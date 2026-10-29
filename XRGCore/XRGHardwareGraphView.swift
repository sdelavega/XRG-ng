// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Stephen de la Vega.
import AppKit

@MainActor protocol XRGHardwareViewHost: AnyObject {
    var appSettings: XRGSettings? { get }
    var moduleManager: XRGModuleManager? { get }
    func initTimers()
}

/// Optional read-only plots own their histories; resizing or clearing never
/// changes the existing GPU/temperature charts or writes hardware controls.
@MainActor @objc(XRGHardwareGraphView)
final class XRGHardwareGraphView: NSView, XRGModuleView {
    enum Kind { case vram, fans
        var id: XRGGraphID { self == .vram ? .vram : .fans }
        var name: String { id.name }
    }
    @MainActor private final class History {
        let data = XRGDataSet()
        var signature: String
        init(signature: String, size: Int) {
            self.signature = signature; data.resize(size); data.setAllValues(XRGGraphRenderer.missingValue)
        }
    }
    let kind: Kind
    private let source: () -> Result<[XRGHardwareReading], Error>
    private let defaults: UserDefaults
    private let standaloneSettings: XRGSettings?
    private weak var host: (any XRGHardwareViewHost)?
    private weak var registeredManager: XRGModuleManager?
    private var awake = false
    private var histories: [String: History] = [:]
    private var slots: [String?] = [nil, nil, nil]
    private var width = 120
    private(set) var readings: [XRGHardwareReading] = []
    private(set) var percentage = false
    private(set) var status: String
    private(set) weak var module: XRGModule?
    let labels = XRGGraphLabels()
    private var settings: XRGSettings? { host?.appSettings ?? standaloneSettings }

