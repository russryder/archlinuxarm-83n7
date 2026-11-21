# Windows-side session, 2026-11-21 14:32 PST — camera power path solved on paper

Executed the Windows work items from `HANDOFF-to-windows-20261121-1400.md` §4.
Read this before resuming on the stick. The short version:

> **The HFRP firmware hunt was the wrong question, and the "porting
> `mtk-scpsys-mt6991-mmpc.c` is a dead end" conclusion was wrong.** HFRP is not
> a coprocessor you have to boot — `hfrpsys` is MediaTek's name for the
> **power-domain controller** that owns every camera domain, and its GPL Linux
> driver is `drivers/soc/mediatek/mtk-scpsys-mt6991-mmpc.c`, which serves the
> compatible `mediatek,mt6991-hfrpsys-hwv`. The whole camera power/clock path
> is public GPL source. Nothing needs reverse-engineering.

Everything below was captured live from this machine (driver store, registry,
disassembly) or from MediaTek's published GPL trees. Sources are archived next
to this file — see §7.

---

## 0. Safety gate: BIOS is unchanged, the ACPI override is still valid

Windows updates ran; **no firmware update was installed.**

| field | recorded 14:00 | now | |
|---|---|---|---|
| bios-version | `SDCN77WW` | `SDCN77WW` | match |
| bios-release-date | 09/24/2026 | 9/23/2026 (CIM renders UTC-local) | same build |
| system-product-name | 83N7 | 83N7 | match |
| system-version | Yoga 9 2-in-1 16N1X11 | same | match |
| baseboard-product-name | LNVNB161216 | LNVNB161216 | match |

`/boot/h7607a-acpi.cpio` is still pinned to the right firmware. Boot the stick
normally. Still worth a `dmidecode -s bios-version` after boot out of habit.

---

## 1. There is no HFRP firmware, and nothing on Windows loads one

Searched the entire driver store (`C:\Windows\System32\DriverStore\FileRepository`)
for `*.img *.bin *.fw *.elf *.rom *.ucode *.blob *.mbn *.bl`. Every
coprocessor-image-shaped blob on the machine:

| blob | package | what it is |
|---|---|---|
| `nvCCU.img` (262168 B) | `nvccu.inf` | camera control unit firmware — see §6 |
| `hifi1_cose_sign_image.bin`, `hifi5_a/b_cose_sign_image.bin` | `nvadsp.inf` | audio DSPs |
| `b0_dflt_*_35l56_*.img`, `a1_dflt_42l43_patch_*.bin` | `xucsmeext_3802_fdl.inf` | Cirrus audio (already handled) |
| `gsp_ga10x.bin`, `ucodes_ga10x.bin`, `nvcubins.bin`, … | `nv_lenovo_woa.inf` | GPU |
| `ISP_mapping_S*.bin`, `*_ISP_param.db`, … | `nvcamavs.inf` | ISP tuning data, userspace |

Strings across `nvCamsys.sys`, `nvCCU.sys`, `nvSCP.sys`, `nvsrootmbx.sys`:
the token `hfrp` appears **once**, as `hfrp_ipi_init` in `nvCamsys.sys`. No
`.img` is named by it, no driver binds `MTK00055`, and no `scp.img`-style
tinysys blob exists for mt8991/mt8991.

**So Windows boots no HFRP firmware, and Windows's camera works.** The
"coprocessor has no firmware running" theory is dead. Do not spend more time
looking for a blob.

## 2. `hfrp_ipi_init` does nothing interesting — disassembled in full

`nvCamsys.sys` rva `0x83338`, 0x480 bytes (ARM64 PE, image base 0x140000000).
Complete behaviour, in order:

1. `KeInitializeEvent(ctx+0xa0, SynchronizationEvent, FALSE)`, `KeResetEvent`
2. `KeInitializeGuardedMutex(ctx+0xc0)`
3. enumerate its own WDFDEVICE resource list; for each `CmResourceTypeMemory`
   descriptor → `MmMapIoSpaceEx(start, len, PAGE_READWRITE|PAGE_NOCACHE)`,
   storing VA at `ctx+0x18` and length at `ctx+0x20`
4. for each `CmResourceTypeInterrupt` descriptor → connect it
5. bails with `-EINVAL` (`-0x16`) if the device context isn't populated

