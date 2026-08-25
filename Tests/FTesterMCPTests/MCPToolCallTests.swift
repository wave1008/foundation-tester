// ft_* ツールの dispatch・引数検証・応答整形。
// ここが未検証だと、MCP から見て「引数を無視する」「別のドライバ操作を呼ぶ」「必須引数の欠落を
// 素通しする」といった退行が、スキーマ宣言のテスト(MCPServerToolDefinitionsTests)を緑のまま通る。

import CoreGraphics
import ImageIO
import UniformTypeIdentifiers
import XCTest
import FTCore
@testable import ftester_mcp

final class MCPToolCallTests: XCTestCase {

    private var driver: FakeDriver!
    private var server: MCPServer!
    /// ft_snapshot が台帳へ落とした内容(実ファイルには書かせない。既定の実装は
    /// 実プロジェクトの .ftester/ へ書くため、差し替えないとテストが利用者の資産を汚す)
    private var recorded: [(ids: [String], platform: String)] = []

    override func setUp() {
        super.setUp()
        driver = FakeDriver()
        recorded = []
        let fake = driver!
        server = MCPServer(write: { _ in }, makeDriver: { _ in fake },
                           recordSnapshot: { [weak self] snapshot, platform, _ in
                               self?.recorded.append((SelectorInventory.ids(in: snapshot), platform))
                           })
    }

    // MARK: - ドライバ操作へ正しく橋渡しされるか

    // MARK: - マップ系ジェスチャ(ft_double_tap / ft_pinch / ft_drag)

    /// 非同期呼び出しが throw することの確認(引数検証が素通りしないこと)
    private func assertThrows(_ tool: String, _ args: [String: Any],
                              file: StaticString = #filePath, line: UInt = #line) async {
        do {
            _ = try await server.call(tool: tool, args: args)
            XCTFail("\(tool) は引数不足で throw するはず", file: file, line: line)
        } catch {}
    }

    /// ref は**座標へ畳んでから**ドライバへ渡す(ref はブリッジごとに別名前空間で、
    /// 501 で別ドライバへ回るときに取り直しが要るため)
    func testDoubleTapResolvesRefToCoordinates() async throws {
        _ = try await server.call(tool: "ft_double_tap", args: ["ref": 1])
        XCTAssertEqual(driver.calls, ["snapshot", "doubleTap(x:60.0,y:40.0)"])
    }

    func testDoubleTapAcceptsCoordinates() async throws {
        _ = try await server.call(tool: "ft_double_tap", args: ["x": 10.0, "y": 20.0])
        XCTAssertEqual(driver.calls, ["doubleTap(x:10.0,y:20.0)"])
    }

    func testDoubleTapRequiresRefOrCoordinates() async {
        await assertThrows("ft_double_tap", [:])
        XCTAssertEqual(driver.calls, [])
    }

    /// ref 指定のピンチは **frame と identifier の両方**を渡す(経路で対象の伝え方が違う。
    /// 片方でも落ちると「対象を指定したのに画面中心がピンチされる」黙った取り違えになる)
    func testPinchPassesFrameAndIdentifierForRef() async throws {
        _ = try await server.call(tool: "ft_pinch", args: ["ref": 1, "scale": 3.0])
        XCTAssertEqual(driver.calls,
                       ["snapshot", "pinch(10.0,20.0,100.0x40.0,id:login_btn,scale:3.0)"])
    }

    /// ref 省略は画面全体(frame nil)
    func testPinchWithoutRefTargetsTheWholeScreen() async throws {
        _ = try await server.call(tool: "ft_pinch", args: [:])
        XCTAssertEqual(driver.calls, ["pinch(screen,id:nil,scale:2.0)"])
    }

    /// 向きの無い scale(1 以下 0 以下)は撃たずに弾く
    func testPinchRejectsMeaninglessScale() async {
        await assertThrows("ft_pinch", ["scale": 1.0])
        await assertThrows("ft_pinch", ["scale": 0.0])
        XCTAssertEqual(driver.calls, [])
    }

    /// 斜めドラッグ(両軸が動く)がそのまま渡ること
    func testDragPassesBothAxes() async throws {
        _ = try await server.call(tool: "ft_drag",
                                  args: ["fromX": 100.0, "fromY": 200.0,
                                         "toX": 40.0, "toY": 150.0, "durationSeconds": 0.8])
        XCTAssertEqual(driver.calls, ["drag(100.0,200.0->40.0,150.0,duration:0.8)"])
    }

