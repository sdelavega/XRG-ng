import Foundation
import SQLite3
import Testing
import XRGCore

struct XRGClaudeStoreTests {
    private func withDatabase(_ body: (String, OpaquePointer) throws -> Void) throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let path = directory.appendingPathComponent("claude.db").path
        var handle: OpaquePointer?
        try #require(sqlite3_open(path, &handle) == SQLITE_OK)
        let database = try #require(handle)
        defer { sqlite3_close(database) }
        try execute(database, "CREATE TABLE sessions(tokens_used INTEGER, estimated_cost REAL)")
        try body(path, database)
    }

    private func execute(_ database: OpaquePointer, _ sql: String) throws {
        try #require(sqlite3_exec(database, sql, nil, nil, nil) == SQLITE_OK)
    }

    @Test func totalsExcludeNonpositiveRowsAndHandleNullCosts() throws {
        try withDatabase { path, database in
            try execute(database, "INSERT INTO sessions VALUES (10,1.25),(20,NULL),(0,50),(-1,50)")
            let snapshot = try #require(XRGClaudeStore.snapshot(atPath: path))
            #expect(snapshot.tokens == 30 && snapshot.cost == 1.25)
        }
    }

    @Test func emptyAndMissingDatabases() throws {
        let missing = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString).path
        #expect(XRGClaudeStore.snapshot(atPath: missing) == nil)
        #expect(!FileManager.default.fileExists(atPath: missing))
        try withDatabase { path, _ in
            let snapshot = try #require(XRGClaudeStore.snapshot(atPath: path))
            #expect(snapshot.tokens == 0 && snapshot.cost == 0)
        }
    }

    @Test func schemaErrorsLocksAndOverflowReturnFailure() throws {
        try withDatabase { path, database in
            try execute(database, "BEGIN EXCLUSIVE")
            #expect(XRGClaudeStore.snapshot(atPath: path) == nil)
            try execute(database, "ROLLBACK")
            try execute(database, "INSERT INTO sessions VALUES (9223372036854775807,1),(1,1)")
            #expect(XRGClaudeStore.snapshot(atPath: path) == nil)
            try execute(database, "DROP TABLE sessions")
            #expect(XRGClaudeStore.snapshot(atPath: path) == nil)
        }
    }

    @Test func readsLiveWAL() throws {
        try withDatabase { path, database in
            try execute(database, "PRAGMA journal_mode=WAL")
            try execute(database, "PRAGMA wal_autocheckpoint=0")
            try execute(database, "INSERT INTO sessions VALUES (5,1)")
            #expect(XRGClaudeStore.snapshot(atPath: path)?.tokens == 5)
            try execute(database, "INSERT INTO sessions VALUES (7,2)")
            #expect(XRGClaudeStore.snapshot(atPath: path)?.tokens == 12)
        }
    }
}
