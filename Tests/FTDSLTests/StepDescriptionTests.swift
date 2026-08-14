import XCTest
@testable import FTDSL
// @testable: ScenarioCodeGen.render(step:indent:) は internal(FTCore に住む。移動前は FTDSL だった)
@testable import FTCore

final class StepDescriptionTests: XCTestCase {

    // MARK: - 言語は内容に追従する(2026-07-30 ユーザー決定)

    /// 同じコマンドでも、内容(ラベル・期待値・入力値)に日本語があれば日本語文・
    /// 無ければ英語文になる。片方だけ変えるとこのテストが境界のドリフトを検出する
    func testLanguageFollowsContent() {
        XCTAssertEqual(StepDescription.describe(command: "tap \"ログイン\""),
                       "\"ログイン\"をタップする")
        XCTAssertEqual(StepDescription.describe(command: "tap \"Login\""), "tap \"Login\"")
        // 目的語はラテンでも、期待値が日本語なら日本語文
        XCTAssertEqual(
            StepDescription.describe(command: "textIs \"#title\" == \"ホーム\""),
            "\"#title\"のテキストが\"ホーム\"であること")
        XCTAssertEqual(
            StepDescription.describe(command: "textIs \"#title\" == \"Home\""),
            "\"#title\" text is \"Home\"")
        // 半角カナも日本語として扱う
        XCTAssertEqual(StepDescription.describe(command: "tap \"ﾛｸﾞｲﾝ\""),
                       "\"ﾛｸﾞｲﾝ\"をタップする")
    }

    // MARK: - ユーザー指定の変換例(完全一致)

    func testUserSpecifiedExamples() {
        XCTAssertEqual(StepDescription.describe(command: "launch com.android.settings"),
                       "launch the com.android.settings app")
        XCTAssertEqual(StepDescription.describe(command: "tap \"ネットワークとインターネット\""),
                       "\"ネットワークとインターネット\"をタップする")
        XCTAssertEqual(
            StepDescription.describe(
                command: "exist \"#collapsing_toolbar||ネットワークとインターネット\""),
            "\"ネットワークとインターネット\"が(覆われず)見えていること")
    }

    func testTap() {
        XCTAssertEqual(StepDescription.describe(command: "tap \"ログイン\""),
                       "\"ログイン\"をタップする")
    }

    func testType() {
        XCTAssertEqual(StepDescription.describe(command: "type \"#email\" \"a@b.c\""),
                       "type \"a@b.c\" into \"#email\"")
    }

    func testTypeFocusedElementForm() {
        // ロケータなしの type "text"(直前の tap でフォーカスした要素へ入力)
        XCTAssertEqual(StepDescription.describe(command: "type \"あいう\""),
                       "フォーカス中の要素に\"あいう\"を入力する")
    }

    func testTypeWithSpaceInText() {
        // テキストに空白があっても最初の「" "」で区切る(セレクタに " は含まれない前提)
        XCTAssertEqual(StepDescription.describe(command: "type \"#q\" \"hello world\""),
                       "type \"hello world\" into \"#q\"")
    }

    func testTapHoldSeconds() {
        XCTAssertEqual(StepDescription.describe(command: "tap \"アイコン\" (hold 1s)"),
                       "\"アイコン\"を1秒間長押しする")
        XCTAssertEqual(StepDescription.describe(command: "tap \"Icon\" (hold 0.5s)"),
                       "long-press \"Icon\" for 0.5s")
        // 廃止済み `optional:` が付けていたサフィックス。**過去 run の説明文を読み直せること**
        XCTAssertEqual(StepDescription.describe(command: "tap \"アイコン\" (hold 1s) (optional)"),
                       "\"アイコン\"を1秒間長押しする")
    }

    func testSwipeAllDirections() {
        XCTAssertEqual(StepDescription.describe(command: "swipe up"), "swipe up")
        XCTAssertEqual(StepDescription.describe(command: "swipe down"), "swipe down")
        XCTAssertEqual(StepDescription.describe(command: "swipe left"), "swipe left")
        XCTAssertEqual(StepDescription.describe(command: "swipe right"), "swipe right")
        XCTAssertNil(StepDescription.describe(command: "swipe diagonal"))
    }

