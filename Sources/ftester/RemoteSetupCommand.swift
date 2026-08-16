// RemoteSetupCommand.swift
// `ftester remote setup` / `ftester remote exec` (docs/remote-runner.md §14)。
// 純粋ロジックは Sources/FTCore/RemoteSetup.swift 側(RemoteSetupPlan、単体テスト対象)。
// ssh の張り方は Sources/ftester/RemoteRunDispatcher.swift・RemoteCommands.swift と同じ規律
// (BatchMode=yes・ConnectTimeout=10)だが、そちらは private のため複製する。

import ArgumentParser
import Darwin
import FTBridgeClient
import FTCore
import Foundation

private let setupSSHBase = ["ssh", "-o", "BatchMode=yes", "-o", "ConnectTimeout=10"]
private let setupSCPBase = ["scp", "-o", "BatchMode=yes", "-o", "ConnectTimeout=10"]

/// 進行の1行出力。**print は使わない** —— stdout が端末でないとき libc の行バッファが効かず、
/// 分単位かかる install/align の進行が最後まで出ない(ログへリダイレクトすると「止まったのか
/// 進んでいるのか」が判らない)。RemoteRunDispatcher.log の cliRun 側と同じ規律
private func say(_ message: String) {
    FileHandle.standardOutput.write(Data((message + "\n").utf8))
}

/// ssh/scp をそのまま実行して stdout/stderr を継承する(RemoteRunDispatcher.runInherited と
/// 同じ規律だが private のため複製する)。preflight/install/align は数分かかり得るため、
/// 出力をバッファせずその場で流す(受け手側スクリプトの逐次表示をそのまま見せる)
private func runInheritedSSH(_ argv: [String]) throws -> Int32 {
    let process = Process()
    process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
    process.arguments = argv
    process.standardOutput = FileHandle.standardOutput
    process.standardError = FileHandle.standardError
    let waitForExit = ProcessExitWait.prepareBlocking(process)
    try process.run()
    waitForExit()
    return process.terminationStatus
}

extension RemoteCommand {

    struct Setup: AsyncParsableCommand {
        static let configuration = CommandConfiguration(
            commandName: "setup",
            abstract: "Provision a remote Mac to receive --host dispatches (idempotent)",
            discussion: "Steps: local → reach → preflight → install → align → machine → verify "
                + "(docs/remote-runner.md §14). Exit codes match install.sh: "
                + "0 = done / 2 = stopped with steps left for a human / 1 = failed.")

        @Argument(help: "Remote host to set up (user@host or host)")
        var host: String

        @Option(name: .customLong("remote-dir"),
                help: "Runner-only base directory on the remote host (default: ~/ftester-runner)")
        var remoteDir: String = "~/ftester-runner"

        // ArgumentHelp は文字列**リテラル**からしか作れない(連結した String は渡せない)。
        // 長い説明は ArgumentHelp(...) で明示的に包む
        @Option(help: ArgumentHelp("Project name to install on the remote (default: the local project resolution — "
            + "the only TestProjects/ entry, or LocalConfig.defaultProject)"))
        var project: String?

        @Option(help: ArgumentHelp("Register this name as the remote's machine profile (ftester machine set). "
            + "Omit to leave the remote's existing registration untouched"))
        var machine: String?

        @Option(help: ArgumentHelp("Run profile for the verification dispatch. Setup is not confirmed working "
            + "until one real dispatch passes (docs/remote-runner.md §14, decision 3)"))
        var profile: String?

        @Option(help: "Scenario ID to run for verification (defaults to the whole --profile)")
        var scenario: String?

        @Flag(name: .customLong("skip-verify"), help: "Skip the verification dispatch")
        var skipVerify = false

        @Flag(help: ArgumentHelp("Delete the remote base directory instead of installing "
            + "(destructive; asks for confirmation unless --yes)"))
        var uninstall = false

        @Flag(help: "Do not prompt for confirmation before --uninstall")
        var yes = false

        func validate() throws {
            guard uninstall else { return }
            if project != nil || machine != nil || profile != nil || scenario != nil || skipVerify {
                throw ValidationError(
                    "--uninstall does not use --project/--machine/--profile/--scenario/--skip-verify")
            }
        }

