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

@MainActor @objc public protocol XRGNetViewHost: NSObjectProtocol {
    var appSettings: XRGSettings? { get }
    var moduleManager: XRGModuleManager? { get }
    var netView: XRGNetView? { get set }
    func initTimers()
    func showNetworkPreferences()
}

@MainActor
@objc(XRGNetView) @objcMembers
public final class XRGNetView: NSView, XRGModuleView {
    public let miner: XRGNetMiner
    public let fastMiner: XRGNetMiner
    private let defaults: UserDefaults
    private let standaloneSettings: XRGSettings?
    private let openURL: (URL) -> Bool
    private let utilityURL: () -> URL?
    private weak var host: (any XRGNetViewHost)?
    private weak var registeredManager: XRGModuleManager?
    private var didAwake = false
    private var wasMini = false
    public private(set) weak var module: XRGModule?
    @nonobjc let graphLabels = XRGGraphLabels()
    @nonobjc let topRates = XRGGraphLabels()
    @nonobjc let bottomRates = XRGGraphLabels()
    @nonobjc private(set) var fastRXValue: CGFloat = 0
    @nonobjc private(set) var fastTXValue: CGFloat = 0
    @nonobjc static let networkSettingsURL = URL(fileURLWithPath: "/System/Library/PreferencePanes/Network.prefPane")
    private var settings: XRGSettings? { host?.appSettings ?? standaloneSettings }

