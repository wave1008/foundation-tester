// RunResultsStore.swift
// ファイルベース実行結果 DB のディレクトリ配置・読み書き。
// レイアウト: <project>/results/runs/<YYYY-MM>/<runID>/run.json, scenarios/<name>.json
// (YYYY-MM は runID 先頭 8 桁 yyyyMMdd(UTC)から導出。runID の発番は RunRecorder.swift)。
// 書き込みは全て best-effort(失敗しても実行を止めない。呼び出し側は throw を想定しない)。
// 既存ファイルへの上書きは run.json の finish() 更新のみ。scenarios/ 配下は追加専用
// (2 回目以降のシナリオは RunRecorder が ~2 サフィックスで別ファイルにする)。

import CryptoKit
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

    /// 1 run の run.json を読む(scanRuns と同じ規律: 壊れたファイル・新しすぎる schemaVersion は nil)
    public static func meta(runDir: URL) -> RunMetaRecord? {
        let metaURL = runDir.appendingPathComponent("run.json")
        guard let data = try? Data(contentsOf: metaURL),
              let meta = try? JSONDecoder().decode(RunMetaRecord.self, from: data),
              meta.schemaVersion <= RunRecordSchema.current else { return nil }
        return meta
    }

    /// 1 run のシナリオ記録を全て読む(--junit などの run 直後の集計用)。
    /// 壊れたファイル・新しすぎる schemaVersion は黙って飛ばす(scanRecords と同じ規律)。
    /// 順序はファイル名昇順(決定的。表示順は呼び出し側でソートし直してよい)
    public static func records(runDir: URL) -> [ScenarioRunRecord] {
        let dir = runDir.appendingPathComponent("scenarios")
        guard let files = jsonFiles(in: dir) else {
            return []
        }
        let decoder = JSONDecoder()
        return files
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

    /// opendir/readdir による列挙(隠しエントリは除く。順序は不定 = 呼び手がソートする)。
    /// `FileManager.contentsOfDirectory(at:)` は1エントリごとに open + getattrlistbulk を撃って
    /// CFURL を組み立てるため、run 1,092 個の `scenarios/` を列挙するだけで約 3 秒かかっていた
    /// (E2E-iOS 2万ファイル: 全体 4.0s のうち sample の 233/296 がここ。2026-09-01 実測)。
    /// 読めないディレクトリは nil(呼び手は従来どおり黙って飛ばす)
    static func directoryEntries(_ dir: URL) -> [(name: String, isDirectory: Bool)]? {
        guard let handle = opendir(dir.path) else { return nil }
        defer { closedir(handle) }
        var entries: [(name: String, isDirectory: Bool)] = []
        while let entry = readdir(handle) {
            let name = withUnsafePointer(to: &entry.pointee.d_name) { pointer in
                pointer.withMemoryRebound(to: CChar.self, capacity: Int(MAXPATHLEN)) { String(cString: $0) }
            }
            if name.hasPrefix(".") { continue }
            let isDirectory: Bool
            switch Int32(entry.pointee.d_type) {
            case DT_DIR:
                isDirectory = true
            case DT_UNKNOWN, DT_LNK:
                // d_type を返さない FS とシンボリックリンクだけ stat で確かめる(リンクは辿る)
                var status = stat()
                isDirectory = stat(dir.appendingPathComponent(name).path, &status) == 0
                    && (status.st_mode & S_IFMT) == S_IFDIR
            default:
                isDirectory = false
            }
            entries.append((name, isDirectory))
        }
        return entries
    }

    /// `dir` 直下の `*.json`(ファイル名昇順)。URL は文字列連結 + `isDirectory:` 明示で作る
    /// (`appendingPathComponent` は2万件で約 0.4s。`fileURLWithPath:` だけだと存在確認の stat が走る)
    static func jsonFiles(in dir: URL) -> [URL]? {
        guard let entries = directoryEntries(dir) else { return nil }
        let base = dir.path + "/"
        return entries
            .filter { !$0.isDirectory && $0.name.hasSuffix(".json") }
            .map(\.name)
            .sorted()
            .map { URL(fileURLWithPath: base + $0, isDirectory: false) }
    }

    /// `dir` 直下のサブディレクトリ(名前昇順)
    static func subdirectories(in dir: URL) -> [URL]? {
        guard let entries = directoryEntries(dir) else { return nil }
        let base = dir.path + "/"
        return entries
            .filter(\.isDirectory)
            .map(\.name)
            .sorted()
            .map { URL(fileURLWithPath: base + $0, isDirectory: true) }
    }

    /// results/runs/ 配下に実在する月ディレクトリ(YYYY-MM)のうち since/until の範囲に
    /// かかるものだけを返す(文字列比較。YYYY-MM は辞書順=時系列順)。全走査回避が目的。
    private static func relevantMonthDirs(resultsDir: URL, since: Date?, until: Date?) -> [URL] {
        let runsDir = resultsDir.appendingPathComponent("runs")
        guard let entries = subdirectories(in: runsDir) else {
            return []
        }
        let sinceKey = since.map(monthKey)
        let untilKey = until.map(monthKey)
        return entries.filter { url in
            let key = url.lastPathComponent
            if let sinceKey, key < sinceKey { return false }
            if let untilKey, key > untilKey { return false }
            return true
        }
    }

    /// since/until の窓判定キー。startedAt は RunRecorder が書く ISO8601(UTC "Z" 固定)なので
    /// **辞書順 = 時系列**(runID の月ディレクトリ剪定と同じ仮定)。境界をこの書式へ1回だけ
    /// 変換し、レコード側は文字列比較だけにする —— レコードごとの ISO8601 パースは ICU の
    /// **グローバルロック**(udat_parseCalendar)を取り、並列デコードが直列化して 90 日窓の
    /// 走査が数十秒になる(2026-09-01 sample 実測)。パース不能な startedAt は辞書順で小さく
    /// 並ぶため、since 指定時は従来(distantPast 扱い)と同じ除外側に倒れる。
    /// 境界とレコードで秒の小数部の有無が違う場合は境界の±1秒未満で判定が割れうるが、
    /// 窓の境界は「now - 90d」等の粗い値なので影響しない
    public static func windowKey(_ date: Date) -> String {
        ISO8601DateFormatter().string(from: date)
    }

    private static func monthKey(from date: Date) -> String {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        let comps = calendar.dateComponents([.year, .month], from: date)
        return String(format: "%04d-%02d", comps.year ?? 0, comps.month ?? 0)
    }

    private static func runDirs(in monthDir: URL) -> [URL] {
        subdirectories(in: monthDir) ?? []
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
    ///   窓は **machine 別にも**数える。リモート実行の回収記録は machine が
    ///   相手のホスト名で、新しい側に並ぶ。machine 非対応で数えると、その記録がこの機械の
    ///   実績を窓から押し出し、LPT の同一 machine 優先(LPTScheduler.durations)が常に
    ///   空振りして混合中央値へ後退する —— platform 押し出しと同型の失敗。
    public static func scanRecords(resultsDir: URL, since: Date? = nil, until: Date? = nil,
                                   maxRuns: Int? = nil,
                                   countingPlatform: String? = nil,
                                   maxObservationsPerScenario: Int? = nil) -> [ScenarioRunRecord] {
        let decoder = JSONDecoder()
        let sinceKey = since.map(windowKey)
        let untilKey = until.map(windowKey)
        var results: [ScenarioRunRecord] = []
        var skipped = 0
        var targetRunDirs: [URL] = []
        for monthDir in relevantMonthDirs(resultsDir: resultsDir, since: since, until: until) {
            targetRunDirs += runDirs(in: monthDir)
        }
        // キャップ無し(全件走査)はデコードを並列化する。キャップ付き(LPT 等)は
        // 「新しい順に見て埋まったら止める」逐次の意味を持つので従来経路のまま。
        // 読む集合・返す内容は逐次と同一(最後のソートで順序も決定的)
        if maxRuns == nil, countingPlatform == nil, maxObservationsPerScenario == nil {
            return scanRecordsConcurrently(runDirs: targetRunDirs, since: since, until: until).map(\.record)
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
            guard let files = jsonFiles(in: scenariosDir) else {
                continue
            }
            for file in files {
                guard let data = try? Data(contentsOf: file),
                      let record = try? decoder.decode(ScenarioRunRecord.self, from: data) else {
                    skipped += 1
                    continue
                }
                guard record.schemaVersion <= RunRecordSchema.current else {
                    skipped += 1
                    continue
                }
                if let sinceKey, record.startedAt < sinceKey {
                    continue
                }
                if let untilKey, record.startedAt > untilKey {
                    continue
                }
                if let cap = maxObservationsPerScenario {
                    let cacheKey = "\(record.scenarioID)\u{1}\(record.platform)\u{1}\(record.host)"
                    let seen = observations[cacheKey] ?? 0
                    if seen >= cap { continue }
                    observations[cacheKey] = seen + 1
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

    /// scanRecords(キャップ無し)が読んだ1件と、その元ファイル。
    /// url は ResultsOutputCache の trend 索引(scenarioID → ファイル)に使う
    public struct ScannedRecord: Sendable {
        public let url: URL
        public let record: ScenarioRunRecord
    }

    /// scanRecords(キャップ無し)と同じ集合を、元ファイルの URL 付きで返す
    public static func scanRecordEntries(resultsDir: URL, since: Date? = nil, until: Date? = nil) -> [ScannedRecord] {
        var targetRunDirs: [URL] = []
        for monthDir in relevantMonthDirs(resultsDir: resultsDir, since: since, until: until) {
            targetRunDirs += runDirs(in: monthDir)
        }
        return scanRecordsConcurrently(runDirs: targetRunDirs, since: since, until: until)
    }

    /// scanRecords のキャップ無し経路。デコードが所要の大半を占める
    /// (実測: E2E-CMP 90日分の逐次走査で 114s。1 プロジェクト 2万ファイル規模)ため、
    /// ファイル単位で並列にデコードする。読み飛ばし規律(壊れたファイル・新しすぎる
    /// schemaVersion・since/until)は逐次経路と同一。順序は最後のソートで決定的
    private static func scanRecordsConcurrently(runDirs: [URL], since: Date?, until: Date?) -> [ScannedRecord] {
        var files: [URL] = []
        for runDir in runDirs {
            let scenariosDir = runDir.appendingPathComponent("scenarios")
            guard let entries = jsonFiles(in: scenariosDir) else {
                continue
            }
            files += entries
        }
        guard !files.isEmpty else { return [] }

        let sinceKey = since.map(windowKey)
        let untilKey = until.map(windowKey)
        let chunkCount = max(1, min(files.count, ProcessInfo.processInfo.activeProcessorCount))
        let chunkSize = (files.count + chunkCount - 1) / chunkCount
        var chunkResults = [[ScannedRecord]](repeating: [], count: chunkCount)
        var chunkSkipped = [Int](repeating: 0, count: chunkCount)

        // 各チャンクは自分のスロットにだけ書く(共有ロック不要)。decoder はチャンクごとに作る
        chunkResults.withUnsafeMutableBufferPointer { resultsBuffer in
            chunkSkipped.withUnsafeMutableBufferPointer { skippedBuffer in
                DispatchQueue.concurrentPerform(iterations: chunkCount) { chunkIndex in
                    let decoder = JSONDecoder()
                    var local: [ScannedRecord] = []
                    var localSkipped = 0
                    let start = chunkIndex * chunkSize
                    let end = min(start + chunkSize, files.count)
                    for file in files[start..<end] {
                        guard let data = try? Data(contentsOf: file),
                              let record = try? decoder.decode(ScenarioRunRecord.self, from: data),
                              record.schemaVersion <= RunRecordSchema.current else {
                            localSkipped += 1
                            continue
                        }
                        if let sinceKey, record.startedAt < sinceKey {
                            continue
                        }
                        if let untilKey, record.startedAt > untilKey {
                            continue
                        }
                        local.append(ScannedRecord(url: file, record: record))
                    }
                    resultsBuffer[chunkIndex] = local
                    skippedBuffer[chunkIndex] = localSkipped
                }
            }
        }

        // 逐次経路の skipped の数え方は「読めない・版が新しすぎる」だけで、日付範囲外は数えない。
        // ここも同じ(壊れたディレクトリ一覧の失敗は逐次と同様 continue で黙って飛ばす)
        warnSkipped(chunkSkipped.reduce(0, +), kind: "scenario record")
        return chunkResults.flatMap { $0 }
            .sorted {
                $0.record.runID == $1.record.runID ? $0.record.scenarioID < $1.record.scenarioID
                                                   : $0.record.runID < $1.record.runID
            }
    }

    // MARK: - 指紋(ResultsOutputCache の鍵)

    /// scanRuns / scanRecords(キャップ無し)が読む入力集合の指紋(SHA256 hex)。
    /// 走査する月・run ディレクトリは scanRecords と同じ relevantMonthDirs / runDirs を通す
    /// (別に列挙すると「読む集合」と「鍵」がずれる)。run ごとに畳むのは stat 2回だけ:
    /// - `run.json` の mtime(ns)と size(finish() が上書きする唯一のファイル)
    /// - `scenarios/` ディレクトリ自身の mtime(ns)。記録の追加(atomic 書き = temp 作成 + rename)・
    ///   削除(removeScenario)・rsync の回収はどれもエントリの作成/rename/削除なので必ず更新される。
    ///   **ファイルの中身を rename 無しで in-place 書き換えした場合だけ捕まえない**(記録の規律 =
    ///   追加専用の外なので許容)
    /// scenarios/ の中は列挙しない —— readdir だけで 2万エントリに 0.23s、URL 化まで含めて約 1s
    /// かかり(2026-09-01 実測)、ヒットの意味が無くなる。E2E-iOS 1,092 run で数十 ms。
    /// **呼ぶ順序は「指紋 → 走査」**: 指紋の後に届いた記録は走査に混ざっても次回の指紋が変わる
    /// (ミス側に倒れる)。逆順だと走査後に届いた記録が指紋に入り、無い記録の出力を有効と見なす
    public static func scanFingerprint(resultsDir: URL, since: Date? = nil, until: Date? = nil) -> String {
        var hasher = SHA256()
        var lines = ""
        func stamp(_ path: String) -> String {
            var status = stat()
            guard stat(path, &status) == 0 else { return "-" }
            let mtime = status.st_mtimespec
            return "\(mtime.tv_sec).\(mtime.tv_nsec) \(status.st_size)"
        }
        for monthDir in relevantMonthDirs(resultsDir: resultsDir, since: since, until: until) {
            lines += "month \(monthDir.lastPathComponent)\n"
            for runDir in runDirs(in: monthDir) {
                let base = runDir.path
                lines += "run \(runDir.lastPathComponent) \(stamp(base + "/run.json")) \(stamp(base + "/scenarios"))\n"
            }
        }
        hasher.update(data: Data(lines.utf8))
        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }
}
