// ProfileSupplyLanes.swift
// --profile の run がデバイスを供給する手順(Android のレーン・iOS のレーン)の唯一の実装。
// `fleetest run`(ProfileRunner.run)と `fleetest api run`(並列経路・--debug/--dry-run の逐次経路)が
// 同じ関数を呼ぶ。**呼び手側に手順を書き足さない** —— 2経路に別々に持っていた間に、api run だけ
// WebView の更新・実機の画面の観測・Android のホームへ戻す処理が抜けていた。
// `ProfileSupplyLanesWiringTests` が、呼び手がここを通っていて手順を直接呼んでいないことを固定する

import Foundation
import FTAndroid
import FTBridgeClient
import FTCore

enum ProfileSupplyLanes {
    /// Android のレーン(Wipe Data → GPU 復帰 → 死んだレーンの起動 → 実機の準備 → 供給 → WebView →
    /// 凍結 triage → 実機の画面の観測 → インストール → ホーム)。**順序に意味がある**:
    /// Wipe Data と GPU 復帰は emulator を入れ替えて serial が変わりうるので供給より前、
    /// インストールはホームより前(ホームの後に入れると起動直後の画面が install で崩れる)。
    /// **凍結 triage で全台が除外されたら投げる**(ユーザー決定: 全滅は異常として run を止める)。
    /// 供給の前から Android デバイスが0台なら空で返す(iOS だけのプロファイル)
    /// - wipeStatus: Wipe Data の進行を NDJSON へ出す口(api run だけが渡す)
    static func android(
        resolved: ResolvedProfile, supplyLease: SupplyLeaseHolder?, supplyStage: SupplyStageReporter?,
        triage: BlankTriageBox, wipeStatus: (@Sendable (String, String) -> Void)? = nil,
        log: @escaping @Sendable (String) -> Void
    ) async throws -> [RunWorker] {
        let stateDir = (try? RepoRoot.find())?.appendingPathComponent(".fleetest")
        var wipedAndroid: [String] = []
        if resolved.wipeDataOnBloat {
            wipedAndroid = await AndroidDataWiper.wipeBloatedAVDs(
                devices: resolved.androidDevices, thresholdGB: resolved.wipeDataThresholdGB,
                locale: resolved.locale, status: wipeStatus, log: log)
        }
        if resolved.recoverCpuFallbackToGpu {
            _ = await AndroidGpuRecovery.recoverCpuFallbackDevices(
                devices: resolved.androidDevices, locale: resolved.locale, log: log)
        }
        // 死んだレーンの復活。復活できなかった場合の扱いは performanceMode の有無で分岐する(呼び手の LaneGate)
        if let running = try? AndroidDeviceCatalog.runningAVDs() {
            let laneTargets = AndroidLaneRecovery.plan(
                devices: resolved.androidDevices, runningAVDIDs: Set(running.values))
            if !laneTargets.isEmpty {
                let outcome = await AndroidLaneRecovery.bootMissingDevices(
                    devices: laneTargets.map(\.device), locale: resolved.locale,
                    supplyStage: supplyStage, log: log)
                // 起こせた分は、ブリッジが定着するまで待ってから先へ進む(awaitDurableAndroidBridges の宣言)
                await ProfileWorkerFactory.awaitDurableAndroidBridges(
                    devices: laneTargets.map(\.device).filter { outcome.booted.contains($0.name) }, log: log)
            }
        }
        await ProfileWorkerFactory.preparePhysicalAndroidDevices(resolved: resolved, log: log)
        // 供給(Wipe Data・古いブリッジ停止等の破壊的操作を含みうる)より前に lease を前倒しして持つ
        var workers = try await ProfileRunner.buildWorkersWithFrontLoadedLease(
            resolved: resolved, platforms: ["android"], leaseStateDir: stateDir, supplyLease: supplyLease
        ) { try ProfileWorkerFactory.buildAndroidWorkers(resolved: resolved, log: log) }
        let serials = workers.compactMap { $0.connection.serial }
        if resolved.updateWebView { updateWebViews(serials: serials, log: log) }
        // **揃わなかった場合は混在を言う**(落とさない。AndroidWebViewVersions の宣言参照)
        warnIfWebViewVersionsDiffer(serials: serials, log: log)
        let beforeBlankCheck = workers.count
        let blank = await ProfileWorkerFactory.excludeOrRepairBlankScreenWorkers(
            workers, stateDir: stateDir, log: log)
        triage.add(repaired: blank.repaired, excluded: blank.excluded, anomalies: blank.anomalies)
        workers = blank.workers
        // **実機は上の triage の対象外**(閾値がエミュレータ較正で、誤判定すると健全な実機へ `adb reboot` を撃つ)。
        // 観測と無害な修復(画面の sleep/wake)だけを通す
        await BlankWorkerTriage.observePhysicalScreens(
            workers, awake: PhysicalScreenProbes.awake, repair: PhysicalScreenProbes.cycleScreen, log: log)
        if workers.isEmpty && beforeBlankCheck > 0 {
            throw ProfileWorkerFactory.InstallError(
                message: "no usable devices (the pre-run check excluded every Android device — the reason for each is in the lines above)")
        }
        workers = try await ProfileWorkerFactory.installIfNeeded(
            apps: resolved.apps, workers: workers,
            forceAndroidInstall: !wipedAndroid.isEmpty, wipeOnInsufficientStorage: resolved.wipeDataOnBloat,
            locale: resolved.locale, supplyStage: supplyStage, log: log)
        // 一斉 launch 直後の黒画面を作らないための予防(ProfileWorkerFactory.pressHomeOnStart)
        await ProfileWorkerFactory.prepareDevicesOnStart(workers, homeOnStart: resolved.homeOnStart, log: log)
        return workers
    }

