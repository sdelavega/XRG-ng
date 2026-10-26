/*
 * XRG-ng: A system resource grapher for macOS and Linux.
 * Copyright (C) 2002-2024 Mike Piatek-Jimenez / Gaucho Software, LLC.
 * Copyright (C) 2025-2026 Marc Shade.
 * Copyright (C) 2026 Stephen de la Vega.
 * You can view the complete license in the LICENSE file in the root
 * of the source tree.
 *
 * This program is free software; you can redistribute it and/or
 * modify it under the terms of the GNU General Public License
 * as published by the Free Software Foundation; either version 3
 * of the License, or (at your option) any later version.
 *
 * This program is distributed in the hope that it will be useful,
 * but WITHOUT ANY WARRANTY; without even the implied warranty of
 * MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
 * GNU General Public License for more details.
 *
 * You should have received a copy of the GNU General Public License
 * along with this program. If not, see <https://www.gnu.org/licenses/>.
 *
 */

import Foundation
import Testing
@testable import XRGCore

private final class SMCTransportFixture: NSObject, XRGSMCTransport {
    var codes: [NSNumber?] = []
    var countOverride: Int?
    var keyCount: Int { countRequests += 1; return countOverride ?? codes.count }
    var descriptionsResourcePath: String? { nil }
    var values: [UInt32: Any] = [:]
    var reads: [UInt32] = []
    var indices: [Int] = []
    var countRequests = 0
    func key(at index: Int) -> NSNumber? { indices.append(index); return codes.indices.contains(index) ? codes[index] : nil }
    func readValue(for key: UInt32) -> Any? { reads.append(key); return values[key] }
    init(keys: [String], values: [String: Any] = [:]) {
        super.init()
        codes = keys.map { NSNumber(value: SMCSensors.keyCode($0)!) }
        self.values = Dictionary(uniqueKeysWithValues: values.map { (SMCSensors.keyCode($0.key)!, $0.value) })
    }
}

