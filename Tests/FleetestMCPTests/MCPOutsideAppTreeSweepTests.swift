// 「アプリの木の外で起きたこと(システムアラート・別のアプリ・キーボード)を、アプリの木の前後比較だけで判断する」型の掃討。
// 直した経路ごとに1本ずつ、MCP の応答まで通して固定する(判定の純粋関数は FTCore 側のテストが持つ)。

import XCTest
import FTCore
@testable import fleetest_mcp

final class MCPOutsideAppTreeSweepTests: XCTestCase {

    private var driver: FakeDriver!
    private var server: MCPServer!

    override func setUp() {
        super.setUp()
        driver = FakeDriver()
        let fake = driver!
        server = MCPServer(write: { _ in }, makeDriver: { _ in fake }, recordSnapshot: { _, _, _ in })
        server.settleWaitSeconds = 0
    }

    private let screen = FTRect(x: 0, y: 0, width: 402, height: 874)

    private func element(_ ref: Int, _ type: String, _ label: String, y: Double) -> ElementInfo {
        ElementInfo(ref: ref, type: type, identifier: nil, label: label, value: nil, placeholder: nil,
                    enabled: true, frame: FTRect(x: 16, y: y, width: 370, height: 44), depth: 2)
    }

    private func tree(_ elements: [ElementInfo], keyboard: FTRect? = nil) -> SnapshotResponse {
        SnapshotResponse(sessionBundleID: "com.example.app", screen: screen, elements: elements,
                         truncatedCount: 0, keyboardFrame: keyboard)
    }

    private func text(_ content: [[String: Any]]) -> String {
        content.compactMap { $0["text"] as? String }.joined()
    }

    /// **座標でシステムアラートを押した ft_tap**: アラートはアプリの木の外なので「効かなかったかも」と言わない
    func testCoordinateTapOnASystemAlertDoesNotSayItHadNoEffect() async throws {
        driver.snapshotResponse = tree([element(1, "button", "検索", y: 100)])
        _ = try await server.call(tool: "ft_snapshot", args: [:])
        driver.scriptedSystemAlert = SystemAlertProbeResponse(
            present: true, title: "位置情報の使用を許可しますか?", buttons: ["許可しない"])
        let result = try await server.call(tool: "ft_tap", args: ["x": 200.0, "y": 500.0, "snapshotAfter": true])
        XCTAssertFalse(text(result).contains("may not have changed the screen"), text(result))
    }

    /// 陰性対照: アラートが無い座標タップは従来どおり比べる
    func testCoordinateTapWithoutAnAlertStillCompares() async throws {
        driver.snapshotResponse = tree([element(1, "button", "検索", y: 100)])
        _ = try await server.call(tool: "ft_snapshot", args: [:])
        let result = try await server.call(tool: "ft_tap", args: ["x": 200.0, "y": 500.0, "snapshotAfter": true])
        XCTAssertTrue(text(result).contains("may not have changed the screen"), text(result))
    }

    /// **キーボードを閉じただけの操作は「変わった」**(looksUnchanged がキーボードの出入りを数える)
    func testHidingTheKeyboardIsNotReportedAsNoChange() async throws {
        let field = element(1, "textField", "名前", y: 100)
        driver.snapshotResponse = tree([field], keyboard: FTRect(x: 0, y: 540, width: 402, height: 334))
        _ = try await server.call(tool: "ft_snapshot", args: [:])
        driver.snapshotResponse = tree([field])
        let result = try await server.call(tool: "ft_tap", args: ["x": 200.0, "y": 300.0, "snapshotAfter": true])
        XCTAssertFalse(text(result).contains("may not have changed the screen"), text(result))
    }

    /// **ft_open_url の受け手が別のアプリかもしれない**ことを、木が配送の前後で同一だったときだけ言う(iOS)
    func testOpenURLOtherAppCaveatOnlyWhenTheTreeDidNotChange() {
        let before = tree([element(1, "button", "検索", y: 100)])
        let changed = tree([element(1, "button", "結果", y: 100)])
        XCTAssertTrue(MCPServer.openURLOtherAppCaveat(routedByScheme: true, before: before, after: before)
            .contains("another app handles this URL"))
        XCTAssertEqual(MCPServer.openURLOtherAppCaveat(routedByScheme: true, before: before, after: changed), "")
        XCTAssertEqual(MCPServer.openURLOtherAppCaveat(routedByScheme: false, before: before, after: before), "",
                       "Android は宛先のパッケージへ配る")
        XCTAssertEqual(MCPServer.openURLOtherAppCaveat(routedByScheme: true, before: nil, after: before), "")
    }

