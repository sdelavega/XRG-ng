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

@MainActor
private final class TemperatureReader: NSObject, XRGTemperatureReader {
    var smc: [String: Any] = [:]
    var silicon: [String: Any] = [:]
    var fans: [String: Any] = [:]
    var labels: [String: String] = [:]
    var known: Set<String> = []
    var knownTemperatureKeyCount = 0
    var smcRequests: [Bool] = []
    var siliconRequests = 0
    var fanRequests = 0

    func temperatures(includingUnknown: Bool) -> [String: Any] {
        smcRequests.append(includingUnknown)
        return includingUnknown ? smc : smc.filter { known.contains($0.key) }
    }
    func siliconTemperatures() -> [String: Any] { siliconRequests += 1; return silicon }
    func fanReadings() -> [String: Any] { fanRequests += 1; return fans }
    func name(forKey key: String) -> String? { labels[key] }
    func isKnownKey(_ key: String) -> Bool { known.contains(key) }
}

@Suite @MainActor
struct XRGTemperatureMinerTests {
    @Test func cadencePreferenceChangesAndClockRollback() {
        let reader = TemperatureReader()
        reader.smc = ["cpu": 50, "unknown": 55]
        reader.silicon = ["hid": 60]
        reader.known = ["cpu"]
        var time = 10.0
        let miner = XRGTemperatureMiner(reader: reader, clock: { time })
        miner.updateCurrentTemperatures(false)
        #expect(miner.allSensorKeys() == ["cpu", "hid"])
        time = 14.9
        miner.updateCurrentTemperatures(false)
        #expect(reader.smcRequests == [false])
        miner.updateCurrentTemperatures(true)
        #expect(reader.smcRequests == [false, true])
        #expect(miner.allSensorKeys() == ["cpu", "hid", "unknown"])
        time = 20
        miner.updateCurrentTemperatures(true)
        #expect(reader.siliconRequests == 3)
        time = .nan
        miner.updateCurrentTemperatures(true)
        #expect(reader.siliconRequests == 3)
        time = 1
        miner.updateCurrentTemperatures(true)
        #expect(reader.siliconRequests == 4)
    }

    @Test func namesKnownFilteringAndOrderingAcrossReaders() {
        let reader = TemperatureReader()
        reader.smc = ["cpu": 50, "ambient": 25]
        reader.silicon = ["gpu": 60, "unnamed": 65]
        reader.fans = ["Fan #0": ["F0Ac": 1500, "F0Mx": 6000]]
        reader.labels = ["cpu": "CPU Core", "ambient": "Ambient", "gpu": "GPU", "F0Ac": "Fan"]
        reader.known = ["cpu", "ambient", "F0Ac"]
        reader.knownTemperatureKeyCount = 2
        let miner = XRGTemperatureMiner(reader: reader, clock: { 0 })
        miner.updateCurrentTemperatures(true)
        #expect(miner.knownTemperatureKeyCount == 2)
        #expect(miner.locationKeys(includingUnknown: true) == ["cpu", "gpu", "ambient", "unnamed", "F0Ac"])
        #expect(miner.locationKeys(includingUnknown: false) == ["cpu", "ambient", "F0Ac"])
        #expect(miner.sensor(forLocation: "unnamed")?.label() == "unnamed")
        #expect(miner.sensor(forLocation: "gpu")?.units == "°C")
        #expect(miner.sensor(forLocation: "F0Ac")?.units == " rpm")
        miner.regenerateLocationKeyOrder()
        #expect(miner.locationKeys(includingUnknown: false) == ["cpu", "ambient", "F0Ac"])
    }

    @Test func fanCacheUsesMonotonicTimeAndNilSelectionsAreSafe() throws {
        let reader = TemperatureReader()
        reader.fans = ["Fan #0": ["F0Ac": 1200, "F0Mx": 6000]]
        var time = 10.0
        let miner = XRGTemperatureMiner(reader: reader, clock: { time })
        let sensor = XRGSensorData(sensorKey: "F0Ac")
        #expect(!miner.isFanSensor(nil))
        #expect(miner.maxSpeed(forFan: nil) == 0)
        #expect(reader.fanRequests == 0)
        #expect(miner.isFanSensor(sensor))
        #expect(miner.maxSpeed(forFan: sensor) == 6000)
        #expect(reader.fanRequests == 1)
        reader.fans = ["Fan #0": ["F0Ac": 0, "F0Mx": 5000]]
        time = 10.99
        #expect(try #require(miner.fanValues().first).actualSpeed == 1200)
        time = 11
        #expect(try #require(miner.fanValues().first).actualSpeed == 0)
        #expect(miner.maxSpeed(forFan: sensor) == 5000)
        #expect(reader.fanRequests == 2)
        time = .infinity
        #expect(miner.fanValues().isEmpty)
        #expect(reader.fanRequests == 2)
        time = 5
        #expect(miner.maxSpeed(forFan: sensor) == 5000)
        #expect(reader.fanRequests == 3)
        reader.fans = [:]
        time = 6
        #expect(!miner.isFanSensor(sensor))
        #expect(miner.maxSpeed(forFan: sensor) == 0)
        #expect(reader.fanRequests == 4)
    }

