// ライブ操作(このプロセス = `api live serve`)が駆動している台の印。書式・鍵・掃除は
// `FTBridgeClient.MCPDeviceLease` と完全に共有する(ファイル名接頭辞は `mcp-` のまま変えない
// —— 読み手(DeviceBooter.deviceInUseRefusal / ProfileRunner.limitingDevicesAvoidingMCP)を
// 増やさないため。ライブ操作も「対話セッション」の一種として同じ印を書く)。
//
// 実地(B5): ライブ操作がこの印を1つも書いていなかったため、`api stop-device` 等の
// 台ごとの調停(run-lease / MCP の印しか読まない)がライブ操作中の台を無言で止め、シミュレータごと
// 落としていた。コマンドが通るたびに refresh() で上書きし(MCPServer.call の markDeviceInUse と
// 同じ粒度)、serve の終了時に release() で自分の印だけを消す。

import FTAndroid
import FTBridgeClient
import Foundation

struct LiveDeviceLease {
    let stateDir: URL
    let key: String
    let pid: Int32
    let log: (String) -> Void

    /// 鍵は iOS = `--udid`、Android = 解決済み serial(`--serial` 省略時は接続中の1台に
    /// 自動決定される値を使う——駆動先と印の鍵がずれると別の台を守ることになる)。
    /// RepoRoot が見つからない・鍵が決まらない(iOS で `--udid` 未指定)ときは nil
    /// (印を置かない=無警告のまま。ベストエフォート)
    static func make(platform: String, udid: String?, explicitAndroidSerial: String?,
                     log: @escaping (String) -> Void) -> LiveDeviceLease? {
        guard let repoRoot = try? RepoRoot.find() else { return nil }
        let key = platform == "ios"
            ? udid
            // ログは既に driverOptions.makeDriver() 内の解決で1回出ている(重複させない)
            : try? AndroidTargetResolution.serial(explicit: explicitAndroidSerial, log: { _ in })
        guard let key, !key.isEmpty else { return nil }
        return LiveDeviceLease(stateDir: repoRoot.appendingPathComponent(".fleetest"), key: key,
                               pid: ProcessInfo.processInfo.processIdentifier, log: log)
    }

    /// その台を run か別の対話セッションが使用中なら、既存の警告文をそのまま stderr へ流す
    /// (新しい文言を作らない。MCPServer.markDeviceInUse と同じ口)
    func refresh() {
        if let warning = MCPDeviceLease.writeAndWarnIfInUse(stateDir: stateDir, key: key, pid: pid) {
            log(warning)
        }
    }

    func release() {
        MCPDeviceLease.removeAll(stateDir: stateDir, pid: pid)
    }
}
