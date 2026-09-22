// LocalDispatchLock.swift
// **この Mac で直接走る run**(`fleetest run` / `fleetest api run` を人が打つ・fan-out の local
// エントリ)が、リモートへのディスパッチとまったく同じ dispatch.lock を取る1箇所。
//
// **なぜ要るか**(ユーザー決定 2026-09-21): 「1つのマシンで同時に複数の run は走らせない」は
// 避けたい副作用ではなく**守りたい不変条件**(高負荷はテストを不安定にする)。リモートへの
// ディスパッチは `dispatch.lock` でそれを守っていたが、その機械で直接打った run は取っていな
// かった —— 他人がこの Mac をランナーとして登録していると、他人のディスパッチと手元の run が
// **同じ CoreSimulatorService と同じ loopback のポート**を奪い合う。
//
// **取得の定義元を増やさない**: コマンド文字列は `FTRemote.RemoteDispatchQueue` /
// `RemoteDispatchLock` が作ったものをそのまま、ssh ではなく `/bin/sh -c` で撃つだけ
// (`mkdir` の原子性・失効チケットの掃除・FIFO の先頭判定はシェル側に入っている)。
// 出力の解析も `RemoteDispatchQueue.parseOutcome`、待つ判断も `WaitLockPolling`、
// 死んだロックの回収も `RemoteDispatchUnlock` を共有する。ここが持つのは**I/O と文言だけ**。
//
// **相手は /bin/sh(リモートは zsh)**だが、共有するコマンドはグロブを使わない契約なので
// どちらでも同じ結果になる(`RemoteDispatchQueue.enqueueAndTryAcquireCommand` の宣言)。

import FTCore
import FTRemote
import Foundation

/// 手元のロックが取れなかったときのエラー。`RemoteDispatchError.remoteSetupFailed` は
/// "remote setup failed:" を前置するので使わない(手元の話にリモートの語を混ぜない)
struct LocalDispatchLockError: Error, LocalizedError {
    let message: String
    var errorDescription: String? { message }
}

final class LocalDispatchLock {

    /// シェル片1本の上限(秒)。ここを通るのは `mkdir` / `find` / `cat` だけで実測はミリ秒 ——
    /// 刺さるのはホームがネットワーク越しにある等の異常だけなので、待ち続けるより落ちるほうが良い
    /// (`RemoteRunDispatcher.sshCaptureTimeoutSeconds` と同じ規律)
    static let commandTimeoutSeconds: Double = 60

    /// 進行ログに出すこの機械の呼び名(`DispatchWaitStatus.target`)。ssh 宛先の代わり
    private static let targetLabel = "this Mac"

    /// 握ったロック1本。**解放は defer から**(成功・失敗・中断のいずれでも)。二重解放は無害
    final class Holder {
        private let releaseAction: () -> Void
        private var released = false

        init(releaseAction: @escaping () -> Void) {
            self.releaseAction = releaseAction
        }

        func release() {
            guard !released else { return }
            released = true
            releaseAction()
        }
    }

    /// 差し替え口(テストが home とシェルを注入する)。**本番の既定はここ1箇所**
    private let home: String
    private let issuer: String
    private let issuerHost: String
    private let pid: Int32
    private let environment: [String: String]
    private let runGroup: String?
    private let waitLock: Int?
    private let forceLock: Bool
    private let pidAlive: (Int32) -> Bool
    private let sleepSeconds: (Int) -> Void
    private let log: (String) -> Void
    private let emitWaiting: ((DispatchWaitStatus) -> Void)?

