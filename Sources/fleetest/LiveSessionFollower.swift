// ライブ操作は「画面に映っているものを触る」——スマホを触るのと同じ感覚に合わせる。
//
// XCUITest ブリッジのジェスチャ・入力は **セッションのアプリが前面のときしか撃てない**
// (背面のアプリの窓を引くと XCTest が Tear Down してランナーごと落ちるので、
// BridgeRouter.requireForegroundAppForGesture / ForInput が 422 で断る)。木も同じで、
// 背面のアプリのセッションで撮ると画面ではなく**最後の状態**が返る。
//
// そこで操作と観測の直前に、セッションを**今 前面にあるもの**へ向け直す。SpringBoard は
// system shell で背面に回らないので、そこへ向けたセッションのジェスチャは**画面の絶対座標**
// として何の上へでも届く(ホーム画面・アプリスイッチャー・別のアプリ・システムダイアログ)。
//
// **iOS(XCUITest ブリッジ)専用** —— Android は木がアクティブウィンドウ・タップが画面座標なので
// この補正は要らない(ApiLiveServe は ios のときだけこの型を作る)。

import FTBridgeClient
import FTCore
import Foundation

/// 向き先の決定だけを持つ純粋ロジック(判定はここ1箇所・デバイスが要る部分は LiveSessionFollower)
enum LiveSessionTarget {
    static let springboard = "com.apple.springboard"

    /// 次に向け直すべき bundle ID。**nil = 変更不要**(向け直しは refFrames を消すので、
    /// 同じ向き先なら撃たない = 直前のスナップショットの ref を生かしたままにする)。
    /// - preferred: パネルが駆動しているアプリ(未選択・終了後は nil)
    /// **システムアラートが出ている間は springboard へ倒す** —— アラートは別プロセスの窓なので
    /// アプリの `.state` は `.runningForeground` のまま(BridgeRouter.handleAppState)で、前面判定
    /// だけでは向き先が変わらない。アプリを向いたままだとアラートは木に1要素も載らず、
    /// 要素一覧に出ないし ref でも叩けない。
    ///
    /// - frontmost: preferred 以外のアプリが前面にいるならその bundle ID(FrontmostApp)。
    ///   **駆動対象でないアプリ(設定アプリ等)を開いている間も木を読めるようにするため**に要る ——
    ///   springboard へ倒すと操作は絶対座標で届くが、木は SpringBoard 自身の UI しか持たない。
    ///   アラート中は使わない(アラートを載せているのは SpringBoard のほう)。
    static func retarget(sessionTarget: String?, preferred: String?,
                         preferredIsForeground: Bool, systemAlertPresent: Bool,
                         frontmost: String?) -> String? {
        let onTheApp = preferredIsForeground && !systemAlertPresent
        let other = systemAlertPresent ? nil : frontmost
        let desired = (onTheApp ? preferred : nil) ?? other ?? springboard
        return desired == sessionTarget ? nil : desired
    }
}

/// devicectl(実機の apps/processes 列挙)の back-off 判定だけを持つ純粋ロジック。「詰まった
/// devicectl は1コマンド分の損失で済ませる、毎コマンドの損失にしない」——実地(M1Ultra):
/// devicectl が詰まり、apps/processes 双方のタイムアウトを毎コマンド払って command watchdog
/// (30秒。`ResidentProcessGuard.startCommandWatchdog`)に引っかかり続け、serve が毎分
/// 再起動していた(再起動のたびに自動起動が別ブリッジを追加で立てていた)
enum DevicectlBackoff {
    /// 直近の失敗/タイムアウト(lastFailureAt)から backoffSeconds 以内なら true
    /// (= devicectl を呼ばず springboard へ倒す。呼び手はログも出さない)
    static func isActive(lastFailureAt: Date?, now: Date, backoffSeconds: TimeInterval) -> Bool {
        guard let lastFailureAt else { return false }
        return now.timeIntervalSince(lastFailureAt) < backoffSeconds
    }
}

