// DSL のプロセスグローバル実行状態。ftester-scenarios は 1 プロセス = 1 シナリオ実行なので
// カレントコンテキストは 1 個でよい。シナリオ本体は専用スレッド上で同期実行され、
// コマンドはこのスレッド以外から呼べない(Task 内等からの誤用は明示エラー)。

import Foundation
import FTCore

// MARK: - 実行記録

public struct DSLStepRecord: Sendable {
    public let index: Int
    /// condition / action / expectation(CAE ブロック外は nil)
    public let section: String?
    public let description: String
    public let status: StepResult.Status
    public let file: String
    public let line: Int
    /// レポートの時間列に使う。欠測条件は recordStep のコメント参照
    public let durationMs: Int?
}

/// セレクタの修正提案(自己修復・キャッシュ命中・フォールバック通過から導出)
public struct FixSuggestion: Sendable {
    /// 強い提案(healed)か弱い提案(passedViaFallback)か
    public let isStrong: Bool
    public let message: String
}

public struct SceneRecordData: Sendable {
    public let number: Int
    public let title: String
    public var steps: [DSLStepRecord] = []
    public var triage: TriageInfo?
    public var failureScreenshot: Data?
    /// 失敗時証跡スクショが白フレーム(画面凍結)でエビデンス無効。ScenarioReportWriter が警告表示する。
    public var evidenceBlank: Bool = false
    /// 失敗時点の要素一覧(SnapshotRenderer の1要素1行テキスト)。スクリーンショットからは
    /// `#id` を読み取れないため、直すための情報はこちらが本体(レポートに折りたたみで載せる)
    public var failureElements: String?
    /// 失敗時にアプリより手前にあった**別プロセスの window**(手前が先)。
    /// これが空でないなら「操作がそこに吸われて ✅ のまま何も起きなかった」を第一に疑う
    /// (アプリの a11y ツリーには他プロセスの window が出ないため、要素一覧では気付けない)
    public var failureForegroundWindows: [String] = []

    public var passed: Bool {
        steps.allSatisfy {
            if case .failed = $0.status { return false }
            return true
        }
    }
}

public struct ScenarioRecordData: Sendable {
    public let id: String
    public let title: String
    public let app: String
    public let platform: String
    /// 実行プロファイル上のデバイス論理名(profiles/machines/ の name)。orchestrator 経由でない
    /// 実行(--ports 直指定等)では取得できず nil
    public let deviceName: String?
    /// 技術識別子(Android: adb serial / iOS: シミュレータ UDID)。取得できなければ nil
    public let deviceIdentifier: String?
    public var scenes: [SceneRecordData] = []
    public var fixSuggestions: [FixSuggestion] = []

    public init(id: String, title: String, app: String, platform: String,
                deviceName: String? = nil, deviceIdentifier: String? = nil,
                scenes: [SceneRecordData] = [], fixSuggestions: [FixSuggestion] = []) {
        self.id = id
        self.title = title
        self.app = app
        self.platform = platform
        self.deviceName = deviceName
        self.deviceIdentifier = deviceIdentifier
        self.scenes = scenes
        self.fixSuggestions = fixSuggestions
    }

    public var passed: Bool { scenes.allSatisfy(\.passed) }
}

// MARK: - ランタイム

public final class FTRuntime {
    public static let shared = FTRuntime()

    /// core / dslThread を守る。**DSL スレッド以外からも読まれる**(誤って別スレッドから呼ばれた
    /// DSL コマンド)ので、tearDown の書き込みと競らせない — 素の Optional への同時読み書きは
    /// 実際に落ち得る(ThreadSanitizer で検出済み)。
    /// **FTDriveCore.stateLock より先に取り、握ったまま core を呼ばない**(ロック順序を一方向に保つ)
    private let lock = NSLock()
    private var core: FTDriveCore?
    private var dslThread: Thread?

    /// ランナーがシナリオ実行前に呼ぶ
    public static func bootstrap(core: FTDriveCore, dslThread: Thread) {
        shared.lock.lock()
        defer { shared.lock.unlock() }
        shared.core = core
        shared.dslThread = dslThread
    }

    public static func tearDown() {
        shared.lock.lock()
        defer { shared.lock.unlock() }
        shared.core = nil
        shared.dslThread = nil
    }

    private var current: (core: FTDriveCore?, thread: Thread?) {
        lock.lock()
        defer { lock.unlock() }
        return (core, dslThread)
    }

    /// コマンド実装から呼ぶ。core 未初期化は fatalError のままにする(記録先そのものが無く
    /// レポートを残す手段が無いため、ここだけは違反を握りつぶさず落とす)。
    /// DSL スレッド外からの呼び出しは fatalError にせず、core に1回だけ失敗ステップを記録させて
    /// シナリオを中断する(1プロセス=1シナリオなので、ここで落とすとレポートごと消えるため)
    static func requireCore(command: String) -> FTDriveCore {
        let (core, thread) = shared.current   // lock は抜けてから core を触る(ロック順序)
        guard let core else {
            fatalError("FTDSL: \(command) was called outside a scenario run"
                + " (it can only be called during a scenario run via ftester-scenarios run)")
        }
        if let thread, Thread.current !== thread {
            core.recordThreadViolation(command: command)
        }
        return core
    }
}

