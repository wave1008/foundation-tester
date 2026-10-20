// ScriptSandbox.swift
// run-setup.sh / run-teardown.sh を Seatbelt で包む入口(docs/remote-runner.md §17「スクリプト(Seatbelt の中)」)。
// 枠の土台と規則は ScenarioSandbox(用途 `.script`)。ここは入力を集めて Scope を組み、起動の形を返すだけ。
// 包むかどうかの判断(マシン側の `sandbox.disabled`)はシナリオと同じ `ScenarioSandbox.plan` = 呼び手が nil なら包まない。
import Foundation

public enum ScriptSandbox {
    /// スクリプト専用の一時領域(`T/fleetest-sandbox/hooks-<pid>/`)。子の `TMPDIR` で、親の gateway のソケットもここに置く
    /// (枠の中から unix ソケットへ繋ぐにはそのパスへの書き込みも要る = sandbox-seatbelt.md §2.7)。取れなければ nil
    public static func temporaryDirectory(pid: Int32 = ProcessInfo.processInfo.processIdentifier) -> String? {
        ScenarioSandbox.childTemporaryDirectory(runnerName: temporaryDirectoryName(pid: pid))
    }

    static func temporaryDirectoryName(pid: Int32) -> String { "hooks-\(pid)" }

    /// 死んだ run が残した `hooks-<pid>/`(親が SIGKILL されると `runScript` の後始末が走らない)。`root` は
    /// `T/fleetest-sandbox/`(テストは差し替える)。生きている pid のものと別の名前のものには触らない
    public static func staleTemporaryDirectories(
        root explicitRoot: String? = nil,
        isAlive: (Int32) -> Bool = ProcessLiveness.isAlive
    ) -> [String] {
        // 既定の root は `T/fleetest-sandbox/`(public の既定引数からは internal の関数を呼べないので中で引く)
        let root = explicitRoot ?? ScenarioSandbox.childTemporaryDirectory(runnerName: "").map { String($0.dropLast()) }
        guard let root, let names = try? FileManager.default.contentsOfDirectory(atPath: root) else { return [] }
        return names.sorted().compactMap { name in
            guard name.hasPrefix("hooks-"), let pid = Int32(name.dropFirst("hooks-".count)), pid > 0,
                  !isAlive(pid) else { return nil }
            return root + "/" + name
        }
    }

    public struct Inputs: Sendable {
        public var script: URL
        /// `scripts/` と `data/` の親
        public var workspace: URL
        public var projectRoot: URL
        public var packageRoot: URL?
        /// マシン側 `hooks.writablePaths`(展開済み)。ここで `protectedLocations` と重ならないことを検める
        public var hookWritablePaths: [String]
        /// マシン側 `services.buildSources`(書ける場所に含めさせない)
        public var buildSources: [String]
        /// 127.0.0.1 で繋いでよいポート(宣言した公開ポート + 親のプロキシ)
        public var loopbackPorts: [UInt16]
        /// 親の gateway のソケット(compose.yaml があるときだけ)
        public var gatewaySocket: String?
        public var usesProxy: Bool
        /// `temporaryDirectory(pid:)` の値(呼び手が先に作る)
        public var temporaryDirectory: String

        public init(script: URL, workspace: URL, projectRoot: URL, packageRoot: URL?, hookWritablePaths: [String],
                    buildSources: [String], loopbackPorts: [UInt16], gatewaySocket: String?, usesProxy: Bool,
                    temporaryDirectory: String) {
            self.script = script
            self.workspace = workspace
            self.projectRoot = projectRoot
            self.packageRoot = packageRoot
            self.hookWritablePaths = hookWritablePaths
            self.buildSources = buildSources
            self.loopbackPorts = loopbackPorts
            self.gatewaySocket = gatewaySocket
            self.usesProxy = usesProxy
            self.temporaryDirectory = temporaryDirectory
        }
    }

    public struct Launch: Sendable {
        public let executable: URL
        public let arguments: [String]
        /// 利用者向けの一文(枠に断られた失敗 = EPERM の原因に辿り着くため、スクリプトのたびに出す)
        public let notice: String
    }

