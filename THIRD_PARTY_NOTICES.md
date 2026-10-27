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
