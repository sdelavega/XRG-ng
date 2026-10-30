import AppKit
import Foundation
import Testing
@testable import XRGCore

private final class GPUReadGate: @unchecked Sendable {
    private let lock = NSLock(), gate = DispatchSemaphore(value: 0)
    private var count = 0, mainThread = false, failed = false
    private var timestamp = 123.0
    private let sample = XRGGPUSample(id: 1, vendor: "Apple", total: 100, free: 60, wait: nil, utilization: 50,
        memoryReading: XRGHardwareReading(id: "memory", name: "Fixture", value: 40, capacity: 100))
    var reads: Int { lock.lock(); defer { lock.unlock() }; return count }
    var readOnMain: Bool { lock.lock(); defer { lock.unlock() }; return mainThread }
    var time: Double { lock.lock(); defer { lock.unlock() }; return timestamp }
    func configure(time: Double, failed: Bool = false) { lock.lock(); timestamp = time; self.failed = failed; lock.unlock() }
    func read() -> [XRGGPUSample]? {
        lock.lock(); count += 1; mainThread = mainThread || Thread.isMainThread; lock.unlock()
        gate.wait()
        lock.lock(); defer { lock.unlock() }; return failed ? nil : [sample]
    }
    func release(_ count: Int = 1) { for _ in 0..<count { gate.signal() } }
}

@Suite @MainActor
struct XRGGPUMinerTests {
    private func eventually(_ predicate: () -> Bool) async -> Bool {
        for _ in 0..<600 {
            if predicate() { return true }
            try? await Task.sleep(for: .milliseconds(5))
        }
        return predicate()
    }
    @Test func workerCoalescesBlockedReadsWhileMainRunLoopDeliversAndFailuresStayMissing() async throws {
        let gate = GPUReadGate(); defer { gate.release(10) }
        let miner = XRGGPUMiner(asyncSource: { gate.read() }, completionClock: { gate.time })
        try #require(await eventually { gate.reads == 1 })
        var heartbeat = false
        let timer = Timer.scheduledTimer(withTimeInterval: 0.01, repeats: false) { _ in MainActor.assumeIsolated { heartbeat = true } }
        defer { timer.invalidate() }
        for tick in 0..<100 { miner.refreshForGraphTick(UInt64(tick)) }
        try #require(await eventually { heartbeat })
        #expect(gate.reads == 1 && !gate.readOnMain && miner.completionRevision == 0)
        gate.release(); try #require(await eventually { miner.completionRevision == 1 })
        let history = try #require(miner.timedHistory(sourceID: "ioreg-id:1"))
        #expect(history.observationCount == 1 && miner.lastObservationTime == 123 && miner.utilizationDataSets[0].currentValue == 50)
        try await Task.sleep(for: .milliseconds(20)); #expect(gate.reads == 1)
        gate.configure(time: 124, failed: true); miner.refreshForGraphTick(1000)
        try #require(await eventually { gate.reads == 2 }); gate.release()
        try #require(await eventually { miner.completionRevision == 2 })
        #expect(history.observationCount == 2 && !miner.countersAvailable && miner.utilizationDataSets[0].currentValue == XRGGraphRenderer.missingValue)
        if case .success = miner.memorySnapshot { Issue.record("Failed worker read exposed cached memory") }
    }
    @Test func resetAndSuspendRejectInflightResultsWithoutQueueingCatchup() async throws {
        let gate = GPUReadGate(); defer { gate.release(10) }
        let miner = XRGGPUMiner(asyncSource: { gate.read() }, completionClock: { gate.time })
        try #require(await eventually { gate.reads == 1 })
        miner.resetHistory(sourceID: nil); gate.release()
        try #require(await eventually { !miner.isCollecting }); #expect(miner.completionRevision == 0)
        miner.refreshForGraphTick(1); try #require(await eventually { gate.reads == 2 })
        miner.setCollectionActive(false); miner.setCollectionActive(true); miner.getLatestGraphicsInfo()
        #expect(gate.reads == 2); gate.release()
        try #require(await eventually { !miner.isCollecting }); #expect(miner.completionRevision == 0)
        miner.refreshForGraphTick(2); try #require(await eventually { gate.reads == 3 }); gate.release()
        try #require(await eventually { miner.completionRevision == 1 })
        let history = try #require(miner.timedHistory(sourceID: "ioreg-id:1"))
        miner.refreshForGraphTick(3); try #require(await eventually { gate.reads == 4 })
        miner.resetHistory(sourceID: "ioreg-id:1"); gate.release()
        try #require(await eventually { !miner.isCollecting })
        #expect(history.observationCount == 0 && miner.completionRevision == 1 && gate.reads == 4)
    }
    @Test func sharedAsyncGPUAndVRAMObserveCompletionsOnceAndHonorVisibilityResetAndDetach() async throws {
        _ = NSApplication.shared
        let domain = "XRG.gpu-worker.\(UUID().uuidString)", gate = GPUReadGate()
        let defaults = try #require(UserDefaults(suiteName: domain))
        defer { gate.release(10); defaults.removePersistentDomain(forName: domain) }
        defaults.set(true, forKey: "showGPUGraph"); defaults.set(true, forKey: "showVRAMGraph")
        defaults.set(false, forKey: "showFansGraph"); defaults.set(false, forKey: "checkForUpdates")
        let window = XRGGraphWindow(contentRect: NSRect(x: 0, y: 0, width: 300, height: 300), defaults: defaults)
        defer { window.cleanupBeforeExiting(); window.close() }
        let miner = XRGGPUMiner(asyncSource: { gate.read() }, completionClock: { gate.time })
        let view = XRGGPUView(frame: NSRect(x: 0, y: 0, width: 200, height: 100), miner: miner, settings: window.appSettings, defaults: defaults)
        window.contentView?.addSubview(view); view.awakeFromNib(); window.initializeHardwareViews()
        let vram = try #require(window.vramView), manager = try #require(window.moduleManager)
        try #require(await eventually { gate.reads == 1 })
        for _ in 0..<100 { window.graphUpdate(nil) }
        #expect(vram.curve("memory").isEmpty && gate.reads == 1)
        gate.release(); try #require(await eventually { vram.readings.count == 1 })
        #expect(vram.curve("memory").filter { $0 != XRGGraphRenderer.missingValue }.count == 1)
        manager.setModule("GPU", isDisplayed: false); window.graphUpdate(nil)
        try #require(await eventually { gate.reads == 2 })
        for _ in 0..<100 { window.graphUpdate(nil) }
        #expect(vram.curve("memory").filter { $0 != XRGGraphRenderer.missingValue }.count == 1)
        manager.setModule("VRAM", isDisplayed: false); gate.release()
        try #require(await eventually { !miner.isCollecting }); #expect(miner.completionRevision == 1)
        manager.setModule("VRAM", isDisplayed: true)
        try #require(await eventually { gate.reads == 3 }); gate.configure(time: 124); gate.release()
        try #require(await eventually { miner.completionRevision == 2 })
        #expect(vram.curve("memory").filter { $0 != XRGGraphRenderer.missingValue }.count == 2)
        window.graphUpdate(nil); try #require(await eventually { gate.reads == 4 })
        vram.clearData(nil); gate.release(); try #require(await eventually { !miner.isCollecting })
        #expect(miner.completionRevision == 2 && vram.curve("memory").allSatisfy { $0 == XRGGraphRenderer.missingValue })
        window.graphUpdate(nil); try #require(await eventually { gate.reads == 5 })
        view.removeFromSuperview(); gate.release(); try #require(await eventually { !miner.isCollecting })
        #expect(miner.completionRevision == 2 && window.gpuView == nil)
    }

