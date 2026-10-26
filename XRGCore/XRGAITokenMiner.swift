/*
 * XRG-ng: A system resource grapher for macOS and Linux.
 * Copyright (C) 2002-2024 Mike Piatek-Jimenez / Gaucho Software, LLC.
 * Copyright (C) 2025-2026 Marc Shade.
 * Copyright (C) 2026 Stephen de la Vega.
 * You can view the complete license in the LICENSE file in the root
 * of the source tree.
 *
 * This program is free software; you can redistribute it and/or
 * modify it under the terms of the GNU General Public License
 * as published by the Free Software Foundation; either version 3
 * of the License, or (at your option) any later version.
 *
 * This program is distributed in the hope that it will be useful,
 * but WITHOUT ANY WARRANTY; without even the implied warranty of
 * MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
 * GNU General Public License for more details.
 *
 * You should have received a copy of the GNU General Public License
 * along with this program. If not, see <https://www.gnu.org/licenses/>.
 *
 */

import Foundation

@objc public enum XRGAIDataStrategy: Int {
    case none, JSONL, SQLite, OTel
}

/// Compatibility estimates carried over from the Objective-C miner.
/// These are not a current provider price catalog.
enum XRGAIPricing {
    static func prices(model: String?, gemini: Bool) -> (Double, Double) {
        let name = model?.lowercased() ?? ""
        if gemini {
            if name.contains("2.0-flash") || name.contains("gemini-2.0") { return (0.1, 0.4) }
            if name.contains("1.5-pro") || name.contains("gemini-pro") { return (1.25, 5) }
            if name.contains("1.5-flash") { return (0.075, 0.3) }
            if name.contains("1.0-pro") { return (0.5, 1.5) }
            if name.contains("ultra") { return (10, 30) }
            return (0.1, 0.4)
        }
        if name.contains("opus") { return (15, 75) }
        if name.contains("haiku") {
            if ["haiku-4-5", "4-5-haiku", "haiku-4.5", "4.5-haiku"].contains(where: name.contains) { return (1, 5) }
            if ["3-5-haiku", "haiku-3-5", "3.5-haiku", "haiku-3.5"].contains(where: name.contains) { return (0.8, 4) }
            if name.contains("3-haiku") || name.contains("haiku-3") { return (0.25, 1.25) }
            return (0.8, 4)
        }
        return (3, 15)
    }
    static func estimate(tokens: UInt64, inputPrice: Double, outputPrice: Double) -> Double {
        // Integer arithmetic avoids trapping when converting rounded Double(UInt64.max).
        let input = tokens / 10 * 7 + tokens % 10 * 7 / 10
        return Double(input) / 1_000_000 * inputPrice + Double(tokens - input) / 1_000_000 * outputPrice
    }
    static func parse(_ path: String, gemini: Bool) -> XRGScanTotals {
        var cost = 0.0
        let consume: (String?, UInt64, UInt64) -> Void = { model, input, output in
            let (i, o) = prices(model: model, gemini: gemini)
            cost += Double(input) / 1_000_000 * i + Double(output) / 1_000_000 * o
        }
        let totals = gemini ? XRGProviderLogParser.parseGemini(atPath: path, consume: consume)
            : XRGProviderLogParser.parseClaude(atPath: path, consume: consume)
        return XRGScanTotals(tokens: totals.total, input: totals.input, output: totals.output, cost: cost)
    }
}

