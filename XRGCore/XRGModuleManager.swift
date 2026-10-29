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

/// The window boundary keeps module layout testable without loading application nibs.
@MainActor @objc public protocol XRGModuleWindow: NSObjectProtocol {
    var minimized: Bool { get }
    var borderWidth: Int32 { get }
    var appSettings: XRGSettings? { get }
    var contentView: NSView? { get }
    var minSize: NSSize { get set }
    var frame: NSRect { get }
    func checkWindowSize()
    func setFrame(_ frame: NSRect, display: Bool, animate: Bool)
}

@MainActor
@objc(XRGModuleManager) @objcMembers
public final class XRGModuleManager: NSObject {
    private var allModules: [XRGModule] = []
    private weak var window: (any XRGModuleWindow)?
    private var laidOutSize: NSSize?
    public var graphOrientationVertical = true
    public var moduleSeparatorWidth: CGFloat = 2

    public override init() { super.init() }

    @objc(initWithWindow:)
    public init(window: (any XRGModuleWindow)?) {
        self.window = window
        super.init()
    }

    private var displayed: [XRGModule] {
        // Stable ties preserve registration order, including nonsequential orders.
        let customOrder = window?.appSettings?.graphPreferences.order
        return allModules.enumerated().filter { $0.element.isDisplayed }
            .sorted {
                if let customOrder {
                    let a = XRGGraphID(name: $0.element.name).flatMap { customOrder.firstIndex(of: $0) } ?? Int.max
                    let b = XRGGraphID(name: $1.element.name).flatMap { customOrder.firstIndex(of: $0) } ?? Int.max
                    if a != b { return a < b }
                }
                return $0.element.displayOrder == $1.element.displayOrder
                    ? $0.offset < $1.offset : $0.element.displayOrder < $1.element.displayOrder
            }.map(\.element)
    }
    private var layoutModules: [XRGModule] { displayed.filter { !$0.isEmptyModule } }
    private var border: CGFloat { max(0, CGFloat(window?.borderWidth ?? 0)) }
    private var titleHeight: CGFloat { XRGModule.dimension(window?.appSettings?.textRectHeight ?? 0) }
    private var separator: CGFloat { XRGModule.dimension(moduleSeparatorWidth) }
    private func fixedHeight(_ module: XRGModule) -> CGFloat? {
        guard let id = XRGGraphID(name: module.name), let height = window?.appSettings?.graphPreferences[id].height else { return nil }
        return max(XRGModule.dimension(module.minHeight), CGFloat(height))
    }
    private func dividerIsResizable(_ first: XRGModule, _ second: XRGModule) -> Bool {
        guard graphOrientationVertical else { return true }
        return [first, second].allSatisfy { module in
            guard let preferred = fixedHeight(module) else { return true }
            return abs(module.currentSize.height - preferred) < 1 && (64...240).contains(module.currentSize.height)
        }
    }

    /// Called only after a validated presentation change; hidden modules retain their order and overrides.
    @nonobjc func presentationChanged() {
        updateWindowMinimum(); window?.checkWindowSize()
        if let window { windowChanged(to: window.frame.size) }
        redisplayModules()
    }

    @objc(addModule:)
    public func addModule(_ module: XRGModule) { updateModule(module) }

    @objc(updateModule:)
    public func updateModule(_ module: XRGModule) {
        if let name = module.name, let index = allModules.firstIndex(where: { $0.name == name }) {
            allModules[index] = module
        } else if !allModules.contains(where: { $0 === module }) {
            allModules.append(module)
        }
        if module.isDisplayed { window?.checkWindowSize() }
        updateWindowMinimum()
    }

    @objc(removeModule:)
    public func removeModule(_ module: XRGModule) {
        guard allModules.contains(where: { $0 === module }) else { return }
        allModules.removeAll { $0 === module }
        updateWindowMinimum()
        if let window { windowChanged(to: window.frame.size) }
        redisplayModules()
    }

    @objc(updateModuleWithName:toReference:)
    public func updateModule(withName name: String, toReference reference: NSView?) {
        getModule(byName: name)?.reference = reference
    }

    @objc(setModule:isDisplayed:)
    public func setModule(_ name: String, isDisplayed: Bool) {
        guard let module = getModule(byName: name) else { return }
        module.isDisplayed = isDisplayed
        if isDisplayed {
            window?.checkWindowSize()
            let target = module.updateTarget
            if module.doesMin30Update { target?.min30Update(nil) }
            if module.doesMin5Update { target?.min5Update(nil) }
            if module.doesGraphUpdate { target?.graphUpdate(nil) }
            if module.doesFastUpdate { target?.fastUpdate(nil) }
        }
        updateWindowMinimum()
    }

