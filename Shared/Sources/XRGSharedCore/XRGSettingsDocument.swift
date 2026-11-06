// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Stephen de la Vega.

import Foundation

/// A JSON value of a settings document, used only for the keys the catalog
/// does not know, so they survive a load and a save verbatim: the other
/// platform's settings, and settings from a newer version of the app, must not
/// be lost by an older core. The document's canonical writer re-emits integral
/// numbers without a fraction; values are compared by value, never by case.
public enum JSONValue: Codable, Equatable, Sendable {
    case null
    case bool(Bool)
    case number(Double)
    case string(String)
    case array([JSONValue])
    case object([String: JSONValue])

    public init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if container.decodeNil() {
            self = .null
            return
        }
        // The modern decoder keeps JSON types strict (a number never decodes
        // as Bool and vice versa), which the catalog's own decoding relies on.
        if let value = try? container.decode(Bool.self) { self = .bool(value); return }
        if let value = try? container.decode(Double.self) { self = .number(value); return }
        if let value = try? container.decode(String.self) { self = .string(value); return }
        if let value = try? container.decode([JSONValue].self) { self = .array(value); return }
        if let value = try? container.decode([String: JSONValue].self) { self = .object(value); return }
        throw DecodingError.dataCorruptedError(in: container,
            debugDescription: "unsupported JSON value")
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        switch self {
        case .null: try container.encodeNil()
        case .bool(let value): try container.encode(value)
        case .number(let value): try container.encode(value)
        case .string(let value): try container.encode(value)
        case .array(let value): try container.encode(value)
        case .object(let value): try container.encode(value)
        }
    }
}

/// One problem found while loading a settings document. `problem` is one of
/// the four constant strings: `malformed`, `unsupported-version`,
/// `invalid-value`, `unknown-format`; `id` names the settings key an
/// `invalid-value` diagnostic is about, and is nil for document-level
/// problems.
public struct XRGSettingsDiagnostic: Codable, Equatable, Sendable {
    public static let malformed = "malformed"
    public static let unsupportedVersion = "unsupported-version"
    public static let invalidValue = "invalid-value"
    public static let unknownFormat = "unknown-format"

    public var id: String?
    public var problem: String

    public init(id: String? = nil, problem: String) {
        self.id = id
        self.problem = problem
    }
}

/// Why a value was refused for a setting.
public enum XRGSettingsError: Error, Equatable, Sendable {
    /// The id is not in the catalog.
    case unknownId
    /// The value cannot have this control's shape (an action has no value).
    case wrongType
    /// A number or duration outside its bounds, carrying the bounds.
    case outOfRange(min: Double, max: Double)
    /// A choice value outside its options, or an order list that is not the
    /// default ids rearranged.
    case notAnOption
    /// The entry's `depends` requirement does not hold.
    case dependencyNotMet
}

/// The result of loading a settings document. `.unreadable` means the file is
/// malformed, of an unknown format, or of a newer version: the caller runs on
/// defaults and must not overwrite the file without the user's confirmation.
public enum XRGSettingsLoad: Equatable, Sendable {
    case ok(XRGSettingsDocument, [XRGSettingsDiagnostic])
    case unreadable(XRGSettingsDiagnostic)
}

/// One settings document: the values of the catalog ids the file stored, plus
/// every unknown key preserved verbatim.
///
/// The document keeps one invariant: `values` only ever holds a valid value
/// that differs from its entry's catalog default (storing the default removes
/// the key), and `unknown` only holds keys the catalog does not know. That is
/// what lets `serialized()` write every stored value without needing the
/// catalog: the written settings are exactly the differing values plus the
/// unknown keys, sorted, in the canonical form of the spec (UTF-8, LF, sorted
/// keys, two-space indent, trailing newline).
public struct XRGSettingsDocument: Equatable, Sendable {
    public static let format = "xrg-ng-settings"
    public static let version = 1

    /// Stored values of catalog ids, each differing from its default.
    public private(set) var values: [String: XRGSettingsValue]
    /// Keys the catalog does not know, preserved verbatim.
    public private(set) var unknown: [String: JSONValue]

    init(values: [String: XRGSettingsValue] = [:], unknown: [String: JSONValue] = [:]) {
        self.values = values
        self.unknown = unknown
    }

