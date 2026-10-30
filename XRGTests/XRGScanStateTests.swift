import Foundation
import Testing
@testable import XRGCore

private final class ParseProbe: @unchecked Sendable {
    private let lock = NSLock()
    private var calls = 0
    var count: Int { lock.withLock { calls } }
    func read(_ path: String) -> XRGScanTotals {
        lock.withLock { calls += 1 }
        let value = (try? String(contentsOfFile: path, encoding: .utf8)).flatMap(UInt64.init) ?? 0
        return XRGScanTotals(tokens: value, input: value, output: 0, cost: Double(value) / 100)
    }
}

// Signals from synchronous scan callbacks without blocking the async test's thread.
private final class ScanSignal: @unchecked Sendable {
    private let lock = NSLock()
    private var signaled = false

    func signal() {
        lock.withLock { signaled = true }
    }

    func wait() async throws -> Bool {
        let deadline = ContinuousClock.now + .seconds(3)
        while !lock.withLock({ signaled }) {
            guard ContinuousClock.now < deadline else { return false }
            try await Task.sleep(for: .milliseconds(1))
        }
        return true
    }
}

private func waitForScan(_ scan: XRGScanCache) async -> Bool {
    let deadline = ContinuousClock.now + .seconds(3)
    while scan.isScanning && ContinuousClock.now < deadline {
        try? await Task.sleep(for: .milliseconds(1))
    }
    return !scan.isScanning
}

struct XRGScanStateTests {
    private func directory() throws -> URL {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        return root
    }
    private func write(_ value: String, to url: URL) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(value.utf8).write(to: url)
    }

    @Test(arguments: [0, 1, 2])
    func cacheUpdatesDeletionAndLayout(_ layout: Int) async throws {
        let root = try directory()
        defer { try? FileManager.default.removeItem(at: root) }
        let relative = ["project/file.jsonl", "2026/10/25/rollout-test.jsonl", "hash/chats/session-test.json"][layout]
        let file = root.appendingPathComponent(relative)
        try write("10", to: file)
        let scan = XRGScanCache(interval: 0)
        let probe = ParseProbe()
        scan.refresh(root: root.path, layout: layout, parse: probe.read)
        #expect(await waitForScan(scan))
        #expect(scan.hasSnapshot && scan.snapshot.tokens == 10 && probe.count == 1)
        scan.refresh(root: root.path, layout: layout, parse: probe.read)
        #expect(await waitForScan(scan))
        #expect(probe.count == 1)
        let date = try #require(FileManager.default.attributesOfItem(atPath: file.path)[.modificationDate] as? Date)
        try write("200", to: file)
        try FileManager.default.setAttributes([.modificationDate: date], ofItemAtPath: file.path)
        scan.refresh(root: root.path, layout: layout, parse: probe.read)
        #expect(await waitForScan(scan))
        #expect(scan.snapshot.tokens == 200 && probe.count == 2)
        try FileManager.default.removeItem(at: file)
        scan.refresh(root: root.path, layout: layout, parse: probe.read)
        #expect(await waitForScan(scan))
        #expect(scan.snapshot.tokens == 0 && scan.snapshot.cost == 0)
    }

    @Test func throttleAndMissingProvider() async throws {
        let root = try directory()
        defer { try? FileManager.default.removeItem(at: root) }
        try write("7", to: root.appendingPathComponent("project/file.jsonl"))
        let scan = XRGScanCache(interval: 3600)
        let probe = ParseProbe()
        scan.refresh(root: root.path, layout: 0, parse: probe.read)
        #expect(await waitForScan(scan))
        try write("12", to: root.appendingPathComponent("project/file.jsonl"))
        scan.refresh(root: root.path, layout: 0, parse: probe.read)
        #expect(!scan.isScanning && scan.snapshot.tokens == 7 && probe.count == 1)
        scan.refresh(root: root.appendingPathComponent("missing").path, layout: 0, parse: probe.read)
        #expect(await waitForScan(scan))
        #expect(scan.hasSnapshot && scan.snapshot.tokens == 0)
    }

    @Test func scanFailureRetainsCompleteSnapshot() async throws {
        let root = try directory()
        defer { try? FileManager.default.removeItem(at: root) }
        try write("7", to: root.appendingPathComponent("project/file.jsonl"))
        let scan = XRGScanCache(interval: 0)
        let probe = ParseProbe()
        scan.refresh(root: root.path, layout: 0, parse: probe.read)
        #expect(await waitForScan(scan))
        // A matching filename that is a directory cannot be parsed as a log.
        try FileManager.default.createDirectory(at: root.appendingPathComponent("project/bad.jsonl"), withIntermediateDirectories: true)
        scan.refresh(root: root.path, layout: 0, parse: probe.read)
        #expect(await waitForScan(scan))
        #expect(scan.snapshot.tokens == 7)
    }

    @Test func changingFileIsRetriedWithoutCachingPartialData() async throws {
        let root = try directory()
        defer { try? FileManager.default.removeItem(at: root) }
        let file = root.appendingPathComponent("project/file.jsonl")
        try write("1", to: file)
        let scan = XRGScanCache(interval: 0)
        scan.refresh(root: root.path, layout: 0) { path in
            try? Data("100".utf8).write(to: URL(fileURLWithPath: path))
            return XRGScanTotals(tokens: 1, input: 1, output: 0, cost: 0)
        }
        #expect(await waitForScan(scan))
        #expect(scan.snapshot.tokens == 0)
        let probe = ParseProbe()
        scan.refresh(root: root.path, layout: 0, parse: probe.read)
        #expect(await waitForScan(scan))
        #expect(scan.snapshot.tokens == 100)
    }

    @Test func overlappingScansAndResetRejectOldPublication() async throws {
        let root = try directory()
        defer { try? FileManager.default.removeItem(at: root) }
        try write("10", to: root.appendingPathComponent("project/file.jsonl"))
        let gate = DispatchSemaphore(value: 0)
        defer { gate.signal() }
        let started = ScanSignal()
        let returned = ScanSignal()
        let scan = XRGScanCache(interval: 0)
        let probe = ParseProbe()
        scan.refresh(root: root.path, layout: 0) { path in
            let value = probe.read(path)
            started.signal()
            _ = gate.wait(timeout: .now() + 3)
            returned.signal()
            return value
        }
        try #require(await started.wait())
        for _ in 0..<10 { scan.refresh(root: root.path, layout: 0, parse: probe.read) }
        #expect(probe.count == 1)
        scan.reset()
        #expect(!scan.hasSnapshot && scan.snapshot.tokens == 0)
        gate.signal()
        try #require(await returned.wait())
        try? await Task.sleep(for: .milliseconds(30))
        #expect(!scan.hasSnapshot && scan.snapshot.tokens == 0)
        scan.refresh(root: root.path, layout: 0, parse: probe.read)
        #expect(await waitForScan(scan))
        #expect(scan.snapshot.tokens == 10)
    }

    @Test func checkedParseFailuresRetainCompleteSnapshotsAndRetryTheSameStamp() async throws {
        let root = try directory(); defer { try? FileManager.default.removeItem(at:root) }
        let file = root.appendingPathComponent("2026/10/30/rollout-fixture.jsonl")
        try write("10",to:file)
        let scan = XRGScanCache(interval:0), probe = ParseProbe()
        scan.refreshChecked(root:root.path,layout:1,parse:probe.read)
        #expect(await waitForScan(scan))
        #expect(scan.completedSnapshot?.tokens == 10 && !scan.lastScanFailed)
        try write("20",to:file)
        scan.refreshChecked(root:root.path,layout:1) { _ in throw CocoaError(.fileReadTooLarge) }
        #expect(await waitForScan(scan))
        #expect(scan.completedSnapshot?.tokens == 10 && scan.lastScanFailed)
        scan.refreshChecked(root:root.path,layout:1,parse:probe.read)
        #expect(await waitForScan(scan))
        #expect(scan.completedSnapshot?.tokens == 20 && probe.count == 2 && !scan.lastScanFailed)
    }

    @Test func codexAggregateModelLimitRetainsAllProviderTokens() async throws {
        let root = try directory(); defer { try? FileManager.default.removeItem(at:root) }
        try write("a",to:root.appendingPathComponent("2026/10/30/rollout-a.jsonl"))
        try write("b",to:root.appendingPathComponent("2026/10/30/rollout-b.jsonl"))
        let scan = XRGScanCache(interval:0)
        scan.refreshChecked(root:root.path,layout:1) { path in
            let prefix = path.hasSuffix("rollout-a.jsonl") ? "a" : "b"
            let models = Dictionary(uniqueKeysWithValues:(0..<255).map { ("\(prefix)\($0)",UInt64(1)) })
            return XRGScanTotals(tokens:255,input:0,output:0,cost:0,modelTotals:models)
        }
        #expect(await waitForScan(scan))
        let sample = try #require(scan.completedSnapshot)
        #expect(sample.tokens == 510 && sample.modelTotals.count == 255)
        #expect(sample.modelTotals.keys.allSatisfy { $0.hasPrefix("a") })
    }

    @Test func aggregateOverflowDoesNotPublishWrappedTotals() async throws {
        let root = try directory()
        defer { try? FileManager.default.removeItem(at: root) }
        try write(String(UInt64.max), to: root.appendingPathComponent("project/a.jsonl"))
        try write("1", to: root.appendingPathComponent("project/b.jsonl"))
        let scan = XRGScanCache(interval: 0)
        let probe = ParseProbe()
        scan.refresh(root: root.path, layout: 0, parse: probe.read)
        #expect(await waitForScan(scan))
        #expect(!scan.hasSnapshot && scan.snapshot.tokens == 0)
    }
}

