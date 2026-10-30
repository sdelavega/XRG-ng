// Copyright (C) 2026 Stephen de la Vega.
// SPDX-License-Identifier: GPL-3.0-or-later
import AppKit
@testable import XRGCore

@main struct CollectorProfile {
    @MainActor static func main() throws {
        let env = ProcessInfo.processInfo.environment
        guard let domain = env["XRG_PROFILE_DOMAIN"], domain.hasPrefix("XRG.collector-profile."),
              UUID(uuidString: String(domain.dropFirst("XRG.collector-profile.".count))) != nil,
              let count = Int(env["XRG_PROFILE_ITERATIONS"] ?? ""), (1...300).contains(count),
              let interval = Double(env["XRG_PROFILE_INTERVAL"] ?? ""), interval.isFinite, (0.2...10).contains(interval),
              let report = env["XRG_PROFILE_REPORT"], let defaults = UserDefaults(suiteName: domain) else {
            throw NSError(domain: "XRGProfile", code: 1, userInfo: [NSLocalizedDescriptionKey: "Run through Tools/profile-macos-collectors.py"])
        }
        let hardware = env["XRG_PROFILE_HARDWARE"] == "1"
        _ = NSApplication.shared
        for key in ["showCPUGraph", "showMemoryGraph", "showNetworkGraph", "showDiskGraph", "showBatteryGraph"] { defaults.set(true, forKey: key) }
        for key in ["showGPUGraph", "showTemperatureGraph", "showVRAMGraph", "showFansGraph"] { defaults.set(hardware, forKey: key) }
        defaults.set(false, forKey: "checkForUpdates"); defaults.set(interval, forKey: "graphRefresh")
        defaults.set(false, forKey: "fastCPUUsage")
        defaults.synchronize()
        let setupStart = ProcessInfo.processInfo.systemUptime
        let window = XRGGraphWindow(contentRect: NSRect(x: 0, y: 0, width: 320, height: 900), defaults: defaults, scheduleTimers: false)
        defer { window.cleanupBeforeExiting(); window.close(); defaults.synchronize() }
        let settings = window.appSettings!, frame = NSRect(x: 0, y: 0, width: 300, height: 90)
        let processes = XRGProcessMiner(source: { [] })
        let cpu = XRGCPUMiner(), network = XRGNetMiner(), disk = XRGDiskMiner(), battery = XRGBatteryMiner()
        let gpu: XRGGPUMiner? = hardware ? XRGGPUMiner() : nil
        var views: [NSView] = [
            XRGCPUView(frame: frame, miner: cpu, processMiner: processes, settings: settings, defaults: defaults),
            XRGMemoryView(frame: frame, memoryMiner: XRGMemoryMiner(), processMiner: processes, settings: settings, defaults: defaults),
            XRGNetView(frame: frame, miner: network, fastMiner: XRGNetMiner(), settings: settings, defaults: defaults),
            XRGDiskView(frame: frame, miner: disk, settings: settings, defaults: defaults),
            XRGBatteryView(frame: frame, miner: battery, settings: settings, defaults: defaults)
        ]
        if hardware {
            views += [XRGGPUView(frame: frame, miner: gpu!, settings: settings, defaults: defaults),
                      XRGTemperatureView(frame: frame, miner: .shared, settings: settings, defaults: defaults)]
        }
        for view in views { window.contentView?.addSubview(view); view.awakeFromNib() }
        if hardware { window.initializeHardwareViews() }
        window.moduleManager?.windowChanged(to: window.frame.size)
        let setupMs = (ProcessInfo.processInfo.systemUptime - setupStart) * 1000
        var durations: [String: [Double]] = [:], cycles: [Double] = []
        window.moduleManager?.onUpdateMeasurement = { name, phase, seconds in durations["\(phase)/\(name)", default: []].append(seconds * 1000) }
        for _ in 0..<count {
            RunLoop.main.run(until: Date().addingTimeInterval(interval))
            let start = ProcessInfo.processInfo.systemUptime
            window.graphUpdate(nil)
            cycles.append((ProcessInfo.processInfo.systemUptime - start) * 1000)
        }
        // Give the final worker completion a bounded publication opportunity.
        if let gpu {
            let deadline = Date().addingTimeInterval(0.5)
            while gpu.isCollecting && Date() < deadline { RunLoop.main.run(until: Date().addingTimeInterval(0.005)) }
        }
        func summary(_ values: [Double]) -> [String: Any] {
            let sorted = values.sorted(), n = sorted.count
            return ["count": n, "minMs": sorted[0], "medianMs": (sorted[(n-1)/2] + sorted[n/2]) / 2,
                    "p95Ms": sorted[max(0, Int(ceil(Double(n) * 0.95)) - 1)], "maxMs": sorted[n-1], "totalMs": values.reduce(0,+)]
        }
        #if arch(arm64)
        let architecture = "arm64"
        #else
        let architecture = "x86_64"
        #endif
        var sourceStatus: [String: Any] = ["cpuCountersAvailable": cpu.countersAvailable,
            "networkCountersAvailable": network.countersAvailable, "diskCountersAvailable": disk.countersAvailable,
            "batteryCount": battery.batteries.count]
        if let gpu {
            sourceStatus["gpuCountersAvailable"] = gpu.countersAvailable
            sourceStatus["gpuCount"] = gpu.numberOfGPUs
            sourceStatus["gpuCompletedReads"] = gpu.completionRevision
            sourceStatus["gpuPendingRead"] = gpu.isCollecting
            sourceStatus["knownTemperatureChannels"] = XRGTemperatureMiner.shared.locationKeys(includingUnknown: false).count
        }
        let result: [String: Any] = ["schema": 1, "architecture": architecture,
            "os": ProcessInfo.processInfo.operatingSystemVersionString, "iterations": count, "intervalSeconds": interval,
            "hardwareEnabled": hardware, "sourceStatus": sourceStatus, "setupMs": setupMs, "cycles": summary(cycles),
            "callbacks": durations.mapValues(summary),
            "scope": "Main-actor normal callbacks: synchronous source calls/enqueues and label updates. GPU publication runs on completion outside the measured normal cycle. Includes gated/cache hits; excludes drawing, real menus, initialization (reported separately), async worker execution and whole-app responsiveness. Debug build; local hardware only. No AI/provider/process-inspector collection."]
        try JSONSerialization.data(withJSONObject: result, options: [.prettyPrinted, .sortedKeys]).write(to: URL(fileURLWithPath: report), options: .atomic)
    }
}
