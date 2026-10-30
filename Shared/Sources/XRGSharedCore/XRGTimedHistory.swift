// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Stephen de la Vega.
import Foundation

/// Bounded observations, projected into time bins ending at the latest completed
/// observation. Projection never invents timestamps for index-only history.
/// Instances are confined to their owner thread, like XRGDataSet.
public final class XRGTimedHistory {
    public static let maximumMinutes = 1_440
    public static let binSeconds = 5
    public static let maximumObservations = 20_000
    public static let maximumChannels = 6
    public static let systemMaximumMinutes = 60
    public static let minimumInterval = 0.2
    public static let maximumPositions = 20_000
    public static let windowPresets = [0, 10, 30, 60, 360, 1_440]
    public static func validMinutes(_ minutes: Int) -> Bool { (0...maximumMinutes).contains(minutes) }
    public static func binCount(minutes: Int, interval: Double = Double(binSeconds)) -> Int? {
        guard (1...maximumMinutes).contains(minutes), interval.isFinite, interval >= minimumInterval else { return nil }
        return Int(min(Double(maximumPositions - 1), max(1, (Double(minutes * 60) / interval).rounded(.up)))) + 1
    }
    public let channels: Int
    public let retentionMinutes: Int
    public private(set) var revision: UInt64 = 0
    private struct Observation { let time: Double; let values: [Double] }
    private var observations: [Observation] = []
    private var head = 0
    public var observationCount: Int { observations.count - head }
    public var latestTime: Double? { observations.last?.time }
    public init?(channels: Int, retentionMinutes: Int = maximumMinutes) {
        guard (1...Self.maximumChannels).contains(channels), (1...Self.maximumMinutes).contains(retentionMinutes) else { return nil }
        self.channels = channels; self.retentionMinutes = retentionMinutes
    }
    public func clear() {
        observations.removeAll(keepingCapacity: true); head = 0; revision &+= 1
    }
    @discardableResult public func append(time: Double, values: [Double]) -> Bool {
        guard time.isFinite, time >= 0, values.count == channels,
              values.allSatisfy({ $0.isNaN || ($0.isFinite && $0 >= 0) }) else { return false }
        if let previous = latestTime, time < previous { clear() }
        let observation = Observation(time: time, values: values)
        if latestTime == time { observations[observations.count - 1] = observation }
        else { observations.append(observation) }
        let cutoff = time - Double(retentionMinutes * 60)
        while head < observations.count && (observations[head].time < cutoff || observationCount > Self.maximumObservations) { head += 1 }
        if head > 1_024 && head >= observations.count / 2 { observations.removeFirst(head); head = 0 }
        revision &+= 1
        return true
    }
    /// Latest observation wins within each bin (five seconds by default). Unobserved bins and
    /// explicit unavailable values remain NaN. Bins are centered on grid positions
    /// so ordinary cadence jitter does not invent gaps. No interpolation/zero fill.
    public func values(minutes: Int, interval: Double = Double(binSeconds)) -> [[Double]]? {
        guard minutes <= retentionMinutes, let count = Self.binCount(minutes: minutes, interval: interval) else { return nil }
        var result = Array(repeating: Array(repeating: Double.nan, count: count), count: channels)
        guard let end = latestTime else { return result }
        let duration = Double(minutes * 60)
        let spacing = duration / Double(count - 1)
        for observation in observations.dropFirst(head) {
            let age = end - observation.time
            guard age >= 0, age <= duration else { continue }
            let slot = count - 1 - min(count - 1, Int((age / spacing).rounded()))
            for channel in 0..<channels { result[channel][slot] = observation.values[channel] }
        }
        return result
    }
}
