// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Stephen de la Vega.

import AppKit
import Darwin
import Foundation

/// The macOS settings store: the single place every catalog setting is read
/// from and written to (spec §2 and §4, decision D5).
///
/// It has two backends. The **document** backend is the application's: the
/// shared settings document at `~/Library/Application Support/XRG-ng/
/// settings.json` is the source of truth, written atomically, migrated once
/// from the 0.2.2 `NSUserDefaults` domain on the first launch and never
/// touching that domain again. An unreadable or malformed file is never
/// overwritten: the store runs on catalog defaults, exposes the problem as
/// `loadProblem`, and keeps changes in memory until the user confirms
/// `replaceUnreadableFile()`. The **legacy** backend backs the objects that
/// are constructed with an injected `UserDefaults` suite (tests and fixture
/// scenes): it reads and writes that suite live, exactly as 0.2.2 did, so
/// every existing suite-based behaviour is preserved unchanged.
///
/// Keys the catalog does not map — Sparkle's `SU*` state, AppKit window frames,
/// the `unminimizedFrame` restore rectangle, internal latches and recorded
/// usage data — are not settings: the allowlisted ones (`isExcludedLegacyKey`)
/// keep their home in `NSUserDefaults` on both backends; every other unmapped
/// key is refused on the document backend and never written anywhere.
@MainActor public final class XRGSettingsStore {
    /// Posted on the main thread after every stored change, with the changed
    /// id in `userInfo["id"]` and the store as the notification's object.
    public static let didChange: Notification.Name = Notification.Name("XRGSettingsStore.didChange")

    /// Posted on the main thread whenever `loadProblem` changes, with the
    /// store as the notification's object (final review, finding 3): a
    /// persistence failure or recovery is its own observable event, so an
    /// already-open settings section shows — and clears — the warning
    /// banner without waiting for the next section render.
    public static let persistenceStateDidChange: Notification.Name =
        Notification.Name("XRGSettingsStore.persistenceStateDidChange")

    /// The problem that stopped the settings file being loaded, nil when the
    /// document is the source of truth. Non-nil while the file is malformed,
    /// of an unknown format, of a newer version, or unreadable — including a
    /// file that loaded but cannot be written (every change is then held in
    /// memory and reported, exactly like an unreadable file).
    public private(set) var loadProblem: XRGSettingsDiagnostic? {
        didSet {
            if oldValue != loadProblem {
                NotificationCenter.default.post(name: Self.persistenceStateDidChange, object: self)
            }
        }
    }

    // All three are immutable and (except `defaults`, which is documented
    // thread-safe) Sendable, so the nonisolated legacy read below can use
    // them from any thread.
    /// The 0.2.2 defaults domain: read once by the document backend's
    /// migration, read live by the legacy backend, and written only by the
    /// legacy backend and for keys the catalog does not map.
    nonisolated(unsafe) public let defaults: UserDefaults
    public let catalog: XRGSettingsCatalog

    private enum Backend: Sendable {
        /// The shared document at this URL.
        case document(URL)
        /// Live `UserDefaults`, exactly as 0.2.2 behaved.
        case legacy
    }
    private let backend: Backend

    /// The bytes of the settings file this store last saw on disk, nil while
    /// no readable file existed (final review, finding 2 / ruling R28).
    /// Every write compares the file with these bytes first: a file someone
    /// else changed is never silently overwritten — it is reloaded, this
    /// store's pending edit re-applied over the new contents, and only then
    /// replaced. New unreadable content stops the write and surfaces the
    /// same confirmation a load would.
    private var observedBytes: Data?

    /// The document under its lock. Every read and write — including the
    /// main-actor ones — goes through the lock, so the nonisolated read the
    /// AI token observer makes from its worker threads cannot race a write.
    private final class LockedDocument: @unchecked Sendable {
        private let lock = NSLock()
        private var storage: XRGSettingsDocument
        init(_ document: XRGSettingsDocument) { storage = document }
        var document: XRGSettingsDocument { lock.withLock { storage } }
        func mutate(_ body: (inout XRGSettingsDocument) -> Void) { lock.withLock { body(&storage) } }
        func set(_ id: String, _ value: XRGSettingsValue, catalog: XRGSettingsCatalog) -> XRGSettingsError? {
            lock.lock()
            defer { lock.unlock() }
            do { try storage.set(id, value, catalog: catalog) }
            catch let error as XRGSettingsError { return error }
            return nil
        }
    }
    private let locked: LockedDocument

    // MARK: Creation

    /// The real XRG-ng application bundle's identifier: the only process
    /// whose shared store may use the production settings path.
    private nonisolated static let productionBundleIdentifier = "com.sdelavega.xrg"

    // MARK: The narrowly gated upgrade-check startup path (Task 13 fix round 2)

    /// Environment variable that opts a renamed (non-production) bundle into
    /// the upgrade-check startup migration. Its value MUST be a disposable
    /// domain beginning with ``upgradeCheckDomainPrefix``. The production
    /// bundle ignores it entirely (``upgradeCheckSourceDomain``).
    public nonisolated static let upgradeCheckEnvironmentKey = "XRG_UPGRADE_CHECK_SOURCE_DOMAIN"

    /// The exact prefix of the disposable domains the macOS upgrade check
    /// generates (``Tools/settings-upgrade-macos.py`` ``UPGRADE_PREFIX``). Only
    /// a source domain under this prefix is ever read by the upgrade-check
    /// path, so the real ``com.sdelavega.xrg`` domain can never be selected.
    public nonisolated static let upgradeCheckDomainPrefix = "com.sdelavega.xrg.upgradecheck."

    /// Decide whether the narrowly gated upgrade-check startup path applies.
    /// It holds ONLY for a non-production bundle whose environment names a
    /// disposable domain under ``upgradeCheckDomainPrefix``. The production
    /// bundle id ALWAYS ignores the variable; an absent, empty or wrong-prefix
    /// value is ignored. Pure and injectable so XRGTests can exercise every
    /// branch without touching any real defaults domain.
    public nonisolated static func upgradeCheckSourceDomain(
        bundleIdentifier: String?, environment: [String: String]) -> String? {
        guard let bundleIdentifier, bundleIdentifier != productionBundleIdentifier else { return nil }
        guard let domain = environment[upgradeCheckEnvironmentKey],
              domain.hasPrefix(upgradeCheckDomainPrefix) else { return nil }
        return domain
    }

    /// The store for the narrowly gated upgrade-check startup path. It reads
    /// ONLY the named disposable domain (``persistentDomain(forName:)`` of the
    /// gated source domain), NEVER the production ``com.sdelavega.xrg`` domain
    /// that the ``shared`` convenience initializer reads, migrates it once, and
    /// writes the document at the R11 private path for this bundle id
    /// (``sharedDocumentURL(bundleIdentifier:)``). Returns nil whenever the
    /// gate does not apply, so every other case keeps today's behaviour.
    ///
    /// ``defaults``/``documentURL``/``legacyDomainFor`` are injectable so
    /// XRGTests can use a disposable suite and a scratch file and prove the
    /// factory never names the production domain. Uses the internal init with
    /// an injected ``legacyDomain`` -- never ``XRGSettingsStore.shared``.
    @MainActor public static func upgradeCheckStore(
        bundleIdentifier: String? = Bundle.main.bundleIdentifier,
        environment: [String: String] = ProcessInfo.processInfo.environment,
        defaults: UserDefaults = .standard,
        documentURL: URL? = nil,
        legacyDomainFor: ((String) -> [String: Any]?)? = nil) -> XRGSettingsStore? {
        guard let sourceDomain = upgradeCheckSourceDomain(
            bundleIdentifier: bundleIdentifier, environment: environment) else { return nil }
        let url = documentURL ?? sharedDocumentURL(bundleIdentifier: bundleIdentifier)
        let legacyDomain: [String: Any]
        if let legacyDomainFor {
            legacyDomain = legacyDomainFor(sourceDomain) ?? [:]
        } else {
            legacyDomain = defaults.persistentDomain(forName: sourceDomain) ?? [:]
        }
        return XRGSettingsStore(fileURL: url, defaults: defaults,
                                catalog: loadCatalog(), legacyDomain: legacyDomain)
    }

