// XCUITestランナー内蔵HTTPサーバへのクライアント。AppDriver の iOS 実装。

import Foundation
import FTCore

public final class BridgeClient: AppDriver {
    let baseURL: URL
    let session: URLSession
    /// per-endpoint の壁時計上限(秒)。既定は Timeout.interaction/session。
    /// テスト seam(下の internal init)経由でのみ短縮注入できる
    let interactionTimeout: TimeInterval
    let sessionTimeout: TimeInterval
    /// 高速入力(quiescence スキップ)。init 時に FT_FAST_INPUT 環境変数から確定
    let fastInput: Bool
    /// 実機の UDID(nil = シミュレータ)。install の simctl / devicectl 分岐にのみ使う
    let physicalUDID: String?
    /// 既知のシミュレータ UDID(ワーカー構築時に分かっている場合だけ入る。nil = ブリッジに聞く)。
    /// **これが無いと removeApp() の直後に installApp() できない** —— 対象の特定が `status()` に
    /// 依存するため、アプリごと in-app ブリッジを消した後は「入れる先を教えてくれる相手」が
    /// 居なくなる(2026-08-19 の受け手報告)
    let simulatorUDID: String?
    /// リクエストに載せる値(未使用時はキーごと省略 → 旧ランナーと byte 互換)。
    ///
    /// **探索のスワイプだけ quiescence を飛ばす案は不採用**(2026-08-04 実測)。
    /// 1スワイプは 2,546→926ms まで縮み S0090 は −10% になったが、**探索直後のタップが飲まれる**
    /// (`tap("#row_30")` 後に `selected=-`)。E2E-iOS の S0080/S0060 が 2/2 で落ちた ——
    /// あの空打ちドラッグ+`settleAfterScroll` は「XCTest の quiescence が慣性を吸った後」を
    /// 前提にしている。CMP のスクロール系は同一セッション A/B で改善ゼロだったので、
    /// 得られるものも小さい。**再提案しない**(docs/performance-tuning.md §8)
    private var fastFlag: Bool? { fastInput ? true : nil }

    /// tap(ref:) が受け取った OKResponse.note(AppDriver.lastActionNote 参照)。
    /// tap(ref:) 呼び出しの冒頭で必ずクリアする(残ると別ステップに誤って付く)。
    public private(set) var lastActionNote: String?

    /// **前提: この接続先は XCUITest ランナー**(BridgeRouter.handleType が読み返し済み)。
    /// **InAppDriver は同じ HTTP プロトコルを in-app ブリッジへ話すのに使うため、この既定 true を
    /// そのまま転送しない**(InAppDriver.verifiesTypedText は固定 false で上書きする)
    public var verifiesTypedText: Bool { true }

    /// per-endpoint の壁時計上限(秒)の既定値。init の 120 は未指定エンドポイントのフォールバック。
    /// URLRequest.timeoutInterval で config の既定を1リクエスト単位に上書きする
    enum Timeout {
        static let interaction: TimeInterval = 20  // tap/swipe/type/press/drag
        // snapshot は a11y ツリー直列化で並列飽和時に伸びるため session 側に置く(誤爆回避)
        static let session: TimeInterval = 45      // launch/activate/screenshot/status/terminate/snapshot/appswitcher/home
    }

    /// timeoutSeconds: 既定 120 秒(launch や snapshot は数秒かかることがある)。
    /// ポート範囲のスキャン(生存確認)には短い値を渡す。
    /// per-endpoint 既定(interaction/session)は URLRequest.timeoutInterval として config 側を
    /// 上書きするため、timeoutSeconds でクランプしないと短い指定が無効化される(実害:
    /// scanBridgeStatuses の 1s が status() の 45s に化け、suspend ゾンビ存在時に
    /// monitor/list-devices のスキャンが毎回 45s 待った。2026-07-25)
    public convenience init(port: UInt16 = BridgeAPI.defaultPort, timeoutSeconds: TimeInterval = 120,
                            host: String = BridgeEndpoint.loopbackHost,
                            physicalUDID: String? = nil,
                            simulatorUDID: String? = nil) {
        self.init(port: port, timeoutSeconds: timeoutSeconds,
                  interactionTimeout: min(Timeout.interaction, timeoutSeconds),
                  sessionTimeout: min(Timeout.session, timeoutSeconds),
                  host: host, physicalUDID: physicalUDID, simulatorUDID: simulatorUDID)
    }

    /// テスト専用 seam: interaction/session の予算を短縮注入する(未応答ブリッジのタイムアウト
    /// 検証等)。公開 init(port:timeoutSeconds:) はこれを既定予算付きで呼ぶだけで公開 API は不変。
    /// host はシミュレータ(ホストとネットワークスタックを共有)では常に 127.0.0.1。
    /// iOS 実機だけ LAN IP を渡す(BridgeEndpoint 参照)
    init(port: UInt16, timeoutSeconds: TimeInterval = 120,
        interactionTimeout: TimeInterval, sessionTimeout: TimeInterval,
        host: String = BridgeEndpoint.loopbackHost,
        physicalUDID: String? = nil,
        simulatorUDID: String? = nil) {
        self.baseURL = URL(string: "http://\(host):\(port)")!
        self.physicalUDID = physicalUDID
        self.simulatorUDID = simulatorUDID
        // 高速入力(quiescence スキップ)はプロセス単位の環境変数で有効化する
        // (実行プロファイル iosFastInput / CLI --fast-input が FT_FAST_INPUT=1 を注入。
        //  BridgeClient は hybrid のフォールバック経路でも生成されるため init 引数ではなく env で統一)
        self.fastInput = ProcessInfo.processInfo.environment["FT_FAST_INPUT"] == "1"
        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = timeoutSeconds
        self.session = URLSession(configuration: config)
        self.interactionTimeout = interactionTimeout
        self.sessionTimeout = sessionTimeout
    }

    // MARK: - AppDriver

    public func status() async throws -> StatusResponse {
        try await get("/status", timeout: sessionTimeout)
    }

    /// 短いタイムアウトでの /status プローブ。バックグラウンドで iOS に suspend された in-app
    /// アプリは TCP 接続は受理するが応答しないため、既定 sessionTimeout(45s)では無限待ちになる。
    /// 呼び出し側は無応答を「不明」として扱う(engine=inapp/hybrid の注入先判定を参照)。
    /// 確実に短時間で切るため config 側も短くした BridgeClient から呼ぶこと。
    public func status(timeout: TimeInterval) async throws -> StatusResponse {
        try await get("/status", timeout: timeout)
    }

