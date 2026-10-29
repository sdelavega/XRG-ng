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

struct XRGGPUSample {
    let id: UInt64
    let vendor: String
    let total: Double?
    let free: Double?
    let wait: Double?
    let utilization: Double?
    var memoryReading: XRGHardwareReading? = nil

    static func parse(id: UInt64, pci: [String: Any], accelerator: [String: Any]) -> Self {
        func number(_ value: Any?) -> Double? {
            guard let value = value as? NSNumber,
                  CFGetTypeID(value) != CFBooleanGetTypeID() else { return nil }
            let result = value.doubleValue
            return result.isFinite && result >= 0 ? result : nil
        }
        func vendorID(_ value: Any?) -> UInt32? {
            guard let data = value as? Data, data.count >= 4 else { return nil }
            return data.withUnsafeBytes { UInt32(littleEndian: $0.loadUnaligned(as: UInt32.self)) }
        }
        let vendor = vendorID(pci["vendor-id"]) ?? vendorID(accelerator["vendor-id"])
        let names: [UInt32: String] = [0x8086: "Intel", 0x1002: "AMD", 0x10de: "nVidia", 0x106b: "Apple"]
        let perf = accelerator["PerformanceStatistics"] as? [String: Any] ?? [:]
        var total = (number(accelerator["VRAM,totalMB"]) ?? number(pci["VRAM,totalMB"])).map { $0 * 1048576 }
            ?? number(pci["ATY,memsize"]) ?? number(perf["Alloc system memory"])
        var free = number(perf["vramFreeBytes"])
        var used = number(perf["vramUsedBytes"])
        let invalidUsed = used.flatMap { u in total.map { u > $0 } } ?? false
        if used == nil || invalidUsed {
            used = number(perf["inUseVidMemoryBytes"]) ?? number(perf["In use system memory"])
        }

        func resolve(_ total: Double?, _ free: Double?, _ used: Double?) -> (Double, Double)? {
            let t = total ?? free.flatMap { f in used.map { f + $0 } }
            guard let t, t.isFinite, t > 0 else { return nil }
            let f = free ?? used.map { t - $0 }
            guard let f, f.isFinite, f >= 0, f <= t else { return nil }
            if let used, used > t { return nil }
            return (t, f)
        }
        var memory = resolve(total, free, used)
        if memory == nil {
            total = number(perf["gartSizeBytes"])
            free = number(perf["gartFreeBytes"])
            used = number(perf["gartUsedBytes"])
            memory = resolve(total, free, used)
        }
        let vendorName = vendor.flatMap { names[$0] } ?? ""
        return Self(id: id, vendor: vendorName,
                    total: memory?.0, free: memory?.1,
                    wait: number(perf["hardwareWaitTime"]),
                    utilization: number(perf["Device Utilization %"]).map { min(100, $0) },
                    memoryReading: XRGHardwareReading.gpuMemory(id: id, vendor: vendorName, pci: pci, accelerator: accelerator))
    }
}

@MainActor
@objc(XRGGPUMiner)
public final class XRGGPUMiner: NSObject {
    private final class History {
        let total = XRGDataSet()
        let free = XRGDataSet()
        let wait = XRGDataSet()
        let utilization = XRGDataSet()
        var all: [XRGDataSet] { [total, free, wait, utilization] }
    }
    private let source: () -> [XRGGPUSample]?
    private var histories: [UInt64: History] = [:]
    private var lastGraphTick: UInt64?
    private(set) var memorySnapshot: Result<[XRGHardwareReading], Error> = .success([])
    @objc public private(set) var numSamples = 1
    @objc public var numberOfGPUs: Int { vendorNames.count }
    @objc public private(set) var totalVRAMDataSets: [XRGDataSet] = []
    @objc public private(set) var freeVRAMDataSets: [XRGDataSet] = []
    @objc public private(set) var cpuWaitDataSets: [XRGDataSet] = []
    @objc public private(set) var utilizationDataSets: [XRGDataSet] = []
    @objc public private(set) var vendorNames: [String] = []
    @objc public private(set) var memoryAvailable: [NSNumber] = []
    @objc public private(set) var utilizationAvailable: [NSNumber] = []

