// 2026-08-12 のコードレビュー由来の修正:
//   A. セッションデバイス記憶を dispatch 入口(call())で畳む(driver cache/engineKey/ref 世代の
//      不整合を解消)+ fold の4欠陥(udid を注入しない・記憶の再記録ドリフト・serial 明示への
//      誤注入・platform 省略時の Android 記憶の無視)
//   B. forgetConnection の Android 分岐(androidConnectionLostHint 経由。probe で serial の
//      死活を確かめる = adb の文言には依存しない)
//   C. connectionLostHint の bridgeUnreachable が busy を「消えた」と誤読しない
//      (bridgeUnreachableVerdict を production の唯一の判定点にする)+ in-app ブリッジの
//      busy 文言を xcuitest と出し分ける
//   D. ft_type replace の4欠陥(マスク欄の偽警告・正規化なし・clear-only 無検証・
//      snapshotAfter との二重読み)

import XCTest
import FTCore
@testable import fleetest_mcp

final class MCPAuditFixes20260812Round17Tests: XCTestCase {

    // MARK: - ① dispatch 入口でのセッション記憶の fold

    /// **記憶した port が省略呼び出しの args へ実際に注入される**こと。
    /// makeDriver に渡る args を直接捕まえて確認する —— driver() 内部の適用(旧実装)は
    /// makeDriver 経路を素通りするため、この fold が dispatch 入口(call())に無いと
    /// 差し替えドライバのテストでは検出できなかった欠陥。
    /// **ft_terminate を使う**(driver(args) を1回しか呼ばないツール — ft_status は
    /// foregroundNote 用に2回呼ぶので、呼び出し数の検証には向かない)
    func testFoldInjectsRememberedPortIntoOmittedCalls() async throws {
        let driver = FakeDriver()
        var seenArgs: [[String: Any]] = []
        let server = MCPServer(write: { _ in }, makeDriver: { args in
            seenArgs.append(args)
            return driver
        }, recordSnapshot: { _, _, _ in })
        server.lastExplicitIOSTarget = (port: 8123, udid: nil)
        _ = try await server.call(tool: "ft_terminate", args: [:])
        XCTAssertEqual(seenArgs.count, 1)
        XCTAssertEqual(seenArgs.first?["port"] as? Int, 8123,
                       "省略呼び出しへ記憶した port が畳み込まれていない: \(seenArgs)")
    }

    /// 明示 port を渡した呼び出しでは記憶を割り込ませない(素通し)
    func testFoldDoesNotOverrideAnExplicitPort() async throws {
        let driver = FakeDriver()
        var seenArgs: [[String: Any]] = []
        let server = MCPServer(write: { _ in }, makeDriver: { args in
            seenArgs.append(args)
            return driver
        }, recordSnapshot: { _, _, _ in })
        server.lastExplicitIOSTarget = (port: 8123, udid: nil)
        _ = try await server.call(tool: "ft_terminate", args: ["port": 9999])
        XCTAssertEqual(seenArgs.first?["port"] as? Int, 9999)
    }

    /// **(i) 4欠陥修正①**: udid を注入すると driver() の portForIOS が毎回 BridgeDiscovery.scan を
    /// 強いる(busy なブリッジは scan に載らず reconcilePort が誤って throw する)。
    /// fold は port だけを注入し、記憶に udid があっても args へは書かない
    func testFoldInjectsPortOnlyNeverUDID() async throws {
        let driver = FakeDriver()
        var seenArgs: [[String: Any]] = []
        let server = MCPServer(write: { _ in }, makeDriver: { args in
            seenArgs.append(args)
            return driver
        }, recordSnapshot: { _, _, _ in })
        server.lastExplicitIOSTarget = (port: 8123, udid: "AAAA-BBBB")
        _ = try await server.call(tool: "ft_terminate", args: [:])
        XCTAssertEqual(seenArgs.first?["port"] as? Int, 8123)
        XCTAssertNil(seenArgs.first?["udid"], "fold が udid を注入した: \(seenArgs)")
    }

    /// **(ii) 4欠陥修正②**: fold が注入した呼び出し(deviceFromMemoryKey 付き)は driver() の
    /// 記憶記録(recordsIOSMemory/recordsAndroidMemory)から見て「明示ではない」— 自動注入の
    /// 解決結果で記憶が黙って上書きされない。明示呼び出しは従来どおり記録対象のまま
    func testMemoryInjectedCallIsNotTreatedAsExplicitForRecording() {
        let injected: [String: Any] = ["port": 8123, MCPServer.deviceFromMemoryKey: true]
        XCTAssertFalse(MCPServer.recordsIOSMemory(injected),
                       "fold 由来の呼び出しが明示扱いされ、記憶が上書きされ得る")
        let explicit: [String: Any] = ["port": 8123]
        XCTAssertTrue(MCPServer.recordsIOSMemory(explicit))

        let injectedAndroid: [String: Any] = ["serial": "emulator-5554", MCPServer.deviceFromMemoryKey: true]
        XCTAssertFalse(MCPServer.recordsAndroidMemory(injectedAndroid, explicitSerial: "emulator-5554"))
        let explicitAndroid: [String: Any] = ["serial": "emulator-5554"]
        XCTAssertTrue(MCPServer.recordsAndroidMemory(explicitAndroid, explicitSerial: "emulator-5554"))
    }

