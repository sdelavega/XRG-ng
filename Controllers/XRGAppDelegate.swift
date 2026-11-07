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
import Sparkle
import XRGCore

@MainActor
@objc(XRGAppDelegate)
@objcMembers
final class XRGAppDelegate: NSObject, NSApplicationDelegate, NSWindowDelegate, XRGSensorWindowDataSource, XRGGraphWindowController {
    private let budgetNotifications: XRGAIBudgetNotifications?
    private let defaults: UserDefaults
    private let loadNib: (String, XRGAppDelegate) -> Void
    private let presentWindow: (NSWindow, Any?) -> Void
    private let activateApplication: () -> Void
    private let sensorProvider: (Bool) -> [XRGSensorData]
    /// The sensor window's unknown-sensor policy. The default resolves the
    /// active graph window's settings store — the shared document in the
    /// shipping app, an injected suite in a fixture scene — so document
    /// changes control the shipping sensor UI (review issue 6); fixtures
    /// keep their injected closures.
    private var includeUnknownSensors: () -> Bool = { false }
    private let invalidThemeNotice: (Error) -> Void
    private var updater: XRGUpdater?

    override convenience init() {
        self.init(defaults: .standard, budgetNotifications: XRGAIBudgetNotifications(),
                  loadNib: { name, owner in _ = Bundle.main.loadNibNamed(NSNib.Name(name), owner: owner, topLevelObjects: nil) },
                  presentWindow: { $0.makeKeyAndOrderFront($1) },
                  activateApplication: {
                      NSRunningApplication.runningApplications(withBundleIdentifier: "com.apple.dock").first?.activate(options: [])
                      DispatchQueue.main.async { NSApp.activate() }
                  }, sensorProvider: { includingUnknown in
                      let miner = XRGTemperatureMiner.shared
                      return miner.locationKeys(includingUnknown: includingUnknown).compactMap { miner.sensor(forLocation: $0) }
                  }, invalidThemeNotice: { error in
                      let alert = NSAlert()
                      alert.messageText = NSLocalizedString("Unable to Load Theme", comment: "Invalid theme alert title")
                      alert.informativeText = error.localizedDescription
                      alert.addButton(withTitle: NSLocalizedString("OK", comment: "Dismiss alert"))
                      alert.runModal()
                  })
    }

    @nonobjc init(defaults: UserDefaults, budgetNotifications: XRGAIBudgetNotifications? = nil, loadNib: @escaping (String, XRGAppDelegate) -> Void,
                  presentWindow: @escaping (NSWindow, Any?) -> Void = { _, _ in },
                  activateApplication: @escaping () -> Void = {},
                  includeUnknownSensors: (() -> Bool)? = nil,
                  sensorProvider: @escaping (Bool) -> [XRGSensorData] = { _ in [] },
                  invalidThemeNotice: @escaping (Error) -> Void = { _ in }) {
        self.budgetNotifications = budgetNotifications
        self.defaults = defaults; self.loadNib = loadNib; self.presentWindow = presentWindow
        self.activateApplication = activateApplication; self.sensorProvider = sensorProvider
        self.invalidThemeNotice = invalidThemeNotice
        super.init()
        self.includeUnknownSensors = includeUnknownSensors ?? { [weak self] in
            XRGTemperatureView.showUnknownSensors(XRGTemperatureView.policyStore(of: self?.xrgGraphWindow))
        }
    }

    @IBOutlet var xrgGraphWindow: XRGGraphWindow?
    @IBOutlet var sensorWindow: NSWindow?
    @IBOutlet var sensorViewController: XRGSensorViewController?

    var appSettings: XRGSettings? { xrgGraphWindow?.appSettings }
    var moduleManager: XRGModuleManager? { xrgGraphWindow?.moduleManager }

    var sensorWindowIncludesUnknownSensors: Bool { includeUnknownSensors() }

    func sensorWindowSensors(includingUnknown: Bool) -> [XRGSensorData] {
        sensorProvider(includingUnknown)
    }

    // MARK: Settings window (0.2.3: replaces the Preferences nib)

    /// The Aether7b settings window, built lazily on first use.
    public private(set) var settingsWindowController: XRGSettingsWindowController?

    @IBAction func showPrefs(_ sender: Any?) {
        showSettings(section: "general")
    }

    /// Open the settings window on one catalog section: renders it and
    /// presents the window through the injectable presentation seam.
    public func showSettings(section: String, sender: Any? = nil) {
        if settingsWindowController == nil {
            let store = xrgGraphWindow?.appSettings?.store ?? XRGSettingsStore.shared
            let provider = XRGHardwareSettingsSourceProvider()
            // The retained unknown-sensor policy drives the temperature
            // pickers, exactly as it drives the sensor window (review
            // issue 5).
            provider.includeUnknownSensors = { [weak self] in
                XRGTemperatureView.showUnknownSensors(XRGTemperatureView.policyStore(of: self?.xrgGraphWindow))
            }
            let controller = XRGSettingsWindowController(store: store,
                                                           catalog: store.catalog,
                                                           sources: provider)
            controller.performCheckForUpdates = { [weak self] in self?.updater?.checkForUpdates(nil) }
            controller.requestBudgetNotifications = { [weak self] in
                guard let self, let budgetNotifications = self.budgetNotifications else {
                    return await XRGAIBudgetNotifications.requestPermission()
                }
                return await XRGAIBudgetNotifications.requestPermission()
            }
            controller.graphFontChanged = { [weak self] in self?.moduleManager?.graphFontChanged() }
            settingsWindowController = controller
        }
        settingsWindowController?.show(section: section)
        if let window = settingsWindowController?.window { presentWindow(window, sender) }
    }

