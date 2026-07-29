import XCTest
@testable import FTCore

/// primary/fallback 2 台の FakeAppDriver 間で呼び出し順序を検証するための共有ログ
/// (StepExecutor は 1 タスク内で順に await するだけなので単純な配列で十分)
private final class CallLog {
    var entries: [String] = []
}

/// snapshot() はスクリプト可能(呼び出し回数ごとの要素列。列を使い切ったら最後の要素を繰り返す)。
/// tap/type/press 等その他のメソッドは記録するだけで何もしない
private final class FakeAppDriver: AppDriver {
    let name: String
    let log: CallLog
    var snapshotElements: [[ElementInfo]]
    private(set) var snapshotCallCount = 0
    /// 非 nil なら type(ref:text:) がこのエラーを throw する(409 リアクティブ切替の検証用)
    var typeError: Error?
    /// 非 nil なら swipe/press がこのエラーを throw する(501 ジェスチャ切替の検証用)
    var swipeError: Error?
    var pressError: Error?

    init(name: String, log: CallLog, snapshotElements: [[ElementInfo]] = []) {
        self.name = name
        self.log = log
        self.snapshotElements = snapshotElements
    }

    func status() async throws -> StatusResponse {
        StatusResponse(ready: true, device: name, osVersion: "-", sessionBundleID: nil)
    }

    func install(packagePath: String) async throws {}

    func launch(bundleID: String) async throws {
        log.entries.append("\(name).launch")
    }

    func snapshot() async throws -> SnapshotResponse {
        snapshotCallCount += 1
        log.entries.append("\(name).snapshot")
        let elements: [ElementInfo]
        if snapshotElements.isEmpty {
            elements = []
        } else {
            let index = min(snapshotCallCount - 1, snapshotElements.count - 1)
            elements = snapshotElements[index]
        }
        return SnapshotResponse(sessionBundleID: nil,
                                screen: FTRect(x: 0, y: 0, width: 400, height: 800),
                                elements: elements, truncatedCount: 0)
    }

    func tap(ref: Int) async throws {
        log.entries.append("\(name).tap(ref:\(ref))")
    }

    func tap(x: Double, y: Double) async throws {}

    func type(ref: Int?, text: String) async throws {
        if let typeError {
            log.entries.append("\(name).type(throws)")
            throw typeError
        }
        log.entries.append("\(name).type(ref:\(ref.map(String.init) ?? "nil"))")
    }

    func swipe(_ direction: FTSwipeDirection) async throws {
        if let swipeError {
            log.entries.append("\(name).swipe(throws)")
            throw swipeError
        }
        log.entries.append("\(name).swipe")
    }

    /// 直近の press に渡った長押し秒数(FlowStep.duration の配線確認用。ログ文言は変えない)
    private(set) var lastPressDuration: Double?

    func press(ref: Int, duration: Double) async throws {
        lastPressDuration = duration
        if let pressError {
            log.entries.append("\(name).press(throws)")
            throw pressError
        }
        log.entries.append("\(name).press(ref:\(ref))")
    }

    /// 非 nil なら drag がこのエラーを throw する(空打ちドラッグの XCUITest 切替の検証用)。
    /// **実装しないと AppDriver 既定の 501 になる**ので、フォールバック先の検証には実装が要る
    var dragError: Error?

    func drag(fromX: Double, fromY: Double, toX: Double, toY: Double,
              pressSeconds: Double, durationSeconds: Double) async throws {
        if let dragError {
            log.entries.append("\(name).drag(throws)")
            throw dragError
        }
        log.entries.append("\(name).drag")
    }

    private(set) var screenshotCallCount = 0
    func screenshot() async throws -> Data { screenshotCallCount += 1; return Data() }

    func terminate() async throws {}

    /// 非 nil なら pressEnter() がこのエラーを throw する(409 リアクティブ切替の検証用)
    var pressEnterError: Error?

    func pressEnter() async throws {
        if let pressEnterError {
            log.entries.append("\(name).pressEnter(throws)")
            throw pressEnterError
        }
        log.entries.append("\(name).pressEnter")
    }
}

/// occlusion-guard 検証用の最小 delegate。verifyElementVisible だけ意味を持たせる。
private final class FakeVisibilityDelegate: ReplayDelegate {
    let visible: Bool
    private(set) var visibleCalls = 0
    init(visible: Bool) { self.visible = visible }
    func healLocator(step: FlowStep, snapshot: SnapshotResponse) async -> HealProposal? { nil }
    func verifyScreen(expected: String, screenshotPNG: Data) async -> (pass: Bool, reason: String)? { nil }
    func triage(goal: String?, stepDescription: String, failureReason: String,
                snapshot: SnapshotResponse?, screenshotPNG: Data?) async -> TriageInfo? { nil }
    func verifyElementVisible(expectedText: String, frame: FTRect, screen: FTRect,
                              screenshotPNG: Data) async
        -> (visible: Bool, state: String, reason: String, observedText: String)? {
        visibleCalls += 1
        return (visible, visible ? "fullyVisible" : "covered", "test", "")
    }
}

/// verifyElementVisible が呼び出しごとに指定の visible 列を返す(尽きたら最後を繰り返す)。
/// 過渡的オーバーレイ(covered→visible)の poll-until-visible 検証用。
private final class SequenceVisibilityDelegate: ReplayDelegate {
    private let results: [Bool]
    private(set) var calls = 0
    init(_ results: [Bool]) { self.results = results }
    func healLocator(step: FlowStep, snapshot: SnapshotResponse) async -> HealProposal? { nil }
    func verifyScreen(expected: String, screenshotPNG: Data) async -> (pass: Bool, reason: String)? { nil }
    func triage(goal: String?, stepDescription: String, failureReason: String,
                snapshot: SnapshotResponse?, screenshotPNG: Data?) async -> TriageInfo? { nil }
    func verifyElementVisible(expectedText: String, frame: FTRect, screen: FTRect,
                              screenshotPNG: Data) async
        -> (visible: Bool, state: String, reason: String, observedText: String)? {
        let v = calls < results.count ? results[calls] : (results.last ?? true)
        calls += 1
        return (v, v ? "fullyVisible" : "covered", "test", "")
    }
}

/// screenMatches 検証用: verifyScreen が常に pass を返し、呼び出し回数を数える
/// (screenIsEnabled=false で呼ばれないことの検証用)
private final class CountingScreenDelegate: ReplayDelegate {
    private(set) var verifyScreenCalls = 0
    func healLocator(step: FlowStep, snapshot: SnapshotResponse) async -> HealProposal? { nil }
    func verifyScreen(expected: String, screenshotPNG: Data) async -> (pass: Bool, reason: String)? {
        verifyScreenCalls += 1
        return (true, "ok")
    }
    func triage(goal: String?, stepDescription: String, failureReason: String,
                snapshot: SnapshotResponse?, screenshotPNG: Data?) async -> TriageInfo? { nil }
}

final class StepExecutorTests: XCTestCase {
    /// occlusion-guard 対象になり得るテキスト要素(StaticText + 文字を含む label)
    private func textElement(id: String, label: String) -> ElementInfo {
        ElementInfo(ref: 1, type: "staticText", identifier: id, label: label, value: nil,
                    placeholder: nil, enabled: true,
                    frame: FTRect(x: 0, y: 0, width: 100, height: 20), depth: 0)
    }

    private func element(ref: Int, id: String) -> ElementInfo {
        ElementInfo(ref: ref, type: "button", identifier: id, label: nil, value: nil,
                   placeholder: nil, enabled: true,
                   frame: FTRect(x: 0, y: 0, width: 10, height: 10), depth: 0)
    }

    private func labeled(ref: Int, label: String) -> ElementInfo {
        ElementInfo(ref: ref, type: "button", identifier: nil, label: label, value: nil,
                   placeholder: nil, enabled: true,
                   frame: FTRect(x: 0, y: 0, width: 10, height: 10), depth: 0)
    }

    /// occlusionGuard 付き exists(exist の既定): delegate が「隠れ」を返すと偽陽性として失敗へ反転する
    func testOcclusionGuardFlipsWhenOccluded() async throws {
        let log = CallLog()
        let primary = FakeAppDriver(name: "primary", log: log,
                                    snapshotElements: [[textElement(id: "msg", label: "こんにちは")]])
        let delegate = FakeVisibilityDelegate(visible: false)
        let executor = StepExecutor(driver: primary, delegate: delegate)
        let step = FlowStep(assert: "exists", locator: FlowLocator(id: "msg"),
                            timeout: 1, occlusionGuard: true)

        let outcome = await executor.execute(step)

        guard case .failed(let msg) = outcome.status else {
            XCTFail("occlusion 反転で失敗を期待したが \(outcome.status) だった"); return
        }
        XCTAssertTrue(msg.contains("occlusion"), "失敗理由に occlusion を含むこと: \(msg)")
        // poll-until-visible: 覆われ続ける間は timeout まで繰り返し照合する(1回とは限らない)
        XCTAssertGreaterThanOrEqual(delegate.visibleCalls, 1)
    }

