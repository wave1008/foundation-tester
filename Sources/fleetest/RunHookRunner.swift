// RunHookRunner.swift
// 実行プロファイルの開始/終了スクリプト(docs/remote-runner.md §17「スクリプト(Seatbelt の中)」)の実行。
// 判定(パス解決・実行可否・孤児か)は FTCore.RunHookPlan / RunHookLease、枠の規則は FTCore.ScriptSandbox、
// 中継の判定は FTServices.ServicePolicy。ここは入力集め・起動・出力の中継・子孫の掃除・控えの更新だけ。
//
// 呼び出し場所は run を実行する2経路(ProfileRunner.run / ApiRunCommand)。**リモートへ
// ディスパッチしたときも同じコードが向こうの子プロセスで走る**(子は `fleetest run --host local`
// として起動されるため)ので、RemoteRunDispatcher には何も足さない = 手元とリモートで実装が割れない。

import Darwin
import Foundation
import FTCore
import FTServices
import FTRemote

/// begin() が返す片付けの控え。end() へそのまま渡す
struct RunHookSession {
    let teardown: RunHook?
    let profile: ResolvedProfile
    let lease: RunHookLeaseFile?
    let inputs: RunHookLaunchInputs
    let interrupt: RunInterruptState?
}

/// スクリプト1本を起こすのに要る、run から来る入力(setup と teardown で同じ。孤児の回収は控えから作り直す)
struct RunHookLaunchInputs {
    /// `scripts/` と `data/` の親
    let workspace: URL
    let projectRoot: URL
    /// compose.yaml が参照している秘密だけ(名前 → 値)。関係のない秘密は渡さない
    let secrets: [String: String]
    /// 宣言した公開ポート = スクリプトが 127.0.0.1 で繋いでよいポート
    let loopbackPorts: [UInt16]
    /// compose.yaml があるときだけ(中継 `fleetest-services` の判定)
    let gatewayPolicy: (any ServiceGatewayPolicy)?
}

/// 控え(`.fleetest/hooks/<pid>.json`)。開始スクリプトを撃つ**前**に置き、終了スクリプトを撃ったら消す。
/// 動いている子の pid はその場で書き足す(親が SIGKILL されても、回収側が先に子を止められる)
final class RunHookLeaseFile {
    let url: URL
    private(set) var info: RunHookLeaseInfo

    init?(stateDir: URL, resolved: ResolvedProfile, secretNames: [String]) {
        let teardown = resolved.teardownHook
        let setup = resolved.setupHook
        let exists = { (hook: RunHook?) in hook.map { FileManager.default.fileExists(atPath: $0.url.path) } ?? false }
        guard let teardown, exists(teardown) || exists(setup) else { return nil }
        let pid = ProcessInfo.processInfo.processIdentifier
        info = RunHookLeaseInfo.now(
            pid: pid, project: resolved.project.name, profile: resolved.runName,
            teardown: teardown.url, workspace: resolved.workspaceRoot ?? resolved.project.rootURL,
            secretNames: secretNames)
        url = RunHookLease.leaseURL(stateDir: stateDir, pid: pid)
        guard write() else { return nil }
    }

    @discardableResult
    private func write() -> Bool {
        guard let encoded = RunHookLease.encode(info) else { return false }
        try? FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        return (try? encoded.write(to: url, atomically: true, encoding: .utf8)) != nil
    }

    func setChild(_ process: Process?) {
        if let process {
            let started = ProcessLiveness.startTime(process.processIdentifier) ?? Date()
            info.child = .init(pid: process.processIdentifier, startedAt: RunHookLease.timestamp(started))
        } else {
            info.child = nil
        }
        write()
    }

    func remove() {
        try? FileManager.default.removeItem(at: url)
    }
}

enum RunHookRunner {

