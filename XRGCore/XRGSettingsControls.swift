// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Stephen de la Vega.
//
// One AppKit view per catalog control type (0.2.3 spec §5), styled only
// with Aether7b tokens: colours from `XRGAether7b.Color`, sizes from its
// type scale and spacing, radii from `XRGAether7b.Radius` — including the
// generated `pill` radius for the toggle's track and knob. Every colour
// any of these views sets — layer background, border, text, focus halo —
// is a token colour (or the colour-well content the user picked), which
// `onlyAether7bColours` walks and checks. Every interactive control has
// the complete interaction contract: mouse, keyboard (Tab/Shift-Tab to
// move, Space/Return to activate) and accessibility activation
// (`accessibilityPerformPress`), with the 2 px Carolina focus halo drawn
// from tokens instead of a native focus ring.

import AppKit

/// The Aether7b colour palette as one flat list per appearance, plus the
/// membership test the window's token-only rule is asserted with.
@MainActor public enum XRGAether7bPalette {
    /// The 2 px Carolina focus halo (the mockup's `--a7b-focus-ring`: the
    /// generated carolinaWeb token at the mockup's 0.35 halo alpha), and
    /// the Carolina rim colour focus turns on (the mockup's focus-visible
    /// border).
    public static let focusHalo = XRGAether7b.Color.carolinaWeb.withAlphaComponent(0.35)
    public static let focusBorder = XRGAether7b.Color.carolinaClassic

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
            // The window background washes the canvas with the token; keep the
            // pure canvas and a 3%-lighter wash both legal (the aurora orb).
            XRGAether7b.Color.bgCanvas(dark: dark).withAlphaComponent(1),
        ]
        // Derived values the design language names but the token file keeps
        // as composites: the focus halo (carolinaWeb at the mockup's halo
        // alpha) and the aurora wash's transparent endpoint (the orb token
        // fading to nothing, exactly the CSS blur's outer edge).
        values.append(focusHalo)
        values.append(XRGAether7b.Color.orb(dark: dark).withAlphaComponent(0))
        values.append(XRGAether7b.Color.obsidian.withAlphaComponent(0))
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
        case .carolinaClassic: return XRGAether7b.Color.carolinaClassic
        }
    }
    public enum Token { case bgCanvas, surfaceCard, accentTint, statusDanger, statusWarning, borderStrong, carolinaClassic }

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
/// edits, an enabled state that follows `depends` (and propagates to the
/// real widgets and the accessibility element), and the danger rim, dot
/// and mono reason label an invalid entry shows (spec §5: nothing else
/// turns red, and an invalid value is never saved). The rim carries the
/// 2 px Carolina focus halo whenever the control's editable widget holds
/// keyboard focus.
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
    /// The 7 pt danger dot beside the reason (the mockup's status dot).
    let dotView = NSView()
    private(set) var errorReason: String?
    public private(set) var isEnabledControl = true
    /// Whether the entry's `depends` requirement holds for this control.
    public var isEnabled: Bool { isEnabledControl }
    /// The rim (container border) the control sits in.
    let rimView = NSView()
    /// The 2 px Carolina halo drawn around the rim when focused.
    let haloLayer = CALayer()
    /// Whether the control's widget currently holds keyboard focus.
    public private(set) var isFocusedControl = false
    /// A read-only display control (ruling P3's font field): the flag is an
    /// enduring property of the control itself, so the `depends`-driven
    /// enablement path can never re-open the widget for edits (finding N4 —
    /// any settings notification used to make the font display editable).
    public var isReadOnlyDisplay = false
    /// Constraints keeping the control sized while no error shows.
    private var idleConstraints: [NSLayoutConstraint] = []
    /// Constraints spreading the rim + dot + reason when an error shows.
    private var errorConstraints: [NSLayoutConstraint] = []

    public init(entry: XRGSettingsEntry, dark: Bool) {
        self.entry = entry
        self.isDarkAppearance = dark
        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false
        setAccessibilityLabel(entry.label)
        setAccessibilityEnabled(true)
        toolTip = entry.help
        identifier = NSUserInterfaceItemIdentifier(entry.id)
        rimView.translatesAutoresizingMaskIntoConstraints = false
        rimView.wantsLayer = true
        rimView.layer?.cornerRadius = XRGAether7b.Radius.md
        rimView.layer?.borderColor = XRGAether7b.Color.borderStrong(dark: dark).cgColor
        rimView.layer?.borderWidth = 1
        addSubview(rimView)
        haloLayer.borderWidth = 2
        haloLayer.borderColor = XRGAether7bPalette.focusHalo.cgColor
        haloLayer.cornerRadius = XRGAether7b.Radius.md + 2
        haloLayer.isHidden = true
        rimView.layer?.addSublayer(haloLayer)
        reasonLabel.translatesAutoresizingMaskIntoConstraints = false
        reasonLabel.identifier = NSUserInterfaceItemIdentifier("reason-\(entry.id)")
        reasonLabel.font = monoFont(XRGAether7b.TypeScale.xs.size)
        reasonLabel.textColor = XRGAether7b.Color.statusDanger(dark: dark)
        reasonLabel.stringValue = ""
        reasonLabel.isHidden = true
        addSubview(reasonLabel)
        dotView.translatesAutoresizingMaskIntoConstraints = false
        dotView.wantsLayer = true
        dotView.layer?.backgroundColor = XRGAether7b.Color.statusDanger(dark: dark).cgColor
        // The mockup's status dot is a 7 pt pill: the CSS-clamped radius,
        // never the raw 9999 token (W1).
        dotView.layer?.cornerRadius = XRGAether7bStyle.pillRadius(for: CGSize(width: 7, height: 7))
        dotView.isHidden = true
        dotView.setAccessibilityHidden(true)
        addSubview(dotView)
        NSLayoutConstraint.activate([
            rimView.leadingAnchor.constraint(equalTo: leadingAnchor),
            rimView.topAnchor.constraint(equalTo: topAnchor),
        ])
        // While no error shows, the control ends at the rim; while one does,
        // it ends at the reason label instead (the pair is swapped in
        // `showError`).
        idleConstraints = [bottomAnchor.constraint(equalTo: rimView.bottomAnchor)]
        let reasonWidth = reasonLabel.widthAnchor.constraint(greaterThanOrEqualToConstant: 180)
        reasonWidth.priority = .dragThatCanResizeWindow
        errorConstraints = [
            reasonLabel.topAnchor.constraint(equalTo: rimView.bottomAnchor, constant: XRGAether7b.Space.s1),
            reasonLabel.leadingAnchor.constraint(equalTo: dotView.trailingAnchor, constant: XRGAether7b.Space.s2),
            reasonLabel.trailingAnchor.constraint(lessThanOrEqualTo: trailingAnchor, constant: XRGAether7b.Space.s6),
            dotView.leadingAnchor.constraint(equalTo: rimView.leadingAnchor, constant: XRGAether7b.Space.s1),
            dotView.widthAnchor.constraint(equalToConstant: 7), dotView.heightAnchor.constraint(equalToConstant: 7),
            dotView.centerYAnchor.constraint(equalTo: reasonLabel.firstBaselineAnchor, constant: -2),
            bottomAnchor.constraint(equalTo: reasonLabel.bottomAnchor),
            reasonWidth,
        ]
        NSLayoutConstraint.activate(idleConstraints)
    }
    @available(*, unavailable) required init?(coder: NSCoder) { fatalError("Programmatic view") }

    public override func layout() {
        super.layout()
        let inset = -2.0
        haloLayer.frame = rimView.bounds.insetBy(dx: inset, dy: inset)
        // Pill radii are re-clamped at layout time (W1): a layer whose size
        // changed can never keep a degenerate 9999 pt radius.
        dotView.layer?.cornerRadius = XRGAether7bStyle.pillRadius(for: dotView.bounds.size)
    }

    // MARK: Theme plumbing

    /// The rim colour (the container border), for the danger-rim checks.
    public var rimColor: NSColor? { rimView.layer?.borderColor.flatMap { NSColor(cgColor: $0) } }
    public func applyAppearance(dark: Bool) {
        isDarkAppearance = dark
        reasonLabel.textColor = XRGAether7b.Color.statusDanger(dark: dark)
        dotView.layer?.backgroundColor = XRGAether7b.Color.statusDanger(dark: dark).cgColor
        rimColor(dark: dark)
        themeDidChange(dark: dark)
    }
    func rimColor(dark: Bool) {
        let color: NSColor
        if errorReason != nil {
            color = XRGAether7bPalette.color(.statusDanger, dark: dark)
        } else if isFocusedControl {
            color = XRGAether7bPalette.color(.carolinaClassic, dark: dark)
        } else {
            color = XRGAether7b.Color.borderStrong(dark: dark)
        }
        rimView.layer?.borderColor = color.cgColor
    }
    /// Subclasses restyle their widgets here.
    public func themeDidChange(dark: Bool) {}

    // MARK: State

    /// Show the store's value without applying anything (silent refresh).
    public func present(_ value: XRGSettingsValue) {}
    /// Enable or disable following the entry's `depends`: the wrapper's
    /// state, the real widgets' editability and the accessibility
    /// element's enabled state all follow, and edits are refused while
    /// disabled.
    public func setEnabled(_ enabled: Bool) {
        isEnabledControl = enabled
        alphaValue = enabled ? 1 : 0.45
        setAccessibilityEnabled(enabled)
        enabledDidChange(enabled)
    }
    public func enabledDidChange(_ enabled: Bool) {}
    /// Show the danger rim, dot and mono reason for an invalid entry, or
    /// clear them. The reason is constrained to stay visible under the
    /// rim: dot and label sit on their own row.
    public func showError(_ reason: String?) {
        let changed = errorReason != reason
        errorReason = reason
        if reason == nil {
            reasonLabel.isHidden = true
            dotView.isHidden = true
            if changed {
                NSLayoutConstraint.deactivate(errorConstraints)
                NSLayoutConstraint.activate(idleConstraints)
            }
        } else {
            reasonLabel.stringValue = reason ?? ""
            reasonLabel.isHidden = false
            dotView.isHidden = false
            if changed {
                NSLayoutConstraint.deactivate(idleConstraints)
                NSLayoutConstraint.activate(errorConstraints)
            }
        }
        if changed { needsUpdateConstraints = true }
        rimColor(dark: isDarkAppearance)
    }
    /// Drive the apply path with a value the widget produced; disabled
    /// controls never submit.
    func submit(_ value: XRGSettingsValue) {
        guard isEnabledControl else { return }
        applyEdit?(self, value)
    }

    // MARK: Focus

    /// Report that the control's editable widget gained or lost keyboard
    /// focus; the rim shows the 2 px Carolina halo while focused.
    func setFocused(_ focused: Bool) {
        guard focused != isFocusedControl else { return }
        isFocusedControl = focused
        haloLayer.isHidden = !focused
        rimColor(dark: isDarkAppearance)
        setAccessibilityFocused(focused)
    }

    /// The views that accept keyboard focus, in Tab order (review issue 4:
    /// the window wires these into its key-view loop). The base control
    /// itself takes no focus; subclasses name their widgets.
    public func focusableViews() -> [NSView] { [] }
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

    /// The corner radius a pill layer actually draws (W1): CSS clamps
    /// `border-radius` to half the box's shortest side, so the mockup's
    /// 9999 px pill token on a 34×20 track *is* 10 pt there — and the raw
    /// 9999 value degenerates the bitmap renderer (`cacheDisplay`, the
    /// snapshot path) into one uniform fill covering the whole capture.
    /// Every pill layer therefore draws this clamped radius, refreshed at
    /// layout time so a resized layer can never regress.
    static func pillRadius(for size: CGSize) -> CGFloat {
        max(0, min(size.width, size.height) / 2)
    }


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
    /// A mono editable field: no native focus ring — the enclosing rim
    /// draws the token focus halo instead.
    static func field(_ dark: Bool) -> XRGSettingsField {
        let field = XRGSettingsField()
        field.font = monoFont(XRGAether7b.TypeScale.sm.size)
        field.textColor = XRGAether7b.Color.textMain(dark: dark)
        field.backgroundColor = XRGAether7b.Color.surfaceCard(dark: dark)
        field.isBordered = false
        field.focusRingType = .none
        field.translatesAutoresizingMaskIntoConstraints = false
        return field
    }
}

