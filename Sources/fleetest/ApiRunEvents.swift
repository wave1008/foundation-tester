// ApiRunEvents.swift
// fleetest api run の NDJSON イベント型と、ApiRunCommand が使う集計・受け渡しの小箱

import Foundation
import FTAndroid
import FTCore
import FTRemote

/// stdin 読み取りスレッドと ScenarioHost.run(onControl コールバック)の間で
/// ScenarioRunControl を受け渡す小箱(いずれか片方のスレッドから読み書きされる)
final class DebugControlBox: @unchecked Sendable {
    private let lock = NSLock()
    private var _control: ScenarioRunControl?

    var control: ScenarioRunControl? {
        get { lock.lock(); defer { lock.unlock() }; return _control }
        set { lock.lock(); defer { lock.unlock() }; _control = newValue }
    }
}

/// fleetest api run の冒頭イベント。internal: ApiRunMachineFanout が複数機械分をまとめて1回だけ emit する
struct ApiRunStartedEvent: Encodable {
    let kind = "runStarted"
    let total: Int
}

/// 実行開始時の Wipe Data(AndroidDataWiper)のデバイス単位フェーズ通知。runStarted より
/// 前に emit されうる。同期相手: vscode-fleetest/src/model.ts の WipeStatusEvent
struct ApiWipeStatusEvent: Encodable {
    let kind = "wipeStatus"
    let device: String
    /// "stopping" | "rebooting" | "done" | "failed"
    let phase: String
}

/// dispatch.lock の待機列に並んでいる間の進行通知。出すのは**リモートへのディスパッチ**
/// (`RemoteRunDispatcher.acquireDispatchLock`)と**手元の run**(`LocalDispatchLock.acquire`)の
/// 2箇所で、どちらも**既存の進行ログと同じ刻み**(初回 + `WaitLockPolling.shouldLogProgress`)。
/// 取得できた/諦めたときの終了イベントは無い(runStarted か失敗で終わりが分かる)。
/// internal: RemoteRunDispatcher / LocalDispatchLock が emit する。
/// 契約の同期相手: vscode-fleetest/src/model.ts の DispatchWaitingEvent
struct ApiDispatchWaitingEvent: Encodable {
    let kind = "dispatchWaiting"
    /// 待っている相手の **machine**(モニタータイル・run レーンと同じ名前空間)。
    /// `--runner` の生値(登録簿のエイリアス)があればそれ、無ければ ssh 宛先そのもの。
    /// **手元のロックを待っているときは `local`**(`DeviceMachineGrouping.localDisplayName` =
    /// `--device-machine` / タイルと同じ語彙。新しい綴りを作らない)。
    ///
    /// **`ProtocolVersion` は上げない**: 欄の集合も型も必須/省略も1つも変わらず、
    /// 既存の欄に取りうる値が1つ増えるだけで、拡張の**読み方**(decode・レーンの振り分け =
    /// `laneIdOf` は worker しか見ない)は変わらない。版で守っているのは decode の互換で、
    /// ここは表示の文言だけ —— 古い拡張は `local` を機械名としてそのまま出す(名前を持たない
    /// 機械と同じ縮退)ので、沈黙する縮退にはならない
    let machine: String
    /// 待機列での自分の位置(1始まり)
    let position: Int
    /// 生きているチケットの総数(自分を含む)
    let total: Int
    /// いまロックを掴んでいる人(`RemoteDispatchLock.holderSummary`)。**読めたときだけ**入る ——
    /// nil はキーごと省く(読めなかったことを「占有」に倒さない。DispatchWaitStatus.holder の宣言)
    let holder: String?
    let elapsedSeconds: Int
    /// `--wait-lock <秒>`。フラグが無ければキーごと省く
    let limitSeconds: Int?
}

extension ApiDispatchWaitingEvent {
    /// 待機の事実を NDJSON の1行として出す。**リモートと手元が共有する唯一の組み立て口** ——
    /// 2つ持つと、欄を足したときに片方だけ古い形を出す(拡張からは片方の機械だけが黙って見えなくなる)。
    /// 数字・保持者は進行ログと同じ1つの値(`DispatchWaitStatus`)から採る。
    /// エンコード失敗は黙って捨てる(待機の通知が出ないだけで run は続く)。
    /// `out` はテストが受け口を差し替えるためだけの引数(本番は NDJSON の stdout)
    static func emit(machine: String, status: DispatchWaitStatus,
                     out: (String) -> Void = { ConsoleOut.out($0) }) {
        let event = ApiDispatchWaitingEvent(
            machine: machine,
            position: status.position, total: status.total,
            // **読めたときだけ**(nil は Encodable の合成が encodeIfPresent でキーごと省く)
            holder: status.holder.map { RemoteDispatchLock.holderSummary($0) },
            elapsedSeconds: status.elapsedSeconds, limitSeconds: status.limitSeconds)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        guard let data = try? encoder.encode(event),
              let line = String(data: data, encoding: .utf8) else { return }
        out(line)
    }
}

