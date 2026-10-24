// 準備中("preparing"/"building")の台帳の書き手。run の入口(Fleetest.swift / ApiRunCommand.swift の
// writeProgress)と ProfileRunOrchestrator.writePreparingProgress が使う(docs/design.md §18.1)。
// 供給の段階(RunSupplyProgress)が変わったら、直前の phase のまま supply だけ載せ替えて書き直す。
// 3つ目の書き手 RunProgressState(RunOrchestrator)は最初の書き込みの後に通知を引き継ぐ。

import Foundation
import FTCore

final class PreparingProgressWriter: Sendable {
    private struct State {
        var phase: String
        var closed = false
    }

    private let pid: Int32
    private let runID: String?
    private let runGroup: String?
    private let issuer: String?
    private let project: String
    private let profile: String?
    private let startedAt: String
    private let supply: RunSupplyProgress
    /// 書き込みもこのロックの中で行う(別スレッドの古い snapshot が新しい控えを上書きしない)
    private let state = LockedValue(State(phase: "preparing"))

    init(pid: Int32, runID: String?, runGroup: String?, issuer: String?, project: String,
         profile: String?, startedAt: String, supply: RunSupplyProgress) {
        self.pid = pid
        self.runID = runID
        self.runGroup = runGroup
        self.issuer = issuer
        self.project = project
        self.profile = profile
        self.startedAt = startedAt
        self.supply = supply
    }

    func write(phase: String) {
        state.withLock { state in
            guard !state.closed else { return }
            state.phase = phase
            flush(phase: phase)
        }
    }

    /// 供給の段階が変わったら直前の phase のまま書き直す。後から attach した書き手が通知を引き継ぐ
    func attach() {
        supply.setOnChange(owner: ObjectIdentifier(self)) { [self] in
            state.withLock { state in
                guard !state.closed else { return }
                flush(phase: state.phase)
            }
        }
    }

    /// 以後書かない。呼び手が台帳を消す前に呼ぶ(消した後に遅れた通知が控えを作り直さない)
    func close() {
        supply.releaseOnChange(owner: ObjectIdentifier(self))
        state.withLock { $0.closed = true }
    }

    private func flush(phase: String) {
        RunProgressLedger.write(RunProgressRecord(
            pid: pid, runID: runID, runGroup: runGroup, issuer: issuer,
            project: project, profile: profile,
            startedAt: startedAt, total: 0, done: 0, failed: 0,
            requeued: 0, laneDropouts: 0, etaSeconds: nil, lanes: [], phase: phase,
            supply: supply.snapshot(), videoClips: nil),
            directory: RunProgressLedger.directory())
    }
}
