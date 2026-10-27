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

#if canImport(ObjectiveC)
@objc(XRGMetricSnapshot)
#endif
#if canImport(ObjectiveC)
@objcMembers
#endif
public final class XRGMetricSnapshot: NSObject {
    public let tokens: UInt64
    public let cost: Double
    init(tokens: UInt64, cost: Double) {
        self.tokens = tokens
        self.cost = cost
    }
}

#if canImport(ObjectiveC)
@objc(XRGLocalProviderParser)
#endif
public final class XRGLocalProviderParser: NSObject {
    private struct Models: Decodable {
        let models: [Model]
        struct Model: Decodable { let name: String }
    }

    #if canImport(ObjectiveC)
    @objc(modelNamesFromData:)
    #endif
    public static func modelNames(from data: Data) -> [String]? {
        guard let response = try? JSONDecoder().decode(Models.self, from: data) else { return nil }
        return response.models.map(\.name)
    }

    /// Prometheus samples have a name/label set, value, and optional timestamp.
    /// Whitespace inside quoted labels is not a field separator.
    #if canImport(ObjectiveC)
    @objc(metricsFromText:)
    #endif
    public static func metrics(from text: String) -> XRGMetricSnapshot {
        var tokens: UInt64 = 0
        var cost = 0.0
        for rawLine in text.split(separator: "\n") {
            let line = rawLine.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !line.isEmpty, !line.hasPrefix("#") else { continue }
            var quoted = false
            var escaped = false
            var braces = 0
            var separator: String.Index?
            for index in line.indices {
                let character = line[index]
                if escaped { escaped = false; continue }
                if quoted && character == "\\" { escaped = true; continue }
                if character == "\"" { quoted.toggle(); continue }
                if !quoted {
                    if character == "{" { braces += 1 }
                    if character == "}" { braces -= 1 }
                    if character.isWhitespace && braces == 0 { separator = index; break }
                }
            }
            guard let separator, !quoted, braces == 0,
                  let valueText = line[separator...].split(whereSeparator: \.isWhitespace).first,
                  let value = Double(valueText), value.isFinite, value >= 0 else { continue }
            let metric = line[..<separator]
            if metric.contains("token_usage") || metric.contains("tokens") {
                guard ["input", "output", "cache_read", "cache_create"].contains(where: { metric.contains($0) }),
                      let count = UInt64(String(valueText)) ?? UInt64(exactly: value) else { continue }
                let (sum, overflow) = tokens.addingReportingOverflow(count)
                if !overflow { tokens = sum }
            } else if metric.contains("cost"), (cost + value).isFinite {
                cost += value
            }
        }
        return XRGMetricSnapshot(tokens: tokens, cost: cost)
    }
}
