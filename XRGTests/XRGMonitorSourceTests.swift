// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Stephen de la Vega.
import AppKit
import Testing
@testable import XRGCore

struct XRGMonitorSourceTests {
    @Test(arguments: [nil, "0", "1048575", "IOService:/GPU/location"] as [String?])
    func sourceRoundTrips(source: String?) throws {
        let value = XRGMonitorSource(source: source)
        #expect(try XRGMonitorSource(data: value.encoded()) == value)
    }
    @Test(arguments: ["", "-1", "01", "1.5", "1048576", "GPU"])
    func CPUIndicesMustBeCanonicalAndBounded(source: String) {
        #expect(throws: (any Error).self) { try XRGMonitorSource(source: source).validateCPU() }
    }
    @Test(arguments: ["{}", "{\"version\":2}", "{\"version\":1,\"source\":false}", "{\"version\":1,\"extra\":1}", "{\"version\":1,\"source\":\"a\\nb\"}"])
    func invalidVersionsTypesUnknownFieldsAndControlsAreRejected(json: String) {
        #expect(throws: (any Error).self) { try XRGMonitorSource(data: Data(json.utf8)) }
    }
    @Test func dataAndUTF8IdentitiesAreBounded() {
        #expect(throws: (any Error).self) { try XRGMonitorSource(data: Data(repeating: 32, count: 8193)) }
        #expect(throws: (any Error).self) { try XRGMonitorSource(source: String(repeating: "é", count: 513)).encoded() }
    }
    @Test @MainActor func detailsAreScrollableSelectableAndReadOnly() throws {
        _ = NSApplication.shared
        let alert = XRGMonitorDetails.alert(title: "Fixture", text: String(repeating: "long details\n", count: 500))
        let scroll = try #require(alert.accessoryView as? NSScrollView)
        let text = try #require(scroll.documentView as? NSTextView)
        #expect(scroll.frame.height == 260 && scroll.hasVerticalScroller)
        #expect(!text.isEditable && text.isSelectable && text.string.hasPrefix("long details"))
        #expect(text.selectedRange().location == 0)
    }
}
