// `fleetest monitor pause/resume/status` — 拡張が尊重するモニター停止指示(計測条件づくり)。
// `api monitor` を kill しても拡張が数秒で再起動するため、保持ファイル(FTCore.MonitorHold)で
// 伝える。効くのは**この機械の** `api monitor`(観測と、拡張への monitorHold イベント経由で
// 配信ヘルパー)だけ —— リモートランナー機の hold は、そこに接続している別の機械の配信を
// 止めない(fan-out の子は --device-machine 付きで hold を見ない。ApiMonitorCommand 参照)。

import ArgumentParser
import FTBridgeClient
import FTCore
import Foundation

struct MonitorCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "monitor",
        abstract: "Hold or release this machine's device monitor (observation and streaming)",
        discussion: """
        Use before an unattended --performance run: `fleetest monitor pause --for 30` stops the \
        monitor's polling and makes the VSCode extension close its streaming helpers, without \
        killing any process (killed processes just get restarted by the extension). \
        `fleetest monitor resume` releases the hold; an expired --for releases itself.
        """,
        subcommands: [Pause.self, Resume.self, Status.self])

    static func stateDir() throws -> URL {
        try RepoRoot.find().appendingPathComponent(".fleetest")
    }

    struct Pause: AsyncParsableCommand {
        static let configuration = CommandConfiguration(
            abstract: "Stop monitoring and streaming (until `monitor resume`, or for --for minutes)")

        @Option(name: .customLong("for"),
                help: "Release the hold automatically after this many minutes (omit = hold until `monitor resume`)")
        var forMinutes: Double?

        func validate() throws {
            if let forMinutes, !(forMinutes > 0) {
                throw ValidationError("--for must be a positive number of minutes")
            }
        }

        func run() async throws {
            let now = Date()
            let hold = MonitorHold(
                until: forMinutes.map { now.timeIntervalSince1970 + $0 * 60 },
                startedAt: now.timeIntervalSince1970)
            try MonitorHold.save(hold, stateDir: try MonitorCommand.stateDir())
            print("⏸ Monitor \(hold.describe(now: now))"
                + " — the running monitor notices within its polling interval")
        }
    }

    struct Resume: AsyncParsableCommand {
        static let configuration = CommandConfiguration(
            abstract: "Release the hold (idempotent)")

        func run() async throws {
            let wasActive = MonitorHold.clear(stateDir: try MonitorCommand.stateDir())
            print(wasActive ? "▶️ Monitor hold released" : "▶️ No active hold (nothing to release)")
        }
    }

    struct Status: AsyncParsableCommand {
        static let configuration = CommandConfiguration(
            abstract: "Show whether a hold is active")

        func run() async throws {
            guard let hold = MonitorHold.load(stateDir: try MonitorCommand.stateDir()),
                  hold.isActive() else {
                print("▶️ No active hold")
                return
            }
            print("⏸ Monitor \(hold.describe())")
        }
    }
}
