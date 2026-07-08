// RunProfile.swift
// 実行プロファイルの組み合わせ型モデル。
//   apps/<name>.json     … アプリケーションプロファイル(common/ios/android セクション)
//   machines/<マシン名>.json … マシンプロファイル(ios/android セクションに name 付きデバイス)
//   runs/<name>.json     … 実行プロファイル(app 参照+デバイス name リスト+実行時設定)
// ProfileResolver が 3 つを合成して ResolvedProfile(検証済み)を作る。
// 実行コード(CLI/GUI/MCP)は ResolvedProfile のみを参照する。

import Foundation

// MARK: - JSON ドキュメント(ファイルの素の形)

/// アプリケーションプロファイルの 1 セクション。common → ios/android の順で後勝ちマージされる
public struct AppProfileSection: Codable, Sendable, Equatable {
    /// ユーザーがアプリを識別するための表示名(レポート/GUI/ログで使用)
    public var appName: String?
    /// bundle identifier / パッケージ名
    public var app: String?
    /// パッケージファイル(.app / .apk)のパス。プロジェクトルート相対 or 絶対 or ~
    public var appPath: String?
    /// 実行前に appPath を自動インストールするか(既定 true)
    public var autoInstall: Bool?

    public init(appName: String? = nil, app: String? = nil,
                appPath: String? = nil, autoInstall: Bool? = nil) {
        self.appName = appName
        self.app = app
        self.appPath = appPath
        self.autoInstall = autoInstall
    }

    static let knownKeys: Set<String> = ["appName", "app", "appPath", "autoInstall"]

    /// 後勝ちマージ(other の非 nil フィールドが勝つ)
    func merging(_ other: AppProfileSection?) -> AppProfileSection {
        guard let other else { return self }
        return AppProfileSection(
            appName: other.appName ?? appName,
            app: other.app ?? app,
            appPath: other.appPath ?? appPath,
            autoInstall: other.autoInstall ?? autoInstall)
    }
}

public struct AppProfile: Codable, Sendable, Equatable {
    public var common: AppProfileSection?
    public var ios: AppProfileSection?
    public var android: AppProfileSection?

    public init(common: AppProfileSection? = nil, ios: AppProfileSection? = nil,
                android: AppProfileSection? = nil) {
        self.common = common
        self.ios = ios
        self.android = android
    }

    static let knownKeys: Set<String> = ["common", "ios", "android"]

    /// common → platform セクションの順で合成した実効セクション
    public func section(for platform: String) -> AppProfileSection {
        let base = common ?? AppProfileSection()
        switch platform {
        case "ios": return base.merging(ios)
        case "android": return base.merging(android)
        default: return base
        }
    }

    /// 表示名(common 優先。無ければどちらかのセクション)
    public var resolvedAppName: String? {
        common?.appName ?? ios?.appName ?? android?.appName
    }
}

/// マシンプロファイル内の 1 デバイス定義
public struct DeviceSpec: Codable, Sendable, Hashable {
    /// ユーザーがデバイスを識別するための名前(実行プロファイルからの参照キー)
    public var name: String
    /// iOS: シミュレータのデバイス名(例 "iPhone 17 Pro")
    public var simulator: String?
    /// iOS: OS バージョン(例 "27.0"。省略時は名前一致の最新)
    public var os: String?
    /// iOS: シミュレータ UDID(指定時は simulator/os より優先)
    public var udid: String?
    /// iOS: ブリッジポートの固定(省略時は自動採番)
    public var port: UInt16?
    /// Android: AVD(ID または表示名。起動中エミュレータとの照合で adb シリアルに解決)
    public var avd: String?

    public init(name: String, simulator: String? = nil, os: String? = nil,
                udid: String? = nil, port: UInt16? = nil, avd: String? = nil) {
        self.name = name
        self.simulator = simulator
        self.os = os
        self.udid = udid
        self.port = port
        self.avd = avd
    }

    static let knownKeys: Set<String> = ["name", "simulator", "os", "udid", "port", "avd"]
}

public struct MachineDeviceList: Codable, Sendable, Equatable {
    public var devices: [DeviceSpec]?

    public init(devices: [DeviceSpec]? = nil) { self.devices = devices }

    static let knownKeys: Set<String> = ["devices"]
}

