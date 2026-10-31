"""Offline checks of the owner-dump ACPI builder with synthetic tables."""
import os
from pathlib import Path
import struct
import sys
import tempfile
import unittest
from unittest import mock

ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT / "provenance/hardware"))
import acpi_builder as builder


def table(signature, body=b"\xa3", oem=builder.OEM, revision=builder.OEM_REVISION):
    data = bytearray(signature + struct.pack("<I", 36 + len(body)) + b"\x02\x00" + oem +
                     struct.pack("<I", revision) + b"INTL" + struct.pack("<I", 0x20230628) + body)
    data[9] = -sum(data) % 256
    return bytes(data)


def device(name, hid, sta=builder.GATED_STA):
    body = name + b"\x08_HID\x0d" + hid + b"\x00" + sta
    length = len(body) + 2
    assert length < (1 << 12)
    return b"\x5b\x82" + bytes([0x40 | (length & 15), length >> 4]) + body


def scope(body):
    length = len(body) + 2 + 4
    return b"\x10" + bytes([0x40 | (length & 15), length >> 4]) + b"_SB_" + body


SVP0 = device(b"SVP0", b"NVDA3000")
SSPM = device(b"SSPM", b"NVDA8400")
DSDT = table(b"DSDT", scope(SVP0 + SSPM + device(b"HFRP", b"MTK00055")))


class Pinned:
    """Pin the builder to synthetic tables for the duration of a test."""

    def __init__(self, dsdt):
        self.dsdt = dsdt

    def __enter__(self):
        self.patches = [mock.patch.object(builder, "DSDT_INPUT", builder.sha(self.dsdt))]
        for patch in self.patches:
            patch.start()
        with mock.patch.object(builder, "exact", lambda data, digest, description: data):
            override = builder.patch_dsdt(self.dsdt)
            cpio = builder.archive(override)
        self.patches += [mock.patch.object(builder, "DSDT_OUTPUT", builder.sha(override)),
                         mock.patch.object(builder, "ARCHIVE_OUTPUT", builder.sha(cpio))]
        for patch in self.patches[1:]:
            patch.start()
        return override, cpio

    def __exit__(self, *error):
        for patch in reversed(self.patches):
            patch.stop()


class PatchTest(unittest.TestCase):
    def test_enables_only_sspm(self):
        with Pinned(DSDT) as (override, _):
            self.assertEqual(len(override), len(DSDT))
            sspm = DSDT.index(SSPM)
            changed = [i for i in range(len(DSDT)) if DSDT[i] != override[i]]
            self.assertEqual(changed[:2], [9, 24])
            self.assertTrue(all(sspm < i < sspm + len(SSPM) for i in changed[2:]))
            self.assertIn(builder.PATCHED_STA, override)
            self.assertEqual(override.count(builder.GATED_STA), 2)
            self.assertEqual(struct.unpack_from("<I", override, 24)[0], builder.OEM_REVISION + 1)
            self.assertEqual(sum(override) % 256, 0)

    def test_finds_sspm_by_structure_not_offset(self):
        moved = table(b"DSDT", scope(device(b"PAD0", b"PNP0C02", b"") * 9 + SVP0 + SSPM))
        with Pinned(moved):
            self.assertEqual(builder.sspm_sta(moved), moved.index(SSPM) + len(SSPM) - len(builder.GATED_STA))

    def test_reports_every_gated_device(self):
        self.assertEqual([(d, h) for d, h, _ in builder.gated_devices(DSDT)],
                         [("SVP0", "NVDA3000"), ("SSPM", "NVDA8400"), ("HFRP", "MTK00055")])

    def test_rejects_unexpected_firmware_shapes(self):
        other_sta = builder.GATED_STA.replace(b"\x0a\x0f", b"\x0a\x0b")
        for dsdt in (table(b"DSDT", scope(SVP0)),
                     table(b"DSDT", scope(SSPM + SSPM)),
                     table(b"DSDT", scope(device(b"SSPX", b"NVDA8400"))),
                     table(b"DSDT", scope(device(b"SSPM", b"NVDA8400", other_sta)))):
            with self.subTest(dsdt=dsdt.hex()), \
                    mock.patch.object(builder, "DSDT_INPUT", builder.sha(dsdt)), self.assertRaises(ValueError):
                builder.patch_dsdt(dsdt)

    def test_rejects_other_oem(self):
        dsdt = table(b"DSDT", scope(SSPM), oem=b"NVDA\0\0ANGUS   ")
        with mock.patch.object(builder, "DSDT_INPUT", builder.sha(dsdt)), self.assertRaises(ValueError):
            builder.patch_dsdt(dsdt)

    def test_archive_holds_only_the_dsdt(self):
        with Pinned(DSDT) as (override, cpio):
            self.assertEqual(len(cpio) % 512, 0)
            self.assertIn(b"kernel/firmware/acpi/DSDT.aml\0", cpio)
            self.assertNotIn(b"SSDT.aml", cpio)
            self.assertIn(override, cpio)