        func run() async throws {
            try RemoteLayout.validateBase(remoteDir)
            let hostSpec = try RemoteHostSpec.parse(host)

            var recorded: [(name: String, status: RemoteSetupStepStatus, detail: String)] = []
            func emit(_ name: String, _ status: RemoteSetupStepStatus, _ detail: String) {
                recorded.append((name, status, detail))
                say(RemoteSetupStepLine.render(name: name, status: status, detail: detail))
            }
            // 常にここへ落とす: 途中で止まった場合も含め、最後に必ず集計を出す
            // (CLAUDE.md「画面は各ステップ1行(逐次)+ 集計だけ」)。ExitCode を投げて終わるので
            // 呼び出し側に return は要らない(Never)
            func summarizeAndExit() throws -> Never {
                say("")
                say("──────── remote setup results ────────")
                say(RemoteSetupSummary(statuses: recorded.map(\.status)).line)
                for step in recorded where step.status == .warn || step.status == .fail {
                    say(RemoteSetupStepLine.render(name: step.name, status: step.status, detail: step.detail))
                }
                // install.sh と同じ終了コードの語彙(0=完了 / 2=必須は通ったが未完の項目がある /
                // 1=必須で停止)。**warn を 0 にしない** —— preflight の needs-manual や
                // 検証ディスパッチ未実施はここで止まっており、0 を返すと呼び出し側が完了と読む
                if recorded.contains(where: { $0.status == .fail }) { throw ExitCode(1) }
                throw ExitCode(recorded.contains(where: { $0.status == .warn }) ? 2 : 0)
            }

            // ローカル側の前提はネットワークより先に解く。後ろに置くと、--project の指定漏れが
            // ssh 往復とリモートの preflight を払った後に「install の失敗」として現れる
            var localPrerequisites: (repoRoot: URL, project: TestProject)?
            if !uninstall {
                guard let repoRoot = try? RepoRoot.find() else {
                    emit("local", .fail,
                         "cannot resolve the local tool root (run this inside the foundation-tester repo)")
                    try summarizeAndExit()
                }
                do {
                    localPrerequisites = (repoRoot, try ScenarioHost.project(named: project))
                } catch {
                    emit("local", .fail, "cannot resolve the local project: \(error.localizedDescription)")
                    try summarizeAndExit()
                }
                emit("local", .ok, "project \(localPrerequisites!.project.name)")
            }

            say("==> reach: checking \(hostSpec.sshTarget)...")
            let (session, home, reachError) = Self.reach(hostSpec: hostSpec)
            guard let home else {
                emit("reach", .fail, reachError ?? "unreachable")
                try summarizeAndExit()
            }
            if let session {
                guard session.isLoggedIn else {
                    emit("reach", .fail,
                         "\(hostSpec.sshTarget) is sitting at the login window (console user: "
                         + "\(session.consoleUser), expected: \(session.sshUser)) — unlock and log in on the "
                         + "runner, then retry (docs/remote-runner.md §5)")
                    try summarizeAndExit()
                }
                emit("reach", .ok, "reachable, logged in as \(session.sshUser)")
            } else {
                emit("reach", .warn, "could not determine the remote console login state — skipping the login check")
            }

            let layout = RemoteLayout(base: RemoteLayout.resolveBase(remoteDir, home: home))

            if uninstall {
                do {
                    try RemoteSetupPlan.validateUninstallBase(layout.base, home: home)
                } catch {
                    emit("uninstall", .fail, error.localizedDescription)
                    try summarizeAndExit()
                }
                guard confirmUninstall(base: layout.base, host: hostSpec.sshTarget) else {
                    emit("uninstall", .fail, "cancelled (pass --yes to skip the confirmation prompt)")
                    try summarizeAndExit()
                }
                say("==> uninstall: deleting \(layout.base) on \(hostSpec.sshTarget)...")
                let command = RemoteSetupPlan.uninstallCommand(base: layout.base)
                let status = (try? runInheritedSSH(setupSSHBase + [hostSpec.sshTarget, command])) ?? -1
                if status == 0 {
                    emit("uninstall", .ok, "deleted \(layout.base)")
                } else {
                    emit("uninstall", .fail, "rm exited with status \(status)")
                }
                try summarizeAndExit()
            }

            // uninstall は上で return するので、ここに来た時点で必ず解決済み
            let (repoRoot, resolvedProject) = localPrerequisites!

            let stamp = "\(Int(Date().timeIntervalSince1970))-\(ProcessInfo.processInfo.processIdentifier)"

            // MARK: preflight

            say("==> preflight: copying and running Scripts/preflight.sh --runner on \(hostSpec.sshTarget)...")
            let localPreflight = repoRoot.appendingPathComponent("Scripts/preflight.sh").path
            let remotePreflight = "/tmp/ftester-remote-setup-\(stamp)-preflight.sh"
            let preflightScpStatus = (try? runInheritedSSH(
                setupSCPBase + [localPreflight, "\(hostSpec.sshTarget):\(remotePreflight)"])) ?? -1
            guard preflightScpStatus == 0 else {
                emit("preflight", .fail, "failed to copy Scripts/preflight.sh to the remote (scp exited \(preflightScpStatus))")
                try summarizeAndExit()
            }
            let preflightCmd = RemoteSetupPlan.runAndCleanupCommand(
                remotePath: remotePreflight, args: RemoteSetupPlan.preflightArgs(base: layout.base))
            let preflightStatus = (try? runInheritedSSH(setupSSHBase + [hostSpec.sshTarget, preflightCmd])) ?? -1
            switch RemoteSetupPlan.preflightVerdict(exitCode: preflightStatus) {
            case .ready:
                emit("preflight", .ok, "ready")
            case .needsManual:
                emit("preflight", .warn, "needs manual steps on the remote (see output above) — fix them, "
                    + "then re-run `ftester remote setup` (it is idempotent)")
                try summarizeAndExit()
            case .blocked:
                emit("preflight", .fail, "blocked (see output above)")
                try summarizeAndExit()
            case .unknown(let code):
                emit("preflight", .fail, "unexpected exit code \(code) (see output above)")
                try summarizeAndExit()
            }

            // MARK: install

            say("==> install: copying and running Scripts/install.sh on \(hostSpec.sshTarget)"
                + " (first run can take several minutes)...")
            let mkdirStatus = (try? Shell.run(
                setupSSHBase + [hostSpec.sshTarget, RemoteSetupPlan.ensureWorkDirCommand(layout: layout)]))?.status ?? -1
            guard mkdirStatus == 0 else {
                emit("install", .fail, "could not create \(layout.workDir) on the remote (mkdir exited \(mkdirStatus))")
                try summarizeAndExit()
            }
            let localInstall = repoRoot.appendingPathComponent("Scripts/install.sh").path
            let remoteInstall = "/tmp/ftester-remote-setup-\(stamp)-install.sh"
            let installScpStatus = (try? runInheritedSSH(
                setupSCPBase + [localInstall, "\(hostSpec.sshTarget):\(remoteInstall)"])) ?? -1
            guard installScpStatus == 0 else {
                emit("install", .fail, "failed to copy Scripts/install.sh to the remote (scp exited \(installScpStatus))")
                try summarizeAndExit()
            }
            let installArgs = RemoteSetupPlan.installArgs(workDir: layout.workDir, projectName: resolvedProject.name)
            let installCmd = RemoteSetupPlan.runAndCleanupCommand(remotePath: remoteInstall, args: installArgs)
            let installStatus = (try? runInheritedSSH(setupSSHBase + [hostSpec.sshTarget, installCmd])) ?? -1
            guard installStatus == 0 else {
                emit("install", .fail, "install.sh exited with status \(installStatus) (see output above)")
                try summarizeAndExit()
            }
            emit("install", .ok, "installed at \(layout.base)")

            // MARK: align

            say("==> align: fetching and building the remote clone...")
            guard let localRevision = (try? Shell.run(["git", "-C", repoRoot.path, "rev-parse", "HEAD"]))
                .map({ $0.output.trimmingCharacters(in: .whitespacesAndNewlines) }), !localRevision.isEmpty else {
                emit("align", .fail, "could not determine the local git revision")
                try summarizeAndExit()
            }
            do {
                try RemoteSetupPlan.validateRevision(localRevision)
            } catch {
                emit("align", .fail, error.localizedDescription)
                try summarizeAndExit()
            }
            if let statusResult = try? Shell.run(["git", "-C", repoRoot.path, "status", "--porcelain"]),
               !statusResult.output.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                say("⚠️ local uncommitted changes will NOT reach the remote (aligning to the last commit, "
                    + "\(localRevision.prefix(7)))")
            }
            let alignCmd = RemoteSetupPlan.alignRevisionCommand(layout: layout, revision: localRevision)
            let alignStatus = (try? runInheritedSSH(setupSSHBase + [hostSpec.sshTarget, alignCmd])) ?? -1
            guard alignStatus == 0 else {
                emit("align", .fail, "git fetch/checkout/build failed (exit \(alignStatus); see output above)")
                try summarizeAndExit()
            }
            emit("align", .ok, "aligned to \(localRevision.prefix(7)) and built")

