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

@MainActor @objc public protocol XRGCPUViewHost: NSObjectProtocol {
    var appSettings: XRGSettings? { get }
    var moduleManager: XRGModuleManager? { get }
    var cpuView: XRGCPUView? { get set }
    func initTimers()
    func showCPUPreferences()
}

@MainActor
@objc(XRGCPUView) @objcMembers
public final class XRGCPUView: NSView, XRGModuleView {
    private let miner: XRGCPUMiner
    @nonobjc private(set) var processInspector: XRGProcessInspector?
    private let processMiner: XRGProcessMiner
    private let defaults: UserDefaults
    private let standaloneSettings: XRGSettings?
    private let openURL: (URL) -> Bool
    private weak var host: (any XRGCPUViewHost)?
    private weak var registeredManager: XRGModuleManager?
    private var didAwake = false
    @nonobjc static let sourceKey = "XRGCPUView.Source.v1"
    @nonobjc static let historyKey = "XRGCPUView.HistorySamples.v1"
    @nonobjc var retainedSamples: Int {
        let value = defaults.integer(forKey: Self.historyKey)
        return XRGSamplingSettings.validCPUHistorySamples(value) ? value : 0
    }
    @nonobjc static let windowKey = "XRGCPUView.HistoryMinutes.v1"
    @nonobjc var historyMinutes: Int {
        let value = defaults.integer(forKey: Self.windowKey)
        return (0...XRGTimedHistory.systemMaximumMinutes).contains(value) ? value : 0
    }
    @nonobjc private let timedHistory = XRGTimedHistory(channels: 3, retentionMinutes: XRGTimedHistory.systemMaximumMinutes)!
    @nonobjc private var historyObservation: UUID?
    @nonobjc private var historyTopology: Int?
    @nonobjc private let timedData = (0..<3).map { _ in XRGDataSet() }
    @nonobjc private var projectedRevision: UInt64?
    @nonobjc private var projectedMinutes = 0
    @nonobjc private var projectedInterval = 0.0
    @nonobjc private var historyInterval: Double {
        let value = settings?.graphRefresh ?? 1
        return value.isFinite && value >= XRGTimedHistory.minimumInterval ? value : XRGTimedHistory.minimumInterval
    }
    @nonobjc private(set) var selectedCPU: Int?
    private var sourceWarning: String?
    public private(set) weak var module: XRGModule?
    @nonobjc let graphLabels = XRGGraphLabels()
    @nonobjc static let activityMonitorURL = URL(fileURLWithPath: "/System/Applications/Utilities/Activity Monitor.app")
    private var settings: XRGSettings? { host?.appSettings ?? standaloneSettings }

