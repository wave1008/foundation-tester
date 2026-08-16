// 凍結の確定状態を**プロセスを跨いで配る**共有ストア。
//
// 書き手: run 前トリアージ(BlankWorkerTriage 経由。凍結を見つけた時点で publish し、回復したら
//         clear する)/ デバイスモニターの観測段。
// 読み手: デバイスモニター(タイルとカウンタ)。将来 MCP から見せるときも同じ口を使う。
//
// **なぜファイル越しなのか**: run とモニターは別プロセスで、互いに接続していない。
// `.ftester/run-<key>.lease` / `recording-<key>.lease` が既に同じ形(pid + mtime で鮮度を見る)
// で動いており、モニターはそれを毎サイクル読んでいる(ApiMonitorCommand の inRun/recording)。
// 同じ棚に置くのが最も配線が少ない。RunLease.swift の姉妹型。
//
// **鮮度は pid 生存が主**: 凍結の回復は数分かかることがあり、短い mtime 期限だと回復途中に
// 表示が消える。観測者が生きている限り有効とし、mtime は「観測者が clear せず死に、しかも
// pid が再利用された」場合の backstop としてだけ持つ。

import Foundation

public enum DeviceFrozenStore {
    /// mtime の backstop(秒)。pid 生存チェックが主なので長めでよい
    public static let stalenessSeconds: TimeInterval = 1800

    /// key: iOS=シミュレータ UDID / Android=adb serial(`RunLease` と同じキー体系)
    public static func entryURL(stateDir: URL, key: String) -> URL {
        stateDir.appendingPathComponent("frozen-\(key).json")
    }

    /// 保存形。`evidence` は FrozenVerdict がそのまま Codable
    private struct Entry: Codable {
        let pid: Int32
        let at: TimeInterval
        let verdict: FrozenVerdict
    }

    /// 凍結を公表する。**健全(根拠なし)を渡したら公表ではなく削除**にする ——
    /// 「健全と書かれたファイル」と「ファイルが無い」を両方扱うと読み手が2形を持つことになる
    public static func publish(stateDir: URL, key: String, verdict: FrozenVerdict,
                               pid: Int32 = ProcessInfo.processInfo.processIdentifier,
                               now: Date = Date()) {
        guard verdict.isSuspected || verdict.isFrozen else {
            clear(stateDir: stateDir, key: key)
            return
        }
        try? FileManager.default.createDirectory(at: stateDir, withIntermediateDirectories: true)
        let entry = Entry(pid: pid, at: now.timeIntervalSince1970, verdict: verdict)
        guard let data = try? JSONEncoder().encode(entry) else { return }
        try? data.write(to: entryURL(stateDir: stateDir, key: key), options: .atomic)
    }

    public static func clear(stateDir: URL, key: String) {
        try? FileManager.default.removeItem(at: entryURL(stateDir: stateDir, key: key))
    }

    /// 公表されている判定。**書き手が死んでいたら無視する**(凍結したまま run が落ちても
    /// カウンタが永遠に残らない)。無ければ nil
    public static func current(stateDir: URL, key: String, now: Date = Date()) -> FrozenVerdict? {
        guard let data = try? Data(contentsOf: entryURL(stateDir: stateDir, key: key)),
              let entry = try? JSONDecoder().decode(Entry.self, from: data) else { return nil }
        guard entry.pid > 0, kill(entry.pid, 0) == 0 else { return nil }
        guard now.timeIntervalSince1970 - entry.at <= stalenessSeconds else { return nil }
        return entry.verdict
    }

    /// 自分が書いた分を全部消す(run の終了時に呼ぶ)。
    /// 他プロセスの公表は消さない = pid で自分のものだけを選ぶ
    public static func clearAll(stateDir: URL,
                                pid: Int32 = ProcessInfo.processInfo.processIdentifier) {
        guard let names = try? FileManager.default.contentsOfDirectory(atPath: stateDir.path) else { return }
        for name in names where name.hasPrefix("frozen-") && name.hasSuffix(".json") {
            let url = stateDir.appendingPathComponent(name)
            guard let data = try? Data(contentsOf: url),
                  let entry = try? JSONDecoder().decode(Entry.self, from: data),
                  entry.pid == pid else { continue }
            try? FileManager.default.removeItem(at: url)
        }
    }
}
