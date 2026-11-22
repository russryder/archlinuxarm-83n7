# Camera: source + ACPI decode (stick session, 2026-11-21)

## Build/test infrastructure
- Test module built against /usr/src/linux-headers-7.0.0-1022-nvidia-yoga loaded and unloaded
  cleanly on 7.0.0-1022-nvidia-yoga (taint O+E only). The approximate build tree works.
- NV-Kernels source: sparse blobless checkout at /root/src/nv-kernels, tag
  Ubuntu-nvidia-7.0-7.0.0-1022.23_24.04.1 = 2234cd7f (the running kernel's base).
  Paths: drivers/media/i2c, drivers/media/platform/mediatek, drivers/staging/media,
  drivers/pinctrl/mediatek, drivers/soc/mediatek, i2c-mt65xx.c, mtk_iommu.c, mtk-smi.c.
- Confirmed: no SENINF/CAMSV/camsys driver in NV-Kernels (platform/mediatek has only jpeg, mdp, mdp3, vcodec, vpu).
  ov08x40.c (2405 lines) and vd55g1.c are present.

## What ov08x40 needs to probe
- fwnode graph endpoint (else -EPROBE_DEFER), CSI-2 D-PHY with 2 or 4 lanes, link-frequencies
  containing 400 MHz or 749 MHz.
- optional "reset" GPIO (requested OUT_HIGH = asserted; logical, so polarity matters).
- regulators dovdd/avdd/dvdd (dummies fine).
- xvclk at exactly 19.2 MHz via devm_v4l2_sensor_clk_get().
- Power-on: clk on -> reset asserted -> regulators -> reset released -> 5 ms -> read 0x300a == 0x560858.
- Match: only acpi OVTI08F4 / of ovti,ov08x40; no i2c_device_id table.

## ACPI facts (live DSDT on the stick)
| | CAMF (NVDA2810, OV08X40) | CAMI (NVDA2812, VD55G0) |
|---|---|---|
| I2C | I2C0: 0x10 sensor, 0x50 eeprom, 400 kHz | I2C4: 0x10 sensor, 0x50 eeprom, 0x63 irled |
| campower | GPIO 34 (0x22) | **GPIO 102 (0x66)** — the earlier findings file only listed 0x5F |
| reset | GPIO 39 (0x27) | GPIO 95 (0x5F) |
| csiport | 0 | (see HWIF) |
| _PS0/_PS3 | empty | empty |
| _DSD, clock | none | none |
- GpioIo resources carry no polarity. Firmware leaves GPIO 34/39/95/102 in GPIO mode, output,
  driven **high** (pinctrl debugfs). Unclaimed by Linux.
- Linux already creates I2C clients i2c-NVDA2810:00 (i2c-0) and i2c-NVDA2812:00 (i2c-4) from the
  first I2cSerialBus resource. No driver bound.

## MCLK: the blocker before a chip-ID read
- No master clock is described anywhere in ACPI (not on CAMF/CAMI/SENI).
- MT8901 pinctrl: CMMCLK0–4 can be muxed onto GPIO 24,30,31,33,34,37,39,42,43,47.
  None is currently in a CMMCLK mode. Note GPIO34 (campower) and GPIO39 (reset) are among them,
  but ACPI uses them as GPIOs. Best guess for CSI port 0: CMMCLK0 on GPIO30 (mode 2) — unverified.
- ISP1 _DSM returns CISP: clock name -> ID table, e.g. cammain 0x0A04, camtg 0x0A09 (camtg feeds CMMCLK),
  camla13 0x0A00, ... plus per-engine tables CLRA/CLRB/CLYA/CLM0/CLV0/... and LARB port tables LPRA/...
- power_wrap (NVDA6210) has \_SB.ISP1 with control_type **CTRL_NONE** (vs DSP3 = CTRL_BY_SCMI,
  feat 0xd, dev 0x1b), so mtk_send_power_control_req() rejects it. Linux has **no path to turn on
  camtg/cammain today**. On Windows nvCamsys presumably asks nvpep for these IDs via a custom PEP interface.

## Asks for the Windows side
1. Which pin/function carries the sensor MCLK, and at what rate: strings/registry of nvSeninf.sys,
   nvCamsys.sys, oem97.inf (look for "mclk", "cmmclk", "camtg", 19200000/24000000).
2. How nvCamsys requests clock IDs 0x0Axx from nvpep (PEP custom-request GUID/payload). If it is an
   SSPM SCMI message, its feat_id/dev_id would let Linux do the same via sspm_ci.
3. Reset/power polarity and power-on order from nvMIPICamSensor (the INF/driver for the sensor).

## Proposed next hardware step (needs Russ's OK; not done)
- Read the CAMF EEPROM at i2c-0 0x50 (i2cget/i2cdump, read only). EEPROMs don't need MCLK, so a
  response proves the module is powered and the I2C path works, before any clock work.

## Result: CAMF EEPROM read (2026-11-21, with Russ's OK)
- i2c-0 @0x50 ACKs. Receive-byte returned 0x01. With 16-bit addressing (w2 + r32 x8) the first
  256 bytes read cleanly and no dmesg errors appeared. Raw dump: camf-eeprom-0x50-first256.txt.
- Content is structured module data, not 0xff/0x00 fill: a header at 0x00 (01 ff 00 0b 01 10 00 40 ...),
  then from about 0x5b a long run of 16-bit values, probably lens-shading/calibration tables.
- Conclusion: camera module power is on (firmware leaves GPIO34 high) and the I2C0 path to the module
  works. The remaining blocker for the sensor at 0x10 is MCLK (see above).

## Result: OV08X40 chip ID read over I2C (no MCLK changes)
- i2c-0 @0x10, reg 0x300a (16-bit address) -> 0x56 0x08 0x58 = 0x560858 = OV08X40. Bus fine afterwards.
- So register access works as firmware leaves things (campower GPIO34 high, reset GPIO39 high).
  **Reset is active-low.** MCLK is still unexplained: either firmware leaves it running or the
  sensor's control interface doesn't need it. Streaming needs it either way.

## ov08x40 patch + glue written (built, not yet loaded)
- Source in camera-src-20261121/ (also /root/src/yoga9n-camera on the stick).
- 0001 adds NVDA2810 to ov08x40's ACPI IDs. yoga9n-cam.c supplies GPIO names/polarity, a
  19.2 MHz clock-frequency (v4l2 registers a dummy fixed clock) and a 4-lane/400 MHz endpoint.

## Result: ov08x40 BOUND on Linux (first camera driver on this machine)
- Load order: yoga9n-cam.ko, then modprobe videodev v4l2-fwnode v4l2-async mc, then ov08x40.ko.
- ov08x40 bound to i2c-NVDA2810:00 with no errors: power-on sequence, reset toggle and the driver's own
  chip-ID check (0x560858) all passed. Dummy regulators dovdd/avdd/dvdd, as expected.
- Sensor subdev is registered with v4l2-async and pending (debugfs pending_async_subdevices:
  "ov08x40 0-0010"). No /dev/v4l-subdev* until a CSI-2 receiver/bridge driver claims it.
- Runtime PM: suspended when idle; GPIO39 reset asserted (out lo, ACTIVE LOW); GPIO34 campower held high by glue.
- Harmless: "gpio-NNN (?): Failed to set debounce-timeout 0: -22" when the ACPI GpioIo lines are requested.
- Next: SENINF (NVDA2820) CSI-2 receiver + CAMSV DMA driver acting as the async notifier/bridge; MCLK question.

## SENINF driver: register reference found, stage-0 skeleton written
- MediaTek's own GPL ISP8 camsys driver is public: github.com/MiCode/MTK_kernel_modules, branch
  bsp-dali-v-oss (MT6991), path mtkcam/camsys/isp8/cam/ (mtk_cam-seninf-drv.c, mtk_csi_phy_3_0/
  mtk_cam-seninf-hw_phy_3_0.c 7.4k lines, mtk_cam-sv.c = CAMSV, per-block register headers).
  Its resource names match \_SB.SENI's MEMS table exactly (seninf-top, seninf-async-top, seninf-tm,
  seninf-outmux[_inner], seninf-csi-rxana-csia/b, -dphy, -cphy, -mac-top, -mac-csia, -sw-ppi,
  seninf-tsrec[-top], seninf-top-irq). This is the port base; mt8991 is that generation.
