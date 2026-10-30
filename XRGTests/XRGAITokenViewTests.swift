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
import Testing
@testable import XRGCore

@MainActor private final class AITokenPanelHost: NSWindow, XRGAITokenViewHost, XRGModuleWindow {
    var appSettings: XRGSettings?
    var moduleManager: XRGModuleManager?
    var aiTokenView: XRGAITokenView?
    var minimized = false
    var borderWidth: Int32 = 2
    var timerRequests = 0
    var mouseEvents: [String] = []
    init(settings: XRGSettings) {
        appSettings = settings
        super.init(contentRect: NSRect(x: 0, y: 0, width: 320, height: 240), styleMask: .borderless, backing: .buffered, defer: false)
        isReleasedWhenClosed = false; moduleManager = XRGModuleManager(window: self)
    }
    func initTimers() { timerRequests += 1 }
    func checkWindowSize() {}
    override func mouseDown(with event: NSEvent) { mouseEvents.append("down") }
    override func mouseDragged(with event: NSEvent) { mouseEvents.append("drag") }
    override func mouseUp(with event: NSEvent) { mouseEvents.append("up") }
}
private final class AITokenPanelNibOwner: NSObject {}

@MainActor final class AITokenPanelSource: XRGAITokenViewSource {
    var usageEventHandler: ((String, XRGTokenAccounting.Delta) -> Void)?
    var pauses = 0
    var holdCompletion = false
    var pendingCompletions: [() -> Void] = []
    func requestLatestTokenInfo(completion: @escaping () -> Void) {
        getLatestTokenInfo()
        if holdCompletion { pendingCompletions.append(completion) } else { completion() }
    }
    var onUpdate: (() -> Void)?
    func pauseCollection() { pauses += 1 }
    var accountingResets = 0
    var trackingStates: [Bool] = []
    func resetAccountingBaseline() { accountingResets += 1 }
    func setAccountingEnabled(_ enabled: Bool) { trackingStates.append(enabled) }
    var now: TimeInterval = 0
    var updates = 0
    var sizes: [Int] = []
    var state = XRGAITokenViewSnapshot()
    init() {
        state.providers = XRGAIViewProvider.allCases.map { kind in
            XRGAIViewProviderData(provider: kind, history: XRGDataSet(), rate: UInt64(kind.rawValue + 1) * 100,
                                 total: UInt64(kind.rawValue + 1) * 1000, cost: kind == .ollama ? 0 : Double(kind.rawValue + 1))
        }
        state.ollamaAvailable = true; state.ollamaStatus = "Ollama: Ready (2 models)"
        state.runningModels = ["local-model", "another-model"]
        state.hermesModels = ["Zeta": ["input": 500, "output": 100], "Alpha": ["input": 1000, "output": 500], "Other model": ["input": 300, "output": 300]]
        state.totalCost = 20; state.costPerHour = 2; state.projectedDailyCost = 48
    }
    func resizeHistory(_ count: Int) { sizes.append(count); for provider in state.providers { provider.history.resize(count, fillingWith: XRGGraphRenderer.missingValue) } }
    func setDataSize(_ count: Int) { sizes.append(count); for provider in state.providers { provider.history.resize(count) } }
    func getLatestTokenInfo() { updates += 1; onUpdate?() }
    func viewSnapshot() -> XRGAITokenViewSnapshot { state }
    func seed() { for item in state.providers { item.history.setAllValues(CGFloat(item.rate)) } }
}