    init(runGroup: String? = nil, waitLock: Int? = nil, forceLock: Bool = false,
         home: String = NSHomeDirectory(),
         issuer: String = LocalConfig.resolveIssuerId(),
         issuerHost: String = ProcessInfo.processInfo.hostName,
         pid: Int32 = ProcessInfo.processInfo.processIdentifier,
         environment: [String: String] = ProcessInfo.processInfo.environment,
         pidAlive: @escaping (Int32) -> Bool = ProcessLiveness.isAlive,
         sleepSeconds: @escaping (Int) -> Void = { Thread.sleep(forTimeInterval: Double($0)) },
         log: @escaping (String) -> Void,
         emitWaiting: ((DispatchWaitStatus) -> Void)? = nil) {
        self.home = home
        self.issuer = issuer
        self.issuerHost = issuerHost
        self.pid = pid
        self.environment = environment
        self.runGroup = runGroup
        self.waitLock = waitLock
        self.forceLock = forceLock
        self.pidAlive = pidAlive
        self.sleepSeconds = sleepSeconds
        self.log = log
        self.emitWaiting = emitWaiting
    }

    /// **`fleetest api run` が渡す NDJSON の出し口**(`fleetest run` は渡さない —— あちらの stdout は
    /// 人間向けで、機械可読行を混ぜない)。ここが「手元 = machine `local`」を決める1箇所で、
    /// 綴りは `--device-machine` / モニタータイルと同じ `DeviceMachineGrouping.localDisplayName`
    /// (新しい呼び名を作らない)。1行の形はリモートのディスパッチと同じ
    /// `ApiDispatchWaitingEvent.emit` を通す。`out` はテストの受け口
    static func apiRunWaitingEmitter(
        out: @escaping (String) -> Void = { ConsoleOut.out($0) }
    ) -> (DispatchWaitStatus) -> Void {
        { status in
            ApiDispatchWaitingEvent.emit(
                machine: DeviceMachineGrouping.localDisplayName, status: status, out: out)
        }
    }

    /// **この run の親(fan-out / ディスパッチした発行側)が既にこの機械のロックを握っているか**。
    /// 印は `DispatchLockHandoff`(手元の fan-out の親が local の子へ / ディスパッチが ssh 越しに
    /// `RemoteShell.remoteRunCommand` で)。印があれば取得**も**解放もしない ——
    /// 片方だけ飛ばすと、親のロックを子が消すか、子が親のロックを待って詰む
    static func parentHoldsTheLock(
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) -> Bool {
        DispatchLockHandoff.isHeldByParent(environment: environment,
                                           sshTarget: DispatchLockHandoff.localTarget)
    }