    public override convenience init() { self.init(source: Self.readSnapshot) }
    init(source: @escaping () -> [XRGGPUSample]?) {
        self.source = source
        super.init()
        getLatestGraphicsInfo()
    }

    @objc public func setDataSize(_ count: Int) {
        guard count >= 0 else { return }
        numSamples = count
        for history in histories.values {
            for values in history.all { values.resize(count) }
        }
    }

    @objc public func getLatestGraphicsInfo() {
        guard let samples = source() else {
            memorySnapshot = .failure(NSError(domain: "XRGGPU", code: 1, userInfo: [NSLocalizedDescriptionKey: "GPU memory readings unavailable"]))
            return
        }
        memorySnapshot = .success(samples.sorted { $0.id < $1.id }.compactMap(\.memoryReading))
        var next: [UInt64: History] = [:]
        var ordered: [History] = []
        var vendors: [String] = []
        var memory: [NSNumber] = []
        var utilization: [NSNumber] = []
        for sample in samples.sorted(by: { $0.id < $1.id }) {
            guard next[sample.id] == nil else { continue }
            let history = histories[sample.id] ?? History()
            for values in history.all where values.numValues != numSamples { values.resize(numSamples) }
            history.total.setNextValue(sample.total ?? 0)
            history.free.setNextValue(sample.free ?? 0)
            history.wait.setNextValue(sample.wait ?? -1)
            history.utilization.setNextValue(sample.utilization ?? 0)
            next[sample.id] = history
            ordered.append(history)
            vendors.append(sample.vendor)
            memory.append(NSNumber(value: sample.total != nil && sample.free != nil))
            utilization.append(NSNumber(value: sample.utilization != nil))
        }
        histories = next
        totalVRAMDataSets = ordered.map(\.total)
        freeVRAMDataSets = ordered.map(\.free)
        cpuWaitDataSets = ordered.map(\.wait)
        utilizationDataSets = ordered.map(\.utilization)
        vendorNames = vendors
        memoryAvailable = memory
        utilizationAvailable = utilization
    }

    func refreshForGraphTick(_ tick: UInt64?) {
        if let tick, lastGraphTick == tick { return }
        lastGraphTick = tick; getLatestGraphicsInfo()
    }

    nonisolated static func readSnapshot() -> [XRGGPUSample]? {
        var iterator: io_iterator_t = 0
        guard IOServiceGetMatchingServices(kIOMainPortDefault, IOServiceMatching("IOAccelerator"),
                                          &iterator) == KERN_SUCCESS else { return nil }
        defer { IOObjectRelease(iterator) }
        var result: [XRGGPUSample] = []
        while true {
            let service = IOIteratorNext(iterator)
            guard service != 0 else { break }
            defer { IOObjectRelease(service) }
            var id: UInt64 = 0
            guard IORegistryEntryGetRegistryEntryID(service, &id) == KERN_SUCCESS,
                  let accelerator = properties(service) else { return nil }
            // Match the actual PCI ancestor, never an unrelated device by enumeration order.
            var pci: [String: Any] = [:]
            var current = service
            IOObjectRetain(current)
            defer { IOObjectRelease(current) }
            for _ in 0..<64 {
                if IOObjectConformsTo(current, "IOPCIDevice") != 0 {
                    guard let values = properties(current) else { return nil }
                    pci = values
                    break
                }
                var parent: io_registry_entry_t = 0
                guard IORegistryEntryGetParentEntry(current, kIOServicePlane, &parent) == KERN_SUCCESS else { break }
                IOObjectRelease(current)
                current = parent
            }
            result.append(XRGGPUSample.parse(id: id, pci: pci, accelerator: accelerator))
        }
        return result
    }

    nonisolated private static func properties(_ service: io_registry_entry_t) -> [String: Any]? {
        var properties: Unmanaged<CFMutableDictionary>?
        guard IORegistryEntryCreateCFProperties(service, &properties, nil, 0) == KERN_SUCCESS else { return nil }
        return properties?.takeRetainedValue() as? [String: Any]
    }
}
