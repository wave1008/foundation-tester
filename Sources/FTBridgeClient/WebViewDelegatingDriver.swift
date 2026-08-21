// hybrid で WebView 画面だけを XCUITest(対象アプリへ attach)へ委譲するデコレータ。
//
// in-app は WKWebView の中身を a11y ツリーからは採れない(Web コンテンツの AX は WebContent
// プロセスが提供し、プロセス内走査では届かない)。uikit ホストでは in-app が DOM を JS で読んで
// 埋めるので委譲は不要。3つ目のモードとして、Compose/Flutter(interop)ホストでも in-app は
// DOM を読めるが、interop が合成タッチ/insertText を横取りするため**操作だけ**
// XCUITest の実タッチへ回す(座標指定。ref は渡さない)。DOM が全く読めない構成(JS 評価失敗・
// 未ロード・旧 dylib)だけが画面ごとの委譲(delegated)に残る。
//
// 画面ごとの委譲は高い(1手 3ms → 378ms)ので、**必要なときだけ**行うのがこのクラスの役目。
//
// **返す snapshot と ref の名前空間は常に一致させる**のが不変条件: delegated 中は XCUITest の
// snapshot を返し、ref を使う操作も XCUITest へ送る。domInterop 中は in-app の snapshot を返すが、
// ref を使う操作は**座標へ解決してから** delegated へ送る — delegated には ref を一切渡さない
// (delegated 側は自分が最後に撮った別の snapshot の ref 名前空間を持っており、in-app の ref を
// そのまま渡すと無関係の要素を指す)。混ぜると ref が別要素を指す。

import Foundation
import FTCore

public final class WebViewDelegatingDriver: AppDriver {
    /// in-app(既定の主経路)
    private let primary: AppDriver
    /// 対象アプリに attach した XCUITest。WebView 画面/domInterop の操作のあいだだけ主役になる
    private let delegated: AppDriver

    private enum WebViewMode: Equatable {
        case normal      // 通常画面、または in-app が DOM 全体を読めている(webViewPath == "dom")
        case delegated   // 画面ごと XCUITest へ委譲(DOM が読めない構成)
        case domInterop  // snapshot は in-app の DOM、ref を使う操作だけ座標で XCUITest へ回す
    }
    /// 直近 snapshot の分類。ref を使う操作の宛先/解決方法はこれで決まる
    private var mode: WebViewMode = .normal
    /// domInterop の直近 snapshot の ref→frame(画面座標)。domInteropPoint がここから中心点を
    /// 引く。snapshot のたびに丸ごと差し替える(古い ref を残すと存在しない要素を指しかねない)
    private var domFrames: [Int: FTRect] = [:]
    /// domInterop の ref→value。**type の読み返しにだけ使う**(入力前後の比較)。
    /// **値を報告しない要素は nil のまま持つ**(空文字と同一視すると、value を持たない
    /// フィールドが「入力前後で不変」に見えて毎回二重入力になる。既存テストが検出した)
    private var domValues: [Int: String?] = [:]
    /// この委譲区間で Web コンテンツを一度でも観測したか。
    /// XCUITest 側は WebView の AX 活性化に時間がかかる(実測 約2.3秒)ので初回だけ待つ。
    /// 一度見えたら待たない(空ページや全要素が画面外の画面で毎ステップ待たされないため)
    private var sawWebContent = false

    private var note: String?

    /// Web コンテンツが現れるまでの初回待ちの**上限**。XCUITest 側の WebView AX 活性化は
    /// **Simulator の実測 2.3s** で、これはそれに余裕を持たせた値。
    /// **hybrid は実機でも動く**ので、この上限が実機で足りる保証は無い ——
    /// だから尽きたときは黙らず `WebViewPath.delegatedEmpty` を名乗る(2026-08-15)。
    /// 名乗らないと「AX がまだ出ていない空の木」と「本当に空のページ」が区別できず、
    /// 否定アサーションが誤って通り、肯定側は「見つからない」で誤誘導される
    private static let contentWaitMs = 5000
    private static let contentPollMs = 250

    /// 委譲中であることの申告(失敗文言・記録に出る)。空のまま尽きた回はこれに理由を足す
    private static let delegatedNote = "WebView screen — delegated to XCUITest"

    public init(primary: AppDriver, delegated: AppDriver) {
        self.primary = primary
        self.delegated = delegated
    }

    // MARK: - 画面の帰属を決める snapshot

