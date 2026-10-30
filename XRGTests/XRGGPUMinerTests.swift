import Foundation
import Testing
@testable import XRGCore

@Suite @MainActor
struct XRGGPUMinerTests {
    private func card(_ perf: [String: Any], id: UInt64 = 1,
                      extra: [String: Any] = [:]) -> XRGGPUSample {
        var accelerator = extra
        accelerator["PerformanceStatistics"] = perf
        return XRGGPUSample.parse(id: id, pci: [:], accelerator: accelerator)
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