/// perform() の内部戻り値。status は既存呼び出し元がそのまま使い、element は exist 系
/// (FTElement.text/value/id)だけが読む
struct PerformResult {
    let status: StepResult.Status
    let element: ElementInfo?
}

// MARK: - ドライブコア(コマンドの実体)

public final class FTDriveCore {
    let driver: AppDriver
    /// home / appSwitcher 用のドライバ。**in-app エンジンは自プロセス外を触れないので原理的に
    /// 実行できない**(501)。hybrid では 501 の往復を作らず最初から XCUITest 側へ直行する
    /// (XCUITest ブリッジの /home・/appswitcher はセッション不要)。
    /// hybrid 以外(xcuitest / Android / inapp 単独)は primary のまま = 挙動不変
    var systemDriver: AppDriver { executor.typeDriver ?? driver }
    public let platform: String
    /// 実機か。白フレーム=画面凍結の推定はエミュレータ固有の病理(GPU 合成バッファ固着)なので、
    /// 実機では「画面が消灯しているだけ」を凍結と誤断しないためにこれで抑止する
    public let physical: Bool
    let appBundleID: String
    let executor: StepExecutor
    let scenarioID: String
    let scenarioTitle: String
    let emit: (ScenarioEvent) -> Void
    let healCache: HealCache
    /// 検証コマンド(exist/textIs 等)の既定タイムアウト秒(実行プロファイルで変更可)
    public let defaultTimeout: Double

    private(set) var record: ScenarioRecordData

    /// **`record`(シナリオ結果)と `scenarioAborted` / `deviceFrozen` の全アクセスを直列化する**。
    /// DSL スレッド以外からも触られる: ①誤って別スレッドから呼ばれた DSL コマンド
    /// (FTRuntime.requireCore のスレッド違反検知)②`executor.onDeviceFrozen` コールバック
    /// (FTSync の detached Task 上で走る)。`record.scenes` の append と
    /// `record.scenes[last]` への代入が競ると配列が壊れ、**レポートを残すどころかプロセスが落ちる**。
    /// **再帰ロック**にしてあるのは、ロック下の処理が `scenarioAborted`(同じロックを取る)を
    /// 触るため(markDeviceFrozen)。他の実行状態(groupStack/scrollContextStack 等)は
    /// DSL スレッド専有が前提でロック不要
    private let stateLock = NSRecursiveLock()

    /// record / 中断フラグを触る処理はすべてこれで包む(上記 stateLock の契約)
    private func withState<T>(_ body: () -> T) -> T {
        stateLock.lock()
        defer { stateLock.unlock() }
        return body()
    }

    // 実行状態(DSL スレッドからのみ触る。scenarioAborted は例外 = stateLock 経由)
    var currentSection: String?
    /// group("名前") { } の入れ子。記録時にステップ説明へ `[外/内]` を前置する
    var groupStack: [String] = []
    private var _scenarioAborted = false
    var scenarioAborted: Bool {
        get { stateLock.lock(); defer { stateLock.unlock() }; return _scenarioAborted }
        set { stateLock.lock(); defer { stateLock.unlock() }; _scenarioAborted = newValue }
    }
    /// スレッド違反の記録は 1 run につき 1 回だけ(stateLock 経由。recordThreadViolation 参照)
    private var threadViolationRecorded = false
    var stepCounter = 0
    /// シナリオ中に **1 度でも解決できた** `#id`。否定アサーション(notExist / countIs 0 /
    /// ifCanSelect)だけで使われ、かつ最後まで一度も解決できなかった id は typo の可能性が高い
    /// (構文検証では捕まらない。「そんな id は無い」= 否定は常に成功するため)
    var resolvedIDs: Set<String> = []
    /// 否定側でしか使われていない `#id` → 最初に見た説明(警告メッセージ用)
    var negativeOnlyIDs: [String: String] = [:]
    /// ifCanSelect のセレクタ → 一度でも成立したか。**一度も成立しなかったものだけ**警告する
    /// (交互に出るダイアログのように「出ないこともある」のが正しい用途があるため)
    var branchOutcomes: [String: Bool] = [:]
    /// `isNotChecked` で通ったセレクタ → 最初に見た説明。**checked を一度も観測できなかったもの**は
    /// 「状態を持たない要素を指していて、何を書いても通っていた」疑いがある(ブリッジは
    /// checked を true のときだけ送るため、オフと未対応が区別できない)。
    /// iOS の SwiftUI / Flutter の checkbox は selected trait を出さない = 常に通る(design.md)
    var notCheckedOnlySelectors: [String: String] = [:]
    /// checked を実際に観測できたセレクタ(観測できたなら状態を持つ要素だと分かる)
    var checkedObservedSelectors: Set<String> = []

