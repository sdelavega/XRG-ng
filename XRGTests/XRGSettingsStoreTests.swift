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
        let t: TestDefaults
        let domain: String
        let defaults: UserDefaults
        let documentURL: URL

        init() throws {
            let t = TestDefaults(prefix: "XRG.settingsStore.")
            let domain = t.domain
            let defaults = t.defaults
            let root = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
                .appendingPathComponent("xrg-0.2.3-task-8", isDirectory: true)
                .appendingPathComponent(domain, isDirectory: true)
            try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
            self.t = t
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
            t.cleanUp()
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
        // No temporary sibling files are left in the document's directory;
        // the transaction's lock file stays (it is never deleted, R32).
        let siblings = try #require(try? FileManager.default.contentsOfDirectory(
            atPath: fixture.documentURL.deletingLastPathComponent().path))
        #expect(siblings.sorted() == ["settings.json", "settings.json.lock"])

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
    /// memory and on disk, and nothing is written. (Round 4's edition drove
    /// the conflict through `graphs.cpu.samples` under an externally stored
    /// time window; ruling R41, completed in round 5, made that pair a
    /// dormant value the core accepts, so the conflict is proven on a
    /// cross-setting combination the reloaded document would gain.)
    @Test func editConflictingWithExternalContentIsRefusedNotWritten() throws {
        let fixture = try Fixture(); defer { fixture.cleanUp() }
        let catalog = try self.catalog()
        let store = XRGSettingsStore(fileURL: fixture.documentURL, defaults: fixture.defaults,
                                      catalog: catalog, legacyDomain: [:])
        try store.set("weather.station", .string("KSEA"))
        // An external editor empties the station — valid on its own while
        // the collector is disabled — which the store's pending enable
        // would combine into a violation the reloaded document lacks.
        let external = """
        {
          "format": "xrg-ng-settings",
          "version": 1,
          "settings": {
            "weather.station": ""
          }
        }
        """
        try Data(external.utf8).write(to: fixture.documentURL)
        #expect(throws: XRGSettingsError.constraint) {
            try store.set("weather.enabled", .bool(true))
        }
        let bytes = try #require(documentBytes(fixture.documentURL))
        #expect(try storedValue("weather.station", in: bytes) as? String == "")
        #expect(try storedValue("weather.enabled", in: bytes) == nil,
                "the refused edit must not reach the file")
        // The store adopted the external station and serves it; the
        // refused enable is not stored.
        #expect(store.value("weather.station") == .string(""))
        #expect(store.value("weather.enabled") == .bool(false))
    }

    // MARK: Batch writes (round 5, ruling R37's one batch per action)

    /// Ruling R41, completed in round 5 — a batch is never refused because a
    /// dependent's dependency is off, in the starting or the final document.
    /// The macOS batch path is `setLegacyValues`: a 0.2.2 snapshot's CPU
    /// history pair riding ONE batch moves the window 5→10 while the count
    /// moves 100→200 — dormant-to-dormant, accepted whole, both entries on
    /// disk, one commit.
    @Test func dormantToDormantBatchThroughTheMacOSBatchPath() throws {
        let fixture = try Fixture(); defer { fixture.cleanUp() }
        let catalog = try self.catalog()
        let store = XRGSettingsStore(fileURL: fixture.documentURL, defaults: fixture.defaults,
                                     catalog: catalog, legacyDomain: [:])
        // The starting document holds the dormant pair: the window on, and
        // a count stored beneath it — a single set stores it (dormant,
        // allowed), exactly as the batch would.
        try store.set("graphs.cpu.time_window", .int(5))
        try store.set("graphs.cpu.samples", .int(100))
        let outcome = store.setLegacyValues([
            "XRGCPUView.HistoryMinutes.v1": 10,
            "XRGCPUView.HistorySamples.v1": 200,
        ])
        #expect(outcome.isEmpty, "the dormant-to-dormant batch was refused")
        #expect(store.value("graphs.cpu.time_window") == .int(10))
        #expect(store.value("graphs.cpu.samples") == .int(200))
        let bytes = try #require(documentBytes(fixture.documentURL))
        #expect(try storedValue("graphs.cpu.time_window", in: bytes) as? Int == 10)
        #expect(try storedValue("graphs.cpu.samples", in: bytes) as? Int == 200)
    }

    /// One batch is all-or-nothing: a refused part stores nothing and
    /// writes nothing — the other entry's change in the same batch never
    /// lands — and the refusal is the refused entry's own error; a write
    /// failure keeps BOTH parts off the disk together.
    @Test func setBatchAppliesWholeOrNothing() throws {
        let fixture = try Fixture(); defer { fixture.cleanUp() }
        let catalog = try self.catalog()
        let store = XRGSettingsStore(fileURL: fixture.documentURL, defaults: fixture.defaults,
                                     catalog: catalog, legacyDomain: [:])
        let empty = try #require(documentBytes(fixture.documentURL),
                                 "the first launch created the empty document")
        // A valid colour riding a wrong-typed partner is refused whole.
        #expect(throws: XRGSettingsError.wrongType) {
            try store.setBatch([
                XRGSettingsChange(id: "appearance.series2.color", value: .color([0.9, 0.1, 0.1, 1])),
                XRGSettingsChange(id: "general.window.title", value: .bool(true)),
            ])
        }
        #expect(store.value("appearance.series2.color") != .color([0.9, 0.1, 0.1, 1]),
                "the refused batch stored its valid part")
        #expect(store.value("general.window.title") != .bool(true),
                "the refused batch stored its other part")
        #expect(documentBytes(fixture.documentURL) == empty, "the refused batch wrote the file")

        // A batch that succeeds lands whole and writes once.
        var writes = 0
        store.durableWrite = { temporary, bytes in
            writes += 1
            try XRGSettingsStore.defaultDurableWrite(temporary, bytes)
        }
        try store.setBatch([
            XRGSettingsChange(id: "appearance.series2.color", value: .color([0.9, 0.1, 0.1, 1])),
            XRGSettingsChange(id: "themes.preset", value: .string("Custom")),
        ])
        #expect(writes == 1, "the batch took \(writes) commits, not one")
        #expect(store.value("appearance.series2.color") == .color([0.9, 0.1, 0.1, 1]))
        #expect(store.value("themes.preset") == .string("Custom"))

        // A write failure leaves NEITHER part on disk — all-or-nothing —
        // and reports through `loadProblem` like any refused destination.
        let landed = try #require(documentBytes(fixture.documentURL))
        store.durableWrite = { _, _ in
            throw NSError(domain: NSPOSIXErrorDomain, code: Int(EIO),
                           userInfo: [NSLocalizedDescriptionKey: "forced failure"])
        }
        try store.setBatch([
            XRGSettingsChange(id: "appearance.series1.color", value: .color([0.1, 0.9, 0.1, 1])),
            XRGSettingsChange(id: "themes.preset", value: .string("Custom")),
        ])
        #expect(store.loadProblem != nil, "the failed batch write was not reported")
        #expect(try documentBytes(fixture.documentURL) == landed,
                "the failed batch wrote the file")
    }

    // MARK: The locked write transaction (final review round 2, issue 1 / R32)

    /// Two stores over one document, interleaved: while store A holds its
    /// staged temporary file, store B's edit of an unrelated key lands on
    /// disk — a writer that bypasses the advisory lock exactly where a
    /// concurrent store would. A's last-moment identity re-check catches
    /// it, the transaction loops once through compare/re-apply over B's
    /// content, and both edits survive; B, a store with independent file
    /// handles, then reads and extends the merged document.
    @Test func interleavedStoresDoNotLoseEdits() throws {
        let fixture = try Fixture(); defer { fixture.cleanUp() }
        let catalog = try self.catalog()
        let a = XRGSettingsStore(fileURL: fixture.documentURL, defaults: fixture.defaults,
                                 catalog: catalog, legacyDomain: [:])
        let b = XRGSettingsStore(fileURL: fixture.documentURL, defaults: fixture.defaults,
                                 catalog: catalog, legacyDomain: [:])
        try a.set("general.window.title", .string("From A"))
        a.stageInterleave = {
            // B's concurrent write of an unrelated key, applied to the file
            // while A is between staging and the atomic replace: the
            // bytes B's own transaction would have written.
            let current = (try? Data(contentsOf: fixture.documentURL)) ?? Data()
            switch XRGSettingsDocument.load(current, catalog: catalog) {
            case .ok(var document, _):
                try? document.set("graphs.refresh", .double(2), catalog: catalog)
                try? document.serialized().write(to: fixture.documentURL)
            case .unreadable:
                Issue.record("B's concurrent write must be a loadable document")
            }
        }
        try a.set("general.window.border_width", .int(8))
        let bytes = try #require(documentBytes(fixture.documentURL))
        #expect(try storedValue("general.window.title", in: bytes) as? String == "From A")
        #expect(try storedValue("general.window.border_width", in: bytes) as? Int == 8)
        #expect(try storedValue("graphs.refresh", in: bytes) as? Double == 2,
                "the interleaved store's edit must survive")
        // B, the second store, adopts the merged content on its own write
        // and extends it: the merged document is everyone's base now.
        try b.set("graphs.refresh", .double(3))
        let merged = try #require(documentBytes(fixture.documentURL))
        #expect(try storedValue("general.window.title", in: merged) as? String == "From A")
        #expect(try storedValue("general.window.border_width", in: merged) as? Int == 8)
        #expect(try storedValue("graphs.refresh", in: merged) as? Double == 3)
    }

    /// A late external replacement during staging — malformed content the
    /// app cannot adopt, written between the staging and the replace — is
    /// never overwritten: the re-check catches it, the transaction loops
    /// into the compare, the load refuses it, the write stops and the same
    /// confirmation a load would surface appears.
    @Test func lateExternalMalformedReplacementDuringStagingIsNeverOverwritten() throws {
        let fixture = try Fixture(); defer { fixture.cleanUp() }
        let catalog = try self.catalog()
        let store = XRGSettingsStore(fileURL: fixture.documentURL, defaults: fixture.defaults,
                                     catalog: catalog, legacyDomain: [:])
        try store.set("general.window.title", .string("Mine"))
        store.stageInterleave = {
            try? Data("definitely not a settings document".utf8).write(to: fixture.documentURL)
        }
        try store.set("general.window.border_width", .int(8))
        #expect(store.loadProblem?.problem == XRGSettingsDiagnostic.malformed)
        let garbage = Data("definitely not a settings document".utf8)
        #expect(try #require(documentBytes(fixture.documentURL)) == garbage,
                "the late replacement is kept byte for byte")
        #expect(store.value("general.window.border_width") == .int(8), "the pending edit is kept in memory")
        // The user's confirmed replacement writes the in-memory document.
        store.replaceUnreadableFile()
        #expect(store.loadProblem == nil)
        let bytes = try #require(documentBytes(fixture.documentURL))
        #expect(try storedValue("general.window.border_width", in: bytes) as? Int == 8)
    }

    /// Another writer holding the lock past the bounded wait: the edit stays
    /// pending in memory, nothing is written, the persistence banner
    /// reports it, and the user's confirmation still writes the pending
    /// document once the other writer is gone (ruling R32).
    @Test func lockWaitExpiryKeepsTheEditPendingWithABanner() throws {
        let fixture = try Fixture(); defer { fixture.cleanUp() }
        let catalog = try self.catalog()
        let store = XRGSettingsStore(fileURL: fixture.documentURL, defaults: fixture.defaults,
                                     catalog: catalog, legacyDomain: [:])
        try store.set("general.window.title", .string("First"))
        let bytes = try #require(documentBytes(fixture.documentURL))
        // Hold the lock file the way another process would.
        let lockURL = fixture.documentURL.deletingLastPathComponent()
            .appendingPathComponent("settings.json.lock")
        let holder = open(lockURL.path, O_RDWR | O_CREAT, 0o600)
        #expect(holder >= 0)
        defer { close(holder) }
        #expect(flock(holder, LOCK_EX) == 0)
        defer { flock(holder, LOCK_UN) }
        try store.set("graphs.refresh", .double(2))
        #expect(store.loadProblem != nil, "the bounded wait expired and the banner reports it")
        #expect(documentBytes(fixture.documentURL) == bytes, "nothing was written")
        #expect(XRGSettingsValue.sameValue(store.value("graphs.refresh"), .double(2)),
                "the edit stays pending in memory")
        flock(holder, LOCK_UN)
        store.replaceUnreadableFile()
        #expect(store.loadProblem == nil)
        let written = try #require(documentBytes(fixture.documentURL))
        #expect(try storedValue("general.window.title", in: written) as? String == "First")
        #expect(try storedValue("graphs.refresh", in: written) as? Double == 2)
    }

    // MARK: Real competing transactions (round 3, ruling R39)

    /// Two REAL competing transactions — the same locked write path `set`
    /// runs, driven from two threads so they genuinely race for the
    /// `settings.json.lock` — both keep their unrelated edits: the file
    /// ends with both, the later transaction adopts the earlier one's
    /// content, and a third reader sees both (ruling R39).
    @Test func concurrentTransactionsKeepTheirUnrelatedEdits() throws {
        let fixture = try Fixture(); defer { fixture.cleanUp() }
        let catalog = try self.catalog()
        let a = XRGSettingsStore(fileURL: fixture.documentURL, defaults: fixture.defaults,
                                 catalog: catalog, legacyDomain: [:])
        let b = XRGSettingsStore(fileURL: fixture.documentURL, defaults: fixture.defaults,
                                 catalog: catalog, legacyDomain: [:])
        try a.set("general.window.title", .string("From A"))
        let group = DispatchGroup()
        let queue = DispatchQueue(label: "XRG.concurrentTransactions", attributes: .concurrent)
        // Each transaction is the same sequence `set` itself runs: mutate the
        // document, then persist with the re-apply closure — driven from two
        // threads so they genuinely race for the `settings.json.lock`.
        queue.async(group: group) {
            _ = a.locked.set("general.window.border_width", .int(8), catalog: catalog)
            _ = a.persist { (document: inout XRGSettingsDocument) throws(XRGSettingsError) in
                try document.set("general.window.border_width", .int(8), catalog: catalog)
            }
        }
        queue.async(group: group) {
            _ = b.locked.set("graphs.refresh", .double(2), catalog: catalog)
            _ = b.persist { (document: inout XRGSettingsDocument) throws(XRGSettingsError) in
                try document.set("graphs.refresh", .double(2), catalog: catalog)
            }
        }
        group.wait()
        let bytes = try #require(documentBytes(fixture.documentURL))
        #expect(try storedValue("general.window.title", in: bytes) as? String == "From A")
        #expect(try storedValue("general.window.border_width", in: bytes) as? Int == 8,
                "A's concurrent edit must survive B's transaction")
        #expect(try storedValue("graphs.refresh", in: bytes) as? Double == 2,
                "B's concurrent edit must survive A's transaction")
        // The later transaction adopted the earlier one's content: its
        // in-memory document carries both edits.
        let merged = try #require(documentBytes(fixture.documentURL))
        #expect(a.value("general.window.border_width") == .int(8))
        #expect(b.value("graphs.refresh") == .double(2))
        #expect(try storedValue("general.window.title", in: merged) != nil)
        // A third reader sees both edits.
        let reopened = XRGSettingsStore(fileURL: fixture.documentURL, defaults: fixture.defaults,
                                        catalog: catalog, legacyDomain: [:])
        #expect(reopened.value("general.window.title") == .string("From A"))
        #expect(XRGSettingsValue.sameValue(reopened.value("graphs.refresh"), .double(2)))
        #expect(reopened.value("general.window.border_width") == .int(8))
    }

    /// Two first launches of the same 0.2.2 installation: the first
    /// migrates and creates the document; the second finds the appeared
    /// file, adopts it and rewrites nothing — its own migration is dropped,
    /// never clobbered over the other's (ruling R39).
    @Test func twoFirstLaunchesConvergeOnOneMigratedFile() throws {
        let fixture = try Fixture(); defer { fixture.cleanUp() }
        let catalog = try self.catalog()
        let legacy: [String: Any] = ["windowTitle": "My XRG", "borderWidth": 7]
        fixture.seed(legacy)
        let first = XRGSettingsStore(fileURL: fixture.documentURL, defaults: fixture.defaults,
                                     catalog: catalog, legacyDomain: legacy)
        #expect(first.loadProblem == nil)
        let bytes = try #require(documentBytes(fixture.documentURL))
        let stamp = try modificationDate(fixture.documentURL)
        // The second launch, "concurrent" with the first: the file appeared
        // before its own migration write, so it adopts the file instead.
        let second = XRGSettingsStore(fileURL: fixture.documentURL, defaults: fixture.defaults,
                                       catalog: catalog, legacyDomain: legacy)
        #expect(second.loadProblem == nil)
        #expect(second.value("general.window.title") == .string("My XRG"))
        #expect(second.value("general.window.border_width") == .int(7))
        #expect(try documentBytes(fixture.documentURL) == bytes,
                "the second launch adopts the appeared file and rewrites nothing")
        #expect(try modificationDate(fixture.documentURL) == stamp)
    }

    /// Two first launches synchronized AFTER BOTH OBSERVED ABSENCE (round 4,
    /// ruling R39): the first launch is parked by the store's first-launch
    /// seam — absence observed, migration computed, nothing written — while
    /// the second launch performs its own full first launch: it observes the
    /// SAME absence (the first has written nothing yet) and migrates first.
    /// Releasing the first puts its migration transaction under contention
    /// with the second's appeared file: it ADOPTS the file — the identity
    /// re-apply over the loaded contents — never clobbers it, and both
    /// launches converge on the one migrated document.
    @Test func synchronizedFirstLaunchesBothObserveAbsenceAndAdoptUnderContention() throws {
        let fixture = try Fixture(); defer { fixture.cleanUp() }
        let catalog = try self.catalog()
        let legacy: [String: Any] = ["windowTitle": "Contended", "borderWidth": 7]
        fixture.seed(legacy)
        let box = FirstLaunchBox()
        XRGSettingsStore.firstLaunchInterleave = {
            // The second first launch runs INSIDE the first's seam: the first
            // observed absence and computed its migration but wrote nothing,
            // so the second observes the same absence and migrates first.
            XRGSettingsStore.firstLaunchInterleave = nil
            box.second = XRGSettingsStore(fileURL: fixture.documentURL, defaults: fixture.defaults,
                                           catalog: catalog, legacyDomain: legacy)
            box.observedAbsence = true
        }
        defer { XRGSettingsStore.firstLaunchInterleave = nil }
        let first = XRGSettingsStore(fileURL: fixture.documentURL, defaults: fixture.defaults,
                                     catalog: catalog, legacyDomain: legacy)
        #expect(box.observedAbsence, "both launches observed absence before either wrote")
        let second = try #require(box.second)
        #expect(first.loadProblem == nil)
        #expect(second.loadProblem == nil)
        // The first adopted the second's file: one converged document.
        #expect(first.locked.document == second.locked.document)
        #expect(first.value("general.window.title") == .string("Contended"))
        #expect(first.value("general.window.border_width") == .int(7))
        #expect(second.value("general.window.title") == .string("Contended"))
        // The file holds exactly the second's migration, and both stores
        // observe it as their baseline for the next compare.
        let bytes = try #require(documentBytes(fixture.documentURL))
        #expect(first.locked.observedBytes == bytes)
        #expect(second.locked.observedBytes == bytes)
        // A third reader sees the converged document.
        let third = XRGSettingsStore(fileURL: fixture.documentURL, defaults: fixture.defaults,
                                      catalog: catalog, legacyDomain: [:])
        #expect(third.value("general.window.title") == .string("Contended"))
        #expect(third.value("general.window.border_width") == .int(7))
    }

    /// The seam box: the second store and the absence flag, shared with the
    /// seam closure without capturing them as mutable locals.
    private final class FirstLaunchBox: @unchecked Sendable {
        var second: XRGSettingsStore?
        var observedAbsence = false
    }

    /// A destination that appears between the first launch's absence
    /// observation and its migration transaction (round 4, ruling R39): the
    /// seam parks the first launch exactly there, the test plants the
    /// appearing file, and the migration transaction must refuse it — adopt
    /// nothing, write nothing — leaving the appeared bytes untouched and
    /// surfacing the same confirmation a load would.
    @Test func destinationAppearingBeforeTheMigrationTransactionIsNeverOverwritten() throws {
        for appearing in ["malformed", "future"] {
            let fixture = try Fixture(); defer { fixture.cleanUp() }
            let catalog = try self.catalog()
            let legacy: [String: Any] = ["windowTitle": "Mine", "borderWidth": 7]
            fixture.seed(legacy)
            let appeared: Data
            let expectedProblem: String
            if appearing == "malformed" {
                appeared = Data("{\"format\": \"xrg-ng-settings\", \"version\": 1, \"settings\": {".utf8)
                expectedProblem = XRGSettingsDiagnostic.malformed
            } else {
                appeared = Data("""
                {
                  "format": "xrg-ng-settings",
                  "version": 2,
                  "settings": {
                    "general.window.title": "From the future"
                  }
                }
                """.utf8)
                expectedProblem = XRGSettingsDiagnostic.unsupportedVersion
            }
            let box = AppearedBox()
            XRGSettingsStore.firstLaunchInterleave = {
                XRGSettingsStore.firstLaunchInterleave = nil
                try? appeared.write(to: fixture.documentURL)
                box.planted = true
            }
            defer { XRGSettingsStore.firstLaunchInterleave = nil }
            let first = XRGSettingsStore(fileURL: fixture.documentURL, defaults: fixture.defaults,
                                         catalog: catalog, legacyDomain: legacy)
            #expect(box.planted)
            #expect(first.loadProblem?.problem == expectedProblem,
                    "the appeared \(appearing) destination is surfaced, never adopted")
            #expect(try #require(documentBytes(fixture.documentURL)) == appeared,
                    "the appeared file is kept byte for byte")
            // The pending migration stays in memory until the user confirms
            // the replacement.
            first.replaceUnreadableFile()
            #expect(first.loadProblem == nil)
            let written = try #require(documentBytes(fixture.documentURL))
            #expect(written != appeared)
            #expect(try storedValue("general.window.title",
                                    in: written) as? String == "Mine")
        }
    }

    /// The seam box for the appearing-destination test.
    private final class AppearedBox: @unchecked Sendable {
        var planted = false
    }

    /// A destination that becomes UNREADABLE at the final re-check —
    /// absent and unreadable are different states (ruling R39) — is never
    /// overwritten: the transaction aborts, the problem is surfaced like a
    /// write failure, and the pending edit stays in memory until the user
    /// confirms the replacement.
    @Test func destinationUnreadableAtTheFinalRecheckIsNeverOverwritten() throws {
        let fixture = try Fixture(); defer { fixture.cleanUp() }
        let catalog = try self.catalog()
        let store = XRGSettingsStore(fileURL: fixture.documentURL, defaults: fixture.defaults,
                                     catalog: catalog, legacyDomain: [:])
        try store.set("general.window.title", .string("Mine"))
        let bytes = try #require(documentBytes(fixture.documentURL))
        store.stageInterleave = {
            try? FileManager.default.setAttributes([.posixPermissions: 0o000],
                                                    ofItemAtPath: fixture.documentURL.path)
        }
        try store.set("general.window.border_width", .int(8))
        #expect(store.loadProblem?.problem == "unreadable:destination",
                "the unreadable destination is surfaced, not overwritten")
        #expect(store.value("general.window.border_width") == .int(8),
                "the pending edit stays in memory")
        try? FileManager.default.setAttributes([.posixPermissions: 0o600],
                                                ofItemAtPath: fixture.documentURL.path)
        #expect(try documentBytes(fixture.documentURL) == bytes,
                "the file's own bytes are untouched")
        store.replaceUnreadableFile()
        #expect(store.loadProblem == nil)
        #expect(try storedValue("general.window.border_width",
                                in: try #require(documentBytes(fixture.documentURL))) as? Int == 8)
    }

    /// A destination that is ABSENT at the final re-check — deleted under
    /// the lock by a writer that ignored it — is created again: the
    /// transaction loops once, adopts the absence, recreates the file with
    /// the pending edit applied, and nothing is lost (ruling R39).
    @Test func destinationAbsentAtTheFinalRecheckIsCreatedAgain() throws {
        let fixture = try Fixture(); defer { fixture.cleanUp() }
        let catalog = try self.catalog()
        let store = XRGSettingsStore(fileURL: fixture.documentURL, defaults: fixture.defaults,
                                     catalog: catalog, legacyDomain: [:])
        try store.set("general.window.title", .string("Mine"))
        store.stageInterleave = {
            try? FileManager.default.removeItem(at: fixture.documentURL)
        }
        try store.set("graphs.refresh", .double(2))
        #expect(store.loadProblem == nil)
        let bytes = try #require(documentBytes(fixture.documentURL))
        #expect(try storedValue("general.window.title", in: bytes) as? String == "Mine",
                "the earlier edit is not lost to the deletion")
        #expect(try storedValue("graphs.refresh", in: bytes) as? Double == 2)
    }

    /// The isolated factory migrates exactly the domain it is given: fixture
    /// data seeded into a disposable suite travels the real first-launch
    /// path, and nothing else is read.
    @Test func isolatedStoreMigratesTheNamedDisposableDomainOnly() throws {
        let fixture = try Fixture(); defer { fixture.cleanUp() }
        let catalog = try self.catalog()
        fixture.seed(["windowTitle": "Fixture Tool", "borderWidth": 3])
        let store = XRGSettingsStore.isolatedStore(fileURL: fixture.documentURL, defaults: fixture.defaults,
                                                   catalog: catalog, legacySourceDomain: fixture.domain)
        #expect(store.loadProblem == nil)
        #expect(store.value("general.window.title") == .string("Fixture Tool"))
        #expect(store.value("general.window.border_width") == .int(3))
    }

    /// A test that fails if the production domain is queried from a
    /// nonproduction tool: the injected reader records every domain the
    /// factory asks for and answers anything but the named one with a
    /// poison value, so a factory that ever consulted the production
    /// ``com.sdelavega.xrg`` domain — whose real contents differ from the
    /// fixture — would surface them here.
    @Test func isolatedStoreNeverQueriesAnotherDomain() throws {
        let fixture = try Fixture(); defer { fixture.cleanUp() }
        let catalog = try self.catalog()
        let fixtureDomain = "com.sdelavega.XRG-ng.ToolFixture." + UUID().uuidString
        var readDomains: [String] = []
        let store = XRGSettingsStore.isolatedStore(
            fileURL: fixture.documentURL, defaults: fixture.defaults, catalog: catalog,
            legacySourceDomain: fixtureDomain,
            legacyDomainFor: { name in
                readDomains.append(name)
                return name == fixtureDomain ? ["windowTitle": "Fixture Tool"] : ["windowTitle": "POISON"]
            })
        #expect(readDomains == [fixtureDomain],
                "the factory must ask for the named domain and nothing else")
        #expect(store.value("general.window.title") == .string("Fixture Tool"))
        #expect(store.value("general.window.title") != .string("POISON"))
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

    /// Round 2's issue 3, closed by the batch (ruling R37): the fan-source
    /// editor's multi-key write — `[nil, "fanA", nil]` passes the editor's
    /// own validity check — reaches the document only through one validated
    /// batch, so a secondary curve without a primary is refused whole:
    /// nothing is stored, nothing is written, the file keeps its bytes.
    @Test func fanSourceEditWithoutAPrimaryIsRefusedByTheValidatedBatch() throws {
        let fixture = try Fixture(); defer { fixture.cleanUp() }
        let catalog = try self.catalog()
        let store = XRGSettingsStore(fileURL: fixture.documentURL, defaults: fixture.defaults,
                                     catalog: catalog, legacyDomain: [:])
        try store.set("sources.fans.sensor1", .string("applesmc-fan1"))
        let bytes = try #require(documentBytes(fixture.documentURL))
        let stamp = try modificationDate(fixture.documentURL)
        // The editor's own `validate()` accepts this shape; the core's
        // combination rule does not, and the batch refuses it.
        store.storeHardwareSources(XRGHardwareSources(sources: [nil, "applesmc-fan1", "applesmc-fan2"]),
                                   legacyKey: "fanGraphSourcesV1")
        #expect(store.value("sources.fans.sensor1") == .string("applesmc-fan1"),
                "the primary the batch did not change survives")
        #expect(store.value("sources.fans.sensor2") == .null, "the refused secondary is not stored")
        #expect(store.value("sources.fans.sensor3") == .null, "the refused third curve is not stored")
        #expect(try documentBytes(fixture.documentURL) == bytes,
                "the refused batch writes nothing")
        #expect(try modificationDate(fixture.documentURL) == stamp)
        // The same slots with their primary are one batch and apply whole.
        store.storeHardwareSources(XRGHardwareSources(sources: ["applesmc-fan1", "applesmc-fan2", nil]),
                                   legacyKey: "fanGraphSourcesV1")
        #expect(store.value("sources.fans.sensor1") == .string("applesmc-fan1"))
        #expect(store.value("sources.fans.sensor2") == .string("applesmc-fan2"))
        #expect(try storedValue("sources.fans.sensor2",
                                in: try #require(documentBytes(fixture.documentURL))) as? String == "applesmc-fan2")
    }

    /// Round 4's test-preservation note: a Linux-only entry SURVIVES a macOS
    /// reset (review rr3): the macOS store's reset removes only the section's
    /// macOS entries — its own platform filter — so a Linux-only value the
    /// document carries (migration, a hand edit, another platform's write)
    /// is preserved in the file, exactly as the shared core's whole-section
    /// reset (SettingsDocumentTests) preserves nothing.
    @Test func linuxOnlyEntrySurvivesAMacOSReset() throws {
        let fixture = try Fixture(); defer { fixture.cleanUp() }
        let catalog = try self.catalog()
        let store = XRGSettingsStore(fileURL: fixture.documentURL, defaults: fixture.defaults,
                                     catalog: catalog, legacyDomain: [:])
        #expect(store.loadProblem == nil)
        // The general section's macOS entry, its Linux-only opacity, and an
        // unrelated section's entry, all stored through the same store.
        try store.set("general.window.border_width", .int(8))
        try store.set("general.window.opacity", .double(0.5))
        try store.set("graphs.refresh", .double(2))
        store.resetSection("general")
        #expect(store.value("general.window.border_width") == .int(4),
                "the macOS entry returns to its default")
        #expect(store.value("general.window.opacity") == .double(0.5),
                "the Linux-only entry survives the macOS reset")
        #expect(store.value("graphs.refresh") == .double(2),
                "other sections are untouched")
        // It survives a reopen: the file keeps it.
        let bytes = try #require(documentBytes(fixture.documentURL))
        #expect(try storedValue("general.window.opacity", in: bytes) as? Double == 0.5)
        #expect(try storedValue("general.window.border_width", in: bytes) == nil)
        let reopened = XRGSettingsStore(fileURL: fixture.documentURL, defaults: fixture.defaults,
                                         catalog: catalog, legacyDomain: [:])
        #expect(reopened.value("general.window.opacity") == .double(0.5))
        #expect(reopened.value("general.window.border_width") == .int(4))
    }

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
        ]).refusedKeys

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
        ]).refusedKeys

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
            atPath: fixture.documentURL.deletingLastPathComponent().path).sorted()
            == ["settings.json", "settings.json.lock"])

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
            atPath: fixture.documentURL.deletingLastPathComponent().path).sorted()
            == ["settings.json", "settings.json.lock"])
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