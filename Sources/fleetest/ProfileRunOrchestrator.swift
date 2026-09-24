// ProfileRunOrchestrator.swift
// `fleetest run --profile`(ProfileRunner.run)と `fleetest api run`(ApiRunCommand.runWithProfileParallel)が
// RunOrchestrator へ渡す配線の唯一の定義元。2実装で違うのは引数で受ける値だけ:
// - log: run は stdout(ConsoleOut)・api run は stderr(stdout は NDJSON 専用)
// - onRevived: api run は復帰したワーカーを NDJSON の worker id 表へ登録する(ポートが変わると label も変わる)
// - lateWorkers: iOS の遅延参加の組み立て方(run はここで供給・api run は起動済みの Task を待つ)
// 走査テスト(RunProgressLedgerWiringTests / SupplyLeaseHandOffWiringTests / RunnerMidRunRecheckTests)は
// 配線をこのファイルで、2経路がここを1回ずつ通ることを呼び手で見る

import Foundation
import FTAndroid
import FTBridgeClient
import FTCore

enum ProfileRunOrchestrator {

    /// ワーカー復帰待ちの上限(秒)。監視側の再起動やデバイス自己回復を待ち、尽きたら復帰させない
    static let reviveTimeout: TimeInterval = 90

    /// record:true のときだけ録画の設定を渡す(runDir が無ければ録画自体しない)
    static func recordingConfig(resolved: ResolvedProfile, recorder: RunRecorder?) -> VideoRecordingConfig? {
        guard resolved.record, let recorder else { return nil }
        return VideoRecordingConfig(
            runDir: recorder.runDir, androidADBPath: try? AndroidDriver.findADB(),
            failuresOnly: resolved.recordFailuresOnly, bitrateKbps: resolved.recordBitrateKbps,
            fullResolution: resolved.recordFullResolution)
    }

    /// 供給(iOS lateWorkers 等)がまだ済んでいない間もボードに1本出す(段階「準備中」)。
    /// RunOrchestrator が最初の laneJoined で "running" の record へ上書きするまでの穴埋め。
    /// **後始末は呼び手**: RunOrchestrator.run() へ到達できずに throw すると finish() が一度も
    /// 呼ばれないので、呼び手は handoff が立たないまま抜けるとき返した pid の控えを defer で消す
    static func writePreparingProgress(recorder: RunRecorder?, project: TestProject, profile: String) -> Int32 {
        let pid = ProcessInfo.processInfo.processIdentifier
        RunProgressLedger.write(RunProgressRecord(
            pid: pid, runID: recorder?.runID, runGroup: recorder?.runGroup,
            issuer: LocalConfig.resolveIssuerId(), project: project.name, profile: profile,
            startedAt: ISO8601DateFormatter().string(from: Date()), total: 0, done: 0, failed: 0,
            requeued: 0, laneDropouts: 0, etaSeconds: nil, lanes: [], phase: "preparing"),
            directory: RunProgressLedger.directory())
        return pid
    }

    static func make(
        project: TestProject, workers: [RunWorker], resolved: ResolvedProfile, reportDir: URL,
        recorder: RunRecorder?, repoRoot: URL, leaseStateDir: URL?, supplyLease: SupplyLeaseHolder?,
        profile: String, progressHistoryRuns: Int, interruptState: RunInterruptState,
        lateWorkers: (platforms: Set<String>, provider: @Sendable () async -> [RunWorker])?,
        onRevived: @escaping @Sendable (RunWorker) -> Void,
        log: @escaping @Sendable (String) -> Void
    ) -> RunOrchestrator {
        return RunOrchestrator(
            project: project, workers: workers,
            settings: ScenarioExecutionSettings(resolved),
            reportDir: reportDir, recorder: recorder,
            recordingConfig: recordingConfig(resolved: resolved, recorder: recorder),
            isDeviceFrozen: { serial in
                // 事後判定は isBlankObserved(窓内に一度でも blank)。isPersistentlyBlank だと
                // 約25秒周期のフラッピングの回復側を引いて凍結を見逃す(実測 2026-07-18)。
                // 凍結確定時はその場で sleep/wake 修復も試みる(判定・振り直しは従来どおり)
                await AndroidHealthProbe.observeBlankAndRepair(serial: serial) { log($0) }
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
                        status: status, remedy: BridgeIdentityCheck.runLaneRemedy) {
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
            profile: profile,
            writeRunProgress: { record in
                RunProgressLedger.write(record, directory: RunProgressLedger.directory())
            },
            removeRunProgress: {
                RunProgressLedger.remove(pid: ProcessInfo.processInfo.processIdentifier,
                                         directory: RunProgressLedger.directory())
            },
            progressHistoryRuns: progressHistoryRuns,
            cleanupRetiredWorker: { retired in
                // ウェッジした旧ブリッジ(/status 無応答)は provision の再利用スキャンに映らないまま
                // 生き残り、シミュレータを掴み続ける。離脱検知の時点で UDID 照合で明示停止する
                // (revive 内でなくここに置く理由: 復帰を試みない離脱でも必ず kill するため)
                guard let udid = retired.connection.udid else { return }  // udid は iOS のみ
                let stopped = BridgeLauncher.stopMatching(udid: udid, repoRoot: repoRoot)
                if !stopped.isEmpty {
                    log("🔧 Stopped stale bridges: port \(stopped.joined(separator: ", "))")
                }
            },
            reviveWorker: { retired in
                guard let name = retired.logicalName else { return nil }
                let deadline = Date().addingTimeInterval(reviveTimeout)
                while Date() < deadline {
                    if let w = await ProfileWorkerFactory.buildWorker(forLogicalName: name, resolved: resolved,
                                                                       repoRoot: repoRoot, log: { log($0) }) {
                        do {
                            let installed = try await ProfileWorkerFactory.installIfNeeded(
                                apps: resolved.apps, workers: [w], forceAndroidInstall: false) { log($0) }
                            guard let revived = installed.first else { return nil }
                            onRevived(revived)
                            return revived
                        } catch {
                            // install に失敗した個体を古いアプリのまま参加させない(F5)。onRevived も呼ばない。
                            // この呼び出しでは復帰させない(呼び出し元が MAX_WORKER_REVIVES の範囲で再度呼ぶ)
                            log("❌ \(w.label): dropped out after an install failure — "
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
            lateWorkers: lateWorkers,
            installHandler: InstallHandlerFactory.make(apps: resolved.apps),
            appName: resolved.appName,
            appBundleIDs: resolved.apps.mapValues(\.bundleID),
            appTargets: resolved.apps,
            registerChildProcess: { interruptState.registerChildProcess($0) })
    }
}