    /// Where `shared` keeps the settings document. The real application
    /// bundle uses the spec's production path
    /// (`~/Library/Application Support/XRG-ng/settings.json`); any other
    /// bundle identifier — a private smoke bundle, a disposable app copy,
    /// an unbundled process — gets a private, bundle-scoped directory under
    /// `XRG-ng-Private`, so `shared` itself can never read or write the
    /// user's real settings file no matter who touches it (review summary:
    /// the store, not its callers, enforces the gate).
    static func sharedDocumentURL(bundleIdentifier: String?) -> URL {
        let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Application Support")
        if bundleIdentifier == productionBundleIdentifier {
            return support.appendingPathComponent("XRG-ng", isDirectory: true)
                .appendingPathComponent("settings.json")
        }
        return support.appendingPathComponent("XRG-ng-Private", isDirectory: true)
            .appendingPathComponent(bundleIdentifier ?? "unbundled", isDirectory: true)
            .appendingPathComponent("settings.json")
    }

    /// The application's store: the shared document at the spec's macOS path.
    public static let shared: XRGSettingsStore = {
        XRGSettingsStore(fileURL: sharedDocumentURL(bundleIdentifier: Bundle.main.bundleIdentifier),
                         defaults: .standard, catalog: loadCatalog())
    }()

    /// A document-backed store for non-production tools (final review,
    /// finding 6 / ruling R31): the caller names the legacy source domain
    /// EXPLICITLY, and that one domain is the only legacy state read —
    /// through `legacyDomainFor` when the tool injects its own reader.
    /// The factory never queries the production ``com.sdelavega.xrg`` domain
    /// the convenience initializer migrates, so a tool seeded with fixture
    /// data can never migrate the user's real preferences into its output.
    /// `defaults` still carries the allowlisted non-setting state (Sparkle's
    /// `SU*` keys, window frames, the recorded usage data) exactly as the
    /// convenience initializer's does.
    @MainActor public static func isolatedStore(
        fileURL: URL, defaults: UserDefaults, catalog: XRGSettingsCatalog,
        legacySourceDomain: String,
        legacyDomainFor: ((String) -> [String: Any]?)? = nil) -> XRGSettingsStore {
        let legacyDomain = legacyDomainFor.map { $0(legacySourceDomain) ?? [:] }
            ?? defaults.persistentDomain(forName: legacySourceDomain) ?? [:]
        return XRGSettingsStore(fileURL: fileURL, defaults: defaults, catalog: catalog, legacyDomain: legacyDomain)
    }

    private nonisolated(unsafe) static var legacyCache: [ObjectIdentifier: XRGSettingsStore] = [:]
    private nonisolated static let legacyCacheLock = NSLock()

    /// The store that keeps reading and writing the given defaults domain,
    /// exactly as 0.2.2 did. Instances are cached per domain so hot paths
    /// (graph tick history settings) do not reload the catalog each read.
    /// Any thread may construct one: the legacy backend only reads immutable
    /// state and the thread-safe `UserDefaults`.
    public nonisolated static func legacy(defaults: UserDefaults) -> XRGSettingsStore {
        legacyCacheLock.lock()
        defer { legacyCacheLock.unlock() }
        if let cached = legacyCache[ObjectIdentifier(defaults)] { return cached }
        let store = XRGSettingsStore(backend: .legacy, defaults: defaults, catalog: loadCatalog())
        legacyCache[ObjectIdentifier(defaults)] = store
        return store
    }

    /// The embedded catalog. Startup cannot proceed without it (decision D4).
    nonisolated static func loadCatalog() -> XRGSettingsCatalog {
        guard let catalog = try? XRGSettingsCatalog.load() else {
            fatalError("XRG-ng settings catalog is missing or invalid")
        }
        return catalog
    }

    /// Load the document backend: an existing settings file is read (its
    /// values are validated by the core, invalid ones fall back to their
    /// defaults with diagnostics); a file that cannot be read at all puts the
    /// store on catalog defaults with a `loadProblem`; a missing file is the
    /// first launch of 0.2.3, which migrates the 0.2.2 domain into a new
    /// document — once, without touching the domain — and writes it.
    public convenience init(fileURL: URL, defaults: UserDefaults, catalog: XRGSettingsCatalog) {
        // The 0.2.2 installation is the user's `com.sdelavega.xrg` persistent
        // domain (fix round 2, finding 5): empty or absent — a fresh install,
        // no settings.json — starts from the catalog defaults. Only ever read.
        self.init(fileURL: fileURL, defaults: defaults, catalog: catalog,
                  legacyDomain: defaults.persistentDomain(forName: Self.productionBundleIdentifier) ?? [:])
    }

    /// `legacyDomain` is the 0.2.2 `NSUserDefaults` domain's contents: its
    /// persistent state, exactly what `persistentDomain(forName:)` reads on a
    /// real installation. Empty means a fresh install. Internal so tests
    /// inject disposable domains and never touch the real one.
    init(fileURL: URL, defaults: UserDefaults, catalog: XRGSettingsCatalog,
         legacyDomain: [String: Any]) {
        backend = .document(fileURL)
        self.defaults = defaults
        self.catalog = catalog
        locked = LockedDocument(XRGSettingsDocument())
        var problem: XRGSettingsDiagnostic?
        let exists = FileManager.default.fileExists(atPath: fileURL.path)
        if exists, let data = try? Data(contentsOf: fileURL) {
            observedBytes = data
            switch XRGSettingsDocument.load(data, catalog: catalog) {
            case .ok(let document, let diagnostics):
                locked.mutate { $0 = document }
                Self.note(diagnostics)
            case .unreadable(let diagnostic):
                // A malformed or future file is never overwritten: the app
                // runs on defaults and reports the problem (spec §2).
                problem = diagnostic
            }
        } else if exists {
            // Present but unreadable (permissions): same rule as malformed.
            problem = XRGSettingsDiagnostic(id: nil, problem: "unreadable")
        } else {
            // First launch of 0.2.3: migrate the 0.2.2 domain once. A key
            // that fails conversion takes its default and is logged; launch
            // never blocks (spec §4). On an UPGRADE — the 0.2.2 domain is
            // non-empty — keys the user never persisted keep their EFFECTIVE
            // 0.2.2 values: the registered defaults 0.2.2 served are written
            // into the document wherever they differ from the catalog
            // default, so an upgrade changes nothing the user sees
            // (netMinGraphScale stays 1024, review issue 4). A FRESH install
            // (empty or absent domain) skips the baseline and starts from
            // the catalog defaults (netMinGraphScale 0, fix round 2,
            // finding 5).
            let registered: [String: Any] = legacyDomain.isEmpty
                ? [:]
                : XRGWindowPreferences.defaultValues(
                    metric: Locale.current.measurementSystem != .us, screen: NSScreen.main?.frame ?? .zero)
            let (migrated, diagnostics) = XRGSettingsMigration.fromMacDefaults(
                legacyDomain, registered: registered, catalog: catalog)
            locked.mutate { $0 = migrated }
            Self.note(diagnostics)
            if let error = persistError() {
                problem = XRGSettingsDiagnostic(id: nil, problem: "unreadable:\(error.domain)")
            }
        }
        loadProblem = problem
    }

