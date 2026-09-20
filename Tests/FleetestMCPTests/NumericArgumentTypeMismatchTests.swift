// 2026-09-20 の負荷テストの実測: MCP クライアントは JSON Schema が integer/number でも、
// 実際には数値を文字列で送ってくる("ref": "8" 等)。直読み(`args["…"] as? Int`)はこれを
// 黙って nil に潰すので、呼び手は型の問題に気づけないまま次の一手(ft_tap の ref → x/y
// フォールバックのような、より危険な経路)へ落ちる。ここでは MCPServer.intArgument/
// doubleArgument(MCPServer.swift)が文字列などの別型を **断る**(寛容に解釈しない)ことと、
// 正しい型は従来どおり通ることの両方を固定する。

import XCTest
import FTCore
@testable import fleetest_mcp

final class NumericArgumentTypeMismatchTests: XCTestCase {

    private var driver: FakeDriver!
    private var server: MCPServer!

    override func setUp() {
        super.setUp()
        driver = FakeDriver()
        let fake = driver!
        server = MCPServer(write: { _ in }, makeDriver: { _ in fake },
                           recordSnapshot: { _, _, _ in })
    }

    // MARK: - intArgument/doubleArgument(型ゲートそのもの)

    func testIntArgumentRejectsAQuotedNumber() {
        XCTAssertThrowsError(try MCPServer.intArgument(["ref": "8"], "ref")) { error in
            let message = error.localizedDescription
            XCTAssertTrue(message.contains("ref must be an integer"), message)
            XCTAssertTrue(message.contains("the string \"8\""), message)
        }
    }

    func testIntArrayArgumentRejectsAQuotedElement() {
        XCTAssertThrowsError(try MCPServer.intArrayArgument(["drop": [1, "2", 3]], "drop")) { error in
            let message = error.localizedDescription
            XCTAssertTrue(message.contains("drop[1] must be an integer"), message)
            XCTAssertTrue(message.contains("the string \"2\""), message)
        }
    }

    func testIntArrayArgumentRejectsANonArray() {
        XCTAssertThrowsError(try MCPServer.intArrayArgument(["scenes": "3"], "scenes")) { error in
            let message = error.localizedDescription
            XCTAssertTrue(message.contains("scenes must be an array of integers"), message)
            XCTAssertTrue(message.contains("the string \"3\""), message)
        }
    }

    func testIntArrayArgumentPassesThroughAProperArray() throws {
        XCTAssertEqual(try MCPServer.intArrayArgument(["drop": [2, 5]], "drop"), [2, 5])
        XCTAssertEqual(try MCPServer.intArrayArgument(["drop": []], "drop"), [])
        XCTAssertNil(try MCPServer.intArrayArgument([:], "drop"))
    }

    func testDoubleArgumentRejectsAQuotedNumber() {
        XCTAssertThrowsError(try MCPServer.doubleArgument(["x": "200"], "x")) { error in
            let message = error.localizedDescription
            XCTAssertTrue(message.contains("x must be a number"), message)
            XCTAssertTrue(message.contains("the string \"200\""), message)
        }
    }

    func testIntArgumentAcceptsAnActualInteger() throws {
        XCTAssertEqual(try MCPServer.intArgument(["ref": 8], "ref"), 8)
    }

    func testDoubleArgumentAcceptsAnActualNumber() throws {
        XCTAssertEqual(try MCPServer.doubleArgument(["x": 200.0], "x"), 200.0)
    }

    func testBothHelpersReturnNilWhenTheKeyIsAbsent() throws {
        XCTAssertNil(try MCPServer.intArgument([:], "ref"))
        XCTAssertNil(try MCPServer.doubleArgument([:], "x"))
    }

    /// **文字列以外の別型も同じ規律で断る**(ブール・配列)
    func testIntArgumentRejectsNonStringNonNumericTypesToo() {
        XCTAssertThrowsError(try MCPServer.intArgument(["ref": true], "ref"))
        XCTAssertThrowsError(try MCPServer.intArgument(["ref": [1, 2]], "ref"))
    }

    // MARK: - 実物の呼び口: ft_tap の ref(黙って x/y フォールバックへ落ちない)

    /// 不具合の実物(2026-09-20 実測): 型を断らないと「ref or x/y is required」に化け、
    /// 読み手は ref が悪いことに気づけないまま x/y 座標へフォールバックする
    func testTapWithAStringRefFailsWithATypeMessageNotTheGenericOne() async {
        do {
            _ = try await server.call(tool: "ft_tap", args: ["ref": "8"])
            XCTFail("string ref が黙って通った")
        } catch {
            let message = error.localizedDescription
            XCTAssertTrue(message.contains("ref must be an integer"), message)
            XCTAssertFalse(message.contains("ref or x/y is required"), message)
        }
    }

    func testTapWithStringCoordinatesFails() async {
        do {
            _ = try await server.call(tool: "ft_tap", args: ["x": "200", "y": "400"])
            XCTFail("string x/y が黙って通った")
        } catch {
            let message = error.localizedDescription
            XCTAssertTrue(message.contains("must be a number"), message)
        }
    }

    /// 正しい型は従来どおり通る(型ゲートが正常系まで壊していないこと)
    func testTapWithAnIntegerRefStillSucceeds() async throws {
        _ = try await server.call(tool: "ft_tap", args: ["ref": 1])
    }

    // MARK: - 実物の呼び口: ft_snapshot の port(文言が型を語る)
    //
    // **portArgument を直接叩く**(server.call 経由ではない): テストの makeDriver 差し替え
    // 経路は resolveDriver の早期分岐(注入されたドライバをそのまま使う)を通るので、
    // port の検査そのものを踏まない(実ブリッジ解決の経路にしか無い検査)

    /// 不具合の実物その3: port は元から断っていたが、文言が `got 8130` で
    /// 文字列と数値の区別が付かなかった(8130 は範囲内なので矛盾した文言に見える)
    func testSnapshotPortArgumentNamesTheTypeInTheMessage() {
        XCTAssertThrowsError(try MCPServer.portArgument(["port": "8130"])) { error in
            let message = error.localizedDescription
            XCTAssertTrue(message.contains("the string \"8130\""), message)
        }
    }

    // MARK: - 実物の呼び口: ft_snapshot の maxElements(不具合その4: 黙って無視されていた)

    func testSnapshotWithAStringMaxElementsFails() async {
        do {
            _ = try await server.call(tool: "ft_snapshot", args: ["maxElements": "3"])
            XCTFail("string maxElements が黙って通った")
        } catch {
            let message = error.localizedDescription
            XCTAssertTrue(message.contains("maxElements must be an integer"), message)
        }
    }

    func testSnapshotWithAnIntegerMaxElementsStillSucceeds() async throws {
        _ = try await server.call(tool: "ft_snapshot", args: ["maxElements": 3])
    }
}
