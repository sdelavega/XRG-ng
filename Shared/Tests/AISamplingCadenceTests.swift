// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Stephen de la Vega.
import Testing
@testable import XRGSharedCore
struct AISamplingCadenceTests {
    @Test func redrawsDoNotCreateSamplesAndDelaysDoNotCreateCatchupBursts() {
        var cadence=XRGAISamplingCadence()
        func begin(_ time: Double)->Bool { cadence.begin(at:time) }
        #expect(XRGAISamplingCadence.seconds == 5 && aiSamplingMilliseconds() == 5000)
        #expect(begin(0))
        for tick in 1..<50 { #expect(!begin(Double(tick)/10)) }
        #expect(begin(5))
        #expect(!begin(5))
        #expect(begin(120))
        #expect(!begin(120) && !begin(124.999))
        #expect(begin(125))
    }
    @Test func resetIsImmediateAndInvalidOrRegressedClocksCannotSample() {
        var cadence=XRGAISamplingCadence()
        func begin(_ time: Double)->Bool { cadence.begin(at:time) }
        for value in [Double.nan, .infinity, -1] { #expect(!begin(value)) }
        #expect(begin(10))
        #expect(!begin(9))
        cadence.reset()
        #expect(begin(11))
        #expect(!begin(12))
    }
}
