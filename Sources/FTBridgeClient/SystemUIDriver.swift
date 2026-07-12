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
        // 参照を張り直してから live ツリー(現在のアラート含む)を取る。session は refFrames をクリアし、
        // 続く snapshot が振り直すので、この直後の tap は同じ ref で当たる。
        try await client.launch(bundleID: "com.apple.springboard")
        return try await client.snapshot()
    }

    public func tap(ref: Int) async throws { try await client.tap(ref: ref) }
    public func type(ref: Int?, text: String) async throws { try await client.type(ref: ref, text: text) }
    public func press(ref: Int, duration: Double) async throws { try await client.press(ref: ref, duration: duration) }
    public func tap(x: Double, y: Double) async throws { try await client.tap(x: x, y: y) }
    public func swipe(_ direction: FTSwipeDirection) async throws { try await client.swipe(direction) }
    public func screenshot() async throws -> Data { try await client.screenshot() }
    public func status() async throws -> StatusResponse { try await client.status() }

    // ライフサイクル・install はアプリ本体(primary=in-app)が担う。フォールバックでは no-op。
    public func install(packagePath: String) async throws {}
    public func launch(bundleID: String) async throws {}
    public func terminate() async throws {}
}