@MainActor
@objc(XRGAITokenMiner)
public final class XRGAITokenMiner: NSObject {
    private let home: String
    private let clock: () -> TimeInterval
    private let claudeScan = XRGScanCache()
    private let codexScan = XRGScanCache()
    private let geminiScan = XRGScanCache()
    private let tracker = XRGRateTracker()
    private let otelRequest: XRGURL
    private let tagsRequest = XRGURL(timeoutInterval: 2)
    private let runningRequest = XRGURL(timeoutInterval: 2)
    private var lastOllamaPoll: TimeInterval?
    private var models: [String] = []
    private var rates = [UInt32](repeating: 0, count: 5)
    private var histories = (0..<5).map { _ in XRGDataSet() }
    private let costHistory = XRGDataSet()
    private var costs = [Double](repeating: 0, count: 5)
    private var costRate = 0.0
    private var claudeReady = false
    private var codexReady = false
    private var geminiReady = false
    private var geminiInput: UInt64 = 0
    private var geminiOutput: UInt64 = 0
    @objc public var geminiEventHandler: ((UInt64, UInt64) -> Void)?
    @objc public private(set) var activeStrategy: XRGAIDataStrategy = .none
    @objc public private(set) var ollamaAvailable = false
    @objc public private(set) var ollamaRunningModels: [String] = []
    @objc public private(set) var hermesModelTokens: [String: [String: NSNumber]] = [:]
    @objc public private(set) var hermesTopModel: String?
    @objc public var totalClaudeTokens: UInt64 = 0
    @objc public var totalCodexTokens: UInt64 = 0
    @objc public var totalGeminiTokens: UInt64 = 0
    @objc public var totalOllamaTokens: UInt64 = 0
    @objc public var totalHermesTokens: UInt64 = 0

    @objc public private(set) var totalCostUSD = 0.0

    public override convenience init() {
        self.init(home: NSHomeDirectory(), clock: { ProcessInfo.processInfo.systemUptime })
    }
    init(home: String, clock: @escaping () -> TimeInterval, otelRequest: XRGURL = XRGURL(timeoutInterval: 2)) {
        self.otelRequest = otelRequest
        self.home = home
        self.clock = clock
        super.init()
        detectBestStrategy()
    }
    private func path(_ suffix: String) -> String { (home as NSString).appendingPathComponent(suffix) }

    @objc public func detectBestStrategy() {
        let old = activeStrategy
        if FileManager.default.fileExists(atPath: path(".claude/projects")) { activeStrategy = .JSONL }
        else if FileManager.default.fileExists(atPath: path(".claude/monitoring/claude_usage.db")) { activeStrategy = .SQLite }
        else { activeStrategy = .none }
        if old != activeStrategy {
            tracker.reset()
            claudeReady = false
        }
    }

    @objc public func strategyName() -> String {
        switch activeStrategy {
        case .JSONL: return "JSONL Transcripts (Universal - Default Claude Code)"
        case .SQLite: return "SQLite Database (Advanced - Custom Monitoring)"
        case .OTel: return "OpenTelemetry Endpoint (Advanced - OTel Configured)"
        case .none: return "None (No data available)"
        }
    }

    @objc public func setDataSize(_ count: Int) {
        guard count >= 0 else { return }
        for history in histories + [costHistory] { history.resize(count) }
    }

    @objc public func reset() {
        for scan in [claudeScan, codexScan, geminiScan] { scan.reset() }
        for request in [otelRequest, tagsRequest, runningRequest] { request.cancelLoading() }
        for history in histories + [costHistory] { history.reset() }
        tracker.reset()
        rates = Array(repeating: 0, count: 5)
        costs = Array(repeating: 0, count: 5)
        costRate = 0
        totalCostUSD = 0
        totalClaudeTokens = 0; totalCodexTokens = 0; totalGeminiTokens = 0
        totalOllamaTokens = 0; totalHermesTokens = 0
        claudeReady = false; codexReady = false; geminiReady = false
        geminiInput = 0; geminiOutput = 0
        hermesModelTokens = [:]; hermesTopModel = nil
        models = []; ollamaRunningModels = []; ollamaAvailable = false
        lastOllamaPoll = nil
    }