/// マシンプロファイル(profiles/machines/<マシン名>.json)。ファイル名がマシン名
public struct MachineProfile: Codable, Sendable, Equatable {
    public var ios: MachineDeviceList?
    public var android: MachineDeviceList?

    public init(ios: MachineDeviceList? = nil, android: MachineDeviceList? = nil) {
        self.ios = ios
        self.android = android
    }

    static let knownKeys: Set<String> = ["ios", "android"]
}

/// 実行プロファイルのデバイス参照(name でマシンプロファイルを引く)
public struct RunDeviceRef: Codable, Sendable, Equatable {
    public var name: String

    public init(name: String) { self.name = name }

    static let knownKeys: Set<String> = ["name"]
}

/// 実行プロファイル(profiles/runs/<name>.json)
public struct RunProfileDocument: Codable, Sendable, Equatable {
    /// apps/<app>.json への参照
    public var app: String?
    /// 実行に使うデバイス(name 参照。iOS/Android 混在可 = 両OS同時実行)
    public var devices: [RunDeviceRef]?
    /// FM によるロケータ自己修復を許可するか(既定 false)
    public var heal: Bool?
    /// レポート出力先(プロジェクトルート相対 or 絶対。既定 "reports")
    public var reportDir: String?
    /// DSL コマンドの既定タイムアウト秒(省略時は DSL 側の既定値)
    public var defaultTimeout: Int?

    public init(app: String? = nil, devices: [RunDeviceRef]? = nil, heal: Bool? = nil,
                reportDir: String? = nil, defaultTimeout: Int? = nil) {
        self.app = app
        self.devices = devices
        self.heal = heal
        self.reportDir = reportDir
        self.defaultTimeout = defaultTimeout
    }

    static let knownKeys: Set<String> = ["app", "devices", "heal", "reportDir", "defaultTimeout"]
}

// MARK: - 解決済みモデル

/// マシンプロファイルから解決されたデバイス(所属プラットフォーム確定)
public struct ResolvedDevice: Sendable, Hashable {
    public let platform: String  // "ios" / "android"
    public let spec: DeviceSpec
    public var name: String { spec.name }

    public init(platform: String, spec: DeviceSpec) {
        self.platform = platform
        self.spec = spec
    }
}

/// プラットフォーム毎に解決されたアプリ情報
public struct ResolvedAppTarget: Sendable, Hashable {
    public let bundleID: String
    /// 絶対パス解決済みのパッケージファイル(nil = インストールしない)
    public let appPath: String?
    public let autoInstall: Bool

    public init(bundleID: String, appPath: String? = nil, autoInstall: Bool = true) {
        self.bundleID = bundleID
        self.appPath = appPath
        self.autoInstall = autoInstall
    }
}

/// 合成・検証済みの実行プロファイル。実行コードはこれだけを見る
public struct ResolvedProfile: Sendable {
    public let project: TestProject
    public let runName: String
    public let machineName: String
    /// アプリの表示名(apps/<name>.json の appName。無ければファイル名)
    public let appName: String
    /// platform("ios"/"android")→ アプリ情報(デバイスがある platform のみ)
    public let apps: [String: ResolvedAppTarget]
    public let devices: [ResolvedDevice]
    public let heal: Bool
    /// 絶対パス解決済み
    public let reportDir: URL
    public let defaultTimeout: Int?
    /// 解決中に出た警告(スキップしたデバイス・未知キー等)。呼び出し側が表示する
    public let warnings: [String]

    public var iosDevices: [ResolvedDevice] { devices.filter { $0.platform == "ios" } }
    public var androidDevices: [ResolvedDevice] { devices.filter { $0.platform == "android" } }
}

/// プロファイルファイルの種別(profiles/ 配下のサブディレクトリと対応)
public enum ProfileFileKind: String, CaseIterable, Sendable {
    case app, machine, run

    /// profiles/ 配下のサブディレクトリ名
    public var directoryName: String {
        switch self {
        case .app: return "apps"
        case .machine: return "machines"
        case .run: return "runs"
        }
    }

    public var label: String {
        switch self {
        case .app: return "アプリ"
        case .machine: return "マシン"
        case .run: return "実行"
        }
    }
}

// MARK: - エラー

