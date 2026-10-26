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

/// Compatibility surface for archived generic views and Swift subclasses.
@MainActor @objc(XRGGenericView) @objcMembers
open class XRGGenericView: NSView, XRGModuleView {
    public var appSettings: XRGSettings?
    public weak var moduleManager: XRGModuleManager?
    public weak var parentWindow: XRGGraphWindow?
    public var leftLabel: NSTextField?
    public var centerLabel: NSTextField?
    public var rightLabel: NSTextField?
    private var graphLabels: XRGGraphLabels?

    @nonobjc private func ensureGraphLabels() -> XRGGraphLabels {
        if let graphLabels { return graphLabels }
        let labels = XRGGraphLabels(); graphLabels = labels
        leftLabel = labels.leftLabel; centerLabel = labels.centerLabel; rightLabel = labels.rightLabel
        for label in [labels.leftLabel, labels.centerLabel, labels.rightLabel] { addSubview(label) }
        return labels
    }
    open override func awakeFromNib() {
        super.awakeFromNib()
        if parentWindow == nil { parentWindow = window as? XRGGraphWindow }
        if appSettings == nil { appSettings = parentWindow?.appSettings }
        if moduleManager == nil { moduleManager = parentWindow?.moduleManager }
        _ = ensureGraphLabels()
    }
    open override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        parentWindow = window as? XRGGraphWindow
        appSettings = parentWindow?.appSettings
        moduleManager = parentWindow?.moduleManager
    }
    @objc(drawGraphWithData:size:currentIndex:maxValue:inRect:flipped:color:)
    open func drawGraph(data: UnsafePointer<CGFloat>?, size: Int, currentIndex: Int, maxValue: CGFloat, in rect: NSRect, flipped: Bool, color: NSColor?) {
        drawRangedGraph(data: data, size: size, currentIndex: currentIndex, upperBound: maxValue, lowerBound: 0, in: rect, flipped: flipped, filled: true, color: color)
    }
    @objc(drawGraphWithDataFromDataSet:maxValue:inRect:flipped:filled:color:)
    open func drawGraph(dataSet: XRGDataSet?, maxValue: CGFloat, in rect: NSRect, flipped: Bool, filled: Bool, color: NSColor?) {
        XRGGraphRenderer.drawDataSet(dataSet, upperBound: maxValue, lowerBound: 0, in: rect, flipped: flipped, filled: filled, color: color)
    }
    @objc(drawRangedGraphWithData:size:currentIndex:upperBound:lowerBound:inRect:flipped:filled:color:)
    open func drawRangedGraph(data: UnsafePointer<CGFloat>?, size: Int, currentIndex: Int, upperBound: CGFloat, lowerBound: CGFloat, in rect: NSRect, flipped: Bool, filled: Bool, color: NSColor?) {
        XRGGraphRenderer.drawSamples(data, count: size, currentIndex: currentIndex, upperBound: upperBound, lowerBound: lowerBound, in: rect, flipped: flipped, filled: filled, color: color)
    }
    @objc(drawRangedGraphWithDataFromDataSet:upperBound:lowerBound:inRect:flipped:filled:color:)
    open func drawRangedGraph(dataSet: XRGDataSet?, upperBound: CGFloat, lowerBound: CGFloat, in rect: NSRect, flipped: Bool, filled: Bool, color: NSColor?) {
        XRGGraphRenderer.drawDataSet(dataSet, upperBound: upperBound, lowerBound: lowerBound, in: rect, flipped: flipped, filled: filled, color: color)
    }
    @objc(drawCyberpunkEffectsInRect:)
    open func drawCyberpunkEffects(in rect: NSRect) { XRGGraphRenderer.drawStyle(in: rect, settings: appSettings) }
    @objc(drawScanlines:)
    open func drawScanlines(_ rect: NSRect) { XRGGraphRenderer.drawScanlines(rect) }
    @objc(drawPixelGrid:withSpacing:color:)
    open func drawPixelGrid(_ rect: NSRect, withSpacing spacing: CGFloat, color: NSColor?) { XRGGraphRenderer.drawPixelGrid(rect, spacing: spacing, color: color) }
    @objc(drawRetroDots:)
    open func drawRetroDots(_ rect: NSRect) { XRGGraphRenderer.drawRetroDots(rect, color: appSettings?.borderColor) }
    @objc(drawPixelDotsWithData:size:currentIndex:maxValue:inRect:color:dotSize:)
    open func drawPixelDots(data: UnsafePointer<CGFloat>?, size: Int, currentIndex: Int, maxValue: CGFloat, in rect: NSRect, color: NSColor?, dotSize: CGFloat) {
        XRGGraphRenderer.drawPixelSamples(data, count: size, currentIndex: currentIndex, upperBound: maxValue, in: rect, color: color, dotSize: dotSize)
    }
    @objc(drawPixelDotsWithDataFromDataSet:maxValue:inRect:color:dotSize:)
    open func drawPixelDots(dataSet: XRGDataSet?, maxValue: CGFloat, in rect: NSRect, color: NSColor?, dotSize: CGFloat) {
        XRGGraphRenderer.drawPixelDataSet(dataSet, upperBound: maxValue, in: rect, color: color, dotSize: dotSize)
    }
    @objc(drawNeonGlowLine:atY:color:)
    open func drawNeonGlowLine(_ rect: NSRect, atY y: CGFloat, color: NSColor?) { XRGGraphRenderer.drawNeonGlowLine(rect, atY: y, color: color) }
    @objc(drawMiniGraphWithValues:upperBound:lowerBound:leftLabel:printValueBytes:printValueIsRate:)
    open func drawMiniGraph(values: [NSNumber], upperBound: Double, lowerBound: Double, leftLabel: String?, printValueBytes: UInt64, printValueIsRate: Bool) {
        let right = XRGCommon.formattedString(forBytes: Double(printValueBytes)) + (printValueIsRate ? "/s" : "")
        drawMiniGraph(values: values, upperBound: upperBound, lowerBound: lowerBound, leftLabel: leftLabel, rightLabel: right)
    }
    @objc(drawMiniGraphWithValues:upperBound:lowerBound:leftLabel:rightLabel:)
    open func drawMiniGraph(values: [NSNumber], upperBound: Double, lowerBound: Double, leftLabel: String?, rightLabel: String?) {
        if appSettings == nil { appSettings = (window as? XRGGraphWindow)?.appSettings }
        XRGGraphRenderer.drawMiniValues(values, upperBound: upperBound, lowerBound: lowerBound, in: bounds, settings: appSettings)
        drawLeftText(leftLabel, centerText: nil, rightText: rightLabel, in: paddedTextRect)
    }
    @objc(fillRect:withColor:)
    open func fillRect(_ rect: NSRect, withColor color: NSColor?) { XRGGraphRenderer.fillRect(rect, color: color) }
    @objc(drawLeftText:centerText:rightText:inRect:)
    open func drawLeftText(_ leftText: String?, centerText: String?, rightText: String?, in rect: NSRect) {
        ensureGraphLabels().layout(leftText: leftText, centerText: centerText, rightText: rightText, in: rect, mini: shouldDrawMiniGraph, settings: appSettings)
        NSGraphicsContext.current?.shouldAntialias = appSettings?.antiAliasing ?? false
    }
    @objc(drawColumnText:rightText:inRect:)
    open func drawColumnText(_ leftText: String?, rightText: String?, in rect: NSRect) {
        ensureGraphLabels().layoutColumnText(leftText, rightText: rightText, in: rect, mini: shouldDrawMiniGraph, settings: appSettings)
        NSGraphicsContext.current?.shouldAntialias = appSettings?.antiAliasing ?? false
    }
    open var shouldDrawMiniGraph: Bool { XRGGraphLabels.shouldDrawMiniGraph(in: bounds, settings: appSettings) }
    open var paddedTextRect: NSRect { XRGGraphLabels.paddedTextRect(for: bounds) }
    open func setGraphSize(_ size: NSSize) {}
    open func updateMinSize() {}
    open func graphUpdate(_ timer: Timer?) {}
    open func fastUpdate(_ timer: Timer?) {}
    open func min5Update(_ timer: Timer?) {}
    open func min30Update(_ timer: Timer?) {}
}
