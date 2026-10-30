// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Stephen de la Vega.
import AppKit

/// Native-only choices never enter portable theme/presentation files. CPU and GPU
/// use separate preference keys so changing one cannot overwrite the other.
struct XRGMonitorSource: Codable, Equatable {
    var version = 1
    var source: String?
    init(source: String? = nil) { self.source = source }
    func validate() throws {
        guard version == 1 else { throw Self.invalid }
        if let source {
            guard !source.isEmpty, source.utf8.count <= 1024,
                  !source.unicodeScalars.contains(where: CharacterSet.controlCharacters.contains) else { throw Self.invalid }
        }
    }
    func validateCPU() throws {
        try validate()
        if let source {
            guard let index = Int(source), (0...1_048_575).contains(index), String(index) == source else { throw Self.invalid }
        }
    }
    init(data: Data) throws {
        guard data.count <= 8192,
              let object = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              Set(object.keys).isSubset(of: ["version", "source"]) else { throw Self.invalid }
        self = try JSONDecoder().decode(Self.self, from: data)
        try validate()
    }
    static func load(_ defaults: UserDefaults, key: String) throws -> Self {
        guard let object = defaults.object(forKey: key) else { return Self() }
        guard let data = object as? Data else { throw Self.invalid }
        return try Self(data: data)
    }
    func encoded() throws -> Data { try validate(); return try JSONEncoder().encode(self) }
    static var invalid: NSError { NSError(domain: "XRGMonitorSource", code: 1, userInfo: [NSLocalizedDescriptionKey:
        "Saved source options are invalid. Using the default without changing the saved value; choose a source explicitly to replace it."]) }
}

enum XRGGPUPlotMode: String, CaseIterable {
    case memoryAndActivity, utilization
    var title: String { self == .memoryAndActivity ? "Memory + Activity" : "Utilization Only" }
}

@MainActor enum XRGMonitorDetails {
    static func present(title: String, text: String, in window: NSWindow) {
        let alert = alert(title: title, text: text)
        alert.beginSheetModal(for: window)
        // AppKit sizes the document while attaching the accessory. Reset the
        // clip origin after that layout instead of opening halfway down the text.
        DispatchQueue.main.async {
            guard let scroll = alert.accessoryView as? NSScrollView else { return }
            if let content = scroll.documentView as? NSTextView, let container = content.textContainer {
                content.layoutManager?.ensureLayout(for: container)
            }
            scroll.contentView.scroll(to: .zero)
            scroll.reflectScrolledClipView(scroll.contentView)
        }
    }
    static func alert(title: String, text: String) -> NSAlert {
        let alert = NSAlert(); alert.messageText = title
        alert.informativeText = "Read-only snapshot of the current selection and its accounting."
        let scroll = NSScrollView(frame: NSRect(x: 0, y: 0, width: 480, height: 260))
        scroll.hasVerticalScroller = true; scroll.borderType = .bezelBorder
        let content = NSTextView(frame: scroll.bounds)
        content.isEditable = false; content.isSelectable = true; content.isRichText = false
        content.font = .systemFont(ofSize: 12); content.string = text
        content.setSelectedRange(NSRange(location: 0, length: 0))
        content.isVerticallyResizable = true; content.isHorizontallyResizable = false
        content.textContainer?.widthTracksTextView = true
        content.setAccessibilityLabel(title)
        scroll.documentView = content; alert.accessoryView = scroll
        alert.addButton(withTitle: "Close")
        return alert
    }
}
