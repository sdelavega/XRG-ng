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

@MainActor private final class WindowControllerSpy: NSObject, XRGGraphWindowController {
    var panels: [String] = []
    var sensors = 0
    var palettes = 0
    func showPrefs(withPanel panel: String) { panels.append(panel) }
    func openSensorWindow(_ sender: Any?) { sensors += 1 }
    func refreshGraphPalette() { palettes += 1 }
}
@MainActor private final class WindowGraphSpy: NSView, XRGModuleView {
    var updates = [0, 0, 0, 0]
    func setGraphSize(_ size: NSSize) { setFrameSize(size) }
    func updateMinSize() {}
    func min30Update(_ timer: Timer?) { updates[0] += 1 }
    func min5Update(_ timer: Timer?) { updates[1] += 1 }
    func graphUpdate(_ timer: Timer?) { updates[2] += 1 }
    func fastUpdate(_ timer: Timer?) { updates[3] += 1 }
}
@MainActor private final class GraphWindowFixture {
    let domain = "XRG.graphWindow.\(UUID().uuidString)"
    let defaults: UserDefaults
    let center = NotificationCenter()
    let window: XRGGraphWindow
    let controller = WindowControllerSpy()
    let graph = WindowGraphSpy(frame: .zero)
    let module: XRGModule
    let background: XRGBackgroundView
    init() throws {
        _ = NSApplication.shared
        defaults = try #require(UserDefaults(suiteName: domain))
        defaults.set(false, forKey: "checkForUpdates"); defaults.set(true, forKey: "isDockIconHidden")
        window = XRGGraphWindow(contentRect: NSRect(x: 100, y: 200, width: 300, height: 400), defaults: defaults, center: center)
        window.controller = controller
        module = XRGModule(name: "CPU", reference: graph, defaults: defaults)
        module.minWidth = 80; module.minHeight = 40; module.displayOrder = 0
        module.doesMin30Update = true; module.doesMin5Update = true; module.doesFastUpdate = true
        window.contentView?.addSubview(graph); window.moduleManager?.addModule(module)
        background = XRGBackgroundView(frame: NSRect(origin: .zero, size: window.frame.size), defaults: defaults)
        window.contentView?.addSubview(background, positioned: .below, relativeTo: graph); background.awakeFromNib()
    }
    func cleanUp() { window.cleanupBeforeExiting(); background.removeFromSuperview(); window.close(); defaults.removePersistentDomain(forName: domain) }
    func popup(_ index: Int, count: Int = 6) -> NSPopUpButton {
        let popup = NSPopUpButton(frame: .zero)
        popup.addItems(withTitles: (0..<count).map { "Item \($0)" }); popup.selectItem(at: index); return popup
    }
    func checkbox(_ state: Bool = true, tag: Int = 0) -> NSButton {
        let button = NSButton(checkboxWithTitle: "Fixture", target: nil, action: nil); button.state = state ? .on : .off; button.tag = tag; return button
    }
    func event(_ type: NSEvent.EventType, _ point: NSPoint) throws -> NSEvent {
        try #require(NSEvent.mouseEvent(with: type, location: point, modifierFlags: [], timestamp: 0, windowNumber: window.windowNumber, context: nil, eventNumber: 0, clickCount: 1, pressure: 1))
    }
}
private final class GraphWindowNibOwner: NSObject {}

