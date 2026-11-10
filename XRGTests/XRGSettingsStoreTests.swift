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

        /// Seed the suite's persistent domain and flush it to cfprefsd: the
        /// store's migration reads the suite's PERSISTENT domain (the 0.2.2
        /// rule, fix round 2 finding 5), which only reflects `set` after a
        /// flush — on a real 0.2.2 installation the values are already on
        /// disk, so production needs no flush.
        func seed(_ values: [String: Any]) {
            for (key, value) in values { defaults.set(value, forKey: key) }
            defaults.synchronize()
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
        fixture.seed(["windowTitle": "My XRG", "borderWidth": 7, "dropShadow": true, "graphRefresh": 2.5])
        let catalog = try self.catalog()

        let first = XRGSettingsStore(fileURL: fixture.documentURL, defaults: defaults, catalog: catalog,
                                     legacyDomain: ["windowTitle": "My XRG", "borderWidth": 7,
                                                    "dropShadow": true, "graphRefresh": 2.5])
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
        let second = XRGSettingsStore(fileURL: fixture.documentURL, defaults: defaults, catalog: catalog, legacyDomain: [:])
        #expect(second.value("general.window.title") == .string("My XRG"))
        #expect(second.value("general.window.border_width") == .int(7))
        #expect(try modificationDate(fixture.documentURL) == stamp)
    }

    @Test func defaultsAreLeftUntouched() throws {
        let fixture = try Fixture(); defer { fixture.cleanUp() }
        let defaults = fixture.defaults
        let seeded: [String: Any] = ["windowTitle": "Keep", "borderWidth": 9, "graphOrientationVertical": false,
                                      "windowLevel": 2, "checkForUpdates": false, "tempUnits": 1]
        fixture.seed(seeded)
        let catalog = try self.catalog()

        let store = XRGSettingsStore(fileURL: fixture.documentURL, defaults: defaults, catalog: catalog,
                                     legacyDomain: seeded)
        #expect(store.value("general.window.title") == .string("Keep"))
        #expect(store.value("general.window.level") == .string("background"))
        #expect(store.value("graphs.temperature.units") == .string("celsius"))

        // Migration reads the domain; it never adds, changes or removes a key.
        let before = defaults.dictionaryRepresentation()
        _ = XRGSettingsStore(fileURL: fixture.documentURL, defaults: defaults, catalog: catalog,
                             legacyDomain: seeded)
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
        let store = XRGSettingsStore(fileURL: fixture.documentURL, defaults: fixture.defaults, catalog: catalog, legacyDomain: [:])

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
        let store = XRGSettingsStore(fileURL: fixture.documentURL, defaults: fixture.defaults, catalog: catalog, legacyDomain: [:])
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

        let store = XRGSettingsStore(fileURL: fixture.documentURL, defaults: fixture.defaults, catalog: catalog, legacyDomain: [:])
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

        let store = XRGSettingsStore(fileURL: fixture.documentURL, defaults: fixture.defaults, catalog: catalog, legacyDomain: [:])
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

        let store = XRGSettingsStore(fileURL: fixture.documentURL, defaults: fixture.defaults, catalog: catalog, legacyDomain: [:])
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
        let store = XRGSettingsStore(fileURL: fixture.documentURL, defaults: fixture.defaults, catalog: catalog, legacyDomain: [:])
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

        let store = XRGSettingsStore(fileURL: fixture.documentURL, defaults: fixture.defaults, catalog: catalog, legacyDomain: [:])
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
        fixture.seed(["windowTitle": "My XRG"])
        let directory = fixture.documentURL.deletingLastPathComponent()
        try FileManager.default.setAttributes([.posixPermissions: 0o555], ofItemAtPath: directory.path)
        defer { try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: directory.path) }

        let store = XRGSettingsStore(fileURL: fixture.documentURL, defaults: fixture.defaults,
                                     catalog: catalog, legacyDomain: ["windowTitle": "My XRG"])
        #expect(store.loadProblem != nil)
        #expect(store.value("general.window.title") == .string("My XRG"))
        #expect(!FileManager.default.fileExists(atPath: fixture.documentURL.path))
    }

    // MARK: External changes are coordinated, never overwritten (final review, finding 2 / R28)

    /// A helper for reading one stored value out of the document file.
    private func storedValue(_ key: String, in data: Data) throws -> Any? {
        let object = try #require(try? JSONSerialization.jsonObject(with: data) as? [String: Any])
        return (object["settings"] as? [String: Any])?[key]
    }

    /// Two stores over one document must not lose each other's edits: each
    /// write compares the file with what that store last observed, adopts
    /// the other's content and re-applies only its own pending edit.
    @Test func twoStoresDoNotLoseEachOthersEdits() throws {
        let fixture = try Fixture(); defer { fixture.cleanUp() }
        let catalog = try self.catalog()
        let a = XRGSettingsStore(fileURL: fixture.documentURL, defaults: fixture.defaults,
                                 catalog: catalog, legacyDomain: [:])
        let b = XRGSettingsStore(fileURL: fixture.documentURL, defaults: fixture.defaults,
                                 catalog: catalog, legacyDomain: [:])
        try a.set("general.window.title", .string("From A"))
        try b.set("graphs.refresh", .double(2))
        let bytes = try #require(documentBytes(fixture.documentURL))
        #expect(try storedValue("general.window.title", in: bytes) as? String == "From A")
        #expect(try storedValue("graphs.refresh", in: bytes) as? Double == 2)
        // Both stores still serve their own view of the one document.
        #expect(a.value("general.window.title") == .string("From A"))
        #expect(b.value("graphs.refresh") == .double(2))
        // A third reader sees both edits.
        let reopened = XRGSettingsStore(fileURL: fixture.documentURL, defaults: fixture.defaults,
                                        catalog: catalog, legacyDomain: [:])
        #expect(reopened.value("general.window.title") == .string("From A"))
        #expect(XRGSettingsValue.sameValue(reopened.value("graphs.refresh"), .double(2)))
    }

    /// An external editor's additions and edits survive the next app write,
    /// and the store adopts the external values it does not edit itself.
    @Test func externalEditsAreAdoptedAndPreserved() throws {
        let fixture = try Fixture(); defer { fixture.cleanUp() }
        let catalog = try self.catalog()
        let store = XRGSettingsStore(fileURL: fixture.documentURL, defaults: fixture.defaults,
                                      catalog: catalog, legacyDomain: [:])
        try store.set("general.window.title", .string("Mine"))
        // An external editor adds an unknown key and retitles the window.
        let external = """
        {
          "format": "xrg-ng-settings",
          "version": 1,
          "settings": {
            "future.widget.config": true,
            "general.window.title": "External"
          }
        }
        """
        try Data(external.utf8).write(to: fixture.documentURL)
        // The next app edit adopts the external content, re-applies its own
        // edit, and keeps both the unknown key and the external title.
        try store.set("general.window.border_width", .int(8))
        let bytes = try #require(documentBytes(fixture.documentURL))
        #expect(try storedValue("future.widget.config", in: bytes) as? Bool == true)
        #expect(try storedValue("general.window.title", in: bytes) as? String == "External")
        #expect(try storedValue("general.window.border_width", in: bytes) as? Int == 8)
        // The store now serves the externally-set title too.
        #expect(store.value("general.window.title") == .string("External"))
        #expect(store.value("general.window.border_width") == .int(8))
    }

    /// An external replacement with malformed content is never overwritten by
    /// the next app edit: the write stops and the same confirmation a load
    /// would surface appears, with the pending edit kept in memory.
    @Test func externallyMalformedReplacementIsNeverOverwritten() throws {
        let fixture = try Fixture(); defer { fixture.cleanUp() }
        let catalog = try self.catalog()
        let store = XRGSettingsStore(fileURL: fixture.documentURL, defaults: fixture.defaults,
                                      catalog: catalog, legacyDomain: [:])
        try store.set("general.window.title", .string("Mine"))
        let garbage = Data("definitely not a settings document".utf8)
        try garbage.write(to: fixture.documentURL)
        try store.set("general.window.border_width", .int(8))
        #expect(store.loadProblem?.problem == XRGSettingsDiagnostic.malformed)
        #expect(try documentBytes(fixture.documentURL) == garbage)
        #expect(store.value("general.window.border_width") == .int(8), "the pending edit is kept in memory")
        // The user's confirmed replacement writes the in-memory document.
        store.replaceUnreadableFile()
        #expect(store.loadProblem == nil)
        let bytes = try #require(documentBytes(fixture.documentURL))
        #expect(try storedValue("general.window.border_width", in: bytes) as? Int == 8)
    }

    /// An external replacement from a newer version is protected the same
    /// way: never overwritten, surfaced as the load's own unsupported-version
    /// problem, replaceable only by the user's confirmation.
    @Test func externallyNewerVersionIsNeverOverwritten() throws {
        let fixture = try Fixture(); defer { fixture.cleanUp() }
        let catalog = try self.catalog()
        let store = XRGSettingsStore(fileURL: fixture.documentURL, defaults: fixture.defaults,
                                      catalog: catalog, legacyDomain: [:])
        try store.set("general.window.title", .string("Mine"))
        let future = Data("""
        {
          "format": "xrg-ng-settings",
          "version": 2,
          "settings": {
            "general.window.title": "From the future"
          }
        }
        """.utf8)
        try future.write(to: fixture.documentURL)
        try store.set("general.window.border_width", .int(8))
        #expect(store.loadProblem?.problem == XRGSettingsDiagnostic.unsupportedVersion)
        #expect(try documentBytes(fixture.documentURL) == future)
        store.replaceUnreadableFile()
        #expect(store.loadProblem == nil)
        #expect(try storedValue("general.window.border_width",
                                in: try #require(documentBytes(fixture.documentURL))) as? Int == 8)
    }

    /// An edit that no longer applies to the externally changed document is
    /// refused with the core's own error: the external content is kept in
    /// memory and on disk, and nothing is written.
    @Test func editConflictingWithExternalContentIsRefusedNotWritten() throws {
        let fixture = try Fixture(); defer { fixture.cleanUp() }
        let catalog = try self.catalog()
        let store = XRGSettingsStore(fileURL: fixture.documentURL, defaults: fixture.defaults,
                                      catalog: catalog, legacyDomain: [:])
        try store.set("graphs.cpu.samples", .int(300))
        // An external editor turns the time window on, which forbids the
        // samples count the store is about to set.
        let external = """
        {
          "format": "xrg-ng-settings",
          "version": 1,
          "settings": {
            "graphs.cpu.time_window": 5
          }
        }
        """
        try Data(external.utf8).write(to: fixture.documentURL)
        #expect(throws: XRGSettingsError.dependencyNotMet) {
            try store.set("graphs.cpu.samples", .int(500))
        }
        let bytes = try #require(documentBytes(fixture.documentURL))
        #expect(try storedValue("graphs.cpu.time_window", in: bytes) as? Int == 5)
        #expect(try storedValue("graphs.cpu.samples", in: bytes) == nil,
                "the refused edit must not reach the file")
        // The store adopted the external window and serves it.
        #expect(store.value("graphs.cpu.time_window") == .int(5))
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
        fixture.seed(["netMinGraphScale": 512])

        let store = XRGSettingsStore(fileURL: fixture.documentURL, defaults: fixture.defaults,
                                     catalog: catalog, legacyDomain: ["netMinGraphScale": 512])
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

        let store = XRGSettingsStore(fileURL: fixture.documentURL, defaults: defaults, catalog: catalog, legacyDomain: [:])
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
        let store = XRGSettingsStore(fileURL: fixture.documentURL, defaults: fixture.defaults, catalog: catalog, legacyDomain: [:])
        try store.set("sources.cpu.core", .int(3))
        try store.set("graphs.cpu.height", .int(90))
        #expect(store.value("sources.cpu.core") == .int(3))

        var snapshot: [String: Any] = [:]
        snapshot[XRGCPUView.sourceKey] = try XRGMonitorSource().encoded()  // cleared selection
        snapshot[XRGGraphPreferences.key] = try XRGGraphPreferences().encoded()  // no overrides
        store.setLegacyValues(snapshot)

        // The cleared values survive a reopen.
        let reopened = XRGSettingsStore(fileURL: fixture.documentURL, defaults: fixture.defaults, catalog: catalog, legacyDomain: [:])
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
        fixture.seed([XRGProcessInspector.optionsKey: try JSONEncoder().encode(options)])
        let catalog = try self.catalog()

        let store = XRGSettingsStore(fileURL: fixture.documentURL, defaults: defaults, catalog: catalog,
                                     legacyDomain: [XRGProcessInspector.optionsKey: try JSONEncoder().encode(options)])
        let loaded = try #require(store.processOptions())
        #expect(loaded == options)

        // The same values load again from the written document...
        let reopened = XRGSettingsStore(fileURL: fixture.documentURL, defaults: defaults, catalog: catalog, legacyDomain: [:])
        #expect(reopened.processOptions() == loaded)

        // ...and storing through the document backend round-trips too.
        var changed = XRGProcessOptions()
        changed.sort = .pid
        changed.search = "changed"
        reopened.storeProcessOptions(changed)
        #expect(reopened.value("graphs.processes.filter") == .string("changed"))
        #expect(reopened.processOptions() == changed)
        let third = XRGSettingsStore(fileURL: fixture.documentURL, defaults: defaults, catalog: catalog, legacyDomain: [:])
        #expect(third.processOptions() == changed)
    }

    // MARK: Unchanged values never rewrite the file (review issue 7)

    @Test func unchangedSetWritesNothingAndNotifiesNobody() throws {
        let fixture = try Fixture(); defer { fixture.cleanUp() }
        let catalog = try self.catalog()
        let store = XRGSettingsStore(fileURL: fixture.documentURL, defaults: fixture.defaults, catalog: catalog, legacyDomain: [:])
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
        let store = XRGSettingsStore(fileURL: fixture.documentURL, defaults: fixture.defaults, catalog: catalog, legacyDomain: [:])
        let settings = XRGSettings(store: store)
        #expect(settings.sensorsWindowOpen && settings.windowCollapsed && settings.windowTitle == "Restored")
        // ...and the restoration paths (openSensorWindow, the collapsed
        // window's minimize) re-assert values the document already holds.
        settings.sensorsWindowOpen = true
        settings.windowCollapsed = true
        #expect(documentBytes(fixture.documentURL) == bytes)
        #expect(try modificationDate(fixture.documentURL) == stamp)

        // A relaunch over the same file is just as quiet.
        let relaunched = XRGSettingsStore(fileURL: fixture.documentURL, defaults: fixture.defaults, catalog: catalog, legacyDomain: [:])
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
        let store = XRGSettingsStore(fileURL: fixture.documentURL, defaults: fixture.defaults, catalog: catalog, legacyDomain: [:])
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
        let store = XRGSettingsStore(fileURL: fixture.documentURL, defaults: fixture.defaults, catalog: catalog, legacyDomain: [:])
        window.appSettings = XRGSettings(store: store)
        let resolved = try #require(XRGTemperatureView.policyStore(of: window))
        #expect(resolved === store && resolved.isDocumentBacked)
    }

    // MARK: The owner-write mode bit is checked, not just access (fix round 2, finding 1)

    /// A destination whose mode lacks the owner-write bit is never replaced,
    /// even when an ACL grants write access so `access(W_OK)` succeeds: the
    /// mode bit itself must be present (ruling B).
    @Test func aclWriteAccessWithOwnerWriteBitMissingIsRefused() throws {
        let fixture = try Fixture(); defer { fixture.cleanUp() }
        let catalog = try self.catalog()
        try XRGSettingsDocument.defaults(catalog: catalog, platform: .macos).serialized()
            .write(to: fixture.documentURL)
        // Grant the current user write access through an ACL, then strip the
        // owner-write mode bit: `access(W_OK)` succeeds, the mode bit is absent.
        let chmod = Process()
        chmod.executableURL = URL(fileURLWithPath: "/bin/chmod")
        chmod.arguments = ["+a", "user:\(NSUserName()) allow write", fixture.documentURL.path]
        try chmod.run(); chmod.waitUntilExit()
        #expect(chmod.terminationStatus == 0)
        try FileManager.default.setAttributes([.posixPermissions: 0o400],
                                               ofItemAtPath: fixture.documentURL.path)
        defer { try? FileManager.default.setAttributes([.posixPermissions: 0o600],
                                                        ofItemAtPath: fixture.documentURL.path) }
        let bytes = try #require(documentBytes(fixture.documentURL))
        let stamp = try modificationDate(fixture.documentURL)

        let store = XRGSettingsStore(fileURL: fixture.documentURL, defaults: fixture.defaults, catalog: catalog, legacyDomain: [:])
        #expect(store.loadProblem == nil)
        try store.set("general.window.title", .string("Held in memory"))
        #expect(store.loadProblem != nil)  // the mode bit, not the ACL, decides
        #expect(documentBytes(fixture.documentURL) == bytes)
        #expect(try modificationDate(fixture.documentURL) == stamp)
        let mode = try #require(FileManager.default.attributesOfItem(atPath: fixture.documentURL.path)[.posixPermissions] as? Int)
        #expect(mode == 0o400)
    }

    // MARK: Unmapped keys are an explicit allowlist (fix round 2, finding 2)

    /// Only the allowlisted non-setting state (Sparkle `SU*`, AppKit
    /// `NSWindow Frame *`, `unminimizedFrame`, `tempLocationsAutoconfigured`,
    /// the eleven recorded AI usage keys) keeps its `NSUserDefaults` home
    /// on the document backend; every other unmapped key is refused and
    /// never written anywhere.
    @Test func setLegacyValuesAllowsOnlyExcludedStateAndRefusesOtherUnmappedKeys() throws {
        let fixture = try Fixture(); defer { fixture.cleanUp() }
        let defaults = fixture.defaults
        let catalog = try self.catalog()
        let store = XRGSettingsStore(fileURL: fixture.documentURL, defaults: defaults, catalog: catalog, legacyDomain: [:])
        #expect(store.loadProblem == nil)
        let documentBytesBefore = try #require(documentBytes(fixture.documentURL))

        let refused = store.setLegacyValues([
            "SUScheduledCheckInterval": 86400,
            "NSWindow Frame XRGGraph": "{{1, 2}, {140, 700}}",
            "unminimizedFrame": "{{10, 20}, {300, 400}}",
            "tempLocationsAutoconfigured": true,
            "aiTokensDailyPromptTokens": 41,
            "aiTokensLastNotifyDate": Date(timeIntervalSince1970: 1),
            "windowTitle": "Converted",  // mapped: goes to the document only
            "completelyMadeUpKey": "refused",
            "anotherUnknownLatch": 3,
        ])

        // The refused keys are reported back and never reach the domain...
        #expect(refused.sorted() == ["anotherUnknownLatch", "completelyMadeUpKey"])
        let domain = defaults.persistentDomain(forName: fixture.domain) ?? [:]
        #expect((domain["SUScheduledCheckInterval"] as? NSNumber)?.intValue == 86400)
        #expect((domain["aiTokensDailyPromptTokens"] as? NSNumber)?.intValue == 41)
        #expect((domain["aiTokensLastNotifyDate"] as? Date) != nil)
        #expect((domain["tempLocationsAutoconfigured"] as? NSNumber)?.boolValue == true)
        #expect(domain["NSWindow Frame XRGGraph"] as? String == "{{1, 2}, {140, 700}}")
        #expect(domain["unminimizedFrame"] as? String == "{{10, 20}, {300, 400}}")
        #expect(domain["completelyMadeUpKey"] == nil)
        #expect(domain["anotherUnknownLatch"] == nil)
        // ...and never reach the document either.
        #expect(store.value("general.window.title") == .string("Converted"))
        let text = String(data: try #require(documentBytes(fixture.documentURL)), encoding: .utf8) ?? ""
        #expect(documentBytes(fixture.documentURL) != documentBytesBefore)
        #expect(!text.contains("completelyMadeUpKey"))
        #expect(!text.contains("anotherUnknownLatch"))
        // A refusal is not a load problem: the document stays the source of truth.
        #expect(store.loadProblem == nil)
    }

    // MARK: The recorded AI usage keys are allowlisted by exact key (fix round 3)

    /// The recorded AI usage data is allowlisted by EXACT key — the eleven
    /// keys docs/settings-inventory.md enumerates (the three daily counters,
    /// the three by-model and three by-provider dictionaries, and the
    /// `aiTokensDailyDate` / `aiTokensLastNotifyDate` dates) — never by
    /// prefix: an unknown key sharing the `aiTokens` prefix is refused like
    /// any other unmapped key and reaches neither the persistent domain nor
    /// the document, while every recorded key keeps its `NSUserDefaults` home.
    @Test func recordedAIUsageKeysAreAllowedAndUnknownAITokensKeysAreRefused() throws {
        let fixture = try Fixture(); defer { fixture.cleanUp() }
        let defaults = fixture.defaults
        let catalog = try self.catalog()
        let store = XRGSettingsStore(fileURL: fixture.documentURL, defaults: defaults, catalog: catalog, legacyDomain: [:])
        #expect(store.loadProblem == nil)
        let documentBytesBefore = try #require(documentBytes(fixture.documentURL))

        let refused = store.setLegacyValues([
            "aiTokensDailyUnclassifiedTokens": 3,
            "aiTokensDailyPromptTokens": 41,
            "aiTokensDailyCompletionTokens": 7,
            "aiTokensDailyModelUnclassifiedTokens": ["gpt": 1],
            "aiTokensDailyModelPromptTokens": ["gpt": 2],
            "aiTokensDailyModelCompletionTokens": ["gpt": 3],
            "aiTokensDailyProviderUnclassifiedTokens": ["openai": 1],
            "aiTokensDailyProviderPromptTokens": ["openai": 2],
            "aiTokensDailyProviderCompletionTokens": ["openai": 3],
            "aiTokensDailyDate": Date(timeIntervalSince1970: 100),
            "aiTokensLastNotifyDate": Date(timeIntervalSince1970: 200),
            "aiTokensMadeUpSetting": "shares the prefix but is not recorded usage",
        ])

        // The made-up key sharing the prefix is refused and absent from the
        // persistent domain; every recorded key is still allowed and lands.
        #expect(refused == ["aiTokensMadeUpSetting"])
        let domain = defaults.persistentDomain(forName: fixture.domain) ?? [:]
        #expect(domain["aiTokensMadeUpSetting"] == nil)
        #expect((domain["aiTokensDailyUnclassifiedTokens"] as? NSNumber)?.intValue == 3)
        #expect((domain["aiTokensDailyPromptTokens"] as? NSNumber)?.intValue == 41)
        #expect((domain["aiTokensDailyCompletionTokens"] as? NSNumber)?.intValue == 7)
        #expect((domain["aiTokensDailyModelUnclassifiedTokens"] as? [String: Any])?.count == 1)
        #expect((domain["aiTokensDailyModelPromptTokens"] as? [String: Any])?.count == 1)
        #expect((domain["aiTokensDailyModelCompletionTokens"] as? [String: Any])?.count == 1)
        #expect((domain["aiTokensDailyProviderUnclassifiedTokens"] as? [String: Any])?.count == 1)
        #expect((domain["aiTokensDailyProviderPromptTokens"] as? [String: Any])?.count == 1)
        #expect((domain["aiTokensDailyProviderCompletionTokens"] as? [String: Any])?.count == 1)
        #expect((domain["aiTokensDailyDate"] as? Date)?.timeIntervalSince1970 == 100)
        #expect((domain["aiTokensLastNotifyDate"] as? Date)?.timeIntervalSince1970 == 200)
        // Nothing in the call maps to the catalog, so the document is
        // untouched — the refused key never reaches it either.
        #expect(documentBytes(fixture.documentURL) == documentBytesBefore)
        let text = String(data: try #require(documentBytes(fixture.documentURL)), encoding: .utf8) ?? ""
        #expect(!text.contains("aiTokensMadeUpSetting"))
        #expect(store.loadProblem == nil)
    }

    // MARK: The delegate's launch restoration and shutdown leave the file alone (fix round 2, finding 3)

    /// The real delegate paths — `applicationDidFinishLaunching`'s collapsed
    /// restore and sensors-window reopen, and the shutdown path through
    /// `cleanupBeforeExiting` — leave a document-backed settings file's bytes
    /// and mtime untouched.
    @Test func documentBackedDelegateLaunchRestoreAndShutdownLeaveFileUnchanged() throws {
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

        let store = XRGSettingsStore(fileURL: fixture.documentURL, defaults: fixture.defaults, catalog: catalog, legacyDomain: [:])
        let settings = XRGSettings(store: store)
        let window = XRGGraphWindow(contentRect: NSRect(x: 100, y: 200, width: 600, height: 900),
                                     defaults: fixture.defaults, center: NotificationCenter(), scheduleTimers: false)
        window.appSettings = settings
        let background = XRGBackgroundView(frame: NSRect(origin: .zero, size: window.frame.size),
                                           defaults: fixture.defaults)
        window.contentView?.addSubview(background)
        background.awakeFromNib()
        var loadedNibs: [String] = []
        let delegate = XRGAppDelegate(defaults: fixture.defaults,
                                      loadNib: { name, _ in loadedNibs.append(name) },
                                      presentWindow: { _, _ in },
                                      activateApplication: {},
                                      sensorProvider: { _ in [] })
        delegate.xrgGraphWindow = window
        window.controller = delegate

        // The real restoration paths the delegate runs at launch: the
        // collapsed window is re-collapsed and the sensors window reopened
        // (the extracted `restoreLaunchState` the delegate calls).
        delegate.restoreLaunchState()
        #expect(loadedNibs == ["Sensors"])
        #expect(window.minimized && background.clickedMinimized)
        #expect(settings.sensorsWindowOpen && settings.windowCollapsed)
        #expect(documentBytes(fixture.documentURL) == bytes)
        #expect(try modificationDate(fixture.documentURL) == stamp)

        // Shutdown: the power-off path expands without persisting the latch.
        delegate.workspaceWillPowerOff(Notification(name: NSWorkspace.willPowerOffNotification))
        #expect(settings.windowCollapsed)  // the latch survived the exit
        #expect(documentBytes(fixture.documentURL) == bytes)
        #expect(try modificationDate(fixture.documentURL) == stamp)
        background.removeFromSuperview()
        window.close()
    }

    // MARK: Durable-write failures leave the destination unchanged (fix round 2, finding 4)

    /// The store's file write is a seam: a forced `open` or `fsync` failure
    /// stops the replacement, removes the temporary file, surfaces the
    /// problem through `loadProblem`, and leaves the destination's bytes
    /// and mtime untouched.
    @Test func durableWriteFailuresLeaveDestinationUnchanged() throws {
        let fixture = try Fixture(); defer { fixture.cleanUp() }
        let catalog = try self.catalog()
        try XRGSettingsDocument.defaults(catalog: catalog, platform: .macos).serialized()
            .write(to: fixture.documentURL)
        let bytes = try #require(documentBytes(fixture.documentURL))
        let stamp = try modificationDate(fixture.documentURL)

        // A failure before anything is written (the `open` the default write
        // performs for its fsync).
        var store = XRGSettingsStore(fileURL: fixture.documentURL, defaults: fixture.defaults, catalog: catalog, legacyDomain: [:])
        store.durableWrite = { _, _ in
            throw NSError(domain: NSPOSIXErrorDomain, code: Int(EIO),
                           userInfo: [NSLocalizedDescriptionKey: "forced open failure"])
        }
        try store.set("general.window.title", .string("Held by open failure"))
        #expect(store.value("general.window.title") == .string("Held by open failure"))
        #expect(store.loadProblem != nil)
        #expect(documentBytes(fixture.documentURL) == bytes)
        #expect(try modificationDate(fixture.documentURL) == stamp)
        #expect(try FileManager.default.contentsOfDirectory(
            atPath: fixture.documentURL.deletingLastPathComponent().path) == ["settings.json"])

        // A failure after the bytes are written but before the sync completes.
        store = XRGSettingsStore(fileURL: fixture.documentURL, defaults: fixture.defaults, catalog: catalog, legacyDomain: [:])
        store.durableWrite = { temporary, contents in
            try contents.write(to: temporary)
            throw NSError(domain: NSPOSIXErrorDomain, code: Int(EIO),
                           userInfo: [NSLocalizedDescriptionKey: "forced fsync failure"])
        }
        try store.set("general.window.title", .string("Held by sync failure"))
        #expect(store.value("general.window.title") == .string("Held by sync failure"))
        #expect(store.loadProblem != nil)
        #expect(documentBytes(fixture.documentURL) == bytes)
        #expect(try modificationDate(fixture.documentURL) == stamp)
        #expect(try FileManager.default.contentsOfDirectory(
            atPath: fixture.documentURL.deletingLastPathComponent().path) == ["settings.json"])
    }

    // MARK: Fresh installs are not upgrades (fix round 2, finding 5)

    /// A fresh install — an empty or absent 0.2.2 persistent domain and no
    /// settings.json — gets the catalog defaults (netMinGraphScale 0); only
    /// an existing 0.2.2 installation migrates the effective registered
    /// defaults (netMinGraphScale 1024).
    @Test func freshInstallKeepsCatalogDefaultsAndUpgradeTakesEffectiveValues() throws {
        let fresh = try Fixture(); defer { fresh.cleanUp() }
        let catalog = try self.catalog()
        // No 0.2.2 installation: the injected suite's persistent domain is empty.
        let freshStore = XRGSettingsStore(fileURL: fresh.documentURL, defaults: fresh.defaults,
                                          catalog: catalog, legacyDomain: [:])
        #expect(freshStore.loadProblem == nil)
        #expect(freshStore.value("graphs.network.minimum_scale") == .int(0))
        #expect(freshStore.value("graphs.stock.visible") == .bool(false))
        // The suite's persistent domain is never written (registration
        // leakage from other suites in the test process rules out
        // `object(forKey:)`; the persistent domain is the user's own).
        #expect((fresh.defaults.persistentDomain(forName: fresh.domain) ?? [:])["netMinGraphScale"] == nil)

        // An existing 0.2.2 installation: the domain is non-empty, so the
        // effective registered defaults migrate (through the store).
        let upgrade = try Fixture(); defer { upgrade.cleanUp() }
        let legacy: [String: Any] = ["windowTitle": "My XRG"]
        upgrade.seed(legacy)
        let upgradeStore = XRGSettingsStore(fileURL: upgrade.documentURL, defaults: upgrade.defaults,
                                            catalog: catalog, legacyDomain: legacy)
        #expect(upgradeStore.loadProblem == nil)
        #expect(upgradeStore.value("general.window.title") == .string("My XRG"))
        #expect(upgradeStore.value("graphs.network.minimum_scale") == .int(1024))
        #expect(upgradeStore.value("graphs.stock.visible") == .bool(true))
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
        fixture.seed(excluded)
        let catalog = try self.catalog()

        let store = XRGSettingsStore(fileURL: fixture.documentURL, defaults: defaults, catalog: catalog, legacyDomain: [:])
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