# XRG-ng third-party notices

The project license is GPL-3.0-or-later; the full text is in LICENSE.
The original project headers permitted GPL version 2 or any later version,
which permits choosing GPL version 3. Existing third-party copyrights and
licenses remain in force for their respective files.

## Apple Public Source License 2.0

The following source files retain APSL 2.0:

- `Data Miners/APSL/SMCInterface.h`, `SMCInterface.m`, and `SMCPacket.h`: Apple Computer, Inc., 2004; native-boundary modifications by Stephen de la Vega, 2026.
- `XRGCore/XRGSMCInterface.swift`: Swift translation of the original SMC interface and CodeExchange decoder; Apple Computer, Inc., 2004, CodeExchange, 2012; modifications by Stephen de la Vega, 2026. This translation remains APSL 2.0.
- `Data Miners/APSL/SMCSensors.h`: CodeExchange, 2012, and Apple Computer, Inc., 2004.
- `XRGCore/SMCSensors.swift`: Swift translation of `SMCSensors.m`, CodeExchange, 2012; modifications by Stephen de la Vega, 2026. The translation remains APSL 2.0.
- `Data Miners/APSL/AppleHIDUsageTables.h` and `IOHIDEventTypes.h`: Apple Computer, Inc., 1999–2003.

The full license is preserved in `Data Miners/APSL/APSL.txt` and included
in macOS app resources as `APSL.txt`. First-party sensor adapters and grouping
code keep their GPL notices; the APSL-derived Swift translation is listed above.

The macOS app currently compiles the SMC implementations into its executable.
The FSF lists APSL 2.0 as incompatible with the GNU GPL. Keeping both license
texts does not resolve that incompatibility: distribution of the combined
executable requires a compatible replacement, suitable permission, or another
resolved licensing arrangement. This project license update does not claim
to resolve that existing issue.

For the XRG-ng 0.1.0 release, the current maintainer has confirmed that distribution
permission or a licensing arrangement is in place. The original APSL license
notices and source attribution remain unchanged.

Reference: https://www.gnu.org/licenses/license-list.en.html#apsl2

## Other contributors

Other authors' source notices and Git authorship remain part of the project
attribution. The project credits in COPYRIGHT do not supersede them.

## Linux Rust SQLite dependencies

The Swift/Rust Linux executable uses rusqlite and libsqlite3-sys (MIT, copyright
2014 The rusqlite developers). Their license is retained in
`xrg-linux/rust/licenses/rusqlite-MIT.txt`. The bundled SQLite implementation is
in the public domain; see https://www.sqlite.org/copyright.html.
Cargo.lock records the complete Rust dependency versions. Distribution packaging
must include applicable dependency notices alongside the Swift runtime notices.

## Linux Rust JSON decoding

The Rust process/TPU port uses Serde and serde_json under their MIT license option.
Their license text is retained in `xrg-linux/rust/licenses/serde-MIT.txt` (identical
in the selected crate versions). Cargo.lock records exact versions and transitive
dependencies; distribution packaging must retain their applicable notices too.

## Linux Rust property-list decoding

The Linux XTF theme importer uses rust-plist (MIT, copyright 2015 Edward Barnard).
Its license is retained in `xrg-linux/rust/licenses/plist-MIT.txt`. Cargo.lock records
the parser and its transitive dependency versions. Preview source archives retain
their Cargo sources and applicable license notices. The streaming API is pinned
to the plist 1.10 minor release as required by that API's stability policy.

## Linux Rust transcript cache fingerprints

The Linux AI log scanner and XTF profile identification use the BLAKE3 crate under its CC0-1.0 license option.
The text is retained in `xrg-linux/rust/licenses/blake3-CC0.txt`. Cargo.lock records
exact versions and dependencies; preview source archives retain the corresponding
Cargo sources and license notices. These digests verify reusable parsed prefixes
and identify supported theme profiles;
they are not used as authentication or encryption.

## Linux Display P3 theme fixtures

The Display P3 XTF fixture embeds `DisplayP3-v4.icc` from
[Compact ICC Profiles](https://github.com/saucecontrol/Compact-ICC-Profiles),
revision `bdd84663061bc4ae95ca70decff54f581e27f702`. Its author releases the profiles
under CC0-1.0; the text is retained in
`xrg-linux/rust/licenses/Compact-ICC-Profiles-CC0.txt`. The unmodified 480-byte
profile is retained beside the fixture. Apple's system profile bytes are used
only for optional local verification and are not redistributed here.

## Linux preview archives

Preview archives retain the project license/credits, dependency license files and
Cargo package metadata under `share/doc/xrg-ng/`. Their `source.tar.gz` contains
the corresponding project snapshot and locked Cargo sources, including third-party
source notices. Rust standard-library copyright and license files are copied from
the build toolchain. GTK, GLib, glibc and graphics driver libraries are system
dependencies and are not included in the archive.

The private Swift 6.4.1 libraries include Swift, Foundation, Dispatch, BlocksRuntime
and Foundation's ICU dependency. The toolchain's license is copied into the package.
Additional upstream notices are retained in `xrg-linux/rust/licenses/swift-6.4.1/`;
`sources.json` records the upstream release URLs and hashes. ICU 76.1 notices follow
the version selected in Swift 6.4.1's Foundation ICU source. Bundled ELF loader
paths are adjusted for relocation; the runtime implementations are otherwise
unchanged. Changing the toolchain/runtime version requires reviewing these notices.
