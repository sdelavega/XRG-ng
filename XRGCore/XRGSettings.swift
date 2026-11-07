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

/// The typed face of the macOS settings store (XRG-ng 0.2.3, spec §2/§4).
///
/// Every property keeps its current name and type. Over the application's
/// shared document (`init(store:)`) the values are hydrated from the document
/// once and every change is written back through `XRGSettingsStore` — the
/// document is the source of truth. Over an injected `UserDefaults` suite
/// (`init(defaults:)`, the fixtures' path) the properties behave exactly as
/// 0.2.2 did: plain stored values restored by `XRGWindowPreferences.apply`
/// without writing, and the AI token and display-effect settings live in the
/// suite. No defaults keys appear here; every read and write goes through
/// the store.
@objc(XRGSettings)
@objcMembers
@MainActor
public final class XRGSettings: NSObject {
    @MainActor public static let sharedSettings = XRGSettings()

    /// The store every read and write below goes through.
    public let store: XRGSettingsStore
    /// True while the document's values are being loaded into the stored
    /// properties, so hydration itself does not write back.
    private var hydrating = false
    @nonobjc private(set) var graphPreferencesStorage = XRGGraphPreferences()
    @nonobjc private(set) var graphPreferencesError: String?

    @nonobjc func applyGraphPreferences(_ value: XRGGraphPreferences) throws {
        let data = try value.encoded()
        store.setLegacyValues([XRGGraphPreferences.key: data])
        graphPreferencesStorage = value; graphPreferencesError = nil
    }
    @nonobjc var graphPreferences: XRGGraphPreferences { graphPreferencesStorage }

    private var backgroundColorStorage = NSColor.clear
    public var backgroundColor: NSColor {
        get { backgroundColorStorage }
        set {
            backgroundColorStorage = newValue.withAlphaComponent(backgroundTransparency)
            persistColor("appearance.window.color", backgroundColorStorage)
        }
    }
    public var backgroundTransparency: CGFloat = 0 {
        didSet {
            backgroundColorStorage = backgroundColorStorage.withAlphaComponent(backgroundTransparency)
            persistDouble("appearance.window.transparency", backgroundTransparency)
            persistColor("appearance.window.color", backgroundColorStorage)
        }
    }

    private var graphBGColorStorage = NSColor.clear
    public var graphBGColor: NSColor {
        get { graphBGColorStorage }
        set {
            graphBGColorStorage = newValue.withAlphaComponent(graphBGTransparency)
            persistColor("appearance.graph_background.color", graphBGColorStorage)
        }
    }
    public var graphBGTransparency: CGFloat = 0 {
        didSet {
            graphBGColorStorage = graphBGColorStorage.withAlphaComponent(graphBGTransparency)
            persistDouble("appearance.graph_background.transparency", graphBGTransparency)
            persistColor("appearance.graph_background.color", graphBGColorStorage)
        }
    }

    private var graphFG1ColorStorage = NSColor.clear
    public var graphFG1Color: NSColor {
        get { graphFG1ColorStorage }
        set {
            graphFG1ColorStorage = newValue.withAlphaComponent(graphFG1Transparency)
            persistColor("appearance.series1.color", graphFG1ColorStorage)
        }
    }
    public var graphFG1Transparency: CGFloat = 0 {
        didSet {
            graphFG1ColorStorage = graphFG1ColorStorage.withAlphaComponent(graphFG1Transparency)
            persistDouble("appearance.series1.transparency", graphFG1Transparency)
            persistColor("appearance.series1.color", graphFG1ColorStorage)
        }
    }

    private var graphFG2ColorStorage = NSColor.clear
    public var graphFG2Color: NSColor {
        get { graphFG2ColorStorage }
        set {
            graphFG2ColorStorage = newValue.withAlphaComponent(graphFG2Transparency)
            persistColor("appearance.series2.color", graphFG2ColorStorage)
        }
    }
    public var graphFG2Transparency: CGFloat = 0 {
        didSet {
            graphFG2ColorStorage = graphFG2ColorStorage.withAlphaComponent(graphFG2Transparency)
            persistDouble("appearance.series2.transparency", graphFG2Transparency)
            persistColor("appearance.series2.color", graphFG2ColorStorage)
        }
    }

