import XCTest
@testable import FTDSL
import FTCore

final class StepDescriptionTests: XCTestCase {

    // MARK: - ユーザー指定の変換例(完全一致)

    func testUserSpecifiedExamples() {
        XCTAssertEqual(StepDescription.describe(command: "launch com.android.settings"),
                       "com.android.settingsアプリを起動する")
        XCTAssertEqual(StepDescription.describe(command: "tap \"ネットワークとインターネット\""),
                       "\"ネットワークとインターネット\"をタップする")
        XCTAssertEqual(
            StepDescription.describe(
                command: "exist \"#collapsing_toolbar||ネットワークとインターネット\""),
            "\"ネットワークとインターネット\"が表示されること")
    }

    func testTap() {
        XCTAssertEqual(StepDescription.describe(command: "tap \"ログイン\""),
                       "\"ログイン\"をタップする")
    }

    func testType() {
        XCTAssertEqual(StepDescription.describe(command: "type \"#email\" \"a@b.c\""),
                       "\"#email\"に\"a@b.c\"を入力する")
    }

    func testTypeFocusedElementForm() {
        // ロケータなしの type "text"(直前の tap でフォーカスした要素へ入力)
        XCTAssertEqual(StepDescription.describe(command: "type \"あいう\""),
                       "フォーカス中の要素に\"あいう\"を入力する")
    }

    func testTypeWithSpaceInText() {
        // テキストに空白があっても最初の「" "」で区切る(セレクタに " は含まれない前提)
        XCTAssertEqual(StepDescription.describe(command: "type \"#q\" \"hello world\""),
                       "\"#q\"に\"hello world\"を入力する")
    }

    func testPress() {
        XCTAssertEqual(StepDescription.describe(command: "press \"アイコン\""),
                       "\"アイコン\"を長押しする")
    }

    func testSwipeAllDirections() {
        XCTAssertEqual(StepDescription.describe(command: "swipe up"), "上にスワイプする")
        XCTAssertEqual(StepDescription.describe(command: "swipe down"), "下にスワイプする")
        XCTAssertEqual(StepDescription.describe(command: "swipe left"), "左にスワイプする")
        XCTAssertEqual(StepDescription.describe(command: "swipe right"), "右にスワイプする")
        XCTAssertNil(StepDescription.describe(command: "swipe diagonal"))
    }

    func testScrollTo() {
        XCTAssertEqual(StepDescription.describe(command: "scrollTo \"設定\""),
                       "\"設定\"が表示されるまでスクロールする")
    }

    func testExist() {
        XCTAssertEqual(StepDescription.describe(command: "exist \"ようこそ\""),
                       "\"ようこそ\"が表示されること")
    }

    func testTextIs() {
        XCTAssertEqual(
            StepDescription.describe(command: "textIs \"#login_error\" == \"パスワードが違います\""),
            "\"#login_error\"のテキストが\"パスワードが違います\"であること")
    }

    func testValueIs() {
        XCTAssertEqual(StepDescription.describe(command: "valueIs \"#switch\" == \"1\""),
                       "\"#switch\"の値が\"1\"であること")
    }

    func testScreenIs() {
        XCTAssertEqual(StepDescription.describe(command: "screenIs \"ホーム画面が表示されている\""),
                       "画面が\"ホーム画面が表示されている\"であること")
    }

    func testLaunchAndRelaunch() {
        XCTAssertEqual(StepDescription.describe(command: "relaunch com.example.app"),
                       "com.example.appアプリを再起動する")
    }

    func testTerminate() {
        XCTAssertEqual(StepDescription.describe(command: "terminate"), "アプリを終了する")
    }

    func testWait() {
        XCTAssertEqual(StepDescription.describe(command: "wait 1.0s"), "1秒待機する")
        XCTAssertEqual(StepDescription.describe(command: "wait 0.5s"), "0.5秒待機する")
        XCTAssertEqual(StepDescription.describe(command: "wait 3.0s"), "3秒待機する")
    }

    func testNonTargetCommandsReturnNil() {
        XCTAssertNil(StepDescription.describe(command: "ifCanSelect \"今はしない\" → 実行"))
        XCTAssertNil(StepDescription.describe(command: "procedure \"テストデータを投入\""))
        XCTAssertNil(StepDescription.describe(command: "unknown \"x\""))
        XCTAssertNil(StepDescription.describe(command: ""))
        XCTAssertNil(StepDescription.describe(command: "tap 引用符なし"))
    }

