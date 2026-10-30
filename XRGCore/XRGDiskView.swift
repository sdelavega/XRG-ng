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

@MainActor @objc public protocol XRGDiskViewHost: NSObjectProtocol {
    var appSettings: XRGSettings? { get }
    var moduleManager: XRGModuleManager? { get }
    var diskView: XRGDiskView? { get set }
    func initTimers()
    func showDiskPreferences()
}

@MainActor
@objc(XRGDiskView) @objcMembers
public final class XRGDiskView: NSView, XRGModuleView {
    private let miner: XRGDiskMiner
    private let defaults: UserDefaults
    private let standaloneSettings: XRGSettings?
    private let openURL: (URL) -> Bool
    private weak var host: (any XRGDiskViewHost)?
    private weak var registeredManager: XRGModuleManager?
    private var didAwake = false
    private var wasMini = false
    public private(set) weak var module: XRGModule?
    @nonobjc let graphLabels = XRGGraphLabels()
    @nonobjc let topRates = XRGGraphLabels()
    @nonobjc let bottomRates = XRGGraphLabels()
    @nonobjc private(set) var fastReadValue: CGFloat = 0
    @nonobjc private(set) var fastWriteValue: CGFloat = 0
    @nonobjc private(set) var fastScale: CGFloat = 1_048_576
    @nonobjc static let diskUtilityURL = URL(fileURLWithPath: "/System/Applications/Utilities/Disk Utility.app")
    private var settings: XRGSettings? { host?.appSettings ?? standaloneSettings }