    private var graphFG3ColorStorage = NSColor.clear
    public var graphFG3Color: NSColor {
        get { graphFG3ColorStorage }
        set {
            graphFG3ColorStorage = newValue.withAlphaComponent(graphFG3Transparency)
            persistColor("appearance.series3.color", graphFG3ColorStorage)
        }
    }
    public var graphFG3Transparency: CGFloat = 0 {
        didSet {
            graphFG3ColorStorage = graphFG3ColorStorage.withAlphaComponent(graphFG3Transparency)
            persistDouble("appearance.series3.transparency", graphFG3Transparency)
            persistColor("appearance.series3.color", graphFG3ColorStorage)
        }
    }

    private var borderColorStorage = NSColor.clear
    public var borderColor: NSColor {
        get { borderColorStorage }
        set {
            borderColorStorage = newValue.withAlphaComponent(borderTransparency)
            persistColor("appearance.border.color", borderColorStorage)
        }
    }
    public var borderTransparency: CGFloat = 0 {
        didSet {
            borderColorStorage = borderColorStorage.withAlphaComponent(borderTransparency)
            persistDouble("appearance.border.transparency", borderTransparency)
            persistColor("appearance.border.color", borderColorStorage)
        }
    }

    private var textColorStorage = NSColor.clear
    public var textColor: NSColor {
        get { textColorStorage }
        set {
            textColorStorage = newValue.withAlphaComponent(textTransparency)
            persistColor("appearance.text.color", textColorStorage)
            updateTextColorAttributes()
        }
    }
    public var textTransparency: CGFloat = 0 {
        didSet {
            textColorStorage = textColorStorage.withAlphaComponent(textTransparency)
            persistDouble("appearance.text.transparency", textTransparency)
            persistColor("appearance.text.color", textColorStorage)
            updateTextColorAttributes()
        }
    }