            // MARK: machine

            if let machine {
                say("==> machine: setting the machine name to \"\(machine)\" on \(hostSpec.sshTarget)...")
                let cmd = RemoteShell.remoteExecCommand(layout: layout, args: ["machine", "set", machine])
                let status = (try? runInheritedSSH(setupSSHBase + [hostSpec.sshTarget, cmd])) ?? -1
                if status == 0 {
                    emit("machine", .ok, "set to \"\(machine)\"")
                } else {
                    emit("machine", .fail, "machine set exited with status \(status)")
                }
            } else {
                emit("machine", .skip, "no --machine given (the remote's existing registration is left untouched)")
            }

            // MARK: verify

            if let profile, !skipVerify {
                let what = scenario.map { "scenario \($0)" } ?? "profile \(profile)"
                say("==> verify: dispatching \(what) to \(hostSpec.sshTarget) (this is the real success gate)...")
                let dispatcher = RemoteRunDispatcher(host: hostSpec, remoteDirRaw: remoteDir, localRepoRoot: repoRoot)
                do {
                    let exitCode = try await dispatcher.dispatch(
                        project: resolvedProject, profile: profile,
                        scenarios: scenario.map { [$0] } ?? [], folders: [],
                        heal: false, noHeal: false, noLPT: false, lptHistoryRuns: nil,
                        fastInput: false, enableAnimations: false, performanceMode: false,
                        localJUnitPath: nil, remoteTimeoutSeconds: nil)
                    if exitCode == 0 {
                        emit("verify", .ok, "dispatch to \(hostSpec.sshTarget) passed")
                    } else {
                        emit("verify", .fail, "dispatch exited with status \(exitCode)")
                    }
                } catch {
                    emit("verify", .fail, "dispatch failed: \(error.localizedDescription)")
                }
            } else {
                emit("verify", .warn, skipVerify
                    ? "skipped (--skip-verify) — not yet verified with a real dispatch"
                    : "skipped (no --profile given) — not yet verified with a real dispatch")
            }

