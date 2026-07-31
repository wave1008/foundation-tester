// RemoteRunDispatcher.swift
// `ftester run --host` のプロセス起動(ssh/rsync)を集約する。純粋ロジックは
// Sources/FTCore/RemoteDispatch.swift 側(単体テスト対象)。

import FTCore
import Foundation

/// cliRun = `ftester run --host`(人間向け進行・出力とも stdout)。apiRun = `ftester api run
/// --host`(NDJSON 中継のため進行メッセージは stderr へ逃がす。stdout は中継行専用)
enum RemoteDispatchMode {
    case cliRun
    case apiRun
}

struct RemoteRunDispatcher {
    let host: RemoteHostSpec
    /// `--remote-dir` の生値(既定 "~/ftester-runner"。チルダ展開前)。resolveLayout が
    /// リモートの $HOME を取得してから RemoteLayout.resolveBase で絶対パスへ解決する
    let remoteDirRaw: String
    let sessionMode: String
    let localRepoRoot: URL
    // var: default 付き let は memberwise init から除外され .apiRun を注入できない
    var mode: RemoteDispatchMode = .cliRun

    /// 戻り値 = リモート `ftester run` の exit code
    func dispatch(project: TestProject, profile: String,
                  scenarios: [String], folders: [String],
                  heal: Bool, noLPT: Bool, lptHistoryRuns: Int?,
                  fastInput: Bool, localJUnitPath: String?,
                  remoteTimeoutSeconds: Int?) async throws -> Int32 {
        let layout = try resolveLayout()
        try checkCompatibility(layout: layout)
        log("note: app packages are not transferred — appPath in app profiles must be valid on the remote")

        try transfer(project: project.name, layout: layout)

        let stamp = Self.makeStamp()
        let remoteReportDir = layout.dispatchReportDir(stamp: stamp)
        let remoteJUnitPath = localJUnitPath != nil
            ? "\(layout.workDir)/.ftester/dispatch/\(stamp)/junit.xml" : nil
        let ftesterArgs = RemoteRunArgs.build(
            project: project.name, profile: profile, scenarios: scenarios, folders: folders,
            heal: heal, noLPT: noLPT, lptHistoryRuns: lptHistoryRuns,
            fastInput: fastInput, remoteJUnitPath: remoteJUnitPath, reportDir: remoteReportDir)
        let timeoutSeconds = RemoteTimeout.seconds(
            explicit: remoteTimeoutSeconds, scenarioCount: scenarios.count)
        let exitCode = try runRemoteAndRelay(
            ftesterArgs: ftesterArgs, layout: layout, timeoutSeconds: timeoutSeconds)

        collectReports(project: project.name, remoteReportDir: remoteReportDir)
        if let localJUnitPath, let remoteJUnitPath {
            collectJUnit(remotePath: remoteJUnitPath, localPath: localJUnitPath, layout: layout)
        }
        cleanupDispatchDir(layout: layout, stamp: stamp)

        log("==> remote run finished (exit \(exitCode))")
        return exitCode
    }

    /// `ftester api run --host`: dispatch と同じ流れ(レイアウト解決→適合チェック→転送→実行→回収)
    /// だが JUnit は扱わない(拡張連携は NDJSON 中継のみで完結する)。戻り値 = リモート
    /// `ftester api run` の exit code
    func dispatchApi(project: TestProject, profile: String, scenarios: [String],
                     heal: Bool, noLPT: Bool, lptHistoryRuns: Int?,
                     defaultTimeout: Double?, scenarioTimeout: Double?,
                     remoteTimeoutSeconds: Int?) async throws -> Int32 {
        let layout = try resolveLayout()
        try checkCompatibility(layout: layout)
        log("note: app packages are not transferred — appPath in app profiles must be valid on the remote")

        try transfer(project: project.name, layout: layout)

        let stamp = Self.makeStamp()
        let remoteReportDir = layout.dispatchReportDir(stamp: stamp)
        let ftesterArgs = RemoteRunArgs.buildApi(
            project: project.name, profile: profile, scenarios: scenarios,
            heal: heal, noLPT: noLPT, lptHistoryRuns: lptHistoryRuns,
            defaultTimeout: defaultTimeout, scenarioTimeout: scenarioTimeout, reportDir: remoteReportDir)
        let timeoutSeconds = RemoteTimeout.seconds(
            explicit: remoteTimeoutSeconds, scenarioCount: scenarios.count)
        let exitCode = try runRemoteAndRelay(
            ftesterArgs: ftesterArgs, layout: layout, timeoutSeconds: timeoutSeconds)

        collectReports(project: project.name, remoteReportDir: remoteReportDir)
        cleanupDispatchDir(layout: layout, stamp: stamp)

        log("==> remote run finished (exit \(exitCode))")
        return exitCode
    }

