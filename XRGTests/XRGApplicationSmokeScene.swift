// Copyright (C) 2026 Stephen de la Vega.
// SPDX-License-Identifier: GPL-3.0-or-later
// Shared by lifecycle tests and the separate AppKit smoke executable.
import AppKit
@testable import XRGCore

enum XRGSmokeError: Error, CustomStringConvertible {
    case failed(String)
    var description: String { switch self { case let .failed(message): return message } }
}
func smokeCheck(_ condition: @autoclosure () -> Bool, _ message: String) throws {
    if !condition() { throw XRGSmokeError.failed(message) }
}

@MainActor final class XRGSmokeInputs {
    var time: TimeInterval = 100
    var cpuReads = 0, gpuReads = 0, npuReads = 0, memoryReads = 0, netReads = 0, diskReads = 0, batteryReads = 0
    var activations = 0
    var nibs: [String] = [], presentations: [NSWindow] = [], errors: [String] = []
    var load: ((String, XRGAppDelegate) -> Void)?
}
@MainActor private final class SmokeTemperatureReader: NSObject, XRGTemperatureReader {
    var knownTemperatureKeyCount = 20
    func temperatures(includingUnknown: Bool) -> [String: Any] { ["cpu": 50, "gpu": 45] }
    func siliconTemperatures() -> [String: Any] { [:] }
    func fanReadings() -> [String: Any] { [:] }
    func name(forKey key: String) -> String? { key == "cpu" ? "Fixture CPU" : "Fixture GPU" }
    func isKnownKey(_ key: String) -> Bool { true }
}
@MainActor private final class SmokeWeather: XRGWeatherTransport {
    private var ready = false
    func setURLString(_ value: String?) {}
    func loadURLInBackground() { ready = true }
    func cancelLoading() { ready = false }
    func isDataReady() -> Bool { ready }
    func didErrorOccur() -> Bool { false }
    func getData() -> Data? { Data("KSEA 251953Z 21016G24KT 9999 20/10 A2992 RMK AO2".utf8) }
}
@MainActor private final class SmokeStock: XRGStockViewData {
    var symbol: String?
    var label: String? { symbol }
    var gettingData: Bool { false }
    var haveGoodDisplayData: Bool { true }
    func resetData() {}
    func loadData() {}
    func get1MonthValues() -> [NSNumber]? { [10, 11, 12] }
    func get3MonthValues() -> [NSNumber]? { get1MonthValues() }
    func get6MonthValues() -> [NSNumber]? { get1MonthValues() }
    func get12MonthValues() -> [NSNumber]? { get1MonthValues() }
    func getCurrentPriceAndChange() -> [NSNumber]? { [12, 1] }
    func priceString() -> String { "12.00" }
    func changeString() -> String { "+1.00" }
}
@MainActor private final class SmokeTokens: XRGAITokenViewSource {
    var geminiEventHandler: ((UInt64, UInt64) -> Void)?
    var updates = 0
    func setDataSize(_ count: Int) {}
    func getLatestTokenInfo() { updates += 1 }
    func viewSnapshot() -> XRGAITokenViewSnapshot { XRGAITokenViewSnapshot() }
}
private final class SmokePreferencesOwner: NSObject {
    @objc var prefController: XRGPrefController?
}

@MainActor final class XRGApplicationSmokeScene {
    static let moduleNames = ["CPU", "GPU", "NPU", "Memory", "Battery", "Temperature", "Network", "Disk", "Weather", "Stock", "AI Tokens"]
    let defaults: UserDefaults
    let resources: Bundle
    let inputs = XRGSmokeInputs()
    let center = NotificationCenter()
    let window: XRGGraphWindow
    let delegate: XRGAppDelegate
    let background: XRGBackgroundView
    let temperature: XRGTemperatureMiner
    let panels: [NSView]
    private var nibObjects: [NSArray] = []
    private var stopped = false

