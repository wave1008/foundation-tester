// fleetest run --profile の実行パス:
//   実行プロファイル解決 → ワーカー構築(iOS ブリッジ供給 / Android 照合)→
//   自動インストール → RunOrchestrator で両OS同時並列実行。
// ワーカー構築の実体は ProfileWorkerFactory。

import ArgumentParser  // --device の指定違いを ValidationError で返す
import Foundation
import FTFoundationModels
import FTAndroid
import FTBridgeClient
import FTCore
import FTRemote  // WaitLockPolling(rejectIfLocalDevicesLeasedBeforeDispatch の --wait-lock)

/// `rejectIfLocalDevicesLeasedBeforeDispatch` の「待つか即断るか」だけを切り出した純粋関数
/// (I/O 無し。dispatch.lock の待機と刻みを共有するため新しい定数は作らない)
enum LocalDeviceLeaseWaitPolicy {
    static func decide(elapsedSeconds: Int, waitLock: Int?) -> WaitLockPolling.Decision {
        guard let waitLock else { return .giveUp }
        return WaitLockPolling.decide(elapsedSeconds: elapsedSeconds, limitSeconds: waitLock)
    }
}

enum ProfileRunner {

    /// 実行プロファイルの実効 FM 設定を、`ResolvedProfile.fm`/`ocrTextVisibilityCheck` から
    /// そのまま写す(**上書きは `--set` が `ProfileResolver.resolve(overrides:)` で当て済み**なので、
    /// ここで CLI 由来の override を二重に適用しない)
    static func fmSettingsRecord(resolved: ResolvedProfile) -> FMSettingsRecord {
        FMSettingsRecord(
            heal: resolved.heal,
            fmTextVisibilityCheck: resolved.fm.fmTextVisibilityCheck,
            screenLooksLike: resolved.fm.screenLooksLike,
            ocrTextVisibilityCheck: resolved.ocrTextVisibilityCheck)
    }

    /// この run が使おうとしているデバイスの run-lease(`.fleetest/run-<key>.lease`)に、
    /// 生きた別プロセスが既に居ないか確かめて、居ればデバイス+保持者 pid を名指しして拒否する
    /// (ユーザー決定「拒否して止める」)。
    /// **呼び出しは各供給フェーズが `supplyLease?.hold(keys:)` で自分の lease を書き始める直前**
    /// (書いた後だと自分の lease を自分と衝突と見なしてしまう)。判定自体は `RunLeaseGuard.conflicts`
    /// (pure function)。`leaseStateDir` が取れない(リポジトリ外実行等)なら何もしない ——
    /// そもそも lease を書けないので検査材料が無く、安全側(検査なし)に倒す。
    /// ApiRunCommand と共用(Android/iOS どちらの供給フェーズからも同じ形で呼ぶ)
    static func rejectIfDeviceLeased(
        workers: [RunWorker], leaseStateDir: URL?,
        selfPID: Int32 = ProcessInfo.processInfo.processIdentifier
    ) throws {
        let devices: [(device: String, key: String)] = workers.compactMap { worker in
            (worker.connection.serial ?? worker.connection.udid).map { (worker.label, $0) }
        }
        try rejectIfDeviceLeased(devices: devices, leaseStateDir: leaseStateDir, selfPID: selfPID)
    }

    /// devices 版(デバイスはまだ RunWorker になっていないが、鍵だけ`leaseKeysByDevice`で解決できている
    /// 時点で使う)。**ブリッジ供給(buildIOSWorkers/buildAndroidWorkers)より前に lease を持つため**
    /// —— 供給には Wipe Data・古いブリッジの停止・凍結デバイスの再起動などの破壊的操作を含み数十秒かかりうるので、
    /// worker が揃うのを待ってから hold すると、その間 lease が無く `stop-device` 等にデバイスを奪われる
    static func rejectIfDeviceLeased(
        devices: [(device: String, key: String)], leaseStateDir: URL?,
        selfPID: Int32 = ProcessInfo.processInfo.processIdentifier
    ) throws {
        guard let leaseStateDir else { return }
        let conflicts = RunLeaseGuard.conflicts(
            devices: devices, selfPID: selfPID,
            holderPID: { RunLease.holderPID(stateDir: leaseStateDir, key: $0) })
        guard conflicts.isEmpty else {
            throw ProfileWorkerFactory.InstallError(message: RunLeaseGuard.message(conflicts))
        }
    }

