// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Stephen de la Vega.

import Foundation

/// Why a version-40 file was refused before any of it was migrated.
public enum XRGSettingsMigrationError: Error, Equatable {
    /// The bytes are not a UTF-8 JSON object, so there is no version-40
    /// document to read. Linux runs its own upgrade chain to version 40
    /// before handing bytes to the core; anything else is a caller error.
    case malformedV40
}

/// One-shot migration of the 0.2.2 platform settings into the shared
/// settings document, and the Linux view of a document (spec §4).
///
/// Both migrations are driven entirely by the catalog's `legacy` fields:
/// every entry that names a legacy location is read there, converted by the
/// transform the entry names, validated by the document's rules and stored
/// only when it differs from the entry's default. A key whose conversion
/// fails takes its default and is reported as a diagnostic; migration never
/// blocks a launch, and the old storage is only ever read.
///
/// The named transforms are exactly the ones docs/settings-inventory.md
/// documents, as a closed switch: a name the catalog carries that the switch
/// does not know fails the catalog test (`implementsTransform`).
public enum XRGSettingsMigration {

    // MARK: Entry points

    /// The raw 0.2.2 defaults value of one entry, converted into its document
    /// value; nil when the conversion fails. The macOS settings store reads
    /// live `NSUserDefaults` domains with it (its legacy backend, which keeps
    /// injected defaults suites behaving exactly as 0.2.2 did); the document
    /// backend never needs it, because migration already converted those
    /// values once, at the first launch of 0.2.3.
    public static func legacyValue(_ raw: Any, for entry: XRGSettingsEntry) -> XRGSettingsValue? {
        convert(decodedLegacy(raw, fallback: nil, for: entry), entry).value
    }

    /// Migrate a 0.2.2 `NSUserDefaults` persistent domain — the dictionary
    /// `UserDefaults.dictionaryRepresentation()` or a defaults export decodes
    /// to — into the shared document. Keys the catalog does not map (Sparkle
    /// `SU*` state, AppKit window frames, latches, recorded data) are ignored:
    /// they are not settings and ignoring them is not a problem.
    ///
    /// `registered` carries the defaults 0.2.2 *registered* (its
    /// `XRGWindowPreferences.defaultValues`), so a mapped key the user never
    /// persisted keeps its effective 0.2.2 value: whenever that registered
    /// value differs from the entry's catalog default, it is written into the
    /// document (`storeMigrated` drops it when it is the same). An upgrade
    /// therefore changes nothing the user sees — `netMinGraphScale` stays at
    /// its registered 1024 instead of the catalog's 0, US-locale unit choices
    /// stay Fahrenheit, and so on. The old domain is only ever read.
    public static func fromMacDefaults(_ defaults: [String: Any], registered: [String: Any] = [:],
                                       catalog: XRGSettingsCatalog)
        -> (XRGSettingsDocument, [XRGSettingsDiagnostic]) {
        var document = XRGSettingsDocument()
        var diagnostics: [XRGSettingsDiagnostic] = []
        // Entries are processed in canonical id order so diagnostics are
        // deterministic. The legacy state is converted as it was saved, in
        // whatever combination it holds: `storeMigrated` applies each entry's
        // own rules but not its `depends` gating, which belongs to the
        // interactive settings window.
        for entry in catalog.entries.sorted(by: { XRGSettingsDocument.precedes($0.id, $1.id) }) {
            guard let key = macKey(of: entry) else { continue }
            if let raw = defaults[key] {
                // Decode with the reader 0.2.2 used, including that reader's
                // registered fallback, then apply the document transform.
                // A custom helper that rejects the stored text (for example
                // graphRefresh "0.5junk") therefore keeps the value 0.2.2
                // showed, not an NSString prefix and not a dropped default.
                let outcome = convert(decodedLegacy(raw, fallback: registered[key], for: entry), entry)
                store(outcome.value, unconvertibleColorSpace: outcome.unconvertibleColorSpace,
                      for: entry, into: &document, diagnostics: &diagnostics, catalog: catalog)
            } else if let raw = registered[key] {
                // The user never persisted this key: 0.2.2 served the
                // registered default for it, so the upgrade must keep that
                // effective value rather than the catalog's fresh-install one.
                let outcome = convert(decodedLegacy(raw, fallback: nil, for: entry), entry)
                if let value = outcome.value, XRGSettingsDocument.validate(value, for: entry) == nil {
                    store(value, unconvertibleColorSpace: nil,
                          for: entry, into: &document, diagnostics: &diagnostics, catalog: catalog)
                }
            }
        }
        return (document, diagnostics)
    }

    /// Migrate a version-40 Linux settings file, already upgraded by Rust's
    /// chain, into the shared document. Each `legacy.linux` pointer is
    /// resolved against the JSON the same way Rust's serde model names it.
    /// A pointer that is not there is the option it names, unset: serde
    /// omits a `None` option entirely (`skip_serializing_if`,
    /// xrg-linux/rust/src/weather.rs), so an absent pointer is handed to
    /// the entry's transform as a JSON null, and the transform decides what
    /// that means — the unit overrides read it as the document's null
    /// ("follow the unit system"). A transform that cannot read null leaves
    /// the entry at its default, exactly as before, and an absent value is
    /// never a failed conversion; a JSON null that is really written is a
    /// value like any other.
    public static func fromLinuxV40(_ json: Data, catalog: XRGSettingsCatalog) throws
        -> (XRGSettingsDocument, [XRGSettingsDiagnostic]) {
        guard let text = String(data: json, encoding: .utf8),
              case .object(let root)? = JSONValue.parse(text) else {
            throw XRGSettingsMigrationError.malformedV40
        }
        var document = XRGSettingsDocument()
        var diagnostics: [XRGSettingsDiagnostic] = []
        for entry in catalog.entries.sorted(by: { XRGSettingsDocument.precedes($0.id, $1.id) }) {
            guard let pointer = entry.legacy?.linux else { continue }
            let raw = value(at: pointer, in: .object(root))
            let value: XRGSettingsValue?
            if let name = entry.legacy?.linuxTransform, let transform = linuxTransform(named: name) {
                let converted = transform(raw ?? .null, entry)
                if converted == nil && raw == nil {
                    // The pointer is absent and the transform cannot read
                    // the unset option it stands for, so the entry keeps its
                    // default — silently, as before: an absent value is not
                    // a failed conversion.
                    continue
                }
                value = converted
            } else {
                guard let raw else { continue }
                value = XRGSettingsValue(json: raw)
            }
            store(value, unconvertibleColorSpace: nil,
                  for: entry, into: &document, diagnostics: &diagnostics, catalog: catalog)
        }
        return (document, diagnostics)
    }