**No firmware load. No reset or boot-control register write. No SMC/PSCI. It
never touches `0x31270074`.** That answers handoff priority §4.2: *nothing* is
written before the first message other than mapping the window.

The matching ISR is at rva `0x83190`: reads a mailbox status, requires it to
equal `0x1F`, reads the payload, stores it at `ctx+0xb8`, and `KeSetEvent`s
`ctx+0xa0`. A plain request/reply mailbox, no bring-up sequence.

## 3. The mailbox register layout, straight from the live registry

`HKLM\SYSTEM\CurrentControlSet\Enum\ACPI\NVDA2801\2&daba3ff&1\Device Parameters\Mbox0`:

| value | offset from the mapped base |
|---|---|
| `Mbox_In_Status_Offset` | `0x100` |
| `Mbox_In_Set_Offset` | `0x100` |
| `Mbox_In_Clr_Offset` | `0x108` |
| `Mbox_Out_Status_Offset` | `0x104` |
| `Mbox_Out_Set_Offset` | `0x104` |
| `Mbox_Out_Clr_Offset` | `0x10c` |

Identical under `NVDA2802` (imgsys) and `NVDA8200` (SCP — which has both
`Mbox0` and `Mbox1`). `nvCamsys` reads these four as registry DWORDs at init
(rva `0x1b6a20`); they are not hardcoded.

**This reinterprets HFRP's ACPI `_CRS` and settles handoff priority §4.3.**
`MTK00055`'s descriptors `0x311C0100 / 0104 / 0108 / 010C` are *not* four
doorbells — they are this one register set:

```
0x311C0000 (0x100)   message slots
0x311C0100           IN_STATUS (read) / IN_SET  (write) <- AP -> coprocessor doorbell
0x311C0104           OUT_STATUS (read) / OUT_SET (write)   coprocessor -> AP
0x311C0108           IN_CLR
0x311C010C           OUT_CLR
```

There is exactly **one** AP→HFRP doorbell and it is `+0x100` (IN_SET), which is
the `db0` you already picked. Writing `+0x104` raises the AP's *own* interrupt
because that is the inbound-direction set register — exactly the symptom you
logged for "doorbells 1-3". Your mailbox mechanics were right.

## 4. Windows's camera mailbox is at `0x31160000`, not `0x311C0000`

`nvCamsys.sys` binds `ACPI\NVDA2801` = `\_SB.ISP1`. ISP1's `_CRS` holds 49
memory descriptors; 48 are camera blocks in `0x3Axxxxxx`, and exactly one —
**index 48, `0x31160000`, 0x1000** — is in the HFRP address block, followed by
IRQ 511. Since `hfrp_ipi_init` maps *its own device's* memory resources, the
window it uses is ISP1's `0x31160000`, with the `+0x100/0x104/0x108/0x10c`
layout above.

`\_SB.HFRP`'s `0x311C0000` is a **different mailbox instance**. That it answers
nobody is consistent: it isn't the one the camera stack uses.

Caveat, stated plainly: this is strong inference (ISP1 owns exactly one
`0x31xxxxxx` region; the init routine maps device memory resources), not an
MMIO trace. No kernel-level tracing was attempted.

**But §5 makes this mostly moot** — you don't need the mailbox at all.

## 5. The actual unblock: `hfrpsys` is a power-domain controller with a GPL driver

MediaTek's own mt6991 device tree (`arch/arm64/boot/dts/mediatek/mt6991.dts`,
MiCode/MTK_kernel_device_modules, branch `bsp-dali-v-oss`) declares:

```dts
hfrpsys_bus: syscon@31b50000 {
    compatible = "mediatek,mt6991-hfrpsys-bus", "syscon";
    reg = <0 0x31b50000 0 0x1000>;
};
hfrpsys: power-controller@31b50000 {
    compatible = "mediatek,mt6991-hfrpsys-hwv", "syscon";   /* hwv = hardware voter */
    reg = <0 0x31b50000 0 0x1000>;
    #power-domain-cells = <1>;
    clocks = <&cksys_gp2_clk CLK_CK2_CCUSYS_SEL>;
    clock-names = "ccusys";
    mmpc = <&hfrpsys_bus>;
    mm-hw-ccf-regmap  = <&mm_hwv>;        /* syscon@31b00000, len 0x6000 */
    mminfra-hwv-regmap = <&mminfra_hwv>;  /* syscon@31a80000, len 0x1000 */
    cksys2-regmap = <&cksys_gp2_clk>;     /* syscon@1000c000, len 0x800  */
};
```

