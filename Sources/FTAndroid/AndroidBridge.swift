// デバイス常駐ブリッジ(AndroidRunner/、instrumentation APK 内蔵 HTTP サーバ)の起動管理。
// プロトコルは iOS ブリッジと完全互換なので、通信は FTBridgeClient.BridgeClient をそのまま使う。
// - 初回操作時に APK を自動インストールし `am instrument -w`(デバイス内バックグラウンド)で常駐させる
// - ホストへは `adb forward tcp:0 tcp:8123` (空きポート自動割当)で到達する
// - ブリッジに接続できない場合は DriverError.bridgeUnreachable を投げる(フォールバックなし)

import Foundation
import FTBridgeClient
import FTCore

extension AndroidDriver {

    public static let bridgePackage = "com.example.ftbridge"
    static let bridgeComponent = "com.example.ftbridge/.BridgeInstrumentation"
    /// デバイス側の listen ポート(全デバイス共通。デバイス毎に独立 loopback なので衝突しない)
    static let bridgeDevicePort: UInt16 = 8123
    /// AndroidRunner/build.sh の VERSION_CODE と同期(不一致なら自動で再インストール)
    public static let expectedBridgeVersionCode = 98
    /// am instrument の起動コマンド自身の stdout/stderr の逃がし先(デバイス側。shell が書ける
    /// /data/local/tmp)。起動失敗時だけホストへ pull する(persistInstrumentFailureLog)
    static let instrumentDeviceLogPath = "/data/local/tmp/ftbridge-instrument.log"

    enum BridgeState {
        case active(BridgeClient)
        /// retryAfter まで再試行しない(嵐防止)。期限後の ensureBridge が自動で再試行するため、
        /// 長寿命プロセス(fleetest-mcp / api monitor)でもデバイス復旧後に自動回復する。
        /// detail は初回失敗の原因(期限内の再 throw に引き継ぐ)
        case unavailable(retryAfter: Date, detail: String?)
    }

    /// 失敗キャッシュの保持時間。startBridge の失敗は probe 2s+起動待ち最大 10s 級のコストなので
    /// この間隔で十分嵐を防げる
    static let unavailableRetryInterval: TimeInterval = 60

    /// serial → ブリッジ状態。ドライバを都度生成してもプローブを繰り返さないプロセス共有レジストリ
    static let bridgeLock = NSLock()
    nonisolated(unsafe) static var bridgeRegistry: [String: BridgeState] = [:]
    /// serial → 進行中の startBridge タスク。同一 serial の並行初回操作を1本に集約する
    /// (未集約だと両者が nil を観測し adb forward / am instrument が二重実行される)。
    nonisolated(unsafe) static var bridgeSetup: [String: Task<BridgeClient, Error>] = [:]

    var bridgeKey: String { serial ?? "default" }

    /// 実機かどうか(nil serial は「不明」ではなく「実機ではない」扱い ——
    /// noticePersistentSettingsOnPhysicalDevice と同じ規則)
    private var isPhysicalAndroidDevice: Bool {
        serial.map(DevicePicker.isPhysicalAndroidSerial) ?? false
    }

    /// この接続が Android であることを表す context。**DriverError.bridgeUnreachable/
    /// .bridgeConnectionRefused を投げる/付け替える箇所は必ずこれを通す**(直書きで
    /// physicalDevice を書き漏らすと iOS 向けの案内が Android の失敗に付いたときと
    /// 同じ事故が起きる)
    func androidContext() -> DriverErrorContext {
        DriverErrorContext(engine: .android, physicalDevice: isPhysicalAndroidDevice)
    }

    // MARK: - 状態機械

    /// .active なら(/status 往復せず)即返す。初回・無効化後は forward確認→probe→必要なら起動。
    /// 全て失敗したら .unavailable にキャッシュ(再試行の嵐防止)し案内メッセージ付きで投げる
    func ensureBridge() async throws -> BridgeClient {
        switch Self.getRegistry(bridgeKey) {
        case .active(let client):
            return client
        case .unavailable(let retryAfter, let detail):
            guard Date() >= retryAfter else {
                throw Self.unreachableError(detail: detail, physicalDevice: isPhysicalAndroidDevice,
                                            cachedSecondsRemaining: retryAfter.timeIntervalSinceNow)
            }
            // 期限切れ → 下の再セットアップへ
        case nil:
            break
        }

        // 同一 serial の並行初回操作は1本の startBridge に集約する(進行中があれば相乗り)。
        let key = bridgeKey
        // @unchecked: setup Task は self を触るが、呼び手はこの Task の完了まで await で止まる
        // (value を待つ間 self を別に操作しない)ので self の利用は常に1本
        struct DriverBox: @unchecked Sendable { let driver: AndroidDriver }
        let box = DriverBox(driver: self)
        let setup = Self.beginSetup(key: key) {
            let driver = box.driver
            do {
                let client = try await driver.startBridge()
                Self.setRegistry(key, .active(client))
                return client
            } catch let held as AndroidBridgeHeldByAnotherSession {
                // キャッシュしない: 再生は到達不能の決まり文句で包まれる。判定は lease を読むだけで安い
                Self.setRegistry(key, nil)
                throw held
            } catch {
                Self.setRegistry(key, .unavailable(
                    retryAfter: Date().addingTimeInterval(Self.unavailableRetryInterval),
                    detail: Self.rawFailureDetail(error)))
                throw error
            }
        }
        do {
            return try await setup.value
        } catch let held as AndroidBridgeHeldByAnotherSession {
            // 到達不能ではない(ブリッジは他のセッションの物で、触らないと決めただけ)。到達不能の
            // 決まり文句(「bridge up を試せ」= 同じ門で断られる)で包まない
            throw held
        } catch {
            throw Self.unreachableError(detail: Self.rawFailureDetail(error),
                                        physicalDevice: isPhysicalAndroidDevice)
        }
    }

