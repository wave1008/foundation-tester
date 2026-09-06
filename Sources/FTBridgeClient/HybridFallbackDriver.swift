// hybrid で「in-app が原理的に実行できない操作」だけを XCUITest 側へ回すデコレータ。
//
// シナリオ実行では同じ判断を StepExecutor が持っている(driver → 501 なら typeDriver)。
// **StepExecutor を通らない呼び出し口**(MCP の ft_*)にも同じ振る舞いを与えるのがこのクラスで、
// これが無いと in-app エンジンでは home / drag / 座標 press が素の 501 で返る
// (2026-07-28 に live/MCP を xcuitest 固定にした理由そのもの)。
//
// **ref を使う操作は回さない**のが不変条件: ref はブリッジごとに別名前空間で、そのまま渡すと
// **無関係な要素を操作する**。座標・identifier で完結する操作だけが安全に回せる
// (WebViewDelegatingDriver の domInterop が ref を渡さないのと同じ理由)。
// 例外は press(ref:) で、**primary の snapshot で座標へ畳んでから**回す(ref を渡さない形にできる)。

import Foundation
import FTCore

public final class HybridFallbackDriver: AppDriver {
    private let primary: AppDriver
    /// 対象アプリに attach した XCUITest ドライバ。home/appSwitcher もこれが受ける
    /// (AppAttachDriver はセッション不要の操作を素通しする)
    private let fallback: AppDriver
    private var fallbackNote: String?
    /// **home/appSwitcher の後は in-app 側が使えない**: in-app ブリッジは対象アプリの
    /// プロセス内に住むので、背面化すると iOS に suspend され、TCP は受理されるのに HTTP が
    /// 返らない(実測: home 直後の snapshot がタイムアウト。2026-08-05)。
    /// この間は**全操作を XCUITest 側へ寄せる** —— 読みも書きも同じ側に寄せるので
    /// ref の名前空間も一致する(混ぜると別要素を操作する)。launch/activate で解除
    private var appBackgrounded = false
    /// in-app ブリッジが住んでいるアプリの bundle ID(分かるときだけ)。
    /// **これが無いと「自分では抱えられないアプリ」を判定できない**
    private let primaryBundleID: String?
    /// **別 bundle のセッションを張れる** XCUITest ドライバ(fallback の AppAttachDriver は
    /// 固定 bundle への attach 専用で、`launch` は意図的に no-op)。
    /// springboard や別アプリを開くのはこちらの役目
    private let foreignApp: AppDriver?
    /// primary(in-app)が原理的に見られない対象を見ている。
    /// **in-app ブリッジは自分のプロセスの中しか見えない**ので、別アプリや springboard を
    /// launch したら以降は読みも書きも XCUITest 側へ寄せる。
    /// これが無いと `ft_launch com.apple.springboard` が**成功を返したうえで、
    /// 続く snapshot がアプリ自身の古い木を返す**(2026-08-06 に実測。
    /// ホーム画面を読もうとして 30 要素のアプリ画面が返った)
    private var delegatedApp = false
    /// 直前の swipe を実際に受けたドライバ(reachedEdgeOnLastSwipe の読み先)
    private var lastSwipeDriver: AppDriver?

    /// primary を使えない状態か(背面化 or primary が抱えられない対象)
    private var delegating: Bool { appBackgrounded || delegatedApp }

    /// 宛先。primary 限定の操作もこちらを見る。
    /// 別 bundle を見ている間は**セッションを張った側**から読む(attach 専用の fallback ではない)
    private var active: AppDriver {
        if delegatedApp, let foreignApp { return foreignApp }
        return delegating ? fallback : primary
    }

    public init(primary: AppDriver, fallback: AppDriver,
                primaryBundleID: String? = nil, foreignApp: AppDriver? = nil) {
        self.primary = primary
        self.fallback = fallback
        self.primaryBundleID = primaryBundleID
        self.foreignApp = foreignApp
    }

    /// primary を試し、**このエンジンでは不可(501 / ルート不明 404)のときだけ** fallback へ回す。
    /// 409 は含めない(一時的競合。理由は DriverError.isEngineIncapable)
    private func withFallback<T>(_ operation: (AppDriver) async throws -> T) async throws -> T {
        try await withFallbackTracking(operation).value
    }

    /// withFallback と同じ振り分けで、**実際に操作を受けたドライバ**も返す(swipe の端申告など
    /// 「直前の操作を受けた側」に紐づく読み出しのため)
    private func withFallbackTracking<T>(
        _ operation: (AppDriver) async throws -> T
    ) async throws -> (value: T, performer: AppDriver) {
        // 背面化中・別アプリを見ている間は primary を撃たない
        // (前者は応答が返らずタイムアウト分待たされる。後者は無関係な木を触る)
        if delegatedApp, let foreignApp { return (try await operation(foreignApp), foreignApp) }
        if delegating { return (try await operation(fallback), fallback) }
        do {
            let result = try await operation(primary)
            fallbackNote = nil
            return (result, primary)
        } catch {
            guard DriverError.isEngineIncapable(error) else { throw error }
            let result = try await operation(fallback)
            fallbackNote = "fell back to XCUITest"
            return (result, fallback)
        }
    }

