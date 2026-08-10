// RunResultsStore.swift
// ファイルベース実行結果 DB のディレクトリ配置・読み書き。
// レイアウト: <project>/results/runs/<YYYY-MM>/<runID>/run.json, scenarios/<name>.json
// (YYYY-MM は runID 先頭 8 桁 yyyyMMdd(UTC)から導出。runID の発番は RunRecorder.swift)。
// 書き込みは全て best-effort(失敗しても実行を止めない。呼び出し側は throw を想定しない)。
// 既存ファイルへの上書きは run.json の finish() 更新のみ。scenarios/ 配下は追加専用
// (2 回目以降のシナリオは RunRecorder が ~2 サフィックスで別ファイルにする)。

import Foundation

public enum RunResultsStore {

    // MARK: - パス導出

    public static func resultsDir(projectRoot: URL) -> URL {
        projectRoot.appendingPathComponent("results")
    }

    /// runID 先頭の yyyyMMdd(UTC)から YYYY-MM を導出して配置する
    public static func runDir(resultsDir: URL, runID: String) -> URL {
        let runsDir = resultsDir.appendingPathComponent("runs")
        guard runID.count >= 6 else {
            return runsDir.appendingPathComponent("unknown").appendingPathComponent(runID)
        }
        let year = runID.prefix(4)
        let monthStart = runID.index(runID.startIndex, offsetBy: 4)
        let monthEnd = runID.index(monthStart, offsetBy: 2)
        let month = runID[monthStart..<monthEnd]
        return runsDir.appendingPathComponent("\(year)-\(month)").appendingPathComponent(runID)
    }

    // MARK: - 書き込み(best-effort)

