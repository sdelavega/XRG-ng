# XRG-ng third-party notices

The project license is GPL-3.0-or-later; the full text is in LICENSE.
The original project headers permitted GPL version 2 or any later version,
which permits choosing GPL version 3. Existing third-party copyrights and
licenses remain in force for their respective files.

## macOS sensor backend

The current sensor backend is first-party GPL-3.0-or-later code. The APSL-derived
SMC implementations, translated decoder/cache, copied HID vendor headers and
inherited sensor-name catalog have been removed from this source tree and build.
The replacement uses a read-only driver protocol, generated key-based labels,
and SDK/system interfaces. It does not relicense the removed implementations.

Historical releases, including macOS 0.1.0, retain the notices and distribution
arrangement recorded with their corresponding source revisions. Do not remove
notices from those historical packages. The dependency notices below still apply
to current distributions; replacement of the sensor backend does not remove them.

## macOS Sparkle updater

The macOS app embeds [Sparkle](https://github.com/sparkle-project/Sparkle)
2.10.1 (Swift Package Manager, `Sparkle` product) for signed appcast update
checks. Sparkle is distributed under the MIT license:

> Copyright (c) 2006-2013 Andy Matuschak.
> Copyright (c) 2009-2013 Elgato Systems GmbH.
> Copyright (c) 2011-2014 Kornel Lesiński.
> Copyright (c) 2015-2017 Mayur Pawashe.
> Copyright (c) 2014 C.W. Betts.
> Copyright (c) 2014 Petroules Corporation.
> Copyright (c) 2014 Big Nerd Ranch.
> All rights reserved.
>
> Permission is hereby granted, free of charge, to any person obtaining a copy of
> this software and associated documentation files (the "Software"), to deal in
> the Software without restriction, including without limitation the rights to
> use, copy, modify, merge, publish, distribute, sublicense, and/or sell copies of
> the Software, and to permit persons to whom the Software is furnished to do so,
> subject to the following conditions:
>
> The above copyright notice and this permission notice shall be included in all
> copies or substantial portions of the Software.
>
> THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
> IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
> FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE
> AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
> LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM,
> OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN THE
> SOFTWARE.

The resolved package version is recorded in
`XRG-ng.xcodeproj/project.xcworkspace/xcshareddata/swiftpm/Package.resolved`.
Sparkle's framework and its bundled XPC services keep their own notices inside
`Sparkle.framework`.

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

## Linux egui frontend

The Linux desktop frontend uses egui/eframe 0.37.0 (MIT OR Apache-2.0).
The upstream workspace license texts are retained under
`xrg-linux/rust/licenses/egui-workspace-0.37.0/`, pinned to the published crate's source
commit with URLs and SHA-256 hashes. The default embedded fonts have their own
Ubuntu Font License, SIL Open Font License and MIT notices; packaging copies all
of `epaint_default_fonts`'s `fonts/*.txt` notices alongside its Cargo metadata.
The corresponding font/code sources are also retained in the vendored source archive.

## Linux preview archives

Preview archives retain the project license/credits, dependency license files and
Cargo package metadata under `share/doc/xrg-ng/`. Their `source.tar.gz` contains
the corresponding project snapshot and locked Cargo sources, including third-party
source notices. Rust standard-library copyright and license files are copied from
the build toolchain. The egui/eframe frontend carries its resolved Cargo notices.
glibc, window-system and graphics driver libraries are system dependencies and
are not included in the archive. GTK, GSK, Cairo and GLib are excluded from the
new frontend dependency graph and checked during packaging.

The private Swift 6.4.1 libraries include Swift, Foundation, Dispatch, BlocksRuntime
and Foundation's ICU dependency. The toolchain's license is copied into the package.
Additional upstream notices are retained in `xrg-linux/rust/licenses/swift-6.4.1/`;
`sources.json` records the upstream release URLs and hashes. ICU 76.1 notices follow
the version selected in Swift 6.4.1's Foundation ICU source. Bundled ELF loader
paths are adjusted for relocation; the runtime implementations are otherwise
unchanged. Changing the toolchain/runtime version requires reviewing these notices.
# AppImage distribution runtime

Linux AppImage previews additionally embed the upstream AppImage type-2 runtime.
The runtime asset/revision and source archive hashes are recorded in
`Tools/appimage-runtime.json`. Each image includes
`usr/share/doc/xrg-ng/appimage-runtime-source.tar.gz` containing the upstream
runtime source, MIT notice, libfuse 3.15.0 source/LGPL notices and upstream patch,
squashfuse source/notices, and reference source/license archives for musl, zstd,
zlib and mimalloc. Build/relink instructions accompany those sources. This
external distribution runtime does not change the project's GPL license or
replace the application's corresponding Rust/Swift source archive.
