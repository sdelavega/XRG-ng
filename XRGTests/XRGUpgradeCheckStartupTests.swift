// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Stephen de la Vega.

import Foundation
import Testing
@testable import XRGCore

/// The narrowly gated upgrade-check startup path (Task 13 fix round 2,
/// finding 1): only a renamed, non-production bundle whose environment names
/// a disposable ``com.sdelavega.xrg.upgradecheck.`` domain runs the real
/// document-backed first-launch migration, over that disposable domain, into
/// the R11 private path. Every test injects a disposable domain/suite and a
/// scratch document URL; none reads or writes the real ``com.sdelavega.xrg``
/// defaults domain or its production settings file.
@Suite @MainActor
struct XRGUpgradeCheckStartupTests {
    private let production = "com.sdelavega.xrg"

    private func disposableDomain() -> String {
        XRGSettingsStore.upgradeCheckDomainPrefix + UUID().uuidString
    }

    /// One disposable suite + scratch document URL, removed afterwards. The
    /// suite name is a disposable (non-production) domain, so nothing here can
    /// resolve to the real production preferences.
    private struct Fixture {
        let domain: String
        let defaults: UserDefaults
        let documentURL: URL

        init(domain: String) throws {
            self.domain = domain
            defaults = try #require(UserDefaults(suiteName: domain))
            let root = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
                .appendingPathComponent("xrg-0.2.3-task-13-upgradecheck", isDirectory: true)
                .appendingPathComponent(domain, isDirectory: true)
            try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
            documentURL = root.appendingPathComponent("settings.json")
        }

        var preferencesURL: URL {
            FileManager.default.homeDirectoryForCurrentUser
                .appendingPathComponent("Library/Preferences/\(domain).plist")
        }

        /// Seed the suite's persistent domain and flush it to cfprefsd so the
        /// store's ``persistentDomain(forName:)`` read sees the values.
        func seed(_ values: [String: Any]) {
            for (key, value) in values { defaults.set(value, forKey: key) }
            defaults.synchronize()
        }

        func cleanUp() {
            defaults.removePersistentDomain(forName: domain)
            // Best-effort: ask cfprefsd to drop the disposable domain too, so a
            // targeted run does not leave an empty {} plist / `defaults domains`
            // tombstone behind. Never production: domain is upgrade-check private.
            let task = Process()
            task.executableURL = URL(fileURLWithPath: "/usr/bin/defaults")
            task.arguments = ["delete", domain]
            task.standardOutput = FileHandle.nullDevice
            task.standardError = FileHandle.nullDevice
            do {
                try task.run()
                task.waitUntilExit()
            } catch {
                // best-effort only; the harness sweep removes any tombstone.
            }
            try? FileManager.default.removeItem(at: preferencesURL)
            try? FileManager.default.removeItem(at: documentURL.deletingLastPathComponent())
        }
    }

    // MARK: The gate (pure, fully injectable)

