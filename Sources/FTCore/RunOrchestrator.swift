// RunOrchestrator.swift
// フロー並列実行のオーケストレーション。CLI(ftester run --ports)と GUI の両方が使う。
// FTCore は FoundationModels に依存しない(FM フックは ReplayDelegate 経由)。
// ドライバはプラットフォーム非依存を保つため呼び出し側が構築して RunWorker で注入する。

import Foundation

/// 実行対象フロー。URL がフローの一意キー(GUI の FlowEntry.id とも一致)
public struct FlowRunItem: Identifiable, Sendable {
    public let url: URL
    public let flow: Flow
    public var id: URL { url }

    public init(url: URL, flow: Flow) {
        self.url = url
        self.flow = flow
    }
}

/// 並列ワーカー定義。platform が一致するフローだけをキューから消化する
public struct RunWorker {
    public let label: String      // 例: "ios:8123" / "android"
    public let platform: String   // "ios" / "android"
    public let driver: AppDriver

    public init(label: String, platform: String, driver: AppDriver) {
        self.label = label
        self.platform = platform
        self.driver = driver
    }
}

/// 実行の進捗イベント。flowURL でフローを識別する(GUI は URL で state を更新)
public enum RunEvent: Sendable {
    case runStarted(total: Int, workerLabels: [String])
    /// ウォームアップ完了(コールドブート対策の snapshot 済み)
    case workerReady(worker: String)
    /// 接続不能などでワーカーが離脱した(他ワーカーが残キューを引き継ぐ)
    case workerFailed(worker: String, message: String)
    case flowStarted(worker: String, flowURL: URL, flowName: String, isDirty: Bool)
    case step(worker: String, flowURL: URL, result: StepResult)
    /// 自己修復したロケータでフローを上書き保存した
    case flowHealed(worker: String, flowURL: URL)
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

/// 並列ワーカーへのフロー分配キュー(早い者勝ち)
actor FlowQueue {
    private var items: [FlowRunItem]
    init(_ items: [FlowRunItem]) { self.items = items }
    func next() -> FlowRunItem? { items.isEmpty ? nil : items.removeFirst() }
}

/// 1フローの実行(heal 時のフロー上書き保存・失敗レポート出力込み)。
/// CLI の逐次実行と RunOrchestrator のワーカーの両方がここを通る。
public enum FlowRunner {
    /// 戻り値: passed。進捗は onEvent で同期通知される(Replayer.onStep は非 async クロージャ)
    public static func runOne(item: FlowRunItem, driver: AppDriver, worker: String,
                              delegate: ReplayDelegate?, healingEnabled: Bool, reportDir: URL,
                              onEvent: @escaping (RunEvent) -> Void) async -> Bool {
        onEvent(.flowStarted(worker: worker, flowURL: item.url,
                             flowName: item.url.lastPathComponent,
                             isDirty: item.flow.dirty == true))

        let replayer = Replayer(driver: driver, delegate: delegate, healingEnabled: healingEnabled)
        replayer.onStep = { step in
            onEvent(.step(worker: worker, flowURL: item.url, result: step))
        }
        let result = await replayer.run(flow: item.flow)

        if let healedFlow = result.healedFlow, healingEnabled {
            try? FlowIO.save(healedFlow, to: item.url)
            onEvent(.flowHealed(worker: worker, flowURL: item.url))
        }
        var reportURL: URL?
        if !result.passed {
            reportURL = try? ReportWriter.write(result: result, to: reportDir)
        }
        onEvent(.flowFinished(worker: worker, flowURL: item.url, passed: result.passed,
                              triage: result.triage, reportURL: reportURL))
        return result.passed
    }
}

/// フロー群をワーカー群で並列消化する。進捗は events(AsyncStream)で配信され、
/// run() の完了時に finish する。イベントはバッファされるため消費開始が遅れても失われない。
public final class RunOrchestrator {
    public let events: AsyncStream<RunEvent>
    private let continuation: AsyncStream<RunEvent>.Continuation
    private let workers: [RunWorker]
    private let delegate: ReplayDelegate?
    private let healingEnabled: Bool
    private let reportDir: URL

    public init(workers: [RunWorker], delegate: ReplayDelegate?,
                healingEnabled: Bool, reportDir: URL) {
        (self.events, self.continuation) = AsyncStream.makeStream(of: RunEvent.self)
        self.workers = workers
        self.delegate = delegate
        self.healingEnabled = healingEnabled
        self.reportDir = reportDir
    }

    public func run(items: [FlowRunItem], defaultPlatform: String) async -> RunSummary {
        let grouped = Dictionary(grouping: items) { $0.flow.platform ?? defaultPlatform }
        let workerPlatforms = Set(workers.map(\.platform))
        var failed = 0

        // 担当ワーカーのない platform のフローは即スキップ(失敗扱い)
        for (platform, list) in grouped where !workerPlatforms.contains(platform) {
            for item in list {
                continuation.yield(.flowSkipped(
                    flowURL: item.url,
                    reason: "担当ワーカーがありません(platform: \(platform))"))
            }
            failed += list.count
        }

        let queues = grouped.filter { workerPlatforms.contains($0.key) }
            .mapValues { FlowQueue($0) }

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

        // ワーカー全滅でキューに残ったフローは失敗扱い
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

    private func runWorker(_ worker: RunWorker, queue: FlowQueue) async -> Int {
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
            let passed = await FlowRunner.runOne(
                item: item, driver: worker.driver, worker: worker.label,
                delegate: delegate, healingEnabled: healingEnabled, reportDir: reportDir,
                onEvent: { [continuation] in continuation.yield($0) })
            if !passed { failed += 1 }
        }
        return failed
    }
}

/// RunEvent → 表示行の共通整形(CLI の従来出力と同一文字列。GUI もこれを使う)
public enum RunLogFormatter {
    public static func lines(for event: RunEvent) -> [String] {
        switch event {
        case .runStarted, .workerReady, .runFinished:
            return []
        case .workerFailed(let worker, let message):
            return ["❌ ワーカー \(worker) が離脱しました: \(message)"]
        case .flowStarted(let worker, _, let flowName, let isDirty):
            var lines = ["▶ \(flowName) [\(worker)]"]
            if isDirty { lines.append("  ⚠️ このフローは dirty(要レビュー)状態です") }
            return lines
        case .step(_, _, let result):
            return lines(for: result)
        case .flowHealed:
            return ["  🔧 修復したロケータでフローを更新しました(dirty: true — 要レビュー)"]
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
            return ["⚠️ \(flowURL.lastPathComponent) を実行できません: \(reason)", ""]
        }
    }

    public static func lines(for step: StepResult) -> [String] {
        switch step.status {
        case .passed:
            return ["  ✅ \(step.index). \(step.description)"]
        case .passedViaFallback(let locator):
            return ["  ✅ \(step.index). \(step.description)(フォールバック \(locator.summary))"]
        case .healed(let locator):
            return ["  🔧 \(step.index). \(step.description) → 自己修復: \(locator.summary)"]
        case .failed(let reason):
            return ["  ❌ \(step.index). \(step.description)", "     \(reason)"]
        case .skipped(let reason):
            return ["  ⚠️ \(step.index). \(step.description)(スキップ: \(reason))"]
        }
    }
}
