import XCTest
@testable import fleetest
import FTCore

/// ライブ操作のセッション追従。**判定(LiveSessionTarget)は純粋関数**なので直接当て、
/// デバイスが要る配線(破壊的な操作の前にセッションを対象へ戻す)はソース走査で固定する。
final class LiveSessionFollowerTests: XCTestCase {

    private let springboard = "com.apple.springboard"

    // MARK: - 向き先の判定

    func testPointsAtSpringboardWhenTheAppIsNotInFront() {
        XCTAssertEqual(
            LiveSessionTarget.retarget(sessionTarget: "com.example.app", preferred: "com.example.app",
                                       preferredIsForeground: false, systemAlertPresent: false, frontmost: nil),
            springboard)
    }

    func testStaysOnTheAppWhileItIsInFront() {
        XCTAssertNil(
            LiveSessionTarget.retarget(sessionTarget: "com.example.app", preferred: "com.example.app",
                                       preferredIsForeground: true, systemAlertPresent: false, frontmost: nil))
    }

    func testComesBackToTheAppOnceItIsInFrontAgain() {
        XCTAssertEqual(
            LiveSessionTarget.retarget(sessionTarget: springboard, preferred: "com.example.app",
                                       preferredIsForeground: true, systemAlertPresent: false, frontmost: nil),
            "com.example.app")
    }

    /// 向き先が同じなら撃たない —— 向け直しはランナーの refFrames を消すので、
    /// 毎コマンド撃つと直前のスナップショットの ref が無効になる
    func testDoesNotRetargetWhenAlreadyPointedAtSpringboard() {
        XCTAssertNil(
            LiveSessionTarget.retarget(sessionTarget: springboard, preferred: "com.example.app",
                                       preferredIsForeground: false, systemAlertPresent: false, frontmost: nil))
        XCTAssertNil(
            LiveSessionTarget.retarget(sessionTarget: springboard, preferred: nil,
                                       preferredIsForeground: false, systemAlertPresent: false, frontmost: nil))
    }

    /// **システムアラートが出ている間は springboard へ倒す**。アラートは別プロセスの窓なので
    /// アプリの state は runningForeground のままで、前面判定だけでは切り替わらない ——
    /// アプリを向いたままだとアラートは木に1要素も載らず、要素一覧に出ないし ref でも叩けない
    /// (2026-09-21: 「システムダイアログのとき要素一覧に出ない」の実害)。
    func testPointsAtSpringboardWhileASystemAlertIsUp() {
        XCTAssertEqual(
            LiveSessionTarget.retarget(sessionTarget: "com.example.app", preferred: "com.example.app",
                                       preferredIsForeground: true, systemAlertPresent: true, frontmost: nil),
            springboard)
    }

    /// アラートが閉じたら戻る(出ている間だけの倒し込み)
    func testComesBackToTheAppOnceTheAlertIsGone() {
        XCTAssertEqual(
            LiveSessionTarget.retarget(sessionTarget: springboard, preferred: "com.example.app",
                                       preferredIsForeground: true, systemAlertPresent: false, frontmost: nil),
            "com.example.app")
    }

    /// 既に springboard を向いていれば撃たない(向け直しは refFrames を消す)
    func testDoesNotRetargetWhenAlreadyOnSpringboardDuringAnAlert() {
        XCTAssertNil(
            LiveSessionTarget.retarget(sessionTarget: springboard, preferred: "com.example.app",
                                       preferredIsForeground: true, systemAlertPresent: true, frontmost: nil))
    }

    /// アプリを選んでいない(起動直後・終了後)は画面にあるものを触るだけ。
    /// **前面判定が true でも** preferred が無ければ springboard へ倒す
    func testPointsAtSpringboardWithoutAPreferredApp() {
        XCTAssertEqual(
            LiveSessionTarget.retarget(sessionTarget: nil, preferred: nil, preferredIsForeground: true, systemAlertPresent: false, frontmost: nil),
            springboard)
    }