/// ランナーのセッションを「今 前面にあるもの」へ追従させる。状態はこの型だけが書き換える
final class LiveSessionFollower {
    /// パネルが駆動しているアプリ。nil = まだ選んでいない(= 画面にあるものを触るだけ)
    private(set) var preferred: String?
    /// ランナーのセッションの向き先 = **今どのアプリを触っているか**。**こちらが動かした分だけ**
    /// 追う(起動時だけ /status で採る)。レコーディングの採否(対象アプリの上での操作か)も
    /// これで決めるので外へ出す(ApiLiveActionResultEvent.app)
    private(set) var sessionTarget: String?
    private var initialized = false
    /// 前面アプリの全探索に使ってよい時間[秒]。**拡張の serve 応答待ち(20 秒)の十分内側**に置く ——
    /// 超えると拡張が serve を kill→respawn し、画面が固まったように見える。
    /// 尽きたら springboard へ倒す(木は読めるので操作は続けられる)。
    private static let frontmostSearchBudgetSeconds: TimeInterval = 3

    /// devicectl(apps/processes)1回あたりの上限[秒]。実測 ~0.6秒/回
    /// (IOSPhysicalRunningApps.swift 冒頭のコメント参照)なので通常は届かないが、詰まったとき
    /// 両呼び出し(apps + processes)が上限まで待っても、1コマンドの所要が拡張の
    /// SERVE_REQUEST_TIMEOUT(20秒)・command watchdog(30秒)の十分内側に収まるようにする
    private static let physicalDevicectlTimeoutSeconds: TimeInterval = 5
    /// devicectl が失敗/タイムアウトしてから、次に呼び直すまでの猶予[秒]。command watchdog と
    /// 同じ 30 秒(根拠は DevicectlBackoff のコメント参照)
    private static let devicectlBackoffSeconds: TimeInterval = 30

    /// 直近に見つけた前面アプリ(preferred 以外)。次回はこれを1回聞くだけで済ませる。
    private var lastFrontmost: String?
    /// 直近に devicectl(apps/processes のどちらか)が失敗/タイムアウトした時刻。
    /// nil = 一度も失敗していない。DevicectlBackoff.isActive の入力
    private var lastDevicectlFailureAt: Date?

    /// 起動中アプリを列挙するための宛先(シミュレータ: simctl / 実機: devicectl)。nil = 列挙しない
    private let udid: String?
    /// 実機か(ApiLiveCommand が SimulatorCatalog.isPhysical で1回だけ解く)。列挙の口が違う ——
    /// 実機に simctl を撃つと失敗して候補が空 = 前面のアプリを見ていても springboard を向いたままになり、
    /// **アプリの要素が1つも取れない**(実地: M1Ultra の iPhone wave で YouTube を表示中)
    private let physical: Bool
    /// 実機のインストール済みアプリ(bundle ID と url)。滅多に変わらないので最初の探索で1回だけ採る
    private var physicalApps: [IOSPhysicalAppCatalog.App]?
    private let log: (String) -> Void

    init(udid: String?, physical: Bool, log: @escaping (String) -> Void) {
        self.udid = udid
        self.physical = physical
        self.log = log
    }

