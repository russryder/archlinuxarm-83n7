#!/bin/bash
# Sign the packages the unprivileged pkgbuild user built and publish build/repo.
# Run it yourself in a terminal (gpg asks for the key's passphrase):
#   wsl -d alarm -- bash /mnt/c/Users/Russ/code/archlinuxarm-83n7/bringup/yoga-9n/wsl/sign-packages.sh
# build-packages.py accepts only packages whose bytes and SHA-256 match the
# build-record.json that the build step wrote for the current locks.
set -euo pipefail
tree=$HOME/build/tree
built=/home/pkgbuild/out
export GNUPGHOME=$HOME/private/gnupg
export GPG_TTY=$(tty)
[[ -f $built/build-record.json ]] || { echo "No build record in $built; build the packages first" >&2; exit 1; }
[[ ! -e $tree/build/repo ]] || { echo "$tree/build/repo already exists" >&2; exit 1; }
cd "$tree"
python3 -B scripts/build-packages.py --assemble-only --output "$built" --signing-home "$GNUPGHOME"
echo
echo "Signed repository: $tree/build/repo"
