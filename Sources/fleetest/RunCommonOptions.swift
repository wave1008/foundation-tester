// `fleetest run`(RunScenarios)と `fleetest api run`(ApiRunCommand)が共有するオプション宣言と、
// 両者に重複していた validate() の規則。**片方だけに足す事故を防ぐ置き場** —— 共通の規則はここ、
// コマンド固有の規則(--scenario・--port の個数・timeouts・--fleet 等)は各 validate() に残す。
// 両者のフラグ集合の差は RunCommandFlagParityTests が固定する。
//
// **validate() の評価順序は2コマンドで違う**(run は --set の検査が platform/profile の検査より前・
// api run は後。api run は --port の個数と timeouts の検査が規則の間に挟まる)。1つの関数にまとめると
// 1打鍵で複数の規則に当たったときの最初のエラーが変わるので、規則の塊ごとの関数にして
// 各 validate() が従来の順序で呼ぶ。

import ArgumentParser
import FTCore

struct RunCommonOptions: ParsableArguments {
    @Option(help: "Test project name (defaults to the only one in TestProjects/, or the default project)")
    var project: String?

    @Option(help: "Run profile name (profiles/runs/<name>.json). Includes device provisioning and auto-install. Cannot be combined with --platform/--port/--serial/--app-id")
    var profile: String?

    @Flag(name: .customLong("skip-build"), help: "Skip the swift build before running")
    var skipBuild = false

    @Flag(name: .customLong("no-lpt"),
          help: "Disable LPT ordering (longest past runtime first) and dispatch in scenario ID order")
    var noLPT = false

    @Option(name: .customLong("lpt-history-runs"),
            help: "Number of past runs to read for LPT ordering (newest first, default 5)")
    var lptHistoryRuns: Int?

    /// `platform` は non-Optional にしない —— 既定値を持たせると「指定された」と「既定のまま」が
    /// 区別できず、`--profile` との併用禁止のような検査ができなくなる(DriverOptions と同じ規律)。
    /// 省略時の推定は各コマンドの `resolvedPlatform`(`DeviceTargetConsistency.defaultPlatform`)
    @Option(help: "Target platform: ios / android (default ios; cannot be combined with --profile)")
    var platform: String?

    @Option(help: "Android device serial (adb -s; defaults to the only connected device. Cannot be combined with --profile)")
    var serial: String?

    /// 実行プロファイル無しで回すときのアプリの指定。--profile があればそちらのアプリプロファイルから
    /// 解決されるので併用不可。**2コマンドで揃える** —— 「app が解決できない」のエラーは --app-id を勧めるが、
    /// 拡張は api run を使うので、片方に無いと「言われたとおりにしたらオプションが無い」で行き止まりになる
    @Option(name: .customLong("app-id"),
            help: "Default app (bundle ID / package name) for runs without --profile. Cannot be combined with --profile (the app profile supplies the bundle ID)")
    var appID: String?

    @Option(name: .customLong("remote-dir"),
            help: "Runner-only base directory on the remote host (holds its own clone and workspace; default: the host registry's entry, or ~/fleetest-runner). Must NOT point at an existing local install of foundation-tester")
    var remoteDir: String?

    @Option(name: .customLong("remote-timeout"),
            help: "Timeout in seconds for the whole remote dispatch (default: auto, sized from the scenario count; see docs/user-docs/fleet/remote_runners.md)")
    var remoteTimeout: Int?

    @Option(name: .customLong("device"), parsing: .upToNextOption,
            help: ArgumentHelp("Run on only these devices of the run profile (device names as written in "
                + "the run profile). Repeatable; defaults to every device the run profile lists. "
                + "Used by the per-host sub-runs when one run profile spans devices on several machines"))
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

    /// `--device <name>` の名前が実行プロファイルの2つ以上の機械に当たるとき、黙って全機械で
    /// 回ってしまう既定を明示させる口(RunDeviceMachineAmbiguity。run と api run で共有)。
    /// 無指定・--runner/--device-machine 無指定でその状況になったら実行前に断る(各 run() 参照)
    @Flag(name: .customLong("all-machines"),
          help: ArgumentHelp("Run on every machine a --device name matches, instead of refusing "
            + "when it matches devices on more than one machine (the previous default behavior). "
            + "Cannot be combined with --runner/--device-machine (those already restrict the run "
            + "to one machine)"))
    var allMachines = false

    /// 同じ実行から分かれた run を束ねる鍵(FTCore.RunMetaRecord.runGroup)。**発行は
    /// マシン別サブ実行の親だけ**で、子は受け取った値をそのまま run.json に書く(自分で作らない)。
    /// 手で打つものではない
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
}

// MARK: - 共通の検査(文言は RunRejectionParityTests が両コマンドの一致を固定する)

extension RunCommonOptions {
    /// 判定は DriverOptions の1箇所。両 validate() の先頭
    static func rejectZeroPorts(_ ports: [UInt16]) throws {
        try ports.forEach { try DriverOptions.rejectZeroPort($0) }
    }