    @Test func missingReadingsDisableHistoriesAndIndependentSourcesRecover() throws {
        let reader = TemperatureReader()
        reader.smc = ["cpu": 50]; reader.silicon = ["gpu": 60]
        reader.fans = ["Fan #0": ["F0Ac": 1200]]
        var time = 0.0
        let miner = XRGTemperatureMiner(reader: reader, clock: { time })
        miner.setDataSize(3)
        miner.updateCurrentTemperatures(true)
        let cpu = try #require(miner.sensor(forLocation: "cpu"))
        let fan = try #require(miner.sensor(forLocation: "F0Ac"))
        reader.smc = [:]; reader.fans = [:]
        time = 5
        miner.updateCurrentTemperatures(true)
        #expect(!cpu.isEnabled && !fan.isEnabled)
        #expect(cpu.currentValue == 0)
        #expect(cpu.dataSet.orderedValues == [50, 50, 0])
        #expect(miner.sensor(forLocation: "gpu")?.isEnabled == true)
        reader.smc = ["cpu": 55]; reader.silicon = [:]
        reader.fans = ["Fan #0": ["F0Ac": 0]]
        time = 10
        miner.updateCurrentTemperatures(true)
        #expect(cpu.isEnabled && fan.isEnabled)
        #expect(fan.currentValue == 0)
        #expect(cpu.dataSet.orderedValues == [50, 0, 55])
        #expect(miner.sensor(forLocation: "gpu")?.isEnabled == false)
    }

    @Test func resizeResetAndManualSamplesPreserveGraphAPI() throws {
        let reader = TemperatureReader()
        reader.smc = ["cpu": 50]; reader.labels = ["cpu": "CPU"]
        var time = 0.0
        let miner = XRGTemperatureMiner(reader: reader, clock: { time })
        miner.setDataSize(3)
        miner.updateCurrentTemperatures(true)
        reader.smc = ["cpu": 60]; time = 5
        miner.updateCurrentTemperatures(true)
        let cpu = try #require(miner.sensor(forLocation: "cpu"))
        #expect(cpu.dataSet.orderedValues == [50, 50, 60])
        miner.reset()
        #expect(cpu.dataSet.orderedValues == [0, 0, 0])
        #expect(cpu.currentValue == 60)
        #expect(cpu.label() == "CPU")
        miner.setDataSize(-1)
        #expect(cpu.dataSet.numValues == 3)
        miner.setDataSize(0)
        #expect(cpu.dataSet.numValues == 0)
        miner.setCurrentValue(15, andUnits: "%", forLocation: "manual")
        #expect(miner.sensor(forLocation: "manual")?.units == "%")
        #expect(miner.sensor(forLocation: "manual")?.label() == "manual")
        miner.setCurrentValue(.infinity, andUnits: nil, forLocation: "bad")
        #expect(miner.sensor(forLocation: "bad") == nil)
        #expect(miner.numberOfCPUs() > 0)
    }

    @Test func absentReaderAndEmptyDiscoveryAreSafe() {
        let miner = XRGTemperatureMiner(reader: nil, clock: { 0 })
        miner.updateCurrentTemperatures(false)
        #expect(miner.knownTemperatureKeyCount == 0)
        #expect(miner.allSensorKeys().isEmpty)
        #expect(miner.fanValues().isEmpty)
        #expect(miner.locationKeys(includingUnknown: true).isEmpty)
        #expect(miner.sensor(forLocation: "unknown") == nil)
        miner.setCurrentValue(50, andUnits: nil, forLocation: "manual")
        #expect(miner.locationKeys(includingUnknown: false).isEmpty)
        #expect(miner.locationKeys(includingUnknown: true) == ["manual"])
    }

    @Test func malformedFansAndDuplicateKeysDoNotTrapNameLookup() {
        let reader = TemperatureReader()
        reader.fans = ["Bad": ["F1Ac": Data([1])],
                       "First": ["F0Ac": 1000], "Second": ["F0Ac": 1000]]
        reader.smc = ["nan": Double.nan, "text": "50", "hot": 151]
        reader.silicon = ["cold": 14, "bool": true]
        let miner = XRGTemperatureMiner(reader: reader, clock: { 0 })
        miner.updateCurrentTemperatures(true)
        #expect(miner.allSensorKeys() == ["F0Ac"])
        #expect(miner.fanValues().count == 2)
        #expect(miner.sensor(forLocation: "F0Ac")?.currentValue == 1000)
    }
}
