// RunOrchestrator.swift
// シナリオ並列実行のオーケストレーション。CLI(ftester run --ports / ftester api run)が使う。
// シナリオ実行の実体は ftester-scenarios サブプロセス(ScenarioHost)で、
// FM フックはサブプロセス側が持つ。ワーカーのドライバはウォームアップ・接続確認用。

import Foundation

/// 実行対象シナリオ。URL(scenario:// スキーム)が一意キー(呼び出し側の実行レーン管理と互換)
public struct ScenarioRunItem: Identifiable, Sendable {
    public let info: ScenarioInfo
    /// ブロードキャスト実行(`ScenarioDispatch.broadcast`)で「どのレーン(デバイス)のぶんか」。
    /// 通常の共有キューでは nil。**URL のクエリに載る**ので、同じシナリオ ID が N 台で
    /// 同時に走っても (シナリオ × デバイス) が別キーになり、URL で状態を持つ側(表示バッファ・
    /// 稼働集計・キューの再実行回数)が混線しない。`lastPathComponent` は ID のまま
    public let lane: String?
    public let url: URL
    public var id: URL { url }

    public init(info: ScenarioInfo, lane: String? = nil) {
        self.info = info
        self.lane = lane
        self.url = Self.url(for: info.id, lane: lane)
    }

    /// シナリオ ID(日本語可)→ 一意キー URL。lane があれば `?lane=<名>` を付ける
    public static func url(for scenarioID: String, lane: String? = nil) -> URL {
        let encoded = scenarioID.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed)
            ?? "scenario"
        var string = "scenario://run/\(encoded)"
        if let lane {
            // デバイス名は "(" ")" ":" "&" を含みうるので英数字以外は全部エスケープする
            string += "?lane=" + (lane.addingPercentEncoding(withAllowedCharacters: .alphanumerics) ?? "lane")
        }
        return URL(string: string) ?? URL(fileURLWithPath: "/scenario")
    }
}

/// 並列ワーカー定義。platform が一致するシナリオだけをキューから消化する
/// ワーカーを1本ずつ参加させる間隔(秒)。**0 で無効**。
///
/// なぜ要るか(2026-08-09): 各シナリオは `condition { launchApp() }` から始まるので、
/// N 台のワーカーを同時に起こすと**最初の launch が N 本同時**に走る。ブリッジ供給側は
/// 「in-app の新規起動は同時2台」に絞ってある(BridgeProvisioner)のに、その数秒後の
/// 本番の launch は無制限、という非対称だった。実測では供給が 2 台ずつ進んだ直後に
/// **10 台中 9 台が画面凍結**し、ワーカー 0 で 24/24 が実行不能になっている。
///
/// **1.5 秒の根拠は「シミュレータの launch がおおむね1〜3秒」**という観測だけで、
/// 凍結率で較正した値ではない —— 効くかどうかは**まだ確かめていない**(凍結の観測は
/// n=1 で、同じ run の別プロファイルは無事だった)。対照実験を安く回せるように
/// `FT_WORKER_STAGGER_SEC` で差し替えられるようにしてある(`0` で従来どおり一斉起動)。
///
/// **間隔だけでは足りない**(2026-08-09 ユーザー指示)。時間は当て推量で、ホストが実際に
/// 空いたことは見ていない —— 供給が長引いた run では飽和したまま次を起こす。もう一つの門
/// (**直近の CPU 使用率が上限未満**)は `WorkerStartGate` にある。`seconds` を 0 にしても
/// CPU の門は残る(こちらを外すのは `FT_WORKER_START_CPU_MAX` ではなく、上限を 100% に
/// 保ったまま「飽和していなければ通る」既定に任せる)。
///
/// **定常のレーン数は変えない**ので、伸びるのは立ち上がりだけ(10 台なら約 13.5 秒)
public enum WorkerStagger {
    public static let defaultSeconds = 1.5

    /// **最初に同時起動してよい台数**(2026-08-09 のユーザー決定)。ここを超えた分から
    /// 1本ずつ間隔を空ける —— つまり 1本目と2本目は同時、3本目以降が待つ。
    /// **2 は BridgeProvisioner の「in-app の新規起動は同時2台」と同じ値**で、
    /// 供給と本番の launch で違う上限を持たないために揃えてある。
    /// 10 台なら待つのは 8 本ぶん(既定 1.5s なら約 12 秒)
    public static let simultaneousHead = 2

    public static var seconds: Double {
        guard let raw = ProcessInfo.processInfo.environment["FT_WORKER_STAGGER_SEC"] else {
            return defaultSeconds
        }
        // 不正値は既定へ倒す(黙って 0 = 無効にすると、実験のつもりが対策を外した run になる)
        guard let value = Double(raw), value >= 0, value.isFinite else { return defaultSeconds }
        return value
    }
}

public struct RunWorker {
    /// 表示・イベント上の識別子。形式は2系統ある:
    ///   プロファイル経路 = `makeLabel` の "<デバイス名>(<platform>:<serial|port>)"
    ///   非プロファイル経路(--port/--serial)= "ios:<port>" / "android"
    /// **RunEvent は platform を運ばない**ので、label から platform を戻す必要がある側は
    /// 必ず `RunWorker.platform(fromLabel:)` を使うこと(デバイス名自体が "(" や ":" を含むため、
    /// 素朴な split は壊れる。実際に稼働率集計がデバイス名を platform と誤認した)
    public let label: String
    public let platform: String           // "ios" / "android"
    public let driver: AppDriver          // ウォームアップ・接続確認用
    public let connection: DriverConnection  // サブプロセスへ渡す接続情報
    /// 実行プロファイル上のデバイス論理名(profiles/machines/ の name)。
    /// ProfileWorkerFactory 経由で構築されたワーカーのみ設定される(ftester api run の
    /// workersReady イベントの id 構築に使う。--ports 等の非プロファイル経路では nil)
    public let logicalName: String?

