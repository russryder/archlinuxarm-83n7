# Yoga 9n: webcam and microphone — hardware analysis and plan

Produced 2026-11-21 from the Windows side of the target machine (Lenovo Yoga 9
2-in-1 16N1X11, MT 83N7, BIOS SDCN77WW). Nothing here was tested on Linux.

## How this was established

- ACPI tables dumped live via `GetSystemFirmwareTable` and decompiled with
  `iasl`. DSDT: `LENOVO CB-01` rev 4, 310717 bytes, 58956 lines of ASL.
- Windows driver INFs, driver-store payloads, and `strings` over the kernel
  drivers (`nvCamsys.sys`, `nvCamAvs.sys`, `nvSoundWireControllerDrv.sys`,
  `libnvcam_mw.dll`).
- Upstream state checked against the Linux 7.3 source tree, a full file
  listing of NVIDIA's `NV-Kernels` tree, and lore mirrors.

Line references are into the decompiled DSDT. The ACPI binaries and anything
derived from them are not redistributable and are excluded by `.gitignore`.

> ## Corrected 2026-11-21 14:32 PST
>
> Two conclusions in this document, and two more in the stick's
> `reports/report-20261121-1323-hfrp.md`, are now known wrong. The corrections
> are in **`reports/report-20261121-1432-windows-camera-power.md`**; read that
> before acting on anything below about camera power.
>
> 1. The four `0x311C01xx` entries in HFRP's `_CRS` are **not four doorbells**.
>    They are one mailbox register set -- `IN_STATUS`/`IN_SET` `+0x100`,
>    `OUT_STATUS`/`OUT_SET` `+0x104`, `IN_CLR` `+0x108`, `OUT_CLR` `+0x10c` --
>    read straight out of the live Windows registry under
>    `Enum\ACPI\NVDA2801\...\Device Parameters\Mbox0`. There is one
>    AP -> coprocessor doorbell, `IN_SET`.
> 2. **Un-gating `\_SB.HFRP` is not the unblock.** It is harmless and already
>    applied, but the camera does not need the mailbox. `hfrpsys` is MediaTek's
>    name for the camera **power-domain controller**
>    (`power-controller@31b50000`, compatible `mediatek,mt6991-hfrpsys-hwv`),
>    and its GPL driver is `drivers/soc/mediatek/mtk-scpsys-mt6991-mmpc.c` --
>    vendored at `camera/upstream/pm-domain/`. The earlier note that porting it
>    was a dead end because its registers are absent from N1X's ACPI was a
>    false negative: absent means unclaimed, not missing.
>
> Also settled: there is no HFRP firmware anywhere in the Windows driver store,
> and nothing on Windows loads one, so stop looking for a blob.

## Summary

| | Microphone | Webcam |
|---|---|---|
| Blocker | configuration only | no driver exists, anywhere |
| Kernel work needed | none | SENINF + CAMSV capture driver |
| Status | fix committed, unverified | not started |

## The peripheral silicon is MediaTek

The ACPI IDs are `NVDA*`, but the uncore is MediaTek, and the DSDT says so
outright: `\_SB.SENI._DSM` returns `"mt8991"` and `"mtk-csi-phy-3-0"`.

Corroborating evidence:

| Evidence | Where |
|---|---|
| `seninf-top`, `seninf-csi-mac-csia`, `seninf-tsrec`, `camsv`, `raw`, `pdp`, `uisp` | `\_SB.SENI` register map and `OMUX` |
| `imgo_r1`, `rawi_r2`, `lsci_r1`, `bpci_r1`, `drzh1r1`, `awbo_r1`, `cqi_r1` | `\_SB.ISP1` DMA port names (MediaTek ISP7) |
| `SCPSYS`, `IMGSYS`, `CCUSYS`, `ADSPSYS`, `mtcmos` | power domains |
| `EintBaseIdx`, `TotalEintPins` | `\_SB.GIO0` (`NVDA9221`) — MediaTek EINT |
| `AFE_ADDA_UL0_SRC_CON0`, `AFE_CONN018_0`, `apll1`/`apll2` | strings in `nvSoundWireControllerDrv.sys` |
| `mt8991_pipe_reset`, `mtk_cam_job_update_clk`, `mtk_cam_ctrl_reset_sensor`, `__qof_mtcmos_raw_voter` | symbols in `nvCamsys.sys` |
| `mcam::IMtkcamDevice`, `NSCam`, `/data/vendor/camera_dump/`, `...\hardware\mtkcam-android\...\P1Proc.cpp` | strings in `libnvcam_mw.dll` |

