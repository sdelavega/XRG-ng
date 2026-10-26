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
struct XRGGraphLabelsTests {
    private func withSettings(_ body: (XRGSettings) throws -> Void) throws {
        let domain = "XRG.labels.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: domain))
        defer { defaults.removePersistentDomain(forName: domain) }
        let settings = XRGSettings(defaults: defaults)
        settings.textTransparency = 1
        settings.textColor = .black
        try body(settings)
    }

    @Test(arguments: [10, 18, 28], [0, 80, 140, 320].flatMap { width in [0, 20, 140].map { (width, $0) } })
    func resizingRetainsFullAccessibleReading(fontSize: Int, size: (Int, Int)) throws {
        try withSettings { settings in
            settings.graphFont = NSFont.systemFont(ofSize: CGFloat(fontSize))
            let labels = XRGGraphLabels()
            let rect = NSRect(x: 3, y: 0, width: size.0, height: size.1)
            let mini = XRGGraphLabels.shouldDrawMiniGraph(in: rect, settings: settings)
            let left = "CPU\n10 cores\nUptime 2d"
            let right = "12%\n2 GHz\n48°C"
            labels.layout(leftText: left, centerText: nil, rightText: right, in: rect, mini: mini, settings: settings)
            for label in [labels.leftLabel, labels.centerLabel, labels.rightLabel] {
                #expect(label.frame.size.width >= 0 && label.frame.size.height >= 0)
                #expect(label.frame.origin.x.isFinite && label.frame.origin.y.isFinite)
                #expect(label.accessibilityRole() == .staticText)
                #expect(label.hitTest(.zero) == nil)
            }
            #expect(labels.leftLabel.accessibilityValue() == left)
            #expect(labels.rightLabel.accessibilityValue() == right)
            #expect(!labels.centerLabel.isAccessibilityElement())
            #expect(labels.centerLabel.stringValue == "")
            if mini { #expect(labels.leftLabel.stringValue == "CPU") }
            else {
                let count = min(3, Int(floor(CGFloat(size.1) / settings.textRectHeight)))
                #expect(labels.leftLabel.stringValue == left.components(separatedBy: "\n").prefix(count).joined(separator: "\n"))
            }
        }
    }

    @Test func columnsStaySeparateAndUseOneLogicalLinePerRow() throws {
        try withSettings { settings in
            let labels = XRGGraphLabels()
            let rect = NSRect(x: 3, y: 5, width: 140, height: 100)
            let source = "A very long weather station name\nPressure"
            labels.layoutColumnText(source, rightText: "24°C\n1000 mb", in: rect, mini: false, settings: settings)
            #expect(labels.leftLabel.frame.maxX + 8 <= labels.rightLabel.frame.minX + 0.001)
            #expect(labels.rightLabel.frame.maxX == rect.maxX)
            #expect(labels.rightLabel.frame.width <= rect.width * 0.48)
            #expect(labels.leftLabel.accessibilityValue() == source)
            #expect(labels.leftLabel.lineBreakMode == .byTruncatingTail)
            let style = try #require(labels.leftLabel.attributedStringValue.attribute(.paragraphStyle, at: 0, effectiveRange: nil) as? NSParagraphStyle)
            #expect(style.minimumLineHeight == settings.textRectHeight)
            #expect(style.maximumLineHeight == settings.textRectHeight)
            labels.layoutColumnText("Only a label", rightText: nil, in: rect, mini: false, settings: settings)
            #expect(labels.rightLabel.frame.width == 0)
            #expect(labels.leftLabel.frame.width == rect.width)
        }
    }

    @Test func collapsedRectsAndInvalidLineHeightStayFinite() throws {
        try withSettings { settings in
            let labels = XRGGraphLabels()
            settings.textRectHeight = .nan
            labels.layoutColumnText("Full reading\nsecond line", rightText: "Value", in: NSRect(x: 3, y: 0, width: -10, height: -20), mini: true, settings: settings)
            #expect(labels.leftLabel.frame.size == .zero)
            #expect(labels.leftLabel.frame.origin.y.isFinite)
            #expect(labels.leftLabel.accessibilityValue() == "Full reading\nsecond line")
            #expect(XRGGraphLabels.paddedTextRect(for: .zero).size == .zero)
            labels.layout(leftText: "Value", centerText: nil, rightText: nil,
                in: NSRect(x: CGFloat.infinity, y: 0, width: 10, height: 10), mini: false, settings: nil)
            #expect(labels.leftLabel.frame == .zero)
        }
    }

    @Test func textFieldFallsBackToItsDisplayedValueWithoutAnOverride() {
        let label = XRGNonInteractableTextField(labelWithString: "Visible")
        #expect(label.accessibilityValue() == "Visible")
        label.fullAccessibilityText = "Complete reading"
        #expect(label.accessibilityValue() == "Complete reading")
        label.fullAccessibilityText = nil
        #expect(label.accessibilityValue() == "Visible")
    }
}
