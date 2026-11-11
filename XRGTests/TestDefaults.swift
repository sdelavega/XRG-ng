// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Stephen de la Vega.
import Foundation

/// A throwaway `UserDefaults` suite owned by a single test.
///
/// `UserDefaults(suiteName:)` writes a real `.plist` into `~/Library/Preferences`.
/// Calling `removePersistentDomain(forName:)` on its own leaves that file (and
/// any private per-domain folder) on disk, so a long-lived test run accumulates
/// thousands of them. `TestDefaults` removes every artefact and makes cleanup
/// automatic and hard to forget:
///
///  - Hold the instance for as long as the domain is needed. ARC calls `deinit`
///    when the test function returns **or throws**, so no exit path leaks — even
///    a test that never wrote an explicit cleanup call.
///  - `cleanUp()` is idempotent and available for tests that want to tear the
///    domain down early (mirrors the old `defer { removePersistentDomain }`).
///
/// Usage:
/// ```swift
/// let t = TestDefaults(prefix: "XRG.cpuView.")
/// let domain = t.domain, defaults = t.defaults
/// defer { t.cleanUp() }   // optional; deinit is the safety net
/// ```
final class TestDefaults {
    let domain: String
    let defaults: UserDefaults

    /// Build a unique, disposable domain as `prefix + UUID`.
    convenience init(prefix: String) {
        self.init(domain: prefix + UUID().uuidString)
    }

    /// Use an exact name when the code under test binds to a specific suite.
    /// The name still has to be a recognisably disposable test domain.
    init(domain: String) {
        Self.assertDisposable(domain)
        guard let defaults = UserDefaults(suiteName: domain) else {
            preconditionFailure("TestDefaults: could not open suite \(domain)")
        }
        self.domain = domain
        self.defaults = defaults
    }

    deinit { cleanUp() }

    private var cleaned = false
    /// Remove the domain from cfprefsd and delete both on-disk artefacts.
    func cleanUp() {
        guard !cleaned else { return }
        cleaned = true
        defaults.removePersistentDomain(forName: domain)
        defaults.synchronize()
        let fm = FileManager.default
        let home = fm.homeDirectoryForCurrentUser
        let plist = home.appendingPathComponent("Library/Preferences/\(domain).plist")
        try? fm.removeItem(at: plist)
        try? fm.removeItem(at: home.appendingPathComponent("Library/Application Support/XRG-ng-Private/\(domain)"))
        // `removePersistentDomain` empties the domain but leaves it registered
        // with cfprefsd, which later rewrites an empty "tombstone" .plist.
        // `/usr/bin/defaults delete` drops the domain for good. `domain` is
        // validated to carry a UUID and never be the real com.sdelavega.xrg,
        // so this can only ever target a throwaway test domain. Best-effort.
        let task = Process()
        task.executableURL = URL(fileURLWithPath: "/usr/bin/defaults")
        task.arguments = ["delete", domain]
        task.standardOutput = FileHandle.nullDevice
        task.standardError = FileHandle.nullDevice
        do {
            try task.run()
            task.waitUntilExit()
        } catch {
            // best-effort only
        }
        try? fm.removeItem(at: plist)
    }

    /// Guard rail: never the real application domain, and always a name that
    /// carries a UUID or an explicit test marker. Because `cleanUp()` deletes
    /// `~/Library/Preferences/<domain>.plist`, this proves it can never target
    /// a real preferences file such as `com.sdelavega.xrg.plist`.
    private static func assertDisposable(_ domain: String) {
        precondition(domain != "com.sdelavega.xrg",
                     "TestDefaults refuses the real com.sdelavega.xrg domain")
        let uuid = domain.range(
            of: #"[0-9A-Fa-f]{8}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{12}"#,
            options: .regularExpression) != nil
        let marker = domain.range(
            of: #"test|spec|fixture|fake|stub|mock|sample|smoke|pdtest|xrgtest|upgrade|probe"#,
            options: [.regularExpression, .caseInsensitive]) != nil
        precondition(uuid || marker,
                     "TestDefaults requires a UUID or an explicit test marker: \(domain)")
    }
}
