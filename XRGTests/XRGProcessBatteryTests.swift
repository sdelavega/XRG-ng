import Foundation
import Testing
@testable import XRGCore

@Suite @MainActor
struct XRGProcessBatteryTests {
    @Test func processParsing() {
        let records = XRGProcessMiner.parse("""
        %CPU PID RSS VSZ NSWAP USER COMMAND
        125.5 42 5000000000 9000000000 - person Command With Spaces
        broken row
        nan 43 1 2 0 user invalid
        0.0 44 1 2 3 root helper
        """)
        #expect(records.count == 2)
        #expect(records.first?.resident == 5_000_000_000)
        #expect(records.first?.command == "Command With Spaces")
        #expect(records.first?.cpu == 125.5)
        #expect(records.first?.swaps == 0)
    }

    @Test func processSortingAndEmptySnapshots() async {
        let miner = XRGProcessMiner(source: {
            XRGProcessMiner.parse("10 1 100 200 - a first\n20 2 50 100 - b second")
        })
        await miner.refresh()
        #expect(miner.processesSortedByCPUUsage().first?["pid"] as? Int == 2)
        #expect(miner.processesSortedByMemoryUsage().first?["pid"] as? Int == 1)
        let empty = XRGProcessMiner(source: { [] })
        await empty.refresh()
        #expect(empty.processes.isEmpty)
    }

    @Test func processChurnAndFailure() async {
        let fixture = ProcessFixture()
        let miner = XRGProcessMiner(source: { fixture.next() })
        await miner.refresh()
        #expect(miner.processes.count == 1)
        await miner.refresh()
        #expect(miner.processes.count == 1)
        await miner.refresh()
        #expect(miner.processes.isEmpty)
    }

    @Test func liveProcesses() async {
        let result = await Task.detached { XRGProcessMiner.readProcesses() }.value
        #expect(result?.contains { $0.pid == Int(ProcessInfo.processInfo.processIdentifier) } == true)
    }

    @Test func explicitlyAbsentDesktopBatteryDoesNotBecomeAnOnHoldBattery() {
        // AppleSmartBattery on the M4 Pro Mac mini publishes a power source even
        // though there is no installed battery.
        let absent = XRGBatteryInfo(dictionary: ["BatteryInstalled": false,
            "CurrentCapacity": 0, "MaxCapacity": 0,
            "ExternalConnected": true, "IsCharging": false])
        var samples = [absent]
        let miner = XRGBatteryMiner(source: { samples })
        miner.graphUpdate(nil)
        #expect(miner.batteries.isEmpty)
        #expect(miner.batteryStatus() == .noBattery)
        #expect(!miner.hasRawCapacity && miner.totalCapacity() == 0)
        let empty = XRGBatteryInfo(dictionary: ["BatteryInstalled": true,
            "AppleRawCurrentCapacity": 0, "AppleRawMaxCapacity": 5000])
        let legacy = XRGBatteryInfo(dictionary: [
            "AppleRawCurrentCapacity": 1000, "AppleRawMaxCapacity": 4000])
        samples = [absent, empty, legacy]
        miner.graphUpdate(nil)
        #expect(miner.batteries.count == 2)
        #expect(miner.hasRawCapacity && miner.totalCapacity() == 9000 && miner.totalCharge() == 1000)
    }

