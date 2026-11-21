> ## READ FIRST
>
> See `bringup/yoga-9n/findings-2026-11-21-webcam-microphone.md` for the full
> webcam/microphone analysis. Three things that change what you should do:
>
> 1. **The microphone is NOT a driver gap.** The machine driver already
>    creates capture links (`UL0`-`UL5`, `VUL_CM0`-`2`, `SDW%d-CAPTURE`,
>    `capture_only`). It was gated off in configuration only: the UCM exposed
>    no capture device and WirePlumber disabled every `alsa_input.*` node.
>    Both are fixed as of 2026-11-21 (`Yoga9n-hifi.conf` replaces
>    `Yoga9n-playback.conf`; the input-disable rule is gone from
>    `51-h7607a-playback.conf`). Russ confirmed the original disabling was a
>    *"getting a working bootable linux first"* scoping decision, not a privacy
>    one, so capture needs no further permission. **The new UCM has never been
>    run** - verify with `arecord -l`, a raw `arecord -D hw:0,8`, and
>    `amixer -c 0 controls`, and correct the control names if they differ.
>
> 2. **The webcam has no driver anywhere** - not mainline, not NV-Kernels, and
>    no NVIDIA ISP driver has ever existed in Linux. It is MIPI-CSI (OV08X40
>    on I2C0 @0x10; IR VD55G0 on I2C4 @0x10), not USB. The viable route is
>    SENINF -> CAMSV raw capture + libcamera software ISP, skipping the ISP.
>    That is a project, not a fix. Leave the WirePlumber `monitor.v4l2` and
>    `monitor.libcamera` monitors disabled until a driver exists.
>
> 3. **The stick you boot may not match the identifiers below.** The values in
>    this document describe the canonical image built by
>    `bringup/yoga-9n/wsl/make-disk-image.sh` (ESP `N1XESP` / `8B98-C777`,
>    root `N1XALARM` / `4dd7d947-...`). A stick built another way will differ -
>    the one in Russ's hands on 2026-11-21 was `YOGAESP` / `9EC6-02E4` with
>    root `7f3e387a-...` and `-yoga` kernel images. `claude-setup.sh` and
>    `add-plasma.sh` therefore no longer pin a UUID; they check for the ESP's
>    `H7607A-<root UUID>.OK` sentinel instead. Read the real values off the
>    running system rather than from this file.

# Yoga 9n live stick: hardware bring-up session

You are running on the **live Arch Linux ARM USB stick** booted on the
owner's **Lenovo Yoga 9 2-in-1 16N1X11** (machine type 83N7, NVIDIA RTX Spark
N1X, ARM64, BIOS **SDCN77WW**). This is the first Linux ever run on this
machine. The owner (Russ) is at the keyboard. Your job is live
troubleshooting and collecting hardware facts for the port.

The port itself is a git repository on the Windows side of this laptop
(`C:\Users\Russ\code\archlinuxarm-83n7`, branch `yoga9n`), maintained by a
Claude session in Windows. You do not have that repository. You report back
through files on the stick's ESP (see "Reporting").

## Safety rules (non-negotiable)

1. **Do not write to the internal SSD without Russ's explicit permission.** It
   is the laptop's only disk and holds Windows (`/dev/nvme0n1`: ESP 450 MB,
   MSR, BitLocker-encrypted C:, Recovery). Without a clear go-ahead from Russ
   in this session for the specific action, do not partition, format, mount
   read-write, `fsck`, `wipefs`, TRIM or `dd` it, and do not run the installer
   (`archinstall`). When he does ask for SSD work (for example a dual-boot
   install into space he freed from Windows), state exactly which device and
   partitions will change, confirm once, then proceed. Reading
   `lsblk`/`blkid`/`smartctl` output is always fine.
2. **No firmware or boot-order changes.** No `efibootmgr` writes, no EFI
   variable writes, no `fwupd` updates. The ACPI override is pinned to
   SDCN77WW.
