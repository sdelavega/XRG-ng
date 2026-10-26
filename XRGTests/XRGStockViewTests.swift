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

@MainActor private final class StockPanelHost: NSWindow, XRGStockViewHost, XRGModuleWindow {
    var appSettings: XRGSettings?
    var moduleManager: XRGModuleManager?
    var stockView: XRGStockView?
    var minimized = false
    var borderWidth: Int32 = 2
    var timerRequests = 0
    var preferencesOpened = 0
    var mouseEvents: [String] = []
    init(settings: XRGSettings) {
        appSettings = settings
        super.init(contentRect: NSRect(x: 0, y: 0, width: 320, height: 240), styleMask: .borderless, backing: .buffered, defer: false)
        isReleasedWhenClosed = false
        moduleManager = XRGModuleManager(window: self)
    }
    func initTimers() { timerRequests += 1 }
    func checkWindowSize() {}
    func showStockPreferences() { preferencesOpened += 1 }
    override func mouseDown(with event: NSEvent) { mouseEvents.append("down") }
    override func mouseDragged(with event: NSEvent) { mouseEvents.append("drag") }
    override func mouseUp(with event: NSEvent) { mouseEvents.append("up") }
}
private final class StockPanelNibOwner: NSObject {}

@MainActor private final class PanelStock: XRGStockViewData {
    var history: [NSNumber] = (1...24).map { NSNumber(value: $0) }
    var quote: [NSNumber]? = [25, 2]
    var gettingData = false
    var held = false
    var symbolRequests = 0
    var loadRequests = 0
    var resets = 0
    var cancellations = 0
    var symbol: String? {
        didSet {
            if symbol == nil { cancellations += 1; gettingData = false }
            else { symbolRequests += 1; gettingData = held }
        }
    }
    var label: String? { symbol }
    var haveGoodDisplayData: Bool { quote != nil || !history.isEmpty }
    func resetData() { resets += 1; gettingData = false }
    func loadData() { loadRequests += 1; gettingData = held }
    func get1MonthValues() -> [NSNumber]? { Array(history.suffix(history.count / 12)) }
    func get3MonthValues() -> [NSNumber]? { Array(history.suffix(history.count / 4)) }
    func get6MonthValues() -> [NSNumber]? { Array(history.suffix(history.count / 2)) }
    func get12MonthValues() -> [NSNumber]? { history }
    func getCurrentPriceAndChange() -> [NSNumber]? {
        if let quote { return quote }
        guard history.count >= 2, let last = history.last else { return nil }
        return [last, NSNumber(value: last.doubleValue - history[history.count - 2].doubleValue)]
    }
    func priceString() -> String { getCurrentPriceAndChange().map { String(format: "$%.2f", $0[0].doubleValue) } ?? "n/a" }
    func changeString() -> String {
        guard let change = getCurrentPriceAndChange()?[1].doubleValue else { return "n/a" }
        return change == 0 ? "unch" : String(format: "%@%.2f", change > 0 ? "▲" : "▼", abs(change))
    }
}
@MainActor private final class PanelStockFactory {
    var created: [PanelStock] = []
    var held = false
    func make() -> PanelStock {
        let stock = PanelStock(); stock.held = held; created.append(stock); return stock
    }
}

