// SharedStateDiagnostics(テストクラスのプロパティで別プロセス間の受け渡しを試みる形の警告)。
// 出すべき形・出してはいけない形を両方固定する(片方だけだと「常に空」「常に出す」の変異が生き残る)。

import SwiftParser
import SwiftSyntaxMacroExpansion
import SwiftSyntaxMacrosTestSupport
import SwiftSyntax
import XCTest
@testable import FTDSLMacros

final class SharedStateDiagnosticsTests: XCTestCase {

    private func findings(_ source: String, tests: Set<String> = ["S0010", "S0020"])
        -> [SharedStateDiagnostics.Finding] {
        let file = Parser.parse(source: source)
        guard let cls = file.statements.compactMap({ $0.item.as(ClassDeclSyntax.self) }).first else {
            XCTFail("no class in source")
            return []
        }
        return SharedStateDiagnostics.findings(in: cls, className: cls.name.text, testMethods: tests)
    }

    private func summary(_ found: [SharedStateDiagnostics.Finding]) -> [String] {
        found.map { "\($0.property): \($0.writer.display) -> \($0.readers.map(\.display).joined(separator: ","))" }
    }

    func testWrittenInOneTestAndReadInAnother() {
        let found = findings("""
        class T {
            var orderID = ""
            func S0010() { orderID = "A-1" }
            func S0020() { use(orderID) }
        }
        """)
        XCTAssertEqual(summary(found), ["orderID: S0010() -> S0020()"])
        XCTAssertEqual(found.first?.message,
                       "`orderID` is written in S0010() but read in S0020(): every @Test runs in its own process,"
                           + " so the value does not carry over. Share the value with writeMemo / readMemo")
    }

    func testWrittenInSetUpDeviceAndReadInTests() {
        let found = findings("""
        class T {
            var token: String?
            func setUpDevice() { self.token = "t" }
            func beforeEach() { use(token ?? "") }
            func S0010() { use(self.token ?? "") }
        }
        """)
        XCTAssertEqual(summary(found), ["token: setUpDevice() -> beforeEach(),S0010()"])
        XCTAssertTrue(found.first?.message.contains("setUpDevice() runs only before the first @Test") == true)
    }

    func testStaticVarCompoundAssignmentAcrossTests() {
        XCTAssertEqual(summary(findings("""
        class T {
            static var count = 0
            func S0010() { Self.count += 1 }
            func S0020() { use(T.count) }
        }
        """)), ["count: S0010() -> S0020()"])
    }

    func testWrittenInAfterEachOrReadInTearDownDevice() {
        XCTAssertEqual(summary(findings("""
        class T {
            var last = ""
            var created = ""
            func afterEach() { last = "x" }
            func S0010() { use(last); created = "u1" }
            func tearDownDevice() { use(created) }
        }
        """)), ["created: S0010() -> tearDownDevice()", "last: afterEach() -> S0010()"])
    }

    /// 同じプロセスで後に走る部分への受け渡しは正しく動くので出さない。
    /// beforeEach で初期化して S0020 が書き換えても、S0010 は beforeEach の値を読んでいる(当てにしていない)
    func testSameProcessFlowsAreNotFlagged() {
        XCTAssertEqual(summary(findings("""
        class T {
            var name = ""
            var seen = 0
            func beforeEach() { name = "a" }
            func S0010() { use(name); seen += 1; use(seen) }
            func S0020() { name = "b"; use(name) }
            func afterEach() { use(name, seen) }
            func setUpDevice() { var local = 1; local += 1 }
        }
        """)), [])
    }

    /// let・計算プロパティ・同名のローカル・別の物のメンバ・ヘルパー関数は対象外
    func testNonStoredOrShadowedOrHelperAreNotFlagged() {
        XCTAssertEqual(summary(findings("""
        class T {
            let fixed = "x"
            var computed: String { "c" }
            var shadow = ""
            var viaHelper = ""
            func S0010() {
                self.shadow = "written"
                use(fixed, computed)
                other.viaHelper = "y"
                helper()
            }
            func S0020() {
                let shadow = "local"
                use(shadow)
                [1].forEach { shadow in use(shadow) }
                use(viaHelper)
            }
            func helper() { viaHelper = "h" }
        }
        """)), [])
    }

    func testVisibilityTable() {
        typealias R = SharedStateDiagnostics.Role
        let visible: [(R, R)] = [(.beforeEach, .test("A")), (.beforeEach, .afterEach), (.test("A"), .afterEach),
                                 (.test("A"), .test("A")), (.setUpDevice, .setUpDevice)]
        let hidden: [(R, R)] = [(.test("A"), .test("B")), (.setUpDevice, .test("A")), (.setUpDevice, .beforeEach),
                                (.afterEach, .beforeEach), (.test("A"), .tearDownDevice),
                                (.beforeEach, .tearDownDevice), (.tearDownDevice, .test("A")),
                                (.test("A"), .beforeEach)]
        for (w, r) in visible { XCTAssertTrue(SharedStateDiagnostics.visible(write: w, read: r), "\(w) -> \(r)") }
        for (w, r) in hidden { XCTAssertFalse(SharedStateDiagnostics.visible(write: w, read: r), "\(w) -> \(r)") }
    }
}

/// @TestClass の展開から警告が実際に出る(解析だけ緑で配線が外れている形を落とす)
final class SharedStateDiagnosticsWiringTests: XCTestCase {
    func testTestClassMacroEmitsTheWarning() {
        assertMacroExpansion(
            """
            @TestClass(app: "com.app")
            class T {
                var x = ""
                @Test("a")
                func S0010() {
                    x = "1"
                }
                @Test("b")
                func S0020() {
                    use(x)
                }
            }
            """,
            expandedSource:
            """
            class T {
                var x = ""
                func S0010() {
                    x = "1"
                }
                func S0020() {
                    use(x)
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
                        app: "com.app",
                        platform: nil,
                        scenarios: [
                        FTDSL.FTScenarioDescriptor(
                            name: "S0010",
                            title: "a",
                            run: {
                                T().S0010()
                            }),
                        FTDSL.FTScenarioDescriptor(
                            name: "S0020",
                            title: "b",
                            run: {
                                T().S0020()
                            }),
                        ])
                }
            }
            """,
            diagnostics: [
                DiagnosticSpec(
                    message: "`x` is written in S0010() but read in S0020(): every @Test runs in its own process,"
                        + " so the value does not carry over. Share the value with writeMemo / readMemo",
                    line: 6, column: 9, severity: .warning),
            ],
            macroSpecs: [
                "TestClass": MacroSpec(type: TestClassMacro.self, conformances: ["FTDSL.FTTestClassDefinition"]),
                "Test": MacroSpec(type: TestMacro.self),
            ]
        )
    }
}
