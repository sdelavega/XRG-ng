// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Stephen de la Vega.
import AppKit
import Darwin
import Testing
@testable import XRGCore

private final class ProcessChild {
    let process = Process()
    init() throws {
        process.executableURL = URL(fileURLWithPath: "/bin/sleep"); process.arguments = ["120"]
        process.standardOutput = FileHandle.nullDevice; process.standardError = FileHandle.nullDevice
        try process.run()
    }
    var identity: XRGProcessIdentity { get throws { try XRGProcessAccess.identity(process.processIdentifier) } }
    func state(stopped: Bool) throws {
        let end = Date().addingTimeInterval(2)
        while try XRGProcessAccess.read(identity).stopped != stopped {
            guard Date() < end else { throw XRGProcessAccessError.unavailable("Child state did not change") }
            Thread.sleep(forTimeInterval: 0.01)
        }
    }
    func exited(signal: Int32) throws {
        let end = Date().addingTimeInterval(2)
        while process.isRunning {
            guard Date() < end else { throw XRGProcessAccessError.unavailable("Child did not exit") }
            Thread.sleep(forTimeInterval: 0.01)
        }
        process.waitUntilExit()
        #expect(process.terminationReason == .uncaughtSignal && process.terminationStatus == signal)
    }
    deinit {
        // Cleanup is restricted to the child owned by this test. Resume is not
        // needed for SIGKILL; never leave a paused child after a failed assertion.
        if process.isRunning { _ = kill(process.processIdentifier, SIGKILL); process.waitUntilExit() }
    }
}

