// RunRecord.swift
// ファイルベース実行結果 DB のレコード DTO(1 run = 1 ディレクトリ・1 シナリオ = 1 ファイル)。
// ディレクトリ配置・書き込みは RunResultsStore.swift、発番・ロックは RunRecorder.swift。
// このファイルのシグネチャは他エージェントの呼び出しコードが前提にしている契約なので、
// 変更する場合は呼び出し側(RunOrchestrator 等)も揃えて直すこと。

import Foundation

public enum RunRecordSchema {
    /// scanRuns/scanRecords はこれより大きい schemaVersion のレコードをスキップする
    public static let current = 1
}

/// run 中に起きたワーカーの異常。**prose の degradedWorkers / freezeRetries と同じ事実を
/// 機械可読な形で持つ**(あちらは人が読む1行。こちらは「この run を除外するか」を
/// コードで判断するための欄)。**判定はしない** —— 起きた事実だけを置く。
public struct WorkerAnomalyRecord: Codable, Sendable {
    /// "degraded"(劣化・離脱)/ "requeued"(結果取り消し+振り直し)/
    /// "retryLimit"(振り直しの上限に達し、失敗として記録した)
    public var kind: String
    /// ScenarioRunRecord.worker と**同じ規則**("<platform>:<デバイス論理名>")。
    /// 論理名を持たない経路(--ports 等)では nil = label だけで照合する
    public var worker: String?
    /// 表示上の識別子(degradedWorkers の1行に出るものと同一)
    public var label: String
    /// requeued / retryLimit のときの対象シナリオ ID
    public var scenarioID: String?
    /// 英語・人間可読(prose 側と同じ文)
    public var reason: String

    public init(kind: String, worker: String?, label: String,
                scenarioID: String? = nil, reason: String) {
        self.kind = kind
        self.worker = worker
        self.label = label
        self.scenarioID = scenarioID
        self.reason = reason
    }
}

/// results/runs/<YYYY-MM>/<runID>/run.json
public struct RunMetaRecord: Codable, Sendable {
    public var schemaVersion: Int
    public var runID: String
    public var project: String
    public var profile: String?
    public var machine: String
    /// "api" | "cli"
    public var trigger: String
    public var startedAt: String
    public var finishedAt: String?
    public var total: Int?
    public var passed: Int?
    public var failed: Int?
    /// 実行中に劣化・離脱したワーカー(「label: 理由」)。空/未発生は nil で省略。連鎖失敗の事後診断用。
    /// **機械的な除外には `workerAnomalies` を見る**(こちらは表示用の1行)
    public var degradedWorkers: [String]?
    /// 凍結等による結果取り消し+振り直しの監査記録(成功した振り直しはシナリオ記録に痕跡を
    /// 残さないため、ここが唯一の証跡)。空/未発生は nil で省略。
    public var freezeRetries: [String]?
    /// run 前の blank 判定で sleep/wake 修復により除外を免れたワーカー label(凍結傾向の追跡用。
    /// TS ミラー: vscode-fleetest/src/dashboardModel.ts)。空/未発生は nil で省略。
    public var blankRepairs: [String]?
    /// run 前の blank 判定で修復不発により除外したワーカー label(guest reboot 発行済み)。
    /// 空/未発生は nil で省略。
    public var blankExclusions: [String]?
    /// performanceMode の run で、実行中にレーン数が変わり所要時間が計測に使えないときだけ true。
    /// false/nil は書かない(`MeasurementValidity.verdict` 参照。既定モードの run は常に nil)。
    public var measurementInvalid: Bool?
    /// measurementInvalid=true のときの理由(英語、人間可読)。measurementInvalid が無ければ nil。
    public var measurementInvalidReasons: [String]?
    /// degradedWorkers / freezeRetries と同じ事実の構造化版(join できる worker id 付き)。
    /// 空/未発生は nil で省略。**後発追加の Optional なので旧レコードもそのまま読める**
    public var workerAnomalies: [WorkerAnomalyRecord]?
    /// 自己申告のディスパッチ発行者(LocalConfig.resolveIssuerId)。認証ではない(帰属の記録のみ)。
    /// 旧レコードにはキーが無いので Optional のまま decode できる(schemaVersion は上げない)
    public var issuer: String?

