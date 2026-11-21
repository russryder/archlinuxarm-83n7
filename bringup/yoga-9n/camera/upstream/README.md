# Vendored MediaTek sources for the Yoga 9n camera port

These are **third-party GPL-2.0 kernel sources**, copied verbatim, not written
here. They are vendored because they are the port target for camera power and
clocks on this machine, and because the trees they come from are vendor code
dumps that have a habit of disappearing.

## Why these files

N1X's camera block **is** MediaTek MT6991's. Every one of `\_SB.ISP1`'s 49
`_CRS` memory descriptors but three resolves 1:1 to a named `reg` in
MediaTek's own `mt6991.dts` — see
`../../reports/report-20261121-1432-windows-camera-power.md` §5b for the full
index table. The Windows driver `nvCamsys.sys` is itself a port of this tree:
its `__qof_mtcmos_raw_voter` disassembles to `mtk_cam-qof.c`'s
`__qof_mtcmos_raw_voter` constant for constant (same register offsets, same
50 µs poll delay, same 600 µs timeout). So this is a port, not a
reverse-engineering job, and these are the authoritative sources.

## Contents and provenance

| path | bytes | SHA-256 (first 16) |
|---|---|---|
| `isp8-qof/mtk_cam-qof.c` | 34514 | `3ebeee45a043b072` |
| `isp8-qof/mtk_cam-qof.h` | 2665 | `8e4beef0d4674973` |
| `isp8-qof/mtk_cam-qof_regs.h` | 44628 | `1b5649b71285271f` |
| `pm-domain/mtk-scpsys-mt6991-mmpc.c` | 36680 | `5db477a0411992ba` |
| `pm-domain/mt6991-power.h` | 3931 | `5a7ccd025072a4a2` |

`isp8-qof/` — from `rsuntk/android_kernel_samsung_a05m-vendor_modules`, branch
`master`, path `mtkcam/camsys/isp8/cam/`. The identical files appear in
`MiCode/MTK_kernel_modules`, `moto-mediatek-devs/android_kernel_motorola_lamu-mediatek_modules`,
`moto-mt6893/android_kernel_motorola_lyriq-mediatek_modules`,
`xiaomi-klee-devs/android_vendor_mediatek_kernel_modules`,
`Mayuri-Chan/kernel_xiaomi_gale-mediatek_modules` and
`mt6899-devs/android_vendor_mediatek_kernel_modules`, so the code is well
mirrored even if any one repo goes away.

`pm-domain/` — from `MiCode/MTK_kernel_device_modules`, branch `bsp-dali-v-oss`,
paths `drivers/soc/mediatek/mtk-scpsys-mt6991-mmpc.c` and
`include/dt-bindings/power/mt6991-power.h`.

Fetched 2026-11-21.

## Deliberately not vendored

- **`arch/arm64/boot/dts/mediatek/mt6991.dts`** (660 KB, same
  `MiCode/MTK_kernel_device_modules` tree and branch). Too large to be worth
  carrying; every excerpt the port needs is quoted in the report, and a local
  copy sits at `yoga9n-linux\upstream\dt\` on the 2 TB data drive and at
  `/boot/yoga9n-notes/upstream/dt/` on the live stick's ESP.
- **`drivers/clk/mediatek/clk-mt6991-cam.c`** — same tree, needed at step 3 of
  the plan. Fetch when you get there.
- **`nvCCU.img`** — the CCU coprocessor firmware lifted from this machine's
  Windows driver store. NVIDIA binary, redistribution rights unclear, so it
  stays off the public repo. Local copies only:
  `yoga9n-linux\firmware\` and `/boot/yoga9n-notes/upstream/`.

## The one thing to know before using `mtk-scpsys-mt6991-mmpc.c`

It drives physical addresses that this laptop's ACPI does not describe
(`0x31b50000` mmpc/ctl, `0x31b00000` mm_hwv, `0x31a80000` mminfra_hwv). That
is not a blocker — absent from ACPI means unclaimed, and `ioremap()` takes a
physical address — but it does mean a wrong guess can take an SError. **Dump
those registers read-only and sanity-check the values before the first
write.** Offsets, bits and masks for all ten CAM domains are tabulated in the
report, §5.