/// A mono settings field that reports keyboard focus to its owning
/// control, so the rim can draw the token focus halo (the native focus
/// ring is off).
@MainActor public final class XRGSettingsField: NSTextField {
    weak var focusOwner: XRGSettingsEntryControl?
    public override func becomeFirstResponder() -> Bool {
        let accepted = super.becomeFirstResponder()
        if accepted { focusOwner?.setFocused(true) }
        return accepted
    }
    public override func resignFirstResponder() -> Bool {
        let resigned = super.resignFirstResponder()
        if resigned { focusOwner?.setFocused(false) }
        return resigned
    }
}

/// The mockup's token slider (issue 9: control chrome is not exempt):
/// macOS 26's NSSlider is SwiftUI-hosted and composites its own
/// system-tinted track layers — no public API restyles them — so the
/// window draws its slider itself: an accent-tint track, an accent-fill
/// progress portion and a pill knob, all token colours, with the keyboard
/// contract (arrows step by the entry's catalog step, Shift ×10) and
/// accessibility increment/decrement. The focus treatment is the 2 px
/// Carolina halo drawn from tokens.
@MainActor public final class XRGSettingsSliderView: NSControl {
    public var minValue: Double = 0
    public var maxValue: Double = 1
    /// The keyboard and accessibility step: the entry's catalog step.
    public var increment: Double = 0.1
    private let trackLayer = CALayer()
    private let fillLayer = CALayer()
    private let knobLayer = CALayer()
    private let haloLayer = CALayer()
    private var isDarkAppearance = false
    private var isDragging = false
    private var internalValue: Double = 0
    public private(set) var isFocused = false

    /// NSControl's own double-value slot, bridged to the internal value
    /// the track draws.
    public override var doubleValue: Double {
        get { internalValue }
        set {
            internalValue = min(maxValue, max(minValue, newValue))
            layoutSlider()
        }
    }

    public init(dark: Bool) {
        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false
        isDarkAppearance = dark
        wantsLayer = true
        for layer in [trackLayer, fillLayer, knobLayer] { self.layer?.addSublayer(layer) }
        haloLayer.borderWidth = 2
        haloLayer.borderColor = XRGAether7bPalette.focusHalo.cgColor
        haloLayer.isHidden = true
        self.layer?.addSublayer(haloLayer)
        setAccessibilityRole(.slider)
        focusRingType = .none
        restyle()
    }
    @available(*, unavailable) required init?(coder: NSCoder) { fatalError("Programmatic view") }

    /// Restyle from the token palette for this appearance.
    public func applyAppearance(dark: Bool) {
        isDarkAppearance = dark
        restyle()
    }
    private func restyle() {
        trackLayer.backgroundColor = XRGAether7b.Color.accentTint(dark: isDarkAppearance).cgColor
        fillLayer.backgroundColor = XRGAether7b.Color.accentFill(dark: isDarkAppearance).cgColor
        knobLayer.backgroundColor = XRGAether7b.Color.accentFill(dark: isDarkAppearance).cgColor
        knobLayer.borderColor = XRGAether7b.Color.iceSpecular.cgColor
        knobLayer.borderWidth = 1
    }

    public override var acceptsFirstResponder: Bool { isEnabled }
    public override func becomeFirstResponder() -> Bool {
        isFocused = true
        haloLayer.isHidden = false
        setAccessibilityFocused(true)
        layoutSlider()
        return true
    }
    public override func resignFirstResponder() -> Bool {
        isFocused = false
        haloLayer.isHidden = true
        setAccessibilityFocused(false)
        layoutSlider()
        return true
    }

    public override func layout() {
        super.layout()
        layoutSlider()
    }

    /// The track, its played portion and the pill knob — every radius is
    /// the CSS-clamped pill (W1), never the raw token.
    private func layoutSlider() {
        let trackHeight: CGFloat = 4
        let knobSize: CGFloat = 14
        let bounds = self.bounds
        guard bounds.width > knobSize, bounds.height >= knobSize else { return }
        let centerY = bounds.midY
        trackLayer.frame = CGRect(x: 0, y: centerY - trackHeight / 2, width: bounds.width, height: trackHeight)
        trackLayer.cornerRadius = XRGAether7bStyle.pillRadius(for: trackLayer.bounds.size)
        let span = max(0.001, maxValue - minValue)
        let fraction = max(0, min(1, (internalValue - minValue) / span))
        let fillWidth = max(0, (bounds.width - knobSize) * fraction)
        fillLayer.frame = CGRect(x: knobSize / 2, y: centerY - trackHeight / 2, width: fillWidth, height: trackHeight)
        fillLayer.cornerRadius = XRGAether7bStyle.pillRadius(for: fillLayer.bounds.size)
        let knobX = knobSize / 2 + (bounds.width - knobSize) * fraction
        knobLayer.frame = CGRect(x: knobX - knobSize / 2, y: centerY - knobSize / 2, width: knobSize, height: knobSize)
        knobLayer.cornerRadius = XRGAether7bStyle.pillRadius(for: knobLayer.bounds.size)
        let inset = -2.0
        haloLayer.frame = bounds.insetBy(dx: inset, dy: inset)
        haloLayer.cornerRadius = XRGAether7bStyle.pillRadius(for: haloLayer.bounds.size)
    }

    private func value(at point: NSPoint) -> Double {
        let span = max(0.001, maxValue - minValue)
        let usable = max(1, bounds.width - 14)
        let x = min(max(0, point.x - 7), usable)
        return minValue + (x / usable) * span
    }
    private func submit() {
        if let action, let target { NSApp.sendAction(action, to: target, from: self) }
    }

    // The whole slider is its own hit target.
    public override func hitTest(_ point: NSPoint) -> NSView? {
        guard isEnabled else { return nil }
        let local = superview.map { convert(point, from: $0) } ?? point
        return bounds.contains(local) ? self : nil
    }

    public override func mouseDown(with event: NSEvent) {
        guard isEnabled else { return }
        isDragging = true
        doubleValue = value(at: convert(event.locationInWindow, from: nil))
        submit()
    }
    public override func mouseDragged(with event: NSEvent) {
        guard isEnabled, isDragging else { return }
        doubleValue = value(at: convert(event.locationInWindow, from: nil))
        submit()
    }
    public override func mouseUp(with event: NSEvent) {
        isDragging = false
    }

    public override func keyDown(with event: NSEvent) {
        guard isEnabled else { super.keyDown(with: event); return }
        switch event.specialKey {
        case .leftArrow, .downArrow, .rightArrow, .upArrow:
            // A held arrow keeps adjusting: repeated key-down events ARE
            // the keyboard's "keep going", and the pre-fix rejection froze
            // the value after the first step (review, slider parity).
            let step = event.modifierFlags.contains(.shift) ? increment * 10 : increment
            if event.specialKey == .leftArrow || event.specialKey == .downArrow {
                doubleValue = internalValue - step
            } else {
                doubleValue = internalValue + step
            }
            submit()
        case .tab:
            guard !event.isARepeat else { return }
            // Explicit key-view chain, skipping ineligible targets (see the
            // flat button's note).
            settingsAdvanceFocus(forward: !event.modifierFlags.contains(.shift))
        default:
            super.keyDown(with: event)
        }
    }

    // MARK: Accessibility (review, slider parity)
    // A plain NSControl provides none of the slider's numbers by default:
    // the element reports a NUMERIC value with explicit min and max bounds
    // and the horizontal orientation, instead of a formatted string with
    // no bounds for VoiceOver to announce.
    public override func accessibilityValue() -> Any? { NSNumber(value: internalValue) }
    public override func accessibilityMinValue() -> Any? { NSNumber(value: minValue) }
    public override func accessibilityMaxValue() -> Any? { NSNumber(value: maxValue) }
    public override func accessibilityOrientation() -> NSAccessibilityOrientation { .horizontal }