    func testRotateToAllOrientations() {
        XCTAssertEqual(StepDescription.describe(command: "rotateTo portrait"), "rotate to portrait")
        XCTAssertEqual(StepDescription.describe(command: "rotateTo landscape"), "rotate to landscape")
        // 廃止した左右は語彙に無い = 説明も作らない(黙って通さない)
        XCTAssertNil(StepDescription.describe(command: "rotateTo landscapeLeft"))
        XCTAssertNil(StepDescription.describe(command: "rotateTo sideways"))
    }

    func testScrollTo() {
        XCTAssertEqual(StepDescription.describe(command: "scrollTo \"設定\""),
                       "\"設定\"が表示されるまでスクロールする")
    }

    func testExist() {
        XCTAssertEqual(StepDescription.describe(command: "exist \"ようこそ\""),
                       "\"ようこそ\"が(覆われず)見えていること")
    }

    /// select は exist と語彙が違う(検証の「見えていること」ではなく操作の「選択する」)
    func testSelect() {
        XCTAssertEqual(StepDescription.describe(command: "select \"ようこそ\""),
                       "\"ようこそ\"を選択する")
        XCTAssertEqual(StepDescription.describe(command: "select \"welcome\""),
                       "select \"welcome\"")
    }

    func testTextIs() {
        XCTAssertEqual(
            StepDescription.describe(command: "textIs \"#login_error\" == \"パスワードが違います\""),
            "\"#login_error\"のテキストが\"パスワードが違います\"であること")
    }

    func testValueIs() {
        XCTAssertEqual(StepDescription.describe(command: "valueIs \"#switch\" == \"1\""),
                       "\"#switch\" value is \"1\"")
    }

    func testScreenIs() {
        XCTAssertEqual(StepDescription.describe(command: "screenIs \"ホーム画面が表示されている\""),
                       "画面が\"ホーム画面が表示されている\"であること")
    }

    func testLaunchAndRestart() {
        XCTAssertEqual(StepDescription.describe(command: "restart com.example.app"),
                       "restart the com.example.app app")
    }

    func testTerminate() {
        XCTAssertEqual(StepDescription.describe(command: "terminate"), "terminate the app")
    }

    func testPressEnter() {
        XCTAssertEqual(StepDescription.describe(command: "pressEnter"), "press the Enter key")
        XCTAssertEqual(StepDescription.describe(step: FlowStep(action: "pressEnter")),
                       "press the Enter key")
    }

    func testWait() {
        XCTAssertEqual(StepDescription.describe(command: "wait 1.0s"), "wait 1s")
        XCTAssertEqual(StepDescription.describe(command: "wait 0.5s"), "wait 0.5s")
        XCTAssertEqual(StepDescription.describe(command: "wait 3.0s"), "wait 3s")
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
        // type 節 + type&&label 節 → label 成分(旧 `.型=ラベル` は廃止済み)
        XCTAssertEqual(StepDescription.objectPhrase(ofSelector: ".button||.switch&&アップロード"),
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
            "\"#id_only\" is visible (not covered)")
    }

    // MARK: - describe(step:)(コード生成用)