    /// アプリを残してデータだけ消す。**シミュレータ専用**(実機は同等の手段が devicectl に無い)。
    /// `simctl get_app_container … data` が指すコンテナの**中身**を消す(コンテナ自体は残す —
    /// ディレクトリごと消すと次回起動でアプリが作り直せず落ちる)。
    /// **uninstall + install は使わない**: in-app エンジンでは dylib 注入ごと消え、
    /// 再インストールに appPath が要る(DSL からは持っていない)
    public func clearAppData(bundleID: String) async throws {
        // **デバイス名は終了より先に採る**: 終了するとブリッジが応答しなくなる経路がある
        // (in-app ブリッジは対象アプリのプロセス内に住む)
        let device = try await simulatorTarget()
        // 起動中に消すとプロセスが保持している状態が書き戻る
        try? await terminate()
        try clearAppDataOnSimulator(bundleID: bundleID, target: device)
    }

    /// 権限(TCC)を未許可へ戻す。**データコンテナの外(デバイスの TCC.db)にあるので
    /// コンテナを消しても権限は残る** — これをやらないと「Android では権限ダイアログが出るのに
    /// iOS では出ない」という OS 差が黙って生まれる(Android の `pm clear` は権限もリセットする)
    public func resetPrivacyOnSimulator(bundleID: String, target: String) throws {
        let result = try Shell.run(
            ["xcrun", "simctl", "privacy", target, "reset", "all", bundleID])
        guard result.status == 0 else {
            throw DriverError.badResponse(status: Int(result.status),
                body: "simctl privacy reset failed (app data was cleared but permissions remain,"
                    + " so permission dialogs will not reappear): \(result.tail)")
        }
    }

    /// /status のデバイス名が指す相手。**名前をそのまま simctl へ渡さない**ための解決。
    /// 渡してしまうと、実機に繋がっているときは「Invalid device」という的外れな失敗になり、
    /// **同名のシミュレータが起動していればそちらを操作してしまう**
    enum ResolvedTarget: Equatable {
        case simulator(udid: String)
        case physical(udid: String)
        /// カタログ自体が引けない(別種の故障)。従来どおり名前を simctl へ渡す
        case unknown(name: String)
    }

    /// **install / uninstall / clearAppData の対象特定はここに一本化する**(3箇所が
    /// 同じ「名前で引いて、見つからなければ名前のまま」を持っていた)。
    /// **実機一覧は遅延評価**: `SimulatorCatalog.devices()` はシミュレータしか返さないので
    /// 実機は devicectl 側を引く必要があるが、毎回引くと数百 ms 乗る。シミュレータに
    /// 同名が居ない = 実機の可能性がある、というときだけ引く
    static func resolveTarget(named device: String, simulators: [SimDeviceInfo]?,
                              physicalDevices: () -> [IOSPhysicalDeviceInfo]?) -> ResolvedTarget {
        guard let simulators else { return .unknown(name: device) }
        if let simulator = simulators.first(where: { $0.booted && !$0.physical && $0.name == device }) {
            return .simulator(udid: simulator.udid)
        }
        if let phone = physicalDevices()?.first(where: { $0.name == device }) {
            return .physical(udid: phone.deviceCtlIdentifier)
        }
        return .unknown(name: device)
    }

    /// **ブリッジに聞かずに決まる対象**(呼び出し側が UDID を知っている場合)。nil = 聞くしかない。
    /// install/uninstall/clearAppData の対象特定が `status()` に依存していると、
    /// `removeApp()` でアプリごと in-app ブリッジを消した直後の `installApp()` が
    /// 「接続拒否」で落ちる。親(ワーカー)は UDID を知っているので、ここで使い切る
    static func knownTarget(physicalUDID: String?, simulatorUDID: String?) -> ResolvedTarget? {
        if let physicalUDID { return .physical(udid: physicalUDID) }
        if let simulatorUDID { return .simulator(udid: simulatorUDID) }
        return nil
    }

    /// 実行時の既定の引き当て(実機一覧は必要になったときだけ devicectl を叩く)
    static func resolveTarget(named device: String) -> ResolvedTarget {
        resolveTarget(named: device, simulators: try? SimulatorCatalog.devices(),
                      physicalDevices: { try? IOSPhysicalDeviceCatalog.devices() })
    }

    /// simctl 系の対象特定。**実機は 501**(devicectl に同等手段が無い)
    func simctlTarget(_ operation: String) async throws -> String {
        // 既知の UDID があればブリッジに聞かない(knownTarget の宣言)
        let resolved: ResolvedTarget
        if let known = Self.knownTarget(physicalUDID: physicalUDID, simulatorUDID: simulatorUDID) {
            resolved = known
        } else {
            resolved = Self.resolveTarget(named: try await status().device)
        }
        switch resolved {
        case .simulator(let udid): return udid
        case .physical:
            throw DriverError.badResponse(status: 501,
                body: "\(operation) is simulator-only on iOS (devicectl has no equivalent;"
                    + " reinstall the app instead)")
        case .unknown(let name): return name
        }
    }

    /// clearAppData の対象シミュレータ(UDID 優先)。実機は同等手段が devicectl に無いので 501
    public func simulatorTarget() async throws -> String {
        guard physicalUDID == nil else {
            throw DriverError.badResponse(status: 501,
                body: "clearAppData is simulator-only on iOS (devicectl has no equivalent;"
                    + " reinstall the app instead)")
        }
        return try await simctlTarget("clearAppData")
    }

    /// install / uninstall の対象。**実機は UDID を渡して devicectl** へ回す
    /// (profile 経由なら physicalUDID が来るが、MCP のポート直指定では来ないので
    /// カタログからも引く。引けなければ simctl の対象として扱う)
    func installTarget() async throws -> ResolvedTarget {
        if let known = Self.knownTarget(physicalUDID: physicalUDID, simulatorUDID: simulatorUDID) {
            return known
        }
        let current = try await status()
        return Self.resolveTarget(named: current.device)
    }

