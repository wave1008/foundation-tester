// RecordingSupport.swift
// デバイス録画(VideoRecordingCoordinator 系)が使う小さな共通部品。

import Foundation

/// ISO8601(小数秒付き・ミリ秒精度)。RunRecorder 等の他所と違いミリ秒まで要るのは、
/// 動画の startedAt/失敗ステップの at を壁時計と突き合わせる用途のため(単一プロセス内の
/// 複数録画・複数ステップが同一秒に収まりうる)。ISO8601DateFormatter はインスタンスを
/// 使い回さず都度生成する(このコードベースの既存慣習に合わせる。OcclusionVerifier.swift 参照)
public enum ISO8601Millis {
    public static func string(from date: Date) -> String {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter.string(from: date)
    }
}

/// 「先に確定した方だけを採用する」レースの 1 回限りフラグ(RunOrchestrator.DeadlineGuard と同じ用途。
/// 録画セッションは別ファイル群に分かれるため、こちらは共通ヘルパーとして公開する)
actor RecordingRaceGuard {
    private var done = false
    func claim() -> Bool {
        if done { return false }
        done = true
        return true
    }
}

/// 非同期処理(op)と期限(seconds)のレース。op が先に終われば結果を、期限が先に来れば
/// onTimeout を返す。**withTaskGroup は使わない**: 構造化並行はスコープ終端で敗者task の完了を
/// 待ってしまうため、録画プロセスが生きている限り stderr 読み取り等の敗者task が終わらず
/// 期限が効かなくなる(RunOrchestrator.withDeadline と同じ理由・同じ形)。
func raceWithDeadline<T: Sendable>(
    seconds: Double, onTimeout: T, _ op: @escaping @Sendable () async -> T
) async -> T {
    let settled = RecordingRaceGuard()
    return await withCheckedContinuation { (continuation: CheckedContinuation<T, Never>) in
        let opTask = Task {
            let result = await op()
            if await settled.claim() { continuation.resume(returning: result) }
        }
        Task {
            try? await Task.sleep(nanoseconds: UInt64(max(0, seconds) * 1_000_000_000))
            if await settled.claim() {
                opTask.cancel()
                continuation.resume(returning: onTimeout)
            }
        }
    }
}
