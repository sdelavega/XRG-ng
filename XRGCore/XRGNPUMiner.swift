// Copyright (C) 2026 Stephen de la Vega.
// SPDX-License-Identifier: GPL-3.0-or-later
import Foundation

/// Only the serial queue touches the IOReport reader; the lock protects request
/// coalescing, and immutable readings cross to AppKit's main actor.
private final class XRGNPUWorker: @unchecked Sendable {
    private let queue = DispatchQueue(label: "com.sdelavega.XRG-ng.neural-engine", qos: .utility)
    private let lock = NSLock()
    private var pending = false
    private var lastPoll: TimeInterval = -.infinity
    private lazy var reader = XRGNPUReader()
    func request(_ completion: @escaping @MainActor @Sendable (XRGNPUReading) -> Void) {
        lock.lock()
        let now = ProcessInfo.processInfo.systemUptime
        guard !pending, now - lastPoll >= 1 else { lock.unlock(); return }
        pending = true; lastPoll = now; lock.unlock()
        queue.async { [self] in
            let reading = reader.sample()
            lock.lock(); pending = false; lock.unlock()
            DispatchQueue.main.async { completion(reading) }
        }
    }
}

@MainActor @objc(XRGNPUMiner)
public final class XRGNPUMiner: NSObject {
    private let worker: XRGNPUWorker?
    private let source: (() -> XRGNPUReading?)?
    private let clock: () -> TimeInterval
    private var previous: XRGNPUReading?
    private var lastReading: TimeInterval?
    private var current: XRGNPUReading?
    private var issue = "Waiting for Neural Engine sample"
    @nonobjc var onUpdate: (() -> Void)?
    @nonobjc var staleAfter: TimeInterval = 5
    @nonobjc private(set) var devices: [XRGNPUDevice] = []
    @nonobjc public private(set) var powerWatts: Double?
    @objc public private(set) var powerDataSet = XRGDataSet()
    @objc public private(set) var numSamples = 1

    public override init() {
        worker = XRGNPUWorker(); source = nil; clock = { ProcessInfo.processInfo.systemUptime }
        super.init(); getLatestNPUInfo()
    }
    init(source: @escaping () -> XRGNPUReading?, clock: @escaping () -> TimeInterval) {
        worker = nil; self.source = source; self.clock = clock
        super.init(); getLatestNPUInfo()
    }
    @objc public func setDataSize(_ count: Int) {
        guard (0...20_000).contains(count), numSamples != count else { return }
        numSamples = count; powerDataSet.resize(count, fillingWith: XRGGraphRenderer.missingValue)
    }
    private func resetHistory() {
        powerDataSet = XRGDataSet(); powerDataSet.resize(numSamples)
        powerDataSet.setAllValues(XRGGraphRenderer.missingValue)
    }
    @objc public func getLatestNPUInfo() {
        if let worker {
            worker.request { [weak self] reading in self?.accept(reading); self?.onUpdate?() }
        } else if let reading = source?() { accept(reading) }
        if let lastReading, clock() - lastReading > max(5, staleAfter.isFinite ? staleAfter : 5) {
            powerWatts = nil; previous = nil; issue = "ANE power sample is stale"; resetHistory()
        }
    }
    private func accept(_ reading: XRGNPUReading) {
        guard reading.time.isFinite, reading.time >= 0, clock().isFinite,
              reading.time <= clock() + 1, clock() - reading.time <= 5 else {
            powerWatts = nil; previous = nil; issue = "Invalid/stale ANE sample time"; resetHistory(); return
        }
        if let lastReading, reading.time <= lastReading { return }
        devices = reading.devices; current = reading; lastReading = reading.time
        let old = previous
        previous = nil; powerWatts = nil
        guard let energy = reading.energy, !energy.isEmpty, energy.count <= 16,
              Set(energy.map(\.id)).count == energy.count,
              energy.allSatisfy({ $0.value >= 0 && $0.joulesPerUnit != nil }) else {
            issue = reading.error ?? "ANE power telemetry unavailable"; resetHistory(); return
        }
        previous = reading
        guard let old, let before = old.energy,
              old.devices.map(\.id).sorted() == reading.devices.map(\.id).sorted(),
              Set(before.map(\.id)) == Set(energy.map(\.id)),
              reading.time > old.time, reading.time - old.time <= 300 else {
            issue = "Waiting for ANE energy interval"; resetHistory(); return
        }
        let counters = Dictionary(uniqueKeysWithValues: before.map { ($0.id, $0) })
        var joules = 0.0
        for value in energy {
            guard let previous = counters[value.id], previous.unit == value.unit,
                  value.value >= previous.value, let factor = value.joulesPerUnit else {
                issue = "ANE counter reset; waiting for interval"; resetHistory(); return
            }
            joules += Double(value.value - previous.value) * factor
        }
        let watts = joules / (reading.time - old.time)
        guard watts.isFinite, watts >= 0 else { issue = "Invalid ANE energy delta"; resetHistory(); return }
        powerWatts = watts; powerDataSet.setNextValue(watts)
        issue = reading.error ?? "Measured ANE power"
    }
    @objc public func fullReading() -> String {
        var lines = ["Apple Neural Engine (NPU)"]
        if current == nil { lines.append("Waiting for Neural Engine inventory") }
        else if devices.isEmpty { lines.append(current?.appleSilicon == true ? "Apple Silicon capability; no ANE driver endpoint detected" : "No Apple Neural Engine detected") }
        for device in devices {
            var line = "ANE · registry ID \(device.id)"
            if let cores = device.cores { line += " · \(cores) cores" }
            if let architecture = device.architecture, !architecture.isEmpty { line += " · \(architecture)" }
            if let loaded = device.firmwareLoaded { line += loaded ? " · firmware loaded" : " · firmware not loaded" }
            lines.append(line)
        }
        lines.append(powerWatts.map { String(format: "Power: %.3f W", $0) } ?? "Power: unavailable")
        lines.append(issue)
        lines.append("IOReport energy delta / elapsed seconds. Power is not utilization or inference throughput. Detection/firmware do not verify inference capability.")
        return lines.joined(separator: "\n")
    }
}
