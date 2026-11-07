// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Stephen de la Vega.
//
// Renders the Aether7b settings window's every section in both light and
// dark to PNGs under a directory the caller names, for the user's visual
// review (spec §9: snapshots do not gate CI). Built against XRGCore:
//
//   xcrun swiftc -swift-version 5 Tools/settings-snapshots-macos.swift \
//     -F <products dir> -framework XRGCore -framework Sparkle -framework AppKit \
//     -o "$TMPDIR/xrg-0.2.3-task-9/settings-snapshots" \
//   DYLD_FRAMEWORK_PATH=<products dir> "$TMPDIR/xrg-0.2.3-task-9/settings-snapshots" \
//     --output .superpowers/sdd/2026-11-06-xrg-ng-0.2.3-unified-settings/task-9-snapshots
//
// Compiles itself nothing: with --products omitted it runs the same
// build-for-testing the smoke harness uses into a scratch directory.

import AppKit
import Foundation
import XRGCore

@MainActor
enum SettingsSnapshots {
    static func fail(_ message: String) -> Never {
        FileHandle.standardError.write(Data(("settings-snapshots-macos: " + message + "\n").utf8))
        exit(1)
    }

    static func parseArguments() throws -> (output: URL, products: URL?) {
        var output: URL?
        var products: URL?
        var iterator = Array(CommandLine.arguments.dropFirst()).makeIterator()
        while let flag = iterator.next() {
            switch flag {
            case "--output": output = iterator.next().map { URL(fileURLWithPath: $0, isDirectory: true) }
            case "--products": products = iterator.next().map { URL(fileURLWithPath: $0, isDirectory: true) }
            default: fail("unexpected argument \(flag); use --output DIR [--products DIR]")
            }
        }
        guard let output else { fail("--output DIR is required") }
        return (output, products)
    }

    /// Build the XRGTests products (XRGCore.framework) into a scratch dir.
    static func buildProducts(into scratch: URL) throws -> URL {
        let root = URL(fileURLWithPath: #filePath, isDirectory: false).deletingLastPathComponent().deletingLastPathComponent()
        let derived = scratch.appendingPathComponent("dd", isDirectory: true)
        let task = Process()
        task.executableURL = URL(fileURLWithPath: "/usr/bin/xcodebuild")
        task.arguments = ["-project", root.appendingPathComponent("XRG-ng.xcodeproj").path, "-scheme", "XRGTests",
                          "-configuration", "Debug", "-destination", "platform=macOS",
                          "-derivedDataPath", derived.path,
                          "CODE_SIGNING_ALLOWED=NO", "ENABLE_TESTABILITY=YES", "build-for-testing"]
        task.currentDirectoryURL = root
        try task.run()
        task.waitUntilExit()
        guard task.terminationStatus == 0 else { fail("xcodebuild build-for-testing failed") }
        return derived.appendingPathComponent("Build/Products/Debug", isDirectory: true)
    }

    static func main() throws {
        let (output, provided) = try parseArguments()
        let scratch = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
            .appendingPathComponent("xrg-0.2.3-task-9", isDirectory: true)
            .appendingPathComponent("settings-snapshots-scratch", isDirectory: true)
        try FileManager.default.createDirectory(at: scratch, withIntermediateDirectories: true)
        // Build (or accept) the products the caller compiles this tool against.
        _ = try provided ?? buildProducts(into: scratch)
        try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)

        _ = NSApplication.shared
        // A disposable store in a temp directory: the real
        // com.sdelavega.xrg domain and the real ~/Library/Application
        // Support/XRG-ng/settings.json are never read or written.
        let domain = "com.sdelavega.XRG-ng.Snapshots." + UUID().uuidString
        guard let defaults = UserDefaults(suiteName: domain) else { fail("no defaults suite") }
        defer { defaults.removePersistentDomain(forName: domain) }
        let root = scratch.appendingPathComponent(domain, isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let catalog = try XRGSettingsCatalog.load()
        let store = XRGSettingsStore(fileURL: root.appendingPathComponent("settings.json"),
                                      defaults: defaults, catalog: catalog)
        let controller = XRGSettingsWindowController(store: store, catalog: catalog,
                                                     sources: XRGHardwareSettingsSourceProvider())
        guard let window = controller.window else { fail("no settings window") }
        window.setFrame(NSRect(x: 0, y: 0, width: 760, height: 560), display: false)

        for (name, appearance) in [("light", NSAppearance(named: .aqua)), ("dark", NSAppearance(named: .darkAqua))] {
            guard let appearance else { fail("no \(name) appearance") }
            window.appearance = appearance
            for section in XRGSettingsCatalog.sections {
                controller.show(section: section)
                controller.refresh()
                guard let content = window.contentView else { continue }
                let pngName = "\(section)-\(name).png"
                guard let bitmap = content.bitmapImageRepForCachingDisplay(in: content.bounds) else {
                    fail("no bitmap for \(pngName)")
                }
                content.cacheDisplay(in: content.bounds, to: bitmap)
                guard let png = bitmap.representation(using: .png, properties: [:]) else {
                    fail("no PNG bytes for \(pngName)")
                }
                try png.write(to: output.appendingPathComponent(pngName))
                print("wrote \(pngName)")
            }
        }
        print("PASS: \(XRGSettingsCatalog.sections.count * 2) settings snapshots")
    }
}

@main
enum SettingsSnapshotsMain {
    @MainActor static func main() {
        do { try SettingsSnapshots.main() }
        catch { SettingsSnapshots.fail("\(error)") }
    }
}