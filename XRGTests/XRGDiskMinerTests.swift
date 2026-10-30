/*
 * XRG-ng: A system resource grapher for macOS and Linux.
 * Copyright (C) 2002-2024 Mike Piatek-Jimenez / Gaucho Software, LLC.
 * Copyright (C) 2025-2026 Marc Shade.
 * Copyright (C) 2026 Stephen de la Vega.
 * You can view the complete license in the LICENSE file in the root
 * of the source tree.
 *
 * This program is free software; you can redistribute it and/or
 * modify it under the terms of the GNU General Public License
 * as published by the Free Software Foundation; either version 3
 * of the License, or (at your option) any later version.
 *
 * This program is distributed in the hope that it will be useful,
 * but WITHOUT ANY WARRANTY; without even the implied warranty of
 * MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
 * GNU General Public License for more details.
 *
 * You should have received a copy of the GNU General Public License
 * along with this program. If not, see <https://www.gnu.org/licenses/>.
 *
 */

import Foundation
import Testing
@testable import XRGCore

@MainActor final class DiskSampleSource {
    var samples: [XRGDiskSample]? = [XRGDiskSample(id: 1, read: 1000, written: 200)]
    var time: TimeInterval = 0
    var reads = 0
    func miner() -> XRGDiskMiner { XRGDiskMiner(source: { self.reads += 1; return self.samples }, clock: { self.time }) }
    func advance(_ time: TimeInterval, read: UInt64, written: UInt64) {
        self.time = time; samples = [XRGDiskSample(id: 1, read: read, written: written)]
    }
}

@Suite @MainActor
struct XRGDiskMinerTests {
    @Test func wakeKeepsExactNormalTransfersAndIndependentlyRebasesFastRates() {
        let source = DiskSampleSource(), miner = source.miner(); miner.setDataSize(4)
        source.advance(1, read: 1600, written: 400); #expect(miner.update()); #expect(miner.updateFast())
        miner.invalidateRateInterval()
        #expect(!miner.countersAvailable && !miner.fastCountersAvailable && miner.totalBytesSinceLoad == 800)
        source.advance(2, read: 11_600, written: 2400)
        #expect(!miner.update() && !miner.updateFast())
        #expect(miner.totalBytesSinceLoad == 12_800 && !miner.transfersAreLowerBound && miner.readRate == 600)
        #expect(miner.readValues.currentValue == XRGGraphRenderer.missingValue)
        #expect(miner.transferDetails.contains("Read 11600 bytes / Write 2400 bytes"))
        source.advance(3, read: 12_200, written: 2600)
        #expect(miner.update() && miner.updateFast() && miner.readRate == 600 && miner.fastReadRate == 600)
        #expect(miner.totalBytesSinceLoad == 13_600)
    }

    @Test func ratesUseElapsedTimeAndSessionTotalsCountBytes() {
        let source = DiskSampleSource(), miner = source.miner()
        miner.setDataSize(3)
        source.advance(2, read: 1600, written: 400)
        #expect(miner.update())
        #expect(miner.readRate == 300 && miner.writeRate == 100)
        #expect(miner.totalValues.currentValue == 400 && miner.totalBytesSinceLoad == 800)
        source.advance(2.5, read: 1800, written: 450); miner.update()
        #expect(miner.readRate == 400 && miner.writeRate == 100 && miner.totalBytesSinceLoad == 1050)
    }

    @Test func fastAndNormalSamplingHaveIndependentBaselines() {
        let source = DiskSampleSource(), miner = source.miner()
        miner.setDataSize(3)
        source.advance(0.2, read: 1060, written: 220)
        #expect(miner.updateFast())
        #expect(abs(miner.fastReadRate - 300) < 0.0001 && abs(miner.fastWriteRate - 100) < 0.0001)
        #expect(miner.totalBytesSinceLoad == 0 && miner.totalValues.max == 0)
        source.advance(2, read: 1600, written: 400); miner.update()
        #expect(miner.readRate == 300 && miner.writeRate == 100 && miner.totalBytesSinceLoad == 800)
        miner.rebaseFast(); miner.updateFast()
        #expect(miner.fastReadRate == 0 && miner.readRate == 300)
        source.advance(2.25, read: 1700, written: 450); miner.updateFast()
        #expect(miner.fastReadRate == 400 && miner.fastWriteRate == 200)
    }

