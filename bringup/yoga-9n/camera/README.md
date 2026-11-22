# yoga9n-camera: OV08X40 bring-up on Lenovo Yoga 9 2-in-1 16N1X11

- patches/0001-media-ov08x40-add-NVDA2810-ACPI-ID.patch  (against NV-Kernels 2234cd7f)
- ov08x40.c   patched copy, built out of tree
- yoga9n-cam.c  glue: ACPI GPIO mapping (campower=_CRS[0], reset=_CRS[1] active-low),
                software node (clock-frequency 19.2 MHz, 4-lane D-PHY endpoint @ 400 MHz)

Build:  make            (uses /lib/modules/$(uname -r)/build)
Test (Russ's OK needed; toggles the sensor's reset line):
  insmod yoga9n-cam.ko && insmod ov08x40.ko
  dmesg | tail; ls /dev/v4l-subdev*
Expected: ov08x40 identifies chip 0x560858 and registers a v4l2 subdev.
Unload: rmmod ov08x40 yoga9n-cam
Known gap: no MCLK/CSI receiver, so no streaming.

## Getting ov08x40.c (not committed here)

`Kbuild` builds `ov08x40.o`, but `ov08x40.c` is upstream kernel source and is
deliberately not vendored. Fetch the version matching the running kernel's
base and apply the patch:

    git clone --filter=blob:none --no-checkout \
        https://github.com/NVIDIA/NV-Kernels /root/src/nv-kernels
    cd /root/src/nv-kernels
    git sparse-checkout set drivers/media/i2c
    git checkout Ubuntu-nvidia-7.0-7.0.0-1022.23_24.04.1     # = 2234cd7f
    cp drivers/media/i2c/ov08x40.c <this directory>/
    cd <this directory>
    patch -p3 < 0001-media-ov08x40-add-NVDA2810-ACPI-ID.patch

The patch is `-p1` against the kernel tree root, so `-p3` when applying to a
bare `ov08x40.c` in this directory.

## Status (2026-11-21)

Working: `ov08x40` binds to `i2c-NVDA2810:00`, passes its own chip-ID check
(0x560858), registers a v4l2 subdev. `n1x-seninf` binds NVDA2820, decodes the
MEMS map, and acts as the v4l2-async notifier, giving `/dev/media0`,
`/dev/v4l-subdev0` (bridge) and `/dev/v4l-subdev1` (sensor), with
`ov08x40:0 -> n1x-seninf:0` ENABLED,IMMUTABLE and sensor format
SGRBG10_1X10/3856x2416.

Not working: streaming. `n1x-seninf` performs **no MMIO access** by design —
the camera power domains and clocks cannot be enabled yet, and on MediaTek
SoCs touching an unpowered block can hang the bus. See
`../findings-2026-11-21-webcam-microphone.md` ("The unblock: \_SB.HFRP").

The 19.2 MHz clock-frequency in `yoga9n-cam.c` is an assumption needed to
satisfy `ov08x40`'s probe, not a measured CAMTG rate.
