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
/// (対応表は merging 参照): appName・app・appPath = platform のみ /
/// autoInstall = common のみ(未指定なら appPath の有無で決まる。false 明示で opt-out)
public struct AppProfileSection: Codable, Sendable, Equatable {
    /// ユーザーがアプリを識別するための表示名(レポート/ログで使用)
    public var appName: String?
    /// bundle identifier / パッケージ名
    public var app: String?
    /// パッケージファイル(.app / .apk / .apks)のパス。プロジェクトルート相対 or 絶対 or ~
    public var appPath: String?
    /// 実行前に appPath を自動インストールするか(既定 false = 無効)
    public var autoInstall: Bool?
    /// アプリが依存するバックエンドの死活確認 URL(common のみ)。実行開始前に到達確認し、
    /// 不達なら警告する(バックエンド停止でアプリがクラッシュ→全滅する事故の早期検知。
    /// 2026-07-21 の実害から追加)。ブロックはしない(オフライン検証を妨げない)
    public var healthCheckURL: String?

    public init(appName: String? = nil, app: String? = nil,
                appPath: String? = nil, autoInstall: Bool? = nil,
                healthCheckURL: String? = nil) {
        self.appName = appName
        self.app = app
        self.appPath = appPath
        self.autoInstall = autoInstall
        self.healthCheckURL = healthCheckURL
    }

    /// common セクションで許容されるキー(appName は platform 専用のためここには含まない —
    /// 含めると common.appName が「既知キー」に化けて checkAppProfileKeys の未知キー検出を
    /// すり抜け、黙って無視される)
    static let commonKnownKeys: Set<String> = ["app", "appPath", "autoInstall", "healthCheckURL"]
    /// ios/android セクションで許容されるキー
    static let platformKnownKeys: Set<String> = [
        "appName", "app", "appPath", "autoInstall", "healthCheckURL",
    ]

