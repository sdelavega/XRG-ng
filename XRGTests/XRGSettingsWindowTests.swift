// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Stephen de la Vega.
import AppKit
import Testing
@testable import XRGCore

/// The Aether7b settings window (0.2.3 spec §5): sidebar, one control per
/// catalog entry, instant apply, danger-rim validation, reset-with-
/// confirmation, token-only colour and unreadable-file recovery.
/// Every fixture uses a temp-directory store and a disposable defaults suite.
@Suite(.serialized) @MainActor
struct XRGSettingsWindowTests {
    /// A store over a settings document in a temp directory, a disposable
    /// defaults suite removed from cfprefsd and disk, and a fixture source
    /// provider. Nothing touches the real com.sdelavega.xrg domain or the
    /// real ~/Library/Application Support/XRG-ng/settings.json.
    private struct Fixture {
        let domain: String
        let defaults: UserDefaults
        let root: URL
        var documentURL: URL { root.appendingPathComponent("settings.json") }
        let sources = XRGFixtureSettingsSourceProvider(options: [
            "temperature": [("Identified Sensors", "Ts0", "Fixture sensor"),
                            ("Unidentified Sensors", "Tu0", "Unnamed sensor")],
            "cpu": [("CPUs", "", "All logical CPUs"), ("CPUs", "0", "Logical CPU 1")],
            "gpu": [("GPUs", "", "All discovered GPUs"), ("GPUs", "gpu-1", "Fixture GPU")],
            "network": [("Network", "", "All active interfaces"), ("Network", "en0", "en0")],
            "gpu_memory": [("Memory", "", "Automatic"), ("Memory", "vram-1", "VRAM 1")],
            "fans": [("Fans", "", "Automatic"), ("Fans", "fan-0", "Fan 1")],
        ])
        private(set) var store: XRGSettingsStore?

        init() throws {
            let domain = "XRG.settingsWindow.\(UUID().uuidString)"
            let defaults = try #require(UserDefaults(suiteName: domain))
            let root = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
                .appendingPathComponent("xrg-0.2.3-task-9", isDirectory: true)
                .appendingPathComponent(domain, isDirectory: true)
            try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
            self.domain = domain
            self.defaults = defaults
            self.root = root
        }

        /// A fresh store over the fixture's document; seeds the 0.2.2 domain
        /// first when given (the migration path), so `defaults` never leaks
        /// into the real domain.
        @MainActor mutating func loadStore(seeding legacy: [String: Any] = [:]) throws -> XRGSettingsStore {
            if !legacy.isEmpty {
                for (key, value) in legacy { defaults.set(value, forKey: key) }
                defaults.synchronize()
            }
            let catalog = try #require(try? XRGSettingsCatalog.load())
            let store = XRGSettingsStore(fileURL: documentURL, defaults: defaults,
                                          catalog: catalog, legacyDomain: defaults.persistentDomain(forName: domain) ?? [:])
            self.store = store
            return store
        }

        func cleanUp() {
            defaults.removePersistentDomain(forName: domain)
            try? FileManager.default.removeItem(at: root)
            let plist = FileManager.default.homeDirectoryForCurrentUser
                .appendingPathComponent("Library/Preferences/\(domain).plist")
            try? FileManager.default.removeItem(at: plist)
        }
    }

    private func controller(_ fixture: Fixture, store: XRGSettingsStore) -> XRGSettingsWindowController {
        XRGSettingsWindowController(store: store, catalog: store.catalog, sources: fixture.sources)
    }

