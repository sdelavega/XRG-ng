// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Stephen de la Vega.
import Testing
@testable import XRGSharedCore

struct CPUIntervalTests {
    @Test func sharedAndCABIRejectUnusableIntervalsAtTheSameBoundary() {
        for (previous, current, expected) in [
            (0.0, 0.001, true), (1, 301, true), (1, 301.001, false),
            (1, 1, false), (2, 1, false), (-1, 1, false),
            (Double.nan, 1, false), (0, Double.nan, false),
            (Double.infinity, 1, false), (0, Double.infinity, false)
        ] {
            #expect(XRGCPUInterval.isValid(previous: previous, current: current) == expected)
            #expect(cpuIntervalValid(previous, current) == (expected ? 1 : 0))
        }
    }
}
