// VSCode拡張向け常駐 CLI(ftester api monitor)。マシンプロファイルのデバイスを一定間隔で
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
// 同期相手: vscode-ftester/src/monitorModel.ts (monitorControlLine)
//
// health プローブ: state=connected の Android エミュレータ(実機除く)へ低頻度でヘルス
// チェック(adb/gRPC プローブ+emulator ログの Metal エラー計数)を行い、確定済み異常を devices[].health(異常なし/非対象は省略)に載せる
// (AndroidHealthProbe.swift。同期相手: vscode-ftester/src/monitorModel.ts の health 契約)。
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
import ImageIO
import UniformTypeIdentifiers

struct ApiMonitorCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "monitor",
        abstract: "Poll every device in the machine profile (or, with --profile, only the devices that"
            + " profile references) at a fixed interval and stream their state and screenshots as"
            + " NDJSON (monitorDevices/monitorFrame/monitorError) on stdout"
            + " (diagnostics on stderr only; exits on stdin EOF or SIGTERM/SIGINT)")

    @Option(help: "Test project name (defaults to the only one in TestProjects/, or the default project)")
    var project: String?

    @Option(help: "Interval between monitor cycles in seconds (default 2.0)")
    var interval: Double = 2.0

    @Option(name: .customLong("max-width"), help: "Maximum size of the screenshot long edge in px (default 480)")
    var maxWidth: Int = 480

    @Option(help: "Run profile name (when given, only the devices that profile references are monitored; otherwise every device in the machine profile)")
    var profile: String?

    func run() async throws {
        // ストリーミング読み取りが前提のため常に行バッファにする(ApiRunCommand.swift と同じ理由)
        setvbuf(stdout, nil, _IOLBF, 0)
        ResidentProcessGuard.startOrphanWatchdog(logLabel: "monitor")

        let testProject = try ScenarioHost.project(named: project)
        // --profile の machine 明示指定を最優先(ProfileResolver.resolve() と同じ優先順位)
        let machine = try ProfileResolver.determineMachine(
            project: testProject, registered: LocalConfig.currentMachineName(),
            runProfileName: profile)
        if machine.auto {
            logStderr("→ Using machine profile \(machine.name) automatically (it is the only one in machines/)")
        }
        let machineURL = testProject.machinesDir.appendingPathComponent("\(machine.name).json")
        guard FileManager.default.fileExists(atPath: machineURL.path) else {
            throw ProfileError.machineProfileNotFound(
                machine: machine.name,
                available: ProfileResolver.machineNames(project: testProject))
        }
        let machineProfile: MachineProfile
        do {
            machineProfile = try JSONDecoder().decode(
                MachineProfile.self, from: Data(contentsOf: machineURL))
        } catch {
            throw ProfileError.decodeFailed(machineURL, detail: "\(error)")
        }

        var targets = (machineProfile.ios?.devices ?? []).map {
            MonitorTarget(platform: "ios", spec: $0)
        }
        targets += (machineProfile.android?.devices ?? []).map {
            MonitorTarget(platform: "android", spec: $0)
        }
        guard !targets.isEmpty else {
            throw ValidationError("machine profile \(machine.name) defines no devices")
        }

        // --profile 指定時は、実行プロファイルが参照するデバイスのみに監視対象を絞り込む
        // (RunProfileScope.swift。ftester devices up/down --profile と共通のロジック)
        if let profile {
            let filtered = try RunProfileScope.filteredMachineProfile(
                project: testProject, machineName: machine.name, machineProfile: machineProfile,
                runProfileName: profile, warn: logStderr)
            targets = (filtered.ios?.devices ?? []).map { MonitorTarget(platform: "ios", spec: $0) }
            targets += (filtered.android?.devices ?? []).map { MonitorTarget(platform: "android", spec: $0) }
        }

        let stop = StopFlag()
        let control = MonitorControl()
        startStdinWatcher(stop: stop, control: control)
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
        // GPU/CPU 判定はブート時固定のため接続毎に1回のみ検出しキャッシュする(健全性プローブとは
        // 別間隔。再接続=リブートで変わりうるため切断時に破棄する)
        var renderModeCache: [String: String] = [:]

        // run/recording lease の読み取り用(.ftester/{run,recording}-<key>.lease で inRun/recording を
        // 判定)。best-effort: リポジトリ外実行等で root が取れない場合は両者 false に倒す
        let monitorRepoRoot = try? RepoRoot.find()
        let leaseStateDir = monitorRepoRoot?.appendingPathComponent(".ftester")

        while !stop.isSet {
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
            let observed = await Self.determineStates(targets: targets, includeUnregistered: profile == nil)
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

            emitLine(ApiMonitorDevicesEvent(devices: states.map { state in
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
                    debounce: frozenDebounce, stateDir: leaseStateDir,
                    displayIdleSeconds: state.displayIdleSeconds)
                return state.info(health: confirmedIssues.isEmpty ? nil : confirmedIssues,
                                   renderMode: state.androidSerial.flatMap { renderModeCache[$0] },
                                   inRun: inRun, recording: recording, host: bridgeHost,
                                   frozen: frozenVerdict.isFrozen)
            }))

            // 接続が切れた機の記憶を落とす(次回同じエラーが起きても「状態変化」として扱えるように。
            // 凍結は**落ちている機を数え続けない**ので確定も捨てる)
            for state in states where state.state != "connected" {
                lastErrorMessage[state.target.id] = nil
                loggedFetchFailure.remove(state.target.id)
                frozenDebounce.forget(id: state.target.id)
                lastFrozenProbeAt.removeValue(forKey: state.target.id)
            }

            // 未登録 iOS シミュレータはブリッジが無い(iosPort == nil のまま connected にするため。
            // unregisteredStates 参照)。表示は拡張の simstream helper が udid だけで担うので
            // fetchScreenshot(ブリッジ /screenshot 前提)は毎サイクル失敗するだけ
            let eligible = states.filter { state in
                state.state == "connected" && (state.target.platform != "ios" || state.iosPort != nil)
            }
            // **観測段と配信段の分かれ目はここだけ**。抑制(拡張のタイルがストリーミング表示中)は
            // `deliver` にしか効かない —— 観測まで止めると凍結判定が丸ごと死ぬ(2026-08-11 の実害)
            let plan = Self.capturePlan(ids: eligible.map(\.target.id),
                                        suppressed: { control.isFrameSuppressed($0) },
                                        lastProbeAt: &lastFrozenProbeAt)
            let deliverIDs = Set(plan.filter(\.deliver).map(\.id))
            let plannedIDs = Set(plan.map(\.id))

            for state in eligible where plannedIDs.contains(state.target.id) {
                guard !stop.isSet else { break }

                let png: Data
                do {
                    png = try await Self.fetchScreenshot(state: state)
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
                // 薄める方向に働く)。撮れなかったサイクル(上の continue)では記録しない = 直前の確定を保つ
                frozenDebounce.record(uniformBlank: BlankFrameDetector.isUniformBlank(pngData: png),
                                      id: state.target.id)

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
                    // JPEG 変換失敗(壊れた PNG 等)はタイルへ警告を出さない(ユーザー決定 2026-07-16:
                    // 過渡的でユーザーに対処可能性が無いため)。stderr のみ・同一メッセージ連続中は
                    // 再ログしない。持続するならブリッジ不調のサイン(curl /screenshot で切り分け)
                    let message = error.localizedDescription
                    if lastErrorMessage[state.target.id] != message {
                        logStderr("[monitor] \(state.target.id): \(message) (not notifying the tile)")
                        lastErrorMessage[state.target.id] = message
                    }
                }
            }

            await Self.sleepInterruptible(seconds: interval, stop: stop)
        }
    }

    // MARK: - デバイス状態判定

    /// iOS は simctl 一覧+ブリッジ /status、Android は起動中 AVD 一覧をそれぞれ一括取得して
    /// 各デバイスへ振り分ける(デバイス毎に simctl/adb を叩くと台数に比例して遅くなるため)。
    /// internal: ApiListDevicesCommand.swift が単発の状態判定にも同じロジックを再利用する
    /// includeUnregistered: true のとき、マシンプロファイル未記載でも起動中(iOS booted sim /
    /// Android running AVD)なら合成した DeviceRuntimeState を追加で返す(unregisteredStates 参照。
    /// 実機は対象外)。list-devices(--profile 指定時と同様スコープを絞る意図)は既定 false のまま
    static func determineStates(targets: [MonitorTarget],
                                repoRoot: URL? = try? RepoRoot.find(),
                                includeUnregistered: Bool = false) async -> [DeviceRuntimeState] {
        async let bridgeStatusesTask = scanBridgeStatuses(repoRoot: repoRoot)
        let simCatalog = (try? SimulatorCatalog.devices()) ?? []
        let runningAVDs = (try? AndroidDeviceCatalog.runningAVDs()) ?? [:]
        // 実機は AVD 照合に載らないので adb の接続一覧で見る(エミュレータも含む全 serial)
        let connectedSerials = Set((try? AndroidDeviceCatalog.connectedSerials()) ?? [])
        // ブート未完了なのに connected 扱いでスクショ取得(=ブリッジAPK自動インストール)を
        // 試みるとパッケージマネージャ未起動で失敗するため、起動中の対象のみブート完了を確認する
        let androidCandidateSerials = Set(targets.compactMap { target -> String? in
            guard target.platform == "android" else { return nil }
            // 実機は serial 直指定(接続していれば候補)。エミュレータは AVD 照合で serial を得る
            if target.spec.isPhysical {
                return target.spec.serial.flatMap { connectedSerials.contains($0) ? $0 : nil }
            }
            guard let avd = target.spec.avd else { return nil }
            let canonical = AndroidDeviceCatalog.canonicalAVDID(avd)
            return runningAVDs.first(where: { $0.value == canonical })?.key
        })
        let registeredCanonicalAVDIDs = Set(targets.compactMap { target -> String? in
            guard target.platform == "android", !target.spec.isPhysical, let avd = target.spec.avd
            else { return nil }
            return AndroidDeviceCatalog.canonicalAVDID(avd)
        })
        // includeUnregistered のときは未登録の running AVD の serial もブート完了スキャンに加える
        // (加えないと合成デバイスがブリッジAPK自動インストールを一切試みず永久に booted のまま)
        let unregisteredAndroidSerials: Set<String> = includeUnregistered
            ? Set(runningAVDs.filter { !registeredCanonicalAVDIDs.contains($0.value) }.keys)
            : []
        async let bootCompletedTask = scanBootCompleted(
            serials: androidCandidateSerials.union(unregisteredAndroidSerials))

        let bridgeStatuses = await bridgeStatusesTask
        let bootCompleted = await bootCompletedTask

        let registeredStates = targets.map { target in
            target.platform == "ios"
                ? iosState(target: target, catalog: simCatalog, bridgeStatuses: bridgeStatuses,
                           repoRoot: repoRoot)
                : androidState(target: target, runningAVDs: runningAVDs,
                               connectedSerials: connectedSerials, bootCompleted: bootCompleted)
        }
        guard includeUnregistered else { return registeredStates }

        let registeredIosUdids = Set(registeredStates.compactMap { $0.iosUdid })
        let (unregistered, skipped) = unregisteredStates(
            simCatalog: simCatalog, runningAVDs: runningAVDs, bootCompleted: bootCompleted,
            registeredTargets: targets, registeredIosUdids: registeredIosUdids)
        for message in skipped {
            FileHandle.standardError.write(Data((message + "\n").utf8))
        }
        return registeredStates + unregistered
    }

    /// 未登録(マシンプロファイル未記載)の起動中デバイスを合成する。iOS は booted かつ実機でない
    /// シミュレータのうち registeredIosUdids に無いもの、Android は runningAVDs のうち canonical AVD ID
    /// が registeredTargets の avd に無いもの。実機は対象外(未登録実機は扱わない)。
    /// 合成 id が登録ターゲット(または他の合成デバイス)の id と衝突したらスキップする — 拡張側は id を
    /// 一意キーとして devices を Map 管理するため、重複 id は片方が消える形で表示が壊れる。
    /// I/O を持たない pure 関数(ユニットテスト対象のため private にしない。skipped は呼び出し側が
    /// stderr へログする用のメッセージ)
    static func unregisteredStates(
        simCatalog: [SimDeviceInfo],
        runningAVDs: [String: String],
        bootCompleted: [String: Bool],
        registeredTargets: [MonitorTarget],
        registeredIosUdids: Set<String>
    ) -> (states: [DeviceRuntimeState], skipped: [String]) {
        var usedIds = Set(registeredTargets.map { $0.id })
        var states: [DeviceRuntimeState] = []
        var skipped: [String] = []

        let bootedUnregistered = simCatalog.filter {
            $0.booted && !$0.physical && !registeredIosUdids.contains($0.udid)
        }
        // 未登録同士で同名の booted sim が複数あると合成 id が衝突するため、udid 先頭8桁で一意化する
        var nameCounts: [String: Int] = [:]
        for sim in bootedUnregistered { nameCounts[sim.name, default: 0] += 1 }
        for sim in bootedUnregistered {
            let name = (nameCounts[sim.name] ?? 0) > 1
                ? "\(sim.name) [\(sim.udid.prefix(8))]" : sim.name
            let target = MonitorTarget(
                platform: "ios", spec: DeviceSpec(name: name, os: sim.os, udid: sim.udid),
                registered: false)
            guard !usedIds.contains(target.id) else {
                skipped.append("[monitor] Skipped an unregistered simulator due to an id collision: \(target.id)")
                continue
            }
            usedIds.insert(target.id)
            // connected にする理由: 拡張の画面配信(monitorDeviceStreamController.ts)は
            // state==="connected" のデバイスにしか helper を張らない。未登録シミュレータは
            // udid だけで simstream が動く(ブリッジ不要)ため、booted のままだと
            // 「接続中」スピナーが永久に回る
            states.append(DeviceRuntimeState(
                target: target, state: "connected", detail: "unregistered",
                iosPort: nil, androidSerial: nil, iosUdid: sim.udid))
        }

        let registeredCanonicalAVDIDs = Set(registeredTargets.compactMap { target -> String? in
            guard target.platform == "android", !target.spec.isPhysical, let avd = target.spec.avd
            else { return nil }
            return AndroidDeviceCatalog.canonicalAVDID(avd)
        })
        for (serial, avdID) in runningAVDs where !registeredCanonicalAVDIDs.contains(avdID) {
            let target = MonitorTarget(
                platform: "android", spec: DeviceSpec(name: avdID, avd: avdID), registered: false)
            guard !usedIds.contains(target.id) else {
                skipped.append("[monitor] Skipped an unregistered emulator due to an id collision: \(target.id)")
                continue
            }
            usedIds.insert(target.id)
            if bootCompleted[serial] == true {
                states.append(DeviceRuntimeState(
                    target: target, state: "connected", detail: serial,
                    iosPort: nil, androidSerial: serial))
            } else {
                states.append(DeviceRuntimeState(
                    target: target, state: "booted", detail: "waiting for boot to finish (\(serial))",
                    iosPort: nil, androidSerial: nil))
            }
        }

        return (states, skipped)
    }

    /// connected からの降格を確定させるまでに要する連続失敗回数(1回の失敗では降格しない)
    static let connectedDowngradeMissThreshold = 3

    /// Android ヘルスプローブ(adb 経由)の再実行間隔(秒)。毎サイクル叩くと adb 負荷が
    /// 高いため低頻度化する
    private static let healthProbeIntervalSeconds: TimeInterval = 30

    /// **配信を抑制中のデバイスでも凍結判定のために撮る**間隔(秒)。
    ///
    /// タイルをストリーミング表示しているデバイスは `suppressFrames` でフレーム配信を止めるが、
    /// **観測まで止めてはいけない** —— 2026-08-11 に、抑制のガードが凍結判定より手前にあったため
    /// 実運用の全デバイス(iOS 10 + Android 8)が判定対象から外れ、`Frozen:` が恒久的に 0 になった。
    /// 配信しないぶん cadence だけ落とす(2連続で確定なので最悪 12 秒で出る。凍結は分単位)
    static let frozenProbeIntervalSeconds: TimeInterval = 6

    /// 1サイクルぶんの「撮る/配る」判断。
    /// **純粋関数として切り出してある**のは、「配信を抑制しても観測は続く」という不変条件を
    /// 単体テストで固定するため(MonitorCapturePlanTests)。この不変条件が壊れたのが
    /// 2026-08-11 の凍結カウンタ恒久 0 で、当時は判断がループ本体に埋まっていて誰も試せなかった
    struct CaptureDecision: Equatable {
        let id: String
        /// webview へフレームを配るか。**撮るかどうかとは独立**
        let deliver: Bool
    }

    /// - 非抑制: 毎サイクル撮って配る
    /// - 抑制中: `probeInterval` 間隔で**撮るだけ**(配らない)
    ///
    /// `lastProbeAt` は「撮ると決めた」デバイスだけ更新する(撮らなかった回で時計を進めると
    /// 間隔が延び続ける)
    static func capturePlan(ids: [String],
                            suppressed: (String) -> Bool,
                            lastProbeAt: inout [String: Date],
                            probeInterval: TimeInterval = frozenProbeIntervalSeconds,
                            now: Date = Date()) -> [CaptureDecision] {
        var plan: [CaptureDecision] = []
        for id in ids {
            guard suppressed(id) else {
                lastProbeAt[id] = now
                plan.append(CaptureDecision(id: id, deliver: true))
                continue
            }
            if let last = lastProbeAt[id], now.timeIntervalSince(last) < probeInterval { continue }
            lastProbeAt[id] = now
            plan.append(CaptureDecision(id: id, deliver: false))
        }
        return plan
    }

    /// モニターが配る凍結判定。**3つの根拠を合流させる**:
    ///   ① 自前の観測(一様フレーム。`MonitorFrozenDebounce`)
    ///   ② run が公表した判定(`DeviceFrozenStore`。run 前トリアージが書く)
    ///   ③ 陽性対照の注入(`FrozenInjection`)
    ///
    /// ②を見るのが要点 —— 2026-08-11 に run は9台の凍結を見つけて回復まで走っていたのに、
    /// モニターは自前の観測しか持たず `Frozen: 0` を出し続けた。純粋関数にしてあるのは、
    /// この「run が知っていることをモニターが知る」経路を陽性対照で毎回通すため
    /// 「描画が止まった」と見なす拍動の空き(秒)。
    /// ブリッジのメインスレッドは操作(タップの整定待ち等)で数百 ms 〜 1秒ほど専有されるので、
    /// **通常の操作でまたがない幅**に置く。凍結は分単位なので緩くて構わない
    static let displayIdleFrozenThreshold: Double = 3.0

    static func frozenVerdict(id: String, key: String?,
                              debounce: MonitorFrozenDebounce,
                              stateDir: URL?,
                              displayIdleSeconds: Double? = nil,
                              environment: [String: String] = ProcessInfo.processInfo.environment,
                              now: Date = Date()) -> FrozenVerdict {
        let published = stateDir.flatMap { dir in
            key.flatMap { DeviceFrozenStore.current(stateDir: dir, key: $0, now: now) }
        } ?? .healthy
        let injected = FrozenInjection.isInjected(key: key, environment: environment)
            ? FrozenVerdict([.injected]) : .healthy
        // 拍動は**単独では確定させない**(FrozenEvidence.noPresent.isConclusive == false)。
        // 申告の無いブリッジ(旧版・計器なし)は nil = 根拠にしない
        let present: FrozenVerdict = (displayIdleSeconds ?? 0) > displayIdleFrozenThreshold
            ? FrozenVerdict([.noPresent]) : .healthy
        return debounce.verdict(id: id)
            .merged(with: published).merged(with: injected).merged(with: present)
    }

    /// pause したまま resume が来ない場合に自動的に resume 扱いにするまでの秒数(安全弁)
    private static let pauseSafetyValveSeconds: TimeInterval = 120
    /// pause 中、resume(または安全弁)を検知するためのポーリング間隔(秒)
    private static let pausedPollSeconds: TimeInterval = 0.2

    /// observed に debounce を適用する。connected への昇格は即時反映。confirmed が connected
    /// だったデバイスが今回そうでない場合は即降格させず、connectedDowngradeMissThreshold 回連続
    /// するまで connected 維持(接続情報も直前値を保持しスクショ取得を試み続ける)。
    /// それ以外の遷移(booted/offline 間)は debounce 不要のため即時反映。
    // debounce / androidState は副作用を持たない判定ロジック。FTesterTests から検証するため
    // internal(タイルの点滅・実機の状態判定はデバイス無しで壊せる)。private へ戻さないこと。
    static func debounce(
        _ observed: [DeviceRuntimeState],
        confirmed: inout [String: ConfirmedDeviceState],
        onDowngrade logDowngrade: (String) -> Void
    ) -> [DeviceRuntimeState] {
        observed.map { state in
            let id = state.target.id
            if state.state == "connected" {
                confirmed[id] = ConfirmedDeviceState(
                    state: "connected", detail: state.detail,
                    iosPort: state.iosPort, androidSerial: state.androidSerial,
                    iosUdid: state.iosUdid, missStreak: 0)
                return state
            }
            guard var current = confirmed[id], current.state == "connected" else {
                confirmed[id] = ConfirmedDeviceState(
                    state: state.state, detail: state.detail,
                    iosPort: nil, androidSerial: nil, iosUdid: nil, missStreak: 0)
                return state
            }
            current.missStreak += 1
            if current.missStreak >= connectedDowngradeMissThreshold {
                confirmed[id] = ConfirmedDeviceState(
                    state: state.state, detail: state.detail,
                    iosPort: nil, androidSerial: nil, iosUdid: nil, missStreak: 0)
                logDowngrade(
                    "[monitor] Lost the connection to \(id)" +
                    " (demoted after \(connectedDowngradeMissThreshold) consecutive /status failures: \(state.state))")
                return state
            }
            confirmed[id] = current
            // 維持中: connected のまま、接続情報(port/serial/udid)も直前の値を使い続ける。
            // iosUdid を持ち越さないと leaseKey が nil になり lease 未更新+inRun=false に振れる。
            return DeviceRuntimeState(
                target: state.target, state: "connected", detail: current.detail,
                iosPort: current.iosPort, androidSerial: current.androidSerial,
                iosUdid: current.iosUdid)
        }
    }

    /// iOS: ブリッジ(127.0.0.1:port)の /status が応答 → connected。
    /// 応答しないが simctl 上で Booted → booted。それ以外 → offline
    private static func iosState(
        target: MonitorTarget, catalog: [SimDeviceInfo],
        bridgeStatuses: [UInt16: StatusResponse], repoRoot: URL? = nil
    ) -> DeviceRuntimeState {
        let sim: SimDeviceInfo
        do {
            sim = try SimulatorCatalog.resolve(spec: target.spec, in: catalog)
        } catch {
            return DeviceRuntimeState(target: target, state: "offline",
                                      detail: error.localizedDescription,
                                      iosPort: nil, androidSerial: nil)
        }
        // 実機は /status の device が機種名("iPhone")で返り、マシンプロファイルのデバイス名
        // (例「iPhone wave(実機)」)と一致しない。名前照合では永久に connected にならないので、
        // ランナープロセスの -destination id=<UDID> で帰属を決める。resolve が通っている
        // = 接続済みなので、ブリッジが無くても booted(未接続なら上の catch で offline)
        if target.spec.isPhysical {
            let ports = repoRoot.map { BridgeLauncher.portsMatching(udid: sim.udid, repoRoot: $0) } ?? []
            if let port = ports.first(where: { bridgeStatuses[$0] != nil }) {
                return DeviceRuntimeState(target: target, state: "connected",
                                          detail: "port \(port)", iosPort: port,
                                          androidSerial: nil, iosUdid: sim.udid,
                                          displayIdleSeconds: bridgeStatuses[port]?.displayIdleSeconds)
            }
            return DeviceRuntimeState(target: target, state: "booted",
                                      detail: "\(sim.name) \(sim.os)",
                                      iosPort: nil, androidSerial: nil, iosUdid: sim.udid)
        }
        // /status には UDID が無いため、ブリッジの帰属はデバイス名でしか判定できない。
        // hybrid は同一シミュレータに inapp+xcuitest の2ブリッジが並ぶため、複数一致でも
        // 同名の起動中シミュレータが1台なら全ブリッジがそのシミュレータ帰属と確定できる。
        // その場合は全画面スクショが取れる xcuitest を優先する(in-app はアプリ外を撮れず、
        // アプリ終了で消える)。同名の起動中シミュレータが複数のときは特定不能 = connected にしない
        let matches = bridgeStatuses
            .filter { $0.value.device == sim.name }
            .sorted { $0.key < $1.key }
        let port: UInt16? = {
            if matches.count == 1 { return matches[0].key }
            guard !matches.isEmpty,
                  catalog.filter({ $0.booted && $0.name == sim.name }).count == 1 else { return nil }
            return (matches.first { ($0.value.engine ?? "xcuitest") == "xcuitest" } ?? matches[0]).key
        }()
        if let port {
            return DeviceRuntimeState(target: target, state: "connected",
                                      detail: "port \(port)", iosPort: port, androidSerial: nil,
                                      iosUdid: sim.udid,
                                      displayIdleSeconds: bridgeStatuses[port]?.displayIdleSeconds)
        }
        if sim.booted {
            return DeviceRuntimeState(target: target, state: "booted",
                                      detail: "\(sim.name) \(sim.os)",
                                      iosPort: nil, androidSerial: nil, iosUdid: sim.udid)
        }
        return DeviceRuntimeState(target: target, state: "offline", detail: "",
                                  iosPort: nil, androidSerial: nil, iosUdid: sim.udid)
    }

    /// Android: AVD起動+ブート完了 → connected。AVD起動のみ(ブート未完了)→ booted
    /// (ブリッジAPKインストールを試みさせないため)。AVD未起動 → offline
    static func androidState(
        target: MonitorTarget, runningAVDs: [String: String],
        connectedSerials: Set<String>, bootCompleted: [String: Bool]
    ) -> DeviceRuntimeState {
        // 実機は AVD を持たない。serial 直指定を adb の接続一覧で確認する
        // (avd 前提のままだと実機が永久に「avd が未設定です」で offline になる)
        if target.spec.isPhysical {
            guard let serial = target.spec.serial, connectedSerials.contains(serial) else {
                return DeviceRuntimeState(
                    target: target, state: "offline",
                    detail: target.spec.serial == nil
                        ? "serial is not set"
                        : "not visible to adb (check the USB connection and USB debugging approval)",
                    iosPort: nil, androidSerial: nil)
            }
            guard bootCompleted[serial] == true else {
                return DeviceRuntimeState(target: target, state: "booted",
                                          detail: "waiting for boot to finish (\(serial))",
                                          iosPort: nil, androidSerial: nil)
            }
            return DeviceRuntimeState(target: target, state: "connected", detail: serial,
                                      iosPort: nil, androidSerial: serial)
        }
        guard let avd = target.spec.avd else {
            return DeviceRuntimeState(target: target, state: "offline",
                                      detail: "avd is not set",
                                      iosPort: nil, androidSerial: nil)
        }
        let canonical = AndroidDeviceCatalog.canonicalAVDID(avd)
        guard let serial = runningAVDs.first(where: { $0.value == canonical })?.key else {
            return DeviceRuntimeState(target: target, state: "offline", detail: "",
                                      iosPort: nil, androidSerial: nil)
        }
        guard bootCompleted[serial] == true else {
            return DeviceRuntimeState(target: target, state: "booted",
                                      detail: "waiting for boot to finish (\(serial))",
                                      iosPort: nil, androidSerial: nil)
        }
        return DeviceRuntimeState(target: target, state: "connected", detail: serial,
                                  iosPort: nil, androidSerial: serial)
    }

    /// 起動中(adb 上で device 表示されている)Android 対象の sys.boot_completed を一括スキャンする。
    /// serial 毎に並列で `adb shell getprop` を叩く(scanBridgeStatuses と同じ並行化方針)
    private static func scanBootCompleted(serials: Set<String>) async -> [String: Bool] {
        await withTaskGroup(of: (String, Bool).self, returning: [String: Bool].self) { group in
            for serial in serials {
                group.addTask { (serial, await AndroidDeviceCatalog.bootCompleted(serial: serial)) }
            }
            var result: [String: Bool] = [:]
            for await (serial, completed) in group {
                result[serial] = completed
            }
            return result
        }
    }

    /// 起動中ブリッジの一括スキャン。ポート毎に短いタイムアウトで並列に /status を叩く
    /// (offline デバイスの判定でループが遅くならないよう既定 1 秒に抑える)
    private static func scanBridgeStatuses(
        timeout: TimeInterval = 1.0, repoRoot: URL? = nil
    ) async -> [UInt16: StatusResponse] {
        let portRange = BridgeAPI.defaultPort...(BridgeAPI.defaultPort + 31)
        return await withTaskGroup(
            of: (UInt16, StatusResponse)?.self, returning: [UInt16: StatusResponse].self
        ) { group in
            for port in portRange {
                group.addTask {
                    // LAN 経由の実機ブリッジは 127.0.0.1 に居ない。establish が残した宛先を使う
                    // (記録が無ければループバック = シミュレータ・USB トンネル・Android の既定)
                    let host = repoRoot.map { BridgeEndpoint.load(port: port, repoRoot: $0).host }
                        ?? BridgeEndpoint.loopbackHost
                    let client = BridgeClient(port: port, timeoutSeconds: timeout, host: host)
                    guard let status = try? await client.status(), status.ready else { return nil }
                    return (port, status)
                }
            }
            var result: [UInt16: StatusResponse] = [:]
            for await entry in group {
                if let (port, status) = entry { result[port] = status }
            }
            return result
        }
    }

    /// state==connected のデバイスのスクリーンショットを取得する(PNG。JPEG 変換は呼び出し側)
    private static func fetchScreenshot(state: DeviceRuntimeState) async throws -> Data {
        if state.target.platform == "ios" {
            guard let port = state.iosPort else { throw MonitorError.noConnection }
            return try await BridgeClient(port: port, timeoutSeconds: 5).screenshot()
        }
        guard let serial = state.androidSerial else { throw MonitorError.noConnection }
        return try await AndroidDriver(serial: serial).screenshot()
    }

    /// SIGTERM/SIGINT/EOF を最大 0.1 秒粒度で検知しながら interval 秒待つ
    /// (待ち時間いっぱい固まって終了が遅れないようにするため)
    private static func sleepInterruptible(seconds: Double, stop: StopFlag) async {
        var remaining = seconds
        while remaining > 0, !stop.isSet {
            try? await Task.sleep(nanoseconds: 100_000_000)
            remaining -= 0.1
        }
    }

    // MARK: - 終了検知・制御コマンド受信(stdin / シグナル)

    /// EOF検知で停止フラグを立てる。readLine はブロッキングなので別スレッドで読み続ける
    /// (ApiRunCommand.swift の --debug stdin 制御読み取りと同じ方式)
    private func startStdinWatcher(stop: StopFlag, control: MonitorControl) {
        let thread = Thread {
            while let line = readLine(strippingNewline: true) {
                guard let data = line.data(using: .utf8),
                      let command = try? JSONDecoder().decode(MonitorControlCommand.self, from: data)
                else { continue }
                switch command.cmd {
                case "pause":
                    control.pause()
                    self.logStderr("[monitor] Polling paused (device operation in progress)")
                case "resume":
                    control.resume()
                    self.logStderr("[monitor] Polling resumed")
                case "suppressFrames":
                    let ids = Set(command.devices ?? [])
                    control.setSuppressedFrames(ids)
                    self.logStderr(
                        "[monitor] Updated the frame-suppression targets" +
                        " (\(ids.count) device(s): \(ids.sorted().joined(separator: ", ")))")
                default:
                    break
                }
            }
            stop.set()
            ResidentProcessGuard.scheduleForcedExit(logLabel: "monitor")
        }
        thread.name = "ftester-api-monitor-stdin"
        thread.start()
    }

    /// SIGTERM/SIGINT を捕捉して停止フラグを立てる(既定の即時終了を上書きし、ループの
    /// 区切りでクリーンに終了できるようにする)。戻り値はループを抜けるまで呼び出し側が
    /// 保持すること(DispatchSourceSignal は解放されるとハンドラが外れる)
    private func installSignalHandlers(stop: StopFlag) -> [DispatchSourceSignal] {
        signal(SIGTERM, SIG_IGN)
        signal(SIGINT, SIG_IGN)
        let queue = DispatchQueue(label: "ftester-api-monitor-signal")
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
        print(line)
    }

    private func logStderr(_ message: String) {
        FileHandle.standardError.write(Data((message + "\n").utf8))
    }
}

