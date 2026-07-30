// IOSSimulatorVideoRecorder.swift
// iOS シミュレータの録画(xcrun simctl io recordVideo)。長時間常駐+SIGINT 停止のため
// Shell.swift(待ち切り実行)ではなく Process を直接管理する(BridgeLauncher.swift の
// pid 管理パターンを踏襲)。stop() は生ソース(1本以上の .mov)を返すだけで、シナリオ毎の
// クリップ切り出しは VideoRecordingCoordinator/VideoRecordingFinalizer が行う。
//
// watchdog: recordVideo は run の途中で(CoreSimulator 側の要因等で)予期せず死ぬことがある
// (実害: 30ワーカー中1回、録画プロセスが途中死してワーカーの録画が丸ごと欠けた)。停止指示前の
// exit を検知したら別ソースファイル(-part2 等)へ再spawnし、RecordingSource には複数 part を
// 1:1 対応のまま返す(部分的にでも録画を残す。全欠落より部分録画の方が有用という判断)。

import AVFoundation
import Foundation

actor IOSSimulatorVideoRecorder: DeviceVideoRecorderSession {
    /// 予期しない死亡からの再spawn上限。無限リトライで死に続けるデバイスに張り付かないため
    private static let maxRestarts = 5

    private let udid: String
    private let workDir: URL
    private let fileStem: String

    private var stopRequested = false
    private var restarts = 0
    private var partIndex = 0
    private var process: Process?
    /// 進行中 part の exit 監視タスク。stop() 側はこれの完了(=最後の part の確定)を待つ
    private var watchTask: Task<Void, Never>?
    /// 確定済み(死亡+再spawn または通常停止)の part。files/segments と 1:1 対応する順で積む
    private var parts: [(url: URL, startedAt: Date, durationMs: Int)] = []

    init(udid: String, workDir: URL, fileStem: String) {
        self.udid = udid
        self.workDir = workDir
        self.fileStem = fileStem
    }

    private func movURL(for index: Int) -> URL {
        workDir.appendingPathComponent(index == 1 ? "\(fileStem).mov" : "\(fileStem)-part\(index).mov")
    }

    func start() async -> Bool {
        killStaleRecording()
        return await spawnNextPart()
    }

    /// run を数十秒間隔で連続させると、直前セッションの CoreSimulator io 解放が間に合わず
    /// recordVideo が実際には録画を開始しない(ファイルが空のまま)ことがある(e2e 連続実行で実害)。
    /// "Recording started" を開始確認として扱い、出なければ仕切り直して再試行する(最大3回)。
    /// 確認できたら watchTask(exit 監視)を張って呼び出し元へ戻る
    private func spawnNextPart() async -> Bool {
        guard !stopRequested else { return false }
        for attempt in 1...3 {
            if await spawnPartOnce() { return true }
            warn("could not confirm recordVideo started (attempt \(attempt)/3)")
            try? await Task.sleep(nanoseconds: 2_000_000_000)
            guard !stopRequested else { return false }
        }
        return false
    }

    private func spawnPartOnce() async -> Bool {
        partIndex += 1
        let url = movURL(for: partIndex)
        try? FileManager.default.removeItem(at: url)

        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/xcrun")
        // codec は h264 固定(再生側 Chromium が HEVC 非対応。hevc にしないこと)
        process.arguments = ["simctl", "io", udid, "recordVideo", "--codec=h264", "--force", url.path]
        // stdout は読まない(/dev/null に捨てる。Pipe のまま放置すると出力がバッファを埋めて
        // 子プロセスをブロックしかねない。ScenarioHost.swift の stderr 並行読みと同じ教訓)
        process.standardOutput = FileHandle.nullDevice
        let stderrPipe = Pipe()
        process.standardError = stderrPipe
        // prepare は必ず run() より前(Shell.swift の ProcessExitWait 契約)
        let exitStream = ProcessExitWait.prepare(process)
        do {
            try process.run()
        } catch {
            warn("cannot start recordVideo: \(error.localizedDescription)")
            return false
        }
        // stderr は**プロセスの生存中ずっと**読み続ける(EOF まで drain)。"Recording started" 検出後に
        // 読み手を終えると読み口が閉じ、simctl が停止時の stderr 出力("Recording completed...")で
        // SIGPIPE 死してファイナライズされない(moov 無しで .mov が読めない)実害があった。
        // "Recording started" の検出は drain タスクから AsyncStream 経由で受け取る
        let (startedSignal, startedCont) = AsyncStream<Date>.makeStream()
        let stderrHandle = stderrPipe.fileHandleForReading
        Task.detached {
            for await line in ScenarioHost.lineStream(stderrHandle) {
                if line.contains("Recording started") { startedCont.yield(Date()) }
            }
            startedCont.finish()
        }
        // "Recording started"(最初のフレーム処理済み)が出るまでは開始とみなさない
        let observedStartOrNil = await raceWithDeadline(seconds: 10, onTimeout: Date?.none) {
            for await date in startedSignal { return date }
            return nil
        }
        guard let observedStart = observedStartOrNil else {
            if process.isRunning { process.interrupt() }
            _ = await raceWithDeadline(seconds: 3, onTimeout: ()) { for await _ in exitStream {} }
            if process.isRunning { kill(process.processIdentifier, SIGKILL) }
            try? FileManager.default.removeItem(at: url)
            return false
        }
        self.process = process
        watchTask = Task { [weak self] in
            for await _ in exitStream {}
            await self?.handlePartExited(url: url, startedAt: observedStart)
        }
        return true
    }

    /// exitStream の唯一の消費者(常駐監視)。停止指示前の exit = 予期しない死亡として扱い、
    /// 上限まで再spawnする。呼ばれる契機は「stop() の SIGINT による正常終了」と
    /// 「予期しない死亡」の両方(区別は stopRequested で行う)
    private func handlePartExited(url: URL, startedAt: Date) async {
        process = nil
        await finalizePart(url: url, startedAt: startedAt)
        guard !stopRequested else { return }
        guard restarts < Self.maxRestarts else {
            warn("the recording process keeps dying — giving up on restarts (\(Self.maxRestarts) times; "
                + "keeping what was captured so far)")
            return
        }
        restarts += 1
        warn("the recording process stopped unexpectedly — restarting (\(restarts)/\(Self.maxRestarts))")
        guard await spawnNextPart() else { return }
        // 再spawn の完了(最大10秒×3試行かかりうる)を待つ間に stop() が既に呼ばれていた場合の
        // 後始末(狭いレースだが、放置すると孤児プロセスが残る)
        if stopRequested { process?.interrupt() }
    }

    /// 死亡時点のファイルは duration が読めれば parts に含め、読めなければ(録画が実質空)破棄する
    private func finalizePart(url: URL, startedAt: Date) async {
        guard let duration = try? await AVURLAsset(url: url).load(.duration), duration.isNumeric,
              duration.seconds > 0 else {
            warn("discarding an unreadable recording file (\(url.lastPathComponent))")
            try? FileManager.default.removeItem(at: url)
            return
        }
        parts.append((url, startedAt, Int((duration.seconds * 1000).rounded())))
    }

    func stop() async -> RecordingSource? {
        stopRequested = true
        if let process, let watchTask {
            process.interrupt()  // SIGINT。SIGKILL すると moov 未書き込みでファイルが壊れる
            let exited = await raceWithDeadline(seconds: 15, onTimeout: false) {
                await watchTask.value  // handlePartExited(→finalizePart)の完了を待つ
                return true
            }
            if !exited {
                if kill(process.processIdentifier, 0) == 0 { kill(process.processIdentifier, SIGKILL) }
                warn("stopping the recording timed out after 15s — discarding the final segment")
                try? FileManager.default.removeItem(at: movURL(for: partIndex))
            }
        }
        guard !parts.isEmpty else { return nil }
        return RecordingSource(
            files: parts.map(\.url),
            segments: parts.map {
                RecordingIndexSegment(startedAt: ISO8601Millis.string(from: $0.startedAt),
                                      durationMs: $0.durationMs)
            })
    }

    /// 同じ udid への stale な recordVideo を起動前に best-effort で止める
    private func killStaleRecording() {
        _ = try? Shell.run(["pkill", "-f", "simctl io \(udid) recordVideo"])
    }

    private func warn(_ message: String) {
        FileHandle.standardError.write(Data("⚠️ [recording] \(udid): \(message)\n".utf8))
    }
}
