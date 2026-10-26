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
import UniformTypeIdentifiers

@MainActor @objc public protocol XRGPreferencesDataSource: NSObjectProtocol {
    var xrgGraphWindow: XRGGraphWindow? { get }
}

@MainActor @objc(XRGPrefController) @objcMembers
public final class XRGPrefController: NSObject, NSToolbarDelegate, NSWindowDelegate {
    private let defaults: UserDefaults
    private let center: NotificationCenter
    private let sensorSource: () -> [XRGSensorData]
    private let interfaceSource: (XRGGraphWindow) -> [String]
    private let openURL: (URL) -> Bool
    private let errorNotice: (String, NSWindow?) -> Void
    private let showFont: (NSFont?) -> Void
    private let chooseOpen: (NSWindow, @escaping (URL?) -> Void) -> Void
    private let chooseSave: (NSWindow, @escaping (URL?) -> Void) -> Void
    private let readFile: (URL) throws -> Data
    private let writeFile: (Data, URL) throws -> Void
    private let animate: Bool
    private var didConfigure = false
    @nonobjc private(set) var toolbarItems: [NSToolbarItem.Identifier: NSToolbarItem] = [:]
    public private(set) var toolbar: NSToolbar?
    public private(set) var currentView: NSView?
    public weak var xrgGraphWindow: XRGGraphWindow?
    public var temperatureSensors: [XRGSensorData] = []
    public private(set) var showAITokensGraph: NSButton?
    @IBOutlet public var GeneralPrefView: NSView?
    @IBOutlet public var ColorPrefView: NSView?
    @IBOutlet public var CPUPrefView: NSView?
    @IBOutlet public var MemoryPrefView: NSView?
    @IBOutlet public var TemperaturePrefView: NSView?
    @IBOutlet public var NetworkPrefView: NSView?
    @IBOutlet public var DiskPrefView: NSView?
    @IBOutlet public var WeatherPrefView: NSView?
    @IBOutlet public var StockPrefView: NSView?
    @IBOutlet public var AIPrefView: NSView?
    @IBOutlet public var window: NSWindow?
    @IBOutlet public var borderWidthSlider: NSSlider?
    @IBOutlet public var showCPUGraph: NSButton?
    @IBOutlet public var showGPUGraph: NSButton?
    @IBOutlet public var showMemoryGraph: NSButton?
    @IBOutlet public var showBatteryGraph: NSButton?
    @IBOutlet public var showTemperatureGraph: NSButton?
    @IBOutlet public var showNetGraph: NSButton?
    @IBOutlet public var showDiskGraph: NSButton?
    @IBOutlet public var showWeatherGraph: NSButton?
    @IBOutlet public var showStockGraph: NSButton?
    @IBOutlet public var showAITokenGraph: NSButton?
    @IBOutlet public var graphOrientation: NSPopUpButton?
    @IBOutlet public var enableAntiAliasing: NSButton?
    @IBOutlet public var graphRefreshValue: NSSlider?
    @IBOutlet public var graphRefreshText: NSTextField?
    @IBOutlet public var windowLevel: NSPopUpButton?
    @IBOutlet public var stickyWindow: NSButton?
    @IBOutlet public var checkForUpdates: NSButton?
    @IBOutlet public var dropShadow: NSButton?
    @IBOutlet public var windowTitle: NSTextField?
    @IBOutlet public var generalAutoExpandGraph: NSButton?
    @IBOutlet public var generalForegroundWhenExpanding: NSButton?
    @IBOutlet public var generalShowSummary: NSButton?
    @IBOutlet public var generalMinimizeUpDown: NSPopUpButton?
    @IBOutlet public var backgroundColorWell: NSColorWell?
    @IBOutlet public var backgroundTransparency: NSSlider?
    @IBOutlet public var graphBGColorWell: NSColorWell?
    @IBOutlet public var graphBGTransparency: NSSlider?
    @IBOutlet public var graphFG1ColorWell: NSColorWell?
    @IBOutlet public var graphFG1Transparency: NSSlider?
    @IBOutlet public var graphFG2ColorWell: NSColorWell?
    @IBOutlet public var graphFG2Transparency: NSSlider?
    @IBOutlet public var graphFG3ColorWell: NSColorWell?
    @IBOutlet public var graphFG3Transparency: NSSlider?
    @IBOutlet public var borderColorWell: NSColorWell?
    @IBOutlet public var borderTransparency: NSSlider?
    @IBOutlet public var textColorWell: NSColorWell?
    @IBOutlet public var textTransparency: NSSlider?
    public var fontButton: NSButton?
    @IBOutlet public var fastCPUUsageCheckbox: NSButton?
    @IBOutlet public var separateCPUColor: NSButton?
    @IBOutlet public var showCPUTemperature: NSButton?
    @IBOutlet public var cpuTemperatureUnits: NSPopUpButton?
    @IBOutlet public var cpuShowAverageUsage: NSButton?
    @IBOutlet public var showLoadAverage: NSButton?
    @IBOutlet public var cpuShowUptime: NSButton?
    @IBOutlet public var memoryShowWired: NSButton?
    @IBOutlet public var memoryShowActive: NSButton?
    @IBOutlet public var memoryShowInactive: NSButton?
    @IBOutlet public var memoryShowFree: NSButton?
    @IBOutlet public var memoryShowCache: NSButton?
    @IBOutlet public var memoryShowPage: NSButton?
    @IBOutlet public var memoryShowPagingGraph: NSButton?
    @IBOutlet public var tempUnits: NSPopUpButton?
    @IBOutlet public var tempFG1Location: NSPopUpButton?
    @IBOutlet public var tempFG2Location: NSPopUpButton?
    @IBOutlet public var tempFG3Location: NSPopUpButton?
    @IBOutlet public var networkInterface: NSPopUpButton?
    @IBOutlet public var netMinGraphScaleUnits: NSPopUpButton?
    @IBOutlet public var netMinGraphScaleValue: NSTextField?
    @IBOutlet public var netGraphMode: NSMatrix?
    @IBOutlet public var showTotalBandwidthSinceBoot: NSButton?
    @IBOutlet public var showTotalBandwidthSinceLoad: NSButton?
    @IBOutlet public var diskGraphMode: NSMatrix?
    @IBOutlet public var ICAOCode: NSTextField?
    @IBOutlet public var secondaryWeatherGraph: NSPopUpButton?
    @IBOutlet public var temperatureUnits: NSPopUpButton?
    @IBOutlet public var distanceUnits: NSPopUpButton?
    @IBOutlet public var pressureUnits: NSPopUpButton?
    @IBOutlet public var weatherStationListLink: NSButton?
    @IBOutlet public var stockSymbols: NSTextField?
    @IBOutlet public var stockGraphTimeFrame: NSPopUpButton?
    @IBOutlet public var stockShowChange: NSButton?
    @IBOutlet public var showDJIA: NSButton?
    @IBOutlet public var hiddenModules: NSView?
    @IBOutlet public var displayedModules: NSView?