// MARK: - 監視対象・判定結果

/// マシンプロファイルの 1 デバイス(監視対象)。internal: ApiListDevicesCommand.swift でも
/// 同じ構造体を使ってマシンプロファイルのデバイスを表す(determineStates と対で共有)
struct MonitorTarget {
    let platform: String  // "ios" / "android"
    let spec: DeviceSpec
    /// マシンプロファイルに実在するか。false は determineStates(includeUnregistered:) が合成した
    /// 起動中デバイス(未登録)。var なのは memberwise init に既定値付きで載せるため
    /// (let + 既定値だと init から除外され registered: false を渡せない)
    var registered: Bool = true

    var name: String { spec.name }
    /// VSCode 拡張側の識別子("ios:simulator1" 等。論理名ベースなのでポート・serial の
    /// 再割当をまたいで安定する)
    var id: String { "\(platform):\(spec.name)" }
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
    /// ブリッジが申告する「最後に画面が進んでからの秒数」(BridgeDTO.StatusResponse 参照)。
    /// **維持(debounce)中は運ばない** —— 古い拍動を根拠にすると、通信が一瞬切れただけで
    /// 「描画が止まった」と言い出す。不明(nil)は根拠なしに倒す
    let displayIdleSeconds: Double?

    init(target: MonitorTarget, state: String, detail: String,
        iosPort: UInt16?, androidSerial: String?, iosUdid: String? = nil,
        displayIdleSeconds: Double? = nil) {
        self.target = target
        self.state = state
        self.detail = detail
        self.iosPort = iosPort
        self.androidSerial = androidSerial
        self.iosUdid = iosUdid
        self.displayIdleSeconds = displayIdleSeconds
    }

