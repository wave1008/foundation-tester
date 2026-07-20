// StepExecutor.swift
// 単一 FlowStep の決定的実行エンジン(Swift DSL のコマンドは全てここを通る)。
// 実証済みのセマンティクス:
// - ロケータ解決失敗は指数バックオフ(100→200→400ms、計3回)で再試行してからヒールへ
//   (UI 遷移直後対策。ヒール発動までの総待機は計700ms)。step.timeout 指定時はアクションも
//   その秒数を予算にリトライ(0 = リトライなし。省略時=nilは従来の3回固定のまま)
// - アサーションでは type+index のみのフォールバックを使わない(別画面要素への偽陽性防止)
// - optional ステップは要素未発見でも失敗にせずスキップ(自己修復の対象外)
// - 自己修復は delegate 提案の confidence == "high" のみ採用
// - 操作後の整定待ちはドライバ側に委譲(Android: ブリッジの a11y 静穏検知 / iOS: XCUITest の
//   暗黙 quiescence)。
//   exists/valueEquals/textEquals はタイムアウトまでポーリング(間隔は PollBackoff の
//   指数バックオフ = 100→200→400→800→1000ms 以降頭打ち)

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
    /// 除外する目印として使う(人間向けの表示には含める)
    public let synthetic: Bool
    /// ステップの所要時間内訳。--profile 並列実行ではサブプロセスの
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