    public override func accessibilityPerformIncrement() -> Bool {
        guard isEnabled else { return false }
        doubleValue = internalValue + increment
        submit()
        return true
    }
    public override func accessibilityPerformDecrement() -> Bool {
        guard isEnabled else { return false }
        doubleValue = internalValue - increment
        submit()
        return true
    }
}

@MainActor func monoFont(_ size: CGFloat) -> NSFont { XRGAether7bStyle.monoFont(size) }

/// A flat token-styled button: a layer-backed plain view with a label, no
/// bezel (macOS 26's SwiftUI-backed NSButtons churn Attribute Graph under
/// the window's re-render churn). The complete interaction contract is
/// implemented here: a real mouse click (down inside, up inside), the
/// keyboard contract (Space, Return and Enter activate; Tab and
/// Shift-Tab move focus through the window's key-view loop) and
/// accessibility activation (`accessibilityPerformPress`). While focused
/// the button draws the 2 px Carolina halo from tokens.
@MainActor public final class XRGSettingsFlatButton: NSControl {
    public let labelField = NSTextField(labelWithString: "")
    var onClick: (() -> Void)?
    /// Whether the button is currently pressed (mouse or key held down).
    private(set) var isPressed = false
    private let haloLayer = CALayer()
    /// Whether the button currently holds keyboard focus.
    public private(set) var isFocused = false
    private var baseStyle: (background: NSColor?, text: NSColor, border: NSColor?)?

    public init(title: String, verticalPadding: CGFloat = XRGAether7b.Space.s2, onClick: (() -> Void)? = nil) {
        self.onClick = onClick
        super.init(frame: .zero)
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
            topAnchor.constraint(equalTo: labelField.topAnchor, constant: -verticalPadding),
            bottomAnchor.constraint(equalTo: labelField.bottomAnchor, constant: verticalPadding),
        ])
        haloLayer.borderWidth = 2
        haloLayer.borderColor = XRGAether7bPalette.focusHalo.cgColor
        haloLayer.cornerRadius = XRGAether7b.Radius.sm + 2
        haloLayer.isHidden = true
        layer?.addSublayer(haloLayer)
        setAccessibilityLabel(title)
        setAccessibilityRole(.button)
        // The token halo is the focus treatment: the button is a plain
        // layer-backed NSControl with no cell, so no cell machinery can
        // draw a native focus ring or bezel.
        focusRingType = .none
    }
    @available(*, unavailable) required init?(coder: NSCoder) { fatalError("Programmatic view") }

    public override func layout() {
        super.layout()
        haloLayer.frame = bounds.insetBy(dx: -2, dy: -2)
    }

    // The whole button is its own hit target: the label is a subview that
    // would otherwise swallow the click. The point arrives in the
    // SUPerview's coordinate system (NSView.hitTest's documented contract,
    // verified: a leaf at (50, 30) receives the click in its superview's
    // coordinates), so it must be converted before the bounds check —
    // the pre-fix comparison rejected every correctly placed click on a
    // nonzero-origin button (finding N1: later sidebar buttons, later
    // segments, row controls).
    public override func hitTest(_ point: NSPoint) -> NSView? {
        guard isEnabled else { return nil }
        let local = superview.map { convert(point, from: $0) } ?? point
        return bounds.contains(local) ? self : nil
    }

    // MARK: Activation

    /// The single activation path: mouse, keyboard and accessibility all
    /// land here. Kept as the programmatic/test seam `performClick` uses.
    public func performClick() {
        guard isEnabled else { return }
        onClick?()
    }
    public override func performClick(_ sender: Any?) { performClick() }
    @objc func clicked(_ sender: Any?) { performClick() }

    // MARK: Mouse

    public override func mouseDown(with event: NSEvent) {
        guard isEnabled else { return }
        isPressed = true
        restyle()
    }
    public override func mouseUp(with event: NSEvent) {
        let pressed = isPressed
        isPressed = false
        restyle()
        guard pressed, isEnabled else { return }
        let point = convert(event.locationInWindow, from: nil)
        if bounds.contains(point) { performClick() }
    }

    // MARK: Keyboard

    public override var acceptsFirstResponder: Bool { isEnabled }
    public override func keyDown(with event: NSEvent) {
        guard isEnabled else { super.keyDown(with: event); return }
        if event.isARepeat { return }
        switch event.characters {
        case " ", "\r", "\n":
            isPressed = true
            restyle()
            performClick()
            isPressed = false
            restyle()
        case "\t":
            // The window's key-view loop is explicit (wireKeyViewLoop), so
            // Tab walks it directly — to the next view that can actually
            // TAKE focus. NSWindow.selectKeyView(following:) consults the
            // auto-recalculated geometric loop instead and lands on
            // unrelated controls (probed: an order-row button's Tab jumped
            // to the section's first text field), and the pre-fix walk
            // handed focus to the IMMEDIATE neighbour and stalled whenever
            // that neighbour was disabled — the reorder chain keeps the
            // disabled first Move up and last Move down wired in, and a
            // `depends` flip can disable any control after the wiring ran.
            settingsAdvanceFocus(forward: !event.modifierFlags.contains(.shift))
        default:
            super.keyDown(with: event)
        }
    }

    // MARK: Accessibility

    public override func accessibilityPerformPress() -> Bool {
        guard isEnabled else { return false }
        performClick()
        return true
    }

    // MARK: Focus

    public override func becomeFirstResponder() -> Bool {
        isFocused = true
        haloLayer.isHidden = false
        restyle()
        setAccessibilityFocused(true)
        return true
    }
    public override func resignFirstResponder() -> Bool {
        isFocused = false
        haloLayer.isHidden = true
        restyle()
        setAccessibilityFocused(false)
        return true
    }

    /// Style from tokens: `background` nil means transparent. A non-nil
    /// border keeps the ghost look; focus turns the border Carolina and
    /// adds the halo. Pressing shows the accent tint.
    public func style(background: NSColor?, text: NSColor, border: NSColor?, dark: Bool) {
        baseStyle = (background, text, border)
        applyStyle()
        labelField.textColor = text
    }
    private func restyle() { applyStyle() }
    private func applyStyle() {
        let base = baseStyle
        let pressed = isPressed ? XRGAether7b.Color.accentTint(dark: XRGAether7bPalette.isDark(self)) : base?.background
        layer?.backgroundColor = pressed?.cgColor
        layer?.borderColor = base?.border?.cgColor
        layer?.borderWidth = base?.border == nil ? 0 : 1
        layer?.cornerRadius = XRGAether7b.Radius.sm
        // Focus draws its own Carolina border and halo, over the base style.
        if isFocused {
            layer?.borderColor = base?.border?.cgColor ?? XRGAether7bPalette.focusBorder.cgColor
            layer?.borderWidth = 1
        }
    }
}
@MainActor func sansFont(_ size: CGFloat, weight: NSFont.Weight = .regular) -> NSFont { XRGAether7bStyle.sansFont(size, weight: weight) }

/// A borderless token-styled pop-up: no system bezel (the rim provides
/// the border), mono type, the native focus ring replaced by the rim's
/// token focus halo. The closed pop-up's title is drawn by a private
/// `NSButtonTextField` in the system label colour by default — the one
/// piece of control chrome AppKit composites inside the button (issue 9:
/// control chrome is not exempt), so the window restyles it from tokens
/// whenever the pop-up realizes, selects or re-themes.
@MainActor public final class XRGSettingsPopUpButton: NSPopUpButton {
    weak var focusOwner: XRGSettingsEntryControl?
    private var titleDark = false

    public override func becomeFirstResponder() -> Bool {
        let accepted = super.becomeFirstResponder()
        if accepted { focusOwner?.setFocused(true) }
        return accepted
    }
    public override func resignFirstResponder() -> Bool {
        let resigned = super.resignFirstResponder()
        if resigned { focusOwner?.setFocused(false) }
        return resigned
    }

    /// Style the title from the token palette for this appearance. Called
    /// by the owning control at build time and on every theme change; the
    /// pop-up reapplies on its own whenever AppKit rebuilds the internal
    /// text field or moves it into the window.
    func applyTitleColour(dark: Bool) {
        titleDark = dark
        restyleTitleFields()
    }
    private func restyleTitleFields() {
        for case let field as NSTextField in subviews {
            field.textColor = XRGAether7b.Color.textMain(dark: titleDark)
        }
    }
    public override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        restyleTitleFields()
    }
    public override func layout() {
        super.layout()
        // The internal title field is created and reconfigured lazily, so
        // every layout pass restyles it: the audit reads the property after
        // layout, and the draw follows the field's own colour.
        restyleTitleFields()
    }
    public override func selectItem(at index: Int) {
        super.selectItem(at: index)
        restyleTitleFields()
    }
    public override func select(_ item: NSMenuItem?) {
        super.select(item)
        restyleTitleFields()
    }
    public override func selectItem(withTitle title: String) {
        super.selectItem(withTitle: title)
        restyleTitleFields()
    }
}

// MARK: - Toggle

