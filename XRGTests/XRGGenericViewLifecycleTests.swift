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
import Testing
@testable import XRGCore

@MainActor private final class GenericCallbackFixture: XRGGenericView {
    var calls: [String] = []
    override func setGraphSize(_ size: NSSize) { calls.append("size") }
    override func updateMinSize() { calls.append("minimum") }
    override func graphUpdate(_ timer: Timer?) { calls.append("graph") }
    override func fastUpdate(_ timer: Timer?) { calls.append("fast") }
    override func min5Update(_ timer: Timer?) { calls.append("five") }
    override func min30Update(_ timer: Timer?) { calls.append("thirty") }
}

@Suite(.serialized) @MainActor
struct XRGGenericViewLifecycleTests {
    private func fixture(_ body: (UserDefaults) throws -> Void) throws {
        _ = NSApplication.shared
        let domain = "XRG.genericLifecycle.\(UUID().uuidString)", defaults = try #require(UserDefaults(suiteName: domain))
        defaults.set(false, forKey: "checkForUpdates"); defaults.set(true, forKey: "isDockIconHidden")
        defer { defaults.removePersistentDomain(forName: domain) }
        try body(defaults)
    }
    @Test func attachesToTheCurrentHostAndClearsReferencesOnOrdinaryWindowsAndDetachment() throws {
        try fixture { defaults in
            let first = XRGGraphWindow(contentRect: NSRect(x: 0, y: 0, width: 300, height: 400), defaults: defaults)
            let second = XRGGraphWindow(contentRect: NSRect(x: 0, y: 0, width: 300, height: 400), defaults: defaults)
            let ordinary = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 300, height: 400), styleMask: .borderless, backing: .buffered, defer: false)
            ordinary.isReleasedWhenClosed = false
            defer { first.cleanupBeforeExiting(); second.cleanupBeforeExiting(); first.close(); second.close(); ordinary.close() }
            let view = XRGGenericView(frame: .zero)
            first.contentView = view; view.awakeFromNib(); view.awakeFromNib()
            #expect(view.parentWindow === first && view.appSettings === first.appSettings && view.moduleManager === first.moduleManager)
            #expect(view.subviews.count == 3)
            second.contentView = view
            #expect(view.parentWindow === second && view.appSettings === second.appSettings && view.moduleManager === second.moduleManager)
            ordinary.contentView = view
            #expect(view.parentWindow == nil && view.appSettings == nil && view.moduleManager == nil)
            second.contentView = view; view.removeFromSuperview()
            #expect(view.parentWindow == nil && view.appSettings == nil && view.moduleManager == nil)
        }
    }
    @Test func managerReferenceDoesNotKeepAModuleViewOwnershipCycleAlive() throws {
        try fixture { _ in
            let view = XRGGenericView(frame: .zero)
            weak var released: XRGModuleManager?
            autoreleasepool {
                let manager = XRGModuleManager(); released = manager; view.moduleManager = manager
            }
            #expect(released == nil && view.moduleManager == nil)
        }
    }
    @Test func swiftSubclassesReceiveAllModuleProtocolCallbacks() throws {
        try fixture { _ in
            let view = GenericCallbackFixture(frame: .zero), target: any XRGModuleView = view
            target.setGraphSize(NSSize(width: 30, height: 50)); target.updateMinSize()
            target.graphUpdate(nil); target.fastUpdate(nil); target.min5Update(nil); target.min30Update(nil)
            #expect(view.calls == ["size", "minimum", "graph", "fast", "five", "thirty"])
        }
    }
    @Test func archivedRuntimeNameDecodesAndRepeatedAwakeningCreatesOnlyOneLabelSet() throws {
        try fixture { _ in
            let original = XRGGenericView(frame: NSRect(x: 0, y: 0, width: 170, height: 40))
            let data = try NSKeyedArchiver.archivedData(withRootObject: original, requiringSecureCoding: false)
            let reader = try NSKeyedUnarchiver(forReadingFrom: data); reader.requiresSecureCoding = false
            let decoded = try #require(reader.decodeObject(forKey: NSKeyedArchiveRootObjectKey) as? XRGGenericView); reader.finishDecoding()
            decoded.awakeFromNib(); decoded.awakeFromNib()
            #expect(decoded.frame.size == original.frame.size && decoded.subviews.count == 3)
            #expect(NSClassFromString("XRGGenericView") === XRGGenericView.self)
            decoded.drawLeftText("CPU", centerText: nil, rightText: "12%", in: decoded.paddedTextRect)
            #expect(decoded.leftLabel?.accessibilityValue() == "CPU")
        }
    }
}