    // MARK: - 座標・フォーカスで完結する操作(回してよい)

    public func tap(x: Double, y: Double) async throws {
        try await withFallback { try await $0.tap(x: x, y: y) }
    }

    public func doubleTap(x: Double, y: Double) async throws {
        try await withFallback { try await $0.doubleTap(x: x, y: y) }
    }

    public func pinch(frame: FTRect?, identifier: String?, scale: Double,
                      durationSeconds: Double) async throws {
        try await withFallback {
            try await $0.pinch(frame: frame, identifier: identifier, scale: scale,
                               durationSeconds: durationSeconds)
        }
    }

    public func drag(fromX: Double, fromY: Double, toX: Double, toY: Double,
                     pressSeconds: Double, durationSeconds: Double) async throws {
        try await withFallback {
            try await $0.drag(fromX: fromX, fromY: fromY, toX: toX, toY: toY,
                              pressSeconds: pressSeconds, durationSeconds: durationSeconds)
        }
    }

    public func rotate(to orientation: FTOrientation) async throws -> FTOrientation {
        try await withFallback { try await $0.rotate(to: orientation) }
    }

    /// **回した先すべてに戻させる**。各ドライバは自分が rotate したときだけ戻す(BridgeClient の
    /// originalOrientation)ので、withFallback で1本に絞ると fallback/foreignApp が回した回転が
    /// 残る(primary は「回していない」と答えて no-op)。501(そのエンジンでは不可)は無視し、
    /// それ以外の失敗は全員に撃ってから最初の1つを投げる。
    /// primary は delegating 中は撃たない(背面化した in-app は応答せずタイムアウト分固まる)
    public func restoreOrientationIfNeeded() async throws {
        var targets: [AppDriver] = delegating ? [] : [primary]
        targets.append(fallback)
        if let foreignApp { targets.append(foreignApp) }
        var firstError: Error?
        for driver in targets {
            do {
                try await driver.restoreOrientationIfNeeded()
            } catch {
                if DriverError.isEngineIncapable(error) { continue }
                if firstError == nil { firstError = error }
            }
        }
        if let firstError { throw firstError }
    }

    public func press(x: Double, y: Double, duration: Double) async throws {
        try await withFallback { try await $0.press(x: x, y: y, duration: duration) }
    }

    public func swipe(_ direction: FTSwipeDirection) async throws {
        lastSwipeDriver = try await withFallbackTracking { try await $0.swipe(direction) }.performer
    }

    public func swipe(_ direction: FTSwipeDirection, intent: FTSwipeIntent,
                      path: FTSwipePath?) async throws {
        lastSwipeDriver = try await withFallbackTracking {
            try await $0.swipe(direction, intent: intent, path: path)
        }.performer
    }

    public func home() async throws {
        try await withFallback { try await $0.home() }
        appBackgrounded = true
    }
    /// back は前面のままなので寄せ替えない
    public func back() async throws { try await withFallback { try await $0.back() } }
    public func openAppSwitcher() async throws {
        try await withFallback { try await $0.openAppSwitcher() }
        appBackgrounded = true
    }
    public func hideKeyboard() async throws {
        try await withFallback { try await $0.hideKeyboard() }
    }
    public func pressEnter() async throws {
        try await withFallback { try await $0.pressEnter() }
    }

    /// ref なし(フォーカス中の要素)だけ回す。ref ありは primary 限定
    public func type(ref: Int?, text: String) async throws {
        guard ref == nil else { return try await active.type(ref: ref, text: text) }
        try await withFallback { try await $0.type(ref: nil, text: text) }
    }

    public func clearInput(ref: Int?) async throws {
        guard ref == nil else { return try await active.clearInput(ref: ref) }
        try await withFallback { try await $0.clearInput(ref: nil) }
    }