    /// **(iii) 4欠陥修正③**: serial を明示した呼び出し(platform 省略 = 既定 ios)へ iOS の記憶を
    /// 注入しない —— 宛先が食い違う
    func testFoldDoesNotInjectIOSMemoryWhenSerialIsExplicit() async throws {
        let driver = FakeDriver()
        var seenArgs: [[String: Any]] = []
        let server = MCPServer(write: { _ in }, makeDriver: { args in
            seenArgs.append(args)
            return driver
        }, recordSnapshot: { _, _, _ in })
        server.lastExplicitIOSTarget = (port: 8123, udid: nil)
        _ = try await server.call(tool: "ft_terminate", args: ["serial": "emulator-5554"])
        XCTAssertNil(seenArgs.first?["port"], "serial 明示の呼び出しに iOS の記憶(port)が注入された")
    }

    /// **(iv) 4欠陥修正④**: Android を明示した後、platform も含め全省略の呼び出しは Android の
    /// 記憶(serial + platform)へ行く —— 既定 "ios" に負けない
    func testFoldUsesLastExplicitPlatformWhenEverythingIsOmitted() async throws {
        let driver = FakeDriver()
        var seenArgs: [[String: Any]] = []
        let server = MCPServer(write: { _ in }, makeDriver: { args in
            seenArgs.append(args)
            return driver
        }, recordSnapshot: { _, _, _ in })
        server.lastExplicitAndroidSerial = "emulator-5554"
        server.lastExplicitPlatform = "android"
        _ = try await server.call(tool: "ft_terminate", args: [:])
        XCTAssertEqual(seenArgs.first?["serial"] as? String, "emulator-5554")
        XCTAssertEqual(seenArgs.first?["platform"] as? String, "android")
    }

    /// 明示 platform が与えられていれば、それを尊重してその platform の記憶だけを見る
    /// (直近の明示が Android でも、platform: "ios" を渡せば iOS の記憶だけを見る)
    func testFoldRespectsExplicitPlatformOverLastExplicitPlatform() async throws {
        let driver = FakeDriver()
        var seenArgs: [[String: Any]] = []
        let server = MCPServer(write: { _ in }, makeDriver: { args in
            seenArgs.append(args)
            return driver
        }, recordSnapshot: { _, _, _ in })
        server.lastExplicitAndroidSerial = "emulator-5554"
        server.lastExplicitPlatform = "android"
        server.lastExplicitIOSTarget = (port: 8123, udid: nil)
        _ = try await server.call(tool: "ft_terminate", args: ["platform": "ios"])
        XCTAssertEqual(seenArgs.first?["port"] as? Int, 8123)
        XCTAssertNil(seenArgs.first?["serial"])
    }

    /// **応答チャネルへの注記は同一ターゲットにつき初回だけ**(2回目以降は出さない —— 同じ機を
    /// 使い続けるだけの呼び出し列がノイズまみれにならないように)
    func testFoldNotesReuseOnce() async throws {
        let driver = FakeDriver()
        let server = MCPServer(write: { _ in }, makeDriver: { _ in driver },
                               recordSnapshot: { _, _, _ in })
        server.lastExplicitIOSTarget = (port: 8123, udid: nil)
        let first = try await server.call(tool: "ft_status", args: [:])
        let firstText = first.compactMap { $0["text"] as? String }.joined()
        XCTAssertTrue(firstText.contains("reusing this session's earlier device"), firstText)
        XCTAssertTrue(firstText.contains("8123"), firstText)

        let second = try await server.call(tool: "ft_status", args: [:])
        let secondText = second.compactMap { $0["text"] as? String }.joined()
        XCTAssertFalse(secondText.contains("reusing this session's earlier device"), secondText)
    }

    /// 明示指定された回には注記が付かない
    func testFoldDoesNotNoteOnAnExplicitCall() async throws {
        let driver = FakeDriver()
        let server = MCPServer(write: { _ in }, makeDriver: { _ in driver },
                               recordSnapshot: { _, _, _ in })
        let content = try await server.call(tool: "ft_status", args: ["port": 8123])
        let text = content.compactMap { $0["text"] as? String }.joined()
        XCTAssertFalse(text.contains("reusing"), text)
    }

