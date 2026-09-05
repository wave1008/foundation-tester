// 詰まったときに MCP が返す「次の一手」。
//
// 2026-08-06 の外部フィードバックは、機能ではなく**案内の欠落**で詰まっていた:
// ホーム画面は springboard 参照セッションで読めるのに 409 の本文からは辿れず(#6)、
// ブリッジ再起動でセッションが消えたことは "session: none" からは読み取れない(#8)。
// 文言が痩せると同じ迷子が再発するので、要点の語だけ固定する。

import XCTest
import FTAndroid
import FTBridgeClient
import FTCore
@testable import fleetest_mcp

final class MCPGuidanceTests: XCTestCase {

    // MARK: - ホーム画面(#6)

    /// セッション不在の 409 は「まだ launch していない」で出る。ホーム画面を見たい場合の
    /// 読み方(springboard)まで返す
    func testSessionMissingSuggestsSpringboard() {
        let hint = MCPServer.springboardHint(
            DriverError.badResponse(status: 409, body: "no session"), engine: "xcuitest")
        XCTAssertTrue(hint.contains("com.apple.springboard"), hint)
    }

    /// home 後の背面アプリ照会(kAXErrorServerNotFound)も同じ行き止まり
    func testAccessibilityServerNotFoundSuggestsSpringboard() {
        let hint = MCPServer.springboardHint(
            DriverError.badResponse(status: 500, body: "Error kAXErrorServerNotFound"),
            engine: "xcuitest")
        XCTAssertTrue(hint.contains("com.apple.springboard"), hint)
    }

    /// **in-app/hybrid には出さない**: in-app ブリッジは注入先アプリ専用で springboard を掴めず、
    /// 案内どおりにやると 409 が増えるだけになる
    func testInAppEngineGetsNoSpringboardHint() {
        for engine in ["inapp", "hybrid", "android"] {
            XCTAssertEqual(MCPServer.springboardHint(
                DriverError.badResponse(status: 409, body: "no session"), engine: engine), "",
                "engine=\(engine) に springboard を案内してはいけない")
        }
    }

    // MARK: - ft_batch の案内

    /// **1セッションに1回だけ渡る instructions で ft_batch に触れること**。
    /// 評価者の申し立ては「個別ツールが並んでいるので順に呼ぶのが自然に見え、ft_batch を使う
    /// 動機が生まれなかった」。実際 ft_batch は**自分のツール説明にしか出ていなかった**。
    ///
    /// **境界も一緒に固定する** —— 「常に batch」ではない: 2手目以降は ref を受けず、
    /// アサーションと lifecycle は拒否し、最初の失敗で止まる。探索は個別ツールが正しい
    func testInstructionsPointAtBatchWithItsBoundary() {
        let text = MCPServer.serverInstructions
        XCTAssertTrue(text.contains("ft_batch"), "instructions が ft_batch に触れていない")
        XCTAssertTrue(text.contains("one call and one approval"), text)
        XCTAssertTrue(text.contains("not the tool for finding your way"),
                      "「常に batch」と読めてはいけない(探索は個別ツール): \(text)")
    }

    /// **案内は1箇所だけ**(2026-08-10 のスキーマ痩身)。個別ツールの説明へ同じ文言を複製すると、
    /// 全ツールぶん毎セッションのコンテキスト費用になる —— 複製を求められたことがあるが、
    /// 同じ効果は instructions 1箇所で得られる
    func testBatchGuidanceIsNotDuplicatedIntoEveryToolDescription() {
        let mentions = MCPServer.toolDefinitions.filter { def in
            guard let name = def["name"] as? String, name != "ft_batch",
                  let description = def["description"] as? String else { return false }
            return description.contains("ft_batch")
        }.compactMap { $0["name"] as? String }
        XCTAssertEqual(mentions, [],
                       "ft_batch の案内が個別ツールの説明へ複製されている: \(mentions)。"
                       + "ニュアンスは serverInstructions に1本化する(スキーマ痩身)")
    }

    // MARK: - システムダイアログ

