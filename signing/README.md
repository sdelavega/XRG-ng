# Linux release signing

XRG-ng uses a dedicated OpenPGP release identity:

```text
XRG-ng Release Signing <sdelavega@users.noreply.github.com>
8DAC471BBD9BC89CD1C881AEA09F0F040FA937A4
```

The public key is [xrg-ng-release.asc](xrg-ng-release.asc). Compare the full
primary fingerprint above with the key before trusting a downloaded release:

```sh
gpg --show-keys --with-fingerprint xrg-ng-release.asc
gpg --import xrg-ng-release.asc
gpg --verify SHA256SUMS.asc SHA256SUMS
sha256sum -c SHA256SUMS
```

The signature must validate against this primary fingerprint, through its signing
subkey. A GnuPG warning about an uncertified owner is expected until you establish
trust yourself; a bad signature or a different fingerprint is a failure.
Download every file listed in SHA256SUMS to run the complete checksum check.
Individual artifacts also have detached signatures (`.asc`, or binary `.sig`
for Arch packages). `Tools/release-signing.py verify /path/to/release` verifies
the entire downloaded set against the repository's pinned public key and rejects
missing, altered or unlisted files.

RPM packages additionally carry native OpenPGP header signatures. After checking
the public key fingerprint, import it with `sudo rpm --import xrg-ng-release.asc`
and check packages with `rpm --checksig --verbose xrg-ng-*.rpm` before installing.
Arch users can add the verified key using `sudo pacman-key --add xrg-ng-release.asc`,
inspect it with `pacman-key --finger 8DAC471BBD9BC89CD1C881AEA09F0F040FA937A4`,
then locally trust it using `sudo pacman-key --lsign-key 8DAC471BBD9BC89CD1C881AEA09F0F040FA937A4`.
Keep each `.pkg.tar.zst.sig` beside its package when installing with `pacman -U`.
Debian, AppImage and archive users verify detached signatures/checksums before
installing. This release does not configure an APT, RPM or Arch repository.

The protected private keyring and revocation certificate stay outside the checkout
at `~/.local/share/xrg-ng-release/gnupg`; its passphrase is held in macOS Keychain
under `com.sdelavega.xrg-ng.release-signing` / `OpenPGP-release-v1`. Back up the
protected keyring and revocation certificate securely. Never upload either to
GitHub. The primary certification key expires in two years and the signing
subkey in one year; renew or rotate them before expiry, publishing updated public
material with an explicit transition notice. CI has no release private key.