    /// 開始スクリプトを撃つ(必要なら)。撃つ前に**他の run が残した孤児の終了スクリプト**を
    /// 回収する —— 掴まれたままのポートを空けてからでないと、こちらの setup が必ず失敗する。
    ///
    /// throw するのは**開始スクリプトが非0で終了したとき**と**枠を組めないとき**だけ。
    /// テストを1本も走らせずに run を止める ―― 依存サービスが上がっていないまま流すと、全シナリオが「アプリの不具合」の顔をして落ちる。
    static func begin(resolved: ResolvedProfile, stateDir: URL?, services: ServicesSession?,
                      interrupt: RunInterruptState?, log: (String) -> Void) throws -> RunHookSession {
        if let stateDir {
            reapOrphans(stateDir: stateDir, log: log)
        }
        // `data/` は親が先に作る(枠の中からは根を作れない)
        try ServicesFacts.ensureDataDirectory(ServicesFacts.workspace(for: resolved))
        let inputs = RunHookLaunchInputs(
            workspace: resolved.workspaceRoot ?? resolved.project.rootURL, projectRoot: resolved.project.rootURL,
            secrets: services?.scriptSecrets ?? [:], loopbackPorts: services?.scriptLoopbackPorts ?? [],
            gatewayPolicy: services.map { ServicePolicy(inputs: $0.gatewayInputs()) })
        // lease は setup を撃つ**前**に置く。setup の途中で死んだ場合も、その時点までに
        // 起きたサービスは片付けたい(「全部起きてから」だと最も壊れやすい区間が無防備になる)
        let lease = stateDir.flatMap {
            RunHookLeaseFile(stateDir: $0, resolved: resolved, secretNames: inputs.secrets.keys.sorted())
        }
        do {
            try run(hook: resolved.setupHook, contract: resolved, inputs: inputs, lease: lease, interrupt: interrupt, log: log)
        } catch {
            // setup が落ちたら、そこまでに起きたものを片付けてから投げ直す
            runIgnoringResult(hook: resolved.teardownHook, contract: resolved, inputs: inputs, lease: lease,
                              interrupt: interrupt, log: log)
            lease?.remove()
            throw error
        }
        return RunHookSession(teardown: resolved.teardownHook, profile: resolved, lease: lease, inputs: inputs,
                              interrupt: interrupt)
    }

    /// 終了スクリプトを撃つ。**run の成否を変えない**(失敗は警告のみ。成果物回収と同じ規律)
    /// —— 片付けの失敗でテスト結果を赤にすると、通ったのか落ちたのかが読めなくなる
    static func end(_ session: RunHookSession, log: (String) -> Void) {
        runIgnoringResult(hook: session.teardown, contract: session.profile, inputs: session.inputs,
                          lease: session.lease, interrupt: session.interrupt, log: log)
        session.lease?.remove()
    }

    // MARK: - 孤児の回収