    /// エラーから「一次情報だけ」を取り出す。`.unavailable` のキャッシュに格納する値と、
    /// `unreachableError` の `detail` はここを通す ——
    /// **既に組み立て済みの DriverError 説明文(errorDescription)を渡すと、
    /// unreachableError がもう一度包んで二重表示になる**(負荷テストで実際に踏んだ:
    /// 固定文が2回出て一次情報が括弧の奥に埋もれた)。DriverError.bridgeUnreachable/
    /// .bridgeConnectionRefused は raw な一次情報を運んでいるので、その `detail` だけを使い
    /// context は捨てる(ここで確定させ直す)。それ以外のエラーは errorDescription/文字列化へ後退する
    static func rawFailureDetail(_ error: Error) -> String {
        guard let driverError = error as? DriverError else {
            return (error as? LocalizedError)?.errorDescription ?? "\(error)"
        }
        switch driverError {
        case .bridgeUnreachable(_, let detail): return detail
        case .bridgeConnectionRefused(_, let detail): return detail
        default: return driverError.errorDescription ?? "\(driverError)"
        }
    }

    /// 同一 key の setup を1本に集約する。進行中の Task があればそれを返し、無ければ起動して登録。
    /// 完了(成功/失敗いずれも)で自動的に登録解除し、次回の再セットアップを妨げない。
    static func beginSetup(key: String,
                           _ body: @escaping @Sendable () async throws -> BridgeClient)
        -> Task<BridgeClient, Error> {
        bridgeLock.lock()
        if let existing = bridgeSetup[key] {
            bridgeLock.unlock()
            return existing
        }
        let task = Task { () async throws -> BridgeClient in
            defer { clearSetup(key: key) }
            return try await body()
        }
        bridgeSetup[key] = task
        bridgeLock.unlock()
        return task
    }

    private static func clearSetup(key: String) {
        bridgeLock.lock(); bridgeSetup[key] = nil; bridgeLock.unlock()
    }

    /// - `detail`: **一次情報の文字列だけを渡すこと**(adb の生の失敗文言等)。
    ///   `DriverError.errorDescription` 経由で既に組み立て済みの説明文を渡すと、
    ///   この関数が組み立てる文の中でもう一度包まれて二重表示になる(実際に踏んだ。
    ///   `rawFailureDetail` がこの規律を守る唯一の抽出口)
    /// - `physicalDevice`: 実機かエミュレータか。呼び出し元は `isPhysicalAndroidDevice`/
    ///   `androidContext()` から渡す(既定値を置かない ——渡し忘れをコンパイルで止める)
    /// - `cachedSecondsRemaining`: 失敗キャッシュ(`.unavailable`)を再生しているときだけ非 nil。
    ///   **キャッシュだと名乗らせる**: 再生された文はライブの失敗と1バイトも
    ///   違わなかったので、読み手は「今まさに adb forward が落ちた」と読む。実際、手で
    ///   `adb forward` を打って成功し `fleetest bridge status` も通るのに MCP だけが同じ文言を
    ///   返し続ける状況で、原因をブリッジ側だと誤認して調査に数分溶かした(実際に踏んだ)。
    ///   嵐防止としてのキャッシュ自体は残す価値がある(失敗1回は probe 2s + 起動待ち最大 10s)
    ///   ので、消さずに**残り時間と抜け道**を添える
    static func unreachableError(detail: String?, physicalDevice: Bool,
                                 cachedSecondsRemaining: TimeInterval? = nil) -> DriverError {
        // **他プロセスで直しても、この文が消えるのは期限後**:
        // `.unavailable` はプロセスごとの static なので、CLI の `bridge up` が成功しても
        // **この長寿命プロセス(fleetest-mcp / monitor)の記憶は消えない**。
        // 「すぐ再試行できる」と書くと、直したのに同じ文が返る次の混乱を作る
        let cached = cachedSecondsRemaining.map {
            " [cached: this is the FIRST failure replayed, not a fresh attempt —"
                + " the next try in \(max(1, Int($0.rounded(.up))))s will actually re-probe."
                + " Fixing the device now (e.g. `fleetest bridge up --platform android`) does NOT"
                + " clear this: the cache is per-process, so this same text replays until then]"
        } ?? ""
        return .bridgeUnreachable(
            context: DriverErrorContext(engine: .android, physicalDevice: physicalDevice),
            detail: (detail ?? "") + cached)
    }

