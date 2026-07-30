// hybrid で WebView 画面だけを XCUITest(対象アプリへ attach)へ委譲するデコレータ。
//
// in-app は WKWebView の中身を a11y ツリーからは採れない(Web コンテンツの AX は WebContent
// プロセスが提供し、プロセス内走査では届かない)。uikit ホストでは in-app が DOM を JS で読んで
// 埋めるので委譲は不要。**それができない構成だけ**をここで XCUITest へ回す:
// Compose / Flutter ホスト(interop がタッチと入力を横取りする)・JS 評価失敗・未ロード・旧 dylib。
//
// 委譲は高い(1手 3ms → 378ms)ので、**必要なときだけ**行うのがこのクラスの役目。
//
// **返す snapshot と ref の名前空間は常に一致させる**のが不変条件: 委譲中は XCUITest の
// snapshot を返し、ref を使う操作も XCUITest へ送る。混ぜると ref が別要素を指す。

import Foundation
import FTCore

public final class WebViewDelegatingDriver: AppDriver {
    /// in-app(既定の主経路)
    private let primary: AppDriver
    /// 対象アプリに attach した XCUITest。WebView 画面のあいだだけ主役になる
    private let delegated: AppDriver

    /// 直近 snapshot が WebView 画面だったか。ref を使う操作の宛先はこれで決まる
    private var delegating = false
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
        let inapp = try await primary.snapshot()
        // in-app が DOM 経路で中身まで読めていれば委譲しない(委譲すると 3ms → 378ms になる)。
        // 読めないのは JS 無効・評価失敗・未ロード・旧 dylib・Compose/Flutter ホストのとき。
        // **判定は web フラグ**(幾何だと WebView と同じ矩形の interop 容器を中身と誤認する)
        guard inapp.elements.contains(where: { $0.type == Self.webViewType }),
              !inapp.elements.contains(where: { $0.web == true }) else {
            // WebView 画面を離れた / in-app で読めている: 次の委譲でまた初回待ちを行う
            delegating = false
            sawWebContent = false
            note = nil
            return inapp
        }

        delegating = true
        note = "WebView screen — delegated to XCUITest"
        var snapshot = try await delegated.snapshot()
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

    // MARK: - 委譲中だけ XCUITest へ回す操作(画面に触るもの)

    private var screenDriver: AppDriver { delegating ? delegated : primary }

    public func tap(ref: Int) async throws { try await screenDriver.tap(ref: ref) }
    public func tap(x: Double, y: Double) async throws { try await screenDriver.tap(x: x, y: y) }
    public func type(ref: Int?, text: String) async throws {
        try await screenDriver.type(ref: ref, text: text)
    }
    public func pressEnter() async throws { try await screenDriver.pressEnter() }
    public func clearInput(ref: Int?) async throws { try await screenDriver.clearInput(ref: ref) }
    public func swipe(_ direction: FTSwipeDirection) async throws {
        try await screenDriver.swipe(direction)
    }
    public func press(ref: Int, duration: Double) async throws {
        try await screenDriver.press(ref: ref, duration: duration)
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
        delegating = false
        sawWebContent = false
        note = nil
    }

    /// 委譲中は自分の注記を優先し、無ければ実行したドライバのものを透過する
    public var lastActionNote: String? { note ?? screenDriver.lastActionNote }
}
