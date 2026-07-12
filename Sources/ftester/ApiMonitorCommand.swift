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
        abstract: "マシンプロファイルの全デバイス(--profile 指定時はそのプロファイルが参照する"
            + "デバイスのみ)を一定間隔で監視し、状態とスクリーンショットを"
            + "NDJSON(monitorDevices/monitorFrame/monitorError)で stdout に流し続ける"
            + "(診断は stderr のみ。stdin の EOF または SIGTERM/SIGINT で終了)")

    @Option(help: "テストプロジェクト名(省略時: Projects/ が 1 つならそれ / 既定プロジェクト)")
    var project: String?

    @Option(help: "監視サイクルの間隔(秒。既定 2.0)")
    var interval: Double = 2.0

    @Option(name: .customLong("max-width"), help: "スクリーンショットの長辺の最大幅(px。既定 480)")
    var maxWidth: Int = 480

    @Option(help: "実行プロファイル名(指定時はそのプロファイルが参照するデバイスのみ監視する。省略時は マシンプロファイルの全デバイス)")
    var profile: String?

    func run() async throws {
        // ストリーミング読み取りが前提のため常に行バッファにする(ApiRunCommand.swift と同じ理由)
        setvbuf(stdout, nil, _IOLBF, 0)

        let testProject = try ScenarioHost.project(named: project)
        // --profile の machine 明示指定を最優先(ProfileResolver.resolve() と同じ優先順位)
        let machine = try ProfileResolver.determineMachine(
            project: testProject, registered: LocalConfig.currentMachineName(),
            runProfileName: profile)
        if machine.auto {
            logStderr("→ マシンプロファイル自動採用: \(machine.name)(machines/ が 1 つのため)")
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
            throw ValidationError("マシンプロファイル \(machine.name) にデバイスが定義されていません")
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

        while !stop.isSet {
            if control.autoResumeIfStale(limit: Self.pauseSafetyValveSeconds) {
                logStderr(
                    "[monitor] 一時停止から\(Int(Self.pauseSafetyValveSeconds))秒経過したため" +
                    "自動的に再開しました(デバイス操作パネル側の resume 未着信の可能性)")
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

            let observed = await Self.determineStates(targets: targets)
            let states = Self.debounce(observed, confirmed: &confirmed) { message in
                self.logStderr(message)
            }
            emitLine(ApiMonitorDevicesEvent(devices: states.map(\.info)))

            for state in states {
                guard !stop.isSet else { break }
                guard state.state == "connected" else {
                    // 接続が切れたら次回同じエラーが起きても「状態変化」として扱えるよう記憶を消す
                    lastErrorMessage[state.target.id] = nil
                    loggedFetchFailure.remove(state.target.id)
                    continue
                }

                let png: Data
                do {
                    png = try await Self.fetchScreenshot(state: state)
                } catch {
                    // 過渡的競合として扱う: monitorError は出さず stderr ログのみ(同一デバイスで
                    // 連続する間は再ログしない)、フレームは skip(前回フレームが Webview に残る)
                    if !loggedFetchFailure.contains(state.target.id) {
                        logStderr(
                            "[monitor] \(state.target.id) のスクリーンショット取得に失敗しました" +
                            "(接続は維持: テスト実行中の一時的な競合の可能性): \(error.localizedDescription)")
                        loggedFetchFailure.insert(state.target.id)
                    }
                    continue
                }
                loggedFetchFailure.remove(state.target.id)

                do {
                    let jpeg = try MonitorImage.downscaledJPEG(pngData: png, maxWidth: maxWidth)
                    emitLine(ApiMonitorFrameEvent(
                        device: state.target.id,
                        jpegBase64: jpeg.data.base64EncodedString(),
                        width: jpeg.width, height: jpeg.height))
                    lastErrorMessage[state.target.id] = nil
                } catch {
                    // JPEG 変換失敗は接続状態では説明できない異常なので monitorError を出す
                    let message = error.localizedDescription
                    if lastErrorMessage[state.target.id] != message {
                        emitLine(ApiMonitorErrorEvent(device: state.target.id, message: message))
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
    static func determineStates(targets: [MonitorTarget]) async -> [DeviceRuntimeState] {
        async let bridgeStatusesTask = scanBridgeStatuses()
        let simCatalog = (try? SimulatorCatalog.devices()) ?? []
        let runningAVDs = (try? AndroidDeviceCatalog.runningAVDs()) ?? [:]
        // ブート未完了なのに connected 扱いでスクショ取得(=ブリッジAPK自動インストール)を
        // 試みるとパッケージマネージャ未起動で失敗するため、起動中の対象のみブート完了を確認する
        let androidCandidateSerials = Set(targets.compactMap { target -> String? in
            guard target.platform == "android", let avd = target.spec.avd else { return nil }
            let canonical = AndroidDeviceCatalog.canonicalAVDID(avd)
            return runningAVDs.first(where: { $0.value == canonical })?.key
        })
        async let bootCompletedTask = scanBootCompleted(serials: androidCandidateSerials)

        let bridgeStatuses = await bridgeStatusesTask
        let bootCompleted = await bootCompletedTask

        return targets.map { target in
            target.platform == "ios"
                ? iosState(target: target, catalog: simCatalog, bridgeStatuses: bridgeStatuses)
                : androidState(target: target, runningAVDs: runningAVDs, bootCompleted: bootCompleted)
        }
    }

    /// connected からの降格を確定させるまでに要する連続失敗回数(1回の失敗では降格しない)
    private static let connectedDowngradeMissThreshold = 3

    /// pause したまま resume が来ない場合に自動的に resume 扱いにするまでの秒数(安全弁)
    private static let pauseSafetyValveSeconds: TimeInterval = 120
    /// pause 中、resume(または安全弁)を検知するためのポーリング間隔(秒)
    private static let pausedPollSeconds: TimeInterval = 0.2

    /// observed に debounce を適用する。connected への昇格は即時反映。confirmed が connected
    /// だったデバイスが今回そうでない場合は即降格させず、connectedDowngradeMissThreshold 回連続
    /// するまで connected 維持(接続情報も直前値を保持しスクショ取得を試み続ける)。
    /// それ以外の遷移(booted/offline 間)は debounce 不要のため即時反映。
    private static func debounce(
        _ observed: [DeviceRuntimeState],
        confirmed: inout [String: ConfirmedDeviceState],
        onDowngrade logDowngrade: (String) -> Void
    ) -> [DeviceRuntimeState] {
        observed.map { state in
            let id = state.target.id
            if state.state == "connected" {
                confirmed[id] = ConfirmedDeviceState(
                    state: "connected", detail: state.detail,
                    iosPort: state.iosPort, androidSerial: state.androidSerial, missStreak: 0)
                return state
            }
            guard var current = confirmed[id], current.state == "connected" else {
                confirmed[id] = ConfirmedDeviceState(
                    state: state.state, detail: state.detail,
                    iosPort: nil, androidSerial: nil, missStreak: 0)
                return state
            }
            current.missStreak += 1
            if current.missStreak >= connectedDowngradeMissThreshold {
                confirmed[id] = ConfirmedDeviceState(
                    state: state.state, detail: state.detail,
                    iosPort: nil, androidSerial: nil, missStreak: 0)
                logDowngrade(
                    "[monitor] \(id) の接続が途切れました" +
                    "(/status 失敗が \(connectedDowngradeMissThreshold) 回連続したため降格: \(state.state))")
                return state
            }
            confirmed[id] = current
            // 維持中: connected のまま、接続情報(port/serial)も直前の値を使い続ける
            return DeviceRuntimeState(
                target: state.target, state: "connected", detail: current.detail,
                iosPort: current.iosPort, androidSerial: current.androidSerial)
        }
    }

    /// iOS: ブリッジ(127.0.0.1:port)の /status が応答 → connected。
    /// 応答しないが simctl 上で Booted → booted。それ以外 → offline
    private static func iosState(
        target: MonitorTarget, catalog: [SimDeviceInfo],
        bridgeStatuses: [UInt16: StatusResponse]
    ) -> DeviceRuntimeState {
        let sim: SimDeviceInfo
        do {
            sim = try SimulatorCatalog.resolve(spec: target.spec, in: catalog)
        } catch {
            return DeviceRuntimeState(target: target, state: "offline",
                                      detail: error.localizedDescription,
                                      iosPort: nil, androidSerial: nil)
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
                                      detail: "port \(port)", iosPort: port, androidSerial: nil)
        }
        if sim.booted {
            return DeviceRuntimeState(target: target, state: "booted",
                                      detail: "\(sim.name) \(sim.os)",
                                      iosPort: nil, androidSerial: nil)
        }
        return DeviceRuntimeState(target: target, state: "offline", detail: "",
                                  iosPort: nil, androidSerial: nil)
    }

    /// Android: AVD起動+ブート完了 → connected。AVD起動のみ(ブート未完了)→ booted
    /// (ブリッジAPKインストールを試みさせないため)。AVD未起動 → offline
    private static func androidState(
        target: MonitorTarget, runningAVDs: [String: String], bootCompleted: [String: Bool]
    ) -> DeviceRuntimeState {
        guard let avd = target.spec.avd else {
            return DeviceRuntimeState(target: target, state: "offline",
                                      detail: "avd が未設定です",
                                      iosPort: nil, androidSerial: nil)
        }
        let canonical = AndroidDeviceCatalog.canonicalAVDID(avd)
        guard let serial = runningAVDs.first(where: { $0.value == canonical })?.key else {
            return DeviceRuntimeState(target: target, state: "offline", detail: "",
                                      iosPort: nil, androidSerial: nil)
        }
        guard bootCompleted[serial] == true else {
            return DeviceRuntimeState(target: target, state: "booted",
                                      detail: "ブート完了待ち(\(serial))",
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
                group.addTask { (serial, AndroidDeviceCatalog.bootCompleted(serial: serial)) }
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
        timeout: TimeInterval = 1.0
    ) async -> [UInt16: StatusResponse] {
        let portRange = BridgeAPI.defaultPort...(BridgeAPI.defaultPort + 31)
        return await withTaskGroup(
            of: (UInt16, StatusResponse)?.self, returning: [UInt16: StatusResponse].self
        ) { group in
            for port in portRange {
                group.addTask {
                    let client = BridgeClient(port: port, timeoutSeconds: timeout)
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
                    self.logStderr("[monitor] ポーリングを一時停止しました(デバイス操作中)")
                case "resume":
                    control.resume()
                    self.logStderr("[monitor] ポーリングを再開しました")
                default:
                    break
                }
            }
            stop.set()
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
            source.setEventHandler { stop.set() }
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

    var name: String { spec.name }
    /// VSCode 拡張側の識別子("ios:シミュ1" 等。論理名ベースなのでポート・serial の
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

    /// fileprivate: 戻り値の型 ApiMonitorDeviceInfo がファイル限定の private 型のため
    /// (list-devices は同じ情報を ApiDeviceEntry として別途組み立てる)
    fileprivate var info: ApiMonitorDeviceInfo {
        ApiMonitorDeviceInfo(id: target.id, name: target.name,
                             platform: target.platform, state: state, detail: detail)
    }
}

/// サイクルをまたいで保持する「直近の確定状態」(debounce 用)。1 デバイス分
private struct ConfirmedDeviceState {
    let state: String  // connected / booted / offline(debounce 後の確定値)
    let detail: String
    let iosPort: UInt16?
    let androidSerial: String?
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
}

private enum MonitorError: Error, LocalizedError {
    case noConnection

    var errorDescription: String? {
        "接続情報がありません(内部エラー)"
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
}

/// monitorFrame イベント: state == connected のデバイスのみ、スクリーンショットを添えて出す
private struct ApiMonitorFrameEvent: Encodable {
    let kind = "monitorFrame"
    let device: String
    let jpegBase64: String
    let width: Int
    let height: Int
}

/// monitorError イベント: スクリーンショット取得失敗時(状態変化時のみ。連続エラーは抑制)
private struct ApiMonitorErrorEvent: Encodable {
    let kind = "monitorError"
    let device: String
    let message: String
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
            case .decodeFailed: return "スクリーンショットのデコードに失敗しました"
            case .encodeFailed: return "JPEG への変換に失敗しました"
            }
        }
    }

    static func downscaledJPEG(pngData: Data, maxWidth: Int,
                               quality: CGFloat = 0.7) throws -> Result {
        guard let source = CGImageSourceCreateWithData(pngData as CFData, nil) else {
            throw ConvertError.decodeFailed
        }
        let thumbnailOptions: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceThumbnailMaxPixelSize: maxWidth,
            kCGImageSourceCreateThumbnailWithTransform: true,
        ]
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