    /// 操作・観測の直前に呼ぶ。**失敗しても投げない** —— 向け直せなかっただけで
    /// 利用者のコマンドを道連れにしない(通常の経路で撃ち、結果は本来の失敗で返る)
    func follow(driver: AppDriver) async {
        await initializeIfNeeded(driver: driver)
        var foreground = false
        if let preferred {
            // **セッションが preferred を向いているときの答えだけが確か** —— ランナーは
            // セッションのアプリなら保持しているインスタンスに聞くが、向いていないときの
            // その場 proxy は実機で前面でも false を返すことがある(BridgeRouter.handleAppState)。
            // 嘘は「戻り遅れ」にしかならない(springboard を向いたままでも座標では届く)ので安全側
            foreground = (try? await driver.isAppForeground(bundleID: preferred)) ?? false
        }
        // **SpringBoard の面が覆っているかは常に見る** —— アプリスイッチャー・コントロール
        // センター・通知センターの間、**どのアプリも foreground と答え続ける**(アプリ側からは
        // 気付けないので専用の口がある。BridgeRouter.handleSystemUICovering)。
        // preferred の前面判定だけでなく**前面アプリの探索も必ず誤る**ので、駆動対象が前面か
        // どうかに関わらず先に聞く(実害: 駆動対象でない Safari を見ている状態で
        // スイッチャーを開くと、探索が Safari を「前面」と拾って木が Safari のままだった)。
        let covered = ((try? await driver.systemUICovering()) ?? nil)?.covering == true
        if covered {
            foreground = false
            lastFrontmost = nil // 面の向こうのアプリを「前面」として覚えない
        }
        // **聞くのは前面と答えた回だけ** —— 前面でなければどのみち springboard を向くので、
        // アラートの有無は答えを変えない(常時の監視にしない)。
        var systemAlertPresent = false
        if foreground {
            systemAlertPresent = ((try? await driver.systemAlert()) ?? nil)?.present ?? false
        }
        // preferred が前面でなく、アラートも面も出ていないなら「別のアプリを見ている」可能性がある。
        // **そのときだけ探す**(毎回 simctl と IPC を払わない)。
        // **覆われているときは探さない** —— 見えているのは SpringBoard の面なので springboard へ
        // 倒すのが正しく、探すだけ無駄。しかも面が出ている間は state の問い合わせが極端に遅く、
        // 探索が応答を止める(実測: アプリスイッチャー表示中に 120 秒を超えて
        // 強制終了 = 拡張から見ると serve が固まる)
        var frontmost: String?
        if !foreground && !systemAlertPresent && !covered {
            frontmost = await frontmostApp(driver: driver)
        }
        guard let target = LiveSessionTarget.retarget(
            sessionTarget: sessionTarget, preferred: preferred, preferredIsForeground: foreground,
            systemAlertPresent: systemAlertPresent, frontmost: frontmost) else { return }
        do {
            if target == LiveSessionTarget.springboard {
                // springboard は**起動せず参照だけ**(BridgeRouter.handleLaunch)。
                // activate で撃つとホームへ飛んでシステムアラートを消す
                try await driver.launch(bundleID: target)
            } else {
                // **前面確認だけの attach**(activate ではない)—— 前面だと確かめた相手でも
                // activate は画面を動かす。Spotlight のような SpringBoard の拡張を activate すると
                // ホーム画面が描画を失って真っ黒になり、自アプリなら注入付きの再起動になる
                // (AppDriver.attach の doc)。失敗しても activate へ倒さない
                try await driver.attach(bundleID: target)
            }
            sessionTarget = target
            log("pointed the session at \(target)")
        } catch {
            log("could not point the session at \(target): \(error.localizedDescription)")
        }
    }

    /// 今 前面にあるアプリ(preferred 以外)。**公開 API だけで採る** —— 手順と根拠は FrontmostApp。
    /// 見つからなければ nil(呼び手は springboard へ倒す)。
    ///
    /// **直近の答えを先に1回だけ確かめる** —— 同じアプリを見ている間は IPC 1 回で済み、
    /// 起動中アプリの列挙(simctl spawn)も全候補への問い合わせも払わない。
    private func frontmostApp(driver: AppDriver) async -> String? {
        if let last = lastFrontmost,
           (try? await driver.isAppForeground(bundleID: last)) == true {
            return last
        }
        lastFrontmost = nil
        guard let udid else { return nil }
        let candidates: [String]
        if physical {
            // **back-off 中は devicectl に触らない**(呼ぶだけ無駄・ログも出さない) ——
            // 詰まった devicectl は apps/processes どちらも同じ 5 秒 timeout を毎回払うので、
            // back-off が無いと毎コマンド 10 秒前後を捨てて command watchdog(30秒)に迫る
            guard !DevicectlBackoff.isActive(lastFailureAt: lastDevicectlFailureAt, now: Date(),
                                             backoffSeconds: Self.devicectlBackoffSeconds) else {
                return nil
            }
            if physicalApps == nil {
                do {
                    physicalApps = try IOSPhysicalAppCatalog.apps(
                        udid: udid, timeout: Self.physicalDevicectlTimeoutSeconds)
                } catch {
                    noteDevicectlFailure(action: "list the installed apps of", udid: udid, error: error)
                    return nil
                }
            }
            guard let apps = physicalApps else { return nil }
            let running: [String]
            do {
                running = try IOSPhysicalRunningApps.running(
                    udid: udid, apps: apps, timeout: Self.physicalDevicectlTimeoutSeconds)
            } catch {
                noteDevicectlFailure(action: "list the running apps of", udid: udid, error: error)
                return nil
            }
            if running.isEmpty {
                log("devicectl listed no running app on \(udid) — falling back to springboard")
            }
            candidates = FrontmostApp.candidates(runningBundleIDs: running)
        } else {
            guard let listing = try? Shell.run(
                ["xcrun", "simctl", "spawn", udid, "launchctl", "list"], timeout: 10), listing.status == 0
            else { return nil }
            candidates = FrontmostApp.candidates(launchctlOutput: listing.output)
        }
        // **探索に締切を置く** —— 1件あたりの問い合わせは普通ミリ秒だが、画面の状態によっては
        // 極端に遅くなる(実測)。ライブ操作は人間の操作なので、待たせるくらいなら
        // 「見つからなかった」(= springboard へ倒す)ほうがよい。尽きたら打ち切る
        let deadline = Date().addingTimeInterval(Self.frontmostSearchBudgetSeconds)
        var foreground: [String] = []
        for bundleID in candidates {
            if Date() >= deadline {
                log("frontmost search hit its budget — falling back to springboard")
                return nil
            }
            if (try? await driver.isAppForeground(bundleID: bundleID)) == true {
                foreground.append(bundleID)
            }
        }
        let picked = FrontmostApp.pick(foreground: foreground)
        lastFrontmost = picked
        if let picked { log("frontmost app is \(picked)") }
        return picked
    }

