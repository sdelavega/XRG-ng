import Foundation
import Testing
import XRGCore

private actor Requests {
    var pending: [String: CheckedContinuation<Data, Error>] = [:]
    func fetch(_ request: URLRequest) async throws -> Data {
        #expect(request.timeoutInterval == 60)
        #expect(request.cachePolicy == .reloadIgnoringLocalCacheData)
        let url = try #require(request.url)
        return try await withCheckedThrowingContinuation { pending[url.path] = $0 }
    }
    func contains(_ path: String) -> Bool { pending[path] != nil }
    func succeed(_ path: String, _ value: String) {
        pending.removeValue(forKey: path)?.resume(returning: Data(value.utf8))
    }
}

private func eventually(_ condition: () async -> Bool) async -> Bool {
    let deadline = ContinuousClock.now + .seconds(3)
    while ContinuousClock.now < deadline {
        if await condition() { return true }
        try? await Task.sleep(for: .milliseconds(1))
    }
    return false
}

struct XRGNetworkingTests {
    @Test func successAndReset() async {
        let requests = Requests()
        let client = XRGURL(transport: { try await requests.fetch($0) })
        client.setURLString("https://example.invalid/first")
        client.loadURLInBackground()
        #expect(client.isLoading)
        #expect(await eventually { await requests.contains("/first") })
        await requests.succeed("/first", "weather")
        #expect(await eventually { client.isDataReady() })
        #expect(client.getData() == Data("weather".utf8))
        #expect(!client.didErrorOccur())
        client.cancelLoading()
        #expect(!client.isLoading && !client.isDataReady() && client.getData() == nil)
    }

    @Test func invalidURLAndTransportFailure() async {
        let client = XRGURL(transport: { _ in throw URLError(.notConnectedToInternet) })
        client.setURLString("relative/path")
        client.loadURLInBackground()
        #expect(!client.haveGoodURL() && client.didErrorOccur() && !client.isLoading)
        client.setURLString("https://example.invalid")
        client.loadURLInBackground()
        #expect(await eventually { !client.isLoading })
        #expect(client.didErrorOccur() && !client.isDataReady() && client.getData() == nil)
    }

    @Test func replacedRequestCannotPublishOldData() async {
        let requests = Requests()
        let client = XRGURL(transport: { try await requests.fetch($0) })
        client.setURLString("https://example.invalid/old")
        client.loadURLInBackground()
        #expect(await eventually { await requests.contains("/old") })
        client.setURLString("https://example.invalid/new")
        client.loadURLInBackground()
        #expect(await eventually { await requests.contains("/new") })
        await requests.succeed("/old", "obsolete")
        // The replacement remains in flight while the canceled transport
        // deliberately delivers its late response.
        try? await Task.sleep(for: .milliseconds(50))
        #expect(client.isLoading && !client.isDataReady() && client.getData() == nil)
        await requests.succeed("/new", "current")
        #expect(await eventually { client.isDataReady() })
        #expect(client.getData() == Data("current".utf8))
    }

    @Test func cancelledRequestCannotPublishLateData() async {
        let requests = Requests()
        let client = XRGURL(transport: { try await requests.fetch($0) })
        client.setURLString("https://example.invalid/cancel")
        client.loadURLInBackground()
        #expect(await eventually { await requests.contains("/cancel") })
        client.cancelLoading()
        await requests.succeed("/cancel", "late")
        try? await Task.sleep(for: .milliseconds(50))
        #expect(!client.isLoading && !client.isDataReady() && !client.didErrorOccur())
        #expect(client.getData() == nil)
    }
}

struct XRGCodexLogParserTests {
    private func record(_ usage: String) -> String {
        #"{"type":"event_msg","payload":{"type":"token_count","info":{"total_token_usage":\#(usage)}}}"#
    }

    @Test func cumulativeTotalsAndFallback() {
        #expect(XRGCodexLogParser.total(inLine: Data(record(#"{"total_tokens":123}"#).utf8)) == 123)
        #expect(XRGCodexLogParser.total(inLine: Data(record(#"{"input_tokens":100,"output_tokens":23}"#).utf8)) == 123)
        #expect(XRGCodexLogParser.total(inLine: Data(record(#"{"total_tokens":0,"input_tokens":100}"#).utf8)) == 0)
    }

    @Test(arguments: [
        "[]", "null", #"{"type":true}"#,
        #"{"type":"event_msg","payload":[]}"#,
        #"{"type":"event_msg","payload":{"type":"token_count","info":null}}"#
    ])
    func malformedRecordsAreIgnored(_ json: String) {
        #expect(XRGCodexLogParser.total(inLine: Data(json.utf8)) == nil)
    }

    @Test(arguments: [
        #"{"total_tokens":-1}"#, #"{"total_tokens":true}"#,
        #"{"total_tokens":"123"}"#, #"{"total_tokens":1.5}"#,
        #"{"input_tokens":18446744073709551615,"output_tokens":1}"#
    ])
    func invalidCountsAreIgnored(_ usage: String) {
        #expect(XRGCodexLogParser.total(inLine: Data(record(usage).utf8)) == nil)
    }

    @Test func streamingDuplicatesPartialWritesAndTruncation() throws {
        let file = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: file) }
        let first = record(#"{"total_tokens":10}"#)
        let second = record(#"{"total_tokens":25}"#)
        try Data((first + "\n" + first + "\r\n" + second + "\n{\"type\":").utf8).write(to: file)
        #expect(XRGCodexLogParser.totalTokens(atPath: file.path) == 25)
        try Data(first.utf8).write(to: file)
        #expect(XRGCodexLogParser.totalTokens(atPath: file.path) == 10)
        try FileManager.default.removeItem(at: file)
        #expect(XRGCodexLogParser.totalTokens(atPath: file.path) == 0)
    }

    @Test func recordsAcrossChunksAndOversizedLineRecovery() throws {
        let file = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: file) }
        let valid = record(#"{"total_tokens":72}"#)
        var data = Data(repeating: 32, count: 65_520)
        data.append(contentsOf: (valid + "\n").utf8)
        data.append(Data(repeating: 120, count: 8 * 1024 * 1024 + 1))
        data.append(contentsOf: ("\n" + valid).utf8)
        try data.write(to: file)
        #expect(XRGCodexLogParser.totalTokens(atPath: file.path) == 72)
    }
}