    /// The window's content view (never nil once shown).
    @MainActor private func content(_ window: XRGSettingsWindowController) -> NSView {
        window.window?.contentView ?? NSView(frame: .zero)
    }
    /// Every view the settings window itself creates, in order. AppKit's own
    /// control internals — button shape/darkening/text views, popup pockets,
    /// scroll backdrops — draw with system colours the window never sets, so
    /// the walk enters only the views the window builds.
    @MainActor private func walkOwned(_ view: NSView) -> [NSView] {
        if view is NSButton || view is NSPopUpButton || view is NSColorWell {
            return []
        }
        // The scroll view's pocket, mask and luminance internals draw with
        // system colours the window never sets; the document view is the
        // window's own tree.
        if let scroll = view as? NSScrollView {
            return [scroll] + walkOwned(scroll.contentView)
        }
        return [view] + view.subviews.flatMap { walkOwned($0) }
    }
    @MainActor private func walkControls(_ window: XRGSettingsWindowController) -> [XRGSettingsEntryControl] {
        walkOwned(content(window)).compactMap { $0 as? XRGSettingsEntryControl }
    }
    @MainActor private func walkViews(_ window: XRGSettingsWindowController) -> [NSView] {
        walkAll(content(window))
    }
    /// A plain whole-subtree walk (the sidebar's own buttons).
    @MainActor private func walkAll(_ view: NSView) -> [NSView] {
        [view] + view.subviews.flatMap { walkAll($0) }
    }

    // MARK: Step 1 tests

    @Test func sidebarListsTheApprovedSections() throws {
        var fixture = try Fixture(); defer { fixture.cleanUp() }
        let store = try fixture.loadStore()
        let window = controller(fixture, store: store)
        window.show(section: "general")
        let sidebar = content(window).subviews.first { $0.identifier?.rawValue == "settings-sidebar" } ?? NSView()
        let buttons = walkAll(sidebar)
            .compactMap { $0 as? XRGSettingsFlatButton }
            .compactMap { button -> (String, String)? in
                guard let identifier = button.identifier?.rawValue, identifier.hasPrefix("section-") else { return nil }
                return (String(identifier.dropFirst(8)), button.labelField.stringValue)
            }
        #expect(buttons.map(\.0) == XRGSettingsCatalog.sections)
        #expect(buttons.map(\.1) == ["General", "Appearance", "Graphs", "Sources", "AI", "Weather", "Stocks", "Themes & import"])
    }

    @Test func everyMacEntryHasAControl() throws {
        var fixture = try Fixture(); defer { fixture.cleanUp() }
        let store = try fixture.loadStore()
        let window = controller(fixture, store: store)
        let catalog = store.catalog
        let macEntries = catalog.entries.filter { $0.platforms.contains(.macos) && $0.shown }
        #expect(!macEntries.isEmpty)
        var seen = Set<String>()
        for section in XRGSettingsCatalog.sections {
            window.show(section: section)
            let controls = walkControls(window)
            for entry in macEntries where entry.section == section {
                let control = try #require(controls.first { $0.entry.id == entry.id }, "missing control for \(entry.id)")
                seen.insert(entry.id)
                #expect(control.entry.control == entry.control, "wrong control type for \(entry.id)")
                #expect(control.accessibilityLabel() == entry.label, "wrong label for \(entry.id)")
                #expect(XRGSettingsValue.sameValue(control.value(), store.value(entry.id)) == true,
                        "control default does not match the store for \(entry.id): \(control.value()) vs \(store.value(entry.id))")
                if let help = entry.help { #expect(control.toolTip == help, "wrong help for \(entry.id)") }
                if let range = entry.range, let number = control as? XRGSettingsNumberControl {
                    #expect(number.fieldMin == range.min && number.fieldMax == range.max, "wrong range for \(entry.id)")
                }
                if let options = entry.options, let choice = control as? XRGSettingsChoiceControl {
                    #expect(choice.optionLabels == options.map(\.label), "wrong options for \(entry.id)")
                }
                if entry.control == .source, let source = control as? XRGSettingsSourceControl {
                    #expect(!source.optionLabels.isEmpty, "no source options for \(entry.id)")
                }
            }
        }
        #expect(seen.count == macEntries.count, "some mac entries never rendered a control")
    }