    /// 「操作しても木が変わらない」ときに、**SpringBoard のダイアログはこの木に出ない**ことと
    /// 読む口を出す。評価者はここで詰まり、座標でダイアログを叩いていた
    func testUnchangedTreeMentionsTheSystemDialogEscapeHatch() {
        for engine in [nil, "xcuitest"] {
            let hint = MCPServer.systemDialogHint(engine: engine)
            XCTAssertTrue(hint.contains("com.apple.springboard"), "engine=\(engine ?? "nil"): \(hint)")
            XCTAssertTrue(hint.contains("SpringBoard"), hint)
        }
    }

    /// **springboardHint と同じゲート**: in-app は注入先アプリしか見えないので springboard を
    /// 掴めず、Android は木のセッションごと移るので switchedAppNote が捕まえる
    func testSystemDialogHintIsIOSXCUITestOnly() {
        for engine in ["inapp", "hybrid", "android"] {
            XCTAssertEqual(MCPServer.systemDialogHint(engine: engine), "",
                           "engine=\(engine) にシステムダイアログの案内を出してはいけない")
        }
    }

    /// 関係ない失敗(404・ネットワーク)に足さない = 誤誘導しない
    func testUnrelatedFailuresGetNoHint() {
        XCTAssertEqual(MCPServer.springboardHint(
            DriverError.badResponse(status: 404, body: "unknown ref"), engine: "xcuitest"), "")
        XCTAssertEqual(MCPServer.springboardHint(
            DriverError.bridgeUnreachable("refused"), engine: "xcuitest"), "")
        XCTAssertEqual(MCPServer.springboardHint(
            DriverError.badResponse(status: 500, body: "something else"), engine: "xcuitest"), "")
    }

    /// home した直後に「この後 snapshot は読めない」と先に言う(踏んでから調べさせない)
    func testNavigateHomeAnnouncesTheReadPath() {
        let note = MCPServer.backgroundingNavigationNote(target: "home", engine: "xcuitest")
        XCTAssertTrue(note.contains("com.apple.springboard"), note)
        XCTAssertEqual(MCPServer.backgroundingNavigationNote(target: "back", engine: "xcuitest"), "")
        XCTAssertEqual(MCPServer.backgroundingNavigationNote(target: "home", engine: "inapp"), "")
    }

    /// **appSwitcher の後は木が前のアプリのままなのに、これまで注記がゼロだった**(実機 iPhone 13
    /// の探索で発見)。home と同じ穴なので同じ関数で塞ぐ —— セッションはアプリを指したままで、
    /// ft_snapshot も ft_tap もそのアプリの木で応答してしまう
    func testNavigateAppSwitcherAnnouncesTheStaleTree() {
        let note = MCPServer.backgroundingNavigationNote(target: "appSwitcher", engine: "xcuitest")
        XCTAssertTrue(note.contains("ft_screenshot"), note)
        XCTAssertTrue(note.contains("ft_launch"), note)
        XCTAssertEqual(MCPServer.backgroundingNavigationNote(target: "appSwitcher", engine: "inapp"), "",
                       "in-app は注入先アプリしか見えず、この注記は xcuitest/engine 不明限定")
        XCTAssertEqual(MCPServer.backgroundingNavigationNote(target: "back", engine: "xcuitest"), "")
    }

    // MARK: - 未インストール(#3)

    func testNotInstalledMessageNamesTheFix() {
        let message = MCPServer.notInstalledMessage(bundleID: "com.example.myapp")
        XCTAssertTrue(message.contains("com.example.myapp"), message)
        XCTAssertTrue(message.contains("ft_install"), message)
    }

    // MARK: - 接続が消えた(#7)

    /// 「Could not connect」だけでは何が起きたか分からない。**今どこに何が居るか**と
    /// 復帰手順まで返す(ランナー死の筆頭原因は同一シミュレータの2本目)
    func testConnectionLostNamesTheCauseAndTheSurvivors() {
        let message = MCPServer.connectionLostMessage(
            connection: "port 8124",
            running: [BridgeDiscovery.Found(port: 8130, device: "iPhone 17 Pro", engine: "xcuitest")])
        XCTAssertTrue(message.contains("port 8124"), message)
        XCTAssertTrue(message.contains("8130"), message)
        XCTAssertTrue(message.contains("bridge up"), message)
        XCTAssertTrue(message.contains("ft_launch"), message)
    }

