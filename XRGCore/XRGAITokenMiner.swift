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
        var models: [String: UInt64] = [:]
        let consume: (String?, UInt64, UInt64) -> Void = { model, input, output in
            if let model, !model.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
               model.utf8.count <= 1024, model.unicodeScalars.allSatisfy({ !CharacterSet.controlCharacters.contains($0) }) {
                let (tokens, badTokens) = input.addingReportingOverflow(output)
                let (sum, badSum) = (models[model] ?? 0).addingReportingOverflow(tokens)
                if !badTokens, !badSum { models[model] = sum }
            }
            let (i, o) = prices(model: model, gemini: gemini)
            cost += Double(input) / 1_000_000 * i + Double(output) / 1_000_000 * o
        }
        let totals = gemini ? XRGProviderLogParser.parseGemini(atPath: path, consume: consume)
            : XRGProviderLogParser.parseClaude(atPath: path, consume: consume)
        return XRGScanTotals(tokens: totals.total, input: totals.input, output: totals.output, cost: cost, modelTotals: models)
    }
}

@MainActor
@objc(XRGAITokenMiner)
public final class XRGAITokenMiner: NSObject {
    private let home: String
    private let clock: () -> TimeInterval
    private let claudeScan: XRGScanCache
    private let codexScan: XRGScanCache
    private let geminiScan: XRGScanCache
    private let tracker = XRGRateTracker()
    private let otelRequest: XRGURL
    private let tagsRequest: XRGURL
    private let runningRequest: XRGURL
    private var collectionTask: Task<Void, Never>?
    private var collectionGeneration = UUID()
    private var completions: [() -> Void] = []
    private var lastOllamaPoll: TimeInterval?
    private var models: [String] = []
    private var rates = [UInt32](repeating: 0, count: 5)
    private var histories = (0..<5).map { _ in XRGDataSet() }
    private let costHistory = XRGDataSet()
    private var costs = [Double](repeating: 0, count: 5)
    private var costRate = 0.0
    private var logSources = [String](repeating: "", count: 3)
    private var rateSources = [String](repeating: "", count: 5)
    private var codexHasSnapshot = false
    private var geminiModels: [String: UInt64] = [:]
    private var claudeReady = false
    private var codexReady = false
    private var geminiReady = false
    private var geminiInput: UInt64 = 0
    private var geminiOutput: UInt64 = 0
    private var accounting = XRGTokenAccounting()
    private var accountingEnabled = false
    private var codexUsage: XRGTokenUsage?
    private var codexModels: [String: UInt64] = [:]
    private var claudeUsage: XRGTokenUsage?
    private var hermesUsage: XRGTokenUsage?
    private var claudeModels: [String: UInt64] = [:]
    var usageEventHandler: ((String, XRGTokenAccounting.Delta) -> Void)?
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
    init(home: String, clock: @escaping () -> TimeInterval, otelRequest: XRGURL = XRGURL(timeoutInterval: 2),
         tagsRequest: XRGURL = XRGURL(timeoutInterval: 2), runningRequest: XRGURL = XRGURL(timeoutInterval: 2),
         scanInterval: TimeInterval = XRGAISamplingCadence.seconds) {
        claudeScan = XRGScanCache(interval: scanInterval)
        codexScan = XRGScanCache(interval: scanInterval)
        geminiScan = XRGScanCache(interval: scanInterval)
        self.otelRequest = otelRequest; self.tagsRequest = tagsRequest; self.runningRequest = runningRequest
        self.home = home
        self.clock = clock
        super.init()
        detectBestStrategy()
    }
    var isScanningLogs: Bool { claudeScan.isScanning || codexScan.isScanning || geminiScan.isScanning }
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

    @nonobjc func resizeHistory(_ count: Int) {
        guard (1...XRGSamplingSettings.maximumHistorySamples).contains(count) else { return }
        for history in histories + [costHistory] {
            history.resize(count, fillingWith: XRGGraphRenderer.missingValue)
        }
    }

    @objc public func reset() {
        cancelCollection()
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
        accounting = XRGTokenAccounting(); claudeUsage = nil; hermesUsage = nil; claudeModels = [:]
        codexUsage = nil; codexModels = [:]; codexHasSnapshot = false
        geminiModels = [:]; logSources = Array(repeating: "", count: 3); rateSources = Array(repeating: "", count: 5)
    }