    /// データコンテナの**中身**を消す(コンテナ自体は残す)。対象の特定と終了は呼び出し側の責務
    /// (in-app は終了するとブリッジが死ぬため、順序を呼び出し側で決める必要がある)
    public func clearAppDataOnSimulator(bundleID: String, target: String) throws {
        let container = try Shell.run(
            ["xcrun", "simctl", "get_app_container", target, bundleID, "data"])
        guard container.status == 0 else {
            throw DriverError.badResponse(status: Int(container.status),
                body: "simctl get_app_container failed (is \(bundleID) installed?): \(container.tail)")
        }
        let path = container.output.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !path.isEmpty, path.hasPrefix("/") else {
            throw DriverError.badResponse(status: 500,
                body: "could not resolve the data container for \(bundleID)")
        }
        let fm = FileManager.default
        let entries = (try? fm.contentsOfDirectory(atPath: path)) ?? []
        var failed: [String] = []
        for entry in entries {
            do { try fm.removeItem(atPath: path + "/" + entry) } catch { failed.append(entry) }
        }
        // **黙って緑にしない**: 一部でも残ったら「消えた」と言えない
        guard failed.isEmpty else {
            throw DriverError.badResponse(status: 500,
                body: "could not delete \(failed.count) item(s) in the data container of"
                    + " \(bundleID): \(failed.prefix(5).joined(separator: ", "))")
        }
        // **ファイルを消しただけでは NSUserDefaults が戻ってくる**(2026-08-05 に実測で確定):
        // cfprefsd がドメインをメモリに抱えており、次の起動で消したはずの値を配って plist を
        // 書き直す。対照実験(消して起動を3回)で launch_count が 2→3→4 と増え続けた =
        // 消去が一度も効いていなかった。デーモンを入れ直すとキャッシュが落ちる(3/3 で初期化)。
        // **順序は「ファイルを消してから再起動」**(先に再起動するとディスクの旧値を読み直す)。
        // `defaults delete` は効かない(サンドボックス化されたドメインが見えず domain not found)、
        // `killall` はシミュレータに存在しない
        let prefsDaemon = try Shell.run(
            ["xcrun", "simctl", "spawn", target,
             "launchctl", "kickstart", "-k", "system/com.apple.cfprefsd.xpc.daemon"])
        guard prefsDaemon.status == 0 else {
            throw DriverError.badResponse(status: Int(prefsDaemon.status),
                body: "could not restart cfprefsd after clearing the data of \(bundleID)"
                    + " — UserDefaults values would survive the clear: \(prefsDaemon.tail)")
        }
        // 権限はコンテナの外にあるので別途戻す(resetPrivacyOnSimulator 参照)
        try resetPrivacyOnSimulator(bundleID: bundleID, target: target)
    }

    /// install は HTTP エンドポイントを持たず simctl / devicectl の役割。
    /// 実機(physicalUDID 指定時)は `devicectl device install app`、シミュレータは従来どおり simctl。
    /// シミュレータの対象特定は /status のデバイス名から行う。同名デバイス(Shutdown の複製等)が
    /// あると名前指定 simctl は失敗するため、Booted かつ同名の UDID に解決してから実行する
    /// (解決不能時は名前のまま試す)。
    public func install(packagePath: String) async throws {
        if case .physical(let udid) = try await installTarget() {
            let result = try Shell.run(
                ["xcrun", "devicectl", "device", "install", "app",
                 "--device", udid, packagePath], timeout: 600)
            guard result.status == 0 else {
                throw DriverError.badResponse(status: Int(result.status),
                    body: "devicectl device install app failed"
                        + " (check that the .app/.ipa is signed and the device is connected): \(result.tail)")
            }
            return
        }
        let target = try await simctlTarget("install")
        let result = try Shell.run(["xcrun", "simctl", "install", target, packagePath])
        guard result.status == 0 else {
            throw DriverError.badResponse(status: Int(result.status),
                body: "simctl install failed: \(result.tail)")
        }
    }

    /// uninstall は install と対で HTTP エンドポイントを持たず simctl / devicectl の役割。
    /// 対象特定は install と同じ規則(実機は UDID 直・シミュレータは /status のデバイス名から解決)
    public func uninstall(bundleID: String) async throws {
        if case .physical(let udid) = try await installTarget() {
            let result = try Shell.run(
                ["xcrun", "devicectl", "device", "uninstall", "app",
                 "--device", udid, bundleID], timeout: 600)
            guard result.status == 0 else {
                throw DriverError.badResponse(status: Int(result.status),
                    body: "devicectl device uninstall app failed: \(result.tail)")
            }
            return
        }
        let target = try await simctlTarget("uninstall")
        let result = try Shell.run(["xcrun", "simctl", "uninstall", target, bundleID])
        guard result.status == 0 else {
            throw DriverError.badResponse(status: Int(result.status),
                body: "simctl uninstall failed: \(result.tail)")
        }
    }

    /// URL(ディープリンク)を配送する。**アプリは再起動しない**(warm 配送。terminate は撃たない)。
    /// 宛先解決は install/uninstall と同じ `installTarget()`(実機は devicectl、シミュレータは
    /// simctl)。`simulatorTarget()` は clearAppData 専用に「実機は非対応」で 501 を返す作りなので、
    /// 実機の devicectl 経路が要るここには使えない。bundleID は Android 向けの引数だが、
    /// iOS シミュレータでも初回確認アラートの自動了承(下記)の対象アプリ特定に使う
    /// (実機の devicectl 経路・bundleID なしの呼び出しでは同意ステップを行わない)
    public func openURL(_ url: String, bundleID: String?) async throws {
        if case .physical(let udid) = try await installTarget() {
            let result = try Shell.run(
                ["xcrun", "devicectl", "device", "process", "openURL", "--device", udid, url])
            guard result.status == 0 else {
                throw DriverError.badResponse(status: Int(result.status),
                    body: "devicectl device process openURL failed: \(result.tail)")
            }
            return
        }
        let target = try await simctlTarget("openURL")
        let result = try Shell.run(["xcrun", "simctl", "openurl", target, url])
        guard result.status == 0 else {
            throw DriverError.badResponse(status: Int(result.status),
                body: "simctl openurl failed: \(result.tail)")
        }
        if let bundleID {
            await acknowledgeOpenURLConsent(bundleID: bundleID, target: target)
        }
    }