    /// 供給(buildAndroidWorkers/buildIOSWorkers/buildWorkers)より前に run-lease を前倒しして持つ
    /// 共通実装。手順は reject(planned) → hold(planned) → build() → reject(built) → hold(built) →
    /// release(planned - built) で固定(順序自体が対策 = 供給完了を待ってから hold すると、
    /// 供給中(Wipe Data・古いブリッジ停止・凍結デバイスの再起動などで数十秒かかりうる)は lease が無く
    /// 別プロセスの `stop-device` 等にデバイスを奪われる。負荷テスト実測: 供給中のシミュレータを
    /// 奪われて run が落ちた)。`platforms` は前倒しで hold する lease キーを `resolved` から
    /// 絞り込むためだけに使う(実際に何を build するかは呼び出し側の `build` クロージャが決める)。
    /// **ProfileRunner と ApiRunCommand の全供給パスがこれを呼ぶ**(CLAUDE.md「run と api run は
    /// 別配線の2実装」対策 —— 各経路が前倒しを別々に書くと、書き忘れた経路にだけ同じ穴が残る)
    static func buildWorkersWithFrontLoadedLease(
        resolved: ResolvedProfile, platforms: Set<String>, leaseStateDir: URL?,
        supplyLease: SupplyLeaseHolder?,
        build: () async throws -> [RunWorker]
    ) async throws -> [RunWorker] {
        let plannedKeys = leaseKeysByDevice(resolved: resolved)
            .filter { platforms.contains($0.device.platform) }
            .map { (device: $0.device.name, key: $0.key) }
        try rejectIfDeviceLeased(devices: plannedKeys, leaseStateDir: leaseStateDir)
        supplyLease?.hold(keys: plannedKeys.map(\.key))
        let workers = try await build()
        // 供給前に解決できなかったデバイス(起動直後に serial が決まる AVD 等)も同じ規律で確保する
        try rejectIfDeviceLeased(workers: workers, leaseStateDir: leaseStateDir)
        let builtKeys = workers.compactMap { $0.connection.serial ?? $0.connection.udid }
        supplyLease?.hold(keys: builtKeys)
        // 予定したが実際には用意できなかったデバイス(供給失敗でレーンから外れた)の lease は取り消す
        let builtKeySet = Set(builtKeys)
        supplyLease?.releaseKeys(plannedKeys.map(\.key).filter { !builtKeySet.contains($0) })
        return workers
    }

    /// **開始スクリプトと供給の前**に、使うデバイスの lease キーをデバイスの実体から引いて二重使用を断る。
    /// 供給段は破壊的な準備(Wipe Data・GPU 復帰・古いブリッジの停止・凍結デバイスの再起動)を含むので、
    /// ワーカー構築後の判定(rejectIfDeviceLeased)だけだと、2本目が1本目のデバイスを消去・再起動してから断る。
    /// 引けないデバイス(停止中のエミュレータ・一覧に無いシミュレータ)は飛ばす —— 生きた run はそこを掴めない。
    /// ワーカー構築後の判定は残す(準備で serial が変わりうる)。ApiRunCommand と共用
    static func rejectIfDevicesLeasedBeforePreparation(
        resolved: ResolvedProfile, leaseStateDir: URL?,
        selfPID: Int32 = ProcessInfo.processInfo.processIdentifier
    ) throws {
        guard let leaseStateDir else { return }
        let conflicts = RunLeaseGuard.conflicts(
            devices: leaseKeysBeforePreparation(resolved: resolved), selfPID: selfPID,
            holderPID: { RunLease.holderPID(stateDir: leaseStateDir, key: $0) })
        guard conflicts.isEmpty else {
            throw ProfileWorkerFactory.InstallError(message: RunLeaseGuard.message(conflicts))
        }
    }

    /// **機械分担の run がリモートへ配る前に**、手元の子と同じ規則(この機械のデバイスへ絞る →
    /// 本数+予備で絞る(MCP のデバイスを避ける)→ lease 照合)で二重使用を断る(デバイス+保持者 pid を名指しして throw)。
    /// 手元の子の拒否より先にリモートの子がロックを取り、断られた run の半分が走って同時刻の
    /// 別 run のリモート分を丸ごと弾いていた(負荷テスト M12)。
    /// 判定材料が揃わない(プロファイル解決の失敗等)ときは何もしない = 手元の子の判定に任せる。
    /// DeviceMachineRunner と ApiRunMachineFanout の2経路から呼ぶ。
    ///
    /// **`waitLock` があれば、この機械の dispatch.lock と同じ刻み(`WaitLockPolling`)で
    /// 待ってから再判定する**(この機械は dispatch.lock で1マシン1 run を守っているので、
    /// 走行中の run が終わればデバイスの lease は必ず空く = 待てば必ず解消する)。無ければ即座に断る
    /// (`LocalDeviceLeaseWaitPolicy.decide`)。上限に達しても空かなければ今と同じ文言で断る
    static func rejectIfLocalDevicesLeasedBeforeDispatch(
        project: TestProject, profileName: String, setOverrides: [String: RunProfileSetValue],
        localDeviceNames: [String], localScenarios: [ScenarioInfo], broadcast: Bool,
        waitLock: Int? = nil,
        leaseStateDir: URL? = (try? RepoRoot.find())?.appendingPathComponent(".fleetest"),
        log: (String) -> Void = { _ in },
        sleepSeconds: (Int) -> Void = { Thread.sleep(forTimeInterval: Double($0)) }
    ) throws {
        guard let leaseStateDir, !localScenarios.isEmpty,
              let resolvedAll = try? ProfileResolver.resolve(
                  project: project, runName: profileName, overrides: setOverrides)
        else { return }
        let full = resolvedAll.filteringDevices(
            names: localDeviceNames, deviceMachine: DeviceMachineGrouping.localDisplayName)
        guard !full.devices.isEmpty else { return }
        let (resolved, _) = limitingDevicesAvoidingMCP(
            full, iosScenarios: localScenarios.filter { $0.platform != "android" }.count,
            androidScenarios: localScenarios.filter { $0.platform != "ios" }.count,
            trim: !broadcast, leaseStateDir: leaseStateDir)
        var elapsed = 0
        while true {
            do {
                try rejectIfDevicesLeasedBeforePreparation(resolved: resolved, leaseStateDir: leaseStateDir)
                return
            } catch {
                guard LocalDeviceLeaseWaitPolicy.decide(elapsedSeconds: elapsed, waitLock: waitLock)
                    == .retry else {
                    throw ProfileWorkerFactory.InstallError(message: error.localizedDescription
                        + " Nothing was dispatched to the other machines of this profile.")
                }
            }
            if WaitLockPolling.shouldLogProgress(elapsedSeconds: elapsed) {
                log("==> waiting for the local device(s) to free up before dispatching to the"
                    + " other machines of this profile (\(elapsed)s elapsed, --wait-lock \(waitLock!)s)...")
            }
            sleepSeconds(WaitLockPolling.pollIntervalSeconds)
            elapsed += WaitLockPolling.pollIntervalSeconds
        }
    }

