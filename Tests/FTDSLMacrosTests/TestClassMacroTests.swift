import SwiftSyntax
import SwiftSyntaxMacroExpansion
import SwiftSyntaxMacros
import SwiftSyntaxMacrosTestSupport
import XCTest
@testable import FTDSLMacros

final class TestClassMacroTests: XCTestCase {
    // MacroSpec で conformances を渡さないと extension ロールの protocols が空になり、
    // 「手書き conformance 済み」と判定されて extension が生成されない(実コンパイルでは渡される)
    let macros: [String: MacroSpec] = [
        "TestClass": MacroSpec(type: TestClassMacro.self,
                               conformances: ["FTDSL.FTTestClassDefinition"]),
        "Test": MacroSpec(type: TestMacro.self),
        "Deleted": MacroSpec(type: DeletedMacro.self),
    ]

    func test日本語クラスとシナリオの展開() {
        assertMacroExpansion(
            """
            @TestClass(app: "com.example.sampleapp")
            class ログインテスト {
                @Test("ログインとエラー表示")
                func ログイン() {
                }
            }
            """,
            expandedSource:
            """
            class ログインテスト {
                func ログイン() {
                }
            }

            final class __FTReg_ログインテスト: FTDSL.FTScenarioRegistration {
                override class var descriptor: FTDSL.FTTestClassDescriptor {
                    ログインテスト.ftDescriptor
                }
            }

            extension ログインテスト: FTDSL.FTTestClassDefinition {
                public static var ftDescriptor: FTDSL.FTTestClassDescriptor {
                    FTDSL.FTTestClassDescriptor(
                        className: "ログインテスト",
                        app: "com.example.sampleapp",
                        platform: nil,
                        scenarios: [
                        FTDSL.FTScenarioDescriptor(
                            name: "ログイン",
                            title: "ログインとエラー表示",
                            run: {
                                ログインテスト().ログイン()
                            }),
                        ])
                }
            }
            """,
            macroSpecs: macros
        )
    }

    func testPlatform指定と複数シナリオ() {
        assertMacroExpansion(
            """
            @TestClass(app: "com.app", platform: "android")
            class 設定 {
                @Test
                func 到達() {
                }
                func ヘルパー() {
                }
                @Test("2本目")
                func 変更() {
                }
            }
            """,
            expandedSource:
            """
            class 設定 {
                func 到達() {
                }
                func ヘルパー() {
                }
                func 変更() {
                }
            }

            final class __FTReg_設定: FTDSL.FTScenarioRegistration {
                override class var descriptor: FTDSL.FTTestClassDescriptor {
                    設定.ftDescriptor
                }
            }

            extension 設定: FTDSL.FTTestClassDefinition {
                public static var ftDescriptor: FTDSL.FTTestClassDescriptor {
                    FTDSL.FTTestClassDescriptor(
                        className: "設定",
                        app: "com.app",
                        platform: "android",
                        scenarios: [
                        FTDSL.FTScenarioDescriptor(
                            name: "到達",
                            title: "",
                            run: {
                                設定().到達()
                            }),
                        FTDSL.FTScenarioDescriptor(
                            name: "変更",
                            title: "2本目",
                            run: {
                                設定().変更()
                            }),
                        ])
                }
            }
            """,
            macroSpecs: macros
        )
    }

    func testDeletedクラスは全シナリオが削除済み() {
        assertMacroExpansion(
            """
            @Deleted("旧UIのため")
            @TestClass(app: "com.app")
            class 旧テスト {
                @Test
                func S0010() {
                }
            }
            """,
            expandedSource:
            """
            class 旧テスト {
                func S0010() {
                }
            }

            final class __FTReg_旧テスト: FTDSL.FTScenarioRegistration {
                override class var descriptor: FTDSL.FTTestClassDescriptor {
                    旧テスト.ftDescriptor
                }
            }

            extension 旧テスト: FTDSL.FTTestClassDefinition {
                public static var ftDescriptor: FTDSL.FTTestClassDescriptor {
                    FTDSL.FTTestClassDescriptor(
                        className: "旧テスト",
                        app: "com.app",
                        platform: nil,
                        scenarios: [
                        FTDSL.FTScenarioDescriptor(
                            name: "S0010",
                            title: "",
                            deleted: true,
                            run: {
                                旧テスト().S0010()
                            }),
                        ])
                }
            }
            """,
            macroSpecs: macros
        )
    }

    func testDeletedメソッドは当該シナリオのみ削除済み() {
        assertMacroExpansion(
            """
            @TestClass(app: "com.app")
            class 混在 {
                @Test
                func S0010() {
                }
                @Deleted
                @Test("古い")
                func S0020() {
                }
            }
            """,
            expandedSource:
            """
            class 混在 {
                func S0010() {
                }
                func S0020() {
                }
            }

            final class __FTReg_混在: FTDSL.FTScenarioRegistration {
                override class var descriptor: FTDSL.FTTestClassDescriptor {
                    混在.ftDescriptor
                }
            }

            extension 混在: FTDSL.FTTestClassDefinition {
                public static var ftDescriptor: FTDSL.FTTestClassDescriptor {
                    FTDSL.FTTestClassDescriptor(
                        className: "混在",
                        app: "com.app",
                        platform: nil,
                        scenarios: [
                        FTDSL.FTScenarioDescriptor(
                            name: "S0010",
                            title: "",
                            run: {
                                混在().S0010()
                            }),
                        FTDSL.FTScenarioDescriptor(
                            name: "S0020",
                            title: "古い",
                            deleted: true,
                            run: {
                                混在().S0020()
                            }),
                        ])
                }
            }
            """,
            macroSpecs: macros
        )
    }

    func testDeletedをクラスとメソッド以外へ付与はエラー() {
        assertMacroExpansion(
            """
            @Deleted
            var x = 1
            """,
            expandedSource:
            """
            var x = 1
            """,
            diagnostics: [
                DiagnosticSpec(
                    message: "@Deleted はテストクラスまたは @Test メソッドにのみ付与できます",
                    line: 1, column: 1),
            ],
            macroSpecs: macros
        )
    }

    func testクラス以外への付与はエラー() {
        assertMacroExpansion(
            """
            @TestClass(app: "com.app")
            struct テスト {
            }
            """,
            expandedSource:
            """
            struct テスト {
            }
            """,
            diagnostics: [
                DiagnosticSpec(message: "@TestClass は class にのみ付与できます", line: 1, column: 1),
            ],
            macroSpecs: macros
        )
    }

    func testシグネチャ違反のシナリオはエラー() {
        assertMacroExpansion(
            """
            @TestClass(app: "com.app")
            class テスト {
                @Test("x")
                func 悪い(値: Int) {
                }
            }
            """,
            expandedSource:
            """
            class テスト {
                func 悪い(値: Int) {
                }
            }

            final class __FTReg_テスト: FTDSL.FTScenarioRegistration {
                override class var descriptor: FTDSL.FTTestClassDescriptor {
                    テスト.ftDescriptor
                }
            }

            extension テスト: FTDSL.FTTestClassDefinition {
                public static var ftDescriptor: FTDSL.FTTestClassDescriptor {
                    FTDSL.FTTestClassDescriptor(
                        className: "テスト",
                        app: "com.app",
                        platform: nil,
                        scenarios: [

                        ])
                }
            }
            """,
            diagnostics: [
                DiagnosticSpec(
                    message: "@Test メソッドは引数なし・非async・非throws で宣言してください: func 悪い()",
                    line: 4, column: 10),
            ],
            macroSpecs: macros
        )
    }
}
