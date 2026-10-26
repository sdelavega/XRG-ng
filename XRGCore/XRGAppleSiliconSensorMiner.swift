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

// Native API provenance retained from the Objective-C adapter:
// https://github.com/yujitach/MenuMeters/
// https://github.com/fermion-star/apple_sensors/blob/master/temp_sensor.m
// https://github.com/freedomtan/sensors/blob/master/sensors/sensors.m
// https://www2.slideshare.net/kstan2/exploring-thermal-related-stuff-in-idevices-using-opensource-tool

/// Each native method contains Objective-C exceptions before returning to Swift.
@objc public protocol XRGHIDTemperatureTransport: NSObjectProtocol {
    func services() -> [Any]?
    @objc(productForService:) func product(for service: Any) -> Any?
    @objc(temperatureForService:) func temperature(for service: Any) -> NSNumber?
}
@objc public protocol XRGHIDTemperatureTransportFactory: NSObjectProtocol {
    static func makeHIDTransport() -> (any XRGHIDTemperatureTransport)?
}

@objc(XRGAppleSiliconSensorMiner) @objcMembers
public final class XRGAppleSiliconSensorMiner: NSObject {
    public static func sensorData() -> [String: NSNumber]? {
        let factory = NSClassFromString("XRGAppleHIDTransport") as? any XRGHIDTemperatureTransportFactory.Type
        return sample(using: factory?.makeHIDTransport())
    }
    @nonobjc static func sample(using transport: (any XRGHIDTemperatureTransport)?) -> [String: NSNumber]? {
        guard let transport, let services = transport.services() else { return nil }
        var readings: [String: NSNumber] = [:]
        for service in services {
            let product = transport.product(for: service)
            let temperature = transport.temperature(for: service)
            if let name = product as? String, let temperature { readings[name] = temperature }
        }
        return readings
    }
}