and every camera block takes its power from it:

```dts
camisp@3a000000   power-domains = <&hfrpsys MT6991_POWER_DOMAIN_CAM_MAIN>;   /* 17 */
camisp-vcore      power-domains = <&hfrpsys MT6991_POWER_DOMAIN_CAM_VCORE>;  /* 16 */
cam-raw-a@3a800000 power-domains = <&hfrpsys MT6991_POWER_DOMAIN_CAM_RAWA>;  /* 19 */
cam-raw-b@3a900000 power-domains = <&hfrpsys MT6991_POWER_DOMAIN_CAM_RAWB>;  /* 20 */
```

`drivers/soc/mediatek/mtk-scpsys-mt6991-mmpc.c` (1181 lines) is the driver, and
its `of_device_id` table serves **both** `mediatek,mt6991-hfrpsys` and
`mediatek,mt6991-hfrpsys-hwv`.

### Why the earlier "dead end" was a false negative

The 14:00 handoff recorded: *"porting `mtk-scpsys-mt6991-mmpc.c` — its voter
registers at 0x31b00000 / 0x31a80000 / 0x31b50000 are **not described in N1X
ACPI at all**"*, and treated that as fatal. It is true but not fatal:

- Confirmed: the DSDT's only `0x31xxxxxx` addresses are `0x31160000`,
  `0x31170000`, `0x311C0000` (+ the four mailbox regs), `0x31270074`,
  `0x31380000`. Nothing at `0x31a8`, `0x31b0` or `0x31b5`.
- **Not being in ACPI doesn't mean absent — it means unclaimed.** `ioremap()`
  takes a physical address, not an ACPI resource. Nothing else on the system
  will contend for those pages.
- They're absent from ACPI because on Windows the AP asks the HFRP coprocessor
  to vote on its behalf over the `0x31160000` mailbox. On MediaTek's own Android
  builds the AP driver programs the voters directly, which is what this driver
  does and what is shipping on every mt6991 phone.

### The programming recipe (exact offsets, from the GPL driver)

Two styles coexist. For the `-hwv` compatible, `CAM_MAIN` and `CAM_VCORE` go
through the **mm_hwv** regmap at `0x31b00000`:

| domain | regmap | set | clr | done | en | set_sta | clr_sta | bit |
|---|---|---|---|---|---|---|---|---|
| `CAM_MAIN` (17) | mm_hwv `0x31b00000` | `0x0218` | `0x021C` | `0x141C` | `0x1410` | `0x146C` | `0x1470` | 20 |
| `CAM_VCORE` (16) | mm_hwv `0x31b00000` | `0x0218` | `0x021C` | `0x141C` | `0x1410` | `0x146C` | `0x1470` | 21 |
| `CAM_MRAW` (18) | mm_hwv `0x31b00000` | `0x0218` | `0x021C` | `0x141C` | `0x1410` | `0x146C` | `0x1470` | 13 |

The remaining camera domains use the classic `ctl_offs` form in the
hfrpsys/mmpc space (`0x31b50000`), `sram_pdn_bits = BIT(8)`,
`sram_pdn_ack_bits = BIT(12)`, with bus-protect via
`BUS_PROT_IGN(MMPC_TYPE, set 0x174, clr 0x178, en 0x170, sta 0x1B0, mask)`:

| domain | `ctl_offs` | bus-protect mask |
|---|---|---|
| `CAM_MRAW` (18) | `0x034` | `BIT(20)` |
| `CAM_RAWA` (19) | `0x038` | `BIT(21)` |
| `CAM_RAWB` (20) | `0x03C` | `BIT(22)` |
| `CAM_RAWC` (21) | `0x040` | `BIT(23)` |
| `CAM_RMSA` (22) | `0x044` | `BIT(24)` |
| `CAM_RMSB` (23) | `0x048` | `BIT(25)` |
| `CAM_RMSC` (24) | `0x04C` | `BIT(26)` |
| `CAM_MAIN` (17) | `0x050` | `BIT(27)` |
| `CAM_VCORE` (16) | `0x054` | `BIT(3)` |
| `CAM_CCU` (25) | `0x058` | `BIT(28)`, basic clk `"ccusys"` |

