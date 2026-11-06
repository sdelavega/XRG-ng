// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Stephen de la Vega.

import Foundation

/// How a setting is edited in the settings window.
public enum XRGSettingsControl: String, Codable, Sendable {
    case toggle, choice, segmented, integer, decimal, duration, color, path, text, source, action
    /// A reorderable list of ids; the value is the ids, comma-separated, in
    /// display order.
    case order
}

/// The platforms a setting exists on; a setting is not shown elsewhere.
public enum XRGSettingsPlatform: String, Codable, Sendable {
    case macos, linux
}

/// A typed settings value. `null` means "not set": the platform inherits.
public enum XRGSettingsValue: Codable, Equatable, Sendable {
    case bool(Bool)
    case int(Int64)
    case double(Double)
    case string(String)
    /// Red, green, blue and opacity, each between 0 and 1.
    case color([Double])
    case null

    public init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if container.decodeNil() {
            self = .null
            return
        }
        // Whole JSON numbers decode as int before double so the catalog keeps
        // the distinction its controls imply; JSON booleans only decode as Bool.
        if let value = try? container.decode(Int64.self) {
            self = .int(value)
        } else if let value = try? container.decode(Double.self) {
            self = .double(value)
        } else if let value = try? container.decode(Bool.self) {
            self = .bool(value)
        } else if let value = try? container.decode(String.self) {
            self = .string(value)
        } else if let value = try? container.decode([Double].self) {
            guard value.count == 4, value.allSatisfy({ $0.isFinite && (0...1).contains($0) }) else {
                throw DecodingError.dataCorruptedError(in: container,
                    debugDescription: "a color value must be four finite numbers between 0 and 1")
            }
            self = .color(value)
        } else {
            throw DecodingError.dataCorruptedError(in: container,
                debugDescription: "unsupported settings value")
        }
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        switch self {
        case .bool(let value): try container.encode(value)
        case .int(let value): try container.encode(value)
        case .double(let value): try container.encode(value)
        case .string(let value): try container.encode(value)
        case .color(let value): try container.encode(value)
        case .null: try container.encodeNil()
        }
    }
}

/// Bounds for number and duration controls.
public struct XRGSettingsRange: Codable, Equatable, Sendable {
    public var min: Double
    public var max: Double
    public var step: Double?
    public var unit: String?

    public init(min: Double, max: Double, step: Double? = nil, unit: String? = nil) {
        self.min = min
        self.max = max
        self.step = step
        self.unit = unit
    }
}

/// One selectable value of a choice or segmented control.
public struct XRGSettingsOption: Codable, Equatable, Sendable {
    public var value: XRGSettingsValue
    public var label: String

    public init(value: XRGSettingsValue, label: String) {
        self.value = value
        self.label = label
    }
}

/// Where a setting lived before the unified settings document, used only by
/// migration. `macos` names a defaults key; `linux` is a JSON pointer into the
/// version-40 file. The transform names are listed in docs/settings-inventory.md.
public struct XRGSettingsLegacy: Codable, Equatable, Sendable {
    public var macos: String?
    public var macosTransform: String?
    public var linux: String?
    public var linuxTransform: String?

    public init(macos: String? = nil, macosTransform: String? = nil,
                linux: String? = nil, linuxTransform: String? = nil) {
        self.macos = macos
        self.macosTransform = macosTransform
        self.linux = linux
        self.linuxTransform = linuxTransform
    }
}

/// Another entry, and the value it must hold, for this control to be enabled.
public struct XRGSettingsDependency: Codable, Equatable, Sendable {
    public var id: String
    public var equals: XRGSettingsValue

    public init(id: String, equals: XRGSettingsValue) {
        self.id = id
        self.equals = equals
    }
}

/// One setting: identity, presentation, default, bounds and legacy location.
public struct XRGSettingsEntry: Codable, Equatable, Sendable {
    public var id: String
    public var section: String
    public var group: String
    public var label: String
    public var help: String?
    public var control: XRGSettingsControl
    public var defaultValue: XRGSettingsValue
    public var range: XRGSettingsRange?
    public var options: [XRGSettingsOption]?
    public var platforms: [XRGSettingsPlatform]
    /// False marks persisted document state that is edited outside the
    /// settings window (window geometry and collapse latches, module sizes,
    /// auxiliary-window state). The settings windows never render these
    /// entries, and the window-control coverage check must skip them; they
    /// exist so every persisted value has one defined home in the document.
    /// Absent in the JSON means true.
    public var shown: Bool
    public var legacy: XRGSettingsLegacy?
    public var depends: XRGSettingsDependency?
    /// The runtime source kind (`temperature`, `gpu`, ...) whose options the
    /// platform supplies for a `source` control.
    public var source: String?

