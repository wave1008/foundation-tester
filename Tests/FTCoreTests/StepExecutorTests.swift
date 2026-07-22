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

    func press(ref: Int, duration: Double) async throws {
        if let pressError {
            log.entries.append("\(name).press(throws)")
            throw pressError
        }
        log.entries.append("\(name).press(ref:\(ref))")
    }

    private(set) var screenshotCallCount = 0
    func screenshot() async throws -> Data { screenshotCallCount += 1; return Data() }

    func terminate() async throws {}
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
                              screenshotPNG: Data) async -> (visible: Bool, state: String, reason: String)? {
        visibleCalls += 1
        return (visible, visible ? "fullyVisible" : "covered", "test")
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
                              screenshotPNG: Data) async -> (visible: Bool, state: String, reason: String)? {
        let v = calls < results.count ? results[calls] : (results.last ?? true)
        calls += 1
        return (v, v ? "fullyVisible" : "covered", "test")
    }
}

final class StepExecutorTests: XCTestCase {
    /// occlusion-guard 対象になり得るテキスト要素(StaticText + 文字を含む label)
    private func textElement(id: String, label: String) -> ElementInfo {
        ElementInfo(ref: 1, type: "StaticText", identifier: id, label: label, value: nil,
                    placeholder: nil, enabled: true,
                    frame: FTRect(x: 0, y: 0, width: 100, height: 20), depth: 0)
    }

    private func element(ref: Int, id: String) -> ElementInfo {
        ElementInfo(ref: ref, type: "Button", identifier: id, label: nil, value: nil,
                   placeholder: nil, enabled: true,
                   frame: FTRect(x: 0, y: 0, width: 10, height: 10), depth: 0)
    }

    private func labeled(ref: Int, label: String) -> ElementInfo {
        ElementInfo(ref: ref, type: "Button", identifier: nil, label: label, value: nil,
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
        XCTAssertFalse(OcclusionEligibility.eligible(type: "StaticText", label: "A, B").ok)
        // ユーザー期待値(textEquals)では除外しない
        XCTAssertTrue(OcclusionEligibility.eligible(type: "StaticText", label: "Hello, World",
                                                    isUserText: true).ok)
        // 型・絵文字の規則は isUserText でも維持
        XCTAssertFalse(OcclusionEligibility.eligible(type: "Button", label: "x", isUserText: true).ok)
        XCTAssertFalse(OcclusionEligibility.eligible(type: "StaticText", label: "📱",
                                                     isUserText: true).ok)
    }

    /// #1 修正: フォールバックドライバ(システムUI)由来の textEquals 一致は座標系が食い違うためガードしない
    func testTextEqualsSkipsGuardForFallbackDriverMatch() async throws {
        let log = CallLog()
        let match = ElementInfo(ref: 1, type: "StaticText", identifier: "msg", label: "OK",
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
            ElementInfo(ref: 1, type: "StaticText", identifier: "msg", label: label, value: nil,
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
        let el = ElementInfo(ref: 1, type: "StaticText", identifier: nil, label: "Hello, World",
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
        let step = FlowStep(action: "tap", locator: FlowLocator(label: "ログイン"))

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
        let step = FlowStep(action: "tap", locator: FlowLocator(label: "ログイン"))

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

    /// gesturesViaTypeDriver(probe で compose 検出)なら 501 を待たず最初から typeDriver で撃つこと
    func testGesturesViaTypeDriverRoutesUpfront() async throws {
        let log = CallLog()
        let primary = FakeAppDriver(name: "primary", log: log)
        let typeDriver = FakeAppDriver(name: "typedriver", log: log)
        let executor = StepExecutor(driver: primary, typeDriver: typeDriver,
                                    gesturesViaTypeDriver: true)

        let outcome = await executor.execute(FlowStep(action: "swipe", direction: "up"))

        XCTAssertEqual(outcome.driverFallback, "XCUITest へフォールバック")
        XCTAssertEqual(log.entries, ["typedriver.swipe"], "primary を無駄打ちしてはいけない")
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
}
