// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Stephen de la Vega.
import Foundation

@objc public protocol XRGSMCSensorValuesProvider: NSObjectProtocol {
    var knownTemperatureKeys: Set<String> { get }
    var fanValues: [String: Any] { get }
    @objc(temperatureValuesIncludingUnknown:) func temperatureValues(includingUnknown: Bool) -> [String: Any]
    @objc(humanReadableNameForKey:) func humanReadableName(forKey key: String) -> String
    func isKnownKey(_ key: String) -> Bool
}

/// Inventory is made from driver keys, not a copied model/description database.
/// Raw keys remain the persisted identity. Labels describe sensor families;
/// undocumented channels never acquire an invented physical location/core number.
@objc(XRGSMCSensors) public final class XRGSMCSensors: NSObject, XRGSMCSensorValuesProvider {
    private let transport: (any XRGSMCTransport)?
    private var inventory: [String: UInt32] = [:]
    public private(set) var knownTemperatureKeys: Set<String> = []
    @objc public override convenience init() { self.init(transport: XRGSMCReader.openReader()) }
    init(transport: (any XRGSMCTransport)?) {
        self.transport = transport; super.init(); reloadInventory()
    }
    static func code(_ key: String) -> UInt32? {
        let bytes = Array(key.utf8)
        guard bytes.count == 4, bytes.allSatisfy({ (32...126).contains($0) }) else { return nil }
        return bytes.reduce(0) { $0 << 8 | UInt32($1) }
    }
    static func name(_ code: UInt32) -> String? {
        let bytes = [24,16,8,0].map { UInt8(truncatingIfNeeded: code >> $0) }
        guard bytes.allSatisfy({ (32...126).contains($0) }) else { return nil }
        return String(bytes: bytes, encoding: .ascii)
    }
    func reloadInventory() {
        guard let transport else { return }
        let count = transport.keyCount
        guard (0...65_536).contains(count) else { return }
        var found: [String: UInt32] = [:], duplicates = Set<String>()
        for index in 0..<count {
            guard let number = transport.key(at: index), CFGetTypeID(number) != CFBooleanGetTypeID(),
                  let code = UInt32(number.stringValue), let name = Self.name(code) else { continue }
            if found.updateValue(code, forKey: name) != nil { duplicates.insert(name) }
        }
        for key in duplicates { found.removeValue(forKey: key) }
        inventory = found
        // These legacy channels report distance from a limit, not absolute C.
        knownTemperatureKeys = Set(found.keys.filter { $0.hasPrefix("T") && $0 != "TCAC" && $0 != "TCBC" })
    }
    @objc(temperatureValuesIncludingUnknown:) public func temperatureValues(includingUnknown: Bool) -> [String: Any] {
        var values: [String: Any] = [:]
        for key in knownTemperatureKeys.sorted() {
            if let code = inventory[key], let number = transport?.temperatureValue(for: code),
               CFGetTypeID(number) != CFBooleanGetTypeID(), number.doubleValue.isFinite { values[key] = number }
        }
        return values
    }
    @objc public var fanValues: [String: Any] {
        var groups: [String: [String: Any]] = [:]
        for key in inventory.keys.sorted() where key.hasPrefix("F") {
            let chars = Array(key)
            guard chars.count == 4, let index = Int(String(chars[1]), radix:16),
                  ["Ac","Mn","Mx","Tg"].contains(String(chars.suffix(2))),
                  let code = inventory[key], let number = transport?.readValue(for: code) as? NSNumber,
                  CFGetTypeID(number) != CFBooleanGetTypeID(), number.doubleValue.isFinite, number.doubleValue >= 0 else { continue }
            groups["Fan #\(index)", default: [:]][key] = number
        }
        // A target/min/max channel alone must not fabricate a running fan.
        return groups.filter { $0.value.keys.contains(where: { $0.hasSuffix("Ac") }) }
    }
    @objc(humanReadableNameForKey:) public func humanReadableName(forKey key: String) -> String {
        if knownTemperatureKeys.contains(key) { return Self.temperatureName(forKey: key) }
        if key.hasPrefix("F"), key.hasSuffix("Ac"), let index = key.dropFirst().first.flatMap({ Int(String($0), radix:16) }) { return "Fan \(index + 1) · \(key)" }
        return Self.hidName(forKey: key)
    }
    // Family names follow driver product names and the published SMC key
    // reference linked in Tools/macos-sensor-names.md. Case is significant.
    static func temperatureName(forKey key: String) -> String {
        if key == "Tp0P", !XRGNPUReader.isAppleSilicon() { return "Power board · \(key)" }
        let exact = ["TC0D": "CPU diode", "TC0H": "CPU heatsink", "TC0P": "CPU proximity",
                     "TCAD": "CPU package", "TG0D": "GPU diode", "TG0H": "GPU heatsink",
                     "TG0P": "GPU proximity", "Tm0P": "Mainboard", "TW0P": "Wi-Fi",
                     "TL0P": "Display", "TTLD": "Thunderbolt left", "TTRD": "Thunderbolt right"]
        if let label = exact[key] { return "\(label) · \(key)" }
        let families = ["TC": "CPU", "Tp": "CPU", "Te": "CPU efficiency",
                        "TG": "GPU", "Tg": "GPU", "Tm": "Memory", "TM": "Memory",
                        "TB": "Battery", "TH": "Drive", "TA": "Ambient", "TZ": "Thermal zone"]
        if let family = families[String(key.prefix(2))] { return "\(family) temperature · \(key)" }
        return "Temperature sensor · \(key)"
    }
    static func hidName(forKey key: String) -> String {
        func groups(_ pattern: String) -> [String]? {
            guard let expression = try? NSRegularExpression(pattern: pattern),
                  let match = expression.firstMatch(in: key, range: NSRange(key.startIndex..., in: key)) else { return nil }
            return (1..<match.numberOfRanges).map {
                Range(match.range(at: $0), in: key).map { String(key[$0]) } ?? ""
            }
        }
        var label: String?
        if key == "als-temp" { label = "Ambient light sensor temperature" }
        else if key == "gas gauge battery" { label = "Battery temperature" }
        else if let parts = groups("^PMU([0-9]*) (tdie|tdev)([0-9]+)$") {
            let unit = parts[0].isEmpty ? "" : " \(parts[0])"
            label = "Power management\(unit) \(parts[1] == "tdie" ? "die" : "device") \(parts[2])"
        } else if let parts = groups("^PMU([0-9]*) tcal$") {
            label = "Power management\(parts[0].isEmpty ? "" : " " + parts[0]) calibration"
        } else if let parts = groups("^NAND CH([0-9]+) temp$") {
            label = "Storage temperature channel \(parts[0])"
        } else if let parts = groups("^([ep])ACC(.*)$") {
            label = "CPU \(parts[0] == "e" ? "efficiency" : "performance") temperature\(parts[1])"
        }
        return "\(label ?? "Temperature sensor") · \(key)"
    }
    @objc public func isKnownKey(_ key: String) -> Bool { knownTemperatureKeys.contains(key) || inventory[key] != nil && key.hasPrefix("F") && key.hasSuffix("Ac") }
}