    /// `withScrollDown { }` 等が積む既定のスクロール向き(Shirates の CodeExecutionContext.scrollDirection 相当)。
    /// 各コマンドの `scroll:` が明示されていればそちらが勝つ。`.none` は withoutScroll { } の明示的な打ち消し
    enum ScrollContext { case none, direction(FTScrollDirection) }
    var scrollContextStack: [ScrollContext] = []

    /// コマンドが使うスクロール向き。明示 > ブロックの文脈 > 無し
    func effectiveScroll(_ explicit: FTScrollDirection?) -> FTScrollDirection? {
        if let explicit { return explicit }
        switch scrollContextStack.last {
        case .direction(let d): return d
        case .none?, nil: return nil
        }
    }

    func runWithScrollContext(_ context: ScrollContext, _ body: () -> Void) {
        scrollContextStack.append(context)
        body()
        scrollContextStack.removeLast()
    }

    /// true = デバイスに触れず全コマンドを記録のみで通過させる(ステップ列挙・コード生成の検証用)
    let dryRun: Bool

    /// --debug 時のブレークポイント/一時停止制御。nil なら通常実行(dry-run でも有効)
    public var debugControl: ScenarioDebugControl?
    /// DSL の `irregularHandler` が宣言した割り込み(アプリ内メッセージ)を実行器へ渡す
    func addInterruptHandler(detect: FlowLocator, dismiss: FlowLocator) {
        executor.interruptHandlers.append(
            StepExecutor.InterruptHandler(detect: detect, dismiss: dismiss))
    }

    /// 失敗時に「アプリより手前にある別プロセスの window」を問い合わせる(Android のみ設定される)。
    /// adb を叩くので FTAndroid を見られる FTScenarioRunner が注入する(FTDSL は FTAndroid に依存しない)
    public var foregroundOverlays: (@Sendable () -> [String])?
    /// stop コマンドで中断した場合 true。expectation 未到達なので成功扱いにしない
    public private(set) var stoppedByUser = false
    /// スクショ時に画面凍結を検知して中断した場合 true。別デバイス再実行対象
    public private(set) var deviceFrozen = false

    public init(driver: AppDriver, platform: String, app: String,
                scenarioID: String, scenarioTitle: String,
                delegate: ReplayDelegate?, healingEnabled: Bool,
                falsePositiveCheckEnabled: Bool = true, screenIsEnabled: Bool = true,
                dryRun: Bool = false,
                healCacheURL: URL? = nil,
                defaultTimeout: Double? = nil,
                fallbackDriver: AppDriver? = nil,
                typeDriver: AppDriver? = nil,
                preferTypeDriver: Bool = false,
                typeDriverGestures: Set<String> = [],
                deviceName: String? = nil,
                deviceIdentifier: String? = nil,
                physical: Bool = false,
                emit: @escaping (ScenarioEvent) -> Void) {
        self.driver = driver
        self.platform = platform
        self.physical = physical
        self.appBundleID = app
        self.executor = StepExecutor(driver: driver, fallbackDriver: fallbackDriver,
                                     typeDriver: typeDriver, preferTypeDriver: preferTypeDriver,
                                     typeDriverGestures: typeDriverGestures,
                                     delegate: delegate, healingEnabled: healingEnabled,
                                     occlusionGuardEnabled: falsePositiveCheckEnabled,
                                     screenIsEnabled: screenIsEnabled,
                                     releasesScrollTouch: platform == "ios")
        self.scenarioID = scenarioID
        self.scenarioTitle = scenarioTitle
        self.dryRun = dryRun
        self.healCache = HealCache(
            url: healCacheURL ?? URL(fileURLWithPath: ".ftester/heal-cache.json"))
        self.defaultTimeout = defaultTimeout ?? 5
        self.emit = emit
        self.record = ScenarioRecordData(id: scenarioID, title: scenarioTitle,
                                         app: app, platform: platform,
                                         deviceName: deviceName, deviceIdentifier: deviceIdentifier)
        self.executor.onDeviceFrozen = { [weak self] in self?.markDeviceFrozen() }
    }

    /// ランナーがシナリオ終了後に読む。**違反スレッドがまだ記録している可能性がある**ので
    /// stateLock 経由で値をコピーして返す(stateLock の契約参照)
    public var finalRecord: ScenarioRecordData { withState { record } }

    // MARK: - scene / CAE ブロック

    func runScene(_ number: Int, _ title: String, _ body: () -> Void) {
        currentSection = nil
        // scene 番号は利用者が手で振るのでコピペで重複しやすい。重複するとレポートに
        // 同じ番号が並び、どちらの結果か読み手が判別できなくなる。**警告に留める**
        // (失敗にはしない = 既存シナリオを止めない。番号は実行順にも結果にも影響しない)
        if withState({ record.scenes.contains(where: { $0.number == number }) }) {
            emit(.log("⚠️ scene \(number) is duplicated (\"\(title)\"). "
                      + "The report will show the same number twice and the results cannot be told apart"))
            addSuggestion(FixSuggestion(
                isStrong: false,
                message: "scene \(number) is duplicated (\"\(title)\"). Renumber the scenes"),
                emitEvent: false, file: "", line: 0)
        }
        withState { record.scenes.append(SceneRecordData(number: number, title: title)) }

        var event = ScenarioEvent(kind: "sceneStarted")
        event.scenario = scenarioID
        event.scene = number
        event.sceneTitle = title
        emit(event)

        if scenarioAborted {
            recordStep(description: "skipped the body of scene \(number)",
                       status: .skipped("not run because the scenario was aborted"), file: "", line: 0)
        } else {
            body()
        }

        currentSection = nil
        let passed = withState { record.scenes.last?.passed ?? false }
        var finished = ScenarioEvent(kind: "sceneFinished")
        finished.scenario = scenarioID
        finished.scene = number
        finished.sceneTitle = title
        finished.passed = passed
        emit(finished)
    }