    /// fileprivate: 戻り値の型 ApiMonitorDeviceInfo がファイル限定の private 型のため
    /// (list-devices は同じ情報を ApiDeviceEntry として別途組み立てる)。
    /// health・renderMode・inRun・recording・frozen は monitor ループだけが知る状態のため引数で受け取る
    fileprivate func info(health: [String]?, renderMode: String?, inRun: Bool,
                          recording: Bool, host: String? = nil,
                          frozen: Bool = false) -> ApiMonitorDeviceInfo {
        ApiMonitorDeviceInfo(id: target.id, name: target.name,
                             platform: target.platform, state: state, detail: detail,
                             udid: iosUdid, serial: androidSerial, health: health, renderMode: renderMode,
                             inRun: inRun,
                             kind: target.spec.isPhysical ? "physical" : "virtual",
                             host: host, port: iosPort,
                             recording: recording, registered: target.registered, frozen: frozen)
    }
}

/// 画面凍結(一様フレーム)の確定判定。**1サンプルでは凍結と言わない** ——
/// 起動直後・遷移中・全面が一色の画面は一瞬だけ一様になるので、`confirmThreshold` 回連続で
/// 一様だったときにだけ確定する(run 前トリアージの `BlankWorkerTriage` が 1.5s 間隔で
/// 2連続を要求するのと同じ規律。あちらは専用サンプリング、こちらは監視サイクルが間隔になる)。
/// 一様でないフレームを1枚見たら即クリアする(復帰を遅らせない)。
///
/// internal: 判定は純粋なのでここだけで単体テストする(ApiMonitorFrozenDebounceTests)。
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

    /// 現在の確定状態(記録の無いデバイスは false)
    func isFrozen(id: String) -> Bool { confirmedIDs.contains(id) }

    /// 確定状態を**根拠つき**で返す。真偽値ではなく FTCore.FrozenVerdict を配ることで、
    /// run 側の判定(DeviceFrozenStore)と同じ型で合流できる
    func verdict(id: String) -> FrozenVerdict {
        confirmedIDs.contains(id) ? FrozenVerdict([.uniformBlank]) : .healthy
    }

    /// 確定済みの件数(モニターのヘッダに出す「Frozen: N」)
    var frozenCount: Int { confirmedIDs.count }

    /// デバイスの記憶を破棄(接続断・デバイス消滅のとき呼ぶ)。
    /// **接続が切れたら忘れる** —— 落ちている機を凍結として数え続けない
    mutating func forget(id: String) {
        streaks.removeValue(forKey: id)
        confirmedIDs.remove(id)
    }
}

