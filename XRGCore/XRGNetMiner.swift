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
    private let historyClock: () -> TimeInterval
    let timedHistory = XRGTimedHistory(channels: 3, retentionMinutes: XRGTimedHistory.systemMaximumMinutes)!
    private var tracker = XRGIOCounterTracker<String>()
    private var rxRate: CGFloat = 0
    private var txRate: CGFloat = 0
    @objc public private(set) var interfaceStats: [XRGNetworkInterface] = []
    @objc public var numInterfaces: Int { interfaceStats.count }
    @objc public private(set) var totalBytesSinceBoot: UInt64 = 0
    public private(set) var kernelTotalIsLowerBound = false
    @objc public var totalBytesSinceLoad: UInt64 { tracker.total }
    public var receivedBytesSinceLoad: UInt64 { tracker.first }
    public var sentBytesSinceLoad: UInt64 { tracker.second }
    public var transfersAreLowerBound: Bool { tracker.lowerBound }
    public var countersAvailable: Bool { tracker.available }
    public var transferDetails: String {
        let interfaces = interfaceStats.filter { selected($0.name) }
        var received: UInt64 = 0, sent: UInt64 = 0
        for interface in interfaces {
            received = XRGIOCounterTracker<String>.sum(received, interface.receivedBytes).value
            sent = XRGIOCounterTracker<String>.sum(sent, interface.sentBytes).value
        }
        // Keep the sheet bounded even on hosts with many virtual interfaces.
        // Individual raw counters remain available in the graph menu.
        return "Scope: \(monitorNetworkInterface) (\(interfaces.count) interfaces in last snapshot).\n"
        + "Kernel counters (normally since boot): Rx \(received) bytes / Tx \(sent) bytes\(kernelTotalIsLowerBound ? " (combined total saturated; lower bound)" : "").\n"
        + tracker.details(firstLabel: "Rx", secondLabel: "Tx")
        + "Interface identity uses name and kernel index; reuse of both between observations cannot be detected. Bridged/VPN/stacked interfaces may count traffic more than once."
    }
    @objc public let rxValues = XRGDataSet()
    @objc public let txValues = XRGDataSet()
    @objc public let totalValues = XRGDataSet()
    @objc public var monitorNetworkInterface = "All" {
        didSet {
            guard oldValue != monitorNetworkInterface else { return }
            rebase()
            reset()
            updateBootTotal()
        }
    }

    public override convenience init() {
        self.init(source: Self.readSnapshot, clock: { ProcessInfo.processInfo.systemUptime })
    }

    init(source: @escaping () -> [XRGNetworkSample]?, clock: @escaping () -> TimeInterval, historyClock: @escaping () -> TimeInterval = { Date().timeIntervalSince1970 }) {
        self.source = source
        self.clock = clock; self.historyClock = historyClock
        super.init()
        getLatestNetInfo()
    }

    @objc public func setDataSize(_ count: Int) {
        guard count >= 0 else { return }
        for history in [rxValues, txValues, totalValues] { history.resize(count) }
    }
    @nonobjc func resizeHistory(_ count: Int) {
        guard (1...XRGSamplingSettings.maximumHistorySamples).contains(count) else { return }
        for data in [rxValues, txValues, totalValues] { data.resize(count, fillingWith: XRGGraphRenderer.missingValue) }
    }
    @objc public func reset() {
        for history in [rxValues, txValues, totalValues] { history.reset() }
        timedHistory.clear()
    }
    public func resetTransfers() { tracker.resetTransfers() }
    public func rebase() { tracker = XRGIOCounterTracker(); rxRate = 0; txRate = 0 }
    @objc public func maxBandwidth() -> CGFloat { totalValues.max }
    @objc public func currentTX() -> CGFloat { txRate }
    @objc public func currentRX() -> CGFloat { rxRate }
    @objc public func networkInterfaces() -> [String] { interfaceStats.map(\.name) }

    private func selected(_ name: String) -> Bool {
        monitorNetworkInterface == "All" || monitorNetworkInterface == name
    }
    private func updateBootTotal() {
        totalBytesSinceBoot = 0; kernelTotalIsLowerBound = false
        for interface in interfaceStats where selected(interface.name) {
            let pair = XRGIOCounterTracker<String>.sum(interface.receivedBytes, interface.sentBytes)
            let total = XRGIOCounterTracker<String>.sum(totalBytesSinceBoot, pair.value)
            totalBytesSinceBoot = total.value
            kernelTotalIsLowerBound = kernelTotalIsLowerBound || pair.overflow || total.overflow
        }
    }

    @discardableResult @objc public func getLatestNetInfo() -> Bool { collect(recordHistory: true) }
    @discardableResult func getLatestFastInfo() -> Bool { collect(recordHistory: false) }
    private func collect(recordHistory: Bool) -> Bool {
        guard let samples = source() else { return failedRead(recordHistory: recordHistory) }
        var next: [String: XRGNetworkSample] = [:]
        for sample in samples where sample.name != "lo0" {
            // Ambiguous identities invalidate the snapshot instead of picking an
            // arbitrary duplicate and counting a fabricated delta.
            guard next[sample.name] == nil else { return failedRead(recordHistory: recordHistory) }
            next[sample.name] = sample
        }
        let now = clock()
        guard now.isFinite else { return failedRead(recordHistory: recordHistory) }
        // Discovery is independent of the pinned selection. A missing selected
        // interface must not hide newly attached interfaces from preferences.
        interfaceStats = next.values.sorted { $0.name < $1.name }.map(XRGNetworkInterface.init)
        updateBootTotal()
        let chosen = next.values.filter { selected($0.name) }
        guard monitorNetworkInterface == "All" || !chosen.isEmpty else { return failedRead(recordHistory: recordHistory) }
        let counters = Dictionary(uniqueKeysWithValues: chosen.map {
            ("\($0.name):\($0.index)", XRGIOCounters(first: $0.received, second: $0.sent))
        })
        guard let reading = tracker.sample(counters, at: now) else { return failedRead(recordHistory: recordHistory) }
        if reading.newSession { reset() }
        rxRate = reading.firstRate; txRate = reading.secondRate
        rxValues.setNextValue(rxRate); txValues.setNextValue(txRate)
        totalValues.setNextValue(rxRate + txRate)
        if recordHistory { timedHistory.append(time: historyClock(), values: [Double(rxRate), Double(txRate), Double(rxRate + txRate)]) }
        return true
    }

    private func failedRead(recordHistory: Bool) -> Bool {
        tracker.fail()
        for history in [rxValues, txValues, totalValues] { history.setNextValue(XRGGraphRenderer.missingValue) }
        if recordHistory { timedHistory.append(time: historyClock(), values: [.nan, .nan, .nan]) }
        return false
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