    /// **device を受けないツールへは適用しない**(ft_dsl_commands は port/serial/udid を持たない)。
    /// device 引数と無関係な応答へ「この機を使い回しています」という誤解を招く注記を付けない
    func testFoldDoesNotApplyToNonDeviceTools() async throws {
        let server = MCPServer(write: { _ in }, makeDriver: { _ in FakeDriver() },
                               recordSnapshot: { _, _, _ in })
        server.lastExplicitIOSTarget = (port: 8123, udid: nil)
        XCTAssertFalse(MCPServer.toolAcceptsDeviceTarget("ft_dsl_commands"))
        let content = try await server.call(tool: "ft_dsl_commands", args: [:])
        let text = content.compactMap { $0["text"] as? String }.joined()
        XCTAssertFalse(text.contains("reusing"), text)
    }

    /// device 系ツールは port または serial プロパティを持つ(toolAcceptsDeviceTarget の判定基盤)。
    /// **(v) 4欠陥修正⑤**: ft_logs は scope: .none で serial だけを個別宣言しており、port 単独
    /// 判定では漏れていた
    func testToolAcceptsDeviceTargetMatchesDeviceScopedTools() {
        XCTAssertTrue(MCPServer.toolAcceptsDeviceTarget("ft_tap"))
        XCTAssertTrue(MCPServer.toolAcceptsDeviceTarget("ft_status"))
        XCTAssertTrue(MCPServer.toolAcceptsDeviceTarget("ft_logs"))
        XCTAssertFalse(MCPServer.toolAcceptsDeviceTarget("ft_list_projects"))
        XCTAssertFalse(MCPServer.toolAcceptsDeviceTarget("ft_dsl_commands"))
    }

    /// **(v) 実際に fold が効く**こと: ft_logs は driver() を呼ばない(adb を直接見る)ので、
    /// call() 経由ではなく foldInRememberedDevice を直接確かめる(実 adb は撃たない)
    func testFoldAppliesToSerialOnlyTools() {
        let server = MCPServer(write: { _ in }, makeDriver: { _ in FakeDriver() },
                               recordSnapshot: { _, _, _ in })
        server.lastExplicitAndroidSerial = "emulator-5554"
        server.lastExplicitPlatform = "android"
        XCTAssertTrue(MCPServer.toolAcceptsDeviceTarget("ft_logs"))
        guard case .applied(let folded, let note) = server.foldInRememberedDevice([:]) else {
            return XCTFail("1台しか触っていないのに記憶が適用されなかった")
        }
        XCTAssertEqual(folded["serial"] as? String, "emulator-5554")
        XCTAssertTrue(note.contains("reusing this session's earlier device"), note)
    }

    // MARK: - ③ forgetConnection が記憶も忘れる

    /// 忘れる接続の port が記憶(lastExplicitIOSTarget)と一致するなら記憶も消える
    func testForgetConnectionClearsMatchingIOSMemory() {
        let server = MCPServer(write: { _ in }, makeDriver: { _ in FakeDriver() },
                               recordSnapshot: { _, _, _ in })
        let key = "direct:ios:8124:"
        server.connectedPorts[key] = 8124
        server.connections[key] = "port 8124"
        server.drivers[key] = FakeDriver()
        server.lastExplicitIOSTarget = (port: 8124, udid: "AAA")

        server.forgetConnection(key)

        XCTAssertNil(server.lastExplicitIOSTarget,
                     "死んだポートへの記憶が残っている — 次の省略呼び出しが同じ死んだポートへ再ダイヤルする")
        XCTAssertNil(server.drivers[key])
        XCTAssertNil(server.connectedPorts[key])
    }

    /// **一致しないときは残す**(片方向だけ見ると「常に消す」変異を素通しする) —— 別のポートの
    /// 接続を忘れても、記憶している別ポートまで巻き添えにしない
    func testForgetConnectionKeepsUnrelatedIOSMemory() {
        let server = MCPServer(write: { _ in }, makeDriver: { _ in FakeDriver() },
                               recordSnapshot: { _, _, _ in })
        let key = "direct:ios:8124:"
        server.connectedPorts[key] = 8124
        server.connections[key] = "port 8124"
        server.lastExplicitIOSTarget = (port: 8130, udid: "BBB")

        server.forgetConnection(key)

        XCTAssertEqual(server.lastExplicitIOSTarget?.port, 8130,
                       "無関係な記憶まで消してしまった")
    }

    /// Android 版(connectedAndroidSerials の記録から照合。connections の表示文字列は見ない)
    func testForgetConnectionClearsMatchingAndroidMemory() {
        let server = MCPServer(write: { _ in }, makeDriver: { _ in FakeDriver() },
                               recordSnapshot: { _, _, _ in })
        let key = "direct:android:0:emulator-5554"
        server.connections[key] = "serial emulator-5554"
        server.connectedAndroidSerials[key] = "emulator-5554"
        server.lastExplicitAndroidSerial = "emulator-5554"

        server.forgetConnection(key)

        XCTAssertNil(server.lastExplicitAndroidSerial)
    }