/// The mockup's pill toggle: a 34×20 track on the strong rim, knob 14 pt,
/// both corners the generated `pill` radius. Activates by mouse, by
/// keyboard (Space/Return) and by accessibility press, and reports its
/// checked state to VoiceOver.
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

    public override init(entry: XRGSettingsEntry, dark: Bool) {
        super.init(entry: entry, dark: dark)
        translatesAutoresizingMaskIntoConstraints = false
        trackView.translatesAutoresizingMaskIntoConstraints = false
        trackView.wantsLayer = true
        // The mockup's pill track: the CSS-clamped radius (10 pt on a
        // 34×20 track), never the raw 9999 token (W1 — the bitmap path
        // degenerates on it and paints the whole capture one colour).
        trackView.layer?.cornerRadius = XRGAether7bStyle.pillRadius(for: CGSize(width: 34, height: 20))
        trackView.layer?.borderWidth = 1
        knobView.translatesAutoresizingMaskIntoConstraints = false
        knobView.wantsLayer = true
        knobView.layer?.cornerRadius = XRGAether7bStyle.pillRadius(for: CGSize(width: 14, height: 14))
        trackView.addSubview(knobView)
        addSubview(trackView)
        setAccessibilityRole(.checkBox)
        present(entry.defaultValue)
        NSLayoutConstraint.activate([
            trackView.widthAnchor.constraint(equalToConstant: 34), trackView.heightAnchor.constraint(equalToConstant: 20),
            trackView.centerYAnchor.constraint(equalTo: rimView.centerYAnchor),
            trackView.leadingAnchor.constraint(equalTo: rimView.leadingAnchor, constant: XRGAether7b.Space.s2),
            rimView.widthAnchor.constraint(equalToConstant: 50), rimView.heightAnchor.constraint(equalToConstant: 24),
            // The wrapper's trailing edge IS the visible switch (V5): the
            // row pins this edge to its own trailing edge, so every switch
            // lands in one right-hand column — a wrapper of unbound width
            // left the rim floating at its leading edge.
            rimView.trailingAnchor.constraint(equalTo: trailingAnchor),
        ])
        layoutTrack()
    }

    public override func layout() {
        super.layout()
        // Pill radii are re-clamped at layout time (W1): a resized track or
        // knob can never keep a degenerate radius.
        trackView.layer?.cornerRadius = XRGAether7bStyle.pillRadius(for: trackView.bounds.size)
        knobView.layer?.cornerRadius = XRGAether7bStyle.pillRadius(for: knobView.bounds.size)
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

    // The whole control is its own hit target: the knob and track are
    // subviews that would otherwise swallow the click. The point arrives in
    // the superview's coordinate system (finding N1), so it is converted
    // before the bounds check — the pre-fix comparison rejected clicks on
    // any toggle not sitting at its row's origin.
    public override func hitTest(_ point: NSPoint) -> NSView? {
        guard isEnabledControl else { return nil }
        let local = superview.map { convert(point, from: $0) } ?? point
        return bounds.contains(local) ? self : nil
    }

    // The whole control is the focusable element: keyboard focus moves
    // the rim's halo, Space/Return flips the switch.
    public override var acceptsFirstResponder: Bool { isEnabledControl }
    public override func becomeFirstResponder() -> Bool { setFocused(true); return true }
    public override func resignFirstResponder() -> Bool { setFocused(false); return true }
    public override func keyDown(with event: NSEvent) {
        guard isEnabledControl, !event.isARepeat else { super.keyDown(with: event); return }
        switch event.characters {
        case " ", "\r", "\n":
            click()
        case "\t":
            // Explicit chain, skipping ineligible targets (see the flat
            // button's note).
            settingsAdvanceFocus(forward: !event.modifierFlags.contains(.shift))
        default:
            super.keyDown(with: event)
        }
    }
    public override func accessibilityPerformPress() -> Bool {
        guard isEnabledControl else { return false }
        click()
        return true
    }
    public override func mouseDown(with event: NSEvent) {}
    public override func mouseUp(with event: NSEvent) {
        guard isEnabledControl else { return }
        let point = convert(event.locationInWindow, from: nil)
        if bounds.contains(point) { click() }
    }
    /// The same path a real click takes (tests use this directly).
    public func click() {
        guard isEnabledControl else { return }
        present(.bool(!isOn))
        submit(value())
    }
    public override func focusableViews() -> [NSView] { isEnabledControl ? [self] : [] }
}

// MARK: - Choice

/// A choice menu inside the rim: borderless pop-up (no system bezel —
/// the rim is the border), mono type, token text.
@MainActor public final class XRGSettingsChoiceControl: XRGSettingsEntryControl {
    public let popUp = XRGSettingsPopUpButton(frame: .zero, pullsDown: false)
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
        popUp.applyTitleColour(dark: dark)
    }
    public override func enabledDidChange(_ enabled: Bool) { popUp.isEnabled = enabled }

    public override init(entry: XRGSettingsEntry, dark: Bool) {
        super.init(entry: entry, dark: dark)
        options = entry.options ?? []
        popUp.translatesAutoresizingMaskIntoConstraints = false
        popUp.isBordered = false
        popUp.focusRingType = .none
        popUp.font = monoFont(XRGAether7b.TypeScale.sm.size)
        popUp.contentTintColor = XRGAether7b.Color.textMain(dark: dark)
        popUp.applyTitleColour(dark: dark)
        popUp.addItems(withTitles: options.map(\.label))
        for (index, option) in options.enumerated() { popUp.item(at: index)?.toolTip = option.value.isTextualDescription }
        popUp.focusOwner = self
        rimView.addSubview(popUp)
        NSLayoutConstraint.activate([
            popUp.leadingAnchor.constraint(equalTo: rimView.leadingAnchor, constant: XRGAether7b.Space.s1),
            popUp.trailingAnchor.constraint(equalTo: rimView.trailingAnchor, constant: -XRGAether7b.Space.s1),
            popUp.centerYAnchor.constraint(equalTo: rimView.centerYAnchor),
            rimView.widthAnchor.constraint(greaterThanOrEqualToConstant: 120), rimView.heightAnchor.constraint(equalToConstant: 26),
            // The wrapper closes around the rim (V2): the row's trailing
            // alignment then lands on the visible menu.
            rimView.trailingAnchor.constraint(equalTo: trailingAnchor),
        ])
        present(entry.defaultValue)
        popUp.target = self
        popUp.action = #selector(selected(_:))
    }
    @objc func selected(_ sender: NSPopUpButton) { submit(value()) }
    public override func focusableViews() -> [NSView] { [popUp] }
}

// MARK: - Segmented

/// The mockup's segmented control: one flat button per option, the
/// selected one on the accent tint with accent text. The rim's height
/// follows the buttons (a fixed height clipped their labels).
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
    public override func enabledDidChange(_ enabled: Bool) {
        for button in buttons { button.isEnabled = enabled }
    }

    public override init(entry: XRGSettingsEntry, dark: Bool) {
        super.init(entry: entry, dark: dark)
        options = entry.options ?? []
        var previous: NSView = rimView
        for (index, option) in options.enumerated() {
            let button = XRGSettingsFlatButton(title: option.label, verticalPadding: XRGAether7b.Space.s1) { [weak self] in
                self?.pickedSegment(index)
            }
            button.labelField.font = sansFont(XRGAether7b.TypeScale.xs.size)
            button.setAccessibilityLabel("\(entry.label): \(option.label)")
            rimView.addSubview(button)
            buttons.append(button)
            let leading = previous == rimView
                ? button.leadingAnchor.constraint(equalTo: rimView.leadingAnchor, constant: XRGAether7b.Space.s1)
                : button.leadingAnchor.constraint(equalTo: previous.trailingAnchor)
            NSLayoutConstraint.activate([
                leading,
                button.centerYAnchor.constraint(equalTo: rimView.centerYAnchor),
                button.topAnchor.constraint(greaterThanOrEqualTo: rimView.topAnchor, constant: 2),
                rimView.bottomAnchor.constraint(greaterThanOrEqualTo: button.bottomAnchor, constant: 2),
            ])
            previous = button
        }
        if let last = buttons.last {
            rimView.trailingAnchor.constraint(equalTo: last.trailingAnchor, constant: XRGAether7b.Space.s1).isActive = true
        }
        // The wrapper closes around the rim (V2): the row's trailing
        // alignment then lands on the visible segments.
        rimView.trailingAnchor.constraint(equalTo: trailingAnchor).isActive = true
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
    public override func focusableViews() -> [NSView] { buttons }
}

// MARK: - Number (integer, decimal, duration)

/// The catalog's "no meaningful upper bound" sentinel: the maximum a JSON
/// whole number can carry without losing precision. A range whose max is
/// the sentinel has no real upper bound to show, so the control shows no
/// range text at all (fix V4).
@MainActor enum XRGSettingsNumberControlConstants {
    static let unboundedMaximum = 9_007_199_254_740_991.0
    /// The minimum-scale unit selector: the units the deleted controller
    /// used (B, KB, MB — multipliers 1, 1024, 1048576) extended with GB
    /// on the same 1024-power series, a presentation of the single stored
    /// bytes/s value (coordinator ruling P5; no new stored setting).
    static let scaleUnits: [(label: String, multiplier: Int64)] = [
        ("bytes/s", 1), ("KB/s", 1024), ("MB/s", 1_048_576), ("GB/s", 1_073_741_824),
    ]
}

/// A number or duration field with its unit and range shown, and a slider
/// when the catalog gives a step (spec §5). Text that does not parse is
/// refused before submission — it shows the danger reason and saves
/// nothing, never the entry's default (review issue 2).
@MainActor public final class XRGSettingsNumberControl: XRGSettingsEntryControl {
    public var field = NSTextField()
    public let slider: XRGSettingsSliderView?
    let unitLabel = NSTextField(labelWithString: "")
    let rangeLabel = NSTextField(labelWithString: "")
    /// The bytes/s unit selector (only for entries stored in bytes/s).
    public private(set) var unitSelector: XRGSettingsPopUpButton?
    var selectedMultiplier: Int64 = 1
    /// The exact stored bytes/s value last presented or edited, held
    /// independently of the field's text (finding N2): the pre-fix unit
    /// switch re-derived the bytes by parsing the display text, which
    /// loses fractional presentations — 512 B/s shown as "0.5" KB/s parsed
    /// back as invalid and displayed the default 0 — and multiplied an
    /// overflowing integer unchecked.
    var exactBytes: Int64?
    public var fieldMin: Double { entry.range?.min ?? 0 }
    public var fieldMax: Double { entry.range?.max ?? 100 }
    /// Whether the entry's range carries a real upper bound.
    public private(set) var hasBoundedRange = false

