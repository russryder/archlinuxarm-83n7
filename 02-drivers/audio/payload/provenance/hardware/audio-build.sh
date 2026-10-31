#!/usr/bin/env bash
# Rebuild mt8901-acp-sdw-legacy-mach.ko from audio-source.c with the inputs,
# compiler and make command recorded in audio-build.json.
# Usage: audio-build.sh IDENTITY_PATCH PACKAGE_DIRECTORY KERNEL_CONFIG [OUTPUT]
# IDENTITY_PATCH is audio-identity.patch (02-drivers/audio/patches/provenance/
# hardware), PACKAGE_DIRECTORY holds the pinned linux-headers-7.0.0-1022-nvidia,
# linux-nvidia-7.0-headers-7.0.0-1022 and linux-modules-7.0.0-1022-nvidia debs
# (.artifacts/packages in an assembled tree) and KERNEL_CONFIG is
# config-7.0.0-1022-nvidia from 01-platform/kernel. With OUTPUT the module is
# copied there. The build runs in /var/tmp/h7607a-audio-build, which must not
# exist.
# The patch gives the card the Lenovo Yoga 9n's tuning identity, SSID 17aa:3802,
# when DMI reports LENOVO 83N7 on board LNVNB161216. The built module must import
# exactly what the stock module of the pinned kernel imports, plus dmi_match,
# with every CRC matching Module.symvers.
# Run natively on aarch64 Linux, because the header package's build tools are
# arm64 binaries, with gcc 16.1.1 20260430, binutils, make, kmod, zstd, tar,
# patch, gawk and diffutils. Nothing is installed or loaded.
set -euo pipefail
if (($# != 3 && $# != 4)); then
    echo "Usage: $0 IDENTITY_PATCH PACKAGE_DIRECTORY KERNEL_CONFIG [OUTPUT]" >&2
    exit 2
fi
patch_file=$(realpath -e -- "$1")
packages=$(realpath -e -- "$2")
config=$(realpath -e -- "$3")
output=${4:-}
recipe=$(cd -- "$(dirname -- "$0")" && pwd)
shipped=$recipe/../../assets/hardware/modules/mt8901-acp-sdw-legacy-mach.ko
# The debug information records the build paths, so a fixed directory keeps
# rebuilds byte-identical.
work=/var/tmp/h7607a-audio-build
headers=$work/root/usr/src/linux-headers-7.0.0-1022-nvidia
upstream=$work/upstream/sound/soc/mediatek/mt8901/mt8901-acp-sdw-legacy-mach.c
stock=$work/root/lib/modules/7.0.0-1022-nvidia/kernel/sound/soc/mediatek/mt8901/mt8901-acp-sdw-legacy-mach.ko
image_deb=linux-headers-7.0.0-1022-nvidia_7.0.0-1022.23~24.04.1_arm64.deb
common_deb=linux-nvidia-7.0-headers-7.0.0-1022_7.0.0-1022.23~24.04.1_all.deb
modules_deb=linux-modules-7.0.0-1022-nvidia_7.0.0-1022.23~24.04.1_arm64.deb
# Inherited KCFLAGS, ARCH, CROSS_COMPILE and similar variables change the build.
clean=(env -i PATH=/usr/bin:/bin LC_ALL=C LANG=C)
[[ $(uname -m) == aarch64 ]] || { echo 'Run natively on aarch64' >&2; exit 1; }
[[ ! -e $work && ! -L $work ]] || { echo "$work must not exist" >&2; exit 1; }
[[ $("${clean[@]}" gcc --version | head -n 1) == 'gcc (GCC) 16.1.1 20260430' ]] ||
    { echo 'audio-build.json records gcc (GCC) 16.1.1 20260430' >&2; exit 1; }
# Source, patch and Kbuild values come from audio-build.json; the debs and the
# configuration are pinned by 07-build/locked-inputs and 01-platform/kernel.
sha256sum --strict --check <<EOF
565fb10356a84af9947f82d955365ae2f71308fc255ba043a01691b8e9d6e546  $recipe/audio-source.c
ce129a3a358551ca16f14fd8e1ab6db4fe7a74aac620b88d780fd8af6b3c8222  $patch_file
5fb2bb7d15adf4fc4a766c3ef32c7ec4048237a07bf74ae686e10076ae9f77af  $recipe/audio.Kbuild
93847c99d2a49f9713c464bb76956dc27f6709c7e20296f8eec894632cac3921  $packages/$image_deb
650da497156cf3518debf2f326e161b598d9fd0b41ab9e717e4bc72b3f8f87c8  $packages/$common_deb
3cb8bac5ed8ba7385f652240f9154691153f5ae86a3313d324f1e28c89aec126  $packages/$modules_deb
300b9d6316a1c772b9cb48eead848444e61d3d177daf74dee4a2007ac5e66667  $config
EOF
mkdir -p -- "$work/root" "$work/module" "$work/tmp" "$(dirname -- "$upstream")"
for deb in "$image_deb" "$common_deb" "$modules_deb"; do
    # The header debs carry data.tar.zst; the modules deb an uncompressed data.tar.
    member=$(ar t "$packages/$deb" | grep -E '^data\.tar(\.zst)?$')
    case $member in
        data.tar.zst) ar p "$packages/$deb" "$member" | tar --zstd -xf - -C "$work/root" ;;
        data.tar) ar p "$packages/$deb" "$member" | tar -xf - -C "$work/root" ;;
        *) echo "$deb has no data.tar member" >&2; exit 1 ;;
    esac