    @objc public func getLatestTokenInfo() {
        let success: Bool
        switch activeStrategy {
        case .JSONL: success = fetchFromJSONLTranscripts()
        case .SQLite: success = fetchFromSQLiteDatabase()
        case .OTel, .none: success = fetchFromOTelEndpoint()
        }
        if !success { detectBestStrategy() }
        _ = fetchFromCodexCLI()
        _ = fetchFromGeminiCLI()
        _ = fetchFromOllamaAPI()
        let hermesReady = fetchFromHermesDatabase()
        publish(time: clock(), hermesReady: hermesReady)
    }

    func publish(time: TimeInterval, hermesReady: Bool) {
        let totals = [totalClaudeTokens, totalCodexTokens, totalGeminiTokens, totalOllamaTokens, totalHermesTokens]
        let ready = [claudeReady, codexReady, geminiReady, true, hermesReady]
        for index in 0..<5 {
            rates[index] = ready[index] ? tracker.sample(counter: totals[index], key: "provider\(index)", time: time).rate : 0
            histories[index].setNextValue(Double(rates[index]))
        }
        if geminiReady {
            let input = tracker.sample(counter: geminiInput, key: "geminiInput", time: time).delta
            let output = tracker.sample(counter: geminiOutput, key: "geminiOutput", time: time).delta
            if input > 0 || output > 0 { geminiEventHandler?(input, output) }
        }
        costs[1] = XRGAIPricing.estimate(tokens: totalCodexTokens, inputPrice: 2.5, outputPrice: 10)
        totalCostUSD = costs.reduce(0, +)
        let costsReady = (claudeReady || activeStrategy == .none) && codexReady && geminiReady
        costRate = costsReady ? tracker.sampleCost(totalCostUSD, time: time) : 0
        costHistory.setNextValue(costRate * 1000)
    }