    /// デバイス → lease キー(Android = serial / iOS = udid。RunWorker の `serial ?? udid` と同じ値)。
    /// 解決の規則はワーカー構築と同じもの(AndroidDeviceCatalog.canonicalAVDID + 起動中の AVD /
    /// SimulatorCatalog.resolve)。iOS 実機は devicectl を引かず udid の記載をそのまま使う
    static func leaseKeysBeforePreparation(resolved: ResolvedProfile) -> [(device: String, key: String)] {
        leaseKeysByDevice(resolved: resolved).map { entry in
            ("\(entry.device.name)(\(entry.device.platform):\(entry.key))", entry.key)
        }
    }

    static func leaseKeysByDevice(resolved: ResolvedProfile) -> [(device: ResolvedDevice, key: String)] {
        var keys: [(device: ResolvedDevice, key: String)] = []
        let android = resolved.androidDevices
        if !android.isEmpty {
            let running = (try? AndroidDeviceCatalog.runningAVDs()) ?? [:]
            for device in android {
                let serial: String?
                if device.spec.isPhysical {
                    serial = device.spec.serial
                } else if let avd = device.spec.avd {
                    let canonical = AndroidDeviceCatalog.canonicalAVDID(avd)
                    serial = running.first(where: { $0.value == canonical })?.key
                } else {
                    serial = nil
                }
                if let serial { keys.append((device, serial)) }
            }
        }
        let ios = resolved.iosDevices
        if !ios.isEmpty {
            let simulators = (try? SimulatorCatalog.devices()) ?? []
            for device in ios {
                let udid = device.spec.isPhysical
                    ? device.spec.udid
                    : (try? SimulatorCatalog.resolve(spec: device.spec, in: simulators))?.udid
                if let udid { keys.append((device, udid)) }
            }
        }
        return keys
    }

    /// **回す本数に絞るとき、MCP(fleetest-mcp)が操作しているデバイスを避ける**(ユーザー決定「避けて、
    /// 足りなければ警告して使う」。予備にも残さない理由は `ResolvedProfile.limitingDevices(avoiding:)`)。
    /// それでも使うデバイスは警告で名指しする(断らない = 新しい検知は警告から)。
    /// 印(`MCPDeviceLease`)が1つも無ければデバイスの実体を引かない(simctl/adb の往復を払わない)。
    /// 自分と親の pid が持つ印は数えない(MCP が起こした run が自分を「MCP が操作中」と言わない)。
    /// `trim: false`(--broadcast)は絞らず、使うデバイスの警告だけ返す
    static func limitingDevicesAvoidingMCP(
        _ full: ResolvedProfile, iosScenarios: Int, androidScenarios: Int, trim: Bool,
        leaseStateDir: URL?
    ) -> (resolved: ResolvedProfile, warnings: [String]) {
        let holders = leaseStateDir.map {
            MCPDeviceLease.liveHolders(stateDir: $0, excluding: [getpid(), getppid()])
        } ?? [:]
        var heldBy: [ResolvedDevice: Int32] = [:]
        if !holders.isEmpty {
            for entry in leaseKeysByDevice(resolved: full) {
                if let pid = holders[entry.key] { heldBy[entry.device] = pid }
            }
        }
        let resolved = trim
            ? full.limitingDevices(iosScenarios: iosScenarios, androidScenarios: androidScenarios,
                                   avoiding: { heldBy[$0] != nil })
            : full
        // trim の理由は数で言う(「空きが無かった」は実測で誤り: 実際は「空きはあったが、
        // 本数+予備1台に足りなかった」ことが起きる。ResolvedProfile.limitingDevices の
        // deviceKeepCount と同じ計算を、プラットフォームごとに読み直す)
        func reason(for platform: String, scenarios: Int) -> String {
            guard trim else { return "--broadcast runs on every device" }
            let list = platform == "ios" ? full.iosDevices : full.androidDevices
            let free = list.filter { heldBy[$0] == nil }.count
            let needed = ResolvedProfile.deviceKeepCount(available: list.count, scenarios: scenarios)
            return Self.shortageReason(needed: needed, scenarios: scenarios, free: free)
        }
        let warnings = resolved.devices.compactMap { device -> String? in
            guard let pid = heldBy[device] else { return nil }
            let why = reason(for: device.platform,
                             scenarios: device.platform == "ios" ? iosScenarios : androidScenarios)
            return "\(device.name) is being driven by an MCP session (pid \(pid)) — this run takes it over"
                + " (\(why)); the session will see the run's screens"
        }
        return (resolved, warnings)
    }

