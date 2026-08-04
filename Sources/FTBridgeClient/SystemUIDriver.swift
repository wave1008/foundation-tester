// ハイブリッドのフォールバック用ドライバ。XCUITest ブリッジを「springboard 参照(非起動)」で駆動し、
// アプリ上に載ったシステム UI(権限ダイアログ・アラート等=別プロセス)を snapshot/tap する。
// in-app ブリッジは自プロセスしか見えないので、StepExecutor が primary(in-app)で解決できないとき
// これを fallbackDriver として使う。
//
// 重要な順序契約: /session springboard はブリッジ側で「起動せず参照のみ」だが refFrames を毎回クリアする。
// そのため snapshot() でだけ session し、tap()/press() は session せず直前 snapshot の ref を使う
// (StepExecutor は snapshot→resolve→act の順で同一 driver を使うのでこれで整合する)。

import Foundation
import FTCore

public final class SystemUIDriver: AppDriver {
    private let client: BridgeClient

    public init(port: UInt16) {
        self.client = BridgeClient(port: port)
    }

    public func snapshot() async throws -> SnapshotResponse {
        try await snapshot(bypassingCache: false)
    }

    /// bypassingCache 版の素通し(既定実装に任せるとフラグが落ちて最内へ届かない。
    /// SnapshotCacheBypassForwardingTests がラッパー全体でこれを守る)。
    /// **張り直しは必ずこちらに置く** —— snapshot() を素通し側にすると片方だけ張り直しを飛ばす
    public func snapshot(bypassingCache: Bool) async throws -> SnapshotResponse {
        // 参照を張り直してから live ツリー(現在のアラート含む)を取る。session は refFrames をクリアし、
        // 続く snapshot が振り直すので、この直後の tap は同じ ref で当たる。
        try await client.launch(bundleID: "com.apple.springboard")
        return try await client.snapshot(bypassingCache: bypassingCache)
    }
    public var supportsCacheBypass: Bool { client.supportsCacheBypass }

    public func tap(ref: Int) async throws { try await client.tap(ref: ref) }
    public func type(ref: Int?, text: String) async throws { try await client.type(ref: ref, text: text) }
    public func pressEnter() async throws { try await client.pressEnter() }
    public func clearInput(ref: Int?) async throws { try await client.clearInput(ref: ref) }
    public func hideKeyboard() async throws { try await client.hideKeyboard() }
    public func press(ref: Int, duration: Double) async throws { try await client.press(ref: ref, duration: duration) }
    public func tap(x: Double, y: Double) async throws { try await client.tap(x: x, y: y) }
    public func swipe(_ direction: FTSwipeDirection) async throws { try await client.swipe(direction) }
    /// 用途つき版の素通し(FastLaunchDriver の注記と同じ理由)
    public func swipe(_ direction: FTSwipeDirection, intent: FTSwipeIntent,
                      path: FTSwipePath?) async throws {
        try await client.swipe(direction, intent: intent, path: path)
    }
    /// tapAppIcon のページ送り(flickRightToLeft 相当)用。既存 /drag ルートの素通し(新規エンドポイントではない)
    public func drag(fromX: Double, fromY: Double, toX: Double, toY: Double,
                     pressSeconds: Double, durationSeconds: Double) async throws {
        try await client.drag(fromX: fromX, fromY: fromY, toX: toX, toY: toY,
                              pressSeconds: pressSeconds, durationSeconds: durationSeconds)
    }
    public func doubleTap(x: Double, y: Double) async throws { try await client.doubleTap(x: x, y: y) }
    public func pinch(frame: FTRect?, identifier: String?, scale: Double,
                      durationSeconds: Double) async throws {
        try await client.pinch(frame: frame, identifier: identifier, scale: scale,
                               durationSeconds: durationSeconds)
    }
    /// tapAppIcon の冒頭 home() 用。**素通しを書かないと extension の 501 既定実装に落ちる**
    /// (実機で踏んだ。SystemUIDriverHomeForwardingTests が守る)
    public func home() async throws { try await client.home() }
    public func screenshot() async throws -> Data { try await client.screenshot() }
    public func status() async throws -> StatusResponse { try await client.status() }

    // ライフサイクル・install/uninstall はアプリ本体(primary=in-app)が担う。フォールバックでは no-op。
    public func install(packagePath: String) async throws {}
    public func uninstall(bundleID: String) async throws {}
    public func launch(bundleID: String) async throws {}
    public func terminate() async throws {}
    public func clearAppData(bundleID: String) async throws {}
    // /appstate はセッション不要の読み取り。フォールバック用も実体は BridgeClient なのでそのまま使える
    public func isAppForeground(bundleID: String) async throws -> Bool {
        try await client.isAppForeground(bundleID: bundleID)
    }
    public func foregroundAppID() async throws -> String? { try await client.foregroundAppID() }
    public var lastActionNote: String? { client.lastActionNote }
}