    func testObjectPhraseUsesFirstLabelClause() {
        // id 節 + label 節 → ラベルを目的語に
        XCTAssertEqual(StepDescription.objectPhrase(ofSelector: "#login_btn||ログイン"), "ログイン")
        // label 節のみ
        XCTAssertEqual(StepDescription.objectPhrase(ofSelector: "ログイン"), "ログイン")
        // id のみ(ラベル無し)→ セレクタ文字列そのまま
        XCTAssertEqual(StepDescription.objectPhrase(ofSelector: "#login_btn"), "#login_btn")
        // type 節 + type=label 節 → label 成分
        XCTAssertEqual(StepDescription.objectPhrase(ofSelector: ".Button||.Switch=アップロード"),
                       "アップロード")
        // = エスケープの生ラベル
        XCTAssertEqual(StepDescription.objectPhrase(ofSelector: "=#タグ"), "#タグ")
        // ラベル無しの連鎖 → セレクタ文字列そのまま
        XCTAssertEqual(StepDescription.objectPhrase(ofSelector: "#a||.Cell[3]"), "#a||.Cell[3]")
    }

    func testOptionalSuffixIsIgnored() {
        XCTAssertEqual(StepDescription.describe(command: "tap \"今はしない\" (optional)"),
                       "\"今はしない\"をタップする")
    }

    func testSelectorOverride() {
        // ヒール確認シート用: 旧セレクタのコマンドに新セレクタを差し込んで説明を生成
        XCTAssertEqual(
            StepDescription.describe(command: "tap \"Network & internet\"",
                                     selectorOverride: "#toolbar||ネットワークとインターネット"),
            "\"ネットワークとインターネット\"をタップする")
        XCTAssertEqual(
            StepDescription.describe(command: "exist \"旧ラベル\"",
                                     selectorOverride: "#id_only"),
            "\"#id_only\"が表示されること")
    }

    // MARK: - describe(step:)(コード生成用)

    func testDescribeStepRepresentativeCases() {
        let tap = FlowStep(action: "tap", locator: FlowLocator(id: "login_btn"),
                           fallbacks: [FlowLocator(label: "ログイン")])
        XCTAssertEqual(StepDescription.describe(step: tap), "\"ログイン\"をタップする")

        let exist = FlowStep(assert: "exists", locator: FlowLocator(id: "collapsing_toolbar"))
        XCTAssertEqual(StepDescription.describe(step: exist),
                       "\"#collapsing_toolbar\"が表示されること")

        let type = FlowStep(action: "type", locator: FlowLocator(id: "email"), text: "a@b.c")
        XCTAssertEqual(StepDescription.describe(step: type), "\"#email\"に\"a@b.c\"を入力する")

        // ロケータなし = フォーカス中の要素へ入力
        XCTAssertEqual(StepDescription.describe(step: FlowStep(action: "type", text: "あいう")),
                       "フォーカス中の要素に\"あいう\"を入力する")

        let screen = FlowStep(assert: "screenMatches", expected: "設定画面")
        XCTAssertEqual(StepDescription.describe(step: screen), "画面が\"設定画面\"であること")

        // 未知の action は nil
        XCTAssertNil(StepDescription.describe(step: FlowStep(action: "unknown")))
    }

    // MARK: - codegen の行末コメント(FM の note のみ。機械的な説明=StepDescription は付けない)

    func testCodeGenUsesNoteAsComment() {
        // note があればそれを行末コメントにする(explore は FM がここに理由を入れる)
        let step = FlowStep(action: "tap", locator: FlowLocator(label: "設定"),
                            note: "FM の理由文")
        let lines = ScenarioCodeGen.render(step: step, indent: "")
        XCTAssertEqual(lines, ["tap(\"設定\")  // FM の理由文"])
    }

    func testCodeGenOmitsCommentWhenNoNote() {
        // note が無いステップ(記録機能の生成物)は行末コメントを付けない
        let step = FlowStep(action: "tap", locator: FlowLocator(label: "設定"))
        let lines = ScenarioCodeGen.render(step: step, indent: "")
        XCTAssertEqual(lines, ["tap(\"設定\")"])
    }
}
