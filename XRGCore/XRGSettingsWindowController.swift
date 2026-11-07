// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Stephen de la Vega.
//
// The macOS settings window (0.2.3 spec §5): a full-height vibrancy sidebar
// tinted with `--a7b-surface-chrome` under a full-size content view title
// bar, a scrolling pane of flat opaque cards — one per catalog `group`,
// each led by a `//` mono eyebrow — and one control per catalog entry, all
// styled from `XRGAether7b` only. Changes apply and save instantly through
// `XRGSettingsStore.set` (decision D9); an invalid entry is not saved and
// shows the danger rim and a mono reason; every section has a
/// reset-with-confirmation; an unreadable settings file shows a banner with
// a Replace action; the appearance follows the system and reduced motion
// disables animation. No nib: `MainMenu.nib`'s Preferences item routes here
// through the app delegate.

import AppKit

/// Supplies the runtime options of `source` controls: sensors, network
/// interfaces, disks, GPUs — the platform's live enumeration (spec §1).
public protocol XRGSettingsSourceProvider {
    /// The options of one source kind, in display order. `group` names the
    /// group a picker's section header shows (the temperature groups
    /// Identified, Unidentified and Suspected unused from PR #6); `value`
    /// is the persisted choice; `label` is what the user sees.
    func options(kind: String) -> [(group: String, value: String, label: String)]
}

/// A fixture provider: fixed options per kind, for tests and fixture scenes.
/// A plain value type: it enumerates nothing.
public struct XRGFixtureSettingsSourceProvider: XRGSettingsSourceProvider {
    private let options: [String: [(group: String, value: String, label: String)]]
    public init(options: [String: [(String, String, String)]]) {
        self.options = options.mapValues { list in list.map { (group: $0.0, value: $0.1, label: $0.2) } }
    }
    public func options(kind: String) -> [(group: String, value: String, label: String)] {
        options[kind] ?? []
    }
}

/// The production provider, backed by the hardware enumeration the old
/// preferences used: logical CPUs, discovered GPUs, network interfaces,
/// GPU memory pools, fans and the temperature sensors with their
/// identification groups (PR #6).
@MainActor public final class XRGHardwareSettingsSourceProvider: XRGSettingsSourceProvider {
    /// Injectable so tests can pin hardware; the defaults enumerate live.
    var gpus: () -> [(String, String)] = { XRGHardwareSettingsSourceProvider.discoveredGPUs() }
    var interfaces: () -> [String] = { XRGNetMiner().networkInterfaces() }
    var gpuMemory: () -> [(String, String)] = { XRGHardwareSettingsSourceProvider.gpuMemoryReadings() }
    var fans: () -> [(String, String)] = { XRGTemperatureMiner.shared.fanValues().map { ($0.key, $0.name ?? $0.key) } }
    var sensors: () -> [(String, String, XRGSensorGroup)] = {
        let miner = XRGTemperatureMiner.shared
        return miner.locationKeys(includingUnknown: true).compactMap { key in
            miner.sensor(forLocation: key).map { ($0.key, $0.label(), miner.sensorGroup(forKey: key)) }
        }
    }
    var logicalCPUs: () -> Int = { ProcessInfo.processInfo.activeProcessorCount }

    public init() {}

