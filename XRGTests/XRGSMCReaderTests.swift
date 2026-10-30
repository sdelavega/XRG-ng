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
}
