// RunOrchestrator.swift
// シナリオ並列実行のオーケストレーション。CLI(ftester run --ports / ftester api run)が使う。
// シナリオ実行の実体は ftester-scenarios サブプロセス(ScenarioHost)で、
// FM フックはサブプロセス側が持つ。ワーカーのドライバはウォームアップ・接続確認用。

import Foundation

/// 実行対象シナリオ。URL(scenario:// スキーム)が一意キー(呼び出し側の実行レーン管理と互換)
public struct ScenarioRunItem: Identifiable, Sendable {
    public let info: ScenarioInfo
    public let url: URL
    public var id: URL { url }

    public init(info: ScenarioInfo) {
        self.info = info
        self.url = Self.url(for: info.id)
    }

    /// シナリオ ID(日本語可)→ 一意キー URL
    public static func url(for scenarioID: String) -> URL {
        let encoded = scenarioID.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed)
            ?? "scenario"
        return URL(string: "scenario://run/\(encoded)") ?? URL(fileURLWithPath: "/scenario")
    }
}

/// 並列ワーカー定義。platform が一致するシナリオだけをキューから消化する
public struct RunWorker {
    public let label: String              // 例: "ios:8123" / "android:emulator-5554"
    public let platform: String           // "ios" / "android"
    public let driver: AppDriver          // ウォームアップ・接続確認用
    public let connection: DriverConnection  // サブプロセスへ渡す接続情報
    /// 実行プロファイル上のデバイス論理名(profiles/machines/ の name)。
    /// ProfileWorkerFactory 経由で構築されたワーカーのみ設定される(ftester api run の
    /// workersReady イベントの id 構築に使う。--ports 等の非プロファイル経路では nil)
    public let logicalName: String?

    public init(label: String, platform: String, driver: AppDriver, connection: DriverConnection,
                logicalName: String? = nil) {
        self.label = label
        self.platform = platform
        self.driver = driver
        self.connection = connection
        self.logicalName = logicalName
    }
}

/// 実行の進捗イベント。flowURL(scenario:// URL)でシナリオを識別する(呼び出し側はこの URL を
/// キーに実行状態を更新する)
public enum RunEvent: Sendable {
    case runStarted(total: Int, workerLabels: [String])
    /// ウォームアップ完了(コールドブート対策の snapshot 済み)
    case workerReady(worker: String)
    /// 接続不能などでワーカーが離脱した(他ワーカーが残キューを引き継ぐ)
    case workerFailed(worker: String, message: String)
    /// ワーカーの進行状況メッセージ(離脱ではない。ワーカー復帰の進行可視化用。NDJSON では "log")
    case workerLog(worker: String, message: String)
    /// シナリオの結果を取り消して別デバイスへ振り直した(Test Explorer は該当項目を「待機中」へ戻す。
    /// NDJSON では "scenarioRequeued"。契約: vscode-ftester/src/model.ts ScenarioRequeuedEvent)
    case flowRequeued(worker: String, flowURL: URL, reason: String, attempt: Int, limit: Int)
    case flowStarted(worker: String, flowURL: URL, flowName: String, isDirty: Bool)
    /// scene 開始(ScenarioEvent kind "sceneStarted" 相当)
    case sceneStarted(worker: String, flowURL: URL, scene: Int, sceneTitle: String)
    case step(worker: String, flowURL: URL, result: StepResult)
    /// scene 終了(ScenarioEvent kind "sceneFinished" 相当)。passed = その scene の合否
    case sceneFinished(worker: String, flowURL: URL, scene: Int, sceneTitle: String, passed: Bool)
    /// デバッグ実行で一時停止した(index = 次に実行するステップ番号、file/line = その位置)
    case flowPaused(worker: String, flowURL: URL, index: Int, description: String,
                    file: String?, line: Int?)
    /// 自己修復でフロー上書き保存(旧 YAML 方式の名残。現行シナリオでは未発行)
    case flowHealed(worker: String, flowURL: URL)
    /// 自己修復の構造化提案(修復候補の確認 UI 向け)。ログ表示は既存の .step 側で行う。
    /// command = 対象コマンドの description(例: tap "旧セレクタ"。説明提案の生成に使う)
    case fixSuggestion(worker: String, flowURL: URL, scenarioID: String,
                       command: String?, file: String?, line: Int?,
                       oldSelector: String?, newSelector: String?, message: String)
    case flowFinished(worker: String, flowURL: URL, passed: Bool,
                      triage: TriageInfo?, reportURL: URL?)
    /// 担当ワーカー不在などで実行できなかった(失敗として数える)
    case flowSkipped(flowURL: URL, reason: String)
    case runFinished(passed: Int, failed: Int)
}

public struct RunSummary: Sendable {
    public let total: Int
    public let failed: Int
    public var passed: Int { total - failed }
    /// 実行中に劣化・離脱したワーカーの記録(「label: 理由」)。凍結/消失/連続失敗/接続不能で離脱した
    /// ワーカーを可視化する(復帰した場合も含む)。連鎖失敗の事後診断・レポート表示用。
    public let degradedWorkers: [String]
    /// 結果取り消し+振り直しの監査記録(成功した振り直しは合否記録に痕跡を残さないため、
    /// ここに「どのシナリオを・どのワーカーから・何回目か」を残す)。
    public let freezeRetries: [String]

