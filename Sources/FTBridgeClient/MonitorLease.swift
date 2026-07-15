// モニター(ftester api monitor)のハートビート lease。
// 書き手: ApiMonitorCommand(監視サイクル毎に mtime 更新)。読み手: BridgeProvisioner.provision(externalRun:)
// (相乗り provision の occupancy 判定。stalenessSeconds 以内の生存 pid のみ「監視中」とみなす)。

import Foundation

public enum MonitorLease {
    public static let stalenessSeconds: TimeInterval = 15

    /// key: iOS=シミュレータ UDID / Android=adb serial
    public static func leaseURL(stateDir: URL, key: String) -> URL {
        stateDir.appendingPathComponent("monitor-\(key).lease")
    }

    /// pid をテキストで書き込む(mtime更新がハートビート)。ベストエフォート(失敗は無視)
    public static func write(stateDir: URL, key: String, pid: Int32) {
        try? FileManager.default.createDirectory(at: stateDir, withIntermediateDirectories: true)
        try? String(pid).write(to: leaseURL(stateDir: stateDir, key: key), atomically: true, encoding: .utf8)
    }

    public static func remove(stateDir: URL, key: String) {
        try? FileManager.default.removeItem(at: leaseURL(stateDir: stateDir, key: key))
    }

    /// lease ファイル存在 + pid 生存 + mtime が stalenessSeconds 以内、の全条件を満たすときだけ true
    public static func isFresh(stateDir: URL, key: String, now: Date = Date()) -> Bool {
        let url = leaseURL(stateDir: stateDir, key: key)
        guard let pidString = try? String(contentsOf: url, encoding: .utf8),
              let pid = Int32(pidString.trimmingCharacters(in: .whitespacesAndNewlines)),
              pid > 0, kill(pid, 0) == 0 else { return false }
        guard let attrs = try? FileManager.default.attributesOfItem(atPath: url.path),
              let mtime = attrs[.modificationDate] as? Date else { return false }
        return now.timeIntervalSince(mtime) <= stalenessSeconds
    }
}
