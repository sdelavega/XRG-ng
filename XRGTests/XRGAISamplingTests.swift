// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Stephen de la Vega.
import Foundation
import Testing
@testable import XRGCore

private actor SamplingEndpoint {
    var calls=0
    func metrics() async throws -> Data {
        calls += 1
        try await Task.sleep(for:.milliseconds(20))
        return Data("claude_code_input_tokens_total \(100+(calls-1)*20)\n".utf8)
    }
    func models() async throws -> Data { calls += 1;return Data(#"{"models":[{"name":"fixture"}]}"#.utf8) }
}
private actor SamplingGate {
    private var next=0
    private var pending:[Int:CheckedContinuation<Data,Never>]=[:]
    func request() async -> Data {
        let id=next;next+=1
        return await withCheckedContinuation { pending[id]=$0 }
    }
    func count()->Int { next }
    func resolve(_ id:Int,_ text:String) { pending.removeValue(forKey:id)?.resume(returning:Data(text.utf8)) }
    func finish() { for (_,continuation) in pending {continuation.resume(returning:Data())};pending=[:] }
}

@Suite(.serialized) @MainActor struct XRGAISamplingTests {
    private func file(_ root:URL,_ total:Int) throws -> URL {
        let path=root.appendingPathComponent(".codex/sessions/2026/10/29/rollout-sample.jsonl")
        try FileManager.default.createDirectory(at:path.deletingLastPathComponent(),withIntermediateDirectories:true)
        try Data(record(total).utf8).write(to:path)
        return path
    }
    private func record(_ total:Int)->String {
        "{\"type\":\"event_msg\",\"payload\":{\"type\":\"token_count\",\"info\":{\"total_token_usage\":{\"total_tokens\":\(total)}}}}\n"
    }
    private func until(_ condition:()->Bool) async throws {
        for _ in 0..<600 { if condition() { return };try await Task.sleep(for:.milliseconds(5)) }
        Issue.record("Collection did not finish within the fixture deadline")
    }
    @Test func completedScansAndResponsesPublishOncePerCycleAndBypassLegacyScanThrottle() async throws {
        let root=FileManager.default.temporaryDirectory.appendingPathComponent("xrg-ai-cadence-"+UUID().uuidString)
        defer { try? FileManager.default.removeItem(at:root) }
        let path=try file(root,100)
        let metrics=SamplingEndpoint(),tags=SamplingEndpoint(),running=SamplingEndpoint()
        var time:Double=0
        let miner=XRGAITokenMiner(home:root.path,clock:{time},
            otelRequest:XRGURL(transport:{_ in try await metrics.metrics()}),
            tagsRequest:XRGURL(transport:{_ in try await tags.models()}),
            runningRequest:XRGURL(transport:{_ in try await running.models()}),scanInterval:3600)
        defer { miner.reset() }
        miner.setDataSize(120);miner.setAccountingEnabled(true)
        var events:[String:UInt64]=[:],callbacks=0
        miner.usageEventHandler={ events[$0,default:0] += $1.usage.total }
        let index=miner.codexTokenData().currentIndex
        let source: any XRGAITokenViewSource = miner
        source.requestLatestTokenInfo { callbacks+=1 }
        source.requestLatestTokenInfo { callbacks+=1 }
        try await until { callbacks == 2 }
        #expect(miner.totalCodexTokens == 100 && miner.totalClaudeTokens == 100 && events.isEmpty)
        #expect(miner.codexTokenData().currentIndex == (index+1)%120)
        let firstCalls = (await metrics.calls, await tags.calls, await running.calls)
        #expect(firstCalls == (1,1,1))
        time=5
        let handle=try FileHandle(forWritingTo:path);try handle.seekToEnd();try handle.write(contentsOf:Data(record(150).utf8));try handle.close()
        miner.requestLatestTokenInfo { callbacks+=1 }
        try await until { callbacks == 3 }
        #expect(miner.totalCodexTokens == 150 && miner.totalClaudeTokens == 120)
        #expect(miner.codexTokenRate() == 10 && miner.claudeTokenRate() == 4)
        #expect(events == ["Claude":20,"Codex":50])
        let secondCalls = (await metrics.calls, await tags.calls, await running.calls)
        #expect(secondCalls == (2,2,2))
        #expect(miner.codexTokenData().currentIndex == (index+2)%120)
    }
    @Test func stoppingBeforeTheTaskStartsCannotLaunchProviderWork() async throws {
        let endpoint=SamplingEndpoint()
        let miner=XRGAITokenMiner(home:"/nonexistent-xrg-cancel-before-start",clock:{0},
            otelRequest:XRGURL(transport:{_ in try await endpoint.metrics()}),
            tagsRequest:XRGURL(transport:{_ in try await endpoint.models()}),
            runningRequest:XRGURL(transport:{_ in try await endpoint.models()}))
        defer {miner.reset()}
        var callbacks=0
        miner.requestLatestTokenInfo {callbacks+=1}
        miner.pauseCollection()
        try await Task.sleep(for:.milliseconds(30))
        let calls=await endpoint.calls
        #expect(calls == 0 && callbacks == 0 && !miner.isScanningLogs)
    }

    @Test(arguments: [false,true])
    func pauseOrResetCancelsPendingCycleAndLateTransportCannotPublishAfterResume(reset:Bool) async throws {
        let root=FileManager.default.temporaryDirectory.appendingPathComponent("xrg-ai-cadence-cancel-"+UUID().uuidString)
        defer { try? FileManager.default.removeItem(at:root) }
        _ = try file(root,100)
        let gate=SamplingGate()
        let miner=XRGAITokenMiner(home:root.path,clock:{0},
            otelRequest:XRGURL(transport:{_ in Data("claude_code_input_tokens_total 100\n".utf8)}),
            tagsRequest:XRGURL(transport:{_ in await gate.request()}),
            runningRequest:XRGURL(transport:{_ in Data(#"{"models":[{"name":"new"}]}"#.utf8)}))
        defer { miner.reset() }
        miner.setDataSize(120);miner.setAccountingEnabled(true)
        var callbacks=0,events=0
        miner.usageEventHandler={_,_ in events+=1}
        miner.requestLatestTokenInfo { callbacks+=1 }
        for _ in 0..<600 { if await gate.count() >= 1 {break};try await Task.sleep(for:.milliseconds(5)) }
        if reset { miner.resetAccountingBaseline() } else { miner.pauseCollection() }
        #expect(miner.totalCodexTokens == 0 && callbacks == 0)
        miner.requestLatestTokenInfo { callbacks+=1 }
        for _ in 0..<600 { if await gate.count() >= 2 {break};try await Task.sleep(for:.milliseconds(5)) }
        await gate.resolve(1,#"{"models":[{"name":"new"}]}"#)
        try await until { callbacks == 1 }
        #expect(miner.totalCodexTokens == 100 && events == 0 && miner.ollamaAvailable)
        await gate.resolve(0,"invalid old data")
        try await Task.sleep(for:.milliseconds(30))
        #expect(callbacks == 1 && events == 0 && miner.ollamaAvailable)
        await gate.finish()
    }
}
