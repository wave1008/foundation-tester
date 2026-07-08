// AppModel.swift
// GUI の状態管理。シナリオ実行は ftester-scenarios サブプロセス(ScenarioHost)、
// 探索・ライブ操作は既存モジュール(ExplorerAgent / BridgeClient / AndroidDriver)を使う。

import AppKit
import Foundation
import FTAgent
import FTAndroid
import FTBridgeClient
import FTCore
import FTDSL
import Observation

@MainActor
@Observable
final class AppModel {

    // MARK: - 設定(設定ペインで編集、UserDefaults に永続化)

    /// ブリッジに割り当てるポートの開始番号(iOS ブリッジ専用)
    var portRangeStartText: String {
        didSet { UserDefaults.standard.set(portRangeStartText, forKey: "portRangeStart") }
    }
    /// 最大並列数 = 開始ポートから確保するポート数(スキャン・割り当ての上限)
    var maxParallel: Int {
        didSet { UserDefaults.standard.set(maxParallel, forKey: "maxParallel") }
    }

    /// スキャン対象のポート一覧: 開始ポートから最大並列数ぶん
    /// (不正入力は既定 8123 に、並列数は 1〜32 に丸める)
    var portRange: [UInt16] {
        var start = Int(portRangeStartText.trimmingCharacters(in: .whitespaces)) ?? 8123
        if !(1024...65535).contains(start) { start = 8123 }
        let count = min(max(maxParallel, 1), 32)
        let end = min(start + count - 1, 65535)
        return (start...end).map { UInt16($0) }
    }

    // MARK: - 対象デバイス(iOS/Android を同時に扱う)

    /// ライブ操作・FM探索の対象、および並列実行のワーカー元。refreshTargets() が発見する
    struct DriveTarget: Identifiable, Hashable {
        let id: String        // "ios:8123" / "android:emulator-5554"
        let platform: String  // "ios" / "android"
        let port: UInt16?     // iOS のみ(Android にポートの概念はない)
        let serial: String?   // Android のみ(adb のシリアル名)
        let name: String      // 表示名(デバイス名)
        /// 表示用ラベル。Android の "emulator-5554" は adb のシリアル名であって
        /// ftester が割り当てたポートではないため、ポート風に見えない表記にする
        var label: String {
            platform == "android"
                ? "Android — \(name)(\(serial ?? "adb"))"
                : "\(id) — \(name)"
        }
    }

    var targets: [DriveTarget] = []
    var selectedTargetID: String?
    var selectedTarget: DriveTarget? {
        targets.first { $0.id == selectedTargetID } ?? targets.first
    }

    var connectionStatus = "未確認"
    var connected = false
    /// ポート毎の /status 結果(スキャンで更新。モニターのウィンドウ照合にも使う)
    var portStatuses: [UInt16: StatusResponse] = [:]

    /// ポート範囲を並行スキャンして iOS ブリッジを、adb devices から Android デバイスを発見する
    func refreshTargets() async {
        // iOS: 範囲内の全ポートへ短タイムアウトで /status
        let range = portRange
        var statuses: [UInt16: StatusResponse] = [:]
        await withTaskGroup(of: (UInt16, StatusResponse?).self) { group in
            for port in range {
                group.addTask {
                    (port, try? await BridgeClient(port: port, timeoutSeconds: 3).status())
                }
            }
            for await (port, status) in group {
                if let status, status.ready { statuses[port] = status }
            }
        }
        portStatuses = statuses

        var found: [DriveTarget] = statuses.sorted { $0.key < $1.key }.map { port, status in
            DriveTarget(id: "ios:\(port)", platform: "ios", port: port, serial: nil,
                        name: status.device)
        }
        // Android: 接続中の全デバイス。名前は adb devices -l の model: から取る
        // (デバイス個別の shell は ANR 中の端末で無期限にハングし得るため使わない)
        for (serial, model) in Self.adbDevices() {
            found.append(DriveTarget(id: "android:\(serial)", platform: "android",
                                     port: nil, serial: serial, name: model ?? serial))
        }
        targets = found
        // 選択が無効になったら先頭を自動選択(ピッカーの空欄防止)
        if targets.first(where: { $0.id == selectedTargetID }) == nil {
            selectedTargetID = targets.first?.id
        }

        let iosCount = statuses.count
        let androidCount = found.count - iosCount
        connected = !found.isEmpty
        connectionStatus = found.isEmpty
            ? "デバイスなし — 設定ペインからブリッジを起動"
            : "iOS \(iosCount) 台 / Android \(androidCount) 台"
    }

