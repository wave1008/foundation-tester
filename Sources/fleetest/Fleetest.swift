import ArgumentParser
import Foundation
import FTFoundationModels
import FTAndroid
import FTBridgeClient
import FTCore
import FTRemote
import FTDSL

@main
struct Fleetest: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "fleetest",
        abstract: "iOS/Android app testing tool for macOS",
        version: ToolVersion.describe(),
        subcommands: [
            InitCommand.self,
            Doctor.self,
            Bridge.self,
            Install.self,
            Launch.self,
            Snapshot.self,
            Tap.self,
            TypeCommand.self,
            Swipe.self,
            Press.self,
            Screenshot.self,
            Terminate.self,
            RunScenarios.self,
            RunFileCommand.self,
            DraftScenarioCommand.self,
            ProjectCommand.self,
            ProfileCommand.self,
            DevicesCommand.self,
            ApiCommand.self,
            ResultsCommand.self,
            RemoteCommand.self,
            HooksCommand.self,
            MonitorCommand.self,
            CleanCommand.self,
            VisionCommand.self,
        ]
    )

    /// AsyncParsableCommand の既定 main() を隠し、パース前に武装だけ差し込む
    /// (`FT_PARENT_PID` が無ければ armIfRequested は no-op = 挙動は変わらない)。
    /// パース → run() → catch は既定と同じ形で、**違うのは run() の中で投げた ValidationError だけ**:
    /// 既定の `exit(withError:)` はルートの Usage(`fleetest <subcommand>`)を出すので、どのコマンドの
    /// 使い方を見ればよいかが消える。そのサブコマンドの help を名指しする(exit code は同じ 64)
    static func main() async {
        // 出力の読み手が先に死ぬと(`| head`/`| tee` を Ctrl-C 等)、書き込みが SIGPIPE で
        // このプロセスごと即死し、中断後の巻き戻し(録画の停止・lease 解放・run.json 完了)が
        // 1つも走らない(実測: rc=141、simctl recordVideo の孤児)。
        // fd 単位で SIGPIPE を止めて EPIPE を write(2) の戻り値で受ける
        // (`signal(SIGPIPE, SIG_IGN)` はプロセス全体の副作用で simctl/adb 等の exec した子にも
        // 継承されるため使わない。Shell.swift の同じ判断を fleetest 自身の stdout/stderr にも適用)。
        // ConsoleOut.emit の write ループは EPIPE(n<0 かつ非 EINTR)で無限ループも例外もせず
        // 静かに return するので、ここで止めるだけで十分
        _ = fcntl(FileHandle.standardOutput.fileDescriptor, F_SETNOSIGPIPE, 1)
        _ = fcntl(FileHandle.standardError.fileDescriptor, F_SETNOSIGPIPE, 1)
        ParentDeathWatch.armIfRequested()
        LedgerWriteRole.enableForProduction()
        let command: ParsableCommand
        do {
            command = try parseAsRoot(nil)
        } catch {
            exit(withError: error)
        }
        do {
            if var asyncCommand = command as? AsyncParsableCommand {
                try await asyncCommand.run()
            } else {
                var syncCommand = command
                try syncCommand.run()
            }
        } catch let error as ValidationError {
            ConsoleOut.err("Error: \(error.message)")
            ConsoleOut.err("  See 'fleetest \(commandPath(of: type(of: command)) ?? "") --help'"
                + " for more information.")
            Foundation.exit(ExitCode.validationFailure.rawValue)
        } catch {
            exit(withError: error)
        }
    }

    /// サブコマンドの型からルート以下の名前の並び("results list")を引く。見つからなければ nil
    static func commandPath(of target: ParsableCommand.Type) -> String? {
        func search(_ type: ParsableCommand.Type, _ path: [String]) -> [String]? {
            if type == target { return path }
            for sub in type.configuration.subcommands {
                if let found = search(sub, path + [sub._commandName]) { return found }
            }
            return nil
        }
        return search(Fleetest.self, []).map { $0.joined(separator: " ") }
    }
}

struct DriverOptions: ParsableArguments {
    @Option(help: "Target platform: ios / android (default ios)")
    var platform: String?

    @Option(name: .long, help: "Bridge port number (iOS only; default \(BridgeAPI.defaultPort))")
    var port: UInt16?

    @Option(help: "Android device serial (adb -s; defaults to the only connected device)")
    var serial: String?

    @Flag(help: "Proceed even if the connected bridge's protocol version differs from this build (manual drive commands only)")
    var allowVersionSkew = false

    /// `makeDriver` を通らないコマンド(`bridge up/status`・`api list-apps`・`api live`)が
    /// この OptionGroup を共有しているので、そこでは `--allow-version-skew` が黙って効かない。
    /// **指定したのに効かない形を作らない** —— 効かせられない場所では名指しで断る
    func rejectVersionSkewFlag(in command: String) throws {
        if allowVersionSkew {
            throw ValidationError("--allow-version-skew has no effect on \(command)"
                + " (it applies to the manual drive commands: snapshot/tap/type/swipe/press/"
                + "screenshot/launch/install/terminate)")
        }
    }

    /// `platform`/`port` は non-Optional にしない —— 既定値を持たせると「指定された」と
    /// 「既定のまま」が区別できず、`--profile` との併用禁止のような検査ができなくなる
    /// (`RunRejectionTests` 参照)。既定値が要る箇所はここを通す
    var resolvedPlatform: String { platform ?? "ios" }
    var resolvedPort: UInt16 { port ?? BridgeAPI.defaultPort }

    /// FTFoundationModels/FTCore はこの抽象のみに依存(BridgeClient/AndroidDriver を直接見ない)。
    /// **手動駆動サブコマンド(install/launch/snapshot/tap/type/swipe/press/screenshot/
    /// terminate)だけがここを通る** —— `bridge up`/`bridge status` は `resolvedPort` を
    /// 直接使うので、この探索・版ズレ拒否の影響を受けない。
    /// 宛先解決は MCP(ft_*)と同じ `FTBridgeClient.BridgeTargetResolution` /
    /// `FTAndroid.AndroidTargetResolution` を通す(判定を2つ持たない)
    func makeDriver(overriding platformOverride: String? = nil) async throws -> AppDriver {
        switch platformOverride ?? resolvedPlatform {
        case "ios":
            // 実機ブリッジは 127.0.0.1 に居ない(LAN)か token が要る(usb)。provision が残した
            // 宛先を丸ごと使う(記録が無ければループバック = シミュレータの既定)。
            // **明示 --port は探索しない**ので実機は従来どおり通る
            let resolvedPort: UInt16
            do {
                resolvedPort = try await BridgeTargetResolution.iosPort(
                    explicit: port, log: { ConsoleOut.err($0) })
            } catch let error as BridgeTargetError {
                throw ValidationError(error.errorDescription ?? "\(error)")
            }
            let driver = PortDirectIOSTarget(port: resolvedPort).makeDriver()
            if let skew = await BridgeTargetResolution.versionSkew(driver: driver) {
                guard allowVersionSkew else {
                    throw ValidationError(Self.skewMessage(skew, port: resolvedPort))
                }
                ConsoleOut.err("⚠️ --allow-version-skew: proceeding despite a bridge/host mismatch. "
                               + Self.skewMessage(skew, port: resolvedPort))
            }
            return driver
        case "android":
            do {
                let resolvedSerial = try AndroidTargetResolution.serial(
                    explicit: serial, log: { ConsoleOut.err($0) })
                return try AndroidDriver(serial: resolvedSerial)
            } catch let error as AndroidTargetError {
                throw ValidationError(error.errorDescription ?? "\(error)")
            }
        default:
            throw ValidationError("platform must be ios or android: \(platformOverride ?? resolvedPlatform)")
        }
    }

    /// 版ズレの CLI 向け文言(純粋関数・テスト用)。**判定(running/expected の比較)は
    /// `BridgeVersionSkew`(FTBridgeClient・MCP と共有)** —— ここは対処の言い回しだけ持つ
    /// (MCP は `fleetest-mcp`/`bridge down --all` を名指しする。こちらは `fleetest` の
    /// 再ビルドと、この宛先だけを建て直す `bridge down --port` を名指しする。文言は呼び手ごと)
    static func skewMessage(_ skew: BridgeVersionSkew, port: UInt16) -> String {
        let side = skew.bridgeIsNewer
            ? "the bridge on port \(port) is NEWER than this build (v\(skew.running) > v\(skew.expected)) —"
                + " your fleetest binary is stale, so rebuild it (swift build --product fleetest) or pull"
            : "the bridge on port \(port) is OLDER than this build (v\(skew.running) < v\(skew.expected)) —"
                + " restart it with `fleetest bridge down --port \(port) && fleetest bridge up`"
        return "bridge protocol mismatch: \(side)."
            + " Refusing to operate: a stale bridge answers with the behaviour of its own version."
            + " Pass --allow-version-skew to proceed anyway."
    }
}

// MARK: - 実行コマンド