    func runSection(_ name: String, _ body: () -> Void) {
        let previous = currentSection
        currentSection = name
        body()
        currentSection = previous
    }

    /// 名前付きの共通ステップ(group)。記録上の見え方だけを変え、実行・失敗セマンティクスは素の列と同じ
    func runGroup(_ title: String, _ body: () -> Void) {
        groupStack.append(title)
        body()
        groupStack.removeLast()
    }

    /// setUp / tearDown の実行。
    /// allowAfterFailure=false(setUp): 中で失敗したら本体と同じくシナリオ中断(handleFailure)。
    /// allowAfterFailure=true(tearDown): 中断中でも片付けが走るよう一度フラグを解除し、
    ///   実行後に「元の中断」と「片付け中の失敗」の OR で復元する(どちらも握りつぶさない)。
    /// 画面凍結(deviceFrozen)とユーザー中断(debug の stop)では両方とも実行しない —
    /// 前者は別デバイスで振り直すので死んだデバイスへの操作が無駄、後者は「止めた」のに
    /// 片付けで再びブレークポイントに掛かるのが不合理なため。
    func runLifecycle(_ name: String, allowAfterFailure: Bool, _ body: () -> Void) {
        guard !deviceFrozen, !stoppedByUser else { return }
        let previousSection = currentSection
        let savedScenarioAborted = scenarioAborted
        currentSection = name
        if allowAfterFailure {
            scenarioAborted = false
        }
        body()
        if allowAfterFailure {
            scenarioAborted = savedScenarioAborted || scenarioAborted
        }
        currentSection = previousSection
    }

    // MARK: - ステップ実行

