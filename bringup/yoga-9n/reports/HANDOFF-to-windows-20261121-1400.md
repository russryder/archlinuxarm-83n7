# Handoff to the Windows side — 2026-11-21 ~14:00 PST

Written by the stick session just before Russ reboots into Windows to let it
process updates. Read this first, then
`report-20261121-1323-hfrp.md` for the detail.

## 1. WARNING: a BIOS update will invalidate the ACPI override

This is the one thing that can break Linux on this machine while you are in
Windows.

The DSDT override is **pinned to BIOS SDCN77WW**. It is built from that
firmware's exact DSDT (SHA-256 `365db468...`) and the kernel applies it by
matching signature + OEM ID + OEM table ID and a newer OEM revision. If Windows
Update or Lenovo Vantage installs a **BIOS/UEFI firmware update**, the
firmware's own DSDT changes, but the kernel will still happily load our stale
override on top of it. The result is an override that patches offsets that may
no longer mean what they did — plausibly an unbootable or subtly broken Linux,
and the failure would not be obvious.

**Please decline BIOS/firmware/"System Firmware Update" items.** Ordinary
Windows and driver updates are fine and are not affected.

If a BIOS update does get installed, **do not just boot the stick**. First:

```
# In Windows, check the version:
wmic bios get smbiosbiosversion        # or: msinfo32 -> BIOS Version
```

If it is no longer `SDCN77WW`, the override must be rebuilt from the new
firmware's DSDT before Linux is booted again:

1. Re-dump the DSDT (`bringup/yoga-9n/windows/capture.ps1` ->
   `private\acpi\DSDT.bin`).
2. Update `DSDT_INPUT` in `provenance/hardware/acpi_builder.py`, re-run
   `power-archive-builder.py`, and replace `/boot/h7607a-acpi.cpio` on the
   stick's ESP.
3. Until then, boot Linux with the **old** override restored (see rollback
   below) only if the firmware is unchanged — otherwise don't boot it at all.

Nothing we did touches Windows' own boot path: our override lives only in the
stick's ESP (`YOGAESP`/`9EC6-02E4`) and is loaded as an initrd by the EDK2 shell
there. Windows boots from `nvme0n1p1` and is unaffected.

## 2. What changed on the machine this session

- `/boot/h7607a-acpi.cpio` on the **stick's** ESP is now
  `83d93a8caf6700e5ab53ac8b06737f53fa10914ed5b44e7a65868e576342ebc0`
  (SSPM **+ HFRP** un-gated). Previous SSPM-only override is backed up beside it
  as `h7607a-acpi.cpio.bak-20261121-sspm-only` (`812820d2...`), and in `/root`.
  **Rollback = restoring that one file.**
- `/opt/h7607a-arch` has the three-file change applied, with `.pre-hfrp`
  backups beside each. **`locks/hardware.json` and `release.json` now disagree
  with the tree** and need regenerating upstream — the four affected entries and
  all new hashes are tabulated in `report-20261121-1323-hfrp.md`.
