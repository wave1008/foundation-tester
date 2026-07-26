import XCTest
@testable import FTCore

/// テストベース Markdown → ScenarioDraft の決定的パース(FM 不使用の土台)。
final class TestbaseOutlineTests: XCTestCase {

    func testHeadingsBecomeTitleAndScenes() {
        let markdown = """
        # ログイン機能

        ## 正しい認証情報でログインできる

        - 前提: アプリを起動している
        - 操作: メールアドレスを入力する
        - 期待: ホーム画面が表示されること

        ## 誤ったパスワードはエラー

        - 操作: 誤ったパスワードでログインする
        - 期待: エラーメッセージが表示されること
        """
        let draft = TestbaseOutline.parse(markdown: markdown, fallbackTitle: "fallback")
        XCTAssertEqual(draft.title, "ログイン機能")
        XCTAssertEqual(draft.scenes.count, 2)
        XCTAssertEqual(draft.scenes[0].number, 1)
        XCTAssertEqual(draft.scenes[0].title, "正しい認証情報でログインできる")
        XCTAssertEqual(draft.scenes[0].condition, ["アプリを起動している"])
        XCTAssertEqual(draft.scenes[0].action, ["メールアドレスを入力する"])
        XCTAssertEqual(draft.scenes[0].expectation, ["ホーム画面が表示されること"])
        XCTAssertEqual(draft.scenes[1].number, 2)
        XCTAssertEqual(draft.scenes[1].action, ["誤ったパスワードでログインする"])
    }

    func testSubHeadingsSwitchBuckets() {
        let markdown = """
        # 設定画面

        ## 通知をオフにする

        ### 前提条件
        - ログイン済みである

        ### 手順
        1. 設定タブを開く
        2. 通知トグルをオフにする

        ### 確認内容
        - トグルがオフになっていること
        """
        let draft = TestbaseOutline.parse(markdown: markdown, fallbackTitle: "fallback")
        XCTAssertEqual(draft.scenes.count, 1)
        XCTAssertEqual(draft.scenes[0].condition, ["ログイン済みである"])
        XCTAssertEqual(draft.scenes[0].action, ["設定タブを開く", "通知トグルをオフにする"])
        XCTAssertEqual(draft.scenes[0].expectation, ["トグルがオフになっていること"])
    }

    func testUnlabeledLineEndingWithKotoGoesToExpectation() {
        let markdown = """
        # 単純
        ## 場面
        - ボタンを押す
        - 結果が表示されること
        """
        let draft = TestbaseOutline.parse(markdown: markdown, fallbackTitle: "fallback")
        XCTAssertEqual(draft.scenes[0].action, ["ボタンを押す"])
        XCTAssertEqual(draft.scenes[0].expectation, ["結果が表示されること"])
    }

    func testEnglishGivenWhenThenLabels() {
        let markdown = """
        # Checkout
        ## Happy path
        - Given: the cart has one item
        - When: tap the checkout button
        - Then: the confirmation screen appears
        """
        let draft = TestbaseOutline.parse(markdown: markdown, fallbackTitle: "fallback")
        XCTAssertEqual(draft.scenes[0].condition, ["the cart has one item"])
        XCTAssertEqual(draft.scenes[0].action, ["tap the checkout button"])
        XCTAssertEqual(draft.scenes[0].expectation, ["the confirmation screen appears"])
    }

    func testNoSceneHeadingStillProducesOneScene() {
        let draft = TestbaseOutline.parse(markdown: "- ボタンを押す", fallbackTitle: "手動テスト")
        XCTAssertEqual(draft.title, "手動テスト")
        XCTAssertEqual(draft.scenes.count, 1)
        XCTAssertEqual(draft.scenes[0].action, ["ボタンを押す"])
    }

    func testEmptyMarkdownProducesPlaceholderScene() {
        let draft = TestbaseOutline.parse(markdown: "\n\n", fallbackTitle: "空")
        XCTAssertEqual(draft.scenes.count, 1)
        XCTAssertFalse(draft.scenes[0].action.isEmpty)
    }

    func testNonBucketLabelsAreNotStripped() {
        // 「エラー:」のような CAE でないラベルは本文の一部として残す
        let draft = TestbaseOutline.parse(markdown: "# t\n## s\n- エラー: 通信失敗",
                                          fallbackTitle: "t")
        XCTAssertEqual(draft.scenes[0].action, ["エラー: 通信失敗"])
    }

    func testDecorationsAreStripped() {
        let draft = TestbaseOutline.parse(markdown: "# t\n## s\n- **操作**: `#btn` を押す",
                                          fallbackTitle: "t")
        XCTAssertEqual(draft.scenes[0].action, ["#btn を押す"])
    }
}