    /// コマンドの共通実行経路。selectorText はヒールキャッシュのキーと修正提案の表示に使う。
    /// 戻り値は status に加え**照合済み要素**も運ぶ(FTElement.text/value/id の元。
    /// exist 系の呼び出し元だけが element を読み、他は捨てる)
    @discardableResult
    /// validateSelector: false = 型付きセレクタ(Sel)由来なので構文検証を飛ばす(FTSelector.structured)
    func perform(step: FlowStep, description: String, selectorText: String? = nil,
                 validateSelector: Bool = true,
                 file: StaticString, line: UInt) -> PerformResult {
        let filePath = relativePath("\(file)")
        debugCheckpoint(description: description, file: filePath, line: Int(line))
        if scenarioAborted {
            let status = StepResult.Status.skipped(skipReason)
            recordStep(description: description, status: status, file: filePath, line: Int(line))
            return PerformResult(status: status, element: nil)
        }
        // 構文検証はデバイスに触る前(dry-run でも)に行う。パースは失敗しない契約のため、
        // `:rigth(x)` のような誤りは「そんなラベルは無い」に化け、notExist/countIs(x,0) では
        // 緑になってしまう。ここで落とすのが唯一の防波堤(FTSelector.validationError 参照)
        if validateSelector, let selectorText, let error = FTSelector.validationError(selectorText) {
            let status = StepResult.Status.failed("invalid selector syntax: \(error)")
            recordStep(description: description, status: status, file: filePath, line: Int(line))
            handleFailure(stepDescription: description, reason: "invalid selector syntax: \(error)")
            return PerformResult(status: status, element: nil)
        }
        if dryRun {
            // 実機に触れず計測はほぼ 0ms だが、NDJSON 配線を検証できるよう durationMs は必ず付与する
            let clock = ContinuousClock()
            let start = clock.now
            recordStep(description: description, status: .passed, file: filePath, line: Int(line),
                       durationMs: continuousClockMilliseconds(clock.now - start))
            return PerformResult(status: .passed, element: nil)
        }

        // 解決順: プライマリ → フォールバック → キャッシュ → FM ヒール(StepExecutor 内)
        var cacheKey: String?
        var cachedEntry: HealCache.Entry?
        if let selectorText {
            let key = HealCache.key(scenarioID: scenarioID, file: filePath,
                                    line: Int(line), selector: selectorText)
            cacheKey = key
            cachedEntry = healCache.lookup(key)
        }

        let executor = self.executor
        let cachedLocators = cachedEntry?.locators ?? []
        let outcome = FTSync.run { await executor.execute(step, cached: cachedLocators) }
        let status = outcome?.status
            ?? .failed("the command timed out (\(Int(FTSync.commandTimeout))s)")
        // driverFallback はロケータの .passedViaFallback とは別物(セレクタは正しくドライバが
        // 変わっただけ、または無言 no-op になり得る経路の注記)。修正提案は出さず、説明文に
        // 括弧書きで付けるだけ。値は表示済み文言(StepExecutor.StepOutcome.driverFallback 参照)。
        let recordedDescription: String
        if let driverFallback = outcome?.driverFallback {
            recordedDescription = "\(description)(\(driverFallback))"
        } else {
            recordedDescription = description
        }
        recordStep(description: recordedDescription, status: status, file: filePath, line: Int(line),
                   durationMs: outcome?.timing?.durationMs,
                   snapshotMs: outcome?.timing?.snapshotMs,
                   actionMs: outcome?.timing?.actionMs,
                   waitMs: outcome?.timing?.waitMs,
                   at: outcome?.at)

        // 修正提案とヒールキャッシュの更新
        if let outcome, let selectorText {
            if let healed = outcome.healedStep, let primary = healed.locator {
                let chain = [primary] + (healed.fallbacks ?? [])
                let newSelector = FTSelector.serialize(primary: primary,
                                                       fallbacks: healed.fallbacks ?? [])
                let rationale: String
                if outcome.healedByCache {
                    rationale = cachedEntry?.rationale ?? "previous self-heal result (cache)"
                } else {
                    rationale = healed.note?.components(separatedBy: "self-healed: ").last
                        ?? "FM self-heal"
                    if let cacheKey {
                        healCache.store(cacheKey, locators: chain,
                                        newSelector: newSelector, rationale: rationale)
                    }
                }
                let via = outcome.healedByCache ? "passed via the heal cache" : "passed via FM self-healing"
                let resolvedNewSelector = cachedEntry?.newSelector ?? newSelector
                addSuggestion(FixSuggestion(
                    isStrong: true,
                    message: "\(filePath):\(line) — change the selector \"\(selectorText)\" to "
                        + "\"\(resolvedNewSelector)\""
                        + " (\(via); reason: \(rationale))"),
                    emitEvent: true, description: description,
                    file: filePath, line: Int(line),
                    oldSelector: selectorText, newSelector: resolvedNewSelector)
            } else if case .passedViaFallback(let locator) = status {
                // 弱い提案(フォールバックは設計上の通常経路なのでレポートのみ)
                addSuggestion(FixSuggestion(
                    isStrong: false,
                    message: "\(filePath):\(line) — \"\(selectorText)\" did not resolve as the primary and "
                        + "passed via the fallback \(locator.summary) (consider updating the selector)"),
                    emitEvent: false, file: filePath, line: Int(line))
            }
        }

        trackIDResolution(step: step, status: status, description: description)
        trackCheckedObservation(step: step, status: status, outcome: outcome,
                                selectorText: selectorText, description: description)

        if case .failed(let reason) = status {
            handleFailure(stepDescription: description, reason: reason)
        }
        return PerformResult(status: status, element: outcome?.resolvedElement)
    }

    /// `#id` が「解決できた」のか「否定側でしか使われていない」のかを覚える。
    /// notExist / countIs 0 は要素が**無い**ことで成功するので、解決の証拠にはならない
    private func trackIDResolution(step: FlowStep, status: StepResult.Status, description: String) {
        // スコープ付き(`#容器 >> #id`)の否定は「容器の外にあること」の検証であり、
        // id が実在しても解決しない。typo 検出の対象から外す(誤検知になるため)
        let locators = ([step.locator] + (step.fallbacks ?? [])).compactMap { $0 }
        let ids = locators.filter { $0.scope?.isEmpty ?? true }.compactMap { $0.id }
        guard !ids.isEmpty else { return }
        let isNegative = step.assert == "notExists"
            || (step.assert == "count" && step.expectedCount == 0)
        let succeeded: Bool
        switch status {
        case .passed, .passedViaFallback, .healed: succeeded = true
        case .failed, .skipped: succeeded = false
        }
        for id in ids {
            if succeeded, !isNegative {
                resolvedIDs.insert(id)
                negativeOnlyIDs[id] = nil
            } else if isNegative, negativeOnlyIDs[id] == nil, !resolvedIDs.contains(id) {
                negativeOnlyIDs[id] = description
            }
        }
    }

    /// `isNotChecked` が「状態を持たない要素」を指していないかを覚える。
    /// notExist の id typo と同じ構造の穴(**何を指しても成功する**)なので、同じく run 終了時に警告する
    private func trackCheckedObservation(step: FlowStep, status: StepResult.Status,
                                         outcome: StepOutcome?, selectorText: String?,
                                         description: String) {
        guard let assert = step.assert, assert == "checked" || assert == "notChecked",
              let key = selectorText else { return }
        if outcome?.observedChecked == true {
            checkedObservedSelectors.insert(key)
            notCheckedOnlySelectors[key] = nil
            return
        }
        guard assert == "notChecked", !checkedObservedSelectors.contains(key) else { return }
        switch status {
        case .passed, .passedViaFallback, .healed:
            if notCheckedOnlySelectors[key] == nil { notCheckedOnlySelectors[key] = description }
        case .failed, .skipped:
            break
        }
    }

