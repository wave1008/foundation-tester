// RunRecordPack.swift
// `fleetest api results` の非キャッシュ経路(RunResultsStore.scanRunsAndRecords)専用の
// run 単位キャッシュ。完了した run の run.json/scenarios/*.json は追加専用で以後変わらない
// (RunResultsStore.swift 冒頭の前提)ので、decode 済みの記録を1ファイルへ束ねて次回以降は
// 1回読むだけにする —— 9万ファイル規模の opendir/open/JSON decode が所要の大半を占める
// (実測は docs/results-json.md §出力キャッシュ)。
//
// 置き場所: <project>/.fleetest/results-cache/record-packs/<YYYY-MM>/<runID>.json
// 有効条件(全部一致しないと直接読みへ倒す。どれも既定値を置かない):
//   - formatVersion(このファイルの容器の形)
//   - executableKey(ResultsOutputCache.executableFingerprint と同じ形式。建て直せば必ず外れる。
//     **型が変わったビルドの書いたパックを新しいビルドが読むと元ファイルにある欄を黙って落とす**
//     ため必須)
//   - runRecordSchemaVersion == RunRecordSchema.current(書いた側と読む側で最大対応版が違えば無効)
//   - runStatKey == RunResultsStore.runStat(runDir:).key(run.json + scenarios/ の stat。
//     このファイルは stat を再計算しない —— 呼び手(RunResultsStore)が渡す1箇所だけで
//     判定することで「読む集合」とパックの鍵がずれないようにする)
// 進行中の run(runStat.inProgress)はパックを作らない・読まない(呼び手側で分岐する)。
// since/until はパックの中身に依存させない(窓は呼び手が読み込み後に一律で掛ける)。
//
// **entries.record は縮小済み**(`trimmedForStorage` 参照)。**この縮小記録を使ってよいのは
// api results の集計だけ** —— trend(--scenario)のような元記録全体を返す経路は、
// entries の url から元ファイルを読み直す(ApiResultsCommand.trendRecords)。

import Foundation

public enum RunRecordPack {

    static let formatVersion = 2

    /// run.json が読めない/版が対応外だったときの理由。1 run = 1 run.json なので1件で足りる。
    /// since/until による除外はここに含めない(パックは窓に依存させない。呼び手が読み込み後に
    /// `RunResultsStore.windowMatch` で判定する)
    enum MetaSkipReason: String, Codable {
        case decodeFailure
        case schemaTooNew
    }

    struct Entry: Codable {
        var fileName: String
        var record: ScenarioRunRecord
    }

    struct Contents: Codable {
        var formatVersion: Int = RunRecordPack.formatVersion
        var executableKey: String
        var runRecordSchemaVersion: Int
        var runStatKey: String
        /// run.json の decode 結果(読めて版も対応内のときだけ非 nil)
        var meta: RunMetaRecord? = nil
        /// meta が nil の理由(両方 nil はあり得ない。両方非 nil にもしない)
        var metaSkipReason: MetaSkipReason? = nil
        var entries: [Entry]
        var decodeFailureCount: Int
        var schemaTooNewCount: Int
    }

    public static func cacheDir(stateDir: URL) -> URL {
        ResultsOutputCache.dir(stateDir: stateDir).appendingPathComponent("record-packs")
    }

    static func url(cacheDir: URL, runDir: URL) -> URL {
        let month = runDir.deletingLastPathComponent().lastPathComponent
        return cacheDir.appendingPathComponent(month).appendingPathComponent("\(runDir.lastPathComponent).json")
    }

