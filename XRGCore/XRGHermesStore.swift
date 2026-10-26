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
import SQLite3

@objc(XRGHermesSnapshot)
@objcMembers
public final class XRGHermesSnapshot: NSObject {
    public let input: UInt64
    public let output: UInt64
    public let total: UInt64
    public let cost: Double
    public let models: [String: [String: NSNumber]]
    public let topModel: String?

    fileprivate init(input: UInt64, output: UInt64, cost: Double,
                     models: [String: [String: NSNumber]], topModel: String?) {
        self.input = input
        self.output = output
        total = input + output
        self.cost = cost
        self.models = models
        self.topModel = topModel
    }
}

@objc(XRGHermesStore)
public final class XRGHermesStore: NSObject {
    /// Each call owns its connection and statement. A failed or incomplete
    /// query returns nil, so the caller can retain its last complete snapshot.
    @objc(snapshotAtPath:)
    public static func snapshot(atPath path: String) -> XRGHermesSnapshot? {
        var database: OpaquePointer?
        guard sqlite3_open_v2(path, &database, SQLITE_OPEN_READONLY, nil) == SQLITE_OK else {
            if let database { sqlite3_close(database) }
            return nil
        }
        defer { sqlite3_close(database) }
        // Fail promptly on locks; the next sampling pass will retry.
        sqlite3_busy_timeout(database, 0)
        let sql = """
        SELECT model, SUM(COALESCE(input_tokens,0)), SUM(COALESCE(output_tokens,0)),
               SUM(COALESCE(actual_cost_usd, estimated_cost_usd, 0))
        FROM sessions WHERE model IS NOT NULL AND model != ''
        GROUP BY model ORDER BY model
        """
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(database, sql, -1, &statement, nil) == SQLITE_OK else { return nil }
        defer { sqlite3_finalize(statement) }
        var input: UInt64 = 0
        var output: UInt64 = 0
        var cost = 0.0
        var models: [String: [String: NSNumber]] = [:]
        var topModel: String?
        var mostUsed: UInt64 = 0
        while true {
            let status = sqlite3_step(statement)
            if status == SQLITE_DONE { break }
            guard status == SQLITE_ROW,
                  sqlite3_column_type(statement, 1) == SQLITE_INTEGER,
                  sqlite3_column_type(statement, 2) == SQLITE_INTEGER,
                  let text = sqlite3_column_text(statement, 0) else { return nil }
            let rowInput = sqlite3_column_int64(statement, 1)
            let rowOutput = sqlite3_column_int64(statement, 2)
            let rowCost = sqlite3_column_double(statement, 3)
            guard rowInput >= 0, rowOutput >= 0, rowCost.isFinite, rowCost >= 0 else { return nil }
            let model = String(cString: text)
            let (nextInput, badInput) = input.addingReportingOverflow(UInt64(rowInput))
            let (nextOutput, badOutput) = output.addingReportingOverflow(UInt64(rowOutput))
            let (_, badTotal) = nextInput.addingReportingOverflow(nextOutput)
            guard !badInput, !badOutput, !badTotal, (cost + rowCost).isFinite else { return nil }
            input = nextInput
            output = nextOutput
            cost += rowCost
            models[model] = ["input": NSNumber(value: rowInput), "output": NSNumber(value: rowOutput)]
            let modelTotal = UInt64(rowInput) + UInt64(rowOutput)
            if modelTotal > mostUsed {
                mostUsed = modelTotal
                topModel = model
            }
        }
        return XRGHermesSnapshot(input: input, output: output, cost: cost, models: models, topModel: topModel)
    }
}