    /// occlusionGuard 付き exists: delegate が「見える」を返せば通常どおり pass
    func testOcclusionGuardPassesWhenVisible() async throws {
        let log = CallLog()
        let primary = FakeAppDriver(name: "primary", log: log,
                                    snapshotElements: [[textElement(id: "msg", label: "こんにちは")]])
        let executor = StepExecutor(driver: primary, delegate: FakeVisibilityDelegate(visible: true))
        let step = FlowStep(assert: "exists", locator: FlowLocator(id: "msg"),
                            timeout: 1, occlusionGuard: true)

        guard case .passed = await executor.execute(step).status else {
            XCTFail("可視判定で pass を期待"); return
        }
    }

    /// スクショ再利用: 操作を挟まない連続ガードでは 1 回のスクショを使い回す
    func testGuardReusesScreenshotAcrossConsecutiveAsserts() async throws {
        let log = CallLog()
        let el = textElement(id: "msg", label: "こんにちは")
        let primary = FakeAppDriver(name: "primary", log: log, snapshotElements: [[el]])
        let executor = StepExecutor(driver: primary, delegate: FakeVisibilityDelegate(visible: true))
        let step = FlowStep(assert: "exists", locator: FlowLocator(id: "msg"),
                            timeout: 1, occlusionGuard: true)

        _ = await executor.execute(step)
        _ = await executor.execute(step)

        XCTAssertEqual(primary.screenshotCallCount, 1, "連続ガードはスクショ1回に集約されるはず")
    }

    /// スクショ再利用: 間に操作(tap)が入るとキャッシュを捨てて取り直す
    func testGuardScreenshotInvalidatedByAction() async throws {
        let log = CallLog()
        let el = textElement(id: "msg", label: "こんにちは")
        let primary = FakeAppDriver(name: "primary", log: log, snapshotElements: [[el]])
        let executor = StepExecutor(driver: primary, delegate: FakeVisibilityDelegate(visible: true))
        let assertStep = FlowStep(assert: "exists", locator: FlowLocator(id: "msg"),
                                  timeout: 1, occlusionGuard: true)

        _ = await executor.execute(assertStep)
        _ = await executor.execute(FlowStep(action: "tap", locator: FlowLocator(id: "msg")))
        _ = await executor.execute(assertStep)

        XCTAssertEqual(primary.screenshotCallCount, 2, "操作を挟んだら取り直すはず")
    }

    /// #2 修正: textEquals の期待値(ユーザーリテラル)は結合 `, ` 規則を外す(句読点入りテキストを守る)
    func testEligibilityAllowsCommaInUserText() {
        // 実 label(exist)では `, ` を結合セマンティクスとして除外
        XCTAssertFalse(OcclusionEligibility.eligible(type: "staticText", label: "A, B").ok)
        // ユーザー期待値(textEquals)では除外しない
        XCTAssertTrue(OcclusionEligibility.eligible(type: "staticText", label: "Hello, World",
                                                    isUserText: true).ok)
        // 型・絵文字の規則は isUserText でも維持
        XCTAssertFalse(OcclusionEligibility.eligible(type: "button", label: "x", isUserText: true).ok)
        XCTAssertFalse(OcclusionEligibility.eligible(type: "staticText", label: "📱",
                                                     isUserText: true).ok)
    }

    /// #1 修正: フォールバックドライバ(システムUI)由来の textEquals 一致は座標系が食い違うためガードしない
    func testTextEqualsSkipsGuardForFallbackDriverMatch() async throws {
        let log = CallLog()
        let match = ElementInfo(ref: 1, type: "staticText", identifier: "msg", label: "OK",
                                value: nil, placeholder: nil, enabled: true,
                                frame: FTRect(x: 0, y: 0, width: 100, height: 20), depth: 0)
        let primary = FakeAppDriver(name: "primary", log: log, snapshotElements: [[]])   // 常に空
        let fallback = FakeAppDriver(name: "fallback", log: log, snapshotElements: [[match]])
        let delegate = SequenceVisibilityDelegate([false])   // ガードが走れば覆いで失敗させる
        let executor = StepExecutor(driver: primary, fallbackDriver: fallback, delegate: delegate)
        let step = FlowStep(assert: "textEquals", locator: FlowLocator(id: "msg"),
                            expected: "OK", timeout: 2, occlusionGuard: true)

        guard case .passed = await executor.execute(step).status else {
            XCTFail("fsnap 一致はガード無しで pass のはず"); return
        }
        XCTAssertEqual(delegate.calls, 0, "フォールバックドライバ一致では FM を呼ばない")
    }

    /// #5 修正: 覆い観測後にテキストが不一致へ変わったら、stale な occlusion でなく不一致失敗を返す
    func testTextEqualsClearsStaleOcclusionOnMismatch() async throws {
        let log = CallLog()
        func el(_ label: String) -> ElementInfo {
            ElementInfo(ref: 1, type: "staticText", identifier: "msg", label: label, value: nil,
                        placeholder: nil, enabled: true,
                        frame: FTRect(x: 0, y: 0, width: 100, height: 20), depth: 0)
        }
        // 1周目: 一致(覆い)→ 2周目以降: 不一致
        let primary = FakeAppDriver(name: "primary", log: log,
                                    snapshotElements: [[el("OK")], [el("NG")]])
        let executor = StepExecutor(driver: primary, delegate: SequenceVisibilityDelegate([false]))
        let step = FlowStep(assert: "textEquals", locator: FlowLocator(id: "msg"),
                            expected: "OK", timeout: 1, occlusionGuard: true)

        guard case .failed(let msg) = await executor.execute(step).status else {
            XCTFail("timeout で失敗するはず"); return
        }
        XCTAssertTrue(msg.contains("一致しません"), "テキスト不一致を返すこと: \(msg)")
        XCTAssertFalse(msg.contains("occlusion"), "stale な occlusion を返さないこと: \(msg)")
    }

    /// #4 修正: label セレクタの exist("Hello, World")はユーザー期待値。結合 `, ` 規則でガードを
    /// スキップせず、覆われていれば occlusion 失敗へ反転する(修正前は素通り pass していた)。
    func testExistsWithCommaLabelStillGuards() async throws {
        let log = CallLog()
        let el = ElementInfo(ref: 1, type: "staticText", identifier: nil, label: "Hello, World",
                             value: nil, placeholder: nil, enabled: true,
                             frame: FTRect(x: 0, y: 0, width: 100, height: 20), depth: 0)
        let primary = FakeAppDriver(name: "primary", log: log, snapshotElements: [[el]])
        let delegate = FakeVisibilityDelegate(visible: false)
        let executor = StepExecutor(driver: primary, delegate: delegate)
        let step = FlowStep(assert: "exists", locator: FlowLocator(label: "Hello, World"),
                            timeout: 1, occlusionGuard: true)

        guard case .failed(let msg) = await executor.execute(step).status else {
            XCTFail("ユーザーラベルの句読点でガードがスキップされ pass してしまった"); return
        }
        XCTAssertTrue(msg.contains("occlusion"), "occlusion 失敗を返すこと: \(msg)")
        XCTAssertGreaterThanOrEqual(delegate.visibleCalls, 1, "ガードが実行されること")
    }

    /// #5 修正: exist で覆い観測後に要素が消失したら、stale な occlusion でなく未発見を返す。
    func testExistsClearsStaleOcclusionOnDisappearance() async throws {
        let log = CallLog()
        let el = textElement(id: "msg", label: "こんにちは")
        // 1周目: 覆われて存在 → 2周目以降: 消失(空)
        let primary = FakeAppDriver(name: "primary", log: log, snapshotElements: [[el], []])
        let executor = StepExecutor(driver: primary, delegate: FakeVisibilityDelegate(visible: false))
        let step = FlowStep(assert: "exists", locator: FlowLocator(id: "msg"),
                            timeout: 1, occlusionGuard: true)

        guard case .failed(let msg) = await executor.execute(step).status else {
            XCTFail("timeout で失敗するはず"); return
        }
        XCTAssertTrue(msg.contains("見つかりません"), "未発見を返すこと: \(msg)")
        XCTAssertFalse(msg.contains("occlusion"), "stale な occlusion を返さないこと: \(msg)")
    }

    /// timeout==0 の exist は「初回照会のみ・リトライなし」。0回照会で必ず失敗する回帰を防ぐ
    /// (存在する要素は 1 回の照会で pass する)。
    func testExistsTimeoutZeroChecksOnce() async throws {
        let log = CallLog()
        let primary = FakeAppDriver(name: "primary", log: log,
                                    snapshotElements: [[textElement(id: "msg", label: "こんにちは")]])
        let executor = StepExecutor(driver: primary)
        let step = FlowStep(assert: "exists", locator: FlowLocator(id: "msg"), timeout: 0)

        guard case .passed = await executor.execute(step).status else {
            XCTFail("timeout==0 でも初回照会で存在すれば pass のはず(0回照会の回帰)"); return
        }
        XCTAssertEqual(primary.snapshotCallCount, 1, "初回照会は1回だけ")
    }

