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

@MainActor private final class BackgroundHost: NSWindow, XRGBackgroundViewHost {
    var appSettings: XRGSettings?
    var moduleManager: XRGModuleManager?
    var minimized = false
    var borderWidth: Int32 = 2
    var backgroundView: XRGBackgroundView? {
        didSet {
            backgroundView?.setFrameSize(frame.size)
            backgroundView?.autoresizingMask = [.width, .height]
        }
    }
    var preferencesOpened = 0
    var themesApplied = 0
    var frameChanges: [NSRect] = []
    var mouseEvents: [String] = []
    init(settings: XRGSettings) {
        appSettings = settings
        super.init(contentRect: NSRect(x: 100, y: 200, width: 300, height: 400), styleMask: .borderless, backing: .buffered, defer: false)
        isReleasedWhenClosed = false
        moduleManager = XRGModuleManager(window: self)
    }
    func checkWindowSize() {}
    func showGeneralPreferences() { preferencesOpened += 1 }
    func backgroundThemeDidApply() { themesApplied += 1 }
    override func setFrame(_ rect: NSRect, display: Bool, animate: Bool) {
        frameChanges.append(rect)
        super.setFrame(rect, display: false, animate: false)
        backgroundView?.setFrameSize(frame.size)
    }
    override func mouseDragged(with event: NSEvent) { mouseEvents.append("drag") }
    override func mouseUp(with event: NSEvent) { mouseEvents.append("up") }
}

@MainActor private final class BackgroundFixture {
    let domain = "XRG.background.\(UUID().uuidString)"
    let defaults: UserDefaults
    let settings: XRGSettings
    let host: BackgroundHost
    let view: XRGBackgroundView
    let module: XRGModule
    var actions: [XRGBackgroundAction] = []
    init(vertical: Bool = true, direction: Int = 0, readTheme: @escaping (URL) throws -> Data = { try Data(contentsOf: $0) }) throws {
        _ = NSApplication.shared
        defaults = try #require(UserDefaults(suiteName: domain))
        defaults.set(true, forKey: "isDockIconHidden")
        settings = XRGSettings(defaults: defaults)
        settings.graphFont = NSFont.systemFont(ofSize: 10)
        settings.textRectHeight = 14; settings.minimizeUpDown = direction
        settings.borderTransparency = 1; settings.borderColor = .blue
        settings.backgroundTransparency = 1; settings.backgroundColor = .white
        settings.textTransparency = 1; settings.textColor = .black
        settings.windowTitle = "Window fixture"
        host = BackgroundHost(settings: settings)
        host.moduleManager?.graphOrientationVertical = vertical
        let panel = NSView(frame: .zero)
        module = XRGModule(name: "Fixture", reference: panel, defaults: defaults)
        module.minWidth = 80; module.minHeight = 40; module.displayOrder = 0
        host.contentView?.addSubview(panel); host.moduleManager?.addModule(module)
        var sink: ((XRGBackgroundAction) -> Void)?
        view = XRGBackgroundView(frame: NSRect(origin: .zero, size: host.frame.size), defaults: defaults,
                                 readTheme: readTheme, action: { sink?($0) })
        sink = { [weak self] in self?.actions.append($0) }
        host.contentView?.addSubview(view, positioned: .below, relativeTo: panel)
        view.awakeFromNib()
    }
    func cleanUp() { view.removeFromSuperview(); host.close(); defaults.removePersistentDomain(forName: domain) }
    func event(at point: NSPoint, clicks: Int = 2) throws -> NSEvent {
        try #require(NSEvent.mouseEvent(with: .leftMouseDown, location: point, modifierFlags: [], timestamp: 0,
                                        windowNumber: host.windowNumber, context: nil, eventNumber: 0, clickCount: clicks, pressure: 1))
    }
    func headerEvent() throws -> NSEvent {
        let rect = view.titleRect(in: view.bounds, vertical: host.moduleManager!.graphOrientationVertical)
        return try event(at: view.convert(NSPoint(x: rect.midX, y: rect.midY), to: nil))
    }
}
private final class BackgroundNibOwner: NSObject {}
private actor BackgroundLookup {
    var continuations: [CheckedContinuation<String, Never>] = []
    func lookup() async -> String { await withCheckedContinuation { continuations.append($0) } }
    func count() -> Int { continuations.count }
    func resolve(_ index: Int, _ value: String) { continuations[index].resume(returning: value) }
}