    /// 既知の platform 名。label から platform を戻すときの照合に使う。
    public static let knownPlatforms: Set<String> = ["ios", "android"]

    /// プロファイル経路の label を組み立てる(解析側の `platform(fromLabel:)` と対。片方だけ変えない)。
    public static func makeLabel(deviceName: String, platform: String, id: String) -> String {
        "\(deviceName)(\(platform):\(id))"
    }

    /// label から platform を戻す。デバイス名が "(" や ":" を含みうるため、
    /// 末尾の "(<platform>:<id>)" を優先して見る。既知の platform 名に一致しない場合は nil。
    public static func platform(fromLabel label: String) -> String? {
        func head(_ text: Substring) -> String {
            String(text.split(separator: ":", maxSplits: 1).first ?? text)
        }
        // プロファイル経路: 末尾の括弧群 "(<platform>:<id>)"
        if label.hasSuffix(")"), let open = label.lastIndex(of: "(") {
            let inner = label[label.index(after: open)..<label.index(before: label.endIndex)]
            let candidate = head(inner)
            if knownPlatforms.contains(candidate) { return candidate }
        }
        // 非プロファイル経路: "ios:<port>" / "android"
        let candidate = head(label[...])
        return knownPlatforms.contains(candidate) ? candidate : nil
    }

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
    /// fm: シナリオの FM 呼び出し実測。並列実行では親が scenarioFinished を**再構築**して
    /// stdout へ出すため、ここで運ばないと拡張(モニターの FM グラフ)まで届かない
    /// (結果 JSON は ScenarioHost 内の builder が別経路で受けるので落ちない)
    case flowFinished(worker: String, flowURL: URL, passed: Bool,
                      triage: TriageInfo?, reportURL: URL?, fm: FMUsageRecord?)
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
    /// run 前の blank 判定で sleep/wake 修復により除外を免れたワーカー label(orchestrator は
    /// 関与しない=呼び出し側がワーカー構築時の triage を summary に載せ替える)。
    public let blankRepairs: [String]
    /// run 前の blank 判定で修復不発により除外したワーカー label(同上)。
    public let blankExclusions: [String]
    /// この run の所要時間を性能計測に使ってよいか(`MeasurementValidity.verdict` の結果)。
    /// orchestrator 自身は performanceMode を知らないため常に false/[] を返す —— 呼び手
    /// (ProfileRunner/ApiRunCommand)が blankExclusions 判明後に自分で構築した RunSummary へ埋める。
    public let measurementInvalid: Bool
    public let measurementInvalidReasons: [String]
    /// **FM の実呼び出しが全滅したまま走ったシナリオ数**(呼び出しが1件でもあり、その全部が失敗)。
    /// FM が死んでいると occlusion-guard(`exist` の既定 requireVisible)・自己修復・`screenLooksLike` が
    /// **黙って素通り**する = その run の緑は「守りが効いた緑」ではない。
    /// **合否は変えない**(FM と無関係な失敗を隠す方が危険)。読み手に劣化を伝えるためだけの数。
    /// 各シナリオの警告は子プロセスの stderr にも出るが、**run のまとめには出ていなかった**ので、
    /// 赤を見るたびに「自分の変更か FM か」を人が切り分ける羽目になっていた(2026-08-20)
    public let fmUnavailableScenarios: Int
    /// degradedWorkers / freezeRetries と**同じ事実の構造化版**(run.json の workerAnomalies)。
    /// 表示は prose 側、機械的な除外はこちら(片方だけ足さない)
    public let workerAnomalies: [WorkerAnomalyRecord]

    public init(total: Int, failed: Int, degradedWorkers: [String] = [],
                freezeRetries: [String] = [],
                blankRepairs: [String] = [], blankExclusions: [String] = [],
                measurementInvalid: Bool = false, measurementInvalidReasons: [String] = [],
                fmUnavailableScenarios: Int = 0,
                workerAnomalies: [WorkerAnomalyRecord] = []) {
        self.total = total
        self.failed = failed
        self.degradedWorkers = degradedWorkers
        self.freezeRetries = freezeRetries
        self.blankRepairs = blankRepairs
        self.blankExclusions = blankExclusions
        self.measurementInvalid = measurementInvalid
        self.measurementInvalidReasons = measurementInvalidReasons
        self.fmUnavailableScenarios = fmUnavailableScenarios
        self.workerAnomalies = workerAnomalies
    }

