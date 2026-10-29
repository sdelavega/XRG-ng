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
    static let documentKey = "portableThemeDocument"
    static let nameKey = "portableThemeName"

    typealias Builtin = XRGBuiltinTheme

    struct Field {
        let colorKey: String
        let alphaKey: String
        let color: NSColor
        let alpha: Double
        let archive: Data
    }

    let fields: [Field]
    let document: XRGThemeDocument?

    init(dictionary: Any?) throws {
        document = nil
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

    init(data: Data) throws {
        guard data.count <= XRGThemeDocument.byteLimit else { throw Self.invalidTheme }
        if let dictionary = try? PropertyListSerialization.propertyList(from: data, options: [], format: nil),
           let theme = try? Self(dictionary: dictionary) {
            self = theme
        } else {
            let document = try XRGThemeDocument(data: data)
            var dictionary: [String: Any] = [:]
            for (name, rgba) in zip(Self.colorNames, document.colors) {
                let color = NSColor(srgbRed: rgba[0], green: rgba[1], blue: rgba[2], alpha: rgba[3])
                dictionary[name + "Color"] = try NSKeyedArchiver.archivedData(withRootObject: color, requiringSecureCoding: true)
                dictionary[name + "Transparency"] = rgba[3]
            }
            fields = try Self(dictionary: dictionary).fields
            self.document = document
        }
    }

    func portableDocument(name: String, original: XRGThemeDocument?) throws -> XRGThemeDocument {
        let colors = try fields.enumerated().map { index, field -> [Double] in
            if let original {
                let rgba = original.colors[index]
                let rendered = NSColor(srgbRed: rgba[0], green: rgba[1], blue: rgba[2], alpha: rgba[3])
                // Preserve untouched imported doubles rather than repeatedly
                // converting them through a native color picker/color profile.
                if field.color.isEqual(rendered) { return rgba }
            }
            guard let rgb = field.color.usingColorSpace(.sRGB) else { throw Self.invalidTheme }
            let components = [Double(rgb.redComponent), Double(rgb.greenComponent), Double(rgb.blueComponent)]
            guard components.allSatisfy(\.isFinite) else { throw Self.invalidTheme }
            // Like the Linux XTF reader, clip converted wide-gamut colors to
            // portable sRGB. XTF export retains the native color archive.
            return components.map { min(1, max(0, $0)) } + [field.alpha]
        }
        return try XRGThemeDocument(name: original?.name ?? name, colors: colors)
    }

    static func readFile(_ url: URL) throws -> Data {
        guard url.isFileURL, try url.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile == true else { throw invalidTheme }
        let file = try FileHandle(forReadingFrom: url); defer { try? file.close() }
        var data = Data()
        while data.count <= XRGThemeDocument.byteLimit {
            let chunk = try file.read(upToCount: XRGThemeDocument.byteLimit + 1 - data.count) ?? Data()
            if chunk.isEmpty { return data }
            data.append(chunk)
        }
        throw invalidTheme
    }

    private static var invalidTheme: NSError {
        NSError(domain: "XRGThemeErrorDomain", code: 1, userInfo: [
            NSLocalizedDescriptionKey: NSLocalizedString(
                "The theme must contain valid colors and transparency values between 0 and 1.",
                comment: "Invalid theme error")
        ])
    }
}


extension XRGBuiltinTheme {
    /// Keep the existing fourteen-field XTF format and NSColor archive identity.
    @MainActor func dictionary() throws -> [String: Any] {
        var result: [String: Any] = [:]
        for (name, color) in zip(XRGTheme.colorNames, rgba) {
            let nsColor = usesDeviceRGB
                ? NSColor(deviceRed: color[0], green: color[1], blue: color[2], alpha: color[3])
                : NSColor(srgbRed: color[0], green: color[1], blue: color[2], alpha: color[3])
            result[name + "Color"] = try NSKeyedArchiver.archivedData(
                withRootObject: nsColor, requiringSecureCoding: true)
            result[name + "Transparency"] = color[3]
        }
        return result
    }
}
