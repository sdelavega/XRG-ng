// Swift translation of Data Miners/APSL/SMCSensors.m.
// Modified 2026-10-26 by Stephen de la Vega. This derivative retains APSL 2.0.
/*
 * Copyright (c) 2012 CodeExchange All rights reserved.
 *
 * @APPLE_LICENSE_HEADER_START@
 *
 * This file contains Original Code and/or Modifications of Original Code
 * as defined in and that are subject to the Apple Public Source License
 * Version 2.0 (the 'License'). You may not use this file except in
 * compliance with the License. Please obtain a copy of the License at
 * http://www.opensource.apple.com/apsl/ and read it before using this
 * file.
 *
 * The Original Code and all software distributed under the License are
 * distributed on an 'AS IS' basis, WITHOUT WARRANTY OF ANY KIND, EITHER
 * EXPRESS OR IMPLIED, AND APPLE HEREBY DISCLAIMS ALL SUCH WARRANTIES,
 * INCLUDING WITHOUT LIMITATION, ANY WARRANTIES OF MERCHANTABILITY,
 * FITNESS FOR A PARTICULAR PURPOSE, QUIET ENJOYMENT OR NON-INFRINGEMENT.
 * Please see the License for the specific language governing rights and
 * limitations under the License.
 *
 * @APPLE_LICENSE_HEADER_END@
 */


import Foundation

/// Native implementations must contain exceptions before returning to Swift.
@objc public protocol XRGSMCTransport: NSObjectProtocol {
    var keyCount: Int { get }
    var descriptionsResourcePath: String? { get }
    @objc(keyAtIndex:) func key(at index: Int) -> NSNumber?
    @objc(readValueForKey:) func readValue(for key: UInt32) -> Any?
}
@objc public protocol XRGSMCTransportFactory: NSObjectProtocol {
    static func makeSMCTransport() -> (any XRGSMCTransport)?
}
@objc public protocol XRGSMCSensorValuesProvider: NSObjectProtocol {
    var knownTemperatureKeys: Set<String> { get }
    var fanValues: [String: Any] { get }
    @objc(temperatureValuesIncludingUnknown:) func temperatureValues(includingUnknown: Bool) -> [String: Any]
    @objc(humanReadableNameForKey:) func humanReadableName(forKey key: String) -> String
    func isKnownKey(_ key: String) -> Bool
}

@objc(SMCSensors) @objcMembers
public final class SMCSensors: NSObject, XRGSMCSensorValuesProvider {
    public var descriptionsForSMCKeys: [String: String]
    public private(set) var knownTemperatureKeys: Set<String> = []
    public private(set) var unknownTemperatureKeys: Set<String> = []
    private var keyDescriptions: [String: String] = [:]
    private var fanDescriptions: [String: Set<String>] = [:]
    private let transport: (any XRGSMCTransport)?

