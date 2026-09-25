// VSCode拡張向け常駐 CLI(fleetest api monitor)。実行プロファイルのデバイスを一定間隔で
// ポーリングし、状態+スクリーンショット(JPEG)を NDJSON で stdout に流す(monitorDevices/
// monitorFrame/monitorError の3種のみ。診断は stderr)。デバイス起動・終了はこのコマンドの
// 責務外。終了条件: stdin EOF または SIGTERM/SIGINT。
//
// pause/resume プロトコル(拡張のパネル操作中に使用): stdin に NDJSON 1行で
// {"cmd":"pause"}/{"cmd":"resume"}(不明な行は無視)。pause 中は次サイクルに入らない
// (実行中のサイクルは完走)。resume 時は降格デバウンスの記憶をクリアしてから即座に1サイクル
// 実行し、操作直後の観測をそのまま採用する(3ストライク持ち越しによる見せかけの警告を防止)。
// pause が120秒続いたら安全弁として自動 resume する。
//
// suppressFrames プロトコル(デバイスタイルがストリーミング表示中はタイル側のポーリングを
// 止めるため): stdin に {"cmd":"suppressFrames","devices":["<id>",...]}。devices は抑制対象の
// 全置換(差分ではない)。省略/null は空集合(全デバイス再開)。抑制中デバイスはスクショ取得〜
// monitorFrame emit をスキップするが monitorDevices は従来どおり全デバイス分 emit する。
// 同期相手: vscode-fleetest/src/monitorModel.ts (monitorControlLine)
//
// health プローブ: state=connected の Android エミュレータ(実機除く)へ低頻度でヘルス
// チェック(adb/gRPC プローブ+emulator ログの Metal エラー計数)を行い、確定済み異常を devices[].health(異常なし/非対象は省略)に載せる
// (AndroidHealthProbe.swift。同期相手: vscode-fleetest/src/monitorModel.ts の health 契約)。
//
// 過渡的エラーの抑制: iOS ブリッジ/adb はテスト実行中 /status・/screenshot がタイムアウト
// しやすい(想定内の一時的競合)。1) connected からの降格は連続3回の失敗まで保留(昇格は即時)。
// 2) connected 中のスクショ取得失敗は monitorError にせず stderr ログ+フレーム skip のみ
// (monitorError は JPEG変換失敗など状態で説明できない異常に限定)。
// → テスト実行中のフレーム更新間欠化は仕様(異常ではない)。

import ArgumentParser
import CoreGraphics
import Foundation
import FTAndroid
import FTBridgeClient
import FTCore
import FTRemote
import ImageIO
import UniformTypeIdentifiers

