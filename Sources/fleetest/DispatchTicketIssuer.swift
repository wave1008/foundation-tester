// DispatchTicketIssuer.swift
// 複数の機械へ子プロセスを配る親(ApiRunMachineFanout / DeviceMachineRunner / FleetRunner)が、
// dispatch.lock の待機チケット(FTRemote.DispatchTicket)を **1回だけ採って全ての子へ同じ値を配る**
// ための1箇所。子は `RemoteDispatchQueue.resolveTicket` が環境変数 `FT_DISPATCH_TICKET` から
// 受け取る(FTRemote/RemoteDispatchWait.swift)。
//
// **なぜ親が採るか**: 機械ごとの子が別々に時刻を採ると、同じ run の前後関係が機械によって
// 食い違う ―― 機械 A の待機列では自分が先・機械 B では相手が先、という形になり、2つの run が
// 互いに相手の機械を待って `--wait-lock` の上限まで進まない。
//
// **親自身は ssh を1本も足さない**(docs/remote-runner.md §18.7「占有を知るために ssh を足さない」)。
// 親がするのは「同じ鍵を配る」ことだけで、待機列へ並ぶのは従来どおり子の
// `RemoteRunDispatcher.acquireDispatchLock` の1往復。
//
// 配線は `DispatchTicketPlumbingTests` が走査で固定する(採る場所が1箇所であること・
// 子を起こす2経路が `childEnvironment(ticket:)` を通ること)。

import FTCore
import FTRemote
import Foundation

enum DispatchTicketIssuer {

    /// この run のチケットを採る。**親が1回だけ**呼ぶ(`withTaskGroup` の中で呼ばない =
    /// 子ごとに別の時刻になり、この配線の目的そのものが消える)。
    ///
    /// 判定は子と同じ `RemoteDispatchQueue.resolveTicket` を通す(綴りも規則も2箇所に持たない)。
    /// この親自身が誰かの子で `FT_DISPATCH_TICKET` を継いでいれば、そのチケットをそのまま
    /// 孫へ配る —— 採り直すと入れ子の run が機械ごとに違う順番を見る、という同じ事故になる。
    /// `runGroup` が無い経路(`--fleet` は機械ごとに別の run なので束ね鍵を持たない)は
    /// pid が同時 run を区別する鍵になる
    static func issue(runGroup: String?,
                      environment: [String: String] = ProcessInfo.processInfo.environment,
                      pid: Int32 = ProcessInfo.processInfo.processIdentifier,
                      now: Date = Date()) -> DispatchTicket {
        RemoteDispatchQueue.resolveTicket(
            environment: environment, issuer: LocalConfig.resolveIssuerId(environment: environment),
            runGroup: runGroup, pid: pid, now: now)
    }

    /// 子1体ぶんの環境(純粋関数)。**引数で受けたチケットをそのまま入れる** —— ここで採り直さない。
    ///
    /// **手元(`--runner local`)の子にも同じものを渡す**: 手元の子も同じ dispatch.lock を
    /// 取る(`LocalDispatchLock`)ので、待機列の鍵は全員で同じ1つでなければ
    /// 前後関係が機械によって食い違う。仕分けを足さないほうへ倒す理由も同じ —— 「どの子に
    /// 渡すか」の判定は待機列の外に2つ目の規則として増え、取りこぼした子だけが別の順番を見る
    /// (取りこぼしは緑のまま起きる)。
    ///
    /// `ParentDeathWatch.childEnvironment` を土台にする(孤児対策の `FT_PARENT_PID` は
    /// 子を起こす全経路の契約。`ParentDeathWatchWiringTests`)
    ///
    /// `lockHeldTarget` = 親が**この子の宛先の** dispatch.lock を先に取れたときの ssh 宛先
    /// (`DispatchPrelock`)。**取れなかった機械には渡さない** —— その子は従来どおり自分で
    /// 取りに行き、同じ失敗を同じ文言で出す。継承した印を消さないのは、値が宛先を名乗っており
    /// (`DispatchLockHandoff`)、別の宛先へ向かう子には効かないから
    static func childEnvironment(ticket: DispatchTicket, lockHeldTarget: String? = nil,
                                 base: [String: String]? = nil) -> [String: String] {
        var env = ParentDeathWatch.childEnvironment(base: base)
        env[DispatchTicket.environmentKey] = ticket.environmentValue
        if let lockHeldTarget {
            env[DispatchLockHandoff.environmentKey] =
                DispatchLockHandoff.environmentValue(sshTarget: lockHeldTarget)
        }
        return env
    }
}
