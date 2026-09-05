// Shell.swift
// 外部コマンド実行ヘルパー(xcodebuild / simctl / adb などで共用)。

import Foundation

/// 子プロセスの終了待ち。Process.waitUntilExit() は使わない: RunLoop 通知に依存し、
/// Swift Concurrency の協調スレッド上では終了通知を取りこぼして永久ハングし得る
/// (watchdog の SIGKILL 後に run 全体が凍結した実害あり)。terminationHandler は
/// Foundation が子を reap した後に必ず呼ばれるため、これを終了シグナルに使う。
/// 契約: prepare 系は必ず process.run() より前に呼ぶ(起動後だと発火を取りこぼし得る)。
public enum ProcessExitWait {
    /// async 待機用。返り値を `for await _ in stream {}` で待つ。
    /// AsyncStream はバッファするため、await より先に終了しても取りこぼさない。
    public static func prepare(_ process: Process) -> AsyncStream<Void> {
        let (stream, continuation) = AsyncStream.makeStream(of: Void.self)
        process.terminationHandler = { _ in continuation.finish() }
        return stream
    }

    /// 同期待機用。返り値のクロージャが終了までブロックする。
    public static func prepareBlocking(_ process: Process) -> () -> Void {
        let semaphore = DispatchSemaphore(value: 0)
        process.terminationHandler = { _ in semaphore.signal() }
        return { semaphore.wait() }
    }

    /// 時限同期待機用。返り値に deadline を渡すと、子の終了 or 期限到達まで待って結果を返す。
    public static func prepareTimed(_ process: Process) -> (DispatchTime) -> DispatchTimeoutResult {
        let semaphore = DispatchSemaphore(value: 0)
        process.terminationHandler = { _ in semaphore.signal() }
        return { semaphore.wait(timeout: $0) }
    }
}

public enum ShellError: Error, CustomStringConvertible {
    /// timeout 指定付き run で期限超過し子を kill した(wedge した adb/simctl 等)。
    case timedOut(args: [String], seconds: Double)
    public var description: String {
        switch self {
        case let .timedOut(args, seconds):
            return "the command timed out after \(seconds)s (killed): \(args.joined(separator: " "))"
        }
    }
}

/// パイプの読み取りを**中断できる**形で持つ(`readDataToEndOfFile` は EOF まで戻らない)。
/// 孫プロセスが書込端を継承したまま残ると EOF は永遠に来ないので、呼び手が期限で `cancel()` する。
/// `poll` の刻み(200ms)は「中断の応答性」だけを決め、読み取りの遅さには効かない
private final class PipeDrain {
    private let fd: Int32
    private let lock = NSLock()
    private var buffer = Data()
    private var cancelled = false
    let done = DispatchSemaphore(value: 0)

    init(fd: Int32) { self.fd = fd }

    var data: Data { lock.lock(); defer { lock.unlock() }; return buffer }

    func start() {
        DispatchQueue.global(qos: .utility).async { [self] in
            var chunk = [UInt8](repeating: 0, count: 65536)
            loop: while true {
                var pfd = pollfd(fd: fd, events: Int16(POLLIN), revents: 0)
                let ready = poll(&pfd, 1, 200)
                lock.lock(); let stop = cancelled; lock.unlock()
                if stop { break }
                if ready == 0 { continue }
                if ready < 0 { if errno == EINTR { continue } else { break } }
                let n = read(fd, &chunk, chunk.count)
                if n > 0 {
                    lock.lock(); buffer.append(contentsOf: chunk[0..<n]); lock.unlock()
                } else if n == 0 {
                    break loop  // EOF = 書込端が全部閉じた
                } else if errno != EINTR {
                    break loop
                }
            }
            done.signal()
        }
    }

    /// 以後の読み取りをやめる。既に読めたぶんは `data` に残る
    func cancel() { lock.lock(); cancelled = true; lock.unlock() }
}

public enum Shell {
    public struct Result {
        public let status: Int32
        public let output: String
        /// エラー表示用にログ末尾だけ返す
        public var tail: String {
            let lines = output.split(separator: "\n")
            return lines.suffix(30).joined(separator: "\n")
        }
    }

