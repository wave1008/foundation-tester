// in-app ブリッジ(dylib 注入。pid ファイルを持たずホストアプリのプロセス内に常駐)の状態ファイル。
// 書き手: InAppLauncher.relaunch(起動成功時)。読み手: BridgeLauncher.stop/stopAll/stopMatching・
// PortHolder.stopIfOwnedBridge(bridge down 系コマンドが simctl terminate で後始末するための、
// pid ファイルの代替)・BridgeProvisioner(**注入済み dylib の出所**の判定)。
//
// **sourceDigest = 注入した dylib のソース集合(BridgeSourceSet.inApp)の digest**。
// これを持たないと「ソースを変えたのに稼働中のブリッジが再利用され、変更が1度も実行されないまま
// 緑になる」(2026-08-20 に実測: InAppSettle.swift を書き換えて run しても dylib は作り直されず、
// 版を下げても稼働中の新しいブリッジがそのまま応答した)。**版の一致だけでは足りない** ——
// 版を上げ忘れた変更も、決定を行うプロセスが1ビルド古い場合(run 内の swift build より前に
// 起動している)も素通りする。digest は**そのときのソースから計算する**のでどちらにも掛かる。

import Foundation
import FTCore

public enum InAppBridgeState {
    public static func url(stateDir: URL, port: UInt16) -> URL {
        stateDir.appendingPathComponent("bridge-\(port).inapp")
    }

    /// udid・bundleID・注入した dylib の sourceDigest を1行・空白区切りで記録する。
    /// ベストエフォート(失敗は無視)
    public static func write(stateDir: URL, port: UInt16, udid: String, bundleID: String,
                             sourceDigest: String? = nil) {
        try? FileManager.default.createDirectory(at: stateDir, withIntermediateDirectories: true)
        let line = [udid, bundleID, sourceDigest].compactMap { $0 }.joined(separator: " ")
        try? line.write(to: url(stateDir: stateDir, port: port), atomically: true, encoding: .utf8)
    }

    /// 3 語目(sourceDigest)は**旧版が書いた 2 語の記録**では nil になる。
    /// 読み手は nil を「出所不明」として扱うこと(= 再利用しない側に倒す)
    static func read(at path: URL) -> (udid: String, bundleID: String, sourceDigest: String?)? {
        guard let content = try? String(contentsOf: path, encoding: .utf8) else { return nil }
        let parts = content.trimmingCharacters(in: .whitespacesAndNewlines).split(separator: " ")
        guard parts.count == 2 || parts.count == 3 else { return nil }
        return (String(parts[0]), String(parts[1]),
                parts.count == 3 ? String(parts[2]) : nil)
    }

    /// 指定ポートの記録(無ければ nil)。BridgeProvisioner の再利用判定が使う
    public static func sourceDigest(stateDir: URL, port: UInt16) -> String? {
        read(at: url(stateDir: stateDir, port: port))?.sourceDigest
    }

    /// 記録された udid+bundleID を simctl terminate してからファイルを削除する。
    /// アプリ/シミュレータが既に死んでいる場合の terminate 失敗は無視する(stale ファイル許容)。
    public static func terminateAndRemove(at path: URL) {
        if let state = read(at: path) {
            // teardown 経路。simctl が wedge しても停止が永久ブロックしないよう時限化(15s)。
            _ = try? Shell.run(["xcrun", "simctl", "terminate", state.udid, state.bundleID], timeout: 15)
        }
        try? FileManager.default.removeItem(at: path)
    }
}
