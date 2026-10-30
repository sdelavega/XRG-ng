// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Stephen de la Vega.
import AppKit
import Testing
@testable import XRGCore

@Suite(.serialized) @MainActor
struct XRGHardwareSourcesTests {
    private func fixture(_ test: (UserDefaults, XRGSettings) async throws -> Void) async throws {
        _ = NSApplication.shared
        let domain = "XRG.hardware-sources.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: domain)); defer { defaults.removePersistentDomain(forName: domain) }
        try await test(defaults, XRGSettings(defaults: defaults))
    }
    @Test func strictSettingsAcceptHolesAndRejectMalformedSelections() throws {
        let valid = XRGHardwareSources(sources: ["fan:A", nil, "fan:B"])
        #expect(try XRGHardwareSources(data: valid.encoded()) == valid)
        #expect(try XRGHardwareSources(data: XRGHardwareSources().encoded()).sources == nil)
        for text in ["{}", "[]", "{\"version\":2}", "{\"version\":1,\"unexpected\":0}",
                     "{\"version\":1,\"sources\":[1,null,null]}"] {
            #expect(throws: (any Error).self) { try XRGHardwareSources(data: Data(text.utf8)) }
        }
        for ids: [String?] in [[], ["a"], [nil,nil,nil], ["a","a",nil], ["",nil,nil], ["a\n",nil,nil], [String(repeating: "é",count:513),nil,nil]] {
            #expect(throws: (any Error).self) { try XRGHardwareSources(sources: ids).encoded() }
        }
        #expect(throws: (any Error).self) { try XRGHardwareSources(data: Data(repeating: 32,count:8193)) }
    }
    @Test func defaultsRemainAutomaticAndInvalidBytesSurviveUntilExplicitApply() async throws {
        try await fixture { defaults, settings in
            let key = XRGHardwareGraphView.Kind.fans.sourcesKey
            let original = Data("{\"version\":9}".utf8); defaults.set(original, forKey:key)
            let view = XRGHardwareGraphView(kind:.fans,frame:NSRect(x:0,y:0,width:160,height:90),settings:settings,defaults:defaults,source:{.success([])})
            view.graphUpdate(nil)
            #expect(view.sourceSelection.sources == nil && view.sourceSelectionError != nil)
            #expect(defaults.data(forKey:key) == original && view.detailText.contains("invalid"))
            #expect(throws:(any Error).self) { try view.applySources(XRGHardwareSources(sources:["a","a",nil])) }
            #expect(defaults.data(forKey:key) == original)
            try view.applySources(XRGHardwareSources(sources:["missing",nil,nil]))
            #expect(view.sourceSelectionError == nil && view.labels.rightLabel.fullAccessibilityText?.contains("n/a") == true)
            let reopen = XRGHardwareGraphView(kind:.fans,frame:view.frame,settings:settings,defaults:defaults,source:{.success([])})
            #expect(reopen.sourceSelection.sources == ["missing",nil,nil])
            let vram = XRGHardwareGraphView(kind:.vram,frame:view.frame,settings:settings,defaults:defaults,source:{.success([])})
            #expect(vram.sourceSelection.sources == nil && defaults.object(forKey: XRGHardwareGraphView.Kind.vram.sourcesKey) == nil)
        }
    }
    @Test func pinnedMissingSourcesKeepGapsAndNeverSelectAnotherDevice() async throws {
        try await fixture { defaults, settings in
            var values = [XRGHardwareReading(id:"a",name:"Front",value:0),XRGHardwareReading(id:"b",name:"Rear",value:1200)]
            let view = XRGHardwareGraphView(kind:.fans,frame:NSRect(x:0,y:0,width:160,height:90),settings:settings,defaults:defaults,source:{.success(values)})
            try view.applySources(XRGHardwareSources(sources:["a",nil,"b"]))
            view.graphUpdate(nil)
            #expect(view.curve("a").last == 0 && view.labels.leftLabel.fullAccessibilityText?.contains("3: Rear") == true)
            values = [XRGHardwareReading(id:"b",name:"Rear",value:1300),XRGHardwareReading(id:"c",name:"New",value:2000)]
            view.graphUpdate(nil)
            #expect(view.curve("a").suffix(2) == [0,XRGGraphRenderer.missingValue])
            #expect(view.curve("c").isEmpty && view.sourceSelection.sources == ["a",nil,"b"])
            #expect(view.labels.leftLabel.fullAccessibilityText?.contains("Unavailable: a") == true)
            #expect(view.curve("b").suffix(2) == [1200,1300])
            values.append(XRGHardwareReading(id:"a",name:"Front",value:900)); view.graphUpdate(nil)
            #expect(view.curve("a").suffix(3) == [0,XRGGraphRenderer.missingValue,900])
            values[2] = XRGHardwareReading(id:"a",name:"Replacement",value:950); view.graphUpdate(nil)
            #expect(view.curve("a").dropLast().allSatisfy {$0 == XRGGraphRenderer.missingValue})
            let saved = defaults.data(forKey:XRGHardwareGraphView.Kind.fans.sourcesKey)
            view.clearData(nil)
            #expect(view.curve("a").allSatisfy {$0 == XRGGraphRenderer.missingValue})
            #expect(defaults.data(forKey:XRGHardwareGraphView.Kind.fans.sourcesKey) == saved)
        }
    }
    @Test func selectionApplyUsesCachedReadingsAndDoesNotAdvanceUnaffectedHistories() async throws {
        try await fixture { defaults, settings in
            var calls=0
            let view = XRGHardwareGraphView(kind:.fans,frame:NSRect(x:0,y:0,width:160,height:90),settings:settings,defaults:defaults,source:{calls+=1;return .success([XRGHardwareReading(id:"a",name:"A",value:100),XRGHardwareReading(id:"b",name:"B",value:200)])})
            view.graphUpdate(nil); let before=view.curve("b")
            try view.applySources(XRGHardwareSources(sources:[nil,nil,"b"]))
            #expect(calls == 1 && view.curve("b") == before && view.curve("a").isEmpty)
            #expect(view.labels.leftLabel.fullAccessibilityText?.contains("3: B") == true)
            try view.applySources(XRGHardwareSources())
            #expect(view.curve("b") == before && calls == 1)
            #expect(view.curve("a").last == 100)
        }
    }
    @Test func memoryAxesFollowOnlySelectedAdaptersAndFailureRemainsAGap() async throws {
        try await fixture { defaults, settings in
            var fail=false
            var values=[XRGHardwareReading(id:"a",name:"Pool",value:50,capacity:100),XRGHardwareReading(id:"b",name:"Allocations",value:200)]
            let view = XRGHardwareGraphView(kind:.vram,frame:NSRect(x:0,y:0,width:160,height:90),settings:settings,defaults:defaults,source:{ fail ? .failure(NSError(domain:"fixture",code:1,userInfo:[NSLocalizedDescriptionKey:"Read failed"])) : .success(values) })
            view.graphUpdate(nil); #expect(!view.percentage)
            try view.applySources(XRGHardwareSources(sources:["a",nil,nil])); #expect(view.percentage && view.curve("a").last == 50 && view.curve("b").isEmpty)
            fail=true; view.graphUpdate(nil)
            #expect(view.percentage && view.curve("a").suffix(2) == [50,XRGGraphRenderer.missingValue])
            #expect(view.labels.rightLabel.fullAccessibilityText?.contains("n/a") == true && view.status == "Read failed")
            fail=false; values=[XRGHardwareReading(id:"a",name:"Pool",value:60,capacity:100)];view.graphUpdate(nil)
            #expect(view.curve("a").suffix(3) == [50,XRGGraphRenderer.missingValue,60])
            values=[XRGHardwareReading(id:"a",name:"Pool",value:20)]; view.graphUpdate(nil)
            #expect(!view.percentage && view.curve("a").last == 20 && view.curve("a").dropLast().allSatisfy {$0 == XRGGraphRenderer.missingValue})
        }
    }
    @Test func gpuLocationIdentitySurvivesRegistryRenumberingWithoutChangingLegacyIDs() throws {
        let location="IOService:/fixture/GPU@1/accelerator"
        let stats:[String:Any] = ["PerformanceStatistics":["In use system memory":1024]]
        let first=try #require(XRGGPUSample.parse(id:17,pci:[:],accelerator:stats,memorySourceID:location).memoryReading)
        let changed=try #require(XRGGPUSample.parse(id:29,pci:[:],accelerator:stats,memorySourceID:location).memoryReading)
        #expect(first.id == location && changed.id == location && first.name != changed.name)
        #expect(XRGGPUSample.parse(id:29,pci:[:],accelerator:stats,memorySourceID:location).id == 29)
        #expect(XRGGPUSample.parse(id:29,pci:[:],accelerator:stats,memorySourceID:"").memoryReading?.id == "29")
        let selection=XRGHardwareSources(sources:[location,nil,nil])
        #expect(try XRGHardwareSources(data: selection.encoded()) == selection)
    }
    @Test func editorRetainsUnavailableChoicesAndValidatesDuplicateDrafts() throws {
        _ = NSApplication.shared
        let editor=XRGHardwareSourcesEditor(selection:XRGHardwareSources(sources:["missing",nil,"a"]),readings:[XRGHardwareReading(id:"a",name:"A",value:0)],suggested:[nil,nil,nil],name:"Fans")
        #expect(editor.draft.sources == ["missing",nil,"a"])
        #expect(editor.pickers[0].titleOfSelectedItem == "Unavailable: missing")
        var valid=true;editor.validityChanged={valid=$0}
        editor.pickers[1].selectItem(at:1);editor.changed(nil); #expect(!valid)
        editor.mode.selectItem(at:0);editor.changed(nil)
        #expect(valid && editor.draft.sources == nil && editor.pickers.allSatisfy {!$0.isEnabled})
        editor.mode.selectItem(at:1);editor.changed(nil);#expect(!valid && editor.draft.sources == ["missing","a","a"])
    }
    @Test func nativeSheetApplyCancelAndWindowCloseRespectDrafts() async throws {
        try await fixture { defaults, settings in
            let window=NSWindow(contentRect:NSRect(x:0,y:0,width:550,height:280),styleMask:[.titled,.closable],backing:.buffered,defer:false)
            window.isReleasedWhenClosed=false
            var inventory=[XRGHardwareReading(id:"a",name:"A",value:0),XRGHardwareReading(id:"b",name:"B",value:1200)]
            let view=XRGHardwareGraphView(kind:.fans,frame:NSRect(x:0,y:0,width:540,height:90),settings:settings,defaults:defaults,source:{.success(inventory)})
            window.contentView?.addSubview(view); window.makeKeyAndOrderFront(nil);view.graphUpdate(nil)
            defer {window.close()}
            view.chooseSources(nil)
            let editor=try #require(view.sourcesEditor)
            editor.mode.selectItem(at:1);editor.pickers[0].selectItem(at:2);editor.pickers[1].selectItem(at:0);editor.pickers[2].selectItem(at:0);editor.changed(nil)
            // Discovery may change while the draft is open. Apply must not use
            // the editor's old reading or silently select the remaining source.
            inventory.removeLast(); view.graphUpdate(nil)
            let sheet=try #require(window.attachedSheet);#expect(sheet.defaultButtonCell?.title == "Cancel")
            window.endSheet(sheet,returnCode:.alertSecondButtonReturn);sheet.orderOut(nil)
            for _ in 0..<30 where view.sourcesEditor != nil {await Task.yield()}
            #expect(view.sourceSelection.sources == ["b",nil,nil] && view.status.contains("unavailable"))
            let saved=defaults.data(forKey:XRGHardwareGraphView.Kind.fans.sourcesKey)
            view.chooseSources(nil)
            let cancelled=try #require(view.sourcesEditor);cancelled.mode.selectItem(at:0);cancelled.changed(nil)
            let cancelSheet=try #require(window.attachedSheet)
            window.endSheet(cancelSheet,returnCode:.alertFirstButtonReturn);cancelSheet.orderOut(nil)
            for _ in 0..<30 where view.sourcesEditor != nil {await Task.yield()}
            #expect(defaults.data(forKey:XRGHardwareGraphView.Kind.fans.sourcesKey) == saved && view.sourceSelection.sources == ["b",nil,nil])
            view.chooseSources(nil);window.close()
            for _ in 0..<30 where view.sourcesEditor != nil {await Task.yield()}
            #expect(view.sourcesEditor == nil && defaults.data(forKey:XRGHardwareGraphView.Kind.fans.sourcesKey) == saved)
        }
    }
}
