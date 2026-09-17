// HostRecordingProbe.swift
// run の**開始前**に、iOS シミュレータに「端末側の録画セッション」が残っていないかを確かめる。
//
// 残っている台では `simctl io recordVideo` が即座に EBUSY("Host recording is already in progress")
// で落ち、**client プロセスが1つも無くても解けない**(シミュレータの shutdown → boot でだけ解ける。
// 実測: 停止 5 秒 + 起動・ブリッジ 28 秒で解消)。録画の開始時(IOSSimulatorVideoRecorder.start)に
// 気付いてもブリッジが張られた後なので再起動できず、その台の録画は run の間ずっと欠ける。
// そこで供給の段階でここを通し、busy の台だけを再起動させる(呼び出しは ProfileWorkerFactory)。
//
// 作り方の規律は IOSSimulatorVideoRecorder と同じ: **停止は SIGINT だけ**(SIGKILL/SIGTERM で殺した
// recordVideo はそれ自体が端末側のセッションを残す = この検査がこの状態を作ってしまう)。

import Foundation

public enum HostRecordingProbe {
    /// 検査の結果。**不明を空きと混ぜない**(不明の台は再起動しない = 何もしないのと同じ)
    public enum Outcome: Sendable, Equatable {
        /// 録画を始められた(テスト用の録画は SIGINT で閉じた)
        case free
        /// 端末側にセッションが残っている(再起動が要る)
        case busy
        /// どちらとも言えない(simctl を起こせない・期限内に何も言わない・無言で終わった)
        case unknown
    }

    /// simctl の stderr の文言。IOSSimulatorVideoRecorder と共有する(片方だけ変えない)
    static let busyMarker = "Host recording is already in progress"
    static let startedMarker = "Recording started"

    /// stderr の1行から結果が決まるか(純粋関数)
    static func classify(line: String) -> Outcome? {
        if line.contains(busyMarker) { return .busy }
        if line.contains(startedMarker) { return .free }
        return nil
    }

    /// 開始か busy のどちらかを simctl が言うまでの上限(秒)。IOSSimulatorVideoRecorder が
    /// "Recording started" を待つ上限と同じ値(健全機では 1 秒未満で出る)
    static let decisionTimeoutSeconds: Double = 10
    /// SIGINT 後に終了を待つ上限(秒)。**尽きても SIGKILL しない**(ファイル冒頭の理由)
    static let stopGraceSeconds: Double = 15

    /// 1台を検査する。`workDir` にテスト用の .mov を一時的に作り、終わったら消す
    public static func probe(udid: String, workDir: URL) async -> Outcome {
        let url = workDir.appendingPathComponent("host-recording-probe-\(udid).mov")
        try? FileManager.default.createDirectory(at: workDir, withIntermediateDirectories: true)
        try? FileManager.default.removeItem(at: url)
        defer { try? FileManager.default.removeItem(at: url) }

        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/xcrun")
        process.arguments = ["simctl", "io", udid, "recordVideo", "--codec=h264", "--force", url.path]
        process.standardOutput = FileHandle.nullDevice
        let stderrPipe = Pipe()
        process.standardError = stderrPipe
        let exitStream = ProcessExitWait.prepare(process)
        do {
            try process.run()
        } catch {
            return .unknown
        }
        // stderr は終了まで読み続ける(途中で読み口を閉じると simctl が停止時の出力で SIGPIPE 死し、
        // それ自体がセッションを残しうる。IOSSimulatorVideoRecorder.spawnPartOnce と同じ理由)
        let (decisions, decisionCont) = AsyncStream<Outcome>.makeStream()
        let stderrHandle = stderrPipe.fileHandleForReading
        Task.detached {
            for await line in ScenarioHost.lineStream(stderrHandle) {
                if let outcome = classify(line: line) { decisionCont.yield(outcome) }
            }
            decisionCont.finish()
        }
        let decided = await raceWithDeadline(seconds: decisionTimeoutSeconds, onTimeout: Outcome?.none) {
            for await outcome in decisions { return outcome }
            return nil  // 何も言わずに終わった
        }
        if process.isRunning { process.interrupt() }
        await raceWithDeadline(seconds: stopGraceSeconds, onTimeout: ()) {
            for await _ in exitStream {}
        }
        return decided ?? .unknown
    }
}