    @objc(getModuleByName:)
    public func getModule(byName name: String) -> XRGModule? {
        allModules.first { $0.name == name }
    }
    @objc(getModuleByReference:)
    public func getModule(byReference reference: NSView?) -> XRGModule? {
        allModules.first { $0.reference === reference }
    }
    public func moduleList() -> [XRGModule] { allModules }
    public func displayList() -> [XRGModule] { displayed }
    public func numModulesDisplayed() -> Int32 { Int32(clamping: layoutModules.count) }

    public func getMinSize() -> NSSize {
        let modules = layoutModules
        let width = modules.map { XRGModule.dimension($0.minWidth) }.max() ?? 0
        let height = modules.map { XRGModule.dimension($0.minHeight) }.max() ?? 0
        let count = CGFloat(modules.count)
        let minimized = window?.minimized ?? false
        if graphOrientationVertical {
            return NSSize(width: width + border * 2,
                          height: (minimized ? titleHeight : titleHeight + (height + separator) * count) + border * 2)
        }
        return NSSize(width: (minimized ? titleHeight : titleHeight + (width + separator) * count) + border * 2,
                      height: height + border * 2)
    }

    private func updateWindowMinimum() { window?.minSize = getMinSize() }
    public func redisplayModules() { window?.contentView?.needsDisplay = true }

    @objc(windowChangedToSize:)
    public func windowChanged(to size: NSSize) {
        guard window?.minimized != true, size.width.isFinite, size.height.isFinite else { return }
        laidOutSize = size
        // Zero-size panels can still expose descendants to accessibility clients.
        for module in allModules { module.reference?.isHidden = !module.isDisplayed }
        for module in allModules where !module.isDisplayed {
            apply(.zero, to: module)
        }
        let modules = layoutModules
        guard !modules.isEmpty else { redisplayModules(); return }
        let count = CGFloat(modules.count)
        let width = max(0, size.width - border * 2)
        let height = max(0, size.height - border * 2)
        if graphOrientationVertical {
            let available = max(0, height - titleHeight - separator * count)
            let automatic = modules.filter { fixedHeight($0) == nil }.count
            if automatic == modules.count {
                for module in modules { apply(NSSize(width: width, height: available / count), to: module) }
            } else {
                // Reserve every graph's minimum first. Preferred heights consume
                // remaining space before automatic graphs, and compress together
                // instead of forcing a window larger than the display.
                let autoMinimum = modules.filter { fixedHeight($0) == nil }.map { XRGModule.dimension($0.minHeight) }.max() ?? 0
                let minima = modules.map { fixedHeight($0) == nil ? autoMinimum : XRGModule.dimension($0.minHeight) }
                let base = minima.reduce(0, +)
                let extra = max(0, available - base)
                let requested = zip(modules, minima).reduce(CGFloat(0)) { $0 + max(0, (fixedHeight($1.0) ?? $1.1) - $1.1) }
                let factor = requested > 0 ? min(1, extra / requested) : 0
                let automaticExtra = automatic > 0 ? max(0, extra - requested) / CGFloat(automatic) : 0
                for (module, minimum) in zip(modules, minima) {
                    let value = fixedHeight(module).map { minimum + max(0, $0 - minimum) * factor } ?? (minimum + automaticExtra)
                    apply(NSSize(width: width, height: base > available && base > 0 ? minimum * available / base : value), to: module)
                }
            }
        } else {
            let unit = max(0, width - titleHeight - separator * count) / count
            for module in modules { apply(NSSize(width: unit, height: min(height, fixedHeight(module) ?? height)), to: module) }
        }
        positionModules()
        redisplayModules()
    }

    private func apply(_ size: NSSize, to module: XRGModule) {
        guard let view = module.reference else { return }
        module.currentSize = size
        module.updateTarget?.setGraphSize(size)
        view.setFrameSize(size)
    }

    private var spatialModules: [XRGModule] {
        graphOrientationVertical ? Array(layoutModules.reversed()) : layoutModules
    }
    private func positionModules() {
        var origin = NSPoint(x: border, y: border)
        if graphOrientationVertical, let size = laidOutSize {
            let used = layoutModules.reduce(CGFloat(0)) { $0 + $1.currentSize.height + separator }
            origin.y += max(0, size.height - border * 2 - titleHeight - used)
        }
        if !graphOrientationVertical { origin.x += titleHeight + separator }
        for module in spatialModules where module.reference != nil {
            var point = origin
            if !graphOrientationVertical, let size = laidOutSize { point.y = border + max(0, size.height - border * 2 - module.currentSize.height) }
            module.reference?.setFrameOrigin(point)
            if graphOrientationVertical { origin.y += module.currentSize.height + separator }
            else { origin.x += module.currentSize.width + separator }
        }
    }

