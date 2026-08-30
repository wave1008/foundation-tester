// AppDriver の Android 実装。
// snapshot/tap/type/swipe/press/screenshot/launch/status はデバイス常駐ブリッジ
// (AndroidRunner/、iOS ブリッジとプロトコル互換)を自動起動して HTTP で行う(AndroidBridge.swift)。
// ブリッジに接続できない場合は DriverError.bridgeUnreachable を投げる(フォールバックなし)。
// 操作後の整定待ちはブリッジ側の a11y 静穏検知に委譲する。
// terminate のみ adb 直(currentPackage 管理の意味論を維持)。
// FTFoundationModels(探索・修復・トリアージ)と FTCore(再生器)はドライバ実装に依存しない。

import CryptoKit
import Foundation
import FTBridgeClient
import FTCore

public final class AndroidDriver: AppDriver {

    public let adbPath: String
    let serial: String?

    // 直近スナップショットの ref → 中心座標(iOS ランナーと同じ方式)。iOS と違い CLI プロセス内に
    // 住むため、呼び出しをまたぐ手動駆動用に一時ファイルへも永続化する(run は単一プロセスで不要だが無害)
    private var refCenters: [Int: (x: Double, y: Double)] = [:]
    /// DOM 由来の要素の ref → ブリッジが知っている a11y の ref(自作アプリの WebView のときだけ埋まる)。
    /// **注入(type / clear)でだけ差し替える**。ブリッジは自分の snapshot の ref しか受け付けない
    /// (未知の ref は 404)ので、これが無いと WebView 内の入力だけが落ちる
    /// (規則と根拠は `AndroidWebViewDOM.bridgeRefMap`)
    private var domBridgeRefs: [Int: Int] = [:]
    private var screen: FTRect = FTRect(x: 0, y: 0, width: 0, height: 0)
    private var currentPackage: String?

    /// captureKeyboardStateOnNextSnapshot() が立てるフラグ。dumpsys window windows は固定費が
    /// 大きいため毎 snapshot では叩かず、StepExecutor が keyboardShown/keyboardNotShown アサートの
    /// 直前に立てたときだけ払う(snapshot() 側で読み捨てる)
    private var captureKeyboardOnNextSnapshot = false
    /// CDP の端送りが使えなかったアプリ(ネイティブ画面で毎回ソケットを探さないための記憶)
    private var webViewEdgeJumpUnavailableFor: String?

    /// raiseElementLimitOnNextSnapshot() が立てる1回限りの要素上限(nil = 既定)
    private var pendingElementLimit: Int?

    /// `pointScale` の1度きりの実測値(端末ごとに固定)
    private var cachedPointScale: Double?

    private struct PersistedState: Codable {
        var centers: [Int: [Double]]
        var screen: FTRect
        var package: String?
        /// 省略可(古い状態ファイルとの互換。domBridgeRefs 参照)
        var domBridgeRefs: [Int: Int]?
    }

    private var stateFileURL: URL {
        // WiFi 接続の実機 serial は "192.168.1.23:5555" 形式で ":" を含む。ファイル名に使うと
        // Finder 上で "/" に化けるため、パス区切りになりうる文字は "_" に潰す
        let safeSerial = (serial ?? "default").map { $0 == ":" || $0 == "/" ? "_" : $0 }
        return FileManager.default.temporaryDirectory
            .appendingPathComponent("fleetest-android-\(String(safeSerial)).json")
    }

    func persistState() {
        let state = PersistedState(
            centers: refCenters.mapValues { [$0.x, $0.y] },
            screen: screen, package: currentPackage, domBridgeRefs: domBridgeRefs)
        if let data = try? JSONEncoder().encode(state) {
            try? data.write(to: stateFileURL)
        }
    }

    private func restoreStateIfNeeded() {
        guard refCenters.isEmpty,
              let data = try? Data(contentsOf: stateFileURL),
              let state = try? JSONDecoder().decode(PersistedState.self, from: data) else { return }
        refCenters = state.centers.compactMapValues { $0.count == 2 ? (x: $0[0], y: $0[1]) : nil }
        domBridgeRefs = state.domBridgeRefs ?? [:]
        screen = state.screen
        if currentPackage == nil { currentPackage = state.package }
    }

    public init(serial: String? = nil) throws {
        self.adbPath = try Self.findADB()
        self.serial = serial
    }

    public static func findADB() throws -> String {
        let candidates = [
            ProcessInfo.processInfo.environment["ANDROID_HOME"].map { $0 + "/platform-tools/adb" },
            NSHomeDirectory() + "/Library/Android/sdk/platform-tools/adb",
            "/usr/local/bin/adb",
            "/opt/homebrew/bin/adb",
        ].compactMap { $0 }
        for path in candidates where FileManager.default.isExecutableFile(atPath: path) {
            return path
        }
        throw DriverError.bridgeUnreachable("adb not found (set ANDROID_HOME)")
    }

    // MARK: - adb helpers

    /// 論理 px → 物理 px の倍率(DOM の CSS px を画面座標へ写すのに要る)
    func displayDensity() -> Double {
        guard let out = try? adb(["shell", "wm", "density"]).output,
              let density = Self.parseDisplayDensity(out) else { return 1 }
        return density
    }

    /// `adb shell wm density` の出力 → **dp あたりの px**。
    /// **最後の density 行**を採る(`Override density` があればそれが実効値)。
    /// 160 は dp の定義そのもの(1dp = 1/160 inch)なので調整値ではない。
    /// 読めなければ nil = 呼び手は 1(換算しない = 従来の挙動)へ落ちる
    static func parseDisplayDensity(_ output: String) -> Double? {
        guard let line = output.split(separator: "\n").last(where: { $0.contains("density") }),
              let dpi = line.split(separator: ":").last
                .flatMap({ Double($0.trimmingCharacters(in: .whitespaces)) }),
              dpi > 0
        else { return nil }
        return dpi / 160.0
    }

    func adb(_ args: [String]) throws -> Shell.Result {
        var full = [adbPath]
        if let serial { full += ["-s", serial] }
        return try Shell.run(full + args)
    }

    func adbData(_ args: [String]) throws -> Data {
        var full = [adbPath]
        if let serial { full += ["-s", serial] }
        let (status, data) = try Shell.runData(full + args)
        guard status == 0 else {
            throw DriverError.badResponse(status: Int(status), body: "adb \(args.joined(separator: " "))")
        }
        return data
    }

    // MARK: - AppDriver

    public func status() async throws -> StatusResponse {
        // ブリッジの /status に一本化(ready判定にブリッジ疎通を伴わせ、接続不能なら早期に失敗させる)
        try await withBridge { try await $0.status() }
    }

