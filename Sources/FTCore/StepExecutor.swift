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

/// `healLocator` が実際に FM を呼べた結果。**nil を返してよいのは呼べなかった/エラーだったときだけ**
/// (資源ゲート待ちタイムアウト・session の例外)。FM が答えを返した回は必ずこの3ケースのどれかで
/// 運ぶ —— 「要素へ引き戻せなかった」を nil に潰すと、2026-09-02 に実際に踏んだ「黙る経路」
/// (`cannot resolve the locator` としか出ず、モデルが何を返したか一切見えない)に戻る。
public enum HealAttempt: Sendable {
    /// 要素へ引き戻せた(採用するかは confidence 次第。StepExecutor+Actions 側の判定)
    case proposed(HealProposal)
    /// FM は答えたが、その生テキストが木のどの要素にも一致しなかった(`resolveByText` が nil)。
    /// 呼び出し側が失敗文言・注記へ流すため、答えは整形せずそのまま運ぶ
    case unresolved(rawAnswer: String)
    /// FM は一覧を見たうえで**「妥当な代わりが無い」と判断した**(`LocatorRepairSuggestion.elementText`
    /// が nil)。`.unresolved`(モデルは何かを名指ししたが木のどの要素にも一致しなかった=答えの質の
    /// 問題)とは意味が違う正常な結論 —— 要素が本当に消えている場合はこれが正解(2026-09-02 実測:
    /// 存在しない要素をわざと叩く陽性対照シナリオで、選択肢を与えない設計のせいでモデルが無関係な
    /// 要素を medium confidence で提案していた)
    case noReplacement(rationale: String)
}

/// FM フック。実装は FTFoundationModels 側(失敗時のみ呼ばれる: 自己修復・画面検証・トリアージ)。
public protocol ReplayDelegate: AnyObject {
    func healLocator(step: FlowStep, snapshot: SnapshotResponse) async -> HealAttempt?
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
        /// 「結論が出ない」状態(ユーザー決定)。シナリオは中断しない = 失敗扱いしない
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
    /// 参照)。実際のコマンド実行結果ではないため、機械可読 NDJSON(fleetest api run)では
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
    /// スクロール探索で実際に撃ったスワイプ数(runScrollSearch を経由したときだけ非nil。
    /// scrollSwipesThisStep と同じ受け渡し形)。MCP の ft_scroll_to が所要時間の内訳に使う
    public let scrollSwipes: Int?
    /// 失敗したときの素性(`StepFailureKind`)。**言えない失敗では nil のまま**。
    /// notes と同じ累積器方式(`failureKindThisStep`)で内側から立て、`execute` の出口で載せる
    public let failureKind: StepFailureKind?