    @Test func replacedGPUViewCannotPublishIntoTheNewVRAMConsumer() async throws {
        _ = NSApplication.shared
        let domain = "XRG.gpu-worker.\(UUID().uuidString)", gate = GPUReadGate()
        let defaults = try #require(UserDefaults(suiteName: domain))
        defer { gate.release(10); defaults.removePersistentDomain(forName: domain) }
        defaults.set(true, forKey: "showGPUGraph"); defaults.set(true, forKey: "showVRAMGraph")
        defaults.set(false, forKey: "showFansGraph"); defaults.set(false, forKey: "checkForUpdates")
        let window = XRGGraphWindow(contentRect: NSRect(x: 0, y: 0, width: 300, height: 300), defaults: defaults)
        defer { window.cleanupBeforeExiting(); window.close() }
        let miner = XRGGPUMiner(asyncSource: { gate.read() }, completionClock: { gate.time })
        let old = XRGGPUView(frame: .zero, miner: miner, settings: window.appSettings, defaults: defaults)
        window.contentView?.addSubview(old); old.awakeFromNib(); window.initializeHardwareViews()
        try #require(await eventually { gate.reads == 1 })
        var newReads = 0
        let sample = XRGGPUSample(id: 2, vendor: "AMD", total: 100, free: 30, wait: nil, utilization: 25,
            memoryReading: XRGHardwareReading(id: "new", name: "New", value: 70, capacity: 100))
        let replacementMiner = XRGGPUMiner(source: { newReads += 1; return [sample] })
        let replacement = XRGGPUView(frame: .zero, miner: replacementMiner, settings: window.appSettings, defaults: defaults)
        defer { old.removeFromSuperview(); replacement.removeFromSuperview() }
        window.contentView?.addSubview(replacement); replacement.awakeFromNib()
        #expect(window.gpuView === replacement && newReads == 1)
        gate.release(); try #require(await eventually { !miner.isCollecting })
        #expect(newReads == 1 && window.vramView?.readings.isEmpty == true)
        window.graphUpdate(nil)
        #expect(newReads == 2 && window.vramView?.readings.first?.id == "new")
    }