            try summarizeAndExit()
        }

        /// `echo $HOME; stat -f%Su /dev/console; id -un` の到達確認(RemoteRunDispatcher.resolveLayout
        /// と同じ規律だが private のため複製する)。session が nil でも home が取れていれば
        /// ログイン判定だけスキップして続行する(古い macOS 等の想定外出力への fallback)
        private static func reach(hostSpec: RemoteHostSpec)
            -> (session: RemoteSessionInfo?, home: String?, error: String?) {
            guard let result = try? Shell.run(
                setupSSHBase + [hostSpec.sshTarget, "echo $HOME; stat -f%Su /dev/console; id -un"]) else {
                return (nil, nil, "ssh failed to run")
            }
            guard result.status == 0 else {
                return (nil, nil, "cannot reach \(hostSpec.sshTarget) over ssh (status \(result.status))"
                    + " — check the host name and keys; BatchMode disables password prompts\n\(result.tail)")
            }
            if let session = RemoteProbe.parseSessionInfo(result.output) {
                return (session, session.home, nil)
            }
            let firstLine = (result.output.split(separator: "\n", maxSplits: 1,
                                                  omittingEmptySubsequences: false).first ?? "")
                .trimmingCharacters(in: .whitespacesAndNewlines)
            guard !firstLine.isEmpty else {
                return (nil, nil, "could not determine $HOME on \(hostSpec.sshTarget)")
            }
            return (nil, firstLine, nil)
        }

