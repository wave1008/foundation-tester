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

    var core: FTDriveCore?
    var dslThread: Thread?

    /// ランナーがシナリオ実行前に呼ぶ
    public static func bootstrap(core: FTDriveCore, dslThread: Thread) {
        shared.core = core
        shared.dslThread = dslThread
    }

    public static func tearDown() {
        shared.core = nil
        shared.dslThread = nil
    }

    /// コマンド実装から呼ぶ。未初期化・スレッド違反は即座に分かりやすく落とす
    static func requireCore(command: String) -> FTDriveCore {
        guard let core = shared.core else {
            fatalError("FTDSL: \(command) はシナリオ実行中にのみ呼び出せます(ftester-scenarios run 経由で実行してください)")
        }
        if let thread = shared.dslThread, Thread.current !== thread {
            fatalError("FTDSL: \(command) は DSL スレッド外(Task や別スレッド内)から呼び出せません。非同期処理は procedure { } に包んでください")
        }
        return core
    }
}

// MARK: - ドライブコア(コマンドの実体)

public final class FTDriveCore {
    let driver: AppDriver
    public let platform: String
    let appBundleID: String
    let executor: StepExecutor
    let scenarioID: String
    let scenarioTitle: String
    let emit: (ScenarioEvent) -> Void
    let healCache: HealCache
    /// 検証コマンド(exist/textIs 等)の既定タイムアウト秒(実行プロファイルで変更可)
    public let defaultTimeout: Int

    private(set) var record: ScenarioRecordData

    // 実行状態(DSL スレッドからのみ触る)
    var currentSection: String?
    var sceneAborted = false
    var scenarioAborted = false
    var abortScenarioOnSceneFailure = false
    var stepCounter = 0

    /// true = デバイスに触れず全コマンドを記録のみで通過させる(ステップ列挙・コード生成の検証用)
    let dryRun: Bool

    /// --debug 時のブレークポイント/一時停止制御。nil なら通常実行(dry-run でも有効)
    public var debugControl: ScenarioDebugControl?
    /// stop コマンドで中断した場合 true。expectation 未到達なので成功扱いにしない
    public private(set) var stoppedByUser = false

    public init(driver: AppDriver, platform: String, app: String,
                scenarioID: String, scenarioTitle: String,
                delegate: ReplayDelegate?, healingEnabled: Bool,
                dryRun: Bool = false,
                healCacheURL: URL? = nil,
                defaultTimeout: Int? = nil,
                fallbackDriver: AppDriver? = nil,
                deviceName: String? = nil,
                deviceIdentifier: String? = nil,
                emit: @escaping (ScenarioEvent) -> Void) {
        self.driver = driver
        self.platform = platform
        self.appBundleID = app
        self.executor = StepExecutor(driver: driver, fallbackDriver: fallbackDriver,
                                     delegate: delegate, healingEnabled: healingEnabled)
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
    }

    public var finalRecord: ScenarioRecordData { record }

    // MARK: - scene / CAE ブロック

