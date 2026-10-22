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
        abstract: "Maintenance for the run profile's setup/teardown scripts",
        subcommands: [Reap.self])

    struct Reap: AsyncParsableCommand {
        static let configuration = CommandConfiguration(
            commandName: "reap",
            abstract: "Run the teardown scripts left behind by runs that died before they could clean up")

        @Flag(help: "Say nothing when there was nothing to reap (for callers that sweep every namespace on a shared runner)")
        var quiet = false

        func run() async throws {
            let stateDir = try RepoRoot.find().appendingPathComponent(".fleetest")
            // スクリプトの孤児を先に(run-teardown.sh は残っているサービスを使いうる)、サービスの孤児を後に片付ける。
            // サービスの控え(`<pid>~<接頭辞>.json`)は同じ置き場に居るが `reapOrphans` は名前で避ける
            let reaped = RunHookRunner.reapOrphans(stateDir: stateDir) { ConsoleOut.out($0) }
            let services = ServicesReaper.reap(stateDir: stateDir) { ConsoleOut.out($0) }
            if reaped == 0 {
                // **黙るのは「0件のとき」だけ** —— 代行実行したことは共有ランナーでも必ず言う
                // (他人の run の後始末が走ったのに誰も知らない状態を作らない)
                if !quiet { ConsoleOut.out("→ no orphaned teardown scripts") }
            } else {
                ConsoleOut.out("→ reaped \(reaped) orphaned teardown script(s)")
            }
            if services.reaped == 0 && services.unreadable.isEmpty && services.kept.isEmpty {
                if !quiet { ConsoleOut.out("→ no orphaned services") }
            } else {
                ConsoleOut.out("→ services: reaped \(services.reaped), kept \(services.kept.count) with leftovers,"
                    + " \(services.unreadable.count) unreadable lease(s) left in place")
            }
        }
    }
}
