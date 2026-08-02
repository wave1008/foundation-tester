// XCUITest ブリッジ(BridgeRouter.swift requireApp())は POST /session でしかセッションを持たず、
// ランナー再起動でセッションが失われると全操作が 409 で落ちる。409 を投げるのはこの1箇所だけなので、
// この経路の 409 は「セッション消失」と断定してよい。
//
// **この「1箇所だけ」は不変条件であって観察ではない**: 一度 handleClear が 409 を足して破れており
// (2026-07-31 修正)、その間 clearInput の正当な失敗が「ランナーが再起動した可能性」と誤報告され、
// 無用な activate まで撃っていた。以後 `BridgeRouterStatusContractTests` が本数を数えて守る。
// **in-app ブリッジには適用しない** — あちらは 409 を一時的競合(キーウィンドウ不在・フォーカス
// 無し)に広く使っており意味が違う(ScenarioRunnerMain の driver 組み立て参照)。
//
// 回復は activate(launch ではない)で行う: セッション確立(handleLaunch)は refFrames をクリアするため、
// 直前 snapshot の ref はセッション再確立後すべて無効になる。launch はアプリを再起動しナビ状態を
// 飛ばすため、ref を使う操作は再試行せず 409 をそのまま呼び出し元へ返す(次段の snapshot からの
// 復帰に委ねる)。ref を使わない操作(座標指定 tap/press・snapshot・screenshot 等)は
// activate 後に1回だけ再試行する。

import Foundation
import FTCore

public final class SessionRecoveryDriver: AppDriver {
    private let base: AppDriver
    private var lastBundleID: String?

    public init(base: AppDriver) {
        self.base = base
    }

    private func isSessionLost(_ error: Error) -> Bool {
        if case DriverError.badResponse(let status, _) = error, status == 409 { return true }
        return false
    }

    /// lastBundleID があれば activate でセッションだけ張り直す。失敗しても握りつぶす
    /// (回復の可否に関わらず、呼び出し元は元の 409 を処理するため)。
    private func recover() async {
        guard let lastBundleID else { return }
        _ = try? await base.activate(bundleID: lastBundleID)
    }

    /// ref を使わない操作向け: 409 なら1回だけ回復+再試行する。
    private func withRecovery<T>(_ operation: () async throws -> T) async throws -> T {
        do {
            return try await operation()
        } catch {
            guard isSessionLost(error), lastBundleID != nil else { throw error }
            await recover()
            return try await operation()
        }
    }

    public func status() async throws -> StatusResponse { try await base.status() }
    public func install(packagePath: String) async throws { try await base.install(packagePath: packagePath) }
    // install と同じくセッション不要の host 側操作なので回復なしで素通し
    public func clearAppData(bundleID: String) async throws { try await base.clearAppData(bundleID: bundleID) }
    public var lastActionNote: String? { base.lastActionNote }
    public var lastLaunchTiming: LaunchTiming? { base.lastLaunchTiming }

    public func launch(bundleID: String) async throws {
        try await base.launch(bundleID: bundleID)
        lastBundleID = bundleID
    }

    public func activate(bundleID: String) async throws {
        try await base.activate(bundleID: bundleID)
        lastBundleID = bundleID
    }

    public func openAppSwitcher() async throws { try await withRecovery { try await base.openAppSwitcher() } }
    public func home() async throws { try await withRecovery { try await base.home() } }
    public func back() async throws { try await withRecovery { try await base.back() } }
    public func snapshot() async throws -> SnapshotResponse { try await withRecovery { try await base.snapshot() } }
    /// bypassingCache 版の素通し(既定実装に任せるとフラグが落ちて最内へ届かない。
    /// SnapshotCacheBypassForwardingTests がラッパー全体でこれを守る)
    public func snapshot(bypassingCache: Bool) async throws -> SnapshotResponse {
        try await withRecovery { try await base.snapshot(bypassingCache: bypassingCache) }
    }
    public var supportsCacheBypass: Bool { base.supportsCacheBypass }
    public func tap(x: Double, y: Double) async throws { try await withRecovery { try await base.tap(x: x, y: y) } }
    public func swipe(_ direction: FTSwipeDirection) async throws {
        try await withRecovery { try await base.swipe(direction) }
    }
    /// 用途つき版の素通し(FastLaunchDriver の注記と同じ理由)
    public func swipe(_ direction: FTSwipeDirection, intent: FTSwipeIntent) async throws {
        try await withRecovery { try await base.swipe(direction, intent: intent) }
    }

    public func drag(fromX: Double, fromY: Double, toX: Double, toY: Double,
                     pressSeconds: Double, durationSeconds: Double) async throws {
        try await withRecovery {
            try await base.drag(fromX: fromX, fromY: fromY, toX: toX, toY: toY,
                                pressSeconds: pressSeconds, durationSeconds: durationSeconds)
        }
    }

    public func press(x: Double, y: Double, duration: Double) async throws {
        try await withRecovery { try await base.press(x: x, y: y, duration: duration) }
    }

    public func screenshot() async throws -> Data { try await withRecovery { try await base.screenshot() } }
    // ref を使わない(フォーカス中要素へ作用する)ので tap(x:y:) と同じ扱い: 1回だけ回復+再試行する
    public func pressEnter() async throws { try await withRecovery { try await base.pressEnter() } }
    // ref を取らず古びる状態も無いので withRecovery でよい(clearInput 側の recoverAndRethrow は不要)
    public func hideKeyboard() async throws { try await withRecovery { try await base.hideKeyboard() } }
    /// terminate 後は回復対象にしない。ブリッジ側 handleTerminate も app=nil にするため以降は 409 に
    /// なるが、これは「意図してセッションを終わらせた」状態であって復旧すべき障害ではない。
    /// ここで lastBundleID を残すと、次の snapshot が activate で**アプリを勝手に起動し直し**、
    /// 明示的な terminateApp を黙って打ち消してしまう。
    public func terminate() async throws {
        try await base.terminate()
        lastBundleID = nil
    }

    // ref を使う操作は再試行禁止(冒頭コメント参照)。409 はセッションだけ張り直した上で
    // 文言を差し替えて再スローする。次のステップの snapshot から ref が振り直され復帰できる。
    public func tap(ref: Int) async throws {
        do {
            try await base.tap(ref: ref)
        } catch {
            try await recoverAndRethrow(error)
        }
    }

    public func type(ref: Int?, text: String) async throws {
        do {
            try await base.type(ref: ref, text: text)
        } catch {
            try await recoverAndRethrow(error)
        }
    }

    public func clearInput(ref: Int?) async throws {
        do {
            try await base.clearInput(ref: ref)
        } catch {
            try await recoverAndRethrow(error)
        }
    }

    public func press(ref: Int, duration: Double) async throws {
        do {
            try await base.press(ref: ref, duration: duration)
        } catch {
            try await recoverAndRethrow(error)
        }
    }

    private func recoverAndRethrow(_ error: Error) async throws -> Never {
        guard isSessionLost(error) else { throw error }
        // launch 前(lastBundleID なし)は張り直す相手が分からない。実際に張り直したときだけ
        // 「復帰します」と言う(していないのに言うと切り分けを誤らせる)。
        let recovered = lastBundleID != nil
        if recovered { await recover() }
        throw DriverError.badResponse(status: 409, body:
            "the XCUITest runner session was lost (the runner may have restarted). "
            + (recovered
               ? "The session was re-established; the next step recovers. "
               : "There is nothing to re-establish the session against (not launched, or already terminated). "
                 + "A launchApp is needed first. ")
            + "This step is not retried because its ref (an element number from the previous snapshot) is now invalid")
    }
}