    /// **ref を渡さずに回す**: in-app は長押しを持たない(501)ので、primary の snapshot で
    /// 中心座標へ畳んでから XCUITest の座標長押しへ送る。ref をそのまま渡すと別要素を押す。
    /// **delegating(背面化 or 別アプリ委譲)中は active へ**(tap(ref:)/type(ref:)/clearInput(ref:) と
    /// 同じ理由): 元は `appBackgrounded` だけを見ており、`delegatedApp`(foreignApp へ委譲中)を
    /// 見落として primary(自分の木を持たない別アプリの ref)へ投げていた
    /// (2026-09-06 発覚: springboard 委譲中の press(ref:) が無関係な要素を長押しするか、
    /// suspend されたアプリへの応答待ちでタイムアウトしていた)
    public func press(ref: Int, duration: Double) async throws {
        if delegating { return try await active.press(ref: ref, duration: duration) }
        do {
            try await primary.press(ref: ref, duration: duration)
            fallbackNote = nil
        } catch {
            guard DriverError.isEngineIncapable(error) else { throw error }
            let snapshot = try await primary.snapshot()
            guard let element = snapshot.elements.first(where: { $0.ref == ref }) else {
                throw error
            }
            try await fallback.press(x: element.frame.centerX, y: element.frame.centerY,
                                     duration: duration)
            fallbackNote = "fell back to XCUITest (by coordinates)"
        }
    }

    // MARK: - primary 限定(ref の名前空間・注入・エンジン identity を跨がせない)

    public func tap(ref: Int) async throws { try await active.tap(ref: ref) }
    public func snapshot() async throws -> SnapshotResponse { try await snapshot(bypassingCache: false) }
    /// **転送必須**(既定実装 nil に落ちると、ラッパー越しでは常に「答えられない」になる。
    /// AppDriver.hittable の doc と AppDriverDefaultDispatchTests 参照)
    public func hitTest(ref: Int) async throws -> HitTestAnswer {
        try await active.hitTest(ref: ref)
    }

    /// **home()/openAppSwitcher() の直後(delegatedApp ではない背面化)だけ特別扱い**する。
    /// それ以外(通常時・foreignApp への明示委譲中)は従来どおり `active` を読む
    public func snapshot(bypassingCache: Bool) async throws -> SnapshotResponse {
        if appBackgrounded, !delegatedApp {
            return try await backgroundSnapshot(bypassingCache: bypassingCache)
        }
        return try await active.snapshot(bypassingCache: bypassingCache)
    }

    /// **再前面化せずに読む**: `fallback`(AppAttachDriver)の `snapshot(bypassingCache:)` は
    /// 呼ぶたび `client.activate(bundleID:)` するため、素通しすると「読むだけで背面化していた
    /// アプリを前面へ戻す」事故になる(MCPServer+Driver.swift の `sentToBackgroundNote` が
    /// 「最後の状態、今の画面ではない」と案内しているのに、実際には読むたびに前面へ戻された
    /// **今の**アプリの木を返していた。2026-09-06 発覚)。
    ///
    /// **foreignApp があれば springboard 参照へ張り替えて読む**
    /// (`SystemUIDriver` の旧ランナーフォールバックと同じ形。`launch(bundleID:)` はブリッジ側で
    /// springboard を「起動せず参照のみ」に特別扱いするので、対象アプリは背面のまま起こさない)。
    /// home() はホーム画面、openAppSwitcher() はマルチタスク画面を出すが、**どちらも SpringBoard
    /// プロセスの木**なので同じ bundle ID で読める。
    ///
    /// **foreignApp が無ければ** attach を activate なしで読む
    /// (`AppAttachDriver.snapshotWithoutReactivating`)。ランナー側の `requireForegroundApp()` が
    /// セッションのアプリが前面に無いと判定すれば 422 を返すので、それをそのまま呼び手へ伝える ——
    /// **黙って activate はしない**(呼び手には「アプリが背面にある」とそのまま伝わる)
    private func backgroundSnapshot(bypassingCache: Bool) async throws -> SnapshotResponse {
        if let foreignApp {
            try await foreignApp.launch(bundleID: "com.apple.springboard")
            return try await foreignApp.snapshot(bypassingCache: bypassingCache)
        }
        guard let attach = fallback as? AppAttachDriver else {
            return try await fallback.snapshot(bypassingCache: bypassingCache)
        }
        return try await attach.snapshotWithoutReactivating(bypassingCache: bypassingCache)
    }
    /// **転送必須**(既定実装に任せると最内のブリッジ接続へ届かず、上げたつもりで 120 のまま)
    public func raiseElementLimitOnNextSnapshot(_ max: Int?) {
        active.raiseElementLimitOnNextSnapshot(max)
    }
    public var supportsCacheBypass: Bool { active.supportsCacheBypass }
    public var pointScale: Double { active.pointScale }
    public var verifiesTypedText: Bool { active.verifiesTypedText }
    public func status() async throws -> StatusResponse { try await active.status() }
    public func screenshot() async throws -> Data { try await active.screenshot() }
    /// 起動系は**必ず primary**(in-app は dylib 注入を伴う再起動で、XCUITest の launch では
    /// ブリッジが載らない)。前面へ戻るので寄せ替えも解除する
    public func launch(bundleID: String) async throws {
        if try await delegateForeignApp(bundleID, { try await $0.launch(bundleID: bundleID) }) { return }
        try await primary.launch(bundleID: bundleID)
        appBackgrounded = false
        delegatedApp = false
    }
    public func activate(bundleID: String) async throws {
        if try await delegateForeignApp(bundleID, { try await $0.activate(bundleID: bundleID) }) { return }
        try await primary.activate(bundleID: bundleID)
        appBackgrounded = false
        delegatedApp = false
    }

