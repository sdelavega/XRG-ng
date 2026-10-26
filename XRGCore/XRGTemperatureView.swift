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

@MainActor @objc public protocol XRGTemperatureViewHost: NSObjectProtocol {
    var appSettings: XRGSettings? { get }
    var moduleManager: XRGModuleManager? { get }
    var temperatureView: XRGTemperatureView? { get set }
    func initTimers()
    func showTemperaturePreferences()
    func showTemperatureSensors()
}

@MainActor
@objc(XRGTemperatureView) @objcMembers
public final class XRGTemperatureView: NSView, XRGModuleView {
    private let miner: XRGTemperatureMiner
    private let statsManager: XRGStatsManager
    private let defaults: UserDefaults
    private let standaloneSettings: XRGSettings?
    private weak var host: (any XRGTemperatureViewHost)?
    private weak var registeredManager: XRGModuleManager?
    private var didAwake = false
    private var historyWidth: Int?
    public private(set) weak var module: XRGModule?
    @nonobjc let graphLabels = XRGGraphLabels()
    private var settings: XRGSettings? { host?.appSettings ?? standaloneSettings }

    @nonobjc static func includesUnknownSensors(defaults: UserDefaults, knownCount: Int) -> Bool {
        defaults.bool(forKey: "tempShowUnknownSensors") || knownCount < 10
    }
    public static func showUnknownSensors() -> Bool {
        includesUnknownSensors(defaults: .standard, knownCount: XRGTemperatureMiner.shared.knownTemperatureKeyCount)
    }
    @nonobjc var includesUnknown: Bool {
        Self.includesUnknownSensors(defaults: defaults, knownCount: miner.knownTemperatureKeyCount)
    }
    public override init(frame frameRect: NSRect) {
        miner = .shared; statsManager = .shared; defaults = .standard; standaloneSettings = nil
        super.init(frame: frameRect)
        prepare()
    }
    public required init?(coder: NSCoder) {
        miner = .shared; statsManager = .shared; defaults = .standard; standaloneSettings = nil
        super.init(coder: coder)
        prepare()
    }
    @nonobjc init(frame: NSRect, miner: XRGTemperatureMiner, statsManager: XRGStatsManager = XRGStatsManager(),
                  settings: XRGSettings?, defaults: UserDefaults) {
        self.miner = miner; self.statsManager = statsManager; self.defaults = defaults; standaloneSettings = settings
        super.init(frame: frame)
        prepare()
    }
    private func prepare() {
        for label in [graphLabels.leftLabel, graphLabels.centerLabel, graphLabels.rightLabel] { addSubview(label) }
        setGraphSize(bounds.size); updateLabels()
    }
    public nonisolated override func awakeFromNib() {
        super.awakeFromNib()
        MainActor.assumeIsolated { didAwake = true; bindToWindow() }
    }
    public override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow(); bindToWindow()
    }
    private func bindToWindow() {
        let next = window as? any XRGTemperatureViewHost
        if host !== next || registeredManager !== next?.moduleManager {
            if host?.temperatureView === self { host?.temperatureView = nil }
            if let module { registeredManager?.removeModule(module) }
            registeredManager = nil; module = nil; host = next
        }
        guard didAwake, let host, let manager = host.moduleManager, settings != nil,
              registeredManager !== manager else { updateLabels(); return }
        let module = XRGModule(name: "Temperature", reference: self, defaults: defaults)
        module.displayOrder = 4
        module.doesGraphUpdate = true; module.doesFastUpdate = false
        module.doesMin5Update = false; module.doesMin30Update = false; module.alwaysDoesGraphUpdate = false
        module.isDisplayed = defaults.bool(forKey: "showTemperatureGraph")
        self.module = module; registeredManager = manager
        host.temperatureView = self; host.initTimers()
        updateMinSize(); manager.addModule(module); setGraphSize(module.currentSize)
    }
    public func setGraphSize(_ size: NSSize) {
        let width = size.width.isFinite ? size.width : 1
        setWidth(Int(min(20_000, max(1, width))))
    }
    public func setWidth(_ width: Int) {
        guard width >= 0 else { return }
        let width = min(20_000, width)
        guard width != historyWidth else { return }
        miner.setDataSize(width); historyWidth = width
    }
    public override func setFrameSize(_ newSize: NSSize) {
        super.setFrameSize(newSize); setGraphSize(newSize); updateLabels()
    }
    private func textWidth(_ text: String) -> CGFloat {
        (text as NSString).size(withAttributes: [.font: settings?.graphFont ?? NSFont.systemFont(ofSize: 10)]).width
    }
    public func updateMinSize() {
        module?.minWidth = textWidth("CPU 199°F")
        module?.minHeight = XRGGraphLabels.lineHeight(settings)
        updateLabels()
    }
    public func graphUpdate(_ timer: Timer?) {
        miner.updateCurrentTemperatures(includesUnknown)
        checkForConfiguredSensors(); updateLabels(); needsDisplay = true
    }
    public func fastUpdate(_ timer: Timer?) {}
    public func min5Update(_ timer: Timer?) {}
    public func min30Update(_ timer: Timer?) {}
    public func shouldDrawMiniGraph() -> Bool { XRGGraphLabels.shouldDrawMiniGraph(in: bounds, settings: settings) }

    public func checkForConfiguredSensors() {
        let keys = miner.locationKeys(includingUnknown: includesUnknown)
        let preferred = ["Fan", "CPU", "GPU", "SSD"].compactMap { prefix in
            keys.first { key in
                guard let sensor = miner.sensor(forLocation: key), sensor.isEnabled else { return false }
                return sensor.label().hasPrefix(prefix)
            }
        }
        _ = settings?.configureTemperatureSensors(preferred)
    }
    @nonobjc func valueText(_ sensor: XRGSensorData) -> String {
        guard sensor.isEnabled, sensor.currentValue.isFinite else { return "n/a" }
        let fahrenheit = settings?.tempUnits == .f && sensor.units == "°C"
        let value = fahrenheit ? sensor.currentValue * 1.8 + 32 : sensor.currentValue
        guard value.isFinite else { return "n/a" }
        let units = fahrenheit ? "°F" : sensor.units ?? ""
        return String(format: units == " rpm" || units == "%" ? "%.0f%@" : "%.1f%@", value, units)
    }
    struct Row {
        let slot: Int
        let sensor: XRGSensorData
        let value: String
        let lower: CGFloat
        let upper: CGFloat
        var hasRange: Bool { lower.isFinite && upper.isFinite && upper > lower }
    }
    @nonobjc func rows() -> [Row] {
        let keys = [settings?.tempFG1Location, settings?.tempFG2Location, settings?.tempFG3Location]
        let selected = keys.enumerated().compactMap { index, key -> (Int, XRGSensorData)? in
            guard let key, let sensor = miner.sensor(forLocation: key) else { return nil }
            return (index, sensor)
        }
        let fans = miner.fanValues()
        let fanKeys = Set(fans.map(\.key))
        let thermal = selected.map(\.1).filter { !fanKeys.contains($0.key) && $0.units != " rpm" && $0.units != "%" && $0.dataSet.numValues > 0 }
        let minima = thermal.map { $0.dataSet.min }.filter(\.isFinite)
        let maxima = thermal.map { $0.dataSet.max }.filter(\.isFinite)
        let low = minima.min() ?? 0, high = maxima.max() ?? 100
        let padding = max(20, high - low) * 0.1
        return selected.map { slot, sensor in
            let lower: CGFloat, upper: CGFloat
            if fanKeys.contains(sensor.key) || sensor.units == " rpm" {
                lower = 0; upper = CGFloat(fans.first { $0.key == sensor.key }?.maximumSpeed ?? 0)
            } else if sensor.units == "%" { lower = 0; upper = 100 }
            else { lower = low - padding; upper = high + padding }
            return Row(slot: slot, sensor: sensor, value: valueText(sensor), lower: lower, upper: upper)
        }
    }
    @nonobjc func emptyMessage() -> String? {
        if miner.locationKeys(includingUnknown: includesUnknown).isEmpty {
            if shouldDrawMiniGraph() { return "Temperature n/a" }
            return textWidth("No Sensors Found") < XRGGraphLabels.paddedTextRect(for: bounds).width ? "No Sensors Found" : "No Sensors\nFound"
        }
        if shouldDrawMiniGraph() && rows().first?.slot != 0 { return "Temperature n/a" }
        if rows().isEmpty {
            return textWidth("Select Sensors in Prefs") < XRGGraphLabels.paddedTextRect(for: bounds).width ? "Select Sensors in Prefs" : "Select Sensors\nin Prefs"
        }
        return nil
    }
    private func updateLabels() {
        let rect = XRGGraphLabels.paddedTextRect(for: bounds)
        if let message = emptyMessage() {
            graphLabels.layout(leftText: message, centerText: nil, rightText: nil, in: rect,
                               mini: shouldDrawMiniGraph(), settings: settings)
            return
        }
        let rows = rows()
        if shouldDrawMiniGraph(), let primary = rows.first {
            graphLabels.layoutColumnText(primary.sensor.label(), rightText: primary.value, in: rect, mini: true, settings: settings)
        } else {
            graphLabels.layoutColumnText(rows.map { $0.sensor.label() }.joined(separator: "\n"),
                rightText: rows.map(\.value).joined(separator: "\n"), in: rect, mini: false, settings: settings)
        }
    }
    @nonobjc func miniValues() -> [NSNumber] {
        guard let primary = rows().first, primary.slot == 0 else { return [] }
        let fans = miner.fanValues()
        var result: [NSNumber] = []
        var seen: Set<String> = [primary.sensor.key]
        if primary.sensor.isEnabled && primary.sensor.currentValue.isFinite {
            var lower = primary.lower, upper = primary.upper
            if !fans.contains(where: { $0.key == primary.sensor.key }) && primary.sensor.units != " rpm" && primary.sensor.units != "%" {
                lower = min(primary.sensor.dataSet.min, 20); upper = max(primary.sensor.dataSet.max, 90)
            }
            if lower.isFinite && upper.isFinite && upper > lower {
                let fraction = (CGFloat(primary.sensor.currentValue) - lower) / (upper - lower)
                if fraction.isFinite { result.append(NSNumber(value: Double(min(1, max(0, fraction)) * 100))) }
            }
        }
        for fan in fans where seen.insert(fan.key).inserted && fan.maximumSpeed > 0 {
            guard let sensor = miner.sensor(forLocation: fan.key), sensor.isEnabled else { continue }
            result.append(NSNumber(value: min(1, max(0, Double(fan.actualSpeed) / Double(fan.maximumSpeed))) * 100))
        }
        return result
    }
    @nonobjc func headerBarRects(in rect: NSRect) -> [NSRect] {
        guard XRGGraphRenderer.validRect(rect) else { return [] }
        let height = XRGGraphLabels.lineHeight(settings)
        return rows().enumerated().map { index, row in
            guard row.sensor.isEnabled, row.sensor.currentValue.isFinite, row.hasRange else { return .zero }
            let fraction = (CGFloat(row.sensor.currentValue) - row.lower) / (row.upper - row.lower)
            guard fraction.isFinite else { return .zero }
            let bar = NSRect(x: rect.minX, y: rect.maxY - CGFloat(index + 1) * height,
                width: min(rect.width, max(1, rect.width * min(1, max(0, fraction)))), height: index == 0 ? height : max(0, floor(height - 1)))
            let clipped = rect.intersection(bar)
            return clipped.isNull || clipped.isEmpty ? .zero : clipped
        }
    }
    @nonobjc func historyRect(in rect: NSRect) -> NSRect {
        guard XRGGraphRenderer.validRect(rect) else { return .zero }
        let used = min(rect.height, CGFloat(rows().count) * XRGGraphLabels.lineHeight(settings))
        return NSRect(x: rect.minX, y: rect.minY, width: rect.width, height: max(0, rect.height - used - 2))
    }
    public override func draw(_ dirtyRect: NSRect) {
        guard !isHidden, let settings, let context = NSGraphicsContext.current, XRGGraphRenderer.validRect(bounds) else { return }
        NSGraphicsContext.saveGraphicsState()
        defer { NSGraphicsContext.restoreGraphicsState() }
        updateLabels()
        settings.graphBGColor.set(); context.cgContext.fill(bounds)
        if emptyMessage() == nil {
            if shouldDrawMiniGraph() {
                XRGGraphRenderer.drawMiniValues(miniValues(), upperBound: 100, lowerBound: 0, in: bounds, settings: settings)
            } else {
                settings.graphFG1Color.set()
                for bar in headerBarRects(in: bounds) { context.cgContext.fill(bar) }
                let height = XRGGraphLabels.lineHeight(settings)
                settings.borderColor.set()
                for index in 0...rows().count {
                    let y = bounds.maxY - CGFloat(index) * height - 1
                    let border = bounds.intersection(NSRect(x: bounds.minX, y: y, width: bounds.width, height: 2))
                    if !border.isNull && !border.isEmpty { border.fill(using: .copy) }
                }
                context.shouldAntialias = settings.antiAliasing
                for row in rows() where row.hasRange {
                    let color = [settings.graphFG1Color, settings.graphFG2Color, settings.graphFG3Color][row.slot]
                    XRGGraphRenderer.drawDataSet(row.sensor.dataSet, upperBound: row.upper, lowerBound: row.lower,
                        in: historyRect(in: bounds), flipped: false, filled: row.slot == 0, color: color)
                }
            }
        }
        XRGGraphRenderer.drawStyle(in: bounds, settings: settings)
    }
    @nonobjc func makeMenu() -> NSMenu {
        let menu = NSMenu(title: "Temperature View")
        func item(_ title: String, _ action: Selector) -> NSMenuItem {
            let item = NSMenuItem(title: title, action: action, keyEquivalent: "")
            item.target = self; return item
        }
        for key in miner.locationKeys(includingUnknown: includesUnknown) {
            if let sensor = miner.sensor(forLocation: key) {
                menu.addItem(item(sensor.label() + ": " + valueText(sensor), #selector(emptyEvent(_:))))
            }
        }
        menu.addItem(.separator()); menu.addItem(item("Reset Graph", #selector(clearData(_:))))
        menu.addItem(.separator()); menu.addItem(item("Open XRG-ng Temperature Preferences...", #selector(openTemperaturePreferences(_:))))
        menu.addItem(item("Open Temperature Sensors Window...", #selector(showSensorWindow(_:))))
        return menu
    }
    public override func menu(for event: NSEvent) -> NSMenu? { makeMenu() }
    public func clearData(_ sender: Any?) {
        miner.reset(); statsManager.clearHistory(forModule: .nameTemperature); updateLabels(); needsDisplay = true
    }
    public func emptyEvent(_ sender: Any?) {}
    public func openTemperaturePreferences(_ sender: Any?) { host?.showTemperaturePreferences() }
    public func showSensorWindow(_ sender: Any?) { host?.showTemperatureSensors() }
    public override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
    public override func mouseDown(with event: NSEvent) { window?.mouseDown(with: event) }
    public override func mouseDragged(with event: NSEvent) { window?.mouseDragged(with: event) }
    public override func mouseUp(with event: NSEvent) { window?.mouseUp(with: event) }
}