struct SMCSensorsTests {
    @Test func buildsAndCachesDirectWildcardUnknownAndNonTemperatureNames() {
        let source = SMCTransportFixture(keys: ["TC0P", "TC1P", "TZ9Z", "F0Ac", "F0Mx", "F1Ac", "FNum", "ALV0"],
            values: ["TC0P": 50, "TC1P": 55, "TZ9Z": Data([1, 2]), "ALV0": "light"])
        let sensors = SMCSensors(transport: source, descriptions: ["TC?P": "CPU", "TC0P": "Direct CPU", "ALV0": "Ambient"])
        #expect(sensors.knownTemperatureKeys == ["TC0P", "TC1P"] && sensors.unknownTemperatureKeys == ["TZ9Z"])
        #expect(sensors.humanReadableName(forKey: "TC0P") == "Direct CPU")
        #expect(sensors.humanReadableName(forKey: "TC1P") == "CPU 2")
        #expect(sensors.isKnownKey("ALV0") && !sensors.isKnownKey("TZ9Z"))
        #expect(sensors.humanReadableName(forKey: "TZ9Z") == "TZ9Z")
        #expect(sensors.temperatureValues(includingUnknown: false) as? [String: Int] == ["TC0P": 50, "TC1P": 55])
        source.reads = []
        let raw = sensors.temperatureValues(includingUnknown: true)
        #expect(raw["TZ9Z"] as? Data == Data([1, 2]))
        #expect(Set(source.reads.prefix(2)) == [SMCSensors.keyCode("TC0P")!, SMCSensors.keyCode("TC1P")!])
        #expect(source.reads.last == SMCSensors.keyCode("TZ9Z"))
        #expect(source.countRequests == 1)
    }
    @Test(arguments: [true, false])
    func retainsOldIntelMarkerDescriptionsAndRawKeysWhenRequired(hasModernSensor: Bool) {
        let source = SMCTransportFixture(keys: ["TCAC", "TCBC"] + (hasModernSensor ? ["TC9C"] : []))
        let sensors = SMCSensors(transport: source, descriptions: ["TCAC": "TCAC", "TCBC": "TCBC"])
        #expect(sensors.humanReadableName(forKey: "TCAC") == (hasModernSensor ? "TCAC" : "CPU A ° Below MaxT"))
        #expect(sensors.humanReadableName(forKey: "TCBC") == (hasModernSensor ? "TCBC" : "CPU B ° Below MaxT"))
    }
    @Test func overlappingWildcardsHaveDeterministicPrecedenceAndDirectNamesAlwaysWin() {
        let source = SMCTransportFixture(keys: ["TC0P"])
        let sensors = SMCSensors(transport: source, descriptions: ["TC?P": "Second", "T?0P": "First"])
        #expect(sensors.humanReadableName(forKey: "TC0P") == "First")
        sensors.descriptionsForSMCKeys["TC0P"] = "Direct"
        #expect(sensors.humanReadableName(forKey: "TC0P") == "First")
        sensors.buildKeyCache(); #expect(sensors.humanReadableName(forKey: "TC0P") == "Direct")
    }
    @Test(arguments: [0, 1, 2, 513, -1])
    func fanGroupingRetainsAllFieldsAndForcedBits(mask: Int) {
        let source = SMCTransportFixture(keys: ["F0Ac", "F0Mx", "F1Ac", "F9Ac", "FNum"],
            values: ["F0Ac": 1200, "F0Mx": 6000, "F1Ac": 1300, "F9Ac": 900, "FNum": 3, "FS! ": mask])
        let sensors = SMCSensors(transport: source, descriptions: [:])
        let fans = sensors.fanValues as! [String: [String: Any]]
        #expect(fans.count == 3 && fans["Fan #0"]?["F0Ac"] as? Int == 1200 && fans["Fan #0"]?["F0Mx"] as? Int == 6000)
        for index in [0, 1, 9] { #expect(fans["Fan #\(index)"]?["Forced"] as? Bool == (UInt32(truncatingIfNeeded: mask) & (1 << index) != 0)) }
        #expect(source.reads.first == SMCSensors.keyCode("FS! "))
    }
    @Test func fanFlagsAcceptTheLegacyNumericStringAndMissingReadingsDoNotHideTheFan() {
        let source = SMCTransportFixture(keys: ["F1Ac"], values: ["FS! ": "2"])
        let sensors = SMCSensors(transport: source, descriptions: [:])
        #expect((sensors.fanValues["Fan #1"] as? [String: Any])?["Forced"] as? Bool == true)
        source.values = [:]
        #expect((sensors.fanValues["Fan #1"] as? [String: Any])?["Forced"] as? Bool == false)
    }
    private static let checkedValues: [(NSNumber, Bool)] = [(15, false), (15.0000001, false), (16, true), (199, true),
        (199.9999999, false), (200, false), (0, false), (-1, false), (NSNumber(value: Double.nan), false), (NSNumber(value: Double.infinity), false)]
    @Test(arguments: Self.checkedValues)
    func allValuesRetainsTheOriginalFloatPrecisionAndStrictBounds(sample: (NSNumber, Bool)) {
        let source = SMCTransportFixture(keys: ["TEST", "DATA"], values: ["TEST": sample.0, "DATA": Data([1, 2])])
        let sensors = SMCSensors(transport: source, descriptions: [:])
        #expect(sensors.allValues["TEST"] as? NSNumber == (sample.1 ? sample.0 : nil))
        #expect(sensors.allValues["DATA"] == nil)
    }
    @Test func allValuesEnumeratesFreshKeysWhileMotionValuesKeepTheirOriginalReadOrder() {
        let source = SMCTransportFixture(keys: ["TC0P"], values: ["TC0P": 50, "ALV0": Data([3]), "MO_X": -5])
        let sensors = SMCSensors(transport: source, descriptions: [:]); source.codes.append(NSNumber(value: SMCSensors.keyCode("NEWK")!)); source.values[SMCSensors.keyCode("NEWK")!] = 60
        #expect(sensors.allValues.count == 2)
        source.reads = []; let motion = sensors.sensorValues
        #expect(motion["ALV0"] as? Data == Data([3]) && motion["MO_X"] as? Int == -5)
        #expect(source.reads == ["ALV0", "ALV1", "MSLD", "MO_X", "MO_Y", "MO_Z", "MOCN"].map { SMCSensors.keyCode($0)! })
    }
    @Test(arguments: [-1, Int.max, 1_000_001])
    func rejectsUnreasonableNativeKeyCountsWithoutEnumerating(count: Int) {
        let source = SMCTransportFixture(keys: []); source.countOverride = count
        let sensors = SMCSensors(transport: source, descriptions: [:])
        #expect(sensors.knownTemperatureKeys.isEmpty && sensors.allValues.isEmpty && source.indices.isEmpty)
    }
    @Test func skipsFailedIndicesAndMalformedKeyNumbersAndKeepsTheRemainingKeys() {
        let source = SMCTransportFixture(keys: ["TC0P"], values: ["TC0P": 50])
        source.codes = [nil, -1, NSNumber(value: true), NSNumber(value: UInt64.max), 1.5, 0, source.codes[0]]
        let sensors = SMCSensors(transport: source, descriptions: ["TC0P": "CPU"])
        #expect(sensors.knownTemperatureKeys == ["TC0P"] && sensors.temperatureValues(includingUnknown: false)["TC0P"] as? Int == 50)
    }
    @Test func fourCharacterCodesPreserveSpacesAndRejectInvalidLengthsOrWideCharacters() {
        #expect(SMCSensors.keyCode("FS! ") == 0x46532120 && SMCSensors.keyString(0x46532120) == "FS! ")
        #expect(SMCSensors.keyString(0x54433050) == "TC0P")
        for key in ["", "TC0", "TC0PX", "温度AA", "😀AB"] { #expect(SMCSensors.keyCode(key) == nil) }
        #expect(SMCSensors(transport: nil, descriptions: [:]).temperatureValues(includingUnknown: true).isEmpty)
    }
    @Test func malformedOrAbsentDescriptionResourcesFailCleanly() throws {
        #expect(SMCSensors.loadDescriptions(at: nil).isEmpty)
        #expect(SMCSensors.loadDescriptions(at: "/nonexistent/xrg-sensor-fixture.plist").isEmpty)
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("XRG-smc-\(UUID().uuidString).plist")
        defer { try? FileManager.default.removeItem(at: url) }
        let data = try PropertyListSerialization.data(fromPropertyList: ["TC0P": "CPU", "bad": 42], format: .xml, options: 0)
        try data.write(to: url); #expect(SMCSensors.loadDescriptions(at: url.path) == ["TC0P": "CPU"])
    }
}
