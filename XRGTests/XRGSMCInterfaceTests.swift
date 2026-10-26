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
import IOKit
import Testing
@testable import XRGCore

private final class PacketFixture: NSObject, XRGSMCPacketTransport {
    var metadata: [UInt32: (UInt32, UInt32)] = [0x54433050: (2, 0x73703738), 0x234b4559: (4, 0x75693332)]
    var values: [UInt32: [UInt8]] = [0x54433050: [50, 0], 0x234b4559: [0, 0, 0, 1]]
    var requests: [Data] = []
    var failInfoOnce = false
    var status: UInt8 = 0
    var kernelError: IOReturn?
    var shortReply = false
    var outputWithError = false
    func transactPacket(_ packet: Data, error: AutoreleasingUnsafeMutablePointer<NSError?>?) -> Data? {
        error?.pointee = nil; requests.append(packet)
        let b = Array(packet)
        func word(_ offset: Int) -> UInt32 { (0..<4).reduce(0) { $0 | UInt32(b[offset + $1]) << ($1 * 8) } }
        let key = word(0), command = b[42]
        var out = [UInt8](repeating: 0, count: 80)
        func put(_ value: UInt32, _ offset: Int) { for i in 0..<4 { out[offset + i] = UInt8(truncatingIfNeeded: value >> (i * 8)) } }
        if command == 9 {
            if failInfoOnce { failInfoOnce = false; error?.pointee = NSError(domain: NSMachErrorDomain, code: Int(kIOReturnError)); return nil }
            let info = metadata[key] ?? (0, 0); put(info.0, 28); put(info.1, 32)
        } else if command == 5 {
            for (index, byte) in (values[key] ?? []).prefix(32).enumerated() { out[48 + index] = byte }
        } else if command == 8 { put(0x54433050, 0) }
        out[40] = status
        if let kernelError { error?.pointee = NSError(domain: NSMachErrorDomain, code: Int(kernelError)); if !outputWithError { return nil } }
        return Data(shortReply ? Array(out.prefix(79)) : out)
    }
}
struct XRGSMCInterfaceTests {
    @Test func readPacketHasTheOriginalEightyByteLittleEndianLayoutAndZeroPadding() {
        let data = XRGSMPacket.request(command: 5, key: 0x54433050, size: 2, type: 0x73703738)
        var golden = [UInt8](repeating: 0, count: 80)
        golden.replaceSubrange(0..<4, with: [0x50, 0x30, 0x43, 0x54])
        golden.replaceSubrange(28..<36, with: [2, 0, 0, 0, 0x38, 0x37, 0x70, 0x73]); golden[42] = 5
        #expect(data == Data(golden))
        let index = Array(XRGSMPacket.request(command: 8, index: 0x12345678))
        #expect(Array(index[44..<48]) == [0x78, 0x56, 0x34, 0x12] && index[42] == 8)
        #expect(XRGSMPacket(Data(repeating: 0, count: 79)) == nil)
        #expect(XRGSMPacket(Data(repeating: 0, count: 81)) == nil)
        #expect(XRGSMPacket((Data([1, 2]) + data).dropFirst(2))?.dataType == 0x73703738)
    }
    struct NumberCase: Sendable { let type: UInt32; let bytes: [UInt8]; let value: Double }
    private static let numbers: [NumberCase] = [
        .init(type: 0x75693820, bytes: [255], value: 255), .init(type: 0x75693136, bytes: [0x12, 0x34], value: 4660),
        .init(type: 0x75693332, bytes: [0x89, 0xab, 0xcd, 0xef], value: 2309737967),
        .init(type: 0x75693332, bytes: [1, 2, 3, 4, 5], value: 33752069),
        .init(type: 0x73693820, bytes: [255], value: -1), .init(type: 0x73693820, bytes: [128], value: -128),
        .init(type: 0x73693136, bytes: [255, 246], value: -10), .init(type: 0x73693136, bytes: [0x7f, 0xff], value: 32767),
        .init(type: 0x73703738, bytes: [0x19, 0x66], value: 25.390625),
        .init(type: 0x73703738, bytes: [0x7f, 0xe7], value: Double(Float(127.9))),
        .init(type: 0x73703738, bytes: [0x80, 0], value: -128), .init(type: 0x73703738, bytes: [0x81, 0], value: -127),
        .init(type: 0x73703738, bytes: [0x82, 0], value: -126), .init(type: 0x73703738, bytes: [0x83, 0], value: -125),
        .init(type: 0x73703738, bytes: [0x84, 0], value: -124), .init(type: 0x73703738, bytes: [255, 0], value: 255),
        .init(type: 0x66706532, bytes: [0x12, 0x34], value: 1165), .init(type: 0x66706532, bytes: [0, 7], value: 1),
        .init(type: 0x666c7420, bytes: [0, 0, 0x48, 0x42], value: 50)]
    @Test(arguments: Self.numbers)
    func numericFormatsKeepTheLegacySignednessPrecisionAndSentinels(sample: NumberCase) throws {
        let value = try #require(XRGSMCInterface.decode(bytes: sample.bytes, type: sample.type) as? NSNumber)
        #expect(value.doubleValue == sample.value)
    }
    @Test func flagsUnknownTypesAndFloatSpecialValuesKeepTheirValueKinds() {
        let flag = XRGSMCInterface.decode(bytes: [2], type: 0x666c6167) as! NSNumber
        #expect(CFGetTypeID(flag) == CFBooleanGetTypeID() && flag.boolValue)
        #expect(XRGSMCInterface.decode(bytes: [1, 2], type: 0x666c6167) as? Data == Data([1, 2]))
        #expect(XRGSMCInterface.decode(bytes: [1, 2, 3], type: 0x6368382a) as? Data == Data([1, 2, 3]))
        #expect((XRGSMCInterface.decode(bytes: [0, 0, 0xc0, 0x7f], type: 0x666c7420) as? NSNumber)?.doubleValue.isNaN == true)
    }
    @Test func metadataIsCachedAndFailedQueriesDoNotPoisonTheCache() {
        let source = PacketFixture(); source.failInfoOnce = true
        let interface = XRGSMCInterface(transport: source); var error: NSError?
        #expect(interface.readValue(0x54433050, error: &error) == nil && error?.domain == NSMachErrorDomain)
        #expect(interface.readValue(0x54433050, error: &error) as? NSNumber == 50 && error == nil)
        #expect(interface.readValue(0x54433050, error: &error) as? NSNumber == 50)
        #expect(source.requests.map { Array($0)[42] } == [9, 9, 5, 5])
    }
    @Test(arguments: [UInt32(0), 33, UInt32.max])
    func invalidMetadataSizesAreRejectedBeforeReadingAndAreNotCached(size: UInt32) {
        let source = PacketFixture(); source.metadata[0x54433050] = (size, 0x73703738)
        let interface = XRGSMCInterface(transport: source); var error: NSError?
        #expect(interface.readValue(0x54433050, error: &error) == nil && error?.code == Int(kIOReturnBadArgument))
        source.metadata[0x54433050] = (2, 0x73703738)
        #expect(interface.readValue(0x54433050, error: &error) as? NSNumber == 50 && error == nil)
        #expect(source.requests.map { Array($0)[42] } == [9, 9, 5])
    }
    @Test func kernelAndSMCFailuresAndShortRepliesDoNotBecomeReadings() {
        let source = PacketFixture(), interface = XRGSMCInterface(transport: PacketFixture())
        var error: NSError? = NSError(domain: "stale", code: 1)
        #expect(interface.readValue(0, error: &error) == nil && error?.code == Int(kIOReturnCannotWire))
        let model = XRGSMCInterface(transport: source)
        source.kernelError = kIOReturnError; source.outputWithError = true
        #expect(model.readValue(0x54433050, error: &error) == nil && error?.code == Int(kIOReturnError))
        source.kernelError = nil; source.status = 0x84
        #expect(model.readValue(0x54433050, error: &error) == nil && error?.code == Int(kIOReturnNotFound))
        source.status = 1
        #expect(model.readValue(0x54433050, error: &error) == nil && error?.code == Int(kIOReturnInternalError))
        source.status = 0; source.shortReply = true
        #expect(model.readValue(0x54433050, error: &error) == nil && error?.code == Int(kIOReturnUnderrun))
        source.shortReply = false
        #expect(model.readValue(0x54433050, error: &error) as? NSNumber == 50 && error == nil)
    }
    @Test func indexAndCountQueriesKeepTheLegacySelectorsAndFailSafely() {
        let source = PacketFixture(), interface = XRGSMCInterface(transport: PacketFixture())
        #expect(interface.keyCount == 1 && interface.key(at: 0) == 0x54433050)
        #expect(interface.key(at: -1) == 0 && interface.key(at: Int.max) == 0)
        let failed = XRGSMCInterface(transport: source); source.status = 1
        #expect(failed.keyCount == 0 && failed.key(at: 0) == 0)
    }
    @Test func truncatedValuesAndOversizedBuffersFailWithoutReadingOutsideThePacket() {
        for type: UInt32 in [0x73693136, 0x73703738, 0x666c7420] { #expect(XRGSMCInterface.decode(bytes: [1], type: type) == nil) }
        #expect(XRGSMCInterface.decode(bytes: [], type: 0x75693820) == nil)
        #expect(XRGSMCInterface.decode(bytes: [UInt8](repeating: 1, count: 33), type: 0) == nil)
        #expect(XRGSMCInterface.decode(bytes: [UInt8](repeating: 1, count: 5), type: 0x66706532) == nil)
    }
}