@Suite(.serialized) @MainActor
struct XRGGraphWindowTests {
    @Test func initializationRestoresPreferencesBeforeLayoutAndKeepsNativeWindowBehavior() throws {
        let f = try GraphWindowFixture(); defer { f.cleanUp() }
        #expect(f.window.borderWidth == 4 && f.window.appSettings?.ICAO == "KMOP")
        #expect(f.window.canBecomeKey && f.window.isMovableByWindowBackground && !f.window.isMovable)
        #expect(!f.window.isOpaque && !f.window.hasShadow && f.window.alphaValue == 0.99)
        #expect(f.window.backgroundView === f.background && f.window.moduleManager?.getModule(byName: "CPU") === f.module)
        let preferences: NSDictionary = ["graphOrientationVertical": "NO", "borderWidth": 6, "graphRefresh": 0.25, "dropShadow": true, "windowLevel": 1]
        f.window.setupSettingsFromDictionary(preferences)
        #expect(f.window.moduleManager?.graphOrientationVertical == false && f.window.borderWidth == 6 && f.window.hasShadow)
        #expect(f.window.appSettings?.graphRefresh == 0.25 && f.window.level == .floating)
        #expect(f.graph.frame.height == 388 && f.graph.frame.width < 300 && f.graph.frame.minX > 6)
    }
    @Test func timersAreIdempotentForwardExactlyOnceAndReplaceOnlyTheGraphTimer() throws {
        let f = try GraphWindowFixture(); defer { f.cleanUp() }
        f.window.initTimers()
        let timers = try [f.window.min30Timer, f.window.min5Timer, f.window.graphTimer, f.window.fastTimer, f.window.aiTimer].map { try #require($0) }
        #expect(timers.map(\.timeInterval) == [1800, 300, 1, 0.125, 5])
        f.window.initTimers(); #expect(f.window.graphTimer === timers[2] && f.window.fastTimer === timers[3])
        for timer in timers { timer.fire() }
        #expect(f.graph.updates == [1, 1, 1, 1])
        let field = NSTextField(); field.doubleValue = 0.31
        f.window.setGraphRefreshActionPart2(field)
        #expect(!timers[2].isValid && f.window.graphTimer?.timeInterval == 0.4 && f.window.appSettings?.graphRefresh == 0.4)
        #expect(f.window.min30Timer === timers[0] && f.window.min5Timer === timers[1] && f.window.fastTimer === timers[3] && f.window.aiTimer === timers[4])
        let replacement = f.window.graphTimer
        for value in [0, -1, Double.nan, Double.infinity] { field.doubleValue = value; f.window.setGraphRefreshActionPart2(field) }
        #expect(f.window.graphTimer === replacement)
        field.doubleValue = 0.01; f.window.setGraphRefreshActionPart2(field)
        #expect(f.window.graphTimer?.timeInterval == 0.2)
        f.window.appSettings?.graphRefresh = .nan; f.window.graphTimer?.invalidate(); f.window.initTimers()
        #expect(f.window.graphTimer?.timeInterval == 1)
        f.window.cleanupBeforeExiting(); #expect(timers.allSatisfy { !$0.isValid })
        #expect(f.window.graphTimer == nil && f.window.fastTimer == nil && f.window.aiTimer == nil)
    }
    @Test func independentAITimerCollectsThroughSlowGraphRefreshWithoutDoubleSampling() throws {
        let f=try GraphWindowFixture();defer {f.cleanUp()}
        f.defaults.set(false,forKey:"showAITokenGraph");f.defaults.set(true,forKey:"aiTokensTrackingEnabled")
        let source=AITokenPanelSource()
        let observer=XRGAITokensObserver(defaults:f.defaults,center:NotificationCenter(),calendar:.current,now:Date.init)
        let view=XRGAITokenView(frame:.zero,source:source,observer:observer,settings:f.window.appSettings!,defaults:f.defaults,
            databaseURL:URL(fileURLWithPath:"/nonexistent-xrg-cadence-fixture"),now:{source.now})
        f.window.contentView?.addSubview(view);view.awakeFromNib()
        f.window.appSettings?.graphRefresh=60;f.window.graphTimer?.invalidate();f.window.initTimers()
        let timer=try #require(f.window.aiTimer)
        #expect(timer.timeInterval == 5 && f.window.graphTimer?.timeInterval == 60)
        timer.fire();source.now=5;timer.fire()
        #expect(source.updates == 2 && view.module?.isDisplayed == false)
        f.window.graphTimer?.fire()
        #expect(source.updates == 2)
        view.removeFromSuperview()
        #expect(source.pauses == 1)
    }

    @Test(arguments: [true, false], [0, 1])
    func orientationChangesPreserveTheTopAnchorAndCollapsedState(minimized: Bool, direction: Int) throws {
        let f = try GraphWindowFixture(); defer { f.cleanUp() }
        f.window.appSettings?.minimizeUpDown = direction
        let original = f.window.frame
        if minimized { f.background.minimizeWindow() }
        f.window.setGraphOrientation(f.popup(1))
        #expect(f.window.minimized == minimized && f.window.moduleManager?.graphOrientationVertical == false)
        #expect(!f.defaults.bool(forKey: "graphOrientationVertical"))
        if minimized { f.background.expandWindow() }
        #expect(f.window.frame.size == NSSize(width: original.height, height: original.width))
        #expect(f.window.frame.maxY == original.maxY)
        f.window.setGraphOrientation(f.popup(0))
        #expect(f.window.frame == original && f.graph.frame.minX == CGFloat(f.window.borderWidth))
    }
    @Test func squareOrientationAndModuleVisibilityAlwaysRelayout() throws {
        let f = try GraphWindowFixture(); defer { f.cleanUp() }
        f.window.setFrame(NSRect(x: 100, y: 200, width: 300, height: 300), display: false)
        let vertical = f.graph.frame
        f.window.setGraphOrientation(f.popup(1))
        #expect(f.graph.frame != vertical && f.graph.frame.minY == 4 && f.graph.frame.minX > 4)
        f.background.minimizeWindow(); f.window.setShowCPUGraph(f.checkbox(false))
        #expect(!f.window.minimized && !f.module.isDisplayed && f.graph.frame.size == .zero)
        f.window.setShowCPUGraph(f.checkbox(true))
        #expect(f.module.isDisplayed && f.graph.frame.width > 0 && f.graph.updates == [1, 1, 1, 1])
        let field = NSTextField(); field.intValue = 10; f.window.setBorderWidthAction(field)
        #expect(f.window.borderWidth == 10 && f.graph.frame.minY == 10)
    }
    @Test func backgroundRefreshAndAllPreferencesRoutesUseTheDelegateProtocol() throws {
        let f = try GraphWindowFixture(); defer { f.cleanUp() }
        f.window.showCPUPreferences(); f.window.showMemoryPreferences(); f.window.showNetworkPreferences()
        f.window.showTemperaturePreferences(); f.window.showStockPreferences(); f.window.showDiskPreferences()
        f.window.showWeatherPreferences(); f.window.showGeneralPreferences(); f.window.showTemperatureSensors(); f.window.backgroundThemeDidApply()
        #expect(f.controller.panels == ["CPU", "RAM", "Network", "Temperature", "Stocks", "Disk", "Weather", "General"])
        #expect(f.controller.sensors == 1 && f.controller.palettes == 1)
        f.window.controller = nil; f.window.showGeneralPreferences(); f.window.backgroundThemeDidApply()
        #expect(f.controller.panels.count == 8)
    }
    @Test(arguments: ["setAntiAliasing:", "setStickyWindow:", "setCheckForUpdates:", "setDropShadow:", "setAutoExpandGraph:", "setForegroundWhenExpanding:", "setShowSummary:", "setShowTotalBandwidthSinceBoot:", "setShowTotalBandwidthSinceLoad:", "setSeparateCPUColor:", "setShowCPUTemperature:", "setStockShowChange:", "setShowDJIA:"])
    func checkboxSelectorsDispatchThroughAppKit(selector: String) throws {
        let f = try GraphWindowFixture(); defer { f.cleanUp() }
        let keys = ["setAntiAliasing:": "antiAliasing", "setStickyWindow:": "stickyWindow", "setCheckForUpdates:": "checkForUpdates", "setDropShadow:": "dropShadow", "setAutoExpandGraph:": "autoExpandGraph", "setForegroundWhenExpanding:": "foregroundWhenExpanding", "setShowSummary:": "showSummary", "setShowTotalBandwidthSinceBoot:": "showTotalBandwidthSinceBoot", "setShowTotalBandwidthSinceLoad:": "showTotalBandwidthSinceLoad", "setSeparateCPUColor:": "separateCPUColor", "setShowCPUTemperature:": "showCPUTemperature", "setStockShowChange:": "stockShowChange", "setShowDJIA:": "showDJIA"]
        let key = try #require(keys[selector])
        #expect(NSApp.sendAction(NSSelectorFromString(selector), to: f.window, from: f.checkbox(false)))
        #expect((f.window.appSettings?.value(forKey: key) as? NSNumber)?.boolValue == false)
        #expect(NSApp.sendAction(NSSelectorFromString(selector), to: f.window, from: f.checkbox(true)))
        #expect((f.window.appSettings?.value(forKey: key) as? NSNumber)?.boolValue == true)
        if selector == "setDropShadow:" { #expect(f.window.hasShadow) }
    }
    @Test(arguments: [21, 22, 23, 24, 25, 26, 27])
    func allColorAndTransparencyTagsDispatchWithoutOverwritingOtherColors(tag: Int) throws {
        let f = try GraphWindowFixture(); defer { f.cleanUp() }
        let well = NSColorWell(); well.tag = tag; well.color = .red
        f.window.setObjectsToColor(well)
        #expect(f.window.colorForTag(tag)?.usingColorSpace(.deviceRGB)?.redComponent == 1)
        let slider = NSSlider(); slider.tag = tag; slider.doubleValue = 0.25; f.window.setObjectsToTransparency(slider)
        #expect(f.window.transparencyForTag(tag) == 0.25 && f.window.colorForTag(tag)?.alphaComponent == 0.25)
        slider.doubleValue = 2; f.window.setObjectsToTransparency(slider); #expect(f.window.transparencyForTag(tag) == 1)
        #expect(f.window.colorForTag(99) == nil && f.window.transparencyForTag(99) == 1)
    }
    @Test func popupsMatricesTextAndSensorSelectionsRetainTheirSelectors() throws {
        let f = try GraphWindowFixture(); defer { f.cleanUp() }
        let popup = f.popup(1)
        for name in ["setMinimizeUpDown:", "setCPUTemperatureUnits:", "setTempUnits:", "setSecondaryWeatherGraph:", "setTemperatureUnits:", "setDistanceUnits:", "setPressureUnits:", "setStockGraphTimeFrame:", "setGraphStyle:"] {
            #expect(NSApp.sendAction(NSSelectorFromString(name), to: f.window, from: popup))
        }
        #expect(f.window.appSettings?.tempUnits == .c && f.window.appSettings?.secondaryWeatherGraph == 1 && f.window.appSettings?.graphStyle == 1)
        #expect(f.window.appSettings?.minimizeUpDown == 1 && f.window.appSettings?.cpuTemperatureUnits == 1 && f.window.appSettings?.distanceUnits == 1 && f.window.appSettings?.pressureUnits == 1 && f.window.appSettings?.stockGraphTimeFrame == 1)
        let matrix = NSMatrix(frame: .zero, mode: .radioModeMatrix, prototype: NSButtonCell(), numberOfRows: 3, numberOfColumns: 1)
        matrix.selectCell(atRow: 2, column: 0); f.window.setNetGraphMode(matrix); f.window.setDiskGraphMode(matrix)
        #expect(f.window.appSettings?.netGraphMode == 2 && f.window.appSettings?.diskGraphMode == 2)
        let text = NSTextField(); text.stringValue = "Window title"; f.window.setWindowTitle(text)
        #expect(f.window.appSettings?.windowTitle == "Window title")
        text.stringValue = "KJFK"; f.window.setICAO(text); #expect(f.window.appSettings?.ICAO == "KJFK")
        text.stringValue = "AAPL,MSFT"; f.window.setStockSymbols(text); #expect(f.window.appSettings?.stockSymbols == "AAPL,MSFT")
        let menu = NSMenuItem(); menu.representedObject = "Sensor.key"
        f.window.setTempFG1Location(menu); f.window.setTempFG2Location(menu); f.window.setTempFG3Location(menu)
        #expect(f.window.appSettings?.tempFG1Location == "Sensor.key" && f.window.appSettings?.tempFG2Location == "Sensor.key" && f.window.appSettings?.tempFG3Location == "Sensor.key")
        f.window.setWindowLevel(f.popup(2)); #expect(f.window.level == .floating && f.window.appSettings?.windowLevel == 1)
        f.window.setWindowLevel(f.popup(0)); #expect(f.window.level == .floating)
        f.window.setNetworkInterface(f.popup(0)); #expect(f.window.appSettings?.networkInterface == "All")
        for tag in 42...48 { f.window.setMemoryCheckbox(f.checkbox(false, tag: tag)) }
        #expect(f.window.appSettings?.memoryShowWired == false && f.window.appSettings?.memoryShowActive == false && f.window.appSettings?.memoryShowInactive == false && f.window.appSettings?.memoryShowFree == false && f.window.appSettings?.memoryShowCache == false && f.window.appSettings?.memoryShowPage == false && f.window.appSettings?.showMemoryPagingGraph == false)
        f.window.setFastCPUUsageCheckbox(f.checkbox(false)); #expect(f.window.appSettings?.fastCPUUsage == false)
        f.window.setShowLoadAverage(f.checkbox(false)); f.window.setCPUShowAverageUsage(f.checkbox(false)); f.window.setCPUShowUptime(f.checkbox(false))
        #expect(f.window.appSettings?.showLoadAverage == false && f.window.appSettings?.cpuShowAverageUsage == false && f.window.appSettings?.cpuShowUptime == false)
    }
    @Test func cleanupRestoresExpandedGeometryAndKeepsTheSavedMinimizedFlag() throws {
        let f = try GraphWindowFixture(); defer { f.cleanUp() }
        let original = f.window.frame; f.window.initTimers(); let timer = try #require(f.window.graphTimer)
        f.background.minimizeWindow(); f.window.cleanupBeforeExiting()
        #expect(f.window.frame == original && !f.window.minimized && f.defaults.bool(forKey: "windowIsMinimized"))
        #expect(!timer.isValid && f.window.graphTimer == nil)
    }
    @Test func runtimeWakeSubscriptionIsIdempotentAndWindowScoped() async throws {
        let f = try GraphWindowFixture(); defer { f.cleanUp() }
        let center = NotificationCenter()
        let window = XRGGraphWindow(contentRect: f.window.frame, defaults: f.defaults, center: center, runtimeEnabled: true)
        defer { window.cleanupBeforeExiting(); window.close() }
        window.awakeFromNib(); center.post(name: NSWorkspace.didWakeNotification, object: nil)
        #expect(!window.systemJustWokeUp())
        window.controller = f.controller; window.startRuntimeIfNeeded(); window.startRuntimeIfNeeded()
        center.post(name: NSWorkspace.didWakeNotification, object: nil)
        #expect(window.systemJustWokeUp() && !f.window.systemJustWokeUp())
        window.setSystemJustWokeUp(false)
        await Task.detached { center.post(name: NSWorkspace.didWakeNotification, object: nil) }.value
        #expect(window.systemJustWokeUp())
        window.setSystemJustWokeUp(false); window.cleanupBeforeExiting()
        center.post(name: NSWorkspace.didWakeNotification, object: nil); #expect(!window.systemJustWokeUp())
    }
    @Test func weakTimersDoNotKeepAClosedWindowAliveAndAreInvalidatedOnDeinit() throws {
        let f = try GraphWindowFixture(); defer { f.cleanUp() }
        weak var weakWindow: XRGGraphWindow?
        var timers: [Timer] = []
        autoreleasepool {
            var window: XRGGraphWindow? = XRGGraphWindow(contentRect: f.window.frame, defaults: f.defaults, scheduleTimers: true)
            window?.initTimers(); timers = [window!.min30Timer!, window!.min5Timer!, window!.graphTimer!, window!.fastTimer!, window!.aiTimer!]
            weakWindow = window; window?.close(); window = nil
        }
        #expect(weakWindow == nil && timers.allSatisfy { !$0.isValid })
    }
    @Test func customDragTracksScreenCoordinatesAndResetsAtBordersAndMouseUp() throws {
        let f = try GraphWindowFixture(); defer { f.cleanUp() }; f.window.appSettings?.stickyWindow = false
        let original = f.window.frame.origin
        f.window.handleWindowDrag(try f.event(.leftMouseDown, NSPoint(x: 100, y: 100)))
        f.window.handleWindowDrag(try f.event(.leftMouseDragged, NSPoint(x: 120, y: 130)))
        #expect(f.window.frame.origin == NSPoint(x: original.x + 20, y: original.y + 30))
        f.window.handleWindowDrag(try f.event(.leftMouseUp, NSPoint(x: 120, y: 130))); #expect(!f.window.draggingWindow)
        f.window.handleWindowDrag(try f.event(.leftMouseDown, NSPoint(x: 1, y: 1))); #expect(!f.window.draggingWindow)
    }
    @Test(arguments: ["GraphWindow", "LegacyGraphWindow"])
    func decodesCurrentAndLegacyNativeWindowTemplatesWithoutPanelsOrRuntime(name: String) throws {
        _ = NSApplication.shared
        let nib = try #require(NSNib(nibNamed: name, bundle: Bundle(for: GraphWindowNibOwner.self)))
        var objects: NSArray?
        #expect(nib.instantiate(withOwner: GraphWindowNibOwner(), topLevelObjects: &objects))
        let window = try #require(objects?.compactMap { $0 as? XRGGraphWindow }.first)
        window.isReleasedWhenClosed = false
        defer { window.cleanupBeforeExiting(); window.close() }
        #expect(window.appSettings != nil && window.moduleManager != nil && window.borderWidth >= 0)
        #expect(window.contentView?.subviews.isEmpty == true && window.controller == nil && window.graphTimer == nil && window.xrgCheckURL == nil)
        #expect(window.frameAutosaveName.isEmpty && window.isMovableByWindowBackground)
        let controller = WindowControllerSpy()
        window.setValue(controller, forKey: "controller")
        window.showGeneralPreferences()
        #expect(window.controller === controller && controller.panels == ["General"])
        window.setValue(nil, forKey: "controller")
    }
    @Test(arguments: ["moreInfo", "disable", "notYet", "invalid", "error", "same"])
    func updateChecksUseTheForkConsumeOnceAndKeepAlertsAndOpeningInjected(choice: String) async throws {
        let f = try GraphWindowFixture(); defer { f.cleanUp() }
        var addresses: [String] = [], notices = 0, opened: [URL] = []
        // The transport executes off actor; only this locked request list is shared.
        let captured = WindowRequestCapture()
        var window: XRGGraphWindow?
        window = XRGGraphWindow(contentRect: f.window.frame, defaults: f.defaults, makeUpdateURL: {
            XRGURL(transport: { request in
                captured.append(request.url!.absoluteString)
                if choice == "error" { throw URLError(.timedOut) }
                return Data((choice == "invalid" ? "<html>failed</html>" : choice == "same" ? "2.0" : " 2.1b1\n").utf8)
            })
        }, updateNotice: { latest, current in
            notices += 1; #expect(latest == "2.1b1" && current == "2.0")
            window?.checkServerForUpdatesPostProcess()
            return choice == "moreInfo" ? .moreInfo : choice == "disable" ? .disable : .notYet
        }, openURL: { opened.append($0); return true })
        let target = try #require(window)
        defer { target.cleanupBeforeExiting(); target.close(); window = nil }
        target.appSettings?.checkForUpdates = true; f.defaults.set(true, forKey: "checkForUpdates")
        target.checkServerForUpdates()
        for _ in 0..<100 where target.xrgCheckURL?.isDataReady() != true && target.xrgCheckURL?.didErrorOccur() != true { try await Task.sleep(for: .milliseconds(1)) }
        target.checkServerForUpdatesPostProcess(); target.checkServerForUpdatesPostProcess()
        addresses = captured.values()
        #expect(addresses == ["https://raw.githubusercontent.com/sdelavega/XRG-ng/main/latest_version.txt"])
        #expect(notices == (["invalid", "error", "same"].contains(choice) ? 0 : 1) && target.xrgCheckURL == nil)
        #expect(opened.map(\.absoluteString) == (choice == "moreInfo" ? ["https://github.com/sdelavega/XRG-ng/releases"] : []))
        if choice == "disable" { #expect(!f.defaults.bool(forKey: "checkForUpdates") && target.appSettings?.checkForUpdates == false) }
        else { #expect(f.defaults.bool(forKey: "checkForUpdates") && target.appSettings?.checkForUpdates == true) }
    }
}
private final class WindowRequestCapture: @unchecked Sendable {
    private let lock = NSLock()
    private var requests: [String] = []
    func append(_ text: String) { lock.withLock { requests.append(text) } }
    func values() -> [String] { lock.withLock { requests } }
}

struct XRGWindowSnapTests {
    @Test(arguments: [(12.0, 300.0, 0.0, 300.0), (790, 300, 800, 300), (350, 690, 350, 700), (395, 690, 400, 700),
                      (12, 345, 0, 350), (500, 10, 500, 0), (500, 300, 500, 300), (-50, 810, 0, 700)])
    @MainActor func edgesAndAlignedCenters(pair: (Double, Double, Double, Double)) {
        let frame = NSRect(x: 0, y: 0, width: 1000, height: 800)
        let point = XRGGraphWindow.snap(NSPoint(x: pair.0, y: pair.1), size: NSSize(width: 200, height: 100), screens: [frame], currentScreen: frame)
        #expect(point == NSPoint(x: pair.2, y: pair.3))
    }
    @Test @MainActor func followsTheNewWindowCenterAcrossNegativeCoordinateScreens() {
        let left = NSRect(x: -1000, y: 0, width: 1000, height: 800), right = NSRect(x: 0, y: 0, width: 1000, height: 800)
        #expect(XRGGraphWindow.snap(NSPoint(x: -990, y: 300), size: NSSize(width: 200, height: 100), screens: [left, right], currentScreen: right) == NSPoint(x: -1000, y: 300))
        #expect(XRGGraphWindow.snap(NSPoint(x: 42, y: 50), size: .zero, screens: [], currentScreen: nil) == NSPoint(x: 42, y: 50))
    }
}
