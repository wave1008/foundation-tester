// ResultsOutputCache.swift
// `fleetest api results` の出力キャッシュ(<project>/.fleetest/results-cache/)。
// 集計は入力(results/ の run 集合)の純関数なので、入力の指紋(RunResultsStore.scanFingerprint)と
// 引数・実行ファイルの識別が一致し、かつ窓の境界(since)をまたいだ記録が無ければ前回の出力を
// そのまま返せる。E2E-iOS 90 日分(1,092 run・2万記録)で 4.1s → 指紋の算出だけ(数十 ms)。
//
// 厳密性の担保(近似を置かない):
// - 入力の指紋 = 読む集合と同じ列挙 + run ごとの stat 2回(RunResultsStore.scanFingerprint の doc。
//   指紋は走査より先に取る)
// - `--since` は相対指定("90d")だと呼ぶたびに動くので鍵に入れず、**引数の文字列**を鍵に入れて
//   「同じ引数なら since は単調に進む」ことを使う。有効条件は
//   `cachedSinceKey <= requestedSinceKey <= oldestIncludedStartedAt`
//   (= 前回含めた最古の記録より手前に境界がある = 何も窓から落ちていない。
//   境界より古い記録が新たに含まれることは since が進む向きでは起きない)。
//   絶対指定("2026-06-01")は両者が等しく常に成立する
// - 実行ファイルの mtime/size を鍵に入れる(集計ロジックや出力契約を変えて建て直せば必ず外れる。
//   キャッシュ形式の版を手で上げる規律に頼らない)
// - since/generatedAt だけは出力のたびに変わるので body の外に置き、印字時に合成する
//   (ResultsOutputCache.compose)。body は既存の集計をそのまま JSON にしたもの
// - trend(--scenario)は body に入れず、scenarioID → 記録ファイルの索引を別ファイルに持つ。
//   ヒット時はそのファイルだけ読んで trend を計算する(索引は指紋が同じ間だけ有効)

import Foundation

public enum ResultsOutputCache {

    public static let formatVersion = 1

    /// body(since/generatedAt/trend 抜きの出力)と有効判定に要る値
    public struct Entry: Codable, Equatable, Sendable {
        public var formatVersion: Int
        /// 引数 + 実行ファイル識別の鍵(argumentsKey の出力)
        public var key: String
        public var scanDigest: String
        /// 保存時の since(RunResultsStore.windowKey 形式)
        public var sinceKey: String
        /// 保存時に窓へ含めた記録(run.json と scenario 記録の両方)の最古の startedAt。
        /// 1件も無ければ nil(= 空の窓。since が進んでも空のまま = 常に有効)
        public var oldestIncludedStartedAt: String?
        /// since/generatedAt/trend を含まない出力 JSON(`{` で始まり、1つ以上のキーを持つ)
        public var body: String

        public init(formatVersion: Int = ResultsOutputCache.formatVersion, key: String, scanDigest: String,
                    sinceKey: String, oldestIncludedStartedAt: String?, body: String) {
            self.formatVersion = formatVersion
            self.key = key
            self.scanDigest = scanDigest
            self.sinceKey = sinceKey
            self.oldestIncludedStartedAt = oldestIncludedStartedAt
            self.body = body
        }
    }

    /// scenarioID → その記録ファイル(resultsDir 相対パス)。Entry と同じ scanDigest の間だけ有効
    public struct TrendIndex: Codable, Equatable, Sendable {
        public var formatVersion: Int
        public var scanDigest: String
        public var files: [String: [String]]

        public init(formatVersion: Int = ResultsOutputCache.formatVersion, scanDigest: String, files: [String: [String]]) {
            self.formatVersion = formatVersion
            self.scanDigest = scanDigest
            self.files = files
        }
    }

    public enum Miss: Equatable, Sendable {
        case noEntry
        case unreadable
        case formatVersion
        case key
        case scanDigest
        /// since が前回より手前(引数が変わらなければ起きない)
        case sinceMovedBackward
        /// 前回含めた最古の記録が窓から落ちた
        case recordAgedOut
    }

    // MARK: - 鍵

