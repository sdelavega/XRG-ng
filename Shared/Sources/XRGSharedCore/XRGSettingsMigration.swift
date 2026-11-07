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

    /// Migrate a 0.2.2 `NSUserDefaults` persistent domain — the dictionary
    /// `UserDefaults.dictionaryRepresentation()` or a defaults export decodes
    /// to — into the shared document. Keys the catalog does not map (Sparkle
    /// `SU*` state, AppKit window frames, latches, recorded data) are ignored:
    /// they are not settings and ignoring them is not a problem.
    public static func fromMacDefaults(_ defaults: [String: Any], catalog: XRGSettingsCatalog)
        -> (XRGSettingsDocument, [XRGSettingsDiagnostic]) {
        var document = XRGSettingsDocument()
        var diagnostics: [XRGSettingsDiagnostic] = []
        // Entries are processed in canonical id order so diagnostics are
        // deterministic. The legacy state is converted as it was saved, in
        // whatever combination it holds: `storeMigrated` applies each entry's
        // own rules but not its `depends` gating, which belongs to the
        // interactive settings window.
        for entry in catalog.entries.sorted(by: { XRGSettingsDocument.precedes($0.id, $1.id) }) {
            guard let key = macKey(of: entry), let raw = defaults[key] else { continue }
            let value: XRGSettingsValue?
            if let name = entry.legacy?.macosTransform, let transform = macosTransform(named: name) {
                value = transform(raw, entry)
            } else {
                value = macIdentity(raw)
            }
            store(value, for: entry, into: &document, diagnostics: &diagnostics, catalog: catalog)
        }
        return (document, diagnostics)
    }

    /// Migrate a version-40 Linux settings file, already upgraded by Rust's
    /// chain, into the shared document. Each `legacy.linux` pointer is
    /// resolved against the JSON the same way Rust's serde model names it; a
    /// pointer that is not there leaves the entry at its default, while a
    /// JSON null is a value like any other ("not set", or "follow the unit
    /// system") and is migrated as such.
    public static func fromLinuxV40(_ json: Data, catalog: XRGSettingsCatalog) throws
        -> (XRGSettingsDocument, [XRGSettingsDiagnostic]) {
        guard let text = String(data: json, encoding: .utf8),
              case .object(let root)? = JSONValue.parse(text) else {
            throw XRGSettingsMigrationError.malformedV40
        }
        var document = XRGSettingsDocument()
        var diagnostics: [XRGSettingsDiagnostic] = []
        for entry in catalog.entries.sorted(by: { XRGSettingsDocument.precedes($0.id, $1.id) }) {
            guard let pointer = entry.legacy?.linux,
                  let raw = value(at: pointer, in: .object(root)) else { continue }
            let value: XRGSettingsValue?
            if let name = entry.legacy?.linuxTransform, let transform = linuxTransform(named: name) {
                value = transform(raw, entry)
            } else {
                value = XRGSettingsValue(json: raw)
            }
            store(value, for: entry, into: &document, diagnostics: &diagnostics, catalog: catalog)
        }
        return (document, diagnostics)
    }

    /// The Linux view of a document: the version-40-shaped JSON the Rust
    /// serde `Settings` struct deserialises (`xrg-linux/rust/src/settings.rs`),
    /// with every field of that struct filled from the document through the
    /// reverse of each entry's `legacy.linux` mapping and the catalog default
    /// where the document has no value. The view also carries a top-level
    /// `stocks` object for the shared Stocks settings (ruling R2: the Rust
    /// struct gains the matching field); every other name is a field of the
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

    private static func store(_ value: XRGSettingsValue?, for entry: XRGSettingsEntry,
                              into document: inout XRGSettingsDocument,
                              diagnostics: inout [XRGSettingsDiagnostic], catalog: XRGSettingsCatalog) {
        guard let value else {
            diagnostics.append(XRGSettingsDiagnostic(id: entry.id, problem: XRGSettingsDiagnostic.invalidValue))
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
                                            "processes", "gpu_memory", "fans", "weather"]

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

    /// A defaults value that already is the document value: strings, plain
    /// numbers and booleans need no transform (docs/settings-inventory.md);
    /// a data blob does, and has none.
    private static func macIdentity(_ raw: Any) -> XRGSettingsValue? {
        if let string = raw as? String { return .string(string) }
        if let bool = macBool(raw) { return .bool(bool) }
        if let int = macInt(raw) { return .int(int) }
        if let double = macDouble(raw) { return .double(double) }
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

    private static func macosTransform(named name: String) -> ((Any, XRGSettingsEntry) -> XRGSettingsValue?)? {
        switch name {
        case "cpuMonitorSource": return cpuMonitorSource
        case "gpuMonitorSource": return gpuMonitorSource
        case "hardwareSourceSlot": return hardwareSourceSlot
        case "graphPreferenceHeight": return graphPreferenceHeight
        case "graphPreferenceCurve": return graphPreferenceCurve
        case "graphPreferenceEffect": return graphPreferenceEffect
        case "graphPreferenceColor": return graphPreferenceColor
        case "graphOrder": return graphOrder
        case "processInspectorField": return processInspectorField
        case "nsColorArchive": return nsColorArchive
        case "fontArchive": return fontArchive
        case "orientationFlag": return orientationFlag
        case "windowLevelIndex": return windowLevelIndex
        case "collapseAnchorIndex": return collapseAnchorIndex
        case "fahrenheitCelsiusIndex": return fahrenheitCelsiusIndex
        case "milesKilometersIndex": return milesKilometersIndex
        case "inchesHectopascalsIndex": return inchesHectopascalsIndex
        case "secondaryIndex": return secondaryIndex
        case "stockTimeframeIndex": return stockTimeframeIndex
        case "gpuPlotMode": return gpuPlotMode
        case "zeroToNull": return zeroToNull
        case "networkInterfaceAll": return networkInterfaceAll
        case "temperatureSensorSlot": return temperatureSensorSlot
        case "themePreset": return themePreset
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
        guard let flag = macBool(raw) else { return nil }
        return .string(flag ? "vertical" : "horizontal")
    }

    private static func windowLevelIndex(_ raw: Any, _ entry: XRGSettingsEntry) -> XRGSettingsValue? {
        guard let index = macInt(raw) else { return nil }
        switch index {
        case 0: return .string("normal")
        case 1: return .string("floating")
        case 2: return .string("background")
        default: return nil
        }
    }

    private static func collapseAnchorIndex(_ raw: Any, _ entry: XRGSettingsEntry) -> XRGSettingsValue? {
        guard let index = macInt(raw) else { return nil }
        switch index {
        case 0: return .string("start")
        case 1: return .string("end")
        default: return nil
        }
    }

    private static func fahrenheitCelsiusIndex(_ raw: Any, _ entry: XRGSettingsEntry) -> XRGSettingsValue? {
        guard let index = macInt(raw) else { return nil }
        switch index {
        case 0: return .string("fahrenheit")
        case 1: return .string("celsius")
        default: return nil
        }
    }

    private static func milesKilometersIndex(_ raw: Any, _ entry: XRGSettingsEntry) -> XRGSettingsValue? {
        guard let index = macInt(raw) else { return nil }
        switch index {
        case 0: return .string("miles")
        case 1: return .string("kilometers")
        default: return nil
        }
    }

    private static func inchesHectopascalsIndex(_ raw: Any, _ entry: XRGSettingsEntry) -> XRGSettingsValue? {
        guard let index = macInt(raw) else { return nil }
        switch index {
        case 0: return .string("inches")
        case 1: return .string("hectopascals")
        default: return nil
        }
    }

    private static func secondaryIndex(_ raw: Any, _ entry: XRGSettingsEntry) -> XRGSettingsValue? {
        guard let index = macInt(raw) else { return nil }
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
        guard let index = macInt(raw) else { return nil }
        switch index {
        case 0: return .int(1)
        case 1: return .int(3)
        case 2: return .int(6)
        case 3: return .int(12)
        default: return nil
        }
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
        guard let number = macInt(raw) else { return nil }
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

    private static func nsColorArchive(_ raw: Any, _ entry: XRGSettingsEntry) -> XRGSettingsValue? {
        guard let data = raw as? Data, data.count <= 64 * 1024,
              let archive = KeyedArchive(data),
              Self.archiveClassName(of: archive.root, objects: archive.objects) == "NSColor",
              case .object(let fields) = archive.root else { return nil }
        if fields["NSComponents"] != nil || fields["NSCustomColorSpace"] != nil {
            // A color archived in its own space. AppKit records the original
            // sRGB channels in NSComponents and keeps NSRGB only as a legacy
            // fallback, so NSComponents is the value to read (xtf.rs again).
            guard case .int(1)? = fields["NSColorSpace"] else { return nil }
            if let exposure = fields["NSLinearExposure"], exposure != .data(Data("0".utf8)) {
                return nil
            }
            guard let space = archiveReferenced("NSCustomColorSpace", in: fields, objects: archive.objects),
                  case .object(let spaceFields) = space,
                  var rgba = colorComponents(fields["NSComponents"], rgb: true) else { return nil }
            switch spaceFields["NSID"] {
            case .int(7): break  // the standard sRGB space
            case .int(12): rgba.replaceSubrange(0..<3, with: displayP3ToSRGB(rgba))
            default: return nil
            }
            return .color(rgba)
        }
        switch fields["NSColorSpace"] {
        case .int(1), .int(2):
            guard fields["NSWhite"] == nil else { return nil }
            return colorComponents(fields["NSRGB"], rgb: true).map { .color($0) }
        case .int(3), .int(4):
            guard fields["NSRGB"] == nil else { return nil }
            return colorComponents(fields["NSWhite"], rgb: false).map { .color($0) }
        default:
            return nil
        }
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

    /// Display P3 channels to bounded sRGB, CSS Color 4's matrices, as the
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

    private static func archiveClassName(of root: ArchiveValue, objects: [ArchiveValue]) -> String? {
        guard case .object(let fields) = root,
              case .uid(let index)? = fields["$class"], objects.indices.contains(Int(index)),
              case .object(let classInfo) = objects[Int(index)],
              case .string(let name)? = classInfo["$classname"] else { return nil }
        return name
    }

    private static func archiveReferenced(_ key: String, in fields: [String: ArchiveValue],
                                          objects: [ArchiveValue]) -> ArchiveValue? {
        guard case .uid(let index)? = fields[key], objects.indices.contains(Int(index)) else { return nil }
        return objects[Int(index)]
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
    /// its `$top` names.
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
                  objects.indices.contains(Int(rootIndex)) else { return nil }
            self.root = objects[Int(rootIndex)]
            self.objects = objects
        }
    }

    /// A reader for the subset of the binary property-list format keyed
    /// archives use, with the same bounded shapes the XTF decoder accepts.
    private struct BinaryPlistReader {
        private static let maximumInput = 64 * 1024
        private static let maximumObjects = 4096
        private static let maximumDepth = 32
        private static let header = Data("bplist00".utf8)

        private let data: Data
        private let offsets: [Int]
        private let referenceSize: Int

        init(_ input: Data) throws {
            guard input.count >= Self.header.count + 32 + 1, input.count <= Self.maximumInput,
                  input.prefix(Self.header.count) == Self.header else { throw CocoaError(.fileReadCorruptFile) }
            let trailer = input.count - 32
            let offsetIntSize = Int(input[input.count - 26])
            let referenceSize = Int(input[input.count - 25])
            let count = Self.uint64(input, input.count - 24, 8)
            let tableOffset = Self.uint64(input, input.count - 8, 8)
            guard (1...8).contains(offsetIntSize), (1...8).contains(referenceSize),
                  count >= 1, count <= Self.maximumObjects,
                  tableOffset >= Self.header.count,
                  tableOffset + count * UInt64(offsetIntSize) <= UInt64(trailer) else {
                throw CocoaError(.fileReadCorruptFile)
            }
            var offsets: [Int] = []
            offsets.reserveCapacity(Int(count))
            for index in 0..<count {
                let offset = Self.uint64(input, Int(tableOffset) + Int(index) * offsetIntSize, offsetIntSize)
                guard offset < UInt64(trailer) else { throw CocoaError(.fileReadCorruptFile) }
                offsets.append(Int(offset))
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
                throw CocoaError(.fileReadCorruptFile)
            }
            var cursor = offsets[index]
            return try parse(at: &cursor, depth: depth)
        }

        private func parse(at cursor: inout Int, depth: Int) throws -> ArchiveValue {
            guard cursor < data.count else { throw CocoaError(.fileReadCorruptFile) }
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
                default: throw CocoaError(.fileReadCorruptFile)
                }
            case 0x1:  // int, big-endian two's complement
                let size = 1 << Int(marker & 0x0f)
                guard size <= 8 else { throw CocoaError(.fileReadCorruptFile) }  // no 128-bit
                let bits = Self.uint64(data, cursor, size)
                cursor += size
                let value = Int64(bitPattern: bits << (64 - 8 * size)) >> (64 - 8 * size)
                return .int(value)
            case 0x2:  // real
                switch marker & 0x0f {
                case 0x2:
                    let bits = UInt32(truncatingIfNeeded: Self.uint64(data, cursor, 4))
                    cursor += 4
                    return .double(Double(Float(bitPattern: bits)))
                case 0x3:
                    let bits = Self.uint64(data, cursor, 8)
                    cursor += 8
                    return .double(Double(bitPattern: bits))
                default: throw CocoaError(.fileReadCorruptFile)
                }
            case 0x4:  // data
                let count = try length(Int(marker & 0x0f), at: &cursor)
                guard cursor + count <= data.count else { throw CocoaError(.fileReadCorruptFile) }
                let payload = data.subdata(in: cursor..<(cursor + count))
                cursor += count
                return .data(payload)
            case 0x5:  // ASCII string
                let count = try length(Int(marker & 0x0f), at: &cursor)
                guard cursor + count <= data.count,
                      let text = String(data: data.subdata(in: cursor..<(cursor + count)), encoding: .ascii) else {
                    throw CocoaError(.fileReadCorruptFile)
                }
                cursor += count
                return .string(text)
            case 0x6:  // UTF-16BE string; the length counts code units
                let units = try length(Int(marker & 0x0f), at: &cursor)
                guard cursor + units * 2 <= data.count,
                      let text = String(data: data.subdata(in: cursor..<(cursor + units * 2)),
                                       encoding: .utf16BigEndian) else {
                    throw CocoaError(.fileReadCorruptFile)
                }
                cursor += units * 2
                return .string(text)
            case 0x8:  // UID
                let size = Int(marker & 0x0f) + 1
                guard size <= 8 else { throw CocoaError(.fileReadCorruptFile) }
                let value = Self.uint64(data, cursor, size)
                cursor += size
                return .uid(value)
            case 0xa:  // array
                let count = try length(Int(marker & 0x0f), at: &cursor)
                var items: [ArchiveValue] = []
                for _ in 0..<count {
                    items.append(try object(at: Int(try reference(at: &cursor)), depth: depth + 1))
                }
                return .array(items)
            case 0xd:  // dictionary
                let count = try length(Int(marker & 0x0f), at: &cursor)
                var keys: [Int] = []
                for _ in 0..<count { keys.append(Int(try reference(at: &cursor))) }
                var fields: [String: ArchiveValue] = [:]
                for key in keys {
                    let keyObject = try object(at: key, depth: depth + 1)
                    guard case .string(let name) = keyObject, name.utf8.count <= 128 else {
                        throw CocoaError(.fileReadCorruptFile)
                    }
                    fields[name] = try object(at: Int(try reference(at: &cursor)), depth: depth + 1)
                }
                return .object(fields)
            default:
                throw CocoaError(.fileReadCorruptFile)
            }
        }

        /// A collection length, short form or the int object that follows the
        /// 0xf marker, bounded to the input size.
        private func length(_ info: Int, at cursor: inout Int) throws -> Int {
            guard cursor < data.count else { throw CocoaError(.fileReadCorruptFile) }
            guard info == 0x0f else { return info }
            let marker = data[cursor]
            guard marker >> 4 == 0x1, 1 << Int(marker & 0x0f) <= 8 else { throw CocoaError(.fileReadCorruptFile) }
            cursor += 1
            let size = 1 << Int(marker & 0x0f)
            let value = Self.uint64(data, cursor, size)
            cursor += size
            guard value <= Self.maximumInput else { throw CocoaError(.fileReadCorruptFile) }
            return Int(value)
        }

        private func reference(at cursor: inout Int) throws -> UInt64 {
            let value = Self.uint64(data, cursor, referenceSize)
            cursor += referenceSize
            return value
        }

        private static func uint64(_ data: Data, _ start: Int, _ size: Int) -> UInt64 {
            var value: UInt64 = 0
            for index in start..<(start + size) {
                value = value << 8 | UInt64(data[index])
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
            ids.append(id == "tpu" ? "npu" : (id == "gpu_memory" ? "vram" : id))
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

    /// The v40 module id for a catalog graph id; nil for a graph the
    /// version-40 model does not know — stock joins it in a later task.
    private static let moduleIds: [String: String] = [
        "cpu": "cpu", "gpu": "gpu", "npu": "tpu", "vram": "gpu_memory", "memory": "memory",
        "battery": "battery", "temperature": "temperature", "network": "network", "disk": "disk",
        "ai": "ai", "processes": "processes", "fans": "fans", "weather": "weather",
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

    private static func viewTheme(_ document: XRGSettingsDocument, _ catalog: XRGSettingsCatalog) -> JSONValue {
        let preset = document.value("themes.preset", catalog: catalog)
        if case .string(let name) = preset, name != "Custom",
           XRGBuiltinTheme.allCases.contains(where: { $0.name == name }) {
            return .object(["kind": .string("builtin"), "name": .string(name)])
        }
        // A custom theme's document is the palette the appearance entries
        // carry, in the shared ABI's order, under the theme's name.
        let paletteIds = ["appearance.window.color", "appearance.graph_background.color",
                          "appearance.series1.color", "appearance.series2.color", "appearance.series3.color",
                          "appearance.border.color", "appearance.text.color"]
        let palette: [[Double]] = paletteIds.map { id in
            let value = document.value(id, catalog: catalog)
            if case .color(let rgba) = value { return rgba }
            if let entry = catalog.entry(id), case .color(let fallback) = entry.defaultValue { return fallback }
            return [0, 0, 0, 1]
        }
        return .object([
            "kind": .string("custom"),
            "theme": .object([
                "colors": .array(palette.map { viewJSON(.color($0)) }),
                "format": .string("xrg-ng-theme"),
                "name": viewString("themes.name", document, catalog),
                "version": .number("1"),
            ]),
        ])
    }
}
