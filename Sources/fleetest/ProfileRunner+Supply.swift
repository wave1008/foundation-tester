import ArgumentParser
import Foundation
import FTAndroid
import FTBridgeClient
import FTCore

// `fleetest run --profile` の準備の段(プロファイル解決 → 台数の絞り込み → 二重使用の確認 → サービス → 開始スクリプト →
// 供給のタスクを起こす)。ビルドが要る回は呼び手(Fleetest.swift の run)がビルドの**前**にこれを呼び、供給をビルドと
// 並行に進める(`api run` と同じ形)。台数はそのとき分かっている本数(`--scenario` の明示だけ)で絞る。
// ビルドが要らない回は `ProfileRunner.run` が一覧の後に自分で呼ぶ(正確な本数で絞れる)。
extension ProfileRunner {
    /// 準備の段の結果。**`close()` を必ず呼ぶ**(サービス・開始スクリプト・計測中のモニター停止・アニメーション設定・
    /// 供給の lease の片付け。順序はここが持つ)。供給のタスクは起動済み(結果は実行の段が受け取る)
    /// 準備の段で作ったものの片付け(**各片付けはここに1か所だけ**。準備の途中で throw したときも、
    /// 準備を終えて `PreparedSupply.close()` が呼ばれたときも、これを通す)。
    /// 作った順の逆に片付ける(供給の lease → 終了スクリプト → サービス → アニメーション設定 → モニター停止の解除)。
    /// 終了スクリプトはサービスより先(スクリプトがサービスを使って後片付けする)
    final class SupplyCleanup {
        var responseMonitorHold: ResponseMeasurementMonitorHold.Handle?
        var animationRestores: [ProfileWorkerFactory.AnimationRestore] = []
        var servicesSession: ServicesSession?
        var hookSession: RunHookSession?
        var supplyLease: SupplyLeaseHolder?
        private var done = false

        func run() {
            guard !done else { return }
            done = true
            supplyLease?.release()
            if let hookSession { RunHookRunner.end(hookSession) { ConsoleOut.out($0) } }
            servicesSession?.down { ConsoleOut.out($0) }
            ProfileWorkerFactory.restoreAnimations(animationRestores) { ConsoleOut.out($0) }
            ResponseMeasurementMonitorHold.release(responseMonitorHold) { ConsoleOut.out($0) }
        }
    }

    /// 準備の段の結果。**`close()` を必ず呼ぶ**(片付けは `SupplyCleanup`)。供給のタスクは起動済み
    /// (結果は実行の段が受け取る)
    final class PreparedSupply {
        let full: ResolvedProfile
        let resolved: ResolvedProfile
        let reportDir: URL
        let leaseStateDir: URL?
        let repoRoot: URL
        let supplyLease: SupplyLeaseHolder?
        let triageBox: BlankTriageBox
        let servicesSession: ServicesSession?
        let androidTask: Task<[RunWorker], Error>
        let iosTask: Task<[RunWorker], Never>?
        private let cleanup: SupplyCleanup

        init(full: ResolvedProfile, resolved: ResolvedProfile, reportDir: URL, leaseStateDir: URL?, repoRoot: URL,
             triageBox: BlankTriageBox, androidTask: Task<[RunWorker], Error>, iosTask: Task<[RunWorker], Never>?,
             cleanup: SupplyCleanup) {
            self.full = full
            self.resolved = resolved
            self.reportDir = reportDir
            self.leaseStateDir = leaseStateDir
            self.repoRoot = repoRoot
            self.supplyLease = cleanup.supplyLease
            self.triageBox = triageBox
            self.servicesSession = cleanup.servicesSession
            self.androidTask = androidTask
            self.iosTask = iosTask
            self.cleanup = cleanup
        }

        func close() { cleanup.run() }

        /// 供給のタスクが終わるまで待つ(結果は捨てる)。**失敗で抜ける経路は、これを待ってから `close()` する** ——
        /// 待たないと、走っている iOS の準備の横で終了スクリプト・サービスの停止・準備中の印の解除が走る
        func settle() async {
            _ = try? await androidTask.value
            _ = await iosTask?.value
        }
    }

    /// `fleetest run` がビルドの前に起こした準備の段の持ち場。`defer` の中では待てないので、本体の外側
    /// (`RunScenarios.run()`)がどの経路で抜けても `settleAndClose()` を1回通す
    final class EarlySupplyBox {
        var supply: PreparedSupply?

