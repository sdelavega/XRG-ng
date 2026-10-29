// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Stephen de la Vega.
import AppKit

/// A draft editor. Only Apply reaches the model; closing/reverting never saves its draft.
@MainActor final class XRGGraphPreferencesEditor: NSView, NSTableViewDataSource, NSTableViewDelegate {
    private weak var manager: XRGModuleManager?
    private weak var settings: XRGSettings?
    private let readVisibility: () -> [XRGGraphID: Bool]
    private let applyValue: (XRGGraphPreferences, [XRGGraphID: Bool]) throws -> Void
    private var baseline = XRGGraphPreferences()
    private var baselineVisibility: [XRGGraphID: Bool] = [:]
    private(set) var draft = XRGGraphPreferences()
    private(set) var visibility: [XRGGraphID: Bool] = [:]
    private var loading = false
    private var selected: XRGGraphID = .cpu
    let table = NSTableView()
    let customHeight = NSButton(checkboxWithTitle: "Preferred height", target: nil, action: nil)
    let heightField = NSTextField(string: "90")
    let curvePicker = NSPopUpButton(frame: .zero, pullsDown: false)
    let effectPicker = NSPopUpButton(frame: .zero, pullsDown: false)
    let errorLabel = NSTextField(wrappingLabelWithString: "")
    private let title = NSTextField(labelWithString: "CPU")
    private let hint = NSTextField(wrappingLabelWithString: "")
    private var customColors: [NSButton] = []
    private var colorWells: [NSColorWell] = []
    private var alphas: [NSSlider] = []