    /// アプリを残してデータだけ消す(`pm clear`)。**refs も落とす**: 消したあとの画面は
    /// 別物なので、古い ref でのタップを「先に snapshot」エラーへ倒す(launch と同じ規律)
    public func clearAppData(bundleID: String) async throws {
        let result = try adb(["shell", "pm", "clear", bundleID])
        guard result.status == 0, result.output.contains("Success") else {
            throw DriverError.badResponse(status: Int(result.status),
                body: "failed to clear app data (is \(bundleID) installed?): \(result.tail)")
        }
        refCenters = [:]
        domBridgeRefs = [:]
        currentPackage = nil
        persistState()
    }

    /// URL(ディープリンク)を配送する。`am start -W` は遷移完了を待つ。package は bundleID が
    /// 非 nil のときだけ付ける(付けないとチューザ/ブラウザへ流れず対象アプリへ直行する)。
    /// 画面遷移を伴うため直前の ref は無効(launch と同じ理由: 次の snapshot 前に古い ref で
    /// タップされると誤爆する)
    public func openURL(_ url: String, bundleID: String?) async throws {
        let result = try adb(try Self.amStartArgs(url: url, package: bundleID))
        guard result.status == 0, !Self.amStartIndicatesFailure(output: result.output) else {
            throw DriverError.badResponse(status: Int(result.status),
                body: "failed to open the URL via am start: \(result.tail)")
        }
        refCenters = [:]
        domBridgeRefs = [:]
        if let bundleID { currentPackage = bundleID }
        persistState()
    }

    /// URL をデバイス側シェルへ渡すためにシングルクォートで包む。`adb shell` はクライアント側の
    /// 複数引数を空白結合してからデバイス側シェルへ渡す(execve 直結ではない)ため、`&`/`?` 等の
    /// シェル特殊文字を筒抜けにしないためにこちらで引用する。URL 自体にシングルクォートを含む場合は
    /// 安全に引用できないため throw する(黙って壊れた URL を送らない)
    static func quoteURLForDeviceShell(_ url: String) throws -> String {
        guard !url.contains("'") else {
            throw DriverError.badResponse(status: 400,
                body: "cannot deliver a URL containing a single quote via adb shell"
                    + " (it would break the quoting): \(url)")
        }
        return "'\(url)'"
    }

    /// `adb shell am start -W -a android.intent.action.VIEW -d '<url>' [<package>]` の引数列
    static func amStartArgs(url: String, package: String?) throws -> [String] {
        var args = ["shell", "am", "start", "-W", "-a", "android.intent.action.VIEW",
                    "-d", try quoteURLForDeviceShell(url)]
        if let package { args.append(package) }
        return args
    }

    /// am start は失敗しても exit 0 で stdout に "Error:" を出すことがある(intent 解決失敗等)ので
    /// 出力も見る。**判定材料は "Error:" だけ** —— `Warning: Activity not started, intent has been
    /// delivered to currently running top-most instance.` は**成功**(既に前面にある同じ Activity の
    /// onNewIntent へ配送済み = ディープリンクの warm 配送そのもの)で、singleTop の SUT では
    /// これが通常の応答になる。ここを失敗にすると Flutter/RN の配送が全滅する(2026-08-08 に実測)
    static func amStartIndicatesFailure(output: String) -> Bool {
        output.contains("Error:")
    }

    public func install(packagePath: String) async throws {
        // .apks(App Bundle 由来のスプリット)は adb install に渡せない(単一 APK ではない)
        if ApksBundle.isApks(path: packagePath) {
            try installSplitBundle(apksPath: packagePath)
            return
        }
        let result = try adb(["install", "-r", packagePath])
        guard result.output.contains("Success") else {
            throw DriverError.badResponse(status: Int(result.status),
                body: "failed to install the app: \(result.tail)")
        }
    }

    /// .apks は bundletool へ委譲する(スプリットの選別は toc.pb の targeting = ApksBundle 参照)。
    /// 端末の指定は `--device-id`(serial 無し = 接続が1台のときだけ通る adb と同じ意味論)
    private func installSplitBundle(apksPath: String) throws {
        guard let bundletool = ApksBundle.findBundletool() else {
            throw DriverError.badResponse(status: 127,
                body: ApksBundle.missingBundletoolMessage(apksPath: apksPath))
        }
        let result = try Shell.run(ApksBundle.installArgs(
            bundletool: bundletool, apksPath: apksPath, serial: serial, adb: adbPath))
        guard result.status == 0 else {
            throw DriverError.badResponse(status: Int(result.status),
                body: "failed to install the split bundle (.apks): \(result.tail)")
        }
    }

    public func uninstall(bundleID: String) async throws {
        let result = try adb(["uninstall", bundleID])
        guard result.output.contains("Success") else {
            throw DriverError.badResponse(status: Int(result.status),
                body: "failed to uninstall the app: \(result.tail)")
        }
    }

    /// フォアグラウンドのアプリが bundleID と一致するか(DSL の appIs)。
    /// ホスト側で dumpsys を引く(ブリッジはアプリ内 a11y ツリーしか見えず、他プロセスの
    /// window は見えない。AndroidForegroundWindows と同じ制約)
    public func isAppForeground(bundleID: String) async throws -> Bool {
        try await foregroundAppID() == bundleID
    }

    public func foregroundAppID() async throws -> String? {
        let result = try adb(["shell", "dumpsys", "window", "windows"])
        guard result.status == 0 else {
            throw DriverError.badResponse(status: Int(result.status),
                body: "dumpsys window windows failed: \(result.tail)")
        }
        return AndroidForegroundWindows.topmostAppPackage(dumpsys: result.output)
    }

    /// パッケージが入っているか。**判定できないときは nil**(adb 不調でも「未インストール」と
    /// 断じない)。launch 失敗の切り分け文言に使う
    public func isInstalled(bundleID: String) -> Bool? {
        guard let result = try? adb(["shell", "pm", "list", "packages", bundleID]),
              result.status == 0 else { return nil }
        // pm list packages は前方一致で引くので、行の完全一致で判定する
        return result.output.split(separator: "\n")
            .contains { $0.trimmingCharacters(in: .whitespaces) == "package:\(bundleID)" }
    }

    public func launch(bundleID: String) async throws {
        // force-stop+monkey+am start フォールバックと整定待ちはブリッジ側 handleLaunch() が持つ
        // (ここでの追加 sleep は不要)
        try await withBridge { try await $0.launch(bundleID: bundleID) }
        // 再起動で旧 snapshot の ref は無効。メモリ・永続化の両方から落とし、
        // 以後の tap(ref:) を「先に snapshot」エラーに倒す(古い座標への誤タップ防止)
        refCenters = [:]
        domBridgeRefs = [:]
        currentPackage = bundleID
        persistState()
    }

    /// 状態を保持したまま前面化する。ブリッジの launch(force-stop+再起動)は使わず adb 直で

