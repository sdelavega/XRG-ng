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
    static let colorNames = ["background", "graphBG", "graphFG1", "graphFG2", "graphFG3", "border", "text"]

    enum Builtin: String, CaseIterable, Sendable {
        case classic, midnight, ocean, dusk, paper, phosphor

        var name: String {
            switch self {
            case .classic: "Classic"
            case .midnight: "Midnight"
            case .ocean: "Ocean"
            case .dusk: "Dusk"
            case .paper: "Paper"
            case .phosphor: "Phosphor"
            }
        }

        @MainActor private var colors: [NSColor] {
            if self == .classic {
                return [NSColor(deviceRed: 0.05, green: 0.02, blue: 0.08, alpha: 1),
                        NSColor(deviceRed: 0.08, green: 0.04, blue: 0.12, alpha: 1),
                        NSColor(deviceRed: 1, green: 0, blue: 0.6, alpha: 1),
                        NSColor(deviceRed: 0, green: 1, blue: 1, alpha: 1),
                        NSColor(deviceRed: 0.2, green: 1, blue: 0.2, alpha: 1),
                        NSColor(deviceRed: 0.5, green: 0, blue: 0.5, alpha: 1),
                        NSColor(deviceRed: 0.6, green: 1, blue: 1, alpha: 1)]
            }
            let palette: [UInt32] = switch self {
            case .midnight: [0x0B1220, 0x111B2B, 0x1D4ED8, 0x0F766E, 0x6D28D9, 0x334155, 0xE5EEFC]
            case .ocean: [0x071D2B, 0x0B2A3C, 0x0369A1, 0x0F766E, 0x7C3AED, 0x23506B, 0xE0F2FE]
            case .dusk: [0x21182F, 0x2D223D, 0x6B3F80, 0x2F6269, 0x804B39, 0x584668, 0xFFF1E6]
            case .paper: [0xF4F5F7, 0xFFFFFF, 0x93C5FD, 0x99F6E4, 0xFDE68A, 0xCBD5E1, 0x152536]
            case .phosphor: [0x07110B, 0x091A10, 0x166534, 0x3F6212, 0x065F46, 0x245437, 0xBBF7D0]
            case .classic: [] // Handled above to retain the original device-RGB values.
            }
            return palette.map { value in
                NSColor(srgbRed: CGFloat((value >> 16) & 0xff) / 255,
                        green: CGFloat((value >> 8) & 0xff) / 255, blue: CGFloat(value & 0xff) / 255, alpha: 1)
            }
        }

        /// Use the existing fourteen-field XTF format so presets can be customized and exported.
        @MainActor func dictionary() throws -> [String: Any] {
            let alphas: [Double] = self == .classic ? [0.9, 0.9, 1, 1, 1, 0.4, 1] : Array(repeating: 1, count: 7)
            var result: [String: Any] = [:]
            for (index, pair) in zip(XRGTheme.colorNames, colors).enumerated() {
                result[pair.0 + "Color"] = try NSKeyedArchiver.archivedData(
                    withRootObject: pair.1.withAlphaComponent(alphas[index]), requiringSecureCoding: true)
                result[pair.0 + "Transparency"] = alphas[index]
            }
            return result
        }
    }

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
        fields = try Self.colorNames.map { name in
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