    public init(total: Int, failed: Int, degradedWorkers: [String] = [],
                freezeRetries: [String] = []) {
        self.total = total
        self.failed = failed
        self.degradedWorkers = degradedWorkers
        self.freezeRetries = freezeRetries
    }
}

/// withDeadline の「継続を一度だけ resume する」ガード(op 完了 と 期限 のレース勝者判定)。
private actor DeadlineGuard {
    private var done = false
    func claim() -> Bool {
        if done { return false }
        done = true
        return true
    }
}

/// withDeadline の満期スレッパー task 参照を保持する箱(op 勝利時に cancel するための前方参照用)。
/// 代入は op の初回 await より前(同期区間)で完了するため実質レースしない。
private final class DeadlineTaskBox: @unchecked Sendable {
    var task: Task<Void, Never>?
}

/// 並列ワーカーからの文字列記録の収集(劣化ワーカー・振り直し監査)。run() が summary に畳む。
private actor NoteCollector {
    private var entries: [String] = []
    func add(_ entry: String) { entries.append(entry) }
    func snapshot() -> [String] { entries }
}

/// 1 シナリオあたりの凍結再実行上限。ポイズンシナリオのフリート全滅を防ぐ
/// (2→1: 意図的に NG になるテストがデバイス不調と重なった際の再実行を最小化。ユーザー決定 2026-07-18)
private let MAX_FREEZE_RETRIES = 1

/// 失敗後ブリッジチェックの観察窓と、ログ静止によるウェッジ確定時間(秒)。
/// AX 飽和(健全だが数十秒無応答)を「接続不能」と誤検知しないための値(bridgeUnreachable 参照)
private let BRIDGE_PROBE_OBSERVE_SECONDS: TimeInterval = 60
private let BRIDGE_PROBE_LOG_SILENCE_SECONDS: TimeInterval = 15

/// 失敗後ブリッジプローブ 1 回分の結果(probeBridge 注入クロージャの戻り値)
public enum BridgeProbeOutcome: Sendable {
    case ok
    /// connection refused = ポート LISTEN なし(ブリッジプロセス死亡)
    case refused
    /// 期限内無応答(busy かウェッジかはこれだけでは未確定)
    case silent
}

/// ワーカー・サーキットブレーカ: 同一ワーカーで通常失敗(凍結/消失に該当しない)が連続でこの回数に
/// 達したら、原因不明でも「不調ワーカー」とみなして離脱させ現シナリオを振り直す。凍結/消失の個別
/// プローブで拾えない不良(ブリッジのウェッジ・ANR 連発等)で死んだワーカーへ投げ続ける事故を防ぐ。
private let WORKER_FAILURE_CIRCUIT_THRESHOLD = 3

/// 1論理デバイスの復帰試行上限。復帰→即死→復帰の暴走防止
private let MAX_WORKER_REVIVES = 2

/// run 中に稼働しているワーカーのデバイスキー集合(run-lease ハートビート対象)。
private actor RunLeaseKeys {
    private var keys: Set<String> = []
    func insert(_ key: String) { keys.insert(key) }
    func remove(_ key: String) { keys.remove(key) }
    func snapshot() -> Set<String> { keys }
}

/// 並列ワーカーへのシナリオ分配キュー(早い者勝ち)
actor ScenarioQueue {
    private var items: [ScenarioRunItem]
    private var attempts: [URL: Int] = [:]
    init(_ items: [ScenarioRunItem]) { self.items = items }
    func next() -> ScenarioRunItem? { items.isEmpty ? nil : items.removeFirst() }
    func hasItems() -> Bool { !items.isEmpty }

    /// 凍結による再実行。上限(MAX_FREEZE_RETRIES)まで item を末尾へ戻し、
    /// 何回目の再実行かを返す。上限超過なら nil(=もう再実行しない)。
    func requeue(_ item: ScenarioRunItem) -> Int? {
        let n = (attempts[item.id] ?? 0) + 1
        attempts[item.id] = n
        guard n <= MAX_FREEZE_RETRIES else { return nil }
        items.append(item)
        return n
    }
}

/// 1 シナリオの実行(サブプロセス起動+イベント変換)。
/// CLI の逐次実行と RunOrchestrator のワーカーの両方がここを通る。
public enum ScenarioOutcome: Sendable, Equatable {
    case passed, failed, frozen
}