    /// 実行権が無いスクリプトは sh で起こす(chmod を忘れただけで止めない)。権があれば直接 = shebang を尊重する
    public static func command(for script: URL) -> (executable: URL, arguments: [String]) {
        if FileManager.default.isExecutableFile(atPath: script.path) { return (script, []) }
        return (URL(fileURLWithPath: "/bin/sh"), [script.path])
    }

    /// 書ける場所に含めさせない場所(枠の外で実行・解釈されるもの・秘密・ツール本体)。`HooksSettings.validate` へ渡す
    public static func protectedLocations(workspace: URL, projectRoot: URL, stateRoots: [String],
                                          buildSources: [String], home: String) -> [(label: String, path: String)] {
        var protected: [(String, String)] = [
            ("the workspace's scripts/ directory", workspace.appendingPathComponent(RunHookPlan.scriptsDirectoryName).path),
            // プロジェクトは親がビルド・解釈する(scenarios/ の Swift・プロファイル・.fleetest の指紋と台帳)
            ("the test project \(projectRoot.path)", projectRoot.path),
            // マシン側の設定(sandbox.disabled を書ける)と秘密・親専用の領域
            ("this Mac's fleetest settings directory", home + "/.config/fleetest"),
            ("this user's .fleetest ledger", home + "/.fleetest"),
        ]
        for root in stateRoots {
            protected.append(("the fleetest tool root \(root)", root))
        }
        for source in buildSources {
            protected.append(("the build source \(source)", source))
        }
        return protected
    }

    /// 枠の形を組む。**包むと決まったのに組めないときは投げる**(枠なしで黙って起こさない)
    public static func launch(_ inputs: Inputs, plan: ScenarioSandbox.Plan,
                              home: String = ScenarioSandbox.realHome(),
                              environment: [String: String] = ProcessInfo.processInfo.environment) throws -> Launch {
        let stateRoots = ScenarioSandbox.stateRoots(
            packageRoot: inputs.packageRoot, environment: environment, executable: Bundle.main.executableURL)
        try HooksSettings.validate(
            writablePaths: inputs.hookWritablePaths,
            protected: protectedLocations(workspace: inputs.workspace, projectRoot: inputs.projectRoot,
                                          stateRoots: stateRoots, buildSources: inputs.buildSources, home: home))
        var scope = ScenarioSandbox.Scope(
            purpose: .script, reportDir: nil, denyRead: plan.denyRead, projectRoot: inputs.projectRoot.path,
            stateRoots: stateRoots, home: home, userTempRoots: [inputs.temporaryDirectory],
            runnerName: "fleetest-hooks")
        scope.dataDir = inputs.workspace.appendingPathComponent("data").path
        scope.hookWritablePaths = inputs.hookWritablePaths
        scope.allowedLoopbackPorts = inputs.loopbackPorts
        scope.brokerSocket = inputs.gatewaySocket
        scope.usesProxy = inputs.usesProxy
        // 根(data/・一時領域・hooks.writablePaths)は親が先に作り、symlink なら起こさない
        try ScenarioSandbox.prepareWritableRoots(scope)
        let command = command(for: inputs.script)
        let wrapped = ScenarioSandbox.wrap(runner: command.executable, arguments: command.arguments,
                                           profile: try ScenarioSandbox.profile(scope))
        return Launch(executable: wrapped.executable, arguments: wrapped.arguments, notice: ScenarioSandbox.scriptNotice)
    }

    /// 親の環境のうちスクリプトへ渡す基本の鍵。**`FT_*` の前方一致は使わない**(親の `FT_PRIVATE_TOKEN` のような変数まで渡る)。
    /// `LC_*` は locale なので通す。契約の `FT_*`(RunHookEnvironment)と制御変数は呼び手が足す
    public static func baseEnvironment(_ parent: [String: String]) -> [String: String] {
        parent.filter { key, _ in ScenarioSandbox.inheritedEnvironmentKeys.contains(key) || key.hasPrefix("LC_") }
    }

    /// 許可ドメインへのプロキシ(fleetest のプロセスが生きている間だけ・集合ごとに1つ)。環境変数と待ち受けポート
    public static func proxy(allowedDomains: [String]) throws -> (environment: [String: String], port: UInt16) {
        let proxy = try SandboxProxyRegistry.shared.proxy(for: allowedDomains)
        return (proxy.environment, proxy.port)
    }
}