    func testConnectionLostWithNothingRunning() {
        let message = MCPServer.connectionLostMessage(connection: "port 8123", running: [])
        XCTAssertTrue(message.contains("no iOS bridge is running now"), message)
    }

    // MARK: - セッション消失(#8)

    /// ブリッジを立て直すとセッションは引き継がれない。"none" だけだと気付けない
    func testStatusExplainsAnEmptySession() async throws {
        let driver = FakeDriver()
        driver.statusResponse = StatusResponse(ready: true, device: "iPhone 17", osVersion: "26.0",
                                               sessionBundleID: nil)
        let server = MCPServer(write: { _ in }, makeDriver: { _ in driver },
                               recordSnapshot: { _, _, _ in })
        let content = try await server.call(tool: "ft_status", args: [:])
        let text = try XCTUnwrap(content.first?["text"] as? String)
        XCTAssertTrue(text.contains("ft_launch"), text)
        XCTAssertTrue(text.contains("bridge restart"), text)
    }

    // MARK: - 前面判定(backgroundedSessionNote)

    /// **通知シェード / クイック設定に「前面に居ない」と言わない**(2026-08-28・実機 Pixel 4a)。
    /// Android の foregroundAppID() は topmost *app* package を返すので、アクティビティを
    /// 持たないシステム UI の窓が前面のときは `com.android.systemui` が決して一致せず、
    /// **木がまさにその面のものでも必ず**「木は古い・ft_launch で戻せ」と言っていた
    func testSystemUiTreeIsNotCalledBackgrounded() async throws {
        let driver = FakeDriver()
        driver.snapshotResponse = SnapshotResponse(
            sessionBundleID: "com.android.systemui",
            screen: FTRect(x: 0, y: 0, width: 1080, height: 2340),
            elements: [], truncatedCount: 0)
        // 実機と同じ形: 前面の「アプリ」は背後のアプリのまま
        driver.foregroundBundleID = "com.ftester.e2e.android"
        let server = MCPServer(write: { _ in }, makeDriver: { _ in driver },
                               recordSnapshot: { _, _, _ in })
        let content = try await server.call(tool: "ft_snapshot", args: [:])
        let text = try XCTUnwrap(content.first?["text"] as? String)
        XCTAssertFalse(text.contains("NOT in the foreground"), text)
    }

    /// **陰性対照ではなく陽性対照**: 本当に背面へ回ったアプリには従来どおり言うこと
    /// (上の絞り込みが検知そのものを消していないか)
    func testAGenuinelyBackgroundedAppIsStillCalledOut() async throws {
        let driver = FakeDriver()
        driver.snapshotResponse = SnapshotResponse(
            sessionBundleID: "com.ftester.e2e.android",
            screen: FTRect(x: 0, y: 0, width: 1080, height: 2340),
            elements: [], truncatedCount: 0)
        driver.foregroundBundleID = "com.example.other"
        let server = MCPServer(write: { _ in }, makeDriver: { _ in driver },
                               recordSnapshot: { _, _, _ in })
        let content = try await server.call(tool: "ft_snapshot", args: [:])
        let text = try XCTUnwrap(content.first?["text"] as? String)
        XCTAssertTrue(text.contains("NOT in the foreground"), text)
    }

    // MARK: - アプリのすり替わり(2026-08-06 の探索で決定的に再現)

