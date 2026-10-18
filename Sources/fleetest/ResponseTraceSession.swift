// iOS 実機のレスポンス計測で、run の間だけ xctrace(Display + Hangs)を録り、終わりに最初のフレームを結果へ入れる。
// `fleetest run --profile`(ProfileRunner)と `fleetest api run`(ApiRunCommand)が同じ型を呼ぶ(2実装の差を作らない)。
// 契約: docs/response-measurement.md §5・§8.5。判定・換算は FTCore の ResponseTracePolicy / ResponseTracePatch(純粋関数)。
//
// 寿命の束ね方:
// - 正常・エラーの終わり: 呼び手の `defer { cleanup() }`(SIGINT で止めて待ち、一時フォルダを消す)。正常は先に `finish`
// - Ctrl-C: 端末の前景グループに xctrace も入り、自分で保存して終わる。run は通常の完了経路で `finish` に来る
// - fleetest の即死(2回目の中断の exit(143)・SIGKILL): 見張りの sh(`watcherScript`)が親の消滅を見て、xctrace が生きていれば
//   SIGINT を送って終わるまで待ち、一時フォルダを消す。**見張りは親の死を生き延びる必要がある**ので `FT_PARENT_PID` を渡さない・
//   InterruptRelay にも載せない(録画の見張り recorder-watch と同じ扱い。自分で終わる)。
//   見張りは各 spawn の直後(開始確認の待ちより前)に起こし、保存・書き出し・結果の書き換え・一時フォルダの削除が終わるまで
//   生かす(cleanup の最後の段で止める)。xctrace が先に終わっても親を見張り続ける
// - `--time-limit`(ResponseTracePolicy.recordTimeLimit)は上の全部が効かなかったときのディスクの安全弁
// 子のパイプは読まない(出力はファイルへ。`readDataToEndOfFile` を使わない規律)

import Foundation
import FTBridgeClient
import FTCore

final class ResponseTraceSession: @unchecked Sendable {
    private let lock = NSLock()
    private let workDir: URL
    private let traceURL: URL
    private let recordCommand: String
    private var recorder: SignalDefaultProcess?
    private var recorderExit: (@Sendable (DispatchTime) -> DispatchTimeoutResult)?
    private var watcher: Process?
    private let startedUptime: TimeInterval
    private var finished = false

    private init(workDir: URL, traceURL: URL, recordCommand: String, recorder: SignalDefaultProcess,
                 recorderExit: @escaping @Sendable (DispatchTime) -> DispatchTimeoutResult, watcher: Process?) {
        self.watcher = watcher
        self.workDir = workDir
        self.traceURL = traceURL
        self.recordCommand = recordCommand
        self.recorder = recorder
        self.recorderExit = recorderExit
        self.startedUptime = ProcessInfo.processInfo.systemUptime
    }

    /// 親(fleetest)が居る間は待ち続け(xctrace が先に終わっても)、親が消えたら後始末する:
    /// 記録の xctrace(`$2`)へ SIGINT(保存させる)、一時フォルダ(`$3`)の名前をコマンドラインに持つ他のプロセス
    /// (表の書き出しの xctrace export など。パイプ・サブシェルを使わず `pgrep -f` の結果をファイル経由で読む =
    /// サブシェルの sh 自身が一時フォルダを引数に持ち、拾ってしまうため。自分(`$$`)と `$2` は除く)へ SIGTERM を送り、
    /// 全部居なくなるまで最長 30 秒待ち、残れば SIGKILL、最後に一時フォルダを消す。`$1` = 親の pid
    static let watcherScript = """
        scan() {
          pgrep -f -- "$3" > "$3/.pids" 2>/dev/null
          others=""
          while read -r p; do
            [ "$p" = "$$" ] || [ "$p" = "$2" ] || others="$others $p"
          done < "$3/.pids"
        }
        while kill -0 "$1" 2>/dev/null; do sleep 2; done
        kill -INT "$2" 2>/dev/null
        scan
        for p in $others; do kill -TERM "$p" 2>/dev/null; done
        n=0
        while [ "$n" -lt 30 ]; do
          scan
          if [ -z "$others" ] && ! kill -0 "$2" 2>/dev/null; then break; fi
          sleep 1
          n=$((n + 1))
        done
        if [ "$n" -ge 30 ]; then
          for p in $others; do kill -KILL "$p" 2>/dev/null; done
          kill -KILL "$2" 2>/dev/null
        fi
        rm -rf "$3"
        """