    // MARK: - 0. レイアウト解決

    /// remoteDirRaw を絶対パスへ解決する。`ssh <host> 'echo $HOME; stat -f%Su /dev/console; id -un'`
    /// を到達性プローブ兼用にする(以前の "true" プローブを置き換え。rev/toolchain は
    /// fail-closed で nil = 不一致扱いになるため、到達不能はここで先に切り分けないと compat
    /// mismatch と誤報する)。コンソールユーザー(§16.3)も同じ往復に相乗りさせて取得する
    /// — 素の $HOME だけの ssh 1本を別に足すと往復が倍になる
    private func resolveLayout() throws -> RemoteLayout {
        log("==> checking compatibility with \(host.sshTarget)")
        let result = try Shell.run(
            sshBase + [host.sshTarget, "echo $HOME; stat -f%Su /dev/console; id -un"])
        guard result.status == 0 else {
            throw RemoteDispatchError.remoteSetupFailed(
                "cannot reach \(host.sshTarget) over ssh (status \(result.status))"
                + " — check the host name and keys; BatchMode disables password prompts\n\(result.tail)")
        }
        guard let session = RemoteProbe.parseSessionInfo(result.output) else {
            // 想定外の出力(古い macOS 等): ログイン判定はスキップするが $HOME は従来どおり必須
            let firstLine = (result.output.split(separator: "\n", maxSplits: 1,
                                                 omittingEmptySubsequences: false).first ?? "")
                .trimmingCharacters(in: .whitespacesAndNewlines)
            guard !firstLine.isEmpty else {
                throw RemoteDispatchError.remoteSetupFailed(
                    "could not determine $HOME on \(host.sshTarget)")
            }
            log("warning: could not determine the remote console login state — skipping the login check")
            return RemoteLayout(base: RemoteLayout.resolveBase(remoteDirRaw, home: firstLine))
        }
        guard session.isLoggedIn else {
            throw RemoteDispatchError.remoteSetupFailed(
                "\(host.sshTarget) is sitting at the login window (console user: \(session.consoleUser), "
                + "expected: \(session.sshUser)) — unlock and log in on the runner, then retry"
                + " (docs/remote-runner.md §5)")
        }
        return RemoteLayout(base: RemoteLayout.resolveBase(remoteDirRaw, home: session.home))
    }

    /// ディスパッチ単位の一意ディレクトリ名(reports/junit の隔離・回収後の削除に使う)
    private static func makeStamp() -> String {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyyMMdd-HHmmss"
        formatter.timeZone = TimeZone(identifier: "UTC")
        return "\(formatter.string(from: Date()))-\(ProcessInfo.processInfo.processIdentifier)"
    }

    // MARK: - 1. 適合チェック

    private func checkCompatibility(layout: RemoteLayout) throws {
        let localRevision = localCapture(["git", "-C", localRepoRoot.path, "rev-parse", "HEAD"])
        if let status = localCapture(["git", "-C", localRepoRoot.path, "status", "--porcelain"]),
           !status.isEmpty {
            log("warning: uncommitted local changes will NOT reach the remote")
        }

        let remoteRevision = try? sshCapture("git -C \(RemoteShell.quote(layout.toolRoot)) rev-parse HEAD")
        let localToolchain = ToolchainFingerprint.current()
        let remoteToolchain = try? remoteToolchainFingerprint()

        let reasons = RemoteCompat.mismatches(
            localRevision: localRevision, remoteRevision: remoteRevision,
            localToolchain: localToolchain, remoteToolchain: remoteToolchain)
        guard reasons.isEmpty else { throw RemoteDispatchError.incompatible(reasons) }
    }

    private func remoteToolchainFingerprint() throws -> String {
        let xcodeVersion = try sshCapture("xcodebuild -version")
        let sdkBuild = try sshCapture("xcrun --sdk iphonesimulator --show-sdk-build-version")
        return ToolchainFingerprint.compose(xcodeVersionOutput: xcodeVersion, sdkBuild: sdkBuild)
    }

    // MARK: - 3. 転送

