// レバー2 PoC: xcuitest エンジンの launch を高速化する AppDriver ラッパー。
// XCUIApplication.launch()(実測 約4.6s。ランナー側の quiescence 込み)の代わりに
// simctl terminate+launch(実測 約2.3s)でアプリを再起動し、ランナーへは activate
// (XCUIApplication.activate() = 起動済みアプリへのプロキシ接続)だけを頼む。
// launch の「再起動」意味論は維持される。FT_FAST_INPUT(iosFastInput / --fast-input)
// 有効時のみ ScenarioRunnerMain が装着する。

import Foundation
import FTCore

public final class FastLaunchDriver: AppDriver {
    private let base: AppDriver
    private let udid: String

    public init(base: AppDriver, udid: String) {
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
        // ランナーの XCUIApplication プロキシを接続(activate は起動済みアプリには前面化+attach のみ)
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
