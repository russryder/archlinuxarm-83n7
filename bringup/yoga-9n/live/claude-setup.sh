#!/bin/bash
# Install Claude Code on the Yoga 9n live stick for live troubleshooting.
# Run as root at the live console with networking up (nmtui):
#   bash /boot/yoga9n-claude-setup.sh
# Then start it with:  cd /root/yoga9n-live && claude
set -euo pipefail
die() { echo "STOP: $*" >&2; exit 1; }
[[ $EUID == 0 ]] || die 'run as root'
[[ $(findmnt -no UUID /) == 4dd7d947-b72c-431f-a74e-3272227ba90c ]] || die 'this is not the live stick'
[[ -f /boot/yoga9n-CLAUDE.md ]] || die '/boot/yoga9n-CLAUDE.md is missing'
getent hosts claude.ai >/dev/null || die 'no network; connect with nmtui first'

echo "== Package holds"
holds='linux-n1x-nvidia-bin nvidia-utils nvidia-n1x-modules nvidia-n1x-userspace-fix h7607a-hardware power-profiles-daemon-n1x linux-firmware-mediatek linux-firmware-cirrus linux-firmware-whence'
if ! grep -q '^IgnorePkg *= *linux-n1x-nvidia-bin' /etc/pacman.conf; then
    sed -i "/^\[options\]/a IgnorePkg = $holds" /etc/pacman.conf
fi
grep '^IgnorePkg' /etc/pacman.conf

echo "== Update and diagnostic tools"
timedatectl set-ntp true || true
pacman -Sy --noconfirm --needed archlinuxarm-keyring archlinux-keyring
pacman -Su --noconfirm
tools=()
for p in git curl ca-certificates ripgrep less nano alsa-utils usbutils pciutils libinput \
         libinput-tools lm_sensors acpica i2c-tools evtest iw edid-decode; do
    if pacman -Si "$p" >/dev/null 2>&1; then tools+=("$p"); else echo "skipping unavailable $p"; fi
done
pacman -S --noconfirm --needed "${tools[@]}"
pacman -Q $holds

echo "== Claude Code"
if ! command -v claude >/dev/null && [[ ! -x /root/.local/bin/claude ]]; then
    # Anthropic's official native installer (Linux arm64 build).
    curl -fsSL https://claude.ai/install.sh | bash
fi
grep -q '/root/.local/bin' /root/.bashrc 2>/dev/null || echo 'export PATH="$HOME/.local/bin:$PATH"' >> /root/.bashrc
export PATH="/root/.local/bin:$PATH"
claude --version

echo "== Workspace"
install -d -m 700 /root/yoga9n-live
install -m 600 /boot/yoga9n-CLAUDE.md /root/yoga9n-live/CLAUDE.md
install -d /boot/yoga9n-notes
echo
echo "Ready. Start it with:"
echo "  source ~/.bashrc; cd /root/yoga9n-live && claude"
echo "On first start choose your Claude account; it shows a URL to open on your phone and a code to paste back."