    public func snapshot() async throws -> SnapshotResponse {
        try await snapshot(bypassingCache: false)
    }

    /// キャッシュ捨ての申告は**そのとき snapshot を撮る側**に従う(normal/domInterop は primary、
    /// delegated は delegated)。mode は直前の snapshot が決めているので、arm の判断と実際の
    /// 取得元は一致する
    public var supportsCacheBypass: Bool {
        mode == .delegated ? delegated.supportsCacheBypass : primary.supportsCacheBypass
    }
    /// **どちらの経路でも同じ端末**なので mode を見ない(委譲へ落ちた回だけ床が変わるのを防ぐ)
    public var pointScale: Double { primary.pointScale }

    /// **両方へ立てる**(supportsCacheBypass と違い、こちらは撮る前に決める必要がある):
    /// mode は「直前の snapshot」が決めた値で、次の1回がどちらから読まれるかは
    /// 委譲判定を通るまで分からない。片方だけに立てると、委譲へ落ちた回で黙って 120 に戻る。
    /// 立てたまま使われなかった側は次の snapshot で消費されるだけ(無害)
    public func raiseElementLimitOnNextSnapshot(_ max: Int?) {
        primary.raiseElementLimitOnNextSnapshot(max)
        delegated.raiseElementLimitOnNextSnapshot(max)
    }
    /// domInterop はここでも primary(false)扱いにする: この区間の type() は「値が変わっていない」
    /// ときだけ1回張り直す簡易チェックしか持たず(下の type() 参照)、TypeReadback.plan の
    /// resend/deleteExcess 相当は持たない。StepExecutor の読み返しを重ねても安全側(検証不能なら
    /// 受理するだけ)なので、無理に true を申告しない
    public var verifiesTypedText: Bool {
        mode == .delegated ? delegated.verifiesTypedText : primary.verifiesTypedText
    }

    /// **モード判定は必ずこちらに置く** —— snapshot() を素通し側にすると片方だけ mode/domFrames を
    /// 更新せず、ref の名前空間の不変条件(冒頭注記)が崩れる。
    /// 既定実装に任せてもフラグが落ちて最内へ届かない
    /// (SnapshotCacheBypassForwardingTests がラッパー全体でこれを守る)
    public func snapshot(bypassingCache: Bool) async throws -> SnapshotResponse {
        let inapp = try await primary.snapshot(bypassingCache: bypassingCache)
        // in-app が DOM 経路で中身まで読めていれば画面ごとの委譲はしない(委譲すると 3ms →
        // 378ms になる)。読めないのは JS 無効・評価失敗・未ロード・旧 dylib のとき。
        // **判定は web フラグ**(幾何だと WebView と同じ矩形の interop 容器を中身と誤認する)
        guard inapp.elements.contains(where: { $0.type == Self.webViewType }),
              !inapp.elements.contains(where: { $0.web == true }) else {
            // WebView 画面を離れた / in-app で読めている。webViewPath がブリッジの自己申告
            // (ホストはフレームワーク固有の知識を持たない) — "dom-interop" なら操作だけ座標で
            // XCUITest へ回すモードに入る。それ以外(nil/"dom")は通常どおり primary 一本
            if inapp.webViewPath == "dom-interop" {
                // **この区間で初めて委譲側を使う前に1回だけ暖める**。旧経路は必ず
                // delegated.snapshot() を通っており、それが attach と WebView の AX 活性化を
                // 兼ねていた。省くと最初の座標タップが 200 を返しても実際には効かないことがある
                // (CMP で再現)。1画面あたり1回だけなので DOM 経路の利得は保たれる
                if mode != .domInterop { _ = try? await delegated.snapshot() }
                mode = .domInterop
                domFrames = Dictionary(uniqueKeysWithValues: inapp.elements.map { ($0.ref, $0.frame) })
                // 値も控える: type の読み返し(下記 type の注記)で「入力前の値」を比べるため
                domValues = Dictionary(uniqueKeysWithValues: inapp.elements.map { ($0.ref, $0.value) })
            } else {
                mode = .normal
                domFrames = [:]
                domValues = [:]
            }
            sawWebContent = false
            note = nil
            return inapp
        }

        mode = .delegated
        domFrames = [:]
        note = Self.delegatedNote
        var snapshot = try await delegated.snapshot(bypassingCache: bypassingCache)
        // 経路は**返した本人が名乗る**(StepExecutor が失敗文言に添える。要素の形から
        // 推測させると Android が「XCUITest へ委譲」を名乗る事故になる)
        snapshot.webViewPath = WebViewPath.delegated
        // offscreen ヒントは純 xcuitest エンジン限定にする: hybrid の WebView スクロールは
        // in-app の contentOffset 短絡が既に速く(実測 scrollToTop 1.5s)、ヒントが乗ると
        // StepExecutor の跳躍(実ドラッグ)が優先されて計測済みの挙動が変わる(2026-08-04)
        snapshot.offscreen = nil
        guard !sawWebContent else { return snapshot }

        var waited = 0
        while !Self.hasWebContent(snapshot), waited < Self.contentWaitMs {
            try await Task.sleep(for: .milliseconds(Self.contentPollMs))
            waited += Self.contentPollMs
            snapshot = try await delegated.snapshot()
            snapshot.webViewPath = WebViewPath.delegated
            snapshot.offscreen = nil
        }
        if Self.hasWebContent(snapshot) {
            sawWebContent = true
        } else {
            // **待ちを使い切ったことを木に載せる**(判定は変えない): 木からは「AX がまだ出ていない」と
            // 「本当に空のページ」を区別できないので失敗にはしないが、黙って空の木を返すと
            // 不在アサーションがそれを根拠に通ってしまう。StepExecutor が注記と失敗文言に使う
            snapshot.webViewPath = WebViewPath.delegatedEmpty
            note = Self.delegatedNote
                + " (it produced no content within \(Self.contentWaitMs)ms, so an absence here is not evidence)"
        }
        return snapshot
    }