    /// The production bundle id ignores the variable completely, even when it
    /// names a perfectly well-formed disposable domain.
    @Test func productionBundleIdentifierIgnoresTheEnvironmentVariable() {
        let key = XRGSettingsStore.upgradeCheckEnvironmentKey
        let domain = disposableDomain()
        #expect(XRGSettingsStore.upgradeCheckSourceDomain(
            bundleIdentifier: production, environment: [key: domain]) == nil)
        #expect(XRGSettingsStore.upgradeCheckSourceDomain(
            bundleIdentifier: nil, environment: [key: domain]) == nil)
        // The factory is nil too, so the production app can never enter this
        // path (and never read the production domain through the convenience
        // initializer). The document URL is injected so no real path is used.
        let fixture = try? Fixture(domain: domain)
        defer { fixture?.cleanUp() }
        if let fixture {
            #expect(XRGSettingsStore.upgradeCheckStore(
                bundleIdentifier: production, environment: [key: domain],
                defaults: fixture.defaults, documentURL: fixture.documentURL) == nil)
        }
    }

    /// A non-matching prefix is ignored: the production domain, other XRG
    /// domains, foreign domains and the prefix without its trailing dot.
    @Test func nonMatchingPrefixIsIgnored() {
        let renamed = "com.sdelavega.XRG-ng.Upgradecheck." + UUID().uuidString
        let key = XRGSettingsStore.upgradeCheckEnvironmentKey
        let bad = [
            production,
            "com.sdelavega.xrg.other." + UUID().uuidString,
            "com.example.upgradecheck." + UUID().uuidString,
            "evil." + XRGSettingsStore.upgradeCheckDomainPrefix + UUID().uuidString,
            "com.sdelavega.xrg.upgradecheck",  // missing the trailing dot
        ]
        for value in bad {
            #expect(XRGSettingsStore.upgradeCheckSourceDomain(
                bundleIdentifier: renamed, environment: [key: value]) == nil, "\(value)")
            #expect(XRGSettingsStore.upgradeCheckStore(
                bundleIdentifier: renamed, environment: [key: value]) == nil)
        }
    }

    /// An empty or absent variable is ignored; a matching one is accepted.
    @Test func emptyOrAbsentVariableIsIgnored() {
        let renamed = "com.sdelavega.XRG-ng.Upgradecheck." + UUID().uuidString
        let key = XRGSettingsStore.upgradeCheckEnvironmentKey
        #expect(XRGSettingsStore.upgradeCheckSourceDomain(bundleIdentifier: renamed, environment: [:]) == nil)
        #expect(XRGSettingsStore.upgradeCheckSourceDomain(bundleIdentifier: renamed, environment: [key: ""]) == nil)
        #expect(XRGSettingsStore.upgradeCheckStore(bundleIdentifier: renamed, environment: [:]) == nil)
        #expect(XRGSettingsStore.upgradeCheckStore(bundleIdentifier: renamed, environment: [key: ""]) == nil)
        let good = disposableDomain()
        #expect(XRGSettingsStore.upgradeCheckSourceDomain(
            bundleIdentifier: renamed, environment: [key: good]) == good)
    }

    // MARK: A matching prefix runs the real migration into the private path

    /// A matching prefix migrates the given disposable domain into the R11
    /// private path: the factory reads ``persistentDomain(forName:)`` of the
    /// disposable suite, runs the real first-launch migration, and writes a
    /// document carrying a distinctive marker. The default (non-injected) file
    /// URL for a renamed bundle resolves under ``XRG-ng-Private``, never the
    /// production settings file.
    @Test func matchingPrefixMigratesDisposableDomainIntoThePrivatePath() throws {
        let domain = disposableDomain()
        let fixture = try Fixture(domain: domain); defer { fixture.cleanUp() }
        let marker = "UpgradeCheck-" + UUID().uuidString
        fixture.seed(["windowTitle": marker, "borderWidth": 7])

        let privateURL = XRGSettingsStore.sharedDocumentURL(bundleIdentifier: domain)
        #expect(privateURL.path.hasSuffix("Application Support/XRG-ng-Private/\(domain)/settings.json"))
        #expect(privateURL != XRGSettingsStore.sharedDocumentURL(bundleIdentifier: production))
        #expect(!privateURL.path.contains("/XRG-ng/settings.json"))

        // The default (no documentURL) path is the private R11 store; inject a
        // scratch URL so the test writes nowhere near ~/Library.
        let store = try #require(XRGSettingsStore.upgradeCheckStore(
            bundleIdentifier: domain,
            environment: [XRGSettingsStore.upgradeCheckEnvironmentKey: domain],
            defaults: fixture.defaults, documentURL: fixture.documentURL))
        #expect(store.isDocumentBacked)
        #expect(store.loadProblem == nil)
        #expect(FileManager.default.fileExists(atPath: fixture.documentURL.path))
        #expect(store.value("general.window.title") == .string(marker))
        #expect(store.value("general.window.border_width") == .int(7))

        // Migration only READS the disposable domain; it never adds or removes
        // a key there (the real com.sdelavega.xrg domain is never involved).
        let after = fixture.defaults.persistentDomain(forName: domain) ?? [:]
        #expect(after["windowTitle"] as? String == marker)
        #expect(after["borderWidth"] as? Int == 7)
    }

    /// The factory reads ONLY the disposable source domain, NEVER the
    /// production ``com.sdelavega.xrg`` domain: injecting a reader that records
    /// the requested name and returns a POISON value for any other domain
    /// proves the upgrade path names just the gated disposable domain.
    @Test func matchingPrefixNeverReadsTheProductionDomain() throws {
        let domain = disposableDomain()
        let fixture = try Fixture(domain: domain); defer { fixture.cleanUp() }
        let marker = "UpgradeCheck-" + UUID().uuidString
        fixture.seed(["windowTitle": marker])
        var readDomains: [String] = []

        let store = try #require(XRGSettingsStore.upgradeCheckStore(
            bundleIdentifier: domain,
            environment: [XRGSettingsStore.upgradeCheckEnvironmentKey: domain],
            defaults: fixture.defaults,
            documentURL: fixture.documentURL,
            legacyDomainFor: { name in
                readDomains.append(name)
                return name == domain
                    ? fixture.defaults.persistentDomain(forName: domain)
                    : ["windowTitle": "POISON-from-another-domain"]
            }))
        #expect(readDomains == [domain])
        #expect(store.value("general.window.title") == .string(marker))
        #expect(store.value("general.window.title") != .string("POISON-from-another-domain"))
    }
}
