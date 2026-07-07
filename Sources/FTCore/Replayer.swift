// Replayer.swift
// M3: フローの決定的再生。FM はループに入らない(高速・安定・CI向き)。
// FM が関与するのは失敗時のみ:
// - ロケータ不一致 → ReplayDelegate.healLocator(自己修復)
// - screenMatches アサーション → ReplayDelegate.verifyScreen(マルチモーダル検証)
// - 失敗確定時 → ReplayDelegate.triage(原因分類・レポート)

import Foundation

public struct TriageInfo: Sendable {
    /// appBug / flakiness / locatorDrift / envIssue
    public let failureClass: String
    public let summary: String
    public let suggestedFix: String

    public init(failureClass: String, summary: String, suggestedFix: String) {
        self.failureClass = failureClass
        self.summary = summary
        self.suggestedFix = suggestedFix
    }
}

public struct HealProposal: Sendable {
    public let element: ElementInfo
    /// high / medium / low
    public let confidence: String
    public let rationale: String

    public init(element: ElementInfo, confidence: String, rationale: String) {
        self.element = element
        self.confidence = confidence
        self.rationale = rationale
    }
}

/// FM フック。実装は FTAgent 側(FTCore は FoundationModels に依存しない)。
public protocol ReplayDelegate: AnyObject {
    func healLocator(step: FlowStep, snapshot: SnapshotResponse) async -> HealProposal?
    func verifyScreen(expected: String, screenshotPNG: Data) async -> (pass: Bool, reason: String)?
    func triage(goal: String?, stepDescription: String, failureReason: String,
                snapshot: SnapshotResponse?, screenshotPNG: Data?) async -> TriageInfo?
}

public struct StepResult: Sendable {
    public enum Status: Sendable {
        case passed
        case passedViaFallback(FlowLocator)
        case healed(FlowLocator)
        case failed(String)
        case skipped(String)
    }
    public let index: Int
    public let description: String
    public let status: Status
}

public struct RunResult: Sendable {
    public let flow: Flow
    public var steps: [StepResult] = []
    /// 自己修復でロケータが書き換わったフロー(dirty: true 付き)。保存は呼び出し側の判断
    public var healedFlow: Flow?
    public var triage: TriageInfo?
    public var failureScreenshot: Data?

    public var passed: Bool {
        steps.allSatisfy {
            switch $0.status {
            case .failed: return false
            default: return true
            }
        }
    }
}

public final class Replayer {
    let driver: AppDriver
    public weak var delegate: ReplayDelegate?
    public var healingEnabled: Bool
    /// 進捗コールバック(結果確定毎に呼ばれる)
    public var onStep: ((StepResult) -> Void)?

    public init(driver: AppDriver, delegate: ReplayDelegate? = nil, healingEnabled: Bool = false) {
        self.driver = driver
        self.delegate = delegate
        self.healingEnabled = healingEnabled
    }

    public func run(flow: Flow) async -> RunResult {
        var result = RunResult(flow: flow)
        var healedSteps: [Int: FlowStep] = [:]

        do {
            try await driver.launch(bundleID: flow.app)
            try await Task.sleep(nanoseconds: 1_200_000_000)
        } catch {
            let stepResult = StepResult(index: 0, description: "launch \(flow.app)",
                                        status: .failed("起動失敗: \(error.localizedDescription)"))
            result.steps.append(stepResult)
            onStep?(stepResult)
            return result
        }

        for (index, step) in flow.steps.enumerated() {
            let stepResult = await execute(step: step, index: index + 1,
                                           flow: flow, healedSteps: &healedSteps)
            result.steps.append(stepResult)
            onStep?(stepResult)

            if case .failed(let reason) = stepResult.status {
                // 失敗確定 → トリアージして終了(以降のステップは前提が崩れている)
                let snapshot = try? await driver.snapshot()
                let screenshot = try? await driver.screenshot()
                result.failureScreenshot = screenshot
                if let delegate {
                    result.triage = await delegate.triage(
                        goal: flow.goal,
                        stepDescription: step.summary,
                        failureReason: reason,
                        snapshot: snapshot,
                        screenshotPNG: screenshot)
                }
                break
            }
        }

        if !healedSteps.isEmpty {
            var healed = flow
            for (index, step) in healedSteps { healed.steps[index] = step }
            healed.dirty = true
            result.healedFlow = healed
        }
        return result
    }

    // MARK: - ステップ実行

    private func execute(step: FlowStep, index: Int, flow: Flow,
                         healedSteps: inout [Int: FlowStep]) async -> StepResult {
        do {
            if let action = step.action {
                return try await executeAction(action, step: step, index: index,
                                               healedSteps: &healedSteps)
            }
            if let assert = step.assert {
                return try await executeAssert(assert, step: step, index: index)
            }
            return StepResult(index: index, description: step.summary,
                              status: .skipped("action も assert もないステップ"))
        } catch {
            return StepResult(index: index, description: step.summary,
                              status: .failed("実行エラー: \(error.localizedDescription)"))
        }
    }

