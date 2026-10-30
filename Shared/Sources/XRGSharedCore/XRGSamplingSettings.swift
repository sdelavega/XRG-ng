// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Stephen de la Vega.

/// Common interactive range. Existing valid Mac preferences outside this range
/// remain readable; changing a control uses millisecond precision.
public enum XRGSamplingSettings {
    public static let minimumMilliseconds: UInt32 = 200
    public static let maximumMilliseconds: UInt32 = 10_000
    public static let defaultMilliseconds: UInt32 = 1_000
    public static let maximumCPUHistorySamples = 20_000
    public static let cpuHistoryPresets = [0, 120, 300, 600, 1_800, 3_600]
    public static func validCPUHistorySamples(_ count: Int) -> Bool {
        (0...maximumCPUHistorySamples).contains(count)
    }
    public static func editedSeconds(_ seconds: Double) -> Double? {
        guard seconds.isFinite, seconds > 0 else { return nil }
        let milliseconds = (seconds * 1_000).rounded()
        guard milliseconds.isFinite else { return nil }
        return max(Double(minimumMilliseconds), milliseconds) / 1_000
    }
    /// Capacity-based estimate, not a measured time axis. Cadence changes and
    /// delayed observations mean older samples may have different spacing.
    public static func nominalSpan(samples: Int, interval: Double) -> Double? {
        guard samples > 0, interval.isFinite, interval > 0 else { return nil }
        let span = Double(samples - 1) * interval
        return span.isFinite ? span : nil
    }
}