    /// The Linux view of a document: the version-40-shaped JSON the Rust
    /// serde `Settings` struct deserialises (`xrg-linux/rust/src/settings.rs`),
    /// with every field of that struct filled from the document through the
    /// reverse of each entry's `legacy.linux` mapping and the catalog default
    /// where the document has no value. The `modules` array now maps every
    /// graph including Stocks (with its presentation) at its `graphs.order`
    /// position. The view also carries a top-level `stocks` object for the
    /// shared Stocks settings; every other name is a field of the Rust
    /// struct, because the Rust model rejects unknown ones.
    public static func linuxView(_ document: XRGSettingsDocument, catalog: XRGSettingsCatalog) -> Data {
        let fields: [String: JSONValue] = [
            "version": .number("40"),
            "theme": viewTheme(document, catalog),
            "modules": viewModules(document, catalog),
            "graph_height": viewInt("graphs.default_height", document, catalog),
            "graph_width": viewInt("general.window.graph_width", document, catalog),
            "sampling_interval_ms": viewSamplingInterval(document, catalog),
            "window_opacity": viewDouble("general.window.opacity", document, catalog),
            "window_size": viewWindowSize(document, catalog),
            "window_collapse": .object([
                "anchor": viewString("general.window.collapse_anchor", document, catalog),
                "collapsed": viewBool("general.window.collapsed", document, catalog),
                "expand_on_hover": viewBool("general.window.expand_on_hover", document, catalog),
            ]),
            "network_min_scale": viewInt("graphs.network.minimum_scale", document, catalog),
            "activity_bars": .object([
                "color": viewColor("graphs.activity_bars.color", document, catalog),
                "style": viewString("graphs.activity_bars.style", document, catalog),
                "use_series_colors": viewBool("graphs.activity_bars.use_series_colors", document, catalog),
                "visible": viewBool("graphs.activity_bars.visible", document, catalog),
            ]),
            "layout": viewString("general.window.orientation", document, catalog),
            "temperature_units": viewString("graphs.temperature.units", document, catalog),
            "metrics": .object([
                "battery_mode": viewString("graphs.battery.mode", document, catalog),
                "cpu": viewCpuCore(document, catalog),
                "cpu_history_minutes": viewInt("graphs.cpu.time_window", document, catalog),
                "cpu_history_samples": viewInt("graphs.cpu.samples", document, catalog),
                "disk": viewStringOrNull("sources.disk.device", document, catalog),
                "fan": viewStringOrNull("sources.fans.sensor1", document, catalog),
                "fan_extra": .array([
                    viewStringOrNull("sources.fans.sensor2", document, catalog),
                    viewStringOrNull("sources.fans.sensor3", document, catalog),
                ]),
                "gpu": viewStringOrNull("sources.gpu.device", document, catalog),
                "history_minutes": viewHistory(document, catalog, field: "time_window"),
                "history_samples": viewHistory(document, catalog, field: "samples"),
                "network": viewStringOrNull("sources.network.interface", document, catalog),
                "temperature": viewStringOrNull("sources.temperature.sensor1", document, catalog),
                "temperature_extra": .array([
                    viewStringOrNull("sources.temperature.sensor2", document, catalog),
                    viewStringOrNull("sources.temperature.sensor3", document, catalog),
                ]),
                "xe_pmu": viewBool("sources.gpu.xe_pmu", document, catalog),
            ]),
            "processes": .object([
                "filter": viewString("graphs.processes.filter", document, catalog),
                "limit": viewInt("graphs.processes.limit", document, catalog),
                "sort": viewString("graphs.processes.sort", document, catalog),
                "uid": viewUid(document, catalog),
            ]),
            "ai": .object([
                "accounting": .object([
                    "auto_reset": viewBool("ai.tracking.auto_reset", document, catalog),
                    "by_model": viewBool("ai.tracking.by_model", document, catalog),
                    "by_provider": viewBool("ai.tracking.by_provider", document, catalog),
                    "daily_budget": viewInt("ai.tracking.daily_budget", document, catalog),
                    "enabled": viewBool("ai.tracking.enabled", document, catalog),
                    "notifications": viewBool("ai.tracking.notifications", document, catalog),
                    "notify_percent": viewInt("ai.tracking.notify_percent", document, catalog),
                ]),
                "claude_database": viewStringOrNull("ai.claude.database_path", document, catalog),
                "claude_logs": viewStringOrNull("ai.claude.logs_path", document, catalog),
                "claude_source": viewString("ai.claude.source", document, catalog),
                "codex_logs": viewStringOrNull("ai.codex.logs_path", document, catalog),
                "enabled": .array([
                    viewBool("ai.sources.claude", document, catalog),
                    viewBool("ai.sources.codex", document, catalog),
                    viewBool("ai.sources.gemini", document, catalog),
                    viewBool("ai.sources.hermes", document, catalog),
                ]),
                "gemini_logs": viewStringOrNull("ai.gemini.logs_path", document, catalog),
                "hermes_database": viewStringOrNull("ai.hermes.database_path", document, catalog),
                "history_minutes": viewInt("graphs.ai.time_window", document, catalog),
                "history_samples": viewInt("graphs.ai.samples", document, catalog),
                "metrics_url": viewString("ai.metrics.url", document, catalog),
                "ollama": viewBool("ai.sources.ollama", document, catalog),
                "ollama_url": viewString("ai.ollama.url", document, catalog),
            ]),
            "ai_show_model_breakdown": viewBool("ai.display.breakdown", document, catalog),
            "weather": .object([
                "distance_units": viewUnits("weather.units.distance", document, catalog,
                                            metric: "kilometers", us: "miles"),
                "enabled": viewBool("weather.enabled", document, catalog),
                "history_hours": viewIntOrNull("weather.history_hours", document, catalog),
                "pressure_units": viewUnits("weather.units.pressure", document, catalog,
                                           metric: "hectopascals", us: "inches"),
                "refresh_minutes": viewInt("weather.refresh", document, catalog),
                "secondary": viewString("weather.secondary", document, catalog),
                "station": viewString("weather.station", document, catalog),
                "temperature_units": viewUnits("weather.units.temperature", document, catalog,
                                               metric: "celsius", us: "fahrenheit"),
                "units": viewString("weather.units.system", document, catalog),
                "wind_units": viewStringOrNull("weather.units.wind", document, catalog),
            ]),
            // Ruling R2: the shared Stocks settings ride along under their
            // catalog leaf names until the Rust model gains the field.
            "stocks": .object([
                "show_change": viewBool("stocks.show_change", document, catalog),
                "show_djia": viewBool("stocks.show_djia", document, catalog),
                "symbols": viewString("stocks.symbols", document, catalog),
                "timeframe": viewInt("stocks.timeframe", document, catalog),
            ]),
        ]
        let rendered = XRGSettingsDocument.render(.object(fields), indent: "")
        return Data((rendered + "\n").utf8)
    }

    /// Whether the closed transform switch knows `name` on `platform`. The
    /// catalog test uses this to fail when the catalog names a transform no
    /// build implements.
    public static func implementsTransform(named name: String, platform: XRGSettingsPlatform) -> Bool {
        switch platform {
        case .macos: return macosTransform(named: name) != nil
        case .linux: return linuxTransform(named: name) != nil
        }
    }

    // MARK: Migration pipeline

    /// The outcome of one macOS transform: the converted value, and — when
    /// the value could not be converted because the archived colour's space
    /// is unsupported — that space's diagnostic name. Both travel together
    /// from the transform into `store` as one local value: no shared or
    /// static state, so concurrent migrations (a regression test runs 200
    /// at once) can never read or clear each other's findings.
    private struct TransformOutcome {
        var value: XRGSettingsValue?
        var unconvertibleColorSpace: String?

        init(_ value: XRGSettingsValue?, unconvertibleColorSpace: String? = nil) {
            self.value = value
            self.unconvertibleColorSpace = unconvertibleColorSpace
        }
    }

    /// Lifts a plain transform into a `TransformOutcome` with no diagnostic:
    /// every transform but `nsColorArchive` converts or fails without naming
    /// a colour space.
    private static func outcome(_ transform: @escaping (Any, XRGSettingsEntry) -> XRGSettingsValue?)
        -> (Any, XRGSettingsEntry) -> TransformOutcome {
        { raw, entry in TransformOutcome(transform(raw, entry)) }
    }

    private static func store(_ value: XRGSettingsValue?, unconvertibleColorSpace: String?,
                              for entry: XRGSettingsEntry,
                              into document: inout XRGSettingsDocument,
                              diagnostics: inout [XRGSettingsDiagnostic], catalog: XRGSettingsCatalog) {
        guard let value else {
            let problem = unconvertibleColorSpace.map { "unsupported-color-space:\($0)" }
                ?? XRGSettingsDiagnostic.invalidValue
            diagnostics.append(XRGSettingsDiagnostic(id: entry.id, problem: problem))
            return
        }
        do {
            // Storing the entry's default removes the value again, so only
            // real customisations are ever written to the document. Migrated
            // values are not gated on `depends`: see `storeMigrated`.
            try document.storeMigrated(entry.id, value, catalog: catalog)
        } catch {
            diagnostics.append(XRGSettingsDiagnostic(id: entry.id, problem: XRGSettingsDiagnostic.invalidValue))
        }
    }

    /// The RFC 6901 components of a catalog pointer, `~1` and `~0` unescaped.
    private static func components(of pointer: String) -> [String] {
        guard pointer.hasPrefix("/") else { return [] }
        return pointer.dropFirst().split(separator: "/", omittingEmptySubsequences: false)
            .map { $0.replacingOccurrences(of: "~1", with: "/").replacingOccurrences(of: "~0", with: "~") }
    }

    /// The defaults key an entry's `legacy.macos` pointer reads. Most pointers
    /// are the key; the two JSON blobs are inventoried as paths into the blob
    /// (docs/settings-inventory.md), so the key is the pointer's first
    /// component and the path after it names the field inside the blob.
    private static func macKey(of entry: XRGSettingsEntry) -> String? {
        guard let pointer = entry.legacy?.macos else { return nil }
        for blob in ["graphPresentationV1", "processInspectorV1"] where pointer.hasPrefix(blob + ".") {
            return blob
        }
        return pointer
    }

    /// The module ids of Rust's `Settings::default_order()`, the order the
    /// catalog's `/modules/<i>/...` pointers index into.
    private static let defaultModuleOrder = ["cpu", "gpu", "tpu", "memory", "battery",
                                            "temperature", "network", "disk", "ai",
                                            "processes", "gpu_memory", "fans", "weather", "stocks"]

    /// The value a catalog `legacy.linux` pointer names. `/modules/<i>/...`
    /// is special: the index is the module's position in Rust's default
    /// order, while the saved array is the user's display order, so the
    /// module is located by its id wherever it sits
    /// (docs/settings-inventory.md).
    private static func value(at pointer: String, in root: JSONValue) -> JSONValue? {
        var path = components(of: pointer)
        guard let first = path.first else { return nil }
        var start = root
        if first == "modules", path.count >= 2, let index = Int(path[1]) {
            guard defaultModuleOrder.indices.contains(index),
                  case .array(let modules)? = field(root, at: ["modules"]) else { return nil }
            guard let module = modules.first(where: { id(of: $0) == defaultModuleOrder[index] }) else {
                return nil
            }
            start = module
            path.removeFirst(2)
        }
        return field(start, at: path)
    }

    private static func id(of module: JSONValue) -> String? {
        guard case .object(let fields) = module, case .string(let id)? = fields["id"] else { return nil }
        return id
    }

    /// The value at a path of object keys and array indexes, nil when the
    /// path does not exist.
    private static func field(_ json: JSONValue, at path: [String]) -> JSONValue? {
        var current = json
        for component in path {
            switch current {
            case .object(let fields):
                guard let next = fields[component] else { return nil }
                current = next
            case .array(let items):
                guard let index = Int(component), items.indices.contains(index) else { return nil }
                current = items[index]
            default:
                return nil
            }
        }
        return current
    }

    // MARK: Raw macOS values

    /// Which 0.2.2 `UserDefaults` accessor read an identity (no named
    /// transform) legacy key. Confirmed from v0.2.2's
    /// `XRGWindowPreferences.apply` (its bool()/integer()/double()/string()
    /// helpers) and its scattered `defaults.bool/integer/double(forKey:)`
    /// reads (XRGSettings.swift, the *View.swift modules, XRGModule.swift).
    /// Only these three accessors coerce CFBoolean, integer/float NSNumbers
    /// and strings; keys 0.2.2 read as strings, data, objects or blobs, and
    /// every key with a named transform (its own index/flag/archive decoder),
    /// keep the strict identity path and are unchanged (ruling "keys 0.2.2
    /// read differently keep their current strictness").
    private enum LegacyScalarAccessor {
        case bool, integer, double
    }

