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
        var sourcesKey: String { self == .vram ? "vramGraphSourcesV1" : "fanGraphSourcesV1" }
    }
    @MainActor private final class History {
        let data = XRGDataSet()
        let timed = XRGTimedHistory(channels: 1, retentionMinutes: 60)!
        let projection = XRGTimeWindowProjection(channels: 1)
        var signature: String
        init(signature: String, size: Int) {
            self.signature = signature; data.resize(size); data.setAllValues(XRGGraphRenderer.missingValue)
        }
    }
    let kind: Kind
    private let historyClock: () -> TimeInterval
    private let source: () -> Result<[XRGHardwareReading], Error>
    private let defaults: UserDefaults
    private let standaloneSettings: XRGSettings?
    private weak var host: (any XRGHardwareViewHost)?
    private weak var registeredManager: XRGModuleManager?
    private var awake = false
    private var histories: [String: History] = [:]
    private var slots: [String?] = [nil, nil, nil]
    private var readError: String?
    private(set) var sourceSelection = XRGHardwareSources()
    private(set) var sourceSelectionError: String?
    private(set) var sourcesEditor: XRGHardwareSourcesEditor?
    private weak var sourcesHost: NSWindow?
    private weak var sourcesSheet: NSWindow?
    private var width = 120
    private(set) var readings: [XRGHardwareReading] = []
    private(set) var percentage = false
    private(set) var status: String
    private(set) weak var module: XRGModule?
    let labels = XRGGraphLabels()
    private var settings: XRGSettings? { host?.appSettings ?? standaloneSettings }

    init(kind: Kind, frame: NSRect, settings: XRGSettings?, defaults: UserDefaults,
         historyClock: @escaping () -> TimeInterval = { Date().timeIntervalSince1970 },
         source: @escaping () -> Result<[XRGHardwareReading], Error>) {
        self.historyClock = historyClock
        self.kind = kind; self.source = source; self.defaults = defaults; standaloneSettings = settings
        status = kind == .fans ? "No readable fan RPM" : "GPU memory unavailable"
        super.init(frame: frame)
        if defaults.object(forKey: kind.sourcesKey) != nil {
            if let data = defaults.data(forKey: kind.sourcesKey), let decoded = try? XRGHardwareSources(data: data) {
                sourceSelection = decoded
            } else {
                sourceSelectionError = "Saved source choices are invalid. Using automatic sources for this session; Apply valid choices to replace them."
            }
        }
        for label in [labels.leftLabel, labels.centerLabel, labels.rightLabel] { addSubview(label) }
        setGraphSize(frame.size); updateLabels()
    }
    required init?(coder: NSCoder) { fatalError("Programmatic optional graph") }
    nonisolated override func awakeFromNib() {
        super.awakeFromNib(); MainActor.assumeIsolated { awake = true; bindToWindow() }
    }
    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if sourcesHost != nil && sourcesHost !== window { cancelSources() }
        bindToWindow()
    }
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
        let next = retainedSamples > 0 ? retainedSamples : Int(min(20_000, max(1, size.width.isFinite ? size.width : 1)))
        guard width != next else { return }; width = next
        for history in histories.values { history.data.resize(next, fillingWith: retainedSamples > 0 ? XRGGraphRenderer.missingValue : 0) }
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
            readError = nil
        case .failure(let error): next = []; readError = error.localizedDescription
        }
        readings = next; project(appendSample: true, observedAt: historyClock())
    }
    private func project(appendSample: Bool, observedAt: TimeInterval? = nil) {
        let next = readings
        let currentIDs = Set(next.map(\.id))
        if let fixed = sourceSelection.sources { slots = fixed }
        else {
            for i in slots.indices where slots[i].map({ !currentIDs.contains($0) }) == true { slots[i] = nil }
            for reading in next where !slots.contains(reading.id) {
                if let empty = slots.firstIndex(where: { $0 == nil }) { slots[empty] = reading.id }
            }
        }
        let selected = Set(slots.compactMap { $0 })
        histories = histories.filter { selected.contains($0.key) && (sourceSelection.sources != nil || currentIDs.contains($0.key)) }
        let plotted = next.filter { selected.contains($0.id) }
        let percent = kind == .vram && (plotted.isEmpty && sourceSelection.sources != nil ? percentage : !plotted.isEmpty && plotted.allSatisfy { $0.capacity != nil })
        if percent != percentage { histories.removeAll(); percentage = percent }
        let missing = selected.subtracting(currentIDs)
        status = readError ?? (!missing.isEmpty ? "Selected sources unavailable" : plotted.isEmpty ? (kind == .fans ? "No readable fan RPM" : "GPU memory unavailable") : "")
        for reading in plotted {
            let signature = "\(reading.name)|\(reading.capacity.map(String.init(describing:)) ?? "none")|\(reading.note)|\(percentage)"
            let history: History
            let fresh = histories[reading.id]?.signature != signature
            if let existing = histories[reading.id], !fresh { history = existing }
            else { history = History(signature: signature, size: width); histories[reading.id] = history }
            let value = percentage ? reading.value / reading.capacity! * 100 : reading.value
            if appendSample || fresh { history.data.setNextValue(value) }
            if let observedAt { history.timed.append(time: observedAt, values: [value]) }
        }
        if appendSample {
            for id in missing {
                histories[id]?.data.setNextValue(XRGGraphRenderer.missingValue)
                if let observedAt { histories[id]?.timed.append(time: observedAt, values: [.nan]) }
            }
        }
        updateLabels(); needsDisplay = true
    }
    func applySources(_ value: XRGHardwareSources) throws {
        let data = try value.encoded()
        defaults.set(data, forKey: kind.sourcesKey)
        sourceSelection = value; sourceSelectionError = nil
        project(appendSample: false)
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
    var heading: String { kind == .fans ? "Fans" : !readings.contains(where: { slots.contains($0.id) }) ? "VRAM" : percentage ? "VRAM pool" : "GPU allocations" }
    var detailText: String {
        let semantics = kind == .fans
            ? "Read-only fan RPM. Zero can mean a stopped fan. Missing sensors are unavailable; no PWM or fan controls are written."
            : "Reported GPU pools/allocations, not inferred installed VRAM or system-RAM capacity. Curves use percent only when every plotted adapter has a valid reported capacity; otherwise all curves use bytes."
        let rows = readings.prefix(64).map { "\($0.name) [\($0.id)]: \(valueText($0))\n\($0.note)" }.joined(separator: "\n")
        let selected = slots.enumerated().compactMap { index, id in id.map {
            "Curve \(index + 1): \($0)" + (readings.contains(where: { $0.id == id }) ? "" : " · unavailable")
        } }.joined(separator: "\n")
        return "\(semantics)\n\(sourceSelection.sources == nil ? "Automatic sources" : "Custom sources")\n\(selected)\n\(sourceSelectionError ?? "")\n\(status)\nAvailable readings:\n\(rows)" + (readings.count > 64 ? "\nAdditional readings omitted" : "")
    }
    private func updateLabels() {
        let selected = slots.enumerated().compactMap { index, id -> (Int, String, XRGHardwareReading?)? in
            id.map { (index, $0, readings.first { $0.id == id }) }
        }
        let mini = XRGGraphLabels.shouldDrawMiniGraph(in: bounds, settings: settings)
        let left = ([heading] + (selected.isEmpty ? [status] : selected.map { "\($0.0 + 1): " + ($0.2?.name ?? "Unavailable: \($0.1)") })).joined(separator: "\n")
        let values = selected.map { $0.2.map(valueText) ?? "n/a" }
        let right = mini ? (values.isEmpty ? "n/a" : values.joined(separator: "\n")) : ([""] + values).joined(separator: "\n")
        labels.layoutColumnText(left, rightText: right, in: XRGGraphLabels.paddedTextRect(for: bounds),
                                mini: mini, settings: settings)
        toolTip = detailText; setAccessibilityLabel(kind.name); setAccessibilityHelp(detailText)
    }
    private func historyData(_ id: String) -> XRGDataSet? {
        guard let history = histories[id] else { return nil }
        return history.projection.values(from: history.timed, minutes: historyMinutes, interval: Double(settings?.graphRefresh ?? 1))?.first ?? history.data
    }
    func curve(_ id: String) -> [CGFloat] { historyData(id)?.orderedValues ?? [] }
    override func draw(_ dirtyRect: NSRect) {
        guard !isHidden, let settings, let context = NSGraphicsContext.current, XRGGraphRenderer.validRect(bounds) else { return }
        NSGraphicsContext.saveGraphicsState(); defer { NSGraphicsContext.restoreGraphicsState() }
        context.shouldAntialias = settings.antiAliasing
        settings.graphColor(kind.id, component: 0).set(); bounds.fill(using: .copy)
        let maxValue = histories.keys.flatMap { curve($0) }.filter { $0.isFinite && $0 != XRGGraphRenderer.missingValue }.max() ?? 0
        let upper: CGFloat = percentage ? 100 : max(1, min(maxValue, CGFloat.greatestFiniteMagnitude / 1.1) * 1.1)
        let style = settings.curveStyle(kind.id) ?? .solid
        for (index, id) in slots.enumerated() {
            guard let id, let data = historyData(id) else { continue }
            XRGGraphRenderer.drawCurve(data, upperBound: upper, lowerBound: 0, in: bounds,
                flipped: false, filled: true, color: settings.graphColor(kind.id, component: index + 1), style: style)
        }
        // Independent series must remain visible over opaque area fills.
        if style == .solid {
            for (index, id) in slots.enumerated() {
                guard let id, let data = historyData(id) else { continue }
                XRGGraphRenderer.drawCurve(data, upperBound: upper, lowerBound: 0, in: bounds,
                    flipped: false, filled: false, color: settings.graphColor(kind.id, component: index + 1), style: .hollow)
            }
        }
        XRGGraphRenderer.drawGraphEffect(in: bounds, settings: settings, module: kind.id)
    }
    override func menu(for event: NSEvent) -> NSMenu? { makeMenu() }
    func makeMenu() -> NSMenu {
        let menu = NSMenu(title: kind.name)
        let sources = NSMenuItem(title: "Choose Sources…", action: #selector(chooseSources(_:)), keyEquivalent: "")
        sources.target = self; menu.addItem(sources); menu.addItem(.separator())
        menu.addItem(XRGHistoryRetention.menu(kind == .vram ? "VRAM History" : "Fans History", count: retainedSamples, target: self, action: #selector(selectHistory(_:)), rootAction: #selector(emptyEvent(_:))))
        menu.addItem(XRGSystemTimeWindow.menu(kind == .vram ? "VRAM Time Window" : "Fans Time Window", minutes: historyMinutes, target: self, action: #selector(selectHistoryWindow(_:)), rootAction: #selector(emptyEvent(_:))))
        for (title, action) in [("Read-only details…", #selector(showDetails(_:))), ("Reset Graph", #selector(clearData(_:)))] {
            let item = NSMenuItem(title: title, action: action, keyEquivalent: ""); item.target = self; menu.addItem(item)
        }
        return menu
    }
    static let windowKey = "XRGHardwareGraphView.VRAM.HistoryMinutes.v1"
    static let fanWindowKey = "XRGHardwareGraphView.Fans.HistoryMinutes.v1"
    private var timeKey: String { kind == .vram ? Self.windowKey : Self.fanWindowKey }
    var historyMinutes: Int { XRGSystemTimeWindow.saved(defaults, key: timeKey) }
    @objc func selectHistoryWindow(_ sender: Any?) {
        guard XRGSystemTimeWindow.store(sender, defaults: defaults, key: timeKey) else { return }
        updateLabels(); needsDisplay = true
    }
    static let historyKey = "XRGHardwareGraphView.VRAM.HistorySamples.v1"
    static let fanHistoryKey = "XRGHardwareGraphView.Fans.HistorySamples.v1"
    private var retentionKey: String { kind == .vram ? Self.historyKey : Self.fanHistoryKey }
    var retainedSamples: Int { XRGHistoryRetention.saved(defaults, key: retentionKey) }
    @objc func selectHistory(_ sender: Any?) {
        guard XRGHistoryRetention.store(sender, defaults: defaults, key: retentionKey) else { return }
        defaults.set(0, forKey: timeKey)
        setGraphSize(bounds.size); updateLabels(); needsDisplay = true
    }
    @objc func emptyEvent(_ sender: Any?) {}
    @objc func chooseSources(_ sender: Any?) {
        guard let window, window.attachedSheet == nil else { return }
        let editor = XRGHardwareSourcesEditor(selection: sourceSelection, readings: readings, suggested: slots, name: kind.name)
        let alert = NSAlert(); alert.messageText = "\(kind.name) Sources"
        alert.informativeText = "Choose the source for each curve, or keep automatic selection. This changes graph display only; hardware controls are never written."
        alert.accessoryView = editor.view
        alert.addButton(withTitle: "Cancel").keyEquivalent = "\r"
        alert.addButton(withTitle: "Apply").keyEquivalent = ""
        editor.validityChanged = { [weak alert] valid in alert?.buttons.last?.isEnabled = valid }
        editor.changed(nil); sourcesEditor = editor; sourcesHost = window; sourcesSheet = alert.window
        NotificationCenter.default.addObserver(self, selector: #selector(sourcesHostWillClose(_:)), name: NSWindow.willCloseNotification, object: window)
        alert.beginSheetModal(for: window) { [weak self, editor] response in
            guard let self else { return }
            NotificationCenter.default.removeObserver(self, name: NSWindow.willCloseNotification, object: self.sourcesHost)
            self.sourcesEditor = nil; self.sourcesSheet = nil; self.sourcesHost = nil
            if response == .alertSecondButtonReturn {
                do { try self.applySources(editor.draft) }
                catch { self.sourceSelectionError = error.localizedDescription; self.updateLabels() }
            }
        }
    }
    @objc private func sourcesHostWillClose(_ notification: Notification) { cancelSources() }
    private func cancelSources() {
        guard let host = sourcesHost, let sheet = sourcesSheet, host.attachedSheet === sheet else { return }
        host.endSheet(sheet, returnCode: .cancel); sheet.orderOut(nil)
    }
    @objc func clearData(_ sender: Any?) {
        for history in histories.values { history.data.setAllValues(XRGGraphRenderer.missingValue); history.timed.clear() }
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
