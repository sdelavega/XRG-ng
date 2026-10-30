import Foundation
import Darwin
import Testing
@testable import XRGCore

@Suite @MainActor
struct XRGNetworkMinerTests {
    private func sample(_ rx: UInt64, _ tx: UInt64 = 0, name: String = "en0",
                        index: UInt16 = 1) -> XRGNetworkSample {
        XRGNetworkSample(name: name, index: index, received: rx, sent: tx)
    }

    @Test func ratesAndCurrentTotals() {
        var samples = [sample(5_000_000_000, 100)]
        var time = 10.0
        let miner = XRGNetMiner(source: { samples }, clock: { time })
        miner.setDataSize(4)
        #expect(miner.totalBytesSinceLoad == 0)
        #expect(miner.totalBytesSinceBoot == 5_000_000_100)
        samples = [sample(5_000_000_600, 300)]
        time += 2
        miner.getLatestNetInfo()
        #expect(miner.currentRX() == 300)
        #expect(miner.currentTX() == 100)
        #expect(miner.maxBandwidth() == 400)
        #expect(miner.totalBytesSinceLoad == 800)
        #expect(miner.totalBytesSinceBoot == 5_000_000_900)
    }

    @Test func disappearanceReappearanceAndIdentityChange() {
        var samples = [sample(100)]
        var time = 0.0
        let miner = XRGNetMiner(source: { samples }, clock: { time })
        miner.setDataSize(4)
        samples = []
        time += 1
        miner.getLatestNetInfo()
        #expect(miner.networkInterfaces().isEmpty)
        #expect(miner.currentRX() == 0)
        samples = [sample(1000)]
        time += 1
        miner.getLatestNetInfo()
        #expect(miner.currentRX() == 0)
        samples = [sample(2000, index: 2)]
        time += 1
        miner.getLatestNetInfo()
        #expect(miner.currentRX() == 0)
        #expect(miner.totalBytesSinceLoad == 0)
    }

    @Test func resetCountersAndOneWayTraffic() {
        var samples = [sample(100, 500)]
        var time = 0.0
        let miner = XRGNetMiner(source: { samples }, clock: { time })
        miner.setDataSize(4)
        samples = [sample(0, 600)]
        time += 1
        miner.getLatestNetInfo()
        #expect(miner.currentRX() == 0)
        #expect(miner.currentTX() == 0)
        #expect(miner.totalBytesSinceLoad == 0)
        samples = [sample(20, 600)]
        time += 1
        miner.getLatestNetInfo()
        #expect(miner.currentRX() == 20)
        #expect(miner.currentTX() == 0)
        miner.reset()
        time += 1
        miner.getLatestNetInfo()
        #expect(miner.maxBandwidth() == 0)
        #expect(miner.totalBytesSinceLoad == 20)
    }

    @Test func selectionAndLoopback() {
        var samples = [sample(100), sample(200, name: "utun0", index: 2),
                       sample(999, name: "lo0", index: 3)]
        var time = 0.0
        let miner = XRGNetMiner(source: { samples }, clock: { time })
        miner.setDataSize(3)
        #expect(miner.networkInterfaces() == ["en0", "utun0"])
        #expect(miner.totalBytesSinceBoot == 300)
        miner.monitorNetworkInterface = "utun0"
        #expect(miner.totalBytesSinceBoot == 200)
        time += 1
        miner.getLatestNetInfo()
        samples = [sample(1000), sample(220, name: "utun0", index: 2)]
        time += 1
        miner.getLatestNetInfo()
        #expect(miner.currentRX() == 20)
        #expect(miner.totalBytesSinceLoad == 20)
        miner.monitorNetworkInterface = "missing"
        #expect(miner.totalBytesSinceBoot == 0)
        #expect(miner.totalBytesSinceLoad == 0)
    }

    @Test func failuresAndInvalidTime() {
        var samples: [XRGNetworkSample]? = [sample(100)]
        var time = 1.0
        let miner = XRGNetMiner(source: { samples }, clock: { time })
        miner.setDataSize(3)
        samples = nil
        time = 2
        miner.getLatestNetInfo()
        #expect(miner.numInterfaces == 1)
        samples = [sample(300)]
        time = 3
        miner.getLatestNetInfo()
        #expect(miner.currentRX() == 0)
        #expect(miner.transfersAreLowerBound)
        #expect(miner.totalBytesSinceLoad == 0)
        time = 3
        samples = [sample(400)]
        miner.getLatestNetInfo()
        #expect(miner.currentRX() == 0)
        time = .nan
        samples = []
        miner.getLatestNetInfo()
        #expect(miner.numInterfaces == 1)
    }