    private static func legacyScalarAccessor(for entry: XRGSettingsEntry) -> LegacyScalarAccessor? {
        // A named transform is 0.2.2's own index/flag/archive decoder, read
        // through XRGWindowPreferences.apply, NOT one of these three
        // UserDefaults accessors: it keeps its current strict parsing.
        guard entry.legacy?.macosTransform == nil, let key = entry.legacy?.macos else { return nil }
        // The catalog control is a faithful, key-accurate stand-in for the
        // accessor 0.2.2 used (checked against v0.2.2 source): every bool
        // toggle, integer, decimal and duration identity key, and the 26
        // null-default XRGModule_* size keys (all `decimal`), is read with the
        // corresponding bool/integer/double accessor. The one place a whole
        // default (1.0 decoding as an int) would mislead is `duration`:
        // graphRefresh is 0.2.2's double() helper, while the
        // *HistoryMinutes.v1 time-window keys are integer(forKey:).
        switch entry.control {
        case .toggle: return .bool
        case .integer, .segmented: return .integer
        case .decimal: return .double
        case .duration: return key.hasSuffix("HistoryMinutes.v1") ? .integer : .double
        default: return nil  // text/choice/color/...: read as strings/data/objects
        }
    }

    /// Run the entry's original 0.2.2 reader, then its document transform.
    private static func convert(_ raw: Any, _ entry: XRGSettingsEntry) -> TransformOutcome {
        if let name = entry.legacy?.macosTransform, let transform = macosTransform(named: name) {
            return transform(raw, entry)
        }
        return TransformOutcome(macIdentity(raw, for: entry))
    }

    /// The defaults key's original reader applied to `raw`. `fallback` is the
    /// registered default a custom helper uses when the stored text does not
    /// parse; UserDefaults accessors ignore it (they never fall back).
    private static func decodedLegacy(_ raw: Any, fallback: Any?, for entry: XRGSettingsEntry) -> Any {
        guard let key = macKey(of: entry) else { return raw }
        return XRGLegacyMacOSReader.decode(raw, fallback: fallback, key: key)
    }

    /// A defaults value that already is the document value. Scalar keys have
    /// already been decoded by their 0.2.2 reader (`decodedLegacy`); this wraps
    /// that Bool/Int/Double. Strict text keys still require a string.
    private static func macIdentity(_ raw: Any, for entry: XRGSettingsEntry) -> XRGSettingsValue? {
        switch legacyScalarAccessor(for: entry) {
        case .bool:
            return decodedBool(raw).map { .bool($0) }
        case .integer:
            return decodedInt(raw).map { .int($0) }
        case .double:
            return decodedDouble(raw).map { .double($0) }
        case nil:
            // Strict identity path, unchanged: strings, plain numbers and
            // booleans need no transform (docs/settings-inventory.md);
            // a data blob does, and has none.
            if let string = raw as? String { return .string(string) }
            if let bool = macBool(raw) { return .bool(bool) }
            if let int = macInt(raw) { return .int(int) }
            if let double = macDouble(raw) { return .double(double) }
            return nil
        }
    }

    /// A Bool the original reader already produced, or a CFBoolean still in
    /// raw form. `as? Bool` is checked only for an actual Bool so a bridged
    /// integer 0/1 is not mistaken for one when the reader returned an Int.
    private static func decodedBool(_ raw: Any) -> Bool? {
        if raw is Bool { return raw as? Bool }
        if let flag = macBool(raw) { return flag }
        if let number = raw as? NSNumber { return number.doubleValue != 0 }
        return nil
    }

    private static func decodedInt(_ raw: Any) -> Int64? {
        if let value = raw as? Int { return Int64(value) }
        if let value = raw as? Int64 { return value }
        if let value = macInt(raw) { return value }
        if let number = raw as? NSNumber { return number.int64Value }
        return nil
    }

    private static func decodedDouble(_ raw: Any) -> Double? {
        if let value = raw as? Double { return value }
        if let value = macDouble(raw) { return value }
        if let number = raw as? NSNumber { return number.doubleValue }
        return nil
    }

    /// A property-list boolean. A plist integer 0 or 1 also bridges to `Bool`,
    /// so the number's encoding is checked: Core Foundation's CFBoolean —
    /// what a plist `<true/>`/`<false/>` and `defaults.set(Bool)` decode to —
    /// is the only value whose `objCType` is `c`.
    private static func macBool(_ raw: Any) -> Bool? {
        guard let number = raw as? NSNumber, macType(of: number) == "c" else { return nil }
        return number.boolValue
    }

    private static func macInt(_ raw: Any) -> Int64? {
        guard let number = raw as? NSNumber else { return nil }
        switch macType(of: number) {
        case "i", "q", "l", "s", "h", "I", "Q", "L", "S", "H": return number.int64Value
        default: return nil
        }
    }

    private static func macDouble(_ raw: Any) -> Double? {
        guard let number = raw as? NSNumber else { return nil }
        switch macType(of: number) {
        case "f", "d": return number.doubleValue
        default: return nil
        }
    }

    private static func macType(of number: NSNumber) -> String {
        String(cString: number.objCType)
    }

    /// A JSON blob 0.2.2 stores as `defaults.set(Data)`, parsed with the
    /// core's own lossless parser.
    private static func blob(_ raw: Any) -> JSONValue? {
        guard let data = raw as? Data, data.count <= 32 * 1024,
              let text = String(data: data, encoding: .utf8) else { return nil }
        return JSONValue.parse(text)
    }

    /// The path into a blob named by the entry, after the blob's own key:
    /// `graphPresentationV1.overrides.cpu.height` becomes
    /// `["overrides", "cpu", "height"]`.
    private static func blobPath(_ entry: XRGSettingsEntry, after key: String) -> [String]? {
        guard let pointer = entry.legacy?.macos, pointer.hasPrefix(key + ".") else { return nil }
        return pointer.dropFirst(key.count + 1)
            .split(separator: ".", omittingEmptySubsequences: false).map(String.init)
    }

    /// The graph options blob and the field this entry reads from it; the
    /// field is nil when the blob carries no such override.
    private static func graphPresentation(_ raw: Any, _ entry: XRGSettingsEntry) -> (JSONValue, JSONValue?)? {
        guard let parsed = blob(raw), case .object = parsed,
              let path = blobPath(entry, after: "graphPresentationV1") else { return nil }
        return (parsed, field(parsed, at: path))
    }

    /// The order value the entry's default describes, with the ids the legacy
    /// order does not name — graphs 0.2.2 did not have — appended in their
    /// default positions at the end, the same way Rust's own upgrades append
    /// new modules. Without them the value would not be the default ids
    /// rearranged and the user's order would be lost.
    private static func completeOrder(_ ids: [String], entry: XRGSettingsEntry) -> String? {
        guard case .string(let defaultValue) = entry.defaultValue else { return nil }
        var result = ids
        for id in defaultValue.split(separator: ",").map(String.init) where !result.contains(id) {
            result.append(id)
        }
        return result.joined(separator: ",")
    }

    /// The effect names the graph options editor indexes, in blob order.
    private static let effectNames = ["normal", "scanlines", "pixel_grid", "retro_dots"]

    // MARK: macOS transforms (docs/settings-inventory.md, "macOS transforms")

    private static func macosTransform(named name: String) -> ((Any, XRGSettingsEntry) -> TransformOutcome)? {
        switch name {
        case "cpuMonitorSource": return outcome(cpuMonitorSource)
        case "gpuMonitorSource": return outcome(gpuMonitorSource)
        case "hardwareSourceSlot": return outcome(hardwareSourceSlot)
        case "graphPreferenceHeight": return outcome(graphPreferenceHeight)
        case "graphPreferenceCurve": return outcome(graphPreferenceCurve)
        case "graphPreferenceEffect": return outcome(graphPreferenceEffect)
        case "graphPreferenceColor": return outcome(graphPreferenceColor)
        case "graphOrder": return outcome(graphOrder)
        case "processInspectorField": return outcome(processInspectorField)
        case "nsColorArchive": return nsColorArchive
        case "fontArchive": return outcome(fontArchive)
        case "orientationFlag": return outcome(orientationFlag)
        case "windowLevelIndex": return outcome(windowLevelIndex)
        case "collapseAnchorIndex": return outcome(collapseAnchorIndex)
        case "fahrenheitCelsiusIndex": return outcome(fahrenheitCelsiusIndex)
        case "milesKilometersIndex": return outcome(milesKilometersIndex)
        case "inchesHectopascalsIndex": return outcome(inchesHectopascalsIndex)
        case "secondaryIndex": return outcome(secondaryIndex)
        case "stockTimeframeIndex": return outcome(stockTimeframeIndex)
        case "graphStyleIndex": return outcome(graphStyleIndex)
        case "gpuPlotMode": return outcome(gpuPlotMode)
        case "zeroToNull": return outcome(zeroToNull)
        case "networkInterfaceAll": return outcome(networkInterfaceAll)
        case "temperatureSensorSlot": return outcome(temperatureSensorSlot)
        case "themePreset": return outcome(themePreset)
        default: return nil
        }
    }

    private static func cpuMonitorSource(_ raw: Any, _ entry: XRGSettingsEntry) -> XRGSettingsValue? {
        guard let parsed = blob(raw), case .object(let fields) = parsed,
              fields["version"]?.doubleValue == 1 else { return nil }
        switch fields["source"] {
        case nil, .null:
            return .null
        case .string(let source):
            // A saved CPU selection is the decimal text of a logical CPU index
            // (XRGMonitorSource.validateCPU); the aggregate is nil.
            guard let index = Int64(source), String(index) == source else { return nil }
            return .int(index)
        default:
            return nil
        }
    }

    private static func gpuMonitorSource(_ raw: Any, _ entry: XRGSettingsEntry) -> XRGSettingsValue? {
        guard let parsed = blob(raw), case .object(let fields) = parsed,
              fields["version"]?.doubleValue == 1 else { return nil }
        switch fields["source"] {
        case nil, .null:
            return .null
        case .string(let source):
            guard !source.isEmpty, source.utf8.count <= 1024,
                  !source.unicodeScalars.contains(where: CharacterSet.controlCharacters.contains)
            else { return nil }
            return .string(source)
        default:
            return nil
        }
    }

