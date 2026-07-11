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
    case flowStarted(worker: String, flowURL: URL, flowName: String, isDirty: Bool)
    /// scene 開始(ScenarioEvent kind "sceneStarted" 相当)
    case sceneStarted(worker: String, flowURL: URL, scene: Int, sceneTitle: String)
    case step(worker: String, flowURL: URL, result: StepResult)
    /// scene 終了(ScenarioEvent kind "sceneFinished" 相当)。passed = その scene の合否
    case sceneFinished(worker: String, flowURL: URL, scene: Int, sceneTitle: String, passed: Bool)
    /// デバッグ実行で一時停止した(index = 次に実行するステップ番号、file/line = その位置)
    case flowPaused(worker: String, flowURL: URL, index: Int, description: String,
                    file: String?, line: Int?)
    /// 自己修復したロケータでフローを上書き保存した(YAML 時代の互換。シナリオでは未使用)
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

    public init(total: Int, failed: Int) {
        self.total = total
        self.failed = failed
    }
}

/// 並列ワーカーへのシナリオ分配キュー(早い者勝ち)
actor ScenarioQueue {
    private var items: [ScenarioRunItem]
    init(_ items: [ScenarioRunItem]) { self.items = items }
    func next() -> ScenarioRunItem? { items.isEmpty ? nil : items.removeFirst() }
}