    public init(id: String, section: String, group: String, label: String, help: String? = nil,
                control: XRGSettingsControl, defaultValue: XRGSettingsValue,
                range: XRGSettingsRange? = nil, options: [XRGSettingsOption]? = nil,
                platforms: [XRGSettingsPlatform], legacy: XRGSettingsLegacy? = nil,
                depends: XRGSettingsDependency? = nil, source: String? = nil, shown: Bool = true) {
        self.id = id
        self.section = section
        self.group = group
        self.label = label
        self.help = help
        self.control = control
        self.defaultValue = defaultValue
        self.range = range
        self.options = options
        self.platforms = platforms
        self.legacy = legacy
        self.depends = depends
        self.source = source
        self.shown = shown
    }

    private enum CodingKeys: String, CodingKey {
        case id, section, group, label, help, control
        case defaultValue = "default"
        case range, options, platforms, shown, legacy, depends, source
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(String.self, forKey: .id)
        section = try container.decode(String.self, forKey: .section)
        group = try container.decode(String.self, forKey: .group)
        label = try container.decode(String.self, forKey: .label)
        help = try container.decodeIfPresent(String.self, forKey: .help)
        control = try container.decode(XRGSettingsControl.self, forKey: .control)
        defaultValue = try container.decode(XRGSettingsValue.self, forKey: .defaultValue)
        range = try container.decodeIfPresent(XRGSettingsRange.self, forKey: .range)
        options = try container.decodeIfPresent([XRGSettingsOption].self, forKey: .options)
        platforms = try container.decode([XRGSettingsPlatform].self, forKey: .platforms)
        shown = try container.decodeIfPresent(Bool.self, forKey: .shown) ?? true
        legacy = try container.decodeIfPresent(XRGSettingsLegacy.self, forKey: .legacy)
        depends = try container.decodeIfPresent(XRGSettingsDependency.self, forKey: .depends)
        source = try container.decodeIfPresent(String.self, forKey: .source)
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(id, forKey: .id)
        try container.encode(section, forKey: .section)
        try container.encode(group, forKey: .group)
        try container.encode(label, forKey: .label)
        try container.encodeIfPresent(help, forKey: .help)
        try container.encode(control, forKey: .control)
        try container.encode(defaultValue, forKey: .defaultValue)
        try container.encodeIfPresent(range, forKey: .range)
        try container.encodeIfPresent(options, forKey: .options)
        try container.encode(platforms, forKey: .platforms)
        // The canonical file omits `shown` when true; keep that form stable.
        if !shown { try container.encode(false, forKey: .shown) }
        try container.encodeIfPresent(legacy, forKey: .legacy)
        try container.encodeIfPresent(depends, forKey: .depends)
        try container.encodeIfPresent(source, forKey: .source)
    }
}

public enum XRGSettingsCatalogError: Error, Equatable, Sendable {
    case empty
    case duplicateID(String)
    case unknownSection(String)
}

/// The settings catalog: every user-facing setting, in display order.
public struct XRGSettingsCatalog: Sendable {
    /// The section list, in sidebar order (decision D7).
    public static let sections: [String] = ["general", "appearance", "graphs", "sources", "ai",
                                            "weather", "stocks", "themes"]

    public let entries: [XRGSettingsEntry]

    public init(entries: [XRGSettingsEntry]) throws {
        guard !entries.isEmpty else { throw XRGSettingsCatalogError.empty }
        var seen: Set<String> = []
        for entry in entries {
            guard !seen.contains(entry.id) else { throw XRGSettingsCatalogError.duplicateID(entry.id) }
            seen.insert(entry.id)
            guard Self.sections.contains(entry.section) else {
                throw XRGSettingsCatalogError.unknownSection(entry.section)
            }
        }
        self.entries = entries
    }

    public init(data: Data) throws {
        let decoded = try JSONDecoder().decode([XRGSettingsEntry].self, from: data)
        try self.init(entries: decoded)
    }

    /// The embedded catalog; the single source of truth for both windows.
    public static func load() throws -> XRGSettingsCatalog {
        try XRGSettingsCatalog(data: Data(XRGSettingsCatalogData.json.utf8))
    }

    public func entry(_ id: String) -> XRGSettingsEntry? {
        entries.first { $0.id == id }
    }

    public func entries(section: String, platform: XRGSettingsPlatform) -> [XRGSettingsEntry] {
        entries.filter { $0.section == section && $0.platforms.contains(platform) }
    }
}