    /// Any isolation may construct the legacy backend: it only reads the
    /// thread-safe `UserDefaults` through immutable state.
    private nonisolated init(backend: Backend, defaults: UserDefaults, catalog: XRGSettingsCatalog) {
        self.backend = backend
        self.defaults = defaults
        self.catalog = catalog
        locked = LockedDocument(XRGSettingsDocument())
    }

    private static func note(_ diagnostics: [XRGSettingsDiagnostic]) {
        for diagnostic in diagnostics {
            NSLog("XRG-ng settings: \(diagnostic.problem) for \(diagnostic.id ?? "document")")
        }
    }

    // MARK: Reading

    /// The effective value of a setting: the stored value, or the entry's
    /// catalog default. `null` (or the default) for an id the catalog does
    /// not know.
    public func value(_ id: String) -> XRGSettingsValue { settingsValue(id) }

    /// A read any thread can make (the AI token accounting observer is not
    /// main-actor confined). Safe because the document lives under its lock
    /// and the legacy path reads only immutable state.
    public nonisolated func settingsValue(_ id: String) -> XRGSettingsValue {
        guard case .legacy = backend else { return locked.document.value(id, catalog: catalog) }
        return legacyDocumentValue(id)
    }

    /// The value of a setting named by its legacy defaults key (the form the
    /// graph views and window still keep their per-view constants in). `null`
    /// when the catalog does not map the key at all.
    public nonisolated func value(legacyKey key: String) -> XRGSettingsValue {
        guard let entry = entry(legacyKey: key) else { return .null }
        return settingsValue(entry.id)
    }

    private nonisolated func legacyDocumentValue(_ id: String) -> XRGSettingsValue {
        guard let entry = catalog.entry(id), let key = Self.legacyKey(of: entry),
              let raw = defaults.object(forKey: key) else {
            return catalog.entry(id)?.defaultValue ?? .null
        }
        guard let value = XRGSettingsMigration.legacyValue(raw, for: entry),
              XRGSettingsDocument.validate(value, for: entry) == nil else {
            return entry.defaultValue
        }
        return value
    }

    // MARK: Writing

    /// Store a value for a setting, enforcing the entry's rules. The value
    /// is written atomically, and `didChange` is posted with the id. While
    /// the settings file is unreadable, the change is held in memory and the
    /// file is left untouched until the user confirms `replaceUnreadableFile()`.
    /// A value that equals the current one is a no-op — no write, no
    /// notification — so the launch paths that re-assert restored state
    /// (the sensors window, the collapse latch) leave settings.json
    /// untouched (spec §2: opening or restoring never rewrites the file).
    ///
    /// The write coordinates with everyone else who may touch the file
    /// (final review, finding 2 / ruling R28): a file that changed on disk
    /// since this store last saw it is reloaded, this edit re-applied over
    /// the new contents, and only then written — so another store, another
    /// process or an external editor never loses an edit. Content the new
    /// file holds that this store cannot adopt (malformed, a newer version)
    /// stops the write and surfaces the same confirmation a load would. An
    /// edit that no longer applies to the reloaded document is refused with
    /// the core's own error, exactly as it would be at the window.
    public func set(_ id: String, _ value: XRGSettingsValue) throws(XRGSettingsError) {
        guard let entry = catalog.entry(id) else { throw .unknownId }
        switch backend {
        case .legacy:
            guard let key = Self.legacyKey(of: entry) else { throw .unknownId }
            guard let raw = reverseLegacy(value, for: entry) else { throw .wrongType }
            defaults.set(raw, forKey: key)
        case .document:
            if XRGSettingsValue.sameValue(value, settingsValue(id)) { return }
            if let error = locked.set(id, value, catalog: catalog) { throw error }
            if loadProblem == nil {
                switch persist(reapplying: { (document: inout XRGSettingsDocument) throws(XRGSettingsError) in
                    try document.set(id, value, catalog: catalog)
                }) {
                case nil:
                    break
                case .failure(let error):
                    loadProblem = XRGSettingsDiagnostic(id: nil, problem: "unreadable:\(error.domain)")
                case .conflict(let error):
                    // The reloaded document refuses this edit; it is not
                    // stored, and the document is the reloaded one.
                    throw error
                case .unreadable(let diagnostic):
                    loadProblem = diagnostic
                }
            }
        }
        post(id)
    }

    /// Non-setting state that keeps its `NSUserDefaults` home on the document
    /// backend (docs/settings-inventory.md): Sparkle's `SU*` updater state,
    /// AppKit's `NSWindow Frame *` autodrive keys, the graph window's
    /// `unminimizedFrame` restore rectangle, the temperature sensor
    /// auto-configuration latch `tempLocationsAutoconfigured`, and the
    /// recorded AI usage data — allowlisted by EXACT key, the eleven keys
    /// docs/settings-inventory.md enumerates (the three daily counters, the
    /// by-model and by-provider dictionaries, and the `aiTokensDailyDate` /
    /// `aiTokensLastNotifyDate` dates), never by prefix: an unknown
    /// `aiTokens*` key is refused like any other unmapped key (fix round 3).
    /// This is the EXPLICIT allowlist: any other key the catalog does not
    /// map is refused — never written to the domain, never converted into
    /// the document (fix round 2, finding 2).
    static let excludedLegacyPrefixes = ["SU", "NSWindow Frame "]
    static let excludedLegacyKeys = [
        "unminimizedFrame", "tempLocationsAutoconfigured",
        // The recorded AI usage data: the exact keys the observer writes.
        "aiTokensDailyUnclassifiedTokens", "aiTokensDailyPromptTokens",
        "aiTokensDailyCompletionTokens",
        "aiTokensDailyModelUnclassifiedTokens", "aiTokensDailyModelPromptTokens",
        "aiTokensDailyModelCompletionTokens",
        "aiTokensDailyProviderUnclassifiedTokens", "aiTokensDailyProviderPromptTokens",
        "aiTokensDailyProviderCompletionTokens",
        "aiTokensDailyDate", "aiTokensLastNotifyDate",
    ]

    /// Whether one raw 0.2.2 defaults key is allowlisted excluded state.
    static func isExcludedLegacyKey(_ key: String) -> Bool {
        excludedLegacyKeys.contains(key) || excludedLegacyPrefixes.contains { key.hasPrefix($0) }
    }

