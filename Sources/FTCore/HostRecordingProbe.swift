// HostRecordingProbe.swift
// run の**開始前**に、iOS シミュレータに「端末側の録画セッション」が残っていないかを確かめる。
//
// 残っているデバイスでは `simctl io recordVideo` が即座に EBUSY(文言は busyMarkers の2通り)
// で落ち、**client プロセスが1つも無くても解けない**(シミュレータの shutdown → boot でだけ解ける。
// 実測: 停止 5 秒 + 起動・ブリッジ 28 秒で解消)。録画の開始時(IOSSimulatorVideoRecorder.start)に
// 気付いてもブリッジが張られた後なので再起動できず、そのデバイスの録画は run の間ずっと欠ける。
// そこで供給の段階でここを通し、busy のデバイスだけを再起動させる(呼び出しは ProfileWorkerFactory)。
//
// 作り方の規律は IOSSimulatorVideoRecorder と同じ: **停止は SIGINT だけ**(SIGKILL/SIGTERM で殺した
// recordVideo はそれ自体が端末側のセッションを残す = この検査がこの状態を作ってしまう)。

import Foundation

public enum HostRecordingProbe {
    /// 検査の結果。**不明を空きと混ぜない**(不明のデバイスは再起動しない = 何もしないのと同じ)
    public enum Outcome: Sendable, Equatable {
        /// 録画を始められた(テスト用の録画は SIGINT で閉じた)
        case free
        /// 端末側にセッションが残っている(再起動が要る)
        case busy
        /// どちらとも言えない(simctl を起こせない・期限内に何も言わない・無言で終わった)
        case unknown
    }

    /// simctl の stderr の文言。IOSSimulatorVideoRecorder と共有する(片方だけ変えない)。
    /// busy は2通り出る(どちらも EBUSY・Code=16): 端末側に残ったセッション = "Host recording …" /
    /// 止まらなかった録画が端末側で撮り続けている = "A recording …"(8 台で採取。client が消えても解けず、
    /// shutdown → boot で解けた = 同じ処置で直る)。1マシン1 run で録画するのは run だけなので、他人の録画を巻き込まない
    static let busyMarkers = ["Host recording is already in progress", "A recording is already in progress"]
    static let startedMarker = "Recording started"

    static func isBusy(line: String) -> Bool {
        busyMarkers.contains { line.contains($0) }
    }

    /// stderr の1行から結果が決まるか(純粋関数)
    static func classify(line: String) -> Outcome? {
        if isBusy(line: line) { return .busy }
        if line.contains(startedMarker) { return .free }
        return nil
    }

    /// 開始か busy のどちらかを simctl が言うまでの上限(秒)。IOSSimulatorVideoRecorder が
    /// "Recording started" を待つ上限と同じ値(健全機では 1 秒未満で出る)
    static let decisionTimeoutSeconds: Double = 10
    /// SIGINT 後に終了を待つ上限(秒)。**尽きても SIGKILL しない**(ファイル冒頭の理由)
    static let stopGraceSeconds: Double = 15

    /// 検査に使う .mov のパス(純粋関数)。**呼び出しごとに一意**(`nonce`。既定は UUID)—— 置き場は run をまたいで同じなので、
    /// 前回の検査で見張りへ渡した client が後から最終名へ rename する形と、同名では衝突する(見張りが別の client の一時ファイルを消す)
    static func probeFileURL(udid: String, workDir: URL, nonce: String = UUID().uuidString) -> URL {
        workDir.appendingPathComponent("host-recording-probe-\(udid)~\(nonce).mov")
    }

    /// 1台を検査する。`workDir` にテスト用の .mov を一時的に作り、終わったら消す
    public static func probe(udid: String, workDir: URL) async -> Outcome {
        await probe(udid: udid, workDir: workDir, xcrunPath: "/usr/bin/xcrun",
                    decisionTimeout: decisionTimeoutSeconds, stopGrace: stopGraceSeconds)
    }

    /// xcrunPath・期限・時計・見張りの実行ファイルはテスト用(本番は上の入口の値)
    static func probe(udid: String, workDir: URL, xcrunPath: String,
                      decisionTimeout: Double, stopGrace: Double,
                      clock: @escaping @Sendable () -> TimeInterval = IOSSimulatorVideoRecorder.monotonicNow,
                      watcherExecutable: URL? = ExecutablePath.current) async -> Outcome {
        let url = probeFileURL(udid: udid, workDir: workDir)
        try? FileManager.default.createDirectory(at: workDir, withIntermediateDirectories: true)

        let process = Process()
        process.executableURL = URL(fileURLWithPath: xcrunPath)
        process.arguments = ["simctl", "io", udid, "recordVideo"] + SimulatorActiveDisplay.simctlIOArguments(udid: udid)
            + ["--codec=h264", "--force", url.path]
        process.standardOutput = FileHandle.nullDevice
        let stderrPipe = Pipe()
        process.standardError = stderrPipe
        let exitStream = ProcessExitWait.prepare(process)
        do {
            try process.run()
        } catch {
            return .unknown
        }
        // 身元は **spawn の直後にだけ採る**(handOff で採り直さない)
        let target = RecorderWatch.Target.of(process.processIdentifier)
        // stderr は終了まで読み続ける(途中で読み口を閉じると simctl が停止時の出力で SIGPIPE 死し、
        // それ自体がセッションを残しうる。IOSSimulatorVideoRecorder.spawnPartOnce と同じ理由)。
        // 判定は読み手が置き、ここは周期で見る(AsyncStream のレースにすると期限側が勝った周で読み手が cancel される)
        let decided = LockedValue<Outcome?>(nil)
        let started = LockedValue(false)
        let stderrHandle = stderrPipe.fileHandleForReading
        let reader = Task.detached {
            for await line in ScenarioHost.lineStream(stderrHandle) {
                if let outcome = classify(line: line) {
                    if outcome == .free { started.withLock { $0 = true } }
                    decided.withLock { if $0 == nil { $0 = outcome } }
                }
            }
        }
        let deadline = clock() + decisionTimeout
        while decided.value == nil, process.isRunning, clock() < deadline {
            try? await Task.sleep(nanoseconds: UInt64(RecorderWatch.repeatIntervalSeconds * 1_000_000_000))
        }
        // 期限の後に撮り始める client もいるので、撮り始める前に無視された SIGINT を送り直す
        if await IOSSimulatorVideoRecorder.interruptRecorder(process, started: { started.value }, grace: stopGrace, clock: clock) {
            for await _ in exitStream {}
            // **判定を読む前に stderr の読み手が末尾まで読み切るのを短く待つ**(終了済みなので EOF はすぐ来る)。
            // busy を言って自分から終わった client を、読み手の遅れで .unknown(= 再起動しない)にしない
            await raceWithDeadline(seconds: 1, onTimeout: ()) { await reader.value }
            RecorderWatch.removeOutputs(of: url)
        } else {
            let outcome = IOSSimulatorVideoRecorder.handOff(process, target: target, stderr: stderrHandle, leaving: url,
                                                            watcher: watcherExecutable)
            ConsoleOut.err("⚠️ [recording] \(udid): " + IOSSimulatorVideoRecorder.handOffNotice(outcome, file: url, udid: udid))
            if case .watching = outcome {
                // ファイルの所有は見張りへ移った(client が終わってから消す)
            } else {
                RecorderWatch.removeOutputs(of: url)
            }
        }
        return decided.value ?? .unknown
    }
}
