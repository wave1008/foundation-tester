// 契約: MCP の引数の型は `call()` の入口で全数断る(`MCPServer.checkDeclaredArgumentTypes`)。
// `intArgument` 等の検査は読まれた回にしか効かないので、条件付きでしか読まれない引数
// (`waitSeconds` 等)の型違いは、読まれない回に黙って通る。

import XCTest
import FTCore
@testable import fleetest_mcp

final class DeclaredArgumentTypeCheckTests: XCTestCase {

    private var driver: FakeDriver!
    private var server: MCPServer!

    override func setUp() {
        super.setUp()
        driver = FakeDriver()
        let fake = driver!
        server = MCPServer(write: { _ in }, makeDriver: { _ in fake }, recordSnapshot: { _, _, _ in })
    }

    /// 実 JSON-RPC と同じ経路(JSONSerialization)で args を作る —— Swift のリテラル
    /// `["x": true]` は素の Bool であって、実際にワイヤを流れてくる NSNumber(CFBoolean)とは
    /// 別物(true/1 の取り違えは NSNumber ブリッジだけの罠)。boolean 絡みのテストは
    /// 必ずこの経路を通す
    private func jsonArgs(_ json: String) -> [String: Any] {
        (try! JSONSerialization.jsonObject(with: Data(json.utf8))) as! [String: Any]
    }

    // MARK: - 実地不具合の再現

