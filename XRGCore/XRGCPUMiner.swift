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

public struct XRGCPUTicks: Sendable {
    public let user: UInt32
    public let system: UInt32
    public let idle: UInt32
    public let nice: UInt32
    public init(user: UInt32, system: UInt32, idle: UInt32, nice: UInt32) {
        self.user = user; self.system = system; self.idle = idle; self.nice = nice
    }
}

@MainActor
@objc(XRGCPUMiner)
public final class XRGCPUMiner: NSObject {
    private let source: () -> [XRGCPUTicks]?
    private let clock: () -> Double
    private var slowBaseline: [XRGCPUTicks]?
    private var fastBaseline: [XRGCPUTicks]?
    private var slowTime: Double?
    private var fastTime: Double?
    private var sampleCount = 0
    private var fast: [Int?] = []
    private var current: [CGFloat?] = []
    public private(set) var countersAvailable = false
    public private(set) var fastCountersAvailable = false
    @objc public var loadAverage = true
    @objc public var uptime = false
    @objc public private(set) var uptimeDays = 0
    @objc public private(set) var uptimeHours = 0
    @objc public private(set) var uptimeMinutes = 0
    @objc public private(set) var uptimeSeconds = 0
    @objc public private(set) var numberOfCPUs = 0
    @objc public private(set) var currentLoadAverage: CGFloat = 0
    @objc public private(set) var userValues: [XRGDataSet] = []
    @objc public private(set) var systemValues: [XRGDataSet] = []
    @objc public private(set) var niceValues: [XRGDataSet] = []
    /// Legacy numeric projection. Swift presentation uses fastUsage(forCPU:) to preserve unavailable slots.
    @objc public var fastValues: [NSNumber] { fast.map { NSNumber(value: $0 ?? 0) } }

    public override convenience init() { self.init(source: Self.readTicks) }
    public convenience init(source: @escaping () -> [XRGCPUTicks]?) {
        self.init(source: source, clock: Self.continuousSeconds)
    }
    public init(source: @escaping () -> [XRGCPUTicks]?, clock: @escaping () -> Double) {
        self.source = source
        self.clock = clock
        super.init()
        if let initial = source(), !initial.isEmpty {
            configure(initial.count)
            let time = clock()
            if time.isFinite && time >= 0 {
                slowBaseline = initial; slowTime = time
                fastBaseline = initial; fastTime = time
            }
        } else {
            configure(max(1, ProcessInfo.processInfo.processorCount))
        }
    }

    private static let timebase: Double = {
        var info = mach_timebase_info_data_t()
        mach_timebase_info(&info)
        return Double(info.numer) / Double(info.denom) / 1_000_000_000
    }()
    private static func continuousSeconds() -> Double {
        // Unlike uptime ticks, this clock also advances during system sleep.
        Double(mach_continuous_time()) * timebase
    }

    private func configure(_ count: Int) {
        guard count != numberOfCPUs else { return }
        numberOfCPUs = count
        func resized(_ original: [XRGDataSet]) -> [XRGDataSet] {
            var values = Array(original.prefix(count))
            while values.count < count {
                let data = XRGDataSet()
                data.resize(sampleCount, fillingWith: XRGGraphRenderer.missingValue)
                values.append(data)
            }
            return values
        }
        userValues = resized(userValues)
        systemValues = resized(systemValues)
        niceValues = resized(niceValues)
        // A changed inventory may remap logical slots. Do not retain history or
        // current readings attributed to the previous CPU topology.
        for data in userValues + systemValues + niceValues { data.setAllValues(XRGGraphRenderer.missingValue) }
        fast = Array(repeating: nil, count: count)
        current = Array(repeating: nil, count: count)
        countersAvailable = false; fastCountersAvailable = false
        slowBaseline = nil
        fastBaseline = nil
        slowTime = nil; fastTime = nil
    }

    @objc public func setDataSize(_ count: Int) {
        guard count >= 0 else { return }
        sampleCount = min(count, 20_000)
        for data in userValues + systemValues + niceValues { data.resize(sampleCount, fillingWith: XRGGraphRenderer.missingValue) }
    }