/// 振り直し通知(RunEvent.flowRequeued)。契約の同期相手: vscode-fleetest/src/model.ts ScenarioRequeuedEvent
struct ApiScenarioRequeuedEvent: Encodable {
    let kind = "scenarioRequeued"
    let scenario: String
    let worker: String
    let reason: String
    let attempt: Int
    let limit: Int
}

/// --profile 指定(ワーカー並列実行時)のみ、runStarted 直後に 1 回 emit するイベント。
/// id は "<platform>:<デバイス論理名>"(ApiMonitorCommand.swift の monitorDevices の id と
/// 同一規則。VSCode 拡張がモニタータイルと突合するため)。internal: 複数機械にまたがる
/// プロファイルでは ApiRunMachineFanout が各子ぶんを合流させて1回だけ emit する
struct ApiWorkersReadyEvent: Encodable {
    let kind = "workersReady"
    let workers: [ApiWorkerInfo]
}

/// ApiWorkersReadyEvent の 1 ワーカー分。同期相手: vscode-fleetest/src/model.ts の WorkerInfo
/// (id/name/platform/detail)。machine は
/// src/monitorDeviceModel.ts の MonitorDevice.machine と同じ名前・同じ意味(手元は省略・
/// リモートはホスト名)で揃える。表示の組み立ては拡張側(src/runLaneModel.ts の workersReady
/// 処理・laneLog.js の .lane-name)の責務なので、name 自体は加工しない
struct ApiWorkerInfo: Encodable {
    let id: String
    let name: String
    let platform: String
    let detail: String
    /// 複数機械にまたがるプロファイルでこのワーカーが居る機械(手元は nil = キー省略)
    let machine: String?

    init(id: String, name: String, platform: String, detail: String, machine: String? = nil) {
        self.id = id
        self.name = name
        self.platform = platform
        self.detail = detail
        self.machine = machine
    }
}

/// fleetest api run の末尾イベント。vscode-fleetest/src/model.ts の RunFinishedEvent と
/// フィールド名を同期(testSeconds/scenarioTotalSeconds のリネーム不可)。internal: 複数機械に
/// またがるプロファイルでは ApiRunMachineFanout が全ホストの合計を1回だけ emit する
struct ApiRunFinishedEvent: Encodable {
    let kind = "runFinished"
    let passed: Int
    let failed: Int
    /// 子が対象外を宣言したシナリオ数(必須。passed + failed + skipped == 実行本数)
    let skipped: Int
    let testSeconds: Double?
    let scenarioTotalSeconds: Double?
    /// 結果を書いた run の runID(記録しない dry-run / debug では nil = キー省略)。拡張は run 完了時に
    /// この run の録画を開く(monitorRecordingsController.ts の revealRun)。束ねた run では
    /// どれか1つでよい —— 読み手は runGroup から全体を引き直す(recordingsStore.ts resolveSessionRunIDs)
    let runID: String?
}

/// 実行の集計結果。testSeconds/scenarioTotalSeconds は ScenarioTimingTracker 参照
/// RunEvent の worker(= RunWorker.label)→ workersReady と同じ id("platform:論理名")への変換表。
/// iOS ワーカーが遅延参加(RunOrchestrator.lateWorkers)で後から加わるため、NSLock で保護した
/// 可変 map にする(書き手=lateWorkers provider タスク、読み手=NDJSON 変換ループ)。
final class WorkerIDMap: @unchecked Sendable {
    private let lock = NSLock()
    private var map: [String: String]

    init(_ workers: [RunWorker]) {
        map = Dictionary(uniqueKeysWithValues: workers.map {
            ($0.label, "\($0.platform):\($0.logicalName ?? $0.label)")
        })
    }

    func merge(_ workers: [RunWorker]) {
        lock.lock()
        defer { lock.unlock() }
        for w in workers {
            map[w.label] = "\(w.platform):\(w.logicalName ?? w.label)"
        }
    }

    func id(for label: String) -> String {
        lock.lock()
        defer { lock.unlock() }
        return map[label] ?? label
    }
}

struct RunOutcome {
    var passed: Int
    var failed: Int
    /// 子が対象外を宣言したシナリオ数(passed / failed のどちらにも含めない)
    var skipped: Int
    var testSeconds: Double?
    var scenarioTotalSeconds: Double?
    /// 実行中に劣化・離脱したワーカー(「label: 理由」)。並列経路のみ発生しうる。
    var degradedWorkers: [String] = []
    /// 結果取り消し+振り直しの監査記録(並列経路のみ)。
    var freezeRetries: [String] = []
    /// run 前の blank 判定で修復/除外されたワーカー label(RunMetaRecord へ記録)。
    var blankRepairs: [String] = []
    var blankExclusions: [String] = []
    /// 上2つ(degraded/freeze)と同じ事象の構造化版(run.json の workerAnomalies)
    var workerAnomalies: [WorkerAnomalyRecord] = []
    /// この run が SIGINT/SIGTERM で中断されたか(RunInterruptState 参照)
    var interrupted = false
}

