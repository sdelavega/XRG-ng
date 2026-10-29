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
    private let processMiner: XRGProcessMiner
    private let defaults: UserDefaults
    private let standaloneSettings: XRGSettings?
    private let openURL: (URL) -> Bool
    private weak var host: (any XRGCPUViewHost)?
    private weak var registeredManager: XRGModuleManager?
    private var didAwake = false
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
    private func prepare() {
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
        let count = min(20_000, width) - (settings?.fastCPUUsage == true ? 7 : 0)
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
        guard let data = miner.dataForCPU(index) else { return 0 }
        let total = data.reduce(CGFloat(0)) { $0 + $1.currentValue }
        return total.isFinite ? min(100, max(0, total)) : 0
    }
    @nonobjc var totalUsage: CGFloat {
        (0..<miner.numberOfCPUs).reduce(0) { $0 + currentUsage(forCPU: $1) }
    }
    @nonobjc var averageUsage: CGFloat {
        guard miner.numberOfCPUs > 0 else { return 0 }
        var result: CGFloat = 0
        for index in 0..<miner.numberOfCPUs {
            let value = miner.dataForCPU(index)?.reduce(CGFloat(0)) { $0 + $1.average } ?? 0
            result += value.isFinite ? min(100, max(0, value)) : 0
        }
        return result / CGFloat(miner.numberOfCPUs)
    }
    @nonobjc func sortedCoreUsage() -> [CGFloat] {
        let values = settings?.fastCPUUsage == true ? miner.fastValues.map { CGFloat($0.doubleValue) }
            : (0..<miner.numberOfCPUs).map { currentUsage(forCPU: $0) }
        return values.map { $0.isFinite ? min(100, max(0, $0)) : 0 }.sorted(by: >)
    }
    @nonobjc static func uptimeText(days: Int, hours: Int, minutes: Int) -> String {
        String(format: "%ldd %ld:%02ld", max(0, days), max(0, hours), max(0, minutes))
    }
    @nonobjc static func loadText(_ value: CGFloat) -> String {
        value.isFinite && value >= 0 ? String(format: "%.2f", value) : "n/a"
    }
    @nonobjc func readings() -> (left: String, right: String) {
        let width = XRGGraphLabels.paddedTextRect(for: bounds).width
        var left = "CPU", right = String(format: "%.0f%%", totalUsage)
        if settings?.cpuShowAverageUsage == true {
            let wide = textWidth(miner.numberOfCPUs == 2 ? "99.9% Average 99.9%" : "Average: 99.9%") + textOffset
            left += width >= wide ? "\nAverage:" : "\nAvg:"
            right += String(format: "\n%.1f%%", averageUsage)
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
    @nonobjc func historyLayers() -> [XRGDataSet] {
        guard let data = miner.combinedData(), data.count == 3,
              let total = XRGDataSet(contentsOfOtherDataSet: data[0]) else { return [] }
        total.addOtherDataSetValues(data[1]); total.addOtherDataSetValues(data[2])
        guard settings?.separateCPUColor == true,
              let systemAndUser = XRGDataSet(contentsOfOtherDataSet: data[0]) else { return [total] }
        systemAndUser.addOtherDataSetValues(data[1])
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
        menu.addItem(item("Reset Graph", #selector(clearData(_:))))
        menu.addItem(.separator())
        menu.addItem(item("Open Activity Monitor...", #selector(openActivityMonitor(_:))))
        menu.addItem(item("Open XRG-ng CPU Preferences...", #selector(openCPUPreferences(_:))))
        menu.addItem(.separator())
        return menu
    }
    public override func menu(for event: NSEvent) -> NSMenu? { makeMenu() }
    public func emptyEvent(_ sender: Any?) {}
    public func clearData(_ sender: Any?) { miner.reset(); updateLabels(); needsDisplay = true }
    public func openActivityMonitor(_ sender: Any?) { _ = openURL(Self.activityMonitorURL) }
    public func openCPUPreferences(_ sender: Any?) { host?.showCPUPreferences() }
    public override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
    public override func mouseDown(with event: NSEvent) { window?.mouseDown(with: event) }
    public override func mouseDragged(with event: NSEvent) { window?.mouseDragged(with: event) }
    public override func mouseUp(with event: NSEvent) { window?.mouseUp(with: event) }
}
