// シミュレータのアプリに dylib 注入した in-app ブリッジを駆動する AppDriver 実装。
// launch/terminate は simctl 再起動+注入(自己再起動できないため)、他は HTTP で
// BridgeClient に委譲する。HTTP プロトコルは XCUITest ブリッジと同一なので委譲でよい。

import Foundation
import FTCore

public final class InAppDriver: AppDriver {
    private let client: BridgeClient
    private let launcher: InAppLauncher
    /// "booted" は nil(AppUIFrameworkQuery の simctl の宛先にしない)
    private let simulatorUDID: String?
    // terminate() は bundleID を取らないため、直近 launch のものを使う
    private var lastBundleID: String?
    private var lastLaunchTimingValue: LaunchTiming?

    /// **simulatorUDID を渡し切る**: install/uninstall/clearAppData は simctl 経路で、宛先を
    /// 知らないと `/status` に聞きに行く。in-app ブリッジは対象アプリのプロセス内に住むので、
    /// 前のシナリオがアプリを終了した直後の `removeApp` は「接続拒否」で落ちる
    /// (受け手報告: シナリオ先頭の removeApp が同じ台で連続して driver-unreachable)。
    /// "booted" は UDID ではないので渡さない(台が複数 booted だと simctl の宛先として曖昧)
    public init(repoRoot: URL, udid: String, port: UInt16) {
        let simulatorUDID = udid == "booted" ? nil : udid
        self.simulatorUDID = simulatorUDID
        self.client = BridgeClient(port: port, simulatorUDID: simulatorUDID)
        self.launcher = InAppLauncher(repoRoot: repoRoot, udid: udid, port: port)
    }

    // launch/terminate だけ simctl(注入起動)

    public func launch(bundleID: String) async throws {
        lastBundleID = bundleID
        lastLaunchTimingValue = nil   // 失敗時に前回成功分の内訳を出さないための明示リセット
        uiFrameworkCache = nil        // 再注入先が変わり得るため判定も採り直す
        lastLaunchTimingValue = try await launcher.relaunch(bundleID: bundleID)
    }

    public func terminate() async throws {
        // launchApp を経ずに terminateApp が来る経路がある(tearDown だけで終了する等)。
        // その場合は**注入先アプリ**を対象にする: in-app ブリッジは対象アプリのプロセス内に
        // 常駐しているので、/status.sessionBundleID が「今動いているアプリ」の唯一の情報源。
        // ブリッジ無応答 = 対象アプリが既に居ない → 何もせず成功にする
        // (未起動 terminate を成功として扱う XCUITest 側 handleTerminate と同じ冪等性)
        var target = lastBundleID
        if target == nil { target = try? await client.status(timeout: 3).sessionBundleID }
        guard let bundleID = target else { return }
        launcher.terminate(bundleID: bundleID)
    }

    // 以下は in-app ブリッジへ HTTP 委譲(XCUITest と同一プロトコル)

