// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Stephen de la Vega.
//
// Plain-language sensor names drawn from community references. Each table
// records its source; the full notices are in THIRD_PARTY_NOTICES.md and the
// per-key evidence is in Tools/macos-sensor-community-names.md.
//
// - Stats, Modules/Sensors/values.swift at 27fa75a5 (2026-11-04).
//   MIT License, Copyright (c) 2019 Serhiy Mytrovtsiy.
//   https://github.com/exelban/stats
// - Asahi Linux device trees, arch/arm64/boot/dts/apple/hwmon-*.dtsi
//   (mainline Linux 05441d69, Asahi fork 6ba0637d). GPL-2.0+ OR MIT,
//   Copyright The Asahi Linux Contributors. https://github.com/AsahiLinux/linux
//
// XRGSMCSensors chooses one best name per key from these tables, the
// firmware-verified roles and Apple's own board descriptions.
import Foundation

enum XRGSMCCommunityNames {
    /// The community name for an SMC temperature key, or nil when no
    /// reference covers this key on this chip and model.
    static func name(forKey key: String, chip: XRGMacChip?, systemModel: String?) -> String? {
        guard let chip else { return nil }
        if let name = modelName(forKey: key, systemModel: systemModel) { return name }
        guard chip.isAppleSilicon else { return statsIntelName(forKey: key) }
        if let name = asahiName(forKey: key, form: systemModel.flatMap(XRGMacModels.model)?.form) { return name }
        if let name = statsGeneration(chip)[key] { return name }
        return statsAppleSilicon[key]
    }

    // MARK: Asahi Linux (GPL-2.0+ OR MIT)

    /// Applied with Asahi's own scoping: hwmon-common.dtsi on every machine,
    /// hwmon-laptop.dtsi on laptops and hwmon-mini.dtsi on the Mac mini.
    static func asahiName(forKey key: String, form: XRGMacModel.Form?) -> String? {
        if key == "TH0x" { return "NAND flash temperature" }
        if form == .laptop {
            if key == "TB0T" { return "Battery hotspot" }
            if key == "TCHP" { return "Charge regulator temperature" }
        }
        if key == "TW0P", form == .laptop || form == .mini { return "Wi-Fi/Bluetooth module temperature" }
        return nil
    }

    // MARK: Model-specific best names

    /// Names for one validated model that combine a community identity with a
    /// firmware-verified copy, maximum or channel layout.
    ///
    /// TH0x is NAND flash (Asahi, Stats). The firmware investigation proves
    /// that on Mac17,4 TH0x copies TH0T, and on Mac16,11 TH0x is the larger of
    /// TH0a and TH0b, so those inputs are the same NAND sensor(s).
    ///
    /// Mac17,4 Ta/Ts: six Ta and eight Ts keys are actively sampled from the
    /// a0va/s0va AON sources, but their publisher was not traced. The same six
    /// Ta keys are firmware-verified Neural Engine channels on Mac16,11, and the
    /// a0va layout matches the ANE0 MTR hardware; Ts keys are verified SoC die
    /// (MTR) channels there. "(probable)" marks this cross-model inference.
    static func modelName(forKey key: String, systemModel: String?) -> String? {
        switch systemModel {
        case "Mac17,4":
            if key == "TH0T" || key == "TH0x" { return "NAND flash temperature" }
            if let index = ["Ta00", "Ta04", "Ta08", "Ta0K", "Ta0O", "Ta0R"].firstIndex(of: key) {
                return "Neural Engine temperature \(index + 1) (probable)"
            }
            if let index = ["Ts00", "Ts04", "Ts08", "Ts0C", "Ts0G", "Ts0K", "Ts0O", "Ts0R"].firstIndex(of: key) {
                return "SoC die temperature \(index + 1) (probable)"
            }
        case "Mac16,11":
            if key == "TH0a" { return "NAND flash temperature 1" }
            if key == "TH0b" { return "NAND flash temperature 2" }
            if key == "TH0x" { return "NAND flash temperature (hottest)" }
        default: break
        }
        return nil
    }

    /// Registered inputs that the firmware investigation found no configured
    /// producer for (Tools/macos-sensor-identity-status.md). They read zero
    /// on the validated machines; nothing proves the hardware is absent.
    static func suspectedUnusedKeys(systemModel: String?) -> Set<String> {
        let tz: Set<String> = ["Tz11", "Tz12", "Tz13", "Tz14", "Tz15", "Tz16", "Tz17", "Tz18", "Tz1j"]
        switch systemModel {
        case "Mac16,11": return tz.union(["TPDF", "TRDF", "TTDF"])
        case "Mac17,4": return tz.union(["TPDD", "TPDE", "TPDF"])
        default: return []
        }
    }