All camera domains carry
`MTK_SCPD_IS_PWR_CON_ON | MTK_SCPD_NON_CPU_RTFF | MTK_SCPD_BYPASS_INIT_ON`.

### Per-frame power: QoF is hardware, and it's also GPL

`mtkcam/camsys/isp8/cam/mtk_cam-qof.c` + `mtk_cam-qof_regs.h`. The function the
Windows driver was named after decompiles to the published source **constant for
constant** — I checked the disassembly of `__qof_mtcmos_raw_voter`
(`nvCamsys.sys` rva `0x13c18`) against it:

| from the GPL source | in the Windows binary |
|---|---|
| `REG_QOF_CAM_A_QOF_CTL_1 = 0x0` | read/modify/write at `qof_base + 0` |
| `QOF_CAM_A_APMCU_SET_1` bit 0 | `orr w8, w10, #1` when refcount hits 1 |
| `QOF_CAM_A_APMCU_CLR_1` bit 1 | `orr w8, w10, #2` when refcount hits 0 |
| `REG_QOF_CAM_A_QOF_STATE_DBG_1 = 0x30` | poll at `qof_base + 0x30` |
| poll `state_dbg & (PS_ON = 1<<1)` | same register, same window |
| delay 50 µs | `x20 = -0x1f4` → 500 × 100 ns |
| `PWR_STATE_POLLING_TIMEOUT_LONG_US = 600` | `x27 = 0x177a` → 6010 × 100 ns = 601 µs |
| `spin_lock_irqsave` | `KeAcquireSpinLockRaiseToDpc` |

So the Windows camera driver *is* a port of this GPL tree. Use the source, not
the binary.

Per-pipe enable lives in the shared QoF top block: `qof_is_enabled()` reads
`qoftop_base + REG_QOF_CAM_TOP_QOF_TOP_CTL` and tests
`QOF_CAM_TOP_QOF_SUBA_EN / SUBB_EN / SUBC_EN`.

## 5b. ISP1 `_CRS` → MediaTek reg-name map (complete)

Every ISP1 memory descriptor but three resolves to a named `reg` in mt6991.dts.
This is proof that N1X's camera block *is* MT6991's, and it is the index table
the port needs (ACPI gives you no `MEMS`-style name table for ISP1, unlike SENI):

| idx | address | len | node | reg-name |
|---|---|---|---|---|
| 0 | `0x3a000000` | 0x1000 | `camisp` | `base` |
| 1 | `0x3a0a0000` | 0x800 | `camisp` | **`qof_base`** (= `qoftop_base`) |
| 2–5 | `0x3a800000/808000/810000/818000` | 0x8000 | `cam-raw-a` | `base` / `inner_base` / `dmatop_base` / `inner_dmatop_base` |
| 6 | `0x3a0b0000` | 0x400 | `cam-raw-a` | **`qof_base`** |
| 7–10 | `0x3a900000/908000/910000/918000` | 0x8000 | `cam-raw-b` | same four |
| 11 | `0x3a0c0000` | 0x400 | `cam-raw-b` | **`qof_base`** |
| 12–13 | `0x3a840000/848000` | 0x8000 | `cam-rms-a` | `base` / `inner_base` |
| 14–15 | `0x3a940000/948000` | 0x8000 | `cam-rms-b` | `base` / `inner_base` |
| 16–19 | `0x3a880000/888000/890000/898000` | 0x8000 | `cam-yuv-a` | base / inner / dmatop / inner_dmatop |
| 20–23 | `0x3a980000/988000/990000/998000` | 0x8000 | `cam-yuv-b` | same four |
| 24–25 | `0x3a700000/708000` | 0x8000 | `mraw1` | `base` / `inner_base` |
| 26–27 | `0x3a720000/728000` | 0x8000 | `mraw3` | `base` / `inner_base` |
| 28–33 | `0x3a500000`+ | 0x1000 | `camsv1` | base / base_DMA / base_SCQ / inner ×3 |
| 34–39 | `0x3a510000`+ | 0x1000 | `camsv2` | same six |
| 40–45 | `0x3a540000`+ | 0x1000 | `camsv5` | same six |
| 46–47 | `0x3a420000/428000` | 0x8000 | — | not in mt6991.dts; identify before touching |
| 48 | `0x31160000` | 0x1000 | — | the HFRP mailbox (§4) |