    /// 取る。**戻り値 nil = 取らなかった**(親が握っている)。throw = 取れなかった(run は止める)。
    ///
    /// **中断(SIGINT/SIGTERM)は待っている間だけ横取りする** —— 受けたら待機列から自分の
    /// チケットを外して throw する(= 通常の巻き戻しへ入る)。**握ったあとは横取りを外す**:
    /// ①握っているロックは死んだ pid として次の run が自分で回収する(`decideLocalSweep`)ので
    /// 握りっぱなしで残らない ②run 自身の中断ハンドラ(`RunInterruptState`)は供給の後でしか
    /// 立たないので、ここで握り続けると**供給中の Ctrl-C が黙って無視される**
    func acquire() throws -> Holder? {
        if Self.parentHoldsTheLock(environment: environment) {
            log("==> the dispatch lock on this Mac is already held by this run's parent")
            return nil
        }
        let info = RemoteDispatchLockInfo.now(issuerHost: issuerHost, pid: pid, issuer: issuer)
        let ticket = RemoteDispatchQueue.resolveTicket(
            environment: environment, issuer: issuer, runGroup: runGroup, pid: pid, now: Date())
        if forceLock {
            log("warning: --force-lock is stealing the dispatch lock on this Mac"
                + " (any run it was protecting may still be going)")
            // 奪う側が列に残り続けないよう、先に自分のチケットを消す(リモートと同じ順序)
            _ = try? shell(RemoteDispatchQueue.dequeueCommand(home: home, ticket: ticket))
            let result = try shell(RemoteDispatchLock.forceAcquireCommand(home: home, info: info))
            guard result.status == 0 else {
                throw LocalDispatchLockError(message: Self.creationFailureMessage(
                    status: result.status, tail: result.tail))
            }
            return makeHolder()
        }
        let interrupted = InterruptFlag()
        let relay = InterruptRelay.observing { interrupted.mark() }
        defer { relay.stop() }

        var elapsed = 0
        while true {
            let result = try shell(RemoteDispatchQueue.enqueueAndTryAcquireCommand(
                home: home, ticket: ticket, info: info))
            guard let outcome = RemoteDispatchQueue.parseOutcome(result.output, ticket: ticket) else {
                // 並べなかった / シェルのエラーで判定語が読めない
                dequeue(ticket)
                let existing = try? shell(RemoteDispatchLock.readCommand(home: home)).output
                throw LocalDispatchLockError(message: Self.acquireFailureMessage(
                    status: result.status, lockRead: existing, tail: result.tail))
            }
            let position: Int
            let total: Int
            let holder: RemoteDispatchLockInfo?
            switch outcome {
            case .acquired:
                return makeHolder()
            case .waiting(let p, let t, let h), .held(let p, let t, let h):
                position = p
                total = t
                holder = h
            }
            // 先頭なのに取れなかった = 誰かが掴んでいる。**自分の死んだ run のロックなら回収する**
            // (毎周試す —— 待ち始めた時点では保持者が生きているのが普通なので、待っている間に
            // 保持者が死ぬことがある。判定は pid の生死だけなので毎周撃っても安い)
            if case .held = outcome, autoReleaseOurDeadLock() {
                continue
            }
            let status = DispatchWaitStatus(
                target: Self.targetLabel, position: position, total: total, holder: holder,
                elapsedSeconds: elapsed, limitSeconds: waitLock, scope: .thisMachine)
            guard let limitSeconds = waitLock else {
                dequeue(ticket)
                throw LocalDispatchLockError(message: status.refusalMessage)
            }
            // **ログの刻みはリモートと同じ式**(`WaitLockPolling.shouldLogProgress`)。
            // **ログと NDJSON イベントは同じ if を通す**(判断を2つ持たない —— 片方だけ刻みが
            // 変わると端末と拡張で見える回数が食い違う。リモート側の同じ規律と対)
            if WaitLockPolling.shouldLogProgress(elapsedSeconds: elapsed) {
                log(elapsed == 0 ? status.queuedLine : status.stillQueuedLine)
                emitDispatchWaiting(status)
            }
            guard !interrupted.isSet else {
                dequeue(ticket)
                throw LocalDispatchLockError(
                    message: "interrupted while queued for the dispatch lock on this Mac"
                        + " (waited \(elapsed)s) — left the queue")
            }
            guard WaitLockPolling.decide(elapsedSeconds: elapsed,
                                         limitSeconds: limitSeconds) == .retry else {
                dequeue(ticket)
                throw LocalDispatchLockError(message: status.refusalMessage)
            }
            sleepSeconds(WaitLockPolling.pollIntervalSeconds)
            elapsed += WaitLockPolling.pollIntervalSeconds
        }
    }

    /// この機械のハードウェア UUID(`DispatchPrelock` の順序付けの鍵)。
    /// **手元も他の機械と同じ全順序へ並べる**ために要る —— 手元だけ「不明 = 最後尾」に倒すと、
    /// 別の Mac から見た順序(あちらでは ssh で採れる)と食い違い、2つの run が互いに相手の
    /// 機械を待つ形が作れる。採取の定義元は `RemoteProbe`(ssh 越しと同じ1行)
    static func probeHardwareUUID() -> String? {
        guard let result = try? Shell.run(["/bin/sh", "-c", RemoteProbe.hardwareUUIDCommand],
                                          timeout: commandTimeoutSeconds),
              result.status == 0 else { return nil }
        return RemoteProbe.parseHardwareUUID(
            result.output.split(separator: "\n", omittingEmptySubsequences: false)
                .first.map(String.init) ?? "")
    }