    /// 死んだ run が残した lease の終了スクリプトを撃つ。`fleetest hooks reap` と run 開始時の
    /// 両方から呼ぶ(前者は誰も見ていないランナー機を `remote clean` から掃除するため)。
    /// 控えに動いている子が残っていれば**先に止める**(親が死んでも子は `data/` を書き続けうる)。
    /// 戻り値: 回収した件数
    @discardableResult
    static func reapOrphans(stateDir: URL, home: String = ScenarioSandbox.realHome(), log: (String) -> Void) -> Int {
        // 死んだ run のスクリプトの一時領域(gateway のソケットの置き場)も掃く
        for stale in ScriptSandbox.staleTemporaryDirectories() {
            try? FileManager.default.removeItem(atPath: stale)
        }
        let dir = RunHookLease.directory(stateDir: stateDir)
        guard let entries = try? FileManager.default.contentsOfDirectory(
            at: dir, includingPropertiesForKeys: nil) else { return 0 }
        var reaped = 0
        for url in entries.sorted(by: { $0.lastPathComponent < $1.lastPathComponent })
        where url.pathExtension == "json"
            // サービスの控え(`<pid>~<prefix>.json`)は同じ置き場に居るが別の形 = `ServicesReaper` が回収する。
            // ここで decode に失敗した扱いにすると**生きている run の控えまで消す**
            && ServicesLeaseFile.parse(fileName: url.lastPathComponent) == nil {
            guard let raw = try? String(contentsOf: url, encoding: .utf8),
                  let info = RunHookLease.decode(raw) else {
                try? FileManager.default.removeItem(at: url)  // 読めない記録は残しても誰も使えない
                continue
            }
            guard RunHookLease.isOrphan(info, isAlive: RunHookLease.processIsAlive) else { continue }
            if let child = info.child, ServicesProcessIdentity.isAlive(pid: child.pid, startedAt: child.startedAt) {
                log("🧹 Stopping the script left running by run \(info.profile) (pid \(child.pid))")
                sweepProcessGroup(child.pid, what: "the script left behind by run \(info.profile)", log: log)
            }
            log("🧹 Running the teardown script left behind by run \(info.profile)"
                + " (pid \(info.pid), started \(info.startedAt))")
            let script = URL(fileURLWithPath: info.teardown)
            if FileManager.default.fileExists(atPath: script.path) {
                let workspace = URL(fileURLWithPath: info.workspace)
                // 秘密は控えの名前だけを、今のマシン側のファイルから引く(値は控えに無い)。読めなければ空で撃つが黙らない
                var secrets: [String: String] = [:]
                do {
                    secrets = try ServicesFacts.dictionaries(
                        project: info.project, workspace: ServicesWorkspace(root: workspace), home: home).secrets
                } catch {
                    if !info.secretNames.isEmpty {
                        log("⚠️ the secrets for the orphaned teardown script could not be read (\(error.localizedDescription));"
                            + " it runs without \(info.secretNames.joined(separator: ", "))")
                    }
                }
                let inputs = RunHookLaunchInputs(
                    workspace: workspace, projectRoot: workspace,
                    secrets: secrets.filter { info.secretNames.contains($0.key) },
                    loopbackPorts: [], gatewayPolicy: nil)
                do {
                    let status = try runScript(script, kind: .teardown, contract: RunHookEnvironment.variables(orphan: info),
                                               inputs: inputs, lease: nil, interrupt: nil, log: log)
                    if status != 0 {
                        log("⚠️ The orphaned teardown script exited with status \(status)")
                    }
                } catch {
                    log("⚠️ \(error.localizedDescription)")
                }
            }
            try? FileManager.default.removeItem(at: url)
            reaped += 1
        }
        return reaped
    }

    // MARK: - 実行

    private static func run(hook: RunHook?, contract: ResolvedProfile, inputs: RunHookLaunchInputs,
                            lease: RunHookLeaseFile?, interrupt: RunInterruptState?,
                            log: (String) -> Void) throws {
        guard let hook else { return }
        let exists = FileManager.default.fileExists(atPath: hook.url.path)
        switch RunHookPlan.action(for: hook, exists: exists) {
        case .skip:
            return
        case .run:
            log("🔧 Running the \(hook.kind.rawValue) script: \(hook.url.path)")
            let status = try runScript(
                hook.url, kind: hook.kind, contract: RunHookEnvironment.variables(kind: hook.kind, profile: contract),
                inputs: inputs, lease: lease, interrupt: interrupt, log: log)
            guard status == 0 else {
                throw RunHookError.scriptFailed(kind: hook.kind, path: hook.url.path, status: status)
            }
        }
    }

    /// 終了スクリプト用(結果で run の成否を変えない)
    private static func runIgnoringResult(hook: RunHook?, contract: ResolvedProfile, inputs: RunHookLaunchInputs,
                                          lease: RunHookLeaseFile?, interrupt: RunInterruptState?,
                                          log: (String) -> Void) {
        do {
            try run(hook: hook, contract: contract, inputs: inputs, lease: lease, interrupt: interrupt, log: log)
        } catch {
            log("⚠️ \(error.localizedDescription)")
        }
    }

