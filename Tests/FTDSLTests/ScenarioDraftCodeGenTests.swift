import XCTest
@testable import FTDSL
import FTCore

/// テストベース下書き → Swift DSL コード。生成物の性質(@Deleted・TODO プレースホルダ・
/// 手順文の保存)と、自然言語 → コマンド候補の写像規則を固定する。
final class ScenarioDraftCodeGenTests: XCTestCase {

    private func render(_ draft: ScenarioDraft, platform: String? = "ios") -> String {
        ScenarioDraftCodeGen.render(draft: draft, className: "下書き", app: "com.example.app",
                                    platform: platform, source: "login.md",
                                    generatedBy: "test")
    }

    func testGeneratedClassIsDeletedAndUsesPlaceholder() {
        let draft = ScenarioDraft(title: "ログイン", scenes: [
            DraftScene(number: 1, title: "成功", condition: ["アプリを起動する"],
                       action: ["ログインボタンを押す"], expectation: ["ホームが表示されること"]),
        ])
        let code = render(draft)
        XCTAssertTrue(code.contains("@TestClass(app: \"com.example.app\", platform: \"ios\")"))
        XCTAssertTrue(code.contains("@Deleted("), "下書きは一括実行から外す")
        XCTAssertTrue(code.contains("@Test(\"ログイン\")"))
        XCTAssertTrue(code.contains("scene(1, \"成功\")"))
        XCTAssertTrue(code.contains("tap(\"#TODO\")"))
        // 手順文は必ずコメントに残る
        XCTAssertTrue(code.contains("// ログインボタンを押す"))
    }

    func testFirstSceneAlwaysStartsWithLaunch() {
        let draft = ScenarioDraft(title: "t", scenes: [
            DraftScene(number: 1, title: "s1", action: ["押す"]),
            DraftScene(number: 2, title: "s2", action: ["押す"]),
        ])
        let code = render(draft)
        XCTAssertEqual(code.components(separatedBy: "launchApp()").count - 1, 1,
                       "起動は最初の scene だけに入れる(2番目以降は状態を引き継ぐ)")
    }

    func testConditionWithoutLaunchBecomesTodoComment() {
        let draft = ScenarioDraft(title: "t", scenes: [
            DraftScene(number: 1, title: "s", condition: ["商品が3件登録済みである"], action: ["押す"]),
        ])
        let code = render(draft)
        XCTAssertTrue(code.contains("// TODO: prepare the precondition 「商品が3件登録済みである」"))
    }

    func testActionMapping() {
        let indent = ""
        XCTAssertTrue(ScenarioDraftCodeGen.commandLine(forAction: "メールアドレスを入力する", indent: indent)
            .hasPrefix("type(\"#TODO\", \"TODO\")"))
        XCTAssertTrue(ScenarioDraftCodeGen.commandLine(forAction: "セルを長押しする", indent: indent)
            .hasPrefix("tap(\"#TODO\", holdSeconds: 1)"))
        XCTAssertTrue(ScenarioDraftCodeGen.commandLine(forAction: "下までスクロールする", indent: indent)
            .hasPrefix("scrollTo(\"#TODO\")"))
        XCTAssertTrue(ScenarioDraftCodeGen.commandLine(forAction: "アプリを再起動する", indent: indent)
            .hasPrefix("restartApp()"))
        XCTAssertTrue(ScenarioDraftCodeGen.commandLine(forAction: "ボタンを押す", indent: indent)
            .hasPrefix("tap(\"#TODO\")"))
    }

    func testExpectationMapping() {
        let indent = ""
        XCTAssertTrue(ScenarioDraftCodeGen.commandLine(forExpectation: "ダイアログが表示されないこと",
                                                       indent: indent).hasPrefix("notExist("))
        XCTAssertTrue(ScenarioDraftCodeGen.commandLine(forExpectation: "送信ボタンが無効であること",
                                                       indent: indent).hasPrefix("select(\"#TODO\").enabledIsFalse("))
        XCTAssertTrue(ScenarioDraftCodeGen.commandLine(forExpectation: "送信ボタンが有効であること",
                                                       indent: indent).hasPrefix("select(\"#TODO\").enabledIsTrue("))
        XCTAssertTrue(ScenarioDraftCodeGen.commandLine(forExpectation: "一覧に3件表示されること",
                                                       indent: indent).hasPrefix("countIs(\"#TODO\", 3)"))
        XCTAssertTrue(ScenarioDraftCodeGen.commandLine(forExpectation: "「保存しました」と表示されること",
                                                       indent: indent).hasPrefix("select(\"#TODO\").textIs("))
        XCTAssertTrue(ScenarioDraftCodeGen.commandLine(forExpectation: "ホーム画面が表示されること",
                                                       indent: indent).hasPrefix("exist("))
    }

    func testItemCountParsing() {
        XCTAssertEqual(ScenarioDraftCodeGen.itemCount(in: "3件ある"), 3)
        XCTAssertEqual(ScenarioDraftCodeGen.itemCount(in: "12 個表示"), 12)
        XCTAssertNil(ScenarioDraftCodeGen.itemCount(in: "たくさん表示される"))
        XCTAssertNil(ScenarioDraftCodeGen.itemCount(in: "3秒待つ"))
    }

    func testPlatformOmittedWhenNil() {
        let draft = ScenarioDraft(title: "t", scenes: [DraftScene(number: 1, title: "s", action: ["押す"])])
        XCTAssertTrue(render(draft, platform: nil).contains("@TestClass(app: \"com.example.app\")"))
    }

    func testQuotesInTextAreEscaped() {
        let draft = ScenarioDraft(title: "\"引用\" を含む", scenes: [
            DraftScene(number: 1, title: "s", action: ["押す"]),
        ])
        XCTAssertTrue(render(draft).contains("@Test(\"\\\"引用\\\" を含む\")"))
    }

    func testConditionOnlyMapsRealAppLaunchToLaunchApp() {
        // 「開く」だけで起動扱いすると画面内操作まで launchApp() に化ける(FM 経路の実出力で確認)
        XCTAssertTrue(ScenarioDraftCodeGen.isAppLaunch("アプリを起動している"))
        XCTAssertTrue(ScenarioDraftCodeGen.isAppLaunch("アプリを開く"))
        XCTAssertTrue(ScenarioDraftCodeGen.isAppLaunch("アプリを立ち上げた状態"))
        XCTAssertFalse(ScenarioDraftCodeGen.isAppLaunch("カートタブを開く"))
        XCTAssertFalse(ScenarioDraftCodeGen.isAppLaunch("設定画面を表示する"))

        let line = ScenarioDraftCodeGen.commandLine(forCondition: "カートタブを開く", indent: "")
        XCTAssertTrue(line.hasPrefix("// TODO: prepare the precondition"), "画面内操作は TODO コメントに落とす: \(line)")
    }
}
