// RunProfile.swift
// 実行プロファイルの組み合わせ型モデル。
//   apps/<name>.json     … アプリケーションプロファイル(common/ios/android セクション)
//   runs/<name>.json     … 実行プロファイル(app 参照+デバイスの実体リスト+実行時設定)
// ProfileResolver が 2 つを合成して ResolvedProfile(検証済み)を作る。
// 実行コード(CLI/MCP)は ResolvedProfile のみを参照する。
// **デバイスの台帳は実行プロファイルの devices だけ**(同じ台が複数の実行プロファイルに載る。
// 編集・削除は同じ (platform, machine, name) を持つ全ファイルへ伝播する = RunProfileDeviceEditor)。
// JSON 形式は vscode-fleetest/schemas/{app,run}-profile.schema.json と同期を要する
// (knownKeys・必須/任意フィールドを変更したらスキーマ側も更新する)。

import Foundation

// MARK: - JSON ドキュメント(ファイルの素の形)

/// アプリケーションプロファイルの 1 セクション。フィールドごとに有効な記述場所が異なる
/// (対応表は merging 参照): appName・app・appPath = platform のみ /
/// autoInstall = common のみ(未指定なら appPath の有無で決まる。false 明示で opt-out)
public struct AppProfileSection: Codable, Sendable, Equatable {
    /// ユーザーがアプリを識別するための表示名(レポート/ログで使用)
    public var appName: String?
    /// bundle identifier / パッケージ名
    public var app: String?
    /// パッケージファイル(.app / .apk / .apks)のパス。プロジェクトルート相対 or 絶対 or ~
    public var appPath: String?
    /// **実機に配るパッケージ**のパス(省略時は appPath)。iOS はシミュレータ用ビルド
    /// (iphonesimulator SDK・未署名)を実機へ入れられない —— `0xe8008014 invalid signature` で
    /// インストールが失敗するため、同じアプリでも成果物が2つ要る。**端末ごとにアプリ
    /// プロファイルを分けない**ためのフィールド(ユーザー決定)。
    /// Android は同じ APK が両方で動くので普通は書かない
    public var appPathPhysical: String?
    /// 実行前に appPath を自動インストールするか(既定 false = 無効)
    public var autoInstall: Bool?
    /// アプリが依存するバックエンドの死活確認 URL(common のみ)。実行開始前に到達確認し、
    /// 不達なら警告する(バックエンド停止でアプリがクラッシュ→全滅する事故の早期検知。
    /// 実害から追加)。ブロックはしない(オフライン検証を妨げない)
    public var healthCheckURL: String?

    public init(appName: String? = nil, app: String? = nil,
                appPath: String? = nil, appPathPhysical: String? = nil,
                autoInstall: Bool? = nil,
                healthCheckURL: String? = nil) {
        self.appName = appName
        self.app = app
        self.appPath = appPath
        self.appPathPhysical = appPathPhysical
        self.autoInstall = autoInstall
        self.healthCheckURL = healthCheckURL
    }

    /// セクションごとに**合成(merging)が実際に読むキーだけ**を既知とする。読まないキーを
    /// 既知に入れると checkAppProfileKeys の未知キー警告をすり抜け、書いたのに効かない設定が黙る
    static let commonKnownKeys: Set<String> = ["autoInstall", "healthCheckURL"]
    static let platformKnownKeys: Set<String> = ["appName", "app", "appPath", "appPathPhysical"]

    /// common(self)と platform セクション(other)の合成(section(for:)専用)。フィールドごとに
    /// 採用元が異なる: appName・app・appPath = platform のみ(OS ごとに書き分けるため。
    /// 表示名も common からは継承しない) /
    /// autoInstall = common のみ(未指定なら appPath の有無で決まる。false 明示で opt-out)(インストール可否は OS 間で揃えるべき運用設定のため)。
    /// common セクションの appName/app/appPath・platform セクションの autoInstall/healthCheckURL は
    /// ここで無視される(validate が未知キーとして警告する)。
    /// other が nil(platform セクション自体が無い)場合も同じ規則で合成するため、
    /// early return せず常に other?.field / self.field を明示的に選ぶ
    func merging(_ other: AppProfileSection?) -> AppProfileSection {
        AppProfileSection(
            appName: other?.appName,
            app: other?.app,
            appPath: other?.appPath,
            appPathPhysical: other?.appPathPhysical,
            autoInstall: autoInstall,
            healthCheckURL: healthCheckURL)  // autoInstall と同じく common のみ
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

    /// 表示名(ios/android セクションのみ採用。common には appName を置けない — merging 参照)
    public var resolvedAppName: String? {
        ios?.appName ?? android?.appName
    }
}

/// デバイスの実体種別。省略時は virtual(既存プロファイルは無改修で動く)
public enum DeviceKind: String, Codable, Sendable, Hashable {
    /// iOS シミュレータ / Android エミュレータ
    case virtual
    /// 実機(iOS は udid、Android は serial で同定する)
    case physical
}

/// デバイス 1 台の実体定義(実行プロファイルの devices[] 1要素から platform/enabled を除いたもの)
public struct DeviceSpec: Codable, Sendable, Hashable {
    /// デバイスの名前。**iOS シミュレータではシミュレータ自身の名前**(Xcode の Name = simctl の名前)と
    /// 一致させる —— udid が無いときはこの名前(+ os)でシミュレータを探す。拡張の編集フォームでは
    /// iOS シミュレータの名前を変えさせない(変えるとシミュレータ側とずれる)。
    /// **一意なのは name 単体ではなく (machine, name)** —— 別のホストに同名のデバイスが居てよい
    /// (フリートの各機が同じ命名規則でシミュレータを作るため、同名は例外ではなく通常)
    public var name: String
    /// このデバイスが居る機械。省略時は手元(ツールは常に明示して書く)。
    /// 書けるのは**登録名**だけ(ssh の実体は書けない = プロファイルはプロジェクト資産)。
    /// 解決規則は DeviceMachineGrouping、正規化は MachineDispatch.normalize。
    /// **JSON キーは "machine"**。旧キー "host" も読む(既存プロファイルは無改修)
    public var machine: String?
    /// 実体種別(省略時 virtual)。実機の識別子は iOS=udid / Android=serial
    public var kind: DeviceKind?
    /// OS バージョン(Xcode の OS Version と同じ表記。例 "iOS 27.0" / Android 実機は "Android 13")。
    /// **JSON キーは "osVersion"**。iOS シミュレータでは udid が無いときの実体解決に使う
    /// (省略時は名前一致の最新)。実機では**表示専用**(model と同じく登録時に控えるだけ)
    public var osVersion: String?
    /// iOS: UDID。kind=virtual ならシミュレータ UDID(name/os より優先)、
    /// kind=physical なら実機の識別子(必須)。`xcrun devicectl list devices` の Identifier 列と
    /// ハードウェア UDID("00008130-..." 形式)のどちらでも解決する(内部では常に後者に正規化。
    /// xcodebuild の -destination id= が受け付けるのは後者だけのため)
    public var udid: String?
    /// iOS: ブリッジポートの固定(省略時は自動採番)
    public var port: UInt16?
    /// iOS: 駆動エンジン。"xcuitest"(既定)= Runner/ の XCUITest ブリッジ、
    /// "inapp" = シミュレータのアプリに dylib 注入する in-app ブリッジ(実機不可)
    public var engine: String?
    /// Android: AVD(ID または表示名。起動中エミュレータとの照合で adb シリアルに解決)
    public var avd: String?
    /// Android 実機: adb シリアル(USB は "14141JEC204922"、WiFi は "192.168.1.23:5555")。
    /// kind=physical のとき必須。エミュレータには使わない(avd から解決するため)
    public var serial: String?
    /// 機種名(iOS シミュレータは Xcode の Model = device type 名、iOS 実機は marketingName、
    /// Android は AVD の機種 / ro.product.model)。**表示専用**で同定には使わない
    /// (登録時に控えるだけ。端末を挿し替えても値は追随しない)
    public var model: String?

    public init(name: String, machine: String? = nil, kind: DeviceKind? = nil,
                osVersion: String? = nil,
                udid: String? = nil, port: UInt16? = nil, engine: String? = nil,
                avd: String? = nil, serial: String? = nil, model: String? = nil) {
        self.name = name
        self.machine = machine
        self.kind = kind
        self.osVersion = osVersion
        self.udid = udid
        self.port = port
        self.engine = engine
        self.avd = avd
        self.serial = serial
        self.model = model
    }

    /// 実機か(kind 省略時は virtual)。デバイス種別の分岐はすべてこれを見ること
    public var isPhysical: Bool { kind == .physical }

    /// 「どの台か」が名前以外に1つも書かれていない登録。iOS は name だけで探しに行くが、
    /// 雛形の論理名(simulator1 等)は実在しないので起動時に落ちる。
    /// 見るキーは ProfileWriter.deviceBodyKeys と同集合(ProfileWriterTests が照合)
    public var lacksConcreteTarget: Bool {
        osVersion == nil && udid == nil && avd == nil && serial == nil
    }

    static let knownKeys: Set<String> = [
        "name", "machine", "kind", "osVersion", "udid", "port", "engine", "avd",
        "serial", "model",
    ]

    private enum CodingKeys: String, CodingKey {
        case name, machine, kind, osVersion, udid, port, engine, avd, serial, model
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        name = try container.decode(String.self, forKey: .name)
        machine = try container.decodeIfPresent(String.self, forKey: .machine)
        kind = try container.decodeIfPresent(DeviceKind.self, forKey: .kind)
        osVersion = try container.decodeIfPresent(String.self, forKey: .osVersion)
        udid = try container.decodeIfPresent(String.self, forKey: .udid)
        port = try container.decodeIfPresent(UInt16.self, forKey: .port)
        engine = try container.decodeIfPresent(String.self, forKey: .engine)
        avd = try container.decodeIfPresent(String.self, forKey: .avd)
        serial = try container.decodeIfPresent(String.self, forKey: .serial)
        model = try container.decodeIfPresent(String.self, forKey: .model)
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(name, forKey: .name)
        try container.encodeIfPresent(machine, forKey: .machine)
        try container.encodeIfPresent(kind, forKey: .kind)
        try container.encodeIfPresent(osVersion, forKey: .osVersion)
        try container.encodeIfPresent(udid, forKey: .udid)
        try container.encodeIfPresent(port, forKey: .port)
        try container.encodeIfPresent(engine, forKey: .engine)
        try container.encodeIfPresent(avd, forKey: .avd)
        try container.encodeIfPresent(serial, forKey: .serial)
        try container.encodeIfPresent(model, forKey: .model)
    }
}

public struct DeviceRosterList: Codable, Sendable, Equatable {
    public var devices: [DeviceSpec]?

    public init(devices: [DeviceSpec]? = nil) { self.devices = devices }
}

/// プラットフォーム別のデバイス一覧(**メモリ上の台帳。ファイルではない**)。
/// 実行プロファイルの devices から作る(`DeviceRoster(entries:)`)。spec.machine は実効値
/// (手元 = nil)を焼き込んだものを渡すこと(DeviceMachineGrouping.entries が前提にする)
public struct DeviceRoster: Codable, Sendable, Equatable {
    public var ios: DeviceRosterList?
    public var android: DeviceRosterList?

    public init(ios: DeviceRosterList? = nil, android: DeviceRosterList? = nil) {
        self.ios = ios
        self.android = android
    }

    /// 並びは入力順を platform ごとに保つ(ios → android)
    public init(entries: [DeviceMachineGrouping.CatalogEntry]) {
        let ios = entries.filter { $0.platform == "ios" }.map(\.spec)
        let android = entries.filter { $0.platform == "android" }.map(\.spec)
        self.init(ios: ios.isEmpty ? nil : DeviceRosterList(devices: ios),
                  android: android.isEmpty ? nil : DeviceRosterList(devices: android))
    }

