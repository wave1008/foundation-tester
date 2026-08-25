// 2026-08-13 の iOS 実機 MCP 監査由来の修正(欠陥③・④・⑥)。
//
// ③ セッションの宛先記憶・曖昧さガードが `profile:` を数えていなかった。
// 実測した実害: ①実機を profile: で操作(port 8144 に解決)→ ②仮想デバイスを port: で操作
// → ③宛先を省いた ft_snapshot が拒否されず仮想デバイスへ行った。実機のブリッジは /status に
// udid を載せないため udid/port で名指しできず、profile: が実機を指す唯一の現実的な手段
// —— recordsIOSMemory/recordsAndroidMemory が profile を見ないと、実機を使うセッションは
// 2台目を触っても曖昧さガードに数えられない。
//
// ④ 実機は listen を iproxy(別プロセス)が引き継ぐため、XCUITest ランナーが死んでも
// BridgeDiscovery.isBound は true のまま残る。bound だけで .busy と判定すると
// forgetConnection が呼ばれず、profile: の呼び出しが永久に死んだポートへ再ダイヤルされ続ける
// (実測: port 8143 は 65ms で応答するのに profile: 経路は復帰しなかった)。
// pid ファイルの所有プロセス生死(bridgeOwnerAlive)で bound を補強する(trustBound)。
//
// ⑥ ft_list_devices のフォールバック見出しの畳み鍵が理由に依存していなかったため、
// 「別の理由に変わった」2回目の呼び出しまで「初回と同じ理由」として畳まれ、指示どおり
// 原因を直しても直った証拠(新しい理由)が読めなくなっていた。