    /// scrollTo に負の maxSwipes が来ても 0...(-1) で trap せず、初回照会で存在すれば pass する。
    func testScrollToNegativeMaxSwipesDoesNotTrap() async throws {
        let log = CallLog()
        let primary = FakeAppDriver(name: "primary", log: log,
                                    snapshotElements: [[textElement(id: "msg", label: "こんにちは")]])
        let executor = StepExecutor(driver: primary)
        let step = FlowStep(action: "scrollTo", locator: FlowLocator(id: "msg"), maxSwipes: -1)

        guard case .passed = await executor.execute(step).status else {
            XCTFail("負の maxSwipes でも trap せず初回発見で pass のはず"); return
        }
    }

    /// textIs(occlusionGuard 既定)も同じガードを通る: 一致しても覆われていれば失敗へ反転
    func testOcclusionGuardOnTextEquals() async throws {
        let log = CallLog()
        let el = textElement(id: "msg", label: "合致")
        let primary = FakeAppDriver(name: "primary", log: log, snapshotElements: [[el]])
        let executor = StepExecutor(driver: primary, delegate: SequenceVisibilityDelegate([false]))
        let step = FlowStep(assert: "textEquals", locator: FlowLocator(id: "msg"),
                            expected: "合致", timeout: 1, occlusionGuard: true)

        guard case .failed(let msg) = await executor.execute(step).status else {
            XCTFail("一致かつ覆われ=occlusion 失敗のはず"); return
        }
        XCTAssertTrue(msg.contains("occlusion"), "occlusion 失敗を返すこと: \(msg)")
    }

    /// occlusionGuardEnabled=false(実行プロファイルの falsePositiveCheck:false)は per-step の
    /// occlusionGuard:true より優先して occlusion-guard 自体を止める(FM を呼ばず pass)
    func testOcclusionGuardMasterSwitchOffSkipsGuard() async throws {
        let log = CallLog()
        let primary = FakeAppDriver(name: "primary", log: log,
                                    snapshotElements: [[textElement(id: "msg", label: "こんにちは")]])
        let delegate = FakeVisibilityDelegate(visible: false)
        let executor = StepExecutor(driver: primary, delegate: delegate,
                                    occlusionGuardEnabled: false)
        let step = FlowStep(assert: "exists", locator: FlowLocator(id: "msg"),
                            timeout: 1, occlusionGuard: true)

        guard case .passed = await executor.execute(step).status else {
            XCTFail("マスタースイッチ OFF ならツリー一致だけで pass のはず"); return
        }
        XCTAssertEqual(delegate.visibleCalls, 0, "マスタースイッチ OFF で FM を呼んではいけない")
    }

    /// screenIsEnabled=false(実行プロファイルの screenIs:false)は screenMatches を skip し、
    /// delegate の verifyScreen を呼ばない
    func testScreenMatchesSkippedWhenScreenIsDisabled() async throws {
        let log = CallLog()
        let primary = FakeAppDriver(name: "primary", log: log)
        let delegate = CountingScreenDelegate()
        let executor = StepExecutor(driver: primary, delegate: delegate, screenIsEnabled: false)
        let step = FlowStep(assert: "screenMatches", expected: "ホーム画面")

        guard case .skipped(let msg) = await executor.execute(step).status else {
            XCTFail("screenIs 無効なら skip のはず"); return
        }
        XCTAssertTrue(msg.contains("screenIs が無効"), "skip 理由に無効化を明示すること: \(msg)")
        XCTAssertEqual(delegate.verifyScreenCalls, 0, "無効時は verifyScreen を呼んではいけない")
        XCTAssertEqual(primary.screenshotCallCount, 0, "無効時はスクショも撮らないはず")
    }

    /// screenIsEnabled 既定(true)では screenMatches が delegate の判定どおりに動く(退行検知)
    func testScreenMatchesRunsWhenScreenIsEnabled() async throws {
        let log = CallLog()
        let primary = FakeAppDriver(name: "primary", log: log)
        let delegate = CountingScreenDelegate()
        let executor = StepExecutor(driver: primary, delegate: delegate)
        let step = FlowStep(assert: "screenMatches", expected: "ホーム画面")

        guard case .passed = await executor.execute(step).status else {
            XCTFail("delegate が pass を返せば pass のはず"); return
        }
        XCTAssertEqual(delegate.verifyScreenCalls, 1)
    }

    /// 素の exist(occlusionGuard 未指定)は、隠れ判定 delegate が居ても FM を呼ばず pass(オプトイン)
    func testPlainExistsNeverInvokesGuard() async throws {
        let log = CallLog()
        let primary = FakeAppDriver(name: "primary", log: log,
                                    snapshotElements: [[textElement(id: "msg", label: "こんにちは")]])
        let delegate = FakeVisibilityDelegate(visible: false)
        let executor = StepExecutor(driver: primary, delegate: delegate)
        let step = FlowStep(assert: "exists", locator: FlowLocator(id: "msg"), timeout: 1)

        guard case .passed = await executor.execute(step).status else {
            XCTFail("ガード無効の exist は pass のはず"); return
        }
        XCTAssertEqual(delegate.visibleCalls, 0, "occlusionGuard 未指定で FM を呼んではいけない")
    }

    /// poll-until-visible: 最初は覆われ(covered)、後で可視になる過渡的オーバーレイは、即失敗せず
    /// timeout まで待って pass する
    func testOcclusionGuardWaitsOutTransientOverlay() async throws {
        let log = CallLog()
        let primary = FakeAppDriver(name: "primary", log: log,
                                    snapshotElements: [[textElement(id: "msg", label: "こんにちは")]])
        let delegate = SequenceVisibilityDelegate([false, true])   // 覆い → 可視
        let executor = StepExecutor(driver: primary, delegate: delegate)
        let step = FlowStep(assert: "exists", locator: FlowLocator(id: "msg"),
                            timeout: 3, occlusionGuard: true)

        guard case .passed = await executor.execute(step).status else {
            XCTFail("過渡的な覆いは待って pass するはず"); return
        }
        XCTAssertGreaterThanOrEqual(delegate.calls, 2, "少なくとも covered→visible の 2 回照合すること")
    }

    /// poll-until-visible: 覆われ続ける場合は timeout で occlusion 失敗を返す
    func testOcclusionGuardFailsIfCoveredUntilTimeout() async throws {
        let log = CallLog()
        let primary = FakeAppDriver(name: "primary", log: log,
                                    snapshotElements: [[textElement(id: "msg", label: "こんにちは")]])
        let executor = StepExecutor(driver: primary, delegate: SequenceVisibilityDelegate([false]))
        let step = FlowStep(assert: "exists", locator: FlowLocator(id: "msg"),
                            timeout: 1, occlusionGuard: true)

        guard case .failed(let msg) = await executor.execute(step).status else {
            XCTFail("覆われ続けたら失敗するはず"); return
        }
        XCTAssertTrue(msg.contains("occlusion"), "occlusion 失敗を返すこと: \(msg)")
    }

    /// exists のフォールバック照会は 2・4・6…回目の primary ミスでのみ発生する(間引き契約。
    /// StepExecutor.swift executeAssert "exists" 参照)
    func testExistsThrottlesFallbackQuery() async throws {
        let log = CallLog()
        let primary = FakeAppDriver(name: "primary", log: log, snapshotElements: [[]])
        let fallback = FakeAppDriver(name: "fallback", log: log, snapshotElements: [[]])
        let executor = StepExecutor(driver: primary, fallbackDriver: fallback)
        let step = FlowStep(assert: "exists", locator: FlowLocator(id: "target"), timeout: 1)

        let outcome = await executor.execute(step)

        guard case .failed = outcome.status else {
            XCTFail("要素なしでの timeout 切れを期待したが \(outcome.status) だった")
            return
        }
        let primaryCount = log.entries.filter { $0 == "primary.snapshot" }.count
        let fallbackCount = log.entries.filter { $0 == "fallback.snapshot" }.count
        XCTAssertGreaterThan(primaryCount, 0)
        XCTAssertLessThanOrEqual(fallbackCount, (primaryCount + 1) / 2)
        XCTAssertFalse(log.entries.prefix(2).contains("fallback.snapshot"),
                       "初回 primary ミス直後に fallback を照会してはいけない: \(log.entries)")
    }

    /// primary に無く fallback に最初から要素がある場合、primary の2回目のミス
    /// (間引きの最初の照会タイミング)で解決すること
    func testExistsResolvesViaFallbackOnSecondPrimaryMiss() async throws {
        let log = CallLog()
        let primary = FakeAppDriver(name: "primary", log: log, snapshotElements: [[]])
        let fallback = FakeAppDriver(name: "fallback", log: log,
                                     snapshotElements: [[element(ref: 1, id: "target")]])
        let executor = StepExecutor(driver: primary, fallbackDriver: fallback)
        let step = FlowStep(assert: "exists", locator: FlowLocator(id: "target"), timeout: 1)

        let outcome = await executor.execute(step)

        // id が step.locator(primary 位置)に一致するため resolve は fallback=nil を返し
        // .passed になる(.passedViaFallback は step.fallbacks 経由で解決した場合のみ)
        guard case .passed = outcome.status else {
            XCTFail("id 一致による解決を期待したが \(outcome.status) だった")
            return
        }
        XCTAssertEqual(primary.snapshotCallCount, 2)
        XCTAssertEqual(fallback.snapshotCallCount, 1)
    }