    /// `--platform` の値の検査と、`--profile` との併用禁止(platform/port/serial/app-id)。
    /// `--platform` は dry-run でも検証する(`ios{}`/`android{}` の選択に直結するので、
    /// 大文字違い等が黙って両方を実行してしまう)。ports はコマンド固有の宣言なので引数で受ける
    func validateTargeting(ports: [UInt16]) throws {
        if let platform, !RunWorker.knownPlatforms.contains(platform) {
            throw ValidationError("--platform must be one of "
                + "\(RunWorker.knownPlatforms.sorted().joined(separator: "/")): \(platform)")
        }
        if profile != nil && (platform != nil || !ports.isEmpty || serial != nil) {
            throw ValidationError("--profile cannot be combined with --platform/--port/--serial")
        }
        if profile != nil && appID != nil {
            throw ValidationError("--app-id cannot be combined with --profile (the app profile supplies the bundle ID)")
        }
    }

    /// `--performance` は --profile が要る。`hasFleet`: `--fleet` を持つのは run だけ(各エントリが
    /// 自分の --profile を持つので run は --fleet でもよい)。api run は false を渡す。
    /// 文言は `acceptsFleet` で決まる(run: "--profile or --fleet" / api run: "--profile")
    func validatePerformance(performanceMode: Bool, hasFleet: Bool, acceptsFleet: Bool) throws {
        if performanceMode, profile == nil, !hasFleet {
            throw ValidationError(acceptsFleet
                ? "--performance requires --profile or --fleet"
                : "--performance requires --profile")
        }
    }

    /// 明示 `--runner`("local" を除く)は --profile が無いと dispatchToRemoteHost の冒頭で必ず落ちる。
    /// デバイスの machine による自動ディスパッチは --profile がある側でしか見ないので、ここは引数だけから
    /// 決まる(ファイル I/O が要らない = validate() に置ける)。`hasFleet`: run だけ(各エントリが自分の
    /// --profile を持つので「プロファイル無し」判定は誤り)。続けて `--all-machines` の併用検査
    func validateRunnerAndMachines(runner: String?, hasFleet: Bool) throws {
        if profile == nil, !hasFleet, let target = runner, !MachineDispatch.isExplicitLocal(target) {
            throw ValidationError("--runner requires --profile")
        }
        if let message = RunDeviceMachineAmbiguity.allMachinesConflictMessage(
            allMachines: allMachines, runner: runner, deviceMachine: deviceMachine) {
            throw ValidationError(message)
        }
    }

    /// `--set` のパース → 専用フラグとの衝突 → `--profile` 無し(かつ dry-run でも fleet 経由でもない)ときの
    /// profile-only キーと record の拒否、をこの順で行う。
    /// - `flagCollisions`: 同じキーを持つ専用フラグの組(run は `--report-dir` だけ・api run は
    ///   `--report-dir`/`--default-timeout`/`--scenario-timeout`)。黙ってどちらかを勝たせない
    /// - `hasFleet`: run だけ(`--fleet` のときは各エントリが自分の --profile を持つので除く)
    /// - `hasRecordingSession` / `recordRejection`: 録画セッションを持つ経路かと、持たないときの文言
    ///   (run は `--port` が2つ以上なら RunOrchestrator 経由で録画できる・api run の runDirect は常に持たない)
    /// - dry-run はデバイスにも録画にも触れないので `--set` はそもそも使われない(profile-only キーを
    ///   dry-run で試すだけの打鍵を止めない)
    @discardableResult
    func validateSet(setOverrides: [String],
                     flagCollisions: [(flag: String, key: String, isSet: Bool)],
                     hasFleet: Bool, dryRun: Bool,
                     hasRecordingSession: Bool, recordRejection: String) throws -> [String: RunProfileSetValue] {
        let parsed: [String: RunProfileSetValue]
        do { parsed = try RunProfileSetOverride.parse(setOverrides) }
        catch { throw ValidationError(error.localizedDescription) }
        for (flag, key, isSet) in flagCollisions {
            if let message = RunProfileDocument.flagOverrideCollision(
                flag: flag, key: key, flagIsSet: isSet, overrides: parsed) {
                throw ValidationError(message)
            }
        }
        if profile == nil, !hasFleet, !dryRun {
            let unsupported = Set(parsed.keys).intersection(RunProfileDocument.profileOnlyKeys).sorted()
            guard unsupported.isEmpty else {
                throw ValidationError("--set \(unsupported.joined(separator: ", ")) needs --profile"
                    + " (there are no devices from a run profile to apply"
                    + " \(unsupported.count == 1 ? "it" : "them") to)")
            }
            if RunProfileDocument.recordNeedsRejecting(
                record: Self.noProfileSettings(overrides: parsed).record,
                hasRecordingSession: hasRecordingSession) {
                throw ValidationError(recordRejection)
            }
        }
        return parsed
    }

    /// `--set` を適用した「デバイスに依存しない実効設定」(FTCore.DeviceIndependentRunSettings)。
    /// 呼び手は `--set` を検証済み(不正なトークンは validate() が先に落とす)という前提で `try?` にしている
    static func noProfileSettings(setOverrides: [String]) -> DeviceIndependentRunSettings {
        noProfileSettings(overrides: (try? RunProfileSetOverride.parse(setOverrides)) ?? [:])
    }

    static func noProfileSettings(overrides: [String: RunProfileSetValue]) -> DeviceIndependentRunSettings {
        DeviceIndependentRunSettings.resolve(
            DeviceIndependentRunSettings.profileLessBase.applyingOverrides(overrides))
    }
}