    /// Parse and validate a settings document. Values that fail their entry's
    /// rules fall back to the catalog default for that key only and are
    /// reported as diagnostics; the rest of the document still loads. Keys the
    /// catalog does not know — in `settings` or at the top level — are
    /// preserved in `unknown`. A malformed file, a file of another format, or
    /// a newer version is `.unreadable`: the caller must not overwrite it.
    public static func load(_ data: Data, catalog: XRGSettingsCatalog) -> XRGSettingsLoad {
        let malformed = XRGSettingsDiagnostic(id: nil, problem: XRGSettingsDiagnostic.malformed)
        guard let root = try? JSONDecoder().decode(JSONValue.self, from: data),
              case .object(let fields) = root else {
            return .unreadable(malformed)
        }
        guard let formatField = fields["format"], case .string(let format) = formatField else {
            return .unreadable(malformed)
        }
        guard format == Self.format else {
            return .unreadable(XRGSettingsDiagnostic(id: nil, problem: XRGSettingsDiagnostic.unknownFormat))
        }
        guard let versionField = fields["version"], case .number(let versionNumber) = versionField,
              let version = Int(exactly: versionNumber) else {
            return .unreadable(malformed)
        }
        guard version == Self.version else {
            // Only a newer version is "unsupported": an older or fractional
            // version simply is not a well-formed version-1 document.
            let problem = version > Self.version ? XRGSettingsDiagnostic.unsupportedVersion
                                                 : XRGSettingsDiagnostic.malformed
            return .unreadable(XRGSettingsDiagnostic(id: nil, problem: problem))
        }
        guard let settingsField = fields["settings"], case .object(let settings) = settingsField else {
            return .unreadable(malformed)
        }

        var values: [String: XRGSettingsValue] = [:]
        var unknown: [String: JSONValue] = [:]
        var diagnostics: [XRGSettingsDiagnostic] = []
        func resolve(_ key: String, _ json: JSONValue) {
            guard let entry = catalog.entry(key) else {
                unknown[key] = json
                return
            }
            guard let value = XRGSettingsValue(json: json), Self.validate(value, for: entry) == nil else {
                diagnostics.append(XRGSettingsDiagnostic(id: key, problem: XRGSettingsDiagnostic.invalidValue))
                return
            }
            // A value at its default is not stored: it is the default.
            guard !XRGSettingsValue.sameValue(value, entry.defaultValue) else { return }
            values[key] = value
        }
        // Deterministic diagnostics: settings keys in canonical sort order.
        for key in settings.keys.sorted(by: Self.precedes) {
            resolve(key, settings[key]!)
        }
        // `settings` is the document's one value namespace, so a top-level
        // key the format does not define is carried there too: it round-trips
        // through older cores byte-stably after the first save. A newer
        // version that restructures the document bumps `version` and is
        // already refused above.
        let extras = fields.keys.filter {
            $0 != "format" && $0 != "version" && $0 != "settings" && settings[$0] == nil
        }.sorted(by: Self.precedes)
        for key in extras {
            resolve(key, fields[key]!)
        }
        return .ok(XRGSettingsDocument(values: values, unknown: unknown), diagnostics)
    }

    /// The document with every setting at its default: no stored values and
    /// no unknown keys. `value(_:catalog:)` resolves each entry's default
    /// through the catalog, so the defaults document itself is the same for
    /// both platforms; the parameters keep call sites explicit and match the
    /// shape of the load and migration entry points.
    public static func defaults(catalog: XRGSettingsCatalog, platform: XRGSettingsPlatform) -> XRGSettingsDocument {
        XRGSettingsDocument()
    }

    /// The effective value of a setting: the stored value, or the entry's
    /// catalog default. An id the catalog does not know reads as `null`.
    public func value(_ id: String, catalog: XRGSettingsCatalog) -> XRGSettingsValue {
        if let stored = values[id] { return stored }
        return catalog.entry(id)?.defaultValue ?? .null
    }

    /// Store a value for a setting, enforcing the entry's rules. Storing the
    /// entry's default removes the value again, so defaults are never
    /// serialised. A `depends` requirement must already hold (its control is
    /// disabled in the window otherwise); the dependency is checked against
    /// the effective value, so setting it to its default counts.
    public mutating func set(_ id: String, _ value: XRGSettingsValue, catalog: XRGSettingsCatalog) throws(XRGSettingsError) {
        guard let entry = catalog.entry(id) else { throw .unknownId }
        if let depends = entry.depends {
            guard XRGSettingsValue.sameValue(self.value(depends.id, catalog: catalog), depends.equals) else {
                throw .dependencyNotMet
            }
        }
        if let error = Self.validate(value, for: entry) { throw error }
        if XRGSettingsValue.sameValue(value, entry.defaultValue) {
            values.removeValue(forKey: id)
        } else {
            values[id] = value
        }
    }