    public init(status: StepResult.Status, healedStep: FlowStep? = nil, healedByCache: Bool = false,
               timing: StepTiming? = nil, driverFallback: String? = nil,
               notes: [StepNote] = [],
               observedChecked: Bool? = nil, resolvedElement: ElementInfo? = nil,
               scrollSwipes: Int? = nil, failureKind: StepFailureKind? = nil,
               at: String = ISO8601Millis.string(from: Date())) {
        self.failureKind = failureKind
        self.observedChecked = observedChecked
        self.resolvedElement = resolvedElement
        self.scrollSwipes = scrollSwipes
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
    /// システム許可アラートの登録台帳(DSL の `iosAlertHandler` が登録する)。
    /// 空 = 監視しない。**fallbackDriver がある(hybrid)ときだけ効く**。
    /// 登録の形・発火で外れる規則は `SystemAlertRule` / `SystemAlertWatchlist` の doc
    public var systemAlertWatchlist = SystemAlertWatchlist()
    /// **登録の無い**システムアラートを1回だけ確かめる契機(launch 系の直後)。FTRuntime が
    /// launchApp / restartApp 等の後に立て、次の触る操作が消費する。登録がある間は
    /// SystemUIGate(毎ステップ)が担うのでこちらは見ない
    public var systemAlertProbePending = false
    /// このステップで「登録の無いアラートが前面にあった」事実(StepOutcome の注記に合流)
    var systemAlertAdvisoryThisStep: String?

    /// 次の触る操作で1回だけ SpringBoard に聞く契機を立てる。呼ぶのは FTRuntime の2箇所:
    /// launch 系コマンドの直後(performCustom)と **CAE の各フェーズ(condition / action /
    /// expectation)の先頭**。OS のアラートは起動直後だけでなくオンボーディングの途中
    /// (アプリ内の事前説明を閉じた直後の通知許可・ATT)でも出るので、フェーズ単位で
    /// 1回だけ見る(シーンあたり高々3往復 ≈ 0.2s。毎ステップの往復は登録がある間だけ)
    public func armUnregisteredSystemAlertProbe() { systemAlertProbePending = true }
    /// launch 系の直後(後方互換の別名)
    public func noteAppLaunched() { armUnregisteredSystemAlertProbe() }

    /// **登録が無いときだけ**1回 SpringBoard に聞き、前面に出ていれば名指しを返す。
    /// 登録がある間は `waitOutSystemUI` / `SystemUIGate` が担うので nil(二重に聞かない)。
    /// XCUITest ランナー(fallback)が無い構成も nil(聞く口が無い)。
    /// 契機は2つだけ(安さのため): launch 直後の最初の触る操作 / ステップの失敗。
    /// **操作は止めない**(閉じるのはシナリオの責務。新しい検知は警告から)
    func unregisteredSystemAlert(phase: inout PhaseAccumulator) async -> String? {
        guard !systemAlertWatchlist.isWatching, let fb = fallbackDriver else { return nil }
        let clock = ContinuousClock()
        let start = clock.now
        let probe = try? await fb.systemAlert()
        phase.snapshotMs += Self.ms(clock.now - start)
        guard SystemUIGate.isCovered(probe) else { return nil }
        noteCodesThisStep.insert(.systemAlertPresent)
        return SystemUIGate.describeUnregistered(probe)
    }

    /// 失敗ステータスに「前面のシステムアラート」を添える(登録が無いときだけ・1往復)。
    /// 時間切れ・操作が効かなかった失敗の原因がアラートなら、その題名が失敗文言に出る
    func annotatedWithSystemAlert(_ status: StepResult.Status,
                                  phase: inout PhaseAccumulator) async -> StepResult.Status {
        guard case .failed(let message) = status else { return status }
        guard let described = await unregisteredSystemAlert(phase: &phase) else { return status }
        return .failed(message + " — " + SystemUIGate.unregisteredAdvice(described))
    }
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
    var gestureFallbackLatched = false
    /// drag(スクロール探索直後の空打ち)専用のラッチ。**gestureFallbackLatched と共有しない**:
    /// in-app は drag を一切実装しないので必ず 501 になるが、swipe は UIKit なら
    /// contentOffset 経路で決定的に効く。共有すると drag の 501 だけで全 swipe が XCUITest 実
    /// スワイプ化し、バウンス由来の flake を持ち込む(typeDriverGestures の注意書きと同じ理由)
    var dragFallbackLatched = false
    public var delegate: ReplayDelegate?
    public var healingEnabled: Bool
    /// 実行プロファイルの falsePositiveCheck に対応するマスタースイッチ(既定 true)。false なら
    /// occlusionGuard/perStepGuard の値に関わらず occlusion-guard 自体を無効化する
    public var occlusionGuardEnabled: Bool
    /// 実行プロファイルの screenLooksLike に対応するマスタースイッチ(既定 true)。false なら
    /// screenMatches ステップを skip する
    public var screenLooksLikeEnabled: Bool
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
    /// [occlusion-guard] StaleFrameDetector の前回観測(凍結フレーム検知用)。cachedScreenshot と
    /// 同じくエンジン1本につき1系列(StepExecutor はエンジンごとに1インスタンス)。
    /// **cache 供給(同一 Data 使い回し)のときは更新しない** —— guardScreenshot 参照
    var lastGuardFrameRecord: StaleFrameDetector.Record?
    /// 白フレーム確定時に呼ぶ。FTDriveCore が凍結中断+deviceFrozen emit を行う
    public var onDeviceFrozen: (@Sendable () -> Void)?
    /// システム許可アラートを自動で押したときに呼ぶ(FTDriveCore が run ログへ流す)。
    /// **報告は判定の中(dismissSystemAlert)で1回だけ**行う —— 呼び出し側3箇所に書くと
    /// どれかが落ちて「押したのに記録が無い」に戻る
    public var onSystemAlertDismissed: (@Sendable (String) -> Void)?
    /// 割り込みハンドラ(アプリ内メッセージ・自前のお知らせダイアログ用)。
    /// **閉じ方はアプリ作者しか知らない**ので、ツールが推測せずプロジェクト側で1回宣言してもらう
    /// (DSL の `irregularHandler`)。detect が現在のスナップショットで解決できたら dismiss をタップし、
    /// 取り直してから本来の操作を続ける。宣言が無ければ何もしない = 正常系のコストはゼロ
    /// (**追加のスナップショットを取らない**。既に手元にあるものへ照合するだけ)
    public struct InterruptHandler: Sendable {
        public let detect: FlowLocator
        public let dismiss: FlowLocator
        /// **1ステップで閉じる上限**(既定 `maxInterruptDismissalsPerStep`)。
        /// 宣言ごとに変えられる —— 湧く頻度は配信側の設定次第で、こちらからは決められない。
        /// 上限そのものを外せないのは、**閉じても消えない相手に無限に付き合わない**ため
        public let maxDismissals: Int
        public init(detect: FlowLocator, dismiss: FlowLocator,
                    maxDismissals: Int = StepExecutor.maxInterruptDismissalsPerStep) {
            self.detect = detect
            self.dismiss = dismiss
            self.maxDismissals = max(1, maxDismissals)
        }
    }

    /// 宣言順に評価する。1ステップにつき**1回だけ**発火する(閉じても消えない相手で無限に回らないため)
    public var interruptHandlers: [InterruptHandler] = []

    /// **自動クローズを止めている入れ子の深さ**(`suppressHandler { }`。Shirates 準拠の名前)。
    /// 0 より大きい間は宣言済みハンドラを閉じない —— **シナリオ自身がそのモーダルを
    /// 検証・操作したいとき**のためのもの(宣言する場所をずらす回避策を書かせない)。
    ///
    /// **止まるのは「こちらが閉じること」だけ**: 割り込みが出ること自体はアプリの都合なので、
    /// 抑止しても「送った操作が吸われる」形は変わらない(責務表は docs/commands.md)
    public var handlerSuppressionDepth = 0

    /// `disableHandler()` で止めているか(`enableHandler()` で戻す)。
    /// **ブロック形と別に持つ理由は CAE**(2026-08-21 ユーザー指摘): `suppressHandler { }` は
    /// **1つの CAE ブロックの内側にしか置けない**ので、`condition` で止めて `expectation` で
    /// 戻す、という書き方ができない。命令形の対だけが**ブロックを跨いで**制御できる
    public var handlersDisabled = false

    /// いま自動クローズを止めているか(ブロック形と命令形の**どちらか**が効いていれば止める)
    public var handlersSuppressed: Bool { handlerSuppressionDepth > 0 || handlersDisabled }

    /// **抑止中に、宣言した割り込みが画面に出ていた**か(そのステップだけの記録)。
    /// 抑止の最大の危険は「抑止したまま忘れる」なので、**失敗したときにだけ**注記へ出す
    /// (成功しているステップには何も足さない = 正常な使い方の出力を増やさない)
    var suppressedInterruptionSeenThisStep = false

    /// スクロール探索の直後に「空打ち」の極小ドラッグを入れるか(**iOS だけ true**)。
    /// iOS(Compose)のスクロール容器は次の1タッチを消費してタップが効かないため必要だが、
    /// **Android では 2pt のドラッグがクリックとして発火してしまう**(タップしていないのに
    /// 行が選択される = 二重実行。2026-07-27 実測)。プラットフォームで分ける唯一の理由
    let releasesScrollTouch: Bool

    /// タップの遮蔽・切り詰め注記の文言分岐にだけ使う。`TapTargetGeometry.advisory` /
    /// `advisoryKind` の判定そのものは変えない —— 判定は1箇所、文言だけが OS で違う。
    /// **既定値を置かない**(呼び忘れをコンパイルで止める。overlayWindows: と同じ規律)
    let isAndroid: Bool

    /// in-app ブリッジの自己申告(/status の uiFramework)、または engine=xcuitest では
    /// `AppBundleInspector` がバンドルのマーカーから判定した値。"compose" / "flutter" / "uikit" / nil(不明)。
    /// **空打ちの発火条件だけに使う**(shouldEmptyDrag)。他の判定には持ち込まない
    let uiFramework: String?

    /// 空打ちを撃ってよいか。releasesScrollTouch(iOS)に加え、uiFramework が判明していれば
    /// Compose/Flutter だけに絞る —— タッチ消費はそれらの自前描画スクロール容器に固有で、
    /// UIKit 系(RN 含む)の容器は消費しない。**RN は逆に空打ちが害になる**: 横抜き4pt の終点が
    /// Pressable の pressRetentionOffset(既定20pt)内に収まり onPress が成立し、`scrollTo` しただけで
    /// 行が選択された(2026-08-08 E2E-RN S0100 実測: `selected=row_40`)。Android がタッチ消費を
    /// 持たず releasesScrollTouch=false で対象外なのと同型の理由。
    /// **nil(不明)は従来どおり打つ**(実機・判定失敗経路で挙動を変えないため)
    var shouldEmptyDrag: Bool {
        releasesScrollTouch && (uiFramework == nil || uiFramework == "compose" || uiFramework == "flutter")
    }

    /// **容器の推測に依存する補正**の既定(実行プロファイルの `containerInference`。既定 true)。
    /// ステップ側の指定(`FlowStep.containerInference`)があればそちらが勝ち、
    /// 環境変数 `FT_CONTAINER_INFERENCE=off` はどちらより上位の殺しスイッチ。
    /// **`execute` の入口でステップへ畳む**ので、下流(解決・探索・タップ)はステップだけ見ればよい
    let containerInference: Bool

    /// **半開きシート内で停滞したら、逆走査(飛び越しの拾い直し)を掛けずに即返す**(既定 false)。
    /// true にしてよいのは「呼び手がシートを展開して再試行する」場合だけ —— 展開後の再試行は
    /// 全画面高の容器で同じ逆走査を持つので救済は落ちない(MCP の ft_scroll_to の1回目が使う。
    /// 実測: 畳まれた Apple マップの経路カードで逆走査 7.8s が丸損だった)。
    /// **DSL には展開する者がいない**ので false のまま = 逆走査が唯一の救済として残る
    let defersPartialSheetRecovery: Bool

    /// 画面が変わり得る操作の直後に呼び、スクショ再利用キャッシュを捨てる(performCustom から呼ぶ)。
    public func invalidateScreenshotCache() { cachedScreenshot = nil }

    /// occlusion-guard 用スクショ。直近(200ms 以内・無効化なし)なら再利用、無ければ取得してキャッシュ。
    /// StepExecutor+Assert.swift の occlusionFlip から呼ばれるため internal。
    /// **freshlyCaptured** = キャッシュ供給ではなく今回 driver.screenshot() を呼んだか。
    /// キャッシュ供給は同一 Data オブジェクトを返すため、StaleFrameDetector の判定に使うと
    /// 「画像同一・木は微変化」で必ず偽 stale になる —— 呼び出し側はこれが false のとき判定しない
    func guardScreenshot(phase: inout PhaseAccumulator) async throws -> (data: Data, freshlyCaptured: Bool) {
        let clock = ContinuousClock()
        if let shot = cachedScreenshot, let at = cachedShotAt, clock.now - at < .milliseconds(200) {
            return (shot, false)
        }
        let start = clock.now
        let shot = try await driver.screenshot()
        phase.actionMs += Self.ms(clock.now - start)
        cachedScreenshot = shot
        cachedShotAt = clock.now
        return (shot, true)
    }

    public init(driver: AppDriver, fallbackDriver: AppDriver? = nil,
                typeDriver: AppDriver? = nil, preferTypeDriver: Bool = false,
                typeDriverGestures: Set<String> = [],
                delegate: ReplayDelegate? = nil, healingEnabled: Bool = false,
                occlusionGuard: Bool = false, occlusionInkThreshold: Double = 12,
                occlusionGuardEnabled: Bool = true, screenLooksLikeEnabled: Bool = true,
                releasesScrollTouch: Bool = false,
                isAndroid: Bool,
                uiFramework: String? = nil,
                containerInference: Bool = true,
                defersPartialSheetRecovery: Bool = false) {
        self.releasesScrollTouch = releasesScrollTouch
        self.isAndroid = isAndroid
        self.uiFramework = uiFramework
        self.containerInference = containerInference
        self.defersPartialSheetRecovery = defersPartialSheetRecovery
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
        self.screenLooksLikeEnabled = screenLooksLikeEnabled
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
        resetInterruptScope()
        suppressedInterruptionSeenThisStep = false
        observedCheckedThisStep = nil
        resolvedElementThisStep = nil
        scrollSwipesThisStep = nil
        noteCodesThisStep = []
        failureKindThisStep = nil
        elementLimitCeilingLatchedThisStep = false
        systemAlertAdvisoryThisStep = nil
        do {
            if let action = step.action {
                let outcome = try await executeAction(action, step: step, cached: cached, phase: &phase)
                // 失敗したなら、登録の無いシステムアラートが前面に無いかを1回だけ聞いて文言に添える
                let status = await annotatedWithSystemAlert(outcome.status, phase: &phase)
                return StepOutcome(status: status, healedStep: outcome.healedStep,
                                   healedByCache: outcome.healedByCache,
                                   timing: StepTiming(durationMs: Self.ms(clock.now - start),
                                                      snapshotMs: phase.snapshotMs,
                                                      actionMs: phase.actionMs, waitMs: phase.waitMs),
                                   driverFallback: noteWithInterrupt(
                                       Self.joinNotes(outcome.driverFallback, systemAlertAdvisoryThisStep),
                                       failed: !Self.isSuccess(status)),
                                   notes: collectedNotes(),
                                   // アクションは**解決した時点**で立てる(操作の成否より前)ため、
                                   // 失敗した操作の要素を持ち帰らないようここで落とす
                                   resolvedElement: Self.isSuccess(outcome.status)
                                       ? resolvedElementThisStep : nil,
                                   scrollSwipes: scrollSwipesThisStep,
                                   failureKind: failureKind(for: outcome.status))
            }
            if let assert = step.assert {
                var status = try await executeAssert(assert, step: step, phase: &phase)
                // **アサートが落ちて素性が立っていなければ「期待と違った」**(定義上そう) ——
                // 見つからない・到達できないは内側で先に立っているので上書きされない
                if case .failed = status { markFailure(.assertion) }
                // 時間切れの原因が前面のシステムアラートなら題名を添える(登録が無いときだけ・1往復)
                status = await annotatedWithSystemAlert(status, phase: &phase)
                return StepOutcome(status: status,
                                   timing: StepTiming(durationMs: Self.ms(clock.now - start),
                                                      snapshotMs: phase.snapshotMs,
                                                      actionMs: phase.actionMs, waitMs: phase.waitMs),
                                   driverFallback: noteWithInterrupt(nil,
                                                                     failed: !Self.isSuccess(status)),
                                   notes: collectedNotes(),
                                   observedChecked: observedCheckedThisStep,
                                   resolvedElement: resolvedElementThisStep,
                                   scrollSwipes: scrollSwipesThisStep,
                                   failureKind: failureKind(for: status))
            }
            return StepOutcome(status: .skipped("step has neither an action nor an assertion"))
        } catch {
            return StepOutcome(status: .failed("execution error: \(error.localizedDescription)"),
                               timing: StepTiming(durationMs: Self.ms(clock.now - start),
                                                  snapshotMs: phase.snapshotMs,
                                                  actionMs: phase.actionMs, waitMs: phase.waitMs),
                               notes: collectedNotes(),
                               scrollSwipes: scrollSwipesThisStep,
                               // 投げられたエラーは**型で**仕分ける(文言一致で数えない)。
                               // 分からない型は nil のまま = 推測しない
                               failureKind: Self.failureKind(thrown: error)
                                   ?? failureKindThisStep)
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
        // one-shot なので、ラッチが立っている間は呼ぶたびに arm し直す(elementLimitCeilingLatchedThisStep の doc)
        if elementLimitCeilingLatchedThisStep {
            driver.raiseElementLimitOnNextSnapshot(BridgeAPI.maxSnapshotElementsCeiling)
        }
        return try await driver.snapshot(bypassingCache: bypassesCache(freshness))
    }

    /// このステップで立った注記。順序を rawValue 固定にするのは、記録が run 間で決定的に
    /// 比較できるようにするため(Set の反復順はプロセスごとに変わる)
    /// **failed のときだけ**素性を載せる。skipped / inconclusive は「落ちた」ではないので
    /// 素性を付けない(付けると読み手の「失敗の内訳」に走っていないステップが混ざる)
    private func failureKind(for status: StepResult.Status) -> StepFailureKind? {
        if case .failed = status { return failureKindThisStep }
        return nil
    }

    /// 投げられたエラーの素性。**エラーの型が名乗るものだけを見る**
    /// (`StepFailureKindProviding`。localizedDescription の文言一致で仕分けると、
    /// 文言を直した瞬間に静かに分類が消える)。名乗らない型は nil = 推測しない
    public static func failureKind(thrown error: Error) -> StepFailureKind? {
        (error as? StepFailureKindProviding)?.stepFailureKind
    }

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
    /// このステップの assert が **SpringBoard 側の木**で解決したか(= シナリオ自身が
    /// システムアラートを検証している)。立っていれば SystemUIGate は緑を取り消さない ——
    /// 取り消すと `exist("許可しない")` のような、アラートを対象にした検証が一切書けなくなる。
    /// **executeAssert が毎ステップ false へ戻す**(立てっぱなしにすると次のステップが素通りする)
    var resolvedViaSystemUIThisStep = false
    /// exist/textIs 等の assert・tap/type/press 等のアクションが**成功時**に実際に照合した要素
    /// (execute が StepOutcome.resolvedElement に載せる)。observedCheckedThisStep と同じ受け渡し形
    /// (StepExecutor+Assert.swift の各 executeAssert* から書くため internal)。失敗時は立てない。
    var resolvedElementThisStep: ElementInfo?
    /// スクロール探索が実際に撃ったスワイプ数(execute が StepOutcome.scrollSwipes に載せる)。
    /// recordedScrollSearchNote(StepExecutor+ScrollSearch.swift)が書く。
    /// resolvedElementThisStep と同じ受け渡し形
    var scrollSwipesThisStep: Int?
    /// このステップで立った機械可読な注記(execute が StepOutcome.notes に載せる)。
    /// アクション/検証のどの return 経路から立てても拾えるようインスタンスで持つ
    /// (scrollSearchNote / observedCheckedThisStep と同じ受け渡し形)。
    /// StepExecutor+Assert.swift からも書くため internal
    var noteCodesThisStep: Set<StepNote> = []
    /// このステップの失敗の素性。**最初に立てたものを残す**(内側の救済経路が後から
    /// 別の理由で落ちても、読み手が知りたいのは最初に何が起きたか)
    var failureKindThisStep: StepFailureKind?

    /// 天井の撮り直しで対象を拾ったステップの**後続読み**も天井にする per-step ラッチ。
    /// 立てるのは StepExecutor+Actions.swift の撮り直し呼び出し箇所だけ(Assert のループは
    /// ループ内 var で完結し、後続読みが無いので立てない)。寿命はステップ
    /// (execute(_:cached:) の入口で false に戻す)。
    /// `AppDriver.raiseElementLimitOnNextSnapshot` は次の1回だけ効く one-shot なので、
    /// 立っている間は `freshSnapshot(_:)` および StepExecutor+Actions.swift の直呼び読みが
    /// **呼ぶたびに** arm し直す。StepExecutor+Actions.swift からも立てるため internal
    var elementLimitCeilingLatchedThisStep = false

    /// 注記の**表示文言と機械可読コードを同時に**足す。片方だけ足すと
    /// 「レポートには出ているのに集計に乗らない(逆も)」が起きるので、必ずこれを通す
    func note(_ code: StepNote, into parts: inout [String]) {
        noteCodesThisStep.insert(code)
        parts.append(code.text)
    }

    /// 失敗の素性を立てる。**上書きしない** = 最初の理由が残る(failureKindThisStep の doc)
    func markFailure(_ kind: StepFailureKind) {
        if failureKindThisStep == nil { failureKindThisStep = kind }
    }

    /// 素性を立てつつ失敗を返す。`return .failed(…)` の形を保ったまま素性だけ足せる
    func failed(_ kind: StepFailureKind, _ message: String) -> StepResult.Status {
        markFailure(kind)
        return .failed(message)
    }

    /// 「掴めた」と言い切れる状態か(StepOutcome.resolvedElement を載せてよいかの判定)。
    /// **public**: MCP(fleetest-mcp)の ft_scroll_to も同じ判定を使う(2つ目の実装を作らない)
    public static func isSuccess(_ status: StepResult.Status) -> Bool {
        switch status {
        case .passed, .passedViaFallback, .healed: return true
        case .failed, .skipped, .inconclusive: return false
        }
    }

    /// このステップで閉じた割り込み(execute が記録の注記に載せる)。
    /// **1ステップにつき1回だけ**発火させるための状態でもある(閉じても消えない相手に対して
    /// アサーションのポーリングごとにタップし続けるのを防ぐ)
    private var interruptNote: String?
    /// このステップで割り込みを閉じた回数(**宣言ごと**。上限は `InterruptHandler.maxDismissals`)
    private var interruptDismissals: [String: Int] = [:]
    /// 注記用の合計(複数の宣言が発動したときも「何回閉じたか」を1つで言う)
    private var interruptDismissalTotal = 0
    /// 直前に閉じた割り込みの detect(閉じた直後にまた一致したかを見る)
    private var lastDismissedInterrupt: String?
    /// 閉じたのに消えない相手を諦めたか(注記に残す)
    private var interruptStuck = false

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
    /// **直前のアクションが tap だったときの対象**(`type`(セレクタ無し)の焦点救済に使う)。
    /// `lastInteraction` は次のアクションの入口で捨てられるので流用できない。
    /// tap 以外のアクションが走ったら捨てる = 「直前」の意味を保つ(`executeAction` の入口)
    var lastTapTarget: ElementInfo?

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

    /// **またぎ解消に必要な最小スクロール量**(+マージン)。またぎ補正に recoveryJump
    /// (容器の 40% 位置へ寄せる)を使うと寄せ過ぎる —— 2026-08-08 実害: SwiftUI の素の
    /// scrollView が木に出るようになった(版58)ことで補正がネイティブ画面でも発火し、
    /// 約330px の寄せが観測対象の echo ラベルまで仮想化の外へ流して、タップは成立したのに
    /// アサーションが要素を見失った(E2E-iOS の3シナリオが決定的に失敗)。
    /// 60 の床上げは dragGesture の実行下限(距離 50 超)を割らないため —— 割ると
    /// overflow の小さいまたぎ(Compose の実測は中心が縁から 2〜12px 外)で寄せ自体が不発になる
    static func straddleJump(for element: ElementInfo, container: FTRect) -> Double? {
        let margin = 12.0
        let bottomOverflow = (element.frame.y + element.frame.height)
            - (container.y + container.height) + margin
        let topOverflow = container.y - element.frame.y + margin
        if bottomOverflow > margin { return max(bottomOverflow, 60) }
        if topOverflow > margin { return -max(topOverflow, 60) }
        return nil
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
                               inferring: Bool = containerInferenceEnabled,
                               scale: Double = 1) -> FTRect? {
        // **床は木の単位へ換算してから比べる**(scale = AppDriver.pointScale。iOS=1・Android=密度)。
        // 換算しないと 3倍密度で床が約3倍緩くなり、この guard が防ぐはずの誤タップが素通りする
        let floor = Self.minimumVisibleTapExtent * scale
        guard let container = clippingContainer(of: element, in: elements, inferring: inferring),
              let visible = ScrollGeometry.intersection(element.frame, container),
              // **細すぎる帯は撃たない**。容器の推測が外れていた場合、わずかな重なりを
              // 「見えている部分」と信じて叩くと**より悪い場所**へ当たる。実測の対象は
              // 10pt 以上見えていた(容器 230 に対し 240〜244)ので、この床で取りこぼさない
              visible.height >= floor,
              visible.width >= floor else { return nil }
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

    /// 「見えている部分」を撃つと言えるだけの最小の幅・高さ。**単位は pt/dp**(物理では約 1.25mm。
    /// iOS の pt = 1/163 inch と Android の dp = 1/160 inch はほぼ同じ大きさなので同じ数で足りる)。
    /// 容器の推測が外れたときに、わずかな重なりへ突っ込まないための床。
    /// **木の単位へは呼び手が換算する**(`visibleTapRect(scale:)` = `AppDriver.pointScale`)——
    /// Android の木は px なので、そのまま比べると密度ぶん床が緩む
    static let minimumVisibleTapExtent: Double = 8

    /// 飲まれたタップの証跡を採る(LastInteraction 参照)。**追加のスナップショットは撮らない** ——
    /// 解決に使った木をそのまま基準にする。前面要素の判定も同じ木の上の計算だけ
    func recordInteraction(step: FlowStep, element: ElementInfo, in snapshot: SnapshotResponse) {
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
                // 名指しであって貼れるセレクタの保証はしない(TapTargetGeometry.describe と同じ判断。
                // 2026-08-15。エスケープ未対応)
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

    /// ステップ横断の注記(内蔵スクロール探索・割り込み)を既存の driverFallback へ合流させる。
    /// `failed` のときは**読み手が原因に辿り着けるように**割り込みの意味を書き足す
    private func noteWithInterrupt(_ base: String?, failed: Bool = false) -> String? {
        var parts = [base, scrollSearchNote].compactMap { $0 }
        if let interruptNote {
            let times = interruptDismissalTotal > 1 ? " ×\(interruptDismissalTotal)" : ""
            parts.append("dismissed the interruption \(interruptNote)\(times)")
        }
        if interruptStuck {
            parts.append("the interruption is still on screen after being dismissed"
                + " — the dismiss selector may not close it")
        }
        // **閉じたのに落ちた**ときは、割り込みが「出ていた」ことより「**直前の操作を吸った
        // かもしれない**」ことの方が読み手に要る情報(2026-08-20 の受け手報告)。
        // 撃ち直しはしない —— 既に届いていた場合に二重実行になる(報告者の指摘どおり)
        // **抑止したまま忘れた**ときに気付けるようにする。出ていたのに閉じなかったのは
        // 宣言どおりの動作なので、**落ちたときにだけ**言う(成功していれば意図どおり)
        if failed, suppressedInterruptionSeenThisStep {
            // **どちらの止め方かは書かない**(suppressHandler / disableHandler の両方があり、
            // 実行器はどちらで止まっているかを区別しても読み手の役に立たない)
            parts.append("a declared interruption was on screen but automatic closing is"
                + " suppressed here — close it in the scenario, or narrow the suppressed range")
        }
        if failed, interruptDismissalTotal > 0 {
            parts.append("the interruption appeared during this step"
                + " — an interaction sent just before it may have been swallowed by it"
                + " (nothing was re-sent: repeating it could double-fire)")
        }
        return parts.isEmpty ? nil : parts.joined(separator: " / ")
    }

    /// 1ステップで割り込みを閉じる上限の**既定値**(宣言ごとに `maxDismissals` で変えられる)。
    /// **1回きりでは足りない**(2026-08-20 の受け手要望): 長いステップの最中に2度目の配信が
    /// 湧くと、閉じ切れないまま待ち続ける。
    ///
    /// 上限を残すのは**閉じても消えない相手に無限に付き合わない**ためだが、
    /// **その役目はもう「閉じたのに残っている」の打ち切りが担っている**(2回で見切る)。
    /// ここは「湧く回数」の上限でしかないので、**素直に湧く相手を取りこぼさない側へ寄せて 10**
    /// (2026-08-20 ユーザー指定)。尽きたときは注記に残るので、黙って待ち続けることはない
    public static let maxInterruptDismissalsPerStep = 10

    /// 宣言された割り込み(アプリ内メッセージ等)が現在の画面に出ていれば閉じる。
    /// **アクションでも検証でも**呼ぶ(割り込みは待機中にこそ出るため、アクション側だけだと
    /// `exist`/`textIs` の待ち中に出たものを閉じられない)。
    /// **1ステップで最大 `maxInterruptDismissalsPerStep` 回まで**閉じる。
    /// スナップショットは呼び手が持っているものを使い、閉じた後だけ取り直す
    /// (**追加のスナップショットを取らない** = 宣言が無ければコストゼロ)
    /// StepExecutor+Assert.swift の executeAssert 系すべてから呼ぶため internal。
    func dismissInterruption(in snapshot: inout SnapshotResponse,
                             phase: inout PhaseAccumulator) async throws {
        guard !interruptHandlers.isEmpty else { return }
        // 抑止中は閉じない。ただし**出ていた事実は覚える**(失敗したときだけ注記に出す)
        guard !handlersSuppressed else {
            if interruptHandlers.contains(where: { Self.match($0.detect, in: snapshot) != nil }) {
                suppressedInterruptionSeenThisStep = true
            }
            return
        }
        let clock = ContinuousClock()
        for handler in interruptHandlers {
            let key = handler.detect.summary
            guard (interruptDismissals[key] ?? 0) < handler.maxDismissals else { continue }
            guard Self.match(handler.detect, in: snapshot) != nil,
                  let target = Self.match(handler.dismiss, in: snapshot) else { continue }
            let start = clock.now
            try await driver.tap(ref: target.ref)
            phase.actionMs += Self.ms(clock.now - start)
            // **整定してから取り直す**(2026-08-20 の受け手報告)。閉じた直後の1枚は
            // **消えるアニメーションの最中**のことがあり、そのとき背面はまだ覆われている扱い =
            // 「同じステップの中で割り込みを閉じたのに、直後の解決が失敗する」が起きる。
            // 追加コストは**閉じたときだけ**(宣言が無ければ従来どおりゼロ)
            let settled = try await settledSignature(phase: &phase)
            snapshot = settled.snapshot
            interruptNote = key
            // 文言は動的なのでコードだけ立てる(StepNote.interruptionDismissed の doc)
            noteCodesThisStep.insert(.interruptionDismissed)
            interruptDismissals[key, default: 0] += 1
            interruptDismissalTotal += 1
            // **閉じた直後にまだ居る = 閉じられていない**。同じ相手に上限まで付き合わず、
            // その場で打ち切って注記に残す(dismiss セレクタが効いていない疑い)。
            // **1回目では切らない** —— 閉じるアニメーションの最中に撮った木で早合点しないため
            if Self.match(handler.detect, in: snapshot) != nil, lastDismissedInterrupt == key {
                interruptStuck = true
                interruptDismissals[key] = handler.maxDismissals
            }
            lastDismissedInterrupt = key
            return
        }
    }


    /// 割り込みの数え直し(1ステップ = 1スコープ)。`execute` と、`perform` を通らない
    /// 条件判定の入口(`beginInterruptionScope`)が共有する
    private func resetInterruptScope() {
        interruptNote = nil
        interruptDismissals = [:]
        interruptDismissalTotal = 0
        lastDismissedInterrupt = nil
        interruptStuck = false
    }

    /// `perform` を通らない条件判定(`ifCanSelect` / `repeatWhileCanSelect`)が
    /// **判定1回を1ステップとして**扱うための起点。呼ばないと直前のステップの回数を引き継ぎ、
    /// 上限に達していると1回も閉じられない
    public func beginInterruptionScope() { resetInterruptScope() }

    /// 閉じた割り込みと、閉じた**後**の画面。閉じていなければ nil
    public struct InterruptDismissal: Sendable {
        /// 検出セレクタの要約(ステップの注記に出す文言と同じもの)
        public let key: String
        /// このスコープで閉じた回数(注記の ×N)
        public let count: Int
        /// 整定を待って撮り直した木
        public let snapshot: SnapshotResponse
    }

    /// 宣言された割り込みが写っていれば閉じて、整定後の木を返す(`dismissInterruption` と同じ実装)。
    /// **条件判定から使う** —— 覆いを閉じずに不成立を確定すると、分岐が黙って飛ぶ
    /// (2026-08-20 の受け手報告。失敗ではなく**誤った経路**として現れるので気付けない)。
    /// 宣言が無ければ何もしない = コストゼロ
    public func dismissDeclaredInterruption(in snapshot: SnapshotResponse) async -> InterruptDismissal? {
        guard !interruptHandlers.isEmpty else { return nil }
        var current = snapshot
        var phase = PhaseAccumulator()
        let before = interruptDismissalTotal
        try? await dismissInterruption(in: &current, phase: &phase)
        guard interruptDismissalTotal > before, let key = lastDismissedInterrupt else { return nil }
        return InterruptDismissal(key: key, count: interruptDismissalTotal, snapshot: current)
    }

    /// scrollFrame の空振り申告(ステップの注記へ載せる)。**「1ステップ1回」は nil 判定だけで
    /// 表現できる**(2026-08-08: 別に立てていた `reportedScrollFrameNote` フラグは、唯一の代入元が
    /// 常に `pendingScrollFrameNote != nil` と同値になり、ガード条件として無力だった)
    var pendingScrollFrameNote: String?

    /// 探索スワイプの刻み倍率(自己補正)。**1回の移動量が容器を超えると要素を飛び越す**ので、
    /// 実移動量を毎周測って詰める。較正表は持たない(端末・SUT を跨ぐと再現しないため。
    /// docs/performance-tuning.md §3.16 / §3.18)。ステップごとに 1.0 へ戻す。
    /// **読むのは `scrollPath` の1箇所だけ** = `scrollFrame` を書いた経路でしか効かない
    var spanScale: Double = 1
}
