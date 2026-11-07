// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Stephen de la Vega.
//
// One AppKit view per catalog control type (0.2.3 spec §5), styled only
// with Aether7b tokens: colours from `XRGAether7b.Color`, sizes from its
// type scale and spacing, radii from `XRGAether7b.Radius`. Every colour any
// of these views sets — layer background, text, rim — is a token colour for
// the current appearance, which `onlyAether7bColours` walks and checks.

import AppKit

/// The Aether7b colour palette as one flat list per appearance, plus the
/// membership test the window's token-only rule is asserted with.
@MainActor public enum XRGAether7bPalette {
    /// Every adaptive token colour for one appearance, as sRGB colours.
    public static func colours(dark: Bool) -> [NSColor] {
        var values: [NSColor] = [
            XRGAether7b.Color.bgCanvas(dark: dark), XRGAether7b.Color.surfaceChrome(dark: dark),
            XRGAether7b.Color.surfaceChromeFallback(dark: dark), XRGAether7b.Color.surfaceCard(dark: dark),
            XRGAether7b.Color.surfaceCode(dark: dark), XRGAether7b.Color.textMain(dark: dark),
            XRGAether7b.Color.textMuted(dark: dark), XRGAether7b.Color.accentActive(dark: dark),
            XRGAether7b.Color.accentFill(dark: dark), XRGAether7b.Color.accentTint(dark: dark),
            XRGAether7b.Color.border(dark: dark), XRGAether7b.Color.borderStrong(dark: dark),
            XRGAether7b.Color.specular(dark: dark), XRGAether7b.Color.statusNominal(dark: dark),
            XRGAether7b.Color.statusWarning(dark: dark), XRGAether7b.Color.statusDanger(dark: dark),
            XRGAether7b.Color.statusSuccess(dark: dark), XRGAether7b.Color.orb(dark: dark),
            XRGAether7b.Color.carolinaClassic, XRGAether7b.Color.carolinaWeb,
            XRGAether7b.Color.carolinaInk, XRGAether7b.Color.iceSpecular,
            XRGAether7b.Color.navyCore, XRGAether7b.Color.obsidian,
        ]
        // The window background washes the canvas with the token; keep the
        // pure canvas and a 3%-lighter wash both legal (the aurora orb).
        values.append(XRGAether7b.Color.bgCanvas(dark: dark).withAlphaComponent(1))
        return values
    }

    /// One adaptive colour by name, for callers that must not hard-code a
    /// raw value (the danger rim, the reason label).
    public static func color(_ token: Token, dark: Bool) -> NSColor {
        switch token {
        case .bgCanvas: return XRGAether7b.Color.bgCanvas(dark: dark)
        case .surfaceCard: return XRGAether7b.Color.surfaceCard(dark: dark)
        case .accentTint: return XRGAether7b.Color.accentTint(dark: dark)
        case .statusDanger: return XRGAether7b.Color.statusDanger(dark: dark)
        case .statusWarning: return XRGAether7b.Color.statusWarning(dark: dark)
        case .borderStrong: return XRGAether7b.Color.borderStrong(dark: dark)
        }
    }
    public enum Token { case bgCanvas, surfaceCard, accentTint, statusDanger, statusWarning, borderStrong }

    /// Whether a colour equals some Aether7b value for this appearance.
    /// Compares sRGB components and alpha with a small rounding tolerance
    /// (token colours go through `NSColor` gamma conversion).
    public static func isAether7b(_ color: NSColor, dark: Bool) -> Bool {
        let candidates = colours(dark: dark).compactMap { $0.usingColorSpace(.sRGB) }
        guard let mine = color.usingColorSpace(.sRGB) else { return false }
        return candidates.contains { candidate in
            abs(candidate.redComponent - mine.redComponent) < 0.002
                && abs(candidate.greenComponent - mine.greenComponent) < 0.002
                && abs(candidate.blueComponent - mine.blueComponent) < 0.002
                && abs(candidate.alphaComponent - mine.alphaComponent) < 0.005
        }
    }

    /// Whether the effective appearance of a view is dark.
    public static func isDark(_ view: NSView) -> Bool {
        var effective: NSAppearance?
        if let window = view.window { effective = window.effectiveAppearance }
        else if let appearance = NSApplication.shared.effectiveAppearance as NSAppearance? { effective = appearance }
        else { effective = NSAppearance(named: .aqua) }
        return isDark(appearance: effective ?? NSAppearance(named: .aqua)!)
    }
    /// Whether an appearance resolves to dark Aether7b values.
    public static func isDark(appearance: NSAppearance) -> Bool {
        guard let match = appearance.bestMatch(from: [.darkAqua, .aqua, .vibrantDark, .vibrantLight]) else {
            return false
        }
        return match == .darkAqua || match == .vibrantDark
    }
}

