// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Stephen de la Vega.
// Sparkle update wiring for the macOS app. MainMenu.nib stays untouched; the
// "Check for Updates…" item is inserted programmatically after "About XRG-ng".
import AppKit
import Sparkle

/// Thin adapter around Sparkle's standard updater controller plus the AppKit
/// wiring the nib cannot hold. `init(startingUpdater: false)` constructs the
/// controller without starting update checks, which keeps unhosted test
/// processes and disposable bundle copies inert; the shipping app starts the
/// updater through `controller.startUpdater()` once launch work is done.
///
/// The internal `init(startingUpdater:host:defaults:)` is the seam the 0.1.0
/// upgrade test exercises: Sparkle's `SUHost` binds a non-main host bundle to
/// the `UserDefaults` suite named by that bundle's identifier, so a test host
/// whose identifier names an isolated suite makes the updater's defaults
/// traffic observable in, and confined to, that seeded suite.
@MainActor
public final class XRGUpdater: NSObject {
    /// Sparkle's standard controller. The app menu item targets this adapter
    /// so the updater can also stay unstarted while the item already exists.
    public var controller: SPUStandardUpdaterController

    /// Sparkle's updater bound to the host bundle this adapter was created
    /// with: `controller.updater` in the shipping app (main-bundle host), or
    /// the updater Sparkle binds to a non-main test host.
    let sparkleUpdater: SPUUpdater

    /// The defaults domain this adapter itself writes through (the shipping
    /// app passes the application's standard domain).
    let defaults: UserDefaults

    public convenience init(startingUpdater: Bool) {
        self.init(startingUpdater: startingUpdater, host: .main, defaults: .standard)
    }

    /// - Parameters:
    ///   - host: the bundle Sparkle updates. Sparkle reads and writes a
    ///     non-main host's settings in the `UserDefaults` suite named by that
    ///     bundle's identifier (`SUHost`); `Bundle.main` uses the standard
    ///     domain. Pass a `defaults` that is that same suite for non-main
    ///     hosts so both handles observe one seeded domain.
    ///   - defaults: the domain this adapter itself writes through.
    init(startingUpdater: Bool, host: Bundle, defaults: UserDefaults) {
        if host === Bundle.main {
            controller = SPUStandardUpdaterController(startingUpdater: startingUpdater,
                                                      updaterDelegate: nil, userDriverDelegate: nil)
            sparkleUpdater = controller.updater
        } else {
            // Sparkle's standard controller binds `Bundle.main` only, so bind
            // the updater to `host` directly. `controller` stays inert and
            // unstarted (the public interface and the shipping app still see
            // Sparkle's standard controller); the host-bound updater above is
            // the one the adapter drives.
            controller = SPUStandardUpdaterController(startingUpdater: false,
                                                      updaterDelegate: nil, userDriverDelegate: nil)
            sparkleUpdater = SPUUpdater(hostBundle: host, applicationBundle: host,
                                        userDriver: SPUStandardUserDriver(hostBundle: host, delegate: nil),
                                        delegate: nil)
        }
        self.defaults = defaults
        super.init()
    }

    /// Menu action behind "Check for Updates…".
    @objc public func checkForUpdates(_ sender: Any?) {
        sparkleUpdater.checkForUpdates()
    }

    /// Mirrors Sparkle's own menu-item validation: the item is enabled only
    /// while the updater can run a user-initiated check.
    @objc public func validateMenuItem(_ item: NSMenuItem) -> Bool {
        item.action == #selector(checkForUpdates(_:)) ? sparkleUpdater.canCheckForUpdates : true
    }

    /// The application menu's "Check for Updates…" item, placed directly after
    /// the first item ("About XRG-ng"). Idempotent: the existing item is
    /// returned instead of adding a second one.
    @discardableResult
    public static func insertCheckForUpdatesItem(into appMenu: NSMenu, target: XRGUpdater) -> NSMenuItem {
        if let existing = appMenu.items.first(where: { $0.action == #selector(checkForUpdates(_:)) }) {
            return existing
        }
        let item = NSMenuItem(title: NSLocalizedString("Check for Updates…", comment: "application menu item"),
                              action: #selector(checkForUpdates(_:)), keyEquivalent: "")
        item.target = target
        insertAppMenuItem(item, after: 0, in: appMenu)
        return item
    }

    /// Inserts `item` directly after the item currently at `index`, clamped to
    /// the menu's bounds. Idempotent: an item already in the menu is never
    /// duplicated. Task 5 reuses this for the Help menu's support link.
    public static func insertAppMenuItem(_ item: NSMenuItem, after index: Int, in menu: NSMenu) {
        guard !menu.items.contains(where: { $0 === item }) else { return }
        menu.insertItem(item, at: min(max(index + 1, 0), menu.numberOfItems))
    }
}