    public init(schemaVersion: Int = RunRecordSchema.current, runID: String, project: String,
                profile: String?, machine: String, trigger: String, startedAt: String,
                finishedAt: String? = nil, total: Int? = nil, passed: Int? = nil,
                failed: Int? = nil, degradedWorkers: [String]? = nil,
                freezeRetries: [String]? = nil,
                blankRepairs: [String]? = nil, blankExclusions: [String]? = nil,
                measurementInvalid: Bool? = nil, measurementInvalidReasons: [String]? = nil,
                workerAnomalies: [WorkerAnomalyRecord]? = nil,
                issuer: String? = nil) {
        self.schemaVersion = schemaVersion
        self.runID = runID
        self.project = project
        self.profile = profile
        self.machine = machine
        self.trigger = trigger
        self.startedAt = startedAt
        self.finishedAt = finishedAt
        self.total = total
        self.passed = passed
        self.failed = failed
        self.degradedWorkers = degradedWorkers
        self.freezeRetries = freezeRetries
        self.blankRepairs = blankRepairs
        self.blankExclusions = blankExclusions
        self.measurementInvalid = measurementInvalid
        self.measurementInvalidReasons = measurementInvalidReasons
        self.workerAnomalies = workerAnomalies
        self.issuer = issuer
    }
}

public struct SceneResultRecord: Codable, Sendable {
    public var scene: Int
    public var title: String
    public var passed: Bool
    public var durationMs: Int?

    public init(scene: Int, title: String, passed: Bool, durationMs: Int? = nil) {
        self.scene = scene
        self.title = title
        self.passed = passed
        self.durationMs = durationMs
    }
}

public struct StepCountsRecord: Codable, Sendable {
    public var total: Int
    public var passed: Int
    public var failed: Int
    public var skipped: Int
    public var healed: Int
    public var passedViaFallback: Int
    /// verify のブロックにアサーションが無かった等の inconclusive。失敗には数えない。
    /// 後発の追加フィールドなので Optional(ScenarioEvent.durationMs と同じ理由。旧レコードの
    /// 欠損キーが decode エラーにならず nil になる = 過去の run 結果を読み続けられる)
    public var inconclusive: Int?
    /// 掴んだ値だけで通り、デバイスを 1 度も見なかったステップ数(StepNote.heldValue)。
    /// これらは durationMs=0 で記録されるため、**所要の内訳を読むときの母数から抜ける** ——
    /// 高速化の効果を見るときに「当たり率が上がっただけ」を切り分けるための分母。Optional の理由は
    /// inconclusive と同じ
    public var viaHeldValue: Int?

    public init(total: Int = 0, passed: Int = 0, failed: Int = 0, skipped: Int = 0,
                healed: Int = 0, passedViaFallback: Int = 0, inconclusive: Int? = nil,
                viaHeldValue: Int? = nil) {
        self.total = total
        self.passed = passed
        self.failed = failed
        self.skipped = skipped
        self.healed = healed
        self.passedViaFallback = passedViaFallback
        self.inconclusive = inconclusive
        self.viaHeldValue = viaHeldValue
    }
}

public struct FailedStepRecord: Codable, Sendable {
    public var index: Int
    public var scene: Int?
    public var sceneTitle: String?
    /// **どのフェーズで落ちたか**: condition / action / expectation(CAE ブロック)、
    /// setUp / tearDown(ライフサイクル)、いずれの外なら nil。
    /// 「共有フローや端末の準備で落ちた」と「テスト内容で落ちた」を機械的に分けるための一次情報
    public var section: String?
    public var description: String
    /// DSL のコマンド名(`tap` / `exist` …)。**description から切り出さずに運ぶ**
    /// (説明文には group の前置や注記の括弧書きが付くため。ScenarioEvent.command 参照)
    public var command: String?
    /// どの経路で落ちたか(`StepFailureKind` の rawValue)。**言えないときは nil**。
    /// 原因の推定ではない —— 「環境要因か否か」の判断は読み手が持つ情報と合わせて行うもの
    public var failureKind: String?
    /// このステップに付いた注記(`StepNote` の rawValue)。割り込みを閉じた・整定を打ち切った等、
    /// 失敗の読み解きに要る事実。注記が無ければ nil
    public var notes: [String]?
    public var detail: String?
    public var file: String?
    public var line: Int?
    public var durationMs: Int?
    /// 失敗確定時刻(ISO8601+ミリ秒。ScenarioEvent.at 由来)。動画録画(record:true)の
    /// 再生位置ジャンプ用。取得できない経路(recordSkipped 等)では nil
    public var at: String?

