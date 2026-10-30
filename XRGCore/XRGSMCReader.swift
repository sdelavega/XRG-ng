// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Stephen de la Vega.
import Foundation
import IOKit

@objc public protocol XRGSMCPacketTransport: NSObjectProtocol {
    @objc(transactPacket:error:)
    func transactPacket(_ packet: Data, error: AutoreleasingUnsafeMutablePointer<NSError?>?) -> Data?
}
@objc public protocol XRGSMCPacketTransportFactory: NSObjectProtocol {
    static func makeSMCPacketTransport() -> (any XRGSMCPacketTransport)?
}
@objc public protocol XRGSMCTransport: NSObjectProtocol {
    var keyCount: Int { get }
    @objc(keyAtIndex:) func key(at index: Int) -> NSNumber?
    @objc(readValueForKey:) func readValue(for key: UInt32) -> Any?
    @objc(temperatureValueForKey:) func temperatureValue(for key: UInt32) -> NSNumber?
}

/// Wire fields are driver ABI facts. No native struct layout or borrowed decoder.
enum XRGSMCWire {
    enum Operation: UInt8 { case value = 5, index = 8, metadata = 9 }
    static func message(_ operation: Operation, key: UInt32 = 0, index: UInt32 = 0, width: UInt32 = 0) -> Data {
        var output = Data(repeating: 0, count: 80)
        for (offset, number) in [(0, key), (28, width), (44, index)] {
            var little = number.littleEndian
            withUnsafeBytes(of: &little) { output.replaceSubrange(offset..<offset+4, with: $0) }
        }
        output[42] = operation.rawValue
        return output
    }
    static func word(_ bytes: Data, at offset: Int) -> UInt32 {
        bytes.withUnsafeBytes { UInt32(littleEndian: $0.loadUnaligned(fromByteOffset: offset, as: UInt32.self)) }
    }
}