@Suite(.serialized) @MainActor
struct XRGAITokenViewTests {
    @Test func codexDetailsKeepCumulativeSplitsAndModelEvidenceSeparateFromObservedCounters() throws {
        try withFixture { settings,defaults,observer,source in
            let index = try #require(source.state.providers.firstIndex { $0.provider == .codex })
            source.state.providers[index].recordedUsage = XRGTokenUsage(input:60,output:30,total:100)
            source.state.providers[index].recordedModels = ["turn-model":70]
            let view = panel(settings,defaults,observer,source)
            let titles = view.makeMenu().items.map(\.title)
            #expect(titles.contains("Codex Log Snapshot") && titles.contains("Recorded input: 60 tokens"))
            #expect(titles.contains("Recorded output: 30 tokens") && titles.contains("Unknown split: 10 tokens"))
            #expect(titles.contains("  turn-model: 70 tokens") && titles.contains("Unattributed model: 30 tokens"))
            #expect(observer.sessionTotalTokens == 0 && observer.dailyTotalTokens == 0)
            source.state.providers[index].recordedSnapshotStale = true
            #expect(view.makeMenu().items.contains { $0.title == "Last Codex scan failed; showing cached snapshot" })
            #expect(view.fullReading().contains("Recorded turn models (not backend confirmation)"))
            settings.aiTokensAggregateByModel = false
            #expect(!view.makeMenu().items.contains { $0.title.contains("turn-model") })
            #expect(view.makeMenu().items.contains { $0.title == "Recorded input: 60 tokens" })
            source.state.providers[index].recordedUsage = nil
            #expect(!view.makeMenu().items.contains { $0.title == "Codex Log Snapshot" })
        }
    }
    @Test func retentionPreservesCurrentRatesCadenceAccountingAndIndependentGapSafeStacks() throws {
        try withFixture { settings, defaults, observer, source in
            let view = panel(settings, defaults, observer, source); source.seed()
            view.graphUpdate(nil)
            source.usageEventHandler?("Codex", .init(usage: .init(total: 30), models: [:]))
            let rates = source.state.providers.map(\.rate), totals = source.state.providers.map(\.total)
            let reads = source.updates, resets = source.accountingResets, pauses = source.pauses
            let option = NSMenuItem(); option.tag = 300; view.selectHistory(option)
            #expect(source.state.providers.allSatisfy { $0.history.numValues == 300 && $0.history.orderedValues.first == XRGGraphRenderer.missingValue })
            #expect(source.state.providers.map(\.rate) == rates && source.state.providers.map(\.total) == totals)
            #expect(source.updates == reads && source.accountingResets == resets && source.pauses == pauses)
            #expect(observer.sessionTotalTokens == 30 && observer.dailyTotalTokens == 30)
            let layers = view.historyLayers()
            #expect(layers.allSatisfy { $0.data.orderedValues.first == XRGGraphRenderer.missingValue })
            #expect(layers.first?.data.currentValue == 1500)
            view.setFrameSize(NSSize(width: 60, height: 90)); #expect(source.sizes.last == 300)
            #expect(view.historyDescription.contains("1495 seconds"))
            source.now = 4.9; view.graphUpdate(nil); #expect(source.updates == reads)
            source.now = 5; view.graphUpdate(nil); #expect(source.updates == reads + 1)
            option.tag = 20001; view.selectHistory(option); #expect(view.retainedSamples == 300)
            option.tag = 1; view.selectHistory(option)
            #expect(source.state.providers.allSatisfy { $0.history.numValues == 1 && $0.history.currentValue > 0 })
            #expect(observer.sessionTotalTokens == 30 && observer.dailyTotalTokens == 30)
            option.tag = 0; view.selectHistory(option); #expect(source.sizes.last == 41)
            let menu = try #require(view.makeMenu().items.first { $0.title == "AI History" }?.submenu)
            #expect(menu.items.allSatisfy { $0.target === view })
        }
    }
    @Test func savedAIHistoryRestoresCustomCountsAndKeepsNewPaddingUnavailable() throws {
        try withFixture { settings, defaults, observer, source in
            defaults.set(257, forKey: XRGAITokenView.historyKey)
            let view = panel(settings, defaults, observer, source)
            #expect(source.sizes.last == 257 && view.retainedSamples == 257 && source.updates == 0)
            #expect(view.historyLayers().allSatisfy { $0.data.orderedValues.allSatisfy { $0 == XRGGraphRenderer.missingValue } })
            let menu = try #require(view.makeMenu().items.first { $0.title == "AI History" }?.submenu)
            #expect(menu.items.contains { $0.tag == 257 && $0.state == .on })
            #expect(view.historyDescription.contains("1280 seconds"))
        }
    }
    private func withFixture(_ body: (XRGSettings, UserDefaults, XRGAITokensObserver, AITokenPanelSource) throws -> Void) throws {
        _ = NSApplication.shared
        let domain = "XRG.aiTokenView.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: domain))
        defer { defaults.removePersistentDomain(forName: domain) }
        defaults.set(true, forKey: "showAITokenGraph"); defaults.set(true, forKey: "aiTokensTrackingEnabled")
        defaults.set(true, forKey: "aiTokensAggregateByModel"); defaults.set(true, forKey: "aiTokensAggregateByProvider")
        defaults.set(true, forKey: "aiTokensShowRate"); defaults.set(true, forKey: "aiTokensShowBreakdown")
        let observer = XRGAITokensObserver(defaults: defaults, center: NotificationCenter(), calendar: .current, now: Date.init)
        let settings = XRGSettings(defaults: defaults)
        settings.graphFont = NSFont.systemFont(ofSize: 10)
        settings.textTransparency = 1; settings.textColor = .black
        settings.graphBGTransparency = 1; settings.graphBGColor = .white
        settings.graphFG1Transparency = 1; settings.graphFG1Color = .red
        settings.graphFG2Transparency = 1; settings.graphFG2Color = .blue
        settings.graphFG3Transparency = 1; settings.graphFG3Color = .green
        settings.borderTransparency = 1; settings.borderColor = .gray; settings.graphStyle = 0
        try body(settings, defaults, observer, AITokenPanelSource())
    }
    private func panel(_ settings: XRGSettings, _ defaults: UserDefaults, _ observer: XRGAITokensObserver,
                       _ source: AITokenPanelSource, width: CGFloat = 240, height: CGFloat = 300) -> XRGAITokenView {
        XRGAITokenView(frame: NSRect(x: 0, y: 0, width: width, height: height), source: source, observer: observer,
            settings: settings, defaults: defaults, databaseURL: URL(fileURLWithPath: "/tmp/xrg-ai-fixture/monitoring"), now: { source.now })
    }
    private func png(_ view: XRGAITokenView) throws -> Data {
        view.needsDisplay = true
        let bitmap = try #require(view.bitmapImageRepForCachingDisplay(in: view.bounds))
        view.cacheDisplay(in: view.bounds, to: bitmap)
        return try #require(bitmap.representation(using: .png, properties: [:]))
    }

