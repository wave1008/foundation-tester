// 補助プロセス `fleetest api vision-serve`: 長寿命のプロセスで Vision の特徴量を計算し、Unix ドメインソケットで答える。
// run の開始時に RunOrchestrator(FTCore の `VisionHelperHost`)が起こし、シナリオのプロセスは Vision の異常を検知したときだけ頼る。
// 本体・通信は Sources/FTCore/VisionHelper*.swift(設計は docs/maintainer-notes.md §67)。
// 終了条件: stdin EOF(親が閉じた)または SIGTERM/SIGINT。ソケットのファイルは終了時に消す。

import ArgumentParser
import Foundation
import FTCore

struct ApiVisionServeCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "vision-serve",
        abstract: "Serve Vision image feature prints over a Unix domain socket from a long-lived process"
            + " (started by `fleetest run` / `fleetest api run`; exits on stdin EOF or SIGTERM/SIGINT)")

    @Option(help: "Unix domain socket path (default: ~/.fleetest/vision-<parent pid>.sock)")
    var socket: String?

    func run() async throws {
        ResidentProcessGuard.startOrphanWatchdog(logLabel: "vision-serve")
        guard let path = socket ?? VisionHelperWire.socketPath(parentPID: getppid()) else {
            ConsoleOut.err("[vision-serve] the socket path does not fit in sun_path")
            throw ExitCode.failure
        }
        let stop = StopFlag()
        // 読み手の居ない stdout/stderr への書き込みで落ちない(補助は何も stdout に出さない)
        signal(SIGPIPE, SIG_IGN)
        let stdinWatcher = Thread {
            while readLine(strippingNewline: true) != nil {}
            stop.set()
            ResidentProcessGuard.scheduleForcedExit(logLabel: "vision-serve")
        }
        stdinWatcher.name = "fleetest-api-vision-serve-stdin"
        stdinWatcher.start()
        signal(SIGTERM, SIG_IGN)
        signal(SIGINT, SIG_IGN)
        let queue = DispatchQueue(label: "fleetest-api-vision-serve-signal")
        let sources = [SIGTERM, SIGINT].map { sig in
            let source = DispatchSource.makeSignalSource(signal: sig, queue: queue)
            source.setEventHandler {
                stop.set()
                ResidentProcessGuard.scheduleForcedExit(logLabel: "vision-serve")
            }
            source.resume()
            return source
        }
        defer { for source in sources { source.cancel() } }

        // accept のループはブロッキングの Thread 上で回す(協調スレッドプールを塞がない)
        let code: Int32 = await withCheckedContinuation { continuation in
            let thread = Thread {
                continuation.resume(returning: VisionHelperServer.run(
                    socketPath: path, shouldStop: { stop.isSet },
                    log: { ConsoleOut.err("[vision-serve] " + $0) }))
            }
            thread.name = "fleetest-api-vision-serve"
            thread.start()
        }
        if code != 0 { throw ExitCode(code) }
    }
}
