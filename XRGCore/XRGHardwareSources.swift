// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Stephen de la Vega.
import AppKit

/// Platform-local source identities stay out of portable palette/presentation files.
struct XRGHardwareSources: Codable, Equatable {
    var version = 1
    /// Nil preserves automatic selection. Custom slots keep their palette positions.
    var sources: [String?]?
    init(sources: [String?]? = nil) { self.sources = sources }
    private enum CodingKeys: String, CodingKey { case version, sources }
    private struct Key: CodingKey {
        let stringValue: String
        init?(stringValue: String) { self.stringValue = stringValue }
        var intValue: Int? { nil }
        init?(intValue: Int) { nil }
    }
    init(from decoder: any Decoder) throws {
        let keys = try decoder.container(keyedBy: Key.self)
        guard keys.allKeys.allSatisfy({ CodingKeys(stringValue: $0.stringValue) != nil }) else { throw Self.invalid }
        let container = try decoder.container(keyedBy: CodingKeys.self)
        version = try container.decode(Int.self, forKey: .version)
        sources = try container.decodeIfPresent([String?].self, forKey: .sources)
        try validate()
    }
    init(data: Data) throws {
        guard data.count <= 8192 else { throw Self.invalid }
        self = try JSONDecoder().decode(Self.self, from: data)
    }
    func validate() throws {
        guard version == 1 else { throw Self.invalid }
        if let sources {
            let ids = sources.compactMap { $0 }
            guard sources.count == 3, !ids.isEmpty, Set(ids).count == ids.count,
                  ids.allSatisfy({ !$0.isEmpty && $0.utf8.count <= 1024 && !$0.unicodeScalars.contains(where: CharacterSet.controlCharacters.contains) }) else { throw Self.invalid }
        }
    }
    func encoded() throws -> Data { try validate(); return try JSONEncoder().encode(self) }
    static var invalid: NSError { NSError(domain: "XRGHardwareSources", code: 1, userInfo: [NSLocalizedDescriptionKey:
        "Choose at least one source in three curve slots, with each source used once. Source IDs must be nonempty and bounded; saved options must use version 1."] ) }
}

/// A draft over the latest cached inventory. Apply alone changes the graph/defaults.
@MainActor final class XRGHardwareSourcesEditor: NSObject {
    let view = NSView(frame: NSRect(x: 0, y: 0, width: 550, height: 220))
    let mode = NSPopUpButton(frame: .zero, pullsDown: false)
    private(set) var pickers: [NSPopUpButton] = []
    let notice = NSTextField(wrappingLabelWithString: "")
    var validityChanged: ((Bool) -> Void)?
    init(selection: XRGHardwareSources, readings: [XRGHardwareReading], suggested: [String?], name: String) {
        super.init()
        let modeLabel = NSTextField(labelWithString: "Selection")
        modeLabel.frame = NSRect(x: 0, y: 190, width: 78, height: 20); view.addSubview(modeLabel)
        mode.frame = NSRect(x: 88, y: 185, width: 450, height: 28)
        mode.addItems(withTitles: ["Automatic (up to three)", "Choose curve sources"])
        mode.selectItem(at: selection.sources == nil ? 0 : 1)
        mode.setAccessibilityLabel("\(name) source selection mode"); mode.target = self; mode.action = #selector(changed(_:)); view.addSubview(mode)
        let seeds = selection.sources ?? suggested
        for index in 0..<3 {
            let label = NSTextField(labelWithString: "Curve \(index + 1)")
            label.frame = NSRect(x: 0, y: 153 - index * 32, width: 78, height: 20); view.addSubview(label)
            let picker = NSPopUpButton(frame: NSRect(x: 88, y: 148 - index * 32, width: 450, height: 28), pullsDown: false)
            picker.addItem(withTitle: "None")
            for reading in readings {
                picker.addItem(withTitle: "\(reading.name) [\(Self.shortID(reading.id))]")
                picker.lastItem?.representedObject = reading.id; picker.lastItem?.toolTip = reading.id
            }
            if let id = seeds.indices.contains(index) ? seeds[index] : nil {
                if let found = picker.itemArray.firstIndex(where: { $0.representedObject as? String == id }) { picker.selectItem(at: found) }
                else {
                    picker.addItem(withTitle: "Unavailable: \(Self.shortID(id))"); picker.lastItem?.representedObject = id
                    picker.lastItem?.toolTip = id; picker.selectItem(at: picker.numberOfItems - 1)
                }
            }
            picker.setAccessibilityLabel("\(name) curve \(index + 1) source"); picker.target = self; picker.action = #selector(changed(_:))
            pickers.append(picker); view.addSubview(picker)
        }
        notice.frame = NSRect(x: 0, y: 4, width: 538, height: 65); notice.font = .systemFont(ofSize: 11)
        view.addSubview(notice); changed(nil)
    }
    private static func shortID(_ id: String) -> String { id.count > 72 ? String(id.prefix(69)) + "…" : id }
    var draft: XRGHardwareSources {
        XRGHardwareSources(sources: mode.indexOfSelectedItem == 0 ? nil : pickers.map { $0.selectedItem?.representedObject as? String })
    }
    @objc func changed(_ sender: Any?) {
        let custom = mode.indexOfSelectedItem == 1
        pickers.forEach { $0.isEnabled = custom }
        do {
            try draft.validate()
            notice.stringValue = "Automatic uses up to three available sources. Custom choices stay pinned; unavailable sources show gaps. None leaves a curve slot empty. Colors follow curve numbers."
            validityChanged?(true)
        } catch {
            notice.stringValue = "Choose at least one source. Each source can appear only once; None leaves an unused curve slot."
            validityChanged?(false)
        }
    }
}