@Suite(.serialized) @MainActor
struct XRGStockViewTests {
    private func withFixture(_ body: (XRGSettings, UserDefaults, PanelStockFactory) async throws -> Void) async throws {
        _ = NSApplication.shared
        let domain = "XRG.stockView.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: domain))
        defer { defaults.removePersistentDomain(forName: domain) }
        defaults.set(true, forKey: "showStockGraph")
        let settings = XRGSettings(defaults: defaults)
        settings.graphFont = NSFont.systemFont(ofSize: 10)
        settings.textTransparency = 1; settings.textColor = .black
        settings.graphBGTransparency = 1; settings.graphBGColor = .white
        settings.graphFG1Transparency = 1; settings.graphFG1Color = .red
        settings.graphFG2Transparency = 1; settings.graphFG2Color = .blue
        settings.graphFG3Transparency = 1; settings.graphFG3Color = .green
        settings.graphStyle = 0; settings.stockSymbols = "AAA,BBB"; settings.stockGraphTimeFrame = 3
        settings.stockShowChange = true; settings.showDJIA = true
        try await body(settings, defaults, PanelStockFactory())
    }
    private func panel(_ settings: XRGSettings, _ defaults: UserDefaults, _ factory: PanelStockFactory,
                       width: CGFloat = 240, height: CGFloat = 160) -> XRGStockView {
        XRGStockView(frame: NSRect(x: 0, y: 0, width: width, height: height), settings: settings,
            defaults: defaults, makeStock: { factory.make() })
    }
    private func png(_ view: XRGStockView) throws -> Data {
        view.needsDisplay = true
        let bitmap = try #require(view.bitmapImageRepForCachingDisplay(in: view.bounds))
        view.cacheDisplay(in: view.bounds, to: bitmap)
        return try #require(bitmap.representation(using: .png, properties: [:]))
    }

    @Test func registrationFontVisibilityAndDetachmentOwnOneTicker() async throws {
        try await withFixture { settings, defaults, factory in
            let host = StockPanelHost(settings: settings)
            defer { host.close() }
            let view = panel(settings, defaults, factory)
            host.contentView?.addSubview(view); view.awakeFromNib(); view.awakeFromNib()
            let module = try #require(view.module), timer = try #require(view.tickerTimer)
            #expect(module.name == "Stock" && module.displayOrder == 8)
            #expect(module.doesGraphUpdate && !module.doesFastUpdate && module.doesMin30Update && !module.doesMin5Update)
            #expect(module.isDisplayed && module.reference === view && host.stockView === view)
            #expect(host.moduleManager?.moduleList().count == 1 && host.timerRequests == 1)
            #expect(factory.created.count == 3 && factory.created.allSatisfy { $0.symbolRequests == 1 && $0.loadRequests == 0 })
            #expect(view.djia?.symbol == "^DJI" && timer.timeInterval == 2)
            let width = module.minWidth
            settings.graphFont = NSFont.systemFont(ofSize: 28); view.updateMinSize()
            #expect(module.minWidth > width)
            view.removeFromSuperview()
            #expect(!timer.isValid && view.tickerTimer == nil && view.module == nil && host.stockView == nil)
            #expect(host.moduleManager?.moduleList().isEmpty == true)
            #expect(factory.created.allSatisfy { $0.symbol == nil })
        }
    }

    @Test func hiddenPanelsDeferRequestsAndResumeWithFreshSnapshots() async throws {
        try await withFixture { settings, defaults, factory in
            defaults.set(false, forKey: "showStockGraph"); factory.held = true
            let host = StockPanelHost(settings: settings)
            defer { host.close() }
            let view = panel(settings, defaults, factory)
            host.contentView?.addSubview(view); view.awakeFromNib()
            view.min30Update(nil); view.graphUpdate(nil)
            #expect(factory.created.isEmpty && view.tickerTimer == nil)
            settings.stockSymbols = "NEW"; view.setStockSymbolsFromString(settings.stockSymbols)
            #expect(factory.created.isEmpty)
            host.moduleManager?.setModule("Stock", isDisplayed: true)
            #expect(factory.created.count == 2 && view.gettingData && view.tickerTimer != nil)
            let old = factory.created
            host.moduleManager?.setModule("Stock", isDisplayed: false); view.ticker()
            #expect(view.tickerTimer == nil && old.allSatisfy { !$0.gettingData && $0.resets == 1 })
            host.moduleManager?.setModule("Stock", isDisplayed: true)
            #expect(factory.created.count == 4 && view.gettingData && view.djia?.gettingData == true)
            #expect(old.allSatisfy { $0.symbol == nil })
            view.removeFromSuperview()
        }
    }

