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

@MainActor @objc public protocol XRGStockViewHost: NSObjectProtocol {
    var appSettings: XRGSettings? { get }
    var moduleManager: XRGModuleManager? { get }
    var stockView: XRGStockView? { get set }
    func initTimers()
    func showStockPreferences()
}

/// The production model owns transport and cancellation; fixtures supply complete snapshots.
@MainActor protocol XRGStockViewData: AnyObject {
    var symbol: String? { get set }
    var label: String? { get }
    var gettingData: Bool { get }
    var haveGoodDisplayData: Bool { get }
    func resetData()
    func loadData()
    func get1MonthValues() -> [NSNumber]?
    func get3MonthValues() -> [NSNumber]?
    func get6MonthValues() -> [NSNumber]?
    func get12MonthValues() -> [NSNumber]?
    func getCurrentPriceAndChange() -> [NSNumber]?
    func priceString() -> String
    func changeString() -> String
}
extension XRGStock: XRGStockViewData {}

@MainActor
@objc(XRGStockView) @objcMembers
public final class XRGStockView: NSView, XRGModuleView {
    private let defaults: UserDefaults
    private let standaloneSettings: XRGSettings?
    private let makeStock: () -> any XRGStockViewData
    private let openURL: (URL) -> Bool
    private weak var host: (any XRGStockViewHost)?
    private weak var registeredManager: XRGModuleManager?
    private var didAwake = false
    private var needsRebuild = true
    private var suspended = false
    private var switchTicks = 0
    @nonobjc private(set) var slowPhase = 0
    @nonobjc private(set) var stockToShow = 0
    @nonobjc private(set) var stockSymbols: [String] = []
    @nonobjc private(set) var stockObjects: [any XRGStockViewData] = []
    @nonobjc private(set) var djia: (any XRGStockViewData)?
    @nonobjc private(set) var tickerTimer: Timer?
    @nonobjc let statusLabels = XRGGraphLabels()
    @nonobjc let footerLabels = XRGGraphLabels()
    @nonobjc private(set) var quoteLabels: [XRGGraphLabels] = []
    public private(set) weak var module: XRGModule?
    private var settings: XRGSettings? { host?.appSettings ?? standaloneSettings }
    private var active: Bool {
        if let module { return module.isDisplayed && window != nil }
        return host == nil && !didAwake && standaloneSettings != nil
    }
    public var graphSize: NSSize { bounds.size }
    public var gettingData: Bool { stockObjects.contains { $0.gettingData } || (djia?.gettingData ?? false) }

