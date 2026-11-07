/*
 * XRG-ng: A system resource grapher for macOS and Linux.
 * Copyright (C) 2002-2024 Mike Piatek-Jimenez / Gaucho Software, LLC.
 * Copyright (C) 2025-2026 Marc Shade.
 * Copyright (C) 2026 Stephen de la Vega.
 * You can view the complete license in the LICENSE file in the root
 * of the source tree.
 *
 * This program is free software; you can redistribute it and/or
 * modify it under the terms of the GNU General Public License
 * as published by the Free Software Foundation; either version 3
 * of the License, or (at your option) any later version.
 *
 * This program is distributed in the hope that it will be useful,
 * but WITHOUT ANY WARRANTY; without even the implied warranty of
 * MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
 * GNU General Public License for more details.
 *
 * You should have received a copy of the GNU General Public License
 * along with this program. If not, see <https://www.gnu.org/licenses/>.
 *
 */

import AppKit

/// Implemented by the existing graph views while rendering is migrated separately.
@MainActor @objc public protocol XRGModuleView: NSObjectProtocol {
    func setGraphSize(_ size: NSSize)
    func updateMinSize()
    func min30Update(_ timer: Timer?)
    func min5Update(_ timer: Timer?)
    func graphUpdate(_ timer: Timer?)
    func fastUpdate(_ timer: Timer?)
}

@MainActor
@objc(XRGModule) @objcMembers
public final class XRGModule: NSObject {
    private let defaults: UserDefaults
    /// The settings this module's saved size belongs to; nil keeps the
    /// legacy defaults domain (the store's legacy backend reads and writes
    /// it exactly as before).
    private weak var settings: XRGSettings?

    public var name: String? { didSet { if name != nil { isEmptyModule = false } } }
    // The module owns its view, as before. The manager's window reference is weak.
    public var reference: NSView? { didSet { if reference != nil { isEmptyModule = false } } }
    public var isDisplayed = true { didSet { isEmptyModule = false } }
    public var displayOrder = -1 { didSet { isEmptyModule = false } }
    public var maxHeight: CGFloat = 1000 { didSet { isEmptyModule = false } }
    public var minHeight: CGFloat = 30 { didSet { isEmptyModule = false } }
    public var minWidth: CGFloat = 30 { didSet { isEmptyModule = false } }
    public var currentSize = NSSize(width: 55, height: 65) {
        didSet {
            currentSize = NSSize(width: Self.dimension(currentSize.width),
                                 height: Self.dimension(currentSize.height))
            Self.saveSize(forModule: self)
            isEmptyModule = false
        }
    }
    public var doesMin30Update = false { didSet { isEmptyModule = false } }
    public var doesMin5Update = false { didSet { isEmptyModule = false } }
    public var doesGraphUpdate = true { didSet { isEmptyModule = false } }
    public var doesFastUpdate = false { didSet { isEmptyModule = false } }
    public var alwaysDoesGraphUpdate = false { didSet { isEmptyModule = false } }
    public var isEmptyModule = true

    public override convenience init() { self.init(defaults: .standard) }

    @nonobjc init(defaults: UserDefaults) {
        self.defaults = defaults
        super.init()
    }

    @objc(initWithName:)
    public convenience init(name: String?) {
        self.init(name: name, reference: nil, defaults: .standard)
    }

    @objc(initWithName:andReference:)
    public convenience init(name: String?, andReference reference: NSView?) {
        self.init(name: name, reference: reference, defaults: .standard)
    }

    @nonobjc convenience init(name: String?, reference: NSView?, defaults: UserDefaults, settings: XRGSettings? = nil) {
        self.init(defaults: defaults)
        self.name = name
        self.reference = reference
        self.settings = settings
        self.currentSize = Self.savedSize(forModule: self)
        isEmptyModule = false
    }

    /// The store this module's size is saved through: the settings' store,
    /// or the legacy backend over the injected defaults.
    private var store: XRGSettingsStore {
        settings?.store ?? XRGSettingsStore.legacy(defaults: defaults)
    }

    @objc(saveSizeForModule:)
    public static func saveSize(forModule module: XRGModule?) {
        guard let module, let name = module.name else { return }
        module.store.storeSetting(Double(module.currentSize.width), legacyKey: "XRGModule_\(name)_width")
        module.store.storeSetting(Double(module.currentSize.height), legacyKey: "XRGModule_\(name)_height")
    }

    @objc(savedSizeForModule:)
    public static func savedSize(forModule module: XRGModule?) -> NSSize {
        guard let module, let name = module.name else { return NSSize(width: 55, height: 65) }
        func value(_ suffix: String, fallback: CGFloat) -> CGFloat {
            // Zero and unset mean automatic sizing: the store reads null for
            // an entry that was never saved.
            guard let number = module.store.doubleSetting(legacyKey: "XRGModule_\(name)_\(suffix)"),
                  number.isFinite, number > 0 else { return fallback }
            return CGFloat(number)
        }
        return NSSize(width: value("width", fallback: 55), height: value("height", fallback: 65))
    }

    @nonobjc static func dimension(_ value: CGFloat) -> CGFloat {
        value.isFinite ? max(0, value) : 0
    }

    @nonobjc var updateTarget: (any XRGModuleView)? { reference as? any XRGModuleView }
}
