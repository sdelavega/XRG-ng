# Community sensor names (Stats and Asahi Linux)

Added 2026-11-05. This fills plain-language gaps left by the firmware
investigation ([status ledger](macos-sensor-identity-status.md)) using two
published community references. Code: `XRGCore/XRGSMCCommunityNames.swift`.
Licences and copyright notices: `THIRD_PARTY_NOTICES.md`.

| Source | What was used | Licence |
| --- | --- | --- |
| [Stats](https://github.com/exelban/stats) by Serhiy Mytrovtsiy, [`Modules/Sensors/values.swift`](https://github.com/exelban/stats/blob/27fa75a53d57072ec06adc730dcfe67633d639d2/Modules/Sensors/values.swift) at `27fa75a5` | Apple Silicon SMC key names for M1–M6 and A18 Pro, chip-family gating, HID product patterns | MIT |
| [Asahi Linux](https://asahilinux.org/) device trees [`hwmon-common.dtsi`, `hwmon-laptop.dtsi`, `hwmon-mini.dtsi`](https://github.com/torvalds/linux/tree/05441d697f7f9a927264f4058cbbc6a03dfcac9d/arch/arm64/boot/dts/apple) (mainline `05441d69`; identical labels in Asahi fork `6ba0637d`) | Board-sensor labels used by the `macsmc-hwmon` driver | GPL-2.0+ OR MIT |

## How names combine

A sensor label now reads `community name · verified role · KEY`. Either part
is omitted when unknown, and the raw key always stays last and remains the
saved identity, so existing selections and histories are unaffected.

Precedence for a temperature key:

1. Firmware-verified role from the earlier investigation (unchanged).
2. Apple's own `libSMC` description for the exact board branch.
3. Community name: derived model-specific name, then Asahi, then Stats by chip
   family, then Stats' all-Apple-Silicon entries.
4. The existing family fallback (`CPU temperature`, `Temperature sensor`, …).

Community names apply only when the chip is known. The app reads it from
`machdep.cpu.brand_string`, parsed the same way Stats does (`Apple M4 Pro`).
Intel Macs and Rosetta's virtual brand get no community names. Tests inject a
chip explicitly, so they behave the same on every host.

## Your Mac mini: M4 Pro, `Mac16,11` (J773s)

| Key | Previous label | New label | Basis |
| --- | --- | --- | --- |
| `Te05` `Te0S` `Te09` `Te0H` | CPU efficiency temperature | CPU efficiency core 1–4 | Stats M4 table |
| `Tp01` `Tp05` `Tp09` `Tp0D` `Tp0V` `Tp0Y` `Tp0b` `Tp0e` | CPU temperature | CPU performance core 1–8 | Stats M4 table |
| `Tg1U` `Tg1k` | GPU temperature | GPU 1–2 | Stats M4 Pro/Max keys |
| `Tg0K` `Tg0L` `Tg0d` `Tg0e` `Tg0j` `Tg0k` | GPU temperature | GPU 3–8 | Stats M4 table |
| `Tm0p` | Power management device 5 | Memory proximity 1 · Power management device 5 | Stats + verified |
| `Tm1p` | Power management stream 3 device channel 2 | Memory proximity 2 · *(same role)* | Stats + verified |
| `Tm2p` | Temperature sensor | Memory proximity 3 | Stats |
| `TW0P` | Power management stream 2 device channel 2 | Wi-Fi/Bluetooth module temperature · *(same role)* | Asahi (`hwmon-mini`) + verified |
| `TH0x` | Temperature maximum (calibrated channels) | NAND flash temperature · *(same role)* | Asahi (`hwmon-common`), Stats agrees |
| `TH0a` `TH0b` | Calibrated temperature channel 1/2 | NAND flash temperature 1/2 · *(same role)* | Derived: `TH0x` is NAND (Asahi) and is the larger of `TH0a`/`TH0b` (verified) |

The M4 Pro has ten performance cores, but Stats lists eight performance keys
for the whole M4 family. The two remaining performance cores, if they have
their own keys, keep the generic `CPU temperature` label.

## Your MacBook Air: M5, `Mac17,4` (J815)

| Key | Previous label | New label | Basis |
| --- | --- | --- | --- |
| `Tp00` `Tp04` `Tp08` `Tp0C` | CPU temperature | CPU super core 1–4 | Stats M5 table, limited to base M5 |
| `Tg0U` `Tg0X` `Tg0d` `Tg0g` `Tg0j` `Tg1Y` `Tg1c` `Tg1g` | GPU temperature | GPU 1–8 | Stats M5 table |
| `TW0P` | Power management device 4 | Wi-Fi/Bluetooth module temperature · *(same role)* | Asahi (`hwmon-laptop`) + verified |
| `TCHP` | Power management device 7 | Charge regulator temperature · *(same role)* | Asahi (`hwmon-laptop`) + verified |
| `TH0x` | Power management 2 device 2 | NAND flash temperature · *(same role)* | Asahi, Stats agrees |
| `TH0T` | Power management 2 device 2 | NAND flash temperature · *(same role)* | Derived: `TH0x` is NAND (Asahi) and copies `TH0T` (verified) |
| `TB0T` | Battery temperature (family) | Battery hotspot | Asahi (`hwmon-laptop`) |
| `TB1T` `TB2T` | Battery temperature (family) | Battery 1/2 | Stats |
| `Ta00` `Ta04` `Ta08` `Ta0K` `Ta0O` `Ta0R` | Temperature sensor | Neural Engine temperature 1–6 (probable) | Inference, below |
| `Ts00` `Ts04` `Ts08` `Ts0C` `Ts0G` `Ts0K` `Ts0O` `Ts0R` | Temperature sensor | SoC die temperature 1–8 (probable) | Inference, below |

Stats' M5 table follows the M5 Pro/Max layout: six super cores (`Tp00`…`Tp0K`)
and twelve performance cores (`Tp0O`…`Tp0y`). Apple's base M5 has four super
cores and six efficiency cores, with no performance-core tier
([Apple, 2026-03-03](https://www.businesswire.com/news/home/20260303427628/en/Apple-debuts-M5-Pro-and-M5-Max-to-supercharge-the-most-demanding-pro-workflows)).
XRG therefore uses only super cores 1–4 on a base M5 and applies the rest on
M5 Pro/Max/Ultra. Stats has no M5 efficiency-core keys, so the Air's `Te`
sensors keep the `CPU efficiency temperature` family label.

### The "(probable)" Neural Engine and SoC die labels

These are not from Stats or Asahi; they are a cross-model inference from the
earlier firmware evidence and are marked "(probable)" in the label.

- On `Mac16,11` the same six keys `Ta00`, `Ta04`, `Ta08`, `Ta0K`, `Ta0O`,
  `Ta0R` are firmware-verified Neural Engine channels 1–6 (`ANE-TO-SMC`).
- On `Mac17,4` exactly those six keys are the mapped channels of the `a0va`
  AON source, whose noncontiguous layout matches the ANE0 MTR hardware. The
  PMP `soc-device` table pairs a device with `ANE0`, and the PMP temperature
  table carries `Ta000i`-style names.
- `Ts` keys are firmware-verified SoC die (MTR) channels on `Mac16,11`; on
  `Mac17,4` eight `Ts` keys are the mapped channels of the parallel `s0va`
  source.

What is still unproven is the named publisher → AON destination edge, so a
different block with the same layout cannot be excluded. A load test can
corroborate it (below). If a Neural Engine workload does not move the `Ta`
group, remove those labels.

## Still unidentified

No published reference covers these, and the firmware evidence shows no
configured producer writes them. They keep generic labels.

- M4 Pro: `TPDF`, `TRDF`, `TTDF`, `Tz11`–`Tz18`, `Tz1j`.
- M5: `TPDD`, `TPDE`, `TPDF`, `Tz11`–`Tz18`, `Tz1j`.
- Any further `Tp`/`Te`/`Tg` keys outside Stats' tables, such as the M4 Pro's
  extra performance-core sensors and the M5's efficiency-core sensors.

## Other Macs

The Stats tables also give plain names on every other Apple Silicon family:
M1, M2, M3, M4, M5 Pro/Max, M6 and A18 Pro. Asahi's four board labels
(`TH0x`, `TB0T`, `TCHP`, `TW0P`) apply to every Apple Silicon Mac that
publishes those keys. HID sensors with MTR product names now use Stats' names
too: `pACC MTR Temp Sensor0` → `CPU performance core 1`, and likewise for
`eACC`, `GPU`, `SOC`, `ANE`, `ISP` and `PMGR SOC Die`.

Limits:

- Stats' numbers are positions in its own list, not verified physical cores.
  Some lists are longer than the chip's core count (eight performance entries
  on the four-performance-core M1).
- Stats applies one table to a whole generation; XRG keeps that, apart from the
  base M5 limit above.
- Stats' Intel and all-platform entries (`Tm0P` mainboard, `TC0P` CPU
  proximity, …) were not imported. Their meaning varies by board, and Intel
  Macs already get Apple's per-branch `libSMC` descriptions.

## Checking the new names on your Macs

Each check takes a few minutes. Open the Sensors window with Show Unknown
Sensors on, then:

1. **CPU core labels:** run `yes > /dev/null &` once per core you want to
   load, then `killall yes`. The `CPU performance/super core` sensors should
   rise first; efficiency-core sensors should stay cooler.
2. **GPU labels:** run any Metal-heavy workload (a game or a GPU benchmark).
   The `GPU N` sensors should lead.
3. **NAND labels:** `dd if=/dev/zero of=~/xrg-nand-test bs=1m count=20000; rm ~/xrg-nand-test`.
   `TH0x` (and `TH0a`/`TH0b` or `TH0T`) should climb.
4. **Wi-Fi/Bluetooth:** run a long, fast download over Wi-Fi. `TW0P` should
   rise more than its neighbours.
5. **Charge regulator (Air):** plug in at a low charge. `TCHP` should rise.
6. **Neural Engine (probable):** run an on-device Core ML or Apple
   Intelligence workload such as Image Playground or Live Captions. On the
   Air, the six `Ta` sensors should move together. If they don't, remove the
   derived `Ta` names in `XRGSMCCommunityNames.derivedName`.
