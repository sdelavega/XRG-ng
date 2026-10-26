import Foundation
import Testing
import XRGCore

struct XRGProviderLogParserTests {
    private func withFile(_ contents: String, extension suffix: String = "jsonl",
                          body: (String) throws -> Void) throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString).appendingPathExtension(suffix)
        defer { try? FileManager.default.removeItem(at: url) }
        try Data(contents.utf8).write(to: url)
        try body(url.path)
    }

    @Test func claudeCacheTokensAndModels() throws {
        let text = """
        {"message":{"model":"model-a","usage":{"input_tokens":10,"cache_creation_input_tokens":20,"cache_read_input_tokens":30,"output_tokens":4}}}
        {"message":{"usage":{"output_tokens":6}}}
        """
        try withFile(text) { path in
            var models: [String?] = []
            var inputs: [UInt64] = []
            let totals = XRGProviderLogParser.parseClaude(atPath: path) { model, input, _ in
                models.append(model)
                inputs.append(input)
            }
            #expect(totals.input == 60 && totals.output == 10 && totals.total == 70)
            #expect(models == ["model-a", nil])
            #expect(inputs == [60, 0])
        }
    }

    @Test(arguments: ["true", "-1", "1.5", "\"12\"", "18446744073709551616"])
    func claudeRejectsInvalidCounts(_ value: String) throws {
        try withFile(#"{"message":{"usage":{"input_tokens":\#(value)}}}"#) { path in
            var calls = 0
            let totals = XRGProviderLogParser.parseClaude(atPath: path) { _, _, _ in calls += 1 }
            #expect(totals.total == 0 && calls == 0)
        }
    }

    @Test func claudeSkipsMalformedRecordsAndOverflowAtomically() throws {
        let text = """
        []
        {"message":[]}
        {"message":{"usage":{"input_tokens":18446744073709551615,"cache_read_input_tokens":1}}}
        {"message":{"usage":{"input_tokens":10,"output_tokens":5}}}
        {"message":{"usage":{"input_tokens":18446744073709551615}}}
        {"message":
        """
        try withFile(text) { path in
            var calls = 0
            let totals = XRGProviderLogParser.parseClaude(atPath: path) { _, _, _ in calls += 1 }
            #expect(totals.input == 10 && totals.output == 5 && totals.total == 15)
            #expect(calls == 1)
        }
    }

    @Test func geminiJSONLExplicitTotalAndFallback() throws {
        let text = """
        {"model":"a","tokens":{"input":3,"output":2,"total":12}}
        {"tokens":{"input":4,"output":1,"total":0}}
        {"model":"b","tokens":{"output":7}}
        """
        try withFile(text) { path in
            var models: [String?] = []
            let totals = XRGProviderLogParser.parseGemini(atPath: path) { model, _, _ in models.append(model) }
            #expect(totals.input == 7 && totals.output == 10 && totals.total == 24)
            #expect(models == ["a", nil, "b"])
        }
    }

    @Test func geminiLegacySessionSkipsBadMessagesAndUsesSessionModel() throws {
        let text = """
        {"model":"session-model","messages":[
          null, [], {"tokens":{"input":true}},
          {"model":"other","tokens":{"input":10,"output":5}},
          {"tokens":{"output":2}}
        ]}
        """
        try withFile(text, extension: "json") { path in
            var models: [String?] = []
            let totals = XRGProviderLogParser.parseGemini(atPath: path) { model, _, _ in models.append(model) }
            #expect(totals.input == 10 && totals.output == 7 && totals.total == 17)
            #expect(models == ["session-model", "session-model"])
        }
    }

    @Test func geminiOverflowAndInvalidRootAreIgnored() throws {
        let text = """
        null
        {"tokens":{"input":18446744073709551615,"output":1}}
        {"tokens":{"total":-1}}
        {"tokens":{"input":2,"output":3}}
        """
        try withFile(text) { path in
            var calls = 0
            let totals = XRGProviderLogParser.parseGemini(atPath: path) { _, _, _ in calls += 1 }
            #expect(totals.total == 5 && calls == 1)
        }
    }

    @Test func missingFilesReturnZeroWithoutCostCallbacks() {
        let path = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString).path
        let claude = XRGProviderLogParser.parseClaude(atPath: path) { _, _, _ in Issue.record("Unexpected callback") }
        let gemini = XRGProviderLogParser.parseGemini(atPath: path) { _, _, _ in Issue.record("Unexpected callback") }
        #expect(claude.total == 0 && gemini.total == 0)
    }

    @Test func streamingHandlesChunksCRLFAndOversizedLines() throws {
        let valid = #"{"message":{"usage":{"input_tokens":3}}}"#
        let text = String(repeating: " ", count: 65_520) + valid + "\r\n"
            + String(repeating: "x", count: 8 * 1024 * 1024 + 1) + "\n" + valid
        try withFile(text) { path in
            let totals = XRGProviderLogParser.parseClaude(atPath: path) { _, _, _ in }
            #expect(totals.total == 6)
        }
    }
}
