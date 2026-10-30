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
import IOKit.storage

struct XRGDiskSample: Sendable {
    let id: UInt64
    let read: UInt64
    let written: UInt64
}

/// Each sampling stream has its own per-device baseline and monotonic timestamp.
@MainActor @objc(XRGDiskMiner)
public final class XRGDiskMiner: NSObject {
    private let source: () -> [XRGDiskSample]?
    private let clock: () -> TimeInterval
    private var normal = XRGIOCounterTracker<UInt64>()
    private var fast = XRGIOCounterTracker<UInt64>()
    public let readValues = XRGDataSet()
    public let writeValues = XRGDataSet()
    public let totalValues = XRGDataSet()
    public private(set) var readRate: CGFloat = 0
    public private(set) var writeRate: CGFloat = 0
    public private(set) var fastReadRate: CGFloat = 0
    public private(set) var fastWriteRate: CGFloat = 0
    public var totalBytesSinceLoad: UInt64 { normal.total }
    public var readBytesSinceLoad: UInt64 { normal.first }
    public var writtenBytesSinceLoad: UInt64 { normal.second }
    public var transfersAreLowerBound: Bool { normal.lowerBound }
    public var countersAvailable: Bool { normal.available }
    public var fastCountersAvailable: Bool { fast.available }
    public var transferDetails: String {
        "Scope: all IOBlockStorageDriver devices (\(deviceCount) in last snapshot).\nKernel counters (normally since boot): Read \(rawRead) bytes / Write \(rawWritten) bytes\(rawSaturated ? " (saturated lower bounds)" : "").\n"
        + normal.details(firstLabel: "Read", secondLabel: "Write")
        + "IOKit registry entry IDs detect device replacement. These are transfers, not disk capacity."
    }
    public private(set) var deviceCount = 0
    private var rawRead: UInt64 = 0
    private var rawWritten: UInt64 = 0
    private var rawSaturated = false

    public override convenience init() { self.init(source: Self.readSamples, clock: { ProcessInfo.processInfo.systemUptime }) }
    init(source: @escaping () -> [XRGDiskSample]?, clock: @escaping () -> TimeInterval) {
        self.source = source; self.clock = clock
        super.init()
        if let counters = snapshot() {
            let time = clock()
            _ = normal.sample(counters, at: time); _ = fast.sample(counters, at: time)
            updateRawCounters(counters)
        }
    }
    public func setDataSize(_ count: Int) {
        guard count >= 0 else { return }
        for history in [readValues, writeValues, totalValues] { history.resize(min(count, 20_000)) }
    }
    private func snapshot() -> [UInt64: XRGIOCounters]? {
        guard let samples = source() else { return nil }
        var counters: [UInt64: XRGIOCounters] = [:]
        for sample in samples {
            guard counters[sample.id] == nil else { return nil }
            counters[sample.id] = XRGIOCounters(first: sample.read, second: sample.written)
        }
        return counters
    }
    private func updateRawCounters(_ counters: [UInt64: XRGIOCounters]) {
        deviceCount = counters.count
        rawRead = 0; rawWritten = 0; rawSaturated = false
        for value in counters.values {
            let a = XRGIOCounterTracker<UInt64>.sum(rawRead, value.first)
            let b = XRGIOCounterTracker<UInt64>.sum(rawWritten, value.second)
            rawRead = a.value; rawWritten = b.value
            rawSaturated = rawSaturated || a.overflow || b.overflow
        }
    }
    @discardableResult public func update() -> Bool {
        guard let counters = snapshot(), let reading = normal.sample(counters, at: clock()) else {
            normal.fail()
            for history in [readValues, writeValues, totalValues] { history.setNextValue(XRGGraphRenderer.missingValue) }
            return false
        }
        if reading.newSession { reset() }
        updateRawCounters(counters)
        readRate = reading.firstRate; writeRate = reading.secondRate
        readValues.setNextValue(readRate); writeValues.setNextValue(writeRate)
        totalValues.setNextValue(readRate + writeRate)
        return true
    }
    @discardableResult public func updateFast() -> Bool {
        guard let counters = snapshot(), let reading = fast.sample(counters, at: clock()) else {
            fast.fail(); return false
        }
        fastReadRate = reading.firstRate; fastWriteRate = reading.secondRate
        return true
    }
    public func rebaseFast() { fast = XRGIOCounterTracker(); fastReadRate = 0; fastWriteRate = 0 }
    public func resetTransfers() { normal.resetTransfers() }
    public func reset() {
        for history in [readValues, writeValues, totalValues] { history.reset() }
    }

    nonisolated static func decodeStatistics(id: UInt64, _ statistics: [String: Any]) -> XRGDiskSample? {
        func counter(_ value: Any?) -> UInt64? {
            guard let number = value as? NSNumber, CFGetTypeID(number) != CFBooleanGetTypeID() else { return nil }
            return UInt64(number.stringValue)
        }
        guard let read = counter(statistics[kIOBlockStorageDriverStatisticsBytesReadKey]),
              let written = counter(statistics[kIOBlockStorageDriverStatisticsBytesWrittenKey]) else { return nil }
        return XRGDiskSample(id: id, read: read, written: written)
    }
    nonisolated static func readSamples() -> [XRGDiskSample]? {
        var iterator: io_iterator_t = 0
        guard IOServiceGetMatchingServices(kIOMainPortDefault, IOServiceMatching("IOBlockStorageDriver"), &iterator) == KERN_SUCCESS else { return nil }
        defer { IOObjectRelease(iterator) }
        var result: [XRGDiskSample] = []
        while true {
            let device = IOIteratorNext(iterator)
            guard device != 0 else { break }
            defer { IOObjectRelease(device) }
            var id: UInt64 = 0
            guard IORegistryEntryGetRegistryEntryID(device, &id) == KERN_SUCCESS,
                  let property = IORegistryEntryCreateCFProperty(device, kIOBlockStorageDriverStatisticsKey as CFString, kCFAllocatorDefault, 0)?.takeRetainedValue(),
                  let statistics = property as? [String: Any], let sample = decodeStatistics(id: id, statistics) else { return nil }
            result.append(sample)
        }
        return result
    }
}