    private func card(_ perf: [String: Any], id: UInt64 = 1,
                      extra: [String: Any] = [:]) -> XRGGPUSample {
        var accelerator = extra
        accelerator["PerformanceStatistics"] = perf
        return XRGGPUSample.parse(id: id, pci: [:], accelerator: accelerator)
    }

    @Test func timestampsKeepGapsAndDeviceIdentitySeparateFromSampleCapacity() throws {
        var wall = 100.0
        var samples: [XRGGPUSample]? = [XRGGPUSample(id: 1, vendor: "Apple", total: 100, free: 75, wait: nil, utilization: 50)]
        let miner = XRGGPUMiner(source: { samples }, historyClock: { wall })
        wall = 110; samples = [XRGGPUSample(id: 1, vendor: "Apple", total: 100, free: 100, wait: nil, utilization: 0)]
        miner.getLatestGraphicsInfo()
        let history = try #require(miner.timedHistory(sourceID: "ioreg-id:1"))
        let values = try #require(history.values(minutes: 1, interval: 1))
        #expect(values[3][50] == 50 && values[3][60] == 0)
        #expect(values[3][51..<60].allSatisfy { $0.isNaN } && values[2].allSatisfy { $0.isNaN })
        miner.setDataSize(1)
        #expect(history.values(minutes: 1, interval: 1)?[3][50] == 50)
        wall = 111; samples = nil; miner.getLatestGraphicsInfo()
        #expect(history.values(minutes: 1, interval: 1)?[3].last?.isNaN == true)
        wall = 112; samples = [XRGGPUSample(id: 1, vendor: "AMD", total: 200, free: 150, wait: 10, utilization: 25)]
        miner.getLatestGraphicsInfo()
        let replacement = try #require(miner.timedHistory(sourceID: "ioreg-id:1"))
        #expect(replacement !== history)
        #expect(replacement.values(minutes: 1, interval: 1)?[3].dropLast().allSatisfy { $0.isNaN } == true)
        miner.resetHistory(sourceID: "ioreg-id:1")
        #expect(replacement.observationCount == 0 && miner.currentSamples.first?.utilization == 25)
    }

    @Test func discreteMemoryAndVendor() {
        let sample = card(["vramUsedBytes": 1048576, "hardwareWaitTime": 50],
                          extra: ["VRAM,totalMB": 8, "vendor-id": Data([2, 16, 0, 0])])
        #expect(sample.total == 8_388_608.0)
        #expect(sample.free == 7_340_032.0)
        #expect(sample.vendor == "AMD")
        #expect(sample.wait == 50)
    }

    @Test func appleMemoryAndIdleUtilization() {
        let sample = card(["Alloc system memory": 100, "In use system memory": 25,
                           "Device Utilization %": 0],
                          extra: ["vendor-id": Data([107, 16, 0, 0])])
        #expect(sample.total == 100)
        #expect(sample.free == 75)
        #expect(sample.vendor == "Apple")
        #expect(sample.utilization == 0)
    }

    @Test func zeroUsedAndZeroFreeAreValid() {
        let idle = card(["vramUsedBytes": 0], extra: ["VRAM,totalMB": 1])
        #expect(idle.free == 1048576)
        let full = card(["vramFreeBytes": 0], extra: ["VRAM,totalMB": 1])
        #expect(full.free == 0)
        let derived = card(["vramFreeBytes": 25, "vramUsedBytes": 75])
        #expect(derived.total == 100)
    }

    @Test func fallbacksAndInvalidValues() {
        let fallback = card(["vramUsedBytes": 999, "gartSizeBytes": 100,
                             "gartUsedBytes": 25], extra: ["VRAM,totalMB": 0])
        #expect(fallback.total == 100)
        #expect(fallback.free == 75)
        let invalid = card(["vramFreeBytes": -1, "vramUsedBytes": true,
                            "Device Utilization %": Double.nan, "hardwareWaitTime": "100"],
                           extra: ["vendor-id": Data([1])])
        #expect(invalid.total == nil)
        #expect(invalid.wait == nil)
        #expect(invalid.utilization == nil)
        #expect(invalid.vendor.isEmpty)
        #expect(card(["Device Utilization %": 150]).utilization == 100)
    }