    public init(index: Int, scene: Int? = nil, sceneTitle: String? = nil, section: String? = nil,
                description: String, command: String? = nil, failureKind: String? = nil,
                notes: [String]? = nil,
                detail: String? = nil, file: String? = nil,
                line: Int? = nil, durationMs: Int? = nil, at: String? = nil) {
        self.index = index
        self.scene = scene
        self.sceneTitle = sceneTitle
        self.section = section
        self.description = description
        self.command = command
        self.failureKind = failureKind
        self.notes = notes
        self.detail = detail
        self.file = file
        self.line = line
        self.durationMs = durationMs
        self.at = at
    }
}

/// 録画再生 UI のステップツリー(クリックでシーク)用。failedSteps と違い成否によらず全ステップを
/// 記録順(イベント到着順)のまま保持する。sceneTitle の解決規則は FailedStepRecord と同一
public struct TimelineStepRecord: Codable, Sendable {
    public var scene: Int?
    public var sceneTitle: String?
    public var index: Int
    public var description: String
    /// ScenarioEvent.status をそのまま(passed/passedViaFallback/healed/failed/skipped)
    public var status: String
    /// ISO8601+ミリ秒(ScenarioEvent.at 由来)。取得できないステップでは nil
    public var at: String?
    public var durationMs: Int?
    /// StepNote の rawValue(ScenarioEvent.notes 由来)。**run 横断の集計はここだけを見る**
    /// (description の文言一致で数えない。StepNote の doc 参照)。注記が無いステップと、
    /// notes を持たない旧レコードはどちらも nil
    public var notes: [String]?

    public init(scene: Int? = nil, sceneTitle: String? = nil, index: Int, description: String,
                status: String, at: String? = nil, durationMs: Int? = nil,
                notes: [String]? = nil) {
        self.scene = scene
        self.sceneTitle = sceneTitle
        self.index = index
        self.description = description
        self.status = status
        self.at = at
        self.durationMs = durationMs
        self.notes = notes
    }
}

public struct FixSuggestionRecord: Codable, Sendable {
    public var scene: Int?
    public var file: String?
    public var line: Int?
    public var oldSelector: String?
    public var newSelector: String?

    public init(scene: Int? = nil, file: String? = nil, line: Int? = nil,
                oldSelector: String? = nil, newSelector: String? = nil) {
        self.scene = scene
        self.file = file
        self.line = line
        self.oldSelector = oldSelector
        self.newSelector = newSelector
    }
}

/// results/runs/<YYYY-MM>/<runID>/scenarios/<シナリオID>.json
/// `RunRecorder.recordSkipped` が書いた合成レコードの理由。**混ぜてはいけない2種**:
/// 意図された対象外と、実行できなかった事故。同じ顔にすると「緑だが1本も走っていない」run を
/// 見分けられなくなる。nil = 通常実行のレコード(または旧形式)
public enum ScenarioSkipKind: String, Codable, Sendable {
    /// 実行プロファイルの platform に対して対象外(`@TestClass(platform:)` / `@Test(platform:)`)。
    /// **意図された未実行**なので run の失敗数には数えない
    case notApplicable
    /// 担当ワーカー不在・全滅・振り直し上限などのインフラ都合。従来どおり失敗として数える
    case noWorker
}

public struct ScenarioRunRecord: Codable, Sendable {
    public var schemaVersion: Int
    /// Builder 段階では ""。RunRecorder.record が焼き込む
    public var runID: String
    public var scenarioID: String
    public var title: String?
    public var platform: String
    /// "<platform>:<デバイス論理名>"(ScenarioEvent.worker と同一規則)
    public var worker: String?
    /// RunRecorder が焼き込む(Builder 段階では "")
    public var machine: String
    /// RunRecorder が焼き込む
    public var profile: String?
    public var passed: Bool
    public var timedOut: Bool?
    public var startedAt: String
    public var durationMs: Int
    public var scenes: [SceneResultRecord]
    public var steps: StepCountsRecord
    /// リポジトリルート相対(packageRoot の prefix を剥がしたもの)
    public var reportPath: String?
    /// 失敗時のみ(passed なら常に nil)
    public var failedSteps: [FailedStepRecord]?
    /// 失敗時のみ(passed なら常に nil)
    public var fixSuggestions: [FixSuggestionRecord]?
    /// 失敗時のみ。ステップ到達前のインフラ失敗(ブリッジ未接続・タイムアウト等)は failedSteps が
    /// 空になるため、エラーログ末尾を残して失敗原因の分析(インフラ起因 vs アサーション起因)を可能にする
    public var errorLogs: [String]?
    /// FM 呼び出し実測(回数・レイテンシ)。FM を使わなかったシナリオでは nil。
    /// FM は直列化するので、run 全体で totalMs を合算すると実行時間の下限が見積もれる
    public var fm: FMUsageRecord?
    /// 全ステップのタイムライン(録画再生 UI のステップツリー用。イベント到着順)。
    /// failedSteps と異なり成否によらず記録する。ステップが1つも無ければ nil
    public var timeline: [TimelineStepRecord]?
    /// recordSkipped の合成レコードだけが持つ理由の種別(通常実行は nil。旧レコードも nil)
    public var skipKind: ScenarioSkipKind?

