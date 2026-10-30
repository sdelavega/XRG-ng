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

/// The existing window implements this boundary while individual panels move to Swift.
@MainActor @objc public protocol XRGGPUViewHost: NSObjectProtocol {
    var appSettings: XRGSettings? { get }
    var moduleManager: XRGModuleManager? { get }
    var gpuView: XRGGPUView? { get set }
    func initTimers()
}

@MainActor
@objc(XRGGPUView) @objcMembers
public final class XRGGPUView: NSView, XRGModuleView {
    private let miner: XRGGPUMiner
    private let defaults: UserDefaults
    private let standaloneSettings: XRGSettings?
    private weak var host: (any XRGGPUViewHost)?
    private weak var registeredManager: XRGModuleManager?
    private var didAwake = false
    @nonobjc static let sourceKey = "XRGGPUView.Source.v1"
    @nonobjc static let modeKey = "XRGGPUView.PlotMode.v1"
    @nonobjc private(set) var selectedSource: String?
    @nonobjc private(set) var plotMode = XRGGPUPlotMode.memoryAndActivity
    private var sourceWarning: String?
    private var modeWarning: String?
    public private(set) weak var module: XRGModule?
    @nonobjc private(set) var cardLabels: [XRGGraphLabels] = []

    private var settings: XRGSettings? { host?.appSettings ?? standaloneSettings }

    public override init(frame frameRect: NSRect) {
        miner = XRGGPUMiner()
        defaults = .standard
        standaloneSettings = nil
        super.init(frame: frameRect)
        prepare()
    }
    public required init?(coder: NSCoder) {
        miner = XRGGPUMiner()
        defaults = .standard
        standaloneSettings = nil
        super.init(coder: coder)
        prepare()
    }
    @nonobjc init(frame: NSRect, miner: XRGGPUMiner, settings: XRGSettings?, defaults: UserDefaults) {
        self.miner = miner
        self.defaults = defaults
        standaloneSettings = settings
        super.init(frame: frame)
        prepare()
    }
    private func prepare() {
        do { selectedSource = try XRGMonitorSource.load(defaults, key: Self.sourceKey).source }
        catch { sourceWarning = XRGMonitorSource.invalid.localizedDescription }
        if let raw = defaults.object(forKey: Self.modeKey) {
            if let name = raw as? String, let mode = XRGGPUPlotMode(rawValue: name) { plotMode = mode }
            else { modeWarning = "Saved GPU plot mode is invalid. Using Memory + Activity without changing the saved value." }
        }
        ensureLabelCount(1)
        setGraphSize(bounds.size)
        updateLabels()
    }

