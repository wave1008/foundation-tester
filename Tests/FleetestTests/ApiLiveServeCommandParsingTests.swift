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
