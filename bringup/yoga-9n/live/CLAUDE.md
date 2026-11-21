> ## READ FIRST -- Windows-side update, 2026-11-21 14:32 PST (supersedes the block below)
>
> **BIOS is still SDCN77WW.** No firmware update was installed during the
> Windows session. The ACPI override is valid. Confirm with
> `dmidecode -s bios-version` anyway.
>
> **The camera blocker is solved on paper. Read
> `/boot/yoga9n-notes/report-20261121-1432-windows-camera-power.md` before
> touching the camera.** Two of your earlier conclusions were wrong, and the
> correction is the whole unblock:
>
> 1. **Stop looking for HFRP firmware.** There is none. The entire Windows
>    driver store was searched; the token `hfrp` appears exactly once in all of
>    it, as the string `hfrp_ipi_init` in `nvCamsys.sys`. No driver binds
>    `MTK00055`. Windows boots no HFRP image and Windows's camera works.
>    `hfrp_ipi_init` was disassembled in full: it initialises an event and a
>    mutex, `MmMapIoSpaceEx`es its own device's memory resources, connects its
>    interrupts, and stops. No firmware load, no reset register, no SMC, and it
>    never touches `0x31270074`.
>
> 2. **`mtk-scpsys-mt6991-mmpc.c` is NOT a dead end -- it is the answer.**
>    `hfrpsys` is MediaTek's name for the camera **power-domain controller**,
>    not a coprocessor you have to boot. MediaTek's own mt6991 DT has
>    `hfrpsys: power-controller@31b50000` with compatible
>    `mediatek,mt6991-hfrpsys-hwv`, and every camera block takes
>    `power-domains = <&hfrpsys MT6991_POWER_DOMAIN_CAM_MAIN / CAM_VCORE /
>    CAM_RAWA / CAM_RAWB>`. That compatible is served by
>    `drivers/soc/mediatek/mtk-scpsys-mt6991-mmpc.c`. It was written off because
>    `0x31b50000` / `0x31b00000` / `0x31a80000` are absent from this machine's
>    ACPI -- true, but absent means **unclaimed, not missing**. `ioremap()`
>    takes a physical address. The report has the exact ctl offsets, voter
>    offsets, bit positions and bus-protect masks for all ten CAM domains.
>
> Also now pinned down, all in the report:
>
> - **The mailbox layout, from the live Windows registry** (not inferred):
>   `IN_STATUS`/`IN_SET` = `+0x100`, `OUT_STATUS`/`OUT_SET` = `+0x104`,
>   `IN_CLR` = `+0x108`, `OUT_CLR` = `+0x10c`. So HFRP's `_CRS` entries
>   `0x311C0100/0104/0108/010C` are **not four doorbells** -- they are that one
>   register set. There is one AP->coprocessor doorbell, `IN_SET` at `+0x100`,
>   which is the `db0` you already picked. `+0x104` raising your own IRQ is
>   correct behaviour, not a bug. Your mailbox mechanics were right all along.
> - **ISP1's `_CRS` maps 1:1 onto MediaTek's mt6991 DT reg-names** -- all 49
>   memory descriptors but three, with a full index table in the report. This
>   is proof N1X's camera block is MT6991's. Note: **there is no RAW_C on this
>   machine** (no `0x3aa00000`), so do not instantiate a third RAW pipe.
>   `qof_base` regions are `_CRS` index 1 (qoftop, `0x3a0a0000`), index 6
>   (raw_a, `0x3a0b0000`) and index 11 (raw_b, `0x3a0c0000`).
> - **QoF is hardware and it is GPL.** `__qof_mtcmos_raw_voter` in
>   `nvCamsys.sys` decompiles to MediaTek's published `mtk_cam-qof.c` constant
>   for constant -- same register offsets (`CTL_1` = 0x0 bit0 set / bit1 clear,
>   `STATE_DBG_1` = 0x30, poll `PS_ON` = bit 1), same 50 us delay, same 600 us
>   timeout. The Windows camera driver is a port of that tree. Use the source.
> - **Camera OPP table** from ISP1's `_DSM` fn 7: 312 MHz/0.575 V,
>   416 MHz/0.600 V, ~550 MHz/0.650 V, 660 MHz/0.700 V, 660 MHz/0.750 V.
> - **`nvCCU.img`** (the CCU 3A coprocessor firmware) is archived on the ESP.
>   `\_SB.CCU0` is `_STA = 0x0F`, i.e. **not gated** -- you can enumerate it
>   today. Not needed for a first frame; leave it.
>
> **Sources are on the ESP, no network needed:**
> `/boot/yoga9n-notes/upstream/isp8-qof/` (mtk_cam-qof.{c,h}, qof_regs.h),
> `/boot/yoga9n-notes/upstream/pm-domain/` (mtk-scpsys-mt6991-mmpc.c,
> mt6991-power.h), `/boot/yoga9n-notes/upstream/dt/mt6991.dts`,
> `/boot/yoga9n-notes/upstream/nvCCU.img`. Same files also at
> `yoga9n-linux\upstream\` on the 2 TB NTFS "Files" drive (`nvme1n1p2`).
>
> **Suggested order:** hfrpsys power-domain provider (read-only register dump
> first), then one domain at a time with its ack bit, then
> `clk-mt6991-cam.c`, then SENINF MMIO. Do not touch SENINF MMIO before the
> power domains are up. Step 1 writes to addresses firmware does not describe,
> so a bad guess can SError the machine -- it is a live stick, the cost is a
> reboot, but dump before you write and do not do it with unsaved work.
>
> The ACPI `_STA` un-gating of HFRP that the earlier block proposed is no
> longer on the critical path. It is already applied in the current
> `h7607a-acpi.cpio` and does no harm; just do not build the camera plan
> around the mailbox.

> ## Earlier Windows-side update, 2026-11-21 evening (superseded in part)
> Your last session's asks are answered in
> `/boot/yoga9n-notes/answers-from-windows-20261121.md`. All of this is now in
> the GitHub repo (russryder/archlinuxarm-83n7, branch yoga9n), including your
> camera source under `bringup/yoga-9n/camera/` and your two reports.
>
> **Microphone: done.** Verified working and committed. Playback was also
> re-checked audibly afterwards and speakers still work, so the shared
> SectionVerb change is safe. The only thing still untested is the headset
> mic, which needs something plugged into the jack. Do not ask Russ to retest
> speakers.
>
> **Camera: the blocker has an answer.** You concluded "Linux has no path to
> turn on camtg/cammain today." There is one:
>
> - Camera power does **not** go through the PEP. `nvpep.sys` is SCMI/tinysys,
>   but `power_wrap` lists `\_SB.ISP1` as `CTRL_NONE`. `nvCamsys.sys` instead
>   has `hfrp_ipi_init`, `__qof_mtcmos_raw_voter`, `mtk_cam_vcore_probe` and
>   `qof_ddren_setting` — the camera votes its own power over an **HFRP
>   mailbox**. `0x31160000` is one of ISP1's own `_CRS` regions (4 KB, shared
>   IRQ 511) and is the likely voter window.
> - `\_SB.HFRP` (MTK00055) has `_STA = 0` **iff** `_OSI("Windows 2022")`, so
>   it is deliberately exposed only to an OS that does not claim that string.
>   No `MTK*` device is enumerated on Windows at all. The repo's
>   `acpi_builder.py` already finds every device behind that gate and
>   neutralises the predicate, and `sspm-patch.json` already lists HFRP — it
>   just patches SSPM only today. Extending it is the unblock. **Not done: it
>   changes boot, so it is Russ's call** (safety rule 2).
> - **The MCLK hunt is a dead end.** `nvMIPICamSensor.sys` handles only
>   `campower` and `reset`; there is no `mclk`/`cmmclk` string and no
>   19200000/24000000 literal in any camera driver. The clock is **CAMTG,
>   owned by SENINF** (clock ID `0x0A09` in ISP1's `CISP` table). So MCLK is
>   not separate from camera clock enablement — stop looking for a pinmux.
>
> Also in the answers file: the SENINF bring-up order lifted from
> `nvSeninf.sys` (`csirx_phyA_power_on` -> `csirx_dphy_init` ->
> `_init_deskew_setting` -> `_dphy_setting` -> `csirx_mac_top_setting` ->
> `csirx_mac_csi_setting`), and confirmation that MT6991's DT puts
> `seninf-top` and `cam_main` at the same addresses this machine uses — so
> MediaTek's public ISP8 driver is a port target, not a reference.
>
> Corrections accepted from your report: DMA is not a blocker (identity
> IOMMU groups), CAMI campower is GPIO 102, reset is active low, card is 1.
>
> Still true from before: the webcam has no upstream driver anywhere, and the
> stick's identifiers may not match the canonical image described below
> (this one: ESP `YOGAESP`/`9EC6-02E4`, root `7f3e387a-...`, `-yoga` kernels).
> `claude-setup.sh` and `add-plasma.sh` now key off the ESP's
> `H7607A-<root UUID>.OK` sentinel instead of a pinned UUID.

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
| Audio | SoundWire controller `\_SB.CNT0` NVDA9100 (_SUB 380217AA). Link 1: CS35L56 amps at uid 0,1,4,5 (left woofers l1u0/l1u4, right l1u1/l1u5) and CS42L43 codec. Tuning installed under `/opt/h7607a-arch/assets/hardware/firmware/cirrus/` (`cs35l56-b0-dsp1-misc-17aa3802[-spkidN][-l1uX]`); on the live system they may still need copying to `/usr/lib/firmware/cirrus/`. **This unit is spkid1** (verified 2026-11-21: all four amps load `cs35l56-b0-dsp1-misc-17aa3802-spkid1.wmfw` + `-spkid1-l1u{0,1,4,5}.bin`, "Calibration applied", PID 0x2690 SID 0x1 TID 0x723). |
| Input | Keyboard I2C-HID `LENC:0001` at `\_SB.ECKB`; touchpad Wacom `WACF:2205` (`\_SB.TCPD`); touchscreen + pen Wacom `WACF:2200` (`\_SB.TCPL`); sensor hub I2C-HID `IDEA:5003` (`\_SB.AI5K`); tablet switch `\_SB.CONV` ID9001 (GPIO). |
| Display | Samsung ATNA60HR06-0 OLED 2880x1800; GPU PCI 10de:2e03 subsys 17aa:3801; `_BCL` on LCD0. |
| Net | MediaTek MT7925 Wi-Fi (14c3:7925, works on the stick), BT USB 0e8d:e025. |
| Other | NVMe SanDisk 15b7:5062 (internal SSD, do not touch), card reader 10ec:522a, USB4 NVDA8100, cameras via NVIDIA ISP (blacklisted), TPM, Pluton. Dell WD22TB4 Thunderbolt dock is often attached; Windows warned "slow charger". |

Verified on Linux so far: the stick boots to the root console and Wi-Fi works.

## Tasks, in order

Desktop, the hardware report and sound are **done** (Plasma runs, the report
was filed, speakers and the internal microphone work and are committed). Do
not redo them. Current work:

1. **Camera: bring up the power domains.** Follow the READ FIRST block and
   `/boot/yoga9n-notes/report-20261121-1432-windows-camera-power.md` §8.
   Port the `-hwv` path of `upstream/pm-domain/mtk-scpsys-mt6991-mmpc.c` as a
   platform driver that ioremaps `0x31b50000` (mmpc/ctl), `0x31b00000`
   (mm_hwv, 0x6000), `0x31a80000` (mminfra_hwv) and `0x1000c000`
   (cksys_gp2), and registers one generic PM domain per CAM domain.
   **Dump those registers read-only first** and show Russ the values before
   any write -- these addresses are not described in ACPI, so a wrong guess
   can SError the machine (live stick, so the cost is a reboot).
2. **One domain at a time.** `CAM_VCORE` then `CAM_MAIN`, checking the
   done/ack bit after each. Keep the bus-protect ordering from the driver.
   Then `CAM_RAWA`.
3. **Clocks.** `clk-mt6991-cam.c` from the same MediaTek tree; `camtg` is
   clock ID `0x0A09` per ISP1's `CISP` table.
4. **SENINF.** Only after the power domains are up. Bring-up order is in
   `answers-from-windows-20261121.md`. Two RAW pipes on this machine, not
   three.
5. **Headset microphone** is the one audio loose end: needs something in the
   jack (`Decimator 1` in `ADC` mode, gated on `Headset Mic Jack`).
6. **Then** anything Russ asks.

Skip, with reasons recorded: HFRP mailbox messaging (nothing services it and
nothing needs to -- see READ FIRST), hunting HFRP firmware (none exists), the
CMMCLK/pinmux hunt (the Windows sensor driver programs no clock), and the CCU
coprocessor (3A only, not needed for a first frame).

## Reporting

Write findings to `/boot/yoga9n-notes/` (FAT32, readable from Windows):
- `report-YYYYMMDD-HHMM.md`: what works, what does not, evidence, and
  proposed repository changes (as unified diffs against paths under
  `/opt/h7607a-arch/`, which mirror the repo's assembled tree).
- raw logs as `.txt` next to it.
Keep each file under 50 MB. Do not copy firmware files or ACPI tables into
the notes.
