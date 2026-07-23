// IOSSimulatorVideoRecorder.swift
// iOS シミュレータの録画(xcrun simctl io recordVideo)。長時間常駐+SIGINT 停止のため
// Shell.swift(待ち切り実行)ではなく Process を直接管理する(BridgeLauncher.swift の
// pid 管理パターンを踏襲)。

import Foundation

actor IOSSimulatorVideoRecorder: DeviceVideoRecorderSession {
    private let udid: String
    private let workDir: URL
    private let fileStem: String

    private var process: Process?
    private var exitStream: AsyncStream<Void>?
    private var startedAt: Date?

    private var movURL: URL { workDir.appendingPathComponent("\(fileStem).mov") }
    private var mp4URL: URL { workDir.appendingPathComponent("\(fileStem).mp4") }

    init(udid: String, workDir: URL, fileStem: String) {
        self.udid = udid
        self.workDir = workDir
        self.fileStem = fileStem
    }

    func start() async -> Bool {
        killStaleRecording()
        try? FileManager.default.removeItem(at: movURL)

        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/xcrun")
        // codec は h264 固定(再生側 Chromium が HEVC 非対応。hevc にしないこと)
        process.arguments = ["simctl", "io", udid, "recordVideo", "--codec=h264", "--force", movURL.path]
        // stdout は読まない(/dev/null に捨てる。Pipe のまま放置すると出力がバッファを埋めて
        // 子プロセスをブロックしかねない。ScenarioHost.swift の stderr 並行読みと同じ教訓)
        process.standardOutput = FileHandle.nullDevice
        let stderrPipe = Pipe()
        process.standardError = stderrPipe
        // prepare は必ず run() より前(Shell.swift の ProcessExitWait 契約)
        let exitStream = ProcessExitWait.prepare(process)
        let spawnedAt = Date()
        do {
            try process.run()
        } catch {
            warn("recordVideo を起動できません: \(error.localizedDescription)")
            return false
        }
        self.process = process
        self.exitStream = exitStream
        // stderr に "Recording started" が出た時点を開始時刻とする(最大10秒。出なければ spawn 時刻で代用)
        let observedStart = await Self.waitForRecordingStarted(
            stderr: stderrPipe.fileHandleForReading, timeoutSeconds: 10)
        self.startedAt = observedStart ?? spawnedAt
        return true
    }

    func stopAndFinalize() async -> [RecordingIndexSegment]? {
        guard let process, let startedAt, let exitStream else { return nil }
        process.interrupt()  // SIGINT。SIGKILL すると moov 未書き込みでファイルが壊れる
        let exited = await raceWithDeadline(seconds: 15, onTimeout: false) {
            for await _ in exitStream {}
            return true
        }
        if !exited {
            if kill(process.processIdentifier, 0) == 0 { kill(process.processIdentifier, SIGKILL) }
            warn("録画停止が15秒でタイムアウトしたため破棄します")
            try? FileManager.default.removeItem(at: movURL)
            return nil
        }
        guard FileManager.default.fileExists(atPath: movURL.path) else { return nil }
        guard let durationMs = await VideoRecordingFinalizer.transcode(from: movURL, to: mp4URL) else {
            warn("mp4 への変換に失敗しました")
            try? FileManager.default.removeItem(at: movURL)
            return nil
        }
        try? FileManager.default.removeItem(at: movURL)
        return [RecordingIndexSegment(startedAt: ISO8601Millis.string(from: startedAt), durationMs: durationMs)]
    }

    /// 同じ udid への stale な recordVideo を起動前に best-effort で止める
    private func killStaleRecording() {
        _ = try? Shell.run(["pkill", "-f", "simctl io \(udid) recordVideo"])
    }

    private func warn(_ message: String) {
        FileHandle.standardError.write(Data("⚠️ [recording] \(udid): \(message)\n".utf8))
    }

    private static func waitForRecordingStarted(stderr: FileHandle, timeoutSeconds: Double) async -> Date? {
        await raceWithDeadline(seconds: timeoutSeconds, onTimeout: Date?.none) { () async -> Date? in
            for await line in ScenarioHost.lineStream(stderr) {
                if line.contains("Recording started") { return Date() }
            }
            return nil
        }
    }
}
