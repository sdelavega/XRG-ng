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

@MainActor @objc public protocol XRGMemoryViewHost: NSObjectProtocol {
    var appSettings: XRGSettings? { get }
    var moduleManager: XRGModuleManager? { get }
    var memoryView: XRGMemoryView? { get set }
    func initTimers()
    func showMemoryPreferences()
}

@MainActor
@objc(XRGMemoryView) @objcMembers
public final class XRGMemoryView: NSView, XRGModuleView {
    private let memoryMiner: XRGMemoryMiner
    private let processMiner: XRGProcessMiner
    private let defaults: UserDefaults
    private let standaloneSettings: XRGSettings?
    private weak var host: (any XRGMemoryViewHost)?
    private weak var registeredManager: XRGModuleManager?
    private var didAwake = false
    public private(set) weak var module: XRGModule?
    @nonobjc let graphLabels = XRGGraphLabels()
    private var settings: XRGSettings? { host?.appSettings ?? standaloneSettings }

    public override init(frame frameRect: NSRect) {
        memoryMiner = XRGMemoryMiner()
        processMiner = XRGProcessMiner()
        defaults = .standard
        standaloneSettings = nil
        super.init(frame: frameRect)
        prepare()
    }
    public required init?(coder: NSCoder) {
        memoryMiner = XRGMemoryMiner()
        processMiner = XRGProcessMiner()
        defaults = .standard
        standaloneSettings = nil
        super.init(coder: coder)
        prepare()
    }
    @nonobjc init(frame: NSRect, memoryMiner: XRGMemoryMiner, processMiner: XRGProcessMiner,
                  settings: XRGSettings?, defaults: UserDefaults) {
        self.memoryMiner = memoryMiner
        self.processMiner = processMiner
        self.defaults = defaults
        standaloneSettings = settings
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
        let next = window as? any XRGMemoryViewHost
        if host !== next {
            if host?.memoryView === self { host?.memoryView = nil }
            if let module { registeredManager?.removeModule(module) }
            registeredManager = nil
            module = nil
            host = next
        }
        guard didAwake, let host, let manager = host.moduleManager, settings != nil,
              registeredManager !== manager else { updateLabels(); return }
        let module = XRGModule(name: "Memory", reference: self, defaults: defaults)
        module.displayOrder = 3
        module.doesGraphUpdate = true
        module.doesFastUpdate = false
        module.doesMin5Update = false
        module.doesMin30Update = false
        module.isDisplayed = defaults.bool(forKey: "showMemoryGraph")
        self.module = module
        registeredManager = manager
        host.memoryView = self
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
        guard width >= 19 else { return }
        let count = min(20_000, Int(width)) - 19
        if memoryMiner.faultData().numValues != count { memoryMiner.setDataSize(count) }
    }
    public override func setFrameSize(_ newSize: NSSize) {
        super.setFrameSize(newSize)
        setGraphSize(newSize)
        updateLabels()
    }
    public func updateMinSize() {
        guard let settings else { return }
        let attributes: [NSAttributedString.Key: Any] = [.font: settings.graphFont ?? NSFont.systemFont(ofSize: 10)]
        module?.minWidth = ("W: 9999M" as NSString).size(withAttributes: attributes).width + 25
        module?.minHeight = XRGGraphLabels.lineHeight(settings)
        updateLabels()
    }
    public func graphUpdate(_ timer: Timer?) {
        memoryMiner.getLatestMemoryInfo()
        updateLabels()
        needsDisplay = true
    }
    public func fastUpdate(_ timer: Timer?) {}
    public func min5Update(_ timer: Timer?) {}
    public func min30Update(_ timer: Timer?) {}
    public func shouldDrawMiniGraph() -> Bool { XRGGraphLabels.shouldDrawMiniGraph(in: bounds, settings: settings) }

