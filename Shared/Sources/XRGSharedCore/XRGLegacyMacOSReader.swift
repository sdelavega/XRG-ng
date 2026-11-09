// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Stephen de la Vega.

import Foundation

/// Platform-independent reproductions of the readers v0.2.2 used for each
/// legacy macOS defaults key.
///
/// Two families must not be mixed:
///
/// - `UserDefaults.bool/integer/double(forKey:)` are NSString
///   `boolValue`/`integerValue`/`doubleValue` (verified on macOS; see the
///   R9 round-2 probe). Those accessors always produce a value.
/// - `XRGWindowPreferences.apply`'s `bool()`/`integer()`/`double()`/`string()`
///   helpers (v0.2.2 `XRGCore/XRGWindowPreferences.swift` ~118–150) use their
///   own spellings, whole-string Swift parsing, bounds and a registered
///   fallback. `"0.5junk"` is not `0.5`; it falls back. Overflow is rejected,
///   not saturated.
///
/// Nothing here calls `NSString.boolValue`/`integerValue`/`doubleValue`, so
/// Linux produces the same results as macOS. The macOS probe this matches:
/// `"Yonder"`/`"yellow"`/`"Tomorrow"`/`"tomato"` boolValue true; leading
/// spaces and tabs skipped (newlines are not); `"+12"` integer 12; `"1.9"`
/// integer 1; overflow saturates to `Int64` bounds; `"0 1"` boolValue false.
enum XRGLegacyMacOSReader {

    /// How v0.2.2 read one defaults key. Blob and plain-text keys stay
    /// strict: their readers do not coerce scalars.
    enum Kind: Equatable {
        case userDefaultsBool
        case userDefaultsInteger
        case userDefaultsDouble
        case windowBool
        case windowInteger(ClosedRange<Int>, WeatherHoursFilter)
        case windowDouble(WindowDoubleRule)
        case windowString
        case strict
    }

    enum WeatherHoursFilter: Equatable {
        case none
        /// `weatherHistoryHours`: after the 0...24 range check, a value
        /// outside `{0, 6, 12, 24}` becomes 0 (v0.2.2 apply).
        case weatherHistory
    }

    enum WindowDoubleRule: Equatable {
        case anyFinite
        case positive
        case unitInterval
    }

    /// The reader for a defaults key (the blob's own key, not a path into
    /// it). Unknown keys stay strict.
    static func kind(of key: String) -> Kind {
        if windowBoolKeys.contains(key) { return .windowBool }
        if let range = windowIntegerRanges[key] {
            return .windowInteger(range, key == "weatherHistoryHours" ? .weatherHistory : .none)
        }
        if let rule = windowDoubleRules[key] { return .windowDouble(rule) }
        if windowStringKeys.contains(key) { return .windowString }
        if userDefaultsBoolKeys.contains(key) { return .userDefaultsBool }
        if userDefaultsIntegerKeys.contains(key) || key.hasSuffix(".HistorySamples.v1")
            || key.hasSuffix(".HistoryMinutes.v1") {
            return .userDefaultsInteger
        }
        if key.hasPrefix("XRGModule_") && (key.hasSuffix("_width") || key.hasSuffix("_height")) {
            return .userDefaultsDouble
        }
        return .strict
    }

    /// The value the original reader produced, ready for the entry's
    /// transform. Custom helpers that reject `raw` return the registered
    /// fallback (or the helper's terminal 0/false/""), never a prefix parse.
    static func decode(_ raw: Any, fallback: Any?, key: String) -> Any {
        switch kind(of: key) {
        case .userDefaultsBool:
            return userDefaultsBool(raw)
        case .userDefaultsInteger:
            return userDefaultsInteger(raw)
        case .userDefaultsDouble:
            return userDefaultsDouble(raw)
        case .windowBool:
            return windowBool(raw, fallback: fallback)
        case .windowInteger(let range, let filter):
            var value = windowInteger(raw, fallback: fallback, range: range)
            if filter == .weatherHistory, ![0, 6, 12, 24].contains(value) { value = 0 }
            return value
        case .windowDouble(let rule):
            return windowDouble(raw, fallback: fallback, valid: rule.valid)
        case .windowString:
            return windowString(raw, fallback: fallback)
        case .strict:
            return raw
        }
    }

