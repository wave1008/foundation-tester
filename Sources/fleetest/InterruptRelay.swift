// InterruptRelay.swift
// 中断(SIGINT / SIGTERM / SIGHUP)を、いま動かしている子プロセスへ伝えるための箱。
//
// **親を殺しても子は死なない**: Foundation の Process は親の終了に子を巻き込まないので、
// fleetest を kill しても ssh クライアントは生き残る。すると `-tt` が担っていた
// 「切断でリモートのプロセスグループへ SIGHUP」(docs/remote-runner.md §16.1)が**発火しない** ——
// リモートには走りっぱなしの run が残り、dispatch.lock も握られたままになる
// (2026-08-18 に実測。残った子は exit 途中で刺さり、次のディスパッチが数十分ぶん詰まった)。
//
// 中断を握りつぶすのではなく、**子を落としてから通常の巻き戻しを続ける**のが要点:
// そうすることで呼び出し側の defer(dispatch.lock の解放・終了スクリプト)が動く。
//
// **1プロセスに1組のシグナルソース**: ホスト別の子を並行に持つ親
// (DeviceMachineRunner / FleetRunner / ApiRunMachineFanout)は relay を同時に複数抱える。
// 以前は relay ごとにソースを立て、`stop()` が `signal(sig, SIG_DFL)` を戻していたため、
// **先に終わった子の stop() が残りの子の横取りまで解いていた** —— 手元のぶんが先に終わった
// 分散 run の親へ `kill -INT` すると、親だけ既定動作で死に、残った M1Max の子・ssh・リモートの
// run・dispatch.lock が全部残った(受け手報告 2026-08-23。端末の Ctrl-C はプロセスグループ
// 全体に届くので子も自力で止まり、差が出ない)。ソースは登録が 0→1 で立て、1→0 で戻す。

import Foundation
import FTCore

final class InterruptRelay {
    private enum Target {
        case process(Process, escalateAfter: TimeInterval?)
        /// `Process` を伴わない購読(手元だけの `api run`/`run`)。呼び出し側が自分で
        /// 「新しいシナリオを配らない」「実行中のシナリオ子へ SIGTERM」を行ってから通常の完了経路へ
        /// 進む —— ここでは通知するだけ(escalate は無意味 = process が無い)
        case observer(@Sendable () -> Void)
    }

    /// observer 用の識別子アンカー。ObjectIdentifier は寿命に依存しないただの値なので、
    /// このトークンは targets 辞書の値(Target.observer と一緒に保持されるわけではない)経由では
    /// 保持されない —— 呼び出し側が返り値の InterruptRelay を保持している間、このトークンも
    /// InterruptRelay 自身が握って生かす
    private final class ObserverToken {}

    private static let signals: [Int32] = [SIGINT, SIGTERM, SIGHUP]
    private static let queue = DispatchQueue(label: "fleetest.interrupt-relay")
    private static let lock = NSLock()
    private static var targets: [ObjectIdentifier: Target] = [:]
    private static var sources: [DispatchSourceSignal] = []

    private let id: ObjectIdentifier
    /// 自分が observer 版のときだけ非 nil(識別子アンカーを生かし続けるため)
    private let observerToken: ObserverToken?
    private var stopped = false

    private init(id: ObjectIdentifier, observerToken: ObserverToken? = nil) {
        self.id = id
        self.observerToken = observerToken
    }

    /// `process` が動いている間だけ中断を横取りし、受けたら子へ SIGTERM を送る。
    /// 戻り値を `stop()` するまで有効(呼び出し側は defer で止める)。
    ///
    /// - escalateAfter: SIGTERM で死ななかったときに SIGKILL するまでの猶予。
    ///   **nil = エスカレートしない**。使い分け:
    ///   - **ssh(外部プロセス。片付けるものが無い)= 2 秒**。残すと「親は死んだのにリモートは
    ///     走り続ける」元の症状に戻るので必ず落とす
    ///   - **fleetest の子(マシン別サブ実行)= nil**。こちらは SIGTERM を受けてから
    ///     dispatch.lock の解放と終了スクリプトを走らせる。**時間で殺すとそれを飛ばす** ——
    ///     2 秒で殺していた版では実際にロックが残った(2026-08-18 実測: 子の exit=9)。
    ///     片付けの所要は利用者のスクリプト次第で上限を決められないので、待つ側に倒す
    ///     (刺さった場合は人が kill -9 する)
    static func forwarding(to process: Process, escalateAfter: TimeInterval? = 2) -> InterruptRelay {
        let id = ObjectIdentifier(process)
        lock.lock()
        defer { lock.unlock() }
        let wasEmpty = targets.isEmpty
        targets[id] = .process(process, escalateAfter: escalateAfter)
        if wasEmpty { installSources() }
        return InterruptRelay(id: id)
    }