    /// Mach CPU counters are unsigned 32-bit tick counts and may wrap.
    private func usage(_ current: [XRGCPUTicks], previous: [XRGCPUTicks]?) -> [(CGFloat, CGFloat, CGFloat)?] {
        guard let previous, previous.count == current.count else {
            return Array(repeating: nil, count: current.count)
        }
        return zip(current, previous).map { current, previous in
            let user = UInt64(current.user &- previous.user)
            let system = UInt64(current.system &- previous.system)
            let idle = UInt64(current.idle &- previous.idle)
            let nice = UInt64(current.nice &- previous.nice)
            let total = CGFloat(user + system + idle + nice)
            guard total > 0 else { return nil }
            return (CGFloat(user) / total * 100, CGFloat(system) / total * 100, CGFloat(nice) / total * 100)
        }
    }

    @objc public func graphUpdate(_ timer: Timer?) {
        // System load/uptime are independent of availability of CPU tick records.
        if uptime { setCurrentUptime() }
        if loadAverage {
            let average = getLoadAverage()
            if average >= 0 { currentLoadAverage = average }
        }
        guard let next = source(), !next.isEmpty else {
            countersAvailable = false; slowBaseline = nil; slowTime = nil
            current = Array(repeating: nil, count: numberOfCPUs)
            for data in userValues + systemValues + niceValues { data.setNextValue(XRGGraphRenderer.missingValue) }
            return
        }
        configure(next.count)
        let time = clock()
        let intervalValid = slowTime.map { XRGCPUInterval.isValid(previous: $0, current: time) } ?? false
        let values = usage(next, previous: intervalValid ? slowBaseline : nil)
        slowBaseline = time.isFinite && time >= 0 ? next : nil
        slowTime = slowBaseline == nil ? nil : time
        countersAvailable = values.contains { $0 != nil }
        current = values.map { value in value.map { min(100, max(0, $0.0 + $0.1 + $0.2)) } }
        for (index, value) in values.enumerated() {
            userValues[index].setNextValue(value?.0 ?? XRGGraphRenderer.missingValue)
            systemValues[index].setNextValue(value?.1 ?? XRGGraphRenderer.missingValue)
            niceValues[index].setNextValue(value?.2 ?? XRGGraphRenderer.missingValue)
        }
    }

    @objc public func fastUpdate(_ timer: Timer?) {
        guard let next = source(), !next.isEmpty else {
            fastCountersAvailable = false; fastBaseline = nil; fastTime = nil
            fast = Array(repeating: nil, count: numberOfCPUs)
            return
        }
        configure(next.count)
        let time = clock()
        let intervalValid = fastTime.map { XRGCPUInterval.isValid(previous: $0, current: time) } ?? false
        let values = usage(next, previous: intervalValid ? fastBaseline : nil)
        fastBaseline = time.isFinite && time >= 0 ? next : nil
        fastTime = fastBaseline == nil ? nil : time
        fastCountersAvailable = values.contains { $0 != nil }
        for (index, value) in values.enumerated() {
            guard let value else { fast[index] = nil; continue }
            let total = min(100, max(0, value.0 + value.1 + value.2))
            let previous = CGFloat(fast[index] ?? 0)
            fast[index] = Int(abs(previous - total) < 5 ? total : previous + 0.25 * (total - previous))
        }
    }

    /// Presentation-only: preserve both independent rate baselines, current
    /// readings, smoothing and availability. No hardware read occurs here.
    @objc public func reset() {
        for data in userValues + systemValues + niceValues { data.setAllValues(XRGGraphRenderer.missingValue) }
    }

    public func currentUsage(forCPU index: Int) -> CGFloat? {
        current.indices.contains(index) ? current[index] : nil
    }
    public func fastUsage(forCPU index: Int) -> CGFloat? {
        guard fast.indices.contains(index), let value = fast[index] else { return nil }
        return CGFloat(value)
    }