    /// **未同意の初回だけ** SpringBoard が出す「"<表示名>"で開きますか?」を自動了承する
    /// (AppDriver.acknowledgeOpenURLConsentIfPresent の実装本体。ベストエフォート、失敗は無視する)。
    ///
    /// 実測(iOS 27 シミュレータ): 同意は端末+アプリの組で永続する ——
    /// 一度「開く」を押すと以後の openURL は無警告で配送される。そのため
    /// **(target, bundleID) ごとにプロセス内で1回だけ**試みる(OpenURLConsentAttemptCache)。
    /// 判定は springboard へ実際に attach できてから初めて「試行済み」にする ——
    /// **先に記録すると in-app 接続の 409 が「試したことにされ」、hybrid で本来なら XCUITest 側
    /// (springboard を見られる)がまだ試していないのに機会を失う**(このメソッドは in-app/xcuitest
    /// どちらの接続からも呼ばれ得る。WebViewDelegatingDriver.openURL 参照)。
    /// 確認アラートの出現待ち(合計約 1.2s)。**同意済みの端末では毎回この分を空振りする**ので、
    /// 伸ばすと初回 openURL の固定費がそのまま増える
    private var consentAlertPollAttempts: Int { 4 }
    private var consentAlertPollIntervalNanos: UInt64 { 400_000_000 }

    func acknowledgeOpenURLConsent(bundleID: String, target: String) async {
        let key = "\(target)#\(bundleID)"
        guard !OpenURLConsentAttemptCache.shared.hasAttempted(key) else { return }
        guard let displayName = Self.appDisplayName(bundleID: bundleID, target: target) else { return }
        do {
            // springboard 参照(SystemUIDriver と同じ非破壊な /session 切り替え)。
            // in-app 接続は自分の bundle 以外の /session を 409 で拒否するため、
            // ここで throw して抜ける = 「この接続では見られない」= 未記録のまま次に委ねる
            try await launch(bundleID: "com.apple.springboard")
        } catch {
            return
        }
        // ここまで来た = springboard を見られる接続だと分かった。以後はこの接続でなくても試さない。
        // **記録はアラートを探し終えてから**(先に記録して1回だけ撮ると、まだ描画されていない
        // アラートを「無かった」と確定してしまい、以後この組では二度と試さない = モーダルが
        // 立ったまま残り、しかもアプリスコープの木には出ないので run の残り全部が黙って失敗する)
        defer { OpenURLConsentAttemptCache.shared.markAttempted(key) }
        // 出るとしても配送直後の一瞬なので短く数回だけ待つ(既に同意済みなら毎回ここを空振りする。
        // 待ち過ぎるとその分だけ全 run の初回 openURL が遅くなる)
        for attempt in 0..<consentAlertPollAttempts {
            if attempt > 0 { try? await Task.sleep(nanoseconds: consentAlertPollIntervalNanos) }
            guard let tree = try? await snapshot() else { continue }
            guard let ref = OpenURLConsent.confirmButtonRef(in: tree, appDisplayName: displayName)
            else { continue }
            try? await tap(ref: ref)   // 押せなくても致命的ではない(同意されないだけ)
            break
        }
        // 対象アプリへ戻す(このステップが springboard へ張り替えたセッションを元に戻す)
        try? await activate(bundleID: bundleID)
    }

    /// AppDriver 要件。外部(WebViewDelegatingDriver/AppAttachDriver)から呼ばれたときは
    /// target をまだ持たないため、まず /status から解決する
    public func acknowledgeOpenURLConsentIfPresent(bundleID: String) async {
        guard physicalUDID == nil, let target = try? await simctlTarget("openURL") else { return }
        await acknowledgeOpenURLConsent(bundleID: bundleID, target: target)
    }

    /// bundleID → 表示名(CFBundleDisplayName、無ければ CFBundleName)。アラート同定に使う
    /// (ラベル文字列は端末ロケールで変わるため使えない)。取れなければ nil(呼び出し側は同意
    /// ステップごと諦める)。`ftester api list-apps`(Sources/ftester/ApiListAppsCommand.swift)と
    /// 同じ simctl listapps 経由だが、Sources/ftester からは呼べないためここに最小限だけ複製する
    static func appDisplayName(bundleID: String, target: String) -> String? {
        guard let result = try? Shell.run(["xcrun", "simctl", "listapps", target]), result.status == 0,
              let data = result.output.data(using: .utf8),
              let raw = try? PropertyListSerialization.propertyList(from: data, options: [], format: nil),
              let apps = raw as? [String: [String: Any]],
              let info = apps[bundleID] else { return nil }
        return (info["CFBundleDisplayName"] as? String) ?? (info["CFBundleName"] as? String)
    }

    /// フォアグラウンドのアプリが bundleID と一致するか(POST /appstate。両ブリッジ HTTP 互換)
    public func isAppForeground(bundleID: String) async throws -> Bool {
        let res: AppStateResponse = try await post("/appstate", body: AppStateRequest(bundleID: bundleID),
                                                    timeout: sessionTimeout)
        return res.foreground
    }

    /// SpringBoard のアラートが載っているか(`GET /systemalert`。XCUITest ランナーのみ)。
    /// **旧ランナーは 404 を返す** → nil(不明)で返し、呼び手は判定しない
    public func systemAlert() async throws -> SystemAlertProbeResponse? {
        do {
            return try await get("/systemalert", timeout: sessionTimeout) as SystemAlertProbeResponse
        } catch DriverError.badResponse(let status, _) where status == 404 {
            return nil
        }
    }

    /// SpringBoard の木を**セッションを触らずに**撮る(`GET /systemui/snapshot`)。
    /// ref は `systemUITap(ref:)` 専用の別名前空間(ランナー側 `systemRefFrames`)。
    ///
    /// 旧ランナー(版 < 79)は 404 —— 呼び手(`SystemUIDriver`)が
    /// `POST /session springboard` + `GET /snapshot` の旧経路へ落ちる
    public func systemUISnapshot() async throws -> SnapshotResponse? {
        let limit = pendingElementLimit
        pendingElementLimit = nil
        let query = limit.map { "max=\(BridgeAPI.resolvedSnapshotElementLimit($0))" }
        do {
            return try await get("/systemui/snapshot", query: query,
                                 timeout: sessionTimeout) as SnapshotResponse
        } catch DriverError.badResponse(let status, _) where status == 404 {
            pendingElementLimit = limit
            return nil
        }
    }

