import Foundation
import Testing
import XRGCore

@MainActor
struct XRGCPUMinerTests {
    private func ticks(_ user: UInt32, _ system: UInt32 = 0, _ idle: UInt32 = 0, _ nice: UInt32 = 0) -> XRGCPUTicks {
        XRGCPUTicks(user: user, system: system, idle: idle, nice: nice)
    }

    @Test func percentagesAndIndependentFastBaseline() throws {
        var values = [ticks(100, 100, 100, 100)]
        let miner = XRGCPUMiner(source: { values })
        miner.loadAverage = false
        miner.setDataSize(3)
        values = [ticks(120, 110, 170, 100)]
        miner.fastUpdate(nil)
        #expect(miner.fastValues[0].intValue == 7)
        miner.graphUpdate(nil)
        let data = try #require(miner.dataForCPU(0))
        #expect(data[0].currentValue == 10)
        #expect(data[1].currentValue == 20)
        #expect(data[2].currentValue == 0)
        miner.graphUpdate(nil)
        #expect(data[1].currentValue == 0)
        #expect(miner.dataForCPU(-1) == nil && miner.dataForCPU(1) == nil)
    }

    @Test func wrapsUnsignedTicksAndAveragesCores() throws {
        var values = [ticks(UInt32.max - 5, 0, 100), ticks(0, 0, 100)]
        let miner = XRGCPUMiner(source: { values })
        miner.loadAverage = false
        miner.setDataSize(1)
        values = [ticks(4, 0, 110), ticks(0, 10, 110)]
        miner.graphUpdate(nil)
        let first = try #require(miner.dataForCPU(0))
        #expect(first[1].currentValue == 50)
        let combined = try #require(miner.combinedData())
        #expect(combined[0].currentValue == 25 && combined[1].currentValue == 25)
        #expect(first[1].currentValue == 50)
    }

    @Test func countChangesAndResetEstablishBaselines() throws {
        var values = [ticks(1, 0, 1)]
        let miner = XRGCPUMiner(source: { values })
        miner.setDataSize(2)
        values = [ticks(2, 0, 2), ticks(100, 0, 100)]
        miner.graphUpdate(nil)
        #expect(miner.numberOfCPUs == 2 && miner.fastValues.count == 2)
        #expect(miner.userValues.allSatisfy { $0.currentValue == 0 && $0.numValues == 2 })
        values = [ticks(3, 0, 3), ticks(110, 0, 110)]
        miner.graphUpdate(nil)
        #expect(miner.userValues.allSatisfy { $0.currentValue == 50 })
        miner.reset()
        miner.graphUpdate(nil)
        #expect(miner.userValues.allSatisfy { $0.currentValue == 0 })
        values = [ticks(4, 0, 4)]
        miner.fastUpdate(nil)
        #expect(miner.numberOfCPUs == 1 && miner.userValues.count == 1)
    }

    @Test func samplingFailurePreservesHistoryAndRecoveryBaselines() {
        var values: [XRGCPUTicks]? = nil
        let miner = XRGCPUMiner(source: { values })
        miner.setDataSize(2)
        #expect(miner.numberOfCPUs > 0)
        values = [ticks(100, 0, 100)]
        miner.graphUpdate(nil)
        #expect(miner.userValues[0].currentValue == 0)
        values = [ticks(120, 0, 120)]
        miner.graphUpdate(nil)
        #expect(miner.userValues[0].currentValue == 50)
        values = nil
        miner.graphUpdate(nil)
        #expect(miner.userValues[0].currentValue == 50)
    }

    @Test func liveMachCPUReader() throws {
        for _ in 0..<20 {
            let ticks = try #require(XRGCPUMiner.readTicks())
            #expect(!ticks.isEmpty)
        }
        #expect(XRGCPUMiner.systemModelIdentifier()?.isEmpty == false)
    }
}

@MainActor
struct XRGMemoryMinerTests {
    @Test(arguments: [UInt64(4096), UInt64(16384)])
    func pageSizesAnd64BitCounters(_ pageSize: UInt64) {
        var snapshot = XRGMemorySnapshot()
        snapshot.free = 10; snapshot.active = 20; snapshot.inactive = 30; snapshot.wired = 40
        snapshot.faults = UInt64(UInt32.max) + 100
        snapshot.usedSwap = 1024; snapshot.totalSwap = 4096
        let miner = XRGMemoryMiner(pageSize: pageSize, source: { snapshot })
        miner.setDataSize(3)
        #expect(miner.recentFaults() == 0)
        snapshot.faults += 20
        snapshot.pageIns = 5; snapshot.pageOuts = 2
        miner.getLatestMemoryInfo()
        #expect(miner.freeBytes() == 10 * pageSize && miner.wiredBytes() == 40 * pageSize)
        #expect(miner.activeBytes() == 20 * pageSize && miner.inactiveBytes() == 30 * pageSize)
        #expect(miner.totalFaults() > UInt64(UInt32.max) && miner.recentFaults() == 20)
        #expect(miner.faultData().currentValue == 20 && miner.pageInData().currentValue == 5)
        #expect(miner.usedSwap == 1024 && miner.totalSwap == 4096)
    }

    @Test func failureResetAndCounterDecrease() {
        var sample = XRGMemorySnapshot()
        sample.faults = 100
        var current: XRGMemorySnapshot? = sample
        let miner = XRGMemoryMiner(pageSize: 4096, source: { current })
        miner.setDataSize(2)
        sample.faults = 120
        current = sample
        miner.getLatestMemoryInfo()
        #expect(miner.recentFaults() == 20)
        current = nil
        miner.getLatestMemoryInfo()
        #expect(miner.totalFaults() == 120 && miner.faultData().currentValue == 20)
        sample.faults = 1
        current = sample
        miner.getLatestMemoryInfo()
        #expect(miner.recentFaults() == 0)
        miner.reset()
        sample.faults = 500
        current = sample
        miner.getLatestMemoryInfo()
        #expect(miner.recentFaults() == 0)
    }

    @Test func failedSwapReadPreservesPriorValuesAndBytesSaturate() {
        var sample = XRGMemorySnapshot()
        sample.usedSwap = 100
        sample.totalSwap = 200
        let miner = XRGMemoryMiner(pageSize: 16384, source: { sample })
        sample.usedSwap = nil; sample.totalSwap = nil; sample.free = .max
        miner.getLatestMemoryInfo()
        #expect(miner.usedSwap == 100 && miner.totalSwap == 200)
        #expect(miner.freeBytes() == UInt64.max)
    }

    @Test func liveMachMemoryReader() throws {
        let sample = try #require(XRGMemoryMiner.readSnapshot())
        #expect(sample.active + sample.wired > 0)
        let miner = XRGMemoryMiner()
        #expect(miner.pageSize == 4096 || miner.pageSize == 16384)
        #expect(miner.activeBytes() + miner.wiredBytes() > 0)
    }
}