    init(defaults: UserDefaults, resources: Bundle) throws {
        _ = NSApplication.shared
        self.defaults = defaults; self.resources = resources
        try smokeCheck(defaults.object(forKey: "checkForUpdates") as? Bool == false, "Smoke preferences must explicitly disable update requests")
        window = XRGGraphWindow(contentRect: NSRect(x: 100, y: 200, width: 600, height: 900),
                                defaults: defaults, center: center, runtimeEnabled: true)
        guard let settings = window.appSettings else { throw XRGSmokeError.failed("Missing settings") }
        let source = inputs
        temperature = XRGTemperatureMiner(reader: SmokeTemperatureReader(), clock: { source.time })
        let temperature = self.temperature
        delegate = XRGAppDelegate(defaults: defaults, loadNib: { name, owner in
            source.nibs.append(name); source.load?(name, owner)
        }, presentWindow: { window, _ in source.presentations.append(window) },
           activateApplication: { source.activations += 1 },
           includeUnknownSensors: { XRGTemperatureView.includesUnknownSensors(defaults: defaults, knownCount: temperature.knownTemperatureKeyCount) },
           sensorProvider: { unknown in temperature.locationKeys(includingUnknown: unknown).compactMap { temperature.sensor(forLocation: $0) } },
           invalidThemeNotice: { source.errors.append(String(describing: $0)) })
        background = XRGBackgroundView(frame: NSRect(origin: .zero, size: window.frame.size), defaults: defaults)
        let frame = NSRect(x: 0, y: 0, width: 400, height: 80)
        let process = XRGProcessMiner(source: { [] })
        let cpu = XRGCPUMiner(source: {
            source.cpuReads += 1
            return [XRGCPUTicks(user: UInt32(source.cpuReads * 20), system: UInt32(source.cpuReads * 10), idle: UInt32(source.cpuReads * 70), nice: 0)]
        })
        let gpu = XRGGPUMiner(source: {
            source.gpuReads += 1
            return [XRGGPUSample(id: 1, vendor: "Fixture", total: 1024, free: 512, wait: 0, utilization: 25)]
        })
        let npu = XRGNPUMiner(source: {
            source.npuReads += 1
            return XRGNPUReading(time: source.time, devices: [XRGNPUDevice(id: 7, cores: 16, architecture: "Fixture", firmwareLoaded: true)], appleSilicon: true,
                                 energy: [XRGNPUEnergy(id: "fixture-ane", unit: "mJ", value: Int64(source.npuReads * 250))], error: nil,
                                 activity: source.time > 0 ? .init(start: max(0, source.time - 0.5), end: source.time,
                                     clusters: [.init(id: "fixture-ane", states: ["ACT": 25, "IDLE": 75])]) : nil)
        }, clock: { source.time })
        let memory = XRGMemoryMiner(pageSize: 4096, source: {
            source.memoryReads += 1
            var value = XRGMemorySnapshot(); value.free = 1000; value.active = 2000; value.wired = 1000
            return value
        })
        let net = { XRGNetMiner(source: {
            source.netReads += 1
            return [XRGNetworkSample(name: "fixture0", index: 1, received: UInt64(source.netReads * 2048), sent: UInt64(source.netReads * 1024))]
        }, clock: { source.time }) }
        let disk = XRGDiskMiner(source: {
            source.diskReads += 1
            return [XRGDiskSample(id: 1, read: UInt64(source.diskReads * 4096), written: UInt64(source.diskReads * 1024))]
        }, clock: { source.time })
        let battery = XRGBatteryMiner(source: { source.batteryReads += 1; return [] })
        let observer = XRGAITokensObserver(defaults: defaults, center: center, calendar: .current, now: { Date(timeIntervalSince1970: 1_770_000_000) })
        panels = [
            XRGCPUView(frame: frame, miner: cpu, processMiner: process, settings: settings, defaults: defaults),
            XRGGPUView(frame: frame, miner: gpu, settings: settings, defaults: defaults),
            XRGNPUView(frame: frame, miner: npu, settings: settings, defaults: defaults),
            XRGMemoryView(frame: frame, memoryMiner: memory, processMiner: process, settings: settings, defaults: defaults),
            XRGBatteryView(frame: frame, miner: battery, settings: settings, defaults: defaults),
            XRGTemperatureView(frame: frame, miner: temperature, settings: settings, defaults: defaults),
            XRGNetView(frame: frame, miner: net(), fastMiner: net(), settings: settings, defaults: defaults),
            XRGDiskView(frame: frame, miner: disk, settings: settings, defaults: defaults),
            XRGWeatherView(frame: frame, settings: settings, defaults: defaults, sources: [SmokeWeather(), SmokeWeather()]),
            XRGStockView(frame: frame, settings: settings, defaults: defaults, makeStock: { SmokeStock() }),
            XRGAITokenView(frame: frame, source: SmokeTokens(), observer: observer, settings: settings, defaults: defaults,
                          databaseURL: URL(fileURLWithPath: "/nonexistent/xrg-smoke-database"))
        ]
        delegate.xrgGraphWindow = window; window.controller = delegate
        window.contentView?.addSubview(background); background.awakeFromNib()
        for panel in panels { window.contentView?.addSubview(panel); panel.awakeFromNib() }
        inputs.load = { [weak self] name, owner in
            do { try self?.load(name, owner: owner) }
            catch { source.errors.append(String(describing: error)) }
        }
    }

