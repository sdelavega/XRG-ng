// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Stephen de la Vega.

import AppKit
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

    // MARK: Read-only destinations are never replaced (review issue 1)

    /// A readable file whose owner cannot write it: the document loads, a
    /// change is held in memory and reported like an unreadable file, and
    /// the file's bytes, mtime and mode are untouched.
    @Test func readOnlyFileIsNeverReplaced() throws {
        let fixture = try Fixture(); defer { fixture.cleanUp() }
        let catalog = try self.catalog()
        try XRGSettingsDocument.defaults(catalog: catalog, platform: .macos).serialized()
            .write(to: fixture.documentURL)
        try FileManager.default.setAttributes([.posixPermissions: 0o400],
                                               ofItemAtPath: fixture.documentURL.path)
        defer { try? FileManager.default.setAttributes([.posixPermissions: 0o600],
                                                        ofItemAtPath: fixture.documentURL.path) }
        let bytes = try #require(documentBytes(fixture.documentURL))
        let stamp = try modificationDate(fixture.documentURL)

        let store = XRGSettingsStore(fileURL: fixture.documentURL, defaults: fixture.defaults, catalog: catalog)
        #expect(store.loadProblem == nil)  // the file is readable: it loads
        try store.set("general.window.title", .string("Held in memory"))
        #expect(store.value("general.window.title") == .string("Held in memory"))
        #expect(store.loadProblem != nil)  // surfaced the same way an unreadable file is
        #expect(documentBytes(fixture.documentURL) == bytes)
        #expect(try modificationDate(fixture.documentURL) == stamp)
        let mode = try #require(FileManager.default.attributesOfItem(atPath: fixture.documentURL.path)[.posixPermissions] as? Int)
        #expect(mode == 0o400)
        // No temporary sibling files were left in the document's directory.
        let siblings = try FileManager.default.contentsOfDirectory(atPath: fixture.documentURL.deletingLastPathComponent().path)
        #expect(siblings == ["settings.json"])
    }

    /// Write permission removed after the store loaded: the same protection.
    @Test func permissionsRemovedAfterLoadKeepFileUnchanged() throws {
        let fixture = try Fixture(); defer { fixture.cleanUp() }
        let catalog = try self.catalog()
        let store = XRGSettingsStore(fileURL: fixture.documentURL, defaults: fixture.defaults, catalog: catalog)
        try store.set("general.window.title", .string("Writable once"))
        let bytes = try #require(documentBytes(fixture.documentURL))
        let stamp = try modificationDate(fixture.documentURL)

        try FileManager.default.setAttributes([.posixPermissions: 0o400],
                                               ofItemAtPath: fixture.documentURL.path)
        defer { try? FileManager.default.setAttributes([.posixPermissions: 0o600],
                                                        ofItemAtPath: fixture.documentURL.path) }
        try store.set("general.window.title", .string("Held in memory"))
        #expect(store.value("general.window.title") == .string("Held in memory"))
        #expect(store.loadProblem != nil)
        #expect(documentBytes(fixture.documentURL) == bytes)
        #expect(try modificationDate(fixture.documentURL) == stamp)
    }

    /// A settings file in a directory that is not writable: a change never
    /// replaces it and never leaves a temporary file behind.
    @Test func nonWritableDirectoryIsNeverWritten() throws {
        let fixture = try Fixture(); defer { fixture.cleanUp() }
        let catalog = try self.catalog()
        try XRGSettingsDocument.defaults(catalog: catalog, platform: .macos).serialized()
            .write(to: fixture.documentURL)
        let bytes = try #require(documentBytes(fixture.documentURL))
        let stamp = try modificationDate(fixture.documentURL)
        let directory = fixture.documentURL.deletingLastPathComponent()
        try FileManager.default.setAttributes([.posixPermissions: 0o555], ofItemAtPath: directory.path)
        defer { try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: directory.path) }

        let store = XRGSettingsStore(fileURL: fixture.documentURL, defaults: fixture.defaults, catalog: catalog)
        #expect(store.loadProblem == nil)
        try store.set("general.window.title", .string("Held in memory"))
        #expect(store.value("general.window.title") == .string("Held in memory"))
        #expect(store.loadProblem != nil)
        #expect(documentBytes(fixture.documentURL) == bytes)
        #expect(try modificationDate(fixture.documentURL) == stamp)
        let siblings = try FileManager.default.contentsOfDirectory(atPath: directory.path)
        #expect(siblings == ["settings.json"])
    }

    /// A first launch whose destination directory is not writable migrates
    /// into memory, reports the problem, and creates no file at all.
    @Test func migrationIntoNonWritableDirectoryCreatesNoFile() throws {
        let fixture = try Fixture(); defer { fixture.cleanUp() }
        let catalog = try self.catalog()
        fixture.defaults.set("My XRG", forKey: "windowTitle")
        let directory = fixture.documentURL.deletingLastPathComponent()
        try FileManager.default.setAttributes([.posixPermissions: 0o555], ofItemAtPath: directory.path)
        defer { try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: directory.path) }

        let store = XRGSettingsStore(fileURL: fixture.documentURL, defaults: fixture.defaults, catalog: catalog)
        #expect(store.loadProblem != nil)
        #expect(store.value("general.window.title") == .string("My XRG"))
        #expect(!FileManager.default.fileExists(atPath: fixture.documentURL.path))
    }

    // MARK: Effective 0.2.2 values survive an upgrade (review issue 4)

    /// An empty 0.2.2 domain migrates the effective registered default for
    /// every mapped key whose 0.2.2 default differs from the catalog default
    /// (netMinGraphScale 1024, not the catalog's 0), writing nothing back.
    /// The migration is driven directly so the empty domain is exactly empty:
    /// in the test process other suites register 0.2.2 defaults into the
    /// shared registration domain, which a live suite would read through.
    @Test func emptyDomainMigratesEffective022Defaults() throws {
        let catalog = try self.catalog()
        let registered = XRGWindowPreferences.defaultValues(metric: false, screen: .zero)
        let (document, diagnostics) = XRGSettingsMigration.fromMacDefaults([:], registered: registered, catalog: catalog)
        #expect(diagnostics.isEmpty)
        #expect(document.values["graphs.network.minimum_scale"] == .int(1024))
        #expect(document.values["graphs.stock.visible"] == .bool(true))
        #expect(document.values["graphs.cpu.temperature_units"] == .string("fahrenheit"))
        #expect(document.values["graphs.temperature.units"] == .string("fahrenheit"))
        #expect(document.values["weather.units.temperature"] == .string("fahrenheit"))
        #expect(document.values["weather.units.distance"] == .string("miles"))
        #expect(document.values["weather.units.pressure"] == .string("inches"))
        // A registered default that equals the catalog default is not stored.
        #expect(document.values["general.window.border_width"] == nil)
        #expect(document.values["graphs.cpu.visible"] == nil)
        // showNPUGraph depends on the machine (Apple Silicon registers "YES",
        // Intel "NO"); the Intel form is covered by
        // migrationAppliesRegisteredDefaultsGenerally below.
    }

    /// Through the store: the user's persisted value beats the registered
    /// default, and nothing is ever written back to the 0.2.2 domain.
    @Test func userValuesBeatRegisteredDefaults() throws {
        let fixture = try Fixture(); defer { fixture.cleanUp() }
        let catalog = try self.catalog()
        fixture.defaults.set(512, forKey: "netMinGraphScale")

        let store = XRGSettingsStore(fileURL: fixture.documentURL, defaults: fixture.defaults, catalog: catalog)
        #expect(store.loadProblem == nil)
        #expect(store.value("graphs.network.minimum_scale") == .int(512))
        let bytes = try #require(documentBytes(fixture.documentURL))
        let loaded = try #require(try? JSONSerialization.jsonObject(with: bytes) as? [String: Any])
        #expect((loaded["settings"] as? [String: Any])?["graphs.network.minimum_scale"] as? Int == 512)
        // The user's key is untouched by the migration.
        #expect(fixture.defaults.object(forKey: "netMinGraphScale") as? Int == 512)
    }

    // MARK: Document writes never touch mapped legacy keys (review issue 2)

    /// Blobs, multi-mapped keys and theme applications on the document
    /// backend leave the complete persistent domain unchanged.
    @Test func mappedLegacyKeysNeverEnterTheDefaultsDomain() throws {
        let fixture = try Fixture(); defer { fixture.cleanUp() }
        let defaults = fixture.defaults
        let catalog = try self.catalog()
        let before = defaults.persistentDomain(forName: fixture.domain) ?? [:]

        let store = XRGSettingsStore(fileURL: fixture.documentURL, defaults: defaults, catalog: catalog)
        #expect(store.loadProblem == nil)
        var snapshot: [String: Any] = [:]
        snapshot[XRGGraphPreferences.key] = try XRGGraphPreferences().encoded()
        snapshot[XRGProcessInspector.optionsKey] = try JSONEncoder().encode(XRGProcessOptions())
        snapshot[XRGCPUView.sourceKey] = try XRGMonitorSource(source: "3").encoded()
        snapshot["vramGraphSourcesV1"] = try XRGHardwareSources().encoded()
        snapshot["fanGraphSourcesV1"] = try XRGHardwareSources().encoded()
        snapshot["portableThemeName"] = "Midnight"
        store.setLegacyValues(snapshot)

        // A theme application through the typed settings writes the document
        // only: neither the mapped theme keys nor the portable document.
        var theme: [String: Any] = [:]
        let archive = try NSKeyedArchiver.archivedData(withRootObject: NSColor.red, requiringSecureCoding: true)
        for key in ["backgroundColor", "graphBGColor", "graphFG1Color", "graphFG2Color", "graphFG3Color", "borderColor", "textColor"] {
            theme[key] = archive
        }
        for key in ["backgroundTransparency", "graphBGTransparency", "graphFG1Transparency", "graphFG2Transparency",
                    "graphFG3Transparency", "borderTransparency", "textTransparency"] {
            theme[key] = 0.5
        }
        let settings = XRGSettings(store: store)
        try settings.applyThemeDictionary(theme, defaults: defaults)

        let after = defaults.persistentDomain(forName: fixture.domain) ?? [:]
        #expect(NSDictionary(dictionary: after).isEqual(to: before))
        // The theme landed in the document instead.
        #expect(settings.backgroundTransparency == 0.5)
        #expect(store.value("themes.name") == .string("Midnight"))
    }

    // MARK: Snapshots replace removed values (review issue 3)

    /// A preferences snapshot that clears a selection or drops a graph
    /// override removes what was stored: it does not silently revert.
    @Test func snapshotValuesReplaceRemovedOnes() throws {
        let fixture = try Fixture(); defer { fixture.cleanUp() }
        let catalog = try self.catalog()
        let store = XRGSettingsStore(fileURL: fixture.documentURL, defaults: fixture.defaults, catalog: catalog)
        try store.set("sources.cpu.core", .int(3))
        try store.set("graphs.cpu.height", .int(90))
        #expect(store.value("sources.cpu.core") == .int(3))

        var snapshot: [String: Any] = [:]
        snapshot[XRGCPUView.sourceKey] = try XRGMonitorSource().encoded()  // cleared selection
        snapshot[XRGGraphPreferences.key] = try XRGGraphPreferences().encoded()  // no overrides
        store.setLegacyValues(snapshot)

        // The cleared values survive a reopen.
        let reopened = XRGSettingsStore(fileURL: fixture.documentURL, defaults: fixture.defaults, catalog: catalog)
        #expect(reopened.value("sources.cpu.core") == .null)
        #expect(reopened.value("graphs.cpu.height") == .null)
    }

    // MARK: Process inspector options load from the document (review issue 5)

    @Test func processOptionsSurviveMigrationAndReopen() throws {
        let fixture = try Fixture(); defer { fixture.cleanUp() }
        let defaults = fixture.defaults
        var options = XRGProcessOptions()
        options.sort = .memory
        options.search = "xrg"
        options.user = "root"
        options.limit = 200
        defaults.set(try JSONEncoder().encode(options), forKey: XRGProcessInspector.optionsKey)
        let catalog = try self.catalog()

        let store = XRGSettingsStore(fileURL: fixture.documentURL, defaults: defaults, catalog: catalog)
        let loaded = try #require(store.processOptions())
        #expect(loaded == options)

        // The same values load again from the written document...
        let reopened = XRGSettingsStore(fileURL: fixture.documentURL, defaults: defaults, catalog: catalog)
        #expect(reopened.processOptions() == loaded)

        // ...and storing through the document backend round-trips too.
        var changed = XRGProcessOptions()
        changed.sort = .pid
        changed.search = "changed"
        reopened.storeProcessOptions(changed)
        #expect(reopened.value("graphs.processes.filter") == .string("changed"))
        #expect(reopened.processOptions() == changed)
        let third = XRGSettingsStore(fileURL: fixture.documentURL, defaults: defaults, catalog: catalog)
        #expect(third.processOptions() == changed)
    }

    // MARK: Unchanged values never rewrite the file (review issue 7)

    @Test func unchangedSetWritesNothingAndNotifiesNobody() throws {
        let fixture = try Fixture(); defer { fixture.cleanUp() }
        let catalog = try self.catalog()
        let store = XRGSettingsStore(fileURL: fixture.documentURL, defaults: fixture.defaults, catalog: catalog)
        try store.set("general.window.title", .string("Once"))
        let bytes = try #require(documentBytes(fixture.documentURL))
        let stamp = try modificationDate(fixture.documentURL)

        var notifications = 0
        let center = NotificationCenter.default
        let token = center.addObserver(forName: XRGSettingsStore.didChange, object: store, queue: .main) { _ in
            notifications += 1
        }
        defer { center.removeObserver(token) }

        try store.set("general.window.title", .string("Once"))  // unchanged
        #expect(notifications == 0)
        #expect(documentBytes(fixture.documentURL) == bytes)
        #expect(try modificationDate(fixture.documentURL) == stamp)
        // A changed value still writes and notifies.
        try store.set("general.window.title", .string("Twice"))
        #expect(notifications == 1)
        #expect(documentBytes(fixture.documentURL) != bytes)
    }

    /// The delegate's launch restoration only re-asserts what the document
    /// already says: a document-backed launch/restore cycle leaves the
    /// file's bytes and mtime untouched.
    @Test func documentBackedLaunchRestoreCycleLeavesFileUnchanged() throws {
        let fixture = try Fixture(); defer { fixture.cleanUp() }
        let catalog = try self.catalog()
        var previous = XRGSettingsDocument()
        try previous.set("general.sensors_window.open", .bool(true), catalog: catalog)
        try previous.set("general.window.collapsed", .bool(true), catalog: catalog)
        try previous.set("general.window.title", .string("Restored"), catalog: catalog)
        try previous.serialized().write(to: fixture.documentURL)
        try FileManager.default.setAttributes([.modificationDate: Date(timeIntervalSince1970: 1_700_000_000)],
                                               ofItemAtPath: fixture.documentURL.path)
        let bytes = try #require(documentBytes(fixture.documentURL))
        let stamp = try modificationDate(fixture.documentURL)

        // Launch: hydration never writes back...
        let store = XRGSettingsStore(fileURL: fixture.documentURL, defaults: fixture.defaults, catalog: catalog)
        let settings = XRGSettings(store: store)
        #expect(settings.sensorsWindowOpen && settings.windowCollapsed && settings.windowTitle == "Restored")
        // ...and the restoration paths (openSensorWindow, the collapsed
        // window's minimize) re-assert values the document already holds.
        settings.sensorsWindowOpen = true
        settings.windowCollapsed = true
        #expect(documentBytes(fixture.documentURL) == bytes)
        #expect(try modificationDate(fixture.documentURL) == stamp)

        // A relaunch over the same file is just as quiet.
        let relaunched = XRGSettingsStore(fileURL: fixture.documentURL, defaults: fixture.defaults, catalog: catalog)
        let restored = XRGSettings(store: relaunched)
        restored.sensorsWindowOpen = true
        restored.windowCollapsed = true
        #expect(restored.windowTitle == "Restored")
        #expect(documentBytes(fixture.documentURL) == bytes)
        #expect(try modificationDate(fixture.documentURL) == stamp)
    }

    // MARK: Typed settings follow store changes (review issue 8)

    /// A change through the store refreshes the typed properties and the
    /// cached graph preferences without writing anything back.
    @Test func typedSettingsFollowStoreChangesWithoutWritingBack() throws {
        let fixture = try Fixture(); defer { fixture.cleanUp() }
        let catalog = try self.catalog()
        let store = XRGSettingsStore(fileURL: fixture.documentURL, defaults: fixture.defaults, catalog: catalog)
        let settings = XRGSettings(store: store)
        #expect(settings.graphRefresh == 1)

        var titleChanges = 0
        let center = NotificationCenter.default
        let token = center.addObserver(forName: XRGSettingsStore.didChange, object: store, queue: .main) {
            if $0.userInfo?["id"] as? String == "graphs.refresh" { titleChanges += 1 }
        }
        defer { center.removeObserver(token) }

        try store.set("graphs.refresh", .double(4))
        #expect(settings.graphRefresh == 4)
        #expect(titleChanges == 1)  // the store's own change only: no write-back

        try store.set("general.window.show_summary", .bool(true))
        #expect(settings.showSummary == true)
        try store.set("appearance.series1.color", .color([1, 0, 0, 1]))
        #expect(settings.graphFG1Color.redComponent == 1)

        // The cached graph presentation follows per-graph changes too.
        try store.set("graphs.cpu.height", .int(90))
        #expect(settings.graphPreferences[.cpu].height == 90)

        // A section reset refreshes the typed properties as well.
        store.resetSection("graphs")
        #expect(settings.graphRefresh == 1)
        #expect(settings.graphPreferences[.cpu].height == nil)
    }

    // MARK: The store's own path is bundle-gated (review summary)

    /// Only the real application bundle resolves to the production path;
    /// every other bundle identifier — a smoke bundle, a disposable copy, an
    /// unbundled process — gets a private, bundle-scoped directory.
    @Test func nonProductionBundleNeverUsesTheProductionPath() throws {
        let production = XRGSettingsStore.sharedDocumentURL(bundleIdentifier: "com.sdelavega.xrg")
        #expect(production.path.hasSuffix("Application Support/XRG-ng/settings.json"))
        #expect(XRGSettingsStore.sharedDocumentURL(bundleIdentifier: "com.sdelavega.xrg") == production)

        let others: [String?] = ["com.sdelavega.XRG-ng.Smoke.53D13083-7C1E-4BB5-9BE1-5E7A88F3AC11",
                                "com.sdelavega.XRG-ng.PackagedSmoke.53D13083-7C1E-4BB5-9BE1-5E7A88F3AC11",
                                "com.sdelavega.xrg.debug", "com.example.other", nil]
        for identifier in others {
            let url = XRGSettingsStore.sharedDocumentURL(bundleIdentifier: identifier)
            #expect(url.lastPathComponent == "settings.json", "\(identifier ?? "nil")")
            #expect(url.path.hasSuffix("Application Support/XRG-ng-Private/\(identifier ?? "unbundled")/settings.json"))
            #expect(url != production)
            #expect(!url.path.contains("/XRG-ng/"), "\(identifier ?? "nil")")
        }
    }

    // MARK: The registered-defaults rule is general (review issue 4)

    /// Every mapped key whose 0.2.2 registered default differs from the
    /// catalog default takes the registered value on migration; keys whose
    /// registered default matches stay unset.
    @Test func migrationAppliesRegisteredDefaultsGenerally() throws {
        let catalog = try self.catalog()
        // The US-locale registered defaults, in the string forms 0.2.2
        // registered them, plus the Intel NPU default and the network floor.
        let registered: [String: Any] = ["cpuTemperatureUnits": 0, "tempUnits": 0, "temperatureUnits": 0,
                                        "distanceUnits": 0, "pressureUnits": 0, "showNPUGraph": "NO",
                                        "netMinGraphScale": "1024", "showStockGraph": "YES",
                                        "borderWidth": "4", "networkInterface": "All"]
        let (document, diagnostics) = XRGSettingsMigration.fromMacDefaults([:], registered: registered, catalog: catalog)
        #expect(diagnostics.isEmpty)

        #expect(document.values["graphs.cpu.temperature_units"] == .string("fahrenheit"))
        #expect(document.values["graphs.temperature.units"] == .string("fahrenheit"))
        #expect(document.values["weather.units.temperature"] == .string("fahrenheit"))
        #expect(document.values["weather.units.distance"] == .string("miles"))
        #expect(document.values["weather.units.pressure"] == .string("inches"))
        #expect(document.values["graphs.npu.visible"] == .bool(false))
        #expect(document.values["graphs.network.minimum_scale"] == .int(1024))
        #expect(document.values["graphs.stock.visible"] == .bool(true))
        // A registered default that equals the catalog default is not stored.
        #expect(document.values["general.window.border_width"] == nil)
        #expect(document.values["graphs.cpu.visible"] == nil)
        #expect(document.values["sources.network.interface"] == nil)
    }

    // MARK: The sensor policy resolves the active window's store (review issue 6)

    @Test func sensorPolicyResolvesTheActiveWindowStore() throws {
        let fixture = try Fixture(); defer { fixture.cleanUp() }
        let catalog = try self.catalog()
        let window = XRGGraphWindow(contentRect: NSRect(x: 0, y: 0, width: 200, height: 400),
                                     defaults: fixture.defaults, center: NotificationCenter(), scheduleTimers: false)
        #expect(XRGTemperatureView.policyStore(of: nil) == nil)
        // A fixture scene's window keeps the injected suite.
        let legacy = try #require(XRGTemperatureView.policyStore(of: window))
        #expect(!legacy.isDocumentBacked)
        #expect(legacy === window.appSettings?.store)
        // The shipping window carries the document store, and the policy
        // resolves that store instead of the legacy domain.
        let store = XRGSettingsStore(fileURL: fixture.documentURL, defaults: fixture.defaults, catalog: catalog)
        window.appSettings = XRGSettings(store: store)
        let resolved = try #require(XRGTemperatureView.policyStore(of: window))
        #expect(resolved === store && resolved.isDocumentBacked)
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