    // MARK: Stats (MIT)

    /// Stats' Apple Silicon entries that apply to every generation. Its TH0x
    /// ("NAND") and TW0P ("Airport") entries agree with Asahi's names above.
    static let statsAppleSilicon: [String: String] = [
        "TaLP": "Airflow left",
        "TaRF": "Airflow right",
        "TH0x": "NAND flash temperature",
        "TB1T": "Battery 1",
        "TB2T": "Battery 2",
        "TW0P": "Wi-Fi/Bluetooth module temperature",
    ]

    private static func numbered(_ prefix: String, _ keys: [String]) -> [String: String] {
        Dictionary(uniqueKeysWithValues: keys.enumerated().map { ($1, "\(prefix) \($0 + 1)") })
    }

    /// Stats numbers sensors in its own list order. The numbers identify a
    /// sensor within a cluster; Stats lists more sensors than some chips have
    /// cores (eight performance entries on the four-core M1), so they are not
    /// a verified one-to-one core assignment.
    static func statsGeneration(_ chip: XRGMacChip) -> [String: String] {
        if chip.family == .a18Pro {
            return numbered("CPU efficiency core", ["Te05", "Te0S"])
                .merging(numbered("CPU performance core", ["Tp05", "Tp0D"])) { $1 }
                .merging(numbered("GPU", ["Tg05", "Tg0D", "Tg0L", "Tg0e"])) { $1 }
        }
        switch chip.generation ?? 0 {
        case 1:
            return numbered("CPU efficiency core", ["Tp09", "Tp0T"])
                .merging(numbered("CPU performance core",
                                  ["Tp01", "Tp05", "Tp0D", "Tp0H", "Tp0L", "Tp0P", "Tp0X", "Tp0b"])) { $1 }
                .merging(numbered("GPU", ["Tg05", "Tg0D", "Tg0L", "Tg0T"])) { $1 }
                .merging(numbered("Memory", ["Tm02", "Tm06", "Tm08", "Tm09"])) { $1 }
        case 2:
            return numbered("CPU efficiency core", ["Tp1h", "Tp1t", "Tp1p", "Tp1l"])
                .merging(numbered("CPU performance core",
                                  ["Tp01", "Tp05", "Tp09", "Tp0D", "Tp0X", "Tp0b", "Tp0f", "Tp0j"])) { $1 }
                .merging(numbered("GPU", ["Tg0f", "Tg0j"])) { $1 }
        case 3:
            return numbered("CPU efficiency core", ["Te05", "Te0L", "Te0P", "Te0S"])
                .merging(numbered("CPU performance core",
                                  ["Tf04", "Tf09", "Tf0A", "Tf0B", "Tf0D", "Tf0E",
                                   "Tf44", "Tf49", "Tf4A", "Tf4B", "Tf4D", "Tf4E"])) { $1 }
                .merging(numbered("GPU", ["Tf14", "Tf18", "Tf19", "Tf1A", "Tf24", "Tf28", "Tf29", "Tf2A"])) { $1 }
        case 4:
            // Stats uses different keys for GPU 1-2 on M4 and on M4 Pro/Max.
            let gpu = chip.tier == .base ? ["Tg0G", "Tg0H"] : ["Tg1U", "Tg1k"]
            return numbered("CPU efficiency core", ["Te05", "Te0S", "Te09", "Te0H"])
                .merging(numbered("CPU performance core",
                                  ["Tp01", "Tp05", "Tp09", "Tp0D", "Tp0V", "Tp0Y", "Tp0b", "Tp0e"])) { $1 }
                .merging(numbered("GPU", gpu + ["Tg0K", "Tg0L", "Tg0d", "Tg0e", "Tg0j", "Tg0k"])) { $1 }
                .merging(numbered("Memory proximity", ["Tm0p", "Tm1p", "Tm2p"])) { $1 }
        case 5:
            // Stats lists the M5 Pro/Max layout (6 super + 12 performance cores).
            // The base M5 has 4 super and 6 efficiency cores and no performance
            // tier, so the extra entries are limited to Pro/Max/Ultra here.
            let superCores = ["Tp00", "Tp04", "Tp08", "Tp0C", "Tp0G", "Tp0K"]
            var names = numbered("CPU super core", chip.tier == .base ? Array(superCores.prefix(4)) : superCores)
                .merging(numbered("GPU", ["Tg0U", "Tg0X", "Tg0d", "Tg0g", "Tg0j", "Tg1Y", "Tg1c", "Tg1g"])) { $1 }
            if chip.tier != .base {
                names.merge(numbered("CPU performance core",
                                     ["Tp0O", "Tp0R", "Tp0U", "Tp0X", "Tp0a", "Tp0d",
                                      "Tp0g", "Tp0j", "Tp0m", "Tp0p", "Tp0u", "Tp0y"])) { $1 }
            }
            return names
        case 6:
            return numbered("CPU super core", ["Tp0j", "Tp0g", "Tp09", "Tp07"])
                .merging(numbered("CPU performance core",
                                  ["Tp0m", "Tp0L", "Tp0I", "Tp0d", "Tp0E", "Tp0G", "Tp0b", "Tp05"])) { $1 }
                .merging(numbered("CPU efficiency core", ["Te07", "Te08", "Te09", "Te0c", "Te0h", "Te0i"])) { $1 }
                .merging(numbered("GPU", ["Tg1e", "Tg0d", "Tg0c", "Tg0b", "Tg1c", "Tg1d",
                                          "Tg07", "Tg1f", "Tg09", "Tg0a", "Tg1g", "Tg1h"])) { $1 }
        default:
            return [:]
        }
    }

