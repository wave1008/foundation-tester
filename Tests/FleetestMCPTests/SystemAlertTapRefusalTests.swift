// ref の操作の前にシステムアラートを確かめて断る(`MCPServer.systemAlertTapRefusal`):
// ①SpringBoard の許可アラートはアプリの木を変えずに湧くので、覆いの探針を木の指紋で使い回しても
//   アラートだけは毎回聞く(使い回すと、権限を要求するボタンを叩いた後の操作で黙る)
// ②断る。どちらのエンジンでも操作は届き(in-app は背面のアプリが反応・XCUITest は XCTest がアラートの
//   ボタンを押す)、起きることをエンジンごとに言う ③SpringBoard に attach している間は断らない

import XCTest
import FTCore
@testable import fleetest_mcp

final class SystemAlertTapRefusalTests: XCTestCase {
    private var driver: FakeDriver!
    private var server: MCPServer!

    override func setUp() {
        super.setUp()
        driver = FakeDriver()
        let fake = driver!
        server = MCPServer(write: { _ in }, makeDriver: { _ in fake }, recordSnapshot: { _, _, _ in })
        driver.snapshotResponse = SnapshotResponse(
            sessionBundleID: "com.example.app",
            screen: FTRect(x: 0, y: 0, width: 390, height: 844),
            elements: [ElementInfo(ref: 1, type: "button", identifier: "btn_request_photos",
                                   label: "写真", value: nil, placeholder: nil, enabled: true,
                                   frame: FTRect(x: 16, y: 168, width: 370, height: 48), depth: 2)],
            truncatedCount: 0)
        driver.systemUICoveringResponse = SystemUICoveringResponse(covering: false)
    }

    private static let photosAlert = SystemAlertProbeResponse(
        present: true, title: "“E2E”が写真へのアクセスを求めています", buttons: ["許可しない", "許可"])

    private var taps: [String] { driver.calls.filter { $0.hasPrefix("tap") } }

    /// 断られたときの本文(断られなければ nil)
    private func refusal(_ tool: String = "ft_tap") async -> String? {
        do {
            _ = try await server.call(tool: tool, args: ["ref": 1])
            return nil
        } catch {
            return error.localizedDescription
        }
    }

    /// **本命(I6)**: 木が1バイトも変わらないまま2回目のタップの前にアラートが湧いても断る
    func testAlertThatAppearsOnAnUnchangedTreeRefusesTheNextTap() async throws {
        _ = try await server.call(tool: "ft_snapshot", args: [:])
        let first = await refusal()
        XCTAssertNil(first, first ?? "")

        driver.scriptedSystemAlert = Self.photosAlert
        let second = await refusal()
        XCTAssertTrue(second?.contains("a system alert (「“E2E”が写真へのアクセスを求めています」") == true,
                      second ?? "not refused")
        XCTAssertEqual(taps.count, 1, "2回目は撃たない: \(driver.calls)")
    }

    /// **in-app(hybrid)**: 断り、背面のアプリへ届いてしまうことを理由に言う
    func testInAppRefusalSaysItWouldReachTheAppBehindTheAlert() async throws {
        server.engines[MCPServer.engineKey([:])] = "hybrid"
        driver.scriptedSystemAlert = Self.photosAlert
        _ = try await server.call(tool: "ft_snapshot", args: [:])
        let text = await refusal() ?? "not refused"
        XCTAssertTrue(text.contains("refusing to act on #btn_request_photos"), text)
        XCTAssertTrue(text.contains("it would still reach the app behind the alert"), text)
        XCTAssertTrue(taps.isEmpty, "\(driver.calls)")
    }

    /// **XCUITest**: XCTest がアラートのボタンを押しうることを理由に言う
    func testXCUITestRefusalSaysXCTestCanPressAnAlertButton() async throws {
        server.engines[MCPServer.engineKey([:])] = "xcuitest"
        driver.scriptedSystemAlert = Self.photosAlert
        _ = try await server.call(tool: "ft_snapshot", args: [:])
        let text = await refusal() ?? "not refused"
        XCTAssertTrue(text.contains("can press one of its buttons"), text)
        XCTAssertTrue(taps.isEmpty, "\(driver.calls)")
    }

    /// ref の操作は同じ門を通る(ft_long_press も断る)
    func testLongPressIsRefusedToo() async throws {
        driver.scriptedSystemAlert = Self.photosAlert
        _ = try await server.call(tool: "ft_snapshot", args: [:])
        let text = await refusal("ft_long_press")
        XCTAssertTrue(text?.contains("refusing to act on") == true, text ?? "not refused")
        XCTAssertFalse(driver.calls.contains { $0.hasPrefix("press") }, "\(driver.calls)")
    }

    /// **SpringBoard に attach している間は断らない**(アラートのボタンを押す経路そのもの)
    func testTappingWhileAttachedToSpringBoardIsNotRefused() async throws {
        driver.scriptedSystemAlert = Self.photosAlert
        _ = try await server.call(tool: "ft_launch", args: ["bundleId": "com.apple.springboard"])
        _ = try await server.call(tool: "ft_snapshot", args: [:])
        let text = await refusal()
        XCTAssertNil(text, text ?? "")
        XCTAssertEqual(taps.count, 1, "\(driver.calls)")
    }

    /// 座標の操作は断らない(XCUITest ではアラートそのものに当たる正当な操作)
    func testCoordinateTapIsNotRefused() async throws {
        driver.scriptedSystemAlert = Self.photosAlert
        _ = try await server.call(tool: "ft_snapshot", args: [:])
        _ = try await server.call(tool: "ft_tap", args: ["x": 100.0, "y": 300.0])
        XCTAssertEqual(taps.count, 1, "\(driver.calls)")
    }
}
