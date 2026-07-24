// AndroidScreenVideoRecorder.swift
// Android の録画(adb shell screenrecord)。1 回の screenrecord は 180 秒上限のため、
// プロセス exit の度に pull → デバイス側ファイル削除 → 次セグメント spawn を停止指示まで
// 繰り返す。stop() は pull 済みセグメント群を生ソースとして返すだけで、シナリオ毎のクリップ
// 切り出し(連結+再エンコード)は VideoRecordingCoordinator/VideoRecordingFinalizer が行う。

import AVFoundation
import Foundation

actor AndroidScreenVideoRecorder: DeviceVideoRecorderSession {
    private static let segmentTimeLimitSeconds = 180
    /// この時間未満で死んだセグメントを「異常に短い」とみなす(クラッシュループ検知)
    private static let crashLoopThresholdSeconds: TimeInterval = 3
    /// crashLoopThresholdSeconds 未満のセグメントがこの回数連続したら録画を諦める。
    /// 先日の実害(録画プロセスが途中死してワーカーの録画が丸ごと欠けた)を受け、無限リトライで
    /// ログを埋め尽くす/デバイスに adb を叩き続けるのを防ぎつつ、それまでに撮れた分は活かす
    private static let crashLoopMaxConsecutive = 5

    private let serial: String
    private let adbPath: String
    private let workDir: URL
    private let fileStem: String
    private let bitrateKbps: Int
    private let fullResolution: Bool

    private var stopRequested = false
    private var gaveUp = false
    private var size: String?
    private var segmentIndex = 0
    /// crashLoopThresholdSeconds 未満で終了したセグメントの連続回数(閾値以上で通常終了したらリセット)
    private var consecutiveShortSegments = 0
    /// pull 済みローカルセグメント(連結順)と各々の spawn 時刻(index.json の startedAt に使う)
    private var pulledSegments: [(url: URL, startedAt: Date)] = []
    private var currentProcess: Process?
    /// 進行中セグメントの exit 監視タスク。stop 側はこれの完了(=最終 pull まで終わったこと)を待つ
    private var watchTask: Task<Void, Never>?

    init(serial: String, adbPath: String, workDir: URL, fileStem: String,
        bitrateKbps: Int = 1500, fullResolution: Bool = false) {
        self.serial = serial
        self.adbPath = adbPath
        self.workDir = workDir
        self.fileStem = fileStem
        self.bitrateKbps = bitrateKbps
        self.fullResolution = fullResolution
    }

    func start() async -> Bool {
        killStaleScreenrecord()
        size = fullResolution ? nil : halvedPhysicalSize()
        return await spawnNextSegment()
    }

    func stop() async -> RecordingSource? {
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

        // 各セグメントの実 duration だけ測る(連結+再エンコードはシナリオ毎のクリップ切り出し時に行う)。
        // 読めないセグメントはここで即座に掃除する(coordinator は返した files しか知らないため)
        var files: [URL] = []
        var segments: [RecordingIndexSegment] = []
        for segment in pulledSegments {
            guard let duration = try? await AVURLAsset(url: segment.url).load(.duration),
                  duration.isNumeric, duration.seconds > 0 else {
                try? FileManager.default.removeItem(at: segment.url)
                continue
            }
            files.append(segment.url)
            segments.append(RecordingIndexSegment(
                startedAt: ISO8601Millis.string(from: segment.startedAt),
                durationMs: Int((duration.seconds * 1000).rounded())))
        }
        guard !files.isEmpty else { return nil }
        return RecordingSource(files: files, segments: segments)
    }

    @discardableResult
    private func spawnNextSegment() async -> Bool {
        guard !stopRequested, !gaveUp else { return false }
        segmentIndex += 1
        let remotePath = "/sdcard/ftrec-\(fileStem)-\(segmentIndex).mp4"
        var args = ["-s", serial, "shell", "screenrecord", "--bit-rate", String(bitrateKbps * 1000)]
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

        // クラッシュループ検知: 明示停止でないのに極端に短時間で終わったセグメントが連続したら、
        // それまで撮れた分(pulledSegments)は活かしつつ以降の再spawnを諦める
        if !stopRequested, Date().timeIntervalSince(startedAt) < Self.crashLoopThresholdSeconds {
            consecutiveShortSegments += 1
            if consecutiveShortSegments >= Self.crashLoopMaxConsecutive {
                gaveUp = true
                warn("セグメントが \(Int(Self.crashLoopThresholdSeconds))秒未満で "
                    + "\(consecutiveShortSegments) 回連続して終了したため録画を諦めます"
                    + "(それまでに撮れた分は保存します)")
                return
            }
        } else {
            consecutiveShortSegments = 0
        }
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