    /// ブリッジを経由せず画面を変えた後の整定。**ブリッジの QuietWaiter(a11y イベント駆動)**を
    /// 呼ぶ(プッシュ型。performance-tuning.md §2 の第1原則)。
    ///
    /// **固定 sleep にしない**: 固定値はマシン性能・並列負荷・アニメーション長で過不足が出る
    /// (iOS 側で同じ問題を実測した。§3.8)。ブリッジが応答しない・旧版(v19 未満)で
    /// ルートが無い等で失敗したときだけ 800ms へ落ちる(整定ゼロで進むと直後の
    /// snapshot が遷移前の画面を掴むため、黙って素通ししない)。
    private func settleViaBridge() async {
        do {
            try await withBridge { try await $0.settle() }
        } catch {
            try? await Task.sleep(nanoseconds: 800_000_000)
        }
    }

    /// ランチャー intent を送る(起動中ならタスクが前面に来るだけ)。
    public func activate(bundleID: String) async throws {
        let result = try adb(["shell", "monkey", "-p", bundleID,
                              "-c", "android.intent.category.LAUNCHER", "1"])
        guard result.status == 0 else {
            throw DriverError.badResponse(status: Int(result.status),
                body: "failed to bring the app to the foreground: \(result.tail)")
        }
        // monkey は intent 送信のみで遷移完了を待たないため、直後の snapshot が遷移前の画面を
        // 掴まないよう整定を待つ(settleViaBridge)
        await settleViaBridge()
        restoreStateIfNeeded()  // 状態保持の前面化なので refs は維持(空の状態で persist して消さない)
        currentPackage = bundleID
        persistState()
    }

    /// タスク一覧(最近使ったアプリ)を開く。**gRPC の名前付きキーは使わない**(理由は home())。
    /// adb keyevent 直行。
    public func openAppSwitcher() async throws {
        let result = try adb(["shell", "input", "keyevent", "KEYCODE_APP_SWITCH"])
        guard result.status == 0 else {
            throw DriverError.badResponse(status: Int(result.status),
                body: "failed to open the app switcher: \(result.tail)")
        }
        // keyevent は遷移完了を待たないため、直後の snapshot 用の整定待ち(activate と同様)
        await settleViaBridge()
    }

    /// ホーム画面に戻る。**gRPC の名前付きキー("GoHome" 等)は使わない** — 成功を返すのに
    /// キーが届かない無音 no-op(2026-08-19 に emulator 36.5.10 / API 36 の2台で確認。
    /// GoHome も AppSwitch も前面が変わらず、adb keyevent なら戻る。送出中の getevent は1イベントも
    /// 受けず、guest の入力デバイスは gpio-keys と multi-touch だけ = キーの載る先が無い。
    /// gpio-keys に載る KEY_POWER/KEY_SLEEP = sleepWake だけは届く。docs/design.md §16.3)。
    /// adb keyevent 直行。
    public func home() async throws {
        let result = try adb(["shell", "input", "keyevent", "KEYCODE_HOME"])
        guard result.status == 0 else {
            throw DriverError.badResponse(status: Int(result.status),
                body: "failed to go to the home screen: \(result.tail)")
        }
        // keyevent は遷移完了を待たないため、直後の snapshot 用の整定待ち(openAppSwitcher と同様)
        await settleViaBridge()
    }

    /// 前の画面へ戻る。**gRPC "GoBack" は使わない** — 成功を返すのにキーが届かない
    /// (2026-07-30 実機で確認。KEY_WAKEUP 不発と同型の無音 no-op。機序は home())。adb keyevent 直行。
    public func back() async throws {
        let result = try adb(["shell", "input", "keyevent", "KEYCODE_BACK"])
        guard result.status == 0 else {
            throw DriverError.badResponse(status: Int(result.status),
                body: "failed to go back: \(result.tail)")
        }
        // keyevent は遷移完了を待たないため、直後の snapshot 用の整定待ち(home() と同様)
        await settleViaBridge()
    }

    public var supportsCacheBypass: Bool { true }

    /// 木は px で来るので、**pt/dp で決めた床を px へ換算する倍率**(= 表示密度)。
    /// 端末ごとに固定なので1度だけ引く(`wm density` の adb 往復をタップのたび払わない)。
    /// 引けなければ 1 = 換算しない側 = 従来の挙動(嘘の倍率を作らない)
    public var pointScale: Double {
        if let cachedPointScale { return cachedPointScale }
        let value = displayDensity()
        cachedPointScale = value
        return value
    }

    /// InputInjector が ACTION_SET_TEXT のたび自前で読み返す(docs/design.md §Android のテキスト注入の規律)
    public var verifiesTypedText: Bool { true }

    public func snapshot() async throws -> SnapshotResponse {
        try await snapshot(bypassingCache: false)
    }

