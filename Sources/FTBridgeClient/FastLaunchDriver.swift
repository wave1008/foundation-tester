// xcuitest エンジンの launch を高速化する AppDriver ラッパー(既定で装着。FT_NO_FAST_LAUNCH=1 で
// 従来の XCUIApplication.launch() に戻せる)。
// XCUIApplication.launch()(実測 約4.6s)の代わりに CoreSimulator 直叩き(利用不能なら simctl)の
// terminate+launch でアプリを再起動し、ランナーへは activate(プロキシ接続+前面化+整定 約1.1s)を
// 頼む。シナリオ全体で −14〜19%。launch の「再起動」意味論は維持される。
// 注: attachOnly(整定なし接続 約0.1s)も試したが、浮いた整定コストが最初のステップの
// ポーリング待ちに移動して相殺・むしろ微悪化(bench-7 vs bench-8)のため activate を採用。

import Foundation
import FTCore

public final class FastLaunchDriver: AppDriver {
    private let base: BridgeClient
    private let udid: String
    private var lastLaunchTimingValue: LaunchTiming?

    public init(base: BridgeClient, udid: String) {
        self.base = base
        self.udid = udid
    }

    public func launch(bundleID: String) async throws {
        lastLaunchTimingValue = nil   // 失敗時に前回成功分の内訳を出さないための明示リセット
        // **terminate は別コールにしない**(--terminate-running-process で1往復に畳む。
        // InAppLauncher.relaunch と同じ形)。分けていた頃は simctl の往復がもう1回増え、
        // 実測で launch 1回あたり約 1.5s を捨てていた(8レーンの ios-xcuitest・2026-08-01)。
        // 未起動でも成功する(冪等)
        let clock = ContinuousClock()
        let actionStart = clock.now
        try launchViaCoreSimOrSimctl(bundleID: bundleID)
        let actionMs = continuousClockMs(clock.now - actionStart)
        // activate = プロキシ接続+前面化+初回整定(冒頭コメントの attachOnly 不採用理由を参照)
        let waitStart = clock.now
        try await base.activate(bundleID: bundleID)
        let waitMs = continuousClockMs(clock.now - waitStart)
        lastLaunchTimingValue = LaunchTiming(actionMs: actionMs, waitMs: waitMs)
    }

    /// CoreSimulator 直叩き優先(simctl launch 883〜909ms → ほぼ0ms・2026-08-02実測)。
    /// **フォールバックするのは「シムが使えない」ときだけ**(nil)。起動そのものの失敗は投げる
    /// (simctl で撃ち直しても同じ結果になり、本物の失敗を隠して二重に時間を使うだけ)。
    /// 強制的に simctl へ戻すには FT_SIMULATOR_CONTROL=simctl
    private func launchViaCoreSimOrSimctl(bundleID: String) throws {
        if let result = CoreSimAppControl.launch(
            udid: udid, bundleID: bundleID, environment: [:], terminateRunningProcess: true) {
            guard result.success else {
                throw DriverError.badResponse(status: -1,
                    body: "CoreSimulator launch failed (the fast-input fast launch): "
                        + (result.error ?? "unknown"))
            }
            return
        }
        let result = try Shell.run(
            ["xcrun", "simctl", "launch", "--terminate-running-process", udid, bundleID])
        guard result.status == 0 else {
            throw DriverError.badResponse(status: Int(result.status),
                body: "simctl launch failed (the fast-input fast launch): \(result.tail)")
        }
    }

    public func status() async throws -> StatusResponse { try await base.status() }
    public func install(packagePath: String) async throws { try await base.install(packagePath: packagePath) }
    public func clearAppData(bundleID: String) async throws { try await base.clearAppData(bundleID: bundleID) }
    public func activate(bundleID: String) async throws { try await base.activate(bundleID: bundleID) }
    public func openAppSwitcher() async throws { try await base.openAppSwitcher() }
    public func home() async throws { try await base.home() }
    public func snapshot() async throws -> SnapshotResponse { try await base.snapshot() }
    public func tap(ref: Int) async throws { try await base.tap(ref: ref) }
    public func tap(x: Double, y: Double) async throws { try await base.tap(x: x, y: y) }
    public func type(ref: Int?, text: String) async throws { try await base.type(ref: ref, text: text) }
    public func pressEnter() async throws { try await base.pressEnter() }
    public func clearInput(ref: Int?) async throws { try await base.clearInput(ref: ref) }
    public func hideKeyboard() async throws { try await base.hideKeyboard() }
    public func back() async throws { try await base.back() }
    public func swipe(_ direction: FTSwipeDirection) async throws { try await base.swipe(direction) }
    // 包むドライバは forScroll 版も必ず素通しする(既定実装は自分の swipe(_:) を呼ぶので
    // ここで受けないと**フラグが最初のラッパーで落ちる**。2026-07-31 に実際に落として
    // in-app のスクロール経路が丸ごと不発になった)
    public func swipe(_ direction: FTSwipeDirection, forScroll: Bool) async throws {
        try await base.swipe(direction, forScroll: forScroll)
    }
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
    public var lastActionNote: String? { base.lastActionNote }
    public var lastLaunchTiming: LaunchTiming? { lastLaunchTimingValue }
}