    // MARK: - 前面アプリ(駆動対象外のアプリを見ているとき)

    /// 駆動対象でないアプリ(設定アプリ等)が前面なら、そちらへ向ける。springboard へ倒すと
    /// 操作は絶対座標で届くが木は SpringBoard 自身の UI しか持たず、要素一覧がほぼ空になる
    /// (2026-09-22 の実害)。
    func testPointsAtTheFrontmostAppWhenItIsNotThePreferredOne() {
        XCTAssertEqual(
            LiveSessionTarget.retarget(sessionTarget: springboard, preferred: "com.example.app",
                                       preferredIsForeground: false, systemAlertPresent: false,
                                       frontmost: "com.apple.Preferences"),
            "com.apple.Preferences")
    }

    /// 見つからなければ従来どおり springboard(ホーム画面・アプリスイッチャーはこちら)
    func testFallsBackToSpringboardWithoutAFrontmostApp() {
        XCTAssertEqual(
            LiveSessionTarget.retarget(sessionTarget: "com.example.app", preferred: "com.example.app",
                                       preferredIsForeground: false, systemAlertPresent: false,
                                       frontmost: nil),
            springboard)
    }

    /// **アラート中は frontmost を使わない** —— アラートを載せているのは SpringBoard のほうで、
    /// 裏のアプリへ向けるとアラートが木から消える
    func testIgnoresTheFrontmostAppWhileASystemAlertIsUp() {
        XCTAssertEqual(
            LiveSessionTarget.retarget(sessionTarget: "com.example.app", preferred: "com.example.app",
                                       preferredIsForeground: true, systemAlertPresent: true,
                                       frontmost: "com.apple.Preferences"),
            springboard)
    }

    /// 駆動しているアプリが前面ならそのまま(frontmost より preferred が優先)
    func testPrefersTheDrivenAppOverTheFrontmostLookup() {
        XCTAssertNil(
            LiveSessionTarget.retarget(sessionTarget: "com.example.app", preferred: "com.example.app",
                                       preferredIsForeground: true, systemAlertPresent: false,
                                       frontmost: "com.apple.Preferences"))
    }

    // MARK: - 候補の作り方(FrontmostApp)

    /// `launchctl list` は UIKitApplication 以外の行が大半。bundle ID だけを取り出す
    func testExtractsBundleIDsFromLaunchctlOutput() {
        let output = """
        97515	0	UIKitApplication:com.example.ftrunner.uitests.xctrunner[b88c][rb-legacy]
        95284	0	UIKitApplication:com.apple.Fitness[b41c][rb-legacy]
        -	0	com.apple.audio.SandboxHelper
        97784	0	UIKitApplication:com.apple.Preferences[b0d0][rb-legacy]
        """
        XCTAssertEqual(FrontmostApp.candidates(launchctlOutput: output),
                       ["com.apple.Fitness", "com.apple.Preferences"],
                       "UIKitApplication 行だけを採り、ランナー自身は落とすこと")
    }

    /// **SpringBoard は常に前面と答える**(system shell なので背面に回らない)。除外しないと
    /// 必ず2つ以上が前面になり、前面アプリを決められない(実測 2026-09-22)
    func testPicksTheOnlyForegroundAppExcludingSpringboard() {
        XCTAssertEqual(
            FrontmostApp.pick(foreground: [springboard, "com.apple.Preferences"]),
            "com.apple.Preferences")
    }