    /// デバイスが足りず MCP のデバイスを使うときの理由を事実で組み立てる(純粋関数)。
    /// `scenarios == 0` はレーン数を数で言えない(本数不明 = 絞りの計算に使わない)ときの
    /// 単純な言い方。`scenarios > 0` は必要レーン数(本数+予備1台)と空き台数を数で言う
    static func shortageReason(needed: Int, scenarios: Int, free: Int) -> String {
        guard scenarios > 0 else { return "no other device was free" }
        func plural(_ n: Int, _ noun: String) -> String { "\(n) \(noun)\(n == 1 ? "" : "s")" }
        let freeClause = free == 1 ? "only 1 device was free" : "only \(free) devices were free"
        // **導出は成り立つときだけ書く**: `deviceKeepCount` は台数でクランプされる
        // (min(available, scenarios + 1))ので、本数よりデバイスが少ない run では
        // 「(N scenarios + 1 spare)」が needed を生まない。そのときは数の内訳を出さない
        let derivation = needed == scenarios + 1
            ? " (\(plural(scenarios, "scenario")) + 1 spare)"
            : " (every device this profile has on this machine)"
        return "needed \(plural(needed, "lane"))" + derivation + " but \(freeClause)"
    }

    /// 戻り値: 実行サマリ(失敗数+劣化ワーカー)+ この run で実際に効いていた FM 設定。
    /// **fmSettings は tuple の2つ目として非 Optional で返す** —— `RunSummary.fmSettings` 自体は
    /// `RunOrchestrator` の生サマリ(プロファイルの実効値を知らないので常に nil)と共有する型なので
    /// Optional のままだが、この関数は0件早期リターンも含め全ての戻り経路で計算済みの値を持つ
    /// (下の2箇所の return 参照)。呼び出し側が `!` で開けずに済むよう、その保証を型で運ぶ
    /// - lpt: LPT 投入順を使うか。並べ替えは defaultPlatform が確定してからでないと
    ///   別 platform の実績で並べてしまうため、この関数の中で行う(呼び出し側では順序を触らない)。
    /// - broadcast: `--broadcast`(ブロードキャスト)。items を**各デバイスで1回ずつ**回す
    ///   (`ScenarioDispatch.broadcast`)。変わるのは台数を絞らないことと分配だけで、供給・
    ///   インストール・フック(run で1回)・スタッガ・復帰・レポートは通常 run と同じ経路
    static func run(project: TestProject, profileName: String, items rawItems: [ScenarioRunItem],
                    setOverrides: [String: RunProfileSetValue] = [:],
                    reportDirOverride: String?,
                    quiet: Bool = false, lpt: Bool = true,
                    lptHistoryRuns: Int = LPTOrdering.defaultHistoryRuns,
                    performanceMode: Bool = false,
                    deviceFilter: [String] = [],
                    deviceMachine: String? = nil,
                    workspaceOverride: String? = nil,
                    recorder: RunRecorder? = nil,
                    broadcast: Bool = false,
                    // 供給の段階の箱(入口の writeProgress の書き手が通知を持っている)。**既定値を置かない**
                    // (渡し忘れで準備中の段階が台帳に載らない)
                    supplyProgress: RunSupplyProgress,
                    // **既定値を置かない**(渡し忘れをコンパイルで止める)。呼び手はロック取得の直前に
                    // InterruptRelay を登録済みの interruptState を渡す(recorder は attachRecorder で後付け)
                    interruptState: RunInterruptState,
                    // ビルドの前に済ませた準備の段(ビルドが要る回に呼び手が渡す。片付けも呼び手が持つ)。
                    // nil なら一覧の後にここで準備する。**既定値を置かない**(渡し忘れで並行にならないまま黙って通る)
                    early: PreparedSupply?
    ) async throws -> (summary: RunSummary, fmSettings: FMSettingsRecord) {
        var items = rawItems
        let runClockStart = Date()
        // 1. プロファイル合成(準備の段を先に済ませた run は、その解決をそのまま使う)
        PhaseLog.mark("profile-runner-start")
        let full = try early?.full ?? Self.resolveFullProfile(
            project: project, profileName: profileName, setOverrides: setOverrides,
            workspaceOverride: workspaceOverride, deviceFilter: deviceFilter, deviceMachine: deviceMachine,
            broadcast: broadcast)
        // **filteringDevices/limitingDevices/broadcast は FM 設定に触れない**ので、devices を
        // 絞る前のこの時点で計算して 0 件早期リターン・本編の両方で使う
        let fmSettings = Self.fmSettingsRecord(resolved: full)
        // OS 対象外(`@TestClass(platform:)` / `@Test(platform:)` がこの run に無い OS を指す)は
        // **キューへ入れる前に外す** —— 入れると RunOrchestrator の「担当ワーカーなし」に落ち、
        // 意図された対象外が失敗として数えられる(PlatformApplicability の宣言)。
        // 台数の見積り(この下)より前に行う: 外した分のデバイスは用意しなくてよい
        let runPlatforms = Set(full.devices.map(\.platform))
        let applicability = PlatformApplicability.partition(items, runPlatforms: runPlatforms) {
            $0.info.platform
        }
        if !applicability.notApplicable.isEmpty {
            for item in applicability.notApplicable {
                let declared = item.info.platform ?? ""
                recorder?.recordSkipped(
                    scenarioID: item.info.id, title: item.info.title, platform: declared,
                    worker: nil,
                    reason: PlatformApplicability.reason(declared: declared,
                                                         runPlatforms: runPlatforms),
                    kind: .notApplicable)
            }
            ConsoleOut.out("→ Skipped \(applicability.notApplicable.count) scenario(s) declared for another"
                  + " platform (this run covers \(runPlatforms.sorted().joined(separator: ", ")))")
            items = applicability.runnable
        }
        // 全部が対象外ならデバイスを起こす意味がない(0 失敗で終える = 正しく緑)。
        // 準備の段を先に済ませた run の片付けは呼び手が持つ
        if items.isEmpty {
            return (RunSummary(total: 0, failed: 0, performanceMode: performanceMode,
                               fmSettings: fmSettings), fmSettings)
        }

        // 供給段(ワーカー構築・install 等)の例外で1本も始まらずに抜けるときは、残りを `--failed` の
        // 「直近失敗」として残す(対象外は上で外れて items に居ない)。orchestrator へ渡したら
        // 以後の未実行は RunOrchestrator が recordSkipped で残す。api run の catch と対
        var scenariosHandedToOrchestrator = false
        defer {
            if !scenariosHandedToOrchestrator { recorder?.recordLastResultsFailed(items.map(\.info.id)) }
        }

        // 2. 準備の段(台数の絞り込み・サービス・開始スクリプト・供給のタスクの起動)。本数はここで確定している
        // (items は解決済み)。platform 未指定のシナリオは**両方**に数える(どちらでも走りうる)
        let prepared: PreparedSupply
        if let early {
            prepared = early
        } else {
            prepared = try await Self.prepareSupply(
                full: full, profileName: profileName,
                iosScenarios: items.filter { $0.info.platform != "android" }.count,
                androidScenarios: items.filter { $0.info.platform != "ios" }.count,
                scenarioCount: items.count, broadcast: broadcast, reportDirOverride: reportDirOverride,
                failureLogDir: recorder?.runDir, supplyProgress: supplyProgress, interruptState: interruptState)
        }
        defer { if early == nil { prepared.close() } }
        let resolved = prepared.resolved
        let reportDir = prepared.reportDir
        let leaseStateDir = prepared.leaseStateDir
        let repoRoot = prepared.repoRoot
        let supplyLease = prepared.supplyLease
        let triageBox = prepared.triageBox
        let servicesSession = prepared.servicesSession
        // 失敗の証跡: 赤の run の後に、各サービスのログの末尾を run の記録(無ければレポートの出力先)へ残す
        let servicesLogDir = recorder?.runDir ?? reportDir
        // 計測 run の識別は finish を待たず run.json に書く(殺された run にも残す。ApiRunCommand.run と同じ)
        recorder?.recordResponseMeasurement(ResponseMeasurementPolicy.runInfo(resolved: resolved))

        // Android のレーンは開始前に揃える。iOS(ブリッジ供給=数十秒かかりうる)は lateWorkers として
        // 分離し、Android を供給完了待ちにしない(api run の並列経路と同じ方針)
        let workers: [RunWorker]
        do {
            workers = try await prepared.androidTask.value
        } catch {
            // 片付け(defer の close)は iOS の準備が終わってから(PreparedSupply.settle の宣言)
            await prepared.settle()
            throw error
        }
        let iosDevicesExist = prepared.iosTask != nil

        // performanceMode では iOS の late join をやめて開始前に揃える。**理由は計測の歪みではなく
        // ゲートの可視性** —— late join だと iOS ワーカーは run 開始後に参加するので、「iOS のレーンが
        // 足りない」を開始前に検出できず、モードの約束(足りなければ開始しない)が iOS だけ守れない。
        // 計測そのものは late join でも歪まない(provider は全機をまとめて返すのでレーンは 0→N と
        // 一段で増え、シナリオはそれまで走らない)。Android が先行する混在プロファイルだけは
        // 歪むが、そこは計測対象外(両OSを1プロファイルにまとめない方針)
        var eagerIOSWorkers: [RunWorker] = []
        if performanceMode, let iosTask = prepared.iosTask {
            eagerIOSWorkers = await iosTask.value
        }
        let hasLateIOS = iosDevicesExist && !performanceMode

        // performanceMode: 復活できなかったレーンがあれば run を開始せずに失敗する
        // (既定 false ではここへ来ない=切り離して完走を優先する挙動のまま)
        if performanceMode {
            let missingAndroid = LaneGate.missing(
                expected: resolved.androidDevices.map(\.name),
                actual: workers.compactMap(\.logicalName))
            let missingIOS = iosDevicesExist
                ? LaneGate.missing(expected: resolved.iosDevices.map(\.name),
                                   actual: eagerIOSWorkers.compactMap(\.logicalName))
                : []
            let missing = missingAndroid + missingIOS
            if !missing.isEmpty {
                throw ProfileWorkerFactory.InstallError(
                    message: "performance mode: \(missing.count) device(s) could not be started "
                        + "(\(missing.joined(separator: ", "))). Fix the devices, or turn "
                        + "performanceMode off to run on the remaining lanes.")
            }
        }

        // 3. 両OS同時並列実行(platform 別キューは RunOrchestrator がそのまま担う)
        let defaultPlatform = (hasLateIOS || (workers + eagerIOSWorkers).contains { $0.platform == "ios" })
            ? "ios" : "android"
        // 長いシナリオを先に流すと末尾の遊休が減る(実績は platform 別。--no-lpt で素の ID 順)
        items = LPTOrdering.apply(items, project: project, defaultPlatform: defaultPlatform,
                                  enabled: lpt, historyRuns: lptHistoryRuns, log: { ConsoleOut.out($0) })
        if resolved.responseMeasurement {
            items = ResponseMeasurementRepeat.expand(items, count: resolved.responseRepeat)
        }
        // ApiRunCommand.run と同じ関数(RunStartLine)で組み立てる(CLAUDE.md「2 実装の差」対策)
        ConsoleOut.out(RunStartLine.text(
            androidWorkers: workers.count, eagerIOSWorkers: eagerIOSWorkers.count, hasLateIOS: hasLateIOS)
            + "\n")

        // SIGINT/SIGTERM を受けたら、新しいシナリオを配らず・今動いている子(fleetest-scenarios)
        // を SIGTERM してから RunOrchestrator.run() の通常の完了経路(録画停止・lease 解放・
        // drain・summary)を通す(ApiRunCommand.runWithProfileParallel と同じ形。CLAUDE.md
        // 「終了猶予の方針」= 自前の後始末を持つ fleetest の子には時限の SIGKILL を送らない)。
        // **interruptState は呼び出し元(Fleetest.swift の run())が供給の前から持っている**
        // (パラメータで受け取るだけ。ここで新しく作ると、この関数の上のほうの供給フェーズ
        // 〈buildWorkersWithFrontLoadedLease・blank/frozen triage・install〉中に届いた中断を
        // 取りこぼす)

        // **sweep はここでは呼ばない** —— この run の掃除は "building" を書く入口で済んでいる
        // (1 run で2回走らせない。docs/design.md §18.1「run 開始時に1回」)

        // 段階「準備中」の控え。handoff が立たないまま抜けるときは defer で消す(writePreparingProgress の doc)
        let progressWriter = ProfileRunOrchestrator.writePreparingProgress(
            recorder: recorder, project: project, profile: profileName, supply: supplyProgress)
        var progressHandedToOrchestrator = false
        defer {
            if !progressHandedToOrchestrator {
                progressWriter.close()
                RunProgressLedger.remove(pid: ProcessInfo.processInfo.processIdentifier,
                                         directory: RunProgressLedger.directory())
            }
        }

        let orchestrator = ProfileRunOrchestrator.make(
            project: project, workers: workers + eagerIOSWorkers, resolved: resolved, reportDir: reportDir,
            recorder: recorder, repoRoot: repoRoot, leaseStateDir: leaseStateDir, supplyLease: supplyLease,
            profile: profileName, progressHistoryRuns: lptHistoryRuns, interruptState: interruptState,
            lateWorkers: hasLateIOS ? (platforms: Set(["ios"]), provider: { @Sendable [iosTask = prepared.iosTask] in
                await iosTask?.value ?? []
            }) : nil,
            supply: supplyProgress,
            onRevived: { _ in },
            log: { ConsoleOut.out($0) })
        // **新しい InterruptRelay は登録しない**(1プロセス1組。呼び出し元が既に登録済み)。
        // 供給中に既に中断済みならここで即 orchestrator.requestInterrupt() が呼ばれる
        interruptState.attachLateSubscriber { orchestrator.requestInterrupt() }
        PhaseLog.mark("orchestrator-setup")
        // レーン = 絞り込み後の全デバイス(供給に失敗して参加しなかったデバイスのぶんは、orchestrator が
        // 「never joined」でそのレーンの本数を失敗として残す = 準備できなかったデバイスが緑に紛れない)
        let dispatch: ScenarioDispatch = broadcast
            ? .broadcast(lanes: resolved.devices.map { BroadcastLane(key: $0.name, platform: $0.platform) })
            : .shared
        let itemsToRun = items  // async let は var を直接捕捉できない(Sendable 境界)
        // iOS 実機の計測だけ: 供給の後・配布の前から xctrace を録る(止めて結果へ入れるのは summary の後)
        let responseTrace = await ResponseTraceSession.startIfNeeded(resolved: resolved) { ConsoleOut.out($0) }
        defer { responseTrace?.cleanup() }
        // ここから先は RunOrchestrator.run() が必ず finish() まで進む(non-throwing)ので、
        // "preparing" の後始末は orchestrator 側の finish()/remove に委ねる
        progressHandedToOrchestrator = true
        scenariosHandedToOrchestrator = true
        async let summary = orchestrator.run(items: itemsToRun, defaultPlatform: defaultPlatform,
                                             dispatch: dispatch)

        // シナリオ毎にバッファして完了時に一括表示(並列時のステップ行の混線防止)。
        // quiet: 成功シナリオは結果1行のみ・失敗シナリオはバッファ全体(失敗詳細)を出す
        var buffers: [URL: [String]] = [:]
        var names: [URL: String] = [:]
        var timing = ScenarioTimingTracker()
        for await event in orchestrator.events {
            timing.record(event)
            var mode: String?
            if case .flowStarted(let worker, _, _, _) = event {
                mode = WorkerModeSummary.mode(forLabel: worker, in: recorder?.recordedWorkerModes ?? [])
            }
            let lines = RunLogFormatter.lines(for: event, mode: mode)
            switch event {
            case .flowStarted(_, let url, let flowName, _):
                names[url] = flowName
                buffers[url, default: []].append(contentsOf: lines)
            case .step(_, let url, _), .flowRequeued(_, let url, _, _, _):
                buffers[url, default: []].append(contentsOf: lines)
            case .flowFinished(_, let url, let passed, _, _, _, let notApplicableReason):
                let all = (buffers.removeValue(forKey: url) ?? []) + lines
                if quiet {
                    ConsoleOut.out(notApplicableReason != nil ? "⏭ \(names[url] ?? url.lastPathComponent)"
                                 : passed ? "✅ \(names[url] ?? url.lastPathComponent)"
                                 : "❌ \(names[url] ?? url.lastPathComponent)\n" + all.joined(separator: "\n"))
                } else {
                    ConsoleOut.out(all.joined(separator: "\n"))
                }
            default:
                if !lines.isEmpty { ConsoleOut.out(lines.joined(separator: "\n")) }
            }
        }

        let totalSeconds = Date().timeIntervalSince(runClockStart)
        let testStr = timing.testSeconds.map { String(format: "%.1f", $0) } ?? "-"
        let scenarioTotalStr = timing.scenarioTotalSeconds.map { String(format: "%.1f", $0) } ?? "-"
        ConsoleOut.out("⏱ Total: \(String(format: "%.1f", totalSeconds))s / "
            + "test time: \(testStr)s / scenario sum: \(scenarioTotalStr)s")
        // どのデバイスがどのモードで走ったか(縮退は理由つき。api run と同じ文言 = WorkerModeSummary)
        for line in WorkerModeSummary.lines(recorder?.recordedWorkerModes ?? []) { ConsoleOut.out(line) }

        // プラットフォーム別のレーン稼働。台数を増やす前にここを見る(遊休レーンがあるなら
        // 増やすのではなく配分を変える。docs/performance-tuning.md §3.6)
        // 単一プラットフォームでも「レーンが遊休している」ことは読めるので出す(台数過多の検知)。
        // 逐次実行(1レーン)だけは自明なので黙る。
        let utilizations = timing.laneUtilizations
        if utilizations.count > 1 || utilizations.contains(where: { $0.lanes > 1 }) {
            let cells = utilizations.map {
                "\($0.platform) \($0.lanes) lane(s), \(Int(($0.utilization * 100).rounded()))% busy"
                + ", last finished at \(String(format: "%.1f", $0.lastFinishSeconds))s"
            }
            ConsoleOut.out("📊 Lane utilisation: " + cells.joined(separator: " / "))
            if let advice = LaneBalanceAdvice.message(for: utilizations) { ConsoleOut.out(advice) }
        }

        let finalSummary = await summary
        if let abortReason = finalSummary.abortReason { ConsoleOut.out("❌ Run stopped: \(abortReason)") }
        await responseTrace?.finish(runDir: recorder?.runDir) { ConsoleOut.out($0) }
        if finalSummary.failed > 0 { servicesSession?.saveLogs(to: servicesLogDir) { ConsoleOut.out($0) } }
        if !finalSummary.degradedWorkers.isEmpty {
            ConsoleOut.out("⚠️ Degraded or dropped workers (\(finalSummary.degradedWorkers.count)):")
            for entry in finalSummary.degradedWorkers { ConsoleOut.out("   - \(entry)") }
        }
        if !finalSummary.freezeRetries.isEmpty {
            ConsoleOut.out("🔁 Results discarded and requeued (\(finalSummary.freezeRetries.count)):")
            for entry in finalSummary.freezeRetries { ConsoleOut.out("   - \(entry)") }
        }
        // performanceMode: レーン数が run 中に変わっていたら所要時間は計測に使えない
        // (MeasurementValidity の宣言参照。既定モードは判定しない=印を付けない)
        // 実行前 triage は両レーンぶん(遅延参加の iOS も run の終わりには箱に入っている)
        let preRunTriage = triageBox.get()
        let validity = MeasurementValidity.verdict(
            performanceMode: performanceMode,
            degradedWorkers: finalSummary.degradedWorkers, blankExclusions: preRunTriage.excluded)
        if validity.invalid {
            ConsoleOut.out("⏱️❌ Measurement invalid: this run's timing cannot be used for performance"
                + " comparisons (\(validity.reasons.joined(separator: "; ")))")
        }
        // run 前の blank triage(orchestrator は関与しない)を summary に載せ替えて返す
        // (RunScenarios が recorder.finish で run.json に記録する)
        let resultSummary = RunSummary(total: finalSummary.total, failed: finalSummary.failed,
                                       skipped: finalSummary.skipped,
                                       degradedWorkers: finalSummary.degradedWorkers,
                                 freezeRetries: finalSummary.freezeRetries,
                                 blankRepairs: preRunTriage.repaired,
                                 blankExclusions: preRunTriage.excluded,
                                 measurementInvalid: validity.invalid,
                                 measurementInvalidReasons: validity.reasons,
                                 fmUnavailableScenarios: finalSummary.fmUnavailableScenarios,
                                 workerAnomalies: finalSummary.workerAnomalies + triageBox.getAnomalies(),
                                 performanceMode: performanceMode,
                                 fmSettings: fmSettings,
                                 interrupted: finalSummary.interrupted,
                                 abortReason: finalSummary.abortReason,
                                 servicesWarnings: servicesSession?.warnings ?? [],
                                 responseMeasurement: ResponseMeasurementPolicy.runInfo(resolved: resolved))
        return (resultSummary, fmSettings)
    }

