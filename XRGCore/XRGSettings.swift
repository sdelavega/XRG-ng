/*
 * XRG-ng: A system resource grapher for macOS and Linux.
 * Copyright (C) 2002-2024 Mike Piatek-Jimenez / Gaucho Software, LLC.
 * Copyright (C) 2025-2026 Marc Shade.
 * Copyright (C) 2026 Stephen de la Vega.
 * You can view the complete license in the LICENSE file in the root
 * of the source tree.
 *
 * This program is free software; you can redistribute it and/or
 * modify it under the terms of the GNU General Public License
 * as published by the Free Software Foundation; either version 3
 * of the License, or (at your option) any later version.
 *
 * This program is distributed in the hope that it will be useful,
 * but WITHOUT ANY WARRANTY; without even the implied warranty of
 * MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
 * GNU General Public License for more details.
 *
 * You should have received a copy of the GNU General Public License
 * along with this program. If not, see <https://www.gnu.org/licenses/>.
 *
 */

import AppKit
import Foundation

@objc public enum XRGTemperatureUnits: Int, Sendable {
    case f = 0
    case c = 1
}

/// Shared with the Objective-C UI while its consumers migrate to Swift.
@objc(XRGSettings)
@objcMembers
public final class XRGSettings: NSObject {
    @MainActor public static let sharedSettings = XRGSettings()
    private let defaults: UserDefaults
    @nonobjc private(set) var graphPreferences = XRGGraphPreferences()
    @nonobjc private(set) var graphPreferencesError: String?

    @nonobjc func applyGraphPreferences(_ value: XRGGraphPreferences) throws {
        let data = try value.encoded()
        defaults.set(data, forKey: XRGGraphPreferences.key)
        graphPreferences = value; graphPreferencesError = nil
    }

    private var backgroundColorStorage = NSColor.clear
    public var backgroundColor: NSColor {
        get { backgroundColorStorage }
        set {
            backgroundColorStorage = newValue.withAlphaComponent(backgroundTransparency)
        }
    }
    public var backgroundTransparency: CGFloat = 0 {
        didSet {
            backgroundColorStorage = backgroundColorStorage.withAlphaComponent(backgroundTransparency)
        }
    }

    private var graphBGColorStorage = NSColor.clear
    public var graphBGColor: NSColor {
        get { graphBGColorStorage }
        set {
            graphBGColorStorage = newValue.withAlphaComponent(graphBGTransparency)
        }
    }
    public var graphBGTransparency: CGFloat = 0 {
        didSet {
            graphBGColorStorage = graphBGColorStorage.withAlphaComponent(graphBGTransparency)
        }
    }

    private var graphFG1ColorStorage = NSColor.clear
    public var graphFG1Color: NSColor {
        get { graphFG1ColorStorage }
        set {
            graphFG1ColorStorage = newValue.withAlphaComponent(graphFG1Transparency)
        }
    }
    public var graphFG1Transparency: CGFloat = 0 {
        didSet {
            graphFG1ColorStorage = graphFG1ColorStorage.withAlphaComponent(graphFG1Transparency)
        }
    }

    private var graphFG2ColorStorage = NSColor.clear
    public var graphFG2Color: NSColor {
        get { graphFG2ColorStorage }
        set {
            graphFG2ColorStorage = newValue.withAlphaComponent(graphFG2Transparency)
        }
    }
    public var graphFG2Transparency: CGFloat = 0 {
        didSet {
            graphFG2ColorStorage = graphFG2ColorStorage.withAlphaComponent(graphFG2Transparency)
        }
    }

    private var graphFG3ColorStorage = NSColor.clear
    public var graphFG3Color: NSColor {
        get { graphFG3ColorStorage }
        set {
            graphFG3ColorStorage = newValue.withAlphaComponent(graphFG3Transparency)
        }
    }
    public var graphFG3Transparency: CGFloat = 0 {
        didSet {
            graphFG3ColorStorage = graphFG3ColorStorage.withAlphaComponent(graphFG3Transparency)
        }
    }

    private var borderColorStorage = NSColor.clear
    public var borderColor: NSColor {
        get { borderColorStorage }
        set {
            borderColorStorage = newValue.withAlphaComponent(borderTransparency)
        }
    }
    public var borderTransparency: CGFloat = 0 {
        didSet {
            borderColorStorage = borderColorStorage.withAlphaComponent(borderTransparency)
        }
    }

    private var textColorStorage = NSColor.clear
    public var textColor: NSColor {
        get { textColorStorage }
        set {
            textColorStorage = newValue.withAlphaComponent(textTransparency)
            updateTextColorAttributes()
        }
    }
    public var textTransparency: CGFloat = 0 {
        didSet {
            textColorStorage = textColorStorage.withAlphaComponent(textTransparency)
            updateTextColorAttributes()
        }
    }