public enum ProfileError: Error, LocalizedError {
    case runProfileNotFound(name: String, available: [String])
    case appProfileNotFound(name: String, available: [String])
    case machineProfileNotFound(machine: String, available: [String])
    case machineUndetermined(available: [String])
    case decodeFailed(URL, detail: String)
    case missingAppReference(run: String)
    case missingDevices(run: String)
    case duplicateDeviceName(name: String, machine: String)
    case noDevicesResolved(run: String, machine: String, requested: [String], available: [String])
    case missingBundleID(platform: String, appProfile: String)

    public var errorDescription: String? {
        switch self {
        case .runProfileNotFound(let name, let available):
            return "実行プロファイルが見つかりません: \(name)"
                + availableHint(available, empty: "profiles/runs/ が空です")
        case .appProfileNotFound(let name, let available):
            return "アプリケーションプロファイルが見つかりません: \(name)"
                + availableHint(available, empty: "profiles/apps/ が空です")
        case .machineProfileNotFound(let machine, let available):
            return "マシンプロファイルが見つかりません: \(machine)"
                + availableHint(available, empty: "profiles/machines/ が空です")
        case .machineUndetermined(let available):
            return "マシン名が未登録です。ftester machine set \"<マシン名>\" で登録するか "
                + "FT_MACHINE 環境変数を設定してください"
                + availableHint(available, empty: "profiles/machines/ が空です")
        case .decodeFailed(let url, let detail):
            return "プロファイルを読み込めません: \(url.path)\n\(detail)"
        case .missingAppReference(let run):
            return "実行プロファイル \(run) に \"app\"(apps/ への参照)がありません"
        case .missingDevices(let run):
            return "実行プロファイル \(run) に \"devices\" がありません"
        case .duplicateDeviceName(let name, let machine):
            return "マシンプロファイル \(machine) でデバイス名が重複しています: \(name)"
                + "(name は ios/android 横断で一意にしてください)"
        case .noDevicesResolved(let run, let machine, let requested, let available):
            return "実行プロファイル \(run) のデバイスがマシン \(machine) で 1 台も解決できません"
                + "(要求: \(requested.joined(separator: ", ")) / "
                + "定義済み: \(available.isEmpty ? "なし" : available.joined(separator: ", ")))"
        case .missingBundleID(let platform, let appProfile):
            return "アプリケーションプロファイル \(appProfile) に \(platform) の \"app\""
                + "(bundle ID / パッケージ名)がありません(common か \(platform) セクションに記述)"
        }
    }

    private func availableHint(_ available: [String], empty: String) -> String {
        available.isEmpty ? "(\(empty))" : "(利用可能: \(available.joined(separator: ", ")))"
    }
}

// MARK: - 解決

public enum ProfileResolver {

    /// profiles/runs/ の実行プロファイル名一覧(拡張子なし、名前順)
    public static func runProfileNames(project: TestProject) -> [String] {
        jsonNames(in: project.runsDir)
    }

    /// profiles/machines/ のマシン名一覧
    public static func machineNames(project: TestProject) -> [String] {
        jsonNames(in: project.machinesDir)
    }

    /// profiles/apps/ のアプリケーションプロファイル名一覧
    public static func appProfileNames(project: TestProject) -> [String] {
        jsonNames(in: project.appsDir)
    }

    /// マシン決定: FT_MACHINE > 登録名 > machines/ が 1 ファイルならそれ > エラー。
    /// 戻り値 auto = 自動採用だったか(呼び出し側がログ表示に使う)
    public static func determineMachine(
        project: TestProject,
        environment: [String: String] = ProcessInfo.processInfo.environment,
        registered: String?
    ) throws -> (name: String, auto: Bool) {
        if let env = environment["FT_MACHINE"], !env.isEmpty { return (env, false) }
        if let registered, !registered.isEmpty { return (registered, false) }
        let machines = machineNames(project: project)
        if machines.count == 1 { return (machines[0], true) }
        throw ProfileError.machineUndetermined(available: machines)
    }