    /// dry-run 判定(repeatWhileCanSelect が空回りしないよう1周で切るために参照する)
    public var isDryRun: Bool { dryRun }

    /// ifCanSelect の成否を記録する(Commands.swift から呼ぶ)。同じセレクタが
    /// 一度でも成立していれば警告しない = 「出ることも出ないこともある」正しい用途を潰さない
    func noteBranchOutcome(selector: String, met: Bool) {
        branchOutcomes[selector] = (branchOutcomes[selector] ?? false) || met
    }

    /// 否定側でしか現れず、一度も解決できなかった `#id` を弱い提案として残す。
    /// シナリオ終了時に1回だけ呼ぶ(ftRunTearDown 後)
    public func warnAboutNeverResolvedIDs() {
        for (id, description) in negativeOnlyIDs.sorted(by: { $0.key < $1.key })
        where !resolvedIDs.contains(id) {
            addSuggestion(FixSuggestion(
                isStrong: false,
                message: "`#\(id)` never resolved during this scenario"
                    + " (\(description)). Negative assertions also pass when the id is misspelled, "
                    + "so make sure the id really exists"),
                emitEvent: false, file: "", line: 0)
        }
        for (selector, description) in notCheckedOnlySelectors.sorted(by: { $0.key < $1.key })
        where !checkedObservedSelectors.contains(selector) {
            addSuggestion(FixSuggestion(
                isStrong: false,
                message: "`\(selector)` passed isNotChecked, but a checked state was never observed "
                    + "during this scenario (\(description)). If it points at an element with no check "
                    + "state (a plain button) or at an implementation that never reports one "
                    + "(SwiftUI on iOS, Flutter checkboxes), **any assertion passes**. "
                    + "Turn it on and verify isChecked as well"),
                emitEvent: false, file: "", line: 0)
        }
        for (selector, met) in branchOutcomes.sorted(by: { $0.key < $1.key }) where !met {
            addSuggestion(FixSuggestion(
                isStrong: false,
                message: "ifCanSelect \"\(selector)\" never matched during this scenario"
                    + " (the selector may be stale; a non-match is not a failure, so it goes unnoticed)"),
                emitEvent: false, file: "", line: 0)
        }
    }

    private func addSuggestion(_ suggestion: FixSuggestion, emitEvent: Bool,
                               description: String? = nil,
                               file: String, line: Int,
                               oldSelector: String? = nil, newSelector: String? = nil) {
        withState { record.fixSuggestions.append(suggestion) }
        guard emitEvent else { return }
        var event = ScenarioEvent(kind: "fixSuggestion")
        event.scenario = scenarioID
        event.scene = withState { record.scenes.last?.number }
        // 対象コマンドの description(例: tap "旧セレクタ")。修復候補の説明生成に使う
        event.description = description
        event.detail = suggestion.message
        event.file = file
        event.line = line
        event.oldSelector = oldSelector
        event.newSelector = newSelector
        emit(event)
    }

    /// 任意の async 処理を 1 ステップとして実行・記録する(launch / procedure / wait 等)
    @discardableResult
    func performCustom(description: String, file: StaticString, line: UInt,
                       _ body: @escaping () async throws -> Void) -> StepResult.Status {
        let filePath = relativePath("\(file)")
        debugCheckpoint(description: description, file: filePath, line: Int(line))
        if scenarioAborted {
            let status = StepResult.Status.skipped(skipReason)
            recordStep(description: description, status: status, file: filePath, line: Int(line))
            return status
        }
        if dryRun {
            // durationMs を必ず付与する理由は perform() 内の同種コメント参照
            let clock = ContinuousClock()
            let start = clock.now
            recordStep(description: description, status: .passed,
                       file: filePath, line: Int(line),
                       durationMs: continuousClockMilliseconds(clock.now - start))
            return .passed
        }

        // launch/wait/procedure 等は画面を変え得る → occlusion-guard のスクショ再利用を無効化
        executor.invalidateScreenshotCache()
        let clock = ContinuousClock()
        let start = clock.now
        let result = FTSync.runThrowing { try await body() }
        let elapsedMs = continuousClockMilliseconds(clock.now - start)
        let status: StepResult.Status
        switch result {
        case .success:
            status = .passed
        case .failure(let error):
            status = .failed(error.localizedDescription)
        case nil:
            status = .failed("the operation timed out (\(Int(FTSync.commandTimeout))s)")
        }
        recordStep(description: description, status: status, file: "\(file)", line: Int(line),
                   durationMs: elapsedMs, at: ISO8601Millis.string(from: Date()))

        if case .failed(let reason) = status {
            handleFailure(stepDescription: description, reason: reason)
        }
        return status
    }

