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
            return "コマンドが \(seconds)s でタイムアウト(kill 済み): \(args.joined(separator: " "))"
        }
    }
}

/// timeout 経路でバックグラウンドスレッドが書き込む出力バッファ(セマフォで happens-before を確立)。
private final class DataBox { var data = Data() }

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

        guard let timeout else {
            // タイムアウト無し(既存の挙動): 呼び出しスレッドで読み切ってから終了を待つ。
            let waitForExit = ProcessExitWait.prepareBlocking(process)
            try process.run()
            let data = pipe.fileHandleForReading.readDataToEndOfFile()
            waitForExit()
            return (process.terminationStatus, data)
        }

        // タイムアウト有り: readDataToEndOfFile は子の終了(=書込端クローズ)まで返らないため、
        // 呼び出しスレッドでは待たずバックグラウンドで排出(パイプ 64KB 飽和で子がブロックするのも防ぐ)。
        // 終了は terminationHandler のセマフォを時限待ちで検知する。
        let box = DataBox()
        let readDone = DispatchSemaphore(value: 0)
        let readHandle = pipe.fileHandleForReading
        let waitExit = ProcessExitWait.prepareTimed(process)  // 契約: run() より前に設定
        try process.run()
        DispatchQueue.global(qos: .utility).async {
            box.data = readHandle.readDataToEndOfFile()   // 子の終了/kill による書込端クローズで EOF
            readDone.signal()
        }
        if waitExit(.now() + timeout) == .timedOut {
            process.terminate()                            // SIGTERM
            if waitExit(.now() + 2.0) == .timedOut {       // 猶予後も生存していれば強制終了
                kill(process.processIdentifier, SIGKILL)
                _ = waitExit(.distantFuture)               // reap(terminationHandler 発火)を待つ
            }
            readDone.wait()                                // 読み取りスレッドの EOF 完了を待って回収
            throw ShellError.timedOut(args: args, seconds: timeout)
        }
        readDone.wait()
        return (process.terminationStatus, box.data)
    }
}