`nvCamsys.sys` is a port of MediaTek's own Linux camera driver with symbols
intact, and its userspace is MediaTek's Android camera HAL recompiled for
Windows. The build path in the binary is
`D:\source_code\0718\t25x\N1xCamera-fromNV\nvCamera\mwcore\nvDevicemft\hardware\mtkcam-android\...`.

**Implication: obtaining MediaTek's downstream mt8991 / Genio kernel sources
would turn the camera from reverse engineering into a port.** That is worth
more than any amount of register poking and should be pursued first.

## Microphone

### Chain

```
DMIC array -> CS42L43 (SoundWire peripheral, mfg 0x01FA, part 0x4243)
4x CS35L56 amps (part 0x3556) at uid 0,1,4,5
   -> MediaTek AFE SoundWire manager  \_SB.CNT0 NVDA9100 (_SUB 380217AA)
      MMIO 0x1A6A0000 + 0x1A6B0000, IRQ 722/723, afe-base 0x1A690000
   -> MediaTek AFE -> DMA
```

SoundWire 1.2, 6.144 MHz, 64x8 frame, 2 links. Bus properties are plain MIPI
DisCo (`mipi-sdw-*`), the format `drivers/soundwire/mipi_disco.c` parses.

### Why it was dark, and what changed

Nothing kernel-side was missing. `mt8901-acp-sdw-legacy-mach.c` already
declares capture front ends `UL0`–`UL5` and `VUL_CM0`–`2` in
`mt8901_fe_dais[]`, and `create_sdw_dailinks()` builds `SDW%d-CAPTURE`
backends with `capture_only`. Capture was blocked in two config files:

1. `Yoga9n-playback.conf` exposed no capture device — its own header said
   *"No microphone/capture device is exposed."*
2. `51-h7607a-playback.conf` set `node.disabled = true` for every
   `~alsa_input.*` node.

Both were a scoping measure taken while playback was being brought up — Russ
confirmed on 2026-11-21 that it was *"a getting a working bootable linux
first decision"*, not a privacy policy.

Fixed in this commit series: `Yoga9n-hifi.conf` replaces
`Yoga9n-playback.conf` (which is retained, unused), and the input-disable rule
is removed from `51-h7607a-playback.conf`.

### Capture routing

Taken from NVIDIA's upstream `HiFi-cs42l43-cs35l56x4.conf`, alsa-ucm-conf
**PR 862** (author `dcemin-nv`, still open) at commit
`7d3555a754936ce073ce5fe3d623294d81dd5c66` — the same commit the playback-only
file was derived from, so the two are consistent.

- verb: `PDI13 Mux` = `DP7`, `O020 I180 Switch` = 1, `O021 I181 Switch` = 1
  (`capture: UL1 <- O020/O021 <- PDI13 <- host DP7`)
- internal mics: CS42L43 **Decimator 3 and 4** via `DP1TX1`/`DP1TX2`
- headset mic: **Decimator 1** in `ADC` mode, sharing the same `DP1TX*`
  inputs, hence the reciprocal `ConflictingDevice`
- capture PCM `hw:${CardId},8`

PCM 8 is consistent with this card: `mt8901_fe_dais[]` is
`DL0,DL1,DL2,DL3,DL4,DL5,DL_24CH,UL0,UL1,...`, so `UL1` is index 8, matching
the proven `hw:X,0` speakers (DL0) and `hw:X,1` headphones (DL1).

### Verification still owed

```bash
arecord -l                                  # expect a capture PCM at index 8
amixer -c 0 controls | grep -iE 'PDI13|O020|O021|Decimator|Headset Mic'
arecord -D hw:0,8 -f S16_LE -r 48000 -c 2 -d 5 /tmp/mic.wav && aplay /tmp/mic.wav
alsaucm -c hw:0 list _devices               # expect Speaker, Headphones, Mic, Headset
wpctl status                                # expect a source
speaker-test -c 2 -t sine -l 1              # playback regression, low volume
```

