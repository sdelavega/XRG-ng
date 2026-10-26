import Foundation
import SQLite3
import Testing
@testable import XRGCore

@Suite @MainActor
struct XRGAITokenMinerTests {
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
