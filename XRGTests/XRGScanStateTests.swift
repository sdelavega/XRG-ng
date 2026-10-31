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

// Fixtures write each file right before scanning it. Unless a test covers the
// production settle window, caches trust equal stamps at once so cache-hit
// parse counts stay exact.
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

    @Test(arguments: [0,1,2])
    func completeInventoriesRebaselineDiscoveryReplacementTruncationAndMaskedRollback(_ layout:Int) async throws {
        let root=try directory();defer { try? FileManager.default.removeItem(at:root) }
        let names=[("p/a.jsonl","p/b.jsonl"),("2026/10/30/rollout-a.jsonl","2026/10/30/rollout-b.jsonl"),("h/chats/session-a.json","h/chats/session-b.json")][layout]
        let a=root.appendingPathComponent(names.0),b=root.appendingPathComponent(names.1)
        let scan=XRGScanCache(interval:0,settle:.zero),probe=ParseProbe()
        func sweep() async throws -> XRGScanCache.Observation {
            scan.refreshChecked(root:root.path,layout:layout,parse:probe.read)
            try #require(await waitForScan(scan))
            let observation=try #require(scan.completedObservation)
            #expect(!observation.failed)
            return observation
        }
        try write("00010",to:a);let initial=try await sweep()
        try write("00020",to:a);let ordinary=try await sweep()
        #expect(ordinary.source == initial.source && ordinary.totals.tokens == 20)
        try write("10000",to:b);let imported=try await sweep()
        #expect(imported.source != ordinary.source && imported.totals.tokens == 10020)
        #expect(try await sweep().source == imported.source)
        // A per-file decrease must be caught even when another file masks it.
        try write("00005",to:a);try write("20000",to:b)
        let rollback=try await sweep()
        #expect(rollback.source != imported.source && rollback.totals.tokens > imported.totals.tokens)
        try FileManager.default.removeItem(at:b);let removed=try await sweep()
        #expect(removed.source != rollback.source)
        try Data("00099".utf8).write(to:a,options:.atomic);let replaced=try await sweep()
        #expect(replaced.source != removed.source)
        // Same inode, shorter bytes but a larger counter is still a boundary.
        try write("100",to:a);let truncated=try await sweep()
        #expect(truncated.source != replaced.source && truncated.totals.tokens == 100)
    }
    @Test func failedSweepCannotHideABoundaryOrPublishADraftInventory() async throws {
        let root=try directory();defer { try? FileManager.default.removeItem(at:root) }
        let a=root.appendingPathComponent("p/a.jsonl"),b=root.appendingPathComponent("p/b.jsonl")
        try write("10",to:a)
        let scan=XRGScanCache(interval:0,settle:.zero),probe=ParseProbe()
        scan.refreshChecked(root:root.path,layout:0,parse:probe.read);try #require(await waitForScan(scan))
        let original=try #require(scan.completedObservation)
        try write("10000",to:b)
        scan.refreshChecked(root:root.path,layout:0) { path in
            if path.hasSuffix("b.jsonl") { throw CocoaError(.fileReadNoPermission) }
            return probe.read(path)
        }
        try #require(await waitForScan(scan))
        let failed=try #require(scan.completedObservation)
        #expect(failed.failed && failed.totals.tokens == 10 && failed.source != original.source)
        scan.refreshChecked(root:root.path,layout:0,parse:probe.read);try #require(await waitForScan(scan))
        let recovered=try #require(scan.completedObservation)
        #expect(!recovered.failed && recovered.totals.tokens == 10010 && recovered.source != original.source)
    }

    @Test(arguments: [0, 1, 2])
    func cacheUpdatesDeletionAndLayout(_ layout: Int) async throws {
        let root = try directory()
        defer { try? FileManager.default.removeItem(at: root) }
        let relative = ["project/file.jsonl", "2026/10/25/rollout-test.jsonl", "hash/chats/session-test.json"][layout]
        let file = root.appendingPathComponent(relative)
        try write("10", to: file)
        let scan = XRGScanCache(interval: 0, settle: .zero)
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
        let scan = XRGScanCache(interval: 0, settle: .zero)
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
        let scan = XRGScanCache(interval: 0, settle: .zero)
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
        let scan = XRGScanCache(interval: 0, settle: .zero)
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
        let scan = XRGScanCache(interval:0,settle:.zero), probe = ParseProbe()
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
        let scan = XRGScanCache(interval:0,settle:.zero)
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
        let scan = XRGScanCache(interval: 0, settle: .zero)
        let probe = ParseProbe()
        scan.refresh(root: root.path, layout: 0, parse: probe.read)
        #expect(await waitForScan(scan))
        #expect(!scan.hasSnapshot && scan.snapshot.tokens == 0)
    }

    // Rewrites in place with the same size and restores the exact mtime.
    private func rewriteKeepingMtime(_ value: String, at url: URL) throws {
        var old = stat()
        try #require(lstat(url.path, &old) == 0)
        try #require(old.st_size == off_t(value.utf8.count), "rewrite must keep the size")
        let before = try FileManager.default.attributesOfItem(atPath: url.path)[.modificationDate] as? Date
        try Data(value.utf8).write(to: url)
        var times = [timespec(tv_sec: 0, tv_nsec: Int(UTIME_OMIT)), old.st_mtimespec]
        try #require(utimensat(AT_FDCWD, url.path, &times, 0) == 0)
        var new = stat()
        try #require(lstat(url.path, &new) == 0)
        #expect(new.st_ino == old.st_ino && new.st_size == old.st_size)
        #expect(new.st_mtimespec.tv_sec == old.st_mtimespec.tv_sec && new.st_mtimespec.tv_nsec == old.st_mtimespec.tv_nsec)
        #expect(try FileManager.default.attributesOfItem(atPath: url.path)[.modificationDate] as? Date == before)
    }

    // Model a coarse timestamp: the snapshot was read early in a tick and the
    // rewrite landed later in it, so the file reports the cached stamp.
    private func collide(_ scan: XRGScanCache, at url: URL) throws {
        let stamp = try XRGScanCache.stamp(url.path)
        scan.withEntry(url.path) { entry in
            entry.stamp = stamp
            entry.observed = stamp.latest + .milliseconds(1)
        }
    }

    @Test(arguments: [false, true])
    func racyRewritesWithIdenticalSizeAndMtimePublishNewTotalsModelsAndContinuity(_ colliding: Bool) async throws {
        let root = try directory(); defer { try? FileManager.default.removeItem(at: root) }
        let file = root.appendingPathComponent("2026/10/30/rollout-a.jsonl")
        let scan = XRGScanCache(interval: 0)
        func sweep() async throws -> XRGScanCache.Observation {
            // "model:tokens" keeps the size fixed while both values change.
            scan.refreshChecked(root: root.path, layout: 1) { path in
                let parts = try String(contentsOfFile: path, encoding: .utf8).split(separator: ":")
                let tokens = try #require(UInt64(parts[1]))
                return XRGScanTotals(tokens: tokens, input: tokens, output: 0, cost: 0, modelTotals: [String(parts[0]): tokens])
            }
            try #require(await waitForScan(scan))
            let observed = try #require(scan.completedObservation)
            #expect(!observed.failed)
            return observed
        }
        try write("a:100", to: file)
        let first = try await sweep()
        #expect(first.totals.tokens == 100 && first.totals.modelTotals == ["a": 100])

        try rewriteKeepingMtime("b:200", at: file)
        if colliding { try collide(scan, at: file) }
        let grown = try await sweep()
        #expect(grown.totals.tokens == 200 && grown.totals.modelTotals == ["b": 200])
        #expect(grown.source == first.source)

        // Fewer tokens in the same bytes and inode is a new baseline.
        try rewriteKeepingMtime("c:100", at: file)
        if colliding { try collide(scan, at: file) }
        let reset = try await sweep()
        #expect(reset.totals.tokens == 100 && reset.totals.modelTotals == ["c": 100])
        #expect(reset.source != grown.source)
    }

    @Test func racyRewritesRecheckYoungSnapshotsAndNeverRereadSettledOnes() async throws {
        let root = try directory(); defer { try? FileManager.default.removeItem(at: root) }
        let file = root.appendingPathComponent("project/file.jsonl")
        try write("10", to: file)
        let scan = XRGScanCache(interval: 0), probe = ParseProbe()
        func sweep() async throws -> UInt64 {
            scan.refresh(root: root.path, layout: 0, parse: probe.read)
            try #require(await waitForScan(scan))
            return scan.snapshot.tokens
        }
        #expect(try await sweep() == 10 && probe.count == 1)
        // Just written: an equal stamp is not yet proof, so the next poll reads.
        #expect(try await sweep() == 10 && probe.count == 2)
        // Once observed past the settle window, unchanged sweeps do no reads.
        scan.withEntry(file.path) { $0.observed = $0.stamp.latest + XRGScanCache.settle + .seconds(1) }
        for _ in 0..<3 { #expect(try await sweep() == 10) }
        #expect(probe.count == 2)
        // A settled snapshot is still dropped by any visible stamp change.
        try write("200", to: file)
        #expect(try await sweep() == 200 && probe.count == 3)
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