    public override init(frame frameRect: NSRect) {
        defaults = .standard; standaloneSettings = nil
        makeStock = { XRGStock() }; openURL = { NSWorkspace.shared.open($0) }
        super.init(frame: frameRect); prepare()
    }
    public required init?(coder: NSCoder) {
        defaults = .standard; standaloneSettings = nil
        makeStock = { XRGStock() }; openURL = { NSWorkspace.shared.open($0) }
        super.init(coder: coder); prepare()
    }
    @nonobjc init(frame: NSRect, settings: XRGSettings, defaults: UserDefaults,
                  makeStock: @escaping () -> any XRGStockViewData, openURL: @escaping (URL) -> Bool = { _ in true }) {
        self.defaults = defaults; standaloneSettings = settings
        self.makeStock = makeStock; self.openURL = openURL
        super.init(frame: frame); prepare()
    }
    private func prepare() {
        for group in [statusLabels, footerLabels] {
            for label in [group.leftLabel, group.centerLabel, group.rightLabel] { addSubview(label) }
        }
        stockSymbols = Self.parseSymbols(settings?.stockSymbols ?? "")
        updateLabels()
    }
    public nonisolated override func awakeFromNib() {
        super.awakeFromNib()
        MainActor.assumeIsolated { didAwake = true; bindToWindow() }
    }
    public override func viewDidMoveToWindow() { super.viewDidMoveToWindow(); bindToWindow() }
    private func cancelData() {
        for stock in stockObjects { stock.symbol = nil }
        djia?.symbol = nil
        stockObjects = []; djia = nil; needsRebuild = true
    }
    private func stopTicker() { tickerTimer?.invalidate(); tickerTimer = nil }
    private func bindToWindow() {
        let next = window as? any XRGStockViewHost
        if host !== next || registeredManager !== next?.moduleManager {
            stopTicker(); cancelData()
            if host?.stockView === self { host?.stockView = nil }
            if let module { registeredManager?.removeModule(module) }
            registeredManager = nil; module = nil; host = next
        }
        guard didAwake, let host, let manager = host.moduleManager, settings != nil,
              registeredManager !== manager else { synchronizeTicker(); updateLabels(); return }
        stockSymbols = Self.parseSymbols(settings?.stockSymbols ?? "")
        let module = XRGModule(name: "Stock", reference: self, defaults: defaults)
        module.displayOrder = 9; module.doesGraphUpdate = true; module.doesFastUpdate = false
        module.doesMin5Update = false; module.doesMin30Update = true
        module.isDisplayed = defaults.bool(forKey: "showStockGraph")
        self.module = module; registeredManager = manager
        host.stockView = self; host.initTimers()
        updateMinSize(); manager.addModule(module); setGraphSize(module.currentSize)
        if module.isDisplayed { min30Update(nil) }
        synchronizeTicker(); updateLabels()
    }
    private func synchronizeTicker() {
        guard module?.isDisplayed == true, window != nil else { stopTicker(); return }
        guard tickerTimer == nil else { return }
        tickerTimer = Timer.scheduledTimer(withTimeInterval: 2, repeats: true) { [weak self] timer in
            let alive = MainActor.assumeIsolated {
                guard let self else { return false }
                self.ticker(); return true
            }
            if !alive { timer.invalidate() }
        }
    }
    public func setGraphSize(_ size: NSSize) {
        let width = size.width.isFinite ? max(0, size.width) : 0
        let height = size.height.isFinite ? max(0, size.height) : 0
        setFrameSize(NSSize(width: width, height: height))
    }
    public override func setFrameSize(_ newSize: NSSize) { super.setFrameSize(newSize); updateLabels() }
    public func updateMinSize() {
        module?.minWidth = ("WWWW: $999.99" as NSString).size(withAttributes: [.font: settings?.graphFont ?? NSFont.systemFont(ofSize: 10)]).width + 6
        module?.minHeight = XRGGraphLabels.lineHeight(settings)
        updateLabels()
    }
    @nonobjc static func parseSymbols(_ text: String) -> [String] {
        text.filter { !$0.isWhitespace }.uppercased().split(separator: ",").map(String.init)
    }
    public func setStockSymbolsFromString(_ text: String?) {
        let symbols = Self.parseSymbols(text ?? "")
        guard symbols != stockSymbols else { return }
        cancelData(); stockSymbols = symbols; stockToShow = 0; switchTicks = 0; slowPhase = 0
        if active { reloadStockData() }
        updateLabels(); needsDisplay = true
    }
    private func synchronizeDJIA() {
        let wanted = settings?.showDJIA == true && !stockSymbols.isEmpty
        if !wanted { djia?.symbol = nil; djia = nil }
        else if djia == nil {
            let index = makeStock(); index.symbol = "^DJI"; djia = index
        }
    }
    public func resetStockObjects() {
        cancelData(); stockToShow = 0; switchTicks = 0
        if active { reloadStockData() }
        updateLabels(); needsDisplay = true
    }
    public func reloadStockData() {
        guard active else { return }
        if needsRebuild {
            cancelData()
            stockObjects = stockSymbols.map { symbol in
                let stock = makeStock(); stock.symbol = symbol; return stock
            }
            needsRebuild = false
            synchronizeDJIA()
        } else {
            for stock in stockObjects { stock.resetData(); stock.loadData() }
            if let djia, settings?.showDJIA == true { djia.resetData(); djia.loadData() }
            synchronizeDJIA()
        }
        suspended = false
        if stockToShow >= stockObjects.count { stockToShow = 0 }
        updateLabels(); needsDisplay = true
    }
    public func dataIsReady() -> Bool { !gettingData }
    private func suspend() {
        stopTicker(); suspended = true
        for stock in stockObjects where stock.gettingData { stock.resetData(); needsRebuild = true }
        if djia?.gettingData == true { djia?.resetData(); needsRebuild = true }
    }
    public func graphUpdate(_ timer: Timer?) {
        guard active else { suspend(); return }
        let symbols = Self.parseSymbols(settings?.stockSymbols ?? "")
        if symbols != stockSymbols { setStockSymbolsFromString(settings?.stockSymbols) }
        if needsRebuild || suspended { reloadStockData() }
        synchronizeDJIA(); synchronizeTicker(); updateLabels(); needsDisplay = true
    }
    public func fastUpdate(_ timer: Timer?) {}
    public func min5Update(_ timer: Timer?) {}
    public func min30Update(_ timer: Timer?) {
        guard active else { suspend(); return }
        if slowPhase == 0 || needsRebuild || suspended { reloadStockData() }
        slowPhase = (slowPhase + 1) % 4
        synchronizeTicker()
    }
    public func ticker() {
        guard active else { suspend(); return }
        synchronizeDJIA()
        switchTicks += 1
        if switchTicks >= 15 {
            switchTicks = 0
            if !stockObjects.isEmpty { stockToShow = (stockToShow + 1) % stockObjects.count }
        }
        updateLabels(); needsDisplay = true
    }
    public func shouldDrawMiniGraph() -> Bool { XRGGraphLabels.shouldDrawMiniGraph(in: bounds, settings: settings) }
    @nonobjc var timeFrame: Int {
        let value = settings?.stockGraphTimeFrame ?? 3
        return (0...3).contains(value) ? value : 3
    }
    @nonobjc var timeFrameText: String { ["1m", "3m", "6m", "1y"][timeFrame] }
    @nonobjc func periodValues(_ stock: any XRGStockViewData) -> [CGFloat] {
        let source: [NSNumber]?
        switch timeFrame {
        case 0: source = stock.get1MonthValues()
        case 1: source = stock.get3MonthValues()
        case 2: source = stock.get6MonthValues()
        default: source = stock.get12MonthValues()
        }
        return (source ?? []).map { CGFloat($0.doubleValue) }.filter { $0.isFinite && $0 >= 0 }
    }
    struct Plot { let values: [CGFloat]; let lower: CGFloat; let upper: CGFloat; let filled: Bool }
    @nonobjc func plots() -> [Plot] {
        guard !gettingData, stockObjects.indices.contains(stockToShow) else { return [] }
        let sources: [(any XRGStockViewData, Bool)] = [(stockObjects[stockToShow], true)] + (settings?.showDJIA == true ? djia.map { [($0, false)] } ?? [] : [])
        return sources.compactMap { source, filled in
            let values = periodValues(source)
            guard let low = values.min(), let high = values.max() else { return nil }
            let padding = (high - low) * 0.1
            guard padding.isFinite, (high + padding).isFinite, (low - padding).isFinite else { return nil }
            return Plot(values: values, lower: low - padding, upper: high + padding, filled: filled)
        }
    }
    @nonobjc func fullReading() -> String {
        if stockSymbols.isEmpty { return "No Stocks Found" }
        if gettingData { return "Fetching Data" }
        var lines = stockObjects.map { stock in
            (stock.label ?? stock.symbol ?? "") + ": " + stock.priceString() + (settings?.stockShowChange == true ? " " + stock.changeString() : "")
        }
        if settings?.showDJIA == true { lines.append("DJIA: " + (djia?.priceString() ?? "n/a")) }
        lines.append(timeFrameText)
        return lines.joined(separator: "\n")
    }
    private func ensureQuoteLabels(_ count: Int) {
        while quoteLabels.count > count {
            let labels = quoteLabels.removeLast()
            for field in [labels.leftLabel, labels.centerLabel, labels.rightLabel] { field.removeFromSuperview() }
        }
        while quoteLabels.count < count {
            let labels = XRGGraphLabels()
            for field in [labels.leftLabel, labels.centerLabel, labels.rightLabel] { addSubview(field) }
            quoteLabels.append(labels)
        }
    }
    private func updateLabels() {
        let rect = XRGGraphLabels.paddedTextRect(for: bounds), mini = shouldDrawMiniGraph()
        let message = stockSymbols.isEmpty ? (mini ? "No Stocks" : "No Stocks\nFound") : gettingData ? "Fetching Data" : stockObjects.isEmpty ? "Stocks n/a" : nil
        for field in [statusLabels.leftLabel, statusLabels.centerLabel, statusLabels.rightLabel] { field.isHidden = !mini && message == nil }
        for field in [footerLabels.leftLabel, footerLabels.centerLabel, footerLabels.rightLabel] { field.isHidden = mini || message != nil }
        if let message {
            ensureQuoteLabels(0)
            statusLabels.layout(leftText: message, centerText: nil, rightText: nil, in: rect, mini: mini, settings: settings)
            footerLabels.layout(leftText: nil, centerText: nil, rightText: nil, in: .zero, mini: false, settings: settings)
            return
        }
        if mini {
            ensureQuoteLabels(0)
            let stock = stockObjects[stockToShow]
            statusLabels.layoutColumnText(stock.label ?? stock.symbol, rightText: stock.priceString(), in: rect, mini: true, settings: settings)
            footerLabels.layout(leftText: nil, centerText: nil, rightText: nil, in: .zero, mini: false, settings: settings)
            return
        }
        statusLabels.layout(leftText: nil, centerText: nil, rightText: nil, in: .zero, mini: false, settings: settings)
        let line = XRGGraphLabels.lineHeight(settings)
        let rowHeight = line * (settings?.stockShowChange == true ? 2 : 1)
        let available = floor(max(0, bounds.height - line) / rowHeight)
        let visible = min(stockObjects.count, available >= CGFloat(stockObjects.count) ? stockObjects.count : max(1, Int(available)))
        ensureQuoteLabels(visible)
        for index in 0..<visible {
            let stock = stockObjects[(stockToShow + index) % stockObjects.count]
            let y = max(bounds.minY + line, bounds.maxY - CGFloat(index + 1) * rowHeight)
            let frame = NSRect(x: rect.minX, y: y, width: rect.width, height: max(0, min(rowHeight, bounds.maxY - y)))
            let right = stock.priceString() + (settings?.stockShowChange == true ? "\n" + stock.changeString() : "")
            quoteLabels[index].layoutColumnText(stock.label ?? stock.symbol, rightText: right, in: frame, mini: false, settings: settings)
            if index == 0 && stockObjects.count > 1, let color = settings?.graphFG3Color {
                for label in [quoteLabels[index].leftLabel, quoteLabels[index].rightLabel] {
                    let text = NSMutableAttributedString(attributedString: label.attributedStringValue)
                    text.addAttribute(.foregroundColor, value: color, range: NSRange(location: 0, length: text.length))
                    label.attributedStringValue = text
                }
            }
        }
        let footer = NSRect(x: rect.minX, y: bounds.minY, width: rect.width, height: min(line, max(0, bounds.height)))
        let djiaText = settings?.showDJIA == true ? djia?.priceString() ?? "n/a" : nil
        var overflowText: String?
        if visible < stockObjects.count {
            let candidate = "↓ \(stockObjects.count - visible)"
            let attributes: [NSAttributedString.Key: Any] = [.font: settings?.graphFont ?? NSFont.systemFont(ofSize: 10)]
            let half = (rect.width - (candidate as NSString).size(withAttributes: attributes).width) / 2
            if ((djiaText ?? "") as NSString).size(withAttributes: attributes).width + 6 <= half,
               (timeFrameText as NSString).size(withAttributes: attributes).width + 6 <= half { overflowText = candidate }
        }
        footerLabels.layoutColumnText(djiaText, centerText: overflowText,
                                      rightText: timeFrameText, in: footer, mini: false, settings: settings)
        footerLabels.centerLabel.fullAccessibilityText = fullReading()
        footerLabels.centerLabel.setAccessibilityElement(true)
    }
    public override func draw(_ dirtyRect: NSRect) {
        guard !isHidden, let settings, let context = NSGraphicsContext.current, XRGGraphRenderer.validRect(bounds) else { return }
        NSGraphicsContext.saveGraphicsState(); defer { NSGraphicsContext.restoreGraphicsState() }
        updateLabels(); settings.graphBGColor.set(); context.cgContext.fill(bounds)
        if shouldDrawMiniGraph(), !gettingData, stockObjects.indices.contains(stockToShow) {
            let stock = stockObjects[stockToShow], values = periodValues(stock)
            if let low = values.min(), let high = values.max(), let price = stock.getCurrentPriceAndChange()?.first, price.doubleValue.isFinite {
                XRGGraphRenderer.drawMiniValues([price], upperBound: Double(high), lowerBound: Double(low), in: bounds, settings: settings)
            }
        } else if !shouldDrawMiniGraph() {
            context.shouldAntialias = settings.antiAliasing
            for plot in plots() {
                plot.values.withUnsafeBufferPointer { values in
                    XRGGraphRenderer.drawSamples(values.baseAddress, count: values.count, currentIndex: values.count - 1,
                        upperBound: plot.upper, lowerBound: plot.lower, in: bounds, flipped: false, filled: plot.filled,
                        color: plot.filled ? settings.graphFG1Color : settings.graphFG2Color)
                }
            }
        }
        XRGGraphRenderer.drawStyle(in: bounds, settings: settings)
    }
    public func convertHeight(_ value: Int32) -> Int32 {
        let result = Double(max(0, value)) / 100 * Double(max(0, bounds.height))
        guard result.isFinite, result < Double(Int32.max) else { return result > 0 ? Int32.max : 0 }
        return Int32(max(0, result))
    }
    @nonobjc static func detailsURL(for symbol: String) -> URL? {
        var parts = URLComponents()
        parts.scheme = "https"; parts.host = "www.google.com"; parts.path = "/finance"
        parts.queryItems = [URLQueryItem(name: "q", value: symbol)]
        return parts.url
    }
    @nonobjc func makeMenu() -> NSMenu {
        let menu = NSMenu(title: "Stock View")
        func item(_ title: String, _ action: Selector) -> NSMenuItem {
            let item = NSMenuItem(title: title, action: action, keyEquivalent: "")
            item.target = self; return item
        }
        for (index, symbol) in stockSymbols.enumerated() {
            let link = item("View Detailed Status for " + symbol, #selector(openStock(_:)))
            link.tag = index; link.representedObject = symbol; menu.addItem(link)
        }
        menu.addItem(.separator()); menu.addItem(item("View Detailed Status for DJIA", #selector(openDJIA(_:))))
        menu.addItem(.separator()); menu.addItem(item("Update Stock Graph Now", #selector(updateNow(_:))))
        menu.addItem(.separator()); menu.addItem(item("Open XRG-ng Stock Preferences...", #selector(openStockPreferences(_:))))
        return menu
    }
    public override func menu(for event: NSEvent) -> NSMenu? { makeMenu() }
    public func emptyEvent(_ sender: Any?) {}
    public func openStock(_ sender: Any?) {
        guard let item = sender as? NSMenuItem else { return }
        let symbol = (item.representedObject as? String) ?? (stockSymbols.indices.contains(item.tag) ? stockSymbols[item.tag] : nil)
        if let symbol, let url = Self.detailsURL(for: symbol) { _ = openURL(url) }
    }
    public func openDJIA(_ sender: Any?) { if let url = Self.detailsURL(for: "^DJI") { _ = openURL(url) } }
    public func updateNow(_ sender: Any?) { slowPhase = 0; min30Update(nil) }
    public func openStockPreferences(_ sender: Any?) { host?.showStockPreferences() }
    public override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
    public override func mouseDown(with event: NSEvent) { window?.mouseDown(with: event) }
    public override func mouseDragged(with event: NSEvent) { window?.mouseDragged(with: event) }
    public override func mouseUp(with event: NSEvent) { window?.mouseUp(with: event) }
}