    /// The value the current text parses to, nil when it does not.
    func parseValue() -> XRGSettingsValue? {
        guard let text = field.stringValue.trimmingCharacters(in: .whitespaces).nilIfEmpty else { return nil }
        switch entry.control {
        case .integer:
            guard let number = Int64(text) else { return nil }
            return .int(number)
        case .decimal, .duration:
            guard let number = Double(text), number.isFinite else { return nil }
            return .double(number)
        default:
            return nil
        }
    }
    public override func value() -> XRGSettingsValue {
        // A bytes/s entry presents through its unit selector: the value is
        // the exact bytes it holds, never the (possibly fractional) text
        // the chosen unit is displaying.
        if unitSelector != nil, let exactBytes { return .int(exactBytes) }
        return parseValue() ?? entry.defaultValue
    }
    public override func present(_ value: XRGSettingsValue) {
        if let unitSelector {
            let bytes = Self.storedBytes(of: value)
            exactBytes = bytes
            let unit = Self.scaleUnit(forBytes: bytes)
            selectedMultiplier = unit.multiplier
            unitSelector.selectItem(withTitle: unit.label)
            field.stringValue = Self.fieldText(forBytes: bytes, multiplier: unit.multiplier)
        } else {
            switch value {
            case .int(let number): field.stringValue = String(number)
            case .double(let number): field.stringValue = Self.format(number)
            default: field.stringValue = ""
            }
        }
        slider?.doubleValue = numericValue ?? fieldMin
    }
    var numericValue: Double? {
        switch value() { case .int(let n): return Double(n); case .double(let n): return n; default: return nil }
    }
    static func format(_ number: Double) -> String {
        number == number.rounded() ? String(Int(number)) : String(format: "%.12g", number)
    }
    static func storedBytes(of value: XRGSettingsValue) -> Int64 {
        switch value {
        case .int(let number): return number
        case .double(let number): return Int64(number)
        default: return 0
        }
    }
    static func fieldText(forBytes bytes: Int64, multiplier: Int64) -> String {
        multiplier <= 1 ? String(bytes) : format(Double(bytes) / Double(multiplier))
    }
    static func scaleUnit(forBytes bytes: Int64) -> (label: String, multiplier: Int64) {
        let units = XRGSettingsNumberControlConstants.scaleUnits
        for unit in units.reversed() where bytes >= unit.multiplier && bytes % unit.multiplier == 0 {
            return (unit.label, unit.multiplier)
        }
        return (units[0].label, units[0].multiplier)
    }

    public override func themeDidChange(dark: Bool) {
        field.textColor = XRGAether7b.Color.textMain(dark: dark)
        field.backgroundColor = XRGAether7b.Color.surfaceCard(dark: dark)
        unitLabel.textColor = XRGAether7b.Color.textMuted(dark: dark)
        rangeLabel.textColor = XRGAether7b.Color.textMuted(dark: dark)
        unitSelector?.contentTintColor = XRGAether7b.Color.textMain(dark: dark)
        unitSelector?.applyTitleColour(dark: dark)
        slider?.applyAppearance(dark: dark)
    }
    public override func enabledDidChange(_ enabled: Bool) {
        field.isEditable = enabled
        slider?.isEnabled = enabled
        unitSelector?.isEnabled = enabled
    }

    public override init(entry: XRGSettingsEntry, dark: Bool) {
        let step = entry.range?.step
        if let step {
            let slider = XRGSettingsSliderView(dark: dark)
            slider.minValue = entry.range?.min ?? 0
            slider.maxValue = entry.range?.max ?? 1
            slider.increment = step
            slider.setAccessibilityLabel(entry.label)
            self.slider = slider
        } else {
            self.slider = nil
        }
        super.init(entry: entry, dark: dark)
        field = XRGAether7bStyle.field(dark)
        (field as? XRGSettingsField)?.focusOwner = self
        field.placeholderString = ""
        rimView.addSubview(field)
        field.leadingAnchor.constraint(equalTo: rimView.leadingAnchor, constant: XRGAether7b.Space.s2).isActive = true
        field.centerYAnchor.constraint(equalTo: rimView.centerYAnchor).isActive = true
        field.widthAnchor.constraint(equalToConstant: 72).isActive = true
        rimView.heightAnchor.constraint(equalToConstant: 26).isActive = true
        field.target = self
        field.action = #selector(fieldEdited)
        var rangeAnchor = field.trailingAnchor
        // The bytes/s unit selector: the units the deleted network-scale
        // control used, presenting the single stored bytes/s value.
        let storedInBytes = entry.range?.unit == "bytes/s"
        if storedInBytes {
            let selector = XRGSettingsPopUpButton(frame: .zero, pullsDown: false)
            selector.translatesAutoresizingMaskIntoConstraints = false
            selector.isBordered = false
            selector.focusRingType = .none
            selector.font = monoFont(XRGAether7b.TypeScale.xs.size)
            selector.contentTintColor = XRGAether7b.Color.textMain(dark: dark)
            selector.applyTitleColour(dark: dark)
            selector.focusOwner = self
            selector.addItems(withTitles: XRGSettingsNumberControlConstants.scaleUnits.map(\.label))
            selector.setAccessibilityLabel("\(entry.label) unit")
            rimView.addSubview(selector)
            NSLayoutConstraint.activate([
                selector.leadingAnchor.constraint(equalTo: field.trailingAnchor, constant: XRGAether7b.Space.s2),
                selector.centerYAnchor.constraint(equalTo: rimView.centerYAnchor),
                selector.widthAnchor.constraint(equalToConstant: 72),
            ])
            selector.target = self
            selector.action = #selector(unitEdited(_:))
            unitSelector = selector
            rangeAnchor = selector.trailingAnchor
        } else if let unit = entry.range?.unit, !unit.isEmpty {
            unitLabel.stringValue = unit
            unitLabel.font = monoFont(XRGAether7b.TypeScale.xs.size)
            unitLabel.textColor = XRGAether7b.Color.textMuted(dark: dark)
            unitLabel.translatesAutoresizingMaskIntoConstraints = false
            addSubview(unitLabel)
            unitLabel.leadingAnchor.constraint(equalTo: field.trailingAnchor, constant: XRGAether7b.Space.s2).isActive = true
            unitLabel.centerYAnchor.constraint(equalTo: field.centerYAnchor).isActive = true
            rangeAnchor = unitLabel.trailingAnchor
        }
        // The rim closes around the field (and selector) EXACTLY (fix V4,
        // tightened for the round-3 cosmetic finding): the pre-fix lower
        // bound left the rim's width underdetermined, and the wrapping row
        // label stretched the field box left to fill the label gap — a
        // 72 pt field rendered in rims up to 442 pt wide, with the range
        // text and slider adrift. The equality pins ONE consistent field
        // width; the range text and slider chain on after the closed box.
        rimView.trailingAnchor.constraint(equalTo: rangeAnchor,
                                         constant: storedInBytes ? XRGAether7b.Space.s1 : XRGAether7b.Space.s2).isActive = true
        // The horizontal chain continues to the right of the rim — the
        // range text, then the slider — so no two contents overlap, and
        // the wrapper's trailing edge closes around the rightmost one
        // (V2): the row's trailing alignment then lands on what the user
        // actually sees, never on an unbound wrapper.
        var rightmost: NSLayoutXAxisAnchor = rimView.trailingAnchor
        // The range, shown beside the rim (mockup: "200 ms – 10 s") —
        // only when the catalog's max is a real bound; the max-safe-integer
        // sentinel means "no meaningful upper bound" and shows nothing.
        if let range = entry.range {
            hasBoundedRange = range.max < XRGSettingsNumberControlConstants.unboundedMaximum
            if hasBoundedRange {
                let minText = entry.control == .duration ? Self.durationText(range.min, unit: range.unit) : Self.format(range.min)
                let maxText = entry.control == .duration ? Self.durationText(range.max, unit: range.unit) : Self.format(range.max)
                rangeLabel.stringValue = "\(minText) – \(maxText)"
                rangeLabel.font = sansFont(XRGAether7b.TypeScale.xs.size)
                rangeLabel.textColor = XRGAether7b.Color.textMuted(dark: dark)
                rangeLabel.translatesAutoresizingMaskIntoConstraints = false
                rangeLabel.setAccessibilityLabel("\(entry.label) range \(minText) to \(maxText)")
                addSubview(rangeLabel)
                rangeLabel.leadingAnchor.constraint(equalTo: rimView.trailingAnchor, constant: XRGAether7b.Space.s3).isActive = true
                rangeLabel.centerYAnchor.constraint(equalTo: field.centerYAnchor).isActive = true
                rightmost = rangeLabel.trailingAnchor
            }
        }
        if let slider {
            slider.translatesAutoresizingMaskIntoConstraints = false
            slider.widthAnchor.constraint(equalToConstant: 150).isActive = true
            slider.heightAnchor.constraint(equalToConstant: 20).isActive = true
            addSubview(slider)
            slider.leadingAnchor.constraint(equalTo: rightmost, constant: XRGAether7b.Space.s3).isActive = true
            slider.centerYAnchor.constraint(equalTo: field.centerYAnchor).isActive = true
            rightmost = slider.trailingAnchor
            slider.target = self
            slider.action = #selector(sliderEdited(_:))
        }
        // The wrapper closes around the chain's rightmost content (V2):
        // the row's trailing alignment lands on the visible assembly.
        trailingAnchor.constraint(equalTo: rightmost).isActive = true
        present(entry.defaultValue)
    }
    static func durationText(_ seconds: Double, unit: String?) -> String {
        switch unit {
        case "min": return "\(Self.format(seconds)) min"
        default: return Self.format(seconds) + " " + (unit ?? "s")
        }
    }
    /// The user edited the field: text that does not parse is rejected
    /// before submission — the store is never offered a phantom default.
    /// A bytes/s entry accepts the number in the unit the selector shows
    /// (fractions included — "1.5" KB/s is 1536 B/s) and converts back with
    /// checked arithmetic on every path: a value that cannot be whole
    /// bytes, or that overflows the stored integer, is refused with the
    /// danger reason and saves nothing (finding N2).
    @objc public func fieldEdited() {
        guard isEnabledControl else { return }
        guard let text = field.stringValue.trimmingCharacters(in: .whitespaces).nilIfEmpty else {
            showError("Enter a number.")
            return
        }
        if let selector = unitSelector {
            guard let display = Double(text), display.isFinite else {
                showError("Enter a number.")
                return
            }
            let units = XRGSettingsNumberControlConstants.scaleUnits
            let multiplier = units.indices.contains(selector.indexOfSelectedItem)
                ? units[selector.indexOfSelectedItem].multiplier : selectedMultiplier
            let scaled = display * Double(multiplier)
            guard scaled.isFinite, scaled == scaled.rounded() else {
                showError("Enter a whole number of bytes per second.")
                return
            }
            guard let bytes = Int64(exactly: scaled) else {
                showError("The value is too large.")
                return
            }
            exactBytes = bytes
            submit(.int(bytes))
            return
        }
        guard let parsed = parseValue() else {
            showError(entry.control == .integer ? "Enter a whole number." : "Enter a number.")
            return
        }
        submit(parsed)
    }
    /// The unit selector changed: re-present the exact stored bytes/s in
    /// the chosen unit — the bytes are the value the store holds, never
    /// re-derived by parsing the field's display text (finding N2), and
    /// fractional displays are first-class. Nothing is submitted until the
    /// number itself is edited.
    @objc func unitEdited(_ sender: NSPopUpButton) {
        let units = XRGSettingsNumberControlConstants.scaleUnits
        guard units.indices.contains(sender.indexOfSelectedItem) else { return }
        let newMultiplier = units[sender.indexOfSelectedItem].multiplier
        guard newMultiplier != selectedMultiplier else { return }
        let bytes = exactBytes ?? Self.storedBytes(of: value())
        selectedMultiplier = newMultiplier
        field.stringValue = Self.fieldText(forBytes: bytes, multiplier: newMultiplier)
    }
    @objc func sliderEdited(_ sender: Any?) {
        guard isEnabledControl, let step = entry.range?.step, let slider else { return }
        // Snap to the entry's step, like the old slider did.
        let raw = slider.doubleValue
        let stepped = (raw / step).rounded() * step
        present(.double(min(fieldMax, max(fieldMin, stepped))))
        submit(value())
    }
    public override func focusableViews() -> [NSView] {
        var views: [NSView] = [field]
        if let unitSelector { views.append(unitSelector) }
        if let slider { views.append(slider) }
        return views
    }
}