    private func load(_ name: String, owner: XRGAppDelegate) throws {
        if name == "Sensors" {
            var objects: NSArray?
            try smokeCheck(resources.loadNibNamed("SmokeSensors", owner: owner, topLevelObjects: &objects), "Sensor nib failed to load")
            if let objects { nibObjects.append(objects) }
            owner.sensorWindow?.isReleasedWhenClosed = false
            return
        }
        guard name == "Preferences" else { throw XRGSmokeError.failed("Unexpected nib: \(name)") }
        // Decode the existing fixture without attaching its default dependencies to the app.
        let oldDelegate = NSApp.delegate; NSApp.delegate = nil
        defer { NSApp.delegate = oldDelegate }
        let nibOwner = SmokePreferencesOwner()
        var objects: NSArray?
        guard let nib = NSNib(nibNamed: "Preferences", bundle: resources),
              nib.instantiate(withOwner: nibOwner, topLevelObjects: &objects),
              let decoded = nibOwner.prefController,
              let url = resources.url(forResource: "PreferencesOutletKeys", withExtension: "plist"),
              let keys = try PropertyListSerialization.propertyList(from: Data(contentsOf: url), options: [], format: nil) as? [String]
        else { throw XRGSmokeError.failed("Preferences fixture did not decode") }
        if let objects { nibObjects.append(objects) }
        let temperature = self.temperature, defaults = self.defaults
        let pref = XRGPrefController(defaults: defaults, center: center,
                                    sensors: { temperature.locationKeys(includingUnknown: true).compactMap { temperature.sensor(forLocation: $0) } },
                                    interfaces: { _ in ["fixture0"] })
        for key in keys { pref.setValue(decoded.value(forKey: key), forKey: key) }
        pref.AIPrefView = decoded.AIPrefView
        func retarget(_ view: NSView) {
            if let control = view as? NSControl, control.target === decoded { control.target = pref }
            for child in view.subviews { retarget(child) }
        }
        for view in pref.panelViews.compactMap({ $0 }) { retarget(view) }
        pref.xrgGraphWindow = window; pref.configure(); owner.prefController = pref
    }

