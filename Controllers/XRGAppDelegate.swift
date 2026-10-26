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
import XRGCore

@MainActor
@objc(XRGAppDelegate)
@objcMembers
final class XRGAppDelegate: NSObject, NSApplicationDelegate, NSWindowDelegate, XRGSensorWindowDataSource, XRGGraphWindowController, XRGPreferencesDataSource {
    @IBOutlet var prefController: XRGPrefController?
    @IBOutlet var xrgGraphWindow: XRGGraphWindow?
    @IBOutlet var sensorWindow: NSWindow?
    @IBOutlet var sensorViewController: XRGSensorViewController?

    var appSettings: XRGSettings? { xrgGraphWindow?.appSettings }
    var moduleManager: XRGModuleManager? { xrgGraphWindow?.moduleManager }

    var sensorWindowIncludesUnknownSensors: Bool { XRGTemperatureView.showUnknownSensors() }

    func sensorWindowSensors(includingUnknown: Bool) -> [XRGSensorData] {
        let miner = XRGTemperatureMiner.shared
        return miner.locationKeys(includingUnknown: includingUnknown).compactMap { miner.sensor(forLocation: $0) }
    }

    @IBAction func showPrefs(_ sender: Any?) {
        if prefController == nil {
            Bundle.main.loadNibNamed("Preferences", owner: self, topLevelObjects: nil)
        }
        prefController?.setUpTemperaturePanel()
        prefController?.window?.makeKeyAndOrderFront(sender)
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
            Bundle.main.loadNibNamed("Sensors", owner: self, topLevelObjects: nil)
        }
        sensorWindow?.level = .normal
        sensorWindow?.makeKeyAndOrderFront(self)
        UserDefaults.standard.set(true, forKey: "showSensorWindow")
    }

    func windowShouldClose(_ sender: NSWindow) -> Bool {
        if sender === sensorWindow {
            UserDefaults.standard.set(false, forKey: "showSensorWindow")
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
        window.startRuntimeIfNeeded()
        window.moduleManager?.windowChanged(to: window.frame.size)
        window.initializeAITokenView()

        let defaults = UserDefaults.standard
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
        NSRunningApplication.runningApplications(withBundleIdentifier: "com.apple.dock")
            .first?.activate(options: [])
        DispatchQueue.main.async { NSApp.activate() }
    }

    func applicationWillTerminate(_ notification: Notification) {
        xrgGraphWindow?.cleanupBeforeExiting()
    }

    func application(_ sender: NSApplication, openFile filename: String) -> Bool {
        guard !filename.isEmpty, let settings = appSettings else { return false }
        do {
            let data = try Data(contentsOf: URL(fileURLWithPath: filename))
            let plist = try PropertyListSerialization.propertyList(from: data, options: [], format: nil)
            try settings.applyThemeDictionary(plist, defaults: .standard)
            xrgGraphWindow?.display()
            prefController?.setUpColorPanel()
            return true
        } catch {
            let alert = NSAlert()
            alert.messageText = NSLocalizedString("Unable to Load Theme", comment: "Invalid theme alert title")
            alert.informativeText = error.localizedDescription
            alert.addButton(withTitle: NSLocalizedString("OK", comment: "Dismiss alert"))
            alert.runModal()
            return false
        }
    }
}
