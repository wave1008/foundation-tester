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
        let loop = try XCTUnwrap(source.range(of: "for bundleID in FrontmostApp.candidates"))
        let after = String(source[loop.upperBound...].prefix(300))
        XCTAssertTrue(after.contains("Date() >= deadline"), "1件ごとに締切を見ること: \(after)")
    }
}
