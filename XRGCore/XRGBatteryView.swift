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

@MainActor @objc public protocol XRGBatteryViewHost: NSObjectProtocol {
    var appSettings: XRGSettings? { get }
    var moduleManager: XRGModuleManager? { get }
    var batteryView: XRGBatteryView? { get set }
    func initTimers()
}

@MainActor
@objc(XRGBatteryView) @objcMembers
public final class XRGBatteryView: NSView, XRGModuleView {
    public let batteryMiner: XRGBatteryMiner
    private let defaults: UserDefaults
    private let standaloneSettings: XRGSettings?
    private let openURL: (URL) -> Bool
    private weak var host: (any XRGBatteryViewHost)?
    private weak var registeredManager: XRGModuleManager?
    private var didAwake = false
    private var statsElapsed: CGFloat = 0
    public private(set) weak var module: XRGModule?
    @nonobjc let graphLabels = XRGGraphLabels()
    @nonobjc private(set) var chargingPhase = 0
    @nonobjc static let batterySettingsURL = URL(fileURLWithPath: "/System/Library/PreferencePanes/Battery.prefPane")
    private var settings: XRGSettings? { host?.appSettings ?? standaloneSettings }

    public override init(frame frameRect: NSRect) {
        batteryMiner = XRGBatteryMiner()
        defaults = .standard; standaloneSettings = nil
        openURL = { NSWorkspace.shared.open($0) }
        super.init(frame: frameRect)
        prepare()
    }
    public required init?(coder: NSCoder) {
        batteryMiner = XRGBatteryMiner()
        defaults = .standard; standaloneSettings = nil
        openURL = { NSWorkspace.shared.open($0) }
        super.init(coder: coder)
        prepare()
    }
    @nonobjc init(frame: NSRect, miner: XRGBatteryMiner, settings: XRGSettings?, defaults: UserDefaults,
                  openURL: @escaping (URL) -> Bool = { _ in true }) {
        batteryMiner = miner; self.defaults = defaults
        standaloneSettings = settings; self.openURL = openURL
        super.init(frame: frame)
        prepare()
    }
    private func prepare() {
        for label in [graphLabels.leftLabel, graphLabels.centerLabel, graphLabels.rightLabel] { addSubview(label) }
        setGraphSize(bounds.size)
        batteryMiner.graphUpdate(nil)
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
        let next = window as? any XRGBatteryViewHost
        if host !== next || registeredManager !== next?.moduleManager {
            if host?.batteryView === self { host?.batteryView = nil }
            if let module { registeredManager?.removeModule(module) }
            registeredManager = nil; module = nil; host = next
        }
        guard didAwake, let host, let manager = host.moduleManager, settings != nil,
              registeredManager !== manager else { updateLabels(); return }
        let module = XRGModule(name: "Battery", reference: self, defaults: defaults)
        module.displayOrder = 4
        module.doesGraphUpdate = true; module.doesFastUpdate = false
        module.doesMin5Update = false; module.doesMin30Update = false
        module.isDisplayed = defaults.bool(forKey: "showBatteryGraph")
        self.module = module; registeredManager = manager
        host.batteryView = self
        host.initTimers()
        updateMinSize()
        manager.addModule(module)
        setGraphSize(module.currentSize)
    }
    public func setGraphSize(_ size: NSSize) {
        let width = size.width.isFinite ? size.width : 1
        setWidth(Int(min(20_000, max(1, width))))
    }
    public func setWidth(_ width: Int) {
        guard width >= 0 else { return }
        let count = retainedSamples > 0 ? retainedSamples : min(20_000, width)
        if batteryMiner.numSamples != count {
            if retainedSamples > 0 { batteryMiner.resizeHistory(count) } else { batteryMiner.setDataSize(count) }
        }
    }
    public override func setFrameSize(_ newSize: NSSize) {
        super.setFrameSize(newSize)
        setGraphSize(newSize)
        updateLabels()
    }
    private func textWidth(_ text: String) -> CGFloat {
        (text as NSString).size(withAttributes: [.font: settings?.graphFont ?? NSFont.systemFont(ofSize: 10)]).width
    }
    public func updateMinSize() {
        module?.minWidth = textWidth("100% Chgd.") + 6
        module?.minHeight = XRGGraphLabels.lineHeight(settings)
        updateLabels()
    }
    public func graphUpdate(_ timer: Timer?) {
        chargingPhase = (chargingPhase + 1) % 4
        let refresh = settings?.graphRefresh ?? 1
        // Keep the existing ten-second sampling cadence independently of animation ticks.
        if refresh.isFinite && refresh > 0 { statsElapsed += refresh }
        if statsElapsed > 10 {
            statsElapsed = 0
            let previous = batteryMiner.batteryStatus()
            batteryMiner.graphUpdate(timer)
            if previous != batteryMiner.batteryStatus() { chargingPhase = 0 }
        }
        updateLabels(); needsDisplay = true
    }
    public func fastUpdate(_ timer: Timer?) {}
    public func min5Update(_ timer: Timer?) {}
    public func min30Update(_ timer: Timer?) {}
    public func shouldDrawMiniGraph() -> Bool { XRGGraphLabels.shouldDrawMiniGraph(in: bounds, settings: settings) }

