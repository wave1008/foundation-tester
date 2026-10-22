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

    /// **アラートはアプリの木に出ない**ので、閉じてもアプリの木は変わらないのが正常 —— snapshotAfter で
    /// 「効かなかったかも」と言わない。実測(Apple マップ): 同じ応答で「マップに戻った」と言いながら
    /// `the tree still looked unchanged … the action may not have changed the screen` を並べていた
    func testSnapshotAfterDoesNotSayThePressHadNoEffectBecauseTheAppTreeIsUnchanged() async throws {
        let app = SnapshotResponse(
            sessionBundleID: "com.apple.Maps", screen: FTRect(x: 0, y: 0, width: 402, height: 874),
            elements: [element(1, "searchField", "マップで検索", depth: 2)], truncatedCount: 0)
        _ = try await server.call(tool: "ft_launch", args: ["bundleId": "com.apple.Maps"])
        driver.snapshotResponse = app
        _ = try await server.call(tool: "ft_snapshot", args: [:])
        arrangeLocationAlert()
        let board = driver.snapshotResponse
        driver.scriptedSnapshots = [board, app, app]
        driver.snapshotResponse = app
        server.settleWaitSeconds = 0
        let result = try await server.call(tool: "ft_tap",
                                           args: ["alertButton": "許可しない", "snapshotAfter": true])
        let text = result.compactMap { $0["text"] as? String }.joined()
        XCTAssertTrue(text.contains("back on com.apple.Maps"), text)
        XCTAssertTrue(text.contains("マップで検索"), "押した後のアプリの木を返していない: \(text)")
        XCTAssertFalse(text.contains("may not have changed the screen"), text)
        XCTAssertFalse(text.contains("looked unchanged"), text)
    }

    /// **home / appSwitcher も相手はアプリの木の外**(XCUITest は背面化してもアプリの木を返し続ける)。
    /// 同じ応答で「背面へ送った」と言いながら「効かなかったかも」を並べない。back は従来どおり比べる
    func testNavigateHomeDoesNotSayItHadNoEffectButBackStillCompares() async throws {
        let app = SnapshotResponse(
            sessionBundleID: "com.apple.Maps", screen: FTRect(x: 0, y: 0, width: 402, height: 874),
            elements: [element(1, "searchField", "マップで検索", depth: 2)], truncatedCount: 0)
        _ = try await server.call(tool: "ft_launch", args: ["bundleId": "com.apple.Maps"])
        driver.snapshotResponse = app
        _ = try await server.call(tool: "ft_snapshot", args: [:])
        server.settleWaitSeconds = 0
        let home = try await server.call(tool: "ft_navigate", args: ["target": "home", "snapshotAfter": true])
        let homeText = home.compactMap { $0["text"] as? String }.joined()
        XCTAssertFalse(homeText.contains("may not have changed the screen"), homeText)
        let back = try await server.call(tool: "ft_navigate", args: ["target": "back", "snapshotAfter": true])
        let backText = back.compactMap { $0["text"] as? String }.joined()
        XCTAssertTrue(backText.contains("may not have changed the screen"),
                      "back は snapshotAfter の木の比較を続けること: \(backText)")
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

    /// udid だけの呼び出しは XCUITest のポートを先に採る(MCP の iOS は常に XCUITest)。走査の順に依らない
    func testUDIDOnlyCallsPreferTheXCUITestBridge() {
        let found = [
            BridgeDiscovery.Found(port: 8137, device: "iPhone", bridge: "xcuitest", udid: "U1"),
            BridgeDiscovery.Found(port: 8136, device: "iPhone", bridge: "inapp", udid: "U1"),
        ]
        XCTAssertEqual(MCPServer.explorationOrder(found), [8137, 8136])
        XCTAssertEqual(MCPServer.explorationOrder(Array(found.reversed())), [8137, 8136])
        XCTAssertEqual(MCPServer.explorationOrder([found[1]]), [8136],
                       "in-app しか無ければそれを採る(ExploreDriverResolver が XCUITest へ振り替える)")
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