    /// Restore every entry of one section to its default for `platform`.
    /// Other sections, and unknown keys, are not touched.
    public mutating func resetSection(_ section: String, catalog: XRGSettingsCatalog, platform: XRGSettingsPlatform) {
        for entry in catalog.entries(section: section, platform: platform) {
            values.removeValue(forKey: entry.id)
        }
    }

    /// The canonical bytes of the document: UTF-8, LF, sorted keys, two-space
    /// indent, trailing newline; `settings` holds the stored values plus every
    /// unknown key. Only values that differ from their default are ever
    /// stored, so all of them are written.
    public func serialized() -> Data {
        var text = "{\n"
        text += "  \"format\": " + Self.quote(Self.format) + ",\n"
        text += "  \"settings\": " + Self.renderSettings(values: values, unknown: unknown) + ",\n"
        text += "  \"version\": \(Self.version)\n"
        text += "}"
        return Data(text.utf8) + Data([0x0a])
    }

    // MARK: - Validation

    /// The rules `set` enforces and `load` reports as an invalid value: the
    /// error is nil when the value may be stored for the entry. `null` means
    /// "not set" (the platform inherits) and is allowed for every control,
    /// matching the catalog convention; an action is a button and holds no
    /// document value at all.
    static func validate(_ value: XRGSettingsValue, for entry: XRGSettingsEntry) -> XRGSettingsError? {
        if case XRGSettingsValue.null = value {
            return entry.control == .action ? .wrongType : nil
        }
        switch entry.control {
        case .action:
            return .wrongType
        case .toggle:
            guard case .bool = value else { return .wrongType }
            return nil
        case .integer:
            guard case .int = value else { return .wrongType }
            return Self.rangeError(of: value, for: entry)
        case .decimal, .duration:
            // Numbers compare by value: a whole number decodes as `.int`
            // (the catalog convention), so a decimal accepts integers too.
            guard let number = value.numberValue, number.isFinite else { return .wrongType }
            return Self.rangeError(of: value, for: entry)
        case .choice, .segmented:
            return entry.options?.contains { XRGSettingsValue.sameValue($0.value, value) } == true
                ? nil : .notAnOption
        case .color:
            guard case .color(let rgba) = value, rgba.count == 4,
                  rgba.allSatisfy({ $0.isFinite && (0...1).contains($0) }) else { return .wrongType }
            return nil
        case .path, .text:
            guard case .string = value else { return .wrongType }
            return nil
        case .source:
            switch value {
            case .string, .int: return nil
            default: return .wrongType
            }
        case .order:
            guard case .string(let list) = value else { return .wrongType }
            return entry.containsSameIds(as: list) ? nil : .notAnOption
        }
    }

    private static func rangeError(of value: XRGSettingsValue, for entry: XRGSettingsEntry) -> XRGSettingsError? {
        guard let range = entry.range else { return nil }
        guard let number = value.numberValue, number >= range.min, number <= range.max else {
            return .outOfRange(min: range.min, max: range.max)
        }
        return nil
    }

    // MARK: - Canonical rendering

    /// Keys sort by their UTF-8 bytes — the order JSON tooling uses on every
    /// platform, so the canonical bytes do not depend on the platform.
    static func precedes(_ a: String, _ b: String) -> Bool {
        a.utf8.lexicographicallyPrecedes(b.utf8)
    }

    private static func renderSettings(values: [String: XRGSettingsValue], unknown: [String: JSONValue]) -> String {
        guard !values.isEmpty || !unknown.isEmpty else { return "{}" }
        var rendered: [String: String] = [:]
        for (key, json) in unknown { rendered[key] = render(json, indent: "    ") }
        for (key, value) in values { rendered[key] = render(value, indent: "    ") }
        let body = rendered.keys.sorted(by: precedes)
            .map { "    " + quote($0) + ": " + rendered[$0]! }
            .joined(separator: ",\n")
        return "{\n" + body + "\n  }"
    }

    private static func render(_ value: XRGSettingsValue, indent: String) -> String {
        switch value {
        case .null: return "null"
        case .bool(let value): return value ? "true" : "false"
        case .int(let value): return String(value)
        case .double(let value): return number(value)
        case .string(let value): return quote(value)
        case .color(let rgba):
            let body = rgba.map { indent + "  " + number($0) }.joined(separator: ",\n")
            return "[\n" + body + "\n" + indent + "]"
        }
    }