    private static func hardwareSourceSlot(_ raw: Any, _ entry: XRGSettingsEntry) -> XRGSettingsValue? {
        guard let parsed = blob(raw), case .object(let fields) = parsed,
              fields["version"]?.doubleValue == 1 else { return nil }
        // The curve slot the entry names: slot1/sensor1 is curve 1, and so on.
        guard let last = entry.id.split(separator: ".").last,
              let slot = Int(last.drop(while: { $0.isLetter })), (1...3).contains(slot) else { return nil }
        switch fields["sources"] {
        case nil, .null:
            return .null  // automatic selection
        case .array(let items):
            guard items.count == 3 else { return nil }
            switch items[slot - 1] {
            case .null: return .null  // the slot is empty
            case .string(let source): return source.isEmpty ? .null : .string(source)
            default: return nil
            }
        default:
            return nil
        }
    }

    private static func graphPreferenceHeight(_ raw: Any, _ entry: XRGSettingsEntry) -> XRGSettingsValue? {
        guard let (_, field) = graphPresentation(raw, entry) else { return nil }
        guard let field else { return .null }
        guard let number = field.doubleValue else { return nil }
        return XRGSettingsValue.wholeNumber(number)
    }

    private static func graphPreferenceCurve(_ raw: Any, _ entry: XRGSettingsEntry) -> XRGSettingsValue? {
        guard let (_, field) = graphPresentation(raw, entry) else { return nil }
        guard let field else { return .null }
        guard case .string(let curve) = field else { return nil }
        return .string(curve)
    }

    private static func graphPreferenceEffect(_ raw: Any, _ entry: XRGSettingsEntry) -> XRGSettingsValue? {
        guard let (_, field) = graphPresentation(raw, entry) else { return nil }
        guard let field else { return .null }
        guard let index = field.doubleValue, index >= 0, index < Double(effectNames.count),
              index == index.rounded() else { return nil }
        return .string(effectNames[Int(index)])
    }

    private static func graphPreferenceColor(_ raw: Any, _ entry: XRGSettingsEntry) -> XRGSettingsValue? {
        guard let (_, field) = graphPresentation(raw, entry) else { return nil }
        switch field {
        case nil, .null:
            // An explicit null inherits the global palette, like an absent one.
            return .null
        case .array(let components):
            guard components.count == 4 else { return nil }
            let rgba = components.compactMap(\.doubleValue)
            guard rgba.count == 4, rgba.allSatisfy({ $0.isFinite && (0...1).contains($0) }) else { return nil }
            return .color(rgba)
        default:
            return nil
        }
    }

    private static func graphOrder(_ raw: Any, _ entry: XRGSettingsEntry) -> XRGSettingsValue? {
        guard let parsed = blob(raw), case .object(let fields) = parsed else { return nil }
        switch fields["order"] {
        case nil, .null:
            // An absent order preserves the app's module priorities: not set.
            return .null
        case .array(let items):
            var ids: [String] = []
            for item in items {
                guard case .string(let id) = item else { return nil }
                ids.append(id == "tpu" ? "npu" : id)
            }
            return completeOrder(ids, entry: entry).map { .string($0) }
        default:
            return nil
        }
    }

    private static func processInspectorField(_ raw: Any, _ entry: XRGSettingsEntry) -> XRGSettingsValue? {
        // The field the entry's legacy path names inside the saved options:
        // sort, search and user are strings, limit a number. A real blob
        // always carries all four, so a missing one is unconvertible.
        guard let parsed = blob(raw), case .object = parsed,
              let path = blobPath(entry, after: "processInspectorV1"),
              let field = field(parsed, at: path) else { return nil }
        return XRGSettingsValue(json: field)
    }

    private static func orientationFlag(_ raw: Any, _ entry: XRGSettingsEntry) -> XRGSettingsValue? {
        guard let flag = decodedBool(raw) else { return nil }
        return .string(flag ? "vertical" : "horizontal")
    }

    private static func windowLevelIndex(_ raw: Any, _ entry: XRGSettingsEntry) -> XRGSettingsValue? {
        guard let index = decodedInt(raw) else { return nil }
        switch index {
        case 0: return .string("normal")
        case 1: return .string("floating")
        case 2: return .string("background")
        default: return nil
        }
    }

    private static func collapseAnchorIndex(_ raw: Any, _ entry: XRGSettingsEntry) -> XRGSettingsValue? {
        guard let index = decodedInt(raw) else { return nil }
        switch index {
        case 0: return .string("start")
        case 1: return .string("end")
        default: return nil
        }
    }

    private static func fahrenheitCelsiusIndex(_ raw: Any, _ entry: XRGSettingsEntry) -> XRGSettingsValue? {
        guard let index = decodedInt(raw) else { return nil }
        switch index {
        case 0: return .string("fahrenheit")
        case 1: return .string("celsius")
        default: return nil
        }
    }

    private static func milesKilometersIndex(_ raw: Any, _ entry: XRGSettingsEntry) -> XRGSettingsValue? {
        guard let index = decodedInt(raw) else { return nil }
        switch index {
        case 0: return .string("miles")
        case 1: return .string("kilometers")
        default: return nil
        }
    }

    private static func inchesHectopascalsIndex(_ raw: Any, _ entry: XRGSettingsEntry) -> XRGSettingsValue? {
        guard let index = decodedInt(raw) else { return nil }
        switch index {
        case 0: return .string("inches")
        case 1: return .string("hectopascals")
        default: return nil
        }
    }

    private static func secondaryIndex(_ raw: Any, _ entry: XRGSettingsEntry) -> XRGSettingsValue? {
        guard let index = decodedInt(raw) else { return nil }
        switch index {
        case 0: return .string("none")
        case 1: return .string("wind")
        case 2: return .string("humidity")
        case 3: return .string("visibility")
        case 4: return .string("dewpoint")
        case 5: return .string("pressure")
        default: return nil
        }
    }

    private static func stockTimeframeIndex(_ raw: Any, _ entry: XRGSettingsEntry) -> XRGSettingsValue? {
        guard let index = decodedInt(raw) else { return nil }
        switch index {
        case 0: return .int(1)
        case 1: return .int(3)
        case 2: return .int(6)
        case 3: return .int(12)
        default: return nil
        }
    }

    private static func graphStyleIndex(_ raw: Any, _ entry: XRGSettingsEntry) -> XRGSettingsValue? {
        // The Color pane's Display Effect popup stores its index; the four
        // effects it offers are the graph options editor's effect names, in
        // the same order.
        guard let index = decodedInt(raw), let effect = Int(exactly: index),
              effectNames.indices.contains(effect) else { return nil }
        return .string(effectNames[effect])
    }

    private static func gpuPlotMode(_ raw: Any, _ entry: XRGSettingsEntry) -> XRGSettingsValue? {
        guard let mode = raw as? String else { return nil }
        switch mode {
        case "memoryAndActivity": return .string("memory_and_activity")
        case "utilization": return .string("utilization")
        default: return nil
        }
    }

    private static func zeroToNull(_ raw: Any, _ entry: XRGSettingsEntry) -> XRGSettingsValue? {
        guard let number = decodedInt(raw) else { return nil }
        return number == 0 ? .null : .int(number)
    }

    private static func networkInterfaceAll(_ raw: Any, _ entry: XRGSettingsEntry) -> XRGSettingsValue? {
        guard let name = raw as? String else { return nil }
        return name == "All" ? .null : .string(name)
    }

    private static func temperatureSensorSlot(_ raw: Any, _ entry: XRGSettingsEntry) -> XRGSettingsValue? {
        guard let key = raw as? String else { return nil }
        // The placeholders 0/1/2 and an empty selection mean the platform
        // auto-configures its sensors; a real key passes through.
        return key.isEmpty || key == "0" || key == "1" || key == "2" ? .null : .string(key)
    }

    private static func themePreset(_ raw: Any, _ entry: XRGSettingsEntry) -> XRGSettingsValue? {
        guard let name = raw as? String else { return nil }
        let builtin = XRGBuiltinTheme.allCases.contains { $0.name == name }
        return .string(builtin ? name : "Custom")
    }

    private static func nsColorArchive(_ raw: Any, _ entry: XRGSettingsEntry) -> TransformOutcome {
        guard let data = raw as? Data, data.count <= 64 * 1024,
              let archive = KeyedArchive(data),
              Self.archiveClassName(of: archive.root, objects: archive.objects) == "NSColor",
              case .object(let fields) = archive.root else {
            return TransformOutcome(nil)
        }
        // `NSLinearExposure` rides along with ICC-backed spaces (a generic
        // gamma 2.2 grey archives "1") but does not change the components, so
        // it is opaque here and never gates the migration.
        if let space = archiveReferenced("NSCustomColorSpace", in: fields, objects: archive.objects),
           case .object(let spaceFields) = space {
            let (components, name) = colorSpaceComponents(spaceFields, fields)
            return TransformOutcome(components.map { .color($0) }, unconvertibleColorSpace: name)
        }
        // The legacy forms carry no space object; `NSColorSpace`'s own numbering
        // (NSCalibratedRGBColorSpace=1, NSDeviceRGBColorSpace=2,
        // NSCalibratedWhiteColorSpace=3, NSDeviceWhiteColorSpace=4,
        // NSDeviceCMYKColorSpace=5) names the space.
        switch archiveInt(fields["NSColorSpace"]) {
        case 1?:
            // The calibrated space is the generic one (NSColor.h).
            guard let rgba = colorComponents(fields["NSRGB"], rgb: true),
                  fields["NSWhite"] == nil, fields["NSCMYK"] == nil else { return TransformOutcome(nil) }
            return TransformOutcome(.color(genericRGBToSRGB(rgba)))
        case 2?:
            guard let rgba = colorComponents(fields["NSRGB"], rgb: true),
                  fields["NSWhite"] == nil, fields["NSCMYK"] == nil else { return TransformOutcome(nil) }
            return TransformOutcome(.color(rgba))
        case 3?:
            guard let rgba = colorComponents(fields["NSWhite"], rgb: false),
                  fields["NSRGB"] == nil, fields["NSCMYK"] == nil else { return TransformOutcome(nil) }
            return TransformOutcome(.color(genericGreyToSRGB(rgba)))
        case 4?:
            guard let rgba = colorComponents(fields["NSWhite"], rgb: false),
                  fields["NSRGB"] == nil, fields["NSCMYK"] == nil else { return TransformOutcome(nil) }
            return TransformOutcome(.color(rgba))
        case 5?:
            return TransformOutcome(nil, unconvertibleColorSpace: "device-cmyk")
        default:
            return TransformOutcome(nil, unconvertibleColorSpace:
                archiveInt(fields["NSColorSpace"]).map { "ns-color-space-\($0)" })
        }
    }

