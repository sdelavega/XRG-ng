// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Stephen de la Vega.
import Foundation
import Testing
@testable import XRGSharedCore

/// The bundled catalog is the single source of truth for both settings
/// windows; these tests keep it complete, self-consistent and in step with
/// docs/settings-inventory.md.
struct SettingsCatalogTests {
    private static let approvedSections = ["general", "appearance", "graphs", "sources", "ai",
                                           "weather", "stocks", "themes"]

    /// Shared/Tests/SettingsCatalogTests.swift -> repository root.
    private func repoRoot() -> URL {
        var url = URL(fileURLWithPath: #filePath)
        for _ in 0..<3 { url.deleteLastPathComponent() }
        return url
    }

    /// Rows of the inventory tables: (legacy key, mapping cell). Rows whose
    /// mapping starts with `excluded` are deliberate exclusions.
    private func inventoryRows() throws -> [(key: String, mapping: String)] {
        let url = repoRoot().appendingPathComponent("docs/settings-inventory.md")
        let text = try String(contentsOf: url, encoding: .utf8)
        var rows: [(key: String, mapping: String)] = []
        for line in text.components(separatedBy: .newlines) where line.hasPrefix("| `") {
            let cells = line.split(separator: "|", omittingEmptySubsequences: false)
                .map { $0.trimmingCharacters(in: .whitespaces) }
            // Key | Type | Default | Where it lives today | Catalog entry
            guard cells.count >= 6 else { continue }
            let key = cells[1].trimmingCharacters(in: CharacterSet(charactersIn: "`"))
            guard !key.isEmpty else { continue }
            rows.append((key, cells[5]))
        }
        return rows
    }

    private func legacyPointers(_ catalog: XRGSettingsCatalog) -> Set<String> {
        Set(catalog.entries.compactMap { $0.legacy?.macos }
            + catalog.entries.compactMap { $0.legacy?.linux })
    }

    private func asNumber(_ value: XRGSettingsValue) -> Double? {
        switch value {
        case .int(let number): return Double(number)
        case .double(let number): return number
        default: return nil
        }
    }

    @Test func bundledCatalogLoads() throws {
        let catalog = try XRGSettingsCatalog.load()
        #expect(!catalog.entries.isEmpty)
        #expect(catalog.entry("graphs.refresh") != nil)
        #expect(catalog.entry("stocks.symbols") != nil)
    }

    @Test func idsAreUniqueAndDotted() throws {
        let catalog = try XRGSettingsCatalog.load()
        let ids = catalog.entries.map(\.id)
        #expect(Set(ids).count == ids.count, "duplicate catalog ids")
        let regex = try NSRegularExpression(pattern: "^[a-z][a-z0-9]*(\\.[a-z][a-z0-9_]*)+$")
        for id in ids {
            #expect(regex.firstMatch(in: id, range: NSRange(id.startIndex..., in: id)) != nil,
                    "malformed catalog id: \(id)")
        }
    }

    @Test func sectionsAreTheApprovedList() throws {
        #expect(XRGSettingsCatalog.sections == Self.approvedSections)
        let catalog = try XRGSettingsCatalog.load()
        for entry in catalog.entries {
            #expect(Self.approvedSections.contains(entry.section),
                    "\(entry.id) is in unknown section \(entry.section)")
        }
    }

    @Test func defaultsSatisfyTheirOwnRules() throws {
        let catalog = try XRGSettingsCatalog.load()
        for entry in catalog.entries {
            let value = entry.defaultValue
            // null is the catalog's documented "not set" default: the platform
            // inherits, so it is valid for every control.
            if case XRGSettingsValue.null = value { continue }
            switch entry.control {
            case .toggle:
                guard case .bool = value else {
                    Issue.record("\(entry.id): a toggle default must be a bool"); continue
                }
            case .choice, .segmented:
                guard let options = entry.options, options.contains(where: { $0.value == value }) else {
                    Issue.record("\(entry.id): the default is not one of its options"); continue
                }
            case .integer:
                guard case .int = value else {
                    Issue.record("\(entry.id): an integer default must be an int"); continue
                }
                if let range = entry.range, !withinRange(value, range) {
                    Issue.record("\(entry.id): the integer default is outside its range")
                }
            case .duration:
                guard asNumber(value) != nil else {
                    Issue.record("\(entry.id): a duration default must be a number"); continue
                }
                if let range = entry.range, !withinRange(value, range) {
                    Issue.record("\(entry.id): the duration default is outside its range")
                }
            case .decimal:
                // A whole decimal (opacity 1.0) serialises as a JSON integer
                // and decodes back as .int with the same value, so any number
                // inside the range is a valid decimal default.
                guard asNumber(value) != nil else {
                    Issue.record("\(entry.id): a decimal default must be a number"); continue
                }
                if let range = entry.range, !withinRange(value, range) {
                    Issue.record("\(entry.id): the decimal default is outside its range")
                }
            case .color:
                guard case .color(let rgba) = value, rgba.count == 4,
                      rgba.allSatisfy({ $0.isFinite && (0...1).contains($0) }) else {
                    Issue.record("\(entry.id): a color default must be four components between 0 and 1")
                    continue
                }
            case .path, .text:
                guard case .string = value else {
                    Issue.record("\(entry.id): a \(entry.control.rawValue) default must be a string"); continue
                }
            case .source:
                switch value {
                case .string, .int: break
                default:
                    Issue.record("\(entry.id): a source default must be a string or int")
                }
            case .action:
                Issue.record("\(entry.id): an action entry must default to null")
            }
        }
    }

    private func withinRange(_ value: XRGSettingsValue, _ range: XRGSettingsRange) -> Bool {
        guard let number = asNumber(value) else { return false }
        return number >= range.min && number <= range.max
    }

    @Test func everyInventoryKeyIsMapped() throws {
        let catalog = try XRGSettingsCatalog.load()
        let pointers = legacyPointers(catalog)
        #expect(!pointers.isEmpty)
        let rows = try inventoryRows()
        // The inventory is a real inventory, not a stub.
        #expect(rows.count > 200, "the inventory tables lost their rows")
        var mapped = 0
        for row in rows where !row.mapping.hasPrefix("excluded") {
            #expect(pointers.contains(row.key),
                    "inventory key \(row.key) is not any entry's legacy pointer")
            mapped += 1
        }
        #expect(mapped > 150, "too few mapped inventory rows")
        let documented = Set(rows.map(\.key))
        for pointer in pointers {
            #expect(documented.contains(pointer),
                    "catalog legacy pointer \(pointer) has no inventory row")
        }
    }

    @Test func stocksIsSharedAndOrdered() throws {
        let catalog = try XRGSettingsCatalog.load()
        let stockEntries = catalog.entries.filter { $0.section == "stocks" }
        #expect(!stockEntries.isEmpty)
        for entry in stockEntries {
            #expect(entry.platforms == [.macos, .linux],
                    "\(entry.id) must exist on both platforms")
        }
        let onLinux = catalog.entries(section: "stocks", platform: .linux)
        #expect(onLinux.map(\.id) == stockEntries.map(\.id),
                "the stocks section must keep display order on every platform")
    }

    @Test func embeddedCatalogIsCurrent() throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        process.arguments = ["python3", "Tools/settings-catalog-embed.py", "--check"]
        process.currentDirectoryURL = repoRoot()
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = pipe
        try process.run()
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        let details = String(data: data, encoding: .utf8) ?? ""
        #expect(process.terminationStatus == 0,
                "the embedded catalog is stale; run Tools/settings-catalog-embed.py\n\(details)")
    }
}
