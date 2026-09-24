import XCTest
@testable import fleetest
import FTCore

/// ライブ操作の軌跡モード(`{"cmd":"gesture", ...}`)。パースは `ApiLiveServeCommand` を直接当て、
/// 実行(driver.gesture の呼び出し・TouchGesture.validate の共有)はデバイスが要るためソース走査で
/// 固定する(LiveSessionFollowerTests と同じ方針)。
final class ApiLiveGestureCommandTests: XCTestCase {

    // MARK: - パース(ApiLiveServeCommand.fingers)

    func testValidFingersParseCleanlyWithNoDecodeError() throws {
        let command = ApiLiveServeCommand(cmd: "gesture", raw: [
            "cmd": "gesture",
            "fingers": [
                ["points": [
                    ["x": 10.0, "y": 20.0, "t": 0.0],
                    ["x": 15.0, "y": 25.0, "t": 0.3],
                ]],
            ],
        ])
        XCTAssertNil(command.decodeError)
        let fingers = try XCTUnwrap(command.fingers)
        XCTAssertEqual(fingers.count, 1)
        XCTAssertEqual(fingers.first?.points.count, 2)
        XCTAssertEqual(fingers.first?.points.first?.x, 10.0)
        XCTAssertEqual(fingers.first?.points.last?.t, 0.3)
    }

    /// JSON の整数値({"x":10}、小数点なし)も number として通す(他の欄と同じ規律)
    func testWholeNumberPointValuesParseCleanly() {
        let command = ApiLiveServeCommand(cmd: "gesture", raw: [
            "cmd": "gesture",
            "fingers": [["points": [["x": 10, "y": 20, "t": 0]]]],
        ])
        XCTAssertNil(command.decodeError)
        XCTAssertEqual(command.fingers?.first?.points.first?.x, 10.0)
    }

    func testNonArrayFingersIsRejectedWithATypedMessage() {
        let command = ApiLiveServeCommand(cmd: "gesture", raw: ["cmd": "gesture", "fingers": "nope"])
        guard let detail = command.decodeError else { return XCTFail("型違いは decodeError に載せる") }
        XCTAssertTrue(detail.contains("fingers must be an array"), detail)
        XCTAssertNil(command.fingers, "型違いの値をなだれ込ませない")
    }

    func testFingerWithoutPointsIsRejected() {
        let command = ApiLiveServeCommand(cmd: "gesture", raw: [
            "cmd": "gesture", "fingers": [["notPoints": []]],
        ])
        guard let detail = command.decodeError else { return XCTFail("points 欠落が通った") }
        XCTAssertTrue(detail.contains("points must be an array"), detail)
        XCTAssertNil(command.fingers)
    }

    func testPointWithNonNumericFieldIsRejected() {
        let command = ApiLiveServeCommand(cmd: "gesture", raw: [
            "cmd": "gesture",
            "fingers": [["points": [["x": "10", "y": 20.0, "t": 0.0]]]],
        ])
        guard let detail = command.decodeError else { return XCTFail("x の型違いが通った") }
        XCTAssertTrue(detail.contains("numeric x/y/t"), detail)
        XCTAssertNil(command.fingers)
    }

    func testAbsentFingersStaysNilWithoutAnError() {
        let command = ApiLiveServeCommand(cmd: "tap", raw: ["cmd": "tap", "x": 1.0, "y": 2.0])
        XCTAssertNil(command.decodeError)
        XCTAssertNil(command.fingers)
    }

    // MARK: - 配線(ソース走査)

    private func liveCommandSource() throws -> String {
        let url = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("Sources/fleetest/ApiLiveCommand.swift")
        return try String(contentsOf: url, encoding: .utf8)
    }

    private func caseBody(_ source: String, cmd: String, until next: String) throws -> String {
        let start = try XCTUnwrap(source.range(of: "case \"\(cmd)\":"))
        let end = try XCTUnwrap(source.range(of: "case \"\(next)\":", range: start.upperBound..<source.endIndex))
        return String(source[start.upperBound..<end.lowerBound])
    }

    /// 画面を触る操作なので追従(LiveSessionFollower)の対象に入れること
    /// (LiveSessionFollowerTests.testOnlyScreenTouchingCommandsFollowTheFrontmostApp と対になる観点)
    func testGestureFollowsTheFrontmostApp() throws {
        let source = try liveCommandSource()
        let start = try XCTUnwrap(source.range(of: "private static func followsFrontmost"))
        let end = try XCTUnwrap(source.range(of: "\n    }", range: start.upperBound..<source.endIndex))
        let body = String(source[start.upperBound..<end.lowerBound])
        XCTAssertTrue(body.contains("\"gesture\""), "gesture が追従の一覧から落ちている")
    }

    /// 空/欠落の fingers は断ること(cmd 単体では ArgumentBounds が検査できない業務ルール)
    func testEmptyFingersIsRefusedBeforeTouchingTheDriver() throws {
        let body = try caseBody(try liveCommandSource(), cmd: "gesture", until: "launch")
        XCTAssertTrue(body.contains("guard let fingers = command.fingers, !fingers.isEmpty else"),
                      "空の fingers を断ること: \(body)")
    }

    /// **共有する判定は TouchGesture.validate の1箇所**(MCP の ft_gesture と同じ門)。
    /// ここを経由せず driver.gesture を直接撃つと、ライブ操作だけ本数・時刻・画面内の検査を欠く
    func testGestureGoesThroughTheSharedValidateBeforeTouchingTheDriver() throws {
        let body = try caseBody(try liveCommandSource(), cmd: "gesture", until: "launch")
        XCTAssertTrue(body.contains("TouchGesture.validate("), "共有の検査を通ること: \(body)")
        let validate = try XCTUnwrap(body.range(of: "TouchGesture.validate("))
        let drive = try XCTUnwrap(body.range(of: "driver.gesture("))
        XCTAssertTrue(validate.lowerBound < drive.lowerBound,
                      "検査してから撃つこと(逆だと不正なジェスチャがそのままデバイスへ届く): \(body)")
    }

    /// `maxGestureSeconds` はこの1回だけ既定 10 秒の上限を引き上げる(press/drag/pinch と同じ規律)
    func testGestureRespectsThePerCommandMaxGestureSecondsOverride() throws {
        let body = try caseBody(try liveCommandSource(), cmd: "gesture", until: "launch")
        XCTAssertTrue(body.contains("command.maxGestureSeconds ?? BridgeAPI.defaultMaxGestureSeconds"), body)
    }
}
