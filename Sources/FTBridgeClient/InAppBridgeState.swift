// in-app ブリッジ(dylib 注入。pid ファイルを持たずホストアプリのプロセス内に常駐)の状態ファイル。
// 書き手: InAppLauncher.relaunch(起動成功時)。読み手: BridgeLauncher.stop/stopAll/stopMatching・
// PortHolder.stopIfOwnedBridge(bridge down 系コマンドが simctl terminate で後始末するための、
// pid ファイルの代替)。

import Foundation
import FTCore

public enum InAppBridgeState {
    public static func url(stateDir: URL, port: UInt16) -> URL {
        stateDir.appendingPathComponent("bridge-\(port).inapp")
    }

    /// udid と bundleID を1行・空白区切りで記録する。ベストエフォート(失敗は無視)
    public static func write(stateDir: URL, port: UInt16, udid: String, bundleID: String) {
        try? FileManager.default.createDirectory(at: stateDir, withIntermediateDirectories: true)
        try? "\(udid) \(bundleID)".write(to: url(stateDir: stateDir, port: port),
                                         atomically: true, encoding: .utf8)
    }

    static func read(at path: URL) -> (udid: String, bundleID: String)? {
        guard let content = try? String(contentsOf: path, encoding: .utf8) else { return nil }
        let parts = content.trimmingCharacters(in: .whitespacesAndNewlines).split(separator: " ")
        guard parts.count == 2 else { return nil }
        return (String(parts[0]), String(parts[1]))
    }

    /// 記録された udid+bundleID を simctl terminate してからファイルを削除する。
    /// アプリ/シミュレータが既に死んでいる場合の terminate 失敗は無視する(stale ファイル許容)。
    public static func terminateAndRemove(at path: URL) {
        if let state = read(at: path) {
            _ = try? Shell.run(["xcrun", "simctl", "terminate", state.udid, state.bundleID])
        }
        try? FileManager.default.removeItem(at: path)
    }
}
