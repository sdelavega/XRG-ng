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
import IOKit

@objc public enum XRGBatteryStatus: Int {
    case unknown, runningOnBattery, charging, charged, onHold, noBattery
}

@objcMembers
public final class XRGBatteryInfo: NSObject {
    public let hasRawCapacity: Bool
    private let chargeFraction: Double
    public let currentCharge: Int
    public let totalCapacity: Int
    public let voltage: CGFloat
    public let amperage: CGFloat
    public let minutesRemaining: Int
    public let isCharging: Bool
    public let isFullyCharged: Bool
    public let isPluggedIn: Bool

    public init(dictionary: [String: Any]) {
        func number(_ key: String) -> NSNumber { dictionary[key] as? NSNumber ?? 0 }
        let rawCurrent = dictionary["AppleRawCurrentCapacity"] as? NSNumber
        let rawMaximum = dictionary["AppleRawMaxCapacity"] as? NSNumber
        hasRawCapacity = rawCurrent != nil && (rawMaximum?.doubleValue ?? 0) > 0
        // Some macOS power sources expose only normalized percentage capacities.
        let current = hasRawCapacity ? rawCurrent?.doubleValue : (dictionary["CurrentCapacity"] as? NSNumber)?.doubleValue
        let maximum = hasRawCapacity ? rawMaximum?.doubleValue : (dictionary["MaxCapacity"] as? NSNumber)?.doubleValue
        if let current, let maximum, current.isFinite, maximum.isFinite, maximum > 0 {
            chargeFraction = min(1, max(0, current / maximum))
        } else {
            chargeFraction = 0
        }
        currentCharge = max(0, number("AppleRawCurrentCapacity").intValue)
        totalCapacity = max(0, number("AppleRawMaxCapacity").intValue)
        voltage = max(0, CGFloat(number("Voltage").doubleValue) / 1000)
        amperage = CGFloat(number("Amperage").int64Value) / 1000
        let minutes = number("TimeRemaining").intValue
        minutesRemaining = minutes > 0 && minutes < 65535 ? minutes : 0
        isCharging = number("IsCharging").boolValue
        isFullyCharged = number("FullyCharged").boolValue
        isPluggedIn = number("ExternalConnected").boolValue
        super.init()
    }

    public func percentCharged() -> CGFloat {
        CGFloat(chargeFraction)
    }
}

@MainActor
@objc(XRGBatteryMiner)
public final class XRGBatteryMiner: NSObject {
    private let source: () -> [XRGBatteryInfo]?
    private var hasSample = false
    @objc public private(set) var batteries: [XRGBatteryInfo] = []
    @objc public let chargeWatts = XRGDataSet()
    @objc public let dischargeWatts = XRGDataSet()
    @objc public private(set) var numSamples = 0

    public override convenience init() { self.init(source: Self.readBatteries) }
    public init(source: @escaping () -> [XRGBatteryInfo]?) {
        self.source = source
        super.init()
    }

    @objc public func setDataSize(_ count: Int) {
        guard count >= 0 else { return }
        chargeWatts.resize(count)
        dischargeWatts.resize(count)
        numSamples = count
    }

    @objc public func graphUpdate(_ timer: Timer?) {
        guard let sample = source() else { return }
        batteries = sample
        hasSample = true
        var charging: CGFloat = 0
        var discharging: CGFloat = 0
        for battery in sample {
            let watts = battery.amperage * battery.voltage
            guard watts.isFinite else { continue }
            charging += max(0, watts)
            discharging += max(0, -watts)
        }
        chargeWatts.setNextValue(charging)
        dischargeWatts.setNextValue(discharging)
    }
    @nonobjc func resizeHistory(_ count: Int) {
        guard (1...XRGSamplingSettings.maximumHistorySamples).contains(count) else { return }
        chargeWatts.resize(count, fillingWith: XRGGraphRenderer.missingValue)
        dischargeWatts.resize(count, fillingWith: XRGGraphRenderer.missingValue)
        numSamples = count
    }

    @objc public func reset() { chargeWatts.reset(); dischargeWatts.reset() }
    @objc public func batteryStatus() -> XRGBatteryStatus {
        guard hasSample else { return .unknown }
        guard let battery = batteries.first else { return .noBattery }
        guard battery.isPluggedIn else { return .runningOnBattery }
        if battery.isFullyCharged { return .charged }
        return battery.isCharging ? .charging : .onHold
    }
    @objc public func minutesRemaining() -> Int { batteries.map(\.minutesRemaining).max() ?? 0 }
    private func sum(_ key: KeyPath<XRGBatteryInfo, Int>) -> Int {
        batteries.reduce(0) {
            let (value, overflow) = $0.addingReportingOverflow($1[keyPath: key])
            return overflow ? Int.max : value
        }
    }
    @objc public func totalCharge() -> Int { sum(\.currentCharge) }
    @objc public func totalCapacity() -> Int { sum(\.totalCapacity) }
    @objc public var hasRawCapacity: Bool {
        !batteries.isEmpty && batteries.allSatisfy(\.hasRawCapacity)
    }
    @objc public func chargePercent() -> Int {
        guard !batteries.isEmpty else { return 0 }
        if !hasRawCapacity {
            let fraction = batteries.reduce(0.0) { $0 + Double($1.percentCharged()) } / Double(batteries.count)
            return Int((fraction * 100).rounded())
        }
        let capacity = batteries.reduce(0.0) { $0 + Double($1.totalCapacity) }
        guard capacity > 0 else { return 0 }
        let charge = batteries.reduce(0.0) { $0 + Double($1.currentCharge) }
        return Int((min(1, charge / capacity) * 100).rounded())
    }

    private static func readBatteries() -> [XRGBatteryInfo]? {
        var iterator: io_iterator_t = 0
        guard IOServiceGetMatchingServices(kIOMainPortDefault,
            IOServiceMatching("IOPMPowerSource"), &iterator) == KERN_SUCCESS else { return nil }
        defer { IOObjectRelease(iterator) }
        var result: [XRGBatteryInfo] = []
        while true {
            let service = IOIteratorNext(iterator)
            guard service != 0 else { break }
            defer { IOObjectRelease(service) }
            var properties: Unmanaged<CFMutableDictionary>?
            guard IORegistryEntryCreateCFProperties(service, &properties, nil, 0) == KERN_SUCCESS,
                  let dictionary = properties?.takeRetainedValue() as? [String: Any] else { return nil }
            result.append(XRGBatteryInfo(dictionary: dictionary))
        }
        return result
    }
}