    public override init(frame frameRect: NSRect) {
        miner = XRGNetMiner(); fastMiner = XRGNetMiner()
        defaults = .standard; standaloneSettings = nil
        openURL = { NSWorkspace.shared.open($0) }
        utilityURL = { NSWorkspace.shared.urlForApplication(withBundleIdentifier: "com.apple.NetworkUtility") }
        super.init(frame: frameRect)
        prepare()
    }
    public required init?(coder: NSCoder) {
        miner = XRGNetMiner(); fastMiner = XRGNetMiner()
        defaults = .standard; standaloneSettings = nil
        openURL = { NSWorkspace.shared.open($0) }
        utilityURL = { NSWorkspace.shared.urlForApplication(withBundleIdentifier: "com.apple.NetworkUtility") }
        super.init(coder: coder)
        prepare()
    }
    @nonobjc init(frame: NSRect, miner: XRGNetMiner, fastMiner: XRGNetMiner,
                  settings: XRGSettings?, defaults: UserDefaults,
                  openURL: @escaping (URL) -> Bool = { _ in true }, utilityURL: @escaping () -> URL? = { nil }) {
        self.miner = miner; self.fastMiner = fastMiner
        self.defaults = defaults; standaloneSettings = settings
        self.openURL = openURL; self.utilityURL = utilityURL
        super.init(frame: frame)
        prepare()
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
        let next = window as? any XRGNetViewHost
        if host !== next {
            if host?.netView === self { host?.netView = nil }
            if let module { registeredManager?.removeModule(module) }
            registeredManager = nil; module = nil; host = next
        }
        guard didAwake, let host, let manager = host.moduleManager, settings != nil,
              registeredManager !== manager else { updateLabels(); return }
        let module = XRGModule(name: "Network", reference: self, defaults: defaults)
        module.displayOrder = 6
        module.doesGraphUpdate = true; module.doesFastUpdate = true
        module.doesMin5Update = false; module.doesMin30Update = false
        module.isDisplayed = defaults.bool(forKey: "showNetworkGraph")
        self.module = module; registeredManager = manager
        host.netView = self
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
        if miner.rxValues.numValues != count {
            if retainedSamples > 0 { miner.resizeHistory(count) } else { miner.setDataSize(count) }
        }
        if fastMiner.rxValues.numValues != count {
            if retainedSamples > 0 { fastMiner.resizeHistory(count) } else { fastMiner.setDataSize(count) }
        }
    }
    public override func setFrameSize(_ newSize: NSSize) {
        super.setFrameSize(newSize)
        setGraphSize(newSize)
        updateLabels()
    }
    public func updateMinSize() {
        guard let settings else { return }
        module?.minWidth = ("N1023K Rx" as NSString).size(withAttributes: [.font: settings.graphFont ?? NSFont.systemFont(ofSize: 10)]).width
        module?.minHeight = XRGGraphLabels.lineHeight(settings)
        updateLabels()
    }
    private func synchronizeSelection() {
        guard let settings else { return }
        let selected = settings.networkInterface
        if miner.monitorNetworkInterface != selected || fastMiner.monitorNetworkInterface != selected {
            miner.monitorNetworkInterface = selected
            fastMiner.monitorNetworkInterface = selected
            fastRXValue = 0; fastTXValue = 0
        }
    }
    private func updateMode() {
        let mini = shouldDrawMiniGraph()
        if mini && !wasMini {
            fastMiner.rebase()
            fastMiner.reset()
            fastRXValue = 0; fastTXValue = 0
        }
        wasMini = mini
    }
    public func graphUpdate(_ timer: Timer?) {
        synchronizeSelection()
        miner.getLatestNetInfo()
        updateLabels()
        needsDisplay = true
    }
    public func fastUpdate(_ timer: Timer?) {
        updateMode()
        guard shouldDrawMiniGraph() else { return }
        synchronizeSelection()
        guard fastMiner.getLatestNetInfo() else { updateLabels(); needsDisplay = true; return }
        fastRXValue = XRGCommon.dampedValue(usingPreviousValue: fastRXValue, currentValue: fastMiner.currentRX())
        fastTXValue = XRGCommon.dampedValue(usingPreviousValue: fastTXValue, currentValue: fastMiner.currentTX())
        updateLabels()
        needsDisplay = true
    }
    public func min5Update(_ timer: Timer?) {}
    public func min30Update(_ timer: Timer?) {}
    public func shouldDrawMiniGraph() -> Bool { XRGGraphLabels.shouldDrawMiniGraph(in: bounds, settings: settings) }
    @nonobjc var graphMode: Int {
        let mode = settings?.netGraphMode ?? 0
        return mode == 0 || mode == 1 ? mode : 2
    }
    @nonobjc func graphScale(fast: Bool = false) -> CGFloat {
        let maximum = fast ? fastMiner.maxBandwidth() : miner.maxBandwidth()
        return max(1, CGFloat(max(0, settings?.netMinGraphScale ?? 1024)), maximum.isFinite ? maximum : 0)
    }
    @nonobjc func miniValues() -> [NSNumber] {
        graphMode == 1 ? [NSNumber(value: Double(fastTXValue)), NSNumber(value: Double(fastRXValue))]
            : [NSNumber(value: Double(fastRXValue)), NSNumber(value: Double(fastTXValue))]
    }
    @nonobjc func plots() -> [(data: XRGDataSet, flipped: Bool)] {
        [(graphMode == 0 ? miner.totalValues : miner.rxValues, graphMode == 2), (miner.txValues, graphMode == 1)]
    }
    private func title() -> String {
        let font = settings?.graphFont ?? NSFont.systemFont(ofSize: 10)
        return ("Net1023K Rx" as NSString).size(withAttributes: [.font: font]).width + 6 > bounds.width ? "N" : "Net"
    }
    @nonobjc func fullLeftReading() -> String {
        var lines = [title(), XRGCommon.formattedString(forBytes: Double(graphScale())) + "/s"]
        if settings?.showTotalBandwidthSinceBoot == true { lines.append((miner.kernelTotalIsLowerBound ? "≥" : "") + XRGCommon.formattedString(forBytes: Double(miner.totalBytesSinceBoot))) }
        if settings?.showTotalBandwidthSinceLoad == true { lines.append((miner.transfersAreLowerBound ? "≥" : "") + XRGCommon.formattedString(forBytes: Double(miner.totalBytesSinceLoad))) }
        return lines.joined(separator: "\n")
    }
    private func updateLabels() {
        synchronizeSelection()
        toolTip = miner.transferDetails
        updateMode()
        let mini = shouldDrawMiniGraph()
        let rect = XRGGraphLabels.paddedTextRect(for: bounds)
        let height = XRGGraphLabels.lineHeight(settings)
        topRates.rightLabel.isHidden = mini || graphMode == 0
        bottomRates.rightLabel.isHidden = mini
        if mini {
            graphLabels.layout(leftText: title(), centerText: nil,
                rightText: miner.countersAvailable ? XRGCommon.formattedString(forBytes: Double(miner.currentRX() + miner.currentTX())) + "/s" : "—",
                in: rect, mini: true, settings: settings)
            topRates.layout(leftText: nil, centerText: nil, rightText: nil, in: .zero, mini: false, settings: settings)
            bottomRates.layout(leftText: nil, centerText: nil, rightText: nil, in: .zero, mini: false, settings: settings)
            return
        }
        let complete = fullLeftReading()
        let lines = complete.components(separatedBy: "\n")
        let available = max(1, ceil(max(0, bounds.height) / height) - 1)
        let count = available >= CGFloat(lines.count) ? lines.count : Int(available)
        graphLabels.layout(leftText: lines.prefix(count).joined(separator: "\n"), centerText: nil,
                           rightText: nil, in: rect, mini: false, settings: settings)
        graphLabels.leftLabel.fullAccessibilityText = complete
        let rx = (miner.countersAvailable ? XRGCommon.formattedString(forBytes: Double(miner.currentRX())) : "—") + " Rx"
        let tx = (miner.countersAvailable ? XRGCommon.formattedString(forBytes: Double(miner.currentTX())) : "—") + " Tx"
        let bottomRect = NSRect(x: rect.minX, y: bounds.minY, width: rect.width, height: min(bounds.height, height * (graphMode == 0 ? 2 : 1)))
        bottomRates.layout(leftText: nil, centerText: nil, rightText: graphMode == 0 ? rx + "\n" + tx : graphMode == 1 ? rx : tx,
                           in: bottomRect, mini: false, settings: settings)
        let topRect = NSRect(x: rect.minX, y: max(bounds.minY, bounds.maxY - height), width: rect.width, height: min(height, bounds.height))
        topRates.layout(leftText: nil, centerText: nil, rightText: graphMode == 0 ? nil : graphMode == 1 ? tx : rx,
                        in: topRect, mini: false, settings: settings)
    }
    public override func draw(_ dirtyRect: NSRect) {
        guard !isHidden, let settings, let context = NSGraphicsContext.current, XRGGraphRenderer.validRect(bounds) else { return }
        NSGraphicsContext.saveGraphicsState()
        defer { NSGraphicsContext.restoreGraphicsState() }
        updateLabels()
        settings.graphColor(.network, component: 0).set(); context.cgContext.fill(bounds)
        if shouldDrawMiniGraph() {
            guard miner.countersAvailable && fastMiner.countersAvailable else { return }
            XRGGraphRenderer.drawGraphBars(miniValues(), upperBound: Double(graphScale(fast: true)), lowerBound: 0, in: bounds, settings: settings, module: .network)
            return
        }
        context.shouldAntialias = settings.antiAliasing
        for (plot, color) in zip(plots(), [settings.graphColor(.network, component: 2), settings.graphColor(.network, component: 1)]) {
            XRGGraphRenderer.drawCurve(plot.data, upperBound: graphScale(), lowerBound: 0,
                in: bounds, flipped: plot.flipped, filled: true, color: color, style: settings.curveStyle(.network))
        }
        XRGGraphRenderer.drawGraphEffect(in: bounds, settings: settings, module: .network)
    }
    public func convertHeight(_ value: Int) -> Int {
        let height = max(0, bounds.height - XRGGraphLabels.lineHeight(settings) * 2)
        let result = Double(max(0, value)) / 100 * Double(height)
        guard result.isFinite, result < Double(Int.max) else { return result > 0 ? Int.max : 0 }
        return Int(max(0, result))
    }

