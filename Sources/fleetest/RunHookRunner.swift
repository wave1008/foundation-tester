// RunHookRunner.swift
// 実行プロファイルの開始/終了スクリプト(docs/remote-runner.md §17)の実行。
// 判定(パス解決・実行可否・孤児か)は FTCore.RunHookPlan / RunHookLease が持ち、ここは I/O だけ。
//
// 呼び出し場所は run を実行する2経路(ProfileRunner.run / ApiRunCommand)。**リモートへ
// ディスパッチしたときも同じコードが向こうの子プロセスで走る**(子は `fleetest run --host local`
// として起動されるため)ので、RemoteRunDispatcher には何も足さない = 手元とリモートで実装が割れない。

import Foundation
import FTCore
import FTRemote

/// begin() が返す片付けの控え。end() へそのまま渡す
struct RunHookSession {
    let teardown: RunHook?
    let profile: ResolvedProfile
    let leaseURL: URL?
}

enum RunHookRunner {

    /// 開始スクリプトを撃つ(必要なら)。撃つ前に**他の run が残した孤児の終了スクリプト**を
    /// 回収する —— 掴まれたままのポートを空けてからでないと、こちらの setup が必ず失敗する。
    ///
    /// throw するのは**開始スクリプトが非0で終了したとき**だけ。**インフラ起因の失敗**
    /// (シナリオの失敗と区別する。§16.7)として、テストを1本も走らせずに run を止める
    /// ―― 依存サービスが上がっていないまま流すと、全シナリオが「アプリの不具合」の顔をして落ちる。
    static func begin(resolved: ResolvedProfile, stateDir: URL?,
                      log: (String) -> Void) throws -> RunHookSession {
        if let stateDir {
            reapOrphans(stateDir: stateDir, log: log)
        }
        // lease は setup を撃つ**前**に置く。setup の途中で死んだ場合も、その時点までに
        // 起きたサービスは片付けたい(「全部起きてから」だと最も壊れやすい区間が無防備になる)
        let leaseURL = stateDir.flatMap { writeLease(resolved: resolved, stateDir: $0) }
        do {
            try run(hook: resolved.setupHook, profile: resolved, log: log)
        } catch {
            // setup が落ちたら、そこまでに起きたものを片付けてから投げ直す
            try? runIgnoringResult(hook: resolved.teardownHook, profile: resolved, log: log)
            if let leaseURL { try? FileManager.default.removeItem(at: leaseURL) }
            throw error
        }
        return RunHookSession(
            teardown: resolved.teardownHook, profile: resolved, leaseURL: leaseURL)
    }

    /// 終了スクリプトを撃つ。**run の成否を変えない**(失敗は警告のみ。成果物回収と同じ規律)
    /// —— 片付けの失敗でテスト結果を赤にすると、通ったのか落ちたのかが読めなくなる
    static func end(_ session: RunHookSession, log: (String) -> Void) {
        try? runIgnoringResult(hook: session.teardown, profile: session.profile, log: log)
        if let leaseURL = session.leaseURL {
            try? FileManager.default.removeItem(at: leaseURL)
        }
    }

    // MARK: - 孤児の回収

    /// 死んだ run が残した lease の終了スクリプトを撃つ。`fleetest hooks reap` と run 開始時の
    /// 両方から呼ぶ(前者は誰も見ていないランナー機を `remote clean` から掃除するため)。
    /// 戻り値: 回収した件数
    @discardableResult
    static func reapOrphans(stateDir: URL, log: (String) -> Void) -> Int {
        let dir = RunHookLease.directory(stateDir: stateDir)
        guard let entries = try? FileManager.default.contentsOfDirectory(
            at: dir, includingPropertiesForKeys: nil) else { return 0 }
        var reaped = 0
        for url in entries.sorted(by: { $0.lastPathComponent < $1.lastPathComponent })
        where url.pathExtension == "json" {
            guard let raw = try? String(contentsOf: url, encoding: .utf8),
                  let info = RunHookLease.decode(raw) else {
                try? FileManager.default.removeItem(at: url)  // 読めない記録は残しても誰も使えない
                continue
            }
            guard RunHookLease.isOrphan(info, isAlive: RunHookLease.processIsAlive) else { continue }
            log("🧹 Running the teardown script left behind by run \(info.profile)"
                + " (pid \(info.pid), started \(info.startedAt))")
            let script = URL(fileURLWithPath: info.teardown)
            if FileManager.default.fileExists(atPath: script.path) {
                let status = execute(script: script, kind: .teardown,
                                     workingDirectory: URL(fileURLWithPath: info.workspace),
                                     environment: RunHookEnvironment.variables(orphan: info),
                                     log: log)
                if status != 0 {
                    log("⚠️ The orphaned teardown script exited with status \(status)")
                }
            }
            try? FileManager.default.removeItem(at: url)
            reaped += 1
        }
        return reaped
    }

    // MARK: - 実行