    public override init(frame frameRect: NSRect) {
        miner = XRGCPUMiner(); processMiner = XRGProcessMiner()
        defaults = .standard; standaloneSettings = nil
        openURL = { NSWorkspace.shared.open($0) }
        super.init(frame: frameRect)
        prepare()
    }
    public required init?(coder: NSCoder) {
        miner = XRGCPUMiner(); processMiner = XRGProcessMiner()
        defaults = .standard; standaloneSettings = nil
        openURL = { NSWorkspace.shared.open($0) }
        super.init(coder: coder)
        prepare()
    }
    @nonobjc init(frame: NSRect, miner: XRGCPUMiner, processMiner: XRGProcessMiner,
                  settings: XRGSettings?, defaults: UserDefaults, openURL: @escaping (URL) -> Bool = { _ in true }) {
        self.miner = miner; self.processMiner = processMiner
        self.defaults = defaults; standaloneSettings = settings; self.openURL = openURL
        super.init(frame: frame)
        prepare()
    }
    isolated deinit { if let historyObservation { miner.removeHistoryObserver(historyObservation) } }
    private func prepare() {
        do {
            let saved = try XRGMonitorSource.load(defaults, key: Self.sourceKey)
            try saved.validateCPU(); selectedCPU = saved.source.flatMap(Int.init)
        } catch { sourceWarning = XRGMonitorSource.invalid.localizedDescription }
        historyObservation = miner.observeHistory { [weak self] event in self?.observeHistory(event) }
        for label in [graphLabels.leftLabel, graphLabels.centerLabel, graphLabels.rightLabel] { addSubview(label) }
        setGraphSize(bounds.size)
        updateLabels()
    }
    public nonisolated override func awakeFromNib() {
        super.awakeFromNib()
        MainActor.assumeIsolated { didAwake = true; bindToWindow() }
    }
    public override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow(); bindToWindow()
    }
    private func bindToWindow() {
        if window == nil { processInspector?.close() }
        let next = window as? any XRGCPUViewHost
        if host !== next || registeredManager !== next?.moduleManager {
            if host?.cpuView === self { host?.cpuView = nil }
            if let module { registeredManager?.removeModule(module) }
            registeredManager = nil; module = nil; host = next
        }
        guard didAwake, let host, let manager = host.moduleManager, settings != nil,
              registeredManager !== manager else { updateLabels(); return }
        let module = XRGModule(name: "CPU", reference: self, defaults: defaults)
        module.displayOrder = 0
        module.doesGraphUpdate = true; module.doesFastUpdate = true
        module.doesMin5Update = false; module.doesMin30Update = false
        module.isDisplayed = defaults.bool(forKey: "showCPUGraph")
        self.module = module; registeredManager = manager
        host.cpuView = self; host.initTimers()
        updateMinSize()
        manager.addModule(module)
        setGraphSize(module.currentSize)
    }
    public func setGraphSize(_ size: NSSize) {
        let width = size.width.isFinite ? size.width : 8
        setWidth(Int(min(20_000, max(8, width))))
    }
    public func setWidth(_ width: Int) {
        guard width >= 0 else { return }
        let count = retainedSamples > 0 ? retainedSamples : min(20_000, width) - (settings?.fastCPUUsage == true ? 7 : 0)
        guard count >= 0 else { return }
        if miner.systemValues.first?.numValues != count { miner.setDataSize(count) }
    }
    public override func setFrameSize(_ newSize: NSSize) {
        super.setFrameSize(newSize); setGraphSize(newSize); updateLabels()
    }
    private func textWidth(_ text: String) -> CGFloat {
        (text as NSString).size(withAttributes: [.font: settings?.graphFont ?? NSFont.systemFont(ofSize: 10)]).width
    }
    private var textOffset: CGFloat { (settings?.fastCPUUsage == true ? 7 : 0) + 6 }
    public func updateMinSize() {
        module?.minWidth = textWidth(miner.numberOfCPUs == 2 ? "100% CPU 100%" : "U: 99d 23:59") + textOffset
        module?.minHeight = XRGGraphLabels.lineHeight(settings)
        updateLabels()
    }
    public func graphUpdate(_ timer: Timer?) {
        setGraphSize(bounds.size)
        miner.loadAverage = settings?.showLoadAverage ?? false
        miner.uptime = true
        let count = miner.numberOfCPUs
        miner.graphUpdate(timer)
        if count != miner.numberOfCPUs { updateMinSize() }
        updateLabels(); needsDisplay = true
    }
    public func fastUpdate(_ timer: Timer?) {
        guard settings?.fastCPUUsage == true else { return }
        setGraphSize(bounds.size)
        let count = miner.numberOfCPUs
        miner.fastUpdate(timer)
        if count != miner.numberOfCPUs { updateMinSize() }
        updateLabels(); needsDisplay = true
    }
    public func min5Update(_ timer: Timer?) {}
    public func min30Update(_ timer: Timer?) {}
    public func shouldDrawMiniGraph() -> Bool { XRGGraphLabels.shouldDrawMiniGraph(in: bounds, settings: settings) }

    @nonobjc private func currentUsage(forCPU index: Int) -> CGFloat {
        miner.currentUsage(forCPU: index) ?? 0
    }
    @nonobjc private var selectedIndices: [Int] {
        if let selectedCPU { return (0..<miner.numberOfCPUs).contains(selectedCPU) ? [selectedCPU] : [] }
        return Array(0..<miner.numberOfCPUs)
    }
    @nonobjc var sourceAvailable: Bool { !selectedIndices.isEmpty && selectedIndices.allSatisfy { miner.currentUsage(forCPU: $0) != nil } }
    @nonobjc var totalUsage: CGFloat {
        selectedIndices.reduce(0) { $0 + currentUsage(forCPU: $1) }
    }
    @nonobjc var averageUsage: CGFloat {
        guard !selectedIndices.isEmpty else { return 0 }
        return totalUsage / CGFloat(selectedIndices.count)
    }
    @nonobjc func sortedCoreUsage() -> [CGFloat] {
        selectedIndices.compactMap { index in
            settings?.fastCPUUsage == true ? miner.fastUsage(forCPU: index) : miner.currentUsage(forCPU: index)
        }.map { $0.isFinite ? min(100, max(0, $0)) : 0 }.sorted(by: >)
    }
    @nonobjc static func uptimeText(days: Int, hours: Int, minutes: Int) -> String {
        String(format: "%ldd %ld:%02ld", max(0, days), max(0, hours), max(0, minutes))
    }
    @nonobjc static func loadText(_ value: CGFloat) -> String {
        value.isFinite && value >= 0 ? String(format: "%.2f", value) : "n/a"
    }
    @nonobjc func readings() -> (left: String, right: String) {
        let width = XRGGraphLabels.paddedTextRect(for: bounds).width
        var left = selectedCPU.map { "CPU \($0)" } ?? "CPU", right = sourceAvailable ? String(format: "%.0f%%", totalUsage) : "n/a"
        if settings?.cpuShowAverageUsage == true {
            let wide = textWidth(miner.numberOfCPUs == 2 ? "99.9% Average 99.9%" : "Average: 99.9%") + textOffset
            left += width >= wide ? "\nAverage:" : "\nAvg:"
            right += sourceAvailable ? String(format: "\n%.1f%%", averageUsage) : "\nn/a"
        }
        if settings?.showLoadAverage == true {
            left += "\nLoad:"; right += "\n" + Self.loadText(miner.currentLoadAverage)
        }
        if settings?.cpuShowUptime == true {
            left += width >= textWidth("Uptime: 99d 23:59") + textOffset ? "\nUptime:" : "\nU:"
            right += "\n" + Self.uptimeText(days: miner.uptimeDays, hours: miner.uptimeHours, minutes: miner.uptimeMinutes)
        }
        return (left, right)
    }
    private func updateLabels() {
        toolTip = detailText
        let text = readings()
        graphLabels.layoutColumnText(text.left, rightText: text.right,
            in: XRGGraphLabels.paddedTextRect(for: bounds), mini: shouldDrawMiniGraph(), settings: settings)
    }
    @nonobjc func historyRect(in rect: NSRect) -> NSRect {
        guard XRGGraphRenderer.validRect(rect) else { return .zero }
        guard settings?.fastCPUUsage == true else { return rect }
        let half = max(0, rect.height / 2 - 1)
        return NSRect(x: rect.minX, y: rect.minY + half + 1, width: rect.width, height: half)
    }
    @nonobjc func fastBarRects(in rect: NSRect) -> [NSRect] {
        guard XRGGraphRenderer.validRect(rect), settings?.fastCPUUsage == true else { return [] }
        let values = sortedCoreUsage()
        guard !values.isEmpty else { return [] }
        let slot = rect.width / CGFloat(values.count)
        let width = max(0, floor(slot - 1)), height = max(0, rect.height / 2 - 1)
        return values.enumerated().map { index, value in
            NSRect(x: rect.minX + CGFloat(index) * slot, y: rect.minY, width: width, height: height * value / 100)
        }
    }
    @nonobjc private func observeHistory(_ event: XRGCPUMiner.HistoryEvent) {
        switch event {
        case .reset: timedHistory.clear(); historyTopology = nil
        case let .sample(values, time):
            if historyTopology != values.count { timedHistory.clear(); historyTopology = values.count }
            let selected: [(CGFloat, CGFloat, CGFloat)?]
            if let selectedCPU { selected = values.indices.contains(selectedCPU) ? [values[selectedCPU]] : [nil] }
            else { selected = values }
            var components = Array(repeating: Double.nan, count: 3)
            if !selected.isEmpty && selected.allSatisfy({ $0 != nil }) {
                let valid = selected.compactMap { $0 }; let count = Double(valid.count)
                // Native stacked order is system / user / nice.
                components = [valid.reduce(0) { $0 + Double($1.1) } / count,
                              valid.reduce(0) { $0 + Double($1.0) } / count,
                              valid.reduce(0) { $0 + Double($1.2) } / count]
            }
            timedHistory.append(time: time, values: components)
        }
    }
    @nonobjc private func windowData() -> [XRGDataSet]? {
        guard historyMinutes > 0 else { return nil }
        if projectedRevision != timedHistory.revision || projectedMinutes != historyMinutes || projectedInterval != historyInterval {
            let values = timedHistory.values(minutes: historyMinutes, interval: historyInterval)!
            for index in timedData.indices {
                timedData[index].resize(values[index].count)
                for value in values[index] { timedData[index].setNextValue(value.isFinite ? value : Double(XRGGraphRenderer.missingValue)) }
            }
            projectedRevision = timedHistory.revision; projectedMinutes = historyMinutes; projectedInterval = historyInterval
        }
        return timedData
    }
    @nonobjc func historyLayers() -> [XRGDataSet] {
        guard !selectedIndices.isEmpty,
              let data = windowData() ?? selectedCPU.flatMap({ miner.dataForCPU($0) }) ?? (selectedCPU == nil ? miner.combinedData() : nil), data.count == 3,
              let total = XRGCPUMiner.sumHistories(data) else { return [] }
        guard settings?.separateCPUColor == true,
              let systemAndUser = XRGCPUMiner.sumHistories(Array(data.prefix(2))) else { return [total] }
        return [total, systemAndUser, data[0]]
    }
    public override func draw(_ dirtyRect: NSRect) {
        guard !isHidden, let settings, let context = NSGraphicsContext.current, XRGGraphRenderer.validRect(bounds) else { return }
        NSGraphicsContext.saveGraphicsState()
        defer { NSGraphicsContext.restoreGraphicsState() }
        updateLabels()
        settings.graphColor(.cpu, component: 0).set(); context.cgContext.fill(bounds)
        if shouldDrawMiniGraph() {
            XRGGraphRenderer.drawGraphBars(sortedCoreUsage().map { NSNumber(value: Double($0)) }, upperBound: 100, lowerBound: 0, in: bounds, settings: settings, module: .cpu)
        } else { drawGraph(bounds) }
        XRGGraphRenderer.drawGraphEffect(in: bounds, settings: settings, module: .cpu)
    }
    public func drawGraph(_ rect: NSRect) {
        guard !isHidden, let settings, let context = NSGraphicsContext.current, XRGGraphRenderer.validRect(rect) else { return }
        NSGraphicsContext.saveGraphicsState()
        defer { NSGraphicsContext.restoreGraphicsState() }
        context.shouldAntialias = settings.antiAliasing
        settings.graphColor(.cpu, component: 1).set()
        for bar in fastBarRects(in: rect) { bar.fill(using: .copy) }
        let colors = settings.separateCPUColor ? [settings.graphColor(.cpu, component: 3), settings.graphColor(.cpu, component: 2), settings.graphColor(.cpu, component: 1)] : [settings.graphColor(.cpu, component: 1)]
        for (data, color) in zip(historyLayers(), colors) {
            XRGGraphRenderer.drawCurve(data, upperBound: 100, lowerBound: 0, in: historyRect(in: rect), flipped: false, filled: true, color: color, style: settings.curveStyle(.cpu))
        }
    }
    @nonobjc func makeMenu() -> NSMenu {
        let menu = NSMenu(title: "CPU View")
        func item(_ title: String, _ action: Selector) -> NSMenuItem {
            let item = NSMenuItem(title: title, action: action, keyEquivalent: "")
            item.target = self; return item
        }
        menu.addItem(item("Top 10 CPU Processes", #selector(emptyEvent(_:))))
        processMiner.graphUpdate(nil)
        for process in processMiner.processesSortedByCPUUsage().prefix(10) {
            let cpu = (process["%cpu"] as? NSNumber)?.doubleValue ?? 0
            let pid = process["pid"] as? Int ?? 0, command = process["command"] as? String ?? ""
            menu.addItem(item(String(format: "%.1f%% - %@ (id %ld)", cpu, command, pid), #selector(emptyEvent(_:))))
        }
        menu.addItem(.separator())
        let sources = item("CPU Source", #selector(emptyEvent(_:)))
        let submenu = NSMenu(title: "CPU Source")
        let all = item("All Logical CPUs", #selector(selectSource(_:))); all.tag = -1
        all.state = selectedCPU == nil ? .on : .off; submenu.addItem(all)
        for index in 0..<miner.numberOfCPUs {
            let option = item("Logical CPU \(index)", #selector(selectSource(_:))); option.tag = index
            option.state = selectedCPU == index ? .on : .off; submenu.addItem(option)
        }
        if let selectedCPU, !selectedIndices.contains(selectedCPU) {
            let missing = item("Logical CPU \(selectedCPU) (unavailable)", #selector(selectSource(_:)))
            missing.tag = selectedCPU; missing.state = .on; submenu.addItem(missing)
        }
        sources.submenu = submenu; menu.addItem(sources)
        let retention = item("CPU History", #selector(emptyEvent(_:)))
        let choices = NSMenu(title: "CPU History")
        var counts = XRGSamplingSettings.cpuHistoryPresets
        if !counts.contains(retainedSamples) { counts.append(retainedSamples); counts.sort() }
        for count in counts {
            let option = item(count == 0 ? "Automatic (graph width)" : "\(count) samples", #selector(selectHistory(_:)))
            option.tag = count; option.state = retainedSamples == count ? .on : .off; choices.addItem(option)
        }
        retention.submenu = choices; menu.addItem(retention)
        let window = item("CPU Time Window", #selector(emptyEvent(_:))), windows = NSMenu(title: "CPU Time Window")
        var minutes = [0, 1, 5, 10, 30, 60]
        if !minutes.contains(historyMinutes) { minutes.append(historyMinutes); minutes.sort() }
        for value in minutes {
            let option = item(value == 0 ? "Use sample count" : value == 1 ? "1 minute" : "\(value) minutes", #selector(selectHistoryWindow(_:)))
            option.tag = value; option.state = historyMinutes == value ? .on : .off; windows.addItem(option)
        }
        window.submenu = windows; menu.addItem(window)
        menu.addItem(item("CPU Details…", #selector(showDetails(_:))))
        menu.addItem(item("Processes…", #selector(openProcesses(_:))))
        menu.addItem(item("Reset Graph", #selector(clearData(_:))))
        menu.addItem(.separator())
        menu.addItem(item("Open Activity Monitor...", #selector(openActivityMonitor(_:))))
        menu.addItem(item("Open XRG-ng CPU Preferences...", #selector(openCPUPreferences(_:))))
        menu.addItem(.separator())
        return menu
    }
    public override func menu(for event: NSEvent) -> NSMenu? { makeMenu() }
    @objc func selectHistory(_ sender: Any?) {
        guard let item = sender as? NSMenuItem, XRGSamplingSettings.validCPUHistorySamples(item.tag) else { return }
        defaults.set(item.tag, forKey: Self.historyKey); defaults.set(0, forKey: Self.windowKey)
        setGraphSize(bounds.size); needsDisplay = true
    }
    @objc func selectHistoryWindow(_ sender: Any?) {
        guard let item = sender as? NSMenuItem, (0...XRGTimedHistory.systemMaximumMinutes).contains(item.tag) else { return }
        defaults.set(item.tag, forKey: Self.windowKey); updateLabels(); needsDisplay = true
    }
    public func openProcesses(_ sender: Any?) {
        if processInspector == nil { processInspector = XRGProcessInspector(miner: processMiner, defaults: defaults, sort: .cpu) }
        processInspector?.present()
    }
    @nonobjc var detailText: String {
        let scope = selectedCPU.map { "logical CPU \($0)" } ?? "all \(miner.numberOfCPUs) logical CPUs"
        let capacity = miner.systemValues.first?.numValues ?? 0
        let nominal = XRGSamplingSettings.nominalSpan(samples: capacity, interval: XRGGraphWindow.validRefresh(settings?.graphRefresh))
            .map { String(format: "%.3f seconds", $0) } ?? "unavailable"
        return [sourceWarning, "Scope: \(scope). \(sourceAvailable ? "Counters available." : "Selected CPU counters unavailable; no replacement is chosen.")",
                "CPU history capacity: \(capacity) samples. Nominal span at the current sampling target: \(nominal). Delays and cadence changes affect the actual span. Explicit capacity survives graph resizing; Automatic follows graph width. Changing capacity retains newest samples and collector baselines.",
                historyMinutes > 0 ? "CPU time window: \(historyMinutes) \(historyMinutes == 1 ? "minute" : "minutes") ending at the latest completed observation. Projection uses the current sampling target (\(historyInterval) seconds); unobserved time bins remain gaps. Rate timing and sample buffers are independent. Source/topology changes start a fresh time history. Capacity is bounded to one hour / 20,000 observations." : nil,
                "CPU total is core-percent: each logical CPU contributes up to 100%. The aggregate history is normalized to 0–100%; a selected CPU uses its own 0–100% history. System, user and nice retain the existing stacked presentation.",
                "Average is the latest interval’s mean across the selected logical CPUs, normalized to 0–100%. Graph width, resizing and clearing history do not affect it. All selected cores must have a measured interval; missing or zero-progress intervals show n/a, not idle. Load and uptime remain system-wide; load is not CPU percent. Process listings remain system-wide.",
                "Selection switches among already collected per-CPU histories without another hardware read. Missing indices stay pinned. Indices are kernel logical-CPU slots and may refer to different hardware after reboot or topology changes. Fast bars are sorted by usage within the selected scope; they are not persistent physical-core labels.",
                "Reset Graph clears history only. It retains source choices, current readings, normal/fast sampling baselines, fast-bar smoothing and availability, without reading hardware. Failed reads append gaps and invalidate that stream’s baseline; recovery first establishes a fresh interval. CPU intervals must increase on the continuous monotonic clock and be at most five minutes, including time asleep. Invalid or delayed intervals leave gaps while retaining earlier observations. CPU count changes clear histories and both streams’ baselines because logical slots may have changed. Mach tick counters wrap at 32 bits."].compactMap { $0 }.joined(separator: "\n\n")
    }
    @nonobjc func applyCPUSource(_ index: Int?) throws {
        let next = XRGMonitorSource(source: index.map(String.init)); try next.validateCPU()
        defaults.set(try next.encoded(), forKey: Self.sourceKey)
        if selectedCPU != index { timedHistory.clear() }
        selectedCPU = index; sourceWarning = nil
        updateLabels(); needsDisplay = true
    }
    public func selectSource(_ sender: NSMenuItem) { try? applyCPUSource(sender.tag == -1 ? nil : sender.tag) }
    public func showDetails(_ sender: Any?) {
        guard let window else { return }
        XRGMonitorDetails.present(title: "CPU Details", text: detailText, in: window)
    }
    public func emptyEvent(_ sender: Any?) {}
    public func clearData(_ sender: Any?) { miner.reset(); updateLabels(); needsDisplay = true }
    public func openActivityMonitor(_ sender: Any?) { _ = openURL(Self.activityMonitorURL) }
    public func openCPUPreferences(_ sender: Any?) { host?.showCPUPreferences() }
    public override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
    public override func mouseDown(with event: NSEvent) { window?.mouseDown(with: event) }
    public override func mouseDragged(with event: NSEvent) { window?.mouseDragged(with: event) }
    public override func mouseUp(with event: NSEvent) { window?.mouseUp(with: event) }
}
