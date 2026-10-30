// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Stephen de la Vega.
import Foundation
import Testing
@testable import XRGSharedCore
struct LogContinuityTests {
    @Test func commonInventoryCorpusPreservesAppendAndRejectsSourceBoundaries() throws {
        struct Case: Decodable {
            let name: String; let previous: [String:XRGLogFileState]
            let next: [String:XRGLogFileState]; let continues: Bool
        }
        let url = try #require(Bundle.module.url(forResource:"log-continuity-cases",withExtension:"json",subdirectory:"Fixtures"))
        for test in try JSONDecoder().decode([Case].self,from:Data(contentsOf:url)) {
            #expect(XRGLogFileState.inventoryContinues(test.previous,test.next) == test.continues, "\(test.name)")
        }
    }
    @Test func sourceRateResetPreservesOtherProvidersAndCostResetIsIndependent() {
        let tracker=XRGRateTracker()
        _ = tracker.sample(counter:100,key:"a",time:1)
        _ = tracker.sample(counter:100,key:"b",time:1)
        _ = tracker.sampleCost(10,time:1)
        tracker.reset(key:"a")
        #expect(tracker.sample(counter:10000,key:"a",time:2).delta == 0)
        #expect(tracker.sample(counter:120,key:"b",time:2).delta == 20)
        #expect(tracker.sampleCost(12,time:2) == 2)
        tracker.resetCost()
        #expect(tracker.sampleCost(1000,time:3) == 0)
        #expect(tracker.sample(counter:130,key:"b",time:3).delta == 10)
    }
}