    private var fontStorage = NSFont.systemFont(ofSize: 10)
    public var graphFont: NSFont! {
        get { fontStorage }
        set {
            guard let newValue else { return }
            fontStorage = newValue
            for attributes in [alignRightAttributes, alignLeftAttributes, alignCenterAttributes] {
                attributes[NSAttributedString.Key.font.rawValue] = newValue
            }
            textRectHeight = ("ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz01234567890°.:%" as NSString)
                .size(withAttributes: textAttributes(alignRightAttributes)).height
        }
    }
    public var textRectHeight: CGFloat = 0
    public var alignRight = NSMutableParagraphStyle()
    public var alignLeft = NSMutableParagraphStyle()
    public var alignCenter = NSMutableParagraphStyle()
    public var alignRightAttributes = NSMutableDictionary()
    public var alignLeftAttributes = NSMutableDictionary()
    public var alignCenterAttributes = NSMutableDictionary()

    public var fastCPUUsage: Bool = false
    public var separateCPUColor: Bool = true
    public var showCPUTemperature: Bool = false
    public var cpuTemperatureUnits: Int = 0
    public var antiAliasing: Bool = false
    public var ICAO: String = ""
    public var secondaryWeatherGraph: Int = 1
    public var weatherHistoryHours: Int = 0
    public var temperatureUnits: Int = 0
    public var distanceUnits: Int = 0
    public var pressureUnits: Int = 0
    public var showMemoryPagingGraph: Bool = true
    public var memoryShowWired: Bool = true
    public var memoryShowActive: Bool = true
    public var memoryShowInactive: Bool = true
    public var memoryShowFree: Bool = true
    public var memoryShowCache: Bool = true
    public var memoryShowPage: Bool = true
    public var graphRefresh: CGFloat = 1
    public var showLoadAverage: Bool = true
    public var netMinGraphScale: Int = 1024
    public var stockSymbols: String = "AAPL"
    public var stockGraphTimeFrame: Int = 3
    public var stockShowChange: Bool = true
    public var showDJIA: Bool = true
    public var windowLevel: Int = 0
    public var stickyWindow: Bool = true
    public var checkForUpdates: Bool = false
    public var netGraphMode: Int = 0
    public var diskGraphMode: Int = 0
    public var dropShadow: Bool = false
    public var showTotalBandwidthSinceBoot: Bool = true
    public var showTotalBandwidthSinceLoad: Bool = true
    public var networkInterface: String = "All"
    public var windowTitle: String = ""
    public var autoExpandGraph: Bool = false
    public var foregroundWhenExpanding: Bool = false
    public var showSummary: Bool = false
    public var minimizeUpDown: Int = 0
    public var cpuShowAverageUsage: Bool = false
    public var cpuShowUptime: Bool = false
    public var tempUnits: XRGTemperatureUnits = .f
    public var tempFG1Location: String = ""
    public var tempFG2Location: String = ""
    public var tempFG3Location: String = ""
    /// Persist auto-selection before marking it complete. Repair only the exact legacy placeholders.
    public func configureTemperatureSensors(_ candidates: [String]) -> Bool {
        let locations = [tempFG1Location, tempFG2Location, tempFG3Location]
        let legacy = locations == ["0", "1", "2"]
        guard legacy || !defaults.bool(forKey: "tempLocationsAutoconfigured") else { return false }
        guard legacy || locations.allSatisfy({ $0.isEmpty }) else { return false }
        var selected: [String] = []
        for key in candidates where !key.isEmpty && !selected.contains(key) {
            selected.append(key)
            if selected.count == 3 { break }
        }
        guard !selected.isEmpty else { return false }
        while selected.count < 3 { selected.append("") }
        for index in 0..<3 {
            defaults.set(selected[index], forKey: "tempFG\(index + 1)Location")
        }
        tempFG1Location = selected[0]
        tempFG2Location = selected[1]
        tempFG3Location = selected[2]
        defaults.set(true, forKey: "tempLocationsAutoconfigured")
        return true
    }