    /// adb devices -l の (serial, model) 一覧。デバイス個別シェルを使わないため安全
    static func adbDevices() -> [(serial: String, model: String?)] {
        guard let driver = try? AndroidDriver(),
              let result = try? Shell.run([driver.adbPath, "devices", "-l"]), result.status == 0 else {
            return []
        }
        return result.output.split(separator: "\n").dropFirst().compactMap { line in
            let fields = line.split(separator: " ", omittingEmptySubsequences: true)
            guard fields.count >= 2, fields[1] == "device" else { return nil }
            let model = fields.first { $0.hasPrefix("model:") }
                .map { String($0.dropFirst("model:".count)) }
            return (String(fields[0]), model)
        }
    }

    struct NoTargetError: LocalizedError {
        var errorDescription: String? {
            "対象デバイスがありません(設定ペインからブリッジを起動するか、エミュレータを接続してください)"
        }
    }

    // MARK: - シナリオ実行

    struct ScenarioEntry: Identifiable {
        let info: ScenarioInfo
        var state: RunState = .idle
        var id: URL { ScenarioRunItem.url(for: info.id) }
    }

    enum RunState {
        case idle, running, passed, failed
    }

    /// ワーカー毎のログレーン(並列実行時の混線防止。1ワーカーなら従来と同じ1列)
    struct WorkerLane: Identifiable {
        let id: String       // ワーカーラベル("ios:8123" / "android" / "system")
        var title: String
        var log: [String] = []
        var running = false
    }

    var scenarios: [ScenarioEntry] = []
    var selectedScenarioID: URL?
    var heal = false
    var runningFlow = false
    var lanes: [WorkerLane] = []
    /// シナリオ一覧のビルド/読込状態(nil = 正常)
    var scenarioListStatus: String?

    var selectedEntry: ScenarioEntry? {
        scenarios.first { $0.id == selectedScenarioID }
    }

    // MARK: - ライブ操作

    var screenshot: NSImage?
    var screenSize: FTRect?
    var elements: [ElementInfo] = []
    var liveBusy = false
    var liveError: String?
    var bundleID = "com.example.sampleapp"

    /// インストールするパッケージファイルのパス(プラットフォーム別に保持、UserDefaults に永続化)
    var iosPackagePath: String {
        didSet { UserDefaults.standard.set(iosPackagePath, forKey: "iosPackagePath") }
    }
    var androidPackagePath: String {
        didSet { UserDefaults.standard.set(androidPackagePath, forKey: "androidPackagePath") }
    }

    // MARK: - FM 探索

    var exploreGoal = ""
    var exploreBundleID = "com.example.sampleapp"
    var exploreMaxSteps = 25
    var exploreLog: [String] = []
    var exploring = false
    private var exploreTask: Task<Void, Never>?

    let fmReport = FMDoctor.check()

    // MARK: - デバイスモニター(ScreenCaptureKit)/ ブリッジ管理

    let monitor = DeviceMonitorCenter()
    let bridgeManager = BridgeManagerModel()

    init() {
        // FT_PORTS 環境変数("8123-8130" または "8123,8124")→ UserDefaults → 既定値 の順
        let defaults = UserDefaults.standard
        iosPackagePath = defaults.string(forKey: "iosPackagePath") ?? ""
        androidPackagePath = defaults.string(forKey: "androidPackagePath") ?? ""
        if let env = ProcessInfo.processInfo.environment["FT_PORTS"],
           let (start, end) = Self.parseRange(env) {
            portRangeStartText = String(start)
            maxParallel = min(max(end - start + 1, 1), 32)
        } else {
            let startText = defaults.string(forKey: "portRangeStart") ?? "8123"
            portRangeStartText = startText
            if defaults.object(forKey: "maxParallel") != nil {
                maxParallel = min(max(defaults.integer(forKey: "maxParallel"), 1), 32)
            } else if let end = Int(defaults.string(forKey: "portRangeEnd") ?? ""),
                      let start = Int(startText) {
                // 旧「終了ポート」設定からの移行
                maxParallel = min(max(end - start + 1, 1), 32)
            } else {
                maxParallel = 8
            }
        }
        monitor.statusProvider = { [weak self] in self?.portStatuses ?? [:] }
    }