    init(manager: XRGModuleManager?, settings: XRGSettings?, visibility: @escaping () -> [XRGGraphID: Bool],
         apply: @escaping (XRGGraphPreferences, [XRGGraphID: Bool]) throws -> Void) {
        self.manager = manager; self.settings = settings; readVisibility = visibility; applyValue = apply
        super.init(frame: NSRect(x: 0, y: 0, width: 700, height: 490))
        build(); reload()
    }
    required init?(coder: NSCoder) { fatalError("Programmatic view") }
    private func label(_ text: String, _ x: CGFloat, _ y: CGFloat, _ width: CGFloat = 120) {
        let value = NSTextField(labelWithString: text); value.frame = NSRect(x: x, y: y, width: width, height: 20); addSubview(value)
    }
    private func button(_ text: String, _ x: CGFloat, _ y: CGFloat, _ width: CGFloat, _ action: Selector) {
        let value = NSButton(title: text, target: self, action: action); value.bezelStyle = .rounded
        value.frame = NSRect(x: x, y: y, width: width, height: 30); addSubview(value)
    }
    private func build() {
        label("Graph order and visibility", 20, 450, 240)
        let show = NSTableColumn(identifier: .init("show")); show.title = "Show"; show.width = 42
        let name = NSTableColumn(identifier: .init("name")); name.title = "Graph"; name.width = 165
        table.addTableColumn(show); table.addTableColumn(name); table.rowHeight = 26
        table.dataSource = self; table.delegate = self; table.allowsMultipleSelection = false; table.allowsEmptySelection = false
        table.setAccessibilityLabel("Graph order and visibility")
        let scroll = NSScrollView(frame: NSRect(x: 20, y: 112, width: 235, height: 330))
        scroll.hasVerticalScroller = true; scroll.borderType = .bezelBorder; scroll.documentView = table; addSubview(scroll)
        button("Move Up", 20, 76, 110, #selector(moveGraphUp(_:)))
        button("Move Down", 135, 76, 120, #selector(moveGraphDown(_:)))
        title.font = .boldSystemFont(ofSize: 15); title.frame = NSRect(x: 280, y: 450, width: 390, height: 24); addSubview(title)
        customHeight.frame = NSRect(x: 280, y: 410, width: 160, height: 24)
        customHeight.target = self; customHeight.action = #selector(edited(_:)); addSubview(customHeight)
        heightField.frame = NSRect(x: 450, y: 410, width: 65, height: 24); heightField.setAccessibilityLabel("Graph height")
        addSubview(heightField); label("64–240 pt", 525, 412)
        label("Curve fill", 280, 370)
        curvePicker.addItems(withTitles: ["Inherit existing curves"] + XRGCurveStyle.allCases.map(\.title))
        curvePicker.frame = NSRect(x: 410, y: 366, width: 255, height: 28)
        curvePicker.target = self; curvePicker.action = #selector(edited(_:)); curvePicker.setAccessibilityLabel("Graph curve fill")
        addSubview(curvePicker)
        label("Display effect", 280, 332)
        effectPicker.addItems(withTitles: ["Inherit global effect", "Normal", "Scanlines", "Pixel Grid", "Retro Dots"])
        effectPicker.frame = NSRect(x: 410, y: 328, width: 255, height: 28)
        effectPicker.target = self; effectPicker.action = #selector(edited(_:)); effectPicker.setAccessibilityLabel("Graph display effect")
        addSubview(effectPicker)
        label("Override color", 280, 295, 160); label("Opacity", 555, 295, 100)
        for (index, name) in ["Background", "Series 1", "Series 2", "Series 3"].enumerated() {
            let y = CGFloat(260 - index * 36)
            let use = NSButton(checkboxWithTitle: name, target: self, action: #selector(edited(_:)))
            use.frame = NSRect(x: 280, y: y, width: 150, height: 25); use.setAccessibilityLabel("Override \(name.lowercased()) color")
            let well = NSColorWell(frame: NSRect(x: 450, y: y, width: 65, height: 27))
            well.target = self; well.action = #selector(edited(_:)); well.isContinuous = true; well.setAccessibilityLabel("\(name) color")
            let alpha = NSSlider(value: 1, minValue: 0, maxValue: 1, target: self, action: #selector(edited(_:)))
            alpha.frame = NSRect(x: 540, y: y, width: 120, height: 25); alpha.setAccessibilityLabel("\(name) opacity")
            customColors.append(use); colorWells.append(well); alphas.append(alpha)
            addSubview(use); addSubview(well); addSubview(alpha)
        }
        hint.frame = NSRect(x: 280, y: 82, width: 390, height: 60); addSubview(hint)
        errorLabel.textColor = .systemRed; errorLabel.frame = NSRect(x: 20, y: 36, width: 655, height: 36); addSubview(errorLabel)
        button("Reset Selected", 20, 4, 140, #selector(resetSelected(_:)))
        button("Reset All", 165, 4, 125, #selector(resetAll(_:)))
        button("Cancel", 478, 4, 90, #selector(cancel(_:)))
        button("Apply", 574, 4, 100, #selector(apply(_:)))
    }
    func reload() {
        baseline = settings?.graphPreferences ?? XRGGraphPreferences(); baselineVisibility = readVisibility()
        draft = baseline; visibility = baselineVisibility
        loading = true; table.reloadData()
        let index = draft.orderedIDs.firstIndex(of: selected) ?? 0
        table.selectRowIndexes(IndexSet(integer: index), byExtendingSelection: false); loading = false
        errorLabel.stringValue = settings?.graphPreferencesError ?? ""
        showSelected()
    }
    func refreshIfClean() {
        if collect(), draft == baseline && visibility == baselineVisibility { reload() }
    }
    func numberOfRows(in tableView: NSTableView) -> Int { draft.orderedIDs.count }
    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        guard draft.orderedIDs.indices.contains(row) else { return nil }
        let id = draft.orderedIDs[row]
        if tableColumn?.identifier.rawValue == "show" {
            let button = NSButton(checkboxWithTitle: "", target: self, action: #selector(toggleVisibility(_:)))
            button.identifier = .init(id.rawValue); button.state = visibility[id] == true ? .on : .off
            button.setAccessibilityLabel("Show \(id.title) graph"); return button
        }
        return NSTextField(labelWithString: id.title)
    }
    func selectionShouldChange(in tableView: NSTableView) -> Bool { loading || collect() }
    func tableViewSelectionDidChange(_ notification: Notification) {
        guard !loading, draft.orderedIDs.indices.contains(table.selectedRow) else { return }
        selected = draft.orderedIDs[table.selectedRow]; showSelected()
    }
    private func showSelected() {
        loading = true; defer { loading = false }
        let value = draft[selected]; title.stringValue = selected.title
        customHeight.state = value.height == nil ? .off : .on
        heightField.integerValue = value.height ?? 90; heightField.isEnabled = value.height != nil
        curvePicker.selectItem(at: value.curve.flatMap { XRGCurveStyle.allCases.firstIndex(of: $0) }.map { $0 + 1 } ?? 0)
        effectPicker.selectItem(at: value.effect.map { $0 + 1 } ?? 0)
        for index in 0..<4 {
            let rgba = value.colors[index]
            let inherited = settings.map { [$0.graphBGColor, $0.graphFG1Color, $0.graphFG2Color, $0.graphFG3Color][index] } ?? .clear
            colorWells[index].color = rgba.map { NSColor(srgbRed: $0[0], green: $0[1], blue: $0[2], alpha: $0[3]) } ?? inherited
            alphas[index].doubleValue = rgba?[3] ?? Double(inherited.alphaComponent)
            customColors[index].state = rgba == nil ? .off : .on
            colorWells[index].isEnabled = rgba != nil; alphas[index].isEnabled = rgba != nil
        }
        hint.stringValue = selected == .ai
            ? "Series 1/2/3 color Claude/Codex/Gemini. Ollama and Hermes retain their blended provider colors. Apply saves this panel; Cancel discards its draft."
            : "Unchecked colors inherit the global theme. Preferred heights compress in small windows. Apply saves this panel; Cancel discards its draft."
    }
    @discardableResult private func collect() -> Bool {
        guard !loading else { return true }
        var value = draft[selected]
        if customHeight.state == .on {
            guard let height = Int(heightField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)), (64...240).contains(height) else {
                errorLabel.stringValue = "Enter a whole graph height between 64 and 240."; return false
            }
            value.height = height
        } else { value.height = nil }
        value.curve = curvePicker.indexOfSelectedItem > 0 ? XRGCurveStyle.allCases[curvePicker.indexOfSelectedItem - 1] : nil
        value.effect = effectPicker.indexOfSelectedItem > 0 ? effectPicker.indexOfSelectedItem - 1 : nil
        for index in 0..<4 {
            if customColors[index].state == .on {
                guard let rgb = colorWells[index].color.usingColorSpace(.sRGB) else { errorLabel.stringValue = "Choose an RGB graph color."; return false }
                let components = [Double(rgb.redComponent), Double(rgb.greenComponent), Double(rgb.blueComponent)]
                guard components.allSatisfy(\.isFinite) else { errorLabel.stringValue = "Choose finite RGB graph colors."; return false }
                value.colors[index] = components.map { min(1, max(0, $0)) } + [alphas[index].doubleValue]
            } else { value.colors[index] = nil }
        }
        do { try value.validate() } catch { errorLabel.stringValue = error.localizedDescription; return false }
        draft[selected] = value; errorLabel.stringValue = ""; return true
    }
    @objc private func edited(_ sender: Any?) {
        guard !loading else { return }
        heightField.isEnabled = customHeight.state == .on
        for index in 0..<4 {
            colorWells[index].isEnabled = customColors[index].state == .on; alphas[index].isEnabled = customColors[index].state == .on
        }
        _ = collect()
    }
    @objc private func toggleVisibility(_ sender: NSButton) {
        if let raw = sender.identifier?.rawValue, let id = XRGGraphID(rawValue: raw) { visibility[id] = sender.state == .on }
    }
    @objc func moveGraphUp(_ sender: Any?) { move(-1) }
    @objc func moveGraphDown(_ sender: Any?) { move(1) }
    private func move(_ offset: Int) {
        guard collect(), let index = draft.orderedIDs.firstIndex(of: selected) else { return }
        let target = index + offset
        guard draft.orderedIDs.indices.contains(target) else { return }
        var order = draft.orderedIDs; order.swapAt(index, target); draft.order = order
        loading = true; table.reloadData(); table.selectRowIndexes(IndexSet(integer: target), byExtendingSelection: false); loading = false
    }
    @objc func resetSelected(_ sender: Any?) { draft[selected] = XRGGraphOverride(); showSelected(); errorLabel.stringValue = "" }
    @objc func resetAll(_ sender: Any?) {
        draft = XRGGraphPreferences(); loading = true; table.reloadData()
        table.selectRowIndexes(IndexSet(integer: draft.orderedIDs.firstIndex(of: selected) ?? 0), byExtendingSelection: false); loading = false
        showSelected(); errorLabel.stringValue = ""
    }
    @objc func cancel(_ sender: Any?) { reload() }
    @objc @discardableResult func apply(_ sender: Any?) -> Bool {
        guard collect() else { return false }
        guard settings?.graphPreferences == baseline, readVisibility() == baselineVisibility else {
            errorLabel.stringValue = "Graphs changed elsewhere. Cancel to reload before applying."; return false
        }
        do {
            try draft.validate(); try applyValue(draft, visibility); reload(); return true
        } catch { errorLabel.stringValue = error.localizedDescription; return false }
    }
}