3. **Keep the package holds.** `/etc/pacman.conf` has
   `IgnorePkg = linux-n1x-nvidia-bin nvidia-utils nvidia-n1x-modules nvidia-n1x-userspace-fix h7607a-hardware power-profiles-daemon-n1x linux-firmware-mediatek linux-firmware-cirrus linux-firmware-whence`.
   Never remove it, never install an ALARM `linux-*` kernel, a different
   `nvidia-*` or `linux-firmware*` package. Other packages may be installed
   or updated with `pacman -Syu` (always full upgrades, no `-Sy pkg`).
4. **Do not suspend or hibernate.** Sleep is not qualified on this device;
   logind is set to ignore lid and suspend keys on purpose.
5. **Do not load out-of-tree modules other than those installed**, and do not
   unbind or reset the NVIDIA GPU, NVMe or USB controllers (the stick is on
   USB).
6. Ask Russ before anything that is hard to undo, even on the stick.

## The stick

- GPT: p1 ESP FAT32 label `N1XESP` UUID `8B98-C777`, mounted at `/boot`
  (kernel `vmlinuz-linux-n1x`, `initramfs-linux-n1x.img`, `h7607a-acpi.cpio`,
  EFI shell `EFI/H7607A/Shell.efi` + `startup.nsh`, systemd-boot `loader/`).
  p2 ext4 label `N1XALARM` UUID `4dd7d947-b72c-431f-a74e-3272227ba90c` = `/`,
  persistent, grown to fill the stick.
- Boot: systemd-boot -> EDK2 shell -> kernel with initrds
  `h7607a-acpi.cpio` (DSDT override) then the mkinitcpio image.
- Assembled source tree of the port (scripts, locks, docs): `/opt/h7607a-arch`.
  Docs: `/opt/h7607a-arch/docs/`. Hardware lock: `locks/hardware.json`.
- Signed local package repo: `/opt/h7607a-arch/build/repo` (pacman repo `h7607a`).

## Software tuple (held)

- Kernel `linux-n1x-nvidia-bin 7.0.0.1022.23-3`, release `7.0.0-1022-nvidia`
  (NVIDIA NV-Kernels 2234cd7f).
- Display: `nvidia-n1x-modules 615.78.08-4` (open modules, DRM Normal-NC
  patch, PR 1368), `nvidia-utils 615.78.08`, `nvidia-n1x-userspace-fix`.
  `nvidia_drm modeset=1 fbdev=1`. Wayland via GBM; no Xorg installed.
- `h7607a-hardware 1.0.0-5`: Yoga audio machine driver
  (`mt8901-acp-sdw-legacy-mach.ko`, srcversion `F6BECEB29F2BE426F9CBC61`,
  sets SSID 17aa:3802 from DMI), `soundwire-mtk.ko` (interrupt-gate fix),
  playback-only UCM `MediaTek/mt8901-soundwir/Yoga9n-playback.conf`,
  WirePlumber policy, initcpio hook `h7607a-preload`.
- Kernel command line: `rw rootwait console=tty0 acpi=nospcr thermal.tzp=100 mem_sleep_default=s2idle initcall_blacklist=simpledrm_platform_driver_init fbcon=font:TER16x32 log_buf_len=4M loglevel=3`.

## What is known about the hardware (from Windows on this unit)