    public override init(frame frameRect: NSRect) {
        miner = XRGDiskMiner()
        defaults = .standard; standaloneSettings = nil
        openURL = { NSWorkspace.shared.open($0) }
        super.init(frame: frameRect)
        prepare()
    }
    public required init?(coder: NSCoder) {
        miner = XRGDiskMiner()
        defaults = .standard; standaloneSettings = nil
        openURL = { NSWorkspace.shared.open($0) }
        super.init(coder: coder)
        prepare()
    }
    @nonobjc init(frame: NSRect, miner: XRGDiskMiner, settings: XRGSettings?, defaults: UserDefaults,
                  openURL: @escaping (URL) -> Bool = { _ in true }) {
        self.miner = miner; self.defaults = defaults; standaloneSettings = settings; self.openURL = openURL
        super.init(frame: frame); prepare()
    }
    private func prepare() {
        for label in [graphLabels.leftLabel, graphLabels.centerLabel, graphLabels.rightLabel,
                      topRates.rightLabel, bottomRates.rightLabel] { addSubview(label) }
        setGraphSize(bounds.size)
        wasMini = shouldDrawMiniGraph()
        updateLabels()
    }
    public nonisolated override func awakeFromNib() {
        super.awakeFromNib()
        MainActor.assumeIsolated { didAwake = true; bindToWindow() }
    }
    public override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        bindToWindow()
    }
    private func bindToWindow() {
        let next = window as? any XRGDiskViewHost
        if host !== next || registeredManager !== next?.moduleManager {
            if host?.diskView === self { host?.diskView = nil }
            if let module { registeredManager?.removeModule(module) }
            registeredManager = nil; module = nil; host = next
        }
        guard didAwake, let host, let manager = host.moduleManager, settings != nil,
              registeredManager !== manager else { updateLabels(); return }
        let module = XRGModule(name: "Disk", reference: self, defaults: defaults)
        module.displayOrder = 7
        // Core history and accounting continue when only presentation is hidden.
        module.alwaysDoesGraphUpdate = true
        module.doesGraphUpdate = true; module.doesFastUpdate = true
        module.doesMin5Update = true; module.doesMin30Update = false
        module.isDisplayed = defaults.bool(forKey: "showDiskGraph")
        self.module = module; registeredManager = manager
        host.diskView = self
        host.initTimers()
        updateMinSize()
        manager.addModule(module)
        setGraphSize(module.currentSize)
    }
    public func setGraphSize(_ size: NSSize) {
        let width = size.width.isFinite ? size.width : 1
        setWidth(Int32(min(20_000, max(1, width))))
    }
    public func setWidth(_ width: Int32) {
        guard width >= 0 else { return }
        let count = retainedSamples > 0 ? retainedSamples : min(20_000, Int(width))
        if miner.readValues.numValues != count {
            if retainedSamples > 0 { miner.resizeHistory(count) } else { miner.setDataSize(count) }
        }
    }
    public override func setFrameSize(_ newSize: NSSize) {
        super.setFrameSize(newSize)
        setGraphSize(newSize)
        updateLabels()
    }
    public func updateMinSize() {
        guard let settings else { return }
        module?.minWidth = ("D1023K W" as NSString).size(withAttributes: [.font: settings.graphFont ?? NSFont.systemFont(ofSize: 10)]).width + 6
        module?.minHeight = XRGGraphLabels.lineHeight(settings)
        updateLabels()
    }
    private func updateMode() {
        let mini = shouldDrawMiniGraph()
        if mini && !wasMini {
            miner.rebaseFast()
            fastReadValue = 0; fastWriteValue = 0; fastScale = 1_048_576
        }
        wasMini = mini
    }
    public func graphUpdate(_ timer: Timer?) {
        miner.update()
        updateLabels()
        needsDisplay = true
    }
    public func fastUpdate(_ timer: Timer?) {
        updateMode()
        guard shouldDrawMiniGraph() else { return }
        guard miner.updateFast() else { return }
        fastReadValue = XRGCommon.dampedValue(usingPreviousValue: fastReadValue, currentValue: miner.fastReadRate)
        fastWriteValue = XRGCommon.dampedValue(usingPreviousValue: fastWriteValue, currentValue: miner.fastWriteRate)
        if fastReadValue + fastWriteValue > 0 {
            fastScale = XRGCommon.dampedMax(usingPreviousMax: fastScale, currentMax: fastReadValue + fastWriteValue, baseMax: 1_048_576)
        }
        updateLabels()
        needsDisplay = true
    }
    public func min5Update(_ timer: Timer?) {
        // Every sample enumerates current devices; no cached iterator needs refreshing.
    }
    public func min30Update(_ timer: Timer?) {}
    public func shouldDrawMiniGraph() -> Bool { XRGGraphLabels.shouldDrawMiniGraph(in: bounds, settings: settings) }
    @nonobjc var graphMode: Int {
        let mode = settings?.diskGraphMode ?? 0
        return mode == 0 || mode == 1 ? mode : 2
    }
    @nonobjc func graphScale() -> CGFloat {
        let maximum = windowData()?[2].max ?? miner.totalValues.max
        return max(1, maximum.isFinite ? maximum : 0)
    }
    @nonobjc func miniValues() -> [NSNumber] {
        graphMode == 2 ? [NSNumber(value: Double(fastWriteValue)), NSNumber(value: Double(fastReadValue))]
            : [NSNumber(value: Double(fastReadValue)), NSNumber(value: Double(fastWriteValue))]
    }
    @nonobjc func plots() -> [(data: XRGDataSet, flipped: Bool)] {
        let data = windowData() ?? [miner.readValues, miner.writeValues, miner.totalValues]
        return [(graphMode == 0 ? data[2] : data[0], graphMode == 1), (data[1], graphMode == 2)]
    }
    private func title() -> String {
        let font = settings?.graphFont ?? NSFont.systemFont(ofSize: 10)
        return ("Disk1023.9K W" as NSString).size(withAttributes: [.font: font]).width + 6 > bounds.width ? "D" : "Disk"
    }
    @nonobjc func scaleText() -> String {
        let value = Double(graphScale())
        if value >= 1_048_576 { return String(format: "%.2fM/s", value / 1_048_576) }
        if value >= 1024 { return String(format: "%.1fK/s", value / 1024) }
        return String(format: "%.0fB/s", value.rounded(.towardZero))
    }
    @nonobjc func fullLeftReading() -> String {
        [title(), scaleText(), (miner.transfersAreLowerBound ? "≥" : "") + XRGCommon.formattedString(forBytes: Double(miner.totalBytesSinceLoad))].joined(separator: "\n")
    }
    public func readBytesString() -> String { (miner.countersAvailable ? XRGCommon.formattedString(forBytes: Double(miner.readRate)) : "—") + " R" }
    public func writeBytesString() -> String { (miner.countersAvailable ? XRGCommon.formattedString(forBytes: Double(miner.writeRate)) : "—") + " W" }
    private func updateLabels() {
        toolTip = miner.transferDetails
        updateMode()
        let mini = shouldDrawMiniGraph()
        let rect = XRGGraphLabels.paddedTextRect(for: bounds)
        let height = XRGGraphLabels.lineHeight(settings)
        topRates.rightLabel.isHidden = mini || graphMode == 0
        bottomRates.rightLabel.isHidden = mini
        if mini {
            graphLabels.layoutColumnText(title(),
                rightText: miner.countersAvailable ? XRGCommon.formattedString(forBytes: Double(miner.readRate + miner.writeRate)) + "/s" : "—",
                in: rect, mini: true, settings: settings)
            topRates.layoutColumnText(nil, rightText: nil, in: .zero, mini: false, settings: settings)
            bottomRates.layoutColumnText(nil, rightText: nil, in: .zero, mini: false, settings: settings)
            return
        }
        let complete = fullLeftReading()
        let lines = complete.components(separatedBy: "\n")
        let available = max(1, ceil(max(0, bounds.height) / height) - 1)
        let count = available >= CGFloat(lines.count) ? lines.count : Int(available)
        let leftRect = NSRect(x: rect.minX, y: rect.minY, width: max(0, rect.width * 0.52 - 8), height: rect.height)
        graphLabels.layoutColumnText(lines.prefix(count).joined(separator: "\n"),
                                    rightText: nil, in: leftRect, mini: false, settings: settings)
        graphLabels.leftLabel.fullAccessibilityText = complete
        let read = readBytesString(), write = writeBytesString()
        let bottomRect = NSRect(x: rect.minX, y: bounds.minY, width: rect.width, height: min(bounds.height, height * (graphMode == 0 ? 2 : 1)))
        bottomRates.layoutColumnText(nil, rightText: graphMode == 0 ? read + "\n" + write : graphMode == 1 ? write : read,
                           in: bottomRect, mini: false, settings: settings)
        let topRect = NSRect(x: rect.minX, y: max(bounds.minY, bounds.maxY - height), width: rect.width, height: min(height, bounds.height))
        topRates.layoutColumnText(nil, rightText: graphMode == 0 ? nil : graphMode == 1 ? read : write,
                        in: topRect, mini: false, settings: settings)
    }
    public override func draw(_ dirtyRect: NSRect) {
        guard !isHidden, let settings, let context = NSGraphicsContext.current, XRGGraphRenderer.validRect(bounds) else { return }
        NSGraphicsContext.saveGraphicsState()
        defer { NSGraphicsContext.restoreGraphicsState() }
        updateLabels()
        settings.graphColor(.disk, component: 0).set(); context.cgContext.fill(bounds)
        if shouldDrawMiniGraph() {
            guard miner.countersAvailable && miner.fastCountersAvailable else { return }
            XRGGraphRenderer.drawGraphBars(miniValues(), upperBound: Double(max(1_048_576, fastScale)), lowerBound: 0, in: bounds, settings: settings, module: .disk)
            return
        }
        context.shouldAntialias = settings.antiAliasing
        for (plot, color) in zip(plots(), [settings.graphColor(.disk, component: 2), settings.graphColor(.disk, component: 1)]) {
            XRGGraphRenderer.drawCurve(plot.data, upperBound: graphScale(), lowerBound: 0,
                in: bounds, flipped: plot.flipped, filled: true, color: color, style: settings.curveStyle(.disk))
        }
        XRGGraphRenderer.drawGraphEffect(in: bounds, settings: settings, module: .disk)
    }
    public func convertHeight(_ value: Int32) -> Int32 {
        let height = max(0, bounds.height - XRGGraphLabels.lineHeight(settings) * 2)
        let result = Double(max(0, value)) / 100 * Double(height)
        guard result.isFinite, result < Double(Int32.max) else { return result > 0 ? Int32.max : 0 }
        return Int32(max(0, result))
    }

    @nonobjc func makeMenu() -> NSMenu {
        let menu = NSMenu(title: "Disk View")
        func item(_ title: String, _ action: Selector) -> NSMenuItem {
            let item = NSMenuItem(title: title, action: action, keyEquivalent: "")
            item.target = self; return item
        }
        menu.addItem(item("Transfer Details…", #selector(showTransferDetails(_:))))
        menu.addItem(XRGHistoryRetention.menu("Disk History", count: retainedSamples, target: self, action: #selector(selectHistory(_:)), rootAction: #selector(emptyEvent(_:))))
        menu.addItem(XRGSystemTimeWindow.menu("Disk Time Window", minutes: historyMinutes, target: self, action: #selector(selectHistoryWindow(_:)), rootAction: #selector(emptyEvent(_:))))
        menu.addItem(item("Reset Graph", #selector(clearData(_:))))
        menu.addItem(item("Reset Session Transfers", #selector(resetTransfers(_:))))
        menu.addItem(.separator())
        menu.addItem(item("Open Disk Utility...", #selector(openDiskUtility(_:))))
        menu.addItem(item("Open XRG-ng Disk Preferences...", #selector(openDiskPreferences(_:))))
        return menu
    }
    public override func menu(for event: NSEvent) -> NSMenu? { makeMenu() }
    public func emptyEvent(_ sender: Any?) {}
    @nonobjc static let windowKey = "XRGDiskView.HistoryMinutes.v1"
    @nonobjc var historyMinutes: Int { XRGSystemTimeWindow.saved(defaults, key: Self.windowKey) }
    @nonobjc private let timeProjection = XRGTimeWindowProjection(channels: 3)
    @nonobjc private func windowData() -> [XRGDataSet]? {
        timeProjection.values(from: miner.timedHistory, minutes: historyMinutes, interval: Double(settings?.graphRefresh ?? 1))
    }
    @objc func selectHistoryWindow(_ sender: Any?) {
        guard XRGSystemTimeWindow.store(sender, defaults: defaults, key: Self.windowKey) else { return }
        updateLabels(); needsDisplay = true
    }
    @nonobjc static let historyKey = "XRGDiskView.HistorySamples.v1"
    @nonobjc var retainedSamples: Int { XRGHistoryRetention.saved(defaults, key: Self.historyKey) }
    @objc func selectHistory(_ sender: Any?) {
        guard XRGHistoryRetention.store(sender, defaults: defaults, key: Self.historyKey) else { return }
        defaults.set(0, forKey: Self.windowKey)
        setGraphSize(bounds.size); needsDisplay = true
    }
    public func openDiskUtility(_ sender: Any?) { _ = openURL(Self.diskUtilityURL) }
    public func openDiskPreferences(_ sender: Any?) { host?.showDiskPreferences() }
    public func clearData(_ sender: Any?) {
        miner.reset()
        updateLabels(); needsDisplay = true
    }
    public func resetTransfers(_ sender: Any?) {
        miner.resetTransfers()
        updateLabels(); needsDisplay = true
    }
    public func showTransferDetails(_ sender: Any?) {
        guard let window else { return }
        let alert = NSAlert()
        alert.messageText = "Disk Transfer Details"
        alert.informativeText = miner.transferDetails
        alert.addButton(withTitle: "Close")
        alert.beginSheetModal(for: window)
    }
    public override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
    public override func mouseDown(with event: NSEvent) { window?.mouseDown(with: event) }
    public override func mouseDragged(with event: NSEvent) { window?.mouseDragged(with: event) }
    public override func mouseUp(with event: NSEvent) { window?.mouseUp(with: event) }
}
