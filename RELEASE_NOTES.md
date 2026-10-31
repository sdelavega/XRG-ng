# XRG-ng 0.2.1

The complete release notes for 0.2.1 — including the Linux changes since
0.2.0, Windows status, install instructions and validation limits — live in
[releases/0.2.1.md](releases/0.2.1.md).

macOS summary since 0.1.0: an Apple Neural Engine panel (Apple silicon),
optional VRAM and Fans graphs, a searchable process table with live
inspectors and confirmed process actions, persistent CPU/GPU source
selection, per-graph presentation controls, portable JSON themes shared with
Linux (XTF keeps working), explicit history capacities and 1–60 minute
observation windows (AI up to 1,440 minutes), sampling that continues while
graphs are hidden, observed AI session/daily accounting with budget alerts,
weather history windows, and the new GPL read-only SMC sensor backend.

New in 0.2.1 itself: Sparkle 2.10.1 automatic updates (**Check for
Updates…** in the application menu; signed feed; daily once you allow
automatic checks; 0.1.0 settings preserved), a Homebrew cask
(`brew install --cask sdelavega/tap/xrg-ng`), and **Help → Support XRG-ng…**
for GitHub Sponsors.

Validation is stated honestly in the release notes: the macOS Release gate
ran natively on ARM and under Rosetta (Rosetta does not replace physical Intel
hardware), the full Linux gate ran in an ARM64 container and on physical
Raspberry Pi 5 and Orange Pi 5 Plus boards (both complete debug gates pass
for this release), Windows compile and unit-test checks ran manually on a
Windows 11 machine, x86-64 and ARM64 Linux and Windows CI pass, and no
physical sleep/wake claims are made. A known limitation of the
pre-existing AI log scanner is documented: a same-size rewrite within the
filesystem's timestamp granularity can go unnoticed on coarse-timestamp
filesystems (observed on Raspberry Pi 5); a fix is planned after 0.2.1.

macOS 26 or newer, universal (Apple silicon and Intel). Copyright and
third-party license notices are included in the app and source.