    @Test func redrawFrequencyDoesNotChangeSamplingAndResetWakesImmediately() throws {
        try withFixture { settings,defaults,observer,source in
            let view=panel(settings,defaults,observer,source)
            view.graphUpdate(nil)
            for tick in 1..<50 { source.now=Double(tick)/10;view.graphUpdate(nil) }
            #expect(source.updates == 1)
            source.now=5;view.graphUpdate(nil);view.graphUpdate(nil)
            #expect(source.updates == 2)
            source.now=120;view.graphUpdate(nil);view.graphUpdate(nil)
            #expect(source.updates == 3)
            view.resetSessionCounters(nil)
            #expect(source.updates == 4 && source.accountingResets == 2)
            #expect(view.makeMenu().items.contains { $0.title == "AI sampling: nominal 5 seconds, independent of graph refresh" })
        }
    }

    @Test func pendingCollectionCoalescesTicksAndLateCompletionCannotReleaseANewerCycle() throws {
        try withFixture { settings,defaults,observer,source in
            source.holdCompletion=true
            let view=panel(settings,defaults,observer,source)
            view.graphUpdate(nil)
            source.now=30
            for _ in 0..<10 {view.graphUpdate(nil)}
            #expect(source.updates == 1 && source.pendingCompletions.count == 1)
            view.suspendCollection();view.graphUpdate(nil)
            #expect(source.updates == 2 && source.pendingCompletions.count == 2)
            source.pendingCompletions.removeFirst()()
            source.now=35;view.graphUpdate(nil)
            #expect(source.updates == 2)
            source.pendingCompletions.removeFirst()();view.graphUpdate(nil)
            #expect(source.updates == 3)
        }
    }

    @Test func hiddenAccountingDeliversBudgetThroughTheInjectedNotificationTransport() async throws {
        _ = NSApplication.shared
        let suite = "XRG.hidden-budget." + UUID().uuidString
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        defaults.set(false, forKey: "showAITokenGraph")
        defaults.set(true, forKey: "aiTokensTrackingEnabled")
        defaults.set(true, forKey: "aiTokensDailyAutoReset")
        defaults.set(10, forKey: "aiTokensDailyBudget")
        defaults.set(80, forKey: "aiTokensBudgetNotifyPercent")
        let settings = XRGSettings(defaults: defaults)
        settings.graphFont = NSFont.systemFont(ofSize: 10)
        let center = NotificationCenter()
        let observer = XRGAITokensObserver(defaults: defaults, center: center, calendar: .current, now: Date.init)
        let source = AITokenPanelSource()
        var delivered: [Double] = []
        let transport = XRGAIBudgetNotifications(events: center, authorized: { true }, deliver: { delivered.append($0) })
        transport.start(); defer { transport.stop() }
        let host = AITokenPanelHost(settings: settings); defer { host.close() }
        let view = panel(settings, defaults, observer, source)
        source.onUpdate = { [weak source] in source?.usageEventHandler?("Codex", .init(usage: .init(total: 5), models: [:])) }
        host.contentView?.addSubview(view); view.awakeFromNib()
        let manager = try #require(host.moduleManager)
        manager.windowChanged(to: host.frame.size)
        manager.graphUpdate(); source.now=5; manager.graphUpdate(); source.now=10; manager.graphUpdate()
        for _ in 0..<100 { if !delivered.isEmpty { break }; try await Task.sleep(for: .milliseconds(5)) }
        #expect(delivered == [100] && observer.dailyTotalTokens == 15 && view.isHidden)
        view.suspendCollection()
    }

