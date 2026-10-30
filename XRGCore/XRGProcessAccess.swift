// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Stephen de la Vega.
import Darwin
import Foundation

/// Captured before and after the ps scan. Numeric PIDs alone never identify rows.
struct XRGProcessIdentity: Hashable, Sendable {
    let pid: Int32
    let uid: UInt32
    let startSeconds: UInt64
    let startMicroseconds: UInt64
    let name: String
    fileprivate init(_ bsd: proc_bsdinfo) {
        pid = Int32(bsd.pbi_pid); uid = bsd.pbi_uid
        startSeconds = bsd.pbi_start_tvsec; startMicroseconds = bsd.pbi_start_tvusec
        var name = bsd.pbi_name
        let full = withUnsafeBytes(of: &name) { String(decoding: $0.prefix(while: { $0 != 0 }), as: UTF8.self) }
        var short = bsd.pbi_comm
        self.name = full.isEmpty ? withUnsafeBytes(of: &short) { String(decoding: $0.prefix(while: { $0 != 0 }), as: UTF8.self) } : full
    }
}

enum XRGProcessAccessError: Error, LocalizedError, Sendable {
    case changed, gone, unavailable(String), refused(String)
    var terminal: Bool { switch self { case .changed, .gone: true; default: false } }
    var errorDescription: String? {
        switch self {
        case .changed: "Process identity, name or ownership changed. This window will not follow a replacement; select it again in the table."
        case .gone: "The process has exited or is no longer available. This window will not follow a reused PID."
        case let .unavailable(message), let .refused(message): message
        }
    }
}

struct XRGProcessLiveSnapshot: Sendable {
    let identity: XRGProcessIdentity
    let parent: UInt32
    let realUID: UInt32
    let status: UInt32
    let nice: Int32
    let resident: UInt64?
    let virtual: UInt64?
    let cpuNanoseconds: UInt64?
    let threads: Int32?
    let priority: Int32?
    let sampledAt: Date
    let uptime: TimeInterval
    var stopped: Bool { status == UInt32(SSTOP) }
    var exited: Bool { status == UInt32(SZOMB) }
    var state: String {
        switch Int32(status) {
        case SIDL: "Starting"
        case SRUN: "Runnable"
        case SSLEEP: "Sleeping"
        case SSTOP: "Stopped"
        case SZOMB: "Exited (zombie)"
        default: "Unknown (\(status))"
        }
    }
    func intervalCPU(since previous: Self?) -> Double? {
        guard let previous, previous.identity == identity,
              let before = previous.cpuNanoseconds, let after = cpuNanoseconds,
              after >= before, uptime > previous.uptime else { return nil }
        let percent = Double(after - before) / 1_000_000_000 / (uptime - previous.uptime) * 100
        return percent.isFinite ? percent : nil
    }
}

enum XRGProcessAction: Int, CaseIterable, Sendable {
    case terminate, forceKill, pause, resume
    var title: String { switch self {
    case .terminate: "Terminate (SIGTERM)"
    case .forceKill: "Force Kill (SIGKILL)"
    case .pause: "Pause (SIGSTOP)"
    case .resume: "Resume (SIGCONT)"
    } }
    var explanation: String { switch self {
    case .terminate: "Ask this process to exit. It may handle or ignore the request. Unsaved work may be lost."
    case .forceKill: "End this process immediately without allowing cleanup. Unsaved work will be lost."
    case .pause: "Stop this process until it is resumed. Work and services it provides will stop while paused."
    case .resume: "Allow this stopped process to run again."
    } }
    var signal: Int32 { switch self {
    case .terminate: SIGTERM
    case .forceKill: SIGKILL
    case .pause: SIGSTOP
    case .resume: SIGCONT
    } }
    func enabled(_ value: XRGProcessLiveSnapshot) -> Bool {
        value.identity.pid > 1 && value.identity.pid != getpid() && !value.exited
            && (self != .pause || !value.stopped) && (self != .resume || value.stopped)
    }
}