- The 2TB data drive (`nvme1n1p2`, NTFS "Files") now has a
  `yoga9n-linux\` folder with an archive of these notes, both DSDTs, both cpios
  and the new driver source. It was mounted read-write from Linux with `ntfs3`
  and **unmounted cleanly** before this reboot, so Windows should see no dirty
  volume. Nothing else on that drive was touched.
- Nothing was written to `nvme0n1` (the Windows/BitLocker disk) at any point.

## 3. Result: HFRP is un-gated and reachable, but nobody is home

Confirmed working: `\_SB.HFRP` (MTK00055) now enumerates (`status` 0 -> 15) with
a platform device and all six `_CRS` regions claimed. SSPM, audio, Wi-Fi and
Plasma all unaffected. The new `hfrp_ci` driver binds it and can compose and
send messages.

Confirmed **not** working: nothing services the mailbox. Messages sit in the
slot unmodified; no reply ever arrives. Writing doorbells 1-3 only raises our
own level IRQ.

Best current explanation: **the HFRP coprocessor has no firmware running.**
`linux-firmware-mediatek` ships `scp.img` System Companion Processor images for
six other MediaTek SoCs, so these coprocessors are normally brought up by an
OS-loaded blob; there is no mt8901/mt8991 image anywhere, and HFRP's registers
all read zero.

## 4. What to do in Windows, in priority order

Windows Update will likely refresh the NVIDIA/MediaTek driver package, which is
**an opportunity** — the driver store will be freshly populated. While you are
there:

1. **Look for HFRP firmware and its loader.** Search the driver store
   (`C:\Windows\System32\DriverStore\FileRepository\`) and the Lenovo/NVIDIA
   package for blobs shipped alongside `nvCamsys.sys` — `*.img`, `*.bin`,
   `*.fw`, anything referenced by name from `nvCamsys`. Also check whether
   `nvCamsys` or a sibling service writes a reset/boot register or calls an
   SMC/PSCI to start a coprocessor. **This now outranks everything else: a
   feature_id is useless if the mailbox is unserviced.**
2. **Disassemble `hfrp_ipi_init`** and record exactly what it touches before the
   first message — register order, and whether it writes `0x31270074` or
   anything outside HFRP's ACPI `_CRS`.
3. **Which of the four doorbells is AP -> HFRP, and what value?** `0x311C0100`
   (db0) is our candidate: it is the only one that does not raise the AP's own
   interrupt. SSPM's analogue writes magic `0x01` to `IN_SET`.
4. **Only then** the `feature_id`/`p1..p5` that `__qof_mtcmos_raw_voter` sends.

Useful context you can rely on now, because it was captured live rather than
inferred: the tinysys wire format is confirmed
(`message_header = msg_id | type<<8 | protocol<<10 | token<<18`, protocol
`0x80`, payload at slot+0x1c = `{reserv, feature_id, p1..p5}`), and `feat_id
0xd` is device power control with `dev_id` 0x0-0x2 = USB0-2, 0x19-0x1b =
DSP1-3. A live SSPM message used `dev_id 0x1c`, which ACPI does not list — the
firmware namespace is larger than DPMT exposes.

Dead ends, documented so they are not retried: porting
`mtk-scpsys-mt6991-mmpc.c` (its voter registers at 0x31b00000 / 0x31a80000 /
0x31b50000 are **not described in N1X ACPI at all**), any ACPI route (HFRP has
no `_DSM`, ISP1's `_PS0`/`_PS3` are empty, no `OperationRegion` touches
`0x31xxxxxx`), and the MCLK/pinmux hunt.

## 5. To resume on Linux after Windows

```
bash /boot/yoga9n-refresh-briefing.sh      # re-sync the briefing if updated
source ~/.bashrc; cd /root/yoga9n-live && claude
```

Then the post-reboot checks in `report-20261121-1323-hfrp.md`. Confirm the BIOS
is still `SDCN77WW` (`dmidecode -s bios-version`) **before** trusting the
override.

## 6. Firmware baseline, captured 2026-11-21 14:00 PST (before the Windows updates)

Compare against this after updating. If `bios-version` is not `SDCN77WW`, see
section 1 before booting Linux.

| field | value |
|---|---|
| bios-vendor | LENOVO |
| **bios-version** | **SDCN77WW** |
| bios-release-date | 09/24/2026 |
| system-product-name | 83N7 |
| system-version | Yoga 9 2-in-1 16N1X11 |
| baseboard-product-name | LNVNB161216 |

Firmware DSDT (unpatched) SHA-256:
`365db468ba36b20b8d972c9531259c6704e8eb04f7bf8d75cad08474f7fde868`, 310717
bytes, OEM revision 4. Our override is the same length, OEM revision 5,
SHA-256 `e1cdbd67f206dd847c3915ce4e05574d5ad5708e46e6ec4968b00db24ab2930c`.

In Windows: `wmic bios get smbiosbiosversion`
In Linux:   `dmidecode -s bios-version`
