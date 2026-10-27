// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Stephen de la Vega.

/// Toolkit-neutral preset data. Color order is part of the shared C ABI:
/// background, graph background, three graph fills, border, text.
public enum XRGBuiltinTheme: String, CaseIterable, Sendable {
    case classic, midnight, ocean, dusk, paper, phosphor

    public var name: String { rawValue.prefix(1).uppercased() + rawValue.dropFirst() }

    /// macOS retains the original device-RGB color space for Classic.
    public var usesDeviceRGB: Bool { self == .classic }

    public var rgba: [[Double]] {
        if self == .classic {
            return [[0.05, 0.02, 0.08, 0.9], [0.08, 0.04, 0.12, 0.9],
                    [1, 0, 0.6, 1], [0, 1, 1, 1], [0.2, 1, 0.2, 1],
                    [0.5, 0, 0.5, 0.4], [0.6, 1, 1, 1]]
        }
        let palette: [UInt32] = switch self {
        case .midnight: [0x0B1220, 0x111B2B, 0x1D4ED8, 0x0F766E, 0x6D28D9, 0x334155, 0xE5EEFC]
        case .ocean: [0x071D2B, 0x0B2A3C, 0x0369A1, 0x0F766E, 0x7C3AED, 0x23506B, 0xE0F2FE]
        case .dusk: [0x21182F, 0x2D223D, 0x6B3F80, 0x2F6269, 0x804B39, 0x584668, 0xFFF1E6]
        case .paper: [0xF4F5F7, 0xFFFFFF, 0x93C5FD, 0x99F6E4, 0xFDE68A, 0xCBD5E1, 0x152536]
        case .phosphor: [0x07110B, 0x091A10, 0x166534, 0x3F6212, 0x065F46, 0x245437, 0xBBF7D0]
        case .classic: []
        }
        return palette.map { [Double(($0 >> 16) & 255) / 255,
                              Double(($0 >> 8) & 255) / 255, Double($0 & 255) / 255, 1] }
    }
}