@Suite(.serialized) @MainActor
struct XRGBackgroundViewTests {
    private func bitmap(_ view: XRGBackgroundView) throws -> NSBitmapImageRep {
        let bitmap = try #require(NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: Int(view.bounds.width), pixelsHigh: Int(view.bounds.height),
                                                   bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0))
        let context = try #require(NSGraphicsContext(bitmapImageRep: bitmap))
        NSGraphicsContext.saveGraphicsState(); defer { NSGraphicsContext.restoreGraphicsState() }
        NSGraphicsContext.current = context
        NSColor.clear.set(); view.bounds.fill(using: .copy); view.draw(view.bounds)
        return bitmap
    }
    private func privatePasteboard(_ urls: [URL]) -> NSPasteboard {
        let board = NSPasteboard(name: .init("XRG.theme.\(UUID().uuidString)"))
        board.clearContents()
        let items = urls.map { url in
            let item = NSPasteboardItem(); item.setString(url.absoluteString, forType: .fileURL); return item
        }
        board.writeObjects(items); return board
    }
    private func themeData(secure: Bool = true, invalid: Bool = false) throws -> Data {
        let archive = try NSKeyedArchiver.archivedData(withRootObject: NSColor.red, requiringSecureCoding: secure)
        var theme: [String: Any] = [:]
        for key in ["background", "graphBG", "graphFG1", "graphFG2", "graphFG3", "border", "text"] {
            theme[key + "Color"] = archive; theme[key + "Transparency"] = 0.5
        }
        if invalid { theme["textColor"] = Data([0, 1, 2]) }
        return try PropertyListSerialization.data(fromPropertyList: theme, format: .xml, options: 0)
    }

    @Test(arguments: [true, false], [0, 1])
    func minimizesAndRestoresEveryAnchor(vertical: Bool, direction: Int) throws {
        let f = try BackgroundFixture(vertical: vertical, direction: direction); defer { f.cleanUp() }
        let original = f.host.frame
        f.view.minimizeWindow()
        let collapsed = f.host.frame
        #expect(f.host.minimized && f.module.reference?.isHidden == true)
        #expect(f.defaults.bool(forKey: "windowIsMinimized"))
        #expect(NSRectFromString(f.defaults.string(forKey: "unminimizedFrame")!) == original)
        if vertical {
            #expect(collapsed.height == 18 && collapsed.width == original.width)
            #expect(direction == 0 ? collapsed.maxY == original.maxY : collapsed.minY == original.minY)
        } else {
            #expect(collapsed.width == 18 && collapsed.height == original.height)
            #expect(direction == 0 ? collapsed.minX == original.minX : collapsed.maxX == original.maxX)
        }
        let calls = f.host.frameChanges.count
        f.view.minimizeWindow(); #expect(f.host.frameChanges.count == calls)
        f.view.expandWindow()
        #expect(f.host.frame == original && !f.host.minimized && f.module.reference?.isHidden == false)
        #expect(!f.defaults.bool(forKey: "windowIsMinimized"))
        f.view.expandWindow(); #expect(f.host.frameChanges.count == calls + 1)
    }

    @Test(arguments: [true, false], [false, true])
    func collapsedStartupRepairsBothAxesAndUsesHistory(vertical: Bool, saved: Bool) throws {
        let f = try BackgroundFixture(vertical: vertical); defer { f.cleanUp() }
        if saved { f.defaults.set("{{5, 6}, {984, 712}}", forKey: "unminimizedFrame") }
        f.host.minSize = .zero
        f.host.setFrame(NSRect(x: 100, y: 200, width: 18, height: 18), display: false, animate: false)
        f.view.minimizeWindow(); f.view.expandWindow()
        #expect(f.host.frame.width == (saved ? 984 : 600))
        #expect(f.host.frame.height == (saved ? 712 : 600))
        #expect(f.host.frame.maxY == (vertical ? 218 : 200 + f.host.frame.height))
    }

    @Test(arguments: [true, false])
    func moduleMinimumStartupTrapAndSmallUserWindows(vertical: Bool) throws {
        let f = try BackgroundFixture(vertical: vertical); defer { f.cleanUp() }
        f.module.minHeight = 87; f.module.minWidth = 789
        let minimum = f.host.moduleManager!.getMinSize()
        f.host.setFrame(NSRect(origin: NSPoint(x: 100, y: 200), size: minimum), display: false, animate: false)
        f.view.minimizeWindow()
        #expect(f.view.unminimizedRect.height == 600)
        #expect(f.view.unminimizedRect.width == max(600, minimum.width))
        f.view.expandWindow()
        // Only an actually collapsed cross axis is replaced; a usable 91px height stays put.
        #expect(f.host.frame.height == (vertical ? 600 : 91))
        #expect(f.host.frame.width == max(600, minimum.width))
        // A deliberately chosen 200px window remains small when the module minimum allows it.
        f.module.minHeight = 40; f.module.minWidth = 80; f.host.minSize = .zero
        f.host.setFrame(NSRect(x: 100, y: 200, width: 200, height: 200), display: false, animate: false)
        f.view.minimizeWindow(); f.view.expandWindow()
        #expect(f.host.frame.size == NSSize(width: 200, height: 200))
    }

    @Test(arguments: [true, false], [0, 1])
    func orientationSwitchWhileLatchedRemainsRestorable(vertical: Bool, direction: Int) throws {
        let f = try BackgroundFixture(vertical: vertical, direction: direction); defer { f.cleanUp() }
        let original = f.host.frame
        f.view.minimizeWindow(); f.view.expandWindow()
        f.host.moduleManager?.graphOrientationVertical.toggle()
        var rotated = original
        rotated.origin.y += original.height - original.width
        rotated.size = NSSize(width: original.height, height: original.width)
        f.host.minSize = f.host.moduleManager!.getMinSize()
        f.host.setFrame(rotated, display: false, animate: false)
        f.view.minimizeWindow(); f.view.expandWindow()
        #expect(f.host.frame == rotated)
        #expect(!f.host.minimized && f.module.reference?.isHidden == false)
    }

    @Test func squareWindowOrientationChangeExplicitlyUpdatesThePanelLayout() throws {
        let f = try BackgroundFixture(); defer { f.cleanUp() }
        f.host.setFrame(NSRect(x: 100, y: 200, width: 300, height: 300), display: false, animate: false)
        #expect(f.module.currentSize == NSSize(width: 296, height: 280))
        f.host.moduleManager?.graphOrientationVertical = false
        f.view.updateModuleLayout()
        #expect(f.module.currentSize == NSSize(width: 280, height: 296))
        #expect(f.module.reference?.frame.origin == NSPoint(x: 18, y: 2))
        f.view.updateModuleLayout()
        #expect(f.host.frame == NSRect(x: 100, y: 200, width: 300, height: 300))
        f.host.moduleManager?.graphOrientationVertical = true; f.view.updateModuleLayout()
        #expect(f.module.currentSize == NSSize(width: 296, height: 280))
        #expect(f.module.reference?.frame.origin == NSPoint(x: 2, y: 2))
    }

    @Test func invalidHistoryCannotPoisonRecovery() {
        let current = NSRect(x: 2, y: 3, width: 18, height: 18)
        let bad = NSRect(x: 0, y: 0, width: .nan, height: -.infinity)
        let repaired = XRGBackgroundGeometry.repairedRestore(current: current, saved: bad, minimum: NSSize(width: 84, height: 100), strip: 18)
        #expect(repaired == NSRect(x: 2, y: 3, width: 600, height: 600))
        let repairedOrigin = XRGBackgroundGeometry.repairedRestore(current: NSRect(x: CGFloat.nan, y: CGFloat.infinity, width: CGFloat.nan, height: CGFloat.infinity), saved: nil, minimum: .zero, strip: 18)
        #expect(repairedOrigin == NSRect(x: 0, y: 0, width: 600, height: 600))
    }

    @Test(arguments: [true, false])
    func doubleClickAndHoverPreserveTheLatch(vertical: Bool) throws {
        let f = try BackgroundFixture(vertical: vertical); defer { f.cleanUp() }
        f.settings.autoExpandGraph = true
        let original = f.host.frame
        f.view.mouseDownAction(try f.event(at: NSPoint(x: 100, y: 100)))
        #expect(!f.host.minimized)
        f.view.mouseDownAction(try f.headerEvent())
        #expect(f.host.minimized && f.view.clickedMinimized)
        f.view.mouseEntered(with: try f.headerEvent())
        #expect(!f.host.minimized && f.view.clickedMinimized && f.host.frame == original)
        f.view.mouseExited(with: try f.headerEvent())
        #expect(f.host.minimized && f.view.clickedMinimized)
        f.view.mouseDownAction(try f.headerEvent())
        #expect(!f.host.minimized && !f.view.clickedMinimized)
        f.view.mouseExited(with: try f.headerEvent()); #expect(!f.host.minimized)
        f.view.mouseDownAction(try f.headerEvent())
        f.view.mouseEntered(with: try f.headerEvent())
        f.view.mouseDownAction(try f.headerEvent())
        #expect(!f.view.clickedMinimized && !f.host.minimized)
        f.settings.autoExpandGraph = false
        f.view.clickedMinimized = true; f.view.minimizeWindow()
        f.view.mouseEntered(with: try f.headerEvent()); #expect(f.host.minimized)
    }

    @Test(arguments: [0, 1, 2])
    func levelsAndDesktopOrderingUseTheSettingsIndex(level: Int) throws {
        let f = try BackgroundFixture(); defer { f.cleanUp() }
        f.settings.windowLevel = level; f.settings.foregroundWhenExpanding = true; f.settings.autoExpandGraph = true
        f.view.minimizeWindow()
        let expected: NSWindow.Level = level == 0 ? .normal : level == 1 ? .floating : .init(rawValue: Int(CGWindowLevelForKey(.desktopWindow)))
        #expect(f.host.level == expected)
        f.view.expandWindow(); #expect(f.host.level == .floating)
        f.view.mouseDownAction(try f.event(at: .zero, clicks: 1))
        #expect(f.actions.contains(.preventOrdering) == (level == 2))
        #expect(f.view.shouldDelayWindowOrdering(for: try f.headerEvent()) && f.view.acceptsFirstMouse(for: nil))
        f.view.mouseDragged(with: try f.headerEvent()); f.view.mouseUp(with: try f.headerEvent())
        #expect(f.host.mouseEvents == ["drag", "up"])
    }

    @Test func bindingTrackingAndMenusHaveExplicitTargetsAndInjectedSystemActions() throws {
        let f = try BackgroundFixture(); defer { f.cleanUp() }
        f.view.awakeFromNib(); f.view.awakeFromNib()
        #expect(f.host.backgroundView === f.view && f.actions.isEmpty)
        f.view.updateTrackingAreas(); f.view.updateTrackingAreas()
        #expect(f.view.trackingAreas.count == 1 && f.view.trackingArea?.options.contains(.inVisibleRect) == true)
        for item in f.view.makeMenu().items where !item.isSeparatorItem {
            #expect(item.target === f.view)
            let selector = try #require(item.action)
            #expect(NSApp.sendAction(selector, to: item.target, from: item))
        }
        #expect(f.actions == [.about, .help, .showDock, .quit])
        #expect(f.host.preferencesOpened == 1 && !f.view.uiIsHidden && !f.defaults.bool(forKey: "isDockIconHidden"))
        let hide = try #require(f.view.makeMenu().items.first { $0.title.hasPrefix("Hide XRG-ng") })
        let selector = try #require(hide.action)
        #expect(NSApp.sendAction(selector, to: hide.target, from: hide))
        #expect(f.view.uiIsHidden && f.defaults.bool(forKey: "isDockIconHidden") && f.actions.last == .hideDockNotice)
        f.view.removeFromSuperview(); #expect(f.host.backgroundView == nil)
        let count = f.host.frameChanges.count
        f.view.minimizeWindow(); #expect(f.host.frameChanges.count == count)
    }

    @Test func dockSetupRunsOnceAndDetachmentCancelsHostnameWork() async throws {
        let f = try BackgroundFixture(); defer { f.cleanUp() }
        f.view.removeFromSuperview()
        f.defaults.set(false, forKey: "isDockIconHidden")
        let lookup = BackgroundLookup()
        var actions: [XRGBackgroundAction] = []
        let view = XRGBackgroundView(frame: NSRect(origin: .zero, size: f.host.frame.size), defaults: f.defaults,
                                     hostnameLookup: { await lookup.lookup() }, action: { actions.append($0) })
        f.host.contentView?.addSubview(view); view.awakeFromNib(); view.awakeFromNib()
        #expect(actions == [.showDock] && f.host.backgroundView === view)
        for _ in 0..<100 where await lookup.count() < 1 { try await Task.sleep(for: .milliseconds(1)) }
        try #require(await lookup.count() == 1)
        view.removeFromSuperview()
        #expect(f.host.backgroundView == nil)
        await lookup.resolve(0, "detached.local")
        for _ in 0..<5 { await Task.yield() }
        #expect(view.hostname == "XRG-ng")
    }

    @Test func drawingBothOrientationsDoesNotResizeOrRotateTheViewAndKeepsPanelHoles() throws {
        let f = try BackgroundFixture(); defer { f.cleanUp() }
        let frame = f.view.frame, bounds = f.view.bounds, moduleSize = f.module.currentSize
        let vertical = try bitmap(f.view)
        #expect(vertical.colorAt(x: 100, y: 100)?.alphaComponent == 0)
        #expect(vertical.colorAt(x: 0, y: 100)?.blueComponent == 1)
        let bytes = try #require(vertical.representation(using: .png, properties: [:]))
        f.host.moduleManager?.graphOrientationVertical = false
        let horizontal = try bitmap(f.view)
        #expect(horizontal.colorAt(x: 8, y: 100)?.alphaComponent == 1)
        #expect(f.view.frame == frame && f.view.bounds == bounds && f.view.boundsRotation == 0)
        #expect(f.module.currentSize == moduleSize)
        f.host.moduleManager?.graphOrientationVertical = true
        let roundTrip = try bitmap(f.view).representation(using: .png, properties: [:])
        #expect(roundTrip == bytes)
        #expect(f.view.accessibilityLabel() == "Window fixture")
        f.settings.windowTitle = ""; f.view.hostname = "Fixture"
        #expect(f.view.displayTitle == "Fixture" && f.view.accessibilityLabel() == "Fixture")
    }

    @Test(arguments: ["BackgroundView", "LegacyBackground"])
    func decodesCurrentAndLegacyNibWithoutAHost(name: String) throws {
        _ = NSApplication.shared
        let nib = try #require(NSNib(nibNamed: name, bundle: Bundle(for: BackgroundNibOwner.self)))
        var objects: NSArray?
        #expect(nib.instantiate(withOwner: BackgroundNibOwner(), topLevelObjects: &objects))
        let view = try #require(objects?.compactMap { $0 as? XRGBackgroundView }.first)
        #expect(view.frame.size == NSSize(width: 84, height: 710))
        #expect(view.hostname == "XRG-ng" && !view.clickedMinimized && view.boundsRotation == 0)
        #expect(view.registeredDraggedTypes.contains(.fileURL))
        view.minimizeWindow(); view.expandWindow()
    }

    @Test(arguments: [true, false])
    func themeDropsReadPrivateFilesAndCommitOnlyCompleteThemes(secure: Bool) throws {
        let data = try themeData(secure: secure)
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("XRG-\(UUID().uuidString).xtf")
        try data.write(to: url); defer { try? FileManager.default.removeItem(at: url) }
        let f = try BackgroundFixture(); defer { f.cleanUp() }
        let board = privatePasteboard([url]); defer { board.releaseGlobally() }
        #expect(f.view.performThemeDrop(from: board, operation: .copy))
        #expect(f.host.themesApplied == 1 && f.actions.isEmpty)
        #expect(f.settings.textTransparency == 0.5 && f.settings.backgroundColor.alphaComponent == 0.5)
        #expect(f.defaults.data(forKey: "textColor") != nil && f.defaults.double(forKey: "borderTransparency") == 0.5)
    }

    @Test(arguments: ["empty", "badPlist", "wrongRoot", "lastColor", "readFailure"])
    func invalidThemeDropsAreAtomic(failure: String) throws {
        let data: Data
        switch failure {
        case "empty": data = Data()
        case "badPlist": data = Data("broken".utf8)
        case "wrongRoot": data = try PropertyListSerialization.data(fromPropertyList: ["wrong"], format: .xml, options: 0)
        default: data = try themeData(invalid: true)
        }
        let f = try BackgroundFixture(readTheme: { _ in
            if failure == "readFailure" { throw CocoaError(.fileReadNoPermission) }
            return data
        }); defer { f.cleanUp() }
        let original = f.defaults.persistentDomain(forName: f.domain) ?? [:]
        let board = privatePasteboard([URL(fileURLWithPath: "/fixture.xtf")]); defer { board.releaseGlobally() }
        #expect(!f.view.performThemeDrop(from: board, operation: .copy))
        #expect(f.host.themesApplied == 0 && f.actions == [.invalidTheme])
        #expect(f.settings.backgroundColor == NSColor.white && f.settings.textColor == NSColor.black)
        #expect(NSDictionary(dictionary: f.defaults.persistentDomain(forName: f.domain) ?? [:]).isEqual(to: original))
    }

    @Test(arguments: ["multiple", "wrongExtension", "upperExtension", "web", "move", "empty"])
    func rejectedDragPayloadNeverReadsAFile(failure: String) throws {
        var reads = 0
        let f = try BackgroundFixture(readTheme: { _ in reads += 1; return Data() }); defer { f.cleanUp() }
        var urls = [URL(fileURLWithPath: "/fixture.xtf")]
        switch failure {
        case "multiple": urls.append(URL(fileURLWithPath: "/second.xtf"))
        case "wrongExtension": urls = [URL(fileURLWithPath: "/fixture.txt")]
        case "upperExtension": urls = [URL(fileURLWithPath: "/fixture.XTF")]
        case "web": urls = [URL(string: "https://example.com/theme.xtf")!]
        case "empty": urls = []
        default: break
        }
        let board = privatePasteboard(urls); defer { board.releaseGlobally() }
        #expect(!f.view.performThemeDrop(from: board, operation: failure == "move" ? .move : .copy))
        #expect(reads == 0 && f.actions.isEmpty && f.host.themesApplied == 0)
    }

    @Test(arguments: [("machine.example.local", "machine"), ("localhost", "localhost"), ("", "XRG-ng"), (".local", "XRG-ng"), ("  machine.local\n", "machine")])
    func hostnameNormalization(pair: (String, String)) { #expect(XRGBackgroundView.shortHostname(pair.0) == pair.1) }

    @Test func hostnameResultsRespectCancellationAndDoNotRetainTheView() async throws {
        let lookup = BackgroundLookup()
        let f = try BackgroundFixture(); defer { f.cleanUp() }
        var view: XRGBackgroundView? = XRGBackgroundView(frame: .zero, defaults: f.defaults, hostnameLookup: { await lookup.lookup() })
        view?.getHostname()
        for _ in 0..<100 where await lookup.count() < 1 { try await Task.sleep(for: .milliseconds(1)) }
        try #require(await lookup.count() == 1)
        view?.getHostname()
        for _ in 0..<100 where await lookup.count() < 2 { try await Task.sleep(for: .milliseconds(1)) }
        try #require(await lookup.count() == 2)
        await lookup.resolve(1, "new.local")
        for _ in 0..<100 where view?.hostname != "new" { try await Task.sleep(for: .milliseconds(1)) }
        #expect(view?.hostname == "new")
        await lookup.resolve(0, "old.local"); await Task.yield()
        #expect(view?.hostname == "new")
        view?.getHostname()
        for _ in 0..<100 where await lookup.count() < 3 { try await Task.sleep(for: .milliseconds(1)) }
        try #require(await lookup.count() == 3)
        weak let weakView = view
        view = nil; #expect(weakView == nil)
        await lookup.resolve(2, "late.local")
    }
}
