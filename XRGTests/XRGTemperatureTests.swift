import Foundation
import Testing
@testable import XRGCore

@Suite @MainActor
struct XRGTemperatureTests {
    @Test func monotonicCadenceAndPreferenceChange() {
        let state = XRGTemperatureState()
        #expect(state.shouldUpdate(at: 10, includeUnknown: false))
        #expect(!state.shouldUpdate(at: 14.9, includeUnknown: false))
        #expect(state.shouldUpdate(at: 15, includeUnknown: false))
        #expect(state.shouldUpdate(at: 15.1, includeUnknown: true))
        #expect(!state.shouldUpdate(at: .nan, includeUnknown: true))
        #expect(state.shouldUpdate(at: 1, includeUnknown: true))
    }

    @Test func validTemperaturesAndMissingReadings() {
        let state = XRGTemperatureState()
        state.setDataSize(3)
        state.beginUpdate()
        state.ingestTemperatures(["cpu": 50, "cold": 14, "hot": 151,
                                  "nan": Double.nan, "bool": true, "text": "50"], names: ["cpu": "CPU"])
        state.finishUpdate()
        #expect(state.allSensorKeys() == ["cpu"])
        let sensor = state.sensor(forLocation: "cpu")
        #expect(sensor?.label() == "CPU")
        #expect(sensor?.dataSet.orderedValues == [50, 50, 50])
        state.beginUpdate()
        state.finishUpdate()
        #expect(sensor?.isEnabled == false)
        #expect(sensor?.currentValue == 0)
        #expect(sensor?.dataSet.orderedValues == [50, 50, XRGGraphRenderer.missingValue])
        state.beginUpdate()
        state.ingestTemperatures(["cpu": 60], names: ["cpu": "CPU"])
        state.finishUpdate()
        #expect(sensor?.isEnabled == true)
        #expect(sensor?.currentValue == 60)
    }

    @Test func missingSamplesAreGapsWhileStoppedFansRemainRealZero() throws {
        let state = XRGTemperatureState()
        state.resizeHistory(3)
        var time = 100.0; state.historyClock = { time }
        let stopped = XRGFan(); stopped.key = "F0Ac"; stopped.actualSpeed = 0
        state.beginUpdate()
        state.ingestTemperatures(["cpu": 50], names: ["cpu": "CPU"])
        state.ingestFans([stopped], names: ["F0Ac": "Fan 1"])
        state.finishUpdate()
        let cpu = try #require(state.sensor(forLocation: "cpu"))
        let fan = try #require(state.sensor(forLocation: "F0Ac"))
        time = 105; state.beginUpdate(); state.finishUpdate()
        #expect(!cpu.isEnabled && !fan.isEnabled)
        #expect(cpu.dataSet.currentValue == XRGGraphRenderer.missingValue && fan.dataSet.currentValue == XRGGraphRenderer.missingValue)
        time = 110; state.beginUpdate()
        state.ingestTemperatures(["cpu": 55], names: ["cpu": "CPU"])
        state.ingestFans([stopped], names: ["F0Ac": "Fan 1"])
        state.finishUpdate()
        #expect(cpu.isEnabled && fan.isEnabled && fan.currentValue == 0)
        #expect(cpu.dataSet.orderedValues == [50, XRGGraphRenderer.missingValue, 55])
        #expect(fan.dataSet.orderedValues == [0, XRGGraphRenderer.missingValue, 0])
        #expect(cpu.timedHistory.observationCount == 3 && fan.timedHistory.observationCount == 3)
    }

    @Test func boundedFanDecoding() {
        var rpm: Float = 1200
        let bytes = withUnsafeBytes(of: &rpm) { Data($0) }
        let fans = XRGTemperatureState.decodeFans([
            "Fan #0": ["F0Ac": bytes, "F0Mx": 6000, "F0Mn": 0, "F0Tg": 1500],
            "Bad": ["F1Ac": Data([1]), "F1Mx": 999],
            "Invalid": ["F2Ac": Double.infinity],
            "Stopped": ["F3Ac": 0]
        ])
        #expect(fans.count == 2)
        #expect(fans[0].actualSpeed == 1200)
        #expect(fans[0].maximumSpeed == 6000)
        #expect(fans[0].targetSpeed == 1500)
        #expect(fans[1].actualSpeed == 0)
        #expect(XRGTemperatureState.numericValue(Data(repeating: 0, count: 8)) == nil)
        #expect(XRGTemperatureState.numericValue(true) == nil)
        let state = XRGTemperatureState()
        state.ingestFans(fans, names: ["F0Ac": "Fan"])
        #expect(state.sensor(forLocation: "F0Ac")?.units == " rpm")
    }

    @Test func orderingAndUnitChanges() {
        let state = XRGTemperatureState()
        state.setCurrentValue(40, andUnits: "°C", forLocation: "z", name: "CPU Core")
        state.setCurrentValue(40, andUnits: "°C", forLocation: "a", name: "GPU")
        state.setCurrentValue(40, andUnits: "°C", forLocation: "b", name: "b")
        state.setCurrentValue(900, andUnits: " rpm", forLocation: "fan", name: "Fan")
        #expect(state.locationKeys() == ["z", "a", "b", "fan"])
        state.setCurrentValue(40, andUnits: "%", forLocation: "z", name: "CPU Core")
        #expect(state.locationKeys() == ["a", "b", "fan", "z"])
    }

    @Test func resizeResetAndNonfiniteValues() {
        let state = XRGTemperatureState()
        state.setDataSize(2)
        state.setCurrentValue(40, andUnits: "°C", forLocation: "cpu", name: nil)
        state.setDataSize(-1)
        #expect(state.sensor(forLocation: "cpu")?.dataSet.numValues == 2)
        state.setCurrentValue(.infinity, andUnits: "°C", forLocation: "cpu", name: nil)
        #expect(state.sensor(forLocation: "cpu")?.currentValue == 40)
        state.reset()
        #expect(state.sensor(forLocation: "cpu")?.dataSet.max == 0)
        state.setDataSize(0)
        state.setCurrentValue(50, andUnits: "°C", forLocation: "cpu", name: nil)
        #expect(state.sensor(forLocation: "cpu")?.dataSet.numValues == 0)
        #expect(state.sensor(forLocation: "cpu")?.label() == "cpu")
    }
}