// MARK: - Color

/// The token-styled colour well (issue 9: control chrome is not exempt):
/// macOS 26's `NSColorWell` is a SwiftUI-hosted view whose chrome — a
/// private white-on-10% overlay and border sublayers — no public API can
/// recolour, so the window owns this well's chrome itself. The swatch,
/// the user's picked colour, is the one colour-content exemption the token
/// rule allows. Clicking opens the shared colour panel and follows its
/// changes; the focus treatment is the enclosing rim's token halo.
@MainActor public final class XRGSettingsColorWellView: NSControl {
    /// The well's colour: the user's picked content, drawn as the swatch.
    public var color: NSColor {
        didSet { applySwatch() }
    }
    weak var focusOwner: XRGSettingsEntryControl?
    /// True while the entry is unset (`.null` — the palette inherits).
    /// Inheritance is decided HERE, never from alpha: an explicit
    /// transparent colour is a stored override and is announced as hex
    /// plus opacity (review round 3: alpha ≤ 0.005 said "Inherited").
    public var isUnset = true { didSet { applySwatch() } }
    private var isDarkAppearance = false

    public init(dark: Bool) {
        self.color = .clear
        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false
        isDarkAppearance = dark
        wantsLayer = true
        layer?.cornerRadius = XRGAether7b.Radius.sm
        layer?.borderColor = XRGAether7b.Color.borderStrong(dark: dark).cgColor
        layer?.borderWidth = 1
        setAccessibilityRole(.colorWell)
        focusRingType = .none
    }
    @available(*, unavailable) required init?(coder: NSCoder) { fatalError("Programmatic view") }

    /// Restyle the well's chrome (its swatch follows `color` alone).
    public func applyAppearance(dark: Bool) {
        isDarkAppearance = dark
        layer?.borderColor = XRGAether7b.Color.borderStrong(dark: dark).cgColor
        applySwatch()
    }
    private func applySwatch() {
        layer?.backgroundColor = (color.usingColorSpace(.sRGB) ?? NSColor.clear).cgColor
        setAccessibilityValue(accessibilityColorDescription)
    }

    /// A colour VoiceOver can use: the swatch as hex with its opacity, or
    /// "Inherited" while the entry is unset — never `NSColor.description`'s
    /// device dump, which announced nothing useful (review: the well's
    /// value was meaningless). Unset-ness comes from `isUnset` (the entry's
    /// `.null` state) — a stored transparent colour is an override with
    /// its own hex and opacity, not inheritance.
    public var accessibilityColorDescription: String {
        guard !isUnset, let rgba = color.usingColorSpace(.sRGB) else { return "Inherited" }
        let hex = String(format: "#%02X%02X%02X",
                         Int((rgba.redComponent * 255).rounded()),
                         Int((rgba.greenComponent * 255).rounded()),
                         Int((rgba.blueComponent * 255).rounded()))
        let opacity = Int((rgba.alphaComponent * 100).rounded())
        return "\(hex), \(opacity)% opacity"
    }

    // The whole well is its own hit target, like every settings control.
    public override func hitTest(_ point: NSPoint) -> NSView? {
        guard isEnabled else { return nil }
        let local = superview.map { convert(point, from: $0) } ?? point
        return bounds.contains(local) ? self : nil
    }

    public override var acceptsFirstResponder: Bool { isEnabled }
    public override func becomeFirstResponder() -> Bool {
        focusOwner?.setFocused(true)
        return true
    }
    public override func resignFirstResponder() -> Bool {
        focusOwner?.setFocused(false)
        return true
    }