    @nonobjc var currentWatts: CGFloat {
        let value = batteryMiner.chargeWatts.currentValue - batteryMiner.dischargeWatts.currentValue
        return value.isFinite ? value : 0
    }
    @nonobjc var wattScale: CGFloat {
        let maximum = max(batteryMiner.chargeWatts.max, batteryMiner.dischargeWatts.max)
        return maximum.isFinite ? max(30, maximum) : 30
    }
    @nonobjc private let timeProjection = XRGTimeWindowProjection(channels: 2)
    @nonobjc func historyData() -> [XRGDataSet] {
        timeProjection.values(from: batteryMiner.timedHistory, minutes: historyMinutes, interval: Double(settings?.graphRefresh ?? 1)) ?? [batteryMiner.chargeWatts, batteryMiner.dischargeWatts]
    }
    @nonobjc var historyWattScale: CGFloat {
        let maximum = historyData().map(\.max).max() ?? 0
        return maximum.isFinite ? max(30, maximum) : 30
    }
    struct Readings { let left: String; let center: String?; let right: String }
    @nonobjc func readings() -> Readings {
        let status = batteryMiner.batteryStatus()
        guard status != .unknown && status != .noBattery else {
            return Readings(left: "No Battery Found", center: nil, right: "")
        }
        let width = XRGGraphLabels.paddedTextRect(for: bounds).width
        var left = "\(batteryMiner.chargePercent())%"
        var right: String
        if status == .charged || status == .onHold {
            let wide = textWidth("100% Charged") <= width
            right = status == .charged ? (wide ? "Charged" : "Chgd.") : (wide ? "On Hold" : "Hold")
        } else if batteryMiner.minutesRemaining() > 0 {
            let minutes = batteryMiner.minutesRemaining()
            let time = String(format: "%ld:%02ld", minutes / 60, minutes % 60)
            if textWidth("100% Charged 9:99 Left") <= width { left += " Charged"; right = time + " Left" }
            else { right = time }
        } else {
            right = textWidth("100% Estimating Left") <= width ? "Estimating Left"
                : textWidth("100% Estimating") <= width ? "Estimating" : "Est."
        }
        left += batteryMiner.hasRawCapacity ? "\n\(batteryMiner.totalCharge())mAh" : "\nn/a"
        right += batteryMiner.hasRawCapacity ? "\n\(batteryMiner.totalCapacity())mAh" : "\nn/a"
        var center: String?
        if !shouldDrawMiniGraph() {
            let watts = String(format: "%.1fW", currentWatts)
            if textWidth("Power: 99.9V") <= width { left += "\nPower:"; right += "\n" + watts }
            else { left += "\n "; right += "\n "; center = "\n\n" + watts }
        }
        return Readings(left: left, center: center, right: right)
    }
    private func updateLabels() {
        let reading = readings()
        let rect = XRGGraphLabels.paddedTextRect(for: bounds)
        if batteryMiner.batteryStatus() == .unknown || batteryMiner.batteryStatus() == .noBattery {
            graphLabels.layout(leftText: reading.left, centerText: nil, rightText: nil,
                               in: rect, mini: shouldDrawMiniGraph(), settings: settings)
            // Preserve the wrapped empty-state message, with its complete accessible source.
            graphLabels.leftLabel.lineBreakMode = .byWordWrapping
            graphLabels.leftLabel.cell?.wraps = true
            let text = NSMutableAttributedString(attributedString: graphLabels.leftLabel.attributedStringValue)
            let style = NSMutableParagraphStyle(); style.lineBreakMode = .byWordWrapping
            text.addAttribute(.paragraphStyle, value: style, range: NSRange(location: 0, length: text.length))
            graphLabels.leftLabel.attributedStringValue = text
        } else {
            graphLabels.layoutColumnText(reading.left, centerText: reading.center, rightText: reading.right,
                                        in: rect, mini: shouldDrawMiniGraph(), settings: settings)
        }
    }
    struct Bars {
        let charge: NSRect
        let charging: NSRect
        let power: NSRect
        let history: NSRect
        let borders: [NSRect]
    }
    @nonobjc func bars(in rect: NSRect, mini: Bool) -> Bars {
        guard XRGGraphRenderer.validRect(rect) else { return Bars(charge: .zero, charging: .zero, power: .zero, history: .zero, borders: []) }
        let height = XRGGraphLabels.lineHeight(settings)
        func clipped(_ value: NSRect) -> NSRect {
            let result = rect.intersection(value)
            return result.isNull || result.isEmpty ? .zero : result
        }
        let header = NSRect(x: rect.minX, y: mini ? rect.minY : rect.maxY - height * 2,
                            width: rect.width, height: mini ? rect.height : height * 2)
        let width = rect.width * CGFloat(min(100, max(0, batteryMiner.chargePercent()))) / 100
        let charge = clipped(NSRect(x: header.minX, y: header.minY, width: width, height: header.height))
        let charging = batteryMiner.batteryStatus() == .charging
            ? clipped(NSRect(x: rect.minX + width, y: header.minY, width: (rect.width - width) * CGFloat(chargingPhase) / 3, height: header.height)) : .zero
        if mini { return Bars(charge: charge, charging: charging, power: .zero, history: .zero, borders: []) }
        let powerY = rect.maxY - height * 3
        let powerWidth = rect.width / 2 * min(1, abs(currentWatts) / wattScale)
        let power = clipped(NSRect(x: rect.midX - (currentWatts < 0 ? powerWidth : 0), y: powerY, width: powerWidth, height: height))
        let topOfGraph = powerY - 1
        let borders = [NSRect(x: rect.minX, y: topOfGraph, width: rect.width, height: 2),
                       NSRect(x: rect.minX, y: topOfGraph + height, width: rect.width, height: 2),
                       NSRect(x: rect.midX - 1, y: topOfGraph, width: 2, height: height + 2)].map(clipped)
        return Bars(charge: charge, charging: charging, power: power,
                    history: NSRect(x: rect.minX, y: rect.minY, width: rect.width, height: max(0, topOfGraph - rect.minY)), borders: borders)
    }
    public override func draw(_ dirtyRect: NSRect) {
        guard !isHidden, let settings, let context = NSGraphicsContext.current, XRGGraphRenderer.validRect(bounds) else { return }
        NSGraphicsContext.saveGraphicsState()
        defer { NSGraphicsContext.restoreGraphicsState() }
        updateLabels()
        settings.graphColor(.battery, component: 0).set(); context.cgContext.fill(bounds)
        let status = batteryMiner.batteryStatus()
        guard status != .unknown && status != .noBattery else { return }
        context.shouldAntialias = settings.antiAliasing
        let bars = bars(in: bounds, mini: shouldDrawMiniGraph())
        settings.graphColor(.battery, component: 1).set(); bars.charge.fill(using: .copy)
        settings.graphColor(.battery, component: 2).set(); bars.charging.fill(using: .copy); bars.power.fill(using: .copy)
        settings.borderColor.set()
        for border in bars.borders { border.fill(using: .copy) }
        if bars.history.height > 0 {
            let data = historyData(), scale = historyWattScale
            XRGGraphRenderer.drawCurve(data[0], upperBound: scale, lowerBound: 0,
                in: bars.history, flipped: false, filled: true, color: settings.graphColor(.battery, component: 1), style: settings.curveStyle(.battery))
            XRGGraphRenderer.drawCurve(data[1], upperBound: scale, lowerBound: 0,
                in: bars.history, flipped: true, filled: true, color: settings.graphColor(.battery, component: 2), style: settings.curveStyle(.battery))
        }
        XRGGraphRenderer.drawGraphEffect(in: bounds, settings: settings, module: .battery)
    }
    @nonobjc func makeMenu() -> NSMenu {
        let menu = NSMenu(title: "Battery View")
        let item = NSMenuItem(title: "Open Battery Settings...", action: #selector(openEnergySaverSystemPreferences(_:)), keyEquivalent: "")
        item.target = self; menu.addItem(item)
        menu.addItem(XRGHistoryRetention.menu("Battery History", count: retainedSamples, target: self, action: #selector(selectHistory(_:)), rootAction: #selector(emptyEvent(_:))))
        menu.addItem(XRGSystemTimeWindow.menu("Battery Time Window", minutes: historyMinutes, target: self, action: #selector(selectHistoryWindow(_:)), rootAction: #selector(emptyEvent(_:))))
        return menu
    }
    public override func menu(for event: NSEvent) -> NSMenu? { makeMenu() }
    @nonobjc static let windowKey = "XRGBatteryView.HistoryMinutes.v1"
    @nonobjc var historyMinutes: Int { XRGSystemTimeWindow.saved(defaults, key: Self.windowKey) }
    @objc func selectHistoryWindow(_ sender: Any?) {
        guard XRGSystemTimeWindow.store(sender, defaults: defaults, key: Self.windowKey) else { return }
        updateLabels(); needsDisplay = true
    }
    @nonobjc static let historyKey = "XRGBatteryView.HistorySamples.v1"
    @nonobjc var retainedSamples: Int { XRGHistoryRetention.saved(defaults, key: Self.historyKey) }
    @objc func selectHistory(_ sender: Any?) {
        guard XRGHistoryRetention.store(sender, defaults: defaults, key: Self.historyKey) else { return }
        defaults.set(0, forKey: Self.windowKey)
        setGraphSize(bounds.size); updateLabels(); needsDisplay = true
    }
    public func emptyEvent(_ sender: Any?) {}
    public func openEnergySaverSystemPreferences(_ sender: Any?) { _ = openURL(Self.batterySettingsURL) }
    public override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
    public override func mouseDown(with event: NSEvent) { window?.mouseDown(with: event) }
    public override func mouseDragged(with event: NSEvent) { window?.mouseDragged(with: event) }
    public override func mouseUp(with event: NSEvent) { window?.mouseUp(with: event) }
}
