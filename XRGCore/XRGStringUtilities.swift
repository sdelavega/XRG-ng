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

@objc(XRGStringUtilities) @objcMembers
public final class XRGStringUtilities: NSObject {
    /// The old category considered only empty, zero, and case-insensitive "no" false.
    public static func legacyBoolValue(_ value: String) -> Bool {
        !value.isEmpty && value != "0" && value.lowercased() != "no"
    }
    /// Removes complete angle-bracket spans; leaves entities and unfinished tags intact.
    @objc(stringWithoutXMLTags:)
    public static func stringWithoutXMLTags(_ value: String) -> String {
        let scalars = value.unicodeScalars
        var cursor = scalars.startIndex
        var result = ""
        while let open = scalars[cursor...].firstIndex(of: "<"),
              let close = scalars[open...].firstIndex(of: ">") {
            result.unicodeScalars.append(contentsOf: scalars[cursor..<open])
            cursor = scalars.index(after: close)
        }
        result.unicodeScalars.append(contentsOf: scalars[cursor...])
        return result
    }
}

public extension NSString {
    @objc var stringWithoutXMLTags: String { XRGStringUtilities.stringWithoutXMLTags(self as String) }
}