/// Base class of every settings control: knows its catalog entry, holds a
/// silent `present` for store-driven refreshes, an `apply` path for user
/// edits, an enabled state that follows `depends`, and the danger rim +
/// mono reason label an invalid entry shows (spec §5: nothing else turns
/// red, and an invalid value is never saved).
@MainActor public class XRGSettingsEntryControl: NSView {
    public let entry: XRGSettingsEntry
    var isDarkAppearance: Bool
    /// Applies a user edit; the window controller installs this. It is
    /// called only for values the widget produced, after user interaction
    /// or the test equivalent (`click()`, `fieldEdited()`).
    var applyEdit: ((XRGSettingsEntryControl, XRGSettingsValue) -> Void)?
    /// The control's current value, as the user last left it.
    public func value() -> XRGSettingsValue { entry.defaultValue }
    /// The mono label carrying the reason an entry is invalid.
    let reasonLabel = NSTextField(wrappingLabelWithString: "")
    private(set) var errorReason: String?
    public private(set) var isEnabledControl = true
    /// Whether the entry's `depends` requirement holds for this control.
    public var isEnabled: Bool { isEnabledControl }
    /// The rim (container border) the control sits in.
    let rimView = NSView()

    public init(entry: XRGSettingsEntry, dark: Bool) {
        self.entry = entry
        self.isDarkAppearance = dark
        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false
        setAccessibilityLabel(entry.label)
        toolTip = entry.help
        identifier = NSUserInterfaceItemIdentifier(entry.id)
        rimView.translatesAutoresizingMaskIntoConstraints = false
        rimView.wantsLayer = true
        rimView.layer?.cornerRadius = XRGAether7b.Radius.md
        rimView.layer?.borderColor = XRGAether7b.Color.borderStrong(dark: dark).cgColor
        rimView.layer?.borderWidth = 1
        addSubview(rimView)
        NSLayoutConstraint.activate([
            rimView.leadingAnchor.constraint(equalTo: leadingAnchor),
            rimView.topAnchor.constraint(equalTo: topAnchor),
            rimView.bottomAnchor.constraint(equalTo: bottomAnchor),
        ])
        reasonLabel.translatesAutoresizingMaskIntoConstraints = false
        reasonLabel.identifier = NSUserInterfaceItemIdentifier("reason-\(entry.id)")
        reasonLabel.font = monoFont(XRGAether7b.TypeScale.xs.size)
        reasonLabel.textColor = XRGAether7b.Color.statusDanger(dark: dark)
        reasonLabel.stringValue = ""
        reasonLabel.isHidden = true
        reasonLabel.cell?.wraps = false
        addSubview(reasonLabel)
    }
    @available(*, unavailable) required init?(coder: NSCoder) { fatalError("Programmatic view") }

    // MARK: Theme plumbing

    /// The rim colour (the container border), for the danger-rim checks.
    public var rimColor: NSColor? { rimView.layer?.borderColor.flatMap { NSColor(cgColor: $0) } }
    public func applyAppearance(dark: Bool) {
        isDarkAppearance = dark
        reasonLabel.textColor = XRGAether7b.Color.statusDanger(dark: dark)
        rimColor(dark: dark)
        themeDidChange(dark: dark)
    }
    func rimColor(dark: Bool) {
        let color: NSColor = errorReason == nil
            ? XRGAether7b.Color.borderStrong(dark: dark)
            : XRGAether7bPalette.color(.statusDanger, dark: dark)
        rimView.layer?.borderColor = color.cgColor
    }
    /// Subclasses restyle their widgets here.
    public func themeDidChange(dark: Bool) {}

    // MARK: State

    /// Show the store's value without applying anything (silent refresh).
    public func present(_ value: XRGSettingsValue) {}
    /// Enable or disable following the entry's `depends`.
    public func setEnabled(_ enabled: Bool) {
        isEnabledControl = enabled
        alphaValue = enabled ? 1 : 0.45
        enabledDidChange(enabled)
    }
    public func enabledDidChange(_ enabled: Bool) {}
    /// Show the danger rim, dot and mono reason for an invalid entry, or
    /// clear them.
    public func showError(_ reason: String?) {
        errorReason = reason
        reasonLabel.stringValue = reason ?? ""
        reasonLabel.isHidden = reason == nil
        rimColor(dark: isDarkAppearance)
    }
    /// Drive the apply path with a value the widget produced.
    func submit(_ value: XRGSettingsValue) { applyEdit?(self, value) }
}

// MARK: - Shared theme helpers

@MainActor enum XRGAether7bStyle {
    static func monoFont(_ size: CGFloat) -> NSFont {
        NSFont.monospacedDigitSystemFont(ofSize: size, weight: .regular)
    }
    static func sansFont(_ size: CGFloat, weight: NSFont.Weight = .regular) -> NSFont {
        NSFont.systemFont(ofSize: size, weight: weight)
    }
    static let eyebrowTracking = 0.9