    /// **テスト開始時に WebView を揃える**(既定 ON。AndroidWebViewUpdate の宣言参照)。adb の出力を終了コードを見ずに
    /// 渡すのは意図(install の失敗文言がそのまま利用者への理由になる。ToolOutputStatusScanTests の免除)
    private static func updateWebViews(serials: [String], log: @escaping @Sendable (String) -> Void) {
        guard let adbPath = try? AndroidDriver.findADB() else { return }
        AndroidWebViewUpdate.run(
            targets: serials,
            allSerials: (try? AndroidDeviceCatalog.connectedSerials()) ?? serials,
            adb: { args in try? Shell.run([adbPath] + args, timeout: 600).output },
            log: log)
    }

    /// iOS のレーン(供給 → インストール → 凍結 triage → 残った録画セッションの解消 → ホーム)。
    /// **投げない** —— 失敗は空で返し、全滅の扱いは呼び手が決める(run の開始前なら投げる・遅延参加なら
    /// RunOrchestrator が配布を止める。`RunOrchestrator` の lateWorkers の宣言)。
    /// 通常は run の開始後に lateWorkers の provider として呼ばれる(iOS のブリッジ供給は数十秒かかりうるので、
    /// Android の開始をそれで待たせない)
    static func ios(
        resolved: ResolvedProfile, supplyLease: SupplyLeaseHolder?, supplyStage: SupplyStageReporter?,
        triage: BlankTriageBox, log: @escaping @Sendable (String) -> Void
    ) async -> [RunWorker] {
        do {
            PhaseLog.mark("ios-workers-start")
            let repoRoot = try RepoRoot.find()
            let stateDir = repoRoot.appendingPathComponent(".fleetest")
            // 供給(シミュレータ起動+ブリッジ供給で数十秒〜数分)より前に lease を前倒しして持つ。前倒ししないと
            // 供給中は run-lease が無く、`stop-device` にデバイスを奪われてワーカーが離脱する(実測: シナリオが requeue された)。
            // ここで投げると下の catch が拒否理由(デバイス+保持者 pid)をそのまま出す
            var ws = try await ProfileRunner.buildWorkersWithFrontLoadedLease(
                resolved: resolved, platforms: ["ios"], leaseStateDir: stateDir, supplyLease: supplyLease
            ) {
                let built = try await ProfileWorkerFactory.buildIOSWorkers(
                    resolved: resolved, repoRoot: repoRoot, supplyStage: supplyStage, log: log)
                PhaseLog.mark("ios-workers-built")
                return built
            }
            // install 全滅の throw は握りつぶさない —— `try?` で受けると失敗前(=古いアプリのまま)の ws へ
            // 静かに戻る。投げれば下の catch がレーンを空にする
            ws = try await ProfileWorkerFactory.installIfNeeded(
                apps: resolved.apps, workers: ws, forceAndroidInstall: false,
                wipeOnInsufficientStorage: resolved.wipeDataOnBloat, locale: resolved.locale,
                supplyStage: supplyStage, log: log)
            PhaseLog.mark("ios-workers-installed")
            // 画面だけ死んだシミュレータを投入前に回復させる(BlankWorkerTriage)。回復は simctl shutdown→boot で
            // ブリッジごと死ぬので、張り直し(buildIOSWorkers の呼び直し)までが1セット
            let recovered = await BlankWorkerTriage.excludeBlankScreenWorkers(
                ws,
                recover: { @Sendable frozen, currentWorkers in
                    await ProfileWorkerFactory.recoverFrozenIOSWorkers(
                        labels: frozen, workers: currentWorkers, resolved: resolved,
                        repoRoot: repoRoot, apps: resolved.apps, log: log)
                },
                // 判定をモニターへ配る(DeviceFrozenStore)。run が知っている凍結をモニターが知らない状態を作らない
                stateDir: stateDir,
                nudge: { @Sendable [bundleID = ProfileWorkerFactory.iosBundleID(apps: resolved.apps)] in
                    await ProfileWorkerFactory.nudgeIOSScreen(worker: $0, restoring: bundleID) },
                log: log)
            triage.add(repaired: recovered.repaired, excluded: recovered.excluded,
                       anomalies: WorkerAnomalyRecord.preRunTriage(
                           excluded: recovered.excludedWorkers, repaired: recovered.repairedWorkers))
            ws = recovered.workers
            // 録画ありの run では、端末側に録画セッションが残ったデバイスを再起動して解く(HostRecordingProbe)
            ws = await ProfileWorkerFactory.recoverStaleRecordingIOSWorkers(
                workers: ws, resolved: resolved, repoRoot: repoRoot, apps: resolved.apps, log: log)
            await ProfileWorkerFactory.prepareDevicesOnStart(ws, homeOnStart: resolved.homeOnStart, log: log)
            log("🚀 \(ws.count) iOS worker(s) joined")
            return ws
        } catch {
            log("❌ Failed to build iOS workers: \(error.localizedDescription)")
            return []
        }
    }
}