    /// **ft_drag の fromRef も ft_tap と同じ被覆**: キーボードの下から始めるドラッグは断る
    func testDragFromARefUnderTheKeyboardIsRefused() async throws {
        let row = element(1, "button", "行", y: 700)
        driver.snapshotResponse = tree([row], keyboard: FTRect(x: 0, y: 540, width: 402, height: 334))
        _ = try await server.call(tool: "ft_snapshot", args: [:])
        do {
            _ = try await server.call(tool: "ft_drag", args: ["fromRef": 1, "dy": -200.0])
            XCTFail("キーボードの下の要素からドラッグした")
        } catch {
            XCTAssertTrue("\(error)".contains("keyboard"), "\(error)")
        }
        XCTAssertFalse(driver.calls.contains { $0.hasPrefix("drag(") }, "\(driver.calls)")
    }

    /// 座標のドラッグは断らず、キーボードの上だと警告する(ft_tap の座標形と同じ)
    func testCoordinateDragStartingOnTheKeyboardWarns() async throws {
        driver.snapshotResponse = tree([element(1, "button", "行", y: 100)],
                                       keyboard: FTRect(x: 0, y: 540, width: 402, height: 334))
        _ = try await server.call(tool: "ft_snapshot", args: [:])
        let result = try await server.call(tool: "ft_drag", args: ["fromX": 200.0, "fromY": 700.0, "dy": -200.0])
        XCTAssertTrue(text(result).contains("inside the soft keyboard"), text(result))
    }

    /// **ft_type の後、次の ref 操作の撮り直しで、画面の外のキーボードが上がるまで待つ**(読みは足さない)
    func testTheNextRefTapAfterATypeWaitsForAKeyboardStillBelowTheScreen() async throws {
        let field = element(1, "textField", "名前", y: 100)
        let send = element(2, "button", "送信", y: 820)
        driver.snapshotResponse = tree([field, send])
        _ = try await server.call(tool: "ft_snapshot", args: [:])
        let hidden = tree([field, send], keyboard: FTRect(x: 0, y: 891, width: 402, height: 233))
        let shown = tree([field, send], keyboard: FTRect(x: 0, y: 540, width: 402, height: 334))
        driver.scriptedSnapshots = [tree([field, send])]
        _ = try await server.call(tool: "ft_type", args: ["ref": 1, "text": "abc"])
        let typed = driver.calls.filter { $0.hasPrefix("snapshot") }.count
        driver.scriptedSnapshots = [hidden, hidden, shown]
        do {
            _ = try await server.call(tool: "ft_tap", args: ["ref": 2])
            XCTFail("上がったキーボードの下の送信ボタンを押した")
        } catch {
            XCTAssertTrue("\(error)".contains("keyboard"), "上がりきった木で判定していない: \(error)")
        }
        XCTAssertEqual(driver.calls.filter { $0.hasPrefix("snapshot") }.count - typed, 3, "\(driver.calls)")
    }

    /// 陰性対照: type の後でもキーボードが既に画面に出ていれば待たない(読みを足さない)
    func testTheNextRefTapDoesNotWaitWhenTheKeyboardIsAlreadyUp() async throws {
        let field = element(1, "textField", "名前", y: 100)
        let ok = element(2, "button", "OK", y: 300)
        let shown = tree([field, ok], keyboard: FTRect(x: 0, y: 540, width: 402, height: 334))
        driver.snapshotResponse = shown
        _ = try await server.call(tool: "ft_snapshot", args: [:])
        _ = try await server.call(tool: "ft_type", args: ["ref": 1, "text": "abc"])
        let typed = driver.calls.filter { $0.hasPrefix("snapshot") }.count
        _ = try await server.call(tool: "ft_tap", args: ["ref": 2])
        XCTAssertEqual(driver.calls.filter { $0.hasPrefix("snapshot") }.count - typed, 1, "\(driver.calls)")
    }

    /// **type の後に別の操作を挟んだら、出現待ちは捨てる**(打つ前の木が古くなる。Android は「出ていない → 出るはず」と読んで
    /// 閉じた後の ref 操作でも 1.5 秒待っていた)。ここは iOS の形で固定する: 打った後の木が画面の外のキーボードを申告したまま
    /// (= 待つ側)でも、間に座標の swipe を挟めば次の ref タップは読みを足さない
    func testThePendingKeyboardWaitIsDroppedWhenAnotherActionIntervenes() async throws {
        let field = element(1, "textField", "名前", y: 100)
        let ok = element(2, "button", "OK", y: 300)
        driver.snapshotResponse = tree([field, ok])
        _ = try await server.call(tool: "ft_snapshot", args: [:])
        _ = try await server.call(tool: "ft_type", args: ["ref": 1, "text": "abc"])
        _ = try await server.call(tool: "ft_swipe", args: ["finger": "up"])
        let hidden = tree([field, ok], keyboard: FTRect(x: 0, y: 891, width: 402, height: 233))
        driver.snapshotResponse = hidden
        let before = driver.calls.filter { $0.hasPrefix("snapshot") }.count
        _ = try await server.call(tool: "ft_tap", args: ["ref": 2])
        XCTAssertEqual(driver.calls.filter { $0.hasPrefix("snapshot") }.count - before, 1,
                       "捨てた待ちで撮り直している: \(driver.calls)")
    }
}