    /// 停止条件に合致したら paused イベントを流してブロックし、再開コマンドを待つ。
    /// stop コマンドはシナリオ中断(以降のステップは skipped)として扱う
    private func debugCheckpoint(description: String, file: String, line: Int) {
        guard let debug = debugControl, !scenarioAborted else { return }
        let result = debug.checkpoint(file: file, line: line) {
            var event = ScenarioEvent(kind: "paused")
            event.scenario = scenarioID
            event.scene = withState { record.scenes.last?.number }
            event.section = currentSection
            event.index = stepCounter + 1
            event.description = description
            event.file = file.isEmpty ? nil : file
            event.line = line == 0 ? nil : line
            emit(event)
        }
        if result == .abort {
            scenarioAborted = true
            stoppedByUser = true
            emit(.log("⏹ The scenario was aborted by the user"))
        }
    }

    /// スキップ記録の理由(デバッグの stop による中断は表示を分ける)
    var skipReason: String {
        stoppedByUser ? "aborted by the user" : "not run because of an earlier failure"
    }

    /// 分岐評価(記録のみ、実行はしない): セレクタが現在画面で解決できるか。
    /// waitSeconds: 0 = 即時1回判定(repeat-while が最低1回は回る契約は変えない)
    func canSelect(_ selector: FTSelector, waitSeconds: Double) -> Bool {
        if dryRun { return true }  // dry-run では分岐内側も記録するため常に成立扱い
        if scenarioAborted { return false }
        let step = FlowStep(locator: selector.primary,
                            fallbacks: selector.fallbacks.isEmpty ? nil : selector.fallbacks)
        let driver = self.driver
        let deadline = Date().addingTimeInterval(waitSeconds)
        repeat {
            let snapshot = FTSync.run { try? await driver.snapshot() } ?? nil
            if let snapshot,
               StepExecutor.resolve(step: step, in: snapshot, strictForAssert: true) != nil {
                return true
            }
            // サブ秒の待ちが 0.5 秒刻みに丸められないよう、残り時間と 0.25 秒の小さい方で待つ
            let remaining = deadline.timeIntervalSinceNow
            if remaining > 0 {
                Thread.sleep(forTimeInterval: min(remaining, 0.25))
            }
        } while Date() < deadline
        return false
    }

    // MARK: - スレッド安全性(DSL スレッド外からの誤呼び出し対策)

    /// DSL スレッド外(Task/別スレッド)から呼ばれたことを FTRuntime.requireCore が検知したときに呼ぶ。
    /// 1 run につき1回だけ失敗ステップを記録してシナリオを中断する(2回目以降は静かに
    /// 中断状態を維持するだけ = ループ内の誤用で記録が溢れない)。
    /// handleFailure は呼ばない(スクリーンショット・FM トリアージを別スレッドから走らせないため)。
    /// stateLock は再入しない(recordStep が別途取得するので、ここでは _scenarioAborted を直接触る)
    func recordThreadViolation(command: String) {
        let firstViolation: Bool = {
            stateLock.lock()
            defer { stateLock.unlock() }
            if threadViolationRecorded { return false }
            threadViolationRecorded = true
            _scenarioAborted = true
            return true
        }()
        guard firstViolation else { return }
        let reason = "the DSL command \"\(command)\" was called from outside the DSL thread "
            + "(inside a Task or another thread). Wrap asynchronous work in procedure { }"
        recordStep(description: "thread violation: \(command)", status: .failed(reason), file: "", line: 0)
    }

    // MARK: - 記録

    /// durationMs/snapshotMs/actionMs/waitMs: ステップの時間内訳(単位ミリ秒)。
    /// StepExecutor 経由のステップ(tap/exist 等)は 4 つとも渡され、performCustom 経由
    /// (launchApp/wait/procedure 等)は durationMs のみ、それ以外(skip・dry-run 等)は
    /// 全て nil のまま(=計測なし)になる。
    /// **DSL スレッドと違反スレッドが同時に呼び得るため stateLock で直列化する**(stepCounter/
    /// record 追記/emit を含む一体の操作。emit は呼び出し側が print 等で組んでおり FTDriveCore へ
    /// 再入しないことを確認済み = デッドロックしない)
    func recordStep(description: String, status: StepResult.Status, file: String, line: Int,
                    durationMs: Int? = nil, snapshotMs: Int? = nil,
                    actionMs: Int? = nil, waitMs: Int? = nil, at: String? = nil) {
        stateLock.lock()
        defer { stateLock.unlock() }
        stepCounter += 1
        // group の名前はここでだけ前置する(修正提案の description は素のまま = ソース行との照合に使うため)
        let displayed = groupStack.isEmpty
            ? description
            : "[\(groupStack.joined(separator: "/"))] \(description)"
        let record = DSLStepRecord(index: stepCounter, section: currentSection,
                                   description: displayed, status: status,
                                   file: relativePath(file), line: line, durationMs: durationMs)
        appendToCurrentScene(record)

        var event = ScenarioEvent(kind: "step")
        event.scenario = scenarioID
        event.scene = self.record.scenes.last?.number
        event.section = currentSection
        event.index = record.index
        event.description = displayed
        let (statusText, detail) = status.eventStatus
        event.status = statusText
        event.detail = detail
        event.file = record.file.isEmpty ? nil : record.file
        event.line = line == 0 ? nil : line
        event.durationMs = durationMs
        event.snapshotMs = snapshotMs
        event.actionMs = actionMs
        event.waitMs = waitMs
        event.at = at
        emit(event)
    }