    func resetAccountingBaseline() {
        cancelCollection()
        for request in [otelRequest, tagsRequest, runningRequest] { request.cancelLoading() }
        claudeUsage = nil; lastOllamaPoll = nil
        accounting = XRGTokenAccounting()
        // A scan started before a reset/enable transition must not later appear
        // as post-reset activity. Fresh complete sweeps establish the baseline.
        for scan in [claudeScan, codexScan, geminiScan] { scan.reset() }
        claudeReady = false; codexReady = false; geminiReady = false; codexHasSnapshot = false
    }
    func pauseCollection() {
        resetAccountingBaseline()
        for request in [otelRequest, tagsRequest, runningRequest] { request.cancelLoading() }
        tracker.reset()
        lastOllamaPoll = nil
    }
    func setAccountingEnabled(_ enabled: Bool) {
        if accountingEnabled != enabled { resetAccountingBaseline(); accountingEnabled = enabled }
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

    private func cancelCollection() {
        collectionGeneration = UUID()
        collectionTask?.cancel(); collectionTask = nil; completions = []
    }

    /// One asynchronous observation per collection cycle. Complete scans and
    /// endpoint responses are consumed once, before rates/accounting are published.
    func requestLatestTokenInfo(completion: @escaping () -> Void) {
        completions.append(completion)
        guard collectionTask == nil else { return }
        let generation = collectionGeneration
        collectionTask = Task { [weak self] in
            guard let self, generation == self.collectionGeneration, !Task.isCancelled else { return }
            defer {
                if generation == self.collectionGeneration {
                    self.collectionTask = nil
                    let callbacks = self.completions; self.completions = []
                    for callback in callbacks { callback() }
                }
            }
            let strategy = self.activeStrategy
            if strategy == .JSONL { self.refreshClaude(force: true) }
            self.refreshCodex(force: true); self.refreshGemini(force: true)
            let usesEndpoint = strategy == .none || strategy == .OTel
            if usesEndpoint {
                self.otelRequest.setURLString("http://localhost:8889/metrics")
                if !self.otelRequest.isLoading { self.otelRequest.loadURLInBackground() }
            }
            self.tagsRequest.setURLString("http://localhost:11434/api/tags")
            self.runningRequest.setURLString("http://localhost:11434/api/ps")
            if !self.tagsRequest.isLoading { self.tagsRequest.loadURLInBackground() }
            if !self.runningRequest.isLoading { self.runningRequest.loadURLInBackground() }
            self.lastOllamaPoll = self.clock()
            // A cancellable, nonblocking wait also handles injected transports
            // that do not immediately honor cancellation. No work runs in paint.
            while self.isScanningLogs || (usesEndpoint && self.otelRequest.isLoading)
                    || self.tagsRequest.isLoading || self.runningRequest.isLoading {
                guard generation == self.collectionGeneration, !Task.isCancelled else { return }
                do { try await Task.sleep(for: .milliseconds(10)) } catch { return }
            }
            guard generation == self.collectionGeneration, !Task.isCancelled else { return }
            let success: Bool
            switch strategy {
            case .JSONL: self.consumeClaudeLogSnapshot(); success = self.claudeReady
            case .SQLite: success = self.fetchFromSQLiteDatabase()
            case .OTel, .none: success = self.consumeOTelResponse()
            }
            if !success { self.detectBestStrategy() }
            self.consumeCodexLogSnapshot(); self.consumeGeminiLogSnapshot(); self.consumeOllamaResponses()
            self.publish(time: self.clock(), hermesReady: self.fetchFromHermesDatabase())
        }
    }

    func publish(time: TimeInterval, hermesReady: Bool) {
        let totals = [totalClaudeTokens, totalCodexTokens, totalGeminiTokens, totalOllamaTokens, totalHermesTokens]
        let ready = [claudeReady, codexReady, geminiReady, true, hermesReady]
        let sources = [activeStrategy == .JSONL ? "claude-log:" + logSources[0] : "claude-\(activeStrategy.rawValue)",
                       "codex-log:" + logSources[1], "gemini-log:" + logSources[2], "ollama", "hermes"]
        let geminiChanged = rateSources[2] != sources[2]
        if rateSources != sources { tracker.resetCost() }
        for index in 0..<5 {
            let waitingForEndpoint = index == 0 && activeStrategy == .OTel && claudeUsage != nil
            if rateSources[index] != sources[index] || (!ready[index] && !waitingForEndpoint) {
                tracker.reset(key: "provider\(index)")
            }
            rateSources[index] = sources[index]
            rates[index] = ready[index] ? tracker.sample(counter: totals[index], key: "provider\(index)", time: time).rate : 0
            histories[index].setNextValue(Double(rates[index]))
        }
        if geminiChanged || !geminiReady {
            tracker.reset(key: "geminiInput"); tracker.reset(key: "geminiOutput")
        }
        if geminiReady {
            let input = tracker.sample(counter: geminiInput, key: "geminiInput", time: time).delta
            let output = tracker.sample(counter: geminiOutput, key: "geminiOutput", time: time).delta
            if input > 0 || output > 0 { geminiEventHandler?(input, output) }
        }
        // Waiting for the next HTTP response is not a failed observation.
        let claudeAccountingReady = activeStrategy == .OTel ? claudeUsage != nil : claudeReady
        let samples: [(String, String, XRGTokenUsage?, [String: UInt64])] = [
            ("Claude", sources[0], claudeAccountingReady ? claudeUsage : nil, claudeModels),
            ("Codex", sources[1], codexReady ? XRGTokenUsage(input: codexUsage?.input ?? 0,
                 output: codexUsage?.output ?? 0, total: totalCodexTokens) : nil, codexModels),
            ("Gemini", sources[2], geminiReady ? XRGTokenUsage(input: geminiInput, output: geminiOutput, total: totalGeminiTokens) : nil, geminiModels),
            ("Hermes", "hermes-sqlite", hermesReady ? hermesUsage : nil,
             hermesModelTokens.mapValues {
                let (sum, overflow) = ($0["input"]?.uint64Value ?? 0).addingReportingOverflow($0["output"]?.uint64Value ?? 0)
                return overflow ? 0 : sum
             })]
        for (provider, source, usage, models) in samples {
            if let delta = accounting.sample(provider: provider, source: source, usage: usage, models: models), accountingEnabled {
                usageEventHandler?(provider, delta)
            }
        }
        costs[1] = XRGAIPricing.estimate(tokens: totalCodexTokens, inputPrice: 2.5, outputPrice: 10)
        totalCostUSD = costs.reduce(0, +)
        let costsReady = (claudeReady || activeStrategy == .none) && codexReady && geminiReady
        costRate = costsReady ? tracker.sampleCost(totalCostUSD, time: time) : 0
        costHistory.setNextValue(costRate * 1000)
    }

    private func consumeClaudeLogSnapshot() {
        let observation = claudeScan.completedObservation
        claudeReady = observation.map { !$0.failed } ?? false
        if let observation {
            logSources[0] = observation.source
            let sample = observation.totals
            totalClaudeTokens = sample.tokens
            claudeUsage = XRGTokenUsage(input: sample.input, output: sample.output, total: sample.tokens)
            claudeModels = sample.modelTotals
            costs[0] = sample.cost
        }
    }
    @objc public func fetchFromJSONLTranscripts() -> Bool {
        consumeClaudeLogSnapshot()
        updateJSONLCacheInBackground()
        return true
    }
    @objc public func updateJSONLCacheInBackground() { refreshClaude(force: false) }
    private func refreshClaude(force: Bool) {
        claudeScan.refreshChecked(root: path(".claude/projects"), layout: 0, force: force) { XRGAIPricing.parse($0, gemini: false) }
    }
    private func consumeCodexLogSnapshot() {
        let observation = codexScan.completedObservation
        codexHasSnapshot = observation != nil
        codexReady = observation.map { !$0.failed } ?? false
        if let observation {
            logSources[1] = observation.source
            let sample = observation.totals
            totalCodexTokens = sample.tokens
            codexUsage = XRGTokenUsage(input: sample.input, output: sample.output, total: sample.tokens)
            codexModels = sample.modelTotals
        }
    }
    @objc public func fetchFromCodexCLI() -> Bool {
        consumeCodexLogSnapshot()
        updateCodexCacheInBackground()
        return true
    }
    var codexLastScanFailed: Bool { codexScan.lastScanFailed }
    var codexRecordedUsage: XRGTokenUsage? { codexHasSnapshot ? codexUsage : nil }
    var codexRecordedModels: [String: UInt64] { codexHasSnapshot ? codexModels : [:] }
    @objc public func updateCodexCacheInBackground() { refreshCodex(force: false) }
    private func refreshCodex(force: Bool) {
        codexScan.refreshChecked(root: path(".codex/sessions"), layout: 1, force: force) {
            let snapshot = try XRGCodexLogParser.snapshot(atPath: $0)
            return XRGScanTotals(tokens: snapshot.usage.total, input: snapshot.usage.input,
                output: snapshot.usage.output, cost: 0, modelTotals: snapshot.modelTotals)
        }
    }
    private func consumeGeminiLogSnapshot() {
        let observation = geminiScan.completedObservation
        geminiReady = observation.map { !$0.failed } ?? false
        if let observation {
            logSources[2] = observation.source
            let sample = observation.totals
            geminiModels = sample.modelTotals
            totalGeminiTokens = sample.tokens
            geminiInput = sample.input; geminiOutput = sample.output
            costs[2] = sample.cost
        }
    }
    @objc public func fetchFromGeminiCLI() -> Bool {
        consumeGeminiLogSnapshot()
        updateGeminiCacheInBackground()
        return true
    }
    @objc public func updateGeminiCacheInBackground() { refreshGemini(force: false) }
    private func refreshGemini(force: Bool) {
        geminiScan.refreshChecked(root: path(".gemini/tmp"), layout: 2, force: force) { XRGAIPricing.parse($0, gemini: true) }
    }
    @objc public func fetchFromSQLiteDatabase() -> Bool {
        guard let sample = XRGClaudeStore.snapshot(atPath: path(".claude/monitoring/claude_usage.db")) else {
            claudeReady = false
            return false
        }
        totalClaudeTokens = sample.tokens
        claudeUsage = XRGTokenUsage(total: sample.tokens); claudeModels = [:]
        costs[0] = sample.cost
        claudeReady = true
        return true
    }
    @objc public func fetchFromHermesDatabase() -> Bool {
        guard let sample = XRGHermesStore.snapshot(atPath: path(".hermes/state.db")) else { return false }
        totalHermesTokens = sample.total
        hermesUsage = XRGTokenUsage(input: sample.input, output: sample.output, total: sample.total)
        costs[4] = sample.cost
        hermesModelTokens = sample.models
        hermesTopModel = sample.topModel
        return true
    }
    @objc public func fetchFromOTelEndpoint() -> Bool {
        otelRequest.setURLString("http://localhost:8889/metrics")
        let result = consumeOTelResponse()
        if !otelRequest.isLoading { otelRequest.loadURLInBackground() }
        return result
    }
    private func consumeOTelResponse() -> Bool {
        var received = false
        if otelRequest.isDataReady(), let data = otelRequest.getData(), let text = String(data: data, encoding: .utf8) {
            let sample = XRGLocalProviderParser.metrics(from: text)
            if activeStrategy != .OTel { tracker.reset() }
            activeStrategy = .OTel
            totalClaudeTokens = sample.tokens
            claudeUsage = sample.hasTokenSamples ? XRGTokenUsage(total: sample.tokens) : nil
            claudeModels = [:]
            costs[0] = sample.cost
            received = sample.hasTokenSamples
        }
        claudeReady = received
        let failed = otelRequest.didErrorOccur()
        if failed { claudeUsage = nil }
        return received || !failed
    }
    @objc public func fetchFromOllamaAPI() -> Bool {
        updateOllamaStatusInBackground()
        return ollamaAvailable
    }
    @objc public func updateOllamaStatusInBackground() {
        tagsRequest.setURLString("http://localhost:11434/api/tags")
        runningRequest.setURLString("http://localhost:11434/api/ps")
        consumeOllamaResponses()
        let now = clock()
        if lastOllamaPoll.map({ now - $0 >= XRGAISamplingCadence.seconds }) ?? true, !tagsRequest.isLoading, !runningRequest.isLoading {
            lastOllamaPoll = now
            tagsRequest.loadURLInBackground()
            runningRequest.loadURLInBackground()
        }
    }
    private func consumeOllamaResponses() {
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