    private static func render(_ json: JSONValue, indent: String) -> String {
        switch json {
        case .null: return "null"
        case .bool(let value): return value ? "true" : "false"
        case .number(let value): return number(value)
        case .string(let value): return quote(value)
        case .array(let items):
            if items.isEmpty { return "[]" }
            let body = items.map { indent + "  " + render($0, indent: indent + "  ") }
                .joined(separator: ",\n")
            return "[\n" + body + "\n" + indent + "]"
        case .object(let fields):
            if fields.isEmpty { return "{}" }
            let body = fields.keys.sorted(by: precedes)
                .map { indent + "  " + quote($0) + ": " + render(fields[$0]!, indent: indent + "  ") }
                .joined(separator: ",\n")
            return "{\n" + body + "\n" + indent + "}"
        }
    }

    /// Canonical JSON for a number: integral values have no fraction (a whole
    /// number is an integer, per the catalog convention); everything else uses
    /// Swift's shortest round-trip form, which is the same on every platform.
    /// Non-finite values cannot come from a parse or pass `validate`; they are
    /// rendered defensively (`null` for NaN, a large exponent otherwise).
    static func number(_ value: Double) -> String {
        if value.isNaN { return "null" }
        if value.isInfinite { return value > 0 ? "1e999" : "-1e999" }
        if let integer = Int64(exactly: value) { return String(integer) }
        return String(value)
    }

    /// Canonical JSON for a string: the two mandatory escapes, the short
    /// escapes for the whitespace controls, `\u` for the other control
    /// characters, and raw UTF-8 for everything else.
    static func quote(_ value: String) -> String {
        var out = "\""
        for scalar in value.unicodeScalars {
            switch scalar {
            case "\"": out += "\\\""
            case "\\": out += "\\\\"
            case "\n": out += "\\n"
            case "\r": out += "\\r"
            case "\t": out += "\\t"
            case _ where scalar.value < 0x20:
                let digits = String(scalar.value, radix: 16)
                out += "\\u" + String(repeating: "0", count: 4 - digits.count) + digits
            default:
                out += String(scalar)
            }
        }
        return out + "\""
    }
}

// MARK: - Value helpers (Task 2 types, extended, not redefined)

extension XRGSettingsValue {
    /// The value a settings key of a document holds. Whole JSON numbers
    /// become `.int` (the catalog convention), an RGBA array becomes a color;
    /// nil when the JSON cannot be a settings value at all.
    init?(json: JSONValue) {
        switch json {
        case .null: self = .null
        case .bool(let value): self = .bool(value)
        case .number(let value): self = Self.wholeNumber(value)
        case .string(let value): self = .string(value)
        case .array(let items):
            var components: [Double] = []
            for item in items {
                guard case .number(let value) = item else { return nil }
                components.append(value)
            }
            guard components.count == 4,
                  components.allSatisfy({ $0.isFinite && (0...1).contains($0) }) else { return nil }
            self = .color(components)
        case .object: return nil
        }
    }

    static func wholeNumber(_ value: Double) -> XRGSettingsValue {
        if let integer = Int64(exactly: value) { return .int(integer) }
        return .double(value)
    }

    /// Numbers compare by value (`.int(1)` and `.double(1.0)` are the same
    /// setting), everything else by case.
    static func sameValue(_ a: XRGSettingsValue, _ b: XRGSettingsValue) -> Bool {
        switch (a, b) {
        case (.null, .null): return true
        case (.bool(let a), .bool(let b)): return a == b
        case (.string(let a), .string(let b)): return a == b
        case (.color(let a), .color(let b)): return a == b
        case (.int(let a), .int(let b)): return a == b
        case (.double(let a), .double(let b)): return a == b
        case (.int(let a), .double(let b)): return Double(a) == b
        case (.double(let a), .int(let b)): return a == Double(b)
        default: return false
        }
    }

    /// The numeric value of a number setting, whichever case holds it.
    var numberValue: Double? {
        switch self {
        case .int(let value): return Double(value)
        case .double(let value): return value
        default: return nil
        }
    }
}

extension XRGSettingsEntry {
    /// An `order` value is the same id list as the default, rearranged: the
    /// same ids, each once, in any order.
    func containsSameIds(as list: String) -> Bool {
        guard case .string(let defaultValue) = defaultValue else { return false }
        let ids = list.split(separator: ",", omittingEmptySubsequences: false).sorted()
        let defaultIds = defaultValue.split(separator: ",", omittingEmptySubsequences: false).sorted()
        return ids == defaultIds
    }
}
