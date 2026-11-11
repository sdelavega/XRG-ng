// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Stephen de la Vega.
//
// The macOS settings window (0.2.3 spec §5): a full-height vibrancy sidebar
// tinted with `--a7b-surface-chrome` under a full-size content view title
// bar, the mockup's soft blurred aurora wash on the canvas, and a scrolling
// pane of flat opaque cards — one per catalog `group`, each led by a `//`
// mono eyebrow — with one control per catalog entry, all styled from
// `XRGAether7b` only. Changes apply and save instantly through
// `XRGSettingsStore.set` (decision D9); an invalid entry is not saved and
// shows the danger rim, dot and a mono reason; every section has a
// reset-with-confirmation; an unreadable settings file shows a banner with
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
    var sensors: (() -> [(String, String, XRGSensorGroup)])?
    /// The unknown-sensor policy: the retained "Show unknown sensors"
    /// setting decides, exactly as the sensor window and temperature view
    /// do (review issue 5). The app delegate wires the live store in.
    public var includeUnknownSensors: () -> Bool = { XRGTemperatureView.showUnknownSensors(nil) }
    var logicalCPUs: () -> Int = { ProcessInfo.processInfo.activeProcessorCount }

    public init() {
        sensors = { [weak self] in
            let miner = XRGTemperatureMiner.shared
            let includeUnknown = self?.includeUnknownSensors() ?? XRGTemperatureView.showUnknownSensors(nil)
            return miner.locationKeys(includingUnknown: includeUnknown).compactMap { key in
                miner.sensor(forLocation: key).map { ($0.key, $0.label(), miner.sensorGroup(forKey: key)) }
            }
        }
    }

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
                for sensor in (sensors?() ?? []) where sensor.2 == group { list.append((title, sensor.0, sensor.1)) }
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
/// recovery, full keyboard navigation and accessibility activation.
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
    /// The AI "Allow Budget Notifications…" action: the one old-preferences
    /// affordance with no other surface (counter resets stay in the AI
    /// Tokens graph's menu). Non-nil makes the catalog row functional;
    /// nil keeps it visible but inert.
    public var requestBudgetNotifications: (() async -> String)?
    /// The themes import/export panel seams (tests inject deterministic URLs).
    public var chooseThemeImport: ((XRGSettingsWindowController) -> Void)?
    public var chooseThemeExport: ((XRGSettingsWindowController) -> Void)?
    /// The Weather section's Station Listing link (the deleted controller's
    /// action, coordinator ruling P1). Tests replace it to capture the URL.
    public var openURL: ((URL) -> Bool)?
    /// The Appearance section's "Choose font…" action: presenting the system
    /// font panel over the current font (ruling P3). Tests replace it.
    public var presentFontPanel: ((NSFont) -> Void)?
    /// Called after the graph font changed through the font panel, so the
    /// app delegate can relayout module minimums.
    public var graphFontChanged: (() -> Void)?
    /// The theme import/export engine: settings over the same store.
    private var themeSettings: XRGSettings?
    var storeObserver: NSObjectProtocol?
    /// Observes the store's persistence state (final review, finding 3) so
    /// a write failure or recovery shows — and clears — immediately while a
    /// section is open, instead of only at the next section render.
    var persistenceObserver: NSObjectProtocol?
    /// The current section's persistence banner and its message: installed
    /// in every section, hidden while the store reports no problem.
    private(set) var persistenceBanner: NSView?
    private weak var persistenceBannerText: NSTextField?
    /// The sidebar's section buttons, in catalog order.
    private(set) var sectionButtons: [XRGSettingsFlatButton] = []
    public private(set) var currentControls: [XRGSettingsEntryControl] = []
    let contentRoot = XRGSettingsRootView(frame: NSRect(x: 0, y: 0, width: 720, height: 560))
    /// The mockup's aurora wash: one soft, low-alpha orb in the token
    /// colour, anchored top-left over the canvas (fix V7 — never a
    /// hard-edged disc).
    private(set) var auroraWash: XRGAuroraWashView?

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
            forName: XRGSettingsStore.didChange, object: store, queue: .main) { [weak self] note in
                let id = note.userInfo?["id"] as? String
                MainActor.assumeIsolated { self?.storeChanged(id: id) }
            }
        persistenceObserver = NotificationCenter.default.addObserver(
            forName: XRGSettingsStore.persistenceStateDidChange, object: store, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.persistenceStateChanged() }
            }
    }
    @available(*, unavailable) required public init?(coder: NSCoder) { fatalError("Programmatic window") }
    isolated deinit {
        if let storeObserver { NotificationCenter.default.removeObserver(storeObserver) }
        if let persistenceObserver { NotificationCenter.default.removeObserver(persistenceObserver) }
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
            storeChanged(id: nil)
        }
    }

    /// Re-render the current section (appearance change, store refresh).
    public func refresh() {
        render(section: currentSection)
    }

    /// Follow a stored change without rebuilding: only the control whose
    /// entry changed re-presents its value (and clears any error); every
    /// other control keeps the user's in-flight text, error included, and
    /// only re-evaluates its `depends` state (review issue 3). A nil id
    /// (the same-section `show`, a whole-window refresh) re-presents
    /// everything.
    func storeChanged(id: String?) {
        for control in currentControls {
            if id == nil || control.entry.id == id {
                present(control: control)
            } else {
                updateDependency(control: control)
            }
        }
        if id == "sources.temperature.show_unknown" { reloadTemperatureSources() }
    }

    /// The unknown-sensor policy changed: refill every temperature picker.
    func reloadTemperatureSources() {
        for case let source as XRGSettingsSourceControl in currentControls
        where source.entry.source == "temperature" {
            source.load(options: sources.options(kind: "temperature"), noneLabel: "None")
            present(control: source)
        }
    }

    // MARK: Sidebar

    private func buildSidebar() {
        let dark = isDark
        // The canvas paints the aurora wash's backdrop (fix V7): the
        // content pane itself stays transparent, like the mockup's main
        // pane, so the wash shows around the cards.
        contentRoot.wantsLayer = true
        contentRoot.layer?.backgroundColor = XRGAether7b.Color.bgCanvas(dark: dark).cgColor
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
        // The aurora wash sits above the chrome tint and below the section
        // buttons, spilling past the sidebar into the content pane, exactly
        // the reference CSS's stacking.
        let wash = XRGAuroraWashView(dark: dark)
        vibrancy.addSubview(wash)
        auroraWash = wash
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
        // The mockup's orb geometry: 60% of the window's width, square,
        // anchored above-left (top -35%, left -15%), blurred to a wash.
        NSLayoutConstraint.activate([
            wash.widthAnchor.constraint(equalTo: contentRoot.widthAnchor, multiplier: 0.6),
            wash.heightAnchor.constraint(equalTo: wash.widthAnchor),
            wash.leadingAnchor.constraint(equalTo: contentRoot.leadingAnchor,
                                          constant: contentRoot.frame.width * -0.15),
            wash.topAnchor.constraint(equalTo: contentRoot.topAnchor,
                                      constant: contentRoot.frame.height * -0.35),
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
        contentRoot.layer?.backgroundColor = XRGAether7b.Color.bgCanvas(dark: dark).cgColor
        sidebar.tint.layer?.backgroundColor = XRGAether7b.Color.surfaceChrome(dark: dark).cgColor
        auroraWash?.restyle(dark: dark)
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

        // The content pane is transparent: the canvas and its aurora wash
        // show around the cards, like the mockup's main pane.
        let content = NSView(frame: .zero)
        content.translatesAutoresizingMaskIntoConstraints = false
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
        // The document view is flipped: content pins to the top and every
        // section opens from its first card (fix V1).
        let pane = XRGSettingsPaneStack()
        pane.orientation = .vertical
        pane.alignment = .leading
        pane.spacing = XRGAether7b.Space.s3
        let insets = NSEdgeInsets(top: XRGAether7b.Space.s12, left: XRGAether7b.Space.s6,
                                  bottom: XRGAether7b.Space.s8, right: XRGAether7b.Space.s6)
        pane.edgeInsets = insets
        pane.translatesAutoresizingMaskIntoConstraints = false
        scroll.documentView = pane
        NSLayoutConstraint.activate([
            scroll.leadingAnchor.constraint(equalTo: content.leadingAnchor),
            scroll.trailingAnchor.constraint(equalTo: content.trailingAnchor),
            scroll.topAnchor.constraint(equalTo: content.topAnchor),
            scroll.bottomAnchor.constraint(equalTo: content.bottomAnchor),
            pane.widthAnchor.constraint(equalTo: scroll.widthAnchor),
        ])

        // Section eyebrow and title.
        pane.addArrangedSubview(XRGAether7bStyle.eyebrow(section, dark: dark))
        let title = NSTextField(labelWithString: title(of: section))
        title.font = sansFont(XRGAether7b.TypeScale.xl.size, weight: .semibold)
        title.textColor = XRGAether7b.Color.textMain(dark: dark)
        pane.addArrangedSubview(title)

        // The persistence banner (spec §2; final review, finding 3): always
        // installed for the section, shown only while the store reports a
        // problem, so a failure or recovery that happens while the section
        // is open appears immediately — without re-rendering the section or
        // disturbing any control's in-flight text.
        let banner = makeBanner(dark: dark)
        banner.isHidden = store.loadProblem == nil
        persistenceBanner = banner
        pane.addArrangedSubview(banner)

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
            // The card honours the pane's side insets: its right edge must
            // land inside the scroll view (fix V2), never past it.
            card.widthAnchor.constraint(equalTo: pane.widthAnchor,
                                        constant: -(insets.left + insets.right)).isActive = true
            if let status = card.notificationStatusLabel { budgetNotificationStatus = status }
        }
        scroll.layoutSubtreeIfNeeded()
        scroll.contentView.scroll(to: .zero)
        wireKeyViewLoop()
    }

    /// Link every focusable view into the window's key-view loop, sidebar
    /// first, so Tab and Shift-Tab traverse the whole window in a
    /// deterministic order (review issue 4). The loop is explicit — the
    /// window stops auto-recalculating it from geometry.
    func wireKeyViewLoop() {
        window?.autorecalculatesKeyViewLoop = false
        var sequence: [NSView] = sectionButtons
        if store.loadProblem != nil,
           let replace = findReplaceButton() {
            sequence.append(replace)
        }
        for control in currentControls {
            sequence.append(contentsOf: control.focusableViews())
        }
        for (view, next) in zip(sequence, sequence.dropFirst()) { view.nextKeyView = next }
        window?.initialFirstResponder = sequence.first
    }
    private func findReplaceButton() -> XRGSettingsFlatButton? {
        func walk(_ view: NSView) -> [NSView] { [view] + view.subviews.flatMap { walk($0) } }
        return walk(contentRoot).compactMap { $0 as? XRGSettingsFlatButton }
            .first { $0.identifier?.rawValue == "replace-unreadable-file" }
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
    /// The AI section's budget-notification status, for tests and the
    /// accessibility report.
    var budgetNotificationStatusText: String? { budgetNotificationStatus?.stringValue }

    private func makeBanner(dark: Bool) -> NSView {
        let banner = NSView(frame: .zero)
        banner.translatesAutoresizingMaskIntoConstraints = false
        banner.wantsLayer = true
        banner.layer?.backgroundColor = XRGAether7b.Color.surfaceCard(dark: dark).cgColor
        banner.layer?.borderColor = XRGAether7bPalette.color(.statusWarning, dark: dark).cgColor
        banner.layer?.borderWidth = 1
        banner.layer?.cornerRadius = XRGAether7b.Radius.lg
        banner.identifier = NSUserInterfaceItemIdentifier("unreadable-file-banner")
        let text = NSTextField(wrappingLabelWithString: Self.persistenceMessage(for: store.loadProblem))
        text.identifier = NSUserInterfaceItemIdentifier("settings-load-problem")
        text.font = sansFont(XRGAether7b.TypeScale.sm.size)
        text.textColor = XRGAether7b.Color.textMain(dark: dark)
        text.translatesAutoresizingMaskIntoConstraints = false
        persistenceBannerText = text
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

    /// The store's persistence state changed while the window is open (final
    /// review, finding 3): show or hide the section's banner immediately,
    /// with the message that names what happened, and keep the key-view
    /// loop in step with the banner's visibility. Nothing re-renders, so
    /// every control keeps its in-flight text and the pending edits stay.
    func persistenceStateChanged() {
        let problem = store.loadProblem
        persistenceBanner?.isHidden = problem == nil
        if let problem {
            persistenceBannerText?.stringValue = Self.persistenceMessage(for: problem)
        }
        wireKeyViewLoop()
    }

    /// What the banner says for a persistence problem: a file that cannot be
    /// read (malformed, a newer version, permissions) keeps its old message;
    /// a file that cannot be written names that, so the already-open section
    /// tells the user which recovery action applies.
    static func persistenceMessage(for problem: XRGSettingsDiagnostic?) -> String {
        guard let problem else {
            return "The settings file could not be read. Changes are kept in memory and the file is left untouched."
        }
        if problem.problem.hasPrefix("unreadable:") {
            return "The settings file could not be written. Changes are kept in memory and the file is left untouched."
        }
        return "The settings file could not be read. Changes are kept in memory and the file is left untouched."
    }

    private func makeCard(title group: String, dark: Bool) -> XRGSettingsCardView {
        XRGSettingsCardView(group: group, dark: dark)
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
        case .order: control = XRGSettingsOrderControl(entry: entry, dark: dark)
        }
        control.applyEdit = { [weak self] control, value in self?.apply(control: control, value: value) }
        present(control: control)
        if entry.id == "appearance.font" {
            // The font field is a read-only display of the current font
            // (ruling P3): the "Choose font…" action edits it through the
            // system font panel. Read-only-ness is an enduring property of
            // the control (finding N4): the dependency refreshes that
            // follow any settings notification must never re-open it.
            if let display = control as? XRGSettingsTextControl {
                display.isReadOnlyDisplay = true
                display.textField.isEditable = false
                display.setAccessibilityValue(store.value("appearance.font").isTextualDescription)
            }
        }
        if let order = control as? XRGSettingsOrderControl {
            // A rebuilt order list rejoins the window's key-view loop
            // (finding N3: moves used to leave the keyboard chain behind
            // with the destroyed buttons).
            order.keyLoopInvalidated = { [weak self] in self?.wireKeyViewLoop() }
        }
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

    /// The user edited a control: save instantly, or show the danger
    /// reason. Selecting a built-in theme preset applies its selection,
    /// its palette and its name as ONE validated batch — one commit (round
    /// 4, ruling R37), so a preset can never land half-applied; editing a
    /// theme colour or transparency rides the SAME one-batch rule (round
    /// 5): the `themes.preset` designation the resulting colours produce —
    /// the built-in they exactly match, or Custom — is computed BEFORE
    /// persisting and travels the same validated batch, one commit, so a
    /// failed part can never leave the palette saved under a stale
    /// designation.
    func apply(control: XRGSettingsEntryControl, value: XRGSettingsValue) {
        if control.entry.id == "themes.preset", case .string(let name) = value,
           XRGBuiltinTheme.allCases.contains(where: { $0.name == name }) {
            applyBuiltinPreset(control: control, name: name)
            return
        }
        do {
            if control.entry.id.hasPrefix("appearance."),
               control.entry.id.hasSuffix(".color") || control.entry.id.hasSuffix(".transparency") {
                try store.setBatch([
                    XRGSettingsChange(id: control.entry.id, value: value),
                    XRGSettingsChange(id: "themes.preset",
                                      value: .string(presetDesignation(editing: control.entry.id, value: value))),
                ])
            } else {
                try store.set(control.entry.id, value)
            }
            control.showError(nil)
        } catch let error as XRGSettingsError {
            control.showError(Self.reason(for: error, entry: control.entry, catalog: catalog))
        } catch {
            control.showError("The value could not be saved.")
        }
    }

    /// The Themes preset (round 4, ruling R37): choosing a built-in applies
    /// the preset selection, the palette and the theme name through the
    /// shared theme engine as ONE validated batch — ONE commit — so a
    /// refused or failed part can never leave a partial preset behind.
    private func applyBuiltinPreset(control: XRGSettingsEntryControl, name: String) {
        guard let preset = XRGBuiltinTheme.allCases.first(where: { $0.name == name }) else { return }
        do {
            try themeEngine().applyThemeDictionary(preset.dictionary(), defaults: store.defaults,
                                                   extraChanges: [
                                                    XRGSettingsChange(id: "themes.preset",
                                                                      value: .string(preset.name)),
                                                    XRGSettingsChange(id: "themes.name",
                                                                      value: .string(preset.name)),
                                                   ])
            control.showError(nil)
            // The palette writes arrive as their own notifications on the
            // document backend; re-present everything so the legacy backend
            // (and the controls' dependent states) follow too.
            storeChanged(id: nil)
        } catch let error as NSError where error.domain == "XRGSettingsLegacyRefusal" {
            // The validated batch refused the preset whole (round 4, ruling
            // R37): nothing was stored or written, and the reason — built
            // the same way the single-entry path builds it — rides the
            // error `XRGSettings.applyThemeDictionary` throws.
            control.showError(error.localizedDescription)
        } catch {
            control.showError("The built-in theme could not be applied.")
        }
    }

    /// The palette ids, in the order the shared ABI's theme documents use.
    private static let paletteIds = ["appearance.window.color", "appearance.graph_background.color",
                                     "appearance.series1.color", "appearance.series2.color",
                                     "appearance.series3.color", "appearance.border.color",
                                     "appearance.text.color"]

    /// The `themes.preset` designation one palette edit produces, computed
    /// BEFORE the edit persists (round 5, ruling R37): the resulting
    /// palette — the stored colours with the edited entry replaced, an
    /// inherited (`null`) colour reading its catalog default — is compared
    /// against every built-in exactly; the one it matches names the
    /// designation (the catalog's own rule: "The built-in palette in use,
    /// or Custom when the colors were edited"), and anything else is
    /// Custom. A transparency edit leaves the colours untouched, so it
    /// re-evaluates the same designation the palette already carries.
    private func presetDesignation(editing id: String, value: XRGSettingsValue) -> String {
        let resulting = Self.paletteIds.map { paletteId -> [Double] in
            if paletteId == id {
                switch value {
                case .color(let rgba): return rgba
                case .null:
                    if let entry = catalog.entry(paletteId), case .color(let rgba) = entry.defaultValue {
                        return rgba
                    }
                    return [0, 0, 0, 1]
                default: return [0, 0, 0, 1]
                }
            }
            if case .color(let rgba) = store.value(paletteId) { return rgba }
            if let entry = catalog.entry(paletteId), case .color(let rgba) = entry.defaultValue {
                return rgba
            }
            return [0, 0, 0, 1]
        }
        return XRGBuiltinTheme.allCases.first { theme in
            zip(resulting, theme.rgba).allSatisfy { $0 == $1 }
        }?.name ?? "Custom"
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
        case .constraint:
            switch entry.constraint {
            case "icao-station": return "Enter a four-character ICAO station code, for example KSEA."
            case "absolute-path": return "Enter an absolute path of at most 4096 characters."
            case "loopback-url":
                return "Use an HTTP URL with a loopback IP (127.0.0.1 or [::1]), without credentials, query or fragment."
            case "process-filter": return "Enter at most 128 printable characters."
            case "whole-minutes": return "Enter a whole number of minutes."
            case "theme-name": return "Enter 1–80 printable characters, without leading or trailing spaces."
            case "device-name": return "Enter a device name of at most 255 characters without spaces, ':' or '/'."
            case "source-identity": return "Enter an identity of at most 4096 characters."
            case "cpu-index": return "Enter a CPU index between 0 and 1048575."
            default: return "The value breaks this setting's rules."
            }
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
        } else if id == "weather.station_list" {
            openWeatherStationList()
        } else if id == "appearance.choose_font" {
            chooseGraphFont()
        } else if id == "ai.notifications.allow" {
            allowBudgetNotifications()
        }
    }

    /// The Weather section's Station Listing link: the deleted controller's
    /// action, restored by the coordinator's ruling P1.
    static let stationListingURL = URL(string: "https://download.gauchosoft.com/xrg/stations.txt")!
    func openWeatherStationList() {
        let open = openURL ?? { NSWorkspace.shared.open($0) }
        _ = open(Self.stationListingURL)
    }

    /// The Appearance section's "Choose font…" action (ruling P3): open the
    /// system font panel on the current graph font. The panel's
    /// `changeFont:` arrives through the responder chain — this controller
    /// is the settings window's delegate — and lands in `changeFont(_:)`
    /// below, which writes the same `appearance.font` setting.
    func chooseGraphFont() {
        let font = themeEngine().graphFont ?? NSFont.systemFont(ofSize: 10)
        if let presentFontPanel { presentFontPanel(font); return }
        NSFontManager.shared.setSelectedFont(font, isMultiple: false)
        NSFontPanel.shared.makeKeyAndOrderFront(nil)
    }

    /// The font panel's action, through the responder chain: convert the
    /// current font and write the same setting the font field displays.
    @objc public func changeFont(_ sender: NSFontManager?) {
        guard let manager = sender else { return }
        let old = themeEngine().graphFont ?? NSFont.systemFont(ofSize: 10)
        applyGraphFont(manager.convert(old), old: old)
    }

    /// The write path behind the font panel's action: the typed settings
    /// follow the new font and the same `appearance.font` setting the
    /// read-only display shows is stored on both backends.
    func applyGraphFont(_ new: NSFont, old: NSFont) {
        guard new != old else { return }
        let settings = themeEngine()
        settings.graphFont = new
        try? store.set("appearance.font", .string(XRGSettings.fontDescriptor(new)))
        graphFontChanged?()
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

/// The scroll pane's document view: flipped, so content pins to the top
/// and every section opens from its first card (fix V1).
@MainActor final class XRGSettingsPaneStack: NSStackView {
    override var isFlipped: Bool { true }
}

/// The mockup's aurora wash (fix V7): the reference CSS anchors one orb
/// per canvas at 60% width and blurs it by 64 px — a soft, low-alpha wash
/// in the token colour, never a hard-edged disc. The blur is approximated
/// with a radial gradient that keeps a plateau and feathers to the token's
/// zero-alpha edge; the view never accepts a hit test.
@MainActor final class XRGAuroraWashView: NSView {
    private let gradient = CAGradientLayer()

    init(dark: Bool) {
        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false
        wantsLayer = true
        gradient.type = .radial
        gradient.startPoint = CGPoint(x: 0.5, y: 0.5)
        gradient.endPoint = CGPoint(x: 1.0, y: 0.5)
        layer?.addSublayer(gradient)
        restyle(dark: dark)
    }
    @available(*, unavailable) required init?(coder: NSCoder) { fatalError("Programmatic view") }

    override func layout() {
        super.layout()
        gradient.frame = bounds
    }
    /// The view is decoration only: clicks and accessibility hit tests
    /// pass through to the controls below it in z-order.
    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    func restyle(dark: Bool) {
        let orb = XRGAether7b.Color.orb(dark: dark)
        let transparent = orb.withAlphaComponent(0)
        // A plateau out to ~55% of the radius, feathering to nothing at the
        // edge — the shape blur(64px) gives a 60%-wide disc.
        gradient.colors = [orb.cgColor, orb.cgColor, transparent.cgColor]
        gradient.locations = [0, 0.55, 1]
    }
}

/// One flat, opaque card per catalog group (spec §5): surface card
/// background, hairline border, `radius-lg` corners, a `//` mono eyebrow.
/// Every non-action row lays its control out in one right-aligned column
/// with a wrapping label that takes the remaining width (the mockup's
/// `flex:1` label), so no row's label pushes its control out of line
/// (fix V5); action buttons align with the label column (fix V8).
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
            rows.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -XRGAether7b.Space.s4),
            rows.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -XRGAether7b.Space.s3),
        ])
    }
    @available(*, unavailable) required init?(coder: NSCoder) { fatalError("Programmatic view") }

    func addRow(entry: XRGSettingsEntry, control: XRGSettingsEntryControl, dark: Bool) {
        switch entry.control {
        case .order:
            // The reorderable list spans the card below its label.
            let label = XRGAether7bStyle.label(entry.label, dark: dark)
            label.setAccessibilityLabel(entry.label)
            rows.addArrangedSubview(label)
            rows.addArrangedSubview(control)
            label.widthAnchor.constraint(equalTo: rows.widthAnchor).isActive = true
            control.widthAnchor.constraint(equalTo: rows.widthAnchor).isActive = true
        case .action:
            // An action button sits in the label column, never indented by
            // a phantom label (fix V8). The budget-notification action also
            // carries its permission status below the button.
            rows.addArrangedSubview(control)
            control.leadingAnchor.constraint(equalTo: rows.leadingAnchor).isActive = true
            if entry.id == "ai.notifications.allow" {
                let status = NSTextField(wrappingLabelWithString: "")
                status.font = sansFont(XRGAether7b.TypeScale.xs.size)
                status.textColor = XRGAether7b.Color.textMuted(dark: dark)
                status.translatesAutoresizingMaskIntoConstraints = false
                status.identifier = NSUserInterfaceItemIdentifier("budget-notification-status")
                rows.addArrangedSubview(status)
                status.leadingAnchor.constraint(equalTo: rows.leadingAnchor, constant: XRGAether7b.Space.s3).isActive = true
                notificationStatusLabel = status
            }
        default:
            let label = NSTextField(wrappingLabelWithString: entry.label)
            label.font = sansFont(XRGAether7b.TypeScale.sm.size)
            label.textColor = XRGAether7b.Color.textMain(dark: dark)
            label.translatesAutoresizingMaskIntoConstraints = false
            label.setAccessibilityLabel(entry.label)
            let row = NSView(frame: .zero)
            row.translatesAutoresizingMaskIntoConstraints = false
            row.addSubview(label)
            row.addSubview(control)
            NSLayoutConstraint.activate([
                label.leadingAnchor.constraint(equalTo: row.leadingAnchor),
                label.centerYAnchor.constraint(equalTo: row.centerYAnchor),
                control.trailingAnchor.constraint(equalTo: row.trailingAnchor),
                control.centerYAnchor.constraint(equalTo: row.centerYAnchor),
                label.trailingAnchor.constraint(lessThanOrEqualTo: control.leadingAnchor,
                                                constant: -XRGAether7b.Space.s3),
                row.heightAnchor.constraint(greaterThanOrEqualToConstant: 30),
                // The row's height follows the control's FULL height, error
                // dot and reason label included (review issue 3): an
                // expanded control grows its own row instead of overlapping
                // the rows below — the pre-fix rows pinned only the
                // control's centre and a minimum height.
                row.bottomAnchor.constraint(greaterThanOrEqualTo: control.bottomAnchor,
                                            constant: XRGAether7b.Space.s1),
                row.bottomAnchor.constraint(greaterThanOrEqualTo: label.bottomAnchor),
            ])
            row.setAccessibilityLabel("\(entry.label)")
            rows.addArrangedSubview(row)
            row.widthAnchor.constraint(equalTo: rows.widthAnchor).isActive = true
        }
    }
    /// The AI section's budget-notification status label, handed to the
    /// controller after the row renders.
    weak var notificationStatusLabel: NSTextField?
}