struct XRGRateTrackerTests {
    @Test func baselinesElapsedTimeAndCounterReset() {
        let tracker = XRGRateTracker()
        #expect(tracker.sample(counter: 1000, key: "a", time: 1).delta == 0)
        let next = tracker.sample(counter: 1100, key: "a", time: 3)
        #expect(next.delta == 100 && next.rate == 50)
        #expect(tracker.sample(counter: 10, key: "a", time: 4).rate == 0)
        #expect(tracker.sample(counter: 20, key: "a", time: 5).rate == 10)
        #expect(tracker.sample(counter: 500, key: "b", time: 5).rate == 0)
        tracker.reset()
        #expect(tracker.sample(counter: 999, key: "a", time: 6).rate == 0)
    }

    @Test func saturationAndInvalidTimes() {
        let tracker = XRGRateTracker()
        _ = tracker.sample(counter: 0, key: "a", time: 1)
        #expect(tracker.sample(counter: 100, key: "a", time: 1).delta == 0)
        #expect(tracker.sample(counter: 100, key: "a", time: .nan).delta == 0)
        #expect(tracker.sample(counter: .max, key: "a", time: 2).rate == UInt32.max)
    }

    @Test func costRateRebasesAndRejectsInvalidSamples() {
        let tracker = XRGRateTracker()
        #expect(tracker.sampleCost(100, time: 1) == 0)
        #expect(tracker.sampleCost(104, time: 3) == 2)
        #expect(tracker.sampleCost(1, time: 4) == 0)
        #expect(tracker.sampleCost(.infinity, time: 5) == 0)
        #expect(tracker.sampleCost(999, time: 3) == 0)
        #expect(tracker.sampleCost(5, time: 6) == 2)
    }
}
