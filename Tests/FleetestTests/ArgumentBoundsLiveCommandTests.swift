import XCTest
@testable import fleetest

/// api live serve(ApiLiveServeCommand)の数値/文字列の値域チェック。MCP と同じ表
/// (FTCore.ArgumentBounds)を引く — 2箇所に値域を持たない。パース自体の型違いは
/// ApiLiveServeCommandParsingTests が別に固定しているので、ここは「型は合っているが
/// 値が無意味」(duration<=0・scale<=0・bundle/path の空文字)を断ることだけを見る。
/// **decode 段は cmd を見ない**ので、bundle の空文字は launch/activate/clearAppData の
/// どの cmd でも同じく断られる(clearAppData の bundle・install の path は従来無検査だった)。
final class ArgumentBoundsLiveCommandTests: XCTestCase {

    func testNegativeDurationIsRejected() {
        let command = ApiLiveServeCommand(cmd: "drag", raw: ["cmd": "drag", "duration": -1.0])
        guard let detail = command.decodeError else { return XCTFail("duration -1 が通った") }
        XCTAssertTrue(detail.contains("duration"), detail)
        XCTAssertNil(command.duration, "値域違反の値をなだれ込ませない")
    }

    func testZeroScaleIsRejected() {
        let command = ApiLiveServeCommand(cmd: "pinch", raw: ["cmd": "pinch", "scale": 0])
        guard let detail = command.decodeError else { return XCTFail("scale 0 が通った") }
        XCTAssertTrue(detail.contains("scale"), detail)
        XCTAssertNil(command.scale)
    }

    func testNegativePressIsRejected() {
        let command = ApiLiveServeCommand(cmd: "drag", raw: ["cmd": "drag", "press": -0.5])
        guard let detail = command.decodeError else { return XCTFail("press -0.5 が通った") }
        XCTAssertTrue(detail.contains("press"), detail)
    }

    /// **cmd を問わず一律**: launch の bundle でも空文字は decode 段で断られる
    func testEmptyBundleIsRejected() {
        let command = ApiLiveServeCommand(cmd: "launch", raw: ["cmd": "launch", "bundle": ""])
        guard let detail = command.decodeError else { return XCTFail("bundle 空文字が通った") }
        XCTAssertTrue(detail.contains("bundle must not be empty"), detail)
        XCTAssertNil(command.bundle)
    }

    /// 空白のみも空文字と同じ扱い
    func testWhitespaceOnlyBundleIsRejected() {
        let command = ApiLiveServeCommand(cmd: "clearAppData", raw: ["cmd": "clearAppData", "bundle": "   "])
        guard let detail = command.decodeError else { return XCTFail("空白のみの bundle が通った") }
        XCTAssertTrue(detail.contains("bundle must not be empty"), detail)
    }

    /// **従来無検査だった**: install の path が空文字でも通っていた
    func testEmptyPathIsRejected() {
        let command = ApiLiveServeCommand(cmd: "install", raw: ["cmd": "install", "path": ""])
        guard let detail = command.decodeError else { return XCTFail("path 空文字が通った") }
        XCTAssertTrue(detail.contains("path must not be empty"), detail)
        XCTAssertNil(command.path)
    }

    /// 省略(キー自体が無い)は値域チェックの対象外 —— cmd ごとの既定に委ねる
    /// (例: clearAppData は bundle 省略でセッションが指すアプリへ倒す)
    func testOmittedBundleStaysNilWithoutAnError() {
        let command = ApiLiveServeCommand(cmd: "clearAppData", raw: ["cmd": "clearAppData"])
        XCTAssertNil(command.decodeError)
        XCTAssertNil(command.bundle)
    }

    /// 正の値は従来どおり通る(値域ゲートが正常系まで壊していないこと)
    func testPositiveValuesStillParseCleanly() {
        let command = ApiLiveServeCommand(
            cmd: "pinch", raw: ["cmd": "pinch", "scale": 2.0, "duration": 0.5])
        XCTAssertNil(command.decodeError)
        XCTAssertEqual(command.scale, 2.0)
        XCTAssertEqual(command.duration, 0.5)
    }

    func testNonEmptyBundleStillParsesCleanly() {
        let command = ApiLiveServeCommand(cmd: "launch", raw: ["cmd": "launch", "bundle": "com.example"])
        XCTAssertNil(command.decodeError)
        XCTAssertEqual(command.bundle, "com.example")
    }
}
