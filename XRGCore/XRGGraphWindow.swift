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

@MainActor @objc public protocol XRGGraphWindowController: NSObjectProtocol {
    @objc(showPrefsWithPanel:) func showPrefs(withPanel panel: String)
    func openSensorWindow(_ sender: Any?)
    func refreshGraphPalette()
}

enum XRGUpdateChoice { case moreInfo, disable, notYet }

enum XRGWindowVersion {
    /// Preserve component and beta ordering without converting untrusted digits to fixed-width integers.
    static func isLater(_ latest: String, than current: String) -> Bool {
        func components(_ text: String) -> [(String, String?)]? {
            guard text.utf8.count <= 256, text.range(of: "^[0-9]+(?:b[0-9]+)?(?:\\.[0-9]+(?:b[0-9]+)?)*$", options: .regularExpression) != nil else { return nil }
            return text.split(separator: ".").map {
                let parts = $0.split(separator: "b")
                return (String(parts[0]), parts.count == 2 ? String(parts[1]) : nil)
            }
        }
        func compare(_ a: String, _ b: String) -> Int {
            let a = String(a.drop(while: { $0 == "0" })), b = String(b.drop(while: { $0 == "0" }))
            if a.count != b.count { return a.count > b.count ? 1 : -1 }
            return a == b ? 0 : a > b ? 1 : -1
        }
        guard let a = components(latest), let b = components(current) else { return false }
        for (a, b) in zip(a, b) {
            let revision = compare(a.0, b.0)
            if revision != 0 { return revision > 0 }
            switch (a.1, b.1) {
            case (nil, .some): return true
            case (.some, nil): return false
            case let (.some(a), .some(b)):
                let beta = compare(a, b); if beta != 0 { return beta > 0 }
            default: break
            }
        }
        return a.count > b.count
    }
}

