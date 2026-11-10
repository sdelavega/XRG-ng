// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Stephen de la Vega.

import Foundation

/// A JSON value of a settings document, used only for the keys the catalog
/// does not know — inside `settings` or at the top level — so they survive a
/// load and a save verbatim: the other platform's settings, and settings from
/// a newer version of the app, must not be lost or altered by an older core.
///
/// A number keeps the exact text it had in the file. `parse` builds values
/// and validates that text against the JSON number grammar, and the
/// document's writer re-emits it unchanged, so an integer beyond the exact
/// range of `Double` (`9007199254740993`, not `9007199254740992`) or a
/// decimal longer than `Double`'s shortest form round-trips byte for byte, at
/// every nesting depth. Two numbers are equal when their original text is.
///
/// Deliberately not `Codable`: a `Decoder` hands numbers back only as
/// `Double`, which cannot round-trip arbitrary JSON numbers, so a conforming
/// implementation would reintroduce exactly the loss this type exists to
/// prevent. Build one from bytes with `parse`; the document's writer
/// serialises one with its canonical renderer.
public enum JSONValue: Equatable, Sendable {
    case null
    case bool(Bool)
    /// A number's original JSON text, a lexeme `parse` has validated.
    case number(String)
    case string(String)
    case array([JSONValue])
    case object([String: JSONValue])

    /// The number as a `Double`, nil for anything that is not a number.
    /// Catalog values only: every catalog range sits far inside `Double`'s
    /// precision. Preserved unknown values never pass through here.
    var doubleValue: Double? {
        guard case .number(let text) = self else { return nil }
        return Double(text)
    }

    /// Parse exactly one JSON value from UTF-8 text, or nil when the JSON
    /// grammar rejects the input: trailing content, an invalid number, a raw
    /// control character in a string, a bad or unpaired `\u` escape, or
    /// nesting deeper than the parser allows. Every number keeps its original
    /// text. Duplicate object members are lenient, like `JSONDecoder`: the
    /// last one wins. A UTF-8 BOM is not whitespace and is rejected.
    static func parse(_ text: String) -> JSONValue? {
        JSONTextParser.parse(text)
    }
}

/// The document's strict JSON parser. `JSONDecoder` cannot be used here: it
/// converts every number to `Double` on the way in, which loses the original
/// text that preserved unknown values must round-trip with. This parser is
/// pure Swift, so it behaves identically on Darwin and corelibs.
private struct JSONTextParser {
    /// A hostile file must not be able to overflow the stack; deeper nesting
    /// is rejected and the document is reported malformed.
    private static let maximumDepth = 256

    private let scalars: [UnicodeScalar]
    private var position = 0

    private init(_ text: String) {
        self.scalars = Array(text.unicodeScalars)
    }

    static func parse(_ text: String) -> JSONValue? {
        var parser = JSONTextParser(text)
        guard let value = parser.parseValue(depth: 0) else { return nil }
        parser.skipWhitespace()
        guard parser.isAtEnd else { return nil }
        return value
    }

    private var current: UnicodeScalar? {
        position < scalars.count ? scalars[position] : nil
    }

    private var isAtEnd: Bool {
        position == scalars.count
    }

    private static func isDigit(_ scalar: UnicodeScalar) -> Bool {
        scalar >= "0" && scalar <= "9"
    }

    private mutating func skipWhitespace() {
        while let scalar = current,
              scalar == " " || scalar == "\t" || scalar == "\n" || scalar == "\r" {
            position += 1
        }
    }

    private mutating func parseValue(depth: Int) -> JSONValue? {
        guard depth <= Self.maximumDepth else { return nil }
        skipWhitespace()
        guard let scalar = current else { return nil }
        switch scalar {
        case "{": return parseObject(depth: depth + 1)
        case "[": return parseArray(depth: depth + 1)
        case "\"": return parseString().map { .string($0) }
        case "t": return parseLiteral("true", .bool(true))
        case "f": return parseLiteral("false", .bool(false))
        case "n": return parseLiteral("null", .null)
        default:
            guard Self.isDigit(scalar) || scalar == "-" else { return nil }
            return parseNumber()
        }
    }