    /// bypassingCache=true はブリッジに全ノード `refresh()` を要求する(既定は WebView 内だけ)。
    /// 約 +65ms 掛かるので、検証が期限切れで失敗と決まる直前の1回にだけ使う(AppDriver の宣言参照)
    public func snapshot(bypassingCache: Bool) async throws -> SnapshotResponse {
        restoreStateIfNeeded()  // 別プロセス実行時に refCenters 等を引き継ぐ(persistState で消さないため)
        // **上限の指定はここで消費する**(クライアントに持たせない): withBridge が返す
        // BridgeClient は接続拒否のたびに作り直されるので、あちら側に立てた1回限りのフラグは
        // 再接続で黙って消える
        let limit = pendingElementLimit
        pendingElementLimit = nil
        var snapshot = try await withBridge {
            $0.raiseElementLimitOnNextSnapshot(limit)
            return try await $0.snapshot(bypassingCache: bypassingCache)
        }
        // RN の button 内側 Text 双子を畳む(SnapshotDedupe の宣言コメント参照)。
        // syncLocalState より前 = 下流(DSL/MCP)は正規化後の木だけを見る
        snapshot.elements = SnapshotDedupe.dropLabelTwinsInsideButtons(snapshot.elements)
        // 対応表は snapshot ごとに作り直す(前の画面のものを持ち越すと別の欄へ注入する)
        domBridgeRefs = [:]
        // **web コンテンツを DOM で置き換える**。対象はブラウザ本体と
        // **テスト対象アプリ自身の WebView**(2026-08-15。a11y が版で属性を入れ替えるため)。
        // **どちらの門も `AndroidWebViewDOM.route` の1箇所**(ここに2つ目の判定を書かない)。
        //
        // **前面の判定はスナップショット自身の `sessionBundleID`(= ブリッジがデバイス上で見た値)を
        // 先に見る**。`currentPackage` は launch/openURL/activate が更新するホスト側の帳簿でしかなく、
        // **MCP のようにアプリを起こさず既にブラウザが前面の端末へ繋ぐ経路では nil のまま**になる
        // (2026-08-13 に実測: 新しいプロセスから Chrome を撮ったら帳簿が nil で経路が丸ごと不発だった)。
        // 帳簿は `sessionBundleID` を返さない古いブリッジのための保険として残す
        if let package = snapshot.sessionBundleID ?? currentPackage {
            // **`webView` ノードが無くても差し込む(ブラウザだけ)**(2026-08-14 の監査で直した)。
            // Chrome は本文を1要素も公開しない画面でノードごと出さないことがあり、
            // そこが**まさに DOM が要る場面**なのに門で弾いていた。無いときは
            // 上下の chrome から内容領域を割り出す(`browserContentFrame`)。
            // 自作アプリ側は `route` が `webView` ノードの存在を門にしているので必ず frame がある
            let webView = WebViewDOM.webViewElement(in: snapshot.elements)
            let frame = webView?.frame ?? WebViewDOM.browserContentFrame(in: snapshot.elements,
                                                                        screen: snapshot.screen)
            let route = AndroidWebViewDOM.route(
                packageID: package, hasWebViewNode: webView != nil,
                a11yLooksSufficient: WebViewDOM.browserA11yLooksSufficient(elements: snapshot.elements),
                browserDOMEnabled: AndroidWebViewDOM.isBrowserDOMEnabled,
                appWebViewDOMEnabled: AndroidWebViewDOM.isAppWebViewDOMEnabled)
            if route != .a11y, let frame,
               let payload = await AndroidWebViewDOM.read(
                serial: serial ?? "", packageID: package, route: route, webViewLabel: webView?.label,
                urlBarValue: AndroidWebViewDOM.urlBarValue(in: snapshot.elements),
                adb: { try self.adb($0).output }) {
                // nextRef は差し込み前の全要素から採る(落とす内側の要素も含めて衝突を避ける)
                let nextRef = (snapshot.elements.map(\.ref).max() ?? 0) + 1
                let added = WebViewDOM.elements(payload: payload, webViewFrame: frame,
                                                density: displayDensity(), startingRef: nextRef)
                var kept = snapshot.elements
                if let webView {
                    // **自作アプリだけ、注入用の ref 対応表を作る**(理由は bridgeRefMap。
                    // ブリッジは自分の ref しか受けないので、無いと type/clearInput が 404)。
                    // **ブラウザ経路は今日の挙動のまま**にする(今回の変更の対象外)
                    if route == .appWebView {
                        domBridgeRefs = AndroidWebViewDOM.bridgeRefMap(
                            dom: added,
                            droppedA11y: StepExecutor.descendants(of: webView, in: snapshot.elements))
                    }
                    kept = WebViewDOM.droppingWebViewSubtree(snapshot.elements, webView: webView)
                }
                snapshot.elements = kept + added
            }
        }
        syncLocalState(from: snapshot)
        // IME は別プロセスの window でアプリの a11y ツリーに出ないため、オンデバイスのブリッジでは
        // 判定できずホスト側で dumpsys を引いて補う(AndroidForegroundWindows.keyboardVisible)。
        // dumpsys は固定費が大きいため毎 snapshot では叩かず、captureKeyboardStateOnNextSnapshot() で
        // 立てたときだけ払う(採らなかった snapshot は keyboardShown == nil = 不明のまま)
        if captureKeyboardOnNextSnapshot {
            captureKeyboardOnNextSnapshot = false
            if let dumpsys = try? adb(["shell", "dumpsys", "window", "windows"]).output {
                snapshot.keyboardShown = AndroidForegroundWindows.keyboardVisible(dumpsys: dumpsys)
            }
        }
        return snapshot
    }

    public func captureKeyboardStateOnNextSnapshot() {
        captureKeyboardOnNextSnapshot = true
    }

    public func raiseElementLimitOnNextSnapshot(_ max: Int?) {
        pendingElementLimit = max
    }

    /// システムロケールの永続変更(ブリッジ /locale。ブート完了後に呼ぶこと)。
    /// 既に一致していれば changed=false の no-op(フレームワーク再起動なし)
    public func setDeviceLocale(_ locale: String) async throws -> BridgeClient.DeviceLocaleResponse {
        try await withBridge { try await $0.setDeviceLocale(locale) }
    }

    public func tap(ref: Int) async throws {
        restoreStateIfNeeded()
        guard let center = refCenters[ref] else {
            throw DriverError.badResponse(status: 404, body: "unknown reference number [\(ref)]. Take a snapshot first")
        }
        try await tap(x: center.0, y: center.1)
    }

    public func tap(x: Double, y: Double) async throws {
        try await withBridge { try await $0.tap(x: x, y: y) }
    }

    public func clearInput(ref: Int?) async throws {
        restoreStateIfNeeded()
        let target = bridgeRef(ref)
        try await withBridge { try await $0.clearInput(ref: target) }
    }

    /// ホストの ref をブリッジが知っている ref へ写す(DOM 由来だけ差し替わる。domBridgeRefs 参照)。
    /// **タップ系は写さない** —— あちらは座標をホストが持っているので、写すと逆に古い a11y の
    /// 中心へ撃つことになる
    private func bridgeRef(_ ref: Int?) -> Int? {
        guard let ref else { return nil }
        return domBridgeRefs[ref] ?? ref
    }

    /// ソフトキーボードを閉じる(DSL の hideKeyboard)。ブリッジの /hidekeyboard
    /// (BridgeRouter.handleHideKeyboard、ESCAPE キー注入)経由。adb keyevent 直行にしない
    /// (back() と違い、ESCAPE は IME にだけ吸われる想定でアプリの画面遷移を起こさない)
    /// ソフトキーボードを閉じる。**ESCAPE は効かない**(2026-07-30 実機で確認。ブリッジの
    /// /hidekeyboard は撃っても IME が閉じない)ので、唯一効く BACK キーを使う。
    /// **BACK は出ていないときに撃つと画面が戻ってしまう**ため、必ず dumpsys で可視を確かめてから
    /// 撃つ(hideKeyboard は冪等が契約。出ていなければ no-op)
    public func hideKeyboard() async throws {
        guard let dumpsys = try? adb(["shell", "dumpsys", "window", "windows"]).output,
              AndroidForegroundWindows.keyboardVisible(dumpsys: dumpsys) else { return }
        let result = try adb(["shell", "input", "keyevent", "KEYCODE_BACK"])
        guard result.status == 0 else {
            throw DriverError.badResponse(status: Int(result.status),
                body: "failed to hide the keyboard: \(result.tail)")
        }
        await settleViaBridge()
    }

