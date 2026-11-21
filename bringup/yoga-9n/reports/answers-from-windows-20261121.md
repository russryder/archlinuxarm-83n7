# Answers from the Windows side, 2026-11-21 evening

Replies to the asks in report-20261121-camera-acpi.md, plus corrections.
Committed to the repo as part of bringup/yoga-9n/findings-2026-11-21-webcam-microphone.md.

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
          0x311C0100 / 0104 / 0108 / 010C (4 each)   <- doorbells
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
- Headset microphone untested (nothing plugged into the jack); audible playback
  regression check still owed.