    @Test func normalizedBatteryCapacityFallback() {
        let battery = XRGBatteryInfo(dictionary: [
            "CurrentCapacity": 100, "MaxCapacity": 100, "FullyCharged": 1
        ])
        let miner = XRGBatteryMiner(source: { [battery] })
        miner.graphUpdate(nil)
        #expect(miner.chargePercent() == 100)
        #expect(!miner.hasRawCapacity)
        #expect(miner.totalCapacity() == 0)
        #expect(XRGBatteryInfo(dictionary: [
            "CurrentCapacity": 42, "MaxCapacity": 100
        ]).percentCharged() == 0.42)
        #expect(XRGBatteryInfo(dictionary: [
            "CurrentCapacity": Double.nan, "MaxCapacity": 100
        ]).percentCharged() == 0)
    }

    @Test func nestedBatteryDataUsesMAhWithoutConfusingNormalizedPercentages() {
        let battery = XRGBatteryInfo(dictionary: [
            "CurrentCapacity": 50, "MaxCapacity": 100,
            "BatteryData": ["AppleRawCurrentCapacity": 2679, "AppleRawMaxCapacity": 5358]
        ])
        let miner = XRGBatteryMiner(source: { [battery] })
        miner.graphUpdate(nil)
        #expect(miner.hasRawCapacity && miner.totalCharge() == 2679 && miner.totalCapacity() == 5358)
        #expect(miner.chargePercent() == 50)
        let preferred = XRGBatteryInfo(dictionary: [
            "AppleRawCurrentCapacity": 2000, "AppleRawMaxCapacity": 4000,
            "BatteryData": ["AppleRawCurrentCapacity": 5358, "AppleRawMaxCapacity": 5358]
        ])
        #expect(preferred.currentCharge == 2000 && preferred.totalCapacity == 4000)
    }

    @Test func invalidOrPartialRawCapacityPairsNeverBecomeMAhOrMixSources() {
        for value: Any in [true, -1, Double.nan, Double.infinity, UInt64.max] {
            let battery = XRGBatteryInfo(dictionary: [
                "AppleRawCurrentCapacity": value, "AppleRawMaxCapacity": 5000,
                "CurrentCapacity": 75, "MaxCapacity": 100
            ])
            #expect(!battery.hasRawCapacity && battery.currentCharge == 0 && battery.totalCapacity == 0)
            #expect(battery.percentCharged() == 0.75)
        }
        let partial = XRGBatteryInfo(dictionary: [
            "AppleRawCurrentCapacity": 2500,
            "BatteryData": ["AppleRawMaxCapacity": 5000]
        ])
        #expect(!partial.hasRawCapacity)
        let recovered = XRGBatteryInfo(dictionary: [
            "AppleRawCurrentCapacity": 2500, "AppleRawMaxCapacity": 0,
            "BatteryData": ["AppleRawCurrentCapacity": 0, "AppleRawMaxCapacity": 5000]
        ])
        #expect(recovered.hasRawCapacity && recovered.currentCharge == 0 && recovered.totalCapacity == 5000)
    }

    @Test func batteryStatesAndFailure() {
        var next: [XRGBatteryInfo]? = nil
        let miner = XRGBatteryMiner(source: { next })
        #expect(miner.batteryStatus() == .unknown)
        for (properties, status) in [
            ([:], XRGBatteryStatus.runningOnBattery),
            (["ExternalConnected": 1], .onHold),
            (["ExternalConnected": 1, "IsCharging": 1], .charging),
            (["ExternalConnected": 1, "FullyCharged": 1], .charged)
        ] {
            next = [XRGBatteryInfo(dictionary: properties)]
            miner.graphUpdate(nil)
            #expect(miner.batteryStatus() == status)
        }
        next = nil
        miner.graphUpdate(nil)
        #expect(miner.batteryStatus() == .charged)
        next = []
        miner.graphUpdate(nil)
        #expect(miner.batteryStatus() == .noBattery)
    }

    @Test func batteryUnitsAndUnknownValues() {
        let battery = XRGBatteryInfo(dictionary: [
            "AppleRawMaxCapacity": 5000, "AppleRawCurrentCapacity": 2500,
            "Voltage": 12000, "Amperage": -2000, "TimeRemaining": 65535
        ])
        let miner = XRGBatteryMiner(source: { [battery] })
        miner.setDataSize(3)
        miner.graphUpdate(nil)
        #expect(miner.chargePercent() == 50)
        #expect(battery.percentCharged() == 0.5)
        #expect(miner.minutesRemaining() == 0)
        #expect(miner.dischargeWatts.currentValue == 24)
        #expect(miner.chargeWatts.currentValue == 0)
        miner.setDataSize(-1)
        #expect(miner.numSamples == 3)
        miner.reset()
        #expect(miner.dischargeWatts.currentValue == 0)
        #expect(XRGBatteryInfo(dictionary: [:]).percentCharged() == 0)
    }

    @Test func batteryClampingAndOverflow() {
        let battery = XRGBatteryInfo(dictionary: [
            "AppleRawMaxCapacity": Int.max, "AppleRawCurrentCapacity": Int.max
        ])
        let miner = XRGBatteryMiner(source: { [battery, battery] })
        miner.graphUpdate(nil)
        #expect(miner.totalCapacity() == Int.max)
        #expect(miner.totalCharge() == Int.max)
        #expect(miner.chargePercent() == 100)
        #expect(XRGBatteryInfo(dictionary: [
            "AppleRawMaxCapacity": 1, "AppleRawCurrentCapacity": 2
        ]).percentCharged() == 1)
    }
}

private final class ProcessFixture: @unchecked Sendable {
    private let lock = NSLock()
    private var index = 0
    func next() -> [XRGProcessRecord]? {
        lock.lock()
        defer { lock.unlock() }
        index += 1
        switch index {
        case 1: return XRGProcessMiner.parse("10 1 100 200 - user command")
        case 2: return nil
        default: return []
        }
    }
}