    /// 中継コマンド `fleetest-services` の置き場(この実行ファイルの隣)。隣に無い(xctest 等)なら nil
    static func gatewayToolDirectory(current: URL? = Bundle.main.executableURL) -> String? {
        guard let current else { return nil }
        let dir = current.deletingLastPathComponent()
        return FileManager.default.isExecutableFile(atPath: dir.appendingPathComponent(ServiceGatewayWire.relayProductName).path) ? dir.path : nil
    }

    /// 枠・環境・中継を組んでスクリプト1本を実行する(setup / teardown / 孤児の teardown の3経路が通る唯一の入口)。
    /// 環境は**明示した鍵だけ**: 基本の鍵 → 秘密 → 契約(FT_HOOK 等)→ 制御変数(PATH・TMPDIR・プロキシ・gateway)。
    /// 後が勝つ = 秘密のファイルの同名で契約と制御変数を上書きさせない
    static func runScript(_ script: URL, kind: RunHook.Kind, contract: [String: String], inputs: RunHookLaunchInputs,
                          lease: RunHookLeaseFile?, interrupt: RunInterruptState?,
                          stallThreshold: Double = RunHookStall.silentWarningSeconds,
                          log: (String) -> Void) throws -> Int32 {
        let plan = try ScenarioSandbox.plan(settings: try ScenarioSandbox.machineSettings())
        guard let temp = ScriptSandbox.temporaryDirectory() else {
            throw RunHookError.cannotPrepare(kind: kind, detail: "this user's temporary directory is unavailable")
        }
        try FileManager.default.createDirectory(atPath: temp, withIntermediateDirectories: true)
        // 一時領域は run ごと(pid)。終わったら消す(gateway の stop より後 = defer は後に書いたものから走る)
        defer { try? FileManager.default.removeItem(atPath: temp) }

        var environment = ScriptSandbox.baseEnvironment(ProcessInfo.processInfo.environment)
        environment.merge(inputs.secrets) { $1 }
        environment.merge(contract) { $1 }
        var ports = inputs.loopbackPorts
        var usesProxy = false
        if let plan, !plan.allowedDomains.isEmpty {
            let proxy = try ScriptSandbox.proxy(allowedDomains: plan.allowedDomains)
            environment.merge(proxy.environment) { $1 }
            ports.append(proxy.port)
            usesProxy = true
        }
        // 中継コマンドは compose.yaml の有無に関わらず PATH に置く(無いときは本体が「サービスを宣言していない」と言う =
        // "command not found" より原因に近い)
        if let dir = gatewayToolDirectory() {
            environment["PATH"] = dir + ":" + (environment["PATH"] ?? "/usr/bin:/bin")
        } else if inputs.gatewayPolicy != nil {
            log("⚠️ fleetest-services is not next to this fleetest binary, so the \(kind.rawValue) script cannot reach"
                + " the services gateway (run swift build)")
        }
        var gateway: ServiceGatewayServer?
        defer { gateway?.stop() }
        if let policy = inputs.gatewayPolicy {
            // 拒否は親の stderr へ(スクリプトの出力の中継とは別の口。スレッド安全な出口だけを使う)
            let server = try ServiceGatewayServer(policy: policy, directory: temp) { ConsoleOut.err($0) }
            gateway = server
            environment[ServiceGatewayWire.environmentKey] = server.socketPath
        }
        environment["TMPDIR"] = temp

        let command: (executable: URL, arguments: [String])
        if let plan {
            let launch = try ScriptSandbox.launch(ScriptSandbox.Inputs(
                script: script, workspace: inputs.workspace, projectRoot: inputs.projectRoot,
                packageRoot: ScenarioHost.packageRoot(),
                hookWritablePaths: try HooksSettings.load()?.writablePaths ?? [],
                buildSources: try ServicesSettings.load()?.buildSources ?? [],
                loopbackPorts: ports, gatewaySocket: gateway?.socketPath, usesProxy: usesProxy,
                temporaryDirectory: temp), plan: plan)
            log(launch.notice)
            command = (launch.executable, launch.arguments)
        } else {
            command = ScriptSandbox.command(for: script)
        }
        return execute(executable: command.executable, arguments: command.arguments, workingDirectory: inputs.workspace,
                       environment: environment, kind: kind, scriptPath: script.path, interrupt: interrupt,
                       stallThreshold: stallThreshold, onStart: { lease?.setChild($0) },
                       onExit: { lease?.setChild(nil) }, log: log)
    }

