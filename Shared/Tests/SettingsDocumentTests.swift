// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Stephen de la Vega.
import Foundation
import Testing
@testable import XRGSharedCore

/// The shared settings document: load, validate, set, reset and serialise.
///
/// The conformance corpus lives in `Shared/Tests/Fixtures/settings/`. Each
/// `<name>.json` input is loaded with `XRGSettingsDocument.load` and checked
/// against `<name>.expected.json`, which holds the diagnostics and the exact
/// canonical bytes `serialized()` must produce:
///
/// - `diagnostics`: the `[XRGSettingsDiagnostic]` the load reports;
/// - `document`: the canonical document bytes as a JSON string (UTF-8, LF,
///   sorted keys, two-space indent, trailing newline; only values that differ
///   from their catalog default, plus every unknown key at the level it came
///   from — a root member the format does not define is written back at the
///   top level, and preserved numbers keep their original text), or `null`
///   when the input is unreadable.
///
/// The expected files are hand-derived from the spec's format rules, never
/// generated from the implementation, so the pinned bytes are an independent
/// oracle; Task 5 runs the same corpus through the C ABI and must reproduce
/// the same bytes on Linux.
///
/// Migration fixtures (`macos-0.2.2-*`, `linux-v40*`) are added by Task 4 and
/// belong to `SettingsMigrationTests`; they are skipped here.
struct SettingsDocumentTests {
    /// Shared/Tests/SettingsDocumentTests.swift -> Shared/Tests/Fixtures/settings.
    private static let fixturesDirectory: URL = {
        var url = URL(fileURLWithPath: #filePath)
        url.deleteLastPathComponent()
        return url.appendingPathComponent("Fixtures/settings")
    }()

    private static let migrationFixtures = ["macos-0.2.2-", "linux-v40"]

    /// The `<name>.expected.json` shape: diagnostics plus the canonical
    /// document bytes (absent when the document is unreadable).
    private struct ExpectedFile: Decodable {
        var diagnostics: [XRGSettingsDiagnostic]
        var document: String?
    }

    private func loadOK(_ data: Data, _ catalog: XRGSettingsCatalog)
        -> (XRGSettingsDocument, [XRGSettingsDiagnostic])? {
        guard case .ok(let document, let diagnostics) = XRGSettingsDocument.load(data, catalog: catalog) else {
            return nil
        }
        return (document, diagnostics)
    }

    private func loadUnreadable(_ data: Data, _ catalog: XRGSettingsCatalog) -> XRGSettingsDiagnostic? {
        guard case .unreadable(let diagnostic) = XRGSettingsDocument.load(data, catalog: catalog) else {
            return nil
        }
        return diagnostic
    }

    private func corpusInputs() throws -> [(name: String, data: Data)] {
        let urls = try FileManager.default.contentsOfDirectory(at: Self.fixturesDirectory,
                                                               includingPropertiesForKeys: nil)
        return try urls
            .filter { $0.pathExtension == "json" && !$0.lastPathComponent.hasSuffix(".expected.json") }
            .filter { url in !Self.migrationFixtures.contains { url.lastPathComponent.hasPrefix($0) } }
            .sorted { $0.lastPathComponent < $1.lastPathComponent }
            .map { try ($0.deletingPathExtension().lastPathComponent, Data(contentsOf: $0)) }
    }

    private func expectedFile(_ name: String) throws -> ExpectedFile {
        let url = Self.fixturesDirectory.appendingPathComponent("\(name).expected.json")
        return try JSONDecoder().decode(ExpectedFile.self, from: Data(contentsOf: url))
    }

    // MARK: corpus

    @Test func corpusMatchesExpectedOutputs() throws {
        let catalog = try XRGSettingsCatalog.load()
        let inputs = try corpusInputs()
        #expect(!inputs.isEmpty, "the settings corpus is missing")
        for input in inputs {
            let expected = try expectedFile(input.name)
            switch (XRGSettingsDocument.load(input.data, catalog: catalog), expected.document) {
            case (.unreadable(let diagnostic), nil):
                #expect([diagnostic] == expected.diagnostics, "\(input.name)")
            case (.ok(let document, let diagnostics), let documentBytes?):
                #expect(diagnostics == expected.diagnostics, "\(input.name): diagnostics differ")
                #expect(document.serialized() == Data(documentBytes.utf8),
                        "\(input.name): canonical output differs")
            case (.unreadable(let diagnostic), .some):
                Issue.record("\(input.name): expected a readable document, got \(diagnostic)")
            case (.ok(let document, _), nil):
                Issue.record("\(input.name): expected an unreadable document, got \(document)")
            }
        }
    }

    // MARK: load

