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

/// Shared text layout, including the full reading retained for accessibility.
@MainActor
@objc(XRGGraphLabels) @objcMembers
public final class XRGGraphLabels: NSObject {
    public let leftLabel: XRGNonInteractableTextField
    public let centerLabel: XRGNonInteractableTextField
    public let rightLabel: XRGNonInteractableTextField

    public override init() {
        func label(_ alignment: NSTextAlignment) -> XRGNonInteractableTextField {
            let label = XRGNonInteractableTextField(frame: .zero)
            label.alignment = alignment
            label.isSelectable = false
            label.isEditable = false
            label.isBordered = false
            label.drawsBackground = false
            label.isEnabled = true
            return label
        }
        leftLabel = label(.left)
        centerLabel = label(.center)
        rightLabel = label(.right)
        super.init()
    }

    @nonobjc static func textRect(_ rect: NSRect) -> NSRect {
        guard rect.origin.x.isFinite, rect.origin.y.isFinite else { return .zero }
        let width = rect.size.width.isFinite ? max(0, rect.size.width) : 0
        let height = rect.size.height.isFinite ? max(0, rect.size.height) : 0
        guard (rect.origin.x + width).isFinite, (rect.origin.y + height).isFinite else { return .zero }
        return NSRect(origin: rect.origin, size: NSSize(width: width, height: height))
    }
    @nonobjc static func lineHeight(_ settings: XRGSettings?) -> CGFloat {
        if let height = settings?.textRectHeight, height.isFinite, height > 0 { return height }
        let font = settings?.graphFont ?? NSFont.systemFont(ofSize: 10)
        return max(1, font.ascender - font.descender)
    }
    @nonobjc private static func attributes(_ source: NSMutableDictionary?, alignment: NSTextAlignment) -> [NSAttributedString.Key: Any] {
        var attributes: [NSAttributedString.Key: Any] = [:]
        if let source {
            for (key, value) in source {
                if let key = key as? String { attributes[NSAttributedString.Key(key)] = value }
            }
        }
        if attributes[.font] == nil { attributes[.font] = NSFont.systemFont(ofSize: 10) }
        if attributes[.paragraphStyle] == nil {
            let style = NSMutableParagraphStyle()
            style.alignment = alignment
            attributes[.paragraphStyle] = style
        }
        return attributes
    }

    @objc(shouldDrawMiniGraphInBounds:settings:)
    public static func shouldDrawMiniGraph(in bounds: NSRect, settings: XRGSettings?) -> Bool {
        !bounds.size.height.isFinite || bounds.size.height < lineHeight(settings) * 2
    }
    @objc(paddedTextRectForBounds:)
    public static func paddedTextRect(for bounds: NSRect) -> NSRect {
        textRect(bounds.insetBy(dx: 3, dy: 0))
    }

    @objc(layoutLeftText:centerText:rightText:inRect:mini:settings:)
    public func layout(leftText: String?, centerText: String?, rightText: String?,
                       in rect: NSRect, mini: Bool, settings: XRGSettings?) {
        let rect = Self.textRect(rect)
        let height = Self.lineHeight(settings)
        var frame = rect
        if mini { frame.origin.y -= 0.5 * (rect.height - height) }
        let inputs = [leftText ?? "", centerText ?? "", rightText ?? ""]
        let attributes = [Self.attributes(settings?.alignLeftAttributes, alignment: .left),
                          Self.attributes(settings?.alignCenterAttributes, alignment: .center),
                          Self.attributes(settings?.alignRightAttributes, alignment: .right)]
        for (index, label) in [leftLabel, centerLabel, rightLabel].enumerated() {
            let lines = inputs[index].components(separatedBy: .newlines)
            let visible: String
            if mini { visible = lines.first ?? "" }
            else {
                let available = floor(rect.height / height)
                let count = available >= CGFloat(lines.count) ? lines.count : Int(max(0, available))
                visible = lines.prefix(count).joined(separator: "\n")
            }
            label.frame = frame
            label.attributedStringValue = NSAttributedString(string: visible, attributes: attributes[index])
            label.fullAccessibilityText = inputs[index]
            label.setAccessibilityRole(.staticText)
            label.setAccessibilityElement(!inputs[index].isEmpty)
        }
    }

    @objc(layoutColumnText:rightText:inRect:mini:settings:)
    public func layoutColumnText(_ leftText: String?, rightText: String?, in rect: NSRect,
                                 mini: Bool, settings: XRGSettings?) {
        layoutColumnText(leftText, centerText: nil, rightText: rightText, in: rect, mini: mini, settings: settings)
    }

    @nonobjc func layoutColumnText(_ leftText: String?, centerText: String?, rightText: String?, in rect: NSRect,
                                  mini: Bool, settings: XRGSettings?) {
        let rect = Self.textRect(rect)
        layout(leftText: leftText, centerText: centerText, rightText: rightText, in: rect, mini: mini, settings: settings)
        let attributes = Self.attributes(settings?.alignRightAttributes, alignment: .right)
        let measured = rightText.map { text in
            text.components(separatedBy: "\n")
                .map { ($0 as NSString).size(withAttributes: attributes).width + 6 }.max() ?? 0
        } ?? 0
        let width = min(measured, rect.width * 0.48)
        let gap = width > 0 ? min(8, max(0, rect.width - width)) : 0
        var leftFrame = leftLabel.frame, rightFrame = rightLabel.frame
        leftFrame.size.width = max(0, rect.width - width - gap)
        rightFrame.origin.x = rect.maxX - width
        rightFrame.size.width = width
        leftLabel.frame = leftFrame
        rightLabel.frame = rightFrame
        for label in [leftLabel, rightLabel] {
            let text = NSMutableAttributedString(attributedString: label.attributedStringValue)
            let style = NSMutableParagraphStyle()
            style.alignment = label.alignment
            style.lineBreakMode = .byTruncatingTail
            style.minimumLineHeight = Self.lineHeight(settings)
            style.maximumLineHeight = style.minimumLineHeight
            text.addAttribute(.paragraphStyle, value: style, range: NSRange(location: 0, length: text.length))
            label.attributedStringValue = text
            label.cell?.wraps = false
            label.cell?.isScrollable = false
            label.lineBreakMode = .byTruncatingTail
        }
    }
}