    func testForgetConnectionKeepsUnrelatedAndroidMemory() {
        let server = MCPServer(write: { _ in }, makeDriver: { _ in FakeDriver() },
                               recordSnapshot: { _, _, _ in })
        let key = "direct:android:0:emulator-5554"
        server.connections[key] = "serial emulator-5554"
        server.connectedAndroidSerials[key] = "emulator-5554"
        server.lastExplicitAndroidSerial = "emulator-5556"

        server.forgetConnection(key)

        XCTAssertEqual(server.lastExplicitAndroidSerial, "emulator-5556")
    }

    /// **profile 経由のラベルでも消せること**(2026-08-14 の実機監査): 表示ラベルは
    /// "<device name> serial <serial>" で `hasPrefix("serial ")` に一致しないが、
    /// `connectedAndroidSerials` から照合するので profile 経由でも記憶が消える
    func testForgetConnectionClearsMatchingAndroidMemoryFromAProfileLabel() {
        let server = MCPServer(write: { _ in }, makeDriver: { _ in FakeDriver() },
                               recordSnapshot: { _, _, _ in })
        let key = "profile::android-device:android"
        server.connections[key] = "Pixel 9(Android 15)-01 serial emulator-5554"
        server.connectedAndroidSerials[key] = "emulator-5554"
        server.lastExplicitAndroidSerial = "emulator-5554"

        server.forgetConnection(key)

        XCTAssertNil(server.lastExplicitAndroidSerial,
                     "profile 経由のラベルでは死んだ serial への記憶が消えない")
    }

    // MARK: - ⑤ ft_navigate back + snapshotAfter: 読み取り失敗を「効かなかった」と誤読しない

    /// **陰性(このバグの再現)**: snapshotAfterBody が読みに失敗した回は、back 前の木が
    /// `lastSnapshots` に残ったまま指紋が自明に一致する。succeeded を見ずに判定すると、
    /// 謝罪文の横に矛盾する「back appears to have had no effect」が並ぶ
    func testBackIneffectiveNoteStaysQuietWhenSnapshotAfterFailedToRead() async throws {
        let driver = FakeDriver()
        let server = MCPServer(write: { _ in }, makeDriver: { _ in driver },
                               recordSnapshot: { _, _, _ in })
        server.settleWaitSeconds = 0
        _ = try await server.call(tool: "ft_snapshot", args: [:])
        driver.failing = ["snapshot"]
        let content = try await server.call(
            tool: "ft_navigate", args: ["target": "back", "snapshotAfter": true])
        let text = try XCTUnwrap(content.first?["text"] as? String)
        XCTAssertTrue(text.contains("could not read the screen"), text)
        XCTAssertFalse(text.contains("back appears to have had no effect"), text)
    }

    /// **陽性(回帰確認)**: 読みに成功し、木が本当に変わっていなければ従来どおり注記が出る
    func testBackIneffectiveNoteStillFiresWhenReadSucceedsAndTreeIsUnchanged() async throws {
        let driver = FakeDriver()
        let server = MCPServer(write: { _ in }, makeDriver: { _ in driver },
                               recordSnapshot: { _, _, _ in })
        server.settleWaitSeconds = 0
        _ = try await server.call(tool: "ft_snapshot", args: [:])
        // FakeDriver は台本が無ければ同じ snapshotResponse を返し続ける = 木は不変
        let content = try await server.call(
            tool: "ft_navigate", args: ["target": "back", "snapshotAfter": true])
        let text = try XCTUnwrap(content.first?["text"] as? String)
        XCTAssertTrue(text.contains("back appears to have had no effect"), text)
    }

    // MARK: - ④ bridgeUnreachableVerdict(busy を「消えた」と誤読しない)

    /// bound かつ ownerAlive が nil(判定材料無し=in-app 等)なら vanished の値によらず busy
    /// (scan にも載らない busy ブリッジを死と誤判定しない)
    func testBridgeUnreachableVerdictBoundMeansBusyRegardlessOfVanished() {
        XCTAssertEqual(
            MCPServer.bridgeUnreachableVerdict(bound: true, ownerAlive: nil, vanished: false), .busy)
        XCTAssertEqual(
            MCPServer.bridgeUnreachableVerdict(bound: true, ownerAlive: nil, vanished: true), .busy)
    }

    /// bound でなく、scan にも載っていなければ vanished
    func testBridgeUnreachableVerdictNotBoundAndVanishedMeansVanished() {
        XCTAssertEqual(
            MCPServer.bridgeUnreachableVerdict(bound: false, ownerAlive: nil, vanished: true), .vanished)
    }