    public func status() async throws -> StatusResponse { try await withCrashContext { try await client.status() } }
    public func install(packagePath: String) async throws {
        try await withCrashContext { try await client.install(packagePath: packagePath) }
    }
    public func uninstall(bundleID: String) async throws {
        try await withCrashContext { try await client.uninstall(bundleID: bundleID) }
    }
    /// in-app ブリッジは自分自身の active/bundleID しか知らないので、判定はブリッジ側の
    /// /appstate ハンドラに一本化してある(InAppBridge.handleAppState)。ここは HTTP 委譲のみ
    public func isAppForeground(bundleID: String) async throws -> Bool {
        try await withCrashContext { try await client.isAppForeground(bundleID: bundleID) }
    }
    /// 自分自身の bundleID しか分からず、それを「今フォアグラウンドのアプリ」として名乗る根拠が
    /// 無い(自分が active でない可能性がある)ため、XCUITest 側と同じく nil(不明)を返す
    public func foregroundAppID() async throws -> String? { nil }
    /// **in-app は答えられない**(自プロセスの外にあるものは見えない)。判定は XCUITest 側が持つ
    public func systemAlert() async throws -> SystemAlertProbeResponse? { nil }
    public func systemUICovering() async throws -> SystemUICoveringResponse? { nil }
    /// **対象を先に採ってから自前で終了させる**: in-app ブリッジは対象アプリのプロセス内に
    /// 住むので、終了するとデバイス名を採れなくなる。また BridgeClient 側の終了は in-app では
    /// 501 で効かない(プロセス制御は launcher = simctl が唯一の経路)。
    /// 起動したまま消すとプロセスが持っている状態が書き戻るため、この順序が要る
    public func clearAppData(bundleID: String) async throws {
        let target = try await withCrashContext { try await client.simulatorTarget() }
        try await terminate()
        try client.clearAppDataOnSimulator(bundleID: bundleID, target: target)
    }
    /// URL(ディープリンク)を配送する。**`simctl openurl` は環境変数を渡せない**ため、
    /// アプリが死んでいる状態で撃つと dylib 未注入のまま起動しブリッジごと死ぬ(注入起動は
    /// launch()/InAppLauncher.relaunch が唯一の経路)。/status で生死を probe し、
    /// **接続拒否のときだけ** launch() 経由で注入起動してから配送する(生きていれば再起動せず warm 配送)。
    /// 対象は bundleID 引数 → 直近 launch した lastBundleID の順。どちらも無ければ、死んでいた場合に
    /// 何へ注入起動すればよいか分からないため明確なエラーで止める
    public func openURL(_ url: String, bundleID: String?) async throws {
        guard let target = bundleID ?? lastBundleID else {
            throw DriverError.badResponse(status: 400,
                body: "openURL needs a bundleID: none was given and no app has been launched yet on"
                    + " this in-app engine, so there is nothing to relaunch into if the bridge is unreachable")
        }
        // **再起動するのは「接続を拒否された」= プロセスが居ないときだけ**。無応答(タイムアウト)は
        // **サスペンド中の生存プロセス**でも起きる —— 背面に回った in-app アプリは TCP を受理して
        // 何も返さない(docs/verification.md)。そこを死と読むと、`home()` の後の openURL が
        // warm 配送のはずが毎回プロセス再起動になり、in-process の状態を黙って捨てる
        // (同じシナリオが xcuitest エンジンとだけ挙動が食い違う)。サスペンドなら
        // simctl openurl 自体が前面化して配送するので、こちらから起こす必要はない
        do {
            _ = try await client.status(timeout: 3)
        } catch DriverError.bridgeConnectionRefused {
            try await launch(bundleID: target)
        } catch {
            // 無応答・その他はそのまま配送を試みる
        }
        try await withCrashContext { try await client.openURL(url, bundleID: target) }
    }

    /// in-app ブリッジは自分の bundle 以外の /session を張れないので、この接続では実際には
    /// 何も押せない(client 側が 409 で抜けて未記録のまま次の接続に委ねる)。**それでも転送する** ——
    /// 既定の no-op のままにすると「試したのか、試せなかったのか」がコードから読めなくなる
    public func acknowledgeOpenURLConsentIfPresent(bundleID: String) async {
        await client.acknowledgeOpenURLConsentIfPresent(bundleID: bundleID)
    }

    public func snapshot() async throws -> SnapshotResponse {
        try await normalizedSnapshot { try await self.client.snapshot() }
    }
    /// bypassingCache 版の素通し(既定実装に任せるとフラグが落ちて最内へ届かない。
    /// SnapshotCacheBypassForwardingTests がラッパー全体でこれを守る)
    public func snapshot(bypassingCache: Bool) async throws -> SnapshotResponse {
        try await normalizedSnapshot { try await self.client.snapshot(bypassingCache: bypassingCache) }
    }

    /// 初回 snapshot でだけ AppUIFrameworkQuery に問い合わせて確定し、以降は使い回す。
    /// **成功だけをキャッシュする**: 失敗を覚えると、コールドラウンチ直後の1回のタイムアウトで
    /// 正規化が run 全体で無効のまま固定される。/status の timeout を短く切るのは suspend 中の
    /// アプリが TCP を受けたまま応答しない既知の形(BridgeClient.status(timeout:) のコメント)で
    /// 45 秒待たないため。launch 済みなら bundle ID が分かるので、静的に決まる回は /status を打たない
    private var uiFrameworkCache: AppUIFramework?