    @Test func hiddenGraphCollectsOnlyWhileTrackingAndNeverDoubleDispatches() throws {
        try withFixture { settings, defaults, observer, source in
            defaults.set(false, forKey: "showAITokenGraph")
            defaults.set(false, forKey: "aiTokensTrackingEnabled")
            let host = AITokenPanelHost(settings: settings)
            defer { host.close() }
            let view = panel(settings, defaults, observer, source)
            host.contentView?.addSubview(view); view.awakeFromNib()
            let manager = try #require(host.moduleManager)
            #expect(view.module?.alwaysDoesGraphUpdate == true)
            manager.windowChanged(to: host.frame.size)
            #expect(view.isHidden && view.frame.size == .zero)
            source.onUpdate = { [weak source] in
                source?.usageEventHandler?("Codex", .init(usage: .init(total: 5), models: [:]))
            }
            manager.graphUpdate()
            #expect(source.updates == 0 && observer.sessionTotalTokens == 0)
            defaults.set(true, forKey: "aiTokensTrackingEnabled")
            manager.graphUpdate(); source.now=5; manager.graphUpdate()
            #expect(source.updates == 2 && observer.dailyTotalTokens == 10)
            host.minimized = true; source.now=10; manager.graphUpdate()
            #expect(source.updates == 3 && observer.sessionTotalTokens == 15)
            defaults.set(false, forKey: "aiTokensTrackingEnabled")
            manager.graphUpdate(); manager.graphUpdate()
            #expect(source.updates == 3 && source.pauses == 1 && observer.dailyTotalTokens == 15)
            host.minimized = false
            manager.setModule("AI Tokens", isDisplayed: true)
            #expect(source.updates == 4 && observer.dailyTotalTokens == 15)
            source.now=15; manager.graphUpdate()
            #expect(source.updates == 5) // visible + always-update is still one recipient.
            view.removeFromSuperview()
            #expect(source.pauses == 2)
            manager.graphUpdate(); #expect(source.updates == 5)
        }
    }

    @Test func programmaticRegistrationVisibilityFontAndDetachment() throws {
        try withFixture { settings, defaults, observer, source in
            defaults.set(false, forKey: "showAITokenGraph")
            let host = AITokenPanelHost(settings: settings)
            defer { host.close() }
            let view = panel(settings, defaults, observer, source, width: 200, height: 100)
            host.contentView?.addSubview(view); view.awakeFromNib(); view.awakeFromNib()
            let module = try #require(view.module)
            #expect(module.name == "AI Tokens" && module.displayOrder == 10)
            #expect(module.doesGraphUpdate && !module.doesFastUpdate && !module.doesMin5Update && !module.doesMin30Update)
            #expect(!module.isDisplayed && host.aiTokenView === view && module.reference === view)
            #expect(host.moduleManager?.moduleList().count == 1 && host.timerRequests == 1 && source.updates == 0)
            let width = module.minWidth
            settings.graphFont = NSFont.systemFont(ofSize: 28); view.updateMinSize()
            #expect(module.minWidth > width)
            host.moduleManager?.setModule("AI Tokens", isDisplayed: true)
            #expect(source.updates == 1)
            view.removeFromSuperview()
            #expect(view.module == nil && host.aiTokenView == nil && host.moduleManager?.moduleList().isEmpty == true)
        }
    }

    @Test func replacementAndManagerChangesRemoveOnlyTheOwnedModule() throws {
        try withFixture { settings, defaults, observer, source in
            let host = AITokenPanelHost(settings: settings)
            defer { host.close() }
            let first = panel(settings, defaults, observer, source), second = panel(settings, defaults, observer, AITokenPanelSource())
            host.contentView?.addSubview(first); first.awakeFromNib()
            host.contentView?.addSubview(second); second.awakeFromNib()
            first.removeFromSuperview()
            #expect(host.aiTokenView === second && host.moduleManager?.moduleList().first === second.module)
            let old = try #require(host.moduleManager)
            host.moduleManager = XRGModuleManager(window: host); second.awakeFromNib()
            #expect(old.moduleList().isEmpty && host.moduleManager?.moduleList().count == 1)
            second.removeFromSuperview()
        }
    }

