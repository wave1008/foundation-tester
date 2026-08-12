// 2026-08-12 の実アプリ監査(赤羽→立川)由来の修正3件:
//   ① ft_navigate に snapshotAfter/waitFor 系を足す(back/home/appSwitcher だけ木を返せなかった)
//   ② ft_status / ft_list_devices にエンジン(inapp/xcuitest)を出す
//   ③ connectionLostMessage の稼働ブリッジ列挙を「同じ端末を先に・残りは件数」へ畳む

import XCTest
import FTBridgeClient
import FTCore
@testable import ftester_mcp

final class MCPAuditFixes20260812Round13Tests: XCTestCase {

    // MARK: - ① ft_navigate のスキーマ

    /// **ft_tap と同じ語彙**であること(新しい言い回しを発明しない)。
    /// スキーマの description は共有 let 定数(snapshotAfterProperty 等)を通していれば
    /// 自動的に一致するので、ここでは「その定数を実際に使っているか」を固定する
    func testNavigateDeclaresTheSameSnapshotAfterVocabularyAsTap() {
        func properties(_ name: String) -> [String: Any] {
            let definition = MCPServer.toolDefinitions.first { $0["name"] as? String == name }
            let schema = definition?["inputSchema"] as? [String: Any]
            return schema?["properties"] as? [String: Any] ?? [:]
        }
        let tapProps = properties("ft_tap")
        let navigateProps = properties("ft_navigate")
        for key in ["snapshotAfter", "waitFor", "timeout", "expandBulk", "interactiveOnly"] {
            let tapDescription = (tapProps[key] as? [String: Any])?["description"] as? String
            let navigateDescription = (navigateProps[key] as? [String: Any])?["description"] as? String
            XCTAssertNotNil(navigateDescription, "ft_navigate に \(key) が無い")
            XCTAssertEqual(tapDescription, navigateDescription,
                           "\(key) の説明が ft_tap と食い違う(独自の言い回しを作っていないか)")
        }
    }

    /// **back のポーリングで撮った木を捨てて撮り直さない**: snapshotAfter: true のときは
    /// 効果判定のポーリング(4回まで)を挟まず、snapshotAfterBody が撮った1枚を無効判定にも使う。
    /// 二重取得なら driver.calls に "snapshot" が複数回積まれるはず
    /// (前面照会などスナップショット以外の呼び出しは数えない —— 数えるのは撮影回数)
    func testNavigateWithSnapshotAfterDoesNotDoubleFetchTheTree() async throws {
        let driver = FakeDriver()
        let server = MCPServer(write: { _ in }, makeDriver: { _ in driver },
                               recordSnapshot: { _, _, _ in })
        let content = try await server.call(
            tool: "ft_navigate", args: ["target": "back", "snapshotAfter": true])
        XCTAssertEqual(driver.calls.filter { $0 == "snapshot" }.count, 1,
                       "back の効果判定ポーリングと snapshotAfterBody の両方が撮ると二重取得になる:"
                       + " \(driver.calls)")
        XCTAssertEqual(driver.calls.first, "back")
        let text = try XCTUnwrap(content.first?["text"] as? String)
        // 撮り直した木がそのまま返っていること(「撮り直せ」の勧めは出ない)
        XCTAssertFalse(text.contains("Take a fresh ft_snapshot to see the result"), text)
    }

    /// snapshotAfter を渡さないときは従来どおり: 撮り直しを勧める文言のまま
    func testNavigateWithoutSnapshotAfterStillTellsYouToSnapshot() async throws {
        let driver = FakeDriver()
        let server = MCPServer(write: { _ in }, makeDriver: { _ in driver },
                               recordSnapshot: { _, _, _ in })
        let content = try await server.call(tool: "ft_navigate", args: ["target": "home"])
        let text = try XCTUnwrap(content.first?["text"] as? String)
        XCTAssertTrue(text.contains("Take a fresh ft_snapshot to see the result"), text)
        XCTAssertEqual(driver.calls, ["home"])
    }

    // MARK: - ② ft_list_devices のエンジン表記

    /// 同じ端末に in-app / XCUITest が同時に立つとき、**両方**出ること
    func testLineListsEveryEngineOnTheSameDevice() {
        let row = DeviceInventory.Row(
            name: "iPhone 17 Pro", platform: "ios", identifier: "SIM-1",
            running: true, physical: false, registered: true,
            bridges: [DeviceInventory.Row.Bridge(port: 8143, engine: "inapp"),
                     DeviceInventory.Row.Bridge(port: 8124, engine: "xcuitest")])
        let text = DeviceInventory.line(row)
        XCTAssertTrue(text.contains("port 8143 (inapp)"), text)
        XCTAssertTrue(text.contains("port 8124 (xcuitest)"), text)
    }

