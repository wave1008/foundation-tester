// IOSSimulatorVideoRecorder.swift
// iOS シミュレータの録画(xcrun simctl io recordVideo)。長時間常駐+SIGINT 停止のため
// Shell.swift(待ち切り実行)ではなく Process を直接管理する(BridgeLauncher.swift の
// pid 管理パターンを踏襲)。stop() は生ソース(1本以上の .mov)を返すだけで、シナリオ毎の
// クリップ切り出しは VideoRecordingCoordinator/VideoRecordingFinalizer が行う。
//
// watchdog: recordVideo は run の途中で(CoreSimulator 側の要因等で)予期せず死ぬことがある
// (実害: 30ワーカー中1回、録画プロセスが途中死してワーカーの録画が丸ごと欠けた)。停止指示前の
// exit を検知したら別ソースファイル(~part2 等)へ再spawnし、RecordingSource には複数 part を
// 1:1 対応のまま返す(部分的にでも録画を残す。全欠落より部分録画の方が有用という判断)。
//
// 期限(撮り始めの確認・SIGINT から止まるまで・掃除)は**単調時計**で測る(`clock`。壁時計の変更に左右されない)。
// テストは止めた時計を渡して、偽の client の準備を見てから期限を越えさせる。

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
    /// 間に合わない形(spawnNextPart の宣言)と、run 開始直後の負荷で撮れない形(実測:
    /// M1Ultra の6台が同時に空になり、数分後には同じデバイスで 1 秒 66KB が撮れた。並列6本でも
    /// 空いていれば全部成功)は同じ一過性なので、**予算はここ1箇所**にして smokeCheck と共有する
    private static let startAttempts = 3
    private static let startRetryBackoffSeconds: Double = 2

    private let udid: String
    private let workDir: URL
    private let fileStem: String

    private var stopRequested = false
    /// start() が false を返した理由(DeviceVideoRecorderSession.startFailure)
    private var lastStartFailure: RecordingStartFailure?
    /// spawnPartOnce が見張りへ渡したときの発話(spawnNextPart が試行番号と同じ 1 行にまとめて出す)
    private var pendingHandOffNotice: String?

    func startFailure() async -> RecordingStartFailure? { lastStartFailure }
    private var restarts = 0
    private var partIndex = 0
    private var process: Process?
    /// 進行中 part の exit 監視タスク。stop() 側はこれの完了(=最後の part の確定)を待つ
    private var watchTask: Task<Void, Never>?
    /// 確定済み(死亡+再spawn または通常停止)の part。files/segments と 1:1 対応する順で積む
    private var parts: [(url: URL, startedAt: Date, durationMs: Int, closedAt: Date)] = []

    /// recordVideo を起こす実行ファイル(テストは偽の xcrun を渡す)
    private let xcrunPath: String
    /// 撮り始めを待つ上限と、SIGINT から止まるまでを待つ上限(テストは短くする。本番は startConfirmSeconds / smokeStopGraceSeconds)
    private let startConfirmLimit: Double
    private let stopGraceLimit: Double
    /// 期限を測る単調時計(秒)。テストは止めた時計を渡す
    private let clock: @Sendable () -> TimeInterval
    /// 見張り(`fleetest api recorder-watch`)を起こす実行ファイル = fleetest 自身。テストは製品バイナリを渡す
    private let watcherExecutable: URL?

    /// 本番の時計。壁時計(`Date`)ではなく単調な稼働時間(変更されない・戻らない)
    static let monotonicNow: @Sendable () -> TimeInterval = { ProcessInfo.processInfo.systemUptime }

    init(udid: String, workDir: URL, fileStem: String, xcrunPath: String = "/usr/bin/xcrun",
         startConfirmLimit: Double = IOSSimulatorVideoRecorder.startConfirmSeconds,
         stopGraceLimit: Double = IOSSimulatorVideoRecorder.smokeStopGraceSeconds,
         clock: @escaping @Sendable () -> TimeInterval = IOSSimulatorVideoRecorder.monotonicNow,
         watcherExecutable: URL? = ExecutablePath.current) {
        self.xcrunPath = xcrunPath
        self.startConfirmLimit = startConfirmLimit
        self.stopGraceLimit = stopGraceLimit
        self.clock = clock
        self.watcherExecutable = watcherExecutable
        self.udid = udid
        self.workDir = workDir
        self.fileStem = fileStem
    }

    enum OutputKind: Equatable {
        case smoke
        case part(Int)
    }

    /// 出力ファイル名(純粋関数)。`<stem>~smoke.mov` / `<stem>.mov`(part 1)/ `<stem>~part<N>.mov`。
    /// **run の中で一意**: `RecordingIndexIO.sanitizedFileName` は英数字と `-` しか出さず(`~` は出ない)、coordinator が同じ名前の worker に
    /// 付ける重複の印は `~<数字>`。接尾辞 `~smoke` / `~part<N>` は数字で始まらないので、stem が違えば最終名も違う。
    /// 接尾辞を `-` で繋ぐと `phone` の smoke と `phone-smoke` の part 1 が同じ名前になる(= 見張りが別の録画の一時ファイルを消す)
    static func outputURL(workDir: URL, fileStem: String, kind: OutputKind) -> URL {
        switch kind {
        case .smoke: return workDir.appendingPathComponent("\(fileStem)~smoke.mov")
        case .part(let index):
            return workDir.appendingPathComponent(index == 1 ? "\(fileStem).mov" : "\(fileStem)~part\(index).mov")
        }
    }

    private func movURL(for index: Int) -> URL {
        Self.outputURL(workDir: workDir, fileStem: fileStem, kind: .part(index))
    }

    func start() async -> Bool {
        await killStaleRecording()
        if let failure = await smokeCheckWithRetries() {
            lastStartFailure = switch failure {
            case .hostRecordingBusy: .hostRecordingBusy
            case .emptyFile: .emptyTestRecording
            case .didNotStop: .testRecordingDidNotStop
            case .cannotStart, .refused: .cannotLaunchRecorder
            }
            switch failure {
            case .hostRecordingBusy:
                // 録画ありの run は供給の段階で再起動して解いている(HostRecordingProbe)。ここへ来るのは
                // 再起動しても解けなかったデバイスか、その検査を通らない経路
                warn("this simulator holds a recording session (simctl: \"… recording is already"
                     + " in progress\"). It survives the client process, so shut the device down and boot"
                     + " it again (fleetest api stop-device --udid \(udid) then start-device --name <name>,"
                     + " or xcrun simctl shutdown/boot \(udid)). Skipping recording for this device")
            case .emptyFile:
                warn("a \(Int(Self.smokeSeconds))s test recording came out empty (simctl reported no"
                     + " error). Skipping recording for this device")
            case .didNotStop(let outcome):
                warn("the test recording did not stop within \(Int(stopGraceLimit))s of SIGINT — "
                     + Self.handOffNotice(outcome, file: Self.outputURL(workDir: workDir, fileStem: fileStem, kind: .smoke), udid: udid)
                     + ". Skipping recording for this device")
            case .cannotStart(let detail):
                warn("cannot start the test recording: \(detail)")
            case .refused(let status, let message):
                warn("simctl recordVideo exited with status \(status) before recording"
                     + (message.isEmpty ? "" : ": \(message)") + ". Skipping recording for this device")
            }
            return false
        }
        return await spawnNextPart()
    }

    /// **録画できることを実物で1本確かめてから本番を始める**。
    /// `recordVideo` は端末側にセッションが刺さっていても "Recording started" を出し、**0 バイトの
    /// .mov を作り続ける** —— 気付けるのは run の終わり(切り出し時)で、その run の録画は全部失われる。
    /// 実害: 3台構成の run で1台だけ録れており、他の2台は録画タブから消えた。
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
        case .emptyFile: return true
        // 端末側のセッションは待っても解けない(シャットダウンが要る)/ simctl を起こせないのも同じ /
        // 止まらなかった試し撮りはセッションを握ったまま撮り続けるので、撮り直しは必ず「録画中」で断られる
        case .hostRecordingBusy, .cannotStart, .refused, .didNotStop: return false
        }
    }

    private static let smokeSeconds: Double = 1
    /// SIGINT の猶予。**尽きても SIGKILL しない**(理由は smokeCheck の宣言)
    static let smokeStopGraceSeconds: Double = 15
    /// "Recording started" を待つ上限(秒)。本番の録画と試し撮りで共有する
    static let startConfirmSeconds: Double = 10
    /// 撮り始める前の SIGINT を送り直す間隔(秒)。見張りと同じ値(`RecorderWatch.repeatIntervalSeconds`)
    static let interruptRepeatSeconds: Double = RecorderWatch.repeatIntervalSeconds

    /// recordVideo を止める。**"Recording started" より前の SIGINT は無視される**(実測: 起動から 0.05・0.2 秒の SIGINT では
    /// 止まらず、0.5 秒以降は止まった。無視された試し撮りが何時間も撮り続け、そのデバイスを run の間ずっと「録画中」で塞いだ)。
    /// 撮り始めるまでは送り直し、撮り始めたら1回だけ送って終わりを待つ(撮り始めた後の client は SIGINT から数 ms で終わる)。
    /// **SIGKILL はしない**(smokeCheck の宣言)。戻り値: grace 内に終わったか
    static func interruptRecorder(_ process: Process, started: @Sendable () -> Bool, grace: Double,
                                  clock: @Sendable () -> TimeInterval = IOSSimulatorVideoRecorder.monotonicNow) async -> Bool {
        let deadline = clock() + grace
        var interruptedAfterStart = false
        while process.isRunning, clock() < deadline {
            let isStarted = started()
            if !isStarted || !interruptedAfterStart {
                process.interrupt()
                interruptedAfterStart = isStarted
            }
            try? await Task.sleep(nanoseconds: UInt64(interruptRepeatSeconds * 1_000_000_000))
        }
        return !process.isRunning
    }
    /// 失敗の理由。**推測で名乗らない** —— simctl の stderr が言ったことだけを持ち帰る
    enum SmokeFailure {
        /// 端末側にセッションが残っている(simctl の busy の文言 = HostRecordingProbe.busyMarkers)
        case hostRecordingBusy
        /// 起動はしたが中身が空(0 バイト)
        case emptyFile
        /// SIGINT を送っても止まらなかった(**SIGKILL しない** = セッションを残さない)。見張りへ渡した結果を運ぶ
        case didNotStop(HandOffOutcome)
        /// simctl を起こせなかった
        case cannotStart(String)
        /// SIGINT を送る前に simctl が自分から非ゼロで終わった(画面の指定が要るのに無い等)。
        /// message は simctl の stderr の末尾(言ったことだけ)
        case refused(status: Int32, message: String)
    }
    private func smokeCheck() async -> SmokeFailure? {
        let url = Self.outputURL(workDir: workDir, fileStem: fileStem, kind: .smoke)
        RecorderWatch.removeOutputs(of: url)

        let process = Process()
        process.executableURL = URL(fileURLWithPath: xcrunPath)
        process.arguments = ["simctl", "io", udid, "recordVideo"] + SimulatorActiveDisplay.simctlIOArguments(udid: udid)
            + ["--codec=h264", "--force", url.path]
        process.standardOutput = FileHandle.nullDevice
        // **stderr を捨てない**: 「セッションが残っている」と「空だった」は原因も対処も違う
        let stderrPipe = Pipe()
        process.standardError = stderrPipe
        let stderrHandle = stderrPipe.fileHandleForReading
        let sawBusy = LockedFlag()
        let sawStarted = LockedFlag()
        let stderrTail = LockedValue<[String]>([])
        let stderrDone = AsyncStream<Void>.makeStream()
        Task.detached {
            for await line in ScenarioHost.lineStream(stderrHandle) {
                if HostRecordingProbe.isBusy(line: line) { sawBusy.set() }
                if line.contains(HostRecordingProbe.startedMarker) { sawStarted.set() }
                let trimmed = line.trimmingCharacters(in: .whitespaces)
                if !trimmed.isEmpty { stderrTail.withLock { $0 = Array(($0 + [trimmed]).suffix(4)) } }
            }
            stderrDone.continuation.finish()
        }
        let exitStream = ProcessExitWait.prepare(process)
        do {
            try process.run()
        } catch {
            return .cannotStart(error.localizedDescription)
        }
        // 身元は **spawn の直後にだけ採る**(この時点の pid は自分の子で使い回されていない。handOff で採り直さない)
        let target = RecorderWatch.Target.of(process.processIdentifier)
        // 撮り始めてから1秒撮る(固定の1秒では、負荷で起動が遅れたとき撮り始める前に止めることになる)
        let startDeadline = clock() + startConfirmLimit
        while !sawStarted.value, process.isRunning, clock() < startDeadline {
            try? await Task.sleep(nanoseconds: UInt64(Self.interruptRepeatSeconds * 1_000_000_000))
        }
        if sawStarted.value { try? await Task.sleep(nanoseconds: UInt64(Self.smokeSeconds * 1_000_000_000)) }
        // **停止は SIGINT**(SIGTERM/SIGKILL だと moov が書かれず、健全な端末でも空に見える)。
        // **猶予が尽きても SIGKILL しない**(実測): SIGINT 以外で殺した recordVideo は
        // **端末側のセッションを握ったまま**になり、そのデバイスは再起動するまで録画できなくなる ——
        // 以後の録画は "Host recording is already in progress" で全部落ち、ツール自身が
        // 「セッションが残っている」と警告する自作自演になっていた。止まらない個体は見張りへ渡す
        // (次の recordVideo は busy で落ちるが、セッションを増やさない)
        let exitedOnItsOwn = !process.isRunning
        if await !Self.interruptRecorder(process, started: { sawStarted.value }, grace: stopGraceLimit, clock: clock) {
            let outcome = Self.handOff(process, target: target, stderr: stderrHandle, leaving: url, watcher: watcherExecutable)
            switch outcome {
            case .watching:
                // ファイルの所有は見張りへ移った(client が終わってから消す)。ここでは消さない
                return sawBusy.value ? .hostRecordingBusy : .didNotStop(outcome)
            case .unwatched:
                RecorderWatch.removeOutputs(of: url)
                return sawBusy.value ? .hostRecordingBusy : .didNotStop(outcome)
            case .clientGone:
                break  // 期限の直後に止まった = 止まった形として下で評価する
            }
        }
        defer { RecorderWatch.removeOutputs(of: url) }
        for await _ in exitStream {}
        // **busy を見る前に** stderr の読み手が末尾まで読み切るのを短く待つ(終了済みなので EOF はすぐ来る)。
        // 先に見ると、busy を言って自分から終わった client を読み手の遅れで .refused(= cannotLaunchRecorder)と誤って名乗る
        await raceWithDeadline(seconds: 1, onTimeout: ()) { for await _ in stderrDone.stream {} }
        if sawBusy.value { return .hostRecordingBusy }
        if exitedOnItsOwn, process.terminationStatus != 0 {
            return .refused(status: process.terminationStatus, message: stderrTail.value.joined(separator: " "))
        }
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
            pendingHandOffNotice = nil
            if await spawnPartOnce() { return true }
            warn("could not confirm recordVideo started (attempt \(attempt)/\(Self.startAttempts))"
                 + (pendingHandOffNotice.map { " — " + $0 } ?? ""))
            try? await Task.sleep(
                nanoseconds: UInt64(Self.startRetryBackoffSeconds * 1_000_000_000))
            guard !stopRequested else { return false }
        }
        return false
    }

    private func spawnPartOnce() async -> Bool {
        partIndex += 1
        let url = movURL(for: partIndex)
        RecorderWatch.removeOutputs(of: url)

        let process = Process()
        process.executableURL = URL(fileURLWithPath: xcrunPath)
        // codec は h264 固定(再生側 Chromium が HEVC 非対応。hevc にしないこと)
        process.arguments = ["simctl", "io", udid, "recordVideo"] + SimulatorActiveDisplay.simctlIOArguments(udid: udid)
            + ["--codec=h264", "--force", url.path]
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
            lastStartFailure = .cannotLaunchRecorder
            return false
        }
        // 身元は **spawn の直後にだけ採る**(handOff で採り直さない)
        let target = RecorderWatch.Target.of(process.processIdentifier)
        // stderr は**プロセスの生存中ずっと**読み続ける(EOF まで drain)。"Recording started" 検出後に
        // 読み手を終えると読み口が閉じ、simctl が停止時の stderr 出力("Recording completed...")で
        // SIGPIPE 死してファイナライズされない(moov 無しで .mov が読めない)実害があった。
        // 開始の印は読み手が置き(時刻は印を見た瞬間)、ここは周期で見る(AsyncStream のレースにすると、期限側が勝った周で
        // 読み手が cancel され、次の周の印を受け取れない)
        let startedAt = LockedValue<Date?>(nil)
        let stderrHandle = stderrPipe.fileHandleForReading
        let reader = Task.detached {
            for await line in ScenarioHost.lineStream(stderrHandle) {
                if line.contains(HostRecordingProbe.startedMarker) {
                    startedAt.withLock { if $0 == nil { $0 = Date() } }
                }
            }
        }
        // "Recording started"(最初のフレーム処理済み)が出るまでは開始とみなさない
        let startDeadline = clock() + startConfirmLimit
        while startedAt.value == nil, process.isRunning, clock() < startDeadline {
            try? await Task.sleep(nanoseconds: UInt64(Self.interruptRepeatSeconds * 1_000_000_000))
        }
        if startedAt.value == nil, !process.isRunning {
            // 撮り始めてすぐ終わった client は、読み手が印を置く前に終了が見える。読み切ってから判定する
            // (開始済みなら exit 監視 → finalizePart へ渡す = 撮れた分を捨てない)
            await raceWithDeadline(seconds: 1, onTimeout: ()) { await reader.value }
        }
        guard let observedStart = startedAt.value else {
            // 期限の後に撮り始める client もいるので、撮り始める前に無視された SIGINT を送り直す(interruptRecorder)
            if await Self.interruptRecorder(process, started: { startedAt.value != nil }, grace: stopGraceLimit, clock: clock) {
                for await _ in exitStream {}
                RecorderWatch.removeOutputs(of: url)
            } else {
                let outcome = Self.handOff(process, target: target, stderr: stderrHandle, leaving: url, watcher: watcherExecutable)
                pendingHandOffNotice = Self.handOffNotice(outcome, file: url, udid: udid)
                if case .watching = outcome {
                    // ファイルの所有は見張りへ移った(client が終わってから消す)
                } else {
                    RecorderWatch.removeOutputs(of: url)
                }
            }
            lastStartFailure = .startNotConfirmed
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
        await finalizePart(url: url, startedAt: startedAt, closedAt: Date())
        guard !stopRequested else { return }
        guard restarts < Self.maxRestarts else {
            warn("the recording process keeps dying — giving up on restarts (\(Self.maxRestarts) times; "
                + "keeping what was captured so far)")
            return
        }
        restarts += 1
        warn("the recording process stopped unexpectedly — restarting (\(restarts)/\(Self.maxRestarts))")
        // 再spawn の途中に stop() が来ても、ここで止めない: stop() はこの監視タスクの完了を待ってから新しい録画を止める
        // (ここでも送ると、撮り始めた client に SIGINT が2回届く)
        await spawnNextPart()
    }

    /// 死亡時点のファイルは duration が読めれば parts に含め、読めなければ(録画が実質空)破棄する
    private func finalizePart(url: URL, startedAt: Date, closedAt: Date) async {
        guard let duration = try? await AVURLAsset(url: url).load(.duration), duration.isNumeric,
              duration.seconds > 0 else {
            warn("discarding an unreadable recording file (\(url.lastPathComponent))")
            try? FileManager.default.removeItem(at: url)
            return
        }
        parts.append((url, startedAt, Int((duration.seconds * 1000).rounded()), closedAt))
    }

    /// シナリオの直前(DeviceVideoRecorderSession.ensureRecording)。動いている録画があれば true。予期しない死亡からの
    /// 撮り直しの途中ならその結果を待ち、止まったままなら撮り直して "Recording started" を確かめる(spawnNextPart)
    func ensureRecording() async -> Bool {
        guard !stopRequested else { return false }
        if let process, process.isRunning { return true }
        // 撮り直しの途中の監視タスクは**入れ替わるたびに新しい方を待ち直す**(stop() と同じ形)。1つ待って自分で spawn すると、
        // 待っている間に撮り直した part がすぐ死んだとき、その監視タスクの撮り直しと二重に spawn する
        var awaited: Task<Void, Never>?
        while process == nil || process?.isRunning == false, let pending = watchTask, pending != awaited {
            awaited = pending
            await pending.value
        }
        if let process, process.isRunning { return true }
        guard !stopRequested else { return false }
        warn("the recording was not running before a scenario — starting it again")
        return await spawnNextPart()
    }

    private func source(of parts: [(url: URL, startedAt: Date, durationMs: Int, closedAt: Date)]) -> RecordingSource {
        RecordingSource(
            files: parts.map(\.url),
            segments: parts.map {
                RecordingIndexSegment(startedAt: ISO8601Millis.string(from: $0.startedAt),
                                      durationMs: $0.durationMs)
            },
            closedAt: parts.map(\.closedAt))
    }

    func stop() async -> RecordingSource? {
        stopRequested = true
        // **部分の終了処理(確定・再spawn)の途中なら、その完了を待ってから止める**。handlePartExited は
        // process を nil にしてから await するので、その間に来た stop は下の停止を素通りし、後から確定した
        // 部分が返却済みの files から漏れて .mov が残る。待った後に次の部分が動いていれば下の停止が止める
        var awaitedExit: Task<Void, Never>?
        while process == nil, let pending = watchTask, pending != awaitedExit {
            awaitedExit = pending
            await pending.value
        }
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
        return source(of: parts)
    }

    /// 同じ udid への stale な recordVideo(client プロセス)を起動前に best-effort で止める。
    /// **SIGINT で止める**(既定の SIGTERM だと moov が書かれないうえ、端末側のセッションが
    /// 握られたまま残り、そのデバイスが再起動まで録画できなくなる。実測)。
    /// **端末側に残るセッションはこれでは解けない** —— プロセスが1つも無いのに録画が始まらない形が
    /// あり、そちらは smokeCheck が busy として報告する
    /// **止まるまで待つ**(上限 smokeStopGraceSeconds)。待たずに試し撮りへ進むと、止まりかけの client がまだ握っていて
    /// "A recording is already in progress" で断られ、そのデバイスは run の間ずっと静止画になった。撮り始める前の client は
    /// SIGINT を無視するので送り直す(interruptRecorder と同じ理由)
    func killStaleRecording() async {
        let pattern = "simctl io \(udid) recordVideo"
        let deadline = clock() + stopGraceLimit
        repeat {
            guard (try? Shell.run(["pkill", "-INT", "-f", pattern]))?.status == 0 else { return }
            try? await Task.sleep(nanoseconds: UInt64(Self.interruptRepeatSeconds * 1_000_000_000))
        } while clock() < deadline
        warn("a leftover recordVideo for this simulator did not stop within \(Int(stopGraceLimit))s of SIGINT")
    }

    // MARK: - 見張りへの引き渡し(RecorderWatch / `fleetest api recorder-watch`)

    enum HandOffOutcome: Equatable {
        /// 見張りへ渡した。**ファイルの所有も見張りへ**(client が終わってから消す。呼び手は消さない)
        case watching(watcherPID: pid_t, client: pid_t)
        /// もう動いていない(呼び手が今あるファイルを消す)
        case clientGone(client: pid_t)
        /// 見張りを起こせなかった(身元が無い / 実行ファイルが fleetest でない / run() が投げた)。呼び手が今あるファイルを消す
        case unwatched(client: pid_t, reason: String)
    }

    /// 見張りの起こし方(純粋関数。テストが引数と環境を見る)。**FT_PARENT_PID を外す** —— 見張りは親(fleetest)より長生きするのが目的
    /// (process-lifecycle.md の例外。`InterruptRelay` にも載せない)
    static func watcherLaunch(executable: URL, target: RecorderWatch.Target, file: URL, environment: [String: String])
        -> (executable: URL, arguments: [String], environment: [String: String]) {
        var env = environment
        env[ParentDeathWatch.environmentKey] = nil
        return (executable,
                ["api", "recorder-watch", "--pid", String(target.pid), "--started-us", String(target.startedMicroseconds),
                 "--file", file.path],
                env)
    }

    /// 止める期限を過ぎてもまだ動いている client を見張りへ渡す。呼び手はもう process を持たない(self.process / watchTask に
    /// 載らない)ので、見張らないと stop() でも止まらずファイルが残る。
    /// **見張りは fleetest より長生きする別プロセス**(`fleetest api recorder-watch`)—— プロセスの中のタスクにすると、fleetest が
    /// 先に終わった後で撮り始めた client を誰も止めない。
    /// `target` = spawn の直後に採った身元(ここで採り直さない = 終わって回収された pid が別のプロセスに使い回された形を弾く)。
    /// `stderr` = client の stderr のパイプの読み口。**見張りが読み継ぐ** —— fleetest が終わると元の読み手が消え、遅れて撮り始めた
    /// client が stderr へ書いた瞬間に SIGPIPE で死ぬ(SIGINT 以外の終わり方 = 端末側のセッションが残りうる)。
    /// handOff 自身はファイルを消さない(所有の規則は HandOffOutcome の各 case)
    static func handOff(_ process: Process, target: RecorderWatch.Target?, stderr: FileHandle, leaving url: URL,
                        watcher: URL?, environment: [String: String] = ProcessInfo.processInfo.environment) -> HandOffOutcome {
        let client = process.processIdentifier
        guard process.isRunning else { return .clientGone(client: client) }
        guard let target else { return .unwatched(client: client, reason: "its identity could not be read") }
        // 門: 見張りは fleetest 自身(`VisionHelperHost.shouldStart` と同じ)。別の実行ファイルからは起こせない
        guard let watcher, watcher.lastPathComponent == "fleetest" else {
            return .unwatched(client: client, reason: "the executable is not fleetest")
        }
        let launch = watcherLaunch(executable: watcher, target: target, file: url, environment: environment)
        let watcherProcess = Process()
        watcherProcess.executableURL = launch.executable
        watcherProcess.arguments = launch.arguments
        watcherProcess.environment = launch.environment
        watcherProcess.standardInput = stderr
        watcherProcess.standardOutput = FileHandle.nullDevice
        watcherProcess.standardError = FileHandle.nullDevice
        watcherProcess.qualityOfService = .utility
        do {
            try watcherProcess.run()
        } catch {
            return .unwatched(client: client, reason: "the watcher could not be started: \(error.localizedDescription)")
        }
        return .watching(watcherPID: watcherProcess.processIdentifier, client: client)
    }

    /// 見張りへ渡した結果の発話(純粋関数。事実だけ・復旧を約束しない)。3 つの呼び手(start / spawnPartOnce / HostRecordingProbe)が
    /// 同じ文を出す。**`restart-devices --name` は論理名しか受けない**ので、再起動の案内は udid で撃てる既存の形(busy の警告と同じ)
    static func handOffNotice(_ outcome: HandOffOutcome, file: URL, udid: String) -> String {
        switch outcome {
        case .watching(let watcherPID, let client):
            return "a watcher (pid \(watcherPID)) keeps sending SIGINT to the recordVideo client \(client) while it can see it,"
                + " and deletes \(file.path) once the client is gone"
        case .clientGone(let client):
            return "the recordVideo client \(client) stopped just after the deadline — \(file.path) was deleted"
        case .unwatched(let client, let reason):
            return "the recordVideo client \(client) outlived the stop deadline and no watcher could be started (\(reason))"
                + " — nothing will stop it, and the file it writes (\(file.path)) will be left behind."
                + " If this simulator stays busy for recording, shut it down and boot it again"
                + " (fleetest api stop-device --udid \(udid) then start-device --name <name>, or xcrun simctl shutdown/boot \(udid))"
        }
    }

    private func warn(_ message: String) {
        ConsoleOut.err("⚠️ [recording] \(udid): \(message)")
    }
}