    private func cachedUIFramework() async -> AppUIFramework? {
        if let cached = uiFrameworkCache { return cached }
        let status = lastBundleID == nil ? (try? await client.status(timeout: 4)) : nil
        let bundleID = lastBundleID ?? status?.sessionBundleID
        let subject = AppUIFrameworkQuery.Subject(platform: "ios", bundleID: bundleID, appPath: nil,
                                                  udid: simulatorUDID, physical: false)
        let framework = await AppUIFrameworkQuery.resolve(subject) { [client] in
            var reported = status
            if reported == nil { reported = try? await client.status(timeout: 4) }
            return AppUIFrameworkQuery.bridgeReport(reported, about: bundleID)
        }.framework
        uiFrameworkCache = framework
        return framework
    }

    /// RN 等 UIKit の in-app ツリーはラッパー分離(testID 付き容器 + 別ノードの実スクロール要素)と
    /// テキスト2重化(id 付き + 同枠同ラベルの匿名ノード)を起こす(実測)。
    /// ビューを持つ系(uikit / swiftUI / reactNative)と判ったときだけ両方を畳む。compose/flutter は scrollable を申告できず
    /// wrapperScrollMerge が実質発火しないとしても、既存 SUT の序数を動かさないため明示的に触らない
    private func normalizedSnapshot(_ fetch: () async throws -> SnapshotResponse) async throws -> SnapshotResponse {
        var response = try await withCrashContext(fetch)
        guard let framework = await cachedUIFramework(), !framework.isSelfRendered else { return response }
        let merged = SnapshotDedupe.wrapperScrollMerge(response.elements)
        var emitted: [ElementInfo] = []
        response.elements = merged.filter { element in
            guard !SnapshotDedupe.isRedundant(element, alreadyEmitted: emitted) else { return false }
            emitted.append(element)
            return true
        }
        return response
    }
    /// **転送必須**(既定実装に任せると最内のブリッジ接続へ届かず、上げたつもりで 120 のまま)
    public func raiseElementLimitOnNextSnapshot(_ max: Int?) {
        client.raiseElementLimitOnNextSnapshot(max)
    }
    public var supportsCacheBypass: Bool { client.supportsCacheBypass }
    public var pointScale: Double { client.pointScale }
    /// **client.verifiesTypedText を転送しない**: client(BridgeClient)は XCUITest ランナー向けの
    /// 既定 true を持つが、ここでは同じ HTTP プロトコルで in-app ブリッジ(読み返し無し)を話している。
    /// 固定 false で StepExecutor 側の読み返しを常に働かせる
    public var verifiesTypedText: Bool { false }
    public func tap(ref: Int) async throws { try await withCrashContext { try await client.tap(ref: ref) } }
    public func tap(x: Double, y: Double) async throws {
        try await withCrashContext { try await client.tap(x: x, y: y) }
    }
    public func type(ref: Int?, text: String) async throws {
        try await withCrashContext { try await client.type(ref: ref, text: text) }
    }
    public func pressEnter() async throws {
        try await withCrashContext { try await client.pressEnter() }
    }
    public func clearInput(ref: Int?) async throws {
        try await withCrashContext { try await client.clearInput(ref: ref) }
    }
    public func hideKeyboard() async throws {
        try await withCrashContext { try await client.hideKeyboard() }
    }
    public func swipe(_ direction: FTSwipeDirection) async throws {
        try await withCrashContext { try await client.swipe(direction) }
    }
    public func swipe(_ direction: FTSwipeDirection, intent: FTSwipeIntent,
                      path: FTSwipePath?) async throws {
        try await withCrashContext { try await client.swipe(direction, intent: intent, path: path) }
    }
    public func press(ref: Int, duration: Double) async throws {
        try await withCrashContext { try await client.press(ref: ref, duration: duration) }
    }
    /// **ダブルタップは in-app の方が正確**(合成タッチはタップだけは受理される): 離してから
    /// 次に押すまでの間隔をこちらで決められるので、XCTest の doubleTap では単タップに落ちる
    /// Compose(iOS)でも成立する。ピンチは合成タッチの move 次第なのでフレームワーク依存
    /// (受理しない実装では黙って無反応 = 呼び出し側の検証で気付く)
    public func doubleTap(x: Double, y: Double) async throws {
        try await withCrashContext { try await client.doubleTap(x: x, y: y) }
    }
    /// in-app には「対象アプリ全体」を掴む要素ピンチの縮退先が無い(XCUITest の
    /// `XCUIElement.pinch` はプロセス外の合成ジェスチャで、in-app の合成タッチは自プロセス内の
    /// 座標にしか撃てない)ので、**`frame` が無ければ 501 で断る**(指の置き方
    /// `FTCore.PinchGesture.ios` は領域が要る)。hybrid では StepExecutor が XCUITest 側へ回す
    public func pinch(frame: FTRect?, identifier: String?, scale: Double,
                      durationSeconds: Double) async throws {
        guard let frame else {
            throw DriverError.badResponse(status: 501,
                body: "pinch needs a target area on the in-app engine (no whole-app element pinch to"
                    + " fall back to). Switch the run profile to hybrid or xcuitest, or scope the pinch"
                    + " to an element")
        }
        try await withCrashContext {
            try await client.pinch(request: PinchRequest(
                scale: scale, durationSeconds: durationSeconds, frame: frame, identifier: identifier,
                fingers: try PinchGesture.ios(frame: frame, scale: scale,
                                              durationSeconds: durationSeconds)))
        }
    }
    public func rotate(to orientation: FTOrientation) async throws -> FTOrientation {
        try await withCrashContext { try await client.rotate(to: orientation) }
    }
    public func restoreOrientationIfNeeded() async throws {
        try await withCrashContext { try await client.restoreOrientationIfNeeded() }
    }
    // in-app では原理的に実行できない操作(自プロセス外・座標ジェスチャ)。hybrid では StepExecutor /
    // FTDriveCore が XCUITest 側へ回すのでここへは来ない。engine=inapp 単独だけがここに到達するため、
    // 既定実装の汎用メッセージではなく構成の直し方を示す(501 = このエンジンでは未対応)
    public func home() async throws { throw Self.inappOnly("home") }
    public func back() async throws { throw Self.inappOnly("back") }
    public func openAppSwitcher() async throws { throw Self.inappOnly("appSwitcher") }
    public func drag(fromX: Double, fromY: Double, toX: Double, toY: Double,
                     pressSeconds: Double, durationSeconds: Double) async throws {
        throw Self.inappOnly("drag")
    }
    public func press(x: Double, y: Double, duration: Double) async throws {
        throw Self.inappOnly("press by coordinates")
    }

