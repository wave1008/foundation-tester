import XCTest
@testable import fleetest

/// api live serve の NDJSON パース(ApiLiveServeCommand)。実地 L3: 型違いの引数
/// ({"cmd":"pinch","scale":"2"} 等)が JSONDecoder の全体失敗で「JSON でない行」と
/// 見分けられず無応答のまま黙殺され、拡張の SERVE_REQUEST_TIMEOUT で serve ごと
/// 再起動していた。cmd が読めた行は decodeError に理由を持ち帰ることを固定する。
final class ApiLiveServeCommandParsingTests: XCTestCase {

    func testQuotedNumberIsRejectedWithATypedMessage() {
        let command = ApiLiveServeCommand(cmd: "pinch", raw: ["cmd": "pinch", "scale": "2"])
        guard let detail = command.decodeError else { return XCTFail("型違いは decodeError に載せる") }
        XCTAssertTrue(detail.contains("scale must be a number"), detail)
        XCTAssertTrue(detail.contains("the string \"2\""), detail)
        XCTAssertNil(command.scale, "型違いの値をなだれ込ませない")
    }

    /// **整数の欄も検査する** —— 変異チェックで `intField` のエラー設定を消しても落ちなかった
    /// (double / string の欄しか見ていなかった)。実地で来る形は `{"cmd":"tap","ref":"abc"}`
    func testQuotedIntegerIsRejectedWithATypedMessage() {
        let command = ApiLiveServeCommand(cmd: "tap", raw: ["cmd": "tap", "ref": "abc"])
        guard let detail = command.decodeError else { return XCTFail("型違いは decodeError に載せる") }
        XCTAssertTrue(detail.contains("ref must be an integer"), detail)
        XCTAssertNil(command.ref, "型違いの値をなだれ込ませない")
    }

    func testNumberInAStringFieldIsRejectedWithATypedMessage() {
        let command = ApiLiveServeCommand(cmd: "type", raw: ["cmd": "type", "text": 123])
        guard let detail = command.decodeError else { return XCTFail("型違いは decodeError に載せる") }
        XCTAssertTrue(detail.contains("text must be a string"), detail)
        XCTAssertNil(command.text)
    }

    /// 複数同時に型が違っても最初の1件だけを持ち帰る(文言に困らない範囲で十分)
    func testOnlyTheFirstTypeErrorIsKept() {
        let command = ApiLiveServeCommand(
            cmd: "drag", raw: ["cmd": "drag", "fromX": "1", "fromY": "2"])
        guard let detail = command.decodeError else { return XCTFail("型違いは decodeError に載せる") }
        XCTAssertTrue(detail.contains("fromX"), detail)
        XCTAssertFalse(detail.contains("fromY"), detail)
    }

    /// **JSON の true は NSNumber(CFBoolean)で来て `as? Int` / `as? Double` を 1 として通る**(負荷テストで
    /// `{"cmd":"type","ref":true}` が ref 1 としてドライバまで届いた)。実入力と同じく JSONSerialization で読む
    /// (Swift の `true` リテラルは CFBoolean にならないので、辞書リテラルでは再現しない)
    private func parsed(_ json: String) throws -> ApiLiveServeCommand {
        let raw = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(json.utf8)) as? [String: Any])
        return ApiLiveServeCommand(cmd: try XCTUnwrap(raw["cmd"] as? String), raw: raw)
    }

    func testJSONBooleanIsRejectedForAnIntegerField() throws {
        let command = try parsed(#"{"cmd":"type","text":"a","ref":true}"#)
        guard let detail = command.decodeError else { return XCTFail("true を ref 1 として通さない") }
        XCTAssertTrue(detail.contains("ref must be an integer (got the boolean true)"), detail)
        XCTAssertNil(command.ref)
    }

    func testJSONBooleanIsRejectedForANumberField() throws {
        let command = try parsed(#"{"cmd":"pinch","scale":false}"#)
        guard let detail = command.decodeError else { return XCTFail("false を scale 0 として通さない") }
        XCTAssertTrue(detail.contains("scale must be a number (got the boolean false)"), detail)
        XCTAssertNil(command.scale)
    }

    func testJSONBooleanIsRejectedForAGesturePoint() throws {
        let command = try parsed(#"{"cmd":"gesture","fingers":[{"points":[{"x":1,"y":2,"t":true}]}]}"#)
        XCTAssertNotNil(command.decodeError, "t: true を 1 秒として通さない")
        XCTAssertNil(command.fingers)
    }

    /// 逆向き: 数値の 1 を「the boolean true」と書かない(`as Bool` は NSNumber の 0/1 にも当たる)
    func testJSONNumberOneInAStringFieldIsNotDescribedAsABoolean() throws {
        let command = try parsed(#"{"cmd":"type","text":1}"#)
        guard let detail = command.decodeError else { return XCTFail("型違いは decodeError に載せる") }
        XCTAssertTrue(detail.contains("text must be a string (got 1)"), detail)
    }

    /// NUL は入口で断る(MCP と同じ文言。外部コマンドへ流れると Process が abort する)
    func testNULInAStringFieldIsRejected() throws {
        let command = try parsed(#"{"cmd":"launch","bundle":"com.x\u0000y"}"#)
        XCTAssertEqual(command.decodeError, "bundle must not contain a NUL character (\\u0000)")
        XCTAssertNil(command.bundle)
    }

    /// 配列の欄の型違いに「JSON の文字列を渡せ」と言わない
    func testArrayFieldTypeErrorAsksForAnArray() throws {
        let command = try parsed(#"{"cmd":"gesture","fingers":-1}"#)
        guard let detail = command.decodeError else { return XCTFail("型違いは decodeError に載せる") }
        XCTAssertTrue(detail.hasSuffix("pass a JSON array"), detail)
    }

    func testCorrectTypesParseCleanlyWithNoDecodeError() {
        let command = ApiLiveServeCommand(
            cmd: "pinch", raw: ["cmd": "pinch", "scale": 2.5, "ref": 7])
        XCTAssertNil(command.decodeError)
        XCTAssertEqual(command.scale, 2.5)
        XCTAssertEqual(command.ref, 7)
    }

    /// JSON の整数値({"scale":2}、小数点なし)も number として通す(NSNumber は Int/Double の
    /// どちらでも来うる。整数値の double 引数を誤って型違いと断らない)
    func testWholeNumberJSONValuePassesADoubleField() {
        let command = ApiLiveServeCommand(cmd: "pinch", raw: ["cmd": "pinch", "scale": 2])
        XCTAssertNil(command.decodeError)
        XCTAssertEqual(command.scale, 2.0)
    }

    func testAbsentFieldsStayNilWithoutAnError() {
        let command = ApiLiveServeCommand(cmd: "refresh", raw: ["cmd": "refresh"])
        XCTAssertNil(command.decodeError)
        XCTAssertNil(command.ref)
        XCTAssertNil(command.bundle)
    }
}