    private func transfer(project: String, layout: RemoteLayout) throws {
        log("==> transferring Projects/\(project) to \(host.sshTarget)")
        let args = ["rsync"] + RemoteTransferPlan.rsyncArgs(
            project: project,
            localProjectsDir: localRepoRoot.appendingPathComponent("Projects").path,
            layout: layout, sshTarget: host.sshTarget)
        let status = try runInherited(args)
        guard status == 0 else {
            throw RemoteDispatchError.remoteSetupFailed("rsync exited with status \(status)")
        }
    }

    // MARK: - 4. 実行(行単位で中継)

    /// ssh の stdout を StreamLineSplitter で行に割り、リモート絶対パスをローカルパスへ
    /// 書き換えて即 stdout へ中継する(cliRun/apiRun 共通。apiRun は中継行=NDJSON そのものなので
    /// 常に本物の stdout へ出す。進行メッセージは log() 経由で別に stderr へ逃がす)
    private func runRemoteAndRelay(ftesterArgs: [String], layout: RemoteLayout,
                                   timeoutSeconds: Int) throws -> Int32 {
        log("==> running on \(host.sshTarget): ftester \(ftesterArgs.joined(separator: " "))")
        let command = RemoteShell.remoteRunCommand(
            layout: layout, ftesterArgs: ftesterArgs, sessionMode: sessionMode)
        let status = try runInheritedWithLineRewrite(
            sshRunBase + [host.sshTarget, command], layout: layout, timeoutSeconds: timeoutSeconds)
        if status == 90 {
            log("==> the remote ftester binary is missing — build it on the remote first"
                + " (swift build --product ftester)")
        }
        return status
    }

    // MARK: - 5. 成果物回収

    /// 回収の失敗は run 全体の成否を変えない(実行結果は既に確定している。
    /// writeJUnitIfRequested と同じ規律)。ディスパッチ単位の reportDir だけを引く
    /// (--delete は付けない = リモートの reports/ 丸ごとは触らない。同じマシンで走る
    /// ローカル実行のレポート・録画と混ざらない)
    private func collectReports(project: String, remoteReportDir: String) {
        log("==> collecting reports")
        let localReports = localRepoRoot.appendingPathComponent("Projects/\(project)/reports")
        try? FileManager.default.createDirectory(at: localReports, withIntermediateDirectories: true)
        let remoteReports = "\(host.sshTarget):\(remoteReportDir)/"
        let status = (try? runInherited(["rsync", "-az", remoteReports, localReports.path + "/"])) ?? -1
        if status != 0 {
            log("warning: failed to collect reports from the remote (rsync exited with \(status))")
        }
    }