    /// bound でも vanished でもない(判定材料が足りない)ときは stillUnclear —— busy/vanished の
    /// どちらとも断定しない
    func testBridgeUnreachableVerdictNeitherBoundNorVanishedIsUnclear() {
        XCTAssertEqual(
            MCPServer.bridgeUnreachableVerdict(bound: false, ownerAlive: nil, vanished: false),
            .stillUnclear)
    }

    func testBridgeBusyHintDoesNotClaimTheRunnerExited() {
        let hint = MCPServer.bridgeBusyHint(connection: "port 8124", engine: "xcuitest")
        XCTAssertTrue(hint.contains("port 8124"), hint)
        XCTAssertTrue(hint.contains("still bound"), hint)
        XCTAssertFalse(hint.contains("exited"), hint)
    }

    /// engine が nil(判定できない)でも xcuitest 相当の busy 文言のまま(誤誘導しない側の既定)
    func testBridgeBusyHintDefaultsToXCUITestWordingWhenEngineIsUnknown() {
        let hint = MCPServer.bridgeBusyHint(connection: "port 8124", engine: nil)
        XCTAssertTrue(hint.contains("still bound"), hint)
    }

    /// **C: suspend された in-app ブリッジへ「busy・リトライせよ」と言わない**。
    /// in-app/hybrid はエンジンが分かればそちらの文言(前面に戻すか xcuitest ポートを使う)に切り替わる
    func testBridgeBusyHintSwitchesToInAppWordingWhenEngineIsInApp() {
        let hint = MCPServer.bridgeBusyHint(connection: "port 8125", engine: "inapp")
        XCTAssertTrue(hint.contains("port 8125"), hint)
        XCTAssertTrue(hint.contains("foreground"), hint)
        XCTAssertTrue(hint.contains("ft_launch"), hint)
        XCTAssertFalse(hint.contains("still bound"), hint)

        let hybridHint = MCPServer.bridgeBusyHint(connection: "port 8125", engine: "hybrid")
        XCTAssertTrue(hybridHint.contains("foreground"), hybridHint)
    }

    // MARK: - B: Android の記憶(lastExplicitAndroidSerial)の清掃経路

    /// androidConnectionLostHint の識別材料(**走査から切り離した純粋関数**。実 adb は撃たない)。
    /// adb の失敗文言は経路ごとに違うので、狭く確実なのは文字列ではなく `adb devices` への
    /// 再照会そのもの —— この関数はその「一覧に居るか」だけを見る
    func testAndroidSerialVanishedIsTrueWhenNotInConnectedList() {
        XCTAssertTrue(MCPServer.androidSerialVanished("emulator-5554", connected: []))
        XCTAssertTrue(MCPServer.androidSerialVanished("emulator-5554", connected: ["emulator-5556"]))
    }

    func testAndroidSerialVanishedIsFalseWhenStillInConnectedList() {
        XCTAssertFalse(MCPServer.androidSerialVanished(
            "emulator-5554", connected: ["emulator-5554", "emulator-5556"]))
    }

    /// makeDriver 差し替え時は connectionLostHint 全体が走査しない(実ポート/実 adb を叩かない)。
    /// テスト環境で誤って adb を撃たないことの契約そのものを固定する
    func testAndroidConnectionLostHintIsNoOpWhenMakeDriverIsInjected() async {
        let server = MCPServer(write: { _ in }, makeDriver: { _ in FakeDriver() },
                               recordSnapshot: { _, _, _ in })
        server.connections["direct:android:0:emulator-5554"] = "serial emulator-5554"
        let hint = await server.connectionLostHint(
            DriverError.badResponse(status: 500, body: "boom"),
            args: ["platform": "android", "serial": "emulator-5554"])
        XCTAssertEqual(hint, "")
    }

    // MARK: - ⑥ ft_type replace の2欠陥

    private static func textFieldScreen(value: String, focused: Bool = true) -> SnapshotResponse {
        SnapshotResponse(sessionBundleID: nil,
                         screen: FTRect(x: 0, y: 0, width: 400, height: 800),
                         elements: [ElementInfo(ref: 1, type: "TextField", identifier: "name_field",
                                                label: "Name", value: value, placeholder: nil,
                                                enabled: true,
                                                frame: FTRect(x: 0, y: 0, width: 200, height: 40),
                                                depth: 1, focused: focused)],
                         truncatedCount: 0)
    }

