// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Stephen de la Vega.
//
// Every Mac model that can run macOS 26 or later, Intel and Apple Silicon.
// Apple Silicon identifiers, boards and SoCs come from the Asahi Linux device
// list (docs/hw/devices/device-list.md at AsahiLinux/docs, CC BY 3.0, The
// Asahi Linux Contributors), with two corrections recorded in
// Tools/macos-sensor-community-names.md. Intel entries are the four Intel
// products Apple lists as macOS Tahoe 26 compatible.
import Foundation
import Darwin

/// Processor family used to choose sensor-name tables.
struct XRGMacChip: Equatable, Sendable {
    enum Family: Equatable, Sendable { case intel, m(Int), a18Pro }
    enum Tier: Sendable { case base, pro, max, ultra }
    let family: Family
    let tier: Tier

    init(_ family: Family, tier: Tier = .base) { self.family = family; self.tier = tier }

    /// M-series generation, or nil for Intel and A-series chips.
    var generation: Int? { if case .m(let value) = family { return value }; return nil }
    var isAppleSilicon: Bool { family != .intel }

    /// Parses brands such as "Apple M4 Pro" the way Stats does. Intel brands
    /// map to `.intel`. Rosetta's "VirtualApple" brand is not recognised; the
    /// model table supplies the chip there.
    init?(brand: String) {
        let text = brand.lowercased()
        if text.hasPrefix("intel") { self.init(.intel); return }
        guard text.hasPrefix("apple ") else { return nil }
        if text.contains("a18 pro") { self.init(.a18Pro); return }
        let words = text.split(whereSeparator: { !$0.isLetter && !$0.isNumber })
        guard let chip = words.first(where: { $0.first == "m" && $0.count > 1 && $0.dropFirst().allSatisfy(\.isNumber) }),
              let generation = Int(chip.dropFirst()), (1...99).contains(generation) else { return nil }
        let tier: Tier = words.contains("pro") ? .pro : words.contains("max") ? .max
            : words.contains("ultra") ? .ultra : .base
        self.init(.m(generation), tier: tier)
    }

    static func hostBrand() -> String? {
        var size = 0
        guard sysctlbyname("machdep.cpu.brand_string", nil, &size, nil, 0) == 0, (1...256).contains(size) else { return nil }
        var bytes = [UInt8](repeating: 0, count: size)
        guard sysctlbyname("machdep.cpu.brand_string", &bytes, &size, nil, 0) == 0 else { return nil }
        return String(decoding: bytes.prefix(while: { $0 != 0 }), as: UTF8.self)
    }

    /// The exact model table wins; the CPU brand covers models newer than it.
    static func host(model: String? = XRGCPUMiner.systemModelIdentifier()) -> XRGMacChip? {
        if let model, let entry = XRGMacModels.model(model) { return entry.chip }
        return hostBrand().flatMap(XRGMacChip.init(brand:))
    }
}

struct XRGMacModel: Sendable {
    enum Form: Sendable { case laptop, mini, iMac, studio, macPro }
    let identifier: String
    let name: String
    /// Board (product) ID without the "AP" suffix, e.g. J773s.
    let board: String
    let chip: XRGMacChip
    let form: Form
}

enum XRGMacModels {
    static func model(_ identifier: String) -> XRGMacModel? { byIdentifier[identifier] }

    private static let byIdentifier: [String: XRGMacModel] =
        Dictionary(uniqueKeysWithValues: all.map { ($0.identifier, $0) })

    private static func mac(_ identifier: String, _ name: String, _ board: String,
                            _ chip: XRGMacChip, _ form: XRGMacModel.Form) -> XRGMacModel {
        XRGMacModel(identifier: identifier, name: name, board: board, chip: chip, form: form)
    }

    private static let intel = XRGMacChip(.intel)
    private static func m(_ generation: Int, _ tier: XRGMacChip.Tier = .base) -> XRGMacChip {
        XRGMacChip(.m(generation), tier: tier)
    }

