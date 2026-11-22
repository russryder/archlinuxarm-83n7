# Linux on the Lenovo Yoga 9 2-in-1 16N1X11 (NVIDIA N1X)

Hardware enablement for **Arch Linux ARM** on the Lenovo Yoga 9 2-in-1
16N1X11 (machine type **83N7**, NVIDIA **N1X**, AArch64, firmware
**SDCN77WW**), on the `yoga9n` branch.

This is a downstream fork of
[**pfeifferj/archlinuxarm-proart-p16**](https://github.com/pfeifferj/archlinuxarm-proart-p16),
which did the original N1X work for the ASUS ProArt P16. The upstream README
follows below and still describes the P16; everything Yoga-specific lives under
[`bringup/yoga-9n/`](bringup/yoga-9n/).

Published so that others working on N1X laptops do not have to start from
nothing. Corrections and additions are welcome.

## Status on this machine

| | State |
|---|---|
| Boot, panel, Wi-Fi, keyboard, touchpad, touchscreen, pen, tablet mode | working |
| Speakers and headphones | working, tuned (`spkid1`) |
| **Internal microphone array** | **working** |
| GPU / CUDA | working (NVIDIA open modules) |
| **Internal webcam** | sensor driver binds; **no streaming yet** |
| Suspend / hibernate | not qualified; deliberately disabled |
| USB4 / Thunderbolt dock DP + Ethernet | no driver |

Kernel is NVIDIA's out-of-tree [NV-Kernels](https://github.com/NVIDIA/NV-Kernels)
(`7.0.0-1022-nvidia`). **Mainline Linux does not boot usefully on N1X**: a
tree-wide search for `NVDA[0-9A-F]{4}` across Linux 7.3 returns only Tegra and
Grace IDs, and `i2c-mt65xx.c` has no ACPI support upstream, so the I²C-HID
keyboard cannot even bind.

## The single most useful thing to know

**N1X's peripheral silicon is MediaTek.** The ACPI IDs are all `NVDA*`, but the
uncore is MediaTek **MT8991**, and the DSDT says so outright —
`\_SB.SENI._DSM` returns `"mt8991"` and `"mtk-csi-phy-3-0"`. The camera block
is the **MT6991** camera block at the *same register addresses*, so MediaTek's
public GPL ISP8 driver is a port target rather than a reference.

That reframes most of the work from reverse engineering into porting. Details,
with evidence, in
[**`bringup/yoga-9n/findings-2026-11-21-webcam-microphone.md`**](bringup/yoga-9n/findings-2026-11-21-webcam-microphone.md).

## Audio

The internal mic was never a missing driver. NVIDIA's machine driver already
creates the capture links (`UL0`–`UL5`, `VUL_CM0`–`2`, `SDW%d-CAPTURE`); it was
gated off in configuration. Topology is CS42L43 plus four CS35L56 amps on
SoundWire link 1, driven by the MediaTek AFE SoundWire manager (`NVDA9100`).

Specifics that cost time to work out:

- Capture is `UL1` = **PCM index 8** (`hw:<card>,8`); the SoundWire card
  enumerates as **card 1**, with NVIDIA HDMI HDA as card 0.
- Routing: `PDI13 Mux` = `DP7`, `O020 I180 Switch`, `O021 I181 Switch`.
- Internal mics are CS42L43 **Decimator 3 and 4** via `DP1TX1`/`DP1TX2`;
  headset mic is **Decimator 1** in `ADC` mode on the same inputs.
- Use alsa-ucm-conf [PR 862](https://github.com/alsa-project/alsa-ucm-conf/pull/862)
  at commit `7d3555a`, **not** its HEAD — HEAD's
  `CaptureMixerElem "cs42l43 Microphone"` does not exist on this card and makes
  the capture devices fail to apply.
- Speaker tuning needs a Lenovo `17aa:3802` SSID, set from DMI in
  [`audio-identity.patch`](02-drivers/audio/patches/provenance/hardware/audio-identity.patch).
  This unit is `spkid1`.

## Camera

No NVIDIA ISP driver has ever existed in Linux, for any generation, and none is
in NV-Kernels. Sensors here are an **OmniVision OV08X40** (I²C0 @ 0x10) and an
IR **ST VD55G0** (I²C4 @ 0x10), MIPI-CSI — not USB.

Working so far, in [`bringup/yoga-9n/camera/`](bringup/yoga-9n/camera/):
`ov08x40` binds and passes its chip-ID check (`0x560858`), and a stage-0 SENINF
bridge gives `/dev/media0` with a media graph at SGRBG10/3856×2416.

The remaining blocker and its likely answer:

- Camera power does **not** go through the PEP — `power_wrap` lists
  `\_SB.ISP1` as `CTRL_NONE`. `nvCamsys.sys` carries `hfrp_ipi_init` and
  `__qof_mtcmos_raw_voter`: the camera votes its own power over an **HFRP**
  mailbox.
- `\_SB.HFRP` (`MTK00055`) has `_STA = 0` **iff** `_OSI("Windows 2022")`, so it
  is exposed only to an OS that does not claim that string. Un-gating it looks
  like the way in.
- The sensor **MCLK** is a red herring: the Windows sensor driver touches no
  clock at all. The clock is **CAMTG**, owned by SENINF (ID `0x0A09`), so it is
  the same power problem — don't go hunting for a `CMMCLK` pinmux.
- DMA is **not** a blocker: nothing describes a translation for the camera
  engines, so Linux puts them in identity/passthrough IOMMU groups and plain
  `dma_alloc_*` works.

Intended path is SENINF → **CAMSV** (MediaTek's plain CSI-to-DRAM DMA, 6 units
at 0x3A500000–0x3A54A000) plus libcamera's software ISP, skipping the ISP, GCE,
CCU and a 19 MB proprietary tuning database entirely.

## Caveats

- One machine, one firmware (**SDCN77WW**). The ACPI override is pinned to it.
- Not an installer you should run unattended; read
  [limits and known issues](08-documentation/current/payload/docs/limits.md).
- Non-redistributable material is deliberately excluded by `.gitignore`: OEM
  Cirrus firmware and tuning, ACPI table dumps and anything derived from them,
  and the raw hardware captures. You will need to supply those from your own
  machine.

## Related work

- [jerryabramson/yoga-rtx](https://github.com/jerryabramson/yoga-rtx) — Ubuntu
  on this same model
- [johannhartmann/asus-proart-p16-rtx-spark-linux](https://github.com/johannhartmann/asus-proart-p16-rtx-spark-linux)
- [Th0rgal/awesome-rtx-spark](https://github.com/Th0rgal/awesome-rtx-spark) —
  N1X / Spark status tracker
- [MiCode/MTK_kernel_modules](https://github.com/MiCode/MTK_kernel_modules)
  (`bsp-dali-v-oss`, `mtkcam/camsys/isp8/cam/`) — MediaTek's GPL ISP8 camsys
  driver, the camera port base

---

## Upstream: Arch Linux ARM on the ASUS ProArt P16 (H7607BA)

Device enablement and an installer for Arch Linux ARM on the ASUS ProArt P16
H7607BA-SE033W: NVIDIA N1X, AArch64, 128 GiB unified memory, firmware
H7607BA.300. The collection packages a patched NVIDIA kernel, the NVIDIA
display modules, keyboard and audio drivers, ACPI table overrides and an
adapter for upstream Archinstall, and builds installer partition images from
pinned inputs.

Partitioning, package installation, accounts and services stay with Arch Linux
ARM, pacman, mkinitcpio, systemd-boot and Archinstall. This repository only adds
what the hardware needs. Read the
[limits and known issues](08-documentation/current/payload/docs/limits.md)
before installing.

## Documentation

The pages in `08-documentation/current/payload/docs/` also ship in the
assembled tree and on the live USB.

| Stage | Where it runs | Result |
|-------|---------------|--------|
| [Dump and patch ACPI tables](08-documentation/current/payload/docs/acpi-overrides.md) | dump on the P16; patch in the checkout | firmware-specific overrides for early Linux boot |
| [Assemble inputs](08-documentation/current/payload/docs/assembling.md) | host with Bash, jq and Python | a verified tree with the paths the build scripts expect |
| [Build images](08-documentation/current/payload/docs/media-build.md) | native AArch64 Linux, as root | ESP and live root partition images, using prebuilt hardware packages |
| [Write the USB](08-documentation/current/payload/docs/media-build.md#writing-the-usb) | macOS and the named Lima VM | replacement partitions on the maintainer's existing stick |
| [Install](08-documentation/current/payload/docs/installing.md) | P16 booted from that USB | a new SSD system with the selected accounts, storage and packages |

Reference pages cover
[hardware support](08-documentation/current/payload/docs/hardware.md),
[development environments](08-documentation/current/payload/docs/development.md),
[maintainer builds](08-documentation/current/payload/docs/maintainer.md) and
[GPL source](08-documentation/current/payload/docs/gpl-source.md).

## Layout

| Directory | Contents |
|-----------|----------|
| `01-platform/` | kernel package and ACPI/EFI overrides |
| `02-drivers/` | NVIDIA display, keyboard, audio and SoundWire |
| `03-system/` | power management, device policy, audio routing and input files |
| `05-development/` | optional Python, PyTorch, CUDA SDK and container tooling |
| `06-installation/` | the Archinstall adapter and the offline wheel carrier reader |
| `07-build/` | image builder, USB writer, package recipes, signed repository and locked inputs |
| `08-documentation/` | documentation copied into the assembled tree |

[Maintainer builds](08-documentation/current/payload/docs/maintainer.md#component-metadata)
describes the component files that pin every input and how to update them, and
the assembled tree's layout is in its
[README](08-documentation/current/payload/README.md).

## License

The scripts, Python modules and configuration in this repository are under the
MIT license in `LICENSE`. Third-party material keeps its own license: kernel
patches and vendored kernel sources are GPL-2.0, `hid-asus.c` is
GPL-2.0-or-later, power-profiles-daemon is GPL-3.0-only, the NVIDIA open kernel
modules are dual MIT/GPL-2.0, NVIDIA's userspace driver is downloaded under
NVIDIA's license, the UCM files are BSD-3-Clause from NVIDIA, the EDK2 shell is
BSD-2-Clause-Patent and the ACPI guard EFI programs are MIT. Arch Linux ARM and
Ubuntu packages keep their distributions' licenses. The Cirrus tuning firmware
belongs to ASUS and Cirrus Logic, and the ACPI tables to ASUS and NVIDIA;
neither is redistributed (see
[Installing](08-documentation/current/payload/docs/installing.md) and
[Building the ACPI overrides](08-documentation/current/payload/docs/acpi-overrides.md)).
