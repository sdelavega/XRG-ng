// Swift translation of the SMC packet/cache/decoder code in SMCInterface.m.
// Original remainder implemented by CodeExchange (2012).
// Modified 2026-10-26 by Stephen de la Vega. This derivative retains APSL 2.0.
/*
 * Copyright (c) 2004 Apple Computer, Inc. All rights reserved.
 *
 * @APPLE_LICENSE_HEADER_START@
 *
 * This file contains Original Code and/or Modifications of Original Code
 * as defined in and that are subject to the Apple Public Source License
 * Version 2.0 (the 'License'). You may not use this file except in
 * compliance with the License. Please obtain a copy of the License at
 * http://www.opensource.apple.com/apsl/ and read it before using this
 * file.
 *
 * The Original Code and all software distributed under the License are
 * distributed on an 'AS IS' basis, WITHOUT WARRANTY OF ANY KIND, EITHER
 * EXPRESS OR IMPLIED, AND APPLE HEREBY DISCLAIMS ALL SUCH WARRANTIES,
 * INCLUDING WITHOUT LIMITATION, ANY WARRANTIES OF MERCHANTABILITY,
 * FITNESS FOR A PARTICULAR PURPOSE, QUIET ENJOYMENT OR NON-INFRINGEMENT.
 * Please see the License for the specific language governing rights and
 * limitations under the License.
 *
 * @APPLE_LICENSE_HEADER_END@
 */

/* Modified version from IOPMLibPrivate.c - reduced to the SMC communication part.
 Derived code follows in the bottom part

 */

import Foundation
import IOKit

/// Native implementations contain exceptions and populate NSError before Swift resumes.
@objc public protocol XRGSMCPacketTransport: NSObjectProtocol {
    @objc(transactPacket:error:)
    func transactPacket(_ packet: Data, error: AutoreleasingUnsafeMutablePointer<NSError?>?) -> Data?
}
@objc public protocol XRGSMCPacketTransportFactory: NSObjectProtocol {
    static func makeSMCPacketTransport() -> (any XRGSMCPacketTransport)?
}

struct XRGSMPacket {
    static let size = 80
    let key: UInt32
    let dataSize: UInt32
    let dataType: UInt32
    let result: UInt8
    let bytes: [UInt8]
    init?(_ data: Data) {
        guard data.count == Self.size else { return nil }
        let b = Array(data)
        func word(_ offset: Int) -> UInt32 { (0..<4).reduce(0) { $0 | (UInt32(b[offset + $1]) << ($1 * 8)) } }
        key = word(0); dataSize = word(28); dataType = word(32); result = b[40]; bytes = Array(b[48..<80])
    }
    static func request(command: UInt8, key: UInt32 = 0, size: UInt32 = 0, type: UInt32 = 0, index: UInt32 = 0) -> Data {
        var b = [UInt8](repeating: 0, count: Self.size)
        for (offset, word) in [(0, key), (28, size), (32, type), (44, index)] {
            for i in 0..<4 { b[offset + i] = UInt8(truncatingIfNeeded: word >> (i * 8)) }
        }
        b[42] = command
        return Data(b)
    }
}

