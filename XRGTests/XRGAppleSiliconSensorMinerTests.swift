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
    var calls: [String] = []
    func services() -> [Any]? { calls.append("services"); return list }
    func product(for service: Any) -> Any? { let index = service as! Int; calls.append("product\(index)"); return products[index] }
    func temperature(for service: Any) -> NSNumber? { let index = service as! Int; calls.append("temperature\(index)"); return values[index] }
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
        #expect(XRGAppleSiliconSensorMiner.sample(using: source) == ["CPU": 46, "GPU": 50])
        #expect(source.calls == ["services", "product0", "temperature0", "product1", "temperature1", "product2", "temperature2", "product3", "temperature3", "product4", "temperature4"])
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
