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

import AppKit

enum XRGAIViewProvider: Int, CaseIterable {
    case claude, codex, gemini, ollama, hermes
    var name: String { ["Claude", "Codex", "Gemini", "Ollama", "Hermes"][rawValue] }
    var code: String { ["C", "X", "G", "O", "H"][rawValue] }
}
struct XRGAIViewProviderData {
    let provider: XRGAIViewProvider
    let history: XRGDataSet
    var rate: UInt64
    var total: UInt64
    var cost: Double = 0
}
struct XRGAITokenViewSnapshot {
    var providers: [XRGAIViewProviderData] = []
    var ollamaAvailable = false
    var ollamaStatus = "Ollama: Not running"
    var runningModels: [String] = []
    var hermesModels: [String: [String: NSNumber]] = [:]
    var totalCost: Double = 0
    var costPerHour: Double = 0
    var projectedDailyCost: Double = 0
    var ordered: [XRGAIViewProviderData] {
        XRGAIViewProvider.allCases.compactMap { provider in providers.first { $0.provider == provider } }
    }
}
@MainActor protocol XRGAITokenViewSource: AnyObject {
    var geminiEventHandler: ((UInt64, UInt64) -> Void)? { get set }
    func setDataSize(_ count: Int)
    func getLatestTokenInfo()
    func viewSnapshot() -> XRGAITokenViewSnapshot
}
extension XRGAITokenMiner: XRGAITokenViewSource {
    func viewSnapshot() -> XRGAITokenViewSnapshot {
        XRGAITokenViewSnapshot(providers: [
            XRGAIViewProviderData(provider: .claude, history: claudeTokenData(), rate: UInt64(claudeTokenRate()), total: totalClaudeTokens, cost: claudeCostUSD()),
            XRGAIViewProviderData(provider: .codex, history: codexTokenData(), rate: UInt64(codexTokenRate()), total: totalCodexTokens, cost: codexCostUSD()),
            XRGAIViewProviderData(provider: .gemini, history: geminiTokenData(), rate: UInt64(geminiTokenRate()), total: totalGeminiTokens, cost: geminiCostUSD()),
            XRGAIViewProviderData(provider: .ollama, history: ollamaTokenData(), rate: UInt64(ollamaTokenRate()), total: totalOllamaTokens),
            XRGAIViewProviderData(provider: .hermes, history: hermesTokenData(), rate: UInt64(hermesTokenRate()), total: totalHermesTokens, cost: hermesCostUSD())],
            ollamaAvailable: ollamaAvailable, ollamaStatus: ollamaStatusString(), runningModels: ollamaRunningModels,
            hermesModels: hermesModelTokens, totalCost: totalCostUSD, costPerHour: costPerHour(), projectedDailyCost: projectedDailyCost())
    }
}

@MainActor @objc public protocol XRGAITokenViewHost: NSObjectProtocol {
    var appSettings: XRGSettings? { get }
    var moduleManager: XRGModuleManager? { get }
    var aiTokenView: XRGAITokenView? { get set }
    func initTimers()
}

@MainActor
@objc(XRGAITokenView) @objcMembers
public final class XRGAITokenView: NSView, XRGModuleView {
    private let source: any XRGAITokenViewSource
    private let observer: XRGAITokensObserver
    private let defaults: UserDefaults
    private let standaloneSettings: XRGSettings?
    private let openURL: (URL) -> Bool
    private let databaseURL: URL
    private weak var host: (any XRGAITokenViewHost)?
    private weak var registeredManager: XRGModuleManager?
    private var didAwake = false
    private var historyWidth: Int?
    private var cachedLayers: [XRGDataSet] = []
    @nonobjc let graphLabels = XRGGraphLabels()
    @nonobjc private(set) var legendLabels: [XRGNonInteractableTextField] = []
    public private(set) weak var module: XRGModule?
    private var settings: XRGSettings? { host?.appSettings ?? standaloneSettings }

