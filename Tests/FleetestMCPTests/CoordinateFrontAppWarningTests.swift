// 座標で撃つ操作の「前面が起動したアプリではない」警告(MCPServer.frontAppWarning)。
// ref の操作は verifiedRef が断るが、座標の操作は木を読まないので、アプリを抜けた後の操作が
// ランチャーや他のアプリへ黙って届いた(実機で実測 → maintainer-notes §60)。

import XCTest
@testable import fleetest_mcp

final class CoordinateFrontAppWarningTests: XCTestCase {

    private let app = "com.ftester.e2e.android"

    func testSilentWhileTheLaunchedAppIsInFront() {
        XCTAssertEqual(MCPServer.frontAppWarning(launched: app, front: app), "")
    }

    /// 前面のアプリを名指しし、戻り方を言う
    func testNamesTheAppInFrontWhenItIsAnotherApp() {
        let launcher = "com.google.android.apps.nexuslauncher"
        let warning = MCPServer.frontAppWarning(launched: app, front: launcher)
        XCTAssertTrue(warning.contains("\(launcher) was in front, not \(app)"), warning)
        XCTAssertTrue(warning.contains("ft_launch \(app)"), warning)
    }

    /// 前面のアプリ名を答えないドライバ(iOS)では黙る(答えられないことを「前面ではない」と読まない)
    func testSilentWhenTheDriverCannotTell() {
        XCTAssertEqual(MCPServer.frontAppWarning(launched: app, front: nil), "")
    }

    /// 権限ダイアログは座標で押すのが正規の操作
    func testSilentOnASystemDialogDrawnOverTheApp() throws {
        let dialog = try XCTUnwrap(MCPServer.systemDialogPackages.first)
        XCTAssertEqual(MCPServer.frontAppWarning(launched: app, front: dialog), "")
    }

    /// iOS のブリッジは前面のアプリ名を通信せずに nil と答える(座標の操作に往復を足さない前提)
    func testIOSBridgeClientAnswersNoFrontAppName() throws {
        let source = try String(contentsOf: URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("Sources/FTBridgeClient/BridgeClient.swift"), encoding: .utf8)
        XCTAssertTrue(source.contains("public func foregroundAppID() async throws -> String? { nil }"))
    }

    /// 座標で撃つ経路の集合を本数で固定する(tap / double tap / long press / drag / pinch / gesture / 全画面 swipe)。
    /// 経路を足したらここも増やす。**撃つ前に読むこと**は各経路で警告の取得が発火より前にあることで見る
    func testEveryCoordinatePathAsksBeforeFiring() throws {
        let source = try MCPServerSourceText.combined()
        let code = source.components(separatedBy: "\n")
            .filter { !$0.trimmingCharacters(in: .whitespaces).hasPrefix("//") }.joined(separator: "\n")
        let calls = code.components(separatedBy: "await coordinateFrontAppWarning(").count - 1
        XCTAssertEqual(calls, 7, "座標で撃つ経路と警告の配線の本数がずれた")
        for (warning, fire) in [
            ("coordinateFrontAppWarning(d, args: args)", "try await d.tap(x: x, y: y)"),
            ("coordinateFrontAppWarning(swipeDriver, args: args)", "try await swipeDriver.swipe(direction)"),
            ("coordinateFrontAppWarning(doubleTapDriver, args: args)", "try await doubleTapDriver.doubleTap("),
            ("coordinateFrontAppWarning(dragDriver, args: args)", "try await dragDriver.drag("),
            ("coordinateFrontAppWarning(pinchDriver, args: args)", "try await pinchDriver.pinch("),
            ("coordinateFrontAppWarning(gestureDriver, args: args)", "try await gestureDriver.gesture("),
            ("coordinateFrontAppWarning(pressDriver, args: args)", "try await pressDriver.press(x: x, y: y"),
        ] {
            let asked = try XCTUnwrap(code.range(of: warning), warning)
            let fired = try XCTUnwrap(code.range(of: fire, range: asked.upperBound..<code.endIndex),
                                      "\(fire) が警告の取得より後に無い")
            XCTAssertLessThan(asked.lowerBound, fired.lowerBound)
        }
    }
}
