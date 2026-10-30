// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Stephen de la Vega.

/// CPU percentages require two observations on one monotonic clock. Long
/// pauses are boundaries, rather than a misleading average across the pause.
public enum XRGCPUInterval {
    public static let maximumSeconds: Double = 300
    public static func isValid(previous: Double, current: Double) -> Bool {
        previous.isFinite && current.isFinite && previous >= 0 && current > previous
            && current - previous <= maximumSeconds
    }
}