    /// The document colour an archived `NSColorSpace` names, converted into
    /// the document's sRGB. The ids are the archiver's internal
    /// `CGColorSpaceID` numbering, which it writes either as `NSID` or — for
    /// the ICC-profiled spaces — as `NSSpaceID` (macOS 26 archives an sRGB
    /// colour with `NSID 7` and a Display P3 one with `NSSpaceID 12`); both
    /// field names are accepted for every id. The components are read from
    /// `NSComponents` where the archiver writes them, else `NSRGB`/`NSWhite`;
    /// a grey colour's `NSWhite` can be its calibrated rendering (a generic
    /// gamma 2.2 grey archives 0.5 as "0.4246723652"), so the space's own
    /// components win whenever the archive carries them. Returns (nil, nil)
    /// when the archive is malformed, (nil, name) — the diagnostic name —
    /// when the space cannot be converted, (components, nil) otherwise.
    private static func colorSpaceComponents(_ spaceFields: [String: ArchiveValue],
                                              _ fields: [String: ArchiveValue])
        -> (components: [Double]?, unconvertibleColorSpace: String?) {
        let id = archiveInt(spaceFields["NSID"]) ?? archiveInt(spaceFields["NSSpaceID"])
        switch id {
        case 7?:    // sRGB: the document's own space
            return (colorComponents(fields["NSComponents"], rgb: true), nil)
        case 12?:   // Display P3
            guard var rgba = colorComponents(fields["NSComponents"], rgb: true) else { return (nil, nil) }
            rgba.replaceSubrange(0..<3, with: displayP3ToSRGB(rgba))
            return (rgba, nil)
        case 1?:    // Generic RGB
            guard let rgba = colorComponents(fields["NSRGB"] ?? fields["NSComponents"], rgb: true),
                  fields["NSWhite"] == nil, fields["NSCMYK"] == nil else { return (nil, nil) }
            return (genericRGBToSRGB(rgba), nil)
        case 2?:    // Generic Grey
            guard let rgba = colorComponents(fields["NSComponents"] ?? fields["NSWhite"], rgb: false),
                  fields["NSRGB"] == nil, fields["NSCMYK"] == nil else { return (nil, nil) }
            return (genericGreyToSRGB(rgba), nil)
        case 9?:    // Generic Grey Gamma 2.2: macOS 26 renders its greys as sRGB
            return (colorComponents(fields["NSComponents"] ?? fields["NSWhite"], rgb: false), nil)
        case 5?:    // Device Grey
            return (colorComponents(fields["NSComponents"] ?? fields["NSWhite"], rgb: false), nil)
        case 8?:    // Adobe RGB (1998)
            return (nil, "adobe-rgb")
        default:
            return (nil, id.map { "color-space-\($0)" } ?? "unnamed")
        }
    }

    /// The `Int` an archived object field carries, nil when it is not an
    /// integer the platform can represent exactly.
    private static func archiveInt(_ value: ArchiveValue?) -> Int? {
        guard case .int(let raw)? = value else { return nil }
        return Int(exactly: raw)
    }

    private static func fontArchive(_ raw: Any, _ entry: XRGSettingsEntry) -> XRGSettingsValue? {
        guard let data = raw as? Data, data.count <= 8 * 1024,
              let archive = KeyedArchive(data),
              Self.archiveClassName(of: archive.root, objects: archive.objects) == "NSFont",
              case .object(let fields) = archive.root,
              let name = archiveReferenced("NSName", in: fields, objects: archive.objects),
              case .string(let postscriptName) = name else { return nil }
        let size: Double
        switch fields["NSSize"] {
        case .int(let value): size = Double(value)
        case .double(let value): size = value
        default: return nil
        }
        // The system font serialises under its internal name; everything else
        // is the PostScript name the descriptor carries.
        let descriptor = postscriptName == ".AppleSystemUIFont" ? "System" : postscriptName
        return .string("\(descriptor) \(XRGSettingsDocument.number(size))")
    }

    /// The space-separated decimal components an archived color carries, with
    /// a trailing NUL tolerated: three or four for RGB (alpha 1 when absent),
    /// one or two for grayscale.
    private static func colorComponents(_ field: ArchiveValue?, rgb: Bool) -> [Double]? {
        guard case .data(let raw)? = field, raw.count <= 256 else { return nil }
        var bytes = raw
        if bytes.last == 0 { bytes = bytes.dropLast() }
        guard let text = String(data: bytes, encoding: .utf8) else { return nil }
        let values = text.split(whereSeparator: \.isWhitespace).compactMap { Double($0) }
        let count = rgb ? 3 : 1
        guard values.count == count || values.count == count + 1,
              values.allSatisfy({ $0.isFinite && (0...1).contains($0) }) else { return nil }
        var rgba = rgb ? [values[0], values[1], values[2]] : [values[0], values[0], values[0]]
        rgba.append(values.count > count ? values[count] : 1)
        return rgba
    }

    /// Display P3 channels to bounded sRGB, CSS Color 4's P3→sRGB matrix, as the
    /// Rust XTF decoder does it.
    private static func displayP3ToSRGB(_ rgb: [Double]) -> [Double] {
        let matrix: [[Double]] = [
            [1.2249401762805598, -0.22494017628055996, 0],
            [-0.04205695470968816, 1.042056954709688, 0],
            [-0.019637554590334432, -0.07863604555063189, 1.0982736001409663],
        ]
        let linear = rgb.map { $0 <= 0.04045 ? $0 / 12.92 : pow(($0 + 0.055) / 1.055, 2.4) }
        let converted = matrix.map { row in
            min(1, max(0, zip(row, linear).map { $0.0 * $0.1 }.reduce(0, +)))
        }
        return converted.map { $0 <= 0.0031308 ? $0 * 12.92 : 1.055 * pow($0, 1 / 2.4) - 0.055 }
    }

    /// Generic RGB (the calibrated space, NSColor.h) channels to bounded
    /// sRGB, with the standard matrices:
    ///
    ///     linear = c ** 1.8
    ///     M = sRGB(D65)⁻¹ · Bradford(D50→D65) · [rXYZ gXYZ bXYZ]
    ///     srgb = encode(clamp(M · linear))    // clamped only after conversion
    ///
    /// `sRGB(D65)` and the Bradford cone matrix are CSS Color 4's constants;
    /// the primaries `[rXYZ gXYZ bXYZ]` are the ICC PCS tags of Apple's
    /// Generic RGB Profile (/System/Library/ColorSync/Profiles/Generic RGB
    /// Profile.icc), which are D50-adapted, so Bradford adapts them to sRGB's
    /// D65 white first. The profile's curve is the classic 1.8 gamma. The
    /// product, to full double precision:
    ///
    ///     M = [ 1.025264015903568   -0.026551657962031315  0.0012841603452191097 ]
    ///         [ 0.019397881509373611  0.94802193968336967   0.032581367105521619 ]
    ///         [ -0.00177326804993563 -0.0014400168347385826 1.0032120110741125 ]
    ///
    /// which reproduces macOS 26 ColorSync's own generic-RGB→sRGB conversions
    /// to within 2e-5 (probed: primaries, greys and mixed colours).
    private static func genericRGBToSRGB(_ rgba: [Double]) -> [Double] {
        let matrix: [[Double]] = [
            [1.025264015903568, -0.026551657962031315, 0.0012841603452191097],
            [0.019397881509373611, 0.94802193968336967, 0.032581367105521619],
            [-0.00177326804993563, -0.0014400168347385826, 1.0032120110741125],
        ]
        let linear = (0..<3).map { pow(rgba[$0], 1.8) }
        let converted = matrix.map { row in
            min(1, max(0, zip(row, linear).map { $0.0 * $0.1 }.reduce(0, +)))
        }
        let encoded = converted.map { $0 <= 0.0031308 ? $0 * 12.92 : 1.055 * pow($0, 1 / 2.4) - 0.055 }
        return encoded + [rgba[3]]
    }

    /// A grey from the 1.8-gamma generic grey space (Generic Grey, and the
    /// legacy calibrated white) to sRGB: the grey is linearised with the 1.8
    /// gamma and encoded with CSS Color 4's sRGB transfer curve, on all three
    /// channels (ColorSync converts these greys exactly this way on
    /// macOS 26, probed to 1e-8 along the grey axis).
    private static func genericGreyToSRGB(_ rgba: [Double]) -> [Double] {
        let linear = min(1, max(0, pow(rgba[0], 1.8)))
        let grey = linear <= 0.0031308 ? linear * 12.92 : 1.055 * pow(linear, 1 / 2.4) - 0.055
        return [grey, grey, grey, rgba[3]]
    }

