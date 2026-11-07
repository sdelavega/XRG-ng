// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Stephen de la Vega.
import Foundation
import Testing
@testable import XRGSharedCore

/// Migration of the 0.2.2 platform settings into the shared settings
/// document, and the Linux view of a document (spec §4).
///
/// The migration fixtures are hand-derived oracles, never produced by the
/// code under test:
///
/// - `macos-0.2.2-defaults.plist` is a realistic, customised 0.2.2 defaults
///   export: every value was chosen by hand, the color and font values are
///   real `NSKeyedArchiver` archives exactly as 0.2.2 writes them, and the
///   excluded keys a long-lived domain really contains (Sparkle `SU*`,
///   AppKit window frames, latches, recorded usage data) are all present.
///   `macos-0.2.2-expected.json` was derived by hand from the catalog's
///   `legacy` mappings: each defaults key was walked through its transform
///   and compared with the entry's default; only differing values are in the
///   pinned canonical bytes.
/// - `linux-v40.json` is a hand-written, customised version-40 file in the
///   shape Rust's serde model writes. `linux-v40-expected.json` was derived
///   by hand the same way, resolving each catalog `legacy.linux` pointer
///   against the file. `linux-v40-view-expected.json` was derived by hand
///   from that document through the reverse transforms, in the v40 shape
///   `xrg-linux/rust/src/settings.rs` deserialises, including the top-level
///   `stocks` object (ruling R2).
struct SettingsMigrationTests {
    /// Shared/Tests/SettingsMigrationTests.swift -> Fixtures/settings.
    private static let fixturesDirectory: URL = {
        var url = URL(fileURLWithPath: #filePath)
        url.deleteLastPathComponent()
        return url.appendingPathComponent("Fixtures/settings")
    }()

    /// The `<name>-expected.json` shape shared with the document corpus.
    private struct ExpectedFile: Decodable {
        var diagnostics: [XRGSettingsDiagnostic]
        var document: String?
    }

    private func expectedFile(_ file: String) throws -> ExpectedFile {
        let url = Self.fixturesDirectory.appendingPathComponent(file)
        return try JSONDecoder().decode(ExpectedFile.self, from: Data(contentsOf: url))
    }

    private func loadDefaultsPlist(_ name: String) throws -> [String: Any] {
        let url = Self.fixturesDirectory.appendingPathComponent("\(name).plist")
        let object = try PropertyListSerialization.propertyList(from: Data(contentsOf: url), options: [], format: nil)
        return try #require(object as? [String: Any])
    }

    // MARK: macOS defaults -> document

    @Test func macDefaultsMigrateToExpectedDocument() throws {
        let catalog = try XRGSettingsCatalog.load()
        let defaults = try loadDefaultsPlist("macos-0.2.2-defaults")
        let (document, diagnostics) = XRGSettingsMigration.fromMacDefaults(defaults, catalog: catalog)
        let expected = try expectedFile("macos-0.2.2-expected.json")
        #expect(diagnostics == expected.diagnostics,
                "the pinned diagnostic is the graphStyle key's (see the report)")
        #expect(document.serialized() == Data(try #require(expected.document).utf8),
                "the migrated document differs from the hand-derived bytes")