    @Test func allFiveStacksReuseOwnedCachesAndLeaveSourceHistoriesUnchanged() throws {
        try withFixture { settings, defaults, observer, source in
            let view = panel(settings, defaults, observer, source); source.seed()
            let before = source.state.providers.map { $0.history.orderedValues }
            let layers = view.historyLayers()
            #expect(layers.map(\.provider) == [.hermes, .ollama, .gemini, .codex, .claude])
            #expect(layers.map { $0.data.currentValue } == [1500, 1000, 600, 300, 100])
            let again = view.historyLayers()
            #expect(zip(layers, again).allSatisfy { $0.data === $1.data })
            #expect(source.state.providers.map { $0.history.orderedValues } == before)
            #expect(!source.state.providers.contains { source in layers.contains { $0.data === source.history } })
            #expect(view.color(for: .claude) == settings.graphFG1Color && view.color(for: .codex) == settings.graphFG2Color)
            #expect(view.color(for: .gemini) == settings.graphFG3Color)
            #expect(view.color(for: .ollama) == settings.graphFG3Color.blended(withFraction: 0.5, of: settings.graphFG1Color))
            #expect(view.color(for: .hermes) == settings.graphFG2Color.blended(withFraction: 0.5, of: settings.graphFG3Color))
        }
    }

    @Test func fullReadingRetainsProvidersHermesModelsCountersAndBudgetWithoutGraphCosts() throws {
        try withFixture { settings, defaults, observer, source in
            observer.recordEvent(promptTokens: 1200, completionTokens: 300, model: "Model Z", provider: "Provider Z")
            settings.aiTokensDailyBudget = 2000
            let view = panel(settings, defaults, observer, source)
            let text = view.fullReading()
            #expect(text.hasPrefix("AI Tokens\n─ Providers ─\n● Claude: 1K\n● Codex: 2K\n● Gemini: 3K\n● Ollama: Ready (2 models)\n● Hermes: 5.0K"))
            #expect(text.contains("    Alpha: 1.5K\n    Other model: 600\n    Zeta: 600"))
            #expect(text.contains("Total: 15.0K") && text.contains("● O: 4.0K") && text.contains("Rate: 1K/s"))
            #expect(text.contains("Session: 1K\nDaily: 1K/2K (75%)"))
            #expect(text.contains("─ By Model ─\nModel Z: 1K\n─ By Provider ─\nProvider Z: 1K"))
            #expect(!text.contains("Cost") && !text.contains("$"))
            #expect(view.graphLabels.leftLabel.accessibilityValue() == text)
        }
    }

    @Test func displayFlagsUseTheInjectedSettingsAndClearStaleSections() throws {
        try withFixture { settings, defaults, observer, source in
            observer.recordEvent(promptTokens: 100, completionTokens: 50, model: "model", provider: "provider")
            let view = panel(settings, defaults, observer, source)
            settings.aiTokensShowRate = false; settings.aiTokensShowBreakdown = false; settings.aiTokensDailyBudget = -1
            view.updateMinSize()
            #expect(!view.fullReading().contains("Rate:") && !view.fullReading().contains("─ By Model ─") && !view.fullReading().contains("─ By Provider ─"))
            #expect(view.fullReading().contains("Daily: 150"))
            settings.aiTokensShowBreakdown = true; settings.aiTokensAggregateByModel = false
            #expect(!view.fullReading().contains("─ By Model ─") && view.fullReading().contains("─ By Provider ─"))
        }
    }

    @Test func hermesModelSortingIncludesAllModelsAndSaturatesTheirCounts() {
        let values = XRGAITokenView.hermesModelTotals([
            "Z": ["input": NSNumber(value: UInt64.max), "output": 1],
            "A": ["input": NSNumber(value: UInt64.max), "output": NSNumber(value: UInt64.max)],
            "Unknown vendor/model": ["input": 1, "output": 2], "Zero": [:]])
        #expect(values.map(\.0) == ["A", "Z", "Unknown vendor/model"])
        #expect(values.map(\.1) == [UInt64.max, UInt64.max, 3])
    }

