// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Stephen de la Vega.
import AppKit

enum XRGGraphID: String, CaseIterable, Codable, Sendable {
    case cpu, gpu, tpu, memory, battery, temperature, network, disk, weather, stock, ai
    var name: String {
        switch self {
        case .cpu: "CPU"
        case .gpu: "GPU"
        case .tpu: "NPU"
        case .memory: "Memory"
        case .battery: "Battery"
        case .temperature: "Temperature"
        case .network: "Network"
        case .disk: "Disk"
        case .weather: "Weather"
        case .stock: "Stock"
        case .ai: "AI Tokens"
        }
    }
    var title: String { self == .tpu ? "Neural Engine" : name }
    var visibilityKey: String {
        switch self {
        case .network: "showNetworkGraph"
        case .ai: "showAITokenGraph"
        default: "show\(name)Graph"
        }
    }
    init?(name: String?) {
        guard let value = Self.allCases.first(where: { $0.name == name }) else { return nil }
        self = value
    }
}

enum XRGCurveStyle: String, CaseIterable, Codable, Sendable {
    case solid, pixel, dot, hollow
    var title: String { rawValue.capitalized }
}

struct XRGGraphOverride: Codable, Equatable {
    var height: Int?
    var curve: XRGCurveStyle?
    /// Display effects are independent of curve fills. Nil inherits the global effect.
    var effect: Int?
    /// Background, then series 1/2/3; nil inherits the global palette.
    var colors: [[Double]?] = [nil, nil, nil, nil]
    var isEmpty: Bool { height == nil && curve == nil && effect == nil && colors.count == 4 && colors.allSatisfy { $0 == nil } }
    func validate() throws {
        guard height.map({ (64...240).contains($0) }) ?? true,
              effect.map({ (0...3).contains($0) }) ?? true,
              colors.count == 4, colors.compactMap({ $0 }).allSatisfy({
                  $0.count == 4 && $0.allSatisfy { $0.isFinite && (0...1).contains($0) }
              }) else { throw XRGGraphPreferences.invalid }
    }
}

struct XRGGraphPreferences: Codable, Equatable {
    static let key = "graphPresentationV1"
    var version = 1
    /// Nil preserves existing module priorities, including older layout behavior.
    var order: [XRGGraphID]?
    var overrides: [String: XRGGraphOverride] = [:]
    var orderedIDs: [XRGGraphID] { order ?? XRGGraphID.allCases }
    subscript(_ id: XRGGraphID) -> XRGGraphOverride {
        get { overrides[id.rawValue] ?? XRGGraphOverride() }
        set { overrides[id.rawValue] = newValue.isEmpty ? nil : newValue }
    }
    init() {}
    init(data: Data) throws {
        guard data.count <= 32 * 1024 else { throw Self.invalid }
        self = try JSONDecoder().decode(Self.self, from: data)
        try validate()
    }
    func validate() throws {
        guard version == 1, order.map({ $0.count == XRGGraphID.allCases.count && Set($0) == Set(XRGGraphID.allCases) }) ?? true,
              overrides.keys.allSatisfy({ XRGGraphID(rawValue: $0) != nil }) else { throw Self.invalid }
        for value in overrides.values { try value.validate() }
    }
    func encoded() throws -> Data { try validate(); return try JSONEncoder().encode(self) }
    static var invalid: NSError { NSError(domain: "XRGGraphPreferences", code: 1, userInfo: [NSLocalizedDescriptionKey:
        "Use unique graph ordering, heights between 64 and 240, and finite RGBA colors between 0 and 1."] ) }
}

extension XRGSettings {
    @nonobjc func customGraphColor(_ id: XRGGraphID, component: Int) -> NSColor? {
        guard (0..<4).contains(component), let rgba = graphPreferences[id].colors[component] else { return nil }
        return NSColor(srgbRed: rgba[0], green: rgba[1], blue: rgba[2], alpha: rgba[3])
    }
    @nonobjc func graphColor(_ id: XRGGraphID, component: Int) -> NSColor {
        customGraphColor(id, component: component) ?? [graphBGColor, graphFG1Color, graphFG2Color, graphFG3Color][min(3, max(0, component))]
    }
    @nonobjc func curveStyle(_ id: XRGGraphID) -> XRGCurveStyle? { graphPreferences[id].curve }
    @nonobjc func graphEffect(_ id: XRGGraphID?) -> Int { id.map { graphPreferences[$0].effect ?? graphStyle } ?? graphStyle }
}
