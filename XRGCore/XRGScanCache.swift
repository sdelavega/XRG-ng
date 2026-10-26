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

@objc(XRGScanTotals)
@objcMembers
public final class XRGScanTotals: NSObject, Sendable {
    public let tokens: UInt64
    public let input: UInt64
    public let output: UInt64
    public let cost: Double
    public init(tokens: UInt64, input: UInt64, output: UInt64, cost: Double) {
        self.tokens = tokens
        self.input = input
        self.output = output
        self.cost = cost
    }
}

/// Owns one provider's schedule, per-file cache, and published snapshot.
/// Parsing runs outside the lock; only the current generation may publish.
@objc(XRGScanCache)
public final class XRGScanCache: NSObject, @unchecked Sendable {
    private struct Stamp: Equatable, Sendable {
        let modified: Date
        let size: UInt64
        let inode: UInt64
    }
    private struct Entry: Sendable {
        let stamp: Stamp
        let totals: XRGScanTotals
    }
    private let lock = NSLock()
    private let interval: TimeInterval
    private var entries: [String: Entry] = [:]
    private var value = XRGScanTotals(tokens: 0, input: 0, output: 0, cost: 0)
    private var published = false
    private var generation = UUID()
    private var task: Task<Void, Never>?
    private var lastStart: TimeInterval?
    private var source: String?
    private var sourceLayout = -1

    public override convenience init() { self.init(interval: 30) }
    public init(interval: TimeInterval) {
        self.interval = interval.isFinite ? max(0, interval) : 30
        super.init()
    }
    deinit { task?.cancel() }

    @objc public var snapshot: XRGScanTotals { lock.withLock { value } }
    @objc public var completedSnapshot: XRGScanTotals? { lock.withLock { published ? value : nil } }
    @objc public var hasSnapshot: Bool { lock.withLock { published } }
    @objc public var isScanning: Bool { lock.withLock { task != nil } }

    @objc public func reset() { lock.withLock { clear() } }

    private func clear() {
        generation = UUID()
        task?.cancel()
        task = nil
        lastStart = nil
        published = false
        entries = [:]
        value = XRGScanTotals(tokens: 0, input: 0, output: 0, cost: 0)
    }

    /// Layout: 0 = Claude project/files, 1 = Codex year/month/day/files,
    /// 2 = Gemini hash/chats/files. The callback preserves caller pricing policy.
    @objc(refreshRoot:layout:parse:)
    public func refresh(root: String, layout: Int,
                        parse: @escaping @Sendable (String) -> XRGScanTotals) {
        lock.withLock {
            if source != root || sourceLayout != layout {
                clear()
                source = root
                sourceLayout = layout
            }
            let now = ProcessInfo.processInfo.systemUptime
            guard task == nil, lastStart.map({ now - $0 >= interval }) ?? true else { return }
            lastStart = now
            let id = generation
            let previous = entries
            task = Task.detached(priority: .utility) { [weak self] in
                let result = try? Self.scan(root: root, layout: layout, previous: previous, parse: parse)
                self?.finish(id: id, result: result)
            }
        }
    }

    private func finish(id: UUID, result: ([String: Entry], XRGScanTotals)?) {
        lock.withLock {
            guard generation == id else { return }
            if let result {
                published = true
                entries = result.0
                value = result.1
            }
            task = nil
        }
    }

    private static func stamp(_ path: String) throws -> Stamp {
        let attributes = try FileManager.default.attributesOfItem(atPath: path)
        guard attributes[.type] as? FileAttributeType == .typeRegular,
              let date = attributes[.modificationDate] as? Date,
              let size = attributes[.size] as? NSNumber,
              let inode = attributes[.systemFileNumber] as? NSNumber else { throw CocoaError(.fileReadUnknown) }
        return Stamp(modified: date, size: size.uint64Value, inode: inode.uint64Value)
    }

    private static func files(root: String, layout: Int) throws -> [String] {
        let manager = FileManager.default
        if !manager.fileExists(atPath: root) {
            // A provider that is not installed contributes an empty snapshot.
            do { _ = try manager.attributesOfItem(atPath: root) }
            catch let error as CocoaError where error.code == .fileReadNoSuchFile || error.code == .fileNoSuchFile { return [] }
        }
        func children(_ path: String) throws -> [String] {
            try manager.contentsOfDirectory(atPath: path).sorted().map {
                (path as NSString).appendingPathComponent($0)
            }
        }
        func directories(_ path: String) throws -> [String] {
            try children(path).filter {
                try manager.attributesOfItem(atPath: $0)[.type] as? FileAttributeType == .typeDirectory
            }
        }
        var parents: [String] = []
        switch layout {
        case 0: parents = try directories(root)
        case 1:
            for year in try directories(root) {
                for month in try directories(year) { parents += try directories(month) }
            }
        case 2:
            for directory in try directories(root) {
                let chats = (directory as NSString).appendingPathComponent("chats")
                var isDirectory: ObjCBool = false
                if manager.fileExists(atPath: chats, isDirectory: &isDirectory), isDirectory.boolValue {
                    parents.append(chats)
                }
            }
        default: throw CocoaError(.fileReadUnknown)
        }
        var paths: [String] = []
        for parent in parents {
            try Task.checkCancellation()
            for path in try children(parent) {
                let name = (path as NSString).lastPathComponent
                let accepted = layout == 0 ? name.hasSuffix(".jsonl")
                    : layout == 1 ? name.hasPrefix("rollout-") && name.hasSuffix(".jsonl")
                    : name.hasPrefix("session-") && (name.hasSuffix(".json") || name.hasSuffix(".jsonl"))
                if accepted { paths.append(path) }
            }
        }
        return paths
    }

    private static func scan(root: String, layout: Int, previous: [String: Entry],
                             parse: @Sendable (String) -> XRGScanTotals) throws -> ([String: Entry], XRGScanTotals) {
        var next: [String: Entry] = [:]
        for path in try files(root: root, layout: layout) {
            try Task.checkCancellation()
            let before = try stamp(path)
            if let old = previous[path], old.stamp == before {
                next[path] = old
            } else {
                guard FileManager.default.isReadableFile(atPath: path) else { throw CocoaError(.fileReadNoPermission) }
                let totals = parse(path)
                try Task.checkCancellation()
                let after = try stamp(path)
                // Retry concurrently changing files on the next scan; do not
                // cache a partially read sample under a newer modification date.
                if before == after { next[path] = Entry(stamp: after, totals: totals) }
                else { next[path] = previous[path] }
            }
        }
        var tokens: UInt64 = 0
        var input: UInt64 = 0
        var output: UInt64 = 0
        var cost = 0.0
        for path in next.keys.sorted() {
            guard let entry = next[path] else { continue }
            let (newTokens, overflowTokens) = tokens.addingReportingOverflow(entry.totals.tokens)
            let (newInput, overflowInput) = input.addingReportingOverflow(entry.totals.input)
            let (newOutput, overflowOutput) = output.addingReportingOverflow(entry.totals.output)
            let newCost = cost + entry.totals.cost
            guard !overflowTokens, !overflowInput, !overflowOutput,
                  entry.totals.cost >= 0, newCost.isFinite else { throw CocoaError(.fileReadCorruptFile) }
            tokens = newTokens
            input = newInput
            output = newOutput
            cost = newCost
        }
        return (next, XRGScanTotals(tokens: tokens, input: input, output: output, cost: cost))
    }
}
