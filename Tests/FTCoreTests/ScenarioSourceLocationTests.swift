// ScenarioSourceLocationTests.swift
// ScenarioSourceEditor.classDeclarationLine / methodDeclarationLine のテスト
// (VSCode拡張向け API `ftester api list-scenarios` のソース位置解決に使う)。

import XCTest
@testable import FTCore

final class ScenarioSourceLocationTests: XCTestCase {

    /// 日本語クラス名・メソッド名、@TestClass・@Test・@Deleted 属性、修飾子付き(public final)
    /// クラス宣言、同名 func(S0010)が別クラスに存在するケースを一通り含む
    private let source = """
    import FTDSL

    @TestClass(app: "com.example.app", platform: "android")
    class ログインテスト {

        @Test("ログインとエラー表示")
        func S0010() {
            scenario {}
        }

        @Deleted("旧仕様")
        @Test
        func S0020() {
            scenario {}
        }
    }

    @TestClass(app: "com.example.app")
    public final class Network_internet_を開いて {

        @Test("「Network & internet」を開いて確認する")
        func S0010() {
            scenario {}
        }
    }
    """

    private func lineNumber(containing text: String, in source: String) -> Int {
        source.components(separatedBy: "\n").firstIndex(where: { $0.contains(text) })! + 1
    }

    private func lineNumbers(containing text: String, in source: String) -> [Int] {
        source.components(separatedBy: "\n").enumerated()
            .filter { $0.element.contains(text) }
            .map { $0.offset + 1 }
    }

    // MARK: - classDeclarationLine

    func testClassDeclarationLineJapaneseName() {
        let expected = lineNumber(containing: "class ログインテスト {", in: source)
        XCTAssertEqual(
            ScenarioSourceEditor.classDeclarationLine(inSource: source, className: "ログインテスト"),
            expected)
    }

    func testClassDeclarationLineWithModifiersAndJapaneseName() {
        // public final 修飾子付きでも宣言行を検出できる
        let expected = lineNumber(
            containing: "public final class Network_internet_を開いて {", in: source)
        XCTAssertEqual(
            ScenarioSourceEditor.classDeclarationLine(
                inSource: source, className: "Network_internet_を開いて"),
            expected)
    }

    func testClassDeclarationLineNotFound() {
        XCTAssertNil(
            ScenarioSourceEditor.classDeclarationLine(inSource: source, className: "存在しない"))
    }

    // MARK: - methodDeclarationLine

    func testMethodDeclarationLineWithTestAttribute() {
        let matches = lineNumbers(containing: "func S0010() {", in: source)
        XCTAssertEqual(
            ScenarioSourceEditor.methodDeclarationLine(
                inSource: source, className: "ログインテスト", method: "S0010"),
            matches[0])
    }

    func testMethodDeclarationLineWithDeletedAndBareTestAttribute() {
        // @Deleted + 引数なし @Test が前置されていても func 宣言行を検出できる
        let expected = lineNumber(containing: "func S0020() {", in: source)
        XCTAssertEqual(
            ScenarioSourceEditor.methodDeclarationLine(
                inSource: source, className: "ログインテスト", method: "S0020"),
            expected)
    }

    func testMethodDeclarationLineScopedToClassDoesNotMatchOtherClass() {
        // 両クラスに同名 func(S0010)がある: それぞれ自クラス内の宣言行を返し、取り違えない
        let matches = lineNumbers(containing: "func S0010() {", in: source)
        XCTAssertEqual(matches.count, 2, "テストソースの前提が崩れていないか確認")
        XCTAssertEqual(
            ScenarioSourceEditor.methodDeclarationLine(
                inSource: source, className: "ログインテスト", method: "S0010"),
            matches[0])
        XCTAssertEqual(
            ScenarioSourceEditor.methodDeclarationLine(
                inSource: source, className: "Network_internet_を開いて", method: "S0010"),
            matches[1])
    }

    func testMethodDeclarationLineNotFoundInClass() {
        XCTAssertNil(ScenarioSourceEditor.methodDeclarationLine(
            inSource: source, className: "ログインテスト", method: "存在しない"))
    }

    func testMethodDeclarationLineClassNotFound() {
        XCTAssertNil(ScenarioSourceEditor.methodDeclarationLine(
            inSource: source, className: "存在しないクラス", method: "S0010"))
    }

    func testMethodDeclarationLineWithModifiers() {
        // public final 等の修飾子付き func 宣言も検出できる(declPrefix の対応範囲)
        let modifierSource = """
        class C {
            public final func run() {
                scenario {}
            }
        }
        """
        XCTAssertEqual(
            ScenarioSourceEditor.methodDeclarationLine(
                inSource: modifierSource, className: "C", method: "run"),
            2)
    }
}
