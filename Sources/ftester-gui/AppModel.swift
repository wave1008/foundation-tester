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

    // MARK: - テストプロジェクト / 実行プロファイル

    var projects: [TestProject] = []
    /// 選択中プロジェクト(LocalConfig.defaultProject に永続化 = CLI の既定とも共有)
    var selectedProjectName: String? {
        didSet {
            guard oldValue != selectedProjectName else { return }
            var config = LocalConfig.load()
            config.defaultProject = selectedProjectName
            try? config.save()
            refreshRunProfiles()
        }
    }
    /// 実行プロファイル名(nil = プロファイルなし: 稼働中デバイスへの自動割当)
    var selectedRunProfile: String? {
        didSet {
            guard oldValue != selectedRunProfile, let name = selectedProjectName else { return }
            var config = LocalConfig.load()
            var last = config.lastRunProfile ?? [:]
            last[name] = selectedRunProfile
            config.lastRunProfile = last
            try? config.save()
        }
    }
    var runProfiles: [String] = []
    /// このマシンの名前(~/.config/ftester/config.json に永続化 = CLI と共有)
    var machineName: String = "" {
        didSet {
            guard oldValue != machineName else { return }
            var config = LocalConfig.load()
            config.machineName = machineName.isEmpty ? nil : machineName
            try? config.save()
        }
    }

    func currentProject() throws -> TestProject {
        try ScenarioHost.project(named: selectedProjectName)
    }

    func refreshProjects() {
        guard let root = ScenarioHost.packageRoot() else {
            projects = []
            return
        }
        projects = ProjectStore.all(repoRoot: root)
        if selectedProjectName == nil
            || !projects.contains(where: { $0.name == selectedProjectName }) {
            selectedProjectName = (try? ScenarioHost.project())?.name ?? projects.first?.name
        }
        refreshRunProfiles()
    }

    var creatingProject = false
    var shuttingDownSimulators = false
    var bootingDevices = false

    /// serial → AVD ID のキャッシュ。ブート/シャットダウン中は adb が一時的に offline になり
    /// ライブ照会(runningAVDs)が空振りするため、一度解決した対応を保持して
    /// タイル(targets 由来)とプレースホルダーの判定が食い違わないようにする
    private var androidSerialAVDCache: [String: String] = [:]
    /// serial → マシンプロファイルの論理名(エミュ1 等)。フォールバックタイルの表示に使う
    private(set) var androidLogicalBySerial: [String: String] = [:]

    /// モニターの 5 秒サイクルで読んだマシンプロファイルの控え。ライブタイルの右クリック解決
    /// (machineDevice(forMonitorLabel:))が body 評価のたびにディスクを読まないようにする
    private var cachedMachineProfile: MachineProfile?

    /// プレースホルダー計算の材料を用意する。マシンプロファイルの全デバイス分の候補カードと
    /// serial → AVD の対応(キャッシュ込み)を返す。どのカードを消すか(抑制)は
    /// DeviceMonitorCenter がタイル更新と同一ターンで判定する(一瞬の重複表示防止)
    func machineDeviceSnapshot() async -> PlaceholderSnapshot {
        cachedMachineProfile = loadMachineProfile()
        guard let profile = cachedMachineProfile else { return .empty }
        let iosSpecs = profile.ios?.devices ?? []
        let androidSpecs = profile.android?.devices ?? []
        // タイルが出ている Android serial(androidDevicesProvider と同じ = targets)
        let activeSerials = targets.filter { $0.platform == "android" }
            .compactMap(\.serial)
        let cache = androidSerialAVDCache

        // serial → AVD の解決(adb)はバックグラウンドで
        let outcome = await Task.detached {
            () -> (snapshot: PlaceholderSnapshot, cache: [String: String],
                   logical: [String: String]) in
            let live = (try? AndroidDeviceCatalog.runningAVDs()) ?? [:]
            // ライブ結果でキャッシュを更新し、現存する serial の分だけ残す
            // (serial は再利用されるため、消えた serial の対応は捨てる。
            //  ブート/シャットダウン中の adb offline で live が空振りしても
            //  キャッシュがタイルとの対応を維持する)
            var merged = cache.merging(live) { _, new in new }
            merged = merged.filter { activeSerials.contains($0.key) || live.keys.contains($0.key) }

            var candidates: [PlaceholderTile] = []
            for spec in iosSpecs {
                candidates.append(PlaceholderTile(
                    name: spec.name, platform: "ios",
                    detail: [spec.simulator, spec.os].compactMap { $0 }
                        .joined(separator: " "),
                    windowMatch: spec.simulator ?? "iPhone 17 Pro"))
            }
            var logical: [String: String] = [:]
            for spec in androidSpecs {
                guard let avd = spec.avd else { continue }
                let avdID = AndroidDeviceCatalog.canonicalAVDID(avd)
                for serial in activeSerials where merged[serial] == avdID {
                    logical[serial] = spec.name
                }
                candidates.append(PlaceholderTile(
                    name: spec.name, platform: "android",
                    detail: avd, windowMatch: avdID))
            }
            return (PlaceholderSnapshot(candidates: candidates, serialToAVD: merged),
                    merged, logical)
        }.value

        androidSerialAVDCache = outcome.cache
        androidLogicalBySerial = outcome.logical
        return outcome.snapshot
    }

    // MARK: - デバイス単体の起動・停止(モニターのプレースホルダー右クリック)

    var deviceOpsInProgress: Set<String> = []
    /// 起動処理中のデバイス(PlaceholderTile.id)。カードに「起動中」を表示する
    var bootingDeviceIDs: Set<String> = []

    /// 現在のプロジェクトと登録マシンのマシンプロファイルを読む
    private func loadMachineProfile() -> MachineProfile? {
        guard let project = try? currentProject(),
              let machine = try? ProfileResolver.determineMachine(
                  project: project, registered: LocalConfig.currentMachineName()),
              let data = try? Data(contentsOf: project.machinesDir
                  .appendingPathComponent("\(machine.name).json")) else {
            return nil
        }
        return try? JSONDecoder().decode(MachineProfile.self, from: data)
    }

    /// マシンプロファイルからプレースホルダーに対応する DeviceSpec を引く
    private func machineDeviceSpec(for tile: PlaceholderTile) -> DeviceSpec? {
        guard let profile = loadMachineProfile() else { return nil }
        let list = tile.platform == "ios" ? profile.ios?.devices : profile.android?.devices
        return list?.first { $0.name == tile.name }
    }

    /// ライブタイルのラベル("ios:8123" / "android:emulator-5556")から
    /// マシンプロファイル上のデバイスを引く(起動済みタイルの右クリック停止用)。
    /// プロファイル外のデバイス(手動起動のシミュレータ等)は nil = メニューを出さない
    func machineDevice(forMonitorLabel label: String?) -> PlaceholderTile? {
        guard let label, let profile = cachedMachineProfile else { return nil }
        if label.hasPrefix("ios:"), let port = UInt16(label.dropFirst("ios:".count)) {
            guard let deviceName = portStatuses[port]?.device,
                  let spec = (profile.ios?.devices ?? []).first(where: {
                      ($0.simulator ?? "iPhone 17 Pro") == deviceName
                  }) else { return nil }
            return PlaceholderTile(
                name: spec.name, platform: "ios",
                detail: [spec.simulator, spec.os].compactMap { $0 }.joined(separator: " "),
                windowMatch: spec.simulator ?? "iPhone 17 Pro")
        }
        if label.hasPrefix("android:") {
            let serial = String(label.dropFirst("android:".count))
            guard let name = androidLogicalBySerial[serial],
                  let spec = (profile.android?.devices ?? []).first(where: { $0.name == name })
            else { return nil }
            return PlaceholderTile(name: spec.name, platform: "android",
                                   detail: spec.avd ?? "", windowMatch: spec.avd)
        }
        return nil
    }

    func bootDevice(_ tile: PlaceholderTile) async {
        bootingDeviceIDs.insert(tile.id)
        defer { bootingDeviceIDs.remove(tile.id) }
        await deviceOperation(tile) { spec, platform, log in
            try await DeviceBooter.bootOne(spec: spec, platform: platform, log: log)
            // iOS はブリッジも供給する(稼働中ブリッジがあれば再利用。
            // 供給しないと画面が取れず「起動済み(ブリッジ未接続)」のままになる)
            if platform == "ios" {
                let root = try RepoRoot.find()
                _ = try await BridgeProvisioner(repoRoot: root)
                    .provision(devices: [(spec.name, spec)], log: log)
            }
        }
    }

    func shutdownDevice(_ tile: PlaceholderTile) async {
        await deviceOperation(tile) { spec, platform, log in
            try await DeviceBooter.shutdownOne(spec: spec, platform: platform, log: log)
        }
    }

    private func deviceOperation(
        _ tile: PlaceholderTile,
        _ body: @escaping @Sendable (DeviceSpec, String, @escaping @Sendable (String) -> Void)
            async throws -> Void
    ) async {
        guard deviceOpsInProgress.insert(tile.id).inserted else { return }
        defer { deviceOpsInProgress.remove(tile.id) }
        guard let spec = machineDeviceSpec(for: tile) else {
            bridgeManager.log.append("❌ \(tile.name): マシンプロファイルに定義が見つかりません")
            return
        }
        let log: @Sendable (String) -> Void = { [weak self] line in
            Task { @MainActor in self?.bridgeManager.log.append(line) }
        }
        let platform = tile.platform
        do {
            try await Task.detached {
                try await body(spec, platform, log)
            }.value
        } catch {
            bridgeManager.log.append("❌ \(tile.name): \(error.localizedDescription)")
        }
        await refreshTargets()
        monitor.rematch()
    }

    /// マシンプロファイルに定義された全デバイスを段階的に起動する
    /// (一斉起動はマシンが固まるため、負荷を見ながら 1 台ずつ。起動済みはスキップ)
    func bootAllDevices() async {
        guard !bootingDevices else { return }
        bootingDevices = true
        defer { bootingDevices = false }

        let machine: MachineProfile
        let machineName: String
        do {
            let project = try currentProject()
            let determined = try ProfileResolver.determineMachine(
                project: project, registered: LocalConfig.currentMachineName())
            machineName = determined.name
            let url = project.machinesDir.appendingPathComponent("\(machineName).json")
            machine = try JSONDecoder().decode(MachineProfile.self, from: Data(contentsOf: url))
        } catch {
            bridgeManager.log.append("❌ デバイス起動: \(error.localizedDescription)")
            return
        }
        bridgeManager.log.append("→ マシンプロファイル \(machineName) の全デバイスを段階的に起動します")

        let log: @Sendable (String) -> Void = { [weak self] line in
            Task { @MainActor in self?.bridgeManager.log.append(line) }
        }
        // 起動処理中のデバイスは「起動中」表示、完了(成否問わず)で再スキャン
        let starting: @Sendable (String, String) -> Void = { [weak self] name, platform in
            Task { @MainActor in self?.bootingDeviceIDs.insert("\(platform):\(name)") }
        }
        let finished: @Sendable (String, String) -> Void = { [weak self] name, platform in
            Task { @MainActor in
                guard let self else { return }
                self.bootingDeviceIDs.remove("\(platform):\(name)")
                await self.refreshTargets()
                self.monitor.rematch()
            }
        }
        // iOS は起動直後にそのままブリッジ供給まで行う(1 台単位で完結)
        let repoRoot = try? RepoRoot.find()
        await Task.detached {
            await DeviceBooter.bootAll(machine: machine, repoRoot: repoRoot, log: log,
                                       deviceStarting: starting, deviceFinished: finished)
        }.value
        bootingDeviceIDs = []

        bridgeManager.log.append("→ デバイス起動シーケンス完了")
        await refreshTargets()
        await bridgeManager.refresh(range: portRange, statuses: portStatuses)
        monitor.rematch()
    }

    /// 全 iOS ブリッジを停止し、起動中のシミュレータと Android エミュレータをすべて終了する
    /// (Android 実機は対象外)。ブリッジ(xcodebuild)を先に止めないと
    /// シミュレータ終了でプロセスが不安定になるため順序固定
    func shutdownAllSimulators() async {
        guard !shuttingDownSimulators else { return }
        shuttingDownSimulators = true
        defer { shuttingDownSimulators = false }

        let result = await Task.detached { () -> (bridges: [String], emulators: [String]) in
            let root = try? RepoRoot.find()
            let stopped = root.map { BridgeLauncher.stopAll(repoRoot: $0) } ?? []
            _ = try? Shell.run(["xcrun", "simctl", "shutdown", "all"])
            // Android エミュレータ(emulator-* のみ。実機は触らない)。
            // offline のエミュレータには emu kill が届かないため、残った qemu を直接落とす
            var killed: [String] = []
            if let adb = try? AndroidDriver.findADB(),
               let serials = try? AndroidDeviceCatalog.allEmulatorSerials() {
                for serial in serials {
                    _ = try? Shell.run([adb, "-s", serial, "emu", "kill"])
                    killed.append(serial)
                }
                if !killed.isEmpty {
                    try? await Task.sleep(nanoseconds: 3_000_000_000)
                    _ = try? Shell.run(["pkill", "-9", "-f", "sdk/emulator/qemu"])
                }
            }
            return (stopped, killed)
        }.value

        var parts: [String] = []
        if !result.bridges.isEmpty {
            parts.append("ブリッジ停止(port: \(result.bridges.joined(separator: ", ")))")
        }
        parts.append("シミュレータ全終了")
        if !result.emulators.isEmpty {
            parts.append("エミュレータ終了(\(result.emulators.joined(separator: ", ")))")
        }
        bridgeManager.log.append("✅ " + parts.joined(separator: " / "))

        // SIGTERM 直後は /status がまだ応答することがあるため少し待ってから再スキャン
        try? await Task.sleep(nanoseconds: 1_500_000_000)
        await refreshTargets()
        await bridgeManager.refresh(range: portRange, statuses: portStatuses)
        monitor.rematch()
    }

    /// 新規テストプロジェクト作成(雛形生成+Package.swift 更新)。成功時は選択して一覧を更新。
    /// 戻り値: エラーメッセージ(nil = 成功)
    func createProject(name: String, app: String) async -> String? {
        guard let root = ScenarioHost.packageRoot() else {
            return "Package.swift が見つかりません(リポジトリ内で起動してください)"
        }
        creatingProject = true
        defer { creatingProject = false }
        let machineName = LocalConfig.currentMachineName()
        // Package.swift 更新は dump-package 検証(swift 実行)を含むため背景スレッドで
        let result: Result<TestProject, Error> = await Task.detached {
            do {
                return .success(try ProjectScaffold.createAndRegister(
                    name: name, app: app, repoRoot: root, machineName: machineName))
            } catch {
                return .failure(error)
            }
        }.value
        switch result {
        case .success(let project):
            refreshProjects()
            selectedProjectName = project.name
            await refreshScenarios()
            return nil
        case .failure(let error):
            return error.localizedDescription
        }
    }

    func refreshRunProfiles() {
        guard let project = try? currentProject() else {
            runProfiles = []
            selectedRunProfile = nil
            return
        }
        runProfiles = ProfileResolver.runProfileNames(project: project)
        if let selected = selectedRunProfile, !runProfiles.contains(selected) {
            selectedRunProfile = nil
        }
        if selectedRunProfile == nil,
           let last = LocalConfig.load().lastRunProfile?[project.name],
           runProfiles.contains(last) {
            selectedRunProfile = last
        }
    }

    // MARK: - シナリオ実行

    struct ScenarioEntry: Identifiable {
        let info: ScenarioInfo
        var state: RunState = .idle
        /// クラスを定義する .swift(フォルダ移動用。ソース走査で特定できなければ nil)
        var fileURL: URL?
        /// 所属フォルダ名(Scenarios/ 直下は nil)
        var folder: String?
        var id: URL { ScenarioRunItem.url(for: info.id) }

        /// シナリオ ID(クラス名.メソッド名)のテストクラス部分
        var className: String {
            info.id.firstIndex(of: ".").map { String(info.id[..<$0]) } ?? info.id
        }
        /// テスト関数(@Test メソッド)部分
        var methodName: String {
            info.id.firstIndex(of: ".").map {
                String(info.id[info.id.index(after: $0)...])
            } ?? info.id
        }
    }

    /// テストクラス 1 つ分のグループ(シナリオペインの階層表示用)。
    /// クラス名は SPM ターゲット内で一意なのでそのまま ID になる
    struct ScenarioClassGroup: Identifiable {
        let className: String
        let entries: [ScenarioEntry]
        var id: String { className }
    }

    /// フローペインのステップ表の 1 行(dry-run の step イベント+ソース行末コメント)
    struct ScenarioStepRow: Identifiable, Sendable {
        /// シナリオ内の通し番号(1 起点)
        let index: Int
        let scene: Int?
        /// scene(n, "タイトル") のタイトル(ツールチップ用)
        let sceneTitle: String?
        /// condition / action / expectation / nil(CAE 外)
        let section: String?
        /// コマンドと引数(例: tap "#login_btn||ログイン")
        let command: String
        /// ソース行末の // コメント(無ければ nil)
        let comment: String?
        /// コメントが無い行の補完用に生成した自然言語の説明(StepDescription。無ければ nil)
        let generatedComment: String?
        /// コマンド呼び出し元のソース位置(ブレークポイントのキー。dry-run イベント由来)
        let file: String?
        let line: Int?
        var id: Int { index }

        /// ブレークポイントの識別子("<file>:<line>"。ランナーへそのまま渡す)
        var breakpointKey: String? {
            guard let file, let line else { return nil }
            return "\(file):\(line)"
        }

        /// 区分の表示名(condition=条件 / action=操作 / expectation=確認)
        var sectionLabel: String {
            switch section {
            case "condition": return "条件"
            case "action": return "操作"
            case "expectation": return "確認"
            default: return ""
            }
        }
    }

    /// ステップ表のロード結果
    enum StepLoadResult: Sendable {
        case steps([ScenarioStepRow])
        /// シナリオ一覧の再読込(ビルド)中。完了時の世代更新で自動的に再取得される
        case building
        case failed(String)
    }

    /// フォルダ行のフォーカス(List 選択)用の擬似 URL。
    /// シナリオの scenario://run/ とは host で区別され衝突しない
    static func folderSelectionID(_ name: String) -> URL {
        selectionID(kind: "folder", name: name)
    }

    /// クラス行のフォーカス(List 選択)用の擬似 URL
    static func classSelectionID(_ className: String) -> URL {
        selectionID(kind: "class", name: className)
    }

    /// 擬似 URL(scenario://folder/<名前>)からフォルダ名を取り出す。フォルダ行以外は nil
    static func folderName(fromSelectionID url: URL) -> String? {
        guard url.scheme == "scenario", url.host == "folder" else { return nil }
        return url.lastPathComponent
    }

    /// 擬似 URL(scenario://class/<名前>)からテストクラス名を取り出す。クラス行以外は nil
    static func className(fromSelectionID url: URL) -> String? {
        guard url.scheme == "scenario", url.host == "class" else { return nil }
        return url.lastPathComponent
    }

    private static func selectionID(kind: String, name: String) -> URL {
        let encoded = name.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? kind
        return URL(string: "scenario://\(kind)/\(encoded)")
            ?? URL(fileURLWithPath: "/\(kind)")
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

    /// 自己修復ONの実行で見つかった修復候補 1 件(実行後の確認シートの表示・確定用)
    struct HealFix: Identifiable, Equatable {
        let scenarioID: String
        /// リポジトリルート相対パス(イベントのまま)
        let file: String
        let line: Int
        let oldSelector: String
        let newSelector: String
        /// 提案文(rationale入り)
        let message: String
        /// 対象コマンドの description(例: tap "旧セレクタ")。説明提案の生成に使う。
        /// id には含めない(ヒールキャッシュ削除キーの形式を維持)
        var command: String? = nil
        /// 適用時に差し替える行末コメント(説明)。nil = 説明は変更しない、空 = コメント削除。
        /// 確認シートが適用対象を組み立てるときだけ詰める(イベント収集時は常に nil)
        var newComment: String? = nil
        var id: String { "\(scenarioID)|\(file):\(line)|\(oldSelector)" }
    }

    var scenarios: [ScenarioEntry] = []
    /// Scenarios/ 直下のフォルダ名一覧(1 階層のみ。空フォルダも含む、名前順)
    var scenarioFolders: [String] = []
    /// 選択中のシナリオ(複数可。Cmd/Shift+クリックで追加・範囲選択)
    var selectedScenarioIDs: Set<URL> = []

    // 外部変更の自動同期(FSEvents)。署名が変わったときだけ再読込する
    private let scenarioWatcher = ScenarioDirectoryWatcher()
    /// 最後に取り込んだ Scenarios/ の署名(自分の操作分はその場で更新して再ビルドを抑制)
    private var scenarioDirSignature: [String]?
    /// シナリオ実行中に外部変更が来た(実行終了後に同期する)
    private var pendingScenarioSync = false
    /// 再読込・署名検査中に外部変更が来た(完了後に署名を再確認する)
    private var scenarioSyncQueued = false
    private var refreshingScenarios = false
    /// 署名検査の直列化(検査中の割り込みイベントは queued へ。二重ビルド防止)
    private var syncCheckInProgress = false
    /// FT_WATCH_DEBUG=1 で外部変更同期の判断を stderr に記録する(検証用)
    private let watchDebug = ProcessInfo.processInfo.environment["FT_WATCH_DEBUG"] == "1"
    var heal = false
    var runningFlow = false
    var lanes: [WorkerLane] = []
    /// シナリオ一覧のビルド/読込状態(nil = 正常)
    var scenarioListStatus: String?

    /// 直近の実行で見つかった自己修復の候補(実行終了後に確認シートで表示)
    var pendingHealFixes: [HealFix] = []
    /// 自己修復の確認シートを表示中か
    var healReviewPresented = false
    /// pendingHealFixes の元になった実行のプロジェクト(適用時のソース解決・ヒールキャッシュ削除に使う)
    private var healReviewProject: TestProject?

    /// シナリオ ID → ステップ表の行(dry-run 結果のキャッシュ)。一覧再読込で全クリア
    private var stepRowsCache: [String: [ScenarioStepRow]] = [:]
    /// 実行中の dry-run(キー: "世代|シナリオID")。同一シナリオへの二重起動防止
    private var stepLoadTasks: [String: Task<StepLoadResult, Never>] = [:]
    /// シナリオ一覧の世代。refreshScenarios 完了毎に +1(ステップ表の再取得トリガ)
    private(set) var scenarioListGeneration = 0

    // MARK: - ステップ表の選択・セル内編集の状態
    // (Table のセルは親 View の @State 変更では再描画されないことがあるため、
    //  Observable なモデルに置いてセルの追従を保証する。表は 1 画面に 1 つ)

    /// ステップ表でクリック選択(ハイライト)された行。id は ScenarioStepRow.index
    var stepTableSelection: ScenarioStepRow.ID?
    /// コマンドセルのインライン編集中の行(選択済み行のセルクリックで開始)
    var stepEditingRow: ScenarioStepRow?
    /// インライン編集中のテキスト(表示表現のまま。例: tap "ラベル")
    var stepEditText = ""
    /// 適用・行移動後の再読込で復元するステップ表の選択(scenarioID, ステップ番号)。
    /// ScenarioStepTable の .task がロード完了時に 1 回だけ消費する
    var pendingStepReselection: (scenarioID: String, index: Int)?

    // MARK: - デバッグ実行(ブレークポイント・ステップ実行)

    /// シナリオ ID → ブレークポイント("<file>:<line>")。ステップ表の行頭クリックで設定・解除
    var scenarioBreakpoints: [String: Set<String>] = [:]
    /// デバッグ実行中のランナーへの制御チャネル(nil = デバッグ実行なし)
    private var debugControl: ScenarioRunControl?
    /// デバッグ実行中のシナリオ ID(実行終了で nil)
    private(set) var debugScenarioID: String?
    /// 一時停止中か(paused イベントで true、再開・停止ボタンで false)
    private(set) var debugPaused = false
    /// 一時停止中の「次に実行するステップ」(ステップ表のハイライトと表示用)
    private(set) var debugPausedIndex: Int?
    private(set) var debugPausedDescription: String?

    /// 「削除済みを非表示にする」: ON なら @Deleted のシナリオをペインから隠す(UserDefaults 永続化)
    var hideDeleted: Bool {
        didSet {
            UserDefaults.standard.set(hideDeleted, forKey: "hideDeletedScenarios")
            // 隠れたシナリオが選択に残ると見えないまま実行対象になるため外す
            if hideDeleted {
                selectedScenarioIDs.subtract(scenarios.filter { $0.info.deleted }.map(\.id))
            }
        }
    }

    /// シナリオペインに表示するシナリオ(非表示設定なら @Deleted を除く)
    var visibleScenarios: [ScenarioEntry] {
        hideDeleted ? scenarios.filter { !$0.info.deleted } : scenarios
    }

    /// 選択中のシナリオを一覧順で返す(実行順もこの順)
    var selectedEntries: [ScenarioEntry] {
        scenarios.filter { selectedScenarioIDs.contains($0.id) }
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
        hideDeleted = defaults.bool(forKey: "hideDeletedScenarios")
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
        monitor.androidDevicesProvider = { [weak self] in
            guard let self else { return [] }
            // 表示名はマシンプロファイルの論理名(エミュ1 等)を優先し、無ければ adb のモデル名
            return self.targets.filter { $0.platform == "android" }
                .compactMap { target in
                    target.serial.map {
                        ($0, self.androidLogicalBySerial[$0] ?? target.name)
                    }
                }
        }
        monitor.placeholderProvider = { [weak self] in
            await self?.machineDeviceSnapshot() ?? .empty
        }
        monitor.targetsRefresher = { [weak self] in
            await self?.refreshTargets()
        }

        // プロジェクト/マシン名(~/.config/ftester/config.json = CLI と共有)
        machineName = LocalConfig.load().machineName ?? ""
        refreshProjects()

        // Scenarios/ の外部変更(Finder・エディタ・CLI)を検知して自動同期する
        scenarioWatcher.onChange = { [weak self] in
            Task { @MainActor in await self?.scenarioDirectoryChanged() }
        }
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

    /// シナリオをビルドして一覧を取得する(ftester-scenarios サブプロセス経由)。
    /// あわせて Scenarios/ を走査してフォルダ一覧とクラス → ファイル対応を更新する
    func refreshScenarios() async {
        refreshingScenarios = true
        defer {
            // ソース/ランナーバイナリが変わった可能性があるため dry-run 結果を捨て、
            // 世代を進めて表示中のステップ表に再取得を促す(行番号ずれ=誤コメントの防止)
            stepRowsCache.removeAll()
            stepLoadTasks.removeAll()
            scenarioListGeneration += 1
            refreshingScenarios = false
            // 再読込中に届いた外部変更は完了後に署名を確認して取り込む
            if scenarioSyncQueued {
                scenarioSyncQueued = false
                Task { @MainActor in await self.scenarioDirectoryChanged() }
            }
        }
        let project: TestProject
        do {
            project = try currentProject()
        } catch {
            scenarioWatcher.stop()
            scenarios = []
            scenarioFolders = []
            scenarioListStatus = "⚠️ \(error.localizedDescription)"
            return
        }
        scenarioListStatus = "シナリオをビルド中(\(project.name))..."
        let scenariosDir = project.scenariosDir
        scenarioWatcher.watch(path: scenariosDir.path)
        let (result, folders, fileByClass, signature):
            (Result<[ScenarioInfo], Error>, [String], [String: URL], [String])
            = await Task.detached {
                // 署名はビルド前に取る(ビルド中の変更は署名不一致となり次の同期で拾う)
                let signature = ScenarioFolders.directorySignature(scenariosDir: scenariosDir)
                let folders = ScenarioFolders.list(scenariosDir: scenariosDir)
                let map = ScenarioFolders.classFileMap(scenariosDir: scenariosDir)
                do {
                    try ScenarioHost.build(project: project)
                    return (.success(try ScenarioHost.list(project: project)), folders, map,
                            signature)
                } catch {
                    return (.failure(error), folders, map, signature)
                }
            }.value

        scenarioDirSignature = signature
        scenarioFolders = folders
        switch result {
        case .success(let infos):
            let states = Dictionary(uniqueKeysWithValues: scenarios.map { ($0.id, $0.state) })
            scenarios = infos.map { info in
                let className = info.id.split(separator: ".").first.map(String.init) ?? info.id
                let file = fileByClass[className]
                return ScenarioEntry(
                    info: info,
                    state: states[ScenarioRunItem.url(for: info.id)] ?? .idle,
                    fileURL: file,
                    folder: file.flatMap {
                        ScenarioFolders.folderName(of: $0, scenariosDir: scenariosDir)
                    })
            }
            scenarioListStatus = nil
        case .failure(let error):
            scenarioListStatus = "⚠️ \(error.localizedDescription)"
        }
        // 消えたシナリオ(非表示の削除済み含む)を選択から外し、空になったら先頭を自動選択
        // (フォルダ行・クラス行のフォーカスは実在する限り保持する)
        var valid = Set(visibleScenarios.map(\.id))
        valid.formUnion(scenarioFolders.map(Self.folderSelectionID))
        valid.formUnion(visibleScenarios.map { Self.classSelectionID($0.className) })
        selectedScenarioIDs.formIntersection(valid)
        if selectedScenarioIDs.isEmpty, let first = visibleScenarios.first?.id {
            selectedScenarioIDs = [first]
        }
    }

    // MARK: - ステップ表(dry-run 列挙)

    /// 1 シナリオのステップ表を取得する(キャッシュ → dry-run サブプロセス)。
    /// フローペインの 1 件選択表示用。デバイス不要・レポートは一時ディレクトリ
    func loadSteps(for entry: ScenarioEntry) async -> StepLoadResult {
        let id = entry.info.id
        if let cached = stepRowsCache[id] { return .steps(cached) }
        // ビルド中はランナーバイナリ差し替えの可能性があるため起動しない
        // (完了時の世代更新で呼び出し側が自動的に再試行する)
        if refreshingScenarios { return .building }
        if let status = scenarioListStatus { return .failed(status) }
        guard let project = try? currentProject() else {
            return .failed("プロジェクトを選択してください")
        }

        let generation = scenarioListGeneration
        let key = "\(generation)|\(id)"
        let task: Task<StepLoadResult, Never>
        if let existing = stepLoadTasks[key] {
            task = existing
        } else {
            let packageRoot = ScenarioHost.packageRoot()
            task = Task.detached {
                do {
                    let events = try await ScenarioHost.dryRunSteps(
                        project: project, scenarioID: id)
                    return .steps(Self.stepRows(from: events, packageRoot: packageRoot))
                } catch {
                    return .failed(error.localizedDescription)
                }
            }
            stepLoadTasks[key] = task
        }
        let result = await task.value
        stepLoadTasks[key] = nil
        // dry-run 中に一覧が更新された場合は古い結果(行番号ずれの可能性)を残さない。
        // 世代更新で .task(id:) が再実行されるため、この戻り値はすぐ上書きされる
        if generation == scenarioListGeneration, case .steps(let rows) = result {
            stepRowsCache[id] = rows
            // ソース変更で行番号がずれた古いブレークポイントを掃除
            // (現在のステップ表のどの行にも一致しないものは残さない)
            if let breakpoints = scenarioBreakpoints[id] {
                let valid = breakpoints.intersection(rows.compactMap(\.breakpointKey))
                if valid != breakpoints { scenarioBreakpoints[id] = valid }
            }
        }
        return result
    }

    // MARK: - デバッグ実行の操作(ブレークポイント・ステップ実行ボタン)

    /// ステップ表の行頭クリック: ブレークポイントの設定・解除。
    /// デバッグ実行中のシナリオならランナーへも即時反映する
    func toggleBreakpoint(scenarioID: String, row: ScenarioStepRow) {
        guard let key = row.breakpointKey else { return }
        var set = scenarioBreakpoints[scenarioID] ?? []
        if set.remove(key) == nil { set.insert(key) }
        scenarioBreakpoints[scenarioID] = set
        if debugScenarioID == scenarioID {
            debugControl?.setBreakpoints(Array(set))
        }
    }

    func hasBreakpoint(scenarioID: String, row: ScenarioStepRow) -> Bool {
        guard let key = row.breakpointKey else { return false }
        return scenarioBreakpoints[scenarioID]?.contains(key) ?? false
    }

    /// ステップ実行: 最初のステップの手前で一時停止して開始する(単一選択時のみ)
    func runSelectedStepwise() async {
        guard selectedEntries.count == 1 else { return }
        await runScenarios(selectedEntries, stepwise: true)
    }

    /// 続行: 次のブレークポイント(なければ最後)まで実行する
    func debugContinue() {
        clearPausedMarker()
        debugControl?.continueRun()
    }

    /// ステップ: 1 ステップ実行して次のステップの手前で再停止する
    func debugStepOver() {
        clearPausedMarker()
        debugControl?.stepOver()
    }

    /// 一時停止: 実行中のシナリオを次のステップの手前で停止させる
    func debugPauseRequest() {
        debugControl?.pause()
    }

    /// 停止: シナリオを中断する(残りのステップは skipped、レポートは書かれる)
    func debugStop() {
        clearPausedMarker()
        debugControl?.stop()
    }

    private func clearPausedMarker() {
        debugPaused = false
        debugPausedIndex = nil
        debugPausedDescription = nil
    }

    private func endDebugSession() {
        debugControl = nil
        debugScenarioID = nil
        clearPausedMarker()
    }

    /// dry-run のイベント列をステップ表の行に変換する。
    /// コメントはソースをファイル毎に 1 回読んで行末 // を引く(読めなければ nil で続行)
    nonisolated private static func stepRows(from events: [ScenarioEvent],
                                             packageRoot: URL?) -> [ScenarioStepRow] {
        var sceneTitles: [Int: String] = [:]
        for event in events where event.kind == "sceneStarted" {
            if let scene = event.scene { sceneTitles[scene] = event.sceneTitle }
        }

        let steps = events.filter { $0.kind == "step" }
        // event.file はランナーの cwd で相対化された repo 相対パスか #file の絶対パス
        var linesByFile: [String: Set<Int>] = [:]
        for step in steps {
            if let file = step.file, let line = step.line {
                linesByFile[file, default: []].insert(line)
            }
        }
        var commentsByFile: [String: [Int: String]] = [:]
        for (file, lines) in linesByFile {
            let url = file.hasPrefix("/")
                ? URL(fileURLWithPath: file)
                : (packageRoot?.appendingPathComponent(file) ?? URL(fileURLWithPath: file))
            guard let source = try? String(contentsOf: url, encoding: .utf8) else { continue }
            commentsByFile[file] = ScenarioSourceComments.trailingComments(
                inSource: source, lines: lines)
        }

        return steps.map { step in
            let comment = step.file.flatMap { file in
                step.line.flatMap { commentsByFile[file]?[$0] }
            }
            return ScenarioStepRow(
                index: step.index ?? 0,
                scene: step.scene,
                sceneTitle: step.scene.flatMap { sceneTitles[$0] },
                section: step.section,
                command: step.description ?? "",
                comment: comment,
                // コメントの無い行は自然言語の生成文で補完(淡色表示で区別)
                generatedComment: comment == nil
                    ? StepDescription.describe(command: step.description ?? "") : nil,
                file: step.file,
                line: step.line)
        }
    }

    // MARK: - 外部変更の自動同期

    /// FSEvents からの変更通知。署名(ファイル構成+更新時刻)が本当に変わったときだけ
    /// 再読込する(エディタの一時ファイルや自分自身の操作では再ビルドしない)
    private func scenarioDirectoryChanged() async {
        if runningFlow {
            // 実行中の再ビルドはランナーバイナリを差し替えてしまうため終了後に回す
            pendingScenarioSync = true
            watchLog("変更検知 → 実行中のため保留")
            return
        }
        if refreshingScenarios || syncCheckInProgress {
            scenarioSyncQueued = true
            watchLog("変更検知 → 再読込/検査中のため完了後に確認")
            return
        }
        guard let project = try? currentProject() else { return }
        syncCheckInProgress = true
        let scenariosDir = project.scenariosDir
        let signature = await Task.detached {
            ScenarioFolders.directorySignature(scenariosDir: scenariosDir)
        }.value
        if signature != scenarioDirSignature {
            watchLog("変更検知 → 署名不一致、再読込します")
            await refreshScenarios()
        } else {
            watchLog("変更検知 → 署名一致(同期不要)")
        }
        syncCheckInProgress = false
        // 検査・再読込の最中に届いた変更をもう一巡確認する(署名一致で収束)
        if scenarioSyncQueued {
            scenarioSyncQueued = false
            Task { @MainActor in await self.scenarioDirectoryChanged() }
        }
    }

    /// シナリオ実行の終了処理。実行中に保留した外部変更があればここで同期する
    private func endRunningFlow() {
        runningFlow = false
        endDebugSession()
        if !pendingHealFixes.isEmpty {
            healReviewPresented = true
        }
        if pendingScenarioSync {
            pendingScenarioSync = false
            watchLog("実行終了 → 保留していた外部変更を確認")
            Task { @MainActor in await scenarioDirectoryChanged() }
        }
    }

    /// 自前のファイル操作(フォルダ作成・移動等)の後に署名を控える
    /// (自分の変更に watcher が反応して再ビルドしないように)
    private func noteOwnScenarioDirChange(_ project: TestProject) {
        scenarioDirSignature = ScenarioFolders.directorySignature(
            scenariosDir: project.scenariosDir)
    }

    private func watchLog(_ message: String) {
        guard watchDebug else { return }
        FileHandle.standardError.write(Data("[watch] \(message)\n".utf8))
    }

    // MARK: - シナリオのフォルダ操作(1 階層。実体は Scenarios/ のサブディレクトリ)

    /// フォルダ内(nil = Scenarios/ 直下)のシナリオを一覧順で返す
    /// (「削除済みを非表示にする」ON なら @Deleted を除く。表示と一致させる)
    func scenarioEntries(inFolder folder: String?) -> [ScenarioEntry] {
        visibleScenarios.filter { $0.folder == folder }
    }

    /// フォルダ内のシナリオをテストクラス毎にまとめる(クラス・関数とも一覧順を保つ)
    func scenarioClassGroups(inFolder folder: String?) -> [ScenarioClassGroup] {
        var order: [String] = []
        var grouped: [String: [ScenarioEntry]] = [:]
        for entry in scenarioEntries(inFolder: folder) {
            let name = entry.className
            if grouped[name] == nil { order.append(name) }
            grouped[name, default: []].append(entry)
        }
        return order.map { ScenarioClassGroup(className: $0, entries: grouped[$0] ?? []) }
    }

    /// フォルダを作成する。戻り値: エラーメッセージ(nil = 成功)
    func createScenarioFolder(_ name: String) -> String? {
        guard let project = try? currentProject() else {
            return "プロジェクトを選択してください"
        }
        let trimmed = name.trimmingCharacters(in: .whitespaces)
        do {
            try ScenarioFolders.create(name: trimmed, scenariosDir: project.scenariosDir)
        } catch {
            return error.localizedDescription
        }
        noteOwnScenarioDirChange(project)
        if !scenarioFolders.contains(trimmed) {
            scenarioFolders.append(trimmed)
            scenarioFolders.sort { $0.localizedStandardCompare($1) == .orderedAscending }
        }
        return nil
    }

    /// シナリオをフォルダへ移動する(folder = nil は Scenarios/ 直下へ)。
    /// 実体はクラスを定義する .swift の移動のため、同じファイルのシナリオはまとめて動く。
    /// 戻り値: ドロップを受理したか(ID 不一致の外部テキスト等は false)
    @discardableResult
    func moveScenario(id: String, toFolder folder: String?) -> Bool {
        guard let index = scenarios.firstIndex(where: { $0.info.id == id }) else {
            return false
        }
        guard scenarios[index].folder != folder else { return true }
        guard let project = try? currentProject(), let file = scenarios[index].fileURL else {
            scenarioListStatus = "⚠️ \(id) のソースファイルを特定できません(再読込してください)"
            return false
        }
        do {
            let moved = try ScenarioFolders.move(file: file, toFolder: folder,
                                                 scenariosDir: project.scenariosDir)
            for i in scenarios.indices where scenarios[i].fileURL == file {
                scenarios[i].fileURL = moved
                scenarios[i].folder = folder
            }
        } catch {
            scenarioListStatus = "⚠️ \(error.localizedDescription)"
            return false
        }
        noteOwnScenarioDirChange(project)
        return true
    }

    /// フォルダの名前を変更する。戻り値: エラーメッセージ(nil = 成功)
    func renameScenarioFolder(_ name: String, to newName: String) -> String? {
        guard let project = try? currentProject() else {
            return "プロジェクトを選択してください"
        }
        let trimmed = newName.trimmingCharacters(in: .whitespaces)
        guard trimmed != name else { return nil }
        do {
            try ScenarioFolders.rename(name, to: trimmed, scenariosDir: project.scenariosDir)
        } catch {
            return error.localizedDescription
        }
        noteOwnScenarioDirChange(project)
        let newDir = project.scenariosDir.appendingPathComponent(trimmed, isDirectory: true)
        for i in scenarios.indices where scenarios[i].folder == name {
            scenarios[i].folder = trimmed
            scenarios[i].fileURL = scenarios[i].fileURL
                .map { newDir.appendingPathComponent($0.lastPathComponent) }
        }
        scenarioFolders = scenarioFolders.map { $0 == name ? trimmed : $0 }
            .sorted { $0.localizedStandardCompare($1) == .orderedAscending }
        return nil
    }

    // MARK: - シナリオソースのリネーム(class 宣言・@Test メソッド・説明の書換)

    /// テストクラス名を変更する(ソース書換。ファイル名がクラス名と一致していれば追従)。
    /// シナリオ ID(クラス名.関数名)が変わるため再ビルド+一覧更新まで行う。
    /// 戻り値: エラーメッセージ(nil = 成功)
    func renameScenarioClass(_ className: String, to newName: String) async -> String? {
        let trimmed = newName.trimmingCharacters(in: .whitespaces)
        guard trimmed != className else { return nil }
        guard let project = try? currentProject() else {
            return "プロジェクトを選択してください"
        }
        guard let file = scenarios.first(where: { $0.className == className })?.fileURL else {
            return "\(className) のソースファイルを特定できません(再読込してください)"
        }
        // クラス名はシナリオ ID の前半 = プロジェクト全体で一意でなければならない
        if ScenarioFolders.classFileMap(scenariosDir: project.scenariosDir)[trimmed] != nil {
            return "同名のテストクラスが既にあります: \(trimmed)"
        }
        do {
            let source = try String(contentsOf: file, encoding: .utf8)
            let updated = try ScenarioSourceEditor.renameClass(
                inSource: source, from: className, to: trimmed)
            try updated.write(to: file, atomically: true, encoding: .utf8)
            // 生成ファイルはクラス名 = ファイル名の慣習なので一致していれば追従する
            // (衝突したときはソースの変更だけ生かしてファイル名は据え置き)
            if file.deletingPathExtension().lastPathComponent == className {
                let dest = file.deletingLastPathComponent()
                    .appendingPathComponent(trimmed + ".swift")
                if !FileManager.default.fileExists(atPath: dest.path) {
                    try? FileManager.default.moveItem(at: file, to: dest)
                }
            }
        } catch {
            return error.localizedDescription
        }
        noteOwnScenarioDirChange(project)
        await refreshScenarios()
        return nil
    }

    /// テスト関数(@Test メソッド)の名前を変更する。ID が変わるため一覧更新まで行う
    func renameScenarioMethod(_ entry: ScenarioEntry, to newName: String) async -> String? {
        let trimmed = newName.trimmingCharacters(in: .whitespaces)
        guard trimmed != entry.methodName else { return nil }
        guard let project = try? currentProject() else {
            return "プロジェクトを選択してください"
        }
        guard let file = entry.fileURL else {
            return "\(entry.info.id) のソースファイルを特定できません(再読込してください)"
        }
        do {
            let source = try String(contentsOf: file, encoding: .utf8)
            let updated = try ScenarioSourceEditor.renameMethod(
                inSource: source, className: entry.className,
                from: entry.methodName, to: trimmed)
            try updated.write(to: file, atomically: true, encoding: .utf8)
        } catch {
            return error.localizedDescription
        }
        noteOwnScenarioDirChange(project)
        await refreshScenarios()
        return nil
    }

    /// テスト関数の説明(@Test の文字列)を変更する。空にすると引数なしの @Test になる
    func updateScenarioTitle(_ entry: ScenarioEntry, to newTitle: String) async -> String? {
        let trimmed = newTitle.trimmingCharacters(in: .whitespaces)
        guard trimmed != entry.info.title else { return nil }
        guard let project = try? currentProject() else {
            return "プロジェクトを選択してください"
        }
        guard let file = entry.fileURL else {
            return "\(entry.info.id) のソースファイルを特定できません(再読込してください)"
        }
        do {
            let source = try String(contentsOf: file, encoding: .utf8)
            let updated = try ScenarioSourceEditor.setTestTitle(
                inSource: source, className: entry.className,
                method: entry.methodName, title: trimmed)
            try updated.write(to: file, atomically: true, encoding: .utf8)
        } catch {
            return error.localizedDescription
        }
        noteOwnScenarioDirChange(project)
        await refreshScenarios()
        return nil
    }

    // MARK: - ステップ表のコマンド編集(選択行のセルクリックでインライン編集)

    /// ステップ行のソース位置(repo 相対 or 絶対)をファイル URL に解決する
    /// (dry-run イベントの file はどちらの形式もあり得る。applyHealFixes と同じ規則)
    nonisolated private static func stepSourceURL(_ file: String) -> URL {
        file.hasPrefix("/")
            ? URL(fileURLWithPath: file)
            : (ScenarioHost.packageRoot()?.appendingPathComponent(file)
                ?? URL(fileURLWithPath: file))
    }

    /// この行のコマンドをセル内編集できるか(ソース位置があり、表示表現を解釈できる行のみ。
    /// ifCanSelect 等の実行結果入り表示・未知コマンドは対象外)。実行中の判定は呼び出し側
    nonisolated static func stepCommandEditable(_ row: ScenarioStepRow) -> Bool {
        row.file != nil && row.line != nil && StepCommandText.parse(row.command) != nil
    }

    /// ステップ行のソースを VSCode で開く(行ダブルクリック)。
    /// プロジェクト(リポジトリルート)を開いていない VSCode でも文脈ごと開けるよう、
    /// アプリ同梱の code CLI で「フォルダ + --goto ファイル:行」を渡す(フォルダを開いた
    /// ウィンドウがあれば再利用、無ければフォルダごと開く = CLI の標準動作。確認ダイアログも
    /// 出ない)。CLI が見つからないときは vscode:// スキームにフォールバックする。
    /// 戻り値: エラーメッセージ(nil = 成功)
    func openStepSourceInVSCode(_ row: ScenarioStepRow) -> String? {
        guard let file = row.file else {
            return "このステップはソース位置を特定できないため開けません"
        }
        let goto = Self.stepSourceURL(file).path + (row.line.map { ":\($0)" } ?? "")
        let root = ScenarioHost.packageRoot()

        if let cli = Self.vscodeCLI() {
            let process = Process()
            process.executableURL = cli
            process.arguments = (root.map { [$0.path] } ?? []) + ["--goto", goto]
            process.terminationHandler = { _ in }  // ゾンビ化防止(結果は使わない)
            if (try? process.run()) != nil { return nil }
            // CLI の起動に失敗したら URL スキームへフォールバック
        }

        // 「vscode://file/<パス>」はフォルダも開ける(既に開いていればフォーカスのみ)。
        // フォルダ→ファイルの順に開くと、ファイルはそのウィンドウに開く
        if let root, let folderURL = Self.vscodeURL(path: root.path),
           NSWorkspace.shared.open(folderURL) {
            let fileURL = Self.vscodeURL(path: goto)
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) {
                if let fileURL { NSWorkspace.shared.open(fileURL) }
            }
            return nil
        }
        guard let url = Self.vscodeURL(path: goto), NSWorkspace.shared.open(url) else {
            return "VSCode を開けませんでした(vscode:// スキームを処理できるアプリがありません)"
        }
        return nil
    }

    /// vscode://file/<パス>(パスの日本語は URLComponents が自動でエンコードする)
    nonisolated private static func vscodeURL(path: String) -> URL? {
        var components = URLComponents()
        components.scheme = "vscode"
        components.host = "file"
        components.path = path
        return components.url
    }

    /// VSCode アプリ同梱の code CLI(/usr/local/bin へのリンクが無い環境でも使える)
    nonisolated private static func vscodeCLI() -> URL? {
        for id in ["com.microsoft.VSCode", "com.microsoft.VSCodeInsiders"] {
            guard let app = NSWorkspace.shared.urlForApplication(
                withBundleIdentifier: id) else { continue }
            let cli = app.appendingPathComponent("Contents/Resources/app/bin/code")
            if FileManager.default.isExecutableFile(atPath: cli.path) { return cli }
        }
        return nil
    }

    /// ステップ表発の 1 ファイル書換の共通処理。編集でビルドが壊れると一覧・ステップ表ごと
    /// 使えなくなるため、ビルド失敗時は元のソースへ自動で戻す。reselectOnSuccess/
    /// reselectOnRollback は各 refreshScenarios の前に pendingStepReselection へ積む
    /// ステップ番号(再読込後、ScenarioStepTable の .task が選択を復元する)。
    /// updated == original なら書換・再ビルドとも行わない。戻り値: エラーメッセージ(nil = 成功)
    private func rewriteStepSource(url: URL, project: TestProject, original: String,
                                   updated: String, scenarioID: String,
                                   reselectOnSuccess: Int, reselectOnRollback: Int) async -> String? {
        guard updated != original else { return nil }  // 変更なし = 再ビルド不要
        do {
            try updated.write(to: url, atomically: true, encoding: .utf8)
        } catch {
            return error.localizedDescription
        }
        noteOwnScenarioDirChange(project)
        pendingStepReselection = (scenarioID: scenarioID, index: reselectOnSuccess)
        await refreshScenarios()
        guard let status = scenarioListStatus else { return nil }
        do {
            try original.write(to: url, atomically: true, encoding: .utf8)
        } catch {
            return "ビルドに失敗しました(元に戻せませんでした):\n\(status)"
        }
        noteOwnScenarioDirChange(project)
        pendingStepReselection = (scenarioID: scenarioID, index: reselectOnRollback)
        await refreshScenarios()
        return "ビルドに失敗したため変更を取り消しました:\n\(status)"
    }

    /// 編集ペイン・セル編集が対象にする行の属するシナリオ ID。ステップ表は選択中の
    /// シナリオが単一のときしか表示されないため、選択そのものを情報源にする
    /// (ScenarioStepRow はどのシナリオの行かを保持しない)。単一選択でなければ nil
    private func currentStepScenarioID() -> String? {
        selectedEntries.count == 1 ? selectedEntries.first?.info.id : nil
    }

    /// セル内編集の確定: コマンド列と同じ表示表現の編集をソースへ変換して反映する。
    /// 動詞・引数構成が同じ編集は文字列リテラルだけ置換(timeout: 等を保存)。
    /// 戻り値: エラーメッセージ(nil = 成功)
    func updateStepCommand(row: ScenarioStepRow, display: String) async -> String? {
        guard let file = row.file, let line = row.line else {
            return "このステップはソース位置を特定できないため編集できません"
        }
        let trimmed = display.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { return "コマンドを入力してください" }
        guard trimmed != row.command else { return nil }  // 変更なし
        guard !runningFlow else { return "シナリオの実行中は編集できません" }
        guard let scenarioID = currentStepScenarioID() else {
            return "シナリオを選択してください"
        }
        guard let project = try? currentProject() else {
            return "プロジェクトを選択してください"
        }
        let url = Self.stepSourceURL(file)
        do {
            let original = try String(contentsOf: url, encoding: .utf8)
            let code = try ScenarioSourceEditor.commandCode(inSource: original, line: line)
            let newCode = try StepCommandText.apply(display: trimmed, toCode: code)
            let updated = try ScenarioSourceEditor.setCommandCode(
                inSource: original, line: line, code: newCode)
            return await rewriteStepSource(
                url: url, project: project, original: original, updated: updated,
                scenarioID: scenarioID, reselectOnSuccess: row.index, reselectOnRollback: row.index)
        } catch {
            return error.localizedDescription
        }
    }

    /// 編集ペインのプリフィル: ステップ行のキーワード引数の現在値をソースから読み取る
    /// (スキーマ name → UI 値。省略された引数は既定値で埋まる)。
    /// ソース位置が無い・表示表現を解釈できない・コード部分を解釈できない行は
    /// nil(= パラメーター編集不可)
    func stepEditParams(row: ScenarioStepRow) -> [String: String]? {
        guard let file = row.file, let line = row.line,
              let parsed = StepCommandText.parse(row.command),
              let source = try? String(contentsOf: Self.stepSourceURL(file), encoding: .utf8),
              let code = try? ScenarioSourceEditor.commandCode(inSource: source, line: line) else {
            return nil
        }
        return StepCommandParams.parse(code: code, verb: parsed.verb)
    }

    /// 編集ペインの「適用」: コマンド(表示表現+パラメーター)と説明(行末コメント)を
    /// 1 回の書換・1 回の再ビルドで反映する。params nil = パラメーター変更なし
    /// (リテラル置換パス=書式保存)。comment nil = 変更なし、"" = コメント削除。
    /// 戻り値: エラーメッセージ(nil = 成功)
    func applyStepEdit(row: ScenarioStepRow, display: String,
                       params: [String: String]?, comment: String?) async -> String? {
        guard !runningFlow else { return "シナリオの実行中は編集できません" }
        guard let file = row.file, let line = row.line else {
            return "このステップはソース位置を特定できないため編集できません"
        }
        guard let scenarioID = currentStepScenarioID() else {
            return "シナリオを選択してください"
        }
        guard let project = try? currentProject() else {
            return "プロジェクトを選択してください"
        }
        let trimmed = display.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { return "コマンドを入力してください" }
        let url = Self.stepSourceURL(file)
        do {
            let original = try String(contentsOf: url, encoding: .utf8)
            var updated = original
            // ifCanSelect 等の編集不可コマンド行でも説明だけは編集できるように、
            // コマンドに変更が無く params も無指定のときはコード書換自体をスキップする
            if trimmed != row.command || params != nil {
                let code = try ScenarioSourceEditor.commandCode(inSource: updated, line: line)
                let newCode = try StepCommandParams.apply(
                    display: trimmed, params: params, toCode: code)
                if newCode != code {
                    updated = try ScenarioSourceEditor.setCommandCode(
                        inSource: updated, line: line, code: newCode)
                }
            }
            if let comment {
                updated = try ScenarioSourceEditor.setTrailingComment(
                    inSource: updated, line: line, comment: comment)
            }
            return await rewriteStepSource(
                url: url, project: project, original: original, updated: updated,
                scenarioID: scenarioID, reselectOnSuccess: row.index, reselectOnRollback: row.index)
        } catch {
            return error.localizedDescription
        }
    }

    /// 空のフォルダを削除する。戻り値: エラーメッセージ(nil = 成功)
    func deleteScenarioFolder(_ name: String) -> String? {
        guard let project = try? currentProject() else {
            return "プロジェクトを選択してください"
        }
        do {
            try ScenarioFolders.delete(name, scenariosDir: project.scenariosDir)
        } catch {
            return error.localizedDescription
        }
        noteOwnScenarioDirChange(project)
        scenarioFolders.removeAll { $0 == name }
        return nil
    }

    private func setState(_ url: URL, _ state: RunState) {
        guard let index = scenarios.firstIndex(where: { $0.id == url }) else { return }
        scenarios[index].state = state
    }

    /// 選択中のシナリオ(複数可)だけを実行する
    func runSelected() async {
        await runScenarios(selectedEntries)
    }

    /// 全実行。削除済み(@Deleted)は除外する(明示選択すれば個別実行は可能)
    func runAll() async {
        await runScenarios(scenarios.filter { !$0.info.deleted })
    }

    /// シナリオ群を実行する。iOS はブリッジ毎、Android はデバイス毎のワーカーで並列消化する
    /// (CLI の run --ports と同じオーケストレータ。実行の実体はサブプロセス)。
    /// 実行プロファイル選択時はデバイス供給(ブリッジ起動)・自動インストール込みで実行する。
    /// 単一シナリオで stepwise またはブレークポイントありならデバッグ実行になる
    /// (一時停止・続行・ステップ・停止はフローペインのボタンで操作)
    func runScenarios(_ entries: [ScenarioEntry], stepwise: Bool = false) async {
        guard !runningFlow, !entries.isEmpty else { return }
        guard let project = try? currentProject() else {
            lanes = [WorkerLane(id: "system", title: "⚠️ プロジェクト未選択",
                                log: ["プロジェクトを選択してください"])]
            return
        }
        pendingHealFixes = []
        healReviewPresented = false
        healReviewProject = project
        runningFlow = true

        // 実行前にシナリオを最新化(ビルドはホスト側で1回だけ)
        await refreshScenarios()
        if scenarioListStatus != nil {
            lanes = [WorkerLane(id: "system", title: "⚠️ ビルド失敗",
                                log: [scenarioListStatus ?? ""])]
            endRunningFlow()
            return
        }

        // デバッグ実行は単一シナリオのみ(並列実行との一時停止の混線を避ける)
        var debugOptions: ScenarioDebugOptions?
        if entries.count == 1 {
            let id = entries[0].info.id
            let breakpoints = scenarioBreakpoints[id] ?? []
            if stepwise || !breakpoints.isEmpty {
                debugScenarioID = id
                debugOptions = ScenarioDebugOptions(
                    breakpoints: Array(breakpoints),
                    pauseOnStart: stepwise
                ) { [weak self] control in
                    Task { @MainActor in self?.debugControl = control }
                }
            }
        }

        // プロファイル実行(デバイス供給 → インストール → 両OS同時並列)
        if let profileName = selectedRunProfile {
            await runScenariosWithProfile(profileName, project: project,
                                          items: entries.map { ScenarioRunItem(info: $0.info) },
                                          debug: debugOptions)
            endRunningFlow()
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

        let orchestrator = RunOrchestrator(project: project, workers: workers,
                                           healingEnabled: heal,
                                           reportDir: project.reportsDir,
                                           debug: debugOptions)
        // イベントは MainActor 上で順に消費する(レーン追記とシナリオ状態の更新)
        let consumer = Task { @MainActor [weak self] in
            for await event in orchestrator.events {
                self?.handle(event)
            }
        }
        _ = await orchestrator.run(items: items, defaultPlatform: "ios")
        await consumer.value
        endRunningFlow()
    }

    /// 実行プロファイルによる実行: 解決 → ワーカー構築(iOS ブリッジ供給 / Android 照合)→
    /// 自動インストール → 両OS同時並列実行。供給ログは system レーンに流す
    private func runScenariosWithProfile(_ profileName: String, project: TestProject,
                                         items: [ScenarioRunItem],
                                         debug: ScenarioDebugOptions? = nil) async {
        lanes = [WorkerLane(id: "system", title: "🧩 プロファイル: \(profileName)")]
        let sink: @Sendable (String) -> Void = { [weak self] line in
            Task { @MainActor in self?.appendLane("system", [line]) }
        }
        do {
            let machine = try ProfileResolver.determineMachine(
                project: project, registered: LocalConfig.currentMachineName())
            if machine.auto {
                appendLane("system", ["→ マシンプロファイル自動採用: \(machine.name)"])
            }
            let resolved = try ProfileResolver.resolve(
                project: project, runName: profileName, machineName: machine.name)
            appendLane("system", resolved.warnings.map { "⚠️ \($0)" })
            appendLane("system", ["\(resolved.appName) @ \(machine.name) — デバイス: "
                + resolved.devices.map { "\($0.name)(\($0.platform))" }.joined(separator: ", ")])

            guard let root = ScenarioHost.packageRoot() else {
                throw AppModel.NoTargetError()
            }
            var workers = try await Task.detached {
                try await ProfileWorkerFactory.buildWorkers(
                    resolved: resolved, repoRoot: root, log: sink)
            }.value
            workers = try await ProfileWorkerFactory.installIfNeeded(
                apps: resolved.apps, workers: workers, log: sink)

            lanes += workers.map { WorkerLane(id: $0.label, title: $0.label) }
            await refreshTargets()
            monitor.rematch()

            let orchestrator = RunOrchestrator(
                project: project, workers: workers,
                healingEnabled: heal || resolved.heal,
                reportDir: resolved.reportDir, defaultTimeout: resolved.defaultTimeout,
                debug: debug)
            let consumer = Task { @MainActor [weak self] in
                for await event in orchestrator.events {
                    self?.handle(event)
                }
            }
            let defaultPlatform = workers.contains { $0.platform == "ios" } ? "ios" : "android"
            _ = await orchestrator.run(items: items, defaultPlatform: defaultPlatform)
            await consumer.value
        } catch {
            appendLane("system", ["❌ \(error.localizedDescription)"])
        }
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
        case .flowPaused(let worker, _, let index, let description, _, _):
            debugPaused = true
            debugPausedIndex = index
            debugPausedDescription = description
            appendLane(worker, lines)
        case .flowHealed(let worker, _):
            appendLane(worker, lines)
        case .fixSuggestion(_, _, let scenarioID, let command, let file, let line,
                            let oldSelector, let newSelector, let message):
            if let file, let line, let oldSelector, let newSelector {
                let fix = HealFix(scenarioID: scenarioID, file: file, line: line,
                                  oldSelector: oldSelector, newSelector: newSelector,
                                  message: message, command: command)
                // 同一ヒールはシーン跨ぎ・複数回実行で重複 emit され得る
                if !pendingHealFixes.contains(where: { $0.id == fix.id }) {
                    pendingHealFixes.append(fix)
                }
            }
        case .flowFinished(let worker, let url, let passed, _, _):
            setState(url, passed ? .passed : .failed)
            setLaneRunning(worker, false)
            appendLane(worker, lines)
        case .flowSkipped(let url, _):
            setState(url, .failed)
            appendLane("system", lines)
        case .sceneStarted, .sceneFinished:
            // RunEvent拡張(並列実行のscene忠実度)の途上で追加されたケース。
            // 生成側が未実装のため現状は発生しない。GUI表示対応は拡張の完成時に検討
            break
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

    // MARK: - 自己修復(heal)の確定

    /// 確認シートで選択された修復候補をシナリオソースへ確定反映する。
    /// ファイル毎にまとめて読み込み→順に置換→書き戻し、成功した分はヒールキャッシュ
    /// (.ftester/heal-cache.json)からも削除する。戻り値: エラーメッセージ(nil = 全件成功)
    func applyHealFixes(_ fixes: [HealFix]) async -> String? {
        guard !fixes.isEmpty else { return nil }
        guard let packageRoot = ScenarioHost.packageRoot() else {
            return "リポジトリルートを特定できません"
        }

        var applied: [HealFix] = []
        var failures: [String] = []
        let byFile = Dictionary(grouping: fixes) { $0.file }

        for (file, fileFixes) in byFile {
            let url = file.hasPrefix("/") ? URL(fileURLWithPath: file)
                : packageRoot.appendingPathComponent(file)
            guard var source = try? String(contentsOf: url, encoding: .utf8) else {
                for fix in fileFixes {
                    failures.append("\(fix.scenarioID)(\(fix.file):\(fix.line)): ファイルを読み込めません")
                }
                continue
            }
            var appliedInFile: [HealFix] = []
            for fix in fileFixes.sorted(by: { $0.line < $1.line }) {
                do {
                    source = try ScenarioSourceEditor.replaceSelector(
                        inSource: source, line: fix.line,
                        oldSelector: fix.oldSelector, newSelector: fix.newSelector)
                    appliedInFile.append(fix)
                } catch {
                    failures.append(
                        "\(fix.scenarioID)(\(fix.file):\(fix.line)): \(error.localizedDescription)")
                    continue
                }
                // 説明(行末コメント)の見直し。失敗してもセレクタ置換は生かし、
                // メッセージで分かるようにする
                if let newComment = fix.newComment {
                    do {
                        source = try ScenarioSourceEditor.setTrailingComment(
                            inSource: source, line: fix.line, comment: newComment)
                    } catch {
                        failures.append(
                            "\(fix.scenarioID)(\(fix.file):\(fix.line)): "
                                + "説明の更新に失敗しました(\(error.localizedDescription))")
                    }
                }
            }
            guard !appliedInFile.isEmpty else { continue }
            do {
                try source.write(to: url, atomically: true, encoding: .utf8)
                applied += appliedInFile
            } catch {
                for fix in appliedInFile {
                    failures.append(
                        "\(fix.scenarioID)(\(fix.file):\(fix.line)): 書き込みに失敗しました"
                            + "(\(error.localizedDescription))")
                }
            }
        }

        if let project = healReviewProject, !applied.isEmpty {
            removeFromHealCache(applied, project: project)
            noteOwnScenarioDirChange(project)
            await refreshScenarios()
        }

        // 適用に成功した fix だけをシートから消す。失敗した fix は残す。
        // 自動で閉じるのは失敗が 1 件も無いときだけ(説明の更新だけ失敗した場合等に
        // シートがバインディング経由で閉じてエラーメッセージが見えなくなるのを防ぐ)
        let appliedIDs = Set(applied.map(\.id))
        pendingHealFixes.removeAll { appliedIDs.contains($0.id) }
        if pendingHealFixes.isEmpty && failures.isEmpty { healReviewPresented = false }

        return failures.isEmpty ? nil : failures.joined(separator: "\n")
    }

    /// 反映済みの fix をヒールキャッシュからも削除する(次回実行で再提案されないように)。
    /// キャッシュ更新の失敗は実行を止めない(HealCache.save と同じ方針)
    private func removeFromHealCache(_ fixes: [HealFix], project: TestProject) {
        let cacheURL = project.stateDir.appendingPathComponent("heal-cache.json")
        guard let data = try? Data(contentsOf: cacheURL),
              var dict = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else {
            return
        }
        var changed = false
        for fix in fixes {
            // HealFix.id はヒールキャッシュのキー(HealCache.key)と同一形式
            if dict.removeValue(forKey: fix.id) != nil { changed = true }
        }
        guard changed,
              let output = try? JSONSerialization.data(
                withJSONObject: dict, options: [.prettyPrinted, .sortedKeys]) else {
            return
        }
        try? output.write(to: cacheURL, options: .atomic)
    }

    /// FT_HEAL_REVIEW_DEMO=1 起動時のみ: 確認シートの表示検証用に、実在のシナリオソースから
    /// クォート付きセレクタを含む行を拾ってサンプルの HealFix を表示する
    /// (行末コメント有り・無しを 1 件ずつ = 説明の置換提案と追加提案の両方を確認できる)。
    /// 見つからない場合は存在しない file:line のダミーで「適用できません」表示を確認する。
    /// 環境変数が無ければ何もしない(プロダクション動作には影響しない)
    func setupHealReviewDemoIfNeeded() {
        guard ProcessInfo.processInfo.environment["FT_HEAL_REVIEW_DEMO"] == "1" else { return }
        guard let root = ScenarioHost.packageRoot(),
              let regex = try? NSRegularExpression(
                pattern: #"(tap|exist)\(\s*"([^"]+)""#) else { return }

        var withComment: HealFix?
        var withoutComment: HealFix?
        for entry in scenarios {
            guard let fileURL = entry.fileURL,
                  let source = try? String(contentsOf: fileURL, encoding: .utf8) else { continue }
            let path = fileURL.path
            let relativeFile = path.hasPrefix(root.path + "/")
                ? String(path.dropFirst(root.path.count + 1)) : path
            for (index, lineText) in source.components(separatedBy: "\n").enumerated() {
                let range = NSRange(lineText.startIndex..., in: lineText)
                guard let match = regex.firstMatch(in: lineText, range: range),
                      let verbRange = Range(match.range(at: 1), in: lineText),
                      let selectorRange = Range(match.range(at: 2), in: lineText) else {
                    continue
                }
                let verb = String(lineText[verbRange])
                let oldSelector = String(lineText[selectorRange])
                let fix = HealFix(
                    scenarioID: entry.info.id, file: relativeFile, line: index + 1,
                    oldSelector: oldSelector, newSelector: oldSelector + "||.Cell[3]",
                    message: "デモ: 自己修復サンプル(FT_HEAL_REVIEW_DEMO の表示検証用)",
                    command: "\(verb) \"\(oldSelector)\"")
                if ScenarioSourceComments.trailingComment(inLine: lineText) != nil {
                    if withComment == nil { withComment = fix }
                } else if withoutComment == nil {
                    withoutComment = fix
                }
                if withComment != nil, withoutComment != nil { break }
            }
            if withComment != nil, withoutComment != nil { break }
        }

        var fixes = [withComment, withoutComment].compactMap { $0 }
        if fixes.isEmpty {
            // 拾えるセレクタが無いプロジェクト向け: 適用できないケースの表示確認用ダミー
            fixes = [HealFix(
                scenarioID: "デモ.S9999", file: "Projects/デモ/Scenarios/存在しない.swift",
                line: 999,
                oldSelector: "#dummy_selector", newSelector: "#dummy_selector||.Cell[3]",
                message: "デモ: 適用できないケースの表示検証用(FT_HEAL_REVIEW_DEMO)")]
        }
        pendingHealFixes = fixes
        healReviewPresented = true
    }

    /// 実行ログに表示するレーン。デバイスモニターでデバイスを選択中は
    /// その台数分だけ(1台=1列、選択順=グリッドの表示順)、未選択なら全ワーカー分。
    /// まだログの無い選択デバイスにはタイトルだけの空レーンを出す
    var displayedLanes: [WorkerLane] {
        let selected = monitor.selectedEntries
        guard !selected.isEmpty else { return lanes }
        return selected.map { entry in
            lane(for: entry)
                ?? WorkerLane(id: "device:\(entry.deviceKey)", title: entry.deviceName)
        }
    }

    /// モニターのデバイスを実行ログレーンへ対応付ける。レーン ID は
    /// 非プロファイル実行が "ios:8123"、プロファイル実行が "シミュ1(ios:8123)" の形式
    private func lane(for entry: MonitorEntry) -> WorkerLane? {
        if let label = entry.workerLabel,
           let lane = lanes.first(where: { $0.id == label || $0.id.hasSuffix("(\(label))") }) {
            return lane
        }
        // ワーカーラベルで引けない場合(未起動カード等)は論理名で引く
        return lanes.first { $0.id.hasPrefix("\(entry.deviceName)(") }
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
                let project = try self.currentProject()
                let generatedDir = project.generatedDir
                let quarantineDir = project.disabledDir
                let className = ScenarioCodeGen.suggestedClassName(
                    for: flow,
                    existing: ScenarioCodeGen.existingClassNames(
                        in: [project.scenariosDir, generatedDir, quarantineDir]))
                let code = ScenarioCodeGen.render(
                    flow: flow, className: className,
                    generatedBy: "ftester explore v0.1 (apple-fm-on-device)")
                self.exploreLog.append("→ 生成コードをビルド検証中...")
                let url = try await Task.detached {
                    try ScenarioCodeGen.writeValidated(code: code, className: className,
                                                       dir: generatedDir,
                                                       quarantineDir: quarantineDir,
                                                       project: project)
                }.value
                self.exploreLog.append("📄 生成: \(url.path)")
                self.exploreLog.append("   実行: ftester run --project \(project.name)"
                                       + " --scenario \(className).\(ScenarioCodeGen.methodName(1))")
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
