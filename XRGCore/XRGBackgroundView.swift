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

@MainActor @objc public protocol XRGBackgroundViewHost: XRGModuleWindow {
    var moduleManager: XRGModuleManager? { get }
    var backgroundView: XRGBackgroundView? { get set }
    var minimized: Bool { get set }
    var level: NSWindow.Level { get set }
    func showGeneralPreferences()
    func backgroundThemeDidApply()
}

enum XRGBackgroundAction { case about, help, quit, showDock, hideDockNotice, invalidTheme, preventOrdering }

/// Keep both-axis startup repair and the original top/bottom/left/right anchors.
enum XRGBackgroundGeometry {
    static func dimension(_ value: CGFloat) -> CGFloat { value.isFinite ? max(0, value) : 0 }
    static func repairedRestore(current: NSRect, saved: NSRect?, minimum: NSSize, strip: CGFloat) -> NSRect {
        var result = current
        if !result.origin.x.isFinite { result.origin.x = 0 }
        if !result.origin.y.isFinite { result.origin.y = 0 }
        let trapHeight = max(strip + 1, dimension(minimum.height)), trapWidth = max(strip + 1, dimension(minimum.width))
        if !result.size.height.isFinite || result.size.height <= trapHeight {
            let history = saved.map { dimension($0.size.height) } ?? 0
            result.size.height = history > trapHeight ? history : max(600, trapHeight)
        }
        if !result.size.width.isFinite || result.size.width <= trapWidth {
            let history = saved.map { dimension($0.size.width) } ?? 0
            result.size.width = history > trapWidth ? history : max(600, trapWidth)
        }
        return result
    }
    static func collapsed(_ frame: NSRect, vertical: Bool, direction: Int, strip: CGFloat) -> NSRect {
        var result = frame
        if vertical {
            if direction == 0 { result.origin.y += result.height - strip }
            result.size.height = strip
        } else {
            if direction != 0 { result.origin.x += result.width - strip }
            result.size.width = strip
        }
        return result
    }
    static func expanded(_ frame: NSRect, restore: NSRect, vertical: Bool, direction: Int, strip: CGFloat) -> NSRect {
        var result = frame
        if vertical {
            if direction == 0 { result.origin.y -= restore.height - result.height }
            result.size.height = restore.height
            if result.width <= strip + 1 && restore.width > strip + 1 { result.size.width = restore.width }
        } else {
            if direction != 0 { result.origin.x -= restore.width - result.width }
            result.size.width = restore.width
            if result.height <= strip + 1 && restore.height > strip + 1 { result.size.height = restore.height }
        }
        return result
    }
}

@MainActor
@objc(XRGBackgroundView) @objcMembers
public final class XRGBackgroundView: NSView {
    private let defaults: UserDefaults
    private let action: (XRGBackgroundAction) -> Void
    private let hostnameLookup: @Sendable () async -> String
    private let readTheme: (URL) throws -> Data
    private let animateResizing: Bool
    private var hostnameTask: Task<Void, Never>?
    private weak var host: (any XRGBackgroundViewHost)?
    private var didAwake = false
    private var binding = false
    private var configured = false
    private var lastLayoutSize: NSSize?
    private var lastLayoutVertical: Bool?
    @nonobjc private(set) var unminimizedRect = NSRect.zero
    @nonobjc private(set) var uiIsHidden = false
    public var hostname = "XRG-ng" { didSet { needsDisplay = true; updateAccessibility() } }
    public var clickedMinimized = false
    public private(set) var trackingArea: NSTrackingArea?
    private var settings: XRGSettings? { host?.appSettings }
    private var manager: XRGModuleManager? { host?.moduleManager }
    private var vertical: Bool { manager?.graphOrientationVertical ?? true }
    private var border: CGFloat { max(0, CGFloat(host?.borderWidth ?? 0)) }
    private var lineHeight: CGFloat { XRGGraphLabels.lineHeight(settings) }
    private var strip: CGFloat { border * 2 + lineHeight }

