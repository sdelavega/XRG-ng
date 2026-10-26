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

struct XRGProcessRecord: Sendable {
    let cpu: Double
    let pid: Int
    let resident: UInt64
    let virtual: UInt64
    let swaps: UInt64
    let user: String
    let command: String

    var dictionary: [String: Any] {
        ["%cpu": cpu, "pid": pid, "rss": resident, "vsz": virtual,
         "nswap": swaps, "user": user, "command": command]
    }
}

@MainActor
@objc(XRGProcessMiner)
public final class XRGProcessMiner: NSObject {
    private let source: @Sendable () -> [XRGProcessRecord]?
    private var refreshTask: Task<Void, Never>?
    private var pollingTask: Task<Void, Never>?
    private var records: [XRGProcessRecord] = []
    @objc public var processes: [[String: Any]] { records.map(\.dictionary) }

    public override convenience init() {
        self.init(source: Self.readProcesses)
        graphUpdate(nil)
        pollingTask = Task { [weak self] in
            while !Task.isCancelled {
                do { try await Task.sleep(for: .seconds(5)) } catch { return }
                self?.graphUpdate(nil)
            }
        }
    }

    init(source: @escaping @Sendable () -> [XRGProcessRecord]?) {
        self.source = source
        super.init()
    }

    deinit { refreshTask?.cancel(); pollingTask?.cancel() }

    @objc public func graphUpdate(_ timer: Timer?) {
        guard refreshTask == nil else { return }
        let source = source
        refreshTask = Task { [weak self] in
            let result = await Task.detached(priority: .utility) { source() }.value
            guard !Task.isCancelled, let self else { return }
            if let result { self.records = result }
            self.refreshTask = nil
        }
    }

    func refresh() async {
        graphUpdate(nil)
        await refreshTask?.value
    }

    @objc public func processesSortedByCPUUsage() -> [[String: Any]] {
        records.sorted { $0.cpu == $1.cpu ? $0.pid < $1.pid : $0.cpu > $1.cpu }.map(\.dictionary)
    }
    @objc public func processesSortedByMemoryUsage() -> [[String: Any]] {
        records.sorted { $0.resident == $1.resident ? $0.pid < $1.pid : $0.resident > $1.resident }.map(\.dictionary)
    }

    nonisolated static func parse(_ output: String) -> [XRGProcessRecord] {
        output.split(whereSeparator: \.isNewline).compactMap { line in
            let fields = line.split(maxSplits: 6, omittingEmptySubsequences: true, whereSeparator: \.isWhitespace)
            guard fields.count == 7, let cpu = Double(fields[0]), cpu.isFinite, cpu >= 0,
                  let pid = Int(fields[1]), pid > 0, let resident = UInt64(fields[2]),
                  let virtual = UInt64(fields[3]),
                  let swaps = fields[4] == "-" ? 0 : UInt64(fields[4]) else { return nil }
            return XRGProcessRecord(cpu: cpu, pid: pid, resident: resident, virtual: virtual,
                                    swaps: swaps, user: String(fields[5]), command: String(fields[6]))
        }
    }

    // Preserve ps's CPU averaging and KiB units while keeping subprocess work off the UI thread.
    nonisolated static func readProcesses() -> [XRGProcessRecord]? {
        let process = Process()
        let pipe = Pipe()
        process.executableURL = URL(fileURLWithPath: "/bin/ps")
        process.arguments = ["axwwrco", "%cpu,pid,rss,vsz,nswap,user,command"]
        process.environment = ["LC_ALL": "C", "PATH": "/usr/bin:/bin"]
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice
        do { try process.run() } catch { return nil }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        guard process.terminationStatus == 0, let output = String(data: data, encoding: .utf8) else { return nil }
        return parse(output)
    }
}