    /// An `// EYEBROW` mono label (CSS-rendered slashes in the mockup).
    static func eyebrow(_ text: String, dark: Bool, size: CGFloat = 12.0) -> NSTextField {
        let label = NSTextField(labelWithString: "")
        label.font = monoFont(size)
        let string = NSMutableAttributedString()
        string.append(NSAttributedString(string: "// ", attributes: [.foregroundColor: XRGAether7b.Color.textMuted(dark: dark),
                                                                      .font: monoFont(size)]))
        string.append(NSAttributedString(string: text.uppercased(), attributes: [.foregroundColor: XRGAether7b.Color.accentActive(dark: dark),
                                                                                    .font: monoFont(size),
                                                                                    .kern: eyebrowTracking]))
        label.attributedStringValue = string
        // The attributed string carries the colours; the property must also
        // stay on a token colour for the walk (AppKit defaults it otherwise).
        label.textColor = XRGAether7b.Color.accentActive(dark: dark)
        return label
    }
    static func label(_ text: String, dark: Bool, muted: Bool = false,
                      size: CGFloat = 13.0) -> NSTextField {
        let field = NSTextField(wrappingLabelWithString: text)
        field.font = sansFont(size, weight: muted ? .regular : .medium)
        field.textColor = muted ? XRGAether7b.Color.textMuted(dark: dark) : XRGAether7b.Color.textMain(dark: dark)
        return field
    }
    static func field(_ dark: Bool) -> NSTextField {
        let field = NSTextField()
        field.font = monoFont(XRGAether7b.TypeScale.sm.size)
        field.textColor = XRGAether7b.Color.textMain(dark: dark)
        field.backgroundColor = XRGAether7b.Color.surfaceCard(dark: dark)
        field.isBordered = false
        field.focusRingType = .exterior
        field.translatesAutoresizingMaskIntoConstraints = false
        return field
    }
}

@MainActor func monoFont(_ size: CGFloat) -> NSFont { XRGAether7bStyle.monoFont(size) }

/// A flat token-styled button: a layer-backed plain view with a label,
/// no bezel (macOS 26's SwiftUI-backed NSButtons churn Attribute Graph
/// under the window's re-render churn). `performClick(_:)` keeps the
/// test-facing action surface of NSButton.
@MainActor public final class XRGSettingsFlatButton: NSControl {
    public let labelField = NSTextField(labelWithString: "")
    var onClick: (() -> Void)?

    public init(title: String, onClick: (() -> Void)? = nil) {
        super.init(frame: .zero)
        self.onClick = onClick
        translatesAutoresizingMaskIntoConstraints = false
        wantsLayer = true
        layer?.cornerRadius = XRGAether7b.Radius.sm
        labelField.translatesAutoresizingMaskIntoConstraints = false
        labelField.stringValue = title
        labelField.font = sansFont(XRGAether7b.TypeScale.sm.size, weight: .medium)
        addSubview(labelField)
        NSLayoutConstraint.activate([
            labelField.leadingAnchor.constraint(equalTo: leadingAnchor, constant: XRGAether7b.Space.s3),
            labelField.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -XRGAether7b.Space.s3),
            labelField.centerYAnchor.constraint(equalTo: centerYAnchor),
            topAnchor.constraint(equalTo: labelField.topAnchor, constant: -XRGAether7b.Space.s2),
            bottomAnchor.constraint(equalTo: labelField.bottomAnchor, constant: XRGAether7b.Space.s2),
        ])
        setAccessibilityLabel(title)
        setAccessibilityRole(.button)
        target = self
        action = #selector(clicked(_:))
    }
    @available(*, unavailable) required init?(coder: NSCoder) { fatalError("Programmatic view") }

    public func performClick() { if isEnabled { onClick?() } }
    @objc func clicked(_ sender: Any?) { onClick?() }

    /// Style from tokens: `background` nil means transparent.
    public func style(background: NSColor?, text: NSColor, border: NSColor?, dark: Bool) {
        layer?.backgroundColor = background?.cgColor
        layer?.borderColor = border?.cgColor
        layer?.borderWidth = border == nil ? 0 : 1
        labelField.textColor = text
    }
}
@MainActor func sansFont(_ size: CGFloat, weight: NSFont.Weight = .regular) -> NSFont { XRGAether7bStyle.sansFont(size, weight: weight) }

// MARK: - Toggle

/// The mockup's pill toggle: a 34×20 track on the strong rim, knob 14 pt.
@MainActor public final class XRGSettingsToggleControl: XRGSettingsEntryControl {
    public let trackView = NSView()
    public let knobView = NSView()
    public private(set) var isOn: Bool = false

    public override func value() -> XRGSettingsValue { .bool(isOn) }
    public override func present(_ value: XRGSettingsValue) {
        guard case .bool(let flag) = value else { return }
        isOn = flag
        layoutTrack()
    }
    public override func themeDidChange(dark: Bool) { layoutTrack() }
    public override func enabledDidChange(_ enabled: Bool) { trackView.isHidden = !enabled }