    static func parseRange(_ text: String) -> (Int, Int)? {
        let trimmed = text.trimmingCharacters(in: .whitespaces)
        if let dash = trimmed.firstIndex(of: "-") {
            guard let start = Int(trimmed[..<dash]),
                  let end = Int(trimmed[trimmed.index(after: dash)...]) else { return nil }
            return (start, end)
        }
        let numbers = trimmed.split(separator: ",")
            .compactMap { Int($0.trimmingCharacters(in: .whitespaces)) }
        guard let minPort = numbers.min(), let maxPort = numbers.max() else { return nil }
        return (minPort, maxPort)
    }

    // MARK: - ドライバ

    /// ライブ操作・FM探索用: 選択中の対象デバイスのドライバ
    func makeSelectedDriver() throws -> AppDriver {
        guard let target = selectedTarget else { throw NoTargetError() }
        return try makeDriver(for: target)
    }

    func makeDriver(for target: DriveTarget) throws -> AppDriver {
        switch target.platform {
        case "android":
            return try AndroidDriver(serial: target.serial)
        default:
            return BridgeClient(port: target.port ?? BridgeAPI.defaultPort)
        }
    }

    // MARK: - シナリオ一覧

    /// シナリオをビルドして一覧を取得する(ftester-scenarios サブプロセス経由)
    func refreshScenarios() async {
        scenarioListStatus = "シナリオをビルド中..."
        let result: Result<[ScenarioInfo], Error> = await Task.detached {
            do {
                try ScenarioHost.build()
                return .success(try ScenarioHost.list())
            } catch {
                return .failure(error)
            }
        }.value

        switch result {
        case .success(let infos):
            let states = Dictionary(uniqueKeysWithValues: scenarios.map { ($0.id, $0.state) })
            scenarios = infos.map { info in
                ScenarioEntry(info: info,
                              state: states[ScenarioRunItem.url(for: info.id)] ?? .idle)
            }
            scenarioListStatus = nil
        case .failure(let error):
            scenarioListStatus = "⚠️ \(error.localizedDescription)"
        }
        // 選択が無効になったら先頭を自動選択
        if scenarios.first(where: { $0.id == selectedScenarioID }) == nil {
            selectedScenarioID = scenarios.first?.id
        }
    }

    private func setState(_ url: URL, _ state: RunState) {
        guard let index = scenarios.firstIndex(where: { $0.id == url }) else { return }
        scenarios[index].state = state
    }

    func runSelected() async {
        guard let entry = selectedEntry else { return }
        await runScenarios([entry])
    }

    func runAll() async {
        await runScenarios(scenarios)
    }

