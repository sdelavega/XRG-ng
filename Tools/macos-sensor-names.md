# macOS sensor names and battery capacities

Sensor keys remain the identity used for selections, statistics and history.
Presentation labels retain the key after a middle dot so similarly named channels
can be distinguished in preferences, graphs and diagnostic exports.

HID labels expand the driver's product names: `PMU2 tdie4` is “Power management 2
die 4”, `PMU tdev8` is “Power management device 8”, `NAND CH0 temp` is “Storage
temperature channel 0”, `als-temp` is “Ambient light sensor temperature” and
`gas gauge battery` is “Battery temperature”. PMU die/device numbers are driver
channel numbers, not CPU core numbers or a claim about physical board placement.

SMC labels optionally use descriptions from the installed system `libSMC`, only
when its catalogue has an exact match for the driver's `RBr ` hardware branch.
The optional reader uses bounded, checked memory copies and disables itself on
unreadable data, an unexpected layout or ambiguous branch records. No system
description catalogue is bundled with XRG. Without matching metadata, labels use
conservative families; precise diode/heatsink/board locations are not inferred
from a shared FourCC. `Tm0P` and `TG0H`, for example, have incompatible meanings
across documented branches. Undocumented channels have
the explicit fallback “Temperature sensor” plus their original key. The same
Apple Silicon key can identify different cores across chip generations; these
labels deliberately avoid assigning core numbers from another chip's layout.
Apple Silicon CPU/GPU prefix rules are not applied to Intel hardware.

The installed catalogue does not cover the local M5. Unknown channels therefore
remain generic. See [the identification investigation](macos-sensor-identification.md)
for the evidence and remaining limits.

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