    /// timeout(秒)を渡すと、期限超過時に子を SIGTERM→(2s猶予後)SIGKILL して
    /// `ShellError.timedOut` を投げる。wedge した adb/simctl が締切ポーリングを無効化するのを防ぐ。
    @discardableResult
    public static func run(_ args: [String], cwd: URL? = nil, timeout: Double? = nil) throws -> Result {
        let (status, data) = try runRaw(args, cwd: cwd, timeout: timeout)
        return Result(status: status, output: String(data: data, encoding: .utf8) ?? "")
    }

    /// スクリーンショット等のバイナリ出力用(stdout のみ。stderr は捨てる)
    public static func runData(_ args: [String], cwd: URL? = nil,
                               timeout: Double? = nil) throws -> (status: Int32, data: Data) {
        try runRaw(args, cwd: cwd, mergeStderr: false, timeout: timeout)
    }

    /// 子の終了(reap)後に出力の EOF を待つ猶予(秒)。子自身の出力は終了時点でパイプに入っており、
    /// 64KB 飽和ぶんの排出はミリ秒で終わる。EOF がそれ以上遅れるのは**孫が書込端を継承したまま
    /// 残っている**形だけ(adb の常駐化・`&` のバックグラウンド等。実測 2026-09-05: `(sleep 3) &` の
    /// 孫で 3 秒、`trap '' TERM` の孫で 30 秒返らなかった)。孫の出力はこのコマンドの出力ではないので
    /// ここで打ち切る。**尽きたとき**(猶予内に EOF が来ず出力が欠けた)は読めたぶんを返す
    public static let outputDrainGraceSeconds: Double = 1.0

    /// SIGTERM から SIGKILL へ上げるまでの猶予(秒)。InterruptRelay の ssh と同じ 2 秒
    static let killGraceSeconds: Double = 2.0

    static func runRaw(_ args: [String], cwd: URL? = nil,
                       mergeStderr: Bool = true, timeout: Double? = nil) throws -> (Int32, Data) {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        process.arguments = args
        if let cwd { process.currentDirectoryURL = cwd }
        let pipe = Pipe()
        process.standardOutput = pipe
        if mergeStderr {
            process.standardError = pipe
        } else {
            process.standardError = FileHandle.nullDevice
        }

        // 出力はバックグラウンドで排出する(パイプ 64KB 飽和で子がブロックするのを防ぐ)。
        // **読み取りは EOF を待ち切らない**(PipeDrain の doc): 子の終了後は outputDrainGraceSeconds で打ち切る
        let drain = PipeDrain(fd: pipe.fileHandleForReading.fileDescriptor)
        let waitExit = ProcessExitWait.prepareTimed(process)  // 契約: run() より前に設定
        try process.run()
        drain.start()
        let pid = process.processIdentifier

        // 子孫ごと止める。Foundation.Process は子を新しいプロセスグループのリーダーにする
        // (実測 2026-09-05: pgid == 子の pid)ので `killpg` で孫まで届く。`kill(pid,…)` だけだと
        // `trap '' TERM` を継いだ孫が SIGKILL を受けずパイプを握り続ける(Codex 指摘)。
        // グループが取れない環境では直接の子へ落とす
        func signalGroup(_ sig: Int32) {
            if killpg(pid, sig) != 0 { _ = kill(pid, sig) }
        }
        func collect() -> Data {
            if drain.done.wait(timeout: .now() + outputDrainGraceSeconds) == .timedOut {
                // 読み手が抜けてから閉じる(開いたまま閉じると fd 番号が再利用され、読み手が無関係な
                // fd を読む)。cancel 後は poll の刻み(200ms)+ 1 回の read で必ず抜けるので無期限で待てる
                drain.cancel()
                drain.done.wait()
            }
            try? pipe.fileHandleForReading.close()
            return drain.data
        }

        let deadline: DispatchTime = timeout.map { .now() + $0 } ?? .distantFuture
        if waitExit(deadline) == .timedOut, let timeout {
            signalGroup(SIGTERM)
            if waitExit(.now() + killGraceSeconds) == .timedOut {
                signalGroup(SIGKILL)
                // SIGKILL は無視できないので reap は必ず来る(D 状態で遅れることはある)
                _ = waitExit(.distantFuture)
            }
            _ = collect()
            throw ShellError.timedOut(args: args, seconds: timeout)
        }
        let data = collect()
        return (process.terminationStatus, data)
    }
}
