// Copyright (C) 2026 Stephen de la Vega.
// SPDX-License-Identifier: GPL-3.0-or-later
import Foundation
import IOKit
import Darwin

struct XRGNPUDevice: Sendable, Equatable {
    let id: UInt64
    let cores: Int?
    let architecture: String?
    let firmwareLoaded: Bool?

    static func parse(id: UInt64, properties: [String: Any]) -> Self {
        let values = properties["DeviceProperties"] as? [String: Any] ?? [:]
        var cores: Int?
        if let value = values["ANEDevicePropertyNumANECores"] as? NSNumber,
           CFGetTypeID(value) != CFBooleanGetTypeID(), value.doubleValue.isFinite,
           (1...1024).contains(value.intValue), value.doubleValue == Double(value.intValue) { cores = value.intValue }
        let architecture = (values["ANEDevicePropertyTypeANEArchitectureTypeStr"] as? String)
            .map { String($0.filter { !$0.isNewline && !$0.unicodeScalars.contains(where: CharacterSet.controlCharacters.contains) }.prefix(64)) }
        let firmware = properties["FirmwareLoaded"] as? NSNumber
        return Self(id: id, cores: cores, architecture: architecture,
                    firmwareLoaded: firmware.flatMap { [0.0, 1.0].contains($0.doubleValue) ? $0.boolValue : nil })
    }
}
struct XRGNPUEnergy: Sendable, Equatable {
    let id: String
    let unit: String
    let value: Int64
    var joulesPerUnit: Double? {
        switch unit {
        case "J": 1
        case "mJ": 0.001
        case "uJ", "µJ", "μJ": 0.000001
        case "nJ": 0.000000001
        default: nil
        }
    }
}
struct XRGNPUReading: Sendable {
    let time: TimeInterval
    let devices: [XRGNPUDevice]
    let appleSilicon: Bool
    let energy: [XRGNPUEnergy]?
    let error: String?
    var activity: XRGNPUActivityInterval? = nil
    var traffic: XRGNPUTrafficInterval? = nil
}

/// Used only on the NPU worker queue. IOReport is optional and dynamically
/// resolved; no device user client, model runtime, root helper or subprocess.
final class XRGNPUReader {
    private final class API {
        typealias Copy = @convention(c) (CFString?, CFString?, UInt64, UInt64, UInt64) -> Unmanaged<CFMutableDictionary>?
        typealias Subscribe = @convention(c) (CFAllocator?, CFMutableDictionary, UnsafeMutablePointer<Unmanaged<CFMutableDictionary>?>?, UInt64, UnsafeMutableRawPointer?) -> Unmanaged<CFTypeRef>?
        typealias Sample = @convention(c) (CFTypeRef, CFMutableDictionary, UnsafeMutableRawPointer?) -> Unmanaged<CFDictionary>?
        typealias Label = @convention(c) (CFDictionary) -> Unmanaged<CFString>?
        typealias Value = @convention(c) (CFDictionary, Int32) -> Int64
        let handle: UnsafeMutableRawPointer
        let copy: Copy, subscribe: Subscribe, sample: Sample, name: Label, unit: Label, value: Value
        init?() {
            guard let handle = dlopen("/usr/lib/libIOReport.dylib", RTLD_LAZY | RTLD_LOCAL) else { return nil }
            func load<T>(_ name: String, _: T.Type) -> T? { dlsym(handle, name).map { unsafeBitCast($0, to: T.self) } }
            guard let copy = load("IOReportCopyChannelsInGroup", Copy.self),
                  let subscribe = load("IOReportCreateSubscription", Subscribe.self),
                  let sample = load("IOReportCreateSamples", Sample.self),
                  let name = load("IOReportChannelGetChannelName", Label.self),
                  let unit = load("IOReportChannelGetUnitLabel", Label.self),
                  let value = load("IOReportSimpleGetIntegerValue", Value.self) else { dlclose(handle); return nil }
            self.handle = handle; self.copy = copy; self.subscribe = subscribe; self.sample = sample
            self.name = name; self.unit = unit; self.value = value
        }
        deinit { dlclose(handle) }
    }
    private var api: API?
    private var subscription: CFTypeRef?
    private var channels: CFMutableDictionary?
    private var nextAttempt: TimeInterval = 0
    private let activityReader = XRGNPUActivityReader()
    private let trafficReader = XRGNPUTrafficReader()
    deinit { subscription = nil; channels = nil; api = nil }