    /// tap(optional: true, timeout: 0): ロケータ再試行は行わないが、driver フォールバックの
    /// 1回照会(hybrid の optional 解決に必須)は timeout: 0 でも必ず行われる
    func testTapOptionalWithZeroTimeoutSkipsRetryButQueriesFallbackOnce() async throws {
        let log = CallLog()
        let primary = FakeAppDriver(name: "primary", log: log, snapshotElements: [[]])
        let fallback = FakeAppDriver(name: "fallback", log: log, snapshotElements: [[]])
        let executor = StepExecutor(driver: primary, fallbackDriver: fallback)
        let step = FlowStep(action: "tap", locator: FlowLocator(id: "target"),
                            timeout: 0, optional: true)

        let outcome = await executor.execute(step)

        guard case .skipped = outcome.status else {
            XCTFail("optional な要素なしでの skip を期待したが \(outcome.status) だった")
            return
        }
        XCTAssertEqual(primary.snapshotCallCount, 1)
        XCTAssertEqual(fallback.snapshotCallCount, 1)
        XCTAssertLessThanOrEqual(outcome.timing?.waitMs ?? 0, 5)
    }

    /// 回帰ガード: step.timeout が nil(省略)のときアクションは従来どおり
    /// 初回+3回リトライ(計4回スナップショット)のまま変わらないこと
    func testTapWithNilTimeoutKeepsLegacyThreeRetries() async throws {
        let log = CallLog()
        let primary = FakeAppDriver(name: "primary", log: log, snapshotElements: [[]])
        let executor = StepExecutor(driver: primary)
        let step = FlowStep(action: "tap", locator: FlowLocator(id: "target"), optional: true)

        let outcome = await executor.execute(step)

        guard case .skipped = outcome.status else {
            XCTFail("optional な要素なしでの skip を期待したが \(outcome.status) だった")
            return
        }
        XCTAssertEqual(primary.snapshotCallCount, 4)
    }

    // MARK: - 施策3: substring 偽陽性の fallback exact 上書き(tap アクション経路)

    /// primary が label 部分一致(substring)でしか解決できないとき、fallback に完全一致(exact)が
    /// あれば fallback で act する(in-app label がシステム UI label の部分文字列 → 偽陽性の抑止)
    func testTapPrefersFallbackExactOverPrimarySubstring() async throws {
        let log = CallLog()
        // primary: "ログイン" を含むが完全一致でない(部分一致のみ)
        let primary = FakeAppDriver(name: "primary", log: log,
                                    snapshotElements: [[labeled(ref: 1, label: "ログインに失敗しました")]])
        // fallback: "ログイン" の完全一致
        let fallback = FakeAppDriver(name: "fallback", log: log,
                                     snapshotElements: [[labeled(ref: 2, label: "ログイン")]])
        let executor = StepExecutor(driver: primary, fallbackDriver: fallback)
        // 部分一致は記法で明示する(素の "ログイン" は完全一致なので primary に当たらない)
        let step = FlowStep(action: "tap",
                            locator: FlowLocator(label: "ログイン", labelMatch: .contains))

        let outcome = await executor.execute(step)

        guard case .passed = outcome.status else {
            XCTFail("fallback exact 解決での passed を期待したが \(outcome.status) だった")
            return
        }
        XCTAssertTrue(log.entries.contains("fallback.tap(ref:2)"),
                      "fallback の exact 要素で act すべき: \(log.entries)")
        XCTAssertFalse(log.entries.contains("primary.tap(ref:1)"),
                       "primary の substring 要素で act してはいけない(偽陽性): \(log.entries)")
    }

    /// primary が substring 一致で fallback に exact が無ければ、primary の substring 一致で act する
    /// (fallback は1回照会するが上書きしない)
    func testTapKeepsPrimarySubstringWhenFallbackHasNoExact() async throws {
        let log = CallLog()
        let primary = FakeAppDriver(name: "primary", log: log,
                                    snapshotElements: [[labeled(ref: 1, label: "ログインに失敗しました")]])
        let fallback = FakeAppDriver(name: "fallback", log: log, snapshotElements: [[]])
        let executor = StepExecutor(driver: primary, fallbackDriver: fallback)
        let step = FlowStep(action: "tap",
                            locator: FlowLocator(label: "ログイン", labelMatch: .contains))

        let outcome = await executor.execute(step)

        guard case .passed = outcome.status else {
            XCTFail("primary substring 解決での passed を期待したが \(outcome.status) だった")
            return
        }
        XCTAssertTrue(log.entries.contains("primary.tap(ref:1)"),
                      "fallback に exact が無ければ primary substring で act すべき: \(log.entries)")
        XCTAssertEqual(fallback.snapshotCallCount, 1, "substring 一致では fallback を1回照会する")
    }

    /// primary が完全一致(exact)のときは fallback を一切照会しない(コスト増を避ける契約)
    func testTapExactPrimaryNeverQueriesFallback() async throws {
        let log = CallLog()
        let primary = FakeAppDriver(name: "primary", log: log,
                                    snapshotElements: [[labeled(ref: 1, label: "ログイン")]])
        let fallback = FakeAppDriver(name: "fallback", log: log,
                                     snapshotElements: [[labeled(ref: 2, label: "ログイン")]])
        let executor = StepExecutor(driver: primary, fallbackDriver: fallback)
        let step = FlowStep(action: "tap", locator: FlowLocator(label: "ログイン"))

        let outcome = await executor.execute(step)

        guard case .passed = outcome.status else {
            XCTFail("primary exact 解決での passed を期待したが \(outcome.status) だった")
            return
        }
        XCTAssertEqual(fallback.snapshotCallCount, 0, "primary exact のとき fallback は照会しない")
        XCTAssertTrue(log.entries.contains("primary.tap(ref:1)"), "primary で act すべき: \(log.entries)")
    }

    /// primary に要素があれば fallbackDriver は一度も呼ばれないこと
    func testExistsResolvedByPrimaryNeverQueriesFallback() async throws {
        let log = CallLog()
        let primary = FakeAppDriver(name: "primary", log: log,
                                    snapshotElements: [[element(ref: 1, id: "target")]])
        let fallback = FakeAppDriver(name: "fallback", log: log, snapshotElements: [[]])
        let executor = StepExecutor(driver: primary, fallbackDriver: fallback)
        let step = FlowStep(assert: "exists", locator: FlowLocator(id: "target"), timeout: 1)

        let outcome = await executor.execute(step)

        guard case .passed = outcome.status else {
            XCTFail("primary 即解決での passed を期待したが \(outcome.status) だった")
            return
        }
        XCTAssertEqual(fallback.snapshotCallCount, 0)
    }

    // MARK: - type の XCUITest ルーティング

    /// preferTypeDriver(Compose 検出)時は primary を試さず typeDriver で type すること
    func testTypePrefersTypeDriverWhenComposeDetected() async throws {
        let log = CallLog()
        let primary = FakeAppDriver(name: "primary", log: log,
                                    snapshotElements: [[element(ref: 1, id: "field_email")]])
        let typeDriver = FakeAppDriver(name: "typedriver", log: log,
                                       snapshotElements: [[element(ref: 2, id: "field_email")]])
        let executor = StepExecutor(driver: primary, typeDriver: typeDriver, preferTypeDriver: true)
        let step = FlowStep(action: "type", locator: FlowLocator(id: "field_email"), text: "hi")

        let outcome = await executor.execute(step)

        guard case .passed = outcome.status else {
            XCTFail("typeDriver 経由での passed を期待したが \(outcome.status) だった")
            return
        }
        guard let snapIdx = log.entries.firstIndex(of: "typedriver.snapshot"),
              let typeIdx = log.entries.firstIndex(of: "typedriver.type(ref:2)") else {
            XCTFail("typedriver.snapshot → typedriver.type(ref:2) が見当たらない: \(log.entries)")
            return
        }
        XCTAssertLessThan(snapIdx, typeIdx)
        XCTAssertFalse(log.entries.contains { $0.hasPrefix("primary.type") },
                       "primary.type が呼ばれてはいけない: \(log.entries)")
    }

    /// preferTypeDriver でも typeDriver 側で解決できなければ primary(通常経路)へ落とすこと
    func testTypeFallsToPrimaryWhenTypeDriverCannotResolve() async throws {
        let log = CallLog()
        let primary = FakeAppDriver(name: "primary", log: log,
                                    snapshotElements: [[element(ref: 1, id: "field_email")]])
        let typeDriver = FakeAppDriver(name: "typedriver", log: log, snapshotElements: [[]])
        let executor = StepExecutor(driver: primary, typeDriver: typeDriver, preferTypeDriver: true)
        let step = FlowStep(action: "type", locator: FlowLocator(id: "field_email"), text: "hi")

        let outcome = await executor.execute(step)

        guard case .passed = outcome.status else {
            XCTFail("primary フォールバックでの passed を期待したが \(outcome.status) だった")
            return
        }
        XCTAssertTrue(log.entries.contains("primary.type(ref:1)"),
                      "typeDriver が解決できないとき primary.type すべき: \(log.entries)")
    }

