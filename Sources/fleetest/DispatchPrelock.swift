// DispatchPrelock.swift
// 複数機械にまたがる run で、**親(fan-out)が子より先に、機械の全順序に従って1台ずつ**
// dispatch.lock を取り切るための1箇所。順序そのものは `FTRemote.DispatchOrder` の純粋関数で、
// ここは I/O(facts の読み出し・ssh 越しの取得と解放)だけを持つ。
//
// **なぜ親が取るか**: 子が並列にそれぞれのロックを取りに行くと「A が機械①を取って②を待ち、
// B が②を取って①を待つ」循環が作れる。全員が同じ順序でしか取らないなら循環は作れない。
//
// **順序の鍵(UUID)はロックより前に要る**ので、キャッシュに無い機械だけ先に1往復して採る
// (`fillMissingUUIDs`)。採らないと、その機械への**初回ディスパッチでは順序付けが効かない**。
//
// 配線は3つの fan-out(ApiRunMachineFanout / DeviceMachineRunner / FleetRunner)から。
// **緑の run では1度も実行されない**(競合が起きないと順序も待ちも観測できない)ので、
// 取得と解放は `Actions` で差し替えられる形にしてある(`DispatchPrelockTests`)。

import FTBridgeClient
import FTCore
import FTRemote
import Foundation

final class DispatchPrelock {

    /// ロック1件の解放手続き(取得時に決まる layout を閉じ込める)。引数はこの機械へ配った子の
    /// 終了コード(nil = 子をまだ起こしていない/不明。正常終了(0/1)かどうかで無条件解放と
    /// 条件付き解放を分けるのは `RemoteRunDispatcher.releaseDispatchLockAsParent` 側の役目 ——
    /// ここは値を右から左へ渡すだけ)
    typealias Release = (Int32?) -> Void

    /// 順序の鍵の供給と、1台ぶんの取得。**テストが差し替える継ぎ目**
    struct Actions {
        /// 機械ラベルの配列 → 順序付けの入力。**引けない機械は hardwareUUID: nil(不明)**
        var keys: ([String]) -> [DispatchOrder.Machine]
        /// 1台ぶんの UUID 採取(接続の1往復)。**キャッシュに無い機械にだけ呼ぶ**。
        /// 接続できなければ throw・接続できても読めなければ nil(どちらも不明のまま)
        var probeHardwareUUID: (DispatchOrder.Machine) throws -> String?
        /// 1台ぶんの取得。成功 = (子へ渡す印の値 = ssh 宛先, 解放手続き)。
        /// 取れなければ throw(その機械は飛ばす)
        var acquire: (DispatchOrder.Machine) throws -> (marker: String, release: Release)
        var log: (String) -> Void
    }

    private let actions: Actions
    /// 取った順(解放は逆順)
    private var held: [(machine: DispatchOrder.Machine, release: Release)] = []
    /// 中断(SIGINT/SIGTERM)で親が即死して解放の defer が飛ばされないようにする観測。
    /// 登録そのもの(signal(…, SIG_IGN))が defer の実行を保証する(RemoteRunDispatcher.dispatch の
    /// 同じ仕掛け)。**do-nothing ではなくなった** —— `interruptFlag` を立てる側も兼ねる
    /// (下の `abortIfInterrupted`)
    private var interruptRelay: InterruptRelay?
    /// 中断済みの印(シグナル用スレッドと acquireInOrder のループが別スレッドなので lock で守る。
    /// RemoteRunDispatcher.DispatchInterruptFlag / LocalDispatchLock.InterruptFlag と同型 ——
    /// いずれも file-private でファイルをまたいで共有できないので、ここにも1つ持つ)
    private final class InterruptFlag: @unchecked Sendable {
        private let lock = NSLock()
        private var _interrupted = false
        var interrupted: Bool {
            lock.lock(); defer { lock.unlock() }
            return _interrupted
        }
        func mark() {
            lock.lock(); defer { lock.unlock() }
            _interrupted = true
        }
    }
    private let interruptFlag = InterruptFlag()

    /// 機械ラベル → 子の環境へ入れる印の値。**取れた機械だけ**が載る
    private(set) var markers: [String: String] = [:]

    init(actions: Actions) {
        self.actions = actions
    }