    public override init(entry: XRGSettingsEntry, dark: Bool) {
        super.init(entry: entry, dark: dark)
        translatesAutoresizingMaskIntoConstraints = false
        trackView.translatesAutoresizingMaskIntoConstraints = false
        trackView.wantsLayer = true
        trackView.layer?.cornerRadius = 10
        trackView.layer?.borderWidth = 1
        knobView.translatesAutoresizingMaskIntoConstraints = false
        knobView.wantsLayer = true
        knobView.layer?.cornerRadius = 7
        trackView.addSubview(knobView)
        addSubview(trackView)
        present(entry.defaultValue)
        NSLayoutConstraint.activate([
            trackView.widthAnchor.constraint(equalToConstant: 34), trackView.heightAnchor.constraint(equalToConstant: 20),
            trackView.centerYAnchor.constraint(equalTo: rimView.centerYAnchor),
            trackView.leadingAnchor.constraint(equalTo: rimView.leadingAnchor, constant: XRGAether7b.Space.s2),
            rimView.widthAnchor.constraint(equalToConstant: 50), rimView.heightAnchor.constraint(equalToConstant: 24),
        ])
        layoutTrack()
    }

    func layoutTrack() {
        let dark = isDarkAppearance
        trackView.layer?.backgroundColor = (isOn ? XRGAether7b.Color.accentFill(dark: dark)
                                                 : XRGAether7b.Color.surfaceCard(dark: dark)).cgColor
        trackView.layer?.borderColor = (isOn ? XRGAether7b.Color.iceSpecular
                                             : XRGAether7b.Color.borderStrong(dark: dark)).cgColor
        knobView.layer?.backgroundColor = (isOn ? XRGAether7b.Color.obsidian : XRGAether7b.Color.textMuted(dark: dark)).cgColor
        knobView.frame = NSRect(x: isOn ? 34 - 2 - 14 : 2, y: 2, width: 14, height: 14)
        setAccessibilityValue(isOn ? "checked" : "unchecked")
    }

    public override func mouseDown(with event: NSEvent) {}
    public override func mouseUp(with event: NSEvent) { if isEnabledControl { click() } }
    /// The same path a real click takes (tests use this directly).
    public func click() {
        guard isEnabledControl else { return }
        present(.bool(!isOn))
        submit(value())
    }
}

// MARK: - Choice

/// A choice menu inside the rim: borderless pop-up, mono type, token text.
@MainActor public final class XRGSettingsChoiceControl: XRGSettingsEntryControl {
    public let popUp = NSPopUpButton(frame: .zero, pullsDown: false)
    var options: [XRGSettingsOption] = []
    public var optionLabels: [String] { options.map(\.label) }

    public override func value() -> XRGSettingsValue {
        let index = popUp.indexOfSelectedItem
        return options.indices.contains(index) ? options[index].value : XRGSettingsValue.null
    }
    public override func present(_ value: XRGSettingsValue) {
        if let index = options.firstIndex(where: { XRGSettingsValue.sameValue($0.value, value) }) {
            popUp.selectItem(at: index)
        }
    }
    public override func themeDidChange(dark: Bool) {
        popUp.contentTintColor = XRGAether7b.Color.textMain(dark: dark)
    }

    public override init(entry: XRGSettingsEntry, dark: Bool) {
        super.init(entry: entry, dark: dark)
        options = entry.options ?? []
        popUp.translatesAutoresizingMaskIntoConstraints = false
        popUp.bezelStyle = .texturedRounded
        popUp.font = monoFont(XRGAether7b.TypeScale.sm.size)
        popUp.contentTintColor = XRGAether7b.Color.textMain(dark: dark)
        popUp.addItems(withTitles: options.map(\.label))
        for (index, option) in options.enumerated() { popUp.item(at: index)?.toolTip = option.value.isTextualDescription }
        rimView.addSubview(popUp)
        NSLayoutConstraint.activate([
            popUp.leadingAnchor.constraint(equalTo: rimView.leadingAnchor, constant: XRGAether7b.Space.s1),
            popUp.trailingAnchor.constraint(equalTo: rimView.trailingAnchor, constant: -XRGAether7b.Space.s1),
            popUp.centerYAnchor.constraint(equalTo: rimView.centerYAnchor),
            rimView.widthAnchor.constraint(greaterThanOrEqualToConstant: 120), rimView.heightAnchor.constraint(equalToConstant: 26),
        ])
        present(entry.defaultValue)
        popUp.target = self
        popUp.action = #selector(selected(_:))
    }
    @objc func selected(_ sender: NSPopUpButton) { submit(value()) }
}

// MARK: - Segmented

/// The mockup's segmented control: one flat button per option, the
/// selected one on the accent tint with accent text.
@MainActor public final class XRGSettingsSegmentedControl: XRGSettingsEntryControl {
    var options: [XRGSettingsOption] = []
    var buttons: [XRGSettingsFlatButton] = []
    var selected = 0
    public var optionLabels: [String] { options.map(\.label) }