    /// `Process` を持たない購読(手元だけの `api run`/`run`)。SIGINT/SIGTERM/SIGHUP を
    /// 受けるたび `onInterrupt` を呼ぶだけ(処理は呼び出し側 —— 新しいシナリオの配布停止・
    /// 実行中のシナリオ子への SIGTERM は呼び出し側の責務)。**同じ静的なシグナルソース集合を
    /// `forwarding(to:)` と共有する**(1プロセスに1組。二重にソースを立てない)
    static func observing(_ onInterrupt: @escaping @Sendable () -> Void) -> InterruptRelay {
        let token = ObserverToken()
        let id = ObjectIdentifier(token)
        lock.lock()
        defer { lock.unlock() }
        let wasEmpty = targets.isEmpty
        targets[id] = .observer(onInterrupt)
        if wasEmpty { installSources() }
        return InterruptRelay(id: id, observerToken: token)
    }

    /// 横取りをやめる。**最後の1つが止まったときだけ**既定動作へ戻す(以降の中断は普通に
    /// このプロセスを終わらせる)。二重に呼んでも無害
    func stop() {
        Self.lock.lock()
        defer { Self.lock.unlock() }
        guard !stopped else { return }
        stopped = true
        Self.targets.removeValue(forKey: id)
        if Self.targets.isEmpty { Self.uninstallSources() }
    }

    /// 現在登録されている子の数(テスト用)
    static var registeredCount: Int {
        lock.lock()
        defer { lock.unlock() }
        return targets.count
    }

    // lock を握ったまま呼ぶ
    private static func installSources() {
        for sig in signals {
            // **DispatchSourceSignal は既定動作を止めない**ので、先に無視へ倒す
            // (これを忘れると、ハンドラが動く前にプロセスごと終わる)
            signal(sig, SIG_IGN)
            let source = DispatchSource.makeSignalSource(signal: sig, queue: queue)
            source.setEventHandler { forwardToAll() }
            source.resume()
            sources.append(source)
        }
    }

    // lock を握ったまま呼ぶ
    private static func uninstallSources() {
        for source in sources { source.cancel() }
        sources.removeAll()
        for sig in signals { signal(sig, SIG_DFL) }
    }

    private static func forwardToAll() {
        lock.lock()
        let snapshot = Array(targets.values)
        lock.unlock()
        for target in snapshot {
            switch target {
            case .process(let process, let escalateAfter):
                guard process.isRunning else { continue }
                process.terminate()
                guard let escalateAfter else { continue }
                queue.asyncAfter(deadline: .now() + escalateAfter) {
                    if process.isRunning { kill(process.processIdentifier, SIGKILL) }
                }
            case .observer(let onInterrupt):
                onInterrupt()
            }
        }
    }
}

/// ローカル実行中の `api run`/`run` が中断(SIGINT/SIGTERM)を受けたときに握る状態。
/// 二役をまとめる: ①新しいシナリオを配らない(RunOrchestrator.requestInterrupt() 越しに
/// フラグを立てる/逐次経路は `isStopped` を直接読む)②いま動いているシナリオ子
/// (fleetest-scenarios)を SIGTERM する(ScenarioHost.run(registerChildProcess:) 経由で登録)。
/// FTCore はこの型を知らない(fleetest ターゲットへの依存を作らない) —— 両方 closure で渡す。
/// **2回目の中断は待たずに強制終了する**(1回目で通常の完了経路が刺さった場合に人が抜けられる
/// ように。CLAUDE.md「終了猶予の方針」—— この force exit だけは registerChildProcess の
/// SIGTERM や defer の巻き戻しを待たない最終手段)。
/// **構築はロック取得の直後(recorder が無い段階)で行う** —— `RunRecorder.begin()` はビルド後
/// にしか作れないので、recorder は `attachRecorder` で後から繋ぐ(attachLateSubscriber と同じ
/// 「後から来た者は現在の状態に追いつく」規律)
final class RunInterruptState: @unchecked Sendable {
    private let lock = NSLock()
    private var stopped = false
    private var runningProcesses: [ObjectIdentifier: Process] = [:]
    /// 1回目の中断で `markInterrupted()` を呼ぶ相手(以後に書く失敗の記録へ `interrupted: true` を付ける)。
    /// **構築時点では nil のことがある**(setup/供給/ビルドより前に登録するため)。`attachRecorder` が
    /// 後から繋ぐ
    private var recorder: RunRecorder?
    /// 供給フェーズを終えてオーケストレータが立ってから合流する追加の通知先
    /// (`RunOrchestrator.requestInterrupt()`)。**この型は供給フェーズの前から生きているので
    /// オーケストレータはまだ存在しない** —— `attachLateSubscriber` で後から合流させる。
    /// 合流前に既に中断済みならその場で呼ぶ(registerChildProcess と同じ「後から来た者は
    /// 現在の状態に追いつく」規律。取りこぼすと「供給中に中断 → 直後にオーケストレータが立つ」
    /// 順序でオーケストレータが中断を一生知らない)
    private var lateSubscriber: (@Sendable () -> Void)?