/// 1 シナリオの実行(サブプロセス起動+イベント変換)。
/// CLI の逐次実行と RunOrchestrator のワーカーの両方がここを通る。
public enum ScenarioRunner {
    /// 戻り値: passed。進捗は onEvent で通知される
    public static func runOne(project: TestProject, item: ScenarioRunItem, worker: RunWorker,
                              healingEnabled: Bool, reportDir: URL,
                              defaultTimeout: Int? = nil,
                              debug: ScenarioDebugOptions? = nil,
                              onEvent: @escaping (RunEvent) -> Void) async -> Bool {
        onEvent(.flowStarted(worker: worker.label, flowURL: item.url,
                             flowName: item.info.id, isDirty: false))

        var reportURL: URL?
        let passed = await ScenarioHost.run(
            project: project, scenarioID: item.info.id, connection: worker.connection,
            heal: healingEnabled, reportDir: reportDir.path,
            defaultTimeout: defaultTimeout, debug: debug) { event in
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
                // 「💡 修正提案: …」合成 step 行(実際のコマンド結果ではない)。
                // synthetic: true を立てて出す(人間向け表示は従来どおり残し、
                // 機械可読 NDJSON 側だけがこのフラグで除外する)
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

        onEvent(.flowFinished(worker: worker.label, flowURL: item.url, passed: passed,
                              triage: nil, reportURL: reportURL))
        return passed
    }

    /// ScenarioEvent(step)→ StepResult。scene/sceneTitle/section は構造化フィールドのまま写し、
    /// status も丸めずそのまま(passedViaFallback/healed の詳細は FlowLocator.raw に保持する。
    /// サブプロセス境界を跨ぐと構造化ロケータは失われ人間可読テキストしか残らないため)
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
        // 時間内訳(Phase 0 計測基盤)。サブプロセスの ScenarioEvent に durationMs が無ければ
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
    /// デバッグ実行(ブレークポイント・ステップ実行)。呼び出し側が単一シナリオ実行時のみ指定する
    private let debug: ScenarioDebugOptions?

    public init(project: TestProject, workers: [RunWorker], healingEnabled: Bool,
                reportDir: URL, defaultTimeout: Int? = nil,
                debug: ScenarioDebugOptions? = nil) {
        (self.events, self.continuation) = AsyncStream.makeStream(of: RunEvent.self)
        self.workers = workers
        self.healingEnabled = healingEnabled
        self.reportDir = reportDir
        self.project = project
        self.defaultTimeout = defaultTimeout
        self.debug = debug
    }

    public func run(items: [ScenarioRunItem], defaultPlatform: String) async -> RunSummary {
        let grouped = Dictionary(grouping: items) { $0.info.platform ?? defaultPlatform }
        let workerPlatforms = Set(workers.map(\.platform))
        var failed = 0

        // 担当ワーカーのない platform のシナリオは即スキップ(失敗扱い)
        for (platform, list) in grouped where !workerPlatforms.contains(platform) {
            for item in list {
                continuation.yield(.flowSkipped(
                    flowURL: item.url,
                    reason: "担当ワーカーがありません(platform: \(platform))"))
            }
            failed += list.count
        }

        let queues = grouped.filter { workerPlatforms.contains($0.key) }
            .mapValues { ScenarioQueue($0) }

        continuation.yield(.runStarted(total: items.count, workerLabels: workers.map(\.label)))

        failed += await withTaskGroup(of: Int.self, returning: Int.self) { group in
            for worker in workers {
                guard let queue = queues[worker.platform] else { continue }
                group.addTask { await self.runWorker(worker, queue: queue) }
            }
            var total = 0
            for await workerFailed in group { total += workerFailed }
            return total
        }

        // ワーカー全滅でキューに残ったシナリオは失敗扱い
        for (_, queue) in queues {
            while let item = await queue.next() {
                continuation.yield(.flowSkipped(flowURL: item.url,
                                                reason: "実行できるワーカーがありません"))
                failed += 1
            }
        }

        let summary = RunSummary(total: items.count, failed: failed)
        continuation.yield(.runFinished(passed: summary.passed, failed: summary.failed))
        continuation.finish()
        return summary
    }

    private func runWorker(_ worker: RunWorker, queue: ScenarioQueue) async -> Int {
        do {
            _ = try await worker.driver.status()
        } catch {
            continuation.yield(.workerFailed(worker: worker.label,
                                             message: "接続できません: \(error.localizedDescription)"))
            return 0
        }
        // コールドブート直後のシミュレータは最初の AX 問い合わせが極端に遅い
        // (kAXErrorIPCTimeout でランナーが落ちる)ため、snapshot で温める(リトライ1回)
        if (try? await worker.driver.snapshot()) == nil {
            _ = try? await worker.driver.snapshot()
        }
        continuation.yield(.workerReady(worker: worker.label))

        var failed = 0
        while let item = await queue.next() {
            let passed = await ScenarioRunner.runOne(
                project: project, item: item, worker: worker,
                healingEnabled: healingEnabled, reportDir: reportDir,
                defaultTimeout: defaultTimeout, debug: debug,
                onEvent: { [continuation] in continuation.yield($0) })
            if !passed { failed += 1 }
        }
        return failed
    }
}

/// RunEvent → 表示行の共通整形(CLI の出力と呼び出し側の実行レーン表示が共用)
public enum RunLogFormatter {
    public static func lines(for event: RunEvent) -> [String] {
        switch event {
        case .runStarted, .workerReady, .runFinished:
            return []
        case .sceneStarted, .sceneFinished:
            // scene の開始・終了(ScenarioRunner.runOne が emit する)。CLI や拡張側の表示は
            // 従来 flowStarted〜flowFinished の間の step 行だけで完結しており、
            // scene 区切りの専用行は無かったため、互換を保つためここでは意図的に空配列のまま
            // (scene/sceneTitle は各 step 行の構造化フィールドとして参照できる)
            return []
        case .workerFailed(let worker, let message):
            return ["❌ ワーカー \(worker) が離脱しました: \(message)"]
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
        // section("condition"/"action"/"expectation")は従来 description 先頭への
        // "[section] " プレフィックス折り込みだった見た目をここで再現する(section は
        // stepResult(from:) 以降は構造化フィールドとして独立して保持されている)
        let description = (step.section.map { "[\($0)] " } ?? "") + step.description
        switch step.status {
        case .passed:
            // index 0 = ステップ以外の情報行(修正提案・ユーザー print 等)
            if step.index == 0 { return ["  \(description)"] }
            return ["  ✅ \(step.index). \(description)"]
        case .passedViaFallback(let locator), .healed(let locator):
            // 従来 stepResult(from:) が passedViaFallback/healed を "passed" に丸め、
            // description 末尾へ "(detail)" を畳み込んでいたときと同じ見た目にする
            // (locator.summary は FlowLocator.raw = ScenarioEvent.detail そのもの)
            return ["  ✅ \(step.index). \(description)(\(locator.summary))"]
        case .failed(let reason):
            return ["  ❌ \(step.index). \(description)", "     \(reason)"]
        case .skipped(let reason):
            return ["  ⚠️ \(step.index). \(description)(スキップ: \(reason))"]
        }
    }
}