    @Test func failedReadsRetainTotalsAndRecoverWithFreshBaseline() {
        let source = DiskSampleSource(), miner = source.miner()
        miner.setDataSize(3)
        source.advance(1, read: 1600, written: 400); miner.update()
        source.samples = nil; source.time = 2
        #expect(!miner.update() && !miner.updateFast())
        #expect(miner.readRate == 600 && miner.totalValues.max == 800)
        source.advance(3, read: 2200, written: 600); miner.update()
        #expect(miner.readRate == 0 && miner.writeRate == 0 && miner.totalBytesSinceLoad == 800)
        #expect(miner.transfersAreLowerBound && miner.countersAvailable)
    }

    @Test func clockRollbackEqualTimesAndNonfiniteClocksDoNotCreateRates() {
        let source = DiskSampleSource(), miner = source.miner()
        miner.setDataSize(3)
        source.advance(1, read: 1600, written: 400); miner.update()
        source.advance(1, read: 1700, written: 500); miner.update()
        #expect(!miner.countersAvailable && miner.totalValues.currentValue == XRGGraphRenderer.missingValue)
        source.advance(0, read: 1800, written: 600); miner.update()
        #expect(miner.totalBytesSinceLoad == 800)
        source.advance(.nan, read: 1900, written: 700)
        #expect(!miner.update())
        source.advance(1, read: 2000, written: 800); miner.update()
        #expect(miner.readRate == 0 && miner.writeRate == 0 && miner.totalBytesSinceLoad == 800)
        #expect(miner.transfersAreLowerBound)
    }

    @Test func driveChurnAndCounterRestartsBeginNewSessions() {
        let source = DiskSampleSource()
        source.samples = [XRGDiskSample(id: 1, read: 1000, written: 200), XRGDiskSample(id: 2, read: 5000, written: 1000)]
        let miner = source.miner(); miner.setDataSize(2)
        source.time = 1
        source.samples = [XRGDiskSample(id: 1, read: 1100, written: 250), XRGDiskSample(id: 3, read: 9_000_000, written: 7_000_000)]
        miner.update()
        #expect(miner.readRate == 0 && miner.writeRate == 0 && miner.totalBytesSinceLoad == 0)
        source.time = 2
        source.samples = [XRGDiskSample(id: 1, read: 5, written: 300), XRGDiskSample(id: 3, read: 9_000_200, written: 7_000_100)]
        miner.update()
        #expect(miner.readRate == 0 && miner.writeRate == 0 && miner.totalBytesSinceLoad == 0)
        source.time = 3; source.samples = []; miner.update()
        #expect(miner.deviceCount == 0 && miner.readRate == 0 && miner.writeRate == 0)
        source.time = 4; source.samples = [XRGDiskSample(id: 1, read: 10_000, written: 10_000)]; miner.update()
        #expect(miner.readRate == 0 && miner.totalBytesSinceLoad == 0)
    }

    @Test func duplicateDeviceIDsInvalidateSnapshotsAndInitialFailuresDoNotSpike() {
        let source = DiskSampleSource(); source.samples = nil
        let miner = source.miner(); miner.setDataSize(2)
        source.advance(1, read: 10_000, written: 5000); miner.update()
        #expect(miner.totalValues.currentValue == 0)
        source.time = 2
        source.samples = [XRGDiskSample(id: 1, read: 10_100, written: 5050), XRGDiskSample(id: 1, read: 99_999, written: 99_999)]
        miner.update()
        #expect(!miner.countersAvailable && miner.transfersAreLowerBound && miner.deviceCount == 1)
        source.advance(3, read: 10_200, written: 5100); miner.update()
        #expect(miner.readRate == 0 && miner.totalBytesSinceLoad == 0)
        source.advance(4, read: 10_300, written: 5150); miner.update()
        #expect(miner.readRate == 100 && miner.writeRate == 50 && miner.totalBytesSinceLoad == 150)
    }

