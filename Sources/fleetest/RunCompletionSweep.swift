// run の完了時に走る保持容量の掃除。
//
// **差し込み口は3つ**(Fleetest.swift のプロファイル経路 / プロファイル無し経路 /
// ApiRunCommand)。run 前後スクリプトが2箇所なのに対してここが3箇所なのは、
// プロファイル無し経路も結果と録画を書くため —— 書く経路だけ掃除しないと、そこだけ溜まり続ける。
//
// **既存の defer に相乗りしない**。プロファイル経路の teardown は `recorder.finish` より前に
// 走るので、defer に入れると「まだ書かれていない今回の run」を保護できない。
// 呼ぶのは結果を書き終えた後。
//
// **run の成否を変えない**(`RunHookRunner.end` と同じ規律)。掃除の失敗でテスト結果が赤に
// なると、通ったのか落ちたのかが読めなくなる。

import FTBridgeClient
import FTCore
import Foundation

enum RunCompletionSweep {

    /// 結果を書き終えた直後に呼ぶ。`activeRunID` はこの run の runID
    /// (**渡さないと今回の成果物が保護されない**)。設定が OFF なら何もしない。
    static func run(activeRunID: String?, log: @escaping (String) -> Void) {
        // 設定ファイルは1回だけ読む(run の出口で2度読む理由が無い)
        let policy = (LocalConfig.load().retention ?? RetentionPolicy()).resolved
        guard policy.effectiveSweepAfterRun, let repoRoot = try? RepoRoot.find() else { return }
        let report = RetentionSweeper.clean(
            repoRoot: repoRoot, categories: RetentionSweeper.Category.allCases,
            policy: policy, dryRun: false, activeRunID: activeRunID,
            // 掃除の一覧は run の出力に混ぜない(合否の直後に数百行が流れると結果が読めない)。
            // 出すのは合計1行だけで、内訳が要るときは `fleetest clean --dry-run` を打つ
            log: { _ in })
        guard report.freedBytes > 0 else { return }
        log("🧹 Cleanup freed \(RetentionSweeper.bytesText(report.freedBytes))"
            + " (limits: fleetest api retention)")
    }
}