The capture `cset`s live in the shared `SectionVerb`, so a wrong control name
there could break playback as well as capture — hence the regression check.
The two values most likely to be wrong are a control name and the PCM index;
trust `amixer`/`arecord -l` over the committed file and correct it.

### Not addressed

- **CS35L56 speaker tuning.** Which supplier (`spkid0` vs `spkid1`) this unit
  carries is still unknown, and upstream `linux-firmware` has no Lenovo
  `17aa:3802` entry, so amps may be running untuned ROM defaults. Check which
  filename `cs35l56` actually requested in `dmesg`.
- **Bluetooth HFP/HSP microphone roles** remain disabled in
  `51-h7607a-playback.conf`; that is a separate decision from the internal mic.
- **SDCA descriptors.** The DSDT describes both codecs purely as generic MIPI
  SDCA peripherals — there are **no `cirrus,*` properties anywhere**. These are
  informational on Linux and can be ignored: the generic SDCA class driver
  (`sound/soc/sdca/sdca_class.c`, v6.19) matches only Cirrus parts
  `0x4245/0x4249/0x4747`, not `0x4243`, so this CS42L43 is driven by the
  native `cs42l43` MFD + codec driver (v6.6) where the DMICs are native
  decimator widgets. `cs35l56` landed v6.4. For reference, the SDCA mic
  function (entity group `4x`) is
  `IT 41 -> FU 41 -> MFPU 41 -> XU 42 -> SU 43/44/45 -> OT 43/44/45`, with
  `CS 41` clock source, `PDE 47` power domain, and a 20-entry
  `mipi-sdca-function-initialization-table` (`IBUF`, DSDT line 58754).

## Webcam

### Sensors

| | Front | IR |
|---|---|---|
| ACPI node | `\_SB.CAMF` (`NVDA2810`, `_UID 0xD7`) | `\_SB.CAMI` (`NVDA2812`, `_UID 0xD8`) |
| Sensor | **OmniVision OV08X40** (`ov08x40_mipi_raw`) | **ST VD55G0** (`vd55g0_mipi_raw`) |
| I2C bus | `\_SB.I2C0` | `\_SB.I2C4` |
| sensor addr | 0x10 @ 400 kHz | 0x10 @ 400 kHz |
| EEPROM | 0x50 | 0x50 |
| extra | — | IR LED driver @ 0x63 |
| GPIOs (`\_SB.GIO0`) | 34 (0x22) `campower`, 39 (0x27) `reset` | 102 (0x66) `campower`, 95 (0x5F) `reset` |
| CSI port | 0 | 2 |

`reset` is **active low** — confirmed on hardware: firmware leaves GPIO 34/39/95/102
in GPIO mode, output, driven high, and the sensor answers on I2C in that state.
`GpioIo` resources carry no polarity, so a driver must assert this itself.

Both via Windows service `nvMIPICamSensor`, `_DSM` UUID
`65da2d87-2b24-487e-aae5-ec266034dca2` (fn 1 `csiport`, 2 GPIO names,
3 I2C role names, 4 AOV info — AOV reports `aov_present = 0`, vendor
`Lattice`). The platform driver also carries tuning for `ov02c`, `imx519` and
`vd55g1`, which are other sensor options for this SoC, not fitted here.

### Pipeline

| Node | HID | Windows service | MMIO | Notes |
|---|---|---|---|---|
| `SENI` | NVDA2820 | nvSeninf | 0x3A100000–0x3A3D0000, 65 regions, 2 IRQ | SENINF + CSI PHY 3.0, 6 ports |
| `ISP1` | NVDA2801 | nvCamsys | 0x3A000000–0x3A998000, 49 regions, 12 IRQ | ISP Pass 1; contains CAMSV |
| `ISP2` | NVDA2802 | nvImgsys | 0x34000000 | ISP Pass 2 |
| `ISP3` | NVDA2803 | nvImgsysSecure | 0x34800000 | **secure** |
| `GCE0` | NVDA2840 | nvCmdq | 0x33110000 | MediaTek GCE/CMDQ |
| `GCE1` | NVDA2841 | nvCmdqSecure | 0x33120000 | **secure** |
| `CCU0` | NVDA2808 | nvCCU | 0x3C080000 | **secure**, camera control coproc |
| `PDA` | NVDA2850 | nvPda | 0x3A750000 | phase-detect AF |
| `MAE0` | NVDA2830 | nvMAE | — | face detect |
| `CMA0` | NVDA2860 | nvMemAllocator | — | |
| `CAV0` | NVDA2800 | nvCamAvs_C9 | — | AVStream |

