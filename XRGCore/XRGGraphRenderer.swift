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

/// Stateless rendering; sample storage and generated geometry are owned by Swift.
@MainActor
@objc(XRGGraphRenderer) @objcMembers
public final class XRGGraphRenderer: NSObject {
    @nonobjc static let missingValue: CGFloat = -1000

    @nonobjc static func validRect(_ rect: NSRect) -> Bool {
        rect.origin.x.isFinite && rect.origin.y.isFinite && rect.size.width.isFinite && rect.size.height.isFinite
            && rect.size.width > 0 && rect.size.height > 0 && rect.maxX.isFinite && rect.maxY.isFinite
    }
    @nonobjc private static func limits(upper: CGFloat, lower: CGFloat, tolerance: CGFloat) -> (CGFloat, CGFloat)? {
        guard upper.isFinite, lower.isFinite, upper >= lower else { return nil }
        let low = upper - lower < tolerance ? lower - 0.5 : lower
        let high = upper - lower < tolerance ? upper + 0.5 : upper
        guard low.isFinite, high.isFinite, (high - low).isFinite, high > low else { return nil }
        return (low, high)
    }
    @nonobjc static func ordered(_ samples: [CGFloat], currentIndex: Int) -> [CGFloat] {
        guard !samples.isEmpty else { return [] }
        let remainder = currentIndex % samples.count
        let index = remainder < 0 ? remainder + samples.count : remainder
        let start = index == samples.count - 1 ? 0 : index + 1
        return Array(samples[start...]) + Array(samples[..<start])
    }
    @nonobjc private static func samples(_ pointer: UnsafePointer<CGFloat>?, count: Int, currentIndex: Int) -> [CGFloat] {
        guard count > 0, let pointer else { return [] }
        return ordered(Array(UnsafeBufferPointer(start: pointer, count: count)), currentIndex: currentIndex)
    }

    @nonobjc static func graphPoints(_ samples: [CGFloat], upper: CGFloat, lower: CGFloat,
                                    in rect: NSRect, flipped: Bool, filled: Bool) -> [NSPoint] {
        guard validRect(rect), !samples.isEmpty,
              let (low, high) = limits(upper: upper, lower: lower, tolerance: 0.001) else { return [] }
        let baseline = flipped ? rect.maxY : rect.minY
        var points: [NSPoint] = []
        for (index, sample) in samples.enumerated() where sample.isFinite && sample != missingValue {
            let fraction = (min(high, max(low, sample)) - low) / (high - low)
            points.append(NSPoint(x: rect.minX + CGFloat(index) * rect.width / CGFloat(samples.count),
                                  y: rect.minY + (flipped ? 1 - fraction : fraction) * rect.height))
        }
        guard !points.isEmpty else { return [] }
        points[points.count - 1].x = rect.maxX
        if filled {
            points.insert(NSPoint(x: rect.minX, y: baseline), at: 0)
            points.append(NSPoint(x: rect.maxX, y: baseline))
        }
        return points
    }
    @nonobjc private static func draw(_ samples: [CGFloat], upper: CGFloat, lower: CGFloat,
                                     in rect: NSRect, flipped: Bool, filled: Bool, color: NSColor?) {
        guard let color, NSGraphicsContext.current != nil else { return }
        let points = graphPoints(samples, upper: upper, lower: lower, in: rect, flipped: flipped, filled: filled)
        guard let first = points.first else { return }
        color.set()
        let path = NSBezierPath()
        path.move(to: first)
        for point in points.dropFirst() { path.line(to: point) }
        if filled {
            path.lineWidth = 0
            path.flatness = 0.6
            path.close()
            path.fill()
        } else {
            path.lineWidth = 1.2
            path.flatness = 10
            path.lineCapStyle = .round
            path.lineJoinStyle = .round
            path.stroke()
        }
    }

    @objc(drawSamples:count:currentIndex:upperBound:lowerBound:inRect:flipped:filled:color:)
    public static func drawSamples(_ pointer: UnsafePointer<CGFloat>?, count: Int, currentIndex: Int,
                                   upperBound: CGFloat, lowerBound: CGFloat, in rect: NSRect,
                                   flipped: Bool, filled: Bool, color: NSColor?) {
        draw(samples(pointer, count: count, currentIndex: currentIndex), upper: upperBound, lower: lowerBound,
             in: rect, flipped: flipped, filled: filled, color: color)
    }
    @objc(drawDataSet:upperBound:lowerBound:inRect:flipped:filled:color:)
    public static func drawDataSet(_ dataSet: XRGDataSet?, upperBound: CGFloat, lowerBound: CGFloat,
                                   in rect: NSRect, flipped: Bool, filled: Bool, color: NSColor?) {
        draw(dataSet?.orderedValues ?? [], upper: upperBound, lower: lowerBound,
             in: rect, flipped: flipped, filled: filled, color: color)
    }