    @Test func saturatedTotals() {
        var samples = [sample(0, 0)]
        var time = 0.0
        let miner = XRGNetMiner(source: { samples }, clock: { time })
        miner.setDataSize(1)
        samples = [sample(.max, .max)]
        time = 1
        miner.getLatestNetInfo()
        #expect(miner.totalBytesSinceBoot == .max)
        #expect(miner.totalBytesSinceLoad == .max)
        #expect(miner.currentRX().isFinite)
    }

    @Test func graphClearPreservesIntervalAndResetTransfersExcludesOldBytes() {
        var samples = [sample(100, 200)]
        var time = 0.0
        let miner = XRGNetMiner(source: { samples }, clock: { time })
        miner.setDataSize(3)
        samples = [sample(700, 400)]; time = 1; miner.getLatestNetInfo()
        miner.reset()
        #expect(miner.maxBandwidth() == 0 && miner.currentRX() == 600)
        samples = [sample(1300, 600)]; time = 2; miner.getLatestNetInfo()
        #expect(miner.currentRX() == 600 && miner.totalBytesSinceLoad == 1600)
        let history = miner.rxValues.orderedValues
        miner.resetTransfers()
        #expect(miner.rxValues.orderedValues == history && miner.currentRX() == 600)
        samples = [sample(1900, 800)]; time = 3; miner.getLatestNetInfo()
        #expect(miner.currentRX() == 600 && miner.totalBytesSinceLoad == 0)
        samples = [sample(2500, 1000)]; time = 4; miner.getLatestNetInfo()
        #expect(miner.receivedBytesSinceLoad == 600 && miner.sentBytesSinceLoad == 200)
    }

    @Test func ambiguousIdentityAndMissingSelectionDoNotFabricateTraffic() {
        var samples = [sample(100)]
        var time = 0.0
        let miner = XRGNetMiner(source: { samples }, clock: { time })
        miner.setDataSize(3)
        samples = [sample(200)]; time = 1; miner.getLatestNetInfo()
        samples = [sample(300), sample(999)]; time = 2
        #expect(!miner.getLatestNetInfo())
        #expect(miner.totalBytesSinceLoad == 100 && miner.transfersAreLowerBound)
        samples = [sample(1000)]; time = 3; miner.getLatestNetInfo()
        #expect(miner.currentRX() == 0 && miner.totalBytesSinceLoad == 100)
        miner.monitorNetworkInterface = "en0"
        samples = [sample(5000, name: "en1", index: 2)]; time = 4
        #expect(!miner.getLatestNetInfo() && !miner.countersAvailable)
        #expect(miner.networkInterfaces() == ["en1"] && miner.totalBytesSinceBoot == 0)
        #expect(miner.monitorNetworkInterface == "en0")
        samples = [sample(2000)]; time = 5; miner.getLatestNetInfo()
        #expect(miner.currentRX() == 0 && miner.totalBytesSinceLoad == 0)
    }

    @Test func malformedRoutingMessages() {
        #expect(XRGNetMiner.parse(Data())?.isEmpty == true)
        #expect(XRGNetMiner.parse(Data([0])) == nil)
        #expect(XRGNetMiner.parse(Data([0, 0, UInt8(RTM_VERSION), UInt8(RTM_IFINFO2)])) == nil)
        #expect(XRGNetMiner.parse(Data([4, 0, UInt8(RTM_VERSION), UInt8(RTM_IFINFO2)])) == nil)
        #expect(XRGNetMiner.parse(Data([4, 0, 0, 0])) == nil)
        #expect(XRGNetMiner.parse(Data([4, 0, UInt8(RTM_VERSION), 0]))?.isEmpty == true)
    }

    @Test func liveKernelSnapshot() {
        let samples = XRGNetMiner.readSnapshot()
        #expect(samples != nil)
        #expect(samples?.contains { $0.name == "lo0" } == false)
        #expect(samples?.allSatisfy { !$0.name.isEmpty } == true)
    }
}