    static let webViewType = "webView"

    /// webView の矩形の中に、webView 以外の要素が1つでも入っているか。
    /// Web コンテンツの AX が起きる前は WebView が「中身のない箱」として出るため、これで待ちを打ち切る
    static func hasWebContent(_ snapshot: SnapshotResponse) -> Bool {
        let webViews = snapshot.elements.filter { $0.type == webViewType }
        guard !webViews.isEmpty else { return false }
        return snapshot.elements.contains { element in
            guard element.type != webViewType else { return false }
            return webViews.contains { intersects($0.frame, element.frame) }
        }
    }

    private static func intersects(_ a: FTRect, _ b: FTRect) -> Bool {
        a.x < b.x + b.width && b.x < a.x + a.width
            && a.y < b.y + b.height && b.y < a.y + a.height
    }

    // MARK: - 委譲中/domInterop 中だけ XCUITest へ回す操作(画面に触るもの)

    private var screenDriver: AppDriver {
        switch mode {
        case .normal: return primary
        case .delegated, .domInterop: return delegated
        }
    }

    /// domInterop の ref を画面座標(矩形中心)へ解決する。**delegated には x/y だけを渡す**
    /// (ref の名前空間が違う — このクラス冒頭の不変条件参照)。直近 snapshot に無い ref は
    /// 座標に解決できない = 黙って別経路へ流さずここで落とす(Android の未知 ref と同じ規約:
    /// Sources/FTAndroid/AndroidDriver.swift の badResponse(status: 404, ...) と同じ文言規約)
    private func domInteropPoint(ref: Int) throws -> (x: Double, y: Double) {
        guard let frame = domFrames[ref] else {
            throw DriverError.badResponse(status: 404,
                                          body: "unknown reference number [\(ref)]. Take a snapshot first")
        }
        return (frame.centerX, frame.centerY)
    }