    /// 引数と実行ファイルの識別を1つの文字列に畳む。`executable` は Bundle.main.executableURL
    /// (nil なら実行ファイルを鍵にできない = 常にミス側へ倒すため乱数を混ぜる)
    public static func argumentsKey(arguments: [String], executable: URL?) -> String {
        var parts = arguments
        if let executable {
            var status = stat()
            if stat(executable.path, &status) == 0 {
                let mtime = status.st_mtimespec
                parts.append("exe=\(mtime.tv_sec).\(mtime.tv_nsec):\(status.st_size)")
            } else {
                parts.append("exe=unstattable:\(UUID().uuidString)")
            }
        } else {
            parts.append("exe=unknown:\(UUID().uuidString)")
        }
        return parts.joined(separator: "\u{1}")
    }

    // MARK: - 有効判定(純関数)

    public static func validate(_ entry: Entry?, readable: Bool = true, key: String,
                                scanDigest: String, sinceKey: String) -> Miss? {
        guard readable else { return .unreadable }
        guard let entry else { return .noEntry }
        guard entry.formatVersion == formatVersion else { return .formatVersion }
        guard entry.key == key else { return .key }
        guard entry.scanDigest == scanDigest else { return .scanDigest }
        guard entry.sinceKey <= sinceKey else { return .sinceMovedBackward }
        if let oldest = entry.oldestIncludedStartedAt, sinceKey > oldest {
            return .recordAgedOut
        }
        return nil
    }

    // MARK: - 出力の合成

    /// `{"generatedAt":…,"since":…,("trend":…,)` + body の `{` 以降。body は `{` で始まり
    /// 1つ以上のキーを持つこと(空の `{}` だと末尾カンマが残る)。満たさなければ nil
    public static func compose(generatedAt: String, since: String, trendJSON: String?, body: String) -> String? {
        guard body.hasPrefix("{"), body.count > 2 else { return nil }
        var head = "{\"generatedAt\":\(jsonString(generatedAt)),\"since\":\(jsonString(since)),"
        if let trendJSON {
            head += "\"trend\":\(trendJSON),"
        }
        return head + body.dropFirst()
    }

    static func jsonString(_ value: String) -> String {
        var out = "\""
        for scalar in value.unicodeScalars {
            switch scalar {
            case "\"": out += "\\\""
            case "\\": out += "\\\\"
            case "\n": out += "\\n"
            case "\r": out += "\\r"
            case "\t": out += "\\t"
            case _ where scalar.value < 0x20: out += String(format: "\\u%04x", scalar.value)
            default: out.unicodeScalars.append(scalar)
            }
        }
        return out + "\""
    }

    // MARK: - 置き場と読み書き(best-effort)

    public static func dir(stateDir: URL) -> URL {
        stateDir.appendingPathComponent("results-cache")
    }

    public static func entryURL(stateDir: URL) -> URL {
        dir(stateDir: stateDir).appendingPathComponent("api-results.json")
    }

    public static func trendIndexURL(stateDir: URL) -> URL {
        dir(stateDir: stateDir).appendingPathComponent("api-results-trend-index.json")
    }

    /// (entry, readable)。ファイルが無い = (nil, true)、あるのに読めない/壊れている = (nil, false)
    public static func readEntry(stateDir: URL) -> (entry: Entry?, readable: Bool) {
        read(Entry.self, at: entryURL(stateDir: stateDir))
    }

    public static func readTrendIndex(stateDir: URL) -> TrendIndex? {
        read(TrendIndex.self, at: trendIndexURL(stateDir: stateDir)).entry
    }

    private static func read<T: Decodable>(_ type: T.Type, at url: URL) -> (entry: T?, readable: Bool) {
        guard FileManager.default.fileExists(atPath: url.path) else { return (nil, true) }
        guard let data = try? Data(contentsOf: url),
              let value = try? JSONDecoder().decode(type, from: data) else { return (nil, false) }
        return (value, true)
    }

    /// 書けなくても失敗にしない(読み取り専用の環境では毎回計算するだけ)
    public static func write(_ entry: Entry, trendIndex: TrendIndex, stateDir: URL) {
        try? FileManager.default.createDirectory(at: dir(stateDir: stateDir), withIntermediateDirectories: true)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        if let data = try? encoder.encode(entry) {
            try? data.write(to: entryURL(stateDir: stateDir), options: .atomic)
        }
        if let data = try? encoder.encode(trendIndex) {
            try? data.write(to: trendIndexURL(stateDir: stateDir), options: .atomic)
        }
    }
}
