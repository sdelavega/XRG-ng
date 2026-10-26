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
import Darwin

struct XRGNetworkSample: Sendable {
    let name: String
    let index: UInt16
    let received: UInt64
    let sent: UInt64
}

@objcMembers
public final class XRGNetworkInterface: NSObject {
    public let name: String
    public let receivedBytes: UInt64
    public let sentBytes: UInt64

    init(_ sample: XRGNetworkSample) {
        name = sample.name
        receivedBytes = sample.received
        sentBytes = sample.sent
        super.init()
    }
}

@MainActor
@objc(XRGNetMiner)
public final class XRGNetMiner: NSObject {
    private let source: () -> [XRGNetworkSample]?
    private let clock: () -> TimeInterval
    private var previous: [String: XRGNetworkSample] = [:]
    private var lastTime: TimeInterval?
    @objc public private(set) var interfaceStats: [XRGNetworkInterface] = []
    @objc public var numInterfaces: Int { interfaceStats.count }
    @objc public private(set) var totalBytesSinceBoot: UInt64 = 0
    @objc public private(set) var totalBytesSinceLoad: UInt64 = 0
    @objc public let rxValues = XRGDataSet()
    @objc public let txValues = XRGDataSet()
    @objc public let totalValues = XRGDataSet()
    @objc public var monitorNetworkInterface = "All" {
        didSet {
            guard oldValue != monitorNetworkInterface else { return }
            totalBytesSinceLoad = 0
            reset()
            updateBootTotal()
        }
    }

    public override convenience init() {
        self.init(source: Self.readSnapshot, clock: { ProcessInfo.processInfo.systemUptime })
    }

    init(source: @escaping () -> [XRGNetworkSample]?, clock: @escaping () -> TimeInterval) {
        self.source = source
        self.clock = clock
        super.init()
        getLatestNetInfo()
    }

    @objc public func setDataSize(_ count: Int) {
        guard count >= 0 else { return }
        for history in [rxValues, txValues, totalValues] { history.resize(count) }
    }
    @objc public func reset() {
        for history in [rxValues, txValues, totalValues] { history.reset() }
        lastTime = nil
    }
    @objc public func maxBandwidth() -> CGFloat { totalValues.max }
    @objc public func currentTX() -> CGFloat { txValues.currentValue }
    @objc public func currentRX() -> CGFloat { rxValues.currentValue }
    @objc public func networkInterfaces() -> [String] { interfaceStats.map(\.name) }

    private func selected(_ name: String) -> Bool {
        monitorNetworkInterface == "All" || monitorNetworkInterface == name
    }
    private func add(_ a: UInt64, _ b: UInt64) -> UInt64 {
        let (result, overflow) = a.addingReportingOverflow(b)
        return overflow ? .max : result
    }
    private func updateBootTotal() {
        totalBytesSinceBoot = interfaceStats.filter { selected($0.name) }.reduce(0) {
            add($0, add($1.receivedBytes, $1.sentBytes))
        }
    }

    @objc public func getLatestNetInfo() {
        guard let samples = source() else { return }
        let now = clock()
        guard now.isFinite else { return }
        let elapsed = lastTime.map { now - $0 } ?? 0
        var received: UInt64 = 0
        var sent: UInt64 = 0
        var next: [String: XRGNetworkSample] = [:]
        for sample in samples where sample.name != "lo0" {
            guard next[sample.name] == nil else { continue }
            next[sample.name] = sample
            guard elapsed > 0, selected(sample.name),
                  let old = previous[sample.name], old.index == sample.index else { continue }
            // A decreased counter is a new baseline, not a 32-bit rollover.
            received = add(received, sample.received >= old.received ? sample.received - old.received : 0)
            sent = add(sent, sample.sent >= old.sent ? sample.sent - old.sent : 0)
        }
        previous = next
        lastTime = now
        interfaceStats = next.values.sorted { $0.name < $1.name }.map(XRGNetworkInterface.init)
        updateBootTotal()
        totalBytesSinceLoad = add(totalBytesSinceLoad, add(received, sent))
        let rx = elapsed > 0 ? Double(received) / elapsed : 0
        let tx = elapsed > 0 ? Double(sent) / elapsed : 0
        // Protect graph storage from pathological clock intervals.
        rxValues.setNextValue(rx.isFinite ? rx : 0)
        txValues.setNextValue(tx.isFinite ? tx : 0)
        totalValues.setNextValue((rx + tx).isFinite ? rx + tx : 0)
    }

    nonisolated static func readSnapshot() -> [XRGNetworkSample]? {
        var mib: [Int32] = [CTL_NET, PF_ROUTE, 0, 0, NET_RT_IFLIST2, 0]
        // Interface churn can enlarge the buffer between the two sysctl calls.
        for _ in 0..<3 {
            var size = 0
            guard sysctl(&mib, u_int(mib.count), nil, &size, nil, 0) == 0,
                  size <= 64 * 1024 * 1024 else { return nil }
            if size == 0 { return [] }
            var data = Data(count: size)
            let status = data.withUnsafeMutableBytes {
                sysctl(&mib, u_int(mib.count), $0.baseAddress, &size, nil, 0)
            }
            if status != 0 {
                if errno == ENOMEM { continue }
                return nil
            }
            guard size <= data.count else { continue }
            data.count = size
            return parse(data)
        }
        return nil
    }

    nonisolated static func parse(_ data: Data) -> [XRGNetworkSample]? {
        data.withUnsafeBytes { bytes in
            var offset = 0
            var result: [XRGNetworkSample] = []
            while offset < bytes.count {
                guard bytes.count - offset >= 4 else { return nil }
                let length = Int(bytes.loadUnaligned(fromByteOffset: offset, as: UInt16.self))
                guard length >= 4, length <= bytes.count - offset else { return nil }
                let version = bytes[offset + 2]
                let type = bytes[offset + 3]
                guard version == RTM_VERSION else { return nil }
                if type == RTM_IFINFO2 {
                    guard length >= MemoryLayout<if_msghdr2>.size else { return nil }
                    let header = bytes.loadUnaligned(fromByteOffset: offset, as: if_msghdr2.self)
                    if header.ifm_flags & IFF_UP != 0 && header.ifm_flags & IFF_LOOPBACK == 0 {
                        var name = [CChar](repeating: 0, count: Int(IF_NAMESIZE))
                        guard if_indextoname(UInt32(header.ifm_index), &name) != nil else {
                            // Retry the whole snapshot after an interface disappears mid-read.
                            return nil
                        }
                        let interfaceName = String(decoding: name.prefix { $0 != 0 }.map { UInt8(bitPattern: $0) }, as: UTF8.self)
                        result.append(XRGNetworkSample(name: interfaceName,
                            index: header.ifm_index, received: header.ifm_data.ifi_ibytes,
                            sent: header.ifm_data.ifi_obytes))
                    }
                }
                offset += length
            }
            return result
        }
    }
}