    /// `systemUISnapshot()` が振った ref を叩く(`POST /systemui/tap`)。
    ///
    /// **404 を握り潰さない**。この口を撃つのは `systemUISnapshot()` が
    /// 成功した後だけ = ルートは在ると分かっているので、ここの 404 は
    /// **「その ref を知らない」**しか意味しない(ランナーの `handleSystemUITap`)。
    /// 一度は「旧ランナー」の合図として false を返し、呼び手が同じ番号を `/tap` へ撃ち直して
    /// いた —— **両方の名前空間が 1 から採番される**ので、番号はアプリ側の `refFrames` で
    /// 引き当たり、SpringBoard を叩いたつもりで**無関係なアプリの要素を黙ってタップ**していた
    public func systemUITap(ref: Int) async throws {
        let _: OKResponse = try await post("/systemui/tap", body: TapRequest(ref: ref),
                                           timeout: interactionTimeout)
    }

    /// `/drag` の SpringBoard 版(`POST /systemui/drag`)。**セッションのアプリを原点にしない**
    /// ので、対象アプリが背面・未起動でも撃てる(tapAppIcon のページ送り。ランナー側
    /// `systemUIAnchor` の doc に理由がある)
    public func systemUIDrag(fromX: Double, fromY: Double, toX: Double, toY: Double,
                             pressSeconds: Double, durationSeconds: Double) async throws {
        let _: OKResponse = try await post("/systemui/drag", body: DragRequest(
            fromX: fromX, fromY: fromY, toX: toX, toY: toY,
            press: pressSeconds, duration: durationSeconds),
            timeout: interactionTimeout)
    }

    /// `/swipe` の SpringBoard 版(`POST /systemui/swipe`)。向きだけ = 呼び手は
    /// ページ送りの座標を作れなかった退避先としてしか使わない
    public func systemUISwipe(_ direction: FTSwipeDirection) async throws {
        let _: OKResponse = try await post("/systemui/swipe",
                                           body: SwipeRequest(direction: direction),
                                           timeout: interactionTimeout)
    }

    /// iOS は任意の前面 bundle ID を取得する手段を持たない(XCUITest は他アプリの状態を見れず、
    /// in-app は自分自身しか知らない)。appIs の失敗メッセージは actual なしで表示する
    public func foregroundAppID() async throws -> String? { nil }

    /// simctl 等で起動済みのアプリへプロキシ接続だけ行う(FastLaunchDriver 用。activate 比 約-1s)
    public func attach(bundleID: String) async throws {
        let _: OKResponse = try await post("/session",
                                           body: LaunchRequest(bundleID: bundleID, attachOnly: true),
                                           timeout: sessionTimeout)
    }

    public func launch(bundleID: String) async throws {
        let _: OKResponse = try await post("/session", body: LaunchRequest(bundleID: bundleID),
                                           timeout: sessionTimeout)
    }

    public func activate(bundleID: String) async throws {
        let _: OKResponse = try await post("/session", body: LaunchRequest(bundleID: bundleID, activate: true),
                                           timeout: sessionTimeout)
    }

    public func openAppSwitcher() async throws {
        let _: OKResponse = try await post("/appswitcher", body: OKResponse(),
                                           timeout: sessionTimeout)
    }

    public func home() async throws {
        let _: OKResponse = try await post("/home", body: OKResponse(),
                                           timeout: sessionTimeout)
    }

    public func snapshot() async throws -> SnapshotResponse {
        try await snapshot(query: nil)
    }

    /// `AppDriver.hittable`。**XCUITest ブリッジだけが答えられる**(in-app / Android は既定の nil)。
    /// 版 67 より古いブリッジは 404 を返すので、その場合も nil(呼び手は黙る)。
    /// 費用は対象1件で 72〜146ms(実測)なので、**呼び手が疑ったときだけ**呼ぶこと
    public func hittable(ref: Int) async throws -> Bool? {
        struct Answer: Decodable { let hittable: Bool? }
        do {
            let answer: Answer = try await get("/hittable", query: "ref=\(ref)",
                                               timeout: sessionTimeout)
            return answer.hittable
        } catch {
            // 未対応(旧ブリッジ)・引き当て不能・一時的な失敗はすべて「答えられない」に畳む ——
            // **タップの手前の照会で失敗して操作ごと落とすのは本末転倒**
            return nil
        }
    }

    /// 次の1回だけ効く要素上限(AppDriver.raiseElementLimitOnNextSnapshot)。
    /// **消費は snapshot(query:) の1箇所**(取りこぼすと以後の木が全部膨らむ)
    private var pendingElementLimit: Int?

    public func raiseElementLimitOnNextSnapshot(_ max: Int?) {
        pendingElementLimit = max
    }

    /// `refresh=1` は Android ブリッジとの契約(AndroidRunner の BridgeRouter.handleSnapshot)。
    /// **iOS ブリッジへ送ってはいけない** —— クエリ付きは別ルート扱いで
    /// `404 not found: GET /snapshot?refresh=1` になる(2026-08-03 に実測。
    /// 「未知クエリは無視される」と書いてあったが誤りだった)。
    /// 呼び出し側は必ず `supportsCacheBypass`(このクライアントは既定の false)で閉じること
    public func snapshot(bypassingCache: Bool) async throws -> SnapshotResponse {
        try await snapshot(query: bypassingCache ? "refresh=1" : nil)
    }

    private func snapshot(query: String?) async throws -> SnapshotResponse {
        // 上限の指定は**消費してから**送る(送信に失敗しても次の呼び出しへ持ち越さない ——
        // 持ち越すと「1回だけ」の契約が壊れ、以後の整定ループまで重い木を引く)
        let limit = pendingElementLimit
        pendingElementLimit = nil
        let merged = [query, limit.map { "max=\(BridgeAPI.resolvedSnapshotElementLimit($0))" }]
            .compactMap { $0 }.joined(separator: "&")
        var response: SnapshotResponse = try await get("/snapshot",
                                                       query: merged.isEmpty ? nil : merged,
                                                       timeout: sessionTimeout)
        // 取りこぼしの申告(クロスオリジン iframe 等)は記録に載せる。
        // **無申告なら触らない**: 直前アクションの note を消してしまわないため
        if let note = response.note { lastActionNote = note }
        await injectSafariDOMIfApplicable(&response)
        return response
    }