    public func options(kind: String) -> [(group: String, value: String, label: String)] {
        switch kind {
        case "cpu":
            var list: [(String, String, String)] = [("CPUs", "", "All logical CPUs")]
            for index in 0..<logicalCPUs() { list.append(("CPUs", String(index), "Logical CPU \(index + 1)")) }
            return list.map { (group: $0.0, value: $0.1, label: $0.2) }
        case "gpu":
            var list: [(String, String, String)] = [("GPUs", "", "All discovered GPUs")]
            for (index, gpu) in gpus().enumerated() { list.append(("GPUs", gpu.0, "GPU \(index + 1) · \(gpu.1)")) }
            return list.map { (group: $0.0, value: $0.1, label: $0.2) }
        case "network":
            return ([("Network", "", "All active interfaces")]
                + interfaces().map { ("Network", $0, $0) }).map { (group: $0.0, value: $0.1, label: $0.2) }
        case "gpu_memory":
            return ([("Memory", "", "Automatic")]
                + gpuMemory().map { ("Memory", $0.0, $0.1) }).map { (group: $0.0, value: $0.1, label: $0.2) }
        case "fans":
            return ([("Fans", "", "Automatic")]
                + fans().map { ("Fans", $0.0, $0.1) }).map { (group: $0.0, value: $0.1, label: $0.2) }
        case "temperature":
            var list: [(String, String, String)] = [("Temperature", "", "None")]
            let order: [(XRGSensorGroup, String)] = [(.identified, "Identified Sensors"),
                                                     (.unidentified, "Unidentified Sensors"),
                                                     (.suspectedUnused, "Suspected Unused Sensors")]
            for (group, title) in order {
                for sensor in sensors() where sensor.2 == group { list.append((title, sensor.0, sensor.1)) }
            }
            return list.map { (group: $0.0, value: $0.1, label: $0.2) }
        default:
            return []
        }
    }

    /// Discovered GPUs: opaque IOService location or registry id, with vendor.
    static func discoveredGPUs() -> [(String, String)] {
        let miner = XRGGPUMiner()
        return miner.currentSamples.map { ($0.selectionID, $0.vendor.isEmpty ? "Unknown vendor" : $0.vendor) }
    }
    /// GPU memory readings for the VRAM curve pickers.
    static func gpuMemoryReadings() -> [(String, String)] {
        let miner = XRGGPUMiner()
        guard case .success(let readings) = miner.memorySnapshot else { return [] }
        return readings.map { ($0.id, $0.name) }
    }
}

/// The settings window. Sidebar sections in catalog order (D7), instant
/// apply, danger validation, reset with confirmation, unreadable-file
/// recovery.
@MainActor @objcMembers
public final class XRGSettingsWindowController: NSWindowController, NSWindowDelegate {
    public let store: XRGSettingsStore
    public let catalog: XRGSettingsCatalog
    public let sources: any XRGSettingsSourceProvider
    public private(set) var currentSection: String = XRGSettingsCatalog.sections[0]
    /// Confirmation for the reset actions; the default asks with a panel.
    /// Tests and fixtures replace it.
    public var confirmReset: ((String) -> Bool)?
    /// The `general.updates.check_now` action.
    public var performCheckForUpdates: (() -> Void)?
    /// The AI pane's "Allow Budget Notifications…" action from 0.2.2: the one
    /// old-preferences affordance with no other surface (counter resets stay
    /// in the AI Tokens graph's menu). Non-nil adds a row to the AI section.
    public var requestBudgetNotifications: (() async -> String)?
    /// The themes import/export panel seams (tests inject deterministic URLs).
    public var chooseThemeImport: ((XRGSettingsWindowController) -> Void)?
    public var chooseThemeExport: ((XRGSettingsWindowController) -> Void)?
    /// The theme import/export engine: settings over the same store.
    private var themeSettings: XRGSettings?
    var storeObserver: NSObjectProtocol?
    /// The sidebar's section buttons, in catalog order.
    private(set) var sectionButtons: [XRGSettingsFlatButton] = []
    public private(set) var currentControls: [XRGSettingsEntryControl] = []
    let contentRoot = XRGSettingsRootView(frame: NSRect(x: 0, y: 0, width: 720, height: 560))