    private mutating func parseObject(depth: Int) -> JSONValue? {
        position += 1  // "{"
        var fields: [String: JSONValue] = [:]
        skipWhitespace()
        if current == "}" { position += 1; return .object(fields) }
        while true {
            skipWhitespace()
            guard let key = parseString() else { return nil }
            skipWhitespace()
            guard current == ":" else { return nil }
            position += 1
            guard let value = parseValue(depth: depth) else { return nil }
            // Duplicate members: the last one wins, as JSONDecoder did.
            fields[key] = value
            skipWhitespace()
            if current == "," { position += 1; continue }
            if current == "}" { position += 1; return .object(fields) }
            return nil
        }
    }

    private mutating func parseArray(depth: Int) -> JSONValue? {
        position += 1  // "["
        var items: [JSONValue] = []
        skipWhitespace()
        if current == "]" { position += 1; return .array(items) }
        while true {
            guard let value = parseValue(depth: depth) else { return nil }
            items.append(value)
            skipWhitespace()
            if current == "," { position += 1; continue }
            if current == "]" { position += 1; return .array(items) }
            return nil
        }
    }

    /// A JSON string. A raw control character is rejected; an escape is one
    /// of the two-character forms or a `\u` escape, and a high surrogate must
    /// be followed by its low half — a lone surrogate is not a Unicode
    /// scalar and cannot live in a Swift string.
    private mutating func parseString() -> String? {
        guard current == "\"" else { return nil }
        position += 1
        var out = String.UnicodeScalarView()
        while let scalar = current {
            position += 1
            if scalar == "\"" { return String(out) }
            if scalar == "\\" {
                guard let escaped = parseEscape() else { return nil }
                out.append(contentsOf: escaped)
                continue
            }
            guard scalar.value >= 0x20 else { return nil }
            out.append(scalar)
        }
        return nil
    }

    /// The scalars of one escape sequence, backslash consumed.
    private mutating func parseEscape() -> [UnicodeScalar]? {
        guard let scalar = current else { return nil }
        position += 1
        switch scalar {
        case "\"": return ["\""]
        case "\\": return ["\\"]
        case "/": return ["/"]
        case "b": return ["\u{08}"]
        case "f": return ["\u{0c}"]
        case "n": return ["\n"]
        case "r": return ["\r"]
        case "t": return ["\t"]
        case "u": return parseUnicodeEscape()
        default: return nil
        }
    }

    private mutating func parseUnicodeEscape() -> [UnicodeScalar]? {
        guard let high = parseHexQuad() else { return nil }
        guard (0xd800...0xdbff).contains(high) else {
            // Not a high surrogate: it must still be an ordinary scalar.
            guard let scalar = UnicodeScalar(high) else { return nil }
            return [scalar]
        }
        // A high surrogate is only half of a pair: the low half must follow
        // as another `\u` escape, whose two characters are consumed here,
        // before the quad is read.
        guard position + 1 < scalars.count, scalars[position] == "\\", scalars[position + 1] == "u" else {
            return nil
        }
        position += 2
        guard let low = parseHexQuad(), (0xdc00...0xdfff).contains(low) else { return nil }
        guard let paired = UnicodeScalar(0x10000 + (high - 0xd800) << 10 + (low - 0xdc00)) else {
            return nil
        }
        return [paired]
    }

    private mutating func parseHexQuad() -> UInt32? {
        var value: UInt32 = 0
        for _ in 0..<4 {
            guard let scalar = current, let digit = Self.hexDigit(of: scalar) else { return nil }
            value = value << 4 | UInt32(digit)
            position += 1
        }
        return value
    }

    private static func hexDigit(of scalar: UnicodeScalar) -> Int? {
        switch scalar {
        case "0"..."9": return Int(scalar.value - 48)
        case "a"..."f": return Int(scalar.value - 97 + 10)
        case "A"..."F": return Int(scalar.value - 65 + 10)
        default: return nil
        }
    }

    /// A number, scanned by the JSON grammar and kept as its original text:
    /// no leading zeros, a fraction needs digits, an exponent needs digits.
    private mutating func parseNumber() -> JSONValue? {
        let start = position
        if current == "-" { position += 1 }
        guard let first = current else { return nil }
        if first == "0" {
            position += 1
        } else if Self.isDigit(first) {
            while let scalar = current, Self.isDigit(scalar) { position += 1 }
        } else {
            return nil
        }
        if current == "." {
            position += 1
            guard scanDigits() else { return nil }
        }
        if let scalar = current, scalar == "e" || scalar == "E" {
            position += 1
            if current == "+" || current == "-" { position += 1 }
            guard scanDigits() else { return nil }
        }
        return .number(String(String.UnicodeScalarView(scalars[start..<position])))
    }

