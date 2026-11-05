// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Stephen de la Vega.
import Foundation
import IOKit
import Testing
@testable import XRGCore

private final class SMCChannelFixture: NSObject, XRGSMCPacketTransport {
    var width: UInt32 = 2, type: UInt32 = 0x73703738
    var payload: [UInt8] = [0x19,0x66]
    var commands: [UInt8] = []
    var failure: IOReturn?, result: UInt8 = 0, replyLength = 80
    func transactPacket(_ packet: Data, error: AutoreleasingUnsafeMutablePointer<NSError?>?) -> Data? {
        error?.pointee = nil; commands.append(packet[42])
        var reply = Data(repeating:0,count:80)
        func put(_ value: UInt32, _ offset: Int) { var v=value.littleEndian;withUnsafeBytes(of:&v) {reply.replaceSubrange(offset..<offset+4,with:$0)} }
        if packet[42] == 9 { put(width,28);put(type,32) }
        if packet[42] == 8 { put(0x54433050,0) }
        for (i,b) in payload.prefix(32).enumerated() { reply[48+i]=b }
        reply[40]=result
        if let failure {error?.pointee=XRGSMCReader.error(failure)}
        return Data(reply.prefix(replyLength))
    }
}
private final class SMCSensorFixture: NSObject, XRGSMCTransport {
    var keys: [NSNumber?], values:[UInt32:Any] = [:], countOverride:Int?
    var requests:[UInt32]=[], indices:[Int]=[]
    var keyCount:Int {countOverride ?? keys.count}
    init(_ names:[String]) {keys=names.map {NSNumber(value:XRGSMCSensors.code($0)!)};super.init()}
    func key(at index:Int)->NSNumber? {indices.append(index);return keys[index]}
    func readValue(for key:UInt32)->Any? {requests.append(key);return values[key]}
    func temperatureValue(for key:UInt32)->NSNumber? {readValue(for:key) as? NSNumber}
    func set(_ name:String,_ value:Any) {values[XRGSMCSensors.code(name)!]=value}
}
struct XRGSMCReaderTests {
    @Test func friendlyNamesPreserveCaseSensitiveSourceIdentityAndUnknownChannels() {
        let source = SMCSensorFixture(["TC0P", "Tp01", "Tg0U", "Tzzz", "F0Ac", "FAAc"])
        let sensors = XRGSMCSensors(transport: source, systemModel: nil)
        #expect(sensors.humanReadableName(forKey: "TC0P") == "CPU temperature · TC0P")
        #expect(sensors.humanReadableName(forKey: "Tp01") == "CPU temperature · Tp01")
        #expect(sensors.humanReadableName(forKey: "Tg0U") == "GPU temperature · Tg0U")
        #expect(sensors.humanReadableName(forKey: "Tzzz") == "Temperature sensor · Tzzz")
        #expect(sensors.humanReadableName(forKey: "F0Ac") == "Fan 1 · F0Ac")
        #expect(sensors.humanReadableName(forKey: "FAAc") == "Fan 11 · FAAc")
        #expect(sensors.humanReadableName(forKey: "PMU2 tdie4") == "Power management 2 die 4 · PMU2 tdie4")
        #expect(sensors.humanReadableName(forKey: "PMU tdev8") == "Power management device 8 · PMU tdev8")
        #expect(sensors.humanReadableName(forKey: "PMU tcal") == "Power management calibration · PMU tcal")
        #expect(sensors.humanReadableName(forKey: "NAND CH0 temp") == "Storage temperature channel 0 · NAND CH0 temp")
        let m5 = XRGSMCSensors(transport: source, systemModel: "Mac17,4")
        #expect(m5.humanReadableName(forKey: "NAND CH0 temp") == "Storage composite temperature · NAND CH0 temp")
        let nand = XRGAppleSiliconSensorMiner.identity(product: "NAND CH0 temp", location: 0x544E306E)
        #expect(m5.humanReadableName(forKey: nand) == "Storage composite temperature · HID TN0n")
        let otherLocation = XRGAppleSiliconSensorMiner.identity(product: "NAND CH0 temp", location: 0x544E316E)
        #expect(m5.humanReadableName(forKey: otherLocation) == "Storage temperature channel 0 · HID TN1n")
        #expect(m5.humanReadableName(forKey: "NAND CH1 temp") == "Storage temperature channel 1 · NAND CH1 temp")
        for model in [nil, "Mac16,11", "Mac17,3"] {
            let other = XRGSMCSensors(transport: source, systemModel: model)
            #expect(other.humanReadableName(forKey: "NAND CH0 temp") == "Storage temperature channel 0 · NAND CH0 temp")
            #expect(other.humanReadableName(forKey: nand) == "Storage temperature channel 0 · HID TN0n")
        }
        #expect(sensors.humanReadableName(forKey: "als-temp") == "Ambient light sensor temperature · als-temp")
        #expect(sensors.humanReadableName(forKey: "gas gauge battery") == "Battery temperature · gas gauge battery")
        #expect(!sensors.isKnownKey("Tzzz2") && sensors.knownTemperatureKeys.contains("Tzzz"))
    }
    @Test func branchDescriptionsOnlyApplyToAnExactDriverBranchAndKeepRawIdentities() {
        let source = SMCSensorFixture(["RBr ", "Tm0P", "TG0H", "Tzzz"])
        source.set("RBr ", Data([109, 56, 55, 0, 0, 0, 0, 0]))
        var branches: [String] = []
        let sensors = XRGSMCSensors(transport: source, branchNameSource: { branch in
            branches.append(branch)
            return branch == "m87" ? ["Tm0P": "Charger proximity", "TG0H": "Northbridge proximity"] : [:]
        }, publishedNameSource: { [:] })
        #expect(branches == ["m87"])
        #expect(sensors.humanReadableName(forKey: "Tm0P") == "Charger proximity · Tm0P")
        #expect(sensors.humanReadableName(forKey: "TG0H") == "Northbridge proximity · TG0H")
        #expect(sensors.knownTemperatureKeys == ["Tm0P", "TG0H", "Tzzz"])
        source.set("RBr ", Data("J815".utf8)); sensors.reloadInventory()
        #expect(branches == ["m87", "J815"])
        #expect(sensors.humanReadableName(forKey: "Tm0P") == "Temperature sensor · Tm0P")
        #expect(sensors.humanReadableName(forKey: "TG0H") == "Temperature sensor · TG0H")
        for silicon in [true, false] {
            #expect(XRGSMCSensors.temperatureName(forKey: "Tm0P", appleSilicon: silicon) == "Temperature sensor · Tm0P")
            #expect(XRGSMCSensors.temperatureName(forKey: "TG0H", appleSilicon: silicon) == "Temperature sensor · TG0H")
        }
        #expect(XRGSMCSensors.temperatureName(forKey: "Tp0P", appleSilicon: false) == "Temperature sensor · Tp0P")
        #expect(XRGSMCSensors.temperatureName(forKey: "Ta00", appleSilicon: true) == "Temperature sensor · Ta00")
    }

    @Test func malformedBranchIdentityDoesNotLoadAnyCatalogue() {
        let source = SMCSensorFixture(["RBr ", "Tm0P"])
        for data in [Data(), Data([109, 0, 56]), Data([109, 10]), Data(repeating: 65, count: 17)] {
            source.set("RBr ", data)
            let sensors = XRGSMCSensors(transport: source, branchNameSource: { _ in
                Issue.record("Invalid branch requested a catalogue"); return [:]
            })
            #expect(sensors.humanReadableName(forKey: "Tm0P") == "Temperature sensor · Tm0P")
        }
    }