    private static func run(hook: RunHook?, profile: ResolvedProfile,
                            log: (String) -> Void) throws {
        guard let hook else { return }
        let exists = FileManager.default.fileExists(atPath: hook.url.path)
        switch RunHookPlan.action(for: hook, exists: exists) {
        case .skip:
            return
        case .run:
            log("🔧 Running the \(hook.kind.rawValue) script: \(hook.url.path)")
            let status = execute(
                script: hook.url, kind: hook.kind,
                workingDirectory: profile.workspaceRoot ?? profile.project.rootURL,
                environment: RunHookEnvironment.variables(kind: hook.kind, profile: profile),
                log: log)
            guard status == 0 else {
                throw RunHookError.scriptFailed(kind: hook.kind, path: hook.url.path, status: status)
            }
        }
    }

    /// 終了スクリプト用(結果で run の成否を変えない)
    private static func runIgnoringResult(hook: RunHook?, profile: ResolvedProfile,
                                          log: (String) -> Void) throws {
        do {
            try run(hook: hook, profile: profile, log: log)
        } catch {
            log("⚠️ \(error.localizedDescription)")
        }
    }

    /// 子プロセスを起動し、出力を1行ずつ中継する(まとめて出すと、数十秒かかる setup が
    /// 終わるまで画面が無音になり「止まった」と読まれる)。**タイムアウトは置かない** ——
    /// 妥当な上限を決める根拠がこちらに無い(起こすものは利用者が決める)。リモート実行は
    /// ディスパッチ全体の上限(§16.2 `--remote-timeout`)が外側から縛る
    private static func execute(script: URL, kind: RunHook.Kind, workingDirectory: URL,
                                environment: [String: String], log: (String) -> Void) -> Int32 {
        let process = Process()
        // 実行権が無いスクリプトは sh で起動する(chmod を忘れただけで止めない)。権があれば
        // 直接起動 = shebang を尊重する(python/ruby で書いた片付けが sh に食われない)
        if FileManager.default.isExecutableFile(atPath: script.path) {
            process.executableURL = script
            process.arguments = []
        } else {
            process.executableURL = URL(fileURLWithPath: "/bin/sh")
            process.arguments = [script.path]
        }
        process.currentDirectoryURL = workingDirectory
        var env = ProcessInfo.processInfo.environment
        for (key, value) in environment { env[key] = value }
        process.environment = env
        // 対話しない(端末が無いリモートで stdin を待つと run ごと固まる)
        process.standardInput = FileHandle.nullDevice
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = pipe  // 利用者のスクリプトの stderr も同じ順序で読ませる
        let waitExit = ProcessExitWait.prepareBlocking(process)  // 契約: run() より前に設定
        let readHandle = pipe.fileHandleForReading
        let readDone = DispatchSemaphore(value: 0)
        let sink = HookLineSink()
        do {
            try process.run()
        } catch {
            log("⚠️ Could not start the \(kind.rawValue) script: \(error.localizedDescription)")
            return 127
        }
        DispatchQueue.global(qos: .utility).async {
            let splitter = StreamLineSplitter()
            while true {
                // availableData = 届いた分だけ返す(readData(ofLength:) は EOF まで貯める)
                let chunk = readHandle.availableData
                if chunk.isEmpty { break }   // 子の終了で書込端が閉じ EOF
                sink.append(splitter.feed(chunk))
            }
            if let last = splitter.flush() { sink.append([last]) }
            readDone.signal()
        }
        // 出力は読み出しスレッドが貯め、こちら側で順に出す(log クロージャは Sendable ではない
        // ので別スレッドから呼ばない)。0.2 秒ごとに吐くので、長い setup でも無音にならない
        while readDone.wait(timeout: .now() + 0.2) == .timedOut {
            for line in sink.takePending() { log("   │ \(line)") }
        }
        for line in sink.takePending() { log("   │ \(line)") }
        waitExit()
        return process.terminationStatus
    }

    // MARK: - lease

    private static func writeLease(resolved: ResolvedProfile, stateDir: URL) -> URL? {
        guard let teardown = resolved.teardownHook,
              FileManager.default.fileExists(atPath: teardown.url.path) else { return nil }
        let pid = ProcessInfo.processInfo.processIdentifier
        let info = RunHookLeaseInfo.now(
            pid: pid, project: resolved.project.name, profile: resolved.runName,
            teardown: teardown.url, workspace: resolved.workspaceRoot ?? resolved.project.rootURL)
        guard let encoded = RunHookLease.encode(info) else { return nil }
        let url = RunHookLease.leaseURL(stateDir: stateDir, pid: pid)
        try? FileManager.default.createDirectory(
            at: RunHookLease.directory(stateDir: stateDir), withIntermediateDirectories: true)
        guard (try? encoded.write(to: url, atomically: true, encoding: .utf8)) != nil else { return nil }
        return url
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

    var errorDescription: String? {
        switch self {
        case .scriptFailed(let kind, let path, let status):
            return "the \(kind.rawValue) script exited with status \(status): \(path)"
                + " — this is an infrastructure failure, so no scenario was run"
        }
    }
}