    /// **(a)** 空テキスト + replace はクリアだけでも clearInput を呼ぶ(スキーマの
    /// "Clear the field before typing" の約束どおり)。type は呼ばない(空文字を打っては壊れる)。
    /// **(2026-08-12 改)**: 断言ではなく読み返して検証するので、読み返しが実際に空であることを
    /// 台本で用意する(D-3 の陽性テストは別に用意した residual/masked のケースで見る)
    func testReplaceWithEmptyTextStillClears() async throws {
        let driver = FakeDriver()
        driver.snapshotResponse = Self.textFieldScreen(value: "", focused: true)
        let server = MCPServer(write: { _ in }, makeDriver: { _ in driver },
                               recordSnapshot: { _, _, _ in })
        let content = try await server.call(tool: "ft_type", args: ["replace": true, "text": ""])
        XCTAssertTrue(driver.calls.contains(where: { $0.hasPrefix("clearInput(") }),
                     "clearInput が呼ばれていない: \(driver.calls)")
        XCTAssertFalse(driver.calls.contains(where: { $0.hasPrefix("type(") }),
                      "空文字で type が呼ばれた: \(driver.calls)")
        let text = try XCTUnwrap(content.first?["text"] as? String)
        XCTAssertTrue(text.contains("cleared the field"), text)
    }

    /// pressEnter だけの replace(text 省略)もクリアする
    func testReplaceWithPressEnterOnlyStillClears() async throws {
        let driver = FakeDriver()
        let server = MCPServer(write: { _ in }, makeDriver: { _ in driver },
                               recordSnapshot: { _, _, _ in })
        _ = try await server.call(tool: "ft_type", args: ["replace": true, "pressEnter": true])
        XCTAssertTrue(driver.calls.contains(where: { $0.hasPrefix("clearInput(") }),
                     "clearInput が呼ばれていない: \(driver.calls)")
        XCTAssertTrue(driver.calls.contains("pressEnter"), "\(driver.calls)")
    }

    /// **(b) 陽性**: 読み返しで旧値が残っている(clear が効かず連結された)ことを検出し、
    /// 無条件の "(replaced …)" ではなく警告になる
    func testReplaceVerificationWarnsWhenOldContentSurvives() async throws {
        let driver = FakeDriver()
        driver.snapshotResponse = Self.textFieldScreen(value: "old")
        let server = MCPServer(write: { _ in }, makeDriver: { _ in driver },
                               recordSnapshot: { _, _, _ in })
        _ = try await server.call(tool: "ft_snapshot", args: [:])
        // ft_type 内の2回の撮り直しを台本で分ける: verifiedRef の撮り直し(clear/type 前 —
        // まだ "old" のまま)→ 読み返し(clear/type 後・clear が効かず連結された想定)
        driver.scriptedSnapshots = [
            Self.textFieldScreen(value: "old"),
            Self.textFieldScreen(value: "oldnew"),
        ]
        let content = try await server.call(
            tool: "ft_type", args: ["ref": 1, "replace": true, "text": "new"])
        let text = try XCTUnwrap(content.first?["text"] as? String)
        XCTAssertTrue(text.contains("warning"), text)
        XCTAssertTrue(text.contains("oldnew"), text)
        XCTAssertFalse(text.contains("(replaced the field's prior content)"), text)
    }

    /// **(b) 陰性**: 期待どおりに置き換わっていれば通常どおり "(replaced …)"
    func testReplaceVerificationConfirmsWhenValueMatches() async throws {
        let driver = FakeDriver()
        driver.snapshotResponse = Self.textFieldScreen(value: "old")
        let server = MCPServer(write: { _ in }, makeDriver: { _ in driver },
                               recordSnapshot: { _, _, _ in })
        _ = try await server.call(tool: "ft_snapshot", args: [:])
        driver.scriptedSnapshots = [
            Self.textFieldScreen(value: "old"),
            Self.textFieldScreen(value: "new"),
        ]
        let content = try await server.call(
            tool: "ft_type", args: ["ref": 1, "replace": true, "text": "new"])
        let text = try XCTUnwrap(content.first?["text"] as? String)
        XCTAssertTrue(text.contains("(replaced the field's prior content)"), text)
        XCTAssertFalse(text.contains("warning"), text)
    }

    /// 読み返しに失敗したら断定しない(could not be read back)
    func testReplaceVerificationNoteStaysNeutralWhenUnreadable() {
        let note = MCPServer.replaceVerificationNote(target: nil, expected: "new", fresh: nil)
        XCTAssertTrue(note.contains("could not be read back") || note.contains("nothing has input focus"), note)
        XCTAssertFalse(note.contains("replaced"), note)
    }

    /// 純粋関数の直接テスト: 期待どおり一致
    func testReplaceVerificationNoteMatchesExactly() {
        let field = ElementInfo(ref: 1, type: "TextField", identifier: "name_field", label: "Name",
                                value: "new", placeholder: nil, enabled: true,
                                frame: FTRect(x: 0, y: 0, width: 200, height: 40), depth: 1)
        let fresh = SnapshotResponse(sessionBundleID: nil,
                                     screen: FTRect(x: 0, y: 0, width: 400, height: 800),
                                     elements: [field], truncatedCount: 0)
        let note = MCPServer.replaceVerificationNote(target: field, expected: "new", fresh: fresh)
        XCTAssertEqual(note, " (replaced the field's prior content)")
    }

