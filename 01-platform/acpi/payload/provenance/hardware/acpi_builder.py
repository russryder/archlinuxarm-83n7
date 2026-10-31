#!/usr/bin/env python3
"""Build the SDCN77WW ACPI override from this Yoga 9n's own DSDT.

No firmware table, nor anything derived from one, is distributed. Dump the
DSDT of your own Lenovo Yoga 9 2-in-1 16N1X11 (machine type 83N7) into a
directory and pass it as --dump. Any of these works:

  Windows on the Yoga: bringup/yoga-9n/windows/capture.ps1 writes
  private\\acpi\\DSDT.bin and private\\acpi-registry\\; pass either folder.

  Linux booted without h7607a-acpi.cpio:
    mkdir DIR
    sudo cat /sys/firmware/acpi/tables/DSDT > DIR/DSDT

  UEFI: scripts/stage-acpi-dump.py stages the EDK2 Shell and a dump script on
  a mounted FAT32 stick; the tables land in its H7607A-ACPI folder.

The DSDT must be that of BIOS SDCN77WW. Five devices in this firmware use the
same _STA gate, If (_OSI ("Windows 2022")) { Return (0) } Else { Return (0x0F) },
which hides them from Windows and, since Linux also answers true to that _OSI
string, from Linux. Only \\_SB.SSPM (NVDA8400, the N1X power device) is
enabled: its predicate becomes Zero, padded with Noop so no length changes.
SSPM is located by walking the AML to the Device whose _HID is NVDA8400 and
then its _STA, not by offset or by searching for the predicate string, which
occurs three times. The other gated devices are reported and left alone.

The Lenovo EC methods (SSDT LfcECCom: RECM, WECM, CECB, RWEC) already keep
their FF-A buffers in named objects, so the ASUS-style SSDT repair of the
ProArt P16 port is not needed and no SSDT is overridden.
"""
import argparse
import hashlib
import json
from pathlib import Path
import stat
import struct

REPO = Path(__file__).resolve().parents[2]
FIRMWARE = "SDCN77WW"
OEM = b"LENOVOCB-01   "
OEM_REVISION = 4
DSDT_INPUT = "365db468ba36b20b8d972c9531259c6704e8eb04f7bf8d75cad08474f7fde868"
DSDT_OUTPUT = "06b53baf4f1b46b645579678ca2e28bd7536dd19e34fe7394d3726bd1e444f52"
ARCHIVE_OUTPUT = "812820d208d01e22b7604d7ad70dbec704b7f9b46a97c77324f6b849418b5488"
TARGET_HID = b"NVDA8400"
PREDICATE = b"_OSI\x0dWindows 2022\x00"
# Method (_STA, 0) { If (_OSI ("Windows 2022")) { Return (Zero) } Else { Return (0x0F) } }
GATED_STA = (b"\x14\x21_STA\x00" b"\xa0\x15" + PREDICATE + b"\xa4\x00" b"\xa1\x04\xa4\x0a\x0f")
PATCHED_STA = GATED_STA.replace(PREDICATE, b"\x00" + b"\xa3" * (len(PREDICATE) - 1))
DSDT_PATH = "assets/hardware/uefi/n1x-dsdt-baseline.bin"
ARCHIVE_PATH = "assets/hardware/acpi/h7607a-acpi.cpio"


def require(condition, message):
    if not condition:
        raise ValueError(message)


def sha(data):
    return hashlib.sha256(data).hexdigest()


def exact(data, digest, description):
    require(sha(data) == digest, f"{description} SHA-256 mismatch")
    return data


def table(data, signature, oem, revision):
    require(len(data) >= 36 and data[:4] == signature, "Wrong ACPI signature")
    require(struct.unpack_from("<I", data, 4)[0] == len(data), "Wrong ACPI length")
    require(sum(data) % 256 == 0, "Invalid ACPI checksum")
    require(data[10:24] == oem, "Wrong ACPI OEM identity")
    require(struct.unpack_from("<I", data, 24)[0] == revision, "Wrong OEM revision")


def pkg_length(data, offset):
    require(0 <= offset < len(data), "Truncated AML package length")
    first = data[offset]
    following = first >> 6
    require(offset + following < len(data), "Truncated AML package length")
    length = first & (0x0f if following else 0x3f)
    for index in range(following):
        length |= data[offset + 1 + index] << (4 + index * 8)
    return length, following + 1