Note what ISP1 does **not** have: no `0x3aa00000` and no `0x3a0d0000`, i.e. **no
RAW_C**. This laptop exposes two RAW pipes. Don't instantiate a third.

IRQs (descriptors 49–60, ACPI numbering; subtract 32 for the Linux virq the
stick showed): 511, 513, 521, 524, 522, 525, 523, 526, 516, 517, 518, 802.
Confident matches against mt6991.dts: **526 = `camisp` "qoftop"**,
516 = `mraw3`, 517 = `mraw4`, 513 = `pda2`. The rest don't line up with
MT6991's assignments — this variant's GIC layout differs, so derive IRQs from
ACPI, not from the DT.

## 5c. Camera DVFS table, from ISP1's `_DSM`

UUID `dce4cf8f-c399-487f-bf1b-cb4b7708a757`:

- fn 3 → returns `CISP`, the clock-ID table (`camtg` 0x0A09, `cammain` 0x0A04,
  `qof` 0x0A1D, `bwr` 0x0A20, …)
- fn 7, `Arg3` = 0…9 → the cam OPP table as (freq Hz, voltage µV) pairs:

| freq | voltage |
|---|---|
| 312 MHz | 0.575 V |
| 416 MHz | 0.600 V |
| ~550 MHz | 0.650 V |
| 660 MHz | 0.700 V |
| 660 MHz | 0.750 V |

This is the `operating-points-v2 = <&opp_table_cam>` equivalent. ISP1 also
carries `CLRA/CLRB/CLYA/CLYB/CLSA/CLSB/CLM0/CLM2/CLV0/CLV1/CLV4/CLUI` (per-block
clock IDs) and `LPRA/LPRB/LPYA/LPYB/LPM0/LPM2/LPV0/LPV1/LPV4/LPUI` (per-block
`0x0Dxx/0x10xx/0x12xx/…` IDs — larb/port IDs, e.g. `LPRA` names `cqi_r1`,
`rawi_r2`, `imgo_r1`, `awbo_r1`).

Also in the DT and worth knowing: the clock driver is
`drivers/clk/mediatek/clk-mt6991-cam.c`, in the same tree.

## 6. `nvCCU.img` — the camera control unit firmware (for later, not now)

`nvccu.inf` binds `ACPI\NVDA2808` = `\_SB.CCU0`, loads `nvCCU.img` from a path
in `HKR,Parameters,CCUFirmware_FileName`, and has a UMDF secure companion
(`nvCCUCompanion.dll`, `TrustletIdentity=4096`).

`\_SB.CCU0` in the DSDT:

```
_HID "NVDA2808", _UID 0, _CCA 1, _DEP { ISP1, ROT0 }
_STA -> 0x0F        <- NOT gated. Linux can already enumerate this today.
_CRS: 0x3C080000 (0x50000); IRQ 0x214 (532), 0x215 (533), 0x217 (535)
_DSM 810afc1e-14a8-4e23-b1ef-3d16ea4ec531: fn1 -> 0x04, fn2 -> 0x231F
```

Container format of the 262168-byte image — 24-byte header + exactly 256 KiB:

```
+0x00  u32   count = 2
+0x04  char  name[6] = "mt8991";  u32 = 0x00014C9C (85148)
+0x0e  char  name[6] = "mt8971";  u32 = 0x00014B1C (84764)
+0x18  payload, 0x40000 bytes
```

`mt8991` is this SoC (matches `nvSeninf.sys`'s `_DSM` SoC string and
`\_SB.SENI`). The payload is high-entropy (6.9 bits/byte over the first
0x14C9C) so it's compressed and/or signed; treating the two u32s as sizes and
laying the blobs end to end does **not** work — `0x14CB4` onward is an `0xFF`
run. Unresolved; the sizes are probably uncompressed lengths.

SHA-256 `300c092c0325a068d62c9ad9e02accbd2431707111258698227aaf74f8301518`.
Copy archived at `firmware/nvCCU.img` with its INF.

CCU is MediaTek's 3A (AE/AF) coprocessor — nice to have, **not** required for
first light. Get a frame out of SENINF→RAW first.

