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
import Testing
@testable import XRGCore

private final class PreferencesNibOwner: NSObject {
    @objc var prefController: XRGPrefController?
}
@MainActor private final class PreferencesInputs {
    var sensors: [XRGSensorData] = []
    var interfaces = ["en0", "en4"]
    var errors: [String] = []
    var opened: [URL] = []
    var fonts: [NSFont?] = []
}
@MainActor private final class PreferencesFixture {
    let domain = "XRG.prefController.\(UUID().uuidString)"
    let defaults: UserDefaults
    let graph: XRGGraphWindow
    let inputs = PreferencesInputs()
    let center = NotificationCenter()
    let owner = PreferencesNibOwner()
    var objects: NSArray?
    let pref: XRGPrefController
    init() throws {
        _ = NSApplication.shared
        defaults = try #require(UserDefaults(suiteName: domain)); defaults.set(false, forKey: "checkForUpdates"); defaults.set(true, forKey: "isDockIconHidden")
        graph = XRGGraphWindow(contentRect: NSRect(x: 100, y: 200, width: 300, height: 400), defaults: defaults)
        let bundle = Bundle(for: PreferencesNibOwner.self)
        let nib = try #require(NSNib(nibNamed: "Preferences", bundle: bundle))
        #expect(nib.instantiate(withOwner: owner, topLevelObjects: &objects))
        let decoded = try #require(owner.prefController)
        let source = inputs
        pref = XRGPrefController(defaults: defaults, center: center, sensors: { source.sensors }, interfaces: { _ in source.interfaces },
                                 openURL: { source.opened.append($0); return true }, error: { message, _ in source.errors.append(message) }, fontPanel: { source.fonts.append($0) })
        let url = try #require(bundle.url(forResource: "PreferencesOutletKeys", withExtension: "plist"))
        let keys = try #require(PropertyListSerialization.propertyList(from: Data(contentsOf: url), options: [], format: nil) as? [String])
        for key in keys { pref.setValue(decoded.value(forKey: key), forKey: key) }
        pref.AIPrefView = decoded.AIPrefView
        for view in [pref.GeneralPrefView, pref.ColorPrefView, pref.CPUPrefView, pref.MemoryPrefView, pref.TemperaturePrefView,
                     pref.NetworkPrefView, pref.DiskPrefView, pref.WeatherPrefView, pref.StockPrefView, pref.AIPrefView, pref.window?.contentView].compactMap({ $0 }) {
            retarget(view, from: decoded)
        }
        pref.xrgGraphWindow = graph; pref.configure()
    }
    private func retarget(_ view: NSView, from old: XRGPrefController) {
        if let control = view as? NSControl, control.target === old { control.target = pref }
        for child in view.subviews { retarget(child, from: old) }
    }
    func cleanUp() {
        pref.window?.delegate = nil; pref.window?.orderOut(nil); pref.window?.close()
        graph.cleanupBeforeExiting(); graph.close(); defaults.removePersistentDomain(forName: domain)
    }
    func send(_ control: NSControl) throws {
        let selector = try #require(control.action)
        #expect(NSApp.sendAction(selector, to: control.target, from: control))
    }
    func sensor(_ key: String, _ label: String) -> XRGSensorData { let sensor = XRGSensorData(sensorKey: key); sensor.humanReadableName = label; return sensor }
}