    @nonobjc static func curveRuns(_ values: [CGFloat], upper: CGFloat, lower: CGFloat,
                                   in rect: NSRect, flipped: Bool) -> [[NSPoint]] {
        guard validRect(rect), !values.isEmpty, let (low, high) = limits(upper: upper, lower: lower, tolerance: 0.001) else { return [] }
        var result: [[NSPoint]] = [], run: [NSPoint] = []
        for (index, value) in values.enumerated() {
            guard value.isFinite, value != missingValue else {
                if !run.isEmpty { result.append(run); run = [] }; continue
            }
            let fraction = (min(high, max(low, value)) - low) / (high - low)
            run.append(NSPoint(x: rect.minX + (CGFloat(index) / CGFloat(max(1, values.count - 1))) * rect.width,
                               y: rect.minY + (flipped ? 1 - fraction : fraction) * rect.height))
        }
        if !run.isEmpty { result.append(run) }
        return result
    }

    @nonobjc private static func drawCurveValues(_ values: [CGFloat], upper: CGFloat, lower: CGFloat,
                                                in rect: NSRect, flipped: Bool, filled: Bool, color: NSColor?, style: XRGCurveStyle?) {
        guard let style else { draw(values, upper: upper, lower: lower, in: rect, flipped: flipped, filled: filled, color: color); return }
        guard let color, NSGraphicsContext.current != nil,
              let (low, high) = limits(upper: upper, lower: lower, tolerance: 0.001), validRect(rect) else { return }
        let runs = curveRuns(values, upper: upper, lower: lower, in: rect, flipped: flipped)
        let zero = (min(high, max(low, 0)) - low) / (high - low)
        let baseline = rect.minY + (flipped ? 1 - zero : zero) * rect.height
        NSGraphicsContext.saveGraphicsState(); defer { NSGraphicsContext.restoreGraphicsState() }
        NSBezierPath(rect: rect).addClip(); color.set()
        var remaining = 100_000
        for run in runs {
            guard let first = run.first, let last = run.last else { continue }
            if style == .solid || style == .hollow {
                let path = NSBezierPath(); path.lineWidth = 1.2
                if style == .solid { path.move(to: NSPoint(x: first.x, y: baseline)); path.line(to: first) }
                else { path.move(to: first) }
                for point in run.dropFirst() { path.line(to: point) }
                if style == .solid { path.line(to: NSPoint(x: last.x, y: baseline)); path.close(); path.fill() }
                else { path.stroke() }
            } else {
                let step: CGFloat = style == .pixel ? 6 : 3
                let dot: CGFloat = style == .pixel ? 3 : 1.5
                guard rect.width / step <= 100_000, rect.height / step <= 100_000 else { return }
                for (a, b) in zip(run, run.dropFirst()) where b.x > a.x {
                    var x = rect.minX + ceil((a.x - rect.minX) / step) * step
                    while x < b.x {
                        let y = a.y + (b.y - a.y) * (x - a.x) / (b.x - a.x)
                        var row = rect.minY + ceil((min(y, baseline) - rect.minY) / step) * step
                        while row < max(y, baseline) {
                            guard remaining > 0 else { return }; remaining -= 1
                            let cell = NSRect(x: x, y: row, width: dot, height: dot)
                            if style == .dot { NSBezierPath(ovalIn: cell).fill() } else { cell.fill() }
                            let next = row + step; guard next > row else { break }; row = next
                        }
                        let next = x + step; guard next > x else { break }; x = next
                    }
                }
            }
        }
    }

    @nonobjc static func drawCurve(_ dataSet: XRGDataSet?, upperBound: CGFloat, lowerBound: CGFloat,
                                   in rect: NSRect, flipped: Bool, filled: Bool, color: NSColor?, style: XRGCurveStyle?) {
        drawCurveValues(dataSet?.orderedValues ?? [], upper: upperBound, lower: lowerBound,
                        in: rect, flipped: flipped, filled: filled, color: color, style: style)
    }
    @nonobjc static func drawCurveSamples(_ pointer: UnsafePointer<CGFloat>?, count: Int, currentIndex: Int,
                                          upperBound: CGFloat, lowerBound: CGFloat, in rect: NSRect,
                                          flipped: Bool, filled: Bool, color: NSColor?, style: XRGCurveStyle?) {
        drawCurveValues(samples(pointer, count: count, currentIndex: currentIndex), upper: upperBound, lower: lowerBound,
                        in: rect, flipped: flipped, filled: filled, color: color, style: style)
    }

