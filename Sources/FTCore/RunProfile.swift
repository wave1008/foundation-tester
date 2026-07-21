// RunProfile.swift
// 実行プロファイルの組み合わせ型モデル。
//   apps/<name>.json     … アプリケーションプロファイル(common/ios/android セクション)
//   machines/<マシン名>.json … マシンプロファイル(ios/android セクションに name 付きデバイス)
//   runs/<name>.json     … 実行プロファイル(app 参照+デバイス name リスト+実行時設定)
// ProfileResolver が 3 つを合成して ResolvedProfile(検証済み)を作る。
// 実行コード(CLI/MCP)は ResolvedProfile のみを参照する。
// JSON 形式は vscode-ftester/schemas/{app,machine,run}-profile.schema.json と同期を要する
// (knownKeys・必須/任意フィールドを変更したらスキーマ側も更新する)。

import Foundation

// MARK: - JSON ドキュメント(ファイルの素の形)

/// アプリケーションプロファイルの 1 セクション。フィールドごとに有効な記述場所が異なる
/// (対応表は merging 参照): appName = common→platform マージ / app・appPath = platform のみ /
/// autoInstall = common のみ
public struct AppProfileSection: Codable, Sendable, Equatable {
    /// ユーザーがアプリを識別するための表示名(レポート/ログで使用)
    public var appName: String?
    /// bundle identifier / パッケージ名
    public var app: String?
    /// パッケージファイル(.app / .apk)のパス。プロジェクトルート相対 or 絶対 or ~
    public var appPath: String?
    /// 実行前に appPath を自動インストールするか(既定 false = 無効)
    public var autoInstall: Bool?

    public init(appName: String? = nil, app: String? = nil,
                appPath: String? = nil, autoInstall: Bool? = nil) {
        self.appName = appName
        self.app = app
        self.appPath = appPath
        self.autoInstall = autoInstall
    }

    static let knownKeys: Set<String> = ["appName", "app", "appPath", "autoInstall"]