- MEMS decode (_CRS index, count): top 0, async-top 1, tm 2, outmux 3x14, outmux_inner 17x14,
  rxana-csia 31x3 (0x12A10000/18000/20000), rxana-csib 34x3, dphy 37x3, cphy 40x3, mac-top 43x3,
  mac-csia 46x3, sw-ppi 49x3, tsrec-top 52, tsrec 53x12, irqs 530 (top) / 531 (dev).
- The downstream driver needs MTCMOS power domains and ~20 clocks (clk_cam_seninf, clk_cam_camtg,
  clk_top_seninf0-5, ...). Linux has no control over these here, so no MMIO access yet: on MTK an
  access to an unpowered block can hang the bus.
- n1x-seninf.c (stage 0): binds NVDA2820, logs the MEMS map, registers /dev/media + a bridge subdev,
  and acts as the v4l2-async notifier for the sensor graph. yoga9n-cam.c now also adds the SENINF
  side of the graph (port@0 endpoint <-> ov08x40 endpoint). Built, not loaded yet.

## Result: stage-0 SENINF bridge loaded (2026-11-21)
- Load: rmmod ov08x40 yoga9n-cam; insmod yoga9n-cam.ko ov08x40.ko n1x-seninf.ko (V4L2 core modules already loaded).
- n1x-seninf bound NVDA2820, _DSM SoC = "mt8991", MEMS map decoded as above; IRQs map to Linux 274 (top) / 275 (dev).
- Graph works: port 0, CSI-2 D-PHY, 4 lanes; notifier bound "ov08x40 0-0010", subdev nodes registered.
- /dev/media0 (driver n1x-seninf), /dev/v4l-subdev0 = n1x-seninf, /dev/v4l-subdev1 = ov08x40.
  media-ctl: ov08x40:0 -> n1x-seninf:0 [ENABLED,IMMUTABLE], sensor fmt SGRBG10_1X10/3856x2416.
