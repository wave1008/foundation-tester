// VideoRecordingCoordinator.swift
// run profile の record:true 時、RunOrchestrator がワーカーの起動/離脱・シナリオ開始/終了に
// 合わせて呼び出す録画セッションの束ね役。録画はワーカー単位で回し、成果物はシナリオ(テスト関数)ごとに
// 1 本の mp4 へ壁時計区間で切り出す(VideoRecordingFinalizer.extractClip)。
// 切り出しは全シナリオが終わってからまとめて行う(finish)。ハードウェアエンコーダ 2 並列で始め、
// 失敗・期限超過・配信中に遅いときはその run の残りをソフトウェアにする(extractAtRunEnd)。
// 各シナリオの前に録画が撮れていることを確かめる(prepareScenario。撮り直せなければ静止画方式へ)。
// index.json への書き出しは finish()(run() の task group join 後に 1 回だけ呼ぶ)。

import Foundation

/// RunOrchestrator に注入する録画設定。nil を渡せば録画自体が無効(呼び出し側の既定)。
public struct VideoRecordingConfig: Sendable {
    /// bitrateKbps 省略時の既定。`RunProfileDocument.effectiveRecordBitrateKbps` が
    /// (--profile あり/profile-less の)両経路でこの値を共有する唯一の定義元
    /// 1000: 実測(M2 Ultra・iOS シミュレータ / Android エミュレータ・静的な画面とスクロールの2本・
    /// 500/1000/1500/3000 × 解像度 ON/OFF を各2回)で、1500 → 1000 は iOS のクリップが 15〜35% 小さくなり、
    /// OCR で読める文字の割合は差が見えなかった(条件内の揺れ ±10pt 以下)。500 は iOS の半分解像度(既定)で
    /// 誤読が 2〜5 倍に増えたので下限。数値の全体は docs/performance-tuning.md §3.31。
    /// Android は半分解像度の映像が 1000 に届く量を使わないので、ほぼ変わらない
    public static let defaultBitrateKbps = 1000

    /// recordings/index.json・録画ファイルの書き出し先(RunRecorder.runDir)
    public let runDir: URL
    /// Android の adb パス(AndroidDriver.findADB() 相当)。nil なら Android 録画は無効
    /// (FTCore は FTAndroid を import できないため呼び出し側が注入する)
    public let androidADBPath: String?
    /// true なら成功したシナリオのクリップを保存しない(RunProfileDocument.recordFailuresOnly)
    public let failuresOnly: Bool
    /// クリップ再エンコードの目標 bitrate(kbps)。AVVideoAverageBitRateKey と Android
    /// screenrecord --bit-rate の両方に *1000 して適用(RunProfileDocument.recordBitrateKbps)
    public let bitrateKbps: Int
    /// true なら半分解像度化をスキップ(Android は screenrecord 自体の --size 指定も省略)
    /// (RunProfileDocument.recordFullResolution)
    public let fullResolution: Bool

    public init(runDir: URL, androidADBPath: String? = nil, failuresOnly: Bool = false,
                bitrateKbps: Int = VideoRecordingConfig.defaultBitrateKbps, fullResolution: Bool = false) {
        self.runDir = runDir
        self.androidADBPath = androidADBPath
        self.failuresOnly = failuresOnly
        self.bitrateKbps = bitrateKbps
        self.fullResolution = fullResolution
    }
}

/// 1 ワーカーのフル録画ソース。iOS は要素数 1([.mov])、Android は pull 済みセグメント mp4 群
/// (180 秒毎)。files[i] の壁時計スパンが segments[i](1:1 対応・連結順)。
/// ソース自体は録画停止していた区間(欠落)を含まない = ここでの位置がそのままソース内 CMTime になる
struct RecordingSource: Sendable {
    let files: [URL]
    let segments: [RecordingIndexSegment]
    /// files と 1:1 の「録画プロセスの終了を観測した時刻」(空 = 不明)。VFR のソース(画面が変わったときだけフレームを書く)は
    /// 最後に画面が変わった所でファイルが終わるので segments の終わり ≤ 閉じた時刻。その間は静止画 = 最終フレームを伸ばしてよい
    var closedAt: [Date] = []
}

/// iOS(simctl)/Android(adb screenrecord)の実体を隠す共通インターフェース
protocol DeviceVideoRecorderSession: Sendable {
    /// 録画プロセスの起動に成功したら true。RecordingLease の書き込み可否の判定に使う
    /// (RunOrchestrator.videoRecording?.start(_:) の戻り値経由)
    func start() async -> Bool
    /// 録画停止。フル録画のソースを返す(ファイナライズ/クリップ切り出しは呼び出し側が行う)。
    /// 録画自体が始まっていない/停止時に何も拾えなかった場合は nil
    /// (呼び出し側は警告ログのみで run を失敗させない)
    func stop() async -> RecordingSource?
    /// start() が false を返したときの理由(観測したものだけ。言えなければ nil)。**要件として宣言する** ——
    /// 既定実装だけだと存在型越しの呼び出しが既定の nil に落ち、録画クラスの答えが黙って捨てられる
    func startFailure() async -> RecordingStartFailure?
    /// シナリオの直前に呼ぶ。録画が**撮れている**(開始を確かめた録画プロセスが動いている)なら true。止まっていれば
    /// 撮り直して開始を確かめ、それでも駄目なら false(呼び手は静止画方式へ切り替える)。**要件として宣言する**(上と同じ理由)
    func ensureRecording() async -> Bool
}