    private func executeAction(_ action: String, step: FlowStep, index: Int,
                               healedSteps: inout [Int: FlowStep]) async throws -> StepResult {
        // ロケータ不要のアクション
        if action == "swipe" {
            let direction = FTSwipeDirection(rawValue: step.direction ?? "") ?? .up
            try await driver.swipe(direction)
            try await Task.sleep(nanoseconds: 800_000_000)
            return StepResult(index: index, description: step.summary, status: .passed)
        }

        // 要素が見つかるまでスクロール(見つかったら成功。操作はしない)
        if action == "scrollTo" {
            let direction = FTSwipeDirection(rawValue: step.direction ?? "") ?? .up
            let maxSwipes = step.maxSwipes ?? 8
            for attempt in 0...maxSwipes {
                let snapshot = try await driver.snapshot()
                // スクロール探索でも type+index フォールバックは偽陽性のもとなので使わない
                if let (_, fallback) = resolve(step: step, in: snapshot, strictForAssert: true) {
                    if let fallback {
                        return StepResult(index: index, description: step.summary,
                                          status: .passedViaFallback(fallback))
                    }
                    return StepResult(index: index, description: step.summary, status: .passed)
                }
                if attempt < maxSwipes {
                    try await driver.swipe(direction)
                    try await Task.sleep(nanoseconds: 600_000_000)
                }
            }
            return StepResult(index: index, description: step.summary,
                              status: .failed("\(maxSwipes) 回スクロールしても要素が見つかりません: \(step.locatorSummary)"))
        }

        // ロケータ解決(1秒待って1回だけ再試行 — UI 遷移直後対策)
        var snapshot = try await driver.snapshot()
        var resolved = resolve(step: step, in: snapshot)
        if resolved == nil {
            try await Task.sleep(nanoseconds: 1_000_000_000)
            snapshot = try await driver.snapshot()
            resolved = resolve(step: step, in: snapshot)
        }

        var status: StepResult.Status = .passed
        var element: ElementInfo

        if let (found, usedFallback) = resolved {
            element = found
            if let fallback = usedFallback { status = .passedViaFallback(fallback) }
        } else if step.optional == true {
            // 出るかどうか不定な要素(システムダイアログ等)。無ければ何もしないで先へ進む。
            // 自己修復の対象にもしない(別要素への誤リダイレクトを防ぐ)
            return StepResult(index: index, description: step.summary,
                              status: .skipped("要素が見つからないため省略(optional)"))
        } else if healingEnabled, let delegate,
                  let proposal = await delegate.healLocator(step: step, snapshot: snapshot),
                  proposal.confidence == "high" {
            // 自己修復: 新しいロケータ連鎖に置き換えたステップを記録(dirty で保存される)
            element = proposal.element
            let (primary, fallbacks) = FlowLocatorBuilder.chain(for: element, in: snapshot.elements)
            var healed = step
            healed.locator = primary
            healed.fallbacks = fallbacks.isEmpty ? nil : fallbacks
            healed.note = (step.note.map { $0 + " / " } ?? "") + "自己修復: \(proposal.rationale)"
            healedSteps[index - 1] = healed
            status = .healed(primary)
        } else {
            return StepResult(index: index, description: step.summary,
                              status: .failed("ロケータを解決できません: \(step.locatorSummary)"))
        }

        switch action {
        case "tap":
            try await driver.tap(ref: element.ref)
        case "type":
            try await driver.type(ref: element.ref, text: step.text ?? "")
        case "press":
            try await driver.press(ref: element.ref, duration: 1.0)
        default:
            return StepResult(index: index, description: step.summary,
                              status: .skipped("未知のアクション: \(action)"))
        }
        try await Task.sleep(nanoseconds: 800_000_000)
        return StepResult(index: index, description: step.summary, status: status)
    }