    private mutating func scanDigits() -> Bool {
        var digits = 0
        while let scalar = current, Self.isDigit(scalar) {
            position += 1
            digits += 1
        }
        return digits > 0
    }

    private mutating func parseLiteral(_ literal: String, _ value: JSONValue) -> JSONValue? {
        for expected in literal.unicodeScalars {
            guard current == expected else { return nil }
            position += 1
        }
        return value
    }
}

/// One problem found while loading a settings document. `problem` is one of
/// the four constant strings: `malformed`, `unsupported-version`,
/// `invalid-value`, `unknown-format` — or, from migration only, an
/// `unsupported-color-space:<name>` string naming an archived colour space
/// the reader cannot convert; `id` names the settings key such a
/// diagnostic is about, and is nil for document-level problems.
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
    /// The value breaks the entry's named semantic constraint (final review,
    /// finding 1 / ruling R29): a rule a platform's worker enforces at
    /// runtime, refused here so it is never saved. The constraint's name is
    /// the entry's `constraint`; the windows turn it into the user-facing
    /// reason.
    case constraint
}

/// The result of loading a settings document. `.unreadable` means the file is
/// malformed, of an unknown format, or of a newer version: the caller runs on
/// defaults and must not overwrite the file without the user's confirmation.
public enum XRGSettingsLoad: Equatable, Sendable {
    case ok(XRGSettingsDocument, [XRGSettingsDiagnostic])
    case unreadable(XRGSettingsDiagnostic)
}

/// One settings document: the values of the catalog ids the file stored, plus
/// every unknown key preserved verbatim, at the level it came from.
///
/// The document keeps one invariant: `values` only ever holds a valid value
/// that differs from its entry's catalog default (storing the default removes
/// the key), `unknown` only holds `settings` keys the catalog does not know,
/// and `rootUnknown` only holds root members other than `format`, `version`
/// and `settings`. That is what lets `serialized()` write the document
/// without needing the catalog: the written top level is `format`,
/// `settings`, `version` and every root member, all sorted; `settings` holds
/// the differing values plus the unknown settings keys, sorted; everything
/// in the canonical form of the spec (UTF-8, LF, sorted keys, two-space
/// indent, trailing newline).
public struct XRGSettingsDocument: Equatable, Sendable {
    public static let format = "xrg-ng-settings"
    public static let version = 1

    /// Stored values of catalog ids, each differing from its default.
    public private(set) var values: [String: XRGSettingsValue]
    /// Settings keys the catalog does not know, preserved verbatim.
    public private(set) var unknown: [String: JSONValue]
    /// Root members the format does not define, preserved verbatim and
    /// written back at the top level: never merged into `settings`, never
    /// treated as a setting — even when named like a catalog id.
    public private(set) var rootUnknown: [String: JSONValue]

    init(values: [String: XRGSettingsValue] = [:], unknown: [String: JSONValue] = [:],
         rootUnknown: [String: JSONValue] = [:]) {
        self.values = values
        self.unknown = unknown
        self.rootUnknown = rootUnknown
    }

