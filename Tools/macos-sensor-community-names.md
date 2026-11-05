# Sensor names, model coverage and picker groups

Updated 2026-11-05. Code: `XRGCore/XRGSMCSensors.swift` (name choice and
groups), `XRGCore/XRGSMCCommunityNames.swift` (community tables) and
`XRGCore/XRGMacModels.swift` (models). Licences: `THIRD_PARTY_NOTICES.md`.
Firmware evidence: [status ledger](macos-sensor-identity-status.md).

## Sources

| Source | Used for | Licence |
| --- | --- | --- |
| Firmware investigation in this repository | Verified roles on `Mac16,11` and `Mac17,4` | GPL-3.0-or-later |
| Apple `libSMC` descriptions, read at runtime for the exact board branch | Board-specific names (mostly Intel boards) | Not bundled |
| [Stats](https://github.com/exelban/stats) by Serhiy Mytrovtsiy, [`values.swift`](https://github.com/exelban/stats/blob/27fa75a53d57072ec06adc730dcfe67633d639d2/Modules/Sensors/values.swift) at `27fa75a5` | Apple Silicon key names for M1–M6 and A18 Pro, Intel key names, HID product patterns | MIT |
| Asahi Linux device trees [`hwmon-*.dtsi`](https://github.com/torvalds/linux/tree/05441d697f7f9a927264f4058cbbc6a03dfcac9d/arch/arm64/boot/dts/apple) | `TH0x`, `TB0T`, `TCHP`, `TW0P` | GPL-2.0+ OR MIT |
| Asahi Linux [device list](https://github.com/AsahiLinux/docs/blob/main/docs/hw/devices/device-list.md) | Apple Silicon model identifiers, boards and SoCs | CC BY 3.0 |

Checked and not used: [VirtualSMC's key list](https://github.com/acidanthera/VirtualSMC/blob/master/Docs/SMCSensorKeys.txt)
is a dump of Apple's own `libSMC` strings, which XRG already reads at
runtime for the exact board instead of bundling. [iSMC](https://github.com/dkorunic/iSMC)
is GPL-3.0-only. It also contradicts better evidence: it calls `TCHP` a CPU
heatpipe (Asahi: charge regulator) and the `Ts` keys SSD sensors (firmware:
SoC die channels).

## One name per sensor

Each sensor shows a single name followed by its raw key, e.g.
`Wi-Fi/Bluetooth module temperature · TW0P`. The key stays the saved identity,
so selections and histories are unaffected. The name is the first of:

1. A name written for this exact model, combining sources (below).
2. A firmware-verified name that says what the reading is: a component
   (Neural Engine, SoC die, ambient light sensor, battery) or a computation
   (temperature maximum, thermal model).
3. Apple's `libSMC` description for this board.
4. Asahi, then Stats.
5. A firmware-verified name that only identifies the channel: "Power
   management device 4", "Calibrated temperature channel 1", "Temperature
   monitor 2 channel 1".
6. The family fallback (`CPU temperature`, `Temperature sensor`).

So a community name beats a channel-only verified name (`TW0P` reads
"Wi-Fi/Bluetooth module", not "Power management device 4"), and a verified
component name beats a generic community one.

Community names need a known chip. The app takes it from the model table,
falling back to `machdep.cpu.brand_string` for Macs newer than the table.
Tests inject the chip explicitly.

## Your Mac mini: M4 Pro, `Mac16,11` (J773s)

| Key | Name | From |
| --- | --- | --- |
| `Te05` `Te0S` `Te09` `Te0H` | CPU efficiency core 1–4 | Stats |
| `Tp01` `Tp05` `Tp09` `Tp0D` `Tp0V` `Tp0Y` `Tp0b` `Tp0e` | CPU performance core 1–8 | Stats |
| `Tg1U` `Tg1k` `Tg0K` `Tg0L` `Tg0d` `Tg0e` `Tg0j` `Tg0k` | GPU 1–8 | Stats (M4 Pro/Max GPU 1–2 keys) |
| `Tm0p` `Tm1p` `Tm2p` | Memory proximity 1–3 | Stats; beats "Power management device 5" / "stream 3 device channel 2" |
| `TW0P` | Wi-Fi/Bluetooth module temperature | Asahi `hwmon-mini`; beats "Power management stream 2 device channel 2" |
| `TH0a` `TH0b` | NAND flash temperature 1/2 | Model-specific: `TH0x` is NAND (Asahi, Stats) and the firmware proves it is the larger of `TH0a`/`TH0b` |
| `TH0x` | NAND flash temperature (hottest) | Same |
| `Ta00`…`Ta0S` | Neural Engine temperature channel 1–6 (and adjusted) | Firmware |
| `Ts00`…`Tsx1` | SoC die temperature channel 1–9 (current/average/adjusted) | Firmware |
| `TPD*` `TRD*` `TTD*`, PMU device keys | Power management die/device/stream names | Firmware; no better source |
| `TfC0`–`TfC4`, `TCMb`, `TPDX`, `TV*` | Maxima and thermal-model roles | Firmware |
| `TPDF` `TRDF` `TTDF` `Tz11`–`Tz18` `Tz1j` | Temperature sensor | Suspected unused (below) |

The M4 Pro has ten performance cores; Stats lists eight performance keys for
the M4 family, so any others keep `CPU temperature`.

## Your MacBook Air: M5, `Mac17,4` (J815)

| Key | Name | From |
| --- | --- | --- |
| `Tp00` `Tp04` `Tp08` `Tp0C` | CPU super core 1–4 | Stats, limited to the base M5 |
| `Tg0U` `Tg0X` `Tg0d` `Tg0g` `Tg0j` `Tg1Y` `Tg1c` `Tg1g` | GPU 1–8 | Stats |
| `TW0P` | Wi-Fi/Bluetooth module temperature | Asahi `hwmon-laptop`; beats "Power management device 4" |
| `TCHP` | Charge regulator temperature | Asahi `hwmon-laptop`; beats "Power management device 7" |
| `TB0T` | Battery hotspot | Asahi `hwmon-laptop` |
| `TB1T` `TB2T` | Battery 1/2 | Stats |
| `TH0T` `TH0x` | NAND flash temperature | Model-specific: `TH0x` is NAND (Asahi, Stats) and the firmware proves it copies `TH0T` |
| `Ta00` `Ta04` `Ta08` `Ta0K` `Ta0O` `Ta0R` | Neural Engine temperature 1–6 (probable) | Inference, below |
| `Ts00` `Ts04` `Ts08` `Ts0C` `Ts0G` `Ts0K` `Ts0O` `Ts0R` | SoC die temperature 1–8 (probable) | Inference, below |
| `TAOL` | Ambient light sensor temperature | Firmware |
| `TPD*` `TRD*`, PMU device keys, `TDBP` `TDeL` `Ts0P` `Ts1P` | Power management / temperature monitor names | Firmware; no better source |
| `TV*`, `TPDX` `TRDX` `TCMb` | Maxima and thermal-model roles | Firmware |
| `TPDD` `TPDE` `TPDF` `Tz11`–`Tz18` `Tz1j` | Temperature sensor | Suspected unused (below) |

Stats' M5 table follows the M5 Pro/Max layout: six super cores and twelve
performance cores. Apple's base M5 has four super cores and six efficiency
cores ([Apple, 2026-03-03](https://www.businesswire.com/news/home/20260303427628/en/Apple-debuts-M5-Pro-and-M5-Max-to-supercharge-the-most-demanding-pro-workflows)),
so a base M5 gets super cores 1–4 only. Stats has no M5 efficiency-core keys,
so the Air's `Te` sensors keep `CPU efficiency temperature`.

### The "(probable)" Neural Engine and SoC die names

These are an inference from the firmware evidence, not from Stats or Asahi:

- On `Mac16,11` the same six `Ta` keys are firmware-verified Neural Engine
  channels 1–6.
- On `Mac17,4` exactly those six keys are the mapped channels of the `a0va`
  AON source, whose layout matches the ANE0 MTR hardware.
- `Ts` keys are verified SoC die channels on `Mac16,11`; on `Mac17,4` eight
  `Ts` keys are the parallel `s0va` source.

The publisher → AON link is unproven. If a Neural Engine workload does not
move the Air's `Ta` group, remove these names in
`XRGSMCCommunityNames.modelName`.

## Every Mac that runs macOS 26 or later

`XRGMacModels.all` lists 65 identifiers. Each entry has the marketing name,
board, chip and form factor.

- **Intel (6):** MacBookPro16,1 and 16,4 (16-inch 2019), MacBookPro16,2
  (13-inch 2020, four Thunderbolt 3 ports), iMac20,1 and 20,2 (27-inch 2020),
  MacPro7,1 (2019). macOS 26 is the last release for these.
- **Apple Silicon (59):** every M1, M2, M3, M4, M5 and M6 Mac, plus MacBook
  Neo (A18 Pro), from Asahi's device list.

Two corrections to Asahi's list:

- It gives `Mac16,4` for the 15-inch M5 MacBook Air. Your Air reports
  `Mac17,4`/J815, as recorded in the firmware investigation.
- It gives `Mac15,4` for the M3 Ultra Mac Studio, which duplicates the M3 iMac.
  Apple's [Mac Studio identification page](https://support.apple.com/HT213073)
  gives `Mac15,14`.

What each Mac gets:

| Macs | Names |
| --- | --- |
| Intel | Apple's `libSMC` board description where present, then Stats' Intel names: CPU diode/heatsink/proximity/package, CPU core N, GPU diode/heatsink/proximity, Mainboard, Airport, Display, Thunderbolt, Ambient N, Heatpipe N, Disk N, memory risers |
| M1–M6, A18 Pro | Stats' per-generation CPU core, GPU and memory names; Stats' Airflow left/right and Battery 1/2 |
| Apple Silicon laptops | Asahi's NAND flash, battery hotspot, charge regulator, Wi-Fi/Bluetooth module |
| Mac mini | Asahi's NAND flash, Wi-Fi/Bluetooth module |
| iMac, Studio, Mac Pro | Asahi's NAND flash; Stats' Wi-Fi/Bluetooth ("Airport") |
| `Mac16,11`, `Mac17,4` | Additionally the firmware-verified and model-specific names above |

Limits:

- Stats' numbers are positions in its list, not verified physical cores; some
  lists are longer than the chip's core count.
- Stats numbers Intel wildcard keys in the order it finds them; XRG numbers
  them by digit (`TC0c` → core 1), which matches when the keys are contiguous.
- Model-specific names and suspected-unused evidence exist only for the two
  models the firmware investigation covered.

## Temperature settings: three groups

The three sensor pickers in Settings → Temperature list sensors in up to three
sections. Headers appear only when more than one section has sensors.

- **Identified Sensors:** the name says what is measured, including
  channel-only firmware names and "(probable)" inferences.
- **Unidentified Sensors:** only a family or generic name is known.
- **Suspected Unused Sensors:**
  - inputs the firmware investigation found no producer for (`Tz11`–`Tz18`,
    `Tz1j`, and `TPDF`/`TRDF`/`TTDF` on `Mac16,11` or `TPDD`/`TPDE`/`TPDF` on
    `Mac17,4`);
  - any unidentified sensor whose reading has not changed at all for 60
    consecutive updates (at least five minutes).

  Identified sensors are never moved here, so a slow-moving battery
  thermistor stays identified. These channels usually read 0 °C; readings
  outside 15–150 °C are not recorded at all, so they appear in the pickers
  only if they start reporting.

## Checking the names on your Macs

Open the Sensors window with Show Unknown Sensors on, then:

1. **CPU cores:** `yes > /dev/null &` once per core you want loaded, then
   `killall yes`. The super/performance core sensors should rise first.
2. **GPU:** run a Metal-heavy workload; the `GPU N` sensors should lead.
3. **NAND:** `dd if=/dev/zero of=~/xrg-nand-test bs=1m count=20000; rm ~/xrg-nand-test`.
   The NAND flash sensors should climb.
4. **Wi-Fi/Bluetooth:** a long, fast Wi-Fi download should raise `TW0P`.
5. **Charge regulator (Air):** plug in at a low charge; `TCHP` should rise.
6. **Neural Engine (probable):** run an on-device Core ML or Apple
   Intelligence workload; the Air's six `Ta` sensors should move together.