/// SDK libproc/task-name APIs only. No task-for-pid control rights, root helper,
/// command arguments, environment, or numeric-PID signal fallback.
enum XRGProcessAccess {
    static func bsd(_ pid: Int32) throws -> proc_bsdinfo {
        guard pid > 0 else { throw XRGProcessAccessError.refused("Invalid process ID") }
        var value = proc_bsdinfo()
        errno = 0
        let count = proc_pidinfo(pid, PROC_PIDTBSDINFO, 0, &value, Int32(MemoryLayout.size(ofValue: value)))
        guard count == MemoryLayout.size(ofValue: value), value.pbi_pid == UInt32(pid) else {
            if errno == ESRCH || errno == ENOENT { throw XRGProcessAccessError.gone }
            throw XRGProcessAccessError.unavailable("Process information unavailable: \(String(cString: strerror(errno)))")
        }
        return value
    }
    static func identity(_ pid: Int32) throws -> XRGProcessIdentity { XRGProcessIdentity(try bsd(pid)) }
    static func identities() -> [Int32: XRGProcessIdentity] {
        let capacity = 65_536
        var pids = [Int32](repeating: 0, count: capacity)
        let count = pids.withUnsafeMutableBytes { proc_listallpids($0.baseAddress, Int32($0.count)) }
        guard count > 0, count < capacity else { return [:] }
        var result: [Int32: XRGProcessIdentity] = [:]
        for pid in pids.prefix(Int(count)) where pid > 0 {
            if let id = try? identity(pid) { result[pid] = id }
        }
        return result
    }
    private static let timebase: (UInt32, UInt32)? = {
        // libproc returns kernel ticks. Rosetta's mach_timebase_info describes
        // the translated userspace clock instead; query the kernel frequency.
        var frequency: UInt64 = 0
        var size = MemoryLayout.size(ofValue: frequency)
        guard sysctlbyname("hw.tbfrequency", &frequency, &size, nil, 0) == 0,
              size == MemoryLayout<UInt64>.size,
              let denominator = UInt32(exactly: frequency), denominator > 0 else { return nil }
        return (1_000_000_000, denominator)
    }()
    /// proc_taskinfo CPU times are Mach absolute ticks, including on Apple Silicon.
    /// Divide first to retain integer precision without overflowing ticks * numer.
    static func nanoseconds(_ ticks: UInt64, numerator: UInt32, denominator: UInt32) -> UInt64? {
        guard numerator > 0, denominator > 0 else { return nil }
        let whole = (ticks / UInt64(denominator)).multipliedReportingOverflow(by: UInt64(numerator))
        let fraction = (ticks % UInt64(denominator)) * UInt64(numerator) / UInt64(denominator)
        let sum = whole.partialValue.addingReportingOverflow(fraction)
        return whole.overflow || sum.overflow ? nil : sum.partialValue
    }
    static func read(_ expected: XRGProcessIdentity) throws -> XRGProcessLiveSnapshot {
        let before = try bsd(expected.pid)
        guard XRGProcessIdentity(before) == expected else { throw XRGProcessAccessError.changed }
        var task = proc_taskinfo()
        let available = proc_pidinfo(expected.pid, PROC_PIDTASKINFO, 0, &task, Int32(MemoryLayout.size(ofValue: task))) == MemoryLayout.size(ofValue: task)
        let after = try bsd(expected.pid)
        guard XRGProcessIdentity(after) == expected else { throw XRGProcessAccessError.changed }
        let total = task.pti_total_user.addingReportingOverflow(task.pti_total_system)
        let cpu = available && !total.overflow ? timebase.flatMap { nanoseconds(total.partialValue, numerator: $0.0, denominator: $0.1) } : nil
        return XRGProcessLiveSnapshot(identity: expected, parent: after.pbi_ppid, realUID: after.pbi_ruid,
            status: after.pbi_status, nice: after.pbi_nice,
            resident: available ? task.pti_resident_size : nil, virtual: available ? task.pti_virtual_size : nil,
            cpuNanoseconds: cpu,
            threads: available ? task.pti_threadnum : nil, priority: available ? task.pti_priority : nil,
            sampledAt: Date(), uptime: ProcessInfo.processInfo.systemUptime)
    }
    fileprivate static func token(_ pid: Int32) throws -> [UInt32] {
        var port: mach_port_name_t = 0
        guard task_name_for_pid(mach_task_self_, pid, &port) == KERN_SUCCESS else {
            throw XRGProcessAccessError.unavailable("Process identity token unavailable. macOS may deny access; no signal was sent.")
        }
        defer { mach_port_deallocate(mach_task_self_, port) }
        var value = audit_token_t()
        var count = mach_msg_type_number_t(MemoryLayout<audit_token_t>.size / MemoryLayout<integer_t>.size)
        let result = withUnsafeMutablePointer(to: &value) { p in
            p.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                task_info(port, task_flavor_t(TASK_AUDIT_TOKEN), $0, &count)
            }
        }
        guard result == KERN_SUCCESS, count == 8, value.val.5 == UInt32(pid) else {
            throw XRGProcessAccessError.unavailable("Process identity token could not be verified; no signal was sent.")
        }
        return withUnsafeBytes(of: value) { Array($0.bindMemory(to: UInt32.self)) }
    }
}

/// Holds the reviewed audit token, whose PID version the kernel checks at delivery.
/// A process exiting during confirmation can never redirect a signal to a new PID.
struct XRGProcessTarget: Sendable {
    let snapshot: XRGProcessLiveSnapshot
    private let token: [UInt32]
    static func prepare(_ identity: XRGProcessIdentity) throws -> Self {
        guard identity.pid > 1, identity.pid != getpid() else {
            throw XRGProcessAccessError.refused("PID 0, PID 1 and XRG-ng itself cannot be controlled.")
        }
        let before = try XRGProcessAccess.read(identity)
        guard !before.exited else { throw XRGProcessAccessError.gone }
        let token = try XRGProcessAccess.token(identity.pid)
        _ = try XRGProcessAccess.read(identity)
        guard token[1] == identity.uid else { throw XRGProcessAccessError.changed }
        return Self(snapshot: before, token: token)
    }
    func send(_ action: XRGProcessAction) throws {
        let current = try XRGProcessAccess.read(snapshot.identity)
        guard try XRGProcessAccess.token(snapshot.identity.pid) == token else { throw XRGProcessAccessError.changed }
        guard action.enabled(current) else { throw XRGProcessAccessError.refused("This action is unavailable for the current process state. Refresh and review it again.") }
        var value = audit_token_t()
        withUnsafeMutableBytes(of: &value) { bytes in bytes.copyBytes(from: token.withUnsafeBytes { Array($0) }) }
        let result = proc_signal_with_audittoken(&value, action.signal)
        guard result == 0 else {
            throw XRGProcessAccessError.refused("Signal was not delivered: \(String(cString: strerror(result))). macOS permissions and process protections still apply.")
        }
    }
}