    public override func value() -> XRGSettingsValue {
        options.indices.contains(selected) ? options[selected].value : .null
    }
    public override func present(_ value: XRGSettingsValue) {
        if let index = options.firstIndex(where: { XRGSettingsValue.sameValue($0.value, value) }) { selected = index }
        restyle()
    }
    public override func themeDidChange(dark: Bool) { restyle() }

    public override init(entry: XRGSettingsEntry, dark: Bool) {
        super.init(entry: entry, dark: dark)
        options = entry.options ?? []
        var previous: NSView = rimView
        for (index, option) in options.enumerated() {
            let button = XRGSettingsFlatButton(title: option.label) { [weak self] in
                self?.pickedSegment(index)
            }
            button.labelField.font = sansFont(XRGAether7b.TypeScale.xs.size)
            button.setAccessibilityLabel("\(entry.label): \(option.label)")
            rimView.addSubview(button)
            buttons.append(button)
            NSLayoutConstraint.activate([
                button.leadingAnchor.constraint(equalTo: previous == rimView ? rimView.leadingAnchor : previous.trailingAnchor),
                button.centerYAnchor.constraint(equalTo: rimView.centerYAnchor),
                button.topAnchor.constraint(greaterThanOrEqualTo: rimView.topAnchor, constant: 2),
                rimView.bottomAnchor.constraint(greaterThanOrEqualTo: button.bottomAnchor, constant: 2),
            ])
            previous = button
        }
        if let last = buttons.last {
            rimView.trailingAnchor.constraint(equalTo: last.trailingAnchor, constant: XRGAether7b.Space.s1).isActive = true
        }
        rimView.heightAnchor.constraint(equalToConstant: 28).isActive = true
        present(entry.defaultValue)
    }
    func pickedSegment(_ index: Int) {
        guard isEnabledControl else { return }
        selected = index
        restyle()
        submit(value())
    }
    func restyle() {
        let dark = isDarkAppearance
        for (index, button) in buttons.enumerated() {
            button.style(background: index == selected ? XRGAether7b.Color.accentTint(dark: dark) : nil,
                         text: index == selected ? XRGAether7b.Color.accentActive(dark: dark)
                                                 : XRGAether7b.Color.textMuted(dark: dark),
                         border: nil, dark: dark)
        }
    }
}

// MARK: - Number (integer, decimal, duration)

/// A number or duration field with its unit and range shown, and a slider
/// when the catalog gives a step (spec §5).
@MainActor public final class XRGSettingsNumberControl: XRGSettingsEntryControl {
    public var field = NSTextField()
    public let slider: NSSlider?
    let unitLabel = NSTextField(labelWithString: "")
    let rangeLabel = NSTextField(labelWithString: "")
    public var fieldMin: Double { entry.range?.min ?? 0 }
    public var fieldMax: Double { entry.range?.max ?? 100 }

    public override func value() -> XRGSettingsValue {
        switch entry.control {
        case .integer:
            guard let text = field.stringValue.trimmingCharacters(in: .whitespaces).nilIfEmpty, let number = Int64(text) else { return entry.defaultValue }
            return .int(number)
        case .decimal, .duration:
            guard let text = field.stringValue.trimmingCharacters(in: .whitespaces).nilIfEmpty, let number = Double(text), number.isFinite else { return entry.defaultValue }
            return .double(number)
        default: return entry.defaultValue
        }
    }
    public override func present(_ value: XRGSettingsValue) {
        switch value {
        case .int(let number): field.stringValue = String(number)
        case .double(let number): field.stringValue = Self.format(number)
        default: field.stringValue = ""
        }
        slider?.doubleValue = numericValue ?? fieldMin
    }
    var numericValue: Double? {
        switch value() { case .int(let n): return Double(n); case .double(let n): return n; default: return nil }
    }
    static func format(_ number: Double) -> String {
        number == number.rounded() ? String(Int(number)) : String(format: "%.12g", number)
    }

    public override func themeDidChange(dark: Bool) {
        field.textColor = XRGAether7b.Color.textMain(dark: dark)
        field.backgroundColor = XRGAether7b.Color.surfaceCard(dark: dark)
        unitLabel.textColor = XRGAether7b.Color.textMuted(dark: dark)
        rangeLabel.textColor = XRGAether7b.Color.textMuted(dark: dark)
    }