    /// ブリッジ snapshot の結果をホスト側 ref テーブルにも写す(CLI プロセス跨ぎの手動駆動を保つ)
    private func syncLocalState(from snapshot: SnapshotResponse) {
        var centers: [Int: (x: Double, y: Double)] = [:]
        for element in snapshot.elements {
            centers[element.ref] = (x: element.frame.centerX, y: element.frame.centerY)
        }
        refCenters = centers
        screen = snapshot.screen
        persistState()
    }

    public func type(ref: Int?, text: String) async throws {
        // ref は**ブリッジまで通す**(ホスト側で tap+ref:nil に分解しない)。分解すると
        // ブリッジは「フォーカス中のフィールドへ注入」(findFocus)しかできず、直前の scene で
        // 別フィールドがフォーカスを保持している+フォーカス遷移が負荷で遅れた実行で
        // 旧フィールドへ誤追記する(hello123secret42 事故)。ブリッジの ref 経路
        // (InputInjector.setTextAppendingAt)は「タップ点にある editable ノードそのもの」へ
        // SET_TEXT + 期限内リトライするため、誤爆が構造的に起きない。
        // v10-v12 のブリッジ側修正がここの分解のせいで一度も実行されていなかった。
        //
        // 末尾の改行1つは ACTION_SET_TEXT では文字として入るだけで IME アクションにならないため、
        // 分離して本文の SET_TEXT 後に Enter キーイベントを送る(pressEnter と同じ経路。文中の
        // 改行はそのまま文字として本文に残す)
        restoreStateIfNeeded()
        let target = bridgeRef(ref)
        let (main, hasTrailingNewline) = Self.splitTrailingNewline(text)
        do {
            guard hasTrailingNewline else {
                try await withBridge { try await $0.type(ref: target, text: text) }
                return
            }
            // 本文が空でも ref があれば SET_TEXT を通し、対象ノードへのフォーカス確立を維持する
            try await withBridge { try await $0.type(ref: target, text: main) }
        } catch let error as DriverError {
            throw Self.typeNoFocusAdvice(after: error, hadRef: ref != nil) ?? error
        }
        try await pressEnter()
    }

    /// **ref 無しの type がフォーカス不在で落ちたとき**の書き換え(純関数 = 単体テストで固定)。
    /// nil = そのままのエラーでよい。
    ///
    /// ブリッジの文面は「tap the field by ref first」だが、**その tap が効かなかったからここに来る**
    /// (2026-08-21 の受け手報告)。Android の入力欄は容器(TextInputLayout 等)と中身
    /// (TextInputEditText)に分かれることがあり、**容器を叩いても入力フォーカスは中身へ移らない** ——
    /// しかも容器のほうが id を持つので、`#id` を書くと容器に解決する。
    /// 読み手が次に打つ手が分かる形にする = **セレクタを取る `type` へ寄せる**
    /// (解決とフォーカスをツール側が引き受ける)。ref 付きで落ちた場合は別の話なので触らない
    static func typeNoFocusAdvice(after error: DriverError, hadRef: Bool) -> DriverError? {
        guard !hadRef, case .badResponse(let status, let body) = error,
              body.contains(noInputFocusMarker) else { return nil }
        return DriverError.badResponse(status: status, body: body
            + " — nothing was tapped into focus. On Android an input is often a container"
            + " (TextInputLayout) wrapping the editable field (TextInputEditText), and the id"
            + " usually sits on the container, so tapping it does not move input focus."
            + " Write type(<selector>, \"…\") instead: it resolves the editable field and"
            + " focuses it (e.g. type(\".textField[1]\", \"…\"))")
    }

    /// 末尾の改行1つだけを分離する(text 全体が "\n" のときは分離しない=本文なしの pressEnter 相当に
    /// 潰さない)。戻り値: (本文, 末尾に改行があったか)
    static func splitTrailingNewline(_ text: String) -> (String, Bool) {
        guard text != "\n", text.hasSuffix("\n") else { return (text, false) }
        return (String(text.dropLast()), true)
    }

    /// Enter キーを押す(フォーカス中の入力欄への IME アクション相当)。ブリッジの /pressEnter
    /// (ACTION_IME_ENTER)を優先する: ソフトキーボード表示中の View/XML EditText では keyevent 66
    /// が IME に吸われ OnEditorActionListener に届かない(Compose は独自のキーイベント処理経路の
    /// ため keyevent でも発火する。実機実測で確認済み)。404(旧ブリッジ未実装)/409(フォーカス無し
    /// 等)/501(API 30未満)は下のキーイベント経路へフォールバックする。bridgeConnectionRefused
    /// 等それ以外のエラーは握り潰さずそのまま投げる。
    /// ブリッジが「入力フォーカスが無い」と言うときの目印(InputInjector と同期。
    /// **文言ではなくこの接頭辞で判定する** —— 文言は英語化で変わる)
    static let noInputFocusMarker = "no-input-focus"

    /// ブリッジの pressEnter が失敗したあとの分岐(純関数 = 単体テストで固定する)。
    /// nil = キーイベントへフォールバックしてよい / 非 nil = このエラーで止める。
    ///
    /// **「フォーカスが無い」だけはフォールバックしない**(2026-08-07 実測)。
    /// 409 は2種類あり、「IME アクションが失敗」はキーイベントで救えるが、
    /// 「そもそも入力フォーカスが無い」は**誰も受け取らない**ので、生の Enter を
    /// 撃って成功を返すと沈黙した誤りになる(入力欄のタップに失敗したまま
    /// 検索が実行されず、原因から遠いところで落ちていた)。
    /// 目印はブリッジ側の `no-input-focus:` 接頭辞(InputInjector。文言は英語化で変わるので
    /// 接頭辞で判定する)
    static func pressEnterAbort(after error: DriverError) -> DriverError? {
        guard case .badResponse(let status, let body) = error,
              status == 404 || status == 409 || status == 501 else { return error }
        guard body.contains(noInputFocusMarker) else { return nil }
        return DriverError.badResponse(status: status,
            body: "pressEnter did nothing: no field has input focus."
                + " Tap the field by ref first (ft_type with ref does this for you)")
    }

    public func pressEnter() async throws {
        do {
            try await withBridge { try await $0.pressEnter() }
            return
        } catch let error as DriverError {
            if let abort = Self.pressEnterAbort(after: error) { throw abort }
        }
        // gRPC の名前付きキーは使わない(理由は home())。"Enter" は GoHome/AppSwitch と同じ
        // sendKey なので同型の無音 no-op になる — ここは成功が返ると adb へ落ちない救済経路で、
        // 失敗の型が沈黙(誤った成功)なので単独では再現していないが塞ぐ
        let result = try adb(["shell", "input", "keyevent", "66"])
        guard result.status == 0 else {
            throw DriverError.badResponse(status: Int(result.status),
                body: "failed to send the Enter key: \(result.tail)")
        }
        // keyevent は遷移完了を待たないため、直後の snapshot 用の整定待ち(home() と同様)。
        // ブリッジ経路はサーバ側 settle() 込みで応答するため不要
        await settleViaBridge()
    }