    // MARK: - 内部

    /// 待機の事実を拡張へ渡す(**渡されていれば** = `fleetest api run` の経路だけ。
    /// 注入されていなければ何もしない = `fleetest run` は従来のログのまま)
    private func emitDispatchWaiting(_ status: DispatchWaitStatus) {
        emitWaiting?(status)
    }

    private func makeHolder() -> Holder {
        // 解放は run の終わり(defer)に走るので、self を抱えずに必要な値だけ写す
        let home = self.home
        let log = self.log
        return Holder(releaseAction: {
            do {
                _ = try Shell.run(["/bin/sh", "-c", RemoteDispatchLock.releaseCommand(home: home)],
                                  timeout: Self.commandTimeoutSeconds)
            } catch {
                log("warning: failed to release the dispatch lock on this Mac"
                    + " (\(error.localizedDescription)) — the next run releases it once this pid is gone")
            }
        })
    }

    /// **同じ機械の pid なので生死で確定できる**。判定は `RemoteDispatchUnlock.decideLocalSweep`
    /// の1箇所(リモートの pgrep による裏取りを掛けない理由はそちらの宣言)
    private func autoReleaseOurDeadLock() -> Bool {
        guard let existing = try? shell(RemoteDispatchLock.readCommand(home: home)).output,
              !existing.isEmpty else { return false }
        let probe = RemoteDispatchLock.Probe.held(RemoteDispatchLock.decode(existing))
        guard case .release(let reason) = RemoteDispatchUnlock.decideLocalSweep(
            probe: probe, myIssuer: issuer, myHost: issuerHost, pidAlive: pidAlive) else {
            return false
        }
        log("==> auto-releasing a stale dispatch lock on this Mac left by a dead run of ours (\(reason))")
        _ = try? shell(RemoteDispatchLock.releaseCommand(home: home))
        return true
    }

    /// 待つのをやめた/失敗したときに**自分のチケットだけ**消す(他人の待機には触らない)。
    /// 失敗は無視する —— 消せなくても `RemoteDispatchQueue.staleSeconds` で失効する
    private func dequeue(_ ticket: DispatchTicket) {
        _ = try? shell(RemoteDispatchQueue.dequeueCommand(home: home, ticket: ticket))
    }

    private func shell(_ command: String) throws -> Shell.Result {
        try Shell.run(["/bin/sh", "-c", command], timeout: Self.commandTimeoutSeconds)
    }

    /// 取得コマンドの出力が読めなかったときの1行。仕分けは
    /// `RemoteRunDispatcher.dispatchLockFailureMessage` と同じ1つ(控えが**空**なら誰も掴んで
    /// いない = `mkdir` 自体が失敗した、それ以外は held)を `scope` 違いで通す
    static func acquireFailureMessage(status: Int32, lockRead: String?, tail: String) -> String {
        RemoteRunDispatcher.dispatchLockFailureMessage(
            status: status, lockRead: lockRead, tail: tail, sshTarget: targetLabel,
            scope: .thisMachine)
    }

    /// `--force-lock` の取得が非0で終わったとき。**控えは消してあるので held ではありえない**ので、
    /// 「誰も掴んでいない = 作成そのものが失敗した」側の文言(`lockRead: ""`)を通す
    static func creationFailureMessage(status: Int32, tail: String) -> String {
        acquireFailureMessage(status: status, lockRead: "", tail: tail)
    }

    /// 中断の印。シグナル用のスレッドと待機ループが別スレッドなので lock で守る
    /// (`DispatchInterruptFlag` と同型。あちらは RemoteRunDispatcher 専用で private)
    private final class InterruptFlag: @unchecked Sendable {
        private let lock = NSLock()
        private var value = false
        var isSet: Bool {
            lock.lock(); defer { lock.unlock() }
            return value
        }
        func mark() {
            lock.lock(); defer { lock.unlock() }
            value = true
        }
    }
}