    func launched() throws {
        try smokeCheck(inputs.activations == 1, "Application launch delegate did not run exactly once")
        try smokeCheck(window.moduleManager?.moduleList().count == 11, "Expected eleven production panels")
        try smokeCheck(window.moduleManager?.displayList().prefix(4).compactMap(\.name) == ["CPU", "GPU", "NPU", "Memory"], "Neural Engine is not between GPU and Memory")
        for (name, panel) in zip(Self.moduleNames, panels) {
            try smokeCheck(window.moduleManager?.getModule(byName: name)?.reference === panel, "Missing module registration: \(name)")
        }
        try smokeCheck(window.aiTokenView === panels.last, "Launch replaced the injected AI panel")
        try smokeCheck(window.xrgCheckURL == nil, "Unexpected update request")
        try smokeCheck(!window.isVisible, "Smoke window became visible")
        if defaults.bool(forKey: "showSensorWindow") {
            try smokeCheck(delegate.sensorWindow != nil && delegate.sensorViewController != nil, "Saved sensor window was not restored")
        }
        if window.minimized {
            let strip = 2 * CGFloat(window.borderWidth) + (window.appSettings?.textRectHeight ?? 0)
            let collapsed = window.moduleManager?.graphOrientationVertical == true ? window.frame.height : window.frame.width
            try smokeCheck(abs(collapsed - strip) < 1, "Collapsed startup frame has expanded dimensions")
        }
    }
    func sampleAndExercise() throws {
        background.expandWindow()
        inputs.time += 2; window.graphUpdate(nil); window.fastUpdate(nil); window.min5Update(nil); window.min30Update(nil)
        window.weatherView?.min30UpdatePostProcessing()
        try smokeCheck(inputs.cpuReads > 0 && inputs.gpuReads > 0 && inputs.npuReads > 0 && inputs.memoryReads > 0 && inputs.netReads > 0 && inputs.diskReads > 0 && inputs.batteryReads > 0, "Fixture collector dispatch failed")
        try smokeCheck(window.npuView?.fullReading().contains("Active time: 25.00%") == true, "Neural Engine active-time fixture did not reach the production panel")
        for panel in panels {
            try smokeCheck(panel.frame.width.isFinite && panel.frame.height.isFinite && panel.frame.width > 0 && panel.frame.height > 0, "Invalid panel layout")
        }
        delegate.openAIPreferences(nil)
        guard let pref = delegate.prefController else { throw XRGSmokeError.failed("Missing preferences controller") }
        try smokeCheck(pref.currentView === pref.AIPrefView, "AI action did not select the existing preferences panel")
        for name in ["General", "Appearance", "CPU", "RAM", "Temperature", "Network", "Disk", "Weather", "Stocks", "AI"] {
            delegate.showPrefs(withPanel: name)
            try smokeCheck(pref.toolbar?.selectedItemIdentifier?.rawValue == name, "Preferences route failed: \(name)")
        }
        try smokeCheck(inputs.nibs.filter { $0 == "Preferences" }.count == 1, "Preferences loaded more than once")
        guard let cpu = pref.showCPUGraph, let action = cpu.action else { throw XRGSmokeError.failed("Missing CPU visibility action") }
        for state: NSControl.StateValue in [.off, .on] {
            cpu.state = state
            try smokeCheck(NSApp.sendAction(action, to: cpu.target, from: cpu), "CPU visibility action was not delivered")
            try smokeCheck(window.moduleManager?.getModule(byName: "CPU")?.isDisplayed == (state == .on), "CPU visibility did not change")
        }
        var resized = window.frame; resized.size.width += 30; resized.size.height += 20
        window.setFrame(resized, display: false)
        for panel in panels {
            try smokeCheck(panel.frame.width > 0 && panel.frame.height > 0, "Resize lost a panel")
        }
        delegate.openSensorWindow(nil); delegate.openSensorWindow(nil)
        try smokeCheck(delegate.sensorViewController?.dataSource === delegate, "Sensor data source was not connected")
        try smokeCheck(inputs.nibs.sorted() == ["Preferences", "Sensors"], "Sensor nib did not load exactly once")
        try smokeCheck(!delegate.sensorWindowSensors(includingUnknown: false).isEmpty, "Fixture sensors were not forwarded")
        try smokeCheck(inputs.errors.isEmpty, "Unexpected lifecycle errors: \(inputs.errors)")
        for visible in [window, pref.window, delegate.sensorWindow].compactMap({ $0 }) {
            try smokeCheck(!visible.isVisible, "Smoke action presented a real window: \(visible.title)")
        }
    }
    func shutdown() {
        guard !stopped else { return }; stopped = true
        delegate.applicationWillTerminate(Notification(name: NSApplication.willTerminateNotification))
        delegate.sensorViewController?.viewDidDisappear()
        for auxiliary in [delegate.prefController?.window, delegate.sensorWindow].compactMap({ $0 }) {
            auxiliary.delegate = nil; auxiliary.orderOut(nil); auxiliary.close()
        }
        for panel in panels { panel.removeFromSuperview() }
        background.removeFromSuperview(); window.close()
    }
}