    init(recorder: RunRecorder?) {
        self.recorder = recorder
    }

    var isStopped: Bool {
        lock.lock(); defer { lock.unlock() }
        return stopped
    }

    /// InterruptRelay.observing(_:) に渡す。1回目: 新規配布の停止フラグを立て、登録済みの
    /// 実行中プロセス全部へ SIGTERM(2回目以降: プロセスの再列挙は無害だが、それに加えて
    /// このプロセス自体を即終了させる)
    func requestStop() {
        lock.lock()
        let firstTime = !stopped
        stopped = true
        let toKill = Array(runningProcesses.values)
        let subscriber = firstTime ? lateSubscriber : nil
        let currentRecorder = recorder
        lock.unlock()
        // 子を止める前に印を付ける(止めた子の失敗の記録が印より先に書かれないように)
        if firstTime {
            currentRecorder?.markInterrupted()
            subscriber?()
            // 供給中(ブリッジの起動等)は止まるまで数十秒かかりうるので、効いていることを言う
            // (無言だと利用者は効いていないと見て強制終了し、中断の記録が残らない)
            ConsoleOut.err("⏹ Interrupt received — stopping (the device supply or the running"
                + " scenario finishes its current step first; send it again to quit immediately"
                + " without the interruption record)")
        }
        for process in toKill where process.isRunning { process.terminate() }
        guard !firstTime else { return }
        // rc=143 は「同じシグナルを2回受けた」ことの目印(1回目は下の通常経路で rc=1 になる)
        exit(143)
    }

    /// 供給フェーズより前に立てた `RunInterruptState` へ、あとから組み上がった
    /// `RunOrchestrator.requestInterrupt()` を合流させる。**登録前に既に中断済みならその場で呼ぶ**
    /// (registerChildProcess と同じ取りこぼし対策 —— 供給中に届いた中断を、オーケストレータが
    /// 後から合流したというだけの理由で黙らせない)
    func attachLateSubscriber(_ subscriber: @escaping @Sendable () -> Void) {
        lock.lock()
        let alreadyStopped = stopped
        if !alreadyStopped { lateSubscriber = subscriber }
        lock.unlock()
        if alreadyStopped { subscriber() }
    }

    /// `RunRecorder.begin()`(ビルド後にしか作れない)が確定したら繋ぐ。**登録前に既に中断済み
    /// なら、その場で markInterrupted() を呼ぶ**(attachLateSubscriber と同じ取りこぼし対策)
    func attachRecorder(_ recorder: RunRecorder) {
        lock.lock()
        let alreadyStopped = stopped
        if self.recorder == nil { self.recorder = recorder }
        lock.unlock()
        if alreadyStopped { recorder.markInterrupted() }
    }

    /// ScenarioHost.run(registerChildProcess:) に渡す。登録前に既に中断済みならその場で
    /// SIGTERM する(register と中断到着の競合を取りこぼさない)
    func registerChildProcess(_ process: Process) -> @Sendable () -> Void {
        let id = ObjectIdentifier(process)
        lock.lock()
        let alreadyStopped = stopped
        if !alreadyStopped { runningProcesses[id] = process }
        lock.unlock()
        if alreadyStopped, process.isRunning { process.terminate() }
        return { [weak self] in
            guard let self else { return }
            self.lock.lock()
            self.runningProcesses.removeValue(forKey: id)
            self.lock.unlock()
        }
    }
}

/// setup.sh・供給(ブリッジ起動等)・ビルドのいずれか(= まだ `RunRecorder` が無いか、
/// シナリオが1本も始まっていない段階)で中断が来たときに投げる。**既存の早期失敗と同じ出口**
/// (ビルド失敗等と同じく、NDJSON は1行も出さず defer で後始末して stderr + 非0 exit で終わる)。
/// 利用者向け文言は英語のみ
struct RunInterruptedBeforeStartError: Error, LocalizedError {
    let phase: String
    var errorDescription: String? {
        "interrupted before the run could start (during \(phase)) — cleaned up and exiting"
    }
}
