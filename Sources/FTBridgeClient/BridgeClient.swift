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
                            physicalUDID: String? = nil) {
        self.init(port: port, timeoutSeconds: timeoutSeconds,
                  interactionTimeout: min(Timeout.interaction, timeoutSeconds),
                  sessionTimeout: min(Timeout.session, timeoutSeconds),
                  host: host, physicalUDID: physicalUDID)
    }

    /// テスト専用 seam: interaction/session の予算を短縮注入する(未応答ブリッジのタイムアウト
    /// 検証等)。公開 init(port:timeoutSeconds:) はこれを既定予算付きで呼ぶだけで公開 API は不変。
    /// host はシミュレータ(ホストとネットワークスタックを共有)では常に 127.0.0.1。
    /// iOS 実機だけ LAN IP を渡す(BridgeEndpoint 参照)
    init(port: UInt16, timeoutSeconds: TimeInterval = 120,
        interactionTimeout: TimeInterval, sessionTimeout: TimeInterval,
        host: String = BridgeEndpoint.loopbackHost,
        physicalUDID: String? = nil) {
        self.baseURL = URL(string: "http://\(host):\(port)")!
        self.physicalUDID = physicalUDID
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

    /// clearAppData の対象シミュレータ(UDID 優先)。実機は同等手段が devicectl に無いので 501
    public func simulatorTarget() async throws -> String {
        guard physicalUDID == nil else {
            throw DriverError.badResponse(status: 501,
                body: "clearAppData is simulator-only on iOS (devicectl has no equivalent;"
                    + " reinstall the app instead)")
        }
        let current = try await status()
        return (try? SimulatorCatalog.devices())?
            .first(where: { $0.booted && $0.name == current.device })?.udid ?? current.device
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
        // 権限はコンテナの外にあるので別途戻す(resetPrivacyOnSimulator 参照)
        try resetPrivacyOnSimulator(bundleID: bundleID, target: target)
    }

    /// install は HTTP エンドポイントを持たず simctl / devicectl の役割。
    /// 実機(physicalUDID 指定時)は `devicectl device install app`、シミュレータは従来どおり simctl。
    /// シミュレータの対象特定は /status のデバイス名から行う。同名デバイス(Shutdown の複製等)が
    /// あると名前指定 simctl は失敗するため、Booted かつ同名の UDID に解決してから実行する
    /// (解決不能時は名前のまま試す)。
    public func install(packagePath: String) async throws {
        if let udid = physicalUDID {
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
        let current = try await status()
        let target = (try? SimulatorCatalog.devices())?
            .first(where: { $0.booted && $0.name == current.device })?.udid ?? current.device
        let result = try Shell.run(["xcrun", "simctl", "install", target, packagePath])
        guard result.status == 0 else {
            throw DriverError.badResponse(status: Int(result.status),
                body: "simctl install failed: \(result.tail)")
        }
    }

    /// uninstall は install と対で HTTP エンドポイントを持たず simctl / devicectl の役割。
    /// 対象特定は install と同じ規則(実機は UDID 直・シミュレータは /status のデバイス名から解決)
    public func uninstall(bundleID: String) async throws {
        if let udid = physicalUDID {
            let result = try Shell.run(
                ["xcrun", "devicectl", "device", "uninstall", "app",
                 "--device", udid, bundleID], timeout: 600)
            guard result.status == 0 else {
                throw DriverError.badResponse(status: Int(result.status),
                    body: "devicectl device uninstall app failed: \(result.tail)")
            }
            return
        }
        let current = try await status()
        let target = (try? SimulatorCatalog.devices())?
            .first(where: { $0.booted && $0.name == current.device })?.udid ?? current.device
        let result = try Shell.run(["xcrun", "simctl", "uninstall", target, bundleID])
        guard result.status == 0 else {
            throw DriverError.badResponse(status: Int(result.status),
                body: "simctl uninstall failed: \(result.tail)")
        }
    }

    /// フォアグラウンドのアプリが bundleID と一致するか(POST /appstate。両ブリッジ HTTP 互換)
    public func isAppForeground(bundleID: String) async throws -> Bool {
        let res: AppStateResponse = try await post("/appstate", body: AppStateRequest(bundleID: bundleID),
                                                    timeout: sessionTimeout)
        return res.foreground
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

    /// `refresh=1` は Android ブリッジとの契約(AndroidRunner の BridgeRouter.handleSnapshot)。
    /// **iOS ブリッジへ送ってはいけない** —— クエリ付きは別ルート扱いで
    /// `404 not found: GET /snapshot?refresh=1` になる(2026-08-03 に実測。
    /// 「未知クエリは無視される」と書いてあったが誤りだった)。
    /// 呼び出し側は必ず `supportsCacheBypass`(このクライアントは既定の false)で閉じること
    public func snapshot(bypassingCache: Bool) async throws -> SnapshotResponse {
        try await snapshot(query: bypassingCache ? "refresh=1" : nil)
    }

    private func snapshot(query: String?) async throws -> SnapshotResponse {
        let response: SnapshotResponse = try await get("/snapshot", query: query,
                                                       timeout: sessionTimeout)
        // 取りこぼしの申告(クロスオリジン iframe 等)は記録に載せる。
        // **無申告なら触らない**: 直前アクションの note を消してしまわないため
        if let note = response.note { lastActionNote = note }
        return response
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
    public func back() async throws {
        let screen = try await snapshot().screen
        try await drag(fromX: screen.x + 1, fromY: screen.y + screen.height * 0.5,
                       toX: screen.x + screen.width * 0.65, toY: screen.y + screen.height * 0.5,
                       pressSeconds: 0.05, durationSeconds: 0.25)
    }

    public func swipe(_ direction: FTSwipeDirection) async throws {
        try await swipe(direction, intent: .gesture)
    }

    public func swipe(_ direction: FTSwipeDirection, intent: FTSwipeIntent,
                      path: FTSwipePath? = nil) async throws {
        let _: OKResponse = try await post(
            "/swipe",
            body: SwipeRequest(direction: direction, fast: fastFlag,
                               scroll: intent == .gesture ? nil : true,
                               durationMs: Self.strokeMs(for: intent, path: path),
                               fling: intent == .edge ? true : nil,
                               velocity: Self.velocity(for: intent, path: path),
                               path: path),
            timeout: interactionTimeout)
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
