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

struct XRGTheme {
    struct Field {
        let colorKey: String
        let alphaKey: String
        let color: NSColor
        let alpha: Double
        let archive: Data
    }

    let fields: [Field]

    init(dictionary: Any?) throws {
        guard let dictionary = dictionary as? NSDictionary else { throw Self.invalidTheme }
        let names = ["background", "graphBG", "graphFG1", "graphFG2", "graphFG3", "border", "text"]
        fields = try names.map { name in
            let colorKey = name + "Color"
            let alphaKey = name + "Transparency"
            guard let data = dictionary[colorKey] as? Data,
                  let number = dictionary[alphaKey] as? NSNumber,
                  CFGetTypeID(number) != CFBooleanGetTypeID(),
                  number.doubleValue.isFinite,
                  (0...1).contains(number.doubleValue) else {
                throw Self.invalidTheme
            }
            let decoded: NSColor?
            do {
                decoded = try NSKeyedUnarchiver.unarchivedObject(ofClass: NSColor.self, from: data)
            } catch {
                throw Self.invalidTheme
            }
            guard let decoded else { throw Self.invalidTheme }
            let color = decoded.withAlphaComponent(CGFloat(number.doubleValue))
            let archive = try NSKeyedArchiver.archivedData(withRootObject: color, requiringSecureCoding: true)
            return Field(colorKey: colorKey, alphaKey: alphaKey, color: color,
                         alpha: number.doubleValue, archive: archive)
        }
    }

    private static var invalidTheme: NSError {
        NSError(domain: "XRGThemeErrorDomain", code: 1, userInfo: [
            NSLocalizedDescriptionKey: NSLocalizedString(
                "The theme must contain valid colors and transparency values between 0 and 1.",
                comment: "Invalid theme error")
        ])
    }
}
