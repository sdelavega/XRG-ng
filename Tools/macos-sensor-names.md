# macOS sensor names and battery capacities

Sensor keys remain the identity used for selections, statistics and history.
Presentation labels retain the key after a middle dot so similarly named channels
can be distinguished in preferences, graphs and diagnostic exports.

HID labels expand the driver's product names: `PMU2 tdie4` is “Power management 2
die 4”, `PMU tdev8` is “Power management device 8”, `NAND CH0 temp` is “Storage
temperature channel 0”, `als-temp` is “Ambient light sensor temperature” and
`gas gauge battery` is “Battery temperature”. PMU die/device numbers are driver
channel numbers, not CPU core numbers or a claim about physical board placement.

For the temperature services directly published by `AppleSMCKeysEndpoint`,
the driver uses `LocationID` as its SMC source key. XRG applies their recognized
PMU/battery names to that exact key when it is present in the SMC temperature
inventory. This metadata takes precedence over older branch descriptions.
Other HID providers are excluded from this join, and ambiguous or malformed
records retain the existing fallback label. The source-key argument proof is
recorded in [the identification investigation](macos-sensor-identification.md).
On the M5 MacBook Air (`Mac17,4`), verified firmware ADC links also let those
published names identify 21 readable `TPD` / `TRD` stream channels and eleven
device-temperature streams. Labels
require each exact source's metadata and retain the stream's original key.
Three computed readings now describe their actual maximum operations instead
of implying individual CPU sensors; see
[the stream and maximum proofs](macos-smc-firmware-investigation.md#resolved-j815-pmu-die-streams-and-computed-maxima).
Two further PMU2 readings use temperature-channel ordinals because their
specific die/device roles remain unknown. Verified PMU device identities
override misleading generic CPU/memory/drive families on this exact model;
see [the device-stream proof](macos-smc-firmware-investigation.md#resolved-j815-pmu-device-streams).
Four other M5 readings are named by their two verified serial temperature
monitors and channel ordinals. Six additional computed fields describe
verified maximum operations, including adjusted GPU/CPU temperature maxima.
These names identify producer/algorithm roles without inferring board
placement; see [the monitor and maximum proofs](macos-smc-firmware-investigation.md#resolved-j815-serial-monitors-and-further-maxima).

Duplicate HID products use the driver's `LocationID` to keep their channels
separate. For example, six `gas gauge battery` services on the local M5 become
distinct `Battery temperature · HID TG0B` / `TG0C` / `TG0H` / `TG0V` / `TG1B` /
`TG2B` channels. These FourCCs are source IDs, not GPU labels or an inferred
assignment to battery cells. The persisted identity includes the HID namespace,
numeric LocationID and original product. Unknown/non-FourCC IDs remain hexadecimal.

Unique products retain their existing IDs. Once a duplicate product is observed
in a process, it stays disambiguated through transient event failures or service
removal. Missing/invalid/duplicate LocationIDs suppress an ambiguous product;
iteration order never chooses a winner. An old saved duplicate-product selection
(such as `gas gauge battery`) becomes unavailable and requires selecting one of
the distinct channels. That old key did not reliably identify a physical source,
so it is not silently redirected. Sensor histories/settings are not reassigned.

Missing or invalid sensor readings produce missing markers in both sample-count
and timestamp-window history. They never become plotted zero temperatures or
zero-RPM observations and do not pull the automatic thermal axis toward zero.
An actual zero fan reading remains zero. The disabled sensor's legacy current
scalar remains zero for compatibility; availability is determined by `isEnabled`,
and current labels remain `n/a`. Copied diagnostic reports also use `n/a` for
disabled or nonfinite readings and preserve genuine zero readings. Recovery
retains the selected source and history.

Discovered HID channels appear in normal sensor lists and pickers without enabling
“Show Unknown Sensors”. Their identities come from the HID temperature transport,
independently of the SMC key inventory. The reader remembers discovered HID IDs
through transient missing events, so a selected channel shows `n/a` instead of
vanishing from the list. Friendly HID names also work when SMC initialization or
metadata lookup fails. Merely resembling a HID product or encoded ID does not
make an unobserved key known. The Sensors window fits its initial friendly names
within the current screen once, then preserves manual resizing on later polls.
The SMC inventory count and unknown-SMC policy are unchanged.

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

The installed catalogue does not cover the local M5. Since 2026-11-05 each
sensor shows one best name chosen from the verified roles, Apple's board
descriptions and credited Stats and Asahi Linux names; a community component
name replaces a channel-only verified name such as "Power management device 4".
See [sensor names, models and groups](macos-sensor-community-names.md).
Channels that no source covers remain generic. See [the identification investigation](macos-sensor-identification.md)
for the evidence and remaining limits.

References checked 2026-11-04:

- [VirtualSMC key reference](https://github.com/acidanthera/VirtualSMC/blob/master/Docs/SMCSensorKeys.txt)
- [Stats sensor definitions](https://github.com/exelban/stats/blob/master/Modules/Sensors/values.swift)
  (MIT). Since 2026-11-05 its Apple Silicon and Intel key names are used,
  with credit, where they are the best available name; see
  [community sensor names](macos-sensor-community-names.md).
- [Asahi Linux hwmon device trees](https://github.com/torvalds/linux/tree/master/arch/arm64/boot/dts/apple)
  (GPL-2.0+ OR MIT), used for `TH0x`, `TB0T`, `TCHP` and `TW0P`.
- Local IORegistry temperature-service product names, used to check the PMU,
  storage, ambient-light and battery naming rules.

Battery capacities are mAh only when a valid raw current/maximum pair is present.
An `AppleSmartBattery` service reporting `BatteryInstalled=false` is excluded:
desktop Macs can expose this service without a physical battery. The battery
panel then shows “No Battery Found”, rather than “On Hold” and unavailable
capacity fields. Missing installation flags retain legacy power-source behavior;
an installed battery at zero charge is still a real battery.
Failed battery polls show “Battery unavailable”, distinct from a successful
read that finds no installed battery. They append missing power samples in both
history modes. The last capacity snapshot remains cached for compatibility, but
the panel hides stale charge, charging state and watt readings until a successful
poll. Recovery with the same nonzero installed-battery count retains the history
and failure gap.
An observed change in installed-battery count clears both power histories. No
installed batteries means missing history, while a real zero-watt reading from
an installed battery remains zero. This boundary detects count changes, not a
replacement that leaves the count unchanged.
The collector prefers the top-level `AppleRawCurrentCapacity` /
`AppleRawMaxCapacity` pair, then the same pair inside `BatteryData`. It never
combines halves from different dictionaries or labels normalized 0–100 capacity
fields as mAh. Real zero charge is valid; missing/invalid pairs remain unavailable.
The nested path was reproduced on the local AppleSmartBattery driver, which
reported 5,358 mAh current and maximum while its top-level normalized fields
reported 100/100.

On the validated M4 Pro Mac mini (`Mac16,11`), twelve `Ta` keys now have
Neural Engine channel labels. Six raw channels each have a distinct adjusted
reading with a firmware-defined +8.2°C offset. These labels require that exact
model; stream order does not imply physical core placement. The named
`ANE-TO-SMC` provider trace is recorded in
[the firmware investigation](macos-smc-firmware-investigation.md#resolved-j773s-neural-engine-channels).
The same validated model has 26 `Ts` readings from nine MTR die-temperature
channels, labeled by current, average and adjusted-average role. Channel
ordinals identify firmware streams, without claiming CPU/GPU core locations.
The [die-temperature trace](macos-smc-firmware-investigation.md#resolved-j773s-die-temperature-channels)
records the configuration dispatch, counter calculation and native checks.

On `Mac17,4`, `TH0x` uses the same verified PMU2 device 2 source as `TH0T`.
`TVMD` is a thermal-control selector and is excluded from Celsius readings;
its categorical lookup consumers are documented in the
[firmware investigation](macos-smc-firmware-investigation.md#resolved-j815-copied-pmu-channel-and-categorical-selector).
This exact exclusion does not remove zero-valued temperature readings.
Nine other `TV` keys on this model have labels for their verified fixed-model,
adaptive-model, clamp and maximum roles. These names describe calculations;
they make no physical-location assignment. Their existing value decoding is
unchanged, and the remaining upstream unit contracts are recorded in the
[computation-role trace](macos-smc-firmware-investigation.md#resolved-j815-thermal-computation-roles).

On `Mac16,11`, 48 PMU die-stream labels include **(average)** because their
exported backings contain accumulated averages. The maps explicitly skip
`TPDF`, `TRDF` and `TTDF`; those keys retain generic labels. Primary published
PMU identities are used where proven, while the other labels identify firmware
stream and die-channel numbers without assigning package positions. All
eighteen selected device inputs and six computed maxima also have verified roles. See the
[M4 PMU trace](macos-smc-firmware-investigation.md#resolved-j773s-pmu-streams).
Its case-sensitive `TVmd` input and `TVMD` selector are categorical controls,
excluded from Celsius readings on this exact model; see the
[control and maximum proof](macos-smc-firmware-investigation.md#resolved-j773s-categorical-controls-and-computed-maxima).
Four other M4 outputs have verified fixed-model role labels, with formulas
independently decoded for this board; see the
[M4 model trace](macos-smc-firmware-investigation.md#resolved-j773s-fixed-model-roles).
The M4 `TH0a` and `TH0b` labels describe two calibrated channels, and `TH0x`
describes their maximum. Their earlier Drive family labels had no established
physical-source join; see the
[calibrated-channel proof](macos-smc-firmware-investigation.md#resolved-j773s-calibrated-channels-and-their-maximum).
On M5, `TAOL` is labeled **Ambient light sensor temperature**. Matching-build
AOP firmware binds the exact `als-temp` provider to slot zero of the writable
`zEAO` packet, which current SMC code maps to `TAOL`. This names the sensor
component, without claiming ambient-air temperature or a physical die site.
The independent upstream unit contract remains recorded in the investigation.
On M5 Mac17,4, the native `NAND CH0 temp` HID reading uses **Storage composite
temperature**. Its exact `TN0n` provider reads the NVMe SMART composite field,
which the matching ANS firmware derives from a maximum. This describes an
aggregate storage reading, without assigning an individual NAND die. Other
models and qualified HID locations retain their existing channel labels.
The native product/raw identity and Objective-C naming selector stay unchanged.

M4 `TfC0`–`TfC4` use **Power management temperature maximum N (filtered
average)** labels. Each is a sample average of a filtered maximum of two
configured thermal captures. Exact named Abbey PMU parents establish the
power-management provider; CPU/GPU placement and downstream transducer sites
are not inferred from packet prefixes. Empty averaging windows still export
zero; these labels do not add availability filtering.

NPU “Quiet” is explained in [macos-npu-telemetry.md](macos-npu-telemetry.md).
