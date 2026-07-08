// ScenarioSourceEditorTests.swift

import XCTest
@testable import FTCore

final class ScenarioSourceEditorTests: XCTestCase {

    /// explore/convert が生成する典型形(2 クラス、同名メソッド S0010 を両方に持つ)
    private let source = """
    import FTDSL

    @TestClass(app: "com.example.app", platform: "android")
    class ログインテスト {

        @Test("ログインとエラー表示")
        func S0010() {
            scenario {
                scene(1) {
                    condition {
                        launchApp()  // class 内コメント: func S9999() や class Dummy は拾わない
                    }
                }
            }
        }

        @Test
        func S0020() {
            scenario {}
        }
    }

    @TestClass(app: "com.example.app")
    class Network_internet_を開いて {

        @Deleted("旧仕様")
        @Test("「Network & internet」を開いて、「Internet」が表示されることを確認する")
        func S0010() {
            scenario {}
        }
    }
    """

    // MARK: - クラス名

    func testRenameClass() throws {
        let result = try ScenarioSourceEditor.renameClass(
            inSource: source, from: "ログインテスト", to: "ログインテスト2")
        XCTAssertTrue(result.contains("class ログインテスト2 {"))
        XCTAssertFalse(result.contains("class ログインテスト {"))
        // もう一方のクラスは無関係
        XCTAssertTrue(result.contains("class Network_internet_を開いて {"))
    }

    func testRenameClassNotFound() {
        XCTAssertThrowsError(try ScenarioSourceEditor.renameClass(
            inSource: source, from: "存在しない", to: "X"))
    }

    func testRenameClassDuplicateInFile() {
        XCTAssertThrowsError(try ScenarioSourceEditor.renameClass(
            inSource: source, from: "ログインテスト", to: "Network_internet_を開いて"))
    }

    func testRenameClassRejectsInvalidIdentifier() {
        XCTAssertThrowsError(try ScenarioSourceEditor.renameClass(
            inSource: source, from: "ログインテスト", to: "1abc"))
        XCTAssertThrowsError(try ScenarioSourceEditor.renameClass(
            inSource: source, from: "ログインテスト", to: "a b"))
        XCTAssertThrowsError(try ScenarioSourceEditor.renameClass(
            inSource: source, from: "ログインテスト", to: "class"))
    }

    // MARK: - 関数名

    func testRenameMethodScopedToClass() throws {
        // 両クラスに S0010 がある: 2 番目のクラスの方だけを変更する
        let result = try ScenarioSourceEditor.renameMethod(
            inSource: source, className: "Network_internet_を開いて",
            from: "S0010", to: "S0015")
        let first = result.range(of: "class ログインテスト")!
        let second = result.range(of: "class Network_internet_を開いて")!
        let firstBody = result[first.upperBound..<second.lowerBound]
        let secondBody = result[second.upperBound...]
        XCTAssertTrue(firstBody.contains("func S0010()"))  // 1 番目は無傷
        XCTAssertTrue(secondBody.contains("func S0015()"))
        XCTAssertFalse(secondBody.contains("func S0010()"))
    }

    func testRenameMethodDuplicateInClass() {
        XCTAssertThrowsError(try ScenarioSourceEditor.renameMethod(
            inSource: source, className: "ログインテスト", from: "S0010", to: "S0020"))
    }

    func testRenameMethodPrefixIsNotMatched() throws {
        // S0010 のリネームで S0010x のような前方一致を巻き込まない(完全一致のみ)
        let src = source.replacingOccurrences(of: "func S0020", with: "func S0010x")
        let result = try ScenarioSourceEditor.renameMethod(
            inSource: src, className: "ログインテスト", from: "S0010", to: "S0099")
        XCTAssertTrue(result.contains("func S0099()"))
        XCTAssertTrue(result.contains("func S0010x()"))
    }

    // MARK: - @Test の説明

    func testSetTestTitle() throws {
        let result = try ScenarioSourceEditor.setTestTitle(
            inSource: source, className: "ログインテスト", method: "S0010",
            title: "新しい説明")
        XCTAssertTrue(result.contains("@Test(\"新しい説明\")"))
        XCTAssertFalse(result.contains("@Test(\"ログインとエラー表示\")"))
        // 他メソッド・他クラスの @Test は無傷
        XCTAssertTrue(result.contains(
            "@Test(\"「Network & internet」を開いて、「Internet」が表示されることを確認する\")"))
    }

    func testSetTestTitleOnBareTestAttribute() throws {
        // 引数なしの @Test にも説明を付けられる
        let result = try ScenarioSourceEditor.setTestTitle(
            inSource: source, className: "ログインテスト", method: "S0020",
            title: "追加した説明")
        XCTAssertTrue(result.contains("@Test(\"追加した説明\")\n    func S0020()"))
    }

    func testSetTestTitleToEmptyProducesBareAttribute() throws {
        let result = try ScenarioSourceEditor.setTestTitle(
            inSource: source, className: "ログインテスト", method: "S0010", title: "")
        XCTAssertTrue(result.contains("@Test\n    func S0010()"))
    }

    func testSetTestTitleEscapesQuotesAndBackslash() throws {
        let result = try ScenarioSourceEditor.setTestTitle(
            inSource: source, className: "ログインテスト", method: "S0010",
            title: #"引用"符と\記号"#)
        XCTAssertTrue(result.contains(#"@Test("引用\"符と\\記号")"#))
    }

    func testSetTestTitleWithDeletedBetweenAttributeAndFunc() throws {
        // @Deleted が @Test と func の間ではなく前段にあっても、直近の @Test を書き換える
        let result = try ScenarioSourceEditor.setTestTitle(
            inSource: source, className: "Network_internet_を開いて", method: "S0010",
            title: "変更後")
        XCTAssertTrue(result.contains("@Deleted(\"旧仕様\")\n    @Test(\"変更後\")"))
    }

    func testSetTestTitleRejectsMultiline() {
        XCTAssertThrowsError(try ScenarioSourceEditor.setTestTitle(
            inSource: source, className: "ログインテスト", method: "S0010",
            title: "a\nb"))
    }
}
