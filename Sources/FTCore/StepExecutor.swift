// StepExecutor.swift
// 単一 FlowStep の決定的実行エンジン(Swift DSL のコマンドは全てここを通る)。
// 実証済みのセマンティクス:
// - ロケータ解決失敗は指数バックオフ(100→200→400ms、計3回)で再試行してからヒールへ
//   (UI 遷移直後対策。ヒール発動までの総待機は計700ms)。step.timeout 指定時はアクションも
//   その秒数を予算にリトライ(0 = リトライなし。省略時=nilは従来の3回固定のまま)
// - アサーションでは type+index のみのフォールバックを使わない(別画面要素への偽陽性防止)。
//   ただしスコープ付き(`#list >> .Cell[2]`)は容器に錨があるので除外しない(FlowLocator.isWeakForAssert)
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
    /// [PoC occlusion-guard] ツリー上は一致した要素が、実際にスクショ上で覆われず/切れず/
    /// 明瞭に描画されているかを FM に照合させる。visible=false なら assert を偽陽性として反転する。
    /// 戻り nil = 判定不能(FM 不可・画像不正)で、この場合ガードは何もしない(従来どおり pass)。
    /// state は fullyVisible/covered/dimmed/notRendered/textMismatch のいずれか(FTCore は FM 非依存
    /// のため文字列で受ける)。既定実装は nil(ガード無効時・非対応 delegate は素通り)。
    /// observedText は FM が実際に読み取れた文字列(切り分け用。空 = 何も読めなかった)。
    func verifyElementVisible(expectedText: String, frame: FTRect, screen: FTRect,
                              screenshotPNG: Data) async
        -> (visible: Bool, state: String, reason: String, observedText: String)?
}

public extension ReplayDelegate {
    func verifyElementVisible(expectedText: String, frame: FTRect, screen: FTRect,
                              screenshotPNG: Data) async
        -> (visible: Bool, state: String, reason: String, observedText: String)? {
        nil
    }
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
    /// 結果確定時刻(ISO8601+ミリ秒。ScenarioEvent.at 由来)。--profile 並列実行の NDJSON
    /// 再構築(ApiRunCommand.ndjsonLines)で失わないよう運ぶ。逐次実行等の合成行は nil
    public let at: String?

