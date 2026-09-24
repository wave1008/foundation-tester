import SwiftSyntax
import SwiftSyntaxMacroExpansion
import SwiftSyntaxMacros
import SwiftSyntaxMacrosTestSupport
import XCTest
@testable import FTDSLMacros

final class FTCommandMacroTests: XCTestCase {
    let macros: [String: MacroSpec] = [
        "FTCommand": MacroSpec(type: FTCommandMacro.self),
    ]

    /// 展開は何も生成しない(マーカーのみ)
    func testトップレベル関数への付与は何も生成しない() {
        assertMacroExpansion(
            """
            @FTCommand("ログインしてホームまで進む")
            func login(user: String, password: String) {
            }
            """,
            expandedSource:
            """
            func login(user: String, password: String) {
            }
            """,
            macroSpecs: macros
        )
    }

    /// extension のメソッドも許可される
    func testextensionメソッドへの付与は何も生成しない() {
        assertMacroExpansion(
            """
            extension FTElement {
                @FTCommand("トーストを閉じる")
                func dismissToast(waitSeconds: Double = 3) {
                }
            }
            """,
            expandedSource:
            """
            extension FTElement {
                func dismissToast(waitSeconds: Double = 3) {
                }
            }
            """,
            macroSpecs: macros
        )
    }

    /// func 以外(var)への付与はエラー
    func testfunc以外への付与はエラー() {
        assertMacroExpansion(
            """
            @FTCommand("説明")
            var x = 1
            """,
            expandedSource:
            """
            var x = 1
            """,
            diagnostics: [
                DiagnosticSpec(
                    message: "@FTCommand can only be attached to a func declaration",
                    line: 1, column: 1),
            ],
            macroSpecs: macros
        )
    }

    /// class/struct の直下メソッドはエラー(トップレベル or extension のみ許可)
    func testクラス直下のメソッドへの付与はエラー() {
        assertMacroExpansion(
            """
            class Helpers {
                @FTCommand("説明")
                func login() {
                }
            }
            """,
            expandedSource:
            """
            class Helpers {
                func login() {
                }
            }
            """,
            diagnostics: [
                DiagnosticSpec(
                    message: "@FTCommand can only be attached to a top-level func or a"
                        + " method inside an extension",
                    line: 2, column: 5),
            ],
            macroSpecs: macros
        )
    }

    /// 空文字列の summary はエラー
    func test空のsummaryはエラー() {
        assertMacroExpansion(
            """
            @FTCommand("")
            func login() {
            }
            """,
            expandedSource:
            """
            func login() {
            }
            """,
            diagnostics: [
                DiagnosticSpec(
                    message: "@FTCommand needs a non-empty string literal summary: @FTCommand(\"…\")",
                    line: 1, column: 1),
            ],
            macroSpecs: macros
        )
    }

    /// 引数なしはエラー
    func test引数無しはエラー() {
        assertMacroExpansion(
            """
            @FTCommand
            func login() {
            }
            """,
            expandedSource:
            """
            func login() {
            }
            """,
            diagnostics: [
                DiagnosticSpec(
                    message: "@FTCommand needs a non-empty string literal summary: @FTCommand(\"…\")",
                    line: 1, column: 1),
            ],
            macroSpecs: macros
        )
    }
}