    /// エンジンが判別できないとき(engine: nil)は**捏造しない** —— 括弧無しでポートだけ
    func testLineOmitsEngineWhenUnknown() {
        let row = DeviceInventory.Row(
            name: "iPhone 17 Pro", platform: "ios", identifier: "SIM-1",
            running: true, physical: false, registered: true,
            bridges: [DeviceInventory.Row.Bridge(port: 8143, engine: nil)])
        let text = DeviceInventory.line(row)
        XCTAssertTrue(text.contains("bridge port 8143"), text)
        // 行全体は外側の括弧で包まれる("- name (ios, ..., bridge port N)") ので、
        // 見るのはポート直後だけ — 捏造した engine 注記が無いこと
        XCTAssertFalse(text.contains("8143 ("), text)
    }

    /// iosRow: 稼働中カタログに複数ブリッジがあれば、liveBridges の並びがそのまま row.bridges へ通ること
    func testIOSRowCarriesEveryLiveBridgeForTheMatchedDevice() {
        let device = SimDeviceInfo(udid: "SIM-1", name: "iPhone 17 Pro", os: "iOS 26.0", booted: true)
        let row = DeviceInventory.iosRow(
            spec: DeviceSpec(name: "primary", simulator: "iPhone 17 Pro"),
            simDevices: [device], physicalDevices: [],
            liveBridges: ["iPhone 17 Pro": [DeviceInventory.Row.Bridge(port: 8143, engine: "inapp"),
                                            DeviceInventory.Row.Bridge(port: 8124, engine: "xcuitest")]])
        XCTAssertEqual(row.bridges,
                       [DeviceInventory.Row.Bridge(port: 8143, engine: "inapp"),
                        DeviceInventory.Row.Bridge(port: 8124, engine: "xcuitest")])
    }

    /// 端末が動いていなければブリッジ情報は乗せない(booted=false の機に稼働中カタログの
    /// 情報を誤って持たせない)
    func testIOSRowIgnoresLiveBridgesWhenNotRunning() {
        let row = DeviceInventory.iosRow(
            spec: DeviceSpec(name: "stopped", simulator: "iPad Pro"),
            simDevices: [], physicalDevices: [],
            liveBridges: ["iPad Pro": [DeviceInventory.Row.Bridge(port: 8143, engine: "inapp")]])
        XCTAssertFalse(row.running)
        XCTAssertTrue(row.bridges.isEmpty)
    }

    // MARK: - ③ connectionLostMessage の畳み方

    private func found(_ port: UInt16, device: String, engine: String = "xcuitest") -> BridgeDiscovery.Found {
        BridgeDiscovery.Found(port: port, device: device, engine: engine)
    }

    /// **同じ端末を先に**、残りは件数へ畳む
    func testRunningBridgesSummaryPutsTheSameDeviceFirstAndFoldsTheRest() {
        let running = [
            found(8130, device: "iPhone 17 Pro-01"),
            found(8131, device: "iPhone 17 Pro-02"),
            found(8132, device: "iPhone 17 Pro-03"),
            found(8143, device: "iPhone 17 Pro-04", engine: "inapp"),
            found(8144, device: "iPhone 17 Pro-04", engine: "xcuitest"),
        ]
        let summary = MCPServer.runningBridgesSummary(running, sameDevice: "iPhone 17 Pro-04")
        XCTAssertTrue(summary.hasPrefix("port 8143"), summary)
        XCTAssertTrue(summary.contains("port 8144"), summary)
        // 上限3本ぶんが名指しされ、残り2本は件数だけ
        XCTAssertTrue(summary.contains("+2 more on other devices"), summary)
        XCTAssertFalse(summary.contains("8132"), summary)
    }

    /// 上限以下なら畳まない(片方向だけ見ると「常に畳む」変異を素通しする)
    func testRunningBridgesSummaryDoesNotFoldWhenWithinTheCap() {
        let running = [found(8130, device: "A"), found(8131, device: "B")]
        let summary = MCPServer.runningBridgesSummary(running, sameDevice: nil)
        XCTAssertFalse(summary.contains("more"), summary)
        XCTAssertTrue(summary.contains("8130"), summary)
        XCTAssertTrue(summary.contains("8131"), summary)
    }

    /// 端末が判別できない(sameDevice: nil)ときは並び替えず先頭を名指しし、
    /// 「on other devices」は言わない(判別していないことを断言しない)
    func testRunningBridgesSummaryWithoutADeviceHintStillCapsButDoesNotClaimOtherDevices() {
        let running = (0..<5).map { found(UInt16(8130 + $0), device: "device-\($0)") }
        let summary = MCPServer.runningBridgesSummary(running, sameDevice: nil)
        XCTAssertTrue(summary.contains("+2 more"), summary)
        XCTAssertFalse(summary.contains("on other devices"), summary)
    }

    /// connectionLostMessage 全体でも同じ畳みが効くこと(既存の2本挙動は変えない回帰確認)
    func testConnectionLostMessageStillNamesASmallRunningSetInFull() {
        let message = MCPServer.connectionLostMessage(
            connection: "port 8124",
            running: [found(8130, device: "iPhone 17 Pro")])
        XCTAssertTrue(message.contains("port 8124"), message)
        XCTAssertTrue(message.contains("8130"), message)
        XCTAssertFalse(message.contains("more"), message)
    }