    // MARK: - type の "\n" 振り分け(iOS Return 既定挙動への統一)

    /// ロケータ有り: text に "\n" を含めば preferTypeDriver=false でも typeDriver を優先すること
    func testTypeRoutesToTypeDriverWhenTextContainsNewline() async throws {
        let log = CallLog()
        let primary = FakeAppDriver(name: "primary", log: log,
                                    snapshotElements: [[element(ref: 1, id: "field_note")]])
        let typeDriver = FakeAppDriver(name: "typedriver", log: log,
                                       snapshotElements: [[element(ref: 2, id: "field_note")]])
        let executor = StepExecutor(driver: primary, typeDriver: typeDriver, preferTypeDriver: false)
        let step = FlowStep(action: "type", locator: FlowLocator(id: "field_note"), text: "hi\n")

        let outcome = await executor.execute(step)

        guard case .passed = outcome.status else {
            XCTFail("typeDriver 経由での passed を期待したが \(outcome.status) だった")
            return
        }
        XCTAssertTrue(log.entries.contains("typedriver.type(ref:2)"))
        XCTAssertFalse(log.entries.contains { $0.hasPrefix("primary.type") },
                       "\\n を含む text は primary を試さず typeDriver へ回すべき: \(log.entries)")
    }

    /// ロケータ有り: text に "\n" が無ければ preferTypeDriver=false のとき従来どおり primary を使うこと
    func testTypeUsesPrimaryWhenTextHasNoNewline() async throws {
        let log = CallLog()
        let primary = FakeAppDriver(name: "primary", log: log,
                                    snapshotElements: [[element(ref: 1, id: "field_note")]])
        let typeDriver = FakeAppDriver(name: "typedriver", log: log,
                                       snapshotElements: [[element(ref: 2, id: "field_note")]])
        let executor = StepExecutor(driver: primary, typeDriver: typeDriver, preferTypeDriver: false)
        let step = FlowStep(action: "type", locator: FlowLocator(id: "field_note"), text: "hi")

        let outcome = await executor.execute(step)

        guard case .passed = outcome.status else {
            XCTFail("primary 経由での passed を期待したが \(outcome.status) だった")
            return
        }
        XCTAssertTrue(log.entries.contains("primary.type(ref:1)"))
        XCTAssertFalse(log.entries.contains { $0.hasPrefix("typedriver.type") },
                       "\\n を含まない text で typeDriver を照会してはいけない: \(log.entries)")
    }

    /// ロケータ無し: text に "\n" を含み typeDriver があれば typeDriver(ref: nil)へ回すこと。
    /// snapshot を挟まない経路なので呼び出しは type 単発のみ
    func testTypeWithoutLocatorRoutesToTypeDriverWhenTextContainsNewline() async throws {
        let log = CallLog()
        let primary = FakeAppDriver(name: "primary", log: log)
        let typeDriver = FakeAppDriver(name: "typedriver", log: log)
        let executor = StepExecutor(driver: primary, typeDriver: typeDriver)
        let step = FlowStep(action: "type", text: "hi\n")

        let outcome = await executor.execute(step)

        guard case .passed = outcome.status else {
            XCTFail("typeDriver 経由での passed を期待したが \(outcome.status) だった")
            return
        }
        XCTAssertEqual(log.entries, ["typedriver.type(ref:nil)"],
                       "ロケータ無し + \\n は typeDriver(ref: nil)へ直接回すべき: \(log.entries)")
    }

    /// ロケータ無し: typeDriver が無い(Android 相当)なら "\n" を含んでいても primary へ素通しすること
    func testTypeWithoutLocatorUsesPrimaryWhenNoTypeDriver() async throws {
        let log = CallLog()
        let primary = FakeAppDriver(name: "primary", log: log)
        let executor = StepExecutor(driver: primary)
        let step = FlowStep(action: "type", text: "hi\n")

        let outcome = await executor.execute(step)

        guard case .passed = outcome.status else {
            XCTFail("primary 経由での passed を期待したが \(outcome.status) だった")
            return
        }
        XCTAssertEqual(log.entries, ["primary.type(ref:nil)"],
                       "typeDriver 無しでは \\n を含んでいても primary へ素通しすべき: \(log.entries)")
    }

    /// 文中(末尾でない)の "\n" でも typeDriver へ回ること(末尾限定のロジックにしない)
    func testTypeRoutesToTypeDriverWhenNewlineIsMidString() async throws {
        let log = CallLog()
        let primary = FakeAppDriver(name: "primary", log: log,
                                    snapshotElements: [[element(ref: 1, id: "field_note")]])
        let typeDriver = FakeAppDriver(name: "typedriver", log: log,
                                       snapshotElements: [[element(ref: 2, id: "field_note")]])
        let executor = StepExecutor(driver: primary, typeDriver: typeDriver, preferTypeDriver: false)
        let step = FlowStep(action: "type", locator: FlowLocator(id: "field_note"), text: "line1\nline2")

        let outcome = await executor.execute(step)

        guard case .passed = outcome.status else {
            XCTFail("typeDriver 経由での passed を期待したが \(outcome.status) だった")
            return
        }
        XCTAssertTrue(log.entries.contains("typedriver.type(ref:2)"))
        XCTAssertFalse(log.entries.contains { $0.hasPrefix("primary.type") },
                       "文中の \\n でも typeDriver へ回すべき(末尾限定ではない): \(log.entries)")
    }

    // MARK: - ジェスチャのドライバフォールバック(Compose)

    /// 501(このエンジンでは未対応)なら swipe を typeDriver へ切り替え、driverFallback を記録すること
    func testSwipe501FallsBackToTypeDriver() async throws {
        let log = CallLog()
        let primary = FakeAppDriver(name: "primary", log: log)
        primary.swipeError = DriverError.badResponse(status: 501, body: "compose では swipe が効きません")
        let typeDriver = FakeAppDriver(name: "typedriver", log: log)
        let executor = StepExecutor(driver: primary, typeDriver: typeDriver)

        let outcome = await executor.execute(FlowStep(action: "swipe", direction: "up"))

        guard case .passed = outcome.status else {
            XCTFail("501 からの切替で passed を期待したが \(outcome.status) だった")
            return
        }
        XCTAssertEqual(outcome.driverFallback, "XCUITest へフォールバック")
        XCTAssertEqual(log.entries, ["primary.swipe(throws)", "typedriver.swipe"])
    }

    /// 409(キーウィンドウ不在等の一時的な競合)ではジェスチャを切り替えないこと。
    /// 切り替えると「アプリが前面に無い」状況を隠して別画面を操作しかねない
    func testSwipe409DoesNotFallBack() async throws {
        let log = CallLog()
        let primary = FakeAppDriver(name: "primary", log: log)
        primary.swipeError = DriverError.badResponse(status: 409, body: "キーウィンドウがありません")
        let typeDriver = FakeAppDriver(name: "typedriver", log: log)
        let executor = StepExecutor(driver: primary, typeDriver: typeDriver)

        let outcome = await executor.execute(FlowStep(action: "swipe", direction: "up"))

        guard case .failed = outcome.status else {
            XCTFail("409 は失敗のままを期待したが \(outcome.status) だった")
            return
        }
        XCTAssertNil(outcome.driverFallback)
        XCTAssertEqual(log.entries, ["primary.swipe(throws)"], "typeDriver を呼んではいけない")
    }

    /// typeDriverGestures に swipe が申告されていれば 501 を待たず最初から typeDriver で撃つこと
    func testTypeDriverGesturesRoutesSwipeUpfront() async throws {
        let log = CallLog()
        let primary = FakeAppDriver(name: "primary", log: log)
        let typeDriver = FakeAppDriver(name: "typedriver", log: log)
        let executor = StepExecutor(driver: primary, typeDriver: typeDriver,
                                    typeDriverGestures: ["swipe", "press"])

        let outcome = await executor.execute(FlowStep(action: "swipe", direction: "up"))

        XCTAssertEqual(outcome.driverFallback, "XCUITest へフォールバック")
        XCTAssertEqual(log.entries, ["typedriver.swipe"], "primary を無駄打ちしてはいけない")
    }

    /// **アクション別ルーティング**: press だけの申告(uikit)で swipe まで typeDriver へ回さないこと。
    /// 一括 Bool だった頃、press の申告だけで scrollTo の swipe が XCUITest 実スワイプ化し、
    /// バウンス由来の非決定性で下端の行タップが flake した(2026-07-23 実害)。
    func testPressOnlyDeclarationKeepsSwipeOnPrimary() async throws {
        let log = CallLog()
        let primary = FakeAppDriver(name: "primary", log: log)
        let typeDriver = FakeAppDriver(name: "typedriver", log: log)
        let executor = StepExecutor(driver: primary, typeDriver: typeDriver,
                                    typeDriverGestures: ["press"])

        let outcome = await executor.execute(FlowStep(action: "swipe", direction: "up"))

        XCTAssertNil(outcome.driverFallback, "press だけの申告で swipe を typeDriver へ回さない")
        XCTAssertEqual(log.entries, ["primary.swipe"], "swipe は primary(in-app)で実行するはず")
    }

