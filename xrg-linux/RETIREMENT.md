# Retired Linux implementations

The Rust/shared Swift/egui application is now the only supported Linux build.
The unused C/GTK3 application and its CMake build, old desktop entry, and archived
GTK4 Rust frontend have been removed from the active checkout. They are not
packaged or rebuilt as fallback executables.

The last revision containing both retired trees is
[`fc8ebe765888c035720a0eeea98bd17055f7ffa0`](https://github.com/sdelavega/XRG-ng/tree/fc8ebe765888c035720a0eeea98bd17055f7ffa0/xrg-linux).
Git history preserves the implementation and its attribution. For example:

```sh
git show fc8ebe765888c035720a0eeea98bd17055f7ffa0:xrg-linux/CMakeLists.txt
```

The desktop icon was retained, unchanged, at
`preview/com.sdelavega.xrg-ng.svg`; current packaging uses that asset directly.
No current application source depends on a retired tree. CI and packaging check
that the retired paths are absent and the active assets remain available.

## Existing installations and settings

Source retirement does not remove installed applications, desktop entries or
user configuration. The current installer continues to preserve unrelated
`xrg-linux` executables and settings. Users can remove an older installation
using the installation method they originally used; no automatic purge is run.

The Rust legacy-settings reader remains supported. Preferences → Themes / import
can review the old `xrg-linux/settings.conf`, then import supported fields into a
draft. Only Apply changes current settings. The old file is read-only; current
preferences live under `xrg-ng/settings.conf`. Original XRG XTF themes and portable
JSON themes remain supported as documented in the current build guide.

The shared C ABI header and `Tools/SharedABISmoke.c` are intentional Swift/Rust
interoperability checks, not remnants of the retired application. The two macOS
Objective-C hardware boundaries are also unaffected by Linux source retirement.
