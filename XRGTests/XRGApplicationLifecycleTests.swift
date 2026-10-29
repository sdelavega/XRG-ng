// Copyright (C) 2026 Stephen de la Vega.
// SPDX-License-Identifier: GPL-3.0-or-later
import AppKit
import Testing
@testable import XRGCore

@Suite(.serialized) @MainActor
struct XRGApplicationLifecycleTests {
    private func preferences() throws -> (String, UserDefaults) {
        let domain = "com.sdelavega.XRG-ng.Smoke.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: domain))
        defaults.set(false, forKey: "checkForUpdates")
        defaults.set(true, forKey: "isDockIconHidden")
        for key in ["showCPUGraph", "showGPUGraph", "showNPUGraph", "showMemoryGraph", "showBatteryGraph", "showTemperatureGraph",
                    "showNetworkGraph", "showDiskGraph", "showWeatherGraph", "showStockGraph", "showAITokenGraph"] {
            defaults.set(true, forKey: key)
        }
        defaults.set("KSEA", forKey: "icao"); defaults.set("FIX", forKey: "stockSymbols")
        return (domain, defaults)
    }
    private var resources: Bundle { Bundle(for: XRGAppDelegate.self) }

    @Test(arguments: [true, false])
    func launchConnectsAllPanelsAndLazyWindowsWithoutSystemActions(vertical: Bool) throws {
        let (domain, defaults) = try preferences(); defer { defaults.removePersistentDomain(forName: domain) }
        defaults.set(vertical, forKey: "graphOrientationVertical")
        defaults.set(vertical, forKey: "showSensorWindow")
        let scene = try XRGApplicationSmokeScene(defaults: defaults, resources: resources); defer { scene.shutdown() }
        scene.delegate.applicationDidFinishLaunching(Notification(name: NSApplication.didFinishLaunchingNotification))
        try scene.launched(); try scene.sampleAndExercise()
        #expect(scene.window.moduleManager?.graphOrientationVertical == vertical)
        let ai = scene.window.aiTokenView, modules = scene.window.moduleManager!.moduleList(), timer = scene.window.graphTimer
        scene.delegate.applicationDidFinishLaunching(Notification(name: NSApplication.didFinishLaunchingNotification))
        #expect(scene.window.aiTokenView === ai && scene.window.graphTimer === timer)
        #expect(scene.window.moduleManager!.moduleList().elementsEqual(modules, by: { $0 === $1 }))
        #expect(scene.inputs.activations == 2 && scene.inputs.errors.isEmpty)
        let sensor = try #require(scene.delegate.sensorWindow)
        #expect(scene.delegate.windowShouldClose(sensor) && !defaults.bool(forKey: "showSensorWindow"))
        #expect(scene.delegate.windowShouldClose(scene.window))
    }

    @Test(arguments: [true, false])
    func collapsedStateSurvivesShutdownAndReconstruction(vertical: Bool) throws {
        let (domain, defaults) = try preferences(); defer { defaults.removePersistentDomain(forName: domain) }
        defaults.set(vertical, forKey: "graphOrientationVertical")
        var scene = try XRGApplicationSmokeScene(defaults: defaults, resources: resources)
        scene.delegate.applicationDidFinishLaunching(Notification(name: NSApplication.didFinishLaunchingNotification))
        try scene.launched()
        scene.background.minimizeWindow()
        #expect(scene.window.minimized && defaults.bool(forKey: "windowIsMinimized"))
        let timers = [scene.window.graphTimer, scene.window.fastTimer, scene.window.min5Timer, scene.window.min30Timer]
        #expect(timers.compactMap({ $0 }).count == 4)
        scene.delegate.workspaceWillPowerOff(Notification(name: NSWorkspace.willPowerOffNotification))
        #expect(timers.compactMap({ $0 }).allSatisfy { !$0.isValid })
        scene.shutdown()
        #expect(defaults.bool(forKey: "windowIsMinimized"))
        scene = try XRGApplicationSmokeScene(defaults: defaults, resources: resources)
        defer { scene.shutdown() }
        scene.delegate.applicationDidFinishLaunching(Notification(name: NSApplication.didFinishLaunchingNotification))
        try scene.launched()
        #expect(scene.window.minimized && scene.background.clickedMinimized)
        scene.background.expandWindow()
        #expect(!scene.window.minimized && scene.window.frame.width > 100 && scene.window.frame.height > 100)
        scene.center.post(name: NSWorkspace.didWakeNotification, object: nil)
        #expect(scene.window.systemJustWokeUp())
    }

