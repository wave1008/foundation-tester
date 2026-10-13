// occlusion の先読み(preload)の契約。**FM を実際に先読みする部分は単体テストで踏まない**
// (ホスト共有資源。効果と害は実 run の A/B で見る。docs/performance-tuning.md §3.5.1)。
// ここで固定するのは殺しスイッチ・スロットの受け渡し規則・等倍の転写がスロットを使うこと。

import XCTest
@testable import FTFoundationModels

final class OcclusionPreloadTests: XCTestCase {

    override func tearDown() {
        OcclusionPreload.resetForTesting()
        super.tearDown()
    }

    func testPreloadIsOnByDefault() {
        XCTAssertTrue(OcclusionVerifier.preloadEnabled(environment: [:]))
        XCTAssertTrue(OcclusionVerifier.preloadEnabled(environment: ["FT_FM_OCCLUSION_PRELOAD": "1"]))
        // 切るのは明示の "0" だけ(想定外の値は切らない側に倒す)
        XCTAssertTrue(OcclusionVerifier.preloadEnabled(environment: ["FT_FM_OCCLUSION_PRELOAD": "off"]))
    }

    func testKillSwitchTurnsItOff() {
        XCTAssertFalse(OcclusionVerifier.preloadEnabled(environment: ["FT_FM_OCCLUSION_PRELOAD": "0"]))
    }

    /// 空のスロットからは取れない(= その場でセッションを作る従来の経路へ落ちる)
    func testTakeOnEmptySlotReturnsNil() {
        OcclusionPreload.resetForTesting()
        XCTAssertNil(OcclusionPreload.take(matching: OcclusionVerifier.instructions))
        XCTAssertFalse(OcclusionPreload.isHoldingForTesting)
    }

    private final class FakeSession {
        let instructions: String
        var warmCount = 0
        init(instructions: String) { self.instructions = instructions }
    }

    /// **未使用の同じ instructions のセッションは作り直さず暖め直すだけ**(規律⑤)。ガード評価ごとに作り捨てると
    /// modelmanagerd が安全判定のモデルを毎回 ANE に載せ、8 並列で ANE が溢れて FM と OCR が死んだ
    func testRepeatedPreloadReusesTheUnusedSession() {
        let slot = PreloadSlot<FakeSession>()
        var made: [FakeSession] = []
        let make = { (instructions: String) -> FakeSession in
            let session = FakeSession(instructions: instructions)
            made.append(session)
            return session
        }
        for _ in 0..<5 { slot.preload(instructions: "a", make: make, warm: { $0.warmCount += 1 }) }
        XCTAssertEqual(made.count, 1, "同じ instructions の先読みのたびにセッションを作り直している")
        XCTAssertEqual(made.first?.warmCount, 5, "作り直さない代わりに毎回暖め直していない")
        XCTAssertTrue(slot.take(matching: "a") === made.first)
    }

    /// 取り出した後(= 使われて履歴を持ちうる)は使い回さず、次の先読みで作り直す(規律②)
    func testPreloadAfterTakeMakesAFreshSession() {
        let slot = PreloadSlot<FakeSession>()
        var made = 0
        let make = { (instructions: String) -> FakeSession in made += 1; return FakeSession(instructions: instructions) }
        slot.preload(instructions: "a", make: make, warm: { _ in })
        let first = slot.take(matching: "a")
        XCTAssertNotNil(first)
        XCTAssertFalse(slot.isHolding)
        slot.preload(instructions: "a", make: make, warm: { _ in })
        XCTAssertEqual(made, 2)
        XCTAssertFalse(slot.take(matching: "a") === first, "使った後のセッションを再び置いている")
    }

    /// 別の instructions の先読みは置き換える(規律①)。古い instructions では取れない
    func testDifferentInstructionsReplaceTheSlot() {
        let slot = PreloadSlot<FakeSession>()
        var made = 0
        let make = { (instructions: String) -> FakeSession in made += 1; return FakeSession(instructions: instructions) }
        slot.preload(instructions: "a", make: make, warm: { _ in })
        slot.preload(instructions: "b", make: make, warm: { _ in })
        XCTAssertEqual(made, 2)
        XCTAssertNil(slot.take(matching: "a"))
        XCTAssertEqual(slot.take(matching: "b")?.instructions, "b")
    }

    /// **instructions は先読みと本番で同一**でなければ意味が無い(prefill は instructions ごと)。
    /// 1段目がスロットを引く鍵と、先読みが置く鍵が同じ定数であることをソースで固定する
    func testPreloadAndCallUseTheSameInstructions() throws {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let verifier = try String(
            contentsOf: root.appendingPathComponent("Sources/FTFoundationModels/OcclusionVerifier.swift"),
            encoding: .utf8)
        let delegate = try String(
            contentsOf: root.appendingPathComponent("Sources/FTFoundationModels/ReplayAssist.swift"),
            encoding: .utf8)
        XCTAssertTrue(verifier.contains("transcribe(crop, instructions: Self.instructions, preloaded: true)"),
                      "本番の呼び出しが共有の instructions 定数を使っていない")
        XCTAssertTrue(verifier.contains("OcclusionPreload.take(matching: instructions)"),
                      "転写が先読み済みセッションを引いていない(先読みが無駄になる)")
        XCTAssertTrue(delegate.contains("OcclusionPreload.preload(instructions: OcclusionVerifier.instructions)"),
                      "先読みが共有の instructions 定数で撃たれていない")
    }

    /// 死んでいる FM を先読みし続けない(門は通らないので、ブレーカだけが歯止め)
    func testPreloadChecksTheBreaker() throws {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let delegate = try String(
            contentsOf: root.appendingPathComponent("Sources/FTFoundationModels/ReplayAssist.swift"),
            encoding: .utf8)
        let body = try XCTUnwrap(Self.functionBody(named: "preloadVisibilityCheck", in: delegate))
        XCTAssertTrue(body.contains("FMBreaker.isOpen"),
                      "先読みがブレーカを見ていない(FM が死んだホストで先読みだけ回り続ける)")
        XCTAssertFalse(body.contains("FMHealth.record"),
                       "先読みを FMHealth へ記録している(呼び出し回数とレートが実態より多く見える)")
    }

    static func functionBody(named name: String, in source: String) -> String? {
        guard let found = source.range(of: "func \(name)("),
              let open = source[found.upperBound...].firstIndex(of: "{") else { return nil }
        var depth = 0
        var index = open
        while index < source.endIndex {
            if source[index] == "{" { depth += 1 }
            if source[index] == "}" {
                depth -= 1
                if depth == 0 { return String(source[open...index]) }
            }
            index = source.index(after: index)
        }
        return nil
    }
}