    public var isEmpty: Bool {
        (ios?.devices ?? []).isEmpty && (android?.devices ?? []).isEmpty
    }
}

/// `--runner`(CLI 明示)からディスパッチ先を決める純粋関数。プロファイル側には機械の既定を
/// 持たない(台ごとの machine はマシン別サブ実行 = DeviceMachineGrouping で配る)。
/// 呼び出し側(Sources/fleetest/RemoteCommands.swift)はここが返す名前を登録簿引きするだけ。
public enum MachineDispatch {
    public struct Decision: Equatable {
        /// 実際のディスパッチ先(nil = ローカル実行)。**マシン名(エイリアス)か、`--runner` で
        /// 直接書かれたホスト名 / IP のどちらか** —— 呼び出し側が登録簿で解決する
        public let target: String?

        public init(target: String? = nil) {
            self.target = target
        }
    }

    /// nil・空文字・trim 後 "local" は「ローカル」(nil に正規化)。devices[].machine と
    /// --runner にもこの規則を適用する
    public static func normalize(_ raw: String?) -> String? {
        guard let trimmed = raw?.trimmingCharacters(in: .whitespacesAndNewlines),
              !trimmed.isEmpty, trimmed != "local" else { return nil }
        return trimmed
    }

    /// **明示 `--runner local` は「ここで走らせる」の指定**(normalize が nil に畳むのと同じ結果)
    public static func resolve(explicitTarget: String?) -> Decision {
        if isExplicitLocal(explicitTarget) { return Decision(target: nil) }
        return Decision(target: normalize(explicitTarget))
    }

    /// 生の(trim 前の)値が文字どおり "local" か。normalize 後の nil(= 未指定)とは区別する。
    /// `--runner local` と devices[].machine の "local" の両方が「ここで走らせる」の明示指定で、
    /// 判定を写すと片方だけズレるのでここが唯一の定義元
    public static func isExplicitLocal(_ raw: String?) -> Bool {
        guard let raw else { return false }
        return raw.trimmingCharacters(in: .whitespacesAndNewlines) == "local"
    }
}

/// 実行プロファイルの devices[] 1要素。JSON は**平ら**
/// (`{"platform", "machine", "name", "enabled"?, <DeviceSpec の実体キー>}`)。
/// 拡張の書き手は vscode-fleetest/src/monitorProfileForms.ts(キー集合を揃える)
public struct RunDeviceEntry: Codable, Sendable, Equatable {
    /// "ios" / "android"
    public var platform: String
    /// false = 一覧(拡張のチェックボックス)には残すが実行対象にしない。省略・true = 対象。
    /// **false の台も台帳には載る**(プロファイルを選んでいないときの監視・起動の対象)
    public var enabled: Bool?
    public var spec: DeviceSpec

    public init(platform: String, spec: DeviceSpec, enabled: Bool? = nil) {
        self.platform = platform
        self.spec = spec
        self.enabled = enabled
    }

    public var isEnabled: Bool { enabled != false }

    public static let supportedPlatforms: Set<String> = ["ios", "android"]

    static let knownKeys: Set<String> = DeviceSpec.knownKeys.union(["platform", "enabled"])

    private enum CodingKeys: String, CodingKey { case platform, enabled }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        platform = try container.decode(String.self, forKey: .platform)
        guard Self.supportedPlatforms.contains(platform) else {
            throw DecodingError.dataCorruptedError(
                forKey: .platform, in: container,
                debugDescription: "platform must be \"ios\" or \"android\" (got \"\(platform)\")")
        }
        enabled = try container.decodeIfPresent(Bool.self, forKey: .enabled)
        spec = try DeviceSpec(from: decoder)
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(platform, forKey: .platform)
        try container.encodeIfPresent(enabled, forKey: .enabled)
        try spec.encode(to: encoder)
    }
}

/// FM 機能の実行時トグル(実行プロファイル由来の実効値)。プロファイル経路の `enabled` は
/// `fmTextOcclusionCheck || screenLooksLike` から導く(`DeviceIndependentRunSettings.resolve`)
public struct FMConfig: Sendable, Equatable {
    /// FM を使用するか(false = 実行バイナリへ --no-fm。MCP・dry-run は明示的に false を渡す)
    public var enabled: Bool
    /// テキストの視覚検証(occlusion guard)= 誤った緑(木では一致したが実際には見えていない)の検査。
    /// **実行プロファイルの既定は true**(ユーザー決定)
    public var fmTextOcclusionCheck: Bool
    public var screenLooksLike: Bool

    /// **この既定値は実行プロファイルの既定とは別物**。プロファイル由来の値は
    /// `ResolvedProfile.fm`(RunProfileDocument の `fmTextOcclusionCheck ?? true` 等)が組み立てる。
    /// ここの既定は「プロファイルを通らない呼び出し」(MCP のシナリオ実行・dry-run 等)向けで、
    /// **FM を積極的に使わない側**に倒してある
    public init(enabled: Bool = true,
                fmTextOcclusionCheck: Bool = false, screenLooksLike: Bool = true) {
        self.enabled = enabled
        self.fmTextOcclusionCheck = fmTextOcclusionCheck
        self.screenLooksLike = screenLooksLike
    }
}

/// リモート実行の制御(docs/remote-runner.md §17)。ワークスペース(アプリのパッケージと
/// 資材を揃える共有ディレクトリ。中身の規約 apps/scripts/data は WorkspaceScaffold)の宣言。
/// run 前後のスクリプトはここでは宣言しない —— ワークスペースの `scripts/setup.sh` /
/// `scripts/teardown.sh` があれば実行される(`RunHookPlan`)。
/// 同期相手: vscode-fleetest/schemas/run-profile.schema.json と拡張のプロファイルフォーム
public struct RemoteControlSection: Codable, Sendable, Equatable {
    /// ワークスペースのルート。絶対パス、または**リポジトリルート基準**の相対パス。
    /// appPath の解決基準には使わない(常にリポジトリルート基準のまま)——
    /// 実行時に appPath の原本をここ配下の `apps/<ファイル名>` へコピー(ステージング)し、
    /// インストールにはそちらを使う(`WorkspaceAppStaging`。docs/remote-runner.md §17)。
    /// **省略時の既定は `<project.rootURL>/workspace`**(ワークスペースは常に有効
    /// —— ここを省略しても appPath はリポジトリルート基準のままではなく、既定ワークスペースの
    /// `apps/` へ切り替わる)。優先順位・既定値の算出は `ProfileResolver.resolveWorkspaceRoot`。
    /// `--workspace` で1回限り上書き可
    public var workspace: String?

    public init(workspace: String? = nil) {
        self.workspace = workspace
    }

    static let knownKeys: Set<String> = ["workspace"]
}

/// 実行プロファイル(profiles/runs/<name>.json)
public struct RunProfileDocument: Codable, Sendable, Equatable {
    /// apps/<app>.json への参照
    public var app: String?
    /// デバイスの実体(iOS/Android 混在可 = 両OS同時実行)。enabled=false の台は走らせない
    public var devices: [RunDeviceEntry]?
    /// ロケータ自己修復(指紋照合)を許可するか(既定 true)。FM は使わない
    public var heal: Bool?
    /// FM を使ったテキストの視覚検証(occlusion guard の FM の段。**既定 true**。ユーザー決定)
    /// = 誤った緑(木では一致したが実際には見えていない)の検査。OCR の段(`ocrTextOcclusionCheck`)と独立で、
    /// guard はどちらかが true なら走る(FTRuntime が合成)
    public var fmTextOcclusionCheck: Bool?
    /// screenLooksLike(screenMatches)を有効にするか(既定 true。無効時は該当ステップを skip)
    public var screenLooksLike: Bool?
    /// OCR を使ったテキストの視覚検証(occlusion guard の OCR の段。既定 true)。`fmTextOcclusionCheck` と独立で、
    /// 両方 true なら OCR が丸ごと読めた回は FM を省き、それ以外は FM と突き合わせる。こちらだけ true なら OCR だけで判定
    public var ocrTextOcclusionCheck: Bool?
    /// チェック状態(checkIsON / checkIsOFF)の判定で CheckStateClassifier を優先するか(**既定 true**)。
    /// 分類器が使えるのは `vision/classifiers/CheckStateClassifier/<ラベル>/` に画像があるときだけ。
    /// false なら a11y が状態を報告しない要素にだけ使う(VisionClassifier.swift)
    public var preferCheckStateClassifier: Bool?
    /// レポート出力先(プロジェクトルート相対 or 絶対。既定 "reports")
    public var reportDir: String?
    /// DSL コマンドの既定タイムアウト秒(小数可。省略時は DSL 側の既定値)
    public var defaultTimeout: Double?
    /// シナリオ単位の壁時計タイムアウト秒(ホスト側 watchdog。子には渡さない。省略時 90)。
    /// defaultTimeout(子内部の検証待ち)とは別物
    public var scenarioTimeout: Int?
    /// iOS の高速な in-app エンジン(ハイブリッド)を使うか(既定 true=ON)。
    /// true → iOS デバイスの実効エンジンを "hybrid"(in-app 主+XCUITest フォールバック)、
    /// false → "xcuitest" にする。devices[] の台に engine を明示している場合は
    /// そちらが優先(resolve 参照)。Android には影響しない。
    public var iosInappEngine: Bool?
    /// 実行開始時に Android AVD の肥大化(wipe 対象ファイル合計サイズ)を検査し超過分を
    /// Wipe Data するか(既定 true=ON)。同期相手: vscode-fleetest/schemas/run-profile.schema.json
    /// と src/monitorModel.ts の RunProfileFormFields
    public var wipeDataOnBloat: Bool?
    /// wipeDataOnBloat のしきい値(GB、1GB=1_073_741_824 バイト。既定 8。0 以下は検証エラー。
    /// Play イメージは wipe 直後の再構築だけで userdata が 2〜4GB になるため(実測)、
    /// それ未満のしきい値は毎実行 wipe が発動するスラッシングになる — 下げるときは要注意)
    /// **テスト開始時に WebView を揃えるか**(既定 ON)。版が混在すると同じシナリオが
    /// 端末によって落ちる(124 は placeholder / 150 は #id と表現が入れ替わる)
    public var updateWebView: Bool?
    public var wipeDataThresholdGB: Double?
    /// 実行開始時に、画面凍結で CPU 描画(swiftshader)へフォールバック済みの Android エミュレータを
    /// GPU(-gpu host)で起動し直すか(既定 false=OFF)。GPU モードは emulator プロセスの起動引数で
    /// 決まるためプロセス再起動が必須で、該当機1台につき run 開始が約1分延びる。戻した先で再び凍結
    /// すればモニターの watchdog がまた CPU に落とす(design.md §12.4 のトレードオフ)。
    /// 同期相手: vscode-fleetest/schemas/run-profile.schema.json と
    /// src/monitorModel.ts の RunProfileFormFields
    public var recoverCpuFallbackToGpu: Bool?
    /// Android エミュレータのブート完了時(Wipe Data 後の再起動を含む)にブリッジ /locale で
    /// 適用するロケール(既定 "ja_JP"。Play イメージでは -change-locale 等が無効なため。
    /// design.md §11.2)。iOS には影響しない。同期相手: vscode-fleetest/schemas/run-profile.schema.json
    /// と src/monitorModel.ts の RunProfileFormFields
    public var locale: String?
    /// iOS xcuitest ブリッジの高速入力(quiescence 待ちスキップ)。true で FT_FAST_INPUT=1 を
    /// 実行環境に注入する(伝搬経路は BridgeClient.fastInput 参照)。動きの激しい画面では
    /// 整定前タップのフレークリスクを伴う(既定 false)
    public var iosFastInput: Bool?
    /// **interop WebView 画面の委譲イベント直前にランナーを1回温めるか**(既定 true)。
    /// attach したままの XCUITest セッションは放置後の座標イベントを 200 のまま届け損なう
    /// (実測 ~13% → 暖機で 0/50。A/B は docs/verification.md §interop WebView)。false で
    /// FT_PRE_ACTION_WARMUP=0 を注入し暖機を止める(WebViewDelegatingDriver が受ける)。
    /// 効くのは hybrid エンジンの domInterop 経路だけ(xcuitest エンジンには元から不要)
    public var iosPreActionWarmup: Bool?
    /// **容器の推測に依存する補正**を行うか(既定 true)。false にすると見切れ判定・掴み直し・
    /// 救済ドラッグ・見えている部分を撃つ座標補正・壊れた座標の候補除外が止まり、
    /// 推測を持たなかった頃の挙動へ戻る。**FM とは無関係**(幾何ヒューリスティック)。
    /// シナリオ側は `tap(..., containerInference:)` で1コマンド単位に上書きできる
    public var containerInference: Bool?
    /// テスト対象アプリのアニメーションを残すか(既定 false = 実行開始時に無効化する)。
    /// true で FT_ANIMATIONS=1 を実行環境に注入する(判定元は AnimationPolicy)。ON にすると
    /// 整定待ちが伸び、Android では静穏判定後もスクリーンショットが遷移途中の絵を掴みうる。
    /// 端末側の設定は run 開始時に毎回この値へ同期される(ブリッジ再利用でも効く)。
    /// 同期相手: vscode-fleetest/schemas/run-profile.schema.json と
    /// src/monitorProfileForms.ts の RunProfileFormFields
    public var enableAnimations: Bool?
    /// run 開始時に各デバイスへ home() を1回撃つか(**既定 true**)。
    /// 一斉に launch した直後の端末は「描画要求が無いだけ」で画面が黒いまま止まることがあり、
    /// そのままだと凍結と見分けが付かない(実測: 黒かった5台のうち4台は入力で戻った)。
    /// 予防として1回だけ入力を入れる。**デバイスあたり1回**なので実行時間への影響はほぼゼロ。
    /// 同期相手: vscode-fleetest/schemas/run-profile.schema.json と RunProfileFormFields
    public var homeOnStart: Bool?
    /// Android の `adb install` で Play Protect の照会を通さないか(**既定 true**)。true で
    /// install の間だけ `verifier_verify_adb_installs` を 0 にして元へ戻す(AdbInstallVerifier。
    /// テスト対象アプリを Google へ送らない = ユーザー決定)。**false はキルスイッチ**:
    /// ツールは端末の設定に触らず、release 署名の APK は端末側のダイアログで install が止まったまま
    /// になる(ツールはそのダイアログに答えない)。FT_PLAY_PROTECT_BYPASS で実行環境へ注入する。
    /// 同期相手: vscode-fleetest/schemas/run-profile.schema.json と RunProfileFormFields
    public var playProtectBypass: Bool?
    /// 並列実行の各ワーカー(デバイス)ごとに run 全体を録画し、テスト関数(シナリオ)ごとに
    /// 1本の mp4 へ切り出すか(既定 false)。実体は RunOrchestrator への VideoRecordingConfig 注入
    /// (VideoRecordingCoordinator.swift)。録画失敗は run を失敗させない(警告ログのみ)
    public var record: Bool?
    /// true なら成功したシナリオのクリップは保存せず、失敗(frozen 含む)シナリオのみ切り出す
    /// (既定 false = 全シナリオ保存)。record:false のときは無関係
    public var recordFailuresOnly: Bool?
    /// クリップ再エンコードの目標 bitrate(kbps。既定 1500)。AVVideoAverageBitRateKey と
    /// Android screenrecord --bit-rate の両方に適用(*1000 して bps に変換)
    public var recordBitrateKbps: Int?
    /// true なら半分解像度化をスキップしフル解像度のまま出力する(既定 false)。
    /// Android は screenrecord 自体の --size 指定も省略する(録画元から既にフル解像度になる)
    public var recordFullResolution: Bool?
    /// ワークスペース(ファイル同期)宣言。省略可(既定 = リポジトリルート基準)
    public var remoteControl: RemoteControlSection?