    func runScene(_ number: Int, _ title: String, _ body: () -> Void) {
        sceneAborted = false
        currentSection = nil
        record.scenes.append(SceneRecordData(number: number, title: title))

        var event = ScenarioEvent(kind: "sceneStarted")
        event.scenario = scenarioID
        event.scene = number
        event.sceneTitle = title
        emit(event)

        if scenarioAborted {
            recordStep(description: "scene \(number) 本体をスキップ",
                       status: .skipped("シナリオ中断のため未実行"), file: "", line: 0)
        } else {
            body()
        }

        currentSection = nil
        let passed = record.scenes.last?.passed ?? false
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

    // MARK: - ステップ実行

    /// コマンドの共通実行経路。selectorText はヒールキャッシュのキーと修正提案の表示に使う
    @discardableResult
    func perform(step: FlowStep, description: String, selectorText: String? = nil,
                 file: StaticString, line: UInt) -> StepResult.Status {
        let filePath = relativePath("\(file)")
        debugCheckpoint(description: description, file: filePath, line: Int(line))
        if sceneAborted || scenarioAborted {
            let status = StepResult.Status.skipped(skipReason)
            recordStep(description: description, status: status, file: filePath, line: Int(line))
            return status
        }
        if dryRun {
            // 実機に触れず計測はほぼ 0ms だが、NDJSON 配線を検証できるよう durationMs は必ず付与する
            let clock = ContinuousClock()
            let start = clock.now
            recordStep(description: description, status: .passed, file: filePath, line: Int(line),
                       durationMs: continuousClockMilliseconds(clock.now - start))
            return .passed
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
            ?? .failed("コマンドがタイムアウトしました(\(Int(FTSync.commandTimeout))s)")
        recordStep(description: description, status: status, file: filePath, line: Int(line),
                   durationMs: outcome?.timing?.durationMs,
                   snapshotMs: outcome?.timing?.snapshotMs,
                   actionMs: outcome?.timing?.actionMs,
                   waitMs: outcome?.timing?.waitMs)

        // 修正提案とヒールキャッシュの更新
        if let outcome, let selectorText {
            if let healed = outcome.healedStep, let primary = healed.locator {
                let chain = [primary] + (healed.fallbacks ?? [])
                let newSelector = FTSelector.serialize(primary: primary,
                                                       fallbacks: healed.fallbacks ?? [])
                let rationale: String
                if outcome.healedByCache {
                    rationale = cachedEntry?.rationale ?? "前回の自己修復結果(キャッシュ)"
                } else {
                    rationale = healed.note?.components(separatedBy: "自己修復: ").last
                        ?? "FM 自己修復"
                    if let cacheKey {
                        healCache.store(cacheKey, locators: chain,
                                        newSelector: newSelector, rationale: rationale)
                    }
                }
                let via = outcome.healedByCache ? "ヒールキャッシュで通過" : "FM 自己修復で通過"
                let resolvedNewSelector = cachedEntry?.newSelector ?? newSelector
                addSuggestion(FixSuggestion(
                    isStrong: true,
                    message: "\(filePath):\(line) — セレクタ \"\(selectorText)\" を "
                        + "\"\(resolvedNewSelector)\" に変更してください"
                        + "(\(via)。理由: \(rationale))"),
                    emitEvent: true, description: description,
                    file: filePath, line: Int(line),
                    oldSelector: selectorText, newSelector: resolvedNewSelector)
            } else if case .passedViaFallback(let locator) = status {
                // 弱い提案(フォールバックは設計上の通常経路なのでレポートのみ)
                addSuggestion(FixSuggestion(
                    isStrong: false,
                    message: "\(filePath):\(line) — \"\(selectorText)\" はプライマリで解決できず "
                        + "フォールバック \(locator.summary) で通過(セレクタ更新を検討)"),
                    emitEvent: false, file: filePath, line: Int(line))
            }
        }

        if case .failed(let reason) = status {
            handleFailure(stepDescription: description, reason: reason)
        }
        return status
    }

    private func addSuggestion(_ suggestion: FixSuggestion, emitEvent: Bool,
                               description: String? = nil,
                               file: String, line: Int,
                               oldSelector: String? = nil, newSelector: String? = nil) {
        record.fixSuggestions.append(suggestion)
        guard emitEvent else { return }
        var event = ScenarioEvent(kind: "fixSuggestion")
        event.scenario = scenarioID
        event.scene = record.scenes.last?.number
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
                       abortsScenario: Bool = false,
                       _ body: @escaping () async throws -> Void) -> StepResult.Status {
        let filePath = relativePath("\(file)")
        debugCheckpoint(description: description, file: filePath, line: Int(line))
        if sceneAborted || scenarioAborted {
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
            status = .failed("処理がタイムアウトしました(\(Int(FTSync.commandTimeout))s)")
        }
        recordStep(description: description, status: status, file: "\(file)", line: Int(line),
                   durationMs: elapsedMs)

        if case .failed(let reason) = status {
            if abortsScenario { scenarioAborted = true }
            handleFailure(stepDescription: description, reason: reason)
        }
        return status
    }

    /// 停止条件に合致したら paused イベントを流してブロックし、再開コマンドを待つ。
    /// stop コマンドはシナリオ中断(以降のステップは skipped)として扱う
    private func debugCheckpoint(description: String, file: String, line: Int) {
        guard let debug = debugControl, !sceneAborted, !scenarioAborted else { return }
        let result = debug.checkpoint(file: file, line: line) {
            var event = ScenarioEvent(kind: "paused")
            event.scenario = scenarioID
            event.scene = record.scenes.last?.number
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
            emit(.log("⏹ ユーザー操作でシナリオを中断しました"))
        }
    }

    /// スキップ記録の理由(デバッグの stop による中断は表示を分ける)
    private var skipReason: String {
        stoppedByUser ? "ユーザー操作で中断" : "scene NG のため未実行"
    }

    /// 分岐評価(記録のみ、実行はしない): セレクタが現在画面で解決できるか
    func canSelect(_ selector: FTSelector, waitSeconds: Int) -> Bool {
        if dryRun { return true }  // dry-run では分岐内側も記録するため常に成立扱い
        if sceneAborted || scenarioAborted { return false }
        let step = FlowStep(locator: selector.primary,
                            fallbacks: selector.fallbacks.isEmpty ? nil : selector.fallbacks)
        let driver = self.driver
        let deadline = Date().addingTimeInterval(TimeInterval(waitSeconds))
        repeat {
            let snapshot = FTSync.run { try? await driver.snapshot() } ?? nil
            if let snapshot,
               StepExecutor.resolve(step: step, in: snapshot, strictForAssert: true) != nil {
                return true
            }
            if Date() < deadline {
                Thread.sleep(forTimeInterval: 0.5)
            }
        } while Date() < deadline
        return false
    }

    // MARK: - 記録

    /// durationMs/snapshotMs/actionMs/waitMs: ステップの時間内訳(単位ミリ秒)。
    /// StepExecutor 経由のステップ(tap/exist 等)は 4 つとも渡され、performCustom 経由
    /// (launchApp/wait/procedure 等)は durationMs のみ、それ以外(skip・dry-run 等)は
    /// 全て nil のまま(=計測なし)になる
    func recordStep(description: String, status: StepResult.Status, file: String, line: Int,
                    durationMs: Int? = nil, snapshotMs: Int? = nil,
                    actionMs: Int? = nil, waitMs: Int? = nil) {
        stepCounter += 1
        let record = DSLStepRecord(index: stepCounter, section: currentSection,
                                   description: description, status: status,
                                   file: relativePath(file), line: line, durationMs: durationMs)
        appendToCurrentScene(record)

        var event = ScenarioEvent(kind: "step")
        event.scenario = scenarioID
        event.scene = self.record.scenes.last?.number
        event.section = currentSection
        event.index = record.index
        event.description = description
        let (statusText, detail) = status.eventStatus
        event.status = statusText
        event.detail = detail
        event.file = record.file.isEmpty ? nil : record.file
        event.line = line == 0 ? nil : line
        event.durationMs = durationMs
        event.snapshotMs = snapshotMs
        event.actionMs = actionMs
        event.waitMs = waitMs
        emit(event)
    }

    private func appendToCurrentScene(_ step: DSLStepRecord) {
        if record.scenes.isEmpty {
            // scene { } の外でコマンドが呼ばれた場合の受け皿(暗黙 scene 0)
            record.scenes.append(SceneRecordData(number: 0, title: ""))
        }
        record.scenes[record.scenes.count - 1].steps.append(step)
    }

    private func handleFailure(stepDescription: String, reason: String) {
        sceneAborted = true
        if abortScenarioOnSceneFailure { scenarioAborted = true }

        // 失敗時のスクリーンショット+トリアージ(FM 利用可時のみ)
        let driver = self.driver
        let delegate = executor.delegate
        let goal = scenarioTitle.isEmpty ? scenarioID : scenarioTitle
        let context = FTSync.run { () async -> (Data?, TriageInfo?) in
            let snapshot = try? await driver.snapshot()
            let screenshot = try? await driver.screenshot()
            let triage = await delegate?.triage(goal: goal,
                                                stepDescription: stepDescription,
                                                failureReason: reason,
                                                snapshot: snapshot,
                                                screenshotPNG: screenshot)
            return (screenshot, triage)
        }
        if let (screenshot, triage) = context, !record.scenes.isEmpty {
            record.scenes[record.scenes.count - 1].failureScreenshot = screenshot
            record.scenes[record.scenes.count - 1].triage = triage
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
