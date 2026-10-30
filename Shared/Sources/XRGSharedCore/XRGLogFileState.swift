// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Stephen de la Vega.

/// Identity and monotonic state from one complete log observation. A replacement,
/// truncation or counter rollback cannot donate historical tokens to a new delta.
public struct XRGLogFileState: Codable, Equatable, Sendable {
    public let device: UInt64
    public let inode: UInt64
    public let bytes: UInt64
    public let tokens: UInt64
    public init(device: UInt64, inode: UInt64, bytes: UInt64, tokens: UInt64) {
        self.device = device; self.inode = inode; self.bytes = bytes; self.tokens = tokens
    }
    public func continues(_ previous: Self) -> Bool {
        device == previous.device && inode == previous.inode
            && bytes >= previous.bytes && tokens >= previous.tokens
    }
    public static func inventoryContinues(_ previous: [String: Self], _ next: [String: Self]) -> Bool {
        previous.count == next.count && next.allSatisfy { name, state in
            previous[name].map { state.continues($0) } ?? false
        }
    }
}