    private static func archiveClassName(of root: ArchiveValue, objects: [ArchiveValue]) -> String? {
        guard case .object(let fields) = root,
              case .uid(let index)? = fields["$class"], let position = objectIndex(index, in: objects),
              case .object(let classInfo) = objects[position],
              case .string(let name)? = classInfo["$classname"] else { return nil }
        return name
    }

    private static func archiveReferenced(_ key: String, in fields: [String: ArchiveValue],
                                          objects: [ArchiveValue]) -> ArchiveValue? {
        guard case .uid(let index)? = fields[key],
              let position = objectIndex(index, in: objects) else { return nil }
        return objects[position]
    }

    /// The object-table position a keyed-archive UID names, nil when the
    /// value is not a representable index or points outside the table.
    /// Archive UIDs are untrusted input, so the conversion is exact.
    private static func objectIndex(_ uid: UInt64, in objects: [ArchiveValue]) -> Int? {
        guard let index = Int(exactly: uid), objects.indices.contains(index) else { return nil }
        return index
    }

    // MARK: Keyed archives

    /// A value from a keyed archive's binary property list. The core reads
    /// what 0.2.2 stored without instantiating archived AppKit classes, like
    /// the Rust XTF decoder (`xrg-linux/rust/src/settings/xtf.rs`);
    /// `PropertyListSerialization` cannot serve here because it hands
    /// keyed-archiver UIDs back as opaque Core Foundation objects with no
    /// public way to read the integer they name.
    private enum ArchiveValue: Equatable {
        case bool(Bool)
        case int(Int64)
        case double(Double)
        case string(String)
        case data(Data)
        case uid(UInt64)
        case array([ArchiveValue])
        case object([String: ArchiveValue])
    }

    /// One `NSKeyedArchiver` archive: the object table and the root object
    /// its `$top` names. Every index the archive names is untrusted input
    /// and converted exactly, so a malformed archive is refused here rather
    /// than trapping.
    private struct KeyedArchive {
        let root: ArchiveValue
        let objects: [ArchiveValue]

        init?(_ data: Data) {
            guard let plist = try? BinaryPlistReader(data).value(),
                  case .object(let fields) = plist,
                  fields["$archiver"] == .string("NSKeyedArchiver"),
                  case .int(100_000)? = fields["$version"],
                  case .array(let objects)? = fields["$objects"],
                  case .string("$null")? = objects.first,
                  case .object(let top)? = fields["$top"],
                  case .uid(let rootIndex)? = top["root"],
                  let rootPosition = XRGSettingsMigration.objectIndex(rootIndex, in: objects) else {
                return nil
            }
            self.root = objects[rootPosition]
            self.objects = objects
        }
    }

    /// A reader for the subset of the binary property-list format keyed
    /// archives use, with the same bounded shapes the XTF decoder accepts.
    /// Every input it reads is untrusted: the trailer's arithmetic is
    /// checked (a corrupt table offset must not wrap around into range),
    /// every byte range is bounds-checked before it is read, and every
    /// object reference is converted exactly, so a malformed archive is
    /// refused with an error instead of trapping.
    private struct BinaryPlistReader {
        private static let maximumInput = 64 * 1024
        private static let maximumObjects = 4096
        private static let maximumDepth = 32
        private static let header = Data("bplist00".utf8)
        private static let corrupt = CocoaError(.fileReadCorruptFile)

        private let data: Data
        private let offsets: [Int]
        private let referenceSize: Int

        init(_ input: Data) throws {
            guard input.count >= Self.header.count + 32 + 1, input.count <= Self.maximumInput,
                  input.prefix(Self.header.count) == Self.header else { throw Self.corrupt }
            let trailer = input.count - 32
            guard let offsetIntSize = Int(exactly: input[input.count - 26]),
                  let referenceSize = Int(exactly: input[input.count - 25]),
                  let count = Self.uint64(input, input.count - 24, 8),
                  let tableOffset = Self.uint64(input, input.count - 8, 8),
                  (1...8).contains(offsetIntSize), (1...8).contains(referenceSize),
                  count >= 1, count <= Self.maximumObjects,
                  tableOffset >= UInt64(Self.header.count),
                  // Checked arithmetic: the table must fit inside the input
                  // without wrapping. The subtraction cannot underflow and
                  // the multiplication cannot overflow once the earlier
                  // clauses have held, and guard clauses evaluate in order.
                  count * UInt64(offsetIntSize) <= UInt64(trailer) &- tableOffset else {
                throw Self.corrupt
            }
            var offsets: [Int] = []
            offsets.reserveCapacity(Int(clamping: count))
            for index in 0..<count {
                let position = tableOffset &+ index &* UInt64(offsetIntSize)
                guard let offset = Self.uint64(input, Int(clamping: position), offsetIntSize),
                      offset < UInt64(trailer),
                      let start = Int(exactly: offset) else { throw Self.corrupt }
                offsets.append(start)
            }
            self.data = input
            self.offsets = offsets
            self.referenceSize = referenceSize
        }

        func value() throws -> ArchiveValue {
            try object(at: 0, depth: 0)
        }

        // MARK: object table

        private func object(at index: Int, depth: Int) throws -> ArchiveValue {
            guard offsets.indices.contains(index), depth <= Self.maximumDepth else {
                throw Self.corrupt
            }
            var cursor = offsets[index]
            return try parse(at: &cursor, depth: depth)
        }

        /// The object-table position an array or dictionary reference names,
        /// nil when the reference is not a representable index.
        private func referenced(_ reference: UInt64) -> Int? {
            guard let index = Int(exactly: reference) else { return nil }
            return index
        }

        private func parse(at cursor: inout Int, depth: Int) throws -> ArchiveValue {
            guard cursor < data.count else { throw Self.corrupt }
            let marker = data[cursor]
            cursor += 1
            switch marker >> 4 {
            case 0x0:
                // Markers 0x08 and 0x09 are the booleans; a keyed archive
                // object table carries no plist null — the archiver writes
                // "$null" as a string.
                switch marker {
                case 0x08: return .bool(false)
                case 0x09: return .bool(true)
                default: throw Self.corrupt
                }
            case 0x1:  // int, big-endian two's complement
                let size = 1 << Int(marker & 0x0f)
                guard size <= 8, let bits = Self.uint64(data, cursor, size) else {
                    throw Self.corrupt  // no 128-bit ints, no reads past the end
                }
                cursor += size
                let value = Int64(bitPattern: bits << (64 - 8 * size)) >> (64 - 8 * size)
                return .int(value)
            case 0x2:  // real
                switch marker & 0x0f {
                case 0x2:
                    guard let bits = Self.uint64(data, cursor, 4) else { throw Self.corrupt }
                    cursor += 4
                    return .double(Double(Float(bitPattern: UInt32(truncatingIfNeeded: bits))))
                case 0x3:
                    guard let bits = Self.uint64(data, cursor, 8) else { throw Self.corrupt }
                    cursor += 8
                    return .double(Double(bitPattern: bits))
                default: throw Self.corrupt
                }
            case 0x4:  // data
                let count = try length(Int(marker & 0x0f), at: &cursor)
                guard count <= data.count - cursor else { throw Self.corrupt }
                let payload = data.subdata(in: cursor..<(cursor + count))
                cursor += count
                return .data(payload)
            case 0x5:  // ASCII string
                let count = try length(Int(marker & 0x0f), at: &cursor)
                guard count <= data.count - cursor,
                      let text = String(data: data.subdata(in: cursor..<(cursor + count)), encoding: .ascii) else {
                    throw Self.corrupt
                }
                cursor += count
                return .string(text)
            case 0x6:  // UTF-16BE string; the length counts code units
                let units = try length(Int(marker & 0x0f), at: &cursor)
                guard units <= (data.count - cursor) / 2,
                      let text = String(data: data.subdata(in: cursor..<(cursor + units * 2)),
                                       encoding: .utf16BigEndian) else {
                    throw Self.corrupt
                }
                cursor += units * 2
                return .string(text)
            case 0x8:  // UID
                let size = Int(marker & 0x0f) + 1
                guard size <= 8, let value = Self.uint64(data, cursor, size) else {
                    throw Self.corrupt
                }
                cursor += size
                return .uid(value)
            case 0xa:  // array
                let count = try length(Int(marker & 0x0f), at: &cursor)
                var items: [ArchiveValue] = []
                for _ in 0..<count {
                    guard let index = referenced(try reference(at: &cursor)) else { throw Self.corrupt }
                    items.append(try object(at: index, depth: depth + 1))
                }
                return .array(items)
            case 0xd:  // dictionary
                let count = try length(Int(marker & 0x0f), at: &cursor)
                var keys: [Int] = []
                for _ in 0..<count {
                    guard let key = referenced(try reference(at: &cursor)) else { throw Self.corrupt }
                    keys.append(key)
                }
                var fields: [String: ArchiveValue] = [:]
                for key in keys {
                    let keyObject = try object(at: key, depth: depth + 1)
                    guard case .string(let name) = keyObject, name.utf8.count <= 128 else {
                        throw Self.corrupt
                    }
                    guard let index = referenced(try reference(at: &cursor)) else { throw Self.corrupt }
                    fields[name] = try object(at: index, depth: depth + 1)
                }
                return .object(fields)
            default:
                throw Self.corrupt
            }
        }

        /// A collection length, short form or the int object that follows the
        /// 0xf marker, bounded to the input size.
        private func length(_ info: Int, at cursor: inout Int) throws -> Int {
            guard cursor < data.count else { throw Self.corrupt }
            guard info == 0x0f else { return info }
            let marker = data[cursor]
            guard marker >> 4 == 0x1, 1 << Int(marker & 0x0f) <= 8 else { throw Self.corrupt }
            cursor += 1
            let size = 1 << Int(marker & 0x0f)
            guard let value = Self.uint64(data, cursor, size) else { throw Self.corrupt }
            cursor += size
            guard value <= Self.maximumInput, let count = Int(exactly: value) else { throw Self.corrupt }
            return count
        }