    public init(app: String? = nil, devices: [RunDeviceEntry]? = nil,
                heal: Bool? = nil, fmTextOcclusionCheck: Bool? = nil, screenLooksLike: Bool? = nil,
                ocrTextOcclusionCheck: Bool? = nil,
                preferCheckStateClassifier: Bool? = nil,
                reportDir: String? = nil, defaultTimeout: Double? = nil, scenarioTimeout: Int? = nil,
                iosInappEngine: Bool? = nil,
                wipeDataOnBloat: Bool? = nil, updateWebView: Bool? = nil,
                wipeDataThresholdGB: Double? = nil,
                recoverCpuFallbackToGpu: Bool? = nil,
                locale: String? = nil, iosFastInput: Bool? = nil, iosPreActionWarmup: Bool? = nil,
                containerInference: Bool? = nil,
                enableAnimations: Bool? = nil, homeOnStart: Bool? = nil,
                playProtectBypass: Bool? = nil, record: Bool? = nil,
                recordFailuresOnly: Bool? = nil, recordBitrateKbps: Int? = nil,
                recordFullResolution: Bool? = nil, remoteControl: RemoteControlSection? = nil) {
        self.app = app
        self.devices = devices
        self.heal = heal
        self.fmTextOcclusionCheck = fmTextOcclusionCheck
        self.screenLooksLike = screenLooksLike
        self.ocrTextOcclusionCheck = ocrTextOcclusionCheck
        self.preferCheckStateClassifier = preferCheckStateClassifier
        self.reportDir = reportDir
        self.defaultTimeout = defaultTimeout
        self.scenarioTimeout = scenarioTimeout
        self.iosInappEngine = iosInappEngine
        self.wipeDataOnBloat = wipeDataOnBloat
        self.updateWebView = updateWebView
        self.wipeDataThresholdGB = wipeDataThresholdGB
        self.recoverCpuFallbackToGpu = recoverCpuFallbackToGpu
        self.locale = locale
        self.iosFastInput = iosFastInput
        self.iosPreActionWarmup = iosPreActionWarmup
        self.containerInference = containerInference
        self.enableAnimations = enableAnimations
        self.homeOnStart = homeOnStart
        self.playProtectBypass = playProtectBypass
        self.record = record
        self.recordFailuresOnly = recordFailuresOnly
        self.recordBitrateKbps = recordBitrateKbps
        self.recordFullResolution = recordFullResolution
        self.remoteControl = remoteControl
    }


    static let knownKeys: Set<String> = [
        "app", "devices", "heal", "fmTextOcclusionCheck", "screenLooksLike", "ocrTextOcclusionCheck",
        "preferCheckStateClassifier",
        "reportDir", "defaultTimeout", "scenarioTimeout",
        "iosInappEngine", "wipeDataOnBloat", "updateWebView", "wipeDataThresholdGB",
        "recoverCpuFallbackToGpu", "locale",
        "iosFastInput", "iosPreActionWarmup", "enableAnimations", "homeOnStart",
        "playProtectBypass",
        "containerInference",
        "record", "recordFailuresOnly", "recordBitrateKbps", "recordFullResolution", "remoteControl",
    ]

    /// `--set` が受ける値の宣言型(配列・オブジェクトは対象外 = `arrayOrObjectKeys` で別に断る)
    public enum ValueKind: Sendable, Equatable {
        case bool, int, double, string

        /// パース失敗時に名指しする期待値の文言(string は `String(rawValue)` が常に成功するため未使用)
        var expectationDescription: String {
            switch self {
            case .bool: return "\"true\" or \"false\""
            case .int: return "an integer"
            case .double: return "a number"
            case .string: return "a string"
            }
        }
    }

    /// キー→宣言型の**唯一の定義元**。`overridableKeys`(Set)はここから導出し、
    /// `RunProfileSetOverride.parse` の型別パース分岐もここを見る。新しいスカラー欄を足したら
    /// ここと `applyingOverrides` の switch 分岐の両方に追記する(`RunProfileSetOverrideKeysTests` が
    /// Mirror で等号を固定する)
    fileprivate static let overridableKeyKinds: [String: ValueKind] = [
        "heal": .bool, "fmTextOcclusionCheck": .bool,
        "screenLooksLike": .bool, "ocrTextOcclusionCheck": .bool, "preferCheckStateClassifier": .bool,
        "iosInappEngine": .bool, "iosFastInput": .bool, "iosPreActionWarmup": .bool,
        "containerInference": .bool, "enableAnimations": .bool, "homeOnStart": .bool,
        "playProtectBypass": .bool, "updateWebView": .bool, "wipeDataOnBloat": .bool,
        "recoverCpuFallbackToGpu": .bool, "record": .bool, "recordFailuresOnly": .bool,
        "recordFullResolution": .bool,
        "reportDir": .string, "defaultTimeout": .double, "scenarioTimeout": .int,
        "recordBitrateKbps": .int, "app": .string, "locale": .string,
        "wipeDataThresholdGB": .double,
    ]

    /// 配列・オブジェクトの欄。`key=value` で表せないので専用のエラーで断る(未知キー扱いにしない)
    fileprivate static let arrayOrObjectKeys: Set<String> = ["devices", "remoteControl"]

    /// `fleetest run --set <key>=<value>` / `fleetest api run --set` が受け付けるキー全部
    /// (Bool 17 + スカラー8。キー名はプロファイル JSON のキーそのもの ——
    /// kebab 変換をしない)。**`RunProfileDocument` の Bool/String/Int/Double 欄の全部から
    /// `devices`・`remoteControl`(配列・オブジェクトで `key=value` を持たない)を除いたもの**。
    /// この等号は `RunProfileSetOverrideKeysTests` が Mirror で固定する
    public static let overridableKeys: Set<String> = Set(overridableKeyKinds.keys)

    /// `--set` の上書きを当てる唯一の箇所。**呼び出しは「読み込んだ直後・解決(ResolvedProfile)
    /// より前」であること**(`ProfileResolver.resolve` が守る) —— そうすれば全キーが
    /// 同じ経路で効き、消費側(ResolvedProfile の各フィールド)を個別に配線し直さずに済む。
    /// **未知キー・型の合わない値はここに来ない前提**(CLI 側が `RunProfileSetOverride.parse` で
    /// キーごとの宣言型に対して検証済み。防御的に無視するだけで、ここでは弾かない)
    public func applyingOverrides(_ overrides: [String: RunProfileSetValue]) -> RunProfileDocument {
        guard !overrides.isEmpty else { return self }
        var copy = self
        for (key, value) in overrides {
            switch (key, value) {
            case ("heal", .bool(let v)): copy.heal = v
            case ("fmTextOcclusionCheck", .bool(let v)): copy.fmTextOcclusionCheck = v
            case ("screenLooksLike", .bool(let v)): copy.screenLooksLike = v
            case ("ocrTextOcclusionCheck", .bool(let v)): copy.ocrTextOcclusionCheck = v
            case ("preferCheckStateClassifier", .bool(let v)): copy.preferCheckStateClassifier = v
            case ("iosInappEngine", .bool(let v)): copy.iosInappEngine = v
            case ("iosFastInput", .bool(let v)): copy.iosFastInput = v
            case ("iosPreActionWarmup", .bool(let v)): copy.iosPreActionWarmup = v
            case ("containerInference", .bool(let v)): copy.containerInference = v
            case ("enableAnimations", .bool(let v)): copy.enableAnimations = v
            case ("homeOnStart", .bool(let v)): copy.homeOnStart = v
            case ("playProtectBypass", .bool(let v)): copy.playProtectBypass = v
            case ("updateWebView", .bool(let v)): copy.updateWebView = v
            case ("wipeDataOnBloat", .bool(let v)): copy.wipeDataOnBloat = v
            case ("recoverCpuFallbackToGpu", .bool(let v)): copy.recoverCpuFallbackToGpu = v
            case ("record", .bool(let v)): copy.record = v
            case ("recordFailuresOnly", .bool(let v)): copy.recordFailuresOnly = v
            case ("recordFullResolution", .bool(let v)): copy.recordFullResolution = v
            case ("reportDir", .string(let v)): copy.reportDir = v
            case ("defaultTimeout", .double(let v)): copy.defaultTimeout = v
            case ("scenarioTimeout", .int(let v)): copy.scenarioTimeout = v
            case ("recordBitrateKbps", .int(let v)): copy.recordBitrateKbps = v
            case ("app", .string(let v)): copy.app = v
            case ("locale", .string(let v)): copy.locale = v
            case ("wipeDataThresholdGB", .double(let v)): copy.wipeDataThresholdGB = v
            default: break
            }
        }
        return copy
    }
}

