# macOS sensor names and battery capacities

Sensor keys remain the identity used for selections, statistics and history.
Presentation labels retain the key after a middle dot so similarly named channels
can be distinguished in preferences, graphs and diagnostic exports.

HID labels expand the driver's product names: `PMU2 tdie4` is “Power management 2
die 4”, `PMU tdev8` is “Power management device 8”, `NAND CH0 temp` is “Storage
temperature channel 0”, `als-temp` is “Ambient light sensor temperature” and
`gas gauge battery` is “Battery temperature”. PMU die/device numbers are driver
channel numbers, not CPU core numbers or a claim about physical board placement.

SMC labels use established descriptions for a small set of unambiguous legacy
keys and broader CPU/GPU/memory/battery family names. Undocumented channels have
the explicit fallback “Temperature sensor” plus their original key. The same
Apple Silicon key can identify different cores across chip generations; these
labels deliberately avoid assigning core numbers from another chip's layout.
`Tp0P` on Intel retains its power-board meaning.

References checked 2026-11-04:

- [VirtualSMC key reference](https://github.com/acidanthera/VirtualSMC/blob/master/Docs/SMCSensorKeys.txt)
- [Stats sensor definitions](https://github.com/exelban/stats/blob/master/Modules/Sensors/values.swift),
  consulted for family meanings and cross-generation ambiguity, not copied as a
  sensor catalogue or implementation.
- Local IORegistry temperature-service product names, used to check the PMU,
  storage, ambient-light and battery naming rules.

Battery capacities are mAh only when a valid raw current/maximum pair is present.
The collector prefers the top-level `AppleRawCurrentCapacity` /
`AppleRawMaxCapacity` pair, then the same pair inside `BatteryData`. It never
combines halves from different dictionaries or labels normalized 0–100 capacity
fields as mAh. Real zero charge is valid; missing/invalid pairs remain unavailable.
The nested path was reproduced on the local AppleSmartBattery driver, which
reported 5,358 mAh current and maximum while its top-level normalized fields
reported 100/100.

NPU “Quiet” is explained in [macos-npu-telemetry.md](macos-npu-telemetry.md).