    /// **ハードウェア UUID の昇順に1台ずつ**取る(並列に撃たない = 順序が意味を持たなくなる)。
    /// 鍵の引けない機械は、順序を決める前にここで採りに行く(`fillMissingUUIDs`)。
    ///
    /// **取れなかった機械は飛ばす**(印を渡さないので、その子は自分で取りに行き、
    /// 同じ失敗を同じ文言で出す)。飛ばしても順序付けの前提は壊れない —— 要求は
    /// 「各 run が取る順序が全順序に従う」ことだけで、**一部を飛ばした部分列でも一貫性は保たれる**
    /// (飛ばした機械は誰にとっても取れないか、取れた人だけが先へ進む)。
    ///
    /// **中断(SIGINT/SIGTERM)を受けたら、ここまでに握ったロックを逆順で外して `false` を返す**。
    /// **戻り値 `false` = 中断された**(呼び手 = `DeviceMachineRunner`/`ApiRunMachineFanout` は
    /// これを見たら子を1つも起こさずに抜ける)。**throws ではなく Bool にしてある** ——
    /// `FleetRunner`(`--fleet`)も同じ Actions/`acquireInOrder` を呼ぶが、中断時の打ち切りは
    /// まだそちらに配線していない(この変更のスコープ外)。`throws` にすると戻り値を見ない
    /// 既存呼び出しごとコンパイルが壊れるので、`@discardableResult` で無視しても壊れない形にし、
    /// 中断を待たずに子を起こす退行は残しても**ビルドは壊さない**側を選ぶ。
    ///
    /// 見るのは①各機械へ進む直前 ②1台ぶんの取得が失敗した直後 の2箇所 —— ①だけだと、既に成功して
    /// いた取得の直後に来た中断は次の反復まで気づかない(最後の1台の途中で来た中断は次の反復が
    /// 無いので一生気づかない)
    @discardableResult
    func acquireInOrder(machines: [String]) -> Bool {
        let ordered = DispatchOrder.sorted(fillMissingUUIDs(actions.keys(machines)))
        guard !ordered.isEmpty else { return true }
        warnIfOrderUndetermined(ordered)
        if interruptRelay == nil {
            let flag = interruptFlag
            interruptRelay = InterruptRelay.observing { flag.mark() }
        }
        // 同じ Mac を指す別名が2つ並んだとき、2度目の取得は**自分が握っているロック**を待って
        // 詰む。控えを共有して1回だけ取る
        var markerByHost: [String: String] = [:]
        for machine in ordered {
            if abortIfInterrupted() { return false }
            if let marker = markerByHost[machine.host] {
                markers[machine.machine] = marker
                continue
            }
            do {
                let (marker, release) = try actions.acquire(machine)
                held.append((machine, release))
                markerByHost[machine.host] = marker
                markers[machine.machine] = marker
            } catch {
                if abortIfInterrupted() { return false }
                // 理由は子が改めて取りに行くときに出す(同じ拒否文言を2回書かない)
                actions.log("==> could not take the dispatch lock on \(machine.host) up front"
                    + " — that machine's run queues for it on its own")
            }
        }
        return true
    }

    /// 中断済みなら、ここまでに握ったロックを逆順で外して true を返す
    private func abortIfInterrupted() -> Bool {
        guard interruptFlag.interrupted else { return false }
        actions.log("==> interrupted while acquiring dispatch locks in order"
            + " — releasing \(held.count) already-held lock(s) and starting no sub-run")
        releaseAll()
        // 印も捨てる(外したロックを「親が持っている」と子へ渡さない)
        markers.removeAll()
        return true
    }