    /// Open the shared colour panel on the current colour and follow the
    /// panel's changes — the same interaction NSColorWell offers. Mouse,
    /// keyboard and accessibility presses all take this one path.
    public func openColourPanel() {
        guard isEnabled else { return }
        let panel = NSColorPanel.shared
        panel.setTarget(self)
        panel.setAction(#selector(panelColourChanged(_:)))
        panel.color = color
        panel.makeKeyAndOrderFront(nil)
    }
    @objc func panelColourChanged(_ sender: NSColorPanel) {
        color = sender.color
        if let action, let target { NSApp.sendAction(action, to: target, from: self) }
    }

    public override func performClick(_ sender: Any?) { openColourPanel() }
    public override func mouseUp(with event: NSEvent) {
        guard isEnabled else { return }
        if bounds.contains(convert(event.locationInWindow, from: nil)) { openColourPanel() }
    }
    public override func keyDown(with event: NSEvent) {
        guard isEnabled, !event.isARepeat else { super.keyDown(with: event); return }
        switch event.characters {
        case " ", "\r", "\n":
            openColourPanel()
        case "\t" where !event.modifierFlags.contains(.shift):
            // Explicit chain, skipping ineligible targets (see the flat
            // button's note).
            settingsAdvanceFocus(forward: true)
        case "\t":
            settingsAdvanceFocus(forward: false)
        default:
            super.keyDown(with: event)
        }
    }
    public override func accessibilityPerformPress() -> Bool {
        openColourPanel()
        return isEnabled
    }
}

/// A colour well with an "Inherit" affordance: pressing it stores `null`
/// — the unset value the palette inherits from — without resetting any
/// unrelated setting (review issue 8). The wrapper encloses the trailing
/// Inherit button (V2), so the row's trailing alignment lands on the
/// whole assembly.
@MainActor public final class XRGSettingsColorControl: XRGSettingsEntryControl {
    public let well: XRGSettingsColorWellView
    public let inheritButton: XRGSettingsFlatButton
    /// False while the entry is unset (`.null`: empty inherits the palette).
    var hasColor = false
    public override func value() -> XRGSettingsValue {
        guard hasColor, let rgba = well.color.usingColorSpace(.sRGB) else { return XRGSettingsValue.null }
        return .color([Double(rgba.redComponent), Double(rgba.greenComponent), Double(rgba.blueComponent), Double(rgba.alphaComponent)])
    }
    public override func present(_ value: XRGSettingsValue) {
        guard case .color(let rgba) = value, rgba.count == 4 else {
            hasColor = false
            well.isUnset = true
            well.color = .clear
            return
        }
        hasColor = true
        well.isUnset = false
        well.color = NSColor(srgbRed: CGFloat(rgba[0]), green: CGFloat(rgba[1]), blue: CGFloat(rgba[2]), alpha: CGFloat(rgba[3]))
    }
    public override func themeDidChange(dark: Bool) {
        inheritButton.style(background: nil, text: XRGAether7b.Color.textMain(dark: dark),
                            border: XRGAether7b.Color.borderStrong(dark: dark), dark: dark)
        well.applyAppearance(dark: dark)
    }
    public override func enabledDidChange(_ enabled: Bool) {
        well.isEnabled = enabled
        inheritButton.isEnabled = enabled
    }
    public override init(entry: XRGSettingsEntry, dark: Bool) {
        inheritButton = XRGSettingsFlatButton(title: "Inherit")
        well = XRGSettingsColorWellView(dark: dark)
        super.init(entry: entry, dark: dark)
        rimView.addSubview(well)
        NSLayoutConstraint.activate([
            well.leadingAnchor.constraint(equalTo: rimView.leadingAnchor, constant: XRGAether7b.Space.s1),
            well.centerYAnchor.constraint(equalTo: rimView.centerYAnchor),
            well.widthAnchor.constraint(equalToConstant: 44), well.heightAnchor.constraint(equalToConstant: 22),
            rimView.trailingAnchor.constraint(equalTo: well.trailingAnchor, constant: XRGAether7b.Space.s1),
            rimView.heightAnchor.constraint(equalToConstant: 24),
        ])
        inheritButton.style(background: nil, text: XRGAether7b.Color.textMain(dark: dark),
                            border: XRGAether7b.Color.borderStrong(dark: dark), dark: dark)
        inheritButton.translatesAutoresizingMaskIntoConstraints = false
        inheritButton.setAccessibilityLabel("Inherit the default \(entry.label)")
        inheritButton.onClick = { [weak self] in
            guard let self, self.isEnabledControl else { return }
            self.present(XRGSettingsValue.null)
            self.submit(XRGSettingsValue.null)
        }
        addSubview(inheritButton)
        NSLayoutConstraint.activate([
            inheritButton.leadingAnchor.constraint(equalTo: rimView.trailingAnchor, constant: XRGAether7b.Space.s2),
            inheritButton.centerYAnchor.constraint(equalTo: rimView.centerYAnchor),
            // The wrapper encloses the trailing Inherit button (V2): the
            // row's trailing alignment lands on the button, not past it.
            inheritButton.trailingAnchor.constraint(equalTo: trailingAnchor),
        ])
        present(entry.defaultValue)
        well.focusOwner = self
        well.target = self
        well.action = #selector(changedColor)
        // The focusable well element carries its OWN catalog label (review:
        // only the enclosing wrapper was labelled, so VoiceOver announced
        // the swatch with no name).
        well.setAccessibilityLabel(entry.label)
    }
    @objc func changedColor() { hasColor = true; well.isUnset = false; submit(value()) }
    public override func focusableViews() -> [NSView] { [well, inheritButton] }
}

// MARK: - Path

@MainActor public final class XRGSettingsPathControl: XRGSettingsEntryControl {
    public var pathField = NSTextField()
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
    public override func enabledDidChange(_ enabled: Bool) {
        pathField.isEditable = enabled
        chooseButton.isEnabled = enabled
    }
    public override init(entry: XRGSettingsEntry, dark: Bool) {
        chooseButton = XRGSettingsFlatButton(title: "Choose…")
        super.init(entry: entry, dark: dark)
        chooseButton.onClick = { [weak self] in
            guard let self else { return }
            _ = self.choose(self.chooseButton)
        }
        pathField = XRGAether7bStyle.field(dark)
        (pathField as? XRGSettingsField)?.focusOwner = self
        chooseButton.style(background: nil, text: XRGAether7b.Color.textMain(dark: dark),
                           border: XRGAether7b.Color.borderStrong(dark: dark), dark: dark)
        rimView.addSubview(pathField)
        chooseButton.translatesAutoresizingMaskIntoConstraints = false
        addSubview(chooseButton)
        NSLayoutConstraint.activate([
            pathField.leadingAnchor.constraint(equalTo: rimView.leadingAnchor, constant: XRGAether7b.Space.s1),
            pathField.trailingAnchor.constraint(equalTo: rimView.trailingAnchor, constant: -XRGAether7b.Space.s1),
            pathField.centerYAnchor.constraint(equalTo: rimView.centerYAnchor),
            chooseButton.leadingAnchor.constraint(equalTo: rimView.trailingAnchor, constant: XRGAether7b.Space.s2),
            chooseButton.centerYAnchor.constraint(equalTo: pathField.centerYAnchor),
            rimView.widthAnchor.constraint(equalToConstant: 180), rimView.heightAnchor.constraint(equalToConstant: 26),
            // The wrapper encloses the trailing Choose… button (V2).
            chooseButton.trailingAnchor.constraint(equalTo: trailingAnchor),
        ])
        chooseButton.target = self
        chooseButton.action = #selector(choose(_:))
    }
    @objc func choose(_ sender: Any?) { onChoose?(self) }
    public func userChose(url: URL) { present(.string(url.path)); submit(value()) }
    public override func focusableViews() -> [NSView] { [pathField, chooseButton] }
}

// MARK: - Text

@MainActor public final class XRGSettingsTextControl: XRGSettingsEntryControl {
    public var textField = NSTextField()
    public override func value() -> XRGSettingsValue { .string(textField.stringValue) }
    public override func present(_ value: XRGSettingsValue) {
        guard case .string(let text) = value else { return }
        textField.stringValue = text
    }
    public override func themeDidChange(dark: Bool) {
        textField.textColor = XRGAether7b.Color.textMain(dark: dark)
        textField.backgroundColor = XRGAether7b.Color.surfaceCard(dark: dark)
    }
    public override func enabledDidChange(_ enabled: Bool) {
        // A read-only display (ruling P3's font field) stays read-only
        // whatever the dependency state does (finding N4: enablement used
        // to re-open it on every settings notification).
        textField.isEditable = enabled && !isReadOnlyDisplay
    }
    public override init(entry: XRGSettingsEntry, dark: Bool) {
        super.init(entry: entry, dark: dark)
        textField = XRGAether7bStyle.field(dark)
        (textField as? XRGSettingsField)?.focusOwner = self
        rimView.addSubview(textField)
        NSLayoutConstraint.activate([
            textField.leadingAnchor.constraint(equalTo: rimView.leadingAnchor, constant: XRGAether7b.Space.s1),
            textField.trailingAnchor.constraint(equalTo: rimView.trailingAnchor, constant: -XRGAether7b.Space.s1),
            textField.centerYAnchor.constraint(equalTo: rimView.centerYAnchor),
            rimView.widthAnchor.constraint(greaterThanOrEqualToConstant: 150), rimView.heightAnchor.constraint(equalToConstant: 26),
            // The wrapper closes around the rim (V2): read-only or not,
            // the row's trailing alignment lands on the visible field.
            rimView.trailingAnchor.constraint(equalTo: trailingAnchor),
        ])
        present(entry.defaultValue)
        textField.target = self
        textField.action = #selector(edited)
    }
    @objc func edited() { submit(value()) }
    public override func focusableViews() -> [NSView] { [textField] }
}

// MARK: - Source

/// A source picker fed by `XRGSettingsSourceProvider`: options grouped
/// (Identified / Unidentified / Suspected unused for temperature), an empty
/// first option meaning "none/automatic". Selection restores by each item's
/// `representedObject`, never by index — the menu carries group headers the
/// flat option list does not (review issue 5).
@MainActor public final class XRGSettingsSourceControl: XRGSettingsEntryControl {
    public let popUp = XRGSettingsPopUpButton(frame: .zero, pullsDown: false)
    var optionValues: [String] = []
    public var optionLabels: [String] { popUp.itemArray.map(\.title) }
    public override func value() -> XRGSettingsValue {
        if let value = popUp.selectedItem?.representedObject as? String {
            return value.isEmpty ? XRGSettingsValue.null : XRGSettingsValue.string(value)
        }
        return XRGSettingsValue.null
    }
    public override func present(_ value: XRGSettingsValue) {
        let current: String? = { if case .string(let text) = value { return text }; return nil }()
        let match = popUp.itemArray.first { ($0.representedObject as? String) == current && $0.isEnabled }
        if let match {
            popUp.select(match)
        } else if current == nil || current?.isEmpty == true {
            popUp.selectItem(at: 0)
        }
    }
    public override func themeDidChange(dark: Bool) {
        popUp.contentTintColor = XRGAether7b.Color.textMain(dark: dark)
        popUp.applyTitleColour(dark: dark)
    }
    public override func enabledDidChange(_ enabled: Bool) { popUp.isEnabled = enabled }
    public override init(entry: XRGSettingsEntry, dark: Bool) {
        super.init(entry: entry, dark: dark)
        popUp.translatesAutoresizingMaskIntoConstraints = false
        popUp.isBordered = false
        popUp.focusRingType = .none
        popUp.font = monoFont(XRGAether7b.TypeScale.sm.size)
        popUp.contentTintColor = XRGAether7b.Color.textMain(dark: dark)
        popUp.applyTitleColour(dark: dark)
        popUp.focusOwner = self
        rimView.addSubview(popUp)
        NSLayoutConstraint.activate([
            popUp.leadingAnchor.constraint(equalTo: rimView.leadingAnchor, constant: XRGAether7b.Space.s1),
            popUp.trailingAnchor.constraint(equalTo: rimView.trailingAnchor, constant: -XRGAether7b.Space.s1),
            popUp.centerYAnchor.constraint(equalTo: rimView.centerYAnchor),
            rimView.widthAnchor.constraint(greaterThanOrEqualToConstant: 140), rimView.heightAnchor.constraint(equalToConstant: 26),
            // The wrapper closes around the rim (V2).
            rimView.trailingAnchor.constraint(equalTo: trailingAnchor),
        ])
    }
    /// Fill the picker from the provider's options for this entry's kind.
    public func load(options: [(group: String, value: String, label: String)], noneLabel: String) {
        let wasEnabled = popUp.isEnabled
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
                    popUp.lastItem?.representedObject = nil
                }
                lastGroup = option.group
            }
            popUp.addItem(withTitle: option.label)
            popUp.lastItem?.representedObject = option.value
            optionValues.append(option.value)
        }
        popUp.isEnabled = wasEnabled
        popUp.target = self
        popUp.action = #selector(picked(_:))
    }
    @objc func picked(_ sender: NSPopUpButton) { submit(value()) }
    public override func focusableViews() -> [NSView] { [popUp] }
}

// MARK: - Order

/// The reorderable graph list (coordinator ruling P4): one row per graph,
/// named, with keyboard-operable Move up / Move down buttons, writing the
/// existing `order` setting. The per-graph reset of the old draft editor
/// is gone; the section reset remains. Every row shares one name column
/// (W2: the Move buttons line up in one column, however long a graph's
/// name is), a move rebuilds the list with exactly one row per graph
/// (finding N3: the pre-fix rebuild left the old row containers in the
/// stack and appended fresh ones, accumulating empty rows), preserves
/// keyboard focus on the moved graph's button, and re-wires the window's
/// key-view loop so Tab and Shift-Tab keep working afterwards.
@MainActor public final class XRGSettingsOrderControl: XRGSettingsEntryControl {
    var ids: [String] = []
    var rows: [(name: NSTextField, up: XRGSettingsFlatButton, down: XRGSettingsFlatButton)] = []
    let listStack = NSStackView()
    /// Re-wires the window's key-view loop after a rebuild (finding N3):
    /// the controller installs this; the buttons a rebuild creates must
    /// rejoin the loop or keyboard navigation dies after the first move.
    var keyLoopInvalidated: (() -> Void)?