/// `--set <key>=<value>` のパース結果。`RunProfileDocument.ValueKind` のケースと1:1
public enum RunProfileSetValue: Sendable, Equatable {
    case bool(Bool)
    case int(Int)
    case double(Double)
    case string(String)

    /// `--set <key>=<token>` の再構成に使う文字列表現(parse() の逆変換)。リモート
    /// ディスパッチ/フリート/マシン別サブ実行の子プロセスへ引数として渡し直すときに使う
    /// (Sources/FTRemote/RemoteDispatch.swift・Sources/fleetest/FleetRunner.swift 等)
    public var token: String {
        switch self {
        case .bool(let value): return value ? "true" : "false"
        case .int(let value): return String(value)
        case .double(let value): return String(value)
        case .string(let value): return value
        }
    }
}

/// テストの `["heal": true]` 表記(暗黙のリテラル推論)を保つための組み込み。true/false の
/// トークンは他のケースと衝突しないので曖昧さは生まれない(Int/Double/String はテストでも
/// 明示的に `.int(_)`/`.double(_)`/`.string(_)` で書く)
extension RunProfileSetValue: ExpressibleByBooleanLiteral {
    public init(booleanLiteral value: Bool) { self = .bool(value) }
}

/// `--set <key>=<value>` の1トークンのデコード失敗。CLI 層(`fleetest run`/`fleetest api run`。
/// 両方が同じ口を呼ぶ ——共通フラグなので `RunCommandFlagParityTests` の対象外)がそのまま
/// `ValidationError` へ包んで投げる
public enum RunProfileSetOverrideError: Error, LocalizedError {
    case invalidFormat(String)
    case invalidValue(key: String, value: String, expected: RunProfileDocument.ValueKind)
    case unknownKey(String, available: [String])
    /// `devices`/`remoteControl`(配列・オブジェクト)は `key=value` で表せない
    case arrayOrObjectKey(String)
    /// 型は合っているが範囲外(`scenarioTimeout` の負値・0 / `defaultTimeout` の負値・NaN)。
    /// `invalidValue` と分けるのは、型不一致(整数の場所に文字列)と範囲外(整数だが 0 以下)を
    /// 同じ文言で混ぜると「何が悪いか」が伝わらないため
    case outOfRange(key: String, value: String, reason: String)

    public var errorDescription: String? {
        switch self {
        case .invalidFormat(let token):
            return "--set \(token) is not <key>=<value>"
        case .invalidValue(let key, let value, let expected):
            return "--set \(key)=\(value): the value must be \(expected.expectationDescription)"
        case .unknownKey(let key, let available):
            return "--set \(key): unknown key (available: \(available.joined(separator: ", ")))"
        case .arrayOrObjectKey(let key):
            return "--set \(key): \"\(key)\" is a list/object field in the run profile and cannot be"
                + " expressed as <key>=<value> on the command line — edit the run profile JSON instead"
        case .outOfRange(let key, let value, let reason):
            return "--set \(key)=\(value): \(reason)"
        }
    }
}

/// `--set` トークン列の検証つきデコード(`fleetest run`/`fleetest api run` の共有実装)
public enum RunProfileSetOverride {
    /// 同じキーの重複指定は後勝ち(左→右の順で辞書に上書きするだけ)
    public static func parse(_ tokens: [String]) throws -> [String: RunProfileSetValue] {
        var result: [String: RunProfileSetValue] = [:]
        for token in tokens {
            guard let separator = token.firstIndex(of: "=") else {
                throw RunProfileSetOverrideError.invalidFormat(token)
            }
            let key = String(token[token.startIndex..<separator])
            let rawValue = String(token[token.index(after: separator)...])
            guard let kind = RunProfileDocument.overridableKeyKinds[key] else {
                if RunProfileDocument.arrayOrObjectKeys.contains(key) {
                    throw RunProfileSetOverrideError.arrayOrObjectKey(key)
                }
                throw RunProfileSetOverrideError.unknownKey(
                    key, available: RunProfileDocument.overridableKeys.sorted())
            }
            switch kind {
            case .bool:
                guard let value = Bool(rawValue) else {
                    throw RunProfileSetOverrideError.invalidValue(key: key, value: rawValue, expected: .bool)
                }
                result[key] = .bool(value)
            case .int:
                guard let value = Int(rawValue) else {
                    throw RunProfileSetOverrideError.invalidValue(key: key, value: rawValue, expected: .int)
                }
                // scenarioTimeout はホストの watchdog(ScenarioHost.watchdogDuration)の秒数。
                // 0 以下は「即タイムアウト」で実質シナリオを一切走らせない意味の無い値
                if key == "scenarioTimeout", value < 1 {
                    throw RunProfileSetOverrideError.outOfRange(
                        key: key, value: rawValue, reason: "must be a positive number of seconds")
                }
                result[key] = .int(value)
            case .double:
                guard let value = Double(rawValue) else {
                    throw RunProfileSetOverrideError.invalidValue(key: key, value: rawValue, expected: .double)
                }
                // defaultTimeout は DSL コマンドの検証待ち秒。**0 は正当**(初回スナップショットだけを見る。
                // ステップの `timeout: 0` と同じ意味・docs/commands.md)。負値・NaN(`Double("nan")` は
                // 成功する)・無限大は下流の待ち処理を壊すので断る
                if key == "defaultTimeout", !(value >= 0 && value.isFinite) {
                    throw RunProfileSetOverrideError.outOfRange(
                        key: key, value: rawValue, reason: "must be a non-negative, finite number of seconds (0 = the first snapshot only, no waiting)")
                }
                result[key] = .double(value)
            case .string:
                result[key] = .string(rawValue)
            }
        }
        return result
    }
}

extension RunProfileDocument {
    /// `overridableKeys` のうち**プロファイルの devices 一覧と供給工程(AVD の起床・入れ替え)を
    /// 必要とし、他のプロファイル欄にも依存する**もの。`--set` にこれが混ざっていて `--profile` も
    /// 無いときは、黙って無視せず名指しでエラーにする(呼び出しは RunScenarios.validate /
    /// ApiRunCommand.run)。残りのキーは `DeviceIndependentRunSettings` を経由して `--profile` 無しでも
    /// 同じ経路で効く(`record`/`recordFailuresOnly`/`recordFullResolution`/`homeOnStart`/`reportDir`/
    /// `defaultTimeout`/`scenarioTimeout`/`recordBitrateKbps` も含む —— これらは devices への
    /// 前処理ではなく単に workers/レポート出力先に対して働くだけなので profile-less でも配線できる)。
    /// **`app` は「他のプロファイルを名指して読み込む」キーそのもの**(プロファイル無しでは
    /// 意味を持たない)。**`locale`/`wipeDataThresholdGB`** は Android の供給工程(wipe data)でしか
    /// 使わない(`wipeDataOnBloat` と同じ理由)
    public static let profileOnlyKeys: Set<String> = [
        "iosInappEngine", "updateWebView", "wipeDataOnBloat", "recoverCpuFallbackToGpu",
        "app", "locale", "wipeDataThresholdGB",
    ]

    /// `record:true` は devices 一覧に依存しない(`profileOnlyKeys` に無い)が、録画の
    /// セッション管理は RunOrchestrator(VideoRecordingCoordinator)が持つため、これを経由しない
    /// 実行経路では録画できない。呼び出し側(Fleetest.swift の runSequential/runParallel 分岐・
    /// ApiRunCommand.swift の runDirect)が「この run は RunOrchestrator を経由するか」を渡す。
    /// true(=エラーにすべき)を黙って無視すると「指定したのに何も録れない」緑の run ができる
    public static func recordNeedsRejecting(record: Bool, hasRecordingSession: Bool) -> Bool {
        record && !hasRecordingSession
    }

    /// 0 以下の指定は無意味なので既定へ落とす。`ProfileResolver.resolve`(--profile あり)と
    /// profile-less の録画構成(Fleetest.swift が `DeviceIndependentRunSettings.recordBitrateKbps`
    /// から組み立てる)が同じ既定(`VideoRecordingConfig.defaultBitrateKbps`)を共有する唯一の定義元
    public static func effectiveRecordBitrateKbps(_ raw: Int?) -> Int {
        raw.map { $0 > 0 ? $0 : VideoRecordingConfig.defaultBitrateKbps }
            ?? VideoRecordingConfig.defaultBitrateKbps
    }

    /// 専用フラグ(`--report-dir` 等)と同じ意味の `--set <key>=...` が両方指定されたときの
    /// 拒否メッセージ(`nil` = 衝突なし)。**黙ってどちらかを勝たせない** ——
    /// `fleetest run`(reportDir)/`fleetest api run`(reportDir/defaultTimeout/scenarioTimeout)が
    /// それぞれ自分の持つ専用フラグの分だけ呼ぶ。**`--app-id`/`--runner` はここでは扱わない** ——
    /// CLI の `--app-id`/`--runner` とプロファイルキー `app` は別物(前者は
    /// `@TestClass(app:)` 省略時の既定アプリ/ディスパッチ先、後者はアプリ**プロファイル名**)
    public static func flagOverrideCollision(
        flag: String, key: String, flagIsSet: Bool, overrides: [String: RunProfileSetValue]
    ) -> String? {
        guard flagIsSet, overrides[key] != nil else { return nil }
        return "\(flag) and --set \(key)=... both set the same field; use only one"
    }
}

/// `RunProfileDocument` のうち**デバイス一覧を経由せず決まる**実効設定。`ProfileResolver.resolve`
/// (デバイスあり)と `--profile` 無しの直接実行(`RunScenarios`/`ApiRunCommand` の profile-less パス)の
/// **両方がこれを呼ぶ** —— FM の子トグルからの合成を二重に書かない。デバイス依存の欄
/// (`RunProfileDocument.profileOnlyKeys`)はここに無い
public struct DeviceIndependentRunSettings: Sendable, Equatable {
    public let fm: FMConfig
    /// ロケータ自己修復(指紋照合)。**`fm` の配下ではない**(FM を使わないので、FM を切っても止めない)
    public let heal: Bool
    public let ocrTextOcclusionCheck: Bool
    /// RunProfileDocument.preferCheckStateClassifier(**既定 true**)
    public let preferCheckStateClassifier: Bool
    public let iosFastInput: Bool
    public let iosPreActionWarmup: Bool
    public let containerInference: Bool
    public let enableAnimations: Bool
    public let playProtectBypass: Bool
    /// run 開始時に各デバイスへ home() を撃つか(RunProfileDocument.homeOnStart。**既定 true**)
    public let homeOnStart: Bool
    /// 各ワーカーを run 全体で録画し、シナリオごとに切り出すか(RunProfileDocument.record。既定 false)
    public let record: Bool
    /// 成功したシナリオのクリップを保存しないか(RunProfileDocument.recordFailuresOnly。既定 false)
    public let recordFailuresOnly: Bool
    /// 半分解像度化をスキップするか(RunProfileDocument.recordFullResolution。既定 false)
    public let recordFullResolution: Bool
    /// レポート出力先(RunProfileDocument.reportDir)。**未指定(nil)のときの既定は呼び出し側が持つ**
    /// (Bool 欄と違いここでは既定値へ倒さない ——「reports」相対 or 絶対のどちらもプロジェクト
    /// ルート基準で解決するのは呼び出し側の責務)
    public let reportDir: String?
    /// DSL コマンドの既定タイムアウト秒(RunProfileDocument.defaultTimeout)。未指定は呼び出し側の既定
    public let defaultTimeout: Double?
    /// シナリオ単位の壁時計タイムアウト秒(RunProfileDocument.scenarioTimeout)。未指定は呼び出し側の既定
    public let scenarioTimeout: Int?
    /// 録画クリップの再エンコード bitrate(kbps。RunProfileDocument.recordBitrateKbps)。
    /// 未指定は `VideoRecordingConfig.defaultBitrateKbps`
    public let recordBitrateKbps: Int?

