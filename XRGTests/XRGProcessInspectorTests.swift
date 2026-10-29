// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Stephen de la Vega.
import AppKit
import Testing
@testable import XRGCore

@Suite(.serialized) @MainActor
struct XRGProcessInspectorTests {
    @Test func filteringSortingLimitsAndMemoryUnits() {
        let records = XRGProcessMiner.parse("10 1 2048 9000 - alice Zebra\n80 2 1024 8000 - bob Alpha\n80 3 4096 7000 - alice Beta")
        var options = XRGProcessOptions()
        #expect(options.ranked(records).map(\.pid) == [2, 3, 1])
        options.sort = .memory; #expect(options.ranked(records).map(\.pid) == [3, 1, 2])
        options.sort = .name; #expect(options.ranked(records).map(\.pid) == [2, 3, 1])
        options.user = "alice"; options.search = "beTA"
        #expect(options.ranked(records).map(\.pid) == [3])
        options.search = "1"; #expect(options.ranked(records).map(\.pid) == [1])
        options.limit = 0; #expect(!options.valid && options.ranked(records).count == 1)
        #expect(XRGProcessInspector.memory(2048) == "2.0 MiB")
        #expect(XRGProcessInspector.memory(UInt64.max).contains("MiB"))
    }
    @Test func failedRefreshIsExplicitAndDetailSnapshotDoesNotFollowReusedPIDs() async throws {
        let fixture = InspectorFixture()
        let miner = XRGProcessMiner(source: { fixture.next() })
        await miner.refresh()
        let first = try #require(miner.records.first)
        let captured = XRGProcessInspector.detailText(first, sampledAt: miner.sampledAt)
        #expect(miner.sampledAt != nil && !miner.refreshFailed)
        await miner.refresh()
        #expect(miner.refreshFailed && miner.records.first?.command == "Original")
        await miner.refresh()
        #expect(!miner.refreshFailed && miner.records.first?.command == "Replacement")
        #expect(captured.contains("Original") && !captured.contains("Replacement"))
        await miner.refresh()
        #expect(miner.records.isEmpty && !miner.refreshFailed)
    }
    @Test func inspectorPersistsFiltersAndStopsRefreshingOnClose() async throws {
        _ = NSApplication.shared
        let domain = "XRG.process-inspector.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: domain)); defer { defaults.removePersistentDomain(forName: domain) }
        let miner = XRGProcessMiner(source: { XRGProcessMiner.parse("10 1 1024 2000 - alice First\n20 2 2048 4000 - bob Second") })
        await miner.refresh()
        let inspector = XRGProcessInspector(miner: miner, defaults: defaults, sort: .memory)
        #expect(inspector.rows.map(\.pid) == [2, 1])
        inspector.search.stringValue = "first"; inspector.user.stringValue = "alice"; inspector.optionsChanged(nil)
        #expect(inspector.rows.map(\.pid) == [1])
        inspector.present(); #expect(inspector.refreshTimer?.isValid == true)
        inspector.close(); #expect(inspector.refreshTimer == nil)
        let reopened = XRGProcessInspector(miner: miner, defaults: defaults, sort: .cpu)
        #expect(reopened.options.search == "first" && reopened.options.user == "alice")
        #expect(reopened.rows.map(\.pid) == [1]); reopened.close()
        defaults.set(Data("{}".utf8), forKey: XRGProcessInspector.optionsKey)
        let invalid = XRGProcessInspector(miner: miner, defaults: defaults, sort: .cpu)
        #expect(invalid.rows.count == 2); invalid.close()
    }
}

private final class InspectorFixture: @unchecked Sendable {
    private let lock = NSLock()
    private var index = 0
    func next() -> [XRGProcessRecord]? {
        lock.lock(); defer { lock.unlock() }; index += 1
        switch index {
        case 1: return XRGProcessMiner.parse("10 42 1024 2048 - user Original")
        case 2: return nil
        case 3: return XRGProcessMiner.parse("20 42 2048 4096 - user Replacement")
        default: return []
        }
    }
}