    /// press の 501 切替は ref を typeDriver 側 snapshot で取り直すこと(ref はブリッジごとに別名前空間)
    func testPress501FallsBackAndReresolvesRef() async throws {
        let log = CallLog()
        let primary = FakeAppDriver(name: "primary", log: log,
                                    snapshotElements: [[element(ref: 1, id: "btn_long")]])
        primary.pressError = DriverError.badResponse(status: 501, body: "compose では press が効きません")
        let typeDriver = FakeAppDriver(name: "typedriver", log: log,
                                       snapshotElements: [[element(ref: 9, id: "btn_long")]])
        let executor = StepExecutor(driver: primary, typeDriver: typeDriver)
        let step = FlowStep(action: "press", locator: FlowLocator(id: "btn_long"))

        let outcome = await executor.execute(step)

        guard case .passed = outcome.status else {
            XCTFail("501 からの切替で passed を期待したが \(outcome.status) だった")
            return
        }
        XCTAssertEqual(outcome.driverFallback, "XCUITest へフォールバック")
        XCTAssertEqual(log.entries, [
            "primary.snapshot",
            "primary.press(throws)",
            "typedriver.snapshot",
            "typedriver.press(ref:9)",
        ], "typeDriver 側の ref(9)で press すべき")
    }

    /// FlowStep.duration は主経路にもフォールバック経路にも届くこと(旧実装は両方 1.0 固定で、
    /// DSL の press(duration:)と拡張のパラメーター編集が黙って無効化されていた)
    func testPressDurationIsPassedThroughBothPaths() async throws {
        let log = CallLog()
        let primary = FakeAppDriver(name: "primary", log: log,
                                    snapshotElements: [[element(ref: 1, id: "btn_long")]])
        let executor = StepExecutor(driver: primary)
        _ = await executor.execute(
            FlowStep(action: "press", locator: FlowLocator(id: "btn_long"), duration: 3.5))
        XCTAssertEqual(primary.lastPressDuration, 3.5)

        let fallbackLog = CallLog()
        let failing = FakeAppDriver(name: "primary", log: fallbackLog,
                                    snapshotElements: [[element(ref: 1, id: "btn_long")]])
        failing.pressError = DriverError.badResponse(status: 501, body: "compose では press が効きません")
        let typeDriver = FakeAppDriver(name: "typedriver", log: fallbackLog,
                                       snapshotElements: [[element(ref: 9, id: "btn_long")]])
        let fallbackExecutor = StepExecutor(driver: failing, typeDriver: typeDriver)
        _ = await fallbackExecutor.execute(
            FlowStep(action: "press", locator: FlowLocator(id: "btn_long"), duration: 3.5))
        XCTAssertEqual(typeDriver.lastPressDuration, 3.5)
    }

    /// 未指定なら既定秒数に落ちること
    func testPressDurationDefaultsWhenUnset() async throws {
        let log = CallLog()
        let primary = FakeAppDriver(name: "primary", log: log,
                                    snapshotElements: [[element(ref: 1, id: "btn_long")]])
        let executor = StepExecutor(driver: primary)
        _ = await executor.execute(FlowStep(action: "press", locator: FlowLocator(id: "btn_long")))
        XCTAssertEqual(primary.lastPressDuration, FlowStep.defaultPressDuration)
    }

    /// 409(inapp が非 UIKit 入力欄で first responder を張れない)はリアクティブに typeDriver へ切り替えること。
    /// ドライバが変わっただけでセレクタは正しいので、ロケータの passedViaFallback ではなく
    /// driverFallback 注記になる(誤ったセレクタ更新提案を防ぐ)。
    func testType409FallsBackToTypeDriverReactively() async throws {
        let log = CallLog()
        let primary = FakeAppDriver(name: "primary", log: log,
                                    snapshotElements: [[element(ref: 1, id: "field_email")]])
        primary.typeError = DriverError.badResponse(status: 409, body: "no first responder")
        let typeDriver = FakeAppDriver(name: "typedriver", log: log,
                                       snapshotElements: [[element(ref: 2, id: "field_email")]])
        let executor = StepExecutor(driver: primary, typeDriver: typeDriver, preferTypeDriver: false)
        let step = FlowStep(action: "type", locator: FlowLocator(id: "field_email"), text: "hi")

        let outcome = await executor.execute(step)

        guard case .passed = outcome.status else {
            XCTFail("409 からの typeDriver 切替による passed を期待したが \(outcome.status) だった")
            return
        }
        XCTAssertEqual(outcome.driverFallback, "XCUITest へフォールバック")
        XCTAssertEqual(log.entries, [
            "primary.snapshot",
            "primary.type(throws)",
            "typedriver.snapshot",
            "typedriver.type(ref:2)",
        ])
    }

    /// 409 以外のエラーは typeDriver へ切り替えず、そのまま失敗させること
    func testTypeNon409DoesNotUseTypeDriver() async throws {
        let log = CallLog()
        let primary = FakeAppDriver(name: "primary", log: log,
                                    snapshotElements: [[element(ref: 1, id: "field_email")]])
        primary.typeError = DriverError.badResponse(status: 500, body: "server error")
        let typeDriver = FakeAppDriver(name: "typedriver", log: log,
                                       snapshotElements: [[element(ref: 2, id: "field_email")]])
        let executor = StepExecutor(driver: primary, typeDriver: typeDriver, preferTypeDriver: false)
        let step = FlowStep(action: "type", locator: FlowLocator(id: "field_email"), text: "hi")

        let outcome = await executor.execute(step)

        guard case .failed = outcome.status else {
            XCTFail("409 以外は失敗のままを期待したが \(outcome.status) だった")
            return
        }
        XCTAssertFalse(log.entries.contains { $0.hasPrefix("typedriver") },
                       "409 以外で typeDriver を照会してはいけない: \(log.entries)")
    }

    /// typeDriver が無い場合、409 はそのまま伝播して失敗させること
    func testType409WithoutTypeDriverPropagates() async throws {
        let log = CallLog()
        let primary = FakeAppDriver(name: "primary", log: log,
                                    snapshotElements: [[element(ref: 1, id: "field_email")]])
        primary.typeError = DriverError.badResponse(status: 409, body: "no first responder")
        let executor = StepExecutor(driver: primary)
        let step = FlowStep(action: "type", locator: FlowLocator(id: "field_email"), text: "hi")

        let outcome = await executor.execute(step)

        guard case .failed = outcome.status else {
            XCTFail("typeDriver 無しでの 409 失敗を期待したが \(outcome.status) だった")
            return
        }
    }

    // MARK: - pressEnter(ロケータ無し。type(ref: nil) と同じくロケータ解決を挟まない経路)

    func testPressEnterCallsDriverDirectlyWithoutSnapshot() async throws {
        let log = CallLog()
        let primary = FakeAppDriver(name: "primary", log: log)
        let executor = StepExecutor(driver: primary)
        let step = FlowStep(action: "pressEnter")

        let outcome = await executor.execute(step)

        guard case .passed = outcome.status else {
            XCTFail("pressEnter の passed を期待したが \(outcome.status) だった")
            return
        }
        XCTAssertEqual(log.entries, ["primary.pressEnter"], "ロケータ解決(snapshot)を挟んではいけない")
    }

    /// 409(inapp が Compose 以外の入力欄/フォーカス無しで返す)はリアクティブに typeDriver へ
    /// 切り替えること(type の 409 フォールバックと同じ形)
    func testPressEnter409FallsBackToTypeDriverReactively() async throws {
        let log = CallLog()
        let primary = FakeAppDriver(name: "primary", log: log)
        primary.pressEnterError = DriverError.badResponse(status: 409, body: "not compose")
        let typeDriver = FakeAppDriver(name: "typedriver", log: log)
        let executor = StepExecutor(driver: primary, typeDriver: typeDriver)
        let step = FlowStep(action: "pressEnter")

        let outcome = await executor.execute(step)

        guard case .passed = outcome.status else {
            XCTFail("409 からの typeDriver 切替による passed を期待したが \(outcome.status) だった")
            return
        }
        XCTAssertEqual(outcome.driverFallback, "XCUITest へフォールバック")
        XCTAssertEqual(log.entries, ["primary.pressEnter(throws)", "typedriver.pressEnter"])
    }

    /// 409 以外のエラーは typeDriver へ切り替えず、そのまま失敗させること
    func testPressEnterNon409DoesNotUseTypeDriver() async throws {
        let log = CallLog()
        let primary = FakeAppDriver(name: "primary", log: log)
        primary.pressEnterError = DriverError.badResponse(status: 500, body: "server error")
        let typeDriver = FakeAppDriver(name: "typedriver", log: log)
        let executor = StepExecutor(driver: primary, typeDriver: typeDriver)
        let step = FlowStep(action: "pressEnter")

        let outcome = await executor.execute(step)

        guard case .failed = outcome.status else {
            XCTFail("409 以外は失敗のままを期待したが \(outcome.status) だった")
            return
        }
        XCTAssertFalse(log.entries.contains { $0.hasPrefix("typedriver") },
                       "409 以外で typeDriver を照会してはいけない: \(log.entries)")
    }

