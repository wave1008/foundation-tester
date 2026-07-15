// in-app ブリッジ(シミュレータのアプリに dylib 注入)の起動・再起動器。
// in-app ブリッジは注入先アプリのプロセス内に常駐するため自己再起動できない。
// 状態リセット(シナリオ毎の fresh 起動)はこのホスト/サブプロセス側が simctl で担う。

import Foundation
import FTCore

public struct InAppLauncher {
    public let repoRoot: URL
    public let udid: String
    public let port: UInt16

    var stateDir: URL { repoRoot.appendingPathComponent(".ftester") }

    public init(repoRoot: URL, udid: String, port: UInt16) {
        self.repoRoot = repoRoot
        self.udid = udid
        self.port = port
    }

    /// 注入する dylib(InAppBridge/build.sh の出力)
    public static func dylibPath(repoRoot: URL) -> URL {
        repoRoot.appendingPathComponent("InAppBridge/build/libFTInAppBridge.dylib")
    }

    /// dylib が未ビルドなら InAppBridge/build.sh でビルドする(BridgeLauncher の buildForTesting 相当)
    public func buildIfNeeded() throws {
        if FileManager.default.fileExists(atPath: Self.dylibPath(repoRoot: repoRoot).path) { return }
        let script = repoRoot.appendingPathComponent("InAppBridge/build.sh").path
        let result = try Shell.run(["bash", script])
        guard result.status == 0 else {
            throw InAppLauncherError.buildFailed(result.tail)
        }
    }

    /// シミュレータが Shutdown なら boot して待つ(ブート済みなら即返るが ~200ms かかるため
    /// プロビジョニング時のみ呼ぶ。relaunch には入れない=シナリオ毎の launch を遅くしない)。
    /// XCUITest 経路は xcodebuild が自動ブートするが、simctl launch はブート済みが前提。
    public func ensureBooted() throws {
        let result = try Shell.run(["xcrun", "simctl", "bootstatus", udid, "-b"])
        guard result.status == 0 else {
            throw InAppLauncherError.bootFailed(result.tail)
        }
    }

    /// アプリを dylib 注入付きで再起動 → /status 到達待ち。
    /// シナリオ開始時の fresh 状態確保(launchApp/relaunchApp)に使う。
    public func relaunch(bundleID: String) async throws {
        let dylib = Self.dylibPath(repoRoot: repoRoot)
        guard FileManager.default.fileExists(atPath: dylib.path) else {
            throw InAppLauncherError.dylibMissing(dylib.path)
        }
        // --terminate-running-process で terminate+launch を1コールに(simctl 往復を2→1)。
        // Shell.run は /usr/bin/env 経由なので、先頭に NAME=VALUE を置けば launch されるアプリへ
        // SIMCTL_CHILD_* が伝わる(dylib 注入とブリッジポートの指定)。
        let result = try Shell.run([
            "SIMCTL_CHILD_DYLD_INSERT_LIBRARIES=\(dylib.path)",
            "SIMCTL_CHILD_FT_PORT=\(port)",
            "xcrun", "simctl", "launch", "--terminate-running-process", udid, bundleID,
        ])
        guard result.status == 0 else {
            throw InAppLauncherError.launchFailed(result.tail)
        }
        try await waitUntilReady()
        // pid ファイルを持たない in-app ブリッジを bridge down 系コマンドが後始末できるよう記録
        InAppBridgeState.write(stateDir: stateDir, port: port, udid: udid, bundleID: bundleID)
    }

    public func terminate(bundleID: String) {
        _ = try? Shell.run(["xcrun", "simctl", "terminate", udid, bundleID])
    }

    public func waitUntilReady(timeout: TimeInterval = 30) async throws {
        let client = BridgeClient(port: port, timeoutSeconds: 3)
        let deadline = Date().addingTimeInterval(timeout)
        var lastError: Error?
        while Date() < deadline {
            do {
                if try await client.status().ready { return }
            } catch { lastError = error }
            // 80ms 間隔(ready 検知の遅れは平均でこの半分。300ms だと最大 +300ms 遅れる)
            try await Task.sleep(nanoseconds: 80_000_000)
        }
        throw InAppLauncherError.notReady(lastError.map { "\($0)" } ?? "no response")
    }
}

public enum InAppLauncherError: Error, LocalizedError {
    case dylibMissing(String)
    case buildFailed(String)
    case bootFailed(String)
    case launchFailed(String)
    case notReady(String)

    public var errorDescription: String? {
        switch self {
        case .dylibMissing(let path):
            return "in-app ブリッジの dylib が見つかりません(InAppBridge/build.sh でビルド): \(path)"
        case .buildFailed(let tail):
            return "InAppBridge/build.sh が失敗しました:\n\(tail)"
        case .bootFailed(let tail):
            return "シミュレータをブートできませんでした(simctl bootstatus -b):\n\(tail)"
        case .launchFailed(let tail):
            return "アプリの注入起動(simctl launch)に失敗しました"
                + "(プロビジョニング時にインストール確認済みのため、シミュレータの状態異常や"
                + "アプリのクラッシュ等を確認してください):\n\(tail)"
        case .notReady(let detail):
            return "in-app ブリッジが時間内に応答しませんでした: \(detail)"
        }
    }
}