    private static func makeEncoder() -> JSONEncoder {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes, .prettyPrinted]
        return encoder
    }

    public static func writeMeta(_ meta: RunMetaRecord, runDir: URL) {
        try? FileManager.default.createDirectory(at: runDir, withIntermediateDirectories: true)
        guard let data = try? makeEncoder().encode(meta) else { return }
        try? data.write(to: runDir.appendingPathComponent("run.json"), options: .atomic)
    }

    /// fileName は拡張子なし(呼び出し側が scenarioID の sanitize・連番サフィックスを付与済みの前提)
    @discardableResult
    public static func writeScenario(_ record: ScenarioRunRecord, runDir: URL, fileName: String) -> URL? {
        let dir = runDir.appendingPathComponent("scenarios")
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        guard let data = try? makeEncoder().encode(record) else { return nil }
        let url = dir.appendingPathComponent("\(fileName).json")
        guard (try? data.write(to: url, options: .atomic)) != nil else { return nil }
        return url
    }

    /// 1 run のシナリオ記録を全て読む(--junit などの run 直後の集計用)。
    /// 壊れたファイル・新しすぎる schemaVersion は黙って飛ばす(scanRecords と同じ規律)。
    /// 順序はファイル名昇順(決定的。表示順は呼び出し側でソートし直してよい)
    public static func records(runDir: URL) -> [ScenarioRunRecord] {
        let dir = runDir.appendingPathComponent("scenarios")
        guard let files = try? FileManager.default.contentsOfDirectory(
            at: dir, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles]) else {
            return []
        }
        let decoder = JSONDecoder()
        return files
            .filter { $0.pathExtension == "json" }
            .sorted { $0.lastPathComponent < $1.lastPathComponent }
            .compactMap { file in
                guard let data = try? Data(contentsOf: file),
                      let record = try? decoder.decode(ScenarioRunRecord.self, from: data),
                      record.schemaVersion <= RunRecordSchema.current else { return nil }
                return record
            }
    }

    /// discardLast(凍結再実行時の取り消し)専用。fileName は writeScenario と同じ規約
    /// (拡張子なし・dir 計算も一致させる)。存在しなければ何もしない
    public static func removeScenario(runDir: URL, fileName: String) {
        let url = runDir.appendingPathComponent("scenarios").appendingPathComponent("\(fileName).json")
        guard FileManager.default.fileExists(atPath: url.path) else { return }
        try? FileManager.default.removeItem(at: url)
    }

    // MARK: - 読み取り(スキャン)

    /// results/runs/ 配下に実在する月ディレクトリ(YYYY-MM)のうち since/until の範囲に
    /// かかるものだけを返す(文字列比較。YYYY-MM は辞書順=時系列順)。全走査回避が目的。
    private static func relevantMonthDirs(resultsDir: URL, since: Date?, until: Date?) -> [URL] {
        let runsDir = resultsDir.appendingPathComponent("runs")
        guard let entries = try? FileManager.default.contentsOfDirectory(
            at: runsDir, includingPropertiesForKeys: [.isDirectoryKey],
            options: [.skipsHiddenFiles]) else {
            return []
        }
        let sinceKey = since.map(monthKey)
        let untilKey = until.map(monthKey)
        return entries
            .filter { (try? $0.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true }
            .filter { url in
                let key = url.lastPathComponent
                if let sinceKey, key < sinceKey { return false }
                if let untilKey, key > untilKey { return false }
                return true
            }
            .sorted { $0.lastPathComponent < $1.lastPathComponent }
    }

    private static func monthKey(from date: Date) -> String {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        let comps = calendar.dateComponents([.year, .month], from: date)
        return String(format: "%04d-%02d", comps.year ?? 0, comps.month ?? 0)
    }

    private static func runDirs(in monthDir: URL) -> [URL] {
        guard let entries = try? FileManager.default.contentsOfDirectory(
            at: monthDir, includingPropertiesForKeys: [.isDirectoryKey],
            options: [.skipsHiddenFiles]) else {
            return []
        }
        return entries
            .filter { (try? $0.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true }
            .sorted { $0.lastPathComponent < $1.lastPathComponent }
    }

    private static func warnSkipped(_ count: Int, kind: String) {
        guard count > 0 else { return }
        let message = "RunResultsStore: skipped \(count) \(kind)(s)" +
            " (corrupt, or their schemaVersion is too new)\n"
        FileHandle.standardError.write(Data(message.utf8))
    }

    /// since/until は startedAt(ISO8601)でフィルタ。両方 nil なら全件
    public static func scanRuns(resultsDir: URL, since: Date? = nil, until: Date? = nil) -> [RunMetaRecord] {
        let decoder = JSONDecoder()
        let formatter = ISO8601DateFormatter()
        var results: [RunMetaRecord] = []
        var skipped = 0
        for monthDir in relevantMonthDirs(resultsDir: resultsDir, since: since, until: until) {
            for runDir in runDirs(in: monthDir) {
                let metaURL = runDir.appendingPathComponent("run.json")
                guard let data = try? Data(contentsOf: metaURL),
                      let meta = try? decoder.decode(RunMetaRecord.self, from: data) else {
                    skipped += 1
                    continue
                }
                guard meta.schemaVersion <= RunRecordSchema.current else {
                    skipped += 1
                    continue
                }
                if let since, let started = formatter.date(from: meta.startedAt), started < since {
                    continue
                }
                if let until, let started = formatter.date(from: meta.startedAt), started > until {
                    continue
                }
                results.append(meta)
            }
        }
        warnSkipped(skipped, kind: "run.json")
        return results.sorted { $0.runID < $1.runID }
    }

    /// - maxRuns: 新しい方から何 run 分だけ読むか(nil = 全件)。結果 JSON は run ×シナリオ数で
    ///   増え続け、実測でも 1 プロジェクト 3,500〜4,500 件に達する。代表値が要るだけの用途
    ///   (LPT の投入順)は上限を付けて I/O を抑える。runID は先頭がタイムスタンプなので
    ///   ディレクトリ名の辞書順降順 = 新しい順になる。
    /// - countingPlatform: maxRuns を数えるとき、この platform のレコードを含む run だけを 1 枠と
    ///   みなす(nil = platform を問わない)。**同じ results/ に複数 platform の run が混ざる
    ///   プロジェクト(iOS と Android を別プロファイルで回す E2E 等)で必要**。枠を platform 非対応で
    ///   数えると、他 platform の run と 1 シナリオだけの run で窓が埋まり、対象 platform の直近フル run
    ///   が窓から押し出されて実績ゼロになる(実害: E2E-Flutter/android の投入順が崩れ壁時計 +10s。
    ///   docs/performance-tuning.md §3.7)。返すレコード自体は絞らない(呼び出し側が platform 別に
    ///   集計するので、混在 run の他 platform 分は無害)。
    /// `maxObservationsPerScenario` で遡る run ディレクトリ数の上限(観測数の何倍まで見るか)。
    /// 8 = 上限 5 なら 40 run。プロファイルを交互に回しても直前のフル run 群には十分届き、
    /// 結果 JSON 全件(1 プロジェクト 3,500〜4,500 件)を毎 run 読む事故は防げる
    public static let observationScanLimitFactor = 8

    /// - maxObservationsPerScenario: 指定すると窓を **run 数ではなく (scenarioID, platform) ごとの
    ///   観測数**で決める(maxRuns / countingPlatform とは併用しない)。run 数で数えると
    ///   **1シナリオだけの run**(調査中のピンポイント実行)が窓を食い潰し、直前のフル run の実績が
    ///   丸ごと消える —— 2026-08-11 のフル E2E で iOS 側が軒並み `1/N with history` に落ちていた。
    ///   遡る run ディレクトリ数は `observationScanLimitFactor` 倍で頭打ち(I/O の上限)。
    ///   打ち切っても集まった分だけで並べる = 従来と同じ安全側。
    public static func scanRecords(resultsDir: URL, since: Date? = nil, until: Date? = nil,
                                   maxRuns: Int? = nil,
                                   countingPlatform: String? = nil,
                                   maxObservationsPerScenario: Int? = nil) -> [ScenarioRunRecord] {
        let decoder = JSONDecoder()
        let formatter = ISO8601DateFormatter()
        var results: [ScenarioRunRecord] = []
        var skipped = 0
        var targetRunDirs: [URL] = []
        for monthDir in relevantMonthDirs(resultsDir: resultsDir, since: since, until: until) {
            targetRunDirs += runDirs(in: monthDir)
        }
        if maxRuns != nil || maxObservationsPerScenario != nil {
            // 新しい順に見て「レコードが取れた run」を数える。実行中の run 自身のディレクトリは
            // scanRecords の時点でまだ空(RunRecorder.begin が先に作る)なので、単純に先頭 N 件を
            // 取ると枠を1つ食われる(maxRuns=1 だと実績ゼロになり LPT が丸ごと効かなくなる)。
            // 中断された run の空ディレクトリも同じ理由で飛ばす。
            targetRunDirs.sort { $0.lastPathComponent > $1.lastPathComponent }
        }
        var runsWithRecords = 0
        var runDirsInspected = 0
        /// (scenarioID, platform) ごとに集めた観測数(maxObservationsPerScenario 指定時のみ)
        var observations: [String: Int] = [:]
        for runDir in targetRunDirs {
            if let maxRuns, runsWithRecords >= maxRuns { break }
            // 歯止めは走査した run ディレクトリ数だけ。**「見えている分が満たされたら止める」に
            // しない** —— 新しい run が1シナリオしか含まないと、そのシナリオが満たされた時点で
            // 止まり、他のシナリオの実績を1件も読まないまま抜ける(2026-08-11 に実装して踏んだ)
            if let cap = maxObservationsPerScenario,
               runDirsInspected >= cap * observationScanLimitFactor { break }
            // countingPlatform 指定時は枠が埋まるまで遡るため、対象 platform が長く走っていないと
            // 窓の全 run を読みかねない。maxRuns の 8 倍で打ち切る(3 プロファイル交互でも
            // 5 枠は 15 run 程で埋まる)。打ち切った場合は集まった分だけで並べる = 従来と同じ安全側。
            if let maxRuns, countingPlatform != nil, runDirsInspected >= maxRuns * 8 { break }
            runDirsInspected += 1
            let before = results.count
            let scenariosDir = runDir.appendingPathComponent("scenarios")
            guard let files = try? FileManager.default.contentsOfDirectory(
                at: scenariosDir, includingPropertiesForKeys: nil,
                options: [.skipsHiddenFiles]) else {
                continue
            }
            for file in files where file.pathExtension == "json" {
                guard let data = try? Data(contentsOf: file),
                      let record = try? decoder.decode(ScenarioRunRecord.self, from: data) else {
                    skipped += 1
                    continue
                }
                guard record.schemaVersion <= RunRecordSchema.current else {
                    skipped += 1
                    continue
                }
                if let since, let started = formatter.date(from: record.startedAt), started < since {
                    continue
                }
                if let until, let started = formatter.date(from: record.startedAt), started > until {
                    continue
                }
                if let cap = maxObservationsPerScenario {
                    let key = "\(record.scenarioID)\u{1}\(record.platform)"
                    let seen = observations[key] ?? 0
                    if seen >= cap { continue }
                    observations[key] = seen + 1
                }
                results.append(record)
            }
            if let countingPlatform {
                if results[before...].contains(where: { $0.platform == countingPlatform }) {
                    runsWithRecords += 1
                }
            } else if results.count > before {
                runsWithRecords += 1
            }
        }
        warnSkipped(skipped, kind: "scenario record")
        return results.sorted { $0.runID == $1.runID ? $0.scenarioID < $1.scenarioID : $0.runID < $1.runID }
    }
}