    /// FM の呼び出しが**全部失敗した**か(呼び出しが1件も無いときは false = 使っていないだけ)
    public static func fmUnavailable(_ usage: FMUsageRecord?) -> Bool {
        guard let usage, usage.calls > 0 else { return false }
        return usage.failures == usage.calls
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

/// withDeadline の満期スリーパー task 参照を保持する箱(op 勝利時に cancel するための前方参照用)。
/// **代入(生成側)と参照(opTask 側)は並行に走る**: `Task { }` の本体は囲みの同期区間と
/// 並行に開始し得るので「代入は op の初回 await より前に完了する」は成り立たない
/// (ThreadSanitizer が実測で競合を報告。2026-07-30)。素の `var` だと競合そのものに加え、
/// **代入前に op が勝つと cancel を取りこぼしスリーパーが seconds 秒居座る**
/// (この箱を置いた目的が消える)ため、**先に来た cancel を覚えて後から来た task に適用する**。
/// `@unchecked Sendable` の根拠は lock(素の可変参照ではない)。
/// 同型の RecordingSupport.raceWithDeadline は前方参照を持たない = この箱が要らない
final class DeadlineTaskBox: @unchecked Sendable {
    private let lock = NSLock()
    private var task: Task<Void, Never>?
    private var cancelRequested = false

    /// 生成側から1回だけ渡す。既に cancel 済みならその場で cancel する
    func hold(_ task: Task<Void, Never>) {
        lock.lock()
        let cancelNow = cancelRequested
        self.task = task
        lock.unlock()
        // cancel はロックの外で呼ぶ(並行ランタイムへの呼び出しをロック下に置かない)
        if cancelNow { task.cancel() }
    }

    /// op 勝利側から呼ぶ。task 未設定でも記憶しておき hold 時に適用する
    func cancel() {
        lock.lock()
        cancelRequested = true
        let task = self.task
        lock.unlock()
        task?.cancel()
    }
}

/// 並列ワーカーからの文字列記録の収集(劣化ワーカー・振り直し監査)。run() が summary に畳む。
private actor NoteCollector {
    private var entries: [String] = []
    func add(_ entry: String) { entries.append(entry) }
    func snapshot() -> [String] { entries }
}

private actor AnomalyCollector {
    private var entries: [WorkerAnomalyRecord] = []
    func add(_ entry: WorkerAnomalyRecord) { entries.append(entry) }
    func snapshot() -> [WorkerAnomalyRecord] { entries }
}

/// 並列ワーカーから数える用の素朴なカウンタ
private actor Counter {
    private var value = 0
    func increment() { value += 1 }
    func snapshot() -> Int { value }
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
    /// **デバイス側の一過性の故障**でテストが落ちた(コードの失敗ではない)。振り直す
    case environmentFault
}

/// 「テストではなくデバイスが壊れていた」と機械的に言い切れる失敗のしるし。
/// **ここに足すのは、アサーション失敗と構造的に区別できるものだけ** ——
/// ドライバが返した基盤側のエラーで、同じコードを別デバイスや少し後に走らせれば通るもの。
/// 判定を広げると本物の失敗を skipped に隠すことになる
enum EnvironmentFault {
    /// XCUITest の a11y 基盤が一時的に応答しない。**ブリッジ供給直後・アプリ入れ替え直後**に
    /// 同時刻クラスタで出て、再実行で必ず消える(2026-08-05/06 に2回・8件と6件を手で判定した)。
    /// docs/verification.md「kAXErrorAPIDisabled は環境と判定してよい」
    static let markers = ["kAXErrorAPIDisabled"]

    static func matches(_ detail: String?) -> Bool {
        guard let detail else { return false }
        return markers.contains { detail.contains($0) }
    }
}

public enum ScenarioRunner {
    /// 戻り値: 実行結果。進捗は onEvent で通知される
    public static func runOne(project: TestProject, item: ScenarioRunItem, worker: RunWorker,
                              fm: FMConfig, reportDir: URL,
                              defaultTimeout: Double? = nil,
                              containerInference: Bool = true,
                              scenarioTimeout: Int? = nil,
                              debug: ScenarioDebugOptions? = nil,
                              recorder: RunRecorder? = nil,
                              installHandler: (@Sendable (RunWorker, String?) async
                                               -> (ok: Bool, message: String))? = nil,
                              appName: String? = nil,
                              appBundleID: String? = nil,
                              onEvent: @escaping (RunEvent) -> Void) async -> ScenarioOutcome {
        onEvent(.flowStarted(worker: worker.label, flowURL: item.url,
                             flowName: item.info.id, isDirty: false))

        // worker id 形式は ApiRunCommand.swift の workerID 変換表・workersReadyInfo と同一規則
        let recording = recorder.map {
            ScenarioRecording(recorder: $0, worker: Self.recordingWorker(worker),
                              title: item.info.title)
        }
        var reportURL: URL?
        var fmUsage: FMUsageRecord?
        var frozen = false
        var environmentFault = false
        let passed = await ScenarioHost.run(
            project: project, scenarioID: item.info.id, connection: worker.connection,
            fm: fm, reportDir: reportDir.path,
            defaultTimeout: defaultTimeout, containerInference: containerInference,
            scenarioTimeout: scenarioTimeout,
            debug: debug, recording: recording,
            installHandler: installHandler.map { handler in
                { (path: String?) async -> (ok: Bool, message: String) in await handler(worker, path) }
            },
            appName: appName, appBundleID: appBundleID) { event in
            switch event.kind {
            case "sceneStarted":
                onEvent(.sceneStarted(worker: worker.label, flowURL: item.url,
                                      scene: event.scene ?? 0,
                                      sceneTitle: event.sceneTitle ?? ""))
            case "step":
                // **デバイス基盤の一過性エラーは「テストの失敗」として数えない**(振り直す)
                if event.status == "failed", EnvironmentFault.matches(event.detail) {
                    environmentFault = true
                }
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
                                                 description: "💡 Suggested fix: \(event.detail ?? "")",
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
                fmUsage = event.fm
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

        let outcome = Self.outcome(passed: passed, frozen: frozen,
                                   environmentFault: environmentFault)
        onEvent(.flowFinished(worker: worker.label, flowURL: item.url, passed: frozen ? false : passed,
                              triage: nil, reportURL: reportURL, fm: fmUsage))
        return outcome
    }

    /// 結果 JSON(`ScenarioRunRecord.worker`)に載る書き手の名。**`RunRecorder.discardLast(worker:)` に
    /// 渡すのもこれ**(同じ文字列でないと、取り消しが別のデバイスの記録を消す)
    public static func recordingWorker(_ worker: RunWorker) -> String {
        "\(worker.platform):\(worker.logicalName ?? worker.label)"
    }

    /// 実行結果の確定(純粋関数)。**優先順位に意味がある**: 画面凍結 > 環境の一過性エラー >
    /// テストの合否。凍結はワーカーごと使えないので先に判定し、環境エラーは合格を上書きしない
    /// (途中のステップが環境エラーでも、最終的に通ったならテストとしては合格)
    static func outcome(passed: Bool, frozen: Bool, environmentFault: Bool) -> ScenarioOutcome {
        if frozen { return .frozen }
        if passed { return .passed }
        return environmentFault ? .environmentFault : .failed
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
        case "inconclusive":
            status = .inconclusive(event.detail ?? "")
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
                          section: event.section, timing: timing, at: event.at)
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
    private let fm: FMConfig
    private let reportDir: URL
    private let project: TestProject
    private let defaultTimeout: Double?
    private let containerInference: Bool
    private let scenarioTimeout: Int?
    /// デバッグ実行(ブレークポイント・ステップ実行)。呼び出し側が単一シナリオ実行時のみ指定する
    private let debug: ScenarioDebugOptions?
    private let recorder: RunRecorder?
    /// run profile の record:true 時のワーカー動画録画(nil = 無効)。VideoRecordingCoordinator.swift
    private let videoRecording: VideoRecordingCoordinator?
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
    /// 録画中 lease(RecordingLease.write/remove、FTBridgeClient)のハートビート書き込み・削除。
    /// writeRunLease と同じ理由(FTCore は FTBridgeClient に依存できない)で ftester ターゲットが注入。
    /// videoRecording?.start(_:) が true(録画プロセスの起動に成功)を返したキーだけ書く
    private let writeRecordingLease: (@Sendable (String) -> Void)?
    private let removeRecordingLease: (@Sendable (String) -> Void)?
    /// 録画がアクティブなワーカーのデバイスキー集合(ハートビート対象)。leaseKeys と同じ
    /// RunLeaseKeys(汎用の Set<String> アクター)を録画用に再利用する
    private let recordingLeaseKeys = RunLeaseKeys()
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
    /// installApp() の親実行ハンドラ(RPC)。nil なら子は --host-install 無しで起動し、
    /// フォールバック(--app-path・明示引数・明示エラー)に委ねる(ScenarioHost.run 参照)。
    /// 呼び出し側(ftester ターゲット)が InstallHandlerFactory 経由で注入する
    private let installHandler: (@Sendable (RunWorker, String?) async -> (ok: Bool, message: String))?
    /// アプリの表示名(プロファイルの appName)。tapAppIcon() の引数省略時の既定として子へ渡す
    private let appName: String?
    /// 実行プロファイルが解決した bundle ID。**platform 別**(appName と違い ios/android で
    /// 別の ID になりうるので単一値にできない)。`@TestClass(app:)` 未指定シナリオの既定アプリ
    private let appBundleIDs: [String: String]
    /// 劣化・離脱したワーカーの収集(summary/レポートの degradedWorkers に載せる)。
    private let degraded = NoteCollector()
    /// 振り直し(結果取り消し+requeue)の監査記録(summary/レポートの freezeRetries に載せる)。
    private let retries = NoteCollector()
    /// 上2つと**同じ事象**の構造化版(run.json の workerAnomalies)。prose と別に持つのではなく
    /// 同じ場所で同時に足す —— 片方だけ足すと「表示には出るが機械可読には無い」に戻る
    private let anomalies = AnomalyCollector()
    /// FM の実呼び出しが全滅したまま走ったシナリオ数(summary の fmUnavailableScenarios)。
    /// **合否には使わない** —— 読み手に「この緑は守りが効いていない」と伝えるための数
    private let fmUnavailable = Counter()

    /// ワーカー離脱を通知(イベント yield + 劣化ワーカー収集)を1箇所に集約する。
    private func reportWorkerFailed(_ worker: RunWorker, _ message: String) async {
        continuation.yield(.workerFailed(worker: worker.label, message: message))
        await degraded.add("\(worker.label): \(message)")
        await anomalies.add(WorkerAnomalyRecord(
            kind: "degraded", worker: Self.workerID(worker), label: worker.label, reason: message))
    }

    /// シナリオ記録(ScenarioRunRecord.worker)と join できる形。論理名が無い経路では nil
    static func workerID(_ worker: RunWorker) -> String? {
        worker.logicalName.map { "\(worker.platform):\($0)" }
    }

    public init(project: TestProject, workers: [RunWorker], fm: FMConfig,
                reportDir: URL, defaultTimeout: Double? = nil, containerInference: Bool = true,
                scenarioTimeout: Int? = nil,
                debug: ScenarioDebugOptions? = nil, recorder: RunRecorder? = nil,
                recordingConfig: VideoRecordingConfig? = nil,
                isDeviceFrozen: (@Sendable (String) async -> Bool)? = nil,
                isDeviceUnreachable: (@Sendable (String) async -> Bool)? = nil,
                bridgeLogSize: (@Sendable (RunWorker) -> UInt64?)? = nil,
                probeBridge: (@Sendable (RunWorker) async -> BridgeProbeOutcome)? = nil,
                writeRunLease: (@Sendable (String) -> Void)? = nil,
                removeRunLease: (@Sendable (String) -> Void)? = nil,
                writeRecordingLease: (@Sendable (String) -> Void)? = nil,
                removeRecordingLease: (@Sendable (String) -> Void)? = nil,
                cleanupRetiredWorker: (@Sendable (RunWorker) async -> Void)? = nil,
                reviveWorker: (@Sendable (RunWorker) async -> RunWorker?)? = nil,
                lateWorkers: (platforms: Set<String>, provider: @Sendable () async -> [RunWorker])? = nil,
                installHandler: (@Sendable (RunWorker, String?) async
                                  -> (ok: Bool, message: String))? = nil,
                appName: String? = nil,
                appBundleIDs: [String: String] = [:]) {
        (self.events, self.continuation) = AsyncStream.makeStream(of: RunEvent.self)
        self.workers = workers
        self.fm = fm
        self.reportDir = reportDir
        self.project = project
        self.defaultTimeout = defaultTimeout
        self.containerInference = containerInference
        self.scenarioTimeout = scenarioTimeout
        self.debug = debug
        self.recorder = recorder
        self.videoRecording = recordingConfig.map { VideoRecordingCoordinator(config: $0) }
        self.isDeviceFrozen = isDeviceFrozen
        self.isDeviceUnreachable = isDeviceUnreachable
        self.bridgeLogSize = bridgeLogSize
        self.probeBridge = probeBridge
        self.writeRunLease = writeRunLease
        self.removeRunLease = removeRunLease
        self.writeRecordingLease = writeRecordingLease
        self.removeRecordingLease = removeRecordingLease
        self.cleanupRetiredWorker = cleanupRetiredWorker
        self.reviveWorker = reviveWorker
        self.lateWorkers = lateWorkers
        self.installHandler = installHandler
        self.appName = appName
        self.appBundleIDs = appBundleIDs
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
                    timeoutBox.cancel()
                    cont.resume(returning: result)
                }
            }
            timeoutBox.hold(Task {
                try? await Task.sleep(nanoseconds: UInt64(max(0, seconds) * 1_000_000_000))
                if await settled.claim() {
                    opTask.cancel()
                    cont.resume(returning: nil)
                }
            })
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

    /// - dispatch: `.shared`(既定。platform 別の共有キュー)/ `.broadcast`(レーン別キュー。
    ///   `ftester run --each-device`)。**違うのはキューの切り方と、ワーカーがどのキューを
    ///   取るかだけ** —— スタッガ・CPU 門・復帰・lease・録画・ドレインは同じ経路を通る
    public func run(items: [ScenarioRunItem], defaultPlatform: String,
                    dispatch: ScenarioDispatch = .shared) async -> RunSummary {
        var failed = 0
        /// キューの key(shared = platform / broadcast = レーン key)。ワーカーがどれを取るかは queueKey
        let queues: [String: ScenarioQueue]
        let total: Int
        let queueKey: @Sendable (RunWorker) -> String
        /// ドレイン(残ったまま終わった item)の記録に載せる (platform, worker, 理由)
        let drainInfo: (String, Bool) -> (platform: String, worker: String?, reason: String)
        switch dispatch {
        case .shared:
            let grouped = Dictionary(grouping: items) { $0.info.platform ?? defaultPlatform }
            // 遅延参加分の platform も含める(含めないと初期ワーカー不在の platform のシナリオが
            // 供給完了を待たず「担当ワーカーなし」で即失敗する)
            let workerPlatforms = Set(workers.map(\.platform)).union(lateWorkers?.platforms ?? [])

            // 担当ワーカーのない platform のシナリオは即スキップ(失敗扱い)
            for (platform, list) in grouped where !workerPlatforms.contains(platform) {
                for item in list {
                    let reason = "no worker available (platform: \(platform))"
                    continuation.yield(.flowSkipped(flowURL: item.url, reason: reason))
                    recorder?.recordSkipped(scenarioID: item.info.id, title: item.info.title,
                                            platform: platform, worker: nil, reason: reason)
                }
                failed += list.count
            }
            queues = grouped.filter { workerPlatforms.contains($0.key) }
                .mapValues { ScenarioQueue($0) }
            total = items.count
            queueKey = { $0.platform }
            drainInfo = { platform, _ in (platform, nil, "no usable workers") }
        case .broadcast(let lanes):
            let plan = BroadcastPlan.make(items: items, lanes: lanes)
            for item in plan.unassigned {
                let platform = item.info.platform ?? defaultPlatform
                let reason = "no device available (platform: \(platform))"
                continuation.yield(.flowSkipped(flowURL: item.url, reason: reason))
                recorder?.recordSkipped(scenarioID: item.info.id, title: item.info.title,
                                        platform: platform, worker: nil, reason: reason)
                failed += 1
            }
            queues = plan.queues.mapValues { ScenarioQueue($0) }
            total = plan.total
            queueKey = { BroadcastPlan.laneKey(of: $0) }
            let lanePlatform = Dictionary(lanes.map { ($0.key, $0.platform) },
                                          uniquingKeysWith: { first, _ in first })
            drainInfo = { key, joined in
                let platform = lanePlatform[key] ?? "?"
                // 台ごとの事実だけ言う(never joined = 供給・triage で落ちて1度も参加しなかった /
                // joined = 参加したが離脱し、復帰できないまま自分のぶんが残った)
                return (platform, "\(platform):\(key)",
                        joined ? "device \(key) dropped out and could not be revived"
                               : "device \(key) never joined the run")
            }
        }
        /// broadcast のドレイン文言用(参加したレーンの key)。shared では使わない
        let joinedKeys = RunLeaseKeys()

        continuation.yield(.runStarted(total: total, workerLabels: workers.map(\.label)))

        // run-lease/recording-lease ハートビート: mtime を stalenessSeconds(15s)以内に保つため
        // 5s 毎に再書き込み。録画は videoRecording?.start(_:) が成功した時だけ recordingLeaseKeys に
        // 積まれる(record:false の run では何も積まれず writeRecordingLease も呼ばれない)
        let heartbeat: Task<Void, Never>? = (writeRunLease != nil || writeRecordingLease != nil)
            ? Task { [weak self] in
                while !Task.isCancelled {
                    try? await Task.sleep(nanoseconds: 5_000_000_000)
                    guard !Task.isCancelled, let self else { return }
                    for key in await self.leaseKeys.snapshot() { self.writeRunLease?(key) }
                    for key in await self.recordingLeaseKeys.snapshot() { self.writeRecordingLease?(key) }
                }
            } : nil

        failed += await withTaskGroup(of: Int.self, returning: Int.self) { group in
            // **ワーカーは一斉に起こさない**(2026-08-09)。各シナリオは `condition { launchApp() }`
            // から始まるので、N 本のワーカーを同時に積むと**最初の launch が N 本同時**に走る。
            // ブリッジ供給側は「in-app の新規起動は同時2台」に絞ってあるのに、その数秒後の
            // 本番の launch は無制限、という非対称だった(実測: 供給は 2 台ずつ進んでいたのに
            // 直後に 9/10 台が画面凍結)。**定常のレーン数は変えない**ので、遅くなるのは
            // 立ち上がりだけ(**先頭 2 本は同時**・3 本目から間隔と CPU の門を通る)。
            // 判定は WorkerStartGate に置いてある(間隔だけでは「本当に空いたか」を見ていないため、
            // **直近の CPU 使用率が上限未満**であることも要求する)。
            // ここで await しても**既に積んだ子タスクは止まらない**(下の遅延参加のコメントと同じ)
            let cpuSampler = CPUSampler(logFailure: { _ in })
            // CPUSampler は**初回だけ必ず nil**(前回サンプルが無く差分が取れない)。ここで
            // 1回捨てておくと、3本目が門に来た時点で既に有効な値が返る
            _ = cpuSampler.sample()
            let startGate = WorkerStartGate(
                sampleCPU: { cpuSampler.sample() },
                sleep: { try? await Task.sleep(for: .seconds($0)) })
            func admit(_ worker: RunWorker, _ queue: ScenarioQueue) async {
                await startGate.waitForTurn(log: { [continuation] message in
                    continuation.yield(.workerLog(worker: worker.label, message: message))
                })
                group.addTask { await self.superviseWorker(worker, queue: queue) }
            }
            // キューが無いワーカー(shared: その platform のシナリオが無い / broadcast: レーンの
            // ぶんが 0 本、または計画に無い台)は参加させない
            for worker in workers {
                guard let queue = queues[queueKey(worker)] else { continue }
                await joinedKeys.insert(queueKey(worker))
                await admit(worker, queue)
            }
            // 遅延参加(iOS ブリッジ供給待ち)。この await の間も上で積んだ初期ワーカーの子タスクは
            // 並行実行される(group スコープ内の await は子を止めない)ため、Android は先に走り出す。
            if let late = lateWorkers {
                for worker in await late.provider() {
                    guard let queue = queues[queueKey(worker)] else { continue }
                    await joinedKeys.insert(queueKey(worker))
                    await admit(worker, queue)
                }
            }
            var failedAcrossWorkers = 0
            for await workerFailed in group { failedAcrossWorkers += workerFailed }
            return failedAcrossWorkers
        }

        heartbeat?.cancel()
        // ワーカーが自分の return 時に外し忘れた lease がないよう最終掃除(通常は runWorker 側で
        // 既に空になっているはず)
        for key in await leaseKeys.snapshot() { removeRunLease?(key) }
        for key in await recordingLeaseKeys.snapshot() { removeRecordingLease?(key) }
        // 全ワーカー終了後に 1 回だけ index.json を書く(拡張側との契約。RecordingIndexIO 参照)
        await videoRecording?.finish()

        // ワーカー全滅(broadcast: そのレーンの台が不在・復帰不能)でキューに残ったシナリオは失敗扱い
        let joined = await joinedKeys.snapshot()
        for (key, queue) in queues {
            let drain = drainInfo(key, joined.contains(key))
            while let item = await queue.next() {
                continuation.yield(.flowSkipped(flowURL: item.url, reason: drain.reason))
                recorder?.recordSkipped(scenarioID: item.info.id, title: item.info.title,
                                        platform: drain.platform, worker: drain.worker,
                                        reason: drain.reason)
                failed += 1
            }
        }

        let summary = RunSummary(total: total, failed: failed,
                                 degradedWorkers: await degraded.snapshot(),
                                 freezeRetries: await retries.snapshot(),
                                 fmUnavailableScenarios: await fmUnavailable.snapshot(),
                                 workerAnomalies: await anomalies.snapshot())
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
            // **worker を名指しして消す** —— broadcast では同じ ID を別の台が同時に書いている
            recorder?.discardLast(scenarioID: item.info.id,
                                  worker: ScenarioRunner.recordingWorker(worker))
        }
        if let attempt = await queue.requeue(item) {
            await retries.add("\(item.info.id): \(reason) (requeued from \(worker.label), \(attempt)/\(MAX_FREEZE_RETRIES))")
            await anomalies.add(WorkerAnomalyRecord(
                kind: "requeued", worker: Self.workerID(worker), label: worker.label,
                scenarioID: item.info.id,
                reason: "\(reason) (attempt \(attempt)/\(MAX_FREEZE_RETRIES))"))
            continuation.yield(.flowRequeued(worker: worker.label, flowURL: item.url,
                                             reason: reason, attempt: attempt,
                                             limit: MAX_FREEZE_RETRIES))
            return true
        }
        await retries.add("\(item.info.id): \(reason) (\(worker.label); retry limit reached, recorded as failed)")
        await anomalies.add(WorkerAnomalyRecord(
            kind: "retryLimit", worker: Self.workerID(worker), label: worker.label,
            scenarioID: item.info.id, reason: "\(reason); retry limit reached, recorded as failed"))
        recorder?.recordSkipped(scenarioID: item.info.id, title: item.info.title,
            platform: worker.platform, worker: worker.label,
            reason: "\(reason) did not clear and the retry limit was reached")
        continuation.yield(.flowSkipped(flowURL: item.url,
            reason: "\(reason) did not clear and the retry limit was reached"))
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
                    message: "🔧 Trying to revive the worker (\(revives + 1)/\(MAX_WORKER_REVIVES); "
                        + "recreating the bridge can take tens of seconds)..."))
                guard let newWorker = await revive(retired) else {
                    continuation.yield(.workerLog(worker: retired.label,
                        message: "⛔ Could not revive the worker"))
                    return totalFailed
                }
                revives += 1
                continuation.yield(.workerLog(worker: newWorker.label,
                    message: "✅ Worker revived — resuming the run"))
                continuation.yield(.workerReady(worker: newWorker.label))
                current = newWorker
            }
        }
    }

    private func runWorker(_ worker: RunWorker, queue: ScenarioQueue) async -> WorkerExit {
        // 期限付き(ウェッジしたブリッジで 120s×N 待たないため。withDeadline 参照)。
        guard await withDeadline(seconds: 10, { try await worker.driver.status() }) != nil else {
            await reportWorkerFailed(worker, "cannot connect (no response to status)")
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

        // 録画プロセスの起動に成功したときだけ RecordingLease を書く(record:false・adb/udid 不明・
        // プロセス spawn 失敗はいずれも false を返し、lease は書かれない)
        if await videoRecording?.start(worker) == true, let leaseKey {
            await recordingLeaseKeys.insert(leaseKey)
            writeRecordingLease?(leaseKey)
        }

        var failed = 0
        var consecutiveFailures = 0
        // 実行前のブリッジ疎通確認(プレフライト)は不採用(ユーザー決定 2026-07-18)。
        // 「取ってから判定」版は一過性の AX スパイクで9台一斉離脱、「取る前に2sで即断」版も
        // 負荷時の誤判定で品質が安定しなかった。ウェッジは失敗後の事後チェック
        // (bridgeUnreachable/deviceUnreachable/deviceFrozen → 振り直し)だけで拾う。
        while let item = await queue.next() {
            // 動画のシナリオ毎クリップ切り出し用の壁時計区間通知(録画無効時は no-op)。
            // ワーカーの録画プロセス自体は起動しっぱなしで、ここでは区間だけ記録する
            await videoRecording?.scenarioStarted(
                workerLabel: worker.label, scenarioID: item.info.id, at: Date())
            let outcome = await ScenarioRunner.runOne(
                project: project, item: item, worker: worker,
                fm: fm, reportDir: reportDir,
                defaultTimeout: defaultTimeout, containerInference: containerInference,
                scenarioTimeout: scenarioTimeout, debug: debug,
                recorder: recorder, installHandler: installHandler, appName: appName,
                appBundleID: appBundleIDs[worker.platform],
                onEvent: { [continuation, fmCounter = self.fmUnavailable] event in
                    // **FM 全滅のまま走ったシナリオを数える**(合否は変えない。summary の
                    // fmUnavailableScenarios。ここで数えるのは、実行結果に FM の可否が
                    // 現れないため —— 失敗は各呼び出し箇所が握って素通りさせる契約)
                    if case .flowFinished(_, _, _, _, _, let fm) = event,
                       RunSummary.fmUnavailable(fm) {
                        Task { await fmCounter.increment() }
                    }
                    continuation.yield(event)
                })
            await videoRecording?.scenarioFinished(
                workerLabel: worker.label, at: Date(), passed: outcome == .passed)
            if outcome == .passed {
                consecutiveFailures = 0
                continue
            }
            // **デバイス基盤の一過性エラー**(kAXErrorAPIDisabled 等)は結果を捨てて振り直す。
            // **ワーカーは離脱させない** —— 個体は健全で、ブリッジを作り直しても同じ確率で踏む
            // (実測でも再実行で必ず消えた)。連続失敗の数にも入れない = サーキットブレーカを
            // 環境ノイズで作動させない
            if outcome == .environmentFault {
                let requeued = await discardAndRequeue(item, worker: worker, queue: queue,
                                                       reason: "a transient accessibility fault")
                if !requeued { failed += 1 }
                continue
            }
            // デバイスが使用不能なら結果取り消し+別デバイス再実行+ワーカー離脱。
            // .frozen(スクショ由来の明示シグナル)は即。.failed は事後プローブで確認:
            // まず消失(adb offline/未検出。安価な adb devices 1回)、次に画面凍結(screencap プローブ)。
            // iOS はブリッジ /status の生存確認(ブリッジのウェッジ=シナリオ途中から全ステップが
            // 接続エラーになる実害があり、Android のプローブでは拾えない)。
            var unusableReason: String? = outcome == .frozen ? "a frozen screen" : nil
            if unusableReason == nil, outcome == .failed, worker.platform == "android",
               let serial = worker.connection.serial {
                if await deviceUnreachable(serial) {
                    // 消失判定(adb devices)は実機でも有効。USB 抜け・WiFi 断の検知に使える
                    unusableReason = "the device disappeared (offline/not found)"
                } else if !worker.connection.physical, await deviceFrozen(serial) {
                    // 凍結判定はエミュレータ限定(閾値が解像度依存。ProfileWorkerFactory の
                    // excludeOrRepairBlankScreenWorkers と同じ理由)
                    unusableReason = "a frozen screen"
                }
            }
            if unusableReason == nil, outcome == .failed, worker.platform == "ios",
               await bridgeUnreachable(worker) {
                unusableReason = "an unreachable bridge"
            }
            // サーキットブレーカ: 凍結/消失に当てはまらなくても連続失敗が閾値に達したら不調ワーカーとして離脱。
            if unusableReason == nil {
                consecutiveFailures += 1
                if consecutiveFailures >= WORKER_FAILURE_CIRCUIT_THRESHOLD {
                    unusableReason = "\(consecutiveFailures) consecutive worker failures"
                }
            }
            if let reason = unusableReason {
                let requeued = await discardAndRequeue(item, worker: worker, queue: queue, reason: reason)
                if !requeued { failed += 1 }
                await reportWorkerFailed(worker, "dropped out because of \(reason)")
                await releaseLease(leaseKey)
                await stopRecording(worker, leaseKey: leaseKey)
                return .retired(failed: failed, worker: worker)
            }
            failed += 1
        }
        await releaseLease(leaseKey)
        await stopRecording(worker, leaseKey: leaseKey)
        return .completed(failed)
    }

    private func releaseLease(_ key: String?) async {
        guard let key else { return }
        await leaseKeys.remove(key)
        removeRunLease?(key)
    }

    /// RecordingLease の削除は停止指示と同時に行う(クリップ切り出し[AVFoundation のエクスポート]は
    /// シナリオ数分繰り返され数秒〜数十秒かかりうるが、モニターの「録画中」表示は停止指示と同時に
    /// 消してよい)。lease 削除後に videoRecording?.stop で実際の停止+クリップ切り出しへ進む
    private func stopRecording(_ worker: RunWorker, leaseKey: String?) async {
        if let leaseKey {
            await recordingLeaseKeys.remove(leaseKey)
            removeRecordingLease?(leaseKey)
        }
        await videoRecording?.stop(worker)
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
            return ["❌ Worker \(worker) dropped out: \(message)"]
        case .workerLog(let worker, let message):
            return ["ℹ️ [\(worker)] \(message)"]
        case .flowRequeued(_, _, let reason, let attempt, let limit):
            return ["  🔁 Re-running on another device because of \(reason) (\(attempt)/\(limit))"]
        case .flowStarted(let worker, _, let flowName, let isDirty):
            var lines = ["▶ \(flowName) [\(worker)]"]
            if isDirty { lines.append("  ⚠️ This flow is dirty (needs review)") }
            return lines
        case .step(_, _, let result):
            return lines(for: result)
        case .flowPaused(_, _, let index, let description, _, _):
            return ["  ⏸ Paused before \(index). \(description)"]
        case .flowHealed:
            return ["  🔧 Updated the flow with healed locators (dirty: true — needs review)"]
        case .fixSuggestion:
            return []
        case .flowFinished(_, _, let passed, let triage, let reportURL, _):
            var lines: [String] = []
            if passed {
                lines.append("  → ✅ passed")
            } else {
                if let triage {
                    lines.append("  → 🔍 Triage: [\(triage.failureClass)] \(triage.summary)")
                }
                if let reportURL {
                    lines.append("  → ❌ failed — report: \(reportURL.path)")
                } else {
                    lines.append("  → ❌ failed")
                }
            }
            lines.append("")
            return lines
        case .flowSkipped(let flowURL, let reason):
            let name = flowURL.lastPathComponent.removingPercentEncoding
                ?? flowURL.lastPathComponent
            return ["⚠️ Cannot run \(name): \(reason)", ""]
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
            return ["  ⚠️ \(step.index). \(description) (skipped: \(reason))"]
        case .inconclusive(let reason):
            return ["  ❓ \(step.index). \(description) (inconclusive: \(reason))"]
        }
    }
}