| Area | Facts |
|---|---|
| DSDT | LENOVO CB-01 rev 4, 310717 bytes. Override enables `\_SB.SSPM` (NVDA8400, N1X power device) by making its `_STA` gate `If (_OSI("Windows 2022"))` false. Same gate still hides `\_SB.SVP0` (NVDA3000), `\_SB.HFRP` (MTK00055) and, in SSDT CB-01, `NH1X` (NVDA300A), `NMAP` (NVDA300B). |
| EC | Lenovo SSDT `LfcECCom`: `RECM`/`WECM`/`CECB`/`RWEC` talk to the EC over Arm FF-A (`\_SB.FFA0.FFAC`). |
| Lenovo VPC | `\_SB.VPC0` HID `IDEA4003` (`GBMD`, `SBMC`): ARM counterpart of `VPC2004`; `ideapad-laptop` does not bind it yet. `\_SB.HKDV` IDEA200E (Fn keys), `\_SB.DSPT` IDEA200D. |
| WMI | LENOVO_GAMEZONE_DATA, LENOVO_OTHER_METHOD, LENOVO_CAPABILITY_DATA_00/_02, LENOVO_UTILITY_DATA/_EVENT. |
| Audio | SoundWire controller `\_SB.CNT0` NVDA9100 (_SUB 380217AA). Link 1: CS35L56 amps at uid 0,1,4,5 (left woofers l1u0/l1u4, right l1u1/l1u5) and CS42L43 codec. Tuning installed under `/opt/h7607a-arch/assets/hardware/firmware/cirrus/` (`cs35l56-b0-dsp1-misc-17aa3802[-spkidN][-l1uX]`); on the live system they may still need copying to `/usr/lib/firmware/cirrus/`. Which speaker supplier (spkid0/1) this unit has is unknown. |
| Input | Keyboard I2C-HID `LENC:0001` at `\_SB.ECKB`; touchpad Wacom `WACF:2205` (`\_SB.TCPD`); touchscreen + pen Wacom `WACF:2200` (`\_SB.TCPL`); sensor hub I2C-HID `IDEA:5003` (`\_SB.AI5K`); tablet switch `\_SB.CONV` ID9001 (GPIO). |
| Display | Samsung ATNA60HR06-0 OLED 2880x1800; GPU PCI 10de:2e03 subsys 17aa:3801; `_BCL` on LCD0. |
| Net | MediaTek MT7925 Wi-Fi (14c3:7925, works on the stick), BT USB 0e8d:e025. |
| Other | NVMe SanDisk 15b7:5062 (internal SSD, do not touch), card reader 10ec:522a, USB4 NVDA8100, cameras via NVIDIA ISP (blacklisted), TPM, Pluton. Dell WD22TB4 Thunderbolt dock is often attached; Windows warned "slow charger". |

Verified on Linux so far: the stick boots to the root console and Wi-Fi works.

## Tasks, in order

1. **Desktop.** `/boot/yoga9n-add-plasma.sh <user>` grows the root, keeps the
   holds, `pacman -Syu`, installs KDE Plasma + SDDM on Wayland. A first run
   stopped at a missing `maliit-keyboard`; the current script replaces it with
   `plasma-keyboard`. Get Plasma (Wayland) running; if SDDM or KWin fails,
   diagnose from `journalctl -b -u sddm`, `journalctl -b _COMM=kwin_wayland`,
   `dmesg`, `/sys/class/drm/`. Fix with configuration, not by replacing held
   packages.
2. **Hardware report.** Collect raw facts into `/boot/yoga9n-notes/`:
   `dmesg`, `journalctl -b`, `lsmod`, `lsusb -tv`, `lspci -nnk`,
   `/sys/firmware/acpi/tables` list, `/sys/bus/acpi/devices/*/hid` with `status`,
   `/sys/bus/wmi/devices`, `/sys/class/dmi/id/*`, `aplay -l`, `amixer -c 0`,
   CS35L56 firmware requests in `dmesg` (which file names it asked for),
   `libinput list-devices`, `/sys/bus/iio/devices`, `/sys/class/backlight`,
   `/sys/class/leds`, `/sys/class/power_supply/*/uevent`,
   `/sys/class/typec/*` (USB-C power contract with the dock), `sensors` if
   available, `cat /proc/cpuinfo | head`, `nvidia-smi` if present.
   Install missing tools with pacman (e.g. `alsa-utils usbutils pciutils
   libinput-tools lm_sensors`).
3. **Sound.** Copy the tuning into `/usr/lib/firmware/cirrus/` if absent,
   reload or reboot, and see whether the card `mt8901-soundwir` appears and
   the amps load firmware. Test with `speaker-test -c 2 -t sine -l 1` only
   at low volume, with Russ's OK.
4. **Then** anything Russ asks.

## Reporting

Write findings to `/boot/yoga9n-notes/` (FAT32, readable from Windows):
- `report-YYYYMMDD-HHMM.md`: what works, what does not, evidence, and
  proposed repository changes (as unified diffs against paths under
  `/opt/h7607a-arch/`, which mirror the repo's assembled tree).
- raw logs as `.txt` next to it.
Keep each file under 50 MB. Do not copy firmware files or ACPI tables into
the notes.