    // MARK: 開始

    /// 計測 run で iOS 実機 1 台のときだけ記録を始める(それ以外は nil)。始められなければ理由を 1 行言って nil
    static func startIfNeeded(resolved: ResolvedProfile, log: @escaping (String) -> Void) async -> ResponseTraceSession? {
        guard let spec = ResponseTracePolicy.recordingDevice(resolved: resolved), let configured = spec.udid else {
            return nil
        }
        sweepStaleWorkDirs()
        // xctrace --device に確かめて通ったのはハードウェア UDID。プロファイルは devicectl の識別子で書かれていることがある
        let udid = (try? IOSPhysicalDeviceCatalog.devices())?
            .first { $0.udid == configured || $0.deviceCtlIdentifier == configured }?.udid ?? configured

        let workDir = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
            .appendingPathComponent(ResponseTracePolicy.workDirPrefix + UUID().uuidString, isDirectory: true)
        let traceURL = workDir.appendingPathComponent("run.trace")
        let logURL = workDir.appendingPathComponent("record.log")
        let argv = ResponseTracePolicy.recordArguments(udid: udid, output: traceURL.path)
        let command = argv.joined(separator: " ")
        var watcher: Process?
        func failed(_ reason: String) -> ResponseTraceSession? {
            try? FileManager.default.removeItem(at: workDir)
            watcher?.terminate()
            log(notMeasured(reason))
            return nil
        }
        if let index = ProcessArguments.firstNULIndex(argv) {
            return failed("`xcrun xctrace record` was not started: " + ProcessArguments.nulRefusal(index: index))
        }
        do {
            try FileManager.default.createDirectory(at: workDir, withIntermediateDirectories: true)
            try "\(getpid())\n".write(to: workDir.appendingPathComponent(ResponseTracePolicy.ownerFileName),
                                      atomically: true, encoding: .utf8)
            guard FileManager.default.createFile(atPath: logURL.path, contents: nil) else {
                return failed("could not create the trace log in \(workDir.path)")
            }
        } catch {
            return failed("could not prepare the trace folder: \(error.localizedDescription)")
        }

        // **Process で起こさない**: run の間 InterruptRelay が SIGINT を SIG_IGN にしており、無視の設定は exec を越えて子へ
        // 引き継がれる = xctrace が停止の SIGINT を無視して保存しないまま上限で殺された(iPhone SE3 で実際に起きた)。
        // posix_spawn で SIGINT/SIGTERM/SIGHUP を既定に戻して起こす(/bin/sh の trap では起動時に無視だった合図を戻せない)
        var started: SignalDefaultProcess?
        for attempt in 1...ResponseTracePolicy.startAttempts {
            _ = FileManager.default.createFile(atPath: logURL.path, contents: nil) // 前の試行の出力を消す
            let process: SignalDefaultProcess
            do {
                process = try SignalDefaultProcess.launch(executable: "/usr/bin/xcrun", arguments: Array(argv.dropFirst()),
                                                          logPath: logURL.path)
            } catch {
                return failed("`\(command)` could not be started: \(error)")
            }
            // 開始確認の待ちの間に親が死んでも xctrace を取り残さないよう、spawn の直後に見張りを起こす(試行ごとに起こし直す)
            watcher?.terminate()
            watcher = Self.launchWatcher(recorderPID: process.processIdentifier, workDir: workDir)
            // 録り始めの印(`Ctrl-C to stop the recording`)か終了まで待つ。最初の出力で抜けない —— 開始の失敗の文が最初の出力になる。
            // 印が出ないまま尽きても失敗にはしない(startConfirmSeconds の宣言)
            let deadline = ProcessInfo.processInfo.systemUptime + ResponseTracePolicy.startConfirmSeconds
            var exitedEarly = false
            while ProcessInfo.processInfo.systemUptime < deadline {
                if !process.isRunning { exitedEarly = true; break }
                if let text = try? String(contentsOf: logURL, encoding: .utf8),
                   text.contains(ResponseTracePolicy.recordingStartedMarker) { break }
                try? await Task.sleep(nanoseconds: 200_000_000)
            }
            if !exitedEarly {
                started = process
                break
            }
            watcher?.terminate()
            watcher = nil
            let output = (try? String(contentsOf: logURL, encoding: .utf8)) ?? ""
            if attempt < ResponseTracePolicy.startAttempts,
               output.contains(ResponseTracePolicy.targetNotFoundMessage) {
                try? await Task.sleep(nanoseconds: 1_000_000_000)
                continue
            }
            return failed("`\(command)` exited with status \(process.terminationStatus)" + tail(of: logURL)
                          + (attempt > 1 ? " (after \(attempt) attempts)" : ""))
        }
        guard let process = started else { return failed("`\(command)` did not start") }
        let exitWait: @Sendable (DispatchTime) -> DispatchTimeoutResult = { process.waitExit(until: $0) }

        return ResponseTraceSession(workDir: workDir, traceURL: traceURL, recordCommand: command,
                                    recorder: process, recorderExit: exitWait, watcher: watcher)
    }