    /// FM を使う run の開始前に、FM が**本当に呼べるか**を確かめて警告する。
    ///
    /// **その経路を使う機能が有効な run でだけ言う** —— run の中で FM を使うのは vision 経路だけ
    /// (occlusion-guard = exist の既定 requireVisible・screenLooksLike)。**text 経路は run の中で
    /// 使わない**ので、その死は言わない(失われる機能が無いのに「無効」と言わない)。availability は嘘をつく
    /// (available のまま実呼び出しが全滅する実測)ので、台帳(FMLiveness)の実観測を使う。
    ///
    /// **台帳が新しければ1回も呼ばない** —— モニターが動いていれば既に埋まっている
    /// (FMLivenessProbe.refresh の門①)。埋まっていないときだけ 1〜2 秒払う。
    /// ApiRunCommand と共用。
    /// `readLiveness` はテストの差し替え口(既定は `FMLivenessProbe.refresh` = 台帳が古いと FM を実際に呼ぶ)
    static func warnIfFMDegraded(
        fm: FMConfig,
        readLiveness: () async -> FMLiveness.Reading = { await FMLivenessProbe.refresh() },
        log: (String) -> Void
    ) async {
        // 視覚系(occlusion-guard / screenLooksLike)を使う run だけが vision の死に影響を受ける。
        // **使わない run では台帳を引く前に返る** —— refresh は台帳が古いと FM を実際に呼ぶ
        // (0.7〜4.7 秒・FMCallSlots を取る)ので、結果を捨てる run で払わない
        let usesVision = fm.fmTextVisibilityCheck || fm.screenLooksLike
        guard fm.enabled, usesVision else { return }
        guard FMVisionSupport.isSupported else {
            log("⚠️ \(FMVisionSupport.requirement): \(visionLossDescription(fm))")
            return
        }
        let reading = await readLiveness()
        if let vision = reading.vision, vision.state == .dead {
            log("⚠️ FM is dead on this machine (vision path): \(visionLossDescription(fm))"
                + " — a green result is not a fully guarded green." + reasonSuffix(vision))
        }
    }

    /// vision 経路が使えない run で**この run が有効にした機能だけ**を挙げる(使っていない機能を
    /// 「無効」と言わない)。occlusion-guard は無効ではなく OCR だけの判定へ落ちる
    static func visionLossDescription(_ fm: FMConfig) -> String {
        var parts: [String] = []
        if fm.screenLooksLike { parts.append("screenLooksLike is skipped") }
        if fm.fmTextVisibilityCheck {
            parts.append("the occlusion-guard (the default requireVisible of exist) judges from on-device OCR alone"
                         + OCROnlyVisibility.fmFallbackCaveat)
        }
        return parts.joined(separator: ", and ")
    }

    /// 死の理由を1行に畳む。**「いつ・何を根拠に」まで出す** —— 台帳は最大
    /// FMLiveness.freshSeconds ぶん古くなりうるので、断定の強さを読み手が測れるようにする
    private static func reasonSuffix(_ verdict: FMLiveness.Verdict) -> String {
        let age = Int(Date().timeIntervalSince1970 - verdict.checkedAt)
        return "\n   Observed \(age)s ago via \(verdict.source.rawValue)"
            + (verdict.error.map { ": \($0)" } ?? "")
    }
}
