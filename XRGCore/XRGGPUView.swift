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
        let count = min(20_000, Int(width))
        if miner.numSamples != count { miner.setDataSize(count) }
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
        miner.getLatestGraphicsInfo()
        updateLabels()
        needsDisplay = true
    }
    public func fastUpdate(_ timer: Timer?) {}
    public func min5Update(_ timer: Timer?) {}
    public func min30Update(_ timer: Timer?) {}

    private struct Card {
        let total: XRGDataSet
        let free: XRGDataSet
        let wait: XRGDataSet
        let utilization: XRGDataSet
        let vendor: String
        let hasMemory: Bool
        let hasUtilization: Bool
        var validMemory: Bool {
            hasMemory && total.currentValue.isFinite && total.currentValue > 0
                && free.currentValue.isFinite && free.currentValue >= 0 && free.currentValue <= total.currentValue
        }
        var used: CGFloat { validMemory ? total.currentValue - free.currentValue : 0 }
    }
    @nonobjc private func cards() -> [Card] {
        let count = miner.totalVRAMDataSets.count
        guard [miner.freeVRAMDataSets.count, miner.cpuWaitDataSets.count, miner.utilizationDataSets.count,
               miner.vendorNames.count, miner.memoryAvailable.count, miner.utilizationAvailable.count]
            .allSatisfy({ $0 == count }) else { return [] }
        return (0..<count).map { index in
            Card(total: miner.totalVRAMDataSets[index], free: miner.freeVRAMDataSets[index],
                 wait: miner.cpuWaitDataSets[index], utilization: miner.utilizationDataSets[index],
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
            let value = card.utilization.currentValue
            return value.isFinite ? String(format: "%.0f%%", min(100, max(0, value)).rounded(.towardZero)) : "n/a"
        }
        return Self.waitText(card.wait.currentValue)
    }
    @nonobjc private func miniValues(_ cards: [Card]) -> ([NSNumber], String) {
        let values = cards.map { NSNumber(value: $0.validMemory ? Double($0.used / $0.total.currentValue * 100) : 0) }
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
    private func updateLabels() { layoutLabels(cards()) }
    @nonobjc private func layoutLabels(_ cards: [Card]) {
        let mini = shouldDrawMiniGraph()
        ensureLabelCount(mini || cards.isEmpty ? 1 : cards.count)
        if cards.isEmpty || mini {
            cardLabels[0].layout(leftText: "GPU", centerText: nil, rightText: miniValues(cards).1,
                                 in: paddedTextRect(), mini: mini, settings: settings)
            return
        }
        for (index, card) in cards.enumerated() {
            let rect = cards.count == 1 ? bounds : band(at: index, count: cards.count)
            let textRect = XRGGraphLabels.paddedTextRect(for: rect)
            let title = cards.count == 1 ? "GPU" : "GPU \(index + 1)"
            var memory = "n/a"
            if card.validMemory {
                memory = XRGCommon.formattedString(forBytes: Double(card.used))
                if textRect.width >= 110 { memory += " / " + XRGCommon.formattedString(forBytes: Double(card.total.currentValue)) }
            }
            cardLabels[index].layout(leftText: "\(title)\n\(card.vendor)", centerText: nil,
                rightText: "\(memory)\n\(usageText(card))", in: textRect,
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
                if card.validMemory, let used = XRGDataSet(contentsOfOtherDataSet: card.total) {
                    used.subtractOtherDataSetValues(card.free)
                    if used.max > 0 {
                        XRGGraphRenderer.drawCurve(used, upperBound: card.total.max, lowerBound: 0, in: rect,
                            flipped: false, filled: true, color: settings.graphColor(.gpu, component: 1), style: settings.curveStyle(.gpu))
                    }
                }
                let data = card.hasUtilization ? card.utilization : card.wait
                XRGGraphRenderer.drawCurve(data, upperBound: card.hasUtilization ? 100 : max(data.max, 100),
                    lowerBound: 0, in: rect, flipped: false, filled: false, color: settings.graphColor(.gpu, component: 2), style: settings.curveStyle(.gpu))
            }
        }
        layoutLabels(cards)
        XRGGraphRenderer.drawGraphEffect(in: bounds, settings: settings, module: .gpu)
    }

    public override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
    public override func mouseDown(with event: NSEvent) { window?.mouseDown(with: event) }
    public override func mouseDragged(with event: NSEvent) { window?.mouseDragged(with: event) }
    public override func mouseUp(with event: NSEvent) { window?.mouseUp(with: event) }
}
