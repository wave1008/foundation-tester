// StepExecutor.swift
// 単一 FlowStep の決定的実行エンジン(Swift DSL のコマンドは全てここを通る)。
// 実証済みのセマンティクス:
// - ロケータ解決失敗は指数バックオフ(100→200→400ms、計3回)で再試行してからヒールへ
//   (UI 遷移直後対策。ヒール発動までの総待機は計700ms)。step.timeout 指定時はアクションも
//   その秒数を予算にリトライ(0 = リトライなし。省略時=nilは従来の3回固定のまま)
// - アサーションでは type+index のみのフォールバックを使わない(別画面要素への偽陽性防止)。
//   ただしスコープ付き(`#list >> .Cell[2]`)は容器に錨があるので除外しない(FlowLocator.isWeakForAssert)
// - **要素未発見で失敗しない唯一のアクションは `select`**(空要素を返す契約。DSL の
//   `FTElement.isEmpty` が真になる)。自己修復の対象にもしない。他は全て失敗=シナリオ中断
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
        /// verify のブロックにアサーションが1つも無かった等、passed でも failed でもなく
        /// 「結論が出ない」状態(2026-08-03 ユーザー決定)。シナリオは中断しない = 失敗扱いしない
        case inconclusive(String)
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
    /// driverFallback のうち **run を跨いで数えたい注記**の機械可読コード(StepNote)。
    /// `execute(_:cached:)` が per-step の累積器から詰めるので、**内側の return では空のまま**でよい
    /// (外側で組み直される)。表示文言との同期は `StepExecutor.note(_:into:)` が担保する
    public let notes: [StepNote]
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
               notes: [StepNote] = [],
               observedChecked: Bool? = nil, resolvedElement: ElementInfo? = nil,
               at: String = ISO8601Millis.string(from: Date())) {
        self.observedChecked = observedChecked
        self.resolvedElement = resolvedElement
        self.status = status
        self.healedStep = healedStep
        self.healedByCache = healedByCache
        self.timing = timing
        self.driverFallback = driverFallback
        self.notes = notes
        self.at = at
    }
}

/// snapshot を撮り直す**理由**。「古い木を掴んでよいか」は方針なので、呼び出し側は
/// bool ではなく理由を書き、`supportsCacheBypass` との掛け合わせは
/// `StepExecutor.bypassesCache(_:)` 1箇所に閉じる。
///
/// bool を渡し回すと、新しい呼び出しを足すときに**既定値を何気なく渡してドリフトする** ——
/// しかも失敗モードは沈黙(古い木で「動かなかった」と誤認する / 静止判定が古い位置で成立する)
/// なので、テストでは捕まらない。素取得でよい経路は今までどおり `driver.snapshot()` を呼ぶ。
enum SnapshotFreshness {
    /// 直前に**自分で画面を動かした**(スワイプ・ドラッグ・整定のポーリング)。
    /// 実測と機構は runScrollSearch のコメントおよび docs/verification.md
    case afterOwnMove
    /// 内蔵スクロール探索の後の解決。**探索がスワイプを撃っていなければ**素取得でよい
    /// (撃っていないなら木は古くならない)
    case afterSearch(swiped: Bool)
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