    private static func inappOnly(_ action: String) -> DriverError {
        .badResponse(status: 501,
                     body: "\(action) cannot run on the in-app engine"
                         + " (other apps and system UI cannot be driven from inside the app process). "
                         + "Switch the run profile to hybrid or xcuitest")
    }

    public func screenshot() async throws -> Data { try await withCrashContext { try await client.screenshot() } }
    public var lastActionNote: String? { client.lastActionNote }
    /// 端の申告は素通し(捨てると端送りが毎回ホストの署名判定まで回る)
    public var reachedEdgeOnLastSwipe: Bool? { client.reachedEdgeOnLastSwipe }
    public var lastLaunchTiming: LaunchTiming? { lastLaunchTimingValue }

    /// 接続系エラーに、直近クラッシュレポートの有無に応じた切り分け情報を detail 末尾に付与して
    /// **同じ case のまま**再 throw する(呼び出し側の catch は変えなくてよい)。
    /// lastBundleID が nil(launch 未実施)なら素の detail のまま re-throw。
    ///
    /// refused だけでなく unreachable も見るのが要点: **操作自体がクラッシュを引き起こした場合**は
    /// リクエスト配送中に切断されるため URLSession は networkConnectionLost を返し、
    /// `isDefiniteDeliveryFailure` が false → bridgeUnreachable に分類される。refused だけを
    /// 見ていると「最も普通のクラッシュ」でレポート添付を取り逃す(実測)。
    /// 分類自体は変えない(unreachable は「届いたか不明」= リトライ可否の意味論を持つため)。
    private func withCrashContext<T>(_ op: () async throws -> T) async throws -> T {
        do {
            return try await op()
        } catch let DriverError.bridgeConnectionRefused(_, detail) {
            throw DriverError.bridgeConnectionRefused(context: Self.context,
                                                       detail: await crashAnnotated(detail))
        } catch let DriverError.bridgeUnreachable(_, detail) {
            throw DriverError.bridgeUnreachable(context: Self.context,
                                                 detail: await crashAnnotated(detail))
        }
    }

