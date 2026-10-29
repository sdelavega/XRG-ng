#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-3.0-or-later
# Copyright (C) 2026 Stephen de la Vega.
# Create a test-only native ARM container from the signed official rootfs.
set -euo pipefail
cd "$(dirname "$0")/.."
[[ "$(uname -m)" == aarch64 ]] || { echo 'Requires native aarch64 Linux' >&2; exit 1; }
scratch=$(mktemp -d "${TMPDIR:-/tmp}/xrg-alarm-image.XXXXXX")
trap 'rm -rf -- "$scratch"' EXIT
export GNUPGHOME="$scratch/gnupg"
mkdir -m 700 "$GNUPGHOME"
# The official download redirects to its mirror network. Authentication is the
# mandatory signature under the fingerprint published by Arch Linux ARM.
curl -fL --retry 3 http://os.archlinuxarm.org/os/ArchLinuxARM-aarch64-latest.tar.gz -o "$scratch/rootfs.tar.gz"
curl -fL --retry 3 http://os.archlinuxarm.org/os/ArchLinuxARM-aarch64-latest.tar.gz.sig -o "$scratch/rootfs.tar.gz.sig"
gpg --batch --no-default-keyring --keyring "$scratch/keyring.gpg" --import Tools/archlinuxarm-build-key.asc
gpgv --status-fd 1 --keyring "$scratch/keyring.gpg" "$scratch/rootfs.tar.gz.sig" "$scratch/rootfs.tar.gz" > "$scratch/status"
grep -F '[GNUPG:] VALIDSIG 68B3537F39A313B3E574D06777193F152BDBE6A6 ' "$scratch/status"
sha256sum "$scratch/rootfs.tar.gz"
docker import "$scratch/rootfs.tar.gz" xrg-arch-arm-ci:local
