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
    /// デバイス側セグメントの置き場。**この接頭辞が「自分の screenrecord」の印**
    /// (killOwnScreenrecordCommand が /proc/<pid>/cmdline でこれを探す)
    static let remoteOutputPrefix = "/sdcard/ftrec-"

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
    /// 撮り始めを確かめられずに止めたセグメントのデバイス側パス。handleSegmentExited は撮り直さない
    /// (撮り直すかはシナリオの前の ensureRecording が決める = 確かめの上限ごとの撮り直しを無限に続けない)
    private var unconfirmedPath: String?

    /// 撮り始めの確かめの上限(秒)。iOS の "Recording started" 待ち(IOSSimulatorVideoRecorder の 10 秒)と同じ値。
    /// screenrecord は最初のフレームを符号化してから mp4 を書き始めるので、端末上のファイルが大きさを持てば撮れている
    static let startConfirmSeconds: Double = 10
    /// 確かめの上限(テストは短くする。本番は startConfirmSeconds)
    private let startConfirmLimit: Double
    /// 今の録画プロセス(currentProcess)の撮り始めを確かめたか。確かめの途中は false
    private var startConfirmed = false
    /// 確かめの刻み(秒)。1回は adb shell stat 1本(数十 ms)。実測で撮り始めは起動から約 0.2〜0.3 秒
    static let startConfirmPollSeconds: Double = 0.2
    /// 単発の adb(kill・rm・find・wm size)の期限と、pull が進まなくなってから諦めるまでの秒数。1回は数十 ms で返る。
    /// 値は FTAndroid の単発の adb の締切(`AndroidDeviceCatalog.adbTimeoutSeconds`。FTCore からは参照できない)と同じ。
    /// 尽きたら子を止めてその呼び出しを失敗として扱う(応答しない adbd に録画の開始・切り替え・停止を握らせない)
    static let adbAnswerSeconds: Double = 10
    /// 上の期限(テストは短くする。本番は adbAnswerSeconds)
    private let adbAnswerLimit: Double
    /// pull 済みローカルセグメント(連結順)と各々の spawn 時刻(index.json の startedAt に使う)
    private var pulledSegments: [(url: URL, startedAt: Date, closedAt: Date)] = []
    private var currentProcess: Process?
    /// 進行中セグメントの exit 監視タスク。stop 側はこれの完了(=最終 pull まで終わったこと)を待つ
    private var watchTask: Task<Void, Never>?
    /// start() が false を返した理由(DeviceVideoRecorderSession.startFailure)
    private var lastStartFailure: RecordingStartFailure?

    func startFailure() async -> RecordingStartFailure? { lastStartFailure }

    init(serial: String, adbPath: String, workDir: URL, fileStem: String,
        bitrateKbps: Int = VideoRecordingConfig.defaultBitrateKbps, fullResolution: Bool = false,
        startConfirmLimit: Double = AndroidScreenVideoRecorder.startConfirmSeconds,
        adbAnswerLimit: Double = AndroidScreenVideoRecorder.adbAnswerSeconds) {
        self.startConfirmLimit = startConfirmLimit
        self.adbAnswerLimit = adbAnswerLimit
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
        guard await spawnNextSegment() else {
            // 確かめられなかった録画を残さない(呼び手は静止画方式へ切り替え、stop を呼ばない)
            if let source = await stop() {
                for file in source.files { try? FileManager.default.removeItem(at: file) }
            }
            return false
        }
        return true
    }

    /// シナリオの直前(DeviceVideoRecorderSession.ensureRecording)。撮り始めを確かめた録画が動いていれば true。
    /// 3 分ごとの切り替え・予期しない終了の後始末の途中ならその結果を待ち、止まったままなら撮り直して確かめる
    func ensureRecording() async -> Bool {
        var awaited: Task<Void, Never>?
        var confirming: Process?
        while !stopRequested, !gaveUp {
            // 確認中の死亡はその確認の失敗。次の世代を待ち続けるループにしない。
            if let confirming, currentProcess !== confirming || !confirming.isRunning {
                return false
            }
            if let process = currentProcess, process.isRunning {
                if startConfirmed { return true }
                if unconfirmedPath != nil { return false }
                confirming = process
                // 生きた録画の終了監視は待たない。確認の完了・世代交代を読み直す。
                do {
                    try await Task.sleep(nanoseconds: UInt64(Self.startConfirmPollSeconds * 1_000_000_000))
                } catch { return false }
                continue
            }
            if let pending = watchTask, pending != awaited {
                awaited = pending
                await pending.value
                continue
            }
            warn("the recording was not running before a scenario — starting it again")
            return await spawnNextSegment()
        }
        return false
    }

    func stop() async -> RecordingSource? {
        stopRequested = true
        if currentProcess != nil {
            // ホスト側 adb クライアントを kill してもデバイス上の screenrecord は止まらず
            // ファイルが壊れる。デバイス側プロセスへ直接 kill -2 を送る
            _ = try? Shell.run([adbPath, "-s", serial, "shell",
                                Self.killOwnScreenrecordCommand(outputPathPrefix: Self.ownOutputPrefix(fileStem: fileStem))],
                               timeout: adbAnswerLimit)
            if let watchTask {
                _ = await raceWithDeadline(seconds: 20, onTimeout: ()) { await watchTask.value }
            }
        }
        return await source(of: pulledSegments)
    }

    private func source(of pulled: [(url: URL, startedAt: Date, closedAt: Date)]) async -> RecordingSource? {
        guard !pulled.isEmpty else { return nil }

        // 各セグメントの実 duration だけ測る(連結+再エンコードはシナリオ毎のクリップ切り出し時に行う)。
        // 読めないセグメントはここで即座に掃除する(coordinator は返した files しか知らないため)
        var files: [URL] = []
        var segments: [RecordingIndexSegment] = []
        var closedAt: [Date] = []
        for segment in pulled {
            guard let duration = try? await AVURLAsset(url: segment.url).load(.duration),
                  duration.isNumeric, duration.seconds > 0 else {
                // 黙って捨てない(screenrecord が SIGINT 以外で落ちると moov が無く読めない = その間のシナリオは撮り直した後の分だけ)
                warn("discarding an unreadable recording segment (\(segment.url.lastPathComponent))")
                try? FileManager.default.removeItem(at: segment.url)
                continue
            }
            files.append(segment.url)
            closedAt.append(segment.closedAt)
            segments.append(RecordingIndexSegment(
                startedAt: ISO8601Millis.string(from: segment.startedAt),
                durationMs: Int((duration.seconds * 1000).rounded())))
        }
        guard !files.isEmpty else { return nil }
        return RecordingSource(files: files, segments: segments, closedAt: closedAt)
    }

    @discardableResult
    private func spawnNextSegment() async -> Bool {
        guard !stopRequested, !gaveUp else { return false }
        segmentIndex += 1
        let remotePath = Self.remoteSegmentPath(fileStem: fileStem, index: segmentIndex)
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
            warn("cannot start screenrecord: \(error.localizedDescription)")
            lastStartFailure = .cannotLaunchRecorder
            return false
        }
        currentProcess = process
        unconfirmedPath = nil
        startConfirmed = false
        watchTask = Task { [weak self] in
            for await _ in exitStream {}
            await self?.handleSegmentExited(remotePath: remotePath, startedAt: spawnedAt)
        }
        // **撮り始めを確かめてから戻る**(テストを録画より先に始めない)。currentProcess を書いた後に待つので、待ちの間に
        // stop() が来ても止め忘れない(下の handleSegmentExited の排他の前提は currentProcess が nil の間だけに掛かる)
        let confirmed = await confirmStarted(remotePath: remotePath, process: process)
        // 確認中に監視が次のセグメントを起こしていたら、その状態を古い結果で書き換えない。
        guard currentProcess === process else { return false }
        guard confirmed else {
            warn("screenrecord did not start writing within \(Int(startConfirmLimit))s — stopping it")
            lastStartFailure = .startNotConfirmed
            unconfirmedPath = remotePath
            _ = try? Shell.run([adbPath, "-s", serial, "shell",
                                Self.killOwnScreenrecordCommand(outputPathPrefix: remotePath)],
                               timeout: startConfirmLimit)
            return false
        }
        startConfirmed = !stopRequested
        return startConfirmed
    }

    /// 端末上のファイルが大きさを持つ(= 撮り始めた)まで待つ。停止が来たら確かめを打ち切って true(stop が後始末する)
    /// **adb にも残り時間を期限として渡す**(応答しない adb で同期の Shell.run から戻らないと、上限が効かず actor ごと止まる =
    /// シナリオの前の確かめから run 全体が待ち続ける)
    private func confirmStarted(remotePath: String, process: Process) async -> Bool {
        let deadline = Date().addingTimeInterval(startConfirmLimit)
        while Date() < deadline, process.isRunning {
            if stopRequested { return true }
            if let result = try? Shell.run([adbPath, "-s", serial, "shell", "stat", "-c", "%s", remotePath],
                                           timeout: max(0.1, deadline.timeIntervalSinceNow)),
               result.status == 0,
               let bytes = Int(result.output.trimmingCharacters(in: .whitespacesAndNewlines)), bytes > 0 {
                return true
            }
            try? await Task.sleep(nanoseconds: UInt64(Self.startConfirmPollSeconds * 1_000_000_000))
        }
        return stopRequested
    }

    // **stop() との排他は actor の直列実行だけに頼る**(明示のロックが無い)。成立条件:
    // currentProcess を nil にしてから spawnNextSegment() が新しいプロセスを currentProcess に書くまでに
    // **真の suspension が無い**こと(Process.run() は同期・Task { } の生成も中断しない。撮り始めの確かめの待ちは
    // currentProcess を書いた後)。この前提が崩れる(その間に await を足す)と、
    // currentProcess が nil の間に stop() が割り込めてしまい、再 spawn 後のプロセスを
    // 止め忘れて孤児 screenrecord を残す。stop() は先頭で同期的に stopRequested = true を
    // 書くので、actor が先にどちらのジョブ(このメソッド呼び出し列 / stop())を実行しても、
    // spawnNextSegment() 入口の guard がその時点の stopRequested を見て再 spawn を止められる
    private func handleSegmentExited(remotePath: String, startedAt: Date) async {
        let exitedAt = Date()  // 閉じた時刻は pull の前に採る(pull の所要を静止画の末尾に足さない)
        let localURL = workDir.appendingPathComponent("\(fileStem)-part\(segmentIndex).mp4")
        if pullSegment(remotePath: remotePath, to: localURL) {
            pulledSegments.append((localURL, startedAt, exitedAt))
        }
        _ = try? Shell.run([adbPath, "-s", serial, "shell", "rm", "-f", remotePath], timeout: adbAnswerLimit)
        currentProcess = nil
        startConfirmed = false
        if unconfirmedPath == remotePath {
            unconfirmedPath = nil
            return
        }

        // クラッシュループ検知: 明示停止でないのに極端に短時間で終わったセグメントが連続したら、
        // それまで撮れた分(pulledSegments)は活かしつつ以降の再spawnを諦める
        if !stopRequested, Date().timeIntervalSince(startedAt) < Self.crashLoopThresholdSeconds {
            consecutiveShortSegments += 1
            if consecutiveShortSegments >= Self.crashLoopMaxConsecutive {
                gaveUp = true
                warn("segments ended under \(Int(Self.crashLoopThresholdSeconds))s "
                    + "\(consecutiveShortSegments) times in a row — giving up on recording"
                    + " (keeping what was captured so far)")
                return
            }
        } else {
            consecutiveShortSegments = 0
        }
        if !stopRequested {
            await spawnNextSegment()
        }
    }

    /// **期限は置かず、進みで見る** —— 所要は大きさ(最大約 34MB)と経路(Emulator 約 150MB/s・USB の実機はそれより遅い)で決まり、
    /// 根拠のある上限が無い。pull は手元のファイルへ逐次書く(実測で 50ms ごとに伸びる)ので、大きさが `adbAnswerLimit` 秒
    /// 変わらなければ止めて失敗とする。**同期のまま待つ**(await にすると actor が空き、stop() の 20 秒の待ちが進んでいる pull の
    /// 途中で切れて最後のセグメントを落とす)
    private func pullSegment(remotePath: String, to localURL: URL) -> Bool {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: adbPath)
        process.arguments = ["-s", serial, "pull", remotePath, localURL.path]
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        let waitExit = ProcessExitWait.prepareTimed(process)
        do { try process.run() } catch { return false }
        var lastSize: Int64 = -1
        var lastProgress = Date()
        while waitExit(.now() + Self.startConfirmPollSeconds) == .timedOut {
            let size = ((try? FileManager.default.attributesOfItem(atPath: localURL.path))?[.size] as? NSNumber)?.int64Value ?? -1
            if size != lastSize {
                lastSize = size
                lastProgress = Date()
                continue
            }
            guard Date().timeIntervalSince(lastProgress) >= adbAnswerLimit else { continue }
            warn("adb pull made no progress for \(Int(adbAnswerLimit))s — giving up on \(remotePath)")
            process.terminate()
            if waitExit(.now() + Shell.killGraceSeconds) == .timedOut {
                kill(process.processIdentifier, SIGKILL)
                _ = waitExit(.distantFuture)
            }
            try? FileManager.default.removeItem(at: localURL)
            return false
        }
        return process.terminationReason == .exit && process.terminationStatus == 0
            && FileManager.default.fileExists(atPath: localURL.path)
    }

    /// 起動前に stale な screenrecord(前の run が残した ftrec-* のもの)を best-effort で止め、
    /// 置き去りのセグメントを消す。端末のファイルを消すのは正常終了のセグメントごとの `rm` だけなので、
    /// ホストが途中で死んだ run(SIGKILL・クラッシュ・adb 切断)のセグメント(最大約 34MB)が溜まり続けた
    private func killStaleScreenrecord() {
        _ = try? Shell.run([adbPath, "-s", serial, "shell",
                            Self.killOwnScreenrecordCommand(outputPathPrefix: Self.remoteOutputPrefix)],
                           timeout: adbAnswerLimit)
        _ = try? Shell.run([adbPath, "-s", serial, "shell", Self.staleSegmentCleanupCommand], timeout: adbAnswerLimit)
    }

    /// 置き去りのセグメントを消すデバイス側シェル。**更新が止まって `staleSegmentMinutes` 分より古いものだけ** ——
    /// 撮影中のセグメントは書き続けられ、1本は `segmentTimeLimitSeconds`(3分)で終わってすぐ pull されるので、
    /// 同じ端末の別の録画が使っているものには触らない。find の -mmin / -delete は toybox(API 26+)に居る
    static let staleSegmentMinutes = 10
    static var staleSegmentCleanupCommand: String {
        let dir = (remoteOutputPrefix as NSString).deletingLastPathComponent
        let namePrefix = (remoteOutputPrefix as NSString).lastPathComponent
        return "find \(dir)/ -maxdepth 1 -name '\(namePrefix)*.mp4' -mmin +\(staleSegmentMinutes) -delete"
    }

    /// この録画セッションのセグメントだけに共通する接頭辞(stop はこれで自分のぶんだけ止める)
    static func ownOutputPrefix(fileStem: String) -> String {
        "\(remoteOutputPrefix)\(fileStem)-"
    }

    static func remoteSegmentPath(fileStem: String, index: Int) -> String {
        "\(ownOutputPrefix(fileStem: fileStem))\(index).mp4"
    }

    /// `adb shell` に渡す、**自分の screenrecord だけ**へ SIGINT を送るデバイス側シェル。
    /// pidof の結果を無差別に kill すると、モニターのライブ配信(fleetest-androidstream の
    /// `screenrecord --output-format=h264`)まで落ち、録画の開始/停止のたびに映像が切れる。
    /// 選別は /proc/<pid>/cmdline(NUL 区切りなので tr で空白へ)に outputPathPrefix を含むか
    /// (screenrecord は adb shell と同じ shell uid なので hidepid=2 でも読める)。
    /// pidof / tr / grep -F は toybox(API 26+ = ブリッジの minSdk)に居る。該当が無ければ何もしない
    static func killOwnScreenrecordCommand(outputPathPrefix: String) -> String {
        let quoted = "'" + outputPathPrefix.replacingOccurrences(of: "'", with: "'\\''") + "'"
        return "pidof screenrecord | tr ' ' '\\n' | while read p; do "
            + "tr '\\000' ' ' < /proc/$p/cmdline | grep -qF -- \(quoted) && kill -2 $p; "
            + "done"
    }

    /// adb shell wm size の "Physical size: WxH" を半分(偶数丸め)にする。取得失敗時は nil(--size 省略)
    private func halvedPhysicalSize() -> String? {
        guard let result = try? Shell.run([adbPath, "-s", serial, "shell", "wm", "size"], timeout: adbAnswerLimit),
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
        ConsoleOut.err("⚠️ [recording] \(serial): \(message)")
    }
}