    @Test func hugeUnsignedCountersSaturateTotalsWithoutNarrowing() {
        let source = DiskSampleSource()
        source.samples = [XRGDiskSample(id: 1, read: 0, written: 0), XRGDiskSample(id: 2, read: 0, written: 0)]
        let miner = source.miner(); miner.setDataSize(1)
        source.time = 1
        source.samples = [XRGDiskSample(id: 1, read: .max, written: .max), XRGDiskSample(id: 2, read: .max, written: .max)]
        miner.update()
        #expect(miner.totalBytesSinceLoad == UInt64.max && miner.readRate > CGFloat(Int64.max))
        #expect(miner.totalValues.currentValue.isFinite && miner.totalValues.currentValue > 0)
    }

    @Test func resizingAndResetKeepBoundedHistoryAndDoNotResetSessionBytes() {
        let source = DiskSampleSource(), miner = source.miner()
        miner.setDataSize(2)
        source.advance(1, read: 1600, written: 400); miner.update(); miner.updateFast()
        source.advance(2, read: 1700, written: 500); miner.update()
        source.advance(3, read: 1750, written: 550); miner.update()
        #expect(miner.totalValues.orderedValues == [200, 100] && miner.totalValues.max == 200)
        miner.setDataSize(1)
        #expect(miner.totalValues.orderedValues == [100])
        let total = miner.totalBytesSinceLoad
        miner.reset()
        #expect(miner.totalValues.max == 0 && miner.readRate == 50 && miner.fastReadRate == 600 && miner.totalBytesSinceLoad == total)
        source.advance(4, read: 1850, written: 650); miner.update()
        #expect(miner.totalValues.currentValue == 200 && miner.totalBytesSinceLoad == total + 200)
        miner.setDataSize(20_001); miner.setDataSize(-1)
        #expect(miner.readValues.numValues == 20_000)
        miner.setDataSize(0); source.advance(5, read: 1900, written: 700); miner.update()
        #expect(miner.totalValues.numValues == 0 && miner.totalBytesSinceLoad == total + 300)
    }

    @Test func transferResetPreservesNormalAndFastHistoryAndRateBaselines() {
        let source = DiskSampleSource(), miner = source.miner()
        miner.setDataSize(3)
        source.advance(1, read: 1600, written: 400); miner.update(); miner.updateFast()
        let history = miner.totalValues.orderedValues
        miner.resetTransfers()
        #expect(miner.totalBytesSinceLoad == 0 && miner.totalValues.orderedValues == history)
        #expect(miner.readRate == 600 && miner.fastReadRate == 600)
        source.advance(2, read: 2200, written: 600); miner.updateFast(); miner.update()
        #expect(miner.readRate == 600 && miner.fastReadRate == 600 && miner.totalBytesSinceLoad == 0)
        source.advance(3, read: 2800, written: 800); miner.updateFast(); miner.update()
        #expect(miner.readBytesSinceLoad == 600 && miner.writtenBytesSinceLoad == 200)
        #expect(miner.transferDetails.contains("Read 2800 bytes / Write 800 bytes"))
    }

    @Test func decoderRetainsUInt64ValuesAndRejectsIncompleteStatistics() throws {
        let sample = try #require(XRGDiskMiner.decodeStatistics(id: 9, ["Bytes (Read)": NSNumber(value: UInt64.max), "Bytes (Write)": 17]))
        #expect(sample.id == 9 && sample.read == UInt64.max && sample.written == 17)
        #expect(XRGDiskMiner.decodeStatistics(id: 9, ["Bytes (Read)": 17]) == nil)
    }

    @Test(arguments: ["negative", "boolean", "fraction", "text", "null"])
    func malformedStatisticsDoNotBecomeUnsignedCounters(kind: String) {
        let value: Any
        switch kind {
        case "negative": value = -1
        case "boolean": value = true
        case "fraction": value = 1.5
        case "text": value = "123"
        default: value = NSNull()
        }
        #expect(XRGDiskMiner.decodeStatistics(id: 1, ["Bytes (Read)": value, "Bytes (Write)": 0]) == nil)
    }

    @Test func liveIOKitSnapshotsHaveStableUniqueIdentifiers() throws {
        for _ in 0..<3 {
            let samples = try #require(XRGDiskMiner.readSamples())
            #expect(Set(samples.map(\.id)).count == samples.count)
        }
    }
}
