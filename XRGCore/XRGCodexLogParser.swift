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

@objc(XRGCodexLogParser)
public final class XRGCodexLogParser: NSObject {
    private struct Record: Decodable {
        let type: String
        let payload: Payload
        struct Payload: Decodable {
            let type: String
            let info: Info?
        }
        struct Info: Decodable {
            let totalTokenUsage: Usage?
            enum CodingKeys: String, CodingKey {
                case totalTokenUsage = "total_token_usage"
            }
        }
        struct Usage: Decodable {
            let totalTokens: UInt64?
            let inputTokens: UInt64?
            let outputTokens: UInt64?
            enum CodingKeys: String, CodingKey {
                case totalTokens = "total_tokens"
                case inputTokens = "input_tokens"
                case outputTokens = "output_tokens"
            }

            var total: UInt64? {
                if let totalTokens { return totalTokens }
                let (sum, overflow) = (inputTokens ?? 0).addingReportingOverflow(outputTokens ?? 0)
                return overflow ? nil : sum
            }
        }
    }

    /// Each event contains a cumulative session total, so repeated events must
    /// replace the previous value rather than contribute to a running sum.
    public static func total(inLine data: Data) -> UInt64? {
        guard let record = try? JSONDecoder().decode(Record.self, from: data),
              record.type == "event_msg", record.payload.type == "token_count" else { return nil }
        return record.payload.info?.totalTokenUsage?.total
    }

    @objc(totalTokensAtPath:)
    public static func totalTokens(atPath path: String) -> UInt64 {
        guard let handle = FileHandle(forReadingAtPath: path) else { return 0 }
        defer { try? handle.close() }
        var lastTotal: UInt64 = 0
        var line = Data()
        var droppingOversizedLine = false
        // Session logs can grow large. Bound memory even for corrupt files with
        // no newlines; token-count records are far smaller than this limit.
        let maximumLineBytes = 8 * 1024 * 1024
        do {
            while let chunk = try handle.read(upToCount: 64 * 1024), !chunk.isEmpty {
                for byte in chunk {
                    if byte == 10 {
                        if !droppingOversizedLine, let total = total(inLine: line) {
                            lastTotal = total
                        }
                        line.removeAll(keepingCapacity: true)
                        droppingOversizedLine = false
                    } else if !droppingOversizedLine {
                        if line.count < maximumLineBytes {
                            line.append(byte)
                        } else {
                            line.removeAll(keepingCapacity: true)
                            droppingOversizedLine = true
                        }
                    }
                }
            }
            // Preserve compatibility with complete final records lacking LF.
            // A partially written JSON object fails decoding and is ignored.
            if !droppingOversizedLine, let total = total(inLine: line) {
                lastTotal = total
            }
        } catch {
            return 0
        }
        return lastTotal
    }
}