    init(kind: Kind, frame: NSRect, settings: XRGSettings?, defaults: UserDefaults,
         source: @escaping () -> Result<[XRGHardwareReading], Error>) {
        self.kind = kind; self.source = source; self.defaults = defaults; standaloneSettings = settings
        status = kind == .fans ? "No readable fan RPM" : "GPU memory unavailable"
        super.init(frame: frame)
        for label in [labels.leftLabel, labels.centerLabel, labels.rightLabel] { addSubview(label) }
        setGraphSize(frame.size); updateLabels()
    }
    required init?(coder: NSCoder) { fatalError("Programmatic optional graph") }
    nonisolated override func awakeFromNib() {
        super.awakeFromNib(); MainActor.assumeIsolated { awake = true; bindToWindow() }
    }
    override func viewDidMoveToWindow() { super.viewDidMoveToWindow(); bindToWindow() }
    private func bindToWindow() {
        let next = window as? any XRGHardwareViewHost
        if host !== next || registeredManager !== next?.moduleManager {
            if let module { registeredManager?.removeModule(module) }
            module = nil; registeredManager = nil; host = next
        }
        guard awake, let host, let manager = host.moduleManager, settings != nil, registeredManager !== manager else { return }
        let module = XRGModule(name: kind.name, reference: self, defaults: defaults)
        // Stable ties place these after NPU/Temperature without renumbering the
        // original modules or changing older saved layout priorities.
        module.displayOrder = kind == .vram ? 2 : 5
        module.doesGraphUpdate = true; module.doesFastUpdate = false
        module.doesMin5Update = false; module.doesMin30Update = false
        module.isDisplayed = defaults.bool(forKey: kind.id.visibilityKey)
        self.module = module; registeredManager = manager
        updateMinSize(); manager.addModule(module); host.initTimers()
    }
    func setGraphSize(_ size: NSSize) {
        let next = Int(min(20_000, max(1, size.width.isFinite ? size.width : 1)))
        guard width != next else { return }; width = next
        for history in histories.values { history.data.resize(next) }
    }
    override func setFrameSize(_ size: NSSize) { super.setFrameSize(size); setGraphSize(size); updateLabels() }
    func updateMinSize() {
        module?.minWidth = 110; module?.minHeight = XRGGraphLabels.lineHeight(settings)
        updateLabels()
    }
    func graphUpdate(_ timer: Timer?) {
        let result = source()
        let next: [XRGHardwareReading]
        switch result {
        case .success(let values):
            var ids = Set<String>()
            next = values.filter { $0.valid && ids.insert($0.id).inserted }.sorted { $0.id < $1.id }
            status = next.isEmpty ? (kind == .fans ? "No readable fan RPM" : "GPU memory unavailable") : ""
        case .failure(let error): next = []; status = error.localizedDescription
        }
        let currentIDs = Set(next.map(\.id))
        histories = histories.filter { currentIDs.contains($0.key) }
        for i in slots.indices where slots[i].map({ !currentIDs.contains($0) }) == true { slots[i] = nil }
        for reading in next where !slots.contains(reading.id) {
            if let empty = slots.firstIndex(where: { $0 == nil }) { slots[empty] = reading.id }
        }
        let plotted = next.filter { slots.contains($0.id) }
        let percent = kind == .vram && !plotted.isEmpty && plotted.allSatisfy { $0.capacity != nil }
        if percent != percentage { histories.removeAll(); percentage = percent }
        readings = next
        for reading in plotted {
            let signature = "\(reading.name)|\(reading.capacity.map(String.init(describing:)) ?? "none")|\(reading.note)|\(percentage)"
            let history: History
            if let existing = histories[reading.id], existing.signature == signature { history = existing }
            else { history = History(signature: signature, size: width); histories[reading.id] = history }
            history.data.setNextValue(percentage ? reading.value / reading.capacity! * 100 : reading.value)
        }
        updateLabels(); needsDisplay = true
    }
    func fastUpdate(_ timer: Timer?) {}
    func min5Update(_ timer: Timer?) {}
    func min30Update(_ timer: Timer?) {}
    func valueText(_ reading: XRGHardwareReading) -> String {
        if kind == .fans { return String(format: "%.0f RPM", reading.value) }
        if let capacity = reading.capacity { return Self.memoryText(reading.value) + "/" + Self.memoryText(capacity) }
        return XRGCommon.formattedString(forBytes: reading.value)
    }
    private static func memoryText(_ bytes: Double) -> String {
        for (unit, size) in [("P", 1_125_899_906_842_624.0), ("T", 1_099_511_627_776.0), ("G", 1_073_741_824.0), ("M", 1_048_576.0), ("K", 1024.0)] where bytes >= size {
            let value = bytes / size
            return String(format: value >= 10 ? "%.0f%@" : "%.1f%@", value, unit)
        }
        return String(format: "%.0fB", bytes)
    }
    var heading: String { kind == .fans ? "Fans" : readings.isEmpty ? "VRAM" : percentage ? "VRAM pool" : "GPU allocations" }
    var detailText: String {
        let semantics = kind == .fans
            ? "Read-only fan RPM. Zero can mean a stopped fan. Missing sensors are unavailable; no PWM or fan controls are written."
            : "Reported GPU pools/allocations, not inferred installed VRAM or system-RAM capacity. Curves use percent only when every plotted adapter has a valid reported capacity; otherwise all curves use bytes."
        let rows = readings.prefix(64).map { "\($0.name) [\($0.id)]: \(valueText($0))\n\($0.note)" }.joined(separator: "\n")
        return "\(semantics)\n\(status)\n\(rows)" + (readings.count > 64 ? "\nAdditional readings omitted" : "")
    }
    private func updateLabels() {
        let visible = slots.enumerated().compactMap { index, id in readings.first { $0.id == id }.map { (index, $0) } }
        let mini = XRGGraphLabels.shouldDrawMiniGraph(in: bounds, settings: settings)
        let left = ([heading] + (visible.isEmpty ? [status] : visible.map { "\($0.0 + 1): \($0.1.name)" })).joined(separator: "\n")
        let values = visible.map { valueText($0.1) }
        let right = mini ? (values.isEmpty ? "n/a" : values.joined(separator: "\n")) : ([""] + values).joined(separator: "\n")
        labels.layoutColumnText(left, rightText: right, in: XRGGraphLabels.paddedTextRect(for: bounds),
                                mini: mini, settings: settings)
        toolTip = detailText; setAccessibilityLabel(kind.name); setAccessibilityHelp(detailText)
    }
    func curve(_ id: String) -> [CGFloat] { histories[id]?.data.orderedValues ?? [] }
    override func draw(_ dirtyRect: NSRect) {
        guard !isHidden, let settings, let context = NSGraphicsContext.current, XRGGraphRenderer.validRect(bounds) else { return }
        NSGraphicsContext.saveGraphicsState(); defer { NSGraphicsContext.restoreGraphicsState() }
        context.shouldAntialias = settings.antiAliasing
        settings.graphColor(kind.id, component: 0).set(); bounds.fill(using: .copy)
        let maxValue = histories.values.flatMap { $0.data.orderedValues }.filter { $0.isFinite && $0 != XRGGraphRenderer.missingValue }.max() ?? 0
        let upper: CGFloat = percentage ? 100 : max(1, min(maxValue, CGFloat.greatestFiniteMagnitude / 1.1) * 1.1)
        let style = settings.curveStyle(kind.id) ?? .solid
        for (index, id) in slots.enumerated() {
            guard let id, let history = histories[id] else { continue }
            XRGGraphRenderer.drawCurve(history.data, upperBound: upper, lowerBound: 0, in: bounds,
                flipped: false, filled: true, color: settings.graphColor(kind.id, component: index + 1), style: style)
        }
        // Independent series must remain visible over opaque area fills.
        if style == .solid {
            for (index, id) in slots.enumerated() {
                guard let id, let history = histories[id] else { continue }
                XRGGraphRenderer.drawCurve(history.data, upperBound: upper, lowerBound: 0, in: bounds,
                    flipped: false, filled: false, color: settings.graphColor(kind.id, component: index + 1), style: .hollow)
            }
        }
        XRGGraphRenderer.drawGraphEffect(in: bounds, settings: settings, module: kind.id)
    }
    override func menu(for event: NSEvent) -> NSMenu? { makeMenu() }
    func makeMenu() -> NSMenu {
        let menu = NSMenu(title: kind.name)
        for (title, action) in [("Read-only details…", #selector(showDetails(_:))), ("Reset Graph", #selector(clearData(_:)))] {
            let item = NSMenuItem(title: title, action: action, keyEquivalent: ""); item.target = self; menu.addItem(item)
        }
        return menu
    }
    @objc func clearData(_ sender: Any?) {
        for history in histories.values { history.data.setAllValues(XRGGraphRenderer.missingValue) }
        needsDisplay = true
    }
    @objc private func showDetails(_ sender: Any?) {
        guard let window else { return }; let alert = NSAlert()
        alert.messageText = kind.name; alert.informativeText = detailText
        alert.addButton(withTitle: "Done"); alert.beginSheetModal(for: window)
    }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
    override func mouseDown(with event: NSEvent) { window?.mouseDown(with: event) }
    override func mouseDragged(with event: NSEvent) { window?.mouseDragged(with: event) }
    override func mouseUp(with event: NSEvent) { window?.mouseUp(with: event) }
}
