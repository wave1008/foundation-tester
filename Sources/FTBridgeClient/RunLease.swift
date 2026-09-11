// run(fleetest api run)がデバイスを使用中であることを示すハートビート lease。
// 書き手: RunOrchestrator(FTCore、closure 注入経由)。読み手: ApiMonitorCommand(watchdog の
// inRun 判定)。RecordingLease.swift の姉妹型(同じ pid+mtime 鮮度の lease。示す事象が違うだけ)。

import FTCore
import Foundation

public enum RunLease {
    public static let stalenessSeconds: TimeInterval = 15

    /// key: iOS=シミュレータ UDID / Android=adb serial
    public static func leaseURL(stateDir: URL, key: String) -> URL {
        stateDir.appendingPathComponent("run-\(key).lease")
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
        holderPID(stateDir: stateDir, key: key, now: now) != nil
    }

    /// 鮮度のある lease の保持者 pid(RunLeaseGuard.conflicts が名指しの拒否メッセージに使う)。
    /// isFresh と同じ条件(生存+mtime)を満たさなければ nil
    public static func holderPID(stateDir: URL, key: String, now: Date = Date()) -> Int32? {
        let url = leaseURL(stateDir: stateDir, key: key)
        guard let pidString = try? String(contentsOf: url, encoding: .utf8),
              let pid = Int32(pidString.trimmingCharacters(in: .whitespacesAndNewlines)),
              pid > 0, ProcessLiveness.isAlive(pid) else { return nil }
        guard let attrs = try? FileManager.default.attributesOfItem(atPath: url.path),
              let mtime = attrs[.modificationDate] as? Date else { return nil }
        return now.timeIntervalSince(mtime) <= stalenessSeconds ? pid : nil
    }
}
