// launch(bundleID:) 前にインストール済みか検査する AppDriver ラッパー(CoreSimulator 直叩き優先・
// 利用不能なら simctl get_app_container)。未インストールのまま launch すると XCUITest ランナーの
// main queue がハングする(~45s → ランナー死亡)ため、その場合は launch を呼ばず即座にエラーで中断する。

import Foundation
import FTCore

public enum LaunchPreflightError: Error, LocalizedError {
    case appNotInstalled(bundleID: String, udid: String)
    /// simctl を実行できなかった(xcrun 不在・spawn 失敗等)。未インストールとは区別する
    /// (「インストールされていません」と誤診断してユーザーを誤誘導しないため)
    case checkFailed(bundleID: String, detail: String)

    public var errorDescription: String? {
        switch self {
        case .appNotInstalled(let bundleID, let udid):
            return "app \(bundleID) is not installed on the simulator (\(udid))"
                + " (launching while uninstalled hangs the XCUITest runner, so the preflight aborts). "
                + "Check the install via the run profile (appPath + autoInstall in apps/<name>.json). "
        case .checkFailed(let bundleID, let detail):
            return "could not run the install preflight (simctl get_app_container) for app \(bundleID)"
                + " (whether it is installed is unknown). Check the Xcode command-line tools: \(detail)"
        }
    }
}

public final class LaunchPreflightDriver: AppDriver {
    private let base: AppDriver
    private let udid: String
    private var confirmedInstalled: Set<String> = []

    public init(base: AppDriver, udid: String) {
        self.base = base
        self.udid = udid
    }

    public func status() async throws -> StatusResponse { try await base.status() }
    public func install(packagePath: String) async throws { try await base.install(packagePath: packagePath) }
    public func clearAppData(bundleID: String) async throws { try await base.clearAppData(bundleID: bundleID) }
    public var lastActionNote: String? { base.lastActionNote }
    public var lastLaunchTiming: LaunchTiming? { base.lastLaunchTiming }

    public func launch(bundleID: String) async throws {
        try ensureInstalled(bundleID: bundleID)
        try await base.launch(bundleID: bundleID)
    }

    // activate も launch と同じ /session を叩くため、未インストール時のランナーハングは同経路
    public func activate(bundleID: String) async throws {
        try ensureInstalled(bundleID: bundleID)
        try await base.activate(bundleID: bundleID)
    }

    private func ensureInstalled(bundleID: String) throws {
        if confirmedInstalled.contains(bundleID) { return }
        // CoreSimulator 直叩き優先(simctl get_app_container 約703ms → ほぼ0ms・2026-08-02実測)。
        // シム利用不能なら simctl へフォールバック(FT_SIMULATOR_CONTROL=simctl で強制)
        if let installed = CoreSimAppControl.isInstalled(udid: udid, bundleID: bundleID) {
            guard installed else {
                throw LaunchPreflightError.appNotInstalled(bundleID: bundleID, udid: udid)
            }
            confirmedInstalled.insert(bundleID)
            return
        }
        let container: Shell.Result
        do {
            container = try Shell.run(["xcrun", "simctl", "get_app_container", udid, bundleID])
        } catch {
            throw LaunchPreflightError.checkFailed(bundleID: bundleID, detail: "\(error)")
        }
        guard container.status == 0,
              !container.output.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw LaunchPreflightError.appNotInstalled(bundleID: bundleID, udid: udid)
        }
        confirmedInstalled.insert(bundleID)
    }
    public func openAppSwitcher() async throws { try await base.openAppSwitcher() }
    public func home() async throws { try await base.home() }
    public func snapshot() async throws -> SnapshotResponse { try await base.snapshot() }
    /// bypassingCache 版の素通し(既定実装に任せるとフラグが落ちて最内へ届かない。
    /// SnapshotCacheBypassForwardingTests がラッパー全体でこれを守る)
    public func snapshot(bypassingCache: Bool) async throws -> SnapshotResponse {
        try await base.snapshot(bypassingCache: bypassingCache)
    }
    public var supportsCacheBypass: Bool { base.supportsCacheBypass }
    public func tap(ref: Int) async throws { try await base.tap(ref: ref) }
    public func tap(x: Double, y: Double) async throws { try await base.tap(x: x, y: y) }
    public func type(ref: Int?, text: String) async throws { try await base.type(ref: ref, text: text) }
    public func pressEnter() async throws { try await base.pressEnter() }
    public func clearInput(ref: Int?) async throws { try await base.clearInput(ref: ref) }
    public func hideKeyboard() async throws { try await base.hideKeyboard() }
    public func back() async throws { try await base.back() }
    public func swipe(_ direction: FTSwipeDirection) async throws { try await base.swipe(direction) }
    /// 用途つき版の素通し(FastLaunchDriver の注記と同じ理由)
    public func swipe(_ direction: FTSwipeDirection, intent: FTSwipeIntent) async throws {
        try await base.swipe(direction, intent: intent)
    }

    public func drag(fromX: Double, fromY: Double, toX: Double, toY: Double,
                     pressSeconds: Double, durationSeconds: Double) async throws {
        try await base.drag(fromX: fromX, fromY: fromY, toX: toX, toY: toY,
                            pressSeconds: pressSeconds, durationSeconds: durationSeconds)
    }

    public func press(ref: Int, duration: Double) async throws {
        try await base.press(ref: ref, duration: duration)
    }

    public func press(x: Double, y: Double, duration: Double) async throws {
        try await base.press(x: x, y: y, duration: duration)
    }

    public func screenshot() async throws -> Data { try await base.screenshot() }
    public func terminate() async throws { try await base.terminate() }
}