struct ApiMonitorCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "monitor",
        abstract: "Poll every device in the run profiles (or, with --profile, only that profile's"
            + " enabled devices) at a fixed interval and stream their state and screenshots as"
            + " NDJSON (monitorDevices/monitorFrame/monitorError) on stdout"
            + " (diagnostics on stderr only; exits on stdin EOF or SIGTERM/SIGINT)")

    @Option(help: "Test project name (defaults to the only one in TestProjects/, or the default project)")
    var project: String?

    @Option(help: "Interval between monitor cycles in seconds (default 2.0)")
    var interval: Double = 2.0

    @Option(name: .customLong("max-width"), help: "Maximum size of the screenshot long edge in px (default 480)")
    var maxWidth: Int = 480

    @Option(help: "Run profile name (when given, only that profile's enabled devices are monitored; otherwise the devices of every run profile)")
    var profile: String?

    /// **どの機械のデバイスを観測するか**。simctl/adb は手元にしか効かないので、既定(nil)では
    /// この機械のデバイスだけを走査し、他の機械のぶんは `RemoteMonitorFanout` がその機械で
    /// 1本ずつ `--device-machine <host>` を走らせて合流させる。**この値が入っているのは子のとき** ——
    /// 子は自分のぶんだけを見て、それ以上の fan-out はしない(入れ子のディスパッチを作らない)
    @Option(name: .customLong("device-machine"),
            help: "Only observe the devices assigned to this machine, treating them as local (set by the parent monitor when it fans out; not for hand use)")
    var deviceMachine: String?

    func run() async throws {
        // ストリーミング読み取りが前提のため常に行バッファにする(ApiRunCommand.swift と同じ理由)
        setvbuf(stdout, nil, _IOLBF, 0)
        ResidentProcessGuard.startOrphanWatchdog(logLabel: "monitor")

        let testProject = try ScenarioHost.project(named: project)
        // 監視対象の台。**実行プロファイルを選んでいるかどうかで作り方が違う**:
        //   選んでいる: その実行プロファイルの enabled の台
        //   選んでいない(拡張の「(プロファイルなし)」): **台帳を1つに決めない** —— runs/ を
        //     全部畳み、手元 + リモート実行の登録簿にあるマシンの台だけを残す(MachineInventory)。
        //     決められないからと「今動いている台」だけに縮退すると、**未起動の台が1台も出ない**
        //     (実害 2026-08-28)
        // **実効マシンは spec に焼き込まれている**(id・帰属判定・拡張へ出す machine がすべてこの1つの値を見る)
        let targets: [MonitorTarget]
        if let profile {
            // 選んでいるのに0台なのは設定の誤りなので落とす(RunProfileScope が投げる)
            let scoped = try RunProfileScope.roster(project: testProject, runProfileName: profile)
            targets = DeviceMachineGrouping.entries(roster: scoped).map {
                MonitorTarget(platform: $0.platform, spec: $0.spec)
            }
        } else {
            let registry = (LocalConfig.load().remoteHosts ?? []).map(\.machine)
            let sources = MachineInventory.loadAllNamed(project: testProject) { logStderr("[monitor] \($0)") }
            let merged = MachineInventory.merge(
                sources: sources, registry: registry, existsLocally: Self.localPresencePredicate())
            // **食い違いは黙って畳まない** —— 負けた台帳の台が実在するほうだと、起動中の台が
            // 下の unregisteredStates で「id 衝突」として落ち、画面から消える(実害 2026-09-03)
            for conflict in merged.conflicts { logStderr("[monitor] \(conflict.message)") }
            targets = merged.entries.map { MonitorTarget(platform: $0.platform, spec: $0.spec) }
            // **0台でも続ける**(起動中の台が現れたら出す)
            logStderr("[monitor] No run profile is selected — monitoring the devices registered for this"
                + " machine and for every machine in the remote registry"
                + " (\(targets.count) device(s) from \(sources.count) run profile(s);"
                + " registry: \(registry.isEmpty ? "none" : registry.joined(separator: ", ")))")
        }

        let scope = Self.scope(targets: targets, deviceMachine: deviceMachine)
        let ownedTargets = scope.owned
        let listedTargets = scope.listed
        // プロファイル未選択(「起動中のデバイス」)は登録簿の全マシンへ張る(fanoutMachines の doc)
        let fanoutTargets = Self.fanoutMachines(
            foreignMachines: scope.foreignMachines,
            profileSelected: profile != nil,
            registry: (LocalConfig.load().remoteHosts ?? []).map(\.machine),
            deviceMachine: deviceMachine)
        let fanout: RemoteMonitorFanout? = {
            guard !fanoutTargets.isEmpty else { return nil }
            return RemoteMonitorFanout(
                machines: fanoutTargets, project: testProject.name, profile: profile,
                interval: interval, maxWidth: maxWidth,
                log: { message in MonitorOutput.shared.writeStderr(message) },
                relayLine: { line in MonitorOutput.shared.writeLine(line) })
        }()
        fanout?.start()
        defer { fanout?.stop() }
        // **死んだ自分のディスパッチのロックを掃除する**(親だけ・プロセス起動時に1回)。
        // 拡張はモニターをバイナリ差し替え等のたびに再起動するので、そのたびに掃除が走る。
        // ssh を伴うので初回サイクルを待たせない(RemoteCommand.StaleLockSweep のコメント参照)
        if deviceMachine == nil {
            let sweepMachines = (LocalConfig.load().remoteHosts ?? []).map(\.machine)
            if !sweepMachines.isEmpty {
                Task.detached {
                    RemoteCommand.StaleLockSweep.sweep(machines: sweepMachines) {
                        MonitorOutput.shared.writeStderr($0)
                    }
                }
            }
        }

        let stop = StopFlag()
        let control = MonitorControl()
        startStdinWatcher(stop: stop, control: control, fanout: fanout)
        // ループを抜けるまでシグナルソースを保持する(解放されるとハンドラが外れる)
        let signalSources = installSignalHandlers(stop: stop)
        defer { for source in signalSources { source.cancel() } }

        // 直近の monitorError メッセージ(デバイス毎、同一メッセージの連続 emit 抑制用。
        // JPEG変換失敗など状態で説明できない異常のみ対象。スクショ取得失敗は loggedFetchFailure 側)
        var lastErrorMessage: [String: String] = [:]
        // ネットワーク起因のスクショ取得失敗を stderr ログ済みか(デバイス毎。状態が変わるまで再ログしない)
        var loggedFetchFailure: Set<String> = []
        // 直近の確定状態(デバイス毎、debounce 用)
        var confirmed: [String: ConfirmedDeviceState] = [:]
        // Android ヘルスプローブ: serial 毎の直近プローブ時刻と確定済み異常の記憶
        // (healthProbeIntervalSeconds 未満はプローブせず直近の確定値を使い回す)
        var lastHealthProbeAt: [String: Date] = [:]
        var healthDebounce = AndroidHealthDebounce(confirmThreshold: 2)
        // 画面凍結(一様フレーム)の確定。判定材料はこのループが毎サイクル撮っている PNG
        var frozenDebounce = MonitorFrozenDebounce(confirmThreshold: 2)
        // 配信を抑制中のデバイスを最後に「観測のためだけに」撮った時刻(capturePlan が更新する)
        var lastFrozenProbeAt: [String: Date] = [:]
        // ブリッジを持たない iOS シミュレータを最後に simctl で撮った時刻
        // (simctlCapturePick が更新する。1サイクル1台の順繰りに使う)
        var lastSimctlCaptureAt: [String: Date] = [:]
        // GPU/CPU 判定はブート時固定のため接続毎に1回のみ検出しキャッシュする(健全性プローブとは
        // 別間隔。再接続=リブートで変わりうるため切断時に破棄する)
        var renderModeCache: [String: String] = [:]

        // run/recording lease の読み取り用(.fleetest/{run,recording}-<key>.lease で inRun/recording を
        // 判定)。best-effort: リポジトリ外実行等で root が取れない場合は両者 false に倒す
        let monitorRepoRoot = try? RepoRoot.find()
        let leaseStateDir = monitorRepoRoot?.appendingPathComponent(".fleetest")

        // 直近の hold 状態(変化したときだけ monitorHold イベントと stderr を出す)
        var lastHoldActive = false
        // 直近サイクルで id 衝突により落とした合成デバイスの警告(変化したときだけ出す)
        var lastSkipped: Set<String> = []
        // その機械の dispatch.lock を毎周期読んで monitorLock を出す。**ランナー機の文脈かで
        // 分岐しない**(2026-09-21)—— ロックは機械に1本で、リモートへのディスパッチも
        // ローカル run も同じ1本を取る(CLAUDE.md「1マシンで同時に走る run は1本」)ので、
        // **手元の run も占有**。黙ると錠前と配信の退避が手元にだけ効かない。
        // **ssh は増えない**(ローカルのファイル読み)。`machine` は埋めない = 欠落が手元の綴り
        // (monitorRuns / monitorDevices と同じ)で、リモートぶんは RemoteMonitorFanout が
        // 中継しながら機械名を埋める
        let myIssuer = LocalConfig.resolveIssuerId()
        var lastOccupancy: HostOccupancy?
        // フリート横断の run 進捗(docs/design.md §18)。読む場所は機械グローバル
        // (~/.fleetest/runs)なので、ここでは fan-out の子(--device-machine 付き)かどうかも
        // 問わない —— 手元で走る CLI 実行の run もここで見せるのが目的
        let runProgressDir = RunProgressLedger.directory()
        // **比較は生の台帳(RunProgressRecord)で行う** —— 変換後の ApiMonitorRunProgress は
        // elapsedSeconds/scenarioElapsedSeconds を毎周期の `now` で計算し直すので、生のまま
        // 比較しないと壁時計が進むだけの周期でも「変化した」と判定して毎回 emit してしまう
        // (startedAt/scenarioStartedAt は固定文字列なので、記録そのものが動いていない限り一致する)
        // **Optional で持つ**(空配列で初期化しない)—— run が 0 本のとき「空配列 == 空配列」で
        // 1行も出さないと、拡張は「一度も聞いていない = 不明」のままになり **「空き」を表現できない**
        // (monitorLock の lastOccupancy が Optional なのと同じ理由)
        var lastRunRecords: [RunProgressRecord]?
        while !stop.isSet {
            let occupancy = HostOccupancy.read(myIssuer: myIssuer)
            if occupancy != lastOccupancy {
                lastOccupancy = occupancy
                emitLine(ApiMonitorLockEvent(occupancy: occupancy))
                logStderr(occupancy.held
                    ? "[monitor] A run holds this machine's dispatch lock"
                      + " (\(occupancy.issuer ?? "holder unknown")) — the extension stops live streams here"
                    : "[monitor] This machine's dispatch lock is free")
            }
            let currentRunRecords = RunProgressLedger.readAll(directory: runProgressDir)
                .sorted { $0.pid < $1.pid }
            if Self.shouldEmitRuns(current: currentRunRecords, last: lastRunRecords) {
                lastRunRecords = currentRunRecords
                emitLine(ApiMonitorRunsEvent(
                    runs: Self.monitorRuns(records: currentRunRecords, now: Date(), myIssuer: myIssuer)))
            }
            // **保持ファイル(`fleetest monitor pause`)は毎周期の頭で見る** —— kill と違い
            // 拡張に再起動されない止め方(FTCore.MonitorHold)。手元スコープのときだけ:
            // fan-out の子(--device-machine 付き)はランナー機側の hold を親の拡張へ波及させない。
            // hold 中も monitorDevices は出す(全台 state:"unknown")—— タイルが最後の絵で
            // 固まると「止めた」ことが見えない。unknown はリモートの未観測と同じ既存表現
            if deviceMachine == nil, let dir = leaseStateDir {
                let holdActive = MonitorHold.load(stateDir: dir)?.isActive() ?? false
                if holdActive != lastHoldActive {
                    lastHoldActive = holdActive
                    emitLine(ApiMonitorHoldEvent(active: holdActive))
                    logStderr(holdActive
                        ? "[monitor] Hold active (`fleetest monitor pause`) — observation and"
                          + " frame delivery stop; tiles show state \"unknown\""
                        : "[monitor] Hold released — resuming observation")
                }
                if holdActive {
                    // **リモートの台も held にする**(remote: を空で渡す)。fanout の snapshot
                    // (state=connected)を合流させると、拡張が qualifying 判定で device-stream を
                    // 張り続け、pause 中もリモートのタイルだけ映像が更新され続ける(2026-09-01 報告)。
                    // fanout の子の観測は止めない —— 畳むのは配信段(この表示)だけ
                    let held = listedTargets.map {
                        Self.unobservedInfo(target: $0, detail: "held (fleetest monitor resume)")
                    }
                    emitLine(ApiMonitorDevicesEvent(devices: Self.mergedDevices(
                        listedTargets: listedTargets, observed: held, remote: [:])))
                    // **interval で寝る(pausedPollSeconds を使わない)** —— あの 0.2s は
                    // pause 分岐が emit せずに resume を素早く検知するための値で、emit を伴う
                    // このループへ流用すると 0.2s ごとに全台ぶんの devices を出し続ける
                    // (受け手の無人計測 = 数十分で数千イベントの洪水。2026-08-24 実害)。
                    // resume の反映が最大 interval 秒遅れるのは許容(既定 2s)
                    await Self.sleepInterruptible(seconds: max(interval, 1), stop: stop)
                    continue
                }
            }
            if control.autoResumeIfStale(limit: Self.pauseSafetyValveSeconds) {
                logStderr(
                    "[monitor] Auto-resumed \(Int(Self.pauseSafetyValveSeconds))s after the pause" +
                    " (the resume from the device-control panel may never have arrived)")
            }
            if control.takeResetRequest() {
                confirmed.removeAll()
                lastErrorMessage.removeAll()
                loggedFetchFailure.removeAll()
            }
            if control.isPaused {
                await Self.sleepInterruptible(seconds: Self.pausedPollSeconds, stop: stop)
                continue
            }

            // --profile 指定時はスコープを絞る意図のため未登録デバイスは合成しない
            let (observed, skipped) = await Self.determineStates(
                targets: ownedTargets, includeUnregistered: profile == nil)
            // **変わったときだけ出す** —— 毎周期そのまま出すと同じ行が永久に流れ続ける。
            // 空へ戻った回も1行出す(出さないと「直ったのか、まだ衝突しているのか」が読めない)
            let skippedNow = Set(skipped)
            if skippedNow != lastSkipped {
                if skippedNow.isEmpty {
                    logStderr("[monitor] The device id collisions reported above are gone")
                } else {
                    for message in skippedNow.sorted() { logStderr(message) }
                }
                lastSkipped = skippedNow
            }
            let states = Self.debounce(observed, confirmed: &confirmed) { message in
                self.logStderr(message)
            }

            // connected な Android エミュレータのみ対象(実機は Wi-Fi オフが意図的でありうるため除外)
            let candidateSerials = Set(states.compactMap { state -> String? in
                guard state.state == "connected", let serial = state.androidSerial,
                      serial.hasPrefix("emulator-") else { return nil }
                return serial
            })
            for serial in Set(lastHealthProbeAt.keys).subtracting(candidateSerials) {
                lastHealthProbeAt.removeValue(forKey: serial)
                healthDebounce.forget(serial: serial)
                renderModeCache.removeValue(forKey: serial)
            }
            let probeNow = Date()
            let dueSerials = candidateSerials.filter { serial in
                guard let last = lastHealthProbeAt[serial] else { return true }
                return probeNow.timeIntervalSince(last) >= Self.healthProbeIntervalSeconds
            }
            if !dueSerials.isEmpty {
                let issuesBySerial = await withTaskGroup(
                    of: (String, Set<String>).self, returning: [String: Set<String>].self
                ) { group in
                    for serial in dueSerials {
                        group.addTask { (serial, await AndroidHealthProbe.observeIssues(serial: serial)) }
                    }
                    var result: [String: Set<String>] = [:]
                    for await (serial, issues) in group { result[serial] = issues }
                    return result
                }
                for (serial, issues) in issuesBySerial {
                    _ = healthDebounce.record(issues, serial: serial)
                    lastHealthProbeAt[serial] = probeNow
                }
            }

            let uncachedSerials = candidateSerials.filter { renderModeCache[$0] == nil }
            if !uncachedSerials.isEmpty {
                let modesBySerial = await withTaskGroup(
                    of: (String, String?).self, returning: [String: String?].self
                ) { group in
                    for serial in uncachedSerials {
                        group.addTask { (serial, AndroidHealthProbe.detectRenderMode(serial: serial)) }
                    }
                    var result: [String: String?] = [:]
                    for await (serial, mode) in group { result[serial] = mode }
                    return result
                }
                for (serial, mode) in modesBySerial {
                    if let mode { renderModeCache[serial] = mode }
                }
            }

            // Android 実機のブリッジ生死(state=connected の実機だけ。shouldProbeBridge)。
            // `ensureBridge()` は通さない(観測のためだけにブリッジを建てない)。対象は少数
            // (通常1〜3台)・`pidof` 1往復が数十ミリ秒なので、health probe と違い**毎サイクル**叩く
            // —— healthProbeIntervalSeconds(30秒)級に低頻度化すると、タイルメニューで
            // ブリッジを止めた直後にタイル表示が変わらず「効いていない」と読まれる。
            // 台数が増えて重くなったら healthProbeIntervalSeconds と同じ形の TTL キャッシュへ寄せる
            let bridgeProbeSerials = Set(states.compactMap { state -> String? in
                Self.shouldProbeBridge(state: state) ? state.androidSerial : nil
            })
            let bridgeRunningBySerial: [String: Bool?] = await withTaskGroup(
                of: (String, Bool?).self, returning: [String: Bool?].self
            ) { group in
                for serial in bridgeProbeSerials {
                    group.addTask { (serial, AndroidDriver.isBridgeRunning(serial: serial)) }
                }
                var result: [String: Bool?] = [:]
                for await (serial, running) in group { result[serial] = running }
                return result
            }

            // 手元の二重配信の判定に使う 1 周期ぶんのプロセス一覧(FTCore.LocalStreamHolder)。
            // 台ごとに ps を撃たない
            let processRows = states.isEmpty ? [] : LocalStreamHolder.snapshot()
            let observedInfos = states.map { state -> ApiMonitorDeviceInfo in
                let confirmedIssues = state.androidSerial.map { healthDebounce.confirmed(serial: $0) } ?? []
                let leaseKey = state.iosUdid ?? state.androidSerial
                let inRun = leaseStateDir.flatMap { dir in
                    leaseKey.map { RunLease.isFresh(stateDir: dir, key: $0) }
                } ?? false
                let recording = leaseStateDir.flatMap { dir in
                    leaseKey.map { RecordingLease.isFresh(stateDir: dir, key: $0) }
                } ?? false
                // 実機の宛先(LAN IP or ループバック)。拡張が画面配信ヘルパーに渡す
                let bridgeHost: String? = state.target.spec.isPhysical
                    ? state.iosPort.flatMap { port in
                        monitorRepoRoot.map { BridgeEndpoint.load(port: port, repoRoot: $0).host }
                      }
                    : nil
                let frozenVerdict = Self.frozenVerdict(
                    id: state.target.id, key: leaseKey,
                    debounce: frozenDebounce, stateDir: leaseStateDir, inRun: inRun,
                    physical: state.target.spec.isPhysical)
                // 他の発行者がこの台を配信中か。控えは機械グローバル(~/.fleetest/streams)なので
                // **手元でも読む** —— 台が居る機械の上で走るこのプロセスの $HOME が答えを持つ
                let leasedByOther = StreamLease.heldByOther(
                    info: StreamLease.read(platform: state.target.platform, name: state.target.name),
                    myIssuer: myIssuer, pidAlive: ProcessLiveness.isAlive)
                // 同じ Mac の別のウィンドウ(別の FT_PARENT_PID)がこの台のヘルパーを持っているか
                let heldLocally = Self.streamIdentity(state).map { identity in
                    LocalStreamHolder.heldByOther(identity: identity, rows: processRows,
                                                  myOwner: LocalStreamHolder.myOwner())
                } ?? false
                let streamedByOther: Bool? = leasedByOther || heldLocally
                var bridgeRunning: Bool?
                if let serial = state.androidSerial, let probed = bridgeRunningBySerial[serial] {
                    bridgeRunning = probed
                }
                return state.info(health: confirmedIssues.isEmpty ? nil : confirmedIssues,
                                   renderMode: state.androidSerial.flatMap { renderModeCache[$0] },
                                   inRun: inRun, recording: recording, host: bridgeHost,
                                   frozen: frozenVerdict.isFrozen, streamedByOther: streamedByOther,
                                   bridgeRunning: bridgeRunning)
            }
            emitLine(ApiMonitorDevicesEvent(devices: Self.mergedDevices(
                listedTargets: listedTargets, observed: observedInfos,
                remote: fanout?.snapshot() ?? [:])))

            // 接続が切れた機の記憶を落とす(次回同じエラーが起きても「状態変化」として扱えるように。
            // 凍結は**落ちている機を数え続けない**ので確定も捨てる)
            for state in states where state.state != "connected" {
                lastErrorMessage[state.target.id] = nil
                loggedFetchFailure.remove(state.target.id)
                frozenDebounce.forget(id: state.target.id)
                lastFrozenProbeAt.removeValue(forKey: state.target.id)
                // **撮り続ける対象の時計は捨てない**(判定は候補と同じ述語 = 2つの規則が
                // 食い違わない)。捨てると毎サイクル全台が「未撮影」に戻り、順繰り
                // (最後に撮ってから最も経った台)が常に同じ1台を選び続ける
                if !Self.isSimctlCaptureTarget(state: state) {
                    lastSimctlCaptureAt.removeValue(forKey: state.target.id)
                }
            }

            // 未登録 iOS シミュレータはブリッジが無い(iosPort == nil のまま connected にするため。
            // unregisteredStates 参照)ので、ブリッジ /screenshot を前提とするこの経路には乗らない
            let eligible = states.filter { state in
                state.state == "connected" && (state.target.platform != "ios" || state.iosPort != nil)
            }
            // **ブリッジを持たない iOS シミュレータは simctl で撮る**。通常は拡張の simstream が
            // 映すので出番は無いが、**配信が張れない台ではここが唯一の絵の出所**になる
            // (リモート機・ポーリングモード)。以前はこの穴が塞がっておらず、
            // 「落ちたときはポーリングへ落ちる」が iOS では成立していなかった(2026-08-28)。
            // 抑制中(= そのタイルは配信で映っている)の台は重い simctl を撃つ理由が無いので外す。
            // 実機は simctl で撮れないので対象外(そちらは devicepoll がブリッジ経由で撮る)。
            //
            // **"booted" も対象**(2026-08-29)。ブリッジの無い台の state は登録の有無で割れる ——
            // 未登録の合成デバイスは "connected"、**台帳に載っている台は "booted"**。connected だけを
            // 見ていたので、台帳に載っていてブリッジを持たない台は絵の出所がゼロになり、タイルが
            // 「接続中」のまま永久に埋まらなかった(実行プロファイル未選択の一覧で顕在化)
            let simctlCandidates = states.filter { state in
                Self.isSimctlCaptureTarget(state: state)
                    && !control.isFrameSuppressed(state.target.id)
            }
            let simctlPickID = Self.simctlCapturePick(ids: simctlCandidates.map(\.target.id),
                                                      lastCapturedAt: &lastSimctlCaptureAt)
            let simctlPicked = simctlPickID.flatMap { id in
                simctlCandidates.first { $0.target.id == id }
            }
            // **観測段と配信段の分かれ目はここだけ**。抑制(拡張のタイルがストリーミング表示中)は
            // `deliver` にしか効かない —— 観測まで止めると凍結判定が丸ごと死ぬ(2026-08-11 の実害)
            let plan = Self.capturePlan(ids: eligible.map(\.target.id),
                                        suppressed: { control.isFrameSuppressed($0) },
                                        lastProbeAt: &lastFrozenProbeAt)
            var deliverIDs = Set(plan.filter(\.deliver).map(\.id))
            var plannedIDs = Set(plan.map(\.id))
            if let simctlPickID {
                // 抑制されていない台だけを候補にしてあるので、撮ったら必ず配る
                deliverIDs.insert(simctlPickID)
                plannedIDs.insert(simctlPickID)
            }

            for state in eligible + (simctlPicked.map { [$0] } ?? [])
            where plannedIDs.contains(state.target.id) {
                guard !stop.isSet else { break }

                let png: Data
                do {
                    png = try await Self.fetchScreenshot(state: state, repoRoot: monitorRepoRoot)
                } catch {
                    // 過渡的競合として扱う: monitorError は出さず stderr ログのみ(同一デバイスで
                    // 連続する間は再ログしない)、フレームは skip(前回フレームが Webview に残る)
                    if !loggedFetchFailure.contains(state.target.id) {
                        logStderr(
                            "[monitor] Failed to capture a screenshot of \(state.target.id)" +
                            " (connection kept: possibly a transient conflict during a test run): \(error.localizedDescription)")
                        loggedFetchFailure.insert(state.target.id)
                    }
                    continue
                }
                loggedFetchFailure.remove(state.target.id)
                // ---- 観測段: **縮小前の PNG で判定する**(JPEG 化は非可逆で、縮小も一様性を
                // 薄める方向に働く)。撮れなかったサイクル(上の continue)では記録しない = 直前の確定を保つ。
                // nil(デコード不能)も欠測として同じ扱い(record(blankness:) が確定を変えない)
                let blankness = BlankFrameDetector.uniformBlankness(pngData: png)
                // **run 中は streak を積まず忘れる**(frozenVerdict の inRun と対)。記録だけ続けて
                // 判定側で無視すると、run 終了の瞬間に run 中の黒で確定済みの ❄️ が出る —— 終了後の
                // 黒は2回の新規確認からやり直す
                let captureLeaseKey = state.iosUdid ?? state.androidSerial
                let captureInRun = leaseStateDir.flatMap { dir in
                    captureLeaseKey.map { RunLease.isFresh(stateDir: dir, key: $0) }
                } ?? false
                if captureInRun {
                    frozenDebounce.forget(id: state.target.id)
                } else {
                    frozenDebounce.record(blankness: blankness, id: state.target.id)
                }

                // ---- 配信段: ここから先だけが抑制の対象
                guard deliverIDs.contains(state.target.id) else { continue }
                do {
                    let jpeg = try MonitorImage.downscaledJPEG(pngData: png, maxWidth: maxWidth)
                    emitLine(ApiMonitorFrameEvent(
                        device: state.target.id,
                        jpegBase64: jpeg.data.base64EncodedString(),
                        width: jpeg.width, height: jpeg.height))
                    lastErrorMessage[state.target.id] = nil
                } catch {
                    // JPEG 変換失敗(壊れた PNG 等)はタイルへ警告を出さない(ユーザー決定:
                    // 過渡的でユーザーに対処可能性が無いため)。stderr のみ・同一メッセージ連続中は
                    // 再ログしない。持続するならブリッジ不調のサイン(curl /screenshot で切り分け)
                    let message = error.localizedDescription
                    // 抑止の鍵は message のまま(バイト数を混ぜるとサイズが揺れるたび再ログしてしまう)
                    if lastErrorMessage[state.target.id] != message {
                        logStderr("[monitor] \(state.target.id): \(message) (\(png.count) bytes, not notifying the tile)")
                        lastErrorMessage[state.target.id] = message
                    }
                }
            }

            await Self.sleepInterruptible(seconds: interval, stop: stop)
        }
    }

    /// 監視対象の仕分け。**この機械が観測できるのは自分のデバイスだけ** —— 他の機械のぶんを
    /// simctl/adb で見ると、同名の手元のシミュレータに解決して**別の機械の台の状態と画面を出す**
    /// ((host, name) が一意なら同名は正常な構成なので普通に起きる)
    struct Scope {
        /// この機械が simctl/adb で観測する台
        let owned: [MonitorTarget]
        /// 毎サイクル devices として出す台。親は全部(他の機械のぶんは fan-out か「取得できません」)、
        /// **子(--device-machine 付き)は自分のぶんだけ** —— 親も同じ台を並べるので、両方が出すと
        /// 拡張の Map で潰し合う
        let listed: [MonitorTarget]
        /// fan-out 先(登場順・重複なし)
        let foreignMachines: [String]
    }

    /// fan-out 先の決定。**プロファイルを選んでいるときはその範囲**(scope が挙げた他機)、
    /// **選んでいないとき(拡張の「起動中のデバイス」)は登録簿の全マシン** ——
    /// 実行プロファイルを引かない = どの台がどの機械に居るかを知る手掛かりが他に無いので、
    /// 何もしないと**リモートで起動中の台が一覧に出ない**(2026-08-26 の報告)。
    /// **子(--device-machine 付き)は常に空** = 入れ子のディスパッチを作らない。
    /// 重複除去は登場順を保つ(表示とログの並びを入力から決まる形にする)。I/O を持たない pure 関数
    static func fanoutMachines(
        foreignMachines: [String], profileSelected: Bool, registry: [String], deviceMachine: String?
    ) -> [String] {
        guard deviceMachine == nil else { return [] }
        if profileSelected { return foreignMachines }
        var seen = Set<String>()
        return registry
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty && MachineDispatch.normalize($0) != nil && seen.insert($0).inserted }
    }

    /// `RunProgressRecord`(台帳。ISO8601 を持つ)→ 拡張へ渡す形(秒に直し、mine を判定する)。
    /// **経過は呼び出し側の `now`**(docs/design.md §18.3: 同じ機械の時計で計算する。台帳の
    /// ISO8601 をそのまま流さない)。**issuer が nil の record は mine=false**
    /// (HostOccupancy.interpret と同じ向き)。並びは pid 昇順に固定する(readAll はディレクトリ
    /// 列挙順=不定なので、固定しないと変化していない run でも比較のたびに emit してしまう)。
    /// I/O を持たない pure 関数
    static func monitorRuns(records: [RunProgressRecord], now: Date, myIssuer: String) -> [ApiMonitorRunProgress] {
        let iso = ISO8601DateFormatter()
        func elapsedSeconds(since text: String) -> Int? {
            guard let started = iso.date(from: text) else { return nil }
            return max(0, Int(now.timeIntervalSince(started).rounded()))
        }
        return records
            .sorted { $0.pid < $1.pid }
            .map { record in
                ApiMonitorRunProgress(
                    pid: record.pid, runID: record.runID, runGroup: record.runGroup,
                    issuer: record.issuer, mine: record.issuer.map { $0 == myIssuer } ?? false,
                    project: record.project, profile: record.profile,
                    // 台帳の startedAt は RunOrchestrator が ISO8601DateFormatter で書いた値なので
                    // 通常パースは失敗しない。壊れていたら 0(不明な負の経過を出すよりまし)
                    elapsedSeconds: record.startedAt.isEmpty ? 0 : (elapsedSeconds(since: record.startedAt) ?? 0),
                    total: record.total, done: record.done, failed: record.failed,
                    // 詰まりの事実(段6)。台帳の値をそのまま運ぶ(判定・文言は作らない)
                    requeued: record.requeued, laneDropouts: record.laneDropouts,
                    // 段5(残り見積もり。docs/design.md §18.4)。台帳の値をそのまま運ぶ ——
                    // 実績ゼロの run は台帳側が既に nil を書いているので、ここで別途判定しない
                    etaSeconds: record.etaSeconds,
                    lanes: record.lanes.map { lane in
                        ApiMonitorRunProgressLane(
                            key: lane.key, name: lane.name, platform: lane.platform,
                            scenario: lane.scenario,
                            scenarioElapsedSeconds: lane.scenarioStartedAt.flatMap { elapsedSeconds(since: $0) },
                            expectedSeconds: lane.expectedSeconds)
                    },
                    phase: record.phase)
            }
    }

    /// `monitorRuns` を出すか。**`last` が nil(まだ1行も出していない)なら必ず出す** ——
    /// run 0 本の機械が「空き」だと分かるのは1行受け取ってからで、出さないと拡張の側は
    /// 「不明」のまま(「不明」と「空き」を混ぜない規律の、送り手側の半分)
    static func shouldEmitRuns(current: [RunProgressRecord], last: [RunProgressRecord]?) -> Bool {
        current != last
    }

    /// I/O を持たない pure 関数(MonitorMachineScopeTests)
    static func scope(targets: [MonitorTarget], deviceMachine: String?) -> Scope {
        let wanted = MachineDispatch.normalize(deviceMachine)
        let owned = targets.filter { MachineDispatch.normalize($0.spec.machine) == wanted }
        let foreign = targets.filter { MachineDispatch.normalize($0.spec.machine) != wanted }
        // **子は fan-out しない**(入れ子のディスパッチを作らない。`remote exec` も
        // --host の relay を拒む = 経路は1段と決めてある)
        let machines = deviceMachine == nil
            ? DeviceMachineGrouping.groups(foreign, machine: { MachineDispatch.normalize($0.spec.machine) })
                .compactMap(\.machine)
            : []
        return Scope(owned: owned, listed: deviceMachine == nil ? targets : owned, foreignMachines: machines)
    }

    /// 出す1サイクルぶんの devices を組み立てる。**並びは台帳の順のまま**
    /// (拡張も並べ替えるが、順序の正はここ = 手元とリモートで別扱いにしない)。
    /// - observed: この機械が simctl/adb で観測した台(未登録の起動中デバイスを含みうる)
    /// - remote: 子(その機械の monitor)が報告してきた台。id は (platform, host, name) 由来で
    ///   親子で一致する
    /// どちらにも無い台は **「状態を取得できない」** として出す —— 観測していないものを
    /// offline と言うと、向こうで動いていても止まって見える(2026-08-17 の実害)。
    /// I/O を持たない pure 関数(MonitorMachineScopeTests)
    static func mergedDevices(listedTargets: [MonitorTarget], observed: [ApiMonitorDeviceInfo],
                              remote: [String: ApiMonitorDeviceInfo]) -> [ApiMonitorDeviceInfo] {
        var observedByID: [String: ApiMonitorDeviceInfo] = [:]
        for info in observed { observedByID[info.id] = info }
        var merged = listedTargets.map { target in
            observedByID[target.id] ?? remote[target.id] ?? unobservedInfo(target: target)
        }
        // 台帳に無い台(determineStates が合成した起動中デバイス)を後ろへ足す
        let listedIDs = Set(listedTargets.map(\.id))
        merged += observed.filter { !listedIDs.contains($0.id) }
        // **リモートの未登録の台も足す** —— プロファイル未選択(拡張の「起動中のデバイス」)では
        // listedTargets が手元のぶんしか無いので、ここで足さないと**向こうで起動中の台が
        // 一覧に出ない**(2026-08-26 の報告)。並びは id 順に固定する(辞書は順序を持たないため、
        // 揺らすと拡張のタイルが毎サイクル並べ替わる)
        let mergedIDs = Set(merged.map(\.id))
        merged += remote.values.filter { !mergedIDs.contains($0.id) }.sorted { $0.id < $1.id }
        // **WiFi 越しの分身は隠す**(2026-08-31 指示: wired を優先表示し WiFi は非表示)。
        // 同じ実機(udid)を、USB で繋がった機械と WiFi ペアリング済みの機械の両方が connected と
        // 報告する(devicectl は localNetwork でも state=connected)。wired の1枚が居るときだけ
        // WiFi 側(wired == false)を落とす。wired が1枚も無ければ全部残す —— どれが本物か
        // 決められないものを隠すと、その実機が一覧から消える
        let wiredUdids = Set(merged.compactMap { $0.wired == true ? $0.udid : nil })
        merged.removeAll { $0.wired == false && $0.udid.map(wiredUdids.contains) == true }
        return merged
    }

    /// 誰も観測していない台。**state は "unknown"** で、offline(= 止まっている)とは区別する。
    /// detail は hold(`fleetest monitor pause`)が理由を載せるための口(既定は従来どおり空)。
    /// hold の値 "held (fleetest monitor resume)" は接頭辞 'held' を拡張の webview が
    /// 「モニタ停止中」表示の目印にする(vscode-fleetest/src/webview/monitor/deviceTiles.js と
    /// 同期。monitorHoldDetailSync.test.mjs が突き合わせる)
    static func unobservedInfo(target: MonitorTarget, detail: String = "") -> ApiMonitorDeviceInfo {
        ApiMonitorDeviceInfo(
            id: target.id, name: target.name, platform: target.platform,
            state: "unknown", detail: detail, udid: nil, serial: nil, health: nil, renderMode: nil,
            inRun: false, kind: target.spec.isPhysical ? "physical" : "virtual",
            host: nil, port: nil, recording: false, registered: target.registered,
            machine: MachineDispatch.normalize(target.spec.machine), frozen: false, wired: nil,
            streamedByOther: nil, bridgeRunning: nil)
    }

    /// `MachineInventory.merge` へ渡す「その台の実体がこの機械にあるか」の述語。
    /// **呼ぶのは targets を組む起動時の1回だけ** —— 監視ループ(既定 2 秒周期)へ I/O を足さない
    /// ため、材料はここで畳んでからクロージャに閉じ込める。
    /// **判定できない種別に true を返さない**: 実機 iOS の列挙は devicectl(秒オーダー)が要るので
    /// ここでは払わず false = 「この機械で観測していない」に倒す。AVD は id と表示名の完全一致だけ
    /// (取りこぼしも false 側 = 従来どおり先頭優先のまま)。見る順は MachineInventory の
    /// identity(of:) と同じ udid → avd → serial
    static func localPresencePredicate() -> (DeviceSpec) -> Bool {
        // udid の大小は台帳ごとに揺れる(simctl は大文字)ので畳んで比べる
        let simulatorUdids = Set(((try? SimulatorCatalog.devices()) ?? []).map { $0.udid.uppercased() })
        let installedAVDs = AndroidDeviceCatalog.installedAVDs()
        let avdLabels = Set(installedAVDs.map(\.id) + installedAVDs.compactMap(\.displayName))
        let serials = Set((try? AndroidDeviceCatalog.connectedSerials()) ?? [])
        return { spec in
            if let udid = spec.udid { return simulatorUdids.contains(udid.uppercased()) }
            if let avd = spec.avd { return avdLabels.contains(avd) }
            if let serial = spec.serial { return serials.contains(serial) }
            return false
        }
    }

    // MARK: - 終了検知・制御コマンド受信(stdin / シグナル)

    /// EOF検知で停止フラグを立てる。readLine はブロッキングなので別スレッドで読み続ける
    /// (ApiRunCommand.swift の --debug stdin 制御読み取りと同じ方式)
    private func startStdinWatcher(stop: StopFlag, control: MonitorControl,
                                  fanout: RemoteMonitorFanout?) {
        let thread = Thread {
            while let line = readLine(strippingNewline: true) {
                guard let data = line.data(using: .utf8),
                      let command = try? JSONDecoder().decode(MonitorControlCommand.self, from: data)
                else { continue }
                // **子にもそのまま渡す** —— pause/resume/suppressFrames はどれも id の集合か
                // 全体の状態で、自分の持たない id が混ざっていても害が無い
                fanout?.forwardControl(line: line)
                switch command.cmd {
                case "pause":
                    control.pause()
                    self.logStderr("[monitor] Polling paused (device operation in progress)")
                case "resume":
                    control.resume()
                    self.logStderr("[monitor] Polling resumed")
                case "suppressFrames":
                    let ids = Set(command.devices ?? [])
                    let previous = control.setSuppressedFrames(ids)
                    // 拡張は配信が1本張られるたびに全リストを送る(30 台なら 30 回)ので、
                    // 全リストを毎回出すと1秒で数千文字になる。出すのは差分だけ
                    // fan-out の子(--device-machine 付き)は親から同じ行を無加工で中継されるので、
                    // 親が1行出せば足りる(子も出すと機械の数だけ同じ差分が並ぶ)
                    if deviceMachine == nil {
                        self.logStderr(Self.suppressionDeltaLine(ids: ids, previous: previous))
                    }
                default:
                    break
                }
            }
            stop.set()
            ResidentProcessGuard.scheduleForcedExit(logLabel: "monitor")
        }
        thread.name = "fleetest-api-monitor-stdin"
        thread.start()
    }

    /// SIGTERM/SIGINT を捕捉して停止フラグを立てる(既定の即時終了を上書きし、ループの
    /// 区切りでクリーンに終了できるようにする)。戻り値はループを抜けるまで呼び出し側が
    /// 保持すること(DispatchSourceSignal は解放されるとハンドラが外れる)
    private func installSignalHandlers(stop: StopFlag) -> [DispatchSourceSignal] {
        signal(SIGTERM, SIG_IGN)
        signal(SIGINT, SIG_IGN)
        let queue = DispatchQueue(label: "fleetest-api-monitor-signal")
        return [SIGTERM, SIGINT].map { sig in
            let source = DispatchSource.makeSignalSource(signal: sig, queue: queue)
            source.setEventHandler {
                stop.set()
                ResidentProcessGuard.scheduleForcedExit(logLabel: "monitor")
            }
            source.resume()
            return source
        }
    }

    private func emitLine<T: Encodable>(_ value: T) {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        guard let data = try? encoder.encode(value),
              let line = String(data: data, encoding: .utf8) else { return }
        MonitorOutput.shared.writeLine(line)
    }

    private func logStderr(_ message: String) {
        MonitorOutput.shared.writeStderr(message)
    }
}