/// サイクルをまたいで保持する「直近の確定状態」(debounce 用)。1 デバイス分。
/// internal: debounce と一緒に FTesterTests から検証する(private へ戻さない)。
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
private final class StopFlag: @unchecked Sendable {
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
    func setSuppressedFrames(_ ids: Set<String>) {
        lock.lock()
        suppressedFrames = ids
        lock.unlock()
    }

    func isFrameSuppressed(_ id: String) -> Bool {
        lock.lock(); defer { lock.unlock() }
        return suppressedFrames.contains(id)
    }
}

private enum MonitorError: Error, LocalizedError {
    case noConnection

    var errorDescription: String? {
        "no connection info (internal error)"
    }
}

// MARK: - JSON イベント

/// monitorDevices イベント: サイクル毎に1回、全デバイスの状態をまとめて出す
private struct ApiMonitorDevicesEvent: Encodable {
    let kind = "monitorDevices"
    let devices: [ApiMonitorDeviceInfo]
}

/// ftester api monitor の 1 デバイス分の状態。detail は補足が無ければ空文字列("")にする
/// (VSCode 拡張側(monitorModel.ts)の契約が detail: string 固定のため null は使わない。
/// ApiScenarioInfo 等の「省略可能フィールドは null を明示する」方針とは別)
private struct ApiMonitorDeviceInfo: Encodable {
    let id: String
    let name: String
    let platform: String
    let state: String
    let detail: String
    /// iOS の解決済みシミュレータ UDID(デバイスタブの ftester-simstream 画面ストリーミングに使う)。Android は nil。
    let udid: String?
    /// Android の adb serial(デバイスタブの ftester-androidstream 画面ストリーミングに使う)。iOS は nil。
    let serial: String?
    /// AndroidHealthProbe で確定した異常の識別子一覧。異常なし・非対象(iOS/実機/未接続)は nil
    let health: [String]?
    /// AndroidHealthProbe.detectRenderMode で検出した実描画モード("gpu"=host/Metal、"cpu"=swiftshader)。
    /// connected な Android のみ。iOS・実機・未検出は nil
    let renderMode: String?
    /// run-lease(RunLease.isFresh)が生存中なら true。ftester api run がこのデバイスを使用中の意味。
    /// leaseStateDir 未解決時は常に false
    let inRun: Bool
    /// デバイスの実体種別("virtual" / "physical")。iOS 実機は ftester-simstream が
    /// CoreSimulator 私有 API のため画面配信できない等、扱いが変わるので拡張側が分岐する
    let kind: String
    /// iOS ブリッジの宛先ホスト。シミュレータ・USB トンネルは "127.0.0.1"、LAN 経由の実機は
    /// その LAN IP。拡張が ftester-devicepoll の --host に渡す。Android は nil
    let host: String?
    /// iOS ブリッジの実効ポート(connected のときのみ)。拡張が ftester-devicepoll の --port に渡す。
    /// Android・未接続は nil(list-devices の port と同じ値)
    let port: UInt16?
    /// recording-lease(RecordingLease.isFresh)が生存中なら true。run profile の record:true で
    /// このデバイスの動画録画(VideoRecordingCoordinator)が進行中の意味。leaseStateDir 未解決時は常に false
    let recording: Bool
    /// マシンプロファイルに実在するか。false は determineStates(includeUnregistered:) が合成した
    /// 起動中デバイス(未登録)。追加フィールドのみで後方互換のため ProtocolVersion は不変
    /// (契約は vscode-ftester/src/monitorDeviceModel.ts の MonitorDevice.registered)
    let registered: Bool
    /// 画面が凍結している(一様フレームが2サイクル連続)。**この値は1サイクル遅れる** ——
    /// devices イベントはフレーム取得より前に出るため、判定に使うのは前サイクルの PNG。
    /// スクショを撮らないデバイス(未接続・タイルがストリーミング中で frame 抑止・
    /// ブリッジ不在)は最後の確定値を保つ(黙って false に戻すと凍結が画面から消える)。
    /// 契約は vscode-ftester/src/monitorDeviceModel.ts の MonitorDevice.frozen
    let frozen: Bool
}

