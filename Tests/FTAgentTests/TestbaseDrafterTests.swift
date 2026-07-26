import XCTest
@testable import FTAgent
import FTCore

/// FM 応答 → ScenarioDraft の変換(TestbaseDrafter.convert / clean / sanitize)。
/// **FM 呼び出し自体は含まない**(オンデバイス FM はホスト状態で落ちるため CI 不能)。
/// 3B モデルが出しがちな崩れ(箇条書き記号の混入・改行・長すぎ・空 scene)をここで吸収する契約を固定する。
final class TestbaseDrafterTests: XCTestCase {

    private func scene(_ title: String, condition: [String] = [], action: [String] = [],
                       expectation: [String] = []) -> TestbaseSceneSuggestion {
        TestbaseSceneSuggestion(title: title, condition: condition,
                                action: action, expectation: expectation)
    }

    func testConvertKeepsOrderAndRenumbersScenes() {
        let suggestion = TestbaseDraftSuggestion(title: "ログインできる", scenes: [
            scene("成功", condition: ["起動済み"], action: ["ログインする"], expectation: ["ホームが出ること"]),
            scene("失敗", action: ["誤りで押す"], expectation: ["エラーが出ること"]),
        ])
        let draft = TestbaseDrafter.convert(suggestion, fallbackTitle: "fb")
        XCTAssertEqual(draft?.title, "ログインできる")
        XCTAssertEqual(draft?.scenes.map(\.number), [1, 2])
        XCTAssertEqual(draft?.scenes[0].condition, ["起動済み"])
        XCTAssertEqual(draft?.scenes[1].expectation, ["エラーが出ること"])
    }

    func testEmptyScenesAreDroppedAndRenumbered() {
        let suggestion = TestbaseDraftSuggestion(title: "t", scenes: [
            scene("空", condition: [""], action: ["   "], expectation: []),
            scene("実体あり", action: ["押す"]),
        ])
        let draft = TestbaseDrafter.convert(suggestion, fallbackTitle: "fb")
        XCTAssertEqual(draft?.scenes.count, 1)
        XCTAssertEqual(draft?.scenes[0].number, 1, "捨てた分の番号の穴を残さない")
        XCTAssertEqual(draft?.scenes[0].title, "実体あり")
    }

    func testAllEmptyYieldsNilSoCallerFallsBackToDeterministicParser() {
        let suggestion = TestbaseDraftSuggestion(title: "t", scenes: [scene("空", action: [""])])
        XCTAssertNil(TestbaseDrafter.convert(suggestion, fallbackTitle: "fb"))
        XCTAssertNil(TestbaseDrafter.convert(TestbaseDraftSuggestion(title: "t", scenes: []),
                                             fallbackTitle: "fb"))
    }

    func testEmptyTitlesFallBack() {
        let suggestion = TestbaseDraftSuggestion(title: "  ", scenes: [scene("", action: ["押す"])])
        let draft = TestbaseDrafter.convert(suggestion, fallbackTitle: "テストベース名")
        XCTAssertEqual(draft?.title, "テストベース名")
        XCTAssertEqual(draft?.scenes[0].title, "場面1")
    }

    func testCleanStripsModelNoise() {
        // 箇条書き記号・引用符・改行は 3B モデルが指示を無視して混ぜてくる(ScenarioNamer と同じ事情)
        XCTAssertEqual(TestbaseDrafter.clean("- 「ボタンを押す」", maxCount: 60), "ボタンを押す")
        XCTAssertEqual(TestbaseDrafter.clean("* 一行目\n二行目", maxCount: 60), "一行目 二行目")
        XCTAssertEqual(TestbaseDrafter.clean(String(repeating: "あ", count: 80), maxCount: 60).count, 60)
        XCTAssertEqual(TestbaseDrafter.clean("   ", maxCount: 60), "")
    }

    func testSanitizeDropsEmptyItems() {
        XCTAssertEqual(TestbaseDrafter.sanitize(["押す", "", "  ", "・確認する"]),
                       ["押す", "確認する"])
    }
}