    /// **無反応だったときの切り分けを応答に載せる**(XCUITest では Compose のダブルタップと
    /// Flutter のピンチが届かない)。Android と分かっているときは付けない —— 無関係な助言は
    /// 誤誘導になる
    func testGestureResultsCarryTheEngineHintOnIOSOnly() async throws {
        let iosDouble = try await server.call(tool: "ft_double_tap", args: ["x": 1.0, "y": 2.0])
        let iosText = try XCTUnwrap(iosDouble.first?["text"] as? String)
        XCTAssertTrue(iosText.contains("XCUITest engine"), iosText)
        XCTAssertTrue(iosText.contains("Compose"), iosText)

        let androidDouble = try await server.call(
            tool: "ft_double_tap", args: ["x": 1.0, "y": 2.0, "platform": "android"])
        let androidText = try XCTUnwrap(androidDouble.first?["text"] as? String)
        XCTAssertFalse(androidText.contains("XCUITest engine"), androidText)

        let pinch = try await server.call(tool: "ft_pinch", args: [:])
        let pinchText = try XCTUnwrap(pinch.first?["text"] as? String)
        XCTAssertTrue(pinchText.contains("Flutter"), pinchText)
    }

    /// **助言は「実際に使ったエンジン」で出し分ける**。in-app/hybrid ではジェスチャが成立するので
    /// 添えない —— 成立しているのに「届かない」と言うと、無関係な原因を探させる
    func testEngineHintDisappearsWhenTheRunIsNotOnXCUITest() async throws {
        for engine in ["hybrid", "inapp"] {
            server.engines[MCPServer.engineKey([:])] = engine
            let result = try await server.call(tool: "ft_double_tap", args: ["x": 1.0, "y": 2.0])
            let resultText = try XCTUnwrap(result.first?["text"] as? String)
            XCTAssertFalse(resultText.contains("XCUITest engine"), "\(engine): \(resultText)")
        }
    }

    /// **in-app 経路の背面化は「次が無応答になりうる」ことまで返す**(in-app ブリッジは
    /// 対象アプリの中に住む)。back は前面のままなので黙る
    func testHomeWarnsAboutTheSuspendedInAppBridge() {
        XCTAssertTrue(MCPServer.backgroundedAppNote(target: "home", engine: "hybrid")
            .contains("XCUITest bridge"))
        XCTAssertTrue(MCPServer.backgroundedAppNote(target: "appSwitcher", engine: "inapp")
            .contains("ft_launch"))
        XCTAssertEqual(MCPServer.backgroundedAppNote(target: "home", engine: "xcuitest"), "",
                       "XCUITest はアプリの外なので関係ない")
        XCTAssertEqual(MCPServer.backgroundedAppNote(target: "back", engine: "hybrid"), "",
                       "back は背面化しない")
    }

    /// **背面のアプリのツリーを「今の画面」として返さない**。XCUITest の snapshot は
    /// セッションのアプリに閉じているので、別のアプリが前面に来ても同じ木を返し続ける
    /// (実機の iPhone で症状に当たり、シミュレータで機構を確定: ステータスバーの
    /// 「元のアプリへ」を踏んだタップで前面が替わったのに気付けなかった)
    func testSnapshotSaysWhenTheAppIsNotInTheForeground() async throws {
        driver.foregroundBundleID = nil   // = 対象アプリは前面に居ない

        let result = try await server.call(tool: "ft_snapshot", args: [:])
        let rendered = try XCTUnwrap(result.first?["text"] as? String)

        XCTAssertTrue(rendered.hasPrefix("com.example.app is NOT in the foreground"), rendered)
        XCTAssertTrue(rendered.contains("login_btn"), "木そのものは返すこと")
    }

    /// 前面に居るときは黙る(毎回付くと注記が読み飛ばされる)
    func testSnapshotIsQuietWhenTheAppIsInTheForeground() async throws {
        driver.foregroundBundleID = "com.example.app"

        let result = try await server.call(tool: "ft_snapshot", args: [:])
        let rendered = try XCTUnwrap(result.first?["text"] as? String)

        XCTAssertTrue(rendered.hasPrefix("screen:"), rendered)
    }

    // MARK: - 待ち(ft_snapshot の waitFor)とデータ消去

    /// **待ちはホスト側で回す**: 出るまで snapshot を撃ち直し、出た画面を1回だけ返す
    /// (エージェントに撃ち直させると、待った回数だけ画面一覧が文脈に積まれる)
    func testSnapshotWaitsUntilTheSelectorAppears() async throws {
        let empty = SnapshotResponse(sessionBundleID: "com.example.app",
                                     screen: FTRect(x: 0, y: 0, width: 390, height: 844),
                                     elements: [], truncatedCount: 0)
        driver.scriptedSnapshots = [empty, empty, driver.snapshotResponse]

        let result = try await server.call(tool: "ft_snapshot",
                                           args: ["waitFor": "#login_btn", "timeout": 5.0])
        let rendered = try XCTUnwrap(result.first?["text"] as? String)

        XCTAssertTrue(rendered.contains("login_btn"), rendered)
        XCTAssertFalse(rendered.contains("did not appear"), rendered)
        XCTAssertEqual(driver.calls.filter { $0 == "snapshot" }.count, 3, "出るまで撮り直すこと")
    }