    public override init(entry: XRGSettingsEntry, dark: Bool) {
        let step = entry.range?.step
        if let step {
            self.slider = NSSlider(value: 0, minValue: entry.range?.min ?? 0, maxValue: entry.range?.max ?? 1,
                                   target: nil, action: nil)
            slider?.allowsTickMarkValuesOnly = false
            _ = step
        } else {
            self.slider = nil
        }
        super.init(entry: entry, dark: dark)
        field = XRGAether7bStyle.field(dark)
        field.placeholderString = ""
        rimView.addSubview(field)
        field.leadingAnchor.constraint(equalTo: rimView.leadingAnchor, constant: XRGAether7b.Space.s2).isActive = true
        field.centerYAnchor.constraint(equalTo: rimView.centerYAnchor).isActive = true
        field.widthAnchor.constraint(equalToConstant: 72).isActive = true
        rimView.heightAnchor.constraint(equalToConstant: 26).isActive = true
        field.target = self
        field.action = #selector(fieldEdited)
        var rangeAnchor = field.trailingAnchor
        if let unit = entry.range?.unit, !unit.isEmpty {
            unitLabel.stringValue = unit
            unitLabel.font = monoFont(XRGAether7b.TypeScale.xs.size)
            unitLabel.textColor = XRGAether7b.Color.textMuted(dark: dark)
            unitLabel.translatesAutoresizingMaskIntoConstraints = false
            addSubview(unitLabel)
            unitLabel.leadingAnchor.constraint(equalTo: field.trailingAnchor, constant: XRGAether7b.Space.s2).isActive = true
            unitLabel.centerYAnchor.constraint(equalTo: field.centerYAnchor).isActive = true
            rangeAnchor = unitLabel.trailingAnchor
        }
        // The range, shown beside the field (mockup: "200 ms – 10 s").
        if let range = entry.range {
            let minText = entry.control == .duration ? Self.durationText(range.min, unit: range.unit) : Self.format(range.min)
            let maxText = entry.control == .duration ? Self.durationText(range.max, unit: range.unit) : Self.format(range.max)
            rangeLabel.stringValue = "\(minText) – \(maxText)"
            rangeLabel.font = sansFont(XRGAether7b.TypeScale.xs.size)
            rangeLabel.textColor = XRGAether7b.Color.textMuted(dark: dark)
            rangeLabel.translatesAutoresizingMaskIntoConstraints = false
            addSubview(rangeLabel)
            rangeLabel.leadingAnchor.constraint(equalTo: rangeAnchor, constant: XRGAether7b.Space.s2).isActive = true
            rangeLabel.centerYAnchor.constraint(equalTo: field.centerYAnchor).isActive = true
        }
        if let slider {
            slider.translatesAutoresizingMaskIntoConstraints = false
            slider.controlSize = .small
            slider.widthAnchor.constraint(equalToConstant: 150).isActive = true
            addSubview(slider)
            slider.leadingAnchor.constraint(equalTo: rimView.trailingAnchor, constant: XRGAether7b.Space.s3).isActive = true
            slider.centerYAnchor.constraint(equalTo: field.centerYAnchor).isActive = true
            slider.target = self
            slider.action = #selector(sliderEdited(_:))
        }
        present(entry.defaultValue)
    }
    static func durationText(_ seconds: Double, unit: String?) -> String {
        switch unit {
        case "min": return "\(Self.format(seconds)) min"
        default: return Self.format(seconds) + " " + (unit ?? "s")
        }
    }
    /// The user edited the field: the same path an end-editing action takes.
    @objc public func fieldEdited() { submit(value()) }
    @objc func sliderEdited(_ sender: NSSlider) {
        guard let step = entry.range?.step else { return }
        let stepped = (sender.doubleValue / step).rounded() * step
        present(.double(min(fieldMax, max(fieldMin, stepped))))
        submit(value())
    }
}

// MARK: - Color

@MainActor public final class XRGSettingsColorControl: XRGSettingsEntryControl {
    public let well = NSColorWell()
    /// False while the entry is unset (`.null`: empty inherits the palette).
    var hasColor = false
    public override func value() -> XRGSettingsValue {
        guard hasColor, let rgba = well.color.usingColorSpace(.sRGB) else { return XRGSettingsValue.null }
        return .color([Double(rgba.redComponent), Double(rgba.greenComponent), Double(rgba.blueComponent), Double(rgba.alphaComponent)])
    }
    public override func present(_ value: XRGSettingsValue) {
        guard case .color(let rgba) = value, rgba.count == 4 else { hasColor = false; well.color = .clear; return }
        hasColor = true
        well.color = NSColor(srgbRed: CGFloat(rgba[0]), green: CGFloat(rgba[1]), blue: CGFloat(rgba[2]), alpha: CGFloat(rgba[3]))
    }
    public override init(entry: XRGSettingsEntry, dark: Bool) {
        super.init(entry: entry, dark: dark)
        well.translatesAutoresizingMaskIntoConstraints = false
        well.color = .black
        rimView.addSubview(well)
        NSLayoutConstraint.activate([
            well.leadingAnchor.constraint(equalTo: rimView.leadingAnchor, constant: XRGAether7b.Space.s1),
            well.centerYAnchor.constraint(equalTo: rimView.centerYAnchor),
            well.widthAnchor.constraint(equalToConstant: 44), well.heightAnchor.constraint(equalToConstant: 22),
            rimView.widthAnchor.constraint(equalToConstant: 50), rimView.heightAnchor.constraint(equalToConstant: 24),
        ])
        present(entry.defaultValue)
        well.target = self
        well.action = #selector(changedColor)
    }
    @objc func changedColor() { hasColor = true; submit(value()) }
}

