// xcuitest エンジンの launch を高速化する AppDriver ラッパー(既定で装着。FT_NO_FAST_LAUNCH=1 で
// 従来の XCUIApplication.launch() に戻せる)。
// XCUIApplication.launch()(実測 約4.6s)の代わりに simctl terminate+launch でアプリを再起動し、
// ランナーへは activate(プロキシ接続+前面化+整定 約1.1s)を頼む。シナリオ全体で −14〜19%。
// launch の「再起動」意味論は維持される。
// 注: attachOnly(整定なし接続 約0.1s)も試したが、浮いた整定コストが最初のステップの
// ポーリング待ちに移動して相殺・むしろ微悪化(bench-7 vs bench-8)のため activate を採用。

import Foundation
import FTCore

public final class FastLaunchDriver: AppDriver {
    private let base: BridgeClient
    private let udid: String

    public init(base: BridgeClient, udid: String) {
        self.base = base
        self.udid = udid
    }

    public func launch(bundleID: String) async throws {
        // terminate は未起動なら失敗してよい(冪等化)
        _ = try? Shell.run(["xcrun", "simctl", "terminate", udid, bundleID])
        let result = try Shell.run(["xcrun", "simctl", "launch", udid, bundleID])
        guard result.status == 0 else {
            throw DriverError.badResponse(status: Int(result.status),
                body: "simctl launch に失敗しました(fast-input の高速 launch): \(result.tail)")
        }
        // activate = プロキシ接続+前面化+初回整定(冒頭コメントの attachOnly 不採用理由を参照)
        try await base.activate(bundleID: bundleID)
    }

    public func status() async throws -> StatusResponse { try await base.status() }
    public func install(packagePath: String) async throws { try await base.install(packagePath: packagePath) }
    public func activate(bundleID: String) async throws { try await base.activate(bundleID: bundleID) }
    public func openAppSwitcher() async throws { try await base.openAppSwitcher() }
    public func home() async throws { try await base.home() }
    public func snapshot() async throws -> SnapshotResponse { try await base.snapshot() }
    public func tap(ref: Int) async throws { try await base.tap(ref: ref) }
    public func tap(x: Double, y: Double) async throws { try await base.tap(x: x, y: y) }
    public func type(ref: Int?, text: String) async throws { try await base.type(ref: ref, text: text) }
    public func swipe(_ direction: FTSwipeDirection) async throws { try await base.swipe(direction) }
    public func drag(fromX: Double, fromY: Double, toX: Double, toY: Double,
                     pressSeconds: Double, durationSeconds: Double) async throws {
        try await base.drag(fromX: fromX, fromY: fromY, toX: toX, toY: toY,
                            pressSeconds: pressSeconds, durationSeconds: durationSeconds)
    }
    public func press(ref: Int, duration: Double) async throws { try await base.press(ref: ref, duration: duration) }
    public func press(x: Double, y: Double, duration: Double) async throws {
        try await base.press(x: x, y: y, duration: duration)
    }
    public func screenshot() async throws -> Data { try await base.screenshot() }
    public func terminate() async throws { try await base.terminate() }
}