    public override init(frame frameRect: NSRect) {
        defaults = .standard; action = Self.systemAction; readTheme = { try Data(contentsOf: $0) }; animateResizing = true
        hostnameLookup = { await Task.detached { ProcessInfo.processInfo.hostName }.value }
        super.init(frame: frameRect); prepare()
    }
    public required init?(coder: NSCoder) {
        defaults = .standard; action = Self.systemAction; readTheme = { try Data(contentsOf: $0) }; animateResizing = true
        hostnameLookup = { await Task.detached { ProcessInfo.processInfo.hostName }.value }
        super.init(coder: coder); prepare()
    }
    @nonobjc init(frame: NSRect, defaults: UserDefaults, animateResizing: Bool = false,
                  hostnameLookup: @escaping @Sendable () async -> String = { "Fixture.local" },
                  readTheme: @escaping (URL) throws -> Data = { try Data(contentsOf: $0) },
                  action: @escaping (XRGBackgroundAction) -> Void = { _ in }) {
        self.defaults = defaults; self.action = action; self.hostnameLookup = hostnameLookup
        self.readTheme = readTheme; self.animateResizing = animateResizing
        super.init(frame: frame); prepare()
    }
    private func prepare() {
        uiIsHidden = defaults.bool(forKey: "isDockIconHidden")
        registerForDraggedTypes([.fileURL]); updateAccessibility()
    }
    public nonisolated override func awakeFromNib() {
        super.awakeFromNib()
        MainActor.assumeIsolated { didAwake = true; bindToWindow() }
    }
    public override func viewDidMoveToWindow() { super.viewDidMoveToWindow(); bindToWindow() }
    private func bindToWindow() {
        guard !binding else { return }
        binding = true; defer { binding = false }
        let next = window as? any XRGBackgroundViewHost
        if host !== next {
            hostnameTask?.cancel()
            if host?.backgroundView === self { host?.backgroundView = nil }
            host = next; configured = false; lastLayoutSize = nil; lastLayoutVertical = nil
        }
        guard didAwake, let host, settings != nil, manager != nil else { updateAccessibility(); return }
        if host.backgroundView !== self { host.backgroundView = self }
        updateModuleLayout()
        if !configured {
            configured = true; getHostname()
            if !uiIsHidden { showUI(nil) }
        }
        updateAccessibility()
    }
    public func updateModuleLayout() {
        guard let manager, frame.size.width.isFinite, frame.size.height.isFinite,
              lastLayoutSize != frame.size || lastLayoutVertical != vertical else { return }
        lastLayoutSize = frame.size; lastLayoutVertical = vertical
        manager.windowChanged(to: frame.size)
    }
    public override var frame: NSRect { didSet { updateModuleLayout() } }
    public override func setFrameSize(_ newSize: NSSize) {
        super.setFrameSize(newSize)
        if didAwake && !configured { bindToWindow() }
        updateModuleLayout(); updateAccessibility()
    }
    public func offsetDrawingOrigin(_ offset: NSSize) {
        guard offset.width.isFinite, offset.height.isFinite else { return }
        translateOrigin(to: NSPoint(x: offset.width, y: offset.height)); needsDisplay = true
    }
    @nonobjc func titleRect(in rect: NSRect, vertical: Bool) -> NSRect {
        guard XRGGraphRenderer.validRect(rect) else { return .zero }
        let width = max(0, rect.width - border * 2), height = max(0, rect.height - border * 2)
        if vertical { return NSRect(x: rect.minX + min(border, rect.width), y: rect.maxY - min(rect.height, border + lineHeight), width: width, height: min(lineHeight, height)) }
        return NSRect(x: rect.minX + min(border, rect.width), y: rect.minY + min(border, rect.height), width: min(lineHeight, width), height: height)
    }
    @nonobjc var displayTitle: String { settings?.windowTitle.isEmpty == false ? settings!.windowTitle : hostname }
    private func updateAccessibility() {
        setAccessibilityElement(true); setAccessibilityRole(.group); setAccessibilityLabel(displayTitle)
    }
    public override func draw(_ dirtyRect: NSRect) {
        guard let settings, let context = NSGraphicsContext.current, XRGGraphRenderer.validRect(bounds) else { return }
        NSGraphicsContext.saveGraphicsState(); defer { NSGraphicsContext.restoreGraphicsState() }
        let path = NSBezierPath(roundedRect: bounds, xRadius: border, yRadius: border)
        path.windingRule = .evenOdd
        for module in manager?.displayList() ?? [] {
            guard let view = module.reference, !view.isHidden, view.window === window else { continue }
            let hole = convert(view.bounds, from: view).intersection(bounds)
            if !hole.isNull && !hole.isEmpty { path.appendRect(hole) }
        }
        settings.borderColor.set(); path.fill()
        context.shouldAntialias = true
        // Rotate only the title's drawing context; never mutate view/window geometry from draw.
        let title: NSRect
        if vertical { title = titleRect(in: bounds, vertical: true) }
        else {
            context.cgContext.translateBy(x: bounds.maxX, y: bounds.minY)
            context.cgContext.rotate(by: .pi / 2)
            let logical = NSRect(x: 0, y: 0, width: bounds.height, height: bounds.width)
            title = titleRect(in: logical, vertical: true)
        }
        settings.backgroundColor.set()
        NSBezierPath(roundedRect: title, xRadius: border, yRadius: border).fill()
        title.fill(using: .copy)
        var attributes: [NSAttributedString.Key: Any] = [:]
        for (key, value) in settings.alignCenterAttributes { if let key = key as? String { attributes[NSAttributedString.Key(key)] = value } }
        (displayTitle as NSString).draw(in: title, withAttributes: attributes)
        updateAccessibility()
    }
    @nonobjc static func shortHostname(_ value: String) -> String {
        let name = value.trimmingCharacters(in: .whitespacesAndNewlines).components(separatedBy: ".").first ?? ""
        return name.isEmpty ? "XRG-ng" : name
    }
    public func getHostname() {
        hostnameTask?.cancel()
        let lookup = hostnameLookup
        hostnameTask = Task { [weak self] in
            let name = await lookup()
            guard !Task.isCancelled else { return }
            self?.hostname = Self.shortHostname(name)
        }
    }
    public override func shouldDelayWindowOrdering(for event: NSEvent) -> Bool { true }
    public override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
    public func acceptsMouseMovedEvents() -> Bool { true }
    public func mouseDownAction(_ event: NSEvent) {
        guard let host, let settings else { return }
        if settings.windowLevel >= 2 { action(.preventOrdering) }
        let originalLevel = host.level
        let point = convert(event.locationInWindow, from: nil)
        guard event.clickCount == 2, titleRect(in: bounds, vertical: vertical).contains(point) else { return }
        if host.minimized { clickedMinimized = false; expandWindow() }
        else if !clickedMinimized { clickedMinimized = true; minimizeWindow() }
        else { clickedMinimized = false; host.level = originalLevel }
    }
    public override func mouseDragged(with event: NSEvent) { window?.mouseDragged(with: event) }
    public override func mouseUp(with event: NSEvent) { window?.mouseUp(with: event) }
    private var savedFrame: NSRect? { defaults.string(forKey: "unminimizedFrame").map(NSRectFromString) }
    public func minimizeWindow() {
        guard let host, let manager, let settings, !host.minimized else { return }
        let frame = host.frame
        unminimizedRect = XRGBackgroundGeometry.repairedRestore(current: frame, saved: savedFrame, minimum: manager.getMinSize(), strip: strip)
        let collapsed = XRGBackgroundGeometry.collapsed(frame, vertical: vertical, direction: settings.minimizeUpDown, strip: strip)
        host.minimized = true; host.minSize = manager.getMinSize()
        for module in manager.displayList() { module.reference?.isHidden = true }
        host.setFrame(collapsed, display: true, animate: animateResizing)
        if settings.foregroundWhenExpanding {
            host.level = settings.windowLevel == 0 ? .normal : settings.windowLevel == 1 ? .floating : NSWindow.Level(rawValue: Int(CGWindowLevelForKey(.desktopWindow)))
        }
        defaults.set(true, forKey: "windowIsMinimized"); defaults.set(NSStringFromRect(unminimizedRect), forKey: "unminimizedFrame")
        needsDisplay = true
    }
    public func expandWindow() {
        guard let host, let manager, let settings, host.minimized else { return }
        if !XRGGraphRenderer.validRect(unminimizedRect) {
            unminimizedRect = XRGBackgroundGeometry.repairedRestore(current: host.frame, saved: savedFrame, minimum: manager.getMinSize(), strip: strip)
        }
        let expanded = XRGBackgroundGeometry.expanded(host.frame, restore: unminimizedRect, vertical: vertical, direction: settings.minimizeUpDown, strip: strip)
        host.minimized = false; host.minSize = manager.getMinSize()
        if settings.foregroundWhenExpanding && settings.autoExpandGraph { host.level = .floating }
        host.setFrame(expanded, display: true, animate: animateResizing)
        for module in manager.displayList() { module.reference?.isHidden = false; module.reference?.needsDisplay = true }
        defaults.set(false, forKey: "windowIsMinimized"); needsDisplay = true
    }
    @nonobjc func makeMenu() -> NSMenu {
        let menu = NSMenu(title: "Background View")
        for (title, selector): (String, Selector) in [
            ("About XRG-ng", #selector(openAboutBox(_:))), ("Preferences...", #selector(openPreferences(_:))), ("XRG-ng Help", #selector(openHelp(_:))),
            (uiIsHidden ? "Show XRG-ng Dock Icon" : "Hide XRG-ng Dock Icon (After Restart)", uiIsHidden ? #selector(showUI(_:)) : #selector(hideUI(_:))), ("Quit XRG-ng", #selector(quit(_:)))] {
            if menu.items.count == 3 || title == "Quit XRG-ng" { menu.addItem(.separator()) }
            let item = NSMenuItem(title: title, action: selector, keyEquivalent: ""); item.target = self; menu.addItem(item)
        }
        return menu
    }
    public override func menu(for event: NSEvent) -> NSMenu? { makeMenu() }
    public func openAboutBox(_ sender: Any?) { action(.about) }
    public func openHelp(_ sender: Any?) { action(.help) }
    public func openPreferences(_ sender: Any?) { host?.showGeneralPreferences() }
    public func hideUI(_ sender: Any?) { uiIsHidden = true; defaults.set(true, forKey: "isDockIconHidden"); action(.hideDockNotice) }
    public func showUI(_ sender: Any?) { uiIsHidden = false; defaults.set(false, forKey: "isDockIconHidden"); action(.showDock) }
    public func quit(_ sender: Any?) { action(.quit) }
    @nonobjc private static func systemAction(_ action: XRGBackgroundAction) {
        switch action {
        case .about: NSApp.orderFrontStandardAboutPanel(nil)
        case .help: NSApp.showHelp(nil)
        case .quit: NSApp.terminate(nil)
        case .showDock: _ = NSApp.setActivationPolicy(.regular)
        case .preventOrdering: NSApp.preventWindowOrdering()
        case .hideDockNotice, .invalidTheme:
            let alert = NSAlert()
            alert.messageText = action == .hideDockNotice ? "Hiding the XRG-ng Dock Icon" : "Error"
            alert.informativeText = action == .hideDockNotice ? "Please re-launch XRG-ng for changes to take effect." : "The theme file dragged is not a valid theme file."
            alert.addButton(withTitle: "OK"); alert.runModal()
        }
    }
    @nonobjc func themeURL(from pasteboard: NSPasteboard, operation: NSDragOperation) -> URL? {
        guard operation.contains(.copy),
              let urls = pasteboard.readObjects(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) as? [URL],
              urls.count == 1, let url = urls.first, url.isFileURL, url.pathExtension == "xtf" else { return nil }
        return url
    }
    @nonobjc func performThemeDrop(from pasteboard: NSPasteboard, operation: NSDragOperation) -> Bool {
        guard let url = themeURL(from: pasteboard, operation: operation), let settings else { return false }
        let scoped = url.startAccessingSecurityScopedResource()
        defer { if scoped { url.stopAccessingSecurityScopedResource() } }
        do {
            let data = try readTheme(url)
            guard !data.isEmpty else { throw NSError(domain: "XRGThemeErrorDomain", code: 1) }
            let dictionary = try PropertyListSerialization.propertyList(from: data, options: [], format: nil)
            try settings.applyThemeDictionary(dictionary, defaults: defaults)
            needsDisplay = true; host?.backgroundThemeDidApply(); return true
        } catch { action(.invalidTheme); return false }
    }
    public override func draggingEntered(_ sender: any NSDraggingInfo) -> NSDragOperation {
        themeURL(from: sender.draggingPasteboard, operation: sender.draggingSourceOperationMask) == nil ? [] : .copy
    }
    public override func performDragOperation(_ sender: any NSDraggingInfo) -> Bool {
        performThemeDrop(from: sender.draggingPasteboard, operation: sender.draggingSourceOperationMask)
    }
    public override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let trackingArea { removeTrackingArea(trackingArea) }
        let area = NSTrackingArea(rect: .zero, options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect], owner: self, userInfo: nil)
        trackingArea = area; addTrackingArea(area)
    }
    public override func mouseEntered(with event: NSEvent) { if clickedMinimized && settings?.autoExpandGraph == true { expandWindow() } }
    public override func mouseExited(with event: NSEvent) { if clickedMinimized && settings?.autoExpandGraph == true { minimizeWindow() } }
}