    /// **ホーム画面の裏方を前面アプリにしない**。実測 2026-09-22: ホーム画面で
    /// `com.apple.chrono.WidgetRenderer-Default` が前面と答える(SpringBoard も true)。
    /// 落とさないとセッションがそこを向き、home が「前面のまま」で 422 になる(実害)
    func testDoesNotPickSpringboardBackgroundHelpers() {
        XCTAssertNil(FrontmostApp.pick(foreground: [springboard, "com.apple.chrono.WidgetRenderer-Default"]),
                     "ウィジェットのレンダラは利用者が見ている「アプリ」ではない")
        XCTAssertNil(FrontmostApp.pick(foreground: [springboard, "com.apple.iMessageAppsViewService"]),
                     "ビューサービスも同じ")
        // 候補を作る段でも落とす(前面かを聞く相手を減らす)
        let output = """
        86275\t0\tUIKitApplication:com.apple.chrono.WidgetRenderer-Default[984f][rb-legacy]
        89073\t0\tUIKitApplication:com.apple.iMessageAppsViewService[145f][rb-legacy]
        97784\t0\tUIKitApplication:com.apple.Preferences[b0d0][rb-legacy]
        """
        XCTAssertEqual(FrontmostApp.candidates(launchctlOutput: output), ["com.apple.Preferences"])
    }

    /// 0個 = アプリは前面にない(ホーム画面)。呼び手は springboard へ倒す
    func testPicksNothingWhenNoAppIsInFront() {
        XCTAssertNil(FrontmostApp.pick(foreground: [springboard]))
        XCTAssertNil(FrontmostApp.pick(foreground: []))
    }

    /// 2個以上 = 判定材料が足りない。**黙って選ばない**(別のアプリの木を読ませない)
    func testRefusesWhenSeveralAppsClaimToBeInFront() {
        XCTAssertNil(FrontmostApp.pick(foreground: ["com.apple.Preferences", "com.apple.Maps"]))
    }

    // MARK: - 配線(ソース走査)

    private func liveCommandSource() throws -> String {
        let url = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("Sources/fleetest/ApiLiveCommand.swift")
        return try String(contentsOf: url, encoding: .utf8)
    }

    private func followerSource() throws -> String {
        let url = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("Sources/fleetest/LiveSessionFollower.swift")
        return try String(contentsOf: url, encoding: .utf8)
    }

    /// 判定へ渡す `systemAlertPresent` は**ドライバに聞いた事実**でなければならない。
    /// リテラルに落としても表示は成立してしまう: 常に false ならアラート中にアプリのツリーしか
    /// 返らず(要素一覧に出ない・ref で叩けない)、常に true なら操作のたびに springboard へ
    /// 向け直して直前の ref を捨てることになる。
    func testFollowAsksTheDriverWhetherASystemAlertIsUp() throws {
        let source = try followerSource()
        XCTAssertTrue(source.contains("driver.systemAlert()"),
                      "アラートの有無はドライバに聞くこと")
        let ask = try XCTUnwrap(source.range(of: "driver.systemAlert()"))
        let guardRange = try XCTUnwrap(source.range(of: "guard let target = LiveSessionTarget.retarget"))
        XCTAssertTrue(ask.lowerBound < guardRange.lowerBound,
                      "判定より前に聞くこと")
        // 前面と答えた回だけ聞く(常時の監視にしない)
        let foregroundGate = try XCTUnwrap(source.range(of: "if foreground {"))
        XCTAssertTrue(foregroundGate.lowerBound < ask.lowerBound,
                      "前面と答えた回だけ聞くこと(前面でなければどのみち springboard を向く)")
    }

    private func caseBody(_ source: String, cmd: String, until next: String) throws -> String {
        let start = try XCTUnwrap(source.range(of: "case \"\(cmd)\":"))
        let end = try XCTUnwrap(source.range(of: "case \"\(next)\":", range: start.upperBound..<source.endIndex))
        return String(source[start.upperBound..<end.lowerBound])
    }

    /// `/terminate` はセッションの向き先を殺す。追従で springboard を向いたまま撃つと
    /// **SpringBoard 自身を終了させる**ので、対象のアプリへ戻してからでなければならない
    func testTerminatePointsTheSessionAtTheAppFirst() throws {
        let body = try caseBody(try liveCommandSource(), cmd: "terminate", until: "clearAppData")
        let pointAt = try XCTUnwrap(body.range(of: "pointAtApp"))
        let terminate = try XCTUnwrap(body.range(of: "driver.terminate()"))
        XCTAssertTrue(pointAt.lowerBound < terminate.lowerBound,
                      "terminate は pointAtApp の後で撃つこと: \(body)")
    }