    public init(schemaVersion: Int = RunRecordSchema.current, runID: String = "",
                scenarioID: String, title: String? = nil, platform: String, worker: String? = nil,
                machine: String = "", profile: String? = nil, passed: Bool, timedOut: Bool? = nil,
                startedAt: String, durationMs: Int, scenes: [SceneResultRecord] = [],
                steps: StepCountsRecord, reportPath: String? = nil,
                failedSteps: [FailedStepRecord]? = nil,
                fixSuggestions: [FixSuggestionRecord]? = nil,
                errorLogs: [String]? = nil,
                fm: FMUsageRecord? = nil,
                timeline: [TimelineStepRecord]? = nil,
                skipKind: ScenarioSkipKind? = nil) {
        self.fm = fm
        self.skipKind = skipKind
        self.schemaVersion = schemaVersion
        self.runID = runID
        self.scenarioID = scenarioID
        self.title = title
        self.platform = platform
        self.worker = worker
        self.machine = machine
        self.profile = profile
        self.passed = passed
        self.timedOut = timedOut
        self.startedAt = startedAt
        self.durationMs = durationMs
        self.scenes = scenes
        self.steps = steps
        self.reportPath = reportPath
        self.failedSteps = failedSteps
        self.fixSuggestions = fixSuggestions
        self.errorLogs = errorLogs
        self.timeline = timeline
    }
}

/// ScenarioEvent の NDJSON 列を ScenarioRunRecord へ畳み込むビルダー。
/// 呼び出し順の前提: sceneStarted → step* → sceneFinished を scene ごとに繰り返し、
/// 末尾で scenarioFinished(reportPath)。順序が崩れても欠けたフィールドは nil/0 になるだけで例外は出さない。
public struct ScenarioRecordBuilder {
    private let scenarioID: String
    private let platform: String
    private let title: String?
    private let worker: String?

    private var scenes: [SceneResultRecord] = []
    private var stepCounts = StepCountsRecord()
    private var failedSteps: [FailedStepRecord] = []
    private var fixSuggestions: [FixSuggestionRecord] = []
    private var reportPath: String?
    private var fm: FMUsageRecord?
    /// 全ステップのタイムライン(成否によらず到着順で蓄積。build() で timeline へ)
    private var timeline: [TimelineStepRecord] = []

    private var sceneTitles: [Int: String] = [:]
    /// sceneFinished が durationMs を持たない場合のフォールバック(scene 内 step の合計)
    private var sceneDurationAccum: [Int: Int] = [:]
    /// ❌/⚠️/⏱ で始まる log イベントの末尾 5 件(失敗時の errorLogs 用)
    private var errorLogs: [String] = []

    public init(scenarioID: String, platform: String, title: String?, worker: String?) {
        self.scenarioID = scenarioID
        self.platform = platform
        self.title = title
        self.worker = worker
    }

    public mutating func consume(_ event: ScenarioEvent) {
        switch event.kind {
        case "sceneStarted":
            if let scene = event.scene {
                sceneTitles[scene] = event.sceneTitle ?? sceneTitles[scene] ?? ""
            }
        case "step":
            consumeStep(event)
        case "sceneFinished":
            consumeSceneFinished(event)
        case "fixSuggestion":
            fixSuggestions.append(FixSuggestionRecord(
                scene: event.scene, file: event.file, line: event.line,
                oldSelector: event.oldSelector, newSelector: event.newSelector))
        case "scenarioFinished":
            reportPath = event.reportPath
            fm = event.fm
        case "log":
            if let message = event.message,
               message.hasPrefix("❌") || message.hasPrefix("⚠️") || message.hasPrefix("⏱") {
                errorLogs.append(message)
                if errorLogs.count > 5 { errorLogs.removeFirst() }
            }
        default:
            break
        }
    }

