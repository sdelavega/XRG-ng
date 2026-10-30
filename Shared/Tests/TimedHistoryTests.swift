// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Stephen de la Vega.
import Testing
@testable import XRGSharedCore
struct TimedHistoryTests {
    @Test func signedQuantitiesAreExplicitAndKeepOldValidationAndGapRules() throws {
        let unsigned = try #require(XRGTimedHistory(channels: 1, retentionMinutes: 60))
        #expect(!unsigned.append(time: 100, values: [-10]) && unsigned.observationCount == 0)
        let signed = try #require(XRGTimedHistory(channels: 1, retentionMinutes: 60, allowsNegativeValues: true))
        #expect(signed.append(time: 100, values: [-10]))
        #expect(signed.append(time: 110, values: [0]))
        let values = try #require(signed.values(minutes: 1, interval: 1))
        #expect(values[0][50] == -10 && values[0][60] == 0)
        #expect(values[0][51..<60].allSatisfy { $0.isNaN })
        #expect(!signed.append(time: 111, values: [.infinity]))
        #expect(!signed.append(time: -1, values: [-10]))
    }

    @Test func exactCutoffSparseBinsAndLatestValueAreBasedOnTimestamps() throws {
        let history = try #require(XRGTimedHistory(channels: 1))
        history.append(time: 0, values: [10]); history.append(time: 5, values: [20]); history.append(time: 65, values: [30])
        var values = try #require(history.values(minutes: 1))[0]
        #expect(values.count == 13 && values[0] == 20 && values[12] == 30)
        #expect(values[1..<12].allSatisfy { $0.isNaN })
        history.append(time: 66, values: [40]); values = try #require(history.values(minutes: 1))[0]
        #expect(values.dropLast().allSatisfy { $0.isNaN } && values.last == 40)
        let revision = history.revision
        _ = history.values(minutes: 60); #expect(history.revision == revision && history.observationCount == 4)
    }
    @Test func duplicatesMissingChannelsInvalidInputsAndClockRollbackStaySafe() throws {
        let history = try #require(XRGTimedHistory(channels: 2))
        history.append(time: 100, values: [0, .nan]); history.append(time: 100, values: [2, 0])
        #expect(history.observationCount == 1 && history.values(minutes: 1)?.map { $0.last! } == [2, 0])
        let revision = history.revision
        for time in [Double.nan, .infinity, -1] { #expect(!history.append(time: time, values: [1, 2])) }
        #expect(!history.append(time: 101, values: [-1, 2]) && !history.append(time: 101, values: [1, .infinity]))
        #expect(!history.append(time: 101, values: [1]) && history.revision == revision)
        history.append(time: 10, values: [0, .nan])
        #expect(history.observationCount == 1 && history.latestTime == 10)
        let values = try #require(history.values(minutes: 1))
        #expect(values[0].last == 0 && values[0].dropLast().allSatisfy { $0.isNaN } && values[1].allSatisfy { $0.isNaN })
    }
    @Test func retainedAgeAndDensityAreBoundedWithoutChangingProjection() throws {
        let history = try #require(XRGTimedHistory(channels: 1))
        history.append(time: 0, values: [1]); history.append(time: 86_400, values: [2])
        #expect(history.observationCount == 2)
        history.append(time: 86_401, values: [3]); #expect(history.observationCount == 2)
        history.clear()
        for i in 0..<20_003 { history.append(time: Double(i) / 10, values: [Double(i)]) }
        #expect(history.observationCount == XRGTimedHistory.maximumObservations)
        #expect(history.values(minutes: 1)?.first?.last == 20_002)
    }
    @Test func limitsAndEmptyClearedWindowsNeverInventObservations() throws {
        #expect(XRGTimedHistory(channels: 0) == nil && XRGTimedHistory(channels: 7) == nil)
        #expect(XRGTimedHistory.binCount(minutes: 1) == 13 && XRGTimedHistory.binCount(minutes: 1440) == 17_281)
        let history = try #require(XRGTimedHistory(channels: 6))
        #expect(history.values(minutes: 0) == nil && history.values(minutes: 1441) == nil)
        #expect(history.values(minutes: 1)!.allSatisfy { $0.allSatisfy { $0.isNaN } })
        history.append(time: 1, values: Array(repeating: 0, count: 6)); history.clear()
        #expect(history.latestTime == nil && history.observationCount == 0)
        #expect(history.values(minutes: 1)!.allSatisfy { $0.allSatisfy { $0.isNaN } })
    }
    @Test func systemProjectionFollowsCadenceAndKeepsOriginalTimestamps() throws {
        #expect(XRGTimedHistory.binCount(minutes:1,interval:1)==61)
        #expect(XRGTimedHistory.binCount(minutes:1,interval:0.2)==301)
        #expect(XRGTimedHistory.binCount(minutes:1,interval:0.375)==161)
        #expect(XRGTimedHistory.binCount(minutes:60,interval:0.2)==18001)
        #expect(XRGTimedHistory.binCount(minutes:1440,interval:0.2)==20000)
        #expect(XRGTimedHistory.binCount(minutes:1,interval:0.1)==nil && XRGTimedHistory.binCount(minutes:1,interval:.nan)==nil)
        let history=try #require(XRGTimedHistory(channels:1,retentionMinutes:60))
        history.append(time:100,values:[10]);history.append(time:101.001,values:[20]);history.append(time:102,values:[30])
        let revision=history.revision, values=try #require(history.values(minutes:1,interval:1))[0]
        #expect(Array(values.suffix(3))==[10,20,30])
        #expect(history.values(minutes:1,interval:0.2)![0].count==301 && history.revision==revision)
        #expect(history.values(minutes:61)==nil)
    }
    @Test func limitedRetainedAgeAndCenteredBinsKeepRealZeroAndUnavailableDistinct() throws {
        let history=try #require(XRGTimedHistory(channels:2,retentionMinutes:60))
        history.append(time:0,values:[0,.nan]);history.append(time:3600,values:[1,2])
        #expect(history.observationCount==2)
        #expect(history.values(minutes:60,interval:1)![0].first==0)
        history.append(time:3601,values:[3,4]);#expect(history.observationCount==2)
        #expect(XRGTimedHistory(channels:1,retentionMinutes:0)==nil)
    }

}
