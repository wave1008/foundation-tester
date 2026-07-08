// StepExecutor.swift
// 単一 FlowStep の決定的実行エンジン(Swift DSL のコマンドは全てここを通る)。
// 実証済みのセマンティクス:
// - ロケータ解決失敗は 1 秒後に 1 回だけ再試行(UI 遷移直後対策)
// - アサーションでは type+index のみのフォールバックを使わない(別画面要素への偽陽性防止)
// - optional ステップは要素未発見でも失敗にせずスキップ(自己修復の対象外)
// - 自己修復は delegate 提案の confidence == "high" のみ採用
// - 操作後 800ms 待機、exists/valueEquals/textEquals はタイムアウトまでポーリング

import Foundation

// MARK: - FM フックと結果型(FTCore は FoundationModels に依存しない)

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

/// FM フック。実装は FTAgent 側(失敗時のみ呼ばれる: 自己修復・画面検証・トリアージ)。
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

    public init(index: Int, description: String, status: Status) {
        self.index = index
        self.description = description
        self.status = status
    }
}

/// 1 ステップの実行結果。自己修復が発生した場合は差し替え済みステップを返す(永続化は呼び出し側の判断)
public struct StepOutcome: Sendable {
    public let status: StepResult.Status
    public let healedStep: FlowStep?
    /// true = ヒールキャッシュで解決(FM 不使用)。false で healedStep あり = FM 自己修復
    public let healedByCache: Bool

    public init(status: StepResult.Status, healedStep: FlowStep? = nil, healedByCache: Bool = false) {
        self.status = status
        self.healedStep = healedStep
        self.healedByCache = healedByCache
    }
}

public final class StepExecutor {
    public let driver: AppDriver
    public var delegate: ReplayDelegate?
    public var healingEnabled: Bool

    public init(driver: AppDriver, delegate: ReplayDelegate? = nil, healingEnabled: Bool = false) {
        self.driver = driver
        self.delegate = delegate
        self.healingEnabled = healingEnabled
    }

    /// cached: ヒールキャッシュ由来のロケータ連鎖。解決順は
    /// プライマリ → フォールバック → キャッシュ → FM ヒール(アクションのみ)
    public func execute(_ step: FlowStep, cached: [FlowLocator] = []) async -> StepOutcome {
        do {
            if let action = step.action {
                return try await executeAction(action, step: step, cached: cached)
            }
            if let assert = step.assert {
                return StepOutcome(status: try await executeAssert(assert, step: step))
            }
            return StepOutcome(status: .skipped("action も assert もないステップ"))
        } catch {
            return StepOutcome(status: .failed("実行エラー: \(error.localizedDescription)"))
        }
    }

    // MARK: - アクション

    private func executeAction(_ action: String, step: FlowStep,
                               cached: [FlowLocator] = []) async throws -> StepOutcome {
        // ロケータ不要のアクション
        if action == "swipe" {
            let direction = FTSwipeDirection(rawValue: step.direction ?? "") ?? .up
            try await driver.swipe(direction)
            try await Task.sleep(nanoseconds: 800_000_000)
            return StepOutcome(status: .passed)
        }

        // 要素が見つかるまでスクロール(見つかったら成功。操作はしない)
        if action == "scrollTo" {
            let direction = FTSwipeDirection(rawValue: step.direction ?? "") ?? .up
            let maxSwipes = step.maxSwipes ?? 8
            for attempt in 0...maxSwipes {
                let snapshot = try await driver.snapshot()
                // スクロール探索でも type+index フォールバックは偽陽性のもとなので使わない
                if let (_, fallback) = Self.resolve(step: step, in: snapshot, strictForAssert: true) {
                    if let fallback {
                        return StepOutcome(status: .passedViaFallback(fallback))
                    }
                    return StepOutcome(status: .passed)
                }
                if attempt < maxSwipes {
                    try await driver.swipe(direction)
                    try await Task.sleep(nanoseconds: 600_000_000)
                }
            }
            return StepOutcome(status: .failed(
                "\(maxSwipes) 回スクロールしても要素が見つかりません: \(step.locatorSummary)"))
        }

        // ロケータ解決(1秒待って1回だけ再試行 — UI 遷移直後対策)
        var snapshot = try await driver.snapshot()
        var resolved = Self.resolve(step: step, in: snapshot)
        if resolved == nil {
            try await Task.sleep(nanoseconds: 1_000_000_000)
            snapshot = try await driver.snapshot()
            resolved = Self.resolve(step: step, in: snapshot)
        }

        var status: StepResult.Status = .passed
        var healedStep: FlowStep?
        var healedByCache = false
        var element: ElementInfo

        if let (found, usedFallback) = resolved {
            element = found
            if let fallback = usedFallback { status = .passedViaFallback(fallback) }
        } else if let (found, locator) = matchCached(cached, in: snapshot) {
            // ヒールキャッシュ命中: FM なしで決定的に解決(healed 扱いで記録し、提案を出し続ける)
            element = found
            var healed = step
            healed.locator = locator
            healed.fallbacks = cached.count > 1 ? cached.filter { $0 != locator } : nil
            healedStep = healed
            healedByCache = true
            status = .healed(locator)
        } else if step.optional == true {
            // 出るかどうか不定な要素(システムダイアログ等)。無ければ何もしないで先へ進む。
            // 自己修復の対象にもしない(別要素への誤リダイレクトを防ぐ)
            return StepOutcome(status: .skipped("要素が見つからないため省略(optional)"))
        } else if healingEnabled, let delegate,
                  let proposal = await delegate.healLocator(step: step, snapshot: snapshot),
                  proposal.confidence == "high" {
            // 自己修復: 新しいロケータ連鎖に置き換えたステップを返す(永続化は呼び出し側)
            element = proposal.element
            let (primary, fallbacks) = FlowLocatorBuilder.chain(for: element, in: snapshot.elements)
            var healed = step
            healed.locator = primary
            healed.fallbacks = fallbacks.isEmpty ? nil : fallbacks
            healed.note = (step.note.map { $0 + " / " } ?? "") + "自己修復: \(proposal.rationale)"
            healedStep = healed
            status = .healed(primary)
        } else {
            return StepOutcome(status: .failed("ロケータを解決できません: \(step.locatorSummary)"))
        }

        switch action {
        case "tap":
            try await driver.tap(ref: element.ref)
        case "type":
            try await driver.type(ref: element.ref, text: step.text ?? "")
        case "press":
            try await driver.press(ref: element.ref, duration: 1.0)
        default:
            return StepOutcome(status: .skipped("未知のアクション: \(action)"))
        }
        try await Task.sleep(nanoseconds: 800_000_000)
        return StepOutcome(status: status, healedStep: healedStep, healedByCache: healedByCache)
    }

