// HooksCommand.swift
// 実行プロファイルの開始/終了スクリプト(docs/remote-runner.md §17)の保守口。
// 実行そのものは run が行う(RunHookRunner)。ここにあるのは、run が defer に到達できずに
// 死んだあとの後始末だけ ―― `remote clean` が誰も見ていないランナー機に対して撃つ。

import ArgumentParser
import Foundation
import FTBridgeClient
import FTCore

struct HooksCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "hooks",
        abstract: "Maintenance for the run profile's setup/teardown scripts (docs/remote-runner.md §17)",
        subcommands: [Reap.self])

    struct Reap: AsyncParsableCommand {
        static let configuration = CommandConfiguration(
            commandName: "reap",
            abstract: "Run the teardown scripts left behind by runs that died before they could clean up")

        func run() async throws {
            let stateDir = try RepoRoot.find().appendingPathComponent(".ftester")
            let reaped = RunHookRunner.reapOrphans(stateDir: stateDir) { print($0) }
            print(reaped == 0
                ? "→ no orphaned teardown scripts"
                : "→ reaped \(reaped) orphaned teardown script(s)")
        }
    }
}
