// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Stephen de la Vega.

/// Nominal AI collection interval, separate from graph paint/system sampling.
/// Delays coalesce to one observation; no backlog of synthetic samples is added.
public struct XRGAISamplingCadence: Sendable {
    public static let milliseconds: UInt64 = 5_000
    public static let seconds = Double(milliseconds) / 1_000
    private var last: Double?
    public init() {}
    public mutating func reset() { last = nil }
    public mutating func begin(at time: Double) -> Bool {
        guard time.isFinite, time >= 0 else { return false }
        if let last, time < last || time - last < Self.seconds { return false }
        last = time
        return true
    }
}
