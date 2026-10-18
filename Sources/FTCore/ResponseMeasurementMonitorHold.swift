// レスポンス計測の run の間だけモニターの観測・配信を止める(.fleetest/monitor-hold.json = MonitorHold)。
// 呼び手は `fleetest run --profile`(ProfileRunner.run)と `fleetest api run` の2箇所。
// 配信や観測の負荷が反応時間に混ざる(docs/response-measurement.md §8.1)。
// hold は `until` なしで書く: run の長さは事前に分からず、期限を置くと長い run の途中で解けて計測が汚れる。
// 外すのは run の終わり(defer。中断・エラーでも通る)で、プロセスが SIGKILL で消えたときだけ残る
// (`fleetest monitor resume` で外す。`monitor status` に出る)。
import Foundation

public enum ResponseMeasurementMonitorHold {

    /// この run が書いた hold の控え。release のときに「まだ自分の hold か」を照合する
    public struct Handle: Sendable, Equatable {
        public let mine: MonitorHold
        public let stateDir: URL
    }

    /// 既に有効な hold(利用者の `monitor pause` 等)があれば触らない。期限切れは無いものとして上書きする
    public static func shouldAcquire(existing: MonitorHold?, now: Date) -> Bool {
        guard let existing else { return true }
        return !existing.isActive(now: now)
    }

    /// 自分が書いた hold が、そのまま残っているときだけ外す。
    /// 別の hold(利用者が pause し直した等)に置き換わっていたら消さない
    public static func shouldRelease(current: MonitorHold?, mine: MonitorHold) -> Bool {
        current == mine
    }

    /// 書けなかった・既に hold があるときは nil(= release で何もしない)
    public static func acquire(stateDir: URL, now: Date = Date(), log: (String) -> Void) -> Handle? {
        guard shouldAcquire(existing: MonitorHold.load(stateDir: stateDir), now: now) else {
            log("→ Response measurement: the monitor is already held; leaving that hold as it is")
            return nil
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
        return Handle(mine: hold, stateDir: stateDir)
    }

    public static func release(_ handle: Handle?, log: (String) -> Void) {
        guard let handle else { return }
        guard shouldRelease(current: MonitorHold.load(stateDir: handle.stateDir), mine: handle.mine) else { return }
        MonitorHold.clear(stateDir: handle.stateDir)
        log("→ Response measurement: monitor hold released")
    }
}