    @Test func verifiedNeuralEngineNamesRequireTheValidatedModelAndKeepSeparateReadings() {
        let source = SMCSensorFixture(["Ta00", "Ta01", "Ta0R", "Ta0S", "Ta02", "Tz11"])
        source.set("Ta00", 35.0); source.set("Ta01", 43.2)
        let sensors = XRGSMCSensors(transport: source, systemModel: "Mac16,11")
        #expect(sensors.humanReadableName(forKey: "Ta00") == "Neural Engine temperature channel 1 · Ta00")
        #expect(sensors.humanReadableName(forKey: "Ta01") == "Neural Engine temperature channel 1 (adjusted) · Ta01")
        #expect(sensors.humanReadableName(forKey: "Ta0R") == "Neural Engine temperature channel 6 · Ta0R")
        #expect(sensors.humanReadableName(forKey: "Ta0S") == "Neural Engine temperature channel 6 (adjusted) · Ta0S")
        #expect(sensors.humanReadableName(forKey: "Ta02") == "Temperature sensor · Ta02")
        #expect(sensors.humanReadableName(forKey: "Tz11") == "Temperature sensor · Tz11")
        #expect(sensors.temperatureValues(includingUnknown: true)["Ta00"] as? Double == 35.0)
        #expect(sensors.temperatureValues(includingUnknown: true)["Ta01"] as? Double == 43.2)
        for model: String? in [nil, "Mac17,4", "Mac16,10", "mac16,11"] {
            let other = XRGSMCSensors(transport: source, systemModel: model)
            #expect(other.humanReadableName(forKey: "Ta00") == "Temperature sensor · Ta00")
            #expect(other.humanReadableName(forKey: "Ta01") == "Temperature sensor · Ta01")
        }
        #expect(XRGSMCSensors.verifiedTemperatureName(forKey: "ta00", systemModel: "Mac16,11") == nil)
    }

    @Test func verifiedDieTemperatureNamesDistinguishCurrentAndAverageChannels() {
        let source = SMCSensorFixture(["Ts00", "Ts01", "Ts02", "Ts0U", "Ts0W", "Tsx0", "Tsx1", "Ts03"])
        source.set("Ts00", 60.4); source.set("Ts02", 61.9)
        let sensors = XRGSMCSensors(transport: source, systemModel: "Mac16,11")
        #expect(sensors.humanReadableName(forKey: "Ts00") == "SoC die temperature channel 1 (average) · Ts00")
        #expect(sensors.humanReadableName(forKey: "Ts01") == "SoC die temperature channel 1 (adjusted average) · Ts01")
        #expect(sensors.humanReadableName(forKey: "Ts02") == "SoC die temperature channel 1 · Ts02")
        #expect(sensors.humanReadableName(forKey: "Ts0U") == "SoC die temperature channel 8 (adjusted average) · Ts0U")
        #expect(sensors.humanReadableName(forKey: "Ts0W") == "SoC die temperature channel 8 · Ts0W")
        #expect(sensors.humanReadableName(forKey: "Tsx0") == "SoC die temperature channel 9 (average) · Tsx0")
        #expect(sensors.humanReadableName(forKey: "Tsx1") == "SoC die temperature channel 9 · Tsx1")
        #expect(sensors.humanReadableName(forKey: "Ts03") == "Temperature sensor · Ts03")
        #expect(sensors.temperatureValues(includingUnknown: true)["Ts00"] as? Double == 60.4)
        #expect(sensors.temperatureValues(includingUnknown: true)["Ts02"] as? Double == 61.9)
        for model: String? in [nil, "Mac17,4", "Mac16,10"] {
            let other = XRGSMCSensors(transport: source, systemModel: model)
            #expect(other.humanReadableName(forKey: "Ts00") == "Temperature sensor · Ts00")
        }
    }