    private func collectJUnit(remotePath: String, localPath: String, layout: RemoteLayout) {
        guard let xml = try? sshCapture("cat \(RemoteShell.quote(remotePath))"), !xml.isEmpty else {
            log("warning: failed to collect the remote JUnit report (\(remotePath))")
            return
        }
        let rewritten = RemotePathRewrite.rewrite(xml, remoteRoot: layout.base, localRoot: localRepoRoot.path)
        let url = URL(fileURLWithPath: localPath)
        do {
            try FileManager.default.createDirectory(
                at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try rewritten.write(to: url, atomically: true, encoding: .utf8)
            log("📄 JUnit report: \(localPath)")
        } catch {
            log("warning: failed to write the JUnit report: \(localPath) (\(error.localizedDescription))")
        }
    }

    /// ディスパッチ単位ディレクトリ(reports/junit の親)をリモートから削除する。
    /// 失敗は run の成否を変えない(warn のみ。同じ規律を上の回収群と共有)
    private func cleanupDispatchDir(layout: RemoteLayout, stamp: String) {
        let dispatchDir = layout.workDir + "/.ftester/dispatch/\(stamp)"
        do {
            _ = try sshCapture("rm -rf \(RemoteShell.quote(dispatchDir))")
        } catch {
            log("warning: failed to remove the remote dispatch directory: \(dispatchDir)")
        }
    }

    /// 進行メッセージの出し分け(cliRun=stdout / apiRun=stderr)。apiRun の stdout は
    /// runRemoteAndRelay が中継する NDJSON 専用のため、人間向け行を混ぜると拡張側の
    /// 行パースが壊れる
    private func log(_ message: String) {
        switch mode {
        case .cliRun:
            print(message)
        case .apiRun:
            FileHandle.standardError.write(Data((message + "\n").utf8))
        }
    }

    // MARK: - process helpers

    private func localCapture(_ args: [String]) -> String? {
        guard let result = try? Shell.run(args), result.status == 0 else { return nil }
        let output = result.output.trimmingCharacters(in: .whitespacesAndNewlines)
        return output.isEmpty ? nil : output
    }

    /// 全 ssh 共通の基底引数。ConnectTimeout が無いと到達不能ホストで TCP 既定(75秒超)固まる
    private var sshBase: [String] { ["ssh", "-o", "BatchMode=yes", "-o", "ConnectTimeout=10"] }

    /// リモート実行専用(§16.1): `-tt` で疑似 TTY を強制割り当てると、ローカル ssh が
    /// SIGTERM/SIGKILL で落ちたとき SIGHUP がリモートのプロセスグループへ伝わり、キャンセルが
    /// 伝播する。照会系(sshBase)には付けない — TTY 化で stdout に CR が混ざり
    /// git rev-parse 等のキャプチャ結果を汚す
    private var sshRunBase: [String] { sshBase + ["-tt"] }

    private func sshCapture(_ command: String) throws -> String {
        let result = try Shell.run(sshBase + [host.sshTarget, command])
        guard result.status == 0 else {
            throw RemoteDispatchError.remoteSetupFailed(
                "ssh command failed (status \(result.status)): \(command)\n\(result.tail)")
        }
        return result.output.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// stdout/stderr を継承して起動する(バッファせずそのまま端末へ流す。rsync 転送は
    /// 進行を人間が見る対話用途のため両モード共通でそのまま継承する — 既定の rsyncArgs
    /// (-az --delete のみ)は成功時 stdout に何も出さないため apiRun の NDJSON 契約を汚さない)
    @discardableResult
    private func runInherited(_ argv: [String]) throws -> Int32 {
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

    /// ssh の stdout を Pipe で受け行単位に組み立て直し、各行を RemotePathRewrite にかけて
    /// print(stdout) する。stderr は継承のまま。パイプ 64KB 飽和で子がブロックする罠を避けるため
    /// 読み取りは別スレッドで行う。期限超過時は SIGTERM→2秒猶予→SIGKILL(Shell.runRaw の
    /// timeout 経路と同じ規律)。stdin は /dev/null に固定する(`-tt` は TTY として stdin を
    /// 要求するが、ディスパッチは対話しない)
    private func runInheritedWithLineRewrite(_ argv: [String], layout: RemoteLayout,
                                             timeoutSeconds: Int) throws -> Int32 {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        process.arguments = argv
        process.standardInput = FileHandle.nullDevice
        let stdoutPipe = Pipe()
        process.standardOutput = stdoutPipe
        process.standardError = FileHandle.standardError
        let waitExit = ProcessExitWait.prepareTimed(process)  // 契約: run() より前に設定
        let readHandle = stdoutPipe.fileHandleForReading
        let readDone = DispatchSemaphore(value: 0)
        let splitter = StreamLineSplitter()
        let remoteRoot = layout.base
        let localRoot = localRepoRoot.path
        func relayLine(_ line: String) {
            print(RemotePathRewrite.rewrite(line, remoteRoot: remoteRoot, localRoot: localRoot))
        }
        try process.run()
        DispatchQueue.global(qos: .utility).async {
            while true {
                let chunk = readHandle.readData(ofLength: 65536)
                if chunk.isEmpty { break }   // 子の終了/kill による書込端クローズで EOF
                for line in splitter.feed(chunk) { relayLine(line) }
            }
            readDone.signal()
        }
        if waitExit(.now() + .seconds(timeoutSeconds)) == .timedOut {
            process.terminate()                        // SIGTERM; -tt が SIGHUP をリモートへ伝える(§16.1)
            if waitExit(.now() + 2.0) == .timedOut {   // 猶予後も生存していれば強制終了
                kill(process.processIdentifier, SIGKILL)
                _ = waitExit(.distantFuture)            // reap(terminationHandler 発火)を待つ
            }
            readDone.wait()
            if let remaining = splitter.flush() { relayLine(remaining) }
            throw RemoteDispatchError.remoteSetupFailed(
                "remote run timed out after \(timeoutSeconds)s (the remote process was signalled;"
                + " run `ftester remote clean <host>` if devices remain busy)")
        }
        readDone.wait()
        if let remaining = splitter.flush() { relayLine(remaining) }
        return process.terminationStatus
    }
}