    /// **順序を決める前に**、キャッシュに UUID が無い機械だけ接続して採る。
    /// 順序は子を起こす前に決まるので、ここで採らないと**その機械へ初めてディスパッチする run**
    /// では全員が不明 = 最後尾になり、順序付けが1台も効かない(同時に投げた2つの初回 run で
    /// 循環が作れる)。
    ///
    /// 守る3つ: **①キャッシュにある機械へは接続しない**(定常状態で往復を1本も増やさない)/
    /// **②宛先が1つの run では採らない**(取る相手が1台なら循環は作れず、順序に意味が無い ——
    /// 払う理由の無い往復)/ **③採れなくても run は止めない**(接続できない機械はどのみち
    /// ロックも取れず、既存の「取れなかった機械は飛ばす」へ落ちる)
    private func fillMissingUUIDs(_ machines: [DispatchOrder.Machine]) -> [DispatchOrder.Machine] {
        guard Set(machines.map(\.host)).count > 1 else { return machines }
        var probed: [String: String] = [:]
        var attempted: Set<String> = []
        for machine in machines where machine.hardwareUUID == nil {
            // 同じ Mac を指す別名が2つ並んでも接続は1回(取得の markerByHost と同じ理由)
            guard attempted.insert(machine.host).inserted else { continue }
            guard let uuid = try? actions.probeHardwareUUID(machine) else { continue }
            probed[machine.host] = uuid
        }
        return machines.map { machine in
            guard machine.hardwareUUID == nil, let uuid = probed[machine.host] else { return machine }
            return DispatchOrder.Machine(machine: machine.machine, host: machine.host,
                                         hardwareUUID: uuid)
        }
    }

    /// 採りに行っても不明が残るなら**1 run につき1行**言う。
    ///
    /// **鳴り続ける警告を作らない**のが既存の規律だが、これは鳴ってよい側 —— 「順序付けが
    /// 退化していて相互待ちを防げていない」という実害のある状態で、しかも**接続できた機械は
    /// キャッシュに載るので次の run からは黙る**(残り続けるなら、その機械は本当に採れていない)。
    /// 宛先が1つなら順序に意味が無いので黙る(fillMissingUUIDs の②と同じ)
    private func warnIfOrderUndetermined(_ ordered: [DispatchOrder.Machine]) {
        guard Set(ordered.map(\.host)).count > 1 else { return }
        var seen: Set<String> = []
        let unknown = ordered.filter { $0.hardwareUUID == nil && seen.insert($0.host).inserted }
        guard !unknown.isEmpty else { return }
        actions.log("warning: could not determine the hardware UUID of "
            + unknown.map(\.host).joined(separator: ", ")
            + " — this run cannot put the machines in a global order,"
            + " so it has no protection against two runs waiting on each other")
    }

    /// 握ったぶんだけ逆順に解放する。**親が defer から呼ぶ**(成功・失敗・中断のいずれでも)。
    /// 二重に呼んでも無害(held が既に空なら何もしない)。
    ///
    /// `exitCodes`: この run で各機械へ配った子の終了コード(machine ラベルで引く。
    /// `DeviceMachineRunner`/`ApiRunMachineFanout` の outcomes から作る)。**省略時(既定 `[:]`)は
    /// 全機械が「終了コード不明」の扱いになる** —— 子をまだ1つも起こしていない中断時の解放
    /// (`abortIfInterrupted`)や、この引数をまだ渡していない呼び手(`FleetRunner`)はこちらに落ちる。
    /// 受け手側(`RemoteRunDispatcher.releaseDispatchLockAsParent`)は「不明」を「正常終了」と
    /// 混同せず安全側(生死を確かめてから外す)に倒すので、省略しても壊れない
    func releaseAll(exitCodes: [String: Int32] = [:]) {
        for entry in held.reversed() { entry.release(exitCodes[entry.machine.machine]) }
        held.removeAll()
        interruptRelay?.stop()
        interruptRelay = nil
    }

    // MARK: - 本番の Actions

