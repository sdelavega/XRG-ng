// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Stephen de la Vega.
import Foundation

/// Read-only reported values. Capacity is optional and never inferred from RAM,
/// allocation limits, GART apertures or an assumed device model.
struct XRGHardwareReading: Sendable {
    let id: String
    let name: String
    let value: Double
    var capacity: Double? = nil
    var note = ""
    var valid: Bool {
        value.isFinite && value >= 0 && (capacity.map { $0.isFinite && $0 > 0 && value <= $0 } ?? true)
    }
    static func gpuMemory(id: UInt64, vendor: String, pci: [String: Any], accelerator: [String: Any], sourceID: String? = nil) -> Self? {
        let sourceID = sourceID.flatMap { !$0.isEmpty && $0.utf8.count <= 1024 && !$0.unicodeScalars.contains(where: CharacterSet.controlCharacters.contains) ? $0 : nil } ?? String(id)
        let perf = accelerator["PerformanceStatistics"] as? [String: Any] ?? [:]
        func number(_ raw: Any?) -> Double? {
            guard let n = raw as? NSNumber, CFGetTypeID(n) != CFBooleanGetTypeID() else { return nil }
            let v = n.doubleValue; return v.isFinite && v >= 0 ? v : nil
        }
        let total = (number(accelerator["VRAM,totalMB"]) ?? number(pci["VRAM,totalMB"])).map { $0 * 1_048_576 }
            ?? number(pci["ATY,memsize"])
        let used = number(perf["vramUsedBytes"]) ?? number(perf["inUseVidMemoryBytes"])
        let free = number(perf["vramFreeBytes"])
        let name = vendor.isEmpty ? "GPU \(id)" : "\(vendor) GPU \(id)"
        if let total, total.isFinite, total > 0 {
            let value = used ?? free.map { total - $0 }
            if let value, value.isFinite, value >= 0, value <= total,
               free.map({ $0 <= total && (used == nil || abs(total - value - $0) <= max(1, total * 0.001)) }) ?? true {
                return Self(id: sourceID, name: name, value: value, capacity: total,
                            note: "Driver-reported GPU memory pool; this does not establish physical memory topology.")
            }
        }
        // Allocation-only counters remain bytes, with no percentage/capacity.
        if let value = number(perf["In use system memory"]) {
            return Self(id: sourceID, name: name, value: value,
                        note: "GPU system-memory allocations; shared/unified RAM, not installed VRAM. Capacity unavailable.")
        }
        if let value = used, total == nil {
            return Self(id: sourceID, name: name, value: value,
                        note: "Driver-reported GPU allocations; capacity unavailable.")
        }
        return nil
    }
}

@MainActor protocol XRGGraphicsSampleClock: AnyObject {
    var graphicsSampleGeneration: UInt64 { get }
}

@MainActor protocol XRGGraphicsSnapshotHost: AnyObject {
    func graphicsSnapshotDidComplete()
}