@Suite(.serialized) @MainActor
struct XRGPrefControllerTests {
    @Test(arguments: ["Preferences", "LegacyPreferences"])
    func currentAndActualLegacyNibsDecodeAllOutletsWithoutAGraphOrSystemActions(name: String) throws {
        _ = NSApplication.shared
        let owner = PreferencesNibOwner(), bundle = Bundle(for: PreferencesNibOwner.self)
        let nib = try #require(NSNib(nibNamed: name, bundle: bundle)); var objects: NSArray?
        #expect(nib.instantiate(withOwner: owner, topLevelObjects: &objects))
        let pref = try #require(owner.prefController)
        defer { pref.window?.delegate = nil; pref.window?.close() }
        #expect(pref.window != nil && pref.xrgGraphWindow == nil && pref.temperatureSensors.isEmpty)
        #expect(pref.GeneralPrefView != nil && pref.ColorPrefView != nil && pref.CPUPrefView != nil && pref.MemoryPrefView != nil && pref.TemperaturePrefView != nil)
        #expect(pref.NetworkPrefView != nil && pref.DiskPrefView != nil && pref.WeatherPrefView != nil && pref.StockPrefView != nil && pref.AIPrefView != nil)
        #expect(pref.graphRefreshValue != nil && pref.stockSymbols != nil && pref.ICAOCode != nil && pref.backgroundColorWell != nil)
        #expect(pref.currentView === pref.GeneralPrefView && pref.window?.isVisible == false)
        let height = pref.ColorPrefView?.frame.height, count = pref.AIPrefView?.subviews.count
        pref.awakeFromNib(); pref.configure()
        #expect(pref.ColorPrefView?.frame.height == height && pref.AIPrefView?.subviews.count == count)
    }
    @Test func generatedControlsAreIdempotentAndRegistrationDoesNotOverrideGraphVisibility() throws {
        let f = try PreferencesFixture(); defer { f.cleanUp() }
        let height = f.pref.ColorPrefView!.frame.height, count = f.pref.AIPrefView!.subviews.count
        let ai = try #require(f.pref.showAITokensGraph)
        let npu = try #require(f.pref.showNPUGraph)
        f.pref.configure(); f.pref.setUpColorPanel(); f.pref.setUpAIPanel(); f.pref.awakeFromNib()
        #expect(f.pref.ColorPrefView?.frame.height == height && f.pref.AIPrefView?.subviews.count == count)
        #expect(f.pref.showAITokensGraph === ai && f.defaults.bool(forKey: "showAITokenGraph"))
        func countAIButtons(_ view: NSView) -> Int {
            (view as? NSButton)?.title == "AI Tokens" ? 1 : view.subviews.reduce(0) { $0 + countAIButtons($1) }
        }
        #expect(countAIButtons(f.pref.GeneralPrefView!) == 1)
        #expect(f.pref.showNPUGraph === npu && npu.target === f.graph && npu.action == #selector(XRGGraphWindow.setShowNPUGraph(_:)))
        let toggles = [f.pref.showCPUGraph,f.pref.showGPUGraph,f.pref.showNPUGraph,f.pref.showMemoryGraph,f.pref.showBatteryGraph,f.pref.showTemperatureGraph,
                       f.pref.showNetGraph,f.pref.showDiskGraph,f.pref.showWeatherGraph,f.pref.showStockGraph,ai].compactMap { $0 }
        for (i,a) in toggles.enumerated() { for b in toggles.dropFirst(i+1) { #expect(!a.frame.intersects(b.frame)) } }
        #expect(ai.target === f.graph && ai.action == #selector(XRGGraphWindow.setShowAITokenGraph(_:)))
        #expect(f.pref.ColorPrefView?.subviews.filter { $0.tag == 1010 }.count == 1)
        #expect(f.pref.ColorPrefView?.subviews.filter { $0.tag == 1011 }.count == 1)
    }
    @Test(arguments: Array(0...10))
    func toolbarRoutesAllPanelsAndPreservesTheWindowTop(index: Int) throws {
        let f = try PreferencesFixture(); defer { f.cleanUp() }
        let toolbar = try #require(f.pref.toolbar), identifiers = f.pref.toolbarDefaultItemIdentifiers(toolbar)
        #expect(identifiers.map(\.rawValue) == ["General", "Appearance", "Graphs", "CPU", "RAM", "Temperature", "Network", "Disk", "Weather", "Stocks", "AI"])
        let id = identifiers[index]
        let item = try #require(f.pref.toolbar(toolbar, itemForItemIdentifier: id, willBeInsertedIntoToolbar: true))
        let top = f.pref.window!.frame.maxY
        let action = try #require(item.action); #expect(item.target === f.pref && NSApp.sendAction(action, to: item.target, from: item))
        #expect(f.pref.currentView === f.pref.panelViews[index] && f.pref.toolbar?.selectedItemIdentifier == id)
        #expect(abs(f.pref.window!.frame.maxY - top) < 0.01 && f.pref.window!.frame.width >= 500)
        #expect(f.pref.toolbar(toolbar, itemForItemIdentifier: .init("unknown"), willBeInsertedIntoToolbar: true) == nil)
        #expect(f.pref.toolbarSelectableItemIdentifiers(toolbar) == identifiers && f.pref.toolbarAllowedItemIdentifiers(toolbar) == identifiers)
        f.pref.general(nil)
        f.pref.selectPanel(named: id.rawValue)
        #expect(f.pref.currentView === f.pref.panelViews[index] && f.pref.toolbar?.selectedItemIdentifier == id)
        #expect(abs(f.pref.window!.frame.maxY - top) < 0.01)

    }
    @Test func namedAIActionReusesThePanelAndKeepsPendingEditsAndExistingDefaults() throws {
        let f = try PreferencesFixture(); defer { f.cleanUp() }
        for key in ["showAITokenGraph", "aiTokensTrackingEnabled", "aiTokensAggregateByProvider"] { f.defaults.set(true, forKey: key) }
        f.defaults.set(400, forKey: "aiTokensDailyBudget"); f.pref.setUpAIPanel()
        let panel = try #require(f.pref.AIPrefView), field = try #require(panel.viewWithTag(1002) as? NSTextField)
        let count = panel.subviews.count; field.stringValue = "900"
        f.pref.general(nil)
        #expect(NSApp.sendAction(NSSelectorFromString("selectPanelNamed:"), to: f.pref, from: "AI"))
        #expect(f.pref.currentView === panel && f.pref.window?.title == "AI Token Preferences")
        #expect(f.pref.toolbar?.selectedItemIdentifier?.rawValue == "AI")
        f.pref.selectPanel(named: "AI"); f.pref.selectPanel(named: "invalid")
        #expect(f.pref.currentView === panel && panel.subviews.count == count && field.stringValue == "900")
        #expect(f.defaults.integer(forKey: "aiTokensDailyBudget") == 400)
        for key in ["showAITokenGraph", "aiTokensTrackingEnabled", "aiTokensAggregateByProvider"] { #expect(f.defaults.bool(forKey: key)) }
    }
    @Test(arguments: ["Reset Session", "Reset Daily"])
    func aiButtonsResetOnlyTheRequestedCountersThroughTheSwiftNotificationNames(title: String) throws {
        let f = try PreferencesFixture(); defer { f.cleanUp() }
        f.defaults.set(true, forKey: "aiTokensTrackingEnabled")
        let observer = XRGAITokensObserver(defaults: f.defaults, center: f.center, calendar: .current, now: Date.init)
        observer.recordEvent(promptTokens: 10, completionTokens: 20, model: "fixture", provider: "fixture")
        f.pref.selectPanel(named: "AI")
        let button = try #require(f.pref.AIPrefView?.subviews.compactMap { $0 as? NSButton }.first { $0.title == title })
        try f.send(button)
        #expect(observer.sessionTotalTokens == (title == "Reset Session" ? 0 : 30))
        #expect(observer.dailyTotalTokens == (title == "Reset Daily" ? 0 : 30))
    }
    @Test func controlTargetsReflectSettingsAndDispatchToTheSwiftWindow() throws {
        let f = try PreferencesFixture(); defer { f.cleanUp() }
        f.graph.appSettings?.windowTitle = "Fixture title"; f.graph.appSettings?.cpuShowUptime = false; f.pref.configure()
        #expect(f.pref.windowTitle?.stringValue == "Fixture title" && f.pref.cpuShowUptime?.state == .off)
        let uptime = try #require(f.pref.cpuShowUptime); uptime.state = .on; try f.send(uptime)
        #expect(f.graph.appSettings?.cpuShowUptime == true)
        let checkbox = try #require(f.pref.memoryShowCache); checkbox.state = .off; try f.send(checkbox)
        #expect(f.graph.appSettings?.memoryShowCache == false)
        let refresh = try #require(f.pref.graphRefreshValue); refresh.doubleValue = 0.4; try f.send(refresh)
        #expect(abs((f.graph.appSettings?.graphRefresh ?? 0) - 0.4) < 0.001 && f.pref.graphRefreshText?.stringValue.contains("0.4") == true)
        let style = try #require(f.pref.ColorPrefView?.viewWithTag(1010) as? NSPopUpButton); style.selectItem(at: 2); try f.send(style)
        #expect(f.graph.appSettings?.graphStyle == 2)
        for well in [f.pref.backgroundColorWell, f.pref.graphBGColorWell, f.pref.graphFG1ColorWell, f.pref.graphFG2ColorWell, f.pref.graphFG3ColorWell, f.pref.borderColorWell, f.pref.textColorWell].compactMap({ $0 }) {
            #expect(well.target === f.graph && f.pref.colorWellForTag(Int32(well.tag)) === well)
        }
    }
    @Test func windowLevelRoundTripsEverySwiftWindowIndex() throws {
        let f = try PreferencesFixture(); defer { f.cleanUp() }
        let popup = try #require(f.pref.windowLevel)
        #expect(popup.itemTitles == ["Window Level", "Normal", "Foreground", "Background"] && popup.item(at: 0)?.isEnabled == false)
        for level in 0...2 {
            popup.selectItem(at: level + 1); try f.send(popup)
            #expect(f.graph.appSettings?.windowLevel == level)
            #expect(f.pref.persistPreferences() && f.defaults.integer(forKey: "windowLevel") == level)
            f.pref.setUpGeneralPanel(); #expect(popup.indexOfSelectedItem == level + 1)
        }
    }
    @Test func sensorsUseStableKeysForDuplicateLabelsReorderingAndNone() throws {
        let f = try PreferencesFixture(); defer { f.cleanUp() }
        f.inputs.sensors = [f.sensor("temp.A", "Same name"), f.sensor("temp.B", "Same name")]
        f.graph.appSettings?.tempFG1Location = "temp.B"; f.pref.setUpTemperaturePanel()
        let popup = try #require(f.pref.tempFG1Location)
        #expect(popup.itemTitles == ["None", "Same name", "Same name"] && popup.indexOfSelectedItem == 2)
        popup.selectItem(at: 1); try f.send(popup); #expect(f.graph.appSettings?.tempFG1Location == "temp.A")
        f.inputs.sensors.reverse(); f.pref.setUpTemperaturePanel()
        #expect(popup.indexOfSelectedItem == 2 && popup.selectedItem?.representedObject as? String == "temp.A")
        #expect(f.pref.persistPreferences() && f.defaults.string(forKey: "tempFG1Location") == "temp.A" && f.defaults.bool(forKey: "tempLocationsAutoconfigured"))
        popup.selectItem(at: 0); try f.send(popup); #expect(f.graph.appSettings?.tempFG1Location == "")
        f.inputs.sensors = []; f.pref.setUpTemperaturePanel()
        #expect(popup.itemTitles == ["No Sensors Found"])
    }
    @Test func savingWithoutSensorsPreservesStoredSensorChoices() throws {
        let f = try PreferencesFixture(); defer { f.cleanUp() }
        f.defaults.set("saved.key", forKey: "tempFG1Location")
        #expect(f.pref.persistPreferences() && f.defaults.string(forKey: "tempFG1Location") == "saved.key")
    }
    @Test(arguments: [0, 1025, 1_048_576, 2_000_000_000_000, Int.max])
    func networkScaleDoesNotLosePrecisionWhenOpeningAndSaving(scale: Int) throws {
        let f = try PreferencesFixture(); defer { f.cleanUp() }
        f.graph.appSettings?.netMinGraphScale = scale; f.pref.setUpNetworkPanel()
        let parsed = XRGPrefController.networkScale(f.pref.netMinGraphScaleValue!.stringValue, unit: f.pref.netMinGraphScaleUnits!.indexOfSelectedItem)
        #expect(parsed == scale && f.pref.persistPreferences() && f.defaults.integer(forKey: "netMinGraphScale") == scale)
    }
    @Test(arguments: ["-1", "1.2", "1x", "", "999999999999999999999999", String(Int.max)])
    func invalidOrOverflowingScaleKeepsTheLiveValueAndPreventsPartialSave(text: String) throws {
        let f = try PreferencesFixture(); defer { f.cleanUp() }
        f.pref.netMinGraphScaleValue?.stringValue = text; f.pref.netMinGraphScaleUnits?.selectItem(at: 2)
        let original = f.defaults.persistentDomain(forName: f.domain) ?? [:], scale = f.graph.appSettings!.netMinGraphScale
        f.pref.setNetMinGraphValueAction(f.pref.netMinGraphScaleValue)
        #expect(f.graph.appSettings?.netMinGraphScale == scale && !f.inputs.errors.isEmpty)
        #expect(!f.pref.persistPreferences() && NSDictionary(dictionary: f.defaults.persistentDomain(forName: f.domain) ?? [:]).isEqual(to: original))
    }
    @Test(arguments: [0.125, 0.25, 1.0, 3600.0])
    func openingAndSavingKeepsValidRefreshIntervals(refresh: Double) throws {
        let f = try PreferencesFixture(); defer { f.cleanUp() }
        f.graph.appSettings?.graphRefresh = refresh; f.pref.setUpGeneralPanel()
        #expect(f.pref.graphRefreshValue?.doubleValue == refresh)
        #expect(f.pref.persistPreferences() && f.defaults.double(forKey: "graphRefresh") == refresh)
        f.pref.graphRefreshValue?.doubleValue = 0.31; try f.send(f.pref.graphRefreshValue!)
        #expect(f.pref.graphRefreshValue?.doubleValue == 0.4 && f.graph.appSettings?.graphRefresh == 0.4)
    }
    @Test func interfaceItemsKeepIdentityAndPersistTheirRepresentedValue() throws {
        let f = try PreferencesFixture(); defer { f.cleanUp() }
        let popup = try #require(f.pref.networkInterface)
        popup.selectItem(at: 2); try f.send(popup)
        #expect(f.graph.appSettings?.networkInterface == "en4")
        f.inputs.interfaces = ["en7"]
        #expect(f.pref.persistPreferences() && f.defaults.string(forKey: "networkInterface") == "en4")
        f.pref.setUpNetworkPanel(); #expect(popup.indexOfSelectedItem == 0)
    }
    @Test func saveCapturesAllControlFamiliesAndPendingTextEdits() throws {
        let f = try PreferencesFixture(); defer { f.cleanUp() }
        f.pref.windowTitle?.stringValue = "Saved title"; f.pref.ICAOCode?.stringValue = "KJFK"; f.pref.stockSymbols?.stringValue = "AAPL,MSFT"
        f.pref.showCPUGraph?.state = .on; f.pref.showGPUGraph?.state = .off; f.pref.fastCPUUsageCheckbox?.state = .off
        f.pref.showNPUGraph?.state = .on
        f.pref.generalAutoExpandGraph?.state = .off; f.pref.secondaryWeatherGraph?.selectItem(at: 5); f.pref.temperatureUnits?.selectItem(at: 1)
        f.pref.diskGraphMode?.selectCell(atRow: 2, column: 0); f.pref.borderWidthSlider?.intValue = 8
        f.pref.showAITokensGraph?.state = .on
        (f.pref.AIPrefView?.viewWithTag(1002) as? NSTextField)?.stringValue = "123456789012"
        let values = try f.pref.preferencesSnapshot()
        #expect(values["showCPUGraph"] as? Bool == true && values["showGPUGraph"] as? Bool == false && values["showAITokenGraph"] as? Bool == true)
        #expect(values["showNPUGraph"] as? Bool == true)
        #expect(values["showCPUBars"] as? Bool == false && values["autoExpandGraph"] as? Bool == false && values["secondaryWeatherGraph"] as? Int == 5)
        #expect(values["diskGraphMode"] as? Int == 2 && values["borderWidth"] as? Int32 == 8 && values["aiTokensDailyBudget"] as? Int == 123456789012)
        #expect(f.pref.persistPreferences() && f.graph.appSettings?.windowTitle == "Saved title" && f.graph.appSettings?.ICAO == "KJFK" && f.graph.appSettings?.stockSymbols == "AAPL,MSFT")
        #expect(f.defaults.string(forKey: "icao") == "KJFK" && f.defaults.object(forKey: "ICAO") == nil)
        #expect(f.defaults.data(forKey: "graphFont") != nil && f.defaults.integer(forKey: "aiTokensDailyBudget") == 123456789012)
    }
    @Test(arguments: ["budget", "percent", "refresh"])
    func otherInvalidFieldsAreRejectedBeforeTheFirstWrite(field: String) throws {
        let f = try PreferencesFixture(); defer { f.cleanUp() }
        switch field {
        case "budget": (f.pref.AIPrefView?.viewWithTag(1002) as? NSTextField)?.stringValue = "-1"
        case "percent": (f.pref.AIPrefView?.viewWithTag(1003) as? NSTextField)?.stringValue = "101"
        default: f.pref.graphRefreshValue?.minValue = 0; f.pref.graphRefreshValue?.doubleValue = 0
        }
        let original = f.defaults.persistentDomain(forName: f.domain) ?? [:]
        #expect(!f.pref.persistPreferences() && NSDictionary(dictionary: f.defaults.persistentDomain(forName: f.domain) ?? [:]).isEqual(to: original))
    }
    @Test func repeatedAISetupReflectsCurrentDefaultsAndResetsUseThePrivateNotificationCenter() throws {
        let f = try PreferencesFixture(); defer { f.cleanUp() }
        f.defaults.set(true, forKey: "aiTokensTrackingEnabled"); f.pref.setUpAIPanel()
        #expect((f.pref.AIPrefView?.viewWithTag(1000) as? NSButton)?.state == .on)
        let capture = PreferencesNotifications()
        f.center.addObserver(capture, selector: #selector(PreferencesNotifications.event(_:)), name: nil, object: f.pref)
        defer { f.center.removeObserver(capture) }
        f.pref.resetSessionCounters(nil); f.pref.resetDailyCounters(nil)
        #expect(capture.names == ["XRGAITokensDidResetSession", "XRGAITokensDidResetDaily"])
        f.pref.setFont(nil); f.pref.openWeatherStationList(nil)
        #expect(f.inputs.fonts.count == 1 && f.inputs.opened.map(\.absoluteString) == ["https://download.gauchosoft.com/xrg/stations.txt"])
    }
    @Test func themeExportImportAndWriteFailuresUsePrivateFilesAndInjectedIO() throws {
        let f = try PreferencesFixture(); defer { f.cleanUp() }
        f.pref.graphFG1ColorWell?.color = .red; f.pref.graphFG1Transparency?.doubleValue = 0.25
        f.pref.netMinGraphScaleValue?.stringValue = "unrelated invalid field"
        let data = try f.pref.themeData(), dictionary = try #require(PropertyListSerialization.propertyList(from: data, options: [], format: nil) as? [String: Any])
        #expect(dictionary.count == 14 && dictionary["graphFont"] == nil)
        let theme = try XRGTheme(dictionary: dictionary)
        #expect(theme.fields.first { $0.colorKey == "graphFG1Color" }?.alpha == 0.25)
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("XRG-pref-\(UUID().uuidString).xtf")
        defer { try? FileManager.default.removeItem(at: url) }
        #expect(f.pref.saveTheme(to: url))
        f.graph.appSettings?.graphFG1Color = .blue
        #expect(f.pref.loadTheme(from: url) && f.graph.appSettings?.graphFG1Color.usingColorSpace(.deviceRGB)?.redComponent == 1)
        #expect(f.graph.appSettings?.graphFG1Color.alphaComponent == 0.25 && f.defaults.data(forKey: "graphFG1Color") != nil)
        #expect(!f.pref.saveTheme(to: URL(fileURLWithPath: "/does-not-exist/fixture.xtf")) && !f.inputs.errors.isEmpty)
    }

    @Test(arguments: XRGTheme.Builtin.allCases)
    func builtinThemesApplyThroughControlsAndRoundTripExistingFiles(preset: XRGTheme.Builtin) throws {
        let f = try PreferencesFixture(); defer { f.cleanUp() }
        let picker = try #require(f.pref.ColorPrefView?.viewWithTag(1011) as? NSPopUpButton)
        #expect(picker.itemTitles == ["Built-in Themes", "Classic", "Midnight", "Ocean", "Dusk", "Paper", "Phosphor"])
        #expect(picker.isEnabled && picker.item(at: 0)?.isEnabled == true)
        f.graph.appSettings?.graphStyle = 2
        let font = try #require(f.graph.appSettings?.graphFont)
        f.defaults.set(1234, forKey: "aiTokensDailyBudget")
        f.pref.netMinGraphScaleValue?.stringValue = "unrelated invalid field"
        picker.select(try #require(picker.itemArray.first { $0.representedObject as? String == preset.rawValue }))
        try f.send(picker)
        let expected = try XRGTheme(dictionary: preset.dictionary())
        func checkApplied() throws {
            for field in expected.fields {
                let actual = try #require((f.graph.appSettings?.value(forKey: field.colorKey) as? NSColor)?.usingColorSpace(.sRGB))
                let target = try #require(field.color.usingColorSpace(.sRGB))
                let rgba = [actual.redComponent, actual.greenComponent, actual.blueComponent, actual.alphaComponent]
                let targetRGBA = [target.redComponent, target.greenComponent, target.blueComponent, target.alphaComponent]
                #expect(zip(rgba, targetRGBA).allSatisfy { abs($0 - $1) < 0.00001 })
                #expect(abs(f.defaults.double(forKey: field.alphaKey) - field.alpha) < 0.00001)
                #expect(f.defaults.data(forKey: field.colorKey) != nil)
            }
        }
        try checkApplied()
        #expect(picker.indexOfSelectedItem == 0 && f.graph.appSettings?.graphStyle == 2)
        #expect(f.graph.appSettings?.graphFont == font && f.defaults.integer(forKey: "aiTokensDailyBudget") == 1234)
        let exported = try f.pref.themeData()
        let dictionary = try #require(PropertyListSerialization.propertyList(from: exported, options: [], format: nil) as? [String: Any])
        #expect(dictionary.count == 14 && dictionary["graphStyle"] == nil && dictionary["builtinTheme"] == nil)
        let roundTrip = try XRGTheme(dictionary: dictionary)
        #expect(roundTrip.fields.count == 7)
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("XRG-builtin-\(UUID().uuidString).xtf")
        defer { try? FileManager.default.removeItem(at: url) }
        #expect(f.pref.saveTheme(to: url))
        f.graph.appSettings?.graphFG1Color = .clear
        #expect(f.pref.loadTheme(from: url))
        try checkApplied()
        #expect(f.inputs.errors.isEmpty)
    }

    @Test func portableThemeImportEditAndExportPreserveUntouchedPrecisionAndOtherSettings() throws {
        let f = try PreferencesFixture(); defer { f.cleanUp() }
        let source = try #require(Bundle(for: PreferencesNibOwner.self).url(forResource: "portable-theme", withExtension: "json"))
        let expected = try XRGThemeDocument(data: Data(contentsOf: source))
        f.defaults.set(777, forKey: "aiTokensDailyBudget"); f.graph.appSettings?.graphStyle = 2
        f.pref.netMinGraphScaleValue?.stringValue = "unrelated invalid field"
        #expect(f.pref.loadTheme(from: source))
        #expect(try XRGThemeDocument(data: f.pref.portableThemeData()) == expected)
        // The cached original also survives a normal preference restore.
        let restored = XRGSettings(defaults: f.defaults)
        _ = XRGWindowPreferences.apply(f.defaults.dictionaryRepresentation() as NSDictionary, to: restored)
        let cached = try XRGThemeDocument(data: #require(f.defaults.data(forKey: XRGTheme.documentKey)))
        #expect(cached == expected)
        #expect(restored.backgroundColor == f.graph.appSettings?.backgroundColor)
        f.pref.graphFG1Transparency?.doubleValue = 0.42
        let edited = try XRGThemeDocument(data: f.pref.portableThemeData())
        #expect(edited.name == expected.name && edited.colors[2][3] == 0.42)
        for i in [0, 1, 3, 4, 5, 6] { #expect(edited.colors[i] == expected.colors[i]) }
        let output = FileManager.default.temporaryDirectory.appendingPathComponent("XRG-portable-\(UUID().uuidString).json")
        defer { try? FileManager.default.removeItem(at: output) }
        #expect(f.pref.saveTheme(to: output))
        #expect(try XRGThemeDocument(data: Data(contentsOf: output)) == edited)
        #expect(f.defaults.integer(forKey: "aiTokensDailyBudget") == 777 && f.graph.appSettings?.graphStyle == 2)
        #expect(f.inputs.errors.isEmpty)
    }

    @Test(arguments: XRGTheme.Builtin.allCases.filter { $0 != .classic })
    func builtinTextRemainsReadableOverBackgroundAndGraphFills(preset: XRGTheme.Builtin) throws {
        let theme = try XRGTheme(dictionary: preset.dictionary())
        func luminance(_ color: NSColor) throws -> Double {
            let color = try #require(color.usingColorSpace(.sRGB))
            func linear(_ c: CGFloat) -> Double { c <= 0.04045 ? Double(c) / 12.92 : pow((Double(c) + 0.055) / 1.055, 2.4) }
            return 0.2126 * linear(color.redComponent) + 0.7152 * linear(color.greenComponent) + 0.0722 * linear(color.blueComponent)
        }
        let text = try luminance(#require(theme.fields.first { $0.colorKey == "textColor" }).color)
        for field in theme.fields where !["textColor", "borderColor"].contains(field.colorKey) {
            let background = try luminance(field.color)
            #expect((max(text, background) + 0.05) / (min(text, background) + 0.05) >= 4.5)
            #expect(field.alpha == 1)
        }
    }
    @Test(arguments: ["empty", "badPlist", "wrongRoot", "lastColor", "readError"])
    func invalidThemesDoNotPartiallyChangeSettingsOrDefaults(failure: String) throws {
        let f = try PreferencesFixture(); defer { f.cleanUp() }
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("XRG-invalid-\(UUID().uuidString).xtf")
        defer { try? FileManager.default.removeItem(at: url) }
        var bytes = Data()
        switch failure {
        case "badPlist": bytes = Data("bad".utf8)
        case "wrongRoot": bytes = try PropertyListSerialization.data(fromPropertyList: ["bad"], format: .xml, options: 0)
        case "lastColor":
            var dictionary = try #require(PropertyListSerialization.propertyList(from: f.pref.themeData(), options: [], format: nil) as? [String: Any])
            dictionary["textColor"] = Data([0xff]); bytes = try PropertyListSerialization.data(fromPropertyList: dictionary, format: .xml, options: 0)
        default: break
        }
        if failure != "readError" { try bytes.write(to: url) }
        let original = f.defaults.persistentDomain(forName: f.domain) ?? [:], color = f.graph.appSettings!.backgroundColor
        #expect(!f.pref.loadTheme(from: url) && f.graph.appSettings?.backgroundColor == color)
        #expect(NSDictionary(dictionary: f.defaults.persistentDomain(forName: f.domain) ?? [:]).isEqual(to: original))
    }
    @Test func sheetCancellationDoesNotReadOrWriteAndCompletionDoesNotRetainTheController() throws {
        _ = NSApplication.shared
        let domain = "XRG.preferencesSheets.\(UUID().uuidString)", defaults = try #require(UserDefaults(suiteName: domain))
        defer { defaults.removePersistentDomain(forName: domain) }
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 500, height: 300), styleMask: .titled, backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false; defer { window.close() }
        var open: ((URL?) -> Void)?, save: ((URL?) -> Void)?, reads = 0, writes = 0
        var pref: XRGPrefController? = XRGPrefController(defaults: defaults, chooseOpen: { _, done in open = done }, chooseSave: { _, done in save = done }, readFile: { _ in reads += 1; return Data() }, writeFile: { _, _ in writes += 1 })
        pref?.window = window; pref?.loadTheme(nil); pref?.saveTheme(nil)
        open?(nil); save?(nil); #expect(reads == 0 && writes == 0)
        weak let weakPref = pref; pref = nil; #expect(weakPref == nil)
        open?(URL(fileURLWithPath: "/unused.xtf")); save?(URL(fileURLWithPath: "/unused.xtf"))
        #expect(reads == 0 && writes == 0)
    }
    @Test func saveOnCloseAndRevertRefreshUseTheSameControllerState() throws {
        let f = try PreferencesFixture(); defer { f.cleanUp() }
        (f.pref.AIPrefView?.viewWithTag(1000) as? NSButton)?.state = .on; f.pref.revert(nil)
        #expect((f.pref.AIPrefView?.viewWithTag(1000) as? NSButton)?.state == .off)
        f.pref.windowTitle?.stringValue = "Closed title"
        f.pref.windowWillClose(Notification(name: NSWindow.willCloseNotification))
        #expect(f.defaults.string(forKey: "windowTitle") == "Closed title")
    }
}
@MainActor private final class PreferencesNotifications: NSObject {
    var names: [String] = []
    @objc func event(_ notification: Notification) { names.append(notification.name.rawValue) }
}