    /// **容器の推測に依存する補正**の既定(実行プロファイルの `containerInference`。既定 true)。
    /// ステップ側の指定(`FlowStep.containerInference`)があればそちらが勝ち、
    /// 環境変数 `FT_CONTAINER_INFERENCE=off` はどちらより上位の殺しスイッチ。
    /// **`execute` の入口でステップへ畳む**ので、下流(解決・探索・タップ)はステップだけ見ればよい
    let containerInference: Bool

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
                releasesScrollTouch: Bool = false,
                containerInference: Bool = true) {
        self.releasesScrollTouch = releasesScrollTouch
        self.containerInference = containerInference
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
    public func execute(_ original: FlowStep, cached: [FlowLocator] = []) async -> StepOutcome {
        // **入口で1回だけ実効値へ畳む**(下流は `step.containerInference` だけを見る)。
        // 優先順位: 環境変数の殺しスイッチ > ステップ指定 > 実行プロファイル既定
        var step = original
        step.containerInference = Self.containerInferenceEnabled
            && (original.containerInference ?? containerInference)
        let clock = ContinuousClock()
        let start = clock.now
        var phase = PhaseAccumulator()
        interruptNote = nil   // 「1ステップにつき1回だけ」の起点(dismissInterruption が見る)
        observedCheckedThisStep = nil
        resolvedElementThisStep = nil
        noteCodesThisStep = []
        do {
            if let action = step.action {
                let outcome = try await executeAction(action, step: step, cached: cached, phase: &phase)
                return StepOutcome(status: outcome.status, healedStep: outcome.healedStep,
                                   healedByCache: outcome.healedByCache,
                                   timing: StepTiming(durationMs: Self.ms(clock.now - start),
                                                      snapshotMs: phase.snapshotMs,
                                                      actionMs: phase.actionMs, waitMs: phase.waitMs),
                                   driverFallback: noteWithInterrupt(outcome.driverFallback),
                                   notes: collectedNotes(),
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
                                   notes: collectedNotes(),
                                   observedChecked: observedCheckedThisStep,
                                   resolvedElement: resolvedElementThisStep)
            }
            return StepOutcome(status: .skipped("step has neither an action nor an assertion"))
        } catch {
            return StepOutcome(status: .failed("execution error: \(error.localizedDescription)"),
                               timing: StepTiming(durationMs: Self.ms(clock.now - start),
                                                  snapshotMs: phase.snapshotMs,
                                                  actionMs: phase.actionMs, waitMs: phase.waitMs),
                               notes: collectedNotes())
        }
    }

    /// 撮り直す理由 → 実際にキャッシュを迂回するか。**ドライバの対応可否と掛け合わせる唯一の場所**
    /// (SnapshotFreshness の doc)。整定の sleep 長も同じ述語を見るので関数として公開する
    func bypassesCache(_ freshness: SnapshotFreshness) -> Bool {
        guard driver.supportsCacheBypass else { return false }
        switch freshness {
        case .afterOwnMove: return true
        case .afterSearch(let swiped): return swiped
        }
    }

    /// 理由付きの snapshot(呼び出し側が bool を組み立てない形)。
    /// **`snapshot(_:)` にしない** —— 呼び出し側の多くが `snapshot` という局所変数へ代入するので、
    /// 同名だと変数がメソッドを覆って `cannot call value of non-function type` になる
    func freshSnapshot(_ freshness: SnapshotFreshness) async throws -> SnapshotResponse {
        try await driver.snapshot(bypassingCache: bypassesCache(freshness))
    }

    /// このステップで立った注記。順序を rawValue 固定にするのは、記録が run 間で決定的に
    /// 比較できるようにするため(Set の反復順はプロセスごとに変わる)
    private func collectedNotes() -> [StepNote] {
        noteCodesThisStep.sorted { $0.rawValue < $1.rawValue }
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
    /// このステップで立った機械可読な注記(execute が StepOutcome.notes に載せる)。
    /// アクション/検証のどの return 経路から立てても拾えるようインスタンスで持つ
    /// (scrollSearchNote / observedCheckedThisStep と同じ受け渡し形)。
    /// StepExecutor+Assert.swift からも書くため internal
    var noteCodesThisStep: Set<StepNote> = []

    /// 注記の**表示文言と機械可読コードを同時に**足す。片方だけ足すと
    /// 「レポートには出ているのに集計に乗らない(逆も)」が起きるので、必ずこれを通す
    func note(_ code: StepNote, into parts: inout [String]) {
        noteCodesThisStep.insert(code)
        parts.append(code.text)
    }

    /// 「掴めた」と言い切れる状態か(StepOutcome.resolvedElement を載せてよいかの判定)
    static func isSuccess(_ status: StepResult.Status) -> Bool {
        switch status {
        case .passed, .passedViaFallback, .healed: return true
        case .failed, .skipped, .inconclusive: return false
        }
    }

    /// このステップで閉じた割り込み(execute が記録の注記に載せる)。
    /// **1ステップにつき1回だけ**発火させるための状態でもある(閉じても消えない相手に対して
    /// アサーションのポーリングごとにタップし続けるのを防ぐ)
    private var interruptNote: String?

    /// 直前の「画面を変えるはずの操作」の記録。**失敗の診断にだけ使い、判定は変えない**。
    ///
    /// タップは 200 を返しても黙って飲まれることがあり(座標が容器の外・容器が最初の1タッチを吸う・
    /// 到達しない)、そのとき落ちるのは2ステップ先の検証なので原因が遠い。ここに操作直前の木を
    /// 置いておき、**失敗した側が既に持っている木と比べる**ことで「あの操作で画面が1ピクセルも
    /// 変わっていない」を証跡として出せる。
    ///
    /// **追加のスナップショットは撮らない**のが要件(実行中に I/O を足すとタイミングが変わって
    /// 事象そのものが消える。docs/verification.md「Compose の探索直後タップ」の heisenbug)。
    /// 署名の生成も**失敗したときだけ**行う(正常系はフィールドを持ち回るだけ)。
    struct LastInteraction {
        /// 失敗文言に出す操作の呼び名(例: `tap "#row_30"`)
        let description: String
        /// 操作の**直前**に解決で使った木の要素列(比較の基準)
        let before: [ElementInfo]
        /// タップ点を取り得る「手前の別要素」(pointIsTakenByFrontElement と同じ規則)。
        /// **これ単独では注記にしない** —— 画面外要素の frame が容器原点へクランプされる
        /// フレームワーク(実測: XCUITest の UITableView は未実体化行のラベルまで同一座標で返す)が
        /// あり、正常なタップでも普通に非 nil になるため。無変化と同時に成立したときだけ添える
        let pointTakenBy: ElementInfo?
        /// **タップした要素そのもの**(タップ時点の frame を含む)。失敗した側の木で同じ要素を
        /// 探し直し、**あの後どれだけ動いたか**を出すのに使う。
        /// これが「座標が古くなった」と「本当に無反応だった」を分ける唯一の材料
        let target: ElementInfo
    }

    /// 直前の操作(tap / 長押し)の記録。**読むのは失敗文言の組み立てだけ**。
    /// StepExecutor+Assert.swift の各失敗経路から読むため internal
    var lastInteraction: LastInteraction?

    /// 容器の外に居る要素を可視域へ戻すのに必要な移動量(`hintDrag` の jump 規約 = 正なら指を上へ)。
    /// 収まっている/測れないときは nil。
    ///
    /// **全画面スワイプで戻してはいけない**(2026-08-05 実測): ずれは 100pt 程度なのに1回が
    /// 約1ページ動くので**行き過ぎて反対側へ出る** → 次の周で逆向き → 往復して収束しない。
    /// 8並列で採った失敗 13 件は**全部**が救済を撃ち切ったうえで(tap 4.0s → 約8.0s)、
    /// `#row_30` は容器 230..692 の**上** y=116〜174 に戻っていた。
    /// WebView のヒント跳躍と同じく**距離を測ってその分だけ**動かす
    static func recoveryJump(for element: ElementInfo, container: FTRect) -> Double? {
        // 着地目標は容器の 40% 位置(offscreenJump と同じ規約 = 端に寄せず中央寄りへ置く)
        let delta = element.frame.centerY - (container.y + container.height * 0.4)
        return abs(delta) > 1 ? delta : nil
    }

    /// **報告された frame の中心が容器の外に落ちるとき、実際に見えている部分の矩形**を返す。
    /// 中心が容器の中なら nil = 従来どおり ref でタップする(ブリッジが frame の中心へ解決)。
    ///
    /// フレームワークは縁をまたぐ行を「原点はクリップ前・サイズはクリップ後」の混成で返すため、
    /// **frame の中心が可視域の外に落ちる**。実測(2026-08-05・S0110 を8並列で 80 サンプル):
    /// **失敗 40 件の全部**でタップ座標が容器の外だった(完全に外 14 / またぎ 26。
    /// またぎの中心は 218〜228 で容器の上端は 230)。
    ///
    /// **整定でも追加スワイプでも直らない**ことは実測済み: 木は1ピクセルも動いていない
    /// (無変化の注記が 17/20)= **frame は安定していて、ただ間違っている**。
    /// 触る直前の静止確認(settleTapTarget)は fix 20/40 対 base 20/40 で**差ゼロ**だったので撤去した。
    /// 送る方向は 2/10 → 5/10 の自傷を実測済み(grabbedGhost の記録)。
    /// 残るのは**座標そのものを直す**ことだけで、見えている部分は実在するのでそこを撃てば当たる
    static func visibleTapRect(for element: ElementInfo, in elements: [ElementInfo],
                               inferring: Bool = containerInferenceEnabled) -> FTRect? {
        guard let container = clippingContainer(of: element, in: elements, inferring: inferring),
              let visible = ScrollGeometry.intersection(element.frame, container),
              // **細すぎる帯は撃たない**。容器の推測が外れていた場合、わずかな重なりを
              // 「見えている部分」と信じて叩くと**より悪い場所**へ当たる。実測の対象は
              // 10pt 以上見えていた(容器 230 に対し 240〜244)ので、この床で取りこぼさない
              visible.height >= Self.minimumVisibleTapExtent,
              visible.width >= Self.minimumVisibleTapExtent else { return nil }
        let center = (x: element.frame.centerX, y: element.frame.centerY)
        let inside = center.x >= container.x && center.x <= container.x + container.width
            && center.y >= container.y && center.y <= container.y + container.height
        return inside ? nil : visible
    }

    /// **指で触る操作か**(縁にまたがった要素を寄せてから撃つ対象)。`select` は掴むだけ、
    /// `type` は入力欄が動くと厄介なので含めない
    static func interactsByTouch(_ action: String) -> Bool {
        action == "tap" || action == "press" || action == "doubleTap"
    }

    /// 「見えている部分」を撃つと言えるだけの最小の幅・高さ(pt)。
    /// 容器の推測が外れたときに、わずかな重なりへ突っ込まないための床
    static let minimumVisibleTapExtent: Double = 8

    /// 飲まれたタップの証跡を採る(LastInteraction 参照)。**追加のスナップショットは撮らない** ——
    /// 解決に使った木をそのまま基準にする。前面要素の判定も同じ木の上の計算だけ
    private func recordInteraction(step: FlowStep, element: ElementInfo, in snapshot: SnapshotResponse) {
        lastInteraction = LastInteraction(
            description: "tap \(step.locatorSummary)",
            before: snapshot.elements,
            // ブリッジは ref を frame の中心へ解決する(iOS/Android とも)。同じ点で判定する
            pointTakenBy: Self.frontElementTakingPoint(
                x: element.frame.centerX, y: element.frame.centerY,
                of: element, in: snapshot.elements),
            target: element)
    }

    /// 木の内容署名(**位置だけでなくラベル・値も含む**)。
    ///
    /// `settledSignature` の署名とは別物なので共用しないこと —— あちらは「動いているか」を見るので
    /// frame だけ(iOS の再利用セルはラベルが振れるため入れると収束しない)。こちらは
    /// 「何か変わったか」を見るので、**レイアウトが同じでテキストだけ変わる更新**
    /// (`selected=-` → `selected=row_30` がまさにこれ)を取りこぼしてはいけない。
    /// ラベルの振れは「変わった」側に倒れる = 誤って「無変化」と言うことはない(片側の誤りしか出ない)
    static func contentSignature(_ elements: [ElementInfo]) -> String {
        var text = ""
        text.reserveCapacity(elements.count * 48)
        for element in elements {
            let frame = element.frame
            text += "\(element.type)|\(element.identifier ?? "")|\(element.label ?? "")"
            text += "|\(element.value ?? "")|\(element.enabled)|\(element.checked ?? false)"
            text += "|\(Int(frame.x)),\(Int(frame.y)),\(Int(frame.width)),\(Int(frame.height));"
        }
        return text
    }

    /// 直前のタップについて、失敗した側の木から**分かることだけ**を失敗文言へ添える。
    /// **判定には触れない**(正しく変化しない操作もあるので、理由付けにだけ使う)。
    /// 呼び手は**既に持っている木の要素列**を渡すこと(このために追加取得しない)。
    ///
    /// 出るのは排他な2つ。**この2つを分けることが目的**で、事後の幾何だけでは区別できない
    /// (2026-08-05 に実際に取り違えた: 失敗時に対象が容器の縁へずれていたのを「掴んだ時点で
    /// 壊れていた」と読み、探索側を直したが**一度も発火しなかった**):
    ///   1. **木が1ピクセルも変わっていない** → タップが丸ごと飲まれた(真の空振り)
    ///   2. **対象があの後動いた** → タップは**動く前の座標**を撃った可能性(古い座標)
    ///
    /// StepExecutor+Assert.swift の失敗経路から呼ぶため internal
    func tapDiagnosisHint(_ elements: [ElementInfo]?) -> String {
        guard let last = lastInteraction, let elements, !elements.isEmpty else { return "" }
        if Self.contentSignature(elements) == Self.contentSignature(last.before) {
            var text = " (the preceding \(last.description) did not change the screen at all"
                + "; the interaction may have been swallowed"
            if let taken = last.pointTakenBy {
                let label = taken.identifier.map { "#\($0)" } ?? taken.label.map { "\"\($0)\"" }
                    ?? taken.type
                text += " — its point was inside \(label), which is in front of the target"
            }
            return text + ")"
        }
        guard let now = Self.relocate(last.target, in: elements) else { return "" }
        let dx = now.frame.x - last.target.frame.x
        let dy = now.frame.y - last.target.frame.y
        guard (dx * dx + dy * dy).squareRoot() >= Self.movedTargetThreshold else { return "" }
        return " (the target has moved (\(Int(dx)),\(Int(dy))) since the preceding"
            + " \(last.description) — the tap used the coordinates from before that move,"
            + " so it may have landed on whatever was there at the time)"
    }

    /// 「動いた」と言い切る下限(pt)。整定のわずかな揺れやサブピクセルで注記を出さないための床。
    /// 実測の取りこぼしは 98pt 級(docs/verification.md の計装記録)なので、この値で十分拾える
    static let movedTargetThreshold: Double = 8

    /// タップした要素を**別の木の中で**探し直す。id があれば id、無ければ型+ラベル。
    /// 見つからなければ nil = 黙る(消えた要素について「動いた」とは言えない)
    static func relocate(_ target: ElementInfo, in elements: [ElementInfo]) -> ElementInfo? {
        if let id = target.identifier, !id.isEmpty {
            return elements.first { $0.identifier == id }
        }
        guard let label = target.label, !label.isEmpty else { return nil }
        return elements.first { $0.type == target.type && $0.label == label }
    }

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
        var found: Bool
        /// 解決に使ったフォールバック節(プライマリで解決したら nil)
        var fallback: FlowLocator?
        /// 1回でも XCUITest 経由で swipe したか(記録の注記に載せる)
        let viaXCUITest: Bool
        /// スクロールヒントで置き換えた長距離ドラッグの回数(記録の注記に載せる)
        let hintJumps: Int
        /// 探索終端の静止待ちが**収束せずに打ち切られた**。黙って返すと「動いている画面で
        /// 掴んだ座標」を後段がタップすることになり、失敗は沈黙(誤った成功)として現れる
        var settleCapped: Bool = false
        /// 実際に撃ったスワイプ数(見つからなかったときの理由文に使う)
        var swipes: Int = 0
        /// **もう動かないので上限より手前で打ち切った**。上限まで振り続けても結果は変わらないため
        var stoppedUnmoving: Bool = false
        /// 端まで来ても見つからず、**逆向きの細刻みで拾い直した**回数(0 か 1。注記に載せる)
        var reverseSweeps: Int = 0
        /// 拾い直しに使った容器を**そのまま書けるセレクタ**にしたもの(nil = 名指しできない)。
        /// 注記で `scrollFrame:` を勧めるときに実物の名前を出すために持つ
        var suggestedScrollFrame: String?
    }

    /// 探索の注記を組み立てつつ、**機械可読コードを今のステップへ記録する**。
    /// 探索の打ち切りは文言が別(「after the search」)だが `settleCapped` として同じ棚で数える ——
    /// 集計側の関心は「動いている画面のまま進んだか」で、どの経路で起きたかではない
    func recordedScrollSearchNote(_ result: ScrollSearchResult,
                                  scrollFrameNote: String? = nil) -> String? {
        if result.settleCapped { noteCodesThisStep.insert(.settleCapped) }
        return Self.scrollSearchNote(result, scrollFrameNote: scrollFrameNote)
    }

    /// スクロール探索の注記(XCUITest フォールバック / ヒント跳躍)。無ければ nil
    static func scrollSearchNote(_ result: ScrollSearchResult,
                                 scrollFrameNote: String? = nil) -> String? {
        var parts: [String] = []
        if result.viaXCUITest { parts.append("fell back to XCUITest") }
        if result.hintJumps > 0 { parts.append("\(result.hintJumps) long drag(s) from scroll hints") }
        if result.settleCapped { parts.append("the screen did not settle after the search (poll limit)") }
        // **黙って拾い直さない**: 順方向で飛び越したことは利用者の書き方(scrollFrame 未指定)に
        // 由来するので、逆走査で救えたことを見せて `scrollFrame` を書く判断材料にする
        if result.reverseSweeps > 0 {
            // **具体名まで出す**: 総称の「scrollFrame を書け」だけだと、読み手は容器の名前を
            // 探すためにスナップショットを撮り直すことになる(困った瞬間に答えを渡す)
            let how = result.suggestedScrollFrame.map { "specify scrollFrame: \($0)" }
                ?? "specify scrollFrame:"
            parts.append("found by sweeping back after overshooting it"
                + " (\(how) to step within the container instead)")
        }
        if let scrollFrameNote { parts.append(scrollFrameNote) }
        return parts.isEmpty ? nil : parts.joined(separator: " / ")
    }

    /// `select` が掴めなかったときの skip 理由。**失敗ではない**(DSL は空要素を返す)ので、
    /// 読み手が「見つからないのに緑」と誤読しないよう理由文で契約を名乗る
    static let selectNotFoundReason = "element not found; select returned an empty element"

    static func scrollNotFoundMessage(_ step: FlowStep,
                                      _ result: ScrollSearchResult? = nil) -> String {
        let limit = max(0, step.maxSwipes ?? FlowStep.defaultMaxSwipes)
        // 打ち切ったときは**実際の回数**を出す(上限を名乗ると「8回も振ったのに」と読めてしまう)
        let swipes = result?.stoppedUnmoving == true ? (result?.swipes ?? limit) : limit
        let stopped = result?.stoppedUnmoving == true
            ? " (stopped early: the content no longer moved)" : ""
        return "element not found after \(swipes) scroll(s)\(stopped): \(step.locatorSummary)"
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

    /// `scrollToEdge` が端と認めるまでに必要な「署名が不変だった周回数」。
    ///
    /// 既定は **2**。Android では次のスワイプがフリングの停止だけに消費されて1回空振りすることがあり、
    /// 1回で打ち切ると途中で止まる(2026-07-27 実測: scrollToTop が row_22 付近で停止)。
    ///
    /// **ヒントを供給する画面(WebView)だけ 1 に下げる**。`offscreen` はその方向にまだ内容が
    /// あるかの**肯定的な証拠**で、`remainingJump == nil` = 「もう先が無い」。これがあるなら
    /// 署名の不変化を2回重ねる必要はない。
    /// 効くのは iOS xcuitest の WebView で、**端に着いた後に捨てのスワイプを2回撃っていた**
    /// (1スワイプ約2.5秒 = 実測 scrollToTop 中央値 12.1s の主成分。docs/performance-tuning.md §8)。
    /// 供給の無い画面(ネイティブ・旧ブリッジ・hybrid の WebViewDelegatingDriver)は
    /// `offscreen` が nil なので従来どおり 2 のまま = 挙動は変わらない
    static func unchangedRoundsForEdge(snapshot: SnapshotResponse,
                                       remainingJump: Double?) -> Int {
        guard remainingJump == nil, let hints = snapshot.offscreen, !hints.isEmpty else { return 2 }
        return 1
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
    /// 1ジェスチャで賄えない距離は呼び手のループ(スナップショット→再計算)が刻む。
    ///
    /// **容器は画面と交差させる**(`ScrollGeometry.intersection` と同じ規則)。
    /// 交差を取らないと、画面からはみ出した容器で**画面外の座標を撃つ**ことになる
    /// (WebView が画面より高いときに起き得た。2026-08-03 に scrollFrame 側と規則を揃えた)
    static func dragGesture(jump: Double, container rawContainer: FTRect,
                            viewport: FTRect? = nil)
        -> (fromX: Double, fromY: Double, toX: Double, toY: Double)? {
        let container = viewport.flatMap { ScrollGeometry.intersection(rawContainer, $0) }
            ?? rawContainer
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
    private func hintDrag(jump: Double, container: FTRect, viewport: FTRect,
                          phase: inout PhaseAccumulator) async -> Bool {
        guard let g = Self.dragGesture(jump: jump, container: container,
                                       viewport: viewport) else { return false }
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

    /// **フリングを出さないドラッグ**。逆走査専用。hintDrag(0.3〜0.7s)は Android では
    /// まだ速く、189px のドラッグが慣性で 700px 走って**逆向きの飛び越し**になった
    /// (2026-08-06 に Emulator で観測)。指を離す直前の速度が閾値を下回るよう、
    /// **距離ぶんの時間を必ず取る**(reverseSweepDragSpeed px/s)
    private func slowDrag(jump: Double, container: FTRect,
                          phase: inout PhaseAccumulator) async -> Bool {
        guard let g = Self.dragGesture(jump: jump, container: container,
                                       viewport: container) else { return false }
        let clock = ContinuousClock()
        let start = clock.now
        let distance = abs(g.toY - g.fromY)
        let duration = min(max(distance / Self.reverseSweepDragSpeed, 0.6), 3.0)
        defer { phase.actionMs += Self.ms(clock.now - start) }
        do {
            try await driver.drag(fromX: g.fromX, fromY: g.fromY, toX: g.toX, toY: g.toY,
                                  pressSeconds: 0.15, durationSeconds: duration)
            return true
        } catch {
            return false
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
    /// `recoverOnMiss` = 見つからずに端まで来たとき、**逆向きの細刻みで1往復だけ拾い直す**か。
    /// `notExist(scroll:)` の前奏だけは false(見つからないのが期待値なので、往復は丸損)
    func runScrollSearch(step: FlowStep, recoverOnMiss: Bool = true,
                         phase: inout PhaseAccumulator) async throws -> ScrollSearchResult {
        let clock = ContinuousClock()
        let direction = FTSwipeDirection(rawValue: step.direction ?? "") ?? .up
        // 負値だと 0...(-1) が ClosedRange 生成で trap(クラッシュ)するため 0 で下限クランプ
        let maxSwipes = max(0, step.maxSwipes ?? FlowStep.defaultMaxSwipes)
        var viaXCUITest = false
        var hintJumps = 0
        var settleCapped = false
        // 自己補正の材料(直前の周回のツリー)。**較正値は持たず毎周測り直す**
        var previousSnapshot: SnapshotResponse?
        // 撃ったスワイプ数と、**振っても木が1文字も変わらなかった**連続回数。
        // 端に着いた後も上限まで振り続けるのは丸損なので、2周続けて変化が無ければ打ち切る
        // (1周で切らないのは、遅れて描画される行を「動かなかった」と誤断しないため)
        var swipes = 0
        var unmovedRounds = 0
        // スクロールした容器(中身が入れ替わった領域)。逆走査の刻みの基準
        var scrolledContainer: FTRect?
        for attempt in 0...maxSwipes {
            // **1周目だけは静止を待ってから撮る**。直前の操作がプログラム的な
            // アニメーションスクロール(「先頭へ」等)だと、ブリッジの整定はすり抜けることがあり
            // (アニメが始まる前に「変化なし」と判定される)、動く前のツリーで解決すると
            // **古い座標をタップして別の要素が選ばれる**(2026-08-02 に CMP で実測。
            // ステップは成功のまま = 黙って誤った結果)。2周目以降はスワイプ後の
            // settleAfterScroll / settledSignature が既に待っているので素取得でよい
            var snapshot: SnapshotResponse
            if attempt == 0 {
                snapshot = try await settledSignature(phase: &phase).snapshot
            } else {
                let start = clock.now
                // **スワイプ直後は必ずキャッシュを捨てて撮る**(Android のみ実費。iOS は素通し)。
                // ブリッジの整定(a11y の静穏待ち)を通っても、**Compose の a11y ツリーは
                // 数十 ms 遅れて公開される** —— 応答時点の素の snapshot が**スワイプ前の位置**を
                // 返す瞬間があり(2026-08-03 実測: 4回中2回。素=row_01 / refresh=1=row_06)、
                // 古いツリーで探索を続けると「動かなかった」と誤認する・見つけた要素が直後の
                // 解決で消える(`cannot resolve the locator` として現れる)。
                // 検証系の期限切れ直前の1回とは別で、ここは**毎周払う**必要がある
                snapshot = try await freshSnapshot(.afterOwnMove)
                phase.snapshotMs += Self.ms(clock.now - start)
            }
            try await dismissInterruption(in: &snapshot, phase: &phase)
            if let previousSnapshot {
                scrolledContainer = Self.changedContentContainer(before: previousSnapshot,
                                                                 after: snapshot)
                    ?? Self.movedContentContainer(before: previousSnapshot, after: snapshot,
                                                  vertical: direction == .up || direction == .down)
                    ?? scrolledContainer
            }
            // **1回の移動量が容器を超えると要素を飛び越す**(スクロール探索は行き過ぎた要素を
            // 拾い直さない)。実測して超えていたら次の刻みを詰める。
            //
            // **基準は画面ではなく容器**(2026-08-05 修正)。旧実装は画面の高さで割っており、
            // 容器は定義上それより小さいので**ほぼ発火しなかった** —— §3.18(f) の実測を当てると
            // SwiftUI は 1 スワイプ 681pt に対し閾値 0.8×874=699pt で素通りする一方、
            // リストの可視高は 492pt = **1.38 倍の超過**(いちばん取りこぼす SUT で無効だった)。
            //
            // **効くのは `scrollFrame` を書いた経路だけ**。刻みを縮める唯一の口は `spanScale` →
            // `scrollPath` で、あちらは領域未指定なら nil を返してエンジン既定に任せるため。
            // 既定経路の飛び越しをホスト側で塞ぐには座標スワイプを常用するしかなく、それは
            // 2度撤回済み(docs/performance-tuning.md §3.19)。**ここを既定経路へ広げないこと**
            let vertical = direction == .up || direction == .down
            if let previousSnapshot,
               let travel = Self.measuredTravel(before: previousSnapshot, after: snapshot,
                                                vertical: vertical) {
                let container = scrollContainer(step: step, in: snapshot, vertical: vertical)
                    .flatMap { ScrollGeometry.intersection($0, snapshot.screen) } ?? snapshot.screen
                let extent = vertical ? container.height : container.width
                if travel > extent * Self.travelCeilingRatio {
                    spanScale = max(Self.minSpanScale, spanScale * Self.spanShrinkFactor)
                }
            }
            // スクロール探索でも type+index フォールバックは偽陽性のもとなので使わない
            if let (element, fallback) = Self.resolve(step: step, in: snapshot, strictForAssert: true) {
                // **見つけただけでは足りない**: 画面の縁で見切れている要素は、フレームワークに
                // よっては frame がクランプされて**タップが外れる**(Compose iOS の既知の上流制約)。
                // まだ送れるなら、完全に見えるまでもう1回スワイプする。
                // 1回の移動量が小さいほど「見えた瞬間 = 見切れ位置」で止まるので、
                // 領域指定(scrollFrame)や刻みの細かい設定ほどここに掛かる
                // (2026-08-02 実測: CMP で #row_40 が y=829/高さ56 = 下端 885 > 画面 874 で見つかり、
                // タップが別の行に取られた。従来の全画面スワイプでは y=720 で見つかっていた)
                // 領域が指定されていないときは**報告された木から clip 元の祖先**を採る。
                // これが無いと viewport が画面全体になり、容器の外に並ぶ ghost 要素を
                // 「見えている」と判定して探索がそこで止まる(2026-08-03 実測: #row_30 が
                // label=nil・y=783 = 容器 230..692 の外で見つかり、タップが飲まれた)
                let viewport = (scrollContainer(step: step, in: snapshot,
                                                vertical: direction == .up || direction == .down)
                                ?? Self.clippingContainer(of: element, in: snapshot.elements,
                                                          inferring: step.containerInference ?? true))
                    .flatMap { ScrollGeometry.intersection($0, snapshot.screen) } ?? snapshot.screen
                if attempt < maxSwipes,
                   Self.isClippedByViewport(element, screen: viewport) {
                    // **行き過ぎた側なら逆へ送る**(recoveryDirection 参照)。探索方向のまま
                    // 送り続けると、既に通り過ぎた要素は遠ざかるだけで永久に可視域へ戻らない
                    var recovery = step
                    recovery.direction = Self.recoveryDirection(for: element, container: viewport,
                                                                searching: direction).rawValue
                    let finger = FTSwipeDirection(rawValue: recovery.direction ?? "") ?? direction
                    if try await swipeWithFallback(finger, intent: .search,
                                                   path: scrollPath(step: recovery, intent: .search,
                                                                    in: snapshot),
                                                   phase: &phase) { viaXCUITest = true }
                    continue
                }
                // **スワイプしたなら静止を待つ**(空打ち→静止待ちの順。settleAfterFind 参照)。
                // スワイプしていない周回(attempt == 0)は静止しているので追加コストを払わない
                if attempt > 0 {
                    settleCapped = try await settleAfterFind(step: step, element: element,
                                                             snapshot: snapshot, phase: &phase)
                }
                return ScrollSearchResult(found: true, fallback: fallback, viaXCUITest: viaXCUITest,
                                          hintJumps: hintJumps, settleCapped: settleCapped)
            }
            if attempt < maxSwipes {
                if let earlier = previousSnapshot,
                   Self.contentSignature(earlier.elements)
                       == Self.contentSignature(snapshot.elements) {
                    unmovedRounds += 1
                    if unmovedRounds >= Self.unmovedRoundsToStopSearch {
                        // **打ち切る前に整定まで待って確かめる**(2026-08-06 に Flutter/Android で
                        // 誤発火): a11y ツリーは遅れて公開されるので、**動いている最中でも
                        // 2周続けて同じ木**が返ることがある。`settledSignature` は
                        // キャッシュを捨てて連続2回一致まで待つので、遅れと停止を区別できる。
                        // 費用は打ち切る局面の1回だけ(正常系には掛からない)
                        let confirmed = try await settledSignature(phase: &phase)
                        if Self.contentSignature(confirmed.snapshot.elements)
                            != Self.contentSignature(snapshot.elements) {
                            snapshot = confirmed.snapshot
                            previousSnapshot = snapshot
                            unmovedRounds = 0
                            continue
                        }
                        var result = ScrollSearchResult(found: false, fallback: nil,
                                                        viaXCUITest: viaXCUITest,
                                                        hintJumps: hintJumps,
                                                        swipes: swipes, stoppedUnmoving: true)
                        guard recoverOnMiss, step.containerInference ?? true,
                              let container = (scrolledContainer
                                               ?? Self.overflowingContainer(in: snapshot))
                                  .flatMap({ ScrollGeometry.intersection($0, snapshot.screen) })
                        else { return result }
                        // **端に着いたのに見つからない = 途中で飛び越した可能性**。
                        // 既定経路(scrollFrame 未指定)は刻みがエンジン任せで縮められないので、
                        // ここでだけ推測した容器で細刻みの逆走査を掛ける
                        // (通常の送りには触らない = 2度撤回した「暗黙の座標化」にならない)
                        if let recovered = try await reverseSweep(step: step, container: container,
                                                                  searching: direction,
                                                                  phase: &phase) {
                            result.found = true
                            result.fallback = recovered
                            result.reverseSweeps += 1
                            // 推測した容器に**申告済みの容器**が重なっていればその名前を出す。
                            // 重ならなければ nil のまま = 注記は総称に留める(推測した矩形を
                            // 座標で名乗っても `scrollFrame:` には書けない)
                            result.suggestedScrollFrame = ScrollFrameCandidates.selector(
                                matching: container, in: snapshot)
                        }
                        return result
                    }
                } else {
                    unmovedRounds = 0
                }
                // ヒント跳躍: 距離が分かるときは固定幅スワイプでなく長距離ドラッグで寄せる。
                // ドラッグ後は静止を待たず次周回のスナップショット(25ms)で測り直す(自己補正)
                if let jump = Self.offscreenJump(step: step, snapshot: snapshot, finger: direction),
                   let container = Self.webViewContainer(in: snapshot),
                   await hintDrag(jump: jump, container: container,
                                  viewport: snapshot.screen, phase: &phase) {
                    hintJumps += 1
                    swipes += 1
                    previousSnapshot = snapshot
                    continue
                }
                if try await swipeWithFallback(direction, intent: .search,
                                               path: scrollPath(step: step, intent: .search,
                                                                in: snapshot),
                                               phase: &phase) { viaXCUITest = true }
                swipes += 1
                previousSnapshot = snapshot
            }
        }
        return ScrollSearchResult(found: false, fallback: nil, viaXCUITest: viaXCUITest,
                                  hintJumps: hintJumps, swipes: swipes)
    }

    private func executeAction(_ action: String, step: FlowStep,
                               cached: [FlowLocator] = [],
                               phase: inout PhaseAccumulator) async throws -> StepOutcome {
        let clock = ContinuousClock()
        cachedScreenshot = nil   // 画面を変える操作 → occlusion-guard スクショ再利用を無効化
        // 直前の操作の記録は**次の操作が画面を変えるまで**有効(検証は画面を変えないので消さない)。
        // `select` は掴むだけでデバイス操作が無いので例外 —— `tap → select → textIs` という
        // 一番ありふれた形で、落ちるのは textIs 側だから、ここで消すと肝心なときに証跡が無くなる
        if action != "select" { lastInteraction = nil }
        pendingScrollFrameNote = nil
        reportedScrollFrameNote = false
        spanScale = 1
        // ロケータ不要のアクション
        if action == "swipe" {
            let direction = FTSwipeDirection(rawValue: step.direction ?? "") ?? .up
            let viaXCUITest = try await swipeWithFallback(direction, phase: &phase)
            // 慣性が止まるまで待つ。ランナー側は /swipe を整定対象から外している(そこで待っても
            // budget 内に収束しないため)ので、直後に tap する書き方をここで支える
            let settled = try await settledSignature(phase: &phase).settled
            var notes: [String] = []
            if viaXCUITest { notes.append("fell back to XCUITest") }
            if !settled { note(.settleCapped, into: &notes) }
            return StepOutcome(status: .passed,
                               driverFallback: notes.isEmpty ? nil : notes.joined(separator: " / "))
        }

        // スクロールだけ行う(Shirates の scrollDown 等)。maxSwipes を繰り返し回数として使う
        if action == "scroll" {
            let direction = FTSwipeDirection(rawValue: step.direction ?? "") ?? .up
            let times = max(1, step.maxSwipes ?? 1)
            var viaXCUITest = false
            var unsettled = false
            var latest = step.scrollFrame == nil ? nil : try await snapshotForScrollFrame(phase: &phase)
            for index in 0..<times {
                let path = latest.flatMap { scrollPath(step: step, intent: .search, in: $0) }
                if try await swipeWithFallback(direction, intent: .search, path: path,
                                               phase: &phase) { viaXCUITest = true }
                // 続けて投げるとフリングの停止だけに消費されて空振りする(Android 実測)。
                // 「repeat 回ぶん送る」を守るため、次のスワイプ前に静止を待つ。
                // 最後の1回の後も待つ: ランナーは /swipe を整定対象から外しているので、
                // 直後に tap する書き方をここで支える(index 条件を外した理由)
                let settled = try await settledSignature(phase: &phase)
                if !settled.settled { unsettled = true }
                if step.scrollFrame != nil { latest = settled.snapshot }
            }
            var notes: [String] = []
            if viaXCUITest { notes.append("fell back to XCUITest") }
            if unsettled { note(.settleCapped, into: &notes) }
            if let note = pendingScrollFrameNote { notes.append(note) }
            return StepOutcome(status: .passed,
                               driverFallback: notes.isEmpty ? nil : notes.joined(separator: " / "))
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
            var sawUnsettled = false
            let limit = max(1, step.maxSwipes ?? FlowStep.defaultMaxEdgeSwipes)
            var hintJumps = 0
            for _ in 0..<limit {
                let settled = try await settledSignature(phase: &phase)
                if !settled.settled { sawUnsettled = true }
                unchanged = settled.signature == previous ? unchanged + 1 : 0
                // ヒント跳躍(WebView): 端までの残り距離が分かるときは長距離ドラッグで寄せる
                let jump = Self.offscreenEdgeJump(snapshot: settled.snapshot, finger: direction)
                if unchanged >= Self.unchangedRoundsForEdge(snapshot: settled.snapshot,
                                                            remainingJump: jump) {
                    reachedEdge = true
                    break
                }
                previous = settled.signature
                if let jump, let container = Self.webViewContainer(in: settled.snapshot),
                   await hintDrag(jump: jump, container: container,
                                  viewport: settled.snapshot.screen, phase: &phase) {
                    hintJumps += 1
                    continue
                }
                if try await swipeWithFallback(direction, intent: .edge,
                                               path: scrollPath(step: step, intent: .edge,
                                                                in: settled.snapshot),
                                               phase: &phase) { viaXCUITest = true }
            }
            // 上限で抜けたら**端に着いたとは限らない**。黙って成功にすると
            // 「scrollToBottom したのに末尾が無い」の原因が読めなくなる
            var notes: [String] = []
            if !reachedEdge { notes.append("stopped at the limit of \(limit) (may not have reached the edge yet)") }
            if let note = pendingScrollFrameNote { notes.append(note) }
            if viaXCUITest { notes.append("fell back to XCUITest") }
            if hintJumps > 0 { notes.append("\(hintJumps) long drag(s) from scroll hints") }
            if sawUnsettled { note(.settleCapped, into: &notes) }
            return StepOutcome(status: .passed,
                               driverFallback: notes.isEmpty ? nil : notes.joined(separator: " / "))
        }

        // フリック(Shirates flickXxx 8種)。scrollableElement は持たず scrollFrame のセレクタ式
        // (nil = 画面全体)で表す。**repeat 回とも同じ座標を撃つ**(Shirates は容器を毎回測り直さない。
        // TestDriveSwipeExtension.kt 参照)。整定待ちは「swipe」アクションと同じ形で末尾に1回だけ
        // (ランナー側は /swipe を整定対象から外しているため)
        if action == "flick" {
            guard let kind = FlickKind(rawValue: step.direction ?? "") else {
                return StepOutcome(status: .failed("unknown flick kind: \(step.direction ?? "")"))
            }
            let times = max(1, step.maxSwipes ?? 1)
            let durationSeconds = step.duration ?? FlowStep.defaultFlickDurationSeconds
            let intervalSeconds = step.intervalSeconds ?? FlowStep.defaultFlickIntervalSeconds

            var path: FTSwipePath?
            if Self.coordinateScrollEnabled {
                let snapshot = try await snapshotForScrollFrame(phase: &phase)
                let container: FTRect?
                if let locator = step.scrollFrame {
                    container = Self.match(locator, in: snapshot)?.frame
                } else {
                    container = snapshot.screen
                }
                if let container {
                    path = ScrollGeometry.flickPath(
                        container: container, viewport: snapshot.screen, kind: kind,
                        startMarginRatio: step.startMarginRatio
                            ?? FTScrollDefaults.startMarginRatio(intent: .gesture, vertical: kind.isVertical))
                }
            }

            var viaXCUITest = false
            if let path {
                for _ in 0..<times {
                    if times > 1 {
                        let waitStart = clock.now
                        try await Task.sleep(for: .milliseconds(Int(intervalSeconds * 1000)))
                        phase.waitMs += Self.ms(clock.now - waitStart)
                    }
                    // in-app エンジンは drag を一切実装しない(501)ため、hybrid では
                    // typeDriver(XCUITest)へ回す(swipePointToPoint と同じ理由)
                    if try await dragWithFallback(path: path, durationSeconds: durationSeconds,
                                                  phase: &phase) {
                        viaXCUITest = true
                    }
                }
            } else {
                // 殺しスイッチ有効時、または領域を削りすぎて座標を作れないとき: 向き基準の汎用スワイプへ
                // 落ちる(scroll アクションが scrollPath nil のとき辿る経路と同じ考え方)
                if try await swipeWithFallback(kind.fingerDirection, phase: &phase) { viaXCUITest = true }
            }
            let settled = try await settledSignature(phase: &phase).settled
            var notes: [String] = []
            if viaXCUITest { notes.append("fell back to XCUITest") }
            if !settled { note(.settleCapped, into: &notes) }
            return StepOutcome(status: .passed,
                               driverFallback: notes.isEmpty ? nil : notes.joined(separator: " / "))
        }

        // ピンチ・ダブルタップ・相対ドラッグ(斜め可)の**対象未指定版** = 画面全体を対象にする。
        // ロケータ付きは下の switch(要素解決・ヒール・スクロール探索にそのまま乗せるため)で、
        // 対象の決め方以外は performGesture に集約してある
        if Self.gestureActions.contains(action), step.locator == nil,
           step.fallbacks?.isEmpty ?? true {
            let snapshot = try await snapshotForScrollFrame(phase: &phase)
            return try await performGesture(action, step: step, target: snapshot.screen,
                                            identifier: nil, viewport: snapshot.screen,
                                            phase: &phase)
        }

        // 要素が見つかるまでスクロール(見つかったら成功。操作はしない)
        if action == "scrollTo" {
            let result = try await runScrollSearch(step: step, phase: &phase)
            let note = recordedScrollSearchNote(result, scrollFrameNote: pendingScrollFrameNote)
            guard result.found else {
                return StepOutcome(status: .failed(Self.scrollNotFoundMessage(step, result)))
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
        // 探索がスワイプを撃ったか。直後の解決 snapshot も**キャッシュを捨てて**撮るために立てる
        // (探索が最後に見た木は新しいのに、ここで古い木を掴むと**見つけたはずの要素が消えて**
        // `cannot resolve the locator` になる。2026-08-03 に CMP/Android で実測した失敗そのもの)
        var searchSwiped = false
        if step.direction != nil, step.locator != nil {
            let result = try await runScrollSearch(step: step, phase: &phase)
            scrollSearchNote = recordedScrollSearchNote(result, scrollFrameNote: pendingScrollFrameNote)
            guard result.found else {
                // select はスクロール探索で見つからなくても空要素を返す契約(下の解決経路と同じ)
                if action == "select" {
                    return StepOutcome(status: .skipped(Self.selectNotFoundReason))
                }
                return StepOutcome(status: .failed(Self.scrollNotFoundMessage(step, result)))
            }
            searchSwiped = true
        }

        // ロケータ解決の再試行(ファイル冒頭のセマンティクス参照: 最大3回、計700ms)
        var start = clock.now
        var snapshot = try await freshSnapshot(.afterSearch(swiped: searchSwiped))
        phase.snapshotMs += Self.ms(clock.now - start)
        // 宣言された割り込み(アプリ内メッセージ等)が出ていれば先に閉じる。**解決を試みる前**に
        // 行う: 覆われているだけで要素自体は解決できてしまい、タップが吸われる形があるため
        // (層3 の coveringHint と同じ事象。あちらは診断、こちらは宣言があるときの自動処理)
        try await dismissInterruption(in: &snapshot, phase: &phase)
        var resolved = Self.resolve(step: step, in: snapshot)
        // **探索の直後は容器の外に並ぶ ghost 行を掴むことがある**(Compose iOS は容器の外にも
        // 子を報告する。docs/verification.md「Compose の探索直後タップ」)。掴んだままタップすると
        // 容器の外を撃って**黙って飲まれる**(値が変わらないので、後段の検証だけが落ちて原因が遠い)。
        // 探索ループの中では同じ判定で「もう1回送る」をしているが、**ループを抜けた後の再解決には
        // 効いていなかった**のが残存フレークの正体(2026-08-04)。
        // 判定は `isOutsideContainer`(容器と**交差しない** = 完全に外)。
        //
        // **またぎ(縁をまたぐ要素)まで対象に広げてはいけない**(2026-08-05 に試して撤回)。
        // 「掴み直し+送り直し」の対象を `isClippedByViewport`(= 完全に外もまたぎも拾う)へ
        // 統一したところ、S0110 の失敗が **2/10 → 5/10 に悪化**した。失敗はいずれも救済が発火し、
        // tap が 4.0s → 7.2〜8.2s に伸びたうえで**「対象があの後 9〜14pt 動いた」**で落ちている
        // = 縁で救済スワイプを撃つと、わずかに動いた先の座標でタップすることになり自傷する。
        // **またぎは探索ループ側の見切れ判定に任せる**(あちらは掴む前に送るので座標が古くならない)
        // **このステップが探索したかは条件にしない**(2026-08-06 に外した): ghost は
        // 「直前の探索」ではなく**アプリがスクロールしていること**の帰結で、木にはその後も
        // 残り続ける。`scrollTo` と `tap` を別ステップで書く(利用者の自然な書き方)と
        // searchSwiped が false になり、**防御がまるごと素通り**していた —— 実測では
        // `tap` が容器の外を撃って画面が何も変わらず、後段の検証だけが落ちていた
        func grabbedGhost(_ candidate: (ElementInfo, FlowLocator?)?) -> Bool {
            guard let element = candidate?.0, step.containerInference ?? true
            else { return false }
            return Self.isOutsideContainer(element, in: snapshot.elements)
        }
        var ghostRetries = 0
        var ghostSwipes = 0
        if resolved == nil || grabbedGhost(resolved) {
            if let timeout = step.timeout {
                // timeout == 0: リトライなし(初回スナップショットのみ。ifCanSelect/select の空振り短縮用)
                if timeout > 0 {
                    let retryDeadline = clock.now.advanced(by: .seconds(timeout))
                    var backoff = PollBackoff()
                    while resolved == nil || grabbedGhost(resolved), clock.now < retryDeadline {
                        start = clock.now
                        try await Task.sleep(for: backoff.nextDelay())
                        phase.waitMs += Self.ms(clock.now - start)
                        start = clock.now
                        // 探索後の再試行もキャッシュを捨てる。古い木は撮り直しても同じものが
                        // 返るので、素取得だと**再試行の予算をまるごと空振りに使う**
                        snapshot = try await freshSnapshot(.afterSearch(swiped: searchSwiped))
                        phase.snapshotMs += Self.ms(clock.now - start)
                        let previous = resolved
                        resolved = Self.resolve(step: step, in: snapshot)
                        if previous != nil { ghostRetries += 1 }
                    }
                }
            } else {
                var backoff = PollBackoff()
                for attempt in 0..<3 {
                    start = clock.now
                    try await Task.sleep(for: backoff.nextDelay())
                    phase.waitMs += Self.ms(clock.now - start)
                    // **撮り直しだけでは戻らないことがある**(2026-08-04 実測: 3回撮り直しても
                    // 容器の外に報告されたまま = タップが飲まれて `selected=-`)。
                    // 探索ループと同じく**もう1回送って**容器の中へ入れる。1周目は撮り直しだけ
                    // (木の遅れなら送らずに直る)、2周目以降だけ送る = 正常系のコストを増やさない
                    // **指の向きを持たないステップでも救済に入る**(2026-08-06): 素の `tap` は
                    // direction を持たないため、旧実装は ghost を検出しておきながら
                    // **1本も送らずにそのままタップ**していた。ghost は容器の外に居ることが
                    // 分かっているので、戻す向きは `recoveryJump` / `recoveryDirection` が
                    // 幾何から決められる(既定の finger は「内側に居るとき」しか使われない)
                    if attempt > 0, grabbedGhost(resolved),
                       let element = resolved?.0 {
                        let finger = FTSwipeDirection(rawValue: step.direction ?? "") ?? .up
                        let container = Self.clippingContainer(
                            of: element, in: snapshot.elements,
                            inferring: step.containerInference ?? true)
                        // **距離を測ってその分だけ動かす**(recoveryJump 参照)。全画面スワイプだと
                        // 100pt のずれに対して1ページ動いてしまい、**行き過ぎて往復する**。
                        // 容器が分かるときだけ使える手なので、駄目なら従来のスワイプへ落ちる
                        if let container,
                           let jump = Self.recoveryJump(for: element, container: container),
                           await hintDrag(jump: jump, container: container,
                                          viewport: snapshot.screen, phase: &phase) {
                            ghostSwipes += 1
                            _ = try await settledSignature(phase: &phase)
                            start = clock.now
                            snapshot = try await freshSnapshot(.afterSearch(swiped: searchSwiped))
                            phase.snapshotMs += Self.ms(clock.now - start)
                            let previous = resolved
                            resolved = Self.resolve(step: step, in: snapshot)
                            if previous != nil { ghostRetries += 1 }
                            if resolved != nil, !grabbedGhost(resolved) { break }
                            continue
                        }
                        // **行き過ぎた側なら逆へ送る**(recoveryDirection 参照)。同じ向きに
                        // 送り続けると遠ざかるだけで、実測でも2回撃って外のままだった
                        var recovery = step
                        recovery.direction = (container
                            .map { Self.recoveryDirection(for: element, container: $0,
                                                          searching: finger) } ?? finger).rawValue
                        _ = try await swipeWithFallback(
                            FTSwipeDirection(rawValue: recovery.direction ?? "") ?? finger,
                            intent: .search,
                            // **座標も逆向きで作り直す**(path は向きを内包している)
                            path: scrollPath(step: recovery, intent: .search, in: snapshot),
                            phase: &phase)
                        ghostSwipes += 1
                        _ = try await settledSignature(phase: &phase)
                    }
                    start = clock.now
                    snapshot = try await freshSnapshot(.afterSearch(swiped: searchSwiped))
                    phase.snapshotMs += Self.ms(clock.now - start)
                    let previous = resolved
                    resolved = Self.resolve(step: step, in: snapshot)
                    if previous != nil { ghostRetries += 1 }
                    if resolved != nil, !grabbedGhost(resolved) { break }
                }
            }
        }

        // driver フォールバック(ハイブリッド): primary(in-app)で解決できない、または primary が
        // label 部分一致(substring)でしか解決できていないとき、fallbackDriver(XCUITest=システム UI)
        // の snapshot でも解決を試す。act は解決した driver で行う。
        // substring 誤解決の偽陽性(in-app の label がシステム UI label の部分文字列で contains 命中し、
        // 本来当てたいシステム UI 要素へフォールバックされない)を、fallback の exact 一致で上書きする。
        // primary が exact のときは fallback を照会しない(従来どおりコスト増なし)。
        // **select は照会しない**: 掴むだけでデバイス操作が無く、掴めないことが答えになり得る
        // コマンドなので、システム UI 側を探す意味がない。実害もある — fb.snapshot() は
        // springboard セッションを張り、**同一デバイス1セッション制約でアプリ attach を潰す**。
        // WebView(domInterop)では直後の type が入らなくなった(2026-08-04 実測。
        // `select("wv_result=*")` はワイルドカードが quality=substring になり毎回ここを踏む)
        // 掴み直しの結果を**必ず注記に残す**: 救えたなら「なぜ遅かったか」の説明になり、
        // 救えなかったなら「タップが飲まれた可能性」を失敗調査の起点にできる(黙るのが最悪)
        // **救済で送った直後は、容器が次の1タッチを吸う**(探索終端と同じ既知の形。
        // docs/verification.md「スクロールした直後のタップ」)。探索終端では空打ちドラッグで
        // 肩代わりしているが、**救済経路には無かった** —— 実測(8並列 40 サンプル):
        // 救済が走った 18 件のうち **4 件が失敗**、走らなかった 22 件は **0 件**(p≈0.03)。
        // しかも失敗時の対象は容器のど真ん中(y=519〜534 / 容器 230..692)で座標は正しい。
        // 探索終端と**同じ順序**で肩代わり → 静止 → 掴み直しを行う
        if ghostSwipes > 0, releasesScrollTouch, let target = resolved?.0 {
            let x = target.frame.centerX
            let y = min(target.frame.centerY,
                        snapshot.screen.y + snapshot.screen.height - Self.bottomUncoveredBand - 1)
            if Self.emptyDragIsSafe(x: x, y: y, of: target, in: snapshot.elements,
                                    screen: snapshot.screen) {
                await emptyDrag(x: x, y: y,
                                toX: Self.emptyDragEndX(of: target, from: x, screen: snapshot.screen))
                let settled = try await settledSignature(phase: &phase)
                snapshot = settled.snapshot
                // 空打ちで木が入れ替わるので ref を取り直す(古い ref は別要素を指す)
                if let refreshed = Self.resolve(step: step, in: snapshot) { resolved = refreshed }
            }
        }

        var straddleNote: String?
        var ghostNote: String?
        if grabbedGhost(resolved) {
            ghostNote = "the element is still reported outside its scroll container"
                + " (\(ghostRetries) re-resolve(s), \(ghostSwipes) extra swipe(s));"
                + " the interaction may be swallowed"
        } else if ghostRetries > 0 {
            ghostNote = "re-resolved \(ghostRetries) time(s)"
                + (ghostSwipes > 0 ? " with \(ghostSwipes) extra swipe(s)" : "")
                + " — the element was first reported outside its scroll container"
        }

        var actingDriver: AppDriver = driver
        if action != "select", let fb = fallbackDriver {
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
        } else if action == "select" {
            // **select だけは掴めなくても失敗させない**(空要素を返して呼び出し側に .isEmpty で
            // 分岐させる契約)。自己修復の対象にもしない — 掴めないことが答えになり得るコマンドで
            // 別要素へ誤リダイレクトすると、空のはずが値を持って返る
            return StepOutcome(status: .skipped(Self.selectNotFoundReason))
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

        // **容器の縁にまたがった要素はそのまま撃たない**(2026-08-06)。見えている部分を撃っても、
        // Compose は focus 時に bringIntoView で内容を動かすため、離すまでに隣の行が指の下へ来る
        // (Emulator で約 50%・実測 135〜179px ずれて隣の行が反応した)。**容器の中へ寄せてから撃つ**。
        //
        // 2026-08-05 に撤回した「またぎも掴み直しの対象へ広げる」との違いは**送り方**:
        // あちらは全画面スワイプで行き過ぎて自傷した(S0110 が 2/10 → 5/10)。ここは
        // `recoveryJump`(容器の 40% 位置までの距離)+ `slowDrag`(フリングを出さない)なので
        // 行き過ぎない。**1回だけ**(収束しなければ従来どおり見えている部分を撃つ)
        if Self.interactsByTouch(action), step.containerInference ?? true,
           let container = Self.clippingContainer(of: element, in: snapshot.elements,
                                                  inferring: true),
           ScrollGeometry.intersection(element.frame, container) != nil,
           Self.isClippedByViewport(element, screen: container),
           let jump = Self.recoveryJump(for: element, container: container),
           await slowDrag(jump: jump, container: container, phase: &phase) {
            _ = try await settledSignature(phase: &phase)
            let refreshed = try await freshSnapshot(.afterOwnMove)
            if let (moved, _) = Self.resolve(step: step, in: refreshed) {
                snapshot = refreshed
                element = moved
                resolvedElementThisStep = element
                straddleNote = "nudged the element fully inside its container before touching it"
            }
        }

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
            // 飲まれたタップの証跡(LastInteraction 参照)。**操作の前**に採る = 比較の基準は
            // 「この操作を撃つ直前の画面」でなければ意味がない
            recordInteraction(step: step, element: element, in: snapshot)
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
            // **中心が容器の外に落ちる要素だけ、見えている部分の中心を座標で撃つ**
            // (visibleTapRect 参照)。ref で撃つとブリッジが frame の中心へ解決するので、
            // 壊れた frame ではそのまま容器の外を叩いて黙って飲まれる
            if let visible = Self.visibleTapRect(for: element, in: snapshot.elements,
                                                inferring: step.containerInference ?? true) {
                try await actingDriver.tap(x: visible.centerX, y: visible.centerY)
                driverFallback = Self.joinNotes(driverFallback,
                    "tapped the visible part (the reported frame's centre falls outside its container)")
            } else {
                try await actingDriver.tap(ref: element.ref)
            }
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
        case "pinchOut", "pinchIn", "doubleTap", "swipeBy":
            // 対象を指定した版。要素の frame(Android のピンチ中心・swipeBy の基準領域)と
            // identifier(XCUITest のピンチ対象)の両方を渡す(理由は BridgeDTO.PinchRequest)
            let outcome = try await performGesture(action, step: step, target: element.frame,
                                                   identifier: element.identifier,
                                                   viewport: snapshot.screen, phase: &phase)
            guard case .passed = outcome.status else { return outcome }
            driverFallback = outcome.driverFallback
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
                           driverFallback: Self.joinNotes(Self.joinNotes(driverFallback, ghostNote),
                                                          straddleNote))
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

    /// 注記の合流(どちらか片方だけのことが多いので nil を潰して " / " で繋ぐ)
    static func joinNotes(_ notes: String?...) -> String? {
        let present = notes.compactMap { $0 }.filter { !$0.isEmpty }
        return present.isEmpty ? nil : present.joined(separator: " / ")
    }

    /// 対象を取り得るジェスチャ(対象未指定なら画面全体)。ロケータ有無で解決だけが違うので
    /// 実体はここ1箇所に置く
    static let gestureActions: Set<String> = ["pinchOut", "pinchIn", "doubleTap", "swipeBy"]

    /// ピンチ / ダブルタップ / 相対ドラッグの実行。target = 対象領域(要素の frame か画面)、
    /// viewport = 画面矩形。**慣性が乗るので末尾で必ず整定を待つ**(ランナーはこれらのルートを
    /// 整定対象に入れていない。理由は BridgeRouter.mutatingPaths のコメント)
    private func performGesture(_ action: String, step: FlowStep, target: FTRect,
                                identifier: String?, viewport: FTRect,
                                phase: inout PhaseAccumulator) async throws -> StepOutcome {
        var viaXCUITest = false
        switch action {
        case "pinchOut", "pinchIn":
            let out = action == "pinchOut"
            let scale = step.scale
                ?? (out ? FlowStep.defaultPinchOutScale : FlowStep.defaultPinchInScale)
            // **向きと倍率が食い違ったら実行しない**。撃ってしまうと「pinchOut と書いたのに
            // 縮小された」が成功として記録され、書き間違いに気付けない
            guard scale.isFinite, out ? scale > 1 : (scale > 0 && scale < 1) else {
                return StepOutcome(status: .failed(
                    out ? "pinchOut requires scale > 1 (got \(scale)). Use pinchIn to zoom out."
                        : "pinchIn requires 0 < scale < 1 (got \(scale)). Use pinchOut to zoom in."))
            }
            viaXCUITest = try await pinchWithFallback(
                frame: target, identifier: identifier, scale: scale,
                durationSeconds: step.duration ?? FlowStep.defaultPinchDurationSeconds,
                phase: &phase)
        case "doubleTap":
            viaXCUITest = try await doubleTapWithFallback(x: target.centerX, y: target.centerY,
                                                          phase: &phase)
        case "swipeBy":
            guard let path = ScrollGeometry.panPath(container: target, viewport: viewport,
                                                    dxRatio: step.dxRatio ?? 0,
                                                    dyRatio: step.dyRatio ?? 0) else {
                // 動かないドラッグを撃って「成功」と記録すると、比率の書き間違いに気付けない
                return StepOutcome(status: .failed(
                    "swipeBy cannot build a usable path (the target area is off-screen, "
                        + "or dxRatio/dyRatio are too small to move a finger)"))
            }
            viaXCUITest = try await dragWithFallback(
                path: path,
                durationSeconds: step.duration ?? FlowStep.defaultSwipeDurationSeconds,
                phase: &phase)
        default:
            return StepOutcome(status: .skipped("unknown gesture: \(action)"))
        }
        let settled = try await settledSignature(phase: &phase).settled
        var notes: [String] = []
        if viaXCUITest { notes.append("fell back to XCUITest") }
        if !settled { note(.settleCapped, into: &notes) }
        return StepOutcome(status: .passed,
                           driverFallback: notes.isEmpty ? nil : notes.joined(separator: " / "))
    }

    /// 座標ドラッグを通常ドライバ →(501/ルート不明404 なら)typeDriver の順で撃つ。
    /// 座標はブリッジ間で共通(ref と違い取り直しが要らない)ので、そのまま渡すだけでよい。
    /// 戻り値: true = typeDriver(XCUITest)経由
    private func dragWithFallback(path: FTSwipePath, durationSeconds: Double,
                                  phase: inout PhaseAccumulator) async throws -> Bool {
        try await gestureWithFallback(phase: &phase) {
            try await $0.drag(fromX: path.fromX, fromY: path.fromY,
                              toX: path.toX, toY: path.toY,
                              pressSeconds: 0.05, durationSeconds: durationSeconds)
        }
    }

    private func doubleTapWithFallback(x: Double, y: Double,
                                       phase: inout PhaseAccumulator) async throws -> Bool {
        try await gestureWithFallback(phase: &phase) { try await $0.doubleTap(x: x, y: y) }
    }

    private func pinchWithFallback(frame: FTRect, identifier: String?, scale: Double,
                                   durationSeconds: Double,
                                   phase: inout PhaseAccumulator) async throws -> Bool {
        try await gestureWithFallback(phase: &phase) {
            try await $0.pinch(frame: frame, identifier: identifier, scale: scale,
                               durationSeconds: durationSeconds)
        }
    }

    /// 座標だけで完結するジェスチャの共通フォールバック。in-app が「このエンジンでは不可」と
    /// 返したとき(501 / ルート不明 404)だけ XCUITest へ回す —— in-app は自前描画の
    /// フレームワークなら多点も撃てるが、UIKit/SwiftUI では合成タッチが受理されず 501 を返す。
    /// **409 は含めない**(理由は DriverError.isEngineIncapable)
    private func gestureWithFallback(phase: inout PhaseAccumulator,
                                     _ body: (AppDriver) async throws -> Void) async throws -> Bool {
        let clock = ContinuousClock()
        let start = clock.now
        do {
            try await body(driver)
            phase.actionMs += Self.ms(clock.now - start)
            return false
        } catch {
            guard DriverError.isEngineIncapable(error), let td = typeDriver else { throw error }
            try await body(td)
            phase.actionMs += Self.ms(clock.now - start)
            return true
        }
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
    /// 戻り値: **静止を確認できたか**。false = 周回上限で打ち切った(= まだ動いているかもしれない)。
    /// 呼び手は注記にする(黙ると「動いている画面の座標をタップ」が誤った成功として通る)
    @discardableResult
    private func settleAfterScroll(step: FlowStep, found: ElementInfo,
                                   phase: inout PhaseAccumulator) async throws -> Bool {
        let clock = ContinuousClock()
        var previous = found.frame
        var lastSnapshotMs = 0
        for _ in 0..<Self.scrollSettleMaxPolls {
            let waitStart = clock.now
            try await Task.sleep(for: .milliseconds(
                Self.settleSleepMs(afterSnapshotMs: lastSnapshotMs,
                                   bypassing: bypassesCache(.afterOwnMove))))
            phase.waitMs += Self.ms(clock.now - waitStart)
            let start = clock.now
            // 静止判定も**キャッシュを捨てて**撮る。古いツリーは連続して同じ座標を返すので、
            // 素取得だと「2回続けて同じ = 止まった」が**遅れて公開された古い位置**で成立する
            // (runScrollSearch のスワイプ後の snapshot と同じ理由)
            let snapshot = try await freshSnapshot(.afterOwnMove)
            lastSnapshotMs = Self.ms(clock.now - start)
            phase.snapshotMs += lastSnapshotMs
            // 解決できなくなった = このスナップショットでは判定材料が無い。静止は名乗らない
            guard let (element, _) = Self.resolve(step: step, in: snapshot,
                                                  strictForAssert: true) else { return false }
            if element.frame == previous { return true }
            previous = element.frame
        }
        return false
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

    /// 要素を **clip している容器**の矩形(見切れ判定の viewport)。**スクロールの座標化には
    /// 使わない** = 暗黙の座標化とは別物(あちらは2度撤回済みで3度目は無い)。
    ///
    /// Compose iOS は容器の外・縁に子を報告する。`scrollable` の申告は Compose では出ないので、
    /// **報告された木そのものから容器を採る**: スナップショットは pre-order + depth なので、
    /// 直前にある depth の小さい要素が容器の候補。ただし**ブリッジは要素を間引く**
    /// (identifier の無い other 等)ので候補が叔父のことがある。そこで
    /// 「同じ depth の兄弟が2つ以上その中に居る」ことを確かめてから採用する ——
    /// 叔父を掴んだときは兄弟が誰も中に居ないので nil に落ちる。
    ///
    /// **交差の有無で絞らない**(2026-08-05 に条件を外した)。旧実装は「容器と交差しないときだけ」
    /// 容器を返していたため、**縁をまたぐ要素で nil に落ちて viewport が画面全体になっていた**。
    /// Compose は縁をまたぐ行を「原点はクリップ前・サイズはクリップ後」の混成で返すので、
    /// `#list_rows` が y 230..692 のとき `#row_30` が `(16,206 370x43)` = **中心 227.5 が容器の外**
    /// になる。画面基準では「見えている」と判定されて探索が止まり、隙間をタップして飲まれていた
    /// (S0110 の失敗 21 件中 **12 件**がこの形)。
    static func clippingContainer(of element: ElementInfo, in elements: [ElementInfo],
                                  inferring enabled: Bool = containerInferenceEnabled) -> FTRect? {
        guard enabled,
              let index = elements.firstIndex(where: { $0.ref == element.ref }),
              let ancestor = elements[..<index].last(where: { $0.depth < element.depth }),
              ancestor.frame.width > 0, ancestor.frame.height > 0
        else { return nil }
        let siblings = descendants(of: ancestor, in: elements).filter { $0.depth == element.depth }
        let inside = siblings.filter { ScrollGeometry.intersection($0.frame, ancestor.frame) != nil }
        return inside.count >= 2 ? ancestor.frame : nil
    }

    /// 要素が**容器の完全に外**に報告されているか(ghost)。`clippingContainer` と違い
    /// **交差しないことが条件**で、こちらは「掴んでしまった要素を捨てて掴み直す」判断に使う。
    /// **またぐ要素を含めてはいけない** —— 縁で救済スワイプを撃つと自傷する(grabbedGhost の記録)
    ///
    /// public なのは ftester-mcp の RefGuard が同じ判定を使うため(ref を撃つ直前の照合)。
    /// **判定はここ1箇所** —— MCP 側に別の閾値を置くと、DSL と MCP で「ghost の定義」が割れる
    public static func isOutsideContainer(_ element: ElementInfo, in elements: [ElementInfo]) -> Bool {
        guard let container = clippingContainer(of: element, in: elements) else { return false }
        return ScrollGeometry.intersection(element.frame, container) == nil
    }

    /// 端まで送っても見つからなかったときの**拾い直し**。探索方向を反転し、
    /// **容器基準の細刻み**(容器の約半分)で戻りながら毎周解決を試す。
    ///
    /// **なぜ失敗が確定してからだけ掛けるか**: 既定経路(`scrollFrame` 未指定)は刻みが
    /// エンジン任せで、1回の移動が容器を超えると要素がスワイプの合間に一度も木へ出ない。
    /// 通常の送りを容器基準に変える案は**2度実装して2度撤回**している(到達距離が縮んで
    /// 既定 maxSwipes で届かなくなる。docs/performance-tuning.md §3.19)。ここは
    /// **もう届かないと確定した後**なので、その撤回理由に触れない。
    /// 容器は推測なので `containerInference` で切れる(呼び出し側で判定済み)
    private func reverseSweep(step: FlowStep, container: FTRect,
                              searching finger: FTSwipeDirection,
                              phase: inout PhaseAccumulator) async throws -> FlowLocator?? {
        let back: FTSwipeDirection = switch finger {
        case .up: .down
        case .down: .up
        case .left: .right
        case .right: .left
        }
        // **スワイプではなくドラッグで戻す**。スワイプはフリングになり、この局面(端に着いている =
        // 残りの可動域が短い)では1回で反対の端まで走り切って、また同じ飛び越しを起こす
        // (2026-08-06 に Emulator で観測: path 付きスワイプでは1本も拾えなかった)。
        // slowDrag は距離ぶんの時間を必ず取るのでフリング閾値を下回る
        let vertical = back == .up || back == .down
        let extent = vertical ? container.height : container.width
        let jump = (back == .up ? 1.0 : -1.0) * extent * Self.reverseSweepSpanRatio
        guard vertical else { return nil }   // 横方向のドラッグ経路は未対応(縦の探索だけ救う)

        var previous: String?
        for _ in 0..<Self.reverseSweepMaxSwipes {
            guard await slowDrag(jump: jump, container: container,
                                 phase: &phase) else { return nil }
            let snapshot = try await freshSnapshot(.afterOwnMove)
            if let (element, fallback) = Self.resolve(step: step, in: snapshot,
                                                     strictForAssert: true) {
                // **見つけただけでは足りない**(本編の探索と同じ規則): 容器の縁で見切れている
                // 要素は frame がクランプされていてタップが外れる。まだ戻せるなら送り続ける
                // (iOS/Compose は可視域の外の行も木に残すので、ここを省くと ghost を掴む)
                if !Self.isClippedByViewport(element, screen: container) {
                    _ = try await settleAfterFind(step: step, element: element,
                                                  snapshot: snapshot, phase: &phase)
                    // **連続2回一致まで待つ**(settleAfterScroll より強い)。逆走査のドラッグは
                    // 遅い代わりに離した後もしばらく減速しながら動き、**掴んだ座標が
                    // タップまでにずれる**(2026-08-06 実測: 176px ずれて隣の行を叩いた)
                    _ = try await settledSignature(phase: &phase)
                    return .some(fallback)
                }
            }
            // 反対の端まで戻った(もう動かない)なら、この画面には無い
            let signature = Self.contentSignature(snapshot.elements)
            if signature == previous { return nil }
            previous = signature
        }
        return nil
    }

    /// 探索が要素を見つけた直後の後始末。**スワイプを撃った周回だけ**呼ぶ。戻り値は
    /// 「静止待ちが収束せず打ち切られた」= 呼び手はそれを注記に載せる。
    /// **順序に意味がある**(逆にすると Android で誤タップが再発する。2026-07-27 実測)
    private func settleAfterFind(step: FlowStep, element: ElementInfo,
                                 snapshot: SnapshotResponse,
                                 phase: inout PhaseAccumulator) async throws -> Bool {
        // 順序に意味がある(逆にすると Android で誤タップが再発する。2026-07-27 実測):
        //  1. **空打ちの極小ドラッグ**: iOS(Compose)のスクロール容器は次の1タッチを
        //     消費してしまい、タップもプレスも効かない(待っても解けない。2回目は効く)。
        //     **横へ抜けるドラッグ**でその1回ぶんを肩代わりする。向きの根拠は
        //     `emptyDragEndX` に書いてある(縦に抜くと容器がスクロールとして消費し、
        //     直後のアサーションが壊れる / 矩形の中で離すとクリックとして成立してしまう)
        //  2. **静止待ち**: 空打ちでリストが微動するので、止まってから返す
        // **触る点が他の要素に取られるなら打たない**。空打ちは手前の要素
        // (タブバー等)に届き、そのボタンが反応してしまう
        // (2026-07-27 実測: E2E-iOS の #txt_offscreen はタブバーの帯の中に出るため、
        // 空打ちでホームタブへ切り替わっていた)
        // **点は容器の中でありさえすればよい**(容器の1タッチを肩代わりするだけで、
        // 対象要素に当てる必要は無い)。そこで下端の a11y 空白帯に掛かるときは
        // 上へずらす —— 探索は「見えた瞬間」に止まるので、**1回の移動量が小さいほど
        // 対象は下端で見つかり**、ずらさないと空打ちが常に抑止される
        // (2026-08-02 実測: CMP で scrollFrame 指定時に #row_40 が y=829 で見つかり、
        // 空打ちが飛ばされてタップが容器に吸われた。従来の全画面スワイプでは y=720)
        let x: Double = element.frame.x + element.frame.width / 2
        let y: Double = min(element.frame.y + element.frame.height / 2,
                            snapshot.screen.y + snapshot.screen.height
                                - Self.bottomUncoveredBand - 1)
        if releasesScrollTouch,
           Self.emptyDragIsSafe(x: x, y: y, of: element,
                                in: snapshot.elements, screen: snapshot.screen) {
            await emptyDrag(x: x, y: y,
                            toX: Self.emptyDragEndX(of: element, from: x,
                                                    screen: snapshot.screen))
        }
        return try await !settleAfterScroll(step: step, found: element, phase: &phase)
    }

    /// 掴んだ要素を可視域へ入れ直すために**次に送る向き**。
    ///
    /// **探索方向へ送り続けてはいけない** —— 行き過ぎた側の要素は**さらに遠ざかる**。
    /// 2026-08-05 実測: `withScrollDown` の探索(指は上)で `#row_30` が容器(230..692)の**上**
    /// y=76 に報告され、ghost 検出後の追加スワイプ2回でも外のままだった
    /// (注記が `3 re-resolve(s), 2 extra swipe(s)` で残っていた = 検出はできていて救済が収束しない)。
    ///
    /// **`direction` は指の向き**(ブリッジへ渡る語彙)なので、内容を下へ戻すには指を下へ動かす。
    /// 中心が容器の内側にある間は探索方向のまま = 「まだ届いていない」ときの挙動は変わらない
    static func recoveryDirection(for element: ElementInfo, container: FTRect,
                                  searching finger: FTSwipeDirection) -> FTSwipeDirection {
        let frame = element.frame
        switch finger {
        case .up, .down:
            if frame.centerY < container.y { return .down }
            if frame.centerY > container.y + container.height { return .up }
        case .left, .right:
            if frame.centerX < container.x { return .right }
            if frame.centerX > container.x + container.width { return .left }
        }
        return finger
    }


    /// 要素が画面の縁で**見切れている**か。ビューポートより大きい要素(長文など)は
    /// どう送っても収まらないので false(送り続けて maxSwipes を使い切らせない)
    static func isClippedByViewport(_ element: ElementInfo, screen: FTRect) -> Bool {
        let frame = element.frame
        // **等しいときは「大きい」ではない**: リストの行は容器と同じ幅を持つのが普通で、
        // `<` にすると幅一致の行が丸ごと判定から漏れる(2026-08-02 実測: 下端で見切れた行が
        // 可視とみなされ、タップが容器の外のタブバーに当たって別画面へ遷移した)
        guard frame.height > 0, frame.width > 0,
              frame.height <= screen.height, frame.width <= screen.width else { return false }
        return frame.y < screen.y
            || frame.y + frame.height > screen.y + screen.height
            || frame.x < screen.x
            || frame.x + frame.width > screen.x + screen.width
    }

    /// **報告された座標が壊れている要素**か(= 同じ場所に同じ深さの兄弟が積み上がっている)。
    ///
    /// フレームワークは**容器の可視域を外れた子孫の frame の原点を、容器の原点へクランプする**。
    /// XCUITest の `UITableView` では**実体化していない行のラベルまでツリーに載り**、
    /// 全部が容器の原点に積み上がる(2026-08-05 実採取: 40 行のうち **32 個**が
    /// `(16,270 330x56)` に重なり、**すべて depth 8**)。これを掴むと:
    ///   - `tap("行 15")` が**先頭行をタップする**(実採取で再現。可視性ガードを通らないので沈黙)
    ///   - `exist("行 15")` が画面外なのに真を返す(「exist は非スクロール」の契約に反する)
    ///
    /// **判定に depth の一致が要る**(2026-08-05 に過去レポート 466 件へ当てて確認): frame だけで
    /// 判定すると `homepage_container > main_content > list_container > recycler_view` のような
    /// **入れ子の連鎖**(親子が同じ矩形を持つのは普通)を巻き込む。祖先と子孫は depth が違うので、
    /// 「同じ depth = 兄弟」を条件にすれば連鎖は残る。
    ///
    /// **「同じ場所に3つ」だけでは足りない**(2026-08-05: 症状で判定したら既存テスト 13 件が落ちた)。
    /// 同 depth の兄弟が同じ矩形を持つこと自体は珍しくない —— 重ねたオーバーレイや、
    /// 属性だけが違う要素群がそうなる。**機構そのもの**を条件にする:
    ///   「容器の**原点にちょうど固定**され、かつ容器より**小さい**要素が3つ以上重なっている」
    /// 実採取と一致する(容器 `#list_rows` (16,270.33 370x395.33) / 群 (16,270.33 **330x56**))。
    /// 全面に重ねた正当なオーバーレイは**容器と同じ大きさ**になるので、この条件では残る。
    ///
    /// 閾値3は `OcclusionSuspicion.isClampGhost` と同じ(親子2重で誤爆させない)。
    /// **あちらとは用途も条件も違う**ので統合しないこと —— あちらは「画面端に接する」ものを
    /// occluder の判定から外す話(FM を余計に呼ばないため)で、こちらは解決候補から外す話
    static func hasClampedCoordinates(_ element: ElementInfo, in elements: [ElementInfo],
                                      inferring enabled: Bool = containerInferenceEnabled) -> Bool {
        guard enabled else { return false }
        let frame = element.frame
        var count = 0
        for other in elements
        where other.depth == element.depth && Self.sameFrame(other.frame, frame) {
            count += 1
            if count >= Self.clampedStackThreshold { break }
        }
        guard count >= Self.clampedStackThreshold else { return false }
        // クランプ先(= 原点を貸している祖先候補)が居るか。**同じ大きさなら別物**
        return elements.contains { container in
            container.depth < element.depth
                && abs(container.frame.x - frame.x) <= 0.5
                && abs(container.frame.y - frame.y) <= 0.5
                && container.frame.width >= frame.width && container.frame.height >= frame.height
                && (container.frame.width > frame.width + 0.5
                    || container.frame.height > frame.height + 0.5)
        }
    }

    /// 同じ場所に積み上がっているとみなす数(自分を含む)
    static let clampedStackThreshold = 3

    /// frame の同一判定。**丸めではなく許容差**で見る(実採取の値は 270.3333… のような
    /// 分数座標で、同じ木の中では同値だが、丸めると隣接する別要素と衝突し得る)
    static func sameFrame(_ a: FTRect, _ b: FTRect, tolerance: Double = 0.5) -> Bool {
        abs(a.x - b.x) <= tolerance && abs(a.y - b.y) <= tolerance
            && abs(a.width - b.width) <= tolerance && abs(a.height - b.height) <= tolerance
    }

    /// その座標のタッチが**対象ではなく手前の別要素に渡る**か。スナップショットは pre-order
    /// (後 = 手前寄り)なので、対象より後ろにあって点を含む要素が居れば取られ得る。
    /// 対象の子孫は同じ見た目の一部なので除く。空打ちドラッグの安全判定に使う
    static func pointIsTakenByFrontElement(x: Double, y: Double, of element: ElementInfo,
                                           in elements: [ElementInfo]) -> Bool {
        frontElementTakingPoint(x: x, y: y, of: element, in: elements) != nil
    }

    /// 同上で、**取っている要素そのもの**を返す(失敗診断に名前を出すため)。
    /// 判定規則は pointIsTakenByFrontElement と1つの実装を共有する(片方だけ変わらないように)
    static func frontElementTakingPoint(x: Double, y: Double, of element: ElementInfo,
                                        in elements: [ElementInfo]) -> ElementInfo? {
        guard let index = elements.firstIndex(where: { $0.ref == element.ref }) else { return nil }
        let ownRefs = Set(descendants(of: element, in: elements).map(\.ref))
        return elements[elements.index(after: index)...].first { other in
            guard !ownRefs.contains(other.ref) else { return false }
            let f = other.frame
            return x >= f.x && x <= f.x + f.width && y >= f.y && y <= f.y + f.height
        }
    }

    /// 整定ポーリングの**周期を一定に保つ**待ち時間。判定したいのは
    /// 「約 `scrollSettleIntervalMs` の周期で画面が変わらないこと」であって sleep の長さではない。
    /// キャッシュ迂回の snapshot は Android で約 +35ms 掛かる(ブリッジ直叩きで 5.1ms → 39.9ms)ので、
    /// 差し引かないと周期が 100ms → 140ms へ伸び、**スクロール系のステップが丸ごと遅くなる**
    /// (2026-08-03 実測: scroll 系ステップ合計 +3.2s。差し引きで -2.0s 回収)。
    /// **迂回しないエンジン(iOS)では引かない** —— あちらは snapshot 自体が重く(xcuitest は
    /// 数百 ms)、引くと周期が大きく縮んで「早すぎる静止判定」に倒れる
    static func settleSleepMs(afterSnapshotMs: Int, bypassing: Bool) -> Int {
        guard bypassing else { return Self.scrollSettleIntervalMs }
        return max(Self.scrollSettleMinSleepMs, Self.scrollSettleIntervalMs - afterSnapshotMs)
    }

    /// 整定ポーリングの待ちの下限(busy loop 防止)
    static let scrollSettleMinSleepMs = 30

    /// スクロール静止待ちの上限(回数 × 間隔 = 最大 600ms)。フリングの減速はこの範囲で収まる
    static let scrollSettleMaxPolls = 6
    static let scrollSettleIntervalMs = 100
    /// screenIs が不一致だったときに撮り直すまでの待ち(ms)。**遷移の描き終わりを待つだけ**なので
    /// スクロールの整定待ち(6×100ms)と同じオーダーに置く。長くすると失敗の確定が遅れる
    static let screenMatchRetryDelayMs = 600

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
    /// 戻り値の `settled` は false = **ポーリング上限で打ち切った**(静止を確認できていない)。
    /// 呼び出し側は note にして可視化する。黙って返すと「毎回上限を使い切っているのに緑」が
    /// 続き、実際そうなっていた(ラベル振れによる非収束。2026-07-31 修正)
    private func settledSignature(
        phase: inout PhaseAccumulator) async throws
        -> (signature: String, snapshot: SnapshotResponse, settled: Bool) {
        func signature(_ snapshot: SnapshotResponse) -> String {
            snapshot.elements
                .map { "\($0.type)|\($0.frame.x),\($0.frame.y)" }
                .joined(separator: ",")
        }
        // **全周キャッシュを捨てて撮る**(Android のみ実費。iOS は素通し)。素取得だと
        // 遅れて公開された古いツリーが2回続けて同じ署名を返し、**動いている最中に
        // 「静止した」が成立する** —— しかも返す `last` が古い木なので、呼び出し側は
        // そのまま古い座標で解決する(settleAfterScroll と同じ理由。掃討 2026-08-03)。
        // 落ち着いた画面なら 2 枚で返るので固定費は約 +130ms/呼び出しに収まる
        let clock = ContinuousClock()
        var start = clock.now
        var last = try await freshSnapshot(.afterOwnMove)
        var previous = signature(last)
        var lastSnapshotMs = Self.ms(clock.now - start)
        phase.snapshotMs += lastSnapshotMs
        for _ in 0..<Self.scrollSettleMaxPolls {
            let waitStart = clock.now
            try await Task.sleep(for: .milliseconds(
                Self.settleSleepMs(afterSnapshotMs: lastSnapshotMs,
                                   bypassing: bypassesCache(.afterOwnMove))))
            phase.waitMs += Self.ms(clock.now - waitStart)
            start = clock.now
            last = try await freshSnapshot(.afterOwnMove)
            let current = signature(last)
            lastSnapshotMs = Self.ms(clock.now - start)
            phase.snapshotMs += lastSnapshotMs
            if current == previous { return (current, last, true) }
            previous = current
        }
        return (previous, last, false)
    }


    /// 空打ちの所要。速いとフリングになり、遅いと長押しになる
    static let emptyDragSeconds: Double = 0.30

    /// 空打ちドラッグの終点。**対象の矩形の外へ横に抜ける**のが要件。
    /// Compose iOS は「離した点が要素の中」ならクリックとして成立させるので、中に留まる限り
    /// **距離では消せない**(2026-08-03 実測: 2pt / 24pt / 120pt、0.05s / 0.30s のどれでも
    /// `scrollTo("#row_40")` だけで `selected=row_40` が入った = 読み取り専用のはずの
    /// コマンドがアプリの状態を書き換える)。矩形の外で離せばクリックは取り消される。
    /// **縦に抜いてはいけない**: 容器がスクロールとして消費して内容が動き、直後に
    /// 「今ここにある」を確かめる assertion が壊れる(実測: E2E-CMP/ios-inapp の S0020 が 0/3)。
    /// **止めるという選択肢も無い**: 完全に外すと肩代わりが効かず S0080 が CMP/ios で落ちる
    static func emptyDragEndX(of element: ElementInfo, from x: Double, screen: FTRect) -> Double {
        let right = element.frame.x + element.frame.width + 4
        if right <= screen.x + screen.width - 1 { return right }
        let left = element.frame.x - 4
        return left >= screen.x + 1 ? left : x
    }

    /// スクロール探索直後の「空打ち」極小ドラッグ(呼ぶ条件は呼び出し側の判定を参照)。
    /// **in-app エンジンは drag を一切実装しない**(501)ため、hybrid では typeDriver=XCUITest へ
    /// 回さないとこの対策が丸ごと不発になる(= Compose の容器がタッチを1回吸ったままになり、
    /// 直後の tap/press が空振りする)。空打ちは補助でありこれ自体の失敗はステップの失敗にしない
    /// (両経路とも失敗したら黙って進む = 従来の `try?` と同じ扱い)
    private func emptyDrag(x: Double, y: Double, toX: Double) async {
        func drag(_ target: AppDriver) async throws {
            try await target.drag(fromX: x, fromY: y, toX: toX, toY: y,
                                  pressSeconds: 0.05, durationSeconds: Self.emptyDragSeconds)
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

    /// intent: swipe の用途(`FTSwipeIntent`)。in-app の Compose/Flutter は
    /// gesture かどうかだけを見る(混ぜるとジェスチャ画面が黙って空振りする)。
    /// Android ブリッジは edge のときだけ強いフリングを使う(`SwipeRequest.fling`)
    private func swipeWithFallback(_ direction: FTSwipeDirection,
                                   intent: FTSwipeIntent = .gesture,
                                   path: FTSwipePath? = nil,
                                   phase: inout PhaseAccumulator) async throws -> Bool {
        let clock = ContinuousClock()
        if typeDriverGestures.contains("swipe") || gestureFallbackLatched, let td = typeDriver {
            let start = clock.now
            try await td.swipe(direction, intent: intent, path: path)
            phase.actionMs += Self.ms(clock.now - start)
            return true
        }
        do {
            let start = clock.now
            try await driver.swipe(direction, intent: intent, path: path)
            phase.actionMs += Self.ms(clock.now - start)
            return false
        } catch {
            // 「このエンジンでは不可」(501 / ルート不明 404)だけ XCUITest へ回す。
            // 409 を含めない理由は DriverError.isEngineIncapable 参照。
            // **座標つきは in-app が必ず 501 を返す**(合成タッチの drag を受理しないため)ので、
            // scrollFrame 指定時の hybrid はここで XCUITest へ落ちる
            guard DriverError.isEngineIncapable(error), let td = typeDriver else { throw error }
            let start = clock.now
            try await td.swipe(direction, intent: intent, path: path)
            phase.actionMs += Self.ms(clock.now - start)
            gestureFallbackLatched = true
            return true
        }
    }

    /// `scrollFrame` を解決するためだけの snapshot。**scroll/scrollToEdge は指定があるときしか
    /// 呼ばない**(従来経路に snapshot を1枚増やさないため)。**flick は scrollFrame の有無に
    /// 関わらず毎回呼ぶ**(未指定でも画面全体を対象に座標を作る必要があるため)
    private func snapshotForScrollFrame(phase: inout PhaseAccumulator) async throws -> SnapshotResponse {
        let clock = ContinuousClock()
        let start = clock.now
        let snapshot = try await driver.snapshot()
        phase.snapshotMs += Self.ms(clock.now - start)
        return snapshot
    }

    /// scrollFrame の空振り申告(ステップの注記へ載せる。1ステップ1回だけ)
    private var pendingScrollFrameNote: String?
    private var reportedScrollFrameNote = false

    /// 探索スワイプの刻み倍率(自己補正)。**1回の移動量が容器を超えると要素を飛び越す**ので、
    /// 実移動量を毎周測って詰める。較正表は持たない(端末・SUT を跨ぐと再現しないため。
    /// docs/performance-tuning.md §3.16 / §3.18)。ステップごとに 1.0 へ戻す。
    /// **読むのは `scrollPath` の1箇所だけ** = `scrollFrame` を書いた経路でしか効かない
    private var spanScale: Double = 1

    /// 実移動量が容器のこの割合を超えたら刻みを詰める(飛び越しの余裕を残す)
    /// **もう動かない**と判定するまでの連続周回数。1 だと遅れて描画される行を取りこぼす
    static let unmovedRoundsToStopSearch = 2

    /// 逆走査の刻み(容器に対する割合)と上限本数。**失敗が確定してからしか撃たない**ので
    /// 上限は「近くを通り過ぎた」を拾える程度でよい(遠くまで戻すと失敗が遅くなるだけ)
    static let reverseSweepSpanRatio: Double = 0.5
    static let reverseSweepMaxSwipes = 8
    /// 逆走査のドラッグ速度(px/s)。**フリングの閾値を下回る**ことが目的で、速いと慣性で走り、
    /// 遅いと1周が高くつく
    static let reverseSweepDragSpeed: Double = 120

    static let travelCeilingRatio: Double = 0.8
    /// 詰めるときの倍率(急に効かせすぎると往復が増えるので緩やかに)
    static let spanShrinkFactor: Double = 0.6
    /// 刻みの下限(これ以上小さくすると周回数が増えるだけ)
    static let minSpanScale: Double = 0.25

    /// 直前のスワイプで**実際に動いた量**。前後のスナップショットに共通する要素の frame 差の
    /// 中央値で測る(1要素だと再利用セルのラベル振れに引きずられる)。
    ///
    /// **共通要素が無いときは nil(不明)を返す**。「1画面ぶん動いた」とは限らず、画面遷移や
    /// id を持たない画面でも同じ状態になるため、行き過ぎと読むと**刻みを縮め続けて到達できなくなる**
    /// (2026-08-02 に実際に踏んだ: #txt_offscreen への scrollTo が maxSwipes を使い切って失敗)
    /// **スワイプで中身が入れ替わった領域**の推測 = スクロールした容器。
    /// 2枚の木を比べ、**後の木にだけ現れた要素**の clip 元を数えて最頻のものを採る。
    ///
    /// **スワイプ点から推測してはいけない**: 既定スワイプの始点はブリッジ側の比率
    /// (Android は画面 70%)で、ホストは知らない。中央と決め打つと、下寄せの容器で nil になる
    /// (2026-08-06 に実測)。**動いた要素から採るのも駄目** —— 飛び越したときは
    /// 2枚の木に共通の要素が1つも無い(だから「消えた/現れた」で見る)
    static func changedContentContainer(before: SnapshotResponse, after: SnapshotResponse)
        -> FTRect? {
        let known = Set(before.elements.compactMap(\.identifier).filter { !$0.isEmpty })
        var tally: [String: (rect: FTRect, count: Int)] = [:]
        for element in after.elements {
            guard let id = element.identifier, !id.isEmpty, !known.contains(id),
                  let container = clippingContainer(of: element, in: after.elements,
                                                    inferring: true)
            else { continue }
            let key = "\(container.x),\(container.y),\(container.width),\(container.height)"
            tally[key] = (container, (tally[key]?.count ?? 0) + 1)
        }
        return tally.values.max { $0.count < $1.count }?.rect
    }

    /// 中身の**入れ替わり**では採れないときの対**: 位置が動いた要素の clip 元。
    /// iOS(Compose)は可視域の外の行も木に残す(ghost)ので id 集合が変わらず、
    /// `changedContentContainer` が nil になる —— そのぶんフレームは動くのでこちらで拾える
    static func movedContentContainer(before: SnapshotResponse, after: SnapshotResponse,
                                      vertical: Bool) -> FTRect? {
        let index = Dictionary(before.elements.compactMap { element -> (String, ElementInfo)? in
            guard let id = element.identifier, !id.isEmpty else { return nil }
            return (id, element)
        }, uniquingKeysWith: { first, _ in first })
        var tally: [String: (rect: FTRect, count: Int)] = [:]
        for element in after.elements {
            guard let id = element.identifier, let old = index[id] else { continue }
            let delta = vertical ? element.frame.y - old.frame.y : element.frame.x - old.frame.x
            guard abs(delta) > 1,
                  let container = clippingContainer(of: element, in: after.elements,
                                                    inferring: true)
            else { continue }
            let key = "\(container.x),\(container.y),\(container.width),\(container.height)"
            tally[key] = (container, (tally[key]?.count ?? 0) + 1)
        }
        return tally.values.max { $0.count < $1.count }?.rect
    }

    /// 木の**形だけ**から採るスクロール容器(2枚の比較が要らない最後の手段)。
    /// **子がはみ出している clip 領域**を探す —— はみ出しはスクロールで外へ出た子の姿で、
    /// 静止した木にも残る。iOS(Compose)は id 集合も frame も変わらないことがあり、
    /// `changedContentContainer` / `movedContentContainer` がどちらも nil になる
    static func overflowingContainer(in snapshot: SnapshotResponse) -> FTRect? {
        var tally: [String: (rect: FTRect, count: Int)] = [:]
        for element in snapshot.elements {
            guard let container = clippingContainer(of: element, in: snapshot.elements,
                                                    inferring: true),
                  // 完全に外 = スクロールで押し出された子(またぎは数えない)
                  ScrollGeometry.intersection(element.frame, container) == nil
            else { continue }
            let key = "\(container.x),\(container.y),\(container.width),\(container.height)"
            tally[key] = (container, (tally[key]?.count ?? 0) + 1)
        }
        return tally.values.max { $0.count < $1.count }?.rect
    }

    static func measuredTravel(before: SnapshotResponse, after: SnapshotResponse,
                               vertical: Bool) -> Double? {
        var deltas: [Double] = []
        let index = Dictionary(before.elements.compactMap { element -> (Int, ElementInfo)? in
            guard let id = element.identifier, !id.isEmpty else { return nil }
            return (id.hashValue, element)
        }, uniquingKeysWith: { first, _ in first })
        for element in after.elements {
            guard let id = element.identifier, !id.isEmpty,
                  let previous = index[id.hashValue] else { continue }
            deltas.append(vertical ? previous.frame.y - element.frame.y
                                   : previous.frame.x - element.frame.x)
        }
        guard !deltas.isEmpty else { return nil }
        let sorted = deltas.map(abs).sorted()
        return sorted[sorted.count / 2]
    }

    /// 指定した `scrollFrame` が**スクロールできない領域**を指していないか。
    /// 指していれば座標は正しく作られ、スワイプは 200 を返し、**何も起きない**(端に達したのと
    /// 区別できないので署名では検出できない)= 黙った空振りになる。
    ///
    /// **判定に使えるのは「true を見つけたとき」だけ**: `scrollable` を申告できないエンジン
    /// (Compose/Flutter の in-app)では全要素が nil になるので、そこで警告すると誤報になる。
    /// だから**画面のどこかに scrollable=true が1つでもあるとき**にだけ判定する。
    /// 戻り値は注記(nil = 問題なし・申告できないエンジン)
    static func scrollFrameNote(_ frame: ElementInfo, in snapshot: SnapshotResponse) -> String? {
        guard snapshot.elements.contains(where: { $0.scrollable == true }) else { return nil }
        if frame.scrollable == true { return nil }
        // 容器そのものが scrollable でなくても、**中のスクロール可能な要素**が動けば意図は満たされる
        // (「リストを包む枠」を指定するのは自然な書き方)
        let inside = snapshot.elements.contains { element in
            element.scrollable == true && ScrollGeometry.intersection(element.frame, frame.frame) != nil
        }
        if inside { return nil }
        return "the specified scrollFrame is not scrollable"
            + " (the swipe lands there but nothing moves)"
    }

    /// `scrollFrame` 指定時のスワイプ座標。**nil = 従来の全画面固定へ落ちる**。
    /// 落ちる条件は「指定が無い」「その画面で解決できない」「削りすぎて動かせない」の3つで、
    /// どれも Shirates が次の候補へ落ちるのと同じ扱い(明示指定は矩形の供給元であって、
    /// スクロール可能かの判定はしない)。
    ///
    /// **毎回の snapshot から解決し直す**: 容器の矩形はスクロールやレイアウト変化で動く。
    /// 較正値は持たない(WebView のヒント跳躍と同じ自己補正の方針)
    private func scrollPath(step: FlowStep, intent: FTSwipeIntent,
                            in snapshot: SnapshotResponse) -> FTSwipePath? {
        guard Self.coordinateScrollEnabled else { return nil }
        // FlowStep.direction は**指の向き**(ブリッジへ渡る語彙)。コンテンツ基準へ戻すのに
        // 逆写像を書き足さない —— 写像は `FTScrollDirection.swipe` の1箇所だけという契約
        let finger = FTSwipeDirection(rawValue: step.direction ?? "") ?? .up
        let direction = FTScrollDirection.allCases.first { $0.swipe == finger } ?? .down
        let vertical = direction == .up || direction == .down

        guard let container = scrollContainer(step: step, in: snapshot, vertical: vertical) else {
            return nil
        }

        // 自己補正(spanScale)は探索だけに掛ける。**較正表を持たない**のが方針で、
        // 実移動量を毎周測って次の刻みを詰める(WebView のヒント跳躍と同じ考え方)
        let base = step.startMarginRatio
            ?? FTScrollDefaults.startMarginRatio(intent: intent, vertical: vertical)
        let baseEnd = step.endMarginRatio
            ?? FTScrollDefaults.endMarginRatio(intent: intent, vertical: vertical)
        let scaled = Self.scaledMargins(start: base, end: baseEnd, scale: spanScale)
        return ScrollGeometry.path(
            container: container,
            viewport: snapshot.screen,
            direction: direction,
            startMarginRatio: scaled.start,
            endMarginRatio: scaled.end)
    }

    /// このステップのスクロール対象領域。**nil = 従来の全画面固定へ落ちる**。
    /// スワイプ座標の計算(`scrollPath`)と、見つけた要素の見切れ判定の**両方**がこれを使う ——
    /// 見切れは画面ではなく**容器の縁**で起きるので、判定を画面基準にすると
    /// 「容器の外にはみ出した行」を可視とみなしてタップが容器の外(タブバー等)へ落ちる
    /// (2026-08-02 実測: #row_30 が y=745・容器の下端 762 で見つかり、中心 773 のタップが
    /// タブバーに当たって別画面へ遷移した)
    func scrollContainer(step: FlowStep, in snapshot: SnapshotResponse,
                         vertical: Bool) -> FTRect? {
        guard Self.coordinateScrollEnabled else { return nil }
        if let locator = step.scrollFrame {
            guard let element = Self.match(locator, in: snapshot) else { return nil }
            // 空振りの申告は1ステップにつき1回だけ(周回ごとに積むとレポートが埋まる)
            if pendingScrollFrameNote == nil, !reportedScrollFrameNote {
                pendingScrollFrameNote = Self.scrollFrameNote(element, in: snapshot)
                reportedScrollFrameNote = pendingScrollFrameNote != nil
            }
            return element.frame
        }
        // **未指定は従来のエンジン既定に任せる**(2026-08-02 に実装 → 撤回 → 08-03 に条件を
        // 変えて再投入 → 再び撤回。**3度目は無い**)。2度目の撤回理由:
        //  - 狙いだった Compose の飛び越しには**効かない**。Compose の容器は xcuitest で
        //    `other` として出て `scrollable` を申告できず、そもそも対象に選べない
        //  - in-app では**到達距離が縮んで既定 maxSwipes(8)で届かなくなる**(実測:
        //    E2E-iOS/ios-inapp の `tap("#row_40")` が失敗)。in-app の 0.85 ページ送りは
        //    エンジン既定として維持する、という決定にも反する
        // 領域を絞りたい利用者は `scrollFrame` を書く(そこでは価値が出ている)
        return nil
    }

    /// 自己補正の倍率をマージンへ写す。span = 1 - start - end を scale 倍し、両端へ等分に戻す
    static func scaledMargins(start: Double, end: Double, scale: Double)
        -> (start: Double, end: Double) {
        guard scale < 0.999 else { return (start, end) }
        let span = max(0.05, (1 - start - end) * scale)
        let margin = max(0, (1 - span) / 2)
        return (margin, margin)
    }

    /// 座標スクロールの殺しスイッチ。`FT_SCROLL_TARGET=legacy` でブリッジ側の
    /// 固定比率(従来経路)へ丸ごと戻す
    static let coordinateScrollEnabled =
        ProcessInfo.processInfo.environment["FT_SCROLL_TARGET"] != "legacy"

    /// **容器をツリーから推測して行う補正**の殺しスイッチ。`FT_CONTAINER_INFERENCE=off` で
    /// まとめて止め、推測を持たなかった頃の挙動(見切れ判定は画面基準・掴み直し無し・
    /// 座標補正無し・候補の除外無し)へ戻す。
    ///
    /// **なぜ要るか**: 容器は「pre-order で直前にある depth の小さい要素」+「同 depth の兄弟が
    /// 2つ以上その中に居る」という**推測**で決めている(`clippingContainer`)。E2E は 4 SUT しか
    /// 見ていないので、想定外のツリーでは推測が外れ得る。外れたときに起きるのは
    /// **より悪い事態**(別の場所を叩く・明後日の方向へ送る・正当な要素が候補から消える)なので、
    /// 利用者が1つの環境変数で全部止められるようにしておく。
    /// 影響範囲を1箇所に閉じるため、**推測の入口(`clippingContainer`)と
    /// `hasClampedCoordinates` の2箇所だけ**でこのフラグを見る
    public static let containerInferenceEnabled =
        ProcessInfo.processInfo.environment["FT_CONTAINER_INFERENCE"] != "off"

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

        // **ステップの実効値を解決経路へ流す**(execute の入口で畳んである。nil = 既定 on)
        let inferring = step.containerInference ?? containerInferenceEnabled
        for (locator, isPrimary) in chain {
            if let (element, quality) = matchDetailed(locator, in: snapshot, inferring: inferring) {
                return (element, isPrimary ? nil : locator, quality)
            }
        }
        return nil
    }

    public static func match(_ locator: FlowLocator, in snapshot: SnapshotResponse) -> ElementInfo? {
        matchDetailed(locator, in: snapshot)?.0
    }

    public static func matchDetailed(_ locator: FlowLocator, in snapshot: SnapshotResponse,
                                     inferring: Bool = containerInferenceEnabled)
        -> (ElementInfo, MatchQuality)? {
        matchDetailed(locator, elements: snapshot.elements, inferring: inferring)
    }

    /// ロケータに一致する要素を 1 つ選ぶ。選択規則:
    /// 属性フィルタ(全て AND)で絞る → `[n]` 番目を採る → 相対ステップがあれば順に辿る。
    /// 相対セレクタ(`通知:rightSwitch`)では属性フィルタが**対象ではなく基準**を指す。
    public static func matchDetailed(_ locator: FlowLocator, elements: [ElementInfo],
                                     inferring: Bool = containerInferenceEnabled)
        -> (ElementInfo, MatchQuality)? {
        guard let matches = candidates(locator, elements: elements, inferring: inferring),
              !matches.isEmpty else {
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
    public static func candidates(_ locator: FlowLocator, elements: [ElementInfo],
                                  inferring: Bool = containerInferenceEnabled) -> [ElementInfo]? {
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
            let excluded = Set(candidates(exclusion, elements: pool, inferring: inferring)?.map(\.ref) ?? [])
            if excluded.isEmpty { continue }
            pool = pool.filter { !excluded.contains($0.ref) }
        }
        // **座標が壊れている要素は候補にしない**(hasClampedCoordinates 参照)。
        // 最後に引くのは、絞り込みで1〜数件になってからでないと走査が無駄になるため。
        // **他に候補が無いときも引く** —— 残すと「見つかったのにタップが別の場所へ落ちる」
        // 沈黙の誤りになり、`exist` も画面外の要素で真を返す(契約は「現在画面のみ判定」)。
        // 計算量は O(|pool| × |elements|) だが、要素数の多い WebView 画面(200 程度)でも
        // 数万回の矩形比較 = 1ms 未満で、snapshot 1枚の往復(数百 ms)に対して無視できる。
        // 群ごとに1回だけ判定する形へ畳むこともできるが、規則の実装が2つに割れる方が高くつく
        return pool.filter { !Self.hasClampedCoordinates($0, in: elements, inferring: inferring) }
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
        if let hint = clampedStackHint(for: locator, in: elements) { hints.append(hint) }
        // 候補の区切りが " / " なので、ヒント同士は別の記号で割る(読み手が機械でも人でも混ざらない)
        return hints.isEmpty ? nil : hints.joined(separator: "。")
    }

    /// **候補から外した理由**を書く(`hasClampedCoordinates` 参照)。これが無いと、画面外の行を
    /// ラベルで指した利用者には「在るのに見つからない」としか見えない —— 実際にはツリーには
    /// 在り、**座標だけが壊れている**ので候補から外した、というのが起きていること。
    /// **黙って消すのが最悪**なので、消したときは必ずここで説明する
    static func clampedStackHint(for locator: FlowLocator, in elements: [ElementInfo]) -> String? {
        // 「フィルタには一致するが座標が壊れている」要素だけを数える(素の一致は上の近傍候補が出す)
        let broken = elements.filter { element in
            guard hasClampedCoordinates(element, in: elements) else { return false }
            if let id = locator.id, element.identifier != id { return false }
            if let label = locator.label, element.label != label { return false }
            return locator.id != nil || locator.label != nil
        }
        guard let sample = broken.first else { return nil }
        let frame = sample.frame
        // 同じ場所に積み上がっている数(**sample と同じ矩形のものだけ**を数える。
        // 画面に複数のスタックがあっても、利用者が指した要素の話に閉じる)
        let stacked = elements.filter { Self.sameFrame($0.frame, frame) && $0.depth == sample.depth }
        return "it is in the tree but its coordinates are unusable"
            + " — \(stacked.count) elements are"
            + " stacked at the same spot (\(Int(frame.x)),\(Int(frame.y))"
            + " \(Int(frame.width))x\(Int(frame.height)));"
            + " the framework clamps offscreen descendants to the container origin,"
            + " so scroll it into view first (scrollTo / tap(scroll:))"
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