    /// common(self)と platform セクション(other)の合成(section(for:)専用)。フィールドごとに
    /// 採用元が異なる: appName・app・appPath = platform のみ(OS ごとに書き分けるため。
    /// 表示名も common からは継承しない) /
    /// autoInstall = common のみ(未指定なら appPath の有無で決まる。false 明示で opt-out)(インストール可否は OS 間で揃えるべき運用設定のため)。
    /// common セクションに appName/app/appPath が書かれていてもここで黙って無視される(validate が警告を出す)。
    /// other が nil(platform セクション自体が無い)場合も同じ規則で合成するため、
    /// early return せず常に other?.field / self.field を明示的に選ぶ
    func merging(_ other: AppProfileSection?) -> AppProfileSection {
        AppProfileSection(
            appName: other?.appName,
            app: other?.app,
            appPath: other?.appPath,
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

/// マシンプロファイル内の 1 デバイス定義
public struct DeviceSpec: Codable, Sendable, Hashable {
    /// ユーザーがデバイスを識別するための名前(実行プロファイルからの参照キー)。
    /// **一意なのは name 単体ではなく (host, name)** —— 別のホストに同名のデバイスが居てよい
    /// (フリートの各機が同じ命名規則でシミュレータを作るため、同名は例外ではなく通常)
    public var name: String
    /// このデバイスが居る機械。省略時はマシンプロファイルの host(そちらも省略なら手元)。
    /// 書けるのは登録名だけ(ssh の実体は書けない。MachineProfile.host と同じ規律)。
    /// 解決規則は DeviceHostGrouping、正規化は MachineHostDispatch.normalize
    public var host: String?
    /// 実体種別(省略時 virtual)。実機の識別子は iOS=udid / Android=serial
    public var kind: DeviceKind?
    /// iOS: シミュレータのデバイス名(例 "iPhone 17 Pro"。実機では未使用)
    public var simulator: String?
    /// OS バージョン(例 "27.0")。iOS シミュレータでは実体解決に使う(省略時は名前一致の最新)。
    /// 実機では**表示専用**(model と同じく登録時に控えるだけ)
    public var os: String?
    /// iOS: UDID。kind=virtual ならシミュレータ UDID(simulator/os より優先)、
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
    /// 実機の機種名(iOS は marketingName、Android は ro.product.model)。**表示専用**で
    /// 同定には使わない(登録時に控えるだけ。端末を挿し替えても値は追随しない)
    public var model: String?

    public init(name: String, host: String? = nil, kind: DeviceKind? = nil,
                simulator: String? = nil, os: String? = nil,
                udid: String? = nil, port: UInt16? = nil, engine: String? = nil,
                avd: String? = nil, serial: String? = nil, model: String? = nil) {
        self.name = name
        self.host = host
        self.kind = kind
        self.simulator = simulator
        self.os = os
        self.udid = udid
        self.port = port
        self.engine = engine
        self.avd = avd
        self.serial = serial
        self.model = model
    }

    /// 実機か(kind 省略時は virtual)。デバイス種別の分岐はすべてこれを見ること
    public var isPhysical: Bool { kind == .physical }

    /// 「どの台か」が1つも書かれていない(name と host だけの登録)。iOS はこの状態でも
    /// SimulatorCatalog の既定名に落ちるので**黙って別の台で走る**(Android は起動時に落ちる)。
    /// 見るキーは ProfileWriter.deviceBodyKeys と同集合(DeviceSpecBodyKeysSyncTests が照合)
    public var lacksConcreteTarget: Bool {
        simulator == nil && os == nil && udid == nil && avd == nil && serial == nil
    }

    static let knownKeys: Set<String> = [
        "name", "host", "kind", "simulator", "os", "udid", "port", "engine", "avd", "serial",
        "model",
    ]
}

public struct MachineDeviceList: Codable, Sendable, Equatable {
    public var devices: [DeviceSpec]?

    public init(devices: [DeviceSpec]? = nil) { self.devices = devices }

    static let knownKeys: Set<String> = ["devices"]
}

/// マシンプロファイル(profiles/machines/<マシン名>.json)。ファイル名がマシン名
public struct MachineProfile: Codable, Sendable, Equatable {
    /// このマシンの実行先(2026-08-17)。省略/"local" = このマシンでローカル実行(**既存プロファイルは
    /// 無改修で動く**)。それ以外は `ftester remote hosts` の登録名でなければならない
    /// (生の ssh 宛先は書けない — プロファイルはプロジェクト資産で、ssh の実体はローカル設定
    /// = LocalConfig.remoteHosts にだけ置く規律。フリート定義と同じ)。優先順位・食い違いの扱いは
    /// MachineHostDispatch、登録簿引きは Sources/ftester/RemoteCommands.swift
    public var host: String?
    public var ios: MachineDeviceList?
    public var android: MachineDeviceList?

    public init(host: String? = nil, ios: MachineDeviceList? = nil, android: MachineDeviceList? = nil) {
        self.host = host
        self.ios = ios
        self.android = android
    }

    static let knownKeys: Set<String> = ["host", "ios", "android"]
}

/// `MachineProfile.host` と `--host`(CLI 明示)の優先順位を1箇所に固定する純粋関数(2026-08-17)。
/// マシンプロファイルに host を持たせたことで、実行プロファイル経由で間接的にリモートホストを
/// 指定できるようにした(ユーザー決定)。呼び出し側(Sources/ftester/RemoteCommands.swift)は
/// ここが返す名前を、由来に応じて登録簿引きするだけで if を散らさない。
public enum MachineHostDispatch {
    public struct Decision: Equatable {
        /// 実際に使うべきホスト名(nil = ローカル実行)
        public let host: String?
        /// `--host` とマシン側 host が両方非ローカルで食い違うときの1行注記。無ければ nil
        /// (黙って別のマシンへ送らない。既存の ResolvedRemoteHost.announce と同じ規律)
        public let mismatchWarning: String?

        public init(host: String? = nil, mismatchWarning: String? = nil) {
            self.host = host
            self.mismatchWarning = mismatchWarning
        }
    }

    /// nil・空文字・trim 後 "local" は「ローカル」(nil に正規化)。MachineProfile.host と
    /// --host の両方にこの規則を適用する
    public static func normalize(_ raw: String?) -> String? {
        guard let trimmed = raw?.trimmingCharacters(in: .whitespacesAndNewlines),
              !trimmed.isEmpty, trimmed != "local" else { return nil }
        return trimmed
    }

    /// **`--host` が常に勝つ**。マシン側 host が別のリモートを指していれば `mismatchWarning` を
    /// 返す(黙って上書きしない)。`--host` が無ければマシン側の値をそのまま自動採用する。
    ///
    /// **明示 `--host local` は「ここで走らせる」の指定であって「未指定」ではない**(欠陥3・
    /// 2026-08-17)。`normalize` は "local" を nil に畳むため、素の `normalize(explicitHost)` だけで
    /// 分岐すると "local" が「--host 未指定」と区別できず、マシン側の host へ自動ディスパッチして
    /// しまう(`FleetRunner` の "local" エントリが実際にはリモートへ飛ぶ実害があった)。ここでだけ
    /// 生の explicitHost を見て先に判定する。マシン側が別のリモートを指していれば、通常の食い違いと
    /// 同じ規律で mismatchWarning を返す(黙って上書きしない)
    public static func resolve(explicitHost: String?, machineHost: String?) -> Decision {
        let machine = normalize(machineHost)
        if isExplicitLocal(explicitHost) {
            guard let machine else { return Decision(host: nil) }
            return Decision(host: nil, mismatchWarning:
                "--host local overrides the machine profile's host \"\(machine)\""
                + " (the run stays local)")
        }
        guard let explicit = normalize(explicitHost) else {
            return Decision(host: machine)
        }
        guard let machine, machine != explicit else {
            return Decision(host: explicit)
        }
        return Decision(host: explicit, mismatchWarning:
            "--host \(explicit) overrides the machine profile's host \"\(machine)\""
            + " (they differ; the run continues on \(explicit))")
    }

    /// 生の(trim 前の)値が文字どおり "local" か。normalize 後の nil(= 未指定)とは区別する。
    /// `--host local` と実行プロファイルの `"host": "local"` の両方が「ここで走らせる」の明示指定で、
    /// 判定を写すと片方だけズレるのでここが唯一の定義元(呼び出し側は DeviceHostGrouping.resolve)
    public static func isExplicitLocal(_ raw: String?) -> Bool {
        guard let raw else { return false }
        return raw.trimmingCharacters(in: .whitespacesAndNewlines) == "local"
    }
}

/// 実行プロファイルのデバイス参照(name でマシンプロファイルを引く)
public struct RunDeviceRef: Codable, Sendable, Equatable {
    public var name: String
    /// 同名のデバイスが複数のホストに居るときの指定(省略可)。省略した参照が複数に当たると
    /// **候補を挙げて中止する**(どちらか一方を黙って選ばない。解決規則は DeviceHostGrouping)
    public var host: String?

    public init(name: String, host: String? = nil) {
        self.name = name
        self.host = host
    }

    static let knownKeys: Set<String> = ["name", "host"]
}

/// FM 機能の実行時トグル(実行プロファイル由来の実効値)。enabled=false のとき他フラグも
/// resolve 側で false に落とす(利用側は個別フラグだけ見ればよい)
public struct FMConfig: Sendable, Equatable {
    /// FM を使用するか(false = heal/偽陽性検証/screenIs/triage を一切呼ばない)
    public var enabled: Bool
    public var heal: Bool
    /// 偽陽性検証(occlusion guard)。プロファイル既定 false(FM コストと誤反転リスクのためオプトイン)
    public var falsePositiveCheck: Bool
    public var screenIs: Bool

    public init(enabled: Bool = true, heal: Bool = false,
                falsePositiveCheck: Bool = false, screenIs: Bool = true) {
        self.enabled = enabled
        self.heal = heal
        self.falsePositiveCheck = falsePositiveCheck
        self.screenIs = screenIs
    }
}

/// リモート実行の制御(docs/remote-runner.md §17)。ワークスペース(アプリのパッケージと
/// 資材を揃える共有ディレクトリ。中身の規約 apps/scripts/data は WorkspaceScaffold)の宣言。
/// run 前後のスクリプトはここでは宣言しない —— ワークスペースの `scripts/setup.sh` /
/// `scripts/teardown.sh` があれば実行される(`RunHookPlan`)。
/// 同期相手: vscode-ftester/schemas/run-profile.schema.json と拡張のプロファイルフォーム
public struct RemoteControlSection: Codable, Sendable, Equatable {
    /// ワークスペースのルート。絶対パス、または**リポジトリルート基準**の相対パス。
    /// appPath の解決基準には使わない(常にリポジトリルート基準のまま)——
    /// 実行時に appPath の原本をここ配下の `apps/<ファイル名>` へコピー(ステージング)し、
    /// インストールにはそちらを使う(`WorkspaceAppStaging`。docs/remote-runner.md §17)。
    /// **省略時の既定は `<project.rootURL>/workspace`**(2026-08-18。ワークスペースは常に有効
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
    /// 実行に使うデバイス(name 参照。iOS/Android 混在可 = 両OS同時実行)
    public var devices: [RunDeviceRef]?
    /// FM 機能を使用するか(既定 true)。false なら heal/偽陽性検証/screenIs/triage を一切呼ばない
    public var fm: Bool?
    /// FM によるロケータ自己修復を許可するか(既定 true)
    public var heal: Bool?
    /// 偽陽性検証(occlusion guard)を有効にするか(既定 false)
    public var falsePositiveCheck: Bool?
    /// screenIs(screenMatches)を有効にするか(既定 true。無効時は該当ステップを skip)
    public var screenIs: Bool?
    /// レポート出力先(プロジェクトルート相対 or 絶対。既定 "reports")
    public var reportDir: String?
    /// DSL コマンドの既定タイムアウト秒(小数可。省略時は DSL 側の既定値)
    public var defaultTimeout: Double?
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
    /// **テスト開始時に WebView を揃えるか**(既定 ON)。版が混在すると同じシナリオが
    /// 端末によって落ちる(124 は placeholder / 150 は #id と表現が入れ替わる)
    public var updateWebView: Bool?
    public var wipeDataThresholdGB: Double?
    /// 実行開始時に、画面凍結で CPU 描画(swiftshader)へフォールバック済みの Android エミュレータを
    /// GPU(-gpu host)で起動し直すか(既定 false=OFF)。GPU モードは emulator プロセスの起動引数で
    /// 決まるためプロセス再起動が必須で、該当機1台につき run 開始が約1分延びる。戻した先で再び凍結
    /// すればモニターの watchdog がまた CPU に落とす(design.md §12.4 のトレードオフ)。
    /// 同期相手: vscode-ftester/schemas/run-profile.schema.json と
    /// src/monitorModel.ts の RunProfileFormFields
    public var recoverCpuFallbackToGpu: Bool?
    /// Android エミュレータのブート完了時(Wipe Data 後の再起動を含む)にブリッジ /locale で
    /// 適用するロケール(既定 "ja_JP"。Play イメージでは -change-locale 等が無効なため。
    /// design.md §11.2)。iOS には影響しない。同期相手: vscode-ftester/schemas/run-profile.schema.json
    /// と src/monitorModel.ts の RunProfileFormFields
    public var locale: String?
    /// iOS xcuitest ブリッジの高速入力(quiescence 待ちスキップ)。true で FT_FAST_INPUT=1 を
    /// 実行環境に注入する(伝搬経路は BridgeClient.fastInput 参照)。動きの激しい画面では
    /// 整定前タップのフレークリスクを伴う(既定 false)
    public var iosFastInput: Bool?
    /// **容器の推測に依存する補正**を行うか(既定 true)。false にすると見切れ判定・掴み直し・
    /// 救済ドラッグ・見えている部分を撃つ座標補正・壊れた座標の候補除外が止まり、
    /// 推測を持たなかった頃の挙動へ戻る。**FM とは無関係**(幾何ヒューリスティック)。
    /// シナリオ側は `tap(..., containerInference:)` で1コマンド単位に上書きできる
    public var containerInference: Bool?
    /// テスト対象アプリのアニメーションを残すか(既定 false = 実行開始時に無効化する)。
    /// true で FT_ANIMATIONS=1 を実行環境に注入する(判定元は AnimationPolicy)。ON にすると
    /// 整定待ちが伸び、Android では静穏判定後もスクリーンショットが遷移途中の絵を掴みうる。
    /// 端末側の設定は run 開始時に毎回この値へ同期される(ブリッジ再利用でも効く)。
    /// 同期相手: vscode-ftester/schemas/run-profile.schema.json と
    /// src/monitorProfileForms.ts の RunProfileFormFields
    public var enableAnimations: Bool?
    /// run 開始時に各デバイスへ home() を1回撃つか(**既定 true**)。
    /// 一斉に launch した直後の端末は「描画要求が無いだけ」で画面が黒いまま止まることがあり、
    /// そのままだと凍結と見分けが付かない(2026-08-11 の実測: 黒かった5台のうち4台は入力で戻った)。
    /// 予防として1回だけ入力を入れる。**デバイスあたり1回**なので実行時間への影響はほぼゼロ。
    /// 同期相手: vscode-ftester/schemas/run-profile.schema.json と RunProfileFormFields
    public var homeOnStart: Bool?
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
    /// ワークスペース(ファイル同期)宣言。省略可(既定 = リポジトリルート基準の従来挙動)
    public var remoteControl: RemoteControlSection?

    public init(app: String? = nil, devices: [RunDeviceRef]? = nil, fm: Bool? = nil,
                heal: Bool? = nil, falsePositiveCheck: Bool? = nil, screenIs: Bool? = nil,
                reportDir: String? = nil, defaultTimeout: Double? = nil, scenarioTimeout: Int? = nil,
                machine: String? = nil, iosInappEngine: Bool? = nil,
                wipeDataOnBloat: Bool? = nil, updateWebView: Bool? = nil,
                wipeDataThresholdGB: Double? = nil,
                recoverCpuFallbackToGpu: Bool? = nil,
                locale: String? = nil, iosFastInput: Bool? = nil,
                containerInference: Bool? = nil,
                enableAnimations: Bool? = nil, homeOnStart: Bool? = nil, record: Bool? = nil,
                recordFailuresOnly: Bool? = nil, recordBitrateKbps: Int? = nil,
                recordFullResolution: Bool? = nil, remoteControl: RemoteControlSection? = nil) {
        self.app = app
        self.devices = devices
        self.fm = fm
        self.heal = heal
        self.falsePositiveCheck = falsePositiveCheck
        self.screenIs = screenIs
        self.reportDir = reportDir
        self.defaultTimeout = defaultTimeout
        self.scenarioTimeout = scenarioTimeout
        self.machine = machine
        self.iosInappEngine = iosInappEngine
        self.wipeDataOnBloat = wipeDataOnBloat
        self.updateWebView = updateWebView
        self.wipeDataThresholdGB = wipeDataThresholdGB
        self.recoverCpuFallbackToGpu = recoverCpuFallbackToGpu
        self.locale = locale
        self.iosFastInput = iosFastInput
        self.containerInference = containerInference
        self.enableAnimations = enableAnimations
        self.homeOnStart = homeOnStart
        self.record = record
        self.recordFailuresOnly = recordFailuresOnly
        self.recordBitrateKbps = recordBitrateKbps
        self.recordFullResolution = recordFullResolution
        self.remoteControl = remoteControl
    }

    static let knownKeys: Set<String> = [
        "app", "devices", "fm", "heal", "falsePositiveCheck", "screenIs",
        "reportDir", "defaultTimeout", "scenarioTimeout",
        "machine", "iosInappEngine", "wipeDataOnBloat", "updateWebView", "wipeDataThresholdGB",
        "recoverCpuFallbackToGpu", "locale",
        "iosFastInput", "enableAnimations", "homeOnStart", "containerInference",
        "record", "recordFailuresOnly", "recordBitrateKbps", "recordFullResolution", "remoteControl",
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
    /// アプリの原本の絶対パス(常にリポジトリルート基準で解決済み。nil = appPath 未指定。
    /// ワークスペースの宣言有無・既定/明示のどれでも基準は変わらない)。`WorkspaceAppStaging`
    /// がここを読んでワークスペースへコピーする。「原本が見つからない」系のエラーはこちらを
    /// 名指しする(インストール先を出しても何をビルドすればよいか分からないため)
    public let sourcePath: String?
    /// インストールに実際に使う絶対パス(nil = インストールしない)。**ワークスペースは常に
    /// 有効**(既定 `<project.rootURL>/workspace`。2026-08-18)なので sourcePath と同値になるのは
    /// appPath 自体が既にワークスペース配下を指している場合だけ。`WorkspaceAppStaging.installPath`
    /// が決める "<workspaceRoot>/apps/<原本のファイル名>"(ProfileResolver.resolve が唯一の生成元)。
    /// 呼び出し側(installApp・ProfileWorkerFactory 等)はこちらだけを見ればよい
    public let appPath: String?
    /// 実行前に appPath を自動インストールするか(既定 false = 無効。
    /// common セクションで明示的に true にした場合のみ有効)
    public let autoInstall: Bool
    /// バックエンド死活確認 URL(AppProfileSection.healthCheckURL)
    public let healthCheckURL: String?

    /// sourcePath 省略時は appPath と同値にする(ワークスペース非経由の既存呼び出しとの互換)
    public init(bundleID: String, sourcePath: String? = nil, appPath: String? = nil,
                autoInstall: Bool = false, healthCheckURL: String? = nil) {
        self.bundleID = bundleID
        self.sourcePath = sourcePath ?? appPath
        self.appPath = appPath
        self.autoInstall = autoInstall
        self.healthCheckURL = healthCheckURL
    }
}

/// 合成・検証済みの実行プロファイル。実行コードはこれだけを見る
public struct ResolvedProfile: Sendable {
    public let project: TestProject
    public let runName: String
    public let machineName: String
    /// マシンプロファイルの host(MachineHostDispatch.normalize 済み。nil = ローカル実行)。
    /// 表示用途(`ftester profile list`)。実際のディスパッチ判定・登録簿引きは呼び出し側
    /// (Sources/ftester/RemoteCommands.swift)が `--host` と突き合わせて行う。
    /// **`var` にする**(memberwise init を直に呼ぶ既存テスト
    /// (Tests/FTAndroidTests/BuildAndroidWorkersPartialFailureTests.swift 等)が
    /// この引数を知らないため既定値が要る。**既定値付きの `let` は memberwise init から
    /// 除外されて渡せなくなる** —— `var` なら既定引数として残る(RemoteRunDispatcher.mode と同じ罠)。
    /// 省略時 nil = ローカル扱いは仕様どおり)
    public var machineHost: String? = nil
    /// アプリの表示名(apps/<name>.json の appName。無ければファイル名)
    public let appName: String
    /// platform("ios"/"android")→ アプリ情報(デバイスがある platform のみ)
    public let apps: [String: ResolvedAppTarget]
    /// 実行に使うデバイス。**limitingDevices が本数に合わせて絞る**ので var
    public var devices: [ResolvedDevice]
    /// FM 機能の実効設定(RunProfileDocument の fm/heal/falsePositiveCheck/screenIs を合成)
    public let fm: FMConfig
    /// FM によるロケータ自己修復を許可するか(fm.heal のエイリアス。既存呼び出し互換のため維持)
    public var heal: Bool { fm.heal }
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
    /// 容器の推測に依存する補正(RunProfileDocument.containerInference。**既定 true**)
    public let containerInference: Bool
    /// アプリのアニメーションを残すか(RunProfileDocument.enableAnimations。既定 false=無効化)
    public let enableAnimations: Bool
    /// run 開始時に各デバイスへ home() を撃つか(RunProfileDocument.homeOnStart。**既定 true**)
    public let homeOnStart: Bool
    /// 各ワーカーを run 全体で録画し、シナリオごとに切り出すか(RunProfileDocument.record。既定 false)
    public let record: Bool
    /// 成功したシナリオのクリップを保存しないか(RunProfileDocument.recordFailuresOnly。既定 false)
    public let recordFailuresOnly: Bool
    /// クリップ再エンコードの目標 bitrate(kbps。RunProfileDocument.recordBitrateKbps。既定 1500)
    public let recordBitrateKbps: Int
    /// 半分解像度化をスキップするか(RunProfileDocument.recordFullResolution。既定 false)
    public let recordFullResolution: Bool
    /// **絶対パス解決済みのワークスペースルート**(remoteControl.workspace / `--workspace` 上書きの
    /// 実効値)。**常に非 nil**(2026-08-18。既定 `<project.rootURL>/workspace` —— ワークスペースは
    /// 常に有効。`ProfileResolver.resolveWorkspaceRoot`)。appPath の原本の解決基準はこれの
    /// 有無に関わらず常にリポジトリルート ―― `apps[platform].appPath`(インストール先)だけが
    /// この配下の `apps/<ファイル名>` に切り替わる(ステージングは WorkspaceAppStaging)。
    /// リモートディスパッチはこれがプロジェクトルート配下かどうかで転送経路を分ける
    /// (`WorkspaceRemoteDispatch.placement`。配下ならプロジェクト転送がそのまま運ぶので専用
    /// ミラーは不要。Sources/ftester/RemoteRunDispatcher.swift)。**`var` にする**(machineHost と
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

    /// `run --device` の絞り込み(ホスト別サブ実行が「自分のぶんのデバイス」だけを回すのに使う)。
    /// 空配列は「絞らない」。**1台も残らない指定は呼び出し側でエラーにする** ——
    /// ここで黙って全台に戻すと、名前を打ち間違えたときに意図しない台で走る
    /// ホスト別サブ実行のスコープ。**一意なのは name 単体ではなく (host, name)** なので、
    /// 名前だけで絞ると**別の機械の同名デバイスまで掴む**(フリートの各機は同じ命名規則で
    /// シミュレータを作るので、同名は例外ではなく通常。2026-08-17 に実走で確認 ——
    /// 手元のサブ実行が3機ぶんの "iPhone …-01" を全部拾って8台になった)。
    /// - deviceHost: そのサブ実行が担当する機械("local" / 登録名。nil = ホストで絞らない)
    public func filteringDevices(names: [String], deviceHost: String? = nil) -> ResolvedProfile {
        guard !names.isEmpty || deviceHost != nil else { return self }
        let wanted = Set(names)
        let wantedHost = MachineHostDispatch.normalize(deviceHost)
        var filtered = self
        filtered.devices = devices.filter { device in
            if !wanted.isEmpty, !wanted.contains(device.name) { return false }
            guard deviceHost != nil else { return true }
            return MachineHostDispatch.normalize(device.spec.host) == wantedHost
        }
        return filtered
    }

    public func limitingDevices(iosScenarios: Int, androidScenarios: Int) -> ResolvedProfile {
        func keep(_ list: [ResolvedDevice], _ count: Int) -> [ResolvedDevice] {
            Array(list.prefix(Self.deviceKeepCount(available: list.count, scenarios: count)))
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
        case .app: return "app"
        case .machine: return "machine"
        case .run: return "run"
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
    /// 同じ (host, name) が2つある。**別ホストの同名は重複ではない**(DeviceHostGrouping)
    case duplicateDeviceName(name: String, host: String?, machine: String)
    /// 実行プロファイルの参照が host を書いておらず、同名が複数ホストに居る
    case ambiguousDeviceRef(name: String, hosts: [String], run: String, machine: String)
    case noDevicesResolved(run: String, machine: String, requested: [String], available: [String])
    case missingBundleID(platform: String, appProfile: String)
    case invalidWipeDataThreshold(run: String)
    case invalidLocale(run: String)
    /// kind=physical なのに同定に必要な識別子(iOS=udid / Android=serial)が無い
    case physicalDeviceMissingIdentifier(name: String, platform: String, machine: String)
    /// kind=physical に dylib 注入エンジンが指定された(実機は注入不可)
    case physicalDeviceUnsupportedEngine(name: String, engine: String, machine: String)

    public var errorDescription: String? {
        switch self {
        case .runProfileNotFound(let name, let available):
            return "run profile not found: \(name)"
                + availableHint(available, empty: "profiles/runs/ is empty")
        case .appProfileNotFound(let name, let available):
            return "app profile not found: \(name)"
                + availableHint(available, empty: "profiles/apps/ is empty")
        case .machineProfileNotFound(let machine, let available):
            return "machine profile not found: \(machine)"
                + availableHint(available, empty: "profiles/machines/ is empty")
        case .runSpecifiedMachineNotFound(let run, let machine, let available):
            return "the machine profile \"\(machine)\" referenced by run profile \(run) was not found"
                + availableHint(available, empty: "profiles/machines/ is empty")
        case .machineUndetermined(let available):
            return "cannot tell which machine profile to use: the run profile does not set "
                + "\"machine\" and profiles/machines/ holds more than one. Add \"machine\": "
                + "\"<name>\" to the run profile (or set FT_MACHINE for a one-off run)"
                + availableHint(available, empty: "profiles/machines/ is empty")
        case .decodeFailed(let url, let detail):
            return "cannot load the profile: \(url.path)\n\(detail)"
        case .missingAppReference(let run):
            return "run profile \(run) has no \"app\" (a reference into apps/)"
        case .missingDevices(let run):
            return "run profile \(run) has no \"devices\""
        case .duplicateDeviceName(let name, let host, let machine):
            return "duplicate device name in machine profile \(machine): \(name)"
                + " on host \(DeviceHostGrouping.display(host))"
                + " (names must be unique per host, across ios and android)"
        case .ambiguousDeviceRef(let name, let hosts, let run, let machine):
            return "device \"\(name)\" in run profile \(run) is ambiguous on machine \(machine):"
                + " it exists on \(hosts.joined(separator: ", "))."
                + " Add \"host\" to the device entry in the run profile to say which one"
        case .noDevicesResolved(let run, let machine, let requested, let available):
            return "none of the devices in run profile \(run) resolve on machine \(machine)"
                + " (requested: \(requested.joined(separator: ", ")) / "
                + "defined: \(available.isEmpty ? "none" : available.joined(separator: ", ")))"
        case .missingBundleID(let platform, let appProfile):
            // common の app は廃止(merging 参照)のため、案内は platform セクション限定
            return "app profile \(appProfile) has no \"app\" (bundle ID / package name) for \(platform)"
                + " (add it in the \(platform) section)"
        case .invalidWipeDataThreshold(let run):
            return "wipeDataThresholdGB in run profile \(run) must be a positive number (GB)"
        case .invalidLocale(let run):
            return "locale in run profile \(run) must look like ja_JP"
        case .physicalDeviceMissingIdentifier(let name, let platform, let machine):
            let field = platform == "ios" ? "udid" : "serial"
            let how = platform == "ios"
                ? "the Identifier column of xcrun devicectl list devices, or the UDID"
                : "the left column of adb devices"
            return "device \"\(name)\" in machine profile \(machine) is kind=physical but has no "
                + "\"\(field)\" (set it to \(how))"
        case .physicalDeviceUnsupportedEngine(let name, let engine, let machine):
            return "device \"\(name)\" in machine profile \(machine) is kind=physical, so "
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
    /// 戻り値 auto = 自動採用だったか(呼び出し側がログ表示に使う。明示指定/FT_MACHINE は false)
    ///
    /// **「この Mac の登録名」は見ない**(2026-08-17 にユーザー決定で廃止)。登録名は
    /// 「複数ある machines/*.json のうちこの機械を表すのはどれか」を答えるためのものだったが、
    /// ①ツールが書く実行プロファイルには必ず machine が入る(42本中 machine 未指定は3本だった)
    /// ②デバイス側が host を持つようになり「どの機械のデバイスか」はプロファイル内で表現できる
    /// ——の2点で役目を終えた。残すと「マシンプロファイルを改名したらこの Mac の身元が変わる」
    /// (実際に project1 の解決が壊れた)ような、名前1つに2つの意味が載る構造が残る
    public static func determineMachine(
        project: TestProject,
        environment: [String: String] = ProcessInfo.processInfo.environment,
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
        let machines = machineNames(project: project)
        if machines.count == 1 { return (machines[0], true) }
        throw ProfileError.machineUndetermined(available: machines)
    }

    /// マシンプロファイルの `host` だけを読む(実行前のディスパッチ判定用)。フルの resolve() は
    /// デバイス解決まで行い重いので、host だけ知りたいホスト解決の前段はこちらを使う
    /// (Sources/ftester/RemoteCommands.swift の EffectiveHostDispatch 解決)。
    /// 戻り値は MachineHostDispatch.normalize 済み(nil = ローカル)
    public static func machineHost(project: TestProject, machineName: String) throws -> String? {
        let machineURL = project.machinesDir.appendingPathComponent("\(machineName).json")
        guard FileManager.default.fileExists(atPath: machineURL.path) else {
            throw ProfileError.machineProfileNotFound(
                machine: machineName, available: machineNames(project: project))
        }
        let data: Data
        do {
            data = try Data(contentsOf: machineURL)
        } catch {
            throw ProfileError.decodeFailed(machineURL, detail: error.localizedDescription)
        }
        do {
            let machine = try JSONDecoder().decode(MachineProfile.self, from: data)
            return MachineHostDispatch.normalize(machine.host)
        } catch {
            throw ProfileError.decodeFailed(machineURL, detail: "\(error)")
        }
    }

    /// 実行プロファイルが使うデバイスを「どの機械に居るか」付きで返す(ディスパッチ判定用。
    /// フルの resolve() はアプリ解決まで行い、host を決める前に落ちうるのでこちらを使う)。
    /// 解決できない参照は**黙って落とす** —— 警告と中止は resolve() が受け持ち、ここは
    /// 「実際に走るデバイスがどの機械にあるか」だけを答える。曖昧な参照だけは resolve() を
    /// 待たずに投げる(どのホストへ配るかがここで決まってしまうため)
    public static func runDeviceHosts(project: TestProject, runProfileName: String,
                                      machineName: String) throws -> [RunDeviceHost] {
        let runURL = project.runsDir.appendingPathComponent("\(runProfileName).json")
        guard let runData = try? Data(contentsOf: runURL),
              let runDoc = try? JSONDecoder().decode(RunProfileDocument.self, from: runData),
              let refs = runDoc.devices else {
            return []
        }
        let machineURL = project.machinesDir.appendingPathComponent("\(machineName).json")
        guard let machineData = try? Data(contentsOf: machineURL),
              let machine = try? JSONDecoder().decode(MachineProfile.self, from: machineData) else {
            return []
        }
        let entries = DeviceHostGrouping.entries(machine: machine)
        var result: [RunDeviceHost] = []
        for ref in refs {
            switch DeviceHostGrouping.resolve(ref, in: entries) {
            case .found(let entry):
                result.append(RunDeviceHost(host: entry.host, name: entry.name,
                                            platform: entry.platform))
            case .missing:
                continue
            case .ambiguous(let hosts):
                throw ProfileError.ambiguousDeviceRef(
                    name: ref.name, hosts: hosts, run: runProfileName, machine: machineName)
            }
        }
        return result
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

    /// runProfileName の実行プロファイルが宣言する `remoteControl.workspace`(trim 後非空)を返す。
    /// ファイルが無い/デコード不能/未宣言・空文字列なら nil。**マシン解決を必要としないので
    /// フルの resolve() を経由しない** —— リモートディスパッチ(Sources/ftester/
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
    /// 戻り値: platform("ios"/"android") → リポジトリルート基準で解決した原本の絶対パス
    /// (appPath 未指定の platform は含まない)。プロファイル/アプリ定義が読めなければ空を返す
    public static func declaredAppPaths(project: TestProject, runName: String) -> [String: String] {
        guard let runData = try? Data(
                contentsOf: project.runsDir.appendingPathComponent("\(runName).json")),
              let runDoc = try? JSONDecoder().decode(RunProfileDocument.self, from: runData),
              let appRef = runDoc.app else { return [:] }
        guard let appData = try? Data(
                contentsOf: project.appsDir.appendingPathComponent("\(appRef).json")),
              let appProfile = try? JSONDecoder().decode(AppProfile.self, from: appData) else { return [:] }
        let repoRoot = project.rootURL.deletingLastPathComponent().deletingLastPathComponent()
        var result: [String: String] = [:]
        for platform in ["ios", "android"] {
            if let raw = appProfile.section(for: platform).appPath {
                result[platform] = resolvePath(raw, base: repoRoot)
            }
        }
        return result
    }

    /// `remoteControl.workspace` 宣言と `--workspace` 上書きから実効の生値(未解決)を決める。
    /// override が非空なら常に勝つ(中継されたリモートの子はこれで自分のリポジトリルート基準を
    /// 上書きする)。両方無ければ nil(未宣言 = 従来どおりリポジトリルート基準)。
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
    /// **既定は `"<projectRoot>/workspace"`**(2026-08-18。常に非 nil を返す ——
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
                               machineName: String,
                               workspaceOverride: String? = nil) throws -> ResolvedProfile {
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
                + checkRemoteControlKeys(json, context: "runs/\(runName).json")
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

        // 一意なのは (host, name)。別ホストの同名は許す(DeviceHostGrouping にすべての規則がある)
        let catalogEntries = DeviceHostGrouping.entries(machine: machine)
        if let duplicate = DeviceHostGrouping.firstDuplicate(in: catalogEntries) {
            throw ProfileError.duplicateDeviceName(
                name: duplicate.name, host: duplicate.host, machine: machineName)
        }
        let catalogOrder = catalogEntries.map(\.name)

        // 4. デバイス解決(このマシンに無い name はスキップ+警告)。
        // iOS 実効エンジン: 実行プロファイルの iosInappEngine(既定 true)で決める。
        // true → "hybrid"(高速な in-app 主+XCUITest フォールバック)、false → "xcuitest"。
        // ただしマシンプロファイルでデバイスに engine を明示していればそちらが優先(上書きしない)。
        let iosEngine = (runDoc.iosInappEngine ?? true) ? "hybrid" : "xcuitest"
        var devices: [ResolvedDevice] = []
        for ref in deviceRefs {
            switch DeviceHostGrouping.resolve(ref, in: catalogEntries) {
            case .ambiguous(let hosts):
                // 片方を黙って選ぶと「別の機械のデバイスを操作した」になる。候補を挙げて止める
                throw ProfileError.ambiguousDeviceRef(
                    name: ref.name, hosts: hosts, run: runName, machine: machineName)
            case .found(let entry):
                // 実体の無い登録は走る前に言う(iOS は既定名へ落ちて別の台で黙って走る)。
                // 止めはしない —— 既定に頼っている既存プロファイルを赤にしない
                if entry.spec.lacksConcreteTarget {
                    warnings.append(
                        "device \"\(ref.name)\" on machine \(machineName) has no concrete target"
                        + " (ios: simulator/udid, android: avd/serial)"
                        + " — re-run `ftester profile setup --auto-device`,"
                        + " or fill it in in profiles/machines/\(machineName).json")
                }
                let device = ResolvedDevice(platform: entry.platform, spec: entry.spec)
                try validatePhysical(device, machine: machineName)
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
                            "device \"\(ref.name)\" explicitly sets engine=\(explicit) in the machine profile, "
                            + "so the iosInappEngine setting does not apply to it")
                    }
                    devices.append(device)
                }
            case .missing:
                let onHost = ref.host.map { " on host \($0)" } ?? ""
                warnings.append(
                    "device \"\(ref.name)\"\(onHost) is not defined on machine \(machineName)"
                    + " — skipping it")
            }
        }
        guard !devices.isEmpty else {
            throw ProfileError.noDevicesResolved(
                run: runName, machine: machineName,
                requested: deviceRefs.map(\.name), available: catalogOrder)
        }

        // 5. アプリ解決(デバイスのある platform ごと。合成規則は AppProfileSection.merging 参照)
        // appPath の相対パスは常に「リポジトリルート」基準(project.rootURL =
        // <repoRoot>/TestProjects/<name> の2階層上。= アプリの原本の場所)。**ワークスペースの
        // 有無・既定/明示のどれでもこの基準は変えない**(以前は宣言時にワークスペース基準へ
        // 切り替えていたが、原本の置き場所とインストールに使う場所を混同していた。
        // docs/remote-runner.md §17)。packageRoot() の CWD 走査は使わない(単体テストでは CWD が
        // 本体リポジトリを指し誤基準になる。project.rootURL からの決定的導出で統一)。
        // reportDir だけはプロジェクト直下に出すため下記で project.rootURL 基準のまま
        // (基準が異なるので resolvePath の base で使い分ける)。
        //
        // **ワークスペースは常に有効**(既定 `"<project.rootURL>/workspace"`。2026-08-18)。
        // インストールに使うパス(ResolvedAppTarget.appPath)は常に
        // "<workspaceRoot>/apps/<原本のファイル名>" に切り替わる(原本の
        // ResolvedAppTarget.sourcePath は常にリポジトリルート基準のまま)。実体のコピー(ステージング)
        // はここでは行わない(純粋な path 計算のみ) —— 呼び出し側(ProfileRunner.run/ApiRunCommand/
        // RemoteRunDispatcher)が resolve() 直後に `WorkspaceAppStaging` を呼んで原本を運ぶ。
        // リモートへディスパッチすると appPath のアプリパッケージ自体は転送されない
        // (RemoteTransferPlan.rsyncArgs は TestProjects/<project> しか rsync しない)ため、
        // リポジトリルート基準の絶対パスはリモートに存在しない。既定のワークスペースは
        // project.rootURL 配下なので、その転送(rsyncArgs)自体がステージング済みの apps/ を
        // 運ぶ ―― 明示指定でプロジェクト外を指したときだけ専用ミラーが要る
        // (`WorkspaceRemoteDispatch.placement`。Sources/ftester/RemoteRunDispatcher.swift)
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
            let installPath = sourcePath.map { source in
                WorkspaceAppStaging.installPath(source: source, workspaceRoot: workspaceRoot)
            }
            apps[platform] = ResolvedAppTarget(
                bundleID: bundleID,
                sourcePath: sourcePath,
                appPath: installPath,
                // **appPath があれば既定で有効**。パスを書いたのに入らない(既定 false)方が
                // 事故で、警告を出さないと気付けない設計だった。止めたいときだけ
                // autoInstall: false を明示する(opt-out)。実インストールは中身が変わったときだけ
                autoInstall: section.autoInstall ?? (section.appPath != nil),
                healthCheckURL: section.healthCheckURL)
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

        // fm:false は他の3フラグを無条件に false へ落とす(利用側は個別フラグだけ見ればよい契約。
        // FMConfig の doc コメント参照)
        let fmEnabled = runDoc.fm ?? true
        let fm = FMConfig(
            enabled: fmEnabled,
            heal: fmEnabled && (runDoc.heal ?? true),
            falsePositiveCheck: fmEnabled && (runDoc.falsePositiveCheck ?? false),
            screenIs: fmEnabled && (runDoc.screenIs ?? true))

        return ResolvedProfile(
            project: project,
            runName: runName,
            machineName: machineName,
            machineHost: MachineHostDispatch.normalize(machine.host),
            appName: appProfile.resolvedAppName ?? appRef,
            apps: apps,
            devices: devices,
            fm: fm,
            reportDir: reportDir,
            defaultTimeout: runDoc.defaultTimeout,
            scenarioTimeout: runDoc.scenarioTimeout,
            wipeDataOnBloat: runDoc.wipeDataOnBloat ?? true,
            updateWebView: runDoc.updateWebView ?? true,
            wipeDataThresholdGB: wipeDataThresholdGB,
            recoverCpuFallbackToGpu: runDoc.recoverCpuFallbackToGpu ?? false,
            locale: locale,
            iosFastInput: runDoc.iosFastInput ?? false,
            containerInference: runDoc.containerInference ?? true,
            enableAnimations: runDoc.enableAnimations ?? false,
            homeOnStart: runDoc.homeOnStart ?? true,
            record: runDoc.record ?? false,
            recordFailuresOnly: runDoc.recordFailuresOnly ?? false,
            // 0 以下は無意味な指定なので既定にフォールバック(run を止めるほどの問題ではない)
            recordBitrateKbps: (runDoc.recordBitrateKbps).map { $0 > 0 ? $0 : 1500 } ?? 1500,
            recordFullResolution: runDoc.recordFullResolution ?? false,
            workspaceRoot: workspaceRoot,
            setupHook: setupHook,
            teardownHook: teardownHook,
            warnings: warnings)
    }

    /// 実機デバイスの整合検査。実行プロファイルから参照されたデバイスにのみ適用する
    /// (マシンプロファイル全体に掛けると、無関係なデバイス定義の不備で run が止まる)
    private static func validatePhysical(_ device: ResolvedDevice, machine: String) throws {
        guard device.spec.isPhysical else { return }
        let identifier = device.platform == "ios" ? device.spec.udid : device.spec.serial
        guard let identifier, !identifier.trimmingCharacters(in: .whitespaces).isEmpty else {
            throw ProfileError.physicalDeviceMissingIdentifier(
                name: device.name, platform: device.platform, machine: machine)
        }
        if device.platform == "ios", let engine = device.spec.engine,
           engine != "xcuitest" {
            throw ProfileError.physicalDeviceUnsupportedEngine(
                name: device.name, engine: engine, machine: machine)
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

    // MARK: - 単一ファイル検証(プロファイルエディタ用)

    /// プロファイルファイル 1 つの検証。戻り値: (エラー, 警告)。
    /// エラー = デコード不能・必須欠落・name 重複、警告 = 未知キー(タイポ検出)。
    /// project は .run の machine フィールド検証(参照先の machines/ 存在チェック)にのみ使う
    public static func validate(
        kind: ProfileFileKind, data: Data, context: String, project: TestProject
    ) -> (errors: [String], warnings: [String]) {
        guard let json = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else {
            return (["cannot parse as JSON (syntax error)"], [])
        }
        var errors: [String] = []
        var warnings: [String] = []
        let decoder = JSONDecoder()
        switch kind {
        case .app:
            if (try? decoder.decode(AppProfile.self, from: data)) == nil {
                errors.append("cannot load as an app profile (type mismatch)")
            }
            warnings += checkAppProfileKeys(json, context: context)
            warnings += checkDeprecatedSectionKeys(json, context: context)
        case .machine:
            if let machine = try? decoder.decode(MachineProfile.self, from: data) {
                // **一意なのは (host, name)**(別の機械の同名は重複ではない)。判定は
                // DeviceHostGrouping で resolve() と共有する —— 片方だけ厳しいと
                // 「保存できるのに検証が赤い」(その逆も)になる
                if let duplicate = DeviceHostGrouping.firstDuplicate(
                    in: DeviceHostGrouping.entries(machine: machine)) {
                    errors.append("duplicate device name: \(duplicate.name)"
                                  + " on host \(DeviceHostGrouping.display(duplicate.host))"
                                  + " (names must be unique per host, across ios and android)")
                }
                for (platform, list) in [("ios", machine.ios), ("android", machine.android)] {
                    for spec in list?.devices ?? [] {
                        errors += physicalDeviceErrors(spec, platform: platform)
                    }
                }
            } else {
                errors.append("cannot load as a machine profile (type mismatch)")
            }
            warnings += checkMachineProfileKeys(json, context: context)
        case .run:
            if let doc = try? decoder.decode(RunProfileDocument.self, from: data) {
                if doc.app == nil { errors.append("no \"app\" (a reference into apps/)") }
                if (doc.devices ?? []).isEmpty { errors.append("no \"devices\"") }
                if let threshold = doc.wipeDataThresholdGB, threshold <= 0 {
                    errors.append("\"wipeDataThresholdGB\" must be a positive number (GB)")
                }
                let locale = (doc.locale ?? "ja_JP").trimmingCharacters(in: .whitespacesAndNewlines)
                if !isValidLocale(locale) {
                    errors.append("\"locale\" must look like ja_JP")
                }
            } else {
                errors.append("cannot load as a run profile (type mismatch)")
            }
            warnings += checkKeys(json, allowed: RunProfileDocument.knownKeys, context: context)
            warnings += checkDeviceRefKeys(json, context: context)
            warnings += checkRemoteControlKeys(json, context: context)
            let (machineErrors, machineWarnings) = checkRunMachineField(json, project: project)
            errors += machineErrors
            warnings += machineWarnings
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

    private static func checkDeviceRefKeys(_ json: [String: Any], context: String) -> [String] {
        guard let devices = json["devices"] as? [[String: Any]] else { return [] }
        return devices.flatMap {
            checkKeys($0, allowed: RunDeviceRef.knownKeys, context: "\(context) devices")
        }
    }

    private static func checkRemoteControlKeys(_ json: [String: Any], context: String) -> [String] {
        guard let section = json["remoteControl"] as? [String: Any] else { return [] }
        return checkKeys(section, allowed: RemoteControlSection.knownKeys, context: "\(context) remoteControl")
    }

    /// 実行プロファイルの machine フィールドの検証(型・参照先の存在・未指定)。
    /// - 存在して string 型でない(JSON null は「未指定」と同義に扱う) → エラー
    /// - 非空文字列だが machines/<machine>.json が無い → エラー(明示指定なので明確に伝える)
    /// - 未指定/空文字列 → 警告(既存プロファイルを壊さないための後方互換。エラーにはしない)
    private static func checkRunMachineField(
        _ json: [String: Any], project: TestProject
    ) -> (errors: [String], warnings: [String]) {
        let unspecifiedWarning = "machine is not specified (explicitly naming the machine profile is recommended)"
        guard let raw = json["machine"], !(raw is NSNull) else {
            return ([], [unspecifiedWarning])
        }
        guard let machineName = raw as? String else {
            return (["\"machine\" must be a string"], [])
        }
        let trimmed = machineName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            return ([], [unspecifiedWarning])
        }
        guard machineNames(project: project).contains(trimmed) else {
            return (["the machine profile \"\(trimmed)\" referenced by \"machine\" was not found"], [])
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
            ("common", "appName", "ios/android", " (the display name)"),
            ("ios", "autoInstall", "common", " (enabled by default when appPath is set)"),
            ("android", "autoInstall", "common", " (enabled by default when appPath is set)"),
        ]
        return rules.compactMap { rule in
            guard let section = json[rule.section] as? [String: Any],
                  section[rule.key] != nil else { return nil }
            return "\(context) \(rule.section): \"\(rule.key)\" is deprecated."
                + " Specify it in the \(rule.moveTo) section instead\(rule.hint)"
        }
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