/// ステップ 1 回分の時間内訳(計測は ContinuousClock。単位はミリ秒)。
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
    /// ステップの所要時間内訳。action も assert もない(空)ステップの場合のみ nil
    /// (実行エラー時も catch 節でこの時点までの計測値を積んで返す)
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
    /// ハイブリッド用: primary(driver=in-app)で要素が解決できないとき、この driver の snapshot でも
    /// 解決を試す(アプリ上に載ったシステム UI=別プロセスのダイアログ等を XCUITest で拾う)。
    /// 解決に使った driver でそのまま act するので ref 名前空間の混同はない。
    public let fallbackDriver: AppDriver?
    /// hybrid 用: type アクションを XCUITest(アプリ attach)で実行する代替ドライバ。inapp が
    /// UIKit 非依存アプリ(Compose 等)で type 不能(409)なときの経路。fallbackDriver(springboard
    /// 参照・システム UI 用)とは別物。
    public let typeDriver: AppDriver?
    /// inapp /status の uiFramework=="compose" 検出時 true。type を inapp で試さず最初から
    /// typeDriver で実行する(409 の無駄打ち回避)。
    public var preferTypeDriver: Bool
    public var delegate: ReplayDelegate?
    public var healingEnabled: Bool
    /// 白フレーム確定時に呼ぶ。FTDriveCore が凍結中断+deviceFrozen emit を行う
    public var onDeviceFrozen: (@Sendable () -> Void)?

    public init(driver: AppDriver, fallbackDriver: AppDriver? = nil,
                typeDriver: AppDriver? = nil, preferTypeDriver: Bool = false,
                delegate: ReplayDelegate? = nil, healingEnabled: Bool = false) {
        self.driver = driver
        self.fallbackDriver = fallbackDriver
        self.typeDriver = typeDriver
        self.preferTypeDriver = preferTypeDriver
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

        // ロケータ指定のない type はフォーカス中の要素へ送る(直前の tap でフォーカスした欄など)。
        // ref: nil = ブリッジがフォーカス中要素へ入力(iOS/Android とも)。ロケータ解決を挟まない。
        if action == "type", step.locator == nil, step.fallbacks?.isEmpty ?? true {
            let start = clock.now
            try await driver.type(ref: nil, text: step.text ?? "")
            phase.actionMs += Self.ms(clock.now - start)
            return StepOutcome(status: .passed)
        }

        // ロケータ解決の再試行(ファイル冒頭のセマンティクス参照: 最大3回、計700ms)
        var start = clock.now
        var snapshot = try await driver.snapshot()
        phase.snapshotMs += Self.ms(clock.now - start)
        var resolved = Self.resolve(step: step, in: snapshot)
        if resolved == nil {
            if let timeout = step.timeout {
                // timeout == 0: リトライなし(初回スナップショットのみ。optional の空振り短縮用)
                if timeout > 0 {
                    let retryDeadline = clock.now.advanced(by: .seconds(timeout))
                    var backoff = PollBackoff()
                    while resolved == nil, clock.now < retryDeadline {
                        start = clock.now
                        try await Task.sleep(for: backoff.nextDelay())
                        phase.waitMs += Self.ms(clock.now - start)
                        start = clock.now
                        snapshot = try await driver.snapshot()
                        phase.snapshotMs += Self.ms(clock.now - start)
                        resolved = Self.resolve(step: step, in: snapshot)
                    }
                }
            } else {
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
        }

        // driver フォールバック(ハイブリッド): primary(in-app)で解決できない、または primary が
        // label 部分一致(substring)でしか解決できていないとき、fallbackDriver(XCUITest=システム UI)
        // の snapshot でも解決を試す。act は解決した driver で行う。
        // substring 誤解決の偽陽性(in-app の label がシステム UI label の部分文字列で contains 命中し、
        // 本来当てたいシステム UI 要素へフォールバックされない)を、fallback の exact 一致で上書きする。
        // primary が exact のときは fallback を照会しない(従来どおりコスト増なし)。
        var actingDriver: AppDriver = driver
        if let fb = fallbackDriver {
            let primaryQuality = resolved == nil ? nil : Self.resolveDetailed(step: step, in: snapshot)?.quality
            if resolved == nil || primaryQuality == .substring {
                start = clock.now
                let fsnap = try await fb.snapshot()
                phase.snapshotMs += Self.ms(clock.now - start)
                if let r = Self.resolveDetailed(step: step, in: fsnap),
                   resolved == nil || r.quality == .exact {
                    resolved = (r.element, r.usedFallback)
                    snapshot = fsnap
                    actingDriver = fb
                }
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
            try await actingDriver.tap(ref: element.ref)
            phase.actionMs += Self.ms(clock.now - start)
        case "type":
            if let td = typeDriver, preferTypeDriver,
               try await typeViaTypeDriver(td, step: step, phase: &phase) {
                return StepOutcome(status: .passed, healedStep: healedStep, healedByCache: healedByCache)
            }
            do {
                start = clock.now
                try await actingDriver.type(ref: element.ref, text: step.text ?? "")
                phase.actionMs += Self.ms(clock.now - start)
            } catch {
                // 409 = inapp が非 UIKit 入力欄で first responder を張れない兆候
                guard case DriverError.badResponse(let code, _) = error, code == 409,
                      let td = typeDriver else { throw error }
                guard try await typeViaTypeDriver(td, step: step, phase: &phase) else { throw error }
                status = .passedViaFallback(step.locator ?? FlowLocator(raw: step.locatorSummary))
            }
        case "press":
            start = clock.now
            try await actingDriver.press(ref: element.ref, duration: 1.0)
            phase.actionMs += Self.ms(clock.now - start)
        default:
            return StepOutcome(status: .skipped("未知のアクション: \(action)"))
        }
        return StepOutcome(status: status, healedStep: healedStep, healedByCache: healedByCache)
    }

    /// typeDriver で type を試みる。ref はブリッジごとに別名前空間なので typeDriver 側 snapshot で
    /// 取り直す。解決できなければ false(呼び出し側で通常経路[inapp]へフォールバック/再スロー)。
    private func typeViaTypeDriver(_ td: AppDriver, step: FlowStep,
                                   phase: inout PhaseAccumulator) async throws -> Bool {
        let clock = ContinuousClock()
        var start = clock.now
        let snapshot = try await td.snapshot()
        phase.snapshotMs += Self.ms(clock.now - start)
        guard let resolved = Self.resolveDetailed(step: step, in: snapshot) else { return false }
        start = clock.now
        try await td.type(ref: resolved.element.ref, text: step.text ?? "")
        phase.actionMs += Self.ms(clock.now - start)
        return true
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
            var primaryMisses = 0
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
                primaryMisses += 1
                // fallback(SystemUIDriver)の snapshot は springboard 再session+XCUITest snapshot で
                // 数百ms。primary(in-app ~0.05ms)ミス毎に払うと通常のアプリ内要素待ちを支配するため
                // 間引く: 2・4・6…回目のミスでのみ照会。実在するシステムUI要素の検知遅れは最大で
                // バックオフ1段+1周期
                if primaryMisses >= 2, primaryMisses % 2 == 0, let fb = fallbackDriver {
                    start = clock.now
                    let fsnap = try await fb.snapshot()
                    phase.snapshotMs += Self.ms(clock.now - start)
                    if let (_, fallback) = Self.resolve(step: step, in: fsnap, strictForAssert: true) {
                        if let fallback { return .passedViaFallback(fallback) }
                        return .passed
                    }
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
            var primaryMisses = 0
            while Date() < deadline {
                var start = clock.now
                let snapshot = try await driver.snapshot()
                phase.snapshotMs += Self.ms(clock.now - start)
                var candidate = Self.resolve(step: step, in: snapshot, strictForAssert: true)
                if candidate == nil { primaryMisses += 1 }
                // driver フォールバック(ハイブリッド): primary で見つからなければシステム UI を確認。
                // 間引きの契約は exists ケース参照
                if candidate == nil, primaryMisses >= 2, primaryMisses % 2 == 0,
                   let fb = fallbackDriver {
                    start = clock.now
                    let fsnap = try await fb.snapshot()
                    phase.snapshotMs += Self.ms(clock.now - start)
                    candidate = Self.resolve(step: step, in: fsnap, strictForAssert: true)
                }
                if let (element, fallback) = candidate {
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
            var start = clock.now
            var screenshot = try await driver.screenshot()
            phase.actionMs += Self.ms(clock.now - start)
            // 白フレーム(画面凍結)を FM 検証に渡すと必ず不一致で誤失敗するため、リトライで回復を待つ
            if BlankFrameDetector.isUniformBlank(pngData: screenshot) {
                for _ in 0..<2 {
                    try await Task.sleep(nanoseconds: 2_000_000_000)
                    start = clock.now
                    let retry = try await driver.screenshot()
                    phase.actionMs += Self.ms(clock.now - start)
                    screenshot = retry
                    if !BlankFrameDetector.isUniformBlank(pngData: retry) { break }
                }
                if BlankFrameDetector.isUniformBlank(pngData: screenshot) {
                    onDeviceFrozen?()
                    return .skipped("画面凍結(白フレーム)のため中断・別デバイスへ振り直し")
                }
            }
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

    /// label の一致品質。exact=完全一致、substring=部分一致(contains)。
    /// ハイブリッドで「primary の substring 解決」を「fallback の exact 解決」で上書きする判定に使う。
    /// id / type+index による一致は exact 扱い。
    public enum MatchQuality { case exact, substring }

    /// 戻り値: (要素, 使用したフォールバック)。プライマリで解決した場合フォールバックは nil
    /// strictForAssert: id も label もない(type+index のみの)フォールバックを除外する
    public static func resolve(step: FlowStep, in snapshot: SnapshotResponse,
                               strictForAssert: Bool = false) -> (ElementInfo, FlowLocator?)? {
        resolveDetailed(step: step, in: snapshot, strictForAssert: strictForAssert)
            .map { ($0.element, $0.usedFallback) }
    }

    /// resolve に label 一致品質(quality)を添えた版。ハイブリッドの偽陽性抑止に使う。
    public static func resolveDetailed(step: FlowStep, in snapshot: SnapshotResponse,
                                       strictForAssert: Bool = false)
        -> (element: ElementInfo, usedFallback: FlowLocator?, quality: MatchQuality)? {
        var chain: [(FlowLocator, isPrimary: Bool)] = []
        if let locator = step.locator { chain.append((locator, true)) }
        for fallback in step.fallbacks ?? [] {
            if strictForAssert, fallback.id == nil, fallback.label == nil { continue }
            chain.append((fallback, false))
        }

        for (locator, isPrimary) in chain {
            if let (element, quality) = matchDetailed(locator, in: snapshot) {
                return (element, isPrimary ? nil : locator, quality)
            }
        }
        return nil
    }

    public static func match(_ locator: FlowLocator, in snapshot: SnapshotResponse) -> ElementInfo? {
        matchDetailed(locator, in: snapshot)?.0
    }

    public static func matchDetailed(_ locator: FlowLocator, in snapshot: SnapshotResponse)
        -> (ElementInfo, MatchQuality)? {
        // type は絞り込み条件として id/label と併用できる
        // (同じ id が Cell/Switch/Button に付くことがあり、値検証では型の指定が必要)
        var candidates = snapshot.elements
        if let type = locator.type {
            candidates = candidates.filter { $0.type == type }
        }
        if let id = locator.id {
            return candidates.first { $0.identifier == id }.map { ($0, .exact) }
        }
        if let label = locator.label {
            if let exact = candidates.first(where: { $0.label == label }) { return (exact, .exact) }
            if let sub = candidates.first(where: { ($0.label ?? "").contains(label) }) { return (sub, .substring) }
            return nil
        }
        if locator.type != nil {
            let index = locator.index ?? 0
            return index < candidates.count ? (candidates[index], .exact) : nil
        }
        return nil
    }
}