    /// waitSeconds は snapshotAfter のときしか intArgument/doubleArgument を通らない —— それでも
    /// 型違いは入口で断られる(実地: 断らず "Launched: …" で成功していた)
    func testLaunchWaitSecondsAsStringIsRejectedEvenWithoutSnapshotAfter() async {
        do {
            _ = try await server.call(tool: "ft_launch",
                                      args: jsonArgs(#"{"bundleId":"com.ftester.e2e","waitSeconds":"five"}"#))
            XCTFail("waitSeconds \"five\" が snapshotAfter 無しで通った")
        } catch {
            let message = error.localizedDescription
            XCTAssertTrue(message.contains("waitSeconds"), message)
            XCTAssertTrue(message.contains("a number"), message)
        }
    }

    // MARK: - checkDeclaredArgumentTypes(純粋関数): NSNumber の boolean/数値の取り違え

    /// JSON の `true`/`false` は NSNumber(CFBoolean)で来るので、素朴な `as? Int` は
    /// true を 1 として通してしまう —— `port`(integer)へ boolean を渡すと断られること
    func testBooleanValueIsRejectedForIntegerProperty() {
        XCTAssertThrowsError(
            try MCPServer.checkDeclaredArgumentTypes(tool: "ft_status", args: jsonArgs(#"{"port": true}"#))
        ) { error in
            let message = error.localizedDescription
            XCTAssertTrue(message.contains("port"), message)
            XCTAssertTrue(message.contains("an integer"), message)
        }
    }

    /// 逆向き: 数値(0/1)は boolean プロパティへ通さない —— `as? Bool` は数値も素通しする
    func testIntegerValueIsRejectedForBooleanProperty() {
        XCTAssertThrowsError(
            try MCPServer.checkDeclaredArgumentTypes(tool: "ft_launch", args: jsonArgs(#"{"resume": 1}"#))
        ) { error in
            let message = error.localizedDescription
            XCTAssertTrue(message.contains("resume"), message)
            XCTAssertTrue(message.contains("boolean"), message)
        }
    }

    func testValidBooleanPassesForBooleanProperty() throws {
        try MCPServer.checkDeclaredArgumentTypes(tool: "ft_launch", args: jsonArgs(#"{"resume": true}"#))
    }

    // MARK: - 複数型宣言(scrollFrame: ["string", "integer"])

    func testScrollFrameAcceptsStringOrInteger() throws {
        try MCPServer.checkDeclaredArgumentTypes(tool: "ft_swipe", args: jsonArgs(##"{"scrollFrame": "#list_rows"}"##))
        try MCPServer.checkDeclaredArgumentTypes(tool: "ft_swipe", args: jsonArgs(#"{"scrollFrame": 7}"#))
    }

    func testScrollFrameRejectsBoolean() {
        XCTAssertThrowsError(
            try MCPServer.checkDeclaredArgumentTypes(tool: "ft_swipe", args: jsonArgs(#"{"scrollFrame": true}"#))
        ) { error in
            let message = error.localizedDescription
            XCTAssertTrue(message.contains("scrollFrame"), message)
            XCTAssertTrue(message.contains("string"), message)
            XCTAssertTrue(message.contains("integer"), message)
        }
    }

    // MARK: - 型が合っていれば素通し(既存の値域検査はここでは踏まない)

    func testMatchingTypesDoNotThrow() throws {
        try MCPServer.checkDeclaredArgumentTypes(tool: "ft_screenshot", args: jsonArgs(#"{"maxWidth": 100, "quality": 0.5, "fullSize": false}"#))
    }

    /// スキーマに無い鍵は素通し(未知引数の扱いは unknownArgumentNote の役目 — ここでは断らない)
    func testUnknownKeyIsIgnoredByTypeCheck() throws {
        try MCPServer.checkDeclaredArgumentTypes(tool: "ft_status", args: jsonArgs(#"{"thisArgumentDoesNotExist": "surprise"}"#))
    }

    /// array/object 型(fingers/drop/scenes)は対象外 —— 各ツールが個別に検査する
    func testArrayAndObjectPropertiesAreSkipped() throws {
        try MCPServer.checkDeclaredArgumentTypes(tool: "ft_draft_scenario", args: jsonArgs(#"{"drop": "not-an-array"}"#))
    }

    // MARK: - ①スキーマ走査: 全ツール × 宣言された数値・文字列・真偽値の引数 全数

    /// 各プロパティについて、宣言されたどの型にも当たらない値を1つ機械的に選び、
    /// `checkDeclaredArgumentTypes` が断ることを確かめる。引数を足したときの型検査の
    /// 取りこぼしを、スキーマから機械的に舐めて落とす
    func testEveryDeclaredScalarPropertyRejectsAMismatchedType() {
        var checked = 0
        for tool in MCPServer.toolDefinitions {
            guard let name = tool["name"] as? String,
                  let schema = tool["inputSchema"] as? [String: Any],
                  let properties = schema["properties"] as? [String: Any] else {
                XCTFail("\(tool) にスキーマが無い")
                continue
            }
            for (key, rawProp) in properties {
                guard let prop = rawProp as? [String: Any] else { continue }
                let types: Set<String>
                if let single = prop["type"] as? String { types = [single] }
                else if let multiple = prop["type"] as? [String] { types = Set(multiple) }
                else { continue }
                guard !types.contains("array"), !types.contains("object") else { continue }
                guard !types.isEmpty else { continue }
                // 専用の文言を持つ引数は入口では断らない(そのツールが自分で断る)
                if name == "ft_batch", key == "steps" { continue }
                let literal = Self.wrongValueLiteral(for: types)
                let args = jsonArgs("{\"\(key)\": \(literal)}")
                checked += 1
                XCTAssertThrowsError(
                    try MCPServer.checkDeclaredArgumentTypes(tool: name, args: args),
                    "\(name).\(key) (\(types.sorted())) が型違い \(literal) を通した"
                ) { error in
                    XCTAssertTrue(error.localizedDescription.contains(key),
                                  "\(name).\(key): \(error.localizedDescription)")
                }
            }
        }
        XCTAssertGreaterThan(checked, 20, "スキーマの走査対象が少なすぎる — properties の読み方を疑う")
    }

    /// 宣言された型集合のどれにも当たらない JSON リテラルを1つ選ぶ(純粋関数)。
    /// boolean が許されていなければ boolean を、次に整数/数値が許されていなければ数値を、
    /// それでも足りなければ文字列を使う —— スキーマが scalar 型を1つも宣言しない
    /// (呼び出し側が事前に array/object を弾いている)限り必ずどれかが「当たらない値」になる
    private static func wrongValueLiteral(for types: Set<String>) -> String {
        if !types.contains("boolean") { return "true" }
        if !types.contains("integer"), !types.contains("number") { return "12345" }
        if !types.contains("string") { return "\"not-a-value\"" }
        fatalError("scalar 型を3つとも宣言するプロパティは無いはず: \(types)")
    }
}