## 7. Archived sources (all on `D:\yoga9n-linux`, no network needed on the stick)

```
upstream/isp8-qof/mtk_cam-qof.c          34514   GPL, the QoF driver
upstream/isp8-qof/mtk_cam-qof.h           2665
upstream/isp8-qof/mtk_cam-qof_regs.h     44628   every QoF register offset
upstream/pm-domain/mtk-scpsys-mt6991-mmpc.c 36680 GPL, serves mt6991-hfrpsys-hwv
upstream/pm-domain/mt6991-power.h          3931   MT6991_POWER_DOMAIN_* ids
upstream/dt/mt6991.dts                   660802  MediaTek's own mt6991 DT
firmware/nvCCU.img                       262168  CCU firmware (NVIDIA, redistribution unclear)
firmware/nvCCU.inf                         2675
```

Provenance: `rsuntk/android_kernel_samsung_a05m-vendor_modules`
(`mtkcam/camsys/isp8/cam/`) for the QoF files — the same ISP8 tree the earlier
notes identified, also mirrored in `MiCode/MTK_kernel_modules`,
`moto-mediatek-devs/...lamu...`, `xiaomi-klee-devs/...` and others;
`MiCode/MTK_kernel_device_modules` branch `bsp-dali-v-oss` for the DT and the
power-domain driver. `nvCCU.img` came off this machine's driver store —
**keep it local, don't commit it to the public repo.**

---

## 8. Suggested order of work on the stick

1. **`hfrpsys` power-domain provider first.** Port
   `mtk-scpsys-mt6991-mmpc.c`'s `-hwv` path as a small platform driver that
   `ioremap`s `0x31b50000` (mmpc/ctl), `0x31b00000` (mm_hwv, 0x6000),
   `0x31a80000` (mminfra_hwv) and `0x1000c000` (cksys_gp2), and registers a
   generic PM domain per §5. Start read-only: dump `mm_hwv + 0x1410/0x141C/
   0x146C/0x1470` and `mmpc + 0x050/0x1B0` and see whether the CAM_MAIN bits
   look sane *before* writing anything.
2. **Then one domain, on its own.** `CAM_VCORE` (bit 21) then `CAM_MAIN`
   (bit 21/20 hwv, or `ctl_offs 0x050`), checking the done/ack bit each time.
   Keep the bus-protect ordering from the driver — releasing a protect on an
   unpowered bus is the classic way to hang.
3. **Clocks**: `clk-mt6991-cam.c` from the same tree, plus `camtg` = clock ID
   `0x0A09` per `CISP`.
4. **Only then** SENINF MMIO, using the bring-up order already recorded in
   `answers-from-windows-20261121.md` §"SENINF bring-up order".
5. HFRP mailbox and CCU: skip. Neither is needed for a first frame.

### Risk note, honestly

Step 1 writes to physical addresses the firmware does not describe. If
`0x31b00000`/`0x31b50000` are wrong or unpowered on this part, an access can
take an SError and wedge the machine. It is a live USB, so the cost is a reboot
and nothing on disk — but do the read-only dump first, and don't do this with
unsaved work in the session.

The counter-hypothesis to keep in mind: the HFRP coprocessor may own those voter
registers on this platform, in which case direct AP writes could race it. On
this machine HFRP appears inert under Linux, so there should be nobody to race —
but if the first read-back looks like garbage rather than plausible voter state,
stop and reconsider rather than writing.

---

## 9. Tooling left behind

Scratch analysis tools for ARM64 PE drivers (PE/`.pdata` parser, import
resolver, string-xref based function naming — 795 of 1732 functions in
`nvCamsys.sys` got real names, since the driver embeds its own function names
for WPP tracing). They live in this session's scratchpad, not on `D:`. Rebuild
if needed; they're ~250 lines of Python over `capstone`, which is already
installed in `C:\Python315`.

Useful one-liners for next time on the Windows side:

```
reg query HKLM\SYSTEM\CurrentControlSet\Enum\ACPI\NVDA2801 /s
gh search code "<mediatek symbol>" --limit 20      # the vendor trees are public
```

`gh search code` against the leaked-but-public Android vendor module trees was
by far the highest-yield tool this session — more than disassembly. Try it
first for any MediaTek symbol.