    private var fontStorage = NSFont.systemFont(ofSize: 10)
    public var graphFont: NSFont! {
        get { fontStorage }
        set {
            guard let newValue else { return }
            fontStorage = newValue
            persistString("appearance.font", Self.fontDescriptor(newValue))
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

    public var fastCPUUsage: Bool = false { didSet { persistBool("graphs.cpu.fast_bars", fastCPUUsage) } }
    public var separateCPUColor: Bool = true { didSet { persistBool("graphs.cpu.separate_colors", separateCPUColor) } }
    public var showCPUTemperature: Bool = false { didSet { persistBool("graphs.cpu.show_temperature", showCPUTemperature) } }
    public var cpuTemperatureUnits: Int = 0 { didSet { persistChoice("graphs.cpu.temperature_units", cpuTemperatureUnits, Self.temperatureNames) } }
    public var antiAliasing: Bool = false { didSet { persistBool("appearance.antialiasing", antiAliasing) } }
    public var ICAO: String = "" { didSet { persistString("weather.station", ICAO) } }
    public var secondaryWeatherGraph: Int = 1 { didSet { persistChoice("weather.secondary", secondaryWeatherGraph, Self.secondaryNames) } }
    public var weatherHistoryHours: Int = 0 { didSet { persistInt("weather.history_hours", weatherHistoryHours) } }
    public var temperatureUnits: Int = 0 { didSet { persistChoice("weather.units.temperature", temperatureUnits, Self.temperatureNames) } }
    public var distanceUnits: Int = 0 { didSet { persistChoice("weather.units.distance", distanceUnits, Self.distanceNames) } }
    public var pressureUnits: Int = 0 { didSet { persistChoice("weather.units.pressure", pressureUnits, Self.pressureNames) } }
    public var showMemoryPagingGraph: Bool = true { didSet { persistBool("graphs.memory.show_paging_graph", showMemoryPagingGraph) } }
    public var memoryShowWired: Bool = true { didSet { persistBool("graphs.memory.show_wired", memoryShowWired) } }
    public var memoryShowActive: Bool = true { didSet { persistBool("graphs.memory.show_active", memoryShowActive) } }
    public var memoryShowInactive: Bool = true { didSet { persistBool("graphs.memory.show_inactive", memoryShowInactive) } }
    public var memoryShowFree: Bool = true { didSet { persistBool("graphs.memory.show_free", memoryShowFree) } }
    public var memoryShowCache: Bool = true { didSet { persistBool("graphs.memory.show_cache", memoryShowCache) } }
    public var memoryShowPage: Bool = true { didSet { persistBool("graphs.memory.show_page", memoryShowPage) } }
    public var graphRefresh: CGFloat = 1 { didSet { persistDouble("graphs.refresh", graphRefresh) } }
    public var showLoadAverage: Bool = true { didSet { persistBool("graphs.cpu.show_load_average", showLoadAverage) } }
    public var netMinGraphScale: Int = 1024 { didSet { persistInt("graphs.network.minimum_scale", netMinGraphScale) } }
    public var stockSymbols: String = "AAPL" { didSet { persistString("stocks.symbols", stockSymbols) } }
    public var stockGraphTimeFrame: Int = 3 { didSet { persistChoice("stocks.timeframe", stockGraphTimeFrame, Self.timeframeNames) } }
    public var stockShowChange: Bool = true { didSet { persistBool("stocks.show_change", stockShowChange) } }
    public var showDJIA: Bool = true { didSet { persistBool("stocks.show_djia", showDJIA) } }
    public var windowLevel: Int = 0 { didSet { persistChoice("general.window.level", windowLevel, Self.windowLevelNames) } }
    public var stickyWindow: Bool = true { didSet { persistBool("general.window.sticky_edges", stickyWindow) } }
    public var checkForUpdates: Bool = false { didSet { persistBool("general.updates.check_on_launch", checkForUpdates) } }
    public var netGraphMode: Int = 0 { didSet { persistInt("graphs.network.display_mode", netGraphMode) } }
    public var diskGraphMode: Int = 0 { didSet { persistInt("graphs.disk.display_mode", diskGraphMode) } }
    public var dropShadow: Bool = false { didSet { persistBool("general.window.drop_shadow", dropShadow) } }
    public var showTotalBandwidthSinceBoot: Bool = true { didSet { persistBool("graphs.network.show_total_since_boot", showTotalBandwidthSinceBoot) } }
    public var showTotalBandwidthSinceLoad: Bool = true { didSet { persistBool("graphs.network.show_total_since_load", showTotalBandwidthSinceLoad) } }
    public var networkInterface: String = "All" { didSet { persistString("sources.network.interface", networkInterface) } }
    public var windowTitle: String = "" { didSet { persistString("general.window.title", windowTitle) } }
    public var autoExpandGraph: Bool = false { didSet { persistBool("general.window.expand_on_hover", autoExpandGraph) } }
    public var foregroundWhenExpanding: Bool = false { didSet { persistBool("general.window.bring_to_front_on_expand", foregroundWhenExpanding) } }
    public var showSummary: Bool = false { didSet { persistBool("general.window.show_summary", showSummary) } }
    public var minimizeUpDown: Int = 0 { didSet { persistChoice("general.window.collapse_anchor", minimizeUpDown, Self.collapseNames) } }
    public var cpuShowAverageUsage: Bool = false { didSet { persistBool("graphs.cpu.show_average", cpuShowAverageUsage) } }
    public var cpuShowUptime: Bool = false { didSet { persistBool("graphs.cpu.show_uptime", cpuShowUptime) } }
    public var tempUnits: XRGTemperatureUnits = .f { didSet { persistChoice("graphs.temperature.units", tempUnits.rawValue, Self.temperatureNames) } }
    public var tempFG1Location: String = "" { didSet { persistString("sources.temperature.sensor1", tempFG1Location) } }
    public var tempFG2Location: String = "" { didSet { persistString("sources.temperature.sensor2", tempFG2Location) } }
    public var tempFG3Location: String = "" { didSet { persistString("sources.temperature.sensor3", tempFG3Location) } }
    public var isDockIconHidden: Bool = false { didSet { persistBool("general.window.hide_dock_icon", isDockIconHidden) } }

    /// The graph window's border width and orientation, window-level in the
    /// legacy preferences and ordinary catalog settings now.
    @nonobjc public var borderWidth: Int = 4 { didSet { persistInt("general.window.border_width", borderWidth) } }
    @nonobjc public var graphOrientationVertical: Bool = true { didSet { persistChoice("general.window.orientation", graphOrientationVertical ? 0 : 1, Self.orientationNames) } }

    /// The AI token and display-effect settings were live defaults-backed
    /// properties in 0.2.2 and stay live through the store on both backends.
    public var showAITokenGraph: Bool = false { didSet { persistBool("graphs.ai.visible", showAITokenGraph) } }
    public var aiTokensTrackingEnabled: Bool { get { store.boolSetting("ai.tracking.enabled") } set { storeBool("ai.tracking.enabled", newValue) } }
    public var aiTokensDailyAutoReset: Bool { get { store.boolSetting("ai.tracking.auto_reset") } set { storeBool("ai.tracking.auto_reset", newValue) } }
    public var aiTokensDailyBudget: Int { get { max(0, store.intSetting("ai.tracking.daily_budget")) } set { storeInt("ai.tracking.daily_budget", max(0, newValue)) } }
    public var aiTokensBudgetNotifyPercent: Int { get { min(100, max(0, store.intSetting("ai.tracking.notify_percent"))) } set { storeInt("ai.tracking.notify_percent", min(100, max(0, newValue))) } }
    public var aiTokensAggregateByModel: Bool { get { store.boolSetting("ai.tracking.by_model") } set { storeBool("ai.tracking.by_model", newValue) } }
    public var aiTokensAggregateByProvider: Bool { get { store.boolSetting("ai.tracking.by_provider") } set { storeBool("ai.tracking.by_provider", newValue) } }
    public var aiTokensShowRate: Bool { get { store.boolSetting("ai.display.rate") } set { storeBool("ai.display.rate", newValue) } }
    public var aiTokensShowBreakdown: Bool { get { store.boolSetting("ai.display.breakdown") } set { storeBool("ai.display.breakdown", newValue) } }
    public var graphStyle: Int {
        get { store.choiceIndex("appearance.display_effect", Self.effectNames) }
        set { storeString("appearance.display_effect", Self.effectNames[max(0, min(3, newValue))]) }
    }

    /// A graph's visibility (`show<Name>Graph` before 0.2.3).
    @nonobjc func moduleVisible(_ graph: XRGGraphID) -> Bool { store.moduleVisible(graph) }
    @nonobjc func setModuleVisible(_ graph: XRGGraphID, _ visible: Bool) { store.setModuleVisible(graph, visible) }

    /// The collapsed state of the graph window (the `windowIsMinimized`
    /// latch) and the Sensors window's open-at-launch state.
    public var windowCollapsed: Bool { get { store.boolSetting("general.window.collapsed") } set { storeBool("general.window.collapsed", newValue) } }
    public var sensorsWindowOpen: Bool { get { store.boolSetting("general.sensors_window.open") } set { storeBool("general.sensors_window.open", newValue) } }

    /// The applied theme's display name (`portableThemeName` before 0.2.3).
    @nonobjc public var themeName: String { get { store.stringSetting("themes.name") } set { storeString("themes.name", newValue) } }

    /// A whole-number graph setting named by its legacy per-view key
    /// (history sizes and time windows), 0 when unset.
    @nonobjc func historySetting(legacyKey key: String) -> Int { store.intSetting(legacyKey: key) }
    @nonobjc func setHistorySetting(_ value: Int, legacyKey key: String) { store.storeSetting(value, legacyKey: key) }

    /// A saved module size named by its legacy key, nil when unset.
    @nonobjc func moduleSize(legacyKey key: String) -> Double? { store.doubleSetting(legacyKey: key) }
    @nonobjc func setModuleSize(_ value: Double, legacyKey key: String) { store.storeSetting(value, legacyKey: key) }

    /// The saved monitor selection for a source key.
    @nonobjc func monitorSource(legacyKey key: String) -> XRGMonitorSource { store.monitorSource(legacyKey: key) }
    @nonobjc func setMonitorSource(_ source: XRGMonitorSource, legacyKey key: String) { store.storeMonitorSource(source, legacyKey: key) }

    /// The saved curve slots for a hardware sources key.
    @nonobjc func hardwareSources(legacyKey key: String) -> XRGHardwareSources { store.hardwareSources(legacyKey: key) }
    @nonobjc func setHardwareSources(_ sources: XRGHardwareSources, legacyKey key: String) { store.storeHardwareSources(sources, legacyKey: key) }

    /// The saved process inspector options, nil when the saved blob is
    /// invalid (the legacy backend's historical error state).
    @nonobjc func processOptions() -> XRGProcessOptions? { store.processOptions() }
    @nonobjc func setProcessOptions(_ options: XRGProcessOptions) { store.storeProcessOptions(options) }

    /// Persist auto-selection before marking it complete. Repair only the exact legacy placeholders.
    public func configureTemperatureSensors(_ candidates: [String]) -> Bool {
        let locations = [tempFG1Location, tempFG2Location, tempFG3Location]
        let legacy = locations == ["0", "1", "2"]
        // The auto-configuration latch is deliberately not a catalog setting
        // (docs/settings-inventory.md): it keeps its home in NSUserDefaults.
        guard legacy || !store.defaults.bool(forKey: "tempLocationsAutoconfigured") else { return false }
        guard legacy || locations.allSatisfy({ $0.isEmpty }) else { return false }
        var selected: [String] = []
        for key in candidates where !key.isEmpty && !selected.contains(key) {
            selected.append(key)
            if selected.count == 3 { break }
        }
        guard !selected.isEmpty else { return false }
        while selected.count < 3 { selected.append("") }
        for index in 0..<3 {
            let id = "sources.temperature.sensor\(index + 1)"
            if let key = store.legacyKey(forId: id) { store.setLegacyValues([key: selected[index]]) }
        }
        tempFG1Location = selected[0]
        tempFG2Location = selected[1]
        tempFG3Location = selected[2]
        store.defaults.set(true, forKey: "tempLocationsAutoconfigured")
        return true
    }

    public override convenience init() {
        self.init(defaults: .standard)
    }

    /// The settings over an injected defaults suite: the store's legacy
    /// backend, which reads and writes that suite exactly as 0.2.2 did.
    public init(defaults: UserDefaults) {
        store = XRGSettingsStore.legacy(defaults: defaults)
        super.init()
        finishSetup()
    }

    /// The settings over the application's shared document: every stored
    /// value below is hydrated from it and every change written back to it.
    public init(store: XRGSettingsStore) {
        self.store = store
        super.init()
        finishSetup()
        hydrateFromStore()
    }

    private func finishSetup() {
        if store.isDocumentBacked {
            graphPreferencesStorage = store.graphPreferences()
        } else if let data = store.defaults.data(forKey: XRGGraphPreferences.key) {
            do { graphPreferencesStorage = try XRGGraphPreferences(data: data) }
            catch { graphPreferencesError = "Saved graph options are invalid. Apply valid options to replace them." }
        }
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

    /// Load every stored value from the document. Runs once, at init; the
    /// only later writes to the document come from the setters below.
    private func hydrateFromStore() {
        guard store.isDocumentBacked else { return }
        hydrating = true
        defer { hydrating = false }
        func bool(_ id: String) -> Bool { store.boolSetting(id) }
        func int(_ id: String) -> Int { store.intSetting(id) }
        func double(_ id: String) -> Double {
            switch store.value(id) {
            case .int(let value): return Double(value)
            case .double(let value): return value
            default: return 0
            }
        }
        func string(_ id: String) -> String { store.stringSetting(id) }
        func choice(_ id: String, _ names: [String]) -> Int { store.choiceIndex(id, names) }
        func color(_ id: String) -> NSColor {
            guard case .color(let rgba) = store.value(id), rgba.count == 4 else { return NSColor.clear }
            return NSColor(srgbRed: rgba[0], green: rgba[1], blue: rgba[2], alpha: rgba[3])
        }
        // Scalar settings.
        fastCPUUsage = bool("graphs.cpu.fast_bars")
        separateCPUColor = bool("graphs.cpu.separate_colors")
        showCPUTemperature = bool("graphs.cpu.show_temperature")
        cpuTemperatureUnits = choice("graphs.cpu.temperature_units", Self.temperatureNames)
        antiAliasing = bool("appearance.antialiasing")
        ICAO = string("weather.station")
        secondaryWeatherGraph = choice("weather.secondary", Self.secondaryNames)
        weatherHistoryHours = int("weather.history_hours")
        temperatureUnits = choice("weather.units.temperature", Self.temperatureNames)
        distanceUnits = choice("weather.units.distance", Self.distanceNames)
        pressureUnits = choice("weather.units.pressure", Self.pressureNames)
        showMemoryPagingGraph = bool("graphs.memory.show_paging_graph")
        memoryShowWired = bool("graphs.memory.show_wired")
        memoryShowActive = bool("graphs.memory.show_active")
        memoryShowInactive = bool("graphs.memory.show_inactive")
        memoryShowFree = bool("graphs.memory.show_free")
        memoryShowCache = bool("graphs.memory.show_cache")
        memoryShowPage = bool("graphs.memory.show_page")
        graphRefresh = CGFloat(double("graphs.refresh"))
        showLoadAverage = bool("graphs.cpu.show_load_average")
        netMinGraphScale = int("graphs.network.minimum_scale")
        stockSymbols = string("stocks.symbols")
        stockGraphTimeFrame = choice("stocks.timeframe", Self.timeframeNames)
        stockShowChange = bool("stocks.show_change")
        showDJIA = bool("stocks.show_djia")
        windowLevel = choice("general.window.level", Self.windowLevelNames)
        stickyWindow = bool("general.window.sticky_edges")
        checkForUpdates = bool("general.updates.check_on_launch")
        netGraphMode = int("graphs.network.display_mode")
        diskGraphMode = int("graphs.disk.display_mode")
        dropShadow = bool("general.window.drop_shadow")
        showTotalBandwidthSinceBoot = bool("graphs.network.show_total_since_boot")
        showTotalBandwidthSinceLoad = bool("graphs.network.show_total_since_load")
        networkInterface = string("sources.network.interface")
        windowTitle = string("general.window.title")
        autoExpandGraph = bool("general.window.expand_on_hover")
        foregroundWhenExpanding = bool("general.window.bring_to_front_on_expand")
        showSummary = bool("general.window.show_summary")
        minimizeUpDown = choice("general.window.collapse_anchor", Self.collapseNames)
        cpuShowAverageUsage = bool("graphs.cpu.show_average")
        cpuShowUptime = bool("graphs.cpu.show_uptime")
        tempUnits = XRGTemperatureUnits(rawValue: choice("graphs.temperature.units", Self.temperatureNames)) ?? .f
        tempFG1Location = string("sources.temperature.sensor1")
        tempFG2Location = string("sources.temperature.sensor2")
        tempFG3Location = string("sources.temperature.sensor3")
        isDockIconHidden = bool("general.window.hide_dock_icon")
        borderWidth = int("general.window.border_width")
        graphOrientationVertical = store.value("general.window.orientation") != .string("horizontal")
        // Colors, transparencies and the font.
        for (colorId, transparencyId) in [("appearance.window.color", "appearance.window.transparency"),
                                           ("appearance.graph_background.color", "appearance.graph_background.transparency"),
                                           ("appearance.series1.color", "appearance.series1.transparency"),
                                           ("appearance.series2.color", "appearance.series2.transparency"),
                                           ("appearance.series3.color", "appearance.series3.transparency"),
                                           ("appearance.border.color", "appearance.border.transparency"),
                                           ("appearance.text.color", "appearance.text.transparency")] {
            let hydrated = color(colorId).withAlphaComponent(CGFloat(double(transparencyId)))
            switch colorId {
            case "appearance.window.color": backgroundColorStorage = hydrated; backgroundTransparency = CGFloat(double(transparencyId))
            case "appearance.graph_background.color": graphBGColorStorage = hydrated; graphBGTransparency = CGFloat(double(transparencyId))
            case "appearance.series1.color": graphFG1ColorStorage = hydrated; graphFG1Transparency = CGFloat(double(transparencyId))
            case "appearance.series2.color": graphFG2ColorStorage = hydrated; graphFG2Transparency = CGFloat(double(transparencyId))
            case "appearance.series3.color": graphFG3ColorStorage = hydrated; graphFG3Transparency = CGFloat(double(transparencyId))
            case "appearance.border.color": borderColorStorage = hydrated; borderTransparency = CGFloat(double(transparencyId))
            default: textColorStorage = hydrated; textTransparency = CGFloat(double(transparencyId))
            }
        }
        if case .string(let descriptor) = store.value("appearance.font") {
            let parts = descriptor.split(separator: " ")
            if let size = Double(parts.last ?? ""), parts.count >= 1 {
                let name = parts.dropLast().joined(separator: " ")
                fontStorage = name == "System" ? NSFont.systemFont(ofSize: CGFloat(size)) : (NSFont(name: name, size: CGFloat(size)) ?? NSFont.systemFont(ofSize: CGFloat(size)))
                for attributes in [alignRightAttributes, alignLeftAttributes, alignCenterAttributes] {
                    attributes[NSAttributedString.Key.font.rawValue] = fontStorage
                }
            }
        }
        textRectHeight = ("A" as NSString).size(withAttributes: textAttributes(alignRightAttributes)).height
    }

    // MARK: Persistence

    /// A write-through is a document write only: the legacy backend keeps
    /// 0.2.2's in-memory behaviour (`XRGWindowPreferences.apply` restores
    /// stored values without touching the suite).
    private func persist(_ id: String, _ value: XRGSettingsValue) {
        guard !hydrating, store.isDocumentBacked else { return }
        try? store.set(id, value)
    }
    private func persistBool(_ id: String, _ value: Bool) { persist(id, .bool(value)) }
    /// The live properties (AI tokens, display effect, window state) write
    /// through the store on both backends, as 0.2.2's defaults-backed ones did.
    private func storeBool(_ id: String, _ value: Bool) { try? store.set(id, .bool(value)) }
    private func persistInt(_ id: String, _ value: Int) { persist(id, .int(Int64(value))) }
    private func storeInt(_ id: String, _ value: Int) { try? store.set(id, .int(Int64(value))) }
    private func persistDouble(_ id: String, _ value: Double) { persist(id, .double(value)) }
    private func persistString(_ id: String, _ value: String) { persist(id, .string(value)) }
    private func storeString(_ id: String, _ value: String) { try? store.set(id, .string(value)) }
    private func persistChoice(_ id: String, _ index: Int, _ names: [String]) {
        guard names.indices.contains(index) else { return }
        persist(id, .string(names[index]))
    }
    private func persistColor(_ id: String, _ color: NSColor) {
        guard let rgba = color.usingColorSpace(.deviceRGB) else { return }
        persist(id, .color([Double(rgba.redComponent), Double(rgba.greenComponent), Double(rgba.blueComponent), Double(rgba.alphaComponent)]))
    }

    /// The legacy names of each converted choice, in the order 0.2.2 indexed
    /// them (the catalog's option values).
    private static let orientationNames = ["vertical", "horizontal"]
    private static let windowLevelNames = ["normal", "floating", "background"]
    private static let collapseNames = ["start", "end"]
    private static let temperatureNames = ["fahrenheit", "celsius"]
    private static let distanceNames = ["miles", "kilometers"]
    private static let pressureNames = ["inches", "hectopascals"]
    private static let secondaryNames = ["none", "wind", "humidity", "visibility", "dewpoint", "pressure"]
    private static let effectNames = ["normal", "scanlines", "pixel_grid", "retro_dots"]
    private static let timeframeNames = ["1", "3", "6", "12"]
    private static func effectIndex(_ index: Int) -> Int { max(0, min(3, index)) }
    private static func fontDescriptor(_ font: NSFont) -> String {
        let size = font.pointSize == font.pointSize.rounded() ? String(Int(font.pointSize)) : String(Double(font.pointSize))
        return font.fontName == ".AppleSystemUIFont" ? "System \(size)" : "\(font.fontName) \(size)"
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

    // MARK: Themes

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
        if store.isDocumentBacked {
            // The document backend owns the theme fields: the migration
            // converts each archive into the document's colors, and the
            // stored color state follows the document immediately.
            var values: [String: Any] = [:]
            for field in theme.fields {
                values[field.alphaKey] = field.alpha
                values[field.colorKey] = field.archive
            }
            if let name = theme.document?.name { values[XRGTheme.nameKey] = name }
            store.setLegacyValues(values)
            hydrating = true
            for field in theme.fields {
                setValue(field.alpha, forKey: field.alphaKey)
                setValue(field.color, forKey: field.colorKey)
            }
            hydrating = false
        } else {
            // 0.2.2's behaviour, verbatim: the theme's keys are written to
            // the injected domain, and the stored state follows them.
            for field in theme.fields {
                // XRGTheme supplies a fixed allowlist of keys.
                setValue(field.alpha, forKey: field.alphaKey)
                setValue(field.color, forKey: field.colorKey)
                defaults.set(field.alpha, forKey: field.alphaKey)
                defaults.set(field.archive, forKey: field.colorKey)
            }
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
            try applyThemeDictionary(dictionary, defaults: store.defaults)
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