// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Stephen de la Vega.
import AppKit

struct XRGProcessOptions: Codable, Equatable {
    enum Sort: String, Codable, CaseIterable { case cpu, memory, name, pid }
    var sort: Sort = .cpu
    var search = ""
    var user = ""
    var limit = 100
    func ranked(_ records: [XRGProcessRecord]) -> [XRGProcessRecord] {
        let query = search.trimmingCharacters(in: .whitespacesAndNewlines)
        let owner = user.trimmingCharacters(in: .whitespacesAndNewlines)
        return Array(records.filter {
            (owner.isEmpty || $0.user == owner) && (query.isEmpty || $0.command.localizedCaseInsensitiveContains(query) || String($0.pid).contains(query))
        }.sorted { a, b in
            switch sort {
            case .cpu: if a.cpu != b.cpu { return a.cpu > b.cpu }
            case .memory: if a.resident != b.resident { return a.resident > b.resident }
            case .name: if a.command != b.command { return a.command.localizedStandardCompare(b.command) == .orderedAscending }
            case .pid: break
            }
            return a.pid < b.pid
        }.prefix(max(1, min(200, limit))))
    }
    var valid: Bool { search.count <= 128 && user.count <= 128 && [25, 50, 100, 200].contains(limit) }
}

/// Uses only the existing name-only ps snapshot. Details are deliberately frozen:
/// a reused numeric PID never redirects a detail window to another process.
@MainActor final class XRGProcessInspector: NSWindowController, NSWindowDelegate, NSTableViewDataSource, NSTableViewDelegate, NSSearchFieldDelegate {
    static let optionsKey = "processInspectorV1"
    private let miner: XRGProcessMiner
    private let defaults: UserDefaults
    private(set) var options = XRGProcessOptions()
    private(set) var rows: [XRGProcessRecord] = []
    private(set) var refreshTimer: Timer?
    private var refreshTask: Task<Void, Never>?
    let search = NSSearchField()
    let user = NSTextField(string: "")
    let sort = NSPopUpButton(frame: .zero, pullsDown: false)
    let limit = NSPopUpButton(frame: .zero, pullsDown: false)
    let table = NSTableView()
    let status = NSTextField(wrappingLabelWithString: "Waiting for a process sample…")
    private let detail = NSButton(title: "Inspect Selected…", target: nil, action: nil)

