#!/bin/bash
# Combine the exported ESP and root partition images into one GPT disk image.
# Usage: make-disk-image.sh ESP.img ROOT.img OUTPUT.img
# The partitions keep the offsets and sizes in locks/live-base.json and
# locks/usb-layout.json (ESP at 1 MiB, root right after it), so the fixed
# filesystem UUIDs the boot configuration expects are unchanged. The P16
# maintainer's raw wheel carrier and Windows backup partition are not part of
# this layout; the image needs a stick of at least 11 GB and leaves the rest
# of it unallocated.
set -euo pipefail
(($# == 3)) || { echo "Usage: $0 ESP.img ROOT.img OUTPUT.img" >&2; exit 2; }
esp=$(realpath -e -- "$1"); root=$(realpath -e -- "$2"); out=$3
[[ ! -e $out ]] || { echo "$out already exists" >&2; exit 1; }
esp_offset=1048576 esp_bytes=805306368 root_offset=806354944 root_bytes=9930014720
[[ $(stat -c %s "$esp") == "$esp_bytes" ]] || { echo "ESP image is not $esp_bytes bytes" >&2; exit 1; }
[[ $(stat -c %s "$root") == "$root_bytes" ]] || { echo "root image is not $root_bytes bytes" >&2; exit 1; }
[[ $(blkid -o value -s UUID "$esp") == 8B98-C777 && $(blkid -o value -s LABEL "$esp") == N1XESP ]] ||
    { echo "ESP image lacks UUID 8B98-C777 / label N1XESP" >&2; exit 1; }
[[ $(blkid -o value -s UUID "$root") == 4dd7d947-b72c-431f-a74e-3272227ba90c && $(blkid -o value -s LABEL "$root") == N1XALARM ]] ||
    { echo "root image lacks its fixed UUID / label N1XALARM" >&2; exit 1; }
# Room after root for the backup GPT, rounded up to a whole MiB.
total=$(( (root_offset + root_bytes + 2097152) / 1048576 * 1048576 ))
truncate -s "$total" "$out"
sgdisk --zap-all "$out" >/dev/null
sgdisk --set-alignment=1 \
    --new=1:$((esp_offset / 512)):$(((esp_offset + esp_bytes) / 512 - 1)) --typecode=1:EF00 --change-name=1:N1XESP \
    --new=2:$((root_offset / 512)):$(((root_offset + root_bytes) / 512 - 1)) --typecode=2:8305 --change-name=2:N1XALARM \
    "$out" >/dev/null
dd if="$esp" of="$out" bs=4M seek=$((esp_offset)) oflag=seek_bytes conv=notrunc,sparse status=none
dd if="$root" of="$out" bs=4M seek=$((root_offset)) oflag=seek_bytes conv=notrunc,sparse status=none
sgdisk --verify "$out" | tail -1
# The written regions must read back as the input images.
cmp -n "$esp_bytes" -i "0:$esp_offset" "$esp" "$out"
cmp -n "$root_bytes" -i "0:$root_offset" "$root" "$out"
sha=$(sha256sum "$out" | cut -d' ' -f1)
printf '{\n  "image": "%s",\n  "bytes": %s,\n  "sha256": "%s",\n  "esp_sha256": "%s",\n  "root_sha256": "%s"\n}\n' \
    "$(basename "$out")" "$total" "$sha" "$(sha256sum "$esp" | cut -d' ' -f1)" "$(sha256sum "$root" | cut -d' ' -f1)" > "$out.json"
cat "$out.json"