    @Test func replacementAndManagerChangesPreserveTheNewRegistration() async throws {
        try await withFixture { settings, defaults, factory in
            let host = StockPanelHost(settings: settings)
            defer { host.close() }
            let first = panel(settings, defaults, factory), second = panel(settings, defaults, factory)
            host.contentView?.addSubview(first); first.awakeFromNib()
            host.contentView?.addSubview(second); second.awakeFromNib()
            first.removeFromSuperview()
            #expect(host.stockView === second && host.moduleManager?.moduleList().first === second.module)
            let old = try #require(host.moduleManager)
            host.moduleManager = XRGModuleManager(window: host); second.awakeFromNib()
            #expect(old.moduleList().isEmpty && host.moduleManager?.moduleList().count == 1)
            second.removeFromSuperview()
        }
    }

    @Test func detachedPanelIsNotRetainedByItsScheduledTimer() async throws {
        try await withFixture { settings, defaults, factory in
            let host = StockPanelHost(settings: settings)
            defer { host.close() }
            weak var released: XRGStockView?
            var timer: Timer?
            autoreleasepool {
                let view = panel(settings, defaults, factory)
                host.contentView?.addSubview(view); view.awakeFromNib()
                released = view; timer = view.tickerTimer
                view.removeFromSuperview()
            }
            #expect(released == nil && timer?.isValid == false)
        }
    }

    @Test func symbolParsingHandlesWhitespaceIndicesAndUnicodeWithoutByteCorruption() {
        #expect(XRGStockView.parseSymbols(" aapl, \t brk.b,, ^dji, 日本株, aapl\n") == ["AAPL", "BRK.B", "^DJI", "日本株", "AAPL"])
        #expect(XRGStockView.parseSymbols("\r\n, \t,").isEmpty)
    }

    @Test func shrinkingOrClearingSymbolsResetsRotationAndCancelsOldRequests() async throws {
        try await withFixture { settings, defaults, factory in
            let view = panel(settings, defaults, factory); view.reloadStockData()
            for _ in 0..<15 { view.ticker() }
            #expect(view.stockToShow == 1)
            let old = factory.created
            settings.stockSymbols = "ONLY"; view.setStockSymbolsFromString(settings.stockSymbols)
            #expect(view.stockToShow == 0 && view.stockObjects.count == 1)
            #expect(old.allSatisfy { $0.symbol == nil })
            #expect(view.stockObjects.first?.symbol == "ONLY")
            view.setStockSymbolsFromString(nil)
            #expect(view.stockObjects.isEmpty && view.djia == nil && !view.gettingData)
            #expect(view.statusLabels.leftLabel.accessibilityValue() == "No Stocks\nFound")
        }
    }

    @Test func reloadCadenceDoesNotDuplicateInitialOrPeriodicRequests() async throws {
        try await withFixture { settings, defaults, factory in
            let view = panel(settings, defaults, factory)
            view.min30Update(nil)
            #expect(factory.created.count == 3 && view.slowPhase == 1)
            for _ in 0..<3 { view.min30Update(nil) }
            #expect(factory.created.allSatisfy { $0.loadRequests == 0 })
            view.min30Update(nil)
            #expect(factory.created.allSatisfy { $0.loadRequests == 1 && $0.resets == 1 })
            view.updateNow(nil)
            #expect(factory.created.allSatisfy { $0.loadRequests == 2 })
            #expect(view.slowPhase == 1)
        }
    }

