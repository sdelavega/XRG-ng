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

import Foundation

@objc(XRGCommon) @objcMembers
public final class XRGCommon: NSObject {
    @objc(dampedMaxUsingPreviousMax:currentMax:baseMax:)
    public static func dampedMax(usingPreviousMax previous: CGFloat, currentMax current: CGFloat, baseMax: CGFloat) -> CGFloat {
        max(baseMax, dampedValue(usingPreviousValue: previous, currentValue: current, dampingCoefficient: 0.95))
    }
    @objc(dampedValueUsingPreviousValue:currentValue:)
    public static func dampedValue(usingPreviousValue previous: CGFloat, currentValue current: CGFloat) -> CGFloat {
        dampedValue(usingPreviousValue: previous, currentValue: current, dampingCoefficient: 0.8)
    }
    @objc(dampedValueUsingPreviousValue:currentValue:dampingCoefficient:)
    public static func dampedValue(usingPreviousValue previous: CGFloat, currentValue current: CGFloat,
                                   dampingCoefficient: CGFloat) -> CGFloat {
        previous * dampingCoefficient + current * (1 - dampingCoefficient)
    }
    @objc(formattedStringForBytes:)
    public static func formattedString(forBytes bytes: Double) -> String {
        guard bytes.isFinite else { return "n/a" }
        for (unit, size) in [("P", 1_125_899_906_842_624.0), ("T", 1_099_511_627_776.0),
                             ("G", 1_073_741_824.0), ("M", 1_048_576.0)] {
            if bytes >= size * 100 { return String(format: "%.1f%@", bytes / size, unit) }
            if bytes >= size { return String(format: "%.2f%@", bytes / size, unit) }
        }
        if bytes >= 102_400 { return String(format: "%.0fK", bytes / 1024) }
        if bytes >= 1024 { return String(format: "%.1fK", bytes / 1024) }
        let integer = bytes <= Double(Int.min) ? Int.min : Int(bytes)
        return "\(integer)B"
    }
}
