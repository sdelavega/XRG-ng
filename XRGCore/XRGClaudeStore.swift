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

@objc(XRGClaudeStore)
public final class XRGClaudeStore: NSObject {
    /// Legacy custom monitoring schema, distinct from Claude's JSONL logs.
    /// Read-only open never creates a missing database.
    @objc(snapshotAtPath:)
    public static func snapshot(atPath path: String) -> XRGMetricSnapshot? {
        var database: OpaquePointer?
        guard sqlite3_open_v2(path, &database, SQLITE_OPEN_READONLY, nil) == SQLITE_OK else {
            if let database { sqlite3_close(database) }
            return nil
        }
        defer { sqlite3_close(database) }
        sqlite3_busy_timeout(database, 0)
        let sql = """
        SELECT COALESCE(SUM(tokens_used),0), COALESCE(SUM(estimated_cost),0)
        FROM sessions WHERE tokens_used > 0
        """
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(database, sql, -1, &statement, nil) == SQLITE_OK else { return nil }
        defer { sqlite3_finalize(statement) }
        guard sqlite3_step(statement) == SQLITE_ROW,
              sqlite3_column_type(statement, 0) == SQLITE_INTEGER else { return nil }
        let tokens = sqlite3_column_int64(statement, 0)
        let cost = sqlite3_column_double(statement, 1)
        guard tokens >= 0, cost.isFinite, cost >= 0,
              sqlite3_step(statement) == SQLITE_DONE else { return nil }
        return XRGMetricSnapshot(tokens: UInt64(tokens), cost: cost)
    }
}
