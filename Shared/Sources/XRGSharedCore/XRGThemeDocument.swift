// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Stephen de la Vega.
import Foundation

/// Portable sRGB palette, in window/background/series 1–3/border/text order.
/// This is the existing Linux theme schema; it contains no monitoring settings.
public struct XRGThemeDocument: Codable, Equatable, Sendable {
    public static let byteLimit = 128 * 1024
    public let format: String
    public let version: UInt32
    public let name: String
    public let colors: [[Double]]

    public init(name: String, colors: [[Double]]) throws {
        format = "xrg-ng-theme"; version = 1; self.name = name; self.colors = colors
        try validate()
    }

    public init(data: Data) throws {
        guard data.count <= Self.byteLimit, String(data: data, encoding: .utf8) != nil,
              !data.starts(with: [0xef, 0xbb, 0xbf]) else { throw Self.invalid }
        // Foundation's decoder accepts duplicate keys and integral floating-point
        // versions. Reject both to match serde's strict document schema.
        let fields = try Self.rootFields(data)
        guard Set(fields.keys) == ["format", "version", "name", "colors"],
              fields["version"] == Data("1".utf8) else { throw Self.invalid }
        self = try JSONDecoder().decode(Self.self, from: data)
        try validate()
    }

    public func encoded() throws -> Data {
        try validate()
        let encoder = JSONEncoder(); encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        var data = try encoder.encode(self); data.append(0x0a)
        guard data.count <= Self.byteLimit else { throw Self.invalid }
        return data
    }

    private func validate() throws {
        let scalars = name.unicodeScalars
        guard format == "xrg-ng-theme", version == 1, !scalars.isEmpty, scalars.count <= 80,
              scalars.first?.properties.isWhitespace == false, scalars.last?.properties.isWhitespace == false,
              !scalars.contains(where: { $0.properties.generalCategory == .control }),
              colors.count == 7, colors.allSatisfy({ $0.count == 4 && $0.allSatisfy { $0.isFinite && (0...1).contains($0) } })
        else { throw Self.invalid }
    }

    private static var invalid: NSError {
        NSError(domain: "XRGThemeDocument", code: 1, userInfo: [NSLocalizedDescriptionKey:
            "Use an xrg-ng-theme version 1 JSON palette with a printable name and seven RGBA colors between 0 and 1 (128 KiB maximum)."])
    }

    /// Locate root member boundaries only; JSONDecoder validates JSON syntax and
    /// typed values. Strings/arrays/objects are tracked so embedded commas, escaped
    /// keys and braces in a theme name cannot hide a duplicate or unknown member.
    private static func rootFields(_ data: Data) throws -> [String: Data] {
        let bytes = Array(data)
        let whitespace: Set<UInt8> = [0x20, 0x09, 0x0a, 0x0d]
        guard bytes.first(where: { !whitespace.contains($0) }) == 0x7b else { throw invalid }
        var fields: [String: Data] = [:], key: String?
        var depth = 0, stringStart: Int?, escaped = false, wantsKey = false, valueStart: Int?
        func finish(_ end: Int) throws {
            guard let key, let start = valueStart else { return }
            guard fields[key] == nil else { throw invalid }
            fields[key] = Data(bytes[start..<end].drop(while: { whitespace.contains($0) })
                .reversed().drop(while: { whitespace.contains($0) }).reversed())
        }
        for (index, byte) in bytes.enumerated() {
            if let start = stringStart {
                if escaped { escaped = false }
                else if byte == 0x5c { escaped = true }
                else if byte == 0x22 {
                    if depth == 1 && wantsKey {
                        key = try JSONDecoder().decode(String.self, from: Data(bytes[start...index]))
                        wantsKey = false
                    }
                    stringStart = nil
                }
                continue
            }
            switch byte {
            case 0x22: stringStart = index
            case 0x7b, 0x5b: depth += 1; if depth == 1 { wantsKey = true }
            case 0x7d, 0x5d:
                if depth == 1 { try finish(index) }; depth -= 1
            case 0x3a: if depth == 1 { valueStart = index + 1 }
            case 0x2c:
                if depth == 1 { try finish(index); key = nil; valueStart = nil; wantsKey = true }
            default: break
            }
        }
        return fields
    }
}