extension DeviceVideoRecorderSession {
    func startFailure() async -> RecordingStartFailure? { nil }
    /// 静止画方式(操作のたびに子が撮る)は止まる録画プロセスを持たない
    func ensureRecording() async -> Bool { true }
}

actor VideoRecordingCoordinator {
    private struct ActiveEntry {
        let session: any DeviceVideoRecorderSession
        let workerID: String
        let platform: String
        /// 静止画の撮影先(StillFrameRecorder)。動画で録るワーカーは nil
        let stillFramesDir: URL?
    }

    /// 1 シナリオの実行区間(壁時計)。end が nil の間は実行中(scenarioFinished 未着)。
    /// passed は scenarioFinished 到着時に確定(未着のまま run が終わった場合は nil = 不明。
    /// recordFailuresOnly では「不明」も安全側に倒して保存対象にする)
    private struct ScenarioInterval {
        let scenarioID: String
        let start: Date
        var end: Date?
        var passed: Bool?
    }

    /// クリップ切り出し関数(テスト注入用。既定は VideoRecordingFinalizer.extractClip)
    typealias ClipExtractor = @Sendable (
        _ sourceFiles: [RecordingClipSource], _ clipStartMs: Int, _ clipEndMs: Int,
        _ bitrateKbps: Int, _ fullResolution: Bool, _ hardware: Bool, _ outputURL: URL) async -> Bool

    private let config: VideoRecordingConfig
    /// セッション生成の差し替え(テスト注入用。引数は worker, recordingsDir, sourceStem)
    private let makeSession: (@Sendable (RunWorker, URL, String) -> (any DeviceVideoRecorderSession)?)?
    private let extractClip: ClipExtractor
    /// ソース総尺(ms)→ ソフトウェアの切り出しの期限(秒)
    private let exportDeadline: @Sendable (Int) -> Double
    /// クリップ長(ms)→ ハードウェアの切り出しの期限(秒)
    private let hardwareDeadline: @Sendable (Int) -> Double
    /// 切り出しをハードウェアエンコーダで始める(失敗・期限超過・配信で遅いならこの run の残りはソフトウェア)
    private let hardwareFirst: Bool
    /// ハードウェアの失敗の後に台帳(VideoEncoderLiveness → モニターの ⚠︎HWE)へ書く確かめ。**切り替えの判断には使わない**。
    /// 本番(RunOrchestrator)は HardwareEncoderProbe.check を渡す。init の既定は撃たない(単体テストで本物のエンコーダを叩かない)
    private let probeHardwareEncoder: @Sendable () async -> VideoEncoderLiveness.Verdict?
    /// この Mac でハードウェアエンコーダを使う配信(ライブ更新の iOS の h264)が動いているか。本番(RunOrchestrator)は
    /// LiveEncodeStreams.anyActive を渡す。init の既定は false(単体テストを機械の配信の有無から切り離す)
    private let liveStreamsActive: @Sendable () -> Bool
    /// run につき1回だけ撃つ確かめ
    private var hardwareProbe: Task<Void, Never>?
    /// 生を台帳へ書いたか(成功のたびに書かない = run につき1回)
    private var recordedHardwareAlive = false

    /// エクスポートの同時実行上限。実測(M2 Ultra・E2E の実クリップ 116 本・2 周): ハードウェア 1 → 24.5/24.6s、**2 → 18.3/18.2s**。
    /// ソフトウェアは別プロセス(VTEncoderXPCService)で総処理量が並列度でほぼ増えない(1 → 88.5/92.2s、
    /// 2 → 80.2/79.5s、3 → 77.7/76.7s、4〜12 → 74〜81s。CPU は 1 本で約 2.1 コア・4 本で約 3 コア、GPU 3〜6%)。
    /// ソフトウェアとハードウェアを同時に回すと遅くなる(2+1 → 33.5s・2+2 → 25.8s)ので混ぜない。
    /// ハングさせない保証は期限+exportsAbandoned / hardwareAbandoned 側が持つ
    private static let maxConcurrentExports = 2
    /// ハードウェアの期限 = max(床, クリップ長 / 下限倍速)。実測(上と同じ 741 本)で最遅 2.17 秒・平均で実時間の約 50 倍速。
    /// `VTCompressionSessionInvalidate` から戻らない固着を 128 本中 2 回観測した(別の日の 741 本では 0)。
    /// 固着で払うのはこの期限1回だけ(以降の run の残りはソフトウェア)
    static let hardwareDeadlineFloorSeconds: Double = 10
    static let hardwareMinSpeedRatio: Double = 4
    /// 配信中の1本目のハードウェアの速さ(クリップ長 ÷ 所要 = 実時間の何倍か)がこれ未満なら、この run の残りはソフトウェアにする
    /// = ハードウェアがソフトウェアより遅い(配信がエンコーダを取り合って余力が無い)。実測(M2 Ultra・実クリップ 40 本・
    /// 2 並列・各 1 分): ソフトウェアの中央値 8.6 倍(配信なし)/ 8.5 倍(iOS 8 + Android 6 本の配信)。
    /// ハードウェアは中央値 39.4・38.6 倍(配信なし)/ 28.3・28.3 倍(配信あり)・最遅 11.3 倍 = この配信量では切り替わらない
    static let minHardwareSpeedWhileStreaming: Double = 8
    private var runningExports = 0
    private var exportWaiters: [CheckedContinuation<Void, Never>] = []
    /// ソフトウェアの切り出しが期限超過したら true にし、この run の残りのクリップを断念する
    /// (無応答エンコーダへ投げ続けるとクリップ数 × 期限の待ちが積み上がるため)
    private var exportsAbandoned = false
    /// true ならこの run の残りはソフトウェアで切り出す(ハードウェアの失敗・期限超過・配信中に遅い・台帳が新しい死)
    private var hardwareAbandoned = false
    /// 切り出しを試みた interval 数(1 interval につき1)
    private var clipsAttempted = 0
    /// clipsAttempted のうち使えるクリップが得られなかった数
    private var clipsFailed = 0
    /// **録画ソースが1本も使えなかったワーカー数**(起動できなかった/停止時に読めるファイルが
    /// 無かった)。切り出しまで到達しないので clipsAttempted には現れない —— ここで数えないと、
    /// 録画が全滅した run が index を書かずに**録画タブから黙って消える**
    /// (実害: この Mac の simctl が 0 バイトの .mov を作る状態で、
    /// 「local だけバッジが出ない」ように見えた)
    private var sourcesFailed = 0
    /// デバイスごとの録画ソースの問題(index.json の sourceIssues。RecordingIndex.swift の契約)
    private var sourceIssues: [RecordingSourceIssue] = []

    private var active: [String: ActiveEntry] = [:]  // key = worker.label(物理ワーカー単位)
    /// key = worker.label。superviseWorker の revive で worker.label が変わっても、
    /// 古いラベルの区間は stop()/finish() 時にそのラベルの録画ソースに対して処理されるだけで矛盾しない
    private var scenarioIntervals: [String: [ScenarioInterval]] = [:]
    /// ソース一時ファイル名(recordings/ 配下に直接置く)の一意化。key = workerID
    private var sourceFileNameCounts: [String: Int] = [:]
    /// 最終クリップファイル名の一意化(同一 scenarioID の revive 後再実行等)。key = scenarioID
    private var clipFileNameCounts: [String: Int] = [:]
    private var entries: [RecordingIndexEntry] = []

    /// 閉じた録画ファイル1本。closedAt = 録画プロセスの終了を観測した時刻(不明なら nil)
    private struct Part {
        let url: URL
        let segment: RecordingIndexSegment
        let closedAt: Date?

        var wallStart: Date? { ISO8601Millis.date(from: segment.startedAt) }
        /// 静止画の末尾まで含めた終わり(closedAt が無ければファイルの終わり)
        var wallEnd: Date? {
            guard let start = wallStart else { return nil }
            let fileEnd = start.addingTimeInterval(Double(segment.durationMs) / 1000)
            return max(fileEnd, closedAt ?? fileEnd)
        }

        var coveredSegment: RecordingIndexSegment {
            guard let start = wallStart, let end = wallEnd else { return segment }
            return RecordingIndexSegment(startedAt: segment.startedAt,
                                         durationMs: Int((end.timeIntervalSince(start) * 1000).rounded()))
        }
    }
    /// key = worker.label。run の途中で静止画方式へ切り替えたワーカーの、それまでの動画(collect でその後の分と合わせる)
    private var retiredParts: [String: [Part]] = [:]

    /// 切り出し待ちのクリップ。失敗(期限内に false)したら1回だけソフトウェアで切り出し直す(読むだけなのでデバイスへの
    /// 撃ち直しには当たらない)。実測: 復号の失敗(-11821 Cannot Decode)は同じソースへの切り出し 200 回で再現しなかった
    private struct PendingClip: Sendable {
        let scenarioID: String
        let workerID: String
        let platform: String
        let files: [RecordingClipSource]
        let clipStartMs: Int
        /// ソースの終わりを越えうる(静止画の末尾。writer の endSession が最終フレームを保持する)
        let clipEndMs: Int
        let sourceTotalMs: Int
        /// index.json の segments
        let segments: [RecordingIndexSegment]
        var file: String
    }
    private var queue: [PendingClip] = []
    /// finish() で消す/残すソース
    private var pendingSources: Set<URL> = []
    private var keptSources: Set<URL> = []

    private enum ExtractOutcome { case ok, failed, timedOut, abandoned }
    private enum Encoder { case software, hardwareUnlessAbandoned }

    init(config: VideoRecordingConfig,
         makeSession: (@Sendable (RunWorker, URL, String) -> (any DeviceVideoRecorderSession)?)? = nil,
         extractClip: ClipExtractor? = nil,
         exportDeadline: (@Sendable (Int) -> Double)? = nil,
         hardwareDeadline: (@Sendable (Int) -> Double)? = nil,
         hardwareFirst: Bool = true,
         probeHardwareEncoder: (@Sendable () async -> VideoEncoderLiveness.Verdict?)? = nil,
         liveStreamsActive: (@Sendable () -> Bool)? = nil) {
        self.config = config
        self.hardwareFirst = hardwareFirst
        self.probeHardwareEncoder = probeHardwareEncoder ?? { nil }
        self.liveStreamsActive = liveStreamsActive ?? { false }
        self.makeSession = makeSession
        self.extractClip = extractClip ?? {
            await VideoRecordingFinalizer.extractClip(
                sourceFiles: $0, clipStartMs: $1, clipEndMs: $2,
                bitrateKbps: $3, fullResolution: $4, hardware: $5, to: $6)
        }
        // extractClip は毎回ソース全域を読み直す設計のため、期限はクリップ長でなくソース総尺に
        // 比例させる(床 60 秒は負荷時の正当な遅延を誤タイムアウトさせないための余裕)
        self.exportDeadline = exportDeadline ?? { max(60, Double($0) / 1000) }
        self.hardwareDeadline = hardwareDeadline ?? {
            max(Self.hardwareDeadlineFloorSeconds, Double($0) / 1000 / Self.hardwareMinSpeedRatio)
        }
    }

    /// worker.label(物理ワーカー)ごとにセッションを開始する。revive 後の新ワーカーは
    /// worker.label が変わるため独立したセッション(=別ソース)になる。
    /// 戻り値: 録画の起動に成功したら true(呼び出し側の RecordingLease 書き込み判定用)。
    /// **動画の録画を起動できなければ静止画方式(StillFrameRecorder)へ切り替える** —— iOS シミュレータの
    /// `simctl` の試し撮りが空になる等で、そのデバイスの録画が丸ごと消えていた(残った録画セッションを
    /// 実行前に片付けるようにした後も、デバイス×実行の約2%)。切り替えは失敗した経路だけに払わせる(静止画は撮影1枚 約110〜165ms を
    /// 操作ごとに払うので、常用はしない)。静止画も起動できなければ従来どおり sourcesFailed に数える
    @discardableResult
    func start(_ worker: RunWorker) async -> Bool {
        let workerID = "\(worker.platform):\(worker.logicalName ?? worker.label)"
        let recordingsDir = config.runDir.appendingPathComponent(RecordingIndexIO.directoryName)
        try? FileManager.default.createDirectory(at: recordingsDir, withIntermediateDirectories: true)
        // クリップの最終ファイル名(scenarioID 由来)とは別名前空間(ソースは切り出し後に削除される一時物)
        let sourceStem = "src-\(uniqueSourceStem(for: workerID))"

        let session: (any DeviceVideoRecorderSession)?
        if let makeSession {
            session = makeSession(worker, recordingsDir, sourceStem)
        } else {
            session = Self.defaultSession(worker: worker, config: config,
                                          recordingsDir: recordingsDir, sourceStem: sourceStem)
        }
        if let session, await session.start() {
            register(session, worker: worker, workerID: workerID)
            return true
        }
        let reason: RecordingStartFailure? = if let session { await session.startFailure() } else { .unavailable }
        if !(session is StillFrameRecorder) {
            let stills = StillFrameRecorder(workDir: recordingsDir, fileStem: sourceStem)
            if await stills.start() {
                ConsoleOut.err("⚠️ [recording] \(workerID): screen recording could not start"
                    + (reason.map { " (\($0.rawValue))" } ?? "")
                    + " — recording this device as still frames taken after each action instead")
                sourceIssues.append(RecordingSourceIssue(worker: workerID, phase: .start, reason: reason,
                                                         stillFramesFallback: true))
                register(stills, worker: worker, workerID: workerID)
                return true
            }
        }
        sourceIssues.append(RecordingSourceIssue(worker: workerID, phase: .start, reason: reason))
        sourcesFailed += 1
        return false
    }

    private func register(_ session: any DeviceVideoRecorderSession, worker: RunWorker, workerID: String) {
        active[worker.label] = ActiveEntry(session: session, workerID: workerID, platform: worker.platform,
                                           stillFramesDir: (session as? StillFrameRecorder)?.stillsDir)
    }

    /// そのワーカーの子(シナリオ実行プロセス)が静止画を置く先。静止画で録画中のワーカー(物理 iPhone・
    /// 動画を起動できず切り替えたデバイス)だけ非 nil
    /// (RunOrchestrator → ScenarioHost の `--still-frames-dir`)
    func stillFramesDir(workerLabel: String) -> URL? {
        active[workerLabel]?.stillFramesDir
    }

    private static func defaultSession(worker: RunWorker, config: VideoRecordingConfig,
                                       recordingsDir: URL,
                                       sourceStem: String) -> (any DeviceVideoRecorderSession)? {
        let session: (any DeviceVideoRecorderSession)?
        switch worker.platform {
        case "ios":
            // 物理 iPhone は動画を取り出せないので、操作の直後の静止画をまとめる(StillFrameRecorder)
            if worker.connection.physical {
                session = StillFrameRecorder(workDir: recordingsDir, fileStem: sourceStem)
            } else {
                session = worker.connection.udid.map {
                    IOSSimulatorVideoRecorder(udid: $0, workDir: recordingsDir, fileStem: sourceStem)
                }
            }
        case "android":
            if let serial = worker.connection.serial, let adbPath = config.androidADBPath {
                session = AndroidScreenVideoRecorder(
                    serial: serial, adbPath: adbPath, workDir: recordingsDir, fileStem: sourceStem,
                    bitrateKbps: config.bitrateKbps, fullResolution: config.fullResolution)
            } else {
                session = nil
            }
        default:
            session = nil
        }
        return session
    }

    /// RunOrchestrator のワーカーループが**各シナリオの直前**(scenarioStarted より前)に呼ぶ。録画が撮れていることを
    /// 確かめ(止まっていれば撮り直して開始を確かめる)、撮れないならこのワーカーの残りを静止画方式へ切り替える。
    /// 戻り値はこのシナリオの子へ渡す静止画の置き場(`--still-frames-dir`)。動画で撮れているなら nil
    func prepareScenario(workerLabel: String) async -> URL? {
        guard let entry = active[workerLabel] else { return nil }
        if let stills = entry.stillFramesDir { return stills }
        if await entry.session.ensureRecording() { return nil }
        // 撮り直しても始まらない: それまでの動画は残し(collect で合わせる)、残りは静止画で撮る。テストは止めない
        if let source = await entry.session.stop() {
            pendingSources.formUnion(source.files)
            retiredParts[workerLabel, default: []] += Self.parts(of: source)
        }
        let recordingsDir = config.runDir.appendingPathComponent(RecordingIndexIO.directoryName)
        let stills = StillFrameRecorder(workDir: recordingsDir, fileStem: "src-\(uniqueSourceStem(for: entry.workerID))")
        guard await stills.start() else {
            ConsoleOut.err("⚠️ [recording] \(entry.workerID): the screen recording stopped and could not be restarted"
                + " — the rest of this device's scenarios are not recorded")
            sourceIssues.append(RecordingSourceIssue(worker: entry.workerID, phase: .start, reason: nil))
            active[workerLabel] = ActiveEntry(session: stills, workerID: entry.workerID, platform: entry.platform,
                                              stillFramesDir: nil)
            return nil
        }
        ConsoleOut.err("⚠️ [recording] \(entry.workerID): the screen recording stopped and could not be restarted"
            + " — recording the rest of this device's scenarios as still frames taken after each action")
        sourceIssues.append(RecordingSourceIssue(worker: entry.workerID, phase: .start, reason: nil,
                                                 stillFramesFallback: true))
        active[workerLabel] = ActiveEntry(session: stills, workerID: entry.workerID, platform: entry.platform,
                                          stillFramesDir: stills.stillsDir)
        return stills.stillsDir
    }

    /// RunOrchestrator のワーカーループが ScenarioRunner.runOne 呼び出し直前に通知する
    func scenarioStarted(workerLabel: String, scenarioID: String, at: Date) {
        scenarioIntervals[workerLabel, default: []].append(
            ScenarioInterval(scenarioID: scenarioID, start: at, end: nil, passed: nil))
    }

    /// RunOrchestrator のワーカーループが ScenarioRunner.runOne 呼び出し直後に通知する。
    /// passed は recordFailuresOnly の判定に使う(frozen は呼び出し側で false 扱いにして渡す)
    func scenarioFinished(workerLabel: String, at: Date, passed: Bool) {
        guard var list = scenarioIntervals[workerLabel], let last = list.indices.last,
              list[last].end == nil else { return }
        list[last].end = at
        list[last].passed = passed
        scenarioIntervals[workerLabel] = list
    }

    func stop(_ worker: RunWorker) async {
        guard let entry = active.removeValue(forKey: worker.label) else { return }
        await collect(worker.label, entry)
    }

    /// run() の task group join 後に 1 回呼ぶ。残っているセッション(通常は無いはずの安全網)を
    /// 畳み、クリップをまとめて切り出してから index.json を書く
    func finish() async {
        let remaining = active
        active.removeAll()
        for (label, entry) in remaining { await collect(label, entry) }
        await extractAtRunEnd()
        // 先頭 segment の startedAt 昇順(再生ビューの既定選択・一覧表示の安定順)
        entries.sort { ($0.segments.first?.startedAt ?? "") < ($1.segments.first?.startedAt ?? "") }
        if clipsFailed > 0 {
            ConsoleOut.err(
                "⚠️ [recording] \(clipsFailed)/\(clipsAttempted) clips could not be extracted")
        }
        if sourcesFailed > 0 {
            ConsoleOut.err(
                "⚠️ [recording] \(sourcesFailed) device(s) produced no usable recording"
                 + " (the recorder started but nothing readable came out)")
        }
        RecordingIndexIO.write(entries, runDir: config.runDir,
                               clipsAttempted: clipsAttempted, clipsFailed: clipsFailed,
                               sourcesFailed: sourcesFailed, sourceIssues: sourceIssues)
    }

    /// 1 ワーカーの録画を停止し、そのワーカーで実行された各シナリオの区間をクリップの待ちに積む
    private func collect(_ workerLabel: String, _ entry: ActiveEntry) async {
        // 区間が1つも無いワーカーの録画は破棄(シナリオが1本も来なかったアイドルワーカー等)。
        // **stop() より先に引く** —— 失敗の数え方がアイドルかどうかで変わるため
        let intervals = scenarioIntervals.removeValue(forKey: workerLabel) ?? []
        var parts = retiredParts.removeValue(forKey: workerLabel) ?? []
        if let source = await entry.session.stop() {
            pendingSources.formUnion(source.files)
            parts += Self.parts(of: source)
        }
        guard !parts.isEmpty else {
            // 読めるファイルが1本も残らなかった(録画プロセスは動いていたのに空だった等)。
            // **黙って消さない** —— finish() がこの数を index に残し、録画タブに run が出る。
            // **ただしアイドルワーカーは数えない** —— `deviceKeepCount` は本数+予備1台を残すので、
            // 本数 < 台数の run では予備が必ず空になる。数えると小さい run のたびに誤警報が出て、
            // 「録画が本当に全滅した run」と見分けが付かなくなる(この警告は全滅の検出が目的)
            if !intervals.isEmpty {
                sourcesFailed += 1
                sourceIssues.append(RecordingSourceIssue(worker: entry.workerID, phase: .stop))
            }
            return
        }
        queue += makeClips(intervals, parts: parts, entry: entry)
    }

    private static func parts(of source: RecordingSource) -> [Part] {
        source.files.indices.map { i in
            Part(url: source.files[i], segment: source.segments[i],
                 closedAt: i < source.closedAt.count ? source.closedAt[i] : nil)
        }
    }

    /// 区間ごとに、重なる録画ファイルからクリップを1本作る(clipsAttempted に数える)。
    /// クリップの壁時計範囲 = [max(シナリオ開始, 録画開始), min(シナリオ終了, 閉じた時刻)]。
    /// ファイルの終わりから閉じた時刻までは静止画なので、その分は最終フレームを伸ばす(clipEndMs がソースを越える)
    private func makeClips(_ intervals: [ScenarioInterval], parts: [Part], entry: ActiveEntry) -> [PendingClip] {
        var clips: [PendingClip] = []
        for interval in intervals {
            if Self.shouldSkip(failuresOnly: config.failuresOnly, passed: interval.passed) { continue }
            let overlapping = parts.filter { part in
                guard let start = part.wallStart, let end = part.wallEnd else { return false }
                return start < (interval.end ?? .distantFuture) && end > interval.start
            }
            // 位置計算と連結の両方で、素材ごとの静止末尾を含む同じ尺を使う。
            let segments = overlapping.map(\.coveredSegment)
            guard let fileRange = RecordingWallClock.wallClockRange(of: segments) else {
                // そのワーカーの録画はあるのに、このシナリオに重なるファイルが1本も無い = 録画が失われた。**黙って飛ばさない**
                clipsAttempted += 1
                clipsFailed += 1
                ConsoleOut.err("⚠️ [recording] \(interval.scenarioID): no readable recording covers this scenario")
                continue
            }

            let clipWallStart = max(interval.start, fileRange.start)
            let clipWallEnd = min(interval.end ?? fileRange.end, fileRange.end)
            // 実長500ms未満はスキップ
            guard clipWallEnd.timeIntervalSince(clipWallStart) >= 0.5 else { continue }

            let clipStartMs = RecordingWallClock.offsetMs(segments, at: clipWallStart)
            let clipEndMs = RecordingWallClock.offsetMs(segments, at: clipWallEnd)
            // シナリオ区間全体が録画の欠落(停止していた間)に落ちるとゼロ長になり得る
            guard clipEndMs > clipStartMs else { continue }

            let clipSegments = RecordingWallClock.intersect(segments, range: (clipWallStart, clipWallEnd))
            clipsAttempted += 1
            clips.append(PendingClip(
                scenarioID: interval.scenarioID, workerID: entry.workerID, platform: entry.platform,
                files: zip(overlapping, segments).map { RecordingClipSource(url: $0.0.url, durationMs: $0.1.durationMs) },
                clipStartMs: clipStartMs, clipEndMs: clipEndMs,
                sourceTotalMs: segments.reduce(0) { $0 + $1.durationMs }, segments: clipSegments,
                file: "\(RecordingIndexIO.directoryName)/\(uniqueClipStem(for: interval.scenarioID)).mp4"))
        }
        return clips
    }

    /// run 完了時の切り出し(同時 maxConcurrentExports 本)。終わったら使い終えたソースを消す。
    /// **2回とも失敗したクリップのソースは残す**(壊れたソースか一時的な失敗かを後から分ける唯一の材料)。
    /// エンコーダの選び方: 台帳が新しい死ならソフトウェア。**この Mac で配信がハードウェアを使っているなら、1本目だけを
    /// 先にハードウェアで切り出して速さを測り**、MinLiveSpeedRatio 未満なら残りはソフトウェア(余力が無い)
    private func extractAtRunEnd() async {
        var clips = queue
        queue.removeAll()
        if hardwareFirst, !clips.isEmpty, VideoEncoderLiveness.isKnownDead() {
            hardwareAbandoned = true
            ConsoleOut.err("⚠️ [recording] the hardware video encoder is known to be broken on this Mac"
                + " — extracting clips with the software encoder (slower)")
        }
        if hardwareFirst, !hardwareAbandoned, !clips.isEmpty, liveStreamsActive() {
            let first = clips.removeFirst()
            if let speed = await extractFinal(first), speed < Self.minHardwareSpeedWhileStreaming, !hardwareAbandoned {
                hardwareAbandoned = true
                ConsoleOut.err("⚠️ [recording] live streams are using the hardware video encoder (the first clip ran at "
                    + String(format: "%.1f", speed) + "x real time) — extracting the rest with the software encoder")
            }
        }
        await withTaskGroup(of: Void.self) { group in
            for clip in clips {
                group.addTask { _ = await self.extractFinal(clip) }
            }
        }
        await hardwareProbe?.value
        for file in pendingSources.subtracting(keptSources) { try? FileManager.default.removeItem(at: file) }
        if !keptSources.isEmpty {
            ConsoleOut.err("⚠️ [recording] kept the source recording(s) for diagnosis: "
                + keptSources.map(\.path).sorted().joined(separator: ", "))
        }
        pendingSources.removeAll()
    }

    /// 1本の切り出し。ハードウェアで始め、**失敗・期限超過ならこの run の残りをソフトウェアにする**(壊れる前に手を引く。
    /// 実測では全滅の前に失敗がぽつぽつ出ていた)。失敗(false)ならソフトウェアで1回やり直す。
    /// 戻り値: 1回目がハードウェアで成功したときの速さ(クリップ長 ÷ 所要。実時間の何倍か)。それ以外は nil
    @discardableResult
    private func extractFinal(_ clip: PendingClip) async -> Double? {
        let started = Date()
        var (outcome, hardware) = await extract(clip, encoder: hardwareFirst ? .hardwareUnlessAbandoned : .software)
        let elapsed = Date().timeIntervalSince(started)
        if hardware { observeHardware(outcome, clip: clip) }
        let speed = hardware && outcome == .ok && elapsed > 0
            ? Double(clip.clipEndMs - clip.clipStartMs) / 1000 / elapsed : nil
        if outcome == .timedOut, hardware {
            hardware = false
            outcome = await extract(clip, encoder: .software).outcome
        }
        if outcome == .failed {
            ConsoleOut.err("⚠️ [recording] \(clip.scenarioID): clip extraction failed — retrying once"
                + (hardware ? " with the software encoder" : ""))
            outcome = await extract(clip, encoder: .software).outcome
            if outcome == .ok {
                ConsoleOut.err("⚠️ [recording] \(clip.scenarioID): clip extraction succeeded on the retry")
            }
        }
        switch outcome {
        case .ok:
            record(clip)
        case .failed:
            clipsFailed += 1
            keptSources.formUnion(clip.files.map(\.url))
            ConsoleOut.err("⚠️ [recording] \(clip.scenarioID): clip extraction failed again on the retry")
        case .timedOut:
            giveUp(after: clip, deadline: exportDeadline(clip.sourceTotalMs))
        case .abandoned:
            clipsFailed += 1
        }
        return speed
    }

    /// ハードウェアの1回の結果をこの run の切り替えと台帳に映す。**失敗・期限超過は1回でこの run の残りをソフトウェアに**
    /// (素材のせいかもしれないが、壊れかけのエンコーダを使い続けるより安全側)。台帳(⚠︎HWE)へは合成映像の確かめ・期限超過の
    /// 事実だけを書く —— 実際の切り出しの失敗1回は素材のせいかもしれないので死と書かない
    private func observeHardware(_ outcome: ExtractOutcome, clip: PendingClip) {
        switch outcome {
        case .ok:
            guard !recordedHardwareAlive else { return }
            recordedHardwareAlive = true
            VideoEncoderLiveness.record(.init(state: .alive, checkedAt: Date().timeIntervalSince1970, source: .call))
        case .failed, .timedOut:
            VideoEncoderHistory.append(event: outcome == .timedOut ? .callTimedOut : .callFailed,
                                       source: .call, detail: clip.scenarioID)
            if outcome == .timedOut {
                VideoEncoderLiveness.record(.init(
                    state: .dead, checkedAt: Date().timeIntervalSince1970, source: .call,
                    error: "clip extraction did not finish within \(Int(hardwareDeadline(clip.clipEndMs - clip.clipStartMs)))s"))
            }
            if !hardwareAbandoned {
                hardwareAbandoned = true
                ConsoleOut.err("⚠️ [recording] \(clip.scenarioID): the hardware video encoder "
                    + (outcome == .timedOut ? "did not finish in time" : "failed")
                    + " — using the software encoder for the rest of this run")
            }
            if outcome == .failed, hardwareProbe == nil {
                let probe = probeHardwareEncoder
                hardwareProbe = Task {
                    guard let verdict = await probe() else { return }
                    VideoEncoderLiveness.record(verdict)
                }
            }
        case .abandoned:
            return
        }
    }

    private func record(_ clip: PendingClip) {
        entries.append(RecordingIndexEntry(
            scenarioID: clip.scenarioID, worker: clip.workerID, platform: clip.platform,
            file: clip.file, segments: clip.segments))
    }

    /// ソフトウェアの期限超過 = 断念する。放置した敗者 task の writer/reader には触らない(固着した VT セッションの
    /// ロックで cancelWriting ごと共倒れし得る)。書きかけ .mp4 は index.json が参照しないため無害。
    /// 既に断念済み(別のクリップが期限超過した巻き添え)なら警告を二重に出さない
    private func giveUp(after clip: PendingClip, deadline: Double) {
        clipsFailed += 1
        if !exportsAbandoned {
            exportsAbandoned = true
            ConsoleOut.err("⚠️ [recording] \(clip.scenarioID): clip extraction did not finish within "
                + "\(Int(deadline))s. Giving up on the remaining clips of this run")
        }
    }

    /// 1 回分の切り出し(スロット取得→期限付き実行→解放)。hardware = 実際にハードウェアで撃ったか。
    /// **エンコーダはスロットを取った後に決める** —— 待っている間に別のクリップがハードウェアを見限っていたら
    /// ソフトウェアで撃つ(先に決めると、待っていた分が壊れかけのエンコーダへもう一度撃つ)
    private func extract(_ clip: PendingClip, encoder: Encoder) async -> (outcome: ExtractOutcome, hardware: Bool) {
        let finalURL = config.runDir.appendingPathComponent(clip.file)
        // **一時フォルダへ書いてから、成功したときだけ recordings/ へ移す** —— 期限を過ぎた敗者 task は待たずに放置するので
        // (固着した VT セッションに触ると共倒れし得る)、後から書かれた出力が index の参照しないゴミとして recordings/ に残っていた
        let temporaryDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("fleetest-clip-\(UUID().uuidString)", isDirectory: true)
        let outputURL = temporaryDir.appendingPathComponent(finalURL.lastPathComponent)
        await acquireExportSlot()
        if exportsAbandoned {  // スロット待ちの間に他のエクスポートが期限超過した場合
            releaseExportSlot()
            return (.abandoned, false)
        }
        guard (try? FileManager.default.createDirectory(at: temporaryDir, withIntermediateDirectories: true)) != nil else {
            releaseExportSlot()
            return (.failed, false)
        }
        defer { try? FileManager.default.removeItem(at: temporaryDir) }
        let hardware = encoder == .hardwareUnlessAbandoned && !hardwareAbandoned
        let deadline = hardware ? hardwareDeadline(clip.clipEndMs - clip.clipStartMs) : exportDeadline(clip.sourceTotalMs)
        let extract = extractClip
        let (bitrate, full) = (config.bitrateKbps, config.fullResolution)
        let (files, start, end) = (clip.files, clip.clipStartMs, clip.clipEndMs)
        let outcome: Bool? = await raceWithDeadline(seconds: deadline, onTimeout: Bool?.none) {
            await extract(files, start, end, bitrate, full, hardware, outputURL)
        }
        releaseExportSlot()
        switch outcome {
        case true?:
            try? FileManager.default.removeItem(at: finalURL)
            guard (try? FileManager.default.moveItem(at: outputURL, to: finalURL)) != nil else {
                try? FileManager.default.removeItem(at: outputURL)
                return (.failed, hardware)
            }
            return (.ok, hardware)
        case false?:
            try? FileManager.default.removeItem(at: outputURL)
            return (.failed, hardware)
        case nil:
            return (.timedOut, hardware)
        }
    }

    /// recordFailuresOnly 時にこの区間のクリップをスキップするか。確実に成功したと分かっている
    /// (passed == true)場合だけスキップし、失敗・不明(nil。scenarioFinished 未着のまま run が
    /// 終わった等)は安全側に倒して保存対象に残す。actor 外(単体テスト)からも呼べるよう static/nonisolated
    static func shouldSkip(failuresOnly: Bool, passed: Bool?) -> Bool {
        failuresOnly && passed == true
    }

    /// エクスポート実行スロットの取得/返却。extractAtRunEnd の task group で並走する切り出しの同時実行を
    /// maxConcurrentExports に制限する。期限超過時もスロットは返却する(敗者 task が裏で動いて
    /// いても、exportsAbandoned が新規エクスポートを止めるため実同時数は超過しない)
    private func acquireExportSlot() async {
        if runningExports < Self.maxConcurrentExports {
            runningExports += 1
            return
        }
        await withCheckedContinuation { exportWaiters.append($0) }
    }

    private func releaseExportSlot() {
        if exportWaiters.isEmpty {
            runningExports -= 1
        } else {
            exportWaiters.removeFirst().resume()  // スロットを引き継ぐ(runningExports は不変)
        }
    }

    private func uniqueSourceStem(for workerID: String) -> String {
        let base = RecordingIndexIO.sanitizedFileName(for: workerID)
        let count = (sourceFileNameCounts[base] ?? 0) + 1
        sourceFileNameCounts[base] = count
        return count == 1 ? base : "\(base)~\(count)"
    }

    private func uniqueClipStem(for scenarioID: String) -> String {
        let base = RecordingIndexIO.sanitizedFileName(for: scenarioID)
        let count = (clipFileNameCounts[base] ?? 0) + 1
        clipFileNameCounts[base] = count
        return count == 1 ? base : "\(base)~\(count)"
    }
}
