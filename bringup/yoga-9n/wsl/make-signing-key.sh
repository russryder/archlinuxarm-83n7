#!/bin/bash
# Create the package-signing key for this Yoga 9n port in a private GnuPG home.
# Run it yourself in a terminal (it asks for the passphrase twice):
#   wsl -d alarm -- bash /mnt/c/Users/Russ/code/archlinuxarm-83n7/bringup/yoga-9n/wsl/make-signing-key.sh
# Only the public key is written into the checkout. The private key stays in
# ~/private/gnupg inside the WSL distro; keep that folder out of every backup
# you would share.
set -euo pipefail
home=$HOME/private/gnupg
public=/mnt/c/Users/Russ/code/archlinuxarm-83n7/07-build/packages/payload/assets/keys/h7607a-build.gpg
uid='Russ Ryder (Yoga 9n Arch Linux ARM package signing) <ryder.russ@gmail.com>'
if [[ -e $home ]]; then
    echo "$home already exists; refusing to create a second key there." >&2
    exit 1
fi
mkdir -p -m 700 "$HOME/private"
mkdir -m 700 "$home"
export GNUPGHOME=$home
cat > "$home/gpg-agent.conf" <<EOF
pinentry-program /usr/bin/pinentry-curses
EOF
export GPG_TTY=$(tty)
gpg --batch --quiet --list-keys >/dev/null 2>&1 || true
echo "Creating an Ed25519 signing key for: $uid"
gpg --quick-generate-key "$uid" ed25519 sign never
fingerprint=$(gpg --with-colons --list-secret-keys "$uid" | awk -F: '/^fpr:/ { print $10; exit }')
gpg --export "$fingerprint" > "$public.new"
mv "$public.new" "$public"
echo
echo "Fingerprint: $fingerprint"
echo "Public key:  $public ($(stat -c %s "$public") bytes)"
echo "Private key: $home (never commit or copy it into the checkout)"
