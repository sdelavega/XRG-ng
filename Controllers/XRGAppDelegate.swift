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
final class XRGAppDelegate: NSObject, NSApplicationDelegate, NSWindowDelegate, XRGSensorWindowDataSource, XRGGraphWindowController, XRGPreferencesDataSource {
    private let budgetNotifications: XRGAIBudgetNotifications?
    private let defaults: UserDefaults
    private let loadNib: (String, XRGAppDelegate) -> Void
    private let presentWindow: (NSWindow, Any?) -> Void
    private let activateApplication: () -> Void
    private let sensorProvider: (Bool) -> [XRGSensorData]
    private let includeUnknownSensors: () -> Bool
    private let invalidThemeNotice: (Error) -> Void
    private var updater: XRGUpdater?

    override convenience init() {
        self.init(defaults: .standard, budgetNotifications: XRGAIBudgetNotifications(),
                  loadNib: { name, owner in _ = Bundle.main.loadNibNamed(NSNib.Name(name), owner: owner, topLevelObjects: nil) },
                  presentWindow: { $0.makeKeyAndOrderFront($1) },
                  activateApplication: {
                      NSRunningApplication.runningApplications(withBundleIdentifier: "com.apple.dock").first?.activate(options: [])
                      DispatchQueue.main.async { NSApp.activate() }
                  }, includeUnknownSensors: { XRGTemperatureView.showUnknownSensors() }, sensorProvider: { includingUnknown in
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
        self.includeUnknownSensors = includeUnknownSensors ?? { defaults.bool(forKey: "tempShowUnknownSensors") }
        self.invalidThemeNotice = invalidThemeNotice
        super.init()
    }

    @IBOutlet var prefController: XRGPrefController?
    @IBOutlet var xrgGraphWindow: XRGGraphWindow?
    @IBOutlet var sensorWindow: NSWindow?
    @IBOutlet var sensorViewController: XRGSensorViewController?

    var appSettings: XRGSettings? { xrgGraphWindow?.appSettings }
    var moduleManager: XRGModuleManager? { xrgGraphWindow?.moduleManager }

    var sensorWindowIncludesUnknownSensors: Bool { includeUnknownSensors() }

    func sensorWindowSensors(includingUnknown: Bool) -> [XRGSensorData] {
        sensorProvider(includingUnknown)
    }

    @IBAction func showPrefs(_ sender: Any?) {
        if prefController == nil {
            loadNib("Preferences", self)
        }
        prefController?.setUpTemperaturePanel()
        if let window = prefController?.window { presentWindow(window, sender) }
    }

    @objc(showPrefsWithPanel:)
    func showPrefs(withPanel panelName: String) {
        showPrefs(self)
        prefController?.selectPanel(named: panelName)
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
        defaults.set(true, forKey: "showSensorWindow")
    }

    func windowShouldClose(_ sender: NSWindow) -> Bool {
        if sender === sensorWindow {
            defaults.set(false, forKey: "showSensorWindow")
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

    func refreshGraphPalette() { prefController?.setUpColorPanel() }

    func applicationDidFinishLaunching(_ notification: Notification) {
        guard let window = xrgGraphWindow else { return }
        budgetNotifications?.installNativeDelegate()
        budgetNotifications?.start()
        window.startRuntimeIfNeeded()
        window.moduleManager?.windowChanged(to: window.frame.size)
        window.initializeNPUView()
        window.initializeAITokenView()
        window.initializeHardwareViews()

        if defaults.bool(forKey: "windowIsMinimized") {
            // Restore the expanded dimensions before collapsing, preserving the
            // fork's fix for relaunches that otherwise get stuck as a thin strip.
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
        if defaults.bool(forKey: "showSensorWindow") {
            openSensorWindow(self)
        }

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
            prefController?.setUpColorPanel()
            return true
        } catch {
            invalidThemeNotice(error)
            return false
        }
    }
}