    /// **出なくてもエラーにしない**: 今の画面は判断材料なので返す。ただし
    /// 「出なかった」と明示する(黙って現状を返すと、出たものと読み違える)
    func testSnapshotReportsWhenTheSelectorNeverAppears() async throws {
        let result = try await server.call(tool: "ft_snapshot",
                                           args: ["waitFor": "#missing", "timeout": 0.5])
        let rendered = try XCTUnwrap(result.first?["text"] as? String)

        XCTAssertTrue(rendered.contains("did not appear"), rendered)
        XCTAssertTrue(rendered.contains("login_btn"), "現在の画面は返すこと: \(rendered)")
    }

    /// 照合は **DSL と同じセレクタエンジン**(ここで書ける式はそのままシナリオへ持ち込める)
    func testWaitForUsesTheDSLSelectorSyntax() {
        let screen = SnapshotResponse(
            sessionBundleID: "com.example.app",
            screen: FTRect(x: 0, y: 0, width: 390, height: 844),
            elements: [
                ElementInfo(ref: 1, type: "Button", identifier: "login_btn", label: "ログイン",
                            value: nil, placeholder: nil, enabled: true,
                            frame: FTRect(x: 10, y: 20, width: 100, height: 40), depth: 1),
            ],
            truncatedCount: 0)

        XCTAssertTrue(MCPServer.matches("#login_btn", in: screen))
        XCTAssertTrue(MCPServer.matches("ログイン", in: screen), "ラベル完全一致")
        XCTAssertTrue(MCPServer.matches("#login_*", in: screen), "# 短縮形のワイルドカード")
        XCTAssertTrue(MCPServer.matches("#nope||#login_btn", in: screen), "|| は和集合")
        XCTAssertFalse(MCPServer.matches("#login", in: screen), "id は完全一致(部分一致は * で明示)")
        XCTAssertFalse(MCPServer.matches("ログ", in: screen), "ラベルも完全一致")
    }

    /// データ消去はアプリを止めるので、**止まったことまで返す**(次に何をすべきかが決まる)
    func testClearAppDataStopsTheAppAndSaysSo() async throws {
        let result = try await server.call(tool: "ft_clear_app_data",
                                           args: ["bundleId": "com.example.app"])
        let message = try XCTUnwrap(result.first?["text"] as? String)

        XCTAssertEqual(driver.calls, ["clearAppData(com.example.app)"])
        XCTAssertTrue(message.contains("ft_launch"), message)
    }

    /// 対象が無ければ撃たない(既定のアプリを勝手に決めない)
    func testClearAppDataRequiresABundleID() async {
        await assertThrows("ft_clear_app_data", [:])
        XCTAssertEqual(driver.calls, [])
    }

    // MARK: - 統合したツール(ft_navigate / ft_clear_input / ft_type の pressEnter)

    /// **3操作を1ツールに束ねている**ので、target がドライバの正しいメソッドへ振り分くこと
    func testNavigateDispatchesToTheRightDriverCall() async throws {
        _ = try await server.call(tool: "ft_navigate", args: ["target": "back"])
        _ = try await server.call(tool: "ft_navigate", args: ["target": "home"])
        _ = try await server.call(tool: "ft_navigate", args: ["target": "appSwitcher"])
        XCTAssertEqual(driver.calls, ["back", "home", "appSwitcher"])
    }

    func testNavigateRejectsAnUnknownTarget() async {
        await assertThrows("ft_navigate", ["target": "sideways"])
        XCTAssertEqual(driver.calls, [])
    }

    /// **覚えている木が無ければチェック自体をしない**(照合の起点が無いのに撃つのは
    /// 余計な往復を増やすだけ)。ft_snapshot を挟んでいない = lastSnapshots が空
    func testBackWithoutAPriorSnapshotSkipsTheIneffectivenessCheck() async throws {
        let content = try await server.call(tool: "ft_navigate", args: ["target": "back"])
        let text = try XCTUnwrap(content.first?["text"] as? String)
        XCTAssertFalse(text.contains("no effect on this screen"), text)
        XCTAssertEqual(driver.calls, ["back"], "覚えている木が無ければ撮り直さないこと")
    }

    /// back を送っても木の指紋が最後まで一致したままなら「効かなかった」を名指しする
    /// (自前ナビの画面はシステムの戻るを無視することがある)
    func testBackWithNoTreeChangeIsNamedAsIneffective() async throws {
        _ = try await server.call(tool: "ft_snapshot", args: [:])
        // 台本を用意しない = 撮り直すたびに同じ木が返り続ける
        let content = try await server.call(tool: "ft_navigate", args: ["target": "back"])
        let text = try XCTUnwrap(content.first?["text"] as? String)
        XCTAssertTrue(text.contains("no effect on this screen"), text)
    }

    /// 途中で木が変われば「効かなかった」とは言わない。**1回だけの撮り直しでは判定しない**
    /// (アニメーション途中の1枚だけを「変わっていない」と誤読しないためポーリングする)
    func testBackWithATreeChangeIsNotFlaggedAsIneffective() async throws {
        _ = try await server.call(tool: "ft_snapshot", args: [:])
        driver.scriptedSnapshots = [
            SnapshotResponse(sessionBundleID: "com.example.app",
                             screen: FTRect(x: 0, y: 0, width: 390, height: 844),
                             elements: [], truncatedCount: 0),
        ]
        let content = try await server.call(tool: "ft_navigate", args: ["target": "back"])
        let text = try XCTUnwrap(content.first?["text"] as? String)
        XCTAssertFalse(text.contains("no effect on this screen"), text)
    }