    @Test func themeErrorsAreContainedAndOnlyTheInjectedDefaultsReceiveChanges() throws {
        let (domain, defaults) = try preferences(); defer { defaults.removePersistentDomain(forName: domain) }
        let scene = try XRGApplicationSmokeScene(defaults: defaults, resources: resources); defer { scene.shutdown() }
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let file = folder.appendingPathComponent("theme.xtf")
        scene.delegate.showPrefs(nil)
        let pref = try #require(scene.delegate.prefController)
        var theme = try pref.preferencesSnapshot(); theme["textTransparency"] = 0.4
        try PropertyListSerialization.data(fromPropertyList: theme, format: .xml, options: 0).write(to: file)
        #expect(scene.delegate.application(NSApplication.shared, openFile: file.path))
        #expect(defaults.double(forKey: "textTransparency") == 0.4)
        try Data("invalid plist".utf8).write(to: file)
        #expect(!scene.delegate.application(NSApplication.shared, openFile: file.path))
        #expect(scene.inputs.errors.count == 1 && defaults.double(forKey: "textTransparency") == 0.4)
        #expect(!scene.delegate.application(NSApplication.shared, openFile: ""))
    }

    @Test func applicationFileOpenAcceptsPortableThemesAndRejectsInvalidJSONAtomically() throws {
        let (domain, defaults) = try preferences(); defer { defaults.removePersistentDomain(forName: domain) }
        let scene = try XRGApplicationSmokeScene(defaults: defaults, resources: resources); defer { scene.shutdown() }
        let file = FileManager.default.temporaryDirectory.appendingPathComponent("XRG-app-theme-\(UUID().uuidString).json")
        defer { try? FileManager.default.removeItem(at: file) }
        let doc = try XRGThemeDocument(name: "Opened JSON", colors: Array(repeating: [0.1, 0.2, 0.3, 0.4], count: 7))
        try doc.encoded().write(to: file)
        #expect(scene.delegate.application(NSApplication.shared, openFile: file.path))
        #expect(defaults.double(forKey: "textTransparency") == 0.4)
        let before = defaults.persistentDomain(forName: domain) ?? [:]
        try Data("{\"format\":\"xrg-ng-theme\",\"version\":2}".utf8).write(to: file)
        #expect(!scene.delegate.application(NSApplication.shared, openFile: file.path))
        #expect(NSDictionary(dictionary: defaults.persistentDomain(forName: domain) ?? [:]).isEqual(to: before))
    }

    @Test func injectedUnknownSensorPolicyAndLazyNibFailuresDoNotFallBackToGlobalHardware() throws {
        let (domain, defaults) = try preferences(); defer { defaults.removePersistentDomain(forName: domain) }
        var loaded: [String] = [], errors = 0
        let delegate = XRGAppDelegate(defaults: defaults, loadNib: { name, _ in loaded.append(name) },
                                      includeUnknownSensors: { true }, sensorProvider: { _ in [] },
                                      invalidThemeNotice: { _ in errors += 1 })
        #expect(delegate.sensorWindowIncludesUnknownSensors && delegate.sensorWindowSensors(includingUnknown: true).isEmpty)
        delegate.openAIPreferences(nil); delegate.openSensorWindow(nil)
        #expect(loaded == ["Preferences", "Sensors"] && delegate.prefController == nil && delegate.sensorWindow == nil)
        #expect(errors == 0)
    }
}