    public init(store: XRGSettingsStore, catalog: XRGSettingsCatalog, sources: any XRGSettingsSourceProvider) {
        self.store = store
        self.catalog = catalog
        self.sources = sources
        let window = NSWindow(contentRect: contentRoot.frame,
                               styleMask: [.titled, .closable, .miniaturizable, .fullSizeContentView],
                               backing: .buffered, defer: false)
        window.title = "Settings"
        window.isReleasedWhenClosed = false
        window.titlebarAppearsTransparent = true
        window.toolbarStyle = .preference
        super.init(window: window)
        window.delegate = self
        contentRoot.controller = self
        window.contentView = contentRoot
        buildSidebar()
        render(section: currentSection)
        storeObserver = NotificationCenter.default.addObserver(
            forName: XRGSettingsStore.didChange, object: store, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.storeChanged() }
            }
    }
    @available(*, unavailable) required public init?(coder: NSCoder) { fatalError("Programmatic window") }
    isolated deinit {
        if let storeObserver { NotificationCenter.default.removeObserver(storeObserver) }
    }

    // MARK: Appearance

    var isDark: Bool {
        if let appearance = window?.effectiveAppearance { return XRGAether7bPalette.isDark(appearance: appearance) }
        return false
    }

    // MARK: Sections

    static let sectionTitles: [String: String] = [
        "general": "General", "appearance": "Appearance", "graphs": "Graphs", "sources": "Sources",
        "ai": "AI", "weather": "Weather", "stocks": "Stocks", "themes": "Themes & import",
    ]
    public func title(of section: String) -> String { Self.sectionTitles[section] ?? section }
    public func confirmResetTitle(_ section: String) -> String {
        "Reset \(title(of: section)) to defaults?"
    }

    /// Open the window on one section: renders it if needed. Presenting
    /// the window stays with the app delegate's presentation seam, exactly
    /// as the nib preferences did (the packaged smoke keeps windows
    /// un-ordered).
    public func show(section: String) {
        if section != currentSection || currentControls.isEmpty {
            render(section: section)
        } else {
            storeChanged()
        }
    }

    /// Re-render the current section (appearance change, store refresh).
    public func refresh() {
        render(section: currentSection)
    }

    /// Follow a stored change without rebuilding: the current controls
    /// re-present the store's values and their `depends` states. The
    /// graph relayout persists module sizes through the same
    /// notification, so a rebuild here would churn one render per curve.
    func storeChanged() {
        for control in currentControls { present(control: control) }
    }

    // MARK: Sidebar

    private func buildSidebar() {
        let dark = isDark
        let vibrancy = NSVisualEffectView(frame: NSRect(x: 0, y: 0, width: 190, height: contentRoot.frame.height))
        vibrancy.material = .underWindowBackground
        vibrancy.blendingMode = .behindWindow
        vibrancy.state = .active
        vibrancy.identifier = NSUserInterfaceItemIdentifier("settings-sidebar")
        // The Aether7b chrome tint over the vibrancy (--a7b-surface-chrome).
        let tint = NSView(frame: vibrancy.bounds)
        tint.autoresizingMask = [.width, .height]
        tint.wantsLayer = true
        tint.layer?.backgroundColor = XRGAether7b.Color.surfaceChrome(dark: dark).cgColor
        vibrancy.addSubview(tint)
        let stack = NSStackView()
        stack.translatesAutoresizingMaskIntoConstraints = false
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = XRGAether7b.Space.s1
        vibrancy.addSubview(stack)
        contentRoot.addSubview(vibrancy)
        self.sidebar = (vibrancy: vibrancy, stack: stack, tint: tint)
        NSLayoutConstraint.activate([
            vibrancy.leadingAnchor.constraint(equalTo: contentRoot.leadingAnchor),
            vibrancy.topAnchor.constraint(equalTo: contentRoot.topAnchor),
            vibrancy.bottomAnchor.constraint(equalTo: contentRoot.bottomAnchor),
            vibrancy.widthAnchor.constraint(equalToConstant: 190),
            stack.leadingAnchor.constraint(equalTo: vibrancy.leadingAnchor, constant: XRGAether7b.Space.s3),
            stack.trailingAnchor.constraint(lessThanOrEqualTo: vibrancy.trailingAnchor, constant: -XRGAether7b.Space.s2),
            stack.topAnchor.constraint(equalTo: contentRoot.safeAreaLayoutGuide.topAnchor, constant: XRGAether7b.Space.s4),
        ])
        for section in XRGSettingsCatalog.sections {
            let button = XRGSettingsFlatButton(title: Self.sectionTitles[section] ?? section) { [weak self] in
                self?.selectSection(section)
            }
            button.labelField.font = sansFont(XRGAether7b.TypeScale.sm.size)
            button.identifier = NSUserInterfaceItemIdentifier("section-\(section)")
            button.setAccessibilityLabel(Self.sectionTitles[section] ?? section)
            stack.addArrangedSubview(button)
            button.widthAnchor.constraint(equalTo: stack.widthAnchor, constant: -XRGAether7b.Space.s1).isActive = true
            sectionButtons.append(button)
        }
        restyleSidebar()
    }
    private var sidebar: (vibrancy: NSVisualEffectView, stack: NSStackView, tint: NSView)?
    private func restyleSidebar() {
        guard let sidebar else { return }
        let dark = isDark
        sidebar.tint.layer?.backgroundColor = XRGAether7b.Color.surfaceChrome(dark: dark).cgColor
        for (index, button) in sectionButtons.enumerated() {
            let selected = XRGSettingsCatalog.sections[index] == currentSection
            button.style(background: selected ? XRGAether7b.Color.accentTint(dark: dark) : nil,
                         text: selected ? XRGAether7b.Color.accentActive(dark: dark)
                                        : XRGAether7b.Color.textMuted(dark: dark),
                         border: nil, dark: dark)
        }
    }
    func selectSection(_ section: String) {
        render(section: section)
    }

    // MARK: Rendering

    func render(section: String) {
        guard let sidebar else { return } // not built yet: the sidebar comes first
        currentSection = section
        let dark = isDark
        // Drop the previous content pane, keep the sidebar.
        for view in contentRoot.subviews where view !== sidebar.vibrancy { view.removeFromSuperview() }
        currentControls = []
        restyleSidebar()

        let content = NSView(frame: .zero)
        content.translatesAutoresizingMaskIntoConstraints = false
        content.wantsLayer = true
        content.layer?.backgroundColor = XRGAether7b.Color.bgCanvas(dark: dark).cgColor
        content.identifier = NSUserInterfaceItemIdentifier("settings-content")
        contentRoot.addSubview(content)
        NSLayoutConstraint.activate([
            content.leadingAnchor.constraint(equalTo: sidebar.vibrancy.trailingAnchor),
            content.trailingAnchor.constraint(equalTo: contentRoot.trailingAnchor),
            content.topAnchor.constraint(equalTo: contentRoot.topAnchor),
            content.bottomAnchor.constraint(equalTo: contentRoot.bottomAnchor),
        ])

        let scroll = NSScrollView()
        scroll.translatesAutoresizingMaskIntoConstraints = false
        scroll.borderType = .noBorder
        scroll.hasVerticalScroller = true
        scroll.drawsBackground = false
        content.addSubview(scroll)
        let pane = NSStackView()
        pane.orientation = .vertical
        pane.alignment = .leading
        pane.spacing = XRGAether7b.Space.s3
        pane.edgeInsets = NSEdgeInsets(top: XRGAether7b.Space.s4 + 20, left: XRGAether7b.Space.s6,
                                       bottom: XRGAether7b.Space.s8, right: XRGAether7b.Space.s6)
        pane.translatesAutoresizingMaskIntoConstraints = false
        scroll.documentView = pane
        NSLayoutConstraint.activate([
            scroll.leadingAnchor.constraint(equalTo: content.leadingAnchor),
            scroll.trailingAnchor.constraint(equalTo: content.trailingAnchor),
            scroll.topAnchor.constraint(equalTo: content.topAnchor),
            scroll.bottomAnchor.constraint(equalTo: content.bottomAnchor),
            pane.widthAnchor.constraint(equalTo: scroll.widthAnchor),
        ])

        // The aurora orb (exactly one, anchored top-left).
        let orb = NSView(frame: .zero)
        orb.translatesAutoresizingMaskIntoConstraints = false
        orb.wantsLayer = true
        orb.layer?.backgroundColor = XRGAether7b.Color.orb(dark: dark).cgColor
        orb.layer?.cornerRadius = 140
        contentRoot.addSubview(orb, positioned: .below, relativeTo: content)
        NSLayoutConstraint.activate([
            orb.widthAnchor.constraint(equalToConstant: 280), orb.heightAnchor.constraint(equalToConstant: 280),
            orb.leadingAnchor.constraint(lessThanOrEqualTo: content.leadingAnchor, constant: -60),
            orb.topAnchor.constraint(equalTo: content.topAnchor, constant: -120),
        ])

        // Section eyebrow and title.
        pane.addArrangedSubview(XRGAether7bStyle.eyebrow(section, dark: dark))
        let title = NSTextField(labelWithString: title(of: section))
        title.font = sansFont(XRGAether7b.TypeScale.xl.size, weight: .semibold)
        title.textColor = XRGAether7b.Color.textMain(dark: dark)
        pane.addArrangedSubview(title)

        // The unreadable-file banner (spec §2): the file is never
        // overwritten until the user confirms replacing it.
        if store.loadProblem != nil {
            pane.addArrangedSubview(makeBanner(dark: dark))
        }

        // One card per group, in catalog order.
        let entries = catalog.entries.filter { $0.section == section && $0.platforms.contains(.macos) && $0.shown }
        var groups: [(String, [XRGSettingsEntry])] = []
        for entry in entries {
            if groups.last?.0 != entry.group { groups.append((entry.group, [])) }
            groups[groups.count - 1].1.append(entry)
        }
        for (group, groupEntries) in groups {
            let card = makeCard(title: group, dark: dark)
            for entry in groupEntries {
                let control = makeControl(entry: entry, dark: dark)
                currentControls.append(control)
                card.addRow(entry: entry, control: control, dark: dark)
            }
            pane.addArrangedSubview(card)
            card.widthAnchor.constraint(equalTo: pane.widthAnchor, constant: -(2 * XRGAether7b.Space.s1)).isActive = true
        }
        // The AI pane's notification permission, kept from 0.2.2: the one
        // old affordance with no other surface (spec §5: the catalog drives
        // every setting; this is an action, not a setting).
        if section == "ai", let requestBudgetNotifications {
            let card = makeCard(title: "Notifications", dark: dark)
            let button = XRGSettingsFlatButton(title: "Allow Budget Notifications…") { [weak self] in
                self?.allowBudgetNotifications()
            }
            button.labelField.font = sansFont(XRGAether7b.TypeScale.sm.size, weight: .medium)
            button.setAccessibilityLabel("Allow Budget Notifications")
            let status = NSTextField(wrappingLabelWithString: "")
            status.translatesAutoresizingMaskIntoConstraints = false
            status.font = sansFont(XRGAether7b.TypeScale.xs.size)
            status.textColor = XRGAether7b.Color.textMuted(dark: dark)
            budgetNotificationStatus = status
            card.rows.addArrangedSubview(button)
            card.rows.addArrangedSubview(status)
            button.bottomAnchor.constraint(equalTo: card.rows.bottomAnchor).isActive = true
            pane.addArrangedSubview(card)
            card.widthAnchor.constraint(equalTo: pane.widthAnchor, constant: -(2 * XRGAether7b.Space.s1)).isActive = true
        }
        scroll.layoutSubtreeIfNeeded()
        scroll.contentView.scroll(to: .zero)
    }
    func allowBudgetNotifications() {
        guard let requestBudgetNotifications else { return }
        Task { [weak self] in
            let message = await requestBudgetNotifications()
            await MainActor.run {
                self?.budgetNotificationStatus?.stringValue = message
            }
        }
    }
    private weak var budgetNotificationStatus: NSTextField?

    private func makeBanner(dark: Bool) -> NSView {
        let banner = NSView(frame: .zero)
        banner.translatesAutoresizingMaskIntoConstraints = false
        banner.wantsLayer = true
        banner.layer?.backgroundColor = XRGAether7b.Color.surfaceCard(dark: dark).cgColor
        banner.layer?.borderColor = XRGAether7bPalette.color(.statusWarning, dark: dark).cgColor
        banner.layer?.borderWidth = 1
        banner.layer?.cornerRadius = XRGAether7b.Radius.lg
        banner.identifier = NSUserInterfaceItemIdentifier("unreadable-file-banner")
        let text = NSTextField(wrappingLabelWithString:
            "The settings file could not be read. Changes are kept in memory and the file is left untouched.")
        text.identifier = NSUserInterfaceItemIdentifier("settings-load-problem")
        text.font = sansFont(XRGAether7b.TypeScale.sm.size)
        text.textColor = XRGAether7b.Color.textMain(dark: dark)
        text.translatesAutoresizingMaskIntoConstraints = false
        let replace = XRGSettingsFlatButton(title: "Replace the file with the current settings") { [weak self] in
            self?.replaceUnreadableFile()
        }
        replace.identifier = NSUserInterfaceItemIdentifier("replace-unreadable-file")
        replace.labelField.font = sansFont(XRGAether7b.TypeScale.sm.size)
        replace.style(background: nil, text: XRGAether7b.Color.textMain(dark: dark),
                      border: XRGAether7b.Color.borderStrong(dark: dark), dark: dark)
        replace.translatesAutoresizingMaskIntoConstraints = false
        banner.addSubview(text)
        banner.addSubview(replace)
        NSLayoutConstraint.activate([
            text.leadingAnchor.constraint(equalTo: banner.leadingAnchor, constant: XRGAether7b.Space.s4),
            text.topAnchor.constraint(equalTo: banner.topAnchor, constant: XRGAether7b.Space.s3),
            replace.leadingAnchor.constraint(equalTo: banner.leadingAnchor, constant: XRGAether7b.Space.s4),
            replace.topAnchor.constraint(equalTo: text.bottomAnchor, constant: XRGAether7b.Space.s2),
            replace.bottomAnchor.constraint(equalTo: banner.bottomAnchor, constant: -XRGAether7b.Space.s3),
            text.trailingAnchor.constraint(lessThanOrEqualTo: banner.trailingAnchor, constant: -XRGAether7b.Space.s4),
        ])
        return banner
    }
    func replaceUnreadableFile() {
        store.replaceUnreadableFile()
        refresh()
    }

    private func makeCard(title group: String, dark: Bool) -> XRGSettingsCardView {
        let card = XRGSettingsCardView(group: group, dark: dark)
        return card
    }

    // MARK: Controls

    func makeControl(entry: XRGSettingsEntry, dark: Bool) -> XRGSettingsEntryControl {
        let control: XRGSettingsEntryControl
        switch entry.control {
        case .toggle: control = XRGSettingsToggleControl(entry: entry, dark: dark)
        case .choice: control = XRGSettingsChoiceControl(entry: entry, dark: dark)
        case .segmented: control = XRGSettingsSegmentedControl(entry: entry, dark: dark)
        case .integer, .decimal, .duration: control = XRGSettingsNumberControl(entry: entry, dark: dark)
        case .color: control = XRGSettingsColorControl(entry: entry, dark: dark)
        case .path: control = XRGSettingsPathControl(entry: entry, dark: dark)
        case .text: control = XRGSettingsTextControl(entry: entry, dark: dark)
        case .source: control = XRGSettingsSourceControl(entry: entry, dark: dark)
        case .action: control = XRGSettingsActionControl(entry: entry, dark: dark)
        case .order: control = XRGSettingsTextControl(entry: entry, dark: dark)
        }
        control.applyEdit = { [weak self] control, value in self?.apply(control: control, value: value) }
        present(control: control)
        if let path = control as? XRGSettingsPathControl {
            path.onChoose = { [weak self] pathControl in self?.choosePath(pathControl) }
        }
        if let source = control as? XRGSettingsSourceControl {
            source.load(options: sources.options(kind: entry.source ?? ""),
                        noneLabel: entry.control == .source && entry.source == "temperature" ? "None" : "Automatic")
            present(control: source)
        }
        if let action = control as? XRGSettingsActionControl {
            action.onAction = { [weak self] control in self?.runAction(control) }
        }
        return control
    }

    /// Show the store's value in a control, silently.
    func present(control: XRGSettingsEntryControl) {
        control.present(store.value(control.entry.id))
        control.showError(nil)
        updateDependency(control: control)
    }

    /// The user edited a control: save instantly, or show the danger reason.
    func apply(control: XRGSettingsEntryControl, value: XRGSettingsValue) {
        do {
            try store.set(control.entry.id, value)
            control.showError(nil)
        } catch let error as XRGSettingsError {
            control.showError(Self.reason(for: error, entry: control.entry, catalog: catalog))
        } catch {
            control.showError("The value could not be saved.")
        }
    }

    static func reason(for error: XRGSettingsError, entry: XRGSettingsEntry,
                       catalog: XRGSettingsCatalog?) -> String {
        switch error {
        case .unknownId: return "Unknown setting."
        case .wrongType:
            switch entry.control {
            case .integer: return "Enter a whole number."
            case .decimal, .duration: return "Enter a number."
            case .choice, .segmented: return "Choose one of the options."
            default: return "The value has the wrong shape for this setting."
            }
        case .outOfRange(let min, let max):
            let unit = entry.range?.unit.flatMap { $0.isEmpty ? nil : $0 } ?? ""
            let unitText = unit.isEmpty ? "" : " \(unit)"
            let number = { (value: Double) in value == value.rounded() ? String(Int(value)) : String(value) }
            return "Between \(number(min))\(unitText) and \(number(max))\(unitText)."
        case .notAnOption: return "Choose one of the listed options."
        case .dependencyNotMet:
            if let depends = entry.depends, let dependsEntry = catalog?.entry(depends.id) {
                return "Requires \(dependsEntry.label) = \(depends.equals.isTextualDescription)."
            }
            return "Another setting must change first."
        }
    }

    /// Enable or disable a control following its entry's `depends`.
    func updateDependency(control: XRGSettingsEntryControl) {
        guard let depends = control.entry.depends else { control.setEnabled(true); return }
        let holds = XRGSettingsValue.sameValue(store.value(depends.id), depends.equals)
        control.setEnabled(holds)
    }

    func choosePath(_ path: XRGSettingsPathControl) {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = true
        if panel.runModal() == .OK, let url = panel.url { path.userChose(url: url) }
    }

    // MARK: Actions

    func runAction(_ action: XRGSettingsActionControl) {
        let id = action.entry.id
        if id.hasSuffix(".reset") {
            let section = action.entry.section
            if askResetConfirmation(for: section) {
                store.resetSection(section)
                refresh()
            }
        } else if id == "general.updates.check_now" {
            performCheckForUpdates?()
        } else if id == "themes.import" {
            importTheme()
        } else if id == "themes.export" {
            exportTheme()
        }
    }

    func askResetConfirmation(for section: String) -> Bool {
        if let confirmReset { return confirmReset(title(of: section)) }
        let alert = NSAlert()
        alert.messageText = confirmResetTitle(section)
        alert.informativeText = "Every \(title(of: section)) setting returns to its default. This cannot be undone."
        alert.addButton(withTitle: "Reset")
        alert.addButton(withTitle: "Cancel")
        return alert.runModal() == .alertFirstButtonReturn
    }

    func themeEngine() -> XRGSettings {
        if let themeSettings { return themeSettings }
        let settings = XRGSettings(store: store)
        themeSettings = settings
        return settings
    }

    /// An export format the save panel refuses (unreachable through the UI).
    static let unsupportedFormat: NSError = NSError(domain: "XRGSettingsExport", code: 1,
                                                    userInfo: [NSLocalizedDescriptionKey: "Unsupported theme format"])

    func importTheme() {
        if let chooseThemeImport { chooseThemeImport(self); return }
        let panel = NSOpenPanel()
        if panel.runModal() == .OK, let url = panel.url {
            do {
                try themeEngine().loadTheme(from: url, defaults: store.defaults)
                refresh()
            } catch {
                NSAlert(error: error).runModal()
            }
        }
    }
    func exportTheme() {
        if let chooseThemeExport { chooseThemeExport(self); return }
        let panel = NSSavePanel()
        panel.allowsOtherFileTypes = false; panel.isExtensionHidden = false
        panel.message = "Choose Original XRG or Portable Mac/Linux theme format."
        panel.directoryURL = FileManager.default.homeDirectoryForCurrentUser
        panel.nameFieldStringValue = "My Theme.xtf"
        let format = XRGThemeSaveFormat(panel: panel)
        if panel.runModal() == .OK, let url = panel.url {
            do {
                let data: Data
                switch url.pathExtension.lowercased() {
                case "json": data = try themeEngine().portableThemeData()
                case "xtf": data = try themeEngine().themeData()
                default: throw XRGSettingsWindowController.unsupportedFormat
                }
                try data.write(to: url, options: .atomic)
            } catch { NSAlert(error: error).runModal() }
        }
    }
}