    /// home/appSwitcher は対象外(back だけの検知)
    func testHomeAndAppSwitcherAreNeverFlaggedAsIneffective() async throws {
        _ = try await server.call(tool: "ft_snapshot", args: [:])
        for target in ["home", "appSwitcher"] {
            let content = try await server.call(tool: "ft_navigate", args: ["target": target])
            let text = try XCTUnwrap(content.first?["text"] as? String)
            XCTAssertFalse(text.contains("no effect on this screen"), "\(target): \(text)")
        }
    }

    /// ref 省略はフォーカス中の欄(DSL の clearInput() と同じ)。
    /// **消した後に必ず読み返す**: in-app iOS の UIKit 経路は clearInput の成否を
    /// 検証なしで YES と返すので、読み返さないと「cleared」が嘘になり、続く ft_type が黙って連結する
    func testClearInputPassesTheRefOrNilAndReadsBack() async throws {
        _ = try await server.call(tool: "ft_clear_input", args: ["ref": 2])
        _ = try await server.call(tool: "ft_clear_input", args: [:])
        XCTAssertEqual(driver.calls,
                       ["clearInput(ref:2)", "snapshot", "clearInput(ref:nil)", "snapshot"])
    }

    /// **入力を伴わない Enter も撃てること**。iOS はソフトキーボードを閉じる手段が
    /// pressEnter しかない(hideKeyboard は Android 専用)ので、text 必須にすると
    /// 「閉じるためだけに何か打つ」しかなくなる
    func testPressEnterAloneIsAllowed() async throws {
        _ = try await server.call(tool: "ft_type", args: ["pressEnter": true])
        XCTAssertEqual(driver.calls, ["pressEnter"], "打鍵せず Enter だけ撃つこと")

        // ref を渡したときはフォーカスを立ててから撃つ
        _ = try await server.call(tool: "ft_type", args: ["ref": 4, "pressEnter": true])
        XCTAssertEqual(driver.calls, ["pressEnter", "tap(ref:4)", "pressEnter"])
    }

    /// text も pressEnter も無ければ弾く(打つものが無い)
    func testTypeRequiresTextUnlessPressEnter() async {
        await assertThrows("ft_type", [:])
        XCTAssertEqual(driver.calls, [])
    }

    /// **Enter を別ツールにしない**ぶん、引数が確実に効くこと(既定は撃たない)。
    /// 末尾の `snapshot` は **ref なし入力の確認**(下の testTypeWithoutRefIsConfirmed 参照)
    func testTypeFiresEnterOnlyWhenAsked() async throws {
        _ = try await server.call(tool: "ft_type", args: ["text": "abc"])
        XCTAssertEqual(driver.calls, ["type(ref:nil,text:abc)", "snapshot"])

        _ = try await server.call(tool: "ft_type", args: ["text": "abc", "pressEnter": true])
        XCTAssertEqual(driver.calls,
                       ["type(ref:nil,text:abc)", "snapshot",
                        "type(ref:nil,text:abc)", "snapshot", "pressEnter"])
    }

    /// 索引はデバイスに触らない。**既定は署名だけ**(全件の要約まで返すと 15KB 級になる)
    func testDslCommandsListsSignaturesAndNarrowsByName() async throws {
        let all = try await server.call(tool: "ft_dsl_commands", args: [:])
        let allText = try XCTUnwrap(all.first?["text"] as? String)
        XCTAssertTrue(allText.contains("tap(selector"), allText.prefix(200).description)
        XCTAssertFalse(allText.contains("—"), "既定では要約を出さない")

        let one = try await server.call(tool: "ft_dsl_commands", args: ["name": "pinchOut"])
        let oneText = try XCTUnwrap(one.first?["text"] as? String)
        XCTAssertTrue(oneText.contains("pinchOut(selector?"), oneText)
        XCTAssertTrue(oneText.contains("—"), "名前を絞ったら要約も出す")

        // 索引に無い名前は**存在しない**ことを伝える(でっち上げの抑止がこのツールの目的)
        let missing = try await server.call(tool: "ft_dsl_commands", args: ["name": "swipeDown"])
        let missingText = try XCTUnwrap(missing.first?["text"] as? String)
        XCTAssertTrue(missingText.contains("does not exist"), missingText)
        XCTAssertEqual(driver.calls, [], "索引はデバイスに触らない")
    }

    func testDragRequiresAllCoordinates() async {
        await assertThrows("ft_drag", ["fromX": 1.0, "fromY": 2.0])
        XCTAssertEqual(driver.calls, [])
    }