    @Test func largeRatesAndTotalsDoNotWrapOrOverflowTheIndicator() throws {
        try withFixture { settings, defaults, observer, source in
            let view = panel(settings, defaults, observer, source)
            for index in source.state.providers.indices {
                source.state.providers[index].rate = UInt64(UInt32.max)
                source.state.providers[index].total = .max
            }
            #expect(view.fullReading().contains("Rate: 21474836K/s"))
            #expect(view.fullReading().contains("Total: 18446744073.71B"))
            for index in source.state.providers.indices { source.state.providers[index].rate = .max }
            let rect = NSRect(x: 10, y: 20, width: 240, height: 100), bars = view.indicatorRects(in: rect)
            #expect(bars.count == 5)
            #expect(bars.allSatisfy { $0.size.height.isFinite && $0.size.height >= 0 && rect.contains($0) })
            #expect(abs(bars.reduce(0) { $0 + $1.height } - view.historyRect(in: rect).height) < 0.0001)
        }
    }

    @Test func historyAndIndicatorKeepTheReservedStripAndRateProportions() throws {
        try withFixture { settings, defaults, observer, source in
            let view = panel(settings, defaults, observer, source)
            let rect = NSRect(x: 10, y: 20, width: 240, height: 100)
            let h = 100 - XRGGraphLabels.lineHeight(settings)
            #expect(view.historyRect(in: rect) == NSRect(x: 10, y: 20, width: 221, height: h))
            let bars = view.indicatorRects(in: rect)
            #expect(bars.count == 5 && bars[0].minX == 233 && bars.allSatisfy { $0.width == 8 })
            #expect(abs(bars[0].height - h / 15) < 0.0001)
            #expect(abs(bars[4].height - h / 3) < 0.0001)
            #expect(abs(bars.last!.maxY - (20 + h)) < 0.0001)
        }
    }

    @Test func resetsInvalidateAccountingWithoutClearingGraphHistory() throws {
        try withFixture { settings, defaults, observer, source in
            let view = panel(settings, defaults, observer, source)
            source.seed()
            let history = source.state.providers.map { $0.history.orderedValues }
            view.graphUpdate(nil)
            #expect(source.accountingResets == 1 && source.trackingStates == [true])
            observer.recordEvent(promptTokens: 10, completionTokens: 20, model: nil, provider: nil)
            view.resetSessionCounters(nil); view.graphUpdate(nil)
            #expect(source.accountingResets == 2 && observer.sessionTotalTokens == 0 && observer.dailyTotalTokens == 30)
            view.resetDailyCounters(nil); view.graphUpdate(nil)
            #expect(source.accountingResets == 3 && observer.dailyTotalTokens == 0)
            #expect(source.state.providers.map { $0.history.orderedValues } == history)
        }
    }

    @Test func usageCallbacksReachOnlyTheInjectedObserverWithoutRetainingTheView() throws {
        try withFixture { settings, defaults, observer, source in
            weak var released: XRGAITokenView?
            autoreleasepool {
                let view = panel(settings, defaults, observer, source)
                released = view; source.usageEventHandler?("Gemini", .init(usage: .init(input: 10, output: 20, total: 30), models: ["gemini-test": 30]))
                #expect(observer.sessionPromptTokens == 10 && observer.sessionCompletionTokens == 20)
                #expect(observer.dailyByModel["gemini-test"] == 30 && observer.dailyByProvider["Gemini"] == 30)
            }
            #expect(released == nil)
        }
    }