/// The root content view: notifies the controller when the effective
/// appearance changes (light/dark follow the system, spec §5).
@MainActor final class XRGSettingsRootView: NSView {
    weak var controller: XRGSettingsWindowController?
    override func viewDidChangeEffectiveAppearance() {
        controller?.refresh()
    }
}

/// One flat, opaque card per catalog group (spec §5): surface card
/// background, hairline border, `radius-lg` corners, a `//` mono eyebrow.
@MainActor final class XRGSettingsCardView: NSView {
    let eyebrowLabel: NSTextField
    let rows = NSStackView()
    var dark: Bool
    init(group: String, dark: Bool) {
        self.dark = dark
        eyebrowLabel = XRGAether7bStyle.eyebrow(group, dark: dark)
        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false
        wantsLayer = true
        layer?.backgroundColor = XRGAether7b.Color.surfaceCard(dark: dark).cgColor
        layer?.borderColor = XRGAether7b.Color.border(dark: dark).cgColor
        layer?.borderWidth = 1
        layer?.cornerRadius = XRGAether7b.Radius.lg
        eyebrowLabel.translatesAutoresizingMaskIntoConstraints = false
        addSubview(eyebrowLabel)
        rows.orientation = .vertical
        rows.alignment = .leading
        rows.spacing = XRGAether7b.Space.s2
        rows.translatesAutoresizingMaskIntoConstraints = false
        rows.setAccessibilityLabel(group)
        addSubview(rows)
        NSLayoutConstraint.activate([
            eyebrowLabel.topAnchor.constraint(equalTo: topAnchor, constant: XRGAether7b.Space.s3),
            eyebrowLabel.leadingAnchor.constraint(equalTo: leadingAnchor, constant: XRGAether7b.Space.s4),
            rows.topAnchor.constraint(equalTo: eyebrowLabel.bottomAnchor, constant: XRGAether7b.Space.s2),
            rows.leadingAnchor.constraint(equalTo: leadingAnchor, constant: XRGAether7b.Space.s4),
            rows.trailingAnchor.constraint(lessThanOrEqualTo: trailingAnchor, constant: -XRGAether7b.Space.s4),
            rows.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -XRGAether7b.Space.s3),
        ])
    }
    @available(*, unavailable) required init?(coder: NSCoder) { fatalError("Programmatic view") }

    func addRow(entry: XRGSettingsEntry, control: XRGSettingsEntryControl, dark: Bool) {
        let row = NSStackView()
        row.orientation = .horizontal
        row.spacing = XRGAether7b.Space.s3
        row.translatesAutoresizingMaskIntoConstraints = false
        let label: NSView
        if entry.control == .action {
            label = NSView(frame: .zero)
            label.translatesAutoresizingMaskIntoConstraints = false
        } else {
            let text = NSTextField(wrappingLabelWithString: entry.label)
            text.font = sansFont(XRGAether7b.TypeScale.sm.size)
            text.textColor = XRGAether7b.Color.textMain(dark: dark)
            text.translatesAutoresizingMaskIntoConstraints = false
            text.setAccessibilityLabel(entry.label)
            label = text
        }
        row.addArrangedSubview(label)
        row.addArrangedSubview(control)
        if entry.control != .action {
            label.widthAnchor.constraint(greaterThanOrEqualToConstant: 180).isActive = true
            control.trailingAnchor.constraint(lessThanOrEqualTo: row.trailingAnchor).isActive = true
        }
        row.setAccessibilityLabel("\(entry.label)")
        rows.addArrangedSubview(row)
        row.widthAnchor.constraint(equalTo: rows.widthAnchor).isActive = true
    }
}