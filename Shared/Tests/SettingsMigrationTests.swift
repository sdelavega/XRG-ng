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
/// - `macos-0.2.2-defaults.plist` is a real export of a disposable defaults
///   domain, written by a harness built from the released 0.2.2 sources and
///   anonymised (review fix 5). Provenance: tag `v0.2.2`, commit
///   `9a4b401063335417ba89fa22643eb430b10a0e8e` ("Record passing 0.2.2 CI in
///   the release notes"), extracted with
///   `git archive v0.2.2 XRGCore Shared Controllers Utility 'Other Sources' Package.swift XRG-Bridging-Header.h | tar -x -C <scratch>/v022`
///   and compiled with
///   `swiftc -swift-version 5 -o write-fixture main.swift <v022>/XRGCore/{XRGSettings,XRGTheme,XRGGraphPreferences,XRGMonitorSource,XRGHardwareSources,XRGHardwareReading,XRGProcessInspector,XRGProcessMiner,XRGProcessAccess,XRGProcessDetailController}.swift <v022>/Shared/Sources/XRGSharedCore/{XRGBuiltinTheme,XRGThemeDocument}.swift`.
///   The harness writes the fixture's hand-chosen values through 0.2.2's own
///   encoders — `XRGSettings.applyThemeData` for the portable theme
///   document and the `NSKeyedArchiver` calls
///   `XRGPrefController.themeDictionary` and `preferencesSnapshot` make for
///   the colors and the font, `applyGraphPreferences`, the
///   `XRGMonitorSource`/`XRGHardwareSources` `encoded()` writers, and the
///   `JSONEncoder` `XRGProcessInspector` uses — into the disposable domain
///   `com.sdelavega.xrg.task-4-fixture`, then
///   `defaults export com.sdelavega.xrg.task-4-fixture <file>` (converted to
///   XML with `plutil -convert xml1`) produced these bytes. No real paths,
///   hostnames or secrets appear (checked against the export before it was
///   committed); the domain and its `~/Library/Preferences` plist were
///   deleted afterwards. `macos-0.2.2-expected.json` was derived by hand
///   from the catalog's `legacy` mappings: each defaults key was walked
///   through its transform and compared with the entry's default, and the
///   real archives' channels were read out of the exported bytes with an
///   independent plist dumper, never with the code under test; only
///   differing values are in the pinned canonical bytes.
/// - `linux-v40.json` is a hand-written, customised version-40 file in the
///   shape Rust's serde model writes — unset optional overrides omitted,
///   exactly as `skip_serializing_if` leaves them out, never as explicit
///   nulls. `linux-v40-expected.json` was derived
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
                "every key in the real 0.2.2 export must convert")
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

    @Test func allFourDisplayEffectsSurviveMigration() throws {
        let catalog = try XRGSettingsCatalog.load()
        // 0.2.2 saves the display effect as the popup's index (0-3). Every
        // one of the four supported effects must migrate to its option name
        // through the graphStyleIndex transform — none of them is invalid
        // data, so none may fall back to the default (review fix 1).
        for (index, effect) in [(0, "normal"), (1, "scanlines"), (2, "pixel_grid"), (3, "retro_dots")] {
            let (document, diagnostics) = XRGSettingsMigration.fromMacDefaults(
                ["graphStyle": index], catalog: catalog)
            #expect(diagnostics.isEmpty, "graphStyle \(index) was reported as invalid")
            // The resolved value, because "normal" is the entry's default
            // and defaults are never stored: what matters is that each
            // effect survives migration as the effective setting.
            #expect(document.value("appearance.display_effect", catalog: catalog) == .string(effect),
                    "graphStyle \(index) did not migrate as \(effect)")
        }
        // An index with no meaning still degrades: default plus diagnostic.
        let (document, diagnostics) = XRGSettingsMigration.fromMacDefaults(
            ["graphStyle": 9], catalog: catalog)
        #expect(diagnostics == [XRGSettingsDiagnostic(id: "appearance.display_effect", problem: "invalid-value")])
        #expect(document.values["appearance.display_effect"] == nil)
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
        // An omitted unit override means "follow the unit system" (serde
        // skips the option, so the real v40 shape has no null either), which
        // is not the catalog default: it must migrate as an explicit null.
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

    @Test func omittedLinuxUnitOverridesMigrateAsInheritance() throws {
        let catalog = try XRGSettingsCatalog.load()
        // Rust's serde omits an unset optional override
        // (`skip_serializing_if = "Option::is_none"`, weather.rs), so the
        // version-40 file of a US user who never chose per-unit overrides
        // carries only `"units": "us"`. Migration must record "follow the
        // unit system" — the document's null — for each omitted override,
        // never the concrete metric catalog defaults, or the round trip
        // would turn a US installation into Celsius/kilometers/hectopascals
        // (review fix 3).
        let json = Data(#"""
        {"version": 40, "weather": {"enabled": true, "history_hours": 6, "secondary": "none", "station": "KSEA", "units": "us", "refresh_minutes": 15}}
        """#.utf8)
        let (document, diagnostics) = try XRGSettingsMigration.fromLinuxV40(json, catalog: catalog)
        #expect(diagnostics.isEmpty)
        #expect(document.values["weather.units.system"] == .string("us"))
        #expect(document.values["weather.units.temperature"] == XRGSettingsValue.null)
        #expect(document.values["weather.units.distance"] == XRGSettingsValue.null)
        #expect(document.values["weather.units.pressure"] == XRGSettingsValue.null)
        // The wind override is also omitted, and its catalog default already
        // is the null that means "follow the distance units".
        #expect(document.values["weather.units.wind"] == nil)

        // The Linux view hands those nulls back as the v40 nulls they came
        // from, so Rust resolves them against "us", not against metric
        // defaults.
        let view = XRGSettingsMigration.linuxView(document, catalog: catalog)
        guard let text = String(data: view, encoding: .utf8),
              case .object(let fields)? = JSONValue.parse(text) else {
            Issue.record("the Linux view is not a JSON object")
            return
        }
        #expect(fields["weather"] == .object([
            "distance_units": .null,
            "enabled": .bool(true),
            "history_hours": .number("6"),
            "pressure_units": .null,
            "refresh_minutes": .number("15"),
            "secondary": .string("none"),
            "station": .string("KSEA"),
            "temperature_units": .null,
            "units": .string("us"),
            "wind_units": .null,
        ]))
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

    @Test func linuxViewKeepsEditedColorsOnASelectedPreset() throws {
        let catalog = try XRGSettingsCatalog.load()

        // A v40 built-in theme migrates with the preset's own palette, so
        // the view keeps it built-in.
        let input = Data(#"{"version": 40, "theme": {"kind": "builtin", "name": "Ocean"}}"#.utf8)
        let (migrated, _) = try XRGSettingsMigration.fromLinuxV40(input, catalog: catalog)
        var document = migrated
        func theme() throws -> JSONValue {
            let view = XRGSettingsMigration.linuxView(document, catalog: catalog)
            guard let text = String(data: view, encoding: .utf8),
                  case .object(let fields)? = JSONValue.parse(text) else {
                throw NSError(domain: "SettingsMigrationTests", code: 1,
                              userInfo: [NSLocalizedDescriptionKey: "the Linux view is not a JSON object"])
            }
            return fields["theme"] ?? .null
        }
        #expect(try theme() == .object(["kind": .string("builtin"), "name": .string("Ocean")]))

        // A single colour edit on the selected preset: the effective
        // palette no longer is the preset's, so the view must carry it as a
        // custom theme — named after the theme the user started from — or
        // Linux would repaint the preset's original colour over the edit
        // (review fix 4).
        try document.set("appearance.window.color", .color([0.1, 0.2, 0.3, 1]), catalog: catalog)
        var palette = XRGBuiltinTheme.ocean.rgba
        palette[0] = [0.1, 0.2, 0.3, 1]
        let colors: [JSONValue] = palette.map { rgba in
            .array(rgba.map { .number(XRGSettingsDocument.number($0)) })
        }
        #expect(try theme() == .object([
            "kind": .string("custom"),
            "theme": .object([
                "colors": .array(colors),
                "format": .string("xrg-ng-theme"),
                "name": .string("Ocean"),
                "version": .number("1"),
            ]),
        ]))

        // The same edit with no stored theme name (a document the settings
        // window built, not a migration): the custom theme still carries the
        // selected preset's name.
        var edited = XRGSettingsDocument()
        try edited.set("themes.preset", .string("Dusk"), catalog: catalog)
        try edited.set("appearance.window.color", .color([0.2, 0.2, 0.2, 1]), catalog: catalog)
        document = edited
        guard case .object(let fields) = try theme(),
              case .object(let themeDocument)? = fields["theme"] else {
            Issue.record("the Linux view carries no custom theme")
            return
        }
        #expect(fields["kind"] == .string("custom"))
        #expect(themeDocument["name"] == .string("Dusk"))
        #expect(themeDocument["colors"] == .array([
            .array([0.2, 0.2, 0.2, 1].map { .number(XRGSettingsDocument.number($0)) }),
        ] + XRGBuiltinTheme.classic.rgba.dropFirst().map { rgba in
            .array(rgba.map { .number(XRGSettingsDocument.number($0)) })
        }))
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
        // The weather object here names no distance or pressure override,
        // so those two migrate as the nulls an omitted option means — the
        // same rule the omitted-overrides test pins.
        let badLinux = Data(#"{"version": 40, "layout": "diagonal", "graph_height": 100, "weather": {"temperature_units": "nautical"}}"#.utf8)
        let (linuxDocument, linuxDiagnostics) = try XRGSettingsMigration.fromLinuxV40(badLinux, catalog: catalog)
        #expect(linuxDiagnostics == [
            XRGSettingsDiagnostic(id: "general.window.orientation", problem: "invalid-value"),
            XRGSettingsDiagnostic(id: "weather.units.temperature", problem: "invalid-value"),
        ])
        #expect(linuxDocument.values == [
            "graphs.default_height": .int(100),
            "weather.units.distance": XRGSettingsValue.null,
            "weather.units.pressure": XRGSettingsValue.null,
        ])
        #expect(linuxDocument.value("general.window.orientation", catalog: catalog) == .string("vertical"))
        #expect(linuxDocument.value("weather.units.temperature", catalog: catalog) == .string("celsius"))
    }

    @Test func malformedArchivesFallBackPerKeyWithADiagnostic() throws {
        let catalog = try XRGSettingsCatalog.load()
        let defaults = try loadDefaultsPlist("macos-0.2.2-defaults")
        let archive = try #require(defaults["borderColor"] as? Data,
                                     "the real export carries the archived border color")

        func migrate(_ color: Any) -> (XRGSettingsDocument, [XRGSettingsDiagnostic]) {
            XRGSettingsMigration.fromMacDefaults(
                ["borderColor": color, "borderWidth": 6], catalog: catalog)
        }
        func expectPerKeyFallback(_ result: (XRGSettingsDocument, [XRGSettingsDiagnostic]),
                                  _ note: String) {
            #expect(result.1 == [XRGSettingsDiagnostic(id: "appearance.border.color",
                                                       problem: "invalid-value")],
                    "\(note): a malformed archive must fall back with exactly one diagnostic")
            #expect(result.0.values == ["general.window.border_width": .int(6)],
                    "\(note): the valid key in the same domain must still migrate")
        }

        // A table offset of UInt64.max passes the offset's own lower bound;
        // unchecked trailer arithmetic and unchecked UInt64-to-Int
        // conversions both trap on it (review fix 2).
        var overflow = archive
        for index in overflow.count - 8..<overflow.count { overflow[index] = 0xFF }
        expectPerKeyFallback(migrate(overflow), "a maximum object-table offset")

        // A trailer cut short: the object count and the table offset are
        // then read from whatever bytes sit where the trailer should be.
        expectPerKeyFallback(migrate(archive.prefix(41)), "a truncated trailer")
        expectPerKeyFallback(migrate(archive.prefix(20)), "a header without a trailer")

        // The $top root reference, out of range: an eight-byte UID of all
        // ones is UInt64.max, which the archive readers once converted with
        // an unchecked Int conversion.
        expectPerKeyFallback(migrate(Self.keyedArchive(
            root: Self.asciiObject("unused"),
            rootReference: Self.uidObject(UInt64.max, size: 8),
            objectReferences: [9, 10], referenceSize: 1)),
            "a root UID of UInt64.max")

        // An object reference beyond the object table.
        expectPerKeyFallback(migrate(Self.keyedArchive(
            root: Self.asciiObject("unused"),
            rootReference: Self.uidObject(10, size: 1),
            objectReferences: [9, 255], referenceSize: 1)),
            "an out-of-range object reference")

        // An oversized integer object: the 0x14 marker names a 16-byte int.
        expectPerKeyFallback(migrate(Self.keyedArchive(
            root: Data([0x14]) + Data(repeating: 0, count: 16),
            rootReference: Self.uidObject(10, size: 1),
            objectReferences: [9, 10], referenceSize: 1)),
            "an oversized integer")

        // A dictionary claiming more references than the archive holds:
        // with an eight-byte reference size the reference bytes are read
        // unchecked, run past what the input contains, and convert huge
        // values through unchecked Int conversions.
        expectPerKeyFallback(migrate(Self.keyedArchive(
            root: Data([0xdf, 0x10, 0x0f]),
            rootReference: Self.uidObject(10, size: 1),
            objectReferences: [9, 10], referenceSize: 8)),
            "a dictionary claiming more references than it holds")
    }

    // MARK: hand-built malformed archives

    /// The bytes of a binary property list in the exact shape NSKeyedArchiver
    /// writes, so malformed archives can be built deterministically: object 0
    /// is the archive's main dictionary (`$archiver`, `$version`,
    /// `$objects`, `$top`), `referenceSize` is the trailer's object-reference
    /// width, and every offset is one byte.
    private static func keyedArchive(root: Data, rootReference: Data,
                                     objectReferences: [Int], referenceSize: Int) -> Data {
        let objects = [
            dictionaryObject([(key: 5, value: 1), (key: 6, value: 2),
                              (key: 7, value: 3), (key: 8, value: 4)], referenceSize: referenceSize),
            asciiObject("NSKeyedArchiver"),
            intObject(100_000),
            arrayObject(objectReferences, referenceSize: referenceSize),
            dictionaryObject([(key: 11, value: 12)], referenceSize: referenceSize),
            asciiObject("$archiver"), asciiObject("$version"),
            asciiObject("$objects"), asciiObject("$top"),
            asciiObject("$null"),
            root,
            asciiObject("root"),
            rootReference,
        ]
        var bytes = Data("bplist00".utf8)
        var offsets: [Int] = []
        for object in objects {
            offsets.append(bytes.count)
            bytes.append(object)
        }
        let tableOffset = bytes.count
        for offset in offsets { bytes.append(UInt8(offset)) }
        bytes.append(Data(repeating: 0, count: 6))
        bytes.append(1)  // object-offset size
        bytes.append(UInt8(referenceSize))
        for shift in stride(from: 56, through: 0, by: -8) {
            bytes.append(UInt8(truncatingIfNeeded: UInt64(objects.count) >> UInt64(shift)))
        }
        bytes.append(Data(repeating: 0, count: 8))
        for shift in stride(from: 56, through: 0, by: -8) {
            bytes.append(UInt8(truncatingIfNeeded: UInt64(tableOffset) >> UInt64(shift)))
        }
        return bytes
    }

    private static func asciiObject(_ text: String) -> Data {
        let count = text.utf8.count
        // A count of 15 or more moves the length into the int object that
        // follows the 0x5f marker, the reader's extended-length form.
        if count < 15 { return Data([0x50 | UInt8(count)]) + Data(text.utf8) }
        return Data([0x5f, 0x10, UInt8(count)]) + Data(text.utf8)
    }

    private static func intObject(_ value: UInt32) -> Data {
        var bytes = Data([0x12])
        for shift in stride(from: 24, through: 0, by: -8) {
            bytes.append(UInt8((value >> UInt32(shift)) & 0xFF))
        }
        return bytes
    }

    private static func uidObject(_ value: UInt64, size: Int) -> Data {
        var bytes = Data([0x80 | UInt8(size - 1)])
        for shift in stride(from: (size - 1) * 8, through: 0, by: -8) {
            bytes.append(UInt8(truncatingIfNeeded: value >> UInt64(shift)))
        }
        return bytes
    }

    private static func arrayObject(_ references: [Int], referenceSize: Int) -> Data {
        Data([0xa0 | UInt8(references.count)]) + referenceBytes(references, referenceSize)
    }

    private static func dictionaryObject(_ pairs: [(key: Int, value: Int)], referenceSize: Int) -> Data {
        var bytes = Data([0xd0 | UInt8(pairs.count)])
        bytes += referenceBytes(pairs.map(\.key), referenceSize)
        bytes += referenceBytes(pairs.map(\.value), referenceSize)
        return bytes
    }

    private static func referenceBytes(_ references: [Int], _ size: Int) -> Data {
        var bytes = Data()
        for reference in references {
            for shift in stride(from: (size - 1) * 8, through: 0, by: -8) {
                bytes.append(UInt8(truncatingIfNeeded: UInt64(reference) >> UInt64(shift)))
            }
        }
        return bytes
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
        // either platform, whatever the catalog might someday say. (The
        // graphStyleIndex the plan's sketch named is a real transform now:
        // the catalog carries it and the inventory documents it, so the
        // loops above already assert it is implemented.)
        #expect(!XRGSettingsMigration.implementsTransform(named: "secondsToMilliseconds", platform: .macos))
        #expect(!XRGSettingsMigration.implementsTransform(named: "secondsToMilliseconds", platform: .linux))
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