@MainActor @objc(XRGGraphWindow) @objcMembers
public final class XRGGraphWindow: NSWindow, XRGModuleWindow, XRGGPUViewHost, XRGMemoryViewHost,
    XRGNetViewHost, XRGBatteryViewHost, XRGCPUViewHost, XRGTemperatureViewHost, XRGStockViewHost,
    XRGDiskViewHost, XRGAITokenViewHost, XRGBackgroundViewHost, XRGWeatherViewHost, XRGNPUViewHost,
    XRGHardwareViewHost, XRGGraphicsSampleClock {
    private let defaults: UserDefaults
    private let wakeCenter: NotificationCenter
    private let scheduleTimers: Bool
    private let runtimeEnabled: Bool
    private let animateResizing: Bool
    private let makeUpdateURL: () -> XRGURL
    private let updateNotice: (String, String) -> XRGUpdateChoice
    private let openURL: (URL) -> Bool
    private let currentVersion: String
    private var runtimeStarted = false
    private var wakeObserver: (any NSObjectProtocol)?
    private var woke = false
    public var borderWidth: Int32 = 4 { didSet { if borderWidth < 0 { borderWidth = 0 } } }
    public var minimized = false
    public var min30Timer: Timer?
    public var min5Timer: Timer?
    public var graphTimer: Timer?
    public var fastTimer: Timer?
    public var fontManager: NSFontManager?
    @IBOutlet public var preferenceWindow: NSWindow?
    @IBOutlet public weak var controller: (any XRGGraphWindowController)?
    public var xrgCheckURL: XRGURL?
    public var appSettings: XRGSettings?
    public var moduleManager: XRGModuleManager?
    public var cpuView: XRGCPUView?
    public var gpuView: XRGGPUView?
    public var npuView: XRGNPUView?
    @nonobjc private(set) var vramView: XRGHardwareGraphView?
    @nonobjc private(set) var fansView: XRGHardwareGraphView?
    @nonobjc private(set) var graphicsSampleGeneration: UInt64 = 0
    public var netView: XRGNetView?
    public var diskView: XRGDiskView?
    public var memoryView: XRGMemoryView?
    public var weatherView: XRGWeatherView?
    public var stockView: XRGStockView?
    public var batteryView: XRGBatteryView?
    public var temperatureView: XRGTemperatureView?
    public var aiTokenView: XRGAITokenView?
    @IBOutlet public var backgroundView: XRGBackgroundView? {
        didSet {
            backgroundView?.setFrameSize(frame.size)
            backgroundView?.autoresizesSubviews = true
            backgroundView?.autoresizingMask = [.width, .height]
            backgroundView?.needsDisplay = true
        }
    }
    public var draggingWindow = false
    public var originAtDragStart = NSPoint.zero
    public var dragStart = NSPoint.zero

    public override init(contentRect: NSRect, styleMask: NSWindow.StyleMask, backing: NSWindow.BackingStoreType, defer flag: Bool) {
        defaults = .standard; wakeCenter = NSWorkspace.shared.notificationCenter; scheduleTimers = true
        runtimeEnabled = true; animateResizing = true; makeUpdateURL = { XRGURL() }
        updateNotice = Self.showUpdateNotice; openURL = { NSWorkspace.shared.open($0) }
        currentVersion = Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "0"
        super.init(contentRect: contentRect, styleMask: styleMask, backing: backing, defer: flag)
        prepare()
    }
    @nonobjc init(contentRect: NSRect, defaults: UserDefaults, center: NotificationCenter = NotificationCenter(),
                  scheduleTimers: Bool = false, runtimeEnabled: Bool = false,
                  makeUpdateURL: @escaping () -> XRGURL = { XRGURL() }, version: String = "2.0",
                  updateNotice: @escaping (String, String) -> XRGUpdateChoice = { _, _ in .notYet },
                  openURL: @escaping (URL) -> Bool = { _ in true }) {
        self.defaults = defaults; wakeCenter = center; self.scheduleTimers = scheduleTimers
        self.runtimeEnabled = runtimeEnabled; animateResizing = false; self.makeUpdateURL = makeUpdateURL
        self.updateNotice = updateNotice; self.openURL = openURL; currentVersion = version
        super.init(contentRect: contentRect, styleMask: .borderless, backing: .buffered, defer: false)
        isReleasedWhenClosed = false; prepare()
    }
    private func prepare() {
        defaults.register(defaults: Self.getDefaultPrefs() as? [String: Any] ?? [:])
        appSettings = XRGSettings(defaults: defaults)
        moduleManager = XRGModuleManager(window: self); fontManager = .shared
        isMovable = false; isMovableByWindowBackground = true
        setupSettingsFromDictionary(defaults.dictionaryRepresentation() as NSDictionary)
    }
    public nonisolated override func awakeFromNib() {
        super.awakeFromNib()
        MainActor.assumeIsolated { startRuntimeIfNeeded() }
    }
    /// Called again after all main-nib outlets are connected by the application delegate.
    public func startRuntimeIfNeeded() {
        guard runtimeEnabled, !runtimeStarted, controller != nil else { return }
        runtimeStarted = true
        wakeObserver = wakeCenter.addObserver(forName: NSWorkspace.didWakeNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.woke = true }
        }
        if appSettings?.checkForUpdates == true { checkServerForUpdates() }
    }
    isolated deinit {
        for timer in [min30Timer, min5Timer, graphTimer, fastTimer] { timer?.invalidate() }
        xrgCheckURL?.cancelLoading()
        if let wakeObserver { wakeCenter.removeObserver(wakeObserver) }
    }
    public static func getDefaultPrefs() -> NSMutableDictionary { XRGWindowPreferences.defaultPreferences() }
    public func setupSettingsFromDictionary(_ dictionary: NSDictionary) {
        guard let settings = appSettings else { return }
        let restored = XRGWindowPreferences.apply(dictionary, to: settings)
        borderWidth = restored.borderWidth
        backgroundColor = .clear; alphaValue = 0.99; isOpaque = false; hasShadow = settings.dropShadow
        // Orientation must be restored before minimum-size and module layout calculations.
        moduleManager?.graphOrientationVertical = restored.graphOrientationVertical
        if let manager = moduleManager { minSize = manager.getMinSize(); manager.windowChanged(to: frame.size) }
        setWindowLevelHelper(settings.windowLevel)
    }
    public func systemJustWokeUp() -> Bool { woke }
    public func setSystemJustWokeUp(_ value: Bool) { woke = value }
    public func systemDidWake(_ notification: Notification) { woke = true }

    public func checkServerForUpdates() {
        xrgCheckURL?.cancelLoading()
        let request = makeUpdateURL(); xrgCheckURL = request
        request.setURLString("https://raw.githubusercontent.com/sdelavega/XRG-ng/main/latest_version.txt")
        request.loadURLInBackground()
    }
    public func checkServerForUpdatesPostProcess() {
        guard let request = xrgCheckURL else { return }
        if request.didErrorOccur() { request.cancelLoading(); xrgCheckURL = nil; return }
        guard request.isDataReady() else { return }
        let latest = request.getData().flatMap { String(data: $0, encoding: .ascii) }?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        // Consume before showing an alert, so a nested run loop cannot show it twice.
        request.cancelLoading(); xrgCheckURL = nil
        guard isVersion(latest, laterThanVersion: currentVersion) else { return }
        switch updateNotice(latest, currentVersion) {
        case .moreInfo: _ = openURL(URL(string: "https://github.com/sdelavega/XRG-ng/releases")!)
        case .disable: appSettings?.checkForUpdates = false; defaults.set(false, forKey: "checkForUpdates")
        case .notYet: break
        }
    }
    public func isVersion(_ latest: String?, laterThanVersion current: String?) -> Bool {
        guard let latest, let current else { return false }
        return XRGWindowVersion.isLater(latest, than: current)
    }
    @nonobjc private static func showUpdateNotice(_ latest: String, _ current: String) -> XRGUpdateChoice {
        let alert = NSAlert(); alert.messageText = "Alert"
        alert.informativeText = "XRG-ng \(latest) is now available.  You are currently running XRG-ng \(current).  If you would like visit the XRG-ng website to upgrade, click More Info."
        for title in ["More Info", "Disable Checking", "Not Yet"] { alert.addButton(withTitle: title) }
        switch alert.runModal() {
        case .alertFirstButtonReturn: return .moreInfo
        case .alertSecondButtonReturn: return .disable
        default: return .notYet
        }
    }
    private func timer(_ interval: TimeInterval, _ selector: Selector) -> Timer {
        let timer = Timer(timeInterval: interval, repeats: true) { [weak self] timer in
            let alive = MainActor.assumeIsolated {
                guard let self else { return false }
                _ = self.perform(selector, with: nil)
                return true
            }
            if !alive { timer.invalidate() }
        }
        if scheduleTimers { RunLoop.main.add(timer, forMode: .default) }
        return timer
    }
    @nonobjc static func validRefresh(_ value: CGFloat?) -> TimeInterval {
        guard let value, value.isFinite, value > 0 else { return 1 }
        return Double(value)
    }
    public func initTimers() {
        if min30Timer?.isValid != true { min30Timer = timer(1800, #selector(min30Update(_:))) }
        if min5Timer?.isValid != true { min5Timer = timer(300, #selector(min5Update(_:))) }
        if graphTimer?.isValid != true { graphTimer = timer(Self.validRefresh(appSettings?.graphRefresh), #selector(graphUpdate(_:))) }
        if fastTimer?.isValid != true { fastTimer = timer(0.125, #selector(fastUpdate(_:))) }
    }
    public func min30Update(_ timer: Timer?) { moduleManager?.min30Update() }
    public func min5Update(_ timer: Timer?) { moduleManager?.min5Update() }
    public func graphUpdate(_ timer: Timer?) {
        graphicsSampleGeneration &+= 1
        moduleManager?.graphUpdate(); checkServerForUpdatesPostProcess()
    }
    public func fastUpdate(_ timer: Timer?) { moduleManager?.fastUpdate() }
    public func initializeAITokenView() {
        guard aiTokenView == nil else { return }
        let view = XRGAITokenView(frame: NSRect(x: 0, y: 0, width: 200, height: 100))
        aiTokenView = view; contentView?.addSubview(view); view.awakeFromNib()
        moduleManager?.windowChanged(to: frame.size)
    }
    public func initializeNPUView() {
        guard npuView == nil else { return }
        let view = XRGNPUView(frame: NSRect(x: 0, y: 0, width: 200, height: 100), miner: XRGNPUMiner(), settings: appSettings, defaults: defaults)
        npuView = view; contentView?.addSubview(view); view.awakeFromNib()
        moduleManager?.windowChanged(to: frame.size)
    }
    public func initializeHardwareViews() {
        initializeHardwareViews(vram: { [weak self] in
            guard let self, let gpu = self.gpuView else {
                return .failure(NSError(domain: "XRGGPU", code: 2, userInfo: [NSLocalizedDescriptionKey: "GPU collector unavailable"]))
            }
            return gpu.memoryReadings(tick: self.graphicsSampleGeneration)
        }, fans: { .success(XRGTemperatureMiner.shared.fanGraphReadings()) })
    }
    @nonobjc func initializeHardwareViews(vram: @escaping () -> Result<[XRGHardwareReading], Error>,
                                        fans: @escaping () -> Result<[XRGHardwareReading], Error>) {
        for (kind, source) in [(XRGHardwareGraphView.Kind.vram, vram), (.fans, fans)] {
            guard kind == .vram ? vramView == nil : fansView == nil else { continue }
            let view = XRGHardwareGraphView(kind: kind, frame: NSRect(x: 0, y: 0, width: 200, height: 100), settings: appSettings, defaults: defaults, source: source)
            if kind == .vram { vramView = view } else { fansView = view }
            contentView?.addSubview(view); view.awakeFromNib()
        }
        moduleManager?.windowChanged(to: frame.size)
    }
    public func showMemoryPreferences() { controller?.showPrefs(withPanel: "RAM") }
    public func showNetworkPreferences() { controller?.showPrefs(withPanel: "Network") }
    public func showCPUPreferences() { controller?.showPrefs(withPanel: "CPU") }
    public func showTemperaturePreferences() { controller?.showPrefs(withPanel: "Temperature") }
    public func showStockPreferences() { controller?.showPrefs(withPanel: "Stocks") }
    public func showDiskPreferences() { controller?.showPrefs(withPanel: "Disk") }
    public func showWeatherPreferences() { controller?.showPrefs(withPanel: "Weather") }
    public func showGeneralPreferences() { controller?.showPrefs(withPanel: "General") }
    public func showTemperatureSensors() { controller?.openSensorWindow(temperatureView) }
    public func backgroundThemeDidApply() { controller?.refreshGraphPalette(); moduleManager?.redisplayModules() }
    private func showModule(_ name: String, sender: Any?) {
        backgroundView?.expandWindow()
        moduleManager?.setModule(name, isDisplayed: Self.checked(sender))
        if let manager = moduleManager { minSize = manager.getMinSize(); checkWindowSize(); manager.windowChanged(to: frame.size) }
    }
    @IBAction public func setShowCPUGraph(_ sender: Any?) { showModule("CPU", sender: sender) }
    @IBAction public func setShowGPUGraph(_ sender: Any?) { showModule("GPU", sender: sender) }
    @IBAction public func setShowNPUGraph(_ sender: Any?) { showModule("NPU", sender: sender) }
    @IBAction public func setShowMemoryGraph(_ sender: Any?) { showModule("Memory", sender: sender) }
    @IBAction public func setShowBatteryGraph(_ sender: Any?) { showModule("Battery", sender: sender) }
    @IBAction public func setShowTemperatureGraph(_ sender: Any?) { showModule("Temperature", sender: sender) }
    @IBAction public func setShowAITokenGraph(_ sender: Any?) { showModule("AI Tokens", sender: sender) }
    @IBAction public func setShowNetGraph(_ sender: Any?) { showModule("Network", sender: sender) }
    @IBAction public func setShowDiskGraph(_ sender: Any?) { showModule("Disk", sender: sender) }
    @IBAction public func setShowWeatherGraph(_ sender: Any?) { showModule("Weather", sender: sender) }
    @IBAction public func setShowStockGraph(_ sender: Any?) { showModule("Stock", sender: sender) }
    private static func checked(_ sender: Any?) -> Bool { (sender as? NSButton)?.state == .on }
    private static func index(_ sender: Any?) -> Int? { (sender as? NSPopUpButton)?.indexOfSelectedItem }
    private static func row(_ sender: Any?) -> Int? { (sender as? NSMatrix)?.selectedRow }
    private static func text(_ sender: Any?) -> String? { (sender as? NSControl)?.stringValue }
    private func redraw() { contentView?.needsDisplay = true; for view in contentView?.subviews ?? [] { view.needsDisplay = true } }
    @IBAction public func setWindowTitle(_ sender: Any?) { guard let text = Self.text(sender) else { return }; appSettings?.windowTitle = text; backgroundView?.needsDisplay = true }
    @IBAction public func setBorderWidthAction(_ sender: Any?) {
        guard let control = sender as? NSControl else { return }
        backgroundView?.expandWindow(); borderWidth = max(0, control.intValue)
        if let manager = moduleManager { minSize = manager.getMinSize(); checkWindowSize(); manager.windowChanged(to: frame.size) }
    }
    @IBAction public func setGraphOrientation(_ sender: Any?) {
        guard let index = Self.index(sender), (0...1).contains(index), let manager = moduleManager else { return }
        let wasMinimized = minimized
        if wasMinimized { backgroundView?.expandWindow() }
        let vertical = index == 0
        if vertical != manager.graphOrientationVertical {
            manager.graphOrientationVertical = vertical
            let rotated = NSRect(x: frame.minX, y: frame.minY + frame.height - frame.width, width: frame.height, height: frame.width)
            minSize = manager.getMinSize(); setFrame(rotated, display: true, animate: animateResizing)
            manager.windowChanged(to: frame.size); backgroundView?.updateModuleLayout()
        }
        if wasMinimized { backgroundView?.minimizeWindow() }
        defaults.set(vertical, forKey: "graphOrientationVertical")
    }
    @IBAction public func setGraphRefreshActionPart2(_ sender: Any?) {
        guard let control = sender as? NSControl, control.doubleValue.isFinite, control.doubleValue > 0 else { return }
        let value = max(0.2, (control.doubleValue * 5).rounded() / 5)
        guard value.isFinite else { return }
        appSettings?.graphRefresh = value
        graphTimer?.invalidate(); graphTimer = timer(value, #selector(graphUpdate(_:)))
    }
    @IBAction public func setWindowLevel(_ sender: Any?) {
        guard let selected = Self.index(sender), (1...3).contains(selected) else { return }
        let value = selected - 1; appSettings?.windowLevel = value; setWindowLevelHelper(value)
    }
    public func setWindowLevelHelper(_ index: Int) {
        level = index == 0 ? .normal : index == 1 ? .floating : NSWindow.Level(rawValue: Int(CGWindowLevelForKey(.backstopMenu)))
    }
    @IBAction public func setAntiAliasing(_ sender: Any?) { guard sender is NSButton else { return }; appSettings?.antiAliasing = Self.checked(sender) }
    @IBAction public func setStickyWindow(_ sender: Any?) { guard sender is NSButton else { return }; appSettings?.stickyWindow = Self.checked(sender) }
    @IBAction public func setCheckForUpdates(_ sender: Any?) { guard sender is NSButton else { return }; appSettings?.checkForUpdates = Self.checked(sender) }
    @IBAction public func setDropShadow(_ sender: Any?) { guard sender is NSButton else { return }; appSettings?.dropShadow = Self.checked(sender); hasShadow = Self.checked(sender) }
    @IBAction public func setAutoExpandGraph(_ sender: Any?) { guard sender is NSButton else { return }; appSettings?.autoExpandGraph = Self.checked(sender) }
    @IBAction public func setForegroundWhenExpanding(_ sender: Any?) { guard sender is NSButton else { return }; appSettings?.foregroundWhenExpanding = Self.checked(sender) }
    @IBAction public func setShowSummary(_ sender: Any?) { guard sender is NSButton else { return }; appSettings?.showSummary = Self.checked(sender) }
    @IBAction public func setShowTotalBandwidthSinceBoot(_ sender: Any?) { guard sender is NSButton else { return }; appSettings?.showTotalBandwidthSinceBoot = Self.checked(sender) }
    @IBAction public func setShowTotalBandwidthSinceLoad(_ sender: Any?) { guard sender is NSButton else { return }; appSettings?.showTotalBandwidthSinceLoad = Self.checked(sender) }
    @IBAction public func setSeparateCPUColor(_ sender: Any?) { guard sender is NSButton else { return }; appSettings?.separateCPUColor = Self.checked(sender) }
    @IBAction public func setShowCPUTemperature(_ sender: Any?) { guard sender is NSButton else { return }; appSettings?.showCPUTemperature = Self.checked(sender) }
    @IBAction public func setStockShowChange(_ sender: Any?) { guard sender is NSButton else { return }; appSettings?.stockShowChange = Self.checked(sender); stockView?.needsDisplay = true }
    @IBAction public func setShowDJIA(_ sender: Any?) { guard sender is NSButton else { return }; appSettings?.showDJIA = Self.checked(sender); stockView?.needsDisplay = true }
    @IBAction public func setShowLoadAverage(_ sender: Any?) { guard sender is NSButton else { return }; appSettings?.showLoadAverage = Self.checked(sender); cpuView?.graphUpdate(nil) }
    @IBAction public func setCPUShowAverageUsage(_ sender: Any?) { guard sender is NSButton else { return }; appSettings?.cpuShowAverageUsage = Self.checked(sender); cpuView?.graphUpdate(nil) }
    @IBAction public func setCPUShowUptime(_ sender: Any?) { guard sender is NSButton else { return }; appSettings?.cpuShowUptime = Self.checked(sender); cpuView?.graphUpdate(nil) }
    @IBAction public func setFastCPUUsageCheckbox(_ sender: Any?) {
        guard sender is NSButton else { return }
        appSettings?.fastCPUUsage = Self.checked(sender)
        if let width = moduleManager?.getModule(byName: "CPU")?.currentSize.width, width.isFinite { cpuView?.setWidth(Int(min(20_000, max(0, width)))) }
        cpuView?.needsDisplay = true
    }
    @IBAction public func setObjectsToColor(_ sender: Any?) {
        guard let well = sender as? NSColorWell, let key = Self.colorKeys[well.tag] else { return }
        appSettings?.setValue(well.color, forKey: key + "Color"); redraw()
    }
    @IBAction public func setObjectsToTransparency(_ sender: Any?) {
        guard let control = sender as? NSControl, let key = Self.colorKeys[control.tag], control.doubleValue.isFinite else { return }
        appSettings?.setValue(min(1, max(0, control.doubleValue)), forKey: key + "Transparency"); redraw()
    }
    private static let colorKeys = [21: "background", 22: "graphBG", 23: "graphFG1", 24: "graphFG2", 25: "graphFG3", 26: "border", 27: "text"]
    public func colorForTag(_ tag: Int) -> NSColor? { Self.colorKeys[tag].flatMap { appSettings?.value(forKey: $0 + "Color") as? NSColor } }
    public func transparencyForTag(_ tag: Int) -> Float { Self.colorKeys[tag].flatMap { appSettings?.value(forKey: $0 + "Transparency") as? NSNumber }?.floatValue ?? 1 }
    @IBAction public func setGraphStyle(_ sender: Any?) { guard let value = Self.index(sender), (0...3).contains(value) else { return }; appSettings?.graphStyle = value; redraw() }
    @IBAction public func setMemoryCheckbox(_ sender: Any?) {
        guard let button = sender as? NSButton else { return }
        let keys = [42: "memoryShowWired", 43: "memoryShowActive", 44: "memoryShowInactive", 45: "memoryShowFree", 46: "memoryShowCache", 47: "memoryShowPage", 48: "showMemoryPagingGraph"]
        guard let key = keys[button.tag] else { return }
        appSettings?.setValue(Self.checked(button), forKey: key); memoryView?.needsDisplay = true
    }
    @IBAction public func setCPUTemperatureUnits(_ sender: Any?) { guard let value = Self.index(sender), (0...1).contains(value) else { return }; appSettings?.cpuTemperatureUnits = value }
    @IBAction public func setMinimizeUpDown(_ sender: Any?) { guard let value = Self.index(sender), (0...1).contains(value) else { return }; appSettings?.minimizeUpDown = value }
    @IBAction public func setTempUnits(_ sender: Any?) { guard let raw = Self.index(sender), let units = XRGTemperatureUnits(rawValue: raw) else { return }; appSettings?.tempUnits = units; temperatureView?.needsDisplay = true }
    @IBAction public func setTempFG1Location(_ sender: NSMenuItem) { guard let key = sender.representedObject as? String else { return }; appSettings?.tempFG1Location = key; temperatureView?.needsDisplay = true }
    @IBAction public func setTempFG2Location(_ sender: NSMenuItem) { guard let key = sender.representedObject as? String else { return }; appSettings?.tempFG2Location = key; temperatureView?.needsDisplay = true }
    @IBAction public func setTempFG3Location(_ sender: NSMenuItem) { guard let key = sender.representedObject as? String else { return }; appSettings?.tempFG3Location = key; temperatureView?.needsDisplay = true }
    @IBAction public func setNetGraphMode(_ sender: Any?) { guard let value = Self.row(sender), (0...2).contains(value) else { return }; appSettings?.netGraphMode = value; netView?.needsDisplay = true }
    @IBAction public func setDiskGraphMode(_ sender: Any?) { guard let value = Self.row(sender), (0...2).contains(value) else { return }; appSettings?.diskGraphMode = value; diskView?.needsDisplay = true }
    @IBAction public func setNetworkInterface(_ sender: Any?) {
        guard let index = Self.index(sender), index >= 0 else { return }
        let interfaces = netView?.miner.networkInterfaces() ?? []
        appSettings?.networkInterface = index > 0 && index - 1 < interfaces.count ? interfaces[index - 1] : "All"
    }
    @IBAction public func setICAO(_ sender: Any?) { guard let value = Self.text(sender) else { return }; appSettings?.ICAO = value; weatherView?.setURL(value); weatherView?.min30Update(nil) }
    @IBAction public func setStockSymbols(_ sender: Any?) { guard let value = Self.text(sender) else { return }; appSettings?.stockSymbols = value; stockView?.setStockSymbolsFromString(value) }
    @IBAction public func setSecondaryWeatherGraph(_ sender: Any?) { guard let value = Self.index(sender), (0...5).contains(value) else { return }; appSettings?.secondaryWeatherGraph = value; weatherView?.needsDisplay = true }
    @IBAction public func setTemperatureUnits(_ sender: Any?) { guard let value = Self.index(sender), (0...1).contains(value) else { return }; appSettings?.temperatureUnits = value; weatherView?.needsDisplay = true }
    @IBAction public func setDistanceUnits(_ sender: Any?) { guard let value = Self.index(sender), (0...1).contains(value) else { return }; appSettings?.distanceUnits = value; weatherView?.needsDisplay = true }
    @IBAction public func setPressureUnits(_ sender: Any?) { guard let value = Self.index(sender), (0...1).contains(value) else { return }; appSettings?.pressureUnits = value; weatherView?.needsDisplay = true }
    @IBAction public func setStockGraphTimeFrame(_ sender: Any?) { guard let value = Self.index(sender), (0...3).contains(value) else { return }; appSettings?.stockGraphTimeFrame = value; stockView?.needsDisplay = true }
    public func checkWindowSize() {
        guard let manager = moduleManager else { return }
        let minimum = manager.getMinSize()
        guard frame.width < minimum.width || frame.height < minimum.height else { return }
        var expanded = frame; expanded.size.width = max(frame.width, minimum.width); expanded.size.height = max(frame.height, minimum.height)
        minSize = minimum; setFrame(expanded, display: true, animate: animateResizing); manager.windowChanged(to: frame.size)
    }
    public override var canBecomeKey: Bool { true }
    public override var isMovableByWindowBackground: Bool {
        get { true }
        set { super.isMovableByWindowBackground = newValue }
    }
    public override func performClose(_ sender: Any?) { if delegate?.windowShouldClose?(self) ?? true { close() } }
    public override func performMiniaturize(_ sender: Any?) { miniaturize(nil) }
    public override func setFrame(_ frame: NSRect, display: Bool, animate: Bool) {
        super.setFrame(frame, display: display, animate: animate && animateResizing)
        moduleManager?.windowChanged(to: self.frame.size)
    }
    public func windowDidResize(_ notification: Notification) { moduleManager?.windowChanged(to: frame.size) }
    public func cleanupBeforeExiting() {
        let wasMinimized = defaults.bool(forKey: "windowIsMinimized")
        backgroundView?.expandWindow(); defaults.set(wasMinimized, forKey: "windowIsMinimized")
        for timer in [min30Timer, min5Timer, graphTimer, fastTimer] { timer?.invalidate() }
        min30Timer = nil; min5Timer = nil; graphTimer = nil; fastTimer = nil
        xrgCheckURL?.cancelLoading(); xrgCheckURL = nil
        weatherView?.cancelLoading()
        aiTokenView?.suspendCollection()
        if let wakeObserver { wakeCenter.removeObserver(wakeObserver) }
        wakeObserver = nil; runtimeStarted = false
    }
    public override func mouseDown(with event: NSEvent) { backgroundView?.mouseDownAction(event); super.mouseDown(with: event) }
    public override func sendEvent(_ event: NSEvent) {
        handleWindowDrag(event)
        super.sendEvent(event)
    }
    @nonobjc func handleWindowDrag(_ event: NSEvent) {
        switch event.type {
        case .leftMouseDown:
            if let bounds = contentView?.bounds, bounds.insetBy(dx: CGFloat(borderWidth), dy: CGFloat(borderWidth)).contains(event.locationInWindow) {
                draggingWindow = true; dragStart = convertToScreen(NSRect(origin: event.locationInWindow, size: .zero)).origin; originAtDragStart = frame.origin
            } else { draggingWindow = false }
        case .leftMouseDragged:
            guard draggingWindow else { return }
            let point = convertToScreen(NSRect(origin: event.locationInWindow, size: .zero)).origin
            let origin = NSPoint(x: originAtDragStart.x + point.x - dragStart.x, y: originAtDragStart.y + point.y - dragStart.y)
            setFrameOrigin(snap(origin))
        case .leftMouseUp: draggingWindow = false
        default: break
        }
    }
    public func snap(_ point: NSPoint) -> NSPoint {
        guard appSettings?.stickyWindow == true else { return point }
        return Self.snap(point, size: contentView?.bounds.size ?? frame.size, screens: NSScreen.screens.map(\.frame), currentScreen: screen?.frame)
    }
    @nonobjc static func snap(_ point: NSPoint, size: NSSize, screens: [NSRect], currentScreen: NSRect?) -> NSPoint {
        guard point.x.isFinite, point.y.isFinite, size.width.isFinite, size.height.isFinite else { return point }
        var rect = NSRect(origin: point, size: size)
        let center = NSPoint(x: rect.midX, y: rect.midY)
        guard let screen = screens.last(where: { $0.contains(center) }) ?? currentScreen else { return point }
        var horizontal = false, vertical = false
        if screen.maxY - rect.maxY <= 20 { rect.origin.y = screen.maxY - rect.height; vertical = true }
        if rect.minX - screen.minX <= 20 { rect.origin.x = screen.minX; horizontal = true }
        if rect.minY - screen.minY <= 20 { rect.origin.y = screen.minY; vertical = true }
        if screen.maxX - rect.maxX <= 20 { rect.origin.x = screen.maxX - rect.width; horizontal = true }
        if vertical && abs(rect.midX - screen.midX) <= 20 { rect.origin.x = screen.midX - rect.width * 0.5 }
        if horizontal && abs(rect.midY - screen.midY) <= 20 { rect.origin.y = screen.midY - rect.height * 0.5 }
        return rect.origin
    }
}
