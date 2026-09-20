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

enum ProfileRunner {

    /// ワーカー復帰待ちの上限。監視側の再起動やデバイス自己回復を待つ
    private static let REVIVE_TIMEOUT: TimeInterval = 90

    /// 実行プロファイルの実効 FM 設定を、`ResolvedProfile.fm`/`ocrTextVisualCheck` から
    /// そのまま写す(**上書きは `--set` が `ProfileResolver.resolve(overrides:)` で当て済み**なので、
    /// ここで CLI 由来の override を二重に適用しない)
    static func fmSettingsRecord(resolved: ResolvedProfile) -> FMSettingsRecord {
        FMSettingsRecord(
            heal: resolved.heal,
            textVisualCheck: resolved.fm.textVisualCheck,
            screenLooksLike: resolved.fm.screenLooksLike,
            ocrTextVisualCheck: resolved.ocrTextVisualCheck)
    }

    /// この run が使おうとしている台の run-lease(`.fleetest/run-<key>.lease`)に、
    /// 生きた別プロセスが既に居ないか確かめて、居れば台+保持者 pid を名指しして拒否する
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

    /// devices 版(台はまだ RunWorker になっていないが、鍵だけ`leaseKeysByDevice`で解決できている
    /// 時点で使う)。**ブリッジ供給(buildIOSWorkers/buildAndroidWorkers)より前に lease を持つため**
    /// —— 供給には Wipe Data・古いブリッジの停止・凍結台の再起動などの破壊的操作を含み数十秒かかりうるので、
    /// worker が揃うのを待ってから hold すると、その間 lease が無く `stop-device` 等に台を奪われる
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

    /// **開始スクリプトと供給の前**に、使う台の lease キーを台の実体から引いて二重使用を断る。
    /// 供給段は破壊的な準備(Wipe Data・GPU 復帰・古いブリッジの停止・凍結台の再起動)を含むので、
    /// ワーカー構築後の判定(rejectIfDeviceLeased)だけだと、2本目が1本目の台を消去・再起動してから断る。
    /// 引けない台(停止中のエミュレータ・一覧に無いシミュレータ)は飛ばす —— 生きた run はそこを掴めない。
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

    /// **機械分担の run がリモートへ配る前に**、手元の子と同じ規則(この機械の台へ絞る →
    /// 本数+予備で絞る(MCP の台を避ける)→ lease 照合)で二重使用を断る(台+保持者 pid を名指しして throw)。
    /// 手元の子の拒否より先にリモートの子がロックを取り、断られた run の半分が走って同時刻の
    /// 別 run のリモート分を丸ごと弾いていた(2026-09-17 負荷テスト M12)。
    /// 判定材料が揃わない(プロファイル解決の失敗等)ときは何もしない = 手元の子の判定に任せる。
    /// DeviceMachineRunner と ApiRunMachineFanout の2経路から呼ぶ
    static func rejectIfLocalDevicesLeasedBeforeDispatch(
        project: TestProject, profileName: String, setOverrides: [String: RunProfileSetValue],
        localDeviceNames: [String], localScenarios: [ScenarioInfo], broadcast: Bool,
        leaseStateDir: URL? = (try? RepoRoot.find())?.appendingPathComponent(".fleetest")
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
        do {
            try rejectIfDevicesLeasedBeforePreparation(resolved: resolved, leaseStateDir: leaseStateDir)
        } catch {
            throw ProfileWorkerFactory.InstallError(message: error.localizedDescription
                + " Nothing was dispatched to the other machines of this profile.")
        }
    }

    /// 台 → lease キー(Android = serial / iOS = udid。RunWorker の `serial ?? udid` と同じ値)。
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

    /// **回す本数に絞るとき、MCP(fleetest-mcp)が操作している台を避ける**(ユーザー決定「避けて、
    /// 足りなければ警告して使う」。予備にも残さない理由は `ResolvedProfile.limitingDevices(avoiding:)`)。
    /// それでも使う台は警告で名指しする(断らない = 新しい検知は警告から)。
    /// 印(`MCPDeviceLease`)が1つも無ければ台の実体を引かない(simctl/adb の往復を払わない)。
    /// 自分と親の pid が持つ印は数えない(MCP が起こした run が自分を「MCP が操作中」と言わない)。
    /// `trim: false`(--broadcast)は絞らず、使う台の警告だけ返す
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