    /// typeDriver が無い場合、409 はそのまま伝播して失敗させること
    func testPressEnter409WithoutTypeDriverPropagates() async throws {
        let log = CallLog()
        let primary = FakeAppDriver(name: "primary", log: log)
        primary.pressEnterError = DriverError.badResponse(status: 409, body: "not compose")
        let executor = StepExecutor(driver: primary)
        let step = FlowStep(action: "pressEnter")

        let outcome = await executor.execute(step)

        guard case .failed = outcome.status else {
            XCTFail("typeDriver 無しでの 409 失敗を期待したが \(outcome.status) だった")
            return
        }
    }

    // MARK: - スクロール探索終端の空打ち可否(pointIsTakenByFrontElement)

    private func framed(ref: Int, id: String, x: Double, y: Double,
                        width: Double, height: Double, depth: Int = 0) -> ElementInfo {
        ElementInfo(ref: ref, type: "button", identifier: id, label: nil, value: nil,
                    placeholder: nil, enabled: true,
                    frame: FTRect(x: x, y: y, width: width, height: height), depth: depth)
    }

    /// 対象の中心が**後ろに並ぶ(=手前寄りの)要素**に入るなら空打ちしない。
    /// 実害: タブバーの帯に出た要素へ空打ちしてホームタブが反応した(docs/verification.md)
    func testPointTakenByFrontElement() {
        let target = framed(ref: 1, id: "txt", x: 16, y: 815, width: 111, height: 20)
        let tabBar = framed(ref: 2, id: "tab_home", x: 0, y: 778, width: 134, height: 62)
        XCTAssertTrue(StepExecutor.pointIsTakenByFrontElement(
            x: 71, y: 825, of: target, in: [target, tabBar]))

        // 手前に何も無ければ打ってよい
        let apart = framed(ref: 3, id: "other", x: 300, y: 0, width: 50, height: 50)
        XCTAssertFalse(StepExecutor.pointIsTakenByFrontElement(
            x: 71, y: 825, of: target, in: [target, apart]))

        // 対象より**前**(奥)にある要素は数えない(pre-order で後 = 手前寄りの規約)
        XCTAssertFalse(StepExecutor.pointIsTakenByFrontElement(
            x: 71, y: 825, of: target, in: [tabBar, target]))

        // 対象自身の子孫(内側の Text 等)は同じ見た目の一部なので数えない
        let child = framed(ref: 4, id: "txt_inner", x: 20, y: 818, width: 60, height: 14, depth: 1)
        XCTAssertFalse(StepExecutor.pointIsTakenByFrontElement(
            x: 71, y: 825, of: target, in: [target, child]))
    }

    /// 空打ちドラッグは in-app が未対応(501)なら typeDriver(XCUITest)へ回すこと。
    /// 回さないと Compose のスクロール容器がタッチを1回吸ったままになり直後の tap が空振りする
    func testEmptyDragFallsBackToTypeDriverWhenEngineIncapable() async throws {
        let log = CallLog()
        let row = framed(ref: 1, id: "row_40", x: 16, y: 300, width: 370, height: 56)
        let primary = FakeAppDriver(name: "primary", log: log, snapshotElements: [[], [row]])
        primary.dragError = DriverError.badResponse(status: 501, body: "未対応")
        let typeDriver = FakeAppDriver(name: "typedriver", log: log)
        let executor = StepExecutor(driver: primary, typeDriver: typeDriver,
                                    releasesScrollTouch: true)
        let step = FlowStep(action: "scrollTo", locator: FlowLocator(id: "row_40"), maxSwipes: 2)

        guard case .passed = await executor.execute(step).status else {
            XCTFail("2回目の snapshot で見つかるので pass のはず"); return
        }
        XCTAssertTrue(log.entries.contains("primary.drag(throws)"), "まず primary を試すこと: \(log.entries)")
        XCTAssertTrue(log.entries.contains("typedriver.drag"),
                      "501 なら typeDriver へ回すこと: \(log.entries)")
    }

    /// drag のラッチは swipe に波及しないこと。in-app は drag だけ不可・swipe は
    /// contentOffset 経路で効くため、共有すると全 swipe が XCUITest 実スワイプ化して flake る
    func testDragFallbackDoesNotLatchSwipeToTypeDriver() async throws {
        let log = CallLog()
        let row = framed(ref: 1, id: "row_40", x: 16, y: 300, width: 370, height: 56)
        let primary = FakeAppDriver(name: "primary", log: log, snapshotElements: [[], [row]])
        primary.dragError = DriverError.badResponse(status: 501, body: "未対応")
        let typeDriver = FakeAppDriver(name: "typedriver", log: log)
        let executor = StepExecutor(driver: primary, typeDriver: typeDriver,
                                    releasesScrollTouch: true)
        _ = await executor.execute(
            FlowStep(action: "scrollTo", locator: FlowLocator(id: "row_40"), maxSwipes: 2))
        log.entries.removeAll()

        _ = await executor.execute(FlowStep(action: "swipe", direction: "up"))

        XCTAssertEqual(log.entries, ["primary.swipe"],
                       "drag の 501 で swipe まで typeDriver へ回してはいけない: \(log.entries)")
    }

    /// フォールバック判定は 501 と「ルート不明の 404」だけ。409(一時的競合)と
    /// ref 不明の 404 を含めると、前面不在や古い ref を隠して別画面を操作しかねない
    func testIsEngineIncapableClassification() {
        XCTAssertTrue(DriverError.isEngineIncapable(
            DriverError.badResponse(status: 501, body: "in-app エンジンでは press が効きません")))
        XCTAssertTrue(DriverError.isEngineIncapable(
            DriverError.badResponse(status: 404, body: "not found: POST /drag")))
        XCTAssertFalse(DriverError.isEngineIncapable(
            DriverError.badResponse(status: 404, body: "参照番号 [3] は未知です")))
        XCTAssertFalse(DriverError.isEngineIncapable(
            DriverError.badResponse(status: 409, body: "キーウィンドウがありません")))
        XCTAssertFalse(DriverError.isEngineIncapable(DriverError.bridgeUnreachable("timeout")))
    }

    /// 画面下端の a11y 空白帯(タブ frame の下〜画面下端)では空打ちしない。
    /// 実測座標(2026-07-28・E2E-iOS): タブ frame 下端 840・画面高 874 のとき、帯内 y=841.8 は
    /// a11y 上どの要素にも覆われないが実タブが反応した(07/16 の間欠フレークの根因)
    func testEmptyDragAvoidsBottomUncoveredBand() {
        let screen = FTRect(x: 0, y: 0, width: 402, height: 874)
        let tabBar = framed(ref: 2, id: "tab_home", x: 0, y: 778, width: 134, height: 62)

        // 失敗の実測ケース: 中心 y=841.8 はタブ frame(〜840)の外だが下端帯の中 → 打たない
        let low = framed(ref: 1, id: "txt", x: 16, y: 831.7, width: 111.3, height: 20.3)
        XCTAssertFalse(StepExecutor.emptyDragIsSafe(
            x: 71.7, y: 841.8, of: low, in: [low, tabBar], screen: screen))

        // タブ frame 内は従来どおり pointIsTakenByFrontElement が拒否する
        let inBand = framed(ref: 1, id: "txt", x: 16, y: 815.7, width: 111.3, height: 20.3)
        XCTAssertFalse(StepExecutor.emptyDragIsSafe(
            x: 71.7, y: 825.8, of: inBand, in: [inBand, tabBar], screen: screen))

        // 帯より上で手前要素も無ければ打ってよい(通常のリスト内)
        let mid = framed(ref: 1, id: "row", x: 16, y: 700, width: 370, height: 56)
        XCTAssertTrue(StepExecutor.emptyDragIsSafe(
            x: 201, y: 728, of: mid, in: [mid, tabBar], screen: screen))
    }

    /// 要素数の上限で打ち切られたスナップショットは「見つかりません」と区別が付かない。
    /// 失敗文言に必ず打ち切りを添える(WebView 画面は要素が多く最も当たりやすい)
    func testTruncationHint() {
        let screen = FTRect(x: 0, y: 0, width: 400, height: 800)
        func snapshot(_ elements: [ElementInfo], truncated: Int) -> SnapshotResponse {
            SnapshotResponse(sessionBundleID: nil, screen: screen,
                             elements: elements, truncatedCount: truncated)
        }
        let button = framed(ref: 1, id: "btn", x: 0, y: 0, width: 10, height: 10)

        XCTAssertEqual(StepExecutor.truncationHint(nil), "")
        XCTAssertEqual(StepExecutor.truncationHint(snapshot([button], truncated: 0)), "",
                       "打ち切られていなければ何も足さない")

        let hint = StepExecutor.truncationHint(snapshot([button], truncated: 30))
        XCTAssertTrue(hint.contains("30"), hint)
        XCTAssertFalse(hint.contains("WebView"), "WebView が無い画面で WebView の話をしない")

        let webView = ElementInfo(ref: 2, type: "WebView", identifier: nil, label: nil, value: nil,
                                  placeholder: nil, enabled: true,
                                  frame: screen, depth: 0)
        let webHint = StepExecutor.truncationHint(snapshot([button, webView], truncated: 30))
        XCTAssertTrue(webHint.contains("WebView"), webHint)
    }

