// ScenarioSandbox.swift
// シナリオ実行バイナリ(`fleetest-scenarios-<project>`)を**常に** macOS の Seatbelt(`sandbox-exec`)で包む
// (外せるのはマシン側の `sandbox.disabled` だけ。プロジェクト・環境変数からは緩められない)。縛るのは
// **この子とその子孫だけ**で、fleetest 本体(供給・ビルド・モニター)は包まない。包む入口は
// `ScenarioHost.sandboxedLaunch` の1箇所(`ScenarioSandboxWiringTests`)。
//
// **全拒否が土台**(`(deny default)`)。全許可を土台にすると、書き込みと通信を絞っても
// LaunchServices(`open -a`)や CoreSimulator(`simctl spawn`)経由で枠の外にプロセスを起こせる
// (どちらも実測)。Simulator の操作は親の `SandboxBroker` が代行する。
// 規則の形・残る抜け道・書式の罠は docs/design.md §11.7。
import Foundation

public enum ScenarioSandbox {
    static let sandboxExecPath = "/usr/bin/sandbox-exec"

    static let notice = "🔒 sandbox: this scenario runs inside Seatbelt — on this Mac it can write"
        + " only under the report directory, .fleetest and temporary directories, cannot read credential"
        + " stores, and connects only to this machine (and allowedDomains through the proxy)"

    /// プロファイルを組み立てる入力。**パスは解決前でよい**(`profile` が実体パスへ直す)
    public struct Scope: Sendable, Equatable {
        /// 一覧取得のようにレポートを書かない起動では nil
        public var reportDir: String?
        /// 親が決めて子に書かせる場所(静止画の置き場 `--still-frames-dir`)。**環境変数から作らない**
        public var extraWritable: [String] = []
        /// 読ませない場所(実体に直す前のパス)。`defaultDenyRead` + マシン側の `denyRead`
        public var denyRead: [String]
        /// テストプロジェクトのルート(`<project>/.fleetest` = 指紋・セレクタ棚卸し・学習済みモデル)
        public var projectRoot: String
        /// `<root>/.fleetest` に台帳を置くルート。シナリオのパッケージ(受け手なら WORK_DIR)と
        /// ツール本体のルートで、clone 構成では同じ1つ・外部パッケージ構成では別々になる
        /// (ブリッジの台帳は `RepoRoot.find()` = ツール本体側に書かれる)
        public var stateRoots: [String]
        public var home: String
        /// ユーザーごとの一時・キャッシュ領域のうち子専用のもの(`childTemporaryDirectory` / `childCacheDirectory`)
        public var userTempRoots: [String]
        /// シナリオ実行バイナリの名前。Vision / Core ML のコンパイルキャッシュが
        /// `~/Library/Caches/<名前>/` に置かれる
        public var runnerName: String
        /// localhost 以外のブリッジへ繋ぐときのポート(実機を LAN 越しに駆動するとき)。
        /// Seatbelt のアドレス条件はホストに `*` か `localhost` しか書けないので、ポートで絞る
        public var remoteBridgePorts: [UInt16]
        /// 親の `SandboxBroker` のソケット(Simulator の操作を頼む口)。一覧取得のように
        /// デバイスを駆動しない起動では nil
        public var brokerSocket: String?
        /// 他に繋がせる unix ソケット(画像判定の補助プロセス `VisionHelperHost`)。**名指しで開ける**
        /// (パス無しの `(remote unix-socket)` は Docker 等の強い口まで開く)。閉じたままだと Vision の異常を
        /// 救えず、ANE が壊れた機械で画像照合と分類器が落ちる(connect が EPERM。拒否ログには出なかった)
        public var helperSockets: [String] = []
        /// adb サーバと Emulator のポートを閉じないか(`MachineSettings.allowDirectAdb`)
        public var allowDirectAdb = false
        /// レーンの Simulator の UDID。あればデータコンテナの書き込みをこの1台に絞る。nil = 全 Simulator
        /// (ポートだけを指定した run では親に UDID が分からない)
        public var simulatorUDID: String?
        /// 許可ドメインへプロキシ経由で出るか(`allowedDomains` が空でないとき)。TLS の証明書の検証に
        /// 要るサービスを開ける
        public var usesProxy = false

        public init(reportDir: String?, denyRead: [String], projectRoot: String, stateRoots: [String],
                    home: String,
                    userTempRoots: [String], runnerName: String, remoteBridgePorts: [UInt16]) {
            self.reportDir = reportDir
            self.denyRead = denyRead
            self.projectRoot = projectRoot
            self.stateRoots = stateRoots
            self.home = home
            self.userTempRoots = userTempRoots
            self.runnerName = runnerName
            self.remoteBridgePorts = remoteBridgePorts
        }
    }

