// シミュレータのアプリに dylib 注入した in-app ブリッジを駆動する AppDriver 実装。
// launch/terminate は simctl 再起動+注入(自己再起動できないため)、他は HTTP で
// BridgeClient に委譲する。HTTP プロトコルは XCUITest ブリッジと同一なので委譲でよい。

import Foundation
import FTCore

public final class InAppDriver: AppDriver {
    private let client: BridgeClient
    private let launcher: InAppLauncher
    // terminate() は bundleID を取らないため、直近 launch のものを使う
    private var lastBundleID: String?
    private var lastLaunchTimingValue: LaunchTiming?

    public init(repoRoot: URL, udid: String, port: UInt16) {
        self.client = BridgeClient(port: port)
        self.launcher = InAppLauncher(repoRoot: repoRoot, udid: udid, port: port)
    }

    // launch/terminate だけ simctl(注入起動)

    public func launch(bundleID: String) async throws {
        lastBundleID = bundleID
        lastLaunchTimingValue = nil   // 失敗時に前回成功分の内訳を出さないための明示リセット
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
    /// **対象を先に採ってから自前で終了させる**: in-app ブリッジは対象アプリのプロセス内に
    /// 住むので、終了するとデバイス名を採れなくなる。また BridgeClient 側の終了は in-app では
    /// 501 で効かない(プロセス制御は launcher = simctl が唯一の経路)。
    /// 起動したまま消すとプロセスが持っている状態が書き戻るため、この順序が要る
    public func clearAppData(bundleID: String) async throws {
        let target = try await withCrashContext { try await client.simulatorTarget() }
        try await terminate()
        try client.clearAppDataOnSimulator(bundleID: bundleID, target: target)
    }
    public func snapshot() async throws -> SnapshotResponse {
        try await withCrashContext { try await client.snapshot() }
    }
    /// bypassingCache 版の素通し(既定実装に任せるとフラグが落ちて最内へ届かない。
    /// SnapshotCacheBypassForwardingTests がラッパー全体でこれを守る)
    public func snapshot(bypassingCache: Bool) async throws -> SnapshotResponse {
        try await withCrashContext { try await client.snapshot(bypassingCache: bypassingCache) }
    }
    public var supportsCacheBypass: Bool { client.supportsCacheBypass }
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
    public func swipe(_ direction: FTSwipeDirection, forScroll: Bool) async throws {
        try await withCrashContext { try await client.swipe(direction, forScroll: forScroll) }
    }
    public func press(ref: Int, duration: Double) async throws {
        try await withCrashContext { try await client.press(ref: ref, duration: duration) }
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
    public var lastLaunchTiming: LaunchTiming? { lastLaunchTimingValue }

    /// 接続系エラーに、直近クラッシュレポートの有無に応じた切り分け情報を detail 末尾に付与して
    /// **同じ case のまま**再 throw する(呼び出し側の catch は変えなくてよい)。
    /// lastBundleID が nil(launch 未実施)なら素の detail のまま re-throw。
    ///
    /// refused だけでなく unreachable も見るのが要点: **操作自体がクラッシュを引き起こした場合**は
    /// リクエスト配送中に切断されるため URLSession は networkConnectionLost を返し、
    /// `isDefiniteDeliveryFailure` が false → bridgeUnreachable に分類される。refused だけを
    /// 見ていると「最も普通のクラッシュ」でレポート添付を取り逃す(2026-07-22 実測)。
    /// 分類自体は変えない(unreachable は「届いたか不明」= リトライ可否の意味論を持つため)。
    private func withCrashContext<T>(_ op: () async throws -> T) async throws -> T {
        do {
            return try await op()
        } catch let DriverError.bridgeConnectionRefused(detail) {
            throw DriverError.bridgeConnectionRefused(await crashAnnotated(detail))
        } catch let DriverError.bridgeUnreachable(detail) {
            throw DriverError.bridgeUnreachable(await crashAnnotated(detail))
        }
    }

    /// クラッシュ検知時の注記。**.ips は落ちてから遅れて書かれる**(実測: ブリッジ切断の
    /// 約 2 秒後。Projects/E2E-iOS の 91_クラッシュ検知 で確認)。切断直後に1回だけ探すと
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
                return detail + " / the app crashed: \(hit.path)\(suffix)"
            }
            if attempt < 7 { try? await Task.sleep(for: .milliseconds(500)) }
        }
        return detail + " / no recent crash report found"
            + " (no .ips appeared within 4s — possibly killed by the OS, memory pressure or a voluntary exit. "
            + "In hybrid/mixed runs the backgrounded app can be suspended or terminated)"
    }
}
