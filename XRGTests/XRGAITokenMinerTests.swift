import Foundation
import SQLite3
import Testing
@testable import XRGCore

@Suite @MainActor
struct XRGAITokenMinerTests {
    @Test func timestampWindowsUseCompletionTimeAndPreserveRateClockAndSampleBuffers() throws {
        var wall = 100.0
        let miner = XRGAITokenMiner(home: "/nonexistent-xrg-window-fixture", clock: { 0 }, historyClock: { wall })
        miner.setDataSize(3); miner.totalHermesTokens = 100; miner.publish(time: 1, hermesReady: true)
        wall = 105; miner.totalHermesTokens = 200; miner.publish(time: 3, hermesReady: true)
        wall = 165; miner.totalHermesTokens = 300; miner.publish(time: 5, hermesReady: true)
        let original = miner.hermesTokenData().orderedValues
        miner.costData().setNextValue(7) // Index-only edits have no invented completion timestamp.
        miner.setHistoryWindow(1)
        let window = try #require(miner.windowHistories())
        #expect(window.count == 6 && window[4].numValues == 13)
        #expect(window[4].orderedValues.first == 50 && window[4].currentValue == 50)
        #expect(window[4].orderedValues[1..<12].allSatisfy { $0 == XRGGraphRenderer.missingValue })
        #expect(window[5].currentValue == 0 && miner.costData().currentValue == 7)
        #expect(miner.hermesTokenData().orderedValues == original && miner.hermesTokenRate() == 50)
        miner.resizeHistory(1); #expect(miner.windowHistories()?[4].numValues == 13)
        wall = 50; miner.totalHermesTokens = 400; miner.publish(time: 7, hermesReady: true)
        #expect(miner.hermesTokenRate() == 50 && miner.totalHermesTokens == 400)
        let reset = try #require(miner.windowHistories())
        #expect(reset[4].orderedValues.dropLast().allSatisfy { $0 == XRGGraphRenderer.missingValue })
        #expect(reset[4].currentValue == 50)
        miner.setHistoryWindow(0); #expect(miner.windowHistories() == nil && miner.hermesTokenData().orderedValues == [50])
        miner.setHistoryWindow(1); miner.reset()
        #expect(miner.windowHistories()![4].orderedValues.allSatisfy { $0 == XRGGraphRenderer.missingValue })
    }

    @Test func retentionPreservesProviderAndCostHistoryRateBaselinesAndTotals() {
        let miner = XRGAITokenMiner(home: "/nonexistent-xrg-retention-fixture", clock: { 0 })
        miner.setDataSize(3); miner.totalHermesTokens = 100; miner.publish(time: 1, hermesReady: true)
        miner.totalHermesTokens = 200; miner.publish(time: 3, hermesReady: true)
        miner.costData().setNextValue(7)
        #expect(miner.hermesTokenRate() == 50)
        miner.resizeHistory(6)
        #expect(miner.hermesTokenData().orderedValues.prefix(3).allSatisfy { $0 == XRGGraphRenderer.missingValue })
        #expect(miner.hermesTokenData().currentValue == 50 && miner.costData().currentValue == 7)
        #expect(miner.totalHermesTokens == 200 && miner.hermesTokenRate() == 50)
        miner.totalHermesTokens = 300; miner.publish(time: 5, hermesReady: true)
        #expect(miner.hermesTokenRate() == 50)
        miner.resizeHistory(1)
        #expect(miner.hermesTokenData().orderedValues == [50] && miner.costData().numValues == 1)
        miner.resizeHistory(20001); #expect(miner.hermesTokenData().numValues == 1)
    }

    @Test func pauseCancelsEndpointAndRebasesAccountingWithoutErasingGraphs() async throws {
        let request = XRGURL(timeoutInterval: 2, transport: { _ in
            try await Task.sleep(for: .seconds(30))
            return Data("claude_code_input_tokens_total 999".utf8)
        })
        let miner = XRGAITokenMiner(home: "/nonexistent-xrg-pause-fixture", clock: { 0 }, otelRequest: request)
        miner.setDataSize(3); miner.hermesTokenData().setAllValues(8)
        miner.totalHermesTokens = 100
        _ = miner.fetchFromOTelEndpoint()
        #expect(request.isLoading)
        miner.pauseCollection()
        #expect(!request.isLoading && !request.isDataReady())
        #expect(miner.hermesTokenData().orderedValues == [8, 8, 8] && miner.totalHermesTokens == 100)
        miner.publish(time: 1, hermesReady: true)
        #expect(miner.hermesTokenRate() == 0)
        miner.reset()
    }