    /// **session と前面は別物**: session はブリッジが掴んでいるアプリで、ホームへ戻っても
    /// 変わらない。「今そのアプリを見ているか」を状態として出す(2026-08-06 の外部フィードバック)
    func testStatusRendersReadyDeviceAndSession() async throws {
        driver.foregroundBundleID = "com.example.app"
        let content = try await server.call(tool: "ft_status", args: [:])
        XCTAssertEqual(driver.calls, ["status", "foregroundAppID"])
        let text = try XCTUnwrap(content.first?["text"] as? String)
        XCTAssertTrue(text.contains("iPhone 17"), text)
        XCTAssertTrue(text.contains("com.example.app"), text)
        XCTAssertTrue(text.contains("foreground: yes"), text)
    }

    /// ホーム画面や別アプリが前面なら、**何が前に居るか**まで返す
    func testStatusSaysWhenTheSessionAppIsNotInFront() async throws {
        driver.foregroundBundleID = "com.apple.springboard"
        let content = try await server.call(tool: "ft_status", args: [:])
        let text = try XCTUnwrap(content.first?["text"] as? String)
        XCTAssertTrue(text.contains("foreground: no"), text)
        XCTAssertTrue(text.contains("com.apple.springboard"), text)
    }

    func testInstallPassesPackagePath() async throws {
        _ = try await server.call(tool: "ft_install", args: ["packagePath": "/tmp/A.app"])
        XCTAssertEqual(driver.calls, ["install(/tmp/A.app)"])
    }

    func testLaunchPassesBundleID() async throws {
        _ = try await server.call(tool: "ft_launch", args: ["bundleId": "com.example.x"])
        XCTAssertEqual(driver.calls, ["launch(com.example.x)"])
    }

    /// snapshot は SnapshotRenderer の出力(ref・型・ラベル)をそのまま返す。
    /// ここが崩れるとエージェントは ref を読めず tap できない
    func testSnapshotReturnsRenderedElements() async throws {
        let content = try await server.call(tool: "ft_snapshot", args: [:])
        let text = try XCTUnwrap(content.first?["text"] as? String)
        XCTAssertTrue(text.contains("[1]"), text)
        XCTAssertTrue(text.contains("ログイン"), text)
        XCTAssertTrue(text.contains("login_btn"), text)
    }

    /// スクロール容器は行に印を出し、**2つ以上あるときだけ**先頭で名指しする
    /// (`scrollFrame:` を書く判断はここでしかできない。1つの画面で勧めると
    /// iOS in-app では XCUITest フォールバックを払うだけになる)
    func testSnapshotMarksScrollContainersAndNamesThemWhenAmbiguous() async throws {
        driver.snapshotResponse = SnapshotResponse(
            sessionBundleID: "com.example.app",
            screen: FTRect(x: 0, y: 0, width: 390, height: 844),
            elements: [
                ElementInfo(ref: 1, type: "ScrollView", identifier: "chips", label: nil,
                            value: nil, placeholder: nil, enabled: true,
                            frame: FTRect(x: 0, y: 60, width: 390, height: 60), depth: 1,
                            scrollable: true),
                ElementInfo(ref: 2, type: "Table", identifier: "list_rows", label: nil,
                            value: nil, placeholder: nil, enabled: true,
                            frame: FTRect(x: 0, y: 120, width: 390, height: 600), depth: 1,
                            scrollable: true),
            ],
            truncatedCount: 0)
        let content = try await server.call(tool: "ft_snapshot", args: [:])
        let text = try XCTUnwrap(content.first?["text"] as? String)
        XCTAssertTrue(text.contains("2 scroll areas"), text)
        XCTAssertTrue(text.contains("#list_rows"), text)
        XCTAssertTrue(text.contains("id=chips scroll"), text)
    }

    /// 申告できないエンジン(Compose/Flutter の in-app)では黙る。
    /// 印も注記も出さない = 「スクロールしない画面」と読ませない
    func testSnapshotStaysSilentWhenNoScrollContainerIsDeclared() async throws {
        let content = try await server.call(tool: "ft_snapshot", args: [:])
        let text = try XCTUnwrap(content.first?["text"] as? String)
        XCTAssertFalse(text.contains("scroll area"), text)
        XCTAssertFalse(text.contains(" scroll"), text)
    }

    /// **撮った id は台帳へ落ちる**(ft_dry_run が綴り誤りの照合に使う唯一の供給源。
    /// ここが切れると照合は永久に黙り、機能が死んでいることに誰も気付けない)
    func testSnapshotRecordsSelectorsForTheInventory() async throws {
        _ = try await server.call(tool: "ft_snapshot", args: [:])
        XCTAssertEqual(recorded.count, 1, "スナップショットが台帳へ落ちていない")
        XCTAssertTrue(recorded.first?.ids.contains("login_btn") ?? false,
                      "id が拾えていない: \(recorded)")
        XCTAssertEqual(recorded.first?.platform, "ios")
    }

    func testTapByRef() async throws {
        _ = try await server.call(tool: "ft_tap", args: ["ref": 3])
        XCTAssertEqual(driver.calls, ["tap(ref:3)"])
    }

