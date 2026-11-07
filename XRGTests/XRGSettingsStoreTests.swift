// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Stephen de la Vega.

import Foundation
import Testing
@testable import XRGCore

/// The macOS settings store: the shared document is the source of truth, the
/// 0.2.2 NSUserDefaults domain is read once (migration) and never written.
@Suite @MainActor
struct XRGSettingsStoreTests {
    /// One disposable suite per test, removed from both cfprefsd and disk so
    /// no XRG test-domain files accumulate under ~/Library/Preferences.
    private struct Fixture {
        let domain: String
        let defaults: UserDefaults
        let documentURL: URL

        init() throws {
            let domain = "XRG.settingsStore.\(UUID().uuidString)"
            let defaults = try #require(UserDefaults(suiteName: domain))
            let root = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
                .appendingPathComponent("xrg-0.2.3-task-8", isDirectory: true)
                .appendingPathComponent(domain, isDirectory: true)
            try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
            self.domain = domain
            self.defaults = defaults
            self.documentURL = root.appendingPathComponent("settings.json")
        }

        var preferencesURL: URL {
            let home = FileManager.default.homeDirectoryForCurrentUser
            return home.appendingPathComponent("Library/Preferences/\(domain).plist")
        }

        /// Remove the suite's persistent domain and its plist file, like the
        /// repo's other disposable-domain tests, plus this fixture's directory.
        func cleanUp() {
            defaults.removePersistentDomain(forName: domain)
            try? FileManager.default.removeItem(at: preferencesURL)
            try? FileManager.default.removeItem(at: documentURL.deletingLastPathComponent())
        }
    }

    private func catalog() throws -> XRGSettingsCatalog {
        try #require(try? XRGSettingsCatalog.load())
    }

    private func modificationDate(_ url: URL) throws -> Date {
        try #require(FileManager.default.attributesOfItem(atPath: url.path)[.modificationDate] as? Date)
    }

    private func documentBytes(_ url: URL) -> Data? {
        try? Data(contentsOf: url)
    }

    // MARK: Migration

    @Test func firstLaunchMigratesDefaultsOnce() throws {
        let fixture = try Fixture(); defer { fixture.cleanUp() }
        let defaults = fixture.defaults
        defaults.set("My XRG", forKey: "windowTitle")
        defaults.set(7, forKey: "borderWidth")
        defaults.set(true, forKey: "dropShadow")
        defaults.set(2.5, forKey: "graphRefresh")
        let catalog = try self.catalog()

        let first = XRGSettingsStore(fileURL: fixture.documentURL, defaults: defaults, catalog: catalog)
        #expect(first.loadProblem == nil)

        // The document exists and carries the migrated settings.
        let bytes = try #require(documentBytes(fixture.documentURL))
        let loaded = try #require(try? JSONSerialization.jsonObject(with: bytes) as? [String: Any])
        let settings = try #require(loaded["settings"] as? [String: Any])
        #expect(settings["general.window.title"] as? String == "My XRG")
        #expect(settings["general.window.border_width"] as? Int == 7)
        #expect(settings["general.window.drop_shadow"] as? Bool == true)
        #expect(settings["graphs.refresh"] as? Double == 2.5)

        // A second store over the same file loads it and rewrites nothing.
        try? FileManager.default.setAttributes([.modificationDate: Date(timeIntervalSince1970: 1_700_000_000)],
                                                ofItemAtPath: fixture.documentURL.path)
        let stamp = try modificationDate(fixture.documentURL)
        let second = XRGSettingsStore(fileURL: fixture.documentURL, defaults: defaults, catalog: catalog)
        #expect(second.value("general.window.title") == .string("My XRG"))
        #expect(second.value("general.window.border_width") == .int(7))
        #expect(try modificationDate(fixture.documentURL) == stamp)
    }