// MARK: - 監視対象・判定結果

/// 台帳の 1 デバイス(監視対象)。internal: ApiListDevicesCommand.swift でも
/// 同じ構造体を使って台帳のデバイスを表す(determineStates と対で共有)
struct MonitorTarget {
    let platform: String  // "ios" / "android"
    let spec: DeviceSpec
    /// 実行プロファイルに実在するか。false は determineStates(includeUnregistered:) が合成した
    /// 起動中デバイス(未登録)。var なのは memberwise init に既定値付きで載せるため
    /// (let + 既定値だと init から除外され registered: false を渡せない)
    var registered: Bool = true

    var name: String { spec.name }
    /// VSCode 拡張側の識別子("ios:simulator1" 等。論理名ベースなのでポート・serial の
    /// 再割当をまたいで安定する)
    /// タイル・ストリーミングの識別子。**ホストを含める** —— 同名のデバイスが別の機械に居るのは
    /// 通常(一意なのは (host, name))で、含めないと拡張側の Map で1つに潰れ、12台の
    /// プロファイルが6タイルになる(2026-08-17 の実害)。手元のデバイスは従来と同じ形にする
    /// (単一マシン構成の id を変えない)
    var id: String {
        DeviceMachineGrouping.workerID(platform: platform, machine: spec.machine, name: spec.name)
    }
}