    /// 実行プロファイルを合成して ResolvedProfile を返す
    public static func resolve(project: TestProject, runName: String,
                               machineName: String) throws -> ResolvedProfile {
        var warnings: [String] = []

        // 1. 実行プロファイル
        let runURL = project.runsDir.appendingPathComponent("\(runName).json")
        guard FileManager.default.fileExists(atPath: runURL.path) else {
            throw ProfileError.runProfileNotFound(
                name: runName, available: runProfileNames(project: project))
        }
        let runDoc: RunProfileDocument = try load(runURL, warnings: &warnings) { json in
            checkKeys(json, allowed: RunProfileDocument.knownKeys, context: "runs/\(runName).json")
                + checkDeviceRefKeys(json, context: "runs/\(runName).json")
        }
        guard let appRef = runDoc.app else {
            throw ProfileError.missingAppReference(run: runName)
        }
        guard let deviceRefs = runDoc.devices, !deviceRefs.isEmpty else {
            throw ProfileError.missingDevices(run: runName)
        }

        // 2. アプリケーションプロファイル
        let appURL = project.appsDir.appendingPathComponent("\(appRef).json")
        guard FileManager.default.fileExists(atPath: appURL.path) else {
            throw ProfileError.appProfileNotFound(
                name: appRef, available: appProfileNames(project: project))
        }
        let appProfile: AppProfile = try load(appURL, warnings: &warnings) { json in
            checkAppProfileKeys(json, context: "apps/\(appRef).json")
        }

        // 3. マシンプロファイル → name → デバイスのカタログ
        let machineURL = project.machinesDir.appendingPathComponent("\(machineName).json")
        guard FileManager.default.fileExists(atPath: machineURL.path) else {
            throw ProfileError.machineProfileNotFound(
                machine: machineName, available: machineNames(project: project))
        }
        let machine: MachineProfile = try load(machineURL, warnings: &warnings) { json in
            checkMachineProfileKeys(json, context: "machines/\(machineName).json")
        }

        var catalog: [String: ResolvedDevice] = [:]
        var catalogOrder: [String] = []
        for (platform, list) in [("ios", machine.ios), ("android", machine.android)] {
            for spec in list?.devices ?? [] {
                guard catalog[spec.name] == nil else {
                    throw ProfileError.duplicateDeviceName(name: spec.name, machine: machineName)
                }
                catalog[spec.name] = ResolvedDevice(platform: platform, spec: spec)
                catalogOrder.append(spec.name)
            }
        }

        // 4. デバイス解決(このマシンに無い name はスキップ+警告)
        var devices: [ResolvedDevice] = []
        for ref in deviceRefs {
            if let device = catalog[ref.name] {
                devices.append(device)
            } else {
                warnings.append(
                    "デバイス \"\(ref.name)\" はマシン \(machineName) に定義がないためスキップします")
            }
        }
        guard !devices.isEmpty else {
            throw ProfileError.noDevicesResolved(
                run: runName, machine: machineName,
                requested: deviceRefs.map(\.name), available: catalogOrder)
        }

        // 5. アプリ解決(デバイスのある platform ごと。common → platform セクションの後勝ち)
        var apps: [String: ResolvedAppTarget] = [:]
        for platform in Set(devices.map(\.platform)) {
            let section = appProfile.section(for: platform)
            guard let bundleID = section.app else {
                throw ProfileError.missingBundleID(platform: platform, appProfile: appRef)
            }
            apps[platform] = ResolvedAppTarget(
                bundleID: bundleID,
                appPath: section.appPath.map { resolvePath($0, base: project.rootURL) },
                autoInstall: section.autoInstall ?? true)
        }

        let reportDir = URL(fileURLWithPath:
            resolvePath(runDoc.reportDir ?? "reports", base: project.rootURL))

        return ResolvedProfile(
            project: project,
            runName: runName,
            machineName: machineName,
            appName: appProfile.resolvedAppName ?? appRef,
            apps: apps,
            devices: devices,
            heal: runDoc.heal ?? false,
            reportDir: reportDir,
            defaultTimeout: runDoc.defaultTimeout,
            warnings: warnings)
    }

    /// チルダ展開+相対パスは base(プロジェクトルート)基準で絶対化
    public static func resolvePath(_ path: String, base: URL) -> String {
        let expanded = (path as NSString).expandingTildeInPath
        if expanded.hasPrefix("/") { return expanded }
        return base.appendingPathComponent(expanded).standardizedFileURL.path
    }

    // MARK: - 単一ファイル検証(GUI エディタ用)