    @Test func stableHistoriesAndReplacement() {
        var samples: [XRGGPUSample]? = [card(["Device Utilization %": 10], id: 2),
                                       card(["Device Utilization %": 20], id: 1)]
        let miner = XRGGPUMiner(source: { samples })
        miner.setDataSize(3)
        let history = miner.utilizationDataSets[0]
        samples = [card(["Device Utilization %": 30], id: 1),
                   card(["Device Utilization %": 40], id: 2)]
        miner.getLatestGraphicsInfo()
        #expect(miner.utilizationDataSets[0] === history)
        #expect(history.currentValue == 30)
        samples = [card(["Device Utilization %": 50], id: 3)]
        miner.getLatestGraphicsInfo()
        #expect(miner.numberOfGPUs == 1)
        #expect(miner.utilizationDataSets[0] !== history)
        #expect(miner.utilizationDataSets[0].orderedValues == [0, 0, 50])
    }

    @Test func failedReadsMissingMetricsAndRemoval() {
        var samples: [XRGGPUSample]? = [card(["Device Utilization %": 0])]
        let miner = XRGGPUMiner(source: { samples })
        #expect(miner.utilizationAvailable[0].boolValue)
        #expect(!miner.memoryAvailable[0].boolValue)
        samples = nil
        miner.getLatestGraphicsInfo()
        #expect(miner.numberOfGPUs == 1)
        samples = [card([:])]
        miner.getLatestGraphicsInfo()
        #expect(!miner.utilizationAvailable[0].boolValue)
        #expect(miner.cpuWaitDataSets[0].currentValue == -1)
        miner.setDataSize(-1)
        #expect(miner.numSamples == 1)
        samples = []
        miner.getLatestGraphicsInfo()
        #expect(miner.numberOfGPUs == 0)
        #expect(miner.totalVRAMDataSets.isEmpty)
    }

    @Test func registryLocationSelectionSurvivesInstanceReplacementButNotHistory() {
        var value = card(["Device Utilization %": 10]); value.sourceID = "IOService:/fixture"
        var samples: [XRGGPUSample]? = [value]
        let miner = XRGGPUMiner(source: { samples }); miner.setDataSize(3)
        let old = miner.utilizationDataSets[0]
        var replacement = card(["Device Utilization %": 50], id: 2); replacement.sourceID = value.sourceID
        samples = [replacement]; miner.getLatestGraphicsInfo()
        #expect(miner.sourceIDs == ["IOService:/fixture"] && miner.utilizationDataSets[0] !== old)
        #expect(miner.utilizationDataSets[0].orderedValues == [0, 0, 50])
        var changed = replacement; changed.sourceID = "IOService:/different"
        let previous = miner.utilizationDataSets[0]
        samples = [changed]; miner.getLatestGraphicsInfo()
        #expect(miner.utilizationDataSets[0] !== previous)
    }

    @Test func ambiguousIDsInvalidateSnapshotAndFailuresAppendGaps() {
        var samples: [XRGGPUSample]? = [card(["Device Utilization %": 50])]
        let miner = XRGGPUMiner(source: { samples }); miner.setDataSize(3)
        let old = miner.utilizationDataSets[0]
        samples = [card(["Device Utilization %": 20]), card(["Device Utilization %": 90])]
        miner.getLatestGraphicsInfo()
        #expect(!miner.countersAvailable && old.currentValue == XRGGraphRenderer.missingValue)
        var a = card([:], id: 1), b = card([:], id: 2)
        a.sourceID = "same"; b.sourceID = "same"; samples = [a,b]; miner.getLatestGraphicsInfo()
        #expect(!miner.countersAvailable && miner.sourceIDs == ["ioreg-id:1"])
        samples = [card(["Device Utilization %": 0])]; miner.getLatestGraphicsInfo()
        #expect(miner.countersAvailable && miner.utilizationDataSets[0] === old && old.currentValue == 0)
    }

    @Test func liveRegistryRead() {
        let samples = XRGGPUMiner.readSnapshot()
        #expect(samples != nil)
        if let samples {
            #expect(Set(samples.map(\.id)).count == samples.count)
            #expect(samples.allSatisfy { $0.total == nil || ($0.total ?? 0) > 0 })
        }
    }
}
