// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Stephen de la Vega.

import Foundation
import Testing
@testable import XRGCore

struct XRGIOCounterTrackerTests {
    private func counters(_ a: UInt64, _ b: UInt64 = 0) -> [Int: XRGIOCounters] {
        [1: XRGIOCounters(first: a, second: b)]
    }

    @Test func wakeSuppressesOnlyRatesAndRetainsEveryValidObservedByte() throws {
        var tracker = XRGIOCounterTracker<Int>()
        _ = tracker.sample(counters(100, 200), at: 0)
        _ = tracker.sample(counters(700, 400), at: 1)
        tracker.invalidateRateInterval(); tracker.invalidateRateInterval()
        #expect(!tracker.available && tracker.total == 800 && !tracker.lowerBound)
        let wakeReading = tracker.sample(counters(10_700, 2_400), at: 2)
        let wake = try #require(wakeReading)
        #expect(!wake.ratesAvailable && wake.firstRate == 0 && !wake.newSession)
        #expect(tracker.total == 12_800 && !tracker.available && !tracker.lowerBound)
        #expect(tracker.details(firstLabel: "RX", secondLabel: "TX").contains("valid observed counter deltas"))
        let freshReading = tracker.sample(counters(11_300, 2_600), at: 3)
        let fresh = try #require(freshReading)
        #expect(fresh.ratesAvailable && fresh.firstRate == 600 && fresh.secondRate == 200 && tracker.available)
        #expect(tracker.total == 13_600)
    }
    @Test func wakeRetainsResetFailureAndRestartAccountingBoundaries() throws {
        var tracker = XRGIOCounterTracker<Int>()
        _ = tracker.sample(counters(100), at: 0); _ = tracker.sample(counters(200), at: 1)
        tracker.resetTransfers(); tracker.invalidateRateInterval()
        #expect(tracker.sample(counters(900), at: 2)?.ratesAvailable == false && tracker.total == 0)
        _ = tracker.sample(counters(1000), at: 3); #expect(tracker.total == 100)
        tracker.invalidateRateInterval(); tracker.fail()
        #expect(tracker.sample(counters(2000), at: 4)?.ratesAvailable == false && tracker.total == 100 && tracker.partial)
        _ = tracker.sample(counters(2100), at: 5); #expect(tracker.total == 200 && tracker.partial)
        tracker.invalidateRateInterval()
        let restartReading = tracker.sample(counters(10), at: 6)
        let restart = try #require(restartReading)
        #expect(restart.newSession && !restart.ratesAvailable && tracker.total == 0 && !tracker.partial)
        _ = tracker.sample(counters(30), at: 7); #expect(tracker.total == 20 && tracker.available)
    }

    @Test func resetExcludesTheStraddlingIntervalWithoutChangingRates() throws {
        var tracker = XRGIOCounterTracker<Int>()
        _ = tracker.sample(counters(100, 200), at: 0)
        _ = tracker.sample(counters(700, 400), at: 2)
        #expect(tracker.first == 600 && tracker.second == 200)
        tracker.resetTransfers()
        let sample = tracker.sample(counters(1300, 600), at: 4)
        let reading = try #require(sample)
        #expect(reading.firstRate == 300 && reading.secondRate == 100 && !reading.newSession)
        #expect(tracker.total == 0 && tracker.started == 4)
        _ = tracker.sample(counters(1900, 800), at: 6)
        #expect(tracker.first == 600 && tracker.second == 200 && !tracker.lowerBound)
    }

    @Test func failedIntervalsRemainExcludedAndPartialUntilExplicitReset() {
        var tracker = XRGIOCounterTracker<Int>()
        _ = tracker.sample(counters(100), at: 0)
        _ = tracker.sample(counters(200), at: 1)
        tracker.fail()
        #expect(tracker.total == 100 && tracker.partial && !tracker.available)
        let recovered = tracker.sample(counters(900), at: 4)
        #expect(recovered?.firstRate == 0 && tracker.total == 100 && tracker.partial)
        _ = tracker.sample(counters(1000), at: 5)
        #expect(tracker.total == 200 && tracker.partial && tracker.available)
        tracker.resetTransfers()
        tracker.fail()
        _ = tracker.sample(counters(1100), at: 6)
        #expect(tracker.total == 0 && !tracker.lowerBound)
    }

    @Test(arguments: [Double.nan, .infinity, -.infinity, 0, -1])
    func invalidTimeBreaksContinuityWithoutImportingBytes(time: Double) {
        var tracker = XRGIOCounterTracker<Int>()
        _ = tracker.sample(counters(100), at: 0)
        #expect(tracker.sample(counters(200), at: time) == nil)
        #expect(tracker.partial && !tracker.available)
        #expect(tracker.sample(counters(900), at: 2)?.firstRate == 0)
        #expect(tracker.total == 0 && tracker.partial)
    }

    @Test func pathologicalRateDoesNotCountAnInvalidInterval() {
        var tracker = XRGIOCounterTracker<Int>()
        _ = tracker.sample(counters(0), at: 0)
        #expect(tracker.sample(counters(.max), at: .leastNonzeroMagnitude) == nil)
        #expect(tracker.total == 0 && tracker.partial)
    }

    @Test func membershipIdentityAndOneWayCounterRestartBeginNewSessions() {
        var tracker = XRGIOCounterTracker<Int>()
        _ = tracker.sample(counters(100, 500), at: 0)
        _ = tracker.sample(counters(200, 600), at: 1)
        #expect(tracker.total == 200)
        #expect(tracker.sample(counters(0, 700), at: 2)?.newSession == true)
        #expect(tracker.total == 0)
        _ = tracker.sample(counters(50, 800), at: 3)
        #expect(tracker.total == 150)
        let replaced = [2: XRGIOCounters(first: 50, second: 800)]
        #expect(tracker.sample(replaced, at: 4)?.newSession == true)
        #expect(tracker.total == 0)
        #expect(tracker.sample([:], at: 5)?.newSession == true)
        #expect(tracker.sample(replaced, at: 6)?.firstRate == 0)
    }

    @Test func counterRestartRemainsDetectableAfterAReadGap() {
        var tracker = XRGIOCounterTracker<Int>()
        _ = tracker.sample(counters(100, 200), at: 0)
        _ = tracker.sample(counters(300, 400), at: 1)
        tracker.fail()
        let recovered = tracker.sample(counters(10, 500), at: 4)
        #expect(recovered?.newSession == true && recovered?.secondRate == 0)
        #expect(tracker.total == 0 && !tracker.lowerBound)
        _ = tracker.sample(counters(30, 600), at: 5)
        #expect(tracker.first == 20 && tracker.second == 100)
    }

    @Test func directionalAndCombinedOverflowAreExplicitLowerBounds() {
        var tracker = XRGIOCounterTracker<Int>()
        _ = tracker.sample(counters(0, 0), at: 0)
        _ = tracker.sample(counters(.max, 1), at: 1)
        #expect(tracker.first == .max && tracker.second == 1 && tracker.total == .max && tracker.saturated)
        tracker.resetTransfers()
        #expect(!tracker.saturated)
        let zero = XRGIOCounters(first: 0, second: 0)
        let large = XRGIOCounters(first: .max, second: 0)
        _ = tracker.sample([1: zero, 2: zero], at: 2)
        let reading = tracker.sample([1: large, 2: large], at: 3)
        #expect(reading?.firstRate.isFinite == true && tracker.first == .max && tracker.saturated)
    }
}
