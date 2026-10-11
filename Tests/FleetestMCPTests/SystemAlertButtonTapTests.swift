// ft_tap alertButton: — 前面のシステムアラートのボタンを1回の呼び出しで押し、アプリへ向け直す。
// 以前は ft_launch(springboard)→ ft_tap(ref)→ ft_launch(resume)の3回が要った(Apple マップの位置情報の許可)

import XCTest
import FTCore
import FTBridgeClient
@testable import fleetest_mcp

final class SystemAlertButtonTapTests: XCTestCase {

    private var driver: FakeDriver!
    private var server: MCPServer!

    override func setUp() {
        super.setUp()
        driver = FakeDriver()
        let fake = driver!
        server = MCPServer(write: { _ in }, makeDriver: { _ in fake }, recordSnapshot: { _, _, _ in })
    }

    private func element(_ ref: Int, _ type: String, _ label: String, depth: Int) -> ElementInfo {
        ElementInfo(ref: ref, type: type, identifier: nil, label: label, value: nil, placeholder: nil,
                    enabled: true, frame: FTRect(x: 57, y: 458 + Double(ref) * 56, width: 288, height: 48),
                    depth: depth)
    }

    /// SpringBoard の木: ホーム画面に**同じ文字のアイコン**があり、アラートの中に本物のボタンがある
    private func arrangeLocationAlert() {
        driver.scriptedSystemAlert = SystemAlertProbeResponse(
            present: true, title: "“マップ”に位置情報の使用を許可しますか?",
            buttons: ["1度だけ許可", "アプリの使用中は許可", "許可しない"])
        driver.snapshotResponse = SnapshotResponse(
            sessionBundleID: "com.apple.springboard", screen: FTRect(x: 0, y: 0, width: 402, height: 874),
            elements: [
                element(1, "button", "許可しない", depth: 1),
                element(2, "alert", "“マップ”に位置情報の使用を許可しますか?", depth: 1),
                element(3, "button", "1度だけ許可", depth: 3),
                element(4, "button", "許可しない", depth: 3),
            ], truncatedCount: 0)
    }

    func testPressesTheNamedButtonInsideTheAlertAndReturnsToTheApp() async throws {
        _ = try await server.call(tool: "ft_launch", args: ["bundleId": "com.apple.Maps"])
        arrangeLocationAlert()
        let result = try await server.call(tool: "ft_tap", args: ["alertButton": "許可しない"])
        let text = result.compactMap { $0["text"] as? String }.joined()
        XCTAssertTrue(text.contains("Pressed \"許可しない\""), text)
        XCTAssertTrue(text.contains("back on com.apple.Maps"), text)
        let calls = driver.calls
        let toBoard = try XCTUnwrap(calls.lastIndex(of: "launch(com.apple.springboard)"), "\(calls)")
        let press = try XCTUnwrap(calls.firstIndex(of: "tap(ref:4)"), "アラートの中のボタンを押していない: \(calls)")
        let back = try XCTUnwrap(calls.firstIndex(of: "attach(com.apple.Maps)"), "\(calls)")
        XCTAssertLessThan(toBoard, press, "\(calls)")
        XCTAssertLessThan(press, back, "\(calls)")
        XCTAssertFalse(calls.contains("tap(ref:1)"), "アラートの外の同じ文字を押した: \(calls)")
        XCTAssertFalse(calls.contains("activate(com.apple.Maps)"), "向け直しに activate を使った: \(calls)")
    }

    /// 戻る先が分からない(起動もしておらず木も読んでいない)ときは、SpringBoard に向いたままだと言う
    func testSaysTheSessionStaysOnSpringBoardWhenThereIsNoAppToReturnTo() async throws {
        arrangeLocationAlert()
        let result = try await server.call(tool: "ft_tap", args: ["alertButton": "許可しない"])
        let text = result.compactMap { $0["text"] as? String }.joined()
        XCTAssertTrue(text.contains("still pointed at SpringBoard"), text)
    }

