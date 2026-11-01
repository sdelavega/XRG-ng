# XRG-ng 0.2.2

The complete release notes for 0.2.2 live in
[releases/0.2.2.md](releases/0.2.2.md).

A fix release. On macOS, 0.2.1 could use a full CPU core continuously: the
Temperature graph re-sorted every sensor once per reading, and one AI log
over the size limit made every AI scan start over. 0.2.2 sorts once per
update, keeps per-file scan results when another file fails, and reads
growing Claude Code and Codex logs incrementally after verifying their
earlier bytes. With the same sensors, settings and logs it measured 3.1% of
one core, against 89.3% for 0.2.1.

On both platforms, AI usage logs up to 1 GiB per file now count (previously
64 MiB), and a log rewritten to the same size is re-read instead of keeping
stale totals.

macOS 26 or newer, universal (Apple silicon and Intel). Existing installs get
the update through **Check for Updates…**; Homebrew users can run
`brew upgrade --cask xrg-ng`. Linux ships signed packages for x86-64 and
ARM64. Copyright and third-party license notices are included in the app and
source.
