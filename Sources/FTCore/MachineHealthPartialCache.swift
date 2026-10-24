// `fleetest api results` の machineHealth が読む**他プロジェクト**ぶんの部分結果(host ごとの行)のキャッシュ。
// machineHealth は --project で絞らず全プロジェクトの results/ を数えるので、出力キャッシュが外れるたびに他プロジェクトの
// 束(RunRecordPack)まで全部 decode していた(E2E-Android の再計算 8.0 秒 → 2.1 秒。他の 18 プロジェクトで束 約 1.8 万)。
// 行は `RunResultsQuery.mergedMachineHealth` で合わせられるので、プロジェクトごとに置いて、そのプロジェクトの入力が
// 変わったときだけ数え直す。
//
// - 置き場: `<other>/.fleetest/results-cache/machine-health-<since の引数の SHA-256>.json`(since の引数ごとに1つ。
//   ダッシュボードの 16h と CLI の 90d が交互に呼んでも互いを追い出さない)。**窓に何も無いプロジェクトには書かない**
//   (数え直しても読むものが無い。結果の無いプロジェクトに `.fleetest/` を作らない)
// - 有効判定は `ResultsOutputCache.validate` の同じ式(鍵 = since の引数 + 実行ファイル・指紋 = そのプロジェクトの
//   `scanFingerprint`・窓 = `cachedSinceKey <= requestedSinceKey <= oldestIncludedStartedAt`)。進行中の run の扱いも
//   出力キャッシュと同じ(存在だけが指紋に入る = 途中経過は完了時にまとめて反映)
// - `--no-cache` は読まない(書き直しは行う)= `--no-cache` との一致で正しさを確かめる手段を残す

import CryptoKit
import Foundation

public enum MachineHealthPartialCache {

    public static let formatVersion = 1

    public struct Entry: Codable, Equatable, Sendable {
        public var formatVersion: Int
        public var key: String
        public var scanDigest: String
        public var sinceKey: String
        /// 窓に含めた run.json と記録の最古の startedAt(1件も無ければ nil)
        public var oldestIncludedStartedAt: String?
        public var rows: [RunResultsQuery.MachineHealthRow]

        public init(formatVersion: Int = MachineHealthPartialCache.formatVersion, key: String, scanDigest: String,
                    sinceKey: String, oldestIncludedStartedAt: String?, rows: [RunResultsQuery.MachineHealthRow]) {
            self.formatVersion = formatVersion
            self.key = key
            self.scanDigest = scanDigest
            self.sinceKey = sinceKey
            self.oldestIncludedStartedAt = oldestIncludedStartedAt
            self.rows = rows
        }
    }

    public struct Part: Equatable, Sendable {
        public let rows: [RunResultsQuery.MachineHealthRow]
        public let oldestIncludedStartedAt: String?
        /// キャッシュから読んだか(診断用)
        public let fromCache: Bool
    }

    /// 1プロジェクトぶんの部分結果。有効なキャッシュがあれば `compute` を呼ばない。外れたら `compute` して書き直す
    /// (書けなくても失敗にしない)。`compute` は窓で絞った (runs, records) を返す
    public static func part(stateDir: URL, since: String, sinceKey: String, scanDigest: String, executable: URL?,
                            readCache: Bool,
                            compute: () -> (runs: [RunMetaRecord], records: [ScenarioRunRecord])) -> Part {
        let key = ResultsOutputCache.argumentsKey(arguments: [since], executable: executable)
        let url = entryURL(stateDir: stateDir, since: since)
        if readCache, let data = try? Data(contentsOf: url),
           let entry = try? JSONDecoder().decode(Entry.self, from: data),
           ResultsOutputCache.validate(
               formatVersion: entry.formatVersion, expectedFormatVersion: formatVersion,
               storedKey: entry.key, key: key, storedScanDigest: entry.scanDigest, scanDigest: scanDigest,
               storedSinceKey: entry.sinceKey, sinceKey: sinceKey,
               oldestIncludedStartedAt: entry.oldestIncludedStartedAt) == nil {
            return Part(rows: entry.rows, oldestIncludedStartedAt: entry.oldestIncludedStartedAt, fromCache: true)
        }
        let (runs, records) = compute()
        let rows = RunResultsQuery.machineHealth(runs: runs, records: records)
        let oldest = (runs.map(\.startedAt) + records.map(\.startedAt)).min()
        guard !runs.isEmpty || !records.isEmpty else {
            return Part(rows: rows, oldestIncludedStartedAt: oldest, fromCache: false)
        }
        let entry = Entry(key: key, scanDigest: scanDigest, sinceKey: sinceKey,
                          oldestIncludedStartedAt: oldest, rows: rows)
        try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        if let data = try? encoder.encode(entry) {
            try? data.write(to: url, options: .atomic)
        }
        return Part(rows: rows, oldestIncludedStartedAt: oldest, fromCache: false)
    }

    /// since の引数(相対指定 "90d" 等の文字列そのまま)ごとに1ファイル。**名前は SHA-256** —— 引数をそのまま(16進でも)
    /// 名前にすると、長い --since でファイル名の上限(255 バイト)を超えて書き込みが黙って失敗し、毎回外れる
    public static func entryURL(stateDir: URL, since: String) -> URL {
        let digest = SHA256.hash(data: Data(since.utf8)).map { String(format: "%02x", $0) }.joined()
        return ResultsOutputCache.dir(stateDir: stateDir).appendingPathComponent("machine-health-\(digest).json")
    }
}