    /// シナリオ群を実行する。iOS はブリッジ毎、Android はデバイス毎のワーカーで並列消化する
    /// (CLI の run --ports と同じオーケストレータ。実行の実体はサブプロセス)。
    func runScenarios(_ entries: [ScenarioEntry]) async {
        guard !runningFlow, !entries.isEmpty else { return }
        runningFlow = true

        // 実行前にシナリオを最新化(ビルドはホスト側で1回だけ)
        await refreshScenarios()
        if scenarioListStatus != nil {
            lanes = [WorkerLane(id: "system", title: "⚠️ ビルド失敗",
                                log: [scenarioListStatus ?? ""])]
            runningFlow = false
            return
        }

        // 稼働中のブリッジ・デバイスを再スキャンして動的にワーカーを割り当てる
        await refreshTargets()
        monitor.rematch()

        let items = entries.map { ScenarioRunItem(info: $0.info) }
        let iosItems = items.filter { ($0.info.platform ?? "ios") == "ios" }
        let androidItems = items.filter { ($0.info.platform ?? "ios") == "android" }

        var workers: [RunWorker] = []
        if !iosItems.isEmpty {
            let bridges = targets.filter { $0.platform == "ios" }
            // シナリオ数を超えるワーカーは立てない(余分なウォームアップ回避)
            for target in bridges.prefix(min(bridges.count, iosItems.count)) {
                guard let port = target.port else { continue }
                workers.append(RunWorker(label: target.id, platform: "ios",
                                         driver: BridgeClient(port: port),
                                         connection: DriverConnection(platform: "ios", port: port)))
            }
        }
        if !androidItems.isEmpty {
            // Android もデバイス(adb シリアル)毎にワーカーを立てて並列実行する
            // (adb -s で分離され、AndroidDriver の状態ファイルもシリアル別)
            let androidTargets = targets.filter { $0.platform == "android" }
            for target in androidTargets.prefix(min(androidTargets.count, androidItems.count)) {
                guard let driver = try? AndroidDriver(serial: target.serial) else { continue }
                workers.append(RunWorker(label: target.id, platform: "android", driver: driver,
                                         connection: DriverConnection(platform: "android",
                                                                      serial: target.serial)))
            }
        }

        lanes = workers.map { worker in
            let target = targets.first { $0.id == worker.label }
            return WorkerLane(id: worker.label, title: target?.label ?? worker.label)
        }

        let orchestrator = RunOrchestrator(workers: workers, healingEnabled: heal,
                                           reportDir: URL(fileURLWithPath: "reports"))
        // イベントは MainActor 上で順に消費する(レーン追記とシナリオ状態の更新)
        let consumer = Task { @MainActor [weak self] in
            for await event in orchestrator.events {
                self?.handle(event)
            }
        }
        _ = await orchestrator.run(items: items, defaultPlatform: "ios")
        await consumer.value
        runningFlow = false
    }

    private func handle(_ event: RunEvent) {
        let lines = RunLogFormatter.lines(for: event)
        switch event {
        case .runStarted, .runFinished:
            break
        case .workerReady(let worker):
            appendLane(worker, ["🟢 ワーカー準備完了"])
        case .workerFailed(let worker, _):
            appendLane(worker, lines)
            setLaneRunning(worker, false)
        case .flowStarted(let worker, let url, _, _):
            setState(url, .running)
            setLaneRunning(worker, true)
            appendLane(worker, lines)
        case .step(let worker, _, _):
            appendLane(worker, lines)
        case .flowHealed(let worker, _):
            appendLane(worker, lines)
        case .flowFinished(let worker, let url, let passed, _, _):
            setState(url, passed ? .passed : .failed)
            setLaneRunning(worker, false)
            appendLane(worker, lines)
        case .flowSkipped(let url, _):
            setState(url, .failed)
            appendLane("system", lines)
        }
    }

    private func appendLane(_ worker: String, _ lines: [String]) {
        guard !lines.isEmpty else { return }
        if let index = lanes.firstIndex(where: { $0.id == worker }) {
            lanes[index].log.append(contentsOf: lines)
        } else {
            // ワーカー不在のフロー通知など、行き先のない行のための予備レーン
            lanes.append(WorkerLane(id: worker, title: "⚠️ 未実行", log: lines))
        }
    }

    private func setLaneRunning(_ worker: String, _ running: Bool) {
        guard let index = lanes.firstIndex(where: { $0.id == worker }) else { return }
        lanes[index].running = running
    }

    func clearLanes() {
        lanes = []
    }

    // MARK: - ライブ操作

    func refreshLive() async {
        liveBusy = true
        liveError = nil
        do {
            let driver = try makeSelectedDriver()
            let png = try await driver.screenshot()
            screenshot = NSImage(data: png)
            let snap = try await driver.snapshot()
            elements = snap.elements
            screenSize = snap.screen
        } catch {
            liveError = error.localizedDescription
        }
        liveBusy = false
    }

    private func liveAction(_ body: @escaping (AppDriver) async throws -> Void) async {
        liveBusy = true
        liveError = nil
        do {
            let driver = try makeSelectedDriver()
            try await body(driver)
            try? await Task.sleep(nanoseconds: 700_000_000)
        } catch {
            liveError = error.localizedDescription
        }
        liveBusy = false
        await refreshLive()
    }

    func tap(ref: Int) async {
        await liveAction { try await $0.tap(ref: ref) }
    }