    private func appendToCurrentScene(_ step: DSLStepRecord) {
        if record.scenes.isEmpty {
            // scene { } の外でコマンドが呼ばれた場合の受け皿(暗黙 scene 0)
            record.scenes.append(SceneRecordData(number: 0, title: ""))
        }
        record.scenes[record.scenes.count - 1].steps.append(step)
    }

    /// executor のコールバック(FTSync の detached Task 上)からも呼ばれるので状態は withState 経由
    private func markDeviceFrozen() {
        let first = withState { () -> Bool in
            guard !deviceFrozen else { return false }
            deviceFrozen = true
            scenarioAborted = true
            return true
        }
        guard first else { return }
        var event = ScenarioEvent(kind: "deviceFrozen")
        event.scenario = scenarioID
        emit(event)
    }

    /// perform を通らないコマンド(ifCanSelect の構文エラー)からも呼ぶため internal
    func handleFailure(stepDescription: String, reason: String) {
        // 失敗したら**シナリオ全体を中断**する(Shirates と同じ。scene を跨いで続行しない。
        // tearDown だけは runLifecycle(allowAfterFailure:) がこのフラグを一時解除して実行する)
        scenarioAborted = true

        // 失敗時のスクリーンショット+トリアージ(FM 利用可時のみ)。Android は画面凍結(白フレーム)で
        // 証跡が無効になり得るため、blank を検知したら最大3回撮り直して回復を待つ(iOS は対象外)。
        // トリアージは白のままでも変わらず実行する(証跡としては evidenceBlank で無効マークするのみ)。
        let driver = self.driver
        let delegate = executor.delegate
        let goal = scenarioTitle.isEmpty ? scenarioID : scenarioTitle
        // 白フレーム=画面凍結の推定を行うか。エミュレータ固有の病理(GPU 合成バッファ固着)なので
        // Android **かつ**実機でない場合だけ。実機は「画面が消灯しているだけ」を凍結と誤断する
        let inferFrozenFromBlankFrame = platform == "android" && !physical
        let context = FTSync.run { () async -> (Data?, TriageInfo?, Bool, String?) in
            let snapshot = try? await driver.snapshot()
            let elementsText = snapshot.map { SnapshotRenderer.render($0) }
            var screenshot = try? await driver.screenshot()
            var evidenceBlank = false
            if inferFrozenFromBlankFrame, let shot = screenshot,
               BlankFrameDetector.isUniformBlank(pngData: shot) {
                evidenceBlank = true
                for _ in 0..<3 {
                    try? await Task.sleep(nanoseconds: 2_500_000_000)
                    guard let retry = try? await driver.screenshot() else { continue }
                    screenshot = retry
                    if !BlankFrameDetector.isUniformBlank(pngData: retry) {
                        evidenceBlank = false
                        break
                    }
                }
            }
            let triage = await delegate?.triage(goal: goal,
                                                stepDescription: stepDescription,
                                                failureReason: reason,
                                                snapshot: snapshot,
                                                screenshotPNG: screenshot)
            return (screenshot, triage, evidenceBlank, elementsText)
        }
        if let (screenshot, triage, evidenceBlank, elementsText) = context {
            withState {
                guard !record.scenes.isEmpty else { return }
                record.scenes[record.scenes.count - 1].failureScreenshot = screenshot
                record.scenes[record.scenes.count - 1].triage = triage
                record.scenes[record.scenes.count - 1].evidenceBlank = evidenceBlank
                record.scenes[record.scenes.count - 1].failureElements = elementsText
            }
            if evidenceBlank { markDeviceFrozen() }
        }
        // アプリが別プロセスの window に覆われていたなら、それが第一の容疑
        // (要素一覧・スクショだけでは「なぜ操作が効かなかったのか」に辿り着けない)
        let overlays = foregroundOverlays?() ?? []
        guard !overlays.isEmpty else { return }
        let recorded = withState { () -> Bool in
            guard !record.scenes.isEmpty else { return false }
            record.scenes[record.scenes.count - 1].failureForegroundWindows = overlays
            return true
        }
        if recorded {
            emit(.log("⚠️ Another window is in front of the app: \(overlays.joined(separator: ", "))"
                      + " (interactions may have been swallowed by it)"))
        }
    }

    private func relativePath(_ path: String) -> String {
        let cwd = FileManager.default.currentDirectoryPath + "/"
        return path.hasPrefix(cwd) ? String(path.dropFirst(cwd.count)) : path
    }
}

/// Duration → 整数ミリ秒(1ms = 1e15 attoseconds)。StepExecutor.ms と同じ計算式だが、
/// FTCore 側は private でモジュールを跨いで参照できないためここに複製している(要同期)
func continuousClockMilliseconds(_ duration: Duration) -> Int {
    let (seconds, attoseconds) = duration.components
    return Int(seconds) * 1000 + Int(attoseconds / 1_000_000_000_000_000)
}