    public nonisolated override func awakeFromNib() {
        super.awakeFromNib()
        // AppKit loads and connects this application's nibs on the main thread.
        MainActor.assumeIsolated {
            didAwake = true
            bindToWindow()
        }
    }
    public override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        bindToWindow()
    }
    private func bindToWindow() {
        let next = window as? any XRGGPUViewHost
        if host !== next {
            if host?.gpuView === self { host?.gpuView = nil }
            if let module { registeredManager?.removeModule(module) }
            registeredManager = nil
            module = nil
            host = next
        }
        guard didAwake, let host, let manager = host.moduleManager, settings != nil,
              registeredManager !== manager else { updateLabels(); return }
        let module = XRGModule(name: "GPU", reference: self, defaults: defaults)
        module.displayOrder = 1
        module.doesGraphUpdate = true
        module.doesFastUpdate = false
        module.doesMin5Update = false
        module.doesMin30Update = false
        module.isDisplayed = defaults.bool(forKey: "showGPUGraph")
        self.module = module
        registeredManager = manager
        host.gpuView = self
        host.initTimers()
        updateMinSize()
        manager.addModule(module)
        setGraphSize(module.currentSize)
    }

    public func setGraphSize(_ size: NSSize) {
        let width = size.width.isFinite ? size.width : 23
        setWidth(Int32(min(20_000, max(23, width))))
    }
    public func setWidth(_ width: Int32) {
        guard width >= 0 else { return }
        let count = retainedSamples > 0 ? retainedSamples : min(20_000, Int(width))
        if retainedSamples > 0 { miner.resizeHistory(count) } else { miner.setDataSize(count) }
    }
    public override func setFrameSize(_ newSize: NSSize) {
        super.setFrameSize(newSize)
        setGraphSize(newSize)
        updateLabels()
    }
    public func updateMinSize() {
        guard let settings else { return }
        let attributes: [NSAttributedString.Key: Any] = [.font: settings.graphFont ?? NSFont.systemFont(ofSize: 10)]
        module?.minWidth = ("GPU 9: 9999M" as NSString).size(withAttributes: attributes).width + 6
        module?.minHeight = XRGGraphLabels.lineHeight(settings)
        updateLabels()
    }
    public func graphUpdate(_ timer: Timer?) {
        miner.refreshForGraphTick((host as? any XRGGraphicsSampleClock)?.graphicsSampleGeneration)
        updateLabels()
        needsDisplay = true
    }
    @nonobjc func memoryReadings(tick: UInt64) -> Result<[XRGHardwareReading], Error> {
        miner.refreshForGraphTick(tick)
        return miner.memorySnapshot
    }
    public func fastUpdate(_ timer: Timer?) {}
    public func min5Update(_ timer: Timer?) {}
    public func min30Update(_ timer: Timer?) {}

    @nonobjc private var timeProjections: [String: (history: XRGTimedHistory, projection: XRGTimeWindowProjection)] = [:]
    @nonobjc func historyData(at index: Int) -> [XRGDataSet] {
        let id = miner.currentSamples[index].selectionID
        if historyMinutes > 0, let raw = miner.timedHistory(sourceID: id) {
            let previous = timeProjections[id]
            let cache = previous?.history === raw ? previous!.projection : XRGTimeWindowProjection(channels: 4)
            timeProjections[id] = (raw, cache)
            if let data = cache.values(from: raw, minutes: historyMinutes, interval: Double(settings?.graphRefresh ?? 1)) { return data }
        }
        return [miner.totalVRAMDataSets[index], miner.freeVRAMDataSets[index], miner.cpuWaitDataSets[index], miner.utilizationDataSets[index]]
    }
    private struct Card {
        let sample: XRGGPUSample
        let total: XRGDataSet
        let free: XRGDataSet
        let wait: XRGDataSet
        let utilization: XRGDataSet
        let vendor: String
        let hasMemory: Bool
        let hasUtilization: Bool
        var validMemory: Bool {
            guard hasMemory, let total = sample.total, let free = sample.free else { return false }
            return total.isFinite && total > 0 && free.isFinite && free >= 0 && free <= total
        }
        var used: CGFloat { validMemory ? CGFloat(sample.total! - sample.free!) : 0 }
        var capacity: CGFloat { validMemory ? CGFloat(sample.total!) : 0 }
    }
    @nonobjc private func cards() -> [Card] {
        let count = miner.totalVRAMDataSets.count
        guard [miner.freeVRAMDataSets.count, miner.cpuWaitDataSets.count, miner.utilizationDataSets.count,
               miner.vendorNames.count, miner.memoryAvailable.count, miner.utilizationAvailable.count, miner.currentSamples.count]
            .allSatisfy({ $0 == count }) else { return [] }
        timeProjections = timeProjections.filter { miner.sourceIDs.contains($0.key) }
        return (0..<count).filter { selectedSource == nil || miner.currentSamples[$0].selectionID == selectedSource }.map { index in
            let data = historyData(at: index)
            return Card(sample: miner.currentSamples[index], total: data[0], free: data[1],
                 wait: data[2], utilization: data[3],
                 vendor: miner.vendorNames[index], hasMemory: miner.memoryAvailable[index].boolValue,
                 hasUtilization: miner.utilizationAvailable[index].boolValue)
        }
    }
    @nonobjc static func waitText(_ value: CGFloat) -> String {
        guard value.isFinite, value >= 0 else { return "" }
        let divisor: CGFloat
        let unit: String
        if value < 1_000 { divisor = 1; unit = "ns" }
        else if value < 1_000_000 { divisor = 1_000; unit = "µs" }
        else if value < 1_000_000_000 { divisor = 1_000_000; unit = "ms" }
        else { divisor = 1_000_000_000; unit = "s" }
        return String(format: "%.0f %@", (value / divisor).rounded(.towardZero), unit)
    }
    @nonobjc private func usageText(_ card: Card) -> String {
        if card.hasUtilization {
            let value = CGFloat(card.sample.utilization ?? .nan)
            return value.isFinite ? String(format: "%.0f%%", min(100, max(0, value)).rounded(.towardZero)) : "n/a"
        }
        return Self.waitText(CGFloat(card.sample.wait ?? -1))
    }
    @nonobjc private func miniValues(_ cards: [Card]) -> ([NSNumber], String) {
        guard miner.countersAvailable else { return ([], "n/a") }
        if plotMode == .utilization {
            let valid = !cards.isEmpty && cards.allSatisfy { $0.hasUtilization && ($0.sample.utilization?.isFinite == true) }
            let values = cards.map { NSNumber(value: $0.sample.utilization ?? 0) }
            let mean = cards.reduce(0.0) { $0 + ($1.sample.utilization ?? 0) } / Double(max(1, cards.count))
            return (values, valid ? String(format: "%.0f%%", mean) : "n/a")
        }
        let values = cards.map { NSNumber(value: $0.validMemory ? Double($0.used / $0.capacity * 100) : 0) }
        let usedMB = cards.reduce(0.0) { $0 + Double($1.used) / 1_048_576 }
        let available = !cards.isEmpty && cards.allSatisfy(\.validMemory) && usedMB.isFinite
        return (values, available ? String(format: "%.0fM", usedMB) : "n/a")
    }
    public func shouldDrawMiniGraph() -> Bool { XRGGraphLabels.shouldDrawMiniGraph(in: bounds, settings: settings) }
    public func paddedTextRect() -> NSRect { XRGGraphLabels.paddedTextRect(for: bounds) }

    private func ensureLabelCount(_ count: Int) {
        while cardLabels.count > count {
            let labels = cardLabels.removeLast()
            for label in [labels.leftLabel, labels.centerLabel, labels.rightLabel] { label.removeFromSuperview() }
        }
        while cardLabels.count < count {
            let labels = XRGGraphLabels()
            for label in [labels.leftLabel, labels.centerLabel, labels.rightLabel] { addSubview(label) }
            cardLabels.append(labels)
        }
    }
    @nonobjc private func band(at index: Int, count: Int) -> NSRect {
        let height = max(0, floor(bounds.height / CGFloat(count)))
        return NSRect(x: bounds.minX, y: bounds.minY + CGFloat(count - index - 1) * height,
                      width: max(0, bounds.width), height: max(0, height - 1))
    }
    private func updateLabels() { toolTip = detailText; layoutLabels(cards()) }
    @nonobjc private func layoutLabels(_ cards: [Card]) {
        let mini = shouldDrawMiniGraph()
        ensureLabelCount(mini || cards.isEmpty ? 1 : cards.count)
        if cards.isEmpty || mini {
            cardLabels[0].layout(leftText: "GPU", centerText: nil, rightText: cards.isEmpty && selectedSource != nil ? "Selected GPU unavailable" : miniValues(cards).1,
                                 in: paddedTextRect(), mini: mini, settings: settings)
            return
        }
        for (index, card) in cards.enumerated() {
            let rect = cards.count == 1 ? bounds : band(at: index, count: cards.count)
            let textRect = XRGGraphLabels.paddedTextRect(for: rect)
            let title: String
            if let selectedSource, let ordinal = miner.sourceIDs.firstIndex(of: selectedSource) { title = "GPU \(ordinal + 1)" }
            else { title = cards.count == 1 ? "GPU" : "GPU \(index + 1)" }
            var memory = "n/a"
            if card.validMemory && miner.countersAvailable {
                memory = XRGCommon.formattedString(forBytes: Double(card.used))
                if textRect.width >= 110 { memory += " / " + XRGCommon.formattedString(forBytes: Double(card.capacity)) }
            }
            let reading = !miner.countersAvailable ? "n/a" : plotMode == .utilization ? (card.hasUtilization ? usageText(card) : "n/a") : "\(memory)\n\(usageText(card))"
            cardLabels[index].layout(leftText: "\(title)\n\(card.vendor)", centerText: nil,
                rightText: reading, in: textRect,
                mini: XRGGraphLabels.shouldDrawMiniGraph(in: rect, settings: settings), settings: settings)
        }
    }

    public override func draw(_ dirtyRect: NSRect) {
        guard !isHidden, let settings, let context = NSGraphicsContext.current,
              XRGGraphRenderer.validRect(bounds) else { return }
        NSGraphicsContext.saveGraphicsState()
        defer { NSGraphicsContext.restoreGraphicsState() }
        settings.graphColor(.gpu, component: 0).set()
        context.cgContext.fill(bounds)
        let cards = cards()
        if shouldDrawMiniGraph() {
            XRGGraphRenderer.drawGraphBars(miniValues(cards).0, upperBound: 100, lowerBound: 0, in: bounds, settings: settings, module: .gpu)
        } else {
            context.shouldAntialias = settings.antiAliasing
            for (index, card) in cards.enumerated() {
                let rect = band(at: index, count: cards.count)
                if plotMode == .memoryAndActivity, card.validMemory {
                    let used = XRGDataSet()
                    let values = zip(card.total.orderedValues, card.free.orderedValues).map { total, free in
                        total == XRGGraphRenderer.missingValue || free == XRGGraphRenderer.missingValue ? XRGGraphRenderer.missingValue : total - free
                    }
                    used.resize(values.count)
                    for value in values { used.setNextValue(value) }
                    if used.max > 0 {
                        XRGGraphRenderer.drawCurve(used, upperBound: max(card.capacity, card.total.max), lowerBound: 0, in: rect,
                            flipped: false, filled: true, color: settings.graphColor(.gpu, component: 1), style: settings.curveStyle(.gpu))
                    }
                }
                // Utilization-only never substitutes CPU wait (nanoseconds) for a
                // percentage. Unsupported percentage samples are explicit gaps.
                let utilization = plotMode == .utilization || card.hasUtilization
                let data = utilization ? card.utilization : card.wait
                XRGGraphRenderer.drawCurve(data, upperBound: utilization ? 100 : max(data.max, 100),
                    lowerBound: 0, in: rect, flipped: false, filled: false, color: settings.graphColor(.gpu, component: 2), style: settings.curveStyle(.gpu))
            }
        }
        layoutLabels(cards)
        XRGGraphRenderer.drawGraphEffect(in: bounds, settings: settings, module: .gpu)
    }

    @nonobjc var detailText: String {
        let selected = cards()
        let available = miner.countersAvailable && !selected.isEmpty
        return [sourceWarning, modeWarning,
                "Scope: \(selectedSource ?? "all discovered GPUs"). \(available ? "Counters available." : "Selected GPU counters unavailable; no replacement is chosen.")",
                "Plot: \(plotMode.title). Utilization Only uses reported device utilization, 0–100%, and never substitutes memory allocation or CPU wait for busy percent. Compact utilization shows one bar per selected adapter and the unweighted mean of available adapters only when every selected value is present. This is not combined GPU capacity.",
                "Memory + Activity retains the existing memory fill and utilization line, with CPU hardware wait in nanoseconds only when utilization is unsupported. Memory pools/allocation counters are driver-reported and are not a measurement of GPU compute activity. Optional VRAM graph choices remain independent.",
                "Source selection uses an opaque IOService location when available, otherwise a registry-entry ID (which can change after reboot). Selection preserves per-device history. A replacement registry instance starts a new history even at the same location. Unavailable pins remain saved. Invalid saved preferences remain unchanged until explicitly replaced.",
                "Reset Graph clears only the selected GPU histories while preserving the latest readout. Selection, display-mode changes, details and reset do not read hardware. Failed polls append gaps and show n/a; recovery retains per-device history. Availability depends on the driver and hardware."].compactMap { $0 }.joined(separator: "\n\n")
    }
    @nonobjc func applyGPUSource(_ id: String?) throws {
        let next = XRGMonitorSource(source: id)
        defaults.set(try next.encoded(), forKey: Self.sourceKey)
        selectedSource = id; sourceWarning = nil; updateLabels(); needsDisplay = true
    }
    @nonobjc func applyPlotMode(_ mode: XRGGPUPlotMode) {
        defaults.set(mode.rawValue, forKey: Self.modeKey)
        plotMode = mode; modeWarning = nil; updateLabels(); needsDisplay = true
    }
    @nonobjc func makeMenu() -> NSMenu {
        let menu = NSMenu(title: "GPU View")
        func item(_ title: String, _ action: Selector) -> NSMenuItem {
            let item = NSMenuItem(title: title, action: action, keyEquivalent: "")
            item.target = self; return item
        }
        let sources = item("GPU Source", #selector(emptyEvent(_:)))
        let submenu = NSMenu(title: "GPU Source")
        let all = item("All Discovered GPUs", #selector(selectSource(_:))); all.state = selectedSource == nil ? .on : .off; submenu.addItem(all)
        for (index, sample) in miner.currentSamples.enumerated() {
            let option = item("GPU \(index + 1) · \(sample.vendor.isEmpty ? "Unknown vendor" : sample.vendor)", #selector(selectSource(_:)))
            option.representedObject = sample.selectionID; option.toolTip = sample.selectionID
            option.state = selectedSource == sample.selectionID ? .on : .off; submenu.addItem(option)
        }
        if let selectedSource, !miner.sourceIDs.contains(selectedSource) {
            let missing = item("Selected GPU (unavailable)", #selector(selectSource(_:)))
            missing.representedObject = selectedSource; missing.toolTip = selectedSource; missing.state = .on; submenu.addItem(missing)
        }
        sources.submenu = submenu; menu.addItem(sources)
        let display = item("GPU Plot", #selector(emptyEvent(_:))); let modes = NSMenu(title: "GPU Plot")
        for mode in XRGGPUPlotMode.allCases {
            let option = item(mode.title, #selector(selectPlotMode(_:))); option.representedObject = mode.rawValue
            option.state = plotMode == mode ? .on : .off; modes.addItem(option)
        }
        display.submenu = modes; menu.addItem(display)
        menu.addItem(XRGHistoryRetention.menu("GPU History", count: retainedSamples, target: self, action: #selector(selectHistory(_:)), rootAction: #selector(emptyEvent(_:))))
        menu.addItem(XRGSystemTimeWindow.menu("GPU Time Window", minutes: historyMinutes, target: self, action: #selector(selectHistoryWindow(_:)), rootAction: #selector(emptyEvent(_:))))
        menu.addItem(.separator()); menu.addItem(item("GPU Details…", #selector(showDetails(_:))))
        menu.addItem(item("Reset Graph", #selector(clearData(_:))))
        return menu
    }
    public override func menu(for event: NSEvent) -> NSMenu? { makeMenu() }
    @nonobjc static let windowKey = "XRGGPUView.HistoryMinutes.v1"
    @nonobjc var historyMinutes: Int { XRGSystemTimeWindow.saved(defaults, key: Self.windowKey) }
    @objc func selectHistoryWindow(_ sender: Any?) {
        guard XRGSystemTimeWindow.store(sender, defaults: defaults, key: Self.windowKey) else { return }
        updateLabels(); needsDisplay = true
    }
    @nonobjc static let historyKey = "XRGGPUView.HistorySamples.v1"
    @nonobjc var retainedSamples: Int { XRGHistoryRetention.saved(defaults, key: Self.historyKey) }
    @objc func selectHistory(_ sender: Any?) {
        guard XRGHistoryRetention.store(sender, defaults: defaults, key: Self.historyKey) else { return }
        defaults.set(0, forKey: Self.windowKey)
        setGraphSize(bounds.size); updateLabels(); needsDisplay = true
    }
    public func emptyEvent(_ sender: Any?) {}
    public func selectSource(_ sender: NSMenuItem) { try? applyGPUSource(sender.representedObject as? String) }
    public func selectPlotMode(_ sender: NSMenuItem) {
        guard let name = sender.representedObject as? String, let mode = XRGGPUPlotMode(rawValue: name) else { return }
        applyPlotMode(mode)
    }
    public func clearData(_ sender: Any?) { miner.resetHistory(sourceID: selectedSource); updateLabels(); needsDisplay = true }
    public func showDetails(_ sender: Any?) {
        guard let window else { return }
        XRGMonitorDetails.present(title: "GPU Details", text: detailText, in: window)
    }

    public override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
    public override func mouseDown(with event: NSEvent) { window?.mouseDown(with: event) }
    public override func mouseDragged(with event: NSEvent) { window?.mouseDragged(with: event) }
    public override func mouseUp(with event: NSEvent) { window?.mouseUp(with: event) }
}
