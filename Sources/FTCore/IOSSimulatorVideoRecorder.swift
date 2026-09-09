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

/// stderr の drain タスク(detached)から立てる旗。actor の外から書くのでロックで守る。
private final class LockedFlag: @unchecked Sendable {
    private let lock = NSLock()
    private var flag = false
    func set() { lock.lock(); flag = true; lock.unlock() }
    var value: Bool { lock.lock(); defer { lock.unlock() }; return flag }
}

actor IOSSimulatorVideoRecorder: DeviceVideoRecorderSession {
    /// 予期しない死亡からの再spawn上限。無限リトライで死に続けるデバイスに張り付かないため
    private static let maxRestarts = 5
    /// **録画の開始が一過性に空振りするときの再試行**。直前セッションの CoreSimulator io 解放が
    /// 間に合わない形(spawnNextPart の宣言)と、run 開始直後の負荷で撮れない形(実測 2026-09-10:
    /// M1Ultra の6台が同時に空になり、数分後には同じ台で 1 秒 66KB が撮れた。並列6本でも
    /// 空いていれば全部成功)は同じ一過性なので、**予算はここ1箇所**にして smokeCheck と共有する
    private static let startAttempts = 3
    private static let startRetryBackoffSeconds: Double = 2

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
        if let failure = await smokeCheckWithRetries() {
            switch failure {
            case .hostRecordingBusy:
                warn("this simulator holds a host recording session (simctl: \"Host recording is already"
                     + " in progress\"). It survives the client process, so shut the device down and boot"
                     + " it again (fleetest api stop-device --udid \(udid) then start-device --name <名前>,"
                     + " or xcrun simctl shutdown/boot \(udid)). Skipping recording for this device")
            case .emptyFile:
                warn("a \(Int(Self.smokeSeconds))s test recording came out empty (simctl reported no"
                     + " error). Skipping recording for this device")
            case .didNotStop:
                warn("the test recording did not stop within \(Int(Self.smokeStopGraceSeconds))s of SIGINT"
                     + " — leaving it alone (killing it would hold the device's recording session until"
                     + " the next boot). Skipping recording for this device")
            case .cannotStart(let detail):
                warn("cannot start the test recording: \(detail)")
            }
            return false
        }
        return await spawnNextPart()
    }

    /// **録画できることを実物で1本確かめてから本番を始める**(2026-08-26)。
    /// `recordVideo` は端末側にセッションが刺さっていても "Recording started" を出し、**0 バイトの
    /// .mov を作り続ける** —— 気付けるのは run の終わり(切り出し時)で、その run の録画は全部失われる。
    /// 実害: 3台構成の run で1台だけ録れており、他の2台は録画タブから消えた(2026-08-26)。
    ///
    /// **「ファイルが育たない」は検知に使えない** —— 正常な録画でも**閉じるまで 0 バイトのまま**
    /// (実測: 8 秒間ずっと 0、停止した瞬間に 21KB)。だから短い録画を1本**閉じて**大きさを見る。
    /// 失敗しても run は続ける(録画はできないが実行はできる)。
    /// **一過性の空振りは再試行する**(予算は startAttempts と共有)。busy は端末側にセッションが
    /// 残っている形で、待っても解けない(= 再試行しても同じ)ので即あきらめる。
    private func smokeCheckWithRetries() async -> SmokeFailure? {
        var last: SmokeFailure?
        for attempt in 1...Self.startAttempts {
            guard let failure = await smokeCheck() else { return nil }
            last = failure
            guard Self.isTransient(failure) else { return failure }
            if attempt < Self.startAttempts {
                warn("the test recording came out empty"
                     + " (attempt \(attempt)/\(Self.startAttempts)) — retrying")
                try? await Task.sleep(
                    nanoseconds: UInt64(Self.startRetryBackoffSeconds * 1_000_000_000))
            }
        }
        return last
    }

    /// 再試行して意味があるか。**デバイス不要の純粋関数**(規則はここだけ・テストが直接叩く)
    static func isTransient(_ failure: SmokeFailure) -> Bool {
        switch failure {
        case .emptyFile, .didNotStop: return true
        // 端末側のセッションは待っても解けない(シャットダウンが要る)/ simctl を起こせないのも同じ
        case .hostRecordingBusy, .cannotStart: return false
        }
    }

    private static let smokeSeconds: Double = 1
    /// SIGINT の猶予。**尽きても SIGKILL しない**(理由は smokeCheck の宣言)
    private static let smokeStopGraceSeconds: Double = 15
    /// 失敗の理由。**推測で名乗らない** —— simctl の stderr が言ったことだけを持ち帰る
    enum SmokeFailure {
        /// 端末側にセッションが残っている(simctl が "Host recording is already in progress")
        case hostRecordingBusy
        /// 起動はしたが中身が空(0 バイト)
        case emptyFile
        /// SIGINT を送っても止まらなかった(**SIGKILL しない** = セッションを残さない)
        case didNotStop
        /// simctl を起こせなかった
        case cannotStart(String)
    }
    private func smokeCheck() async -> SmokeFailure? {
        let url = workDir.appendingPathComponent("\(fileStem)-smoke.mov")
        try? FileManager.default.removeItem(at: url)
        defer { try? FileManager.default.removeItem(at: url) }

        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/xcrun")
        process.arguments = ["simctl", "io", udid, "recordVideo", "--codec=h264", "--force", url.path]
        process.standardOutput = FileHandle.nullDevice
        // **stderr を捨てない**: 「セッションが残っている」と「空だった」は原因も対処も違う
        let stderrPipe = Pipe()
        process.standardError = stderrPipe
        let stderrHandle = stderrPipe.fileHandleForReading
        let sawBusy = LockedFlag()
        Task.detached {
            for await line in ScenarioHost.lineStream(stderrHandle) {
                if line.contains("Host recording is already in progress") { sawBusy.set() }
            }
        }
        let exitStream = ProcessExitWait.prepare(process)
        do {
            try process.run()
        } catch {
            return .cannotStart(error.localizedDescription)
        }
        try? await Task.sleep(nanoseconds: UInt64(Self.smokeSeconds * 1_000_000_000))
        // **停止は SIGINT**(SIGTERM/SIGKILL だと moov が書かれず、健全な端末でも空に見える)。
        // **猶予が尽きても SIGKILL しない**(実測 2026-09-09): SIGINT 以外で殺した recordVideo は
        // **端末側のセッションを握ったまま**になり、その台は再起動するまで録画できなくなる ——
        // 以後の録画は "Host recording is already in progress" で全部落ち、ツール自身が
        // 「セッションが残っている」と警告する自作自演になっていた。止まらない個体は放置する
        // (次の recordVideo は busy で落ちるが、セッションを増やさない)
        if process.isRunning { process.interrupt() }
        await raceWithDeadline(seconds: Self.smokeStopGraceSeconds, onTimeout: ()) {
            for await _ in exitStream {}
        }
        if sawBusy.value { return .hostRecordingBusy }
        if process.isRunning { return .didNotStop }
        let size = (try? FileManager.default.attributesOfItem(atPath: url.path)[.size] as? Int) ?? nil
        return (size ?? 0) > 0 ? nil : .emptyFile
    }

    /// run を数十秒間隔で連続させると、直前セッションの CoreSimulator io 解放が間に合わず
    /// recordVideo が実際には録画を開始しない(ファイルが空のまま)ことがある(e2e 連続実行で実害)。
    /// "Recording started" を開始確認として扱い、出なければ仕切り直して再試行する(最大3回)。
    /// 確認できたら watchTask(exit 監視)を張って呼び出し元へ戻る
    private func spawnNextPart() async -> Bool {
        guard !stopRequested else { return false }
        for attempt in 1...Self.startAttempts {
            if await spawnPartOnce() { return true }
            warn("could not confirm recordVideo started (attempt \(attempt)/\(Self.startAttempts))")
            try? await Task.sleep(
                nanoseconds: UInt64(Self.startRetryBackoffSeconds * 1_000_000_000))
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
            // **SIGKILL しない**(smokeCheck と同じ理由): SIGINT 以外で殺すと端末側のセッションが
            // 残り、その台は再起動まで録画できなくなる
            if process.isRunning { process.interrupt() }
            _ = await raceWithDeadline(seconds: Self.smokeStopGraceSeconds, onTimeout: ()) {
                for await _ in exitStream {}
            }
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
            // 停止は SIGINT だけ(強制終了すると moov 未書き込みでファイルが壊れ、
            // 端末側の録画セッションも残る)
            process.interrupt()
            let exited = await raceWithDeadline(seconds: 15, onTimeout: false) {
                await watchTask.value  // handlePartExited(→finalizePart)の完了を待つ
                return true
            }
            if !exited {
                // **SIGKILL しない**(smokeCheck と同じ理由)。刺さった client は放置し、
                // 次の run の smokeCheck が busy として正直に報告する
                warn("stopping the recording timed out after 15s — discarding the final segment"
                     + " (leaving the recorder alone: killing it would hold this device's recording"
                     + " session until the next boot)")
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

    /// 同じ udid への stale な recordVideo(client プロセス)を起動前に best-effort で止める。
    /// **SIGINT で止める**(既定の SIGTERM だと moov が書かれないうえ、端末側のセッションが
    /// 握られたまま残り、その台が再起動まで録画できなくなる。実測 2026-09-09)。
    /// **端末側に残るセッションはこれでは解けない** —— プロセスが1つも無いのに録画が始まらない形が
    /// あり、そちらは smokeCheck が busy として報告する
    private func killStaleRecording() {
        _ = try? Shell.run(["pkill", "-INT", "-f", "simctl io \(udid) recordVideo"])
    }

    private func warn(_ message: String) {
        ConsoleOut.err("⚠️ [recording] \(udid): \(message)")
    }
}