    func testTapByCoordinates() async throws {
        _ = try await server.call(tool: "ft_tap", args: ["x": 12.5, "y": 34.0])
        XCTAssertEqual(driver.calls, ["tap(x:12.5,y:34.0)"])
    }

    /// ref と x/y の両方が来たら ref を優先する(座標は snapshot 依存で古くなりうる)
    func testTapPrefersRefOverCoordinates() async throws {
        _ = try await server.call(tool: "ft_tap", args: ["ref": 7, "x": 1.0, "y": 2.0])
        XCTAssertEqual(driver.calls, ["tap(ref:7)"])
    }

    func testTypeWithRef() async throws {
        _ = try await server.call(tool: "ft_type", args: ["text": "あいう", "ref": 2])
        XCTAssertEqual(driver.calls, ["type(ref:2,text:あいう)"])
    }

    /// ref 省略時は「フォーカス中の要素」= ref nil をドライバへ渡す
    func testTypeWithoutRefPassesNil() async throws {
        _ = try await server.call(tool: "ft_type", args: ["text": "hello"])
        XCTAssertEqual(driver.calls, ["type(ref:nil,text:hello)", "snapshot"])
    }

    /// replace: true は type の前に clearInput(ft_clear_input と同じ呼び出し形)を挟み、
    /// 最後に読み返し用の snapshot を1回だけ払う(clear の嘘 200 を検出するため)
    func testTypeReplaceClearsBeforeTyping() async throws {
        _ = try await server.call(tool: "ft_type", args: ["text": "あいう", "ref": 2, "replace": true])
        XCTAssertEqual(driver.calls, ["clearInput(ref:2)", "type(ref:2,text:あいう)", "snapshot"])
    }

    /// replace: false(既定と同じ)は今までどおり追記のみで、clearInput は呼ばない
    func testTypeReplaceFalseStillAppends() async throws {
        _ = try await server.call(tool: "ft_type", args: ["text": "あいう", "ref": 2, "replace": false])
        XCTAssertEqual(driver.calls, ["type(ref:2,text:あいう)"])
    }

    /// replace: true のときは「追記」警告(the field already held ...)を出さず、
    /// 置換した旨の短い注記に差し替わる
    func testTypeReplaceSkipsTheAppendWarning() async throws {
        driver.snapshotResponse = SnapshotResponse(
            sessionBundleID: "com.example.app",
            screen: FTRect(x: 0, y: 0, width: 390, height: 844),
            elements: [ElementInfo(ref: 1, type: "textField", identifier: "search",
                                   label: nil, value: "hello", placeholder: nil, enabled: true,
                                   frame: FTRect(x: 0, y: 0, width: 200, height: 40), depth: 2,
                                   focused: true)],
            truncatedCount: 0)
        _ = try await server.call(tool: "ft_snapshot", args: [:])

        let appended = Self.responseText(try await server.call(
            tool: "ft_type", args: ["text": "world", "ref": 1]))
        XCTAssertTrue(appended.contains("the field already held"), appended)

        // 読み返しが「入力どおり」を確認できたときだけ置換の注記が付く(clear の嘘 200 対策)。
        // 偽ドライバは type で値を書き換えないので、読み返し用の木を入力後の値に差し替える
        driver.snapshotResponse = SnapshotResponse(
            sessionBundleID: "com.example.app",
            screen: FTRect(x: 0, y: 0, width: 390, height: 844),
            elements: [ElementInfo(ref: 1, type: "textField", identifier: "search",
                                   label: nil, value: "world", placeholder: nil, enabled: true,
                                   frame: FTRect(x: 0, y: 0, width: 200, height: 40), depth: 2,
                                   focused: true)],
            truncatedCount: 0)
        let replaced = Self.responseText(try await server.call(
            tool: "ft_type", args: ["text": "world", "ref": 1, "replace": true]))
        XCTAssertFalse(replaced.contains("the field already held"), replaced)
        XCTAssertTrue(replaced.contains("replaced the field's prior content"), replaced)
    }

    private static func responseText(_ content: [[String: Any]]) -> String {
        content.compactMap { $0["text"] as? String }.joined()
    }

    /// **ref なしの入力は撃ちっぱなしにしない**: iOS の XCUITest ランナーは ref から対象を
    /// 引けたときだけ読み返す(TypeReadback)ので、ref なしは無検証で OK が返っていた。
    /// 木は `focused` を持っているので、撮り直して**どこへ入ったか**を名指しする。
    /// 焦点が無ければそれ自体が答え(撃った先が無かった = 沈黙した誤り)
    func testTypeWithoutRefIsConfirmedAgainstTheFocusedField() async throws {
        driver.snapshotResponse = SnapshotResponse(
            sessionBundleID: "com.example.app",
            screen: FTRect(x: 0, y: 0, width: 390, height: 844),
            elements: [ElementInfo(ref: 1, type: "textField", identifier: "search",
                                   label: nil, value: "hello", placeholder: nil, enabled: true,
                                   frame: FTRect(x: 0, y: 0, width: 200, height: 40), depth: 2,
                                   focused: true)],
            truncatedCount: 0)
        let hit = Self.responseText(try await server.call(tool: "ft_type", args: ["text": "hello"]))
        XCTAssertTrue(hit.contains("#search"), hit)
        XCTAssertTrue(hit.contains("hello"), hit)

        // 焦点がどこにも無い = 撃った先が無い
        driver.snapshotResponse = SnapshotResponse(
            sessionBundleID: "com.example.app",
            screen: FTRect(x: 0, y: 0, width: 390, height: 844),
            elements: [ElementInfo(ref: 1, type: "button", identifier: "b", label: "B", value: nil,
                                   placeholder: nil, enabled: true,
                                   frame: FTRect(x: 0, y: 0, width: 10, height: 10), depth: 2)],
            truncatedCount: 0)
        let miss = Self.responseText(try await server.call(tool: "ft_type", args: ["text": "hello"]))
        XCTAssertTrue(miss.contains("nothing has input focus"), miss)
    }