class DumpTest(unittest.TestCase):
    def dump(self, files):
        directory = tempfile.TemporaryDirectory()
        self.addCleanup(directory.cleanup)
        for name, data in files.items():
            Path(directory.name, name).write_bytes(data)
        return directory.name

    def test_windows_capture_and_sysfs_names(self):
        for files in ({"DSDT.bin": DSDT, "FACP.bin": table(b"FACP"), "MSDM.bin": table(b"MSDM")},
                      {"DSDT-LENOVO-CB-01___-00000004.bin": DSDT, "SSD1-LENOVO-CB-01.bin": table(b"SSDT")},
                      {"DSDT": DSDT, "SSDT1": table(b"SSDT"), "notes.txt": b"x"}):
            with self.subTest(files=sorted(files)):
                name, data = builder.dumped_dsdt(self.dump(files))
                self.assertEqual(data, DSDT)
                self.assertTrue(name.startswith("DSDT"))

    def test_identical_copies(self):
        self.assertEqual(builder.dumped_dsdt(self.dump({"DSDT": DSDT, "DSDT.bin": DSDT})), ("DSDT", DSDT))

    def test_rejects_ambiguous_missing_truncated_or_corrupt(self):
        corrupt = bytearray(DSDT)
        corrupt[-1] ^= 1
        for files in ({"DSDT": DSDT, "DSDT.bin": table(b"DSDT")},
                      {"SSDT1": table(b"SSDT")},
                      {"DSDT": DSDT + bytes(4)},
                      {"DSDT": bytes(corrupt)}):
            with self.subTest(files=sorted(files)), self.assertRaises(ValueError):
                builder.dumped_dsdt(self.dump(files))


class FirmwareTest(unittest.TestCase):
    def test_other_firmware_names_the_supported_version(self):
        with self.assertRaises(ValueError) as caught:
            builder.firmware("DSDT", DSDT)
        self.assertIn(builder.FIRMWARE, str(caught.exception))

    def test_override_dump_is_recognized(self):
        with mock.patch.object(builder, "DSDT_OUTPUT", builder.sha(DSDT)), self.assertRaises(ValueError) as caught:
            builder.firmware("DSDT", DSDT)
        self.assertIn("h7607a-acpi.cpio", str(caught.exception))

    def test_pinned_firmware_passes(self):
        with mock.patch.object(builder, "DSDT_INPUT", builder.sha(DSDT)):
            builder.firmware("DSDT", DSDT)


class PublishTest(unittest.TestCase):
    def setUp(self):
        directory = tempfile.TemporaryDirectory()
        self.addCleanup(directory.cleanup)
        self.repo = Path(directory.name).resolve()

    def test_writes_once_and_keeps_identical_files(self):
        files = {builder.ARCHIVE_PATH: b"archive", builder.DSDT_PATH: b"dsdt"}
        self.assertEqual(builder.publish(self.repo, files), sorted(files))
        self.assertEqual((self.repo / builder.ARCHIVE_PATH).read_bytes(), b"archive")
        self.assertEqual(builder.publish(self.repo, files), [])

    def test_keeps_a_different_file(self):
        path = self.repo / builder.ARCHIVE_PATH
        path.parent.mkdir(parents=True)
        path.write_bytes(b"older")
        with self.assertRaises(ValueError):
            builder.publish(self.repo, {builder.DSDT_PATH: b"dsdt", builder.ARCHIVE_PATH: b"archive"})
        self.assertEqual(path.read_bytes(), b"older")
        self.assertFalse((self.repo / builder.DSDT_PATH).exists())

    def test_does_not_write_through_symlinks(self):
        path = self.repo / builder.ARCHIVE_PATH
        path.parent.mkdir(parents=True)
        path.symlink_to(self.repo / "elsewhere")
        with self.assertRaises(ValueError):
            builder.publish(self.repo, {builder.ARCHIVE_PATH: b"archive"})
        self.assertFalse((self.repo / "elsewhere").exists())


class BuildTest(unittest.TestCase):
    def test_build_writes_the_baseline_and_archive(self):
        with tempfile.TemporaryDirectory() as dump, tempfile.TemporaryDirectory() as repo, Pinned(DSDT) as (_, cpio):
            Path(dump, "DSDT").write_bytes(DSDT)
            result = builder.build(dump, repo=repo)
            self.assertEqual(result["written"], sorted([builder.ARCHIVE_PATH, builder.DSDT_PATH]))
            self.assertEqual(Path(repo, builder.ARCHIVE_PATH).read_bytes(), cpio)
            self.assertEqual([row["device"] for row in result["gated_devices"]], ["SVP0", "SSPM", "HFRP"])
            check = builder.build(dump, repo=repo, check_only=True)
            self.assertEqual(check["written"], [])


@unittest.skipUnless(os.environ.get("H7607A_ACPI_DUMP"),
                     "set H7607A_ACPI_DUMP to a folder holding this Yoga's SDCN77WW DSDT")
class OwnerDumpTest(unittest.TestCase):
    def test_reproduces_the_pinned_archive(self):
        with tempfile.TemporaryDirectory() as repo:
            result = builder.build(os.environ["H7607A_ACPI_DUMP"], repo=repo)
            expected = {builder.DSDT_PATH: builder.DSDT_INPUT, builder.ARCHIVE_PATH: builder.ARCHIVE_OUTPUT}
            self.assertEqual({path: builder.sha(Path(repo, path).read_bytes()) for path in expected}, expected)
            self.assertEqual([row["device"] for row in result["gated_devices"]], ["SVP0", "SSPM", "HFRP"])


if __name__ == "__main__":
    unittest.main()