    /// **Android のブリッジは session を前面ウィンドウから採る**ので、back でアプリを出ると
    /// session ごと別アプリに移り、`backgroundedSessionNote` は永遠に沈黙する。
    /// E2E の 4 SUT は id・ラベルが共通契約なので、木を見ても入れ替わりに気付けない
    func testSnapshotNamesTheAppSwitchWhenTheTreeIsNotTheLaunchedApp() async throws {
        let driver = FakeDriver()
        driver.snapshotResponse = SnapshotResponse(
            sessionBundleID: "com.ftester.e2e.flutter",
            screen: FTRect(x: 0, y: 0, width: 1080, height: 2424),
            elements: [], truncatedCount: 0)
        let server = MCPServer(write: { _ in }, makeDriver: { _ in driver },
                               recordSnapshot: { _, _, _ in })
        _ = try await server.call(tool: "ft_launch", args: ["bundleId": "com.ftester.e2e.android"])
        let content = try await server.call(tool: "ft_snapshot", args: [:])
        let text = try XCTUnwrap(content.first?["text"] as? String)
        XCTAssertTrue(text.contains("com.ftester.e2e.flutter"), text)
        XCTAssertTrue(text.contains("com.ftester.e2e.android"), text)
        XCTAssertTrue(text.contains("ft_launch"), text)
    }

    /// **木を返す口はすべて名指しする**。`ft_scroll_to` の「対象が居るか」の再確認は
    /// セレクタしか見ないので、**別アプリに同じ id がある**と素通しする —— 4 SUT は
    /// id・ラベルが共通契約なので、これは現に起こり得る形(2026-08-06 の掃討で見つけた漏れ)
    func testScrollToAlsoNamesTheAppSwitch() async throws {
        let driver = FakeDriver()
        let tree = SnapshotResponse(
            sessionBundleID: "com.ftester.e2e.flutter",
            screen: FTRect(x: 0, y: 0, width: 390, height: 844),
            elements: [ElementInfo(ref: 1, type: "Button", identifier: "row_40", label: "行 40",
                                   value: nil, placeholder: nil, enabled: true,
                                   frame: FTRect(x: 16, y: 100, width: 100, height: 40), depth: 1)],
            truncatedCount: 0)
        driver.snapshotResponse = tree
        let server = MCPServer(write: { _ in }, makeDriver: { _ in driver },
                               recordSnapshot: { _, _, _ in })
        _ = try await server.call(tool: "ft_launch", args: ["bundleId": "com.ftester.e2e.android"])
        let content = try await server.call(tool: "ft_scroll_to", args: ["selector": "#row_40"])
        let text = try XCTUnwrap(content.first?["text"] as? String)
        XCTAssertTrue(text.contains("NOT the app you launched"), text)
    }

    /// **欠陥⑧**: 別パッケージがシステムダイアログのときは「操作してから続行」であって
    /// 「ft_launch し直す」ではない。実測: 位置情報の許可ダイアログ(permissioncontroller)で
    /// 通常の案内(ft_launch し直す)に従うと、ダイアログを放置したままアプリを再起動してループした
    func testSwitchedAppNoteGuidesToOperateSystemDialogs() {
        let snapshot = SnapshotResponse(sessionBundleID: "com.google.android.permissioncontroller",
                                        screen: FTRect(x: 0, y: 0, width: 1080, height: 2424),
                                        elements: [], truncatedCount: 0)
        let note = MCPServer.switchedAppNote(launched: "com.example.app", snapshot: snapshot)
        XCTAssertTrue(note.contains("system dialog"), note)
        XCTAssertTrue(note.contains("Operate the dialog"), note)
        XCTAssertFalse(note.contains("Leaving the app"), "通常文言に落ちないこと: \(note)")
    }

    /// springboard は `ft_launch bundleId: com.apple.springboard` が正規の attach 先(ツール説明に
    /// 明記)なので、その用途を否定しない文言にする
    func testSwitchedAppNoteDoesNotDenySpringboardAsAValidDestination() {
        let snapshot = SnapshotResponse(sessionBundleID: "com.apple.springboard",
                                        screen: FTRect(x: 0, y: 0, width: 390, height: 844),
                                        elements: [], truncatedCount: 0)
        let note = MCPServer.switchedAppNote(launched: "com.example.app", snapshot: snapshot)
        XCTAssertTrue(note.contains("supported"), note)
        XCTAssertTrue(note.contains("com.apple.springboard"), note)
    }