def name_at(data, offset):
    """Return (NameString bytes, size) for the AML name starting at offset."""
    start = offset
    while data[offset] in b"\\^":
        offset += 1
    if data[offset] == 0x2e:  # DualNamePrefix
        offset += 9
    elif data[offset] == 0x2f:  # MultiNamePrefix
        offset += 2 + 4 * data[offset + 1]
    elif data[offset] == 0x00:  # NullName
        offset += 1
    else:
        offset += 4
    return data[start:offset], offset - start


def objects(data, kind, start=36, end=None):
    """Yield (offset, end, name) for each Device (kind b"\\x5b\\x82") or Method (b"\\x14") whose
    package parses inside [start, end). Matches are filtered by structure, not trusted blindly."""
    end = len(data) if end is None else end
    offset = data.find(kind, start, end)
    while offset != -1:
        body = offset + len(kind)
        try:
            length, width = pkg_length(data, body)
            name, size = name_at(data, body + width)
        except (ValueError, IndexError):
            name = None
        stop = body + length if name is not None else 0
        if name is not None and offset < stop <= end and len(name) >= 4 and \
                all(c in b"ABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789_\\^." or c in (0x2e, 0x2f) for c in name):
            yield offset, stop, name
        offset = data.find(kind, offset + 1, end)


def gated_devices(dsdt):
    """Return [(device name, _HID, _STA offset)] for every device whose _STA is the Windows 2022 gate."""
    found, devices = [], None
    at = dsdt.find(GATED_STA)
    while at != -1:
        if devices is None:
            devices = list(objects(dsdt, b"\x5b\x82"))
        owners = [(offset, stop, name) for offset, stop, name in devices if offset < at < stop]
        require(owners, f"Gated _STA at 0x{at:x} is not inside a Device")
        offset, stop, name = max(owners)  # innermost: the latest start that still encloses it
        found.append((name[-4:].decode("ascii"), device_hid(dsdt, offset, stop), at))
        at = dsdt.find(GATED_STA, at + 1)
    return found


def device_hid(dsdt, start, stop):
    at = dsdt.find(b"\x08_HID", start, stop)
    if at == -1:
        return None
    if dsdt[at + 5] == 0x0d:
        return dsdt[at + 6:dsdt.index(b"\x00", at + 6)].decode("ascii")
    if dsdt[at + 5] == 0x0c:  # EISA ID DWord
        return "EISA:" + dsdt[at + 6:at + 10].hex()
    return None


def sspm_sta(dsdt):
    """Return the offset of SSPM's gated _STA, found through the device holding _HID NVDA8400."""
    hid = b"\x08_HID\x0d" + TARGET_HID + b"\x00"
    devices = []
    for offset, stop, name in objects(dsdt, b"\x5b\x82"):
        if dsdt.find(hid, offset, stop) != -1:
            inner = [d for d in objects(dsdt, b"\x5b\x82", offset + 2, stop)]
            if not any(dsdt.find(hid, a, b) != -1 for a, b, _ in inner):
                devices.append((offset, stop, name))
    require(len(devices) == 1, f"Expected one Device with _HID {TARGET_HID.decode()}, found {len(devices)}")
    offset, stop, name = devices[0]
    require(name.endswith(b"SSPM"), f"The {TARGET_HID.decode()} device is {name!r}, not SSPM")
    methods = [m for m in objects(dsdt, b"\x14", offset, stop) if m[2] == b"_STA"]
    require(len(methods) == 1, f"Expected one _STA in SSPM, found {len(methods)}")
    at = methods[0][0]
    require(dsdt[at:at + len(GATED_STA)] == GATED_STA,
            "SSPM._STA is not the expected Windows 2022 gate; this firmware differs from " + FIRMWARE)
    return at


def patch_dsdt(original):
    exact(original, DSDT_INPUT, "Firmware DSDT")
    table(original, b"DSDT", OEM, OEM_REVISION)
    at = sspm_sta(original)
    modified = bytearray(original)
    modified[at:at + len(GATED_STA)] = PATCHED_STA
    struct.pack_into("<I", modified, 24, OEM_REVISION + 1)
    modified[9] = 0
    modified[9] = -sum(modified) % 256
    table(modified, b"DSDT", OEM, OEM_REVISION + 1)
    return exact(bytes(modified), DSDT_OUTPUT, "SSPM override")


def member(name, data, mode, inode):
    name = name.encode("ascii") + b"\0"
    fields = (inode, mode, 0, 0, 2 if stat.S_ISDIR(mode) else 1,
              0, len(data), 0, 0, 0, 0, len(name), 0)
    entry = b"070701" + b"".join(f"{value:08x}".encode() for value in fields) + name
    entry += bytes(-len(entry) % 4)
    entry += data
    return entry + bytes(-len(entry) % 4)