    /// facts キャッシュ(`.fleetest/remote-hosts/<host>.json`)から順序の鍵を引き、
    /// **載っていない機械だけ** `RemoteRunDispatcher.probeHardwareUUIDAsParent` で採り直す。
    /// 取得は子とまったく同じ `RemoteRunDispatcher.acquireDispatchLock`(待機列 FIFO)を通す。
    /// `mode` は進行ログの出し先(cliRun = stdout / apiRun = stderr + NDJSON)。
    ///
    /// **手元(`local`)も他の機械と同じ扱い**で、`LocalDispatchLock` が同じコマンド・同じ待機列を
    /// `/bin/sh -c` で撃つ(ユーザー決定「1つのマシンで同時に複数の run は走らせない」)。
    /// 手元だけ順序の外へ出すと、**A が手元を握って M1Max を待ち、B が M1Max を握って手元を待つ**
    /// 形が作れる(手元も全順序の1要素でなければ循環は消えない)。**local を「取得済み」扱いにして
    /// ここで取り直しを飛ばす口を作らない** —— 手元だけ全順序の外へ出す形そのものになり、
    /// 上と同じ循環待ちを合成できてしまう(docs/remote-runner.md §18.10)
    static func live(project: TestProject, remoteDir: String?, forceLock: Bool, waitLock: Int?,
                     runGroup: String?, mode: RemoteDispatchMode,
                     log: @escaping (String) -> Void) -> Actions {
        let entries = LocalConfig.load().remoteHosts ?? []
        let factsDir = RemoteHostFactsStore.dir(project: project)
        let localHost = RunRecorder.currentMachine()
        // UUID の採取も取得も**同じ dispatcher**(= 子とまったく同じ ssh の組み立て)を通す
        func dispatcher(for machine: DispatchOrder.Machine) throws -> RemoteRunDispatcher {
            let resolved = try RemoteHostResolver.resolve(rawHost: machine.machine,
                                                          remoteDirOverride: remoteDir)
            return RemoteRunDispatcher(
                host: resolved.hostSpec, remoteDirRaw: resolved.remoteDirRaw,
                localRepoRoot: try RepoRoot.find(), mode: mode,
                forceLock: forceLock, waitLock: waitLock, hostLabel: machine.machine)
        }
        return Actions(
            keys: { labels in
                labels.map { label in
                    // 読みと書きで鍵がずれないよう、解決は RemoteHostFactsStore.hostKey の1箇所
                    let host = RemoteHostFactsStore.hostKey(machine: label, entries: entries,
                                                            localHost: localHost)
                    return DispatchOrder.Machine(
                        machine: label, host: host,
                        hardwareUUID: RemoteHostFactsStore.load(dir: factsDir, host: host)?.hardwareUUID)
                }
            },
            // 採取は既存の経路そのまま(接続の1往復に相乗り → facts キャッシュへ)。
            // 2つ目の採取実装を作らない = RemoteRunDispatcher.probeHardwareUUIDAsParent。
            // 手元は ssh を張れないので、同じ1行を `/bin/sh -c` で撃つ LocalDispatchLock 側
            probeHardwareUUID: { machine in
                guard !MachineDispatch.isExplicitLocal(machine.machine) else {
                    return LocalDispatchLock.probeHardwareUUID()
                }
                return try dispatcher(for: machine).probeHardwareUUIDAsParent(project: project)
            },
            acquire: { machine in
                guard !MachineDispatch.isExplicitLocal(machine.machine) else {
                    let local = LocalDispatchLock(runGroup: runGroup, waitLock: waitLock,
                                                  forceLock: forceLock, log: log)
                    // **nil = この fan-out 自身が誰かの子で、手元のロックは既に上が握っている**
                    // (入れ子の run)。そのときも印は配る —— 配らないと孫が自分で取りに行き、
                    // 祖先の握っているロックを待って詰む。解放は握った1箇所(= 上)だけが行う。
                    // **local の release は終了コードを見ない** —— 呼び手は子プロセスの終了
                    // (waitForExit 完了)を待ってから release を呼ぶので、渡された時点で子は
                    // 既に死んでいる(リモートと違い「後始末が非同期でまだ生きているかも」が無い)
                    guard let holder = try local.acquire() else {
                        return (DispatchLockHandoff.localTarget, { _ in })
                    }
                    return (DispatchLockHandoff.localTarget, { _ in holder.release() })
                }
                let target = try dispatcher(for: machine)
                let layout = try target.acquireDispatchLockAsParent(project: project,
                                                                    runGroup: runGroup)
                return (target.host.sshTarget,
                        { exitCode in target.releaseDispatchLockAsParent(layout: layout, exitCode: exitCode) })
            },
            log: log)
    }

    /// この run がロックを取りに行く機械のラベル。**手元(`local`)も含める** ——
    /// 手元の run も同じ dispatch.lock を取るようになった(`LocalDispatchLock`)ので、
    /// ここで落とすと fan-out の local 枠だけがロック無しで走り、同時刻の別 run と
    /// 同じ CoreSimulatorService を奪い合う。重複は畳む(同じ機械を2回取りに行かない)
    static func machinesToLock(_ labels: [String]) -> [String] {
        var seen: Set<String> = []
        return labels.filter { seen.insert($0).inserted }
    }
}