    /// **自分の中に居ないアプリは XCUITest 側で開く**。in-app ブリッジは対象アプリの
    /// プロセス内に住むので、別 bundle を渡されても自分の外は見えない ——
    /// primary に投げると「成功したのに読めるのは自分の木だけ」になる。
    /// 開いた後も寄せたままにする(読みと書きを同じ側に置く = ref の名前空間が揃う)。
    /// primaryBundleID が不明なときは従来どおり primary へ(判定材料が無いので嘘をつかない)
    private func delegateForeignApp(
        _ bundleID: String, _ operation: (AppDriver) async throws -> Void) async throws -> Bool {
        guard let own = primaryBundleID, bundleID != own, let foreignApp else { return false }
        try await operation(foreignApp)
        delegatedApp = true
        appBackgrounded = false
        fallbackNote = "delegated to XCUITest (the in-app bridge only sees \(own))"
        return true
    }
    public func terminate() async throws { try await primary.terminate() }
    public func install(packagePath: String) async throws {
        try await primary.install(packagePath: packagePath)
    }
    public func uninstall(bundleID: String) async throws {
        try await primary.uninstall(bundleID: bundleID)
    }
    public func clearAppData(bundleID: String) async throws {
        try await primary.clearAppData(bundleID: bundleID)
    }
    /// 座標・identifier で完結する操作と同じ扱いで withFallback に乗せる: primary(in-app)は
    /// 自前でブリッジ生存確認+注入起動を持つので通常はそのまま届く。501/ルート不明のときだけ
    /// XCUITest 側(fallback/foreignApp)の simctl/devicectl 経路へ回す
    public func openURL(_ url: String, bundleID: String?) async throws {
        try await withFallback { try await $0.openURL(url, bundleID: bundleID) }
        // **委譲状態を解く**(launch/activate と同じ理由): URL の配送先アプリが前面に来たのに
        // delegatedApp/appBackgrounded が立ったままだと、以後の snapshot/tap が
        // foreignApp(springboard 等)の木を読んで**別のものを叩く**。ft_launch で踏んだ形と同じ
        appBackgrounded = false
        delegatedApp = false
    }
    /// **in-app(primary)は springboard を見られない**(自分の bundle 以外の /session を 409 で拒否)。
    /// 確認アラートの了承は XCUITest 側にしかできないので、両方へ順に投げる(BridgeClient 側が
    /// (デバイス, bundleID)ごとに1回だけ実際の操作を行うので二重に押すことはない)
    public func acknowledgeOpenURLConsentIfPresent(bundleID: String) async {
        await primary.acknowledgeOpenURLConsentIfPresent(bundleID: bundleID)
        await fallback.acknowledgeOpenURLConsentIfPresent(bundleID: bundleID)
    }
    public func isAppForeground(bundleID: String) async throws -> Bool {
        try await active.isAppForeground(bundleID: bundleID)
    }
    public func foregroundAppID() async throws -> String? { try await active.foregroundAppID() }
    // **常に fallback(XCUITest)へ聞く** —— in-app(primary)は SpringBoard を見られず常に nil を
    // 返す(InAppDriver)ので、`active` に乗せると delegating が false の間(通常時)ずっと nil に
    // 潰れて何も見えない。fallback はセッション不要の attach で常に居るので、どの状態でも答えられる
    public func systemAlert() async throws -> SystemAlertProbeResponse? { try await fallback.systemAlert() }
    public func systemUICovering() async throws -> SystemUICoveringResponse? {
        try await fallback.systemUICovering()
    }
    public func captureKeyboardStateOnNextSnapshot() {
        primary.captureKeyboardStateOnNextSnapshot()
    }

    /// フォールバックしたことは注記として見せる(黙って別経路へ回ると挙動差の原因が読めない)。
    /// primary 自身の注記があればそちらを優先する(最内の観測を潰さない)
    public var lastActionNote: String? { primary.lastActionNote ?? fallbackNote }
    /// 端の申告は**素通し**(捨てると端送りが毎回ホストの署名判定まで回る)。
    /// 読むのは**直前の swipe を受けたドライバ**(fallback/foreignApp が送ったのに primary を
    /// 読むと、古い申告か nil を返す)
    public var reachedEdgeOnLastSwipe: Bool? { (lastSwipeDriver ?? primary).reachedEdgeOnLastSwipe }
    public var lastLaunchTiming: LaunchTiming? { primary.lastLaunchTiming }
}