/// 並列ワーカー構築 Task から blank triage を run() へ運ぶ入れ物
/// (--debug の DebugControlBox と同じ受け渡しパターン)。**android task と iOS task の両方が
/// `add` で書く**(android / iOS の 2 つの Task が別々に書くので、上書き(set)だと後から
/// 書いた側だけが run.json の blankRepairs に残る)
final class BlankTriageBox: @unchecked Sendable {
    private let lock = NSLock()
    private var repaired: [String] = []
    private var excluded: [String] = []
    private var anomalies: [WorkerAnomalyRecord] = []
    func add(repaired: [String], excluded: [String], anomalies new: [WorkerAnomalyRecord] = []) {
        lock.lock(); defer { lock.unlock() }
        self.repaired += repaired; self.excluded += excluded; self.anomalies += new
    }
    func get() -> (repaired: [String], excluded: [String]) {
        lock.lock(); defer { lock.unlock() }
        return (repaired, excluded)
    }
    func getAnomalies() -> [WorkerAnomalyRecord] { lock.lock(); defer { lock.unlock() }; return anomalies }
}

/// flowStarted〜flowFinished から testSeconds(最初の開始〜最後の完了)と
/// scenarioTotalSeconds(シナリオ毎の所要時間の合計)を計測する。並列実行では
/// record(_:) で RunEvent の flowStarted/flowFinished を渡す(flowURL をキーに対応付ける。
/// flowSkipped は無視 = 0秒扱い)。逐次実行では recordSequential(start:finish:) を
/// シナリオ毎に直接呼ぶ(同時に1件しか走らないため URL キー付けは不要)。ProfileRunner.swift
/// からも同一ターゲット内で参照
/// プラットフォーム 1 つ分のレーン稼働。分母は run 全体の壁時計(= そのプラットフォームが
/// 「run が続いている間どれだけ遊休だったか」を表す)。docs/performance-tuning.md §3.6 の
/// 「台数を増やす前に、プラットフォーム別の稼働率と最終終了時刻を見る」を実行後に読める形にしたもの。
struct LaneUtilization {
    let platform: String
    /// 実際にシナリオを1本でも実行したワーカー数
    let lanes: Int
    /// そのプラットフォームの全レーンの実行時間の総和
    let busySeconds: Double
    /// run 全体の開始から、そのプラットフォームの最後のシナリオが終わるまで
    let lastFinishSeconds: Double
    /// busy ÷ (lanes × run 全体の壁時計)。1.0 = 全レーンが最後まで詰まっていた
    let utilization: Double
}

struct ScenarioTimingTracker {
    private var firstStart: Date?
    private var lastFinish: Date?
    /// flowURL → ワーカー → 開始時刻。**ワーカーまで分ける**(broadcast は同じ flowURL を複数のワーカーが同時に走らせる)
    private var startedAt: [URL: [String: Date]] = [:]
    /// 直後の flowStarted / flowFinished が送られた時刻(RunEvent.flowStartedAt / flowEndedAt)。flowURL → ワーカー → 時刻。
    /// あれば受け取り時刻より優先する(開始・終了を同じ基準で数える)
    private var sentStartAt: [URL: [String: Date]] = [:]
    private var sentEndAt: [URL: [String: Date]] = [:]

    /// 終了に対応する開始を取り出す。同じワーカーの開始が無ければ、その flowURL に残る開始が**1つだけ**のときに限ってそれを使う
    /// (振り直しで開始と終了のワーカーが変わる形。broadcast のように複数が並ぶときは混ぜない)
    private mutating func takeStart(flowURL: URL, worker: String) -> (at: Date, worker: String)? {
        if let at = startedAt[flowURL]?.removeValue(forKey: worker) { return (at, worker) }
        guard let pending = startedAt[flowURL], pending.count == 1, let only = pending.first else { return nil }
        startedAt[flowURL] = nil
        return (only.value, only.key)
    }
    private var scenarioTotal: TimeInterval = 0
    private var hasScenario = false
    /// platform → (稼働したレーン = RunWorker.laneKey(デバイス単位。label はポートで変わる),
    /// 実行時間の総和, 最後の終了時刻)
    private var lanesByPlatform: [String: Set<String>] = [:]
    private var busyByPlatform: [String: TimeInterval] = [:]
    private var lastFinishByPlatform: [String: Date] = [:]