// MARK: - Path

@MainActor public final class XRGSettingsPathControl: XRGSettingsEntryControl {
    public let pathField = NSTextField()
    public let chooseButton: XRGSettingsFlatButton
    var onChoose: ((XRGSettingsPathControl) -> Void)?

    public override func value() -> XRGSettingsValue { .string(pathField.stringValue) }
    public override func present(_ value: XRGSettingsValue) {
        guard case .string(let path) = value else { return }
        pathField.stringValue = path
    }
    public override func themeDidChange(dark: Bool) {
        pathField.textColor = XRGAether7b.Color.textMain(dark: dark)
        pathField.backgroundColor = XRGAether7b.Color.surfaceCard(dark: dark)
    }
    public override init(entry: XRGSettingsEntry, dark: Bool) {
        chooseButton = XRGSettingsFlatButton(title: "Choose…")
        super.init(entry: entry, dark: dark)
        chooseButton.onClick = { [weak self] in
            guard let self else { return }
            _ = self.choose(self.chooseButton)
        }
        chooseButton.style(background: nil, text: XRGAether7b.Color.textMain(dark: dark),
                           border: XRGAether7b.Color.borderStrong(dark: dark), dark: dark)
        pathField.font = monoFont(XRGAether7b.TypeScale.sm.size)
        pathField.textColor = XRGAether7b.Color.textMain(dark: dark)
        pathField.backgroundColor = XRGAether7b.Color.surfaceCard(dark: dark)
        pathField.isBordered = false
        rimView.addSubview(pathField)
        chooseButton.translatesAutoresizingMaskIntoConstraints = false
        chooseButton.style(background: nil, text: XRGAether7b.Color.textMain(dark: dark),
                           border: XRGAether7b.Color.borderStrong(dark: dark), dark: dark)
        addSubview(chooseButton)
        NSLayoutConstraint.activate([
            pathField.leadingAnchor.constraint(equalTo: rimView.leadingAnchor, constant: XRGAether7b.Space.s1),
            pathField.trailingAnchor.constraint(equalTo: rimView.trailingAnchor, constant: -XRGAether7b.Space.s1),
            pathField.centerYAnchor.constraint(equalTo: rimView.centerYAnchor),
            chooseButton.leadingAnchor.constraint(equalTo: rimView.trailingAnchor, constant: XRGAether7b.Space.s2),
            chooseButton.centerYAnchor.constraint(equalTo: pathField.centerYAnchor),
            rimView.widthAnchor.constraint(equalToConstant: 180), rimView.heightAnchor.constraint(equalToConstant: 26),
        ])
        chooseButton.target = self
        chooseButton.action = #selector(choose(_:))
    }
    @objc func choose(_ sender: Any?) { onChoose?(self) }
    public func userChose(url: URL) { present(.string(url.path)); submit(value()) }
}

// MARK: - Text

@MainActor public final class XRGSettingsTextControl: XRGSettingsEntryControl {
    public let textField = NSTextField()
    public override func value() -> XRGSettingsValue { .string(textField.stringValue) }
    public override func present(_ value: XRGSettingsValue) {
        guard case .string(let text) = value else { return }
        textField.stringValue = text
    }
    public override func themeDidChange(dark: Bool) {
        textField.textColor = XRGAether7b.Color.textMain(dark: dark)
        textField.backgroundColor = XRGAether7b.Color.surfaceCard(dark: dark)
    }
    public override init(entry: XRGSettingsEntry, dark: Bool) {
        super.init(entry: entry, dark: dark)
        textField.font = monoFont(XRGAether7b.TypeScale.sm.size)
        textField.textColor = XRGAether7b.Color.textMain(dark: dark)
        textField.backgroundColor = XRGAether7b.Color.surfaceCard(dark: dark)
        textField.isBordered = false
        rimView.addSubview(textField)
        NSLayoutConstraint.activate([
            textField.leadingAnchor.constraint(equalTo: rimView.leadingAnchor, constant: XRGAether7b.Space.s1),
            textField.trailingAnchor.constraint(equalTo: rimView.trailingAnchor, constant: -XRGAether7b.Space.s1),
            textField.centerYAnchor.constraint(equalTo: rimView.centerYAnchor),
            rimView.widthAnchor.constraint(greaterThanOrEqualToConstant: 150), rimView.heightAnchor.constraint(equalToConstant: 26),
        ])
        present(entry.defaultValue)
        textField.target = self
        textField.action = #selector(edited)
    }
    @objc func edited() { submit(value()) }
}

// MARK: - Source

