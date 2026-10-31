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

Validation is stated honestly in the release notes: native ARM and Rosetta
tests (Rosetta does not replace physical Intel hardware), CI for x86-64 Linux
and for Windows compile checks, an ARM64 container gate plus physical
Raspberry Pi 5 board runs for Linux ARM64 (the Pi's complete debug gate is
not a clean pass — three log-scan unit tests need finer file-timestamp
granularity than that board's 4 ms kernel tick), and no physical sleep/wake
claims.

macOS 26 or newer, universal (Apple silicon and Intel). Copyright and
third-party license notices are included in the app and source.