    private static func launchWatcher(recorderPID: Int32, workDir: URL) -> Process? {
        let sh = Process()
        sh.executableURL = URL(fileURLWithPath: "/bin/sh")
        sh.arguments = ["-c", watcherScript, "fleetest-trace-watch", String(getpid()),
                        String(recorderPID), workDir.path]
        sh.standardInput = FileHandle.nullDevice
        sh.standardOutput = FileHandle.nullDevice
        sh.standardError = FileHandle.nullDevice
        return (try? sh.run()) != nil ? sh : nil
    }

    // MARK: 終了

    /// 記録を止め、表を書き出し、この run の結果 JSON へ最初のフレームを入れる。失敗は 1 行言って結果には触らない。
    /// どの経路でも最後に一時フォルダを消す。`runDir` が無ければ(記録を作らない run)止めて消すだけ
    func finish(runDir: URL?, log: @escaping (String) -> Void) async {
        let stopFailure = await stopRecording()
        defer { cleanup() }
        if let stopFailure {
            log(Self.notMeasured(stopFailure))
            return
        }
        guard let runDir else { return }
        let outcome = await Task.detached(priority: .utility) { self.analyze(runDir: runDir) }.value
        switch outcome {
        case .failed(let reason):
            log(Self.notMeasured(reason))
        case .patched(let steps, let scenarios, let outside, let unbounded):
            guard steps > 0 || outside > 0 || unbounded > 0 else { return }
            var line = "ℹ️ First frame filled in from the Instruments trace for \(steps) step(s) in \(scenarios) scenario(s)"
            if outside > 0 {
                line += "; \(outside) step(s) whose first touch is outside the recorded range were left empty"
            }
            if unbounded > 0 {
                line += "; \(unbounded) step(s) without an observation end time were left empty"
            }
            log(line)
        }
    }

