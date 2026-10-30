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
import Darwin

public struct XRGMemorySnapshot: Sendable {
    public var free: UInt64 = 0
    public var active: UInt64 = 0
    public var inactive: UInt64 = 0
    public var wired: UInt64 = 0
    public var faults: UInt64 = 0
    public var pageIns: UInt64 = 0
    public var pageOuts: UInt64 = 0
    public var lookups: UInt64 = 0
    public var hits: UInt64 = 0
    public var usedSwap: UInt64?
    public var totalSwap: UInt64?
    public init() {}
}

@MainActor
@objc(XRGMemoryMiner)
public final class XRGMemoryMiner: NSObject {
    private let source: () -> XRGMemorySnapshot?
    private let historyClock: () -> TimeInterval
    let timedHistory = XRGTimedHistory(channels: 3, retentionMinutes: XRGTimedHistory.systemMaximumMinutes)!
    private var previous: XRGMemorySnapshot?
    private var current = XRGMemorySnapshot()
    private var faults: UInt64 = 0
    private var pageIns: UInt64 = 0
    private var pageOuts: UInt64 = 0
    private let faultsHistory = XRGDataSet()
    private let pageInHistory = XRGDataSet()
    private let pageOutHistory = XRGDataSet()
    @objc public let pageSize: UInt64
    @objc public private(set) var usedSwap: UInt64 = 0
    @objc public private(set) var totalSwap: UInt64 = 0

    public override convenience init() {
        self.init(pageSize: UInt64(getpagesize()), source: Self.readSnapshot)
    }
    public init(pageSize: UInt64, source: @escaping () -> XRGMemorySnapshot?, historyClock: @escaping () -> TimeInterval = { Date().timeIntervalSince1970 }) {
        self.pageSize = pageSize
        self.source = source
        self.historyClock = historyClock
        super.init()
        getLatestMemoryInfo()
    }

    @objc public func setDataSize(_ count: Int) {
        guard count >= 0 else { return }
        for data in [faultsHistory, pageInHistory, pageOutHistory] { data.resize(count) }
    }
    @nonobjc func resizeHistory(_ count: Int) {
        guard (1...XRGSamplingSettings.maximumHistorySamples).contains(count) else { return }
        for data in [faultsHistory, pageInHistory, pageOutHistory] { data.resize(count, fillingWith: XRGGraphRenderer.missingValue) }
    }
    @objc public func reset() {
        for data in [faultsHistory, pageInHistory, pageOutHistory] { data.reset() }
        timedHistory.clear()
        previous = nil
        faults = 0; pageIns = 0; pageOuts = 0
    }

    @objc public func getLatestMemoryInfo() {
        guard let sample = source() else {
            timedHistory.append(time: historyClock(), values: [.nan, .nan, .nan])
            return
        }
        if let previous, sample.faults < previous.faults || sample.pageIns < previous.pageIns || sample.pageOuts < previous.pageOuts {
            timedHistory.clear()
        }
        func delta(_ value: UInt64, _ old: UInt64?) -> UInt64 {
            guard let old, value >= old else { return 0 }
            return value - old
        }
        faults = delta(sample.faults, previous?.faults)
        pageIns = delta(sample.pageIns, previous?.pageIns)
        pageOuts = delta(sample.pageOuts, previous?.pageOuts)
        current = sample
        previous = sample
        faultsHistory.setNextValue(CGFloat(faults))
        pageInHistory.setNextValue(CGFloat(pageIns))
        pageOutHistory.setNextValue(CGFloat(pageOuts))
        timedHistory.append(time: historyClock(), values: [Double(faults), Double(pageIns), Double(pageOuts)])
        if let used = sample.usedSwap, let total = sample.totalSwap {
            usedSwap = used
            totalSwap = total
        }
    }

    private func bytes(_ pages: UInt64) -> UInt64 {
        let (value, overflow) = pages.multipliedReportingOverflow(by: pageSize)
        return overflow ? .max : value
    }
    @objc public func freeBytes() -> UInt64 { bytes(current.free) }
    @objc public func activeBytes() -> UInt64 { bytes(current.active) }
    @objc public func inactiveBytes() -> UInt64 { bytes(current.inactive) }
    @objc public func wiredBytes() -> UInt64 { bytes(current.wired) }
    @objc public func totalFaults() -> UInt64 { current.faults }
    @objc public func recentFaults() -> UInt64 { faults }
    @objc public func totalPageIns() -> UInt64 { current.pageIns }
    @objc public func recentPageIns() -> UInt64 { pageIns }
    @objc public func totalPageOuts() -> UInt64 { current.pageOuts }
    @objc public func recentPageOuts() -> UInt64 { pageOuts }
    @objc public func totalCacheLookups() -> UInt64 { current.lookups }
    @objc public func totalCacheHits() -> UInt64 { current.hits }
    @objc public func faultData() -> XRGDataSet { faultsHistory }
    @objc public func pageInData() -> XRGDataSet { pageInHistory }
    @objc public func pageOutData() -> XRGDataSet { pageOutHistory }

    nonisolated public static func readSnapshot() -> XRGMemorySnapshot? {
        let host = mach_host_self()
        defer { mach_port_deallocate(mach_task_self_, host) }
        var statistics = vm_statistics64_data_t()
        let capacity = MemoryLayout<vm_statistics64_data_t>.stride / MemoryLayout<integer_t>.stride
        var count = mach_msg_type_number_t(capacity)
        let status = withUnsafeMutablePointer(to: &statistics) {
            $0.withMemoryRebound(to: integer_t.self, capacity: capacity) {
                host_statistics64(host, HOST_VM_INFO64, $0, &count)
            }
        }
        guard status == KERN_SUCCESS else { return nil }
        var sample = XRGMemorySnapshot()
        sample.free = UInt64(statistics.free_count)
        sample.active = UInt64(statistics.active_count)
        sample.inactive = UInt64(statistics.inactive_count)
        sample.wired = UInt64(statistics.wire_count)
        sample.faults = statistics.faults
        sample.pageIns = statistics.pageins
        sample.pageOuts = statistics.pageouts
        sample.lookups = statistics.lookups
        sample.hits = statistics.hits
        var swap = xsw_usage()
        var size = MemoryLayout<xsw_usage>.size
        if sysctlbyname("vm.swapusage", &swap, &size, nil, 0) == 0 {
            sample.usedSwap = swap.xsu_used
            sample.totalSwap = swap.xsu_total
        }
        return sample
    }
}