    /// Store raw 0.2.2-style defaults values (a preferences snapshot, a theme,
    /// a graph presentation or process options blob). The legacy backend
    /// writes them to its domain verbatim, as 0.2.2 did; the document backend
    /// converts them through the migration into the document, and the
    /// conversion REPLACES what the keys' entries held: a snapshot whose
    /// value converts to the entry's default — or whose blob omits a field —
    /// clears the stored value, so restoring defaults cannot silently revert
    /// (review issue 3). On the document backend, keys the catalog maps with
    /// one entry or a whole blob never touch the domain; unmapped keys keep
    /// their `NSUserDefaults` home ONLY when they are allowlisted excluded
    /// state (`isExcludedLegacyKey`); every other unmapped key is refused —
    /// returned, logged, and never written anywhere (fix round 2,
    /// finding 2). Returns the refused keys (empty on the legacy backend).
    @discardableResult
    public func setLegacyValues(_ raw: [String: Any]) -> [String] {
        switch backend {
        case .legacy:
            for (key, value) in raw { defaults.set(value, forKey: key) }
            return []
        case .document:
            var refused: [String] = []
            for (key, value) in raw where ids(legacyKey: key).isEmpty {
                if Self.isExcludedLegacyKey(key) {
                    // Excluded state keeps its `NSUserDefaults` home.
                    defaults.set(value, forKey: key)
                } else {
                    // Not a setting and not allowlisted state: refuse it.
                    refused.append(key)
                }
            }
            if !refused.isEmpty {
                NSLog("XRG-ng settings: refusing unmapped legacy keys \(refused.sorted())")
            }
            let named = raw.keys.flatMap { ids(legacyKey: $0) }
                .sorted(by: XRGSettingsDocument.precedes)
            if !named.isEmpty {
                let (migrated, _) = XRGSettingsMigration.fromMacDefaults(raw, catalog: catalog)
                locked.mutate { document in
                    for id in named {
                        if let value = migrated.values[id] {
                            try? document.storeMigrated(id, value, catalog: catalog)
                        } else if let entry = catalog.entry(id) {
                            // The value converted to the entry's default (or the
                            // blob carries no such field): clear what was stored.
                            try? document.storeMigrated(id, entry.defaultValue, catalog: catalog)
                        }
                    }
                }
                if loadProblem == nil {
                    persistAndReport { document in
                        for id in named {
                            if let value = migrated.values[id] {
                                try? document.storeMigrated(id, value, catalog: self.catalog)
                            } else if let entry = self.catalog.entry(id) {
                                try? document.storeMigrated(id, entry.defaultValue, catalog: self.catalog)
                            }
                        }
                    }
                }
                for id in named { post(id) }
            }
            return refused.sorted()
        }
    }

    /// Restore every entry of one section to its default. Other sections and
    /// unknown keys at either level are not touched. A section already at
    /// its defaults has nothing to remove: the file keeps its bytes and mtime.
    /// Every backend posts per entry, so the live consumers (the settings
    /// window's controls, the app delegate's presentation sync) reconcile
    /// after a reset on either path (review issue 1).
    public func resetSection(_ section: String) {
        let entries = catalog.entries(section: section, platform: .macos)
        switch backend {
        case .legacy:
            for entry in entries {
                if let key = Self.legacyKey(of: entry) { defaults.removeObject(forKey: key) }
            }
        case .document:
            let storedSomething = entries.contains { locked.document.values[$0.id] != nil }
            locked.mutate { $0.resetSection(section, catalog: catalog, platform: .macos) }
            if storedSomething, loadProblem == nil {
                persistAndReport { document in
                    document.resetSection(section, catalog: self.catalog, platform: .macos)
                }
            }
        }
        for entry in entries { post(entry.id) }
    }

    /// The user confirmed replacing an unreadable settings file: write the
    /// current in-memory document over it and clear the problem. The user's
    /// confirmation is the point, so this write does not compare with what
    /// anyone else put on disk in the meantime.
    public func replaceUnreadableFile() {
        guard case .document = backend else { return }
        if let error = persistError() {
            loadProblem = XRGSettingsDiagnostic(id: nil, problem: "unreadable:\(error.domain)")
        } else {
            loadProblem = nil
        }
    }

    /// Persist the current document, re-applying `reapply` over a file that
    /// changed on disk, and surface the outcome through `loadProblem` (final
    /// review, findings 2 and 3). A plain failure keeps the pending change
    /// in memory and reports the write problem like an unreadable file.
    private func persistAndReport(_ reapply: @escaping (inout XRGSettingsDocument) -> Void) {
        switch persist(reapplying: reapply) {
        case nil:
            break
        case .failure(let error):
            loadProblem = XRGSettingsDiagnostic(id: nil, problem: "unreadable:\(error.domain)")
        case .conflict:
            // Unreachable for the callers that share this helper: their
            // re-applyments cannot be refused (no `depends` is checked).
            break
        case .unreadable(let diagnostic):
            loadProblem = diagnostic
        }
    }

    private func post(_ id: String) {
        NotificationCenter.default.post(name: Self.didChange, object: self, userInfo: ["id": id])
    }