    public override init() {
        defaults = .standard; center = .default; animate = true
        sensorSource = {
            let miner = XRGTemperatureMiner.shared
            return miner.locationKeys(includingUnknown: XRGTemperatureView.showUnknownSensors()).compactMap { miner.sensor(forLocation: $0) }
        }
        interfaceSource = { $0.netView?.miner.networkInterfaces() ?? [] }
        openURL = { NSWorkspace.shared.open($0) }; errorNotice = Self.presentError
        showFont = { font in
            NSFontPanel.shared.makeKeyAndOrderFront(nil)
            if let font { NSFontManager.shared.setSelectedFont(font, isMultiple: false) }
        }
        chooseOpen = Self.openThemePanel; chooseSave = Self.saveThemePanel
        readFile = { try Data(contentsOf: $0) }; writeFile = { try $0.write(to: $1, options: .atomic) }
        super.init()
    }
    @nonobjc init(defaults: UserDefaults, center: NotificationCenter = NotificationCenter(),
                  sensors: @escaping () -> [XRGSensorData] = { [] }, interfaces: @escaping (XRGGraphWindow) -> [String] = { _ in [] },
                  openURL: @escaping (URL) -> Bool = { _ in true }, error: @escaping (String, NSWindow?) -> Void = { _, _ in },
                  fontPanel: @escaping (NSFont?) -> Void = { _ in },
                  chooseOpen: @escaping (NSWindow, @escaping (URL?) -> Void) -> Void = { _, done in done(nil) },
                  chooseSave: @escaping (NSWindow, @escaping (URL?) -> Void) -> Void = { _, done in done(nil) },
                  readFile: @escaping (URL) throws -> Data = { try Data(contentsOf: $0) },
                  writeFile: @escaping (Data, URL) throws -> Void = { try $0.write(to: $1, options: .atomic) }) {
        self.defaults = defaults; self.center = center; sensorSource = sensors; interfaceSource = interfaces
        self.openURL = openURL; errorNotice = error; showFont = fontPanel; self.chooseOpen = chooseOpen; self.chooseSave = chooseSave
        self.readFile = readFile; self.writeFile = writeFile; animate = false
        super.init()
    }
    public nonisolated override func awakeFromNib() {
        super.awakeFromNib()
        MainActor.assumeIsolated {
            if xrgGraphWindow == nil { xrgGraphWindow = (NSApp.delegate as? any XRGPreferencesDataSource)?.xrgGraphWindow }
            configure()
        }
    }
    public func configure() {
        if !didConfigure, let window {
            didConfigure = true; window.isReleasedWhenClosed = false; window.delegate = self
            let toolbar = NSToolbar(identifier: "preferenceToolbar"); self.toolbar = toolbar
            toolbar.delegate = self; toolbar.allowsUserCustomization = false; toolbar.autosavesConfiguration = false
            toolbar.displayMode = .iconAndLabel; window.toolbar = toolbar
            if let GeneralPrefView {
                let size = NSSize(width: max(500, GeneralPrefView.frame.width), height: GeneralPrefView.frame.height)
                window.contentView = GeneralPrefView; window.setContentSize(size); currentView = GeneralPrefView
            }
            window.title = "General Preferences"; toolbar.selectedItemIdentifier = .init("General")
        }
        setUpGeneralPanel(); setUpColorPanel(); setUpCPUPanel(); setUpMemoryPanel(); setUpTemperaturePanel()
        setUpNetworkPanel(); setUpDiskPanel(); setUpWeatherPanel(); setUpStockPanel(); setUpAIPanel()
    }
    private var settings: XRGSettings? { xrgGraphWindow?.appSettings }
    private func bind(_ control: NSControl?, _ action: Selector, target: AnyObject? = nil) {
        control?.target = target ?? xrgGraphWindow; control?.action = action
    }
    private func check(_ button: NSButton?, _ key: String, _ action: Selector) {
        bind(button, action); button?.state = (settings?.value(forKey: key) as? NSNumber)?.boolValue == true ? .on : .off
    }
    private func popup(_ control: NSPopUpButton?, titles: [String]?, selected: Int, action: Selector) {
        bind(control, action)
        if let titles { control?.removeAllItems(); control?.addItems(withTitles: titles) }
        if let control, control.numberOfItems > 0 { control.selectItem(at: control.itemArray.indices.contains(selected) ? selected : 0) }
    }
    private func redrawGraphs() {
        xrgGraphWindow?.contentView?.needsDisplay = true
        for view in xrgGraphWindow?.contentView?.subviews ?? [] { view.needsDisplay = true }
    }
    public func setUpGeneralPanel() {
        guard let settings else { return }
        bind(windowTitle, #selector(XRGGraphWindow.setWindowTitle(_:))); windowTitle?.stringValue = settings.windowTitle
        bind(borderWidthSlider, #selector(XRGGraphWindow.setBorderWidthAction(_:))); borderWidthSlider?.intValue = xrgGraphWindow?.borderWidth ?? 4
        popup(graphOrientation, titles: nil, selected: xrgGraphWindow?.moduleManager?.graphOrientationVertical == false ? 1 : 0, action: #selector(XRGGraphWindow.setGraphOrientation(_:)))
        check(enableAntiAliasing, "antiAliasing", #selector(XRGGraphWindow.setAntiAliasing(_:)))
        check(stickyWindow, "stickyWindow", #selector(XRGGraphWindow.setStickyWindow(_:)))
        check(checkForUpdates, "checkForUpdates", #selector(XRGGraphWindow.setCheckForUpdates(_:)))
        check(dropShadow, "dropShadow", #selector(XRGGraphWindow.setDropShadow(_:)))
        check(generalAutoExpandGraph, "autoExpandGraph", #selector(XRGGraphWindow.setAutoExpandGraph(_:)))
        check(generalForegroundWhenExpanding, "foregroundWhenExpanding", #selector(XRGGraphWindow.setForegroundWhenExpanding(_:)))
        check(generalShowSummary, "showSummary", #selector(XRGGraphWindow.setShowSummary(_:)))
        bind(showCPUGraph, #selector(XRGGraphWindow.setShowCPUGraph(_:))); showCPUGraph?.state = xrgGraphWindow?.moduleManager?.getModule(byName: "CPU")?.isDisplayed == true ? .on : .off
        bind(showGPUGraph, #selector(XRGGraphWindow.setShowGPUGraph(_:))); showGPUGraph?.state = xrgGraphWindow?.moduleManager?.getModule(byName: "GPU")?.isDisplayed == true ? .on : .off
        bind(showMemoryGraph, #selector(XRGGraphWindow.setShowMemoryGraph(_:))); showMemoryGraph?.state = xrgGraphWindow?.moduleManager?.getModule(byName: "Memory")?.isDisplayed == true ? .on : .off
        bind(showBatteryGraph, #selector(XRGGraphWindow.setShowBatteryGraph(_:))); showBatteryGraph?.state = xrgGraphWindow?.moduleManager?.getModule(byName: "Battery")?.isDisplayed == true ? .on : .off
        bind(showTemperatureGraph, #selector(XRGGraphWindow.setShowTemperatureGraph(_:))); showTemperatureGraph?.state = xrgGraphWindow?.moduleManager?.getModule(byName: "Temperature")?.isDisplayed == true ? .on : .off
        bind(showNetGraph, #selector(XRGGraphWindow.setShowNetGraph(_:))); showNetGraph?.state = xrgGraphWindow?.moduleManager?.getModule(byName: "Network")?.isDisplayed == true ? .on : .off
        bind(showDiskGraph, #selector(XRGGraphWindow.setShowDiskGraph(_:))); showDiskGraph?.state = xrgGraphWindow?.moduleManager?.getModule(byName: "Disk")?.isDisplayed == true ? .on : .off
        bind(showWeatherGraph, #selector(XRGGraphWindow.setShowWeatherGraph(_:))); showWeatherGraph?.state = xrgGraphWindow?.moduleManager?.getModule(byName: "Weather")?.isDisplayed == true ? .on : .off
        bind(showStockGraph, #selector(XRGGraphWindow.setShowStockGraph(_:))); showStockGraph?.state = xrgGraphWindow?.moduleManager?.getModule(byName: "Stock")?.isDisplayed == true ? .on : .off
        if showAITokenGraph == nil && showAITokensGraph == nil, let existing = findAIVisibilityButton(in: GeneralPrefView) {
            showAITokenGraph = existing; showAITokensGraph = existing
        }
        if showAITokenGraph == nil && showAITokensGraph == nil, let stock = showStockGraph, let container = stock.superview {
            let button = NSButton(checkboxWithTitle: "AI Tokens", target: nil, action: nil)
            button.frame = stock.frame.offsetBy(dx: 0, dy: -stock.frame.height - 8); container.addSubview(button); showAITokensGraph = button
        }
        let ai = showAITokenGraph ?? showAITokensGraph
        ai?.toolTip = "Enable/Disable the AI Token Graph"
        bind(ai, #selector(XRGGraphWindow.setShowAITokenGraph(_:))); ai?.state = xrgGraphWindow?.moduleManager?.getModule(byName: "AI Tokens")?.isDisplayed == true ? .on : .off
        bind(graphRefreshValue, #selector(setGraphRefreshAction(_:)), target: self)
        let refresh = XRGGraphWindow.validRefresh(settings.graphRefresh)
        if let slider = graphRefreshValue { slider.minValue = min(slider.minValue, refresh); slider.maxValue = max(slider.maxValue, refresh); slider.doubleValue = refresh }
        updateRefreshText()
        popup(windowLevel, titles: ["Window Level", "Normal", "Foreground", "Background"], selected: settings.windowLevel + 1, action: #selector(XRGGraphWindow.setWindowLevel(_:)))
        windowLevel?.item(at: 0)?.isEnabled = false
        popup(generalMinimizeUpDown, titles: nil, selected: settings.minimizeUpDown, action: #selector(XRGGraphWindow.setMinimizeUpDown(_:)))
    }
    private func findAIVisibilityButton(in view: NSView?) -> NSButton? {
        guard let view else { return nil }
        if let button = view as? NSButton, button.title == "AI Tokens" { return button }
        for child in view.subviews { if let button = findAIVisibilityButton(in: child) { return button } }
        return nil
    }
    public func setUpColorPanel() {
        setUpWell(backgroundColorWell, withTransparency: backgroundTransparency)
        setUpWell(graphBGColorWell, withTransparency: graphBGTransparency)
        setUpWell(graphFG1ColorWell, withTransparency: graphFG1Transparency)
        setUpWell(graphFG2ColorWell, withTransparency: graphFG2Transparency)
        setUpWell(graphFG3ColorWell, withTransparency: graphFG3Transparency)
        setUpWell(borderColorWell, withTransparency: borderTransparency)
        setUpWell(textColorWell, withTransparency: textTransparency)
        bind(fontButton, #selector(setFont(_:)), target: self)
        guard let panel = ColorPrefView else { return }
        let style: NSPopUpButton
        if let existing = panel.viewWithTag(1010) as? NSPopUpButton { style = existing }
        else {
            panel.setFrameSize(NSSize(width: panel.frame.width, height: panel.frame.height + 60))
            for view in panel.subviews { view.setFrameOrigin(NSPoint(x: view.frame.minX, y: view.frame.minY + 60)) }
            let label = NSTextField(labelWithString: "Graph Style:"); label.frame = NSRect(x: 20, y: 20, width: 80, height: 17); panel.addSubview(label)
            style = NSPopUpButton(frame: NSRect(x: 105, y: 15, width: 150, height: 26)); style.tag = 1010
            style.addItems(withTitles: ["Normal", "Scanlines", "Pixel Grid", "Retro Dots"]); panel.addSubview(style)
        }
        popup(style, titles: nil, selected: settings?.graphStyle ?? 0, action: #selector(XRGGraphWindow.setGraphStyle(_:)))
    }
    public func setUpWell(_ well: NSColorWell?, withTransparency slider: NSSlider?) {
        guard let well else { return }
        bind(well, #selector(XRGGraphWindow.setObjectsToColor(_:))); well.isContinuous = true
        if let color = xrgGraphWindow?.colorForTag(well.tag) { well.color = color }
        bind(slider, #selector(XRGGraphWindow.setObjectsToTransparency(_:)))
        if let value = xrgGraphWindow?.transparencyForTag(well.tag) { slider?.floatValue = value }
    }
    public func setUpCPUPanel() {
        check(fastCPUUsageCheckbox, "fastCPUUsage", #selector(XRGGraphWindow.setFastCPUUsageCheckbox(_:)))
        check(separateCPUColor, "separateCPUColor", #selector(XRGGraphWindow.setSeparateCPUColor(_:)))
        check(showCPUTemperature, "showCPUTemperature", #selector(XRGGraphWindow.setShowCPUTemperature(_:)))
        check(showLoadAverage, "showLoadAverage", #selector(XRGGraphWindow.setShowLoadAverage(_:)))
        check(cpuShowAverageUsage, "cpuShowAverageUsage", #selector(XRGGraphWindow.setCPUShowAverageUsage(_:)))
        check(cpuShowUptime, "cpuShowUptime", #selector(XRGGraphWindow.setCPUShowUptime(_:)))
        popup(cpuTemperatureUnits, titles: nil, selected: settings?.cpuTemperatureUnits ?? 0, action: #selector(XRGGraphWindow.setCPUTemperatureUnits(_:)))
    }
    public func setUpMemoryPanel() {
        check(memoryShowWired, "memoryShowWired", #selector(XRGGraphWindow.setMemoryCheckbox(_:)))
        check(memoryShowActive, "memoryShowActive", #selector(XRGGraphWindow.setMemoryCheckbox(_:)))
        check(memoryShowInactive, "memoryShowInactive", #selector(XRGGraphWindow.setMemoryCheckbox(_:)))
        check(memoryShowFree, "memoryShowFree", #selector(XRGGraphWindow.setMemoryCheckbox(_:)))
        check(memoryShowCache, "memoryShowCache", #selector(XRGGraphWindow.setMemoryCheckbox(_:)))
        check(memoryShowPage, "memoryShowPage", #selector(XRGGraphWindow.setMemoryCheckbox(_:)))
        check(memoryShowPagingGraph, "showMemoryPagingGraph", #selector(XRGGraphWindow.setMemoryCheckbox(_:)))
    }
    public func setUpTemperaturePanel() {
        popup(tempUnits, titles: ["Fahrenheit", "Celsius"], selected: settings?.tempUnits.rawValue ?? 0, action: #selector(XRGGraphWindow.setTempUnits(_:)))
        temperatureSensors = settings == nil ? [] : sensorSource()
        // Keys belong to menu items, so discovery/reordering cannot turn a selected index into a different sensor.
        for (index, control) in [tempFG1Location, tempFG2Location, tempFG3Location].enumerated() {
            guard let control else { continue }
            control.removeAllItems(); bind(control, #selector(sensorChoiceChanged(_:)), target: self)
            guard !temperatureSensors.isEmpty else { control.addItem(withTitle: "No Sensors Found"); control.item(at: 0)?.isEnabled = false; continue }
            let selector = [#selector(XRGGraphWindow.setTempFG1Location(_:)), #selector(XRGGraphWindow.setTempFG2Location(_:)), #selector(XRGGraphWindow.setTempFG3Location(_:))][index]
            for (key, label) in [("", "None")] + temperatureSensors.map({ ($0.key, $0.label()) }) {
                let item = NSMenuItem(title: label, action: selector, keyEquivalent: ""); item.representedObject = key; item.target = xrgGraphWindow; control.menu?.addItem(item)
            }
            let selected = [settings?.tempFG1Location, settings?.tempFG2Location, settings?.tempFG3Location][index] ?? ""
            control.selectItem(at: control.itemArray.firstIndex { $0.representedObject as? String == selected } ?? 0)
        }
    }
    public func setUpNetworkPanel() {
        bind(netMinGraphScaleUnits, #selector(setNetMinGraphUnitsAction(_:)), target: self)
        bind(netMinGraphScaleValue, #selector(setNetMinGraphValueAction(_:)), target: self)
        let scale = max(0, settings?.netMinGraphScale ?? 1024)
        let unit = scale >= 1_048_576 && scale % 1_048_576 == 0 ? 2 : scale >= 1024 && scale % 1024 == 0 ? 1 : 0
        netMinGraphScaleUnits?.selectItem(at: unit); netMinGraphScaleValue?.stringValue = String(scale / [1, 1024, 1_048_576][unit])
        bind(netGraphMode, #selector(XRGGraphWindow.setNetGraphMode(_:))); netGraphMode?.selectCell(atRow: settings?.netGraphMode ?? 0, column: 0)
        check(showTotalBandwidthSinceBoot, "showTotalBandwidthSinceBoot", #selector(XRGGraphWindow.setShowTotalBandwidthSinceBoot(_:)))
        check(showTotalBandwidthSinceLoad, "showTotalBandwidthSinceLoad", #selector(XRGGraphWindow.setShowTotalBandwidthSinceLoad(_:)))
        bind(networkInterface, #selector(networkChoiceChanged(_:)), target: self); networkInterface?.removeAllItems(); networkInterface?.addItem(withTitle: "All Active")
        networkInterface?.item(at: 0)?.representedObject = "All"
        if let graph = xrgGraphWindow {
            for name in interfaceSource(graph) { networkInterface?.addItem(withTitle: name); networkInterface?.lastItem?.representedObject = name }
        }
        if let index = networkInterface?.itemArray.firstIndex(where: { $0.representedObject as? String == settings?.networkInterface }) { networkInterface?.selectItem(at: index) }
    }
    @IBAction public func sensorChoiceChanged(_ sender: NSPopUpButton) {
        guard let item = sender.selectedItem else { return }
        if sender === tempFG1Location { xrgGraphWindow?.setTempFG1Location(item) }
        else if sender === tempFG2Location { xrgGraphWindow?.setTempFG2Location(item) }
        else if sender === tempFG3Location { xrgGraphWindow?.setTempFG3Location(item) }
    }
    @IBAction public func networkChoiceChanged(_ sender: NSPopUpButton) {
        settings?.networkInterface = sender.selectedItem?.representedObject as? String ?? "All"
    }
    public func setUpDiskPanel() { bind(diskGraphMode, #selector(XRGGraphWindow.setDiskGraphMode(_:))); diskGraphMode?.selectCell(atRow: settings?.diskGraphMode ?? 0, column: 0) }
    public func setUpWeatherPanel() {
        bind(ICAOCode, #selector(XRGGraphWindow.setICAO(_:))); ICAOCode?.stringValue = settings?.ICAO ?? ""
        weatherStationListLink?.title = "Station Listing"; bind(weatherStationListLink, #selector(openWeatherStationList(_:)), target: self)
        popup(secondaryWeatherGraph, titles: ["None", "Wind Speed", "Relative Humidity", "Visibility", "Dewpoint", "Pressure"], selected: settings?.secondaryWeatherGraph ?? 0, action: #selector(XRGGraphWindow.setSecondaryWeatherGraph(_:)))
        popup(temperatureUnits, titles: ["Fahrenheit", "Celsius"], selected: settings?.temperatureUnits ?? 0, action: #selector(XRGGraphWindow.setTemperatureUnits(_:)))
        popup(distanceUnits, titles: ["Miles", "Kilometers"], selected: settings?.distanceUnits ?? 0, action: #selector(XRGGraphWindow.setDistanceUnits(_:)))
        popup(pressureUnits, titles: ["Inches", "Hectopascals"], selected: settings?.pressureUnits ?? 0, action: #selector(XRGGraphWindow.setPressureUnits(_:)))
    }
    public func setUpStockPanel() {
        bind(stockSymbols, #selector(XRGGraphWindow.setStockSymbols(_:))); stockSymbols?.stringValue = settings?.stockSymbols ?? ""
        popup(stockGraphTimeFrame, titles: ["1 Month", "3 Months", "6 Months", "12 Months"], selected: settings?.stockGraphTimeFrame ?? 3, action: #selector(XRGGraphWindow.setStockGraphTimeFrame(_:)))
        check(stockShowChange, "stockShowChange", #selector(XRGGraphWindow.setStockShowChange(_:)))
        check(showDJIA, "showDJIA", #selector(XRGGraphWindow.setShowDJIA(_:)))
    }
    @nonobjc static let aiDefaults: [String: Any] = ["aiTokensTrackingEnabled": false, "aiTokensDailyAutoReset": true, "aiTokensDailyBudget": 0,
        "aiTokensBudgetNotifyPercent": 80, "aiTokensAggregateByModel": true, "aiTokensAggregateByProvider": false, "aiTokensShowRate": true, "aiTokensShowBreakdown": true, "graphStyle": 0]
    @nonobjc static let aiCheckboxes = [(1000, "Enable AI Token Tracking", "aiTokensTrackingEnabled"), (1001, "Auto-reset daily counters at midnight", "aiTokensDailyAutoReset"),
        (1004, "Track usage by AI model", "aiTokensAggregateByModel"), (1005, "Track usage by AI provider", "aiTokensAggregateByProvider"),
        (1006, "Show token rate (tokens/second)", "aiTokensShowRate"), (1007, "Show detailed breakdown", "aiTokensShowBreakdown")]
    public func setUpAIPanel() {
        defaults.register(defaults: Self.aiDefaults.filter { defaults.object(forKey: $0.key) == nil })
        if AIPrefView == nil { AIPrefView = NSView(frame: NSRect(x: 0, y: 0, width: 500, height: 550)) }
        guard let panel = AIPrefView else { return }
        if panel.viewWithTag(1000) == nil {
            let title = NSTextField(labelWithString: "AI Token Tracking Settings"); title.font = .boldSystemFont(ofSize: 14); title.frame = NSRect(x: 20, y: 500, width: 460, height: 24); panel.addSubview(title)
            let ys: [CGFloat] = [460, 430, 310, 280, 250, 220]
            for (index, field) in Self.aiCheckboxes.enumerated() {
                let button = NSButton(checkboxWithTitle: field.1, target: nil, action: nil); button.frame = NSRect(x: 20, y: ys[index], width: 460, height: 20); button.tag = field.0; panel.addSubview(button)
            }
            for (tag, title, y) in [(1002, "Daily token budget (0 = no limit):", CGFloat(390)), (1003, "Budget notification threshold (%):", CGFloat(350))] {
                let label = NSTextField(labelWithString: title); label.frame = NSRect(x: 20, y: y, width: 305, height: 20); panel.addSubview(label)
                let field = NSTextField(frame: NSRect(x: 340, y: y, width: 140, height: 22)); field.tag = tag; field.setAccessibilityLabel(title); panel.addSubview(field)
            }
            for (index, title) in ["Reset Session", "Reset Daily"].enumerated() {
                let button = NSButton(title: title, target: self, action: index == 0 ? #selector(resetSessionCounters(_:)) : #selector(resetDailyCounters(_:)))
                button.bezelStyle = .rounded; button.frame = NSRect(x: 20 + index * 160, y: 160, width: 150, height: 28); panel.addSubview(button)
            }
        }
        for field in Self.aiCheckboxes { (panel.viewWithTag(field.0) as? NSButton)?.state = defaults.bool(forKey: field.2) ? .on : .off }
        (panel.viewWithTag(1002) as? NSTextField)?.integerValue = defaults.integer(forKey: "aiTokensDailyBudget")
        (panel.viewWithTag(1003) as? NSTextField)?.integerValue = defaults.integer(forKey: "aiTokensBudgetNotifyPercent")
    }
    private func updateRefreshText() {
        let refresh = XRGGraphWindow.validRefresh(settings?.graphRefresh)
        graphRefreshText?.stringValue = abs(refresh - 1) < 0.05 ? "Graph updates every second" : String(format: "Graph updates every %.1f seconds", refresh)
    }
    @IBAction public func setGraphRefreshAction(_ sender: Any?) {
        xrgGraphWindow?.setGraphRefreshActionPart2(sender)
        if let value = settings?.graphRefresh, value.isFinite, value > 0 { graphRefreshValue?.doubleValue = Double(value) }
        updateRefreshText()
    }
    @nonobjc static func networkScale(_ text: String, unit: Int) -> Int? {
        guard (0...2).contains(unit), let value = Int(text.trimmingCharacters(in: .whitespacesAndNewlines)), value >= 0 else { return nil }
        let result = value.multipliedReportingOverflow(by: [1, 1024, 1_048_576][unit]); return result.overflow ? nil : result.partialValue
    }
    private func updateNetworkScale() {
        guard let field = netMinGraphScaleValue, let units = netMinGraphScaleUnits,
              let value = Self.networkScale(field.stringValue, unit: units.indexOfSelectedItem) else { errorNotice("The minimum network scale must be a nonnegative whole number within range.", window); return }
        settings?.netMinGraphScale = value
    }
    @IBAction public func setNetMinGraphUnitsAction(_ sender: Any?) { updateNetworkScale() }
    @IBAction public func setNetMinGraphValueAction(_ sender: Any?) { updateNetworkScale() }
    public func setUpModuleSelection() {}
    public func colorWellForTag(_ tag: Int32) -> NSColorWell? {
        [backgroundColorWell, graphBGColorWell, graphFG1ColorWell, graphFG2ColorWell, graphFG3ColorWell, borderColorWell, textColorWell].compactMap { $0 }.first { $0.tag == Int(tag) }
    }
    @IBAction public func setFont(_ sender: Any?) { showFont(settings?.graphFont) }
    @IBAction public func openWeatherStationList(_ sender: Any?) { _ = openURL(URL(string: "https://download.gauchosoft.com/xrg/stations.txt")!) }
    @IBAction public func resetSessionCounters(_ sender: Any?) { center.post(name: .xrgAITokensDidResetSession, object: self) }
    @IBAction public func resetDailyCounters(_ sender: Any?) { center.post(name: .xrgAITokensDidResetDaily, object: self) }

    @nonobjc func preferencesSnapshot() throws -> [String: Any] {
        guard let settings, xrgGraphWindow != nil else { return [:] }
        var values = try themeDictionary()
        if let button = generalAutoExpandGraph { values["autoExpandGraph"] = button.state == .on }
        if let button = generalForegroundWhenExpanding { values["foregroundWhenExpanding"] = button.state == .on }
        if let button = generalShowSummary { values["showSummary"] = button.state == .on }
        if let button = showCPUGraph { values["showCPUGraph"] = button.state == .on }
        if let button = showGPUGraph { values["showGPUGraph"] = button.state == .on }
        if let button = showMemoryGraph { values["showMemoryGraph"] = button.state == .on }
        if let button = showBatteryGraph { values["showBatteryGraph"] = button.state == .on }
        if let button = showTemperatureGraph { values["showTemperatureGraph"] = button.state == .on }
        if let button = showNetGraph { values["showNetworkGraph"] = button.state == .on }
        if let button = showDiskGraph { values["showDiskGraph"] = button.state == .on }
        if let button = showWeatherGraph { values["showWeatherGraph"] = button.state == .on }
        if let button = showStockGraph { values["showStockGraph"] = button.state == .on }
        if let button = fastCPUUsageCheckbox { values["showCPUBars"] = button.state == .on }
        if let button = enableAntiAliasing { values["antiAliasing"] = button.state == .on }
        if let button = separateCPUColor { values["separateCPUColor"] = button.state == .on }
        if let button = showLoadAverage { values["showLoadAverage"] = button.state == .on }
        if let button = showCPUTemperature { values["showCPUTemperature"] = button.state == .on }
        if let button = cpuShowAverageUsage { values["cpuShowAverageUsage"] = button.state == .on }
        if let button = cpuShowUptime { values["cpuShowUptime"] = button.state == .on }
        if let button = memoryShowPagingGraph { values["showMemoryPagingGraph"] = button.state == .on }
        if let button = memoryShowWired { values["memoryShowWired"] = button.state == .on }
        if let button = memoryShowActive { values["memoryShowActive"] = button.state == .on }
        if let button = memoryShowInactive { values["memoryShowInactive"] = button.state == .on }
        if let button = memoryShowFree { values["memoryShowFree"] = button.state == .on }
        if let button = memoryShowCache { values["memoryShowCache"] = button.state == .on }
        if let button = memoryShowPage { values["memoryShowPage"] = button.state == .on }
        if let button = stockShowChange { values["stockShowChange"] = button.state == .on }
        if let button = showDJIA { values["showDJIA"] = button.state == .on }
        if let button = stickyWindow { values["stickyWindow"] = button.state == .on }
        if let button = checkForUpdates { values["checkForUpdates"] = button.state == .on }
        if let button = dropShadow { values["dropShadow"] = button.state == .on }
        if let button = showTotalBandwidthSinceBoot { values["showTotalBandwidthSinceBoot"] = button.state == .on }
        if let button = showTotalBandwidthSinceLoad { values["showTotalBandwidthSinceLoad"] = button.state == .on }
        if let popup = secondaryWeatherGraph, popup.indexOfSelectedItem >= 0 { values["secondaryWeatherGraph"] = popup.indexOfSelectedItem }
        if let popup = temperatureUnits, popup.indexOfSelectedItem >= 0 { values["temperatureUnits"] = popup.indexOfSelectedItem }
        if let popup = distanceUnits, popup.indexOfSelectedItem >= 0 { values["distanceUnits"] = popup.indexOfSelectedItem }
        if let popup = pressureUnits, popup.indexOfSelectedItem >= 0 { values["pressureUnits"] = popup.indexOfSelectedItem }
        if let popup = generalMinimizeUpDown, popup.indexOfSelectedItem >= 0 { values["minimizeUpDown"] = popup.indexOfSelectedItem }
        if let popup = cpuTemperatureUnits, popup.indexOfSelectedItem >= 0 { values["cpuTemperatureUnits"] = popup.indexOfSelectedItem }
        if let popup = tempUnits, popup.indexOfSelectedItem >= 0 { values["tempUnits"] = popup.indexOfSelectedItem }
        if let popup = stockGraphTimeFrame, popup.indexOfSelectedItem >= 0 { values["stockGraphTimeFrame"] = popup.indexOfSelectedItem }
        if let button = showAITokenGraph ?? showAITokensGraph { values["showAITokenGraph"] = button.state == .on }
        if let graphOrientation { values["graphOrientationVertical"] = graphOrientation.indexOfSelectedItem == 0 }
        if let borderWidthSlider { values["borderWidth"] = max(0, borderWidthSlider.intValue) }
        if let graphRefreshValue {
            let value = graphRefreshValue.doubleValue
            guard value.isFinite, value > 0 else { throw Self.invalidInput }; values["graphRefresh"] = value
        }
        if let windowLevel, (1...3).contains(windowLevel.indexOfSelectedItem) { values["windowLevel"] = windowLevel.indexOfSelectedItem - 1 }
        for (field, key) in [(windowTitle, "windowTitle"), (ICAOCode, "icao"), (stockSymbols, "stockSymbols")] { if let field { values[key] = field.stringValue } }
        if let netGraphMode, netGraphMode.selectedRow >= 0 { values["netGraphMode"] = netGraphMode.selectedRow }
        if let diskGraphMode, diskGraphMode.selectedRow >= 0 { values["diskGraphMode"] = diskGraphMode.selectedRow }
        if let networkInterface { values["networkInterface"] = networkInterface.selectedItem?.representedObject as? String ?? "All" }
        if let field = netMinGraphScaleValue, let units = netMinGraphScaleUnits {
            guard let scale = Self.networkScale(field.stringValue, unit: units.indexOfSelectedItem) else { throw Self.invalidInput }; values["netMinGraphScale"] = scale
        }
        if !temperatureSensors.isEmpty {
            for (index, control) in [tempFG1Location, tempFG2Location, tempFG3Location].enumerated() {
                if let control { values["tempFG\(index + 1)Location"] = control.selectedItem?.representedObject as? String ?? "" }
            }
            values["tempLocationsAutoconfigured"] = true
        }
        for field in Self.aiCheckboxes { if let button = AIPrefView?.viewWithTag(field.0) as? NSButton { values[field.2] = button.state == .on } }
        for (tag, key) in [(1002, "aiTokensDailyBudget"), (1003, "aiTokensBudgetNotifyPercent")] {
            if let field = AIPrefView?.viewWithTag(tag) as? NSTextField {
                guard let value = Int(field.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)), value >= 0,
                      tag == 1002 || value <= 100 else { throw Self.invalidInput }; values[key] = value
            }
        }
        if let style = ColorPrefView?.viewWithTag(1010) as? NSPopUpButton, (0...3).contains(style.indexOfSelectedItem) { values["graphStyle"] = style.indexOfSelectedItem }
        values["graphFont"] = try NSKeyedArchiver.archivedData(withRootObject: settings.graphFont!, requiringSecureCoding: true)
        return values
    }
    @nonobjc @discardableResult func persistPreferences() -> Bool {
        guard let graph = xrgGraphWindow, let settings else { return false }
        do {
            let values = try preferencesSnapshot()
            // Validate and archive the complete snapshot before the first persistent write.
            for (key, value) in values { defaults.set(value, forKey: key) }
            if let ICAOCode, settings.ICAO != ICAOCode.stringValue { graph.setICAO(ICAOCode) }
            if let stockSymbols, settings.stockSymbols != stockSymbols.stringValue { graph.setStockSymbols(stockSymbols) }
            if let windowTitle { graph.setWindowTitle(windowTitle) }
            return true
        } catch { errorNotice("The preferences contain an invalid value. Check the network scale, refresh interval, budget and percentages.", window); return false }
    }
    @IBAction public func save(_ sender: Any?) { if persistPreferences() { window?.orderOut(nil) } }
    @IBAction public func revert(_ sender: Any?) { configure() }
    public func windowWillClose(_ notification: Notification) { _ = persistPreferences() }
    private static var invalidInput: NSError { NSError(domain: "XRGPreferencesErrorDomain", code: 1) }
    private func themeDictionary() throws -> [String: Any] {
        guard let settings else { throw Self.invalidInput }
        var values: [String: Any] = [:]
        for (well, slider, name) in [(backgroundColorWell, backgroundTransparency, "background"), (graphBGColorWell, graphBGTransparency, "graphBG"),
            (graphFG1ColorWell, graphFG1Transparency, "graphFG1"), (graphFG2ColorWell, graphFG2Transparency, "graphFG2"), (graphFG3ColorWell, graphFG3Transparency, "graphFG3"), (borderColorWell, borderTransparency, "border"), (textColorWell, textTransparency, "text")] {
            let alpha = slider?.doubleValue ?? (settings.value(forKey: name + "Transparency") as? NSNumber)?.doubleValue ?? 1
            guard alpha.isFinite, (0...1).contains(alpha), let color = well?.color ?? settings.value(forKey: name + "Color") as? NSColor else { throw Self.invalidInput }
            values[name + "Transparency"] = alpha
            values[name + "Color"] = try NSKeyedArchiver.archivedData(withRootObject: color.withAlphaComponent(alpha), requiringSecureCoding: true)
        }
        return values
    }
    @nonobjc func themeData() throws -> Data {
        try PropertyListSerialization.data(fromPropertyList: themeDictionary(), format: .xml, options: 0)
    }
    @nonobjc func loadTheme(from url: URL) -> Bool {
        guard let settings else { return false }
        let scope = url.startAccessingSecurityScopedResource(); defer { if scope { url.stopAccessingSecurityScopedResource() } }
        do {
            let plist = try PropertyListSerialization.propertyList(from: readFile(url), options: [], format: nil)
            try settings.applyThemeDictionary(plist, defaults: defaults); setUpColorPanel(); redrawGraphs(); return true
        } catch { errorNotice("The theme file specified is not a valid theme file.", window); return false }
    }
    @nonobjc func saveTheme(to url: URL) -> Bool {
        let scope = url.startAccessingSecurityScopedResource(); defer { if scope { url.stopAccessingSecurityScopedResource() } }
        do { try writeFile(themeData(), url); return true }
        catch { errorNotice("Could not save the theme to that location.", window); return false }
    }
    @IBAction public func loadTheme(_ sender: Any?) {
        guard let window else { return }
        chooseOpen(window) { [weak self] url in if let url { _ = self?.loadTheme(from: url) } }
    }
    @IBAction public func saveTheme(_ sender: Any?) {
        guard let window else { return }
        chooseSave(window) { [weak self] url in if let url { _ = self?.saveTheme(to: url) } }
    }
    private static func openThemePanel(_ window: NSWindow, completion: @escaping (URL?) -> Void) {
        let panel = NSOpenPanel(); panel.allowsMultipleSelection = false; panel.canChooseDirectories = false
        panel.allowedContentTypes = [.init(filenameExtension: "xtf") ?? .data]; panel.directoryURL = FileManager.default.homeDirectoryForCurrentUser
        panel.beginSheetModal(for: window) { response in completion(response == .OK ? panel.url : nil) }
    }
    private static func saveThemePanel(_ window: NSWindow, completion: @escaping (URL?) -> Void) {
        let panel = NSSavePanel(); panel.allowedContentTypes = [.init(filenameExtension: "xtf") ?? .data]
        panel.directoryURL = FileManager.default.homeDirectoryForCurrentUser; panel.nameFieldStringValue = "My Theme.xtf"
        panel.beginSheetModal(for: window) { response in completion(response == .OK ? panel.url : nil) }
    }
    private static func presentError(_ message: String, _ window: NSWindow?) {
        let alert = NSAlert(); alert.messageText = "Error"; alert.informativeText = message; alert.addButton(withTitle: "Okay")
        if let window { alert.beginSheetModal(for: window) } else { alert.runModal() }
    }

    @nonobjc static let panels = ["General", "Appearance", "CPU", "RAM", "Temperature", "Network", "Disk", "Weather", "Stocks", "AI"]
    @nonobjc var panelViews: [NSView?] { [GeneralPrefView, ColorPrefView, CPUPrefView, MemoryPrefView, TemperaturePrefView, NetworkPrefView, DiskPrefView, WeatherPrefView, StockPrefView, AIPrefView] }
    @objc(selectPanelNamed:)
    public func selectPanel(named name: String) {
        guard let index = Self.panels.firstIndex(of: name) else { return }
        selectPanel(index)
    }
    private func selectPanel(_ index: Int) {
        guard let window, panelViews.indices.contains(index), let view = panelViews[index] else { return }
        if currentView !== view {
            let top = window.frame.maxY
            let size = NSSize(width: max(500, view.frame.width), height: view.frame.height)
            var target = window.frameRect(forContentRect: NSRect(origin: .zero, size: size)); target.origin = NSPoint(x: window.frame.minX, y: top - target.height)
            window.contentView = view; window.setFrame(target, display: true, animate: animate); currentView = view
        }
        let title = ["General", "Appearance", "CPU", "Memory", "Temperature", "Network", "Disk", "Weather", "Stock", "AI Token"][index]
        window.title = title + " Preferences"; toolbar?.selectedItemIdentifier = .init(Self.panels[index])
    }
    @objc(General:) @IBAction public func general(_ sender: Any?) { selectPanel(0) }
    @objc(Colors:) @IBAction public func colors(_ sender: Any?) { selectPanel(1) }
    @objc(CPU:) @IBAction public func cpu(_ sender: Any?) { selectPanel(2) }
    @objc(RAM:) @IBAction public func ram(_ sender: Any?) { selectPanel(3) }
    @objc(Temperature:) @IBAction public func temperature(_ sender: Any?) { selectPanel(4) }
    @objc(Network:) @IBAction public func network(_ sender: Any?) { selectPanel(5) }
    @objc(Disk:) @IBAction public func disk(_ sender: Any?) { selectPanel(6) }
    @objc(Weather:) @IBAction public func weather(_ sender: Any?) { selectPanel(7) }
    @objc(Stocks:) @IBAction public func stocks(_ sender: Any?) { selectPanel(8) }
    @objc(AI:) @IBAction public func ai(_ sender: Any?) { selectPanel(9) }
    public func toolbarDefaultItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] { Self.panels.map { NSToolbarItem.Identifier($0) } }
    public func toolbarAllowedItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] { toolbarDefaultItemIdentifiers(toolbar) }
    public func toolbarSelectableItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] { toolbarDefaultItemIdentifiers(toolbar) }
    public func toolbar(_ toolbar: NSToolbar, itemForItemIdentifier identifier: NSToolbarItem.Identifier, willBeInsertedIntoToolbar flag: Bool) -> NSToolbarItem? {
        guard let index = Self.panels.firstIndex(of: identifier.rawValue) else { return nil }
        let labels = ["General", "Appearance", "CPU", "Memory", "Temperature", "Network", "Disk", "Weather", "Stocks", "AI"]
        let symbols = ["gearshape", "paintbrush", "cpu", "memorychip", "thermometer", "network", "externaldrive", "cloud.sun", "chart.line.uptrend.xyaxis", "brain"]
        let selectors = [#selector(general(_:)), #selector(colors(_:)), #selector(cpu(_:)), #selector(ram(_:)), #selector(temperature(_:)), #selector(network(_:)), #selector(disk(_:)), #selector(weather(_:)), #selector(stocks(_:)), #selector(ai(_:))]
        let item = NSToolbarItem(itemIdentifier: identifier); item.label = labels[index]; item.paletteLabel = labels[index]; item.toolTip = labels[index] + " Graph Options"
        item.image = NSImage(systemSymbolName: symbols[index], accessibilityDescription: labels[index]); item.target = self; item.action = selectors[index]
        toolbarItems[identifier] = item; return item
    }
}
