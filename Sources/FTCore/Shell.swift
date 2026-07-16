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

    @discardableResult
    public static func run(_ args: [String], cwd: URL? = nil) throws -> Result {
        let (status, data) = try runRaw(args, cwd: cwd)
        return Result(status: status, output: String(data: data, encoding: .utf8) ?? "")
    }

    /// スクリーンショット等のバイナリ出力用(stdout のみ。stderr は捨てる)
    public static func runData(_ args: [String], cwd: URL? = nil) throws -> (status: Int32, data: Data) {
        try runRaw(args, cwd: cwd, mergeStderr: false)
    }

    static func runRaw(_ args: [String], cwd: URL? = nil,
                       mergeStderr: Bool = true) throws -> (Int32, Data) {
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
        let waitForExit = ProcessExitWait.prepareBlocking(process)
        try process.run()
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        waitForExit()
        return (process.terminationStatus, data)
    }
}
