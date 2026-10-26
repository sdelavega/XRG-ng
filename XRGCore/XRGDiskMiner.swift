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
    private struct Tracker {
        var samples: [UInt64: XRGDiskSample] = [:]
        var time: TimeInterval?
    }
    private var normal = Tracker()
    private var fast = Tracker()
    public let readValues = XRGDataSet()
    public let writeValues = XRGDataSet()
    public let totalValues = XRGDataSet()
    public private(set) var readRate: CGFloat = 0
    public private(set) var writeRate: CGFloat = 0
    public private(set) var fastReadRate: CGFloat = 0
    public private(set) var fastWriteRate: CGFloat = 0
    public private(set) var totalBytesSinceLoad: UInt64 = 0
    public private(set) var deviceCount = 0

    public override convenience init() { self.init(source: Self.readSamples, clock: { ProcessInfo.processInfo.systemUptime }) }
    init(source: @escaping () -> [XRGDiskSample]?, clock: @escaping () -> TimeInterval) {
        self.source = source; self.clock = clock
        super.init()
        if let samples = source() {
            let time = clock()
            if time.isFinite {
                var initial = Tracker()
                for sample in samples where initial.samples[sample.id] == nil { initial.samples[sample.id] = sample }
                initial.time = time; normal = initial; fast = initial; deviceCount = initial.samples.count
            }
        }
    }
    public func setDataSize(_ count: Int) {
        guard count >= 0 else { return }
        for history in [readValues, writeValues, totalValues] { history.resize(min(count, 20_000)) }
    }
    private static func add(_ left: UInt64, _ right: UInt64) -> UInt64 {
        let (result, overflow) = left.addingReportingOverflow(right)
        return overflow ? .max : result
    }
    private struct Delta { let read: UInt64; let written: UInt64; let readRate: CGFloat; let writeRate: CGFloat }
    private func poll(_ tracker: inout Tracker) -> Delta? {
        guard let samples = source() else { return nil }
        let now = clock()
        guard now.isFinite else { return nil }
        let elapsed = tracker.time.map { now - $0 } ?? 0
        var next: [UInt64: XRGDiskSample] = [:]
        var read: UInt64 = 0, written: UInt64 = 0
        for sample in samples where next[sample.id] == nil {
            next[sample.id] = sample
            guard elapsed > 0, let previous = tracker.samples[sample.id] else { continue }
            read = Self.add(read, sample.read >= previous.read ? sample.read - previous.read : 0)
            written = Self.add(written, sample.written >= previous.written ? sample.written - previous.written : 0)
        }
        tracker.samples = next; tracker.time = now; deviceCount = next.count
        let readRate = elapsed > 0 ? Double(read) / elapsed : 0
        let writeRate = elapsed > 0 ? Double(written) / elapsed : 0
        return Delta(read: read, written: written, readRate: readRate.isFinite ? CGFloat(readRate) : 0,
                     writeRate: writeRate.isFinite ? CGFloat(writeRate) : 0)
    }
    @discardableResult public func update() -> Bool {
        guard let delta = poll(&normal) else { return false }
        readRate = delta.readRate; writeRate = delta.writeRate
        totalBytesSinceLoad = Self.add(totalBytesSinceLoad, Self.add(delta.read, delta.written))
        readValues.setNextValue(readRate); writeValues.setNextValue(writeRate)
        let total = readRate + writeRate
        totalValues.setNextValue(total.isFinite ? total : 0)
        return true
    }
    @discardableResult public func updateFast() -> Bool {
        guard let delta = poll(&fast) else { return false }
        fastReadRate = delta.readRate; fastWriteRate = delta.writeRate
        return true
    }
    public func rebaseFast() { fast = Tracker(); fastReadRate = 0; fastWriteRate = 0 }
    public func reset() {
        for history in [readValues, writeValues, totalValues] { history.reset() }
        readRate = 0; writeRate = 0; fastReadRate = 0; fastWriteRate = 0
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