    /// clearAppData はホスト側で `terminate()`(= セッションのアプリ)を撃ってから
    /// コンテナを消す。対象へ寄せずに撃つと別のものを殺す
    func testClearAppDataPointsTheSessionAtTheTargetFirst() throws {
        let body = try caseBody(try liveCommandSource(), cmd: "clearAppData", until: "install")
        let pointAt = try XCTUnwrap(body.range(of: "pointAtApp"))
        let clear = try XCTUnwrap(body.range(of: "driver.clearAppData("))
        XCTAssertTrue(pointAt.lowerBound < clear.lowerBound,
                      "clearAppData は pointAtApp の後で撃つこと: \(body)")
    }

    /// アプリを選んでいないセッションでは `/terminate` を撃たない —— 追従で springboard を
    /// 向いているので、そのまま撃つと **SpringBoard 自身**を終了させる
    func testTerminateRefusesWithoutAnAppInTheSession() throws {
        let body = try caseBody(try liveCommandSource(), cmd: "terminate", until: "clearAppData")
        XCTAssertTrue(body.contains("guard let target = follower.drivenApp()"),
                      "駆動しているアプリが無いときは断ること: \(body)")
    }

    /// clearAppData の既定対象にセッションの springboard を採らない(同じ理由)
    func testClearAppDataNeverDefaultsToSpringboard() throws {
        let source = try liveCommandSource()
        let start = try XCTUnwrap(source.range(of: "private func resolveBundleForClearAppData"))
        let end = try XCTUnwrap(source.range(of: "\n    }", range: start.upperBound..<source.endIndex))
        let body = String(source[start.upperBound..<end.lowerBound])
        XCTAssertTrue(body.contains("!= LiveSessionTarget.springboard"),
                      "セッションからの既定は springboard を除くこと: \(body)")
    }

    /// 追従させるのは画面を触るコマンドだけ。セッションを引数で名指しするコマンドを
    /// ここへ入れると、自分で決めた向き先を追従が上書きする
    func testOnlyScreenTouchingCommandsFollowTheFrontmostApp() throws {
        let source = try liveCommandSource()
        let start = try XCTUnwrap(source.range(of: "private static func followsFrontmost"))
        let end = try XCTUnwrap(source.range(of: "\n    }", range: start.upperBound..<source.endIndex))
        let body = String(source[start.upperBound..<end.lowerBound])
        for cmd in ["tap", "type", "clear", "hideKeyboard", "swipe", "drag", "doubleTap", "pinch",
                    "press", "back", "appSwitcher", "home"] {
            XCTAssertTrue(body.contains("\"\(cmd)\""), "\(cmd) が追従の一覧から落ちている")
        }
        for cmd in ["launch", "activate", "terminate", "clearAppData", "install", "frame", "refresh"] {
            XCTAssertFalse(body.contains("\"\(cmd)\""), "\(cmd) は追従させない")
        }
    }
}

/// 前面アプリの探索は **preferred が前面でないときだけ**走らせる。毎回走らせると操作のたびに
/// simctl spawn と候補ぶんの IPC を払う(体感できる遅さになる)。
extension LiveSessionFollowerTests {
    func testLooksForTheFrontmostAppOnlyWhenTheDrivenAppIsNotInFront() throws {
        let source = try followerSource()
        XCTAssertTrue(source.contains("if !foreground && !systemAlertPresent && !covered {"),
                      "探索の門(前面でない・アラート無し・覆われていない)が無い")
        let gate = try XCTUnwrap(source.range(of: "if !foreground && !systemAlertPresent && !covered {"))
        let call = try XCTUnwrap(source.range(of: "await frontmostApp(driver: driver)"))
        XCTAssertTrue(gate.lowerBound < call.lowerBound, "門の中で呼ぶこと")
    }
}