    /// 後始末(冪等)。まだ録っていれば SIGINT で止めて待ち、一時フォルダを消す。呼び手の defer 用
    func cleanup() {
        lock.lock()
        if finished { lock.unlock(); return }
        finished = true
        let watcher = self.watcher
        let process = recorder
        let exitWait = recorderExit
        recorder = nil
        recorderExit = nil
        self.watcher = nil
        lock.unlock()
        if let process, process.isRunning {
            kill(process.processIdentifier, SIGINT)
            // 保存を待つ(消す前に書き込みが終わっていること)。エラー経路なので長くは待たない
            if let exitWait, exitWait(.now() + Self.cleanupWaitSeconds) == .timedOut, process.isRunning {
                kill(process.processIdentifier, SIGKILL)
            }
        }
        try? FileManager.default.removeItem(at: workDir)
        // 見張りは最後に止める(保存・削除が終わる前に親が死んでも、見張りが後始末を引き取れるように)
        watcher?.terminate()
    }

    /// エラー経路で xctrace の終了を待つ上限(秒)。根拠: 結果を使わず捨てるだけなので、保存の完了までは待たず
    /// 書き込み中のファイルを消す前に止まったと言える程度(SIGINT から終了までは試作で数秒)
    static let cleanupWaitSeconds = 15.0

    /// SIGINT で止めて保存の終わりを待つ。失敗の理由(1 行)か nil
    private func stopRecording() async -> String? {
        // 見張りは止めない(解析と一時フォルダの削除が終わる cleanup の最後まで生かす)
        let (process, exitWait) = lock.withLock {
            let taken = (recorder, recorderExit)
            recorderExit = nil
            return taken
        }
        guard let process, let exitWait else { return "the trace recorder was already stopped" }
        let recorded = ProcessInfo.processInfo.systemUptime - startedUptime
        if process.isRunning { kill(process.processIdentifier, SIGINT) }
        let limit = ResponseTracePolicy.stopLimitSeconds(recordedSeconds: recorded)
        let exited = await Task.detached { exitWait(.now() + limit) == .success }.value
        guard exited else {
            if process.isRunning { kill(process.processIdentifier, SIGKILL) }
            return "`\(recordCommand)` did not finish saving within \(Int(limit))s after the stop signal (killed)"
                + Self.tail(of: workDir.appendingPathComponent("record.log"))
        }
        return nil
    }

    private enum Analysis {
        case failed(String)
        case patched(steps: Int, scenarios: Int, outside: Int, unbounded: Int)
    }

    /// 表の書き出し → 換算 → 結果の書き換え。ブロックするので detached で呼ぶ
    private func analyze(runDir: URL) -> Analysis {
        let timeInfoXML = workDir.appendingPathComponent("time-info.xml")
        let surfacesXML = workDir.appendingPathComponent("surfaces.xml")
        let tocXML = workDir.appendingPathComponent("toc.xml")
        let tableJobs: [(String, URL)] = [(ResponseTracePolicy.timeInfoSchema, timeInfoXML),
                                          (ResponseTracePolicy.displayedSurfacesSchema, surfacesXML)]
        for (schema, out) in tableJobs {
            let args = ResponseTracePolicy.exportTableArguments(trace: traceURL.path, schema: schema, output: out.path)
            if let failure = Self.run(args) { return .failed(failure) }
        }
        // 記録の長さは任意(無ければ最後のフレームまでを覆う範囲にする = 外へ倒れる)
        let tocFailed = Self.run(ResponseTracePolicy.exportTocArguments(trace: traceURL.path, output: tocXML.path)) != nil
        let duration = tocFailed ? nil : (try? Data(contentsOf: tocXML)).flatMap { XctraceToc.durationSeconds(xml: $0) }

        guard let timeInfoTable = (try? Data(contentsOf: timeInfoXML)).flatMap({ XctraceTable.parse(xml: $0) }),
              let timeInfo = ResponseTracePatch.timeInfo(from: timeInfoTable) else {
            return .failed("the Instruments trace has no readable \(ResponseTracePolicy.timeInfoSchema) table")
        }
        guard let surfacesTable = (try? Data(contentsOf: surfacesXML)).flatMap({ XctraceTable.parse(xml: $0) }) else {
            return .failed("the Instruments trace has no readable \(ResponseTracePolicy.displayedSurfacesSchema) table")
        }
        let surfaces = ResponseTracePatch.surfaces(timeInfo: timeInfo, table: surfacesTable)
        guard let coverage = ResponseTracePatch.coverage(
            timeInfo: timeInfo, durationSeconds: duration, lastSurfaceEndMs: surfaces.lastEndMs) else {
            return .failed("the Instruments trace has no usable time range")
        }
        var steps = 0
        var outside = 0
        var unbounded = 0
        let scenarios = RunResultsStore.rewriteScenarios(runDir: runDir) { record in
            let patched = ResponseTracePatch.apply(surfaceMs: surfaces.times, coverage: coverage, to: record)
            outside += patched.outside
            unbounded += patched.unbounded
            guard patched.changed > 0 else { return nil }
            steps += patched.changed
            Self.patchReport(before: record, after: patched.record)
            return patched.record
        }
        return .patched(steps: steps, scenarios: scenarios, outside: outside, unbounded: unbounded)
    }