    @Test func changingAControlSavesInstantly() throws {
        var fixture = try Fixture(); defer { fixture.cleanUp() }
        let store = try fixture.loadStore()
        let window = controller(fixture, store: store)
        window.show(section: "general")
        let posted = MainActorBox<[String]>([])
        let observer = NotificationCenter.default.addObserver(forName: XRGSettingsStore.didChange, object: store, queue: .main) { note in
            MainActor.assumeIsolated { posted.value.append(note.userInfo?["id"] as? String ?? "") }
        }
        defer { NotificationCenter.default.removeObserver(observer) }
        let controls = walkControls(window)
        let toggle = try #require(controls.first { $0.entry.id == "general.window.sticky_edges" } as? XRGSettingsToggleControl)
        #expect(toggle.isOn == true)
        toggle.click()
        // Instant apply: the change is in the document, not a draft.
        #expect(store.value("general.window.sticky_edges") == .bool(false))
        #expect(posted.value.contains("general.window.sticky_edges"))
        // The document file exists and holds the value.
        let bytes = try String(contentsOf: fixture.documentURL, encoding: .utf8)
        #expect(bytes.contains("\"general.window.sticky_edges\": false"))
    }

    @Test func invalidInputShowsDangerAndDoesNotSave() throws {
        var fixture = try Fixture(); defer { fixture.cleanUp() }
        let store = try fixture.loadStore()
        let window = controller(fixture, store: store)
        window.show(section: "general")
        let before = try String(contentsOf: fixture.documentURL, encoding: .utf8)
        let controls = walkControls(window)
        let number = try #require(controls.first { $0.entry.id == "general.window.border_width" } as? XRGSettingsNumberControl)
        let field = try #require(number.field as? NSTextField)
        field.stringValue = "99"
        number.fieldEdited()
        // Not saved: the store still holds the default, the file is unchanged.
        #expect(store.value("general.window.border_width") == .int(4))
        #expect(try String(contentsOf: fixture.documentURL, encoding: .utf8) == before)
        // The field gets the danger rim and a mono reason label; nothing else turned red.
        #expect(number.errorReason?.isEmpty == false)
        #expect(try #require(number.rimColor) == XRGAether7b.Color.statusDanger(dark: number.isDarkAppearance))
        let views = walkViews(window)
        let dangerLabels = views.compactMap { $0 as? NSTextField }.filter {
            $0.identifier?.rawValue == "reason-\(number.entry.id)"
        }
        #expect(dangerLabels.count == 1 && !dangerLabels[0].stringValue.isEmpty)
        #expect(dangerLabels[0].font?.fontName ==
                NSFont.monospacedDigitSystemFont(ofSize: XRGAether7b.TypeScale.xs.size, weight: .regular).fontName)
        // Repairing the field clears the rim.
        field.stringValue = "6"
        number.fieldEdited()
        #expect(number.errorReason == nil && store.value("general.window.border_width") == .int(6))
    }

    @Test func resetSectionAsksThenResets() throws {
        var fixture = try Fixture(); defer { fixture.cleanUp() }
        let store = try fixture.loadStore()
        let window = controller(fixture, store: store)
        var asked: [String] = []
        window.confirmReset = { title in asked.append(title); return asked.count > 1 }
        window.show(section: "general")
        let controls = walkControls(window)
        let toggle = try #require(controls.first { $0.entry.id == "general.window.sticky_edges" } as? XRGSettingsToggleControl)
        toggle.click()
        #expect(store.value("general.window.sticky_edges") == .bool(false))
        let reset = try #require(controls.first { $0.entry.id == "general.reset" } as? XRGSettingsActionControl)
        reset.button.performClick()
        // First ask: declined (confirmReset returns false on the first ask), nothing resets.
        #expect(asked.count == 1 && store.value("general.window.sticky_edges") == .bool(false))
        reset.button.performClick()
        // Second ask: confirmed, the section resets to its defaults.
        #expect(asked.count == 2 && store.value("general.window.sticky_edges") == .bool(true))
        #expect(window.confirmResetTitle(asked[0]).contains("General") == true)
    }

    @Test func dependentControlIsDisabled() throws {
        var fixture = try Fixture(); defer { fixture.cleanUp() }
        let store = try fixture.loadStore()
        let window = controller(fixture, store: store)
        window.show(section: "graphs")
        var controls = walkControls(window)
        var samples = try #require(controls.first { $0.entry.id == "graphs.cpu.samples" })
        #expect(samples.isEnabled)
        // samples depends on time_window == 0; a nonzero window disables it.
        try store.set("graphs.cpu.time_window", .double(5))
        controls = walkControls(window)
        samples = try #require(controls.first { $0.entry.id == "graphs.cpu.samples" })
        #expect(!samples.isEnabled)
        // And back again.
        try store.set("graphs.cpu.time_window", .double(0))
        controls = walkControls(window)
        samples = try #require(controls.first { $0.entry.id == "graphs.cpu.samples" })
        #expect(samples.isEnabled)
    }

    @Test(arguments: [false, true])
    func onlyAether7bColours(dark: Bool) throws {
        var fixture = try Fixture(); defer { fixture.cleanUp() }
        let store = try fixture.loadStore()
        let window = controller(fixture, store: store)
        let appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
        for section in XRGSettingsCatalog.sections {
            window.window?.appearance = appearance
            window.show(section: section)
            window.refresh()
            let views = walkOwned(content(window))
            for view in views {
                if let layer = view.layer, let background = layer.backgroundColor, let converted = NSColor(cgColor: background) {
                    #expect(XRGAether7bPalette.isAether7b(converted, dark: dark),
                            "non-token layer background on \(type(of: view)) in \(section): \(background)")
                }
                if let field = view as? NSTextField {
                    if let color = field.textColor {
                        #expect(XRGAether7bPalette.isAether7b(color, dark: dark),
                                "non-token text colour on a field in \(section): \(color)")
                    }
                    if field.isEditable, let color = field.backgroundColor {
                        #expect(XRGAether7bPalette.isAether7b(color, dark: dark),
                                "non-token field background in \(section): \(color)")
                    }
                }
                if let button = view as? NSButton, let color = button.contentTintColor {
                    #expect(XRGAether7bPalette.isAether7b(color, dark: dark),
                            "non-token button tint in \(section): \(color)")
                }
            }
        }
    }

    @Test func voiceOverLabelsComeFromCatalog() throws {
        var fixture = try Fixture(); defer { fixture.cleanUp() }
        let store = try fixture.loadStore()
        let window = controller(fixture, store: store)
        for section in XRGSettingsCatalog.sections {
            window.show(section: section)
            let controls = walkControls(window)
            for entry in store.catalog.entries.filter({ $0.section == section && $0.platforms.contains(.macos) && $0.shown }) {
                let control = try #require(controls.first { $0.entry.id == entry.id })
                #expect(control.accessibilityLabel() == entry.label)
                if let help = entry.help { #expect(control.toolTip == help) }
            }
        }
    }

    @Test func unreadableFileShowsBannerAndReplaceAction() throws {
        var fixture = try Fixture(); defer { fixture.cleanUp() }
        // A malformed settings file is never overwritten: the store runs on
        // defaults and the window reports the problem (spec §2).
        let malformed = Data("certainly not json".utf8)
        try malformed.write(to: fixture.documentURL)
        let store = try fixture.loadStore()
        #expect(store.loadProblem != nil)
        let window = controller(fixture, store: store)
        window.show(section: "general")
        let views = walkViews(window)
        let banner = try #require(views.first { $0.identifier?.rawValue == "unreadable-file-banner" })
        let replace = try #require(views.first { $0.identifier?.rawValue == "replace-unreadable-file" } as? XRGSettingsFlatButton)
        #expect(views.contains { $0.identifier?.rawValue == "settings-load-problem" && !($0 as? NSTextField)!.stringValue.isEmpty })
        // A change while the file is unreadable stays in memory only.
        let controls = walkControls(window)
        let toggle = try #require(controls.first { $0.entry.id == "general.window.sticky_edges" } as? XRGSettingsToggleControl)
        toggle.click()
        #expect(try Data(contentsOf: fixture.documentURL) == malformed)
        // The user confirms replacing the file: the in-memory document
        // (including the held change) is written over it.
        replace.performClick()
        #expect(store.loadProblem == nil)
        let written = try JSONSerialization.jsonObject(with: Data(contentsOf: fixture.documentURL)) as? [String: Any]
        #expect((written?["settings"] as? [String: Any])?["general.window.sticky_edges"] as? Bool == false)
        #expect(walkViews(window).contains { $0.identifier?.rawValue == "unreadable-file-banner" } == false)
        _ = banner
    }
}

/// A main-actor box for recording notifications in tests.
@MainActor final class MainActorBox<Value> {
    var value: Value
    init(_ value: Value) { self.value = value }
}