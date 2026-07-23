// AndroidScreenVideoRecorder.swift
// Android の録画(adb shell screenrecord)。1 回の screenrecord は 180 秒上限のため、
// プロセス exit の度に pull → デバイス側ファイル削除 → 次セグメント spawn を停止指示まで
// 繰り返す(セグメントは VideoRecordingFinalizer.concatenate で 1 本の mp4 に連結する)。

import Foundation

actor AndroidScreenVideoRecorder: DeviceVideoRecorderSession {
    private static let segmentTimeLimitSeconds = 180

    private let serial: String
    private let adbPath: String
    private let workDir: URL
    private let fileStem: String

    private var stopRequested = false
    private var size: String?
    private var segmentIndex = 0
    /// pull 済みローカルセグメント(連結順)と各々の spawn 時刻(index.json の startedAt に使う)
    private var pulledSegments: [(url: URL, startedAt: Date)] = []
    private var currentProcess: Process?
    /// 進行中セグメントの exit 監視タスク。stop 側はこれの完了(=最終 pull まで終わったこと)を待つ
    private var watchTask: Task<Void, Never>?

    init(serial: String, adbPath: String, workDir: URL, fileStem: String) {
        self.serial = serial
        self.adbPath = adbPath
        self.workDir = workDir
        self.fileStem = fileStem
    }

    func start() async -> Bool {
        killStaleScreenrecord()
        size = halvedPhysicalSize()
        return await spawnNextSegment()
    }

    func stopAndFinalize() async -> [RecordingIndexSegment]? {
        stopRequested = true
        if currentProcess != nil {
            // ホスト側 adb クライアントを kill してもデバイス上の screenrecord は止まらず
            // ファイルが壊れる。デバイス側プロセスへ直接 kill -2 を送る
            _ = try? Shell.run([adbPath, "-s", serial, "shell", "kill", "-2", "$(pidof screenrecord)"])
            if let watchTask {
                _ = await raceWithDeadline(seconds: 20, onTimeout: ()) { await watchTask.value }
            }
        }
        guard !pulledSegments.isEmpty else { return nil }
        let localURLs = pulledSegments.map(\.url)
        guard let durationsMs = await VideoRecordingFinalizer.concatenate(
            segmentURLs: localURLs, to: finalMP4URL), durationsMs.count == pulledSegments.count else {
            warn("セグメント結合に失敗しました")
            cleanupSegmentFiles()
            return nil
        }
        cleanupSegmentFiles()
        return zip(pulledSegments, durationsMs).map {
            RecordingIndexSegment(startedAt: ISO8601Millis.string(from: $0.0.startedAt), durationMs: $0.1)
        }
    }

    private var finalMP4URL: URL { workDir.appendingPathComponent("\(fileStem).mp4") }

    @discardableResult
    private func spawnNextSegment() async -> Bool {
        guard !stopRequested else { return false }
        segmentIndex += 1
        let remotePath = "/sdcard/ftrec-\(fileStem)-\(segmentIndex).mp4"
        var args = ["-s", serial, "shell", "screenrecord", "--bit-rate", "1500000"]
        if let size { args += ["--size", size] }
        args += ["--time-limit", String(Self.segmentTimeLimitSeconds), remotePath]

        let process = Process()
        process.executableURL = URL(fileURLWithPath: adbPath)
        process.arguments = args
        // stdout/stderr は読まない(/dev/null に捨てる。Pipe のまま放置すると出力がバッファを
        // 埋めて子プロセスをブロックしかねない。IOSSimulatorVideoRecorder と同じ理由)
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        let exitStream = ProcessExitWait.prepare(process)
        let spawnedAt = Date()
        do {
            try process.run()
        } catch {
            warn("screenrecord を起動できません: \(error.localizedDescription)")
            return false
        }
        currentProcess = process
        watchTask = Task { [weak self] in
            for await _ in exitStream {}
            await self?.handleSegmentExited(remotePath: remotePath, startedAt: spawnedAt)
        }
        return true
    }

    private func handleSegmentExited(remotePath: String, startedAt: Date) async {
        let localURL = workDir.appendingPathComponent("\(fileStem)-part\(segmentIndex).mp4")
        if pullSegment(remotePath: remotePath, to: localURL) {
            pulledSegments.append((localURL, startedAt))
        }
        _ = try? Shell.run([adbPath, "-s", serial, "shell", "rm", "-f", remotePath])
        currentProcess = nil
        if !stopRequested {
            await spawnNextSegment()
        }
    }

    private func pullSegment(remotePath: String, to localURL: URL) -> Bool {
        guard let result = try? Shell.run([adbPath, "-s", serial, "pull", remotePath, localURL.path]),
              result.status == 0, FileManager.default.fileExists(atPath: localURL.path) else {
            return false
        }
        return true
    }

    private func cleanupSegmentFiles() {
        for segment in pulledSegments { try? FileManager.default.removeItem(at: segment.url) }
    }

    /// 起動前に stale な screenrecord を best-effort で止める
    private func killStaleScreenrecord() {
        _ = try? Shell.run([adbPath, "-s", serial, "shell", "kill", "-2", "$(pidof screenrecord)"])
    }

    /// adb shell wm size の "Physical size: WxH" を半分(偶数丸め)にする。取得失敗時は nil(--size 省略)
    private func halvedPhysicalSize() -> String? {
        guard let result = try? Shell.run([adbPath, "-s", serial, "shell", "wm", "size"]),
              result.status == 0 else { return nil }
        guard let line = result.output.split(separator: "\n").first(where: { $0.contains("Physical size:") }),
              let sizePart = line.split(separator: ":").last else { return nil }
        let dims = String(sizePart).trimmingCharacters(in: .whitespaces).split(separator: "x")
        guard dims.count == 2, let w = Int(dims[0]), let h = Int(dims[1]), w > 0, h > 0 else { return nil }
        func halveEven(_ v: Int) -> Int {
            let half = v / 2
            return half % 2 == 0 ? half : half - 1
        }
        return "\(halveEven(w))x\(halveEven(h))"
    }

    private func warn(_ message: String) {
        FileHandle.standardError.write(Data("⚠️ [recording] \(serial): \(message)\n".utf8))
    }
}
