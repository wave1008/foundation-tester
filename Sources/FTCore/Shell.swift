// Shell.swift
// 外部コマンド実行ヘルパー(xcodebuild / simctl / adb などで共用)。

import Foundation

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
        try process.run()
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        return (process.terminationStatus, data)
    }
}