    /// `--profile` を使わない実行(`--port`/`--serial` 直指定)の基底。**プロファイルの既定を
    /// そのまま使わない** —— 2つだけ意図的に違う(`fmTextOcclusionCheck` はプロファイルと同じ既定 true。
    /// ユーザー決定):
    ///   `heal` … profile-less は**修復しない**(`ScenarioExecutionSettings.init` の既定と同じ。
    ///     素の run で壊れたセレクタを黙って別要素へ解決させない)
    ///   `homeOnStart` … profile-less は**デバイスに触らない**。この設定は一斉起動直後の
    ///     黒画面を防ぐためのもので、既に建っているブリッジへ繋ぐだけの経路では、手で用意した
    ///     画面を Home で流してしまう
    /// **`--set` はこの基底の上に当てる**ので、`--set heal=true` はそのまま効く。
    /// 既定はリテラルで固定するテストを置くこと(`DeviceIndependentRunSettingsTests`)
    public static let profileLessBase = RunProfileDocument(
        heal: false, homeOnStart: false)

    public static func resolve(_ doc: RunProfileDocument) -> DeviceIndependentRunSettings {
        // FM を使うかは子トグルから導く(親スイッチは無い)。両方 false なら
        // 実行バイナリへ --no-fm が渡る(ScenarioHost の既存分岐。FMConfig の doc コメント参照)
        let fmTextOcclusionCheck = doc.fmTextOcclusionCheck ?? true
        let screenLooksLike = doc.screenLooksLike ?? true
        return DeviceIndependentRunSettings(
            fm: FMConfig(
                enabled: fmTextOcclusionCheck || screenLooksLike,
                fmTextOcclusionCheck: fmTextOcclusionCheck,
                screenLooksLike: screenLooksLike),
            heal: doc.heal ?? true,
            ocrTextOcclusionCheck: doc.ocrTextOcclusionCheck ?? true,
            preferCheckStateClassifier: doc.preferCheckStateClassifier ?? true,
            iosFastInput: doc.iosFastInput ?? false,
            iosPreActionWarmup: doc.iosPreActionWarmup ?? true,
            containerInference: doc.containerInference ?? true,
            enableAnimations: doc.enableAnimations ?? false,
            playProtectBypass: doc.playProtectBypass ?? true,
            homeOnStart: doc.homeOnStart ?? true,
            record: doc.record ?? false,
            recordFailuresOnly: doc.recordFailuresOnly ?? false,
            recordFullResolution: doc.recordFullResolution ?? false,
            reportDir: doc.reportDir,
            defaultTimeout: doc.defaultTimeout,
            scenarioTimeout: doc.scenarioTimeout,
            recordBitrateKbps: doc.recordBitrateKbps)
    }
}

// MARK: - 解決済みモデル

/// 実行プロファイルから解決されたデバイス(所属プラットフォーム確定)
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
/// `declaredAppPaths` の鍵。ワークスペースへ運ぶ対象は platform だけでは決まらない
/// (実機用ビルドは別ファイル・別のステージング先)
public struct DeclaredAppPath: Hashable, Sendable {
    public let platform: String
    public let physical: Bool
    public init(platform: String, physical: Bool) {
        self.platform = platform
        self.physical = physical
    }
}

/// `declaredAppPaths` の値。`source` はステージング(実コピー)の入力、`declared` は
/// `WorkspaceAppStaging.installPath` の名前空間の入力 —— 別々に持つのは、`source` が
/// repoRoot 込みの絶対パス(ホストごとに違う)なのに対し、`declared` はプロファイル JSON の
/// 生の文字列(ローカル・リモートの子で常に同じ)だから。installPath は必ず `declared` を使う
public struct DeclaredAppPathEntry: Sendable, Equatable {
    public let source: String
    public let declared: String
    public init(source: String, declared: String) {
        self.source = source
        self.declared = declared
    }
}

public struct ResolvedAppTarget: Sendable, Hashable {
    public let bundleID: String
    /// アプリの原本の絶対パス(常にリポジトリルート基準で解決済み。nil = appPath 未指定。
    /// ワークスペースの宣言有無・既定/明示のどれでも基準は変わらない)。`WorkspaceAppStaging`
    /// がここを読んでワークスペースへコピーする。「原本が見つからない」系のエラーはこちらを
    /// 名指しする(インストール先を出しても何をビルドすればよいか分からないため)
    public let sourcePath: String?
    /// インストールに実際に使う絶対パス(nil = インストールしない)。**ワークスペースは常に
    /// 有効**(既定 `<project.rootURL>/workspace`)なので sourcePath と同値になるのは
    /// appPath 自体が既にワークスペース配下を指している場合だけ。`WorkspaceAppStaging.installPath`
    /// が決める "<workspaceRoot>/apps/<原本のファイル名>"(ProfileResolver.resolve が唯一の生成元)。
    /// 呼び出し側(installApp・ProfileWorkerFactory 等)はこちらだけを見ればよい
    public let appPath: String?
    /// 実機向けパッケージの原本(nil = appPathPhysical 未指定 = 実機にも appPath を配る)
    public let sourcePathPhysical: String?
    /// 実機向けパッケージのインストールに使う絶対パス(ステージング先。nil = 未指定)
    public let appPathPhysical: String?
    /// 実行前に appPath を自動インストールするか(既定 false = 無効。
    /// common セクションで明示的に true にした場合のみ有効)
    public let autoInstall: Bool
    /// バックエンド死活確認 URL(AppProfileSection.healthCheckURL)
    public let healthCheckURL: String?

    /// **配るパッケージは端末の種別で決まる**(この規則の唯一の定義元)。実機に
    /// `appPathPhysical` が無ければ appPath に落ちる —— iOS ではまず入らない(シミュレータ用
    /// ビルドは署名が無い)が、Android は同じ APK が両方で動くので落とすのが正しい。
    /// 「実機なのに実機用が無い」を install の失敗より手前で言うのは ProfileValidation の役目
    public func packagePath(physical: Bool) -> String? {
        physical ? (appPathPhysical ?? appPath) : appPath
    }

    /// packagePath の原本側(ステージングの元。名前の対応は packagePath と同じ規則)
    public func packageSource(physical: Bool) -> String? {
        physical ? (sourcePathPhysical ?? sourcePath) : sourcePath
    }

    /// sourcePath 省略時は appPath と同値にする(ワークスペース非経由の既存呼び出しとの互換)
    public init(bundleID: String, sourcePath: String? = nil, appPath: String? = nil,
                sourcePathPhysical: String? = nil, appPathPhysical: String? = nil,
                autoInstall: Bool = false, healthCheckURL: String? = nil) {
        self.bundleID = bundleID
        self.sourcePath = sourcePath ?? appPath
        self.appPath = appPath
        self.sourcePathPhysical = sourcePathPhysical ?? appPathPhysical
        self.appPathPhysical = appPathPhysical
        self.autoInstall = autoInstall
        self.healthCheckURL = healthCheckURL
    }
}

/// 合成・検証済みの実行プロファイル。実行コードはこれだけを見る
public struct ResolvedProfile: Sendable {
    public let project: TestProject
    public let runName: String
    /// アプリの表示名(apps/<name>.json の appName。無ければファイル名)
    public let appName: String
    /// platform("ios"/"android")→ アプリ情報(デバイスがある platform のみ)
    public let apps: [String: ResolvedAppTarget]
    /// 実行に使うデバイス。**limitingDevices が本数に合わせて絞る**ので var
    public var devices: [ResolvedDevice]
    /// FM 機能の実効設定(RunProfileDocument の fmTextOcclusionCheck/screenLooksLike を合成)
    public let fm: FMConfig
    /// ロケータ自己修復(指紋照合)を許可するか。**`fm` の配下ではない**
    public let heal: Bool
    /// 絶対パス解決済み
    public let reportDir: URL
    public let defaultTimeout: Double?
    /// シナリオ単位の壁時計タイムアウト秒(ホスト側 watchdog。nil=未指定→run 側で既定 90 を適用)
    public let scenarioTimeout: Int?
    /// 実行開始時に Android AVD 肥大化を Wipe Data するか(既定 true)
    public let wipeDataOnBloat: Bool
    /// **テスト開始時に WebView を揃えるか**(既定 true)
    /// (`AndroidWebViewUpdate`。adb に更新コマンドは無いので、接続中で最も新しい端末から配る)
    public let updateWebView: Bool
    /// wipeDataOnBloat のしきい値(GB)
    public let wipeDataThresholdGB: Double
    /// 実行開始時に CPU 描画フォールバック機を GPU で起動し直すか
    /// (RunProfileDocument.recoverCpuFallbackToGpu。既定 false)
    public let recoverCpuFallbackToGpu: Bool
    /// Android エミュレータのブート時に -change-locale で適用するロケール(既定 "ja_JP")
    public let locale: String
    /// iOS xcuitest ブリッジの高速入力(RunProfileDocument.iosFastInput。既定 false)
    public let iosFastInput: Bool
    /// interop WebView のアクション前暖機(RunProfileDocument.iosPreActionWarmup。**既定 true**)
    public let iosPreActionWarmup: Bool
    /// 容器の推測に依存する補正(RunProfileDocument.containerInference。**既定 true**)
    public let containerInference: Bool
    /// OCR を使ったテキストの視覚検証の実効値(RunProfileDocument.ocrTextOcclusionCheck。既定 true)
    public let ocrTextOcclusionCheck: Bool
    /// RunProfileDocument.preferCheckStateClassifier の実効値(既定 true)
    public let preferCheckStateClassifier: Bool
    /// アプリのアニメーションを残すか(RunProfileDocument.enableAnimations。既定 false=無効化)
    public let enableAnimations: Bool
    /// run 開始時に各デバイスへ home() を撃つか(RunProfileDocument.homeOnStart。**既定 true**)
    public let homeOnStart: Bool
    /// Play Protect の照会をバイパスするか(RunProfileDocument.playProtectBypass。**既定 true**)
    public let playProtectBypass: Bool
    /// 各ワーカーを run 全体で録画し、シナリオごとに切り出すか(RunProfileDocument.record。既定 false)
    public let record: Bool
    /// 成功したシナリオのクリップを保存しないか(RunProfileDocument.recordFailuresOnly。既定 false)
    public let recordFailuresOnly: Bool
    /// クリップ再エンコードの目標 bitrate(kbps。RunProfileDocument.recordBitrateKbps。既定 1500)
    public let recordBitrateKbps: Int
    /// 半分解像度化をスキップするか(RunProfileDocument.recordFullResolution。既定 false)
    public let recordFullResolution: Bool
    /// **絶対パス解決済みのワークスペースルート**(remoteControl.workspace / `--workspace` 上書きの
    /// 実効値)。**常に非 nil**(既定 `<project.rootURL>/workspace` —— ワークスペースは
    /// 常に有効。`ProfileResolver.resolveWorkspaceRoot`)。appPath の原本の解決基準はこれの
    /// 有無に関わらず常にリポジトリルート ―― `apps[platform].appPath`(インストール先)だけが
    /// この配下の `apps/<ファイル名>` に切り替わる(ステージングは WorkspaceAppStaging)。
    /// リモートディスパッチはこれがプロジェクトルート配下かどうかで転送経路を分ける
    /// (`WorkspaceRemoteDispatch.placement`。配下ならプロジェクト転送がそのまま運ぶので専用
    /// ミラーは不要。Sources/fleetest/RemoteRunDispatcher.swift)。**`var` にする**(machine と
    /// 同じ理由 —— 既定値付きの `let` は memberwise init から除外され、この引数を知らない
    /// 既存テストの直接呼び出しが壊れる。型を Optional のまま残すのも同じ理由 ——
    /// 非 Optional にすると同じ既存テストが nil を渡せなくなる)
    public var workspaceRoot: URL? = nil
    /// run の前後で走らせる利用者のスクリプト(`<workspace>/scripts/setup.sh`・`teardown.sh`)。
    /// **workspaceRoot と同じく既定値付きの `var`**(memberwise init を直に呼ぶ既存テストのため)。
    /// 実行するかどうかは**ファイルがあるかどうか**だけで決まる(`RunHookPlan.action`)
    public var setupHook: RunHook? = nil
    public var teardownHook: RunHook? = nil
    /// 解決中に出た警告(スキップしたデバイス・未知キー等)。呼び出し側が表示する
    public let warnings: [String]

