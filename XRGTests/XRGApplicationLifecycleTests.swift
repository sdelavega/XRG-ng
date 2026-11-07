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
        let timers = [scene.window.graphTimer, scene.window.fastTimer, scene.window.min5Timer, scene.window.min30Timer, scene.window.aiTimer]
        #expect(timers.compactMap({ $0 }).count == 5)
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
        _ = try #require(scene.delegate.settingsWindowController)
        var theme = try XRGTheme.Builtin.classic.dictionary()
        theme["textTransparency"] = 0.4
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

    @Test func settingsWindowInstantApplyReplacesTheDraftGraphOptionsEditor() throws {
        let (domain, defaults) = try preferences(); defer { defaults.removePersistentDomain(forName: domain) }
        let scene = try XRGApplicationSmokeScene(defaults: defaults, resources: resources); defer { scene.shutdown() }
        scene.delegate.applicationDidFinishLaunching(Notification(name: NSApplication.didFinishLaunchingNotification))
        try scene.launched()
        scene.delegate.showPrefs(nil)
        let settings = try #require(scene.delegate.settingsWindowController)
        settings.show(section: "graphs")
        let manager = try #require(scene.window.moduleManager)
        // Visibility through the window's toggle: instant apply, no draft —
        // asserted LIVE, against the module the layout serves (review
        // issue 11), not only against the stored values.
        let visibility = try #require(settings.currentControls.first { $0.entry.id == "graphs.cpu.visible" } as? XRGSettingsToggleControl)
        visibility.click()
        #expect(scene.window.appSettings?.moduleVisible(.cpu) == false)
        #expect(manager.getModule(byName: "CPU")?.isDisplayed == false)
        #expect(defaults.bool(forKey: "showCPUGraph") == false)
        visibility.click()
        #expect(manager.getModule(byName: "CPU")?.isDisplayed == true)
        // A height override through the window's number field reaches the
        // live layout: the module's served height becomes the override.
        let height = try #require(settings.currentControls.first { $0.entry.id == "graphs.cpu.height" } as? XRGSettingsNumberControl)
        let before = try #require(manager.getModule(byName: "CPU")?.currentSize.height)
        height.field.stringValue = "128"
        height.fieldEdited()
        let restored = XRGSettings(defaults: defaults)
        #expect(restored.graphPreferences[.cpu].height == 128)
        #expect(manager.getModule(byName: "CPU")?.currentSize.height == 128)
        #expect(manager.getModule(byName: "CPU")?.currentSize.height != before)
        // A reset with confirmation restores the section's defaults — live.
        var asked = 0
        settings.confirmReset = { _ in asked += 1; return true }
        let reset = try #require(settings.currentControls.first { $0.entry.id == "graphs.reset" } as? XRGSettingsActionControl)
        #expect(reset.button.accessibilityPerformPress())
        #expect(asked == 1 && defaults.bool(forKey: "showCPUGraph") == true)
        #expect(XRGSettings(defaults: defaults).graphPreferences[.cpu].height != 128)
        #expect(manager.getModule(byName: "CPU")?.isDisplayed == true)
        #expect(manager.getModule(byName: "CPU")?.currentSize.height != 128)
    }

    /// Review issue 1: every settings-window edit reconciles the live
    /// window and module manager — orientation, border width, window
    /// level, shadow, heights and the order all reach the live layout —
    /// on the document-backed production path, and the persisted module
    /// sizes a relayout feeds back never loop.
    @Test func settingsWindowEditsReachTheLiveWindowAndManagerOnTheDocumentPath() throws {
        let (domain, defaults) = try preferences(); defer { defaults.removePersistentDomain(forName: domain) }
        // A document store over a fixture document under the task's scratch:
        // never the real com.sdelavega.xrg domain, never the real settings.json.
        let root = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
            .appendingPathComponent("xrg-0.2.3-task-9", isDirectory: true)
            .appendingPathComponent(domain, isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = XRGSettingsStore(fileURL: root.appendingPathComponent("settings.json"), defaults: defaults,
                                      catalog: try #require(try? XRGSettingsCatalog.load()),
                                      legacyDomain: defaults.persistentDomain(forName: domain) ?? [:])
        let scene = try XRGApplicationSmokeScene(defaults: defaults, resources: resources, store: store); defer { scene.shutdown() }
        scene.delegate.applicationDidFinishLaunching(Notification(name: NSApplication.didFinishLaunchingNotification))
        try scene.launched()
        let manager = try #require(scene.window.moduleManager)
        scene.delegate.showSettings(section: "general", sender: nil)
        let settings = try #require(scene.delegate.settingsWindowController)
        #expect(settings.store.isDocumentBacked)
        settings.show(section: "general")

        // Border width reaches the live window and the layout follows it.
        #expect(scene.window.borderWidth == 4)
        let border = try #require(settings.currentControls.first { $0.entry.id == "general.window.border_width" } as? XRGSettingsNumberControl)
        border.field.stringValue = "8"
        border.fieldEdited()
        #expect(scene.window.borderWidth == 8, "an edit did not reach the live border width")
        #expect(store.value("general.window.border_width") == .int(8))
        #expect(try String(contentsOf: root.appendingPathComponent("settings.json"), encoding: .utf8)
            .contains("\"general.window.border_width\": 8"))

        // Window level and shadow reach the live window.
        let level = try #require(settings.currentControls.first { $0.entry.id == "general.window.level" } as? XRGSettingsChoiceControl)
        level.popUp.selectItem(withTitle: "Floating")
        #expect(NSApp.sendAction(try #require(level.popUp.action), to: level.popUp.target, from: level.popUp))
        #expect(scene.window.level == .floating)
        let shadow = try #require(settings.currentControls.first { $0.entry.id == "general.window.drop_shadow" } as? XRGSettingsToggleControl)
        #expect(!scene.window.hasShadow)
        #expect(shadow.accessibilityPerformPress())
        #expect(scene.window.hasShadow)

        // Orientation rotates the live layout (and back).
        let orientation = try #require(settings.currentControls.first { $0.entry.id == "general.window.orientation" } as? XRGSettingsChoiceControl)
        let frame = scene.window.frame
        orientation.popUp.selectItem(withTitle: "Horizontal")
        #expect(NSApp.sendAction(try #require(orientation.popUp.action), to: orientation.popUp.target, from: orientation.popUp))
        #expect(manager.graphOrientationVertical == false)
        // The rotation swaps the axes; the window may then grow to the
        // horizontal layout's minimum (checkWindowSize).
        #expect(scene.window.frame.size.height == frame.width)
        #expect(scene.window.frame.size.width >= frame.height)

        // Visibility, a height override and the order reach the live modules.
        settings.show(section: "graphs")
        let visibility = try #require(settings.currentControls.first { $0.entry.id == "graphs.battery.visible" } as? XRGSettingsToggleControl)
        #expect(visibility.accessibilityPerformPress())
        #expect(manager.getModule(byName: "Battery")?.isDisplayed == false)
        #expect(manager.getModule(byName: "Battery")?.currentSize == .zero)
        let height = try #require(settings.currentControls.first { $0.entry.id == "graphs.cpu.height" } as? XRGSettingsNumberControl)
        height.field.stringValue = "128"
        height.fieldEdited()
        #expect(manager.getModule(byName: "CPU")?.currentSize.height == 128)
        let order = try #require(settings.currentControls.first { $0.entry.id == "graphs.order" } as? XRGSettingsOrderControl)
        #expect(try #require(order.rows.first?.down).accessibilityPerformPress())
        #expect(manager.displayList().prefix(2).compactMap(\.name) == ["GPU", "CPU"])

        // A section reset restores every live piece.
        var asked = 0
        settings.confirmReset = { _ in asked += 1; return true }
        let reset = try #require(settings.currentControls.first { $0.entry.id == "graphs.reset" } as? XRGSettingsActionControl)
        #expect(reset.button.accessibilityPerformPress())
        #expect(asked == 1)
        #expect(manager.getModule(byName: "Battery")?.isDisplayed == true)
        #expect(manager.getModule(byName: "Battery")?.currentSize != .zero)
        #expect(manager.getModule(byName: "CPU")?.currentSize.height != 128)
        #expect(manager.displayList().prefix(2).compactMap(\.name) == ["CPU", "GPU"])
    }

    @Test func injectedUnknownSensorPolicyAndLazyNibFailuresDoNotFallBackToGlobalHardware() throws {
        let (domain, defaults) = try preferences(); defer { defaults.removePersistentDomain(forName: domain) }
        var loaded: [String] = [], errors = 0
        let delegate = XRGAppDelegate(defaults: defaults, loadNib: { name, _ in loaded.append(name) },
                                      includeUnknownSensors: { true }, sensorProvider: { _ in [] },
                                      invalidThemeNotice: { _ in errors += 1 })
        #expect(delegate.sensorWindowIncludesUnknownSensors && delegate.sensorWindowSensors(includingUnknown: true).isEmpty)
        delegate.openAIPreferences(nil); delegate.openSensorWindow(nil)
        #expect(loaded == ["Sensors"] && delegate.settingsWindowController != nil && delegate.sensorWindow == nil)
        #expect(errors == 0)
    }
}
