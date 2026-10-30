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
/// Raw keys remain the persisted identity. Labels intentionally make no claim
/// about a channel's physical location or calibration without driver metadata.
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
        if knownTemperatureKeys.contains(key) { return "SMC temperature · \(key)" }
        if key.hasPrefix("F"), key.hasSuffix("Ac"), let index = key.dropFirst().first.flatMap({ Int(String($0), radix:16) }) { return "Fan \(index + 1) · \(key)" }
        return key
    }
    @objc public func isKnownKey(_ key: String) -> Bool { knownTemperatureKeys.contains(key) || inventory[key] != nil && key.hasPrefix("F") && key.hasSuffix("Ac") }
}