    public var iosDevices: [ResolvedDevice] { devices.filter { $0.platform == "ios" } }
    public var androidDevices: [ResolvedDevice] { devices.filter { $0.platform == "android" } }

    /// **回す本数を超える台数を用意しない**。1本のシナリオを回すのに 10 台ぶんのブリッジ供給と
    /// アプリ版チェックを払うのは丸損で、実測では iOS の固定費 14.8s のほとんどがこれだった
    /// (合計 21.8s のうちテスト実行は 7.0s)。
    ///
    /// **予備を1台残す**(`+ 1`): 用意した台が blank/frozen で triage に弾かれると
    /// 「使えるワーカーが無い」で run ごと落ちる。10 台あった頃はその余裕が偶然あった。
    /// 台数が上限以下、または本数が 0(= platform 不明で絞れない)のときは何もしない
    /// 用意する台数。**判断はここだけ**(テストはこの純粋関数を直接叩く)。
    /// `scenarios == 0` は「判断材料が無い」= 絞らない
    public static func deviceKeepCount(available: Int, scenarios: Int) -> Int {
        guard scenarios > 0 else { return available }
        return min(available, scenarios + 1)
    }

    /// `run --device` の絞り込み(マシン別サブ実行が「自分のぶんのデバイス」だけを回すのに使う)。
    /// 空配列は「絞らない」。**1台も残らない指定は呼び出し側でエラーにする** ——
    /// ここで黙って全台に戻すと、名前を打ち間違えたときに意図しない台で走る
    /// マシン別サブ実行のスコープ。**一意なのは name 単体ではなく (host, name)** なので、
    /// 名前だけで絞ると**別の機械の同名デバイスまで掴む**(フリートの各機は同じ命名規則で
    /// シミュレータを作るので、同名は例外ではなく通常。実走で確認 ——
    /// 手元のサブ実行が3機ぶんの "iPhone …-01" を全部拾って8台になった)。
    /// - deviceMachine: そのサブ実行が担当する機械("local" / 登録名。nil = ホストで絞らない)
    public func filteringDevices(names: [String], deviceMachine: String? = nil) -> ResolvedProfile {
        guard !names.isEmpty || deviceMachine != nil else { return self }
        let wanted = Set(names)
        let wantedHost = MachineDispatch.normalize(deviceMachine)
        var filtered = self
        filtered.devices = devices.filter { device in
            if !wanted.isEmpty, !wanted.contains(device.name) { return false }
            guard deviceMachine != nil else { return true }
            return MachineDispatch.normalize(device.spec.machine) == wantedHost
        }
        return filtered
    }

    /// `avoiding` の台(MCP が操作している台。ユーザー決定「避けて、足りなければ警告して使う」)は、**ほかの台で
    /// 本数ぶん足りるなら予備にも残さない** —— 残した台はシナリオを早い者勝ちで取り合うので、予備として残すと
    /// 結局そこで走る。本数が分からない(0 = 絞らない)ときは、ほかに台があれば外す。足りないときだけ足りない
    /// ぶんを加える。**既定値を置かない** —— 呼び出し元が渡し忘れると黙って MCP の台を使う形へ戻る
    public func limitingDevices(iosScenarios: Int, androidScenarios: Int,
                                avoiding: (ResolvedDevice) -> Bool) -> ResolvedProfile {
        func keep(_ list: [ResolvedDevice], _ count: Int) -> [ResolvedDevice] {
            let free = list.filter { !avoiding($0) }
            let avoided = list.filter(avoiding)
            guard count > 0 else { return free.isEmpty ? avoided : free }
            if free.count >= count {
                return Array(free.prefix(Self.deviceKeepCount(available: free.count, scenarios: count)))
            }
            let total = Self.deviceKeepCount(available: list.count, scenarios: count)
            return free + avoided.prefix(total - free.count)
        }
        let kept = Set(keep(iosDevices, iosScenarios) + keep(androidDevices, androidScenarios))
        guard kept.count < devices.count else { return self }
        var trimmed = self
        trimmed.devices = devices.filter { kept.contains($0) }
        return trimmed
    }
}

/// プロファイルファイルの種別(profiles/ 配下のサブディレクトリと対応)
public enum ProfileFileKind: String, CaseIterable, Sendable {
    case app, run

    /// profiles/ 配下のサブディレクトリ名
    public var directoryName: String {
        switch self {
        case .app: return "apps"
        case .run: return "runs"
        }
    }

    public var label: String {
        switch self {
        case .app: return "app"
        case .run: return "run"
        }
    }
}

// MARK: - エラー

/// 重複デバイス名エラーの文言の共有部分(ProfileError.duplicateDeviceName と
/// ProfileResolver.validate の2箇所で同じ言い回しにする)。判定は無効化された行
/// (`"enabled": false`)も重複に数える(DeviceMachineGrouping.entries(enabledOnly: false))ので、
/// 文言もそれを言う —— 編集画面には見えない無効行がエラーの原因になりうるため
private let duplicateDeviceNameRule =
    "names must be unique per machine, across ios and android — entries with \"enabled\": false count too"

public enum ProfileError: Error, LocalizedError {
    case runProfileNotFound(name: String, available: [String])
    case appProfileNotFound(name: String, available: [String])
    case decodeFailed(URL, detail: String)
    case missingAppReference(run: String)
    case missingDevices(run: String)
    /// devices はあるが全台が enabled: false
    case noEnabledDevices(run: String)
    /// 同じ (platform 横断で machine, name) が2つある。**別マシンの同名は重複ではない**(DeviceMachineGrouping)
    case duplicateDeviceName(name: String, deviceMachine: String?, run: String)
    case missingBundleID(platform: String, appProfile: String)
    case invalidWipeDataThreshold(run: String)
    case invalidLocale(run: String)
    /// kind=physical なのに同定に必要な識別子(iOS=udid / Android=serial)が無い
    case physicalDeviceMissingIdentifier(name: String, platform: String, run: String)
    /// kind=physical に dylib 注入エンジンが指定された(実機は注入不可)
    case physicalDeviceUnsupportedEngine(name: String, engine: String, run: String)

    public var errorDescription: String? {
        switch self {
        case .runProfileNotFound(let name, let available):
            return "run profile not found: \(name)"
                + availableHint(available, empty: "profiles/runs/ is empty")
        case .appProfileNotFound(let name, let available):
            return "app profile not found: \(name)"
                + availableHint(available, empty: "profiles/apps/ is empty")
        case .decodeFailed(let url, let detail):
            return "cannot load the profile: \(url.path)\n\(detail)"
        case .missingAppReference(let run):
            return "run profile \(run) has no \"app\" (a reference into apps/)"
        case .missingDevices(let run):
            return "run profile \(run) has no \"devices\""
        case .noEnabledDevices(let run):
            return "run profile \(run) has no enabled devices (every entry in \"devices\" has \"enabled\": false)"
        case .duplicateDeviceName(let name, let deviceMachine, let run):
            return "duplicate device name in run profile \(run): \(name)"
                + " on machine \(DeviceMachineGrouping.display(deviceMachine))"
                + " (\(duplicateDeviceNameRule))"
        case .missingBundleID(let platform, let appProfile):
            // common の app は廃止(merging 参照)のため、案内は platform セクション限定
            return "app profile \(appProfile) has no \"app\" (bundle ID / package name) for \(platform)"
                + " (add it in the \(platform) section)"
        case .invalidWipeDataThreshold(let run):
            return "wipeDataThresholdGB in run profile \(run) must be a positive number (GB)"
        case .invalidLocale(let run):
            return "locale in run profile \(run) must look like ja_JP"
        case .physicalDeviceMissingIdentifier(let name, let platform, let run):
            let field = platform == "ios" ? "udid" : "serial"
            let how = platform == "ios"
                ? "the Identifier column of xcrun devicectl list devices, or the UDID"
                : "the left column of adb devices"
            return "device \"\(name)\" in run profile \(run) is kind=physical but has no "
                + "\"\(field)\" (set it to \(how))"
        case .physicalDeviceUnsupportedEngine(let name, let engine, let run):
            return "device \"\(name)\" in run profile \(run) is kind=physical, so "
                + "engine=\(engine) cannot be used (dylib injection is impossible on physical devices; "
                + "omit engine or set it to \"xcuitest\")"
        }
    }

    private func availableHint(_ available: [String], empty: String) -> String {
        available.isEmpty ? " (\(empty))" : " (available: \(available.joined(separator: ", ")))"
    }
}

// MARK: - 解決

public enum ProfileResolver {

    /// profiles/runs/ の実行プロファイル名一覧(拡張子なし、名前順)
    public static func runProfileNames(project: TestProject) -> [String] {
        jsonNames(in: project.runsDir)
    }

    /// profiles/apps/ のアプリケーションプロファイル名一覧
    public static func appProfileNames(project: TestProject) -> [String] {
        jsonNames(in: project.appsDir)
    }

    /// 実行プロファイルが使う(enabled の)デバイスを「どの機械に居るか」付きで返す(ディスパッチ判定用。
    /// フルの resolve() はアプリ解決まで行い、machine を決める前に落ちうるのでこちらを使う)。
    /// 読めなければ空(警告と中止は resolve() が受け持つ)
    public static func runDeviceMachines(project: TestProject,
                                         runProfileName: String) -> [RunDeviceMachine] {
        let runURL = project.runsDir.appendingPathComponent("\(runProfileName).json")
        guard let runData = try? Data(contentsOf: runURL),
              let runDoc = try? JSONDecoder().decode(RunProfileDocument.self, from: runData) else {
            return []
        }
        return DeviceMachineGrouping.entries(runDevices: runDoc.devices ?? [], enabledOnly: true)
            .map { RunDeviceMachine(machine: $0.machine, name: $0.name, platform: $0.platform) }
    }

    /// runProfileName の実行プロファイルが宣言する `remoteControl.workspace`(trim 後非空)を返す。
    /// ファイルが無い/デコード不能/未宣言・空文字列なら nil。**マシン解決を必要としないので
    /// フルの resolve() を経由しない** —— リモートディスパッチ(Sources/fleetest/
    /// RemoteRunDispatcher.swift)はミラーの要否だけを知りたく、実行するマシンはまだ決めていない
    public static func declaredWorkspace(project: TestProject, runName: String) -> String? {
        let runURL = project.runsDir.appendingPathComponent("\(runName).json")
        guard let data = try? Data(contentsOf: runURL),
              let doc = try? JSONDecoder().decode(RunProfileDocument.self, from: data),
              let workspace = doc.remoteControl?.workspace?.trimmingCharacters(in: .whitespacesAndNewlines),
              !workspace.isEmpty else {
            return nil
        }
        return workspace
    }

    /// `resolveWorkspaceRoot` の軽量版(declaredWorkspace を読むだけ。マシン/デバイス解決を
    /// 経由しない —— RemoteRunDispatcher がミラー前に、実行するマシンを決める前に呼ぶ)。
    /// override は渡さない(このホストがワークスペースを最初に組み立てる側 = `--workspace` は
    /// 子プロセスへの中継専用で、ここでは常に無指定)
    public static func effectiveWorkspaceRoot(project: TestProject, runName: String) -> URL {
        let repoRoot = project.rootURL.deletingLastPathComponent().deletingLastPathComponent()
        return resolveWorkspaceRoot(
            declared: declaredWorkspace(project: project, runName: runName), override: nil,
            projectRoot: project.rootURL, repoRoot: repoRoot)
    }

