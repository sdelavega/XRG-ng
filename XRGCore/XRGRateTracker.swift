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

@objc(XRGCounterSample)
@objcMembers
public final class XRGCounterSample: NSObject {
    public let delta: UInt64
    public let rate: UInt32
    fileprivate init(delta: UInt64, rate: UInt32) {
        self.delta = delta
        self.rate = rate
    }
}

@objc(XRGRateTracker)
public final class XRGRateTracker: NSObject {
    private let lock = NSLock()
    private var counters: [String: (UInt64, TimeInterval)] = [:]
    private var costSample: (Double, TimeInterval)?

    @objc public func reset() {
        lock.withLock { counters = [:]; costSample = nil }
    }

    @objc(sampleCounter:key:time:)
    public func sample(counter: UInt64, key: String, time: TimeInterval) -> XRGCounterSample {
        lock.withLock {
            guard time.isFinite else { return XRGCounterSample(delta: 0, rate: 0) }
            guard let previous = counters[key] else {
                counters[key] = (counter, time)
                return XRGCounterSample(delta: 0, rate: 0)
            }
            guard time > previous.1 else { return XRGCounterSample(delta: 0, rate: 0) }
            counters[key] = (counter, time)
            guard counter >= previous.0 else { return XRGCounterSample(delta: 0, rate: 0) }
            let delta = counter - previous.0
            let rate = Double(delta) / (time - previous.1)
            return XRGCounterSample(delta: delta, rate: rate >= Double(UInt32.max) ? .max : UInt32(rate))
        }
    }

    @objc(sampleCost:time:)
    public func sampleCost(_ total: Double, time: TimeInterval) -> Double {
        lock.withLock {
            guard total.isFinite, total >= 0, time.isFinite else { return 0 }
            guard let previous = costSample else { costSample = (total, time); return 0 }
            guard time > previous.1 else { return 0 }
            costSample = (total, time)
            guard total >= previous.0 else { return 0 }
            let rate = (total - previous.0) / (time - previous.1)
            return rate.isFinite ? rate : 0
        }
    }
}
