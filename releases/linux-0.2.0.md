# XRG-ng Linux 0.2.0

The Rust/Swift Linux application now ships as a signed release for **x86-64 and
ARM64**. Each architecture has a `.deb`, `.rpm`, `.pkg.tar.zst`, `.AppImage` and
relocatable `.tar.gz`. The private Swift runtime, corresponding project and locked
Cargo dependency sources, provenance and license notices are included.

The egui interface follows the macOS graph layout, with built-in and custom themes,
CPU/GPU/NPU, memory, storage, network, sensors, process and AI monitoring, plus
optional station weather. Legacy C/GTK sources are retired. Existing installations
and preferences remain untouched until you explicitly install or import settings.

Native CI exercises both architectures, Debug and Release, X11 and nested Wayland
desktop checks, and clean runtime install/launch/upgrade/remove checks on Ubuntu
24.04, Fedora 44, Arch Linux (x86-64) and Arch Linux ARM (aarch64). A separate
archive upgrade test builds the frozen 0.1.0 application, installs 0.2.0 over it,
and checks effective custom themes, module ordering, graph options and preferences.
Native package tests also exercise packaging revision upgrades.

Hardware support remains a **best-effort attempt**; most GPU/NPU and sensor
combinations have not been physically tested. Automated desktop checks use Mesa
software rendering. AppImage extraction/relocation is tested without FUSE; mounted
AppImage operation and arbitrary desktop compositors are not established by CI.
Feedback, working setups and bug reports are welcome and encouraged.

Verify downloads using the [release signing instructions](https://github.com/sdelavega/XRG-ng/blob/main/signing/README.md)
and the dedicated primary fingerprint:

```text
8DAC471BBD9BC89CD1C881AEA09F0F040FA937A4
```

`SHA256SUMS.asc` authenticates the complete asset set. RPMs also have native header
signatures and Arch packages have `.sig` files. `release-metadata.json` identifies
the exact source revision and successful CI run. There is no package repository.
See the [Linux installation guide](https://github.com/sdelavega/XRG-ng/blob/main/xrg-linux/preview/README.md)
for dependencies, installation and removal. glibc 2.39+ is required; Alpine/musl
and older glibc systems are not supported by these binaries.

This Linux release uses tag `linux-v0.2.0`. The macOS 0.1.0 release and update feed
remain separate.
