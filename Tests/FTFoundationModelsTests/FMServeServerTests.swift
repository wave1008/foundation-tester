// FM の常駐プロセスの本体(FMServeServer)のうち、FM を呼ばない部分: 暖機の判断・要求の振り分け(状態・版・壊れた要求)。

import Foundation
import XCTest
import FTCore
@testable import FTFoundationModels

final class FMServeServerTests: XCTestCase {

    func testKeepWarmIntervalIsPinned() {
        XCTAssertEqual(FMServeServer.keepWarmIntervalSeconds, 1.0)
        XCTAssertEqual(FMServeServer.slowKeepAliveSeconds, 4)
    }

    /// **暖機は実際の生成**(prewarm だけでは安全判定のモデルが約 5 秒で降ろされ、その載せ直しで FM が死んだ)。
    /// 合間の判断(tick)が生成の暖機を撃ち、受け付けのスレッドを塞がない(裏の Task)ことをソースで固定する
    func testKeepWarmIsARealGenerationOffTheAcceptThread() throws {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let server = try String(contentsOf: root.appendingPathComponent("Sources/FTFoundationModels/FMServeServer.swift"),
                                encoding: .utf8)
        let keepAlive = try XCTUnwrap(PreloadSlotTests.functionBody(named: "keepAlive", in: server))
        XCTAssertTrue(keepAlive.contains("session.respond("), "暖機が生成を撃っていない(prewarm だけでは安全判定のモデルが降ろされる)")
        XCTAssertTrue(keepAlive.contains("Attachment("), "暖機が画像の部品を通っていない")
        let tick = try XCTUnwrap(PreloadSlotTests.functionBody(named: "tick", in: server))
        let activity = try String(contentsOf: root.appendingPathComponent("Sources/FTFoundationModels/FMServeActivity.swift"),
                                  encoding: .utf8)
        let startWarm = try XCTUnwrap(PreloadSlotTests.functionBody(named: "startWarm", in: activity))
        XCTAssertTrue(tick.contains("activity.startWarm(") && tick.contains("try await keepAlive()")
                      && startWarm.contains("Task.detached {"),
                      "合間の判断が排他的な門を通して暖機を裏で撃っていない")
        XCTAssertEqual(FMServeServer.keepAliveTokens, 8)
    }

    /// **安全判定による拒否は FM の失敗ではない**(同じ画面の切り出しで毎回起きる拒否を失敗に数えると、連続 3 回で「死」を
    /// 記録し以後の呼び出しを全部止めた。長時間テストで実測)。常駐プロセスは拒否を `refused` で返し、頼む側は失敗として
    /// 記録しない(答えの無かった回 = skip)・死活の確かめは「生きている」と読む
    func testGuardrailRefusalIsNotCountedAsAnFMFailure() throws {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        func source(_ path: String) throws -> String {
            try String(contentsOf: root.appendingPathComponent(path), encoding: .utf8)
        }
        let server = try source("Sources/FTFoundationModels/FMServeServer.swift")
        XCTAssertTrue(server.contains("if case .guardrailViolation = error { return .refused("),
                      "常駐プロセスが拒否を失敗と区別していない")
        for path in ["Sources/FTFoundationModels/OcclusionVerifier.swift", "Sources/FTFoundationModels/ReplayAssist.swift"] {
            let text = try source(path)
            let branch = try XCTUnwrap(text.range(of: "case .refused, .versionMismatch:"), "\(path) が拒否を扱っていない")
            let failedRecord = try XCTUnwrap(text.range(of: "ok: false,"), path)
            XCTAssertLessThan(failedRecord.lowerBound, branch.lowerBound, "\(path) の拒否の分岐が失敗の記録の後ろに無い")
            let after = text[branch.upperBound...].prefix(400)
            XCTAssertTrue(after.contains("FMHealth.recordSkip()"), "\(path) が拒否を答えの無かった回として数えていない")
        }
        XCTAssertTrue(try source("Sources/FTFoundationModels/FMLivenessProbe.swift").contains("case .ok, .refused: return .answered"),
                      "死活の確かめが拒否を死と読む")
    }