    /// パックへ格納する直前に呼ぶ縮小。記録のバイト数の84%を占めるのが `timeline` で
    /// (実測は docs/results-json.md)、api results の集計(`RunResultsQuery`)がそこから読むのは
    /// **`notes` だけ**(`unsettledStepsInsight`。他の欄は読まない)。よって:
    ///   - `notes` を持たないステップは丸ごと落とす(集計は notes の有無でしか timeline を見ない)
    ///   - 残すステップも `index` / `description` / `status` / `notes` の4欄だけにし、
    ///     計時等の他の欄(durationMs・snapshotMs・cpuMs 等)は落とす
    /// **`RunResultsQuery` が timeline から読む欄が増えたら、ここも合わせて直すこと**
    /// (`TimelineNotesOnlyScanTests` がソース走査で検出し、落ちたときにこの関数名を指す)
    static func trimmedForStorage(_ record: ScenarioRunRecord) -> ScenarioRunRecord {
        guard let timeline = record.timeline else { return record }
        var trimmed = record
        trimmed.timeline = timeline.compactMap { step in
            guard step.notes != nil else { return nil }
            return TimelineStepRecord(index: step.index, description: step.description,
                                      status: step.status, notes: step.notes)
        }
        return trimmed
    }

    /// 有効なら読む。読めない・壊れている・無効(鍵が食い違う)なら nil
    /// (**呼び手は黙って直接読みへ倒す** —— 誤った結果を返すより遅い方がよい)
    static func read(cacheDir: URL, runDir: URL, executableKey: String, runStatKey: String) -> Contents? {
        guard let data = try? Data(contentsOf: url(cacheDir: cacheDir, runDir: runDir)),
              let contents = try? JSONDecoder().decode(Contents.self, from: data),
              contents.formatVersion == formatVersion,
              contents.executableKey == executableKey,
              contents.runRecordSchemaVersion == RunRecordSchema.current,
              contents.runStatKey == runStatKey else { return nil }
        return contents
    }

    /// atomic 書き込み(temp 作成 + rename)。複数プロセスが同時に同じ run を書いても
    /// 最後の rename が勝つだけで壊れない。書けなくても失敗にしない(best-effort)
    static func write(_ contents: Contents, cacheDir: URL, runDir: URL) {
        let fileURL = url(cacheDir: cacheDir, runDir: runDir)
        try? FileManager.default.createDirectory(at: fileURL.deletingLastPathComponent(),
                                                  withIntermediateDirectories: true)
        guard let data = try? JSONEncoder().encode(contents) else { return }
        try? data.write(to: fileURL, options: .atomic)
    }

    /// 対応する run ディレクトリが無くなったパックを消す。**保持容量の掃除(RetentionSweeper)は
    /// run.json/scenarios/ 自体を消さない**(消すのは recordings/ 等だけ)ので、孤児化するのは
    /// `git rm -r` による月単位の間引きのような手動操作のときだけ(docs/results-json.md §git での扱い)。
    /// **デコードは走らない**(ディレクトリの存在確認だけ。RunResultsStore と同じ opendir 経由の
    /// 列挙を使い、`FileManager.contentsOfDirectory` の1エントリごとの stat コストを避ける)。
    /// ①パックの月ディレクトリに対応する `runs/<月>` が無い(月ごと削除)→ 月ごと削除
    /// ②月は在るが個々の run ディレクトリが無い → その run のパックだけ削除
    static func sweepOrphans(cacheDir: URL, runsDir: URL) {
        guard let packMonthDirs = RunResultsStore.subdirectories(in: cacheDir) else { return }
        for packMonthDir in packMonthDirs {
            let runsMonthDir = runsDir.appendingPathComponent(packMonthDir.lastPathComponent)
            guard let existingRunDirs = RunResultsStore.subdirectories(in: runsMonthDir) else {
                try? FileManager.default.removeItem(at: packMonthDir)
                continue
            }
            let existingRunIDs = Set(existingRunDirs.map(\.lastPathComponent))
            guard let packFiles = RunResultsStore.jsonFiles(in: packMonthDir) else { continue }
            for packFile in packFiles {
                let runID = packFile.deletingPathExtension().lastPathComponent
                guard !existingRunIDs.contains(runID) else { continue }
                try? FileManager.default.removeItem(at: packFile)
            }
        }
    }
}