    public override init(frame frameRect: NSRect) {
        source = XRGAITokenMiner(); observer = .shared; defaults = .standard; standaloneSettings = nil
        openURL = { NSWorkspace.shared.open($0) }
        databaseURL = URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent(".claude/monitoring", isDirectory: true)
        super.init(frame: frameRect); prepare()
    }
    public required init?(coder: NSCoder) {
        source = XRGAITokenMiner(); observer = .shared; defaults = .standard; standaloneSettings = nil
        openURL = { NSWorkspace.shared.open($0) }
        databaseURL = URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent(".claude/monitoring", isDirectory: true)
        super.init(coder: coder); prepare()
    }
    @nonobjc init(frame: NSRect, source: any XRGAITokenViewSource, observer: XRGAITokensObserver,
                  settings: XRGSettings, defaults: UserDefaults, databaseURL: URL,
                  openURL: @escaping (URL) -> Bool = { _ in true }) {
        self.source = source; self.observer = observer; standaloneSettings = settings; self.defaults = defaults
        self.databaseURL = databaseURL; self.openURL = openURL
        super.init(frame: frame); prepare()
    }
    private func prepare() {
        for label in [graphLabels.leftLabel, graphLabels.centerLabel, graphLabels.rightLabel] { addSubview(label) }
        source.geminiEventHandler = { [observer] input, output in
            observer.recordEvent(promptTokens: input, completionTokens: output, model: "Gemini", provider: "Google")
        }
        setGraphSize(bounds.size); updateLabels()
    }
    public nonisolated override func awakeFromNib() {
        super.awakeFromNib()
        MainActor.assumeIsolated { didAwake = true; bindToWindow() }
    }
    public override func viewDidMoveToWindow() { super.viewDidMoveToWindow(); bindToWindow() }
    private func bindToWindow() {
        let next = window as? any XRGAITokenViewHost
        if host !== next || registeredManager !== next?.moduleManager {
            if host?.aiTokenView === self { host?.aiTokenView = nil }
            if let module { registeredManager?.removeModule(module) }
            registeredManager = nil; module = nil; host = next
        }
        guard didAwake, let host, let manager = host.moduleManager, settings != nil,
              registeredManager !== manager else { updateLabels(); return }
        let module = XRGModule(name: "AI Tokens", reference: self, defaults: defaults)
        module.displayOrder = 10; module.doesGraphUpdate = true; module.doesFastUpdate = false
        module.doesMin5Update = false; module.doesMin30Update = false
        module.isDisplayed = defaults.bool(forKey: "showAITokenGraph")
        self.module = module; registeredManager = manager
        host.aiTokenView = self; host.initTimers()
        updateMinSize(); manager.addModule(module); setGraphSize(module.currentSize)
    }
    public func setGraphSize(_ size: NSSize) {
        let width = size.width.isFinite ? size.width : 23
        setWidth(Int32(min(20_000, max(23, width))))
    }
    public func setWidth(_ width: Int32) {
        let count = min(20_000, Int(width)) - 19
        guard count >= 0, historyWidth != count else { return }
        source.setDataSize(count); historyWidth = count
    }
    public override func setFrameSize(_ newSize: NSSize) { super.setFrameSize(newSize); setGraphSize(newSize); updateLabels() }
    public func updateMinSize() {
        module?.minWidth = ("Claude: 99999K tok/s" as NSString).size(withAttributes: [.font: settings?.graphFont ?? NSFont.systemFont(ofSize: 10)]).width + 25
        module?.minHeight = XRGGraphLabels.lineHeight(settings)
        updateLabels()
    }
    public func graphUpdate(_ timer: Timer?) { source.getLatestTokenInfo(); updateLabels(); needsDisplay = true }
    public func fastUpdate(_ timer: Timer?) {}
    public func min5Update(_ timer: Timer?) {}
    public func min30Update(_ timer: Timer?) {}
    public func shouldDrawMiniGraph() -> Bool { XRGGraphLabels.shouldDrawMiniGraph(in: bounds, settings: settings) }