    init(miner: XRGProcessMiner, defaults: UserDefaults, sort initialSort: XRGProcessOptions.Sort) {
        self.miner = miner; self.defaults = defaults
        if let data = defaults.data(forKey: Self.optionsKey), data.count <= 4096,
           let saved = try? JSONDecoder().decode(XRGProcessOptions.self, from: data), saved.valid { options = saved }
        options.sort = initialSort
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 800, height: 540),
                              styleMask: [.titled, .closable, .miniaturizable, .resizable], backing: .buffered, defer: false)
        super.init(window: window)
        window.title = "XRG-ng · Processes"; window.minSize = NSSize(width: 720, height: 420)
        window.isReleasedWhenClosed = false; window.delegate = self; window.center()
        build(); reload()
    }
    required init?(coder: NSCoder) { fatalError("Programmatic window") }
    private func build() {
        guard let content = window?.contentView else { return }
        func label(_ text: String, _ x: CGFloat, _ width: CGFloat) {
            let label = NSTextField(labelWithString: text); label.frame = NSRect(x: x, y: 495, width: width, height: 20)
            label.autoresizingMask = [.minYMargin]; content.addSubview(label)
        }
        label("Search", 16, 48); search.frame = NSRect(x: 70, y: 492, width: 195, height: 26)
        label("User", 278, 38); user.frame = NSRect(x: 318, y: 492, width: 105, height: 26)
        user.placeholderString = "All users"; user.setAccessibilityLabel("Exact process user")
        search.setAccessibilityLabel("Search process name or PID")
        sort.addItems(withTitles: ["CPU %", "Memory", "Name", "PID"])
        sort.frame = NSRect(x: 440, y: 492, width: 135, height: 28); sort.setAccessibilityLabel("Sort processes")
        limit.addItems(withTitles: ["25 rows", "50 rows", "100 rows", "200 rows"])
        limit.frame = NSRect(x: 585, y: 492, width: 120, height: 28); limit.setAccessibilityLabel("Process row limit")
        for control in [search as NSControl, user, sort, limit] {
            control.autoresizingMask = [.minYMargin]; control.target = self; control.action = #selector(optionsChanged(_:)); content.addSubview(control)
        }
        search.delegate = self; user.delegate = self
        search.stringValue = options.search; user.stringValue = options.user
        sort.selectItem(at: XRGProcessOptions.Sort.allCases.firstIndex(of: options.sort) ?? 0)
        limit.selectItem(at: [25, 50, 100, 200].firstIndex(of: options.limit) ?? 2)
        let explanation = NSTextField(wrappingLabelWithString: "CPU: ps recent decaying average; 100% is one core. RSS may include shared pages and is not summed into system memory. Names only; arguments and environments are not read.")
        explanation.frame = NSRect(x: 16, y: 439, width: 768, height: 44); explanation.autoresizingMask = [.width, .minYMargin]; content.addSubview(explanation)
        for (key, title, width) in [("pid", "PID", 65.0), ("command", "Process", 230), ("cpu", "CPU %", 75), ("rss", "RSS", 110), ("user", "User", 130)] {
            let column = NSTableColumn(identifier: .init(key)); column.title = title; column.width = width; table.addTableColumn(column)
        }
        table.dataSource = self; table.delegate = self; table.rowHeight = 25; table.usesAlternatingRowBackgroundColors = true
        table.setAccessibilityLabel("Readable processes"); table.target = self; table.doubleAction = #selector(inspectSelected(_:))
        let scroll = NSScrollView(frame: NSRect(x: 16, y: 104, width: 768, height: 326))
        scroll.autoresizingMask = [.width, .height]; scroll.hasVerticalScroller = true; scroll.hasHorizontalScroller = true; scroll.borderType = .bezelBorder; scroll.documentView = table; content.addSubview(scroll)
        status.frame = NSRect(x: 16, y: 49, width: 768, height: 46); status.autoresizingMask = [.width]; content.addSubview(status)
        detail.frame = NSRect(x: 16, y: 12, width: 160, height: 30); detail.target = self; detail.action = #selector(inspectSelected(_:)); content.addSubview(detail)
        let refresh = NSButton(title: "Refresh", target: self, action: #selector(refresh(_:)))
        refresh.frame = NSRect(x: 184, y: 12, width: 100, height: 30); content.addSubview(refresh)
    }
    func present() {
        showWindow(nil); window?.makeKeyAndOrderFront(nil)
        refresh(nil); refreshTimer?.invalidate()
        refreshTimer = Timer.scheduledTimer(withTimeInterval: 5, repeats: true) { [weak self] timer in
            let alive = MainActor.assumeIsolated {
                guard let self else { return false }
                self.refresh(nil); return true
            }
            if !alive { timer.invalidate() }
        }
    }
    func windowWillClose(_ notification: Notification) {
        refreshTimer?.invalidate(); refreshTimer = nil; refreshTask?.cancel(); refreshTask = nil
    }
    @objc func refresh(_ sender: Any?) {
        guard refreshTask == nil else { return }
        refreshTask = Task { [weak self, miner] in
            await miner.refresh()
            guard !Task.isCancelled, let self else { return }
            self.reload(); self.refreshTask = nil
        }
    }
    func reload() {
        let selected = rows.indices.contains(table.selectedRow) ? rows[table.selectedRow].pid : nil
        rows = options.ranked(miner.records); table.reloadData()
        if let selected, let index = rows.firstIndex(where: { $0.pid == selected }) { table.selectRowIndexes(IndexSet(integer: index), byExtendingSelection: false) }
        else { table.deselectAll(nil) }
        detail.isEnabled = table.selectedRow >= 0
        if let date = miner.sampledAt {
            status.stringValue = "\(rows.count) shown / \(miner.records.count) readable · Sample: \(date.formatted(date: .omitted, time: .standard))" + (miner.refreshFailed ? " · Refresh failed; showing the last successful snapshot." : " · Updates every 5 seconds.")
        } else { status.stringValue = miner.refreshFailed ? "Process collection unavailable. Refresh to retry." : "Waiting for a process sample…" }
    }
    @objc func optionsChanged(_ sender: Any?) {
        options.search = String(search.stringValue.prefix(128)); options.user = String(user.stringValue.prefix(128))
        search.stringValue = options.search; user.stringValue = options.user
        options.sort = XRGProcessOptions.Sort.allCases[max(0, sort.indexOfSelectedItem)]
        options.limit = [25, 50, 100, 200][max(0, limit.indexOfSelectedItem)]
        if let data = try? JSONEncoder().encode(options) { defaults.set(data, forKey: Self.optionsKey) }
        reload()
    }
    func controlTextDidChange(_ notification: Notification) { optionsChanged(nil) }
    func numberOfRows(in tableView: NSTableView) -> Int { rows.count }
    func tableViewSelectionDidChange(_ notification: Notification) { detail.isEnabled = table.selectedRow >= 0 }
    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        guard rows.indices.contains(row) else { return nil }; let record = rows[row]
        let text: String
        switch tableColumn?.identifier.rawValue {
        case "pid": text = String(record.pid)
        case "command": text = record.command
        case "cpu": text = String(format: "%.1f", record.cpu)
        case "rss": text = Self.memory(record.resident)
        case "user": text = record.user
        default: return nil
        }
        return NSTextField(labelWithString: text)
    }
    static func memory(_ kib: UInt64) -> String { String(format: "%.1f MiB", Double(kib) / 1024) }
    // ps may return "-" for swap counts; the legacy record maps that to zero,
    // so omit that field rather than presenting an unavailable count as measured.
    static func detailText(_ record: XRGProcessRecord, sampledAt: Date?) -> String {
        """
        \(record.command) · PID \(record.pid)
        User: \(record.user)
        CPU: \(String(format: "%.1f", record.cpu))% (ps recent decaying average, one core = 100%)
        RSS: \(memory(record.resident))
        Virtual size: \(memory(record.virtual))
        Sample: \(sampledAt?.formatted() ?? "unavailable")

        Frozen, read-only snapshot. This window does not follow a numeric PID after the sample; the process may exit or its PID may be reused. RSS includes shared pages; virtual size is not physical memory usage. Arguments and environments are not collected.
        """
    }
    @objc func inspectSelected(_ sender: Any?) {
        guard rows.indices.contains(table.selectedRow), let window else { return }
        let alert = NSAlert(); alert.messageText = "Process snapshot"
        alert.informativeText = Self.detailText(rows[table.selectedRow], sampledAt: miner.sampledAt)
        alert.addButton(withTitle: "Done"); alert.beginSheetModal(for: window)
    }
}