@Suite(.serialized) @MainActor
struct XRGProcessAccessTests {
    @Test func nativeIdentityAndDetailsAndMissingTaskValues() throws {
        let child = try ProcessChild(), id = try child.identity
        let value = try XRGProcessAccess.read(id)
        #expect(id.pid == child.process.processIdentifier && id.uid == geteuid())
        #expect(value.parent == getpid() && value.resident != nil && value.threads != nil)
        #expect(value.intervalCPU(since: nil) == nil)
        let later = XRGProcessLiveSnapshot(identity: id, parent: value.parent, realUID: value.realUID,
            status: value.status, nice: value.nice, resident: nil, virtual: nil, cpuNanoseconds: 3_000_000_000,
            threads: nil, priority: nil, sampledAt: Date(), uptime: 12)
        let previous = XRGProcessLiveSnapshot(identity: id, parent: value.parent, realUID: value.realUID,
            status: value.status, nice: value.nice, resident: nil, virtual: nil, cpuNanoseconds: 1_000_000_000,
            threads: nil, priority: nil, sampledAt: Date(), uptime: 10)
        #expect(later.intervalCPU(since: previous) == 100)
        #expect(previous.intervalCPU(since: later) == nil)
        let text = XRGProcessDetailController.text(later, cpu: nil)
        #expect(text.contains("RSS: unavailable") && text.contains("Threads: unavailable"))
        #expect(text.contains("CPU lifetime (user + system): 3.000 s"))
        #expect(!text.contains("/bin/sleep"))
    }
    @Test func machTicksConvertWithoutOverflowAndAgreeWithIndependentRusage() throws {
        #expect(XRGProcessAccess.nanoseconds(24, numerator: 125, denominator: 3) == 1000)
        #expect(XRGProcessAccess.nanoseconds(UInt64.max, numerator: 1, denominator: 1) == UInt64.max)
        #expect(XRGProcessAccess.nanoseconds(UInt64.max, numerator: 125, denominator: 3) == nil)
        #expect(XRGProcessAccess.nanoseconds(1, numerator: 1, denominator: 0) == nil)
        #expect(XRGProcessAccess.nanoseconds(0, numerator: 125, denominator: 3) == 0)
        func usage() throws -> Double {
            var value = rusage()
            guard getrusage(RUSAGE_SELF, &value) == 0 else { throw XRGProcessAccessError.unavailable("getrusage failed") }
            return Double(value.ru_utime.tv_sec + value.ru_stime.tv_sec)
                + Double(value.ru_utime.tv_usec + value.ru_stime.tv_usec) / 1_000_000
        }
        let id = try XRGProcessAccess.identity(getpid()), beforeUsage = try usage()
        let before = try XRGProcessAccess.read(id)
        var checksum: UInt64 = 7
        let end = ProcessInfo.processInfo.systemUptime + 0.15
        while ProcessInfo.processInfo.systemUptime < end {
            for _ in 0..<2000 { checksum = checksum &* 1664525 &+ 1013904223 }
        }
        let after = try XRGProcessAccess.read(id), elapsedCPU = try usage() - beforeUsage
        let measured = Double(try #require(after.cpuNanoseconds) - #require(before.cpuNanoseconds)) / 1_000_000_000
        #expect(checksum != 0 && elapsedCPU > 0)
        #expect(abs(measured - elapsedCPU) < max(0.02, elapsedCPU * 0.15))
    }
    @Test func pauseResumeAndSignalsAffectOnlyTheChosenChildren() throws {
        let untouched = try ProcessChild()
        let child = try ProcessChild(), id = try child.identity
        let running = try XRGProcessAccess.read(id)
        #expect(XRGProcessAction.pause.enabled(running) && !XRGProcessAction.resume.enabled(running))
        try XRGProcessTarget.prepare(id).send(.pause); try child.state(stopped: true)
        let stopped = try XRGProcessAccess.read(id)
        #expect(!XRGProcessAction.pause.enabled(stopped) && XRGProcessAction.resume.enabled(stopped))
        #expect(throws: (any Error).self) { try XRGProcessTarget.prepare(id).send(.pause) }
        try XRGProcessTarget.prepare(id).send(.resume); try child.state(stopped: false)
        try XRGProcessTarget.prepare(id).send(.terminate); try child.exited(signal: SIGTERM)
        let force = try ProcessChild()
        try XRGProcessTarget.prepare(force.identity).send(.forceKill); try force.exited(signal: SIGKILL)
        #expect(untouched.process.isRunning)
    }
    @Test func exitedAndSelfTargetsAreRefusedAndNoPIDFallbackExists() throws {
        let child = try ProcessChild(), id = try child.identity
        let target = try XRGProcessTarget.prepare(id)
        child.process.terminate(); child.process.waitUntilExit()
        let other = try ProcessChild()
        #expect(throws: (any Error).self) { try target.send(.forceKill) }
        #expect(throws: (any Error).self) { try XRGProcessAccess.read(id) }
        #expect(throws: (any Error).self) { try XRGProcessTarget.prepare(XRGProcessAccess.identity(getpid())) }
        #expect(throws: (any Error).self) { try XRGProcessAccess.identity(0) }
        #expect(other.process.isRunning)
    }
    @Test func liveRowsHaveIdentitiesAndFixtureRowsHaveNone() async throws {
        let child = try ProcessChild()
        let rows = try #require(await Task.detached { XRGProcessMiner.readProcesses() }.value)
        let row = try #require(rows.first { $0.pid == child.process.processIdentifier })
        #expect(row.identity == (try child.identity))
        #expect(XRGProcessMiner.parse("0 42 1 2 - user fixture").first?.identity == nil)
    }
    @Test func liveWindowCancelAndCloseInvalidateAReviewedAction() async throws {
        _ = NSApplication.shared
        let child = try ProcessChild(), id = try child.identity
        var completion: ((Bool) -> Void)?
        let controller = XRGProcessDetailController(identity: id, review: { _, text, done in
            #expect(text.contains("PID \(id.pid)") && text.contains("UID \(id.uid)")); completion = done
        })
        controller.present(); await controller.waitForRefresh()
        #expect(controller.snapshot?.identity == id && controller.buttons[0].isEnabled)
        controller.request(.pause); await controller.waitForAction()
        #expect(completion != nil)
        completion?(false)
        #expect(controller.status.stringValue.contains("cancelled"))
        try child.state(stopped: false)
        controller.request(.forceKill); await controller.waitForAction()
        controller.close(); completion?(true)
        #expect(controller.refreshTimer == nil && child.process.isRunning)
    }
    @Test func exitDuringConfirmationDisablesActionsWithoutTouchingAnotherChild() async throws {
        _ = NSApplication.shared
        let child = try ProcessChild(), id = try child.identity
        let untouched = try ProcessChild()
        var completion: ((Bool) -> Void)?
        let controller = XRGProcessDetailController(identity: id, review: { _, _, done in completion = done })
        controller.present(); await controller.waitForRefresh()
        controller.request(.forceKill); await controller.waitForAction()
        #expect(completion != nil)
        child.process.terminate(); child.process.waitUntilExit()
        completion?(true); await controller.waitForAction()
        #expect(controller.terminal && controller.refreshTimer == nil)
        #expect(controller.buttons.allSatisfy { !$0.isEnabled } && untouched.process.isRunning)
        controller.close()
    }
    @Test func failedReadsRetainSnapshotAndTerminalIdentityChangeStopsRefresh() async throws {
        _ = NSApplication.shared
        let child = try ProcessChild(), id = try child.identity
        let source = DetailFixture(try XRGProcessAccess.read(id))
        let controller = XRGProcessDetailController(identity: id, reader: { _ in try source.next() })
        controller.present(); await controller.waitForRefresh()
        let first = controller.body.string
        controller.refresh(); await controller.waitForRefresh()
        #expect(controller.body.string == first && controller.status.stringValue.contains("retained"))
        #expect(controller.buttons.allSatisfy { !$0.isEnabled } && !controller.terminal)
        controller.refresh(); await controller.waitForRefresh()
        #expect(controller.terminal && controller.refreshTimer == nil && controller.body.string == first)
        controller.refresh(); await controller.waitForRefresh()
        #expect(source.count == 3); controller.close()
    }
    @Test func actualConfirmationDefaultsToCancellationAndCanBeCaptured() async throws {
        _ = NSApplication.shared
        let child = try ProcessChild(), id = try child.identity
        let controller = XRGProcessDetailController(identity: id)
        controller.present(); await controller.waitForRefresh()
        controller.request(.pause); await controller.waitForAction()
        let window = try #require(controller.window), sheet = try #require(window.attachedSheet)
        if let path = ProcessInfo.processInfo.environment["XRG_PROCESS_QA_CAPTURE"] {
            #if arch(x86_64)
            let architecture = "x86_64"
            #else
            let architecture = "arm64"
            #endif
            let root = URL(fileURLWithPath: path, isDirectory: true).appendingPathComponent(architecture)
            try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
            for (name, view) in [("live-details", window.contentView), ("confirmation", sheet.contentView)] {
                let view = try #require(view)
                view.layoutSubtreeIfNeeded(); view.displayIfNeeded()
                let rep = try #require(view.bitmapImageRepForCachingDisplay(in: view.bounds))
                view.cacheDisplay(in: view.bounds, to: rep)
                try #require(rep.representation(using: .png, properties: [:])).write(to: root.appendingPathComponent(name + ".png"))
            }
        }
        #expect(sheet.defaultButtonCell?.title == "Cancel")
        window.endSheet(sheet, returnCode: .alertFirstButtonReturn); sheet.orderOut(nil)
        for _ in 0..<20 where !controller.status.stringValue.contains("cancelled") { await Task.yield() }
        try child.state(stopped: false)
        #expect(controller.status.stringValue.contains("cancelled") && child.process.isRunning)
        controller.close()
    }
    @Test func closingDuringCollectionRejectsTheLateResult() async throws {
        _ = NSApplication.shared
        let child = try ProcessChild(), id = try child.identity
        let source = DetailGate(try XRGProcessAccess.read(id))
        let controller = XRGProcessDetailController(identity: id, reader: { _ in try source.read() })
        controller.present()
        let waiting = Task { await controller.waitForRefresh() }
        let started = await Task.detached { source.waitUntilEntered() }.value
        #expect(started)
        controller.close(); source.release.signal(); await waiting.value
        #expect(controller.snapshot == nil && controller.refreshTimer == nil)
    }
    @Test func aReaderReturningAnotherProcessNeverChangesTheDetailTarget() async throws {
        _ = NSApplication.shared
        let first = try ProcessChild(), second = try ProcessChild()
        let expected = try first.identity, replacement = try XRGProcessAccess.read(second.identity)
        let controller = XRGProcessDetailController(identity: expected, reader: { _ in replacement })
        controller.present(); await controller.waitForRefresh()
        #expect(controller.terminal && controller.snapshot == nil && controller.buttons.allSatisfy { !$0.isEnabled })
        #expect(controller.status.stringValue.contains("identity")); controller.close()
    }
    @Test func detailsAreRetainedByIdentityAndCloseWithTheirInspector() async throws {
        _ = NSApplication.shared
        let child = try ProcessChild()
        let live = try #require(XRGProcessMiner.readProcesses()?.first { $0.pid == child.process.processIdentifier })
        let miner = XRGProcessMiner(source: { [live] }); await miner.refresh()
        let domain = "XRG.process-detail.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: domain)); defer { defaults.removePersistentDomain(forName: domain) }
        let inspector = XRGProcessInspector(miner: miner, defaults: defaults, sort: .pid)
        inspector.present(); inspector.table.selectRowIndexes([0], byExtendingSelection: false)
        inspector.inspectSelected(nil)
        let detail = try #require(inspector.details.values.first); await detail.waitForRefresh()
        inspector.inspectSelected(nil); #expect(inspector.details.count == 1)
        inspector.close(); #expect(inspector.details.isEmpty && detail.refreshTimer == nil)
    }
}

private final class DetailFixture: @unchecked Sendable {
    private let lock = NSLock()
    private let snapshot: XRGProcessLiveSnapshot
    private var index = 0
    var count: Int { lock.lock(); defer { lock.unlock() }; return index }
    init(_ snapshot: XRGProcessLiveSnapshot) { self.snapshot = snapshot }
    func next() throws -> XRGProcessLiveSnapshot {
        lock.lock(); defer { lock.unlock() }; index += 1
        switch index {
        case 1: return snapshot
        case 2: throw XRGProcessAccessError.unavailable("Fixture read failed.")
        default: throw XRGProcessAccessError.changed
        }
    }
}

private final class DetailGate: @unchecked Sendable {
    let entered = DispatchSemaphore(value: 0), release = DispatchSemaphore(value: 0)
    private let snapshot: XRGProcessLiveSnapshot
    init(_ snapshot: XRGProcessLiveSnapshot) { self.snapshot = snapshot }
    func waitUntilEntered() -> Bool { entered.wait(timeout: .now() + 2) == .success }
    func read() throws -> XRGProcessLiveSnapshot {
        entered.signal()
        guard release.wait(timeout: .now() + 3) == .success else { throw XRGProcessAccessError.unavailable("Fixture gate timed out") }
        return snapshot
    }
}