    @nonobjc func makeMenu() -> NSMenu {
        let menu = NSMenu(title: "Network View")
        func item(_ title: String, _ action: Selector) -> NSMenuItem {
            let item = NSMenuItem(title: title, action: action, keyEquivalent: "")
            item.target = self
            return item
        }
        menu.addItem(item("Kernel Interface Counters (last snapshot)", #selector(emptyEvent(_:))))
        for interface in miner.interfaceStats {
            let title = String(format: "%@: RX(%1.1fM) TX(%1.1fM)", interface.name,
                               Double(interface.receivedBytes) / 1_048_576, Double(interface.sentBytes) / 1_048_576)
            menu.addItem(item(title, #selector(emptyEvent(_:))))
        }
        menu.addItem(.separator())
        menu.addItem(item("Transfer Details…", #selector(showTransferDetails(_:))))
        menu.addItem(XRGHistoryRetention.menu("Network History", count: retainedSamples, target: self, action: #selector(selectHistory(_:)), rootAction: #selector(emptyEvent(_:))))
        menu.addItem(item("Reset Graph", #selector(clearData(_:))))
        menu.addItem(item("Reset Session Transfers", #selector(resetTransfers(_:))))
        menu.addItem(.separator())
        menu.addItem(item("Open Network Settings...", #selector(openNetworkSystemPreferences(_:))))
        if utilityURL() != nil { menu.addItem(item("Open Network Utility...", #selector(openNetworkUtility(_:)))) }
        menu.addItem(item("Open XRG-ng Network Preferences...", #selector(openNetworkPreferences(_:))))
        return menu
    }
    public override func menu(for event: NSEvent) -> NSMenu? { makeMenu() }
    @nonobjc static let historyKey = "XRGNetView.HistorySamples.v1"
    @nonobjc var retainedSamples: Int { XRGHistoryRetention.saved(defaults, key: Self.historyKey) }
    @objc func selectHistory(_ sender: Any?) {
        guard XRGHistoryRetention.store(sender, defaults: defaults, key: Self.historyKey) else { return }
        setGraphSize(bounds.size); needsDisplay = true
    }
    public func emptyEvent(_ sender: Any?) {}
    public func openNetworkSystemPreferences(_ sender: Any?) { _ = openURL(Self.networkSettingsURL) }
    public func openNetworkUtility(_ sender: Any?) { if let url = utilityURL() { _ = openURL(url) } }
    public func openNetworkPreferences(_ sender: Any?) { host?.showNetworkPreferences() }
    public func clearData(_ sender: Any?) {
        miner.reset(); fastMiner.reset()
        updateLabels(); needsDisplay = true
    }
    public func resetTransfers(_ sender: Any?) {
        miner.resetTransfers()
        updateLabels(); needsDisplay = true
    }
    public func showTransferDetails(_ sender: Any?) {
        guard let window else { return }
        let alert = NSAlert()
        alert.messageText = "Network Transfer Details"
        alert.informativeText = miner.transferDetails
        alert.addButton(withTitle: "Close")
        alert.beginSheetModal(for: window)
    }
    public override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
    public override func mouseDown(with event: NSEvent) { window?.mouseDown(with: event) }
    public override func mouseDragged(with event: NSEvent) { window?.mouseDragged(with: event) }
    public override func mouseUp(with event: NSEvent) { window?.mouseUp(with: event) }
}
