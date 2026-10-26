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

@objc(XRGFan) @objcMembers
public final class XRGFan: NSObject {
    public var name: String?
    public var key = ""
    public var actualSpeed = 0
    public var targetSpeed = 0
    public var minimumSpeed = 0
    public var maximumSpeed = 0
}

@objc(XRGSensorData) @objcMembers
public final class XRGSensorData: NSObject {
    public var humanReadableName: String?
    public var units: String?
    public var key: String
    public var currentValue = 0.0
    public let dataSet = XRGDataSet()
    public var isEnabled = false

    @objc(initWithSensorKey:)
    public init(sensorKey: String) {
        key = sensorKey
        super.init()
    }
    public func label() -> String { humanReadableName ?? key }
}

@MainActor
@objc(XRGTemperatureState) @objcMembers
public final class XRGTemperatureState: NSObject {
    private var sensors: [String: XRGSensorData] = [:]
    private var count = 0
    private var lastUpdate: TimeInterval?
    private var lastIncludeUnknown: Bool?
    private var orderedKeys: [String] = []

    public func shouldUpdate(at time: TimeInterval, includeUnknown: Bool) -> Bool {
        guard time.isFinite else { return false }
        if let lastUpdate, time >= lastUpdate, time - lastUpdate < 5,
           lastIncludeUnknown == includeUnknown { return false }
        lastUpdate = time
        lastIncludeUnknown = includeUnknown
        return true
    }

    public func beginUpdate() {
        for sensor in sensors.values { sensor.isEnabled = false }
    }
    public func finishUpdate() {
        for sensor in sensors.values where !sensor.isEnabled {
            sensor.currentValue = 0
            sensor.dataSet.setNextValue(0)
        }
        regenerateLocationKeyOrder()
    }

    @objc(setCurrentValue:andUnits:forLocation:name:)
    public func setCurrentValue(_ value: Double, andUnits units: String?,
                                forLocation location: String, name: String?) {
        guard value.isFinite, !location.isEmpty else { return }
        let sensor: XRGSensorData
        if let existing = sensors[location] {
            sensor = existing
        } else {
            sensor = XRGSensorData(sensorKey: location)
            sensor.dataSet.resize(count)
            sensor.dataSet.setAllValues(value)
            sensors[location] = sensor
        }
        sensor.units = units
        sensor.humanReadableName = name
        sensor.currentValue = value
        sensor.isEnabled = true
        sensor.dataSet.setNextValue(value)
        XRGStatsManager.shared.observeStat(value, forKey: location, inModule: .nameTemperature)
        regenerateLocationKeyOrder()
    }

    public func ingestTemperatures(_ values: [String: Any], names: [String: String]) {
        for (key, raw) in values {
            guard raw is NSNumber, let value = Self.numericValue(raw), (15...150).contains(value) else { continue }
            setCurrentValue(value, andUnits: "°C", forLocation: key, name: names[key] ?? key)
        }
    }

    public static func numericValue(_ raw: Any) -> Double? {
        let value: Double
        if let number = raw as? NSNumber, CFGetTypeID(number) != CFBooleanGetTypeID() {
            value = number.doubleValue
        } else if let data = raw as? Data, data.count == MemoryLayout<Float>.size {
            value = data.withUnsafeBytes { Double($0.loadUnaligned(as: Float.self)) }
        } else { return nil }
        return value.isFinite ? value : nil
    }

    public static func decodeFans(_ values: [String: Any]) -> [XRGFan] {
        values.keys.sorted().compactMap { name in
            guard let fields = values[name] as? [String: Any] else { return nil }
            let fan = XRGFan()
            fan.name = name
            for key in fields.keys.sorted() {
                guard let raw = fields[key], let value = numericValue(raw),
                      value >= 0, value < Double(Int.max) else { continue }
                if key.hasSuffix("Ac") { fan.key = key; fan.actualSpeed = Int(value) }
                else if key.hasSuffix("Tg") { fan.targetSpeed = Int(value) }
                else if key.hasSuffix("Mn") { fan.minimumSpeed = Int(value) }
                else if key.hasSuffix("Mx") { fan.maximumSpeed = Int(value) }
            }
            return fan.key.isEmpty ? nil : fan
        }
    }

    public func ingestFans(_ fans: [XRGFan], names: [String: String]) {
        for fan in fans {
            setCurrentValue(Double(fan.actualSpeed), andUnits: " rpm", forLocation: fan.key,
                            name: names[fan.key] ?? fan.key)
        }
    }

    public func sensor(forLocation location: String) -> XRGSensorData? { sensors[location] }
    public func allSensorKeys() -> [String] { sensors.keys.sorted() }
    public func locationKeys() -> [String] { orderedKeys }
    public func setDataSize(_ size: Int) {
        guard size >= 0 else { return }
        count = size
        for sensor in sensors.values { sensor.dataSet.resize(size) }
    }
    public func reset() {
        for sensor in sensors.values { sensor.dataSet.reset() }
    }
    public func regenerateLocationKeyOrder() {
        func rank(_ sensor: XRGSensorData) -> (Int, Int) {
            let unit = ["°C", " rpm", "%"].firstIndex(of: sensor.units ?? "") ?? 3
            guard let name = sensor.humanReadableName, name != sensor.key else { return (unit, 10) }
            let group: Int
            if name.contains("CPU") && name.contains("Core") { group = 0 }
            else if name.contains("CPU A") { group = 1 }
            else if name.contains("CPU B") { group = 2 }
            else if name.contains("CPU") { group = 3 }
            else if name.contains("GPU") { group = 4 }
            else if name.contains("Memory") || name.contains("U3") { group = 5 }
            else if name.uppercased().contains("BATTERY") { group = 6 }
            else if name.uppercased().contains("DRIVE") || name.contains("HDD") { group = 7 }
            else { group = 8 }
            return (unit, group)
        }
        orderedKeys = sensors.values.sorted {
            let a = rank($0), b = rank($1)
            return a == b ? $0.key < $1.key : a < b
        }.map(\.key)
    }
}