/// monitorFrame イベント: state == connected のデバイスのみ、スクリーンショットを添えて出す
private struct ApiMonitorFrameEvent: Encodable {
    let kind = "monitorFrame"
    let device: String
    let jpegBase64: String
    let width: Int
    let height: Int
}

// MARK: - 画像変換

/// 生PNGの base64 は1フレーム数MBになり Webview に流せないため maxWidth px にダウンスケールして
/// JPEG化する。private を外して ApiLiveCommand.swift にも共有する
enum MonitorImage {
    struct Result {
        let data: Data
        let width: Int
        let height: Int
    }

    enum ConvertError: Error, LocalizedError {
        case decodeFailed
        case encodeFailed

        var errorDescription: String? {
            switch self {
            case .decodeFailed: return "failed to decode the screenshot"
            case .encodeFailed: return "failed to encode to JPEG"
            }
        }
    }

    /// maxWidth が 0 以下なら縮小せず原寸で JPEG 化する(ライブ操作の原寸表示用。
    /// モニタータイルは従来どおり正の値でダウンスケールする)
    static func downscaledJPEG(pngData: Data, maxWidth: Int,
                               quality: CGFloat = 0.7) throws -> Result {
        guard let source = CGImageSourceCreateWithData(pngData as CFData, nil) else {
            throw ConvertError.decodeFailed
        }
        var thumbnailOptions: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
        ]
        if maxWidth > 0 {
            thumbnailOptions[kCGImageSourceThumbnailMaxPixelSize] = maxWidth
        }
        guard let thumbnail = CGImageSourceCreateThumbnailAtIndex(
            source, 0, thumbnailOptions as CFDictionary) else {
            throw ConvertError.decodeFailed
        }

        let output = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(
            output, UTType.jpeg.identifier as CFString, 1, nil) else {
            throw ConvertError.encodeFailed
        }
        let destinationOptions: [CFString: Any] = [
            kCGImageDestinationLossyCompressionQuality: quality
        ]
        CGImageDestinationAddImage(destination, thumbnail, destinationOptions as CFDictionary)
        guard CGImageDestinationFinalize(destination) else {
            throw ConvertError.encodeFailed
        }
        return Result(data: output as Data, width: thumbnail.width, height: thumbnail.height)
    }
}
