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
///   from their catalog default, plus every unknown key), or `null` when the
///   input is unreadable.
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
        // Keys the catalog does not know survive verbatim, wherever they sat
        // in the input; a top-level unknown key is carried inside `settings`,
        // the document's one value namespace.
        #expect(document.values == ["general.window.border_width": .int(2)])
        #expect(document.unknown == [
            "another.scalar": .number(-7),
            "experiments.alpha.flag": .bool(true),
            "future.widget.config": .object([
                "labels": .array([.string("a"), .string("b")]),
                "nested": .object(["deep": .null]),
                "size": .number(2),
            ]),
            "some.scalar": .number(3.25),
            "toplevel.extra": .string("kept"),
        ])
        let (reloaded, rediagnostics) = try #require(loadOK(document.serialized(), catalog))
        #expect(rediagnostics.isEmpty)
        #expect(reloaded.unknown == document.unknown)
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

    @Test func setEnforcesDependencies() throws {
        let catalog = try XRGSettingsCatalog.load()
        var document = XRGSettingsDocument.defaults(catalog: catalog, platform: .macos)
        // Bring-to-front depends on expand-on-hover being on (its default).
        try document.set("general.window.expand_on_hover", .bool(false), catalog: catalog)
        #expect(throws: XRGSettingsError.dependencyNotMet) {
            try document.set("general.window.bring_to_front_on_expand", .bool(true), catalog: catalog)
        }
        #expect(document.values["general.window.bring_to_front_on_expand"] == nil)
        try document.set("general.window.expand_on_hover", .bool(true), catalog: catalog)
        try document.set("general.window.bring_to_front_on_expand", .bool(true), catalog: catalog)
        #expect(document.value("general.window.bring_to_front_on_expand", catalog: catalog) == .bool(true))
        // Samples depends on the CPU time window following the sample count (0).
        try document.set("graphs.cpu.time_window", .int(5), catalog: catalog)
        #expect(throws: XRGSettingsError.dependencyNotMet) {
            try document.set("graphs.cpu.samples", .int(500), catalog: catalog)
        }
        try document.set("graphs.cpu.time_window", .int(0), catalog: catalog)
        try document.set("graphs.cpu.samples", .int(500), catalog: catalog)
        #expect(document.value("graphs.cpu.samples", catalog: catalog) == .int(500))
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

        // A macOS reset sees only the macOS entries of the section.
        document.resetSection("general", catalog: catalog, platform: .macos)
        #expect(document.value("general.window.border_width", catalog: catalog) == .int(4))
        #expect(document.value("general.window.opacity", catalog: catalog) == .double(0.5))
        #expect(document.value("appearance.font", catalog: catalog) == .string("Menlo 12"))
        #expect(document.value("graphs.refresh", catalog: catalog) == .int(5))
        // Unknown keys are never touched by a reset.
        #expect(document.unknown["toplevel.extra"] == .string("kept"))
        #expect(document.unknown["future.widget.config"] != nil)

        // The Linux reset also reaches the Linux-only entries of the section.
        document.resetSection("general", catalog: catalog, platform: .linux)
        #expect(document.value("general.window.opacity", catalog: catalog) == .int(1))
        #expect(document.value("graphs.refresh", catalog: catalog) == .int(5))
        #expect(document.unknown["toplevel.extra"] == .string("kept"))
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

    @Test func topLevelUnknownsAreFoldedIntoSettings() throws {
        let catalog = try XRGSettingsCatalog.load()
        let input = Data(#"{"format": "xrg-ng-settings", "version": 1, "settings": {"general.window.border_width": 2}, "toplevel.extra": {"z": true}}"#.utf8)
        let (document, diagnostics) = try #require(loadOK(input, catalog))
        #expect(diagnostics.isEmpty)
        #expect(document.values == ["general.window.border_width": .int(2)])
        #expect(document.unknown == ["toplevel.extra": .object(["z": .bool(true)])])
        // The one value namespace is `settings`, so the unknown key is
        // written there — hand-derived expected bytes, exactly as for the corpus.
        let expected = "{\n  \"format\": \"xrg-ng-settings\",\n  \"settings\": {\n    \"general.window.border_width\": 2,\n    \"toplevel.extra\": {\n      \"z\": true\n    }\n  },\n  \"version\": 1\n}\n"
        #expect(document.serialized() == Data(expected.utf8))
        // Folding is idempotent: the second round-trip is byte-identical.
        let (reloaded, _) = try #require(loadOK(document.serialized(), catalog))
        #expect(reloaded.serialized() == document.serialized())
    }

    @Test func defaultsAreNotWritten() throws {
        let catalog = try XRGSettingsCatalog.load()
        let document = XRGSettingsDocument.defaults(catalog: catalog, platform: .macos)
        #expect(document.values.isEmpty)
        #expect(document.unknown.isEmpty)
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
}