/// 木が読めない状態からの回復(`snapshotWithSessionFallback`)。**ライブ操作では普通に起きる**:
/// 利用者はいつでも画面を切り替えるので、前面追従が向けた直後に前面が外れる。
/// 409(セッション未作成)も 422(セッションのアプリが前面でない)も、springboard は背面に
/// 回らないのでそこへ倒せば必ず読める。**follower にも伝える**(黙って倒すと「まだあのアプリを
/// 向いている」と思い続け、次の追従が撃たない)。
/// 実体は driver とブリッジが要るのでソース走査で固定する。
extension LiveSessionFollowerTests {
    private func liveSource() throws -> String {
        let url = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("Sources/fleetest/ApiLiveCommand.swift")
        return try String(contentsOf: url, encoding: .utf8)
    }

    func testSnapshotFallbackRecoversFromBothNoSessionAndNotInForeground() throws {
        let source = try liveSource()
        let start = try XCTUnwrap(source.range(of: "private func snapshotWithSessionFallback"))
        let end = try XCTUnwrap(source.range(of: "\n    }", range: start.upperBound..<source.endIndex))
        let body = String(source[start.upperBound..<end.lowerBound])
        XCTAssertTrue(body.contains("status == 409 || status == 422"),
                      "409(セッション未作成)と 422(前面でない)の両方から回復すること: \(body)")
        XCTAssertTrue(body.contains("LiveSessionTarget.springboard"),
                      "倒す先は springboard(背面に回らないので必ず読める): \(body)")
        XCTAssertTrue(body.contains("follower?.noteSessionChanged"),
                      "倒したことを follower にも伝えること: \(body)")
    }
}

/// **SpringBoard の面が覆っている間はアプリを前面と見なさない**。アプリスイッチャー・
/// コントロールセンター・通知センターの間もアプリは foreground と答え続ける(実測 2026-09-22:
/// スイッチャー表示中に Safari が foreground:true で、木もページのまま)。見ないと開いた面に
/// 対してアプリへ activate を撃ち、**その面が閉じてアプリへ戻る**。
/// デバイスが要るのでソース走査で固定する。
extension LiveSessionFollowerTests {
    func testTreatsACoveredAppAsNotInFront() throws {
        let source = try followerSource()
        XCTAssertTrue(source.contains("driver.systemUICovering()"),
                      "覆いの有無はドライバに聞くこと(アプリ側からは気付けない)")
        // 前面と答えた回だけ聞き、覆われていたら前面扱いを取り消す
        let ask = try XCTUnwrap(source.range(of: "driver.systemUICovering()"))
        let decision = try XCTUnwrap(source.range(of: "guard let target = LiveSessionTarget.retarget"))
        XCTAssertTrue(ask.lowerBound < decision.lowerBound, "判定より前に聞くこと")
        let after = String(source[ask.upperBound...].prefix(200))
        XCTAssertTrue(after.contains("foreground = false"), "覆われていたら前面扱いを取り消すこと")
    }

    /// アプリスイッチャーの目印が覆いの一覧に入っていること(ここが無いと覆いを検出できない)
    func testSwitcherCountsAsACoveringSurface() {
        XCTAssertTrue(BridgeAPI.systemUICoveringMarkers.contains("SBSwitcherWindow"))
    }

    /// **覆われているときは前面アプリを探さない**。見えているのは SpringBoard の面なので
    /// springboard へ倒すのが正しく、探すだけ無駄。しかも面が出ている間は state の問い合わせが
    /// 極端に遅く、探索が応答を止める(実測 2026-09-22: アプリスイッチャー表示中に 120 秒を超えて
    /// 強制終了 = 拡張から見ると serve が固まり、要素一覧も枠も更新されない)。
    func testDoesNotSearchForTheFrontmostAppWhileCovered() throws {
        let source = try followerSource()
        XCTAssertTrue(source.contains("!foreground && !systemAlertPresent && !covered"),
                      "覆われているときは探索の門を通さないこと")
    }

