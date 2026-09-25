import XCTest

/// `api live serve` の座標コマンド(tap/doubleTap/press/drag の x/y 形)が、ドライバへ撃つ前に
/// 画面内かを断ることの配線(G1、2026-09-25: 断らずに撃った結果 AndroidDriver の Int32 変換が
/// trap してプロセスごと落ちた)。`perform` はデバイスが要る private func なのでソース走査で
/// 固定する(ApiLiveGestureCommandTests と同じ方針)。
/// 判定そのもの(`FTCore.TapTargetGeometry.isPointOnScreen`)の単体テストは
/// TapTargetGeometryIsPointOnScreenTests、MCP との共有配線は LiveControlExitParityTests が見る。
final class ApiLiveCoordinateOnScreenGuardTests: XCTestCase {

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

    /// 走査が届いていることの確認(空文字を検索すると何を書いても通る)
    func testSourceIsActuallyRead() throws {
        XCTAssertTrue(try liveCommandSource().contains("requireOnScreen"))
    }

    /// **共有する判定は `TapTargetGeometry.isPointOnScreen` の1箇所**(MCP の
    /// `offscreenCoordinateError` と共有。LiveControlExitParityTests が両側の配線を固定する)
    func testRequireOnScreenCallsTheSharedPredicate() throws {
        let source = try liveCommandSource()
        let start = try XCTUnwrap(source.range(of: "private func requireOnScreen"))
        let end = try XCTUnwrap(source.range(of: "\n    private func perform", range: start.upperBound..<source.endIndex))
        let body = String(source[start.upperBound..<end.lowerBound])
        XCTAssertTrue(body.contains("TapTargetGeometry.isPointOnScreen("), body)
        XCTAssertTrue(body.contains("driver.snapshot()"), "画面を得るために snapshot を撮ること: \(body)")
    }

    func testTapCoordinateFormGoesThroughTheGuardBeforeTouchingTheDriver() throws {
        let body = try caseBody(try liveCommandSource(), cmd: "tap", until: "type")
        try assertGuardsBeforeDriverCall(body, driverCall: "driver.tap(x:")
    }

    func testDoubleTapCoordinateFormGoesThroughTheGuardBeforeTouchingTheDriver() throws {
        let body = try caseBody(try liveCommandSource(), cmd: "doubleTap", until: "pinch")
        try assertGuardsBeforeDriverCall(body, driverCall: "driver.doubleTap(x: x, y: y)")
    }

    func testPressCoordinateFormGoesThroughTheGuardBeforeTouchingTheDriver() throws {
        let body = try caseBody(try liveCommandSource(), cmd: "press", until: "gesture")
        try assertGuardsBeforeDriverCall(body, driverCall: "driver.press(x:")
    }

    /// drag は from/to の両点を1回の呼び出しでまとめて渡す(往復1回で両方を検査する)
    func testDragChecksBothEndpointsBeforeTouchingTheDriver() throws {
        let body = try caseBody(try liveCommandSource(), cmd: "drag", until: "doubleTap")
        XCTAssertTrue(body.contains("requireOnScreen([(fromX, fromY), (toX, toY)]"),
                      "drag は起点・終点の両方を検査すること: \(body)")
        let guardCall = try XCTUnwrap(body.range(of: "requireOnScreen("))
        let drive = try XCTUnwrap(body.range(of: "driver.drag("))
        XCTAssertTrue(guardCall.lowerBound < drive.lowerBound,
                      "検査してから撃つこと(逆だと桁外れの座標がそのままドライバへ届く): \(body)")
    }

    private func assertGuardsBeforeDriverCall(_ body: String, driverCall: String) throws {
        XCTAssertTrue(body.contains("requireOnScreen("), "座標形が画面内チェックを通っていない: \(body)")
        let guardCall = try XCTUnwrap(body.range(of: "requireOnScreen("))
        let drive = try XCTUnwrap(body.range(of: driverCall))
        XCTAssertTrue(guardCall.lowerBound < drive.lowerBound,
                      "検査してから撃つこと(逆だと桁外れの座標がそのままドライバへ届く): \(body)")
    }
}