    struct StatusRects {
        let paging: NSRect
        let ram: [NSRect]
        let swap: NSRect
        let borders: [NSRect]
    }
    @nonobjc func statusRects(in rect: NSRect, mini: Bool) -> StatusRects {
        guard XRGGraphRenderer.validRect(rect) else {
            return StatusRects(paging: .zero, ram: [.zero, .zero, .zero], swap: .zero, borders: [])
        }
        let wired = Double(memoryMiner.wiredBytes()), active = Double(memoryMiner.activeBytes())
        let inactive = Double(memoryMiner.inactiveBytes()), free = Double(memoryMiner.freeBytes())
        // Convert before summing: each miner field can independently saturate UInt64.
        let total = wired + active + inactive + free
        let totalSwap = Double(memoryMiner.totalSwap), usedSwap = min(Double(memoryMiner.usedSwap), totalSwap)
        func fraction(_ value: Double, _ scale: Double) -> CGFloat {
            scale > 0 ? CGFloat(min(1, max(0, value / scale))) : 0
        }
        func clip(_ value: NSRect) -> NSRect {
            let result = value.intersection(rect)
            return result.isNull || result.isEmpty ? .zero : result
        }
        if mini {
            let scale = max(total, totalSwap)
            let split = min(rect.height, max(0, (rect.height * 0.4).rounded()))
            let topY = rect.minY + split, topHeight = max(0, rect.height - split)
            var x = rect.minX
            let ram = [wired, active, inactive].map { value in
                let width = fraction(value, scale) * rect.width
                defer { x += width }
                return clip(NSRect(x: x, y: topY, width: width, height: topHeight))
            }
            return StatusRects(paging: .zero, ram: ram,
                swap: clip(NSRect(x: rect.minX, y: rect.minY, width: rect.width * fraction(usedSwap, scale), height: max(0, split - 1))), borders: [])
        }
        let graphWidth = max(0, rect.width - 19), x = rect.minX + graphWidth
        var y = rect.minY
        let ram = [wired, active, inactive].map { value in
            let height = fraction(value, total) * rect.height
            defer { y += height }
            return clip(NSRect(x: x + 2, y: y, width: 8, height: height))
        }
        return StatusRects(paging: clip(NSRect(x: rect.minX, y: rect.minY, width: graphWidth, height: rect.height)),
            ram: ram, swap: clip(NSRect(x: x + 11, y: rect.minY, width: 8, height: rect.height * fraction(usedSwap, totalSwap))),
            borders: [clip(NSRect(x: x, y: rect.minY, width: 2, height: rect.height)),
                      clip(NSRect(x: x + 10, y: rect.minY, width: 1, height: rect.height))])
    }
    @nonobjc func pagingLayers() -> (maximum: CGFloat, values: [XRGDataSet]) {
        guard let all = XRGDataSet(contentsOfOtherDataSet: memoryMiner.faultData()) else { return (0, []) }
        all.addOtherDataSetValues(memoryMiner.pageInData())
        all.addOtherDataSetValues(memoryMiner.pageOutData())
        let maximum = all.max
        guard maximum.isFinite, maximum > 0,
              let withoutPageOut = XRGDataSet(contentsOfOtherDataSet: all) else { return (0, []) }
        withoutPageOut.subtractOtherDataSetValues(memoryMiner.pageOutData())
        return (maximum, [all, withoutPageOut, memoryMiner.faultData()])
    }
    @nonobjc func fullReading() -> String {
        guard let settings else { return "Memory" }
        var lines = ["Memory"]
        func bytes(_ value: UInt64) -> String { XRGCommon.formattedString(forBytes: Double(value)) }
        if settings.memoryShowFree { lines.append("F: " + bytes(memoryMiner.freeBytes())) }
        if settings.memoryShowInactive { lines.append("I: " + bytes(memoryMiner.inactiveBytes())) }
        if settings.memoryShowActive { lines.append("A: " + bytes(memoryMiner.activeBytes())) }
        if settings.memoryShowWired { lines.append("W: " + bytes(memoryMiner.wiredBytes())) }
        if settings.memoryShowCache {
            let lookups = Double(memoryMiner.totalCacheLookups())
            let percent = lookups > 0 ? min(100, Double(memoryMiner.totalCacheHits()) / lookups * 100) : 0
            lines.append(String(format: "Ca: %.0f%%", percent.rounded(.towardZero)))
        }
        if settings.memoryShowPage, settings.graphRefresh != 0 {
            let interval = Double(settings.graphRefresh)
            let rate = Double(memoryMiner.recentFaults()) * Double(memoryMiner.pageSize) / 1024 / interval
            if interval.isFinite, interval > 0, rate.isFinite {
                lines.append(rate > 1024 ? String(format: "PF: %4.2fM/s", rate / 1024) : String(format: "PF: %.0fK/s", rate))
            } else { lines.append("PF: n/a") }
        }
        lines.append("Vu: " + bytes(memoryMiner.usedSwap))
        lines.append("Vt: " + bytes(memoryMiner.totalSwap))
        return lines.joined(separator: "\n")
    }
    private func updateLabels() {
        let mini = shouldDrawMiniGraph()
        let rect = mini ? bounds : NSRect(x: bounds.minX, y: bounds.minY, width: max(0, bounds.width - 19), height: bounds.height)
        graphLabels.layout(leftText: mini ? "Mem" : fullReading(), centerText: nil,
            rightText: mini ? "\(memoryMiner.usedSwap / 1_048_576)M Vu" : nil,
            in: XRGGraphLabels.paddedTextRect(for: rect), mini: mini, settings: settings)
    }
    public override func draw(_ dirtyRect: NSRect) {
        guard !isHidden, let settings, let context = NSGraphicsContext.current,
              XRGGraphRenderer.validRect(bounds) else { return }
        NSGraphicsContext.saveGraphicsState()
        defer { NSGraphicsContext.restoreGraphicsState() }
        settings.graphBGColor.set()
        context.cgContext.fill(bounds)
        context.shouldAntialias = settings.antiAliasing
        let mini = shouldDrawMiniGraph(), rects = statusRects(in: bounds, mini: mini)
        if !mini, settings.showMemoryPagingGraph {
            let layers = pagingLayers()
            for (data, color) in zip(layers.values, [settings.graphFG3Color, settings.graphFG2Color, settings.graphFG1Color]) {
                XRGGraphRenderer.drawDataSet(data, upperBound: layers.maximum, lowerBound: 0,
                    in: rects.paging, flipped: false, filled: true, color: color)
            }
        }
        settings.borderColor.set()
        for rect in rects.borders { rect.fill(using: .copy) }
        for (rect, color) in zip(rects.ram, [settings.graphFG1Color, settings.graphFG2Color, settings.graphFG3Color]) {
            color.set(); rect.fill(using: .copy)
        }
        settings.graphFG1Color.set(); rects.swap.fill(using: .copy)
        updateLabels()
        if !mini { XRGGraphRenderer.drawStyle(in: bounds, settings: settings) }
    }