    /// The panel names the old Preferences toolbar used, routed to the new
    /// window's sections (openAIPreferences and the AI menu item).
    @objc(showPrefsWithPanel:)
    func showPrefs(withPanel panelName: String) {
        showSettings(section: Self.section(forPanel: panelName))
    }

    static func section(forPanel panelName: String) -> String {
        switch panelName.lowercased() {
        case "general": return "general"
        case "appearance", "color": return "appearance"
        case "cpu": return "graphs"
        case "ram", "memory": return "graphs"
        case "temperature": return "sources"
        case "network": return "graphs"
        case "disk": return "graphs"
        case "weather": return "weather"
        case "stock", "stocks": return "stocks"
        case "ai": return "ai"
        default: return "general"
        }
    }

    @IBAction func openAIPreferences(_ sender: Any?) {
        showPrefs(withPanel: "AI")
    }

    @IBAction func openSensorWindow(_ sender: Any?) {
        if sensorViewController == nil {
            loadNib("Sensors", self)
        }
        if sensorViewController?.dataSource == nil { sensorViewController?.dataSource = self }
        sensorWindow?.level = .normal
        if let window = sensorWindow { presentWindow(window, self) }
        appSettings?.sensorsWindowOpen = true
    }

    func windowShouldClose(_ sender: NSWindow) -> Bool {
        if sender === sensorWindow {
            appSettings?.sensorsWindowOpen = false
        }
        return true
    }

    @IBAction func changeFont(_ sender: Any?) {
        guard let manager = sender as? NSFontManager,
              let settings = appSettings, let oldFont = settings.graphFont else { return }
        let newFont = manager.convert(oldFont)
        guard newFont != oldFont else { return }
        settings.graphFont = newFont
        moduleManager?.graphFontChanged()
    }

    @objc(NSWorkSpaceWillPowerOffNotification:)
    func workspaceWillPowerOff(_ notification: Notification) {
        xrgGraphWindow?.cleanupBeforeExiting()
    }

    func refreshGraphPalette() { settingsWindowController?.refresh() }

    /// The launch restoration: re-collapse the graph window if it was
    /// collapsed (restoring the expanded dimensions first, preserving the
    /// fork's fix for relaunches that otherwise get stuck as a thin strip)
    /// and reopen the sensors window if it was open. Extracted from
    /// `applicationDidFinishLaunching` so the document store's
    /// byte-for-byte quietness — these paths only re-assert what the
    /// document already says, so settings.json is never rewritten by a
    /// launch, restore or shutdown — is testable without a running app
    /// (fix round 2, finding 3).
    func restoreLaunchState() {
        guard let window = xrgGraphWindow else { return }
        if window.appSettings?.windowCollapsed == true {
            let collapsedLimit = (2 * CGFloat(window.borderWidth)) + (window.appSettings?.textRectHeight ?? 0) + 1
            if let savedFrame = defaults.string(forKey: "unminimizedFrame") {
                let saved = NSRectFromString(savedFrame)
                if saved.height > collapsedLimit && saved.width > collapsedLimit {
                    var frame = window.frame
                    frame.size = saved.size
                    window.setFrame(frame, display: false)
                }
            }
            if let background = window.backgroundView {
                background.minimizeWindow()
                background.clickedMinimized = true
            }
        }
        if window.appSettings?.sensorsWindowOpen == true {
            openSensorWindow(self)
        }
    }