    /// WebView 画面の失敗には**どの経路で読んだか**を添える。DOM 経路の未検出は
    /// 「無反応タップが成功として記録され、2ステップ先で別の文言で落ちる」形で出るため、
    /// 落ちた側に経路が書いていないと原因まで辿れない。
    /// **経路はドライバの申告(webViewPath)だけで決める**。要素の形から推測すると
    /// Android(webView 型は出るが web フラグは持たない)が XCUITest 委譲を名乗る
    func testWebViewPathHint() {
        let screen = FTRect(x: 0, y: 0, width: 400, height: 800)
        let webView = ElementInfo(ref: 1, type: "WebView", identifier: nil, label: nil, value: nil,
                                  placeholder: nil, enabled: true, frame: screen, depth: 0)
        let content = ElementInfo(ref: 2, type: "StaticText", identifier: nil, label: "本文",
                                  value: nil, placeholder: nil, enabled: true,
                                  frame: FTRect(x: 0, y: 0, width: 10, height: 10), depth: 0)
        func snapshot(_ path: String?) -> SnapshotResponse {
            SnapshotResponse(sessionBundleID: nil, screen: screen, elements: [webView, content],
                             truncatedCount: 0, webViewPath: path)
        }

        XCTAssertEqual(StepExecutor.webViewPathHint(nil), "")

        let dom = StepExecutor.webViewPathHint(snapshot("dom"))
        XCTAssertTrue(dom.contains("DOM 経路"), dom)
        XCTAssertTrue(dom.contains("無反応"), "無反応タップの可能性まで書くこと: \(dom)")

        let delegated = StepExecutor.webViewPathHint(snapshot("delegated"))
        XCTAssertTrue(delegated.contains("XCUITest"), delegated)
        XCTAssertFalse(delegated.contains("無反応"), "委譲側は合成タッチを使わないので警告しない")

        // **Android**: WebView 要素は出るが経路の申告は無い。XCUITest を名乗ってはいけない
        // (Android に XCUITest は存在せず、デバッグ中の人を誤誘導する)
        let android = StepExecutor.webViewPathHint(snapshot(nil))
        XCTAssertEqual(android, "", "申告が無ければ何も足さない: \(android)")

        // 通常画面(WebView 要素すら無い)も当然そのまま
        let plain = SnapshotResponse(sessionBundleID: nil, screen: screen, elements: [content],
                                     truncatedCount: 0)
        XCTAssertEqual(StepExecutor.webViewPathHint(plain), "")
    }

    // MARK: - スクロールヒント(WebView の画面外ノードによる長距離ドラッグ)

    private func hintSnapshot(screen: FTRect, elements: [ElementInfo] = [],
                              hints: [ElementInfo]) -> SnapshotResponse {
        SnapshotResponse(sessionBundleID: nil, screen: screen, elements: elements,
                         truncatedCount: 0, offscreen: hints)
    }

    private func hint(_ label: String, y: Double, height: Double = 100) -> ElementInfo {
        ElementInfo(ref: 0, type: "StaticText", identifier: nil, label: label, value: nil,
                    placeholder: nil, enabled: true,
                    frame: FTRect(x: 42, y: y, width: 1000, height: height), depth: 0)
    }

    private func scrollStep(_ label: String) -> FlowStep {
        FlowStep(action: "scrollTo", locator: FlowLocator(label: label), direction: "up", maxSwipes: 15)
    }

    /// 下方向のヒント一致 → 正のジャンプ(指を上へ)。目標は要素上端が画面の 40% 位置
    func testOffscreenJumpTowardsBelow() {
        let screen = FTRect(x: 0, y: 0, width: 1080, height: 2400)
        let snapshot = hintSnapshot(screen: screen, hints: [hint("画面外テキスト", y: 7000)])
        let jump = StepExecutor.offscreenJump(step: scrollStep("画面外テキスト"),
                                              snapshot: snapshot, finger: .up)
        XCTAssertEqual(jump ?? -1, 7000 - 2400 * 0.4, accuracy: 0.5)
    }

    /// 方向が合わないヒントは使わない(逆向きに引き返して往復しない)
    func testOffscreenJumpIgnoresWrongDirection() {
        let screen = FTRect(x: 0, y: 0, width: 1080, height: 2400)
        let above = hintSnapshot(screen: screen, hints: [hint("画面外テキスト", y: -3000)])
        XCTAssertNil(StepExecutor.offscreenJump(step: scrollStep("画面外テキスト"),
                                                snapshot: above, finger: .up))
        XCTAssertNotNil(StepExecutor.offscreenJump(step: scrollStep("画面外テキスト"),
                                                   snapshot: above, finger: .down))
    }

    /// ヒントに無いラベル・水平方向・ヒント無しは nil(従来のスワイプへ)
    func testOffscreenJumpFallsBackToSwipe() {
        let screen = FTRect(x: 0, y: 0, width: 1080, height: 2400)
        let snapshot = hintSnapshot(screen: screen, hints: [hint("別の要素", y: 7000)])
        XCTAssertNil(StepExecutor.offscreenJump(step: scrollStep("画面外テキスト"),
                                                snapshot: snapshot, finger: .up))
        XCTAssertNil(StepExecutor.offscreenJump(step: scrollStep("別の要素"),
                                                snapshot: snapshot, finger: .left))
        let empty = SnapshotResponse(sessionBundleID: nil, screen: screen, elements: [],
                                     truncatedCount: 0)
        XCTAssertNil(StepExecutor.offscreenJump(step: scrollStep("別の要素"),
                                                snapshot: empty, finger: .up))
    }

    /// もう画面のすぐ近く(30% 以内)なら跳ばない(通常ループの1スワイプで足りる。
    /// 近距離のドラッグはフリング過走で行き過ぎるリスクの方が大きい)
    func testOffscreenJumpSkipsNearTargets() {
        let screen = FTRect(x: 0, y: 0, width: 1080, height: 2400)
        let near = hintSnapshot(screen: screen, hints: [hint("画面外テキスト", y: 2400 * 0.4 + 500)])
        XCTAssertNil(StepExecutor.offscreenJump(step: scrollStep("画面外テキスト"),
                                                snapshot: near, finger: .up))
    }

    /// 端までの残り: 下端はヒント最下端まで、上端はヒント最上端まで
    func testOffscreenEdgeJump() {
        let screen = FTRect(x: 0, y: 0, width: 1080, height: 2400)
        let below = hintSnapshot(screen: screen,
                                 hints: [hint("a", y: 5000), hint("b", y: 7000, height: 200)])
        XCTAssertEqual(StepExecutor.offscreenEdgeJump(snapshot: below, finger: .up) ?? -1,
                       7200 - 2400, accuracy: 0.5)
        XCTAssertNil(StepExecutor.offscreenEdgeJump(snapshot: below, finger: .down),
                     "上方向にヒントが無ければ跳ばない")
        // 端の閾値は 100px(過走が端でクランプされるため scrollTo の 30% より攻められる)
        let close = hintSnapshot(screen: screen, hints: [hint("a", y: 2400 + 50, height: 100)])
        XCTAssertNotNil(StepExecutor.offscreenEdgeJump(snapshot: close, finger: .up))
        let above = hintSnapshot(screen: screen, hints: [hint("a", y: -2510)])
        XCTAssertEqual(StepExecutor.offscreenEdgeJump(snapshot: above, finger: .down) ?? 1,
                       -2510, accuracy: 0.5)
    }

    /// ドラッグの始点・終点: コンテナ内・上下 15% マージン・距離は 0.9 掛けと可動域でクランプ
    func testDragGestureGeometry() {
        let container = FTRect(x: 0, y: 332, width: 1080, height: 1900)
        // 指を上へ: 下端マージンから上へ
        let up = StepExecutor.dragGesture(jump: 1000, container: container)
        XCTAssertNotNil(up)
        XCTAssertEqual(up!.fromX, 540)
        XCTAssertEqual(up!.fromY, 332 + 1900 - 285, accuracy: 0.5)   // マージン 15% = 285
        XCTAssertEqual(up!.fromY - up!.toY, 900, accuracy: 0.5)      // 1000 * 0.9
        // 長距離は可動域(70%)でクランプ
        let far = StepExecutor.dragGesture(jump: 10000, container: container)
        XCTAssertEqual(far!.fromY - far!.toY, 1900 * 0.7, accuracy: 0.5)
        // 指を下へ: 上端マージンから下へ
        let down = StepExecutor.dragGesture(jump: -1000, container: container)
        XCTAssertEqual(down!.toY - down!.fromY, 900, accuracy: 0.5)
        // 潰れたコンテナ・極小距離は nil
        XCTAssertNil(StepExecutor.dragGesture(jump: 1000,
                                              container: FTRect(x: 0, y: 0, width: 100, height: 120)))
        XCTAssertNil(StepExecutor.dragGesture(jump: 40, container: container))
    }
}
