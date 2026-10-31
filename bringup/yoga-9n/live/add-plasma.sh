#!/bin/bash
# Add a KDE Plasma (Wayland) desktop to the Yoga 9n live stick.
# Run as root at the live console, with networking up (nmtui):
#   bash /boot/yoga9n-add-plasma.sh USERNAME
# Steps, each skipped when already done:
#   1. grow the stick's root partition into the free space after it and the
#      ext4 filesystem with it (online; the filesystem UUIDs do not change);
#   2. hold the device packages exactly as the installer does on an installed
#      system, so updates never replace the kernel, NVIDIA, firmware or power tuple;
#   3. update the rest of the system from the ALARM mirrors (pacman -Syu);
#   4. install Plasma with SDDM on Wayland, PipeWire audio, touch/pen/rotation
#      support and a browser;
#   5. create USERNAME with sudo rights and start Plasma at boot.
# Only the stick is touched: the root filesystem must be the live image's
# (UUID 4dd7d947-...) on a USB disk.
set -euo pipefail
die() { echo "STOP: $*" >&2; exit 1; }
[[ $EUID == 0 ]] || die 'run as root'
user=${1-}
[[ $user =~ ^[a-z_][a-z0-9_-]{0,31}$ && $user != root ]] || die "usage: $0 USERNAME (lower case, not root)"

root_uuid=4dd7d947-b72c-431f-a74e-3272227ba90c
[[ $(findmnt -no UUID /) == "$root_uuid" ]] || die 'the root filesystem is not the live stick image'
root_dev=$(findmnt -no SOURCE /)
part=$(basename "$root_dev")
disk=/dev/$(lsblk -no PKNAME "$root_dev")
[[ $(lsblk -dno TRAN "$disk") == usb ]] || die "$disk is not a USB disk"
num=$(cat "/sys/class/block/$part/partition")

echo "== 1/5 Root partition $root_dev on $disk"
before=$(blockdev --getsize64 "$root_dev")
# The image's backup GPT sits where the image ended; move it to the end of the stick first.
sfdisk --relocate gpt-bak-std "$disk"
echo ', +' | sfdisk --no-reread --no-tell-kernel -N "$num" "$disk"
partx -u "$disk"
resize2fs "$root_dev"
printf 'root partition: %s -> %s bytes\n' "$before" "$(blockdev --getsize64 "$root_dev")"
df -h /

echo "== 2/5 Package holds"
holds='linux-n1x-nvidia-bin nvidia-utils nvidia-n1x-modules nvidia-n1x-userspace-fix h7607a-hardware power-profiles-daemon-n1x linux-firmware-mediatek linux-firmware-cirrus linux-firmware-whence'
if ! grep -q '^IgnorePkg *= *linux-n1x-nvidia-bin' /etc/pacman.conf; then
    sed -i "/^\[options\]/a IgnorePkg = $holds" /etc/pacman.conf
fi
grep '^IgnorePkg' /etc/pacman.conf

echo "== 3/5 System update"
timedatectl set-ntp true || true
pacman -Sy --noconfirm --needed archlinuxarm-keyring archlinux-keyring
pacman -Su --noconfirm
pacman -Q $holds   # unchanged versions prove the holds held

echo "== 4/5 Plasma"
pacman -S --noconfirm --needed \
    plasma-desktop plasma-workspace kwin plasma-nm plasma-pa powerdevil kscreen bluedevil \
    kde-gtk-config breeze-gtk xdg-desktop-portal-kde systemsettings \
    konsole dolphin kate ark spectacle gwenview \
    sddm sddm-kcm \
    pipewire pipewire-alsa pipewire-pulse wireplumber \
    maliit-keyboard iio-sensor-proxy \
    noto-fonts noto-fonts-emoji firefox sudo
# SDDM's greeter on Wayland (KWin), since no X server is installed.
install -d /etc/sddm.conf.d
cat > /etc/sddm.conf.d/10-wayland.conf <<'EOF'
[General]
DisplayServer=wayland
GreeterEnvironment=QT_WAYLAND_SHELL_INTEGRATION=layer-shell

[Wayland]
CompositorCommand=kwin_wayland --drm --no-lockscreen --no-global-shortcuts --locale1
EOF

echo "== 5/5 User $user"
if ! id "$user" >/dev/null 2>&1; then
    useradd -m -G wheel,video,audio,input -s /bin/bash "$user"
    echo "Choose a password for $user:"
    passwd "$user"
fi
echo '%wheel ALL=(ALL:ALL) ALL' > /etc/sudoers.d/10-wheel
chmod 0440 /etc/sudoers.d/10-wheel
systemctl enable sddm.service
systemctl set-default graphical.target
echo
echo "Done. Reboot (or run: systemctl isolate graphical.target) and log in as $user with 'Plasma (Wayland)'."
echo "The live root console stays on Ctrl+Alt+F1."
