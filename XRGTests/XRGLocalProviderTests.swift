import Foundation
import SQLite3
import Testing
import XRGCore

struct XRGHermesStoreTests {
    private func withDatabase(_ body: (String, OpaquePointer) throws -> Void) throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let path = directory.appendingPathComponent("state ?#%.db").path
        var handle: OpaquePointer?
        #expect(sqlite3_open(path, &handle) == SQLITE_OK)
        let database = try #require(handle)
        defer { sqlite3_close(database) }
        try execute(database, """
        CREATE TABLE sessions(model TEXT, input_tokens INTEGER, output_tokens INTEGER,
                              actual_cost_usd REAL, estimated_cost_usd REAL)
        """)
        try body(path, database)
    }

    private func execute(_ database: OpaquePointer, _ sql: String) throws {
        try #require(sqlite3_exec(database, sql, nil, nil, nil) == SQLITE_OK)
    }

    @Test func aggregatesModelsAndPreservesReportedCosts() throws {
        try withDatabase { path, database in
            try execute(database, """
            INSERT INTO sessions VALUES ('a',10,20,0.0,99.0), ('a',5,6,NULL,2.5),
              ('b',100,1,3.0,99.0), ('',500,500,100,100), (NULL,500,500,100,100)
            """)
            let result = try #require(XRGHermesStore.snapshot(atPath: path))
            #expect(result.input == 115 && result.output == 27 && result.total == 142)
            #expect(result.cost == 5.5 && result.topModel == "b")
            #expect(result.models["a"]?["input"]?.uint64Value == 15)
            #expect(result.models.count == 2)
        }
    }

    @Test func readsUncheckpointedWALWhileWriterRemainsOpen() throws {
        try withDatabase { path, database in
            try execute(database, "PRAGMA journal_mode=WAL")
            try execute(database, "PRAGMA wal_autocheckpoint=0")
            try execute(database, "INSERT INTO sessions VALUES ('wal',11,2,NULL,1.0)")
            #expect(XRGHermesStore.snapshot(atPath: path)?.total == 13)
            try execute(database, "INSERT INTO sessions VALUES ('wal',7,3,2.0,NULL)")
            #expect(XRGHermesStore.snapshot(atPath: path)?.total == 23)
            #expect(XRGHermesStore.snapshot(atPath: path)?.cost == 3)
        }
    }

    @Test func failedQueriesNeverPublishPartialSnapshots() throws {
        try withDatabase { path, database in
            try execute(database, """
            INSERT INTO sessions VALUES ('a',1,2,0,0),
              ('z',9223372036854775807,0,0,0), ('z',1,0,0,0)
            """)
            #expect(XRGHermesStore.snapshot(atPath: path) == nil)
            try execute(database, "DELETE FROM sessions")
            try execute(database, "INSERT INTO sessions VALUES ('a',-1,1,0,0)")
            #expect(XRGHermesStore.snapshot(atPath: path) == nil)
            try execute(database, "DROP TABLE sessions")
            #expect(XRGHermesStore.snapshot(atPath: path) == nil)
        }
    }

    @Test func emptyMissingAndLockedDatabases() throws {
        let missing = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString).path
        #expect(XRGHermesStore.snapshot(atPath: missing) == nil)
        #expect(!FileManager.default.fileExists(atPath: missing))
        try withDatabase { path, database in
            #expect(XRGHermesStore.snapshot(atPath: path)?.total == 0)
            try execute(database, "BEGIN EXCLUSIVE")
            #expect(XRGHermesStore.snapshot(atPath: path) == nil)
            try execute(database, "ROLLBACK")
            #expect(XRGHermesStore.snapshot(atPath: path)?.total == 0)
        }
    }
}

struct XRGLocalProviderParserTests {
    @Test func ollamaModels() {
        let data = Data(#"{"models":[{"name":"model-a","size":123},{"name":"model-b"}]}"#.utf8)
        #expect(XRGLocalProviderParser.modelNames(from: data) == ["model-a", "model-b"])
        #expect(XRGLocalProviderParser.modelNames(from: Data(#"{"models":[]}"#.utf8)) == [])
    }

    @Test(arguments: ["[]", "null", "{}", #"{"models":[null]}"#, #"{"models":[{"name":123}]}"#])
    func malformedOllamaModels(_ text: String) {
        #expect(XRGLocalProviderParser.modelNames(from: Data(text.utf8)) == nil)
    }

    @Test func prometheusValuesWithOptionalTimestampsAndLabels() {
        let snapshot = XRGLocalProviderParser.metrics(from: """
        # HELP ignored
        claude_tokens{type="input",model="two words"} 100
        claude_tokens{type="output"} 25 1234567890
        claude_tokens{type="cache_read"}\t1e2
        claude_cost 0.25
        claude_cost{model="two words"} 0.5 1234567890
        """)
        #expect(snapshot.tokens == 225 && snapshot.cost == 0.75)
    }

    @Test func invalidMetricsAndOverflowAreIgnored() {
        let snapshot = XRGLocalProviderParser.metrics(from: """
        claude_input_tokens -1
        claude_output_tokens NaN
        claude_input_tokens +Inf
        claude_input_tokens 1.5
        claude_input_tokens 18446744073709551615
        claude_output_tokens 1
        claude_cost -3
        claude_cost NaN
        claude_cost 2
        """)
        #expect(snapshot.tokens == UInt64.max && snapshot.cost == 2)
    }

    @Test func localRequestsUseShortTimeout() async {
        let request = XRGURL(timeoutInterval: 2, transport: { request in
            #expect(request.timeoutInterval == 2)
            return Data("ok".utf8)
        })
        request.setURLString("http://localhost:11434/api/tags")
        request.loadURLInBackground()
        let deadline = ContinuousClock.now + .seconds(3)
        while request.isLoading && ContinuousClock.now < deadline {
            try? await Task.sleep(for: .milliseconds(1))
        }
        #expect(request.isDataReady() && request.getData() == Data("ok".utf8))
    }
}