    // MARK: macOS NSString scalar accessors (platform-independent)

    /// `NSString.boolValue` as probed on macOS: skip `CharacterSet.whitespaces`
    /// (not newlines), a Y/y/T/t prefix is true, otherwise a sign glued to
    /// digits is nonzero. `"0 1"` is false. `"Yonder"` is true.
    static func nsBoolValue(_ text: String) -> Bool {
        let scalars = Array(text.unicodeScalars)
        let index = skipWhitespaces(scalars, from: 0)
        guard index < scalars.count else { return false }
        switch scalars[index] {
        case "Y", "y", "T", "t": return true
        default:
            return nsIntegerDigits(scalars, from: index, allowGapAfterSign: false) != 0
        }
    }

    /// `NSString.integerValue`: leading whitespace, optional sign, whitespace
    /// again, then digits. Overflow saturates to `Int64` bounds. `"1.9"` is 1.
    static func nsIntegerValue(_ text: String) -> Int64 {
        nsIntegerDigits(Array(text.unicodeScalars), from: 0, allowGapAfterSign: true)
    }

    /// `NSString.doubleValue` for the forms 0.2.2 domains store: leading
    /// whitespace, an optional sign glued to the number, a fraction and an
    /// exponent. A junk suffix is ignored (`"0.5junk"` is 0.5). `"inf"` /
    /// `"nan"` are 0, matching the macOS probe. Whitespace between the sign
    /// and the digits is not accepted (unlike `integerValue`).
    static func nsDoubleValue(_ text: String) -> Double {
        let scalars = Array(text.unicodeScalars)
        var index = skipWhitespaces(scalars, from: 0)
        guard index < scalars.count else { return 0 }
        var negative = false
        if scalars[index] == "+" || scalars[index] == "-" {
            negative = scalars[index] == "-"
            index += 1
        }
        let start = index
        var sawDigit = false
        var sawDot = false
        while index < scalars.count {
            let scalar = scalars[index]
            if scalar >= "0" && scalar <= "9" {
                sawDigit = true
                index += 1
            } else if scalar == "." && !sawDot {
                sawDot = true
                index += 1
            } else {
                break
            }
        }
        guard sawDigit else { return 0 }
        if index < scalars.count, scalars[index] == "e" || scalars[index] == "E" {
            var next = index + 1
            if next < scalars.count, scalars[next] == "+" || scalars[next] == "-" { next += 1 }
            let exponent = next
            while next < scalars.count, scalars[next] >= "0" && scalars[next] <= "9" { next += 1 }
            if next > exponent { index = next }
        }
        let body = String(String.UnicodeScalarView(scalars[start..<index]))
        guard let magnitude = Double(body), magnitude.isFinite else { return 0 }
        return negative ? -magnitude : magnitude
    }

    static func userDefaultsBool(_ raw: Any) -> Bool {
        if let text = raw as? String { return nsBoolValue(text) }
        if let number = raw as? NSNumber { return number.doubleValue != 0 }
        return false
    }

    static func userDefaultsInteger(_ raw: Any) -> Int64 {
        if let text = raw as? String { return nsIntegerValue(text) }
        if let number = raw as? NSNumber { return number.int64Value }
        return 0
    }

    static func userDefaultsDouble(_ raw: Any) -> Double {
        if let text = raw as? String { return nsDoubleValue(text) }
        if let number = raw as? NSNumber { return number.doubleValue }
        return 0
    }

    // MARK: XRGWindowPreferences custom helpers

    /// `bool()`: `YES`/`TRUE`/`1` and `NO`/`FALSE`/`0`/`""` after trim and
    /// uppercase. Anything else, including `"Yonder"`, falls back.
    static func windowBool(_ raw: Any?, fallback: Any?) -> Bool {
        if let parsed = windowBoolSpelling(raw) { return parsed }
        if let parsed = windowBoolSpelling(fallback) { return parsed }
        if let text = fallback as? String { return legacyBoolValue(text) }
        return false
    }