done
zstd -q -d -o "$stock" "$stock.zst"
(cd -- "$headers" && sha256sum --strict --check) <<'EOF'
3702382acae6cb607b441f0a44c2f0929a9ed98b9d33dcf2f731b1a1d1469297  .config
ad63eccd8911085a10d7996b78dd0c40f6bcaa0b32d42986a9cce39e0101a7ba  Module.symvers
f3fdeeaa2053f98aa80f3c0d8efd797bddec5d2dc112ed2232b16cfd720debaf  Makefile
deb435ae4bf00fe209a66e9d146a4ccb03b82a826a0f83b85844cb6e127a0935  include/generated/autoconf.h
7e524323ec20f848311d0666a66207dc2fb595be38b03e55795493a54abf670a  include/generated/utsrelease.h
430df14bc7aec97db7a25388783c0a69f5d0630fb10b6ef2979e1ad99a779389  include/config/auto.conf
076eaff42468545fd1174e65c2e4104ba3030504b2a79576dae2453f9e6e7a25  scripts/module.lds
715118bc3b328b369e9a16f96f0dbf469dd0c873aaaa5e4937fbc9cc9361988f  include/config/kernel.release
730cb5034088c43d586658efd91cf05181d5b0becb42d7dbaae338f41e3cd0b8  include/generated/rustc_cfg
EOF
# The stock module is the one audio-build.json records for the pinned kernel.
printf '%s  %s\n' 7eece1c13729170e098899da258076087daa0bef6f11d3489c1a18af12b14c9f "$stock.zst" |
    sha256sum --strict --check
# The shipped kernel is built from KERNEL_CONFIG. It differs from the header
# package's .config only in Rust toolchain values that no C header reads.
rust='^CONFIG_(RUSTC_VERSION|RUSTC_LLVM_VERSION|RUST_IS_AVAILABLE|RUSTC_HAS_SLICE_AS_FLATTENED)='
diff <(grep -Ev "$rust" "$headers/.config") <(grep -Ev "$rust" "$config")
# Reversing the patch must give the NV-Kernels 2234cd7f file audio-build.json records.
cp -- "$recipe/audio-source.c" "$upstream"
patch --batch --fuzz=0 --reverse -p1 -d "$work/upstream" < "$patch_file"
printf '%s  %s\n' 94f11feb334a20639d3643ea27603c14bc5584cb64b535622b2ea04c26bf720b "$upstream" |
    sha256sum --strict --check
cp -- "$recipe/audio.Kbuild" "$work/module/Kbuild"
cp -- "$recipe/audio-source.c" "$work/module/mt8901-acp-sdw-legacy-mach.c"
"${clean[@]}" TMPDIR="$work/tmp" make -j2 -C "$headers" M="$work/module" \
    CC=gcc HOSTCC=gcc modules 2>&1 | tee "$work/build.log"
built=$work/mt8901-acp-sdw-legacy-mach.ko
cp -- "$work/module/mt8901-acp-sdw-legacy-mach.ko" "$built"
modprobe --show-modversions "$built" | LC_ALL=C sort > "$work/imports.tsv"
modprobe --show-modversions "$stock" | LC_ALL=C sort > "$work/stock-imports.tsv"
[[ -s $work/imports.tsv ]] || { echo 'No versioned imports' >&2; exit 1; }
awk -F '\t' 'NR == FNR { crc[$2] = $1; next }
    crc[$2] != $1 { print "CRC differs from Module.symvers: " $2 > "/dev/stderr"; bad = 1 }
    END { exit bad }' "$headers/Module.symvers" "$work/imports.tsv"
names() { cut -f2 "$1" | LC_ALL=C sort; }
added=$(LC_ALL=C comm -13 <(names "$work/stock-imports.tsv") <(names "$work/imports.tsv") | tr '\n' ' ')
removed=$(LC_ALL=C comm -23 <(names "$work/stock-imports.tsv") <(names "$work/imports.tsv") | tr '\n' ' ')
[[ $added == 'dmi_match ' && -z $removed ]] ||
    { echo "Imports differ from the stock module beyond dmi_match: added [$added] removed [$removed]" >&2; exit 1; }
for field in name vermagic license depends alias import_ns parm; do
    [[ $(modinfo -F "$field" "$built") == "$(modinfo -F "$field" "$stock")" ]] ||
        { echo "modinfo $field differs from the stock module" >&2; exit 1; }
done
sha=$(sha256sum < "$built")
srcversion=$(modinfo -F srcversion "$built")
printf '%s\n  sha256      %s\n  bytes       %s\n  srcversion  %s\n' "$built" "${sha%% *}" "$(stat -c %s "$built")" "$srcversion"
if [[ -f $shipped ]]; then
    shipped_sha=$(sha256sum < "$shipped")
    if [[ $sha == "$shipped_sha" ]]; then
        echo 'The sha256 matches the shipped module.'
    else
        printf 'The sha256 differs from the shipped module (%s). Byte identity needs the same toolchain and the same build paths, which the debug information records.\n' "${shipped_sha%% *}"
    fi
fi
if [[ -n $output ]]; then
    install -m 0644 -- "$built" "$output"
    echo "Wrote $output"
fi
echo 'Imports match the stock module plus dmi_match, with CRCs from Module.symvers; nothing was installed or loaded.'