        func settleAndClose() async {
            guard let supply else { return }
            await supply.settle()
            supply.close()
        }
    }

    /// プロファイルを解決し、ワークスペースを用意して `--device` / `--device-machine` で絞る(0台なら止める)
    static func resolveFullProfile(project: TestProject, profileName: String,
                                   setOverrides: [String: RunProfileSetValue], workspaceOverride: String?,
                                   deviceFilter: [String], deviceMachine: String?,
                                   broadcast: Bool) throws -> ResolvedProfile {
        let resolvedAll = try ProfileResolver.resolve(
            project: project, runName: profileName,
            workspaceOverride: workspaceOverride, overrides: setOverrides)
        if broadcast, resolvedAll.responseMeasurement {
            throw ValidationError(ResponseMeasurementPolicy.combinationRejection(flag: "--broadcast"))
        }
        // ワークスペースは常に有効(既定 `<project.rootURL>/workspace`。docs/remote-runner.md §17)
        // なので毎回雛形作成(既に揃っていれば何もしない。WorkspaceScaffold の宣言)。
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
        return full
    }

    /// 準備の段。`iosScenarios` / `androidScenarios` は台数の見積りに使う本数(0 = 絞らない)、
    /// `scenarioCount` は表示用(分からなければ nil)。`failureLogDir` = 開始スクリプトが落ちたときにサービスのログを残す場所
    /// (無ければレポートの出力先)
    static func prepareSupply(
        full: ResolvedProfile, profileName: String, iosScenarios: Int, androidScenarios: Int,
        scenarioCount: Int?, broadcast: Bool, reportDirOverride: String?, failureLogDir: URL?,
        supplyProgress: RunSupplyProgress, interruptState: RunInterruptState
    ) async throws -> PreparedSupply {
        // **回す本数を超える台数を用意しない**(ResolvedProfile.limitingDevices の宣言参照)。
        // ブリッジ供給・アプリ版チェック・blank triage が丸ごと縮む。
        // **--broadcast は絞らない** —— 各デバイスで1回ずつ走らせるのが目的なので、絞ると回るべきデバイスが落ちる
        let leaseStateDir = (try? RepoRoot.find())?.appendingPathComponent(".fleetest")
        let (resolved, mcpWarnings) = Self.limitingDevicesAvoidingMCP(
            full, iosScenarios: iosScenarios, androidScenarios: androidScenarios,
            trim: !broadcast, leaseStateDir: leaseStateDir)
        let forCount = scenarioCount.map { " for \($0) scenario(s)" } ?? ""
        if broadcast {
            ConsoleOut.out("→ Broadcasting \(scenarioCount.map { "\($0) scenario(s)" } ?? "the scenarios")"
                + " to each of \(full.devices.count) device(s) (--broadcast)")
        } else if resolved.devices.count < full.devices.count {
            ConsoleOut.out("→ Using \(resolved.devices.count) of \(full.devices.count) device(s)" + forCount)
        }
        for warning in resolved.warnings + mcpWarnings { ConsoleOut.out("⚠️ \(warning)") }

        // 開始スクリプト(docs/remote-runner.md §17)。**デバイスに触る前**に撃つ ——
        // 依存サービスが上がっていない状態でシミュレータを起こしてアプリを入れても、
        // 全シナリオが「アプリの不具合」の顔で落ちるだけ。渡すのは絞り込み後の resolved
        // (スクリプトが受け取るデバイス一覧を、この run が実際に使うデバイスと一致させる)。
        // 終了スクリプトは close() で撃つ。プロセスごと殺された場合は lease が残り、次の run と
        // `fleetest hooks reap` が代わりに撃つ
        let hookStateDir = (try? RepoRoot.find())?.appendingPathComponent(".fleetest")
        // 二重使用は開始スクリプトと破壊的な準備より前に断る(rejectIfDevicesLeasedBeforePreparation)
        try Self.rejectIfDevicesLeasedBeforePreparation(resolved: resolved, leaseStateDir: hookStateDir)
        let reportDir = reportDirOverride.map { URL(fileURLWithPath: $0) } ?? resolved.reportDir
        // 以下で作るものは cleanup に積む。途中で throw したら積んだ分だけ片付ける(作り終えたら PreparedSupply.close() が持つ)
        let cleanup = SupplyCleanup()
        var handedOver = false
        defer { if !handedOver { cleanup.run() } }
        // レスポンス計測中はモニターを止める(ApiRunCommand.run と同じ)
        cleanup.responseMonitorHold = resolved.responseMeasurement
            ? hookStateDir.flatMap { ResponseMeasurementMonitorHold.acquire(stateDir: $0) { ConsoleOut.out($0) } }
            : nil
        // 計測 run が書き換えた Android 実機のアニメーション設定を終了時に戻す。取得は開始時の同期(buildAndroidWorkers)より前
        cleanup.animationRestores = resolved.responseMeasurement
            ? ProfileWorkerFactory.captureAnimationRestore(resolved: resolved) : []
        // サービス(scripts/compose.yaml)は開始スクリプトの前に上げ、片付けは終了スクリプトの後
        let servicesSession = try ServicesSession.up(
            resolved: resolved, stateDir: hookStateDir, options: .forRun(resolved), interruptState: interruptState) { ConsoleOut.out($0) }
        cleanup.servicesSession = servicesSession
        do {
            cleanup.hookSession = try RunHookRunner.begin(
                resolved: resolved, stateDir: hookStateDir, services: servicesSession, interrupt: interruptState) { ConsoleOut.out($0) }
        } catch {
            // 失敗の証跡: run-setup.sh が落ちたとき、各サービスのログの末尾を run の記録(無ければレポートの出力先)へ残す
            servicesSession?.saveLogs(to: failureLogDir ?? reportDir) { ConsoleOut.out($0) }
            throw error
        }

        // fm は full から計算する(filteringDevices/limitingDevices/broadcast は devices だけを変える)
        await Self.warnIfFMDegraded(fm: full.fm) { ConsoleOut.out($0) }
        RunEnvironment.apply(resolved)
        let deviceList = resolved.devices
            .map { "\($0.name)(\($0.platform))" }.joined(separator: ", ")
        ConsoleOut.out("🧩 Profile \(profileName): \(resolved.appName)")
        ConsoleOut.out("   Devices: \(deviceList)")

        let repoRoot = try RepoRoot.find()
        await BackendHealthCheck.warnIfUnreachable(resolved: resolved) { ConsoleOut.out($0) }
        // 供給フェーズ(install・凍結triage)の間も run-lease を保つ。RunOrchestrator の lease は
        // シナリオ実行中しか書かれず、その手前に start-device が割り込む穴が空くため。best-effort: リポジトリ外
        // 実行等で root が取れない場合は書かない(monitor 側の inRun 判定が false になるだけで安全)
        let supplyLease = leaseStateDir.map { SupplyLeaseHolder(stateDir: $0) }
        cleanup.supplyLease = supplyLease
        // 両レーンの実行前 triage を run.json(blankRepairs/blankExclusions/workerAnomalies)へ運ぶ
        let triageBox = BlankTriageBox()
        // **供給のタスクを起こす前にも中断を見る**(まだ何も起こしていないので抜けられる)
        if interruptState.isStopped {
            throw RunInterruptedBeforeStartError(phase: "device supply")
        }
        // 2つのレーン(手順は ProfileSupplyLanes の1箇所)。Android(照合+インストール=数秒)と
        // iOS(ブリッジ供給=数十秒かかりうる)を別のタスクにし、互いを待たせない(api run と同じ形)
        let progress = supplyProgress.reporter
        let androidTask = Task {
            try await ProfileSupplyLanes.android(
                resolved: resolved, supplyLease: supplyLease, supplyStage: progress,
                triage: triageBox) { ConsoleOut.out($0) }
        }
        let iosTask: Task<[RunWorker], Never>? = resolved.iosDevices.isEmpty ? nil : Task {
            await ProfileSupplyLanes.ios(
                resolved: resolved, supplyLease: supplyLease, supplyStage: progress,
                triage: triageBox) { ConsoleOut.out($0) }
        }
        handedOver = true
        return PreparedSupply(
            full: full, resolved: resolved, reportDir: reportDir, leaseStateDir: leaseStateDir, repoRoot: repoRoot,
            triageBox: triageBox, androidTask: androidTask, iosTask: iosTask, cleanup: cleanup)
    }
}