    public var isDockIconHidden: Bool = false
    public var showAITokenGraph: Bool = false
    public var aiTokensTrackingEnabled: Bool {
        get { defaults.bool(forKey: "aiTokensTrackingEnabled") }
        set { defaults.set(newValue, forKey: "aiTokensTrackingEnabled") }
    }
    public var aiTokensDailyAutoReset: Bool {
        get { defaults.bool(forKey: "aiTokensDailyAutoReset") }
        set { defaults.set(newValue, forKey: "aiTokensDailyAutoReset") }
    }
    public var aiTokensDailyBudget: Int {
        get { defaults.integer(forKey: "aiTokensDailyBudget") }
        set { defaults.set(newValue, forKey: "aiTokensDailyBudget") }
    }
    public var aiTokensBudgetNotifyPercent: Int {
        get { defaults.integer(forKey: "aiTokensBudgetNotifyPercent") }
        set { defaults.set(newValue, forKey: "aiTokensBudgetNotifyPercent") }
    }
    public var aiTokensAggregateByModel: Bool {
        get { defaults.bool(forKey: "aiTokensAggregateByModel") }
        set { defaults.set(newValue, forKey: "aiTokensAggregateByModel") }
    }
    public var aiTokensAggregateByProvider: Bool {
        get { defaults.bool(forKey: "aiTokensAggregateByProvider") }
        set { defaults.set(newValue, forKey: "aiTokensAggregateByProvider") }
    }
    public var aiTokensShowRate: Bool {
        get { defaults.bool(forKey: "aiTokensShowRate") }
        set { defaults.set(newValue, forKey: "aiTokensShowRate") }
    }
    public var aiTokensShowBreakdown: Bool {
        get { defaults.bool(forKey: "aiTokensShowBreakdown") }
        set { defaults.set(newValue, forKey: "aiTokensShowBreakdown") }
    }
    public var graphStyle: Int {
        get { defaults.integer(forKey: "graphStyle") }
        set { defaults.set(newValue, forKey: "graphStyle") }
    }

    public override convenience init() {
        self.init(defaults: .standard)
    }

    public init(defaults: UserDefaults) {
        self.defaults = defaults
        if let data = defaults.data(forKey: XRGGraphPreferences.key) {
            do { graphPreferences = try XRGGraphPreferences(data: data) }
            catch { graphPreferencesError = "Saved graph options are invalid. Apply valid options to replace them." }
        }
        super.init()
        alignRight.alignment = .right
        alignLeft.alignment = .left
        alignCenter.alignment = .center
        alignLeft.lineBreakMode = .byTruncatingMiddle
        for (attributes, style) in [(alignRightAttributes, alignRight),
                                    (alignLeftAttributes, alignLeft),
                                    (alignCenterAttributes, alignCenter)] {
            attributes[NSAttributedString.Key.font.rawValue] = fontStorage
            attributes[NSAttributedString.Key.foregroundColor.rawValue] = NSColor.black
            attributes[NSAttributedString.Key.paragraphStyle.rawValue] = style
        }
        textRectHeight = ("A" as NSString).size(withAttributes: textAttributes(alignRightAttributes)).height
    }

    private func textAttributes(_ dictionary: NSMutableDictionary) -> [NSAttributedString.Key: Any] {
        var result: [NSAttributedString.Key: Any] = [:]
        for (key, value) in dictionary {
            if let key = key as? String {
                result[NSAttributedString.Key(key)] = value
            }
        }
        return result
    }

    private func updateTextColorAttributes() {
        for attributes in [alignRightAttributes, alignLeftAttributes, alignCenterAttributes] {
            attributes[NSAttributedString.Key.foregroundColor.rawValue] = textColorStorage
        }
    }

    /// Decode every field before applying any settings or persisting preferences.
    @objc(applyThemeDictionary:defaults:error:)
    public func applyThemeDictionary(_ dictionary: Any?, defaults: UserDefaults) throws {
        let theme = try XRGTheme(dictionary: dictionary)
        try applyTheme(theme, defaults: defaults)
    }

    @nonobjc public func applyThemeData(_ data: Data, defaults: UserDefaults) throws {
        try applyTheme(XRGTheme(data: data), defaults: defaults)
    }

    @nonobjc public func loadTheme(from url: URL, defaults: UserDefaults) throws {
        let scoped = url.startAccessingSecurityScopedResource()
        defer { if scoped { url.stopAccessingSecurityScopedResource() } }
        try applyThemeData(XRGTheme.readFile(url), defaults: defaults)
    }

    private func applyTheme(_ theme: XRGTheme, defaults: UserDefaults) throws {
        let portable = try theme.document?.encoded()
        for field in theme.fields {
            // XRGTheme supplies a fixed allowlist of keys.
            setValue(field.alpha, forKey: field.alphaKey)
            setValue(field.color, forKey: field.colorKey)
        }
        for field in theme.fields {
            defaults.set(field.alpha, forKey: field.alphaKey)
            defaults.set(field.archive, forKey: field.colorKey)
        }
        if let portable {
            defaults.set(portable, forKey: XRGTheme.documentKey)
            defaults.set(theme.document?.name, forKey: XRGTheme.nameKey)
        } else {
            defaults.removeObject(forKey: XRGTheme.documentKey)
            defaults.removeObject(forKey: XRGTheme.nameKey)
        }
    }

    @MainActor
    public func readXTFDictionary(_ dictionary: NSDictionary) -> Bool {
        do {
            try applyThemeDictionary(dictionary, defaults: defaults)
            return true
        } catch {
            let alert = NSAlert()
            alert.messageText = NSLocalizedString("Unable to Load Theme", comment: "Invalid theme alert title")
            alert.informativeText = error.localizedDescription
            alert.addButton(withTitle: NSLocalizedString("OK", comment: "Dismiss alert"))
            alert.runModal()
            return false
        }
    }
}
