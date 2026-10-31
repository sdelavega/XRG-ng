// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Stephen de la Vega.
// GitHub Sponsors link: the donation URL and Help-menu item placement.
import AppKit
import Testing
import XRGCore

@Suite(.serialized) @MainActor
struct XRGSupportLinkTests {
    /// The Help menu shape the MainMenu nib builds: a help item and a separator.
    private func helpMenu() -> NSMenu {
        let menu = NSMenu()
        menu.addItem(NSMenuItem(title: "XRG-ng Help", action: nil, keyEquivalent: ""))
        menu.addItem(NSMenuItem.separator())
        return menu
    }

    @Test func testSupportURL() {
        #expect(XRGSupportLink.url == URL(string: "https://github.com/sponsors/sdelavega"))
        #expect(XRGSupportLink.url.absoluteString == "https://github.com/sponsors/sdelavega")
    }

    @Test func testInsertsFirstInHelpMenuWithSeparator() throws {
        let menu = helpMenu()
        let target = SupportTarget()
        let action = #selector(SupportTarget.openSponsors(_:))
        let item = XRGSupportLink.insert(into: menu, target: target, action: action)
        #expect(menu.items.first === item)
        #expect(item.title == "Support XRG-ng…")
        #expect(item.action == action)
        #expect(item.target === target)
        #expect(menu.items.count == 4)
        #expect(menu.items[1].isSeparatorItem)
        #expect(menu.items[2].title == "XRG-ng Help")
        #expect(menu.items[3].isSeparatorItem)
    }

    @Test func testInsertIsIdempotent() {
        let menu = helpMenu()
        let target = SupportTarget()
        let action = #selector(SupportTarget.openSponsors(_:))
        let first = XRGSupportLink.insert(into: menu, target: target, action: action)
        let second = XRGSupportLink.insert(into: menu, target: target, action: action)
        #expect(first === second)
        #expect(menu.items.filter { $0.action == action }.count == 1)
        #expect(menu.items.count == 4)
        #expect(menu.items[0] === first && menu.items[1].isSeparatorItem)
    }

    /// A stand-in target so the inserted item's action and target can be verified.
    private final class SupportTarget: NSObject {
        @objc func openSponsors(_ sender: Any?) {}
    }
}