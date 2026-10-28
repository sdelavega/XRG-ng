// Copyright (C) 2026 Stephen de la Vega.
// SPDX-License-Identifier: GPL-3.0-or-later
import Foundation
import Darwin

struct XRGNPUClusterResidency: Sendable {
    let id: String
    let states: [String: UInt64]

    var activeFraction: Double? {
        // ACT is a software power-state residency, not arithmetic occupancy.
        let inactive: Set<String> = ["IDLE", "OFF", "DOWN", "SLEEP", "RET"]
        guard let active = states["ACT"], states.count >= 2, states.count <= 64,
              states.keys.allSatisfy({ $0 == "ACT" || inactive.contains($0) }),
              states.values.allSatisfy({ $0 <= UInt64(Int64.max) }) else { return nil }
        let total = states.values.reduce(0.0) { $0 + Double($1) }
        guard total.isFinite, total > 0 else { return nil }
        return Double(active) / total
    }
}

struct XRGNPUActivityInterval: Sendable {
    let start: TimeInterval
    let end: TimeInterval
    let clusters: [XRGNPUClusterResidency]

    var activeFraction: Double? {
        guard start.isFinite, end.isFinite, start >= 0, end > start, end - start <= 300,
              !clusters.isEmpty, clusters.count <= 16,
              Set(clusters.map(\.id)).count == clusters.count else { return nil }
        let values = clusters.compactMap(\.activeFraction)
        guard values.count == clusters.count else { return nil }
        // Different ANE clusters can overlap. Report the busiest, never sum them.
        return values.max()
    }
}

/// Serial-worker-only, optional private IOReport subscription. Kept independent
/// of energy acquisition so a missing power rail cannot hide active residency.
final class XRGNPUActivityReader {
    private final class API {
        typealias Copy = @convention(c) (CFString?, CFString?, UInt64, UInt64, UInt64) -> Unmanaged<CFMutableDictionary>?
        typealias Subscribe = @convention(c) (CFAllocator?, CFMutableDictionary, UnsafeMutablePointer<Unmanaged<CFMutableDictionary>?>?, UInt64, UnsafeMutableRawPointer?) -> Unmanaged<CFTypeRef>?
        typealias Sample = @convention(c) (CFTypeRef, CFMutableDictionary, UnsafeMutableRawPointer?) -> Unmanaged<CFDictionary>?
        typealias Delta = @convention(c) (CFDictionary, CFDictionary, UnsafeMutableRawPointer?) -> Unmanaged<CFDictionary>?
        typealias Label = @convention(c) (CFDictionary) -> Unmanaged<CFString>?
        typealias Count = @convention(c) (CFDictionary) -> Int32
        typealias StateName = @convention(c) (CFDictionary, Int32) -> Unmanaged<CFString>?
        typealias Residency = @convention(c) (CFDictionary, Int32) -> UInt64
        let handle: UnsafeMutableRawPointer
        let copy: Copy, subscribe: Subscribe, sample: Sample, delta: Delta, name: Label
        let format: Count, count: Count, stateName: StateName, residency: Residency
        init?() {
            guard let handle = dlopen("/usr/lib/libIOReport.dylib", RTLD_LAZY | RTLD_LOCAL) else { return nil }
            func load<T>(_ name: String, _: T.Type) -> T? { dlsym(handle, name).map { unsafeBitCast($0, to: T.self) } }
            guard let copy = load("IOReportCopyChannelsInGroup", Copy.self),
                  let subscribe = load("IOReportCreateSubscription", Subscribe.self),
                  let sample = load("IOReportCreateSamples", Sample.self),
                  let delta = load("IOReportCreateSamplesDelta", Delta.self),
                  let name = load("IOReportChannelGetChannelName", Label.self),
                  let format = load("IOReportChannelGetFormat", Count.self),
                  let count = load("IOReportStateGetCount", Count.self),
                  let stateName = load("IOReportStateGetNameForIndex", StateName.self),
                  let residency = load("IOReportStateGetResidency", Residency.self) else { dlclose(handle); return nil }
            self.handle = handle; self.copy = copy; self.subscribe = subscribe; self.sample = sample
            self.delta = delta; self.name = name; self.format = format; self.count = count
            self.stateName = stateName; self.residency = residency
        }
        deinit { dlclose(handle) }
    }
    private var api: API?
    private var subscription: CFTypeRef?
    private var channels: CFMutableDictionary?
    private var previous: (sample: CFDictionary, time: TimeInterval, states: [XRGNPUClusterResidency])?
    private var nextAttempt: TimeInterval = 0
    private var deviceIDs: [UInt64] = []
    deinit { previous = nil; subscription = nil; channels = nil; api = nil }