    /// 純粋関数の直接テスト: サフィックス一致(旧値が残ったまま連結された)は警告
    func testReplaceVerificationNoteWarnsOnSuffixMatch() {
        let field = ElementInfo(ref: 1, type: "TextField", identifier: "name_field", label: "Name",
                                value: "old", placeholder: nil, enabled: true,
                                frame: FTRect(x: 0, y: 0, width: 200, height: 40), depth: 1)
        let fresh = SnapshotResponse(sessionBundleID: nil,
                                     screen: FTRect(x: 0, y: 0, width: 400, height: 800),
                                     elements: [ElementInfo(ref: 1, type: "TextField",
                                                            identifier: "name_field", label: "Name",
                                                            value: "oldnew", placeholder: nil,
                                                            enabled: true,
                                                            frame: FTRect(x: 0, y: 0, width: 200, height: 40),
                                                            depth: 1)],
                                     truncatedCount: 0)
        let note = MCPServer.replaceVerificationNote(target: field, expected: "new", fresh: fresh)
        XCTAssertTrue(note.contains("warning"), note)
        XCTAssertTrue(note.contains("does not look cleared"), note)
    }

    // MARK: - D: ft_type replace の4欠陥

    /// **(1) マスク欄は偽警告にしない**: パスワード欄の読み返しは伏せ字(•/●/*)で、
    /// 期待値と一致しなくても「違う」ではなく「確かめようがない」の中立注記になる
    func testReplaceVerificationNoteStaysNeutralOnMaskedReadback() {
        let field = ElementInfo(ref: 1, type: "SecureTextField", identifier: "password_field",
                                label: "Password", value: "old", placeholder: nil, enabled: true,
                                frame: FTRect(x: 0, y: 0, width: 200, height: 40), depth: 1)
        let fresh = SnapshotResponse(sessionBundleID: nil,
                                     screen: FTRect(x: 0, y: 0, width: 400, height: 800),
                                     elements: [ElementInfo(ref: 1, type: "SecureTextField",
                                                            identifier: "password_field",
                                                            label: "Password", value: "••••••",
                                                            placeholder: nil, enabled: true,
                                                            frame: FTRect(x: 0, y: 0, width: 200, height: 40),
                                                            depth: 1)],
                                     truncatedCount: 0)
        let note = MCPServer.replaceVerificationNote(target: field, expected: "new", fresh: fresh)
        XCTAssertTrue(note.contains("reads back masked"), note)
        XCTAssertFalse(note.contains("warning"), note)
    }

    /// **(2) 正規化してから比較する**: ゼロ幅文字だけが違う値は「一致」として扱う
    /// (FlowMatchMode.normalizeInvisibleCharacters を両辺にかける)
    func testReplaceVerificationNoteNormalizesInvisibleCharactersBeforeComparing() {
        let field = ElementInfo(ref: 1, type: "TextField", identifier: "name_field", label: "Name",
                                value: "old", placeholder: nil, enabled: true,
                                frame: FTRect(x: 0, y: 0, width: 200, height: 40), depth: 1)
        let fresh = SnapshotResponse(sessionBundleID: nil,
                                     screen: FTRect(x: 0, y: 0, width: 400, height: 800),
                                     elements: [ElementInfo(ref: 1, type: "TextField",
                                                            identifier: "name_field", label: "Name",
                                                            value: "\u{200B}new", placeholder: nil,
                                                            enabled: true,
                                                            frame: FTRect(x: 0, y: 0, width: 200, height: 40),
                                                            depth: 1)],
                                     truncatedCount: 0)
        let note = MCPServer.replaceVerificationNote(target: field, expected: "new", fresh: fresh)
        XCTAssertEqual(note, " (replaced the field's prior content)", note)
    }

    /// **(3) clear-only(expected 空)の陽性**: 残存していれば「(cleared the field)」と断言せず警告
    func testReplaceVerificationNoteWarnsWhenClearLeavesResidualValue() {
        let field = ElementInfo(ref: 1, type: "TextField", identifier: "name_field", label: "Name",
                                value: "old", placeholder: nil, enabled: true,
                                frame: FTRect(x: 0, y: 0, width: 200, height: 40), depth: 1)
        let fresh = SnapshotResponse(sessionBundleID: nil,
                                     screen: FTRect(x: 0, y: 0, width: 400, height: 800),
                                     elements: [field], truncatedCount: 0)
        let note = MCPServer.replaceVerificationNote(target: field, expected: "", fresh: fresh)
        XCTAssertTrue(note.contains("warning"), note)
        XCTAssertTrue(note.contains("old"), note)
    }