    public func swipe(_ direction: FTSwipeDirection) async throws {
        try await withBridge { try await $0.swipe(direction) }
    }

    /// 用途つき版。**Android は用途でジェスチャが変わる**(edge は強いフリング)ので、
    /// 既定実装に落として用途を捨ててはいけない。
    ///
    /// **端送り(edge)で中身が WebView なら、スワイプを1本も撃たずに CDP で飛ばす**
    /// (`AndroidWebViewDOM.scrollToEdge`。実測 28ms)。Android のスワイプは1本 ≒ 6 行しか
    /// 進まないので、長文では往復回数がそのまま所要になる(受け手の実文書で 19.2s)。
    /// iOS の in-app が `contentOffset` で同じことをしているのと揃える。
    /// **飛ばせなければ従来のジェスチャへ落ちる**(判定は1インスタンスにつき1回だけ試す)
    public func swipe(_ direction: FTSwipeDirection, intent: FTSwipeIntent,
                      path: FTSwipePath?) async throws {
        atEdgeOnLastSwipe = nil
        if intent == .edge, await webViewJumpToEdge(direction) { return }
        if intent == .edge, let stroke = edgeStroke(direction, path: path) {
            try await drag(fromX: stroke.fromX, fromY: stroke.fromY,
                           toX: stroke.toX, toY: stroke.toY,
                           pressSeconds: 0, durationSeconds: Self.edgeStrokeSeconds)
            return
        }
        try await withBridge { try await $0.swipe(direction, intent: intent, path: path) }
    }

    /// 端送りのストローク。**ブリッジの `/swipe` ではなく drag(注入器直結)で撃つ**理由は2つ:
    ///
    /// - **1本で進む距離が違う**(2026-08-20 実測・40 行リスト): `/swipe`(画面比 0.4 + fling)は
    ///   1本 **約 6 行**しか進まないのに、中央→端のストローク(0.25s)は **14 行**進む。
    ///   端送りは往復回数がそのまま所要になるので、ここが倍違うと所要も倍違う
    /// - **`/swipe` はブリッジ内で静穏を待ってから返す**(中央値 233ms)。ホストも同じ整定を
    ///   待つので二重になる。drag 経路はブリッジを通らないため、待ちはホストの1回だけになる
    ///
    /// **探索(search)には使わない** —— 1回の移動量がビューポートを超えると要素を飛び越す。
    /// 端送りは行き過ぎても端で止まるので安全(§3.16 と同じ線引き)
    private func edgeStroke(_ direction: FTSwipeDirection,
                            path: FTSwipePath?) -> FTSwipePath? {
        Self.edgeStroke(direction, path: path, screen: screen)
    }

    /// 上のストロークの決め方(I/O 抜き・単体テスト対象)
    static func edgeStroke(_ direction: FTSwipeDirection, path: FTSwipePath?,
                           screen: FTRect) -> FTSwipePath? {
        if let path { return path }   // 領域指定はホストが計算済み(ScrollGeometry)
        // 画面の大きさが分からないとき(snapshot 前)は ScrollGeometry が nil を返し、
        // 呼び手は従来の /swipe へ落ちる。**ここで別途ガードしない**(同じ判定を2箇所に置くと、
        // 変異テストで「殺せない条件」として残るだけで何も守らない)
        let kind: FlickKind
        switch direction {
        case .up: kind = .centerToTop
        case .down: kind = .centerToBottom
        case .left: kind = .centerToLeft
        case .right: kind = .centerToRight
        }
        return ScrollGeometry.flickPath(
            container: screen, viewport: screen, kind: kind,
            startMarginRatio: FTScrollDefaults.startMarginRatio(
                intent: .gesture, vertical: kind.isVertical))
    }

    /// 端送りストロークの所要(秒)。**flick の既定と同じ値**にしてある ——
    /// この値で「1本 14 行」を実測した(短くすると距離が伸びる可能性はあるが、
    /// §3.16 の較正をやり直す話になるので別立て)
    private static let edgeStrokeSeconds: Double = FlowStep.defaultFlickDurationSeconds

    /// CDP でページを端まで飛ばせたか。**使えないと分かったら以後は試さない**
    /// (ネイティブ画面で毎回 adb のソケット探索を払わないため。アプリが変わればやり直す)
    private func webViewJumpToEdge(_ direction: FTSwipeDirection) async -> Bool {
        guard AndroidWebViewDOM.isAppWebViewDOMEnabled,
              let package = currentPackage,
              webViewEdgeJumpUnavailableFor != package else { return false }
        let outcome = await AndroidWebViewDOM.scrollToEdge(
            serial: serial ?? "", packageID: package, route: .appWebView,
            finger: direction, adb: { try self.adb($0).output })
        guard let outcome else { webViewEdgeJumpUnavailableFor = package; return false }
        // **動かなかった = もう端**。ホストはこれを受けて署名の2回不変を待たずに切り上げる
        atEdgeOnLastSwipe = !outcome.moved
        return true
    }

    /// 直前の端送りで「もう端」と分かったか(`AppDriver.reachedEdgeOnLastSwipe`)
    public private(set) var atEdgeOnLastSwipe: Bool?
    public var reachedEdgeOnLastSwipe: Bool? { atEdgeOnLastSwipe }

    /// ダブルタップ・ピンチは**ブリッジ apk 経由だけ**(gRPC の道は作らない)。
    /// gRPC は `EmulatorController` = エミュレータ専用で実機に無く、一方 apk の
    /// `UiAutomation.injectInputEvent` は両方で動く。1操作の中で時間制約(ダブルタップ判定)や
    /// 多点の同期が要るので、実装を2本持つと差が出るところでもある
    public func doubleTap(x: Double, y: Double) async throws {
        try await withBridge { try await $0.doubleTap(x: x, y: y) }
    }

    public func pinch(frame: FTRect?, identifier: String?, scale: Double,
                      durationSeconds: Double) async throws {
        try await withBridge {
            try await $0.pinch(frame: frame, identifier: identifier, scale: scale,
                               durationSeconds: durationSeconds)
        }
    }

    // MARK: - Rotation (host-side adb; no bridge route — adb already does this without one)

    /// Captured only on this driver instance's first `rotate(to:)` call (nil = not used yet, or
    /// already restored). Auto-rotate must be off for `user_rotation` to stick, so both settings
    /// are captured/restored together, user_rotation before accelerometer_rotation (writing
    /// accelerometer back to auto=1 first would let physical/simulated tilt override the angle).
    private var originalRotationSettings: (userRotation: Int, accelerometerRotation: Int)?

