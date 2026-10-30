// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Stephen de la Vega.
import AppKit

@MainActor final class XRGProcessDetailController: NSWindowController, NSWindowDelegate {
    typealias Reader = @Sendable (XRGProcessIdentity) throws -> XRGProcessLiveSnapshot
    typealias Review = (String, String, @escaping (Bool) -> Void) -> Void
    let identity: XRGProcessIdentity
    private let reader: Reader
    private let review: Review?
    private let onClose: () -> Void
    private var generation: UInt64 = 0
    private var active = false
    private var busy = false
    private var healthy = false
    private(set) var terminal = false
    private(set) var snapshot: XRGProcessLiveSnapshot?
    private(set) var cpu: Double?
    private(set) var refreshTimer: Timer?
    private var refreshTask: Task<Void, Never>?
    private var actionTask: Task<Void, Never>?
    let body = NSTextView()
    let status = NSTextField(wrappingLabelWithString: "Waiting for process details…")
    private(set) var buttons: [NSButton] = []
    private let refreshButton = NSButton(title: "Refresh", target: nil, action: nil)

    init(identity: XRGProcessIdentity, reader: @escaping Reader = XRGProcessAccess.read,
         review: Review? = nil, onClose: @escaping () -> Void = {}) {
        self.identity = identity; self.reader = reader; self.review = review; self.onClose = onClose
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 700, height: 540),
            styleMask: [.titled, .closable, .miniaturizable, .resizable], backing: .buffered, defer: false)
        super.init(window: window)
        window.title = "XRG-ng · \(identity.name) · PID \(identity.pid)"
        window.minSize = NSSize(width: 700, height: 440); window.isReleasedWhenClosed = false; window.delegate = self; window.center()
        guard let content = window.contentView else { return }
        let explanation = NSTextField(wrappingLabelWithString: "Live details · 5-second refresh · follows this process instance only")
        explanation.frame = NSRect(x: 16, y: 497, width: 540, height: 26)
        explanation.autoresizingMask = [.width, .minYMargin]; content.addSubview(explanation)
        refreshButton.frame = NSRect(x: 574, y: 494, width: 110, height: 30)
        refreshButton.autoresizingMask = [.minXMargin, .minYMargin]
        refreshButton.target = self; refreshButton.action = #selector(refreshClicked(_:)); content.addSubview(refreshButton)
        let scroll = NSScrollView(frame: NSRect(x: 16, y: 107, width: 668, height: 379))
        scroll.autoresizingMask = [.width, .height]; scroll.hasVerticalScroller = true; scroll.borderType = .bezelBorder
        body.frame = NSRect(origin: .zero, size: scroll.contentSize); body.isEditable = false; body.isSelectable = true
        body.font = .monospacedSystemFont(ofSize: 12, weight: .regular)
        body.autoresizingMask = [.width]; body.isVerticallyResizable = true
        body.textContainer?.widthTracksTextView = true; body.textContainerInset = NSSize(width: 8, height: 8)
        body.setAccessibilityLabel("Live process details")
        scroll.documentView = body; content.addSubview(scroll)
        status.frame = NSRect(x: 16, y: 51, width: 668, height: 48); status.autoresizingMask = [.width]; content.addSubview(status)
        for (index, action) in XRGProcessAction.allCases.enumerated() {
            let title = ["Terminate…", "Force Kill…", "Pause…", "Resume…"][index]
            let button = NSButton(title: title, target: self, action: #selector(actionClicked(_:)))
            button.frame = NSRect(x: 16 + index * 168, y: 12, width: 160, height: 30)
            button.tag = action.rawValue; button.setAccessibilityLabel(action.title); content.addSubview(button); buttons.append(button)
        }
        updateControls()
    }
    required init?(coder: NSCoder) { fatalError("Programmatic window") }
    func present() {
        active = true; showWindow(nil); window?.makeKeyAndOrderFront(nil); refresh()
        refreshTimer?.invalidate()
        if !terminal {
            refreshTimer = Timer.scheduledTimer(withTimeInterval: 5, repeats: true) { [weak self] timer in
                let alive = MainActor.assumeIsolated {
                    guard let self, self.active else { return false }
                    self.refresh(); return true
                }
                if !alive { timer.invalidate() }
            }
        }
    }
    func windowWillClose(_ notification: Notification) {
        active = false; generation &+= 1
        refreshTimer?.invalidate(); refreshTimer = nil
        refreshTask?.cancel(); refreshTask = nil; actionTask?.cancel(); actionTask = nil
        if let window, let sheet = window.attachedSheet { window.endSheet(sheet, returnCode: .cancel); sheet.orderOut(nil) }
        onClose()
    }
    @objc private func refreshClicked(_ sender: Any?) { refresh() }
    func refresh() {
        guard active, !terminal, refreshTask == nil else { return }
        let reader = reader, identity = identity, generation = generation
        refreshTask = Task { [weak self] in
            let result = await Task.detached(priority: .utility) { () -> Result<XRGProcessLiveSnapshot, XRGProcessAccessError> in
                do { return .success(try reader(identity)) }
                catch let error as XRGProcessAccessError { return .failure(error) }
                catch { return .failure(.unavailable(error.localizedDescription)) }
            }.value
            guard !Task.isCancelled, let self, self.active, self.generation == generation else { return }
            switch result {
            case let .success(value):
                // Injected/test readers must obey the same instance contract.
                if value.identity != identity { self.fail(.changed) }
                else {
                    self.cpu = value.intervalCPU(since: self.snapshot); self.snapshot = value; self.healthy = true
                    self.terminal = value.exited; self.body.string = Self.text(value, cpu: self.cpu)
                    self.status.stringValue = value.exited ? "Process exited. Last snapshot retained." : "Updated: \(value.sampledAt.formatted(date: .omitted, time: .standard)). Actions require confirmation; macOS permissions apply."
                }
            case let .failure(error): self.fail(error)
            }
            if self.terminal { self.refreshTimer?.invalidate(); self.refreshTimer = nil }
            self.refreshTask = nil; self.updateControls()
        }
    }
    func waitForRefresh() async { await refreshTask?.value }
    func waitForAction() async { await actionTask?.value }
    private func fail(_ error: XRGProcessAccessError) {
        healthy = false; terminal = error.terminal
        if terminal { refreshTimer?.invalidate(); refreshTimer = nil }
        status.stringValue = error.localizedDescription + (snapshot == nil ? "" : " Last successful details retained.")
        if snapshot == nil { body.string = status.stringValue }
    }
    private func updateControls() {
        for (button, action) in zip(buttons, XRGProcessAction.allCases) {
            button.isEnabled = active && healthy && !terminal && !busy && snapshot.map(action.enabled) == true
        }
        refreshButton.isEnabled = active && !terminal && !busy
    }
    @objc private func actionClicked(_ sender: NSButton) {
        if let action = XRGProcessAction(rawValue: sender.tag) { request(action) }
    }
    func request(_ action: XRGProcessAction) {
        guard active, healthy, !terminal, !busy, let snapshot, action.enabled(snapshot) else { return }
        busy = true; updateControls()
        let generation = generation, identity = identity
        actionTask = Task { [weak self] in
            let result = await Task.detached(priority: .utility) { () -> Result<XRGProcessTarget, XRGProcessAccessError> in
                do { return .success(try XRGProcessTarget.prepare(identity)) }
                catch let error as XRGProcessAccessError { return .failure(error) }
                catch { return .failure(.unavailable(error.localizedDescription)) }
            }.value
            guard !Task.isCancelled, let self, self.active, self.generation == generation else { return }
            self.actionTask = nil
            switch result {
            case let .failure(error):
                self.fail(error); self.busy = false; self.updateControls()
            case let .success(target):
                let value = target.snapshot
                let text = "\(identity.name) · PID \(identity.pid) · UID \(identity.uid)\nStarted: \(Self.startDate(identity).formatted())\n\n\(action.explanation)\n\nThis acts on this process instance only. A delivered signal does not guarantee that the requested state has been reached."
                let completion: (Bool) -> Void = { [weak self] accepted in
                    guard let self, self.active, self.generation == generation else { return }
                    if accepted { self.deliver(target, action, generation: generation) }
                    else { self.busy = false; self.status.stringValue = "Action cancelled. No signal was sent."; self.updateControls() }
                }
                guard action.enabled(value) else { self.busy = false; self.status.stringValue = "Process state changed; refresh and review again."; self.updateControls(); return }
                if let review = self.review { review(action.title, text, completion) }
                else if let window = self.window {
                    let alert = NSAlert(); alert.messageText = action.title + "?"; alert.informativeText = text
                    alert.alertStyle = action == .forceKill || action == .terminate ? .warning : .informational
                    alert.addButton(withTitle: "Cancel").keyEquivalent = "\r"
                    alert.addButton(withTitle: action.title).keyEquivalent = ""
                    alert.beginSheetModal(for: window) { response in completion(response == .alertSecondButtonReturn) }
                }
            }
        }
    }
    private func deliver(_ target: XRGProcessTarget, _ action: XRGProcessAction, generation: UInt64) {
        actionTask = Task { [weak self] in
            let result = await Task.detached(priority: .utility) { () -> Result<Void, XRGProcessAccessError> in
                do { try target.send(action); return .success(()) }
                catch let error as XRGProcessAccessError { return .failure(error) }
                catch { return .failure(.unavailable(error.localizedDescription)) }
            }.value
            guard !Task.isCancelled, let self, self.active, self.generation == generation else { return }
            self.actionTask = nil; self.busy = false
            switch result {
            case let .failure(error): self.fail(error)
            case .success:
                self.status.stringValue = "\(action.title) delivered. Waiting for a new observation…"
                self.refresh()
            }
            self.updateControls()
        }
    }
    static func startDate(_ identity: XRGProcessIdentity) -> Date {
        Date(timeIntervalSince1970: Double(identity.startSeconds) + Double(identity.startMicroseconds) / 1_000_000)
    }
    static func text(_ value: XRGProcessLiveSnapshot, cpu: Double?) -> String {
        func bytes(_ count: UInt64?) -> String { count.map { String(format: "%.1f MiB", Double($0) / 1_048_576) } ?? "unavailable" }
        let cpuText = cpu.map { String(format: "%.1f%%", $0) } ?? "unavailable (needs two observations)"
        let time = value.cpuNanoseconds.map { String(format: "%.3f s", Double($0) / 1_000_000_000) } ?? "unavailable"
        return """
        \(value.identity.name) · PID \(value.identity.pid)
        Parent PID: \(value.parent)
        Effective UID: \(value.identity.uid) · Real UID: \(value.realUID)
        Started: \(startDate(value.identity).formatted())
        State (BSD): \(value.state)
        CPU interval: \(cpuText) (100% = one core)
        CPU lifetime (user + system): \(time)
        RSS: \(bytes(value.resident))
        Virtual size: \(bytes(value.virtual))
        Threads: \(value.threads.map(String.init) ?? "unavailable")
        Nice: \(value.nice) · Priority: \(value.priority.map(String.init) ?? "unavailable")
        Sample: \(value.sampledAt.formatted())

        Live details use native process counters. Table CPU uses ps's recent decaying average; the two can differ. RSS may include shared pages. Virtual size is not physical memory usage. Missing task counters are unavailable, not zero. Arguments and environments are not collected.
        """
    }
}