public enum ScenarioRunner {
    /// 戻り値: 実行結果。進捗は onEvent で通知される
    public static func runOne(project: TestProject, item: ScenarioRunItem, worker: RunWorker,
                              healingEnabled: Bool, reportDir: URL,
                              defaultTimeout: Int? = nil,
                              scenarioTimeout: Int? = nil,
                              debug: ScenarioDebugOptions? = nil,
                              recorder: RunRecorder? = nil,
                              onEvent: @escaping (RunEvent) -> Void) async -> ScenarioOutcome {
        onEvent(.flowStarted(worker: worker.label, flowURL: item.url,
                             flowName: item.info.id, isDirty: false))

        // worker id 形式は ApiRunCommand.swift の workerID 変換表・workersReadyInfo と同一規則
        let recording = recorder.map {
            ScenarioRecording(recorder: $0,
                              worker: "\(worker.platform):\(worker.logicalName ?? worker.label)",
                              title: item.info.title)
        }
        var reportURL: URL?
        var frozen = false
        let passed = await ScenarioHost.run(
            project: project, scenarioID: item.info.id, connection: worker.connection,
            heal: healingEnabled, reportDir: reportDir.path,
            defaultTimeout: defaultTimeout, scenarioTimeout: scenarioTimeout,
            debug: debug, recording: recording) { event in
            switch event.kind {
            case "sceneStarted":
                onEvent(.sceneStarted(worker: worker.label, flowURL: item.url,
                                      scene: event.scene ?? 0,
                                      sceneTitle: event.sceneTitle ?? ""))
            case "step":
                onEvent(.step(worker: worker.label, flowURL: item.url,
                              result: stepResult(from: event)))
            case "sceneFinished":
                onEvent(.sceneFinished(worker: worker.label, flowURL: item.url,
                                       scene: event.scene ?? 0,
                                       sceneTitle: event.sceneTitle ?? "",
                                       passed: event.passed ?? false))
            case "paused":
                onEvent(.flowPaused(worker: worker.label, flowURL: item.url,
                                    index: event.index ?? 0,
                                    description: event.description ?? "",
                                    file: event.file, line: event.line))
            case "fixSuggestion":
                // 「💡 修正提案: …」合成 step 行(実際のコマンド結果ではない。synthetic: true の
                // 意味は StepResult.synthetic 参照)
                onEvent(.step(worker: worker.label, flowURL: item.url,
                              result: StepResult(index: event.index ?? 0,
                                                 description: "💡 修正提案: \(event.detail ?? "")",
                                                 status: .passed, synthetic: true)))
                onEvent(.fixSuggestion(worker: worker.label, flowURL: item.url,
                                       scenarioID: event.scenario ?? item.info.id,
                                       command: event.description,
                                       file: event.file, line: event.line,
                                       oldSelector: event.oldSelector,
                                       newSelector: event.newSelector,
                                       message: event.detail ?? ""))
            case "scenarioFinished":
                reportURL = event.reportPath.map { URL(fileURLWithPath: $0) }
            case "deviceFrozen":
                frozen = true
            case "log":
                if let message = event.message, !message.isEmpty {
                    onEvent(.step(worker: worker.label, flowURL: item.url,
                                  result: StepResult(index: 0, description: message,
                                                     status: .passed)))
                }
            default:
                break
            }
        }

        let outcome: ScenarioOutcome = frozen ? .frozen : (passed ? .passed : .failed)
        onEvent(.flowFinished(worker: worker.label, flowURL: item.url, passed: frozen ? false : passed,
                              triage: nil, reportURL: reportURL))
        return outcome
    }

    /// ScenarioEvent(step)→ StepResult。scene/sceneTitle/section は構造化フィールドのまま写す。
    /// passedViaFallback/healed の detail の扱いは FlowLocator.raw(Flow.swift)参照
    static func stepResult(from event: ScenarioEvent) -> StepResult {
        let status: StepResult.Status
        switch event.status {
        case "passed":
            status = .passed
        case "passedViaFallback":
            status = .passedViaFallback(FlowLocator(raw: event.detail ?? ""))
        case "healed":
            status = .healed(FlowLocator(raw: event.detail ?? ""))
        case "failed":
            status = .failed(event.detail ?? "")
        default:
            status = .skipped(event.detail ?? "")
        }
        // 時間内訳。サブプロセスの ScenarioEvent に durationMs が無ければ
        // 未計測のステップ(dry-run・スキップ等)なので timing 自体を nil のままにする
        let timing = event.durationMs.map {
            StepTiming(durationMs: $0, snapshotMs: event.snapshotMs,
                      actionMs: event.actionMs, waitMs: event.waitMs)
        }
        return StepResult(index: event.index ?? 0, description: event.description ?? "",
                          status: status, scene: event.scene, sceneTitle: event.sceneTitle,
                          section: event.section, timing: timing)
    }
}

/// runWorker() の離脱理由。.retired は「デバイス使用不能でループを抜けた」場合のみで、
/// superviseWorker の復帰トライへ渡す worker を保持する(キュー消化を再開できる)
private enum WorkerExit {
    case completed(Int)
    case retired(failed: Int, worker: RunWorker)
}

