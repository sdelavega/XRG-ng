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

/// Every implementation must contain Objective-C exceptions within its own calls.
@MainActor @objc public protocol XRGTemperatureReader: NSObjectProtocol {
    @objc(temperatureValuesIncludingUnknown:)
    func temperatures(includingUnknown: Bool) -> [String: Any]
    @objc(siliconTemperatureValues)
    func siliconTemperatures() -> [String: Any]
    @objc(fanValues)
    func fanReadings() -> [String: Any]
    @objc(humanReadableNameForKey:)
    func name(forKey key: String) -> String?
    func isKnownKey(_ key: String) -> Bool
    var knownTemperatureKeyCount: Int { get }
}

/// The app supplies this factory; the core and its tests do not link sensor transports.
@MainActor @objc public protocol XRGTemperatureReaderFactory: NSObjectProtocol {
    static func makeTemperatureReader() -> any XRGTemperatureReader
}

@MainActor
@objc(XRGTemperatureMiner) @objcMembers
public final class XRGTemperatureMiner: NSObject {
    public static let shared = XRGTemperatureMiner()
    private let state = XRGTemperatureState()
    private let reader: (any XRGTemperatureReader)?
    private let clock: () -> TimeInterval
    private var fanCache: [XRGFan]?
    private var fanCacheTime: TimeInterval?

    public override convenience init() {
        // Runtime discovery keeps the low-level Objective-C adapter out of XRGCore.
        let factory = NSClassFromString("XRGTemperatureHardwareReader") as? any XRGTemperatureReaderFactory.Type
        self.init(reader: factory?.makeTemperatureReader())
    }

    @nonobjc init(reader: (any XRGTemperatureReader)?,
                  clock: @escaping () -> TimeInterval = { ProcessInfo.processInfo.systemUptime }) {
        self.reader = reader
        self.clock = clock
        super.init()
    }

    public var knownTemperatureKeyCount: Int { reader?.knownTemperatureKeyCount ?? 0 }
    public func numberOfCPUs() -> Int { ProcessInfo.processInfo.processorCount }
    public func reset() { state.reset() }
    public func setDataSize(_ size: Int) { state.setDataSize(size) }
    public func allSensorKeys() -> [String] { state.allSensorKeys() }
    @objc(sensorForLocation:)
    public func sensor(forLocation location: String) -> XRGSensorData? { state.sensor(forLocation: location) }
    public func regenerateLocationKeyOrder() { state.regenerateLocationKeyOrder() }

    private func names(for keys: [String]) -> [String: String] {
        keys.reduce(into: [:]) { result, key in result[key] = reader?.name(forKey: key) ?? key }
    }

    @objc(setCurrentValue:andUnits:forLocation:)
    public func setCurrentValue(_ value: Float, andUnits units: String?, forLocation location: String) {
        state.setCurrentValue(Double(value), andUnits: units, forLocation: location,
                              name: reader?.name(forKey: location))
    }

    public func updateCurrentTemperatures(_ includeUnknown: Bool) {
        guard state.shouldUpdate(at: clock(), includeUnknown: includeUnknown) else { return }
        state.beginUpdate()
        defer { state.finishUpdate() }
        let temperatures = reader?.temperatures(includingUnknown: includeUnknown) ?? [:]
        state.ingestTemperatures(temperatures, names: names(for: Array(temperatures.keys)))
        let fans = fanValues()
        state.ingestFans(fans, names: names(for: fans.map(\.key)))
        let silicon = reader?.siliconTemperatures() ?? [:]
        state.ingestTemperatures(silicon, names: names(for: Array(silicon.keys)))
    }

    @objc(locationKeysIncludingUnknown:)
    public func locationKeys(includingUnknown: Bool) -> [String] {
        let keys = state.locationKeys()
        return includingUnknown ? keys : keys.filter { reader?.isKnownKey($0) == true }
    }

    public func fanValues() -> [XRGFan] {
        let now = clock()
        guard now.isFinite else { return [] }
        if let fanCache, let fanCacheTime, now >= fanCacheTime, now - fanCacheTime < 1 { return fanCache }
        let fans = XRGTemperatureState.decodeFans(reader?.fanReadings() ?? [:])
        fanCache = fans
        fanCacheTime = now
        return fans
    }
    @nonobjc func fanGraphReadings() -> [XRGHardwareReading] {
        fanValues().map { fan in
            XRGHardwareReading(id: fan.key, name: reader?.name(forKey: fan.key) ?? fan.name ?? fan.key,
                               value: Double(fan.actualSpeed), note: "Read-only actual fan RPM; zero can mean stopped.")
        }
    }

    // Empty graph selections can pass nil through Objective-C; preserve that behavior.
    public func isFanSensor(_ sensor: XRGSensorData?) -> Bool {
        guard let sensor else { return false }
        return fanValues().contains { $0.key == sensor.key }
    }
    @objc(maxSpeedForFan:)
    public func maxSpeed(forFan sensor: XRGSensorData?) -> Int {
        guard let sensor else { return 0 }
        return fanValues().first { $0.key == sensor.key }?.maximumSpeed ?? 0
    }
}