        private func reference(at cursor: inout Int) throws -> UInt64 {
            guard let value = Self.uint64(data, cursor, referenceSize) else { throw Self.corrupt }
            cursor += referenceSize
            return value
        }

        /// The big-endian unsigned integer `size` bytes wide at `start`, nil
        /// when those bytes are not all inside the input. Reading past the
        /// end of a truncated or corrupt archive must refuse, not trap.
        private static func uint64(_ data: Data, _ start: Int, _ size: Int) -> UInt64? {
            guard size >= 1, size <= 8, start >= 0, start <= data.count,
                  size <= data.count - start else { return nil }
            var value: UInt64 = 0
            for byte in data[start..<(start + size)] {
                value = value << 8 | UInt64(byte)
            }
            return value
        }
    }

    // MARK: Linux transforms (docs/settings-inventory.md, "Linux transforms")

    private static func linuxTransform(named name: String) -> ((JSONValue, XRGSettingsEntry) -> XRGSettingsValue?)? {
        switch name {
        case "themeChoice": return linuxThemeChoice
        case "themeName": return linuxThemeName
        case "themeColor": return linuxThemeColor
        case "millisecondsToSeconds": return millisecondsToSeconds
        case "unitsToTemperature": return unitsToTemperature
        case "unitsToDistance": return unitsToDistance
        case "unitsToPressure": return unitsToPressure
        case "modulesOrder": return modulesOrder
        case "windowSizePresent": return windowSizePresent
        case "uidToString": return uidToString
        default: return nil
        }
    }

    /// The ThemeChoice at `/theme`: a built-in by name, or a custom document.
    private enum LinuxTheme {
        case builtin(String)
        case custom(name: String, colors: [[Double]])
    }

    private static func linuxTheme(_ raw: JSONValue) -> LinuxTheme? {
        guard case .object(let fields) = raw else { return nil }
        switch (fields["kind"], fields["theme"]) {
        case (.string("builtin"), .none):
            guard case .string(let name)? = fields["name"] else { return nil }
            return .builtin(name)
        case (.string("custom"), .some(let document)):
            guard case .object(let documentFields) = document,
                  documentFields["format"] == .string("xrg-ng-theme"),
                  documentFields["version"]?.doubleValue == 1,
                  case .string(let name)? = documentFields["name"],
                  case .array(let palette)? = documentFields["colors"] else { return nil }
            var colors: [[Double]] = []
            for color in palette {
                guard case .array(let components) = color, components.count == 4,
                      let rgba = components.compactMap(\.doubleValue) as [Double]?, rgba.count == 4,
                      rgba.allSatisfy({ $0.isFinite && (0...1).contains($0) }) else { return nil }
                colors.append(rgba)
            }
            guard colors.count == 7 else { return nil }
            return .custom(name: name, colors: colors)
        default:
            return nil
        }
    }

    private static func linuxThemePalette(_ raw: JSONValue) -> [[Double]]? {
        switch linuxTheme(raw) {
        case .builtin(let name):
            guard let theme = XRGBuiltinTheme.allCases.first(where: { $0.name == name }) else { return nil }
            return theme.rgba
        case .custom(_, let colors)?:
            return colors
        default:
            return nil
        }
    }

    private static func linuxThemeChoice(_ raw: JSONValue, _ entry: XRGSettingsEntry) -> XRGSettingsValue? {
        switch linuxTheme(raw) {
        case .builtin(let name):
            // A built-in the core does not know cannot become a preset: the
            // entry's options would reject it.
            return XRGBuiltinTheme.allCases.contains { $0.name == name } ? .string(name) : nil
        case .custom:
            return .string("Custom")
        default:
            return nil
        }
    }

    private static func linuxThemeName(_ raw: JSONValue, _ entry: XRGSettingsEntry) -> XRGSettingsValue? {
        switch linuxTheme(raw) {
        case .builtin(let name): return .string(name)
        case .custom(let name, _): return .string(name)
        default: return nil
        }
    }

    private static func linuxThemeColor(_ raw: JSONValue, _ entry: XRGSettingsEntry) -> XRGSettingsValue? {
        // The palette entry the entry names, in the shared ABI's order:
        // window background, graph background, three fills, border, text.
        let index: Int?
        switch entry.id {
        case "appearance.window.color": index = 0
        case "appearance.graph_background.color": index = 1
        case "appearance.series1.color": index = 2
        case "appearance.series2.color": index = 3
        case "appearance.series3.color": index = 4
        case "appearance.border.color": index = 5
        case "appearance.text.color": index = 6
        default: index = nil
        }
        guard let index, let palette = linuxThemePalette(raw), palette.indices.contains(index) else { return nil }
        return .color(palette[index])
    }

    private static func millisecondsToSeconds(_ raw: JSONValue, _ entry: XRGSettingsEntry) -> XRGSettingsValue? {
        guard let milliseconds = raw.doubleValue, milliseconds >= 0 else { return nil }
        return XRGSettingsValue.wholeNumber(milliseconds / 1000)
    }

    private static func unitsToTemperature(_ raw: JSONValue, _ entry: XRGSettingsEntry) -> XRGSettingsValue? {
        switch raw {
        case .null: return .null
        case .string("metric"): return .string("celsius")
        case .string("us"): return .string("fahrenheit")
        default: return nil
        }
    }

    private static func unitsToDistance(_ raw: JSONValue, _ entry: XRGSettingsEntry) -> XRGSettingsValue? {
        switch raw {
        case .null: return .null
        case .string("metric"): return .string("kilometers")
        case .string("us"): return .string("miles")
        default: return nil
        }
    }

    private static func unitsToPressure(_ raw: JSONValue, _ entry: XRGSettingsEntry) -> XRGSettingsValue? {
        switch raw {
        case .null: return .null
        case .string("metric"): return .string("hectopascals")
        case .string("us"): return .string("inches")
        default: return nil
        }
    }

    private static func modulesOrder(_ raw: JSONValue, _ entry: XRGSettingsEntry) -> XRGSettingsValue? {
        guard case .array(let items) = raw else { return nil }
        var ids: [String] = []
        for item in items {
            guard case .object(let fields) = item, case .string(let id)? = fields["id"] else { return nil }
            ids.append(id == "tpu" ? "npu" : (id == "gpu_memory" ? "vram" : (id == "stocks" ? "stock" : id)))
        }
        return completeOrder(ids, entry: entry).map { .string($0) }
    }

    private static func windowSizePresent(_ raw: JSONValue, _ entry: XRGSettingsEntry) -> XRGSettingsValue? {
        switch raw {
        case .null: return .bool(false)
        case .object: return .bool(true)
        default: return nil
        }
    }

    private static func uidToString(_ raw: JSONValue, _ entry: XRGSettingsEntry) -> XRGSettingsValue? {
        switch raw {
        case .null: return .string("")
        case .number:
            guard let uid = raw.doubleValue, uid >= 0, uid == uid.rounded(),
                  let value = Int64(exactly: uid) else { return nil }
            return .string(String(value))
        default: return nil
        }
    }

    // MARK: Linux view helpers

    /// The view's JSON for a document value.
    private static func viewJSON(_ value: XRGSettingsValue) -> JSONValue {
        switch value {
        case .null: return .null
        case .bool(let value): return .bool(value)
        case .int(let value): return .number(String(value))
        case .double(let value): return .number(XRGSettingsDocument.number(value))
        case .string(let value): return .string(value)
        case .color(let rgba): return .array(rgba.map { .number(XRGSettingsDocument.number($0)) })
        }
    }

    /// The v40 module id for a catalog graph id. The Stocks graph joins the
    /// Linux view in 0.2.3, so `stock` now maps to the `stocks` module and
    /// appears in `modules` and `graphs.order` at its stored position.
    private static let moduleIds: [String: String] = [
        "cpu": "cpu", "gpu": "gpu", "npu": "tpu", "vram": "gpu_memory", "memory": "memory",
        "battery": "battery", "temperature": "temperature", "network": "network", "disk": "disk",
        "ai": "ai", "processes": "processes", "fans": "fans", "weather": "weather",
        "stock": "stocks",
    ]

    /// The modules with retained-history pointers into `metrics`, with their
    /// catalog graph ids and v40 module names.
    private static let historyModules: [(module: String, graph: String)] = [
        ("battery", "battery"), ("disk", "disk"), ("fans", "fans"), ("gpu", "gpu"),
        ("gpu_memory", "vram"), ("memory", "memory"), ("network", "network"),
        ("temperature", "temperature"), ("tpu", "npu"),
    ]

    private static func viewBool(_ id: String, _ document: XRGSettingsDocument, _ catalog: XRGSettingsCatalog) -> JSONValue {
        let value = document.value(id, catalog: catalog)
        if case .bool(let concrete) = value { return .bool(concrete) }
        if let entry = catalog.entry(id), case .bool(let fallback) = entry.defaultValue { return .bool(fallback) }
        return .bool(false)
    }

    private static func viewString(_ id: String, _ document: XRGSettingsDocument, _ catalog: XRGSettingsCatalog) -> JSONValue {
        let value = document.value(id, catalog: catalog)
        if case .string(let concrete) = value { return .string(concrete) }
        if let entry = catalog.entry(id), case .string(let fallback) = entry.defaultValue { return .string(fallback) }
        return .string("")
    }

    private static func viewInt(_ id: String, _ document: XRGSettingsDocument, _ catalog: XRGSettingsCatalog) -> JSONValue {
        if let number = viewInt64(id, document, catalog, fallbackToDefault: true) {
            return .number(String(number))
        }
        return .number("0")
    }

    private static func viewDouble(_ id: String, _ document: XRGSettingsDocument, _ catalog: XRGSettingsCatalog) -> JSONValue {
        let value = document.value(id, catalog: catalog)
        if let number = value.numberValue, number.isFinite { return .number(XRGSettingsDocument.number(number)) }
        if let entry = catalog.entry(id), let number = entry.defaultValue.numberValue {
            return .number(XRGSettingsDocument.number(number))
        }
        return .number("0")
    }