    /// Android Surface.ROTATION_*。**どちらの landscape でもよい**(契約は「アプリの UI が
    /// 横になること」で、物理方向はテストから観測できないので約束しない。FTOrientation の宣言を参照)
    private static func androidRotation(for orientation: FTOrientation) -> Int {
        switch orientation {
        case .portrait: return 0
        case .landscape: return 1
        }
    }

    private func currentRotationSettings() throws -> (userRotation: Int, accelerometerRotation: Int) {
        let userRotation = Int((try adb(["shell", "settings", "get", "system", "user_rotation"])
            .output).trimmingCharacters(in: .whitespacesAndNewlines)) ?? 0
        let accel = Int((try adb(["shell", "settings", "get", "system", "accelerometer_rotation"])
            .output).trimmingCharacters(in: .whitespacesAndNewlines)) ?? 1
        return (userRotation, accel)
    }

    private static let rotationDeadlineSeconds: Double = 5.0

    public func rotate(to orientation: FTOrientation) async throws -> FTOrientation {
        if originalRotationSettings == nil {
            originalRotationSettings = try currentRotationSettings()
        }
        _ = try adb(["shell", "settings", "put", "system", "user_rotation",
                     String(Self.androidRotation(for: orientation))])
        _ = try adb(["shell", "settings", "put", "system", "accelerometer_rotation", "0"])
        let wantsLandscape = orientation != .portrait
        let deadline = Date().addingTimeInterval(Self.rotationDeadlineSeconds)
        while Date() < deadline {
            let screen = try await snapshot(bypassingCache: true).screen
            if (screen.width > screen.height) == wantsLandscape { return orientation }
            try await Task.sleep(nanoseconds: 300_000_000)
        }
        throw DriverError.badResponse(status: 422, body: "orientation did not settle to "
            + "\(orientation.rawValue) within \(Self.rotationDeadlineSeconds)s")
    }

    public func restoreOrientationIfNeeded() async throws {
        guard let original = originalRotationSettings else { return }
        originalRotationSettings = nil
        _ = try adb(["shell", "settings", "put", "system", "user_rotation",
                     String(original.userRotation)])
        _ = try adb(["shell", "settings", "put", "system", "accelerometer_rotation",
                     String(original.accelerometerRotation)])
    }

    /// 2点間ドラッグ。ブリッジ経由ではなく gRPC タッチ合成(down→補間 move→up)優先・
    /// adb input swipe フォールバック(どちらも snapshot と同じピクセル座標)。
    /// gRPC はゲスト内 app_process 起動(~300ms/回)が無くステップ列が高速。
    /// pressSeconds は対応がなく未使用。durationSeconds を duration(ms)へ変換し 50〜10000ms にクランプ。
    public func drag(fromX: Double, fromY: Double, toX: Double, toY: Double,
                     pressSeconds: Double, durationSeconds: Double) async throws {
        let durationMs = min(max(Int((durationSeconds * 1000).rounded()), 50), 10000)
        if let serial, await EmulatorControl.drag(serial: serial,
                                      fromX: Int32(fromX.rounded()), fromY: Int32(fromY.rounded()),
                                      toX: Int32(toX.rounded()), toY: Int32(toY.rounded()),
                                      durationMs: durationMs) {
            return
        }
        let result = try adb(["shell", "input", "swipe",
                              String(Int(fromX.rounded())), String(Int(fromY.rounded())),
                              String(Int(toX.rounded())), String(Int(toY.rounded())),
                              String(durationMs)])
        guard result.status == 0 else {
            throw DriverError.badResponse(status: Int(result.status),
                body: "drag failed: \(result.tail)")
        }
    }

    public func press(ref: Int, duration: Double) async throws {
        restoreStateIfNeeded()
        guard let center = refCenters[ref] else {
            throw DriverError.badResponse(status: 404, body: "unknown reference number [\(ref)]. Take a snapshot first")
        }
        // tap(ref:) と同じくホスト側で座標解決してブリッジへは x/y で送る(ブリッジ再起動で
        // ブリッジ側 ref 表だけが消えてもずれない。注入経路は従来と同じ InputInjector.press)。
        // ブリッジ v8 以降が前提(v7 は /press が ref 必須。probe の版照合で自動更新される)
        try await withBridge { try await $0.press(x: center.x, y: center.y, duration: duration) }
    }

    /// 座標ロングプレス。gRPC タッチ(down→保持→up)優先・同一点 input swipe フォールバック。
    public func press(x: Double, y: Double, duration: Double) async throws {
        let durationMs = min(max(Int((duration * 1000).rounded()), 300), 10000)
        if let serial, await EmulatorControl.longPress(serial: serial, x: Int32(x.rounded()),
                                           y: Int32(y.rounded()), durationMs: durationMs) {
            return
        }
        let px = String(Int(x.rounded()))
        let py = String(Int(y.rounded()))
        let result = try adb(["shell", "input", "swipe", px, py, px, py, String(durationMs)])
        guard result.status == 0 else {
            throw DriverError.badResponse(status: Int(result.status),
                body: "long-press failed: \(result.tail)")
        }
    }

    public func screenshot() async throws -> Data {
        let device = try await withBridge { try await $0.screenshot() }
        return await webViewComposited(device) ?? device
    }

    /// **端末のキャプチャが WebView の層を取り逃したときだけ**、CDP から撮ったページ画像を
    /// その領域へ貼って返す(何が起きているかと実測は WebViewShotComposite の冒頭)。
    /// 貼れない・貼る必要が無いときは nil = 端末の画像をそのまま使う。
    ///
    /// 順序は**安い順**: ①画像に全幅の大きな1色の帯があるか(数ミリ秒。通常の画面はここで終わる)
    /// → ②木を読んで `webView` の矩形を採る → ③CDP でページを撮る → ④貼れる形なら貼る。
    ///
    /// **貼る位置は木の `webView` ノードを優先し、無ければ帯**(2026-08-20 の受け手報告で修正)。
    /// 当初は帯だけで決めていたが、**アプリの chrome ごと写らずに画面全体が1色になる端末**では
    /// 帯 = 画面全体になり、ページ画像と縦横比が合わず**1枚も貼れなかった**。
    /// ノードがあれば「どこからどこまでが WebView か」が分かるので、その矩形へ貼る。
    /// ノードが出ないことも実際にある(同じ画面で「木に居る/居ない」の両方を実測)ので、
    /// その場合だけ帯へ落ち、**縦横比がほぼ一致するときに限って**貼る
    private func webViewComposited(_ devicePNG: Data) async -> Data? {
        guard AndroidWebViewDOM.isAppWebViewDOMEnabled,
              let base = WebViewShotComposite.cgImage(fromPNG: devicePNG),
              let band = WebViewShotComposite.largestUniformBand(base) else { return nil }
        let snapshot = try? await snapshot()
        guard let package = snapshot?.sessionBundleID ?? currentPackage else { return nil }
        // 木の webView ノード(あれば正確な矩形)。無ければ帯で代用する
        let nodeRect = snapshot.flatMap { tree -> CGRect? in
            guard let node = WebViewDOM.webViewElement(in: tree.elements) else { return nil }
            return WebViewShotComposite.imageRect(
                frame: (node.frame.x, node.frame.y, node.frame.width, node.frame.height),
                screen: (tree.screen.width, tree.screen.height),
                imageWidth: base.width, imageHeight: base.height)
        }
        guard let pagePNG = await AndroidWebViewDOM.capturePagePNG(
                serial: serial ?? "", packageID: package, route: .appWebView,
                webViewLabel: nil, urlBarValue: nil, adb: { try self.adb($0).output }),
              let overlay = WebViewShotComposite.cgImage(fromPNG: pagePNG),
              let rect = WebViewShotComposite.pasteRect(
                in: nodeRect ?? band, pageWidth: overlay.width, pageHeight: overlay.height,
                known: nodeRect != nil) else {
            warnBlankCaptureOnce(package: package, hasWebViewNode: nodeRect != nil)
            return nil
        }
        return WebViewShotComposite.composite(base: base, overlay: overlay, rect: rect)
    }

