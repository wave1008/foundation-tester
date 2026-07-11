// StepExecutor.swift
// 単一 FlowStep の決定的実行エンジン(Swift DSL のコマンドは全てここを通る)。
// 実証済みのセマンティクス:
// - ロケータ解決失敗は指数バックオフ(100→200→400ms、計3回)で再試行してからヒールへ
//   (UI 遷移直後対策。ヒール発動までの総待機は計700msで、Phase 2 以前の1000ms台から
//   大きく変えていない)
// - アサーションでは type+index のみのフォールバックを使わない(別画面要素への偽陽性防止)
// - optional ステップは要素未発見でも失敗にせずスキップ(自己修復の対象外)
// - 自己修復は delegate 提案の confidence == "high" のみ採用
// - 操作後の整定待ちはドライバ側に委譲(Android: ブリッジの a11y 静穏検知 / iOS: XCUITest の
//   暗黙 quiescence)。Phase 2 でホスト側の固定 sleep は撤廃した。
//   exists/valueEquals/textEquals はタイムアウトまでポーリング(間隔は PollBackoff の
//   指数バックオフ = 100→200→400→800→1000ms 以降頭打ち。Phase 3 でポーリング間隔を統一)

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
    /// scene 番号(ScenarioEvent.scene 由来)。RunOrchestrator 経由(並列実行)でのみ設定され、
    /// StepExecutor が直接組み立てる場合は scene の概念を知らないため常に nil
    public let scene: Int?
    /// scene タイトル(ScenarioEvent.sceneTitle 由来)
    public let sceneTitle: String?
    /// condition / action / expectation(ScenarioEvent.section 由来。CAE ブロック外や
    /// scene の外で発生した情報行は nil)
    public let section: String?
    /// true = fixSuggestion に伴う合成行(「💡 修正提案: …」固定文言。ScenarioRunner.runOne
    /// 参照)。実際のコマンド実行結果ではないため、機械可読 NDJSON(ftester api run)では
    /// 除外する目印として使う(人間向けの表示では従来どおり残す)
    public let synthetic: Bool
    /// ステップの所要時間内訳(Phase 0 計測基盤)。--profile 並列実行ではサブプロセスの
    /// ScenarioEvent から復元される(ScenarioRunner.stepResult(from:) 参照)。合成行は nil
    public let timing: StepTiming?

    public init(index: Int, description: String, status: Status,
                scene: Int? = nil, sceneTitle: String? = nil, section: String? = nil,
                synthetic: Bool = false, timing: StepTiming? = nil) {
        self.index = index
        self.description = description
        self.status = status
        self.scene = scene
        self.sceneTitle = sceneTitle
        self.section = section
        self.synthetic = synthetic
        self.timing = timing
    }
}

/// ステップ 1 回分の時間内訳(計測は ContinuousClock。単位はミリ秒。Phase 0 計測基盤)。
/// durationMs はステップ全体の所要。snapshotMs/actionMs/waitMs は StepExecutor が計測できた
/// 場合のみ値が入る(launchApp/wait/procedure 等 performCustom 経由のステップは durationMs のみ)
public struct StepTiming: Sendable, Equatable {
    public var durationMs: Int
    public var snapshotMs: Int?
    public var actionMs: Int?
    public var waitMs: Int?

    public init(durationMs: Int, snapshotMs: Int? = nil, actionMs: Int? = nil, waitMs: Int? = nil) {
        self.durationMs = durationMs
        self.snapshotMs = snapshotMs
        self.actionMs = actionMs
        self.waitMs = waitMs
    }
}

/// 1 ステップの実行結果。自己修復が発生した場合は差し替え済みステップを返す(永続化は呼び出し側の判断)
public struct StepOutcome: Sendable {
    public let status: StepResult.Status
    public let healedStep: FlowStep?
    /// true = ヒールキャッシュで解決(FM 不使用)。false で healedStep あり = FM 自己修復
    public let healedByCache: Bool
    /// ステップの所要時間内訳(Phase 0 計測基盤)。実行エラー等で計測できなかった場合のみ nil
    public let timing: StepTiming?

    public init(status: StepResult.Status, healedStep: FlowStep? = nil, healedByCache: Bool = false,
               timing: StepTiming? = nil) {
        self.status = status
        self.healedStep = healedStep
        self.healedByCache = healedByCache
        self.timing = timing
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
        let clock = ContinuousClock()
        let start = clock.now
        var phase = PhaseAccumulator()
        do {
            if let action = step.action {
                let outcome = try await executeAction(action, step: step, cached: cached, phase: &phase)
                return StepOutcome(status: outcome.status, healedStep: outcome.healedStep,
                                   healedByCache: outcome.healedByCache,
                                   timing: StepTiming(durationMs: Self.ms(clock.now - start),
                                                      snapshotMs: phase.snapshotMs,
                                                      actionMs: phase.actionMs, waitMs: phase.waitMs))
            }
            if let assert = step.assert {
                let status = try await executeAssert(assert, step: step, phase: &phase)
                return StepOutcome(status: status,
                                   timing: StepTiming(durationMs: Self.ms(clock.now - start),
                                                      snapshotMs: phase.snapshotMs,
                                                      actionMs: phase.actionMs, waitMs: phase.waitMs))
            }
            return StepOutcome(status: .skipped("action も assert もないステップ"))
        } catch {
            return StepOutcome(status: .failed("実行エラー: \(error.localizedDescription)"),
                               timing: StepTiming(durationMs: Self.ms(clock.now - start),
                                                  snapshotMs: phase.snapshotMs,
                                                  actionMs: phase.actionMs, waitMs: phase.waitMs))
        }
    }