/// シナリオ群をワーカー群で並列消化する。進捗は events(AsyncStream)で配信され、
/// run() の完了時に finish する。イベントはバッファされるため消費開始が遅れても失われない。
public final class RunOrchestrator {
    public let events: AsyncStream<RunEvent>
    private let continuation: AsyncStream<RunEvent>.Continuation
    private let workers: [RunWorker]
    private let healingEnabled: Bool
    private let reportDir: URL
    private let project: TestProject
    private let defaultTimeout: Int?
    private let scenarioTimeout: Int?
    /// デバッグ実行(ブレークポイント・ステップ実行)。呼び出し側が単一シナリオ実行時のみ指定する
    private let debug: ScenarioDebugOptions?
    private let recorder: RunRecorder?
    /// Android の画面凍結(blank-screen)判定。FTCore は FTAndroid に依存できない(循環)ため
    /// 実プローブ(AndroidHealthProbe)の注入は呼び出し側(ftester ターゲット)が行う。
    /// nil(未注入)時は常に false(凍結扱いしない)
    private let isDeviceFrozen: (@Sendable (String) async -> Bool)?
    /// Android デバイスが実行中に到達不能(adb で offline/未検出=プロセス消滅・watchdog 再起動 down 等)に
    /// なったかの判定。凍結(adb 生存・画面のみ死)とは別で、こちらは adb からデバイス自体が消えた状態。
    /// isDeviceFrozen と同じ理由で呼び出し側が注入(未注入時は常に false)
    private let isDeviceUnreachable: (@Sendable (String) async -> Bool)?
    /// xcuitest ブリッジのランナーログ(.ftester/bridge-<port>.log)の現在サイズ。ログ成長=ランナー生存
    /// の傍証として bridgeUnreachable の busy/ウェッジ判別に使う。ログパスは FTBridgeClient 側の知識
    /// なので isDeviceFrozen と同じ理由で注入。取得不能・非 xcuitest は nil(判別に使わない)
    private let bridgeLogSize: (@Sendable (RunWorker) -> UInt64?)?
    /// 失敗後チェックの /status プローブ 1 回分。isDeviceFrozen と同じ理由で注入(BridgeClient は
    /// FTBridgeClient)。hybrid は主ポート(in-app)が別アプリのシナリオ中サスペンドされ
    /// 「TCP 受理・HTTP 無応答」になるため、注入側で xcuitest 側ポートを叩く(design §8.8)。
    /// 未注入時は worker.driver への素朴なプローブにフォールバック
    private let probeBridge: (@Sendable (RunWorker) async -> BridgeProbeOutcome)?
    /// run-lease(RunLease.write/remove、FTBridgeClient)のハートビート書き込み・削除。
    /// isDeviceFrozen と同じ理由(FTCore は FTBridgeClient に依存できない)で ftester ターゲットが注入。
    /// nil(未注入。テストハーネス等)時は lease 書き込みを単に skip する
    private let writeRunLease: (@Sendable (String) -> Void)?
    private let removeRunLease: (@Sendable (String) -> Void)?
    /// run 中に稼働しているワーカーのデバイスキー集合(ハートビート対象)。run() 内のバックグラウンド
    /// タスクが 5 秒毎にこの snapshot を舐めて writeRunLease を呼ぶ
    private let leaseKeys = RunLeaseKeys()
    /// ワーカー離脱(retired)時の後始末(ウェッジしたブリッジプロセスの停止等)。復帰(revive)の
    /// 有無に関係なく離脱の度に必ず呼ぶ — 復帰しない離脱(キュー空・上限到達)で kill を省くと、
    /// ウェッジしたランナーがシミュレータを掴んだまま生き残り、次回 run の新ブリッジと
    /// 2ランナー競合を起こす。isDeviceFrozen と同じ理由で呼び出し側が注入
    private let cleanupRetiredWorker: (@Sendable (RunWorker) async -> Void)?
    /// retired ワーカーの論理デバイス復帰。nil(未注入)なら復帰を試みず即ギブアップ
    /// (呼び出し側がプロファイル経由の場合のみ注入。--ports 等の非プロファイル経路では nil)
    private let reviveWorker: (@Sendable (RunWorker) async -> RunWorker?)?
    /// 遅延参加ワーカー(iOS ブリッジ供給待ち)。platforms は「後から必ず来る platform」の宣言で、
    /// これが無いと初期ワーカーに iOS が居ない時点で iOS シナリオが「担当ワーカーなし」で即失敗する。
    /// provider は供給完了時にワーカー群を返す(失敗時は空配列。キューに残った分は run 末尾の
    /// ドレインが「実行できるワーカーがありません」で失敗確定する)。
    /// Android を iOS 供給(壊れたブリッジの置き換え=数十秒)の完了待ちにしないための機構。
    private let lateWorkers: (platforms: Set<String>, provider: @Sendable () async -> [RunWorker])?
    /// 劣化・離脱したワーカーの収集(summary/レポートの degradedWorkers に載せる)。
    private let degraded = NoteCollector()
    /// 振り直し(結果取り消し+requeue)の監査記録(summary/レポートの freezeRetries に載せる)。
    private let retries = NoteCollector()

    /// ワーカー離脱を通知(イベント yield + 劣化ワーカー収集)を1箇所に集約する。
    private func reportWorkerFailed(_ label: String, _ message: String) async {
        continuation.yield(.workerFailed(worker: label, message: message))
        await degraded.add("\(label): \(message)")
    }