    /// in-app は常にシミュレータ(実機への注入は不可能。CLAUDE.md 決定)なので physicalDevice は
    /// 固定 false。**client(BridgeClient)は xcuitest 向けの context を既定に持つので、必ず
    /// `withCrashContext` で in-app へ付け替える**(DriverErrorContext の doc 参照。
    /// 付け替えないと Android と同じ理由で誤った構成の案内が付く)
    private static let context = DriverErrorContext(engine: .iosInApp, physicalDevice: false)

    /// クラッシュ検知時の注記。**.ips は落ちてから遅れて書かれる**(実測: ブリッジ切断の
    /// 約 2 秒後。TestProjects/E2E-iOS の 91_クラッシュ検知 で確認)。切断直後に1回だけ探すと
    /// ファイルがまだ無く「見つかりませんでした」になるため、短くポーリングして待つ。
    /// この経路は既に失敗が確定しているので、待ち時間が正常系を遅らせることはない。
    private func crashAnnotated(_ detail: String) async -> String {
        guard let bundleID = lastBundleID else { return detail }
        for attempt in 0..<8 {
            // within を既定(120s)のままにすると、**前の実行が残した .ips** が先に窓へ入って
            // 古いパスと終了理由を報告してしまう(実測: 94 秒前のレポートを拾った)。
            // 今しがた切断したのだから、対象は数秒以内のものだけでよい。
            if let hit = SimulatorCrashReport.findRecent(bundleID: bundleID, within: 10) {
                let suffix = hit.reason.map { " (\($0))" } ?? ""
                LastAppCrash.shared.record(AppCrashRecord(evidence: .crashReport, path: hit.path, summary: hit.reason))
                return detail + " / the app crashed: \(hit.path)\(suffix)"
            }
            if attempt < 7 { try? await Task.sleep(for: .milliseconds(500)) }
        }
        // .ips が無い = 殺されたとは限らない(実測: SIGSTOP で 60 秒止めたアプリは
        // プロセスとして生きたまま無応答だった)。生死を確かめてから事実どおりの文言に分ける
        switch await appIsStillRunning(bundleID: bundleID) {
        case true:
            return detail + " / no recent crash report found, and the app process is still running"
                + " — it is not answering (a hang, or it is suspended because another app is in front)"
        case false, nil:
            return detail + " / no recent crash report found"
                + " (no .ips appeared within 4s — possibly killed by the OS, memory pressure or a voluntary exit. "
                + "In hybrid/mixed runs the backgrounded app can be suspended or terminated)"
        }
    }

    /// .ips が見つからなかったときの生死確認。simulatorUDID が nil("booted" 起動で宛先が
    /// 曖昧)や simctl 自体の失敗では判定できない(nil)ので、呼び出し側は通常の
    /// 「殺された可能性」の文言を使う(判定できない=生きていない、にはしない)
    /// **協調スレッドプールで待たない**(Shell.run は同期で最大 timeout 秒ブロックする)
    private func appIsStillRunning(bundleID: String) async -> Bool? {
        guard let udid = simulatorUDID else { return nil }
        return await Task.detached {
            guard let result = try? Shell.run(
                ["xcrun", "simctl", "spawn", udid, "launchctl", "list"],
                timeout: Self.launchctlListTimeoutSeconds
            ), result.status == 0 else { return nil }
            return Self.processIsRunning(inLaunchctlListOutput: result.output, bundleID: bundleID)
        }.value
    }

    /// `launchctl list` の直読み(5 秒 = SafariWebInspector の lsof 診断と同じ、応答が無ければ
    /// 待つ意味の無い読み取り専用診断の目安)
    private static let launchctlListTimeoutSeconds: Double = 5

    /// `launchctl list` の1行は "PID\tステータス\tラベル"。対象アプリのラベルは
    /// "UIKitApplication:<bundleID>[" を含み、未起動なら PID 列が "-"。純粋関数でテストする
    static func processIsRunning(inLaunchctlListOutput output: String, bundleID: String) -> Bool {
        let marker = "UIKitApplication:\(bundleID)["
        for line in output.split(separator: "\n") {
            let fields = line.split(separator: "\t")
            guard let label = fields.last, label.contains(marker) else { continue }
            guard let pidField = fields.first, Int(pidField) != nil else { continue }
            return true
        }
        return false
    }
}
