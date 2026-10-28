// Copyright (C) 2026 Stephen de la Vega.
// SPDX-License-Identifier: GPL-3.0-or-later
// Build with XRGCore/XRGNPUReader.swift and XRGCore/XRGNPUActivityReader.swift.
// A read-only diagnostic; it never loads or executes an inference model.
import Foundation

@main struct NPUTelemetryDiagnostic {
    static func main() throws {
        let arguments = Array(CommandLine.arguments.dropFirst())
        guard arguments.count <= 1, let count = arguments.isEmpty ? 5 : Int(arguments[0]), (2...120).contains(count) else {
            fputs("Usage: npu-telemetry [sample count: 2...120]\n", stderr)
            exit(2)
        }
        let reader = XRGNPUReader()
        var previous: XRGNPUReading?
        for index in 0..<count {
            if index > 0 { Thread.sleep(forTimeInterval: 1) }
            let value = reader.sample()
            var record: [String: Any] = ["uptimeSeconds": value.time, "appleSilicon": value.appleSilicon,
                "endpoints": value.devices.count, "cores": value.devices.compactMap(\.cores),
                "activePercent": value.activity?.activeFraction.map { $0 * 100 } as Any? ?? NSNull(),
                "trafficObserved": value.traffic?.observations.map { $0 > 0 } as Any? ?? NSNull(),
                "trafficBinReports": value.traffic?.observations as Any? ?? NSNull(),
                "trafficIntervalSeconds": value.traffic.map { $0.end - $0.start } as Any? ?? NSNull(),
                "energy": value.energy?.map { ["id": $0.id, "unit": $0.unit, "counter": $0.value] as [String: Any] } as Any? ?? NSNull(),
                "powerError": value.error as Any? ?? NSNull()]
            var watts: Double?
            if let old = previous, value.time > old.time, let a = old.energy, let b = value.energy,
               !a.isEmpty, a.count == b.count, Set(a.map(\.id)).count == a.count,
               Set(b.map(\.id)).count == b.count, Set(a.map(\.id)) == Set(b.map(\.id)),
               old.devices.map(\.id).sorted() == value.devices.map(\.id).sorted() {
                let before = Dictionary(uniqueKeysWithValues: a.map { ($0.id, $0) })
                var joules = 0.0, valid = true
                for counter in b {
                    guard let prior = before[counter.id], prior.unit == counter.unit, prior.value >= 0,
                          counter.value >= prior.value, let factor = counter.joulesPerUnit else { valid = false; break }
                    joules += Double(counter.value - prior.value) * factor
                }
                if valid { watts = joules / (value.time - old.time) }
            }
            record["watts"] = watts as Any? ?? NSNull()
            let data = try JSONSerialization.data(withJSONObject: record, options: [.sortedKeys])
            print(String(decoding: data, as: UTF8.self)); fflush(stdout)
            previous = value
        }
    }
}