    @Test func invalidValueFallsBackPerKey() throws {
        let catalog = try XRGSettingsCatalog.load()
        let input = try Data(contentsOf: Self.fixturesDirectory.appendingPathComponent("out-of-range.json"))
        let (document, diagnostics) = try #require(loadOK(input, catalog))
        #expect(diagnostics == [
            XRGSettingsDiagnostic(id: "appearance.window.transparency", problem: "invalid-value"),
            XRGSettingsDiagnostic(id: "general.window.border_width", problem: "invalid-value"),
            XRGSettingsDiagnostic(id: "graphs.refresh", problem: "invalid-value"),
        ])
        // Each invalid value falls back to its catalog default; the rest load.
        #expect(document.value("general.window.border_width", catalog: catalog) == .int(4))
        #expect(document.value("graphs.refresh", catalog: catalog) == .int(1))
        #expect(document.value("appearance.window.transparency", catalog: catalog) == .double(0.9))
        #expect(document.value("graphs.cpu.samples", catalog: catalog) == .int(500))
        // The fallback is the entry default, not a stored value: nothing is written for it.
        #expect(document.values["graphs.refresh"] == nil)
    }

    @Test func unknownKeysSurviveRoundTrip() throws {
        let catalog = try XRGSettingsCatalog.load()
        let input = try Data(contentsOf: Self.fixturesDirectory.appendingPathComponent("unknown-keys.json"))
        let (document, diagnostics) = try #require(loadOK(input, catalog))
        #expect(diagnostics.isEmpty, "preserved keys are not problems")
        // Keys the catalog does not know survive verbatim at the level they
        // sat in the input: inside `settings`, or at the top level.
        #expect(document.values == ["general.window.border_width": .int(2)])
        #expect(document.unknown == [
            "another.scalar": .number("-7"),
            "experiments.alpha.flag": .bool(true),
            "future.widget.config": .object([
                "labels": .array([.string("a"), .string("b")]),
                "nested": .object(["deep": .null]),
                "size": .number("2"),
            ]),
            "some.scalar": .number("3.25"),
        ])
        #expect(document.rootUnknown == ["toplevel.extra": .string("kept")])
        let (reloaded, rediagnostics) = try #require(loadOK(document.serialized(), catalog))
        #expect(rediagnostics.isEmpty)
        #expect(reloaded.unknown == document.unknown)
        #expect(reloaded.rootUnknown == document.rootUnknown)
        #expect(reloaded.values == document.values)
        #expect(reloaded.serialized() == document.serialized())
    }

    @Test func malformedIsUnreadable() throws {
        let catalog = try XRGSettingsCatalog.load()
        let cases: [(String, Data)] = [
            ("empty data", Data()),
            ("truncated object", Data(#"{"format": "xrg-ng-settings", "version": 1"#.utf8)),
            ("top-level array", Data("[1, 2, 3]".utf8)),
            ("top-level scalar", Data("42".utf8)),
            ("top-level null", Data("null".utf8)),
            ("empty object (no format)", Data("{}".utf8)),
            ("format is not a string", Data(#"{"format": 1, "version": 1, "settings": {}}"#.utf8)),
            ("format missing", Data(#"{"version": 1, "settings": {}}"#.utf8)),
            ("version missing", Data(#"{"format": "xrg-ng-settings", "settings": {}}"#.utf8)),
            ("version is a string", Data(#"{"format": "xrg-ng-settings", "version": "1", "settings": {}}"#.utf8)),
            ("version is fractional", Data(#"{"format": "xrg-ng-settings", "version": 1.5, "settings": {}}"#.utf8)),
            ("settings missing", Data(#"{"format": "xrg-ng-settings", "version": 1}"#.utf8)),
            ("settings is an array", Data(#"{"format": "xrg-ng-settings", "version": 1, "settings": []}"#.utf8)),
            ("settings is a string", Data(#"{"format": "xrg-ng-settings", "version": 1, "settings": "x"}"#.utf8)),
            ("trailing garbage", Data(#"{"format": "xrg-ng-settings", "version": 1, "settings": {}} oops"#.utf8)),
            ("not utf-8", Data([0xff, 0xfe, 0x00, 0x7b])),
            ("trailing comma", Data(#"{"format": "xrg-ng-settings", "version": 1, "settings": {},}"#.utf8)),
            // The parser enforces the JSON number grammar.
            ("leading zero number", Data(#"{"format": "xrg-ng-settings", "version": 1, "settings": {"n": 01}}"#.utf8)),
            ("number missing fraction digits", Data(#"{"format": "xrg-ng-settings", "version": 1, "settings": {"n": 1.}}"#.utf8)),
            ("number missing exponent digits", Data(#"{"format": "xrg-ng-settings", "version": 1, "settings": {"n": 1e}}"#.utf8)),
            ("bad string escape", Data(#"{"format": "xrg-ng-settings", "version": 1, "settings": {"n": "\q"}}"#.utf8)),
            ("raw control character in string", Data("{\"\u{01}\": 1}".utf8)),
            // A `\u` surrogate escape must be a complete pair: a lone half,
            // or a second escape that is not the low surrogate, is not a
            // Unicode scalar (RFC 8259 §7).
            ("lone high surrogate escape",
             Data(#"{"format": "xrg-ng-settings", "version": 1, "settings": {"n": "\uD83D"}}"#.utf8)),
            ("lone low surrogate escape",
             Data(#"{"format": "xrg-ng-settings", "version": 1, "settings": {"n": "\uDE00"}}"#.utf8)),
            ("high surrogate escape paired with non-low A",
             Data(#"{"format": "xrg-ng-settings", "version": 1, "settings": {"n": "\uD83D\u0041"}}"#.utf8)),
            ("high surrogate escape followed by raw A",
             Data(#"{"format": "xrg-ng-settings", "version": 1, "settings": {"n": "\uD83DA"}}"#.utf8)),
            ("nesting deeper than the parser allows",
             Data((String(repeating: "[", count: 512) + String(repeating: "]", count: 512)).utf8)),
        ]
        for (name, data) in cases {
            let diagnostic = try #require(loadUnreadable(data, catalog), "\(name): expected unreadable")
            #expect(diagnostic == XRGSettingsDiagnostic(id: nil, problem: "malformed"), "\(name)")
        }
    }

    @Test func futureVersionIsUnreadable() throws {
        let catalog = try XRGSettingsCatalog.load()
        let cases: [(Int, String)] = [
            (2, "unsupported-version"),
            (3, "unsupported-version"),
            (99, "unsupported-version"),
            (0, "malformed"),
            (-1, "malformed"),
        ]
        for (version, problem) in cases {
            let data = Data(#"{"format": "xrg-ng-settings", "version": \#(version), "settings": {"anything": {"new": [1]}}}"#.utf8)
            let diagnostic = try #require(loadUnreadable(data, catalog), "version \(version): expected unreadable")
            #expect(diagnostic == XRGSettingsDiagnostic(id: nil, problem: problem), "version \(version)")
        }
    }

    @Test func unknownFormatIsUnreadable() throws {
        let catalog = try XRGSettingsCatalog.load()
        let cases: [(String, String)] = [
            ("xrg-settings", "unknown-format"),
            ("completely different", "unknown-format"),
            // A file of another format is judged by its format before its version.
            ("xrg-ng-settings-v2", "unknown-format"),
        ]
        for (format, problem) in cases {
            let data = Data(#"{"format": "\#(format)", "version": 2, "settings": {}}"#.utf8)
            let diagnostic = try #require(loadUnreadable(data, catalog), "\(format): expected unreadable")
            #expect(diagnostic == XRGSettingsDiagnostic(id: nil, problem: problem), "\(format)")
        }
    }

    // MARK: set

    @Test func setRejectsOutOfRangeWithBounds() throws {
        let catalog = try XRGSettingsCatalog.load()
        var document = XRGSettingsDocument.defaults(catalog: catalog, platform: .macos)
        #expect(throws: XRGSettingsError.outOfRange(min: 1, max: 16)) {
            try document.set("general.window.border_width", .int(99), catalog: catalog)
        }
        #expect(throws: XRGSettingsError.outOfRange(min: 1, max: 16)) {
            try document.set("general.window.border_width", .int(0), catalog: catalog)
        }
        #expect(throws: XRGSettingsError.outOfRange(min: 0.2, max: 10)) {
            try document.set("graphs.refresh", .double(0.1), catalog: catalog)
        }
        #expect(throws: XRGSettingsError.outOfRange(min: 0.1, max: 1)) {
            try document.set("general.window.opacity", .double(1.5), catalog: catalog)
        }
        // A rejected set stores nothing.
        #expect(document.value("general.window.border_width", catalog: catalog) == .int(4))
        // The bounds themselves are settable.
        try document.set("general.window.border_width", .int(1), catalog: catalog)
        try document.set("graphs.refresh", .double(10), catalog: catalog)
        try document.set("general.window.opacity", .double(0.1), catalog: catalog)
        #expect(document.value("general.window.border_width", catalog: catalog) == .int(1))
        #expect(document.value("graphs.refresh", catalog: catalog) == .double(10))
    }

    @Test func setRejectsWrongType() throws {
        let catalog = try XRGSettingsCatalog.load()
        var document = XRGSettingsDocument.defaults(catalog: catalog, platform: .macos)
        let cases: [(String, XRGSettingsValue, XRGSettingsError)] = [
            ("general.window.expand_on_hover", .string("yes"), .wrongType),
            ("general.window.border_width", .double(4.5), .wrongType),
            // An integer control takes integers only, even whole doubles.
            ("general.window.border_width", .double(4), .wrongType),
            ("general.window.title", .int(5), .wrongType),
            ("appearance.series1.color", .string("#ffffff"), .wrongType),
            ("appearance.series1.color", .color([0.1, 0.2, 0.3, 2]), .wrongType),
            ("sources.cpu.core", .double(1.5), .wrongType),
            ("graphs.order", .int(3), .wrongType),
            // A choice value outside its options.
            ("general.window.orientation", .string("diagonal"), .notAnOption),
            // An order list with unknown, missing or repeated ids.
            ("graphs.order", .string("cpu,unknown"), .notAnOption),
            ("graphs.order", .string("cpu"), .notAnOption),
            ("graphs.order", .string("cpu,cpu,gpu,npu,vram,memory,battery,temperature,fans,network,disk,weather,stock,ai,processes"), .notAnOption),
            // An action is a button; it holds no document value.
            ("general.reset", .bool(true), .wrongType),
            // An id the catalog does not have.
            ("nope.nope", .bool(true), .unknownId),
        ]
        for (id, value, error) in cases {
            #expect(throws: error) { try document.set(id, value, catalog: catalog) }
        }
        // None of the rejected values were stored.
        #expect(document.values.isEmpty)
        // The same rules accept the right shapes: a source takes a string or
        // an int, an order takes the default ids in any order, and null means
        // "not set" for every non-action control.
        try document.set("sources.cpu.core", .int(2), catalog: catalog)
        try document.set("graphs.order",
                         .string("memory,cpu,gpu,npu,vram,battery,temperature,fans,network,disk,weather,stock,ai,processes"),
                         catalog: catalog)
        try document.set("general.window.orientation", .null, catalog: catalog)
        #expect(document.value("sources.cpu.core", catalog: catalog) == .int(2))
        #expect(document.value("general.window.orientation", catalog: catalog) == .null)
    }

    /// Ruling R41, completed in round 5: `depends` never refuses a write.
    /// A dependent stored while its dependency is off is a DORMANT value —
    /// allowed, and rendered with its control disabled in the windows —
    /// and turning the dependency back on makes the stored value
    /// meaningful again without any further edit.
    @Test func dependentsStoreAsDormantValues() throws {
        let catalog = try XRGSettingsCatalog.load()
        var document = XRGSettingsDocument.defaults(catalog: catalog, platform: .macos)
        // Bring-to-front depends on expand-on-hover being on (its default).
        try document.set("general.window.expand_on_hover", .bool(false), catalog: catalog)
        try document.set("general.window.bring_to_front_on_expand", .bool(true), catalog: catalog)
        #expect(document.values["general.window.bring_to_front_on_expand"] == .bool(true),
                "the dormant dependent must be stored, never refused")
        try document.set("general.window.expand_on_hover", .bool(true), catalog: catalog)
        #expect(document.value("general.window.bring_to_front_on_expand", catalog: catalog) == .bool(true))
        // Samples depends on the CPU time window following the sample count (0).
        try document.set("graphs.cpu.time_window", .int(5), catalog: catalog)
        try document.set("graphs.cpu.samples", .int(500), catalog: catalog)
        #expect(document.value("graphs.cpu.samples", catalog: catalog) == .int(500),
                "the count under a stored window is dormant, not refused")
        try document.set("graphs.cpu.time_window", .int(0), catalog: catalog)
        #expect(document.value("graphs.cpu.samples", catalog: catalog) == .int(500))
    }

    // MARK: named semantic constraints (final review, finding 1 / R29, R30)

    /// The values the workers would reject are refused before they are ever
    /// saved — the exact review case is the one-character ICAO station that
    /// crashed the Linux launch, and its siblings.
    @Test func setRefusesValuesTheWorkersWouldReject() throws {
        let catalog = try XRGSettingsCatalog.load()
        var document = XRGSettingsDocument.defaults(catalog: catalog, platform: .linux)
        let cases: [(String, XRGSettingsValue)] = [
            // The review's crash: a station no worker accepts.
            ("weather.station", .string("K")),
            ("weather.station", .string("KSEAA")),
            // AI paths must be absolute, bounded and printable.
            ("ai.claude.logs_path", .string("relative/path")),
            ("ai.hermes.database_path", .string("")),
            // AI endpoints must be loopback HTTP, without credentials/query.
            ("ai.metrics.url", .string("http://localhost:8889/metrics")),
            ("ai.ollama.url", .string("http://10.0.0.1:11434")),
            ("ai.metrics.url", .string("http://127.0.0.1:8889/metrics?x=1")),
            ("ai.ollama.url", .string("http://user@127.0.0.1:11434")),
            // The process filter is bounded printable text.
            ("graphs.processes.filter", .string(String(repeating: "a", count: 129))),
            // Whole-minute durations refuse fractions (ruling R30).
            ("graphs.cpu.time_window", .double(1.5)),
            ("weather.refresh", .double(5.5)),
        ]
        for (id, value) in cases {
            #expect(throws: XRGSettingsError.constraint) {
                try document.set(id, value, catalog: catalog)
            }
            #expect(document.values[id] == nil, "\(id) must not be stored")
        }
        // A theme name is bounded printable text, trimmed.
        #expect(throws: XRGSettingsError.constraint) {
            try document.set("themes.name", .string(" padded "), catalog: catalog)
        }
    }

    /// The cross-setting combinations the workers enforce, refused before
    /// save from either side of the combination (final review round 2,
    /// issue 2 / ruling R33).
    @Test func setRefusesCombinationsTheWorkersReject() throws {
        let catalog = try XRGSettingsCatalog.load()
        var document = XRGSettingsDocument.defaults(catalog: catalog, platform: .linux)
        // Weather: an enabled collector needs a station the worker can
        // address. Setting the empty station first (entry-valid on its own),
        // then enabling, is the exact combination settings.rs rejects.
        try document.set("weather.station", .string(""), catalog: catalog)
        #expect(throws: XRGSettingsError.constraint) {
            try document.set("weather.enabled", .bool(true), catalog: catalog)
        }
        #expect(document.values["weather.enabled"] == nil, "the refused edit must not be stored")
        // The same refusal from the other side: enabling first (the default
        // station is addressable), then clearing the station it needs.
        try document.set("weather.station", .string("KSEA"), catalog: catalog)
        try document.set("weather.enabled", .bool(true), catalog: catalog)
        #expect(throws: XRGSettingsError.constraint) {
            try document.set("weather.station", .string(""), catalog: catalog)
        }
        #expect(document.value("weather.station", catalog: catalog) == .string("KSEA"))
        // Sensor curves: a secondary requires a primary, and each curve uses
        // a different sensor.
        #expect(throws: XRGSettingsError.constraint) {
            try document.set("sources.temperature.sensor2", .string("coretemp-isa-0000"), catalog: catalog)
        }
        try document.set("sources.temperature.sensor1", .string("coretemp-isa-0000"), catalog: catalog)
        try document.set("sources.temperature.sensor2", .string("acpitz-1"), catalog: catalog)
        #expect(throws: XRGSettingsError.constraint) {
            try document.set("sources.temperature.sensor3", .string("acpitz-1"), catalog: catalog)
        }
        // Clearing the primary while a secondary is drawn is refused too;
        // clearing the secondary first fixes the document.
        #expect(throws: XRGSettingsError.constraint) {
            try document.set("sources.temperature.sensor1", .null, catalog: catalog)
        }
        try document.set("sources.temperature.sensor2", .null, catalog: catalog)
        try document.set("sources.temperature.sensor1", .null, catalog: catalog)
        #expect(document.value("sources.temperature.sensor1", catalog: catalog) == .null)
        // A document that satisfies the combinations still saves.
        try document.set("weather.station", .string(" ksea "), catalog: catalog)
        try document.set("sources.fans.sensor1", .string("applesmc-fan1"), catalog: catalog)
        try document.set("sources.fans.sensor2", .string("applesmc-fan2"), catalog: catalog)
        #expect(document.value("sources.fans.sensor2", catalog: catalog) == .string("applesmc-fan2"))
    }

    /// The same rules accept the values the workers accept, so a valid edit
    /// still saves — including the fractional sampling interval, where both
    /// platforms genuinely use fractions (ruling R30).
    @Test func setAcceptsValuesThatSatisfyTheConstraints() throws {
        let catalog = try XRGSettingsCatalog.load()
        var document = XRGSettingsDocument.defaults(catalog: catalog, platform: .linux)
        try document.set("weather.station", .string(" ksea "), catalog: catalog)
        try document.set("ai.claude.logs_path", .string("/home/user/.claude/projects"), catalog: catalog)
        try document.set("ai.metrics.url", .string("http://127.0.0.1:8889/metrics"), catalog: catalog)
        try document.set("ai.ollama.url", .string("http://[::1]:11434"), catalog: catalog)
        try document.set("graphs.processes.filter", .string("chrome"), catalog: catalog)
        try document.set("graphs.cpu.time_window", .int(5), catalog: catalog)
        try document.set("weather.refresh", .int(20), catalog: catalog)
        try document.set("graphs.refresh", .double(0.25), catalog: catalog)
        #expect(document.value("weather.station", catalog: catalog) == .string(" ksea "))
        #expect(document.value("graphs.refresh", catalog: catalog) == .double(0.25))
    }

    // MARK: batch writes (round 3 redesign, rulings R37/R38)

    /// One batch applies every set and every removal together and validates
    /// the FINAL document once (ruling R37): the two transitions a
    /// dependency-ordered application used to reject — disabling the weather
    /// collector together with clearing its station, and swapping the sensor
    /// curves so the duplicate secondary disappears — are one valid batch.
    @Test func batchApplyValidatesTheFinalDocumentOnce() throws {
        let catalog = try XRGSettingsCatalog.load()
        // Weather enabled with a station: a valid starting document.
        var weather = XRGSettingsDocument.defaults(catalog: catalog, platform: .linux)
        try weather.set("weather.station", .string("KSEA"), catalog: catalog)
        try weather.set("weather.enabled", .bool(true), catalog: catalog)
        // Disabling the collector and clearing its station in ONE batch: the
        // final document is valid, so the batch applies whole.
        guard case .applied(let disabled) = XRGSettingsDocument.apply([
            XRGSettingsChange(id: "weather.enabled", value: .bool(false)),
            XRGSettingsChange(id: "weather.station", value: nil),
        ], to: weather, catalog: catalog) else {
            Issue.record("the whole-view transition must apply as one batch")
            return
        }
        #expect(disabled.values["weather.enabled"] == nil)
        #expect(disabled.values["weather.station"] == nil)

        // Sensors [A, B, nil] → [B, nil, nil]: the primary moves into the
        // duplicate's place and the duplicate clears, in ONE batch.
        var sensors = XRGSettingsDocument.defaults(catalog: catalog, platform: .linux)
        try sensors.set("sources.fans.sensor1", .string("applesmc-fan1"), catalog: catalog)
        try sensors.set("sources.fans.sensor2", .string("applesmc-fan2"), catalog: catalog)
        // A single edit through that transition is refused: the primary
        // would duplicate the secondary (the old dependency-ordering trap).
        #expect(throws: XRGSettingsError.constraint) {
            try sensors.set("sources.fans.sensor1", .string("applesmc-fan2"), catalog: catalog)
        }
        guard case .applied(let swapped) = XRGSettingsDocument.apply([
            XRGSettingsChange(id: "sources.fans.sensor1", value: .string("applesmc-fan2")),
            XRGSettingsChange(id: "sources.fans.sensor2", value: nil),
        ], to: sensors, catalog: catalog) else {
            Issue.record("the sensor swap must apply as one batch")
            return
        }
        #expect(swapped.values["sources.fans.sensor1"] == .string("applesmc-fan2"))
        #expect(swapped.values["sources.fans.sensor2"] == nil)
        #expect(XRGSettingsDocument.combinationViolations(swapped.values, catalog: catalog).isEmpty)

        // A batch whose final document is refused: enabling the collector
        // with no addressable station, from a clean document, reports the
        // offending entry and applies nothing.
        guard case .refused(let refusals) = XRGSettingsDocument.apply([
            XRGSettingsChange(id: "weather.station", value: .string("")),
            XRGSettingsChange(id: "weather.enabled", value: .bool(true)),
        ], to: XRGSettingsDocument.defaults(catalog: catalog, platform: .linux), catalog: catalog) else {
            Issue.record("the combination-breaking batch must be refused")
            return
        }
        #expect(refusals.count == 1, "one cross-setting offender: \(refusals)")
        #expect(refusals.first?.id == "weather.enabled")
        #expect(refusals.first?.error == .constraint)
        // A per-entry refusal in a batch: the out-of-range value is
        // reported with its own entry and bounds, and nothing is applied.
        guard case .refused(let entryRefusals) = XRGSettingsDocument.apply([
            XRGSettingsChange(id: "general.window.title", value: .string("Kept")),
            XRGSettingsChange(id: "general.window.border_width", value: .int(99)),
        ], to: XRGSettingsDocument.defaults(catalog: catalog, platform: .linux), catalog: catalog) else {
            Issue.record("the per-entry refusal must be refused")
            return
        }
        #expect(entryRefusals.count == 1, "one per-entry refusal: \(entryRefusals)")
        #expect(entryRefusals.first?.id == "general.window.border_width")
        #expect(entryRefusals.first?.error == .outOfRange(min: 1, max: 16))
    }

    /// Ruling R41, completed in round 5 — a batch is never refused because a
    /// dependent's dependency is off, in the starting or the final document.
    /// Every direction of the sample-count/time-window transition:
    ///
    /// - a single-entry set (a batch of one) of the count while the window
    ///   is on stores a DORMANT value — allowed, its control renders
    ///   disabled in the windows;
    /// - enable-and-set: a batch that removes the CPU window override and
    ///   stores the sample count together is ACCEPTED — the final document
    ///   enables it (this is the review's exact counterexample: a starting
    ///   `time_window` of 5 refused it before);
    /// - dormant: a batch that stores the sample count while switching the
    ///   window ON keeps a DORMANT value the windows render disabled, and
    ///   is never refused for that;
    /// - dormant-to-dormant: a batch that moves the window 5→10 while the
    ///   count moves 100→200 is accepted — the final document merely
    ///   retains a dormant count, whatever the starting document held.
    @Test func batchDependenciesFollowTheFinalDocumentBothWays() throws {
        let catalog = try XRGSettingsCatalog.load()
        // Samples depends on the window following the count (time_window == 0).
        let samples = try #require(catalog.entry("graphs.cpu.samples"))
        let depends = try #require(samples.depends)
        #expect(depends.id == "graphs.cpu.time_window")
        #expect(depends.equals == .int(0))

        // Start with the window override on: the sample mode is disabled.
        var windowed = XRGSettingsDocument.defaults(catalog: catalog, platform: .linux)
        try windowed.set("graphs.cpu.time_window", .int(5), catalog: catalog)
        // A single-entry set of the count is accepted as a DORMANT value
        // (ruling R41 completed): its control renders disabled in the
        // windows, and the stored value waits beneath the window.
        try windowed.set("graphs.cpu.samples", .int(100), catalog: catalog)
        #expect(windowed.values["graphs.cpu.samples"] == .int(100),
                "a dormant dependent must be stored, never refused")
        // Direction 1 — enable-and-set: remove the window override and store
        // the count in ONE batch: accepted, the final document enables it.
        guard case .applied(let enabled) = XRGSettingsDocument.apply([
            XRGSettingsChange(id: "graphs.cpu.time_window", value: nil),
            XRGSettingsChange(id: "graphs.cpu.samples", value: .int(200)),
        ], to: windowed, catalog: catalog) else {
            Issue.record("the enable-and-set batch must be accepted")
            return
        }
        #expect(enabled.values["graphs.cpu.time_window"] == nil)
        #expect(enabled.values["graphs.cpu.samples"] == .int(200))
        #expect(windowed.values["graphs.cpu.samples"] == .int(100),
                "the batch that was applied to a copy changed nothing in place")

        // Direction 2 — dormant: with the count stored and the window off,
        // one batch that turns the window ON keeps the count as a dormant
        // value (its control renders disabled): accepted, never refused.
        var counted = XRGSettingsDocument.defaults(catalog: catalog, platform: .linux)
        try counted.set("graphs.cpu.samples", .int(100), catalog: catalog)
        guard case .applied(let dormant) = XRGSettingsDocument.apply([
            XRGSettingsChange(id: "graphs.cpu.time_window", value: .int(5)),
        ], to: counted, catalog: catalog) else {
            Issue.record("a batch that leaves a dormant dependent must be accepted")
            return
        }
        #expect(dormant.values["graphs.cpu.samples"] == .int(100),
                "the dormant value is retained")
        #expect(dormant.values["graphs.cpu.time_window"] == .int(5))
        // Direction 3 — dormant-to-dormant (round 5): ONE batch moves the
        // window 5→10 while the count moves 100→200; the dependency is off
        // in BOTH the starting and the final document, and the final
        // document merely retains a dormant count — accepted, the exact
        // refusal round 4's starting-state check produced.
        guard case .applied(let moved) = XRGSettingsDocument.apply([
            XRGSettingsChange(id: "graphs.cpu.time_window", value: .int(10)),
            XRGSettingsChange(id: "graphs.cpu.samples", value: .int(200)),
        ], to: dormant, catalog: catalog) else {
            Issue.record("the dormant-to-dormant batch must be accepted")
            return
        }
        #expect(moved.values["graphs.cpu.time_window"] == .int(10))
        #expect(moved.values["graphs.cpu.samples"] == .int(200))
        // The dormant document still edits, and its count still loads.
        let reloaded = try #require(loadOK(dormant.serialized(), catalog)).0
        #expect(reloaded.values["graphs.cpu.samples"] == .int(100))
        #expect(reloaded.values["graphs.cpu.time_window"] == .int(5))
    }

    /// The "don't make it worse" rule (ruling R38): a document that already
    /// carries cross-setting violations — an older build's or a hand edit's,
    /// each entry valid on its own — loads, an unrelated edit still applies,
    /// fixing either violation alone applies, and only ever ADDING a
    /// violation is refused.
    @Test func existingViolationsStayEditableAndFixableOneAtATime() throws {
        let catalog = try XRGSettingsCatalog.load()
        let input = Data("""
        {
          "format": "xrg-ng-settings",
          "version": 1,
          "settings": {
            "general.window.title": "Hand edited",
            "weather.enabled": true,
            "weather.station": "",
            "sources.fans.sensor2": "applesmc-fan2"
          }
        }
        """.utf8)
        var loaded = try #require(loadOK(input, catalog)).0
        #expect(loadOK(input, catalog)?.1.isEmpty == true, "each entry is valid on its own")
        // Two independent violations: the enabled collector without a
        // station, and the secondary fan curve without a primary.
        #expect(!XRGSettingsDocument.combinationViolations(loaded.values, catalog: catalog).isEmpty)
        // An unrelated edit succeeds: nothing gets worse (ruling R38).
        try loaded.set("general.window.border_width", .int(8), catalog: catalog)
        // Fixing EITHER violation alone succeeds: the other one is
        // pre-existing, not made worse.
        try loaded.set("weather.station", .string("KSEA"), catalog: catalog)
        try loaded.set("sources.fans.sensor1", .string("applesmc-fan1"), catalog: catalog)
        #expect(loaded.value("general.window.title", catalog: catalog) == .string("Hand edited"))
        #expect(loaded.value("sources.fans.sensor2", catalog: catalog) == .string("applesmc-fan2"))
        #expect(XRGSettingsDocument.combinationViolations(loaded.values, catalog: catalog).isEmpty)
        // From the violated document, ADDING a violation is still refused.
        var stillViolated = try #require(loadOK(input, catalog)).0
        #expect(throws: XRGSettingsError.constraint) {
            try stillViolated.set("sources.fans.sensor3", .string("applesmc-fan2"), catalog: catalog)
        }
    }

    /// The in-memory repair a load applies on Linux (ruling R38): each
    /// combination's own offenders revert to their defaults — nothing else
    /// moves — and the repaired document satisfies every combination.
    @Test func combinationRepairResetsOnlyTheOffenders() throws {
        let catalog = try XRGSettingsCatalog.load()
        let input = Data("""
        {
          "format": "xrg-ng-settings",
          "version": 1,
          "settings": {
            "general.window.title": "Hand edited",
            "weather.enabled": true,
            "weather.station": "",
            "sources.fans.sensor1": "applesmc-fan1",
            "sources.fans.sensor2": "applesmc-fan1",
            "sources.fans.sensor3": "applesmc-fan2",
            "sources.temperature.sensor2": "coretemp-isa-0000"
          }
        }
        """.utf8)
        let loaded = try #require(loadOK(input, catalog)).0
        let (repaired, ids) = loaded.repairingCombinations(catalog: catalog)
        #expect(ids == ["weather.enabled", "sources.temperature.sensor2", "sources.fans.sensor2"])
        #expect(repaired.values["weather.enabled"] == nil, "the collector alone steps back")
        #expect(repaired.values["weather.station"] == .string(""),
                "the empty station is entry-valid 'not set': it stays")
        #expect(repaired.values["sources.fans.sensor1"] == .string("applesmc-fan1"), "the primary survives")
        #expect(repaired.values["sources.fans.sensor2"] == nil, "the later duplicate clears")
        #expect(repaired.values["sources.fans.sensor3"] == .string("applesmc-fan2"),
                "the distinct third curve survives")
        #expect(repaired.values["sources.temperature.sensor2"] == nil, "the secondary without a primary clears")
        #expect(repaired.values["general.window.title"] == .string("Hand edited"))
        #expect(XRGSettingsDocument.combinationViolations(repaired.values, catalog: catalog).isEmpty)
    }

    /// An old document that already holds worker-refusing values loads with
    /// per-key fallbacks and reports them, exactly like any other invalid
    /// value — the file is not unreadable and the rest still loads.
    @Test func loadReplacesValuesThatBreakTheirConstraint() throws {
        let catalog = try XRGSettingsCatalog.load()
        let input = Data("""
        {
          "format": "xrg-ng-settings",
          "version": 1,
          "settings": {
            "general.window.title": "Kept",
            "graphs.cpu.time_window": 1.5,
            "weather.station": "K",
            "ai.ollama.url": "http://10.0.0.1:11434"
          }
        }
        """.utf8)
        let (document, diagnostics) = try #require(loadOK(input, catalog))
        #expect(diagnostics == [
            XRGSettingsDiagnostic(id: "ai.ollama.url", problem: "invalid-value"),
            XRGSettingsDiagnostic(id: "graphs.cpu.time_window", problem: "invalid-value"),
            XRGSettingsDiagnostic(id: "weather.station", problem: "invalid-value"),
        ])
        // Each entry falls back to its catalog default; the rest loads.
        #expect(document.value("general.window.title", catalog: catalog) == .string("Kept"))
        #expect(document.value("graphs.cpu.time_window", catalog: catalog) == .int(0))
        #expect(document.value("weather.station", catalog: catalog) == .string("KMOP"))
        #expect(document.value("ai.ollama.url", catalog: catalog) == .string("http://127.0.0.1:11434"))
    }

    /// The shared loopback-endpoint parity table (round 3, ruling R40): the
    /// accept/reject cases live in one committed table both platforms assert
    /// identically — this suite through `isLoopbackHTTPURL`, the Rust suite
    /// through the workers' own `validate_url`, whose authority parsing is
    /// std's `SocketAddr`/`IpAddr` parser. Every case here is derived from
    /// what Rust's parser does, so a working endpoint is never dropped and a
    /// malformed one is never newly accepted.
    @Test func loopbackURLGrammarMatchesTheSharedParityTable() throws {
        let tableURL = Self.fixturesDirectory.deletingLastPathComponent()
            .appendingPathComponent("url-parity.json")
        struct Case: Decodable { let url: String; let accept: Bool }
        struct Table: Decodable { let cases: [Case] }
        let table = try JSONDecoder().decode(Table.self, from: Data(contentsOf: tableURL))
        #expect(!table.cases.isEmpty, "the shared parity table is missing")
        for parity in table.cases {
            #expect(XRGSettingsDocument.isLoopbackHTTPURL(parity.url) == parity.accept,
                    "\(parity.url) must \(parity.accept ? "be accepted" : "be refused")")
        }
        // The parser rules the table pins, at the boundaries (ruling R40):
        // a leading-zero port parses to its value, and an embedded IPv4 quad
        // is accepted only AFTER a "::", never before it.
        #expect(XRGSettingsDocument.parseIPv6Address("::1.2.3.4") == [0, 0, 0, 0, 0, 0, 0x0102, 0x0304])
        #expect(XRGSettingsDocument.parseIPv6Address("0.0.0.0::1") == nil)
        #expect(XRGSettingsDocument.parseIPv6Address("1:2:3:4:5:6:1.2.3.4") == [1, 2, 3, 4, 5, 6, 0x0102, 0x0304])
        #expect(XRGSettingsDocument.parseIPv6Address("1:2:3:4:5:6:7:1.2.3.4") == nil,
                "seven groups plus an embedded quad is nine: Rust rejects it")
        #expect(XRGSettingsDocument.parseIPv6Address("0:0:0:0:0:0:0:1") == [0, 0, 0, 0, 0, 0, 0, 1])
    }

    /// The named-constraint rules themselves, at the boundaries the workers
    /// decide on: the loopback URL grammar and the device-name rules.
    @Test func constraintBoundariesMatchTheWorkersRules() throws {
        // Loopback URLs: the accepted authorities and the refused shapes —
        // every textual form the workers' own `SocketAddr`/`IpAddr` parsing
        // takes, so migration never drops a working endpoint (R34).
        let accepted = [
            "http://127.0.0.1", "http://127.0.0.1:8889", "http://127.255.0.1:80/metrics",
            "http://[::1]", "http://[::1]:11434", "http://127.0.0.2:80",
            "http://[0:0:0:0:0:0:0:1]:11435", "http://[::0:0:1]:11435",
            "http://127.0.0.1:65535/x/y",
            // Leading-zero ports parse in Rust's socket parser (ruling R40).
            "http://127.0.0.1:080/metrics",
        ]
        let refused = [
            "", "https://127.0.0.1", "http://localhost:8889", "http://127.0.0.1:0",
            "http://127.0.0.1:99999", "http://10.0.0.1:80", "http://128.0.0.1:80",
            "http://::1", "http://127.0.0.1:80?q", "http://127.0.0.1:80#f",
            "http://u@127.0.0.1:80", "http://[127.0.0.1]:80", "http://127.0.0.01:80",
            // Non-canonical bare authorities the workers' own canonical-form
            // check refuses: expanded IPv6 without a port, unbracketed IPv6.
            "http://[0:0:0:0:0:0:0:1]", "http://0:0:0:0:0:0:0:1]:11435",
            "http://0:0:0:0:0:0:0:1", "http://[::1]:0",
            // An embedded IPv4 quad before the "::" is not an IPv6 address
            // in Rust's parser (ruling R40) — never a loopback endpoint.
            "http://[0.0.0.0::1]:80",
        ]
        for url in accepted {
            #expect(XRGSettingsDocument.isLoopbackHTTPURL(url), "\(url) must be accepted")
        }
        for url in refused {
            #expect(!XRGSettingsDocument.isLoopbackHTTPURL(url), "\(url) must be refused")
        }
        // Device names: the network/disk rule.
        #expect(XRGSettingsDocument.isDeviceName("en0"))
        #expect(!XRGSettingsDocument.isDeviceName(""))
        #expect(!XRGSettingsDocument.isDeviceName("."))
        #expect(!XRGSettingsDocument.isDeviceName(".."))
        #expect(!XRGSettingsDocument.isDeviceName("disk0s2:1"))
        #expect(!XRGSettingsDocument.isDeviceName("has space"))
        #expect(!XRGSettingsDocument.isDeviceName(String(repeating: "a", count: 256)))
        // Absolute paths: rooted, bounded, printable.
        #expect(XRGSettingsDocument.isAbsolutePath("/"))
        #expect(XRGSettingsDocument.isAbsolutePath("/home/u/.claude/projects"))
        #expect(!XRGSettingsDocument.isAbsolutePath("home/u"))
        #expect(!XRGSettingsDocument.isAbsolutePath("/a\u{1}b"))
    }

    // MARK: reset

    @Test func resetSectionOnlyTouchesThatSection() throws {
        let catalog = try XRGSettingsCatalog.load()
        let input = try Data(contentsOf: Self.fixturesDirectory.appendingPathComponent("unknown-keys.json"))
        var document = try #require(loadOK(input, catalog)).0
        try document.set("general.window.border_width", .int(8), catalog: catalog)
        try document.set("appearance.font", .string("Menlo 12"), catalog: catalog)
        try document.set("graphs.refresh", .int(5), catalog: catalog)
        // Linux-only, but a member of the general section.
        try document.set("general.window.opacity", .double(0.5), catalog: catalog)

        // A reset is one batch of removals for the WHOLE section — every
        // entry, whichever platform it belongs to (round 3, ruling R37).
        document = try applyReset("general", document, catalog)
        #expect(document.value("general.window.border_width", catalog: catalog) == .int(4))
        #expect(document.value("general.window.opacity", catalog: catalog) == .int(1))
        #expect(document.value("appearance.font", catalog: catalog) == .string("Menlo 12"))
        #expect(document.value("graphs.refresh", catalog: catalog) == .int(5))
        // Unknown keys, at either level, are never touched by a reset.
        #expect(document.rootUnknown["toplevel.extra"] == .string("kept"))
        #expect(document.unknown["future.widget.config"] != nil)

        // Other sections are untouched: resetting sources changes nothing.
        #expect(try applyReset("sources", document, catalog).serialized() == document.serialized())
    }

    /// `resettingSection` applied, or the original document with the
    /// refusal recorded.
    private func applyReset(_ section: String, _ document: XRGSettingsDocument,
                             _ catalog: XRGSettingsCatalog) throws -> XRGSettingsDocument {
        switch XRGSettingsDocument.resettingSection(section, in: document, catalog: catalog) {
        case .applied(let reset): return reset
        case .refused(let refusals):
            Issue.record("the reset was refused: \(refusals)")
            return document
        }
    }

    // MARK: serialise

    @Test func serializationIsStable() throws {
        let catalog = try XRGSettingsCatalog.load()
        for input in try corpusInputs() {
            guard let (document, _) = loadOK(input.data, catalog) else { continue }
            let once = document.serialized()
            guard let (reloaded, _) = loadOK(once, catalog) else {
                Issue.record("\(input.name): the canonical output must reload")
                continue
            }
            #expect(reloaded == document, "\(input.name): load∘serialize must be idempotent")
            #expect(reloaded.serialized() == once, "\(input.name): bytes must be stable")
        }
        // An empty settings object loads and re-emits the defaults document.
        let empty = Data(#"{"format": "xrg-ng-settings", "version": 1, "settings": {}}"#.utf8)
        let (document, diagnostics) = try #require(loadOK(empty, catalog))
        #expect(diagnostics.isEmpty)
        #expect(document.serialized() == XRGSettingsDocument.defaults(catalog: catalog, platform: .linux).serialized())
    }

    // MARK: unknown root members and numbers

    /// A root member and a settings member of the same name are two
    /// different values: both survive, each written at its own level.
    @Test func rootCollisionWithSettingsIsPreservedAtBothLevels() throws {
        let catalog = try XRGSettingsCatalog.load()
        let input = Data(#"{"format": "xrg-ng-settings", "version": 1, "settings": {"extra": 2}, "extra": 1}"#.utf8)
        let (document, diagnostics) = try #require(loadOK(input, catalog))
        #expect(diagnostics.isEmpty)
        #expect(document.values.isEmpty)
        #expect(document.unknown == ["extra": .number("2")])
        #expect(document.rootUnknown == ["extra": .number("1")])
        // The whole top level sorts canonically, so "extra" comes before
        // "format". Hand-derived expected bytes, exactly as for the corpus.
        let expected = "{\n  \"extra\": 1,\n  \"format\": \"xrg-ng-settings\",\n  \"settings\": {\n    \"extra\": 2\n  },\n  \"version\": 1\n}\n"
        #expect(document.serialized() == Data(expected.utf8))
        // The collision survives the round trip, each value still at its level.
        let (reloaded, _) = try #require(loadOK(document.serialized(), catalog))
        #expect(reloaded.unknown == document.unknown)
        #expect(reloaded.rootUnknown == document.rootUnknown)
        #expect(reloaded.serialized() == document.serialized())
    }

    /// A root member named like a catalog id is root data, not a setting: it
    /// stays at the root and never changes that setting's value.
    @Test func rootMemberNamedLikeACatalogIdIsRootData() throws {
        let catalog = try XRGSettingsCatalog.load()
        // Without a stored value, the setting stays at its default.
        let onlyRoot = Data(#"{"format": "xrg-ng-settings", "version": 1, "settings": {}, "general.window.border_width": 8}"#.utf8)
        let (bare, diagnostics) = try #require(loadOK(onlyRoot, catalog))
        #expect(diagnostics.isEmpty)
        #expect(bare.values.isEmpty)
        #expect(bare.unknown.isEmpty)
        #expect(bare.rootUnknown == ["general.window.border_width": .number("8")])
        #expect(bare.value("general.window.border_width", catalog: catalog) == .int(4))
        let bareBytes = "{\n  \"format\": \"xrg-ng-settings\",\n  \"general.window.border_width\": 8,\n  \"settings\": {},\n  \"version\": 1\n}\n"
        #expect(bare.serialized() == Data(bareBytes.utf8))

        // With both present, the root member still does not touch the setting.
        let both = Data(#"{"format": "xrg-ng-settings", "version": 1, "settings": {"general.window.border_width": 2}, "general.window.border_width": 8}"#.utf8)
        let (document, _) = try #require(loadOK(both, catalog))
        #expect(document.values == ["general.window.border_width": .int(2)])
        #expect(document.rootUnknown == ["general.window.border_width": .number("8")])
        #expect(document.value("general.window.border_width", catalog: catalog) == .int(2))
        let bothBytes = "{\n  \"format\": \"xrg-ng-settings\",\n  \"general.window.border_width\": 8,\n  \"settings\": {\n    \"general.window.border_width\": 2\n  },\n  \"version\": 1\n}\n"
        #expect(document.serialized() == Data(bothBytes.utf8))
        let (reloaded, _) = try #require(loadOK(document.serialized(), catalog))
        #expect(reloaded.serialized() == document.serialized())
    }

    /// Preserved numbers round-trip byte for byte, whatever their precision:
    /// an integer beyond Double's exact range and a decimal longer than its
    /// shortest form survive unchanged — plain, inside arrays and inside
    /// objects, in `settings` and at the top level. The corpus runs the same
    /// check through `precision.json`; this pins it with a second,
    /// independently derived expectation.
    @Test func unknownNumbersSurviveByteExactly() throws {
        let catalog = try XRGSettingsCatalog.load()
        let input = Data(#"{"format": "xrg-ng-settings", "version": 1, "settings": {"big": 9007199254740993, "deep": {"decimal": 0.1000000000000000055511151231257827}, "list": [9007199254740993, 0.1000000000000000055511151231257827]}}"#.utf8)
        let (document, diagnostics) = try #require(loadOK(input, catalog))
        #expect(diagnostics.isEmpty)
        // The stored value is the original number text, not a rounded Double.
        #expect(document.unknown["big"] == .number("9007199254740993"))
        #expect(document.unknown["list"] == .array([
            .number("9007199254740993"),
            .number("0.1000000000000000055511151231257827"),
        ]))
        let expected = "{\n  \"format\": \"xrg-ng-settings\",\n  \"settings\": {\n    \"big\": 9007199254740993,\n    \"deep\": {\n      \"decimal\": 0.1000000000000000055511151231257827\n    },\n    \"list\": [\n      9007199254740993,\n      0.1000000000000000055511151231257827\n    ]\n  },\n  \"version\": 1\n}\n"
        #expect(document.serialized() == Data(expected.utf8))
        // load∘serialize is byte-stable: the second load sees the same numbers.
        let (reloaded, _) = try #require(loadOK(document.serialized(), catalog))
        #expect(reloaded.unknown == document.unknown)
        #expect(reloaded.serialized() == document.serialized())
    }

    @Test func defaultsAreNotWritten() throws {
        let catalog = try XRGSettingsCatalog.load()
        let document = XRGSettingsDocument.defaults(catalog: catalog, platform: .macos)
        #expect(document.values.isEmpty)
        #expect(document.unknown.isEmpty)
        #expect(document.rootUnknown.isEmpty)
        #expect(document.value("general.window.border_width", catalog: catalog) == .int(4))
        #expect(document.value("graphs.refresh", catalog: catalog) == .int(1))
        #expect(document.value("nope.nope", catalog: catalog) == .null)
        let canonical = "{\n  \"format\": \"xrg-ng-settings\",\n  \"settings\": {},\n  \"version\": 1\n}\n"
        #expect(document.serialized() == Data(canonical.utf8))

        // A value equal to its default is not written, whichever way it got there.
        var changed = document
        try changed.set("general.window.border_width", .int(8), catalog: catalog)
        #expect(String(data: changed.serialized(), encoding: .utf8)!.contains("\"general.window.border_width\": 8"))
        try changed.set("general.window.border_width", .int(4), catalog: catalog)
        #expect(changed.serialized() == Data(canonical.utf8))

        let loadedDefault = Data(#"{"format": "xrg-ng-settings", "version": 1, "settings": {"general.window.border_width": 4, "general.window.sticky_edges": true}}"#.utf8)
        let (atDefaults, diagnostics) = try #require(loadOK(loadedDefault, catalog))
        #expect(diagnostics.isEmpty)
        #expect(atDefaults.serialized() == Data(canonical.utf8))
    }

    // MARK: escaped surrogate pairs

    /// A supplementary character written as a pair of `\u` escapes is valid
    /// JSON (RFC 8259 §7) and must not make the document unreadable: an
    /// unknown key and an unknown string value that both contain 😀 (U+1F600)
    /// load, and the canonical output carries the character as raw UTF-8.
    /// The same character written raw in the file loads to the same document
    /// and the same bytes.
    @Test func surrogatePairsSurviveRoundTrip() throws {
        let catalog = try XRGSettingsCatalog.load()
        // 😀 is U+1F600: high surrogate D83D, low surrogate DE00.
        let escaped = Data(#"{"format": "xrg-ng-settings", "version": 1, "settings": {"emoji\uD83D\uDE00key": "\uD83D\uDE00"}}"#.utf8)
        let (document, diagnostics) = try #require(loadOK(escaped, catalog))
        #expect(diagnostics.isEmpty)
        #expect(document.values.isEmpty)
        #expect(document.unknown == ["emoji\u{1F600}key": .string("\u{1F600}")])
        // Hand-derived expected bytes: the writer emits non-ASCII raw, so the
        // key and the value each carry U+1F600 as the four UTF-8 bytes
        // F0 9F 98 80; keys sorted, two-space indent, LF, trailing newline.
        let expected = "{\n  \"format\": \"xrg-ng-settings\",\n  \"settings\": {\n    \"emoji\u{1F600}key\": \"\u{1F600}\"\n  },\n  \"version\": 1\n}\n"
        #expect(document.serialized() == Data(expected.utf8))

        // The same character raw in the file: the same document, the same
        // canonical bytes — the escape and the raw form are one character.
        let raw = Data("{\"format\": \"xrg-ng-settings\", \"version\": 1, \"settings\": {\"emoji\u{1F600}key\": \"\u{1F600}\"}}".utf8)
        let (rawDocument, rawDiagnostics) = try #require(loadOK(raw, catalog))
        #expect(rawDiagnostics.isEmpty)
        #expect(rawDocument.unknown == document.unknown)
        #expect(rawDocument.serialized() == document.serialized())

        // Both canonical outputs reload byte-identically: the pair survives,
        // the raw bytes are read back raw, and load∘serialize is stable.
        for bytes in [document.serialized(), rawDocument.serialized()] {
            let (reloaded, reloadedDiagnostics) = try #require(loadOK(bytes, catalog))
            #expect(reloadedDiagnostics.isEmpty)
            #expect(reloaded.unknown == document.unknown)
            #expect(reloaded.serialized() == bytes)
        }
    }
}