    @Test func defaultsAreLeftUntouched() throws {
        let fixture = try Fixture(); defer { fixture.cleanUp() }
        let defaults = fixture.defaults
        let seeded: [String: Any] = ["windowTitle": "Keep", "borderWidth": 9, "graphOrientationVertical": false,
                                     "windowLevel": 2, "checkForUpdates": false, "tempUnits": 1]
        for (key, value) in seeded { defaults.set(value, forKey: key) }
        let catalog = try self.catalog()

        let store = XRGSettingsStore(fileURL: fixture.documentURL, defaults: defaults, catalog: catalog)
        #expect(store.value("general.window.title") == .string("Keep"))
        #expect(store.value("general.window.level") == .string("background"))
        #expect(store.value("graphs.temperature.units") == .string("celsius"))

        // Migration reads the domain; it never adds, changes or removes a key.
        let before = defaults.dictionaryRepresentation()
        _ = XRGSettingsStore(fileURL: fixture.documentURL, defaults: defaults, catalog: catalog)
        let after = defaults.dictionaryRepresentation()
        for key in after.keys {
            #expect(before[key] != nil, "migration added key \(key)")
        }
        for (key, value) in seeded {
            let current = after[key]
            if let number = value as? Int {
                #expect((current as? NSNumber)?.intValue == number, "mismatch: \(key)")
            } else if let flag = value as? Bool {
                #expect((current as? NSNumber)?.boolValue == flag, "mismatch: \(key)")
            } else if let text = value as? String {
                #expect(current as? String == text, "mismatch: \(key)")
            }
        }
    }

    // MARK: Writes