    @Test func publishedPMUNamesRequireExactKeysAndRejectAmbiguousOrMalformedMetadata() {
        func record(_ key: String, _ product: String) -> [String: Any] {
            ["LocationID": NSNumber(value: XRGSMCSensors.code(key)!), "Product": product, "ProviderID": 1]
        }
        let records = [record("TP1b", "PMU tdie1"), record("TR1b", "PMU2 tdie1"),
                       record("TP1d", "PMU tdev1"), record("TP0Z", "PMU tcal"),
                       record("TG0H", "gas gauge battery")]
        let names = XRGSMCPublishedNames.decode(records)
        #expect(names["TP1b"] == "Power management die 1")
        #expect(names["TR1b"] == "Power management 2 die 1")
        #expect(names["TP1d"] == "Power management device 1")
        #expect(names["TP0Z"] == "Power management calibration")
        #expect(names["TG0H"] == "Battery temperature")
        #expect(XRGSMCPublishedNames.decode(records + [record("TP1b", "PMU tdie1")])["TP1b"] == names["TP1b"])
        #expect(XRGSMCPublishedNames.decode(records + [record("TP1b", "PMU2 tdie2")])["TP1b"] == nil)
        var otherProvider = record("TP1b", "PMU tdie1"); otherProvider["ProviderID"] = 2
        #expect(XRGSMCPublishedNames.decode(records + [otherProvider])["TP1b"] == nil)
        var invalidProvider = record("TP1b", "PMU tdie1"); invalidProvider["ProviderID"] = true
        #expect(XRGSMCPublishedNames.decode([invalidProvider]).isEmpty)
        let malformed: [[String: Any]] = [
            ["LocationID": true, "Product": "PMU tdie1"],
            ["LocationID": -1, "Product": "PMU tdie1"],
            ["LocationID": 1.5, "Product": "PMU tdie1"],
            ["LocationID": UInt64.max, "Product": "PMU tdie1"],
            record("TP2b", "PMU tdie2\n"), record("TP3b", "unrecognized"),
            record("VP1b", "PMU tdie1")]
        #expect(XRGSMCPublishedNames.decode(malformed.map { item in
            var item = item; item["ProviderID"] = 1; return item
        }).isEmpty)
        let source = SMCSensorFixture(["RBr ", "TP1b", "TG0H", "Tzzz"])
        source.set("RBr ", Data("m87".utf8))
        var current = names
        let sensors = XRGSMCSensors(transport: source, branchNameSource: { _ in ["TG0H": "Northbridge proximity"] },
                                   publishedNameSource: { current })
        #expect(sensors.humanReadableName(forKey: "TP1b") == "Power management die 1 · TP1b")
        #expect(sensors.humanReadableName(forKey: "TG0H") == "Battery temperature · TG0H")
        #expect(sensors.humanReadableName(forKey: "TR1b") == "Temperature sensor · TR1b")
        #expect(sensors.knownTemperatureKeys == ["TP1b", "TG0H", "Tzzz"])
        current = [:]; sensors.reloadInventory()
        #expect(sensors.humanReadableName(forKey: "TP1b") == "Temperature sensor · TP1b")
    }

    @Test func firmwareAliasesRequireTheValidatedModelAndExactPublishedADCSource() {
        let source = SMCSensorFixture(["TPD0", "TPD9", "TPDA", "TPDC", "TPDD", "TRD0", "TRD7", "TRD8", "TRD9"])
        source.set("TPD0", 36.5)
        var names = ["TP1b": "Power management die 1", "TPab": "Power management die 10",
                     "TPbl": "Power management die 11", "TPdl": "Power management die 13",
                     "TR1b": "Power management 2 die 1", "TR8l": "Power management 2 die 8"]
        let sensors = XRGSMCSensors(transport: source, systemModel: "Mac17,4", publishedNameSource: { names })
        #expect(sensors.humanReadableName(forKey: "TPD0") == "Power management die 1 · TPD0")
        #expect(sensors.humanReadableName(forKey: "TPD9") == "Power management die 10 · TPD9")
        #expect(sensors.humanReadableName(forKey: "TPDA") == "Power management die 11 · TPDA")
        #expect(sensors.humanReadableName(forKey: "TPDC") == "Power management die 13 · TPDC")
        #expect(sensors.humanReadableName(forKey: "TRD0") == "Power management 2 die 1 · TRD0")
        #expect(sensors.humanReadableName(forKey: "TRD7") == "Power management 2 die 8 · TRD7")
        for key in ["TPDD"] {
            #expect(sensors.humanReadableName(forKey: key) == "Temperature sensor · \(key)")
        }
        #expect(!sensors.knownTemperatureKeys.contains("TP1b"))
        #expect(sensors.humanReadableName(forKey: "TP1b") == "Temperature sensor · TP1b")
        #expect(sensors.temperatureValues(includingUnknown: true)["TPD0"] as? Double == 36.5)
        for model: String? in [nil, "Mac16,10", "mac17,4"] {
            let other = XRGSMCSensors(transport: source, systemModel: model, publishedNameSource: { names })
            #expect(other.humanReadableName(forKey: "TPD0") == "Temperature sensor · TPD0")
        }
        names["TP1b"] = "Battery temperature"; sensors.reloadInventory()
        #expect(sensors.humanReadableName(forKey: "TPD0") == "Temperature sensor · TPD0")
        names = [:]; sensors.reloadInventory()
        #expect(sensors.humanReadableName(forKey: "TRD0") == "Temperature sensor · TRD0")
        #expect(XRGSMCSensors.verifiedPublishedAlias(forKey: "TPDa", systemModel: "Mac17,4") == nil)
    }

    @Test func verifiedComputedTemperaturesDoNotAcquirePhysicalCPULabels() {
        let source = SMCSensorFixture(["TCMb", "TPDX", "TRDX"])
        let sensors = XRGSMCSensors(transport: source, systemModel: "Mac17,4", publishedNameSource: { [:] })
        #expect(sensors.humanReadableName(forKey: "TCMb") == "Adjusted temperature maximum · TCMb")
        #expect(sensors.humanReadableName(forKey: "TPDX") == "Temperature maximum (selected channels) · TPDX")
        #expect(sensors.humanReadableName(forKey: "TRDX") == "Temperature maximum (selected channels) · TRDX")
        #expect(XRGSMCSensors.verifiedTemperatureName(forKey: "TCMb", systemModel: "Mac16,11") == "Temperature maximum (selected channels)")
    }

    @Test func verifiedDeviceStreamsReplaceMisleadingGenericFamiliesAndFailClosedWithoutMetadata() {
        let source = SMCSensorFixture(["Tm0B", "TCHP", "TMVR", "TH0T", "TH0x", "TPSP"])
        var names = ["TP2d": "Power management device 2", "TP7d": "Power management device 7",
                     "TP8d": "Power management device 8", "TR2d": "Power management 2 device 2",
                     "TR5d": "Power management 2 device 5"]
        let sensors = XRGSMCSensors(transport: source, systemModel: "Mac17,4", publishedNameSource: { names })
        #expect(sensors.humanReadableName(forKey: "Tm0B") == "Power management device 2 · Tm0B")
        #expect(sensors.humanReadableName(forKey: "TCHP") == "Power management device 7 · TCHP")
        #expect(sensors.humanReadableName(forKey: "TMVR") == "Power management device 8 · TMVR")
        #expect(sensors.humanReadableName(forKey: "TH0T") == "Power management 2 device 2 · TH0T")
        #expect(sensors.humanReadableName(forKey: "TH0x") == "Power management 2 device 2 · TH0x")
        #expect(sensors.humanReadableName(forKey: "TPSP") == "Power management 2 device 5 · TPSP")
        names = [:]; sensors.reloadInventory()
        for key in ["TCHP", "TMVR", "TH0T", "TH0x"] {
            #expect(sensors.humanReadableName(forKey: key) == "Temperature sensor · \(key)")
        }
    }

    @Test func categoricalThermalSelectorIsNotExposedAsCelsiusOnVerifiedModel() {
        let source = SMCSensorFixture(["TVMD", "TVmd", "TVMR", "Tz11"])
        source.set("TVMD", 1.0); source.set("TVMR", 40.0); source.set("Tz11", 0.0)
        let sensors = XRGSMCSensors(transport: source, systemModel: "Mac17,4", publishedNameSource: { [:] })
        #expect(!sensors.knownTemperatureKeys.contains("TVMD"))
        #expect(!sensors.isKnownKey("TVMD"))
        #expect(sensors.temperatureValues(includingUnknown: true)["TVMD"] == nil)
        #expect(sensors.temperatureValues(includingUnknown: true)["TVMR"] as? Double == 40.0)
        #expect(sensors.temperatureValues(includingUnknown: true)["Tz11"] as? Double == 0.0)
        #expect(sensors.humanReadableName(forKey: "TVMD") == "Thermal control selector · TVMD")
        let havana = XRGSMCSensors(transport: source, systemModel: "Mac16,11", publishedNameSource: { [:] })
        #expect(!havana.knownTemperatureKeys.contains("TVMD"))
        #expect(havana.temperatureValues(includingUnknown: true)["TVMD"] == nil)
        #expect(havana.humanReadableName(forKey: "TVMD") == "Thermal control selector · TVMD")
        #expect(!havana.knownTemperatureKeys.contains("TVmd"))
        #expect(havana.humanReadableName(forKey: "TVmd") == "Thermal control input · TVmd")
        #expect(sensors.knownTemperatureKeys.contains("TVmd"))
        for model in [nil, "Mac17,3"] {
            let other = XRGSMCSensors(transport: source, systemModel: model, publishedNameSource: { [:] })
            #expect(other.knownTemperatureKeys.contains("TVMD"))
            #expect(other.temperatureValues(includingUnknown: true)["TVMD"] as? Double == 1.0)
        }
    }

    @Test func providerStreamOrdinalsDoNotBecomeUnprovenPMUDieNumbers() {
        let source = SMCSensorFixture(["TRD8", "TRD9"])
        let names = ["TR9l": "Power management 2 die 9", "TRal": "Power management 2 die 10"]
        let sensors = XRGSMCSensors(transport: source, systemModel: "Mac17,4", publishedNameSource: { names })
        #expect(sensors.humanReadableName(forKey: "TRD8") == "Power management 2 temperature channel 9 · TRD8")
        #expect(sensors.humanReadableName(forKey: "TRD9") == "Power management 2 temperature channel 10 · TRD9")
        #expect(XRGSMCSensors.verifiedPublishedAlias(forKey: "TRD8", systemModel: "Mac17,4") == nil)
        let other = XRGSMCSensors(transport: source, systemModel: "Mac16,11", publishedNameSource: { names })
        #expect(other.humanReadableName(forKey: "TRD8") == "Power management stream 2 die channel 9 (average) · TRD8")
    }

    @Test func serialTemperatureMonitorsUseVerifiedProducerAndChannelOrdinals() {
        let source = SMCSensorFixture(["TDBP", "TDeL", "Ts0P", "Ts1P", "Ts00", "TDEL"])
        source.set("TDBP", 40.0); source.set("TDeL", 45.0)
        let sensors = XRGSMCSensors(transport: source, systemModel: "Mac17,4", publishedNameSource: { [:] })
        #expect(sensors.humanReadableName(forKey: "TDBP") == "Temperature monitor 1 channel 1 · TDBP")
        #expect(sensors.humanReadableName(forKey: "TDeL") == "Temperature monitor 1 channel 2 · TDeL")
        #expect(sensors.humanReadableName(forKey: "Ts0P") == "Temperature monitor 2 channel 1 · Ts0P")
        #expect(sensors.humanReadableName(forKey: "Ts1P") == "Temperature monitor 2 channel 2 · Ts1P")
        #expect(sensors.humanReadableName(forKey: "Ts00") == "Temperature sensor · Ts00")
        #expect(sensors.humanReadableName(forKey: "TDEL") == "Temperature sensor · TDEL")
        #expect(sensors.temperatureValues(includingUnknown: true)["TDBP"] as? Double == 40.0)
        #expect(sensors.temperatureValues(includingUnknown: true)["TDeL"] as? Double == 45.0)
        let other = XRGSMCSensors(transport: source, systemModel: "Mac16,11", publishedNameSource: { [:] })
        #expect(other.humanReadableName(forKey: "Ts0P") == "Temperature sensor · Ts0P")
    }

    @Test func adjustedTemperatureAggregatesKeepTheirVerifiedSourceFamilies() {
        let source = SMCSensorFixture(["TVD0", "TVDA", "TVDG", "TVDP", "TVDE", "TVV0"])
        let sensors = XRGSMCSensors(transport: source, systemModel: "Mac17,4", publishedNameSource: { [:] })
        #expect(sensors.humanReadableName(forKey: "TVD0") == "Adjusted temperature maximum · TVD0")
        #expect(sensors.humanReadableName(forKey: "TVDA") == "Adjusted temperature maximum · TVDA")
        #expect(sensors.humanReadableName(forKey: "TVDG") == "GPU temperature maximum (adjusted) · TVDG")
        #expect(sensors.humanReadableName(forKey: "TVDP") == "CPU temperature maximum (adjusted) · TVDP")
        #expect(sensors.humanReadableName(forKey: "TVDE") == "CPU efficiency temperature maximum (adjusted) · TVDE")
        #expect(sensors.humanReadableName(forKey: "TVV0") == "Temperature maximum (selected channels) · TVV0")
        #expect(XRGSMCSensors.verifiedTemperatureName(forKey: "TVDA", systemModel: nil) == nil)
        #expect(XRGSMCSensors.verifiedTemperatureName(forKey: "TVDG", systemModel: "Mac16,11") == nil)
    }

    @Test func computedModelLabelsDescribeRolesWithoutInventingPhysicalLocations() {
        let models = ["TVS1", "TVS0", "TVA0", "TVAC", "TVN0", "TVN1"]
        let source = SMCSensorFixture(models + ["TVMR", "TVmS", "TVNS"])
        let sensors = XRGSMCSensors(transport: source, systemModel: "Mac17,4", publishedNameSource: { [:] })
        for (index, key) in models.enumerated() {
            #expect(sensors.humanReadableName(forKey: key) == "Fixed thermal model \(index + 1) · \(key)")
        }
        #expect(sensors.humanReadableName(forKey: "TVMR") == "Adaptive thermal model · TVMR")
        #expect(sensors.humanReadableName(forKey: "TVmS") == "Bounded thermal model output · TVmS")
        #expect(sensors.humanReadableName(forKey: "TVNS") == "Thermal model maximum · TVNS")
        for key in ["TVAC", "TVN1", "TVMR", "TVmS", "TVNS"] {
            #expect(XRGSMCSensors.verifiedTemperatureName(forKey: key, systemModel: "Mac16,11") == nil)
        }
        let m4 = XRGSMCSensors(transport: source, systemModel: "Mac16,11", publishedNameSource: { [:] })
        for (index, key) in ["TVS0", "TVS1", "TVA0", "TVN0"].enumerated() {
            #expect(m4.humanReadableName(forKey: key) == "Fixed thermal model \(index + 1) · \(key)")
        }
    }

    @Test func m4MaximaDoNotInheritCPUOnlyOrM5AdjustedRoles() {
        let source = SMCSensorFixture(["TCMb", "TCMz", "TVD0"])
        let sensors = XRGSMCSensors(transport: source, systemModel: "Mac16,11", publishedNameSource: { [:] })
        for key in ["TCMb", "TCMz", "TVD0"] {
            #expect(sensors.humanReadableName(forKey: key) == "Temperature maximum (selected channels) · \(key)")
        }
        #expect(XRGSMCSensors.verifiedTemperatureName(forKey: "TCMb", systemModel: "Mac17,4") == "Adjusted temperature maximum")
        #expect(XRGSMCSensors.verifiedTemperatureName(forKey: "TCMz", systemModel: nil) == nil)
    }

    @Test func m4PMUStreamsKeepTheirAverageRolesAndSkippedChannels() {
        let suffixes = Array("0123456789ABCDEG")
        let keys = ["TPD", "TRD", "TTD"].flatMap { prefix in suffixes.map { prefix + String($0) } }
        let source = SMCSensorFixture(keys + ["TPDF", "TRDF", "TTDF", "Ta0p", "Tm0p", "Tm1p", "TPDX", "TRDX", "TTDX"])
        let canonical = ["TP1b", "TP2b", "TP3b", "TP4b", "TP5b", "TP6b", "TP7b", "TP8b", "TP9b", "TPab", "TPbl", "TPcl", "TPdl", "TPel"]
        var names = Dictionary(uniqueKeysWithValues: canonical.enumerated().map { ($0.element, "Power management die \($0.offset + 1)") })
        names["TP3d"] = "Power management device 3"; names["TP5d"] = "Power management device 5"
        let sensors = XRGSMCSensors(transport: source, systemModel: "Mac16,11", publishedNameSource: { names })
        for (index, suffix) in suffixes.enumerated() {
            let channel = index == 15 ? 17 : index + 1
            for (stream, prefix) in ["TPD", "TRD", "TTD"].enumerated() {
                let key = prefix + String(suffix)
                let label = stream == 0 && index < 14 ? "Power management die \(channel) (average)" : "Power management stream \(stream + 1) die channel \(channel) (average)"
                #expect(sensors.humanReadableName(forKey: key) == "\(label) · \(key)")
            }
        }
        for key in ["TPDF", "TRDF", "TTDF"] {
            #expect(sensors.humanReadableName(forKey: key) == "Temperature sensor · \(key)")
        }
        #expect(sensors.humanReadableName(forKey: "Ta0p") == "Power management device 3 · Ta0p")
        #expect(sensors.humanReadableName(forKey: "Tm0p") == "Power management device 5 · Tm0p")
        #expect(sensors.humanReadableName(forKey: "Tm1p") == "Power management stream 3 device channel 2 · Tm1p")
        for key in ["TPDX", "TRDX", "TTDX"] {
            #expect(sensors.humanReadableName(forKey: key) == "Temperature maximum (selected channels) · \(key)")
        }
        names = [:]; sensors.reloadInventory()
        #expect(sensors.humanReadableName(forKey: "TPD0") == "Temperature sensor · TPD0")
        #expect(sensors.humanReadableName(forKey: "Ta0p") == "Temperature sensor · Ta0p")
        #expect(XRGSMCSensors.verifiedPublishedAlias(forKey: "TPDD", systemModel: "Mac17,4") == nil)
        #expect(XRGSMCSensors.verifiedTemperatureName(forKey: "TTDG", systemModel: "Mac17,4") == nil)
    }

    @Test func m4PMUDeviceLabelsReplaceMisleadingComponentFamilies() {
        let keys = ["TMIA", "TH0p", "TPMP", "TW0P", "TNwC", "TMVR", "TSCW"]
        let source = SMCSensorFixture(keys)
        var names = ["TP1d": "Power management device 1", "TP6d": "Power management device 6", "TP8d": "Power management device 8"]
        let sensors = XRGSMCSensors(transport: source, systemModel: "Mac16,11", publishedNameSource: { names })
        #expect(sensors.humanReadableName(forKey: "TMIA") == "Power management device 1 · TMIA")
        #expect(sensors.humanReadableName(forKey: "TH0p") == "Power management device 6 · TH0p")
        #expect(sensors.humanReadableName(forKey: "TPMP") == "Power management device 8 · TPMP")
        #expect(sensors.humanReadableName(forKey: "TW0P") == "Power management stream 2 device channel 2 · TW0P")
        #expect(sensors.humanReadableName(forKey: "TNwC") == "Power management stream 2 device channel 4 · TNwC")
        #expect(sensors.humanReadableName(forKey: "TMVR") == "Power management stream 2 device channel 7 · TMVR")
        #expect(sensors.humanReadableName(forKey: "TSCW") == "Power management stream 3 device channel 4 · TSCW")
        names = [:]; sensors.reloadInventory()
        #expect(sensors.humanReadableName(forKey: "TMIA") == "Temperature sensor · TMIA")
        #expect(sensors.humanReadableName(forKey: "TH0p") == "Temperature sensor · TH0p")
        #expect(XRGSMCSensors.verifiedPublishedAlias(forKey: "TH0p", systemModel: "Mac16,10") == nil)
        #expect(XRGSMCSensors.verifiedTemperatureName(forKey: "TSCW", systemModel: "Mac17,4") == nil)
    }

    @Test func m4CalibratedChannelsAndMaximumDoNotAcquireUnprovedDriveLocations() {
        let source = SMCSensorFixture(["TH0a", "TH0b", "TH0x"])
        source.set("TH0a", 0.0); source.set("TH0b", 40.0); source.set("TH0x", 40.0)
        let sensors = XRGSMCSensors(transport: source, systemModel: "Mac16,11", publishedNameSource: { [:] })
        #expect(sensors.humanReadableName(forKey: "TH0a") == "Calibrated temperature channel 1 · TH0a")
        #expect(sensors.humanReadableName(forKey: "TH0b") == "Calibrated temperature channel 2 · TH0b")
        #expect(sensors.humanReadableName(forKey: "TH0x") == "Temperature maximum (calibrated channels) · TH0x")
        #expect(sensors.temperatureValues(includingUnknown: true)["TH0a"] as? Double == 0.0)
        let m5 = XRGSMCSensors(transport: source, systemModel: "Mac17,4", publishedNameSource: { ["TR2d": "Power management 2 device 2"] })
        #expect(m5.humanReadableName(forKey: "TH0x") == "Power management 2 device 2 · TH0x")
        #expect(XRGSMCSensors.verifiedTemperatureName(forKey: "TH0a", systemModel: nil) == nil)
        #expect(XRGSMCSensors.verifiedTemperatureName(forKey: "TH0b", systemModel: "Mac17,4") == nil)
    }

    @Test func m5SuppliedInputUsesVerifiedAmbientLightSensorSource() {
        let source = SMCSensorFixture(["TAOL", "RBr "])
        source.set("TAOL", 0.0); source.set("RBr ", Data("m87".utf8))
        let sensors = XRGSMCSensors(transport: source, branchNameSource: { _ in ["TAOL": "Ambient temperature"] },
                                   systemModel: "Mac17,4", publishedNameSource: { [:] })
        #expect(sensors.humanReadableName(forKey: "TAOL") == "Ambient light sensor temperature · TAOL")
        #expect(sensors.temperatureValues(includingUnknown: true)["TAOL"] as? Double == 0.0)
        #expect(XRGSMCSensors.verifiedTemperatureName(forKey: "TAOL", systemModel: "Mac16,11") == nil)
        #expect(XRGSMCSensors.verifiedTemperatureName(forKey: "TAOL", systemModel: nil) == nil)
    }

    @Test func m4TelemetryLabelsPreserveVerifiedPowerManagementMaximumRoles() {
        let keys = ["TfC0", "TfC1", "TfC2", "TfC3", "TfC4"]
        let source = SMCSensorFixture(keys + ["TfC5", "TFC0"])
        source.set("TfC0", 0.0)
        let sensors = XRGSMCSensors(transport: source, systemModel: "Mac16,11", publishedNameSource: { [:] })
        for (index, key) in keys.enumerated() {
            #expect(sensors.humanReadableName(forKey: key) == "Power management temperature maximum \(index + 1) (filtered average) · \(key)")
            #expect(XRGSMCSensors.verifiedTemperatureName(forKey: key, systemModel: "Mac17,4") == nil)
        }
        #expect(sensors.temperatureValues(includingUnknown: true)["TfC0"] as? Double == 0.0)
        #expect(sensors.humanReadableName(forKey: "TfC5") == "Temperature sensor · TfC5")
        #expect(XRGSMCSensors.verifiedTemperatureName(forKey: "TFC0", systemModel: "Mac16,11") == nil)
        #expect(XRGSMCSensors.verifiedTemperatureName(forKey: "TfC0", systemModel: nil) == nil)
    }

    @Test func boundedLegacyCatalogueDecoderRejectsAmbiguousBranchesAndChangedLayouts() {
        func word(_ value: UInt64, _ offset: Int, into data: inout Data, width: Int = 8) {
            for i in 0..<width { data[offset+i] = UInt8(truncatingIfNeeded: value >> (8*i)) }
        }
        func row(_ branch: String, count: UInt64 = 1) -> Data {
            var data = Data(repeating: 0, count: 48)
            data.replaceSubrange(0..<branch.utf8.count, with: branch.utf8)
            word(0x2000, 16, into: &data); word(count, 32, into: &data, width: 4)
            return data
        }
        func description(_ label: String) -> Data {
            var data = Data(repeating: 0, count: 272)
            data.replaceSubrange(0..<4, with: "P0mT".utf8)
            data.replaceSubrange(5..<(5+label.utf8.count), with: label.utf8)
            data[261] = 2; data.replaceSubrange(264..<268, with: "87ps".utf8)
            return data
        }
        var memory = [UInt64(0x1000): row("m87"), 0x1030: Data(repeating: 0, count: 48),
                      0x2000: description("Charger proximity (Tm0P)")]
        var requests = 0
        func decode(_ branch: String) -> [String: String] {
            XRGSMCBranchNames.decode(branch: branch, address: 0x1000) { address, count in
                requests += 1
                guard let bytes = memory[address], bytes.count == count else { return nil }
                return bytes
            }
        }
        #expect(decode("m87") == ["Tm0P": "Charger proximity"])
        #expect(decode("M87").isEmpty && decode("J815").isEmpty)
        memory[0x1030] = row("m87"); #expect(decode("m87").isEmpty)
        memory[0x1030] = Data(repeating: 0, count: 48)
        memory[0x1000] = row("m87", count: 10_001); #expect(decode("m87").isEmpty)
        memory[0x1000] = row("m87")
        memory[0x2000] = description("bad\nname"); #expect(decode("m87").isEmpty)
        memory[0x2000] = description("Charger proximity")
        memory[0x2000]![268] = 1; #expect(decode("m87").isEmpty)
        memory[0x2000] = nil; #expect(decode("m87").isEmpty)
        #expect(requests < 30)
        var boundedReads = 0
        let noBoundary = XRGSMCBranchNames.decode(branch: "m87", address: 0x1000) { _, _ in
            boundedReads += 1; return row("other")
        }
        #expect(noBoundary.isEmpty && boundedReads == 256)
        #expect(XRGSMCBranchNames.decode(branch: "m87", address: UInt64.max) { _, _ in
            Issue.record("Overflow address must not be read"); return nil
        }.isEmpty)
    }
    struct Sample:Sendable {let type:UInt32;let bytes:[UInt8];let value:Double}
    static let numbers:[Sample] = [
        .init(type:0x75693820,bytes:[255],value:255),.init(type:0x75693136,bytes:[0x12,0x34],value:4660),
        .init(type:0x75693332,bytes:[255,255,255,255],value:4294967295),
        .init(type:0x73693820,bytes:[128],value:-128),.init(type:0x73693136,bytes:[255,246],value:-10),
        .init(type:0x73693332,bytes:[255,255,255,254],value:-2),
        .init(type:0x73703738,bytes:[0x19,0x66],value:25.3984375),
        .init(type:0x73703738,bytes:[0xff,0x80],value:-0.5),
        .init(type:0x73703738,bytes:[0x7f,0xe7],value:127.90234375),
        .init(type:0x73703738,bytes:[0x80,0],value:-128),
        .init(type:0x66706532,bytes:[0x12,0x34],value:1165),.init(type:0x66706532,bytes:[0,7],value:1.75),
        .init(type:0x73706234,bytes:[0xff,0xf8],value:-0.5),
        .init(type:0x666c7420,bytes:[0,0,0x48,0x42],value:50)]
    @Test(arguments: numbers) func numericFormatsUseTheirFullSignedAndFractionalPrecision(_ sample:Sample) throws {
        let number=try #require(XRGSMCReader.decode(Data(sample.bytes),type:sample.type) as? NSNumber)
        #expect(number.doubleValue == sample.value)
    }
    @Test func invalidWidthsAndNonfiniteValuesAreUnavailableAndUnknownTypesRemainRaw() {
        for type:UInt32 in [0x75693820,0x75693136,0x75693332,0x73693136,0x73703738,0x66706532,0x666c7420] {
            #expect(XRGSMCReader.decode(Data(),type:type) == nil)
            #expect(XRGSMCReader.decode(Data(repeating:0,count:33),type:type) == nil)
        }
        #expect(XRGSMCReader.decode(Data([1,2,3,4,5]),type:0x75693332) == nil)
        #expect(XRGSMCReader.decode(Data([0,0,0xc0,0x7f]),type:0x666c7420) == nil)
        #expect(XRGSMCReader.decode(Data([1,2,3]),type:0) as? Data == Data([1,2,3]))
        #expect((XRGSMCReader.decode(Data([2]),type:0x666c6167) as? NSNumber)?.boolValue == true)
    }
    @Test func packetABIAndMetadataCacheAreReadOnlyAndBounded() throws {
        let data=XRGSMCWire.message(.value,key:0x54433050,width:2)
        #expect(data.count == 80 && Array(data[0..<4]) == [0x50,0x30,0x43,0x54] && data[42] == 5)
        #expect(Array(data[28..<32]) == [2,0,0,0] && data[32..<40].allSatisfy {$0 == 0})
        let fixture=SMCChannelFixture(),reader=XRGSMCReader(channel:fixture)
        #expect(try (reader.value(0x54433050) as? NSNumber)?.doubleValue == 25.3984375)
        _=try reader.value(0x54433050);#expect(fixture.commands == [9,5,5])
        #expect(reader.key(at:-1) == nil && reader.key(at:Int.max) == nil && reader.key(at:65536) == nil)
        #expect(reader.key(at:0)?.uint32Value == 0x54433050)
    }
    @Test(arguments:[UInt32(0),3,33,UInt32.max]) func invalidMetadataIsNeverCached(_ width:UInt32) {
        let fixture=SMCChannelFixture();fixture.width=width
        let reader=XRGSMCReader(channel:fixture)
        #expect(throws:(any Error).self) {try reader.value(0x54433050)}
        fixture.width=2;#expect(reader.readValue(for:0x54433050) != nil)
        #expect(fixture.commands == [9,9,5])
    }
    @Test func failuresCannotPublishValuesAndRecoveryRemainsPossible() {
        let source=SMCChannelFixture(), reader=XRGSMCReader(channel:SMCChannelFixture())
        #expect(reader.readValue(for:0) == nil)
        let checked=XRGSMCReader(channel:source)
        source.failure=kIOReturnError;#expect(checked.readValue(for:0x54433050) == nil)
        source.failure=nil;source.result=0x84;#expect(checked.readValue(for:0x54433050) == nil)
        source.result=1;#expect(checked.readValue(for:0x54433050) == nil)
        source.result=0;source.replyLength=79;#expect(checked.readValue(for:0x54433050) == nil)
        source.replyLength=80;#expect(checked.readValue(for:0x54433050) != nil)
    }
    @Test func transportFailureInvalidatesFormatsBeforeAReconnectedDeviceIsRead() throws {
        let source=SMCChannelFixture(),reader=XRGSMCReader(channel:source)
        _=try reader.value(0x54433050)
        source.failure=kIOReturnNoDevice
        #expect(reader.readValue(for:0x54433050) == nil)
        source.failure=nil;source.width=4;source.type=0x666c7420;source.payload=[0,0,0x48,0x42]
        #expect(reader.readValue(for:0x54433050) as? NSNumber == 50)
        #expect(source.commands == [9,5,5,9,5])
    }
    @Test func aTemperaturePrefixAloneDoesNotMakeAnIntegerCounterACelsiusReading() {
        let source=SMCChannelFixture();source.width=4;source.type=0x75693332;source.payload=[0,0,0,40]
        let reader=XRGSMCReader(channel:source)
        #expect(reader.readValue(for:0x54433050) as? NSNumber == 40)
        #expect(reader.temperatureValue(for:0x54433050) == nil)
        let high=SMCChannelFixture();high.type=0x666c7420;high.width=4;high.payload=[0,0,0x7a,0x44]
        #expect(XRGSMCReader(channel:high).temperatureValue(for:0x54433050) == nil)
    }
    @Test func inventoryKeysAndGeneratedNamesPreserveSavedIdentitiesWithoutACatalogFile() {
        let source=SMCSensorFixture(["TC0P","Tp01","TCAC","F0Ac","F0Mx","F1Tg"])
        source.set("TC0P",50);source.set("Tp01",0);source.set("TCAC",10);source.set("F0Ac",0);source.set("F0Mx",6000)
        let sensors=XRGSMCSensors(transport:source)
        #expect(sensors.knownTemperatureKeys == ["TC0P","Tp01"])
        #expect(sensors.temperatureValues(includingUnknown:false) as? [String:Int] == ["TC0P":50,"Tp01":0])
        #expect(sensors.temperatureValues(includingUnknown:true)["TCAC"] == nil)
        #expect(sensors.humanReadableName(forKey:"TC0P").contains("TC0P"))
        #expect(sensors.isKnownKey("F0Ac") && !sensors.isKnownKey("F1Tg"))
        let fans=sensors.fanValues as? [String:[String:Int]]
        #expect(fans?["Fan #0"]?["F0Ac"] == 0 && fans?["Fan #0"]?["F0Mx"] == 6000 && fans?["Fan #1"] == nil)
        source.values.removeAll();#expect(sensors.fanValues.isEmpty && sensors.temperatureValues(includingUnknown:true).isEmpty)
    }
    @Test func thermalBoolsRawDataAndNonfiniteReadingsNeverBecomeTemperatures() {
        let source=SMCSensorFixture(["TC0P","TC1P","TC2P","TC3P"])
        source.set("TC0P",true);source.set("TC1P",Data([1,2]));source.set("TC2P",Double.nan);source.set("TC3P",Double.infinity)
        #expect(XRGSMCSensors(transport:source).temperatureValues(includingUnknown:true).isEmpty)
    }
    @Test(arguments:[-1,65537,Int.max]) func unreasonableInventoriesDoNotEnumerate(_ count:Int) {
        let source=SMCSensorFixture([]);source.countOverride=count
        #expect(XRGSMCSensors(transport:source).knownTemperatureKeys.isEmpty && source.indices.isEmpty)
    }
    @Test func badAndAmbiguousKeysDoNotAliasAnotherSensor() {
        let source=SMCSensorFixture(["TC0P","TC0P","TC1P"])
        source.keys += [nil,-1,NSNumber(value:true),1.5,NSNumber(value:UInt64.max)]
        #expect(XRGSMCSensors(transport:source).knownTemperatureKeys == ["TC1P"])
        for text in ["","TC0","TC0PX","温度AA","😀AB","T\n0P"] {#expect(XRGSMCSensors.code(text) == nil)}
        #expect(XRGSMCSensors.name(0x46532120) == "FS! " && XRGSMCSensors.code("TC0P") == 0x54433050)
        #expect(XRGSMCSensors(transport:nil).fanValues.isEmpty)
    }

    // Best names from GPT-verified roles, Apple, Stats (MIT) and Asahi Linux
    // (GPL-2.0+ OR MIT). See XRGCore/XRGSMCCommunityNames.swift.
    @Test func macChipParsesBrandsLikeStatsAndTheModelTableCoversEveryMac() {
        #expect(XRGMacChip(brand: "Apple M4 Pro") == XRGMacChip(.m(4), tier: .pro))
        #expect(XRGMacChip(brand: "Apple M5") == XRGMacChip(.m(5)))
        #expect(XRGMacChip(brand: "Apple M1 Max") == XRGMacChip(.m(1), tier: .max))
        #expect(XRGMacChip(brand: "Apple M2 Ultra") == XRGMacChip(.m(2), tier: .ultra))
        #expect(XRGMacChip(brand: "Apple A18 Pro") == XRGMacChip(.a18Pro))
        #expect(XRGMacChip(brand: "Intel(R) Core(TM) i9-9880H CPU @ 2.30GHz") == XRGMacChip(.intel))
        for brand in ["", "Apple", "Apple Mx", "VirtualApple @ 2.50GHz processor"] {
            #expect(XRGMacChip(brand: brand) == nil)
        }
        #expect(XRGMacModels.model("Mac16,11")?.chip == XRGMacChip(.m(4), tier: .pro))
        #expect(XRGMacModels.model("Mac16,11")?.board == "J773s" && XRGMacModels.model("Mac16,11")?.form == .mini)
        #expect(XRGMacModels.model("Mac17,4")?.board == "J815" && XRGMacModels.model("Mac17,4")?.form == .laptop)
        #expect(XRGMacModels.model("Mac15,14")?.chip == XRGMacChip(.m(3), tier: .ultra))
        #expect(XRGMacModels.model("Mac15,4")?.form == .iMac)
        #expect(XRGMacModels.model("Mac17,5")?.chip == XRGMacChip(.a18Pro))
        for intel in ["MacBookPro16,1", "MacBookPro16,2", "MacBookPro16,4", "iMac20,1", "iMac20,2", "MacPro7,1"] {
            #expect(XRGMacModels.model(intel)?.chip == XRGMacChip(.intel))
        }
        #expect(XRGMacModels.model("MacBookPro16,3") == nil && XRGMacModels.model("Macmini8,1") == nil)
        #expect(Set(XRGMacModels.all.map(\.identifier)).count == XRGMacModels.all.count)
        #expect(XRGMacChip.host(model: "Mac16,11") == XRGMacChip(.m(4), tier: .pro))
    }

    @Test func communityNamesRequireAChip() {
        let source = SMCSensorFixture(["Tp01", "TW0P", "TH0x"])
        for model in [nil, "Mac16,11", "Mac17,4"] {
            let sensors = XRGSMCSensors(transport: source, systemModel: model, publishedNameSource: { [:] })
            #expect(!sensors.humanReadableName(forKey: "Tp01").hasPrefix("CPU performance core"))
            #expect(!sensors.humanReadableName(forKey: "TW0P").hasPrefix("Wi-Fi"))
        }
        #expect(XRGSMCCommunityNames.name(forKey: "TW0P", chip: nil, systemModel: "Mac16,11") == nil)
    }

    @Test func m4ProMiniUsesOneBestNamePerSensorAndGroupsThem() {
        let source = SMCSensorFixture(["Te05", "Tp01", "Tp0e", "Tg1U", "Tg0G", "Tg0k", "Tm0p", "Tm1p", "Tm2p", "TW0P",
                                       "TH0a", "TH0b", "TH0x", "Ta00", "Ts00", "TPD0", "TCMb", "Tz11", "TPDF", "Tq01"])
        let names = ["TP5d": "Power management device 5", "TP1b": "Power management die 1"]
        let sensors = XRGSMCSensors(transport: source, systemModel: "Mac16,11", publishedNameSource: { names },
                                    chip: XRGMacChip(.m(4), tier: .pro))
        func expectName(_ key: String, _ name: String, _ group: XRGSensorGroup = .identified) {
            #expect(sensors.humanReadableName(forKey: key) == "\(name) · \(key)")
            #expect(sensors.sensorGroup(forKey: key) == group.rawValue)
        }
        expectName("Te05", "CPU efficiency core 1")
        expectName("Tp01", "CPU performance core 1")
        expectName("Tp0e", "CPU performance core 8")
        expectName("Tg1U", "GPU 1")
        expectName("Tg0k", "GPU 8")
        // Stats assigns Tg0G to the base M4 only.
        expectName("Tg0G", "GPU temperature", .unidentified)
        // Community component names beat channel-only verified names.
        expectName("Tm0p", "Memory proximity 1")
        expectName("Tm1p", "Memory proximity 2")
        expectName("Tm2p", "Memory proximity 3")
        expectName("TW0P", "Wi-Fi/Bluetooth module temperature")
        expectName("TH0a", "NAND flash temperature 1")
        expectName("TH0b", "NAND flash temperature 2")
        expectName("TH0x", "NAND flash temperature (hottest)")
        // Verified names with no better competitor are kept.
        expectName("Ta00", "Neural Engine temperature channel 1")
        expectName("Ts00", "SoC die temperature channel 1 (average)")
        expectName("TPD0", "Power management die 1 (average)")
        expectName("TCMb", "Temperature maximum (selected channels)")
        // No producer writes these on this model.
        expectName("Tz11", "Temperature sensor", .suspectedUnused)
        expectName("TPDF", "Temperature sensor", .suspectedUnused)
        expectName("Tq01", "Temperature sensor", .unidentified)
        let base = XRGSMCSensors(transport: source, systemModel: "Mac16,10", publishedNameSource: { [:] },
                                 chip: XRGMacChip(.m(4)))
        #expect(base.humanReadableName(forKey: "Tg0G") == "GPU 1 · Tg0G")
        #expect(base.humanReadableName(forKey: "Tg1U") == "GPU temperature · Tg1U")
        #expect(base.sensorGroup(forKey: "Tz11") == XRGSensorGroup.unidentified.rawValue)
    }

    @Test func m5AirUsesOneBestNamePerSensorAndMarksCrossModelInference() {
        let m5 = XRGMacChip(.m(5))
        let source = SMCSensorFixture(["Tp00", "Tp0C", "Tp0G", "Tp0O", "Tg0U", "Tg1g", "TW0P", "TCHP", "TH0T", "TH0x",
                                       "TB0T", "TB1T", "Ta00", "Ta0R", "Ts00", "Ts0R", "Ts0P", "Tz11", "TPDD", "TMVR", "TAOL"])
        let names = ["TP4d": "Power management device 4", "TP7d": "Power management device 7",
                     "TP8d": "Power management device 8", "TR2d": "Power management 2 device 2"]
        let sensors = XRGSMCSensors(transport: source, systemModel: "Mac17,4", publishedNameSource: { names }, chip: m5)
        let expected = [
            "Tp00": "CPU super core 1", "Tp0C": "CPU super core 4",
            // The base M5 has four super cores and no performance-core tier.
            "Tp0G": "CPU temperature", "Tp0O": "CPU temperature",
            "Tg0U": "GPU 1", "Tg1g": "GPU 8",
            "TW0P": "Wi-Fi/Bluetooth module temperature", "TCHP": "Charge regulator temperature",
            "TH0T": "NAND flash temperature", "TH0x": "NAND flash temperature",
            "TB0T": "Battery hotspot", "TB1T": "Battery 1",
            "Ta00": "Neural Engine temperature 1 (probable)", "Ta0R": "Neural Engine temperature 6 (probable)",
            "Ts00": "SoC die temperature 1 (probable)", "Ts0R": "SoC die temperature 8 (probable)",
            "Ts0P": "Temperature monitor 2 channel 1", "TMVR": "Power management device 8",
            "TAOL": "Ambient light sensor temperature", "Tz11": "Temperature sensor", "TPDD": "Temperature sensor",
        ]
        for (key, name) in expected { #expect(sensors.humanReadableName(forKey: key) == "\(name) · \(key)") }
        #expect(sensors.sensorGroup(forKey: "Tp0G") == XRGSensorGroup.unidentified.rawValue)
        #expect(sensors.sensorGroup(forKey: "Ts0P") == XRGSensorGroup.identified.rawValue)
        #expect(sensors.sensorGroup(forKey: "Tz11") == XRGSensorGroup.suspectedUnused.rawValue)
        #expect(sensors.sensorGroup(forKey: "TPDD") == XRGSensorGroup.suspectedUnused.rawValue)
        // A verified alias with neither metadata nor a community name stays generic.
        let bare = XRGSMCSensors(transport: source, systemModel: "Mac17,4", publishedNameSource: { [:] }, chip: m5)
        #expect(bare.humanReadableName(forKey: "TCHP") == "Charge regulator temperature · TCHP")
        #expect(bare.humanReadableName(forKey: "TMVR") == "Temperature sensor · TMVR")
        #expect(bare.sensorGroup(forKey: "TMVR") == XRGSensorGroup.unidentified.rawValue)
        let pro = XRGSMCSensors(transport: source, systemModel: "Mac17,9", publishedNameSource: { [:] },
                                chip: XRGMacChip(.m(5), tier: .pro))
        #expect(pro.humanReadableName(forKey: "Tp0G") == "CPU super core 5 · Tp0G")
        #expect(pro.humanReadableName(forKey: "Tp0O") == "CPU performance core 1 · Tp0O")
        // The cross-model inference is limited to the validated model.
        #expect(pro.humanReadableName(forKey: "Ta00") == "Temperature sensor · Ta00")
        // Asahi scopes battery and charger names to laptops; the family fallback remains.
        let studio = XRGSMCSensors(transport: source, systemModel: "Mac17,14", publishedNameSource: { [:] },
                                   chip: XRGMacChip(.m(5), tier: .max))
        #expect(studio.humanReadableName(forKey: "TCHP") == "CPU temperature · TCHP")
        #expect(studio.sensorGroup(forKey: "TCHP") == XRGSensorGroup.unidentified.rawValue)
        #expect(studio.humanReadableName(forKey: "TH0x") == "NAND flash temperature · TH0x")
    }

    @Test func intelMacsUseStatsNamesBelowApplesBoardDescriptions() {
        let source = SMCSensorFixture(["RBr ", "TC0P", "TC2c", "TA1P", "TH0A", "Tm0P", "TG0D", "TW0P", "Tx9Q"])
        source.set("RBr ", Data("j152f".utf8))
        let sensors = XRGSMCSensors(transport: source, branchNameSource: { _ in ["TG0D": "GPU Die"] },
                                    systemModel: "MacBookPro16,1", publishedNameSource: { [:] }, chip: XRGMacChip(.intel))
        #expect(sensors.humanReadableName(forKey: "TC0P") == "CPU proximity · TC0P")
        #expect(sensors.humanReadableName(forKey: "TC2c") == "CPU core 3 · TC2c")
        #expect(sensors.humanReadableName(forKey: "TA1P") == "Ambient 2 · TA1P")
        #expect(sensors.humanReadableName(forKey: "TH0A") == "Disk 1 (A) · TH0A")
        #expect(sensors.humanReadableName(forKey: "Tm0P") == "Mainboard · Tm0P")
        #expect(sensors.humanReadableName(forKey: "TG0D") == "GPU Die · TG0D")
        #expect(sensors.humanReadableName(forKey: "TW0P") == "Airport · TW0P")
        #expect(sensors.sensorGroup(forKey: "Tx9Q") == XRGSensorGroup.unidentified.rawValue)
        #expect(XRGSMCCommunityNames.statsIntelName(forKey: "TC٣c") == nil)
    }

    @Test func statsGenerationTablesFollowTheirChipFamilies() {
        func name(_ key: String, _ chip: XRGMacChip) -> String? {
            XRGSMCCommunityNames.name(forKey: key, chip: chip, systemModel: nil)
        }
        #expect(name("Tp09", XRGMacChip(.m(1))) == "CPU efficiency core 1")
        #expect(name("Tp09", XRGMacChip(.m(2), tier: .max)) == "CPU performance core 3")
        #expect(name("Tm02", XRGMacChip(.m(1), tier: .ultra)) == "Memory 1")
        #expect(name("Tf4E", XRGMacChip(.m(3), tier: .pro)) == "CPU performance core 12")
        #expect(name("Tf2A", XRGMacChip(.m(3))) == "GPU 8")
        #expect(name("Tp09", XRGMacChip(.m(6))) == "CPU super core 3")
        #expect(name("Te0i", XRGMacChip(.m(6))) == "CPU efficiency core 6")
        #expect(name("Tg1h", XRGMacChip(.m(6))) == "GPU 12")
        #expect(name("Tp05", XRGMacChip(.a18Pro)) == "CPU performance core 1")
        #expect(name("Tg0e", XRGMacChip(.a18Pro)) == "GPU 4")
        #expect(name("TaLP", XRGMacChip(.m(2))) == "Airflow left")
        #expect(name("TH0x", XRGMacChip(.m(2))) == "NAND flash temperature")
        #expect(name("Tf04", XRGMacChip(.m(4))) == nil)
        #expect(name("Tp01", XRGMacChip(.m(7))) == nil)
        #expect(name("TH0T", XRGMacChip(.m(5))) == nil)
        #expect(name("TC0P", XRGMacChip(.m(5))) == nil)
    }

    @Test func statsHIDProductNamesAreOneBasedAndRejectMalformedIndices() {
        #expect(XRGSMCSensors.hidName(forKey: "pACC MTR Temp Sensor0", systemModel: nil) == "CPU performance core 1 · pACC MTR Temp Sensor0")
        #expect(XRGSMCSensors.hidName(forKey: "eACC MTR Temp Sensor3", systemModel: nil) == "CPU efficiency core 4 · eACC MTR Temp Sensor3")
        #expect(XRGSMCSensors.hidName(forKey: "GPU MTR Temp Sensor12", systemModel: nil) == "GPU core 13 · GPU MTR Temp Sensor12")
        #expect(XRGSMCSensors.hidName(forKey: "SOC MTR Temp Sensor1", systemModel: nil) == "SoC core 2 · SOC MTR Temp Sensor1")
        #expect(XRGSMCSensors.hidName(forKey: "ANE MTR Temp Sensor0", systemModel: nil) == "Neural Engine 1 · ANE MTR Temp Sensor0")
        #expect(XRGSMCSensors.hidName(forKey: "ISP MTR Temp Sensor0", systemModel: nil) == "Image signal processor 1 · ISP MTR Temp Sensor0")
        #expect(XRGSMCSensors.hidName(forKey: "PMGR SOC Die Temp Sensor2", systemModel: nil) == "Power manager die 3 · PMGR SOC Die Temp Sensor2")
        for product in ["GPU MTR Temp Sensor", "GPU MTR Temp Sensor-1", "GPU MTR Temp Sensor+1", "GPU MTR Temp Sensor64",
                        "GPU MTR Temp Sensor123", "GPU MTR Temp Sensor1a"] {
            #expect(XRGSMCCommunityNames.hidName(forProduct: product) == nil)
        }
        #expect(XRGSMCSensors.hidSensorGroup(forKey: "PMU tdie1") == XRGSensorGroup.identified.rawValue)
        #expect(XRGSMCSensors.hidSensorGroup(forKey: "mystery probe") == XRGSensorGroup.unidentified.rawValue)
    }
}