    /// ステージング対象(appPath の原本)だけを軽量に読む。マシン/デバイス解決を経由しない
    /// (declaredWorkspace と同じ理由 —— RemoteRunDispatcher はミラー直前にここだけ要る)。
    /// 戻り値: platform("ios"/"android") → (原本の絶対パス, 生の宣言文字列)
    /// (appPath 未指定の platform は含まない)。プロファイル/アプリ定義が読めなければ空を返す
    public static func declaredAppPaths(project: TestProject,
                                        runName: String) -> [DeclaredAppPath: DeclaredAppPathEntry] {
        guard let runData = try? Data(
                contentsOf: project.runsDir.appendingPathComponent("\(runName).json")),
              let runDoc = try? JSONDecoder().decode(RunProfileDocument.self, from: runData),
              let appRef = runDoc.app else { return [:] }
        guard let appData = try? Data(
                contentsOf: project.appsDir.appendingPathComponent("\(appRef).json")),
              let appProfile = try? JSONDecoder().decode(AppProfile.self, from: appData) else { return [:] }
        let repoRoot = project.rootURL.deletingLastPathComponent().deletingLastPathComponent()
        var result: [DeclaredAppPath: DeclaredAppPathEntry] = [:]
        for platform in ["ios", "android"] {
            let section = appProfile.section(for: platform)
            if let raw = section.appPath {
                result[DeclaredAppPath(platform: platform, physical: false)] =
                    DeclaredAppPathEntry(source: resolvePath(raw, base: repoRoot), declared: raw)
            }
            // **この経路はデバイスを解決しない**(devices を読まない軽量読み)ので
            // 「そのランナーに実機が居るか」を知らない。居る場合に運び忘れると向こうで
            // 仮想デバイス用ビルドを実機へ入れて 0xe8008014 で落ちるため、宣言があれば運ぶ
            if let raw = section.appPathPhysical {
                result[DeclaredAppPath(platform: platform, physical: true)] =
                    DeclaredAppPathEntry(source: resolvePath(raw, base: repoRoot), declared: raw)
            }
        }
        return result
    }

    /// `remoteControl.workspace` 宣言と `--workspace` 上書きから実効の生値(未解決)を決める。
    /// override が非空なら常に勝つ(中継されたリモートの子はこれで自分のリポジトリルート基準を
    /// 上書きする)。両方無ければ nil(未宣言 = リポジトリルート基準)。
    /// 純粋関数として切り出す(デバイス・ファイル I/O 不要のためテストが直接叩ける)
    public static func effectiveWorkspaceRaw(declared: String?, override: String?) -> String? {
        func trimmedNonEmpty(_ s: String?) -> String? {
            guard let s else { return nil }
            let trimmed = s.trimmingCharacters(in: .whitespacesAndNewlines)
            return trimmed.isEmpty ? nil : trimmed
        }
        return trimmedNonEmpty(override) ?? trimmedNonEmpty(declared)
    }

    /// `remoteControl.workspace` の実効ルート(絶対パス解決済み)。優先順は
    /// **override(`--workspace`) > declared(`remoteControl.workspace`) > 既定**。
    /// **既定は `"<projectRoot>/workspace"`**(常に非 nil を返す ——
    /// ワークスペースは常に有効。declared/override 省略時に repoRoot 基準へ戻すと、
    /// 呼び出し側ごとに「省略時どう扱うか」の分岐が要る)。declared/override が相対パスなら
    /// repoRoot 基準で解決する(絶対パスならそのまま)。純粋関数(I/O なし)
    public static func resolveWorkspaceRoot(
        declared: String?, override: String?, projectRoot: URL, repoRoot: URL
    ) -> URL {
        guard let raw = effectiveWorkspaceRaw(declared: declared, override: override) else {
            return projectRoot.appendingPathComponent(WorkspaceScaffold.defaultRootName)
        }
        return URL(fileURLWithPath: resolvePath(raw, base: repoRoot))
    }