    public func tap(ref: Int) async throws {
        guard mode == .domInterop else { try await screenDriver.tap(ref: ref); return }
        let p = try domInteropPoint(ref: ref)
        try await delegated.tap(x: p.x, y: p.y)
    }
    public func tap(x: Double, y: Double) async throws { try await screenDriver.tap(x: x, y: y) }
    /// domInterop の入力は「座標タップでフォーカス → フォーカス中要素へ typeText」なので、
    /// **タップがフォーカスを立て損なうと打鍵が丸ごと落ちる**(値が空のまま。実測 2026-08-04:
    /// E2E-CMP の WebView シナリオが 4/78 でこれを踏み、後段の検証だけが落ちていた)。
    /// DOM は `value` を返せるので**読み返して1回だけ張り直す**。
    /// **判定は「値が入力前から1文字も変わっていない」ときだけ**にする —— 「期待した文字列を
    /// 含まない」で判定すると、入力を加工するフィールド(大文字化・書式化)で二重入力になる
    /// (Android の SET_TEXT で踏んだ二重追記と同じ型。docs/design.md §Android のテキスト注入の規律)
    public func type(ref: Int?, text: String) async throws {
        guard mode == .domInterop else { try await screenDriver.type(ref: ref, text: text); return }
        guard let ref else {
            try await delegated.type(ref: nil, text: text)
            return
        }
        let point = try domInteropPoint(ref: ref)
        let before = domValues[ref]
        try await delegated.tap(x: point.x, y: point.y)
        try await delegated.type(ref: nil, text: text)
        // **値を報告する要素だけ**読み返す(報告しない要素は検証不能 = 従来どおり撃ちっぱなし。
        // ここを空文字で代用すると、value を持たない要素で毎回二重入力になる)
        guard !text.isEmpty, let before, before != nil else { return }
        // 読み返しは DOM の再取得(in-app 経路。実測 1手 3ms 級なので正常系でも重くない)
        _ = try await snapshot()
        guard let after = domValues[ref], after != nil, after == before else { return }
        note = "the typed text did not reach the WebView field; tapped and typed again"
        try await delegated.tap(x: point.x, y: point.y)
        try await delegated.type(ref: nil, text: text)
    }
    public func pressEnter() async throws { try await screenDriver.pressEnter() }
    public func clearInput(ref: Int?) async throws {
        guard mode == .domInterop else { try await screenDriver.clearInput(ref: ref); return }
        if let ref {
            let p = try domInteropPoint(ref: ref)
            try await delegated.tap(x: p.x, y: p.y)
        }
        try await delegated.clearInput(ref: nil)
    }
    public func hideKeyboard() async throws { try await screenDriver.hideKeyboard() }
    public func swipe(_ direction: FTSwipeDirection) async throws {
        try await screenDriver.swipe(direction)
    }
    /// 用途つき版。**delegated/domInterop 中でもスクロール目的だけは in-app を先に試す**:
    /// WKWebView の中の WKScrollView は contentOffset で動かせるので、XCUITest の実スワイプ
    /// (1回 ≒ 450ms、直後の委譲 snapshot も 300ms)を丸ごと省ける。効かない構成なら in-app が
    /// 501 を返すので従来どおり XCUITest へ落とす。
    ///
    /// **ref を使わない操作なので名前空間の不変条件は崩れない**(このクラスの冒頭注記の例外は
    /// ここだけ。ref を伴う操作を同じ理屈で in-app へ回してはいけない)。
    /// intent が `.gesture`(DSL の `swipe` = ジェスチャ自体が目的)は従来どおり委譲先へ送る:
    /// in-app は interop のジェスチャを駆動できない。
    public func swipe(_ direction: FTSwipeDirection, intent: FTSwipeIntent,
                      path: FTSwipePath?) async throws {
        guard mode != .normal, intent != .gesture else {
            try await screenDriver.swipe(direction, intent: intent, path: path)
            return
        }
        do {
            try await primary.swipe(direction, intent: intent, path: path)
        } catch {
            guard DriverError.isEngineIncapable(error) else { throw error }
            try await delegated.swipe(direction, intent: intent, path: path)
        }
    }
    public func press(ref: Int, duration: Double) async throws {
        guard mode == .domInterop else { try await screenDriver.press(ref: ref, duration: duration); return }
        let p = try domInteropPoint(ref: ref)
        try await delegated.press(x: p.x, y: p.y, duration: duration)
    }
    public func press(x: Double, y: Double, duration: Double) async throws {
        try await screenDriver.press(x: x, y: y, duration: duration)
    }
    public func drag(fromX: Double, fromY: Double, toX: Double, toY: Double,
                     pressSeconds: Double, durationSeconds: Double) async throws {
        try await screenDriver.drag(fromX: fromX, fromY: fromY, toX: toX, toY: toY,
                                    pressSeconds: pressSeconds, durationSeconds: durationSeconds)
    }

    /// 多点・座標ジェスチャは WebView の中でも画面側(screenDriver)が撃つ(drag と同じ理由。
    /// DOM 側に相当する口が無い)
    public func doubleTap(x: Double, y: Double) async throws {
        try await screenDriver.doubleTap(x: x, y: y)
    }

    public func pinch(frame: FTRect?, identifier: String?, scale: Double,
                      durationSeconds: Double) async throws {
        try await screenDriver.pinch(frame: frame, identifier: identifier, scale: scale,
                                     durationSeconds: durationSeconds)
    }

    // MARK: - 常に in-app 側で扱う操作

