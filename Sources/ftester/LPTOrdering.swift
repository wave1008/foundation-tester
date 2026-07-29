// LPT 投入順の適用(過去実績の読み込み + 並べ替え)。
// 並べ替えの規則そのものは FTCore の LPTScheduler(純関数・単体テスト済み)にあり、
// ここは「どの実績を読むか」だけを決める。
//
// 実績は結果 JSON(Projects/<p>/results/runs/**/scenarios/*.json)の durationMs。
// 範囲を二重に絞る:
//   - 直近 historyDays 日: 古い実績はアプリもシナリオも変わっていて代表値にならない
//   - 直近 maxRuns run: 結果 JSON は run × シナリオ数で増え続ける(実測で 1 プロジェクト
//     3,500〜4,500 件)。毎 run 全件読むと run の固定費になるため上限を付ける
//     (中央値の代表性は直近 5 run で十分)

import FTCore
import Foundation

enum LPTOrdering {
    /// 実績として見る期間。短すぎると新規プロジェクトで実績ゼロ、長すぎると古い値に引きずられる
    private static let historyDays = 30.0
    /// 読み込む run 数の上限(新しい方から)の既定値。I/O を実行のたびに増やさないための頭打ち。
    /// **VSCode 設定 ftester.lptHistoryRuns の既定値・CLI --lpt-history-runs の既定値と同じ値**
    /// (3箇所で一致させる。片方だけ変えると設定タブが表示する件数と実際に走る件数が食い違う。
    /// `lptDefaultSync.test.mjs` が検出する)
    static let defaultHistoryRuns = 5

    /// enabled=false ならそのまま返す(既定順 = シナリオ ID 順)。
    /// 実績が 1 件も無いときも並べ替えない(全件「実績なし」で元の順序と同じになるが、
    /// 紛らわしいログを避けるため早期に返す)。
    ///
    /// - defaultPlatform: platform 未指定シナリオが走る platform。実績は platform ごとに
    ///   分けて集計するため、ここが RunOrchestrator.run の defaultPlatform とズレると
    ///   別 platform の実績で並べてしまう。
    /// - historyRuns: 新しい方から何 run 分の実績を読むか。1 未満は 1 に丸める
    ///   (0 や負値を渡されても「実績なし = 元の順序」で安全側に倒れる)。
    static func apply(_ items: [ScenarioRunItem], project: TestProject, defaultPlatform: String,
                      enabled: Bool, historyRuns: Int = defaultHistoryRuns,
                      log: (String) -> Void) -> [ScenarioRunItem] {
        guard enabled, items.count > 1 else { return items }

        let resultsDir = RunResultsStore.resultsDir(projectRoot: project.rootURL)
        let since = Date().addingTimeInterval(-historyDays * 24 * 60 * 60)
        let maxRuns = max(1, historyRuns)
        let records = RunResultsStore.scanRecords(resultsDir: resultsDir, since: since,
                                                  maxRuns: maxRuns)
        guard !records.isEmpty else { return items }

        let durations = LPTScheduler.durations(from: records)
        guard !durations.isEmpty else { return items }

        let ordered = LPTScheduler.order(items, durations: durations,
                                         defaultPlatform: defaultPlatform)
        let known = Set(durations.map { "\($0.scenarioID)\u{1}\($0.platform)" })
        let withHistory = items.filter {
            known.contains("\($0.info.id)\u{1}\($0.info.platform ?? defaultPlatform)")
        }.count
        log("🔀 LPT 投入順: 実績あり \(withHistory)/\(items.count) 件"
            + "(直近\(Int(historyDays))日・最大\(maxRuns) run・platform 別中央値の降順。実績なしは先頭)")
        return ordered
    }
}
