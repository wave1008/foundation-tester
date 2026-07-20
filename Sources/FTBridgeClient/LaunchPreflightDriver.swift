// launch(bundleID:) 前に simctl でインストール済みか検査する AppDriver ラッパー。未インストールの
// まま launch すると XCUITest ランナーの main queue がハングする(~45s → ランナー死亡)ため、
// その場合は launch を呼ばず即座にエラーで中断する。

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
            return "アプリ \(bundleID) はシミュレータ(\(udid))にインストールされていません"
                + "(未インストールのまま launch すると XCUITest ランナーがハングするため事前検査で中断)。"
                + "実行プロファイル(apps/<名>.json の appPath+autoInstall)でのインストールを確認してください。"
        case .checkFailed(let bundleID, let detail):
            return "アプリ \(bundleID) のインストール事前検査(simctl get_app_container)を実行できませんでした"
                + "(未インストールかどうかは不明)。Xcode コマンドラインツールの状態を確認してください: \(detail)"
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
    public func tap(ref: Int) async throws { try await base.tap(ref: ref) }
    public func tap(x: Double, y: Double) async throws { try await base.tap(x: x, y: y) }
    public func type(ref: Int?, text: String) async throws { try await base.type(ref: ref, text: text) }
    public func swipe(_ direction: FTSwipeDirection) async throws { try await base.swipe(direction) }

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