/// A source picker fed by `XRGSettingsSourceProvider`: options grouped
/// (Identified / Unidentified / Suspected unused for temperature), an empty
/// first option meaning "none/automatic".
@MainActor public final class XRGSettingsSourceControl: XRGSettingsEntryControl {
    public let popUp = NSPopUpButton(frame: .zero, pullsDown: false)
    var optionValues: [String] = []
    public var optionLabels: [String] { popUp.itemArray.compactMap { $0.isEnabled ? $0.title : nil } }
    public override func value() -> XRGSettingsValue {
        if let value = popUp.selectedItem?.representedObject as? String {
            return value.isEmpty ? XRGSettingsValue.null : XRGSettingsValue.string(value)
        }
        return XRGSettingsValue.null
    }
    public override func present(_ value: XRGSettingsValue) {
        let current: String? = { if case .string(let text) = value { return text }; return nil }()
        popUp.selectItem(at: optionValues.firstIndex(where: { $0 == current }) ?? 0)
    }
    public override func themeDidChange(dark: Bool) {
        popUp.contentTintColor = XRGAether7b.Color.textMain(dark: dark)
    }
    public override init(entry: XRGSettingsEntry, dark: Bool) {
        super.init(entry: entry, dark: dark)
        popUp.translatesAutoresizingMaskIntoConstraints = false
        popUp.bezelStyle = .texturedRounded
        popUp.font = monoFont(XRGAether7b.TypeScale.sm.size)
        popUp.contentTintColor = XRGAether7b.Color.textMain(dark: dark)
        rimView.addSubview(popUp)
        NSLayoutConstraint.activate([
            popUp.leadingAnchor.constraint(equalTo: rimView.leadingAnchor, constant: XRGAether7b.Space.s1),
            popUp.trailingAnchor.constraint(equalTo: rimView.trailingAnchor, constant: -XRGAether7b.Space.s1),
            popUp.centerYAnchor.constraint(equalTo: rimView.centerYAnchor),
            rimView.widthAnchor.constraint(greaterThanOrEqualToConstant: 140), rimView.heightAnchor.constraint(equalToConstant: 26),
        ])
    }
    /// Fill the picker from the provider's options for this entry's kind.
    public func load(options: [(group: String, value: String, label: String)], noneLabel: String) {
        popUp.removeAllItems()
        optionValues = [""]
        popUp.addItem(withTitle: noneLabel)
        popUp.item(at: 0)?.representedObject = ""
        var lastGroup: String?
        var groupCount = 0
        for option in options where !option.value.isEmpty {
            if option.group != lastGroup {
                groupCount += 1
                if groupCount > 1, let group = option.group.nonEmpty {
                    popUp.addItem(withTitle: group)
                    popUp.lastItem?.isEnabled = false
                }
                lastGroup = option.group
            }
            popUp.addItem(withTitle: option.label)
            popUp.lastItem?.representedObject = option.value
            optionValues.append(option.value)
        }
        popUp.target = self
        popUp.action = #selector(picked(_:))
    }
    @objc func picked(_ sender: NSPopUpButton) { submit(value()) }
}

// MARK: - Action

/// A ghost action button (spec §5: Check for updates, Reset, Import,
/// Export): the entry's label is the button's title.
@MainActor public final class XRGSettingsActionControl: XRGSettingsEntryControl {
    public let button: XRGSettingsFlatButton
    public var onAction: ((XRGSettingsActionControl) -> Void)?
    public override func value() -> XRGSettingsValue { .null }
    public override func themeDidChange(dark: Bool) {
        button.style(background: nil, text: XRGAether7b.Color.textMain(dark: dark),
                     border: XRGAether7b.Color.borderStrong(dark: dark), dark: dark)
    }
    public override init(entry: XRGSettingsEntry, dark: Bool) {
        button = XRGSettingsFlatButton(title: entry.label)
        super.init(entry: entry, dark: dark)
        button.style(background: nil, text: XRGAether7b.Color.textMain(dark: dark),
                     border: XRGAether7b.Color.borderStrong(dark: dark), dark: dark)
        addSubview(button)
        NSLayoutConstraint.activate([
            button.leadingAnchor.constraint(equalTo: leadingAnchor),
            button.centerYAnchor.constraint(equalTo: centerYAnchor),
            topAnchor.constraint(equalTo: button.topAnchor),
            bottomAnchor.constraint(equalTo: button.bottomAnchor),
        ])
        button.onClick = { [weak self] in
            guard let self else { return }
            self.onAction?(self)
        }
    }
}

// MARK: - Small helpers

extension String {
    var nilIfEmpty: String? { isEmpty ? nil : self }
    var nonEmpty: String? { isEmpty ? nil : self }
}

extension XRGSettingsValue {
    var isTextualDescription: String {
        switch self {
        case .bool(let flag): return flag ? "on" : "off"
        case .int(let number): return String(number)
        case .double(let number): return number == number.rounded() ? String(Int(number)) : String(number)
        case .string(let text): return text
        case .color: return "color"
        case .null: return "none"
        }
    }
}