    /// Stats' entries for Intel Macs ("Platform.all" and ".intel"). Apple's
    /// own description for the exact board, read from libSMC at runtime,
    /// outranks these where it exists.
    static let statsIntel: [String: String] = [
        "TC0D": "CPU diode", "TC0E": "CPU diode virtual", "TC0F": "CPU diode filtered",
        "TC0H": "CPU heatsink", "TC0P": "CPU proximity", "TCAD": "CPU package",
        "TCAH": "CPU A heatsink", "TCBH": "CPU B heatsink",
        "TCGC": "GPU Intel Graphics", "TG0D": "GPU diode", "TGDD": "GPU AMD Radeon",
        "TG0H": "GPU heatsink", "TG0P": "GPU proximity",
        "Tm0P": "Mainboard", "Tp0P": "Powerboard", "TB1T": "Battery", "TW0P": "Airport",
        "TL0P": "Display", "TTLD": "Thunderbolt left", "TTRD": "Thunderbolt right",
        "TN0D": "Northbridge diode", "TN0H": "Northbridge heatsink", "TN0P": "Northbridge proximity",
        "TMA1": "Memory riser A slot 1", "TMA2": "Memory riser A slot 2",
        "TMA3": "Memory riser A slot 3", "TMA4": "Memory riser A slot 4",
        "TMB1": "Memory riser B slot 1", "TMB2": "Memory riser B slot 2",
        "TMB3": "Memory riser B slot 3", "TMB4": "Memory riser B slot 4",
    ]

    /// Stats' Intel wildcard entries, "%" being one digit. Stats numbers the
    /// keys it finds in order; XRG numbers by the digit (0 → 1), which is the
    /// same whenever the keys are contiguous.
    private static let statsIntelPatterns: [(prefix: String, suffix: Character, name: String)] = [
        ("TA", "P", "Ambient %"), ("Th", "H", "Heatpipe %"), ("TZ", "C", "Thermal zone %"),
        ("TC", "c", "CPU core %"), ("TC", "C", "CPU core %"), ("TI", "P", "Thunderbolt %"),
        ("TH", "A", "Disk % (A)"), ("TH", "B", "Disk % (B)"), ("TH", "C", "Disk % (C)"),
    ]

    static func statsIntelName(forKey key: String) -> String? {
        if let name = statsIntel[key] { return name }
        let characters = Array(key)
        guard characters.count == 4, let digit = characters[2].wholeNumberValue, characters[2].isASCII else { return nil }
        for pattern in statsIntelPatterns
        where String(characters[0...1]) == pattern.prefix && characters[3] == pattern.suffix {
            return pattern.name.replacingOccurrences(of: "%", with: String(digit + 1))
        }
        return nil
    }

    /// Stats' HID product patterns. The trailing driver index is zero-based;
    /// Stats displays it one-based, as here.
    static func hidName(forProduct product: String) -> String? {
        let patterns: [(String, String)] = [
            ("pACC MTR Temp Sensor", "CPU performance core"),
            ("eACC MTR Temp Sensor", "CPU efficiency core"),
            ("GPU MTR Temp Sensor", "GPU core"),
            ("SOC MTR Temp Sensor", "SoC core"),
            ("ANE MTR Temp Sensor", "Neural Engine"),
            ("ISP MTR Temp Sensor", "Image signal processor"),
            ("PMGR SOC Die Temp Sensor", "Power manager die"),
        ]
        for (prefix, name) in patterns where product.hasPrefix(prefix) {
            let suffix = product.dropFirst(prefix.count)
            guard (1...2).contains(suffix.count), suffix.allSatisfy({ ("0"..."9").contains($0) }),
                  let index = Int(suffix), (0..<64).contains(index) else { return nil }
            return "\(name) \(index + 1)"
        }
        return nil
    }
}