    /// Follow the settings store: every stored change (the settings window's
    /// instant apply, a theme import, a section reset) reconciles the live
    /// window and module manager with the store — visibility, orientation,
    /// border width, window level, shadow, title and the layout-affecting
    /// graph settings (heights and the order). The relayout is skipped
    /// entirely when nothing layout-affecting changed (launch re-asserts
    /// state through the same notification; it must not pay for a
    /// relayout), modules that are not registered are skipped explicitly
    /// (an absent module is not a hidden one), and the module sizes the
    /// relayout persists in return are layout FEEDBACK, never layout
    /// input. Re-entrant notifications are ignored (review issue 1).
    private var syncingPresentation = false
    @objc func settingsStoreChanged(_ note: Notification) {
        syncGraphPresentationFromStore(changedID: note.userInfo?["id"] as? String)
    }
    func syncGraphPresentationFromStore(changedID: String? = nil) {
        guard !syncingPresentation else { return }
        syncingPresentation = true
        defer { syncingPresentation = false }
        guard let window = xrgGraphWindow, let manager = window.moduleManager, let settings = window.appSettings else { return }
        // The module sizes a relayout writes back are feedback, not input:
        // they must never trigger another pass.
        if let changedID, changedID.hasSuffix(".size_width") || changedID.hasSuffix(".size_height") { return }
        let store = settings.store
        var layoutChanged = false
        for graph in XRGGraphID.allCases {
            guard let module = manager.getModule(byName: graph.name) else { continue }
            let visible = settings.moduleVisible(graph)
            if module.isDisplayed != visible {
                manager.setModule(graph.name, isDisplayed: visible)
                layoutChanged = true
            }
        }
        // Live presentation the old preference actions set explicitly.
        let vertical = store.value("general.window.orientation") != .string("horizontal")
        if manager.graphOrientationVertical != vertical {
            window.applyGraphOrientation(vertical: vertical)
            layoutChanged = true
        }
        let border = store.intSetting("general.window.border_width")
        if window.borderWidth != border {
            if window.minimized { window.backgroundView?.expandWindow() }
            window.borderWidth = Int32(max(0, border))
            layoutChanged = true
        }
        if changedID == nil || changedID == "general.window.level" {
            let level = { if case .string(let name) = store.settingsValue("general.window.level") { return name }; return "normal" }()
            window.setWindowLevelHelper(["normal", "floating", "background"].firstIndex(of: level) ?? 0)
        }
        if changedID == nil || changedID == "general.window.drop_shadow" {
            window.hasShadow = store.boolSetting("general.window.drop_shadow")
        }
        if changedID == nil || changedID == "general.window.title" {
            window.backgroundView?.needsDisplay = true
        }
        // Heights and the order only change the layout; colour, style and
        // effect changes only need a redraw (the views read them live).
        if let changedID {
            if changedID == "graphs.order" || changedID.hasSuffix(".height") { layoutChanged = true }
            if changedID.hasPrefix("appearance.")
                || (changedID.hasPrefix("graphs.") && (changedID.contains(".color.") || changedID.hasSuffix(".style") || changedID.hasSuffix(".effect"))) {
                manager.redisplayModules()
            }
        } else {
            layoutChanged = true
        }
        if layoutChanged { manager.presentationChanged() }
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        guard let window = xrgGraphWindow else { return }
        if let settings = window.appSettings {
            NotificationCenter.default.addObserver(
                self, selector: #selector(settingsStoreChanged(_:)),
                name: XRGSettingsStore.didChange, object: settings.store)
        }
        // The AI token observer is not main-actor confined; hand it the
        // shared document store before any accounting can start. A test
        // scene's injected suite keeps the observer on that suite.
        if defaults === UserDefaults.standard, Bundle.main.bundleIdentifier == "com.sdelavega.xrg" {
            XRGAITokensObserver.adoptStore(XRGSettingsStore.shared)
        }
        budgetNotifications?.installNativeDelegate()
        budgetNotifications?.start()
        window.startRuntimeIfNeeded()
        window.moduleManager?.windowChanged(to: window.frame.size)
        window.initializeNPUView()
        window.initializeAITokenView()
        window.initializeHardwareViews()
        restoreLaunchState()

        // Preserve the existing launch ordering until menu activation is
        // verified independently of the language migration.
        activateApplication()

        // Sparkle owns update checks from 0.2.1 on (replacing the legacy
        // XRGURL server probe). The updater is created unstarted so unhosted
        // test processes and disposable bundle copies never run checks or
        // present Sparkle's automatic-checks prompt; the shipping bundle then
        // starts the standard updater, which asks the user itself.
        let updater = XRGUpdater(startingUpdater: false)
        self.updater = updater
        if let appMenu = NSApp.mainMenu?.items.first?.submenu {
            _ = XRGUpdater.insertCheckForUpdatesItem(into: appMenu, target: updater)
        }
        if Bundle.main.bundleIdentifier == "com.sdelavega.xrg" {
            updater.controller.startUpdater()
        }

        // 0.2.1: "Support XRG-ng…" links the Help menu to GitHub Sponsors.
        // A host without any Help menu simply skips the insertion.
        if let helpMenu = XRGSupportLink.helpMenu() {
            _ = XRGSupportLink.insert(into: helpMenu, target: self, action: #selector(openSponsors(_:)))
        }
    }

    /// Opens the GitHub Sponsors page from the Help menu's "Support XRG-ng…" item.
    @IBAction func openSponsors(_ sender: Any?) {
        NSWorkspace.shared.open(XRGSupportLink.url)
    }

    func applicationWillTerminate(_ notification: Notification) {
        budgetNotifications?.stop()
        xrgGraphWindow?.cleanupBeforeExiting()
    }

    func application(_ sender: NSApplication, openFile filename: String) -> Bool {
        guard !filename.isEmpty, let settings = appSettings else { return false }
        do {
            try settings.loadTheme(from: URL(fileURLWithPath: filename), defaults: defaults)
            xrgGraphWindow?.display()
            refreshGraphPalette()
            return true
        } catch {
            invalidThemeNotice(error)
            return false
        }
    }
}