    /// **前面が Safari のときだけ WebView の中身を DOM で置き換える**(Android の
    /// `AndroidDriver.snapshot(bypassingCache:)` と同じ規則。宣言は `WebViewDOM.droppingWebViewSubtree`)。
    ///
    /// 前面判定は `sessionBundleID`(ブリッジがデバイス上で見た値)**だけ**を見る。
    /// このクライアントは Android の `currentPackage` に相当する host 側の帳簿を持たないので
    /// 新たに足さない —— Android では「帳簿は launch/openURL 経由でしか更新されず、MCP のように
    /// 既に前面にあるブラウザへ繋ぐと nil のまま」という実害が出ている(AndroidDriver 宣言コメント参照)。
    /// **取れなければ黙って a11y のまま**(例外にしない。Safari 未起動・タブ無し・ペアリング未了はどれも普通にある)。
    private func injectSafariDOMIfApplicable(_ response: inout SnapshotResponse) async {
        guard SafariWebInspector.isEnabled,
              response.sessionBundleID == SafariWebInspector.safariBundleID else { return }
        // **`webView` ノードが無くても差し込む**(2026-08-14 の監査で直した。Android 側と同じ規律。
        // 理由は `WebViewDOM.browserContentFrame` の宣言)
        // **既定は a11y**。足りているなら DOM は読まない(理由は browserA11yLooksSufficient)
        guard !WebViewDOM.browserA11yLooksSufficient(elements: response.elements) else { return }
        let webView = WebViewDOM.webViewElement(in: response.elements)
        guard let frame = webView?.frame ?? WebViewDOM.browserContentFrame(in: response.elements,
                                                                          screen: response.screen),
              let target = await browserDOMTarget(),
              let payload = await readBrowserDOM(target)
        else { return }
        // nextRef は差し込み前の全要素から採る(落とす内側の要素も含めて衝突を避ける)
        let nextRef = (response.elements.map(\.ref).max() ?? 0) + 1
        // **density: 1**(iOS の a11y frame は既に pt。Android は物理 px なので density を掛ける)
        let added = WebViewDOM.elements(payload: payload, webViewFrame: frame,
                                        density: 1, startingRef: nextRef)
        let kept = webView.map { WebViewDOM.droppingWebViewSubtree(response.elements, webView: $0) }
            ?? response.elements
        response.elements = kept + added
    }

    private func readBrowserDOM(_ target: BrowserDOMTarget) async -> WebViewDOM.Payload? {
        switch target {
        case .simulator(let udid): return await SafariWebInspector.read(udid: udid)
        case .physical(let udid): return await SafariWebInspector.read(physicalUDID: udid)
        }
    }

    /// Safari inspector の接続先。シミュレータは simctl UDID、実機は **usbmuxd の識別子
    /// (= ハードウェア UDID)**。**devicectl の identifier とは別物**(`ResolvedTarget.physical` /
    /// `installTarget()` が持つのは devicectl 用の識別子で、usbmuxd の `ReadPairRecord`/
    /// `ListDevices` には通らない。`IOSPhysicalDeviceInfo.udid` がハードウェア UDID)
    enum BrowserDOMTarget: Equatable {
        case simulator(udid: String)
        case physical(udid: String)
    }

    /// **クライアント1つにつき1回だけ解決してキャッシュする** —— `status()`/カタログ列挙は
    /// snapshot のたびに引くと重い(相手は接続の生存中に変わらない前提)。
    /// 外側 Optional = 未解決、内側 Optional = 解決済みで対象外(解決不能)
    private var resolvedBrowserDOMTarget: BrowserDOMTarget??

    private func browserDOMTarget() async -> BrowserDOMTarget? {
        if let resolvedBrowserDOMTarget { return resolvedBrowserDOMTarget }
        let target: BrowserDOMTarget?
        if let physicalUDID {
            target = .physical(udid: physicalUDID)
        } else if let current = try? await status() {
            target = Self.resolveBrowserDOMTarget(named: current.device, simulators: try? SimulatorCatalog.devices(),
                                                   physicalDevices: { try? IOSPhysicalDeviceCatalog.devices() })
        } else {
            target = nil
        }
        resolvedBrowserDOMTarget = target
        return target
    }

    /// 純粋な名前引き(`resolveTarget(named:simulators:physicalDevices:)` と同じ形)。
    /// **実機は `.udid`(ハードウェア UDID)を返す** —— `resolveTarget` が返す
    /// `deviceCtlIdentifier` は devicectl 専用でここでは使えない
    /// **同名が複数居たら諦める**(2026-08-13 のレビュー指摘)。ここで1つ選ぶと
    /// **別端末の Safari の画面内容を、この端末の木へ正として差し込む**ことになる。
    /// 宛先が一意でないときは撃たない規律(MCP の宛先記憶と同じ)。
    /// 取れないときは黙って a11y のまま = 誤った木を返すより無害
    static func resolveBrowserDOMTarget(named device: String, simulators: [SimDeviceInfo]?,
                                        physicalDevices: () -> [IOSPhysicalDeviceInfo]?) -> BrowserDOMTarget? {
        if let simulators {
            let booted = simulators.filter { $0.booted && !$0.physical && $0.name == device }
            if booted.count > 1 { return nil }
            if let simulator = booted.first { return .simulator(udid: simulator.udid) }
        }
        let phones = physicalDevices()?.filter { $0.name == device } ?? []
        if phones.count > 1 { return nil }
        return phones.first.map { .physical(udid: $0.udid) }
    }

    public func tap(ref: Int) async throws {
        lastActionNote = nil
        let res: OKResponse = try await post("/tap", body: TapRequest(ref: ref, fast: fastFlag),
                                             timeout: interactionTimeout)
        lastActionNote = res.note
    }

    public func tap(x: Double, y: Double) async throws {
        let _: OKResponse = try await post("/tap", body: TapRequest(x: x, y: y, fast: fastFlag),
                                           timeout: interactionTimeout)
    }

    public func type(ref: Int?, text: String) async throws {
        let _: OKResponse = try await post("/type", body: TypeRequest(ref: ref, text: text),
                                           timeout: interactionTimeout)
    }

    public func pressEnter() async throws {
        let _: OKResponse = try await post("/pressEnter", body: OKResponse(), timeout: interactionTimeout)
    }

    public func clearInput(ref: Int?) async throws {
        let _: OKResponse = try await post("/clear", body: ClearRequest(ref: ref),
                                           timeout: interactionTimeout)
    }

    public func hideKeyboard() async throws {
        let _: OKResponse = try await post("/hidekeyboard", body: OKResponse(), timeout: interactionTimeout)
    }