import XCTest
@testable import fleetest_mcp

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
                .appendingPathComponent("Sources/fleetest-mcp/MCPServer+Driver.swift"),
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
        let source = try MCPServerSourceText.combined()
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

    // MARK: - 欠陥④ trustBound/bridgeUnreachableVerdict(実機の孤児 iproxy を生存中と誤判定しない)

    /// bound=true でも所有プロセスが確認できる形で死んでいれば信じない
    /// (実機は listen を iproxy が引き継ぐので、ランナー死後も bound は true のまま残る)
    func testTrustBoundDoesNotTrustBoundWhenOwnerIsConfirmedDead() {
        XCTAssertFalse(MCPServer.trustBound(bound: true, ownerAlive: false))
    }

    /// ownerAlive が nil(pid ファイル無し = in-app ブリッジ等、判定材料が無い)は疑わない側に倒す
    /// —— nil を死と読むと仮想デバイスの in-app 経路まで巻き添えにする
    func testTrustBoundStillTrustsBoundWhenOwnerIsUnknown() {
        XCTAssertTrue(MCPServer.trustBound(bound: true, ownerAlive: nil))
    }

    func testTrustBoundIsFalseWheneverNotBound() {
        XCTAssertFalse(MCPServer.trustBound(bound: false, ownerAlive: true))
        XCTAssertFalse(MCPServer.trustBound(bound: false, ownerAlive: nil))
    }

    /// bound かつ ownerAlive=false は .busy にならない —— vanished の値で従来どおり決まる
    func testBridgeUnreachableVerdictDoesNotSayBusyWhenOwnerIsConfirmedDead() {
        XCTAssertEqual(
            MCPServer.bridgeUnreachableVerdict(bound: true, ownerAlive: false, vanished: true),
            .vanished)
        XCTAssertEqual(
            MCPServer.bridgeUnreachableVerdict(bound: true, ownerAlive: false, vanished: false),
            .stillUnclear)
    }

    /// bound かつ ownerAlive=nil(in-app 等)は従来どおり busy —— 巻き添えにしない
    func testBridgeUnreachableVerdictStaysBusyWhenOwnerIsUnknown() {
        XCTAssertEqual(
            MCPServer.bridgeUnreachableVerdict(bound: true, ownerAlive: nil, vanished: true), .busy)
    }

    func testBridgeOwnerAliveIsNilWithoutRepoRootOrPidFile() {
        XCTAssertNil(MCPServer.bridgeOwnerAlive(port: 65000, repoRoot: nil))
        let emptyRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent("ft-owner-alive-empty-\(UUID().uuidString)")
        XCTAssertNil(MCPServer.bridgeOwnerAlive(port: 65000, repoRoot: emptyRoot))
    }

    /// pid ファイルを実際に置いて生死判定する(kill(pid, 0) の実地確認)。
    /// 生存中の pid = 自分自身のプロセス。死亡確認済みの pid = waitUntilExit 後の子プロセス
    /// (pid の即時再利用を避けるため、単なるマジックナンバーではなく実測で確定させる)
    func testBridgeOwnerAliveReadsThePidFileAndChecksLiveness() throws {
        let repoRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent("ft-owner-alive-\(UUID().uuidString)")
        let stateDir = repoRoot.appendingPathComponent(".fleetest")
        try FileManager.default.createDirectory(at: stateDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: repoRoot) }

        try String(ProcessInfo.processInfo.processIdentifier).write(
            to: stateDir.appendingPathComponent("bridge-9001.pid"), atomically: true, encoding: .utf8)
        XCTAssertEqual(MCPServer.bridgeOwnerAlive(port: 9001, repoRoot: repoRoot), true)

        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/true")
        try process.run()
        process.waitUntilExit()
        try String(process.processIdentifier).write(
            to: stateDir.appendingPathComponent("bridge-9002.pid"), atomically: true, encoding: .utf8)
        XCTAssertEqual(MCPServer.bridgeOwnerAlive(port: 9002, repoRoot: repoRoot), false)
    }

    /// **配線**: iosConnectionLostHint が ownerAlive を実際に計算し、verdict とスキャン要否の
    /// 両方へ渡していること。純粋関数だけを固定すると「呼び出し側が ownerAlive を渡すのをやめる」
    /// 変異が生き残る(この台帳が繰り返し踏んでいる型)
    func testIosConnectionLostHintWiresOwnerAliveIntoBothDecisions() throws {
        let source = try MCPServerSourceText.combined()
        let start = try XCTUnwrap(source.range(of: "func iosConnectionLostHint("),
                                  "iosConnectionLostHint が見つからない")
        let tail = source[start.upperBound...]
        let end = try XCTUnwrap(tail.range(of: "\n    /// iOS の2分岐"),
                                "iosConnectionLostHint の終端(次の関数のコメント)が見つからない")
        let body = String(tail[..<end.lowerBound])

        XCTAssertTrue(body.contains("Self.bridgeOwnerAlive(port: port, repoRoot: repoRoot)"),
                     "ownerAlive を計算していない —— bound だけでは実機の孤児 iproxy を"
                     + "生存中と誤判定する(欠陥④)")
        XCTAssertTrue(body.contains("ownerAlive: ownerAlive"),
                     "bridgeUnreachableVerdict へ ownerAlive を渡していない")
        XCTAssertTrue(body.contains("Self.trustBound(bound: bound, ownerAlive: ownerAlive)"),
                     "走査を省くかどうかの判定が trustBound を経由していない"
                     + "(手書きの `bound ? [] : …` へ戻すと verdict と条件がずれ得る)")
        XCTAssertFalse(body.contains("bound ? [] : await BridgeDiscovery.scan"),
                       "旧来の bound 単独判定(欠陥④)へ戻っている")
    }

    // MARK: - 欠陥⑥ ft_list_devices の畳み鍵が理由込みであること(実測した実害の再現)

    private func bodyText(_ content: [[String: Any]]) -> String {
        content.compactMap { $0["text"] as? String }.joined(separator: "\n")
    }

    /// 実測: ①project 無指定で失敗(理由A)→ 指示どおり project: を渡す → ②同じ理由がもう一度
    /// 出るなら畳んでよい → ③その後 project: を直しても別の理由(理由B。machine profile が
    /// profiles/machines/ に無い等)で失敗したら、**理由が変わった回は満額で出る**こと。
    /// 修正前は鍵が理由に依存しないため、②はおろか③まで「reason given in the first」で畳まれ、
    /// 直したかどうかを読む手段が消えていた
    func testFallbackHeaderIsFoldedPerReasonNotGlobally() async throws {
        let s = server()
        let missingA = "no-such-project-mcp-audit-defect6-a"
        let missingB = "no-such-project-mcp-audit-defect6-b"

        let first = bodyText(try await s.call(tool: "ft_list_devices", args: ["project": missingA]))
        XCTAssertTrue(first.contains(missingA), first)
        XCTAssertFalse(first.contains("reason given in the first"), first)

        let second = bodyText(try await s.call(tool: "ft_list_devices", args: ["project": missingA]))
        XCTAssertTrue(second.contains("reason given in the first ft_list_devices"),
                      "同じ理由の繰り返しが畳まれていない: \(second)")

        let third = bodyText(try await s.call(tool: "ft_list_devices", args: ["project": missingB]))
        XCTAssertTrue(third.contains(missingB),
                      "理由が変わったのに満額で出ていない(欠陥⑥の再現): \(third)")
        XCTAssertFalse(third.contains("reason given in the first"),
                       "理由が変わった回まで畳まれている(欠陥⑥の再現): \(third)")
    }
}