    /// マシン側の設定(`~/.config/fleetest/config.json` の `sandbox`)。**プロジェクトの中には置かない** ——
    /// プロジェクトはエージェントが書き換えられるので、そこに緩める口があると壁にならない。
    /// どの欄も省略でき、省略 = 既定(有効・追加の拒否なし・外部通信なし)
    public struct MachineSettings: Codable, Sendable, Equatable {
        /// true でこの機械のシナリオを包まない(壁が要らない環境のための逃げ道)
        public var disabled: Bool?
        /// 内蔵の `defaultDenyRead` に**足す**読ませない場所(置き換えない)。`~` を受ける
        public var denyRead: [String]?
        /// プロキシ経由で通す宛先(`example.com` / `*.example.com`)。省略・空 = 外部へは一切出られない
        public var allowedDomains: [String]?
        /// true でシナリオが adb / bundletool を親に頼まず自分で使う(adb サーバと Emulator のポート・
        /// `~/.android` を開ける)。**Emulator の中 = 枠の外から外部へ出られ、繋がった全 Android 端末に届く**ので
        /// 既定は閉じる。マシン側の設定だけで開ける(プロジェクト・環境変数からは開けない)
        public var allowDirectAdb: Bool?

        static let knownKeys: Set<String> = ["disabled", "denyRead", "allowedDomains", "allowDirectAdb"]

        public init(disabled: Bool? = nil, denyRead: [String]? = nil, allowedDomains: [String]? = nil,
                    allowDirectAdb: Bool? = nil) {
            self.disabled = disabled
            self.denyRead = denyRead
            self.allowedDomains = allowedDomains
            self.allowDirectAdb = allowDirectAdb
        }
    }

    /// 解決済み(包むと決まったときの中身)
    public struct Plan: Sendable, Equatable {
        public var denyRead: [String]
        public var allowedDomains: [String]
        public var allowDirectAdb: Bool = false
    }

    public enum ConfigError: Error, LocalizedError, Equatable {
        case unreadable(String, detail: String)
        case unknownKeys(String, keys: [String])
        case invalidDomain(String, pattern: String)
        case redirectOutsideSandbox(key: String, path: String)

        public var errorDescription: String? {
            switch self {
            case .unreadable(let path, let detail):
                return "sandbox settings in \(path) cannot be read: \(detail)"
            case .unknownKeys(let path, let keys):
                return "sandbox settings in \(path) have unknown key(s): \(keys.joined(separator: ", "))"
                    + " (known: \(MachineSettings.knownKeys.sorted().joined(separator: ", ")))"
            case .invalidDomain(let path, let pattern):
                return "sandbox settings in \(path): \(pattern.debugDescription) is not a valid"
                    + " allowedDomains entry (write a host name such as api.example.com or *.example.com, optionally with one port such as api.example.com:443)"
            case .redirectOutsideSandbox(let key, let path):
                return "\(key)=\(path) points outside the locations a sandboxed scenario may write"
                    + " (the scenario's .fleetest, the report directory, or this user's temporary directory)"
                    + " — unset it or point it inside one of them"
            }
        }
    }

    /// 実ホーム(パスワードデータベースの値)。**`HOME` を見ない** —— 差し替えられると読ませない場所
    /// (`~/.ssh` 等)が偽のホームの下に組まれ、本物が読める
    public static func realHome() -> String {
        if let entry = getpwuid(getuid()), let dir = entry.pointee.pw_dir {
            let path = String(cString: dir)
            if !path.isEmpty { return path }
        }
        return NSHomeDirectoryForUser(NSUserName()) ?? FileManager.default.homeDirectoryForCurrentUser.path
    }

    /// マシン側の設定の場所。`LocalConfig.url` と違い `XDG_CONFIG_HOME` を見ない(理由は `LocalConfig.sandbox`)
    public static func machineSettingsURL(home: String = realHome()) -> URL {
        URL(fileURLWithPath: home).appendingPathComponent(".config/fleetest/config.json")
    }

