#!/usr/bin/env python3
"""Stage this Yoga 9n's Cirrus CS35L56 firmware and tuning under their Linux names.

Usage: stage-lenovo-tuning.py SOURCE

The files come from Lenovo's Cirrus driver package XuCsMeExt_3802_FDL 1.1.0.11,
which Windows on the Yoga installs. No public download of that package is
pinned, and redistribution is not asserted, so they come from the owner's own
machine. SOURCE is one of:

  the package folder itself, for example on Windows
    C:\\Windows\\System32\\DriverStore\\FileRepository\\xucsmeext_3802_fdl.inf_arm64_*
  a folder holding that package folder, such as the private\\audio-firmware
    folder bringup/yoga-9n/windows/capture.ps1 writes
  a Linux mount of the Windows partition's DriverStore\\FileRepository

Every source file must match its pinned SHA-256. The copies are written to
assets/hardware/firmware/cirrus/ in this component and are kept out of commits.

Linux names: the kernel asks for cs35l56-b0-dsp1-misc-<SSID>[-spkid<N>][-<amp>]
with SSID 17aa3802 (set by the machine driver from DMI) and amp l<link>u<uid>.
The four amps are l1u0 and l1u4 (left woofers) and l1u1 and l1u5 (right). The
Windows SS0/SS1 sets are the two speaker suppliers and map to spkid0/spkid1.
This firmware has no ACPI speaker-ID GPIO, so the plain names without a spkid
part are also written, from SS0; which supplier this unit has is not known.
"""
import hashlib
from pathlib import Path
import sys

COMPONENT = Path(__file__).resolve().parents[1]
DESTINATION = "assets/hardware/firmware/cirrus"
PACKAGE = "xucsmeext_3802_fdl.inf_arm64_"
PREFIX = "cs35l56-b0-dsp1-misc-17aa3802"
WMFW = ("fw/35L56/3.13.5/dflt/b0_dflt_35l56_3.13.5.wmfw",
        "816853191b40050c31fbeba1c82aff3dab8ab69b30e82e5b9274b7f1d0c10eb6")
TUNING = {
    # (supplier, amp): (member, sha256)
    (0, "l1u0"): ("tn/35L56/3802/dflt/b0_dflt_SS0_3802_LW_l1u0.bin",
                  "8672461f27ce9117b9393188596756e3dab9eb1efbde0ee387f336dac0aed32e"),
    (0, "l1u4"): ("tn/35L56/3802/dflt/b0_dflt_SS0_3802_LW_l1u4.bin",
                  "4dd42a3df6051eb9a1dd595220982c1ea755a2063138503a66e624c4fdb2fc12"),
    (0, "l1u1"): ("tn/35L56/3802/dflt/b0_dflt_SS0_3802_RW_l1u1.bin",
                  "0e36b74ce5e8e537fbd0a66d3bf175e9f07172f16398ee760847ef55cae8a1b3"),
    (0, "l1u5"): ("tn/35L56/3802/dflt/b0_dflt_SS0_3802_RW_l1u5.bin",
                  "71e4fbc50917e8d9334c66dedf91ceb6dda483da551a6d782acc9e603a695f0a"),
    (1, "l1u0"): ("tn/35L56/3802/dflt/b0_dflt_SS1_3802_LW_l1u0.bin",
                  "4d363006504e4de4fce700778c9c099d64021c30555de331e7141e5e7ba082f5"),
    (1, "l1u4"): ("tn/35L56/3802/dflt/b0_dflt_SS1_3802_LW_l1u4.bin",
                  "76135657fccf271074247e7b7680639cb496a23a849529f2377d7f70130988de"),
    (1, "l1u1"): ("tn/35L56/3802/dflt/b0_dflt_SS1_3802_RW_l1u1.bin",
                  "d615e33fc750af6f16f3dde7760302a7328e178a579f4de47d01accb5c3ea7a1"),
    (1, "l1u5"): ("tn/35L56/3802/dflt/b0_dflt_SS1_3802_RW_l1u5.bin",
                  "c9b79e9a333b0f923817b32acd8efec4bb1132f9ba449512b8f110fb7cc713c7"),
}
DEFAULT_SUPPLIER = 0


def outputs():
    """Return {linux file name: (member, sha256)}."""
    result = {f"{PREFIX}.wmfw": WMFW, f"{PREFIX}-spkid0.wmfw": WMFW, f"{PREFIX}-spkid1.wmfw": WMFW}
    for (supplier, amp), source in TUNING.items():
        result[f"{PREFIX}-spkid{supplier}-{amp}.bin"] = source
        if supplier == DEFAULT_SUPPLIER:
            result[f"{PREFIX}-{amp}.bin"] = source
    return result


def package_root(source):
    source = Path(source)
    if (source / "fw").is_dir() and (source / "tn").is_dir():
        return source
    candidates = sorted(p for p in source.glob(PACKAGE + "*") if p.is_dir())
    if not candidates:
        candidates = sorted(p for p in source.iterdir() if p.is_dir() and p.name.lower().startswith(PACKAGE))
    if not candidates:
        raise SystemExit(f"No {PACKAGE}* package folder in {source}")
    return candidates[0]


def read(root, member, digest):
    path = root.joinpath(*member.split("/"))
    if not path.is_file():
        # Windows file systems do not care about case; a Linux mount of one may.
        matches = [p for p in root.rglob("*") if p.is_file() and
                   p.relative_to(root).as_posix().lower() == member.lower()]
        if len(matches) != 1:
            raise SystemExit(f"{member} is missing from {root}")
        path = matches[0]
    data = path.read_bytes()
    if hashlib.sha256(data).hexdigest() != digest:
        raise SystemExit(f"{path} differs from the pinned XuCsMeExt_3802_FDL 1.1.0.11 file")
    return data


def main():
    if len(sys.argv) != 2:
        raise SystemExit(__doc__.split("\n\n")[1])
    root = package_root(sys.argv[1])
    files = {name: read(root, member, digest) for name, (member, digest) in outputs().items()}
    target = COMPONENT / DESTINATION
    for name, data in files.items():
        path = target / name
        if path.exists() and (not path.is_file() or path.is_symlink() or path.read_bytes() != data):
            raise SystemExit(f"Refusing to replace {path}, which differs; remove it first")
    target.mkdir(parents=True, exist_ok=True)
    written = 0
    for name, data in sorted(files.items()):
        path = target / name
        if not path.exists():
            path.write_bytes(data)
            written += 1
    print(f"Staged {written} new of {len(files)} files from {root} in {target}")


if __name__ == "__main__":
    main()
