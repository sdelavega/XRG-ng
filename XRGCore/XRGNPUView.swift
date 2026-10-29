// Copyright (C) 2026 Stephen de la Vega.
// SPDX-License-Identifier: GPL-3.0-or-later
import AppKit

@MainActor @objc public protocol XRGNPUViewHost: NSObjectProtocol {
    var appSettings: XRGSettings? { get }
    var moduleManager: XRGModuleManager? { get }
    var npuView: XRGNPUView? { get set }
    func initTimers()
    func showGeneralPreferences()
}

@MainActor @objc(XRGNPUView) @objcMembers
public final class XRGNPUView: NSView, XRGModuleView {
    private let miner: XRGNPUMiner
    private let defaults: UserDefaults
    private let standaloneSettings: XRGSettings?
    private weak var host: (any XRGNPUViewHost)?
    private weak var registeredManager: XRGModuleManager?
    private var didAwake = false
    public private(set) weak var module: XRGModule?
    @nonobjc let labels = XRGGraphLabels()
    private var settings: XRGSettings? { host?.appSettings ?? standaloneSettings }

    public override init(frame frameRect: NSRect) {
        miner = XRGNPUMiner(); defaults = .standard; standaloneSettings = nil
        super.init(frame: frameRect); prepare()
    }
    public required init?(coder: NSCoder) {
        miner = XRGNPUMiner(); defaults = .standard; standaloneSettings = nil
        super.init(coder: coder); prepare()
    }
    @nonobjc init(frame: NSRect, miner: XRGNPUMiner, settings: XRGSettings?, defaults: UserDefaults) {
        self.miner = miner; self.defaults = defaults; standaloneSettings = settings
        super.init(frame: frame); prepare()
    }
    private func prepare() {
        for label in [labels.leftLabel, labels.centerLabel, labels.rightLabel] { addSubview(label) }
        miner.onUpdate = { [weak self] in self?.updateLabels(); self?.needsDisplay = true }
        setGraphSize(bounds.size); updateLabels()
    }
    public nonisolated override func awakeFromNib() {
        super.awakeFromNib()
        MainActor.assumeIsolated { didAwake = true; bindToWindow() }
    }
    public override func viewDidMoveToWindow() { super.viewDidMoveToWindow(); bindToWindow() }
    private func bindToWindow() {
        let next = window as? any XRGNPUViewHost
        if host !== next {
            if host?.npuView === self { host?.npuView = nil }
            if let module { registeredManager?.removeModule(module) }
            registeredManager = nil; module = nil; host = next
        }
        guard didAwake, let host, let manager = host.moduleManager, settings != nil,
              registeredManager !== manager else { updateLabels(); return }
        let module = XRGModule(name: "NPU", reference: self, defaults: defaults)
        module.displayOrder = 2; module.doesGraphUpdate = true
        module.isDisplayed = defaults.bool(forKey: "showNPUGraph")
        self.module = module; registeredManager = manager; host.npuView = self
        host.initTimers(); updateMinSize(); manager.addModule(module); setGraphSize(module.currentSize)
    }
    public func setGraphSize(_ size: NSSize) {
        miner.setDataSize(Int(min(20_000, max(23, size.width.isFinite ? size.width : 23))))
    }
    public override func setFrameSize(_ size: NSSize) {
        super.setFrameSize(size); setGraphSize(size); updateLabels()
    }
    public func updateMinSize() {
        guard let settings else { return }
        let attributes: [NSAttributedString.Key: Any] = [.font: settings.graphFont ?? NSFont.systemFont(ofSize: 10)]
        module?.minWidth = ("NPU 99.99 W" as NSString).size(withAttributes: attributes).width + 6
        module?.minHeight = XRGGraphLabels.lineHeight(settings); updateLabels()
    }
    public func graphUpdate(_ timer: Timer?) {
        miner.staleAfter = max(5, 3 * XRGGraphWindow.validRefresh(settings?.graphRefresh))
        miner.getLatestNPUInfo(); updateLabels(); needsDisplay = true
    }
    public func fastUpdate(_ timer: Timer?) {}
    public func min5Update(_ timer: Timer?) {}
    public func min30Update(_ timer: Timer?) {}
    public func fullReading() -> String { miner.fullReading() }
    public func shouldDrawMiniGraph() -> Bool { XRGGraphLabels.shouldDrawMiniGraph(in: bounds, settings: settings) }
    private func updateLabels() {
        let compact = bounds.width < 140
        // Keep the W suffix visible in the narrow default graph. The tooltip
        // and accessibility reading retain three decimal places.
        let watts = miner.powerWatts.map { String(format: compact ? ($0 < 10 ? "%.1fW" : "%.0fW") : "%.2f W", $0) } ?? "n/a"
        let status: String, values: String
        if let fraction = miner.activeFraction {
            status = fraction > 0 ? "Busy" : "Idle"
            let percent = fraction > 0 && fraction < 0.001 ? "<0.1%"
                : String(format: fraction > 0 && fraction < 0.01 ? "%.1f%%" : "%.0f%%", fraction * 100)
            values = "\(percent)\n\(watts)"
        } else {
            // An energy change is evidence of activity, but cannot define a percentage.
            if miner.trafficObserved == true { status = "Traffic" }
            else if (miner.powerWatts ?? 0) > 0 { status = "Pwr↑" }
            else { status = miner.trafficObserved == false ? "No bus" : "Pwr" }
            values = "\(watts)\nn/a%"
        }
        labels.layoutColumnText("NPU\n\(status)", centerText: nil,
                      rightText: values, in: XRGGraphLabels.paddedTextRect(for: bounds),
                      mini: shouldDrawMiniGraph(), settings: settings)
        toolTip = fullReading(); setAccessibilityElement(true); setAccessibilityLabel(fullReading())
    }
    public override func draw(_ dirtyRect: NSRect) {
        guard !isHidden, let settings, let context = NSGraphicsContext.current, XRGGraphRenderer.validRect(bounds) else { return }
        NSGraphicsContext.saveGraphicsState(); defer { NSGraphicsContext.restoreGraphicsState() }
        settings.graphColor(.tpu, component: 0).set(); context.cgContext.fill(bounds)
        if miner.activeFraction != nil {
            XRGGraphRenderer.drawCurve(miner.activityDataSet, upperBound: 100, lowerBound: 0,
                                        in: bounds, flipped: false, filled: true, color: settings.graphColor(.tpu, component: 1), style: settings.curveStyle(.tpu))
        } else if miner.powerWatts != nil {
            XRGGraphRenderer.drawCurve(miner.powerDataSet, upperBound: max(1, miner.powerDataSet.max * 1.1), lowerBound: 0,
                                        in: bounds, flipped: false, filled: true, color: settings.graphColor(.tpu, component: 1), style: settings.curveStyle(.tpu))
        }
        if miner.activeFraction == nil, miner.trafficObserved != nil {
            // A narrow presence band cannot be mistaken for a 100% capacity
            // meter. The main graph keeps its watt scale and n/a% label.
            let band = NSRect(x: bounds.minX, y: bounds.minY, width: bounds.width, height: min(6, bounds.height * 0.12))
            XRGGraphRenderer.drawCurve(miner.trafficDataSet, upperBound: max(1, miner.trafficDataSet.max * 1.1), lowerBound: 0,
                                        in: band, flipped: false, filled: true, color: settings.graphColor(.tpu, component: 2), style: settings.curveStyle(.tpu))
        }
        updateLabels(); XRGGraphRenderer.drawGraphEffect(in: bounds, settings: settings, module: .tpu)
    }
    public override func menu(for event: NSEvent) -> NSMenu? {
        let menu = NSMenu(title: "Neural Engine")
        let reading = NSMenuItem(title: fullReading(), action: nil, keyEquivalent: ""); reading.isEnabled = false; menu.addItem(reading)
        menu.addItem(.separator())
        let preferences = NSMenuItem(title: "Open Graph Preferences…", action: #selector(openPreferences(_:)), keyEquivalent: "")
        preferences.target = self; menu.addItem(preferences); return menu
    }
    public func openPreferences(_ sender: Any?) { host?.showGeneralPreferences() }
    public override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
    public override func mouseDown(with event: NSEvent) { window?.mouseDown(with: event) }
    public override func mouseDragged(with event: NSEvent) { window?.mouseDragged(with: event) }
    public override func mouseUp(with event: NSEvent) { window?.mouseUp(with: event) }
}