    public override func value() -> XRGSettingsValue { .string(ids.joined(separator: ",")) }
    static func displayName(of id: String) -> String {
        if id == "npu" { return "NPU" }
        if let graph = XRGGraphID(rawValue: id) { return graph.name }
        return id.prefix(1).uppercased() + id.dropFirst()
    }
    public override func present(_ value: XRGSettingsValue) {
        guard case .string(let list) = value else { return }
        let parsed = list.split(separator: ",").map(String.init)
        guard !parsed.isEmpty else { return }
        if parsed != ids { rebuild(ids: parsed) }
    }
    public override func themeDidChange(dark: Bool) {
        for row in rows {
            row.name.textColor = XRGAether7b.Color.textMain(dark: dark)
            for button in [row.up, row.down] {
                button.style(background: nil, text: XRGAether7b.Color.textMain(dark: dark),
                             border: XRGAether7b.Color.borderStrong(dark: dark), dark: dark)
            }
        }
    }
    public override func enabledDidChange(_ enabled: Bool) { refreshButtonStates() }

    public override init(entry: XRGSettingsEntry, dark: Bool) {
        super.init(entry: entry, dark: dark)
        // The list IS the control: the base class's empty rim box would
        // render as a zero-width chrome layer (the audit's radius rule
        // flags degenerate-sized chrome), so it stays hidden — the rows,
        // not a rim, carry the visual.
        rimView.isHidden = true
        listStack.orientation = .vertical
        listStack.alignment = .leading
        listStack.spacing = XRGAether7b.Space.s1
        listStack.translatesAutoresizingMaskIntoConstraints = false
        addSubview(listStack)
        NSLayoutConstraint.activate([
            listStack.leadingAnchor.constraint(equalTo: rimView.leadingAnchor),
            listStack.trailingAnchor.constraint(equalTo: trailingAnchor),
            listStack.topAnchor.constraint(equalTo: topAnchor),
            listStack.bottomAnchor.constraint(equalTo: bottomAnchor),
        ])
        present(entry.defaultValue)
    }

    private func rebuild(ids newIds: [String]) {
        // Preserve keyboard focus across the rebuild: remember which
        // graph's button holds it, then refocus the matching button of
        // the rebuilt row (finding N3: the focused button used to be
        // destroyed by the rebuild, dropping focus on the floor).
        let firstResponder = window?.firstResponder
        var focused: (id: String, isUp: Bool)?
        for (index, row) in rows.enumerated() where ids.indices.contains(index) {
            if firstResponder === row.up { focused = (ids[index], true) }
            if firstResponder === row.down { focused = (ids[index], false) }
        }
        // Remove the previous row containers themselves — arranged
        // subviews AND views — so the list holds exactly one row per
        // graph after every move (finding N3's accumulating empties).
        for row in listStack.arrangedSubviews {
            listStack.removeArrangedSubview(row)
            row.removeFromSuperview()
        }
        ids = newIds
        rows = []
        var previousName: NSTextField?
        for (index, id) in ids.enumerated() {
            let name = NSTextField(labelWithString: Self.displayName(of: id))
            name.font = sansFont(XRGAether7b.TypeScale.sm.size)
            name.textColor = XRGAether7b.Color.textMain(dark: isDarkAppearance)
            name.translatesAutoresizingMaskIntoConstraints = false
            let up = XRGSettingsFlatButton(title: "Move up", verticalPadding: XRGAether7b.Space.s1) { [weak self] in
                self?.moveRow(at: index, by: -1)
            }
            let down = XRGSettingsFlatButton(title: "Move down", verticalPadding: XRGAether7b.Space.s1) { [weak self] in
                self?.moveRow(at: index, by: 1)
            }
            for button in [up, down] {
                button.labelField.font = sansFont(XRGAether7b.TypeScale.xs.size)
                button.style(background: nil, text: XRGAether7b.Color.textMain(dark: isDarkAppearance),
                             border: XRGAether7b.Color.borderStrong(dark: isDarkAppearance), dark: isDarkAppearance)
            }
            up.setAccessibilityLabel("Move \(Self.displayName(of: id)) up")
            down.setAccessibilityLabel("Move \(Self.displayName(of: id)) down")
            let row = NSStackView(views: [name, up, down])
            row.orientation = .horizontal
            row.spacing = XRGAether7b.Space.s2
            row.translatesAutoresizingMaskIntoConstraints = false
            listStack.addArrangedSubview(row)
            row.widthAnchor.constraint(equalTo: listStack.widthAnchor).isActive = true
            up.widthAnchor.constraint(equalToConstant: 84).isActive = true
            down.widthAnchor.constraint(equalToConstant: 92).isActive = true
            // One shared name column (W2): every row's name is as wide as
            // the widest, so the Move buttons start at one x and form one
            // column, like the other rows' controls.
            if let previousName {
                name.widthAnchor.constraint(equalTo: previousName.widthAnchor).isActive = true
            }
            previousName = name
            rows.append((name, up, down))
        }
        refreshButtonStates()
        // The rebuilt buttons must rejoin the window's key-view loop, or
        // Tab and Shift-Tab stop at the destroyed chain (finding N3).
        if window != nil { keyLoopInvalidated?() }
        if let focused, let newIndex = ids.firstIndex(of: focused.id),
           rows.indices.contains(newIndex) {
            // A move that reaches an endpoint disables the moved graph's own
            // direction button (the first row's Move up, the last row's Move
            // down): follow focus to its ENABLED opposite-direction button
            // instead, so the keyboard never loses the moved graph (the
            // remaining P4/N3 — the pre-fix code declined and dropped focus
            // on the floor at both endpoints).
            let preferred = focused.isUp ? rows[newIndex].up : rows[newIndex].down
            let opposite = focused.isUp ? rows[newIndex].down : rows[newIndex].up
            let button = preferred.isEnabled ? preferred : opposite
            if button.isEnabled { window?.makeFirstResponder(button) }
        }
    }

    private func refreshButtonStates() {
        for (index, row) in rows.enumerated() {
            row.up.isEnabled = isEnabledControl && index > 0
            row.down.isEnabled = isEnabledControl && index < rows.count - 1
        }
    }

    private func moveRow(at index: Int, by delta: Int) {
        guard isEnabledControl else { return }
        let target = index + delta
        guard rows.indices.contains(index), rows.indices.contains(target) else { return }
        // The rebuild's focus capture pairs the OLD ids with the OLD rows,
        // so the moved order is passed in — `ids` must still describe the
        // rows that are on screen when the capture runs.
        var moved = ids
        moved.swapAt(index, target)
        rebuild(ids: moved)
        submit(value())
    }
    public override func focusableViews() -> [NSView] { rows.flatMap { [$0.up, $0.down] } }
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
    public override func enabledDidChange(_ enabled: Bool) { button.isEnabled = enabled }
    public override init(entry: XRGSettingsEntry, dark: Bool) {
        button = XRGSettingsFlatButton(title: entry.label)
        super.init(entry: entry, dark: dark)
        // The button IS the control: the base class's empty rim box would
        // render as zero-width chrome (the audit's radius rule flags
        // degenerate-sized chrome), so it stays hidden.
        rimView.isHidden = true
        button.style(background: nil, text: XRGAether7b.Color.textMain(dark: dark),
                     border: XRGAether7b.Color.borderStrong(dark: dark), dark: dark)
        addSubview(button)
        NSLayoutConstraint.activate([
            button.leadingAnchor.constraint(equalTo: leadingAnchor),
            button.centerYAnchor.constraint(equalTo: rimView.centerYAnchor),
            topAnchor.constraint(equalTo: button.topAnchor),
            bottomAnchor.constraint(equalTo: button.bottomAnchor),
            // The wrapper closes around the visible button (V2/V8): the
            // row's leading alignment lands on the button itself.
            button.trailingAnchor.constraint(equalTo: trailingAnchor),
        ])
        button.onClick = { [weak self] in
            guard let self else { return }
            self.onAction?(self)
        }
    }
    public override func focusableViews() -> [NSView] { [button] }
}

// MARK: - Small helpers

@MainActor extension NSView {
    /// The settings window's key-view loop is explicit (`wireKeyViewLoop`
    /// wires the chain and stops the automatic recalculation), so Tab and
    /// Shift-Tab walk it here — to the next view that can actually TAKE
    /// focus. Disabled controls stay wired in the chain (their enablement
    /// follows `depends` after the wiring ran, and the reorder list keeps
    /// its endpoint buttons in it), so the walk skips anything disabled or
    /// hidden in either direction, wrapping end-to-end within one bounded
    /// lap of the chain. The pre-fix walk handed focus to the IMMEDIATE
    /// neighbour and stalled whenever that neighbour was disabled
    /// (Shift-Tab from the first Move down, Tab from the last Move up).
    @discardableResult
    func settingsAdvanceFocus(forward: Bool) -> Bool {
        guard let window else { return false }
        // The chain the controller wired, from its first view on.
        var chain: [NSView] = []
        var current: NSView? = window.initialFirstResponder
        var seen = Set<ObjectIdentifier>()
        while let view = current, seen.insert(ObjectIdentifier(view)).inserted {
            chain.append(view)
            current = view.nextKeyView
        }
        guard let here = chain.firstIndex(where: { $0 === self }) else {
            // Not in the explicit chain: AppKit's own loop.
            if forward { window.selectKeyView(following: self) } else { window.selectKeyView(preceding: self) }
            return true
        }
        func eligible(_ view: NSView) -> Bool {
            guard !view.isHidden, !view.isHiddenOrHasHiddenAncestor else { return false }
            if let control = view as? NSControl, !control.isEnabled { return false }
            // The number/text/path fields report disablement through their
            // owning control: their own `isEnabled` stays on so the token
            // colours keep drawing, only `isEditable` closes.
            if let field = view as? XRGSettingsField, field.focusOwner?.isEnabled == false { return false }
            return view.acceptsFirstResponder
        }
        // Bounded: at most one lap around the chain, wrapping end to end,
        // and on to the next candidate if a focus target refuses.
        for step in 1...max(1, chain.count) {
            let wrapped = ((here + (forward ? step : -step)) % chain.count + chain.count) % chain.count
            let candidate = chain[wrapped]
            if candidate !== self, eligible(candidate), window.makeFirstResponder(candidate) {
                return true
            }
        }
        return false
    }
}

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