    /// `integer()`: a whole-string `Int`, else a finite `Double` truncated
    /// toward zero when it fits in `Int`. Out of `range`, or `"0.5junk"`,
    /// falls back. Overflow is rejected, not saturated.
    static func windowInteger(_ raw: Any?, fallback: Any?, range: ClosedRange<Int>) -> Int {
        if let parsed = windowIntegerParsed(raw), range.contains(parsed) { return parsed }
        return windowIntegerParsed(fallback) ?? 0
    }

    /// `double()`: `NSNumber.doubleValue` or `Double` of the whole trimmed
    /// string, finite, and passing `valid`. `"0.5junk"` falls back.
    static func windowDouble(_ raw: Any?, fallback: Any?, valid: (Double) -> Bool) -> Double {
        if let parsed = windowNumber(raw), valid(parsed) { return parsed }
        return windowNumber(fallback) ?? 0
    }

    static func windowString(_ raw: Any?, fallback: Any?) -> String {
        if let text = raw as? String { return text }
        if let text = fallback as? String { return text }
        return ""
    }

    /// v0.2.2 `XRGStringUtilities.legacyBoolValue`, used only for a fallback
    /// string the spelling list did not match.
    static func legacyBoolValue(_ value: String) -> Bool {
        !value.isEmpty && value != "0" && value.lowercased() != "no"
    }

    // MARK: Reader tables (v0.2.2 XRGCore)

    /// Keys `XRGWindowPreferences.apply` reads with `bool()` and whose
    /// settings property is what the app shows. `isDockIconHidden` and
    /// `showAITokenGraph` are also passed to `bool()`, but the dock icon and
    /// the AI graph's `isDisplayed` read `defaults.bool(forKey:)` — that
    /// UserDefaults reader is the one listed for them below.
    static let windowBoolKeys: Set<String> = [
        "antiAliasing", "stickyWindow", "checkForUpdates", "dropShadow",
        "autoExpandGraph", "foregroundWhenExpanding", "showSummary",
        "showCPUBars", "separateCPUColor", "showCPUTemperature", "showLoadAverage",
        "cpuShowAverageUsage", "cpuShowUptime", "showMemoryPagingGraph",
        "memoryShowWired", "memoryShowActive", "memoryShowInactive", "memoryShowFree",
        "memoryShowCache", "memoryShowPage", "showTotalBandwidthSinceBoot",
        "showTotalBandwidthSinceLoad", "stockShowChange", "showDJIA",
        "graphOrientationVertical",
    ]

    static let windowIntegerRanges: [String: ClosedRange<Int>] = [
        "windowLevel": 0...2,
        "minimizeUpDown": 0...1,
        "cpuTemperatureUnits": 0...1,
        "secondaryWeatherGraph": 0...5,
        "weatherHistoryHours": 0...24,
        "temperatureUnits": 0...1,
        "distanceUnits": 0...1,
        "pressureUnits": 0...1,
        "tempUnits": 0...1,
        "netMinGraphScale": 0...Int.max,
        "netGraphMode": 0...2,
        "diskGraphMode": 0...2,
        "stockGraphTimeFrame": 0...3,
        "borderWidth": 0...Int(Int32.max),
    ]

    static let windowDoubleRules: [String: WindowDoubleRule] = [
        "graphRefresh": .positive,
        "backgroundTransparency": .unitInterval,
        "graphBGTransparency": .unitInterval,
        "graphFG1Transparency": .unitInterval,
        "graphFG2Transparency": .unitInterval,
        "graphFG3Transparency": .unitInterval,
        "borderTransparency": .unitInterval,
        "textTransparency": .unitInterval,
    ]

    static let windowStringKeys: Set<String> = [
        "windowTitle", "icao", "tempFG1Location", "tempFG2Location", "tempFG3Location",
        "networkInterface", "stockSymbols",
    ]