    /// 実行プロファイルを合成して ResolvedProfile を返す。
    /// - workspaceOverride: `--workspace`(hidden)。実行プロファイルの `remoteControl.workspace` を
    ///   上書きする。リモートディスパッチが、ミラー先を実行するマシンの子へ伝えるのに使う
    ///   (RemoteRunDispatcher が必ず渡す。渡さないと子は自分のリポジトリルート基準で appPath を
    ///   解決し、リモートに転送されていない絶対パスを見に行く)
    public static func resolve(project: TestProject, runName: String,
                               workspaceOverride: String? = nil,
                               overrides: [String: RunProfileSetValue] = [:]) throws -> ResolvedProfile {
        var warnings: [String] = []

        // 1. 実行プロファイル
        let runURL = project.runsDir.appendingPathComponent("\(runName).json")
        guard FileManager.default.fileExists(atPath: runURL.path) else {
            throw ProfileError.runProfileNotFound(
                name: runName, available: runProfileNames(project: project))
        }
        let loadedRunDoc: RunProfileDocument = try load(runURL, warnings: &warnings) { json in
            checkKeys(json, allowed: RunProfileDocument.knownKeys, context: "runs/\(runName).json")
                + checkDeviceEntryKeys(json, context: "runs/\(runName).json")
                + checkRemoteControlKeys(json, context: "runs/\(runName).json")
        }
        // `--set` はここで一度だけ当てる(読み込み直後・解決より前)。以降の全処理はこの
        // runDoc だけを見るので、全キーが個別の配線無しで効く(RunProfileDocument.applyingOverrides)
        let runDoc = loadedRunDoc.applyingOverrides(overrides)
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

        // 3. デバイス(enabled の台だけ)。一意なのは (machine, name)。別マシンの同名は許す
        // (DeviceMachineGrouping にすべての規則がある)。重複は無効の台も含めて見る(台帳として壊れている)
        if let duplicate = DeviceMachineGrouping.firstDuplicate(
            in: DeviceMachineGrouping.entries(runDevices: deviceRefs, enabledOnly: false)) {
            throw ProfileError.duplicateDeviceName(
                name: duplicate.name, deviceMachine: duplicate.machine, run: runName)
        }
        let enabledEntries = DeviceMachineGrouping.entries(runDevices: deviceRefs, enabledOnly: true)
        guard !enabledEntries.isEmpty else {
            throw ProfileError.noEnabledDevices(run: runName)
        }

        // 4. iOS 実効エンジン: 実行プロファイルの iosInappEngine(既定 true)で決める。
        // true → "hybrid"(高速な in-app 主+XCUITest フォールバック)、false → "xcuitest"。
        // ただし台に engine を明示していればそちらが優先(上書きしない)。
        let iosEngine = (runDoc.iosInappEngine ?? true) ? "hybrid" : "xcuitest"
        var devices: [ResolvedDevice] = []
        for entry in enabledEntries {
            // 実体の無い登録は走る前に言う(iOS は既定名へ落ちて別の台で黙って走る)。
            // 止めはしない —— 既定に頼っている既存プロファイルを赤にしない
            if entry.spec.lacksConcreteTarget {
                warnings.append(
                    "device \"\(entry.name)\" on machine \(DeviceMachineGrouping.display(entry.machine))"
                    + " has no concrete target (ios: udid/osVersion, android: avd/serial)"
                    + " — re-run `fleetest profile setup --auto-device`,"
                    + " or fill it in in profiles/runs/\(runName).json")
            }
            let device = ResolvedDevice(platform: entry.platform, spec: entry.spec)
            try validatePhysical(device, run: runName)
            if device.spec.isPhysical, device.platform == "ios" {
                // 実機は dylib 注入不可。iosInappEngine の既定(hybrid)を無視して固定する
                // (ここで潰さないと provision が inapp 経路に入り実行時に落ちる)
                var spec = device.spec
                spec.engine = "xcuitest"
                devices.append(ResolvedDevice(platform: "ios", spec: spec))
            } else if device.platform == "ios", device.spec.engine == nil {
                var spec = device.spec
                spec.engine = iosEngine
                devices.append(ResolvedDevice(platform: "ios", spec: spec))
            } else {
                // フラグを明示指定したのにデバイス側 engine が勝つ組み合わせは
                // GUI のチェックボックスが「効かない」ように見えるため警告で知らせる
                if device.platform == "ios", runDoc.iosInappEngine != nil,
                   let explicit = device.spec.engine {
                    warnings.append(
                        "device \"\(entry.name)\" explicitly sets engine=\(explicit), "
                        + "so the iosInappEngine setting does not apply to it")
                }
                devices.append(device)
            }
        }

        // 5. アプリ解決(デバイスのある platform ごと。合成規則は AppProfileSection.merging 参照)
        // appPath の相対パスは常に「リポジトリルート」基準(project.rootURL =
        // <repoRoot>/TestProjects/<name> の2階層上。= アプリの原本の場所)。**ワークスペースの
        // 有無・既定/明示のどれでもこの基準は変えない**(ワークスペース基準へ切り替えない ——
        // 原本の置き場所とインストールに使う場所は別物。docs/remote-runner.md §17)。packageRoot() の CWD 走査は使わない(単体テストでは CWD が
        // 本体リポジトリを指し誤基準になる。project.rootURL からの決定的導出で統一)。
        // reportDir だけはプロジェクト直下に出すため下記で project.rootURL 基準のまま
        // (基準が異なるので resolvePath の base で使い分ける)。
        //
        // **ワークスペースは常に有効**(既定 `"<project.rootURL>/workspace"`)。
        // インストールに使うパス(ResolvedAppTarget.appPath)は常に
        // "<workspaceRoot>/apps/<原本のファイル名>" に切り替わる(原本の
        // ResolvedAppTarget.sourcePath は常にリポジトリルート基準のまま)。実体のコピー(ステージング)
        // はここでは行わない(純粋な path 計算のみ) —— 呼び出し側(ProfileRunner.run/ApiRunCommand/
        // RemoteRunDispatcher/MCP の resolveProfileTarget)が resolve() 直後に `WorkspaceAppStaging` を呼んで原本を運ぶ。
        // リモートへディスパッチすると appPath のアプリパッケージ自体は転送されない
        // (RemoteTransferPlan.rsyncArgs は TestProjects/<project> しか rsync しない)ため、
        // リポジトリルート基準の絶対パスはリモートに存在しない。既定のワークスペースは
        // project.rootURL 配下なので、その転送(rsyncArgs)自体がステージング済みの apps/ を
        // 運ぶ ―― 明示指定でプロジェクト外を指したときだけ専用ミラーが要る
        // (`WorkspaceRemoteDispatch.placement`。Sources/fleetest/RemoteRunDispatcher.swift)
        let repoRoot = project.rootURL.deletingLastPathComponent().deletingLastPathComponent()
        let workspaceRoot = resolveWorkspaceRoot(
            declared: runDoc.remoteControl?.workspace, override: workspaceOverride,
            projectRoot: project.rootURL, repoRoot: repoRoot)
        // 開始/終了スクリプト。パス計算だけで、ファイルの有無は見ない —— それは実行側
        // (RunHookRunner)が action() で判定する(resolve は I/O を増やさない)
        let setupHook = RunHookPlan.resolve(kind: .setup, workspaceRoot: workspaceRoot)
        let teardownHook = RunHookPlan.resolve(kind: .teardown, workspaceRoot: workspaceRoot)
        var apps: [String: ResolvedAppTarget] = [:]
        for platform in Set(devices.map(\.platform)) {
            let section = appProfile.section(for: platform)
            guard let bundleID = section.app else {
                throw ProfileError.missingBundleID(platform: platform, appProfile: appRef)
            }
            let sourcePath = section.appPath.map { resolvePath($0, base: repoRoot) }
            // installPath の名前空間は section.appPath(生の宣言文字列)から作る —— resolvePath 後の
            // 絶対パス(sourcePath)は repoRoot 込みでホストごとに違うため、そこから作ると
            // ローカルとリモートの子で違うステージ先になってしまう(WorkspaceAppStaging.installPath の doc)
            let installPath = section.appPath.map { declared in
                WorkspaceAppStaging.installPath(declared: declared, workspaceRoot: workspaceRoot)
            }
            let physicalSource = section.appPathPhysical.map { resolvePath($0, base: repoRoot) }
            let physicalInstallPath = section.appPathPhysical.map { declared in
                WorkspaceAppStaging.installPath(declared: declared, workspaceRoot: workspaceRoot,
                                                physical: true)
            }
            apps[platform] = ResolvedAppTarget(
                bundleID: bundleID,
                sourcePath: sourcePath,
                appPath: installPath,
                sourcePathPhysical: physicalSource,
                appPathPhysical: physicalInstallPath,
                // **appPath があれば既定で有効**。パスを書いたのに入らない(既定 false)方が
                // 事故で、警告を出さないと気付けない設計だった。止めたいときだけ
                // autoInstall: false を明示する(opt-out)。実インストールは中身が変わったときだけ
                autoInstall: section.autoInstall
                    ?? (section.appPath != nil || section.appPathPhysical != nil),
                healthCheckURL: section.healthCheckURL)
            // **iOS の実機にシミュレータ用ビルドは入らない**(未署名 = 0xe8008014)。
            // インストールの失敗は run の途中(ブリッジ供給の後)に出るので、
            // ここで先に言う。止めはしない。**appPath 自体が実機用ビルドなら鳴らさない**
            // (Info.plist の CFBundleSupportedPlatforms で判る)。**原本(sourcePath)が読めなければ
            // ステージ済みの複製(installPath)を読む** —— リモートの子は原本を持たず
            // ステージ先の複製だけを持つため、sourcePath だけを見ると常に nil(判らない)になり
            // 実機用ビルドが appPath に入っている場合でも誤って警告が鳴る。両方読めないときだけ
            // 鳴らす(安全側)
            if platform == "ios", section.appPathPhysical == nil, section.appPath != nil,
               (AppBundleInspector.declaresDevicePlatform(appPath: sourcePath)
                   ?? AppBundleInspector.declaresDevicePlatform(appPath: installPath)) != true,
               devices.contains(where: { $0.platform == "ios" && $0.spec.isPhysical }) {
                warnings.append(
                    "the run includes a physical iOS device but apps/\(appRef).json has no"
                    + " \"appPathPhysical\" — a simulator build cannot be installed on a device"
                    + " (it is unsigned); set appPathPhysical to a device build")
            }
            // appName はアイコン名を兼ねる(AppBundleInspector.appNameMismatchWarning の doc)。
            // 読めるのは iOS の .app だけ(APK のラベルは aapt が要る)。候補は原本2つの和 ——
            // 片方にしか無い名前でも一致すれば黙る(誤検知を出さない側)
            if platform == "ios", let appName = section.appName {
                var candidates: [String] = []
                for path in [sourcePath, physicalSource].compactMap({ $0 }) {
                    for name in AppBundleInspector.iconNameCandidates(appPath: path)
                    where !candidates.contains(name) {
                        candidates.append(name)
                    }
                }
                if let warning = AppBundleInspector.appNameMismatchWarning(
                    appRef: appRef, platform: platform, appName: appName, candidates: candidates) {
                    warnings.append(warning)
                }
            }
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

        // デバイスに依存しない実効設定(FM の子トグルからの合成含む)は `--profile` 無しの直接実行
        // (`fleetest run`/`fleetest api run` の profile-less パス)と1つの関数を共有する
        // (DeviceIndependentRunSettings.resolve)。ここでしか決まらないデバイス依存の欄
        // (iosInappEngine 等。RunProfileDocument.profileOnlyKeys)だけ runDoc から直接読む
        let settings = DeviceIndependentRunSettings.resolve(runDoc)

        return ResolvedProfile(
            project: project,
            runName: runName,
            appName: appProfile.resolvedAppName ?? appRef,
            apps: apps,
            devices: devices,
            fm: settings.fm,
            heal: settings.heal,
            reportDir: reportDir,
            defaultTimeout: runDoc.defaultTimeout,
            scenarioTimeout: runDoc.scenarioTimeout,
            wipeDataOnBloat: runDoc.wipeDataOnBloat ?? true,
            updateWebView: runDoc.updateWebView ?? true,
            wipeDataThresholdGB: wipeDataThresholdGB,
            recoverCpuFallbackToGpu: runDoc.recoverCpuFallbackToGpu ?? false,
            locale: locale,
            iosFastInput: settings.iosFastInput,
            iosPreActionWarmup: settings.iosPreActionWarmup,
            containerInference: settings.containerInference,
            ocrTextOcclusionCheck: settings.ocrTextOcclusionCheck,
            preferCheckStateClassifier: settings.preferCheckStateClassifier,
            enableAnimations: settings.enableAnimations,
            homeOnStart: settings.homeOnStart,
            playProtectBypass: settings.playProtectBypass,
            record: settings.record,
            recordFailuresOnly: settings.recordFailuresOnly,
            recordBitrateKbps: RunProfileDocument.effectiveRecordBitrateKbps(runDoc.recordBitrateKbps),
            recordFullResolution: settings.recordFullResolution,
            workspaceRoot: workspaceRoot,
            setupHook: setupHook,
            teardownHook: teardownHook,
            warnings: warnings)
    }

    /// 実機デバイスの整合検査。enabled の台にのみ適用する
    /// (無効の台の不備で run を止めない)
    private static func validatePhysical(_ device: ResolvedDevice, run: String) throws {
        guard device.spec.isPhysical else { return }
        let identifier = device.platform == "ios" ? device.spec.udid : device.spec.serial
        guard let identifier, !identifier.trimmingCharacters(in: .whitespaces).isEmpty else {
            throw ProfileError.physicalDeviceMissingIdentifier(
                name: device.name, platform: device.platform, run: run)
        }
        if device.platform == "ios", let engine = device.spec.engine,
           engine != "xcuitest" {
            throw ProfileError.physicalDeviceUnsupportedEngine(
                name: device.name, engine: engine, run: run)
        }
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

    /// デコード失敗を「どのキーが・何を期待したか」で言う(型の違いだけではどの欄を直すか分からない)
    static func describeDecodingError(_ error: Error) -> String {
        func path(_ context: DecodingError.Context) -> String {
            var out = ""
            for key in context.codingPath {
                if let index = key.intValue { out += "[\(index)]" }
                else { out += (out.isEmpty ? "" : ".") + key.stringValue }
            }
            return out.isEmpty ? "the top level" : "\"" + out + "\""
        }
        switch error as? DecodingError {
        case .typeMismatch(let type, let context)?:
            return "\(path(context)): expected \(type)"
        case .valueNotFound(let type, let context)?:
            return "\(path(context)): expected \(type), got null"
        case .keyNotFound(let key, let context)?:
            let parent = context.codingPath.isEmpty ? "" : " in " + path(context)
            return "missing \"\(key.stringValue)\"\(parent)"
        case .dataCorrupted(let context)?:
            return "\(path(context)): \(context.debugDescription)"
        default:
            return "type mismatch"
        }
    }

    // MARK: - 単一ファイル検証(プロファイルエディタ用)

    /// プロファイルファイル 1 つの検証。戻り値: (エラー, 警告)。
    /// エラー = デコード不能・必須欠落・name 重複、警告 = 未知キー(タイポ検出)
    public static func validate(
        kind: ProfileFileKind, data: Data, context: String
    ) -> (errors: [String], warnings: [String]) {
        guard let parsed = try? JSONSerialization.jsonObject(with: data, options: [.fragmentsAllowed]) else {
            return (["cannot parse as JSON (syntax error)"], [])
        }
        guard let json = parsed as? [String: Any] else {
            let got = parsed is [Any] ? "an array" : "a single value"
            return (["the top level must be a JSON object ({ ... }), not \(got)"], [])
        }
        var errors: [String] = []
        var warnings: [String] = []
        let decoder = JSONDecoder()
        switch kind {
        case .app:
            do { _ = try decoder.decode(AppProfile.self, from: data) } catch {
                errors.append("cannot load as an app profile (\(describeDecodingError(error)))")
            }
            warnings += checkAppProfileKeys(json, context: context)
        case .run:
            if let doc = try? decoder.decode(RunProfileDocument.self, from: data) {
                if doc.app == nil { errors.append("no \"app\" (a reference into apps/)") }
                let devices = doc.devices ?? []
                if devices.isEmpty { errors.append("no \"devices\"") }
                // **一意なのは (machine, name)**(別の機械の同名は重複ではない)。判定は
                // DeviceMachineGrouping で resolve() と共有する —— 片方だけ厳しいと
                // 「保存できるのに検証が赤い」(その逆も)になる
                if let duplicate = DeviceMachineGrouping.firstDuplicate(
                    in: DeviceMachineGrouping.entries(runDevices: devices, enabledOnly: false)) {
                    errors.append("duplicate device name: \(duplicate.name)"
                                  + " on machine \(DeviceMachineGrouping.display(duplicate.machine))"
                                  + " (\(duplicateDeviceNameRule))")
                }
                for entry in devices where entry.isEnabled {
                    errors += physicalDeviceErrors(entry.spec, platform: entry.platform)
                }
                if let threshold = doc.wipeDataThresholdGB, threshold <= 0 {
                    errors.append("\"wipeDataThresholdGB\" must be a positive number (GB)")
                }
                // 負値・0・NaN はホストの watchdog(ScenarioHost.watchdogDuration)まで
                // 届くと壊れた/意味の無い挙動になる(0 秒 watchdog・即トリガー)
                if let scenarioTimeout = doc.scenarioTimeout, scenarioTimeout < 1 {
                    errors.append("\"scenarioTimeout\" must be a positive number of seconds")
                }
                // 検証待ち(defaultTimeout)の 0 は正当(初回スナップショットだけを見る)。負値だけ断る
                if let defaultTimeout = doc.defaultTimeout, !(defaultTimeout >= 0 && defaultTimeout.isFinite) {
                    errors.append("\"defaultTimeout\" must be a non-negative, finite number of seconds (0 = the first snapshot only, no waiting)")
                }
                let locale = (doc.locale ?? "ja_JP").trimmingCharacters(in: .whitespacesAndNewlines)
                if !isValidLocale(locale) {
                    errors.append("\"locale\" must look like ja_JP")
                }
            } else {
                let reason: String
                do { _ = try decoder.decode(RunProfileDocument.self, from: data); reason = "" }
                catch { reason = describeDecodingError(error) }
                errors.append("cannot load as a run profile (\(reason))")
            }
            warnings += checkKeys(json, allowed: RunProfileDocument.knownKeys, context: context)
            warnings += checkDeviceEntryKeys(json, context: context)
            warnings += checkRemoteControlKeys(json, context: context)
        }
        return (errors, warnings)
    }

    // MARK: - 内部ヘルパー

    /// エディタ用の実機検査(resolve 側の validatePhysical と同じ規則を文言だけ単体ファイル向けにしたもの)
    private static func physicalDeviceErrors(_ spec: DeviceSpec, platform: String) -> [String] {
        guard spec.isPhysical else { return [] }
        var errors: [String] = []
        let field = platform == "ios" ? "udid" : "serial"
        let identifier = platform == "ios" ? spec.udid : spec.serial
        if (identifier?.trimmingCharacters(in: .whitespaces) ?? "").isEmpty {
            errors.append("device \"\(spec.name)\" is kind=physical but has no \"\(field)\"")
        }
        if platform == "ios", let engine = spec.engine, engine != "xcuitest" {
            errors.append("device \"\(spec.name)\" is kind=physical, so engine=\(engine) cannot be"
                          + " used (dylib injection is impossible on physical devices)")
        }
        return errors
    }

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
            "\(context): unknown key \"\($0)\" is ignored"
        }
    }

    private static func checkDeviceEntryKeys(_ json: [String: Any], context: String) -> [String] {
        guard let devices = json["devices"] as? [[String: Any]] else { return [] }
        return devices.flatMap {
            checkKeys($0, allowed: RunDeviceEntry.knownKeys, context: "\(context) devices")
        }
    }

    private static func checkRemoteControlKeys(_ json: [String: Any], context: String) -> [String] {
        guard let section = json["remoteControl"] as? [String: Any] else { return [] }
        return checkKeys(section, allowed: RemoteControlSection.knownKeys, context: "\(context) remoteControl")
    }

    private static func checkAppProfileKeys(_ json: [String: Any], context: String) -> [String] {
        var warnings = checkKeys(json, allowed: AppProfile.knownKeys, context: context)
        for key in AppProfile.knownKeys {
            guard let section = json[key] as? [String: Any] else { continue }
            // common と ios/android で許容キーが違う(commonKnownKeys 参照)
            let allowed = key == "common"
                ? AppProfileSection.commonKnownKeys : AppProfileSection.platformKnownKeys
            warnings += checkKeys(section, allowed: allowed, context: "\(context) \(key)")
        }
        return warnings
    }
}
