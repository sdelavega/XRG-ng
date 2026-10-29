# XRG-ng for Linux

The supported Linux implementation is **Rust + shared Swift + egui/eframe**.
It has no GTK, GSK, Cairo or GLib application dependency. The old C/GTK3 app,
its CMake build and the uncompiled GTK4 reference frontend have been retired.

- [Build, architecture, hardware support and remaining work](rust/README.md)
- [Preview download/install/upgrade/uninstall](preview/README.md)
- [Legacy retirement and settings compatibility](RETIREMENT.md)

From the repository root:

```sh
cargo run --manifest-path xrg-linux/rust/Cargo.toml --features egui-ui
cargo run --manifest-path xrg-linux/rust/Cargo.toml -- --headless --samples 3
```

Native builds require the matching Swift and Rust toolchains; preview bundles
include the Swift runtime. See the build guide for X11/Wayland/OpenGL requirements.

All thirteen graph modules, built-in/custom themes, JSON/XTF theme imports,
legacy settings review, process tools, AI monitoring and optional station weather
are implemented in the current application. Hardware telemetry is best effort;
missing values remain unavailable and community feedback is welcome.
