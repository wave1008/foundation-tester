import XCTest
@testable import fleetest

/// ライブ操作のセッション追従。**判定(LiveSessionTarget)は純粋関数**なので直接当て、
/// デバイスが要る配線(破壊的な操作の前にセッションを対象へ戻す)はソース走査で固定する。
final class LiveSessionFollowerTests: XCTestCase {

    private let springboard = "com.apple.springboard"

    // MARK: - 向き先の判定

    func testPointsAtSpringboardWhenTheAppIsNotInFront() {
        XCTAssertEqual(
            LiveSessionTarget.retarget(current: "com.example.app", preferred: "com.example.app",
                                       preferredIsForeground: false),
            springboard)
    }

    func testStaysOnTheAppWhileItIsInFront() {
        XCTAssertNil(
            LiveSessionTarget.retarget(current: "com.example.app", preferred: "com.example.app",
                                       preferredIsForeground: true))
    }

    func testComesBackToTheAppOnceItIsInFrontAgain() {
        XCTAssertEqual(
            LiveSessionTarget.retarget(current: springboard, preferred: "com.example.app",
                                       preferredIsForeground: true),
            "com.example.app")
    }

    /// 向き先が同じなら撃たない —— 向け直しはランナーの refFrames を消すので、
    /// 毎コマンド撃つと直前のスナップショットの ref が無効になる
    func testDoesNotRetargetWhenAlreadyPointedAtSpringboard() {
        XCTAssertNil(
            LiveSessionTarget.retarget(current: springboard, preferred: "com.example.app",
                                       preferredIsForeground: false))
        XCTAssertNil(
            LiveSessionTarget.retarget(current: springboard, preferred: nil,
                                       preferredIsForeground: false))
    }

    /// アプリを選んでいない(起動直後・終了後)は画面にあるものを触るだけ。
    /// **前面判定が true でも** preferred が無ければ springboard へ倒す
    func testPointsAtSpringboardWithoutAPreferredApp() {
        XCTAssertEqual(
            LiveSessionTarget.retarget(current: nil, preferred: nil, preferredIsForeground: true),
            springboard)
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

    /// `/terminate` はセッションの向き先を殺す。追従で springboard を向いたまま撃つと
    /// **SpringBoard 自身を終了させる**ので、対象のアプリへ戻してからでなければならない
    func testTerminatePointsTheSessionAtTheAppFirst() throws {
        let body = try caseBody(try liveCommandSource(), cmd: "terminate", until: "clearAppData")
        let pointAt = try XCTUnwrap(body.range(of: "pointAtApp"))
        let terminate = try XCTUnwrap(body.range(of: "driver.terminate()"))
        XCTAssertTrue(pointAt.lowerBound < terminate.lowerBound,
                      "terminate は pointAtApp の後で撃つこと: \(body)")
    }

    /// clearAppData はホスト側で `terminate()`(= セッションのアプリ)を撃ってから
    /// コンテナを消す。対象へ寄せずに撃つと別のものを殺す
    func testClearAppDataPointsTheSessionAtTheTargetFirst() throws {
        let body = try caseBody(try liveCommandSource(), cmd: "clearAppData", until: "install")
        let pointAt = try XCTUnwrap(body.range(of: "pointAtApp"))
        let clear = try XCTUnwrap(body.range(of: "driver.clearAppData("))
        XCTAssertTrue(pointAt.lowerBound < clear.lowerBound,
                      "clearAppData は pointAtApp の後で撃つこと: \(body)")
    }

    /// アプリを選んでいないセッションでは `/terminate` を撃たない —— 追従で springboard を
    /// 向いているので、そのまま撃つと **SpringBoard 自身**を終了させる
    func testTerminateRefusesWithoutAnAppInTheSession() throws {
        let body = try caseBody(try liveCommandSource(), cmd: "terminate", until: "clearAppData")
        XCTAssertTrue(body.contains("guard let target = follower.drivenApp()"),
                      "駆動しているアプリが無いときは断ること: \(body)")
    }

    /// clearAppData の既定対象にセッションの springboard を採らない(同じ理由)
    func testClearAppDataNeverDefaultsToSpringboard() throws {
        let source = try liveCommandSource()
        let start = try XCTUnwrap(source.range(of: "private func resolveBundleForClearAppData"))
        let end = try XCTUnwrap(source.range(of: "\n    }", range: start.upperBound..<source.endIndex))
        let body = String(source[start.upperBound..<end.lowerBound])
        XCTAssertTrue(body.contains("!= LiveSessionTarget.springboard"),
                      "セッションからの既定は springboard を除くこと: \(body)")
    }

    /// 追従させるのは画面を触るコマンドだけ。セッションを引数で名指しするコマンドを
    /// ここへ入れると、自分で決めた向き先を追従が上書きする
    func testOnlyScreenTouchingCommandsFollowTheFrontmostApp() throws {
        let source = try liveCommandSource()
        let start = try XCTUnwrap(source.range(of: "private static func followsFrontmost"))
        let end = try XCTUnwrap(source.range(of: "\n    }", range: start.upperBound..<source.endIndex))
        let body = String(source[start.upperBound..<end.lowerBound])
        for cmd in ["tap", "type", "clear", "hideKeyboard", "swipe", "drag", "doubleTap", "pinch",
                    "press", "back", "appSwitcher", "home"] {
            XCTAssertTrue(body.contains("\"\(cmd)\""), "\(cmd) が追従の一覧から落ちている")
        }
        for cmd in ["launch", "activate", "terminate", "clearAppData", "install", "frame", "refresh"] {
            XCTAssertFalse(body.contains("\"\(cmd)\""), "\(cmd) は追従させない")
        }
    }
}
