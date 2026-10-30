// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Stephen de la Vega.
import Testing
@testable import XRGSharedCore

struct SamplingSettingsTests {
    @Test func fractionalEditsRemainPreciseAndLegacyValuesAreNotSilentlyLimited() {
        for (input, output) in [(0.375, 0.375), (0.3101, 0.31), (0.01, 0.2), (3600, 3600)] {
            #expect(XRGSamplingSettings.editedSeconds(input) == output)
        }
        for input in [0.0, -1, Double.nan, .infinity, .greatestFiniteMagnitude] {
            #expect(XRGSamplingSettings.editedSeconds(input) == nil)
        }
        #expect(XRGSamplingSettings.nominalSpan(samples: 120, interval: 0.375) == 44.625)
        #expect(XRGSamplingSettings.nominalSpan(samples: 0, interval: 1) == nil)
        #expect(XRGSamplingSettings.nominalSpan(samples: 120, interval: .nan) == nil)
    }
    @Test func metadataAndResizeABIHaveTransactionalBoundsAndRetainNewestSamples() {
        var metadata: [UInt32] = [99, 99, 99, 99]
        #expect(samplingSettings(&metadata, 3) == -1 && metadata == [99, 99, 99, 99])
        #expect(samplingSettings(&metadata, 4) == 4 && metadata == [200, 10000, 1000, 20000])
        #expect(XRGSamplingSettings.validCPUHistorySamples(0))
        #expect(!XRGSamplingSettings.validCPUHistorySamples(-1) && !XRGSamplingSettings.validCPUHistorySamples(20001))
        let handle = historyCreate(3)!
        defer { historyFree(handle) }
        for value in [1.0, 2, 3, 4] { #expect(historyAppend(handle, value) == 0) }
        #expect(historyResize(handle, 5) == 0)
        var values = [Double](repeating: 99, count: 5)
        #expect(historyCopy(handle, &values, 5) == 5 && values == [0, 0, 2, 3, 4])
        #expect(historyResize(handle, 0) == -1 && historyResize(handle, 86401) == -1)
        #expect(historyResize(handle, 2) == 0)
        #expect(historyCopy(handle, &values, 5) == 2 && Array(values.prefix(2)) == [3, 4])
    }
}