    /// **無いボタンは押さない**(SpringBoard へも向けない)。ボタンの一覧を返す
    func testRefusesAButtonTheAlertDoesNotHave() async throws {
        _ = try await server.call(tool: "ft_launch", args: ["bundleId": "com.apple.Maps"])
        arrangeLocationAlert()
        do {
            _ = try await server.call(tool: "ft_tap", args: ["alertButton": "許可"])
            XCTFail("無いボタンが通った")
        } catch {
            XCTAssertTrue(error.localizedDescription.contains("\"許可しない\""), error.localizedDescription)
        }
        XCTAssertFalse(driver.calls.contains("launch(com.apple.springboard)"), "\(driver.calls)")
        XCTAssertFalse(driver.calls.contains { $0.hasPrefix("tap(") }, "\(driver.calls)")
    }

    /// アラートが出ていなければ何も押さない
    func testRefusesWhenNoAlertIsInFront() async throws {
        _ = try await server.call(tool: "ft_launch", args: ["bundleId": "com.apple.Maps"])
        do {
            _ = try await server.call(tool: "ft_tap", args: ["alertButton": "許可しない"])
            XCTFail("アラートが無いのに通った")
        } catch {
            XCTAssertTrue(error.localizedDescription.contains("no system alert"), error.localizedDescription)
        }
        XCTAssertFalse(driver.calls.contains { $0.hasPrefix("tap(") }, "\(driver.calls)")
    }

    /// **hybrid でも押せる**(エンジンを意識させない。SpringBoard は hybrid が XCUITest 側へ寄せる)
    func testWorksOnTheHybridEngine() async throws {
        _ = try await server.call(tool: "ft_launch", args: ["bundleId": "com.apple.Maps"])
        server.engines[MCPServer.engineKey([:])] = "hybrid"
        arrangeLocationAlert()
        _ = try await server.call(tool: "ft_tap", args: ["alertButton": "許可しない"])
        XCTAssertTrue(driver.calls.contains("tap(ref:4)"), "\(driver.calls)")
    }

    /// in-app だけ(XCUITest を用意できなかった)のときは SpringBoard を掴めないので断る
    func testRefusesOnAnInAppOnlyBridge() async throws {
        _ = try await server.call(tool: "ft_launch", args: ["bundleId": "com.apple.Maps"])
        server.engines[MCPServer.engineKey([:])] = "inapp"
        arrangeLocationAlert()
        do {
            _ = try await server.call(tool: "ft_tap", args: ["alertButton": "許可しない"])
            XCTFail("in-app だけで通った")
        } catch {
            XCTAssertTrue(error.localizedDescription.contains("in-app bridge alone"), error.localizedDescription)
        }
        XCTAssertFalse(driver.calls.contains { $0.hasPrefix("tap(") }, "\(driver.calls)")
    }

    /// udid だけの呼び出しは、応答している in-app のポートを先に採る(hybrid で組まれる)。走査の順に依らない
    func testUDIDOnlyCallsPreferTheInAppBridge() {
        let found = [
            BridgeDiscovery.Found(port: 8137, device: "iPhone", engine: "xcuitest", udid: "U1"),
            BridgeDiscovery.Found(port: 8136, device: "iPhone", engine: "inapp", udid: "U1"),
        ]
        XCTAssertEqual(MCPServer.explorationOrder(found), [8136, 8137])
        XCTAssertEqual(MCPServer.explorationOrder(Array(found.reversed())), [8136, 8137])
        XCTAssertEqual(MCPServer.explorationOrder([found[0]]), [8137], "in-app が無ければ XCUITest")
    }

    /// ref と併用させない(どちらを押したのか読み手が決められない)
    func testRefusesAlertButtonTogetherWithARef() async {
        do {
            _ = try await server.call(tool: "ft_tap", args: ["alertButton": "許可しない", "ref": 1])
            XCTFail("ref と併用できた")
        } catch {
            XCTAssertTrue(error.localizedDescription.contains("not both"), error.localizedDescription)
        }
    }
}