    static let all: [XRGMacModel] = [
        // Intel (macOS 26 is the last Intel release)
        mac("MacBookPro16,1", "MacBook Pro (16-inch, 2019)", "J152F", intel, .laptop),
        mac("MacBookPro16,4", "MacBook Pro (16-inch, 2019, Radeon Pro 5600M)", "J152F", intel, .laptop),
        mac("MacBookPro16,2", "MacBook Pro (13-inch, 2020, Four Thunderbolt 3 ports)", "J214K", intel, .laptop),
        mac("iMac20,1", "iMac (Retina 5K, 27-inch, 2020)", "J185", intel, .iMac),
        mac("iMac20,2", "iMac (Retina 5K, 27-inch, 2020)", "J185F", intel, .iMac),
        mac("MacPro7,1", "Mac Pro (2019)", "J160", intel, .macPro),
        // M1
        mac("Macmini9,1", "Mac mini (M1, 2020)", "J274", m(1), .mini),
        mac("MacBookPro17,1", "MacBook Pro (13-inch, M1, 2020)", "J293", m(1), .laptop),
        mac("MacBookAir10,1", "MacBook Air (M1, 2020)", "J313", m(1), .laptop),
        mac("iMac21,1", "iMac (24-inch, 4-port, M1, 2021)", "J456", m(1), .iMac),
        mac("iMac21,2", "iMac (24-inch, 2-port, M1, 2021)", "J457", m(1), .iMac),
        mac("MacBookPro18,1", "MacBook Pro (16-inch, M1 Pro, 2021)", "J316s", m(1, .pro), .laptop),
        mac("MacBookPro18,2", "MacBook Pro (16-inch, M1 Max, 2021)", "J316c", m(1, .max), .laptop),
        mac("MacBookPro18,3", "MacBook Pro (14-inch, M1 Pro, 2021)", "J314s", m(1, .pro), .laptop),
        mac("MacBookPro18,4", "MacBook Pro (14-inch, M1 Max, 2021)", "J314c", m(1, .max), .laptop),
        mac("Mac13,1", "Mac Studio (M1 Max, 2022)", "J375c", m(1, .max), .studio),
        mac("Mac13,2", "Mac Studio (M1 Ultra, 2022)", "J375d", m(1, .ultra), .studio),
        // M2
        mac("Mac14,7", "MacBook Pro (13-inch, M2, 2022)", "J493", m(2), .laptop),
        mac("Mac14,2", "MacBook Air (13-inch, M2, 2022)", "J413", m(2), .laptop),
        mac("Mac14,3", "Mac mini (M2, 2023)", "J473", m(2), .mini),
        mac("Mac14,12", "Mac mini (M2 Pro, 2023)", "J474s", m(2, .pro), .mini),
        mac("Mac14,9", "MacBook Pro (14-inch, M2 Pro, 2023)", "J414s", m(2, .pro), .laptop),
        mac("Mac14,10", "MacBook Pro (16-inch, M2 Pro, 2023)", "J416s", m(2, .pro), .laptop),
        mac("Mac14,5", "MacBook Pro (14-inch, M2 Max, 2023)", "J414c", m(2, .max), .laptop),
        mac("Mac14,6", "MacBook Pro (16-inch, M2 Max, 2023)", "J416c", m(2, .max), .laptop),
        mac("Mac14,15", "MacBook Air (15-inch, M2, 2023)", "J415", m(2), .laptop),
        mac("Mac14,13", "Mac Studio (M2 Max, 2023)", "J475c", m(2, .max), .studio),
        mac("Mac14,14", "Mac Studio (M2 Ultra, 2023)", "J475d", m(2, .ultra), .studio),
        mac("Mac14,8", "Mac Pro (2023)", "J180d", m(2, .ultra), .macPro),
        // M3
        mac("Mac15,4", "iMac (24-inch, 2-port, M3, 2023)", "J433", m(3), .iMac),
        mac("Mac15,5", "iMac (24-inch, 4-port, M3, 2023)", "J434", m(3), .iMac),
        mac("Mac15,3", "MacBook Pro (14-inch, M3, Nov 2023)", "J504", m(3), .laptop),
        mac("Mac15,6", "MacBook Pro (14-inch, M3 Pro, Nov 2023)", "J514s", m(3, .pro), .laptop),
        mac("Mac15,7", "MacBook Pro (16-inch, M3 Pro, Nov 2023)", "J516s", m(3, .pro), .laptop),
        mac("Mac15,8", "MacBook Pro (14-inch, M3 Max, Nov 2023)", "J514c", m(3, .max), .laptop),
        mac("Mac15,9", "MacBook Pro (16-inch, M3 Max, Nov 2023)", "J516c", m(3, .max), .laptop),
        mac("Mac15,10", "MacBook Pro (14-inch, M3 Max, Nov 2023)", "J514m", m(3, .max), .laptop),
        mac("Mac15,11", "MacBook Pro (16-inch, M3 Max, Nov 2023)", "J516m", m(3, .max), .laptop),
        mac("Mac15,12", "MacBook Air (13-inch, M3, 2024)", "J613", m(3), .laptop),
        mac("Mac15,13", "MacBook Air (15-inch, M3, 2024)", "J615", m(3), .laptop),
        mac("Mac15,14", "Mac Studio (M3 Ultra, 2025)", "J575d", m(3, .ultra), .studio),
        // M4
        mac("Mac16,2", "iMac (24-inch, 2-port, M4, 2024)", "J623", m(4), .iMac),
        mac("Mac16,3", "iMac (24-inch, 4-port, M4, 2024)", "J624", m(4), .iMac),
        mac("Mac16,10", "Mac mini (M4, 2024)", "J773g", m(4), .mini),
        mac("Mac16,11", "Mac mini (M4 Pro, 2024)", "J773s", m(4, .pro), .mini),
        mac("Mac16,1", "MacBook Pro (14-inch, M4, Nov 2024)", "J604", m(4), .laptop),
        mac("Mac16,8", "MacBook Pro (14-inch, M4 Pro, Nov 2024)", "J614s", m(4, .pro), .laptop),
        mac("Mac16,7", "MacBook Pro (16-inch, M4 Pro, Nov 2024)", "J616s", m(4, .pro), .laptop),
        mac("Mac16,6", "MacBook Pro (14-inch, M4 Max, Nov 2024)", "J614c", m(4, .max), .laptop),
        mac("Mac16,5", "MacBook Pro (16-inch, M4 Max, Nov 2024)", "J616c", m(4, .max), .laptop),
        mac("Mac16,12", "MacBook Air (13-inch, M4, 2025)", "J713", m(4), .laptop),
        mac("Mac16,13", "MacBook Air (15-inch, M4, 2025)", "J715", m(4), .laptop),
        mac("Mac16,9", "Mac Studio (M4 Max, 2025)", "J575c", m(4, .max), .studio),
        // A18 Pro, M5 and M6
        mac("Mac17,5", "MacBook Neo (A18 Pro, 2026)", "J700", XRGMacChip(.a18Pro), .laptop),
        mac("Mac17,16", "Mac mini (M5 Pro, 2026)", "J873s", m(5, .pro), .mini),
        mac("Mac17,2", "MacBook Pro (14-inch, M5, 2025)", "J704", m(5), .laptop),
        mac("Mac17,9", "MacBook Pro (14-inch, M5 Pro, 2026)", "J714s", m(5, .pro), .laptop),
        mac("Mac17,8", "MacBook Pro (16-inch, M5 Pro, 2026)", "J716s", m(5, .pro), .laptop),
        mac("Mac17,7", "MacBook Pro (14-inch, M5 Max, 2026)", "J714c", m(5, .max), .laptop),
        mac("Mac17,6", "MacBook Pro (16-inch, M5 Max, 2026)", "J716c", m(5, .max), .laptop),
        mac("Mac17,3", "MacBook Air (13-inch, M5, 2026)", "J813", m(5), .laptop),
        mac("Mac17,4", "MacBook Air (15-inch, M5, 2026)", "J815", m(5), .laptop),
        mac("Mac17,14", "Mac Studio (M5 Max, 2026)", "J775c", m(5, .max), .studio),
        mac("Mac17,15", "Mac Studio (M5 Ultra, 2026)", "J775d", m(5, .ultra), .studio),
        mac("Mac18,5", "Mac mini (M6, 2026)", "J873g", m(6), .mini),
    ]
}