    /// エッジスワイプ = iOS の戻る操作(pop ジェスチャ)。ブリッジに /back ルートは無い(版上げ回避。
    /// /drag で表現する)。スワイプバック無効の画面では効かない
    /// **戻るボタンがあれば押す。無ければ左端エッジスワイプ**。
    ///
    /// エッジスワイプは iOS 標準の interactive pop を再現したものだが、**成立を保証できない** ——
    /// 成立しなければ同じタッチが下の要素へ渡り、押していない行が反応し得る。
    /// Android のシステムキーと違って決定的でないため、外部フィードバックで
    /// 「戻ったはずが別の画面に居た」と報告された(こちらでは9回試して再現せず。
    /// 報告者も後に別原因と訂正したが、**機構として非決定的なのは事実**なので直す)。
    ///
    /// UIKit / SwiftUI のナビゲーションバーは戻るボタンに `BackButton` という識別子を付ける
    /// (iOS 27.0 の設定アプリで実測: `button id=BackButton label=設定 (16,62 44x44)`)。
    /// **Compose / Flutter は自前描画でシステムのナビゲーションバーを持たない**ので nil になり、
    /// 従来どおりエッジスワイプへ落ちる = 既存の挙動は変わらない
    public func back() async throws {
        let tree = try await snapshot()
        if let button = Self.navigationBackButton(in: tree) {
            try await tap(x: button.frame.x + button.frame.width / 2,
                          y: button.frame.y + button.frame.height / 2)
            return
        }
        let screen = tree.screen
        try await drag(fromX: screen.x + 1, fromY: screen.y + screen.height * 0.5,
                       toX: screen.x + screen.width * 0.65, toY: screen.y + screen.height * 0.5,
                       pressSeconds: 0.05, durationSeconds: 0.25)
    }

    /// ナビゲーションバーの戻るボタン。**識別子で引く**(位置や順序で当てると、左に別のボタンを
    /// 置く画面で取り違える)。無効(戻れない)なものは採らない
    static func navigationBackButton(in snapshot: SnapshotResponse) -> ElementInfo? {
        snapshot.elements.first {
            $0.identifier == "BackButton" && $0.type == "button" && $0.enabled
        }
    }

    public func swipe(_ direction: FTSwipeDirection) async throws {
        try await swipe(direction, intent: .gesture)
    }

    /// 直前の端送りで「もう端」とブリッジが答えたか(`AppDriver.reachedEdgeOnLastSwipe`)。
    /// **答えない旧ブリッジでは nil のまま** = ホストは従来どおり木の署名で判定する
    public private(set) var atEdgeOnLastSwipe: Bool?
    public var reachedEdgeOnLastSwipe: Bool? { atEdgeOnLastSwipe }

    public func swipe(_ direction: FTSwipeDirection, intent: FTSwipeIntent,
                      path: FTSwipePath? = nil) async throws {
        atEdgeOnLastSwipe = nil
        let response: OKResponse = try await post(
            "/swipe",
            body: SwipeRequest(direction: direction, fast: fastFlag,
                               scroll: intent == .gesture ? nil : true,
                               durationMs: Self.strokeMs(for: intent, path: path),
                               fling: intent == .edge ? true : nil,
                               velocity: Self.velocity(for: intent, path: path),
                               path: path,
                               edge: intent == .edge ? true : nil),
            timeout: interactionTimeout)
        atEdgeOnLastSwipe = response.atEdge
    }

    /// scrollToEdge のジェスチャ(Android)。**行き過ぎても無害な用途にだけ使う**(探索に使うと
    /// 1回の移動量がビューポート高を超えて要素を飛び越す)。iOS 側は未使用フィールドとして無視する。
    ///
    /// **`SwipeRequest.distance` は送らない**(= ブリッジの軸別既定 縦 0.4・横 0.6 のまま)。
    /// 距離を広げてはいけない: スワイプは画面中央基準の全画面固定(design.md 承認済み差分)なので、
    /// 0.8 にすると始点が y=画面の10% になり**スクロール領域の外から始まって1ミリも動かない**。
    /// 2026-08-02 に実際に踏んだ(scrollToBottom は始点がリスト内なので成功し、scrollToTop だけが
    /// 3 SUT とも row_29 で止まって直後の `exist "#row_01"` が落ちた)。速くするのはストロークだけ。
    /// 実測(Android View/XML): 300ms/実時計 276px → 200ms/合成 1,156px
    static let edgeSwipeDurationMs = 150

    /// ストローク時間。**探索では触らない**(ブリッジ既定 300ms)。
    /// 2026-08-02 に 200ms を試したが、Android の Compose で慣性が出て
    /// **探索直後のタップが 9 行ずれた**(row_30 を狙って row_39)。
    /// 逆に 300ms のままだと Flutter/Android は負荷時に到達し損ねることがある ——
    /// **どちらかに倒せるだけの較正が無い**ので現状維持(docs/performance-tuning.md §3.16 の
    /// 「較正できるまで触らない」に従う)
    static func strokeMs(for intent: FTSwipeIntent, path: FTSwipePath?) -> Int? {
        intent == .edge ? edgeSwipeDurationMs : nil
    }

    /// XCUITest ランナー側の同じ用途のノブ(points/sec。`XCUIGestureVelocity`)。
    /// 距離ではなく速度で効かせるので、Android のような「始点がスクロール領域の外に出る」
    /// 事故は起きない(XCTest が要素の中で始点を決める)。
    ///
    /// **2500 ではなく 1500**: 3設定×3周(交互)の実測で、scrollToTop の中央値はほぼ同じ
    /// (8,251 対 8,287ms)なのに**最悪ケースが 12.9s 対 18.5s**と差が付き、周ごとのばらつきも
    /// 小さかった。sum では 2500 が 8.8s 勝つ(壁時計 約1.1s/プロファイル)が、尾を引く挙動は
    /// フレーク耐性の観点で割に合わない。詳細は docs/performance-tuning.md §3.17
    static let edgeSwipeVelocity = 1500.0

    /// 用途から velocity を決める。**探索では送らない**(既定速度のまま)。
    /// 慣性を消す狙いで v350 を試したが、**エンジンを跨ぐと収束しなかった** ——
    /// iOS では刻み = 実移動量にできる一方、Android は速度ノブが無く(距離とストローク時間で
    /// 決まる)同じ設計にできない。実測は docs/performance-tuning.md §3.18
    static func velocity(for intent: FTSwipeIntent, path: FTSwipePath?) -> Double? {
        intent == .edge ? edgeSwipeVelocity : nil
    }

    public func drag(fromX: Double, fromY: Double, toX: Double, toY: Double,
                     pressSeconds: Double, durationSeconds: Double) async throws {
        let _: OKResponse = try await post("/drag", body: DragRequest(
            fromX: fromX, fromY: fromY, toX: toX, toY: toY,
            press: pressSeconds, duration: durationSeconds),
            timeout: interactionTimeout)
    }