    /// プロファイルファイル 1 つの検証。戻り値: (エラー, 警告)。
    /// エラー = デコード不能・必須欠落・name 重複、警告 = 未知キー(タイポ検出)
    public static func validate(kind: ProfileFileKind, data: Data,
                                context: String) -> (errors: [String], warnings: [String]) {
        guard let json = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else {
            return (["JSON として解析できません(構文エラー)"], [])
        }
        var errors: [String] = []
        var warnings: [String] = []
        let decoder = JSONDecoder()
        switch kind {
        case .app:
            if (try? decoder.decode(AppProfile.self, from: data)) == nil {
                errors.append("アプリケーションプロファイルとして読み込めません(型不一致)")
            }
            warnings += checkAppProfileKeys(json, context: context)
        case .machine:
            if let machine = try? decoder.decode(MachineProfile.self, from: data) {
                var seen = Set<String>()
                for list in [machine.ios, machine.android] {
                    for spec in list?.devices ?? [] where !seen.insert(spec.name).inserted {
                        errors.append("デバイス名が重複しています: \(spec.name)"
                                      + "(name は ios/android 横断で一意にしてください)")
                    }
                }
            } else {
                errors.append("マシンプロファイルとして読み込めません(型不一致)")
            }
            warnings += checkMachineProfileKeys(json, context: context)
        case .run:
            if let doc = try? decoder.decode(RunProfileDocument.self, from: data) {
                if doc.app == nil { errors.append("\"app\"(apps/ への参照)がありません") }
                if (doc.devices ?? []).isEmpty { errors.append("\"devices\" がありません") }
            } else {
                errors.append("実行プロファイルとして読み込めません(型不一致)")
            }
            warnings += checkKeys(json, allowed: RunProfileDocument.knownKeys, context: context)
            warnings += checkDeviceRefKeys(json, context: context)
        }
        return (errors, warnings)
    }

    // MARK: - 内部ヘルパー

    private static func jsonNames(in dir: URL) -> [String] {
        guard let entries = try? FileManager.default.contentsOfDirectory(
            at: dir, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles]) else {
            return []
        }
        return entries.filter { $0.pathExtension == "json" }
            .map { $0.deletingPathExtension().lastPathComponent }
            .sorted()
    }

    /// デコード+未知キー検査(タイポ検出)。未知キーは警告のみでエラーにしない
    private static func load<T: Decodable>(
        _ url: URL, warnings: inout [String],
        keyCheck: ([String: Any]) -> [String]
    ) throws -> T {
        let data: Data
        do {
            data = try Data(contentsOf: url)
        } catch {
            throw ProfileError.decodeFailed(url, detail: error.localizedDescription)
        }
        let value: T
        do {
            value = try JSONDecoder().decode(T.self, from: data)
        } catch {
            throw ProfileError.decodeFailed(url, detail: "\(error)")
        }
        if let json = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] {
            warnings.append(contentsOf: keyCheck(json))
        }
        return value
    }

    private static func checkKeys(_ json: [String: Any], allowed: Set<String>,
                                  context: String) -> [String] {
        json.keys.filter { !allowed.contains($0) }.sorted().map {
            "\(context): 未知のキー \"\($0)\" は無視されます"
        }
    }

    private static func checkDeviceRefKeys(_ json: [String: Any], context: String) -> [String] {
        guard let devices = json["devices"] as? [[String: Any]] else { return [] }
        return devices.flatMap {
            checkKeys($0, allowed: RunDeviceRef.knownKeys, context: "\(context) devices")
        }
    }

    private static func checkAppProfileKeys(_ json: [String: Any], context: String) -> [String] {
        var warnings = checkKeys(json, allowed: AppProfile.knownKeys, context: context)
        for key in AppProfile.knownKeys {
            if let section = json[key] as? [String: Any] {
                warnings += checkKeys(section, allowed: AppProfileSection.knownKeys,
                                      context: "\(context) \(key)")
            }
        }
        return warnings
    }

    private static func checkMachineProfileKeys(_ json: [String: Any],
                                                context: String) -> [String] {
        var warnings = checkKeys(json, allowed: MachineProfile.knownKeys, context: context)
        for key in MachineProfile.knownKeys {
            guard let section = json[key] as? [String: Any] else { continue }
            warnings += checkKeys(section, allowed: MachineDeviceList.knownKeys,
                                  context: "\(context) \(key)")
            for device in (section["devices"] as? [[String: Any]]) ?? [] {
                warnings += checkKeys(device, allowed: DeviceSpec.knownKeys,
                                      context: "\(context) \(key) devices")
            }
        }
        return warnings
    }
}
