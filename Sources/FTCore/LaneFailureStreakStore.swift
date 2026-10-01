// デバイスごとの「連続失敗の数」を run をまたいで引き継ぐ台帳(`.fleetest/lane-streak-<key>.json`)。
// 読み手・書き手は RunOrchestrator.runWorker の WorkerCircuitBreaker の周りだけ。
//
// なぜ要るか: 1 run で1台が受け取る本数が閾値(WORKER_FAILURE_CIRCUIT_THRESHOLD)未満だと、
// ブレーカは run の中でしか数えないので一度も離脱せず、毎 run 同じ不調デバイスが赤を出し続ける
// (実測: ロック画面の Android 1台が 3 run で 28 件落とした)。
//
// - 鍵は `RunOrchestrator.workerID`(`<platform>:<デバイス論理名>`)。論理名が無い経路は鍵が無く、台帳を使わない。
// - 通ったら消す。**期限は置かない**(回復したデバイスは最初の緑で戻る)。
// - 壊れた・読めないファイルは 0 として扱う(落ちない・例外を投げない)。
// - ブレーカに数えない失敗(environmentFault 等)と、中断で終わったシナリオの失敗は呼び手が書かない。
//   書き込みは read-modify-write ではなく全置換(同じ鍵の書き手は run の中で1レーンだけ)。

import Foundation

public enum LaneFailureStreakStore {
    private struct Entry: Codable {
        let consecutiveFailures: Int
        let at: TimeInterval
    }

    /// 鍵に ":" や空白が入るのでパーセントエンコードする(単射 = 別の鍵が同じファイルに潰れない)
    public static func entryURL(stateDir: URL, key: String) -> URL {
        let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "-._"))
        let encoded = key.addingPercentEncoding(withAllowedCharacters: allowed) ?? key
        return stateDir.appendingPathComponent("lane-streak-\(encoded).json")
    }

    /// 引き継ぐ連続失敗数。無い・壊れている・負数は 0
    public static func load(stateDir: URL, key: String) -> Int {
        guard let data = try? Data(contentsOf: entryURL(stateDir: stateDir, key: key)),
              let entry = try? JSONDecoder().decode(Entry.self, from: data),
              entry.consecutiveFailures > 0 else { return 0 }
        return entry.consecutiveFailures
    }

    /// 0 以下は削除(「0 と書かれたファイル」と「無い」の2形を持たない)
    public static func save(stateDir: URL, key: String, consecutiveFailures: Int,
                            now: Date = Date()) {
        guard consecutiveFailures > 0 else {
            clear(stateDir: stateDir, key: key)
            return
        }
        try? FileManager.default.createDirectory(at: stateDir, withIntermediateDirectories: true)
        let entry = Entry(consecutiveFailures: consecutiveFailures, at: now.timeIntervalSince1970)
        guard let data = try? JSONEncoder().encode(entry) else { return }
        try? data.write(to: entryURL(stateDir: stateDir, key: key), options: .atomic)
    }

    public static func clear(stateDir: URL, key: String) {
        try? FileManager.default.removeItem(at: entryURL(stateDir: stateDir, key: key))
    }
}
