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
    @nonobjc private(set) var activeFraction: Double?
    @nonobjc private(set) var trafficObserved: Bool?
    @nonobjc private(set) var trafficReportsPerSecond: Double?
    @nonobjc private(set) var lastActivityTime: TimeInterval?
    private var lastActivitySource: String?
    private var lastActivityIntervalEnd: TimeInterval?
    private var lastTrafficIntervalEnd: TimeInterval?
    private var trafficSourceIDs: [String] = []
    @nonobjc var secondsSinceActivity: TimeInterval? {
        guard let lastActivityTime, clock().isFinite else { return nil }
        return max(0, clock() - lastActivityTime)
    }
    @objc public private(set) var activityDataSet = XRGDataSet()
    @objc public private(set) var trafficDataSet = XRGDataSet()
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
        activityDataSet.resize(count, fillingWith: XRGGraphRenderer.missingValue)
        trafficDataSet.resize(count, fillingWith: XRGGraphRenderer.missingValue)
    }
    private func resetHistory() {
        powerDataSet = XRGDataSet(); powerDataSet.resize(numSamples)
        powerDataSet.setAllValues(XRGGraphRenderer.missingValue)
    }
    private func resetActivity() {
        activeFraction = nil
        activityDataSet.resize(numSamples, fillingWith: XRGGraphRenderer.missingValue)
        activityDataSet.setAllValues(XRGGraphRenderer.missingValue)
    }
    private func acceptActivity(_ reading: XRGNPUReading) {
        guard !reading.devices.isEmpty, let interval = reading.activity, let fraction = interval.activeFraction,
              interval.end <= reading.time, reading.time - interval.end <= 5,
              lastActivityIntervalEnd.map({ interval.end > $0 && interval.start >= $0 }) ?? true else {
            resetActivity(); return
        }
        lastActivityIntervalEnd = interval.end; activeFraction = fraction
        activityDataSet.setNextValue(fraction * 100)
        if fraction > 0 { lastActivityTime = interval.end; lastActivitySource = "active residency" }
    }
    private func resetTraffic() {
        trafficObserved = nil
        trafficReportsPerSecond = nil
        trafficDataSet.resize(numSamples, fillingWith: XRGGraphRenderer.missingValue)
        trafficDataSet.setAllValues(XRGGraphRenderer.missingValue)
    }
    private func acceptTraffic(_ reading: XRGNPUReading) {
        guard !reading.devices.isEmpty, let interval = reading.traffic, let count = interval.observations,
              interval.end <= reading.time, reading.time - interval.end <= 5,
              lastTrafficIntervalEnd.map({ interval.end > $0 && interval.start >= $0 }) ?? true else {
            resetTraffic(); return
        }
        let rate = Double(count) / (interval.end - interval.start)
        guard rate.isFinite, rate >= 0 else { resetTraffic(); return }
        let ids = interval.channels.map(\.id).sorted()
        if trafficSourceIDs != ids { resetTraffic(); trafficSourceIDs = ids }
        lastTrafficIntervalEnd = interval.end; trafficObserved = count > 0
        trafficReportsPerSecond = rate; trafficDataSet.setNextValue(rate)
        if activeFraction == nil, count > 0 {
            lastActivityTime = interval.end; lastActivitySource = "ANE fabric traffic (observed)"
        }
    }
    @objc public func getLatestNPUInfo() {
        if let worker {
            worker.request { [weak self] reading in self?.accept(reading); self?.onUpdate?() }
        } else if let reading = source?() { accept(reading) }
        if let lastReading, clock() - lastReading > max(5, staleAfter.isFinite ? staleAfter : 5) {
            powerWatts = nil; previous = nil; issue = "ANE sample is stale"; resetHistory(); resetActivity(); resetTraffic()
        }
    }
    private func accept(_ reading: XRGNPUReading) {
        guard reading.time.isFinite, reading.time >= 0, clock().isFinite,
              reading.time <= clock() + 1, clock() - reading.time <= 5 else {
            powerWatts = nil; previous = nil; issue = "Invalid/stale ANE sample time"; resetHistory(); resetActivity(); resetTraffic(); return
        }
        if let lastReading, reading.time <= lastReading { return }
        if current?.devices.map(\.id).sorted() != reading.devices.map(\.id).sorted() {
            lastActivityIntervalEnd = nil; lastActivityTime = nil; lastActivitySource = nil; resetActivity()
            lastTrafficIntervalEnd = nil; trafficSourceIDs = []; resetTraffic()
        }
        devices = reading.devices; current = reading; lastReading = reading.time
        acceptActivity(reading)
        acceptTraffic(reading)
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
        if activeFraction == nil, trafficObserved != true, watts > 0 { lastActivityTime = reading.time; lastActivitySource = "energy increase (inferred)" }
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
        if let fraction = activeFraction {
            lines.append(String(format: "Active time: %.2f%% (busiest ANE cluster, software residency)", fraction * 100))
            lines.append(fraction > 0 ? "Activity: active during the last interval" : "Activity: idle during the last interval")
        } else {
            lines.append("Active time: unavailable")
            if trafficObserved == true {
                lines.append("Activity: ANE fabric traffic observed; utilization unknown")
            } else {
                lines.append(powerWatts.map { $0 > 0 ? "Activity: energy increase detected (inferred)" : "Activity: no energy increase reported; utilization unknown" }
                             ?? "Activity: unavailable")
            }
        }
        lines.append(trafficObserved.map { $0 ? "ANE traffic: reported during the last interval (marker band)" : "ANE traffic: no positive bandwidth-bin reports; this does not prove idle" } ?? "ANE traffic: unavailable")
        if let rate = trafficReportsPerSecond {
            lines.append(String(format: "Traffic band: %.1f positive bandwidth-bin reports/s; not bytes, inferences or capacity", rate))
        }
        if let elapsed = secondsSinceActivity {
            lines.append("Last detected activity: \(Int(min(elapsed, Double(Int32.max)))) s ago · \(lastActivitySource ?? "unknown source")")
        } else { lines.append("Last detected activity: none observed this session") }
        lines.append(issue)
        lines.append("Active time measures ACT state residency, not compute-core occupancy or inference throughput. Power is not utilization; zero power alone does not prove idle. Unavailable counters remain unknown.")
        return lines.joined(separator: "\n")
    }
}