    /// **向け直しは画面を動かさない attach で撃つ**。前面だと確かめた相手でも activate は
    /// 画面を動かす —— Spotlight を開くと `com.apple.Spotlight` が前面と答えるが、これは
    /// SpringBoard の拡張で、activate すると**ホーム画面が描画を失い真っ黒になる**
    /// (実測 2026-09-22 の陽性対照: スクリーンショット 2.2MB→68KB・木が 28→6 要素)。
    /// 自アプリでも in-app の activate は既定実装から launch = 注入付きの再起動へ落ちる。
    /// デバイスが要るのでソース走査で固定する。
    func testPointsTheSessionWithoutMovingTheScreen() throws {
        let source = try followerSource()
        let start = try XCTUnwrap(source.range(of: "guard let target = LiveSessionTarget.retarget"))
        let end = try XCTUnwrap(source.range(of: "\n    }", range: start.upperBound..<source.endIndex))
        let body = String(source[start.upperBound..<end.lowerBound])
        XCTAssertTrue(body.contains("driver.attach(bundleID: target)"),
                      "向け直しは attach で撃つこと: \(body)")
        XCTAssertFalse(body.contains("driver.activate("),
                      "activate は画面を動かすので使わないこと: \(body)")
    }

    /// 探索そのものにも締切を置く(拡張の serve 応答待ちより十分内側)。尽きたら springboard へ倒す
    func testFrontmostSearchHasABudget() throws {
        let source = try followerSource()
        XCTAssertTrue(source.contains("frontmostSearchBudgetSeconds"), "締切の定数があること")
        let loop = try XCTUnwrap(source.range(of: "for bundleID in candidates {"))
        let after = String(source[loop.upperBound...].prefix(300))
        XCTAssertTrue(after.contains("Date() >= deadline"), "1件ごとに締切を見ること: \(after)")
    }

    // MARK: - 実機の前面アプリ(devicectl 経由)

    /// 実機に simctl は撃てない(候補が空 = 前面のアプリを見ていても springboard のまま = アプリの要素が
    /// 1つも取れない。実地 2026-09-24: M1Ultra の iPhone wave で YouTube)。実機は devicectl の
    /// processes × apps(IOSPhysicalRunningApps)で候補を採り、同じ「ちょうど1つ」の規則に通す。
    /// デバイスが要る配線なのでソース走査で固定する
    func testPhysicalDevicesEnumerateRunningAppsThroughDevicectl() throws {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let follower = try String(contentsOf: root.appendingPathComponent("Sources/fleetest/LiveSessionFollower.swift"),
                                  encoding: .utf8)
        guard let search = follower.range(of: "private func frontmostApp(driver: AppDriver) async -> String? {") else {
            return XCTFail("frontmostApp が見当たらない — テストを見直すこと")
        }
        let body = follower[search.upperBound...]
        XCTAssertTrue(body.contains("if physical {"), "実機で分岐すること")
        XCTAssertTrue(body.contains("IOSPhysicalRunningApps.running("),
                      "実機は devicectl の processes × apps で候補を採ること")
        XCTAssertTrue(body.contains("udid: udid, apps: apps, timeout: Self.physicalDevicectlTimeoutSeconds"),
                      "毎コマンド撃つので短い timeout を渡すこと")
        XCTAssertTrue(body.contains("FrontmostApp.candidates(launchctlOutput: listing.output)"),
                      "シミュレータは従来どおり launchctl で採ること")
        let command = try String(contentsOf: root.appendingPathComponent("Sources/fleetest/ApiLiveCommand.swift"),
                                 encoding: .utf8)
        XCTAssertTrue(command.contains("let physical = udid.flatMap { SimulatorCatalog.isPhysical(udid: $0) } ?? false")
                      && command.contains("LiveSessionFollower(udid: udid, physical: physical,"),
                      "serve は実機かを SimulatorCatalog.isPhysical で解いて follower へ渡すこと")
    }