    /// ワーカー label から platform を戻す。形式の正は RunWorker.platform(fromLabel:)
    /// (デバイス名が "(" や ":" を含むため素朴な split は壊れる)。
    /// 解釈できない label は "?" に寄せる(集計から落とさない)。
    private static func platform(ofWorker label: String) -> String {
        RunWorker.platform(fromLabel: label) ?? "?"
    }

    /// at はテストから時刻を固定するための注入点(既定は実時刻)。
    mutating func record(_ event: RunEvent, at now: Date = Date()) {
        switch event {
        case .flowStartedAt(let worker, let flowURL, let at):
            sentStartAt[flowURL, default: [:]][worker] = at
        case .flowEndedAt(let worker, let flowURL, let at):
            sentEndAt[flowURL, default: [:]][worker] = at
        case .flowStarted(let worker, let flowURL, _, _):
            let now = sentStartAt[flowURL]?.removeValue(forKey: worker) ?? now
            // min/max で受ける(実運用のイベントは時系列順だが、順序に依存しない方が安全。
            // 依存すると集計が壁時計より短い分母を掴んで稼働率が 100% を超える)
            firstStart = min(firstStart ?? now, now)
            startedAt[flowURL, default: [:]][worker] = now
            hasScenario = true
        case .flowFinished(let worker, let flowURL, _, _, _, _, _):
            let now = sentEndAt[flowURL]?.removeValue(forKey: worker) ?? now
            lastFinish = max(lastFinish ?? now, now)
            let platform = Self.platform(ofWorker: worker)
            lastFinishByPlatform[platform] = max(lastFinishByPlatform[platform] ?? now, now)
            lanesByPlatform[platform, default: []].insert(RunWorker.laneKey(fromLabel: worker))
            if let start = takeStart(flowURL: flowURL, worker: worker) {
                let elapsed = now.timeIntervalSince(start.at)
                scenarioTotal += elapsed
                // 実行したのは開始時のワーカー(振り直しで別デバイスに移ることがある)
                let busyPlatform = Self.platform(ofWorker: start.worker)
                busyByPlatform[busyPlatform, default: 0] += elapsed
                lanesByPlatform[busyPlatform, default: []].insert(RunWorker.laneKey(fromLabel: start.worker))
            }
        default:
            break
        }
    }

    /// プラットフォーム別のレーン稼働(platform 名の昇順)。run が空なら空配列。
    var laneUtilizations: [LaneUtilization] {
        guard let firstStart, let lastFinish else { return [] }
        let runSpan = lastFinish.timeIntervalSince(firstStart)
        return lanesByPlatform.keys.sorted().compactMap { platform in
            let lanes = lanesByPlatform[platform]?.count ?? 0
            guard lanes > 0 else { return nil }
            let busy = busyByPlatform[platform] ?? 0
            let denominator = Double(lanes) * runSpan
            return LaneUtilization(
                platform: platform, lanes: lanes, busySeconds: busy,
                lastFinishSeconds: (lastFinishByPlatform[platform] ?? firstStart)
                    .timeIntervalSince(firstStart),
                utilization: denominator > 0 ? busy / denominator : 0)
        }
    }

    mutating func recordSequential(start: Date, finish: Date) {
        firstStart = min(firstStart ?? start, start)
        lastFinish = max(lastFinish ?? finish, finish)
        scenarioTotal += finish.timeIntervalSince(start)
        hasScenario = true
    }

    var testSeconds: Double? {
        guard let firstStart, let lastFinish else { return nil }
        return lastFinish.timeIntervalSince(firstStart)
    }

    var scenarioTotalSeconds: Double? { hasScenario ? scenarioTotal : nil }
}

/// `api run` が台数を決めるための本数の読み方(判断はここだけ。ApiRunExactScenarioCountTests)。
/// この経路はシナリオ一覧をビルドと並行に解決するので、台数を決める時点では一覧が無い ——
/// 確定しているのは `--scenario` の指定文字列だけ。**明示 ID(`Class.method`)は1つにつき高々1本**
/// なので合計を上限に使える。クラス名指定や全件は本数が分からないので **0 = 絞らない**
/// (そこは並列度が要る場面で、絞ると遅くなる)
enum ApiRun {
    static func exactScenarioCount(_ selectors: [String]) -> Int {
        guard !selectors.isEmpty, selectors.allSatisfy({ $0.contains(".") }) else { return 0 }
        return selectors.count
    }

    /// dry-run は FM を丸ごと切る(`fleetest run --dry-run` / `ft_dry_run` と同じ)。
    /// デバイスも画面も無いので、FM を引く経路をまとめて止める(個別に切ると残った経路が FM の直列化待ちを払う)
    static func withDryRunFM(_ settings: ScenarioExecutionSettings,
                             dryRun: Bool) -> ScenarioExecutionSettings {
        guard dryRun else { return settings }
        var out = settings
        out.fm = FMConfig(enabled: false)
        return out
    }
}
