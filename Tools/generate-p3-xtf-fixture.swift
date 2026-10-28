// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Stephen de la Vega.
// Run on macOS: swift Tools/generate-p3-xtf-fixture.swift OUTPUT_DIRECTORY
// Apple profile bytes stay local. Checked-in fixtures embed a CC0 P3 profile.
import AppKit

let directory = URL(fileURLWithPath: CommandLine.arguments[1], isDirectory: true)
try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
let names = ["background", "graphBG", "graphFG1", "graphFG2", "graphFG3", "border", "text"]
let colors: [[Double]] = [
    [0, 0, 0, 0.9], [0.03, 0.04, 0.02, 0.4], [0.2, 0.4, 0.8, 0.75],
    [1, 0, 0, 0.8], [0, 1, 0, 0.6], [0, 0, 1, 0.5], [1, 1, 1, 1],
]
func srgb(_ color: NSColor) -> [Double] {
    let value = color.usingColorSpace(.sRGB)!
    return [value.redComponent, value.greenComponent, value.blueComponent].map { Double($0).clamped }
}
extension Double {
    var clamped: Double { min(1, max(0, self)) }
}
var full: [String: Any] = [:]
var normalized: [String: Any] = [:]
var expected: [[Double]] = []
let profile = try Data(contentsOf: URL(fileURLWithPath: "xrg-linux/rust/tests/fixtures/DisplayP3-v4.icc"))
for (name, rgba) in zip(names, colors) {
    let color = NSColor(displayP3Red: rgba[0], green: rgba[1], blue: rgba[2], alpha: 0.123)
    let data = try NSKeyedArchiver.archivedData(withRootObject: color, requiringSecureCoding: true)
    var archive = try PropertyListSerialization.propertyList(from: data, format: nil) as! [String: Any]
    var objects = archive["$objects"] as! [Any]
    precondition(objects.contains { ($0 as? [String: Any])?["NSSpaceID"] as? Int == 12 })
    // Replace the system profile while retaining AppKit's archive structure.
    // Its space ID alone is insufficient: AppKit falls back to generic RGB.
    for i in objects.indices where objects[i] is Data { objects[i] = profile }
    archive["$objects"] = objects
    let fixtureData = try PropertyListSerialization.data(fromPropertyList: archive, format: .binary, options: 0)
    let restored = try NSKeyedUnarchiver.unarchivedObject(ofClass: NSColor.self, from: fixtureData)!
    precondition(zip([restored.redComponent, restored.greenComponent, restored.blueComponent], rgba).allSatisfy {
        abs($0 - $1) < 0.000001
    })
    precondition(abs(restored.alphaComponent - 0.123) < 0.000001)
    full["\(name)Color"] = data
    normalized["\(name)Color"] = fixtureData
    full["\(name)Transparency"] = rgba[3]
    normalized["\(name)Transparency"] = rgba[3]
    expected.append(srgb(restored) + [rgba[3]])
}
for (name, value) in [("DisplayP3-full.xtf", full), ("DisplayP3.xtf", normalized)] {
    try PropertyListSerialization.data(fromPropertyList: value, format: .xml, options: 0)
        .write(to: directory.appendingPathComponent(name))
}
try JSONSerialization.data(withJSONObject: expected, options: [.prettyPrinted, .sortedKeys])
    .write(to: directory.appendingPathComponent("DisplayP3-expected.json"))
var cases: [[String: [Double]]] = []
for r in [0.0, 0.003, 0.04, 0.2, 0.5, 1] {
    for g in [0.0, 0.003, 0.04, 0.2, 0.5, 1] {
        for b in [0.0, 0.003, 0.04, 0.2, 0.5, 1] {
            cases.append(["p3": [r, g, b], "srgb": srgb(NSColor(displayP3Red: r, green: g, blue: b, alpha: 1))])
        }
    }
}
try JSONSerialization.data(withJSONObject: cases, options: [.prettyPrinted, .sortedKeys])
    .write(to: directory.appendingPathComponent("DisplayP3-oracle.json"))
print("Verified AppKit P3 component round trips with the CC0 profile; wrote palette and \(cases.count) sRGB oracle cases to \(directory.path)")