    static func isClusterChannel(_ name: String) -> Bool {
        name.range(of: "^(?:(?:DIE[0-9]+[ _]|DIE_[0-9]+_))?ANE(?:[0-9]+(?:_[0-9]+)?)?$",
                   options: .regularExpression) != nil
    }
    private func entries(_ dictionary: CFDictionary) -> [NSDictionary]? {
        guard let rows = (dictionary as NSDictionary)["IOReportChannels"] as? [NSDictionary], rows.count <= 1024 else { return nil }
        return rows
    }
    private func connect(_ now: TimeInterval) -> Bool {
        guard now >= nextAttempt else { return false }
        nextAttempt = now + 30
        guard let api = API(), let all = api.copy("SoC Stats" as CFString, "Cluster Power States" as CFString, 0, 0, 0)?.takeRetainedValue(),
              let rows = entries(all) else { return false }
        let selected = rows.filter {
            api.format($0 as CFDictionary) == 2 && Self.isClusterChannel(api.name($0 as CFDictionary)?.takeUnretainedValue() as String? ?? "")
        }
        guard !selected.isEmpty, selected.count <= 16 else { return false }
        let chosen = (all as NSDictionary).mutableCopy() as! NSMutableDictionary
        chosen["IOReportChannels"] = selected
        var actual: Unmanaged<CFMutableDictionary>?
        guard let sub = api.subscribe(nil, chosen as CFMutableDictionary, &actual, 0, nil)?.takeRetainedValue() else { return false }
        self.api = api; subscription = sub; channels = actual?.takeRetainedValue() ?? chosen as CFMutableDictionary
        return true
    }
    private func clusters(_ sample: CFDictionary, api: API) -> [XRGNPUClusterResidency]? {
        guard let rows = entries(sample), !rows.isEmpty, rows.count <= 16 else { return nil }
        var result: [XRGNPUClusterResidency] = [], ids = Set<String>()
        for row in rows {
            let d = row as CFDictionary
            let name = api.name(d)?.takeUnretainedValue() as String? ?? ""
            guard Self.isClusterChannel(name), api.format(d) == 2,
                  let driver = row["DriverID"] as? NSNumber, CFGetTypeID(driver) != CFBooleanGetTypeID(),
                  (2...64).contains(api.count(d)) else { return nil }
            let id = "\(driver.stringValue):\(name)"
            guard ids.insert(id).inserted else { return nil }
            var states: [String: UInt64] = [:]
            for index in 0..<api.count(d) {
                guard let key = api.stateName(d, index)?.takeUnretainedValue() as String?, states[key] == nil else { return nil }
                let value = api.residency(d, index)
                guard value <= UInt64(Int64.max) else { return nil }
                states[key] = value
            }
            result.append(.init(id: id, states: states))
        }
        return result
    }
    func sample(deviceIDs: [UInt64]) -> XRGNPUActivityInterval? {
        let ids = deviceIDs.sorted(), now = ProcessInfo.processInfo.systemUptime
        if ids != self.deviceIDs {
            previous = nil; subscription = nil; channels = nil; nextAttempt = 0; self.deviceIDs = ids
        }
        guard !ids.isEmpty, subscription != nil || connect(now), let api, let subscription, let channels,
              let current = api.sample(subscription, channels, nil)?.takeRetainedValue(),
              let raw = clusters(current, api: api) else {
            previous = nil; self.subscription = nil; self.channels = nil; return nil
        }
        let end = ProcessInfo.processInfo.systemUptime, before = previous
        previous = (current, end, raw)
        guard let before, end > before.time, end - before.time <= 300,
              Set(before.states.map(\.id)) == Set(raw.map(\.id)) else { return nil }
        let old = Dictionary(uniqueKeysWithValues: before.states.map { ($0.id, $0.states) })
        // Catch reset/wrap before asking IOReport to reduce the state samples.
        guard raw.allSatisfy({ cluster in
            guard let old = old[cluster.id], Set(old.keys) == Set(cluster.states.keys) else { return false }
            return cluster.states.allSatisfy { $0.value >= old[$0.key]! }
        }), let delta = api.delta(before.sample, current, nil)?.takeRetainedValue(),
            let values = clusters(delta, api: api) else { return nil }
        let interval = XRGNPUActivityInterval(start: before.time, end: end, clusters: values)
        return interval.activeFraction == nil ? nil : interval
    }
}