The ACPI **SDEV** (Secure Devices) table, OEM table ID `ISPESS`, fences
exactly three of these to the secure world — `\_SB.ISP3` @ 0x34800000,
`\_SB.GCE1` @ 0x33120000, `\_SB.CCU0` @ 0x3C080000 — which is the Windows
Hello path. **The non-secure path is not fenced.**

### What exists upstream

- **No NVIDIA ISP driver has ever existed in Linux**, any generation.
  `drivers/staging/media/tegra-video/` is still staging and holds only
  `tegra20.c` and `tegra210.c`: CSI/VI only, no ISP, nothing for Xavier/Orin.
- Nothing camera-related in NV-Kernels either (the tree this stick's
  `7.0.0-1022-nvidia` kernel comes from).
- No public ISP register documentation; NVIDIA staff on record that no ISP
  source is published. No reverse-engineering project targets this pipeline.
- `drivers/media/i2c/ov08x40.c` **is** upstream (**v6.2**) but binds on ACPI
  HID `OVTI08F4`, which this DSDT does not expose — the sensor sits behind
  `\_SB.CAMF` with raw I2C/GPIO resources, so an I2C client must be
  instantiated by glue code.
- The IR sensor driver **does not exist**. Upstream has `vd55g1.c` (v6.16,
  covering `st,vd55g1/vd55g4/vd65g4`, and DT-only with no ACPI match table),
  not VD55G0.

### The plan: skip the ISP

`\_SB.SENI`'s `OMUX` property lists 14 output-mux routes: **6 x `camsv`**,
3 x `raw`, 4 x `pdp`, 1 x `uisp`. `camsv` is MediaTek's plain CSI-to-DRAM DMA
engine; **6 CAMSV units sit at 0x3A500000–0x3A54A000** (3 x 4 KB regions each)
within ISP1's window. So the hardware can dump raw Bayer straight to memory
with no ISP involvement.

1. Instantiate `ov08x40` on I2C0 @ 0x10, driving `campower`/`reset` GPIOs.
2. Write a SENINF / CSI-PHY driver for 2 of the 6 ports.
3. Write a CAMSV DMA driver.
4. Debayer with **libcamera's software ISP**.

Skip ISP P1/P2, GCE, CCU, PDA and MAE entirely. Expect mediocre image quality
but a working camera. Do **not** attempt the real ISP: Windows needs a 19 MB
per-sensor SQLite tuning database (`ov08x40_mipi_raw_ISP_param.db`) plus closed
3A libraries (`libnvcam_aaa_isp.dll`, `libaaa_ae/awb/af/tnc.dll`).

### DMA: not an obstacle after all

IORT declares 5 SMMUv3 instances (0x13000000, 0x13800000, 0x14900000,
0x33200000, 0x35000000) and exactly **one** named component: `\_SB.USB0`. The
camera engines have no StreamID mapping in ACPI.

That turns out to help rather than hurt. Because nothing describes a
translation for them, Linux places the camera devices in **identity
(passthrough)** IOMMU groups — verified live on the stick for `NVDA2801`
(ISP1, which contains CAMSV), `NVDA2802`/`NVDA2803`, `NVDA2808` (CCU),
`NVDA2830` (MAE) and `NVDA2860` (CMA0), all served by the SMMUv3 at
0x33200000. So a CAMSV driver can use ordinary `dma_alloc_*` with no SMMU or
LARB setup at all.

An earlier revision of this file called this a blocker needing SMMU bypass or
direct LARB programming. The bypass is simply what happens by default. The
LARB information in `\_SB.ISP1`'s `_DSM` (port names `l13cqia`, `l25img0`, …
and clocks `clarb13`, `camla13`) is still how Windows drives it, and would
matter only if translation were ever enabled.

## Platform notes

Clocks and power do **not** go through FF-A. They run through MediaTek's
`power_wrap` (`NVDA6210`, Windows `nvpep`) over an SSPM mailbox (`NVDA8400`) —
SCMI-shaped messages, but not Linux's `arm_scmi` stack. FF-A (`\_SB.FFA0`,
`ARML0002`) carries **EC services**; Lenovo's SSDT `LfcECCom`
(`RECM`/`WECM`/`CECB`/`RWEC`) reaches the EC through `\_SB.FFA0.FFAC`.

