// Copyright (C) 2026 Stephen de la Vega.
// SPDX-License-Identifier: GPL-3.0-or-later
import AppKit
import Darwin
@testable import XRGCore

@MainActor func runSmoke() throws {
    // AppKit interprets positional arguments as files to open. Keep harness inputs out of argv.
    let environment = ProcessInfo.processInfo.environment
    guard let domain = environment["XRG_SMOKE_DOMAIN"], let phase = environment["XRG_SMOKE_PHASE"],
          let outputPath = environment["XRG_SMOKE_RESULTS"] else { throw XRGSmokeError.failed("Missing smoke environment") }
    try smokeCheck(CommandLine.arguments.count == 1, "Smoke inputs must not be passed as document paths")
    let prefix = "com.sdelavega.XRG-ng.Smoke."
    try smokeCheck(domain.hasPrefix(prefix) && UUID(uuidString: String(domain.dropFirst(prefix.count))) != nil,
                   "Smoke preferences require a generated, private UUID domain")
    try smokeCheck(phase == "seed" || phase == "restore", "Invalid smoke phase")
    let output = URL(fileURLWithPath: outputPath, isDirectory: true)
    func capture(_ view: NSView?, _ name: String) throws {
        guard let view, let bitmap = view.bitmapImageRepForCachingDisplay(in: view.bounds) else { return }
        view.cacheDisplay(in: view.bounds, to: bitmap)
        if let png = bitmap.representation(using: .png, properties: [:]) { try png.write(to: output.appendingPathComponent(name)) }
    }
    try smokeCheck(Bundle.main.bundleIdentifier == domain, "Smoke bundle and private preference domain must match")
    let defaults = UserDefaults.standard
    if phase == "seed" {
        defaults.set(false, forKey: "checkForUpdates"); defaults.set(true, forKey: "isDockIconHidden")
        for key in ["showCPUGraph", "showGPUGraph", "showNPUGraph", "showMemoryGraph", "showBatteryGraph", "showTemperatureGraph",
                    "showNetworkGraph", "showDiskGraph", "showWeatherGraph", "showStockGraph", "showAITokenGraph"] {
            defaults.set(true, forKey: key)
        }
        defaults.set("KSEA", forKey: "icao"); defaults.set("FIX", forKey: "stockSymbols")
    } else {
        try smokeCheck(defaults.integer(forKey: "aiTokensDailyBudget") == 1337, "Saved budget did not survive process exit")
        try smokeCheck(defaults.bool(forKey: "windowIsMinimized"), "Saved collapsed state did not survive process exit")
    }
    let app = NSApplication.shared
    app.setActivationPolicy(.prohibited)
    let activity = ProcessInfo.processInfo.beginActivity(options: .userInitiatedAllowingIdleSystemSleep, reason: "XRG fixture smoke test")
    defer { ProcessInfo.processInfo.endActivity(activity) }
    let scene = try XRGApplicationSmokeScene(defaults: defaults, resources: .main)
    defer { scene.shutdown() }
    app.delegate = scene.delegate
    var launched = false, failure: Error?
    let token = NotificationCenter.default.addObserver(forName: NSApplication.didFinishLaunchingNotification, object: app, queue: .main) { _ in
        DispatchQueue.main.async {
            MainActor.assumeIsolated {
                do {
                    launched = true
                    try scene.launched()
                    if phase == "restore" {
                        try smokeCheck(scene.window.minimized, "Relaunched window was not collapsed")
                        try smokeCheck(scene.window.moduleManager?.graphOrientationVertical == false, "Saved orientation was not restored")
                        try smokeCheck(scene.window.appSettings?.windowTitle == "XRG smoke restore", "Saved title was not restored")
                    }
                    try scene.sampleAndExercise()
                    try capture(scene.window.contentView, "layout-\(phase).png")
                    try capture(scene.window.npuView, "npu-\(phase).png")
                    scene.delegate.showPrefs(withPanel: "General")
                    try capture(scene.delegate.prefController?.GeneralPrefView, "general-\(phase).png")
                    guard let pref = scene.delegate.prefController, let orientation = pref.graphOrientation,
                          let budget = pref.AIPrefView?.viewWithTag(1002) as? NSTextField else {
                        throw XRGSmokeError.failed("Missing production preferences controls")
                    }
                    orientation.selectItem(at: 1)
                    guard let action = orientation.action else { throw XRGSmokeError.failed("Orientation action is missing") }
                    try smokeCheck(app.sendAction(action, to: orientation.target, from: orientation), "Orientation action was not delivered")
                    pref.windowTitle?.stringValue = "XRG smoke restore"; budget.stringValue = "1337"
                    try smokeCheck(pref.persistPreferences(), "Production preferences did not save")
                    if let view = scene.window.contentView, let bitmap = view.bitmapImageRepForCachingDisplay(in: view.bounds) {
                        view.cacheDisplay(in: view.bounds, to: bitmap)
                        if let png = bitmap.representation(using: .png, properties: [:]) {
                            try png.write(to: output.appendingPathComponent("\(phase).png"))
                        }
                    }
                    try scene.showNPUTrafficFixture()
                    if let view = scene.window.npuView {
                        let size = view.frame.size
                        view.setFrameSize(NSSize(width: 86, height: 90))
                        try capture(view, "npu-traffic-\(phase).png")
                        view.setFrameSize(size)
                    }
                    scene.background.minimizeWindow()
                } catch { failure = error }
                app.stop(nil)
                if let event = NSEvent.otherEvent(with: .applicationDefined, location: .zero, modifierFlags: [], timestamp: 0,
                                                 windowNumber: 0, context: nil, subtype: 0, data1: 0, data2: 0) {
                    app.postEvent(event, atStart: true)
                }
            }
        }
    }
    defer { NotificationCenter.default.removeObserver(token); app.delegate = nil }
    app.run()
    if let failure { throw failure }
    try smokeCheck(launched, "AppKit did not finish launching")
    let timers = [scene.window.graphTimer, scene.window.fastTimer, scene.window.min5Timer, scene.window.min30Timer].compactMap { $0 }
    try smokeCheck(timers.count == 4, "Expected all four graph timers before shutdown")
    let moduleCount = scene.window.moduleManager?.moduleList().count ?? 0
    scene.shutdown()
    try smokeCheck(timers.allSatisfy { !$0.isValid }, "Shutdown left graph timers active")
    try smokeCheck(defaults.synchronize(), "Private preferences did not synchronize")
    let report: [String: Any] = ["phase": phase, "pid": ProcessInfo.processInfo.processIdentifier,
                               "appKitLaunchNotification": launched, "moduleCount": moduleCount,
                               "budget": defaults.integer(forKey: "aiTokensDailyBudget"),
                               "collapsed": defaults.bool(forKey: "windowIsMinimized"),
                               "nibs": scene.inputs.nibs, "failures": scene.inputs.errors,
                               "shutdownTimersInvalidated": true]
    try JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted, .sortedKeys])
        .write(to: output.appendingPathComponent("\(phase).json"))
    print("PASS: isolated AppKit \(phase), eleven fixture-backed panels, preference persistence and delegate shutdown")
}

exit(MainActor.assumeIsolated {
    do { try runSmoke(); return Int32(0) }
    catch { fputs("Smoke failed: \(error)\n", stderr); return Int32(1) }
})