/// 1 サイクル分のデバイス判定結果。internal: determineStates と一緒に list-devices へ共有
struct DeviceRuntimeState {
    let target: MonitorTarget
    let state: String  // connected / booted / offline
    /// 補足(ポートや serial 等)。無ければ空文字列("")— VSCode 拡張側の契約が
    /// detail: string 固定のため null は使わない
    let detail: String
    /// state == connected(iOS)のときだけ設定。スクリーンショット取得に使う
    let iosPort: UInt16?
    /// state == connected(Android)のときだけ設定。スクリーンショット取得に使う
    let androidSerial: String?
    /// iOS で SimulatorCatalog.resolve が成功した場合(state に関わらず)設定。list-devices が
    /// ブリッジ自動起動(ApiLiveCommand --udid)のために公開する。resolve 失敗時は nil のまま
    let iosUdid: String?
    /// iOS 実機の USB 接続か(devicectl の transportType == "wired")。仮想・Android・不明は nil
    /// (mergedDevices の WiFi 分身の抑制にだけ使う)
    let wired: Bool?

    init(target: MonitorTarget, state: String, detail: String,
        iosPort: UInt16?, androidSerial: String?, iosUdid: String? = nil, wired: Bool? = nil) {
        self.target = target
        self.state = state
        self.detail = detail
        self.iosPort = iosPort
        self.androidSerial = androidSerial
        self.iosUdid = iosUdid
        self.wired = wired
    }