    public init(index: Int, description: String, status: Status,
                scene: Int? = nil, sceneTitle: String? = nil, section: String? = nil,
                synthetic: Bool = false, timing: StepTiming? = nil, at: String? = nil) {
        self.index = index
        self.description = description
        self.status = status
        self.scene = scene
        self.sceneTitle = sceneTitle
        self.section = section
        self.synthetic = synthetic
        self.timing = timing
        self.at = at
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
    /// ドライバが通常と違う経路を通ったときの注記。FTRuntime が説明文に括弧書きでそのまま付けるため
    /// 表示済み文言で持つ(例 "fell back to XCUITest" / "activate 不発 → 合成タッチ(...)")。
    /// ロケータのフォールバック(.passedViaFallback)とは別物で、セレクタ更新の提案は出さない。
    public let driverFallback: String?
    /// このステップの結果が確定した壁時計時刻(ISO8601+ミリ秒)。execute(_:cached:) が
    /// 返す直前に都度 Date() から採る(failed 以外にも付くが、永続化するのは失敗ステップのみ。
    /// ScenarioEvent.at / FailedStepRecord.at 参照)
    public let at: String
    /// checked / notChecked のとき、**掴んだ要素が実際に checked を報告したか**。
    /// ブリッジは true のときだけ送るので、nil のままなら「オフ」か「状態を持たない要素」の
    /// 区別が付かない = `isNotChecked` が何を指しても通ってしまう。呼び手(FTDriveCore)が
    /// シナリオ横断で集計し、一度も観測できなければ run 終了時に警告する
    public let observedChecked: Bool?
    /// 成功時に実際に照合した要素(exist/textIs 等の assert・tap/type/press 等のアクションで解決した
    /// 要素)。失敗時は常に nil(掴めなかったのに値が読める状態を作らない)。notExists/count/
    /// screenMatches のように要素が1つに定まらない assert も nil のまま
    public let resolvedElement: ElementInfo?

    public init(status: StepResult.Status, healedStep: FlowStep? = nil, healedByCache: Bool = false,
               timing: StepTiming? = nil, driverFallback: String? = nil,
               observedChecked: Bool? = nil, resolvedElement: ElementInfo? = nil,
               at: String = ISO8601Millis.string(from: Date())) {
        self.observedChecked = observedChecked
        self.resolvedElement = resolvedElement
        self.status = status
        self.healedStep = healedStep
        self.healedByCache = healedByCache
        self.timing = timing
        self.driverFallback = driverFallback
        self.at = at
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
    /// in-app ブリッジが /status の unsupportedActions で申告したジェスチャ("swipe"/"press")。
    /// 含まれるアクションは inapp で試さず最初から typeDriver で実行する。
    /// **アクション別に持つ**: uikit は press だけ申告する(swipe は contentOffset 直接操作で
    /// 決定的に効く)。一括 Bool だと press の申告だけで swipe まで XCUITest 実スワイプ化し、
    /// バウンス由来の非決定性で scrollTo 直後のタップが flake した(2026-07-23 実害)。
    /// type 用の preferTypeDriver(廃止済み・常に false)とは別物。
    public var typeDriverGestures: Set<String>
    /// swipe/press が「このエンジンでは不可」を1回でも受けたら true。以降は直接 typeDriver へ
    /// (scrollTo は最大 maxSwipes 回 swipe するため、毎回往復させないため)
    private var gestureFallbackLatched = false
    /// drag(スクロール探索直後の空打ち)専用のラッチ。**gestureFallbackLatched と共有しない**:
    /// in-app は drag を一切実装しないので必ず 501 になるが、swipe は UIKit なら
    /// contentOffset 経路で決定的に効く。共有すると drag の 501 だけで全 swipe が XCUITest 実
    /// スワイプ化し、バウンス由来の flake を持ち込む(typeDriverGestures の注意書きと同じ理由)
    private var dragFallbackLatched = false
    public var delegate: ReplayDelegate?
    public var healingEnabled: Bool
    /// 実行プロファイルの falsePositiveCheck に対応するマスタースイッチ(既定 true)。false なら
    /// occlusionGuard/perStepGuard の値に関わらず occlusion-guard 自体を無効化する
    public var occlusionGuardEnabled: Bool
    /// 実行プロファイルの screenIs に対応するマスタースイッチ(既定 true)。false なら
    /// screenMatches ステップを skip する
    public var screenIsEnabled: Bool
    /// [PoC occlusion-guard] true のとき、exists/textEquals がツリー一致で pass した直後に
    /// FM で「その要素がスクショ上で実際に見えているか」を1回照合し、覆われ/切れ/減光/不在なら
    /// 偽陽性として失敗へ反転する。delegate が verifyElementVisible を実装していなければ無効。
    /// occlusionGuardEnabled(実行プロファイル由来のマスタースイッチ)とは別物: こちらは
    /// exist の requireVisible 既定値由来のステップ既定(step.occlusionGuard が per-step 指定)
    public var occlusionGuard: Bool
    /// [PoC occlusion-guard] 事前フィルタの閾値。対象 frame 領域の輝度 stddev がこの値以上なら
    /// 「明瞭にインクあり=見えている」とみなし FM を省略する(疑いのある低インク領域だけ FM へ回す)。
    /// 単位はスクショの輝度分散(0〜約128)。実測(合成フィクスチャ)で可視 stddev≳25 / 覆い・空・減光
    /// stddev≲8 に分離するため既定 12。0 にすると常に FM を呼ぶ(ゲート無効)。
    public var occlusionInkThreshold: Double
    /// [occlusion-guard] スクショ再利用キャッシュ。操作を挟まない連続ガード(exist を並べる等)で
    /// 直近のスクショを使い回し、往復(~125ms)を省く。無効化は action/performCustom(launch/wait)/
    /// poll 待機、および 200ms TTL(下記 guardScreenshot)。静止画面前提のため TTL で staleness を上限。
    /// StepExecutor+Assert.swift の occlusionFlip/executeAssert からも直接クリアされるため internal
    /// (private のままだと拡張ファイルからの `cachedScreenshot = nil` がコンパイルできない)。
    var cachedScreenshot: Data?
    private var cachedShotAt: ContinuousClock.Instant?
    /// 白フレーム確定時に呼ぶ。FTDriveCore が凍結中断+deviceFrozen emit を行う
    public var onDeviceFrozen: (@Sendable () -> Void)?
    /// 割り込みハンドラ(アプリ内メッセージ・自前のお知らせダイアログ用)。
    /// **閉じ方はアプリ作者しか知らない**ので、ツールが推測せずプロジェクト側で1回宣言してもらう
    /// (DSL の `irregularHandler`)。detect が現在のスナップショットで解決できたら dismiss をタップし、
    /// 取り直してから本来の操作を続ける。宣言が無ければ何もしない = 正常系のコストはゼロ
    /// (**追加のスナップショットを取らない**。既に手元にあるものへ照合するだけ)
    public struct InterruptHandler: Sendable {
        public let detect: FlowLocator
        public let dismiss: FlowLocator
        public init(detect: FlowLocator, dismiss: FlowLocator) {
            self.detect = detect
            self.dismiss = dismiss
        }
    }

    /// 宣言順に評価する。1ステップにつき**1回だけ**発火する(閉じても消えない相手で無限に回らないため)
    public var interruptHandlers: [InterruptHandler] = []

    /// スクロール探索の直後に「空打ち」の極小ドラッグを入れるか(**iOS だけ true**)。
    /// iOS(Compose)のスクロール容器は次の1タッチを消費してタップが効かないため必要だが、
    /// **Android では 2pt のドラッグがクリックとして発火してしまう**(タップしていないのに
    /// 行が選択される = 二重実行。2026-07-27 実測)。プラットフォームで分ける唯一の理由
    private let releasesScrollTouch: Bool

    /// 画面が変わり得る操作の直後に呼び、スクショ再利用キャッシュを捨てる(performCustom から呼ぶ)。
    public func invalidateScreenshotCache() { cachedScreenshot = nil }

    /// occlusion-guard 用スクショ。直近(200ms 以内・無効化なし)なら再利用、無ければ取得してキャッシュ。
    /// StepExecutor+Assert.swift の occlusionFlip から呼ばれるため internal。
    func guardScreenshot(phase: inout PhaseAccumulator) async throws -> Data {
        let clock = ContinuousClock()
        if let shot = cachedScreenshot, let at = cachedShotAt, clock.now - at < .milliseconds(200) {
            return shot
        }
        let start = clock.now
        let shot = try await driver.screenshot()
        phase.actionMs += Self.ms(clock.now - start)
        cachedScreenshot = shot
        cachedShotAt = clock.now
        return shot
    }

    public init(driver: AppDriver, fallbackDriver: AppDriver? = nil,
                typeDriver: AppDriver? = nil, preferTypeDriver: Bool = false,
                typeDriverGestures: Set<String> = [],
                delegate: ReplayDelegate? = nil, healingEnabled: Bool = false,
                occlusionGuard: Bool = false, occlusionInkThreshold: Double = 12,
                occlusionGuardEnabled: Bool = true, screenIsEnabled: Bool = true,
                releasesScrollTouch: Bool = false) {
        self.releasesScrollTouch = releasesScrollTouch
        self.driver = driver
        self.fallbackDriver = fallbackDriver
        self.typeDriver = typeDriver
        self.preferTypeDriver = preferTypeDriver
        self.typeDriverGestures = typeDriverGestures
        self.delegate = delegate
        self.healingEnabled = healingEnabled
        self.occlusionGuard = occlusionGuard
        self.occlusionInkThreshold = occlusionInkThreshold
        self.occlusionGuardEnabled = occlusionGuardEnabled
        self.screenIsEnabled = screenIsEnabled
    }

    /// cached: ヒールキャッシュ由来のロケータ連鎖。解決順は
    /// プライマリ → フォールバック → キャッシュ → FM ヒール(アクションのみ)
    public func execute(_ step: FlowStep, cached: [FlowLocator] = []) async -> StepOutcome {
        let clock = ContinuousClock()
        let start = clock.now
        var phase = PhaseAccumulator()
        interruptNote = nil   // 「1ステップにつき1回だけ」の起点(dismissInterruption が見る)
        observedCheckedThisStep = nil
        resolvedElementThisStep = nil
        do {
            if let action = step.action {
                let outcome = try await executeAction(action, step: step, cached: cached, phase: &phase)
                return StepOutcome(status: outcome.status, healedStep: outcome.healedStep,
                                   healedByCache: outcome.healedByCache,
                                   timing: StepTiming(durationMs: Self.ms(clock.now - start),
                                                      snapshotMs: phase.snapshotMs,
                                                      actionMs: phase.actionMs, waitMs: phase.waitMs),
                                   driverFallback: noteWithInterrupt(outcome.driverFallback),
                                   // アクションは**解決した時点**で立てる(操作の成否より前)ため、
                                   // 失敗した操作の要素を持ち帰らないようここで落とす
                                   resolvedElement: Self.isSuccess(outcome.status)
                                       ? resolvedElementThisStep : nil)
            }
            if let assert = step.assert {
                let status = try await executeAssert(assert, step: step, phase: &phase)
                return StepOutcome(status: status,
                                   timing: StepTiming(durationMs: Self.ms(clock.now - start),
                                                      snapshotMs: phase.snapshotMs,
                                                      actionMs: phase.actionMs, waitMs: phase.waitMs),
                                   driverFallback: noteWithInterrupt(nil),
                                   observedChecked: observedCheckedThisStep,
                                   resolvedElement: resolvedElementThisStep)
            }
            return StepOutcome(status: .skipped("step has neither an action nor an assertion"))
        } catch {
            return StepOutcome(status: .failed("execution error: \(error.localizedDescription)"),
                               timing: StepTiming(durationMs: Self.ms(clock.now - start),
                                                  snapshotMs: phase.snapshotMs,
                                                  actionMs: phase.actionMs, waitMs: phase.waitMs))
        }
    }

    /// execute(_:cached:) 1 回分の snapshot/action/wait 所要時間(ミリ秒)の積算値。
    /// 呼び出しの中だけで閉じるローカル値のため、並行アクセスの心配はない。
    /// StepExecutor+Assert.swift の executeAssert 系のシグネチャにも使うため internal。
    struct PhaseAccumulator {
        var snapshotMs = 0
        var actionMs = 0
        var waitMs = 0
    }

    /// ContinuousClock の Duration → 整数ミリ秒(秒成分×1000 + attoseconds成分。
    /// 1ms = 1e15 attoseconds)。StepExecutor+Assert.swift からも使うため internal。
    static func ms(_ duration: Duration) -> Int {
        let (seconds, attoseconds) = duration.components
        return Int(seconds) * 1000 + Int(attoseconds / 1_000_000_000_000_000)
    }

    // MARK: - アクション

    /// 内蔵スクロール探索が XCUITest 経由の swipe に落ちたときの注記(execute が載せる)。
    /// StepExecutor+Assert.swift の executeAssertExists からも書くため internal。
    var scrollSearchNote: String?
    /// checked / notChecked が**実際に checked を観測したか**(execute が StepOutcome に載せる)。
    /// executeAssert は Status しか返さないためインスタンス変数で受け渡す
    /// (StepExecutor+Assert.swift の executeAssertChecked から書くため internal)。
    var observedCheckedThisStep: Bool?
    /// exist/textIs 等の assert・tap/type/press 等のアクションが**成功時**に実際に照合した要素
    /// (execute が StepOutcome.resolvedElement に載せる)。observedCheckedThisStep と同じ受け渡し形
    /// (StepExecutor+Assert.swift の各 executeAssert* から書くため internal)。失敗時は立てない。
    var resolvedElementThisStep: ElementInfo?

    /// 「掴めた」と言い切れる状態か(StepOutcome.resolvedElement を載せてよいかの判定)
    static func isSuccess(_ status: StepResult.Status) -> Bool {
        switch status {
        case .passed, .passedViaFallback, .healed: return true
        case .failed, .skipped: return false
        }
    }

    /// このステップで閉じた割り込み(execute が記録の注記に載せる)。
    /// **1ステップにつき1回だけ**発火させるための状態でもある(閉じても消えない相手に対して
    /// アサーションのポーリングごとにタップし続けるのを防ぐ)
    private var interruptNote: String?

    /// ステップ横断の注記(内蔵スクロール探索・割り込み)を既存の driverFallback へ合流させる
    private func noteWithInterrupt(_ base: String?) -> String? {
        var parts = [base, scrollSearchNote].compactMap { $0 }
        if let interruptNote { parts.append("dismissed the interruption \(interruptNote)") }
        return parts.isEmpty ? nil : parts.joined(separator: " / ")
    }

    /// 宣言された割り込み(アプリ内メッセージ等)が現在の画面に出ていれば閉じる。
    /// **アクションでも検証でも**呼ぶ(割り込みは待機中にこそ出るため、アクション側だけだと
    /// `exist`/`textIs` の待ち中に出たものを閉じられない)。既に1回閉じていれば何もしない。
    /// スナップショットは呼び手が持っているものを使い、閉じた後だけ取り直す
    /// (**追加のスナップショットを取らない** = 宣言が無ければコストゼロ)
    /// StepExecutor+Assert.swift の executeAssert 系すべてから呼ぶため internal。
    func dismissInterruption(in snapshot: inout SnapshotResponse,
                             phase: inout PhaseAccumulator) async throws {
        guard !interruptHandlers.isEmpty, interruptNote == nil else { return }
        let clock = ContinuousClock()
        for handler in interruptHandlers {
            guard Self.match(handler.detect, in: snapshot) != nil,
                  let target = Self.match(handler.dismiss, in: snapshot) else { continue }
            let start = clock.now
            try await driver.tap(ref: target.ref)
            phase.actionMs += Self.ms(clock.now - start)
            let shotStart = clock.now
            snapshot = try await driver.snapshot()
            phase.snapshotMs += Self.ms(clock.now - shotStart)
            interruptNote = handler.detect.summary
            return
        }
    }

    struct ScrollSearchResult {
        let found: Bool
        /// 解決に使ったフォールバック節(プライマリで解決したら nil)
        let fallback: FlowLocator?
        /// 1回でも XCUITest 経由で swipe したか(記録の注記に載せる)
        let viaXCUITest: Bool
        /// スクロールヒントで置き換えた長距離ドラッグの回数(記録の注記に載せる)
        let hintJumps: Int
    }

    /// スクロール探索の注記(XCUITest フォールバック / ヒント跳躍)。無ければ nil
    static func scrollSearchNote(_ result: ScrollSearchResult) -> String? {
        var parts: [String] = []
        if result.viaXCUITest { parts.append("fell back to XCUITest") }
        if result.hintJumps > 0 { parts.append("\(result.hintJumps) long drag(s) from scroll hints") }
        return parts.isEmpty ? nil : parts.joined(separator: " / ")
    }

    static func scrollNotFoundMessage(_ step: FlowStep) -> String {
        "element not found after \(max(0, step.maxSwipes ?? FlowStep.defaultMaxSwipes)) scroll(s)"
            + ": \(step.locatorSummary)"
    }

    /// `notExist(scroll:)` の裏返し: スクロール探索中に見つかってしまったら不在検証は失敗
    /// (executeAssertNotExists の scroll-search prelude が使う。scrollNotFoundMessage の対)
    static func scrollFoundMessage(_ step: FlowStep) -> String {
        "element found via scroll search: \(step.locatorSummary)"
    }

    /// スクロールヒント(WebView の画面外ノード・実座標付き)から「あと何 px 先か」を出す。
    ///
    /// **なぜ**: スクロール探索の支配項はスワイプ1回のジェスチャ時間(Android 実測 1.05s / 974px。
    /// スナップショットは 25ms)。距離が分かれば、固定幅スワイプ N 回を少数の長距離ドラッグに
    /// 置き換えられる(1500px を 0.44s)。ヒントは Android の WebView だけが供給する
    /// (Chromium が全ドキュメントをツリーに載せる。ネイティブのリストは画面外を載せないため、
    /// **ヒントが無いことは不在の根拠にならない** = 従来ループの代替であって不在の即断には使わない)。
    ///
    /// 戻り値: 正 = 指を上へ(内容を下へ読み進める)動かす px。ヒント不一致・方向不一致・
    /// 水平方向・既に画面内なら nil(呼び手は従来のスワイプに落ちる)。
    /// 呼び手はスナップショットごとに再計算する(ドラッグの実移動はフリングで揺れるが、
    /// 毎回測り直す自己補正で収束する。較正は持たない)
    static func offscreenJump(step: FlowStep, snapshot: SnapshotResponse,
                              finger: FTSwipeDirection) -> Double? {
        guard finger == .up || finger == .down,
              let hints = snapshot.offscreen, !hints.isEmpty else { return nil }
        let pseudo = SnapshotResponse(sessionBundleID: nil, screen: snapshot.screen,
                                      elements: hints, truncatedCount: 0)
        guard let (hint, _) = Self.resolve(step: step, in: pseudo, strictForAssert: true) else {
            return nil
        }
        let screen = snapshot.screen
        // 着地目標: 要素の上端を画面の 40% 位置へ(中央より上 = 下端の固定要素・タブに重ねない)
        let jump = hint.frame.y - (screen.y + screen.height * 0.4)
        // 方向が合っているときだけ(逆向きのヒントで往復しない。ドラッグ過走の戻しは
        // ここではなく通常ループの資格 = 見えたら resolve が拾う、に任せる)
        if finger == .up, jump > screen.height * 0.3 { return jump }
        if finger == .down, jump < -screen.height * 0.3 { return jump }
        return nil
    }

    /// スクロールヒントの端(その方向にまだ続く実座標の限界)までの距離。scrollToEdge 用。
    /// 正 = 指を上へ。ヒントがその方向に無ければ nil(従来の署名ループへ)
    static func offscreenEdgeJump(snapshot: SnapshotResponse,
                                  finger: FTSwipeDirection) -> Double? {
        guard finger == .up || finger == .down,
              let hints = snapshot.offscreen, !hints.isEmpty else { return nil }
        let screen = snapshot.screen
        // 閾値は小さくてよい(100px): 端スクロールは行き過ぎても端で止まる(クランプされる)ので
        // 過走が無害。scrollTo(offscreenJump)の 30% 閾値とは安全条件が違う
        switch finger {
        case .up:
            // 下端: いちばん下のヒント下端が画面下端に来るまでの残り
            guard let maxBottom = hints.map({ $0.frame.y + $0.frame.height }).max() else { return nil }
            let jump = maxBottom - (screen.y + screen.height)
            return jump > 100 ? jump : nil
        case .down:
            // 上端: いちばん上のヒント上端(負)が画面上端に来るまでの残り
            guard let minTop = hints.map({ $0.frame.y }).min() else { return nil }
            let jump = minTop - screen.y
            return jump < -100 ? jump : nil
        default:
            return nil
        }
    }

    /// 長距離ドラッグの1ジェスチャ分の始点・終点(純粋関数・単体テスト対象)。
    /// container(webView の可視矩形)内で、上下 15% のマージンを避けて縦線上を動かす。
    /// 1ジェスチャで賄えない距離は呼び手のループ(スナップショット→再計算)が刻む
    static func dragGesture(jump: Double, container: FTRect)
        -> (fromX: Double, fromY: Double, toX: Double, toY: Double)? {
        let margin = container.height * 0.15
        let usable = container.height - margin * 2
        guard usable > 100 else { return nil }
        // 0.9 掛け: フリング分の過走を抑える(過走しても次周回の再計算で戻るが、往復は遅い)
        let distance = min(abs(jump) * 0.9, usable)
        guard distance > 50 else { return nil }
        let x = container.x + container.width / 2
        if jump > 0 {   // 指を上へ
            let fromY = container.y + container.height - margin
            return (x, fromY, x, fromY - distance)
        }
        let fromY = container.y + margin
        return (x, fromY, x, fromY + distance)
    }

    /// ヒント跳躍のドラッグ実行。ゆっくり終える(pressSeconds でフリングを抑えつつ、
    /// 距離に応じた duration)。失敗したら false(呼び手は従来のスワイプへ落ちる)
    private func hintDrag(jump: Double, container: FTRect,
                          phase: inout PhaseAccumulator) async -> Bool {
        guard let g = Self.dragGesture(jump: jump, container: container) else { return false }
        let clock = ContinuousClock()
        let start = clock.now
        let duration = min(max(abs(g.toY - g.fromY) / 2500, 0.3), 0.7)
        do {
            try await driver.drag(fromX: g.fromX, fromY: g.fromY, toX: g.toX, toY: g.toY,
                                  pressSeconds: 0.08, durationSeconds: duration)
            phase.actionMs += Self.ms(clock.now - start)
            return true
        } catch {
            phase.actionMs += Self.ms(clock.now - start)
            return false   // drag 未対応ドライバ等 → このヒントは諦めて通常スワイプ
        }
    }

    /// スナップショット中の webView コンテナ(ヒントのドラッグ領域)。無ければ nil
    static func webViewContainer(in snapshot: SnapshotResponse) -> FTRect? {
        snapshot.elements.first(where: { $0.type == "webView" })?.frame
    }

    /// **スクロール探索の本体**。`scrollTo` コマンドと、`tap(scroll:)` / `exist(scroll:)` の
    /// 内蔵探索が共有する(同じ挙動を2箇所に書かない)。見つけたら静止させてから返すので、
    /// 呼び手はそのまま解決・操作してよい
    /// StepExecutor+Assert.swift の executeAssertExists(`exist(scroll:)`)からも呼ぶため internal。
    func runScrollSearch(step: FlowStep,
                         phase: inout PhaseAccumulator) async throws -> ScrollSearchResult {
        let clock = ContinuousClock()
        let direction = FTSwipeDirection(rawValue: step.direction ?? "") ?? .up
        // 負値だと 0...(-1) が ClosedRange 生成で trap(クラッシュ)するため 0 で下限クランプ
        let maxSwipes = max(0, step.maxSwipes ?? FlowStep.defaultMaxSwipes)
        var viaXCUITest = false
        var hintJumps = 0
        for attempt in 0...maxSwipes {
            let start = clock.now
            var snapshot = try await driver.snapshot()
            phase.snapshotMs += Self.ms(clock.now - start)
            try await dismissInterruption(in: &snapshot, phase: &phase)
            // スクロール探索でも type+index フォールバックは偽陽性のもとなので使わない
            if let (element, fallback) = Self.resolve(step: step, in: snapshot, strictForAssert: true) {
                // **スワイプしたなら静止を待つ**。フリングの慣性でリストは減速しながら動き続けており、
                // 見つけた瞬間に返すと次の操作が別の要素を掴む
                // (実測 2026-07-27: Android は #row_30 を狙って #row_37 をタップした)。
                // スワイプしていない周回(attempt == 0)は静止しているので追加コストを払わない
                if attempt > 0 {
                    // 順序に意味がある(逆にすると Android で誤タップが再発する。2026-07-27 実測):
                    //  1. **空打ちの極小ドラッグ**: iOS(Compose)のスクロール容器は次の1タッチを
                    //     消費してしまい、タップもプレスも効かない(待っても解けない。2回目は効く)。
                    //     クリックにならない 2pt のドラッグでその1回ぶんを肩代わりする
                    //  2. **静止待ち**: 空打ちでリストが微動するので、止まってから返す
                    // **触る点が他の要素に取られるなら打たない**。空打ちは手前の要素
                    // (タブバー等)に届き、そのボタンが反応してしまう
                    // (2026-07-27 実測: E2E-iOS の #txt_offscreen はタブバーの帯の中に出るため、
                    // 空打ちでホームタブへ切り替わっていた)
                    let x: Double = element.frame.x + element.frame.width / 2
                    let y: Double = element.frame.y + element.frame.height / 2
                    if releasesScrollTouch,
                       Self.emptyDragIsSafe(x: x, y: y, of: element,
                                            in: snapshot.elements, screen: snapshot.screen) {
                        await emptyDrag(x: x, y: y)
                    }
                    try await settleAfterScroll(step: step, found: element, phase: &phase)
                }
                return ScrollSearchResult(found: true, fallback: fallback, viaXCUITest: viaXCUITest,
                                          hintJumps: hintJumps)
            }
            if attempt < maxSwipes {
                // ヒント跳躍: 距離が分かるときは固定幅スワイプでなく長距離ドラッグで寄せる。
                // ドラッグ後は静止を待たず次周回のスナップショット(25ms)で測り直す(自己補正)
                if let jump = Self.offscreenJump(step: step, snapshot: snapshot, finger: direction),
                   let container = Self.webViewContainer(in: snapshot),
                   await hintDrag(jump: jump, container: container, phase: &phase) {
                    hintJumps += 1
                    continue
                }
                if try await swipeWithFallback(direction, forScroll: true, phase: &phase) { viaXCUITest = true }
            }
        }
        return ScrollSearchResult(found: false, fallback: nil, viaXCUITest: viaXCUITest,
                                  hintJumps: hintJumps)
    }

    private func executeAction(_ action: String, step: FlowStep,
                               cached: [FlowLocator] = [],
                               phase: inout PhaseAccumulator) async throws -> StepOutcome {
        let clock = ContinuousClock()
        cachedScreenshot = nil   // 画面を変える操作 → occlusion-guard スクショ再利用を無効化
        // ロケータ不要のアクション
        if action == "swipe" {
            let direction = FTSwipeDirection(rawValue: step.direction ?? "") ?? .up
            let viaXCUITest = try await swipeWithFallback(direction, phase: &phase)
            // 慣性が止まるまで待つ。ランナー側は /swipe を整定対象から外している(そこで待っても
            // budget 内に収束しないため)ので、直後に tap する書き方をここで支える
            _ = try await settledSignature(phase: &phase)
            return StepOutcome(status: .passed, driverFallback: viaXCUITest ? "fell back to XCUITest" : nil)
        }

        // スクロールだけ行う(Shirates の scrollDown 等)。maxSwipes を繰り返し回数として使う
        if action == "scroll" {
            let direction = FTSwipeDirection(rawValue: step.direction ?? "") ?? .up
            let times = max(1, step.maxSwipes ?? 1)
            var viaXCUITest = false
            for index in 0..<times {
                if try await swipeWithFallback(direction, forScroll: true, phase: &phase) { viaXCUITest = true }
                // 続けて投げるとフリングの停止だけに消費されて空振りする(Android 実測)。
                // 「repeat 回ぶん送る」を守るため、次のスワイプ前に静止を待つ。
                // 最後の1回の後も待つ: ランナーは /swipe を整定対象から外しているので、
                // 直後に tap する書き方をここで支える(index 条件を外した理由)
                _ = try await settledSignature(phase: &phase).signature
            }
            return StepOutcome(status: .passed,
                               driverFallback: viaXCUITest ? "fell back to XCUITest" : nil)
        }

        // 端まで送る(Shirates の scrollToBottom 等)。**画面が変化しなくなったら端**とみなす。
        // 比較は**静止してから**行う(フリングの減速中に撮ると動いていないように見える)。
        // さらに **2 回続けて変化なし**を条件にする — Android では次のスワイプがフリングの
        // 停止だけに消費されて 1 回空振りすることがあり、1 回で打ち切ると途中で止まる
        // (2026-07-27 実測: scrollToTop が row_22 付近で停止した)
        if action == "scrollToEdge" {
            let direction = FTSwipeDirection(rawValue: step.direction ?? "") ?? .up
            var viaXCUITest = false
            var previous: String?
            var unchanged = 0
            var reachedEdge = false
            let limit = max(1, step.maxSwipes ?? FlowStep.defaultMaxEdgeSwipes)
            var hintJumps = 0
            for _ in 0..<limit {
                let settled = try await settledSignature(phase: &phase)
                unchanged = settled.signature == previous ? unchanged + 1 : 0
                if unchanged >= 2 { reachedEdge = true; break }
                previous = settled.signature
                // ヒント跳躍(WebView): 端までの残り距離が分かるときは長距離ドラッグで寄せる。
                // 端の確定は従来どおり署名の不変化で行う(ヒントは近道であって判定ではない)
                if let jump = Self.offscreenEdgeJump(snapshot: settled.snapshot, finger: direction),
                   let container = Self.webViewContainer(in: settled.snapshot),
                   await hintDrag(jump: jump, container: container, phase: &phase) {
                    hintJumps += 1
                    continue
                }
                if try await swipeWithFallback(direction, forScroll: true, phase: &phase) { viaXCUITest = true }
            }
            // 上限で抜けたら**端に着いたとは限らない**。黙って成功にすると
            // 「scrollToBottom したのに末尾が無い」の原因が読めなくなる
            var notes: [String] = []
            if !reachedEdge { notes.append("stopped at the limit of \(limit) (may not have reached the edge yet)") }
            if viaXCUITest { notes.append("fell back to XCUITest") }
            if hintJumps > 0 { notes.append("\(hintJumps) long drag(s) from scroll hints") }
            return StepOutcome(status: .passed,
                               driverFallback: notes.isEmpty ? nil : notes.joined(separator: " / "))
        }

        // 要素が見つかるまでスクロール(見つかったら成功。操作はしない)
        if action == "scrollTo" {
            let result = try await runScrollSearch(step: step, phase: &phase)
            let note = Self.scrollSearchNote(result)
            guard result.found else {
                // optional は他のアクションと同契約(出るか不定の要素をスクロール探索したとき、
                // 空振りで scene を落とさない)。tap(scroll:) が optional を伝えてくる
                if step.optional == true {
                    return StepOutcome(status: .skipped("skipped because the element was not found (optional)"))
                }
                return StepOutcome(status: .failed(Self.scrollNotFoundMessage(step)))
            }
            if let fallback = result.fallback {
                return StepOutcome(status: .passedViaFallback(fallback), driverFallback: note)
            }
            return StepOutcome(status: .passed, driverFallback: note)
        }

        // ロケータ指定のない type はフォーカス中の要素へ送る(直前の tap でフォーカスした欄など)。
        // ref: nil = ブリッジがフォーカス中要素へ入力(iOS/Android とも)。ロケータ解決を挟まない。
        if action == "type", step.locator == nil, step.fallbacks?.isEmpty ?? true {
            let start = clock.now
            let text = step.text ?? ""
            // ロケータ有り type(下記 case "type")と同じ規則: "\n" を含むときだけ
            // typeDriver(XCUITest)へ回し、iOS の Return キー既定挙動に揃える(理由は同 case のコメント参照)。
            if text.contains("\n"), let td = typeDriver {
                try await td.type(ref: nil, text: text)
            } else {
                try await driver.type(ref: nil, text: text)
            }
            phase.actionMs += Self.ms(clock.now - start)
            return StepOutcome(status: .passed)
        }

        // pressEnter もロケータを持たない(フォーカス中の入力欄への Enter 押下)ので、type(ref: nil)
        // と同じ理由でロケータ解決を挟まない。409(inapp が Compose 以外の入力欄/フォーカス無しで
        // 出す。InAppBridge.handlePressEnter 参照)は type のロケータ版と同じ形で
        // typeDriver(xcuitest)へフォールバックする
        if action == "pressEnter" {
            let start = clock.now
            do {
                try await driver.pressEnter()
            } catch {
                guard case DriverError.badResponse(let code, _) = error, code == 409,
                      let td = typeDriver else { throw error }
                try await td.pressEnter()
                phase.actionMs += Self.ms(clock.now - start)
                return StepOutcome(status: .passed, driverFallback: "fell back to XCUITest")
            }
            phase.actionMs += Self.ms(clock.now - start)
            return StepOutcome(status: .passed)
        }

        // hideKeyboard もロケータを持たない(フォーカス中の入力欄からファーストレスポンダを外す)。
        // pressEnter と同じ理由でロケータ解決を挟まないが、フォールバック判定は 409 ではなく
        // isEngineIncapable(501/ルート不明404): このエンジンでは原理的に非対応、という意味だから
        // (409 は「今フォーカス無し」等の一時的競合で、pressEnter/type の 409 とは事情が違う)
        if action == "hideKeyboard" {
            let start = clock.now
            do {
                try await driver.hideKeyboard()
            } catch {
                guard DriverError.isEngineIncapable(error), let td = typeDriver else { throw error }
                try await td.hideKeyboard()
                phase.actionMs += Self.ms(clock.now - start)
                return StepOutcome(status: .passed, driverFallback: "fell back to XCUITest")
            }
            phase.actionMs += Self.ms(clock.now - start)
            return StepOutcome(status: .passed)
        }

        // clearInput もロケータ無しならフォーカス中欄へ作用する(type(ref: nil) と同じくロケータ解決を
        // 挟まない)。対象なし(409)またはこのエンジンでは未対応(isEngineIncapable)なら
        // typeDriver(xcuitest)へフォールバックする
        if action == "clearInput", step.locator == nil, step.fallbacks?.isEmpty ?? true {
            // 事後検証(ブリッジが 200 を返しても実際に消えていない「嘘の成功」を潰す)の下ごしらえ。
            // ref が無いので、クリア前にフォーカス要素を覚えておき、クリア後の突き合わせは
            // identifier/frame で行う(residualClearValue(of:in:) 参照)。見つからなければ検証不能として
            // 後段をスキップする(検証できないことを失敗にしない)。追加 snapshot は clearInput の
            // ときだけなので他コマンドの固定費は増えない
            var snapStart = clock.now
            let beforeSnapshot = try await driver.snapshot()
            phase.snapshotMs += Self.ms(clock.now - snapStart)
            let focusedBefore = beforeSnapshot.elements.first { $0.focused == true }

            let start = clock.now
            do {
                try await driver.clearInput(ref: nil)
            } catch {
                guard Self.isClearInputFallback(error), let td = typeDriver else { throw error }
                try await td.clearInput(ref: nil)
                phase.actionMs += Self.ms(clock.now - start)
                // フォールバック経路も同じ事後検証を通す(検証されるパスに例外を作らない)
                if let focusedBefore,
                   let residual = try await residualClearValue(td, focusedBefore: focusedBefore,
                                                               phase: &phase) {
                    return StepOutcome(status: .failed(
                        "clearInput reported success but the value remained: \"\(residual)\""))
                }
                return StepOutcome(status: .passed, driverFallback: "fell back to XCUITest")
            }
            phase.actionMs += Self.ms(clock.now - start)

            if let focusedBefore,
               let residual = try await residualClearValue(driver, focusedBefore: focusedBefore,
                                                           phase: &phase) {
                guard let td = typeDriver else {
                    return StepOutcome(status: .failed(
                        "clearInput reported success but the value remained: \"\(residual)\""))
                }
                let retryStart = clock.now
                try await td.clearInput(ref: nil)
                phase.actionMs += Self.ms(clock.now - retryStart)
                if let residual2 = try await residualClearValue(td, focusedBefore: focusedBefore,
                                                                phase: &phase) {
                    return StepOutcome(status: .failed(
                        "clearInput reported success but the value remained: \"\(residual2)\""))
                }
                return StepOutcome(status: .passed, driverFallback: "fell back to XCUITest")
            }
            return StepOutcome(status: .passed)
        }

        // `tap(scroll:)` 等の内蔵スクロール探索。**別ステップにしない**のは
        // 利用者が書いたのは1コマンドだから(記録に scrollTo 行が増えると、書いていない行が
        // 現れ、しかもソース行を持たないためジャンプも修正提案の照合もできない)。
        // 探索は runScrollSearch が静止まで面倒を見るので、以降は通常の解決へ進んでよい
        if step.direction != nil, step.locator != nil {
            let result = try await runScrollSearch(step: step, phase: &phase)
            scrollSearchNote = Self.scrollSearchNote(result)
            guard result.found else {
                if step.optional == true {
                    return StepOutcome(status: .skipped("skipped because the element was not found (optional)"))
                }
                return StepOutcome(status: .failed(Self.scrollNotFoundMessage(step)))
            }
        }

        // ロケータ解決の再試行(ファイル冒頭のセマンティクス参照: 最大3回、計700ms)
        var start = clock.now
        var snapshot = try await driver.snapshot()
        phase.snapshotMs += Self.ms(clock.now - start)
        // 宣言された割り込み(アプリ内メッセージ等)が出ていれば先に閉じる。**解決を試みる前**に
        // 行う: 覆われているだけで要素自体は解決できてしまい、タップが吸われる形があるため
        // (層3 の coveringHint と同じ事象。あちらは診断、こちらは宣言があるときの自動処理)
        try await dismissInterruption(in: &snapshot, phase: &phase)
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
        // ロケータのフォールバック(.passedViaFallback)とは別物。ドライバ切替の注記のみで、
        // FTRuntime の修正提案(セレクタ更新)は誘発しない
        var driverFallback: String?
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
            return StepOutcome(status: .skipped("skipped because the element was not found (optional)"))
        } else if healingEnabled, let delegate,
                  let proposal = await delegate.healLocator(step: step, snapshot: snapshot),
                  proposal.confidence == "high" {
            // 自己修復: 新しいロケータ連鎖に置き換えたステップを返す(永続化は呼び出し側)
            element = proposal.element
            let (primary, fallbacks) = FlowLocatorBuilder.chain(for: element, in: snapshot.elements)
            var healed = step
            healed.locator = primary
            healed.fallbacks = fallbacks.isEmpty ? nil : fallbacks
            healed.note = (step.note.map { $0 + " / " } ?? "") + "self-healed: \(proposal.rationale)"
            healedStep = healed
            status = .healed(primary)
        } else {
            // 惜しい候補を添える。これが無いと直すために snapshot を取り直す往復が必要になる
            // (レポート側の全要素一覧は ScenarioReportWriter が別途出す)
            let hint = Self.candidateHint(for: step, in: snapshot)
            return StepOutcome(status: .failed(
                "cannot resolve the locator: \(step.locatorSummary)" + (hint.map { ". \($0)" } ?? "")
                    + Self.truncationHint(snapshot)
                    + Self.webViewPathHint(snapshot)))
        }
        resolvedElementThisStep = element

        switch action {
        case "select":
            // 掴むだけでデバイス操作はしない。ただし**可視性は exist と同じ規律で確かめる**
            // (覆われた要素を掴んで値を読むと、画面に見えていない値でテストが通る)。
            // `requireVisible: false` で外せる(step.occlusionGuard が false のとき素通り)
            if try await occlusionFlip(
                element: element, expectedText: element.label ?? step.locator?.label ?? "",
                elements: snapshot.elements, screen: snapshot.screen,
                looseMatch: false, perStepGuard: step.occlusionGuard,
                expectedIsUserText: step.locator?.label != nil, phase: &phase) != nil {
                // **見えないときは失敗させず空要素を返す**(呼び出し側が `.text == nil` で分岐できる)。
                // exist(検証)と違い select は「掴む」操作なので、見えない事実は値で表す
                resolvedElementThisStep = nil
                return StepOutcome(status: .passed,
                                   driverFallback: "not visible: returned an empty element")
            }
        case "tap":
            // **長押しは tap の引数**(Shirates 準拠。`tap(sel, holdSeconds:)`)。0 より大きいときだけ
            // ブリッジの /press へ回す。in-app は座標ジェスチャを持たない(501)ので XCUITest へ
            // フォールバックする経路も長押し側だけが必要
            let hold = step.duration ?? FlowStep.defaultTapHoldSeconds
            if hold > 0 {
                if typeDriverGestures.contains("press") || gestureFallbackLatched, let td = typeDriver,
                   try await pressViaTypeDriver(td, step: step, phase: &phase) {
                    return StepOutcome(status: .passed, healedStep: healedStep,
                                       healedByCache: healedByCache,
                                       driverFallback: "fell back to XCUITest")
                }
                do {
                    start = clock.now
                    try await actingDriver.press(ref: element.ref, duration: hold)
                    phase.actionMs += Self.ms(clock.now - start)
                } catch {
                    // 「このエンジンでは不可」(501 / ルート不明 404)だけ XCUITest へ回す。
                    // 409 を含めない理由は DriverError.isEngineIncapable 参照
                    guard DriverError.isEngineIncapable(error), let td = typeDriver else { throw error }
                    guard try await pressViaTypeDriver(td, step: step, phase: &phase) else { throw error }
                    gestureFallbackLatched = true
                    driverFallback = "fell back to XCUITest"
                }
                break
            }
            start = clock.now
            try await actingDriver.tap(ref: element.ref)
            phase.actionMs += Self.ms(clock.now - start)
            // ドライバが「無言 no-op になり得る経路を通った」と申告した注記(例: InAppBridge の
            // activate 不発→合成タッチ)。失敗ではないので driverFallback に載せて可視化するだけ
            if let note = actingDriver.lastActionNote { driverFallback = note }
        case "type":
            // "\n" を含む入力だけ typeDriver(XCUITest)を優先する: typeText は改行を Return
            // キー押下として発火し iOS 既定の挙動と揃うが、in-app の insertText は改行の解釈が
            // フレームワーク任せで揃わない。"\n" を含まない入力は両経路で結果が同じなので、この
            // 振り分けはエンジン間の観測可能な挙動差を生まない。
            let text = step.text ?? ""
            if let td = typeDriver, preferTypeDriver || text.contains("\n"),
               try await typeViaTypeDriver(td, step: step, phase: &phase) {
                return StepOutcome(status: .passed, healedStep: healedStep, healedByCache: healedByCache)
            }
            do {
                start = clock.now
                try await actingDriver.type(ref: element.ref, text: step.text ?? "")
                phase.actionMs += Self.ms(clock.now - start)
            } catch {
                // 409 = inapp が非 UIKit 入力欄で first responder を張れない兆候。type は要素個別の
                // フォーカス有無に依存する一時的競合なので、press/swipe と違い 501 化しない。
                guard case DriverError.badResponse(let code, _) = error, code == 409,
                      let td = typeDriver else { throw error }
                guard try await typeViaTypeDriver(td, step: step, phase: &phase) else { throw error }
                // セレクタは正しくドライバが変わっただけ = .passedViaFallback(ロケータ用)は立てない
                driverFallback = "fell back to XCUITest"
            }
        case "clearInput":
            if let td = typeDriver, preferTypeDriver,
               try await clearViaTypeDriver(td, step: step, phase: &phase) {
                return StepOutcome(status: .passed, healedStep: healedStep, healedByCache: healedByCache)
            }
            do {
                start = clock.now
                try await actingDriver.clearInput(ref: element.ref)
                phase.actionMs += Self.ms(clock.now - start)
                // 事後検証: ブリッジが 200 を返しても実際に消えていない(嘘の成功)場合の保険。
                // 同じ driver で snapshot を撮り直し、同じ locator を再解決して value を見る
                if let residual = try await residualClearValue(actingDriver, step: step,
                                                              before: element.value, phase: &phase) {
                    guard let td = typeDriver,
                          try await clearViaTypeDriver(td, step: step, phase: &phase) else {
                        return StepOutcome(status: .failed(
                            "clearInput reported success but the value remained: \"\(residual)\""))
                    }
                    if let residual2 = try await residualClearValue(td, step: step,
                                                                   before: element.value,
                                                                   phase: &phase) {
                        return StepOutcome(status: .failed(
                            "clearInput reported success but the value remained: \"\(residual2)\""))
                    }
                    driverFallback = "fell back to XCUITest"
                }
            } catch {
                guard Self.isClearInputFallback(error), let td = typeDriver else { throw error }
                guard try await clearViaTypeDriver(td, step: step, phase: &phase) else { throw error }
                // フォールバック経路も同じ事後検証を通す(**どのパスなら検証されるかに例外を作らない**。
                // 規則が無いと将来の変更で無検証の穴が復活する)
                if let residual = try await residualClearValue(td, step: step,
                                                              before: element.value, phase: &phase) {
                    return StepOutcome(status: .failed(
                        "clearInput reported success but the value remained: \"\(residual)\""))
                }
                driverFallback = "fell back to XCUITest"
            }
        case "swipeElementToElement":
            guard let endLocator = step.endLocator else {
                return StepOutcome(status: .failed("swipeElementToElement requires an end locator"))
            }
            var endStep = step
            endStep.locator = endLocator
            endStep.fallbacks = nil
            guard let (endElement, _) = Self.resolve(step: endStep, in: snapshot) else {
                let hint = Self.candidateHint(for: endStep, in: snapshot)
                return StepOutcome(status: .failed(
                    "cannot resolve the end locator: \(endStep.locatorSummary)"
                        + (hint.map { ". \($0)" } ?? "")))
            }
            let swipeDuration = step.duration ?? FlowStep.defaultSwipeDurationSeconds
            do {
                start = clock.now
                try await actingDriver.drag(fromX: element.frame.centerX, fromY: element.frame.centerY,
                                            toX: endElement.frame.centerX, toY: endElement.frame.centerY,
                                            pressSeconds: 0.05, durationSeconds: swipeDuration)
                phase.actionMs += Self.ms(clock.now - start)
            } catch {
                // in-app エンジンは drag を一切実装しない(501)ため、hybrid では typeDriver=XCUITest
                // で始点・終点を取り直す(ref はブリッジごとに別名前空間)
                guard DriverError.isEngineIncapable(error), let td = typeDriver else { throw error }
                guard try await dragViaTypeDriver(td, step: step, endStep: endStep,
                                                  durationSeconds: swipeDuration, phase: &phase) else {
                    throw error
                }
                driverFallback = "fell back to XCUITest"
            }
        default:
            return StepOutcome(status: .skipped("unknown action: \(action)"))
        }
        return StepOutcome(status: status, healedStep: healedStep, healedByCache: healedByCache,
                           driverFallback: driverFallback)
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

    /// typeDriver で press を試みる。ref はブリッジごとに別名前空間なので typeDriver 側 snapshot で
    /// 取り直す(typeViaTypeDriver と同じ理由)。解決できなければ false(呼び出し側で再スロー)。
    private func pressViaTypeDriver(_ td: AppDriver, step: FlowStep,
                                    phase: inout PhaseAccumulator) async throws -> Bool {
        let clock = ContinuousClock()
        var start = clock.now
        let snapshot = try await td.snapshot()
        phase.snapshotMs += Self.ms(clock.now - start)
        guard let resolved = Self.resolveDetailed(step: step, in: snapshot) else { return false }
        start = clock.now
        try await td.press(ref: resolved.element.ref,
                           duration: step.duration ?? FlowStep.defaultTapHoldSeconds)
        phase.actionMs += Self.ms(clock.now - start)
        return true
    }

    /// clearInput のフォールバック判定: 409(in-app の対象なし/フォーカス無し。type の 409 と同じ
    /// 一時的競合)、422(XCUITest ランナーの同じ事情。**あちらは 409 を使えない** —
    /// SessionRecoveryDriver がセッション消失と断定するため。BridgeRouter.handleClear 参照)、
    /// または isEngineIncapable(このエンジンでは未対応)なら typeDriver へ回してよい
    private static func isClearInputFallback(_ error: Error) -> Bool {
        if DriverError.isEngineIncapable(error) { return true }
        if case DriverError.badResponse(let status, _) = error, status == 409 || status == 422 {
            return true
        }
        return false
    }

    /// typeDriver で clearInput を試みる。ref はブリッジごとに別名前空間なので typeDriver 側 snapshot で
    /// 取り直す(typeViaTypeDriver と同じ理由)。解決できなければ false(呼び出し側で再スロー)。
    private func clearViaTypeDriver(_ td: AppDriver, step: FlowStep,
                                    phase: inout PhaseAccumulator) async throws -> Bool {
        let clock = ContinuousClock()
        var start = clock.now
        let snapshot = try await td.snapshot()
        phase.snapshotMs += Self.ms(clock.now - start)
        guard let resolved = Self.resolveDetailed(step: step, in: snapshot) else { return false }
        start = clock.now
        try await td.clearInput(ref: resolved.element.ref)
        phase.actionMs += Self.ms(clock.now - start)
        return true
    }

    /// clearInput 事後検証: 残っている値(nil = 消えている/判定不能)。
    /// **`placeholder` フィールドとの一致では判定できない**ので「クリア前の値からの変化」で見る:
    /// 空欄の `value` に placeholder 文字列が入る実装があり(iOS 全般 / **Android の CMP は
    /// `placeholder` を送らないまま value に入れる** ―― 2026-07-30 実測)、一致判定は素通りする。
    /// **層3は保険なので誤検出ゼロに倒す**(検出漏れは層2 = 受け口側の読み返しが拾う):
    /// 値が変わっていれば消えたと見なし、`before` が空/placeholder なら「消すものが無かった」
    /// として検証しない
    private static func residualClearValue(before: String?, after: String?,
                                          placeholder: String?) -> String? {
        guard let before, !before.isEmpty, before != placeholder else { return nil }
        guard let after, !after.isEmpty, after != placeholder else { return nil }
        return after == before ? after : nil
    }

    /// clearInput(ref あり)の事後検証。渡された snapshot 内で同じ step(locator)を解決し直して
    /// クリア前の値と比べる。解決できない(要素が消えた等)ときは検証不能なので nil
    /// (検証できないことを失敗にしない)
    private static func residualClearValue(step: FlowStep, before: String?,
                                          in snapshot: SnapshotResponse) -> String? {
        guard let (found, _) = Self.resolve(step: step, in: snapshot) else { return nil }
        return Self.residualClearValue(before: before, after: found.value,
                                       placeholder: found.placeholder)
    }

    /// clearInput(ref あり)の事後検証: 同じ driver で snapshot を撮り直してから残存値を見る。
    /// **単発では判定しない**(ロケータ解決の再試行と同じ規律で最大3回・計約700ms):
    /// Android の `ACTION_SET_TEXT` は a11y ツリーへの反映が数十〜数百ms遅れ、1発勝負では
    /// 消えているのに古い値を読んで誤検出する(2026-07-30 実測。textIs がポーリングで
    /// 吸収しているのと同じ事情)
    private func residualClearValue(_ driver: AppDriver, step: FlowStep, before: String?,
                                    phase: inout PhaseAccumulator) async throws -> String? {
        let clock = ContinuousClock()
        var backoff = PollBackoff()
        var residual: String?
        for attempt in 0..<3 {
            if attempt > 0 {
                let waitStart = clock.now
                try await Task.sleep(for: backoff.nextDelay())
                phase.waitMs += Self.ms(clock.now - waitStart)
            }
            let start = clock.now
            let snapshot = try await driver.snapshot()
            phase.snapshotMs += Self.ms(clock.now - start)
            residual = Self.residualClearValue(step: step, before: before, in: snapshot)
            if residual == nil { return nil }
        }
        return residual
    }

    /// clearInput(ref なし)の事後検証: クリア前に覚えた要素を撮り直した snapshot で突き合わせる。
    /// ref あり版と同じ理由でポーリングする(単発では反映遅れを誤検出する)
    private func residualClearValue(_ driver: AppDriver, focusedBefore: ElementInfo,
                                    phase: inout PhaseAccumulator) async throws -> String? {
        let clock = ContinuousClock()
        var backoff = PollBackoff()
        var residual: String?
        for attempt in 0..<3 {
            if attempt > 0 {
                let waitStart = clock.now
                try await Task.sleep(for: backoff.nextDelay())
                phase.waitMs += Self.ms(clock.now - waitStart)
            }
            let start = clock.now
            let snapshot = try await driver.snapshot()
            phase.snapshotMs += Self.ms(clock.now - start)
            residual = Self.residualClearValue(of: focusedBefore, in: snapshot)
            if residual == nil { return nil }
        }
        return residual
    }

    /// clearInput(ref なし)の事後検証。クリア前に覚えた要素をクリア後の snapshot で同一要素として
    /// 突き合わせる。**identifier 優先、無ければ frame 一致**(ref はスナップショット毎に振り直され
    /// フォールバック後は driver も変わるため使えない)。見つからなければ検証不能なので nil
    private static func residualClearValue(of before: ElementInfo, in snapshot: SnapshotResponse) -> String? {
        let match: ElementInfo?
        if let identifier = before.identifier {
            match = snapshot.elements.first { $0.identifier == identifier }
        } else {
            match = snapshot.elements.first { $0.frame == before.frame }
        }
        guard let match else { return nil }
        return Self.residualClearValue(before: before.value, after: match.value,
                                       placeholder: match.placeholder)
    }

    /// typeDriver で始点・終点を取り直してドラッグする(ref はブリッジごとに別名前空間なので、
    /// typeViaTypeDriver と同じ理由で両方とも撮り直す)。解決できなければ false(呼び出し側で再スロー)。
    private func dragViaTypeDriver(_ td: AppDriver, step: FlowStep, endStep: FlowStep,
                                   durationSeconds: Double,
                                   phase: inout PhaseAccumulator) async throws -> Bool {
        let clock = ContinuousClock()
        var start = clock.now
        let snapshot = try await td.snapshot()
        phase.snapshotMs += Self.ms(clock.now - start)
        guard let (from, _) = Self.resolve(step: step, in: snapshot),
              let (to, _) = Self.resolve(step: endStep, in: snapshot) else { return false }
        start = clock.now
        try await td.drag(fromX: from.frame.centerX, fromY: from.frame.centerY,
                          toX: to.frame.centerX, toY: to.frame.centerY,
                          pressSeconds: 0.05, durationSeconds: durationSeconds)
        phase.actionMs += Self.ms(clock.now - start)
        return true
    }

    /// swipe を通常ドライバ→(typeDriverGestures 申告/ラッチ済みなら最初から、501 ならキャッチしてから)
    /// typeDriver の順で試す。swipe は ref を使わないので要素再解決は不要。
    /// 戻り値: true = typeDriver(XCUITest)経由で実行した
    /// スクロール探索で要素を見つけた直後、**その要素の frame が動かなくなるまで**待つ。
    /// 連続2回同じ frame なら静止とみなす。見失った場合・上限に達した場合はそのまま抜ける
    /// (探索自体は成功しているので、ここで失敗にはしない = 判定を1箇所に保つ)。
    /// 上限はフリングの減速が収まる実測レンジに合わせた固定値で、調整ノブにはしない
    private func settleAfterScroll(step: FlowStep, found: ElementInfo,
                                   phase: inout PhaseAccumulator) async throws {
        let clock = ContinuousClock()
        var previous = found.frame
        for _ in 0..<Self.scrollSettleMaxPolls {
            let waitStart = clock.now
            try await Task.sleep(for: .milliseconds(Self.scrollSettleIntervalMs))
            phase.waitMs += Self.ms(clock.now - waitStart)
            let start = clock.now
            let snapshot = try await driver.snapshot()
            phase.snapshotMs += Self.ms(clock.now - start)
            guard let (element, _) = Self.resolve(step: step, in: snapshot,
                                                  strictForAssert: true) else { return }
            if element.frame == previous { return }
            previous = element.frame
        }
    }

    /// スクロール探索終端の空打ちドラッグを (x,y) に打ってよいか。打たない条件は2つ
    /// (どちらも「空打ちが別の UI に渡って画面が変わる」実害の再発防止):
    /// 1. 対象より手前の要素が点を取る(タブバー等。pointIsTakenByFrontElement)
    /// 2. 点が**画面下端の帯**にある。タブバーの実ヒット域は a11y frame の下(ホームインジケータ域
    ///    =画面下端)まで伸びるのに、その帯は a11y 上は空白で 1 が効かない
    ///    (実測 2026-07-28: タブ frame 下端 840・画面高 874 で、帯内 y=841.8 への空打ちで
    ///    #tab_home が反応しホームへ遷移。E2E-iOS 07/16 の間欠フレークの根因)
    static func emptyDragIsSafe(x: Double, y: Double, of element: ElementInfo,
                                in elements: [ElementInfo], screen: FTRect) -> Bool {
        if pointIsTakenByFrontElement(x: x, y: y, of: element, in: elements) { return false }
        if y >= screen.y + screen.height - Self.bottomUncoveredBand { return false }
        return true
    }

    /// 画面下端の a11y 空白帯の高さ(pt)。実測の空白(874-840=34)+整定位置のブレの余裕
    static let bottomUncoveredBand: Double = 48

    /// その座標のタッチが**対象ではなく手前の別要素に渡る**か。スナップショットは pre-order
    /// (後 = 手前寄り)なので、対象より後ろにあって点を含む要素が居れば取られ得る。
    /// 対象の子孫は同じ見た目の一部なので除く。空打ちドラッグの安全判定に使う
    static func pointIsTakenByFrontElement(x: Double, y: Double, of element: ElementInfo,
                                           in elements: [ElementInfo]) -> Bool {
        guard let index = elements.firstIndex(where: { $0.ref == element.ref }) else { return false }
        let ownRefs = Set(descendants(of: element, in: elements).map(\.ref))
        return elements[elements.index(after: index)...].contains { other in
            guard !ownRefs.contains(other.ref) else { return false }
            let f = other.frame
            return x >= f.x && x <= f.x + f.width && y >= f.y && y <= f.y + f.height
        }
    }

    /// スクロール静止待ちの上限(回数 × 間隔 = 最大 600ms)。フリングの減速はこの範囲で収まる
    static let scrollSettleMaxPolls = 6
    static let scrollSettleIntervalMs = 100

    /// 画面が静止するまで待ち、そのときの要素配置の署名を返す(scrollToEdge の到達判定)。
    /// **横スクロールでは y が動かない**ので x と y の両方を入れる。
    /// ref は取り直しで振り直されるため使わない(型と座標だけで比較する)。
    /// 静止時点のスナップショットも返す(scrollToEdge のヒント跳躍が再利用する。
    /// 別途撮り直すと iOS xcuitest では1周 約380ms の追加になるため)
    ///
    /// **label を署名に入れてはいけない**(2026-07-31 実測。入れると SwiftUI List で永久に
    /// 収束しない): 画面外まで含む行のうち 2 件が、静止画面でも取得のたびに別の行のラベルを
    /// 名乗り、A↔B で交互に振れ続ける(XCUITest が再利用セル群の古いラベルを読むため。
    /// frame は 1pt も動かない)。結果 settledSignature は毎回 6 poll を使い切り、
    /// scrollToEdge の「連続2回不変=端」も成立せず maxSwipes 上限まで回っていた
    /// (E2E-iOS/ios-xcuitest の scrollToTop で 44〜55s。同じ画面が in-app では 1.5s)。
    /// **判定したいのは「動いているか」なので frame だけで足りる**
    /// (settleAfterScroll も同じ理由で frame だけを見ている)。
    /// 逆に**ランナー側の captureSettled では label を外さない** — あちらは tap 直後の
    /// 「内容が更新されたか」を待つので、レイアウトが変わらずテキストだけ変わる更新を
    /// 取りこぼすと stale なツリーを返す
    private func settledSignature(
        phase: inout PhaseAccumulator) async throws -> (signature: String, snapshot: SnapshotResponse) {
        func signature(_ snapshot: SnapshotResponse) -> String {
            snapshot.elements
                .map { "\($0.type)|\($0.frame.x),\($0.frame.y)" }
                .joined(separator: ",")
        }
        let clock = ContinuousClock()
        var start = clock.now
        var last = try await driver.snapshot()
        var previous = signature(last)
        phase.snapshotMs += Self.ms(clock.now - start)
        for _ in 0..<Self.scrollSettleMaxPolls {
            let waitStart = clock.now
            try await Task.sleep(for: .milliseconds(Self.scrollSettleIntervalMs))
            phase.waitMs += Self.ms(clock.now - waitStart)
            start = clock.now
            last = try await driver.snapshot()
            let current = signature(last)
            phase.snapshotMs += Self.ms(clock.now - start)
            if current == previous { return (current, last) }
            previous = current
        }
        return (previous, last)
    }


    /// スクロール探索直後の「空打ち」極小ドラッグ(呼ぶ条件は呼び出し側の判定を参照)。
    /// **in-app エンジンは drag を一切実装しない**(501)ため、hybrid では typeDriver=XCUITest へ
    /// 回さないとこの対策が丸ごと不発になる(= Compose の容器がタッチを1回吸ったままになり、
    /// 直後の tap/press が空振りする)。空打ちは補助でありこれ自体の失敗はステップの失敗にしない
    /// (両経路とも失敗したら黙って進む = 従来の `try?` と同じ扱い)
    private func emptyDrag(x: Double, y: Double) async {
        func drag(_ target: AppDriver) async throws {
            try await target.drag(fromX: x, fromY: y, toX: x + 2, toY: y,
                                  pressSeconds: 0.05, durationSeconds: 0.05)
        }
        if dragFallbackLatched, let td = typeDriver {
            try? await drag(td)
            return
        }
        do {
            try await drag(driver)
        } catch {
            guard DriverError.isEngineIncapable(error), let td = typeDriver else { return }
            dragFallbackLatched = true
            try? await drag(td)
        }
    }

    /// forScroll: **スクロールが目的**か(scrollTo / scrollToEdge / scroll)。DSL の `swipe` は
    /// ジェスチャ自体が目的なので false。in-app の Compose/Flutter だけがこの区別を使う
    /// (`SwipeRequest.scroll` の説明を参照。混ぜるとジェスチャ画面が黙って空振りする)
    private func swipeWithFallback(_ direction: FTSwipeDirection, forScroll: Bool = false,
                                   phase: inout PhaseAccumulator) async throws -> Bool {
        let clock = ContinuousClock()
        if typeDriverGestures.contains("swipe") || gestureFallbackLatched, let td = typeDriver {
            let start = clock.now
            try await td.swipe(direction, forScroll: forScroll)
            phase.actionMs += Self.ms(clock.now - start)
            return true
        }
        do {
            let start = clock.now
            try await driver.swipe(direction, forScroll: forScroll)
            phase.actionMs += Self.ms(clock.now - start)
            return false
        } catch {
            // 「このエンジンでは不可」(501 / ルート不明 404)だけ XCUITest へ回す。
            // 409 を含めない理由は DriverError.isEngineIncapable 参照
            guard DriverError.isEngineIncapable(error), let td = typeDriver else { throw error }
            let start = clock.now
            try await td.swipe(direction, forScroll: forScroll)
            phase.actionMs += Self.ms(clock.now - start)
            gestureFallbackLatched = true
            return true
        }
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
            if strictForAssert, fallback.isWeakForAssert { continue }
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
        matchDetailed(locator, elements: snapshot.elements)
    }

    /// ロケータに一致する要素を 1 つ選ぶ。選択規則:
    /// 属性フィルタ(全て AND)で絞る → `[n]` 番目を採る → 相対ステップがあれば順に辿る。
    /// 相対セレクタ(`通知:rightSwitch`)では属性フィルタが**対象ではなく基準**を指す。
    public static func matchDetailed(_ locator: FlowLocator, elements: [ElementInfo])
        -> (ElementInfo, MatchQuality)? {
        guard let matches = candidates(locator, elements: elements), !matches.isEmpty else {
            return nil
        }
        let index = locator.index ?? 0
        guard index < matches.count else { return nil }
        var current = matches[index]
        let baseQuality = Self.quality(of: current, for: locator)
        guard let steps = locator.relative, !steps.isEmpty else { return (current, baseQuality) }
        // 相対ステップの候補もスコープの中から採る(節の中は全部同じ pool で解決する)
        guard let pool = scopedPool(locator.scope, elements: elements) else { return nil }
        // 品質は**返す要素**の話なので、最後のステップの判定だけが残る
        // (基準や途中のステップを部分一致で書いても、最終的に掴んだ要素の一致品質とは無関係)
        var quality = MatchQuality.exact
        for step in steps {
            guard let next = resolveRelative(step, from: current, pool: pool) else { return nil }
            current = next.element
            quality = next.quality
        }
        return (current, quality)
    }

    /// 一致品質。**記法(部分一致かどうか)ではなく掴んだ要素**で判定する
    /// (`*ログイン*` が "ログインに失敗しました" を掴めば substring、"ログイン" を掴めば exact)。
    /// 読み手はハイブリッドの偽陽性抑止(fallback の exact を primary の substring より優先)だけ
    static func quality(of element: ElementInfo, for locator: FlowLocator) -> MatchQuality {
        guard let label = locator.label else { return .exact }
        return element.label == label ? .exact : .substring
    }

    /// 相対ステップ1つ分。フィルタ連鎖は `||` と同じく**候補集合の和**(Shirates 準拠)で、
    /// 節ごとに方向解決するのではなく**全節の候補を合わせてから方向で並べる**
    /// (`:right(.button||.switch)` = 「両者のうち最も近い1つ」。節の順は同着の並びにだけ効く)。
    /// フィルタ省略時は `.widget`(役割が確定した要素だけ = 容器やレイアウトノードを掴まない)
    static func resolveRelative(_ step: FlowRelativeStep, from anchor: ElementInfo,
                                pool: [ElementInfo]) -> (element: ElementInfo, quality: MatchQuality)? {
        let filters = (step.filter?.isEmpty ?? true)
            ? [FlowLocator(type: "widget")] : step.filter!
        var union: [(element: ElementInfo, filter: FlowLocator)] = []
        var seen: Set<Int> = []
        for filter in filters {
            for element in resolvedCandidates(filter, elements: pool) ?? [] {
                guard seen.insert(element.ref).inserted else { continue }
                union.append((element, filter))
            }
        }
        guard !union.isEmpty else { return nil }
        let ordered = directionalCandidates(union.map(\.element), anchor: anchor,
                                            direction: step.direction)
        // 序数は `:right(2)` が本線。`:right(.button&&[2])` はパースが step.ordinal へ畳むので、
        // ここに残る節ごとの `[n]` は「節で違う値を手書きした」場合だけ = 最初の1つを和集合の序数に使う。
        // 節自身が相対セレクタのときの index は基準の選択で消費済みなので見ない
        let filterIndex = filters.first { ($0.relative?.isEmpty ?? true) && $0.index != nil }?.index
        let ordinal = step.ordinal ?? ((filterIndex ?? 0) + 1)
        guard ordinal >= 1, ordinal <= ordered.count else { return nil }
        let picked = ordered[ordinal - 1]
        // 一致品質は**掴んだ要素を出した節**で判定する(和集合なので節は要素ごとに違う)
        let filter = union.first { $0.element.ref == picked.ref }?.filter ?? filters[0]
        return (picked, quality(of: picked, for: filter))
    }

    /// 節連鎖(`||`)が指す候補集合。**Shirates 準拠の和集合**で、順序は「節の順 → 節内のツリー順」、
    /// 同一要素(ref)は先に現れた節のものだけを残す(Shirates の filterBySelector と同じ規則)。
    /// 要素を1つ選ぶ経路(resolveDetailed)が「最初に解決した節」を採るのと優先順位が一致するので、
    /// `#id||ラベル` のヒール連鎖は和集合にしても先頭が変わらない。
    /// **節ごとの `[n]` はここでは見ない**(集合を数える用途では `.button[2]` も全 button を指す)
    public static func unionCandidates(_ chain: [FlowLocator], elements: [ElementInfo])
        -> [ElementInfo] {
        unionByClause(chain, elements: elements).flatMap(\.elements)
    }

    /// 「親子で重ねて数えている」ときだけ付ける案内。**直し方(型で絞る)まで書く** —
    /// これを知らないと `countIs("項目", 3)` が 6 を返す理由に辿り着けない(実際に踏んだ)
    static func nestingHint(_ matched: [ElementInfo], in all: [ElementInfo]) -> String {
        let outer = outermostCount(matched, in: all)
        guard outer != matched.count, outer > 0 else { return "" }
        // 外側だけに残る型が1つなら、そのまま書ける形で提案する
        let matchedRefs = Set(matched.map(\.ref))
        var nested: Set<Int> = []
        for element in matched {
            for descendant in descendants(of: element, in: all)
            where matchedRefs.contains(descendant.ref) { nested.insert(descendant.ref) }
        }
        let outerTypes = Set(matched.filter { !nested.contains($0.ref) }.map(\.type))
        let suggestion = outerTypes.count == 1 ? " (e.g. `.\(outerTypes.first!)&&…`)" : ""
        return ". **Parent and child are being counted as the same element** — narrowing by type gives \(outer)"
            + suggestion + ". A button and the label inside it are separate elements and both appear in the tree"
    }

    /// 数えた要素の中に**親子関係のもの**(ボタンとその内側の Text 等)が混ざっていないか。
    /// 返すのは「子孫を除いた件数」で、元の件数と違えばラベルだけで数えている疑いが濃い。
    /// **フレームワーク一般の性質**(Compose / SwiftUI / Flutter とも、ボタンとラベルが
    /// 別要素として両方ツリーに載る)なので、利用者は必ず一度は踏む。型で絞れば解決する
    public static func outermostCount(_ matched: [ElementInfo], in all: [ElementInfo]) -> Int {
        guard matched.count > 1 else { return matched.count }
        let matchedRefs = Set(matched.map(\.ref))
        var nested: Set<Int> = []
        for element in matched {
            for descendant in descendants(of: element, in: all)
            where descendant.ref != element.ref && matchedRefs.contains(descendant.ref) {
                nested.insert(descendant.ref)
            }
        }
        return matched.count - nested.count
    }

    /// 和集合を**節ごとの寄与に分けて**返す(countIs の失敗メッセージの内訳用)。
    /// 重複は先に現れた節に数えるので、**各節の件数の合計 = 和集合の総数**になる
    /// (合計が表示件数と合わないと、内訳がかえって混乱のもとになる)
    public static func unionByClause(_ chain: [FlowLocator], elements: [ElementInfo])
        -> [(clause: FlowLocator, elements: [ElementInfo])] {
        var result: [(clause: FlowLocator, elements: [ElementInfo])] = []
        var seen: Set<Int> = []
        for locator in chain {
            var mine: [ElementInfo] = []
            for element in resolvedCandidates(locator, elements: elements) ?? [] {
                guard seen.insert(element.ref).inserted else { continue }
                mine.append(element)
            }
            result.append((locator, mine))
        }
        return result
    }

    /// 節が指す候補集合。**相対ステップ付きは解決結果の 0 or 1 件**になる
    /// (`candidates` は属性フィルタしか見ないので、countIs のような「集合を数える」用途が
    /// `通知:rightSwitch` を基準の個数で数えてしまうのを防ぐ)。
    /// 相対ステップのフィルタ自身がさらに相対セレクタでもよい(連鎖は有限なので停止する)
    public static func resolvedCandidates(_ locator: FlowLocator, elements: [ElementInfo])
        -> [ElementInfo]? {
        guard locator.relative?.isEmpty ?? true else {
            return matchDetailed(locator, elements: elements).map { [$0.0] } ?? []
        }
        return candidates(locator, elements: elements)
    }

    /// スコープ連鎖(`#list >> ...`)を外側から順に適用した候補プール。
    /// 途中の容器が解決できなければ nil(= その節は不一致)
    static func scopedPool(_ scope: [FlowLocator]?, elements: [ElementInfo]) -> [ElementInfo]? {
        var pool = elements
        for scopeLocator in scope ?? [] {
            guard let (container, _) = matchDetailed(scopeLocator, elements: pool) else { return nil }
            pool = descendants(of: container, in: elements)
        }
        return pool
    }

    /// ロケータの属性フィルタに一致する全要素(スナップショットのツリー順)。
    /// **フィルタは全て AND**。一致ゼロなら空、絞り込み条件が1つも無ければ nil
    /// (スコープだけは条件として認める。`#list >> [2]` を書けるようにするため)。
    /// 相対ステップ(`relative`)と序数(`index`)はここでは見ない —
    /// 呼び手(matchDetailed)が基準を決めてから辿る。
    public static func candidates(_ locator: FlowLocator, elements: [ElementInfo]) -> [ElementInfo]? {
        guard var pool = scopedPool(locator.scope, elements: elements) else { return [] }
        if locator.hasNoFilter, locator.scope?.isEmpty ?? true { return nil }
        // 素の文字列は**完全一致**。部分一致は `*x*` 等で明示したときだけ
        func narrow(_ text: String?, _ mode: FlowMatchMode?, _ attribute: @escaping (ElementInfo) -> String?) {
            guard let text else { return }
            let mode = mode ?? .exact
            pool = pool.filter { mode.matches(attribute($0), text) }
        }
        if let type = locator.type {
            // エイリアス(input/widget)はここで実型集合へ展開する
            let types = Set(FlowTypeAlias.expand(type))
            pool = pool.filter { types.contains($0.type) }
        }
        narrow(locator.id, locator.idMatch) { $0.identifier }
        narrow(locator.label, locator.labelMatch) { $0.label }
        narrow(locator.value, locator.valueMatch) { $0.value }
        narrow(locator.placeholder, locator.placeholderMatch) { $0.placeholder }
        // checked は true のときだけ送られる = false は「オフ、または状態を持たない要素」
        if let checked = locator.checked { pool = pool.filter { ($0.checked ?? false) == checked } }
        if let enabled = locator.enabled { pool = pool.filter { $0.enabled == enabled } }
        // 除外条件(`text!=キャンセル`)は**肯定フィルタで絞ったあと**に引く。
        // 否定だけの節は上の hasNoFilter で既に nil を返しているので、ここには来ない
        for exclusion in locator.not ?? [] {
            let excluded = Set(candidates(exclusion, elements: pool)?.map(\.ref) ?? [])
            if excluded.isEmpty { continue }
            pool = pool.filter { !excluded.contains($0.ref) }
        }
        return pool
    }

    /// 否定系アサート(`*Not` / `*IsEmpty` / `*IsNotEmpty`)の判定。
    /// **可視性は見ない**(見えていないことは画面照合できない)。text/value の別は呼び手が解決済み
    static func negativeAssertSatisfied(_ assert: String, actual: String?,
                                        expected: String?) -> Bool {
        let text = actual ?? ""
        switch assert {
        case "textIsEmpty", "valueIsEmpty": return text.isEmpty
        case "textIsNotEmpty", "valueIsNotEmpty": return !text.isEmpty
        case "textStartsWithNot", "valueStartsWithNot":
            return !text.hasPrefix(expected ?? "")
        case "textContainsNot", "valueContainsNot":
            return !text.contains(expected ?? "")
        case "textEndsWithNot", "valueEndsWithNot":
            return !text.hasSuffix(expected ?? "")
        case "textMatchesNot", "valueMatchesNot":
            return text.range(of: expected ?? "", options: .regularExpression) == nil
        default:   // textNotEquals / valueNotEquals
            return actual != expected
        }
    }

    /// アサート種別ごとの一致判定。戻り値は「画面上で実際に一致した文字列」(occlusion-guard 用)、
    /// 不一致なら nil。textMatches は**部分一致の正規表現**(^...$ を書けば全体一致になる)
    static func matchedText(_ actual: String?, expected: String, assert: String) -> String? {
        guard let actual else { return nil }
        switch assert {
        case "textContains", "valueContains":
            return actual.contains(expected) ? expected : nil
        case "textStartsWith", "valueStartsWith":
            return actual.hasPrefix(expected) ? expected : nil
        case "textEndsWith", "valueEndsWith":
            return actual.hasSuffix(expected) ? expected : nil
        case "textMatchesDateFormat", "valueMatchesDateFormat":
            // 日付書式(`yyyy/MM/dd` 等)。DateFormatter で往復できたら一致とみなす
            let formatter = DateFormatter()
            formatter.locale = Locale(identifier: "en_US_POSIX")
            formatter.dateFormat = expected
            return formatter.date(from: actual) != nil ? actual : nil
        case "textMatches", "valueMatches":
            guard let range = actual.range(of: expected, options: .regularExpression) else {
                return nil
            }
            return String(actual[range])
        default:
            return actual == expected ? expected : nil
        }
    }

    /// 解決できなかったロケータに「惜しい候補」を最大3件添える(失敗メッセージ用)。
    /// 優先度: id の部分一致 → ラベルの部分一致 → 同じ型。1件も無ければ nil(黙って何も足さない)
    static func candidateHint(for step: FlowStep, in snapshot: SnapshotResponse) -> String? {
        guard let locator = step.locator else { return nil }
        let elements = snapshot.elements
        var picked: [ElementInfo] = []

        func add(_ candidates: [ElementInfo]) {
            for candidate in candidates where !picked.contains(where: { $0.ref == candidate.ref }) {
                picked.append(candidate)
                if picked.count >= 3 { return }
            }
        }
        if let id = locator.id?.lowercased(), !id.isEmpty {
            add(elements.filter {
                guard let other = $0.identifier?.lowercased() else { return false }
                return other.contains(id) || id.contains(other)
            })
        }
        if let label = locator.label?.lowercased(), !label.isEmpty, picked.count < 3 {
            add(elements.filter {
                guard let other = $0.label?.lowercased() else { return false }
                return other.contains(label) || label.contains(other)
            })
        }
        if let type = locator.type, picked.count < 3 {
            // エイリアス(.input / .widget)も実型集合へ展開して候補を挙げる
            let types = Set(FlowTypeAlias.expand(type))
            add(elements.filter { types.contains($0.type) })
        }
        var hints: [String] = []
        if !picked.isEmpty {
            let summaries = picked.prefix(3).map { element -> String in
                var parts = [element.type]
                if let id = element.identifier, !id.isEmpty { parts.append("#\(id)") }
                if let label = element.label, !label.isEmpty {
                    parts.append("\"\(SnapshotRenderer.truncate(label, 24))\"")
                }
                return parts.joined(separator: " ")
            }
            hints.append("near matches: \(summaries.joined(separator: " / "))")
        }
        if let hint = partialMatchHint(for: locator, in: elements) { hints.append(hint) }
        // 候補の区切りが " / " なので、ヒント同士は別の記号で割る(読み手が機械でも人でも混ざらない)
        return hints.isEmpty ? nil : hints.joined(separator: "。")
    }

    /// 完全一致のラベル指定が外れたが**部分一致なら在る**ときに書き方を示す
    /// (素の文字列は完全一致なので、部分一致で拾いたいなら記法で明示する必要がある)
    static func partialMatchHint(for locator: FlowLocator, in elements: [ElementInfo]) -> String? {
        guard let label = locator.label, !label.isEmpty,
              (locator.labelMatch ?? .exact) == .exact,
              !elements.contains(where: { $0.label == label }),
              elements.contains(where: { ($0.label ?? "").contains(label) }) else { return nil }
        return "present as a partial match: writing \"*\(label)*\" would find it"
    }

    /// 要素の子孫(スナップショットは pre-order + 元ツリーの depth を保つため、
    /// 直後から depth がその要素以下になるまでが子孫。3 ブリッジとも同じ規約で組み立てる
    /// [BridgeRouter.collect / InAppSnapshot.collect / SnapshotBuilder.collect]。
    /// 中間ノードのフィルタや上限打ち切りは pre-order を崩さないのでこの判定は保たれる)
    public static func descendants(of element: ElementInfo, in elements: [ElementInfo]) -> [ElementInfo] {
        guard let start = elements.firstIndex(where: { $0.ref == element.ref }) else { return [] }
        var result: [ElementInfo] = []
        var index = elements.index(after: start)
        while index < elements.endIndex, elements[index].depth > element.depth {
            result.append(elements[index])
            index = elements.index(after: index)
        }
        return result
    }

    /// 相対セレクタ(`通知:rightSwitch`)の選択規則。**この 1 箇所が唯一の解釈者**で、
    /// 仕様は次の3条件のみ(調整値・閾値を持たない = 同じ画面なら常に同じ順序を返す):
    ///  1. 帯: 候補の中心が、基準の frame をその軸方向に無限に伸ばした帯に入る
    ///     (right/left なら中心 y が anchor の y..y+height、above/below なら中心 x が x..x+width)
    ///  2. 向き: 候補の中心が基準の中心よりその方向にある
    ///  3. 順序: 条件を満たすものを方向軸の中心間距離の昇順に並べる。同距離はツリー順
    /// 戻り値が空 = **解決失敗**。条件を満たす候補が無いとき「最も近いものを返す」ことはしない
    /// (レイアウトが変わったときに黙って別要素を掴ませないため)。序数(`:right(2)`)はこの並びの n 番目。
    /// 基準自身は候補から除く。画面外要素は frame が丸められる環境があるため可視要素にのみ有効。
    static func directionalCandidates(_ candidates: [ElementInfo], anchor: ElementInfo,
                                      direction: FlowDirection) -> [ElementInfo] {
        let base = anchor.frame
        var scored: [(element: ElementInfo, distance: Double, order: Int)] = []
        for (order, candidate) in candidates.enumerated() where candidate.ref != anchor.ref {
            let frame = candidate.frame
            let inBand: Bool
            let ahead: Bool
            let distance: Double
            switch direction {
            case .right, .left:
                inBand = frame.centerY >= base.y && frame.centerY <= base.y + base.height
                ahead = direction == .right
                    ? frame.centerX > base.centerX : frame.centerX < base.centerX
                distance = abs(frame.centerX - base.centerX)
            case .above, .below:
                inBand = frame.centerX >= base.x && frame.centerX <= base.x + base.width
                ahead = direction == .below
                    ? frame.centerY > base.centerY : frame.centerY < base.centerY
                distance = abs(frame.centerY - base.centerY)
            }
            guard inBand, ahead else { continue }
            scored.append((candidate, distance, order))
        }
        return scored
            .sorted { $0.distance == $1.distance ? $0.order < $1.order : $0.distance < $1.distance }
            .map(\.element)
    }
}