struct RunScenarios: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "run",
        abstract: "Run Swift DSL scenarios (TestProjects/<name>/scenarios/). FM only steps in on failure")

    @Option(help: "Test project name (defaults to the only one in TestProjects/, or the default project)")
    var project: String?

    @Option(help: "Run profile name (profiles/runs/<name>.json). Includes device provisioning and auto-install. Cannot be combined with --platform/--port/--serial/--app-id")
    var profile: String?

    @Option(name: .customLong("scenario"), parsing: .upToNextOption,
            help: "Scenario IDs to run (Class.method; a class name alone runs all of its scenarios). Repeatable; defaults to all. @Deleted / @Draft scenarios run only on an exact match")
    var scenarios: [String] = []

    @Option(name: .customLong("folder"), parsing: .upToNextOption,
            help: "Scenario folders to run (subfolders directly under scenarios/). Repeatable; can be combined with --scenario and --failed")
    var folders: [String] = []

    /// キーはプロファイル JSON のキーそのもの(kebab 変換しない)。**共有フラグ**(`fleetest api run`
    /// にも同じ口があるので `RunCommandFlagParityTests` の runOnly/apiOnly には入れない)。
    /// 上書きは `ProfileResolver.resolve` / `--profile` 無しの直接実行の両方で
    /// `RunProfileDocument.applyingOverrides` を通る唯一の経路(FTCore/RunProfile.swift)。
    /// 値の型はキーの宣言型に従う(Bool/Int/Double/String。パース失敗は型を名指しでエラーにする。
    /// 検証は `RunProfileSetOverride.parse`。validate() が呼ぶ)。
    /// **プロファイルの devices 一覧・供給工程に依存するキー**(`RunProfileDocument.profileOnlyKeys`:
    /// iosInappEngine/updateWebView/wipeDataOnBloat/recoverCpuFallbackToGpu/app/machine/locale/
    /// wipeDataThresholdGB)は `--profile` が無いと run() のプロファイル無し分岐でエラーにする
    /// (黙って無視しない)。`record` は devices に依存しないが、単一接続(`--port` 未指定/1個)の
    /// 経路では別途エラーにする(RunOrchestrator の録画セッションが無い。run() 参照)。
    /// **`reportDir` は `--report-dir` と同時指定するとエラー**(黙ってどちらかを勝たせない。
    /// validate() 参照)
    @Option(name: .customLong("set"),
            help: ArgumentHelp("Override one field of the run profile document for this run only "
                + "(repeatable): <key>=<value>, where <key> is exactly the run profile JSON key and "
                + "<value> matches that key's type (e.g. --set textVisualCheck=false "
                + "--set reportDir=/tmp/out). Keys that need a run profile's device list/supply "
                + "pipeline (iosInappEngine, updateWebView, wipeDataOnBloat, recoverCpuFallbackToGpu, "
                + "app, machine, locale, wipeDataThresholdGB) need --profile. The run profile keys "
                + "\"app\"/\"machine\" (an app/machine *profile* name) are unrelated to this command's "
                + "own --app-id/--runner flags. Cannot combine reportDir with --report-dir. "
                + "devices/remoteControl are lists/objects and cannot be set this way; edit the run "
                + "profile JSON instead"))
    var setOverrides: [String] = []

    @Flag(name: .customLong("dry-run"),
          help: "Enumerate and validate the steps without touching a device (No-Load-Run). Catches selector syntax errors, unreachable scenes and expectation blocks with no assertions")
    var dryRun = false

    @Flag(name: .customLong("no-lpt"),
          help: "Disable LPT ordering (longest past runtime first) and dispatch in scenario ID order")
    var noLPT = false

    @Option(name: .customLong("lpt-history-runs"),
            help: "Number of past runs to read for LPT ordering (newest first, default 5)")
    var lptHistoryRuns: Int?

    @Flag(help: "Run only the scenarios that failed last time (results are recorded in .fleetest/last-results/ on every run)")
    var failed = false

    @Option(name: .customLong("report-dir"),
            help: "Directory to write reports to (defaults to TestProjects/<name>/reports). Cannot combine with --set reportDir=...")
    var reportDir: String?

    @Option(name: .customLong("port"),
            help: "Bridge port for running iOS scenarios in parallel. Repeatable (--port 8123 --port 8124); each port must already have a bridge up on a separate device")
    var ports: [UInt16] = []

    @Flag(name: .customLong("skip-build"), help: "Skip the swift build before running")
    var skipBuild = false

    @Flag(help: "Suppress step lines and print only the summary (for CI and agents)")
    var quiet = false

    @Option(help: "Write a JUnit XML report of this run to the given path (for CI test reporting)")
    var junit: String?

    /// 受け付ける2つの形(machine = 登録簿の名前 = ローカルエイリアス、host = ホスト名 / IP)の
    /// 解決は RemoteHostRegistry.resolve に委譲する(ApiRunCommand の同名オプションと同じ規律)
    @Option(name: .customLong("runner"), help: ArgumentHelp(
        "Dispatch this run to a remote runner: a registered machine name (fleetest remote machines) "
        + "or a raw user@host/host. Requires --profile"))
    var runner: String?

    @Option(name: .customLong("remote-dir"),
            help: "Runner-only base directory on the remote host (holds its own clone and workspace; default: the host registry's entry, or ~/fleetest-runner). Must NOT point at an existing local install of foundation-tester")
    var remoteDir: String?

    @Option(name: .customLong("remote-timeout"),
            help: "Timeout in seconds for the whole remote dispatch (default: auto, sized from the scenario count; see docs/remote-runner.md)")
    var remoteTimeout: Int?

    @Flag(name: .customLong("performance"),
          help: "Performance-testing mode (requires --profile or --fleet): if a dead lane cannot be revived before the run starts, fail instead of dropping it and continuing on the remaining lanes. iOS lanes are built before the run starts (no late join) so a missing one is reported before the run, not in the middle of it")
    var performanceMode = false

    @Option(help: ArgumentHelp("Dispatch this run across a fleet of hosts in parallel: "
        + "profiles/fleets/<name>.json (docs/remote-runner.md §13). Each entry runs as its own "
        + "child process, with output lines prefixed by the entry's host name. Mutually exclusive "
        + "with --runner/--profile/--port/--failed/--report-dir/--skip-build. --junit is supported: "
        + "each entry's report is merged into one file (docs/remote-runner.md §8). Experimental"))
    var fleet: String?

    @Flag(help: ArgumentHelp("With --fleet: distribute the scenario set across the fleet's entries "
        + "(LPT bin packing by past duration; docs/remote-runner.md §8) instead of running the same "
        + "set on every entry. Requires a local build+scenario list to resolve the assignment "
        + "(skipped by plain --fleet), and resolves each entry's platform from its run profile's "
        + "devices. Entries assigned 0 scenarios are not dispatched. Experimental"))
    var split = false

    @Flag(name: .customLong("force-lock"),
          help: ArgumentHelp("Steal a remote host's dispatch.lock instead of failing fast when another dispatch "
            + "already holds it (docs/remote-runner.md §5). Needs a run profile, --runner or --fleet"))
    var forceLock = false

    @Option(name: .customLong("wait-lock"),
            help: ArgumentHelp("Instead of failing fast, poll until a remote host's dispatch.lock is released, "
              + "up to this many seconds (docs/remote-runner.md §5). Needs a run profile, --runner or --fleet. "
              + "Cannot be combined with --force-lock"))
    var waitLock: Int?

    /// ブロードキャスト実行。warmup のように「全デバイスがそれぞれ準備される」
    /// ことが目的の run 向け。分配だけを `ScenarioDispatch.broadcast` に差し替え、他は通常 run
    /// (ProfileRunner.run)と同じ経路。**--profile が要る**(レーン = プロファイルのデバイス)
    @Flag(name: .customLong("broadcast"),
          help: ArgumentHelp("Run the selected scenarios once on EVERY device of the run profile "
            + "(broadcast) instead of sharing them out across the devices — e.g. a warm-up that must "
            + "touch each device. Needs --profile; --device narrows the set of devices. Provisioning, "
            + "auto-install, setup/teardown hooks (once per run), staggered start, lane revival and "
            + "reports are the same as a normal run. Results: one scenarios/*.json per (scenario, device), "
            + "told apart by their worker field"))
    var broadcast = false

    @Option(name: .customLong("device"), parsing: .upToNextOption,
            help: ArgumentHelp("Run on only these devices of the run profile (device names as written in "
                + "the run profile). Repeatable; defaults to every device the run profile lists. "
                + "Used by the per-host sub-runs when one run profile spans devices on several machines "
                + "(docs/remote-runner.md §13)"))
    var devices: [String] = []

    /// **どの機械のデバイスを使うか**。`--device` は名前でしか絞れないが、一意なのは (host, name)
    /// なので、名前だけだと別の機械の同名デバイスまで掴む(docs/remote-runner.md §13)。
    /// マシン別サブ実行が自分で付ける値で、手で打つものではない
    @Option(name: .customLong("device-machine"),
            help: ArgumentHelp(
                "Only use the devices assigned to this machine (\"local\" or a registered host name). "
                + "Set by the per-host sub-runs; not for hand use",
                visibility: .hidden))
    var deviceMachine: String?

    /// 同じ実行から分かれた run を束ねる鍵(FTCore.RunMetaRecord.runGroup)。**発行は
    /// マシン別サブ実行の親だけ**で、子は受け取った値をそのまま run.json に書く。手で打つものではない
    @Option(name: .customLong("run-group"),
            help: ArgumentHelp(
                "Group key shared by the per-machine sub-runs of one execution. "
                + "Set by the per-host sub-runs; not for hand use",
                visibility: .hidden))
    var runGroup: String?

    /// **手で打つものではない**。RemoteRunDispatcher がミラー後の絶対パスを渡す
    /// (Sources/FTRemote/RemoteDispatch.swift の RemoteRunArgs.build)。プロファイルの
    /// `remoteControl.workspace` を上書きし、appPath のインストール先(ステージ先。原本の解決基準は
    /// 常にリポジトリルートで不変)をそちらへ切り替える(ProfileResolver.resolve の
    /// workspaceOverride / WorkspaceAppStaging 参照)
    @Option(help: ArgumentHelp(
        "Override this run profile's remoteControl.workspace (where the staged appPath package is "
        + "installed from). Set by the remote dispatcher on the far side; not for hand use",
        visibility: .hidden))
    var workspace: String?

    /// `@TestClass(app:)` を書かないシナリオを **実行プロファイル無し**で回すときの逃げ道。
    /// --profile があればそちらのアプリプロファイルから解決されるので併用不可(validate() 参照)
    @Option(name: .customLong("app-id"),
            help: "Default app (bundle ID / package name) for scenarios that declare no @TestClass(app:). Cannot be combined with --profile (the app profile supplies the bundle ID)")
    var appID: String?

    @Option(help: "Target platform: ios / android (default ios)")
    var platform: String?

    @Option(help: "Android device serial (adb -s; defaults to the only connected device)")
    var serial: String?

    /// `platform` は non-Optional にしない —— 既定値を持たせると「指定された」と「既定のまま」が
    /// 区別できず、`--profile` との併用禁止のような検査ができなくなる(DriverOptions と同じ規律)
    var resolvedPlatform: String { platform ?? "ios" }

    func validate() throws {
        // レポートは run 後に書くので、書けない先は**始める前に**言う(フリート run では
        // 20 分走ってから分かっていた)。末尾の書き込み失敗が警告のみの規律は変えない
        // (判定は FTCore.JUnitOutputPath の doc)
        if let junit, let reason = JUnitOutputPath.unwritableReason(path: junit) {
            throw ValidationError("--junit \(junit) cannot be written: \(reason)")
        }
        // dry-run は JUnit を書かない(実行していない結果を合否として CI に渡さない)ので、黙って無視せず断る
        if junit != nil, dryRun {
            throw ValidationError("--junit cannot be combined with --dry-run (a dry-run writes no JUnit report)")
        }
        let parsed: [String: RunProfileSetValue]
        do { parsed = try RunProfileSetOverride.parse(setOverrides) }
        catch { throw ValidationError(error.localizedDescription) }
        // 専用フラグと同じキーの `--set` は黙ってどちらかを勝たせない(--profile の有無を問わない)
        if let message = RunProfileDocument.flagOverrideCollision(
            flag: "--report-dir", key: "reportDir", flagIsSet: reportDir != nil, overrides: parsed) {
            throw ValidationError(message)
        }
        // --profile 無しのときだけ判定できる(デバイス一覧・録画基盤が無い経路。run() が
        // build 後にもう一度これを検査すると約12秒のビルドを無駄に払う。引数だけで決まるので
        // ここへ寄せる)。**--fleet は除く**(各エントリが自分の --profile を持つので、
        // ここでの「プロファイル無し」判定は誤り。dispatchToFleet は素通しで転送する)。
        // **--dry-run も除く**(デバイスにも録画にも触れないので --set はそもそも使われない。
        // run() が info 注記を出すだけで、この検査までは到達しない)
        if profile == nil, fleet == nil, !dryRun {
            let unsupported = Set(parsed.keys).intersection(RunProfileDocument.profileOnlyKeys).sorted()
            guard unsupported.isEmpty else {
                throw ValidationError("--set \(unsupported.joined(separator: ", ")) needs --profile"
                    + " (there are no devices from a run profile to apply"
                    + " \(unsupported.count == 1 ? "it" : "them") to)")
            }
            // 単一接続の runSequential は RunOrchestrator を経由しないため録画できない
            // (FTCore.RunProfileDocument.recordNeedsRejecting 参照)。--port を2つ以上渡せば
            // runParallel = RunOrchestrator 経由になり録画できる
            let noProfileSettings = DeviceIndependentRunSettings.resolve(
                DeviceIndependentRunSettings.profileLessBase.applyingOverrides(parsed))
            let iosPorts: [UInt16] = ports.isEmpty ? [BridgeAPI.defaultPort] : ports
            if RunProfileDocument.recordNeedsRejecting(record: noProfileSettings.record,
                                                        hasRecordingSession: iosPorts.count > 1) {
                throw ValidationError("--set record=true needs --profile, or --port given more than"
                    + " once (a single connection here runs scenarios directly; there is no"
                    + " recording session for --set record to attach to)")
            }
        }
        // `--platform` は dry-run でも検証する(`ios{}`/`android{}` の選択に直結するので、
        // 大文字違い等が黙って両方を実行してしまう。)
        if let platform, !RunWorker.knownPlatforms.contains(platform) {
            throw ValidationError("--platform must be one of "
                + "\(RunWorker.knownPlatforms.sorted().joined(separator: "/")): \(platform)")
        }
        if profile != nil,
           platform != nil || !ports.isEmpty || serial != nil {
            throw ValidationError("--profile cannot be combined with --platform/--port/--serial")
        }
        if profile != nil, appID != nil {
            throw ValidationError("--app-id cannot be combined with --profile (the app profile supplies the bundle ID)")
        }
        if performanceMode, profile == nil, fleet == nil {
            throw ValidationError("--performance requires --profile or --fleet")
        }
        // 明示 --runner("local" を除く)は --profile が無いと dispatchToRemoteHost の冒頭で
        // 必ず落ちる。台の machine による自動ディスパッチは --profile がある側でしか
        // 見ないので、ここは引数だけから決まる(ファイル I/O が要らない = validate() に置ける)。
        // **api run と同じ規則・同じ文言**(RunRejectionParityTests が両者の一致を固定する)
        if profile == nil, fleet == nil, let target = runner, !MachineDispatch.isExplicitLocal(target) {
            throw ValidationError("--runner requires --profile")
        }
        if fleet != nil {
            if runner != nil { throw ValidationError("--fleet cannot be combined with --runner") }
            if profile != nil {
                throw ValidationError(
                    "--fleet cannot be combined with --profile (set profile per entry in the fleet file)")
            }
            if !ports.isEmpty { throw ValidationError("--fleet cannot be combined with --port") }
            if failed { throw ValidationError("--fleet cannot be combined with --failed") }
            if reportDir != nil { throw ValidationError("--fleet cannot be combined with --report-dir") }
            if skipBuild { throw ValidationError("--fleet cannot be combined with --skip-build") }
        }
        if split, fleet == nil {
            throw ValidationError("--split requires --fleet")
        }
        if broadcast {
            // 黙って無視しない(fleet の子へは中継していない。ports 経路にはレーンの名が無い)
            if fleet != nil { throw ValidationError("--broadcast cannot be combined with --fleet") }
            if profile == nil { throw ValidationError("--broadcast requires --profile") }
        }
        if forceLock, let message = RemoteDispatchFlagPolicy.forceLockRejection(
            host: runner, fleet: fleet, profile: profile) {
            throw ValidationError(message)
        }
        if let message = RemoteDispatchFlagPolicy.waitLockConflictsWithForceLock(
            forceLock: forceLock, waitLock: waitLock) {
            throw ValidationError(message)
        }
        // `--wait-lock` に前提条件は無い —— 手元の run も dispatch.lock を取るので待つ相手が居る
        // (理由と経緯は FTRemote.RemoteDispatchFlagPolicy の `--wait-lock` の節。`api run` と同じ)
    }

    func run() async throws {
        // `--set` は validate() で検証済み(未知キー・不正値は既に弾かれている)。
        // **デバイスに依存しない設定は `--profile` の有無に関わらず1つの経路で決まる**
        // (`DeviceIndependentRunSettings`)。`--profile` ありの経路は `ProfileResolver.resolve`
        // が同じ上書きをもう一度当てる(実プロファイルの値まで見えるので、ここでの計算は
        // その代わりにはならない ——ここは「プロファイルを経由しない env トグル」専用)。
        // BridgeClient(ホスト・サブプロセス両方)が FT_FAST_INPUT を読む
        let profileOverrides = try RunProfileSetOverride.parse(setOverrides)
        let noProfileSettings = DeviceIndependentRunSettings.resolve(
            DeviceIndependentRunSettings.profileLessBase.applyingOverrides(profileOverrides))
        RunEnvironment.apply(noProfileSettings)
        // リモート実行はここで打ち切る(以降はローカル実行の段取り。フラグはコマンドラインごと
        // リモートへ中継されるので、向こう側の fleetest が同じ env を自分で立てる)。
        // dry-run だけは送らない(--runner 明示・全台がリモートのプロファイルの自動のどちらも。
        // 理由と罠は RemoteDispatchGate の宣言。判定は resolveEffectiveDispatchTarget)
        // デバイスが複数の機械にまたがる実行プロファイルは、ホストごとのサブ実行へ分ける
        // (単一ディスパッチでは「そのホストに無いデバイス」が解決できない)。--runner 明示や
        // 全台が同じ機械なら nil が返り、従来の経路をそのまま通る
        if !dryRun, fleet == nil, let profile,
           let groups = try DeviceMachineRunner.plan(
               project: try ScenarioHost.project(named: project), profileName: profile,
               explicitHost: runner, deviceFilter: devices,
               disabledMachines: MachineEnablement.disabledMachines(config: LocalConfig.load())) {
            let exitCode = try await DeviceMachineRunner.run(
                project: try ScenarioHost.project(named: project), profileName: profile,
                groups: groups, scenarios: scenarios, folders: folders,
                setOverrides: profileOverrides, noLPT: noLPT, lptHistoryRuns: lptHistoryRuns,
                performanceMode: performanceMode, forceLock: forceLock, waitLock: waitLock,
                remoteDir: remoteDir, remoteTimeout: remoteTimeout,
                quiet: quiet, junit: junit,
                broadcast: broadcast, failed: failed, reportDir: reportDir)
            if exitCode != 0 { throw ExitCode(exitCode) }
            return
        }
        if !dryRun, let dispatch = try resolveEffectiveDispatchTarget(
        explicitTarget: runner, profile: profile, project: project,
            requireProfileMachine: true) {
            try await dispatchToRemoteHost(dispatch)
            return
        }
        // dry-run だけは送らない(--runner と同じ規律。RemoteDispatchGate の宣言参照)
        if let fleet, !dryRun {
            try await dispatchToFleet(fleet)
            return
        }
        PhaseLog.mark("start")
        // **この Mac のロックを、デバイスにもビルドにも触る前に取る**(ユーザー決定 2026-09-21
        // 「1つのマシンで同時に複数の run は走らせない」)。リモートへのディスパッチが
        // dispatch.lock で守っていた不変条件を、手元で直接打った run にも同じロックで掛ける。
        // **ビルドより前**に置くのは `swift build` 自体が重い負荷だから(CLAUDE.md
        // 「E2E 実行中に swift build を打たない」)。`--dry-run` はデバイスに触らないので取らない。
        // **run-lease(台ごと)との上下**: ここが**マシン全体**の門で、台ごとの二重使用は
        // この後の `ProfileRunner` / `RunLeaseGuard` が見る —— MCP のセッション
        // (`mcp-<鍵>.lease`)は dispatch.lock を取らないので、台ごとの調停はこのロックでは代替できない
        // **中断(SIGINT/SIGTERM/SIGHUP)の登録は、この Mac のロックを取るより前**(1プロセス1組。
        // .claude/rules/process-lifecycle.md「割り込みの登録は run の記録開始の直後・供給より前」)。recorder はまだ無い
        // (`RunRecorder.begin` はビルド後にしか作れない)ので nil で構築し、後で確定したら
        // `attachRecorder` で繋ぐ。setup.sh・供給は `ProfileRunner.run`/`runSequential`/
        // `runParallel` の内側でこの interruptState をそのまま受け取るので、ここで登録すれば
        // それらもカバーする(runParallel は orchestrator 構築後に attachLateSubscriber で合流する)
        let interruptState = RunInterruptState(recorder: nil)
        let interruptRelay = InterruptRelay.observing { interruptState.requestStop() }
        defer { interruptRelay.stop() }

        var dispatchLock: LocalDispatchLock.Holder?
        if !dryRun {
            // **待機中の中断は上で登録済みの interruptState をそのまま使う**(acquire() が自前で
            // 2つ目の InterruptRelay を立てない)
            dispatchLock = try LocalDispatchLock(
                runGroup: runGroup, waitLock: waitLock, forceLock: forceLock,
                log: { ConsoleOut.out($0) }
            ).acquire(interruptCheck: { interruptState.isStopped })
        }
        defer { dispatchLock?.release() }
        let testProject = try ScenarioHost.project(named: project)
        PhaseLog.mark("project-resolved")

        // run 進捗の記帳(docs/design.md §18.1)。**ビルドより前に1本書く** —— 実測でシナリオの
        // swift build から供給の記帳が出るまで ~15秒あり、書かないとその間ボードに1本も出ない。
        // 総本数・レーンはまだ未確定(total: 0・lanes: [])。`ProfileRunner.run` が同じ pid
        // ファイルを上書きする。**この build 呼び出しは ProfileRunner.swift の外(ここ)にある**
        // ので、「building」の書き手はここに置く。**後始末**: ProfileRunner.run へ到達できずに
        // 関数を抜けたら控えを消す
        let progressPid = ProcessInfo.processInfo.processIdentifier
        var progressHandedToProfileRunner = false
        let recordsProgress = profile != nil && !dryRun
        // 書き直しても**入口の時刻のまま**(経過が巻き戻らない)
        let progressStartedAt = ISO8601DateFormatter().string(from: Date())
        /// **段階は実際にやっていることだけを言う**(ユーザー決定 2026-09-22)—— 入口ではまだ
        /// ビルドしていない(`--skip-build` = 機械分担のローカル子なら最後までしない)ので
        /// "preparing" で始め、"building" は `ScenarioHost.build` を挟む間だけ立てて直後に戻す。
        func writeProgress(phase: String) {
            guard recordsProgress else { return }
            RunProgressLedger.write(RunProgressRecord(
                pid: progressPid, runID: nil, runGroup: nil, issuer: LocalConfig.resolveIssuerId(),
                project: testProject.name, profile: profile,
                startedAt: progressStartedAt, total: 0, done: 0, failed: 0,
                requeued: 0, laneDropouts: 0, etaSeconds: nil, lanes: [], phase: phase),
                directory: RunProgressLedger.directory())
        }
        if recordsProgress {
            RunProgressLedger.sweep(directory: RunProgressLedger.directory())
            writeProgress(phase: "preparing")
        }
        defer {
            if profile != nil, !dryRun, !progressHandedToProfileRunner {
                RunProgressLedger.remove(pid: progressPid, directory: RunProgressLedger.directory())
            }
        }

        // **ビルドの前にも中断を見る**(ロック取得〜ここまでの間に届いた分をここで拾う)
        if interruptState.isStopped {
            throw RunInterruptedBeforeStartError(phase: "before the scenario build")
        }
        // ビルドはホスト側で 1 回だけ(サブプロセスは自らビルドしない)
        if !skipBuild {
            writeProgress(phase: "building")
            ConsoleOut.out("→ Building scenarios (\(testProject.name))...")
            try ScenarioHost.build(project: testProject)
            writeProgress(phase: "preparing")
        } else {
            // 食い違っていても止めない(警告のみ。)
            ScenarioHost.warnIfSkipBuildStale(project: testProject) { ConsoleOut.out($0) }
        }
        // **ビルドの後にも中断を見る**(`ScenarioHost.build` は子の生死を確かめられず
        // `interruptState` に登録もしないので、ビルド中に届いた中断はここで初めて拾える ——
        // その間 swift build 自体は最後まで走ってしまう。この限界は直せていない)
        if interruptState.isStopped {
            throw RunInterruptedBeforeStartError(phase: "after the scenario build")
        }
        PhaseLog.mark("build")
        let all = try ScenarioHost.listForRun(project: testProject, dryRun: dryRun)
        PhaseLog.mark("scenario-list")
        guard !all.isEmpty else {
            throw ValidationError(
                "no scenarios (add a @TestClass under TestProjects/\(testProject.name)/scenarios/)")
        }
        var selected = try ScenarioSelection.resolve(scenarios, from: all, scenariosDir: testProject.scenariosDir)
        if scenarios.isEmpty {
            let deletedCount = all.filter(\.deleted).count
            if deletedCount > 0 {
                ConsoleOut.out("→ Excluded \(deletedCount) deleted (@Deleted) scenario(s)")
            }
            // deleted 側と二重計上しないよう、deleted も付いているものは deleted のほうで数える
            let draftCount = all.filter { $0.draft && !$0.deleted }.count
            if draftCount > 0 {
                ConsoleOut.out("→ Excluded \(draftCount) draft (@Draft) scenario(s)")
            }
        }
        if !folders.isEmpty {
            selected = try Self.filterByFolders(selected, folders: folders,
                                                scenariosDir: testProject.scenariosDir)
        }
        if failed {
            // (project, profile) 単位の記録。プロファイル無しの run は専用の区分
            // (LastResultsStore.noProfileKey)を読む。**リモート実行の分はここでは拾えない** ——
            // 手元でこの分岐へ来る時点でリモート/フリートへの分岐(dispatchToRemoteHost/
            // dispatchToFleet)は既に return 済みなので、`--failed` は常にこの機械での直近実行を見る。
            // リモートで落ちた分は RemoteRunDispatcher が回収した scenario JSON から書く
            let failedSet = LastResultsStore.failedIDs(project: testProject, profile: profile)
            selected = selected.filter { failedSet.contains($0.id) }
            guard !selected.isEmpty else {
                ConsoleOut.out("No scenarios failed last time (everything passed, or nothing has run)")
                return
            }
            ConsoleOut.out("→ Re-running the \(selected.count) scenario(s) that failed last time")
        }
        guard !selected.isEmpty else {
            ConsoleOut.out("Nothing to run (every scenario is marked @Deleted or @Draft)")
            return
        }
        // LPT 投入順の適用は実行経路ごとに行う(実効 platform が確定してからでないと
        // 別 platform の実績で並べてしまう): --profile は ProfileRunner.run、--port は runParallel。
        // 逐次実行は並列度が無いので並べ替えない
        let items = selected.map { ScenarioRunItem(info: $0) }

        // dry-run はデバイスにも FM にも触れないので、供給・接続・FM 診断・結果記録を全部飛ばす。
        // **RunRecorder を作らない**(実行していない結果を results DB と --failed の判断材料に
        // 混ぜないため。ScenarioHost も dryRun では LastResultsStore へ書かない)
        if dryRun {
            if let profile {
                // **使わなくても実在は確かめる** —— `api run` は同じ打鍵を「run profile not found」で
                // 断る(2実装で検査規則を揃える)。確かめないと打ち間違えたプロファイル名が dry-run を
                // 素通りし、デバイス実行で初めて落ちる
                let names = ProfileResolver.runProfileNames(project: testProject)
                guard names.contains(profile) else {
                    throw ProfileError.runProfileNotFound(name: profile, available: names)
                }
                ConsoleOut.out("ℹ️ --dry-run touches no device, so --profile is not used"
                      + " (--platform decides which ios { } / android { } blocks run)")
            }
            if runner != nil {
                ConsoleOut.out("ℹ️ --dry-run touches no device, so --runner is not used"
                      + " (the scenarios are validated locally, from the same source the remote would run)")
            }
            if let fleet {
                // プロファイルと同じく、使わなくても実在と形は確かめる(打ち間違いを素通りさせない)
                _ = try FleetProfile.load(project: testProject, name: fleet)
                ConsoleOut.out("ℹ️ --dry-run touches no device, so --fleet is not used"
                      + " (the scenarios are validated locally, from the same source every fleet entry would run)")
            }
            if !profileOverrides.isEmpty {
                ConsoleOut.out("ℹ️ --dry-run touches no device, so --set is not used"
                      + " (dry-run always runs with FM disabled)")
            }
            let failedCount = await runDryRun(items, project: testProject)
            ConsoleOut.out(failedCount == 0
                  ? "✅ All \(items.count) scenario(s) passed the dry-run"
                  : "❌ \(failedCount) of \(items.count) scenario(s) failed the dry-run")
            if failedCount > 0 { throw ExitCode(1) }
            return
        }

        // **availability(FMDoctor.check)では判定しない** —— `.available` のまま実呼び出しが
        // 全滅する状態が実在する(2026-07-22 実測)。判定は --profile 経路と同じ1箇所へ委ねる。
        //
        // **--profile のときはここで撃たない**(2026-09-03 の実 run で二重に出た)。あちらは
        // `ProfileRunner.run` が**プロファイルの実効トグル**で撃つので、ここで撃つと同じ警告が
        // 2行並ぶうえ、機能ごとのトグルを持たないこちらの既定のほうが情報として粗い。
        // プロファイル無しの run にはその呼び出し元が無いので、ここが唯一の口になる
        // (`--set` がデバイス一覧・録画基盤に依存するキーを持つかは validate() が既に検査済み)
        if profile == nil {
            await ProfileRunner.warnIfFMDegraded(fm: noProfileSettings.fm) { ConsoleOut.out($0) }
        }

        PhaseLog.mark("fm-doctor")
        let recorder = RunRecorder.begin(project: testProject, profile: profile, trigger: "cli",
                                         runGroup: runGroup)
        PhaseLog.mark("recorder-begin")
        // **interruptState はロック取得の直後(build より前)に登録済み**(このコメントより上、
        // dispatchLock の直前)。ここでは作った recorder を繋ぐだけ(`attachRecorder`。既に
        // 中断済みならその場で markInterrupted)
        interruptState.attachRecorder(recorder)

        if let profile {
            // 明示 --runner local はこの機械で走らせる指定なので、ホスト混在プロファイルでは
            // local 枠だけに絞る(他ホスト担当分まで手元で解決すると存在しない台を掴む。
            // マシン別サブ実行は --device/--device-machine を持つのでこの分岐に入らない)。
            // **明示 --device があっても絞る** —— 名前だけでは同名の台が別の機械にもあるとき
            // そちらのエントリに解決し、向こうの UDID を手元で探して
            // "no simulator with that UDID" で止まる(受け手報告 2026-08-24)。判定は
            // --runner <リモート> と同じ machineScopedDeviceFilter(RemoteDispatchExplicitDeviceScope)
            var effectiveDeviceFilter = devices
            var effectiveDeviceHost = deviceMachine
            if deviceMachine == nil, MachineDispatch.isExplicitLocal(runner) {
                (effectiveDeviceFilter, effectiveDeviceHost) = try machineScopedDeviceFilter(
                    project: testProject, profile: profile,
                    targetMachine: DeviceMachineGrouping.localDisplayName, requestedDevices: devices)
            }
            let runSummary: RunSummary
            let fmSettings: FMSettingsRecord
            progressHandedToProfileRunner = true
            do {
                (runSummary, fmSettings) = try await ProfileRunner.run(
                    project: testProject, profileName: profile, items: items,
                    setOverrides: profileOverrides,
                    reportDirOverride: reportDir,
                    quiet: quiet, lpt: !noLPT,
                    lptHistoryRuns: lptHistoryRuns ?? LPTOrdering.defaultHistoryRuns,
                    performanceMode: performanceMode,
                    deviceFilter: effectiveDeviceFilter,
                    deviceMachine: effectiveDeviceHost,
                    workspaceOverride: workspace,
                    recorder: recorder,
                    broadcast: broadcast,
                    interruptState: interruptState)
            } catch {
                // 供給段(ワーカー構築等)の例外は run.json を完了させずに投げていた
                // (finishedAt 無し = results insights が「クラッシュ/強制終了」に誤分類する)。
                // ここへ来るのは常にシナリオ実行が
                // 1本も始まる前なので、items 分すべて未実行という分かっている事実だけを記録する。
                // fmSettings は resolve 前で実効値が無いため noProfileSettings で近似する
                // (この run は abortReason 付きなので実効値の断定ではないと読み手に伝わる)
                recorder.finish(total: items.count, passed: 0, failed: items.count,
                                performanceMode: performanceMode,
                                fmSettings: FMSettingsRecord(
                                    heal: noProfileSettings.heal,
                                    textVisualCheck: noProfileSettings.fm.textVisualCheck,
                                    screenLooksLike: noProfileSettings.fm.screenLooksLike,
                                    ocrTextVisualCheck: noProfileSettings.ocrTextVisualCheck),
                                setOverrides: profileOverrides.mapValues(\.token),
                                abortReason: error.localizedDescription)
                throw error
            }
            let failedCount = runSummary.failed
            // **回した本数は items.count ではない** —— ProfileRunner が OS 対象外
            // (`@TestClass(platform:)` / `@Test(platform:)`)を投入前に外すので、
            // ここで items.count を使うと「12本全部成功」と出しつつ10本しか走っていない、になる
            let ranCount = runSummary.total
            // --broadcast の total は (本数 × 台数) なので items.count との差は対象外の数にならない
            // (対象外の件数は ProfileRunner が「Skipped N scenario(s) …」で出している)
            let notApplicable = broadcast ? 0 : items.count - ranCount
            PhaseLog.mark("profile-run-done")
            let slowWorkers = recorder.finish(total: ranCount, passed: ranCount - failedCount, failed: failedCount,
                            degradedWorkers: runSummary.degradedWorkers,
                            freezeRetries: runSummary.freezeRetries,
                            blankRepairs: runSummary.blankRepairs,
                            blankExclusions: runSummary.blankExclusions,
                            measurementInvalid: runSummary.measurementInvalid,
                            measurementInvalidReasons: runSummary.measurementInvalidReasons,
                            workerAnomalies: runSummary.workerAnomalies,
                            performanceMode: runSummary.performanceMode,
                            fmSettings: fmSettings,
                            setOverrides: profileOverrides.mapValues(\.token),
                            interrupted: runSummary.interrupted)
            PhaseLog.mark("recorder-finish")
            try writeJUnitIfRequested(project: testProject, recorder: recorder)
            // 保持容量の掃除は**結果を書き終えた後に背景の別プロセスで**(テストの実行時間に含めない)
            RunCompletionSweep.spawn(activeRunID: recorder.runID) { ConsoleOut.out($0) }
            let skippedSuffix = notApplicable > 0
                ? " (\(notApplicable) skipped: declared for another platform)" : ""
            // --broadcast は (シナリオ × デバイス) を数える。単位を言わないと「3本のはずが
            // 24 passed」に見える
            let unit = broadcast ? "scenario run(s) (one per scenario per device)" : "scenario(s)"
            ConsoleOut.out(failedCount == 0
                  ? "✅ All \(ranCount) \(unit) passed\(skippedSuffix)"
                  : "❌ \(failedCount) of \(ranCount) \(unit) failed\(skippedSuffix)")
            // **合否は変えず、劣化だけ伝える**。FM(vision 経路)が死んでいると occlusion-guard・
            // screenLooksLike が黙って素通りするので、緑は「守りが効いた緑」ではない。
            // **text 経路の死は言わない** —— run の中で text 経路を使う機能は無い
            // 赤のときも、切り分けの出発点として先に知りたい情報(自分の変更か FM か)
            //
            // 2つ出すのは根拠が別だから: 台帳(FMLiveness)は**この機械の FM の生死**で、
            // 呼び出しが0件でも言える。fmUnavailableScenarios は**実際に FM を引いて全滅した
            // シナリオ数**。前者だけだと「死んでいたが今回の run は FM を引かなかった」が
            // 同じ文になり、後者だけだと**ブレーカが落ちて1回も呼ばずに素通りした run で沈黙する**
            let fmReading = FMLiveness.current()
            if fmReading.deadPaths.contains("vision"), let reason = fmReading.deadSummary() {
                ConsoleOut.out("⚠️ FM is dead on this machine (\(fmReading.deadPaths.joined(separator: " + "))):"
                    + " a green here is not a guarded green — the occlusion-guard and"
                    + " screenLooksLike passed through silently."
                    + "\n   \(reason)")
            }
            if runSummary.fmUnavailableScenarios > 0 {
                ConsoleOut.out("⚠️ FM unavailable: \(runSummary.fmUnavailableScenarios) scenario(s) ran"
                    + " with occlusion-guard / screenLooksLike silently disabled."
                    + " Read this run's result with that in mind"
                    + " (confirm with: fleetest doctor --fm-only)")
            }
            // 台そのものが遅いことの観測(SlowWorkerDetector)。自動では何もしない・除外もしない
            for finding in slowWorkers { ConsoleOut.out(finding.consoleWarning) }
            if failedCount > 0 { throw ExitCode(1) }
            return
        }

        // `--report-dir` が優先(validate() が両方指定を既にエラーにしている)。次点は
        // `--set reportDir=`。`defaultTimeout`/`scenarioTimeout` はこの経路(RunScenarios)に
        // 専用フラグが無いため `--set` だけが口
        let reportDirPath = reportDir ?? noProfileSettings.reportDir ?? testProject.reportsDir.path
        // --set record=true の可否(単一接続では録画セッションが無い)は validate() が既に検査済み
        let iosPorts: [UInt16] = ports.isEmpty ? [BridgeAPI.defaultPort] : ports

        // record:true のときだけ VideoRecordingConfig を注入(--profile 経路と同じ形。
        // bitrate は --set recordBitrateKbps=... で上書きできる(既定は
        // VideoRecordingConfig.defaultBitrateKbps。effectiveRecordBitrateKbps が0以下を弾く)
        let recordingConfig: VideoRecordingConfig? = noProfileSettings.record
            ? VideoRecordingConfig(runDir: recorder.runDir, androidADBPath: try? AndroidDriver.findADB(),
                                   failuresOnly: noProfileSettings.recordFailuresOnly,
                                   bitrateKbps: RunProfileDocument.effectiveRecordBitrateKbps(
                                       noProfileSettings.recordBitrateKbps),
                                   fullResolution: noProfileSettings.recordFullResolution)
            : nil

        // 供給段の例外(AndroidDriver 初期化等)は run.json を完了させずに投げていた。
        // fmSettings は下の finish 呼び出しと同じ noProfileSettings 由来の値なので先に計算する
        let noProfileFMSettings = FMSettingsRecord(
            heal: noProfileSettings.heal,
            textVisualCheck: noProfileSettings.fm.textVisualCheck,
            screenLooksLike: noProfileSettings.fm.screenLooksLike,
            ocrTextVisualCheck: noProfileSettings.ocrTextVisualCheck)
        let failedCount: Int
        let interrupted: Bool
        do {
            if iosPorts.count <= 1 {
                (failedCount, interrupted) = try await runSequential(items, project: testProject,
                                                      port: iosPorts[0], reportDir: reportDirPath,
                                                      settings: ScenarioExecutionSettings(noProfileSettings),
                                                      homeOnStart: noProfileSettings.homeOnStart,
                                                      recorder: recorder, interruptState: interruptState)
            } else {
                (failedCount, interrupted) = await runParallel(items, project: testProject,
                                                iosPorts: iosPorts, reportDir: reportDirPath,
                                                settings: ScenarioExecutionSettings(noProfileSettings),
                                                homeOnStart: noProfileSettings.homeOnStart,
                                                recordingConfig: recordingConfig,
                                                recorder: recorder, interruptState: interruptState)
            }
        } catch {
            // 供給段の throw はここへ来る時点で
            // シナリオ実行が1本も始まっていない(total 分すべて未実行)
            recorder.finish(total: items.count, passed: 0, failed: items.count,
                            performanceMode: false, fmSettings: noProfileFMSettings,
                            setOverrides: profileOverrides.mapValues(\.token),
                            abortReason: error.localizedDescription)
            throw error
        }
        // --profile 無しの経路(runSequential/runParallel)は `--set` の上書きを当てた既定
        // ドキュメントの実効値(noProfileSettings)をそのまま使う(--profile 経路と同じ
        // DeviceIndependentRunSettings を通す。ProfileResolver.resolve の宣言参照)
        let slowWorkers = recorder.finish(total: items.count, passed: items.count - failedCount, failed: failedCount,
                        // --performance は --profile 専用(ヘルプ参照)。この経路は素通りするので false
                        performanceMode: false,
                        fmSettings: noProfileFMSettings,
                        setOverrides: profileOverrides.mapValues(\.token),
                        interrupted: interrupted)
        try writeJUnitIfRequested(project: testProject, recorder: recorder)
        RunCompletionSweep.spawn(activeRunID: recorder.runID) { ConsoleOut.out($0) }

        ConsoleOut.out(failedCount == 0
              ? "✅ All \(items.count) scenario(s) passed"
              : "❌ \(failedCount) of \(items.count) scenario(s) failed")
        // 台そのものが遅いことの観測(SlowWorkerDetector)。自動では何もしない・除外もしない
        for finding in slowWorkers { ConsoleOut.out(finding.consoleWarning) }
        if failedCount > 0 {
            throw ExitCode(1)
        }
    }

    /// `--runner` または(自動)全台が居るリモートの機械: ローカルビルド・実行をせず、対等ピア
    /// (SSH 到達可能な foundation-tester clone)に丸ごとディスパッチする
    /// (docs/remote-runner.md §3・§7・Phase 1)。デバイス割当競合を避けるためリモート1本での
    /// 実行のみサポートし、ローカル専用オプションは併用不可にする
    private func dispatchToRemoteHost(_ dispatch: EffectiveDispatchTarget) async throws {
        guard let profile else {
            throw ValidationError("--runner requires --profile")
        }
        // `--set` は向こうの子へそのまま中継する
        let dispatchOverrides = try RunProfileSetOverride.parse(setOverrides)
        // 拒否 or 注記の分岐は FTRemote.RemoteDispatchFlagPolicy に委譲(欠陥1)。origin が
        // 自動ディスパッチ(全台がリモート)なら --skip-build は注記のみで無視する
        // (リモートは常に自前でビルドする)。他の3つは自動でも意味を持たせられないため拒否のまま
        let origin = dispatch.origin
        if !ports.isEmpty {
            try applyFlagPolicy(RemoteDispatchFlagPolicy.rejected(flag: "--port", origin: origin))
        }
        if reportDir != nil {
            try applyFlagPolicy(RemoteDispatchFlagPolicy.rejected(flag: "--report-dir", origin: origin))
        }
        if failed {
            try applyFlagPolicy(RemoteDispatchFlagPolicy.rejected(flag: "--failed", origin: origin))
        }
        if skipBuild {
            try applyFlagPolicy(RemoteDispatchFlagPolicy.skipBuild(origin: origin))
        }

        let resolved = try resolveRemoteTarget(dispatch, remoteDirOverride: remoteDir)
        resolved.announce()
        let testProject = try ScenarioHost.project(named: project)
        let localRoot = try RepoRoot.find()
        let dispatcher = RemoteRunDispatcher(
            host: resolved.hostSpec, remoteDirRaw: resolved.remoteDirRaw, localRepoRoot: localRoot,
            forceLock: forceLock, waitLock: waitLock, hostLabel: dispatch.rawTarget)
        var scopedDevices = devices
        var scopedDeviceHost = deviceMachine
        if deviceMachine == nil {
            (scopedDevices, scopedDeviceHost) = try machineScopedDeviceFilter(
                project: testProject, profile: profile, targetMachine: dispatch.rawTarget,
                requestedDevices: devices)
        }
        let exitCode = try await dispatcher.dispatch(
            project: testProject, profile: profile, scenarios: scenarios, folders: folders,
            deviceNames: scopedDevices, deviceMachine: scopedDeviceHost,
            setOverrides: dispatchOverrides,
            noLPT: noLPT, lptHistoryRuns: lptHistoryRuns,
            performanceMode: performanceMode, broadcast: broadcast,
            localJUnitPath: junit, remoteTimeoutSeconds: remoteTimeout, runGroup: runGroup)
        if exitCode != 0 {
            throw ExitCode(exitCode)
        }
    }

    /// RemoteDispatchFlagPolicy.Decision の適用。注記は ConsoleOut 経由(print を使わない —
    /// RemoteRunDispatcher.log と同じ規律。stdout が端末でないと libc の行バッファが効かず
    /// 出力が遅延・欠落しうる。他の書き手とロックを共有するのでここだけ直書きにしない)
    private func applyFlagPolicy(_ decision: RemoteDispatchFlagPolicy.Decision) throws {
        switch decision {
        case .allowed:
            return
        case .ignoredWithNote(let note):
            ConsoleOut.out(note)
        case .rejected(let message):
            throw ValidationError(message)
        }
    }

    /// `--fleet`: profiles/fleets/<name>.json の全エントリを並行実行する(docs/remote-runner.md
    /// §13)。検証は投入前に全部済ませる(FleetProfile.validate)。実体は FleetRunner
    /// (エントリごとに子プロセスを起動し、出力を host 名で前置する)
    private func dispatchToFleet(_ fleetName: String) async throws {
        let testProject = try ScenarioHost.project(named: project)
        let doc = try FleetProfile.load(project: testProject, name: fleetName)
        let config = LocalConfig.load()
        let registeredNames = Set((config.remoteHosts ?? []).map(\.machine))
        let issues = FleetProfile.validate(doc, project: testProject, registeredHostNames: registeredNames)
        guard issues.isEmpty else {
            throw ValidationError((["fleet \"\(fleetName)\" is invalid:"] + issues.map { "  - \($0)" })
                .joined(separator: "\n"))
        }
        let (enabledDoc, skipped) = FleetRunner.excludingDisabledMachines(
            doc, disabled: MachineEnablement.disabledMachines(config: config))
        if !skipped.isEmpty {
            guard !enabledDoc.runs.isEmpty else {
                throw ValidationError(MachineEnablement.allDisabledMessage(
                    skipped, subject: "fleet \"\(fleetName)\" runs on"))
            }
            FleetRunner.log(MachineEnablement.skippedNotice(skipped))
        }
        let exitCode = try await FleetRunner.run(
            project: testProject, fleetName: fleetName, fleet: enabledDoc,
            scenarios: scenarios, folders: folders,
            setOverrides: try RunProfileSetOverride.parse(setOverrides),
            noLPT: noLPT, lptHistoryRuns: lptHistoryRuns, performanceMode: performanceMode,
            forceLock: forceLock, waitLock: waitLock, remoteDir: remoteDir, remoteTimeout: remoteTimeout,
            split: split, quiet: quiet, junit: junit)
        if exitCode != 0 {
            throw ExitCode(exitCode)
        }
    }

    /// --junit: run の記録(runDir/scenarios/*.json)から JUnit XML を書き出す。
    /// **ExitCode(1) を投げる前に呼ぶ**(失敗 run こそ CI がレポートを要る)。
    /// 書き込み失敗は run の成否を変えない(warn のみ。CI 側はファイル欠如で気付ける)
    private func writeJUnitIfRequested(project: TestProject, recorder: RunRecorder) throws {
        guard let junit else { return }
        let records = RunResultsStore.records(runDir: recorder.runDir)
        let xml = JUnitReportWriter.xml(project: project.name, records: records)
        let url = URL(fileURLWithPath: junit)
        do {
            try FileManager.default.createDirectory(
                at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try xml.write(to: url, atomically: true, encoding: .utf8)
            ConsoleOut.out("📄 JUnit report: \(junit) (\(records.count) testcase(s))")
        } catch {
            ConsoleOut.out("⚠️ Failed to write the JUnit report: \(junit) (\(error.localizedDescription))")
        }
    }

    /// --folder でシナリオを絞り込む(クラス名→ソースファイル→フォルダ名で照合)。
    /// 絞り込んだ結果が空、かつ未知のフォルダ名が含まれる場合はエラー
    static func filterByFolders(_ infos: [ScenarioInfo], folders: [String],
                                scenariosDir: URL) throws -> [ScenarioInfo] {
        let classFile = ScenarioFolders.classFileMap(scenariosDir: scenariosDir)
        let filtered = ScenarioFolders.filter(infos, byFolders: folders) { className in
            classFile[className].flatMap { ScenarioFolders.folderName(of: $0, scenariosDir: scenariosDir) }
        }
        if filtered.isEmpty {
            let available = ScenarioFolders.list(scenariosDir: scenariosDir)
            let unknown = folders.filter { !available.contains($0) }
            if !unknown.isEmpty {
                throw ValidationError(unknownFolderMessage(unknown: unknown, available: available))
            }
        }
        return filtered
    }

    /// available が空のとき "(available: )" と空括弧を出さない —— scenarios/ にサブフォルダが
    /// 無いので --folder という指定自体が使えないことを言う
    static func unknownFolderMessage(unknown: [String], available: [String]) -> String {
        let prefix = "folder not found: \(unknown.joined(separator: ", "))"
        guard !available.isEmpty else {
            return prefix + " (scenarios/ has no subfolders, so --folder cannot be used)"
        }
        return prefix + " (available: \(available.joined(separator: ", ")))"
    }

    /// ブリッジの /status(デバイス名)→ 起動中シミュレータの一意な同名から UDID を解決する。
    /// launch 事前検査(LaunchPreflightDriver)と FastLaunch 用。
    /// **プロファイル経路は provision の udid を渡すのでここを通らない** —— これは
    /// `--port` 直指定の経路だけの相関。
    ///
    /// 同名複数・未起動・応答なしは nil(検査なしで従来動作)だが、**黙って落とさない**:
    /// 事前検査が外れると、未インストールのまま launch して XCUITest ランナーが死ぬ経路
    /// (LaunchPreflightDriver のコメント)がそのまま開く。Xcode はランタイムごとに同名の
    /// シミュレータを作るので、同名2台は受け手環境で普通に起きる(2026-08-06 に実例)
    private static func resolveUdid(port: UInt16) async -> String? {
        guard let status = try? await PortDirectIOSTarget(port: port).makeDriver(timeoutSeconds: 5).status(),
              let catalog = try? SimulatorCatalog.devices() else { return nil }
        let matches = catalog.filter { $0.booted && $0.name == status.device }
        if matches.count == 1 { return matches[0].udid }
        ConsoleOut.err(
            "install preflight and fast launch are disabled:"
             + " \(matches.count) booted simulators are named \"\(status.device)\"."
             + " Launching an app that is not installed will kill the XCUITest runner."
             + " Use a run profile (--profile) to target a simulator by UDID.")
        return nil
    }

    // MARK: - 逐次実行(ライブ出力)

    /// dry-run(No-Load-Run): デバイスにも FM にも触れずステップを列挙・検証する。
    /// **レポートは一時ディレクトリへ書かせて捨てる** —— ランナーは dry-run でもレポートを書くので、
    /// 実行していない結果を reports/ に残すと results の集計と紛れる(`ScenarioHost.dryRunSteps`・
    /// MCP の `ft_dry_run` と同じ扱い。案内すると開けないパスを渡すことになるので report 行も落とす)。
    /// 接続情報は NullDriver 固定のため使われず、**platform だけが `ios { }` / `android { }` の
    /// 分岐と `#id` 台帳の照合に効く**。整形は MCP・サブプロセスと同じ `ScenarioLogFormatter`
    /// `--app-id` は platform 別に書き分けられないので両 platform に同じ値を配る
    /// (書き分けが要るなら実行プロファイルを使う)。nil なら空 = 子が明示エラーを出す
    static func appBundleIDs(_ app: String?) -> [String: String] {
        guard let app else { return [:] }
        return ["ios": app, "android": app]
    }

    private func runDryRun(_ items: [ScenarioRunItem], project: TestProject) async -> Int {
        let tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("fleetest-dryrun-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: tempDir) }

        var failedCount = 0
        for item in items {
            let platform = item.info.platform ?? resolvedPlatform
            // quiet: runSequential と同じ扱い(成功なら結果1行・失敗ならバッファ全体)
            var buffer: [String] = []
            let passed = await ScenarioHost.run(
                project: project, scenarioID: item.info.id,
                connection: DriverConnection(platform: platform),
                // **`enabled: false`(= 子へ --no-fm)**。デバイスも画面も無いので FM を引く経路を
                // まとめて止める(個別に切ると残った経路が FM の直列化待ちを払う)
                settings: ScenarioExecutionSettings(fm: FMConfig(enabled: false)),
                reportDir: tempDir.path,
                dryRun: true, appBundleID: appID) { event in
                let lines = ScenarioLogFormatter.lines(for: event)
                    .filter { !$0.contains("→ report:") }
                if quiet {
                    buffer.append(contentsOf: lines)
                } else {
                    for line in lines { ConsoleOut.out(line) }
                }
            }
            if quiet {
                ConsoleOut.out(passed ? "✅ \(item.info.id)" : "❌ \(item.info.id)")
                if !passed { ConsoleOut.out(buffer.joined(separator: "\n")) }
            }
            if !passed { failedCount += 1 }
        }
        return failedCount
    }

    private func runSequential(_ items: [ScenarioRunItem], project: TestProject,
                               port: UInt16, reportDir: String,
                               settings: ScenarioExecutionSettings,
                               homeOnStart: Bool,
                               recorder: RunRecorder?, interruptState: RunInterruptState
    ) async throws -> (failed: Int, interrupted: Bool) {
        // 次のシナリオへ進まず、今動いている子(fleetest-scenarios)を SIGTERM してから
        // 普通に return する(呼び出し元の通常の完了経路をそのまま通す。ApiRunCommand.runDirect
        // と同じ形)。**登録は呼び出し元(run())が供給の前に済ませている**
        let iosUdid = await Self.resolveUdid(port: port)
        // homeOnStart は「run 開始時に1回」の予防措置(ProfileWorkerFactory.pressHomeOnStart)。
        // この経路は毎シナリオでワーカーを組み直すので、実際に使う platform 分の使い捨てワーカーを
        // ループの前で1回だけ組んで渡す(ループ側の実行用インスタンスとは別物)
        let platformsInUse = Set(items.map { $0.info.platform ?? resolvedPlatform })
        var primingWorkers: [RunWorker] = []
        if platformsInUse.contains("ios") {
            // 宛先・token・実機判定は記録から(PortDirectIOSTarget)。**子プロセスへも同じ宛先を
            // 渡す**(DriverConnection.host → `--bridge-host`)。片方だけだと親は繋がるのに
            // 子だけ接続拒否になる
            primingWorkers.append(
                PortDirectIOSTarget(port: port).makeWorker(label: "ios", simulatorUDID: iosUdid))
        }
        if platformsInUse.contains("android"), let driver = try? AndroidDriver(serial: serial) {
            primingWorkers.append(RunWorker(
                label: "android", platform: "android", driver: driver,
                connection: DriverConnection(platform: "android", serial: serial)))
        }
        await ProfileWorkerFactory.prepareDevicesOnStart(
            primingWorkers, homeOnStart: homeOnStart) { ConsoleOut.out($0) }

        var failedCount = 0
        for (index, item) in items.enumerated() {
            if interruptState.isStopped {
                // 始まらなかった分を記録して失敗に数える(RunRecorder.recordInterruptedBeforeStart)
                let notStarted = items[index...].map(\.info)
                recorder?.recordInterruptedBeforeStart(notStarted, defaultPlatform: resolvedPlatform)
                failedCount += notStarted.count
                break
            }
            let platform = item.info.platform ?? resolvedPlatform
            let driver: AppDriver
            let connection: DriverConnection
            if platform == "android" {
                driver = try AndroidDriver(serial: serial)
                connection = DriverConnection(platform: "android", serial: serial)
            } else {
                let target = PortDirectIOSTarget(port: port)
                driver = target.makeDriver()
                connection = target.connection(simulatorUDID: iosUdid)
            }
            _ = try await driver.status()
            let worker = RunWorker(label: platform, platform: platform,
                                   driver: driver, connection: connection)
            // quiet: 全行をバッファし、成功なら結果1行のみ・失敗ならバッファ全体(失敗詳細)を出す
            var buffer: [String] = []
            let outcome = await ScenarioRunner.runOne(
                project: project, item: item, worker: worker, settings: settings,
                reportDir: URL(fileURLWithPath: reportDir),
                recorder: recorder,
                appBundleID: appID,
                registerChildProcess: { interruptState.registerChildProcess($0) }) { event in
                let lines = RunLogFormatter.lines(for: event)
                if quiet {
                    buffer.append(contentsOf: lines)
                } else {
                    for line in lines { ConsoleOut.out(line) }
                }
            }
            if quiet {
                if outcome == .passed {
                    ConsoleOut.out("✅ \(item.info.id)")
                } else {
                    ConsoleOut.out("❌ \(item.info.id)")
                    ConsoleOut.out(buffer.joined(separator: "\n"))
                }
            }
            if outcome != .passed { failedCount += 1 }
        }
        return (failedCount, interruptState.isStopped)
    }

    // MARK: - 並列実行(iOS はポート毎のワーカー、Android は専用ワーカー)

    private func runParallel(_ rawItems: [ScenarioRunItem], project: TestProject,
                             iosPorts: [UInt16], reportDir: String,
                             settings: ScenarioExecutionSettings,
                             homeOnStart: Bool,
                             recordingConfig: VideoRecordingConfig?,
                             recorder: RunRecorder?, interruptState: RunInterruptState
    ) async -> (failed: Int, interrupted: Bool) {
        let defaultPlatform = resolvedPlatform
        let items = LPTOrdering.apply(rawItems, project: project, defaultPlatform: defaultPlatform,
                                      enabled: !noLPT,
                                      historyRuns: lptHistoryRuns ?? LPTOrdering.defaultHistoryRuns,
                                      log: { ConsoleOut.out($0) })
        let androidItems = items.filter { ($0.info.platform ?? defaultPlatform) == "android" }
        let portList = iosPorts.map(String.init).joined(separator: ", ")
        ConsoleOut.out("🚀 Parallel run: \(iosPorts.count) iOS worker(s) (port: \(portList))"
              + (androidItems.isEmpty ? "" : " + 1 Android worker") + "\n")

        var workers: [RunWorker] = []
        for port in iosPorts {
            let udid = await Self.resolveUdid(port: port)
            workers.append(PortDirectIOSTarget(port: port).makeWorker(label: "ios:\(port)",
                                                                      simulatorUDID: udid))
        }
        if !androidItems.isEmpty {
            if let driver = try? AndroidDriver(serial: serial) {
                workers.append(RunWorker(label: "android", platform: "android", driver: driver,
                                         connection: DriverConnection(platform: "android",
                                                                      serial: serial)))
            } else {
                ConsoleOut.out("❌ Cannot initialise the Android driver (adb not found)")
                // ワーカー不在の android シナリオは orchestrator が flowSkipped(失敗扱い)にする
            }
        }

        // 一斉 launch 直後の黒画面を作らないための予防(ProfileRunner.run と同じ呼び出し)
        await ProfileWorkerFactory.prepareDevicesOnStart(
            workers, homeOnStart: homeOnStart) { ConsoleOut.out($0) }

        // ApiRunCommand.runWithProfileParallel / ProfileRunner.run と同じ形。
        // **interruptState は呼び出し元(run())が供給の前から持っている** —— ここで新しく
        // 作ると供給中(上の prepareDevicesOnStart 等)に届いた中断を取りこぼす
        let orchestrator = RunOrchestrator(project: project, workers: workers,
                                           settings: settings,
                                           reportDir: URL(fileURLWithPath: reportDir),
                                           recorder: recorder,
                                           recordingConfig: recordingConfig,
                                           // このパス(プロファイル無し run)は writeRunProgress を
                                           // 注入しない(docs/design.md §18.1: 注入は2経路だけ)ので
                                           // 残り見積もりの実績も読まれない。値自体は LPTOrdering.apply
                                           // (直前)と揃える —— 将来ここへ注入するときに窓がズレない
                                           progressHistoryRuns: lptHistoryRuns ?? LPTOrdering.defaultHistoryRuns,
                                           appBundleIDs: Self.appBundleIDs(appID),
                                           registerChildProcess: { interruptState.registerChildProcess($0) })
        // **新しい InterruptRelay は登録しない**(1プロセス1組)。供給中に既に中断済みなら
        // ここで即 orchestrator.requestInterrupt() が呼ばれる
        interruptState.attachLateSubscriber { orchestrator.requestInterrupt() }
        async let summary = orchestrator.run(items: items, defaultPlatform: defaultPlatform)

        // シナリオ毎にバッファして完了時に一括表示(並列時のステップ行の混線防止)。
        // quiet: 成功シナリオは結果1行のみ・失敗シナリオはバッファ全体(失敗詳細)を出す
        var buffers: [URL: [String]] = [:]
        var names: [URL: String] = [:]
        for await event in orchestrator.events {
            let lines = RunLogFormatter.lines(for: event)
            switch event {
            case .flowStarted(_, let url, let flowName, _):
                names[url] = flowName
                buffers[url, default: []].append(contentsOf: lines)
            case .step(_, let url, _), .flowHealed(_, let url):
                buffers[url, default: []].append(contentsOf: lines)
            case .flowFinished(_, let url, let passed, _, _):
                let all = (buffers.removeValue(forKey: url) ?? []) + lines
                if quiet {
                    ConsoleOut.out(passed ? "✅ \(names[url] ?? url.lastPathComponent)"
                                 : "❌ \(names[url] ?? url.lastPathComponent)\n" + all.joined(separator: "\n"))
                } else {
                    ConsoleOut.out(all.joined(separator: "\n"))
                }
            default:
                if !lines.isEmpty { ConsoleOut.out(lines.joined(separator: "\n")) }
            }
        }
        let result = await summary
        return (result.failed, result.interrupted)
    }
}