    @objc public func getNumCPUs() -> Int { numberOfCPUs }
    @objc public func getLoadAverage() -> CGFloat {
        var value = 0.0
        return getloadavg(&value, 1) == 1 ? CGFloat(value) : -1
    }

    @objc public func setCurrentUptime() {
        var boot = timeval()
        var size = MemoryLayout<timeval>.size
        guard sysctlbyname("kern.boottime", &boot, &size, nil, 0) == 0, boot.tv_sec > 0 else { return }
        let seconds = max(0, Int(Date().timeIntervalSince1970) - Int(boot.tv_sec))
        uptimeDays = seconds / 86400
        uptimeHours = seconds / 3600 % 24
        uptimeMinutes = seconds / 60 % 60
        uptimeSeconds = seconds % 60
    }

    @objc public func dataForCPU(_ index: Int) -> [XRGDataSet]? {
        guard systemValues.indices.contains(index) else { return nil }
        return [systemValues[index], userValues[index], niceValues[index]]
    }

    @objc public func combinedData() -> [XRGDataSet]? {
        guard numberOfCPUs > 0 else { return nil }
        return [systemValues, userValues, niceValues].compactMap {
            Self.sumHistories($0, divisor: CGFloat(numberOfCPUs))
        }
    }

    /// Preserve holes through both per-core averaging and stacked layers. Adding
    /// the sentinel numerically would turn an unknown interval into a fake zero.
    static func sumHistories(_ histories: [XRGDataSet], divisor: CGFloat = 1) -> XRGDataSet? {
        guard let first = histories.first, divisor.isFinite, divisor > 0,
              histories.allSatisfy({ $0.numValues == first.numValues }) else { return nil }
        var sums = Array(repeating: CGFloat(0), count: first.numValues)
        var valid = Array(repeating: true, count: first.numValues)
        for history in histories {
            for (index, value) in history.orderedValues.enumerated() {
                if value.isFinite && value >= 0 { sums[index] += value }
                else { valid[index] = false }
            }
        }
        let result = XRGDataSet(); result.resize(first.numValues, fillingWith: XRGGraphRenderer.missingValue)
        for index in sums.indices {
            result.setNextValue(valid[index] ? sums[index] / divisor : XRGGraphRenderer.missingValue)
        }
        return result
    }

    @objc nonisolated public static func systemModelIdentifier() -> String? {
        var size = 0
        guard sysctlbyname("hw.model", nil, &size, nil, 0) == 0, size > 0 else { return nil }
        var bytes = [UInt8](repeating: 0, count: size)
        guard sysctlbyname("hw.model", &bytes, &size, nil, 0) == 0 else { return nil }
        return String(decoding: bytes.prefix(while: { $0 != 0 }), as: UTF8.self)
    }

    nonisolated public static func readTicks() -> [XRGCPUTicks]? {
        let host = mach_host_self()
        defer { mach_port_deallocate(mach_task_self_, host) }
        var processors: natural_t = 0
        var count: mach_msg_type_number_t = 0
        var buffer: processor_info_array_t?
        guard host_processor_info(host, PROCESSOR_CPU_LOAD_INFO, &processors, &buffer, &count) == KERN_SUCCESS,
              let buffer else { return nil }
        defer {
            vm_deallocate(mach_task_self_, vm_address_t(UInt(bitPattern: buffer)),
                          vm_size_t(count) * vm_size_t(MemoryLayout<integer_t>.stride))
        }
        let stride = Int(CPU_STATE_MAX)
        guard Int(count) >= Int(processors) * stride else { return nil }
        return (0..<Int(processors)).map { index in
            let base = index * stride
            return XRGCPUTicks(user: UInt32(bitPattern: buffer[base + Int(CPU_STATE_USER)]),
                               system: UInt32(bitPattern: buffer[base + Int(CPU_STATE_SYSTEM)]),
                               idle: UInt32(bitPattern: buffer[base + Int(CPU_STATE_IDLE)]),
                               nice: UInt32(bitPattern: buffer[base + Int(CPU_STATE_NICE)]))
        }
    }
}
