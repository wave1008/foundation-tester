// 「ツールの都合で待った時間」を締め切り(FTSync のコマンド待ち・ScenarioHost の scenarioTimeout)
// の計算から差し引くための帳簿。今のところ対象は OCR 近道のコンパイル待ち(RegionText.awaitModelCompile)だけ。
// **1 プロセス 1 シナリオ・ステップは逐次実行**なので、プロセス全体で1個の状態でよい
// (begin/end は重ねて呼ばれない前提)。lock は別スレッド/Task(NDJSON 読み取りループ・
// killer タスク)からの読み取りを守るためのもの。

import Foundation
import Synchronization

public enum DeadlineExclusion {
    public struct Token: Sendable {}

    public struct Snapshot: Sendable {
        fileprivate let completedMs: Int
        fileprivate let activeSince: ContinuousClock.Instant?
    }

    /// `observer` へ渡す変化。began は上限(cap)ぶんの見込み、ended は実測に置き換える
    /// (呼び手側の集計は `began だけ = 上限ぶん延長 / ended で実測に置き換え` の規則。
    /// FTCore/ScenarioHost.swift の WatchdogExtension 参照)
    public enum Change: Sendable {
        case began(capMs: Int)
        case ended(ms: Int)
    }

    /// 変化を外へ伝える口。**FTDriveCore が emit(ScenarioEvent)へ橋渡しする**(子→親の
    /// deadlineExclusion イベント。ScenarioHost はこれを横取りして emit に渡さない)
    public static var observer: (@Sendable (Change) -> Void)? {
        get { state.withLock { $0.observer } }
        set { state.withLock { $0.observer = newValue } }
    }

    private struct State {
        var observer: (@Sendable (Change) -> Void)?
        var completedMs = 0
        var activeSince: ContinuousClock.Instant?
    }
    private static let state = Mutex(State())

    /// 待ちが始まる瞬間に呼ぶ。**待ちが 0 なら呼ばない**(呼び手の契約 —
    /// RegionText.awaitModelCompile は既にコンパイル済みなら begin しない)
    public static func begin(cap: Duration) -> Token {
        state.withLock { $0.activeSince = ContinuousClock().now }
        observer?(.began(capMs: ms(cap)))
        return Token()
    }

    /// 待ちが終わった瞬間に呼ぶ(結果が compiled/finishedUnready/capped のどれでも呼ぶ)
    public static func end(_ token: Token) {
        let now = ContinuousClock().now
        let elapsedMs: Int = state.withLock {
            guard let startedAt = $0.activeSince else { return 0 }
            let elapsed = ms(now - startedAt)
            $0.completedMs += elapsed
            $0.activeSince = nil
            return elapsed
        }
        observer?(.ended(ms: elapsedMs))
    }

    /// 締め切りの計算を始める前に取る基準点(FTSync.run はコマンドを起こす前に取る)
    public static func snapshot() -> Snapshot {
        state.withLock { Snapshot(completedMs: $0.completedMs, activeSince: $0.activeSince) }
    }

    /// `snapshot` 以降に差し引かれた時間(完了分の合計 + 進行中ならその経過)。
    /// **呼び手は begin より前に snapshot を取る前提**(snapshot 時点で既に進行中だった窓を
    /// 正しく扱う一般化はしない — 1 プロセス 1 シナリオでは begin/end が重ならないため不要)
    public static func excluded(since snap: Snapshot) -> Duration {
        state.withLock {
            var totalMs = $0.completedMs - snap.completedMs
            if let startedAt = $0.activeSince {
                totalMs += ms(ContinuousClock().now - startedAt)
            }
            return .milliseconds(max(0, totalMs))
        }
    }

    static func ms(_ duration: Duration) -> Int {
        let (seconds, attoseconds) = duration.components
        return Int(seconds) * 1000 + Int(attoseconds / 1_000_000_000_000_000)
    }
}