    public override convenience init() {
        let factory = NSClassFromString("XRGSMCTransport") as? any XRGSMCTransportFactory.Type
        let transport = factory?.makeSMCTransport()
        self.init(transport: transport, descriptions: Self.loadDescriptions(at: transport?.descriptionsResourcePath))
    }
    @nonobjc init(transport: (any XRGSMCTransport)?, descriptions: [String: String]) {
        self.transport = transport; descriptionsForSMCKeys = descriptions
        super.init(); buildKeyCache()
    }
    @nonobjc static func loadDescriptions(at path: String?) -> [String: String] {
        guard let path, let data = try? Data(contentsOf: URL(fileURLWithPath: path)),
              let plist = try? PropertyListSerialization.propertyList(from: data, options: [], format: nil),
              let values = plist as? [String: Any] else { return [:] }
        return values.compactMapValues { $0 as? String }
    }
    @nonobjc static func keyCode(_ key: String) -> UInt32? {
        let units = Array(key.utf16)
        guard units.count == 4, units.allSatisfy({ $0 <= 255 }) else { return nil }
        return units.reduce(UInt32(0)) { ($0 << 8) | UInt32($1) }
    }
    @nonobjc static func keyString(_ key: UInt32) -> String {
        String(String.UnicodeScalarView([24, 16, 8, 0].map { UnicodeScalar(UInt8(truncatingIfNeeded: key >> $0)) }))
    }
    @nonobjc private func keyCodes() -> [UInt32] {
        guard let transport else { return [] }
        let count = transport.keyCount
        // Reject invalid native counts instead of allocating an unbounded cache.
        guard (0...1_000_000).contains(count) else { return [] }
        return (0..<count).compactMap { index in
            guard let number = transport.key(at: index), CFGetTypeID(number) != CFBooleanGetTypeID() else { return nil }
            guard let code = UInt32(number.stringValue), code != 0 else { return nil }
            return code
        }
    }
    @objc(buildKeyCache) public func buildKeyCache() {
        let keys = Set(keyCodes().map(Self.keyString))
        let groups = descriptionsForSMCKeys.keys.filter { $0.contains("?") }.sorted().compactMap { pattern in
            SMCSensorGroup(pattern: pattern, usingAvailableSensors: keys, description: descriptionsForSMCKeys[pattern]!)
        }
        var names: [String: String] = [:], fans: [String: Set<String>] = [:]
        var known: Set<String> = [], unknown: Set<String> = []
        for key in keys {
            let units = Array(key.utf16)
            var label = descriptionsForSMCKeys[key] ?? groups.lazy.compactMap { $0.sensorKeyDescriptions[key] }.first
            if label == "TCAC" && !keys.contains("TC9C") { label = "CPU A ° Below MaxT" }
            else if label == "TCBC" && !keys.contains("TC9C") { label = "CPU B ° Below MaxT" }
            names[key] = label
            if units[0] == 84 { // T
                if label != nil { known.insert(key) } else { unknown.insert(key) }
            } else if units[0] == 70 && (48...57).contains(units[1]) { // F0...F9
                fans[String(UnicodeScalar(units[1])!), default: []].insert(key)
            }
        }
        keyDescriptions = names; fanDescriptions = fans
        knownTemperatureKeys = known; unknownTemperatureKeys = unknown
    }
    @objc(humanReadableNameForKey:)
    public func humanReadableName(forKey key: String) -> String { keyDescriptions[key] ?? key }
    public func isKnownKey(_ key: String) -> Bool { keyDescriptions[key] != nil }
    @nonobjc private func read<Keys: Sequence>(_ keys: Keys) -> [String: Any] where Keys.Element == String {
        keys.reduce(into: [:]) { values, key in
            if let code = Self.keyCode(key), let value = transport?.readValue(for: code) { values[key] = value }
        }
    }
    @objc(temperatureValuesIncludingUnknown:)
    public func temperatureValues(includingUnknown includeUnknown: Bool) -> [String: Any] {
        var values = read(knownTemperatureKeys)
        if includeUnknown { values.merge(read(unknownTemperatureKeys)) { _, incoming in incoming } }
        return values
    }
    public var fanValues: [String: Any] {
        let raw = transport?.readValue(for: Self.keyCode("FS! ")!)
        let forced: UInt32
        if let value = raw as? NSNumber { forced = value.uint32Value }
        else if let text = raw as? String { forced = UInt32(truncatingIfNeeded: (text as NSString).intValue) }
        else { forced = 0 }
        return fanDescriptions.reduce(into: [:]) { result, entry in
            let index = Int(entry.key)!
            var values = read(entry.value)
            values["Forced"] = NSNumber(value: forced & (UInt32(1) << index) != 0)
            result["Fan #\(index)"] = values
        }
    }
    public var allValues: [String: Any] {
        keyCodes().reduce(into: [:]) { result, code in
            if let number = transport?.readValue(for: code) as? NSNumber,
               number.floatValue > 15 && number.floatValue < 200 { result[Self.keyString(code)] = number }
        }
    }
    public var sensorValues: [String: Any] { read(["ALV0", "ALV1", "MSLD", "MO_X", "MO_Y", "MO_Z", "MOCN"]) }
}