    /// bridgeConnectionRefused(リクエストが届いていないと確実な場合)だけレジストリを無効化して
    /// 1回だけ再プロビジョン+リトライする。それ以外のエラー(HTTPエラー応答等)はそのまま投げる。
    ///
    /// **ここを抜ける bridgeUnreachable/bridgeConnectionRefused は必ず android の context へ
    /// 付け替える**: `BridgeClient`(operation の中身)は自分が iOS xcuitest 向けか Android 向けか
    /// を知らず、既定で iosXCUITest の context を付けて投げる(BridgeClient.send 参照)。
    /// 付け替えないと Android の一時的な adb 断に xcuitest/inapp 向けの案内が付く
    /// (負荷テストで実際に踏んだ)
    func withBridge<T>(_ operation: (BridgeClient) async throws -> T) async throws -> T {
        let client = try await ensureBridge()
        do {
            return try await operation(client)
        } catch DriverError.bridgeConnectionRefused {
            Self.setRegistry(bridgeKey, nil)
            do {
                let retried = try await ensureBridge()
                return try await operation(retried)
            } catch DriverError.bridgeConnectionRefused(_, let retryDetail) {
                throw DriverError.bridgeConnectionRefused(context: androidContext(), detail: retryDetail)
            } catch DriverError.bridgeUnreachable(_, let retryDetail) {
                Self.setRegistry(bridgeKey, nil)
                throw DriverError.bridgeUnreachable(context: androidContext(), detail: retryDetail)
            }
        } catch DriverError.bridgeUnreachable(_, let detail) {
            // **接続が確立してから切れた**(instrumentation の死。コールドブート直後の
            // 起動ストームで頻発する。実測: 起動17s→21s で死亡)。
            // 同じ操作は自動再試行しない — 届いた可能性があり tap/type の二重実行になる。
            // ただし**レジストリは必ず捨てる**: .active は生存確認なしで即返す設計なので、
            // 死んだクライアントを握ったままだと以後の全操作と worker の revive が
            // 同じ死体に当たり続け、二度と復帰しない(復帰しなかった実害の根因)
            Self.setRegistry(bridgeKey, nil)
            throw DriverError.bridgeUnreachable(context: androidContext(), detail: detail)
        }
    }

    /// **読み取りだけの状態照会**(ft_status の Android 一覧用)。ブリッジが動いていなければ起動せず nil ——
    /// `status()` は `withBridge` 経由で起動まで撃つ(APK の導入・force-stop・アニメ無効化)ので、一覧で全台へ撃つと
    /// 他のセッションが使っている端末のブリッジまで作り直す。adb forward も新しく作らない(既存の forward だけ見る)
    public func statusIfBridgeRunning() async -> StatusResponse? {
        if case .active(let client) = Self.getRegistry(bridgeKey) { return try? await client.status() }
        guard let hostPort = findExistingForward() else { return nil }
        guard let status = try? await BridgeClient(port: hostPort, timeoutSeconds: 2).status(), status.ready
        else { return nil }
        return status
    }

    /// bridge up --platform android 用: `.unavailable` を破棄して強制再セットアップ
    public func resetAndEnsureBridge() async throws {
        Self.setRegistry(bridgeKey, nil)
        _ = try await ensureBridge()
    }

    private static func setRegistry(_ key: String, _ state: BridgeState?) {
        bridgeLock.lock()
        bridgeRegistry[key] = state
        bridgeLock.unlock()
    }

    private static func getRegistry(_ key: String) -> BridgeState? {
        bridgeLock.lock()
        defer { bridgeLock.unlock() }
        return bridgeRegistry[key]
    }

    // MARK: - セットアップ

    private func startBridge() async throws -> BridgeClient {
        let hostPort = try ensureForward()
        // 計時ログは instrumentation 引数なので**起動時にしか切り替わらない**。稼働中ブリッジを
        // そのまま使うと、on 側は「1行も出ない = 待ちが無かった」と誤読し、off 側は計測が
        // 終わった後もログを出し続ける。**希望と食い違うときは必ず起動し直す**(両方向)
        let timingRequested = ProcessInfo.processInfo.environment["FT_BRIDGE_TIMING"] == "1"
        // 既に稼働中で版一致ならそのまま使う(CLI の別プロセスが起動済みのケース)。
        // 版不一致(旧ブリッジプロセスが常駐したまま)は素通しせず、下の再インストール+
        // force-stop+再起動で更新する(APK 差し替えだけでは稼働中プロセスは旧版のまま)
        let probed = await probeBridge(hostPort: hostPort)
        if let (client, version, timing) = probed,
           version == Self.expectedBridgeVersionCode, timing == timingRequested {
            return client
        }
        // **他のセッション(run・MCP)が使っているデバイスのブリッジは作り直さない**(下の force-stop が
        // そのセッションの instrumentation ごと落とす)。計時フラグだけが違うなら作り直さずそのまま使う
        // (計時はログの有無だけ)。呼び手が run(とその子 = シナリオ)なら MCP から引き取ったデバイスでも立て直す
        if let serial, let stateDir = (try? RepoRoot.find())?.appendingPathComponent(".fleetest"),
           RunnerAccessibilityHealth.hasForeignLeaseUnlessOwnRun(key: serial, stateDir: stateDir) {
            if let (client, version, _) = probed, version == Self.expectedBridgeVersionCode {
                return client
            }
            throw AndroidBridgeHeldByAnotherSession(serial: serial)
        }

        // sys.boot_completed は起動直後でも既に 1 なのでゲートに使えない(ProfileWorkerFactory の
        // waitForDurableBridge を参照)。代わりに animations 段がどのみち打つ get を1本先出しし、
        // guest の system_server がまだ無い印(スタックトレース)が乗っていれば早期に名指しする
        // **期限つき** —— 凍結した端末はここで答えず、続く段(設定・install・起動)も全部答えない
        let probe: Shell.Result?
        do {
            probe = try adbProbe(["shell", "settings", "get", "global", "window_animation_scale"],
                                 timeout: Self.deviceAnswerTimeoutSeconds)
        } catch ShellError.timedOut {
            throw DriverError.bridgeUnreachable(
                context: androidContext(),
                detail: AndroidGuestReadiness.noAnswerMessage(
                    serial: serial ?? "?", seconds: Self.deviceAnswerTimeoutSeconds))
        } catch {
            probe = nil
        }
        if let probe, let marker = AndroidGuestReadiness.systemServerStartingMarker(in: probe.output) {
            throw DriverError.bridgeUnreachable(
                context: androidContext(),
                detail: AndroidGuestReadiness.stillStartingMessage(marker: marker, serial: serial ?? "?"))
        }

        noticePersistentSettingsOnPhysicalDevice()
        disableAnimations()
        disableStylusHandwriting()
        hideErrorDialogs()
        allowHiddenAPIReflection()
        try installBridgeIfNeeded()
        _ = try? adb(["shell", "am", "force-stop", Self.bridgePackage])
        // -w 必須(UiAutomationConnection は am プロセス側に生成される)。
        // デバイス内でバックグラウンド化するので adb 切断後も常駐する
        let ttl = BridgeAPI.resolvedBridgeTTLSeconds(ProcessInfo.processInfo.environment["FT_BRIDGE_TTL"])
        let repoRoot = try? RepoRoot.find()
        _ = try adb(["shell", Self.instrumentCommand(ttl: ttl, ownerPath: repoRoot?.path, timing: timingRequested)])

        // ready 待ち(200ms 間隔・最大 10 秒)。起動直後は導入したての APK なので版照合は不要
        for _ in 0..<50 {
            if let (client, _, _) = await probeBridge(hostPort: hostPort) { return client }
            try await Task.sleep(nanoseconds: 200_000_000)
        }
        throw DriverError.bridgeUnreachable(
            context: androidContext(),
            detail: "the Android bridge will not start (check adb logcat -s FTBridge)"
                + persistInstrumentFailureLog(repoRoot: repoRoot))
    }

