// 下書きの「位置」に関する性質(2026-08-10)。
//
// MCP の探索は長い。33 手の実測で2つ壊れていた:
//   - セレクタを解決できなかった手をまとめて先頭のコメントへ出していたため、action の並びから
//     その手が消え、生成コードが実際の手順と食い違った(チェックアウト→住所画面へ移る手が
//     抜けたまま #btn_add_address を叩く形になった)
//   - 33 手が全部 scene(1) に入り、CAE の構造が無かった
//
// どちらも「位置」の問題なので、ここで位置そのものを固定する。

import XCTest
@testable import FTDSL
// @testable: ScenarioCodeGen.sceneRanges は internal(FTCore に住む。移動前は FTDSL だった)
@testable import FTCore

final class ScenarioCodeGenPlacementTests: XCTestCase {

    private func tap(_ selector: String) -> FlowStep {
        var step = FlowStep(action: "tap")
        step.locator = FTSelector.parse(selector).primary
        return step
    }

    private func flow(_ steps: [FlowStep]) -> Flow {
        Flow(name: "t", app: "com.example.app", platform: "ios", goal: nil,
             generatedBy: "test", steps: steps)
    }

    private func render(_ steps: [FlowStep], notes: [Int: [String]] = [:],
                        scenes: [Int] = []) -> [String] {
        ScenarioCodeGen.render(flow: flow(steps), className: "T", generatedBy: "test",
                               emptyExpectation: true, notesBeforeStep: notes,
                               sceneBreaks: scenes)
            .components(separatedBy: "\n").map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
    }

    // MARK: - 解決できなかった手はその場に残る

    func testNoteLandsImmediatelyBeforeTheStepItPrecedes() {
        let lines = render([tap("#a"), tap("#b")], notes: [1: ["TODO: no stable selector — tap X"]])
        let noteAt = lines.firstIndex { $0.contains("no stable selector") }
        let aAt = lines.firstIndex { $0.contains("tap(\"#a\")") }
        let bAt = lines.firstIndex { $0.contains("tap(\"#b\")") }
        XCTAssertNotNil(noteAt)
        // **#a の後・#b の前**。まとめて先頭へ出す旧挙動ならここが崩れる
        XCTAssertLessThan(aAt!, noteAt!)
        XCTAssertLessThan(noteAt!, bAt!)
    }

    func testNoteAtTheEndStaysAfterTheLastStep() {
        let lines = render([tap("#a")], notes: [1: ["TODO: no stable selector — tap Z"]])
        XCTAssertLessThan(lines.firstIndex { $0.contains("tap(\"#a\")") }!,
                          lines.firstIndex { $0.contains("tap Z") }!)
    }

    /// 注記が1件も無ければ本文は素のまま(注記の仕組みが常時何かを足していないこと)
    func testNoNotesLeavesTheBodyAlone() {
        XCTAssertFalse(render([tap("#a")]).contains { $0.contains("no stable selector") })
    }

    // MARK: - scene の切り分け

    // `sceneBreaks` は **steps の 0 起点の位置**(一覧番号 → 位置の変換は MCP 側の仕事)。
    // 位置 k を渡すと steps[k] が新しい scene の先頭になる

    func testStepsAreCutIntoScenesAtTheGivenBoundaries() {
        let lines = render([tap("#a"), tap("#b"), tap("#c"), tap("#d")], scenes: [1, 2])
        XCTAssertTrue(lines.contains("scene(1) {"))
        XCTAssertTrue(lines.contains("scene(2) {"))
        XCTAssertTrue(lines.contains("scene(3) {"))
        XCTAssertFalse(lines.contains("scene(4) {"))
        // 切れ目の手は**新しい scene の先頭**: #b は scene(2) より後、#c は scene(3) より後
        XCTAssertGreaterThan(lines.firstIndex { $0.contains("tap(\"#b\")") }!,
                             lines.firstIndex(of: "scene(2) {")!)
        XCTAssertGreaterThan(lines.firstIndex { $0.contains("tap(\"#c\")") }!,
                             lines.firstIndex(of: "scene(3) {")!)
        // #a は scene(2) より前(最初の scene に残る)
        XCTAssertLessThan(lines.firstIndex { $0.contains("tap(\"#a\")") }!,
                          lines.firstIndex(of: "scene(2) {")!)
    }

    /// **launchApp は最初の scene だけ**(2つ目以降で撃つと画面が巻き戻る)
    func testOnlyTheFirstSceneGetsTheLaunchCondition() {
        let lines = render([tap("#a"), tap("#b")], scenes: [1])
        XCTAssertEqual(lines.filter { $0.contains("launchApp()") }.count, 1)
        XCTAssertEqual(lines.filter { $0 == "condition {" }.count, 1)
        // 2つ目の scene は action から始まる(先頭ブロックなので `}.` が付かない)
        XCTAssertTrue(lines.contains("action {"), lines.joined(separator: " / "))
    }

    /// scene ごとに空の expectation が付く = dry-run が「各 scene は何を証明するのか」を全部訊く
    func testEverySceneGetsItsOwnEmptyExpectation() {
        let lines = render([tap("#a"), tap("#b"), tap("#c")], scenes: [1, 2])
        XCTAssertEqual(lines.filter { $0.contains("expectation {") }.count, 3)
    }

    /// 切れ目を渡さなければ従来どおり 1 scene(既定を変えない)
    func testWithoutBreaksItIsStillOneScene() {
        let lines = render([tap("#a"), tap("#b")])
        XCTAssertTrue(lines.contains("scene(1) {"))
        XCTAssertFalse(lines.contains("scene(2) {"))
    }

    // MARK: - 人が読んだ番号をそのまま受けるので、範囲外・重複・順不同を吸収する

    func testOutOfRangeDuplicateAndUnorderedBreaksDoNotProduceEmptyScenes() {
        for breaks in [[0], [99], [2, 2], [3, 2], [-1, 2]] {
            let ranges = ScenarioCodeGen.sceneRanges(count: 4, breaks: breaks)
            XCTAssertFalse(ranges.contains { $0.isEmpty }, "\(breaks) で空の scene が出た")
            XCTAssertEqual(ranges.first?.lowerBound, 0, "\(breaks)")
            XCTAssertEqual(ranges.last?.upperBound, 4, "\(breaks)")
            // 連続していること(手が落ちない)
            for (a, b) in zip(ranges, ranges.dropFirst()) {
                XCTAssertEqual(a.upperBound, b.lowerBound, "\(breaks)")
            }
        }
    }

    func testEmptyStepListStillRenders() {
        XCTAssertFalse(render([]).isEmpty)
    }
}
