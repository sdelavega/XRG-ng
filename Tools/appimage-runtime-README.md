# AppImage runtime inputs

XRG-ng embeds the unmodified upstream type-2 runtime identified by the commit,
immutable GitHub asset ID and SHA-256 in `inputs.json`. Updating these inputs is
an explicit packaging change; builds fail on a checksum mismatch.

The included type2-runtime source archive contains its MIT license, runtime
sources, Makefile, build instructions, Docker recipe and libfuse patch. The
libfuse 3.15.0 and squashfuse 0.5.2 archives match the versions/hashes pinned in
that upstream build recipe. Sources include the LGPL libfuse license and permit
modification and relinking of the runtime. Follow the included `BUILD.md` and
`scripts/docker/Dockerfile`; `scripts/common/install-dependencies.sh` applies the
included libfuse patch. The upstream recipe supplies the remaining static
libraries from Alpine 3.21.

Reference source archives and license notices for musl, zstd, zlib and mimalloc
are also included. These are not a claim that all upstream Alpine package
revisions or the complete application build reproduce byte for byte.

A rebuilt runtime can be combined with the AppDir using XRG-ng's corresponding
`Tools/linux_formats.py` packaging source. The runtime pins protect published
builds; they do not restrict personal modification or replacement. The
application's Rust/Swift sources and locked dependency sources are provided
separately in `source.tar.gz` in the same documentation directory.

The repository vendors all runtime inputs under `Tools/appimage-runtime/` and
verifies their hashes before use. Thus RPM/Arch/archive corresponding-source
snapshots that contain the runtime binaries also contain the runtime/library
source archives. AppImage builds do not fetch moving release assets at build time.