    /// health・renderMode・inRun・recording・frozen は monitor ループだけが知る状態のため引数で受け取る
    /// (list-devices は同じ情報を ApiDeviceEntry として別途組み立てる)
    func info(health: [String]?, renderMode: String?, inRun: Bool,
                          recording: Bool, host: String? = nil,
                          frozen: Bool = false, streamedByOther: Bool? = nil,
                          bridgeRunning: Bool? = nil) -> ApiMonitorDeviceInfo {
        ApiMonitorDeviceInfo(id: target.id, name: target.name,
                             platform: target.platform, state: state, detail: detail,
                             udid: iosUdid, serial: androidSerial, health: health, renderMode: renderMode,
                             inRun: inRun,
                             kind: target.spec.isPhysical ? "physical" : "virtual",
                             host: host, port: iosPort,
                             recording: recording, registered: target.registered,
                             machine: MachineDispatch.normalize(target.spec.machine),
                             frozen: frozen, wired: wired, streamedByOther: streamedByOther,
                             bridgeRunning: bridgeRunning)
    }
}

/// 画面凍結(一様フレーム)の確定判定。**1サンプルでは凍結と言わない** ——
/// 起動直後・遷移中・全面が一色の画面は一瞬だけ一様になるので、`confirmThreshold` 回連続で
/// 一様だったときにだけ確定する(監視サイクルの間隔ぶんデバウンスする受動観測)。
/// **run 前トリアージ(`BlankWorkerTriage`)とは別物**: あちらは 2.5s × 5 サンプルの専用窓 +
/// 能動プローブ(`nudge`)で確定させる。ここは受動観測のみ(run 中は使わない。`frozenVerdict`
/// の `inRun` 参照)。一様でないフレームを1枚見たら即クリアする(復帰を遅らせない)。
///
/// internal: 判定は純粋なのでここだけで単体テストする(MonitorFrozenDebounceTests)。
struct MonitorFrozenDebounce {
    private let confirmThreshold: Int
    private var streaks: [String: Int] = [:]
    private var confirmedIDs: Set<String> = []