    func testSwipeParsesDirection() async throws {
        _ = try await server.call(tool: "ft_swipe", args: ["direction": "left"])
        XCTAssertEqual(driver.calls, ["swipe(left)"])
    }

    func testPressUsesDefaultDurationWhenOmitted() async throws {
        _ = try await server.call(tool: "ft_long_press", args: ["ref": 4])
        XCTAssertEqual(driver.calls, ["press(ref:4,duration:1.0)"])
    }

    func testPressPassesExplicitHoldSeconds() async throws {
        _ = try await server.call(tool: "ft_long_press", args: ["ref": 4, "holdSeconds": 2.5])
        XCTAssertEqual(driver.calls, ["press(ref:4,duration:2.5)"])
    }

    /// screenshot は text ではなく image コンテンツ(base64 + mimeType)で返す契約。
    /// FakeDriver の絵は PNG として解釈できないので、ここは**縮小できないときの原寸フォールバック**でもある
    func testScreenshotReturnsBase64Image() async throws {
        let content = try await server.call(tool: "ft_screenshot", args: [:])
        let item = try XCTUnwrap(content.first)
        XCTAssertEqual(item["type"] as? String, "image")
        XCTAssertEqual(item["mimeType"] as? String, "image/png")
        XCTAssertEqual(item["data"] as? String, driver.screenshotData.base64EncodedString())
    }

