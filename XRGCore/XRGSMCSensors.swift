// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Stephen de la Vega.
import Foundation
import Darwin
import IOKit

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
    private let branchNameSource: (String) -> [String: String]
    private let systemModel: String?
    private let publishedNameSource: () -> [String: String]
    private var inventory: [String: UInt32] = [:]
    private var branchNames: [String: String] = [:]
    private var publishedNames: [String: String] = [:]
    public private(set) var knownTemperatureKeys: Set<String> = []
    @objc public override convenience init() { self.init(transport: XRGSMCReader.openReader()) }
    init(transport: (any XRGSMCTransport)?, branchNameSource: @escaping (String) -> [String: String] = XRGSMCBranchNames.load,
         systemModel: String? = XRGCPUMiner.systemModelIdentifier(),
         publishedNameSource: @escaping () -> [String: String] = XRGSMCPublishedNames.load) {
        self.transport = transport; self.branchNameSource = branchNameSource; self.systemModel = systemModel
        self.publishedNameSource = publishedNameSource
        super.init(); reloadInventory()
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
        branchNames = [:]
        if let code = found["RBr "], let raw = transport.readValue(for: code) as? Data,
           let branch = XRGSMCBranchNames.branch(raw) {
            branchNames = branchNameSource(branch)
        }
        // These legacy channels report distance from a limit, not absolute C.
        knownTemperatureKeys = Set(found.keys.filter { $0.hasPrefix("T") && $0 != "TCAC" && $0 != "TCBC" })
        // Some published ADC source keys are absent from ordinary key enumeration.
        // Keep their metadata for verified firmware aliases, without adding keys.
        publishedNames = publishedNameSource()
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
        if knownTemperatureKeys.contains(key) {
            if let name = publishedNames[key] { return "\(name) · \(key)" }
            if let source = Self.verifiedPublishedAlias(forKey: key, systemModel: systemModel),
               let name = publishedNames[source],
               name.hasPrefix(source.hasPrefix("TP") ? "Power management die " : "Power management 2 die ") {
                return "\(name) · \(key)"
            }
            if let name = Self.verifiedTemperatureName(forKey: key, systemModel: systemModel) { return "\(name) · \(key)" }
            if let name = branchNames[key] { return "\(name) · \(key)" }
            return Self.temperatureName(forKey: key)
        }
        if key.hasPrefix("F"), key.hasSuffix("Ac"), let index = key.dropFirst().first.flatMap({ Int(String($0), radix:16) }) { return "Fan \(index + 1) · \(key)" }
        return Self.hidName(forKey: key)
    }
    static func verifiedPublishedAlias(forKey key: String, systemModel: String?) -> String? {
        guard systemModel == "Mac17,4" else { return nil }
        // These streams and canonical keys select the same HAL and ADC ID.
        // Require the canonical key's live published label at the call site.
        let sources = ["TPD0": "TP1b", "TPD1": "TP2b", "TPD2": "TP3b", "TPD3": "TP4b",
                       "TPD4": "TP5b", "TPD5": "TP6b", "TPD6": "TP7b", "TPD7": "TP8b",
                       "TPD8": "TP9b", "TPD9": "TPab", "TPDA": "TPbl", "TPDB": "TPcl", "TPDC": "TPdl",
                       "TRD0": "TR1b", "TRD1": "TR2b", "TRD2": "TR3b", "TRD3": "TR4b",
                       "TRD4": "TR5b", "TRD5": "TR6b", "TRD6": "TR7b", "TRD7": "TR8l"]
        return sources[key]
    }
    static func verifiedTemperatureName(forKey key: String, systemModel: String?) -> String? {
        if systemModel == "Mac17,4" {
            if key == "TPDX" || key == "TRDX" { return "Temperature maximum (selected channels)" }
            if key == "TCMb" { return "Adjusted temperature maximum" }
            return nil
        }
        // The j773s firmware joins these exact keys to six ANE-TO-SMC
        // streams. Channel numbers describe stream order, not core position.
        // Other boards use different providers for the same Ta keys.
        // See Tools/macos-smc-firmware-investigation.md for the trace.
        guard systemModel == "Mac16,11" else { return nil }
        let channels = [("Ta00", "Ta01"), ("Ta04", "Ta05"), ("Ta08", "Ta09"),
                        ("Ta0K", "Ta0L"), ("Ta0O", "Ta0P"), ("Ta0R", "Ta0S")]
        for (index, pair) in channels.enumerated() {
            if key == pair.0 { return "Neural Engine temperature channel \(index + 1)" }
            if key == pair.1 { return "Neural Engine temperature channel \(index + 1) (adjusted)" }
        }
        // MTR die-temperature streams expose current and two averaged outputs.
        // Their ordinal does not identify a CPU/GPU core or a physical site.
        let dieChannels = [("Ts02", "Ts00", "Ts01"), ("Ts06", "Ts04", "Ts05"),
                           ("Ts0A", "Ts08", "Ts09"), ("Ts0E", "Ts0C", "Ts0D"),
                           ("Ts0I", "Ts0G", "Ts0H"), ("Ts0M", "Ts0K", "Ts0L"),
                           ("Ts0R", "Ts0O", "Ts0Q"), ("Ts0W", "Ts0T", "Ts0U")]
        for (index, keys) in dieChannels.enumerated() {
            if key == keys.0 { return "Die temperature channel \(index + 1)" }
            if key == keys.1 { return "Die temperature channel \(index + 1) (average)" }
            if key == keys.2 { return "Die temperature channel \(index + 1) (adjusted average)" }
        }
        if key == "Tsx1" { return "Die temperature channel 9" }
        if key == "Tsx0" { return "Die temperature channel 9 (average)" }
        return nil
    }
    // Family names follow driver product names and the published SMC key
    // reference linked in Tools/macos-sensor-names.md. Case is significant.
    static func temperatureName(forKey key: String, appleSilicon: Bool = XRGNPUReader.isAppleSilicon()) -> String {
        // Position suffixes and even some families vary by branch: on m87,
        // Tm0P is charger proximity and TG0H is northbridge proximity.
        var families = ["TC": "CPU", "TM": "Memory",
                        "TB": "Battery", "TH": "Drive", "TA": "Ambient", "TZ": "Thermal zone"]
        if appleSilicon {
            families.merge(["Tp": "CPU", "Te": "CPU efficiency", "Tg": "GPU"]) { _, new in new }
        }
        if let family = families[String(key.prefix(2))] { return "\(family) temperature · \(key)" }
        return "Temperature sensor · \(key)"
    }
    @objc(humanReadableHIDNameForKey:) public static func hidName(forKey key: String) -> String {
        if let identity = XRGAppleSiliconSensorMiner.parseIdentity(key) {
            let label = hidName(forKey: identity.product)
            let suffix = " · \(identity.product)"
            let friendly = label.hasSuffix(suffix) ? String(label.dropLast(suffix.count)) : label
            let source = Self.name(identity.location) ?? String(format: "%08X", identity.location)
            return "\(friendly) · HID \(source)"
        }
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

/// These driver services publish the exact SMC read key as LocationID.
/// Only direct AppleSMCKeysEndpoint children and recognized temperature products count.
enum XRGSMCPublishedNames {
    static func load() -> [String: String] {
        var iterator: io_iterator_t = 0
        guard IOServiceGetMatchingServices(kIOMainPortDefault, IOServiceMatching("AppleARMPMUTempSensor"), &iterator) == KERN_SUCCESS else { return [:] }
        defer { IOObjectRelease(iterator) }
        var records: [[String: Any]] = []
        while true {
            let service = IOIteratorNext(iterator)
            guard service != 0 else { break }
            defer { IOObjectRelease(service) }
            var parent: io_registry_entry_t = 0
            guard IORegistryEntryGetParentEntry(service, kIOServicePlane, &parent) == KERN_SUCCESS else { continue }
            defer { IOObjectRelease(parent) }
            var providerID: UInt64 = 0
            guard IOObjectConformsTo(parent, "AppleSMCKeysEndpoint") != 0,
                  IORegistryEntryGetRegistryEntryID(parent, &providerID) == KERN_SUCCESS, providerID != 0,
                  let product = IORegistryEntryCreateCFProperty(service, "Product" as CFString, kCFAllocatorDefault, 0)?.takeRetainedValue(),
                  let location = IORegistryEntryCreateCFProperty(service, "LocationID" as CFString, kCFAllocatorDefault, 0)?.takeRetainedValue() else { continue }
            records.append(["Product": product, "LocationID": location, "ProviderID": NSNumber(value: providerID)])
        }
        return decode(records)
    }

    static func decode(_ records: [[String: Any]]) -> [String: String] {
        var names: [String: String] = [:], providers: [String: UInt64] = [:], ambiguous = Set<String>()
        for record in records {
            guard let product = record["Product"] as? String, product.utf8.count <= 128,
                  !product.unicodeScalars.contains(where: CharacterSet.controlCharacters.contains),
                  let provider = record["ProviderID"] as? NSNumber, CFGetTypeID(provider) != CFBooleanGetTypeID(),
                  let providerID = UInt64(provider.stringValue), providerID != 0,
                  let number = record["LocationID"] as? NSNumber, CFGetTypeID(number) != CFBooleanGetTypeID(),
                  let code = UInt32(number.stringValue), let key = XRGSMCSensors.name(code), key.hasPrefix("T") else { continue }
            let label = XRGSMCSensors.hidName(forKey: product)
            let suffix = " · \(product)"
            guard label.hasPrefix("Power management") || product == "gas gauge battery",
                  label.hasSuffix(suffix) else { continue }
            let name = String(label.dropLast(suffix.count))
            if let previous = names[key] {
                if previous != name || providers[key] != providerID { ambiguous.insert(key) }
            } else {
                names[key] = name; providers[key] = providerID
            }
        }
        for key in ambiguous { names.removeValue(forKey: key) }
        return names
    }
}

/// Optional descriptions from the installed system library, matched to the
/// driver's exact RBr branch. No Apple catalogue is copied into the application.
/// Unknown ABI, branch or unreadable memory disables this optional source.
enum XRGSMCBranchNames {
    static func branch(_ bytes: Data) -> String? {
        guard (1...16).contains(bytes.count) else { return nil }
        let text = bytes.prefix { $0 != 0 }
        guard !text.isEmpty, text.allSatisfy({ (33...126).contains($0) }),
              bytes.dropFirst(text.count).allSatisfy({ $0 == 0 }) else { return nil }
        return String(bytes: text, encoding: .ascii)
    }

    static func load(branch: String) -> [String: String] {
        guard let handle = dlopen("/usr/lib/libSMC.dylib", RTLD_LAZY | RTLD_LOCAL) else { return [:] }
        defer { dlclose(handle) }
        guard let symbol = dlsym(handle, "AccumulatorPlatformStructLookupArray") else { return [:] }
        return decode(branch: branch, address: UInt64(UInt(bitPattern: symbol)), read: readMemory)
    }

    private static func readMemory(_ address: UInt64, _ count: Int) -> Data? {
        guard address > 0, count > 0, count <= 272 * 10_000,
              address <= UInt64.max - UInt64(count) else { return nil }
        var output = Data(count: count), copied: mach_vm_size_t = 0
        let status = output.withUnsafeMutableBytes { bytes in
            mach_vm_read_overwrite(mach_task_self_, address, mach_vm_size_t(count),
                                   mach_vm_address_t(UInt(bitPattern: bytes.baseAddress!)), &copied)
        }
        return status == KERN_SUCCESS && copied == count ? output : nil
    }

    static func decode(branch expected: String, address: UInt64,
                       read: (UInt64, Int) -> Data?) -> [String: String] {
        guard branch(Data(expected.utf8)) == expected,
              address > 0, address <= UInt64.max - 256 * 48 else { return [:] }
        var matching: Data?
        for index in 0..<256 {
            guard let row = read(address + UInt64(index * 48), 48), row.count == 48 else { return [:] }
            // The observed exported array ends at a non-record boundary.
            // Never search beyond it or scan for a replacement symbol.
            guard let name = branch(Data(row.prefix(16))) else {
                return matching.flatMap { descriptions($0, read: read) } ?? [:]
            }
            guard XRGSMCWire.word(row, at: 32) <= 10_000,
                  XRGSMCWire.word(row, at: 36) <= 10_000,
                  XRGSMCWire.word(row, at: 40) <= 1,
                  XRGSMCWire.word(row, at: 44) == 0 else { return [:] }
            if name == expected {
                guard matching == nil else { return [:] }
                matching = row
            }
        }
        return [:]
    }

    private static func descriptions(_ row: Data, read: (UInt64, Int) -> Data?) -> [String: String]? {
        var names: [String: String] = [:]
        for group in 0..<2 {
            let count = Int(XRGSMCWire.word(row, at: 32 + group * 4))
            if count == 0 { continue }
            let pointer = row.withUnsafeBytes {
                UInt64(littleEndian: $0.loadUnaligned(fromByteOffset: 16 + group * 8, as: UInt64.self))
            }
            guard pointer > 0, pointer <= UInt64.max - UInt64(count * 272),
                  let bytes = read(pointer, count * 272), bytes.count == count * 272 else { return nil }
            for index in 0..<count {
                let value = Data(bytes[index * 272..<(index + 1) * 272])
                guard value[262] == 0, value[263] == 0,
                      value[268..<272].allSatisfy({ $0 == 0 }) else { return nil }
                guard let key = String(bytes: value.prefix(4).reversed(), encoding: .ascii),
                      XRGSMCSensors.code(key) != nil, key.hasPrefix("T") else { continue }
                let raw = value[5..<261]
                guard let end = raw.firstIndex(of: 0), end > raw.startIndex,
                      let text = String(bytes: raw[..<end], encoding: .utf8),
                      !text.unicodeScalars.contains(where: CharacterSet.controlCharacters.contains) else { return nil }
                var name = text.trimmingCharacters(in: .whitespaces)
                if name.hasSuffix("(\(key))") { name = String(name.dropLast(6)).trimmingCharacters(in: .whitespaces) }
                guard !name.isEmpty else { return nil }
                if let previous = names[key], previous != name { return nil }
                names[key] = name
            }
        }
        return names
    }
}