    @Test func loadingWaitsForAllRequestedSymbolsAndOnlyRotatesEveryFifteenTicks() async throws {
        try await withFixture { settings, defaults, factory in
            factory.held = true
            let view = panel(settings, defaults, factory); view.reloadStockData()
            #expect(!view.dataIsReady() && view.statusLabels.leftLabel.accessibilityValue() == "Fetching Data")
            factory.created[0].gettingData = false; factory.created[1].gettingData = false
            view.ticker()
            #expect(view.stockToShow == 0 && !view.dataIsReady())
            factory.created[2].gettingData = false; view.ticker()
            #expect(view.dataIsReady() && view.stockToShow == 0)
            for _ in 0..<13 { view.ticker() }
            #expect(view.stockToShow == 1)
            for _ in 0..<15 { view.ticker() }
            #expect(view.stockToShow == 0)
        }
    }

    @Test func djiaToggleStartsOneRawIndexRequestAndCancelsItWhenDisabled() async throws {
        try await withFixture { settings, defaults, factory in
            settings.showDJIA = false
            let view = panel(settings, defaults, factory); view.reloadStockData()
            #expect(factory.created.count == 2 && view.djia == nil)
            settings.showDJIA = true; view.graphUpdate(nil)
            let index = try #require(factory.created.last)
            #expect(factory.created.count == 3 && index.symbol == "^DJI")
            view.graphUpdate(nil)
            #expect(factory.created.count == 3)
            settings.showDJIA = false; view.graphUpdate(nil)
            #expect(view.djia == nil && index.symbol == nil && view.plots().count == 1)
        }
    }

    @Test(arguments: [0, 1, 2, 3])
    func allPeriodsRetainTheirSamplesScalePaddingAndOverlay(timeFrame: Int) async throws {
        try await withFixture { settings, defaults, factory in
            settings.stockGraphTimeFrame = timeFrame
            let view = panel(settings, defaults, factory); view.reloadStockData()
            let plot = try #require(view.plots().first)
            let count = [2, 6, 12, 24][timeFrame]
            #expect(plot.values.count == count && plot.values.last == 24)
            #expect(abs(plot.lower - (25 - CGFloat(count) - CGFloat(count - 1) * 0.1)) < 0.0001)
            #expect(abs(plot.upper - (24 + CGFloat(count - 1) * 0.1)) < 0.0001)
            #expect(plot.filled && view.plots().last?.filled == false)
            #expect(view.timeFrameText == ["1m", "3m", "6m", "1y"][timeFrame])
        }
    }

    @Test func flatMissingAndNonfiniteHistoriesDoNotHideValidQuotes() async throws {
        try await withFixture { settings, defaults, factory in
            let view = panel(settings, defaults, factory); view.reloadStockData()
            let stock = factory.created[0]
            stock.history = [10, 10, 10]
            #expect(view.plots().first?.lower == 10 && view.plots().first?.upper == 10)
            _ = try png(view)
            stock.history = [NSNumber(value: Double.nan), -1, NSNumber(value: Double.infinity), 0, 0.5]
            #expect(view.periodValues(stock) == [0, 0.5])
            stock.history = []; view.setFrameSize(NSSize(width: 240, height: 10))
            #expect(view.statusLabels.rightLabel.accessibilityValue() == "$25.00")
            stock.quote = nil; view.ticker()
            #expect(view.statusLabels.rightLabel.accessibilityValue() == "n/a")
            settings.stockGraphTimeFrame = -1
            #expect(view.timeFrame == 3)
        }
    }

    @Test func fullRowsKeepSubDollarZeroAndUnchangedQuotesAndDoNotMutateSettingsColors() async throws {
        try await withFixture { settings, defaults, factory in
            let view = panel(settings, defaults, factory); view.reloadStockData()
            factory.created[0].quote = [0.75, 0]; factory.created[1].quote = [0, -0.5]
            let color = settings.alignLeftAttributes[NSAttributedString.Key.foregroundColor.rawValue] as? NSColor
            _ = try png(view)
            #expect(view.quoteLabels.count == 2)
            #expect(view.quoteLabels[0].rightLabel.accessibilityValue() == "$0.75\nunch")
            #expect(view.quoteLabels[1].rightLabel.accessibilityValue() == "$0.00\n▼0.50")
            #expect(settings.alignLeftAttributes[NSAttributedString.Key.foregroundColor.rawValue] as? NSColor == color)
            #expect(view.footerLabels.centerLabel.accessibilityValue()?.contains("AAA: $0.75 unch") == true)
            settings.stockShowChange = false; view.updateMinSize()
            #expect(view.quoteLabels[0].rightLabel.accessibilityValue() == "$0.75")
        }
    }