@objc(XRGSMCInterface) @objcMembers
public final class XRGSMCInterface: NSObject {
    private struct KeyInfo { let size: UInt32; let type: UInt32 }
    private let transport: any XRGSMCPacketTransport
    private let lock = NSLock()
    private var cache: [UInt32: KeyInfo] = [:]
    @nonobjc init(transport: any XRGSMCPacketTransport) { self.transport = transport; super.init() }
    public static func openInterface() -> XRGSMCInterface? {
        let factory = NSClassFromString("XRGSMCPacketTransport") as? any XRGSMCPacketTransportFactory.Type
        guard let transport = factory?.makeSMCPacketTransport() else { return nil }
        return XRGSMCInterface(transport: transport)
    }
    @nonobjc private static func failure(_ code: IOReturn) -> NSError { NSError(domain: NSMachErrorDomain, code: Int(code)) }
    @nonobjc private func request(_ data: Data) throws -> XRGSMPacket {
        var error: NSError?
        guard let output = transport.transactPacket(data, error: &error) else { throw error ?? Self.failure(kIOReturnError) }
        if let error { throw error }
        guard let packet = XRGSMPacket(output) else { throw Self.failure(kIOReturnUnderrun) }
        if packet.result == 0x84 { throw Self.failure(kIOReturnNotFound) }
        guard packet.result == 0 else { throw Self.failure(kIOReturnInternalError) }
        return packet
    }
    @nonobjc private func info(for key: UInt32) throws -> KeyInfo {
        if let entry = lock.withLock({ cache[key] }) { return entry }
        let output = try request(XRGSMPacket.request(command: 9, key: key))
        guard (1...32).contains(output.dataSize), Self.validSize(output.dataSize, type: output.dataType) else { throw Self.failure(kIOReturnBadArgument) }
        let info = KeyInfo(size: output.dataSize, type: output.dataType)
        lock.withLock { cache[key] = info }
        return info
    }
    @nonobjc private static func validSize(_ size: UInt32, type: UInt32) -> Bool {
        switch type {
        case 0x73703738, 0x73693136: return size >= 2 // sp78 / si16
        case 0x666c7420: return size == 4 // flt
        case 0x66706532: return size <= 4 // bounded legacy fpe2 arithmetic
        default: return true
        }
    }
    @nonobjc static func decode(bytes: [UInt8], type: UInt32) -> Any? {
        guard (1...32).contains(bytes.count), validSize(UInt32(bytes.count), type: type) else { return nil }
        switch type {
        case 0x75693820, 0x75693136, 0x75693332: // ui8 / ui16 / ui32
            return NSNumber(value: bytes.reduce(UInt32(0)) { ($0 << 8) | UInt32($1) })
        case 0x73693820: return NSNumber(value: Int8(bitPattern: bytes[0]))
        case 0x73693136: return NSNumber(value: Int16(bitPattern: UInt16(bytes[0]) << 8 | UInt16(bytes[1])))
        case 0x666c6167: return bytes.count == 1 ? NSNumber(value: bytes[0] != 0) : Data(bytes)
        case 0x73703738:
            if (0x80...0x84).contains(bytes[0]) { return NSNumber(value: Int(bytes[0]) - 256) }
            if bytes[0] == 0x7f && bytes[1] == 0xe7 { return NSNumber(value: Float(127.9)) }
            return NSNumber(value: Float((UInt16(bytes[0]) << 8 | UInt16(bytes[1])) >> 2) / 64)
        case 0x66706532:
            var value: Float = 0
            for (index, byte) in bytes.enumerated() {
                value += index == bytes.count - 1 ? Float(byte >> 2) : Float(UInt32(byte) << ((bytes.count - 1 - index) * 6))
            }
            return NSNumber(value: value)
        case 0x666c7420:
            let bits = bytes.enumerated().reduce(UInt32(0)) { $0 | UInt32($1.element) << ($1.offset * 8) }
            return NSNumber(value: Float(bitPattern: bits))
        default: return Data(bytes)
        }
    }
    @objc(readValue:error:)
    public func readValue(_ key: UInt32, error errorOut: AutoreleasingUnsafeMutablePointer<NSError?>?) -> Any? {
        errorOut?.pointee = nil
        do {
            guard key != 0 else { throw Self.failure(kIOReturnCannotWire) }
            let info = try info(for: key)
            let output = try request(XRGSMPacket.request(command: 5, key: key, size: info.size, type: info.type))
            guard let value = Self.decode(bytes: Array(output.bytes.prefix(Int(info.size))), type: info.type) else { throw Self.failure(kIOReturnBadArgument) }
            return value
        } catch { errorOut?.pointee = error as NSError; return nil }
    }
    public var keyCount: Int {
        guard let number = readValue(0x234b4559, error: nil) as? NSNumber else { return 0 }
        return Int(clamping: number.int64Value)
    }
    @objc(keyAtIndex:)
    public func key(at index: Int) -> UInt32 {
        guard let value = UInt32(exactly: index), let output = try? request(XRGSMPacket.request(command: 8, index: value)) else { return 0 }
        return output.key
    }
}
