// in-app ブリッジ(シミュレータのアプリに dylib 注入)の起動・再起動器。
// in-app ブリッジは注入先アプリのプロセス内に常駐するため自己再起動できない。
// 状態リセット(シナリオ毎の fresh 起動)はこのホスト/サブプロセス側が simctl で担う。

import Foundation
import FTCore

public struct InAppLauncher {
    public let repoRoot: URL
    public let udid: String
    public let port: UInt16

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

    /// アプリを terminate → dylib 注入付きで launch → /status 到達待ち。
    /// シナリオ開始時の fresh 状態確保(launchApp/relaunchApp)に使う。
    public func relaunch(bundleID: String) async throws {
        let dylib = Self.dylibPath(repoRoot: repoRoot)
        guard FileManager.default.fileExists(atPath: dylib.path) else {
            throw InAppLauncherError.dylibMissing(dylib.path)
        }
        _ = try? Shell.run(["xcrun", "simctl", "terminate", udid, bundleID])
        // Shell.run は /usr/bin/env 経由なので、先頭に NAME=VALUE を置けば launch されるアプリへ
        // SIMCTL_CHILD_* が伝わる(dylib 注入とブリッジポートの指定)。
        let result = try Shell.run([
            "SIMCTL_CHILD_DYLD_INSERT_LIBRARIES=\(dylib.path)",
            "SIMCTL_CHILD_FT_PORT=\(port)",
            "xcrun", "simctl", "launch", udid, bundleID,
        ])
        guard result.status == 0 else {
            throw InAppLauncherError.launchFailed(result.tail)
        }
        try await waitUntilReady()
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
            try await Task.sleep(nanoseconds: 300_000_000)
        }
        throw InAppLauncherError.notReady(lastError.map { "\($0)" } ?? "no response")
    }
}

public enum InAppLauncherError: Error, LocalizedError {
    case dylibMissing(String)
    case buildFailed(String)
    case launchFailed(String)
    case notReady(String)

    public var errorDescription: String? {
        switch self {
        case .dylibMissing(let path):
            return "in-app ブリッジの dylib が見つかりません(InAppBridge/build.sh でビルド): \(path)"
        case .buildFailed(let tail):
            return "InAppBridge/build.sh が失敗しました:\n\(tail)"
        case .launchFailed(let tail):
            return "アプリの注入起動(simctl launch)に失敗しました:\n\(tail)"
        case .notReady(let detail):
            return "in-app ブリッジが時間内に応答しませんでした: \(detail)"
        }
    }
}