    // ライフサイクルは注入起動を持つ in-app 側の責務(XCUITest から起動すると dylib が入らない)。
    // 画面が変わるので委譲状態はここで畳む
    public func launch(bundleID: String) async throws {
        resetDelegation()
        try await primary.launch(bundleID: bundleID)
    }
    public func activate(bundleID: String) async throws {
        resetDelegation()
        try await primary.activate(bundleID: bundleID)
    }
    public func terminate() async throws {
        resetDelegation()
        try await primary.terminate()
    }
    public func install(packagePath: String) async throws {
        try await primary.install(packagePath: packagePath)
    }
    public func uninstall(bundleID: String) async throws {
        try await primary.uninstall(bundleID: bundleID)
    }
    public func clearAppData(bundleID: String) async throws {
        try await primary.clearAppData(bundleID: bundleID)
    }
    /// URL 配送は画面遷移を伴う起動系操作なので launch/activate と同じ扱い(primary=in-app 固定・
    /// 委譲状態をリセット)。in-app 側がブリッジ死活の probe と注入起動フォールバックを自分で持つ。
    ///
    /// **初回確認アラートの同意だけは delegated(XCUITest attach)側でも試す**: primary(in-app)は
    /// 自分の bundle 以外の /session を張れないため springboard を見られず、その同意ベストエフォートは
    /// 必ず 409 で何もしないまま終わる(BridgeClient.acknowledgeOpenURLConsent 参照)。delegated は
    /// XCUITest 接続なので springboard を見られる。二重に試しても
    /// OpenURLConsentAttemptCache が (target, bundleID) 単位で防ぐので無駄打ちにはならない
    public func openURL(_ url: String, bundleID: String?) async throws {
        resetDelegation()
        try await primary.openURL(url, bundleID: bundleID)
        if let bundleID {
            await delegated.acknowledgeOpenURLConsentIfPresent(bundleID: bundleID)
        }
    }
    /// primary(in-app)は springboard を見られないので delegated(XCUITest attach)側も試す。
    /// 実際の操作は BridgeClient 側が (デバイス, bundleID) ごとに1回だけ行う
    public func acknowledgeOpenURLConsentIfPresent(bundleID: String) async {
        await primary.acknowledgeOpenURLConsentIfPresent(bundleID: bundleID)
        await delegated.acknowledgeOpenURLConsentIfPresent(bundleID: bundleID)
    }
    public func status() async throws -> StatusResponse { try await primary.status() }
    // WebView 委譲モードと無関係な状態照会なので primary 固定(status() と同じ扱い)
    public func isAppForeground(bundleID: String) async throws -> Bool {
        try await primary.isAppForeground(bundleID: bundleID)
    }
    public func foregroundAppID() async throws -> String? { try await primary.foregroundAppID() }
    public func systemAlert() async throws -> SystemAlertProbeResponse? { try await primary.systemAlert() }
    // Unrelated to WebView delegation mode, same as status()/isAppForeground — primary 固定
    public func rotate(to orientation: FTOrientation) async throws -> FTOrientation {
        try await primary.rotate(to: orientation)
    }
    public func restoreOrientationIfNeeded() async throws {
        try await primary.restoreOrientationIfNeeded()
    }
    /// 画面を離れる操作。in-app は 501 を返すので XCUITest 側で行う(委譲状態は畳む)
    public func home() async throws {
        resetDelegation()
        try await delegated.home()
    }
    public func openAppSwitcher() async throws {
        resetDelegation()
        try await delegated.openAppSwitcher()
    }
    public func back() async throws {
        resetDelegation()
        try await delegated.back()
    }
    /// スクリーンショットは同じ画面を写すので安い in-app 側で撮る(WKWebView の描画も写る)
    public func screenshot() async throws -> Data { try await primary.screenshot() }

    private func resetDelegation() {
        mode = .normal
        domFrames = [:]
        sawWebContent = false
        note = nil
    }

    /// 委譲中は自分の注記を優先し、無ければ実行したドライバのものを透過する
    public var lastActionNote: String? { note ?? screenDriver.lastActionNote }
    public var reachedEdgeOnLastSwipe: Bool? { screenDriver.reachedEdgeOnLastSwipe }
    /// launch は常に primary(in-app)固定(launch(bundleID:) 参照)。screenDriver/mode の状態には無関係
    public var lastLaunchTiming: LaunchTiming? { primary.lastLaunchTiming }
}