    public init(project: TestProject, workers: [RunWorker], healingEnabled: Bool,
                reportDir: URL, defaultTimeout: Int? = nil, scenarioTimeout: Int? = nil,
                debug: ScenarioDebugOptions? = nil, recorder: RunRecorder? = nil,
                isDeviceFrozen: (@Sendable (String) async -> Bool)? = nil,
                isDeviceUnreachable: (@Sendable (String) async -> Bool)? = nil,
                bridgeLogSize: (@Sendable (RunWorker) -> UInt64?)? = nil,
                probeBridge: (@Sendable (RunWorker) async -> BridgeProbeOutcome)? = nil,
                writeRunLease: (@Sendable (String) -> Void)? = nil,
                removeRunLease: (@Sendable (String) -> Void)? = nil,
                cleanupRetiredWorker: (@Sendable (RunWorker) async -> Void)? = nil,
                reviveWorker: (@Sendable (RunWorker) async -> RunWorker?)? = nil,
                lateWorkers: (platforms: Set<String>, provider: @Sendable () async -> [RunWorker])? = nil) {
        (self.events, self.continuation) = AsyncStream.makeStream(of: RunEvent.self)
        self.workers = workers
        self.healingEnabled = healingEnabled
        self.reportDir = reportDir
        self.project = project
        self.defaultTimeout = defaultTimeout
        self.scenarioTimeout = scenarioTimeout
        self.debug = debug
        self.recorder = recorder
        self.isDeviceFrozen = isDeviceFrozen
        self.isDeviceUnreachable = isDeviceUnreachable
        self.bridgeLogSize = bridgeLogSize
        self.probeBridge = probeBridge
        self.writeRunLease = writeRunLease
        self.removeRunLease = removeRunLease
        self.cleanupRetiredWorker = cleanupRetiredWorker
        self.reviveWorker = reviveWorker
        self.lateWorkers = lateWorkers
    }

    private func deviceUnreachable(_ serial: String) async -> Bool {
        guard let probe = isDeviceUnreachable else { return false }
        return await probe(serial)
    }

    /// 死活確認系の await に期限を切る。ウェッジしたブリッジは「接続は受けるが応答しない」ため、
    /// BridgeClient の既定タイムアウトに任せると status 確認だけで数分止まり run 全体が凍結する
    /// (実測 2026-07-18: ウェッジ機への status で run が 5 分以上アイドル固着)。
    ///
    /// **withTaskGroup は使わない**: 構造化並行はスコープ終端で全子タスクの完了を待つため、
    /// op(URLSession)がキャンセルに即応しないと cancelAll しても遅い方を待ち続けてハングする。
    /// ここは「先に終わった方で即確定・遅い方は待たない」レースにする(継続を一度だけ resume。
    /// 期限側が勝ったら op はキャンセルだけして放置=最終的に URLSession の timeout で自然消滅)。
    private func withDeadline<T: Sendable>(
        seconds: Double, _ op: @escaping @Sendable () async throws -> T
    ) async -> T? {
        let settled = DeadlineGuard()
        // 敗者を残さないため相互キャンセルする(op が先に終わったら満期スリーパーを cancel。
        // 残すと probe 毎に seconds 秒のスリーパー task が居座る=失敗プローブのホットパスで無駄)。
        let timeoutBox = DeadlineTaskBox()
        return await withCheckedContinuation { (cont: CheckedContinuation<T?, Never>) in
            let opTask = Task {
                let result = try? await op()
                if await settled.claim() {
                    timeoutBox.task?.cancel()
                    cont.resume(returning: result)
                }
            }
            timeoutBox.task = Task {
                try? await Task.sleep(nanoseconds: UInt64(max(0, seconds) * 1_000_000_000))
                if await settled.claim() {
                    opTask.cancel()
                    cont.resume(returning: nil)
                }
            }
        }
    }

    /// /status 1回分(5s 期限)。refused=ポート LISTEN なし(プロセス死亡)、silent=期限内無応答。
    /// probeBridge(注入)があればそちら(hybrid の suspend 回避で xcuitest 側ポートを叩く)。
    /// 未注入時は worker.driver に対する素朴なプローブ
    private func probeBridgeOnce(_ worker: RunWorker) async -> BridgeProbeOutcome {
        if let probeBridge { return await probeBridge(worker) }
        let result = await withDeadline(seconds: 5) { () -> BridgeProbeOutcome in
            do { _ = try await worker.driver.status(); return .ok }
            catch DriverError.bridgeConnectionRefused { return .refused }
            catch { return .silent }
        }
        return result ?? .silent
    }