    @Test func currentMenusKeepCostsLocalStatusBreakdownsAndExplicitActions() throws {
        try withFixture { settings, defaults, observer, source in
            observer.recordEvent(promptTokens: 10, completionTokens: 20, model: "z-model", provider: "z-provider")
            observer.recordEvent(promptTokens: 20, completionTokens: 30, model: "a-model", provider: "a-provider")
            var opened: [URL] = []
            let location = URL(fileURLWithPath: "/tmp/xrg-private-fixture")
            let view = XRGAITokenView(frame: NSRect(x: 0, y: 0, width: 240, height: 300), source: source, observer: observer,
                settings: settings, defaults: defaults, databaseURL: location, openURL: { opened.append($0); return true })
            let menu = view.makeMenu(), titles = menu.items.map(\.title)
            #expect(titles.contains("Cost Intelligence") && titles.contains("  Mixed Cost (includes estimates): $20.0000"))
            #expect(titles.contains("  Estimated Change: $2.0000/hr") && titles.contains("  Extrapolated 24hr: $48.0000"))
            #expect(titles.contains("  Hermes: $5.0000 (source value (may include estimates))") && titles.contains("Ollama Local Inference") && titles.contains("    local-model"))
            let firstModel = try #require(titles.firstIndex(of: "  a-model: 50 tokens"))
            let lastModel = try #require(titles.firstIndex(of: "  z-model: 30 tokens"))
            #expect(firstModel < lastModel)
            #expect(menu.items.first?.isEnabled == false && !menu.autoenablesItems)
            for item in menu.items where !item.isSeparatorItem { #expect(item.target === view) }
            let open = try #require(menu.items.first { $0.title == "Open Database Location..." })
            let openAction = try #require(open.action)
            #expect(NSApp.sendAction(openAction, to: open.target, from: open))
            #expect(opened == [location])
            let reset = try #require(menu.items.first { $0.title == "Reset Daily Counters" })
            let resetAction = try #require(reset.action)
            #expect(NSApp.sendAction(resetAction, to: reset.target, from: reset))
            #expect(observer.dailyTotalTokens == 0 && observer.sessionTotalTokens == 80)
            #expect(source.state.providers[0].total == 1000 && view.fullReading().contains("Daily: 0"))
        }
    }

    @Test func costAndLocalSectionsDisappearWhenUnavailableOrNonfinite() throws {
        try withFixture { settings, defaults, observer, source in
            let view = panel(settings, defaults, observer, source)
            source.state.totalCost = .nan; source.state.ollamaAvailable = false; source.state.runningModels = []
            source.state.providers[3].total = 0
            view.graphUpdate(nil)
            #expect(!view.makeMenu().items.contains { $0.title == "Cost Intelligence" || $0.title == "Ollama Local Inference" })
            #expect(view.legendLabels.count == 4 && source.updates == 1)
            source.state.totalCost = 20; source.state.costPerHour = .infinity
            #expect(!view.makeMenu().items.contains { $0.title.contains("Estimated Change") })
            source.state.ollamaAvailable = true; view.graphUpdate(nil)
            #expect(view.legendLabels.count == 5)
        }
    }

    @Test(arguments: [CGFloat(10), 18, 28], [CGFloat(60), 100, 240])
    func fullAndClippedTextRetainEveryProviderAndLegendIdentity(font: CGFloat, width: CGFloat) throws {
        try withFixture { settings, defaults, observer, source in
            settings.graphFont = NSFont.systemFont(ofSize: font)
            let view = panel(settings, defaults, observer, source, width: width, height: 100)
            #expect(view.graphLabels.leftLabel.accessibilityValue() == view.fullReading())
            #expect(view.graphLabels.leftLabel.accessibilityValue()?.contains("Other model: 600") == true)
            #expect(view.accessibilityValue() as? String == view.fullReading())
            #expect(view.legendLabels.first?.accessibilityValue() == "Claude: 1.0K")
            for label in view.subviews { #expect(label.frame.size.width >= 0 && label.frame.size.height >= 0) }
        }
    }

    @Test func compactModeKeepsItsTotalAreaAndCompleteAccessibleSource() throws {
        try withFixture { settings, defaults, observer, source in
            let view = panel(settings, defaults, observer, source, height: 10); source.seed()
            #expect(view.shouldDrawMiniGraph() && view.graphLabels.leftLabel.isHidden)
            #expect(view.legendLabels.allSatisfy { $0.isHidden })
            #expect(view.accessibilityValue() as? String == view.fullReading())
            #expect(view.historyLayers().first?.data.currentValue == 1500)
            let mini = try png(view)
            settings.graphStyle = 3
            #expect(try png(view) == mini)
        }
    }

    @Test func emptyMismatchedAndZeroHistoriesStillShowStatisticsSafely() throws {
        try withFixture { settings, defaults, observer, source in
            let view = panel(settings, defaults, observer, source)
            #expect(view.historyLayers().first?.data.max == 0)
            _ = try png(view)
            source.state.providers[0].history.resize(0)
            #expect(view.historyLayers().isEmpty)
            view.updateMinSize()
            #expect(view.graphLabels.leftLabel.accessibilityValue()?.hasPrefix("AI Tokens") == true)
            _ = try png(view)
            source.state = XRGAITokenViewSnapshot(); view.graphUpdate(nil)
            #expect(view.historyLayers().isEmpty && view.indicatorRects(in: view.bounds).isEmpty && view.legendLabels.isEmpty)
            #expect(view.fullReading() == "AI Tokens\nSession: 0\nDaily: 0")
        }
    }

    @Test func sampleWidthsAndCollapsedGeometryStayBounded() throws {
        try withFixture { settings, defaults, observer, source in
            let view = panel(settings, defaults, observer, source, width: 200)
            #expect(source.sizes.last == 181 && source.updates == 0)
            view.setGraphSize(NSSize(width: CGFloat.greatestFiniteMagnitude, height: 0))
            #expect(source.sizes.last == 19_981)
            let sizes = source.sizes.count
            view.setWidth(18); view.setWidth(-1)
            #expect(source.sizes.count == sizes)
            view.setGraphSize(NSSize(width: CGFloat.nan, height: 0))
            #expect(source.sizes.last == 4)
            for height: CGFloat in [26, 47, 58, 69, 80] {
                view.setFrameSize(NSSize(width: 240, height: height))
                for label in view.legendLabels where !label.isHidden { #expect(view.bounds.contains(label.frame)) }
            }
            view.setFrameSize(.zero)
            #expect(view.historyRect(in: view.bounds).isEmpty && view.indicatorRects(in: view.bounds).isEmpty)
            for label in view.subviews { #expect(label.frame.size.width >= 0 && label.frame.size.height >= 0) }
        }
    }

    @Test func compiledNibInstantiatesTheRuntimeClassWithoutPollingProviders() throws {
        try withFixture { _, _, _, _ in
            let nib = try #require(NSNib(nibNamed: "AITokenView", bundle: Bundle(for: AITokenPanelNibOwner.self)))
            var objects: NSArray?
            #expect(nib.instantiate(withOwner: AITokenPanelNibOwner(), topLevelObjects: &objects))
            let view = try #require(objects?.compactMap { $0 as? XRGAITokenView }.first)
            #expect(view.module == nil && view.subviews.count == 3 && view.frame.size == NSSize(width: 76, height: 76))
            #expect(view.fullReading() == "AI Tokens")
            withExtendedLifetime(objects) {}
        }
    }

    @Test func productionMinerAdapterPreservesAllFiveSourcesAndUsageCallback() throws {
        try withFixture { settings, defaults, observer, _ in
            let miner = XRGAITokenMiner(home: "/nonexistent-xrg-ai-view-fixture", clock: { 0 })
            let view = XRGAITokenView(frame: NSRect(x: 0, y: 0, width: 240, height: 100), source: miner, observer: observer,
                settings: settings, defaults: defaults, databaseURL: URL(fileURLWithPath: "/tmp/xrg-ai-fixture"))
            miner.totalClaudeTokens = 100; miner.totalCodexTokens = 200; miner.totalGeminiTokens = 300
            miner.totalOllamaTokens = 400; miner.totalHermesTokens = 500
            #expect(miner.viewSnapshot().ordered.map(\.total) == [100, 200, 300, 400, 500])
            miner.hermesTokenData().setAllValues(50)
            #expect(view.historyLayers().first?.data.currentValue == 50)
            miner.usageEventHandler?("Gemini", .init(usage: .init(input: 5, output: 7, total: 12), models: [:]))
            #expect(observer.sessionTotalTokens == 12)
        }
    }

    @Test func fullGraphStylesRenderWithoutMutatingSourceSamples() throws {
        try withFixture { settings, defaults, observer, source in
            let view = panel(settings, defaults, observer, source); source.seed()
            let before = source.state.providers.map { $0.history.orderedValues }
            let normal = try png(view)
            settings.graphStyle = 1; #expect(try png(view) != normal)
            settings.graphStyle = 2; _ = try png(view)
            settings.graphStyle = 3; #expect(try png(view) != normal)
            #expect(source.state.providers.map { $0.history.orderedValues } == before)
        }
    }

    @Test func decimalCountFormattingRetainsBoundariesAndLargeValues() {
        #expect(XRGAITokenView.compactCount(999) == "999")
        #expect(XRGAITokenView.compactCount(1000) == "1.0K")
        #expect(XRGAITokenView.compactCount(1_500_000) == "1.5M")
        #expect(XRGAITokenView.integerCount(1999) == "1K")
        #expect(XRGAITokenView.preciseCount(1_234_567_890, billions: true) == "1.23B")
        #expect(XRGAITokenView.add(UInt64.max, 1) == UInt64.max)
    }

    @Test func mouseEventsStillReachTheWindow() throws {
        try withFixture { settings, defaults, observer, source in
            let host = AITokenPanelHost(settings: settings)
            defer { host.close() }
            let view = panel(settings, defaults, observer, source)
            host.contentView?.addSubview(view); view.awakeFromNib()
            let event = try #require(NSEvent.mouseEvent(with: .leftMouseDown, location: .zero, modifierFlags: [],
                timestamp: 0, windowNumber: host.windowNumber, context: nil, eventNumber: 1, clickCount: 1, pressure: 1))
            #expect(view.acceptsFirstMouse(for: event))
            view.mouseDown(with: event); view.mouseDragged(with: event); view.mouseUp(with: event)
            #expect(host.mouseEvents == ["down", "drag", "up"])
            view.removeFromSuperview()
        }
    }
}