    @Test func setWritesAtomicallyAndNotifies() throws {
        let fixture = try Fixture(); defer { fixture.cleanUp() }
        let catalog = try self.catalog()
        let store = XRGSettingsStore(fileURL: fixture.documentURL, defaults: fixture.defaults, catalog: catalog)

        var changed: [(String?, XRGSettingsStore?)] = []
        let center = NotificationCenter.default
        let token = center.addObserver(forName: XRGSettingsStore.didChange, object: nil, queue: .main) {
            changed.append(($0.userInfo?["id"] as? String, $0.object as? XRGSettingsStore))
        }
        defer { center.removeObserver(token) }

        try store.set("general.window.title", .string("Notified"))
        #expect(changed.count == 1 && changed[0].0 == "general.window.title" && changed[0].1 === store)

        let bytes = try #require(documentBytes(fixture.documentURL))
                let loaded = try #require(try? JSONSerialization.jsonObject(with: bytes) as? [String: Any])
        #expect((loaded["settings"] as? [String: Any])?["general.window.title"] as? String == "Notified")
        // No temporary sibling files are left in the document's directory.
        let siblings = try #require(try? FileManager.default.contentsOfDirectory(
            atPath: fixture.documentURL.deletingLastPathComponent().path))
        #expect(siblings == ["settings.json"])

        // Storing the entry's catalog default removes the key again.
        try store.set("general.window.title", .string(""))
        let saved = try #require(documentBytes(fixture.documentURL))
        let defaults = try #require(try? JSONSerialization.jsonObject(with: saved) as? [String: Any])
        #expect((defaults["settings"] as? [String: Any])?["general.window.title"] == nil)
    }

    @Test func invalidSetIsNotSaved() throws {
        let fixture = try Fixture(); defer { fixture.cleanUp() }
        let catalog = try self.catalog()
        let store = XRGSettingsStore(fileURL: fixture.documentURL, defaults: fixture.defaults, catalog: catalog)
        try store.set("general.window.title", .string("Valid"))
        let bytes = documentBytes(fixture.documentURL)
        let stamp = try modificationDate(fixture.documentURL)

        #expect(throws: XRGSettingsError.unknownId) {
            try store.set("not.a.setting", .bool(true))
        }
        #expect(throws: XRGSettingsError.wrongType) {
            try store.set("general.window.title", .bool(true))
        }
        let entry = try #require(catalog.entry("general.window.border_width"))
        let range = try #require(entry.range)
        #expect(throws: XRGSettingsError.outOfRange(min: range.min, max: range.max)) {
            try store.set("general.window.border_width", .int(1_000_000))
        }
        #expect(throws: XRGSettingsError.notAnOption) {
            try store.set("general.window.level", .string("sideways"))
        }
        #expect(store.value("general.window.title") == .string("Valid"))
        #expect(documentBytes(fixture.documentURL) == bytes)
        #expect(try modificationDate(fixture.documentURL) == stamp)
    }

    // MARK: Unreadable files

    @Test func malformedFileIsNotOverwritten() throws {
        let fixture = try Fixture(); defer { fixture.cleanUp() }
        let catalog = try self.catalog()
        let garbage = Data("{\"format\": \"xrg-ng-settings\", \"version\": 1, \"settings\": {".utf8)
        try garbage.write(to: fixture.documentURL)
                let stamp = try modificationDate(fixture.documentURL)

        let store = XRGSettingsStore(fileURL: fixture.documentURL, defaults: fixture.defaults, catalog: catalog)
        // The store runs on catalog defaults and reports the problem.
        #expect(store.loadProblem?.problem == XRGSettingsDiagnostic.malformed)
        #expect(store.value("general.window.border_width") == .int(4))
        #expect(XRGSettingsValue.sameValue(store.value("graphs.refresh"), .double(1)))
        // A change does not overwrite the user's file before they confirm.
        try store.set("general.window.title", .string("Unsaved"))
        #expect(store.value("general.window.title") == .string("Unsaved"))
        #expect(documentBytes(fixture.documentURL) == garbage)
        #expect(try modificationDate(fixture.documentURL) == stamp)

        // After the user confirms, the file is replaced and further changes persist.
        store.replaceUnreadableFile()
        #expect(store.loadProblem == nil)
        let bytes = try #require(documentBytes(fixture.documentURL))
        #expect(bytes != garbage)
        #expect(store.value("general.window.title") == .string("Unsaved"))
        try store.set("general.window.title", .string("Saved"))
        let saved = try #require(documentBytes(fixture.documentURL))
        let parsed = try #require(JSONSerialization.jsonObject(with: saved) as? [String: Any])
        #expect(parsed["settings"] != nil)
    }

    @Test func readOnlyFileReportsAndKeepsRunning() throws {
        let fixture = try Fixture(); defer { fixture.cleanUp() }
        let catalog = try self.catalog()
        try XRGSettingsDocument.defaults(catalog: catalog, platform: .macos).serialized()
            .write(to: fixture.documentURL)
        // The file cannot be read at all (owner has no read permission).
        try FileManager.default.setAttributes([.posixPermissions: 0o000],
                                              ofItemAtPath: fixture.documentURL.path)
        defer { try? FileManager.default.setAttributes([.posixPermissions: 0o600],
                                                        ofItemAtPath: fixture.documentURL.path) }

        let store = XRGSettingsStore(fileURL: fixture.documentURL, defaults: fixture.defaults, catalog: catalog)
        #expect(store.loadProblem != nil)
        #expect(store.loadProblem?.problem != XRGSettingsDiagnostic.malformed)
        #expect(store.value("general.window.border_width") == .int(4))
        // The store keeps serving settings and reporting the problem.
        try store.set("general.window.title", .string("Held"))
        #expect(store.value("general.window.title") == .string("Held"))
        #expect(store.loadProblem != nil)
    }

    // MARK: Excluded keys stay in NSUserDefaults

    @Test func windowFramesAndSparkleKeysStayInDefaults() throws {
        let fixture = try Fixture(); defer { fixture.cleanUp() }
        let defaults = fixture.defaults
        let excluded: [String: Any] = [
            "SUEnableAutomaticChecks": true,
            "SUScheduledCheckInterval": 86400,
            "unminimizedFrame": "{{10, 20}, {300, 400}}",
            "NSWindow Frame XRGGraph": "{{1, 2}, {140, 700}}",
            "tempLocationsAutoconfigured": true,
            "aiTokensDailyPromptTokens": 41,
        ]
        for (key, value) in excluded { defaults.set(value, forKey: key) }
        let catalog = try self.catalog()

        let store = XRGSettingsStore(fileURL: fixture.documentURL, defaults: defaults, catalog: catalog)
        #expect(store.value("general.window.title") == .string(""))

        // None of the excluded keys moved into the document...
        let text = String(data: try #require(documentBytes(fixture.documentURL)), encoding: .utf8) ?? ""
        for key in excluded.keys {
            #expect(!text.contains("\"\(key)\"") || key == "unminimizedFrame")
        }
        // ...and every one is still in the defaults domain afterwards.
        for (key, value) in excluded {
            if let number = value as? Int {
                #expect(defaults.object(forKey: key) != nil && (defaults.object(forKey: key) as? NSNumber)?.intValue == number, "mismatch: \(key)")
            } else if let flag = value as? Bool {
                #expect(defaults.bool(forKey: key) == flag, "mismatch: \(key)")
            } else if let text = value as? String {
                #expect(defaults.string(forKey: key) == text, "mismatch: \(key)")
            }
        }

        // Writing through the store never touches the excluded keys either.
        try store.set("general.window.title", .string("Routed"))
        #expect(defaults.object(forKey: "general.window.title") == nil)
        for (key, value) in excluded {
            if let number = value as? Int {
                #expect((defaults.object(forKey: key) as? NSNumber)?.intValue == number, "mismatch: \(key)")
            } else if let flag = value as? Bool {
                #expect(defaults.bool(forKey: key) == flag, "mismatch: \(key)")
            }
        }
    }
}