    @objc public func fetchFromJSONLTranscripts() -> Bool {
        claudeReady = claudeScan.completedSnapshot != nil
        if let sample = claudeScan.completedSnapshot {
            totalClaudeTokens = sample.tokens
            costs[0] = sample.cost
        }
        updateJSONLCacheInBackground()
        return true
    }
    @objc public func updateJSONLCacheInBackground() {
        claudeScan.refresh(root: path(".claude/projects"), layout: 0) { XRGAIPricing.parse($0, gemini: false) }
    }
    @objc public func fetchFromCodexCLI() -> Bool {
        codexReady = codexScan.completedSnapshot != nil
        if let sample = codexScan.completedSnapshot { totalCodexTokens = sample.tokens }
        updateCodexCacheInBackground()
        return true
    }
    @objc public func updateCodexCacheInBackground() {
        codexScan.refresh(root: path(".codex/sessions"), layout: 1) {
            XRGScanTotals(tokens: XRGCodexLogParser.totalTokens(atPath: $0), input: 0, output: 0, cost: 0)
        }
    }
    @objc public func fetchFromGeminiCLI() -> Bool {
        geminiReady = geminiScan.completedSnapshot != nil
        if let sample = geminiScan.completedSnapshot {
            totalGeminiTokens = sample.tokens
            geminiInput = sample.input; geminiOutput = sample.output
            costs[2] = sample.cost
        }
        updateGeminiCacheInBackground()
        return true
    }
    @objc public func updateGeminiCacheInBackground() {
        geminiScan.refresh(root: path(".gemini/tmp"), layout: 2) { XRGAIPricing.parse($0, gemini: true) }
    }
    @objc public func fetchFromSQLiteDatabase() -> Bool {
        guard let sample = XRGClaudeStore.snapshot(atPath: path(".claude/monitoring/claude_usage.db")) else {
            claudeReady = false
            return false
        }
        totalClaudeTokens = sample.tokens
        costs[0] = sample.cost
        claudeReady = true
        return true
    }
    @objc public func fetchFromHermesDatabase() -> Bool {
        guard let sample = XRGHermesStore.snapshot(atPath: path(".hermes/state.db")) else { return false }
        totalHermesTokens = sample.total
        costs[4] = sample.cost
        hermesModelTokens = sample.models
        hermesTopModel = sample.topModel
        return true
    }
    @objc public func fetchFromOTelEndpoint() -> Bool {
        otelRequest.setURLString("http://localhost:8889/metrics")
        var received = false
        if otelRequest.isDataReady(), let data = otelRequest.getData(), let text = String(data: data, encoding: .utf8) {
            let sample = XRGLocalProviderParser.metrics(from: text)
            if activeStrategy != .OTel { tracker.reset() }
            activeStrategy = .OTel
            totalClaudeTokens = sample.tokens
            costs[0] = sample.cost
            received = true
        }
        claudeReady = received
        let failed = otelRequest.didErrorOccur()
        if !otelRequest.isLoading { otelRequest.loadURLInBackground() }
        return received || !failed
    }
    @objc public func fetchFromOllamaAPI() -> Bool {
        updateOllamaStatusInBackground()
        return ollamaAvailable
    }
    @objc public func updateOllamaStatusInBackground() {
        tagsRequest.setURLString("http://localhost:11434/api/tags")
        runningRequest.setURLString("http://localhost:11434/api/ps")
        if tagsRequest.isDataReady(), let data = tagsRequest.getData() {
            let names = XRGLocalProviderParser.modelNames(from: data)
            ollamaAvailable = names != nil
            models = names ?? []
            if names == nil { ollamaRunningModels = [] }
        } else if tagsRequest.didErrorOccur() {
            ollamaAvailable = false; models = []; ollamaRunningModels = []
        }
        if ollamaAvailable, runningRequest.isDataReady(), let data = runningRequest.getData() {
            ollamaRunningModels = XRGLocalProviderParser.modelNames(from: data) ?? []
        } else if runningRequest.didErrorOccur() { ollamaRunningModels = [] }
        let now = clock()
        if lastOllamaPoll.map({ now - $0 >= 5 }) ?? true, !tagsRequest.isLoading, !runningRequest.isLoading {
            lastOllamaPoll = now
            tagsRequest.loadURLInBackground()
            runningRequest.loadURLInBackground()
        }
    }
    @objc public func ollamaStatusString() -> String {
        guard ollamaAvailable else { return "Ollama: Not running" }
        guard let first = ollamaRunningModels.first else { return "Ollama: Ready (\(models.count) models)" }
        let name = first.count > 15 ? String(first.prefix(12)) + "..." : first
        let extra = ollamaRunningModels.count > 1 ? " +\(ollamaRunningModels.count - 1)" : ""
        return "Ollama: \(name)\(extra) (\(models.count) avail)"
    }
    @objc public func totalTokenRate() -> UInt32 { UInt32(clamping: rates.reduce(UInt64(0)) { $0 + UInt64($1) }) }
    @objc public func costPerHour() -> Double { costRate * 3600 }
    @objc public func projectedDailyCost() -> Double { costPerHour() * 24 }
    @objc public func costData() -> XRGDataSet { costHistory }
    @objc public func claudeTokenRate() -> UInt32 { rates[0] }
    @objc public func claudeTokenData() -> XRGDataSet { histories[0] }
    @objc public func claudeCostUSD() -> Double { costs[0] }
    @objc public func codexTokenRate() -> UInt32 { rates[1] }
    @objc public func codexTokenData() -> XRGDataSet { histories[1] }
    @objc public func codexCostUSD() -> Double { costs[1] }
    @objc public func geminiTokenRate() -> UInt32 { rates[2] }
    @objc public func geminiTokenData() -> XRGDataSet { histories[2] }
    @objc public func geminiCostUSD() -> Double { costs[2] }
    @objc public func ollamaTokenRate() -> UInt32 { rates[3] }
    @objc public func ollamaTokenData() -> XRGDataSet { histories[3] }
    @objc public func hermesTokenRate() -> UInt32 { rates[4] }
    @objc public func hermesTokenData() -> XRGDataSet { histories[4] }
    @objc public func hermesCostUSD() -> Double { costs[4] }
}