    func testDescribeStepRepresentativeCases() {
        let tap = FlowStep(action: "tap", locator: FlowLocator(id: "login_btn"),
                           fallbacks: [FlowLocator(label: "ログイン")])
        XCTAssertEqual(StepDescription.describe(step: tap), "\"ログイン\"をタップする")

        // duration 非 nil = 長押し(tap/press 統合の要点)
        let hold = FlowStep(action: "tap", locator: FlowLocator(id: "icon"),
                            fallbacks: [FlowLocator(label: "アイコン")], duration: 1.5)
        XCTAssertEqual(StepDescription.describe(step: hold), "\"アイコン\"を1.5秒間長押しする")

        let exist = FlowStep(assert: "exists", locator: FlowLocator(id: "collapsing_toolbar"))
        XCTAssertEqual(StepDescription.describe(step: exist),
                       "\"#collapsing_toolbar\" is shown")

        // select は action(検証ではない)。exist と語彙が違うことを固定する
        let select = FlowStep(action: "select", locator: FlowLocator(id: "cleanup"))
        XCTAssertEqual(StepDescription.describe(step: select), "select \"#cleanup\"")

        let type = FlowStep(action: "type", locator: FlowLocator(id: "email"), text: "a@b.c")
        XCTAssertEqual(StepDescription.describe(step: type), "type \"a@b.c\" into \"#email\"")

        // ロケータなし = フォーカス中の要素へ入力
        XCTAssertEqual(StepDescription.describe(step: FlowStep(action: "type", text: "あいう")),
                       "フォーカス中の要素に\"あいう\"を入力する")

        // replace: true は「空にしてから入力する」に言い換える(セレクタあり/なしとも)。
        // 言語は元の type と同じ判定(obj/input 由来)に従う ―― この2件はラテン文字のみなので英語
        var replaceType = type
        replaceType.replace = true
        XCTAssertEqual(StepDescription.describe(step: replaceType),
                       "clear \"#email\", then type \"a@b.c\" into it")
        var replaceNoLocator = FlowStep(action: "type", text: "あいう")
        replaceNoLocator.replace = true
        XCTAssertEqual(StepDescription.describe(step: replaceNoLocator),
                       "フォーカス中の要素を空にしてから\"あいう\"を入力する")

        let screen = FlowStep(assert: "screenMatches", expected: "設定画面")
        XCTAssertEqual(StepDescription.describe(step: screen), "画面が\"設定画面\"であること")

        // 未知の action は nil
        XCTAssertNil(StepDescription.describe(step: FlowStep(action: "unknown")))

        let rotate = FlowStep(action: "rotateTo", direction: "landscape")
        XCTAssertEqual(StepDescription.describe(step: rotate), "rotate to landscape")
    }

    // MARK: - codegen の行末コメント(FM の note のみ。機械的な説明=StepDescription は付けない)

    func testCodeGenUsesNoteAsComment() {
        // note があればそれを行末コメントにする(explore は FM がここに理由を入れる)
        let step = FlowStep(action: "tap", locator: FlowLocator(label: "設定"),
                            note: "FM の理由文")
        let lines = ScenarioCodeGen.render(step: step, indent: "")
        XCTAssertEqual(lines, ["tap(\"設定\")  // FM の理由文"])
    }

    func testCodeGenWritesPressEnter() {
        let lines = ScenarioCodeGen.render(step: FlowStep(action: "pressEnter"), indent: "")
        XCTAssertEqual(lines, ["pressEnter()"])
    }

    func testCodeGenOmitsCommentWhenNoNote() {
        // note が無いステップ(記録機能の生成物)は行末コメントを付けない
        let step = FlowStep(action: "tap", locator: FlowLocator(label: "設定"))
        let lines = ScenarioCodeGen.render(step: step, indent: "")
        XCTAssertEqual(lines, ["tap(\"設定\")"])
    }

    /// FlowStep.direction はジェスチャ(指の動き)、DSL の direction はコンテンツ基準。
    /// 生成コードは**コンテンツ基準**で書き戻す(往復させると向きが反転する退行を防ぐ)
    func testCodeGenWritesScrollDirectionInContentTerms() {
        func generated(_ swipe: String) -> String {
            ScenarioCodeGen.render(
                step: FlowStep(action: "scrollTo", locator: FlowLocator(id: "row_40"),
                               direction: swipe, maxSwipes: 15),
                indent: "").first ?? ""
        }
        // 指が上 = 下に読み進める = 既定なので direction は書かない
        XCTAssertEqual(generated("up"), "scrollTo(\"#row_40\", maxSwipes: 15)")
        XCTAssertEqual(generated("down"), "scrollTo(\"#row_40\", direction: .up, maxSwipes: 15)")
        XCTAssertEqual(generated("left"), "scrollTo(\"#row_40\", direction: .right, maxSwipes: 15)")
    }
}