    /// common(self)と platform セクション(other)の合成(section(for:)専用)。フィールドごとに
    /// 採用元が異なる: appName = common→platform 後勝ち(表示名は共通定義が自然なため) /
    /// app・appPath = platform のみ(OS ごとに実体が異なるため) /
    /// autoInstall = common のみ(インストール可否は OS 間で揃えるべき運用設定のため)。
    /// 廃止側のセクションに書かれた値はここで黙って無視される(validate が警告を出す)。
    /// other が nil(platform セクション自体が無い)場合も同じ規則で合成するため、
    /// early return せず常に other?.field / self.field を明示的に選ぶ
    func merging(_ other: AppProfileSection?) -> AppProfileSection {
        AppProfileSection(
            appName: other?.appName ?? appName,
            app: other?.app,
            appPath: other?.appPath,
            autoInstall: autoInstall)
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

    /// common と platform セクションを合成した実効セクション(規則は merging 参照)
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
    /// iOS: 駆動エンジン。"xcuitest"(既定)= Runner/ の XCUITest ブリッジ、
    /// "inapp" = シミュレータのアプリに dylib 注入する in-app ブリッジ(実機不可)
    public var engine: String?
    /// Android: AVD(ID または表示名。起動中エミュレータとの照合で adb シリアルに解決)
    public var avd: String?

    public init(name: String, simulator: String? = nil, os: String? = nil,
                udid: String? = nil, port: UInt16? = nil, engine: String? = nil, avd: String? = nil) {
        self.name = name
        self.simulator = simulator
        self.os = os
        self.udid = udid
        self.port = port
        self.engine = engine
        self.avd = avd
    }

    static let knownKeys: Set<String> = ["name", "simulator", "os", "udid", "port", "engine", "avd"]
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
    /// シナリオ単位の壁時計タイムアウト秒(ホスト側 watchdog。子には渡さない。省略時 90)。
    /// defaultTimeout(子内部の検証待ち)とは別物
    public var scenarioTimeout: Int?
    /// devices を解決するマシンプロファイル名の明示指定(machines/<machine>.json)。
    /// 省略可(既存プロファイルとの後方互換のため必須にしない)。優先順位は
    /// ProfileResolver.determineMachine 参照
    public var machine: String?
    /// iOS の高速な in-app エンジン(ハイブリッド)を使うか(既定 true=ON)。
    /// true → iOS デバイスの実効エンジンを "hybrid"(in-app 主+XCUITest フォールバック)、
    /// false → "xcuitest" にする。マシンプロファイルでデバイスに engine を明示している場合は
    /// そちらが優先(resolve 参照)。Android には影響しない。
    public var iosInappEngine: Bool?
    /// 実行開始時に Android AVD の肥大化(wipe 対象ファイル合計サイズ)を検査し超過分を
    /// Wipe Data するか(既定 true=ON)。同期相手: vscode-ftester/schemas/run-profile.schema.json
    /// と src/monitorModel.ts の RunProfileFormFields
    public var wipeDataOnBloat: Bool?
    /// wipeDataOnBloat のしきい値(GB、1GB=1_073_741_824 バイト。既定 8。0 以下は検証エラー。
    /// Play イメージは wipe 直後の再構築だけで userdata が 2〜4GB になるため(実測 2026-07-17)、
    /// それ未満のしきい値は毎実行 wipe が発動するスラッシングになる — 下げるときは要注意)
    public var wipeDataThresholdGB: Double?
    /// Android エミュレータのブート完了時(Wipe Data 後の再起動を含む)にブリッジ /locale で
    /// 適用するロケール(既定 "ja_JP"。Play イメージでは -change-locale 等が無効なため。
    /// design.md §11.2)。iOS には影響しない。同期相手: vscode-ftester/schemas/run-profile.schema.json
    /// と src/monitorModel.ts の RunProfileFormFields
    public var locale: String?
    /// iOS/Android の駆動エンジンを直接指定する(例 "appium")。マシンプロファイルで
    /// DeviceSpec.engine を明示している場合はそちらが優先。iosInappEngine 由来の
    /// hybrid/xcuitest 選択より優先度が高い
    public var engine: String?
    /// iOS xcuitest ブリッジの高速入力(quiescence 待ちスキップ。PoC)。true で FT_FAST_INPUT=1 を
    /// 実行環境に注入する(伝搬経路は BridgeClient.fastInput 参照)。動きの激しい画面では
    /// 整定前タップのフレークリスクを伴う
    public var iosFastInput: Bool?

    public init(app: String? = nil, devices: [RunDeviceRef]? = nil, heal: Bool? = nil,
                reportDir: String? = nil, defaultTimeout: Int? = nil, scenarioTimeout: Int? = nil,
                machine: String? = nil, iosInappEngine: Bool? = nil,
                wipeDataOnBloat: Bool? = nil, wipeDataThresholdGB: Double? = nil,
                locale: String? = nil, engine: String? = nil, iosFastInput: Bool? = nil) {
        self.app = app
        self.devices = devices
        self.heal = heal
        self.reportDir = reportDir
        self.defaultTimeout = defaultTimeout
        self.scenarioTimeout = scenarioTimeout
        self.machine = machine
        self.iosInappEngine = iosInappEngine
        self.wipeDataOnBloat = wipeDataOnBloat
        self.wipeDataThresholdGB = wipeDataThresholdGB
        self.locale = locale
        self.engine = engine
        self.iosFastInput = iosFastInput
    }

    static let knownKeys: Set<String> = [
        "app", "devices", "heal", "reportDir", "defaultTimeout", "scenarioTimeout",
        "machine", "iosInappEngine", "wipeDataOnBloat", "wipeDataThresholdGB", "locale", "engine",
        "iosFastInput",
    ]
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
    /// 実行前に appPath を自動インストールするか(既定 false = 無効。
    /// common セクションで明示的に true にした場合のみ有効)
    public let autoInstall: Bool

    public init(bundleID: String, appPath: String? = nil, autoInstall: Bool = false) {
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
    /// シナリオ単位の壁時計タイムアウト秒(ホスト側 watchdog。nil=未指定→run 側で既定 90 を適用)
    public let scenarioTimeout: Int?
    /// 実行開始時に Android AVD 肥大化を Wipe Data するか(既定 true)
    public let wipeDataOnBloat: Bool
    /// wipeDataOnBloat のしきい値(GB)
    public let wipeDataThresholdGB: Double
    /// Android エミュレータのブート時に -change-locale で適用するロケール(既定 "ja_JP")
    public let locale: String
    /// iOS xcuitest ブリッジの高速入力(RunProfileDocument.iosFastInput。既定 false)
    public let iosFastInput: Bool
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
    /// 実行プロファイルが明示指定した machine が machines/ に存在しない
    /// (CLI/env で決定した machineProfileNotFound と区別し、原因が実行プロファイル側の
    /// 指定であることをメッセージで明確にする)
    case runSpecifiedMachineNotFound(run: String, machine: String, available: [String])
    case machineUndetermined(available: [String])
    case decodeFailed(URL, detail: String)
    case missingAppReference(run: String)
    case missingDevices(run: String)
    case duplicateDeviceName(name: String, machine: String)
    case noDevicesResolved(run: String, machine: String, requested: [String], available: [String])
    case missingBundleID(platform: String, appProfile: String)
    case invalidWipeDataThreshold(run: String)
    case invalidLocale(run: String)

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
        case .runSpecifiedMachineNotFound(let run, let machine, let available):
            return "実行プロファイル \(run) が指定するマシンプロファイル「\(machine)」が見つかりません"
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
            // common の app は廃止(merging 参照)のため、案内は platform セクション限定
            return "アプリケーションプロファイル \(appProfile) に \(platform) の \"app\""
                + "(bundle ID / パッケージ名)がありません(\(platform) セクションに記述)"
        case .invalidWipeDataThreshold(let run):
            return "実行プロファイル \(run) の wipeDataThresholdGB は正の数(GB)で指定してください"
        case .invalidLocale(let run):
            return "実行プロファイル \(run) の locale は ja_JP のような形式で指定してください"
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

    /// マシン決定: 実行プロファイル自身の machine 指定 > FT_MACHINE > 登録名 >
    /// machines/ が 1 ファイルならそれ > エラー。
    /// runProfileName を渡すと、そのプロファイルが machine(trim 後非空)を明示指定している場合に
    /// 最優先でそれを使う(未登録・複数マシンの環境でも実行プロファイルの明示指定だけで解決できる
    /// ようにするため)。ファイルが無い/デコード不能/machine 未指定はここでは無視し、
    /// 通常どおり resolve() 側の runProfileNotFound/decodeFailed/missingDevices 等に委ねる。
    /// 明示指定された machine が machines/ に存在しない場合のみ、ここで
    /// runSpecifiedMachineNotFound を投げる(resolve() を経由しない呼び出し側でも
    /// 同じ明確なエラーになるようにするため)。
    /// 戻り値 auto = 自動採用だったか(呼び出し側がログ表示に使う。明示指定/FT_MACHINE/登録名は false)
    public static func determineMachine(
        project: TestProject,
        environment: [String: String] = ProcessInfo.processInfo.environment,
        registered: String?,
        runProfileName: String? = nil
    ) throws -> (name: String, auto: Bool) {
        if let runProfileName,
           let explicit = explicitMachine(project: project, runProfileName: runProfileName) {
            let machineURL = project.machinesDir.appendingPathComponent("\(explicit).json")
            guard FileManager.default.fileExists(atPath: machineURL.path) else {
                throw ProfileError.runSpecifiedMachineNotFound(
                    run: runProfileName, machine: explicit, available: machineNames(project: project))
            }
            return (explicit, false)
        }
        if let env = environment["FT_MACHINE"], !env.isEmpty { return (env, false) }
        if let registered, !registered.isEmpty { return (registered, false) }
        let machines = machineNames(project: project)
        if machines.count == 1 { return (machines[0], true) }
        throw ProfileError.machineUndetermined(available: machines)
    }

    /// runProfileName の実行プロファイルが指定する machine(trim 後非空)を返す。
    /// ファイルが無い/デコード不能/未指定・空文字列なら nil(呼び出し側は fallback を使う。
    /// ファイル自体の欠落・型不一致は resolve() 側で改めて明確なエラーにする)
    private static func explicitMachine(project: TestProject, runProfileName: String) -> String? {
        let runURL = project.runsDir.appendingPathComponent("\(runProfileName).json")
        guard let data = try? Data(contentsOf: runURL),
              let doc = try? JSONDecoder().decode(RunProfileDocument.self, from: data),
              let machine = doc.machine?.trimmingCharacters(in: .whitespacesAndNewlines),
              !machine.isEmpty else {
            return nil
        }
        return machine
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
        // runDoc.machine の明示指定は引数 machineName(determineMachine の結果)より優先。
        // 食い違っていても警告は出さない(明示指定が勝つ、で一貫させる)
        var machineName = machineName
        let explicitMachine = runDoc.machine?.trimmingCharacters(in: .whitespacesAndNewlines)
        if let explicitMachine, !explicitMachine.isEmpty {
            machineName = explicitMachine
        }
        let machineURL = project.machinesDir.appendingPathComponent("\(machineName).json")
        guard FileManager.default.fileExists(atPath: machineURL.path) else {
            if let explicitMachine, !explicitMachine.isEmpty {
                throw ProfileError.runSpecifiedMachineNotFound(
                    run: runName, machine: explicitMachine, available: machineNames(project: project))
            }
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

        // 4. デバイス解決(このマシンに無い name はスキップ+警告)。
        // iOS 実効エンジン: 実行プロファイルの iosInappEngine(既定 true)で決める。
        // true → "hybrid"(高速な in-app 主+XCUITest フォールバック)、false → "xcuitest"。
        // ただしマシンプロファイルでデバイスに engine を明示していればそちらが優先(上書きしない)。
        let explicitRunEngine = runDoc.engine?.trimmingCharacters(in: .whitespacesAndNewlines)
        let iosEngine = (explicitRunEngine?.isEmpty == false)
            ? explicitRunEngine!
            : ((runDoc.iosInappEngine ?? true) ? "hybrid" : "xcuitest")
        var devices: [ResolvedDevice] = []
        for ref in deviceRefs {
            if let device = catalog[ref.name] {
                if device.platform == "ios", device.spec.engine == nil {
                    var spec = device.spec
                    spec.engine = iosEngine
                    devices.append(ResolvedDevice(platform: "ios", spec: spec))
                } else {
                    // フラグを明示指定したのにデバイス側 engine が勝つ組み合わせは
                    // GUI のチェックボックスが「効かない」ように見えるため警告で知らせる
                    if device.platform == "ios", runDoc.iosInappEngine != nil,
                       let explicit = device.spec.engine {
                        warnings.append(
                            "デバイス \"\(ref.name)\" はマシンプロファイルで engine=\(explicit) を"
                            + "明示しているため iosInappEngine の指定は適用されません")
                    }
                    devices.append(device)
                }
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

        // 5. アプリ解決(デバイスのある platform ごと。合成規則は AppProfileSection.merging 参照)
        // appPath の相対パスは「リポジトリルート」基準(project.rootURL = <repoRoot>/Projects/<name> の
        // 2 階層上)。ビルド成果物は Projects/ 外(リポジトリ直下の builds/ 等)に置くのが普通なため。
        // packageRoot() の CWD 走査は使わない(単体テストでは CWD が本体リポジトリを指し誤基準になる。
        // project.rootURL からの決定的導出で統一)。reportDir だけはプロジェクト直下に出すため下記で
        // project.rootURL 基準のまま(基準が異なるので resolvePath の base で使い分ける)。
        let repoRoot = project.rootURL.deletingLastPathComponent().deletingLastPathComponent()
        var apps: [String: ResolvedAppTarget] = [:]
        for platform in Set(devices.map(\.platform)) {
            let section = appProfile.section(for: platform)
            guard let bundleID = section.app else {
                throw ProfileError.missingBundleID(platform: platform, appProfile: appRef)
            }
            apps[platform] = ResolvedAppTarget(
                bundleID: bundleID,
                appPath: section.appPath.map { resolvePath($0, base: repoRoot) },
                // autoInstall 未指定時の既定は false(無効)。appPath 指定+未指定のまま
                // 実行前インストールされてしまう事故を避けるため、明示指定を必須とする
                autoInstall: section.autoInstall ?? false)
        }

        let reportDir = URL(fileURLWithPath:
            resolvePath(runDoc.reportDir ?? "reports", base: project.rootURL))

        let wipeDataThresholdGB = runDoc.wipeDataThresholdGB ?? 8
        guard wipeDataThresholdGB > 0 else {
            throw ProfileError.invalidWipeDataThreshold(run: runName)
        }

        let locale = (runDoc.locale ?? "ja_JP").trimmingCharacters(in: .whitespacesAndNewlines)
        guard isValidLocale(locale) else {
            throw ProfileError.invalidLocale(run: runName)
        }

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
            scenarioTimeout: runDoc.scenarioTimeout,
            wipeDataOnBloat: runDoc.wipeDataOnBloat ?? true,
            wipeDataThresholdGB: wipeDataThresholdGB,
            locale: locale,
            iosFastInput: runDoc.iosFastInput ?? false,
            warnings: warnings)
    }

    /// locale 形式検証(trim 済み文字列を渡すこと): 言語[-地域/バリアント...](BCP47 風の緩い検査)
    private static func isValidLocale(_ value: String) -> Bool {
        value.range(of: "^[A-Za-z]{2,3}([-_][A-Za-z0-9]{2,8})*$", options: .regularExpression) != nil
    }

    /// チルダ展開+相対パスは呼び出し側が渡す base 基準で絶対化
    /// (base は用途で異なる: appPath=リポジトリルート / reportDir=プロジェクトルート。resolve 参照)
    public static func resolvePath(_ path: String, base: URL) -> String {
        let expanded = (path as NSString).expandingTildeInPath
        if expanded.hasPrefix("/") { return expanded }
        return base.appendingPathComponent(expanded).standardizedFileURL.path
    }

    // MARK: - 単一ファイル検証(プロファイルエディタ用)

    /// プロファイルファイル 1 つの検証。戻り値: (エラー, 警告)。
    /// エラー = デコード不能・必須欠落・name 重複、警告 = 未知キー(タイポ検出)。
    /// project は .run の machine フィールド検証(参照先の machines/ 存在チェック)にのみ使う
    public static func validate(
        kind: ProfileFileKind, data: Data, context: String, project: TestProject
    ) -> (errors: [String], warnings: [String]) {
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
            warnings += checkDeprecatedSectionKeys(json, context: context)
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
                if let threshold = doc.wipeDataThresholdGB, threshold <= 0 {
                    errors.append("\"wipeDataThresholdGB\" は正の数(GB)で指定してください")
                }
                let locale = (doc.locale ?? "ja_JP").trimmingCharacters(in: .whitespacesAndNewlines)
                if !isValidLocale(locale) {
                    errors.append("\"locale\" は ja_JP のような形式で指定してください")
                }
            } else {
                errors.append("実行プロファイルとして読み込めません(型不一致)")
            }
            warnings += checkKeys(json, allowed: RunProfileDocument.knownKeys, context: context)
            warnings += checkDeviceRefKeys(json, context: context)
            let (machineErrors, machineWarnings) = checkRunMachineField(json, project: project)
            errors += machineErrors
            warnings += machineWarnings
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

    /// 実行プロファイルの machine フィールドの検証(型・参照先の存在・未指定)。
    /// - 存在して string 型でない(JSON null は「未指定」と同義に扱う) → エラー
    /// - 非空文字列だが machines/<machine>.json が無い → エラー(明示指定なので明確に伝える)
    /// - 未指定/空文字列 → 警告(既存プロファイルを壊さないための後方互換。エラーにはしない)
    private static func checkRunMachineField(
        _ json: [String: Any], project: TestProject
    ) -> (errors: [String], warnings: [String]) {
        let unspecifiedWarning = "machine が未指定です(使用するマシンプロファイルの明示指定を推奨)"
        guard let raw = json["machine"], !(raw is NSNull) else {
            return ([], [unspecifiedWarning])
        }
        guard let machineName = raw as? String else {
            return (["\"machine\" は文字列で指定してください"], [])
        }
        let trimmed = machineName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            return ([], [unspecifiedWarning])
        }
        guard machineNames(project: project).contains(trimmed) else {
            return (["\"machine\" が指すマシンプロファイル「\(trimmed)」が見つかりません"], [])
        }
        return ([], [])
    }

    /// セクション別に廃止されたキーの検査(廃止の理由は AppProfileSection.merging 参照)。
    /// 存在すれば警告のみ(値自体は merging で無視されるだけなので後方互換上エラーにはしない)
    private static func checkDeprecatedSectionKeys(_ json: [String: Any],
                                                   context: String) -> [String] {
        // (セクション, 廃止キー, 移動先の案内, 補足)。表示順を安定させるため明示配列で回す
        let rules: [(section: String, key: String, moveTo: String, hint: String)] = [
            ("common", "app", "ios/android", ""),
            ("common", "appPath", "ios/android", ""),
            ("ios", "autoInstall", "common", "(既定は無効)"),
            ("android", "autoInstall", "common", "(既定は無効)"),
        ]
        return rules.compactMap { rule in
            guard let section = json[rule.section] as? [String: Any],
                  section[rule.key] != nil else { return nil }
            return "\(context) \(rule.section): \"\(rule.key)\" は廃止されました。"
                + "\(rule.moveTo) セクションで指定してください\(rule.hint)"
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
