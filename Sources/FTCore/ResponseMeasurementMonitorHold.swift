// レスポンス計測の run の間だけモニターの観測・配信を止める(.fleetest/monitor-hold.json = MonitorHold)。
// 呼び手は `fleetest run --profile`(ProfileRunner.run)と `fleetest api run` の2箇所。
// 配信や観測の負荷が反応時間に混ざる(docs/response-measurement.md §8.1)。
// 既に期限付きの pause があれば控えて上書きし、終わりに(期限が残っていれば)戻す。期限の無い pause は触らない。
// hold は `until` なしで書く: run の長さは事前に分からず、期限を置くと長い run の途中で解けて計測が汚れる。
// 外すのは run の終わり(defer。中断・エラーでも通る)で、プロセスが SIGKILL で消えたときだけ残る
// (`fleetest monitor resume` で外す。`monitor status` に出る)。
import Foundation

public enum ResponseMeasurementMonitorHold {

    /// この run が書いた hold の控え。release のときに「まだ自分の hold か」を照合する。
    /// `previous` = 書く前にあった期限付きの有効な hold(run の途中で期限が来てモニターが戻らないよう上書きし、終わりに戻す)
    public struct Handle: Sendable, Equatable {
        public let mine: MonitorHold
        public let stateDir: URL
        public let previous: MonitorHold?
    }

    public enum AcquireDecision: Equatable, Sendable {
        /// 期限の無い有効な hold(利用者の `monitor pause`)がある: 触らない
        case leaveAsIs
        /// 書く。`remember` = 上書きする期限付きの有効な hold(release で戻す)
        case acquire(remember: MonitorHold?)
    }

    /// 期限の無い有効な hold は触らない。期限付きの有効な hold は控えて上書きする(run の途中で切れると計測が汚れる)。
    /// 期限切れは無いものとして上書きする
    public static func acquireDecision(existing: MonitorHold?, now: Date) -> AcquireDecision {
        guard let existing, existing.isActive(now: now) else { return .acquire(remember: nil) }
        return existing.until == nil ? .leaveAsIs : .acquire(remember: existing)
    }

    public enum ReleaseAction: Equatable, Sendable {
        case keep
        case clear
        case restore(MonitorHold)
    }

    /// 自分が書いた hold が、そのまま残っているときだけ外す(別の hold に置き換わっていたら触らない)。
    /// 控えた期限付きの hold は、期限がまだ先なら戻す
    public static func releaseAction(current: MonitorHold?, mine: MonitorHold, previous: MonitorHold?,
                                     now: Date) -> ReleaseAction {
        guard current == mine else { return .keep }
        if let previous, previous.isActive(now: now) { return .restore(previous) }
        return .clear
    }

    /// 書けなかった・期限の無い hold が既にあるときは nil(= release で何もしない)
    public static func acquire(stateDir: URL, now: Date = Date(), log: (String) -> Void) -> Handle? {
        let previous: MonitorHold?
        switch acquireDecision(existing: MonitorHold.load(stateDir: stateDir), now: now) {
        case .leaveAsIs:
            log("→ Response measurement: the monitor is already held; leaving that hold as it is")
            return nil
        case .acquire(let remember):
            previous = remember
        }
        let hold = MonitorHold(until: nil, startedAt: now.timeIntervalSince1970)
        do {
            try MonitorHold.save(hold, stateDir: stateDir)
        } catch {
            log("⚠️ Response measurement: could not hold the monitor (\(error.localizedDescription));"
                + " run `fleetest monitor pause` yourself for a clean measurement")
            return nil
        }
        log("→ Response measurement: monitor held for this run (released when the run ends)")
        return Handle(mine: hold, stateDir: stateDir, previous: previous)
    }

    public static func release(_ handle: Handle?, now: Date = Date(), log: (String) -> Void) {
        guard let handle else { return }
        switch releaseAction(current: MonitorHold.load(stateDir: handle.stateDir), mine: handle.mine,
                             previous: handle.previous, now: now) {
        case .keep:
            return
        case .clear:
            MonitorHold.clear(stateDir: handle.stateDir)
            log("→ Response measurement: monitor hold released")
        case .restore(let previous):
            if (try? MonitorHold.save(previous, stateDir: handle.stateDir)) != nil {
                log("→ Response measurement: monitor hold released (the earlier time-limited pause is back)")
            } else {
                MonitorHold.clear(stateDir: handle.stateDir)
                log("→ Response measurement: monitor hold released")
            }
        }
    }
}
