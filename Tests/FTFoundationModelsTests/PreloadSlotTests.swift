// FM の常駐プロセス(FMServeServer)の予備のセッションの規則(PreloadSlot)。**FM を実際に呼ぶ部分は単体テストで踏まない**
// (ホスト共有資源)。ここで固定するのはスロットの受け渡し規則と、転写と暖機が同じ instructions・同じスロットを使うこと。

import XCTest
@testable import FTFoundationModels

final class PreloadSlotTests: XCTestCase {

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

    /// **instructions は暖機と本番で同一**でなければ意味が無い(prefill は instructions ごと)。
    /// 転写がスロットを引く鍵と、暖機が置く鍵が同じ定数であることをソースで固定する
    func testWarmUpAndTranscriptionUseTheSameSlotAndInstructions() throws {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let server = try String(
            contentsOf: root.appendingPathComponent("Sources/FTFoundationModels/FMServeServer.swift"), encoding: .utf8)
        XCTAssertTrue(server.contains("spare.take(matching: OcclusionVerifier.instructions)"),
                      "転写が暖めた予備のセッションを引いていない(暖機が無駄になる)")
        XCTAssertTrue(server.contains("spare.preload(instructions: OcclusionVerifier.instructions,"),
                      "暖機が共有の instructions 定数で撃たれていない")
        let transcribe = try XCTUnwrap(Self.functionBody(named: "transcribe", in: server))
        XCTAssertTrue(transcribe.contains("defer { warmSpare() }"), "転写の後に予備を置き直していない(次の呼び出しが暖機なしになる)")
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