    /// 補えなかったことを serial ごとにプロセスで1回だけ知らせる(毎枚出すと騒がしい)。
    /// 文言と切り分け方は WebViewShotComposite.blankCaptureWarning、
    /// once の置き場が static である理由は shouldWarnBlankCapture
    private func warnBlankCaptureOnce(package: String, hasWebViewNode: Bool) {
        let serial = serial ?? "default"
        guard WebViewShotComposite.shouldWarnBlankCapture(serial: serial) else { return }
        // 理由の引き直しは once の内側 = serial ごとに adb 1往復だけ
        let reason: WebViewShotComposite.BlankCaptureReason
        switch AndroidWebViewDOM.appSocketResolution(packageID: package, adb: { try self.adb($0).output }) {
        case .socket: reason = .captureFailed
        case .noWebView: reason = .noDevtoolsSocket
        case .appNotRunning: reason = .appNotRunning
        case .ambiguous(let names): reason = .undetermined("several candidate sockets: \(names.joined(separator: ", "))")
        case .unavailable: reason = .undetermined("adb could not list the sockets")
        }
        let text = WebViewShotComposite.blankCaptureWarning(
            serial: serial, hasWebViewNode: hasWebViewNode, reason: reason)
        FileHandle.standardError.write(Data((text + "\n").utf8))
    }

    public func terminate() async throws {
        restoreStateIfNeeded()
        if let package = currentPackage {
            _ = try adb(["shell", "am", "force-stop", package])
            currentPackage = nil
            persistState()  // 消さないと別プロセスの再 terminate が古い package を force-stop する
        }
    }

    /// インストール済み APK が apkPath と同一内容か(adb install は base.apk をそのままコピーする
    /// ため md5 一致で判定できる。autoInstall の差分スキップ用)。未インストール・判定不能は
    /// false(=要インストール)。
    public func installedPackageIsCurrent(packageID: String, apkPath: String) -> Bool {
        if ApksBundle.isApks(path: apkPath) {
            return installedSplitsAreCurrent(packageID: packageID, apksPath: apkPath)
        }
        guard let pathResult = try? adb(["shell", "pm", "path", packageID]),
              pathResult.status == 0 else { return false }
        guard let remote = pathResult.output.split(separator: "\n")
            .first(where: { $0.hasPrefix("package:") })
            .map({ String($0.dropFirst("package:".count)).trimmingCharacters(in: .whitespaces) }),
            !remote.isEmpty else { return false }
        guard let md5Result = try? adb(["shell", "md5sum", remote]), md5Result.status == 0,
              let remoteHash = md5Result.output.split(separator: " ").first.map(String.init) else {
            return false
        }
        guard let localData = try? Data(contentsOf: URL(fileURLWithPath: apkPath)) else { return false }
        let localHash = Insecure.MD5.hash(data: localData).map { String(format: "%02x", $0) }.joined()
        return remoteHash.lowercased() == localHash
    }

    /// .apks 版の差分判定: 端末に入っている base/split の全ファイルがこの .apks のエントリ由来か
    /// (規則と限界は ApksBundle.installedIsFromBundle)
    private func installedSplitsAreCurrent(packageID: String, apksPath: String) -> Bool {
        let entries = ApksBundle.listEntries(apksPath: apksPath)
        guard !entries.isEmpty else { return false }
        guard let probe = try? adb(["shell", ApksBundle.installedFilesScript(packageID: packageID)]),
              probe.status == 0,
              let installed = ApksBundle.parseInstalledFiles(probe.output) else { return false }
        return ApksBundle.installedIsFromBundle(installed: installed, entries: entries) {
            ApksBundle.entryMD5(apksPath: apksPath, entry: $0)
        }
    }

    /// インストール済みのユーザーアプリ(third-party)のパッケージ名一覧。
    public func listInstalledPackages() throws -> [String] {
        try packageIDs(scope: "-3")
    }

    public struct InstalledPackage: Sendable, Equatable {
        public let id: String
        public let isUser: Bool

        public init(id: String, isUser: Bool) {
            self.id = id
            self.isUser = isUser
        }
    }

    /// **system も引けるようにする**: 端末に載っている地図・ブラウザ等は
    /// system 扱いで `-3` には1つも出ず、MCP から探しようが無かった(実測: Pixel の AVD で
    /// `com.google.android.apps.maps` が出ず adb へ落ちた)。`pm` は `-3` か `-s` の
    /// どちらかしか出せないので2回撃つ。**system アプリに更新が当たると `-s` 側にだけ出る**ので、
    /// 同じ id が両方に出たときは user を採る(利用者から見て「自分で入れた物」に近い)
    public func listPackages(includeSystem: Bool) throws -> [InstalledPackage] {
        let user = try packageIDs(scope: "-3").map { InstalledPackage(id: $0, isUser: true) }
        guard includeSystem else { return user }
        let userIDs = Set(user.map(\.id))
        let system = try packageIDs(scope: "-s")
            .filter { !userIDs.contains($0) }
            .map { InstalledPackage(id: $0, isUser: false) }
        return (user + system).sorted { $0.id < $1.id }
    }

    private func packageIDs(scope: String) throws -> [String] {
        let result = try adb(["shell", "pm", "list", "packages", scope])
        return result.output.split(separator: "\n")
            .compactMap { line in
                let trimmed = line.trimmingCharacters(in: .whitespaces)
                return trimmed.hasPrefix("package:") ? String(trimmed.dropFirst("package:".count)) : nil
            }
            .sorted()
    }

}