    /// iOS ワーカーの失敗後チェック。「接続不能」の確定条件:
    /// - connection refused(プロセス死亡)は即確定
    /// - それ以外は観察窓(60s)内で /status を繰り返す。失敗直後は AX 飽和で健全ブリッジも
    ///   数十秒 /status に応答しない(プレフライト不採用と同じ教訓。短い期限は必ず誤検知する)
    /// - xcuitest はランナーログが AX 処理中も成長し続ける=生存の傍証(bridgeLogSize 注入)。
    ///   /status 無応答のままログが 15s 静止したらウェッジ確定(窓の残りを待たない)。
    ///   窓を使い切ってもログが成長し続けていれば busy(健全)扱いで接続不能にしない
    private func bridgeUnreachable(_ worker: RunWorker) async -> Bool {
        let deadline = Date().addingTimeInterval(BRIDGE_PROBE_OBSERVE_SECONDS)
        var lastSize = bridgeLogSize?(worker)
        let hasLogSignal = lastSize != nil  // in-app 等ホスト側ログが無い場合は窓いっぱい /status のみで判定
        var lastGrowth = Date()
        while true {
            switch await probeBridgeOnce(worker) {
            case .ok: return false
            case .refused: return true
            case .silent: break
            }
            if hasLogSignal, let size = bridgeLogSize?(worker) {
                if let prev = lastSize, size > prev { lastGrowth = Date() }
                lastSize = size
                if Date().timeIntervalSince(lastGrowth) >= BRIDGE_PROBE_LOG_SILENCE_SECONDS {
                    return true
                }
            }
            if Date() >= deadline {
                // 窓内で一度も応答なし。ログが直近まで成長していた場合のみ busy=健全側に倒す
                return !(hasLogSignal && Date().timeIntervalSince(lastGrowth) < BRIDGE_PROBE_LOG_SILENCE_SECONDS)
            }
            try? await Task.sleep(nanoseconds: 3_000_000_000)
        }
    }

    private func deviceFrozen(_ serial: String) async -> Bool {
        guard let probe = isDeviceFrozen else { return false }
        return await probe(serial)
    }

