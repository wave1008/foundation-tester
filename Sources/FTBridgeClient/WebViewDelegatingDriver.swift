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
    /// この委譲区間で Web コンテンツを一度でも観測したか。
    /// XCUITest 側は WebView の AX 活性化に時間がかかる(実測 約2.3秒)ので初回だけ待つ。
    /// 一度見えたら待たない(空ページや全要素が画面外の画面で毎ステップ待たされないため)
    private var sawWebContent = false

    private var note: String?

    /// Web コンテンツが現れるまでの初回待ち。実測 2.3s に対し余裕を持たせる
    private static let contentWaitMs = 5000
    private static let contentPollMs = 250

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
            } else {
                mode = .normal
                domFrames = [:]
            }
            sawWebContent = false
            note = nil
            return inapp
        }

        mode = .delegated
        domFrames = [:]
        note = "WebView screen — delegated to XCUITest"
        var snapshot = try await delegated.snapshot(bypassingCache: bypassingCache)
        // 経路は**返した本人が名乗る**(StepExecutor が失敗文言に添える。要素の形から
        // 推測させると Android が「XCUITest へ委譲」を名乗る事故になる)
        snapshot.webViewPath = "delegated"
        guard !sawWebContent else { return snapshot }

        var waited = 0
        while !Self.hasWebContent(snapshot), waited < Self.contentWaitMs {
            try await Task.sleep(for: .milliseconds(Self.contentPollMs))
            waited += Self.contentPollMs
            snapshot = try await delegated.snapshot()
            snapshot.webViewPath = "delegated"
        }
        if Self.hasWebContent(snapshot) { sawWebContent = true }
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
    public func type(ref: Int?, text: String) async throws {
        guard mode == .domInterop else { try await screenDriver.type(ref: ref, text: text); return }
        if let ref {
            let p = try domInteropPoint(ref: ref)
            try await delegated.tap(x: p.x, y: p.y)
        }
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
    public func clearAppData(bundleID: String) async throws {
        try await primary.clearAppData(bundleID: bundleID)
    }
    public func status() async throws -> StatusResponse { try await primary.status() }
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
    /// launch は常に primary(in-app)固定(launch(bundleID:) 参照)。screenDriver/mode の状態には無関係
    public var lastLaunchTiming: LaunchTiming? { primary.lastLaunchTiming }
}
