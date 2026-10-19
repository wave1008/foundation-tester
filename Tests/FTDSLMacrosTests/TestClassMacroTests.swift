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
        "Draft": MacroSpec(type: DraftMacro.self),
    ]

    func test日本語クラスとシナリオの展開() {
        assertMacroExpansion(
            """
            @TestClass
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
            @TestClass(platform: "android")
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
            @TestClass
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
            @TestClass
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
                    message: "@Deleted can only be attached to a test class or a @Test method",
                    line: 1, column: 1),
            ],
            macroSpecs: macros
        )
    }

    func testDraftクラスは全シナリオが実装中() {
        assertMacroExpansion(
            """
            @Draft("未実装")
            @TestClass
            class 新テスト {
                @Test
                func S0010() {
                }
            }
            """,
            expandedSource:
            """
            class 新テスト {
                func S0010() {
                }
            }

            final class __FTReg_新テスト: FTDSL.FTScenarioRegistration {
                override class var descriptor: FTDSL.FTTestClassDescriptor {
                    新テスト.ftDescriptor
                }
            }

            extension 新テスト: FTDSL.FTTestClassDefinition {
                public static var ftDescriptor: FTDSL.FTTestClassDescriptor {
                    FTDSL.FTTestClassDescriptor(
                        className: "新テスト",
                        platform: nil,
                        scenarios: [
                        FTDSL.FTScenarioDescriptor(
                            name: "S0010",
                            title: "",
                            draft: true,
                            run: {
                                新テスト().S0010()
                            }),
                        ])
                }
            }
            """,
            macroSpecs: macros
        )
    }

    func testDraftメソッドは当該シナリオのみ実装中() {
        assertMacroExpansion(
            """
            @TestClass
            class 混在 {
                @Test
                func S0010() {
                }
                @Draft
                @Test("実装中")
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
                            title: "実装中",
                            draft: true,
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

    func testDraftをクラスとメソッド以外へ付与はエラー() {
        assertMacroExpansion(
            """
            @Draft
            var x = 1
            """,
            expandedSource:
            """
            var x = 1
            """,
            diagnostics: [
                DiagnosticSpec(
                    message: "@Draft can only be attached to a test class or a @Test method",
                    line: 1, column: 1),
            ],
            macroSpecs: macros
        )
    }

    func testクラス以外への付与はエラー() {
        assertMacroExpansion(
            """
            @TestClass
            struct テスト {
            }
            """,
            expandedSource:
            """
            struct テスト {
            }
            """,
            diagnostics: [
                DiagnosticSpec(message: "@TestClass can only be attached to a class", line: 1, column: 1),
            ],
            macroSpecs: macros
        )
    }

    func testシグネチャ違反のシナリオはエラー() {
        assertMacroExpansion(
            """
            @TestClass
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
                        platform: nil,
                        scenarios: [

                        ])
                }
            }
            """,
            diagnostics: [
                DiagnosticSpec(
                    message: "@Test methods must take no arguments and be neither async nor throws: func 悪い()",
                    line: 4, column: 10),
            ],
            macroSpecs: macros
        )
    }
    func testBeforeEachとAfterEachがrunに織り込まれる() {
        assertMacroExpansion(
            """
            @TestClass
            class T {
                func beforeEach() {
                }
                func afterEach() {
                }
                @Test("t")
                func S0010() {
                }
            }
            """,
            expandedSource:
            """
            class T {
                func beforeEach() {
                }
                func afterEach() {
                }
                func S0010() {
                }
            }

            final class __FTReg_T: FTDSL.FTScenarioRegistration {
                override class var descriptor: FTDSL.FTTestClassDescriptor {
                    T.ftDescriptor
                }
            }

            extension T: FTDSL.FTTestClassDefinition {
                public static var ftDescriptor: FTDSL.FTTestClassDescriptor {
                    FTDSL.FTTestClassDescriptor(
                        className: "T",
                        platform: nil,
                        scenarios: [
                        FTDSL.FTScenarioDescriptor(
                            name: "S0010",
                            title: "t",
                            run: {
                                let ftInstance = T();
                                FTDSL.ftRunBeforeEach {
                                    ftInstance.beforeEach()
                                };
                                ftInstance.S0010();
                                FTDSL.ftRunAfterEach {
                                    ftInstance.afterEach()
                                }
                            }),
                        ])
                }
            }
            """,
            macroSpecs: macros
        )
    }

    func testSetUpDeviceはbeforeEachの前に織り込まれる() {
        assertMacroExpansion(
            """
            @TestClass
            class T {
                func setUpDevice() {
                }
                @Test("t")
                func S0010() {
                }
            }
            """,
            expandedSource:
            """
            class T {
                func setUpDevice() {
                }
                func S0010() {
                }
            }

            final class __FTReg_T: FTDSL.FTScenarioRegistration {
                override class var descriptor: FTDSL.FTTestClassDescriptor {
                    T.ftDescriptor
                }
            }

            extension T: FTDSL.FTTestClassDefinition {
                public static var ftDescriptor: FTDSL.FTTestClassDescriptor {
                    FTDSL.FTTestClassDescriptor(
                        className: "T",
                        platform: nil,
                        scenarios: [
                        FTDSL.FTScenarioDescriptor(
                            name: "S0010",
                            title: "t",
                            run: {
                                let ftInstance = T();
                                FTDSL.ftRunSetUpDevice {
                                    ftInstance.setUpDevice()
                                };
                                ftInstance.S0010()
                            }),
                        ])
                }
            }
            """,
            macroSpecs: macros
        )
    }

    /// tearDownDevice はシナリオの run に入らず、descriptor の欄になる(親が専用の子で呼ぶ)
    /// afterAll は run クロージャに入れず、descriptor の欄になる(親が run の最後に専用の子で呼ぶ)
    func testAfterAllはdescriptorの欄になりrunには入らない() {
        assertMacroExpansion(
            """
            @TestClass
            class T {
                func afterAll() {
                }
                @Test("t")
                func S0010() {
                }
            }
            """,
            expandedSource:
            """
            class T {
                func afterAll() {
                }
                func S0010() {
                }
            }

            final class __FTReg_T: FTDSL.FTScenarioRegistration {
                override class var descriptor: FTDSL.FTTestClassDescriptor {
                    T.ftDescriptor
                }
            }

            extension T: FTDSL.FTTestClassDefinition {
                public static var ftDescriptor: FTDSL.FTTestClassDescriptor {
                    FTDSL.FTTestClassDescriptor(
                        className: "T",
                        platform: nil,
                        scenarios: [
                        FTDSL.FTScenarioDescriptor(
                            name: "S0010",
                            title: "t",
                            run: {
                                T().S0010()
                            }),
                        ],
                        afterAll: {
                            let ftInstance = T();
                            FTDSL.ftRunAfterAll {
                                ftInstance.afterAll()
                            }
                        })
                }
            }
            """,
            macroSpecs: macros
        )
    }

    /// beforeAll は run の最初(setUpDevice より前)に織り込まれ、descriptor に印が付く(親が一覧で知り、他のデバイスを待たせる)
    func testBeforeAllはsetUpDeviceの前に織り込まれdescriptorに印が付く() {
        assertMacroExpansion(
            """
            @TestClass
            class T {
                func beforeAll() {
                }
                func setUpDevice() {
                }
                @Test("t")
                func S0010() {
                }
            }
            """,
            expandedSource:
            """
            class T {
                func beforeAll() {
                }
                func setUpDevice() {
                }
                func S0010() {
                }
            }

            final class __FTReg_T: FTDSL.FTScenarioRegistration {
                override class var descriptor: FTDSL.FTTestClassDescriptor {
                    T.ftDescriptor
                }
            }

            extension T: FTDSL.FTTestClassDefinition {
                public static var ftDescriptor: FTDSL.FTTestClassDescriptor {
                    FTDSL.FTTestClassDescriptor(
                        className: "T",
                        platform: nil,
                        scenarios: [
                        FTDSL.FTScenarioDescriptor(
                            name: "S0010",
                            title: "t",
                            run: {
                                let ftInstance = T();
                                FTDSL.ftRunBeforeAll {
                                    ftInstance.beforeAll()
                                };
                                FTDSL.ftRunSetUpDevice {
                                    ftInstance.setUpDevice()
                                };
                                ftInstance.S0010()
                            }),
                        ],
                        hasBeforeAll: true)
                }
            }
            """,
            macroSpecs: macros
        )
    }

    func testTearDownDeviceはdescriptorの欄になりrunには入らない() {
        assertMacroExpansion(
            """
            @TestClass
            class T {
                func tearDownDevice() {
                }
                @Test("t")
                func S0010() {
                }
            }
            """,
            expandedSource:
            """
            class T {
                func tearDownDevice() {
                }
                func S0010() {
                }
            }

            final class __FTReg_T: FTDSL.FTScenarioRegistration {
                override class var descriptor: FTDSL.FTTestClassDescriptor {
                    T.ftDescriptor
                }
            }

            extension T: FTDSL.FTTestClassDefinition {
                public static var ftDescriptor: FTDSL.FTTestClassDescriptor {
                    FTDSL.FTTestClassDescriptor(
                        className: "T",
                        platform: nil,
                        scenarios: [
                        FTDSL.FTScenarioDescriptor(
                            name: "S0010",
                            title: "t",
                            run: {
                                T().S0010()
                            }),
                        ],
                        tearDownDevice: {
                            let ftInstance = T();
                            FTDSL.ftRunTearDownDevice {
                                ftInstance.tearDownDevice()
                            }
                        })
                }
            }
            """,
            macroSpecs: macros
        )
    }

    /// @Test(platform:) はメソッド単位の対象OS宣言(クラスの platform: より優先)
    func testTestのplatform引数が展開される() {
        assertMacroExpansion(
            """
            @TestClass(platform: "ios")
            class T {
                @Test("t", platform: "android")
                func S0010() {
                }
            }
            """,
            expandedSource:
            """
            class T {
                func S0010() {
                }
            }

            final class __FTReg_T: FTDSL.FTScenarioRegistration {
                override class var descriptor: FTDSL.FTTestClassDescriptor {
                    T.ftDescriptor
                }
            }

            extension T: FTDSL.FTTestClassDefinition {
                public static var ftDescriptor: FTDSL.FTTestClassDescriptor {
                    FTDSL.FTTestClassDescriptor(
                        className: "T",
                        platform: "ios",
                        scenarios: [
                        FTDSL.FTScenarioDescriptor(
                            name: "S0010",
                            title: "t",
                            platform: "android",
                            run: {
                                T().S0010()
                            }),
                        ])
                }
            }
            """,
            macroSpecs: macros
        )
    }

    // @Test(scenarioTimeout:) はメソッド単位の打ち切り秒(式は verbatim 転写)

    func testTestのscenarioTimeout引数が展開される() {
        assertMacroExpansion(
            """
            @TestClass
            class T {
                @Test("t", scenarioTimeout: 1800)
                func S0010() {
                }
            }
            """,
            expandedSource:
            """
            class T {
                func S0010() {
                }
            }

            final class __FTReg_T: FTDSL.FTScenarioRegistration {
                override class var descriptor: FTDSL.FTTestClassDescriptor {
                    T.ftDescriptor
                }
            }

            extension T: FTDSL.FTTestClassDefinition {
                public static var ftDescriptor: FTDSL.FTTestClassDescriptor {
                    FTDSL.FTTestClassDescriptor(
                        className: "T",
                        platform: nil,
                        scenarios: [
                        FTDSL.FTScenarioDescriptor(
                            name: "S0010",
                            title: "t",
                            scenarioTimeout: 1800,
                            run: {
                                T().S0010()
                            }),
                        ])
                }
            }
            """,
            macroSpecs: macros
        )
    }

    func testTestのscenarioTimeout省略時は欄を出さない() {
        assertMacroExpansion(
            """
            @TestClass
            class T {
                @Test("t")
                func S0010() {
                }
            }
            """,
            expandedSource:
            """
            class T {
                func S0010() {
                }
            }

            final class __FTReg_T: FTDSL.FTScenarioRegistration {
                override class var descriptor: FTDSL.FTTestClassDescriptor {
                    T.ftDescriptor
                }
            }

            extension T: FTDSL.FTTestClassDefinition {
                public static var ftDescriptor: FTDSL.FTTestClassDescriptor {
                    FTDSL.FTTestClassDescriptor(
                        className: "T",
                        platform: nil,
                        scenarios: [
                        FTDSL.FTScenarioDescriptor(
                            name: "S0010",
                            title: "t",
                            run: {
                                T().S0010()
                            }),
                        ])
                }
            }
            """,
            macroSpecs: macros
        )
    }

    func testTestのscenarioTimeoutリテラル以外の式は転写される() {
        assertMacroExpansion(
            """
            @TestClass
            class T {
                @Test("t", scenarioTimeout: limits.long)
                func S0010() {
                }
            }
            """,
            expandedSource:
            """
            class T {
                func S0010() {
                }
            }

            final class __FTReg_T: FTDSL.FTScenarioRegistration {
                override class var descriptor: FTDSL.FTTestClassDescriptor {
                    T.ftDescriptor
                }
            }

            extension T: FTDSL.FTTestClassDefinition {
                public static var ftDescriptor: FTDSL.FTTestClassDescriptor {
                    FTDSL.FTTestClassDescriptor(
                        className: "T",
                        platform: nil,
                        scenarios: [
                        FTDSL.FTScenarioDescriptor(
                            name: "S0010",
                            title: "t",
                            scenarioTimeout: limits.long,
                            run: {
                                T().S0010()
                            }),
                        ])
                }
            }
            """,
            macroSpecs: macros
        )
    }

    func testTestのscenarioTimeoutが0はエラー() {
        assertMacroExpansion(
            """
            @TestClass
            class T {
                @Test("t", scenarioTimeout: 0)
                func S0010() {
                }
            }
            """,
            expandedSource:
            """
            class T {
                func S0010() {
                }
            }

            final class __FTReg_T: FTDSL.FTScenarioRegistration {
                override class var descriptor: FTDSL.FTTestClassDescriptor {
                    T.ftDescriptor
                }
            }

            extension T: FTDSL.FTTestClassDefinition {
                public static var ftDescriptor: FTDSL.FTTestClassDescriptor {
                    FTDSL.FTTestClassDescriptor(
                        className: "T",
                        platform: nil,
                        scenarios: [
                        FTDSL.FTScenarioDescriptor(
                            name: "S0010",
                            title: "t",
                            scenarioTimeout: 0,
                            run: {
                                T().S0010()
                            }),
                        ])
                }
            }
            """,
            diagnostics: [
                DiagnosticSpec(
                    message: "@Test scenarioTimeout must be a positive number of seconds (got 0)",
                    line: 3, column: 33),
            ],
            macroSpecs: macros
        )
    }

    func testTestのscenarioTimeoutが負はエラー() {
        assertMacroExpansion(
            """
            @TestClass
            class T {
                @Test("t", scenarioTimeout: -5)
                func S0010() {
                }
            }
            """,
            expandedSource:
            """
            class T {
                func S0010() {
                }
            }

            final class __FTReg_T: FTDSL.FTScenarioRegistration {
                override class var descriptor: FTDSL.FTTestClassDescriptor {
                    T.ftDescriptor
                }
            }

            extension T: FTDSL.FTTestClassDefinition {
                public static var ftDescriptor: FTDSL.FTTestClassDescriptor {
                    FTDSL.FTTestClassDescriptor(
                        className: "T",
                        platform: nil,
                        scenarios: [
                        FTDSL.FTScenarioDescriptor(
                            name: "S0010",
                            title: "t",
                            scenarioTimeout: -5,
                            run: {
                                T().S0010()
                            }),
                        ])
                }
            }
            """,
            diagnostics: [
                DiagnosticSpec(
                    message: "@Test scenarioTimeout must be a positive number of seconds (got -5)",
                    line: 3, column: 33),
            ],
            macroSpecs: macros
        )
    }
}