    /// The store's durable file write: serialize the bytes to the temporary
    /// file, mode 0600, then fsync it so the rename cannot promote a
    /// half-written file (spec §2). Internal to the module so tests can
    /// force `open` and `fsync` failures (fix round 2, finding 4): a throw
    /// stops the write before the replacement, and the caller removes the
    /// temporary file.
    typealias DurableFileWrite = (_ temporary: URL, _ bytes: Data) throws -> Void
    nonisolated(unsafe) static let defaultDurableWrite: DurableFileWrite = { temporary, bytes in
        try bytes.write(to: temporary)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: temporary.path)
        let descriptor = open(temporary.path, O_RDONLY)
        guard descriptor >= 0 else {
            throw NSError(domain: NSPOSIXErrorDomain, code: Int(errno),
                          userInfo: [NSLocalizedDescriptionKey: "Could not open \(temporary.path) for fsync"])
        }
        let synced = fsync(descriptor) == 0
        close(descriptor)
        guard synced else {
            throw NSError(domain: NSPOSIXErrorDomain, code: Int(errno),
                          userInfo: [NSLocalizedDescriptionKey: "Could not sync \(temporary.path)"])
        }
    }
    /// The write `persistError()` uses. Injectable (internal) so tests can
    /// force the `open` and `fsync` failures the default checks. The default
    /// closure is stateless, so the unchecked isolation is sound.
    nonisolated(unsafe) var durableWrite: DurableFileWrite = XRGSettingsStore.defaultDurableWrite

    /// What a persistence attempt concluded (final review, findings 2 and 3):
    /// nil means the document reached the file.
    private enum PersistOutcome {
        /// The file or directory refused the write: nothing changed on disk,
        /// the pending edit stays in memory and `loadProblem` must report it.
        case failure(NSError)
        /// The file changed on disk into content this store cannot adopt —
        /// malformed or a newer version: the write stopped, the new content
        /// is protected exactly like an unreadable load, and `loadProblem`
        /// must surface the confirmation the spec requires.
        case unreadable(XRGSettingsDiagnostic)
        /// The file changed on disk and was adopted, but the pending edit no
        /// longer applies to the adopted document (the core refused it):
        /// nothing was written, the in-memory document is the adopted one,
        /// and the caller reports the refusal.
        case conflict(XRGSettingsError)
    }

    /// An advisory exclusive lock over one settings file, taken on a sibling
    /// lock file (`settings.json.lock`, created with mode 0600 and never
    /// deleted while held) for the duration of one read → compare →
    /// re-apply → stage → replace transaction (final review round 2,
    /// issue 1 / ruling R32): two stores in one process — or two
    /// processes — cannot both pass the comparison and then each replace
    /// the file, losing the other's edit. External editors that ignore the
    /// lock are covered by the last-moment identity re-check
    /// `persist(reapplying:)` makes before the atomic replace.
    private final class SettingsFileLock: @unchecked Sendable {
        private let descriptor: Int32
        private init(descriptor: Int32) { self.descriptor = descriptor }

        /// Acquire the lock, waiting at most `wait` seconds; nil means the
        /// bounded wait expired and the edit stays pending (ruling R32).
        static func acquire(url: URL, wait: TimeInterval) -> SettingsFileLock? {
            let descriptor = open(url.path, O_RDWR | O_CREAT, 0o600)
            guard descriptor >= 0 else { return nil }
            fchmod(descriptor, 0o600)
            let deadline = Date().addingTimeInterval(wait)
            repeat {
                if flock(descriptor, LOCK_EX | LOCK_NB) == 0 {
                    return SettingsFileLock(descriptor: descriptor)
                }
                usleep(20_000)
            } while Date() < deadline
            close(descriptor)
            return nil
        }

        func release() {
            flock(descriptor, LOCK_UN)
            close(descriptor)
        }

        deinit { close(descriptor) }
    }

    /// A test seam for ruling R32: called between staging the temporary file
    /// and the last-moment identity re-check, while the transaction lock is
    /// held, so tests can interleave another writer exactly there.
    var stageInterleave: (() -> Void)?

    /// Write the document atomically, coordinating with everyone else who
    /// may touch the file (final review, finding 2 / rulings R28 and R32):
    /// the whole read → compare → re-apply → stage → replace transaction
    /// runs under the advisory exclusive lock, and the destination's
    /// identity is re-checked immediately before the atomic replace.
    ///
    /// Before anything is replaced, the file is compared with the bytes this
    /// store last observed. Unchanged, the write proceeds. Changed, the new
    /// contents are loaded: readable and the same version, this store's
    /// pending edit — `reapply` — is applied over the adopted document
    /// before the write, so another store in this process, another process
    /// or an external editor never loses an edit to this one. Unreadable
    /// content stops the write with `.unreadable`. A pending edit the
    /// adopted document refuses stops it with `.conflict`.
    ///
    /// A destination that changed AGAIN during staging — a writer that
    /// ignored the lock — makes the transaction loop once through
    /// compare/re-apply over the new content; a second change stops the
    /// write and surfaces it. A destination that cannot be written — a
    /// settings file whose mode lacks owner write, or a directory that is
    /// not writable — is never replaced: the write is refused before any
    /// temporary file exists, the change stays in memory and `loadProblem`
    /// reports it, exactly like an unreadable file (review issue 1). The
    /// owner-write MODE BIT is checked explicitly, in addition to
    /// `access(W_OK)`: an ACL can grant write access while the bit is
    /// absent, and the bit is what the ruling requires (fix round 2,
    /// finding 1). Durability is checked too: a temporary file that cannot
    /// be opened or synced stops the write instead of proceeding to the
    /// replacement (review issue 10).
    private func persist(reapplying reapply: (inout XRGSettingsDocument) throws(XRGSettingsError) -> Void)
        -> PersistOutcome? {
        guard case .document(let fileURL) = backend else { return nil }
        if let error = Self.writePermissionError(fileURL) { return .failure(error) }
        guard let lock = SettingsFileLock.acquire(
            url: fileURL.deletingLastPathComponent()
                .appendingPathComponent(fileURL.lastPathComponent + ".lock"), wait: 2) else {
            // The bounded wait expired: another writer holds the file. The
            // edit stays pending in memory and the banner reports it,
            // exactly like a refused write (ruling R32).
            return .failure(NSError(domain: NSPOSIXErrorDomain, code: Int(EWOULDBLOCK),
                userInfo: [NSLocalizedDescriptionKey: "Another settings writer holds \(fileURL.path)"]))
        }
        defer { lock.release() }
        var document = locked.document
        for attempt in 0..<2 {
            // Read and compare: the file against the bytes this store last
            // saw (R28). A file that is gone has no content left to
            // preserve; a file that changed is adopted first.
            var onDisk: Data?
            if FileManager.default.fileExists(atPath: fileURL.path) {
                do {
                    onDisk = try Data(contentsOf: fileURL)
                } catch {
                    return .failure(error as NSError)
                }
            }
            if let current = onDisk, current != observedBytes {
                switch XRGSettingsDocument.load(current, catalog: catalog) {
                case .ok(let adopted, let diagnostics):
                    Self.note(diagnostics)
                    var reapplied = adopted
                    do {
                        try reapply(&reapplied)
                    } catch {
                        // The edit no longer applies to the new contents:
                        // keep what the new file holds, refuse the edit.
                        locked.mutate { $0 = adopted }
                        observedBytes = current
                        return .conflict(error)
                    }
                    document = reapplied
                    locked.mutate { $0 = reapplied }
                    // The adopted values belong to the document now; the
                    // window re-presents every control for them.
                    NotificationCenter.default.post(name: Self.didChange, object: self)
                case .unreadable(let diagnostic):
                    // External malformed or future content is never
                    // overwritten: surface the load's own confirmation.
                    return .unreadable(diagnostic)
                }
            }
            // Stage: the durable temporary file, still under the lock.
            let bytes = document.serialized()
            let temporary = fileURL.deletingLastPathComponent()
                .appendingPathComponent(".settings-\(UUID().uuidString).tmp")
            do {
                try durableWrite(temporary, bytes)
            } catch {
                try? FileManager.default.removeItem(at: temporary)
                return .failure(error as NSError)
            }
            stageInterleave?()
            // Re-check the destination's identity immediately before the
            // atomic replace, still under the lock (R32): a writer that
            // ignored the lock cannot be overwritten unnoticed.
            var recheck: Data?
            if FileManager.default.fileExists(atPath: fileURL.path) {
                recheck = try? Data(contentsOf: fileURL)
            }
            if recheck != onDisk {
                try? FileManager.default.removeItem(at: temporary)
                if attempt == 0 {
                    // The destination changed during staging: loop once
                    // through compare/re-apply over the new content.
                    continue
                }
                // It changed again: stop writing and surface it.
                return .failure(NSError(domain: NSPOSIXErrorDomain, code: Int(EAGAIN),
                    userInfo: [NSLocalizedDescriptionKey: "The settings file changed during staging"]))
            }
            do {
                _ = try FileManager.default.replaceItemAt(fileURL, withItemAt: temporary)
            } catch {
                try? FileManager.default.removeItem(at: temporary)
                return .failure(error as NSError)
            }
            // These are the bytes this store now observes on disk; the next
            // write compares against them (R28).
            observedBytes = bytes
            return nil
        }
        return .failure(NSError(domain: NSPOSIXErrorDomain, code: Int(EAGAIN),
            userInfo: [NSLocalizedDescriptionKey: "The settings file kept changing during staging"]))
    }

    /// The guard checks both persistence paths share: the directories must
    /// exist, the destination — when present — must be owner-writable by
    /// both `access(W_OK)` and its owner-write mode bit, and the directory
    /// must be writable. Returns the error that stops the write, nil when
    /// the destination may be replaced.
    private static func writePermissionError(_ fileURL: URL) -> NSError? {
        let directory = fileURL.deletingLastPathComponent()
        func denied(_ path: String) -> NSError {
            NSError(domain: NSPOSIXErrorDomain, code: Int(EACCES),
                    userInfo: [NSLocalizedDescriptionKey: "Permission denied: \(path)"])
        }
        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            if FileManager.default.fileExists(atPath: fileURL.path) {
                if access(fileURL.path, W_OK) != 0 { throw denied(fileURL.path) }
                // The owner-write mode bit itself must be present: effective
                // access (an ACL) is not enough (ruling B).
                var status = stat()
                guard stat(fileURL.path, &status) == 0, status.st_mode & S_IWUSR != 0 else {
                    throw denied(fileURL.path)
                }
            }
            if access(directory.path, W_OK) != 0 {
                throw denied(directory.path)
            }
            return nil
        } catch {
            return (error as? NSError) ?? denied(fileURL.path)
        }
    }

    /// The plain write of bytes over the settings file, used by the
    /// confirmed replacement of an unreadable file: the user has already
    /// decided the destination's fate, so no comparison or lock happens,
    /// but the observed bytes still follow what was written.
    private func persistError() -> NSError? {
        guard case .document(let fileURL) = backend else { return nil }
        if let error = writeBytes(locked.document.serialized()) { return error }
        return nil
    }

    /// The file write `persistError` uses: the guard checks, the atomic
    /// replacement and the observed-bytes bookkeeping. Returns the error
    /// that stopped the write, nil on success.
    private func writeBytes(_ bytes: Data) -> NSError? {
        guard case .document(let fileURL) = backend else { return nil }
        if let error = Self.writePermissionError(fileURL) { return error }
        let temporary = fileURL.deletingLastPathComponent()
            .appendingPathComponent(".settings-\(UUID().uuidString).tmp")
        do {
            try durableWrite(temporary, bytes)
            // A rename within the directory cannot leave a half-written
            // file, and replaces the settings file if it already exists.
            _ = try FileManager.default.replaceItemAt(fileURL, withItemAt: temporary)
        } catch {
            try? FileManager.default.removeItem(at: temporary)
            return error as NSError
        }
        // These are the bytes this store now observes on disk; the next
        // write compares against them (R28).
        observedBytes = bytes
        return nil
    }

    // MARK: Legacy keys

    /// The defaults key an entry's `legacy.macos` pointer reads — the same
    /// reduction the migration applies: the two JSON blobs are inventoried
    /// as paths into the blob, so the key is the pointer's first component.
    nonisolated static func legacyKey(of entry: XRGSettingsEntry) -> String? {
        guard let pointer = entry.legacy?.macos else { return nil }
        for blob in ["graphPresentationV1", "processInspectorV1"] where pointer.hasPrefix(blob + ".") {
            return blob
        }
        return pointer
    }

    /// Whether this store is the application's shared document (against the
    /// store built over an injected `UserDefaults` suite).
    public nonisolated var isDocumentBacked: Bool {
        if case .document = backend { return true }
        return false
    }

    /// The legacy key an entry id reads, when the catalog maps one.
    public func legacyKey(forId id: String) -> String? {
        catalog.entry(id).flatMap { Self.legacyKey(of: $0) }
    }

    /// The one entry that reads `key`, nil when none does (an excluded key)
    /// or several do (the blobs, which the migration decodes as a unit).
    /// Only immutable catalog state, so any thread may call it.
    public nonisolated func entry(legacyKey key: String) -> XRGSettingsEntry? {
        var matches: [XRGSettingsEntry] = []
        for entry in catalog.entries where Self.legacyKey(of: entry) == key {
            matches.append(entry)
            if matches.count > 1 { return nil }
        }
        return matches.first
    }

    /// The ids whose entries read `key` (several for the blobs).
    public nonisolated func ids(legacyKey key: String) -> [String] {
        catalog.entries.filter { Self.legacyKey(of: $0) == key }.map(\.id)
    }

    // MARK: Typed legacy-key helpers (the graph views keep their per-view keys)

    /// The id of a graph's visibility setting (`graphs.<g>.visible`); the
    /// blob's `tpu` is the catalog's `npu`.
    nonisolated static func visibilityID(_ graph: XRGGraphID) -> String {
        "graphs.\(graph == .tpu ? "npu" : graph.rawValue).visible"
    }

    /// A graph's visibility (`show<Name>Graph` before 0.2.3).
    func moduleVisible(_ graph: XRGGraphID) -> Bool {
        if case .bool(let visible) = settingsValue(Self.visibilityID(graph)) { return visible }
        return false
    }

    func setModuleVisible(_ graph: XRGGraphID, _ visible: Bool) {
        try? set(Self.visibilityID(graph), .bool(visible))
    }

    /// A boolean setting named by its legacy key, false when unset.
    public nonisolated func boolSetting(legacyKey key: String) -> Bool {
        if case .bool(let value) = value(legacyKey: key) { return value }
        return false
    }

    /// A whole-number setting named by its legacy key (graph history sizes
    /// and time windows), 0 when unset or invalid.
    public nonisolated func intSetting(legacyKey key: String) -> Int {
        switch value(legacyKey: key) {
        case .int(let number): return Int(number)
        case .double(let number): return Int(number)
        default: return 0
        }
    }

    /// A decimal setting named by its legacy key (saved module sizes), nil
    /// when unset (the caller supplies its fallback).
    public nonisolated func doubleSetting(legacyKey key: String) -> Double? {
        switch value(legacyKey: key) {
        case .int(let number): return Double(number)
        case .double(let number): return number
        default: return nil
        }
    }

    /// Store a whole-number or decimal value through its legacy key. Both
    /// backends validate it against the catalog entry first.
    public func storeSetting(_ value: Int, legacyKey key: String) {
        guard let entry = entry(legacyKey: key) else { return }
        try? set(entry.id, .int(Int64(value)))
    }

    public func storeSetting(_ value: Double, legacyKey key: String) {
        guard let entry = entry(legacyKey: key) else { return }
        try? set(entry.id, .double(value))
    }

    /// The saved CPU or GPU monitor selection for a source key
    /// (`XRGCPUView.Source.v1`, `XRGGPUView.Source.v1`).
    func monitorSource(legacyKey key: String) -> XRGMonitorSource {
        switch value(legacyKey: key) {
        case .string(let source): return XRGMonitorSource(source: source)
        case .int(let index): return XRGMonitorSource(source: String(index))
        default: return XRGMonitorSource()
        }
    }

    /// Store a monitor selection through its source key.
    func storeMonitorSource(_ source: XRGMonitorSource, legacyKey key: String) {
        guard let data = try? source.encoded() else { return }
        setLegacyValues([key: data])
    }

    /// The saved curve slots for a hardware sources key
    /// (`vramGraphSourcesV1`, `fanGraphSourcesV1`).
    func hardwareSources(legacyKey key: String) -> XRGHardwareSources {
        let ids = ids(legacyKey: key).sorted()
        guard !ids.isEmpty else { return XRGHardwareSources() }
        var slots: [String?] = []
        for id in ids {
            switch settingsValue(id) {
            case .string(let source): slots.append(source)
            default: slots.append(nil)
            }
        }
        while slots.count < 3 { slots.append(nil) }
        return XRGHardwareSources(sources: slots.count == 3 && slots.contains(where: { $0 != nil }) ? slots : nil)
    }

    /// Store curve slots through their sources key.
    func storeHardwareSources(_ sources: XRGHardwareSources, legacyKey key: String) {
        guard let data = try? sources.encoded() else { return }
        setLegacyValues([key: data])
    }

    /// The saved process inspector options (`processInspectorV1`), nil when
    /// the saved blob is invalid (the legacy backend's historical error state).
    func processOptions() -> XRGProcessOptions? {
        switch backend {
        case .legacy:
            guard let data = defaults.data(forKey: XRGProcessInspector.optionsKey) else { return XRGProcessOptions() }
            guard let saved = try? JSONDecoder().decode(XRGProcessOptions.self, from: data), saved.valid else { return nil }
            return saved
        case .document:
            // The options live in the document under their canonical ids
            // (`graphs.processes.*`); the legacy pointer only names the blob
            // they migrated from (review issue 5).
            var options = XRGProcessOptions()
            for (id, field) in [("graphs.processes.sort", "sort"), ("graphs.processes.filter", "search"),
                                ("graphs.processes.user", "user"), ("graphs.processes.limit", "limit")] {
                switch (field, settingsValue(id)) {
                case ("sort", .string(let sort)): options.sort = XRGProcessOptions.Sort(rawValue: sort) ?? options.sort
                case ("search", .string(let search)): options.search = search
                case ("user", .string(let user)): options.user = user
                case ("limit", .int(let limit)): options.limit = min(200, max(25, Int(limit)))
                default: break
                }
            }
            return options
        }
    }

    /// Store process options through their blob key.
    func storeProcessOptions(_ options: XRGProcessOptions) {
        guard let data = try? JSONEncoder().encode(options) else { return }
        setLegacyValues([XRGProcessInspector.optionsKey: data])
    }

    /// The saved curve slots for a sources key, or the decoding error the
    /// legacy blob produced (invalid saved choices keep their historical
    /// error state; the document cannot hold invalid slots).
    func hardwareSourcesResult(legacyKey key: String) -> Result<XRGHardwareSources, Error> {
        if case .document = backend { return .success(hardwareSources(legacyKey: key)) }
        guard let raw = defaults.object(forKey: key) else { return .success(XRGHardwareSources()) }
        guard let data = raw as? Data, let decoded = try? XRGHardwareSources(data: data) else {
            return .failure(XRGHardwareSources.invalid)
        }
        return .success(decoded)
    }

    /// The state of the saved GPU plot mode: valid, invalid (the legacy
    /// backend's historical warning state), or unset.
    enum PlotModeState {
        case valid(XRGGPUPlotMode)
        case invalid
        case unset
    }

    func plotMode(legacyKey key: String) -> PlotModeState {
        if case .document = backend {
            switch settingsValue(entry(legacyKey: key)?.id ?? "") {
            case .string("memory_and_activity"): return .valid(.memoryAndActivity)
            case .string("utilization"): return .valid(.utilization)
            case .null: return .unset
            default: return .invalid
            }
        }
        guard let raw = defaults.object(forKey: key) else { return .unset }
        guard let name = raw as? String, let mode = XRGGPUPlotMode(rawValue: name) else { return .invalid }
        return .valid(mode)
    }

    /// Store the GPU plot mode through its legacy key.
    func storePlotMode(_ mode: XRGGPUPlotMode, legacyKey key: String) {
        guard let entry = entry(legacyKey: key) else { return }
        try? set(entry.id, .string(mode == .memoryAndActivity ? "memory_and_activity" : "utilization"))
    }

    /// A boolean setting by its catalog id.
    public nonisolated func boolSetting(_ id: String) -> Bool {
        if case .bool(let value) = settingsValue(id) { return value }
        return false
    }

    /// A string setting by its catalog id, empty when unset.
    public nonisolated func stringSetting(_ id: String) -> String {
        if case .string(let value) = settingsValue(id) { return value }
        return ""
    }

    /// The legacy index a choice setting's option list gives a value
    /// (`names` in the order 0.2.2 indexed them).
    func choiceIndex(_ id: String, _ names: [String]) -> Int {
        guard case .string(let name) = settingsValue(id) else { return 0 }
        return names.firstIndex(of: name) ?? 0
    }

    /// The whole number at a whole-number setting by its catalog id.
    public nonisolated func intSetting(_ id: String) -> Int {
        switch settingsValue(id) {
        case .int(let value): return Int(value)
        case .double(let value): return Int(value)
        default: return 0
        }
    }

    /// Store a whole number at a setting by its catalog id.
    public func storeSetting(_ value: Int, id: String) {
        try? set(id, .int(Int64(value)))
    }

    /// The saved graph presentation as a whole (`graphPresentationV1`),
    /// rebuilt from the per-field entries on the document backend and from
    /// the blob on the legacy backend.
    func graphPreferences() -> XRGGraphPreferences {
        switch backend {
        case .legacy:
            if let data = defaults.data(forKey: XRGGraphPreferences.key),
               let saved = try? XRGGraphPreferences(data: data) {
                return saved
            }
            return XRGGraphPreferences()
        case .document:
            var preferences = XRGGraphPreferences()
            if case .string(let list) = settingsValue("graphs.order") {
                let ids = list.split(separator: ",").map(String.init).compactMap { name -> XRGGraphID? in
                    XRGGraphID(rawValue: name == "npu" ? "tpu" : name)
                }
                if !ids.isEmpty { preferences.order = ids }
            }
            for graph in XRGGraphID.allCases {
                var override = XRGGraphOverride()
                let prefix = "graphs.\(graph == .tpu ? "npu" : graph.rawValue)"
                if case .int(let height) = settingsValue(prefix + ".height") { override.height = Int(height) }
                if case .string(let curve) = settingsValue(prefix + ".style"),
                   let style = XRGCurveStyle(rawValue: curve) { override.curve = style }
                if case .string(let name) = settingsValue(prefix + ".effect"),
                   let index = Self.effectNames.firstIndex(of: name) { override.effect = index }
                for component in 0..<4 {
                    let suffix = component == 0 ? "background" : "series\(component)"
                    if case .color(let rgba) = settingsValue(prefix + ".color." + suffix) {
                        override.colors[component] = rgba
                    }
                }
                preferences[graph] = override
            }
            return preferences
        }
    }

    /// Store the whole graph presentation through its blob key.
    func storeGraphPreferences(_ preferences: XRGGraphPreferences) throws {
        guard let data = try? preferences.encoded() else { throw XRGGraphPreferences.invalid }
        setLegacyValues([XRGGraphPreferences.key: data])
    }

    /// The raw 0.2.2 defaults value that means the same as `value` for one
    /// entry: the reverse of the migration's transform. Only the legacy
    /// backend needs it (the document backend stores the converted value);
    /// nil when the value cannot be represented for the entry.
    private func reverseLegacy(_ value: XRGSettingsValue, for entry: XRGSettingsEntry) -> Any? {
        switch entry.legacy?.macosTransform {
        case nil:
            switch value {
            case .bool(let flag): return flag
            case .int(let number): return Int(number)
            case .double(let number): return number
            case .string(let text): return text
            case .null: return nil
            case .color(let rgba): return Self.colorArchive(rgba)
            }
        case "orientationFlag":
            return (value == .string("vertical")) ? true : false
        case "windowLevelIndex":
            switch value {
            case .string("normal"): return 0
            case .string("floating"): return 1
            case .string("background"): return 2
            default: return nil
            }
        case "collapseAnchorIndex":
            switch value {
            case .string("start"): return 0
            case .string("end"): return 1
            default: return nil
            }
        case "fahrenheitCelsiusIndex":
            switch value {
            case .string("fahrenheit"): return 0
            case .string("celsius"): return 1
            default: return nil
            }
        case "milesKilometersIndex":
            switch value {
            case .string("miles"): return 0
            case .string("kilometers"): return 1
            default: return nil
            }
        case "inchesHectopascalsIndex":
            switch value {
            case .string("inches"): return 0
            case .string("hectopascals"): return 1
            default: return nil
            }
        case "secondaryIndex":
            switch value {
            case .string("none"): return 0
            case .string("wind"): return 1
            case .string("humidity"): return 2
            case .string("visibility"): return 3
            case .string("dewpoint"): return 4
            case .string("pressure"): return 5
            default: return nil
            }
        case "stockTimeframeIndex":
            switch value {
            case .int(1): return 0
            case .int(3): return 1
            case .int(6): return 2
            case .int(12): return 3
            default: return nil
            }
        case "graphStyleIndex":
            switch value {
            case .string("normal"): return 0
            case .string("scanlines"): return 1
            case .string("pixel_grid"): return 2
            case .string("retro_dots"): return 3
            default: return nil
            }
        case "gpuPlotMode":
            switch value {
            case .string("memory_and_activity"): return "memoryAndActivity"
            case .string("utilization"): return "utilization"
            default: return nil
            }
        case "zeroToNull":
            switch value {
            case .null: return 0
            case .int(let number): return Int(number)
            default: return nil
            }
        case "networkInterfaceAll":
            switch value {
            case .null: return "All"
            case .string(let name): return name
            default: return nil
            }
        case "temperatureSensorSlot":
            switch value {
            case .null: return ""
            case .string(let key): return key
            default: return nil
            }
        case "themePreset":
            guard case .string(let name) = value else { return nil }
            return name
        case "nsColorArchive":
            guard case .color(let rgba) = value, rgba.count == 4 else { return nil }
            return Self.colorArchive(rgba)
        case "fontArchive":
            guard case .string(let descriptor) = value else { return nil }
            return Self.fontArchive(descriptor)
        case "cpuMonitorSource":
            switch value {
            case .null: return try? XRGMonitorSource().encoded()
            case .int(let index): return try? XRGMonitorSource(source: String(index)).encoded()
            default: return nil
            }
        case "gpuMonitorSource":
            switch value {
            case .null: return try? XRGMonitorSource().encoded()
            case .string(let source): return try? XRGMonitorSource(source: source).encoded()
            default: return nil
            }
        case "hardwareSourceSlot":
            let ids = ids(legacyKey: Self.legacyKey(of: entry) ?? "")
            guard ids.count == 3, let slot = entry.id.last(where: { $0.isNumber }).flatMap({ Int(String($0)) }),
                  (1...3).contains(slot) else { return nil }
            var sources: [String?] = []
            for id in ids.sorted() {
                switch settingsValue(id) {
                case .null: sources.append(nil)
                case .string(let source): sources.append(source)
                default: return nil
                }
            }
            return try? XRGHardwareSources(sources: sources).encoded()
        case "graphPreferenceHeight":
            guard case .int(let height) = value else { return nil }
            return reverseGraphPreferences { $0[graphID(of: entry)].height = Int(height) }
        case "graphPreferenceCurve":
            guard case .string(let curve) = value, let style = XRGCurveStyle(rawValue: curve) else { return nil }
            return reverseGraphPreferences { $0[graphID(of: entry)].curve = style }
        case "graphPreferenceEffect":
            guard case .string(let name) = value,
                  let index = Self.effectNames.firstIndex(of: name) else { return nil }
            return reverseGraphPreferences { $0[graphID(of: entry)].effect = index }
        case "graphPreferenceColor":
            let component = colorComponent(of: entry)
            switch value {
            case .null: return reverseGraphPreferences { $0[graphID(of: entry)].colors[component] = nil }
            case .color(let rgba): return reverseGraphPreferences { $0[graphID(of: entry)].colors[component] = rgba }
            default: return nil
            }
        case "graphOrder":
            guard case .string(let list) = value else { return nil }
            let ids = list.split(separator: ",").map(String.init).compactMap { name -> XRGGraphID? in
                (name == "npu" ? XRGGraphID.tpu : XRGGraphID(rawValue: name))
            }
            return reverseGraphPreferences { $0.order = ids }
        case "processInspectorField":
            guard let pointer = entry.legacy?.macos,
                  let field = pointer.split(separator: ".").last.map(String.init),
                  var current = savedProcessOptions() else { return nil }
            switch (field, value) {
            case ("sort", .string(let sort)): current.sort = XRGProcessOptions.Sort(rawValue: sort) ?? current.sort
            case ("search", .string(let search)): current.search = search
            case ("user", .string(let user)): current.user = user
            case ("limit", .int(let limit)): current.limit = Int(limit)
            default: return nil
            }
            return try? JSONEncoder().encode(current)
        default:
            return nil
        }
    }

    /// Rebuild the saved graph presentation blob with one field changed.
    /// Only the legacy backend calls this, so the current blob is read from
    /// the defaults domain it still lives in.
    private func reverseGraphPreferences(_ update: (inout XRGGraphPreferences) -> Void) -> Any? {
        var preferences = XRGGraphPreferences()
        if let data = defaults.data(forKey: XRGGraphPreferences.key),
           let saved = try? XRGGraphPreferences(data: data) {
            preferences = saved
        }
        update(&preferences)
        return try? preferences.encoded()
    }

    private func savedProcessOptions() -> XRGProcessOptions? {
        guard let data = defaults.data(forKey: XRGProcessInspector.optionsKey) else { return XRGProcessOptions() }
        guard let saved = try? JSONDecoder().decode(XRGProcessOptions.self, from: data), saved.valid else { return nil }
        return saved
    }

    /// The graph an entry's `legacy.macos` override path names:
    /// `graphPresentationV1.overrides.<graph>.<field>` — the blob's `tpu` is
    /// the catalog's `npu` (docs/settings-inventory.md).
    private func graphID(of entry: XRGSettingsEntry) -> XRGGraphID {
        guard let pointer = entry.legacy?.macos else { return .cpu }
        let components = pointer.split(separator: ".").map(String.init)
        guard components.count >= 3 else { return .cpu }
        return XRGGraphID(rawValue: components[2]) ?? .cpu
    }

    private func colorComponent(of entry: XRGSettingsEntry) -> Int {
        guard let pointer = entry.legacy?.macos else { return 0 }
        let components = pointer.split(separator: ".").map(String.init)
        guard let component = components.last.flatMap({ Int($0) }) else { return 0 }
        return min(3, max(0, component))
    }

    /// The effect names the graph options editor indexes, in blob order —
    /// the same four the migration's `graphStyleIndex` converts.
    private static let effectNames = ["normal", "scanlines", "pixel_grid", "retro_dots"]

    private static func colorArchive(_ rgba: [Double]) -> Data? {
        guard rgba.count == 4, rgba.allSatisfy({ $0.isFinite && (0...1).contains($0) }) else { return nil }
        let color = NSColor(srgbRed: rgba[0], green: rgba[1], blue: rgba[2], alpha: rgba[3])
        return try? NSKeyedArchiver.archivedData(withRootObject: color, requiringSecureCoding: true)
    }

    private static func fontArchive(_ descriptor: String) -> Data? {
        let parts = descriptor.split(separator: " ")
        guard let size = Double(parts.last ?? "") else { return nil }
        let name = parts.dropLast().joined(separator: " ")
        let font = name == "System" ? NSFont.systemFont(ofSize: CGFloat(size)) : NSFont(name: name, size: CGFloat(size))
        guard let font else { return nil }
        return try? NSKeyedArchiver.archivedData(withRootObject: font, requiringSecureCoding: true)
    }
}