    private func executeAssert(_ assert: String, step: FlowStep, index: Int) async throws -> StepResult {
        switch assert {
        case "exists":
            let deadline = Date().addingTimeInterval(TimeInterval(step.timeout ?? 5))
            while Date() < deadline {
                let snapshot = try await driver.snapshot()
                // アサーションでは type+index のみのフォールバックを使わない。
                // 別画面の無関係な要素にマッチして偽陽性になる(実測済み)
                if let (_, fallback) = resolve(step: step, in: snapshot, strictForAssert: true) {
                    if let fallback {
                        return StepResult(index: index, description: step.summary,
                                          status: .passedViaFallback(fallback))
                    }
                    return StepResult(index: index, description: step.summary, status: .passed)
                }
                try await Task.sleep(nanoseconds: 1_000_000_000)
            }
            return StepResult(index: index, description: step.summary,
                              status: .failed("要素が見つかりません: \(step.locatorSummary)(timeout \(step.timeout ?? 5)s)"))

        case "valueEquals":
            guard let expected = step.expected else {
                return StepResult(index: index, description: step.summary,
                                  status: .skipped("expected が未指定"))
            }
            let deadline = Date().addingTimeInterval(TimeInterval(step.timeout ?? 5))
            var lastActual: String?
            var found = false
            while Date() < deadline {
                let snapshot = try await driver.snapshot()
                if let (element, fallback) = resolve(step: step, in: snapshot, strictForAssert: true) {
                    found = true
                    lastActual = element.value
                    if element.value == expected {
                        if let fallback {
                            return StepResult(index: index, description: step.summary,
                                              status: .passedViaFallback(fallback))
                        }
                        return StepResult(index: index, description: step.summary, status: .passed)
                    }
                }
                try await Task.sleep(nanoseconds: 1_000_000_000)
            }
            let reason = found
                ? "値が一致しません: 期待 \"\(expected)\"、実際 \"\(lastActual ?? "nil")\""
                : "要素が見つかりません: \(step.locatorSummary)"
            return StepResult(index: index, description: step.summary, status: .failed(reason))

        case "screenMatches":
            guard let expected = step.expected, !expected.isEmpty else {
                return StepResult(index: index, description: step.summary,
                                  status: .skipped("expected が未指定"))
            }
            guard let delegate else {
                return StepResult(index: index, description: step.summary,
                                  status: .skipped("FM 検証が無効(Foundation Models 利用不可)"))
            }
            let screenshot = try await driver.screenshot()
            guard let verdict = await delegate.verifyScreen(expected: expected, screenshotPNG: screenshot) else {
                return StepResult(index: index, description: step.summary,
                                  status: .skipped("画面検証を実行できませんでした"))
            }
            if verdict.pass {
                return StepResult(index: index, description: step.summary, status: .passed)
            }
            return StepResult(index: index, description: step.summary,
                              status: .failed("画面が期待と一致しません: \(verdict.reason)"))

        default:
            return StepResult(index: index, description: step.summary,
                              status: .skipped("未知のアサーション: \(assert)"))
        }
    }

    // MARK: - ロケータ解決(決定的)

    /// 戻り値: (要素, 使用したフォールバック)。プライマリで解決した場合フォールバックは nil
    /// strictForAssert: id も label もない(type+index のみの)フォールバックを除外する
    func resolve(step: FlowStep, in snapshot: SnapshotResponse,
                 strictForAssert: Bool = false) -> (ElementInfo, FlowLocator?)? {
        var chain: [(FlowLocator, isPrimary: Bool)] = []
        if let locator = step.locator { chain.append((locator, true)) }
        for fallback in step.fallbacks ?? [] {
            if strictForAssert, fallback.id == nil, fallback.label == nil { continue }
            chain.append((fallback, false))
        }

        for (locator, isPrimary) in chain {
            if let element = match(locator, in: snapshot) {
                return (element, isPrimary ? nil : locator)
            }
        }
        return nil
    }

    func match(_ locator: FlowLocator, in snapshot: SnapshotResponse) -> ElementInfo? {
        // type は絞り込み条件として id/label と併用できる
        // (同じ id が Cell/Switch/Button に付くことがあり、値検証では型の指定が必要)
        var candidates = snapshot.elements
        if let type = locator.type {
            candidates = candidates.filter { $0.type == type }
        }
        if let id = locator.id {
            return candidates.first { $0.identifier == id }
        }
        if let label = locator.label {
            return candidates.first { $0.label == label }
                ?? candidates.first { ($0.label ?? "").contains(label) }
        }
        if locator.type != nil {
            let index = locator.index ?? 0
            return index < candidates.count ? candidates[index] : nil
        }
        return nil
    }
}

public extension FlowStep {
    var summary: String {
        if let action {
            switch action {
            case "type": return "type \(locatorSummary) \"\(text ?? "")\""
            case "swipe": return "swipe \(direction ?? "up")"
            case "scrollTo": return "scrollTo \(locatorSummary)"
            default: return "\(action) \(locatorSummary)"
            }
        }
        if let assert {
            if assert == "screenMatches" { return "assert screenMatches \"\(expected ?? "")\"" }
            if assert == "valueEquals" { return "assert valueEquals \(locatorSummary) == \"\(expected ?? "")\"" }
            return "assert \(assert) \(locatorSummary)"
        }
        return "(空ステップ)"
    }

    var locatorSummary: String {
        var parts: [String] = []
        if let locator { parts.append(locator.summary) }
        if let fallbacks, !fallbacks.isEmpty {
            parts.append("(fallback: \(fallbacks.map(\.summary).joined(separator: " → ")))")
        }
        return parts.isEmpty ? "(ロケータなし)" : parts.joined(separator: " ")
    }
}
