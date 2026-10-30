import Foundation
import Testing
@testable import XRGCore

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
        #expect(data[1].currentValue == XRGGraphRenderer.missingValue && miner.currentUsage(forCPU: 0) == nil)
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

    @Test func countChangesInvalidateBothStreamsAndRestartHistory() throws {
        var values = [ticks(1, 0, 1)]
        let miner = XRGCPUMiner(source: { values }); miner.setDataSize(2)
        values = [ticks(2, 0, 2), ticks(100, 0, 100)]; miner.graphUpdate(nil)
        #expect(miner.numberOfCPUs == 2 && miner.fastValues.count == 2)
        #expect(!miner.countersAvailable && !miner.fastCountersAvailable)
        #expect(miner.userValues.allSatisfy { $0.orderedValues.allSatisfy { $0 == XRGGraphRenderer.missingValue } })
        values = [ticks(3, 0, 3), ticks(110, 0, 110)]; miner.graphUpdate(nil)
        #expect(miner.currentUsage(forCPU: 0) == 50 && miner.currentUsage(forCPU: 1) == 50)
        values = [ticks(4, 0, 4)]; miner.fastUpdate(nil)
        #expect(miner.numberOfCPUs == 1 && miner.currentUsage(forCPU: 0) == nil && miner.fastUsage(forCPU: 0) == nil)
        #expect(miner.userValues[0].orderedValues.allSatisfy { $0 == XRGGraphRenderer.missingValue })
    }

    @Test func failuresAndRecoveryNeverImportMissedIntervalsOrFakeIdle() {
        var values: [XRGCPUTicks]? = nil
        let miner = XRGCPUMiner(source: { values }); miner.setDataSize(4)
        #expect(!miner.countersAvailable && miner.currentUsage(forCPU: 0) == nil)
        values = [ticks(100, 0, 100)]; miner.graphUpdate(nil)
        #expect(miner.currentUsage(forCPU: 0) == nil)
        values = [ticks(120, 0, 120)]; miner.graphUpdate(nil)
        #expect(miner.currentUsage(forCPU: 0) == 50)
        values = nil; miner.graphUpdate(nil)
        #expect(!miner.countersAvailable && miner.currentUsage(forCPU: 0) == nil)
        #expect(miner.userValues[0].orderedValues.suffix(2) == [50, XRGGraphRenderer.missingValue])
        values = [ticks(900, 0, 1000)]; miner.graphUpdate(nil)
        #expect(!miner.countersAvailable && miner.currentUsage(forCPU: 0) == nil)
        values = [ticks(920, 0, 1020)]; miner.graphUpdate(nil)
        #expect(miner.currentUsage(forCPU: 0) == 50)
        miner.graphUpdate(nil)
        #expect(miner.currentUsage(forCPU: 0) == nil && miner.userValues[0].currentValue == XRGGraphRenderer.missingValue)
    }

    @Test func resetPreservesBothBaselinesCurrentReadingsSmoothingAndAvailability() {
        var values: [XRGCPUTicks]? = [ticks(0, 0, 0)]
        var reads = 0
        let miner = XRGCPUMiner(source: { reads += 1; return values }); miner.setDataSize(4)
        values = [ticks(20, 0, 20)]; miner.fastUpdate(nil)
        values = [ticks(40, 0, 60)]; miner.graphUpdate(nil)
        #expect(miner.currentUsage(forCPU: 0) == 40 && miner.fastUsage(forCPU: 0) == 12)
        values = [ticks(70, 0, 70)] // Unsampled work before the reset must remain in the next interval.
        let count = reads
        miner.reset()
        #expect(reads == count && miner.countersAvailable && miner.fastCountersAvailable)
        #expect(miner.currentUsage(forCPU: 0) == 40 && miner.fastUsage(forCPU: 0) == 12)
        #expect((miner.userValues + miner.systemValues + miner.niceValues).allSatisfy {
            $0.orderedValues.allSatisfy { $0 == XRGGraphRenderer.missingValue }
        })
        values = [ticks(80, 0, 120)]; miner.fastUpdate(nil)
        #expect(miner.fastUsage(forCPU: 0) == 18 && miner.currentUsage(forCPU: 0) == 40)
        values = [ticks(120, 0, 180)]; miner.graphUpdate(nil)
        #expect(miner.currentUsage(forCPU: 0) == 40 && miner.userValues[0].currentValue == 40)
        values = nil; miner.graphUpdate(nil)
        let failedReads = reads
        miner.reset()
        #expect(reads == failedReads && !miner.countersAvailable && miner.fastCountersAvailable)
        #expect(miner.currentUsage(forCPU: 0) == nil && miner.fastUsage(forCPU: 0) == 18)
    }

    @Test func historySizeDoesNotChangeCurrentUsageOrBaselines() {
        var values = [ticks(0, 0, 0)]
        let miner = XRGCPUMiner(source: { values }); miner.setDataSize(1)
        values = [ticks(40, 0, 60)]; miner.graphUpdate(nil)
        for size in [100, 0, 3, 30_000] {
            miner.setDataSize(size)
            #expect(miner.currentUsage(forCPU: 0) == 40)
            #expect(miner.userValues[0].numValues == min(size, 20_000))
        }
        values = [ticks(100, 0, 100)]; miner.graphUpdate(nil)
        #expect(miner.currentUsage(forCPU: 0) == 60)
    }

    @Test func fastFailureRebasesOnlyFastSampling() {
        var values: [XRGCPUTicks]? = [ticks(0, 0, 0)]
        let miner = XRGCPUMiner(source: { values }); miner.setDataSize(2)
        values = [ticks(20, 0, 20)]; miner.fastUpdate(nil)
        values = nil; miner.fastUpdate(nil)
        #expect(miner.fastUsage(forCPU: 0) == nil)
        values = [ticks(40, 0, 60)]; miner.graphUpdate(nil); miner.fastUpdate(nil)
        #expect(miner.currentUsage(forCPU: 0) == 40 && miner.fastUsage(forCPU: 0) == nil)
        values = [ticks(60, 0, 80)]; miner.fastUpdate(nil)
        #expect(miner.fastUsage(forCPU: 0) == 12 && miner.currentUsage(forCPU: 0) == 40)
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