    /// 暖機が載せたままにできない機械(呼び出しの中で載せ直す = 遅い回が多い)では暖機をやめる。判断は直近 20 回の割合で、
    /// 窓が埋まるまでは決めない・遅い回が速い回に挟まっていても数える(M1mini は「続いた回数」では一度も満たさなかった)
    func testKeepWarmGivesUpOnTheShareOfSlowCalls() {
        XCTAssertEqual(FMServeServer.keepWarmWindow, 20)
        XCTAssertEqual(FMServeServer.keepWarmGiveUpSlowCalls, 6)
        func history(slowAt: Set<Int>, count: Int = 20) -> [Bool] { (0..<count).map { slowAt.contains($0) } }
        XCTAssertTrue(FMServeServer.keepWarmStillUseful(recent: history(slowAt: [0, 1, 2, 3, 4, 5, 6], count: 19)),
                      "窓が埋まる前に決めた")
        XCTAssertTrue(FMServeServer.keepWarmStillUseful(recent: history(slowAt: [3, 4, 10, 15, 19])), "20 回中 5 回でやめた")
        XCTAssertFalse(FMServeServer.keepWarmStillUseful(recent: history(slowAt: [1, 4, 7, 10, 13, 16])),
                       "遅い回が速い回に挟まった 20 回中 6 回でやめていない")
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let server = (try? String(contentsOf: root.appendingPathComponent("Sources/FTFoundationModels/FMServeServer.swift"),
                                  encoding: .utf8)) ?? ""
        let tick = PreloadSlotTests.functionBody(named: "tick", in: server) ?? ""
        XCTAssertTrue(tick.contains("let generate = keepWarmStillUseful(recent:"), "合間の判断が暖機をやめる判断を通っていない")
        XCTAssertTrue(tick.contains("history.append(took > slowKeepAliveSeconds)"), "暖機の所要を記録していない")
    }

    /// 間隔が過ぎたら撃つ・過ぎる前は撃たない・死んでいると分かっている FM には撃たない
    func testShouldWarm() {
        let now = Date(timeIntervalSince1970: 1_000)
        XCTAssertFalse(FMServeServer.shouldWarm(lastFMUse: now.addingTimeInterval(-0.9), now: now, knownDead: false))
        XCTAssertTrue(FMServeServer.shouldWarm(lastFMUse: now.addingTimeInterval(-1.0), now: now, knownDead: false))
        XCTAssertTrue(FMServeServer.shouldWarm(lastFMUse: .distantPast, now: now, knownDead: false))
        XCTAssertFalse(FMServeServer.shouldWarm(lastFMUse: .distantPast, now: now, knownDead: true))
    }

    private func answer(_ payload: Data) async throws -> FMServeWire.Response {
        let raw = await FMServeServer.handle(payload, executable: "/x/fleetest", stamp: "7-8")
        let data = try XCTUnwrap(raw)
        return try JSONDecoder().decode(FMServeWire.Response.self, from: data)
    }

    func testStatusAnswersWithoutCallingFMAndCarriesTheIdentity() async throws {
        let response = try await answer(try JSONEncoder().encode(FMServeWire.Request(kind: .status)))
        XCTAssertEqual(response.status, .ok)
        XCTAssertEqual(response.serverVersion, FMServeWire.protocolVersion)
        XCTAssertEqual(response.executable, "/x/fleetest")
        XCTAssertEqual(response.buildStamp, "7-8")
    }

    func testVersionMismatchDoesNothing() async throws {
        let request = FMServeWire.Request(kind: .transcribe, png: Data([0]), version: FMServeWire.protocolVersion + 1)
        let response = try await answer(try JSONEncoder().encode(request))
        XCTAssertEqual(response.status, .versionMismatch)
        XCTAssertNil(response.text)
    }

    func testMalformedRequestFailsWithoutCallingFM() async throws {
        let response = try await answer(Data("not json".utf8))
        XCTAssertEqual(response.status, .failed)
    }

    /// 画像が読めない要求は FM を呼ばずに失敗で返す(macOS 27 未満では画像入力そのものが無い旨で返す)
    func testUnreadableImageFailsWithoutCallingFM() async throws {
        let response = try await answer(try JSONEncoder().encode(FMServeWire.Request(kind: .transcribe, png: Data([1, 2, 3]))))
        XCTAssertEqual(response.status, .failed)
        XCTAssertNotNil(response.error)
    }
}