    init(confirmThreshold: Int = 2) {
        self.confirmThreshold = max(1, confirmThreshold)
    }

    /// このサイクルのフレーム1枚を記録する。戻り値 = 記録後の確定状態
    @discardableResult
    mutating func record(uniformBlank: Bool, id: String) -> Bool {
        guard uniformBlank else {
            streaks[id] = 0
            confirmedIDs.remove(id)
            return false
        }
        let streak = (streaks[id] ?? 0) + 1
        streaks[id] = streak
        if streak >= confirmThreshold { confirmedIDs.insert(id) }
        return confirmedIDs.contains(id)
    }

    /// PNG が読めなかった等でこのサイクルは判定不能(nil)のとき、
    /// **状態を一切変えず**確定を保つ(撮れなかったサイクルと同じ扱い) ——
    /// 読めないフレームを「一様でない」の証拠にすると、壊れた絵を返し続けるブリッジの台で
    /// 凍結が永久に確定しない
    @discardableResult
    mutating func record(blankness: Bool?, id: String) -> Bool {
        guard let blankness else { return confirmedIDs.contains(id) }
        return record(uniformBlank: blankness, id: id)
    }

    /// 確定状態を**根拠つき**で返す(唯一の読み口)。真偽値ではなく FTCore.FrozenVerdict を
    /// 配ることで、run 側の判定(DeviceFrozenStore)と同じ型で合流できる
    /// `physical` の写し分けは `FrozenVerdict.observe` に委ねる(真偽値を自前で分岐しない)
    func verdict(id: String, physical: Bool = false) -> FrozenVerdict {
        FrozenVerdict.observe(uniformBlank: confirmedIDs.contains(id), physical: physical)
    }

