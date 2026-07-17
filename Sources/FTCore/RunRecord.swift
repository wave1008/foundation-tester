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
    public var degradedWorkers: [String]?
    /// 凍結等による結果取り消し+振り直しの監査記録(成功した振り直しはシナリオ記録に痕跡を
    /// 残さないため、ここが唯一の証跡)。空/未発生は nil で省略。
    public var freezeRetries: [String]?

    public init(schemaVersion: Int = RunRecordSchema.current, runID: String, project: String,
                profile: String?, machine: String, trigger: String, startedAt: String,
                finishedAt: String? = nil, total: Int? = nil, passed: Int? = nil,
                failed: Int? = nil, degradedWorkers: [String]? = nil,
                freezeRetries: [String]? = nil) {
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

    public init(total: Int = 0, passed: Int = 0, failed: Int = 0, skipped: Int = 0,
                healed: Int = 0, passedViaFallback: Int = 0) {
        self.total = total
        self.passed = passed
        self.failed = failed
        self.skipped = skipped
        self.healed = healed
        self.passedViaFallback = passedViaFallback
    }
}

public struct FailedStepRecord: Codable, Sendable {
    public var index: Int
    public var scene: Int?
    public var sceneTitle: String?
    public var section: String?
    public var description: String
    public var detail: String?
    public var file: String?
    public var line: Int?
    public var durationMs: Int?

    public init(index: Int, scene: Int? = nil, sceneTitle: String? = nil, section: String? = nil,
                description: String, detail: String? = nil, file: String? = nil,
                line: Int? = nil, durationMs: Int? = nil) {
        self.index = index
        self.scene = scene
        self.sceneTitle = sceneTitle
        self.section = section
        self.description = description
        self.detail = detail
        self.file = file
        self.line = line
        self.durationMs = durationMs
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

    public init(schemaVersion: Int = RunRecordSchema.current, runID: String = "",
                scenarioID: String, title: String? = nil, platform: String, worker: String? = nil,
                machine: String = "", profile: String? = nil, passed: Bool, timedOut: Bool? = nil,
                startedAt: String, durationMs: Int, scenes: [SceneResultRecord] = [],
                steps: StepCountsRecord, reportPath: String? = nil,
                failedSteps: [FailedStepRecord]? = nil,
                fixSuggestions: [FixSuggestionRecord]? = nil,
                errorLogs: [String]? = nil) {
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
        switch status {
        case "passed":
            stepCounts.passed += 1
        case "passedViaFallback":
            stepCounts.passedViaFallback += 1
        case "healed":
            stepCounts.healed += 1
        case "skipped":
            stepCounts.skipped += 1
        case "failed":
            stepCounts.failed += 1
            failedSteps.append(FailedStepRecord(
                index: event.index ?? 0, scene: event.scene,
                sceneTitle: event.sceneTitle ?? event.scene.flatMap { sceneTitles[$0] },
                section: event.section, description: event.description ?? "",
                detail: event.detail, file: event.file, line: event.line,
                durationMs: event.durationMs))
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
            fixSuggestions: passed ? nil : (fixSuggestions.isEmpty ? nil : fixSuggestions),
            errorLogs: passed ? nil : (errorLogs.isEmpty ? nil : errorLogs))
    }

    private static func relativize(_ path: String?, packageRoot: URL?) -> String? {
        guard let path, let packageRoot else { return path }
        let rootPath = packageRoot.standardizedFileURL.path
        let prefix = rootPath.hasSuffix("/") ? rootPath : rootPath + "/"
        guard path.hasPrefix(prefix) else { return path }
        return String(path.dropFirst(prefix.count))
    }
}