/// A new, bounded, read-only reader. One channel owns its native connection;
/// metadata and value transactions are serialized together, never retried as writes.
@objc(XRGSMCReader) public final class XRGSMCReader: NSObject, XRGSMCTransport {
    private let channel: any XRGSMCPacketTransport
    private let mutex = NSLock()
    private var formats: [UInt32: (width: UInt32, type: UInt32)] = [:]
    init(channel: any XRGSMCPacketTransport) { self.channel = channel; super.init() }
    @objc public static func openReader() -> XRGSMCReader? {
        let factory = NSClassFromString("XRGSMCPacketTransport") as? any XRGSMCPacketTransportFactory.Type
        guard let channel = factory?.makeSMCPacketTransport() else { return nil }
        return XRGSMCReader(channel: channel)
    }
    private func exchange(_ message: Data) throws -> Data {
        var failure: NSError?
        let result = channel.transactPacket(message, error: &failure)
        if let failure { formats.removeAll(); throw failure }
        guard let result else { formats.removeAll(); throw Self.error(kIOReturnError) }
        guard result.count == 80 else { throw Self.error(kIOReturnUnderrun) }
        switch result[40] {
        case 0: return result
        case 0x84: throw Self.error(kIOReturnNotFound)
        default: throw Self.error(kIOReturnInternalError)
        }
    }
    static func error(_ code: IOReturn) -> NSError { NSError(domain: NSMachErrorDomain, code: Int(code)) }
    func value(_ key: UInt32) throws -> Any { try sample(key).value }
    private func sample(_ key: UInt32) throws -> (value: Any, type: UInt32) {
        try mutex.withLock {
            guard key != 0 else { throw Self.error(kIOReturnBadArgument) }
            let format: (width: UInt32, type: UInt32)
            if let cached = formats[key] { format = cached }
            else {
                let reply = try exchange(XRGSMCWire.message(.metadata, key: key))
                format = (XRGSMCWire.word(reply, at: 28), XRGSMCWire.word(reply, at: 32))
                guard (1...32).contains(format.width), Self.validWidth(Int(format.width), type: format.type) else { throw Self.error(kIOReturnBadArgument) }
                formats[key] = format
            }
            let reply = try exchange(XRGSMCWire.message(.value, key: key, width: format.width))
            guard let value = Self.decode(Data(reply[48..<48+Int(format.width)]), type: format.type) else { throw Self.error(kIOReturnBadArgument) }
            return (value, format.type)
        }
    }
    @objc(temperatureValueForKey:) public func temperatureValue(for key: UInt32) -> NSNumber? {
        guard let sample = try? sample(key), sample.type == 0x73703738 || sample.type == 0x666c7420,
              let number = sample.value as? NSNumber, number.doubleValue.isFinite,
              (-128...200).contains(number.doubleValue) else { return nil }
        return number
    }
    @objc(readValueForKey:) public func readValue(for key: UInt32) -> Any? { try? value(key) }
    @objc public var keyCount: Int {
        guard let value = readValue(for: 0x234b4559) as? NSNumber, CFGetTypeID(value) != CFBooleanGetTypeID(),
              let count = UInt32(value.stringValue), count <= 65_536 else { return 0 }
        return Int(count)
    }
    @objc(keyAtIndex:) public func key(at index: Int) -> NSNumber? {
        guard let index = UInt32(exactly: index), index < 65_536 else { return nil }
        return mutex.withLock {
            guard let reply = try? exchange(XRGSMCWire.message(.index, index: index)) else { return nil }
            let key = XRGSMCWire.word(reply, at: 0)
            return key == 0 ? nil : NSNumber(value: key)
        }
    }
    private static func format(_ type: UInt32) -> String {
        String(bytes: [24,16,8,0].map { UInt8(truncatingIfNeeded: type >> $0) }, encoding: .ascii) ?? ""
    }
    private static func fraction(_ type: String) -> (signed: Bool, bits: Int)? {
        let chars = Array(type)
        guard chars.count == 4, type.hasPrefix("sp") || type.hasPrefix("fp"),
              let integer = Int(String(chars[2]), radix:16), let fraction = Int(String(chars[3]), radix:16),
              integer + fraction == (chars[0] == "s" ? 15 : 16) else { return nil }
        return (chars[0] == "s", fraction)
    }
    static func validWidth(_ width: Int, type: UInt32) -> Bool {
        let name = format(type)
        if let bits = ["ui8 ":1,"si8 ":1,"ui16":2,"si16":2,"ui32":4,"si32":4,"flt ":4,"flag":1][name] { return width == bits }
        if fraction(name) != nil { return width == 2 }
        return (1...32).contains(width)
    }
    static func decode(_ bytes: Data, type: UInt32) -> Any? {
        guard validWidth(bytes.count, type: type) else { return nil }
        let name = format(type)
        let unsigned = bytes.prefix(4).reduce(UInt32(0)) { ($0 << 8) | UInt32($1) }
        if name.hasPrefix("ui"), ["ui8 ","ui16","ui32"].contains(name) { return NSNumber(value: unsigned) }
        switch name {
        case "si8 ": return NSNumber(value: Int8(bitPattern: UInt8(unsigned)))
        case "si16": return NSNumber(value: Int16(bitPattern: UInt16(unsigned)))
        case "si32": return NSNumber(value: Int32(bitPattern: unsigned))
        case "flag": return NSNumber(value: unsigned != 0)
        case "flt ":
            let value = bytes.withUnsafeBytes { Float(bitPattern: UInt32(littleEndian: $0.loadUnaligned(as: UInt32.self))) }
            return value.isFinite ? NSNumber(value: value) : nil
        default:
            if let fixed = fraction(name) {
                let value = fixed.signed ? Double(Int16(bitPattern: UInt16(unsigned))) : Double(unsigned)
                return NSNumber(value: value / Double(1 << fixed.bits))
            }
            return bytes
        }
    }
}
