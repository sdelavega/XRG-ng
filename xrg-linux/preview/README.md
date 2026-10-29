# XRG-ng Linux preview

This is the Rust/Swift + egui application, version 0.1.0. It is an early preview.
The C/GTK implementation has been retired; see the retirement notes in the source
repository. Existing legacy installations and settings are not removed automatically.

## Requirements

Use the archive matching `uname -m`: **x86_64** or **aarch64** (ARM64).
The preview is built and tested on **Ubuntu 24.04**, using glibc and **OpenGL / EGL**.
Other distributions with compatible libraries may work but are not validated.
These archives do not target musl/Alpine or older glibc systems. They include the
required Swift libraries; Swift, Rust and development packages are not needed.
X11/Wayland and graphics driver libraries remain system dependencies. GTK, GSK,
Cairo and GLib are not frontend dependencies.

On Ubuntu 24.04:

```sh
sudo apt-get update
sudo apt-get install libgl1 libegl1 libgl1-mesa-dri libxkbcommon0 libxkbcommon-x11-0 libwayland-client0 libwayland-cursor0 libwayland-egl1 libx11-6 libxcursor1 libxi6 libxrandr2 libstdc++6 libgcc-s1 python3 curl ca-certificates
```

Python 3.11+ is only used by the optional install/uninstall scripts. Running directly
from the extracted archive requires a POSIX shell and coreutils, not Python.
Graphical launch needs a desktop session. The desktop binary loads its windowing/graphics libraries even in headless mode.

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

Use **AI…** for provider totals, recorded Claude/Gemini/Hermes token breakdowns by
model, Ollama inventories and saved source settings.
Preferences → AI can disable providers, override local data paths and select local
HTTP endpoints. These controls and their limits are described in
`share/doc/xrg-ng/DEVELOPMENT.md`.

The title menu opens **Weather**. Requests are off by default; enable
them and apply a four-character ICAO station to show current station observations.
Metric/US units and a 5–60 minute refresh interval are saved. The window shows the
observation age, raw METAR and explicit stale/error states. **Refresh now** obeys
a one-minute request minimum per instance. Weather uses HTTPS to the NWS Aviation
Weather Center; it does not detect your location or provide a forecast.

Right-click a graph or focus it and press **Shift+F10** for live details,
preferences, style and hide actions. Preferences restores graph visibility, keeping saved order, themes and data sources.

Use **Preferences → Themes / import → Browse legacy settings…** to review the C app's
`xrg-linux/settings.conf`. Supported visibility flags and global colors can be
imported into the draft; **Apply** saves them in the new app. Layout orientation
and system temperature units also transfer. Unsupported fields
are listed, and the original file stays unchanged.

The **TPU / NPU** graph includes onboard neural accelerators as well as Coral.
Inventory and activity coverage depend on the driver: see the
[vendor/interface table](../rust/README.md#tpu--npu-neural-accelerators).
Missing counters are unavailable; SoC capability records are explicitly unverified.
Support is best effort and community feedback is encouraged.

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
for offline Cargo dependency resolution. Swift/Rust toolchains and windowing development
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
