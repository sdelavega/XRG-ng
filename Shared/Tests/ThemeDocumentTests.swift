// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Stephen de la Vega.
import Foundation
import Testing
@testable import XRGSharedCore

struct ThemeDocumentTests {
    struct Case: Decodable { let name: String; let json: String; let valid: Bool }
    private func fixture(_ name: String) throws -> Data {
        let url = try #require(Bundle.module.url(forResource: name, withExtension: "json", subdirectory: "Fixtures"))
        return try Data(contentsOf: url)
    }
    @Test func swiftAndRustUseTheSameWireAcceptanceCases() throws {
        let cases = try JSONDecoder().decode([Case].self, from: fixture("theme-validation-cases"))
        for item in cases {
            let parsed = try? XRGThemeDocument(data: Data(item.json.utf8))
            #expect((parsed != nil) == item.valid, "\(item.name)")
        }
    }
    @Test func portableColorsAndNamesRoundTripWithoutPrecisionLoss() throws {
        let document = try XRGThemeDocument(data: fixture("portable-theme"))
        #expect(try XRGThemeDocument(data: document.encoded()) == document)
        #expect(document.colors[0][0] == 0.012345678901234567)
    }
    @Test func oversizedAndNonUTF8DocumentsAreRejected() throws {
        var data = try fixture("portable-theme")
        data.append(Data(repeating: 0x20, count: XRGThemeDocument.byteLimit))
        #expect(throws: (any Error).self) { try XRGThemeDocument(data: data) }
        let utf16 = try #require(String(data: fixture("portable-theme"), encoding: .utf8)?.data(using: .utf16))
        #expect(throws: (any Error).self) { try XRGThemeDocument(data: utf16) }
    }
}
