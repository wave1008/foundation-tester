// `fleetest api recorder-watch`: IOSSimulatorVideoRecorder.handOff が起こす見張り(本体は FTCore.RecorderWatch)。
// **親(fleetest run)より長生きするのが目的**なので、起こす側は FT_PARENT_PID を渡さず、InterruptRelay にも載せない
// (process-lifecycle.md の例外)。client が終わったら自分で終わる。

import ArgumentParser
import Foundation
import FTCore

struct ApiRecorderWatchCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "recorder-watch",
        abstract: "Keep sending SIGINT to a simctl recordVideo client that outlived its stop deadline, then delete its file"
            + " (started by the recorder; outlives the run on purpose)",
        shouldDisplay: false)

    @Option(help: "pid of the recordVideo client")
    var pid: Int32

    @Option(name: .customLong("started-us"), help: "Start time of that pid in microseconds since the epoch (identity check)")
    var startedUs: Int64

    @Option(help: "Absolute path of the file the client writes (deleted once the client is gone)")
    var file: String

    func validate() throws {
        guard pid > 0 else { throw ValidationError("--pid must be positive") }
        guard file.hasPrefix("/") else { throw ValidationError("--file must be an absolute path") }
    }

    func run() async {
        await RecorderWatch.run(target: RecorderWatch.Target(pid: pid, startedMicroseconds: startedUs),
                                file: URL(fileURLWithPath: file), stdin: FileHandle.standardInput)
    }
}
