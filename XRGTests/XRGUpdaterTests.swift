// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Stephen de la Vega.
// Sparkle update wiring: menu item placement, the shipping update feed and
// the 0.1.0 upgrade promise (existing preferences survive, Sparkle asks the
// user about automatic checks itself).
import AppKit
import Sparkle
import Testing
@testable import XRGCore

@Suite(.serialized) @MainActor
struct XRGUpdaterTests {
    /// The MainMenu nib's application menu shape: About, separator, Preferences.
    private func applicationMenu() -> NSMenu {
        let menu = NSMenu()
        menu.addItem(NSMenuItem(title: "About XRG-ng", action: nil, keyEquivalent: ""))
        menu.addItem(NSMenuItem.separator())
        menu.addItem(NSMenuItem(title: "Preferences…", action: nil, keyEquivalent: ""))
        return menu
    }

    @Test func insertsCheckForUpdatesDirectlyAfterAbout() throws {
        let menu = applicationMenu()
        let updater = XRGUpdater(startingUpdater: false)
        let item = XRGUpdater.insertCheckForUpdatesItem(into: menu, target: updater)
        let placed = try #require(menu.item(at: 1))
        #expect(placed === item)
        #expect(item.title == "Check for Updates…")
        #expect(item.action == Selector("checkForUpdates:"))
        #expect(item.target === updater)
        #expect(menu.items.first?.title == "About XRG-ng")
        #expect(menu.items[2].isSeparatorItem && menu.items[3].title == "Preferences…")
    }

    @Test func insertionIsIdempotent() throws {
        let menu = applicationMenu()
        let updater = XRGUpdater(startingUpdater: false)
        let first = XRGUpdater.insertCheckForUpdatesItem(into: menu, target: updater)
        let second = XRGUpdater.insertCheckForUpdatesItem(into: menu, target: updater)
        #expect(first === second)
        XRGUpdater.insertAppMenuItem(first, after: 0, in: menu)
        #expect(menu.items.filter { $0.action == Selector("checkForUpdates:") }.count == 1)
        #expect(menu.items.filter { $0 === first }.count == 1)
        #expect(menu.items[1] === first && menu.items.count == 4)
    }

    @Test func infoPlistDeclaresFeedAndKey() throws {
        // XRG-Info.plist is the shipping app's Info.plist; read it from the
        // source tree so the declaration is verified without a built app bundle.
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
        let data = try Data(contentsOf: root.appendingPathComponent("XRG-Info.plist"))
        let plist = try #require(try PropertyListSerialization.propertyList(from: data, options: [], format: nil) as? [String: Any])
        #expect(plist["SUFeedURL"] as? String == "https://sdelavega.github.io/XRG-ng/appcast.xml")
        #expect((plist["SUPublicEDKey"] as? String ?? "").isEmpty == false)
        #expect(plist["SUEnableInstallerLauncherService"] == nil)
        #expect((plist["SUScheduledCheckInterval"] as? NSNumber)?.intValue == 86400)
    }

    @Test func upgradeFromV010DefaultsKeepsPreferences() throws {
        // Review Focus 1: constructing the updater over a defaults store that
        // looks like an upgraded 0.1.0 install must not disturb any seeded
        // value and must not decide automatic checks for the user; Sparkle
        // asks via its standard permission prompt once the updater starts.
        // The host bundle's identifier names the suite Sparkle binds to a
        // non-main host (SUHost), so the seeded domain below is the one the
        // updater under test actually reads and writes.
        let domain = "com.sdelavega.xrg.upgradeTest.\(UUID().uuidString)"
        let host = try makeTestHostBundle(identifier: domain)
        let defaults = try #require(UserDefaults(suiteName: domain))
        defer {
            defaults.removePersistentDomain(forName: domain)
            try? FileManager.default.removeItem(at: host.bundleURL)
        }
        // Representative 0.1.0 keys: module order, a theme, module visibility.
        let order = Data(#"{"version":1,"order":["cpu","gpu","tpu","memory","network","disk"]}"#.utf8)
        defaults.set(order, forKey: XRGGraphPreferences.key)
        defaults.set(Data(#"{"format":"xrg-ng-theme","version":2}"#.utf8), forKey: XRGTheme.documentKey)
        defaults.set("Fixture", forKey: XRGTheme.nameKey)
        defaults.set(0.4, forKey: "textTransparency")
        defaults.set(true, forKey: "showCPUGraph")
        let seeded = defaults.persistentDomain(forName: domain) ?? [:]
        let updater = XRGUpdater(startingUpdater: false, host: host, defaults: defaults)
        #expect(NSDictionary(dictionary: defaults.persistentDomain(forName: domain) ?? [:]).isEqual(to: seeded))
        #expect(defaults.data(forKey: XRGGraphPreferences.key) == order)
        #expect(defaults.string(forKey: XRGTheme.nameKey) == "Fixture")
        #expect(defaults.bool(forKey: "showCPUGraph"))
        // The host-bound updater reads the same seeded suite, so construction
        // left automatic checks unset there.
        #expect(updater.sparkleUpdater.automaticallyChecksForUpdates == false)
        #expect(defaults.object(forKey: "SUEnableAutomaticChecks") == nil)
    }

    /// A minimal bundle on disk standing in for a previously installed host.
    /// Sparkle binds a non-main host to the defaults suite named by the
    /// bundle's identifier, which keeps the seeded domain isolated from this
    /// test process's own preferences.
    private func makeTestHostBundle(identifier: String) throws -> Bundle {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("XRGUpdaterTests-host-\(UUID().uuidString)", isDirectory: true)
        let contents = root.appendingPathComponent("Contents", isDirectory: true)
        try FileManager.default.createDirectory(at: contents, withIntermediateDirectories: true)
        let info: [String: Any] = ["CFBundleIdentifier": identifier,
                                   "CFBundleName": "XRG-ng Upgrade Fixture",
                                   "CFBundlePackageType": "APPL",
                                   "CFBundleShortVersionString": "0.1.0",
                                   "CFBundleVersion": "1"]
        let data = try PropertyListSerialization.data(fromPropertyList: info, format: .xml, options: 0)
        try data.write(to: contents.appendingPathComponent("Info.plist"))
        return try #require(Bundle(path: root.path))
    }
}
