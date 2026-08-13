// 2026-08-13 の iOS 実機 MCP 監査由来の修正(欠陥③): セッションの宛先記憶・曖昧さガードが
// `profile:` を数えていなかった。
//
// 実測した実害: ①実機を profile: で操作(port 8144 に解決)→ ②仮想デバイスを port: で操作
// → ③宛先を省いた ft_snapshot が拒否されず仮想デバイスへ行った。実機のブリッジは /status に
// udid を載せないため udid/port で名指しできず、profile: が実機を指す唯一の現実的な手段
// —— recordsIOSMemory/recordsAndroidMemory が profile を見ないと、実機を使うセッションは
// 2台目を触っても曖昧さガードに数えられない。

import XCTest
@testable import ftester_mcp

final class MCPAuditFixes20260813PhysicalDeviceTests: XCTestCase {

    private func server() -> MCPServer {
        MCPServer(write: { _ in }, makeDriver: { _ in FakeDriver() }, recordSnapshot: { _, _, _ in })
    }

    // MARK: - 純粋述語(recordsIOSMemory/recordsAndroidMemory)が profile を明示扱いすること

    func testRecordsIOSMemoryTreatsProfileAsExplicit() {
        XCTAssertTrue(MCPServer.recordsIOSMemory(["profile": "ios-device"]),
                     "profile: 指定が明示ターゲットとして数えられていない")
    }

    /// 既存の判定(port/udid 明示・無指定)は壊れていないこと
    func testRecordsIOSMemoryUnaffectedForNonProfileCalls() {
        XCTAssertTrue(MCPServer.recordsIOSMemory(["port": 8123]))
        XCTAssertFalse(MCPServer.recordsIOSMemory([:]))
    }

    /// fold が注入した呼び出しは、profile と同居していても明示扱いしない
    /// (実際には fold が profile 呼び出しへ注入することは無いが、述語自体がガードを守ることを固定する)
    func testRecordsIOSMemoryStillIgnoresInjectedCallsEvenWithProfile() {
        let injected: [String: Any] = ["profile": "ios-device", MCPServer.deviceFromMemoryKey: true]
        XCTAssertFalse(MCPServer.recordsIOSMemory(injected))
    }

    func testRecordsAndroidMemoryTreatsProfileAsExplicit() {
        XCTAssertTrue(MCPServer.recordsAndroidMemory(["profile": "android-device"], explicitSerial: nil),
                      "profile: 指定が明示ターゲットとして数えられていない")
    }

    func testRecordsAndroidMemoryUnaffectedForNonProfileCalls() {
        XCTAssertTrue(MCPServer.recordsAndroidMemory(["serial": "emulator-5554"],
                                                     explicitSerial: "emulator-5554"))
        XCTAssertFalse(MCPServer.recordsAndroidMemory([:], explicitSerial: nil))
    }

    func testRecordsAndroidMemoryStillIgnoresInjectedCallsEvenWithProfile() {
        let injected: [String: Any] = ["profile": "android-device", MCPServer.deviceFromMemoryKey: true]
        XCTAssertFalse(MCPServer.recordsAndroidMemory(injected, explicitSerial: nil))
    }

    // MARK: - 配線: rememberResolvedTarget が profile 由来の宛先を実際に記録すること

    /// フラグを手で立てず、記録点そのものを通す(LostTargetFoldTests と同じ規律 ——
    /// 「常に記録しない」変異をここで捕まえる)
    func testRememberResolvedTargetRecordsAProfileOriginatedIOSTarget() {
        let s = server()
        XCTAssertFalse(s.everNamedIOSTarget)
        s.rememberResolvedTarget(platform: "ios", args: ["profile": "ios-device", "project": "E2E-iOS"],
                                 iosPort: 8144, iosUDID: nil, androidSerial: nil)
        XCTAssertTrue(s.everNamedIOSTarget, "profile: 経由の宛先が明示として記録されていない")
        XCTAssertEqual(s.seenExplicitIOSPorts, [8144])
        XCTAssertEqual(s.lastExplicitIOSTarget?.port, 8144)
        XCTAssertEqual(s.lastExplicitPlatform, "ios")
    }

    func testRememberResolvedTargetRecordsAProfileOriginatedAndroidTarget() {
        let s = server()
        XCTAssertFalse(s.everNamedAndroidTarget)
        s.rememberResolvedTarget(platform: "android", args: ["profile": "android-device"],
                                 iosPort: nil, iosUDID: nil, androidSerial: "emulator-5554")
        XCTAssertTrue(s.everNamedAndroidTarget, "profile: 経由の Android 宛先が記録されていない")
        XCTAssertEqual(s.seenExplicitAndroidSerials, ["emulator-5554"])
    }

