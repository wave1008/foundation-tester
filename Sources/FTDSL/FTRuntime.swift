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
    /// screenshot() コマンドが撮った画像。ScenarioReportWriter がこのステップの直後に埋め込む。
    /// 他コマンドは常に nil(failureScreenshot とは別経路)
    public let screenshotData: Data?
    public let screenshotLabel: String?

    public init(index: Int, section: String?, description: String, status: StepResult.Status,
                file: String, line: Int, durationMs: Int? = nil,
                screenshotData: Data? = nil, screenshotLabel: String? = nil) {
        self.index = index
        self.section = section
        self.description = description
        self.status = status
        self.file = file
        self.line = line
        self.durationMs = durationMs
        self.screenshotData = screenshotData
        self.screenshotLabel = screenshotLabel
    }
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
    /// tapAppIcon 用。**systemDriver とは別**: hybrid の typeDriver(AppAttachDriver)は
    /// snapshot() のたびテスト対象アプリを再前面化する(springboard を見せない)ため使えない。
    /// 優先順: ①明示注入(xcuitest 単独。**セッションが対象アプリに縛られた通常ドライバは
    /// home() 後の snapshot が背面アプリ照会でハングする** — 実機で踏んだため springboard 参照を
    /// 注入する)→ ② fallbackDriver(hybrid の SystemUIDriver)→ ③ systemDriver
    /// (Android は再前面化しない。inapp 単独は home() が 501 で自然に失敗する)
    private let homeScreenDriverOverride: AppDriver?
    var homeScreenDriver: AppDriver {
        homeScreenDriverOverride ?? executor.fallbackDriver ?? systemDriver
    }
    /// true = homeScreenDriver が主ドライバと同じランナーのセッションを付け替える
    /// (xcuitest 単独。tapAppIcon が終わりにセッションを張り直す条件。
    /// hybrid は主ドライバが in-app なので張り替えの影響を受けない)
    var homeScreenSharesRunnerSession: Bool { homeScreenDriverOverride != nil }
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
    /// 自由関数 `lastElement` が読む「直前に掴んだ要素」(Shirates の TestDriver.lastElement 相当)。
    /// 更新するのは**要素を1つに定めて解決したコマンドだけ**(判定は Commands.swift の
    /// `definesSingleElement`)。**掴めなかったときも空要素で上書きする** —— 前の要素を残すと
    /// 別要素の値を「今掴んだもの」として読んでしまう。scene の切り替わりで捨てる(runScene)。
    /// 保持するのは掴んだ時点の凍結値で、再取得はしない(FTElement.matched と同じ契約)
    var lastResolvedElement: FTElement?
    /// 何も掴んでいない状態で `lastElement` を読んだ警告は 1 run に 1 回だけ
    private var lastElementWarned = false
    /// group("名前") { } の入れ子。記録時にステップ説明へ `[外/内]` を前置する
    var groupStack: [String] = []
    /// verify() のブロック内で走ったアサーション数を数えるスタック。ネストした verify を
    /// support するため「今アクティブな全フレーム」に加算する(noteAssertion 参照)。
    /// group と同様 DSL スレッド専有で lock 不要
    struct VerifyFrame { var assertionCount = 0 }
    var verifyStack: [VerifyFrame] = []
    /// 実行中の CAE セクション内で走ったアサーション数(runSection が退避・復元する)。
    /// **0 のまま終わった expectation は「何も検証していない」** = 緑になる誤り
    var sectionAssertionCount = 0
    /// シナリオ全体のアサーション数。0 なら**どう転んでも検証していない**(warnAboutMissingAssertions)
    var scenarioAssertionCount = 0
    /// 本体を実行しなかった条件ブロックの数(`ios`/`android` の不一致・`ifCanSelect` の不成立・
    /// `repeatWhileCanSelect` の 0 周)。**中に何が書かれているかは実行しないと分からない**ので、
    /// 1つでもあればアサーション不足の警告を出さない —— 誤検知を出さない側に倒す
    /// (実際 `expectation { android { notExist(...) } }` を iOS で回すと 0 本に見える)
    var sectionUnexecutedBlocks = 0
    var scenarioUnexecutedBlocks = 0
    /// このプロジェクトで観測済みの `#id`(`ft_snapshot` が貯めた台帳。SelectorInventory)。
    /// **nil = 台帳が無い / このプラットフォームの記録が無い** → 照合しない(黙る)
    private let knownIDs: Set<String>?
    /// dry-run 中に見つけた「台帳に無い id」→ 最初に見たステップの説明
    private var unknownIDs: [String: String] = [:]
    /// 同じく、台帳に**在った** id。**台帳がこのシナリオの範囲を実際にカバーしているか**の判定に使う
    /// (warnAboutUnknownIDs 参照)
    private var seenKnownIDs: Set<String> = []
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
    /// `checkIsOFF` で通ったセレクタ → 最初に見た説明。**checked を一度も観測できなかったもの**は
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

    /// `withScrollDown(scrollFrame:) { }` が積むスクロール領域(Shirates の
    /// CodeExecutionContext.scrollFrame 相当)。**向きと同じ寿命**で積み降ろしする。
    /// 中身はセレクタ式(Shirates も String 式)。ブロック内の `scroll:` 探索が継承する
    var scrollFrameStack: [String?] = []

    /// コマンドが使うスクロール向き。明示 > ブロックの文脈 > 無し
    func effectiveScroll(_ explicit: FTScrollDirection?) -> FTScrollDirection? {
        if let explicit { return explicit }
        switch scrollContextStack.last {
        case .direction(let d): return d
        case .none?, nil: return nil
        }
    }

    /// コマンドが使うスクロール領域。明示 > ブロックの文脈 > 無し(= 従来の全画面固定)
    func effectiveScrollFrame(_ explicit: String?) -> String? {
        if let explicit { return explicit }
        return scrollFrameStack.last ?? nil
    }

    func runWithScrollContext(_ context: ScrollContext, scrollFrame: String? = nil,
                              _ body: () -> Void) {
        scrollContextStack.append(context)
        scrollFrameStack.append(scrollFrame)
        body()
        scrollContextStack.removeLast()
        scrollFrameStack.removeLast()
    }

    /// `withoutContainerInference { }` が積む文脈(Bool そのもの。方向のような .none 相当は無く、
    /// スタックが空 = 文脈なし)。**`FlowStep.containerInference` と同じ3値ロジック** ——
    /// nil はここでも「プロファイル既定に委ねる」を表す
    var containerInferenceStack: [Bool] = []

    /// コマンドが使う容器推測補正の有効/無効。明示 > ブロックの文脈 > nil(実行プロファイル既定に委ねる)。
    /// `FTDriveCore.perform` の入口が `step.containerInference == nil` のときだけこれを呼ぶので、
    /// 全コマンド共通でブロックの文脈が効く(tap/scrollTo は明示引数をここへ渡してから呼ぶ)
    func effectiveContainerInference(_ explicit: Bool?) -> Bool? {
        if let explicit { return explicit }
        return containerInferenceStack.last
    }

    func runWithContainerInference(_ enabled: Bool, _ body: () -> Void) {
        containerInferenceStack.append(enabled)
        body()
        containerInferenceStack.removeLast()
    }

    /// true = デバイスに触れず全コマンドを記録のみで通過させる(ステップ列挙・コード生成の検証用)
    let dryRun: Bool

    /// --debug 時のブレークポイント/一時停止制御。nil なら通常実行(dry-run でも有効)
    public var debugControl: ScenarioDebugControl?
    /// --host-install 時のみ非 nil。installApp() はこれがあれば親(オーケストレータ)へ RPC する
    /// (installApp と同じ理由で子はパスを解決できないため、実行自体を親に委ねる。2026-08-03 決定)
    public var installControl: ScenarioInstallControl?
    /// --app-path で親が解決して渡した実行プロファイルの appPath。installControl が nil のとき
    /// (ホスト無しの単独実行)の installApp() 引数省略時のフォールバックに使う
    public var appPathOverride: String?
    /// --app-name で親が解決して渡したアプリの表示名(プロファイルの appName)。
    /// tapAppIcon() 引数省略時の既定(Shirates の appIconName 既定=プロファイル、に相当)
    public var appDisplayName: String?
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
                // 容器の推測に依存する補正の既定(実行プロファイル由来。**FM とは無関係**)
                containerInference: Bool = true,
                dryRun: Bool = false,
                healCacheURL: URL? = nil,
                selectorInventoryURL: URL? = nil,
                defaultTimeout: Double? = nil,
                fallbackDriver: AppDriver? = nil,
                typeDriver: AppDriver? = nil,
                preferTypeDriver: Bool = false,
                typeDriverGestures: Set<String> = [],
                homeScreenDriver: AppDriver? = nil,
                deviceName: String? = nil,
                deviceIdentifier: String? = nil,
                physical: Bool = false,
                emit: @escaping (ScenarioEvent) -> Void) {
        self.driver = driver
        self.platform = platform
        self.physical = physical
        self.appBundleID = app
        self.homeScreenDriverOverride = homeScreenDriver
        self.executor = StepExecutor(driver: driver, fallbackDriver: fallbackDriver,
                                     typeDriver: typeDriver, preferTypeDriver: preferTypeDriver,
                                     typeDriverGestures: typeDriverGestures,
                                     delegate: delegate, healingEnabled: healingEnabled,
                                     occlusionGuardEnabled: falsePositiveCheckEnabled,
                                     screenIsEnabled: screenIsEnabled,
                                     releasesScrollTouch: platform == "ios",
                                     containerInference: containerInference)
        self.scenarioID = scenarioID
        self.scenarioTitle = scenarioTitle
        self.dryRun = dryRun
        self.healCache = HealCache(
            url: healCacheURL ?? URL(fileURLWithPath: ".ftester/heal-cache.json"))
        // 台帳の照合は dry-run 専用(実行なら解決の成否が答えを出すので、二重に言う意味が無い)
        self.knownIDs = dryRun
            ? selectorInventoryURL.flatMap { SelectorInventory.load(at: $0) }?.ids(platform: platform)
            : nil
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
        // scene を跨いで前の画面の要素を読むのは事故(値も座標も古い)。持ち越さない
        lastResolvedElement = nil
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

    /// CAE の 1 ブロック。**expectation がアサーション 0 個で終わったら警告する** —
    /// 「action に全部書いて expectation には tap だけ置く」「exist のつもりで select を置く」は
    /// コンパイルも実行も通り、**何も検証しないまま緑**になる(verify の inconclusive と同じ穴を
    /// CAE 側にも塞ぐ)。失敗にはしない = 既存シナリオを止めない
    func runSection(_ name: String, _ body: () -> Void) {
        let previous = currentSection
        let previousCount = sectionAssertionCount
        let previousUnexecuted = sectionUnexecutedBlocks
        currentSection = name
        sectionAssertionCount = 0
        sectionUnexecutedBlocks = 0
        body()
        if name == "expectation", sectionAssertionCount == 0, sectionUnexecutedBlocks == 0 {
            warnSectionWithoutAssertions()
        }
        currentSection = previous
        sectionAssertionCount = previousCount
        sectionUnexecutedBlocks = previousUnexecuted
    }

    private func warnSectionWithoutAssertions() {
        let scene = withState { record.scenes.last }
        let title = (scene?.title).map { $0.isEmpty ? "" : " (\"\($0)\")" } ?? ""
        let location = scene.map { "scene \($0.number)\(title)" } ?? "a scene"
        let message = "the expectation block of \(location) contains no assertions "
            + "(it checks nothing). Add exist / textIs / thisIs etc."
        emit(.log("⚠️ " + message))
        addSuggestion(FixSuggestion(isStrong: false, message: message),
                      emitEvent: false, file: "", line: 0)
    }

    /// まだ何も掴んでいないのに `lastElement` が読まれた。空要素を返すだけだと
    /// 「掴んだが空だった」と見分けが付かないので、1 度だけ警告と弱い修正提案を残す
    func warnLastElementUnavailable() {
        guard !lastElementWarned else { return }
        lastElementWarned = true
        let message = "lastElement was read before any element was grabbed, so it is empty. "
            + "Grab one first (select / exist / tap ...), or hold it in a variable"
        emit(.log("⚠️ " + message))
        addSuggestion(FixSuggestion(isStrong: false, message: message),
                      emitEvent: false, file: "", line: 0)
    }

    /// 名前付きの共通ステップ(group)。記録上の見え方だけを変え、実行・失敗セマンティクスは素の列と同じ
    func runGroup(_ title: String, _ body: () -> Void) {
        groupStack.append(title)
        body()
        groupStack.removeLast()
    }

    struct VerifyOutcome { let assertionCount: Int; let failed: Bool }

    /// verify() の実体。body 実行中に noteAssertion() で数えたアサーション数と、
    /// 実行中に新たに scenarioAborted が立ったか(= 既存の failure が verify を失敗させたか)を返す
    func runVerify(_ body: () -> Void) -> VerifyOutcome {
        verifyStack.append(VerifyFrame())
        let abortedBefore = scenarioAborted
        body()
        let frame = verifyStack.removeLast()
        let failed = !abortedBefore && scenarioAborted
        return VerifyOutcome(assertionCount: frame.assertionCount, failed: failed)
    }

    /// perform()(assert 系 FlowStep)と ValueAssertions.record()(thisIs 系)の両方から呼ぶ。
    /// **「アサーションとして書かれた」の唯一の定義**で、verify / CAE セクション / シナリオ全体の
    /// 3 つの計数がここに合流する(定義が割れると片方だけ誤検知する)
    func noteAssertion() {
        sectionAssertionCount += 1
        scenarioAssertionCount += 1
        for i in verifyStack.indices { verifyStack[i].assertionCount += 1 }
    }

    /// 条件ブロックの本体を実行しなかった(sectionUnexecutedBlocks の説明を参照)
    func noteUnexecutedBlock() {
        sectionUnexecutedBlocks += 1
        scenarioUnexecutedBlocks += 1
    }

    /// verify のブロックにアサーションが無かったときの弱い修正提案(2026-08-03 ユーザー決定:
    /// ステップ自体は .inconclusive(理由つき)で記録されるため、別途の警告ログは出さない
    /// (旧 warnVerifyWithoutAssertions。ステップ行が理由を持つようになり役割が変わった)
    func suggestVerifyWithoutAssertions(message: String) {
        addSuggestion(FixSuggestion(
            isStrong: false,
            message: "verify \"\(message)\" block contains no assertions (it checks nothing). "
                     + "Add exist / textIs / thisIs etc."),
            emitEvent: false, file: "", line: 0)
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
    /// selectorError: 実行前に落とす理由(FTSelector.preflightError)。
    /// nil = 検証済み・問題なし。セレクタを取らないコマンドも nil
    /// commandError: セレクタ以外の引数の誤り。**メッセージをそのまま**失敗理由にする
    /// (selectorError は "invalid selector syntax: " を前置するので用途が違う)
    /// heldElement: **既に掴んである要素**(FTElement のチェーンだけが渡す)。満たしていれば
    /// デバイスを見ずに通す(下記の高速経路)。満たしていなければ従来どおり実機で取り直す
    func perform(step: FlowStep, description: String, selectorText: String? = nil,
                 selectorError: String? = nil, commandError: String? = nil,
                 heldElement: ElementInfo? = nil,
                 file: StaticString, line: UInt) -> PerformResult {
        // 全コマンドの唯一の合流点(セレクタを取らないコマンドも含む)なので、ここで一度だけ
        // ブロックの文脈を埋める。tap/scrollTo は明示引数を effectiveContainerInference 済みで
        // 渡してくるため、ここでは非 nil で二重に通っても変わらない
        var step = step
        if step.containerInference == nil {
            step.containerInference = effectiveContainerInference(nil)
        }
        let filePath = relativePath("\(file)")
        // verify() のブロック内アサーション数を数える(判定は FlowStep.assert != nil のみ。
        // skip/dry-run/失敗いずれの結果になっても「アサーションとして書かれた」事実は変わらない)
        if step.assert != nil { noteAssertion() }
        debugCheckpoint(description: description, file: filePath, line: Int(line))
        if scenarioAborted {
            let status = StepResult.Status.skipped(skipReason)
            recordStep(description: description, status: status, file: filePath, line: Int(line))
            return PerformResult(status: status, element: nil)
        }
        // 構文検証はデバイスに触る前(dry-run でも)に行う。パースは失敗しない契約のため、
        // `:rigth(x)` のような誤りは「そんなラベルは無い」に化け、notExist/countIs(x,0) では
        // 緑になってしまう。ここで落とすのが唯一の防波堤(FTSelector.preflightError 参照)
        if let error = selectorError ?? commandError {
            let reason = selectorError == nil ? error : "invalid selector syntax: \(error)"
            let status = StepResult.Status.failed(reason)
            recordStep(description: description, status: status, file: filePath, line: Int(line))
            handleFailure(stepDescription: description, reason: reason)
            return PerformResult(status: status, element: nil)
        }
        if dryRun {
            trackUnknownIDs(step: step, description: description)
            // 実機に触れず計測はほぼ 0ms だが、NDJSON 配線を検証できるよう durationMs は必ず付与する
            let clock = ContinuousClock()
            let start = clock.now
            recordStep(description: description, status: .passed, file: filePath, line: Int(line),
                       durationMs: continuousClockMilliseconds(clock.now - start))
            return PerformResult(status: .passed, element: nil)
        }

        // 高速経路: **掴んである値だけで満たしているなら実機を見に行かない**(FTElement のチェーン)。
        // 満たしていなければ何もせず下の通常経路へ落ちる = 従来どおり取り直しながらポーリングする。
        // 判定できるアサートの範囲と除外理由は HeldElementAssert。
        // **可視性照合(occlusion-guard)が走る設定では高速経路に入らない** —— 見えているかは
        // 保持値から言えないので、飛ばすと falsePositiveCheck 有効の run で検査が1つ静かに消える。
        // 条件は StepExecutor.occlusionFlip の入口(ステップ非依存の部分)と同じものを見る。
        // 注記を description に足すのは、レポートで「取り直していない判定」を見分けられるようにするため
        let visibilityWouldBeChecked = executor.occlusionGuardEnabled
            && (step.occlusionGuard ?? executor.occlusionGuard)
            && executor.delegate != nil
            && FMVisionSupport.isSupported
        if let heldElement, let assert = step.assert, !visibilityWouldBeChecked,
           HeldElementAssert.satisfied(assert: assert, expected: step.expected,
                                       element: heldElement) == true {
            recordStep(description: description + "(\(StepNote.heldValue.text))", status: .passed,
                       file: filePath, line: Int(line), durationMs: 0,
                       notes: [.heldValue])
            trackIDResolution(step: step, status: .passed, description: description)
            return PerformResult(status: .passed, element: heldElement)
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
                   at: outcome?.at,
                   notes: outcome?.notes ?? [])

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

    /// dry-run 中、**台帳に無い `#id`** を覚える(綴り誤り・でっち上げの検出。SelectorInventory)。
    /// 台帳が無い/そのプラットフォームの記録が無いなら何もしない = 「知らない」を「間違い」と言わない
    private func trackUnknownIDs(step: FlowStep, description: String) {
        guard let knownIDs, !knownIDs.isEmpty else { return }
        let locators = ([step.locator] + (step.fallbacks ?? [])).compactMap { $0 }
        for id in locators.flatMap(SelectorInventory.exactIDs(in:)) {
            if knownIDs.contains(id) {
                seenKnownIDs.insert(id)
            } else if unknownIDs[id] == nil {
                unknownIDs[id] = description
            }
        }
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
        case .failed, .skipped, .inconclusive: succeeded = false
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

    /// `checkIsOFF` が「状態を持たない要素」を指していないかを覚える。
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
        case .failed, .skipped, .inconclusive:
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

    /// **シナリオ全体でアサーションが1本も無い**ときの警告。expectation 単位の警告
    /// (runSection)より重い症状 —— 操作しただけで何も確かめておらず、**アプリがどう壊れても緑**。
    /// dry-run でも成立する静的な判定なので、生成直後の検証ループで拾える。
    /// シナリオ終了時に1回だけ呼ぶ(warnAboutNeverResolvedIDs と同じ位置)
    public func warnAboutMissingAssertions() {
        guard scenarioAssertionCount == 0, scenarioUnexecutedBlocks == 0,
              withState({ !record.scenes.isEmpty }) else { return }
        let message = "this scenario contains no assertions at all "
            + "(it only operates the app, so it stays green no matter how the app breaks). "
            + "Add exist / textIs / thisIs etc. to the expectation blocks"
        emit(.log("⚠️ " + message))
        addSuggestion(FixSuggestion(isStrong: true, message: message),
                      emitEvent: false, file: "", line: 0)
    }

    /// **台帳(ft_snapshot が貯めた実在 id)に無い `#id`** を dry-run で警告する。
    /// 綴り誤り・でっち上げは構文検証を通ってしまい、従来は実機で初めて分かった。
    /// **失敗にはしない** —— 台帳は「撮った画面ぶんだけ」なので、新しい画面の id は当然載っていない。
    /// シナリオ終了時に1回だけ呼ぶ(dry-run 以外では unknownIDs が空なので no-op)。
    ///
    /// **薄い台帳では黙る**: 台帳の有無だけで判定すると、1画面しか撮っていない状態で
    /// 既存シナリオを回したときに**他画面の id を全部「綴り誤り」と言う**(実測 44/47 シナリオが
    /// 誤警告。2026-08-03 のドッグフーディングで判明)。**そのシナリオが触る id の 2/3 以上が
    /// 台帳に在るときだけ**警告する = 台帳がこの範囲をカバーしている証拠がある場合に限る。
    /// 綴り誤りは「多数の正しい id に少数の誤り」という形で出るので、この比で拾える
    public func warnAboutUnknownIDs() {
        guard !unknownIDs.isEmpty else { return }
        let total = unknownIDs.count + seenKnownIDs.count
        guard unknownIDs.count * 3 <= total else { return }
        let listed = unknownIDs.keys.sorted().map { "`#\($0)`" }.joined(separator: ", ")
        let message = "\(listed): no snapshot taken for this project contains this id "
            + "(it may be misspelled). If it belongs to a screen that has not been captured yet, "
            + "take a fresh ft_snapshot of that screen"
        emit(.log("⚠️ " + message))
        addSuggestion(FixSuggestion(isStrong: false, message: message),
                      emitEvent: false, file: "", line: 0)
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
                message: "`\(selector)` passed checkIsOFF, but a checked state was never observed "
                    + "during this scenario (\(description)). If it points at an element with no check "
                    + "state (a plain button) or at an implementation that never reports one "
                    + "(SwiftUI on iOS, Flutter checkboxes), **any assertion passes**. "
                    + "Turn it on and verify checkIsON as well"),
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

    /// 任意の async 処理を 1 ステップとして実行・記録する(launch / procedure / wait 等)。
    /// launchTiming は launchApp/restartApp だけが渡す(body 完了後に読む actionMs/waitMs 取得元。
    /// 他の呼び出しは既定 nil = durationMs のみ)。
    /// isAssertion は **appIs だけ** true(FlowStep を持たない唯一の検証コマンドで、
    /// 渡さないと verify も expectation も「検証0本」と数えてしまう)
    @discardableResult
    func performCustom(description: String, file: StaticString, line: UInt,
                       launchTiming: (() -> LaunchTiming?)? = nil,
                       isAssertion: Bool = false,
                       _ body: @escaping () async throws -> Void) -> StepResult.Status {
        let filePath = relativePath("\(file)")
        if isAssertion { noteAssertion() }
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
        let timing = launchTiming?()
        recordStep(description: description, status: status, file: "\(file)", line: Int(line),
                   durationMs: elapsedMs, actionMs: timing?.actionMs, waitMs: timing?.waitMs,
                   at: ISO8601Millis.string(from: Date()))

        if case .failed(let reason) = status {
            handleFailure(stepDescription: description, reason: reason)
        }
        return status
    }

    /// screenshot コマンドの実体。performCustom を使わないのは、取得した Data をこのステップの
    /// 記録へ添付する必要があるため(performCustom の body は Void しか返せない)
    @discardableResult
    func performScreenshot(filename: String?, file: StaticString, line: UInt) -> StepResult.Status {
        let filePath = relativePath("\(file)")
        let label = Self.screenshotLabel(filename: filename, index: stepCounter + 1)
        let description = "screenshot \"\(label)\""
        debugCheckpoint(description: description, file: filePath, line: Int(line))
        if scenarioAborted {
            let status = StepResult.Status.skipped(skipReason)
            recordStep(description: description, status: status, file: filePath, line: Int(line))
            return status
        }
        if dryRun {
            recordStep(description: description, status: .passed, file: filePath, line: Int(line))
            return .passed
        }

        executor.invalidateScreenshotCache()
        let driver = self.driver
        let clock = ContinuousClock()
        let start = clock.now
        let result = FTSync.runThrowing { try await driver.screenshot() }
        let elapsedMs = continuousClockMilliseconds(clock.now - start)
        switch result {
        case .success(let data):
            recordStep(description: description, status: .passed, file: filePath, line: Int(line),
                      durationMs: elapsedMs, screenshotData: data, screenshotLabel: label)
            return .passed
        case .failure(let error):
            let status = StepResult.Status.failed(error.localizedDescription)
            recordStep(description: description, status: status, file: filePath, line: Int(line),
                      durationMs: elapsedMs)
            handleFailure(stepDescription: description, reason: error.localizedDescription)
            return status
        case nil:
            let reason = "the operation timed out (\(Int(FTSync.commandTimeout))s)"
            let status = StepResult.Status.failed(reason)
            recordStep(description: description, status: status, file: filePath, line: Int(line),
                      durationMs: elapsedMs)
            handleFailure(stepDescription: description, reason: reason)
            return status
        }
    }

    private static func screenshotLabel(filename: String?, index: Int) -> String {
        let base = filename ?? "\(index)"
        return base.hasSuffix(".png") ? base : base + ".png"
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
    /// StepExecutor 経由のステップ(tap/exist 等)は 4 つとも渡され、performCustom 経由は
    /// durationMs のみ(launchApp/restartApp は launchTiming 経由で actionMs/waitMs も持つ。
    /// 他の wait/procedure 等は durationMs のみ)、それ以外(skip・dry-run 等)は
    /// 全て nil のまま(=計測なし)になる。
    /// **DSL スレッドと違反スレッドが同時に呼び得るため stateLock で直列化する**(stepCounter/
    /// record 追記/emit を含む一体の操作。emit は呼び出し側が print 等で組んでおり FTDriveCore へ
    /// 再入しないことを確認済み = デッドロックしない)
    func recordStep(description: String, status: StepResult.Status, file: String, line: Int,
                    durationMs: Int? = nil, snapshotMs: Int? = nil,
                    actionMs: Int? = nil, waitMs: Int? = nil, at: String? = nil,
                    notes: [StepNote] = [],
                    screenshotData: Data? = nil, screenshotLabel: String? = nil) {
        stateLock.lock()
        defer { stateLock.unlock() }
        stepCounter += 1
        // group の名前はここでだけ前置する(修正提案の description は素のまま = ソース行との照合に使うため)
        let displayed = groupStack.isEmpty
            ? description
            : "[\(groupStack.joined(separator: "/"))] \(description)"
        let record = DSLStepRecord(index: stepCounter, section: currentSection,
                                   description: displayed, status: status,
                                   file: relativePath(file), line: line, durationMs: durationMs,
                                   screenshotData: screenshotData, screenshotLabel: screenshotLabel)
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
        event.notes = notes.isEmpty ? nil : notes.map(\.rawValue)
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
        // 証跡が無効になり得るため、blank を検知したら最大3回撮り直して回復を待つ。
        // トリアージは白のままでも変わらず実行する(証跡としては evidenceBlank で無効マークするのみ)。
        let driver = self.driver
        let delegate = executor.delegate
        let goal = scenarioTitle.isEmpty ? scenarioID : scenarioTitle
        // 白フレーム=画面凍結の推定を行うか。**仮想デバイスなら OS を問わず行う**。
        // **実機だけ外す**理由は「画面が消灯しているだけ」を凍結と誤断するため。
        //
        // **旧実装は Android 限定で、これは誤りだった**(2026-08-05 実測): iOS シミュレータでも
        // まったく同じ病理が起きる —— 画面は真っ黒なのに **a11y ツリーは健全なホーム画面を返し、
        // タップだけが1つも届かない**。E2E-CMP/ios-xcuitest の `-06` で `tap("#nav_scroll")` が
        // 9/9 で飲まれ、MCP から手で叩いても再現した(2回連続タップも不発 =「容器が最初の1タッチを
        // 吸う」型ではない)。**ファイルサイズでは検出できない**(黒一色でも 42KB あった)ので、
        // 画素をサンプルする BlankFrameDetector が唯一の判定手段。
        // これを外していたため、環境起因の全滅が「テストの失敗」として無警告で記録されていた
        let inferFrozenFromBlankFrame = !physical
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