    /// ヒールキャッシュのロケータ連鎖を順に照合する
    private func matchCached(_ cached: [FlowLocator],
                             in snapshot: SnapshotResponse) -> (ElementInfo, FlowLocator)? {
        for locator in cached {
            if let element = Self.match(locator, in: snapshot) {
                return (element, locator)
            }
        }
        return nil
    }

    // MARK: - アサーション

    private func executeAssert(_ assert: String, step: FlowStep) async throws -> StepResult.Status {
        switch assert {
        case "exists":
            let deadline = Date().addingTimeInterval(TimeInterval(step.timeout ?? 5))
            while Date() < deadline {
                let snapshot = try await driver.snapshot()
                // アサーションでは type+index のみのフォールバックを使わない。
                // 別画面の無関係な要素にマッチして偽陽性になる(実測済み)
                if let (_, fallback) = Self.resolve(step: step, in: snapshot, strictForAssert: true) {
                    if let fallback { return .passedViaFallback(fallback) }
                    return .passed
                }
                try await Task.sleep(nanoseconds: 1_000_000_000)
            }
            return .failed("要素が見つかりません: \(step.locatorSummary)(timeout \(step.timeout ?? 5)s)")

        case "valueEquals", "textEquals":
            guard let expected = step.expected else {
                return .skipped("expected が未指定")
            }
            let deadline = Date().addingTimeInterval(TimeInterval(step.timeout ?? 5))
            var lastActual: String?
            var found = false
            while Date() < deadline {
                let snapshot = try await driver.snapshot()
                if let (element, fallback) = Self.resolve(step: step, in: snapshot, strictForAssert: true) {
                    found = true
                    let actual = assert == "textEquals" ? element.label : element.value
                    lastActual = actual
                    if actual == expected {
                        if let fallback { return .passedViaFallback(fallback) }
                        return .passed
                    }
                }
                try await Task.sleep(nanoseconds: 1_000_000_000)
            }
            let subject = assert == "textEquals" ? "テキスト" : "値"
            return found
                ? .failed("\(subject)が一致しません: 期待 \"\(expected)\"、実際 \"\(lastActual ?? "nil")\"")
                : .failed("要素が見つかりません: \(step.locatorSummary)")

        case "screenMatches":
            guard let expected = step.expected, !expected.isEmpty else {
                return .skipped("expected が未指定")
            }
            guard let delegate else {
                return .skipped("FM 検証が無効(Foundation Models 利用不可)")
            }
            let screenshot = try await driver.screenshot()
            guard let verdict = await delegate.verifyScreen(expected: expected, screenshotPNG: screenshot) else {
                return .skipped("画面検証を実行できませんでした")
            }
            if verdict.pass { return .passed }
            return .failed("画面が期待と一致しません: \(verdict.reason)")

        default:
            return .skipped("未知のアサーション: \(assert)")
        }
    }

    // MARK: - ロケータ解決(決定的)

    /// 戻り値: (要素, 使用したフォールバック)。プライマリで解決した場合フォールバックは nil
    /// strictForAssert: id も label もない(type+index のみの)フォールバックを除外する
    public static func resolve(step: FlowStep, in snapshot: SnapshotResponse,
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

    public static func match(_ locator: FlowLocator, in snapshot: SnapshotResponse) -> ElementInfo? {
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