    /// Markdown レポート(reports/scenario-*.md)の該当ステップの行へも最初のフレームを足す。
    /// `reportPath` は絶対パスか、パッケージルート相対。解決できない・読めない・書けないときは何もしない(結果 JSON は書き換え済み)
    private static func patchReport(before: ScenarioRunRecord, after: ScenarioRunRecord) {
        guard let path = after.reportPath else { return }
        let url = path.hasPrefix("/")
            ? URL(fileURLWithPath: path) : ScenarioHost.packageRoot()?.appendingPathComponent(path)
        guard let url, let markdown = try? String(contentsOf: url, encoding: .utf8),
              let updated = ResponseReportPatch.patching(markdown: markdown, before: before, after: after) else { return }
        try? updated.write(to: url, atomically: true, encoding: .utf8)
    }

    /// 外部コマンドを撃つ。失敗の理由(コマンドと終了コード)か nil
    private static func run(_ args: [String]) -> String? {
        do {
            let result = try Shell.run(args, timeout: ResponseTracePolicy.exportTimeoutSeconds)
            guard result.status == 0 else {
                return "`\(args.joined(separator: " "))` exited with status \(result.status)"
            }
            return nil
        } catch {
            return "`\(args.joined(separator: " "))` failed: \(error.localizedDescription)"
        }
    }

    // MARK: 文言と残骸の掃除

    static func notMeasured(_ reason: String) -> String {
        "⚠️ First frame was not measured on this run: \(reason)"
    }

    /// 出力ファイルの末尾(最後の空でない 3 行・300 文字まで)。無ければ空
    private static func tail(of url: URL) -> String {
        guard let text = try? String(contentsOf: url, encoding: .utf8) else { return "" }
        let lines = text.split(separator: "\n").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
        guard !lines.isEmpty else { return "" }
        return ": " + String(lines.suffix(3).joined(separator: " / ").prefix(300))
    }

    /// 前の run が殺されて残した一時フォルダを消す(判定は ResponseTracePolicy.isStale)
    private static func sweepStaleWorkDirs() {
        let tmp = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
        guard let names = try? FileManager.default.contentsOfDirectory(atPath: tmp.path) else { return }
        let now = Date()
        for name in names where name.hasPrefix(ResponseTracePolicy.workDirPrefix) {
            let dir = tmp.appendingPathComponent(name, isDirectory: true)
            let pid = (try? String(contentsOf: dir.appendingPathComponent(ResponseTracePolicy.ownerFileName),
                                   encoding: .utf8))
                .flatMap { Int32($0.trimmingCharacters(in: .whitespacesAndNewlines)) }
            let modified = (try? FileManager.default.attributesOfItem(atPath: dir.path)[.modificationDate] as? Date) ?? now
            if ResponseTracePolicy.isStale(
                name: name, ownerPID: pid, ownerAlive: pid.map { ProcessLiveness.isAlive($0) } ?? false,
                ageSeconds: now.timeIntervalSince(modified)) {
                try? FileManager.default.removeItem(at: dir)
            }
        }
    }
}

