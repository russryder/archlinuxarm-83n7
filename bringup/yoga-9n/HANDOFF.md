# Handoff: Yoga 9n hardware capture on Windows

For a Claude Code session running on the new laptop under Windows. Written
2026-10-25 by the Claude session on the owner's Linux machine (CachyOS, x86-64),
which cannot see this hardware.

## Goal

Port this repository, Arch Linux ARM for the ASUS ProArt P16 H7607BA, to the
**Lenovo Yoga 9n 2-in-1 16N1X11**: machine type 83N7, model 83N7000UUS
(confirmed from Lenovo's support API). Both laptops use the NVIDIA N1X (ARM64).

This session does **not** port anything. Its job is to collect the hardware
facts the port needs, from the preinstalled Windows on Arm and, with the owner's
consent, one UEFI Shell boot. It then writes a report and hands back one
archive. The port itself is done on the Linux machine.

## Ground rules

- **Read-only.** Do not install drivers, change Windows settings, repartition,
  or write to the internal disk outside the capture folder.
- **Ask the owner before touching firmware settings** (Secure Boot, boot order,
  BIOS updates). Phase 3 needs one Secure Boot change; explain it first.
- **BitLocker.** Changing Secure Boot will trigger a BitLocker recovery prompt
  unless BitLocker is suspended first. Before Phase 3, make sure the owner has
  the recovery key (`manage-bde -protectors -get C:`, or their Microsoft
  account), then run `Suspend-BitLocker -MountPoint C: -RebootCount 2`.
- **Firmware pinning.** The ACPI overrides are tied to one exact BIOS version.
  Settle on a BIOS version in Phase 0 and keep it. Lenovo Vantage and Windows
  Update install BIOS updates on their own.
- **Licensing.** Firmware ACPI tables and OEM driver firmware may not be
  redistributed. Keep them in the capture's `private\` folder. Never commit,
  push, paste into an issue, or upload them anywhere public. The repo's
  `.gitignore` already excludes `bringup/yoga-9n/captures/`.
- **CachyOS is not an option**: it is x86-64 only. The target stays Arch Linux
  ARM. A CachyOS-style desktop setup may be added later.

## What is already known

From reading this repo (see `README.md` and `08-documentation/current/payload/docs/`):

| Area | P16 implementation | Expected on the Yoga |
|------|--------------------|----------------------|
| Kernel | NVIDIA `7.0.0-1022-nvidia`, prebuilt | N1X-generic; should carry over |
| Display | `nvidia-n1x-modules 615.78.08`, Normal-NC DRM patch | N1X-generic; should carry over |
| Power | CPPC init and `power-profiles-daemon-n1x` | probably carries over |
| DSDT override | `\_SB.SSPM._STA` is gated on `_OSI("Windows 2022")`; the patch makes it return 0x0F so Linux sees the NVIDIA power device `NVDA8400`. DSDT OEM ID `NVDA`, table ID `ANGUS` | NVIDIA reference code, so likely the same gate. **Verify** |
| SSDT override | rewrites six ASUS EC methods (`RRA9 RRA8 WRA9 WRA8 RWEC GBST`) in the `_ASUS_ASUSSSDT` table | does not apply; Lenovo EC code differs. Need the Lenovo SSDTs |
| Keyboard | patched `hid-asus` | ASUS-only. Need the Yoga's keyboard bus and IDs |
| Audio | MediaTek `mt8901` SoundWire machine driver; Cirrus CS35L56 amps; DMI patch sets SSID 1043:1484 for tuning lookup; tuning from an ASUS driver download | SoundWire controller likely the same; codec and amps unknown. Need the Lenovo SSID and amp tuning |
| Touchpad | PixArt pressure and palm quirk | unknown |
| Brightness | `h7607a-brightness` | unknown; OLED panel |
| Wi-Fi and BT | MediaTek MT7925 | unknown |
| Excluded on P16 | camera, mic capture, touchscreen, stylus, fingerprint, NPU | 2-in-1: touchscreen, pen and tablet-mode sensors matter more here |

Published specs: 16" 2880×1800 OLED touch, N1X with 20 CPU cores, 64 GB
LPDDR5X, 1 TB Gen4 SSD, 99.9 Wh battery, rotating soundbar with tweeters.

## Phase 0: settle the firmware

1. Note the current BIOS version (`Get-CimInstance Win32_BIOS`).
2. Ask the owner whether to update the BIOS to Lenovo's latest **once**, now,
   before any capture. Recommend yes: later BIOS releases usually fix early
   N1X firmware, and every capture after this point pins that version.
3. Then turn off automatic BIOS and driver updates in Lenovo Vantage (or
   Lenovo Commercial Vantage), and ask the owner whether to block driver and
   firmware delivery through Windows Update. One way is Group Policy: "Do not
   include drivers with Windows Updates".

## Phase 1: capture from Windows

The repo needs to be on this machine. Clone it, or copy the folder over from
the Linux machine (`~/code/archlinuxarm-83n7`).

In an **elevated** PowerShell:

```powershell
cd <repo>\bringup\yoga-9n
Set-ExecutionPolicy -Scope Process Bypass
New-Item -ItemType Directory -Force captures | Out-Null
.\windows\capture.ps1 -OutputRoot (Resolve-Path .\captures).Path
```

`capture.ps1` was written without a Windows machine and has never run. Read it
first. If a section logs `FAIL` in `capture.log`, fix the script and rerun.
Keep the fixes: they are part of the handoff. Each section is independent.

It writes `captures\yoga9n-capture-<timestamp>\` and a zip, including:

| File | Contents |
|------|----------|
| `system.json` | DMI-equivalent identity, OS, CPU, RAM, Secure Boot |
| `pnp-devices.json` / `.csv` | every present device: hardware IDs, **ACPI path**, driver, service |
| `pnputil-*.txt` | device tree with relations; driver packages |
| `acpi-tables.json`, `private\acpi\*.bin` | tables Windows exposes. **Only the first SSDT**: a Windows API limitation |
| `dsdt-facts.json` | quick checks: `NVDA8400`, SSPM, every `_OSI` string and its offset, HIDs |
| `edid-*.bin`, `edid.json` | panel EDID |
| `wmi-*.txt` | Lenovo WMI classes, for keyboard backlight, Fn-lock and charge-limit support |
| `powercfg-sleepstates.txt`, `battery-report.html` | S0ix/modern standby, battery |
| `audio-*.txt/json`, `private\audio-firmware\` | audio devices, driver file inventory, copied amp firmware and INFs |
| `inputs.txt` | keyboard, touchpad, touchscreen, pen, sensors, camera, fingerprint, Wi-Fi/BT |

Optional, for deeper ACPI work on this machine: download the ACPICA Windows
tools from acpica.org (`iasl` 20260408 to match the repo), then disassemble
`DSDT.bin` and the SSDTs and grep for `SSPM`, `_OSI`, `EC0`, `NVDA8400` and the
SoundWire and HID devices.

## Phase 2: write the report

Write `captures\yoga9n-capture-<timestamp>\REPORT.md` answering each question
below. Give the evidence file for each answer, and write "unknown" rather than
guessing.

1. **Identity.** The exact values for the repo's `locks/hardware.json`
   `device` block: `sys_vendor`, `product_name`, `board_vendor`, `board_name`,
   `bios_version`, `bios_date`. Also `product_version`, SKU and the EC firmware
   version.
2. **DSDT.** OEM ID, OEM table ID, OEM revision, size and SHA-256. Is
   `NVDA8400` present? Is there an `\_SB.SSPM` device whose `_STA` checks
   `_OSI("Windows 2022")`? Give the offset of that string and say whether it
   is unique. List every `_OSI` string.
3. **SSDTs.** Each SSDT's OEM ID, table ID and revision. Mark which came only
   from the Phase 3 dump. Which table holds the EC (`EC0` or similar), battery
   (`BAT0`) and ACPI AC adapter devices? Do the EC methods store Buffers in
   `Local` variables, like the ASUS methods the P16 SSDT patch rewrites?
4. **Audio.** The SoundWire controller ACPI HID and path; each SoundWire
   peripheral (`SDW\...` or MIPI IDs: manufacturer and part, e.g. Cirrus
   CS35L56/CS42L43 or Realtek RT7xx/RT1xxx); the amp count; the PCI-style
   subsystem ID Lenovo uses for tuning lookup (look in the INFs and firmware
   file names, e.g. `17aaXXXX`); the list of copied tuning files with their
   driver package.
5. **Keyboard and touchpad.** Bus (I2C-HID, SPI or EC/PS2), ACPI path and
   HID IDs (VID/PID) for the keyboard, touchpad, touchscreen and pen. Which
   service drives each one?
6. **Display.** EDID manufacturer, product code, native mode and refresh
   rates; whether brightness goes through the panel (DPCD/OLED) or a backlight
   device.
7. **Wi-Fi and Bluetooth.** Chip and PCI/USB IDs.
8. **Sensors and 2-in-1 features.** Accelerometer, hinge or tablet-mode
   switch, ambient light, lid; their ACPI HIDs.
9. **Camera, fingerprint, NPU.** IDs only.
10. **Power.** Sleep states from `powercfg /a`; anything notable in the
    battery report.
11. **Lenovo WMI.** Class names that match known Linux drivers
    (`ideapad-laptop`, `lenovo-wmi-*`, `lenovo-wmi-gamezone`).
12. **Differences from the P16 table above** that change the porting plan.

## Phase 3: full ACPI dump from the UEFI Shell (needs consent)

Windows hides all SSDTs after the first. The repo's existing kit dumps every
table. This needs a FAT32 USB stick, Secure Boot **off** for one boot, and
BitLocker suspended first (see Ground rules).

1. Format a USB stick as FAT32 (its contents will be lost; ask first).
2. Copy files from the repo and check their hashes with `Get-FileHash`:

   | Source | Destination on stick | SHA-256 |
   |--------|----------------------|---------|
   | `07-build\media\payload\assets\hardware\uefi\Shell.efi` | `EFI\BOOT\BOOTAA64.EFI` | `bb498165b74ad742abd4f223a859caf0ab2187bd9178d3394317cf6c125a9c0e` |
   | `01-platform\acpi\payload\assets\hardware\uefi\acpi-dump.nsh` | `EFI\BOOT\startup.nsh` | `586b206bf10eda0648e5edc3a6891f1f36962e03675c986b5792218c2d9b66c6` |

   (With Python installed, `python 01-platform\acpi\payload\scripts\stage-acpi-dump.py E:\`
   does the same and checks the pins.)
3. Have the owner suspend BitLocker, enter the firmware setup (on Lenovo:
   F2 at power-on, or the Novo button / pinhole; F12 for the boot menu), and
   disable Secure Boot.
4. Boot the stick from the boot menu. The script writes `DSDT0000.bin` and
   `SSDT0000.bin`, `SSDT0001.bin`, ... to `H7607A-ACPI\` on the stick (the
   folder name is a leftover from the P16 and will be renamed in the port). If
   the Shell lacks `acpiview`, it stops with a message; record it.
5. Power off, boot Windows, **re-enable Secure Boot**, and check that BitLocker
   protection is back on (`manage-bde -status C:`).
6. Copy `H7607A-ACPI\` into the capture's `private\acpi-uefi\`, compare the
   DSDT hash with Windows' copy, and update REPORT.md questions 2 and 3.

If anything about Secure Boot or BitLocker is unclear, stop and ask the owner.
Skipping Phase 3 is acceptable; the Linux side can do it later.

## Handing back

1. Re-create the zip once REPORT.md is written and Phase 3 data has been added.
2. Tell the owner the zip's path and SHA-256, and that it contains private
   firmware not to be shared publicly.
3. The owner moves it to the Linux machine by USB or a private cloud folder.
   On Linux it goes in `~/code/archlinuxarm-83n7/bringup/yoga-9n/captures/`.
4. If `capture.ps1` was fixed, the owner copies it back too.

## What happens next on Linux

With the capture, the Linux session will:

- replace the ASUS identity in `locks/hardware.json`, the installer checks
  and the boot scripts with the Yoga's;
- make the DSDT `SSPM` patch find its predicate by pattern, pin the Yoga's
  firmware hashes, and decide whether a Lenovo SSDT fix is needed;
- drop `hid-asus`, the ASUS SSDT guard and the ASUS audio download; add the
  Yoga's audio SSID and tuning extraction;
- update the touchpad quirk, brightness helper and docs;
- add a re-pin tool for `component.yaml` and `manifest.yaml` hashes;
- rebuild the hardware package and images on a native AArch64 host. The
  owner's x86 laptop must not run heavy builds.