    /// 台が足りず MCP の台を使うときの理由を事実で組み立てる(純粋関数)。
    /// `scenarios == 0` はレーン数を数で言えない(本数不明 = 絞りの計算に使わない)ときの
    /// 従来の言い方のまま。`scenarios > 0` は必要レーン数(本数+予備1台)と空き台数を数で言う
    static func shortageReason(needed: Int, scenarios: Int, free: Int) -> String {
        guard scenarios > 0 else { return "no other device was free" }
        func plural(_ n: Int, _ noun: String) -> String { "\(n) \(noun)\(n == 1 ? "" : "s")" }
        let freeClause = free == 1 ? "only 1 device was free" : "only \(free) devices were free"
        // **導出は成り立つときだけ書く**: `deviceKeepCount` は台数でクランプされる
        // (min(available, scenarios + 1))ので、本数より台が少ない run では
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
                    broadcast: Bool = false
    ) async throws -> (summary: RunSummary, fmSettings: FMSettingsRecord) {
        var items = rawItems
        let runClockStart = Date()
        // 1. プロファイル合成
        PhaseLog.mark("profile-runner-start")
        let resolvedAll = try ProfileResolver.resolve(
            project: project, runName: profileName,
            workspaceOverride: workspaceOverride, overrides: setOverrides)
        // ワークスペースは常に有効(既定 `<project.rootURL>/workspace`。docs/remote-runner.md §17・
        // 2026-08-18)なので毎回雛形作成(既に揃っていれば何もしない。WorkspaceScaffold の宣言)。
        // リモートディスパッチはこれとは別に、ミラー前のローカル側で同じ呼び出しを行う
        // (RemoteRunDispatcher.prepareWorkspace)。続けて appPath の原本を apps/ へ
        // ステージング(WorkspaceAppStaging)。**dest も原本も無ければここで throw する**
        // (原本のパスを名指しする。呼び出し側で握り潰さない)
        if let workspaceRoot = resolvedAll.workspaceRoot {
            let created = (try? WorkspaceScaffold.ensure(root: workspaceRoot)) ?? []
            if !created.isEmpty {
                ConsoleOut.out("→ Created workspace scaffold: " + created.map { "\($0)/" }.joined(separator: ", "))
            }
            let staged = try WorkspaceAppStaging.stageWorkspaceApps(resolvedAll)
            if !staged.isEmpty {
                ConsoleOut.out("→ Staged app package(s) into the workspace: " + staged.joined(separator: ", "))
            }
        }
        // --device / --device-machine(マシン別サブ実行が自分のぶんだけ回す)。**ホストで絞らないと
        // 別の機械の同名デバイスまで掴む**(filteringDevices の宣言)。0台になったら止める
        let full = resolvedAll.filteringDevices(names: deviceFilter, deviceMachine: deviceMachine)
        if full.devices.isEmpty {
            let scope = deviceFilter.isEmpty ? "--device-machine \(deviceMachine ?? "")"
                : "--device \(deviceFilter.joined(separator: ", "))"
                    + (deviceMachine.map { " --device-machine \($0)" } ?? "")
            throw ValidationError(
                "\(scope) matched no device in run profile \(profileName)"
                + " (available: \(resolvedAll.devices.map(\.name).joined(separator: ", ")))")
        }
        // **filteringDevices/limitingDevices/broadcast は FM 設定に触れない**ので、devices を
        // 絞る前のこの時点で計算して 0 件早期リターン・本編の両方で使う
        let fm = full.fm
        let fmSettings = Self.fmSettingsRecord(resolved: full)
        // OS 対象外(`@TestClass(platform:)` / `@Test(platform:)` がこの run に無い OS を指す)は
        // **キューへ入れる前に外す** —— 入れると RunOrchestrator の「担当ワーカーなし」に落ち、
        // 意図された対象外が失敗として数えられる(PlatformApplicability の宣言)。
        // 台数の見積り(この下)より前に行う: 外した分の台は用意しなくてよい
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
        // 全部が対象外ならデバイスを起こす意味がない(0 失敗で終える = 正しく緑)
        if items.isEmpty {
            return (RunSummary(total: 0, failed: 0, performanceMode: performanceMode,
                               fmSettings: fmSettings), fmSettings)
        }

        // **回す本数を超える台数を用意しない**(ResolvedProfile.limitingDevices の宣言参照)。
        // 本数はここで確定している(items は呼び出し側で解決済み)ので、ブリッジ供給・アプリ版チェック・
        // blank triage が丸ごと縮む。platform 未指定のシナリオは**両方**に数える(どちらでも走りうる)。
        // **--broadcast は絞らない** —— 各台で1回ずつ走らせるのが目的なので、絞ると回るべき台が落ちる
        let leaseStateDir = (try? RepoRoot.find())?.appendingPathComponent(".fleetest")
        let (resolved, mcpWarnings) = Self.limitingDevicesAvoidingMCP(
            full, iosScenarios: items.filter { $0.info.platform != "android" }.count,
            androidScenarios: items.filter { $0.info.platform != "ios" }.count,
            trim: !broadcast, leaseStateDir: leaseStateDir)
        if broadcast {
            ConsoleOut.out("→ Broadcasting \(items.count) scenario(s) to each of \(full.devices.count) device(s)"
                + " (--broadcast)")
        } else if resolved.devices.count < full.devices.count {
            ConsoleOut.out("→ Using \(resolved.devices.count) of \(full.devices.count) device(s)"
                + " for \(items.count) scenario(s)")
        }
        for warning in resolved.warnings + mcpWarnings { ConsoleOut.out("⚠️ \(warning)") }

        // 開始スクリプト(docs/remote-runner.md §17)。**デバイスに触る前**に撃つ ——
        // 依存サービスが上がっていない状態でシミュレータを起こしてアプリを入れても、
        // 全シナリオが「アプリの不具合」の顔で落ちるだけ。渡すのは絞り込み後の resolved
        // (スクリプトが受け取るデバイス一覧を、この run が実際に使う台と一致させる)。
        // 終了スクリプトは defer で必ず撃つ(途中の throw・シナリオの失敗のいずれでも)。
        // プロセスごと殺された場合は lease が残り、次の run と `fleetest hooks reap` が代わりに撃つ
        let hookStateDir = (try? RepoRoot.find())?.appendingPathComponent(".fleetest")
        // 二重使用は開始スクリプトと破壊的な準備より前に断る(rejectIfDevicesLeasedBeforePreparation)
        try Self.rejectIfDevicesLeasedBeforePreparation(resolved: resolved, leaseStateDir: hookStateDir)
        let hookSession = try RunHookRunner.begin(
            resolved: resolved, stateDir: hookStateDir) { ConsoleOut.out($0) }
        defer { RunHookRunner.end(hookSession) { ConsoleOut.out($0) } }


        // fm は上(full 確定直後)で計算済み。filteringDevices/limitingDevices/broadcast は
        // devices だけを変えるので resolved.fm も同じ値のまま(再計算しない)
        await Self.warnIfFMDegraded(fm: fm) { ConsoleOut.out($0) }
        let reportDir = reportDirOverride.map { URL(fileURLWithPath: $0) } ?? resolved.reportDir
        RunEnvironment.apply(resolved)
        let deviceList = resolved.devices
            .map { "\($0.name)(\($0.platform))" }.joined(separator: ", ")
        ConsoleOut.out("🧩 Profile \(profileName): \(resolved.appName)")
        ConsoleOut.out("   Devices: \(deviceList)")

        // 1.5. Android AVD 肥大化チェック(超過分は Wipe Data。buildWorkers 前に実行)
        var wipedAndroid: [String] = []
        if resolved.wipeDataOnBloat {
            wipedAndroid = await AndroidDataWiper.wipeBloatedAVDs(
                devices: resolved.androidDevices, thresholdGB: resolved.wipeDataThresholdGB,
                locale: resolved.locale) { ConsoleOut.out($0) }
        }

        // 2. Android ワーカー構築(serial 照合=数秒)→ 白化の修復/除外 → 自動インストール。
        // iOS(ブリッジ供給=壊れたブリッジの置き換えで数十秒かかりうる)は lateWorkers として
        // 分離し、Android を供給完了待ちにしない(ApiRunCommand の並列経路と同じ方針)。
        let repoRoot = try RepoRoot.find()
        await BackendHealthCheck.warnIfUnreachable(resolved: resolved) { ConsoleOut.out($0) }
        // GPU 復帰は buildAndroidWorkers より前(emulator プロセスを入れ替えるため serial が
        // 変わりうる。Wipe Data と同じ理由・同じ位置)
        if resolved.recoverCpuFallbackToGpu {
            _ = await AndroidGpuRecovery.recoverCpuFallbackDevices(
                devices: resolved.androidDevices, locale: resolved.locale) { ConsoleOut.out($0) }
        }
        // 死んだレーンの復活(両モード共通)。buildAndroidWorkers の直前(GPU 復帰の後)で
        // 起動していない仮想デバイスを先に起こす。復活できなかった場合の扱いは
        // performanceMode の有無で分岐する(このあとの LaneGate 判定)
        if let running = try? AndroidDeviceCatalog.runningAVDs() {
            let laneTargets = AndroidLaneRecovery.plan(
                devices: resolved.androidDevices, runningAVDIDs: Set(running.values))
            if !laneTargets.isEmpty {
                let outcome = await AndroidLaneRecovery.bootMissingDevices(
                    devices: laneTargets.map(\.device), locale: resolved.locale) { ConsoleOut.out($0) }
                // 起こせた分は、ブリッジが定着するまで待ってから先へ進む(理由は
                // awaitDurableAndroidBridges の宣言)
                await ProfileWorkerFactory.awaitDurableAndroidBridges(
                    devices: laneTargets.map(\.device)
                        .filter { outcome.booted.contains($0.name) }) { ConsoleOut.out($0) }
            }
        }
        // run-lease(.fleetest/run-<key>.lease)は上で求めた leaseStateDir へ。best-effort: リポジトリ外
        // 実行等で root が取れない場合は書かない(monitor 側の inRun 判定が false になるだけで安全)
        // 供給フェーズ(install・凍結triage)の間も lease を保つ。RunOrchestrator の lease は
        // シナリオ実行中しか書かれず、その手前に start-device が割り込む穴が空くため
        let supplyLease = leaseStateDir.map { SupplyLeaseHolder(stateDir: $0) }
        defer { supplyLease?.release() }

        await ProfileWorkerFactory.preparePhysicalAndroidDevices(resolved: resolved) { ConsoleOut.out($0) }
        // 供給(buildAndroidWorkers。Wipe Data・古いブリッジ停止等の破壊的操作を含みうる)より前に、
        // その時点で解決できる台(既に起動している AVD・接続済みの実機)の lease を先に持つ
        // (reject→hold の順は崩さない。狙いは lease を前倒しすることだけで、供給自体は前倒ししない)
        let plannedAndroidKeys = Self.leaseKeysByDevice(resolved: resolved)
            .filter { $0.device.platform == "android" }
            .map { (device: $0.device.name, key: $0.key) }
        try Self.rejectIfDeviceLeased(devices: plannedAndroidKeys, leaseStateDir: leaseStateDir)
        supplyLease?.hold(keys: plannedAndroidKeys.map(\.key))
        var workers = try ProfileWorkerFactory.buildAndroidWorkers(resolved: resolved) { ConsoleOut.out($0) }
        // 供給前に解決できなかった台(起動直後に serial が決まる AVD 等)も同じ規律で確保する ——
        // 供給フェーズが自分の lease を書き始める前に、生きた別プロセスが同じ台を
        // 既に使っていないか確かめる(拒否して止める)
        try Self.rejectIfDeviceLeased(workers: workers, leaseStateDir: leaseStateDir)
        let builtAndroidKeys = workers.compactMap { $0.connection.serial ?? $0.connection.udid }
        supplyLease?.hold(keys: builtAndroidKeys)
        // 予定したが実際には建たなかった台(供給失敗でレーンから外れた)の lease は取り消す
        let builtAndroidKeySet = Set(builtAndroidKeys)
        supplyLease?.releaseKeys(plannedAndroidKeys.map(\.key).filter { !builtAndroidKeySet.contains($0) })
        let androidSerials = workers.compactMap { $0.connection.serial }
        // **テスト開始時に WebView を揃える**(既定 ON。AndroidWebViewUpdate の宣言参照)
        if resolved.updateWebView, let adbPath = try? AndroidDriver.findADB() {
            AndroidWebViewUpdate.run(
                targets: androidSerials,
                allSerials: (try? AndroidDeviceCatalog.connectedSerials()) ?? androidSerials,
                adb: { args in try? Shell.run([adbPath] + args, timeout: 600).output },
                log: { ConsoleOut.out($0) })
        }
        // **揃わなかった場合は混在を言う**(落とさない。AndroidWebViewVersions の宣言参照)
        warnIfWebViewVersionsDiffer(serials: androidSerials) { ConsoleOut.out($0) }
        let beforeBlankCheck = workers.count
        let triage = await ProfileWorkerFactory.excludeOrRepairBlankScreenWorkers(
                workers, stateDir: (try? RepoRoot.find())?.appendingPathComponent(".fleetest")) { ConsoleOut.out($0) }
        workers = triage.workers
        if workers.isEmpty && beforeBlankCheck > 0 {
            throw ProfileWorkerFactory.InstallError(
                message: "no usable devices (every Android device went blank)")
        }
        workers = try await ProfileWorkerFactory.installIfNeeded(
            apps: resolved.apps, workers: workers,
            forceAndroidInstall: !wipedAndroid.isEmpty) { ConsoleOut.out($0) }
        // 一斉 launch 直後の黒画面を作らないための予防(ProfileWorkerFactory.pressHomeOnStart)
        await ProfileWorkerFactory.prepareDevicesOnStart(
            workers, homeOnStart: resolved.homeOnStart) { ConsoleOut.out($0) }
        let iosDevicesExist = !resolved.iosDevices.isEmpty
        // buildIOSLane(eager / lateWorkers のどちらから呼ばれても)が回復させた iOS の label を
        // ここへ運ぶ(F10)。android 分の `triage.repaired` とはここで合流させる
        let iosBlankRepairBox = IOSBlankRepairBox()

        // performanceMode では iOS の late join をやめて開始前に建てる。**理由は計測の歪みではなく
        // ゲートの可視性** —— late join だと iOS ワーカーは run 開始後に建つので、「iOS のレーンが
        // 足りない」を開始前に検出できず、モードの約束(足りなければ開始しない)が iOS だけ守れない。
        // 計測そのものは late join でも歪まない(provider は全機をまとめて返すのでレーンは 0→N と
        // 一段で増え、シナリオはそれまで走らない)。Android が先行する混在プロファイルだけは
        // 歪むが、そこは計測対象外(両OSを1プロファイルにまとめない方針)。
        // buildIOSLane は lateWorkers provider と同じ関数(2つ目の実装を書かない)
        var eagerIOSWorkers: [RunWorker] = []
        if performanceMode, iosDevicesExist {
            eagerIOSWorkers = await buildIOSLane(
                resolved: resolved, repoRoot: repoRoot, supplyLease: supplyLease,
                blankRepairBox: iosBlankRepairBox)
            ConsoleOut.out("🚀 \(eagerIOSWorkers.count) iOS worker(s) joined")
        }
        let hasLateIOS = iosDevicesExist && !performanceMode

        // performanceMode: 復活できなかったレーンがあれば run を開始せずに失敗する
        // (既定 false ではここへ来ない=切り離して完走を優先する従来どおりの挙動)
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
        // 長いシナリオを先に流すと末尾の遊休が減る(実績は platform 別。--no-lpt で従来の ID 順)
        items = LPTOrdering.apply(items, project: project, defaultPlatform: defaultPlatform,
                                  enabled: lpt, historyRuns: lptHistoryRuns, log: { ConsoleOut.out($0) })
        // ApiRunCommand.run と同じ関数(RunStartLine)で組み立てる(CLAUDE.md「2 実装の差」対策)
        ConsoleOut.out(RunStartLine.text(
            androidWorkers: workers.count, eagerIOSWorkers: eagerIOSWorkers.count, hasLateIOS: hasLateIOS)
            + "\n")

        // record:true のときだけ VideoRecordingConfig を注入(runDir が無ければ録画自体しない)
        let recordingConfig: VideoRecordingConfig? = {
            guard resolved.record, let recorder else { return nil }
            return VideoRecordingConfig(
                runDir: recorder.runDir, androidADBPath: try? AndroidDriver.findADB(),
                failuresOnly: resolved.recordFailuresOnly, bitrateKbps: resolved.recordBitrateKbps,
                fullResolution: resolved.recordFullResolution)
        }()

        // SIGINT/SIGTERM を受けたら、新しいシナリオを配らず・今動いている子(fleetest-scenarios)
        // を SIGTERM してから RunOrchestrator.run() の通常の完了経路(録画停止・lease 解放・
        // drain・summary)を通す(ApiRunCommand.runWithProfileParallel と同じ形。CLAUDE.md
        // 「終了猶予の方針」= 自前の後始末を持つ fleetest の子には時限の SIGKILL を送らない)
        let interruptState = RunInterruptState(recorder: recorder)

        // 死んだ pid の控えを回収してから始める(SIGKILL で removeRunProgress に届かなかったぶん。
        // docs/design.md §18.1 —— 掃除は書き手側に置く)
        RunProgressLedger.sweep(directory: RunProgressLedger.directory())

        let orchestrator = RunOrchestrator(
            project: project, workers: workers + eagerIOSWorkers,
            settings: ScenarioExecutionSettings(resolved),
            reportDir: reportDir, recorder: recorder,
            recordingConfig: recordingConfig,
            isDeviceFrozen: { serial in
                // 事後判定は isBlankObserved(窓内に一度でも blank)。isPersistentlyBlank だと
                // 約25秒周期のフラッピングの回復側を引いて凍結を見逃す(実測 2026-07-18)。
                // 凍結確定時はその場で sleep/wake 修復も試みる(判定・振り直しは従来どおり)
                await AndroidHealthProbe.observeBlankAndRepair(serial: serial) { ConsoleOut.out($0) }
            },
            isDeviceUnreachable: { serial in
                // adb で state=device の一覧に居なければ消失(offline/未検出)。取得失敗時は誤って
                // 振り直さないよう false(reachable 扱い)に倒す。
                guard let serials = try? AndroidDeviceCatalog.connectedSerials() else { return false }
                return !serials.contains(serial)
            },
            bridgeLogSize: { worker in
                // xcuitest ランナーのログのみ有効(hybrid は xcuiPort 側。in-app はホスト側ログが
                // AX 処理で成長しないため nil を返して /status のみの判定にフォールバックさせる)
                guard let port = worker.connection.xcuiPort
                    ?? ((worker.connection.engine == nil || worker.connection.engine == "xcuitest")
                        ? worker.connection.port : nil) else { return nil }
                let attrs = try? FileManager.default.attributesOfItem(
                    atPath: repoRoot.appendingPathComponent(".fleetest/bridge-\(port).log").path)
                return (attrs?[.size] as? NSNumber)?.uint64Value
            },
            runnerProcessAlive: { worker in
                // xcuitest ランナー(ホスト側の xcodebuild)の生死。**nil = 分からない**
                // (in-app ブリッジは台帳に pid を持たない)。BridgeLiveness.decide の材料で、
                // 「生きている間はログ静止の近道を使わない/消えていれば窓の残りを待たない」を分ける
                guard let port = worker.connection.xcuiPort
                    ?? ((worker.connection.engine == nil || worker.connection.engine == "xcuitest")
                        ? worker.connection.port : nil) else { return nil }
                let pidPath = repoRoot.appendingPathComponent(".fleetest/bridge-\(port).pid").path
                guard let text = try? String(contentsOfFile: pidPath, encoding: .utf8),
                      let pid = Int32(text.trimmingCharacters(in: .whitespacesAndNewlines)) else { return nil }
                return ProcessLiveness.isAlive(pid)
            },
            probeBridge: { worker in
                // hybrid の主ポート(in-app)は別アプリのシナリオ中サスペンドされ TCP 受理・HTTP
                // 無応答になる(design §8.8)ため、死活確認は suspend されない xcuitest 側で行う
                guard let port = worker.connection.xcuiPort ?? worker.connection.port else {
                    return .silent
                }
                do {
                    // 実機ブリッジは 127.0.0.1 に居ない。宛先は DriverConnection 経由で届く
                    // (取り違えると失敗のたびに健全な実機ワーカーを「接続不能」で離脱させる)。
                    // physicalUDID も渡す —— usb トンネルは host がループバックのままでも
                    // token を要求するため、host だけでは実機の判別に使えない
                    // (ProfileWorkerFactory.warnOnResidualSystemAlerts と同じ規律)
                    let status = try await BridgeClient(
                        port: port,
                        host: worker.connection.host ?? BridgeEndpoint.loopbackHost,
                        physicalUDID: worker.connection.physical ? worker.connection.udid : nil)
                        .status(timeout: 5)
                    // 答えたのが別の台のブリッジなら接続不能と同じ扱い(BridgeProbeOutcome.hijacked)
                    if case .mismatch(let detail) = BridgeIdentityCheck.verdict(
                        expected: BridgeIdentityCheck.expected(for: worker.connection, probedPort: port),
                        status: status) {
                        return .hijacked(detail: detail)
                    }
                    return .ok
                } catch DriverError.bridgeConnectionRefused {
                    return .refused
                } catch {
                    return .silent
                }
            },
            writeRunLease: { key in
                guard let leaseStateDir else { return }
                RunLease.write(stateDir: leaseStateDir, key: key, pid: ProcessInfo.processInfo.processIdentifier)
                // 書いた後に手放す(順序を逆にすると一瞬 lease が消える)。SupplyLeaseHolder 冒頭参照
                supplyLease?.handOff(key: key)
            },
            removeRunLease: { key in
                guard let leaseStateDir else { return }
                RunLease.remove(stateDir: leaseStateDir, key: key)
            },
            writeRecordingLease: { key in
                guard let leaseStateDir else { return }
                RecordingLease.write(stateDir: leaseStateDir, key: key,
                                     pid: ProcessInfo.processInfo.processIdentifier)
            },
            removeRecordingLease: { key in
                guard let leaseStateDir else { return }
                RecordingLease.remove(stateDir: leaseStateDir, key: key)
            },
            profile: profileName,
            writeRunProgress: { record in
                RunProgressLedger.write(record, directory: RunProgressLedger.directory())
            },
            removeRunProgress: {
                RunProgressLedger.remove(pid: ProcessInfo.processInfo.processIdentifier,
                                         directory: RunProgressLedger.directory())
            },
            cleanupRetiredWorker: { retired in
                // ウェッジした旧ブリッジ(/status 無応答)は provision の再利用スキャンに映らないまま
                // 生き残り、シミュレータを掴み続ける。離脱検知の時点で UDID 照合で明示停止する
                // (revive 内でなくここに置く理由: 復帰を試みない離脱でも必ず kill するため)
                guard let udid = retired.connection.udid else { return }  // udid は iOS のみ
                let stopped = BridgeLauncher.stopMatching(udid: udid, repoRoot: repoRoot)
                if !stopped.isEmpty {
                    ConsoleOut.out("🔧 Stopped stale bridges: port \(stopped.joined(separator: ", "))")
                }
            },
            reviveWorker: { retired in
                guard let name = retired.logicalName else { return nil }
                let deadline = Date().addingTimeInterval(REVIVE_TIMEOUT)
                while Date() < deadline {
                    if let w = await ProfileWorkerFactory.buildWorker(forLogicalName: name, resolved: resolved,
                                                                       repoRoot: repoRoot, log: { ConsoleOut.out($0) }) {
                        do {
                            let installed = try await ProfileWorkerFactory.installIfNeeded(
                                apps: resolved.apps, workers: [w], forceAndroidInstall: false) { ConsoleOut.out($0) }
                            return installed.first
                        } catch {
                            // install に失敗した個体を古いアプリのまま参加させない(F5)。
                            // この呼び出しでは復帰させない(呼び出し元が MAX_WORKER_REVIVES の
                            // 範囲で reviveWorker を再度呼ぶ)
                            ConsoleOut.out("❌ \(w.label): dropped out after an install failure — "
                                + error.localizedDescription)
                            return nil
                        }
                    }
                    try? await Task.sleep(nanoseconds: 5_000_000_000)
                }
                return nil
            },
            recheckRunner: { worker, maxStepSnapshotMs, log in
                await RunnerMidRunRecheck.recheck(worker: worker, maxStepSnapshotMs: maxStepSnapshotMs,
                                                  repoRoot: repoRoot, log: log)
            },
            lateWorkers: hasLateIOS ? (platforms: Set(["ios"]), provider: { @Sendable in
                let ws = await buildIOSLane(resolved: resolved, repoRoot: repoRoot, supplyLease: supplyLease,
                                            blankRepairBox: iosBlankRepairBox)
                ConsoleOut.out("🚀 \(ws.count) iOS worker(s) joined")
                return ws
            }) : nil,
            installHandler: InstallHandlerFactory.make(apps: resolved.apps),
            appName: resolved.appName,
            appBundleIDs: resolved.apps.mapValues(\.bundleID),
            appTargets: resolved.apps,
            registerChildProcess: { interruptState.registerChildProcess($0) })
        let interruptRelay = InterruptRelay.observing {
            interruptState.requestStop()
            orchestrator.requestInterrupt()
        }
        defer { interruptRelay.stop() }
        PhaseLog.mark("orchestrator-setup")
        // レーン = 絞り込み後の全デバイス(供給に失敗して参加しなかった台のぶんは、orchestrator が
        // 「never joined」でそのレーンの本数を失敗として残す = 準備できなかった台が緑に紛れない)
        let dispatch: ScenarioDispatch = broadcast
            ? .broadcast(lanes: resolved.devices.map { BroadcastLane(key: $0.name, platform: $0.platform) })
            : .shared
        let itemsToRun = items  // async let は var を直接捕捉できない(Sendable 境界)
        async let summary = orchestrator.run(items: itemsToRun, defaultPlatform: defaultPlatform,
                                             dispatch: dispatch)

        // シナリオ毎にバッファして完了時に一括表示(並列時のステップ行の混線防止)。
        // quiet: 成功シナリオは結果1行のみ・失敗シナリオはバッファ全体(失敗詳細)を出す
        var buffers: [URL: [String]] = [:]
        var names: [URL: String] = [:]
        var timing = ScenarioTimingTracker()
        for await event in orchestrator.events {
            timing.record(event)
            let lines = RunLogFormatter.lines(for: event)
            switch event {
            case .flowStarted(_, let url, let flowName, _):
                names[url] = flowName
                buffers[url, default: []].append(contentsOf: lines)
            case .step(_, let url, _), .flowHealed(_, let url), .flowRequeued(_, let url, _, _, _):
                buffers[url, default: []].append(contentsOf: lines)
            case .flowFinished(_, let url, let passed, _, _):
                let all = (buffers.removeValue(forKey: url) ?? []) + lines
                if quiet {
                    ConsoleOut.out(passed ? "✅ \(names[url] ?? url.lastPathComponent)"
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
        let validity = MeasurementValidity.verdict(
            performanceMode: performanceMode,
            degradedWorkers: finalSummary.degradedWorkers, blankExclusions: triage.excluded)
        if validity.invalid {
            ConsoleOut.out("⏱️❌ Measurement invalid: this run's timing cannot be used for performance"
                + " comparisons (\(validity.reasons.joined(separator: "; ")))")
        }
        // run 前の blank triage(orchestrator は関与しない)を summary に載せ替えて返す
        // (RunScenarios が recorder.finish で run.json に記録する)
        let resultSummary = RunSummary(total: finalSummary.total, failed: finalSummary.failed,
                                       degradedWorkers: finalSummary.degradedWorkers,
                                 freezeRetries: finalSummary.freezeRetries,
                                 blankRepairs: triage.repaired + iosBlankRepairBox.get(),
                                 blankExclusions: triage.excluded,
                                 measurementInvalid: validity.invalid,
                                 measurementInvalidReasons: validity.reasons,
                                 fmUnavailableScenarios: finalSummary.fmUnavailableScenarios,
                                 workerAnomalies: finalSummary.workerAnomalies,
                                 performanceMode: performanceMode,
                                 fmSettings: fmSettings,
                                 interrupted: finalSummary.interrupted)
        return (resultSummary, fmSettings)
    }

    /// FM を使う run の開始前に、FM が**本当に呼べるか**を確かめて警告する。
    ///
    /// **その経路を使う機能が有効な run でだけ言う** —— run の中で FM を使うのは vision 経路だけ
    /// (occlusion-guard = exist の既定 requireVisible・screenLooksLike)。**text 経路は run の中で
    /// 使わない**ので、その死は言わない(失われる機能が無いのに「無効」と言わない)。availability は嘘をつく
    /// (available のまま実呼び出しが全滅する実測 2026-07-22)ので、台帳(FMLiveness)の実観測を使う。
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
        // (0.7〜4.7 秒・FMLock を取る)ので、結果を捨てる run で払わない
        let usesVision = fm.textVisualCheck || fm.screenLooksLike
        guard fm.enabled, usesVision else { return }
        guard FMVisionSupport.isSupported else {
            log("⚠️ \(FMVisionSupport.requirement): occlusion-guard and screenLooksLike are disabled for this run")
            return
        }
        let reading = await readLiveness()
        if let vision = reading.vision, vision.state == .dead {
            log("⚠️ FM is dead on this machine (vision path): the occlusion-guard"
                + " (the default requireVisible of exist) and screenLooksLike are disabled for this run"
                + " — a green result is not a guarded green." + reasonSuffix(vision))
        }
    }

    /// 死の理由を1行に畳む。**「いつ・何を根拠に」まで出す** —— 台帳は最大
    /// FMLiveness.freshSeconds ぶん古くなりうるので、断定の強さを読み手が測れるようにする
    private static func reasonSuffix(_ verdict: FMLiveness.Verdict) -> String {
        let age = Int(Date().timeIntervalSince1970 - verdict.checkedAt)
        return "\n   Observed \(age)s ago via \(verdict.source.rawValue)"
            + (verdict.error.map { ": \($0)" } ?? "")
    }

    /// buildIOSLane が回復させたワーカーの label を run() へ運ぶ入れ物
    /// (ApiRunCommand.BlankTriageBox と同じ受け渡しパターン)。eager 呼び出しと
    /// lateWorkers.provider 呼び出しはどちらか一方しか起きないが、後者は RunOrchestrator が
    /// 別 Task から呼ぶため、素の var の直接キャプチャは @Sendable 境界で弾かれる
    private final class IOSBlankRepairBox: @unchecked Sendable {
        private let lock = NSLock()
        private var labels: [String] = []
        func add(_ new: [String]) { lock.lock(); defer { lock.unlock() }; labels += new }
        func get() -> [String] { lock.lock(); defer { lock.unlock() }; return labels }
    }

    /// iOS レーンの構築(供給→インストール→凍結 triage→home)。**通常は `lateWorkers` provider
    /// として run 開始後に呼ばれる**(iOS のブリッジ供給は数十秒かかりうるため、Android の
    /// 開始をそれで待たせない)。`performanceMode` のときだけ run 開始前に同じ関数を呼ぶ
    /// (ゲートが iOS レーンの不足を開始前に見られるようにするため。呼び出し箇所のコメント参照。
    /// 2つ目の実装を書かない —— 通常経路と performanceMode 経路で処理が食い違うと、
    /// どちらか一方だけにバグが残る)。
    /// 供給失敗は run 全体を落とさない(iOS シナリオはワーカー不在ドレインで失敗確定させる。
    /// performanceMode では空配列が返ることで後段の LaneGate が run 開始前エラーへ格上げする)
    private static func buildIOSLane(
        resolved: ResolvedProfile, repoRoot: URL, supplyLease: SupplyLeaseHolder?,
        blankRepairBox: IOSBlankRepairBox
    ) async -> [RunWorker] {
        do {
            PhaseLog.mark("ios-workers-start")
            let leaseStateDir = repoRoot.appendingPathComponent(".fleetest")
            // 供給(buildIOSWorkers。シミュレータ起動+ブリッジ供給で数十秒〜数分かかりうる)より前に、
            // その時点で解決できる台(シミュレータ一覧から UDID が引ける・実機は spec の udid)の
            // lease を先に持つ(Android 経路のコメント参照。reject→hold の順は崩さない)。
            // 前倒ししないと供給中は run-lease が無く、`stop-device` に台を奪われて
            // ワーカーが離脱する(実測: シナリオが requeue された)
            let plannedIOSKeys = leaseKeysByDevice(resolved: resolved)
                .filter { $0.device.platform == "ios" }
                .map { (device: $0.device.name, key: $0.key) }
            try rejectIfDeviceLeased(devices: plannedIOSKeys, leaseStateDir: leaseStateDir)
            supplyLease?.hold(keys: plannedIOSKeys.map(\.key))
            var ws = try await ProfileWorkerFactory.buildIOSWorkers(
                resolved: resolved, repoRoot: repoRoot) { ConsoleOut.out($0) }
            PhaseLog.mark("ios-workers-built")
            // 同じ理由(Android 経路のコメント参照)。ここで throw すると呼び出し元の
            // do/catch が「❌ Failed to build iOS workers: …」として拒否理由(台+保持者 pid)を
            // そのまま出す(iOS 供給失敗は run 全体を落とさない既存の規律はそのまま=このレーンだけ空になる)
            try rejectIfDeviceLeased(workers: ws, leaseStateDir: leaseStateDir)
            let builtIOSKeys = ws.compactMap { $0.connection.serial ?? $0.connection.udid }
            supplyLease?.hold(keys: builtIOSKeys)
            // 予定したが実際には建たなかった台(供給失敗でレーンから外れた)の lease は取り消す
            let builtIOSKeySet = Set(builtIOSKeys)
            supplyLease?.releaseKeys(plannedIOSKeys.map(\.key).filter { !builtIOSKeySet.contains($0) })
            // install 全滅の throw は握りつぶさない(F5) —— `try?` で受けると失敗前(=古いアプリ
            // のまま)の ws へ静かに戻ってしまう。ここで投げれば下の catch が「レーンを空にする」
            // 既定の扱いに落とす
            ws = try await ProfileWorkerFactory.installIfNeeded(
                apps: resolved.apps, workers: ws, forceAndroidInstall: false) { ConsoleOut.out($0) }
            PhaseLog.mark("ios-workers-installed")
            // 画面だけ死んだシミュレータを**投入前に回復させる**(BlankWorkerTriage 参照)。
            // 回復は simctl shutdown→boot で、**ブリッジごと死ぬ**ので張り直しまでが1セット。
            // 張り直しは buildIOSWorkers を呼び直すだけでよい(生きているブリッジは
            // 再利用されるので、実際に建て直るのは落とした機だけ)。
            // レーンに凍結機を残さないための処理で、戻らなかった個体だけが除外される
            let recovered = await BlankWorkerTriage.excludeBlankScreenWorkers(
                ws,
                recover: { @Sendable frozen, currentWorkers in
                    await ProfileWorkerFactory.recoverFrozenIOSWorkers(
                        labels: frozen, workers: currentWorkers, resolved: resolved,
                        repoRoot: repoRoot, apps: resolved.apps) { ConsoleOut.out($0) }
                },
                stateDir: repoRoot.appendingPathComponent(".fleetest"),
                    nudge: { @Sendable [bundleID = ProfileWorkerFactory.iosBundleID(apps: resolved.apps)] in
                        await ProfileWorkerFactory.nudgeIOSScreen(worker: $0, restoring: bundleID) },
                log: { ConsoleOut.out($0) })
            // run.json の blankRepairs へ渡す(F10)。buildIOSLane は eager / lateWorkers.provider の
            // どちらから呼ばれても run() 側で読めるよう、箱経由で運ぶ(戻り値の型は変えない)
            blankRepairBox.add(recovered.repaired)
            ws = recovered.workers
            // 録画ありの run では、端末側に録画セッションが残った台を再起動して解く
            // (HostRecordingProbe。凍結の回復と同じくブリッジごと張り直す)
            ws = await ProfileWorkerFactory.recoverStaleRecordingIOSWorkers(
                workers: ws, resolved: resolved, repoRoot: repoRoot,
                apps: resolved.apps) { ConsoleOut.out($0) }
            await ProfileWorkerFactory.prepareDevicesOnStart(
                ws, homeOnStart: resolved.homeOnStart) { ConsoleOut.out($0) }
            return ws
        } catch {
            // iOS 供給失敗は run 全体を落とさない(iOS シナリオはワーカー不在ドレインで失敗確定)
            ConsoleOut.out("❌ Failed to build iOS workers: \(error.localizedDescription)")
            return []
        }
    }

}

/// フリートの WebView 版を集めて混在を警告する。**adb を端末数だけ叩く**が
/// 1台あたり1回・数十msなので run 前の固定費として許容範囲
/// (取れない端末は黙って飛ばす = 判定材料が無いだけで異常ではない)
private func warnIfWebViewVersionsDiffer(serials: [String], log: (String) -> Void) {
    guard serials.count > 1 else { return }
    let versions = AndroidWebViewVersions.collect(serials: serials) { serial, args in
        guard let adb = try? AndroidDriver.findADB() else { return nil }
        return try? Shell.run([adb, "-s", serial] + args, timeout: 10).output
    }
    if let warning = AndroidWebViewVersions.mixedVersionWarning(versions) { log(warning) }
}