    /// 包まずに起こす(テストの差し替え口。本番は `runScript` を通る)
    static func execute(script: URL, kind: RunHook.Kind, workingDirectory: URL,
                        environment: [String: String],
                        stallThreshold: Double = RunHookStall.silentWarningSeconds,
                        log: (String) -> Void) -> Int32 {
        let command = ScriptSandbox.command(for: script)
        return execute(executable: command.executable, arguments: command.arguments, workingDirectory: workingDirectory,
                       environment: environment, kind: kind, scriptPath: script.path, interrupt: nil,
                       stallThreshold: stallThreshold, onStart: { _ in }, onExit: {}, log: log)
    }

    /// 子プロセスを起動し、出力を1行ずつ中継する(まとめて出すと、数十秒かかる setup が
    /// 終わるまで画面が無音になり「止まった」と読まれる)。**タイムアウトは置かない** ——
    /// 妥当な上限を決める根拠がこちらに無い(起こすものは利用者が決める)。リモート実行は
    /// ディスパッチ全体の上限(§16.2 `--remote-timeout`)が外側から縛る。
    /// **出力せずに戻らない**形は `RunHookStall` の閾値ごとに警告を 1 行出して待ち続ける。
    /// **終了はパイプの EOF と独立に待つ**(`sleep 999 &` の孫が書込端を握っても掃除に進める)。
    /// 終わったら期限つきで出力を回収し、プロセスグループに残った子孫を止める。
    /// 環境は `environment` そのもの(親の環境を継がせない)
    static func execute(executable: URL, arguments: [String], workingDirectory: URL,
                        environment: [String: String], kind: RunHook.Kind, scriptPath: String,
                        interrupt: RunInterruptState?, stallThreshold: Double,
                        onStart: (Process) -> Void, onExit: () -> Void, log: (String) -> Void) -> Int32 {
        let process = Process()
        process.executableURL = executable
        process.arguments = arguments
        process.currentDirectoryURL = workingDirectory
        process.environment = environment
        // 対話しない(端末が無いリモートで stdin を待つと run ごと固まる)
        process.standardInput = FileHandle.nullDevice
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = pipe  // 利用者のスクリプトの stderr も同じ順序で読ませる
        let waitExit = ProcessExitWait.prepareTimed(process)  // 契約: run() より前に設定
        let readHandle = pipe.fileHandleForReading
        let readDone = DispatchSemaphore(value: 0)
        let sink = HookLineSink()
        do {
            try process.run()
        } catch {
            log("⚠️ Could not start the \(kind.rawValue) script: \(error.localizedDescription)")
            return 127
        }
        let unregister = interrupt?.registerChildProcess(process)
        defer { unregister?() }
        onStart(process)
        let pid = process.processIdentifier
        DispatchQueue.global(qos: .utility).async {
            let splitter = StreamLineSplitter()
            while true {
                // availableData = 届いた分だけ返す(readData(ofLength:) は EOF まで貯める)。
                // **1回ごとに解放の区切り**(autoreleasepool)—— 自動解放の NSData が抜けないループで溜まる
                let eof: Bool = autoreleasepool {
                    let chunk = readHandle.availableData
                    if chunk.isEmpty { return true }   // 書込端が全部閉じて EOF
                    sink.append(splitter.feed(chunk))
                    return false
                }
                if eof { break }
            }
            if let last = splitter.flush() { sink.append([last]) }
            readDone.signal()
        }
        // 出力は読み出しスレッドが貯め、こちら側で順に出す(log クロージャは Sendable ではない
        // ので別スレッドから呼ばない)。0.2 秒ごとに吐くので、長い setup でも無音にならない
        var lastOutputAt = Date()
        var stallWarnings = 0
        func drain() {
            let pending = sink.takePending()
            if !pending.isEmpty {
                lastOutputAt = Date()
                stallWarnings = 0
            }
            for line in pending { log("   │ \(line)") }
        }
        while waitExit(.now() + 0.2) == .timedOut {
            drain()
            let silent = Date().timeIntervalSince(lastOutputAt)
            if RunHookStall.shouldWarn(silentSeconds: silent, warningsSoFar: stallWarnings,
                                       threshold: stallThreshold) {
                stallWarnings += 1
                log(RunHookStall.message(kind: kind, path: scriptPath, silentSeconds: silent, pid: pid))
            }
        }
        onExit()
        // 終了後の出力は少しだけ回収する(孫が書込端を握っていても EOF を待ち切らない)
        _ = readDone.wait(timeout: .now() + Shell.outputDrainGraceSeconds)
        drain()
        sweepProcessGroup(pid, what: "the \(kind.rawValue) script", log: log)
        return process.terminationStatus
    }