    /// デバイスの記憶を破棄(接続断・デバイス消滅のとき呼ぶ)。
    /// **接続が切れたら忘れる** —— 落ちている機を凍結として数え続けない
    mutating func forget(id: String) {
        streaks.removeValue(forKey: id)
        confirmedIDs.remove(id)
    }
}

/// サイクルをまたいで保持する「直近の確定状態」(debounce 用)。1 デバイス分。
/// internal: debounce と一緒に FleetestTests から検証する(private へ戻さない)。
struct ConfirmedDeviceState {
    let state: String  // connected / booted / offline(debounce 後の確定値)
    let detail: String
    let iosPort: UInt16?
    let androidSerial: String?
    /// iOS の UDID。維持(debounce)中もこれを持ち越さないと leaseKey が nil になり、
    /// 一過性の /status 失敗の間だけ inRun/recording 判定が false に振れる。
    let iosUdid: String?
    /// confirmed が connected の間、observed が connected でなかった連続回数。
    /// connectedDowngradeMissThreshold に達するまでは降格させない
    var missStreak: Int
}

/// stdin 読み取りスレッド・シグナルハンドラ・メインループの間で共有する停止フラグ
/// (ApiRunCommand.swift の DebugControlBox と同様 NSLock で保護する)
final class StopFlag: @unchecked Sendable {
    private let lock = NSLock()
    private var flag = false