    /// 一致していれば黙る(注記は毎回の木の先頭に出るので、無駄に出すと本文を押し出す)
    func testSnapshotStaysQuietWhenTheTreeIsTheLaunchedApp() {
        let snapshot = SnapshotResponse(sessionBundleID: "com.example.app",
                                        screen: FTRect(x: 0, y: 0, width: 390, height: 844),
                                        elements: [], truncatedCount: 0)
        XCTAssertEqual(
            MCPServer.switchedAppNote(launched: "com.example.app", snapshot: snapshot), "")
        // ft_launch していない / 木が名乗らないときは**判定材料が無い** = 嘘を足さない
        XCTAssertEqual(MCPServer.switchedAppNote(launched: nil, snapshot: snapshot), "")
        XCTAssertEqual(MCPServer.switchedAppNote(
            launched: "com.example.app",
            snapshot: SnapshotResponse(sessionBundleID: nil,
                                       screen: FTRect(x: 0, y: 0, width: 390, height: 844),
                                       elements: [], truncatedCount: 0)), "")
    }

    /// **実測(2026-09-05・実機 Pixel 4a)**: #btn_crash_confirm でプロセスを落とすと、通常文言は
    /// launcher へ迷い込んだとしか言わず、実際に落ちたことを伝えられない。processEvidence が
    /// running: false を言っているときは、原因をクラッシュへ差し替える
    func testSwitchedAppNoteReportsCrashWhenProcessIsNotRunning() {
        let snapshot = SnapshotResponse(sessionBundleID: "com.google.android.apps.nexuslauncher",
                                        screen: FTRect(x: 0, y: 0, width: 1080, height: 2424),
                                        elements: [], truncatedCount: 0)
        let evidence = AndroidAppProcessEvidence(
            running: false,
            crashSummary: ["FATAL EXCEPTION: main",
                          "Process: com.ftester.e2e.android, PID: 13561",
                          "java.lang.RuntimeException: FT_E2E intentional crash"])
        let note = MCPServer.switchedAppNote(launched: "com.ftester.e2e.android", snapshot: snapshot,
                                             processEvidence: evidence)
        XCTAssertTrue(note.contains("may have crashed"), note)
        XCTAssertTrue(note.contains("FT_E2E intentional crash"), note)
        XCTAssertTrue(note.contains("ft_logs"), note)
        XCTAssertFalse(note.contains("Leaving the app"), "通常文言に落ちないこと: \(note)")
    }

    /// running: true(またはプロセスが分からない = nil)のときは従来文のまま
    /// (誤ってクラッシュを疑わせない)
    func testSwitchedAppNoteKeepsUsualWordingWhenProcessIsRunning() {
        let snapshot = SnapshotResponse(sessionBundleID: "com.google.android.apps.nexuslauncher",
                                        screen: FTRect(x: 0, y: 0, width: 1080, height: 2424),
                                        elements: [], truncatedCount: 0)
        let evidence = AndroidAppProcessEvidence(running: true, crashSummary: [])
        let note = MCPServer.switchedAppNote(launched: "com.ftester.e2e.android", snapshot: snapshot,
                                             processEvidence: evidence)
        XCTAssertTrue(note.contains("Leaving the app"), note)
        XCTAssertFalse(note.contains("may have crashed"), note)

        let noteWithoutEvidence = MCPServer.switchedAppNote(
            launched: "com.ftester.e2e.android", snapshot: snapshot)
        XCTAssertTrue(noteWithoutEvidence.contains("Leaving the app"), noteWithoutEvidence)
    }

    // MARK: - back は空振りし得る / in-app への切替はアプリを起動し直す

    /// 「画面が変わった」と断言しない。iOS の back は端の swipe なので、自前ナビの画面では
    /// 1px も動かない(E2E-iOS のセレクタ画面で2回とも不変を実測)
    func testBackDoesNotClaimTheScreenChanged() {
        let note = MCPServer.backNoOpNote(target: "back", engine: "xcuitest")
        XCTAssertTrue(note.contains("edge swipe"), note)
        XCTAssertTrue(note.contains("leaves the app"), note)
        // Android には端 swipe の話が無い(無関係な助言は誤誘導になる)
        XCTAssertFalse(MCPServer.backNoOpNote(target: "back", engine: "android").contains("edge swipe"))
        XCTAssertEqual(MCPServer.backNoOpNote(target: "home", engine: "xcuitest"), "")
    }