    static func isAppleSilicon() -> Bool {
        var value: Int32 = 0, size = MemoryLayout<Int32>.size
        return sysctlbyname("hw.optional.arm64", &value, &size, nil, 0) == 0 && value == 1
    }
    static func devices() -> ([XRGNPUDevice], String?) {
        var iterator: io_iterator_t = 0
        guard IOServiceGetMatchingServices(kIOMainPortDefault, IOServiceMatching("H11ANEIn"), &iterator) == KERN_SUCCESS else {
            return ([], "Neural Engine inventory unavailable")
        }
        defer { IOObjectRelease(iterator) }
        var devices: [XRGNPUDevice] = []
        for _ in 0..<16 {
            let service = IOIteratorNext(iterator)
            guard service != 0 else { return (devices, nil) }
            defer { IOObjectRelease(service) }
            var id: UInt64 = 0, values: Unmanaged<CFMutableDictionary>?
            guard IORegistryEntryGetRegistryEntryID(service, &id) == KERN_SUCCESS,
                  IORegistryEntryCreateCFProperties(service, &values, nil, 0) == KERN_SUCCESS,
                  let properties = values?.takeRetainedValue() as? [String: Any] else { return (devices, "Neural Engine properties unavailable") }
            if !devices.contains(where: { $0.id == id }) { devices.append(.parse(id: id, properties: properties)) }
        }
        return (devices, "Neural Engine inventory limit reached")
    }
    static func isEnergyChannel(_ name: String) -> Bool {
        if name == "ANE" || name == "ANE Energy" { return true }
        let digits = name.dropFirst(3)
        return name.hasPrefix("ANE") && !digits.isEmpty && digits.allSatisfy(\.isNumber) && digits.allSatisfy(\.isASCII)
    }
    private func entries(_ dictionary: CFDictionary) -> [NSDictionary]? {
        guard let result = (dictionary as NSDictionary)["IOReportChannels"] as? [NSDictionary], result.count <= 512 else { return nil }
        return result
    }
    private func connect(_ now: TimeInterval) -> Bool {
        guard now >= nextAttempt else { return false }
        nextAttempt = now + 30
        guard let api = API(), let all = api.copy("Energy Model" as CFString, nil, 0, 0, 0)?.takeRetainedValue(),
              let entries = entries(all) else { return false }
        var selected = entries.filter { entry in
            let name = api.name(entry as CFDictionary)?.takeUnretainedValue() as String? ?? ""
            return Self.isEnergyChannel(name)
        }
        // Prefer an aggregate to indexed components; never sum both.
        let aggregate = selected.filter { entry in
            let name = api.name(entry as CFDictionary)?.takeUnretainedValue() as String? ?? ""
            return name == "ANE"
        }
        let alternate = selected.filter { api.name($0 as CFDictionary)?.takeUnretainedValue() as String? == "ANE Energy" }
        if !aggregate.isEmpty { selected = aggregate }
        else if !alternate.isEmpty { selected = alternate }
        guard !selected.isEmpty, selected.count <= 16 else { return false }
        let chosen = (all as NSDictionary).mutableCopy() as! NSMutableDictionary
        chosen["IOReportChannels"] = selected
        var actual: Unmanaged<CFMutableDictionary>?
        let subscription = api.subscribe(nil, chosen as CFMutableDictionary, &actual, 0, nil)?.takeRetainedValue()
        let resolved = actual?.takeRetainedValue()
        guard let subscription else { return false }
        self.api = api; self.subscription = subscription
        self.channels = resolved ?? (chosen as CFMutableDictionary)
        return true
    }
    func sample() -> XRGNPUReading {
        let silicon = Self.isAppleSilicon(), inventory = Self.devices()
        let now = ProcessInfo.processInfo.systemUptime
        let activity = activityReader.sample(deviceIDs: inventory.0.map(\.id))
        let traffic = trafficReader.sample(deviceIDs: inventory.0.map(\.id))
        func result(_ energy: [XRGNPUEnergy]?, _ error: String?) -> XRGNPUReading {
            XRGNPUReading(time: ProcessInfo.processInfo.systemUptime, devices: inventory.0, appleSilicon: silicon, energy: energy, error: error ?? inventory.1, activity: activity, traffic: traffic)
        }
        guard !inventory.0.isEmpty else {
            subscription = nil; channels = nil; nextAttempt = 0
            return result(nil, inventory.1 ?? (silicon ? "Apple Silicon ANE capability; driver endpoint unavailable" : "No Apple Neural Engine detected"))
        }
        guard subscription != nil || connect(now), let api, let subscription, let channels,
              let values = api.sample(subscription, channels, nil)?.takeRetainedValue(), let entries = entries(values) else {
            self.subscription = nil; self.channels = nil
            return result(nil, "ANE power telemetry unavailable")
        }
        var energy: [XRGNPUEnergy] = [], ids = Set<String>()
        for entry in entries {
            let name = api.name(entry as CFDictionary)?.takeUnretainedValue() as String? ?? ""
            guard Self.isEnergyChannel(name) else { continue }
            let unit = api.unit(entry as CFDictionary)?.takeUnretainedValue() as String? ?? ""
            guard let driver = entry["DriverID"] as? NSNumber, CFGetTypeID(driver) != CFBooleanGetTypeID() else { return result(nil, "ANE channel identity unavailable") }
            let counter = XRGNPUEnergy(id: "\(driver.stringValue):\(name)", unit: unit, value: api.value(entry as CFDictionary, 0))
            guard counter.value >= 0, counter.joulesPerUnit != nil, ids.insert(counter.id).inserted else { return result(nil, "Invalid or duplicate ANE energy counter") }
            energy.append(counter)
        }
        return result(energy.isEmpty ? nil : energy, energy.isEmpty ? "ANE energy counters unavailable" : nil)
    }
}