    func tap(x: Double, y: Double) async {
        await liveAction { try await $0.tap(x: x, y: y) }
    }

    func swipe(_ direction: FTSwipeDirection) async {
        await liveAction { try await $0.swipe(direction) }
    }

    /// 選択中デバイスのプラットフォームに対応するパス欄のパッケージをインストールする
    func installApp() async {
        let isAndroid = selectedTarget?.platform == "android"
        let path = (isAndroid ? androidPackagePath : iosPackagePath)
            .trimmingCharacters(in: .whitespaces)
        guard !path.isEmpty else {
            liveError = isAndroid
                ? "Android の .apk パスを入力してください"
                : "iOS の .app パスを入力してください"
            return
        }
        let expanded = (path as NSString).expandingTildeInPath
        guard FileManager.default.fileExists(atPath: expanded) else {
            liveError = "パッケージファイルが見つかりません: \(path)"
            return
        }
        await liveAction { try await $0.install(packagePath: expanded) }
    }

    func launchApp() async {
        let id = bundleID
        await liveAction { try await $0.launch(bundleID: id) }
    }

    func terminateApp() async {
        await liveAction { try await $0.terminate() }
    }

    // MARK: - FM 探索

    func startExplore() {
        guard !exploring, !exploreGoal.isEmpty, !exploreBundleID.isEmpty else { return }
        exploring = true
        exploreLog = ["🧭 探索開始: \(exploreBundleID)", "   目標: \(exploreGoal)"]

        let goal = exploreGoal
        let bundle = exploreBundleID
        let maxSteps = exploreMaxSteps
        // 探索対象 = 選択中の対象デバイス(生成フローの platform にも反映)
        let flowPlatform = selectedTarget?.platform ?? "ios"

        exploreTask = Task { @MainActor [weak self] in
            guard let self else { return }
            do {
                let driver = try self.makeSelectedDriver()
                let agent = ExplorerAgent(driver: driver, goal: goal, maxSteps: maxSteps)
                agent.onStep = { [weak self] step, desc in
                    Task { @MainActor in
                        self?.exploreLog.append(step == 0 ? "🗺 \(desc)" : "[\(step)/\(maxSteps)] \(desc)")
                    }
                }
                let result = try await agent.explore(bundleID: bundle)

                var flow = result.flow
                flow.platform = flowPlatform

                switch result.outcome {
                case .completed(let desc):
                    self.exploreLog.append("✅ 目標達成(\(result.stepsTaken)ステップ)"
                                           + (desc.map { " — \($0)" } ?? ""))
                case .gaveUp(let reason):
                    self.exploreLog.append("⚠️ 中断: \(reason)(TODO コメント付きで生成)")
                case .stepLimitReached:
                    self.exploreLog.append("⚠️ ステップ上限に到達(TODO コメント付きで生成)")
                }

                // Swift シナリオとして生成 → ビルド検証(失敗時は _disabled/ に隔離)
                let generatedDir = URL(fileURLWithPath: "Scenarios/Generated")
                let quarantineDir = URL(fileURLWithPath: "Scenarios/_disabled")
                let className = ScenarioCodeGen.suggestedClassName(
                    for: flow,
                    existing: ScenarioCodeGen.existingClassNames(
                        in: [URL(fileURLWithPath: "Scenarios"), generatedDir, quarantineDir]))
                let code = ScenarioCodeGen.render(
                    flow: flow, className: className,
                    generatedBy: "ftester explore v0.1 (apple-fm-on-device)")
                self.exploreLog.append("→ 生成コードをビルド検証中...")
                let url = try await Task.detached {
                    try ScenarioCodeGen.writeValidated(code: code, className: className,
                                                       dir: generatedDir,
                                                       quarantineDir: quarantineDir)
                }.value
                self.exploreLog.append("📄 生成: \(url.path)")
                self.exploreLog.append("   実行: ftester run --scenario \(className).\(ScenarioCodeGen.methodName(1))")
                await self.refreshScenarios()
            } catch is CancellationError {
                self.exploreLog.append("⛔️ キャンセルしました")
            } catch {
                self.exploreLog.append("❌ エラー: \(error.localizedDescription)")
            }
            self.exploring = false
        }
    }

    func cancelExplore() {
        exploreTask?.cancel()
    }
}
