// XCUITest ブリッジ(BridgeRouter.swift requireApp())は POST /session でしかセッションを持たず、
// ランナー再起動でセッションが失われると全操作が 409 で落ちる。409 を投げるのはこの1箇所だけなので
// (`grep -n "409" Runner/FTesterRunnerUITests/BridgeRouter.swift`)、この経路の 409 は
// 「セッション消失」と断定してよい。
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
    public func snapshot() async throws -> SnapshotResponse { try await withRecovery { try await base.snapshot() } }
    public func tap(x: Double, y: Double) async throws { try await withRecovery { try await base.tap(x: x, y: y) } }
    public func swipe(_ direction: FTSwipeDirection) async throws {
        try await withRecovery { try await base.swipe(direction) }
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
    public func terminate() async throws { try await base.terminate() }

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
            "XCUITest ランナーのセッションが失われました(ランナー再起動の可能性)。"
            + (recovered
               ? "セッションは張り直したので次のステップから復帰します。"
               : "まだ launch していないためセッションを張り直せません(先に launchApp が要ります)。")
            + "このステップは ref(直前スナップショットの要素番号)が無効になるため再試行しません")
    }
}
