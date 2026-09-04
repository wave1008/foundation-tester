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

    public static func decide(elapsed: TimeInterval?, budget: TimeInterval) -> StartingRunnerVerdict {
        // elapsed が測れない(unknown)ときは旧挙動どおり待つ側に倒す(不明を restart 側の
        // 根拠にしない)。ちょうど budget と同値は「起動側の待ちが既に尽きた」ので restart
        guard let elapsed else { return .wait }
        return elapsed >= budget ? .restart : .wait
    }
}