/// 両レーンの実行前 triage(blank の修復・除外・workerAnomalies)を run の記録へ運ぶ箱。
/// **Android と iOS のレーンが別々の Task から `add` で書く**(上書きだと後から書いた側だけが残る)
final class BlankTriageBox: @unchecked Sendable {
    private let lock = NSLock()
    private var repaired: [String] = []
    private var excluded: [String] = []
    private var anomalies: [WorkerAnomalyRecord] = []
    func add(repaired: [String], excluded: [String], anomalies new: [WorkerAnomalyRecord] = []) {
        lock.lock(); defer { lock.unlock() }
        self.repaired += repaired; self.excluded += excluded; self.anomalies += new
    }
    func get() -> (repaired: [String], excluded: [String]) {
        lock.lock(); defer { lock.unlock() }
        return (repaired, excluded)
    }
    func getAnomalies() -> [WorkerAnomalyRecord] { lock.lock(); defer { lock.unlock() }; return anomalies }
}

/// フリートの WebView 版を集めて混在を警告する。**adb を端末数だけ叩く**が1台あたり1回・数十msなので
/// run 前の固定費として許容範囲(取れない端末は黙って飛ばす = 判定材料が無いだけで異常ではない)
private func warnIfWebViewVersionsDiffer(serials: [String], log: (String) -> Void) {
    guard serials.count > 1 else { return }
    let versions = AndroidWebViewVersions.collect(serials: serials) { serial, args in
        guard let adb = try? AndroidDriver.findADB() else { return nil }
        return try? Shell.run([adb, "-s", serial] + args, timeout: AndroidDeviceCatalog.adbTimeoutSeconds).outputIfSucceeded
    }
    if let warning = AndroidWebViewVersions.mixedVersionWarning(versions) { log(warning) }
}