    private mutating func consumeStep(_ event: ScenarioEvent) {
        if let scene = event.scene, let duration = event.durationMs {
            sceneDurationAccum[scene, default: 0] += duration
        }
        guard let status = event.status else { return }
        stepCounts.total += 1
        // 録画再生 UI のステップツリー用: 成否によらず到着順のまま全ステップを積む
        timeline.append(TimelineStepRecord(
            scene: event.scene, sceneTitle: event.sceneTitle ?? event.scene.flatMap { sceneTitles[$0] },
            index: event.index ?? 0, description: event.description ?? "",
            status: status, at: event.at, durationMs: event.durationMs,
            notes: event.notes?.isEmpty == true ? nil : event.notes))
        if event.notes?.contains(StepNote.heldValue.rawValue) == true {
            stepCounts.viaHeldValue = (stepCounts.viaHeldValue ?? 0) + 1
        }
        switch status {
        case "passed":
            stepCounts.passed += 1
        case "passedViaFallback":
            stepCounts.passedViaFallback += 1
        case "healed":
            stepCounts.healed += 1
        case "skipped":
            stepCounts.skipped += 1
        case "inconclusive":
            stepCounts.inconclusive = (stepCounts.inconclusive ?? 0) + 1
        case "failed":
            stepCounts.failed += 1
            failedSteps.append(FailedStepRecord(
                index: event.index ?? 0, scene: event.scene,
                sceneTitle: event.sceneTitle ?? event.scene.flatMap { sceneTitles[$0] },
                section: event.section, description: event.description ?? "",
                command: event.command, failureKind: event.failureKind,
                notes: event.notes?.isEmpty == true ? nil : event.notes,
                detail: event.detail, file: event.file, line: event.line,
                durationMs: event.durationMs, at: event.at))
        default:
            break
        }
    }

    private mutating func consumeSceneFinished(_ event: ScenarioEvent) {
        let scene = event.scene ?? 0
        let title = event.sceneTitle ?? sceneTitles[scene] ?? ""
        let passed = event.passed ?? true
        let durationMs = event.durationMs ?? sceneDurationAccum[scene]
        scenes.append(SceneResultRecord(scene: scene, title: title, passed: passed, durationMs: durationMs))
    }

    public func build(passed: Bool, timedOut: Bool, startedAt: Date, durationMs: Int,
                      packageRoot: URL?) -> ScenarioRunRecord {
        let formatter = ISO8601DateFormatter()
        return ScenarioRunRecord(
            scenarioID: scenarioID, title: title, platform: platform, worker: worker,
            passed: passed, timedOut: timedOut, startedAt: formatter.string(from: startedAt),
            durationMs: durationMs, scenes: scenes, steps: stepCounts,
            reportPath: Self.relativize(reportPath, packageRoot: packageRoot),
            failedSteps: passed ? nil : (failedSteps.isEmpty ? nil : failedSteps),
            // **修正提案は成否によらず残す**(fm と同じ理由)。強い提案が出るのは自己修復か
            // ヒールキャッシュで**通ったとき**なので、passed で捨てると
            // 「緑だがセレクタは壊れている」という一番知りたい状態の記録が1件も残らない
            // (実測: 89,025 記録すべてで fixSuggestions が空だった)
            fixSuggestions: fixSuggestions.isEmpty ? nil : fixSuggestions,
            errorLogs: passed ? nil : (errorLogs.isEmpty ? nil : errorLogs),
            // FM 実測は成否によらず残す(コスト分析は成功実行こそ必要)
            fm: fm,
            // timeline も成否によらず残す(録画再生 UI は成功シナリオでもステップツリーを出す)
            timeline: timeline.isEmpty ? nil : timeline)
    }

    private static func relativize(_ path: String?, packageRoot: URL?) -> String? {
        guard let path, let packageRoot else { return path }
        let rootPath = packageRoot.standardizedFileURL.path
        let prefix = rootPath.hasSuffix("/") ? rootPath : rootPath + "/"
        guard path.hasPrefix(prefix) else { return path }
        return String(path.dropFirst(prefix.count))
    }
}
