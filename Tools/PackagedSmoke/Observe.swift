// Copyright (C) 2026 Stephen de la Vega.
// SPDX-License-Identifier: GPL-3.0-or-later
// Deliberately uses runtime interfaces: linking XRGCore would duplicate its static classes.
import AppKit
import Darwin
import ObjectiveC

@MainActor private var observer: (any NSObjectProtocol)?
@MainActor private var initialGraphTimer: Timer?
@MainActor private var initialGraphFireDate: Date?
@MainActor private var stoppingTimers: [Timer] = []
@MainActor private var pendingReport: [String: Any]?

private enum Failure: Error { case failed(String) }
private func require(_ value: @autoclosure () throws -> Bool, _ message: String) throws {
    if try !value() { throw Failure.failed(message) }
}
@MainActor private func property(_ object: NSObject, _ key: String) throws -> Any? {
    try require(object.responds(to: NSSelectorFromString(key)), "Missing runtime getter: \(key)")
    return object.value(forKey: key)
}
@MainActor private func send(_ object: NSObject, _ selector: String, _ value: Any? = nil) throws {
    let selector = NSSelectorFromString(selector)
    try require(object.responds(to: selector), "Missing runtime action: \(selector)")
    object.perform(selector, with: value)
}
@MainActor private func inspect() throws {
    let env = ProcessInfo.processInfo.environment
    guard let phase = env["XRG_PACKAGED_SMOKE_PHASE"], let orientation = env["XRG_PACKAGED_SMOKE_CASE"],
          let delegate = NSApp.delegate as? NSObject,
          let window = try property(delegate, "xrgGraphWindow") as? NSWindow,
          let manager = try property(window, "moduleManager") as? NSObject,
          let modules = try property(manager, "moduleList") as? [NSObject] else {
        throw Failure.failed("MainMenu did not connect the production application graph")
    }
    try require(XRGPackagedSmokeInstalled() == 1 && NSApp.activationPolicy() == .prohibited, "Presentation protections were lost")
    try require(String(cString: class_getName(type(of: delegate))) == "XRGAppDelegate", "Wrong nib delegate class")
    try require(modules.count == 11, "MainMenu did not register eleven modules")
    let expected = Set(["CPU", "GPU", "NPU", "Memory", "Battery", "Temperature", "Network", "Disk", "Weather", "Stock", "AI Tokens"])
    let names = try Set(modules.map { try property($0, "name") as? String ?? "" })
    try require(names == expected, "Unexpected module identities")
    let displayed = try property(manager, "displayList") as? [NSObject] ?? []
    let order = try displayed.prefix(4).map { try property($0, "name") as? String ?? "" }
    try require(order == ["CPU", "GPU", "NPU", "Memory"], "NPU was not placed between GPU and Memory")
    for object in [delegate, window, manager] + modules {
        guard let image = class_getImageName(type(of: object)) else { throw Failure.failed("Missing runtime image") }
        try require(URL(fileURLWithPath: String(cString: image)).resolvingSymlinksInPath().path == Bundle.main.executableURL?.resolvingSymlinksInPath().path,
                    "A production class came from another image")
    }
    for module in modules {
        guard let panel = try property(module, "reference") as? NSView else { throw Failure.failed("Missing nib panel") }
        try require(panel.window === window, "A nib panel is not attached to its window")
        guard let image = class_getImageName(type(of: panel)) else { throw Failure.failed("Missing panel image") }
        try require(URL(fileURLWithPath: String(cString: image)).resolvingSymlinksInPath().path == Bundle.main.executableURL?.resolvingSymlinksInPath().path,
                    "A panel came from another image")
        if ["Weather", "Stock", "AI Tokens"].contains(try property(module, "name") as? String ?? "") {
            try require((try property(module, "isDisplayed") as? NSNumber)?.boolValue == false, "External provider module was enabled")
        }
    }
    try require(try property(window, "xrgCheckURL") == nil, "Update request was started")
    let timers = try ["graphTimer", "fastTimer", "min5Timer", "min30Timer"].map { key -> Timer in
        guard let timer = try property(window, key) as? Timer else { throw Failure.failed("Missing runtime timer: \(key)") }
        try require(timer.isValid, "Runtime timer is not active: \(key)")
        return timer
    }
    guard let initialGraphFireDate else { throw Failure.failed("Missing launch timer baseline") }
    try require(timers[0] === initialGraphTimer && timers[0].fireDate > initialGraphFireDate, "Graph timer did not advance on the application run loop")
    try require(getpriority(PRIO_PROCESS, id_t(getpid())) >= 10, "Shipping entry point did not lower process priority")
    try require(XRGPackagedSmokeActivations() > 0, "Production launch activation callback did not run")
    let vertical = (try property(manager, "graphOrientationVertical") as? NSNumber)?.boolValue == true
    try require(vertical == (orientation == "vertical"), "Saved orientation was not applied")
    if phase == "restore" {
        try require((try property(window, "minimized") as? NSNumber)?.boolValue == true, "Collapsed state was not restored")
        guard let settings = try property(window, "appSettings") as? NSObject,
              let border = try property(window, "borderWidth") as? NSNumber,
              let text = try property(settings, "textRectHeight") as? NSNumber else { throw Failure.failed("Missing collapsed frame metrics") }
        let collapsed = vertical ? window.frame.height : window.frame.width
        try require(abs(collapsed - (2 * border.doubleValue + text.doubleValue)) < 1, "Restored collapsed geometry is wrong")
    }
    try send(delegate, "openAIPreferences:")
    guard let pref = try property(delegate, "prefController") as? NSObject,
          let prefWindow = try property(pref, "window") as? NSWindow else { throw Failure.failed("Production Preferences nib did not connect") }
    guard let aiPanel = try property(pref, "AIPrefView") as? NSView,
          let currentPanel = try property(pref, "currentView") as? NSView else { throw Failure.failed("Missing AI preferences view") }
    try require(currentPanel === aiPanel, "AI preference route failed")
    for key in ["GeneralPrefView", "ColorPrefView", "CPUPrefView", "MemoryPrefView", "TemperaturePrefView",
                "NetworkPrefView", "DiskPrefView", "WeatherPrefView", "StockPrefView"] {
        try require(try property(pref, key) is NSView, "Missing preferences outlet: \(key)")
    }
    try send(delegate, "openSensorWindow:")
    try require(try property(delegate, "sensorWindow") is NSWindow, "Production Sensors nib did not connect")
    guard let sensor = try property(delegate, "sensorViewController") as? NSObject else { throw Failure.failed("Missing sensor controller outlet") }
    try require(try property(sensor, "dataSource") as? NSObject === delegate, "Sensor controller data source was not connected")
    try require(!NSApp.windows.contains { $0.isVisible } && !prefWindow.isVisible, "A window became visible")
    guard let background = try property(window, "backgroundView") as? NSObject else { throw Failure.failed("Missing background") }
    try send(background, "expandWindow")
    try send(background, "minimizeWindow")
    stoppingTimers = timers
    pendingReport = ["phase": phase, "orientation": orientation, "pid": getpid(), "moduleCount": modules.count,
                               "architecture": String(cString: XRGPackagedSmokeArchitecture()),
                               "translated": XRGPackagedSmokeTranslated() == 1,
                               "mainMenuConnected": true, "productionClassImages": true,
                               "shippingPriority": true, "runtimeTimersAdvanced": true,
                               "preferencesNibLoaded": true, "sensorsNibLoaded": true,
                               "windowsHidden": true, "activationsSuppressed": XRGPackagedSmokeActivations(),
                               "orderingSuppressed": XRGPackagedSmokeOrdering()]
    XRGPackagedInstallTerminationHook(delegate)
    NSApp.terminate(nil)
}