    /// execute(_:cached:) 1 回分の snapshot/action/wait 所要時間(ミリ秒)の積算値。
    /// 呼び出しの中だけで閉じるローカル値のため、並行アクセスの心配はない
    private struct PhaseAccumulator {
        var snapshotMs = 0
        var actionMs = 0
        var waitMs = 0
    }

    /// ContinuousClock の Duration → 整数ミリ秒(秒成分×1000 + attoseconds成分。
    /// 1ms = 1e15 attoseconds)
    private static func ms(_ duration: Duration) -> Int {
        let (seconds, attoseconds) = duration.components
        return Int(seconds) * 1000 + Int(attoseconds / 1_000_000_000_000_000)
    }

    // MARK: - アクション

    private func executeAction(_ action: String, step: FlowStep,
                               cached: [FlowLocator] = [],
                               phase: inout PhaseAccumulator) async throws -> StepOutcome {
        let clock = ContinuousClock()
        // ロケータ不要のアクション
        if action == "swipe" {
            let direction = FTSwipeDirection(rawValue: step.direction ?? "") ?? .up
            let start = clock.now
            try await driver.swipe(direction)
            phase.actionMs += Self.ms(clock.now - start)
            return StepOutcome(status: .passed)
        }

        // 要素が見つかるまでスクロール(見つかったら成功。操作はしない)
        if action == "scrollTo" {
            let direction = FTSwipeDirection(rawValue: step.direction ?? "") ?? .up
            let maxSwipes = step.maxSwipes ?? 8
            for attempt in 0...maxSwipes {
                var start = clock.now
                let snapshot = try await driver.snapshot()
                phase.snapshotMs += Self.ms(clock.now - start)
                // スクロール探索でも type+index フォールバックは偽陽性のもとなので使わない
                if let (_, fallback) = Self.resolve(step: step, in: snapshot, strictForAssert: true) {
                    if let fallback {
                        return StepOutcome(status: .passedViaFallback(fallback))
                    }
                    return StepOutcome(status: .passed)
                }
                if attempt < maxSwipes {
                    start = clock.now
                    try await driver.swipe(direction)
                    phase.actionMs += Self.ms(clock.now - start)
                }
            }
            return StepOutcome(status: .failed(
                "\(maxSwipes) 回スクロールしても要素が見つかりません: \(step.locatorSummary)"))
        }

        // ロケータ解決(指数バックオフで最大3回再試行 — UI 遷移直後対策。
        // 100→200→400ms で計700ms、ヒール発動までの総待機は Phase 2 以前(1000ms台)から
        // 大きく変えていない)
        var start = clock.now
        var snapshot = try await driver.snapshot()
        phase.snapshotMs += Self.ms(clock.now - start)
        var resolved = Self.resolve(step: step, in: snapshot)
        if resolved == nil {
            var backoff = PollBackoff()
            for _ in 0..<3 {
                start = clock.now
                try await Task.sleep(for: backoff.nextDelay())
                phase.waitMs += Self.ms(clock.now - start)
                start = clock.now
                snapshot = try await driver.snapshot()
                phase.snapshotMs += Self.ms(clock.now - start)
                resolved = Self.resolve(step: step, in: snapshot)
                if resolved != nil { break }
            }
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
            start = clock.now
            try await driver.tap(ref: element.ref)
            phase.actionMs += Self.ms(clock.now - start)
        case "type":
            start = clock.now
            try await driver.type(ref: element.ref, text: step.text ?? "")
            phase.actionMs += Self.ms(clock.now - start)
        case "press":
            start = clock.now
            try await driver.press(ref: element.ref, duration: 1.0)
            phase.actionMs += Self.ms(clock.now - start)
        default:
            return StepOutcome(status: .skipped("未知のアクション: \(action)"))
        }
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

    private func executeAssert(_ assert: String, step: FlowStep,
                               phase: inout PhaseAccumulator) async throws -> StepResult.Status {
        let clock = ContinuousClock()
        switch assert {
        case "exists":
            let deadline = Date().addingTimeInterval(TimeInterval(step.timeout ?? 5))
            var backoff = PollBackoff()
            while Date() < deadline {
                var start = clock.now
                let snapshot = try await driver.snapshot()
                phase.snapshotMs += Self.ms(clock.now - start)
                // アサーションでは type+index のみのフォールバックを使わない。
                // 別画面の無関係な要素にマッチして偽陽性になる(実測済み)
                if let (_, fallback) = Self.resolve(step: step, in: snapshot, strictForAssert: true) {
                    if let fallback { return .passedViaFallback(fallback) }
                    return .passed
                }
                start = clock.now
                try await Task.sleep(for: backoff.nextDelay())
                phase.waitMs += Self.ms(clock.now - start)
            }
            return .failed("要素が見つかりません: \(step.locatorSummary)(timeout \(step.timeout ?? 5)s)")

        case "valueEquals", "textEquals":
            guard let expected = step.expected else {
                return .skipped("expected が未指定")
            }
            let deadline = Date().addingTimeInterval(TimeInterval(step.timeout ?? 5))
            var lastActual: String?
            var found = false
            var backoff = PollBackoff()
            while Date() < deadline {
                var start = clock.now
                let snapshot = try await driver.snapshot()
                phase.snapshotMs += Self.ms(clock.now - start)
                if let (element, fallback) = Self.resolve(step: step, in: snapshot, strictForAssert: true) {
                    found = true
                    let actual = assert == "textEquals" ? element.label : element.value
                    lastActual = actual
                    if actual == expected {
                        if let fallback { return .passedViaFallback(fallback) }
                        return .passed
                    }
                }
                start = clock.now
                try await Task.sleep(for: backoff.nextDelay())
                phase.waitMs += Self.ms(clock.now - start)
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
            let start = clock.now
            let screenshot = try await driver.screenshot()
            phase.actionMs += Self.ms(clock.now - start)
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