    public func run(items: [ScenarioRunItem], defaultPlatform: String) async -> RunSummary {
        let grouped = Dictionary(grouping: items) { $0.info.platform ?? defaultPlatform }
        // 遅延参加分の platform も含める(含めないと初期ワーカー不在の platform のシナリオが
        // 供給完了を待たず「担当ワーカーなし」で即失敗する)
        let workerPlatforms = Set(workers.map(\.platform)).union(lateWorkers?.platforms ?? [])
        var failed = 0

        // 担当ワーカーのない platform のシナリオは即スキップ(失敗扱い)
        for (platform, list) in grouped where !workerPlatforms.contains(platform) {
            for item in list {
                let reason = "担当ワーカーがありません(platform: \(platform))"
                continuation.yield(.flowSkipped(flowURL: item.url, reason: reason))
                recorder?.recordSkipped(scenarioID: item.info.id, title: item.info.title,
                                        platform: platform, worker: nil, reason: reason)
            }
            failed += list.count
        }

        let queues = grouped.filter { workerPlatforms.contains($0.key) }
            .mapValues { ScenarioQueue($0) }

        continuation.yield(.runStarted(total: items.count, workerLabels: workers.map(\.label)))

        // run-lease ハートビート: mtime を stalenessSeconds(15s)以内に保つため 5s 毎に再書き込み
        let heartbeat: Task<Void, Never>? = writeRunLease != nil ? Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 5_000_000_000)
                guard !Task.isCancelled, let self else { return }
                for key in await self.leaseKeys.snapshot() { self.writeRunLease?(key) }
            }
        } : nil

        failed += await withTaskGroup(of: Int.self, returning: Int.self) { group in
            for worker in workers {
                guard let queue = queues[worker.platform] else { continue }
                group.addTask { await self.superviseWorker(worker, queue: queue) }
            }
            // 遅延参加(iOS ブリッジ供給待ち)。この await の間も上で積んだ初期ワーカーの子タスクは
            // 並行実行される(group スコープ内の await は子を止めない)ため、Android は先に走り出す。
            if let late = lateWorkers {
                for worker in await late.provider() {
                    guard let queue = queues[worker.platform] else { continue }
                    group.addTask { await self.superviseWorker(worker, queue: queue) }
                }
            }
            var total = 0
            for await workerFailed in group { total += workerFailed }
            return total
        }

        heartbeat?.cancel()
        // ワーカーが自分の return 時に外し忘れた lease がないよう最終掃除(通常は runWorker 側で
        // 既に空になっているはず)
        for key in await leaseKeys.snapshot() { removeRunLease?(key) }

        // ワーカー全滅でキューに残ったシナリオは失敗扱い
        for (platform, queue) in queues {
            while let item = await queue.next() {
                let reason = "実行できるワーカーがありません"
                continuation.yield(.flowSkipped(flowURL: item.url, reason: reason))
                recorder?.recordSkipped(scenarioID: item.info.id, title: item.info.title,
                                        platform: platform, worker: nil, reason: reason)
                failed += 1
            }
        }

        let summary = RunSummary(total: items.count, failed: failed,
                                 degradedWorkers: await degraded.snapshot(),
                                 freezeRetries: await retries.snapshot())
        continuation.yield(.runFinished(passed: summary.passed, failed: summary.failed))
        continuation.finish()
        return summary
    }

    /// 使用不能デバイス(画面凍結・実行中の消失)のシナリオを結果取り消し+別デバイス再キュー。
    /// requeue できたら true、上限到達で false。reason は表示・記録用の理由(例:「画面凍結」)。
    /// discardRecord=false は「シナリオ未実行のまま振り直す」プレフライト用(まだ記録が無いので
    /// discardLast を呼ばない)。post-failure は true(失敗した記録を取り消す)。
    private func discardAndRequeue(_ item: ScenarioRunItem, worker: RunWorker,
                                   queue: ScenarioQueue, reason: String,
                                   discardRecord: Bool = true) async -> Bool {
        if discardRecord {
            recorder?.discardLast(scenarioID: item.info.id)
        }
        if let attempt = await queue.requeue(item) {
            await retries.add("\(item.info.id): \(reason)(\(worker.label) から振り直し \(attempt)/\(MAX_FREEZE_RETRIES))")
            continuation.yield(.flowRequeued(worker: worker.label, flowURL: item.url,
                                             reason: reason, attempt: attempt,
                                             limit: MAX_FREEZE_RETRIES))
            return true
        }
        await retries.add("\(item.info.id): \(reason)(\(worker.label)、上限到達で失敗確定)")
        recorder?.recordSkipped(scenarioID: item.info.id, title: item.info.title,
            platform: worker.platform, worker: worker.label,
            reason: "\(reason)が解消せず再実行上限に到達しました")
        continuation.yield(.flowSkipped(flowURL: item.url,
            reason: "\(reason)が解消せず再実行上限に到達しました"))
        return false
    }

    /// retired ワーカーを reviveWorker で復帰させ、同じ queue の消化を継続する。
    /// runWorker が .completed を返すまで(または復帰を諦めるまで)ループする。
    private func superviseWorker(_ worker: RunWorker, queue: ScenarioQueue) async -> Int {
        var current = worker
        var totalFailed = 0
        var revives = 0
        while true {
            switch await runWorker(current, queue: queue) {
            case .completed(let f):
                return totalFailed + f
            case .retired(let f, let retired):
                totalFailed += f
                // ウェッジしたブリッジプロセスの停止は復帰の有無に関係なく必ず行う(プロパティ宣言の
                // コメント参照)。復帰する場合も、供給前に旧プロセスを止めておく方が安全
                await cleanupRetiredWorker?(retired)
                // queue が空/復帰未注入/復帰回数上限 のいずれかならこれ以上粘っても無駄なので諦める
                guard revives < MAX_WORKER_REVIVES, await queue.hasItems(), let revive = reviveWorker else {
                    return totalFailed
                }
                continuation.yield(.workerLog(worker: retired.label,
                    message: "🔧 ワーカー復帰を試みます(\(revives + 1)/\(MAX_WORKER_REVIVES)。"
                        + "ブリッジ再作成のため数十秒かかることがあります)..."))
                guard let newWorker = await revive(retired) else {
                    continuation.yield(.workerLog(worker: retired.label,
                        message: "⛔ ワーカーを復帰できませんでした"))
                    return totalFailed
                }
                revives += 1
                continuation.yield(.workerLog(worker: newWorker.label,
                    message: "✅ ワーカーが復帰しました。実行を再開します"))
                continuation.yield(.workerReady(worker: newWorker.label))
                current = newWorker
            }
        }
    }

    private func runWorker(_ worker: RunWorker, queue: ScenarioQueue) async -> WorkerExit {
        // 期限付き(ウェッジしたブリッジで 120s×N 待たないため。withDeadline 参照)。
        guard await withDeadline(seconds: 10, { try await worker.driver.status() }) != nil else {
            await reportWorkerFailed(worker.label, "接続できません(status 応答なし)")
            // leaseKey 未取得(まだ何もしていない)なので releaseLease は呼ばない。
            // 接続不能もデバイス使用不能の一種として復帰トライの対象にする(監視側の再起動待ち等)。
            return .retired(failed: 0, worker: worker)
        }
        // コールドブート直後のシミュレータは最初の AX 問い合わせが極端に遅い
        // (kAXErrorIPCTimeout でランナーが落ちる)ため、snapshot で温める(リトライ1回)
        if await withDeadline(seconds: 15, { try await worker.driver.snapshot() }) == nil {
            _ = await withDeadline(seconds: 15, { try await worker.driver.snapshot() })
        }
        continuation.yield(.workerReady(worker: worker.label))

        let leaseKey = worker.connection.serial ?? worker.connection.udid
        if let leaseKey {
            await leaseKeys.insert(leaseKey)
            writeRunLease?(leaseKey)
        }

        var failed = 0
        var consecutiveFailures = 0
        // 実行前のブリッジ疎通確認(プレフライト)は不採用(ユーザー決定 2026-07-18)。
        // 「取ってから判定」版は一過性の AX スパイクで9台一斉離脱、「取る前に2sで即断」版も
        // 負荷時の誤判定で品質が安定しなかった。ウェッジは失敗後の事後チェック
        // (bridgeUnreachable/deviceUnreachable/deviceFrozen → 振り直し)だけで拾う。
        while let item = await queue.next() {
            let outcome = await ScenarioRunner.runOne(
                project: project, item: item, worker: worker,
                healingEnabled: healingEnabled, reportDir: reportDir,
                defaultTimeout: defaultTimeout, scenarioTimeout: scenarioTimeout, debug: debug,
                recorder: recorder,
                onEvent: { [continuation] in continuation.yield($0) })
            if outcome == .passed {
                consecutiveFailures = 0
                continue
            }
            // デバイスが使用不能なら結果取り消し+別デバイス再実行+ワーカー離脱。
            // .frozen(スクショ由来の明示シグナル)は即。.failed は事後プローブで確認:
            // まず消失(adb offline/未検出。安価な adb devices 1回)、次に画面凍結(screencap プローブ)。
            // iOS はブリッジ /status の生存確認(ブリッジのウェッジ=シナリオ途中から全ステップが
            // 接続エラーになる実害があり、Android のプローブでは拾えない)。
            var unusableReason: String? = outcome == .frozen ? "画面凍結" : nil
            if unusableReason == nil, outcome == .failed, worker.platform == "android",
               let serial = worker.connection.serial {
                if await deviceUnreachable(serial) {
                    unusableReason = "デバイス消失(offline/未検出)"
                } else if await deviceFrozen(serial) {
                    unusableReason = "画面凍結"
                }
            }
            if unusableReason == nil, outcome == .failed, worker.platform == "ios",
               await bridgeUnreachable(worker) {
                unusableReason = "ブリッジ接続不能"
            }
            // サーキットブレーカ: 凍結/消失に当てはまらなくても連続失敗が閾値に達したら不調ワーカーとして離脱。
            if unusableReason == nil {
                consecutiveFailures += 1
                if consecutiveFailures >= WORKER_FAILURE_CIRCUIT_THRESHOLD {
                    unusableReason = "ワーカー連続失敗(\(consecutiveFailures)回)"
                }
            }
            if let reason = unusableReason {
                let requeued = await discardAndRequeue(item, worker: worker, queue: queue, reason: reason)
                if !requeued { failed += 1 }
                await reportWorkerFailed(worker.label, "\(reason)のため離脱しました")
                await releaseLease(leaseKey)
                return .retired(failed: failed, worker: worker)
            }
            failed += 1
        }
        await releaseLease(leaseKey)
        return .completed(failed)
    }

    private func releaseLease(_ key: String?) async {
        guard let key else { return }
        await leaseKeys.remove(key)
        removeRunLease?(key)
    }
}