    /// devicectl(apps/processes)の失敗/タイムアウトを記録し、back-off 窓を開始する。
    /// **ログはここでだけ出す** —— 以後 back-off が切れるまでの呼び出しは冒頭の
    /// DevicectlBackoff.isActive で早期 return するので、同じ失敗を毎コマンド言わずに済む
    private func noteDevicectlFailure(action: String, udid: String, error: Error) {
        lastDevicectlFailureAt = Date()
        log("could not \(action) \(udid) — backing off devicectl for"
            + " \(Int(Self.devicectlBackoffSeconds))s and falling back to springboard:"
            + " \(error.localizedDescription)")
    }

    /// **セッションのアプリを対象に撃つ破壊的な操作**(terminate / clearAppData)の前に、
    /// セッションをそのアプリへ戻す。springboard を向いたまま撃つと SpringBoard 自身を
    /// 終了させる(clearAppData はホスト側で `terminate()` を撃ってからコンテナを消す)。
    /// 前面に無ければ activate が前面へ出すが、**どちらもこの直後に終了させる操作**なので
    /// 見えるのは一瞬で、取り違えて別のものを殺すほうが害が大きい
    func pointAtApp(_ bundleID: String, driver: AppDriver) async throws {
        await initializeIfNeeded(driver: driver)
        guard sessionTarget != bundleID else { return }
        try await driver.activate(bundleID: bundleID)
        sessionTarget = bundleID
    }

    /// セッションを動かすコマンド(launch / activate)が成功した直後に呼ぶ
    func noteSessionChanged(to bundleID: String) {
        initialized = true
        sessionTarget = bundleID
        preferred = bundleID == LiveSessionTarget.springboard ? nil : bundleID
    }

    /// `/terminate` の後に呼ぶ。ランナーは session を落とす(`sessionBundleID = nil`)が、
    /// **preferred は残す** —— 利用者が駆動しているアプリは変わっておらず、次の起動・
    /// clearAppData の既定対象もそれのため
    func noteSessionDropped() {
        initialized = true
        sessionTarget = nil
    }

    /// パネルが駆動しているアプリ(terminate の対象・clearAppData の bundle 省略時の既定)。
    /// **`/status` を引く前にこちらを使う** —— セッションは springboard を向いていることがあり、
    /// そのまま対象にすると SpringBoard を終了させる・そのデータを消す
    func drivenApp() -> String? { preferred }

    private func initializeIfNeeded(driver: AppDriver) async {
        guard !initialized else { return }
        initialized = true
        let status = try? await driver.status()
        sessionTarget = status?.sessionBundleID
        // **駆動対象にできないものは preferred にしない** —— 起動時のセッションが
        // SpringBoard の裏方(ウィジェットのレンダラ等)を向いていることがあり、そのまま
        // 引き継ぐと「そのアプリを駆動している」ことになって前面追従が働かない
        // (実害: screen がウィジェットの窓になり、絵が横に膨らんだ)
        preferred = sessionTarget.map { FrontmostApp.isExcluded($0) ? nil : $0 } ?? nil
    }
}