    /// **ソース走査**: driver() の profile 分岐が rememberResolvedTarget を呼ぶこと。
    /// この分岐は makeDriver 注入(テストの FakeDriver 経路)より手前で短絡されるため、
    /// call() 越しには一度も実行できない(踏めない枝の退行はソースで止める。
    /// MCPSessionMemoryCacheHitTests.testCachedDriverBranchCallsTheRecorder と同じ理由)
    func testProfileBranchOfDriverCallsTheRecorder() throws {
        let source = try String(
            contentsOf: URL(fileURLWithPath: #filePath)
                .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
                .appendingPathComponent("Sources/ftester-mcp/MCPServer+Driver.swift"),
            encoding: .utf8)
        let marker = "if let profileName = args[\"profile\"] as? String {"
        let start = try XCTUnwrap(source.range(of: marker), "profile 分岐の開始が見つからない")
        let tail = source[start.upperBound...]
        let returnCreated = try XCTUnwrap(tail.range(of: "return created"),
                                          "profile 分岐の return が見つからない")
        let body = String(tail[..<returnCreated.lowerBound])
        // **OS ごとに1本ずつ要求する**: 「分岐のどこかに1回あるか」だと、片方の OS だけ
        // 外す変異を素通しする(実測: .ios 側だけ落とした変異が生き残った)
        for platform in ["ios", "android"] {
            XCTAssertTrue(body.contains("rememberResolvedTarget(platform: \"\(platform)\""),
                         "profile 分岐が \(platform) の宛先を記録していない"
                         + "(記録しないとその OS の profile: 宛先は一度も記憶されず、"
                         + "曖昧さガードが働かない)")
        }
    }

    /// **ソース走査**: ft_list_apps の iOS 分岐が、実機を simctl より手前で振り分けること。
    /// 実機の有無に依存するのでテストからは踏めない(欠陥⑤: 実機 udid を simctl へ素通しすると
    /// `Invalid device` で死ぬ)
    func testListAppsRoutesPhysicalDevicesAwayFromSimctl() throws {
        let source = try String(
            contentsOf: URL(fileURLWithPath: #filePath)
                .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
                .appendingPathComponent("Sources/ftester-mcp/MCPServer+Dispatch.swift"),
            encoding: .utf8)
        let start = try XCTUnwrap(source.range(of: "case \"ft_list_apps\":"),
                                  "ft_list_apps の分岐が見つからない")
        let tail = source[start.upperBound...]
        let end = try XCTUnwrap(tail.range(of: "case \"ft_logs\":"), "次の case が見つからない")
        let body = String(tail[..<end.lowerBound])
        let physical = try XCTUnwrap(body.range(of: "IOSPhysicalAppCatalog.apps"),
                                     "実機の経路が無い —— 実機 udid が simctl へ素通しされる")
        let simctl = try XCTUnwrap(body.range(of: "SimulatorAppCatalog.apps"),
                                   "シミュレータの経路が無い")
        XCTAssertTrue(physical.lowerBound < simctl.lowerBound,
                      "実機の振り分けが simctl の後ろにある —— 先に simctl が呼ばれて死ぬ")
    }

    // MARK: - 実測した実害の再現(修正後は拒否される)

    /// ①実機を profile: で操作 → ②仮想デバイスを port: で操作 → ③宛先を省いた呼び出し。
    /// 修正前は profile 側が一度も記録されず「1台しか触っていない」ことになり、②へ黙って流れた。
    /// 修正後は2台名指ししたことになり、曖昧として拒否される
    func testOmittedCallIsRefusedAfterAPhysicalProfileDeviceAndADirectPortDeviceWereBothDriven() {
        let s = server()
        s.rememberResolvedTarget(platform: "ios", args: ["profile": "ios-device", "project": "E2E-iOS"],
                                 iosPort: 8144, iosUDID: nil, androidSerial: nil)
        s.rememberResolvedTarget(platform: "ios", args: ["port": 8124],
                                 iosPort: 8124, iosUDID: nil, androidSerial: nil)
        guard case .ambiguous(let message) = s.foldInRememberedDevice([:]) else {
            return XCTFail("2台触ったのに省略呼び出しが1台へ黙って流れた(欠陥③の再現)")
        }
        XCTAssertTrue(message.contains("8144") && message.contains("8124"), message)
    }

    /// 対照: profile で1台だけ触ったセッションは、宛先省略でそのままそこへ戻る
    /// (曖昧さガードは「2台以上」でだけ発動する)
    func testOmittedCallReusesTheSingleProfileDrivenDevice() {
        let s = server()
        s.rememberResolvedTarget(platform: "ios", args: ["profile": "ios-device", "project": "E2E-iOS"],
                                 iosPort: 8144, iosUDID: nil, androidSerial: nil)
        guard case .applied(let args, let note) = s.foldInRememberedDevice([:]) else {
            return XCTFail("1台しか触っていないのに記憶が適用されなかった")
        }
        XCTAssertEqual(args["port"] as? Int, 8144)
        XCTAssertTrue(note.contains("8144"), note)
    }
}