    /// 子孫の掃除の猶予(秒)。根拠: 後始末を持たない外部プロセスへの時限 SIGKILL の方針(process-lifecycle.md)。
    /// 尽きたとき = SIGKILL
    static let descendantGraceSeconds: Double = 2

    /// スクリプトのプロセスグループに残っているもの(`sleep 999 &` 等)へ SIGTERM → 猶予 → SIGKILL。
    /// `Foundation.Process` の子はグループリーダーで、`sandbox-exec` は同じ pid で exec するので pgid = 子の pid。
    /// `setsid` で離脱した子孫には届かない(検出もできない = §17 ⑤ は目標)
    static func sweepProcessGroup(_ pgid: pid_t, what: String, log: (String) -> Void) {
        guard killpg(pgid, 0) == 0 else { return }  // 誰も居ない
        killpg(pgid, SIGTERM)
        let deadline = Date().addingTimeInterval(descendantGraceSeconds)
        while Date() < deadline, killpg(pgid, 0) == 0 {
            Thread.sleep(forTimeInterval: 0.05)
        }
        if killpg(pgid, 0) == 0 {
            killpg(pgid, SIGKILL)
            log("⚠️ \(what) left processes running in its process group; they were killed")
        } else {
            log("⚠️ \(what) left processes running in its process group; they were stopped")
        }
    }
}

/// 読み出しスレッドとの受け渡しだけを行う箱(ロックで直列化)
private final class HookLineSink: @unchecked Sendable {
    private let lock = NSLock()
    private var pending: [String] = []

    func append(_ lines: [String]) {
        guard !lines.isEmpty else { return }
        lock.lock()
        pending.append(contentsOf: lines)
        lock.unlock()
    }

    func takePending() -> [String] {
        lock.lock()
        defer { pending.removeAll(); lock.unlock() }
        return pending
    }
}

enum RunHookError: LocalizedError {
    case scriptFailed(kind: RunHook.Kind, path: String, status: Int32)
    case cannotPrepare(kind: RunHook.Kind, detail: String)

    var errorDescription: String? {
        switch self {
        case .scriptFailed(let kind, let path, let status):
            return "the \(kind.rawValue) script exited with status \(status): \(path)"
                + " — this is an infrastructure failure, so no scenario was run"
        case .cannotPrepare(let kind, let detail):
            return "cannot prepare the sandbox for the \(kind.rawValue) script: \(detail) — no scenario was run"
        }
    }
}
