// ref の操作の前にシステムアラートを確かめて断る(`MCPServer.systemAlertGate`):
// ①SpringBoard の許可アラートはアプリの木を変えずに湧くので、覆いの探針を木の指紋で使い回しても
//   アラートだけは毎回聞く(使い回すと、権限を要求するボタンを叩いた後の操作で黙る)
// ②断る。どちらのエンジンでも操作は届き(in-app は背面のアプリが反応・XCUITest は XCTest がアラートの
//   ボタンを押す)、起きることをエンジンごとに言う ③SpringBoard に attach している間は断らない
// ④ref を座標へ畳む double_tap / drag / pinch(`verifiedElement`)も同じ門(§19 A4)
// ⑤照会そのものが失敗したら断らずに撃つが、確かめていないことを注記に残す(P2 の MCP 側)

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

    /// **ref を座標へ畳む3ツール**(`verifiedElement` 経由)も断る。以前はここだけ門の外で、
    /// XCTest が「許可しない」を押して done と返していた(実機 SE3)
    func testDoubleTapDragAndPinchByRefAreRefusedToo() async throws {
        server.engines[MCPServer.engineKey([:])] = "xcuitest"
        driver.scriptedSystemAlert = Self.photosAlert
        _ = try await server.call(tool: "ft_snapshot", args: [:])
        for (tool, args) in [("ft_double_tap", ["ref": 1] as [String: Any]),
                             ("ft_drag", ["fromRef": 1, "dx": 0.0, "dy": -200.0]),
                             ("ft_pinch", ["ref": 1, "scale": 2.0])] {
            do {
                _ = try await server.call(tool: tool, args: args)
                XCTFail("\(tool) は断られるべき: \(driver.calls)")
            } catch {
                XCTAssertTrue(error.localizedDescription.contains("refusing to act on #btn_request_photos"),
                              "\(tool): \(error.localizedDescription)")
                XCTAssertTrue(error.localizedDescription.contains("can press one of its buttons"),
                              "\(tool): \(error.localizedDescription)")
            }
        }
        XCTAssertFalse(driver.calls.contains { $0.hasPrefix("doubleTap") || $0.hasPrefix("drag")
                                               || $0.hasPrefix("pinch") }, "\(driver.calls)")
    }

    /// **照会が失敗したら断らずに撃つが、確かめていないことを注記に残す**(黙って「無し」にしない)。
    /// `verifiedRef`(ft_tap)と `verifiedElement`(ft_double_tap)の両方
    func testProbeFailureActsButSaysTheCheckCouldNotBeMade() async throws {
        _ = try await server.call(tool: "ft_snapshot", args: [:])
        driver.failing.insert("systemAlert")
        for tool in ["ft_tap", "ft_double_tap"] {
            let result = try await server.call(tool: tool, args: ["ref": 1])
            let text = result.compactMap { $0["text"] as? String }.joined()
            XCTAssertTrue(text.contains("the system-alert check before acting on #btn_request_photos failed"),
                          "\(tool): \(text)")
            XCTAssertTrue(text.contains("without knowing whether an alert was in front of the app"),
                          "\(tool): \(text)")
        }
        XCTAssertEqual(taps.count, 1, "\(driver.calls)")
        XCTAssertEqual(driver.calls.filter { $0.hasPrefix("doubleTap") }.count, 1, "\(driver.calls)")
    }

    /// 座標の操作は断らない(XCUITest ではアラートそのものに当たる正当な操作)
    func testCoordinateTapIsNotRefused() async throws {
        driver.scriptedSystemAlert = Self.photosAlert
        _ = try await server.call(tool: "ft_snapshot", args: [:])
        _ = try await server.call(tool: "ft_tap", args: ["x": 100.0, "y": 300.0])
        XCTAssertEqual(taps.count, 1, "\(driver.calls)")
    }

    // MARK: - ref なし ft_type が「焦点が無い」で失敗したとき(§19.3 M10)

    /// **本命**: ref を渡さない ft_type がドライバの失敗(=「焦点が無い」相当)で落ちたとき、
    /// 前面にシステムアラートが出ていれば、それを可能性の高い原因として名指しする
    /// (SystemUIGate の申告は木に載らないので、素の失敗文は「焦点が無い」としか言えない)
    func testRefLessTypeFailureNamesTheSystemAlertAsTheLikelyCause() async {
        driver.scriptedSystemAlert = Self.photosAlert
        driver.failing.insert("type")
        do {
            _ = try await server.call(tool: "ft_type", args: ["text": "hello"])
            XCTFail("ドライバが失敗しているのに ft_type が成功した")
        } catch {
            let message = error.localizedDescription
            XCTAssertTrue(message.contains("system alert"), message)
            XCTAssertTrue(message.contains(Self.photosAlert.title!), message)
            XCTAssertTrue(message.contains("ft_launch bundleId: com.apple.springboard"), message)
        }
    }

    /// アラートが無ければ、素のドライバのエラーをそのまま投げる(でっち上げない)
    func testRefLessTypeFailureWithoutAnAlertPropagatesThePlainError() async {
        driver.failing.insert("type")
        do {
            _ = try await server.call(tool: "ft_type", args: ["text": "hello"])
            XCTFail("ドライバが失敗しているのに ft_type が成功した")
        } catch {
            let message = error.localizedDescription
            XCTAssertFalse(message.contains("system alert"), message)
        }
    }

    /// ref を渡した ft_type の失敗には、この一発物の照会を足さない(既にターゲット前提の
    /// systemAlertGate を通っている経路であり、ここでの二重の照会は要らない)
    func testTypeFailureWithARefDoesNotAddTheOneShotProbe() async throws {
        driver.snapshotResponse = SnapshotResponse(
            sessionBundleID: "com.example.app",
            screen: FTRect(x: 0, y: 0, width: 390, height: 844),
            elements: [ElementInfo(ref: 1, type: "textField", identifier: "field_a",
                                   label: nil, value: nil, placeholder: nil, enabled: true,
                                   frame: FTRect(x: 16, y: 168, width: 370, height: 48), depth: 2)],
            truncatedCount: 0)
        _ = try await server.call(tool: "ft_snapshot", args: [:])
        // **verifiedRef の時点ではアラート無し**(alert が出ていれば systemAlertGate が
        // ref 操作そのものを別の理由で断り、ここで確かめたい「ref 形は一発物の照会を
        // 足さない」ことを検証できなくなる)。type() 自体の失敗だけを起こす
        driver.failing.insert("type")
        do {
            _ = try await server.call(tool: "ft_type", args: ["ref": 1, "text": "hello"])
            XCTFail("ドライバが失敗しているのに ft_type が成功した")
        } catch {
            let message = error.localizedDescription
            XCTAssertFalse(message.contains("likely explains the missing focus"), message)
            XCTAssertFalse(message.contains("system alert"), message)
        }
    }
}
