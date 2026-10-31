// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Stephen de la Vega.
// GitHub Sponsors wiring for the macOS app: the "Support XRG-ng…" item is
// inserted programmatically as the first item of the Help menu, reusing
// XRGUpdater.insertAppMenuItem (after: -1 places the item at index 0).
import AppKit

/// The project's donation link and the Help-menu item that opens it.
@MainActor
public enum XRGSupportLink {
    /// The GitHub Sponsors page for the XRG-ng maintainer.
    public static let url = URL(string: "https://github.com/sponsors/sdelavega")!

    /// The application's Help menu: AppKit's `helpMenu` when it has one,
    /// otherwise the submenu of the main-menu item titled "Help". `nil` when
    /// neither exists, in which case the support link is simply skipped.
    public static func helpMenu(of application: NSApplication = .shared) -> NSMenu? {
        if let menu = application.helpMenu { return menu }
        return application.mainMenu?.items.first(where: {
            $0.title == NSLocalizedString("Help", comment: "main menu title")
        })?.submenu
    }

    /// The Help menu's "Support XRG-ng…" item, placed as its first item and
    /// followed by a separator. Idempotent: the existing item is returned
    /// instead of adding a second one.
    @discardableResult
    public static func insert(into helpMenu: NSMenu, target: AnyObject, action: Selector) -> NSMenuItem {
        if let existing = helpMenu.items.first(where: { $0.action == action }) {
            return existing
        }
        let item = NSMenuItem(title: NSLocalizedString("Support XRG-ng…", comment: "help menu item"),
                              action: action, keyEquivalent: "")
        item.target = target
        // after: -1 inserts at index 0, so the support link leads the menu.
        XRGUpdater.insertAppMenuItem(item, after: -1, in: helpMenu)
        if helpMenu.items.count < 2 || !helpMenu.items[1].isSeparatorItem {
            XRGUpdater.insertAppMenuItem(.separator(), after: 0, in: helpMenu)
        }
        return item
    }
}