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
    @objc(locationIDForService:) optional func locationID(for service: Any) -> NSNumber?
}
@objc public protocol XRGHIDTemperatureTransportFactory: NSObjectProtocol {
    static func makeHIDTransport() -> (any XRGHIDTemperatureTransport)?
}

// Every access to products is protected by lock, including native sampling.
private final class XRGHIDIdentityState: @unchecked Sendable {
    let lock = NSLock()
    var products = Set<String>()
}

@objc(XRGAppleSiliconSensorMiner) @objcMembers
public final class XRGAppleSiliconSensorMiner: NSObject {
    private static let identityState = XRGHIDIdentityState()
    public static func sensorData() -> [String: NSNumber]? {
        identityState.lock.lock()
        defer { identityState.lock.unlock() }
        let factory = NSClassFromString("XRGAppleHIDTransport") as? any XRGHIDTemperatureTransportFactory.Type
        return sample(using: factory?.makeHIDTransport(), disambiguating: &identityState.products)
    }
    @nonobjc static func sample(using transport: (any XRGHIDTemperatureTransport)?) -> [String: NSNumber]? {
        var products = Set<String>()
        return sample(using: transport, disambiguating: &products)
    }
    @nonobjc static func sample(using transport: (any XRGHIDTemperatureTransport)?,
                               disambiguating products: inout Set<String>) -> [String: NSNumber]? {
        guard let transport, let services = transport.services() else { return nil }
        var groups: [String: [(service: Any, temperature: NSNumber?)]] = [:]
        for service in services {
            let product = transport.product(for: service)
            let temperature = transport.temperature(for: service)
            if let name = product as? String { groups[name, default: []].append((service, temperature)) }
        }
        products.formUnion(groups.filter { $0.value.count > 1 }.keys)
        var readings: [String: NSNumber] = [:], collisions = Set<String>()
        for (name, channels) in groups {
            if !products.contains(name) {
                if let temperature = channels.first?.temperature {
                    if readings.updateValue(temperature, forKey: name) != nil { collisions.insert(name) }
                }
                continue
            }
            // Product strings are not identities: several battery services have
            // the same Product. Resolve every ID before publishing any reading.
            var ids: [UInt32] = []
            for channel in channels {
                guard let number = transport.locationID?(for: channel.service) ?? nil,
                      CFGetTypeID(number) != CFBooleanGetTypeID(),
                      let id = UInt32(number.stringValue), id != 0 else { break }
                ids.append(id)
            }
            guard ids.count == channels.count, Set(ids).count == ids.count else { continue }
            for (channel, id) in zip(channels, ids) {
                guard let temperature = channel.temperature else { continue }
                let key = identity(product: name, location: id)
                if readings.updateValue(temperature, forKey: key) != nil { collisions.insert(key) }
            }
        }
        for key in collisions { readings.removeValue(forKey: key) }
        return readings
    }
    @nonobjc static func identity(product: String, location: UInt32) -> String {
        "HID:\(String(format: "%08X", location)):\(product)"
    }
    @nonobjc static func parseIdentity(_ key: String) -> (product: String, location: UInt32)? {
        let pieces = key.split(separator: ":", maxSplits: 2, omittingEmptySubsequences: false)
        guard pieces.count == 3, pieces[0] == "HID", pieces[1].utf8.count == 8,
              pieces[1].utf8.allSatisfy({ (48...57).contains($0) || (65...70).contains($0) }),
              let id = UInt32(pieces[1], radix: 16), id != 0 else { return nil }
        return (String(pieces[2]), id)
    }
}