    /// `defaults.bool(forKey:)` in the views, the app delegate, or
    /// `XRGSettings` — not the custom helper.
    static let userDefaultsBoolKeys: Set<String> = [
        "showCPUGraph", "showGPUGraph", "showNPUGraph", "showVRAMGraph", "showMemoryGraph",
        "showBatteryGraph", "showTemperatureGraph", "showNetworkGraph", "showDiskGraph",
        "showWeatherGraph", "showStockGraph", "showAITokenGraph", "showFansGraph",
        "windowIsMinimized", "tempShowUnknownSensors", "showSensorWindow", "isDockIconHidden",
        "aiTokensTrackingEnabled", "aiTokensDailyAutoReset", "aiTokensAggregateByModel",
        "aiTokensAggregateByProvider", "aiTokensShowRate", "aiTokensShowBreakdown",
    ]

    static let userDefaultsIntegerKeys: Set<String> = [
        "graphStyle", "aiTokensDailyBudget", "aiTokensBudgetNotifyPercent",
    ]

    // MARK: Parsing details

    private static func skipWhitespaces(_ scalars: [Unicode.Scalar], from start: Int) -> Int {
        var index = start
        while index < scalars.count, CharacterSet.whitespaces.contains(scalars[index]) {
            index += 1
        }
        return index
    }

    /// Digits after an optional sign. `allowGapAfterSign` is `integerValue`
    /// (whitespace between the sign and the digits counts); boolValue does not.
    private static func nsIntegerDigits(_ scalars: [Unicode.Scalar], from start: Int,
                                        allowGapAfterSign: Bool) -> Int64 {
        var index = skipWhitespaces(scalars, from: start)
        guard index < scalars.count else { return 0 }
        var negative = false
        if scalars[index] == "+" || scalars[index] == "-" {
            negative = scalars[index] == "-"
            index += 1
            if allowGapAfterSign { index = skipWhitespaces(scalars, from: index) }
        }
        guard index < scalars.count, scalars[index] >= "0" && scalars[index] <= "9" else { return 0 }
        var magnitude: Int64 = 0
        var saturated = false
        while index < scalars.count, scalars[index] >= "0" && scalars[index] <= "9" {
            let digit = Int64(scalars[index].value - 48)
            if saturated {
                index += 1
                continue
            }
            if magnitude > Int64.max / 10 || (magnitude == Int64.max / 10 && digit > Int64.max % 10) {
                saturated = true
            } else {
                magnitude = magnitude * 10 + digit
            }
            index += 1
        }
        if saturated { return negative ? Int64.min : Int64.max }
        return negative ? -magnitude : magnitude
    }

    private static func windowBoolSpelling(_ raw: Any?) -> Bool? {
        if let number = raw as? NSNumber, !(raw is String) {
            // A plist boolean or number. Fractional 0.5 is true on macOS
            // (`NSNumber.boolValue`); `doubleValue != 0` matches that on Linux.
            return number.doubleValue != 0
        }
        guard let text = raw as? String else { return nil }
        switch text.trimmingCharacters(in: .whitespacesAndNewlines).uppercased() {
        case "YES", "TRUE", "1": return true
        case "NO", "FALSE", "0", "": return false
        default: return nil
        }
    }

    private static func windowIntegerParsed(_ raw: Any?) -> Int? {
        if let number = raw as? NSNumber, !(raw is String), let exact = Int(number.stringValue) {
            return exact
        }
        if let text = raw as? String,
           let exact = Int(text.trimmingCharacters(in: .whitespacesAndNewlines)) {
            return exact
        }
        guard let value = windowNumber(raw), value >= Double(Int.min), value < Double(Int.max) else {
            return nil
        }
        return Int(value)
    }

    private static func windowNumber(_ raw: Any?) -> Double? {
        let result: Double?
        if let number = raw as? NSNumber, !(raw is String) {
            result = number.doubleValue
        } else if let text = raw as? String {
            result = Double(text.trimmingCharacters(in: .whitespacesAndNewlines))
        } else {
            result = nil
        }
        return result.flatMap { $0.isFinite ? $0 : nil }
    }
}

extension XRGLegacyMacOSReader.WindowDoubleRule {
    var valid: (Double) -> Bool {
        switch self {
        case .anyFinite: return { _ in true }
        case .positive: return { $0 > 0 }
        case .unitInterval: return { (0...1).contains($0) }
        }
    }
}