    /// **(3) clear-only の陰性**: 本当に空になっていれば "(cleared the field)"
    func testReplaceVerificationNoteConfirmsClearWhenReadsBackEmpty() {
        let field = ElementInfo(ref: 1, type: "TextField", identifier: "name_field", label: "Name",
                                value: "old", placeholder: nil, enabled: true,
                                frame: FTRect(x: 0, y: 0, width: 200, height: 40), depth: 1)
        let fresh = SnapshotResponse(sessionBundleID: nil,
                                     screen: FTRect(x: 0, y: 0, width: 400, height: 800),
                                     elements: [ElementInfo(ref: 1, type: "TextField",
                                                            identifier: "name_field", label: "Name",
                                                            value: "", placeholder: nil, enabled: true,
                                                            frame: FTRect(x: 0, y: 0, width: 200, height: 40),
                                                            depth: 1)],
                                     truncatedCount: 0)
        let note = MCPServer.replaceVerificationNote(target: field, expected: "", fresh: fresh)
        XCTAssertEqual(note, " (cleared the field)")
    }

    /// clear-only ({replace:true, text:""}) を通しで呼ぶと、実際に read-back で検証されること
    /// (無条件の "(cleared the field)" ではなく、読み返した値に応じて分岐する)
    func testReplaceWithEmptyTextIsVerifiedNotAssumed() async throws {
        let driver = FakeDriver()
        driver.snapshotResponse = Self.textFieldScreen(value: "residual", focused: true)
        let server = MCPServer(write: { _ in }, makeDriver: { _ in driver },
                               recordSnapshot: { _, _, _ in })
        let content = try await server.call(tool: "ft_type", args: ["replace": true, "text": ""])
        let text = try XCTUnwrap(content.first?["text"] as? String)
        XCTAssertTrue(text.contains("warning"), text)
        XCTAssertTrue(text.contains("residual"), text)
        XCTAssertFalse(text.contains("(cleared the field)"), text)
    }

    /// **(4) replace + snapshotAfter(Enter なし)は木を2回読まない**: verifiedRef の撮り直し
    /// + 検証/snapshotAfter 共有の1回だけ(3回目が無い)。FakeDriver の calls で固定する
    func testReplaceVerificationDoesNotDoubleReadWhenSnapshotAfterIsUsed() async throws {
        let driver = FakeDriver()
        driver.snapshotResponse = Self.textFieldScreen(value: "old")
        let server = MCPServer(write: { _ in }, makeDriver: { _ in driver },
                               recordSnapshot: { _, _, _ in })
        server.settleWaitSeconds = 0
        _ = try await server.call(tool: "ft_snapshot", args: [:])
        driver.scriptedSnapshots = [
            Self.textFieldScreen(value: "old"),   // verifiedRef の撮り直し
            Self.textFieldScreen(value: "new"),   // 検証と snapshotAfter で共有する1回
        ]
        let callsBefore = driver.calls.count
        let content = try await server.call(
            tool: "ft_type", args: ["ref": 1, "replace": true, "text": "new", "snapshotAfter": true])
        let text = try XCTUnwrap(content.first?["text"] as? String)
        XCTAssertTrue(text.contains("(replaced the field's prior content)"), text)
        let snapshotCallsDuringFtType = driver.calls[callsBefore...].filter { $0.hasPrefix("snapshot") }
        XCTAssertEqual(snapshotCallsDuringFtType.count, 2,
                       "3回目の読みが発生している: \(driver.calls[callsBefore...])")
    }

    /// **(4) の対照**: pressEnter を伴う replace は最適化の対象外 —— Enter の前後で状態が
    /// 変わるので、検証(Enter 前)と最終の snapshotAfter(Enter 後)は別の読みのままでよい
    func testReplaceWithPressEnterStillReadsAfterEnter() async throws {
        let driver = FakeDriver()
        driver.snapshotResponse = Self.textFieldScreen(value: "old")
        let server = MCPServer(write: { _ in }, makeDriver: { _ in driver },
                               recordSnapshot: { _, _, _ in })
        server.settleWaitSeconds = 0
        _ = try await server.call(tool: "ft_snapshot", args: [:])
        driver.scriptedSnapshots = [
            Self.textFieldScreen(value: "old"),   // verifiedRef の撮り直し
            Self.textFieldScreen(value: "new"),   // replace 検証(Enter 前)
            Self.textFieldScreen(value: "new"),   // snapshotAfter(Enter 後)
        ]
        let callsBefore = driver.calls.count
        let content = try await server.call(
            tool: "ft_type",
            args: ["ref": 1, "replace": true, "text": "new", "pressEnter": true, "snapshotAfter": true])
        let text = try XCTUnwrap(content.first?["text"] as? String)
        XCTAssertTrue(text.contains("(replaced the field's prior content)"), text)
        let snapshotCallsDuringFtType = driver.calls[callsBefore...].filter { $0.hasPrefix("snapshot") }
        XCTAssertEqual(snapshotCallsDuringFtType.count, 3, "\(driver.calls[callsBefore...])")
    }
}