        /// `--yes` があれば無条件に許可。無ければ TTY からのみ確認を取る(非対話セッションは
        /// 確認できないので拒否する。破壊的操作は必ず人の確認を経る)
        private func confirmUninstall(base: String, host: String) -> Bool {
            if yes { return true }
            guard isatty(fileno(stdin)) != 0 else { return false }
            // 入力を同じ行で待つので改行を付けない(ここは TTY 限定なのでバッファ懸念は無い)
            FileHandle.standardOutput.write(
                Data("This permanently deletes \(base) on \(host). Type 'yes' to continue: ".utf8))
            guard let line = readLine() else { return false }
            return line.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() == "yes"
        }
    }

    struct Exec: AsyncParsableCommand {
        static let configuration = CommandConfiguration(
            commandName: "exec",
            abstract: "Run `ftester <args>` on a remote host and relay its output and exit code",
            discussion: "The generic transport for one-shot queries and operations "
                + "(docs/remote-runner.md §14): do not add a dedicated ssh path for a new use case, use this. "
                + "Everything after <host> is passed through verbatim, so --remote-dir must come before it.\n"
                + "  ftester remote exec mac2 -- doctor --fm-only\n"
                + "  ftester remote exec --remote-dir ~/runner mac2 -- api device-catalog")

        @Argument(help: "Remote host to run on (user@host or host)")
        var host: String

        @Option(name: .customLong("remote-dir"),
                help: "Runner-only base directory on the remote host (default: ~/ftester-runner)")
        var remoteDir: String = "~/ftester-runner"

        // 設計文書(docs/remote-runner.md §14)は `ftester --host <name> <サブコマンド>` の形で
        // 書いているが、ArgumentParser のサブコマンド解決と `run --host` の意味が衝突するため
        // `remote exec <host> -- <args>` に変えた(トップレベルに --host オプションは無い)
        @Argument(parsing: .captureForPassthrough,
                  help: "The ftester subcommand and its arguments to run remotely, e.g. -- doctor --fm-only")
        var args: [String] = []

        func run() async throws {
            var relayed = args
            if relayed.first == "--" { relayed.removeFirst() }
            guard !relayed.isEmpty else {
                throw ValidationError("no ftester subcommand given (usage: remote exec <host> -- <subcommand> [args...])")
            }
            guard !relayed.contains("--host") else {
                throw ValidationError("--host cannot be relayed through `remote exec` (no nested dispatch to another host)")
            }
            try RemoteLayout.validateBase(remoteDir)
            let hostSpec = try RemoteHostSpec.parse(host)

            let homeResult = try Shell.run(setupSSHBase + [hostSpec.sshTarget, "echo $HOME"])
            guard homeResult.status == 0 else {
                throw RemoteDispatchError.remoteSetupFailed(
                    "cannot reach \(hostSpec.sshTarget) over ssh (status \(homeResult.status))\n\(homeResult.tail)")
            }
            let home = homeResult.output.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !home.isEmpty else {
                throw RemoteDispatchError.remoteSetupFailed("could not determine $HOME on \(hostSpec.sshTarget)")
            }
            let layout = RemoteLayout(base: RemoteLayout.resolveBase(remoteDir, home: home))
            let command = RemoteShell.remoteExecCommand(layout: layout, args: relayed)
            let status = try runInheritedSSH(setupSSHBase + [hostSpec.sshTarget, command])
            if status == 90 {
                FileHandle.standardError.write(Data(
                    "the remote ftester binary is missing — run `ftester remote setup \(hostSpec.sshTarget)` first\n"
                        .utf8))
            }
            if status != 0 {
                throw ExitCode(status)
            }
        }
    }
}
