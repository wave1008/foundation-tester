import Foundation

/// RunEvent → 表示行の共通整形(CLI の出力と呼び出し側の実行レーン表示が共用)
public enum RunLogFormatter {
    public static func lines(for event: RunEvent) -> [String] {
        switch event {
        case .runStarted, .workerReady, .runFinished, .flowStartedAt, .flowEndedAt:
            return []
        case .sceneStarted, .sceneFinished:
            // 表示は flowStarted〜flowFinished 間の step 行だけで完結させる方針のため、
            // scene 区切り用の専用行は意図的に出さない(scene/sceneTitle は各 step 行の
            // 構造化フィールドとして参照できる)
            return []
        case .workerFailed(let worker, let message):
            return ["❌ Worker \(worker) dropped out: \(message)"]
        case .workerLog(let worker, let message):
            return ["ℹ️ [\(worker)] \(message)"]
        case .flowRequeued(_, _, let reason, let attempt, let limit):
            // 復活したデバイスへ再キューされることがあり、「別のデバイス」と断定すると事実と違う
            // (元の物理デバイスのまま・ポートだけ新しいケースがある)
            return ["  🔁 Re-queued because of \(reason) (\(attempt)/\(limit))"]
        case .flowStarted(let worker, _, let flowName, let isDirty):
            var lines = ["▶ \(flowName) [\(worker)]"]
            if isDirty { lines.append("  ⚠️ This flow is dirty (needs review)") }
            return lines
        case .step(_, _, let result):
            return lines(for: result)
        case .flowPaused(_, _, let index, let description, _, _):
            return ["  ⏸ Paused before \(index). \(description)"]
        case .fixSuggestion:
            return []
        case .flowFinished(_, _, let passed, let reportURL, _, _, let notApplicableReason):
            var lines: [String] = []
            if let notApplicableReason {
                lines.append("  → ⏭ skipped (not applicable): \(notApplicableReason)")
            } else if passed {
                lines.append("  → ✅ passed")
            } else {
                if let reportURL {
                    lines.append("  → ❌ failed — report: \(reportURL.path)")
                } else {
                    lines.append("  → ❌ failed")
                }
            }
            lines.append("")
            return lines
        case .flowSkipped(let flowURL, let reason):
            let name = flowURL.lastPathComponent.removingPercentEncoding
                ?? flowURL.lastPathComponent
            return ["⚠️ Cannot run \(name): \(reason)", ""]
        case .recordingFinalizing:
            return ["🎬 All scenarios finished — extracting the per-scenario recording clips..."]
        }
    }

    public static func lines(for step: StepResult) -> [String] {
        // section("condition"/"action"/"expectation")を description 先頭に "[section] " として折り込む
        let description = (step.section.map { "[\($0)] " } ?? "") + step.description
        switch step.status {
        case .passed:
            // index 0 = ステップ以外の情報行(修正提案・ユーザー print 等)
            if step.index == 0 { return ["  \(description)"] }
            return ["  ✅ \(step.index). \(description)"]
        case .passedViaFallback(let locator), .healed(let locator):
            // 表示上は passed と同じ ✅ とし、末尾に "(detail)" を畳み込む
            return ["  ✅ \(step.index). \(description)(\(locator.summary))"]
        case .failed(let reason):
            return ["  ❌ \(step.index). \(description)", "     \(reason)"]
        case .skipped(let reason):
            return ["  ⚠️ \(step.index). \(description) (skipped: \(reason))"]
        case .inconclusive(let reason):
            return ["  ❓ \(step.index). \(description) (inconclusive: \(reason))"]
        }
    }
}