    @nonobjc static func add(_ left: UInt64, _ right: UInt64) -> UInt64 {
        let (total, overflow) = left.addingReportingOverflow(right)
        return overflow ? .max : total
    }
    @nonobjc static func compactCount(_ value: UInt64) -> String {
        if value >= 1_000_000 { return String(format: "%.1fM", Double(value) / 1_000_000) }
        if value >= 1000 { return String(format: "%.1fK", Double(value) / 1000) }
        return String(value)
    }
    @nonobjc static func integerCount(_ value: UInt64) -> String {
        value >= 1_000_000 ? "\(value / 1_000_000)M" : value >= 1000 ? "\(value / 1000)K" : String(value)
    }
    @nonobjc static func preciseCount(_ value: UInt64, billions: Bool = false) -> String {
        if billions && value >= 1_000_000_000 { return String(format: "%.2fB", Double(value) / 1_000_000_000) }
        if value >= 1_000_000 { return String(format: "%.2fM", Double(value) / 1_000_000) }
        if value >= 1000 { return String(format: "%.1fK", Double(value) / 1000) }
        return String(value)
    }
    @nonobjc static func hermesModelTotals(_ models: [String: [String: NSNumber]]) -> [(String, UInt64)] {
        models.map { name, counts in
            (name, add(UInt64(counts["input"]?.stringValue ?? "") ?? 0, UInt64(counts["output"]?.stringValue ?? "") ?? 0))
        }.filter { $0.1 > 0 }.sorted { $0.1 == $1.1 ? $0.0 < $1.0 : $0.1 > $1.1 }
    }
    @nonobjc func fullReading() -> String { fullReading(source.viewSnapshot()) }
    private func fullReading(_ snapshot: XRGAITokenViewSnapshot) -> String {
        guard let settings else { return "AI Tokens" }
        let providers = snapshot.ordered
        var lines = ["AI Tokens"]
        if providers.contains(where: { $0.total > 0 }) || snapshot.ollamaAvailable {
            lines.append("─ Providers ─")
            for item in providers {
                if item.provider == .ollama && snapshot.ollamaAvailable { lines.append("● " + snapshot.ollamaStatus) }
                else if item.total > 0 {
                    lines.append("● \(item.provider.name): " + (item.provider == .hermes ? Self.compactCount(item.total) : Self.integerCount(item.total)))
                }
                if item.provider == .hermes && item.total > 0 {
                    for (name, count) in Self.hermesModelTotals(snapshot.hermesModels) { lines.append("    \(name): \(Self.compactCount(count))") }
                }
            }
        }
        let total = providers.reduce(UInt64(0)) { Self.add($0, $1.total) }
        if total > 0 {
            lines += ["─ Tokens ─", "Total: " + Self.preciseCount(total, billions: true)]
            for item in providers where item.total > 0 { lines.append("● \(item.provider.code): " + Self.preciseCount(item.total)) }
        }
        let rate = providers.reduce(UInt64(0)) { Self.add($0, $1.rate) }
        if settings.aiTokensShowRate && rate > 0 { lines.append("Rate: " + (rate >= 1000 ? "\(rate / 1000)K/s" : "\(rate)/s")) }
        lines.append("Session: " + Self.integerCount(observer.sessionTotalTokens))
        let daily = observer.dailyTotalTokens, budget = settings.aiTokensDailyBudget
        if budget > 0 {
            lines.append("Daily: \(Self.integerCount(daily))/\(Self.integerCount(UInt64(budget))) (" + String(format: "%.0f%%)", Double(daily) / Double(budget) * 100))
        } else { lines.append("Daily: " + Self.integerCount(daily)) }
        if settings.aiTokensShowBreakdown {
            if settings.aiTokensAggregateByModel, !observer.dailyByModel.isEmpty {
                lines.append("─ By Model ─")
                for key in observer.dailyByModel.keys.sorted() { lines.append(key + ": " + Self.integerCount(observer.dailyByModel[key]?.uint64Value ?? 0)) }
            }
            if settings.aiTokensAggregateByProvider, !observer.dailyByProvider.isEmpty {
                lines.append("─ By Provider ─")
                for key in observer.dailyByProvider.keys.sorted() { lines.append(key + ": " + Self.integerCount(observer.dailyByProvider[key]?.uint64Value ?? 0)) }
            }
        }
        return lines.joined(separator: "\n")
    }
    @nonobjc func color(for provider: XRGAIViewProvider) -> NSColor {
        let first = settings?.graphColor(.ai, component: 1) ?? .clear, second = settings?.graphColor(.ai, component: 2) ?? .clear, third = settings?.graphColor(.ai, component: 3) ?? .clear
        switch provider {
        case .claude: return first
        case .codex: return second
        case .gemini: return third
        case .ollama: return third.blended(withFraction: 0.5, of: first) ?? third
        case .hermes: return second.blended(withFraction: 0.5, of: third) ?? second
        }
    }
    struct Layer { let provider: XRGAIViewProvider; let data: XRGDataSet }
    @nonobjc func historyLayers() -> [Layer] { historyLayers(source.viewSnapshot()) }
    private func historyLayers(_ snapshot: XRGAITokenViewSnapshot) -> [Layer] {
        let providers = snapshot.ordered
        guard let first = providers.first, first.history.numValues > 0,
              providers.allSatisfy({ $0.history.numValues == first.history.numValues }) else { return [] }
        while cachedLayers.count < providers.count { cachedLayers.append(XRGDataSet()) }
        if cachedLayers.count > providers.count { cachedLayers.removeLast(cachedLayers.count - providers.count) }
        for (index, item) in providers.enumerated() {
            cachedLayers[index].copyValues(from: index == 0 ? item.history : cachedLayers[index - 1])
            if index > 0 { cachedLayers[index].addOtherDataSetValues(item.history) }
        }
        return providers.enumerated().map { Layer(provider: $0.element.provider, data: cachedLayers[$0.offset]) }.reversed()
    }
    @nonobjc func historyRect(in rect: NSRect) -> NSRect {
        guard XRGGraphRenderer.validRect(rect) else { return .zero }
        return NSRect(x: rect.minX, y: rect.minY, width: max(0, rect.width - 19), height: max(0, rect.height - XRGGraphLabels.lineHeight(settings)))
    }
    @nonobjc func indicatorRects(in rect: NSRect) -> [NSRect] { indicatorRects(in: rect, snapshot: source.viewSnapshot()) }
    private func indicatorRects(in rect: NSRect, snapshot: XRGAITokenViewSnapshot) -> [NSRect] {
        let graph = historyRect(in: rect), providers = snapshot.ordered
        guard XRGGraphRenderer.validRect(graph) else { return [] }
        let total = providers.reduce(0.0) { $0 + Double($1.rate) }
        guard total.isFinite, total > 0 else { return providers.map { _ in .zero } }
        var y = graph.minY
        return providers.map { provider in
            let height = graph.height * CGFloat(Double(provider.rate) / total)
            let bar = NSRect(x: graph.maxX + 2, y: y, width: min(8, max(0, rect.maxX - graph.maxX - 2)), height: min(height, max(0, graph.maxY - y)))
            y += height; return bar
        }
    }
    private func updateLabels() {
        let mini = shouldDrawMiniGraph(), snapshot = source.viewSnapshot(), text = fullReading(snapshot)
        setAccessibilityElement(true); setAccessibilityRole(mini ? .image : .group)
        setAccessibilityLabel("AI Tokens"); setAccessibilityValue(text)
        for field in [graphLabels.leftLabel, graphLabels.centerLabel, graphLabels.rightLabel] { field.isHidden = mini }
        let rect = XRGGraphLabels.paddedTextRect(for: bounds)
        graphLabels.layoutColumnText(text, rightText: nil,
            in: NSRect(x: rect.minX, y: rect.minY, width: max(0, rect.width - 30), height: rect.height), mini: false, settings: settings)
        let legends = snapshot.ordered.filter { $0.total > 0 || ($0.provider == .ollama && snapshot.ollamaAvailable) }
        while legendLabels.count > legends.count { legendLabels.removeLast().removeFromSuperview() }
        while legendLabels.count < legends.count {
            let label = XRGNonInteractableTextField(frame: .zero)
            label.isEditable = false; label.isSelectable = false; label.isBordered = false; label.drawsBackground = false
            label.font = NSFont.systemFont(ofSize: 9); addSubview(label); legendLabels.append(label)
        }
        let graph = historyRect(in: bounds)
        for (index, item) in legends.enumerated() {
            let y = graph.maxY - 12 - CGFloat(index) * 11
            let label = legendLabels[index]
            label.isHidden = mini || y < bounds.minY || bounds.width < 30
            label.frame = label.isHidden ? .zero : bounds.intersection(NSRect(x: rect.maxX - 12, y: y - 1, width: 12, height: 12))
            label.stringValue = item.provider.code; label.textColor = settings?.textColor ?? .labelColor
            label.fullAccessibilityText = item.provider.name + ": " + Self.compactCount(item.total)
            label.setAccessibilityRole(.staticText); label.setAccessibilityElement(true)
        }
    }
    public override func draw(_ dirtyRect: NSRect) {
        guard !isHidden, let settings, let context = NSGraphicsContext.current, XRGGraphRenderer.validRect(bounds) else { return }
        NSGraphicsContext.saveGraphicsState(); defer { NSGraphicsContext.restoreGraphicsState() }
        updateLabels(); settings.graphColor(.ai, component: 0).set(); bounds.fill(using: .copy)
        context.shouldAntialias = settings.antiAliasing
        let snapshot = source.viewSnapshot(), layers = historyLayers(snapshot)
        let highest = layers.first?.data.max ?? 0
        let maximum: CGFloat = highest.isFinite && highest > 0 ? highest : 1000
        if shouldDrawMiniGraph() {
            if let total = layers.first { XRGGraphRenderer.drawCurve(total.data, upperBound: maximum, lowerBound: 0, in: bounds, flipped: false, filled: true, color: settings.graphColor(.ai, component: 1), style: settings.curveStyle(.ai)) }
            return
        }
        let graph = historyRect(in: bounds)
        if settings.graphEffect(.ai) == 2 { XRGGraphRenderer.drawPixelGrid(graph, spacing: 4, color: settings.borderColor) }
        for layer in layers { XRGGraphRenderer.drawCurve(layer.data, upperBound: maximum, lowerBound: 0, in: graph, flipped: false, filled: true, color: color(for: layer.provider), style: settings.curveStyle(.ai)) }
        if settings.graphEffect(.ai) == 1 { XRGGraphRenderer.drawScanlines(graph) }
        if settings.graphEffect(.ai) == 3 {
            for layer in layers { XRGGraphRenderer.drawPixelDataSet(layer.data, upperBound: maximum, in: graph, color: color(for: layer.provider), dotSize: 2) }
        }
        if XRGGraphRenderer.validRect(graph) {
            settings.borderColor.set(); NSRect(x: graph.maxX, y: graph.minY, width: min(2, max(0, bounds.maxX - graph.maxX)), height: graph.height).fill(using: .copy)
        }
        for (provider, bar) in zip(snapshot.ordered, indicatorRects(in: bounds, snapshot: snapshot)) { color(for: provider.provider).set(); bar.fill(using: .copy) }
        let legends = snapshot.ordered.filter { $0.total > 0 || ($0.provider == .ollama && snapshot.ollamaAvailable) }
        for (index, item) in legends.enumerated() {
            let y = graph.maxY - 12 - CGFloat(index) * 11
            guard y >= bounds.minY, bounds.width >= 30 else { continue }
            color(for: item.provider).set(); NSRect(x: bounds.maxX - 25, y: y, width: 8, height: 8).fill(using: .copy)
        }
    }
    @nonobjc func makeMenu() -> NSMenu {
        let menu = NSMenu(title: "AI Token View"); menu.autoenablesItems = false
        func item(_ title: String, _ action: Selector = #selector(emptyEvent(_:)), enabled: Bool = true) {
            let entry = NSMenuItem(title: title, action: action, keyEquivalent: "")
            entry.target = self; entry.isEnabled = enabled; menu.addItem(entry)
        }
        let snapshot = source.viewSnapshot(), providers = snapshot.ordered
        item("Session Statistics", enabled: false)
        item("  Prompt: \(Self.compactCount(observer.sessionPromptTokens)) tokens")
        item("  Completion: \(Self.compactCount(observer.sessionCompletionTokens)) tokens")
        item("  Total: \(Self.compactCount(observer.sessionTotalTokens)) tokens")
        menu.addItem(.separator()); item("Daily Statistics", enabled: false)
        let daily = observer.dailyTotalTokens, budget = settings?.aiTokensDailyBudget ?? 0
        item("  Total: \(Self.compactCount(daily)) tokens")
        if budget > 0 { item("  Budget: \(Self.compactCount(daily)) / \(Self.compactCount(UInt64(budget))) (" + String(format: "%.1f%%)", Double(daily) / Double(budget) * 100)) }
        if snapshot.totalCost.isFinite && snapshot.totalCost > 0.001 {
            menu.addItem(.separator()); item("Cost Intelligence", enabled: false)
            item(String(format: "  Total Cost: $%.4f", snapshot.totalCost))
            if snapshot.costPerHour.isFinite && snapshot.costPerHour > 0.001 {
                item(String(format: "  Burn Rate: $%.4f/hr", snapshot.costPerHour))
                if snapshot.projectedDailyCost.isFinite { item(String(format: "  Projected 24hr: $%.4f", snapshot.projectedDailyCost)) }
            }
            for provider in providers where provider.cost.isFinite && provider.cost > 0.001 { item(String(format: "  %@: $%.4f", provider.provider.name, provider.cost)) }
        }
        if snapshot.ollamaAvailable {
            menu.addItem(.separator()); item("Ollama Local Inference", enabled: false); item("  " + snapshot.ollamaStatus)
            if !snapshot.runningModels.isEmpty {
                item("  Running Models:", enabled: false)
                for name in snapshot.runningModels { item("    " + name) }
            }
        }
        if settings?.aiTokensAggregateByModel == true, !observer.dailyByModel.isEmpty {
            menu.addItem(.separator()); item("By Model", enabled: false)
            for key in observer.dailyByModel.keys.sorted() { item("  \(key): \(Self.compactCount(observer.dailyByModel[key]?.uint64Value ?? 0)) tokens") }
        }
        if settings?.aiTokensAggregateByProvider == true, !observer.dailyByProvider.isEmpty {
            menu.addItem(.separator()); item("By Provider", enabled: false)
            for key in observer.dailyByProvider.keys.sorted() { item("  \(key): \(Self.compactCount(observer.dailyByProvider[key]?.uint64Value ?? 0)) tokens") }
        }
        menu.addItem(.separator()); item("Reset Daily Counters", #selector(resetDailyCounters(_:)))
        item("Open Database Location...", #selector(openDatabaseLocation(_:)))
        return menu
    }
    public override func menu(for event: NSEvent) -> NSMenu? { makeMenu() }
    public func formatNumber(_ number: UInt64) -> String { Self.compactCount(number) }
    public func emptyEvent(_ sender: Any?) {}
    public func resetDailyCounters(_ sender: Any?) { observer.resetDaily(); updateLabels(); needsDisplay = true }
    public func openDatabaseLocation(_ sender: Any?) { _ = openURL(databaseURL) }
    public override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
    public override func mouseDown(with event: NSEvent) { window?.mouseDown(with: event) }
    public override func mouseDragged(with event: NSEvent) { window?.mouseDragged(with: event) }
    public override func mouseUp(with event: NSEvent) { window?.mouseUp(with: event) }
}