Mainline has none of this platform: a tree-wide search for `NVDA[0-9A-F]{4}`
across Linux 7.3 returns only Tegra/Grace IDs. `i2c-mt65xx.c` has zero ACPI
support upstream. The enablement is out of tree in
`github.com/NVIDIA/NV-Kernels`: `drivers/soundwire/mediatek/mtk-sdw.c`
(matching `NVDA9100`), `sound/soc/mediatek/mt8901/`,
`sound/soc/sof/mediatek/mt8901/`, `pinctrl-mt8901.c`, ACPI-enabled
`i2c-mt65xx.c`, `drivers/soc/mediatek/power_wrap/`,
`drivers/soc/mediatek/sspm_ci/`, `drivers/platform/arm64/nvidia-ffa-ec.c`.

NVIDIA's `mtk-sdw-mach.c` documents this exact topology: *"Config 1: SDW0 =
4x CS35L56 (amps, aggregated), SDW1 = CS42L43 (jack codec)."*

The only upstream posting touching this platform is *"Add pinctrl and GPIO
support for MediaTek MT8901"* (Lei Xue, 3 patches, 2025-11-25); reviewers asked
for DT alongside ACPI and it is **not merged**.

### Related work

- `github.com/jerryabramson/yoga-rtx` — this exact machine (16N1X11, MT 83N7).
  Reports speakers and headphones working via alsa-ucm-conf PR 862, internal
  mics not working, CS35L56 tuning broken for want of a Lenovo `17aa:3802`
  entry in `linux-firmware`, and does not mention the camera.
- `github.com/johannhartmann/asus-proart-p16-rtx-spark-linux` — the lineage of
  this tree's EDK2-shell boot scheme and `h7607a-acpi.cpio`.
- `github.com/Th0rgal/awesome-rtx-spark` (`docs/linux.md`) — status tracker;
  records NVIDIA listing native N1X Linux as "deferred".

---

# Round 2 — results from the stick, and answers from Windows (2026-11-21 evening)

## Status

| Item | State |
|---|---|
| Internal microphone | **working** — candidate UCM installed unchanged |
| CS35L56 speaker tuning | **resolved: spkid1** |
| `ov08x40` driver | **bound**, chip ID `0x560858` read over I2C |
| SENINF stage-0 bridge | loaded; `/dev/media0`, media graph links sensor to bridge |
| Camera streaming | blocked on camera power/clock enablement |

Confirmed predictions: `UL1` = capture device 8; every control name in the
committed UCM exists on the card; `cs42l43 Microphone` and
`cs42l43 Headset Microphone` do **not** exist, so following commit `7d3555a`
instead of PR HEAD was the correct call.

Corrections folded into the sections above: the card is **card 1**
(`mt8901soundwire`), CAMI's `campower` is **GPIO 102**, `reset` is **active
low**, and DMA is not a blocker.

Speaker tuning: all four CS35L56 load
`cirrus/cs35l56-b0-dsp1-misc-17aa3802-spkid1.wmfw` plus
`-spkid1-l1u{0,1,4,5}.bin`, reporting "Calibration applied", Tuning PID
0x2690 / SID 0x1 / TID 0x723. The `17aa:3802` SSID from `audio-identity.patch`
is doing its job.

## Answer: how Windows turns on camera power and clocks

**Not through the PEP.** `nvpep.sys` is an SCMI driver (`DMF_Scmi_*`,
`DMF_Scmi_Tinysys_Common_Get`/`_Set`, `ScmiTarget_Interrupt*`, custom request
types `TCustom1`/`TCustom2`) talking to MediaTek "tinysys" coprocessors. But
`power_wrap` lists `\_SB.ISP1` as **`CTRL_NONE`**, so the camera is not a PEP
client. Chasing an SCMI/PEP path for camera power is a dead end.

**It goes through HFRP IPI.** `nvCamsys.sys` contains `hfrp_ipi_init`,
`__qof_mtcmos_raw_voter`, `mtk_cam_vcore_probe`, `qof_ddren_setting`,
`update_sen_expo_qof_voter`, and the string "failed to acquire cam vcore
handle". So camera power and clocks are voted by the camera driver itself over
an HFRP mailbox, not requested from a central power service.