    @nonobjc static func miniBars(_ values: [Double], upper: Double, lower: Double, in rect: NSRect) -> [NSRect?] {
        guard validRect(rect), !values.isEmpty, upper.isFinite, lower.isFinite, upper >= lower else { return [] }
        // Preserve the mini graph's historical zero-range policy and one-pixel minimum.
        let span = upper - lower < 0.0001 ? 1 : upper - lower
        guard span.isFinite, span > 0 else { return [] }
        let height = rect.height / CGFloat(values.count)
        let spacing: CGFloat = height > 2 ? 1 : 0
        return values.enumerated().map { index, value in
            guard value.isFinite else { return nil }
            let fraction = min(1, max(0, (value - lower) / span))
            let width = min(rect.width, max(1, CGFloat(fraction) * rect.width))
            return NSRect(x: rect.minX, y: rect.maxY - CGFloat(index + 1) * height,
                          width: width, height: index == 0 ? height : max(0, floor(height - spacing)))
        }
    }
    @objc(drawMiniValues:upperBound:lowerBound:inRect:settings:)
    public static func drawMiniValues(_ values: [NSNumber], upperBound: Double, lowerBound: Double,
                                      in rect: NSRect, settings: XRGSettings?) {
        guard let settings, let context = NSGraphicsContext.current else { return }
        NSGraphicsContext.saveGraphicsState()
        defer { NSGraphicsContext.restoreGraphicsState() }
        context.shouldAntialias = settings.antiAliasing
        for (index, bar) in miniBars(values.map(\.doubleValue), upper: upperBound, lower: lowerBound, in: rect).enumerated() {
            guard let bar else { continue }
            (index == 1 && values.count == 2 ? settings.graphFG2Color : settings.graphFG1Color).set()
            context.cgContext.fill(bar)
        }
    }

    @nonobjc static func drawGraphBars(_ values: [NSNumber], upperBound: Double, lowerBound: Double,
                                       in rect: NSRect, settings: XRGSettings?, module: XRGGraphID) {
        guard let settings, let context = NSGraphicsContext.current else { return }
        NSGraphicsContext.saveGraphicsState(); defer { NSGraphicsContext.restoreGraphicsState() }
        context.shouldAntialias = settings.antiAliasing
        for (index, bar) in miniBars(values.map(\.doubleValue), upper: upperBound, lower: lowerBound, in: rect).enumerated() {
            guard let bar else { continue }
            settings.graphColor(module, component: index == 1 && values.count == 2 ? 2 : 1).set()
            context.cgContext.fill(bar)
        }
    }

    @objc(drawStyleInRect:settings:)
    public static func drawStyle(in rect: NSRect, settings: XRGSettings?) {
        drawEffect(in: rect, effect: settings?.graphStyle ?? 0, settings: settings)
    }
    @nonobjc static func drawGraphEffect(in rect: NSRect, settings: XRGSettings?, module: XRGGraphID) {
        drawEffect(in: rect, effect: settings?.graphEffect(module) ?? 0, settings: settings)
    }
    @nonobjc private static func drawEffect(in rect: NSRect, effect: Int, settings: XRGSettings?) {
        switch effect {
        case 1: drawScanlines(rect)
        case 2: drawPixelGrid(rect, spacing: 4, color: settings?.borderColor)
        case 3: drawRetroDots(rect, color: settings?.borderColor)
        default: break
        }
    }
    public static func drawScanlines(_ rect: NSRect) {
        guard validRect(rect), rect.height / 2 <= 100_000, NSGraphicsContext.current != nil else { return }
        NSColor.black.withAlphaComponent(0.5).set()
        let path = NSBezierPath()
        path.lineWidth = 1
        for row in 0..<Int(ceil(rect.height / 2)) {
            let y = rect.minY + CGFloat(row) * 2
            path.move(to: NSPoint(x: rect.minX, y: y)); path.line(to: NSPoint(x: rect.maxX, y: y))
        }
        path.stroke()
    }
    @objc(drawPixelGrid:spacing:color:)
    public static func drawPixelGrid(_ rect: NSRect, spacing: CGFloat, color: NSColor?) {
        guard validRect(rect), spacing.isFinite, spacing > 0,
              rect.width / spacing + rect.height / spacing <= 100_000,
              let color, NSGraphicsContext.current != nil else { return }
        color.withAlphaComponent(0.4).set()
        let path = NSBezierPath()
        path.lineWidth = 1
        for column in 0..<Int(ceil(rect.width / spacing)) {
            let x = rect.minX + CGFloat(column) * spacing
            path.move(to: NSPoint(x: x, y: rect.minY)); path.line(to: NSPoint(x: x, y: rect.maxY))
        }
        for row in 0..<Int(ceil(rect.height / spacing)) {
            let y = rect.minY + CGFloat(row) * spacing
            path.move(to: NSPoint(x: rect.minX, y: y)); path.line(to: NSPoint(x: rect.maxX, y: y))
        }
        path.stroke()
    }
    @objc(drawRetroDots:color:)
    public static func drawRetroDots(_ rect: NSRect, color: NSColor?) {
        guard validRect(rect), let color, NSGraphicsContext.current != nil else { return }
        let columns = max(0, ceil(rect.width / 3) - 1), rows = max(0, ceil(rect.height / 3) - 1)
        guard columns * rows <= 100_000, columns <= 100_000, rows <= 100_000 else { return }
        color.withAlphaComponent(0.5).set()
        for x in 0..<Int(columns) {
            for y in 0..<Int(rows) {
                NSBezierPath(ovalIn: NSRect(x: rect.minX + CGFloat(x + 1) * 3 - 1,
                                           y: rect.minY + CGFloat(y + 1) * 3 - 1, width: 2, height: 2)).fill()
            }
        }
    }