@_cdecl("XRGPackagedSmokeFinished") public func packagedSmokeFinished() {
    MainActor.assumeIsolated {
        do {
            guard var report = pendingReport, let output = ProcessInfo.processInfo.environment["XRG_PACKAGED_SMOKE_RESULTS"],
                  let phase = report["phase"] as? String, let orientation = report["orientation"] as? String else {
                throw Failure.failed("Unexpected termination callback")
            }
            try require(stoppingTimers.count == 4 && stoppingTimers.allSatisfy { !$0.isValid }, "Production shutdown did not invalidate timers")
            try require(UserDefaults.standard.synchronize(), "Private defaults did not synchronize")
            report["timersStopped"] = true; report["appKitTerminationCallback"] = true
            try JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted, .sortedKeys])
                .write(to: URL(fileURLWithPath: output).appendingPathComponent("\(phase)-\(orientation).json"))
            print("PASS: shipping entry point, original nibs, running timers and AppKit termination callback")
            fflush(stdout)
        } catch { fputs("Packaged termination verification failed: \(error)\n", stderr); _exit(1) }
    }
}

@_cdecl("XRGPackagedSmokeStart") public func startPackagedSmoke() {
    MainActor.assumeIsolated {
        observer = NotificationCenter.default.addObserver(forName: NSApplication.didFinishLaunchingNotification, object: nil, queue: .main) { _ in
            MainActor.assumeIsolated {
                if let delegate = NSApp.delegate as? NSObject,
                   let window = (try? property(delegate, "xrgGraphWindow")) as? NSObject {
                    initialGraphTimer = (try? property(window, "graphTimer")) as? Timer
                    initialGraphFireDate = initialGraphTimer?.fireDate
                }
            }
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) {
                MainActor.assumeIsolated {
                    do { try inspect() }
                    catch { fputs("Packaged smoke failed: \(error)\n", stderr); _exit(1) }
                }
            }
        }
    }
}
