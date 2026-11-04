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

private final class HIDTransportFixture: NSObject, XRGHIDTemperatureTransport {
    var list: [Any]? = []
    var products: [Int: Any] = [:]
    var values: [Int: NSNumber] = [:]
    var locations: [Int: NSNumber] = [:]
    var calls: [String] = []
    func services() -> [Any]? { calls.append("services"); return list }
    func product(for service: Any) -> Any? { let index = service as! Int; calls.append("product\(index)"); return products[index] }
    func temperature(for service: Any) -> NSNumber? { let index = service as! Int; calls.append("temperature\(index)"); return values[index] }
    func locationID(for service: Any) -> NSNumber? { locations[service as! Int] }
}
struct XRGAppleSiliconSensorMinerTests {
    @Test func missingTransportOrServicesKeepsTheNilVersusEmptyContract() {
        #expect(XRGAppleSiliconSensorMiner.sample(using: nil) == nil)
        let source = HIDTransportFixture(); source.list = nil
        #expect(XRGAppleSiliconSensorMiner.sample(using: source) == nil)
        source.list = []; #expect(XRGAppleSiliconSensorMiner.sample(using: source) == [:])
    }
    @Test func productsAndEventsAreReadInOrderAndMalformedServicesDoNotHideOtherSensors() {
        let source = HIDTransportFixture(); source.list = [0, 1, 2, 3, 4]
        source.products = [0: "CPU", 1: 123, 2: "missing event", 3: "GPU", 4: "CPU"]
        source.values = [0: 45, 1: 99, 3: 50, 4: 46]
        #expect(XRGAppleSiliconSensorMiner.sample(using: source) == ["GPU": 50])
        #expect(source.calls == ["services", "product0", "temperature0", "product1", "temperature1", "product2", "temperature2", "product3", "temperature3", "product4", "temperature4"])
    }
    @Test func duplicateProductsKeepStableDriverIdentitiesAcrossOrderMissingEventsAndRemoval() throws {
        let source = HIDTransportFixture(); source.list = [0, 1, 2]
        source.products = [0: "gas gauge battery", 1: "gas gauge battery", 2: "PMU tdie1"]
        source.locations = [0: 0x54473042, 1: 0x54473142]
        source.values = [0: 31, 1: 34, 2: 40]
        var products = Set<String>()
        let first = XRGAppleSiliconSensorMiner.identity(product: "gas gauge battery", location: 0x54473042)
        let second = XRGAppleSiliconSensorMiner.identity(product: "gas gauge battery", location: 0x54473142)
        let expected: [String: NSNumber] = [first: 31, second: 34, "PMU tdie1": 40]
        #expect(XRGAppleSiliconSensorMiner.sample(using: source, disambiguating: &products) == expected)
        source.list = [2, 1, 0]
        #expect(XRGAppleSiliconSensorMiner.sample(using: source, disambiguating: &products) == expected)
        source.values[1] = nil
        #expect(XRGAppleSiliconSensorMiner.sample(using: source, disambiguating: &products) == [first: 31, "PMU tdie1": 40])
        source.list = [0]
        #expect(XRGAppleSiliconSensorMiner.sample(using: source, disambiguating: &products) == [first: 31])
        source.list = nil
        #expect(XRGAppleSiliconSensorMiner.sample(using: source, disambiguating: &products) == nil)
        source.list = [1]; source.values[1] = 35
        #expect(XRGAppleSiliconSensorMiner.sample(using: source, disambiguating: &products) == [second: 35])
        #expect(XRGSMCSensors.hidName(forKey: first) == "Battery temperature · HID TG0B")
        #expect(XRGSMCSensors.hidName(forKey: second) == "Battery temperature · HID TG1B")
        #expect(XRGSMCSensors.hidName(forKey: "PMU tdie1") == "Power management die 1 · PMU tdie1")
    }

    @Test func ambiguousMissingInvalidAndDuplicateLocationIDsNeverPublishAnArbitraryChannel() {
        let source = HIDTransportFixture(); source.list = [0, 1, 2]
        source.products = [0: "battery", 1: "battery", 2: "independent"]
        source.values = [0: 31, 1: 34, 2: 40]
        for id: NSNumber? in [nil, 0, -1, true, 1.5, NSNumber(value: UInt64.max), NSNumber(value: Double.nan), 7] {
            source.locations = [0: 7]
            source.locations[1] = id
            #expect(XRGAppleSiliconSensorMiner.sample(using: source) == ["independent": 40])
        }
        // A transiently missing event must not turn a duplicate product into a
        // different, apparently unique source.
        source.values[1] = nil
        #expect(XRGAppleSiliconSensorMiner.sample(using: source) == ["independent": 40])
    }

    @Test func encodedIdentityCollisionsAreUnavailableAndNamesKeepNumericIDsWhenNotFourCCs() {
        let source = HIDTransportFixture()
        let collision = XRGAppleSiliconSensorMiner.identity(product: "battery", location: 7)
        source.list = [0, 1, 2]
        source.products = [0: "battery", 1: "battery", 2: collision]
        source.locations = [0: 7, 1: 8]; source.values = [0: 31, 1: 34, 2: 60]
        #expect(XRGAppleSiliconSensorMiner.sample(using: source) == ["HID:00000008:battery": 34])
        #expect(XRGSMCSensors.hidName(forKey: "HID:00000007:gas gauge battery") == "Battery temperature · HID 00000007")
        for key in ["HID:00000000:battery", "HID:0000000a:battery", "HID:123:battery", "HID:GGGGGGGG:battery"] {
            #expect(XRGAppleSiliconSensorMiner.parseIdentity(key) == nil)
        }
    }
    @Test func samplingKeepsRawReadingsForTheExistingTemperatureValidationLayer() throws {
        let source = HIDTransportFixture(); source.list = [0, 1, 2]
        source.products = [0: "", 1: "unavailable", 2: "zero"]
        source.values = [0: 55, 1: NSNumber(value: Double.nan), 2: 0]
        let readings = try #require(XRGAppleSiliconSensorMiner.sample(using: source))
        #expect(readings[""] == 55 && readings["zero"] == 0)
        #expect(readings["unavailable"]?.doubleValue.isNaN == true)
    }
}
