// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Stephen de la Vega.
// Run on macOS: swift Tools/generate-srgb-xtf-fixture.swift OUTPUT_DIRECTORY
// Keep the identity-only fixture in Git; the full system ICC profile stays local.
import AppKit

let directory = URL(fileURLWithPath: CommandLine.arguments[1], isDirectory: true)
try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
let names = ["background", "graphBG", "graphFG1", "graphFG2", "graphFG3", "border", "text"]
let colors: [[Double]] = [
    [0, 0, 0, 0.75], [1, 1, 1, 0.4], [0.2, 0.4, 0.8, 0.5],
    [1, 0, 0, 0.6], [0, 1, 0, 0.7], [0, 0, 1, 0.8], [0.5, 0.5, 0.5, 0.9],
]
var full: [String: Any] = [:]
var identityOnly: [String: Any] = [:]
for (name, rgba) in zip(names, colors) {
    let color = NSColor(srgbRed: rgba[0], green: rgba[1], blue: rgba[2], alpha: 0.123)
    let data = try NSKeyedArchiver.archivedData(withRootObject: color, requiringSecureCoding: true)
    var archive = try PropertyListSerialization.propertyList(from: data, format: nil) as! [String: Any]
    var objects = archive["$objects"] as! [Any]
    // Locate the space by its fields, without depending on object-table ordering.
    let index = objects.firstIndex { ($0 as? [String: Any])?["NSID"] as? Int == 7 }!
    var space = objects[index] as! [String: Any]
    space.removeValue(forKey: "NSICC")
    objects[index] = space
    // Omit the unreferenced vendor profile rather than redistributing its bytes.
    for i in objects.indices where objects[i] is Data { objects[i] = "$null" }
    archive["$objects"] = objects
    let stripped = try PropertyListSerialization.data(fromPropertyList: archive, format: .binary, options: 0)
    let restored = try NSKeyedUnarchiver.unarchivedObject(ofClass: NSColor.self, from: stripped)!
        .usingColorSpace(.sRGB)!
    precondition(zip([restored.redComponent, restored.greenComponent, restored.blueComponent], rgba).allSatisfy {
        abs($0 - $1) < 0.000001
    })
    full["\(name)Color"] = data
    identityOnly["\(name)Color"] = stripped
    full["\(name)Transparency"] = rgba[3]
    identityOnly["\(name)Transparency"] = rgba[3]
}
for (name, value) in [("ModernSRGB-full.xtf", full), ("ModernSRGB.xtf", identityOnly)] {
    try PropertyListSerialization.data(fromPropertyList: value, format: .xml, options: 0)
        .write(to: directory.appendingPathComponent(name))
}
print("Verified AppKit sRGB identity-only round trips; wrote fixtures to \(directory.path)")
