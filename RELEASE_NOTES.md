# XRG-ng 0.2.3

The complete release notes for 0.2.3 live in
[releases/0.2.3.md](releases/0.2.3.md).

A settings release. macOS and Linux now share one settings window, backed by a
single settings catalog and one settings document, drawn with the Aether7b
design language. Its sections are General, Appearance, Graphs, Sources, AI,
Weather, Stocks, Themes & import, and changes apply and save instantly on both
platforms. The document lives at `~/Library/Application Support/XRG-ng/settings.json`
on macOS and `$XDG_CONFIG_HOME/xrg-ng/settings.json` on Linux. On first launch,
0.2.3 migrates your 0.2.2 settings once and leaves the old preferences
untouched, so downgrading to 0.2.2 still works.

Linux gains a Stocks graph (off by default) using the same Yahoo chart data as
macOS, and the sensor-naming work lands on macOS: temperature sensors get real
names, the Temperature settings group them, missing readings stay gaps rather
than zeros, and battery and NPU readings are more reliable.

macOS 26 or newer, universal (Apple silicon and Intel). Existing installs get
the update through **Check for Updates…**; Homebrew users can run
`brew upgrade --cask xrg-ng`. Linux ships packages for x86-64 and ARM64.
Copyright and third-party license notices are included in the app and source.
