# XRG-ng 0.1.0

The first XRG-ng release brings the macOS application logic to Swift while
retaining small native hardware interfaces and the existing graph-based UI.

- CPU, GPU, memory, battery, temperature, network and disk monitoring.
- Weather, stock and multi-provider AI token monitoring.
- Six built-in color themes: Classic, Midnight, Ocean, Dusk, Paper and Phosphor.
- Existing custom colors and `.xtf` theme load/save remain available.
- Accessible graph expansion/collapse actions and improved hidden-panel behavior.
- Universal macOS app for Apple silicon and Intel, requiring macOS 26 or newer.

Download the DMG and drag XRG-ng into Applications, or extract the ZIP. The release
packages are intended to be Developer ID signed, notarized and stapled; SHA-256
checksums and source-commit metadata accompany the downloads.

Validation includes native ARM and Rosetta x86_64 tests, packaged launch/restore/
shutdown checks, and targeted interactive UI checks. Rosetta validation does not
replace physical Intel hardware testing. Sensor accuracy and a complete VoiceOver
session remain separate validation work.

Copyright and third-party license notices are included in the app and source.
