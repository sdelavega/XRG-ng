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

@objc public enum XRGStatsModule: Int {
    case nameCPU, nameGPU, nameMemory, nameTemperature, nameBattery
    case nameDisk, nameNetwork, nameWeather, nameStock
}

@objc(XRGStatsContentItem)
@objcMembers
public final class XRGStatsContentItem: NSObject {
    public let key: String
    public private(set) var last: Double
    public private(set) var min: Double
    public private(set) var max: Double
    public private(set) var average: Double
    private var count: UInt64 = 1

    public init(key: String, initialValue: Double) {
        self.key = key
        last = initialValue
        min = initialValue
        max = initialValue
        average = initialValue
        super.init()
    }

    public func observeStat(_ value: Double) {
        min = Swift.min(min, value)
        max = Swift.max(max, value)
        count += 1
        average += (value - average) / Double(count)
        last = value
    }

    fileprivate func snapshot() -> XRGStatsContentItem {
        let copy = XRGStatsContentItem(key: key, initialValue: last)
        copy.min = min
        copy.max = max
        copy.average = average
        copy.count = count
        return copy
    }
}

@objc(XRGStatsModuleContent)
@objcMembers
public final class XRGStatsModuleContent: NSObject {
    private var items: [String: XRGStatsContentItem] = [:]

    public func keys() -> [String] { Array(items.keys) }

    public func stats(forKey key: String) -> XRGStatsContentItem? {
        items[key]?.snapshot()
    }

    public func observeStat(_ value: Double, forKey key: String) {
        if let item = items[key] {
            item.observeStat(value)
        } else {
            // Construction records the first sample; do not count it twice.
            items[key] = XRGStatsContentItem(key: key, initialValue: value)
        }
    }
}

/// All owned module state is protected by lock; callers receive snapshots.
@objc(XRGStatsManager)
@objcMembers
public final class XRGStatsManager: NSObject, @unchecked Sendable {
    public static let shared = XRGStatsManager()
    private let lock = NSLock()
    private var modules: [XRGStatsModule: XRGStatsModuleContent] = [:]

    public func clearHistory() {
        lock.withLock { modules.removeAll() }
    }

    public func clearHistory(forModule module: XRGStatsModule) {
        lock.withLock { _ = modules.removeValue(forKey: module) }
    }

    public func stat(forKey key: String, inModule module: XRGStatsModule) -> XRGStatsContentItem? {
        lock.withLock { modules[module]?.stats(forKey: key) }
    }

    public func observeStat(_ value: Double, forKey key: String, inModule module: XRGStatsModule) {
        lock.withLock {
            let content = modules[module] ?? XRGStatsModuleContent()
            content.observeStat(value, forKey: key)
            modules[module] = content
        }
    }
}
