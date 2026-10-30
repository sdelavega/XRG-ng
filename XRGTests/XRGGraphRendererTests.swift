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
import Foundation
import Testing
@testable import XRGCore

@Suite @MainActor
struct XRGGraphRendererTests {
    private let rect = NSRect(x: 10, y: 20, width: 100, height: 80)

    private func bitmap(_ draw: () -> Void) throws -> [UInt8] {
        let context = try #require(CGContext(data: nil, width: 64, height: 64, bitsPerComponent: 8,
            bytesPerRow: 64 * 4, space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        context.setFillColor(NSColor.white.cgColor)
        context.fill(CGRect(x: 0, y: 0, width: 64, height: 64))
        NSGraphicsContext.saveGraphicsState()
        defer { NSGraphicsContext.restoreGraphicsState() }
        NSGraphicsContext.current = NSGraphicsContext(cgContext: context, flipped: false)
        NSGraphicsContext.current?.shouldAntialias = false
        draw()
        return Array(UnsafeBufferPointer(start: try #require(context.data).assumingMemoryBound(to: UInt8.self), count: 64 * 64 * 4))
    }

    // Bitmap storage is top-to-bottom; graph coordinates are bottom-to-top.
    private func pixelOffset(x: Int, y: Int) -> Int { ((63 - y) * 64 + x) * 4 }

    @Test func observationPositionsPreserveTimeAndRejectInvalidCoordinates() throws {
        let runs = XRGGraphRenderer.curveRuns([0,-1000,100], upper:100, lower:0, in:rect, flipped:false, positions:[0.1,0.5,0.8])
        #expect(runs == [[NSPoint(x:20,y:20)],[NSPoint(x:90,y:100)]])
        for positions: [CGFloat] in [[0.8,0.1],[0,1.1],[0,.nan],[0]] {
            #expect(XRGGraphRenderer.curveRuns([0,100], upper:100, lower:0, in:rect, flipped:false, positions:positions).isEmpty)
        }
        let single = try bitmap {
            XRGGraphRenderer.drawObservationCurve([50],positions:[0.5],upper:100,lower:0,in:NSRect(x:4,y:4,width:56,height:56),filled:false,color:.blue,style:nil)
        }
        #expect(single.contains { $0 != 255 })
    }
    @Test func chronologicalOrderingNormalizesRawRingIndexes() {
        #expect(XRGGraphRenderer.ordered([30, 40, 10, 20], currentIndex: 1) == [10, 20, 30, 40])
        #expect(XRGGraphRenderer.ordered([30, 40, 10, 20], currentIndex: -3) == [10, 20, 30, 40])
        #expect(XRGGraphRenderer.ordered([1, 2], currentIndex: .max) == [1, 2])
        #expect(XRGGraphRenderer.ordered([], currentIndex: -1).isEmpty)
    }

    @Test func explicitCurveStylesPreserveMissingIntervalsAndRetainLegacyRenderingWhenInherited() throws {
        let runs = XRGGraphRenderer.curveRuns([20, .nan, 80, 60], upper: 100, lower: 0, in: rect, flipped: false)
        #expect(runs.count == 2 && runs[0].count == 1 && runs[1].count == 2)
        #expect(runs[0][0].x == rect.minX && runs[1][1].x == rect.maxX)
        let data = XRGDataSet(); data.resize(3)
        for value in [CGFloat(50), 50, 50] { data.setNextValue(value) }
        let bounds = NSRect(x: 4, y: 4, width: 56, height: 56)
        let legacy = try bitmap { XRGGraphRenderer.drawDataSet(data, upperBound: 100, lowerBound: 0, in: bounds, flipped: false, filled: true, color: .red) }
        let inherited = try bitmap { XRGGraphRenderer.drawCurve(data, upperBound: 100, lowerBound: 0, in: bounds, flipped: false, filled: true, color: .red, style: nil) }
        #expect(inherited == legacy)
        var renderings: [[UInt8]] = []
        for style in XRGCurveStyle.allCases {
            let image = try bitmap { XRGGraphRenderer.drawCurve(data, upperBound: 100, lowerBound: 0, in: bounds, flipped: false, filled: true, color: .red, style: style) }
            #expect(image.contains { $0 != 255 })
            renderings.append(image)
        }
        for i in renderings.indices { for j in renderings.indices where j > i { #expect(renderings[i] != renderings[j]) } }
        let extreme = XRGGraphRenderer.curveRuns([0, 50, 100], upper: 100, lower: 0,
            in: NSRect(x: 0, y: 0, width: 1e300, height: 1e300), flipped: false)
        #expect(extreme.flatMap { $0 }.allSatisfy { $0.x.isFinite && $0.y.isFinite })
    }

    @Test(arguments: [false, true])
    func filledAndFlippedGeometryRetainsBounds(flipped: Bool) {
        let points = XRGGraphRenderer.graphPoints([-10, 25, 200], upper: 100, lower: 0, in: rect, flipped: flipped, filled: true)
        #expect(points.count == 5)
        #expect(points.first == NSPoint(x: 10, y: flipped ? 100 : 20))
        #expect(points.last == NSPoint(x: 110, y: flipped ? 100 : 20))
        #expect(points[1].y == (flipped ? 100 : 20))
        #expect(points[2].y == (flipped ? 80 : 40))
        #expect(points[3] == NSPoint(x: 110, y: flipped ? 20 : 100))
    }

    @Test func missingNonfiniteAndInvalidGeometryAreSafe() {
        #expect(XRGGraphRenderer.graphPoints([-1000, .nan, .infinity], upper: 100, lower: 0, in: rect, flipped: false, filled: false).isEmpty)
        let points = XRGGraphRenderer.graphPoints([20, -1000, 80, .nan], upper: 100, lower: 0, in: rect, flipped: false, filled: false)
        #expect(points == [NSPoint(x: 10, y: 36), NSPoint(x: 110, y: 84)])
        #expect(XRGGraphRenderer.graphPoints([1], upper: .infinity, lower: 0, in: rect, flipped: false, filled: true).isEmpty)
        #expect(XRGGraphRenderer.graphPoints([1], upper: 0, lower: 1, in: rect, flipped: false, filled: true).isEmpty)
        #expect(XRGGraphRenderer.graphPoints([1], upper: 2, lower: 0, in: NSRect(x: 0, y: 0, width: -5, height: 10), flipped: false, filled: true).isEmpty)
        let equal = XRGGraphRenderer.graphPoints([25], upper: 25, lower: 25, in: rect, flipped: false, filled: false)
        #expect(equal == [NSPoint(x: 110, y: 60)])
    }

    @Test func miniBarsKeepRowSpacingClampValuesAndHandleEmptyInput() throws {
        let bounds = NSRect(x: 2, y: 3, width: 100, height: 20)
        let bars = XRGGraphRenderer.miniBars([150, -5], upper: 100, lower: 0, in: bounds)
        #expect(try #require(bars[0]) == NSRect(x: 2, y: 13, width: 100, height: 10))
        #expect(try #require(bars[1]) == NSRect(x: 2, y: 3, width: 1, height: 9))
        #expect(XRGGraphRenderer.miniBars([], upper: 1, lower: 0, in: bounds).isEmpty)
        #expect(XRGGraphRenderer.miniBars([.nan], upper: 1, lower: 0, in: bounds).first! == nil)
        #expect(XRGGraphRenderer.miniBars([0], upper: .nan, lower: 0, in: bounds).isEmpty)
        let equal = XRGGraphRenderer.miniBars([10], upper: 10, lower: 10, in: bounds)
        #expect(try #require(equal[0]).width == 1)
    }

    @Test func pixelGeometryRejectsMissingValuesAndClampsExtremes() {
        let points = XRGGraphRenderer.pixelPoints([0, -1000, .infinity, 200, 50], upper: 100, in: rect)
        #expect(points == [NSPoint(x: 70, y: 100), NSPoint(x: 90, y: 60)])
        #expect(XRGGraphRenderer.pixelPoints([1], upper: -1, in: rect).isEmpty)
    }

    @Test(arguments: [false, true], [false, true])
    func dataSetAndRawRendererHaveIdenticalPixels(flipped: Bool, filled: Bool) throws {
        let set = XRGDataSet()
        set.resize(4)
        for value in [10.0, 20, 30, 40] { set.setNextValue(value) }
        let bounds = NSRect(x: 0, y: 0, width: 64, height: 64)
        let fromSet = try bitmap {
            XRGGraphRenderer.drawDataSet(set, upperBound: 100, lowerBound: 0, in: bounds, flipped: flipped, filled: filled, color: .red)
        }
        let fromRaw = try bitmap {
            [10.0, 20, 30, 40].withUnsafeBufferPointer {
                XRGGraphRenderer.drawSamples($0.baseAddress, count: 4, currentIndex: 3, upperBound: 100, lowerBound: 0,
                    in: bounds, flipped: flipped, filled: filled, color: .red)
            }
        }
        #expect(fromSet == fromRaw)
        #expect(fromSet != (try bitmap {}))
    }

    @Test func invalidDrawingInputsLeaveBitmapUnchanged() throws {
        let untouched = try bitmap {}
        let image = try bitmap {
            let bounds = NSRect(x: 0, y: 0, width: 64, height: 64)
            [-1000.0, Double.nan].withUnsafeBufferPointer {
                XRGGraphRenderer.drawSamples($0.baseAddress, count: 2, currentIndex: 1, upperBound: 100, lowerBound: 0,
                    in: bounds, flipped: false, filled: false, color: .red)
            }
            XRGGraphRenderer.drawSamples(nil, count: -1, currentIndex: 0, upperBound: 100, lowerBound: 0, in: bounds, flipped: false, filled: true, color: .red)
            XRGGraphRenderer.drawPixelGrid(bounds, spacing: 0, color: .red)
            XRGGraphRenderer.drawPixelGrid(bounds, spacing: .leastNonzeroMagnitude, color: .red)
            XRGGraphRenderer.drawPixelGrid(bounds, spacing: .infinity, color: .red)
            XRGGraphRenderer.drawMiniValues([], upperBound: 1, lowerBound: 0, in: bounds, settings: nil)
            XRGGraphRenderer.drawPixelDataSet(nil, upperBound: 1, in: bounds, color: .red, dotSize: .nan)
        }
        #expect(image == untouched)
    }

    @Test func drawingStylesAndFillProduceVisiblePixels() throws {
        let untouched = try bitmap {}
        let bounds = NSRect(x: 2, y: 2, width: 60, height: 60)
        #expect(try bitmap { XRGGraphRenderer.drawScanlines(bounds) } != untouched)
        #expect(try bitmap { XRGGraphRenderer.drawPixelGrid(bounds, spacing: 4, color: .red) } != untouched)
        #expect(try bitmap { XRGGraphRenderer.drawRetroDots(bounds, color: .red) } != untouched)
        #expect(try bitmap { XRGGraphRenderer.drawNeonGlowLine(bounds, atY: 30, color: .red) } != untouched)
        let filled = try bitmap { XRGGraphRenderer.fillRect(bounds, color: .red) }
        let center = pixelOffset(x: 32, y: 32)
        #expect(filled[center] > 240 && filled[center + 1] < 10 && filled[center + 2] < 10)
    }
    @Test func neonRetainsCopyAlphaAndPixelDotsStayInsideTheirPlot() throws {
        let neon = try bitmap {
            XRGGraphRenderer.drawNeonGlowLine(NSRect(x: 2, y: 2, width: 60, height: 60), atY: 30, color: .red)
        }
        let outerGlow = pixelOffset(x: 32, y: 32)
        #expect((50...52).contains(Int(neon[outerGlow + 3])))
        #expect(neon[outerGlow + 1] == 0 && neon[outerGlow + 2] == 0)
        let pixels = try bitmap {
            [CGFloat(50)].withUnsafeBufferPointer {
                XRGGraphRenderer.drawPixelSamples($0.baseAddress, count: 1, currentIndex: 0,
                    upperBound: 100, in: NSRect(x: 10, y: 10, width: 20, height: 20), color: .red, dotSize: 2)
            }
        }
        let outside = pixelOffset(x: 9, y: 20)
        #expect(pixels[outside] == 255 && pixels[outside + 1] == 255 && pixels[outside + 2] == 255)
        let inside = pixelOffset(x: 10, y: 20)
        #expect(pixels[inside] > 240 && pixels[inside + 1] < 10 && pixels[inside + 2] < 10)
    }

    @Test func miniDrawingRestoresContextAndUsesBothSeriesColors() throws {
        let settings = XRGSettings()
        settings.graphFG1Transparency = 1; settings.graphFG1Color = .red
        settings.graphFG2Transparency = 1; settings.graphFG2Color = .blue
        settings.antiAliasing = true
        let image = try bitmap {
            XRGGraphRenderer.drawMiniValues([100, 100], upperBound: 100, lowerBound: 0,
                in: NSRect(x: 0, y: 0, width: 64, height: 64), settings: settings)
            #expect(NSGraphicsContext.current?.shouldAntialias == false)
        }
        let upper = pixelOffset(x: 32, y: 48), lower = pixelOffset(x: 32, y: 16)
        #expect(image[upper] > 240 && image[upper + 2] < 10)
        #expect(image[lower] < 10 && image[lower + 2] > 240)
    }

}