- Sensor controls usable: exposure, flips, vblank/hblank, analogue/digital gain, test_pattern (5 entries),
  link_frequency 400 MHz, pixel_rate 320 MHz. Frame sizes 3856x2416, 3856x2176, 1928x1208 (4-lane).
- No SENINF register access. Next: camera power domain + clocks (MTCMOS / camtg), then PHY 3.0 + CSI-2 MAC.

## Camera power/clock research (source only) + IOMMU (2026-11-21)

### IOMMU: not a blocker
- IORT does map the camera engines (contrary to the earlier note): SMMUv3 @0x33200000 serves NVDA2801 (ISP1,
  contains CAMSV), NVDA2802/2803, NVDA2808 (CCU), NVDA2830 (MAE), NVDA2860 (CMA0). Every group is type
  **identity** (passthrough). A CAMSV driver on NVDA2801 can use ordinary dma_alloc_* with no SMMU/LARB setup.

### N1X camera block = MediaTek MT6991 camera block
- MT6991 DT (MiCode/MTK_kernel_device_modules, bsp-dali-v-oss, arch/arm64/boot/dts/mediatek/mt6991.dts):
  seninf-top @0x3a300000, async-top 0x3a301000, tm 0x3a302000, cam_main_r1a @0x3a000000: the same addresses as
  \_SB.SENI / \_SB.ISP1. So MediaTek's ISP8 driver plus the mt6991 clk/pd code are the right references.
- MT6991 SENINF needs power-domains CAM_VCORE, CAM_MAIN, CSI_BS_RX, CSI_LS_RX from `hfrpsys`
  (MMPC hardware voter @0x31b50000, mtk-scpsys-mt6991-mmpc.c) and clocks: cam_vcore CGs, cam_main
  SENINF/CAM/CAMTG CGs (cam_main_r1a syscon @0x3a000000, inside ISP1's MMIO), topckgen2 SENINF0-5 muxes, mmdvfs.
- Mainline MT8196 (same generation; in NV-Kernels drivers/pmdomain/mediatek/mt8196-pm-domains.h) drives HFRP
  HW-voter domains by direct register set/clr (csi-bs-rx / csi-ls-rx are bits 5/6 at set 0x220/clr 0x224,
  done 0x142C). It has no CAM domains upstream yet.
- **N1X ACPI describes none of MT6991's MM power-controller ranges** (no 0x31b0xxxx/0x31b5xxxx/0x31a8xxxx).
  \_SB.HFRP (MTK00055) here is a small mailbox: MMIO 0x311C0000 (0x100) + doorbells 0x311C0100..010C,
  0x31270074, IRQ 0x324. Its _STA is 0 whenever _OSI("Windows 2022") is true, i.e. on Windows AND on default
  Linux. It looks intended for an OS that opts out (NVIDIA's Linux?). No driver for MTK00055 in NV-Kernels.
- ISP1 has one region outside 0x3Axxxxxx: **0x31160000 (4 KB)**. Not in the MT6991 DT. It may be how
  nvCamsys votes camera power/clock on N1X.
- Pin observation: CMMCLK-capable pins 30 (CMMCLK0), 37 and 42 (CMMCLK3) are in mux mode 1
  "B0_TP_GPIO*_AO" (a coprocessor-owned GPIO function), unlike the other candidates (mode 0).
  Possibly handed to an always-on coprocessor by firmware.

### Questions for the Windows side (sharpened)
1. What does nvCamsys/nvSeninf write at 0x31160000, and does it send nvpep custom requests when the camera
   starts? (Trace or strings: "mtcmos", "cam_main", "cam_vcore", "hwv", "vote", "0x31160000".)
2. Which pin/mux carries sensor MCLK (pins 30/37/42 in TP_GPIO mode are suspects), and its rate.
3. Is \_SB.HFRP used by anything on Windows (driver for MTK00055)?