    /// 既定は縮小 JPEG。原寸 PNG は 830〜910KB あり base64 でさらに 1.33 倍になるため、
    /// **既定が原寸へ戻る退行**をここで落とす
    func testScreenshotDownscalesByDefault() async throws {
        driver.screenshotData = Self.makePNG(width: 1179, height: 2556)
        let content = try await server.call(tool: "ft_screenshot", args: [:])
        let item = try XCTUnwrap(content.first)
        XCTAssertEqual(item["mimeType"] as? String, "image/jpeg")
        let data = try XCTUnwrap(Data(base64Encoded: try XCTUnwrap(item["data"] as? String)))
        // バイト数ではなく**画素数**で見る: 合成画像は PNG のほうが小さくなることがあり
        // (市松模様は可逆圧縮が効く)、サイズ比較では「縮小したか」を判定できない
        let source = try XCTUnwrap(CGImageSourceCreateWithData(data as CFData, nil))
        let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any]
        XCTAssertEqual(properties?[kCGImagePropertyPixelWidth] as? Int, MCPServer.screenshotMaxWidth)
    }

    func testScreenshotFullSizeReturnsOriginalPNG() async throws {
        driver.screenshotData = Self.makePNG(width: 1179, height: 2556)
        let content = try await server.call(tool: "ft_screenshot", args: ["fullSize": true])
        let item = try XCTUnwrap(content.first)
        XCTAssertEqual(item["mimeType"] as? String, "image/png")
        XCTAssertEqual(item["data"] as? String, driver.screenshotData.base64EncodedString())
    }

    /// 単色だと JPEG が極端に小さくなり「縮小したか」の判定が甘くなるので市松模様にする
    private static func makePNG(width: Int, height: Int) -> Data {
        let space = CGColorSpaceCreateDeviceRGB()
        let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8,
                                bytesPerRow: 0, space: space,
                                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        for y in stride(from: 0, to: height, by: 16) {
            for x in stride(from: 0, to: width, by: 16) where (x / 16 + y / 16) % 2 == 0 {
                context.setFillColor(CGColor(red: 0.1, green: 0.6, blue: 0.9, alpha: 1))
                context.fill(CGRect(x: x, y: y, width: 16, height: 16))
            }
        }
        let image = context.makeImage()!
        let out = NSMutableData()
        let dest = CGImageDestinationCreateWithData(out, UTType.png.identifier as CFString, 1, nil)!
        CGImageDestinationAddImage(dest, image, nil)
        CGImageDestinationFinalize(dest)
        return out as Data
    }

    func testTerminate() async throws {
        _ = try await server.call(tool: "ft_terminate", args: [:])
        XCTAssertEqual(driver.calls, ["terminate"])
    }

    // MARK: - 必須引数の欠落・不正値

    /// **ドライバを呼ぶ前に**弾くこと(呼んでから失敗すると副作用が残る)
    func testMissingRequiredArgumentsThrowBeforeTouchingDriver() async {
        let cases: [(tool: String, args: [String: Any], expect: String)] = [
            ("ft_install", [:], "packagePath"),
            ("ft_launch", [:], "bundleId"),
            ("ft_type", [:], "text"),
            ("ft_long_press", [:], "ref"),
            ("ft_tap", [:], "ref or x/y"),
            ("ft_swipe", ["direction": "sideways"], "up/down/left/right"),
            ("ft_run_scenario", [:], "id"),
            ("ft_dry_run", [:], "id"),
        ]
        for testCase in cases {
            do {
                _ = try await server.call(tool: testCase.tool, args: testCase.args)
                XCTFail("\(testCase.tool): 引数不足なのに成功した")
            } catch {
                XCTAssertTrue(error.localizedDescription.contains(testCase.expect),
                              "\(testCase.tool): 期待する語 \"\(testCase.expect)\" が"
                              + "エラー文に無い: \(error.localizedDescription)")
            }
        }
        XCTAssertEqual(driver.calls, [], "引数不足でドライバに触れてはいけない")
    }

    /// x だけ / y だけの半端な座標は座標タップとして扱わない
    func testTapWithOnlyOneCoordinateIsRejected() async {
        for args in [["x": 1.0], ["y": 2.0]] as [[String: Any]] {
            do {
                _ = try await server.call(tool: "ft_tap", args: args)
                XCTFail("片方だけの座標が通った: \(args)")
            } catch {
                XCTAssertTrue(error.localizedDescription.contains("ref or x/y"),
                              error.localizedDescription)
            }
        }
        XCTAssertEqual(driver.calls, [])
    }

    func testUnknownToolThrows() async {
        do {
            _ = try await server.call(tool: "ft_nope", args: [:])
            XCTFail("未知のツールが通った")
        } catch {
            XCTAssertTrue(error.localizedDescription.contains("ft_nope"), error.localizedDescription)
        }
    }

    /// ドライバ側の失敗はそのまま投げ上げる(握り潰さない)。整形は handle 側の責務
    func testDriverFailurePropagates() async {
        driver.failing = ["tap"]
        do {
            _ = try await server.call(tool: "ft_tap", args: ["ref": 1])
            XCTFail("ドライバの失敗が握り潰された")
        } catch {
            XCTAssertTrue(error.localizedDescription.contains("tap"), error.localizedDescription)
        }
    }

    // MARK: - 宣言と実装の対応

    /// ドライバ操作系は空引数でも「未知のツール」にならない = dispatch が存在する。
    /// **プロジェクト系(下記 projectBackedTools)は呼ばない**: ft_list_scenarios は swift build を
    /// 起こし、ft_doctor は実 FM を叩くため(数秒〜分・環境依存)。そちらは名前の集合で担保する
    private static let driverBackedTools: Set<String> = [
        "ft_status", "ft_install", "ft_launch", "ft_snapshot", "ft_tap", "ft_type",
        "ft_swipe", "ft_scroll_to", "ft_batch", "ft_long_press", "ft_screenshot", "ft_terminate",
        "ft_double_tap", "ft_pinch", "ft_drag",
        "ft_navigate", "ft_clear_input", "ft_clear_app_data", "ft_open_url", "ft_rotate",
        "ft_list_apps",
    ]
    private static let projectBackedTools: Set<String> = [
        "ft_list_scenarios", "ft_run_scenario", "ft_dry_run", "ft_list_projects", "ft_doctor",
        "ft_draft_scenario", "ft_dsl_commands",
    ]
    /// ドライバを掴まないがホストの外部コマンド(simctl / adb)やファイル走査を伴うので
    /// ここでは呼ばない。名前の集合だけで宣言と dispatch の対応を担保する
    private static let hostBackedTools: Set<String> = ["ft_list_devices", "ft_logs"]

    func testDriverBackedToolsAreAllDispatched() async {
        for name in Self.driverBackedTools {
            do {
                _ = try await server.call(tool: name, args: [:])
            } catch {
                XCTAssertFalse(error.localizedDescription.contains("unknown tool"),
                               "\(name) は宣言されているが dispatch されていない")
            }
        }
    }

    /// **宣言と実装の対応表**。ツールを足したらここも更新することになり、そこで
    /// 「dispatch を書いたか」を意識する(宣言だけして `call` に case を書き忘れると、
    /// クライアントからは見えるのに呼ぶと必ず「未知のツール」で落ちる)
    func testDeclaredToolNamesMatchKnownSet() {
        let declared = Set(MCPServer.toolDefinitions.compactMap { $0["name"] as? String })
        XCTAssertEqual(declared,
                       Self.driverBackedTools.union(Self.projectBackedTools)
                           .union(Self.hostBackedTools),
                       "ツールの増減があります。dispatch(MCPServer.call)に case を足したうえで"
                       + "このテストの集合を更新すること")
    }
}
