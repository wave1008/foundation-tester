// FM の常駐プロセス `fleetest api fm-serve`: 画像を伴う FM の呼び出しを 1 つのプロセスに集め、Unix ドメインソケットで答える。
// 起こすのは FTCore の `FMServeHost.ensureRunning`(run の開始・死活の確かめ・doctor)。設計は Sources/FTCore/FMServe.swift 冒頭。
// 本体は Sources/FTFoundationModels/FMServeServer.swift。
// 終了条件: どこからも要求が無いまま `FMServeWire.idleExitSeconds`・shutdown の要求・SIGTERM/SIGINT。ソケットのファイルは終了時に消す。
// **stdin・親の死では終わらない**(常駐 = 起こした run より長く生きる。stdin は /dev/null で起こされる)。
// 孤児の監視(`ResidentProcessGuard.startOrphanWatchdog`)も付けない —— 親が居なくなるのが前提のプロセス。

import ArgumentParser
import Foundation
import FTCore
import FTFoundationModels

struct ApiFMServeCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "fm-serve",
        abstract: "Serve on-device Foundation Models calls with images from one long-lived process over a Unix"
            + " domain socket, keeping the model loaded between calls (started by `fleetest run` / `fleetest api run`;"
            + " exits after \(Int(FMServeWire.idleExitSeconds / 60)) minutes without requests or on SIGTERM/SIGINT)")

    @Option(help: "Unix domain socket path (default: ~/.fleetest/fm.sock)")
    var socket: String?

    func run() async throws {
        guard let path = socket ?? FMServeWire.socketPath() else {
            ConsoleOut.err("[fm-serve] the socket path does not fit in sun_path")
            throw ExitCode.failure
        }
        let stop = StopFlag()
        // 読み手の居ない stdout/stderr への書き込みで落ちない
        signal(SIGPIPE, SIG_IGN)
        signal(SIGTERM, SIG_IGN)
        signal(SIGINT, SIG_IGN)
        let queue = DispatchQueue(label: "fleetest-api-fm-serve-signal")
        let sources = [SIGTERM, SIGINT].map { sig in
            let source = DispatchSource.makeSignalSource(signal: sig, queue: queue)
            source.setEventHandler { stop.set() }
            source.resume()
            return source
        }
        defer { for source in sources { source.cancel() } }

        // accept のループはブロッキングの Thread 上で回す(協調スレッドプールを塞がない)
        let code: Int32 = await withCheckedContinuation { continuation in
            let thread = Thread {
                continuation.resume(returning: FMServeServer.run(
                    socketPath: path, shouldStop: { stop.isSet },
                    log: { ConsoleOut.err("[fm-serve] \(Self.timestamp()) " + $0) }))
            }
            thread.name = "fleetest-api-fm-serve"
            thread.start()
        }
        if code != 0 { throw ExitCode(code) }
    }

    private static func timestamp() -> String {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd HH:mm:ss"
        return formatter.string(from: Date())
    }
}
