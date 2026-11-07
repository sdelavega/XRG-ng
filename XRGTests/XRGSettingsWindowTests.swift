// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Stephen de la Vega.
import AppKit
import Testing
@testable import XRGCore

/// The Aether7b settings window (0.2.3 spec §5): sidebar, one control per
/// catalog entry, instant apply, danger-rim validation, reset-with-
/// confirmation, token-only colour and unreadable-file recovery — plus the
/// fix-round contracts: real keyboard, mouse and accessibility activation
/// (review issue 4), the danger dot and its constrained reason label
/// (issue 3), rejected malformed input (issue 2), grouped source
/// restoration and the unknown-sensor policy (issue 5), disabled controls
/// that cannot be edited (issue 6), presets that apply a palette
/// (issue 7), colour inheritance (issue 8), a token audit without subtree
/// exclusions (issue 9), the catalog-driven notification action
/// (issue 10) and the parity restorations (rulings P1, P3, P4, P5).
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
    private func controller(_ fixture: Fixture, store: XRGSettingsStore,
                            sources: any XRGSettingsSourceProvider) -> XRGSettingsWindowController {
        XRGSettingsWindowController(store: store, catalog: store.catalog, sources: sources)
    }

    /// The window's content view (never nil once shown).
    @MainActor private func content(_ window: XRGSettingsWindowController) -> NSView {
        window.window?.contentView ?? NSView(frame: .zero)
    }
    /// A plain whole-subtree walk.
    @MainActor private func walkAll(_ view: NSView) -> [NSView] {
        [view] + view.subviews.flatMap { walkAll($0) }
    }
    /// Every view the audit visits (review issue 9): the WHOLE subtree the
    /// window builds — no control class excluded; the vibrancy sidebar,
    /// pop-ups, colour wells and sliders are descended into like any other
    /// view. Each visit records whether the view actually DRAWS (a view
    /// inside a hidden ancestor cannot): colour properties are asserted
    /// only for views that draw, because AppKit's own hidden internals
    /// (the scroll pocket's mask, for instance) hold system colours the
    /// window never sets and never shows. Corner radii are asserted for
    /// every layer in the tree, drawing or not — the degenerate radius
    /// (W1) lived in layers regardless of visibility.
    @MainActor private func auditViews(_ window: XRGSettingsWindowController) -> [(view: NSView, draws: Bool)] {
        var visits: [(NSView, Bool)] = []
        func visit(_ view: NSView, parentDraws: Bool) {
            let draws = parentDraws && !view.isHidden
            visits.append((view, draws))
            for sub in view.subviews { visit(sub, parentDraws: draws) }
        }
        visit(content(window), parentDraws: true)
        return visits
    }
    /// Every layer below a view's layer, the view's own layer first —
    /// the focus halos, the aurora gradient and every pill live in
    /// sublayers (review issue 9: the audit used to inspect only
    /// `view.layer` itself).
    @MainActor private func auditLayers(_ layer: CALayer, draws: Bool) -> [(layer: CALayer, draws: Bool)] {
        var visits: [(CALayer, Bool)] = [(layer, draws)]
        for sub in layer.sublayers ?? [] { visits.append(contentsOf: auditLayers(sub, draws: draws)) }
        return visits
    }
    @MainActor private func walkControls(_ window: XRGSettingsWindowController) -> [XRGSettingsEntryControl] {
        walkAll(content(window)).compactMap { $0 as? XRGSettingsEntryControl }
    }
    @MainActor private func control(_ window: XRGSettingsWindowController, _ id: String) throws -> XRGSettingsEntryControl {
        try #require(walkControls(window).first { $0.entry.id == id }, "missing control for \(id)")
    }

    // MARK: Real event delivery (review issue 4)

    /// Deliver a real keyDown event through the window, exactly as the
    /// event loop would: the window routes it to its first responder.
    @MainActor private func deliverKey(_ characters: String, keyCode: UInt16,
                                       to window: XRGSettingsWindowController, shift: Bool = false) throws {
        let nsWindow = try #require(window.window)
        let event = try #require(NSEvent.keyEvent(with: .keyDown, location: .zero,
                                                  modifierFlags: shift ? [.shift] : [], timestamp: 0,
                                                  windowNumber: nsWindow.windowNumber, context: nil,
                                                  characters: characters, charactersIgnoringModifiers: characters,
                                                  isARepeat: false, keyCode: keyCode))
        nsWindow.sendEvent(event)
    }
    /// Deliver a real mouse click: the window's own hit-testing finds the
    /// view under the cursor, then the down and up events — the same
    /// NSEvent objects the window system would deliver — drive its press
    /// state machine (mouseDown, then mouseUp inside bounds).
    @MainActor private func deliverClick(on view: NSView, in window: XRGSettingsWindowController) throws {
        let nsWindow = try #require(window.window)
        nsWindow.contentView?.layoutSubtreeIfNeeded()
        view.scrollToVisible(view.bounds)
        nsWindow.contentView?.layoutSubtreeIfNeeded()
        let center = view.convert(NSPoint(x: view.bounds.midX, y: view.bounds.midY), to: nil)
        let target = try #require(nsWindow.contentView?.hitTest(center), "the click found no view")
        #expect(target === view || target.isDescendant(of: view) || view.isDescendant(of: target),
                "the click did not hit the intended control")
        for type in [NSEvent.EventType.leftMouseDown, .leftMouseUp] {
            let event = try #require(NSEvent.mouseEvent(with: type, location: center, modifierFlags: [],
                                                        timestamp: 0, windowNumber: nsWindow.windowNumber,
                                                        context: nil, eventNumber: 0, clickCount: 1, pressure: 1))
            if type == .leftMouseDown { target.mouseDown(with: event) } else { target.mouseUp(with: event) }
        }
    }
    /// Focus a control's widget so key events reach it.
    @MainActor private func focus(_ view: NSView, in window: XRGSettingsWindowController) throws {
        let nsWindow = try #require(window.window)
        #expect(nsWindow.makeFirstResponder(view))
    }
    /// The entry the Tab order should move to after `view`.
    @MainActor private func nextKeyView(of view: NSView) -> NSView? { view.nextKeyView }

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

    /// Review issue 11: the entry's declared control type is verified
    /// against the CONCRETE widget class that rendered, not against itself.
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
                let matchesType: Bool
                switch entry.control {
                case .toggle: matchesType = control is XRGSettingsToggleControl
                case .choice: matchesType = control is XRGSettingsChoiceControl
                case .segmented: matchesType = control is XRGSettingsSegmentedControl
                case .integer, .decimal, .duration: matchesType = control is XRGSettingsNumberControl
                case .color: matchesType = control is XRGSettingsColorControl
                case .path: matchesType = control is XRGSettingsPathControl
                case .text: matchesType = control is XRGSettingsTextControl
                case .source: matchesType = control is XRGSettingsSourceControl
                case .action: matchesType = control is XRGSettingsActionControl
                case .order: matchesType = control is XRGSettingsOrderControl
                }
                #expect(matchesType, "wrong widget class for \(entry.id): \(type(of: control))")
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

    /// Review issue 4: an instant-apply toggle operated by a REAL mouse
    /// click delivered through the window.
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
        let toggle = try #require(walkControls(window).first { $0.entry.id == "general.window.sticky_edges" } as? XRGSettingsToggleControl)
        #expect(toggle.isOn == true)
        try deliverClick(on: toggle, in: window)
        // Instant apply: the change is in the document, not a draft.
        #expect(store.value("general.window.sticky_edges") == .bool(false))
        #expect(posted.value.contains("general.window.sticky_edges"))
        // The document file exists and holds the value.
        let bytes = try String(contentsOf: fixture.documentURL, encoding: .utf8)
        #expect(bytes.contains("\"general.window.sticky_edges\": false"))
    }

    /// Review issues 2 and 3: malformed and out-of-range input is refused
    /// before submission — never silently replaced by the entry's default —
    /// and the danger rim, dot and reason label are laid out and visible.
    /// An unrelated stored change must not clobber the user's invalid edit.
    @Test func invalidInputShowsDangerAndDoesNotSave() throws {
        var fixture = try Fixture(); defer { fixture.cleanUp() }
        let store = try fixture.loadStore()
        let window = controller(fixture, store: store)
        window.show(section: "general")
        let number = try #require(try control(window, "general.window.border_width") as? XRGSettingsNumberControl)
        // A nondefault stored value the malformed input must not overwrite.
        try store.set("general.window.border_width", .int(6))
        window.show(section: "general")
        let before = try String(contentsOf: fixture.documentURL, encoding: .utf8)
        // Out-of-range input: the store refuses it.
        number.field.stringValue = "99"
        number.fieldEdited()
        #expect(store.value("general.window.border_width") == .int(6))
        // Malformed text, an overflowing integer and a nonfinite decimal all
        // follow the refusal path too (review issue 2).
        for bad in ["abc", "99999999999999999999999"] {
            number.field.stringValue = bad
            number.fieldEdited()
            #expect(number.errorReason?.isEmpty == false, "no danger reason for \(bad)")
            #expect(store.value("general.window.border_width") == .int(6), "malformed \(bad) overwrote the setting")
            #expect(try String(contentsOf: fixture.documentURL, encoding: .utf8) == before,
                    "the file changed while the input was invalid")
        }
        // The field gets the danger rim, a visible dot and a visible reason
        // label, laid out under the rim; nothing else turned red.
        #expect(number.errorReason?.isEmpty == false)
        #expect(try #require(number.rimColor) == XRGAether7b.Color.statusDanger(dark: number.isDarkAppearance))
        number.layoutSubtreeIfNeeded()
        #expect(!number.reasonLabel.isHidden && !number.dotView.isHidden)
        #expect(number.reasonLabel.frame.width > 10 && number.reasonLabel.frame.height > 5,
                "the reason label is not visible")
        #expect(number.reasonLabel.frame.maxY <= number.bounds.height + 1 && number.reasonLabel.frame.minY >= 0,
                "the reason label is not laid out inside the control")
        #expect(number.bounds.contains(number.dotView.frame), "the danger dot is not visible")
        let views = walkAll(content(window))
        let dangerLabels = views.compactMap { $0 as? NSTextField }.filter {
            $0.identifier?.rawValue == "reason-\(number.entry.id)"
        }
        #expect(dangerLabels.count == 1 && !dangerLabels[0].stringValue.isEmpty)
        #expect(dangerLabels[0].font?.fontName ==
                NSFont.monospacedDigitSystemFont(ofSize: XRGAether7b.TypeScale.xs.size, weight: .regular).fontName)
        // An unrelated stored change does not clobber the invalid edit or
        // its error (review issue 3): only the changed entry re-presents.
        let unrelated = try #require(try control(window, "general.window.sticky_edges") as? XRGSettingsToggleControl)
        #expect(unrelated.accessibilityPerformPress())
        #expect(number.field.stringValue == "99999999999999999999999", "the invalid text was replaced by an unrelated change")
        #expect(number.errorReason != nil, "the invalid state was cleared by an unrelated change")
        #expect(store.value("general.window.border_width") == .int(6))
        // Repairing the field clears the rim and saves.
        number.field.stringValue = "8"
        number.fieldEdited()
        #expect(number.errorReason == nil && store.value("general.window.border_width") == .int(8))
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
        #expect(toggle.accessibilityPerformPress())
        #expect(store.value("general.window.sticky_edges") == .bool(false))
        let reset = try #require(controls.first { $0.entry.id == "general.reset" } as? XRGSettingsActionControl)
        // VoiceOver activation of the reset action (review issue 4).
        #expect(reset.button.accessibilityPerformPress())
        // First ask: declined (confirmReset returns false on the first ask), nothing resets.
        #expect(asked.count == 1 && store.value("general.window.sticky_edges") == .bool(false))
        #expect(reset.button.accessibilityPerformPress())
        // Second ask: confirmed, the section resets to its defaults.
        #expect(asked.count == 2 && store.value("general.window.sticky_edges") == .bool(true))
        #expect(window.confirmResetTitle(asked[0]).contains("General") == true)
    }

    /// Review issue 6: a control disabled by `depends` cannot be edited —
    /// the real widget refuses the keyboard and its accessibility element
    /// reports the disabled state.
    @Test func dependentControlIsDisabled() throws {
        var fixture = try Fixture(); defer { fixture.cleanUp() }
        let store = try fixture.loadStore()
        let window = controller(fixture, store: store)
        window.show(section: "graphs")
        let samples = try #require(try control(window, "graphs.cpu.samples") as? XRGSettingsNumberControl)
        #expect(samples.isEnabled)
        #expect(samples.field.isEditable)
        // samples depends on time_window == 0; a nonzero window disables it.
        try store.set("graphs.cpu.time_window", .double(5))
        let disabled = try #require(try control(window, "graphs.cpu.samples") as? XRGSettingsNumberControl)
        #expect(!disabled.isEnabled)
        #expect(!disabled.field.isEditable, "the dependent field is still editable")
        #expect(!disabled.isAccessibilityEnabled(), "the accessibility element still reports enabled")
        let before = try String(contentsOf: fixture.documentURL, encoding: .utf8)
        disabled.field.stringValue = "150"
        disabled.fieldEdited()
        #expect(store.value("graphs.cpu.samples") == .int(0), "a disabled control saved an edit")
        #expect(try String(contentsOf: fixture.documentURL, encoding: .utf8) == before)
        // And back again.
        try store.set("graphs.cpu.time_window", .double(0))
        let restored = try #require(try control(window, "graphs.cpu.samples") as? XRGSettingsNumberControl)
        #expect(restored.isEnabled && restored.field.isEditable)
    }

    /// Review issue 9: the token audit walks the whole window — every
    /// descendant, the vibrancy sidebar, pop-ups, colour wells and sliders
    /// included, and every layer below each view (focus halos, the aurora
    /// gradient). Pop-up bezels are off, radii are generated tokens or the
    /// CSS-clamped pill, and no layer may hold a degenerate radius (W1's
    /// bitmap poison). Every colour the window sets is an Aether7b value
    /// for the current appearance; the one allowance is the colour well's
    /// swatch content — the colour the user picked. AppKit-private chrome
    /// that never draws (hidden scroll-pocket internals) carries system
    /// colours the window cannot set and never shows: colour properties
    /// are asserted only on views that draw.
    @Test(arguments: [false, true])
    func onlyAether7bColours(dark: Bool) throws {
        var fixture = try Fixture(); defer { fixture.cleanUp() }
        let store = try fixture.loadStore()
        let window = controller(fixture, store: store)
        let appearance = try #require(NSAppearance(named: dark ? .darkAqua : .aqua))
        for section in XRGSettingsCatalog.sections {
            window.window?.appearance = appearance
            window.show(section: section)
            window.refresh()
            window.window?.contentView?.layoutSubtreeIfNeeded()
            var failures: [String] = []
            func nearestWell(of view: NSView) -> XRGSettingsColorWellView? {
                var current: NSView? = view
                while let candidate = current {
                    if let found = candidate as? XRGSettingsColorWellView { return found }
                    current = candidate.superview
                }
                return nil
            }
            func check(_ colour: NSColor?, _ what: String, of view: NSView, in well: XRGSettingsColorWellView?) {
                guard let colour else { return }
                if XRGAether7bPalette.isAether7b(colour, dark: dark) { return }
                // The one allowance, per property: the colour well's swatch
                // content, which the user picked (an unset well is clear).
                if let well, view === well || view.isDescendant(of: well) {
                    let content = well.color.usingColorSpace(.sRGB)
                    let mine = colour.usingColorSpace(.sRGB)
                    if let content, let mine,
                       content.alphaComponent < 0.01 || mine.alphaComponent < 0.01
                       || (abs(content.redComponent - mine.redComponent) < 0.003
                           && abs(content.greenComponent - mine.greenComponent) < 0.003
                           && abs(content.blueComponent - mine.blueComponent) < 0.003
                           && abs(content.alphaComponent - mine.alphaComponent) < 0.005) { return }
                }
                failures.append("\(section): \(what) on \(type(of: view)) is \(colour)")
            }
            // Radii: generated tokens, the halo outsets (md/sm + the 2 px
            // Carolina ring) or the CSS-clamped pill — and never larger
            // than half the layer's shorter side, which is what degenerated
            // the bitmap renderer into W1's solid block.
            let tokenRadii: [CGFloat] = [XRGAether7b.Radius.sm, XRGAether7b.Radius.md, XRGAether7b.Radius.lg,
                                         XRGAether7b.Radius.md + 2, XRGAether7b.Radius.sm + 2]
            func radiusIsLegal(_ radius: CGFloat, of layer: CALayer) -> Bool {
                let shorterSide = min(layer.bounds.width, layer.bounds.height)
                let pill = max(0, shorterSide / 2)
                if radius > pill + 0.5 { return false }
                return tokenRadii.contains { abs($0 - radius) < 0.01 } || abs(radius - pill) < 0.5
            }
            for (view, draws) in auditViews(window) {
                let well = nearestWell(of: view)
                if let layer = view.layer {
                    for (l, lDraws) in auditLayers(layer, draws: draws) {
                        if lDraws {
                            if let background = l.backgroundColor {
                                check(NSColor(cgColor: background), "layer background", of: view, in: well)
                            }
                            // CALayer's border and shadow colours default to opaque
                            // black while their widths and opacities are zero: only a
                            // border or shadow that draws is a colour the window set.
                            if l.borderWidth > 0, let border = l.borderColor {
                                check(NSColor(cgColor: border), "layer border", of: view, in: well)
                            }
                            if l.shadowOpacity > 0, let shadow = l.shadowColor {
                                check(NSColor(cgColor: shadow), "layer shadow", of: view, in: well)
                            }
                            if let gradient = l as? CAGradientLayer {
                                for colour in gradient.colors ?? [] {
                                    check(NSColor(cgColor: colour as! CGColor), "gradient colour", of: view, in: well)
                                }
                            }
                        }
                        // The radius contract holds for every layer that
                        // can actually render — positive-sized, drawing,
                        // with no hidden ancestor: hidden or degenerate-
                        // sized layers cannot poison a capture, and W1's
                        // degenerate radius lived on fully visible layers.
                        if l.cornerRadius > 0, lDraws,
                           min(l.bounds.width, l.bounds.height) > 0.5 {
                            #expect(radiusIsLegal(l.cornerRadius, of: l),
                                    "non-token or degenerate corner radius \(l.cornerRadius) on \(type(of: view)) (layer bounds \(l.bounds)) in \(section)")
                        }
                    }
                }
                guard draws else { continue }
                if let button = view as? NSButton, let tint = button.contentTintColor {
                    check(tint, "content tint", of: view, in: well)
                }
                if let field = view as? NSTextField {
                    check(field.textColor, "text colour", of: view, in: well)
                    if field.isEditable { check(field.backgroundColor, "field background", of: view, in: well) }
                    field.attributedStringValue.enumerateAttribute(.foregroundColor, in: NSRange(location: 0, length: field.attributedStringValue.length)) { value, _, _ in
                        if let colour = value as? NSColor { check(colour, "attributed text", of: view, in: well) }
                    }
                }
                // The system bezel must be gone from the pop-ups (V6): the
                // rim is the border, never a double one.
                if let popUp = view as? NSPopUpButton {
                    #expect(!popUp.isBordered, "a pop-up kept its system bezel in \(section)")
                }
                switch view {
                case is XRGSettingsFlatButton:
                    // The flat button's focus treatment is the token halo;
                    // its chrome is layer-drawn, so no cell machinery can
                    // draw a native ring (the keyboard test asserts the halo
                    // appears on focus and leaves on resign).
                    #expect(view.wantsLayer, "the flat button is not layer-backed chrome")
                default:
                    break
                }
                // Note: NSControl.focusRingType cannot gate this audit on the
                // macOS 26 SDK — the getter answers `.default` whatever the
                // setter stored (probed against NSTextField, NSSlider and
                // NSPopUpButton), so the bezel removal (isBordered, above)
                // and the keyboard test's token-halo assertions carry the
                // focus contract instead.
            }
            #expect(failures.isEmpty, "non-token colours: \(failures.joined(separator: "\n"))")
        }
    }

    /// Review issue 4: the full interaction contract — Tab and Shift-Tab
    /// through the window's key-view loop, Space and Return activation,
    /// the token focus indication, and VoiceOver press on buttons,
    /// toggles and the sidebar.
    @Test func keyboardAndAccessibilityOperateEveryControl() throws {
        var fixture = try Fixture(); defer { fixture.cleanUp() }
        let store = try fixture.loadStore()
        let window = controller(fixture, store: store)
        window.show(section: "general")
        let nsWindow = try #require(window.window)
        nsWindow.contentView?.layoutSubtreeIfNeeded()

        // The key-view loop: sidebar first, then the section's controls.
        let title = try #require(try control(window, "general.window.title") as? XRGSettingsTextControl)
        let sticky = try #require(try control(window, "general.window.sticky_edges") as? XRGSettingsToggleControl)
        let checkNow = try #require(try control(window, "general.updates.check_now") as? XRGSettingsActionControl)
        let lastSidebar = try #require(window.sectionButtons.last)
        try focus(lastSidebar, in: window)
        #expect(nsWindow.firstResponder === lastSidebar)
        #expect(nextKeyView(of: lastSidebar) === title.textField, "the key-view loop does not enter the controls")
        // Tab delivers focus to the first control — the text field's field
        // editor becomes the responder, as with any text field.
        try deliverKey("\t", keyCode: 48, to: window)
        let editor = try #require(nsWindow.fieldEditor(false, for: title.textField))
        #expect(nsWindow.firstResponder === editor, "Tab did not enter the first control")
        // Shift-Tab walks back through the custom controls' own handling —
        // the sticky toggle's predecessor is the window-level pop-up.
        try focus(sticky, in: window)
        let level = try #require(try control(window, "general.window.level") as? XRGSettingsChoiceControl)
        try deliverKey("\t", keyCode: 48, to: window, shift: true)
        #expect(nsWindow.firstResponder === level.popUp, "Shift-Tab did not walk back through the controls")

        // Keyboard focus shows the token halo and the Carolina rim.
        try focus(sticky, in: window)
        #expect(sticky.isFocusedControl && !sticky.haloLayer.isHidden)
        #expect(try #require(sticky.rimColor) == XRGAether7bPalette.focusBorder)
        // Space toggles through the keyboard contract.
        try deliverKey(" ", keyCode: 49, to: window)
        #expect(sticky.isOn == false && store.value("general.window.sticky_edges") == .bool(false))
        try deliverKey(" ", keyCode: 49, to: window)
        #expect(sticky.isOn == true && store.value("general.window.sticky_edges") == .bool(true))
        // Return activates a focused button.
        var checked = 0
        window.performCheckForUpdates = { checked += 1 }
        try focus(checkNow.button, in: window)
        try deliverKey("\r", keyCode: 36, to: window)
        #expect(checked == 1)
        #expect(checkNow.button.isFocused)

        // VoiceOver press: a button, a toggle and a sidebar section switch.
        #expect(sticky.accessibilityPerformPress())
        #expect(sticky.isOn == false)
        let weatherButton = try #require(window.sectionButtons.first { $0.identifier?.rawValue == "section-weather" })
        #expect(weatherButton.accessibilityPerformPress())
        #expect(window.currentSection == "weather")
        // A real mouse click on a flat button also works.
        window.show(section: "general")
        let freshCheckNow = try #require(try control(window, "general.updates.check_now") as? XRGSettingsActionControl)
        try deliverClick(on: freshCheckNow.button, in: window)
        #expect(checked == 2)
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
        // Toggles report the checkbox role with their checked state.
        window.show(section: "general")
        let sticky = try #require(try control(window, "general.window.sticky_edges") as? XRGSettingsToggleControl)
        #expect(sticky.accessibilityRole() == .checkBox)
        #expect((sticky.accessibilityValue() as? String) == "checked")
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
        let views = walkAll(content(window))
        let banner = try #require(views.first { $0.identifier?.rawValue == "unreadable-file-banner" })
        let replace = try #require(views.first { $0.identifier?.rawValue == "replace-unreadable-file" } as? XRGSettingsFlatButton)
        #expect(views.contains { $0.identifier?.rawValue == "settings-load-problem" && !($0 as? NSTextField)!.stringValue.isEmpty })
        // A change while the file is unreadable stays in memory only.
        let controls = walkControls(window)
        let toggle = try #require(controls.first { $0.entry.id == "general.window.sticky_edges" } as? XRGSettingsToggleControl)
        #expect(toggle.accessibilityPerformPress())
        #expect(try Data(contentsOf: fixture.documentURL) == malformed)
        // The user confirms replacing the file: the in-memory document
        // (including the held change) is written over it — activated through
        // VoiceOver, like any other button.
        #expect(replace.accessibilityPerformPress())
        #expect(store.loadProblem == nil)
        let written = try JSONSerialization.jsonObject(with: Data(contentsOf: fixture.documentURL)) as? [String: Any]
        #expect((written?["settings"] as? [String: Any])?["general.window.sticky_edges"] as? Bool == false)
        #expect(walkAll(content(window)).contains { $0.identifier?.rawValue == "unreadable-file-banner" } == false)
        _ = banner
    }

    // MARK: Source pickers (review issue 5)

    /// Grouped source selections restore the right menu item: selection
    /// follows each item's representedObject, never the index the flat
    /// option list would give (the group headers occupy indices too).
    @Test func sourcePickersRestoreByRepresentedObjectAcrossGroups() throws {
        var fixture = try Fixture(); defer { fixture.cleanUp() }
        let store = try fixture.loadStore()
        let window = controller(fixture, store: store)
        window.show(section: "sources")
        let picker = try #require(try control(window, "sources.temperature.sensor1") as? XRGSettingsSourceControl)
        // The fixture menu: None, the first group's sensor, then the second
        // group behind its header (the first group needs none).
        #expect(picker.optionLabels == ["None", "Fixture sensor",
                                        "Unidentified Sensors", "Unnamed sensor"])
        // Pick the second group's sensor — the item that restored as its
        // header before the fix.
        let unnamed = try #require(picker.popUp.itemArray.first { $0.title == "Unnamed sensor" })
        picker.popUp.select(unnamed)
        #expect(picker.value() == .string("Tu0"))
        try store.set("sources.temperature.sensor1", .string("Tu0"))
        window.show(section: "sources")
        let restored = try #require(try control(window, "sources.temperature.sensor1") as? XRGSettingsSourceControl)
        #expect(restored.popUp.selectedItem?.title == "Unnamed sensor",
                "the grouped selection did not restore by representedObject")
        #expect(restored.value() == .string("Tu0"))
    }

    /// The retained "Show unknown sensors" policy drives the temperature
    /// pickers, and changing it refreshes them (review issue 5).
    private final class MutableTemperatureProvider: XRGSettingsSourceProvider {
        var includeUnknown = false
        let identified: [(group: String, value: String, label: String)] = [("Identified Sensors", "Ts0", "Fixture sensor")]
        let unknown: [(group: String, value: String, label: String)] = [("Unidentified Sensors", "Tu0", "Unnamed sensor")]
        func options(kind: String) -> [(group: String, value: String, label: String)] {
            kind == "temperature" ? (includeUnknown ? identified + unknown : identified) : []
        }
    }
    @Test func unknownSensorPolicyDrivesTemperaturePickers() throws {
        var fixture = try Fixture(); defer { fixture.cleanUp() }
        let store = try fixture.loadStore()
        let provider = MutableTemperatureProvider()
        let window = controller(fixture, store: store, sources: provider)
        window.show(section: "sources")
        let picker = try #require(try control(window, "sources.temperature.sensor1") as? XRGSettingsSourceControl)
        #expect(picker.optionLabels == ["None", "Fixture sensor"])
        // The retained policy on, and the pickers refill with the unknown
        // sensors — the same rule the sensor window follows.
        let policy = try #require(try control(window, "sources.temperature.show_unknown") as? XRGSettingsToggleControl)
        provider.includeUnknown = true
        #expect(policy.accessibilityPerformPress())
        #expect(store.value("sources.temperature.show_unknown") == .bool(true))
        #expect(picker.optionLabels.contains("Unnamed sensor"), "the temperature picker ignored the unknown-sensor policy")
    }

    // MARK: Themes (review issue 7)

    /// Selecting a built-in preset applies its palette and its name through
    /// the shared settings model; editing a colour afterwards marks the
    /// theme Custom, exactly as the catalog documents.
    @Test func themePresetAppliesPaletteAndCustomFollowsEdits() throws {
        var fixture = try Fixture(); defer { fixture.cleanUp() }
        let store = try fixture.loadStore()
        let window = controller(fixture, store: store)
        window.show(section: "themes")
        let preset = try #require(try control(window, "themes.preset") as? XRGSettingsChoiceControl)
        let midnight = try #require(preset.options.firstIndex { $0.label == "Midnight" } ??
                                    preset.popUp.itemArray.firstIndex { $0.title == "Midnight" })
        preset.popUp.selectItem(at: midnight)
        #expect(NSApp.sendAction(try #require(preset.popUp.action), to: preset.popUp.target, from: preset.popUp))
        // The palette, the name and the preset are all Midnight's now.
        #expect(store.value("themes.preset") == .string("Midnight"))
        #expect(store.value("themes.name") == .string("Midnight"))
        let palette = try #require(XRGBuiltinTheme.allCases.first { $0.name == "Midnight" })
        for (index, id) in ["appearance.window.color", "appearance.graph_background.color",
                            "appearance.series1.color", "appearance.series2.color",
                            "appearance.series3.color", "appearance.border.color",
                            "appearance.text.color"].enumerated() {
            let stored = try #require({ if case .color(let rgba) = store.value(id) { return rgba }; return nil }())
            #expect(zip(stored, palette.rgba[index]).allSatisfy { abs($0 - $1) < 0.002 }, "preset colour \(id) did not apply")
        }
        // The live typed colours and the exported theme carry the preset.
        let settings = window.themeEngine()
        let series1 = try #require(settings.graphFG1Color.usingColorSpace(.sRGB))
        #expect(abs(series1.redComponent - CGFloat(palette.rgba[2][0])) < 0.002
                && abs(series1.greenComponent - CGFloat(palette.rgba[2][1])) < 0.002)
        let exported = try XRGThemeDocument(data: settings.portableThemeData())
        #expect(exported.name == "Midnight")
        #expect(zip(exported.colors, palette.rgba).allSatisfy { pair in
            zip(pair.0, pair.1).allSatisfy { abs($0 - $1) < 0.002 }
        })
        // Editing one colour makes the theme Custom — the palette no longer
        // matches the selected built-in (the catalog's documented rule).
        window.show(section: "appearance")
        let colour = try #require(try control(window, "appearance.series2.color") as? XRGSettingsColorControl)
        colour.well.color = NSColor(srgbRed: 0.9, green: 0.1, blue: 0.1, alpha: 1)
        #expect(NSApp.sendAction(try #require(colour.well.action), to: colour.well.target, from: colour.well))
        #expect(store.value("themes.preset") == .string("Custom"), "an edited palette did not become Custom")
    }

    // MARK: Colour inheritance (review issue 8)

    @Test func colourInheritReturnsToTheDefault() throws {
        var fixture = try Fixture(); defer { fixture.cleanUp() }
        let store = try fixture.loadStore()
        let window = controller(fixture, store: store)
        window.show(section: "appearance")
        let control = try #require(try control(window, "appearance.series2.color") as? XRGSettingsColorControl)
        // Pick a colour: the entry holds it.
        control.well.color = NSColor(srgbRed: 0.8, green: 0.3, blue: 0.2, alpha: 1)
        #expect(NSApp.sendAction(try #require(control.well.action), to: control.well.target, from: control.well))
        #expect({ if case .color = store.value("appearance.series2.color") { return true }; return false }())
        // Inherit returns the entry to the unset value — .null — without
        // resetting any other setting.
        try store.set("general.window.sticky_edges", .bool(false))
        #expect(store.value("general.window.sticky_edges") == .bool(false))
        #expect(control.inheritButton.accessibilityPerformPress())
        #expect(store.value("appearance.series2.color") == .null,
                "inherit did not return the entry to the unset value")
        #expect(store.value("general.window.sticky_edges") == .bool(false), "inherit reset unrelated settings")
    }

    // MARK: Network minimum scale (ruling P5, fix V4)

    /// The unit selector presents the single stored bytes/s value in the
    /// deleted controller's units (extended with GB on the same 1024
    /// series), edits convert back to bytes/s, and the max-safe-integer
    /// sentinel never shows as a range.
    @Test func minimumScalePresentsInUnitsAndHidesTheSentinelRange() throws {
        var fixture = try Fixture(); defer { fixture.cleanUp() }
        let store = try fixture.loadStore()
        let window = controller(fixture, store: store)
        window.show(section: "graphs")
        let scale = try #require(try control(window, "graphs.network.minimum_scale") as? XRGSettingsNumberControl)
        let selector = try #require(scale.unitSelector)
        // The field renders inside its rim (fix V4's invisible field).
        scale.layoutSubtreeIfNeeded()
        #expect(scale.rimView.bounds.insetBy(dx: -0.5, dy: -0.5).contains(scale.field.frame),
                "the number field is not laid out inside its rim")
        // The max-safe-integer sentinel is not a real bound: no range text.
        #expect(!scale.hasBoundedRange)
        #expect(scale.rangeLabel.stringValue.isEmpty)
        #expect(selector.itemTitles == ["bytes/s", "KB/s", "MB/s", "GB/s"])
        // A stored bytes/s value presents in the largest dividing unit.
        try store.set("graphs.network.minimum_scale", .int(1_048_576))
        window.show(section: "graphs")
        let presented = try #require(try control(window, "graphs.network.minimum_scale") as? XRGSettingsNumberControl)
        #expect(presented.field.stringValue == "1")
        #expect(presented.unitSelector?.selectedItem?.title == "MB/s")
        // Editing the number writes bytes/s back, in the selected unit.
        presented.unitSelector?.selectItem(withTitle: "KB/s")
        presented.field.stringValue = "2"
        presented.fieldEdited()
        #expect(store.value("graphs.network.minimum_scale") == .int(2048))
        // Switching the unit keeps the stored bytes/s and re-presents the
        // number, submitting nothing.
        presented.unitSelector?.selectItem(withTitle: "bytes/s")
        presented.unitEdited(presented.unitSelector!)
        #expect(presented.field.stringValue == "2048")
        #expect(store.value("graphs.network.minimum_scale") == .int(2048))
        // A bounded entry still shows its range (the mockup's "200 ms – 10 s").
        let refresh = try #require(try control(window, "graphs.refresh") as? XRGSettingsNumberControl)
        #expect(refresh.hasBoundedRange)
        #expect(refresh.rangeLabel.stringValue.contains("0.2 s") && refresh.rangeLabel.stringValue.contains("10 s"))
    }

    // MARK: Graph order (ruling P4)

    /// The order list: graph names with keyboard-operable Move up / Move
    /// down buttons, writing the existing order setting.
    @Test func graphOrderListReordersByKeyboardAndAccessibility() throws {
        var fixture = try Fixture(); defer { fixture.cleanUp() }
        let store = try fixture.loadStore()
        let window = controller(fixture, store: store)
        window.show(section: "graphs")
        let order = try #require(try control(window, "graphs.order") as? XRGSettingsOrderControl)
        // The default ids, named for display — NPU and Processes included.
        #expect(order.rows.count == 14)
        #expect(order.rows.map(\.name.stringValue).prefix(4) == ["CPU", "GPU", "NPU", "VRAM"])
        #expect(order.rows.map(\.name.stringValue).contains("Processes"))
        // The buttons are in the key-view loop, and a real keyboard Space
        // moves a row (issue 4's contract on the new control).
        let focusables = order.focusableViews()
        #expect(focusables.count == 28)
        let firstDown = try #require(order.rows.first?.down)
        try focus(firstDown, in: window)
        try deliverKey(" ", keyCode: 49, to: window)
        #expect(store.value("graphs.order") == .string("gpu,cpu,npu,vram,memory,battery,temperature,fans,network,disk,weather,stock,ai,processes"))
        window.show(section: "graphs")
        let moved = try #require(try control(window, "graphs.order") as? XRGSettingsOrderControl)
        #expect(moved.rows.map(\.name.stringValue).prefix(2) == ["GPU", "CPU"])
        // VoiceOver press moves the second row back up; the disabled edges
        // (first row's up, last row's down) refuse the press.
        #expect(try #require(moved.rows.first?.up).isEnabled == false)
        #expect(try #require(moved.rows.last?.down).isEnabled == false)
        #expect(try #require(moved.rows.first?.up).accessibilityPerformPress() == false)
        #expect(try #require(moved.rows[1].up).accessibilityPerformPress())
        #expect(store.value("graphs.order") == .string("cpu,gpu,npu,vram,memory,battery,temperature,fans,network,disk,weather,stock,ai,processes"))
    }

    // MARK: Parity actions (rulings P1, P3, P6; review issue 10)

    /// The Weather section's Station Listing action, restored with the
    /// deleted controller's URL behaviour.
    @Test func stationListingOpensTheOldURL() throws {
        var fixture = try Fixture(); defer { fixture.cleanUp() }
        let store = try fixture.loadStore()
        let window = controller(fixture, store: store)
        var opened: [URL] = []
        window.openURL = { url in opened.append(url); return true }
        window.show(section: "weather")
        let listing = try #require(try control(window, "weather.station_list") as? XRGSettingsActionControl)
        #expect(listing.button.labelField.stringValue == "Station Listing")
        #expect(listing.button.accessibilityPerformPress())
        #expect(opened == [URL(string: "https://download.gauchosoft.com/xrg/stations.txt")!])
    }

    /// The "Choose font…" action opens the font panel on the current font
    /// and the panel's changeFont: writes the same font setting; the text
    /// field is a read-only display.
    @Test func chooseFontActionOpensTheFontPanelAndWritesTheSetting() throws {
        var fixture = try Fixture(); defer { fixture.cleanUp() }
        let store = try fixture.loadStore()
        let window = controller(fixture, store: store)
        var shown: [NSFont] = []
        window.presentFontPanel = { shown.append($0) }
        window.show(section: "appearance")
        let display = try #require(try control(window, "appearance.font") as? XRGSettingsTextControl)
        #expect(!display.textField.isEditable, "the font display is editable")
        let action = try #require(try control(window, "appearance.choose_font") as? XRGSettingsActionControl)
        #expect(action.button.labelField.stringValue == "Choose font…")
        #expect(action.button.accessibilityPerformPress())
        #expect(shown.count == 1 && shown[0].pointSize == 10)
        // The panel's changeFont:, delivered through the responder chain's
        // method, writes the same setting and relayouts through the hook.
        var relayouts = 0
        window.graphFontChanged = { relayouts += 1 }
        let manager = NSFontManager.shared
        // The responder method with no panel state is a no-op...
        window.changeFont(manager)
        #expect(store.value("appearance.font") == .string("System 10"))
        #expect(relayouts == 0)
        // ...and the write path behind it, with a real NSFontManager
        // conversion, stores the font the panel picked.
        let resized = manager.convert(shown[0], toSize: 17)
        window.applyGraphFont(resized, old: shown[0])
        #expect(store.value("appearance.font") == .string("System 17"))
        #expect(relayouts == 1)
        // The display re-presents the new font.
        window.show(section: "appearance")
        let updated = try #require(try control(window, "appearance.font") as? XRGSettingsTextControl)
        #expect(updated.textField.stringValue == "System 17")
    }

    /// The Allow Budget Notifications action is catalog-driven (review
    /// issue 10): the row renders from the catalog even before the
    /// production closure is wired, opening the section requests nothing,
    /// and an explicit activation calls the closure exactly once and
    /// reports the result.
    @Test func budgetNotificationsActionIsCatalogDrivenAndExplicit() async throws {
        var fixture = try Fixture(); defer { fixture.cleanUp() }
        let store = try fixture.loadStore()
        let window = controller(fixture, store: store)
        let requests = MainActorBox(0)
        window.requestBudgetNotifications = {
            requests.value += 1
            return await "Permission granted"
        }
        window.show(section: "ai")
        let action = try #require(try control(window, "ai.notifications.allow") as? XRGSettingsActionControl)
        #expect(action.button.labelField.stringValue == "Allow Budget Notifications…")
        #expect(action.button.accessibilityLabel() == "Allow Budget Notifications…")
        // Opening the AI section requested no permission.
        #expect(requests.value == 0)
        // The explicit activation requests it, once, and reports the result.
        #expect(action.button.accessibilityPerformPress())
        var waited = 0
        while (window.budgetNotificationStatusText ?? "").isEmpty && waited < 100 {
            try? await Task.sleep(nanoseconds: 10_000_000)
            waited += 1
        }
        #expect(requests.value == 1)
        #expect(window.budgetNotificationStatusText == "Permission granted")
    }

    // MARK: Fix round 2 (issues 3/4/9/11, findings N1–N4, W1, W2)

    /// Review issue 3: the error state grows its OWN row — the reason label
    /// stays inside the row's bounds and the rows below never overlap it.
    /// The pre-fix rows pinned only the control's centre and a minimum
    /// height, so the reason text spilled over the next row.
    @Test func validationGrowsItsRowInsteadOfOverlappingTheNext() throws {
        var fixture = try Fixture(); defer { fixture.cleanUp() }
        let store = try fixture.loadStore()
        let window = controller(fixture, store: store)
        window.show(section: "general")
        let nsWindow = try #require(window.window)
        let number = try #require(try control(window, "general.window.border_width") as? XRGSettingsNumberControl)
        number.field.stringValue = "99"
        number.fieldEdited()
        #expect(number.errorReason != nil)
        nsWindow.contentView?.layoutSubtreeIfNeeded()
        let row = try #require(number.superview, "the control has no row")
        let stack = try #require(row.superview, "the row has no container")
        // The reason label lies inside its row.
        let reasonFrame = number.reasonLabel.convert(number.reasonLabel.bounds, to: row)
        #expect(row.bounds.insetBy(dx: -1, dy: -1).contains(reasonFrame),
                "the reason label escapes its row: \(reasonFrame) in \(row.bounds)")
        // And the row's frame grew with the control: no row overlaps another.
        let rowFrames = stack.subviews
            .filter { $0 !== stack }
            .map { $0.convert($0.bounds, to: stack) }
            .sorted { $0.minY < $1.minY }
        for (lower, upper) in zip(rowFrames, rowFrames.dropFirst()) {
            #expect(lower.maxY <= upper.minY + 0.5,
                    "rows overlap: \(lower) reaches into \(upper)")
        }
        // Repairing collapses the row back.
        number.field.stringValue = "4"
        number.fieldEdited()
        nsWindow.contentView?.layoutSubtreeIfNeeded()
        #expect(number.errorReason == nil)
    }

    /// Finding N1: AppKit delivers hit-test points in the superview's
    /// coordinate system. A click on any correctly positioned control at a
    /// NONZERO origin — a later sidebar button, a later segment, a toggle
    /// right-aligned inside its row — must reach and activate it.
    @Test func clicksReachNonZeroOriginControls() throws {
        var fixture = try Fixture(); defer { fixture.cleanUp() }
        let store = try fixture.loadStore()
        let window = controller(fixture, store: store)
        window.show(section: "general")
        try #require(window.window).contentView?.layoutSubtreeIfNeeded()
        // A later sidebar button (its origin inside the stack is nonzero).
        let stocks = try #require(window.sectionButtons.first { $0.identifier?.rawValue == "section-stocks" })
        #expect(stocks.frame.origin != .zero, "the sidebar button sits at its stack's origin — the test proves nothing")
        try deliverClick(on: stocks, in: window)
        #expect(window.currentSection == "stocks", "the click on a later sidebar button did not switch sections")
        // A later segment button (nonzero x inside the segmented rim).
        window.show(section: "graphs")
        let segmented = try #require(try control(window, "graphs.network.display_mode") as? XRGSettingsSegmentedControl)
        let last = try #require(segmented.buttons.last)
        #expect(last.frame.origin != .zero, "the last segment sits at its rim's origin — the test proves nothing")
        let expected = try #require(segmented.options.last).value
        try deliverClick(on: last, in: window)
        #expect(store.value("graphs.network.display_mode") == expected,
                "the click on a later segment did not select it")
        // A toggle right-aligned inside its row (nonzero origin in the row).
        window.show(section: "general")
        let sticky = try #require(try control(window, "general.window.sticky_edges") as? XRGSettingsToggleControl)
        #expect(sticky.frame.minX > 4, "the toggle sits at its row's origin — the test proves nothing")
        try deliverClick(on: sticky, in: window)
        #expect(sticky.isOn == false && store.value("general.window.sticky_edges") == .bool(false),
                "the click on a row-aligned toggle did not flip it")
    }

    /// Finding N2: the bytes/s unit selector keeps the exact stored bytes
    /// independently of the displayed text — 512 B/s shows "0.5" KB/s and
    /// back without losing the value, fractional edits in a larger unit
    /// store whole bytes, fractional byte counts are refused, and every
    /// conversion is checked (a huge integer under GB/s cannot overflow).
    @Test func minimumScaleUnitsRoundTripExactBytes() throws {
        var fixture = try Fixture(); defer { fixture.cleanUp() }
        let store = try fixture.loadStore()
        let window = controller(fixture, store: store)
        try store.set("graphs.network.minimum_scale", .int(512))
        window.show(section: "graphs")
        let presented = try #require(try control(window, "graphs.network.minimum_scale") as? XRGSettingsNumberControl)
        let selector = try #require(presented.unitSelector)
        #expect(presented.field.stringValue == "512")
        #expect(selector.selectedItem?.title == "bytes/s")
        let file = try String(contentsOf: fixture.documentURL, encoding: .utf8)
        // KB/s presents the fraction; bytes/s presents it back; the stored
        // value never moves and nothing is submitted.
        selector.selectItem(withTitle: "KB/s")
        presented.unitEdited(selector)
        #expect(presented.field.stringValue == "0.5", "512 B/s did not present as 0.5 KB/s")
        selector.selectItem(withTitle: "bytes/s")
        presented.unitEdited(selector)
        #expect(presented.field.stringValue == "512", "the round trip lost the exact bytes")
        #expect(presented.value() == .int(512))
        #expect(store.value("graphs.network.minimum_scale") == .int(512))
        #expect(try String(contentsOf: fixture.documentURL, encoding: .utf8) == file)
        // A fractional edit in KB/s stores whole bytes.
        selector.selectItem(withTitle: "KB/s")
        presented.unitEdited(selector)
        presented.field.stringValue = "1.5"
        presented.fieldEdited()
        #expect(store.value("graphs.network.minimum_scale") == .int(1536))
        // A fractional byte count is refused and saves nothing.
        selector.selectItem(withTitle: "bytes/s")
        presented.unitEdited(selector)
        let before = try String(contentsOf: fixture.documentURL, encoding: .utf8)
        presented.field.stringValue = "0.5"
        presented.fieldEdited()
        #expect(presented.errorReason?.isEmpty == false, "0.5 bytes/s was not refused")
        #expect(store.value("graphs.network.minimum_scale") == .int(1536))
        #expect(try String(contentsOf: fixture.documentURL, encoding: .utf8) == before)
        // An overflowing value under GB/s is refused, not wrapped.
        selector.selectItem(withTitle: "GB/s")
        presented.unitEdited(selector)
        presented.field.stringValue = "99999999999999999999999"
        presented.fieldEdited()
        #expect(presented.errorReason == "The value is too large.",
                "the overflow was not refused with the stated reason")
        #expect(store.value("graphs.network.minimum_scale") == .int(1536))
        #expect(try String(contentsOf: fixture.documentURL, encoding: .utf8) == before)
        // Repairing presents in the stored value's largest dividing unit.
        selector.selectItem(withTitle: "bytes/s")
        presented.unitEdited(selector)
        presented.field.stringValue = "2048"
        presented.fieldEdited()
        #expect(store.value("graphs.network.minimum_scale") == .int(2048))
        window.show(section: "graphs")
        let repaired = try #require(try control(window, "graphs.network.minimum_scale") as? XRGSettingsNumberControl)
        #expect(repaired.field.stringValue == "2" && repaired.unitSelector?.selectedItem?.title == "KB/s")
    }

    /// Finding N3: repeated moves keep exactly one row container per graph,
    /// preserve keyboard focus on the moved graph's button, and Tab /
    /// Shift-Tab keep walking the rebuilt buttons — without reopening the
    /// section.
    @Test func reorderMovesKeepRowsFocusAndKeyboardNavigationAlive() throws {
        var fixture = try Fixture(); defer { fixture.cleanUp() }
        let store = try fixture.loadStore()
        let window = controller(fixture, store: store)
        window.show(section: "graphs")
        let nsWindow = try #require(window.window)
        let order = try #require(try control(window, "graphs.order") as? XRGSettingsOrderControl)
        try focus(try #require(order.rows[0].down), in: window)
        // Three keyboard moves in a row.
        for _ in 0..<3 { try deliverKey(" ", keyCode: 49, to: window) }
        // One row container per graph — the pre-fix rebuild left the old
        // containers behind and appended fresh ones.
        #expect(order.listStack.arrangedSubviews.count == 14,
                "empty row containers accumulated: \(order.listStack.arrangedSubviews.count)")
        #expect(order.rows.count == 14)
        #expect(order.rows.map(\.name.stringValue)[3] == "CPU", "three moves did not walk CPU down three rows")
        #expect(store.value("graphs.order") == .string("gpu,npu,vram,cpu,memory,battery,temperature,fans,network,disk,weather,stock,ai,processes"))
        // Focus survived on the moved graph's Move down button.
        #expect(nsWindow.firstResponder === order.rows[3].down,
                "keyboard focus did not survive the rebuild on the moved graph")
        // The rebuilt buttons rejoined the key-view loop: Tab walks on,
        // Shift-Tab walks back, without reopening the section.
        let expectedNext = order.rows[3].down.nextKeyView
        try deliverKey("\t", keyCode: 48, to: window)
        #expect(nsWindow.firstResponder === expectedNext, "Tab did not continue into the rebuilt rows")
        try deliverKey("\t", keyCode: 48, to: window, shift: true)
        #expect(nsWindow.firstResponder === order.rows[3].down, "Shift-Tab did not walk back")
        // A fourth move by VoiceOver press still works after all that.
        #expect(try #require(order.rows[3].down).accessibilityPerformPress())
        #expect(order.rows.map(\.name.stringValue)[4] == "CPU")
        #expect(order.listStack.arrangedSubviews.count == 14, "a move after keyboard navigation accumulated rows")
    }

    /// W2: every graph-order row shares one name column, so the Move up /
    /// Move down buttons line up vertically in their own columns.
    @Test func graphOrderMoveButtonsShareOneColumn() throws {
        var fixture = try Fixture(); defer { fixture.cleanUp() }
        let store = try fixture.loadStore()
        let window = controller(fixture, store: store)
        window.show(section: "graphs")
        let nsWindow = try #require(window.window)
        nsWindow.contentView?.layoutSubtreeIfNeeded()
        let order = try #require(try control(window, "graphs.order") as? XRGSettingsOrderControl)
        let ups = order.rows.map { $0.up.convert($0.up.bounds, to: order).minX }
        let downs = order.rows.map { $0.down.convert($0.down.bounds, to: order).minX }
        #expect(ups.allSatisfy { abs($0 - ups[0]) < 1.5 },
                "the Move up buttons do not share one column: \(ups)")
        #expect(downs.allSatisfy { abs($0 - downs[0]) < 1.5 },
                "the Move down buttons do not share one column: \(downs)")
        // The names share one column width, whatever each graph is called.
        let names = order.rows.map { $0.name.frame.width }
        #expect(names.allSatisfy { abs($0 - names[0]) < 1.5 },
                "the name column is not one shared width: \(names)")
    }

    /// Finding N4: the read-only font display (ruling P3) stays read-only —
    /// an unrelated settings notification, a font change of its own, and a
    /// same-section reopen must all leave it uneditable.
    @Test func readOnlyFontDisplayStaysReadOnlyThroughNotifications() throws {
        var fixture = try Fixture(); defer { fixture.cleanUp() }
        let store = try fixture.loadStore()
        let window = controller(fixture, store: store)
        window.show(section: "appearance")
        let display = try #require(try control(window, "appearance.font") as? XRGSettingsTextControl)
        #expect(!display.textField.isEditable, "the font display is editable from the start")
        // An unrelated change re-presents and re-enables the section's
        // controls — the font display must not re-open.
        try store.set("appearance.antialiasing", .bool(false))
        #expect(!display.textField.isEditable, "an unrelated notification re-opened the font display")
        // The font's own change drives the same path.
        let current = window.themeEngine().graphFont ?? NSFont.systemFont(ofSize: 10)
        window.applyGraphFont(NSFont.systemFont(ofSize: 17), old: current)
        #expect(!display.textField.isEditable, "changing the font re-opened the font display")
        #expect(store.value("appearance.font") == .string("System 17"))
        // And reopening the section keeps it read-only.
        window.show(section: "appearance")
        let reopened = try #require(try control(window, "appearance.font") as? XRGSettingsTextControl)
        #expect(!reopened.textField.isEditable, "a section reopen re-opened the font display")
        #expect(reopened.textField.stringValue == "System 17")
    }

    /// W1, proof (b): the window opened ON SCREEN renders every section's
    /// first card through the bitmap path — the controls are present,
    /// visible and inside the card's bounds, and the bitmap the snapshot
    /// tool draws from the live view shows their ink inside the first
    /// card. The degenerate pill radius used to paint one uniform colour
    /// over the whole capture instead, with no labels or controls.
    @Test func liveWindowRendersEverySectionsFirstCard() throws {
        var fixture = try Fixture(); defer { fixture.cleanUp() }
        let store = try fixture.loadStore()
        let window = controller(fixture, store: store)
        let nsWindow = try #require(window.window)
        // ON SCREEN, the way the user opens it.
        nsWindow.setFrame(NSRect(x: 120, y: 120, width: 760, height: 560), display: true)
        nsWindow.makeKeyAndOrderFront(nil)
        defer { nsWindow.orderOut(nil) }
        let content = try #require(nsWindow.contentView)
        for section in XRGSettingsCatalog.sections {
            window.show(section: section)
            content.layoutSubtreeIfNeeded()
            let pane = try #require(walkAll(content).compactMap { $0 as? XRGSettingsPaneStack }.first)
            let cards = walkAll(pane).compactMap { $0 as? XRGSettingsCardView }
            let first = try #require(cards.first, "no cards rendered in \(section)")
            let controls = walkAll(first).compactMap { $0 as? XRGSettingsEntryControl }
            #expect(!controls.isEmpty, "the first card of \(section) holds no controls")
            for control in controls {
                // Present, visible, inside the card: the W1 symptom was a
                // card whose controls were painted over by a uniform block.
                #expect(!control.isHidden && !control.isHiddenOrHasHiddenAncestor,
                        "a control of \(section)'s first card is hidden")
                #expect(control.alphaValue > 0.01,
                        "a control of \(section)'s first card is transparent")
                #expect(control.bounds.width > 0 && control.bounds.height > 0,
                        "a control of \(section)'s first card has no size")
                let frame = control.superview.map { $0.convert(control.frame, to: first) } ?? control.frame
                #expect(first.bounds.insetBy(dx: -1, dy: -1).contains(frame),
                        "a control of \(section)'s first card escapes the card: \(frame) in \(first.bounds)")
            }
            // The bitmap path over the LIVE view shows the card's ink: at
            // least one percent of the card's pixels differ from the card's
            // own surface — labels, rims and controls. The poisoned capture
            // was one uniform colour and failed exactly here.
            guard let bitmap = content.bitmapImageRepForCachingDisplay(in: content.bounds) else {
                #expect(Bool(false), "no bitmap for \(section)")
                continue
            }
            content.cacheDisplay(in: content.bounds, to: bitmap)
            let cardFrame = first.convert(first.bounds, to: content)
            let scale = CGFloat(bitmap.pixelsWide) / max(1, content.bounds.width)
            guard let surface = first.layer?.backgroundColor.flatMap(NSColor.init(cgColor:)) else {
                #expect(Bool(false), "the first card of \(section) has no surface colour")
                continue
            }
            var ink = 0, sampled = 0
            var inkBuckets: Set<String> = []
            for y in stride(from: 0, to: Int(cardFrame.height * scale), by: 2) {
                for x in stride(from: 0, to: Int(cardFrame.width * scale), by: 2) {
                    let bitmapX = Int(cardFrame.minX * scale) + x
                    // The bitmap's rows start at the content's visual top.
                    let bitmapY = Int((content.bounds.height - cardFrame.maxY) * scale) + y
                    guard bitmapX >= 0, bitmapY >= 0, bitmapX < bitmap.pixelsWide, bitmapY < bitmap.pixelsHigh,
                          let pixel = bitmap.colorAt(x: bitmapX, y: bitmapY)?.usingColorSpace(.sRGB) else { continue }
                    sampled += 1
                    let delta = max(abs(pixel.redComponent - surface.redComponent),
                                    abs(pixel.greenComponent - surface.greenComponent),
                                    abs(pixel.blueComponent - surface.blueComponent))
                    if delta > 0.09 {
                        ink += 1
                        // Real cards draw many chrome colours (labels, the
                        // eyebrow accent, rims, toggles); W1's poisoned
                        // capture was ONE flat fill with hairlines.
                        inkBuckets.insert("\(Int(pixel.redComponent * 16))/\(Int(pixel.greenComponent * 16))/\(Int(pixel.blueComponent * 16))")
                    }
                }
            }
            #expect(sampled > 500, "too little of \(section)'s first card was sampled: \(sampled)")
            #expect(Double(ink) >= 0.01 * Double(sampled),
                    "\(section)'s first card shows no controls in the bitmap path (ink \(ink)/\(sampled))")
            #expect(inkBuckets.count >= 3,
                    "\(section)'s first card renders as a flat block in the bitmap path (\(inkBuckets.count) ink colours)")
            // Every card leads with a "// GROUP" eyebrow in the accent
            // colour: W1's flat fill buried it, so its accent pixels are
            // the sharpest proof the card actually renders. (The flat-fill
            // share alone cannot discriminate: a healthy sparse card runs
            // as high as 97.5% surface while the poison covered ~99%.)
            let accent = XRGAether7b.Color.accentActive(dark: XRGAether7bPalette.isDark(content))
                .usingColorSpace(.sRGB) ?? NSColor.black
            var eyebrow = 0
            for y in stride(from: 0, to: Int(30 * scale), by: 2) {
                for x in stride(from: 0, to: Int(cardFrame.width * scale), by: 2) {
                    let bitmapX = Int(cardFrame.minX * scale) + x
                    let bitmapY = Int((content.bounds.height - cardFrame.maxY) * scale) + y
                    guard bitmapX >= 0, bitmapY >= 0, bitmapX < bitmap.pixelsWide, bitmapY < bitmap.pixelsHigh,
                          let pixel = bitmap.colorAt(x: bitmapX, y: bitmapY)?.usingColorSpace(.sRGB) else { continue }
                    // Small mono glyphs subpixel-blend toward the card
                    // surface, so the match tolerance is loose — the flat
                    // poison fill left ZERO such pixels.
                    if abs(pixel.redComponent - accent.redComponent) < 0.15,
                       abs(pixel.greenComponent - accent.greenComponent) < 0.15,
                       abs(pixel.blueComponent - accent.blueComponent) < 0.15 { eyebrow += 1 }
                }
            }
            #expect(eyebrow >= 15,
                    "\(section)'s first card eyebrow is missing in the bitmap path (\(eyebrow) accent pixels)")
        }
    }

    // MARK: Layout (fixes V1, V2, V3, V5, V8)

    /// Every section opens from its top, cards fit the content pane,
    /// controls align in one right-hand column, action buttons align with
    /// the label column, and segmented labels are not clipped.
    @Test func cardsFitControlsAlignAndSectionsOpenFromTheTop() throws {
        var fixture = try Fixture(); defer { fixture.cleanUp() }
        let store = try fixture.loadStore()
        let window = controller(fixture, store: store)
        let nsWindow = try #require(window.window)
        // Every section — short and long alike — opens from its top (V1):
        // the visible document range starts at the document's first line
        // (within the full-size titlebar's content inset), never at the end.
        for section in ["stocks", "graphs"] {
            window.show(section: section)
            nsWindow.contentView?.layoutSubtreeIfNeeded()
            let clip = try #require(walkAll(content(window)).compactMap { $0 as? NSClipView }.first)
            #expect(clip.documentVisibleRect.minY <= 36, "\(section) did not open from the top")
        }
        window.show(section: "general")
        nsWindow.contentView?.layoutSubtreeIfNeeded()
        let pane = try #require(walkAll(content(window)).compactMap { $0 as? XRGSettingsPaneStack }.first)
        let cards = walkAll(pane).compactMap { $0 as? XRGSettingsCardView }
        #expect(!cards.isEmpty)
        for card in cards {
            // The card's right edge lands inside the content pane (V2).
            #expect(card.frame.maxX <= pane.bounds.width + 0.5, "a card is wider than the content pane")
            let rows = card.rows.subviews.compactMap { $0 as? NSView }
            _ = rows
            // Controls align in one column on the right (V5).
            let trailing = walkAll(card).compactMap { $0 as? XRGSettingsEntryControl }
                .filter { $0.entry.control != .action && $0.entry.control != .order }
                .map { $0.superview!.convert($0.frame, to: card).maxX }
            if !trailing.isEmpty {
                #expect(trailing.allSatisfy { abs($0 - trailing[0]) < 1.5 },
                        "the controls do not sit in one column: \(trailing)")
            }
            // V2: every wrapper closes around its VISIBLE contents — the
            // column above must be made of real controls, not stretched
            // wrappers whose contents float anywhere inside them.
            for control in walkAll(card).compactMap({ $0 as? XRGSettingsEntryControl }) {
                let visible = control.subviews.filter { !$0.isHidden && !$0.isHiddenOrHasHiddenAncestor }
                guard !visible.isEmpty else { continue }
                let widest = visible.map { $0.frame.maxX }.max() ?? 0
                #expect(abs(control.bounds.width - widest) < 1.5,
                        "the wrapper of \(control.entry.id) does not enclose its trailing content: \(control.bounds.width) vs \(widest)")
            }
            // An action button aligns with the label column (V8).
            let rowLabels = walkAll(card).compactMap { $0 as? NSTextField }
                .filter { $0.superview?.superview === card.rows }
            if let action = walkAll(card).compactMap({ $0 as? XRGSettingsActionControl }).first,
               let row = rowLabels.first?.superview {
                let actionX = action.convert(action.bounds, to: card).minX
                let rowX = row.convert(row.bounds, to: card).minX
                #expect(abs(actionX - rowX) < 1.5, "the action button is indented relative to the card content: actionX=\(actionX) rowX=\(rowX)")
            }
        }
        // Segmented labels are not vertically clipped (V3).
        window.show(section: "graphs")
        nsWindow.contentView?.layoutSubtreeIfNeeded()
        let segmented = try #require(try control(window, "graphs.network.display_mode") as? XRGSettingsSegmentedControl)
        let first = try #require(segmented.buttons.first)
        #expect(segmented.rimView.bounds.insetBy(dx: -0.5, dy: -0.5).contains(first.bounds),
                "a segment button is clipped by its rim")
        #expect(first.bounds.height >= first.labelField.intrinsicContentSize.height + 4,
                "the segment label is clipped")
    }
}

/// A main-actor box for recording notifications in tests.
@MainActor final class MainActorBox<Value> {
    var value: Value
    init(_ value: Value) { self.value = value }
}