    @nonobjc static func pixelPoints(_ samples: [CGFloat], upper: CGFloat, in rect: NSRect) -> [NSPoint] {
        guard validRect(rect), !samples.isEmpty, upper.isFinite, upper >= 0 else { return [] }
        let limit: CGFloat = upper < 0.001 ? 1 : upper
        return samples.enumerated().compactMap { index, value in
            guard value.isFinite, value != missingValue, value > 0 else { return nil }
            return NSPoint(x: rect.minX + CGFloat(index) * rect.width / CGFloat(samples.count),
                           y: rect.minY + min(value / limit, 1) * rect.height)
        }
    }
    @nonobjc private static func drawPixels(_ samples: [CGFloat], upper: CGFloat, in rect: NSRect,
                                           color: NSColor?, dotSize: CGFloat) {
        guard let color, dotSize.isFinite, dotSize > 0, dotSize <= 100_000,
              NSGraphicsContext.current != nil else { return }
        let points = pixelPoints(samples, upper: upper, in: rect)
        guard !points.isEmpty else { return }
        NSGraphicsContext.saveGraphicsState()
        defer { NSGraphicsContext.restoreGraphicsState() }
        NSBezierPath(rect: rect).addClip()
        color.withAlphaComponent(0.3).set()
        for point in points {
            NSBezierPath(ovalIn: NSRect(x: point.x - dotSize, y: point.y - dotSize,
                                       width: dotSize * 3, height: dotSize * 3)).fill()
        }
        color.set()
        for point in points {
            NSRect(x: point.x - dotSize / 2, y: point.y - dotSize / 2, width: dotSize, height: dotSize).fill(using: .copy)
        }
    }
    @objc(drawPixelSamples:count:currentIndex:upperBound:inRect:color:dotSize:)
    public static func drawPixelSamples(_ pointer: UnsafePointer<CGFloat>?, count: Int, currentIndex: Int,
                                        upperBound: CGFloat, in rect: NSRect, color: NSColor?, dotSize: CGFloat) {
        drawPixels(samples(pointer, count: count, currentIndex: currentIndex), upper: upperBound,
                   in: rect, color: color, dotSize: dotSize)
    }
    @objc(drawPixelDataSet:upperBound:inRect:color:dotSize:)
    public static func drawPixelDataSet(_ dataSet: XRGDataSet?, upperBound: CGFloat,
                                        in rect: NSRect, color: NSColor?, dotSize: CGFloat) {
        drawPixels(dataSet?.orderedValues ?? [], upper: upperBound, in: rect, color: color, dotSize: dotSize)
    }
    @objc(drawNeonGlowLine:atY:color:)
    public static func drawNeonGlowLine(_ rect: NSRect, atY y: CGFloat, color: NSColor?) {
        guard validRect(rect), y.isFinite, let color, NSGraphicsContext.current != nil else { return }
        color.withAlphaComponent(0.2).set()
        NSRect(x: rect.minX, y: y - 3, width: rect.width, height: 6).fill(using: .copy)
        color.withAlphaComponent(0.5).set()
        NSRect(x: rect.minX, y: y - 1, width: rect.width, height: 2).fill(using: .copy)
        color.set()
        NSRect(x: rect.minX, y: y - 0.5, width: rect.width, height: 1).fill(using: .copy)
    }
    @objc(fillRect:color:)
    public static func fillRect(_ rect: NSRect, color: NSColor?) {
        guard validRect(rect), let color, NSGraphicsContext.current != nil else { return }
        color.set(); rect.fill()
    }
}