`0x31160000` is **one of `\_SB.ISP1`'s own `_CRS` regions** (4 KB, DSDT line
20513, followed by shared IRQ `0x1FF` = 511). Given `hfrp_ipi_init`, and that
this address sits in the same `0x311xxxxx` block as HFRP's own mailbox at
`0x311C0000`, this is very likely the camera's HFRP IPI / hardware-voter
window. **Inference, not verified** — no MMIO trace was taken.

### The unblock: `\_SB.HFRP` is gated off, and the repo already knows how to un-gate it

```
Device (HFRP) {
    Name (_HID, "MTK00055")
    _CRS: IRQ 0x324; 0x311C0000 (0x100); 0x31270074 (4);
          0x311C0100 / 0104 / 0108 / 010C (4 each)   <- NOT doorbells: see
              correction above. One mailbox register set:
              +0x100 IN_STATUS/IN_SET, +0x104 OUT_STATUS/OUT_SET,
              +0x108 IN_CLR, +0x10c OUT_CLR
    Method (_STA) { If (_OSI ("Windows 2022")) { Return (Zero) }
                    Else { Return (0x0F) } }
}
```

Verified on Windows: **no `MTK*` device is enumerated at all**, so nothing on
Windows uses the HFRP ACPI device — Windows reaches the same hardware through
ISP1's own resources instead. The `_STA` gate means HFRP is deliberately
exposed **only to an OS that does not claim `Windows 2022`**, which reads like
it was left for NVIDIA's own Linux.

Linux answers true to that `_OSI` string by default, so HFRP is hidden on the
stick too. **This repository already contains the exact mechanism to fix
that.** `01-platform/acpi/payload/provenance/hardware/acpi_builder.py` walks
the AML for every device whose `_STA` is that gate (`gated_devices()`) and
neutralises the predicate by overwriting it with `\x00` plus `\xa3` padding
(`GATED_STA` -> `PATCHED_STA`). It currently applies that to SSPM only, via
`sspm_sta()` keyed on `_HID` `NVDA8400`. And `sspm-patch.json` **already lists
HFRP / MTK00055** among the gated devices it found.

Two ways forward, in preference order:

1. Generalise `patch_dsdt()` to patch HFRP's `_STA` as well as SSPM's — a
   small change to code that already does exactly this, keeping the override
   self-verifying and pinned to SDCN77WW.
2. Boot with `acpi_osi="!Windows 2022"` (what `jerryabramson/yoga-rtx` does).
   Cruder: it un-gates `SVP0`, `NH1X` and `NMAP` at the same time and changes
   `_OSI`-dependent behaviour platform-wide.

This touches the ACPI override and therefore boot, so it is left as a
proposal rather than done — safety rule 2.

## Answer: the sensor MCLK question

**The Windows sensor driver never touches a clock.** `nvMIPICamSensor.sys`
contains only `campower`, `reset` and `g_cmd_sensor_in_reset`. There is no
`mclk`, no `cmmclk`, and no `19200000`/`24000000` literal anywhere in it — nor
in `nvSeninf.sys` or `nvCamsys.sys`.

The clock is **CAMTG, owned by SENINF**: `nvSeninf.sys` has
`mtk_cam_seninf_set_camtg`, `_set_camtg_with_dest_idx`,
`mtk_cam_ddi_seninf_set_camtg{,_camsv,_multiraw}`,
`mtk_cam_seninf_set_new_camtg`, `mtk_cam_seninf_forget_camtg_setting`,
`seninf_clk_enable`, `enable_clock`, `set_clock_rate` and
`enable_power_domain`. `\_SB.ISP1`'s `_DSM` `CISP` table names it: `camtg` =
clock ID **0x0A09** (alongside `cammain` 0x0A04, `qof` 0x0A1D, `bwr` 0x0A20).

So the hunt for a `CMMCLK` pin/mux (pins 30/37/42) is a dead end for the
sensor path — nothing in the Windows sensor driver programs one. MCLK is not a
separate problem: it is the same camera clock-enablement problem as everything
else, and it resolves through CAMTG once HFRP voting works. That also explains
why the chip-ID read succeeded with firmware's default pin state.

## Bonus: SENINF bring-up order, from `nvSeninf.sys`

Useful when porting MediaTek's ISP8 `mtk_cam-seninf-hw_phy_3_0.c`, since these
are the Windows port's names for the same steps, in this order:

```
csirx_phyA_power_on
csirx_dphy_init
csirx_dphy_init_deskew_setting
csirx_dphy_setting          /  csirx_cphy_setting
csirx_mac_top_setting
csirx_mac_csi_setting
```

plus out-mux handling (`mtk_cam_seninf_set_outmux_pixel_mode`,
`_set_outmux_ref_vsync{,_inner}`, `_set_outmux_cfg_done`,
`mtk_cam_get_outmux_sel`, `mtk_cam_seninf_outmux_put`,
`mtk_cam_seninf_streaming_mux_change`), CSI MAC measurement helpers
(`mtk_cam_csi_mac_hv_hb_*`) and `mtk_cam_ddi_seninf_set_secure`.
`nvSeninf.sys`'s `_DSM` SoC string is `mt8991`, matching `\_SB.SENI`.

## Port base: MediaTek's own GPL ISP8 driver is public

Found on the stick side, and the single most useful resource for the camera
work: `github.com/MiCode/MTK_kernel_modules`, branch `bsp-dali-v-oss`
(MT6991), path `mtkcam/camsys/isp8/cam/` — `mtk_cam-seninf-drv.c`,
`mtk_csi_phy_3_0/mtk_cam-seninf-hw_phy_3_0.c` (~7.4k lines), `mtk_cam-sv.c`
(CAMSV), and per-block register headers. Its resource names match
`\_SB.SENI`'s `MEMS` table exactly.

Corroborating: MT6991's DT (`MiCode/MTK_kernel_device_modules`,
`arch/arm64/boot/dts/mediatek/mt6991.dts`) puts `seninf-top` at 0x3A300000,
`async-top` 0x3A301000, `tm` 0x3A302000 and `cam_main_r1a` at 0x3A000000 —
**the same addresses as `\_SB.SENI` and `\_SB.ISP1` here.** N1X's camera block
is the MT6991 camera block, so MediaTek's ISP8 driver plus the mt6991 clock
and power-domain code are the correct references. This is a port, not a
reverse-engineering job.

Caveat carried from the stick: MediaTek's driver expects MTCMOS power domains
and ~20 clocks (`clk_cam_seninf`, `clk_cam_camtg`, `clk_top_seninf0-5`, …).
Until HFRP voting works, do not touch SENINF MMIO — on MediaTek SoCs an access
to an unpowered block can hang the bus.

## SENINF MEMS decode

`\_SB.SENI`'s `MEMS` package maps names to `_CRS` index and count:

| Block | `_CRS` index | count |
|---|---|---|
| `seninf-top` | 0 | 1 |
| `seninf-async-top` | 1 | 1 |
| `seninf-tm` | 2 | 1 |
| `seninf-outmux` | 3 | 14 |
| `seninf-outmux_inner` | 17 | 14 |
| `seninf-csi-rxana-csia` | 31 | 3 (0x12A10000/18000/20000) |
| `seninf-csi-rxana-csib` | 34 | 3 |
| `seninf-csi-dphy` | 37 | 3 |
| `seninf-csi-cphy` | 40 | 3 |
| `seninf-csi-mac-top` | 43 | 3 |
| `seninf-csi-mac-csia` | 46 | 3 |
| `seninf-csi-mac-sw-ppi` | 49 | 3 |
| `seninf-tsrec-top` | 52 | 1 |
| `seninf-tsrec` | 53 | 12 |

IRQs: 530 (`seninf-top-irq`), 531 (`seninf-dev-irq`) — Linux 274 / 275 on the
stick.

## Still open

- The 19.2 MHz figure in `yoga9n-cam.c` is the glue's own assumption (it
  registers a dummy fixed clock to satisfy `ov08x40`); it is **not** confirmed
  as the real CAMTG rate.
- No MMIO trace of what `nvCamsys` writes at `0x31160000`. That needs
  kernel-level tracing on Windows, not attempted.
- The kernel source tree for `7.0.0-1022-nvidia-yoga` is not in this
  repository — the running kernel was built on the stick itself. The stick has
  an approximated headers tree that builds and loads modules successfully.
- Headset microphone untested (nothing plugged into the jack). The audible
  playback regression check is **done**: speakers confirmed still working
  after capture was enabled, so the shared-SectionVerb change is safe.