    /// The integer a v40 field needs, from the document value or the catalog
    /// default; nil when both are "not set" or not integral.
    private static func viewInt64(_ id: String, _ document: XRGSettingsDocument, _ catalog: XRGSettingsCatalog,
                                  fallbackToDefault: Bool) -> Int64? {
        let value = document.value(id, catalog: catalog)
        if let number = value.numberValue, number.isFinite, let integer = Int64(exactly: number) {
            return integer
        }
        guard fallbackToDefault, let entry = catalog.entry(id),
              let number = entry.defaultValue.numberValue, let integer = Int64(exactly: number) else { return nil }
        return integer
    }

    private static func viewIntOrNull(_ id: String, _ document: XRGSettingsDocument, _ catalog: XRGSettingsCatalog) -> JSONValue {
        viewInt64(id, document, catalog, fallbackToDefault: true).map { .number(String($0)) } ?? .null
    }

    private static func viewColor(_ id: String, _ document: XRGSettingsDocument, _ catalog: XRGSettingsCatalog) -> JSONValue {
        let value = document.value(id, catalog: catalog)
        if case .color(let concrete) = value { return viewJSON(.color(concrete)) }
        if let entry = catalog.entry(id), case .color(let fallback) = entry.defaultValue {
            return viewJSON(.color(fallback))
        }
        return .array((0..<4).map { _ in .number("0") })
    }

    /// A v40 `Option<String>`: a source identity is a string, and a numeric
    /// identity is rendered in its decimal form so the value survives.
    private static func viewStringOrNull(_ id: String, _ document: XRGSettingsDocument, _ catalog: XRGSettingsCatalog) -> JSONValue {
        let value = document.value(id, catalog: catalog)
        switch value {
        case .null: return .null
        case .string(let identity): return .string(identity)
        case .int(let identity): return .string(String(identity))
        default: return .null
        }
    }

    private static func viewCpuCore(_ document: XRGSettingsDocument, _ catalog: XRGSettingsCatalog) -> JSONValue {
        let value = document.value("sources.cpu.core", catalog: catalog)
        switch value {
        case .null: return .null
        case .int(let index): return index >= 0 ? .number(String(index)) : .null
        case .string(let index):
            guard let number = Int64(index), number >= 0, String(number) == index else { return .null }
            return .number(String(number))
        default: return .null
        }
    }

    private static func viewUid(_ document: XRGSettingsDocument, _ catalog: XRGSettingsCatalog) -> JSONValue {
        // The user filter is the decimal text of a uid; empty means no filter.
        guard case .string(let text) = document.value("graphs.processes.user", catalog: catalog),
              let uid = Int64(text), uid >= 0, String(uid) == text else { return .null }
        return .number(String(uid))
    }

    /// The document's `metric/us` unit choice, or the v40 null that means
    /// "follow the unit system": the inverse of the units* transforms. The
    /// `metric`/`us` arguments are the catalog names of the two choices.
    private static func viewUnits(_ id: String, _ document: XRGSettingsDocument, _ catalog: XRGSettingsCatalog,
                                  metric: String, us: String) -> JSONValue {
        let value = document.value(id, catalog: catalog)
        if case .null = value { return .null }
        if case .string(let name) = value {
            if name == metric { return .string("metric") }
            if name == us { return .string("us") }
        }
        if let entry = catalog.entry(id), case .string(let fallback) = entry.defaultValue {
            return .string(fallback == us ? "us" : "metric")
        }
        return .null
    }

    private static func viewSamplingInterval(_ document: XRGSettingsDocument, _ catalog: XRGSettingsCatalog) -> JSONValue {
        let value = document.value("graphs.refresh", catalog: catalog)
        var seconds = value.numberValue
        if seconds == nil, let entry = catalog.entry("graphs.refresh") {
            seconds = entry.defaultValue.numberValue
        }
        guard let interval = seconds, interval > 0 else { return .number("1000") }
        return .number(String(Int64((interval * 1000).rounded())))
    }

    private static func viewWindowSize(_ document: XRGSettingsDocument, _ catalog: XRGSettingsCatalog) -> JSONValue {
        guard case .bool(true) = document.value("general.window.remember_size", catalog: catalog),
              let width = viewInt64("general.window.width", document, catalog, fallbackToDefault: false),
              let height = viewInt64("general.window.height", document, catalog, fallbackToDefault: false)
        else { return .null }
        return .object(["height": .number(String(height)), "width": .number(String(width))])
    }

    private static func viewHistory(_ document: XRGSettingsDocument, _ catalog: XRGSettingsCatalog, field: String) -> JSONValue {
        // Rust drops a module's retained history when its count is zero, so
        // the view carries only the non-default entries.
        var fields: [String: JSONValue] = [:]
        for (module, graph) in historyModules {
            let value = document.value("graphs.\(graph).\(field)", catalog: catalog)
            if let number = value.numberValue, number > 0, let count = Int64(exactly: number) {
                fields[module] = .number(String(count))
            }
        }
        return .object(fields)
    }

    private static func viewModuleOrder(_ document: XRGSettingsDocument, _ catalog: XRGSettingsCatalog)
        -> [(catalog: String, module: String)] {
        func mapped(_ text: String) -> [(catalog: String, module: String)] {
            text.split(separator: ",").compactMap { id in moduleIds[String(id)].map { (String(id), $0) } }
        }
        var pairs = [(catalog: String, module: String)]()
        if case .string(let text) = document.value("graphs.order", catalog: catalog) {
            pairs = mapped(text)
        }
        if Set(pairs.map(\.module)).count != moduleIds.count {
            if let entry = catalog.entry("graphs.order"), case .string(let text) = entry.defaultValue {
                pairs = mapped(text)
            }
        }
        return pairs
    }

    private static func viewModules(_ document: XRGSettingsDocument, _ catalog: XRGSettingsCatalog) -> JSONValue {
        .array(viewModuleOrder(document, catalog).map { catalogId, moduleId in
            .object([
                "colors": .object([
                    "background": viewModuleColor("graphs.\(catalogId).color.background", document, catalog),
                    "series": .array([
                        viewModuleColor("graphs.\(catalogId).color.series1", document, catalog),
                        viewModuleColor("graphs.\(catalogId).color.series2", document, catalog),
                        viewModuleColor("graphs.\(catalogId).color.series3", document, catalog),
                    ]),
                ]),
                "height": viewIntOrNull("graphs.\(catalogId).height", document, catalog),
                "id": .string(moduleId),
                "style": viewString("graphs.\(catalogId).style", document, catalog),
                "visible": viewBool("graphs.\(catalogId).visible", document, catalog),
            ])
        })
    }

    private static func viewModuleColor(_ id: String, _ document: XRGSettingsDocument, _ catalog: XRGSettingsCatalog) -> JSONValue {
        switch document.value(id, catalog: catalog) {
        case .color: return viewJSON(document.value(id, catalog: catalog))
        default: return .null
        }
    }

    /// The appearance palette entry ids, in the shared ABI's order: window
    /// background, graph background, three fills, border, text.
    private static let paletteIds = ["appearance.window.color", "appearance.graph_background.color",
                                     "appearance.series1.color", "appearance.series2.color",
                                     "appearance.series3.color", "appearance.border.color",
                                     "appearance.text.color"]

    /// The colors the platform actually draws: each appearance entry's
    /// stored color, or its catalog default.
    private static func effectivePalette(_ document: XRGSettingsDocument, _ catalog: XRGSettingsCatalog)
        -> [[Double]] {
        paletteIds.map { id in
            let value = document.value(id, catalog: catalog)
            if case .color(let rgba) = value { return rgba }
            if let entry = catalog.entry(id), case .color(let fallback) = entry.defaultValue { return fallback }
            return [0, 0, 0, 1]
        }
    }

    private static func viewTheme(_ document: XRGSettingsDocument, _ catalog: XRGSettingsCatalog) -> JSONValue {
        let preset = document.value("themes.preset", catalog: catalog)
        if case .string(let name) = preset, name != "Custom",
           let builtin = XRGBuiltinTheme.allCases.first(where: { $0.name == name }) {
            // A selected built-in is only the theme the platform draws while
            // the palette still is the built-in's. One edited color makes
            // the effective palette a custom theme — Linux keeps the edit,
            // under the name of the theme it was edited from.
            if effectivePalette(document, catalog) == builtin.rgba {
                return .object(["kind": .string("builtin"), "name": .string(name)])
            }
            return customTheme(document, catalog, name: themeName(document, catalog, preset: name))
        }
        // A custom theme's document is the palette the appearance entries
        // carry, in the shared ABI's order, under the theme's name: the
        // stored name, or the catalog default when no name is stored.
        if case .string(let stored) = document.values["themes.name"] {
            return customTheme(document, catalog, name: stored)
        }
        if case .string(let resolved) = viewString("themes.name", document, catalog) {
            return customTheme(document, catalog, name: resolved)
        }
        return customTheme(document, catalog, name: "Custom")
    }

    /// A stored theme name when there is one; otherwise the selected
    /// preset's name, so an edited preset stays recognisable.
    private static func themeName(_ document: XRGSettingsDocument, _ catalog: XRGSettingsCatalog,
                                  preset: String) -> String {
        if case .string(let stored) = document.values["themes.name"] { return stored }
        return preset
    }

    private static func customTheme(_ document: XRGSettingsDocument, _ catalog: XRGSettingsCatalog,
                                    name: String) -> JSONValue {
        .object([
            "kind": .string("custom"),
            "theme": .object([
                "colors": .array(effectivePalette(document, catalog).map { viewJSON(.color($0)) }),
                "format": .string("xrg-ng-theme"),
                "name": .string(name),
                "version": .number("1"),
            ]),
        ])
    }
}
