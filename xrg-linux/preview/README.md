# XRG-ng Linux preview

This is the Swift/Rust + GTK4 rewrite, version 0.1.0. It is an early preview;
the legacy C/GTK3 application remains available separately.

## Requirements

Use the archive matching `uname -m`: **x86_64** or **aarch64** (ARM64).
The preview is built and tested on **Ubuntu 24.04**, using glibc and **GTK 4.10+**.
Other distributions with compatible libraries may work but are not validated.
These archives do not target musl/Alpine or older glibc systems. They include the
required Swift libraries; Swift, Rust and development packages are not needed.
GTK, GLib, graphics drivers, fonts and other system libraries remain dependencies.

On Ubuntu 24.04:

```sh
sudo apt-get update
sudo apt-get install libgtk-4-1 adwaita-icon-theme librsvg2-common libstdc++6 libgcc-s1 python3
```

Python 3.11+ is only used by the optional install/uninstall scripts. Running directly
from the extracted archive requires a POSIX shell and coreutils, not Python.
Graphical launch needs a desktop session. Headless mode still loads GTK libraries.

## Verify, extract and run

Download the `.tar.gz` and matching `.sha256` from the same CI artifact. In their
directory, run `sha256sum -c xrg-ng-*.sha256`, then extract the archive with `tar -xzf`.
Enter its extracted directory and run:

```sh
./xrg-ng-linux
./xrg-ng-linux --version
./xrg-ng-linux --headless --samples 3
```

Checksums detect incomplete or changed downloads; these preview artifacts are not
signed release packages. Keep the whole extracted tree together; moving the ELF
executable alone will lose its private libraries. The launcher also works after
moving the extracted directory, including paths with spaces.

## Optional desktop installation

```sh
./install.sh
```

This installs under `~/.local`, creates `~/.local/bin/xrg-ng-linux`, and adds
**XRG-ng Preview** to the application menu. The desktop entry uses an absolute path
and does not require `~/.local/bin` in the desktop session's PATH. Add that directory
to your terminal PATH if needed. No sudo is required. A custom absolute prefix is
supported with `./install.sh --prefix /absolute/path`; pass the same prefix to
uninstall. Installation paths containing control characters are rejected.
For a custom prefix, its `share/` directory must be on the desktop session's
`XDG_DATA_DIRS` for automatic application-menu discovery; direct launch still works.

Run the installer again from a new extracted archive to upgrade. It replaces only
an installation bearing its own ownership record. Existing files at the launcher,
desktop entry or icon paths, and modified application files, cause a refusal with
their contents preserved. Keep the archive outside the installation directory.

To remove it:

```sh
~/.local/lib/xrg-ng/uninstall.sh
# Or: ./uninstall.sh --prefix /absolute/path
```

Uninstallation preserves `~/.config/xrg-ng/settings.conf`, provider data and the
legacy C application's installation/settings. It refuses to remove an installation
whose recorded files or desktop integration have been changed.

## Sources and attribution

`manifest.json` records the source commit, toolchains, architecture, input hashes,
private/system library inventory and package file hashes. A development package
is explicitly marked `dirty: true`; CI packages require a clean checkout.
`source.tar.gz` includes the corresponding project snapshot and locked Cargo
dependency sources. Extract it, enter `source/`, and follow the Linux build guide
in `xrg-linux/rust/README.md`. The included `.cargo/config.toml` selects `vendor/`
for offline Cargo dependency resolution. Swift/Rust toolchains and GTK development
packages are still needed to rebuild. The Swift runtime is unmodified apart from
relative ELF loader paths. Licenses/notices are in `share/doc/xrg-ng/`.

## Hardware support and feedback

Hardware support is a **best-effort attempt**. We do not own most GPU, sensor and
driver combinations and cannot physically validate them all. Automated fixtures,
native architecture CI and clean-runtime launch checks verify software behavior;
they do not establish real-device compatibility or Wayland/compositor behavior.
Physical validation of every platform is not a release prerequisite.

**Feedback is welcome and encouraged**, including working setups. Please open an
issue at https://github.com/sdelavega/XRG-ng/issues with the manifest revision,
distribution, kernel, architecture, device/driver and expected/observed behavior.
See `share/doc/xrg-ng/DEVELOPMENT.md` for collector limits and remaining features.