    /// am instrument が失敗時にだけ出す診断(デバイス側の一時ファイル)を pull してホストの
    /// `.fleetest/` へ残す(起動ごとに作り直し、直前は `.prev.log` へ。BridgeLauncher.logPath と
    /// 同じ方式)。repoRoot が引けない/pull できない/中身が空のときは何もせず空文字を返す
    /// (エラー文言に添えられないだけで、起動失敗そのものは変わらず投げる)
    private func persistInstrumentFailureLog(repoRoot: URL?) -> String {
        // **終了コードで見る**(`cat` が対象無しで失敗した回の stderr を診断として書かない。
        // Shell.run は非ゼロで投げないので outputIfSucceeded で弾く)
        guard let repoRoot,
              let deviceLog = (try? adb(["shell", "cat", Self.instrumentDeviceLogPath]))?.outputIfSucceeded,
              !deviceLog.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return "" }
        let stateDir = repoRoot.appendingPathComponent(".fleetest")
        let safeSerial = String((serial ?? "default").map { ch in
            ch.isLetter || ch.isNumber || ch == "." || ch == "-" || ch == "_" ? ch : "_"
        })
        let logPath = stateDir.appendingPathComponent("android-bridge-\(safeSerial).log")
        let prevLogPath = stateDir.appendingPathComponent("android-bridge-\(safeSerial).prev.log")
        try? FileManager.default.createDirectory(at: stateDir, withIntermediateDirectories: true)
        try? FileManager.default.removeItem(at: prevLogPath)
        try? FileManager.default.moveItem(at: logPath, to: prevLogPath)
        guard (try? deviceLog.write(to: logPath, atomically: true, encoding: .utf8)) != nil else { return "" }
        return " (see \(logPath.path))"
    }

    /// 実機に対する設定変更は端末のグローバル設定を**永続的に**書き換える(使い捨ての
    /// エミュレータと違い、run 後も戻らない)。テスト安定に必要なので実行はするが、
    /// 黙って変えないようコールド起動時に 1 回だけ知らせる。
    /// **設定を増やしたらこの文面にも足すこと**(黙って変えない、が規律の本体)。
    /// 実機判定は serial の emulator- 前置(ApiMonitorCommand のヘルス除外と同じ規則)
    private func noticePersistentSettingsOnPhysicalDevice() {
        guard let serial, !serial.hasPrefix("emulator-") else { return }
        let animations = AnimationPolicy.animationsEnabled()
            ? "animations on (restored to the OS default)" : "animations off"
        ConsoleOut.err("ℹ️ \(serial): applying these device settings — \(animations) / "
            + "hidden_api_policy=1 / stylus handwriting off (its IME hint covers the app) / "
            + "crash and ANR dialogs hidden"
            + " (on physical devices these persist; revert via Developer options)")
    }

    /// アニメーションは a11y イベントを発しないため、QuietWaiter の静穏判定後もアニメが表示を
    /// 動かし続け screenshot が古い/遷移途中の絵を掴むことがある(a11y要素はFRESHだが画像だけSTALE)。
    /// 既定は無効化。実行プロファイルの enableAnimations(→ FT_ANIMATIONS)が ON のときは OS 既定の
    /// 1 へ戻す。ブリッジのコールド起動時のみ実行(毎操作ではないため3回のadb spawnは許容)。
    /// run 開始ごとの同期は ProfileWorkerFactory.syncAnimationSettings(ブリッジ再利用でも効く)。
    /// 失敗は非致命。
    private func disableAnimations() {
        let enabled = AnimationPolicy.animationsEnabled()
        let failed = AndroidAnimationSettings.apply(animationsEnabled: enabled) {
            (try? adb(["shell"] + $0))?.status == 0
        }
        guard !failed.isEmpty else { return }
        let action = enabled ? "restore" : "disable"
        let consequence = enabled
            ? "the device keeps running without animations"
            : "while they stay on, screenshots can grab a stale frame even after the quiet check"
        ConsoleOut.err("⚠️ Failed to \(action) the Android animation settings "
            + "(\(failed.joined(separator: ", "))). \(consequence)")
    }

    /// クラッシュ/ANR ダイアログを出さない。**アプリを覆って次のシナリオまで巻き込む**のを防ぐ
    /// (「アプリが繰り返し停止しています」が残ると、同じデバイスに割り当てられた後続シナリオの
    /// タップを全部吸う)。クラッシュ自体は隠れない — プロセスが落ちれば次の操作が
    /// 「アプリが起動していません」で落ちるので、検知は失われない。
    /// A/B 実測(Pixel 9 / Android 15): `am crash` 後の window に
    /// エラーダイアログが 0 のとき 3 行 → 1 のとき 0 行。失敗は非致命
    private func hideErrorDialogs() {
        guard (try? adb(["shell", "settings", "put", "global",
                         "hide_error_dialogs", "1"]))?.status == 0 else {
            ConsoleOut.err("⚠️ Failed to set hide_error_dialogs"
                + " (crash/ANR dialogs may linger and swallow taps in later scenarios)")
            return
        }
    }

    /// IME(Gboard)のスタイラス手書き機能を切る。**目的はプロモ画面の抑止**:
    /// 入力欄にフォーカスすると「タッチペンを試してみる」の教育用シートが**別プロセスの window として**
    /// アプリの上に出ることがあり、送信ボタン等を覆う。ブリッジの a11y ツリーには他プロセスの window が
    /// 出ないため、覆われたまま tap が成功扱いになり「✅ なのに何も起きない」になる
    /// (05_テキスト入力 の間欠失敗として実際に踏んだ。失敗時スクショで確定)。
    /// 失敗は非致命(disableAnimations と同方針)
    private func disableStylusHandwriting() {
        guard (try? adb(["shell", "settings", "put", "secure",
                         "stylus_handwriting_enabled", "0"]))?.status == 0 else {
            ConsoleOut.err("⚠️ Failed to disable stylus_handwriting_enabled"
                + " (the IME stylus hint can cover the app and make taps miss)")
            return
        }
    }

    /// ブリッジの /locale(BridgeRouter.java handleLocale)が使う隠し API 反射の許可。
    /// 未設定だとロケール変更だけが 500 になる。失敗は非致命(disableAnimations と同方針)
    private func allowHiddenAPIReflection() {
        guard (try? adb(["shell", "settings", "put", "global", "hidden_api_policy", "1"]))?.status == 0
        else {
            ConsoleOut.err("⚠️ Failed to set hidden_api_policy (the /locale locale change is unavailable)")
            return
        }
    }

    /// 生存確認+稼働中プロセスの版(旧ブリッジは bridgeVersionCode を返さない → nil)
    private func probeBridge(hostPort: UInt16)
        async -> (client: BridgeClient, version: Int?, timing: Bool)? {
        let probe = BridgeClient(port: hostPort, timeoutSeconds: 2)
        guard let status = try? await probe.status(), status.ready else { return nil }
        // 操作用は通常タイムアウト(snapshot 等は余裕を持つ)
        return (BridgeClient(port: hostPort), status.bridgeVersionCode,
                status.timingEnabled ?? false)
    }

    private func ensureForward() throws -> UInt16 {
        if let existing = findExistingForward() { return existing }
        let created = try adb(["forward", "tcp:0", "tcp:\(Self.bridgeDevicePort)"])
        guard let hostPort = UInt16(created.output.trimmingCharacters(in: .whitespacesAndNewlines)) else {
            throw DriverError.bridgeUnreachable(context: androidContext(), detail: "adb forward failed: \(created.tail)")
        }
        return hostPort
    }

    private func findExistingForward() -> UInt16? {
        guard let list = try? adb(["forward", "--list"]) else { return nil }
        var unscopedMatches: [UInt16] = []
        for line in list.output.split(separator: "\n") {
            // 形式: "<serial> tcp:<hostPort> tcp:<devicePort>"
            let parts = line.split(separator: " ").map(String.init)
            guard parts.count == 3, parts[2] == "tcp:\(Self.bridgeDevicePort)",
                  let hostPort = UInt16(parts[1].dropFirst(4)) else { continue }
            if let serial {
                if parts[0] == serial { return hostPort }
            } else {
                unscopedMatches.append(hostPort)
            }
        }
        // serial 未指定(デフォルトドライバ)は、bridge ポートへの forward が唯一のときだけ再利用する。
        // 複数あると別デバイスの forward を掴み得るため、曖昧回避で nil を返す(呼び出し側が新規 forward)。
        return unscopedMatches.count == 1 ? unscopedMatches[0] : nil
    }

    // MARK: - CLI(bridge down / status / doctor)用

    /// ブリッジ停止 + forward 解放(fleetest bridge down --platform android)
    public func stopBridge() {
        _ = try? adb(["shell", "am", "force-stop", Self.bridgePackage])
        if let list = try? adb(["forward", "--list"]) {
            for line in list.output.split(separator: "\n") {
                let parts = line.split(separator: " ").map(String.init)
                guard parts.count == 3, parts[2] == "tcp:\(Self.bridgeDevicePort)",
                      serial == nil || parts[0] == serial else { continue }
                _ = try? adb(["forward", "--remove", parts[1]])
            }
        }
        Self.setRegistry(bridgeKey, nil)
    }

    /// 生死判定の唯一の信号(`adb shell pidof <bridgePackage>`)。`bridgeDoctorSummary` と
    /// `isBridgeRunning` の両方がこれを通す(判定を2箇所に持たない)。**`ensureBridge()` は
    /// 呼ばない** —— 観測のためだけにブリッジを起動する副作用は入れない
    private static func pidofResult(serial: String?, adbPath: String, timeout: Double? = nil) -> Shell.Result? {
        var args = [adbPath]
        if let serial { args += ["-s", serial] }
        args += ["shell", "pidof", bridgePackage]
        return try? Shell.run(args, timeout: timeout)
    }

    /// `pidof` の出力から**信頼できる pid 文字列**だけを取り出す(純関数)。**status では
    /// adb 自体の失敗と区別できない** —— pidof は「見つからない」でも非ゼロで終わるため、
    /// 非ゼロは「動いていない」と「adb がデバイスに届かない」の両方で起きる。空白区切りの
    /// 数字だけなら pid 列(空 = 動いていない)、それ以外(adb のエラー文言等)は不明で nil
    static func pidofDigitsOnly(_ output: String) -> String? {
        let trimmed = output.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.isEmpty || trimmed.split(separator: " ").allSatisfy({ Int($0) != nil }) else {
            return nil
        }
        return trimmed
    }

    /// `pidofResult` の出力から生死を判定する純関数(テスト用に分離)。
    /// **取得できない(nil)・pid 列として読めない(adb 失敗のエラー文言等)ときは nil を返し、
    /// true/false に丸めない** —— 丸めると「観測できない」と「ブリッジが有る/無い」を混同し、
    /// pidof がたまたま失敗しただけの回に絵が消える、または adb のエラー文言を pid と誤認して
    /// 「動いている」と誤って断定する
    static func bridgeRunningVerdict(_ result: Shell.Result?) -> Bool? {
        guard let result, let digits = pidofDigitsOnly(result.output) else { return nil }
        return !digits.isEmpty
    }

    /// ブリッジを**起動せずに**生死だけを見る(`ensureBridge()` を通さない)。
    /// `api monitor` の毎サイクルから叩かれる想定なので timeout を必ず指定し、adb が刺さっても
    /// サイクルを握らせない
    public static func isBridgeRunning(serial: String?, timeout: Double = 5) -> Bool? {
        guard let adbPath = try? AndroidDriver.findADB() else { return nil }
        return bridgeRunningVerdict(pidofResult(serial: serial, adbPath: adbPath, timeout: timeout))
    }

    /// 端末が `adb shell` に答えるまで待つ上限[秒](doctor / bridge status の問い合わせと、ブリッジの
    /// コールド起動の最初の問い合わせ)。凍結した端末の adbd は答えないので、期限が無いと1台に呼び手全体
    /// (MCP は呼び出しを順に処理する = 他の端末への呼び出しまで)を握られる。値は wedge した adbd に握らせない
    /// 既存の締切(`AndroidHealthProbe.adbTimeoutSeconds`)と同じ。尽きたらその端末の残りの段を撃たない
    static let deviceAnswerTimeoutSeconds: Double = AndroidHealthProbe.adbTimeoutSeconds

    /// `dumpsys package <bridge>` の読み。**読めなかったことを「未導入」に畳まない**
    /// (畳むと、凍結・切断した端末に「初回操作で自動導入される」と言う)
    enum InstalledVersionReading: Equatable {
        case installed(Int)
        case notInstalled
        case unknown
    }

    /// 純粋関数(テストが直接叩く)。`result` が nil = adb が起動できなかった/返らなかった
    static func installedVersionReading(_ result: Shell.Result?) -> InstalledVersionReading {
        guard let result, result.status == 0 else { return .unknown }
        if let range = result.output.range(of: #"versionCode=(\d+)"#, options: .regularExpression),
           let code = Int(result.output[range].dropFirst("versionCode=".count)) {
            return .installed(code)
        }
        return result.output.contains("Unable to find package") ? .notInstalled : .unknown
    }

    /// doctor / bridge status 用の1行サマリ
    public func bridgeDoctorSummary() -> String { bridgeDoctorReport().summary }

    /// `answered` = 端末が期限内に adb へ答えたか。false のとき呼び手は同じ端末への追加の問い合わせ
    /// (`animationScaleWarning` 等)を飛ばす(凍結した端末1台ごとに期限 × 問い合わせ数を払わない)
    public func bridgeDoctorReport() -> (summary: String, answered: Bool) {
        let timeout = Self.deviceAnswerTimeoutSeconds
        let dump: Shell.Result?
        do {
            dump = try adbProbe(["shell", "dumpsys", "package", Self.bridgePackage], timeout: timeout)
        } catch ShellError.timedOut {
            return ("bridge state unknown — the device did not answer adb within \(Int(timeout))s"
                + " (it may be frozen or still booting)", false)
        } catch {
            dump = nil
        }
        let version: Int
        switch Self.installedVersionReading(dump) {
        case .installed(let code):
            version = code
        case .notInstalled:
            return ("bridge not installed (installed automatically on first use)", true)
        case .unknown:
            return ("bridge state unknown (adb could not read the installed package)", true)
        }
        var summary = "bridge v\(version)"
        if version > Self.expectedBridgeVersionCode {
            // 引き下げは自動更新できない(downgradeRefusal が fail fast する)ので「自動で直る」と言わない
            summary += " (newer than this build expects, v\(Self.expectedBridgeVersionCode);"
                + " cannot auto-downgrade — update this machine or `adb uninstall \(Self.bridgePackage)`)"
        } else if version != Self.expectedBridgeVersionCode {
            summary += " (update required → v\(Self.expectedBridgeVersionCode); updated automatically on next use)"
        }
        // pidofDigitsOnly を通す(adb 自体の失敗の出力を pid と誤認して「動いている」と
        // 言わない・逆に「停止」とも言い切らない。bridgeRunningVerdict と同じ判定)
        switch Self.pidofResult(serial: serial, adbPath: adbPath, timeout: timeout)
            .map(\.output).flatMap(Self.pidofDigitsOnly) {
        case .some(let pid) where !pid.isEmpty:
            summary += " running (pid \(pid)"
                + (findExistingForward().map { ", forward tcp:\($0)" } ?? "") + ")"
        case .some:
            summary += " stopped (started automatically on first use)"
        case .none:
            summary += " status unknown (adb did not answer pidof as expected)"
        }
        return (summary, true)
    }

    /// doctor 用: window/transition/animator の *_scale のいずれかが 0 でなければ注意文言を返す(全て0ならnil)。
    /// 未設定(get が "null" を返す)は Android の既定値である 1.0 相当として扱い、警告対象に含める。
    /// **読めなかった key(adb 失敗・期限切れ)は「ON」と言わず、読めなかったと別に言う**
    /// (黙って諦めない。未設定と取り違えて「ON」と断定もしない)
    public func animationScaleWarning() -> String? {
        Self.animationScaleWarning(readings: AnimationPolicy.androidScaleKeys.map { key in
            guard let read = try? adbProbe(["shell"] + AndroidAnimationSettings.getArguments(key: key),
                                           timeout: Self.deviceAnswerTimeoutSeconds),
                  read.status == 0 else { return (key, nil) }
            return (key, read.output)
        })
    }

    /// 純粋関数(テストが直接叩く)。`value` が nil = その key は読めなかった
    static func animationScaleWarning(readings: [(key: String, value: String?)]) -> String? {
        let nonZero = readings.filter { reading in
            reading.value.map { !AndroidAnimationSettings.matches(rawValue: $0, animationsEnabled: false) } ?? false
        }.map(\.key)
        let unread = readings.filter { $0.value == nil }.map(\.key)
        var parts: [String] = []
        if !nonZero.isEmpty {
            // doctor は実行プロファイルを知らないので断定しない(enableAnimations:true なら意図どおり)
            parts.append("animation settings are on (\(nonZero.joined(separator: ", "))). "
                + "Screenshots can grab a stale frame even after the quiet check. "
                + "Unless the run profile sets enableAnimations, the next run turns them off automatically")
        }
        if !unread.isEmpty {
            // run の apply は読めない key も put する(AndroidAnimationSettings.matches)
            parts.append("could not read the animation settings (\(unread.joined(separator: ", "))) —"
                + " adb did not answer `settings get`; the next run sets them anyway")
        }
        return parts.isEmpty ? nil : parts.joined(separator: " / ")
    }

    /// installed が expected より新しいときだけ拒否理由を返す(等しい/古い/未インストールは
    /// nil = 通常の自動更新経路を塞がない)。Android は versionCode の引き下げインストールを
    /// 拒否するため、adb install を試みる前に fail fast させる(docs/remote-runner.md §18.5)
    static func downgradeRefusal(installed: Int?, expected: Int, serial: String? = nil) -> String? {
        guard let installed, installed > expected else { return nil }
        let uninstall = serial.map { "adb -s \($0) uninstall \(Self.bridgePackage)" }
            ?? "adb uninstall \(Self.bridgePackage)"
        return "the device has bridge v\(installed) installed, but this build expects v\(expected). "
            + "Android refuses to install a lower versionCode, so this cannot auto-update. "
            + "This means a newer fleetest has already used this device. Fix it by either "
            + "(1) updating this machine's fleetest (`git pull` + rebuild, or Scripts/update.sh), or "
            + "(2) removing the newer bridge from the device (`\(uninstall)`)."
    }

    func installBridgeIfNeeded() throws {
        let installed = installedBridgeVersionCode()
        // **版が合っていても code path の実在まで見る** —— `pm list packages -u` と
        // `dumpsys package` にはレコードが残るのに `pm path` が空、という中途半端な install が
        // あり、この形だと `am instrument` が黙って失敗して「cannot connect」がレーン復帰でも
        // 直らない(受け手報告: 4 run 連続。`pm uninstall` → 再インストールで回復)。
        // 壊れたレコードは `install -r` を弾きうるので、先に剥がしてから通常の導入経路へ落とす
        if installed != nil, bridgeCodePathPresent() == false {
            logStderr("⚠️ the bridge package record is present but has no code path"
                      + " (pm path is empty) — removing the broken install and reinstalling")
            _ = try? adb(["uninstall", Self.bridgePackage])
        } else if installed == Self.expectedBridgeVersionCode {
            return
        }
        if let refusal = Self.downgradeRefusal(installed: installed,
                                                expected: Self.expectedBridgeVersionCode,
                                                serial: serial) {
            throw DriverError.badResponse(status: 0, body: refusal)
        }
        let apk = try Self.locateBridgeAPK()
        var result = try adb(["install", "-r", apk.path])
        if result.output.contains("INSTALL_FAILED_UPDATE_INCOMPATIBLE") {
            // 別マシンの debug keystore で署名された旧 APK が居る場合
            _ = try? adb(["uninstall", Self.bridgePackage])
            result = try adb(["install", apk.path])
        }
        guard result.output.contains("Success") else {
            // チェックとインストールの間に別ホストが新版を入れたレース。読み直せなければ通常のメッセージ
            if result.output.contains("INSTALL_FAILED_VERSION_DOWNGRADE"),
               let refusal = Self.downgradeRefusal(installed: installedBridgeVersionCode(),
                                                    expected: Self.expectedBridgeVersionCode,
                                                    serial: serial) {
                throw DriverError.badResponse(status: Int(result.status), body: refusal)
            }
            // probe と install の間に system_server が落ちたレース(まれ)。同じ印なら
            // 30行のスタックトレースでなく理由を名指しする
            if let marker = AndroidGuestReadiness.systemServerStartingMarker(in: result.output) {
                throw DriverError.bridgeUnreachable(
                    context: androidContext(),
                    detail: AndroidGuestReadiness.stillStartingMessage(marker: marker, serial: serial ?? "?"))
            }
            throw DriverError.badResponse(status: Int(result.status),
                body: "failed to install the bridge APK: \(result.tail)")
        }
    }

    /// ブリッジ APK の code path が実在するか。**判定できないときは nil**
    /// (adb 不調で「壊れている」と断じない = 健全な端末を剥がして入れ直さない)。
    /// `pm path` は未インストールでも非0で終わるため、**終端マーカーを必ず出す形**で撃ち、
    /// マーカーが返ったときだけ判定を下す(非0 = adb 不調、と読み違えない)
    func bridgeCodePathPresent() -> Bool? {
        guard let result = try? adb(
            ["shell", "pm path \(Self.bridgePackage) 2>/dev/null; echo \(Self.pmPathMarker)"])
        else { return nil }
        return Self.codePathVerdict(output: result.output, status: result.status)
    }

    static let pmPathMarker = "FT_PM_PATH_DONE"

    /// ブリッジを常駐させる端末側の1行(純粋)。**サンドボックスの `AdbPolicy.instrumentPattern` と同じ形**
    /// (`AdbPolicyBuilderSyncTests`)。
    /// - owner: 起動元の自己申告(/status の ownerRepo。doctor の診断用)。端末の sh へシングルクォートで渡すので、
    ///   `'` や改行を含むパスは付けない(付けるとクォートが壊れ、枠の中では AdbPolicy にも断られる)
    /// - timing: ブリッジ内の所要内訳ログ(iOS 側の FT_BRIDGE_TIMING と同じスイッチ)
    /// - am instrument の stdout/stderr は端末側の一時ファイルへ逃がし、起動失敗のときだけホストへ読む
    ///   (健全なブリッジは何も出力しないので溜まらない)
    static func instrumentCommand(ttl: Int, ownerPath: String?, timing: Bool) -> String {
        let owner = ownerPath.flatMap { $0.contains("'") || $0.contains("\n") ? nil : " -e owner '\($0)'" } ?? ""
        return "am instrument -w -e port \(bridgeDevicePort) -e ttl \(ttl)\(owner)\(timing ? " -e timing 1" : "") "
            + "\(bridgeComponent) </dev/null >\(instrumentDeviceLogPath) 2>&1 &"
    }

    /// pm path 出力 → 実在/欠落/判定不能。純粋関数(BridgeCodePathVerdictTests)
    static func codePathVerdict(output: String, status: Int32) -> Bool? {
        guard status == 0, output.contains(pmPathMarker) else { return nil }
        return output.split(separator: "\n")
            .contains { $0.trimmingCharacters(in: .whitespaces).hasPrefix("package:") }
    }

    private func logStderr(_ message: String) {
        ConsoleOut.err("\(serial.map { "\($0): " } ?? "")\(message)")
    }

    public func installedBridgeVersionCode() -> Int? {
        guard let dump = try? adb(["shell", "dumpsys", "package", Self.bridgePackage]),
              let range = dump.output.range(of: #"versionCode=(\d+)"#, options: .regularExpression)
        else { return nil }
        return Int(dump.output[range].dropFirst("versionCode=".count))
    }

    /// 探索順: 環境変数 → リポジトリの prebuilt → ~/.fleetest キャッシュ
    public static func locateBridgeAPK() throws -> URL {
        let fm = FileManager.default
        if let env = ProcessInfo.processInfo.environment["FT_ANDROID_BRIDGE_APK"],
           fm.isReadableFile(atPath: env) {
            return URL(fileURLWithPath: env)
        }
        let cache = fm.homeDirectoryForCurrentUser.appendingPathComponent(".fleetest/ftbridge.apk")
        if let root = try? RepoRoot.find() {
            let repoAPK = root.appendingPathComponent("AndroidRunner/prebuilt/ftbridge.apk")
            if fm.isReadableFile(atPath: repoAPK.path) {
                // リポジトリ外 cwd からの将来の起動用にキャッシュしておく
                try? fm.createDirectory(at: cache.deletingLastPathComponent(),
                                        withIntermediateDirectories: true)
                try? fm.removeItem(at: cache)
                try? fm.copyItem(at: repoAPK, to: cache)
                return repoAPK
            }
        }
        if fm.isReadableFile(atPath: cache.path) {
            return cache
        }
        // static(serial 不明・実機/エミュレータどちらもあり得る)。android の文言は
        // physicalDevice で分岐しないのでここでは無害
        throw DriverError.bridgeUnreachable(
            context: DriverErrorContext(engine: .android, physicalDevice: false),
            detail: """
            the bridge APK (ftbridge.apk) was not found.
            Use the repository's AndroidRunner/prebuilt/ftbridge.apk, or set
            FT_ANDROID_BRIDGE_APK=<path to the APK> (rebuild it with AndroidRunner/build.sh)
            """)
    }
}

/// Android ブリッジが応答しないが、そのデバイスを他のセッション(run・MCP)が使っているので作り直さなかった。
/// **DriverError にしない** —— bridgeUnreachable にすると到達不能の決まり文句(「`fleetest bridge up` を試せ」)が付くが、
/// その bridge up も同じ門で断られる。文言は完成文(`errorDescription` をそのまま出す)
public struct AndroidBridgeHeldByAnotherSession: Error, LocalizedError {
    public let serial: String
    public var errorDescription: String? {
        "the Android bridge on \(serial) is not answering, and it was not restarted: another session"
            + " (a fleetest run or an MCP session) is using this device, and restarting it would take that"
            + " session's bridge down. Wait for that session to finish, or drive another device"
    }
}