        // Spot checks the fixture pins on purpose: the excluded keys never
        // become settings, and the transforms that need context beyond the
        // raw value resolve it from the entry.
        #expect(document.values["general.window.collapse_anchor"] == .string("end"))
        #expect(document.values["graphs.temperature.show_unknown"] == nil)
        #expect(document.values["sources.temperature.show_unknown"] == .bool(true))
        // The temperature placeholders 0/1/2 and an empty selection are the
        // platform's auto-configuration state, not sensor keys: they migrate
        // as "not set", so only the real sensor key survives.
        #expect(document.values["sources.temperature.sensor1"] == .string("cpu"))
        #expect(document.values["sources.temperature.sensor2"] == nil)
        #expect(document.values["sources.temperature.sensor3"] == nil)
        // Every graph the blob does not override inherits its curve: the
        // transform yields null (docs/settings-inventory.md), which the
        // document stores because the catalog default is a concrete style.
        #expect(document.values["graphs.disk.style"] == XRGSettingsValue.null)
        #expect(document.values["graphs.cpu.style"] == .string("dot"))
        // Zero keeps its meaning through zeroToNull: history 0 is "session".
        let (zeroed, zeroDiagnostics) = XRGSettingsMigration.fromMacDefaults(
            ["weatherHistoryHours": 0], catalog: catalog)
        #expect(zeroDiagnostics.isEmpty)
        #expect(zeroed.values["weather.history_hours"] == nil)
    }

    // MARK: Linux version 40 -> document

    @Test func linuxV40MigratesToExpectedDocument() throws {
        let catalog = try XRGSettingsCatalog.load()
        let input = try Data(contentsOf: Self.fixturesDirectory.appendingPathComponent("linux-v40.json"))
        let (document, diagnostics) = try XRGSettingsMigration.fromLinuxV40(input, catalog: catalog)
        let expected = try expectedFile("linux-v40-expected.json")
        #expect(diagnostics == expected.diagnostics)
        #expect(document.serialized() == Data(try #require(expected.document).utf8),
                "the migrated document differs from the hand-derived bytes")

        // Spot checks: the module pointers are indexes into the default
        // order, but the saved array is the user's order, so migration must
        // locate every module by id wherever it sits (the fixture reorders).
        #expect(document.values["graphs.memory.style"] == .string("pixel"))
        #expect(document.values["graphs.fans.style"] == .string("hollow"))
        // A null unit override means "follow the unit system", which is not
        // the catalog default: it must survive as an explicit null.
        #expect(document.values["weather.units.temperature"] == XRGSettingsValue.null)
        // A custom theme keeps its name and fills the palette entries.
        #expect(document.values["themes.preset"] == .string("Custom"))
        #expect(document.values["themes.name"] == .string("Aurora"))
        #expect(document.values["appearance.window.color"] == .color([0, 0.05, 0.1, 0.8]))

        // Anything that is not a version-40 object is refused, never parsed
        // as an empty document.
        #expect(throws: XRGSettingsMigrationError.malformedV40.self) {
            _ = try XRGSettingsMigration.fromLinuxV40(Data("not json".utf8), catalog: catalog)
        }
        #expect(throws: XRGSettingsMigrationError.malformedV40.self) {
            _ = try XRGSettingsMigration.fromLinuxV40(Data("[1, 2, 3]".utf8), catalog: catalog)
        }
        #expect(throws: XRGSettingsMigrationError.malformedV40.self) {
            _ = try XRGSettingsMigration.fromLinuxV40(Data("null".utf8), catalog: catalog)
        }
    }

    // MARK: document -> Linux view

    @Test func linuxViewRoundTrips() throws {
        let catalog = try XRGSettingsCatalog.load()
        let input = try Data(contentsOf: Self.fixturesDirectory.appendingPathComponent("linux-v40.json"))
        let (document, _) = try XRGSettingsMigration.fromLinuxV40(input, catalog: catalog)
        let view = XRGSettingsMigration.linuxView(document, catalog: catalog)
        let expected = try Data(contentsOf: Self.fixturesDirectory
            .appendingPathComponent("linux-v40-view-expected.json"))
        #expect(view == expected, "the Linux view differs from the hand-derived v40 shape")
        // The view is well-formed JSON in the v40 shape Rust deserialises:
        // every struct field present, plus the shared Stocks object.
        guard let text = String(data: view, encoding: .utf8),
              case .object(let fields)? = JSONValue.parse(text) else {
            Issue.record("the Linux view is not a JSON object")
            return
        }
        #expect(fields["version"] == .number("40"))
        #expect(fields["stocks"] == .object([
            "show_change": .bool(true),
            "show_djia": .bool(true),
            "symbols": .string("AAPL"),
            "timeframe": .number("12"),
        ]))
        #expect(fields.keys.contains("modules") && fields.keys.contains("metrics")
                && fields.keys.contains("ai") && fields.keys.contains("weather"))
    }

    // MARK: degradation

    @Test func unconvertibleKeyFallsBackAndReports() throws {
        let catalog = try XRGSettingsCatalog.load()

        // macOS: a level index with no meaning, and a monitor-source blob
        // that is not JSON. Both take their defaults and are reported; the
        // valid key in the same domain still migrates.
        let badMac: [String: Any] = [
            "windowLevel": 9,
            "borderWidth": 3,
            "XRGCPUView.Source.v1": Data("not json".utf8),
        ]
        let (macDocument, macDiagnostics) = XRGSettingsMigration.fromMacDefaults(badMac, catalog: catalog)
        #expect(macDiagnostics == [
            XRGSettingsDiagnostic(id: "general.window.level", problem: "invalid-value"),
            XRGSettingsDiagnostic(id: "sources.cpu.core", problem: "invalid-value"),
        ])
        #expect(macDocument.values == ["general.window.border_width": .int(3)])
        #expect(macDocument.value("general.window.level", catalog: catalog) == .string("normal"))

        // Linux: a layout Rust would reject and a unit the transform does
        // not know. Same rule: default plus diagnostic, launch never blocks.
        let badLinux = Data(#"{"version": 40, "layout": "diagonal", "graph_height": 100, "weather": {"temperature_units": "nautical"}}"#.utf8)
        let (linuxDocument, linuxDiagnostics) = try XRGSettingsMigration.fromLinuxV40(badLinux, catalog: catalog)
        #expect(linuxDiagnostics == [
            XRGSettingsDiagnostic(id: "general.window.orientation", problem: "invalid-value"),
            XRGSettingsDiagnostic(id: "weather.units.temperature", problem: "invalid-value"),
        ])
        #expect(linuxDocument.values == ["graphs.default_height": .int(100)])
        #expect(linuxDocument.value("general.window.orientation", catalog: catalog) == .string("vertical"))
        #expect(linuxDocument.value("weather.units.temperature", catalog: catalog) == .string("celsius"))
    }

    // MARK: catalog agreement

    @Test func everyLegacyTransformExists() throws {
        let catalog = try XRGSettingsCatalog.load()
        for entry in catalog.entries {
            if let name = entry.legacy?.macosTransform {
                #expect(XRGSettingsMigration.implementsTransform(named: name, platform: .macos),
                        "\(entry.id) names an unimplemented macOS transform: \(name)")
            }
            if let name = entry.legacy?.linuxTransform {
                #expect(XRGSettingsMigration.implementsTransform(named: name, platform: .linux),
                        "\(entry.id) names an unimplemented Linux transform: \(name)")
            }
        }
        // The switch is closed: an unknown name is not a transform, on
        // either platform, whatever the catalog might someday say.
        #expect(!XRGSettingsMigration.implementsTransform(named: "secondsToMilliseconds", platform: .macos))
        #expect(!XRGSettingsMigration.implementsTransform(named: "secondsToMilliseconds", platform: .linux))
        #expect(!XRGSettingsMigration.implementsTransform(named: "graphStyleIndex", platform: .macos))
        #expect(!XRGSettingsMigration.implementsTransform(named: "noSuchTransform", platform: .linux))

        // The closed switch also agrees with docs/settings-inventory.md:
        // every transform the tables document is implemented, and nothing
        // implements a name the tables do not carry.
        let url = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("docs/settings-inventory.md")
        let text = try String(contentsOf: url, encoding: .utf8)
        var documented: [XRGSettingsPlatform: Set<String>] = [.macos: [], .linux: []]
        var platform: XRGSettingsPlatform?
        for line in text.components(separatedBy: .newlines) {
            if line.hasPrefix("## macOS transforms") { platform = .macos }
            if line.hasPrefix("## Linux transforms") { platform = .linux }
            if line.hasPrefix("## macOS defaults keys") { platform = nil }
            guard let platform, line.hasPrefix("| `") else { continue }
            let cells = line.split(separator: "|", omittingEmptySubsequences: false)
                .map { $0.trimmingCharacters(in: .whitespaces) }
            guard cells.count >= 2 else { continue }
            documented[platform]?.insert(cells[1].trimmingCharacters(in: CharacterSet(charactersIn: "`")))
        }
        for (platform, names) in documented where !names.isEmpty {
            for name in names {
                #expect(XRGSettingsMigration.implementsTransform(named: name, platform: platform),
                        "the inventory documents an unimplemented \(platform) transform: \(name)")
            }
            for entry in catalog.entries {
                for name in [entry.legacy?.macosTransform, entry.legacy?.linuxTransform].compactMap({ $0 })
                    where XRGSettingsMigration.implementsTransform(named: name, platform: platform) {
                    #expect(names.contains(name),
                            "an implemented \(platform) transform is missing from the inventory: \(name)")
                }
            }
        }
    }

    // MARK: excluded storage

    @Test func migrationNeverReadsSparkleKeys() throws {
        let catalog = try XRGSettingsCatalog.load()

        // A domain holding only excluded keys migrates to the empty default
        // document: Sparkle's SU* state, AppKit window frames, the restore
        // frame, one-shot latches, recorded usage data and the profiling
        // marker are not settings, and none of them is a failure.
        let excluded: [String: Any] = [
            "NSWindow Frame XRG": "{{1, 2}, {3, 4}}",
            "SUEnableAutomaticChecks": false,
            "SUHasLaunchedBefore": true,
            "SUScheduledCheckInterval": 3600,
            "aiTokensDailyDate": Date(timeIntervalSince1970: 1_793_975_940),
            "aiTokensDailyPromptTokens": 999,
            "fastCPUUsage": false,
            "packagedSmokeMarker": "smoke",
            "portableThemeDocument": Data(#"{"format":"xrg-ng-theme","version":1,"name":"X","colors":[[0,0,0,1],[0,0,0,1],[0,0,0,1],[0,0,0,1],[0,0,0,1],[0,0,0,1],[0,0,0,1]]}"#.utf8),
            "tempLocationsAutoconfigured": true,
            "unminimizedFrame": "{{5, 6}, {7, 8}}",
            "windowHeight": 43,
            "windowOriginX": 1,
            "windowOriginY": 2,
            "windowWidth": 42,
        ]
        let (emptyDocument, emptyDiagnostics) = XRGSettingsMigration.fromMacDefaults(excluded, catalog: catalog)
        #expect(emptyDocument.values.isEmpty, "an excluded key became a setting")
        #expect(emptyDocument.unknown.isEmpty && emptyDocument.rootUnknown.isEmpty,
                "an excluded key was preserved into the document")
        #expect(emptyDiagnostics.isEmpty, "an excluded key was reported as a problem")

        // Decoys that a sloppy migration could confuse with real settings:
        // Sparkle's check state is not the app's, the profiling tool's
        // fastCPUUsage is not the fast-bars preference, and the registered
        // window geometry is not the Linux remembered size.
        let decoys: [String: Any] = [
            "SUEnableAutomaticChecks": true,
            "checkForUpdates": false,
            "fastCPUUsage": false,
            "windowWidth": 999,
        ]
        let (document, diagnostics) = XRGSettingsMigration.fromMacDefaults(decoys, catalog: catalog)
        #expect(diagnostics.isEmpty)
        #expect(document.values == ["general.updates.check_on_launch": .bool(false)],
                "only the app's own defaults key migrated")
        #expect(document.value("graphs.cpu.fast_bars", catalog: catalog) == .bool(true))
    }
}