    @Test func strategyAndDatabaseCostSurvivePublication() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let directory = root.appendingPathComponent(".claude/monitoring")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        var db: OpaquePointer?
        try #require(sqlite3_open(directory.appendingPathComponent("claude_usage.db").path, &db) == SQLITE_OK)
        defer { sqlite3_close(db) }
        try #require(sqlite3_exec(db, "CREATE TABLE sessions(tokens_used INTEGER, estimated_cost REAL); INSERT INTO sessions VALUES (1000000,0)", nil, nil, nil) == SQLITE_OK)
        let miner = XRGAITokenMiner(home: root.path, clock: { 0 })
        #expect(miner.activeStrategy == .SQLite)
        #expect(miner.fetchFromSQLiteDatabase())
        miner.publish(time: 1, hermesReady: false)
        #expect(miner.totalClaudeTokens == 1_000_000)
        #expect(miner.claudeCostUSD() == 0)
        #expect(miner.totalCostUSD == 0)
        try #require(sqlite3_exec(db, "UPDATE sessions SET estimated_cost=12.5", nil, nil, nil) == SQLITE_OK)
        #expect(miner.fetchFromSQLiteDatabase())
        miner.publish(time: 2, hermesReady: false)
        #expect(miner.totalCostUSD == 12.5)
        try FileManager.default.createDirectory(at: root.appendingPathComponent(".claude/projects"), withIntermediateDirectories: true)
        miner.detectBestStrategy()
        #expect(miner.activeStrategy == .JSONL)
    }

    @Test func ratesSaturateAndReset() {
        let miner = XRGAITokenMiner(home: "/nonexistent-xrg-fixture", clock: { 0 })
        miner.setDataSize(3)
        miner.publish(time: 1, hermesReady: true)
        miner.totalHermesTokens = .max
        miner.totalOllamaTokens = .max
        miner.publish(time: 2, hermesReady: true)
        #expect(miner.hermesTokenRate() == .max)
        #expect(miner.totalTokenRate() == .max)
        miner.reset()
        #expect(miner.totalTokenRate() == 0)
        #expect(miner.hermesTokenData().max == 0)
        #expect(miner.totalHermesTokens == 0)
        #expect(miner.hermesModelTokens.isEmpty)
        #expect(miner.costPerHour() == 0)
        miner.totalHermesTokens = 900
        miner.publish(time: 3, hermesReady: true)
        #expect(miner.hermesTokenRate() == 0)
    }

    @Test func preservedPricePolicyAndExtremeEstimates() {
        #expect(XRGAIPricing.prices(model: "claude-haiku-4-5", gemini: false).0 == 1)
        #expect(XRGAIPricing.prices(model: "claude-3-haiku", gemini: false).1 == 1.25)
        #expect(XRGAIPricing.prices(model: "gemini-1.5-flash", gemini: true).0 == 0.075)
        #expect(XRGAIPricing.estimate(tokens: .max, inputPrice: 2.5, outputPrice: 10).isFinite)
        #expect(XRGAIPricing.estimate(tokens: 1_000_000, inputPrice: 2.5, outputPrice: 10) == 4.75)
    }

    @Test func otelWaitsForCompletedSampleAndKeepsReportedCost() async throws {
        let request = XRGURL(timeoutInterval: 2, transport: { _ in
            Data("claude_code_input_tokens_total 100\nclaude_code_cost_usd_total 0".utf8)
        })
        let miner = XRGAITokenMiner(home: "/nonexistent-xrg-fixture", clock: { 0 }, otelRequest: request)
        #expect(miner.fetchFromOTelEndpoint())
        #expect(miner.activeStrategy == .none)
        for _ in 0..<200 {
            if request.isDataReady() { break }
            try await Task.sleep(for: .milliseconds(5))
        }
        #expect(request.isDataReady())
        #expect(miner.fetchFromOTelEndpoint())
        #expect(miner.activeStrategy == .OTel)
        #expect(miner.totalClaudeTokens == 100)
        #expect(miner.claudeCostUSD() == 0)
        miner.reset()
        #expect(!request.isLoading)
    }
}