    public func doubleTap(x: Double, y: Double) async throws {
        let _: OKResponse = try await post("/doubletap", body: TapRequest(x: x, y: y, fast: fastFlag),
                                           timeout: interactionTimeout)
    }

    /// ピンチは XCUITest の `XCUIElement.pinch` に落ちる = **1回の呼び出しの中で指を動かし切る**ので、
    /// 移動時間ぶん応答が遅れる。interactionTimeout に収まる範囲でしか使えない
    public func pinch(frame: FTRect?, identifier: String?, scale: Double,
                      durationSeconds: Double) async throws {
        let _: OKResponse = try await post("/pinch", body: PinchRequest(
            scale: scale, durationSeconds: durationSeconds,
            frame: frame, identifier: identifier), timeout: interactionTimeout)
    }

    /// Captured only on this client's first `rotate(to:)` call in the current scenario (nil = not
    /// used yet, or already restored). Read from the bridge (GET /status) rather than assumed,
    /// since the bridge is the source of truth for its own orientation.
    private var originalOrientation: FTOrientation?

    public func rotate(to orientation: FTOrientation) async throws -> FTOrientation {
        if originalOrientation == nil {
            let current: StatusResponse = try await status()
            originalOrientation = current.orientation ?? .portrait
        }
        let response: RotateResponse = try await post(
            "/rotate", body: RotateRequest(orientation: orientation), timeout: interactionTimeout)
        return response.orientation
    }

    public func restoreOrientationIfNeeded() async throws {
        guard let original = originalOrientation else { return }
        originalOrientation = nil
        let _: RotateResponse = try await post(
            "/rotate", body: RotateRequest(orientation: original), timeout: interactionTimeout)
    }

    public func press(ref: Int, duration: Double) async throws {
        let _: OKResponse = try await post("/press", body: PressRequest(ref: ref, duration: duration,
                                                                        fast: fastFlag),
                                           timeout: interactionTimeout)
    }

    public func press(x: Double, y: Double, duration: Double) async throws {
        let _: OKResponse = try await post("/press", body: PressRequest(x: x, y: y, duration: duration,
                                                                        fast: fastFlag),
                                           timeout: interactionTimeout)
    }

    public func screenshot() async throws -> Data {
        let (data, response) = try await request(path: "/screenshot", method: "GET", body: nil,
                                                 timeout: sessionTimeout)
        try Self.check(response: response, data: data)
        return data
    }

    /// 画面の静穏だけ待つ(状態は変えない)。**Android ブリッジ専用**(v19 以降)。
    /// ホストが adb/gRPC でブリッジを経由せず画面を変えた後、固定 sleep の代わりに使う。
    /// iOS ブリッジにはこのルートが無いので呼ばないこと(404 になる)。
    public func settle() async throws {
        let _: OKResponse = try await post("/settle", body: OKResponse(), timeout: interactionTimeout)
    }

    public func terminate() async throws {
        let _: OKResponse = try await post("/terminate", body: OKResponse(),
                                           timeout: sessionTimeout)
    }

    public struct DeviceLocaleResponse: Decodable, Sendable {
        public let changed: Bool
        public let locale: String
    }

    /// システムロケールの永続変更。Android ブリッジのみ対応(iOS ブリッジは 404。
    /// 同期相手: AndroidRunner/src/.../BridgeRouter.java handleLocale)
    public func setDeviceLocale(_ locale: String) async throws -> DeviceLocaleResponse {
        struct LocaleRequest: Encodable { let locale: String }
        return try await post("/locale", body: LocaleRequest(locale: locale),
                              timeout: sessionTimeout)
    }

    // MARK: - HTTP helpers

    func get<R: Decodable>(_ path: String, query: String? = nil,
                           timeout: TimeInterval? = nil) async throws -> R {
        let (data, response) = try await request(path: path, method: "GET", body: nil,
                                                 query: query, timeout: timeout)
        try Self.check(response: response, data: data)
        return try JSONDecoder().decode(R.self, from: data)
    }

    func post<B: Encodable, R: Decodable>(_ path: String, body: B,
                                          timeout: TimeInterval? = nil) async throws -> R {
        let bodyData = try JSONEncoder().encode(body)
        let (data, response) = try await request(path: path, method: "POST", body: bodyData,
                                                 timeout: timeout)
        try Self.check(response: response, data: data)
        return try JSONDecoder().decode(R.self, from: data)
    }

    /// **クエリは path に混ぜない**: appendingPathComponent は "?" を %3F へ逃がすので、
    /// "/snapshot?refresh=1" を渡すとブリッジ側で "GET /snapshot%3Frefresh=1" になり 404 になる
    /// (2026-08-02 に実際に踏んだ。フェイクドライバの単体テストでは配線が通らず気付けなかった)
    static func url(base: URL, path: String, query: String?) -> URL {
        let withPath = base.appendingPathComponent(path)
        guard let query, !query.isEmpty,
              var components = URLComponents(url: withPath, resolvingAgainstBaseURL: false)
        else { return withPath }
        components.query = query
        return components.url ?? withPath
    }

    func request(path: String, method: String, body: Data?, query: String? = nil,
                 timeout: TimeInterval? = nil) async throws -> (Data, URLResponse) {
        var req = URLRequest(url: Self.url(base: baseURL, path: path, query: query))
        req.httpMethod = method
        req.httpBody = body
        if let timeout { req.timeoutInterval = timeout }
        if body != nil {
            req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        }
        do {
            if let collector = HTTPTimingCollector.shared {
                return try await session.data(for: req, delegate: collector)
            }
            return try await session.data(for: req)
        } catch {
            if DriverError.isDefiniteDeliveryFailure(error) {
                throw DriverError.bridgeConnectionRefused(error.localizedDescription)
            }
            throw DriverError.bridgeUnreachable(error.localizedDescription)
        }
    }

    static func check(response: URLResponse, data: Data) throws {
        guard let http = response as? HTTPURLResponse else { return }
        guard (200..<300).contains(http.statusCode) else {
            let message: String
            if let err = try? JSONDecoder().decode(ErrorResponse.self, from: data) {
                message = err.error
            } else {
                message = String(data: data, encoding: .utf8) ?? "<binary>"
            }
            throw DriverError.badResponse(status: http.statusCode, body: message)
        }
    }
}