/// 合図の扱いを既定に戻して起こした子プロセス(posix_spawn)。`Process` の代わりに、使う分だけ(生死・pid・終了コード・終了待ち)を持つ。
/// 刈り取り(waitpid)は起動直後に立てる専用のスレッドが1回だけ行う(他所で waitpid しない)
final class SignalDefaultProcess: @unchecked Sendable {
    // 不変条件: exited / status は lock の内側でだけ読み書きする。pid は起動後に変わらない
    let processIdentifier: pid_t
    private let lock = NSLock()
    private let exitSemaphore = DispatchSemaphore(value: 0)
    private var exited = false
    private var status: Int32 = 0

    struct LaunchError: Error, CustomStringConvertible {
        let errno: Int32
        var description: String { "posix_spawn failed (\(String(cString: strerror(errno))))" }
    }

    private init(pid: pid_t) { processIdentifier = pid }

    /// stdin は /dev/null、stdout と stderr は logPath(既存のファイルへ追記)
    static func launch(executable: String, arguments: [String], logPath: String) throws -> SignalDefaultProcess {
        var attr: posix_spawnattr_t?
        posix_spawnattr_init(&attr)
        defer { posix_spawnattr_destroy(&attr) }
        var defaults = sigset_t()
        sigemptyset(&defaults)
        for sig in [SIGINT, SIGTERM, SIGHUP] { sigaddset(&defaults, sig) }
        posix_spawnattr_setsigdefault(&attr, &defaults)
        var emptyMask = sigset_t()
        sigemptyset(&emptyMask)
        posix_spawnattr_setsigmask(&attr, &emptyMask)
        posix_spawnattr_setflags(&attr, Int16(POSIX_SPAWN_SETSIGDEF | POSIX_SPAWN_SETSIGMASK))

        var actions: posix_spawn_file_actions_t?
        posix_spawn_file_actions_init(&actions)
        defer { posix_spawn_file_actions_destroy(&actions) }
        posix_spawn_file_actions_addopen(&actions, 0, "/dev/null", O_RDONLY, 0)
        posix_spawn_file_actions_addopen(&actions, 1, logPath, O_WRONLY | O_APPEND | O_CREAT, 0o644)
        posix_spawn_file_actions_adddup2(&actions, 1, 2)

        let argv = ([executable] + arguments).map { strdup($0) } + [nil]
        defer { argv.forEach { free($0) } }
        var pid: pid_t = 0
        let result = posix_spawn(&pid, executable, &actions, &attr, argv, environ)
        guard result == 0 else { throw LaunchError(errno: result) }
        let child = SignalDefaultProcess(pid: pid)
        let reaper = Thread { child.reap() }
        reaper.name = "fleetest-trace-reaper"
        reaper.start()
        return child
    }

    private func reap() {
        var raw: Int32 = 0
        while waitpid(processIdentifier, &raw, 0) == -1 && errno == EINTR {}
        lock.withLock {
            exited = true
            status = raw
        }
        exitSemaphore.signal()
    }

    var isRunning: Bool { lock.withLock { !exited } }

    /// 正常終了なら終了コード、合図で終わったら 128 + 合図の番号
    var terminationStatus: Int32 {
        lock.withLock { (status & 0x7f) == 0 ? (status >> 8) & 0xff : 128 + (status & 0x7f) }
    }

    func waitExit(until deadline: DispatchTime) -> DispatchTimeoutResult {
        let result = exitSemaphore.wait(timeout: deadline)
        if result == .success { exitSemaphore.signal() } // 何度でも待てるように戻す
        return result
    }
}