    public func graphFontChanged() {
        for module in displayed { module.updateTarget?.updateMinSize() }
        guard let window else { return }
        let minimum = getMinSize()
        var frame = window.frame
        frame.size.width = max(frame.width, minimum.width)
        frame.size.height = max(frame.height, minimum.height)
        window.setFrame(frame, display: true, animate: true)
        updateWindowMinimum()
    }

    // Copy the recipients before invoking views: a callback may change registration.
    public func min30Update() {
        let targets = displayed.filter(\.doesMin30Update).compactMap(\.updateTarget)
        for target in targets { target.min30Update(nil) }
    }
    public func min5Update() {
        let targets = displayed.filter(\.doesMin5Update).compactMap(\.updateTarget)
        for target in targets { target.min5Update(nil) }
    }
    public func graphUpdate() {
        let targets = (displayed.filter(\.doesGraphUpdate)
            + allModules.filter { !$0.isDisplayed && $0.alwaysDoesGraphUpdate })
            .compactMap(\.updateTarget)
        for target in targets { target.graphUpdate(nil) }
    }
    public func fastUpdate() {
        let targets = displayed.filter(\.doesFastUpdate).compactMap(\.updateTarget)
        for target in targets { target.fastUpdate(nil) }
    }

    @objc(resizeModuleNumber:byDelta:)
    public func resizeModule(number index: Int32, byDelta delta: Float) -> Float {
        let modules = spatialModules
        guard window?.minimized != true, delta.isFinite, index >= 0,
              Int(index) < modules.count - 1 else { return 0 }
        let first = modules[Int(index)], second = modules[Int(index) + 1]
        guard dividerIsResizable(first, second) else { return 0 }
        let a = graphOrientationVertical ? first.currentSize.height : first.currentSize.width
        let b = graphOrientationVertical ? second.currentSize.height : second.currentSize.width
        let minA = XRGModule.dimension(graphOrientationVertical ? first.minHeight : first.minWidth)
        let minB = XRGModule.dimension(graphOrientationVertical ? second.minHeight : second.minWidth)
        guard a.isFinite, b.isFinite else { return 0 }
        // Preserve the pair's total extent and return the distance actually moved.
        // Never shrink a module that is already at or below its minimum.
        var lower = min(0, minA - a), upper = max(0, b - minB)
        if graphOrientationVertical {
            if fixedHeight(first) != nil { lower = max(lower, 64 - a); upper = min(upper, 240 - a) }
            if fixedHeight(second) != nil { lower = max(lower, b - 240); upper = min(upper, b - 64) }
        }
        guard lower <= upper else { return 0 }
        let movement = min(max(CGFloat(delta), lower), upper)
        var sizeA = first.currentSize, sizeB = second.currentSize
        if graphOrientationVertical { sizeA.height += movement; sizeB.height -= movement }
        else { sizeA.width += movement; sizeB.width -= movement }
        apply(sizeA, to: first)
        apply(sizeB, to: second)
        if graphOrientationVertical, let settings = window?.appSettings {
            var value = settings.graphPreferences
            for module in [first, second] where fixedHeight(module) != nil {
                if let id = XRGGraphID(name: module.name) { value[id].height = Int(module.currentSize.height.rounded()) }
            }
            if value != settings.graphPreferences { try? settings.applyGraphPreferences(value) }
        }
        positionModules()
        redisplayModules()
        return Float(movement)
    }

    public func resizeRects() -> [NSValue] {
        let modules = spatialModules
        guard modules.count > 1 else { return [] }
        var origin = NSPoint(x: border, y: border)
        if graphOrientationVertical { origin.y = modules.first?.reference?.frame.minY ?? border }
        if !graphOrientationVertical { origin.x += titleHeight + separator }
        var rectangles: [NSValue] = []
        for (index, module) in modules.dropLast().enumerated() where module.reference != nil {
            let size = module.currentSize
            let rect: NSRect
            if graphOrientationVertical {
                origin.y += size.height + separator
                rect = NSRect(x: origin.x, y: origin.y - 2, width: size.width, height: separator + 2)
            } else {
                origin.x += size.width
                rect = NSRect(x: origin.x - 2, y: module.reference?.frame.minY ?? origin.y, width: separator + 2, height: size.height)
                origin.x += separator
            }
            rectangles.append(NSValue(rect: dividerIsResizable(module, modules[index + 1]) ? rect : .zero))
        }
        return rectangles
    }
}