    func testRunningBundleIDCandidatesApplyTheSameExclusions() {
        XCTAssertEqual(
            FrontmostApp.candidates(runningBundleIDs: [
                "com.apple.springboard", "com.google.ios.youtube", "com.apple.chrono.WidgetRenderer-Default",
                "com.google.ios.youtube", "io.github.x.xctrunner", "com.apple.Preferences",
            ]),
            ["com.google.ios.youtube", "com.apple.Preferences"],
            "除外(SpringBoard・ランナー・裏方)と重複を落とし、順序は入力のまま")
    }
}

/// L-C: 実機で devicectl(apps/processes)が詰まると、back-off が無いと**毎コマンド**
/// apps/processes 双方の timeout を払い続け、command watchdog(30秒)に引っかかって serve が
/// 毎分再起動していた(M1Ultra 実地)。`DevicectlBackoff.isActive` は純粋関数なのでデバイス無しで
/// 全分岐を当て、follower 側の配線(短い timeout・失敗のたびの back-off 開始・back-off 中は
/// devicectl に触らない)はソース走査で固定する。
extension LiveSessionFollowerTests {

    // MARK: - DevicectlBackoff(純粋関数)

    func testBackoffIsNotActiveWithoutAPriorFailure() {
        XCTAssertFalse(DevicectlBackoff.isActive(lastFailureAt: nil, now: Date(), backoffSeconds: 30))
    }

    func testBackoffIsActiveRightAfterAFailure() {
        let now = Date()
        XCTAssertTrue(DevicectlBackoff.isActive(lastFailureAt: now, now: now, backoffSeconds: 30))
        XCTAssertTrue(DevicectlBackoff.isActive(
            lastFailureAt: now, now: now.addingTimeInterval(10), backoffSeconds: 30))
    }

    /// 窓が切れたら再挑戦を許す(そうでないと1回の詰まりが永久に devicectl を止める)
    func testBackoffExpiresAfterTheWindow() {
        let now = Date()
        XCTAssertFalse(DevicectlBackoff.isActive(
            lastFailureAt: now, now: now.addingTimeInterval(31), backoffSeconds: 30))
    }

    /// ちょうど境界(経過 == backoffSeconds)は「切れた」側に倒す(`<` であって `<=` ではない)——
    /// 境界を「まだ有効」に倒すと、時計の丸めで実質1周分ずつ余計に待つことになる
    func testBackoffBoundaryIsExclusive() {
        let now = Date()
        XCTAssertFalse(DevicectlBackoff.isActive(
            lastFailureAt: now, now: now.addingTimeInterval(30), backoffSeconds: 30))
    }

    // MARK: - 配線(ソース走査)

    private func frontmostAppBody() throws -> String {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let follower = try String(
            contentsOf: root.appendingPathComponent("Sources/fleetest/LiveSessionFollower.swift"),
            encoding: .utf8)
        guard let search = follower.range(
            of: "private func frontmostApp(driver: AppDriver) async -> String? {") else {
            throw XCTSkip("frontmostApp が見当たらない — テストを見直すこと")
        }
        return String(follower[search.upperBound...])
    }

    /// back-off 中は apps()/running() のどちらも呼ばない(呼ぶだけ無駄・毎コマンドの timeout を払う)。
    /// 判定はブロックの先頭(if physicalApps == nil より前)にあること
    func testBackoffGateComesBeforeEitherDevicectlCall() throws {
        let body = try frontmostAppBody()
        guard let physicalRange = body.range(of: "if physical {") else {
            return XCTFail("実機の分岐が見当たらない")
        }
        guard let gateRange = body.range(
            of: "DevicectlBackoff.isActive(", range: physicalRange.upperBound..<body.endIndex) else {
            return XCTFail("back-off の判定(DevicectlBackoff.isActive)が無い")
        }
        guard let appsCallRange = body.range(
            of: "IOSPhysicalAppCatalog.apps(", range: physicalRange.upperBound..<body.endIndex) else {
            return XCTFail("apps() の呼び出しが見当たらない")
        }
        guard let runningCallRange = body.range(
            of: "IOSPhysicalRunningApps.running(", range: physicalRange.upperBound..<body.endIndex) else {
            return XCTFail("running() の呼び出しが見当たらない")
        }
        XCTAssertTrue(gateRange.upperBound < appsCallRange.lowerBound,
                      "back-off の判定は apps() より前に行うこと")
        XCTAssertTrue(gateRange.upperBound < runningCallRange.lowerBound,
                      "back-off の判定は running() より前に行うこと")
    }

