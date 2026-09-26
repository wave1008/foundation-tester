// iOS Simulator を simctl で起動する直前の掃除の唯一の入口(呼び出し口の一覧と「起動より前」の順序は
// Tests/FTCoreTests/SimulatorPosterCachePurgeWiringTests.swift が固定する)。**Booted の台には何もしない**
// (状態は1回だけ確かめる。一覧が読めないときも安全側で撃たない)。
//   1. PosterBoard のスナップショット(SimulatorPosterCache)
//   2. 統合ログの Special ストア(`<data>/var/db/diagnostics/Special/*.tracev3`)の古いファイル
//      —— logd は Special を容量でなくファイル数(1,000)でしか抑えない(logdata.statistics の purge 記録で
//      goal が無制限・kept 1000 files)。ツールの操作とモニターの画面配信で backboardd 等が大量に書き、
//      1台 1.2〜1.9GB に達していた。新しい `specialLogFilesToKeep` 個だけ残す(iOS 内部の診断ログだけで、
//      fleetest のレポート・録画には関係しない)。停止中に消して起動 → ログは続けて書かれ・読め、
//      ホーム画面・シナリオ1本が正常だった(docs/design.md §12.4.3)

import FTCore
import Foundation

public enum SimulatorBootCleanup {

    /// Special に残すファイル数。**根拠**: 1ファイル約 1.8MB(実測)で約 0.18GB = logd 自身の上限
    /// (1,000 ファイル・約 1.9GB)の 1 割。実測の書き込みペースで 3.5 日〜1.5 週間分に当たる
    static let specialLogFilesToKeep = 100

    public static func beforeBoot(udid: String) {
        let observation = SimulatorCatalog.shutdownObservation(udid: udid)
        guard SimulatorPosterCache.shouldPurge(observation: observation) else { return }
        SimulatorPosterCache.purge(observation: observation, udid: udid)
        let start = Date()
        let removed = trimSpecialLogs(udid: udid)
        if removed > 0 {
            ConsoleOut.err("[fleetest] removed \(removed) old unified-log file(s) (Special) for simulator \(udid)"
                + " in \(String(format: "%.1f", Date().timeIntervalSince(start)))s")
        }
    }

    static func specialLogDirectory(udid: String,
                                    home: URL = FileManager.default.homeDirectoryForCurrentUser) -> URL {
        home.appendingPathComponent("Library/Developer/CoreSimulator/Devices/\(udid)/data/var/db/diagnostics/Special")
    }

    /// 新しい `keep` 個(ファイル名 = 固定幅の16進連番なので名前の昇順 = 古い順)を残して消す。
    /// `.tracev3` 以外には触れない。消せた数を返す(失敗は飛ばす = 起動を止めない)
    @discardableResult
    static func trimSpecialLogs(udid: String, keep: Int = specialLogFilesToKeep,
                                home: URL = FileManager.default.homeDirectoryForCurrentUser) -> Int {
        trimSpecialLogs(in: specialLogDirectory(udid: udid, home: home), keep: keep)
    }

    static func trimSpecialLogs(in dir: URL, keep: Int) -> Int {
        guard let names = try? FileManager.default.contentsOfDirectory(atPath: dir.path) else { return 0 }
        let traces = names.filter { $0.hasSuffix(".tracev3") }.sorted()
        guard traces.count > keep else { return 0 }
        var removed = 0
        for name in traces.dropLast(keep) {
            if (try? FileManager.default.removeItem(at: dir.appendingPathComponent(name))) != nil { removed += 1 }
        }
        return removed
    }
}