    var isSet: Bool {
        lock.lock(); defer { lock.unlock() }
        return flag
    }

    func set() {
        lock.lock(); flag = true; lock.unlock()
    }
}

private struct MonitorControlCommand: Decodable {
    let cmd: String
    /// cmd == "suppressFrames" のときのみ使用
    let devices: [String]?
}
/// **stdout に書く口を1つにする**。子(RemoteMonitorFanout)の中継行は別スレッドから来るので、
/// 親の emitLine と混ざると1行の途中で割り込まれて NDJSON が壊れる。stdio のバッファを
/// 経由せず FileHandle へ直接書くのは、`print` と FileHandle 書き込みが混在すると
/// **バッファの取り合いで行が入れ替わる**ため(どちらか片方に寄せる必要がある)
final class MonitorOutput: @unchecked Sendable {
    static let shared = MonitorOutput()
    private let lock = NSLock()

    func writeLine(_ line: String) {
        lock.lock(); defer { lock.unlock() }
        ConsoleOut.out(line)
    }

    func writeStderr(_ message: String) {
        lock.lock(); defer { lock.unlock() }
        ConsoleOut.err(message)
    }
}


/// pause/resume コマンド(stdin 経由)の状態。stdin 読み取りスレッドとメインループの間で共有する
/// (StopFlag と同様 NSLock で保護する)
private final class MonitorControl: @unchecked Sendable {
    private let lock = NSLock()
    private var paused = false
    private var pausedAt: Date?
    /// resume後、次周回でデバウンス記憶をクリアすべきという指示(単純さ優先で
    /// pause していなかった場合の resume でも一律クリアする)
    private var resetRequested = false
    /// フレーム抑制対象デバイス id の集合(全置換。suppressFrames コマンドで更新)
    private var suppressedFrames: Set<String> = []

    var isPaused: Bool {
        lock.lock(); defer { lock.unlock() }
        return paused
    }

    func pause() {
        lock.lock()
        paused = true
        pausedAt = Date()
        lock.unlock()
    }

    func resume() {
        lock.lock()
        paused = false
        pausedAt = nil
        resetRequested = true
        lock.unlock()
    }

    /// pause 継続時間が limit 秒以上なら自動的に resume 状態にする(安全弁)。実際に発火したら true
    func autoResumeIfStale(limit: TimeInterval) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        guard paused, let pausedAt, Date().timeIntervalSince(pausedAt) >= limit else { return false }
        paused = false
        self.pausedAt = nil
        resetRequested = true
        return true
    }

    /// 保留中のデバウンスリセット要求を取り出す(取り出すと同時にクリアする)
    func takeResetRequest() -> Bool {
        lock.lock()
        defer { lock.unlock() }
        let value = resetRequested
        resetRequested = false
        return value
    }

    /// フレーム抑制対象デバイス集合を全置換する
    /// 戻り値は差し替える前の集合(呼び手が差分をログする)
    @discardableResult
    func setSuppressedFrames(_ ids: Set<String>) -> Set<String> {
        lock.lock(); defer { lock.unlock() }
        let previous = suppressedFrames
        suppressedFrames = ids
        return previous
    }

    func isFrameSuppressed(_ id: String) -> Bool {
        lock.lock(); defer { lock.unlock() }
        return suppressedFrames.contains(id)
    }
}

enum MonitorError: Error, LocalizedError {
    /// ブリッジのポートも撮れる udid/serial も無い(ブリッジ無しの実機・serial 未解決)
    case noEndpoint
    /// `simctl io screenshot` が失敗した、または 15 秒で切った(run に使われて混んでいる形が典型)
    case simctlScreenshotFailed(udid: String)
    /// adb 実行ファイルが見つからない(AndroidDriver.findADB() 参照)
    case adbNotFound
    /// `adb exec-out screencap -p` が失敗した、または締切で切った
    /// (端末のスリープ復帰・USB 切断で adb が刺さった形が典型)
    case androidScreencapFailed(serial: String)

    var errorDescription: String? {
        switch self {
        case .noEndpoint:
            return "no bridge port and no capturable device id"
                + " (a physical device without a bridge, or an unresolved Android serial)"
        case .simctlScreenshotFailed(let udid):
            // **事実だけ言う**(2026-09-09): 以前は「a test run is probably driving it」と書いており、
            // run が始まる2分前(一括起動の最中)の失敗にも同じ推測を断定していた。混んでいる理由は
            // ここからは分からない —— 起こりうる原因だけを候補として並べる
            return "`simctl io screenshot` failed or did not return within 15 s (\(udid))."
                + " Something else is holding the simulator (a run, a bulk start/stop, or a stuck"
                + " simctl); the connection is kept and the next cycle retries"
        case .adbNotFound:
            return "adb not found (set ANDROID_HOME)"
        case .androidScreencapFailed(let serial):
            return "`adb exec-out screencap -p` failed or did not return within"
                + " \(Int(ApiMonitorCommand.androidScreencapTimeoutSeconds)) s (\(serial))."
                + " The device is probably asleep or disconnected"
        }
    }
}