    /// 毎コマンド撃つ2呼び出しは、他の呼び手(list-apps 等)の既定 30 秒ではなく
    /// physicalDevicectlTimeoutSeconds(短い timeout)を渡すこと
    func testBothDevicectlCallsUseTheShortTimeout() throws {
        let body = try frontmostAppBody()
        let occurrences = body.components(separatedBy: "timeout: Self.physicalDevicectlTimeoutSeconds").count - 1
        XCTAssertEqual(occurrences, 2,
                       "apps()/running() の両方が短い timeout を渡すこと(occurrences=\(occurrences))")
    }

    /// 失敗/タイムアウトのたびに noteDevicectlFailure(back-off の開始点)を経由すること。
    /// **catch 節で直接 log() しない** —— 直接 log すると、次に back-off ゲートで早期 return する
    /// 回とログの経路が2つに割れ、「1回だけ言う」の保証が薄れる
    func testBothDevicectlFailuresGoThroughNoteDevicectlFailure() throws {
        let body = try frontmostAppBody()
        // `action: "` の引用符つきで数える(関数宣言 `action: String` 自体を呼び出しと誤カウントしない)
        let occurrences = body.components(separatedBy: "noteDevicectlFailure(action: \"").count - 1
        XCTAssertEqual(occurrences, 2,
                       "apps() の catch と running() の catch の両方が noteDevicectlFailure を"
                       + " 呼ぶこと(occurrences=\(occurrences))")
    }

    /// noteDevicectlFailure が back-off の起点(lastDevicectlFailureAt)を書き、ログはそこでだけ出す
    func testNoteDevicectlFailureRecordsTheTimestampAndLogsOnce() throws {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let follower = try String(
            contentsOf: root.appendingPathComponent("Sources/fleetest/LiveSessionFollower.swift"),
            encoding: .utf8)
        guard let start = follower.range(of: "private func noteDevicectlFailure(") else {
            return XCTFail("noteDevicectlFailure が見当たらない")
        }
        guard let end = follower.range(of: "\n    }", range: start.upperBound..<follower.endIndex) else {
            return XCTFail("noteDevicectlFailure の終わりが見当たらない")
        }
        let body = String(follower[start.upperBound..<end.lowerBound])
        XCTAssertTrue(body.contains("lastDevicectlFailureAt = Date()"),
                      "back-off の起点を書くこと")
        XCTAssertTrue(body.contains("log("), "ログを出すこと")
    }
}

/// ライブ操作の自動起動は、同じ実機を宛先に持つ別ポートのランナーを見たら起動しない(maintainer-notes §49.4)
final class LiveAutoStarterDuplicateRunnerWiringTests: XCTestCase {
    func testLaunchBridgeChecksForAnotherRunnerBeforeStarting() throws {
        let url = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("Sources/fleetest/LiveBridgeAutoStarter.swift")
        let code = try String(contentsOf: url, encoding: .utf8)
        guard let guardRange = code.range(of: "BridgeLauncher.runnersOnDevice("),
              let startRange = code.range(of: "try launcher.startDetached()") else {
            return XCTFail("launchBridge の門か起動が見当たらない — テストを見直すこと")
        }
        XCTAssertLessThan(guardRange.lowerBound, startRange.lowerBound, "門は startDetached より前に置く")
        XCTAssertTrue(code.contains("LauncherError.deviceRunnerElsewhere("))
    }
}