    /// マシン側の設定を読む。ファイルが無い・`sandbox` 欄が無い = 既定。
    /// **壊れている・未知のキーがあるときは投げる**(綴りを誤った `denyRead` を黙って無視すると、
    /// 読ませないつもりの場所が読める。`LocalConfig.load` の「壊れていたら空設定」には倒さない)
    public static func machineSettings(url: URL = machineSettingsURL()) throws -> MachineSettings {
        guard FileManager.default.fileExists(atPath: url.path) else { return MachineSettings() }
        do {
            let data = try Data(contentsOf: url)
            guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
                throw ConfigError.unreadable(url.path, detail: "not a JSON object")
            }
            guard let section = json["sandbox"] else { return MachineSettings() }
            guard let object = section as? [String: Any] else {
                throw ConfigError.unreadable(url.path, detail: "\"sandbox\" is not an object")
            }
            let unknown = object.keys.filter { !MachineSettings.knownKeys.contains($0) }.sorted()
            guard unknown.isEmpty else { throw ConfigError.unknownKeys(url.path, keys: unknown) }
            return try JSONDecoder().decode(
                MachineSettings.self, from: JSONSerialization.data(withJSONObject: object))
        } catch let error as ConfigError {
            throw error
        } catch {
            throw ConfigError.unreadable(url.path, detail: "\(error)")
        }
    }

    /// 包むかどうかと中身を決める唯一の箇所。nil = 包まない(マシン側で `disabled: true` のときだけ)
    public static func plan(settings: MachineSettings, home: String = realHome(),
                            source: String = machineSettingsURL().path) throws -> Plan? {
        guard settings.disabled != true else { return nil }
        let domains = settings.allowedDomains ?? []
        if let bad = domains.first(where: { !SandboxDomainPolicy.isValidPattern($0) }) {
            throw ConfigError.invalidDomain(source, pattern: bad)
        }
        let extra = (settings.denyRead ?? []).map { expandTilde($0, home: home) }
        let direct = settings.allowDirectAdb == true
        let adbKeys = direct ? [] : adbDenyReadHomeSubpaths.map { home + "/" + $0 }
        return Plan(denyRead: defaultDenyRead(home: home) + adbKeys + extra, allowedDomains: domains,
                    allowDirectAdb: direct)
    }

    static func expandTilde(_ path: String, home: String) -> String {
        if path == "~" { return home }
        if path.hasPrefix("~/") { return home + "/" + path.dropFirst(2) }
        return path
    }

    public enum ProfileError: Error, LocalizedError, Equatable {
        case unrepresentablePath(String)
        case symlinkedWritableRoot(String)

        public var errorDescription: String? {
            switch self {
            case .unrepresentablePath(let path):
                return "sandbox: cannot write a Seatbelt rule for a path that contains a control"
                    + " character: \(path.debugDescription)"
            case .symlinkedWritableRoot(let path):
                return "sandbox: \(path) is a symbolic link — a scenario may write under it, and a link would"
                    + " let it write wherever the link points. Replace it with a real directory"
            }
        }
    }

    /// この Mac の実行時の値から `Scope` を作る(`ScenarioHost.run` 用)
    static func scope(project: TestProject, plan: Plan, reportDir: String?, extraWritable: [String] = [],
                      packageRoot: URL?, runner: URL, connection: DriverConnection?,
                      environment: [String: String] = ProcessInfo.processInfo.environment,
                      home: String = realHome()) throws -> Scope {
        var scope = Scope(
            reportDir: reportDir,
            denyRead: plan.denyRead,
            projectRoot: project.rootURL.path,
            stateRoots: stateRoots(packageRoot: packageRoot, environment: environment,
                                   executable: Bundle.main.executableURL),
            home: home,
            userTempRoots: [childTemporaryDirectory(runnerName: runner.lastPathComponent),
                            childCacheDirectory(runnerName: runner.lastPathComponent)].compactMap { $0 },
            runnerName: runner.lastPathComponent,
            remoteBridgePorts: connection.map(remoteBridgePorts) ?? [])
        scope.extraWritable = extraWritable
        scope.allowDirectAdb = plan.allowDirectAdb
        scope.simulatorUDID = simulatorUDID(connection)
        try checkRedirects(scope, environment: environment)
        return scope
    }

    /// Simulator のレーンの UDID。UUID の形でなければ nil(正規表現へ埋めるので形を検める)
    static func simulatorUDID(_ connection: DriverConnection?) -> String? {
        guard let connection, connection.platform == "ios", !connection.physical,
              let udid = connection.udid, UUID(uuidString: udid) != nil else { return nil }
        return udid
    }

    /// 親の環境のうち子へ渡すもの(許可リスト)。**親の環境を丸ごと継がせない** —— `.mcp.json` の `env` や
    /// シェルのトークン(`GITHUB_TOKEN` 等)をシナリオが読み、UI 操作でデバイスへ持ち出せる。
    /// 子が読む鍵は `FT_*` とこの一覧(Sources の `environment["…"]` / `getenv` を棚卸しした結果)。
    /// 子が読む鍵を足したらここにも足す(足し忘れると子では未設定に見える)。設定の場所を差し替える鍵は渡さない
    /// (子が読めるのは実ホームの `~/.config/fleetest` だけ = `readReopenedHomeSubpaths`)
    static let inheritedEnvironmentKeys: Set<String> = [
        "PATH", "HOME", "USER", "LOGNAME", "SHELL", "TERM", "LANG", "__CF_USER_TEXT_ENCODING",
        "DEVELOPER_DIR", "JAVA_HOME", "SSH_CONNECTION", "SSH_TTY",
        "ANDROID_HOME", "ANDROID_SDK_ROOT", "ANDROID_AVD_HOME", "ANDROID_ADB_SERVER_PORT",
    ]
    static let inheritedEnvironmentPrefixes = ["FT_", "LC_"]

    static func inheritedEnvironment(_ parent: [String: String]) -> [String: String] {
        parent.filter { key, _ in
            inheritedEnvironmentKeys.contains(key) || inheritedEnvironmentPrefixes.contains { key.hasPrefix($0) }
        }
    }

    /// 子は親の環境を継ぐので、これらが立っていると既定の置き場ではなくここへ書く
    static let redirectedDirectoryKeys = [
        "FT_OCCLUSION_DUMP_DIR", "FT_OCCLUSION_CORPUS_DIR", "FT_FM_LIVENESS_DIR",
        "FT_FM_USAGE_DIR", "FT_VISION_USAGE_DIR", "FT_APP_FRAMEWORK_DIR", "FT_OCR_COMPILE_DIR",
    ]

    /// 差し替えた置き場は**書ける場所の中にあるときだけ**通す。書ける場所へ足す形にしない ——
    /// 環境変数は `.mcp.json` やコマンド行から差し替えられるので、足すと任意の場所(`~/Library/LaunchAgents` 等)を
    /// 書けるようにできる。外を指すなら起こさずに止める(黙って書けずに効かなくなるより先に気づかせる)
    static func checkRedirects(_ scope: Scope, environment: [String: String]) throws {
        let roots = writablePaths(scope).map(canonicalPath)
        for key in redirectedDirectoryKeys {
            guard let raw = environment[key], !raw.isEmpty else { continue }
            let real = canonicalPath(expandTilde(raw, home: scope.home))
            guard roots.contains(where: { real == $0 || real.hasPrefix($0 + "/") }) else {
                throw ConfigError.redirectOutsideSandbox(key: key, path: raw)
            }
        }
    }

    /// 子の `TMPDIR` = ユーザーの一時領域の中の子専用のフォルダ(`T/fleetest-sandbox/<実行バイナリ名>/`)。
    /// **親の値を継がせない**(差し替えられた `TMPDIR` を書ける場所に足すと、上と同じ穴になる)。
    /// **一時領域そのもの(T・C・0・X)は開けない** —— 他のツールが信じて読むもの(xcrun のツール位置キャッシュ
    /// `T/xcrun_db`・clang のモジュールキャッシュ `C/clang`・VSCode のシェル統合)を書き換えられる。
    /// 子のコードは `TemporaryDirectory.url` で `TMPDIR` を読む(`NSTemporaryDirectory()` は `TMPDIR` を見ない)
    static func childTemporaryDirectory(runnerName: String) -> String? {
        darwinUserDirectory(_CS_DARWIN_USER_TEMP_DIR).map { $0 + "fleetest-sandbox/" + runnerName + "/" }
    }

    /// 子の実行バイナリのキャッシュ(`C/<実行バイナリ名>/`)。Metal のシェーダ等はプロセス名のフォルダに置かれる
    static func childCacheDirectory(runnerName: String) -> String? {
        darwinUserDirectory(_CS_DARWIN_USER_CACHE_DIR).map { $0 + runnerName }
    }

    /// Foundation が atomic な書き込み・置き換えに使う作業フォルダ(`T/TemporaryItems/NSIRD_<プロセス名>_…`。正規表現)。
    /// `NSTemporaryDirectory()` と同じく `TMPDIR` を見ないので子専用の一時フォルダの外に作られ、閉じると黙って別の経路へ
    /// 縮退する(拒否ログで実測)。名前にプロセス名と `_` が入るので、この子のぶんだけに当たる。
    /// **Metal のシェーダキャッシュ(`C/com.apple.metal/`)は開けない** —— ユーザー全体で共有され、閉じても所要は変わらなかった
    static func childReplacementDirectoryRegex(runnerName: String) throws -> String? {
        guard let temp = darwinUserDirectory(_CS_DARWIN_USER_TEMP_DIR) else { return nil }
        return "^" + (try regexEscapedPath(canonicalPath(temp))) + "/TemporaryItems/NSIRD_"
            + NSRegularExpression.escapedPattern(for: runnerName) + "_"
    }

    /// Seatbelt の `#"…"` に埋める実体パス(`"` と制御文字を断る)
    private static func regexEscapedPath(_ real: String) throws -> String {
        guard !real.contains("\""),
              !real.unicodeScalars.contains(where: { $0.value < 0x20 || $0.value == 0x7F }) else {
            throw ProfileError.unrepresentablePath(real)
        }
        return NSRegularExpression.escapedPattern(for: real)
    }

    /// Core ML がコンパイルしたモデルの置き場(`T/model_<UUID>.mlmodelc`。正規表現)。`MLModel.compileModel` は
    /// `TMPDIR` を見ずにここへ置くので、閉じると分類器(checkIsON/OFF・imageIs)が「“model.mlmodelc” couldn’t be moved」で
    /// 使えなくなる(実測: a11y で読めない部品の checkIsON が赤・読める部品は黙って a11y へ倒れた)。
    /// 名前にプロセス名が入らないので、他のプロセスの `model_*.mlmodelc` にも当たる(Core ML 以外が信じて実行する物ではない)
    /// Create ML の学習の出力先 `T/CreateMLModels/` も同じ(`MLImageClassifier` が `TMPDIR` を見ずに書く)。
    /// 閉じると見本からの学習が「You don’t have permission to save … in the folder “CreateMLModels”」で失敗する
    /// (学習済みのキャッシュが無い作業ツリー = 受け手が初めて見本を置いたときにだけ通る経路。実測)
    static func compiledModelRegex() throws -> String? {
        guard let temp = darwinUserDirectory(_CS_DARWIN_USER_TEMP_DIR) else { return nil }
        return "^" + (try regexEscapedPath(canonicalPath(temp)))
            + "/(model_[^/]*\\.mlmodelc|CreateMLModels)(/|$)"
    }

    /// 子が書ける正規表現の場所(データコンテナ・Foundation の作業フォルダ・Core ML のコンパイル先)。
    /// broker の「子が書ける場所からの install を断る」判定にも同じ集合を使う
    static func childWritableRegexes(_ scope: Scope, containerUDID: String?) throws -> [String] {
        [try simulatorDataContainerRegex(home: scope.home, udid: containerUDID)]
            + [try childReplacementDirectoryRegex(runnerName: scope.runnerName), try compiledModelRegex()].compactMap { $0 }
    }

    /// `confstr` のユーザーごとの領域(末尾 `/` 付き)。取れなければ nil
    private static func darwinUserDirectory(_ name: Int32) -> String? {
        var buffer = [CChar](repeating: 0, count: Int(PATH_MAX))
        guard confstr(name, &buffer, buffer.count) > 0 else { return nil }
        let dir = String(decoding: buffer.prefix { $0 != 0 }.map { UInt8(bitPattern: $0) }, as: UTF8.self)
        guard !dir.isEmpty else { return nil }
        return dir.hasSuffix("/") ? dir : dir + "/"
    }

    /// `.fleetest` を持つルートの候補。ツール本体側は `FTBridgeClient.RepoRoot.find()` が子の中で
    /// 解決する(FTCore からは呼べない)ので、**あちらが返しうる場所を全部**挙げる:
    /// `FT_TOOL_ROOT`・受け手パッケージの SPM checkout・fleetest の実行ファイルの上方
    static func stateRoots(packageRoot: URL?, environment: [String: String],
                           executable: URL?) -> [String] {
        var roots: [String] = []
        if let packageRoot {
            roots.append(packageRoot.path)
            let checkouts = packageRoot.appendingPathComponent(".build/checkouts")
            let entries = (try? FileManager.default.contentsOfDirectory(atPath: checkouts.path)) ?? []
            for entry in entries.sorted() {
                let candidate = checkouts.appendingPathComponent(entry)
                if hasBridgeAssets(candidate) { roots.append(candidate.path) }
            }
        }
        if let override = environment["FT_TOOL_ROOT"], !override.isEmpty {
            let dir = URL(fileURLWithPath: (override as NSString).expandingTildeInPath)
            if hasBridgeAssets(dir) { roots.append(dir.path) }
        }
        if let executable {
            // `.build/debug` は symlink なので実体から遡る
            var dir = URL(fileURLWithPath: canonicalPath(executable.path)).deletingLastPathComponent()
            for _ in 0..<8 {
                if hasBridgeAssets(dir) { roots.append(dir.path); break }
                let parent = dir.deletingLastPathComponent()
                guard parent.path != dir.path else { break }
                dir = parent
            }
        }
        var seen = Set<String>()
        return roots.map(canonicalPath).filter { seen.insert($0).inserted }
    }

    /// `RepoRoot.hasRunner` と同じ目印(ツール本体のルートかどうか)
    private static func hasBridgeAssets(_ dir: URL) -> Bool {
        FileManager.default.fileExists(atPath: dir.appendingPathComponent("Runner/project.yml").path)
    }

    /// ブリッジが localhost に居ないときに開けるポート。host が nil / ループバックなら空
    static func remoteBridgePorts(_ connection: DriverConnection) -> [UInt16] {
        guard let host = connection.host, !isLoopback(host) else { return [] }
        return [connection.port, connection.xcuiPort].compactMap { $0 }
    }

    static func isLoopback(_ host: String) -> Bool {
        host == "localhost" || host == "::1" || host.hasPrefix("127.")
    }

    /// 子が書いてよい場所。**外で実行・解釈されるものを置く場所を足さない**(足すと、枠の中から
    /// 次の run や人の操作に実行させられる)。`/private/tmp` を入れないのも同じ理由(共有の置き場)
    static func writablePaths(_ scope: Scope) -> [String] {
        var paths = [
            scope.projectRoot + "/.fleetest",
            scope.home + "/.fleetest",
            scope.home + "/Library/Logs/fleetest",
            // Vision / Core ML のコンパイルキャッシュと、URLSession の既定の保存先
            scope.home + "/Library/Caches/" + scope.runnerName,
            scope.home + "/Library/HTTPStorages/" + scope.runnerName,
            // FM の直列化ロックとブレーカ(`FMLock`・`FMBreaker`)。**書けないと黙って効かなくなる**
            // (ロックは取れたことになり、ブレーカは落ちた事実を残せない)
            scope.home + "/Library/Caches/fleetest",
        ]
        paths += scope.stateRoots.map { $0 + "/.fleetest" }
        paths += scope.userTempRoots
        if let reportDir = scope.reportDir { paths.append(reportDir) }
        paths += scope.extraWritable
        return paths
    }

    /// Simulator のアプリのデータコンテナ(正規表現)。`clearAppData` が中身を直接消す
    /// (`BridgeClient.clearAppDataOnSimulator`)。`udid` が nil なら全 Simulator(`Scope.simulatorUDID`)
    static func simulatorDataContainerRegex(home: String, udid: String?) throws -> String {
        let real = canonicalPath(home)
        guard !real.contains("\""),
              !real.unicodeScalars.contains(where: { $0.value < 0x20 || $0.value == 0x7F }) else {
            throw ProfileError.unrepresentablePath(real)
        }
        let device = udid.map { NSRegularExpression.escapedPattern(for: $0) } ?? "[^/]+"
        // **`<UUID>` そのものは含めない**(その下だけ)。含めると子が `<UUID>` を symlink に差し替え、親の
        // `clearAppData`(MCP・ライブ操作)が symlink の先の中身を消す(差し替えは実測で通った)
        return "^" + NSRegularExpression.escapedPattern(for: real)
            + "/Library/Developer/CoreSimulator/Devices/" + device + "/data/Containers/Data/Application/[^/]+/"
    }

    /// 書ける場所の根を親が先に作り、symlink なら止める。**根そのものは枠で書かせない**(`profile` の
    /// literal の拒否)ので、子が作る必要のある根(Core ML のキャッシュ・URLSession の保存先)もここで作る。
    /// 根が symlink だと `canonicalPath` がその先を書ける場所に入れる —— 子が空にした根を `rmdir` して
    /// ホームへの symlink に差し替えると、次のシナリオの枠がホーム全体を開ける(差し替えは実測で通った)
    static func prepareWritableRoots(_ scope: Scope) throws {
        let fm = FileManager.default
        for root in writablePaths(scope) {
            if (try? fm.destinationOfSymbolicLink(atPath: root)) != nil {
                throw ProfileError.symlinkedWritableRoot(root)
            }
            try fm.createDirectory(atPath: root, withIntermediateDirectories: true)
        }
    }

    /// 子に書かせない台帳(ツール本体側の `.fleetest`)。**`.inapp` は除く**(子の `InAppLauncher` が書く)。
    /// 親はこれらを信じて kill(`.pid`)・外への接続(`.endpoint`)・デバイスの帰属(`.device`)を決め、
    /// ログは symlink を辿って追記する
    static func ledgerDenyRegexes(_ scope: Scope) throws -> [String] {
        try scope.stateRoots.map { root in
            let real = canonicalPath(root)
            guard !real.contains("\""),
                  !real.unicodeScalars.contains(where: { $0.value < 0x20 || $0.value == 0x7F }) else {
                throw ProfileError.unrepresentablePath(real)
            }
            return "^" + NSRegularExpression.escapedPattern(for: real)
                + "/\\.fleetest/(android-)?bridge-[^/]*\\.(pid|endpoint|device|toolchain|ready|adopt|log)$"
        }
    }

    /// 子が書いてよい `/dev` の中。**`/dev` を丸ごと開けない** —— 同じユーザーの他の端末(`/dev/ttys*`)へ
    /// 書けて、偽の表示やエスケープシーケンスを流し込める(実測)。`/dev/fd` は開いている記述子の別名だけ
    static let devWritableLiterals = ["/dev/null", "/dev/zero", "/dev/tty", "/dev/random", "/dev/urandom",
                                      "/dev/dtracehelper"]

    /// 書いてよい場所の中で、書かせない場所。どれも**親が中身を信じて枠の外で実行・配布するもの**:
    /// `hooks/` = 次の run が `teardown.sh` を実行(`RunHooks`)/ `DerivedData*` = ランナーの xctestrun と .app を
    /// 親が xcodebuild で起動(子はランナーをビルドしない)/ `ftbridge.apk` = 親が全 Android 端末へ入れる /
    /// `dispatch.lock`・`dispatch.queue` = 1マシン1 run の門(消すと他人の run に重ねられる)。
    /// **親だけが書く場所も閉じる**(子が symlink を置くと、親が先を書き換える・消す): WebView のキャッシュ
    /// (親が run の開始時に「残す1件以外」を消し、置かれた APK を全端末へ入れる)・掃除のロック(親が切り詰めて pid を書く)・
    /// `cleanup.log`・録画の点検フォルダ・Emulator のログ(`metal-history.ndjson` に追記・`<avd>.log` を開き直す)
    static func writeDeniedPaths(_ scope: Scope) -> [String] {
        scope.stateRoots.flatMap { root in
            ["hooks", "DerivedData", "DerivedData-device", "cleanup.log", "recording-probe"]
                .map { root + "/.fleetest/" + $0 }
        } + ["ftbridge.apk", "dispatch.lock", "dispatch.queue", "retention-sweep.lock"]
            .map { scope.home + "/.fleetest/" + $0 }
            + ["Library/Caches/fleetest/webview", "Library/Logs/fleetest/emulator"].map { scope.home + "/" + $0 }
    }

    /// 常に読ませない場所(ホーム相対)。シナリオの駆動に要らない認証情報・個人データの定番の置き場で、
    /// **網羅ではない**(ここに無い秘密は読める。足すのはマシン側の `denyRead`)。
    /// `.config` は丸ごと閉じ、`readReopenedHomeSubpaths` だけ開け直す
    static let defaultDenyReadHomeSubpaths = [
        ".ssh", ".aws", ".azure", ".gnupg", ".kube", ".docker", ".config",
        ".netrc", ".git-credentials", ".npmrc", ".pypirc",
        ".claude", ".claude.json", ".codex",
        "Library/Keychains", "Library/Cookies", "Library/Safari", "Library/Mail", "Library/Messages",
        "Library/Application Support/Google/Chrome", "Library/Application Support/Firefox",
        "Library/Application Support/Microsoft Edge", "Library/Application Support/BraveSoftware",
        "Library/Application Support/Arc",
        // ビルド・配布の資格情報(署名鍵のパスワード・Maven / gem / cargo / pub / yarn のトークン・
        // App Store Connect の API 鍵・fastlane のセッション)とシェルの履歴(打ったトークンが残る)
        ".gradle", ".m2", ".gem/credentials", ".cargo/credentials", ".cargo/credentials.toml",
        ".pub-cache/credentials.json", ".yarnrc", ".yarnrc.yml", ".bundle/config",
        ".appstoreconnect", "private_keys", ".private_keys", ".fastlane", ".expo",
        ".pgpass", ".vault-token", ".terraform.d",
        ".zsh_history", ".zsh_sessions", ".bash_history", ".bash_sessions",
        ".python_history", ".node_repl_history", ".psql_history", ".mysql_history",
        // `Library/Mobile Documents` は入れない: iCloud の「デスクトップと書類」では `~/Documents` の実体がその下にあり、
        // そこに置いたプロジェクトとシナリオ実行バイナリを読めなくなる
        "Library/Application Support/Code", "Library/Application Support/Cursor",
        "Library/Application Support/Slack", "Library/Application Support/Claude",
    ]

    /// 閉じた場所の中で、子が読む必要のある場所。`~/.config/fleetest/config.json` は子が FM の並列枠
    /// (`FMLock.concurrency` → `LocalConfig.load`)を読む
    static let readReopenedHomeSubpaths = [".config/fleetest"]

    /// adb の鍵(Emulator の adbd へ直に繋げば認証が通る)と Emulator のコンソールの鍵。子の adb は親が代行する
    /// (`AdbPolicy`)ので子は読まない。`allowDirectAdb` のときだけ開ける(子の adb がこの鍵を使う)
    static let adbDenyReadHomeSubpaths = [".android", ".emulator_console_auth_token"]

    static func defaultDenyRead(home: String) -> [String] {
        defaultDenyReadHomeSubpaths.map { home + "/" + $0 }
    }

    /// 全拒否の上に開ける、ファイルと通信以外の操作
    static let baseRules = [
        "(allow process-exec*)",
        "(allow process-fork)",
        "(allow signal (target same-sandbox))",
        "(allow process-info*)",
        "(allow file-read*)",
        "(allow sysctl-read)",
        "(allow ipc-posix-shm-read* (ipc-posix-name \"apple.shm.notification_center\"))",
        "(allow file-ioctl (literal \"/dev/dtracehelper\"))",
        "(allow system-fsctl)",
        "(allow network-outbound (literal \"/private/var/run/syslog\"))",
        // Vision / Core ML が画像バッファと GPU を使う。閉じると `Failed to create CVPixelBufferPool` で
        // 画像照合が落ち、OCR は 10 倍以上遅くなる(実測: 1 プロファイル 120 秒 → 1,478 秒)
        "(allow iokit-open-user-client (iokit-user-client-class \"IOSurfaceRootUserClient\")"
            + " (iokit-user-client-class \"AGXDeviceUserClient\")"
            + " (iokit-user-client-class \"IOSurfaceAcceleratorClient\")"
            + " (iokit-user-client-class \"H1xANELoadBalancerDirectPathClient\"))",
        "(allow mach-lookup (xpc-service-name \"com.apple.MTLCompilerService\"))",
    ]

    /// 名指しで開ける mach サービス
    static let machServices = [
        "com.apple.system.opendirectoryd.libinfo",
        "com.apple.system.notification_center",
        "com.apple.logd",
        "com.apple.diagnosticd",
        "com.apple.bsd.dirhelper",
        "com.apple.system.opendirectoryd.membership",
        // LaunchServices のデータベースの読み取り専用の写像(UTType の判定)。閉じると Create ML が見本の画像を
        // 1枚も見つけられず(`No data found for label`)、チェック状態の分類器が学習できない(実測)。
        // **アプリを起こす `coreservicesd` と登録を書き換える `lsd.modifydb` は閉じたまま**(`open -a` は断られる)
        "com.apple.lsd.mapdb",
        // Core ML のコンパイル済みモデル(ANE)と FoundationModels の推論
        "com.apple.appleneuralengine",
        "com.apple.modelmanager",
    ]

    /// プロキシ経由で外へ出るときだけ開ける。閉じたままだと `URLSession` の HTTPS が証明書を検証できず
    /// -1202(信頼できないサーバ証明書)で落ちる(実測)。curl は自前の検証なので要らない
    static let proxyMachServices = ["com.apple.trustd.agent"]

    /// Seatbelt のプロファイル本文。**後に書いた規則が勝つ**ので、順序は
    /// 全拒否 → 開ける操作 → 書き込みの許可 → その中の拒否 → 読み取りの拒否 → 開け直し → 通信
    public static func profile(_ scope: Scope) throws -> String {
        var lines = ["(version 1)", "(deny default)"] + baseRules
        let services = machServices + (scope.usesProxy ? proxyMachServices : [])
        lines.append("(allow mach-lookup " + services.map { "(global-name \"\($0)\")" }
            .joined(separator: " ") + ")")
        let writable = try writablePaths(scope).map { try subpath($0) }
        let dev = devWritableLiterals.map { "(literal \"\($0)\")" } + ["(subpath \"/dev/fd\")"]
        let regexes = try childWritableRegexes(scope, containerUDID: scope.simulatorUDID).map { "(regex #\"" + $0 + "\")" }
        lines.append("(allow file-write* " + (dev + writable + regexes).joined(separator: " ") + ")")
        // Core ML がコンパイルキャッシュを ANE のデーモンへ見せるための権利の発行
        lines.append("(allow file-issue-extension "
            + (try subpath(scope.home + "/Library/Caches/" + scope.runnerName)) + ")")
        let denied = try writeDeniedPaths(scope).map { try subpath($0) }
            + (try ledgerDenyRegexes(scope)).map { "(regex #\"" + $0 + "\")" }
            // 根そのもの(中身は書ける)。`prepareWritableRoots` の doc
            + (try writablePaths(scope).map { "(literal " + (try quoted(canonicalPath($0))) + ")" })
        lines.append("(deny file-write* " + denied.joined(separator: " ") + ")")
        let unreadable = try scope.denyRead.map { try subpath($0) }
        if !unreadable.isEmpty {
            lines.append("(deny file-read* " + unreadable.joined(separator: " ") + ")")
            let reopened = try readReopenedHomeSubpaths.map { try subpath(scope.home + "/" + $0) }
            lines.append("(allow file-read* " + reopened.joined(separator: " ") + ")")
        }
        // **`network*` に `(local ip "localhost:*")` を書かない** —— 外向きの接続にも当たって全部通る
        // (実測)。向きごとに分け、外向きは宛先(remote)だけで絞る。`localhost` は自機の全アドレスを含む
        lines.append("(deny network*)")
        lines.append("(allow network-outbound (remote ip \"localhost:*\"))")
        for socket in [scope.brokerSocket].compactMap({ $0 }) + scope.helperSockets {
            lines.append("(allow network-outbound (remote unix-socket (path-literal "
                + (try quoted(canonicalPath(socket))) + ")))")
        }
        lines.append("(allow network-bind (local ip \"localhost:*\"))")
        lines.append("(allow network-inbound (local ip \"localhost:*\"))")
        for port in scope.remoteBridgePorts {
            lines.append("(allow network-outbound (remote ip \"*:\(port)\"))")
        }
        // adb サーバと Emulator のコンソール / adbd は閉じる(後に書いた規則が勝つので上の localhost:* より後)。
        // 開いていると `adb shell` で Emulator の中 = 枠の外から外部へ出られ、繋がった全端末を操作できる。
        // 子の adb は親が代行する(`AdbPolicy`)
        for port in scope.allowDirectAdb ? [] : deniedLoopbackPorts() {
            lines.append("(deny network-outbound (remote ip \"localhost:\(port)\"))")
        }
        return lines.joined(separator: "\n") + "\n"
    }

    static func deniedLoopbackPorts(environment: [String: String] = ProcessInfo.processInfo.environment) -> [UInt16] {
        [AdbLocator.adbServerPort(environment: environment)] + Array(AdbLocator.emulatorPorts)
    }

    /// `(subpath "<実体パス>")`。Seatbelt は symlink を解決した後のパスで照合するので
    /// (`/var` → `/private/var`・`/tmp` → `/private/tmp`)、解決前のパスを書くと規則が当たらない
    static func subpath(_ path: String) throws -> String {
        "(subpath " + (try quoted(canonicalPath(path))) + ")"
    }

    /// Seatbelt の文字列リテラル
    static func quoted(_ real: String) throws -> String {
        guard !real.unicodeScalars.contains(where: { $0.value < 0x20 || $0.value == 0x7F }) else {
            throw ProfileError.unrepresentablePath(real)
        }
        let escaped = real.replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
        return "\"\(escaped)\""
    }

    /// 親の broker に渡す方針の文脈(子が書ける場所は、プロファイルに書いたものと同じ集合から作る)
    static func brokerContext(_ scope: Scope, connection: DriverConnection?) throws -> SimctlPolicy.Context {
        SimctlPolicy.Context(
            udid: connection?.udid, deviceName: connection?.deviceName,
            toolRoots: scope.stateRoots,
            childWritableRoots: ["/dev"] + writablePaths(scope).map(canonicalPath),
            // 子が書ける場所からの install を断る判定なので、広い側(全 Simulator)で断る
            childWritablePattern: try childWritableRegexes(scope, containerUDID: nil).map { "(?:" + $0 + ")" }
                .joined(separator: "|"),
            serial: connection?.serial, adbPath: AdbLocator.adbPath(), bundletool: BundletoolLocator.find())
    }

    /// symlink を解決した実体パス。**まだ無いパスでも返す** ——
    /// 存在する最も深い祖先を `realpath` で解決し、残りを足す。
    /// `URL.resolvingSymlinksInPath` は `/private` を剥がすので使わない
    static func canonicalPath(_ path: String) -> String {
        var current = URL(fileURLWithPath: path).standardizedFileURL
        var tail: [String] = []
        while true {
            if let resolved = realpath(current.path, nil) {
                defer { free(resolved) }
                var result = String(cString: resolved)
                for component in tail.reversed() {
                    result = (result as NSString).appendingPathComponent(component)
                }
                return result
            }
            let parent = current.deletingLastPathComponent()
            guard parent.path != current.path else { return path }
            tail.append(current.lastPathComponent)
            current = parent
        }
    }

    /// `sandbox-exec` は枠を掛けてから対象を exec する = **pid は変わらない**ので、
    /// SIGTERM・親の死の検知・stdin の制御チャネルは包まないときと同じに届く。
    /// プロファイルはファイルに置かず `-p` で渡す(置くと枠の中から書き換えられる場所を1つ増やす)
    public static func wrap(runner: URL, arguments: [String],
                            profile: String) -> (executable: URL, arguments: [String]) {
        (URL(fileURLWithPath: sandboxExecPath), ["-p", profile, runner.path] + arguments)
    }
}