def archive(dsdt):
    exact(dsdt, DSDT_OUTPUT, "SSPM override")
    result = b"".join(member(name, b"", stat.S_IFDIR | 0o755, inode)
                      for inode, name in enumerate(("kernel", "kernel/firmware", "kernel/firmware/acpi"), 1))
    result += member("kernel/firmware/acpi/DSDT.aml", dsdt, stat.S_IFREG | 0o644, 4)
    result += member("TRAILER!!!", b"", 0, 5)
    result += bytes(-len(result) % 512)
    return exact(result, ARCHIVE_OUTPUT, "Production ACPI archive")


def dumped_dsdt(dump):
    """Return (file name, data) of the single distinct DSDT in dump."""
    dump = Path(dump)
    require(dump.is_dir(), f"{dump} is not a directory")
    found = {}
    for path in sorted(dump.iterdir()):
        if not path.is_file():
            continue
        with path.open("rb") as stream:
            head = stream.read(4)
        if head != b"DSDT":
            continue
        data = path.read_bytes()
        require(len(data) >= 36 and struct.unpack_from("<I", data, 4)[0] == len(data),
                f"{path.name} does not hold exactly one table; delete old dumps and dump again")
        require(sum(data) % 256 == 0, f"{path.name} has an invalid ACPI checksum; dump again")
        found.setdefault(data, []).append(path.name)
    require(found, f"No DSDT dump in {dump}; pass a folder holding this Yoga's DSDT "
            "(capture.ps1 private\\acpi, or a copy of /sys/firmware/acpi/tables/DSDT)")
    require(len(found) == 1, f"Different DSDT dumps in {dump}: " +
            ", ".join(sorted(name for names in found.values() for name in names)))
    data, names = next(iter(found.items()))
    return names[0], data


def firmware(name, data):
    digest = sha(data)
    require(digest != DSDT_OUTPUT,
            f"{name} is the DSDT from h7607a-acpi.cpio, not the firmware's; dump it from Windows or "
            "from a Linux booted without that archive")
    require(digest == DSDT_INPUT,
            f"{name} is not the DSDT of BIOS {FIRMWARE} (SHA-256 {digest}); "
            f"this override is only for BIOS {FIRMWARE}")


def publish(repo, files):
    """Write verified results to their collection paths, keeping identical existing files."""
    pending = {}
    for relative, data in files.items():
        path = repo / relative
        require(path.parent.resolve().is_relative_to(repo), f"{path.parent} resolves outside {repo}")
        if path.exists() or path.is_symlink():
            require(path.is_file() and not path.is_symlink() and path.read_bytes() == data,
                    f"Refusing to replace {path}, which differs from the verified result; remove it first")
        else:
            pending[path] = data
    for path, data in pending.items():
        path.parent.mkdir(parents=True, exist_ok=True)
        stream = path.open("xb")
        try:
            with stream:
                stream.write(data)
        except BaseException:
            path.unlink(missing_ok=True)
            raise
    return sorted(path.relative_to(repo).as_posix() for path in pending)


def pins(files):
    return {name: {"bytes": len(data), "sha256": sha(data)} for name, data in files.items()}


def build(dump, *, repo=REPO, check_only=False):
    repo = Path(repo).resolve()
    name, dsdt = dumped_dsdt(dump)
    firmware(name, dsdt)
    override = patch_dsdt(dsdt)
    files = {DSDT_PATH: dsdt, ARCHIVE_PATH: archive(override)}
    written = [] if check_only else publish(repo, files)
    return {"schema": 3, "firmware": FIRMWARE, "dump": {"DSDT": name},
            "enabled": "\\_SB.SSPM", "gated_devices": [
                {"device": device, "hid": hid, "sta_offset": f"0x{at:x}"} for device, hid, at in gated_devices(dsdt)],
            "overrides": pins({"DSDT.aml": override}), "outputs": pins(files), "written": written}


def cli(*, check_only=False):
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("--dump", required=True, type=Path, metavar="DIR",
                        help="Directory holding this Yoga's DSDT dump")
    args = parser.parse_args()
    try:
        result = build(args.dump, check_only=check_only)
    except (ValueError, OSError) as error:
        parser.exit(1, f"ACPI build failed: {error}\n")
    print(json.dumps(result, indent=2))
