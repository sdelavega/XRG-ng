// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Stephen de la Vega.
import AppKit
import UniformTypeIdentifiers
import Testing
@testable import XRGCore

private final class PortableThemeResources: NSObject {}

@Suite(.serialized) @MainActor
struct XRGPortableThemeTests {
    private func fixture(_ name: String) throws -> Data {
        let url = try #require(Bundle(for: PortableThemeResources.self).url(forResource: name, withExtension: "json"))
        return try Data(contentsOf: url)
    }
    @Test func invalidPortableDocumentsCannotPartiallyChangeColorsOrPreferences() throws {
        struct Case: Decodable { let name: String; let json: String; let valid: Bool }
        let domain = "XRG.portable-theme.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: domain))
        defer { defaults.removePersistentDomain(forName: domain) }
        let settings = XRGSettings(defaults: defaults)
        try settings.applyThemeData(fixture("portable-theme"), defaults: defaults)
        let original = defaults.persistentDomain(forName: domain) ?? [:]
        let color = settings.backgroundColor
        let cases = try JSONDecoder().decode([Case].self, from: fixture("theme-validation-cases"))
        for item in cases {
            if item.valid {
                #expect(throws: Never.self) { try XRGTheme(data: Data(item.json.utf8)) }
            } else {
                #expect(throws: (any Error).self) { try settings.applyThemeData(Data(item.json.utf8), defaults: defaults) }
                #expect(settings.backgroundColor == color, "\(item.name)")
                #expect(NSDictionary(dictionary: defaults.persistentDomain(forName: domain) ?? [:]).isEqual(to: original), "\(item.name)")
            }
        }
    }
    @Test func theSaveFormatPickerChangesTheExtensionAndAllowedTypeTogether() {
        _ = NSApplication.shared
        let panel = NSSavePanel(); panel.nameFieldStringValue = "Custom Theme.xtf"
        let format = XRGThemeSaveFormat(panel: panel)
        #expect(panel.nameFieldStringValue == "Custom Theme.xtf")
        format.picker.selectItem(at: 1); format.change(format.picker)
        #expect(panel.nameFieldStringValue == "Custom Theme.json")
        #expect(panel.allowedContentTypes == [.json])
        format.picker.selectItem(at: 0); format.change(format.picker)
        #expect(panel.nameFieldStringValue == "Custom Theme.xtf")
        #expect(panel.allowedContentTypes.first?.preferredFilenameExtension == "xtf")
    }
    @Test func boundedFileOpenDoesNotReadOrApplyAnOversizedPalette() throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("XRG-large-theme-\(UUID().uuidString).json")
        defer { try? FileManager.default.removeItem(at: url) }
        try Data(repeating: 0x20, count: XRGThemeDocument.byteLimit + 1).write(to: url)
        #expect(throws: (any Error).self) { try XRGTheme.readFile(url) }
    }
    @Test func wideGamutColorsExportAsBoundedSRGBWithoutChangingTheNativeArchive() throws {
        var rgba: [CGFloat] = [1, 0, 0, 0.6]
        let color = NSColor(colorSpace: .displayP3, components: &rgba, count: 4)
        let archive = try NSKeyedArchiver.archivedData(withRootObject: color, requiringSecureCoding: true)
        var dictionary = try XRGTheme.Builtin.classic.dictionary()
        dictionary["graphFG1Color"] = archive; dictionary["graphFG1Transparency"] = 0.6
        let theme = try XRGTheme(dictionary: dictionary)
        let doc = try theme.portableDocument(name: "P3 export", original: nil)
        #expect(doc.colors[2][0] == 1 && doc.colors[2][1] < 0.00001 && doc.colors[2][2] < 0.00001)
        #expect(doc.colors[2][3] == 0.6)
        #expect(try XRGThemeDocument(data: doc.encoded()) == doc)
        #expect(theme.fields[2].color.colorSpace == .displayP3)
        #expect(dictionary["graphFG1Color"] as? Data == archive)
    }
}