    @nonobjc static func processMemoryText(_ kibibytes: UInt64) -> String {
        if kibibytes > 1_048_576 { return String(format: "%.1fG", Double(kibibytes) / 1_048_576) }
        if kibibytes > 1024 { return String(format: "%.1fM", Double(kibibytes) / 1024) }
        return "\(kibibytes)K"
    }
    @nonobjc func makeMenu() -> NSMenu {
        let menu = NSMenu(title: "Memory View")
        func item(_ title: String, action: Selector) -> NSMenuItem {
            let item = NSMenuItem(title: title, action: action, keyEquivalent: "")
            item.target = self
            return item
        }
        menu.addItem(item("Top 10 Memory Processes", action: #selector(emptyEvent(_:))))
        processMiner.graphUpdate(nil)
        for process in processMiner.processesSortedByMemoryUsage().prefix(10) {
            let memory = (process["rss"] as? NSNumber)?.uint64Value ?? 0
            let pid = process["pid"] as? Int ?? 0, command = process["command"] as? String ?? ""
            menu.addItem(item("\(Self.processMemoryText(memory)) - \(command) (id \(pid))", action: #selector(emptyEvent(_:))))
        }
        menu.addItem(.separator())
        menu.addItem(item("Reset Graph", action: #selector(clearData(_:))))
        menu.addItem(.separator())
        menu.addItem(item("Open XRG-ng Memory Preferences...", action: #selector(openMemoryPreferences(_:))))
        return menu
    }
    public override func menu(for event: NSEvent) -> NSMenu? { makeMenu() }
    public func clearData(_ sender: Any?) {
        memoryMiner.reset()
        updateLabels()
        needsDisplay = true
    }
    public func emptyEvent(_ sender: Any?) {}
    public func openMemoryPreferences(_ sender: Any?) { host?.showMemoryPreferences() }
    public override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
    public override func mouseDown(with event: NSEvent) { window?.mouseDown(with: event) }
    public override func mouseDragged(with event: NSEvent) { window?.mouseDragged(with: event) }
    public override func mouseUp(with event: NSEvent) { window?.mouseUp(with: event) }
}