    // MARK: - ④ waitForChange(その場で中身が入れ替わる画面)

    /// **陽性**: 木が変わるまで待つ。waitFor は旧結果へ即マッチしてしまうのでここでは使えない
    func testWaitForChangePollsUntilTheTreeDiffers() async throws {
        let driver = FakeDriver()
        driver.scriptedSnapshots = [
            Self.oneElementScreen(label: "old"),   // ft_snapshot(基準)
            Self.oneElementScreen(label: "old"),   // 操作直後: まだ旧内容
            Self.oneElementScreen(label: "new"),   // ポーリング1回目で入れ替わる
        ]
        let server = MCPServer(write: { _ in }, makeDriver: { _ in driver },
                               recordSnapshot: { _, _, _ in })
        _ = try await server.call(tool: "ft_snapshot", args: [:])
        let content = try await server.call(
            tool: "ft_tap", args: ["x": 10.0, "y": 10.0, "snapshotAfter": true, "waitForChange": true])
        let text = try XCTUnwrap(content.first?["text"] as? String)
        XCTAssertTrue(text.contains("waitForChange: the tree differs"), text)
        XCTAssertTrue(text.contains("new"), text)
    }

    /// **陰性**: 変わらないまま期限を迎えたら、変わったとは言わない(嘘の成功を作らない)
    func testWaitForChangeSaysSoWhenNothingChanged() async throws {
        let driver = FakeDriver()
        driver.scriptedSnapshots = [Self.oneElementScreen(label: "old")]   // 以降ずっと同じ
        let server = MCPServer(write: { _ in }, makeDriver: { _ in driver },
                               recordSnapshot: { _, _, _ in })
        _ = try await server.call(tool: "ft_snapshot", args: [:])
        let content = try await server.call(
            tool: "ft_tap", args: ["x": 10.0, "y": 10.0, "snapshotAfter": true,
                                   "waitForChange": true, "timeout": 0.1])
        let text = try XCTUnwrap(content.first?["text"] as? String)
        XCTAssertTrue(text.contains("waitForChange timed out"), text)
        XCTAssertFalse(text.contains("waitForChange: the tree differs"), text)
    }

    /// snapshotAfter 無しで渡したら無視したことを言う(黙って捨てない)
    func testWaitForChangeWithoutSnapshotAfterSaysItWasIgnored() async throws {
        let driver = FakeDriver()
        let server = MCPServer(write: { _ in }, makeDriver: { _ in driver },
                               recordSnapshot: { _, _, _ in })
        let content = try await server.call(
            tool: "ft_tap", args: ["x": 10.0, "y": 10.0, "waitForChange": true])
        let text = try XCTUnwrap(content.first?["text"] as? String)
        XCTAssertTrue(text.contains("waitForChange requires snapshotAfter: true"), text)
    }

    private static func oneElementScreen(label: String) -> SnapshotResponse {
        SnapshotResponse(sessionBundleID: nil,
                         screen: FTRect(x: 0, y: 0, width: 400, height: 800),
                         elements: [ElementInfo(ref: 1, type: "staticText", identifier: "row",
                                                label: label, value: nil, placeholder: nil,
                                                enabled: true,
                                                frame: FTRect(x: 0, y: 0, width: 100, height: 40),
                                                depth: 1)],
                         truncatedCount: 0)
    }

    // MARK: - ⑤ ACTION_SET_TEXT を断られたときの回避策

    /// **陽性**: ref 経路の type が注入器に断られたら、通る書き方(タップ→ref なし type)を出す
    func testSetTextRefusedHintNamesTheWorkingPath() {
        let hint = MCPServer.setTextRefusedHint(
            tool: "ft_type", args: ["ref": 16],
            message: "The driver returned an error (500): cannot type into the field that was"
                + " tapped (ACTION_SET_TEXT refused, 4000ms waited)")
        XCTAssertTrue(hint.contains("WITHOUT ref"), hint)
        XCTAssertTrue(hint.contains("already tapped"), hint)
    }

    /// **陰性**: 関係のない失敗・関係のないツール・ref なしの呼び方には出さない
    /// (どこにでも付く助言は読み飛ばされる)
    func testSetTextRefusedHintStaysQuietElsewhere() {
        XCTAssertEqual(MCPServer.setTextRefusedHint(
            tool: "ft_type", args: ["ref": 16], message: "bridge not running"), "")
        XCTAssertEqual(MCPServer.setTextRefusedHint(
            tool: "ft_tap", args: ["ref": 16],
            message: "cannot type into the field that was tapped (…)"), "")
        XCTAssertEqual(MCPServer.setTextRefusedHint(
            tool: "ft_type", args: [:],
            message: "cannot type into the field that was tapped (…)"), "")
    }
}
