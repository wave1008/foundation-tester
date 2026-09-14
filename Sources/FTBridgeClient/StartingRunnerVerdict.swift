// 引き取った起動中ランナーが announce するまで待つか、諦めて建て直すかの決定。
// 純粋関数にしてあるのは単体テストで固定するため —— 誤って「待つ」に倒すと孤児ランナーへ
// 毎回 startupTimeoutSeconds 分待たされ、誤って「建て直す」に倒すと正常に起動中のランナーを
// 撃ち殺して起動をやり直させてしまう。

import Foundation

/// `ps -o etime=` の出力("MM:SS" / "HH:MM:SS" / "D-HH:MM:SS")を秒数へ変換する。
public enum PSElapsedTime {
    public static func parse(_ etime: String) -> TimeInterval? {
        let trimmed = etime.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        var daySeconds: TimeInterval = 0
        var rest = Substring(trimmed)
        if let dashIndex = rest.firstIndex(of: "-") {
            guard let days = Double(rest[rest.startIndex..<dashIndex]) else { return nil }
            daySeconds = days * 86400
            rest = rest[rest.index(after: dashIndex)...]
        }
        let parts = rest.split(separator: ":", omittingEmptySubsequences: false)
        guard (2...3).contains(parts.count) else { return nil }
        var seconds: TimeInterval = 0
        for part in parts {
            guard let value = Double(part) else { return nil }
            seconds = seconds * 60 + value
        }
        return daySeconds + seconds
    }
}

/// 引き取った起動中ランナーへの判定
public enum StartingRunnerVerdict: Equatable {
    /// 起動予算内 → 従来どおり announce を待つ
    case wait
    /// 起動予算を超えて生きている → 起動した側は既に諦めている。待たずに止めて建て直す
    case restart

    /// - elapsed: ランナーの生存時間(ps etime)。測れなければ待つ側に倒す(不明を restart の根拠にしない)
    /// - quietFor: 起動ログが最後に伸びてからの秒数。**起動した側は進み具合で待つ**
    ///   (BridgeStartupWait)ので、ログが伸びている間は起動側もまだ諦めていない = 引き取る側も待つ。
    ///   測れなければ elapsed だけで決める(旧挙動)
    /// - simulatorBooted: 対象がシミュレータで Shutdown なら、ランナーが起動中であるはずがない(xcodebuild は
    ///   ブートを待つ側で、落とされた台に張り付いたランナーは二度と announce しない)。**待たずに建て直す**
    ///   (実測 2026-09-14: 落とした台の引き取りが 180 秒待ってから建て直していた。台帳 §19.25)
    public static func decide(elapsed: TimeInterval?, quietFor: TimeInterval? = nil,
                              simulatorBooted: Bool = true,
                              budget: TimeInterval) -> StartingRunnerVerdict {
        guard simulatorBooted else { return .restart }
        guard let elapsed, elapsed >= budget else { return .wait }
        // ちょうど budget と同値は「起動側の待ちが既に尽きた」ので restart
        guard let quietFor else { return .restart }
        return quietFor >= budget ? .restart : .wait
    }
}