    // MARK: - 古いブリッジに繋がっている(2026-08-06 に実際に踏んだ)

    /// profile 無しの iOS 経路は**生きているポートへ素で繋ぐだけ**なので、版を上げても
    /// 旧ランナーが使われ続ける。実害: ブリッジ側の修正2件を入れて版も上げたのに、
    /// ft_snapshot は直る前の木を返し、`bridge down && bridge up` まで直っていなく見えた
    func testAStaleBridgeIsCalledOut() async throws {
        let driver = FakeDriver()
        driver.statusResponse = StatusResponse(
            ready: true, device: "iPhone 17", osVersion: "27.0",
            sessionBundleID: "com.example.app",
            protocolVersion: BridgeAPI.bridgeProtocolVersion - 1)
        let skew = await MCPServer.bridgeVersionSkew(driver: driver)
        let text = try XCTUnwrap(skew)
        XCTAssertTrue(text.contains("bridge down"), text)
        XCTAssertTrue(text.contains("v\(BridgeAPI.bridgeProtocolVersion)"), text)
        // **どちらが新しいかを言う**(G-4): 対処が変わる
        XCTAssertTrue(text.contains("OLDER than this build"), text)
    }

    /// ブリッジのほうが新しいときは**ホストを建て直せ**と言う(逆を勧めると直らない)。
    /// 実際に起きた形: 版を上げた作業中にビルドされたランナーが生き残り、
    /// 撤回後のホストより新しい版を名乗っていた
    func testANewerBridgeTellsYouToRebuildTheHost() async throws {
        let driver = FakeDriver()
        driver.statusResponse = StatusResponse(
            ready: true, device: "iPhone 17", osVersion: "27.0",
            sessionBundleID: "com.example.app",
            protocolVersion: BridgeAPI.bridgeProtocolVersion + 1)
        let skew = await MCPServer.bridgeVersionSkew(driver: driver)
        let text = try XCTUnwrap(skew)
        XCTAssertTrue(text.contains("NEWER than this build"), text)
        XCTAssertTrue(text.contains("swift build --product fleetest-mcp"), text)
    }

    /// 版が合っていれば黙る。**返さないブリッジ(nil)も黙る** —— 旧ブリッジは版を返さないので、
    /// nil を「古い」と読むと常時警告になり、本当に古いときの信号が埋もれる
    func testAMatchingOrUnknownBridgeVersionStaysQuiet() async throws {
        let driver = FakeDriver()
        driver.statusResponse = StatusResponse(
            ready: true, device: "iPhone 17", osVersion: "27.0",
            sessionBundleID: "com.example.app",
            protocolVersion: BridgeAPI.bridgeProtocolVersion)
        let matching = await MCPServer.bridgeVersionSkew(driver: driver)
        XCTAssertNil(matching)
        driver.statusResponse = StatusResponse(
            ready: true, device: "iPhone 17", osVersion: "27.0",
            sessionBundleID: "com.example.app", protocolVersion: nil)
        let unknown = await MCPServer.bridgeVersionSkew(driver: driver)
        XCTAssertNil(unknown)
    }

    /// エンジン切替の案内には**アプリが起動し直る**ことまで書く。書かないと、案内に従った
    /// 瞬間に探索中の画面が消え、ホーム画面へ同じ座標のジェスチャが撃たれる
    func testEngineHintWarnsThatSwitchingRelaunchesTheApp() {
        let server = MCPServer(write: { _ in }, makeDriver: { _ in FakeDriver() },
                               recordSnapshot: { _, _, _ in })
        server.engines[MCPServer.engineKey([:])] = "xcuitest"
        let hint = server.iosEngineHint("Compose Multiplatform", "double tap", args: [:])
        XCTAssertTrue(hint.contains("relaunches the app"), hint)
    }
}
