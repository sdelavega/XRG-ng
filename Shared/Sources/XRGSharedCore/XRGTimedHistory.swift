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
    public static let windowPresets = [0, 10, 30, 60, 360, 1_440]
    public static func validMinutes(_ minutes: Int) -> Bool { (0...maximumMinutes).contains(minutes) }
    public static func binCount(minutes: Int) -> Int? {
        guard (1...maximumMinutes).contains(minutes) else { return nil }
        return minutes * 60 / binSeconds + 1
    }
    public let channels: Int
    public private(set) var revision: UInt64 = 0
    private struct Observation { let time: Double; let values: [Double] }
    private var observations: [Observation] = []
    private var head = 0
    public var observationCount: Int { observations.count - head }
    public var latestTime: Double? { observations.last?.time }
    public init?(channels: Int) {
        guard (1...Self.maximumChannels).contains(channels) else { return nil }
        self.channels = channels
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
        let cutoff = time - Double(Self.maximumMinutes * 60)
        while head < observations.count && (observations[head].time < cutoff || observationCount > Self.maximumObservations) { head += 1 }
        if head > 1_024 && head >= observations.count / 2 { observations.removeFirst(head); head = 0 }
        revision &+= 1
        return true
    }
    /// Latest observation wins within each five-second bin. Unobserved bins and
    /// explicit unavailable values remain NaN. No interpolation or zero fill.
    public func values(minutes: Int) -> [[Double]]? {
        guard let count = Self.binCount(minutes: minutes) else { return nil }
        var result = Array(repeating: Array(repeating: Double.nan, count: count), count: channels)
        guard let end = latestTime else { return result }
        let duration = Double(minutes * 60)
        for observation in observations.dropFirst(head) {
            let age = end - observation.time
            guard age >= 0, age <= duration else { continue }
            let slot = count - 1 - Int((age / Double(Self.binSeconds)).rounded(.down))
            for channel in 0..<channels { result[channel][slot] = observation.values[channel] }
        }
        return result
    }
}