    @Test(arguments: [CGFloat(10), 18, 28], [CGFloat(60), 100, 240])
    func narrowAndClippedRowsRetainCompleteAccessibleQuotes(font: CGFloat, width: CGFloat) async throws {
        try await withFixture { settings, defaults, factory in
            settings.graphFont = NSFont.systemFont(ofSize: font)
            settings.stockSymbols = "AAA,BBB,CCC,DDD"
            let view = panel(settings, defaults, factory, width: width, height: 80); view.reloadStockData()
            #expect(!view.quoteLabels.isEmpty)
            for group in view.quoteLabels {
                #expect(group.leftLabel.frame.maxX <= group.rightLabel.frame.minX)
                #expect(group.rightLabel.accessibilityValue() == "$25.00\n▲2.00")
            }
            #expect(view.footerLabels.centerLabel.accessibilityValue()?.contains("DDD: $25.00 ▲2.00") == true)
            #expect(view.footerLabels.rightLabel.accessibilityValue() == "1y")
            if width == 60 { #expect(view.footerLabels.centerLabel.stringValue.isEmpty) }
            if width == 240 && font == 10 { #expect(!view.footerLabels.centerLabel.stringValue.isEmpty) }
        }
    }

    @Test func menuActionsUseSnapshotSymbolsAndSafelyEncodeTheirURLs() async throws {
        try await withFixture { settings, defaults, factory in
            var opened: [URL] = []
            let view = XRGStockView(frame: NSRect(x: 0, y: 0, width: 240, height: 160), settings: settings,
                defaults: defaults, makeStock: { factory.make() }, openURL: { opened.append($0); return true })
            let host = StockPanelHost(settings: settings)
            defer { host.close() }
            host.contentView?.addSubview(view); view.awakeFromNib()
            let menu = view.makeMenu()
            for item in menu.items where !item.isSeparatorItem { #expect(item.target === view) }
            let original = try #require(menu.items.first)
            settings.stockSymbols = "NEW"; view.setStockSymbolsFromString(settings.stockSymbols)
            #expect(NSApp.sendAction(try #require(original.action), to: original.target, from: original))
            #expect(URLComponents(url: try #require(opened.last), resolvingAgainstBaseURL: false)?.queryItems?.first?.value == "AAA")
            let invalid = NSMenuItem(); invalid.tag = -1; view.openStock(invalid)
            invalid.tag = 100; view.openStock(invalid); view.openStock(nil)
            #expect(opened.count == 1)
            for title in ["View Detailed Status for DJIA", "Update Stock Graph Now", "Open XRG-ng Stock Preferences..."] {
                let item = try #require(menu.items.first { $0.title == title })
                #expect(NSApp.sendAction(try #require(item.action), to: item.target, from: item))
            }
            #expect(host.preferencesOpened == 1 && opened.count == 2)
            let url = try #require(XRGStockView.detailsURL(for: "^INDEX/?#&"))
            #expect(url.scheme == "https" && URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems?.first?.value == "^INDEX/?#&")
            view.removeFromSuperview()
        }
    }

    @Test func productionStockTransportPublishesRecordedSubDollarQuotesAndHistoryFallback() async throws {
        try await withFixture { settings, defaults, _ in
            settings.showDJIA = false; settings.stockSymbols = "TEST"
            let history = Data(#"{"chart":{"result":[{"indicators":{"quote":[{"close":[0.25,0.5,0.75]}]}}]}}"#.utf8)
            let quote = Data(#"{"chart":{"result":[{"meta":{"regularMarketPrice":0.75,"previousClose":0.75}}]}}"#.utf8)
            let view = XRGStockView(frame: NSRect(x: 0, y: 0, width: 240, height: 10), settings: settings, defaults: defaults,
                makeStock: { XRGStock(transport: { $0.path.contains("/v7/") ? history : quote }) })
            view.reloadStockData()
            let deadline = ContinuousClock.now + .seconds(3)
            while view.gettingData && ContinuousClock.now < deadline { try await Task.sleep(for: .milliseconds(1)) }
            #expect(view.dataIsReady())
            view.ticker()
            #expect(view.statusLabels.rightLabel.accessibilityValue() == "$0.75")
            #expect(view.periodValues(try #require(view.stockObjects.first)) == [0.25, 0.5, 0.75])
            let fallback = XRGStockView(frame: NSRect(x: 0, y: 0, width: 240, height: 10), settings: settings, defaults: defaults,
                makeStock: { XRGStock(transport: { url in
                    if url.path.contains("/v8/") { throw URLError(.timedOut) }
                    return history
                }) })
            fallback.reloadStockData()
            while fallback.gettingData && ContinuousClock.now < deadline { try await Task.sleep(for: .milliseconds(1)) }
            #expect(fallback.dataIsReady()); fallback.ticker()
            #expect(fallback.statusLabels.rightLabel.accessibilityValue() == "$0.75")
        }
    }

    @Test(arguments: ["StockView", "LegacyStock"])
    func currentAndLegacyNibArchivesInstantiateWithoutRequestsOrTimers(name: String) async throws {
        try await withFixture { _, _, _ in
            let nib = try #require(NSNib(nibNamed: NSNib.Name(name), bundle: Bundle(for: StockPanelNibOwner.self)))
            var objects: NSArray?
            #expect(nib.instantiate(withOwner: StockPanelNibOwner(), topLevelObjects: &objects))
            let view = try #require(objects?.compactMap { $0 as? XRGStockView }.first)
            #expect(view.subviews.count == 6 && view.module == nil && view.tickerTimer == nil)
            #expect(view.stockObjects.isEmpty && view.djia == nil && !view.gettingData)
            #expect(view.frame.size == NSSize(width: 76, height: 76))
            withExtendedLifetime(objects) {}
        }
    }

    @Test func plotsCompactLoadingAndEmptyStatesRenderAndCollapsedSizesStaySafe() async throws {
        try await withFixture { settings, defaults, factory in
            let view = panel(settings, defaults, factory); view.reloadStockData()
            let full = try png(view)
            settings.showDJIA = false; view.graphUpdate(nil)
            #expect(try png(view) != full)
            view.setFrameSize(NSSize(width: 240, height: 10)); _ = try png(view)
            factory.created[0].gettingData = true; view.ticker()
            #expect(view.statusLabels.leftLabel.accessibilityValue() == "Fetching Data")
            settings.stockSymbols = ""; view.setStockSymbolsFromString("")
            #expect(view.statusLabels.leftLabel.accessibilityValue() == "No Stocks")
            view.setGraphSize(.zero)
            #expect(view.graphSize == .zero && view.convertHeight(-1) == 0)
            for label in view.subviews { #expect(label.frame.size.width >= 0 && label.frame.size.height >= 0) }
            view.setGraphSize(NSSize(width: 240, height: 1000))
            #expect(view.convertHeight(Int32.max) == Int32.max)
            view.setGraphSize(NSSize(width: CGFloat.nan, height: CGFloat.infinity))
            #expect(view.graphSize == .zero)
        }
    }

    @Test func mouseEventsStillReachTheWindow() async throws {
        try await withFixture { settings, defaults, factory in
            let host = StockPanelHost(settings: settings)
            defer { host.close() }
            let view = panel(settings, defaults, factory)
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