    /// Parse and validate a settings document. Values that fail their entry's
    /// rules fall back to the catalog default for that key only and are
    /// reported as diagnostics; the rest of the document still loads. Keys
    /// the catalog does not know are preserved verbatim: `unknown` holds the
    /// ones inside `settings`, `rootUnknown` the top-level members the format
    /// does not define. A malformed file, a file of another format, or a
    /// newer version is `.unreadable`: the caller must not overwrite it.
    public static func load(_ data: Data, catalog: XRGSettingsCatalog) -> XRGSettingsLoad {
        let malformed = XRGSettingsDiagnostic(id: nil, problem: XRGSettingsDiagnostic.malformed)
        // The core's own parser, not JSONDecoder: it keeps every number's
        // original text, so preserved values round-trip byte for byte.
        guard let text = String(data: data, encoding: .utf8),
              let root = JSONValue.parse(text),
              case .object(let fields) = root else {
            return .unreadable(malformed)
        }
        guard let formatField = fields["format"], case .string(let format) = formatField else {
            return .unreadable(malformed)
        }
        guard format == Self.format else {
            return .unreadable(XRGSettingsDiagnostic(id: nil, problem: XRGSettingsDiagnostic.unknownFormat))
        }
        guard let versionField = fields["version"], case .number(let versionText) = versionField,
              let versionNumber = Double(versionText), versionNumber.isFinite,
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
        // Deterministic diagnostics: settings keys in canonical sort order.
        for key in settings.keys.sorted(by: Self.precedes) {
            guard let entry = catalog.entry(key) else {
                unknown[key] = settings[key]!
                continue
            }
            guard let value = XRGSettingsValue(json: settings[key]!),
                  Self.validate(value, for: entry) == nil else {
                diagnostics.append(XRGSettingsDiagnostic(id: key, problem: XRGSettingsDiagnostic.invalidValue))
                continue
            }
            // A value at its default is not stored: it is the default.
            guard !XRGSettingsValue.sameValue(value, entry.defaultValue) else { continue }
            values[key] = value
        }
        // Members the format does not define stay at the top level, whatever
        // their name: they are not settings, and `settings` never absorbs
        // them (so a root member can never collide with, or be mistaken
        // for, a setting).
        var rootUnknown: [String: JSONValue] = [:]
        for key in fields.keys where key != "format" && key != "version" && key != "settings" {
            rootUnknown[key] = fields[key]!
        }
        return .ok(XRGSettingsDocument(values: values, unknown: unknown, rootUnknown: rootUnknown), diagnostics)
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

    /// Store a migrated value. The entry's own rules apply — type, bounds,
    /// options — but `depends` does not: migration converts one coherent
    /// legacy state, whose entries may legitimately have been saved in any
    /// order, so a control that depends on another is stored with its own
    /// value and the settings windows render the disabled combination. Used
    /// by `XRGSettingsMigration`; interactive changes go through `set`.
    mutating func storeMigrated(_ id: String, _ value: XRGSettingsValue, catalog: XRGSettingsCatalog) throws(XRGSettingsError) {
        guard let entry = catalog.entry(id) else { throw .unknownId }
        if let error = Self.validate(value, for: entry) { throw error }
        if XRGSettingsValue.sameValue(value, entry.defaultValue) {
            values.removeValue(forKey: id)
        } else {
            values[id] = value
        }
    }

    /// Restore every entry of one section to its default for `platform`.
    /// Other sections, and unknown keys at either level, are not touched.
    public mutating func resetSection(_ section: String, catalog: XRGSettingsCatalog, platform: XRGSettingsPlatform) {
        for entry in catalog.entries(section: section, platform: platform) {
            values.removeValue(forKey: entry.id)
        }
    }

    /// The canonical bytes of the document: UTF-8, LF, sorted keys, two-space
    /// indent, trailing newline. `settings` holds the stored values plus
    /// every unknown settings key; unknown root members are written back at
    /// the top level, sorted with `format`, `settings` and `version`. Only
    /// values that differ from their default are ever stored, so all of them
    /// are written.
    public func serialized() -> Data {
        var members: [String: String] = [
            "format": Self.quote(Self.format),
            "settings": Self.renderSettings(values: values, unknown: unknown),
            "version": "\(Self.version)",
        ]
        for (key, json) in rootUnknown {
            members[key] = Self.render(json, indent: "  ")
        }
        var text = "{\n"
        text += members.keys.sorted(by: Self.precedes)
            .map { "  " + Self.quote($0) + ": " + members[$0]! }
            .joined(separator: ",\n")
        text += "\n}\n"
        return Data(text.utf8)
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
        if let error = Self.shapeError(value, for: entry) { return error }
        // The entry's named semantic constraint, on top of the shape above.
        if let name = entry.constraint, let error = Self.constraintError(value, name: name) {
            return error
        }
        return nil
    }

    /// The control's own shape and range rules.
    private static func shapeError(_ value: XRGSettingsValue, for entry: XRGSettingsEntry) -> XRGSettingsError? {
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

    // MARK: Named semantic constraints (final review, finding 1 / R29)

    /// The constraint names the core implements. The catalog test fails the
    /// build when the catalog names one outside this list, so a constraint
    /// can never silently accept (or refuse) everything.
    public static let constraintNames = [
        "whole-minutes", "icao-station", "absolute-path", "loopback-url", "process-filter",
        "theme-name", "device-name", "source-identity", "cpu-index",
    ]

    /// The error for a value that breaks the entry's named constraint, nil
    /// when the value satisfies it (or the constraint is not known, which
    /// the catalog's transform-coverage test prevents). Every rule here is
    /// one a worker enforces at runtime — the Linux `validate()` walk the
    /// review traced, and the ICAO station the weather collector requires —
    /// so refusing the edit here means no saved document can make a worker
    /// refuse its settings, crash, or quietly change them.
    static func constraintError(_ value: XRGSettingsValue, name: String) -> XRGSettingsError? {
        switch name {
        case "whole-minutes":
            // Whole-minute durations (ruling R30): a fraction is in range
            // for the control but the consumers read whole minutes — the
            // Linux view needs an exact integer and macOS truncates, so a
            // fraction would mean a different setting on each platform.
            guard let number = value.numberValue, number.isFinite,
                  number == number.rounded() else { return .constraint }
            return nil
        case "icao-station":
            if case .null = value { return nil }
            guard case .string(let text) = value else { return .constraint }
            // The worker's own rule: an empty station is "not set" (the
            // platform's default, kept when weather is off); a non-empty
            // one must be a station the worker can address.
            if text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { return nil }
            return XRGWeatherReport.station(text) != nil ? nil : .constraint
        case "absolute-path":
            if case .null = value { return nil }
            guard case .string(let text) = value, Self.isAbsolutePath(text) else { return .constraint }
            return nil
        case "loopback-url":
            if case .null = value { return nil }
            guard case .string(let text) = value, Self.isLoopbackHTTPURL(text) else { return .constraint }
            return nil
        case "process-filter":
            if case .null = value { return nil }
            guard case .string(let text) = value, Self.isPrintableBounded(text, scalars: 128) else {
                return .constraint
            }
            return nil
        case "theme-name":
            if case .null = value { return nil }
            guard case .string(let text) = value,
                  text.trimmingCharacters(in: .whitespacesAndNewlines) == text,
                  !text.isEmpty, text.unicodeScalars.count <= 80,
                  !text.unicodeScalars.contains(where: Self.isControlScalar) else { return .constraint }
            return nil
        case "device-name":
            if case .null = value { return nil }
            guard case .string(let text) = value, Self.isDeviceName(text) else { return .constraint }
            return nil
        case "source-identity":
            if case .null = value { return nil }
            guard case .string(let text) = value, !text.isEmpty, text.utf8.count <= 4096,
                  !text.unicodeScalars.contains(where: Self.isControlScalar) else { return .constraint }
            return nil
        case "cpu-index":
            if case .null = value { return nil }
            switch value {
            case .int(let index): return (0...1_048_575).contains(index) ? nil : .constraint
            case .string(let text):
                guard let index = Int64(text), index >= 0, String(index) == text,
                      (0...1_048_575).contains(index) else { return .constraint }
                return nil
            default: return .constraint
            }
        default:
            // An unknown constraint name never silently accepts the value:
            // the catalog test fails the build for a name the core does not
            // implement, so this arm is unreachable for a shipped catalog.
            return .constraint
        }
    }

    /// A Unicode control character (category Cc), the set Rust's
    /// `char::is_control` accepts and the workers reject.
    static func isControlScalar(_ scalar: Unicode.Scalar) -> Bool {
        scalar.value <= 0x1F || (0x7F...0x9F).contains(scalar.value)
    }

    /// The absolute-path rule the Linux AI readers enforce: rooted, at most
    /// 4096 UTF-8 bytes, no control characters.
    static func isAbsolutePath(_ text: String) -> Bool {
        text.hasPrefix("/") && text.utf8.count <= 4096
            && !text.unicodeScalars.contains(where: Self.isControlScalar)
    }

    /// The loopback-HTTP rule the Linux AI endpoints enforce
    /// (`ai/preferences.rs validate_url`): ASCII, at most 2048 bytes, no
    /// control or whitespace characters, no credentials, query or fragment
    /// markers, and an authority Rust's own `SocketAddr`/`IpAddr` parsing
    /// accepts — a loopback IPv4 address (127.0.0.0/8) or a loopback IPv6
    /// address, bracketed, each with an optional port; a path may follow
    /// the authority. Every textual form the workers' address parser
    /// accepts counts, exactly as it decides: the fully expanded
    /// `[0:0:0:0:0:0:0:1]:11435` works today, so the core must keep
    /// accepting it — and migration must never drop it for the default
    /// endpoint (final review round 2, issue 3 / ruling R34).
    static func isLoopbackHTTPURL(_ text: String) -> Bool {
        guard text.utf8.count <= 2048, text.allSatisfy(\.isASCII) else { return false }
        for scalar in text.unicodeScalars {
            if scalar.value <= 0x20 || scalar.value == 0x7F { return false }
            if "@?#\\".unicodeScalars.contains(scalar) { return false }
        }
        guard text.hasPrefix("http://") else { return false }
        let authority = text.dropFirst("http://".count).prefix { $0 != "/" }
        // A socket authority ("host:port") is accepted exactly the way
        // Rust's `SocketAddr::from_str` decides: an unbracketed IPv4
        // address or a bracketed IPv6 address with a non-zero port — and
        // any textual form of the address inside it that the parser takes.
        if let socket = Self.parseSocketAuthority(authority) {
            guard socket.port != 0, socket.address.isLoopback else { return false }
            if socket.address.isIPv6 {
                guard authority.hasPrefix("[") else { return false }
            } else {
                guard !authority.contains("["), !authority.contains("]") else { return false }
            }
            // The authority parsed as a socket address, so the workers'
            // canonical-form check passes it by construction.
            return true
        }
        // A bare address carries no port: only the canonical authorities
        // survive the workers' final canonical-form comparison — a dotted
        // loopback quad exactly as written, or the bracketed `::1` itself.
        var bare = authority
        while bare.hasPrefix("[") { bare = bare.dropFirst() }
        while bare.hasSuffix("]") { bare = bare.dropLast() }
        guard let address = Self.parseIPAddress(String(bare)), address.isLoopback else { return false }
        if address.isIPv6 {
            return authority == "[::1]"
        }
        return !authority.contains("[") && !authority.contains("]")
    }

    /// One parsed IP address: the 8 groups of an IPv6 address, or the 4
    /// octets of an IPv4 address as two groups, with the family recorded.
    /// The parsers below take exactly what Rust's
    /// `Ipv4Addr`/`Ipv6Addr::from_str` takes (no leading-zero octets, one
    /// `::`, an optional trailing dotted quad).
    struct IPAddress: Sendable {
        var groups: [UInt16]
        var isIPv6: Bool

        var isLoopback: Bool {
            if isIPv6 {
                return groups == [0, 0, 0, 0, 0, 0, 0, 1]
            }
            return groups[0] >> 8 == 127
        }
    }

    /// An IPv4 dotted quad, or nil when Rust's parser would refuse it:
    /// exactly four groups of one to three digits, no leading zeros.
    static func parseIPv4Address(_ text: String) -> [UInt8]? {
        let parts = text.split(separator: ".", omittingEmptySubsequences: false)
        guard parts.count == 4 else { return nil }
        var octets: [UInt8] = []
        for part in parts {
            guard (1...3).contains(part.count), part.allSatisfy(\.isNumber),
                  part.first != "0" || part.count == 1, let octet = UInt8(part) else {
                return nil
            }
            octets.append(octet)
        }
        return octets
    }

    /// An IPv6 address, or nil when Rust's parser would refuse it: up to
    /// eight groups of one to four hex digits, one optional `::` that
    /// expands to the missing groups, and an optional trailing dotted quad
    /// that counts as the last two groups. No zone, no empty groups.
    static func parseIPv6Address(_ text: String) -> [UInt16]? {
        guard !text.isEmpty else { return nil }
        let halves = text.components(separatedBy: "::")
        guard halves.count <= 2 else { return nil }
        let compressed = halves.count == 2
        func groups(of part: String) -> [UInt16]? {
            if part.isEmpty { return [] }
            func hex(_ piece: String) -> UInt16? {
                guard (1...4).contains(piece.count), piece.allSatisfy({ $0.isHexDigit }),
                      let value = UInt16(piece, radix: 16) else { return nil }
                return value
            }
            var pieces = part.split(separator: ":", omittingEmptySubsequences: false).map(String.init)
            guard let last = pieces.popLast() else { return nil }
            var result: [UInt16] = []
            for piece in pieces {
                guard let group = hex(piece) else { return nil }
                result.append(group)
            }
            if last.contains(".") {
                guard let octets = Self.parseIPv4Address(last) else { return nil }
                result.append(UInt16(octets[0]) << 8 | UInt16(octets[1]))
                result.append(UInt16(octets[2]) << 8 | UInt16(octets[3]))
            } else {
                guard let group = hex(last) else { return nil }
                result.append(group)
            }
            return result
        }
        guard let head = groups(of: halves[0]) else { return nil }
        let tail = compressed ? (groups(of: halves[1]) ?? []) : []
        guard head.count + tail.count <= (compressed ? 7 : 8) else { return nil }
        if !compressed, head.count + tail.count != 8 { return nil }
        var result = head
        if compressed {
            while result.count + tail.count < 8 { result.append(0) }
        }
        result.append(contentsOf: tail)
        return result
    }

    /// Either family of address, the way `IpAddr::from_str` decides.
    static func parseIPAddress(_ text: String) -> IPAddress? {
        if let octets = parseIPv4Address(text) {
            return IPAddress(groups: [UInt16(octets[0]) << 8 | UInt16(octets[1]),
                                      UInt16(octets[2]) << 8 | UInt16(octets[3])], isIPv6: false)
        }
        guard let groups = parseIPv6Address(text) else { return nil }
        return IPAddress(groups: groups, isIPv6: true)
    }

    /// A decimal port the way Rust's socket parser reads one: one to five
    /// digits, no leading zeros, within range.
    private static func parsePort(_ text: Substring) -> UInt32? {
        guard (1...5).contains(text.count), text.allSatisfy(\.isNumber),
              text.first != "0", let number = UInt32(text), number <= 65_535 else { return nil }
        return number
    }

    /// A "host:port" socket authority, or nil when Rust's
    /// `SocketAddr::from_str` would refuse it: `[IPv6]:port` or `IPv4:port`.
    static func parseSocketAuthority(_ authority: Substring)
        -> (address: IPAddress, port: UInt32)? {
        if authority.hasPrefix("[") {
            guard let close = authority.firstIndex(of: "]") else { return nil }
            let host = String(authority[authority.index(after: authority.startIndex)..<close])
            var rest = authority[authority.index(after: close)...]
            guard rest.hasPrefix(":") else { return nil }
            rest = rest.dropFirst()
            guard let port = Self.parsePort(rest), let groups = Self.parseIPv6Address(host) else {
                return nil
            }
            return (IPAddress(groups: groups, isIPv6: true), port)
        }
        guard let colon = authority.firstIndex(of: ":") else { return nil }
        let host = String(authority[..<colon])
        guard let port = Self.parsePort(authority[authority.index(after: colon)...]),
              let octets = Self.parseIPv4Address(host) else { return nil }
        return (IPAddress(groups: [UInt16(octets[0]) << 8 | UInt16(octets[1]),
                                   UInt16(octets[2]) << 8 | UInt16(octets[3])], isIPv6: false), port)
    }

    /// At most `scalars` Unicode scalars, none of them a control character:
    /// the process-filter rule the Linux process view enforces.
    static func isPrintableBounded(_ text: String, scalars: Int) -> Bool {
        text.unicodeScalars.count <= scalars
            && !text.unicodeScalars.contains(where: Self.isControlScalar)
    }

    /// The network/disk device-name rule the Linux metric selection enforces:
    /// not empty, not `.` or `..`, at most 255 bytes, and no control,
    /// whitespace, `:` or `/` characters.
    static func isDeviceName(_ text: String) -> Bool {
        guard !text.isEmpty, text != ".", text != "..", text.utf8.count <= 255 else { return false }
        return !text.unicodeScalars.contains { scalar in
            Self.isControlScalar(scalar) || CharacterSet.whitespacesAndNewlines.contains(scalar)
                || scalar == ":" || scalar == "/"
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

    /// Canonical rendering of a JSON tree, sorted keys and two-space indent:
    /// shared with the migration, which renders the Linux view in the same
    /// canonical form (only arrays keep their order; objects sort).
    static func render(_ json: JSONValue, indent: String) -> String {
        switch json {
        case .null: return "null"
        case .bool(let value): return value ? "true" : "false"
        // The number's original text, re-emitted unchanged.
        case .number(let text): return text
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
    /// Preserved unknown numbers never come here: they keep their own text.
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
        case .number:
            // A catalog value goes through Double: every catalog range sits
            // far inside its precision. Preserved unknown values never do.
            guard let number = json.doubleValue else { return nil }
            self = Self.wholeNumber(number)
        case .string(let value): self = .string(value)
        case .array(let items):
            var components: [Double] = []
            for item in items {
                guard let component = item.doubleValue else { return nil }
                components.append(component)
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