/// RunEvent → 表示行の共通整形(CLI の出力と呼び出し側の実行レーン表示が共用)
public enum RunLogFormatter {
    public static func lines(for event: RunEvent) -> [String] {
        switch event {
        case .runStarted, .workerReady, .runFinished:
            return []
        case .sceneStarted, .sceneFinished:
            // 表示は flowStarted〜flowFinished 間の step 行だけで完結させる方針のため、
            // scene 区切り用の専用行は意図的に出さない(scene/sceneTitle は各 step 行の
            // 構造化フィールドとして参照できる)
            return []
        case .workerFailed(let worker, let message):
            return ["❌ ワーカー \(worker) が離脱しました: \(message)"]
        case .workerLog(let worker, let message):
            return ["ℹ️ [\(worker)] \(message)"]
        case .flowRequeued(_, _, let reason, let attempt, let limit):
            return ["  🔁 \(reason)のため別デバイスで再実行します(\(attempt)/\(limit))"]
        case .flowStarted(let worker, _, let flowName, let isDirty):
            var lines = ["▶ \(flowName) [\(worker)]"]
            if isDirty { lines.append("  ⚠️ このフローは dirty(要レビュー)状態です") }
            return lines
        case .step(_, _, let result):
            return lines(for: result)
        case .flowPaused(_, _, let index, let description, _, _):
            return ["  ⏸ \(index). \(description) の手前で一時停止中"]
        case .flowHealed:
            return ["  🔧 修復したロケータでフローを更新しました(dirty: true — 要レビュー)"]
        case .fixSuggestion:
            return []
        case .flowFinished(_, _, let passed, let triage, let reportURL):
            var lines: [String] = []
            if passed {
                lines.append("  → ✅ 成功")
            } else {
                if let triage {
                    lines.append("  → 🔍 トリアージ: [\(triage.failureClass)] \(triage.summary)")
                }
                if let reportURL {
                    lines.append("  → ❌ 失敗 — レポート: \(reportURL.path)")
                } else {
                    lines.append("  → ❌ 失敗")
                }
            }
            lines.append("")
            return lines
        case .flowSkipped(let flowURL, let reason):
            let name = flowURL.lastPathComponent.removingPercentEncoding
                ?? flowURL.lastPathComponent
            return ["⚠️ \(name) を実行できません: \(reason)", ""]
        }
    }

    public static func lines(for step: StepResult) -> [String] {
        // section("condition"/"action"/"expectation")を description 先頭に "[section] " として折り込む
        let description = (step.section.map { "[\($0)] " } ?? "") + step.description
        switch step.status {
        case .passed:
            // index 0 = ステップ以外の情報行(修正提案・ユーザー print 等)
            if step.index == 0 { return ["  \(description)"] }
            return ["  ✅ \(step.index). \(description)"]
        case .passedViaFallback(let locator), .healed(let locator):
            // 表示上は passed と同じ ✅ とし、末尾に "(detail)" を畳み込む
            return ["  ✅ \(step.index). \(description)(\(locator.summary))"]
        case .failed(let reason):
            return ["  ❌ \(step.index). \(description)", "     \(reason)"]
        case .skipped(let reason):
            return ["  ⚠️ \(step.index). \(description)(スキップ: \(reason))"]
        }
    }
}
