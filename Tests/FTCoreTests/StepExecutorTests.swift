import XCTest
import CoreGraphics
import ImageIO
import UniformTypeIdentifiers
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
    /// snapshotElements と同じ「呼び出し回数ぶんの列(尽きたら最後を繰り返す)」規約で
    /// SnapshotResponse.keyboardShown を差し替える(keyboardShown/keyboardNotShown の
    /// poll-until-state-change 検証用)。nil のままなら常に nil(非表示扱い)
    var keyboardShownFrames: [Bool]?
    /// 同じ規約(尽きたら最後を繰り返す)で screenshot() の戻り値を差し替える。
    /// nil のままなら空 Data(= BlankFrameDetector はデコードできず「白ではない」を返す)
    var screenshots: [Data]?
    private(set) var snapshotCallCount = 0
    /// このドライバでキャッシュ迂回が意味を持つか(既定は AppDriver の既定実装と同じ false)。
    /// bypassesCache の真理値表の検証で切り替える
    var bypassSupported = false
    /// 迂回付きで撮られた回数(素取得と区別する)
    private(set) var bypassedSnapshotCount = 0
    /// 非 nil なら type(ref:text:) がこのエラーを throw する(409 リアクティブ切替の検証用)
    var typeError: Error?
    /// 非 nil なら swipe/press がこのエラーを throw する(501 ジェスチャ切替の検証用)
    var swipeError: Error?
    var pressError: Error?
    /// SnapshotResponse.keyboardFrame(全 snapshot() 呼び出しに一律で乗せる。
    /// キーボード遮蔽の配線テスト専用。既定 nil = 従来どおりキーボード非表示扱い)
    var keyboardFrame: FTRect?

    init(name: String, log: CallLog, snapshotElements: [[ElementInfo]] = [],
         screenshots: [Data]? = nil) {
        self.name = name
        self.log = log
        self.snapshotElements = snapshotElements
        self.screenshots = screenshots
    }

    /// `GET /systemalert` の擬似。nil = 申告なし(既定 = ゲートは何もしない)。
    /// 「呼び出し回数ぶんの列(尽きたら最後を繰り返す)」規約は snapshotElements と同じ
    var systemAlertFrames: [SystemAlertProbeResponse]?
    private(set) var systemAlertCallCount = 0

    func systemAlert() async throws -> SystemAlertProbeResponse? {
        systemAlertCallCount += 1
        log.entries.append("\(name).systemAlert")
        guard let frames = systemAlertFrames, !frames.isEmpty else { return nil }
        return frames[min(systemAlertCallCount - 1, frames.count - 1)]
    }

    func status() async throws -> StatusResponse {
        StatusResponse(ready: true, device: name, osVersion: "-", sessionBundleID: nil)
    }

    func install(packagePath: String) async throws {}
    func uninstall(bundleID: String) async throws {}
    func isAppForeground(bundleID: String) async throws -> Bool { false }
    func foregroundAppID() async throws -> String? { nil }

    func launch(bundleID: String) async throws {
        log.entries.append("\(name).launch")
    }

    func snapshot() async throws -> SnapshotResponse {
        // **打ち切りを効かせる**: 無限ループを時間で縛るテスト
        // (testItGivesUpWithinTheBudget…)は、どこかに協調的な打ち切り点が無いと
        // Task.cancel() が届かず**ハングして「生き残り」に見える**
        try Task.checkCancellation()
        snapshotCallCount += 1
        log.entries.append("\(name).snapshot")
        let elements: [ElementInfo]
        if snapshotElements.isEmpty {
            elements = []
        } else {
            let index = min(snapshotCallCount - 1, snapshotElements.count - 1)
            elements = snapshotElements[index]
        }
        let keyboardShown: Bool?
        if let frames = keyboardShownFrames, !frames.isEmpty {
            keyboardShown = frames[min(snapshotCallCount - 1, frames.count - 1)]
        } else {
            keyboardShown = nil
        }
        return SnapshotResponse(sessionBundleID: nil,
                                screen: FTRect(x: 0, y: 0, width: 400, height: 800),
                                elements: elements, truncatedCount: 0, keyboardShown: keyboardShown,
                                keyboardFrame: keyboardFrame)
    }

    var supportsCacheBypass: Bool { bypassSupported }

    /// 既定実装はフラグを捨てて snapshot() を呼ぶので、記録するには実装が要る
    func snapshot(bypassingCache: Bool) async throws -> SnapshotResponse {
        if bypassingCache { bypassedSnapshotCount += 1 }
        return try await snapshot()
    }

    /// **既定 true**(AppDriver の既定 false とは逆)。type 読み返しテスト以外の全既存テストは
    /// 読み返しの発動を意図していないので、明示的に false へ落とすテストだけが対象になる
    var verifiesTypedText = true
    /// type(ref:text:)/clearInput(ref:) が呼ばれるたびに実行するフック。読み返し検証の
    /// resend/deleteExcess 経路で「訂正が実際に効いた」ことを、次の snapshot() 呼び出し以降に
    /// snapshotElements へ追記して表現するために使う(呼び出し時点までの列は変えず追記するだけなので、
    /// まだ訂正前の周回が読む値には影響しない)
    var onMutatingCall: (() -> Void)?

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
        onMutatingCall?()
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
    /// 直近の drag 呼び出しに渡った引数(swipeElementToElement/swipePointToPoint の座標配線確認用)
    private(set) var lastDragArgs: (fromX: Double, fromY: Double, toX: Double, toY: Double,
                                    pressSeconds: Double, durationSeconds: Double)?
    /// 全 drag 呼び出し(空打ちが撃たれたかの検証用。lastDragArgs は最後の1件しか残らない)
    private(set) var dragCalls: [(fromX: Double, fromY: Double, toX: Double, toY: Double)] = []

    func drag(fromX: Double, fromY: Double, toX: Double, toY: Double,
              pressSeconds: Double, durationSeconds: Double) async throws {
        lastDragArgs = (fromX, fromY, toX, toY, pressSeconds, durationSeconds)
        dragCalls.append((fromX, fromY, toX, toY))
        if let dragError {
            log.entries.append("\(name).drag(throws)")
            throw dragError
        }
        log.entries.append("\(name).drag")
    }

    /// 非 nil なら doubleTap/pinch がこのエラーを throw する(501 切替の検証用)。
    /// **実装しないと AppDriver 既定の 501 になる**ので、通常経路の検証にも実装が要る
    var doubleTapError: Error?
    var pinchError: Error?
    private(set) var lastDoubleTap: (x: Double, y: Double)?
    private(set) var lastPinch: (frame: FTRect?, identifier: String?,
                                 scale: Double, durationSeconds: Double)?

    func doubleTap(x: Double, y: Double) async throws {
        lastDoubleTap = (x, y)
        if let doubleTapError {
            log.entries.append("\(name).doubleTap(throws)")
            throw doubleTapError
        }
        log.entries.append("\(name).doubleTap")
    }

    func pinch(frame: FTRect?, identifier: String?, scale: Double,
               durationSeconds: Double) async throws {
        lastPinch = (frame, identifier, scale, durationSeconds)
        if let pinchError {
            log.entries.append("\(name).pinch(throws)")
            throw pinchError
        }
        log.entries.append("\(name).pinch")
    }

    private(set) var screenshotCallCount = 0
    func screenshot() async throws -> Data {
        defer { screenshotCallCount += 1 }
        guard let screenshots, !screenshots.isEmpty else { return Data() }
        return screenshots[min(screenshotCallCount, screenshots.count - 1)]
    }

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

    /// 非 nil なら clearInput(ref:) がこのエラーを throw する(409/501 切替の検証用)
    var clearInputError: Error?

    func clearInput(ref: Int?) async throws {
        if let clearInputError {
            log.entries.append("\(name).clearInput(throws)")
            throw clearInputError
        }
        log.entries.append("\(name).clearInput(ref:\(ref.map(String.init) ?? "nil"))")
        onMutatingCall?()
    }

    func back() async throws {
        log.entries.append("\(name).back")
    }

    /// 非 nil なら hideKeyboard() がこのエラーを throw する(501/404 切替の検証用)
    var hideKeyboardError: Error?

    func hideKeyboard() async throws {
        if let hideKeyboardError {
            log.entries.append("\(name).hideKeyboard(throws)")
            throw hideKeyboardError
        }
        log.entries.append("\(name).hideKeyboard")
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

/// screenMatches の撮り直し検証用: verdict を順番に返し、呼び出し回数を数える
/// (列を使い切ったら最後の verdict を返し続ける)
private final class ScriptedScreenDelegate: ReplayDelegate {
    private(set) var verifyScreenCalls = 0
    private let verdicts: [Bool]
    init(_ verdicts: [Bool]) { self.verdicts = verdicts }
    func healLocator(step: FlowStep, snapshot: SnapshotResponse) async -> HealProposal? { nil }
    func verifyScreen(expected: String, screenshotPNG: Data) async -> (pass: Bool, reason: String)? {
        let pass = verdicts[min(verifyScreenCalls, verdicts.count - 1)]
        verifyScreenCalls += 1
        return (pass, pass ? "ok" : "mismatch")
    }
    func triage(goal: String?, stepDescription: String, failureReason: String,
                snapshot: SnapshotResponse?, screenshotPNG: Data?) async -> TriageInfo? { nil }
}

/// screenMatches 検証用: verifyScreen が常に pass を返し、呼び出し回数を数える
/// (screenLooksLikeEnabled=false で呼ばれないことの検証用)
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
    /// 白ベタ = BlankFrameDetector が凍結と判定する画像
    static let blankPNG: Data = makePNG { context in
        context.setFillColor(CGColor(red: 1, green: 1, blue: 1, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: 64, height: 64))
    }
    /// 市松模様 = サンプル点が割れるので凍結と判定されない画像
    static let nonBlankPNG: Data = makePNG { context in
        context.setFillColor(CGColor(red: 1, green: 1, blue: 1, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: 64, height: 64))
        context.setFillColor(CGColor(red: 0, green: 0, blue: 0, alpha: 1))
        for row in 0..<8 where row.isMultiple(of: 2) {
            for col in 0..<8 where col.isMultiple(of: 2) {
                context.fill(CGRect(x: col * 8, y: row * 8, width: 8, height: 8))
            }
        }
    }

    private static func makePNG(_ draw: (CGContext) -> Void) -> Data {
        guard let context = CGContext(data: nil, width: 64, height: 64, bitsPerComponent: 8,
                                      bytesPerRow: 0, space: CGColorSpaceCreateDeviceRGB(),
                                      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else {
            fatalError("テスト用 CGContext 生成に失敗")
        }
        draw(context)
        guard let image = context.makeImage() else { fatalError("テスト用 CGImage 生成に失敗") }
        let output = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(
            output, UTType.png.identifier as CFString, 1, nil) else {
            fatalError("テスト用 PNG destination 生成に失敗")
        }
        CGImageDestinationAddImage(destination, image, nil)
        guard CGImageDestinationFinalize(destination) else { fatalError("テスト用 PNG 書き出しに失敗") }
        return output as Data
    }

    /// occlusion-guard 対象になり得るテキスト要素(StaticText + 文字を含む label)
    private func textElement(id: String, label: String) -> ElementInfo {
        ElementInfo(ref: 1, type: "staticText", identifier: id, label: label, value: nil,
                    placeholder: nil, enabled: true,
                    frame: FTRect(x: 0, y: 0, width: 100, height: 20), depth: 0)
    }

    // MARK: - 見切れ判定(スクロール探索が「見えた瞬間」で止まらないための条件)

    /// 縁で見切れた要素は frame がクランプされてタップが外れる(Compose iOS の上流制約)。
    /// **見つけた = 十分ではない**ことをここで固定する
    func testClippedByViewportDetectsEachEdge() {
        let screen = FTRect(x: 0, y: 0, width: 402, height: 874)
        func at(_ x: Double, _ y: Double, _ w: Double = 370, _ h: Double = 56) -> ElementInfo {
            ElementInfo(ref: 1, type: "clickable", identifier: "row", label: nil, value: nil,
                        placeholder: nil, enabled: true,
                        frame: FTRect(x: x, y: y, width: w, height: h), depth: 1)
        }
        XCTAssertFalse(StepExecutor.isClippedByViewport(at(16, 400), screen: screen))
        XCTAssertTrue(StepExecutor.isClippedByViewport(at(16, 829), screen: screen), "下端で見切れ")
        XCTAssertTrue(StepExecutor.isClippedByViewport(at(16, -1), screen: screen), "上端で見切れ")
        XCTAssertTrue(StepExecutor.isClippedByViewport(at(-1, 400), screen: screen), "左で見切れ")
        XCTAssertTrue(StepExecutor.isClippedByViewport(at(40, 400, 370), screen: screen), "右で見切れ")
        // ちょうど収まっているものは見切れではない(境界)
        XCTAssertFalse(StepExecutor.isClippedByViewport(at(16, 818), screen: screen))
        // **幅がビューポートと同じ要素も判定対象**(リストの行は容器と同じ幅を持つ)
        XCTAssertTrue(StepExecutor.isClippedByViewport(at(0, 829, 402), screen: screen),
                      "幅一致の行が漏れるとタップが容器の外へ落ちる")
    }

    /// ビューポートより大きい要素はどう送っても収まらない。true にすると maxSwipes を
    /// 使い切って「見つけたのに失敗」になる
    func testElementLargerThanViewportIsNotTreatedAsClipped() {
        let screen = FTRect(x: 0, y: 0, width: 402, height: 874)
        let tall = ElementInfo(ref: 1, type: "other", identifier: "long", label: nil, value: nil,
                               placeholder: nil, enabled: true,
                               frame: FTRect(x: 0, y: -100, width: 402, height: 1200), depth: 1)
        XCTAssertFalse(StepExecutor.isClippedByViewport(tall, screen: screen))
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

    /// clearInput の事後検証テスト用の入力欄。value/placeholder/focused を個別に指定できる
    private func inputField(ref: Int, id: String? = nil, value: String? = nil,
                            placeholder: String? = nil, focused: Bool? = nil,
                            frame: FTRect = FTRect(x: 0, y: 0, width: 100, height: 20)) -> ElementInfo {
        ElementInfo(ref: ref, type: "textField", identifier: id, label: nil, value: value,
                   placeholder: placeholder, enabled: true, frame: frame, depth: 0,
                   focused: focused)
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

    /// [StaleFrameDetector] 新規撮影のスクショが「木は変わったのに画像はバイト同一」を示したら
    /// 1回だけ撮り直す。撮り直しで画像が変われば(=もう凍結していない)通常どおり判定を続ける
    func testStaleScreenshotRetriesOnceThenProceedsWithFreshCapture() async throws {
        let log = CallLog()
        let stuckPNG = Data([0x01])
        let freshPNG = Data([0x02])
        let primary = FakeAppDriver(name: "primary", log: log,
                                    snapshotElements: [[textElement(id: "msg", label: "A")],
                                                       [textElement(id: "msg", label: "B")]],
                                    screenshots: [stuckPNG, stuckPNG, freshPNG])
        let delegate = FakeVisibilityDelegate(visible: true)
        let executor = StepExecutor(driver: primary, delegate: delegate)
        let step = FlowStep(assert: "exists", locator: FlowLocator(id: "msg"),
                            timeout: 1, occlusionGuard: true)

        _ = await executor.execute(step)   // baseline: 木 "A"・画像 stuckPNG
        _ = await executor.execute(FlowStep(action: "tap", locator: FlowLocator(id: "msg")))
        let outcome = await executor.execute(step)   // 木 "B"(変化)・初回捕捉は stuckPNG のまま → stale → 撮り直し → freshPNG

        guard case .passed = outcome.status else {
            XCTFail("撮り直しで凍結が解消されたので通常どおり pass するはず: \(outcome.status)"); return
        }
        XCTAssertEqual(primary.screenshotCallCount, 3, "2回目の assert は初回捕捉+撮り直しの2回スクショを払うはず")
        // baseline(1回目の assert)自体も stale ではないので通常どおり FM を呼ぶ+今回の撮り直し後
        // の1回 = 計2回
        XCTAssertEqual(delegate.visibleCalls, 2, "baseline 1回+撮り直した新しい画像で1回、計2回 FM 照合するはず")
        XCTAssertFalse(outcome.notes.contains(.staleScreenshot), "凍結は解消されたので stale 注記は付かないはず")
    }

    /// 撮り直してもなお画像がバイト同一(=木は変わったのに絵が固まったまま)なら、
    /// 古い絵を根拠に偽陽性反転を宣言せず flip しない。FM も呼ばない。
    /// **delegate は visible:true**(false にすると baseline 自体が本物の occlusion で
    /// timeout まで poll してしまい、その間の追加 snapshot/screenshot 呼び出しが
    /// スクリプトした木/画像の対応関係を狂わせる —— stale 判定だけを切り分けるため)
    func testStaleScreenshotSkipsFlipWhenRetakeStillStale() async throws {
        let log = CallLog()
        let stuckPNG = Data([0x01])
        let primary = FakeAppDriver(name: "primary", log: log,
                                    snapshotElements: [[textElement(id: "msg", label: "A")],
                                                       [textElement(id: "msg", label: "B")]],
                                    screenshots: [stuckPNG])
        let delegate = FakeVisibilityDelegate(visible: true)
        let executor = StepExecutor(driver: primary, delegate: delegate)
        let step = FlowStep(assert: "exists", locator: FlowLocator(id: "msg"),
                            timeout: 1, occlusionGuard: true)

        _ = await executor.execute(step)   // baseline: not stale → 通常どおり FM を1回呼んで pass
        _ = await executor.execute(FlowStep(action: "tap", locator: FlowLocator(id: "msg")))
        let callsBeforeStep2 = delegate.visibleCalls
        let outcome = await executor.execute(step)   // 木は変わったが、画像は撮り直しても不変のまま

        guard case .passed = outcome.status else {
            XCTFail("flip しないのでツリー一致のまま pass するはず: \(outcome.status)"); return
        }
        XCTAssertEqual(delegate.visibleCalls, callsBeforeStep2, "stale が解消しないうちは FM を呼ばないはず")
        XCTAssertTrue(outcome.notes.contains(.staleScreenshot), "stale-screenshot 注記が付くはず: \(outcome.notes)")
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
        XCTAssertTrue(msg.contains("does not equal"), "テキスト不一致を返すこと: \(msg)")
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
        XCTAssertTrue(msg.contains("not found"), "未発見を返すこと: \(msg)")
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

    // MARK: - システム UI の覆い(SystemUIGate)

    /// **覆われている間は撃たない**。要素は木に居て解決できてしまうが、人手では触れないので
    /// 操作させてはいけない(受け手報告 2026-08-20 の症状そのもの)
    func testActionIsRefusedWhileSystemUICoversTheApp() async throws {
        let log = CallLog()
        let primary = FakeAppDriver(name: "primary", log: log,
                                    snapshotElements: [[element(ref: 1, id: "target")]])
        let fallback = FakeAppDriver(name: "fallback", log: log, snapshotElements: [[]])
        fallback.systemAlertFrames = [SystemAlertProbeResponse(present: true, title: "権限",
                                                               buttons: ["許可"])]
        let executor = StepExecutor(driver: primary, fallbackDriver: fallback,
                                    systemAlertButtons: ["許可"])
        let step = FlowStep(action: "tap", locator: FlowLocator(id: "target"), timeout: 1)

        let outcome = await executor.execute(step)

        guard case .failed(let msg) = outcome.status else {
            XCTFail("覆われている間のタップは失敗にすること: \(outcome.status)"); return
        }
        XCTAssertEqual(outcome.failureKind, .systemUICovered, msg)
        XCTAssertTrue(msg.contains("権限"), "覆っているものを名指しすること: \(msg)")
        XCTAssertFalse(log.entries.contains { $0.hasPrefix("primary.tap") },
                       "1回も撃ってはいけない: \(log.entries)")
    }

    /// 覆いが**消えれば普通に撃つ**(即失敗にしない = 過渡的なアラートで赤くしない)。
    /// 待ったことは注記に残す
    func testActionProceedsOnceTheSystemUIGoesAway() async throws {
        let log = CallLog()
        let primary = FakeAppDriver(name: "primary", log: log,
                                    snapshotElements: [[element(ref: 1, id: "target")]])
        let fallback = FakeAppDriver(name: "fallback", log: log, snapshotElements: [[]])
        fallback.systemAlertFrames = [SystemAlertProbeResponse(present: true),
                                      SystemAlertProbeResponse(present: false)]
        let executor = StepExecutor(driver: primary, fallbackDriver: fallback,
                                    systemAlertButtons: ["一致しないラベル"])
        let step = FlowStep(action: "tap", locator: FlowLocator(id: "target"), timeout: 5)

        let outcome = await executor.execute(step)

        guard case .passed = outcome.status else {
            XCTFail("覆いが消えたら撃つこと: \(outcome.status)"); return
        }
        XCTAssertTrue(log.entries.contains { $0.hasPrefix("primary.tap") }, "\(log.entries)")
        XCTAssertTrue(outcome.notes.contains(.waitedForSystemUI),
                      "待ったことを黙ってはいけない: \(outcome.notes)")
    }

    /// **`iosSystemAlertButtons` を宣言していない実行では1往復も払わない**
    /// (2026-08-21 ユーザー決定)。アラートが出る画面は書き手が知っているので宣言できる
    /// はずで、宣言しない実行に毎ステップ約 73ms を負わせない
    func testNoProbeWithoutDeclaredAlertButtons() async throws {
        let log = CallLog()
        let primary = FakeAppDriver(name: "primary", log: log,
                                    snapshotElements: [[element(ref: 1, id: "target")]])
        let fallback = FakeAppDriver(name: "fallback", log: log, snapshotElements: [[]])
        fallback.systemAlertFrames = [SystemAlertProbeResponse(present: true, title: "権限")]
        let executor = StepExecutor(driver: primary, fallbackDriver: fallback)   // 宣言なし
        let tap = FlowStep(action: "tap", locator: FlowLocator(id: "target"), timeout: 1)
        let exists = FlowStep(assert: "exists", locator: FlowLocator(id: "target"), timeout: 1)

        guard case .passed = await executor.execute(tap).status,
              case .passed = await executor.execute(exists).status else {
            XCTFail("宣言が無い実行は従来どおり通すこと"); return
        }
        XCTAssertFalse(log.entries.contains { $0.hasSuffix(".systemAlert") },
                       "宣言が無いのに聞いてはいけない: \(log.entries)")
    }

    /// **ランナーが居ない構成でも1往復も払わない**。ここが止まると engine=inapp 固定と
    /// Android が全滅する
    func testActionCostsNothingWithoutAFallbackBridge() async throws {
        let log = CallLog()
        let primary = FakeAppDriver(name: "primary", log: log,
                                    snapshotElements: [[element(ref: 1, id: "target")]])
        let executor = StepExecutor(driver: primary, systemAlertButtons: ["許可"])   // fallback 無し
        let step = FlowStep(action: "tap", locator: FlowLocator(id: "target"), timeout: 1)

        guard case .passed = await executor.execute(step).status else {
            XCTFail("fallback が無いなら従来どおり撃つこと"); return
        }
        XCTAssertFalse(log.entries.contains { $0.hasSuffix(".systemAlert") },
                       "fallback が無いのに聞いてはいけない: \(log.entries)")
    }

    /// **シナリオ自身がアラートを操作しているときは奪わない**: 対象が fallback(SpringBoard)の
    /// 木で解決できるなら、覆われていても止めない
    func testActionOnTheAlertItselfIsNotBlocked() async throws {
        let log = CallLog()
        let primary = FakeAppDriver(name: "primary", log: log, snapshotElements: [[]])
        let fallback = FakeAppDriver(name: "fallback", log: log,
                                     snapshotElements: [[labeled(ref: 9, label: "許可")]])
        fallback.systemAlertFrames = [SystemAlertProbeResponse(present: true)]
        let executor = StepExecutor(driver: primary, fallbackDriver: fallback,
                                    systemAlertButtons: ["一致しないラベル"])
        let step = FlowStep(action: "tap", locator: FlowLocator(label: "許可"), timeout: 1)

        let outcome = await executor.execute(step)

        guard case .passed = outcome.status else {
            XCTFail("アラート自身への操作は止めてはいけない: \(outcome.status)"); return
        }
        XCTAssertTrue(log.entries.contains { $0.hasPrefix("fallback.tap") }, "\(log.entries)")
    }

    /// **覆われている間の緑は取り消す**。木には居るが人手には見えていないので、
    /// 「見えた」と言うのは別ウィンドウのモーダルと同じ形の偽陽性になる
    func testPassingAssertIsRevokedWhileSystemUICoversTheApp() async throws {
        let log = CallLog()
        let primary = FakeAppDriver(name: "primary", log: log,
                                    snapshotElements: [[element(ref: 1, id: "target")]])
        let fallback = FakeAppDriver(name: "fallback", log: log, snapshotElements: [[]])
        fallback.systemAlertFrames = [SystemAlertProbeResponse(present: true, title: "権限")]
        let executor = StepExecutor(driver: primary, fallbackDriver: fallback,
                                    systemAlertButtons: ["一致しないラベル"])
        let step = FlowStep(assert: "exists", locator: FlowLocator(id: "target"), timeout: 1)

        let outcome = await executor.execute(step)

        guard case .failed = outcome.status else {
            XCTFail("覆われている間に exist を通してはいけない: \(outcome.status)"); return
        }
        XCTAssertEqual(outcome.failureKind, .systemUICovered)
    }

    /// **アラート自身の検証は取り消さない**(`exist("許可しない")` が書けなくなる)
    func testAssertOnTheAlertItselfStaysGreen() async throws {
        let log = CallLog()
        let primary = FakeAppDriver(name: "primary", log: log, snapshotElements: [[]])
        let fallback = FakeAppDriver(name: "fallback", log: log,
                                     snapshotElements: [[labeled(ref: 9, label: "許可しない")]])
        fallback.systemAlertFrames = [SystemAlertProbeResponse(present: true)]
        let executor = StepExecutor(driver: primary, fallbackDriver: fallback,
                                    systemAlertButtons: ["一致しないラベル"])
        let step = FlowStep(assert: "exists", locator: FlowLocator(label: "許可しない"), timeout: 2)

        guard case .passed = await executor.execute(step).status else {
            XCTFail("アラート自身の検証は通すこと"); return
        }
    }

    /// **失敗したときは聞かない**(既にシナリオは止まるので往復を足す価値がない)
    func testAFailingAssertDoesNotPayForTheProbe() async throws {
        let log = CallLog()
        let primary = FakeAppDriver(name: "primary", log: log, snapshotElements: [[]])
        let fallback = FakeAppDriver(name: "fallback", log: log, snapshotElements: [[]])
        let executor = StepExecutor(driver: primary, fallbackDriver: fallback,
                                    systemAlertButtons: ["許可"])
        let step = FlowStep(assert: "exists", locator: FlowLocator(id: "missing"), timeout: 1)

        _ = await executor.execute(step)

        XCTAssertFalse(log.entries.contains { $0.hasSuffix(".systemAlert") },
                       "失敗した検証で往復を足してはいけない: \(log.entries)")
    }

    /// **押した宣言は消費され、使い切ったら監視を解除する**(ユーザー決定 2026-08-21 ——
    /// 同じアラートはそのシナリオで二度出ないものとする)。解除後は1往復も払わない
    func testMonitoringStopsOnceEveryDeclaredButtonHasBeenUsed() async throws {
        let log = CallLog()
        let primary = FakeAppDriver(name: "primary", log: log,
                                    snapshotElements: [[element(ref: 1, id: "target")]])
        let fallback = FakeAppDriver(name: "fallback", log: log,
                                     snapshotElements: [[labeled(ref: 9, label: "許可")]])
        // 1回目: アラートあり → 閉じた後は消えている。2回目以降も「あり」を返すが、
        // 監視が解除されていれば**そもそも聞かない**ので観測されないはず
        fallback.systemAlertFrames = [SystemAlertProbeResponse(present: true, title: "権限"),
                                      SystemAlertProbeResponse(present: false)]
        let executor = StepExecutor(driver: primary, fallbackDriver: fallback,
                                    systemAlertButtons: ["許可"])
        let step = FlowStep(action: "tap", locator: FlowLocator(id: "target"), timeout: 5)

        guard case .passed = await executor.execute(step).status else {
            XCTFail("閉じたら進むこと"); return
        }
        let afterFirst = fallback.systemAlertCallCount
        XCTAssertGreaterThan(afterFirst, 0, "1ステップ目は聞くこと")

        guard case .passed = await executor.execute(step).status else {
            XCTFail("2ステップ目も通ること"); return
        }
        XCTAssertEqual(fallback.systemAlertCallCount, afterFirst,
                       "使い切った後は1往復も払ってはいけない")
    }

    /// **アラートは重なり得る**(位置情報の直後に通知など)。1枚閉じただけで進むと
    /// 2枚目に覆われたまま撃つことになるので、閉じたら確かめ直してから進む
    func testStackedAlertsAreDismissedOneAfterAnother() async throws {
        let log = CallLog()
        let primary = FakeAppDriver(name: "primary", log: log,
                                    snapshotElements: [[element(ref: 1, id: "target")]])
        // **2枚目にも「許可」を置く**: 消費済みを候補から外していないと、2枚目でも先頭の
        // 「許可」を押してしまう(=同じラベルを二度押す)。ここで両方を出さないと、
        // 「未消費だけを渡す」実装と「全部渡す」実装が同じ結果になり判別できない
        let fallback = FakeAppDriver(name: "fallback", log: log,
                                     snapshotElements: [[labeled(ref: 9, label: "許可")],
                                                        [labeled(ref: 9, label: "許可"),
                                                         labeled(ref: 8, label: "OK")]])
        // 1枚目を閉じた直後もまだ覆われている(2枚目)→ 3回目の照会で晴れる
        fallback.systemAlertFrames = [SystemAlertProbeResponse(present: true, title: "1枚目"),
                                      SystemAlertProbeResponse(present: true, title: "2枚目"),
                                      SystemAlertProbeResponse(present: false)]
        let executor = StepExecutor(driver: primary, fallbackDriver: fallback,
                                    systemAlertButtons: ["許可", "OK"])
        let step = FlowStep(action: "tap", locator: FlowLocator(id: "target"), timeout: 5)

        guard case .passed = await executor.execute(step).status else {
            XCTFail("2枚とも閉じて進むこと"); return
        }
        let taps = log.entries.filter { $0.hasPrefix("fallback.tap") }
        XCTAssertEqual(taps, ["fallback.tap(ref:9)", "fallback.tap(ref:8)"],
                       "1枚目は「許可」・2枚目は**消費済みを避けて**「OK」を押すこと: \(log.entries)")
        XCTAssertTrue(log.entries.contains { $0.hasPrefix("primary.tap") }, "\(log.entries)")
    }

    /// **消費済みのラベルは二度と押さない**。同じアラートが再び出た前提は置かないので、
    /// 2枚目が同じラベルなら③(撃たずに待って落ちる)へ行く
    func testAConsumedLabelIsNotPressedAgain() async throws {
        let log = CallLog()
        let primary = FakeAppDriver(name: "primary", log: log,
                                    snapshotElements: [[element(ref: 1, id: "target")]])
        let fallback = FakeAppDriver(name: "fallback", log: log,
                                     snapshotElements: [[labeled(ref: 9, label: "許可")]])
        fallback.systemAlertFrames = [SystemAlertProbeResponse(present: true, title: "権限",
                                                               buttons: ["許可"])]
        let executor = StepExecutor(driver: primary, fallbackDriver: fallback,
                                    systemAlertButtons: ["許可"])
        let step = FlowStep(action: "tap", locator: FlowLocator(id: "target"), timeout: 1)

        let outcome = await executor.execute(step)

        guard case .failed = outcome.status else {
            XCTFail("閉じても覆われたままなら止めること: \(outcome.status)"); return
        }
        XCTAssertEqual(outcome.failureKind, .systemUICovered)
        XCTAssertEqual(log.entries.filter { $0.hasPrefix("fallback.tap") }.count, 1,
                       "同じラベルを二度押してはいけない: \(log.entries)")
    }

    /// **閉じても消えない画面でも予算内で終わる**。②(閉じる)が成功し続ける限りループが
    /// 回るので、予算の確認をループ先頭に置かないと**無限に回る**(変異テストで実際に
    /// ハングして見つけた defect の回帰)
    func testItGivesUpWithinTheBudgetEvenIfDismissingNeverClearsTheAlert() async throws {
        let log = CallLog()
        let primary = FakeAppDriver(name: "primary", log: log,
                                    snapshotElements: [[element(ref: 1, id: "target")]])
        // 押せるボタンは常にあり、アラートも消えない(閉じたつもりで消えない画面)
        let fallback = FakeAppDriver(name: "fallback", log: log,
                                     snapshotElements: [[labeled(ref: 9, label: "許可"),
                                                         labeled(ref: 8, label: "OK")]])
        fallback.systemAlertFrames = [SystemAlertProbeResponse(present: true, title: "消えない")]
        let executor = StepExecutor(driver: primary, fallbackDriver: fallback,
                                    systemAlertButtons: ["許可", "OK"])
        let step = FlowStep(action: "tap", locator: FlowLocator(id: "target"), timeout: 1)

        // **時間で縛る**: 予算の確認を外すとここは失敗ではなく**ハング**する。ハングは
        // 変異テストのハーネスからは「生き残り」と区別できず、SwiftPM のロックを掴んだまま
        // 後続の worktree まで止める(2026-08-21 に実際に踏んだ)ので、落ちる形にしておく。
        // 打ち切りは待機の `Task.sleep` が投げて伝わる
        let started = Date()
        let running = Task { await executor.execute(step) }
        let watchdog = Task { try? await Task.sleep(for: .seconds(15)); running.cancel() }
        let outcome = await running.value
        watchdog.cancel()
        XCTAssertLessThan(Date().timeIntervalSince(started), 15,
                          "予算(1s)を大きく超えた = ループが予算を見ていない")

        guard case .failed = outcome.status else {
            XCTFail("消えないなら予算切れで落ちること: \(outcome.status)"); return
        }
        XCTAssertEqual(outcome.failureKind, .systemUICovered)
    }

    /// **監視の解除は検証側にも効く**(操作側だけだと、消費後も緑のたびに1往復払い続ける)
    func testAssertStopsProbingOnceEveryDeclaredButtonHasBeenUsed() async throws {
        let log = CallLog()
        let primary = FakeAppDriver(name: "primary", log: log,
                                    snapshotElements: [[element(ref: 1, id: "target")]])
        let fallback = FakeAppDriver(name: "fallback", log: log,
                                     snapshotElements: [[labeled(ref: 9, label: "許可")]])
        fallback.systemAlertFrames = [SystemAlertProbeResponse(present: true, title: "権限"),
                                      SystemAlertProbeResponse(present: false)]
        let executor = StepExecutor(driver: primary, fallbackDriver: fallback,
                                    systemAlertButtons: ["許可"])
        // 1本目(操作)で宣言を使い切る
        guard case .passed = await executor.execute(
            FlowStep(action: "tap", locator: FlowLocator(id: "target"), timeout: 5)).status else {
            XCTFail("閉じたら進むこと"); return
        }
        let afterAction = fallback.systemAlertCallCount

        guard case .passed = await executor.execute(
            FlowStep(assert: "exists", locator: FlowLocator(id: "target"), timeout: 1)).status else {
            XCTFail("検証も通ること"); return
        }
        XCTAssertEqual(fallback.systemAlertCallCount, afterAction,
                       "使い切った後は検証でも1往復も払ってはいけない")
    }

    /// **検証側も宣言で閉じる**(受け手報告 2026-08-22)。6c1d4dd7 までこの経路は
    /// **一度も照合せずに**「どの宣言も一致しなかった」と書いており、アラートにも宣言にも
    /// 「許可」があるのに落ち続けた = 設定では直せない状態を作っていた
    func testAssertDismissesTheAlertWithADeclaredLabelInsteadOfFailing() async throws {
        let log = CallLog()
        let primary = FakeAppDriver(name: "primary", log: log,
                                    snapshotElements: [[element(ref: 1, id: "target")]])
        let fallback = FakeAppDriver(name: "fallback", log: log,
                                     snapshotElements: [[labeled(ref: 9, label: "許可")]])
        fallback.systemAlertFrames = [SystemAlertProbeResponse(present: true, title: "トラッキング",
                                                               buttons: ["許可しない", "許可"]),
                                      SystemAlertProbeResponse(present: false)]
        let executor = StepExecutor(driver: primary, fallbackDriver: fallback,
                                    systemAlertButtons: ["許可"])
        let step = FlowStep(assert: "exists", locator: FlowLocator(id: "target"), timeout: 1)

        let outcome = await executor.execute(step)

        guard case .passed = outcome.status else {
            XCTFail("宣言で閉じられるなら閉じて判定し直すこと: \(outcome.status)"); return
        }
        XCTAssertTrue(log.entries.contains { $0.hasPrefix("fallback.tap") },
                      "閉じるボタンを押すこと: \(log.entries)")
        XCTAssertTrue(outcome.notes.contains(.waitedForSystemUI), "\(outcome.notes)")
    }

    /// 閉じたあとは**判定し直す**。覆いの下で出した緑は根拠にならないので、
    /// 晴れた画面で答えが変わるならそちらを返す
    func testAssertIsRejudgedAfterTheAlertIsDismissed() async throws {
        let log = CallLog()
        // 1枚目(覆われている間)は見えていたが、閉じたあとの画面には居ない
        let primary = FakeAppDriver(name: "primary", log: log,
                                    snapshotElements: [[element(ref: 1, id: "target")], []])
        let fallback = FakeAppDriver(name: "fallback", log: log,
                                     snapshotElements: [[labeled(ref: 9, label: "許可")]])
        fallback.systemAlertFrames = [SystemAlertProbeResponse(present: true, buttons: ["許可"]),
                                      SystemAlertProbeResponse(present: false)]
        let executor = StepExecutor(driver: primary, fallbackDriver: fallback,
                                    systemAlertButtons: ["許可"])
        let step = FlowStep(assert: "exists", locator: FlowLocator(id: "target"), timeout: 1)

        let outcome = await executor.execute(step)

        guard case .failed = outcome.status else {
            XCTFail("晴れた画面に居ないなら緑にしてはいけない: \(outcome.status)"); return
        }
        XCTAssertEqual(outcome.failureKind, .notFound,
                       "判定し直した結果の失敗であること(覆いのせいにしない)")
    }

    /// screenLooksLikeEnabled=false(実行プロファイルの screenLooksLike:false)は screenMatches を skip し、
    /// delegate の verifyScreen を呼ばない
    func testScreenMatchesSkippedWhenScreenIsDisabled() async throws {
        let log = CallLog()
        let primary = FakeAppDriver(name: "primary", log: log)
        let delegate = CountingScreenDelegate()
        let executor = StepExecutor(driver: primary, delegate: delegate, screenLooksLikeEnabled: false)
        let step = FlowStep(assert: "screenMatches", expected: "ホーム画面")

        guard case .skipped(let msg) = await executor.execute(step).status else {
            XCTFail("screenLooksLike 無効なら skip のはず"); return
        }
        XCTAssertTrue(msg.contains("screenLooksLike is disabled"), "skip 理由に無効化を明示すること: \(msg)")
        XCTAssertEqual(delegate.verifyScreenCalls, 0, "無効時は verifyScreen を呼んではいけない")
        XCTAssertEqual(primary.screenshotCallCount, 0, "無効時はスクショも撮らないはず")
    }

    /// screenLooksLikeEnabled 既定(true)では screenMatches が delegate の判定どおりに動く(退行検知)
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

    /// **screenLooksLike は不一致なら1回だけ撮り直す**(遷移直後のまだ描き終わっていない画面を救う)。
    /// 他の検証のような timeout ポーリングにしないのは、FM 照合がホスト全体で直列(約1回/秒)だから
    func testScreenMatchesRetriesOnceOnMismatch() async throws {
        let log = CallLog()
        let primary = FakeAppDriver(name: "primary", log: log)
        let delegate = ScriptedScreenDelegate([false, true])
        let executor = StepExecutor(driver: primary, delegate: delegate)
        let step = FlowStep(assert: "screenMatches", expected: "ホーム画面")

        guard case .passed = await executor.execute(step).status else {
            XCTFail("撮り直しで一致すれば pass のはず"); return
        }
        XCTAssertEqual(delegate.verifyScreenCalls, 2, "1回だけ撮り直すこと")
        XCTAssertEqual(primary.screenshotCallCount, 2, "撮り直しでは画像も取り直すこと")
    }

    /// 撮り直しても一致しなければ失敗。**再試行は1回で打ち切る**(FM を焼き続けない)
    func testScreenMatchesStopsAfterOneRetry() async throws {
        let log = CallLog()
        let primary = FakeAppDriver(name: "primary", log: log)
        let delegate = ScriptedScreenDelegate([false, false])
        let executor = StepExecutor(driver: primary, delegate: delegate)
        let step = FlowStep(assert: "screenMatches", expected: "ホーム画面")

        guard case .failed = await executor.execute(step).status else {
            XCTFail("2回とも不一致なら失敗のはず"); return
        }
        XCTAssertEqual(delegate.verifyScreenCalls, 2, "3回目を呼んではいけない")
    }

    /// **撮り直しも白フレーム検査を通す**。凍結した画面を FM に渡すと必ず不一致になるので、
    /// 素の screenshot() で撮り直すと「requeue すべき凍結」が「画面が一致しない」に化ける
    func testScreenMatchesRetryStillGuardsAgainstBlankFrames() async throws {
        let log = CallLog()
        // 1枚目は通常の画像、2枚目以降(撮り直し)は白フレーム
        let primary = FakeAppDriver(name: "primary", log: log,
                                    screenshots: [Self.nonBlankPNG] + Array(repeating: Self.blankPNG, count: 5))
        let delegate = ScriptedScreenDelegate([false])
        let frozen = CallLog()   // @Sendable クロージャからは参照型で数える
        let executor = StepExecutor(driver: primary, delegate: delegate)
        executor.onDeviceFrozen = { frozen.entries.append("frozen") }
        let step = FlowStep(assert: "screenMatches", expected: "ホーム画面")

        guard case .skipped(let msg) = await executor.execute(step).status else {
            XCTFail("撮り直しが白フレームなら凍結として skip するはず"); return
        }
        XCTAssertTrue(msg.contains("frozen display"), "凍結として報告すること: \(msg)")
        XCTAssertEqual(frozen.entries.count, 1, "requeue のため onDeviceFrozen を呼ぶこと")
        XCTAssertEqual(delegate.verifyScreenCalls, 1, "白フレームを FM に渡してはいけない")
    }

    /// 一致した場合は撮り直さない(正常系のコストを増やさない)
    func testScreenMatchesDoesNotRetryWhenItPasses() async throws {
        let log = CallLog()
        let primary = FakeAppDriver(name: "primary", log: log)
        let delegate = ScriptedScreenDelegate([true])
        let executor = StepExecutor(driver: primary, delegate: delegate)
        let step = FlowStep(assert: "screenMatches", expected: "ホーム画面")

        guard case .passed = await executor.execute(step).status else {
            XCTFail("1回目で一致すれば pass のはず"); return
        }
        XCTAssertEqual(delegate.verifyScreenCalls, 1, "正常系で撮り直してはいけない")
        XCTAssertEqual(primary.screenshotCallCount, 1)
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

    /// select は解決するだけでデバイス操作(tap/press 等)を一切呼ばないこと
    /// (exist と違い検証でもない = occlusionGuard も立たない。docs/design.md の select 契約)
    func testSelectResolvesWithoutDeviceOperation() async throws {
        let log = CallLog()
        let primary = FakeAppDriver(name: "primary", log: log,
                                    snapshotElements: [[element(ref: 1, id: "target")]])
        let executor = StepExecutor(driver: primary)
        let step = FlowStep(action: "select", locator: FlowLocator(id: "target"), timeout: 1)

        guard case .passed = await executor.execute(step).status else {
            XCTFail("解決できれば select は pass するはず"); return
        }
        XCTAssertTrue(log.entries.allSatisfy { !$0.contains(".tap(") && !$0.contains(".press(") },
                     "select はデバイス操作を呼んではいけない: \(log.entries)")
    }

    /// select は**見えないとき失敗させず空要素を返す**(exist は失敗へ反転する = 意味が違う)。
    /// 呼び出し側は `.text == nil` で分岐できる
    func testSelectReturnsEmptyElementWhenNotVisible() async throws {
        let log = CallLog()
        let primary = FakeAppDriver(name: "primary", log: log,
                                    snapshotElements: [[textElement(id: "msg", label: "こんにちは")]])
        let executor = StepExecutor(driver: primary, delegate: FakeVisibilityDelegate(visible: false))
        let step = FlowStep(action: "select", locator: FlowLocator(id: "msg"),
                            timeout: 1, occlusionGuard: true)

        let outcome = await executor.execute(step)

        guard case .passed = outcome.status else {
            XCTFail("select は覆われていても失敗させない。実際は \(outcome.status)"); return
        }
        XCTAssertNil(outcome.resolvedElement, "見えないなら空要素(掴めていない)を返すこと")
    }

    /// requireVisible: false 相当(occlusionGuard: false)なら照合せず掴む
    func testSelectSkipsVisibilityCheckWhenNotRequired() async throws {
        let log = CallLog()
        let primary = FakeAppDriver(name: "primary", log: log,
                                    snapshotElements: [[textElement(id: "msg", label: "こんにちは")]])
        let delegate = FakeVisibilityDelegate(visible: false)
        let executor = StepExecutor(driver: primary, delegate: delegate)
        let step = FlowStep(action: "select", locator: FlowLocator(id: "msg"),
                            timeout: 1, occlusionGuard: false)

        let outcome = await executor.execute(step)

        guard case .passed = outcome.status else {
            XCTFail("照合を外したら pass するはず。実際は \(outcome.status)"); return
        }
        XCTAssertNotNil(outcome.resolvedElement, "照合を外したら掴めていること")
        XCTAssertEqual(delegate.visibleCalls, 0, "requireVisible: false なら FM を呼ばない")
    }

    /// **select だけは掴めなくても失敗しない**(空要素を返す契約)。DSL の `.isEmpty` 分岐が
    /// 成立する前提なので、ここが failed に転ぶと利用者は掴めない要素を検知できなくなる
    func testSelectSkipsWithAnEmptyElementWhenNotFound() async throws {
        let log = CallLog()
        let primary = FakeAppDriver(name: "primary", log: log, snapshotElements: [[]])
        let executor = StepExecutor(driver: primary)
        let step = FlowStep(action: "select", locator: FlowLocator(id: "missing"), timeout: 0)

        let outcome = await executor.execute(step)

        guard case .skipped = outcome.status else {
            XCTFail("select は見つからなければ skip のはず。実際は \(outcome.status)"); return
        }
        XCTAssertNil(outcome.resolvedElement, "掴めていないので要素を返さないこと")
    }

    /// 対の検証: **select 以外は見つからなければ失敗**(シナリオ中断)。`optional:` 廃止で
    /// 「空振りを黙って許す」経路が tap/type に残っていないことを固定する
    func testTapFailsWhenNotFound() async throws {
        let log = CallLog()
        let primary = FakeAppDriver(name: "primary", log: log, snapshotElements: [[]])
        let executor = StepExecutor(driver: primary)
        let step = FlowStep(action: "tap", locator: FlowLocator(id: "missing"), timeout: 0)

        guard case .failed = await executor.execute(step).status else {
            XCTFail("tap は見つからなければ失敗のはず"); return
        }
    }

    /// **申告 keyboardFrame はキー面だけ**(TapTargetGeometry.effectiveKeyboardFrame の doc)。
    /// MCP 側(MCPRefGuardTests.testTapWarnsWhenTheCentreIsOnlyUnderTheExpandedKeyboardChrome)と
    /// 同じ witness を DSL 側(StepExecutor+Actions.swift)でも固定する —— 呼び出し元が申告のまま
    /// 渡すよう後退すると、この注記が付かず落ちる
    func testTapNotesKeyboardCoverageUsingTheExpandedChromeFrame() async throws {
        let log = CallLog()
        let tabHome = ElementInfo(ref: 1, type: "button", identifier: "tab_home", label: "ホーム",
                                  value: nil, placeholder: nil, enabled: true,
                                  frame: FTRect(x: 0, y: 548, width: 134, height: 62), depth: 1)
        let inputView = ElementInfo(ref: 2, type: "other", identifier: "inputView", label: nil,
                                    value: nil, placeholder: nil, enabled: true,
                                    frame: FTRect(x: 0, y: 546, width: 402, height: 328), depth: 1)
        let suggestBar = ElementInfo(ref: 3, type: "other", identifier: "SystemInputAssistantView",
                                     label: nil, value: nil, placeholder: nil, enabled: true,
                                     frame: FTRect(x: 0, y: 546, width: 402, height: 44), depth: 1)
        let primary = FakeAppDriver(name: "primary", log: log,
                                    snapshotElements: [[tabHome, inputView, suggestBar]])
        // 申告は 590..816 —— tab_home の中心 y=579 はこの外(修正前は無警告)
        primary.keyboardFrame = FTRect(x: 0, y: 590, width: 402, height: 226)
        let executor = StepExecutor(driver: primary)
        let step = FlowStep(action: "tap", locator: FlowLocator(id: "tab_home"))

        let outcome = await executor.execute(step)

        guard case .passed = outcome.status else {
            XCTFail("tap 自体は passed のはず(警告であって拒否ではない): \(outcome.status)"); return
        }
        XCTAssertTrue(outcome.driverFallback?.contains("soft keyboard") == true,
                      "chrome で広げた実効矩形(546..874)なら中心 579 を拾って警告すること:"
                      + " \(outcome.driverFallback ?? "nil")")
    }

    /// **chrome 自身の部品を撃つときはキーボード警告を出さない**(2026-08-14)。地球儀キーは
    /// 実効矩形の中に中心があるが chrome(`#inputView`)の子孫なので、覆っている側であって
    /// 覆われている側ではない。片方だけ生の keyboardFrame へ戻す変異(RefGuard 側は直ったが
    /// StepExecutor 側は据え置き、のような部分退行)をここで落とす
    func testTapOnTheKeyboardChromeItselfDoesNotWarnAboutTheKeyboard() async throws {
        let log = CallLog()
        let inputView = ElementInfo(ref: 1, type: "other", identifier: "inputView", label: nil,
                                    value: nil, placeholder: nil, enabled: true,
                                    frame: FTRect(x: 0, y: 546, width: 402, height: 328), depth: 1)
        let globeKey = ElementInfo(ref: 2, type: "button", identifier: "globe_key", label: nil,
                                   value: nil, placeholder: nil, enabled: true,
                                   frame: FTRect(x: 0, y: 806, width: 134, height: 68), depth: 2)
        let primary = FakeAppDriver(name: "primary", log: log,
                                    snapshotElements: [[inputView, globeKey]])
        primary.keyboardFrame = FTRect(x: 0, y: 590, width: 402, height: 226)
        let executor = StepExecutor(driver: primary)
        let step = FlowStep(action: "tap", locator: FlowLocator(id: "globe_key"))

        let outcome = await executor.execute(step)

        guard case .passed = outcome.status else {
            XCTFail("tap 自体は passed のはず: \(outcome.status)"); return
        }
        XCTAssertFalse(outcome.driverFallback?.contains("soft keyboard") == true,
                       "chrome 自身の部品には keyboard 警告を出さないこと:"
                       + " \(outcome.driverFallback ?? "nil")")
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
    /// StepExecutor+Assert.swift executeAssert "exists" 参照)
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

    /// timeout: 0 ではロケータ再試行を行わないが、driver フォールバックの
    /// 1回照会(hybrid で解決するために必須)は timeout: 0 でも必ず行われる。
    /// 操作コマンド(tap)で解決の往復回数だけを観測する
    func testZeroTimeoutSkipsRetryButQueriesFallbackOnce() async throws {
        let log = CallLog()
        let primary = FakeAppDriver(name: "primary", log: log, snapshotElements: [[]])
        let fallback = FakeAppDriver(name: "fallback", log: log, snapshotElements: [[]])
        let executor = StepExecutor(driver: primary, fallbackDriver: fallback)
        let step = FlowStep(action: "tap", locator: FlowLocator(id: "target"), timeout: 0)

        let outcome = await executor.execute(step)

        guard case .failed = outcome.status else {
            XCTFail("tap の空振りは失敗を期待したが \(outcome.status) だった")
            return
        }
        XCTAssertEqual(primary.snapshotCallCount, 1)
        XCTAssertEqual(fallback.snapshotCallCount, 1)
        XCTAssertLessThanOrEqual(outcome.timing?.waitMs ?? 0, 5)
    }

    /// **select は driver フォールバックを照会しない**(掴むだけでデバイス操作が無く、
    /// 掴めないことが答えになり得るコマンド。fb.snapshot() は springboard セッションを張り、
    /// 同一デバイス1セッション制約でアプリ attach を潰す実害があった。StepExecutor 側の
    /// コメント参照)
    func testSelectDoesNotQueryDriverFallback() async throws {
        let log = CallLog()
        let primary = FakeAppDriver(name: "primary", log: log, snapshotElements: [[]])
        let fallback = FakeAppDriver(name: "fallback", log: log,
                                     snapshotElements: [[element(ref: 1, id: "target")]])
        let executor = StepExecutor(driver: primary, fallbackDriver: fallback)
        let step = FlowStep(action: "select", locator: FlowLocator(id: "target"), timeout: 0)

        let outcome = await executor.execute(step)

        // fallback 側に要素が実在しても照会しない = 掴めず skip(空要素)になる
        guard case .skipped = outcome.status else {
            XCTFail("select の空振りは skip を期待したが \(outcome.status) だった")
            return
        }
        XCTAssertEqual(fallback.snapshotCallCount, 0)
    }

    /// 回帰ガード: step.timeout が nil(省略)のときアクションは従来どおり
    /// 初回+3回リトライ(計4回スナップショット)のまま変わらないこと
    func testNilTimeoutKeepsLegacyThreeRetries() async throws {
        let log = CallLog()
        let primary = FakeAppDriver(name: "primary", log: log, snapshotElements: [[]])
        let executor = StepExecutor(driver: primary)
        let step = FlowStep(action: "select", locator: FlowLocator(id: "target"))

        let outcome = await executor.execute(step)

        guard case .skipped = outcome.status else {
            XCTFail("select の空振りは skip を期待したが \(outcome.status) だった")
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

    /// **システムダイアログの形**(2026-08-16): iOS の権限ダイアログは SpringBoard が別プロセスで
    /// 描くので、**アプリ側の木には1件も現れない**。hybrid ではこのとき fallbackDriver
    /// (SystemUIDriver = springboard 参照)だけが持っているので、`tap("許可")` は
    /// フォールバック経由で解決して**そちらのドライバで撃つ**必要がある。
    ///
    /// 既存の fallback テストは「primary にも何かある」形(substring vs exact)しか見ておらず、
    /// **primary が空**というこの形は未カバーだった。docs/commands.md §システムダイアログ(iOS)
    /// が「hybrid なら普通に書ける」と約束している経路の砦
    func testTapResolvesViaFallbackWhenPrimaryTreeHasNothing() async throws {
        let log = CallLog()
        let primary = FakeAppDriver(name: "primary", log: log, snapshotElements: [[]])
        let fallback = FakeAppDriver(name: "fallback", log: log,
                                     snapshotElements: [[labeled(ref: 7, label: "許可")]])
        let executor = StepExecutor(driver: primary, fallbackDriver: fallback)
        let step = FlowStep(action: "tap", locator: FlowLocator(label: "許可"))

        let outcome = await executor.execute(step)

        guard case .passed = outcome.status else {
            XCTFail("fallback だけが持つ要素での passed を期待したが \(outcome.status) だった")
            return
        }
        XCTAssertTrue(log.entries.contains("fallback.tap(ref:7)"),
                      "システムダイアログのボタンは fallback のドライバで撃つこと: \(log.entries)")
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

    // MARK: - type の読み返し検証(verifiesTypedText == false のドライバだけ発動)

    /// verifiesTypedText == true(xcuitest/Android 相当)では読み返しスナップショットを増やさないこと
    func testTypeSkipsReadbackWhenDriverAlreadyVerifies() async throws {
        let log = CallLog()
        let primary = FakeAppDriver(name: "primary", log: log,
                                    snapshotElements: [[inputField(ref: 1, id: "field")]])
        // verifiesTypedText は既定 true(FakeAppDriver の既定。AppDriver 既定の false とは逆)
        let executor = StepExecutor(driver: primary)
        let step = FlowStep(action: "type", locator: FlowLocator(id: "field"), text: "hi")

        let outcome = await executor.execute(step)

        guard case .passed = outcome.status else {
            XCTFail("passed を期待したが \(outcome.status) だった")
            return
        }
        XCTAssertEqual(primary.snapshotCallCount, 1,
                       "検証済みドライバでは読み返しの追加 snapshot を撮らないこと")
    }

    /// 一発で期待どおりに入る場合: 追加 snapshot 1枚だけで成功し、注記は付かない
    func testTypeVerifiesReadbackOnFirstTry() async throws {
        let log = CallLog()
        let primary = FakeAppDriver(
            name: "primary", log: log,
            snapshotElements: [[inputField(ref: 1, id: "field", value: nil)],
                              [inputField(ref: 1, id: "field", value: "hi")]])
        primary.verifiesTypedText = false
        let executor = StepExecutor(driver: primary)
        let step = FlowStep(action: "type", locator: FlowLocator(id: "field"), text: "hi")

        let outcome = await executor.execute(step)

        guard case .passed = outcome.status else {
            XCTFail("一致した読み返しでは passed を期待したが \(outcome.status) だった")
            return
        }
        XCTAssertNil(outcome.driverFallback)
        XCTAssertEqual(primary.snapshotCallCount, 2, "読み返しは追加 snapshot 1枚で足りること")
        XCTAssertEqual(log.entries.filter { $0.hasPrefix("primary.type(ref:1)") }.count, 1,
                       "一発で一致すれば追送/削除は要らない")
    }

    /// 1回目の読みが前方一致で止まる(取りこぼし)場合: 足りない分だけ追送して成功すること
    func testTypeResendsMissingCharactersOnPartialCommit() async throws {
        let log = CallLog()
        let primary = FakeAppDriver(
            name: "primary", log: log,
            snapshotElements: [[inputField(ref: 1, id: "field", value: nil)],
                              [inputField(ref: 1, id: "field", value: "h")]])
        primary.verifiesTypedText = false
        // 1回目の type(hi そのもの)では値遷移させない —— このフックは全 type/clearInput 呼び出しで
        // 発火するので、追送(2回目以降)のときだけ「値が hi に落ち着いた」を表現する
        var mutations = 0
        primary.onMutatingCall = {
            mutations += 1
            guard mutations > 1 else { return }
            primary.snapshotElements.append([self.inputField(ref: 1, id: "field", value: "hi")])
        }
        let executor = StepExecutor(driver: primary)
        let step = FlowStep(action: "type", locator: FlowLocator(id: "field"), text: "hi")

        let outcome = await executor.execute(step)

        guard case .passed = outcome.status else {
            XCTFail("追送後に一致すれば passed を期待したが \(outcome.status) だった")
            return
        }
        XCTAssertEqual(log.entries.filter { $0.hasPrefix("primary.type(ref:1)") }.count, 2,
                       "取りこぼした分を1回だけ追送すること: \(log.entries)")
    }

    /// 読みが期待値を超えて長い(二重入力)場合: clearInput してから全文を打ち直して成功すること
    func testTypeDeletesExcessAndRetypesOnDoubleCommit() async throws {
        let log = CallLog()
        let primary = FakeAppDriver(
            name: "primary", log: log,
            snapshotElements: [[inputField(ref: 1, id: "field", value: nil)],
                              [inputField(ref: 1, id: "field", value: "hihi")]])
        primary.verifiesTypedText = false
        // 1回目の type(hi そのもの)では値遷移させない(resend テストと同じ理由)。
        // clearInput+再送の2回(mutations 2,3回目)が終わってから hi に落ち着かせる
        var mutations = 0
        primary.onMutatingCall = {
            mutations += 1
            guard mutations > 2 else { return }
            primary.snapshotElements.append([self.inputField(ref: 1, id: "field", value: "hi")])
        }
        let executor = StepExecutor(driver: primary)
        let step = FlowStep(action: "type", locator: FlowLocator(id: "field"), text: "hi")

        let outcome = await executor.execute(step)

        guard case .passed = outcome.status else {
            XCTFail("削除+再送後に一致すれば passed を期待したが \(outcome.status) だった")
            return
        }
        XCTAssertTrue(log.entries.contains("primary.clearInput(ref:1)"),
                      "過剰入力は clearInput で削ること: \(log.entries)")
        XCTAssertEqual(log.entries.filter { $0.hasPrefix("primary.type(ref:1)") }.count, 2,
                       "削除後に全文を再送すること: \(log.entries)")
    }

    /// マスク欄など加工された値(前方一致でも超過でもない)は検証不能として受理すること
    /// (パスワード欄の伏せ字が典型)
    func testTypeAcceptsUnverifiableValueWithoutRetry() async throws {
        let log = CallLog()
        let primary = FakeAppDriver(
            name: "primary", log: log,
            snapshotElements: [[inputField(ref: 1, id: "field", value: nil)],
                              [inputField(ref: 1, id: "field", value: "••")]])
        primary.verifiesTypedText = false
        let executor = StepExecutor(driver: primary)
        let step = FlowStep(action: "type", locator: FlowLocator(id: "field"), text: "hi")

        let outcome = await executor.execute(step)

        guard case .passed = outcome.status else {
            XCTFail("検証不能な値は受理して passed を期待したが \(outcome.status) だった")
            return
        }
        XCTAssertEqual(log.entries.filter { $0.hasPrefix("primary.type(ref:1)") }.count, 1,
                       "検証不能なら追送しないこと: \(log.entries)")
    }

    /// 値が停滞したまま収束しない場合: ステップを失敗させ、失敗理由に入力値そのものを含めないこと
    func testTypeFailsWhenValueNeverSettles() async throws {
        let log = CallLog()
        let primary = FakeAppDriver(
            name: "primary", log: log,
            snapshotElements: [[inputField(ref: 1, id: "field", value: nil)],
                              [inputField(ref: 1, id: "field", value: "h")]])
        primary.verifiesTypedText = false
        let executor = StepExecutor(driver: primary)
        let step = FlowStep(action: "type", locator: FlowLocator(id: "field"), text: "hi")

        let outcome = await executor.execute(step)

        guard case .failed(let reason) = outcome.status else {
            XCTFail("値が収束しなければ failed を期待したが \(outcome.status) だった")
            return
        }
        XCTAssertFalse(reason.contains("hi"), "失敗理由に入力値そのものを含めないこと: \(reason)")
    }

    // MARK: - type(replace:)(2026-08-12)

    /// replace: true は type の前に clearInput を1回だけ呼ぶこと(retype ではなく置換)
    func testTypeWithReplaceClearsBeforeTyping() async throws {
        let log = CallLog()
        let primary = FakeAppDriver(
            name: "primary", log: log,
            snapshotElements: [[inputField(ref: 1, id: "field", value: "old")],
                              [inputField(ref: 1, id: "field", value: nil)]])
        // verifiesTypedText 既定 true(呼び出し順だけを見るテストなので読み返しは起こさない)
        let executor = StepExecutor(driver: primary)
        let step = FlowStep(action: "type", locator: FlowLocator(id: "field"), text: "new", replace: true)

        let outcome = await executor.execute(step)

        guard case .passed = outcome.status else {
            XCTFail("passed を期待したが \(outcome.status) だった"); return
        }
        let clearIndex = log.entries.firstIndex(of: "primary.clearInput(ref:1)")
        let typeIndex = log.entries.firstIndex { $0.hasPrefix("primary.type(ref:1)") }
        XCTAssertNotNil(clearIndex, "replace は type の前に clearInput を呼ぶこと: \(log.entries)")
        XCTAssertNotNil(typeIndex)
        if let clearIndex, let typeIndex {
            XCTAssertLessThan(clearIndex, typeIndex, "clearInput は type より前であること: \(log.entries)")
        }
        XCTAssertEqual(log.entries.filter { $0.hasPrefix("primary.clearInput(ref:1)") }.count, 1,
                       "clearInput は1回だけであること: \(log.entries)")
    }

    /// clear 後も残存値が消えない(typeDriver も無い)場合は type を撃たずに失敗させること。
    /// 空にできていないのに書き足すと、検証したのと違う値になるため
    func testTypeWithReplaceFailsWithoutTypingWhenClearLeavesResidualValue() async throws {
        let log = CallLog()
        let primary = FakeAppDriver(
            name: "primary", log: log,
            snapshotElements: [[inputField(ref: 1, id: "field", value: "still there")]])
        let executor = StepExecutor(driver: primary)
        let step = FlowStep(action: "type", locator: FlowLocator(id: "field"), text: "new", replace: true)

        let outcome = await executor.execute(step)

        guard case .failed(let message) = outcome.status else {
            XCTFail("clear が効かなければ type を撃たず failed を期待したが \(outcome.status) だった"); return
        }
        XCTAssertTrue(message.contains("still there"), "残った値をメッセージに含めるべき: \(message)")
        XCTAssertFalse(log.entries.contains { $0.hasPrefix("primary.type(ref:") },
                       "clear に失敗したら type を撃ってはいけない: \(log.entries)")
    }

    /// **ロケータなし `type(text, replace: true)` も clear を通ること**。この形は
    /// ロケータ有りとは別の分岐(フォーカス中要素へ ref: nil で撃つ経路)を通るので、
    /// ここを覆わないと片方だけ無言で追記に戻る
    func testTypeWithoutLocatorWithReplaceClearsFocusedElementFirst() async throws {
        let log = CallLog()
        let primary = FakeAppDriver(name: "primary", log: log)
        let executor = StepExecutor(driver: primary)
        let step = FlowStep(action: "type", text: "new", replace: true)

        let outcome = await executor.execute(step)

        guard case .passed = outcome.status else {
            XCTFail("passed を期待したが \(outcome.status) だった"); return
        }
        // pre-snapshot はフォーカス要素の有無を見るための下ごしらえ(clearInput ロケータなし版と同じ)
        XCTAssertEqual(log.entries,
                       ["primary.snapshot", "primary.clearInput(ref:nil)", "primary.type(ref:nil)"],
                       "ロケータなしの replace も clear → type の順で撃つこと: \(log.entries)")
    }

    /// ロケータなしで replace を指定しなければ clearInput を呼ばないこと(上の裏側)
    func testTypeWithoutLocatorWithoutReplaceNeverClears() async throws {
        let log = CallLog()
        let primary = FakeAppDriver(name: "primary", log: log)
        let executor = StepExecutor(driver: primary)
        let step = FlowStep(action: "type", text: "new")

        let outcome = await executor.execute(step)

        guard case .passed = outcome.status else {
            XCTFail("passed を期待したが \(outcome.status) だった"); return
        }
        XCTAssertEqual(log.entries, ["primary.type(ref:nil)"],
                       "replace 未指定では clear もその下ごしらえの snapshot も撃たないこと: \(log.entries)")
    }

    /// replace: false(既定・未指定)は今までどおり clearInput を一切呼ばないこと(退行防止)
    func testTypeWithoutReplaceNeverCallsClearInput() async throws {
        let log = CallLog()
        let primary = FakeAppDriver(name: "primary", log: log,
                                    snapshotElements: [[inputField(ref: 1, id: "field", value: "old")]])
        let executor = StepExecutor(driver: primary)
        let step = FlowStep(action: "type", locator: FlowLocator(id: "field"), text: "new")

        let outcome = await executor.execute(step)

        guard case .passed = outcome.status else {
            XCTFail("passed を期待したが \(outcome.status) だった"); return
        }
        XCTAssertFalse(log.entries.contains { $0.hasPrefix("primary.clearInput(") },
                       "replace 未指定では clearInput を呼んではいけない(退行防止): \(log.entries)")
    }

    /// **replace の読み返し期待値は `text` だけ**(既存値を連結しない)。ここが誤って
    /// `existingValue + text` のままだと、前方一致の取りこぼし("ne")は expected("oldnew")との
    /// prefix 関係を持たないため TypeReadback.plan が `.unverifiable` と判定し、追送せず黙って
    /// 受理してしまう(取りこぼしたまま成功したことになる)。expected が正しく "new" であれば
    /// "ne" は前方一致として認識され、追送("w")を経て "new" に収束する ―― この追送が
    /// **実際に起きること**(type 呼び出しが2回になること)で expected の値を間接的に確かめる
    func testTypeWithReplaceVerifiesAgainstTextAloneNotPriorPlusText() async throws {
        let log = CallLog()
        let primary = FakeAppDriver(
            name: "primary", log: log,
            snapshotElements: [
                [inputField(ref: 1, id: "field", value: "old")],   // 解決(クリア前の値)
                [inputField(ref: 1, id: "field", value: nil)],     // clear 事後検証: 消えている
                [inputField(ref: 1, id: "field", value: "ne")],    // type 直後の読み返し: 取りこぼし
            ])
        primary.verifiesTypedText = false
        var mutations = 0
        primary.onMutatingCall = {
            mutations += 1
            // clearInput(1回目)・初回 type(2回目)では値を進めない。追送(3回目)で "new" に収束させる
            guard mutations > 2 else { return }
            primary.snapshotElements.append([self.inputField(ref: 1, id: "field", value: "new")])
        }
        let executor = StepExecutor(driver: primary)
        let step = FlowStep(action: "type", locator: FlowLocator(id: "field"), text: "new", replace: true)

        let outcome = await executor.execute(step)

        guard case .passed = outcome.status else {
            XCTFail("追送→収束で passed を期待したが \(outcome.status) だった"); return
        }
        XCTAssertEqual(log.entries.filter { $0.hasPrefix("primary.type(ref:1)") }.count, 2,
                       "expected が \"new\" でなければ「ne」は検証不能として即受理され、追送は"
                           + "起きないはず(expected が誤って \"oldnew\" だとここが1のまま): \(log.entries)")
        XCTAssertEqual(log.entries.filter { $0.hasPrefix("primary.clearInput(ref:1)") }.count, 1)
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
        XCTAssertEqual(outcome.driverFallback, "fell back to XCUITest")
        // 末尾に続く primary.snapshot は swipe 後の静止待ち(settledSignature)
        XCTAssertEqual(Array(log.entries.prefix(2)), ["primary.swipe(throws)", "typedriver.swipe"])
        XCTAssertTrue(log.entries.dropFirst(2).allSatisfy { $0 == "primary.snapshot" },
                      "静止待ち以外が混ざっている: \(log.entries)")
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

        XCTAssertEqual(outcome.driverFallback, "fell back to XCUITest")
        XCTAssertEqual(log.entries.first, "typedriver.swipe", "primary を無駄打ちしてはいけない")
        XCTAssertTrue(log.entries.dropFirst().allSatisfy { $0 == "primary.snapshot" },
                      "swipe 後は静止待ちの snapshot だけが続くはず: \(log.entries)")
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
        // swipe 後の snapshot は静止待ち(settledSignature)。ランナーが /swipe を整定対象から
        // 外したぶんをホスト側で持つため、swipe の**あとに** primary の snapshot が続くのが正
        XCTAssertEqual(log.entries.first, "primary.swipe", "swipe は primary(in-app)で実行するはず")
        XCTAssertTrue(log.entries.dropFirst().allSatisfy { $0 == "primary.snapshot" },
                      "静止待ち以外の呼び出しが混ざっている: \(log.entries)")
    }

    /// tap(holdSeconds:) の 501 切替は ref を typeDriver 側 snapshot で取り直すこと(ref はブリッジごとに別名前空間)
    func testTapHoldSeconds501FallsBackAndReresolvesRef() async throws {
        let log = CallLog()
        let primary = FakeAppDriver(name: "primary", log: log,
                                    snapshotElements: [[element(ref: 1, id: "btn_long")]])
        primary.pressError = DriverError.badResponse(status: 501, body: "compose では press が効きません")
        let typeDriver = FakeAppDriver(name: "typedriver", log: log,
                                       snapshotElements: [[element(ref: 9, id: "btn_long")]])
        let executor = StepExecutor(driver: primary, typeDriver: typeDriver)
        let step = FlowStep(action: "tap", locator: FlowLocator(id: "btn_long"), duration: 1.0)

        let outcome = await executor.execute(step)

        guard case .passed = outcome.status else {
            XCTFail("501 からの切替で passed を期待したが \(outcome.status) だった")
            return
        }
        XCTAssertEqual(outcome.driverFallback, "fell back to XCUITest")
        XCTAssertEqual(log.entries, [
            "primary.snapshot",
            "primary.press(throws)",
            "typedriver.snapshot",
            "typedriver.press(ref:9)",
        ], "typeDriver 側の ref(9)で press すべき")
    }

    /// FlowStep.duration(tap の holdSeconds)は主経路にもフォールバック経路にも届くこと(旧実装は両方 1.0 固定で、
    /// DSL の press(duration:)が黙って無効化されていた)
    func testTapHoldSecondsIsPassedThroughBothPaths() async throws {
        let log = CallLog()
        let primary = FakeAppDriver(name: "primary", log: log,
                                    snapshotElements: [[element(ref: 1, id: "btn_long")]])
        let executor = StepExecutor(driver: primary)
        _ = await executor.execute(
            FlowStep(action: "tap", locator: FlowLocator(id: "btn_long"), duration: 3.5))
        XCTAssertEqual(primary.lastPressDuration, 3.5)

        let fallbackLog = CallLog()
        let failing = FakeAppDriver(name: "primary", log: fallbackLog,
                                    snapshotElements: [[element(ref: 1, id: "btn_long")]])
        failing.pressError = DriverError.badResponse(status: 501, body: "compose では press が効きません")
        let typeDriver = FakeAppDriver(name: "typedriver", log: fallbackLog,
                                       snapshotElements: [[element(ref: 9, id: "btn_long")]])
        let fallbackExecutor = StepExecutor(driver: failing, typeDriver: typeDriver)
        _ = await fallbackExecutor.execute(
            FlowStep(action: "tap", locator: FlowLocator(id: "btn_long"), duration: 3.5))
        XCTAssertEqual(typeDriver.lastPressDuration, 3.5)
    }

    /// duration 未指定(既定 holdSeconds=0)は通常タップになり、press は呼ばれないこと
    /// (tap/press 統合の要点: 既定を境に呼び先が変わる)
    func testTapDurationDefaultsToPlainTapWhenUnset() async throws {
        let log = CallLog()
        let primary = FakeAppDriver(name: "primary", log: log,
                                    snapshotElements: [[element(ref: 1, id: "btn_long")]])
        let executor = StepExecutor(driver: primary)
        _ = await executor.execute(FlowStep(action: "tap", locator: FlowLocator(id: "btn_long")))
        XCTAssertNil(primary.lastPressDuration, "既定は通常タップで press を呼ばないはず")
        XCTAssertEqual(log.entries.last, "primary.tap(ref:1)")
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
        XCTAssertEqual(outcome.driverFallback, "fell back to XCUITest")
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
    // 以下は焦点待ち(awaitFocusBeforePressEnter)を通るので、409/typeDriver 切替の検証は
    // primary 側に focused 要素を用意して即進行させる(待ち自体は下の MARK で別途検証する)

    /// 1枚目から focused な要素があれば、焦点確認は1回で足りすぐ実行すること
    func testPressEnterWithImmediateFocusChecksOnceThenExecutes() async throws {
        let log = CallLog()
        let primary = FakeAppDriver(name: "primary", log: log,
                                    snapshotElements: [[inputField(ref: 1, id: "field", focused: true)]])
        let executor = StepExecutor(driver: primary)
        let step = FlowStep(action: "pressEnter")

        let outcome = await executor.execute(step)

        guard case .passed = outcome.status else {
            XCTFail("pressEnter の passed を期待したが \(outcome.status) だった")
            return
        }
        XCTAssertNil(outcome.driverFallback, "既に焦点があるので注記は付かない")
        XCTAssertEqual(log.entries, ["primary.snapshot", "primary.pressEnter"],
                       "焦点確認は1回で足りること")
    }

    /// 409(inapp が Compose 以外の入力欄/フォーカス無しで返す)はリアクティブに typeDriver へ
    /// 切り替えること(type の 409 フォールバックと同じ形)
    func testPressEnter409FallsBackToTypeDriverReactively() async throws {
        let log = CallLog()
        let primary = FakeAppDriver(name: "primary", log: log,
                                    snapshotElements: [[inputField(ref: 1, id: "field", focused: true)]])
        primary.pressEnterError = DriverError.badResponse(status: 409, body: "not compose")
        let typeDriver = FakeAppDriver(name: "typedriver", log: log)
        let executor = StepExecutor(driver: primary, typeDriver: typeDriver)
        let step = FlowStep(action: "pressEnter")

        let outcome = await executor.execute(step)

        guard case .passed = outcome.status else {
            XCTFail("409 からの typeDriver 切替による passed を期待したが \(outcome.status) だった")
            return
        }
        XCTAssertEqual(outcome.driverFallback, "fell back to XCUITest")
        XCTAssertEqual(log.entries,
                       ["primary.snapshot", "primary.pressEnter(throws)", "typedriver.pressEnter"])
    }

    /// 409 以外のエラーは typeDriver へ切り替えず、そのまま失敗させること
    func testPressEnterNon409DoesNotUseTypeDriver() async throws {
        let log = CallLog()
        let primary = FakeAppDriver(name: "primary", log: log,
                                    snapshotElements: [[inputField(ref: 1, id: "field", focused: true)]])
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
        let primary = FakeAppDriver(name: "primary", log: log,
                                    snapshotElements: [[inputField(ref: 1, id: "field", focused: true)]])
        primary.pressEnterError = DriverError.badResponse(status: 409, body: "not compose")
        let executor = StepExecutor(driver: primary)
        let step = FlowStep(action: "pressEnter")

        let outcome = await executor.execute(step)

        guard case .failed = outcome.status else {
            XCTFail("typeDriver 無しでの 409 失敗を期待したが \(outcome.status) だった")
            return
        }
    }

    // MARK: - pressEnter の焦点待ち(awaitFocusBeforePressEnter。MCP の awaitFocus と値を共有)

    /// 1枚目は focused なし・2枚目で focused あり → 実行され、snapshot は2回以上呼ばれ、警告なし
    func testPressEnterWaitsForFocusThenExecutesWithoutWarning() async throws {
        let log = CallLog()
        let primary = FakeAppDriver(
            name: "primary", log: log,
            snapshotElements: [[inputField(ref: 1, id: "field", focused: false)],
                              [inputField(ref: 1, id: "field", focused: true)]])
        let executor = StepExecutor(driver: primary)
        let step = FlowStep(action: "pressEnter")

        let outcome = await executor.execute(step)

        guard case .passed = outcome.status else {
            XCTFail("pressEnter の passed を期待したが \(outcome.status) だった")
            return
        }
        XCTAssertNil(outcome.driverFallback, "焦点が立ったので注記は付かない")
        XCTAssertGreaterThanOrEqual(log.entries.filter { $0 == "primary.snapshot" }.count, 2)
        XCTAssertEqual(log.entries.last, "primary.pressEnter")
    }

    /// **どこにも** focused == true が立たないまま(pressEnter に特定の対象は無いので、
    /// 判定は「木のどこかが focused か」— DSL の awaitFocusBeforePressEnter 参照)→
    /// タイムアウト後に実行され、警告注記が driverFallback に載る。実時間 waitSeconds(1.5s)を払う
    func testPressEnterTimesOutWithWarningWhenFocusNeverArrives() async throws {
        let log = CallLog()
        let primary = FakeAppDriver(
            name: "primary", log: log,
            snapshotElements: [[inputField(ref: 1, id: "field", focused: false)]])
        let executor = StepExecutor(driver: primary)
        let step = FlowStep(action: "pressEnter")

        let outcome = await executor.execute(step)

        guard case .passed = outcome.status else {
            XCTFail("タイムアウトしても拒否せず実行されることを期待したが \(outcome.status) だった")
            return
        }
        XCTAssertEqual(outcome.driverFallback?.contains("took focus"), true, "\(outcome.driverFallback ?? "nil")")
        XCTAssertEqual(log.entries.last, "primary.pressEnter", "拒否せず実行まで進むこと")
    }

    // MARK: - hideKeyboard(ロケータ無し。pressEnter と同じくロケータ解決を挟まない経路)

    func testHideKeyboardCallsDriverDirectlyWithoutSnapshot() async throws {
        let log = CallLog()
        let primary = FakeAppDriver(name: "primary", log: log)
        let executor = StepExecutor(driver: primary)
        let step = FlowStep(action: "hideKeyboard")

        let outcome = await executor.execute(step)

        guard case .passed = outcome.status else {
            XCTFail("hideKeyboard の passed を期待したが \(outcome.status) だった")
            return
        }
        XCTAssertTrue(log.entries.contains("primary.hideKeyboard"), "\(log.entries)")
    }

    /// 501(このドライバは原理的に非対応)はリアクティブに typeDriver へ切り替えること。
    /// pressEnter の 409 切替と違い、hideKeyboard は isEngineIncapable(501/ルート不明404)で判定する
    /// (409 は「今フォーカス無し」等の一時的競合で、実行不能の申告ではないため)
    func testHideKeyboard501FallsBackToTypeDriverReactively() async throws {
        let log = CallLog()
        let primary = FakeAppDriver(name: "primary", log: log)
        primary.hideKeyboardError = DriverError.badResponse(status: 501, body: "not supported")
        let typeDriver = FakeAppDriver(name: "typedriver", log: log)
        let executor = StepExecutor(driver: primary, typeDriver: typeDriver)
        let step = FlowStep(action: "hideKeyboard")

        let outcome = await executor.execute(step)

        guard case .passed = outcome.status else {
            XCTFail("501 からの typeDriver 切替による passed を期待したが \(outcome.status) だった")
            return
        }
        XCTAssertEqual(outcome.driverFallback, "fell back to XCUITest")
        XCTAssertEqual(log.entries, ["primary.hideKeyboard(throws)", "typedriver.hideKeyboard"])
    }

    // MARK: - keyboardIsShown / keyboardIsNotShown(ロケータ無し。開閉アニメーションを待つポーリング)

    /// キーボードが非表示→表示へ変わる過渡を、即失敗にせず timeout まで待って pass すること
    /// (1回のスナップショット照会だけだとフレークする契約の検証)
    func testKeyboardShownPollsUntilShown() async throws {
        let log = CallLog()
        let primary = FakeAppDriver(name: "primary", log: log, snapshotElements: [[]])
        primary.keyboardShownFrames = [false, true]
        let executor = StepExecutor(driver: primary)
        let step = FlowStep(assert: "keyboardShown", timeout: 3)

        guard case .passed = await executor.execute(step).status else {
            XCTFail("表示に変わったら pass するはず"); return
        }
        XCTAssertGreaterThan(primary.snapshotCallCount, 1, "1回の照会で決めず、状態変化までポーリングすること")
    }

    /// keyboardShown の裏返し: 表示→非表示へ変わる過渡を待って pass すること
    func testKeyboardNotShownPollsUntilHidden() async throws {
        let log = CallLog()
        let primary = FakeAppDriver(name: "primary", log: log, snapshotElements: [[]])
        primary.keyboardShownFrames = [true, false]
        let executor = StepExecutor(driver: primary)
        let step = FlowStep(assert: "keyboardNotShown", timeout: 3)

        guard case .passed = await executor.execute(step).status else {
            XCTFail("非表示に変わったら pass するはず"); return
        }
        XCTAssertGreaterThan(primary.snapshotCallCount, 1, "1回の照会で決めず、状態変化までポーリングすること")
    }

    /// keyboardShown が nil(判定不能: Android の旧ブリッジ・captureKeyboardStateOnNextSnapshot
    /// 未着火の両方であり得る)のとき、非表示への嘘の成功にせず明示的に failed で返すこと
    /// (nil を false 扱いすると keyboardIsNotShown が偽陽性で通ってしまう)
    func testKeyboardShownFailsWhenStateUnknown() async throws {
        let log = CallLog()
        // keyboardShownFrames を設定しない → SnapshotResponse.keyboardShown は常に nil
        let primary = FakeAppDriver(name: "primary", log: log, snapshotElements: [[]])
        let executor = StepExecutor(driver: primary)
        let step = FlowStep(assert: "keyboardShown", timeout: 0)

        guard case .failed(let message) = await executor.execute(step).status else {
            XCTFail("状態を取得できないときは failed のはず"); return
        }
        XCTAssertTrue(message.contains("cannot determine"), "\(message)")
    }

    // MARK: - clearInput

    /// clearInput(セレクタあり) → 解決した ref で driver.clearInput が呼ばれること
    func testClearInputWithSelectorUsesResolvedRef() async throws {
        let log = CallLog()
        let primary = FakeAppDriver(name: "primary", log: log,
                                    snapshotElements: [[element(ref: 7, id: "field_note")]])
        let executor = StepExecutor(driver: primary)
        let step = FlowStep(action: "clearInput", locator: FlowLocator(id: "field_note"))

        let outcome = await executor.execute(step)

        guard case .passed = outcome.status else {
            XCTFail("clearInput の passed を期待したが \(outcome.status) だった"); return
        }
        XCTAssertTrue(log.entries.contains("primary.clearInput(ref:7)"),
                      "解決した ref でクリアすべき: \(log.entries)")
    }

    /// clearInput(ロケータなし) → clearInput(ref: nil)。pre-snapshot(実装2の事後検証の下ごしらえ。
    /// フォーカス要素の有無を見るために必ず撮る)はフォーカス要素が無いので、後段の事後検証は
    /// スキップして従来どおり成功する
    func testClearInputWithoutLocatorClearsFocusedElement() async throws {
        let log = CallLog()
        let primary = FakeAppDriver(name: "primary", log: log)
        let executor = StepExecutor(driver: primary)
        let step = FlowStep(action: "clearInput")

        let outcome = await executor.execute(step)

        guard case .passed = outcome.status else {
            XCTFail("clearInput の passed を期待したが \(outcome.status) だった"); return
        }
        XCTAssertEqual(log.entries, ["primary.snapshot", "primary.clearInput(ref:nil)"],
                       "ロケータ解決は挟まないが、事後検証の下ごしらえの pre-snapshot は1回撮る")
    }

    /// clearInput で primary が 409(対象なし)→ typeDriver 側の clearInput が呼ばれ、
    /// ステータスは passed + driverFallback になること
    func testClearInput409FallsBackToTypeDriverReactively() async throws {
        let log = CallLog()
        let primary = FakeAppDriver(name: "primary", log: log,
                                    snapshotElements: [[element(ref: 1, id: "field_note")]])
        primary.clearInputError = DriverError.badResponse(status: 409, body: "no focused input")
        let typeDriver = FakeAppDriver(name: "typedriver", log: log,
                                       snapshotElements: [[element(ref: 2, id: "field_note")]])
        let executor = StepExecutor(driver: primary, typeDriver: typeDriver)
        let step = FlowStep(action: "clearInput", locator: FlowLocator(id: "field_note"))

        let outcome = await executor.execute(step)

        guard case .passed = outcome.status else {
            XCTFail("409 からの typeDriver 切替による passed を期待したが \(outcome.status) だった"); return
        }
        XCTAssertEqual(outcome.driverFallback, "fell back to XCUITest")
        // 末尾の typedriver.snapshot は事後検証(フォールバック経路にも例外を作らない契約)
        XCTAssertEqual(log.entries, [
            "primary.snapshot",
            "primary.clearInput(throws)",
            "typedriver.snapshot",
            "typedriver.clearInput(ref:2)",
            "typedriver.snapshot",
        ])
    }

    /// **422 も 409 と同じ扱い**にすること。XCUITest ランナーは同じ事情(フォーカス欄が無い/
    /// 消し切れない)を 409 では返せない — 409 は SessionRecoveryDriver がセッション消失と
    /// 断定して activate を撃つため 422 に分けてある(BridgeRouter.handleClear)。
    /// ここを 409 だけに戻すと、hybrid の in-app→XCUITest の再試行が丸ごと不発になる
    func testClearInput422FallsBackToTypeDriverLike409() async throws {
        let log = CallLog()
        let primary = FakeAppDriver(name: "primary", log: log,
                                    snapshotElements: [[element(ref: 1, id: "field_note")]])
        primary.clearInputError = DriverError.badResponse(
            status: 422, body: "フォーカスされた入力欄がありません")
        let typeDriver = FakeAppDriver(name: "typedriver", log: log,
                                       snapshotElements: [[element(ref: 2, id: "field_note")]])
        let executor = StepExecutor(driver: primary, typeDriver: typeDriver)
        let step = FlowStep(action: "clearInput", locator: FlowLocator(id: "field_note"))

        let outcome = await executor.execute(step)

        guard case .passed = outcome.status else {
            XCTFail("422 からの typeDriver 切替による passed を期待したが \(outcome.status) だった"); return
        }
        XCTAssertEqual(outcome.driverFallback, "fell back to XCUITest")
        XCTAssertTrue(log.entries.contains("typedriver.clearInput(ref:2)"),
                      "422 でも typeDriver へ回すこと: \(log.entries)")
    }

    /// ロケータ無し版でも 409 は typeDriver(ref: nil)へフォールバックすること(pressEnter と同じ形)。
    /// pre-snapshot(実装2の下ごしらえ)は 409 の前に必ず1回撮る
    func testClearInputWithoutLocator409FallsBackToTypeDriver() async throws {
        let log = CallLog()
        let primary = FakeAppDriver(name: "primary", log: log)
        primary.clearInputError = DriverError.badResponse(status: 409, body: "no focused input")
        let typeDriver = FakeAppDriver(name: "typedriver", log: log)
        let executor = StepExecutor(driver: primary, typeDriver: typeDriver)
        let step = FlowStep(action: "clearInput")

        let outcome = await executor.execute(step)

        guard case .passed = outcome.status else {
            XCTFail("409 からの typeDriver 切替による passed を期待したが \(outcome.status) だった"); return
        }
        XCTAssertEqual(outcome.driverFallback, "fell back to XCUITest")
        XCTAssertEqual(log.entries,
                       ["primary.snapshot", "primary.clearInput(throws)", "typedriver.clearInput(ref:nil)"])
    }

    // MARK: - clearInput の事後検証(実装2: ブリッジが 200 を返しても消えていない場合の保険)

    /// clearInput(セレクタあり)成功後、同じ driver の snapshot で値が残っていることが分かったら
    /// typeDriver へフォールバックし、そちらで消えていれば passed になること
    func testClearInputWithSelectorFallsBackWhenResidualValueRemains() async throws {
        let log = CallLog()
        // **残存 = クリア前後で同じ値**(値が変わっていれば消えたと見なす契約。placeholder が
        // value に出る実装があるため一致判定では見ない)
        let primary = FakeAppDriver(name: "primary", log: log, snapshotElements: [
            [inputField(ref: 7, id: "field_note", value: "residual")],
            [inputField(ref: 7, id: "field_note", value: "residual")],
        ])
        let typeDriver = FakeAppDriver(name: "typedriver", log: log, snapshotElements: [
            [inputField(ref: 2, id: "field_note", value: "residual")],
            [inputField(ref: 2, id: "field_note", value: nil)],
        ])
        let executor = StepExecutor(driver: primary, typeDriver: typeDriver)
        let step = FlowStep(action: "clearInput", locator: FlowLocator(id: "field_note"))

        let outcome = await executor.execute(step)

        guard case .passed = outcome.status else {
            XCTFail("残存値検出→フォールバック成功による passed を期待したが \(outcome.status) だった"); return
        }
        XCTAssertEqual(outcome.driverFallback, "fell back to XCUITest")
        XCTAssertTrue(log.entries.contains("primary.clearInput(ref:7)"))
        XCTAssertTrue(log.entries.contains("typedriver.clearInput(ref:2)"),
                      "残存値が消えるまで typeDriver へフォールバックすべき: \(log.entries)")
    }

    /// clearInput(セレクタあり)で primary・typeDriver 双方とも値が残っていれば failed になり、
    /// メッセージに残存値を含めること
    func testClearInputWithSelectorFailsWhenValueRemainsAfterFallback() async throws {
        let log = CallLog()
        let primary = FakeAppDriver(name: "primary", log: log, snapshotElements: [
            [inputField(ref: 7, id: "field_note", value: "still there")],
            [inputField(ref: 7, id: "field_note", value: "still there")],
        ])
        let typeDriver = FakeAppDriver(name: "typedriver", log: log, snapshotElements: [
            [inputField(ref: 2, id: "field_note", value: "still there")],
            [inputField(ref: 2, id: "field_note", value: "still there")],
        ])
        let executor = StepExecutor(driver: primary, typeDriver: typeDriver)
        let step = FlowStep(action: "clearInput", locator: FlowLocator(id: "field_note"))

        let outcome = await executor.execute(step)

        guard case .failed(let message) = outcome.status else {
            XCTFail("両ドライバとも残存値がある場合は failed を期待したが \(outcome.status) だった"); return
        }
        XCTAssertTrue(message.contains("still there"), "残った値をメッセージに含めるべき: \(message)")
    }

    /// clearInput(セレクタあり)成功後、value が placeholder と一致(= iOS の空欄が value に
    /// placeholder を返す実測仕様。空欄扱い)なら typeDriver へフォールバックしないこと
    func testClearInputWithSelectorSkipsFallbackWhenValueMatchesPlaceholder() async throws {
        let log = CallLog()
        let primary = FakeAppDriver(name: "primary", log: log, snapshotElements: [
            [inputField(ref: 7, id: "field_note", value: "old")],
            [inputField(ref: 7, id: "field_note", value: "type here", placeholder: "type here")],
        ])
        let typeDriver = FakeAppDriver(name: "typedriver", log: log)
        let executor = StepExecutor(driver: primary, typeDriver: typeDriver)
        let step = FlowStep(action: "clearInput", locator: FlowLocator(id: "field_note"))

        let outcome = await executor.execute(step)

        guard case .passed = outcome.status else {
            XCTFail("空(placeholder 一致)なら passed を期待したが \(outcome.status) だった"); return
        }
        XCTAssertNil(outcome.driverFallback, "フォールバックしてはいけない: \(log.entries)")
        XCTAssertEqual(typeDriver.snapshotCallCount, 0, "typeDriver 側は一切呼ばれないはず")
    }

    /// clearInput(ロケータなし)成功後、クリア前に覚えたフォーカス要素を事後 snapshot で identifier
    /// で突き合わせ、値が残っていれば typeDriver へフォールバックすること
    func testClearInputWithoutLocatorMatchesFocusedElementByIdentifierAndFallsBack() async throws {
        let log = CallLog()
        let primary = FakeAppDriver(name: "primary", log: log, snapshotElements: [
            [inputField(ref: 1, id: "field_note", value: "residual", focused: true)],
            [inputField(ref: 1, id: "field_note", value: "residual", focused: true)],
        ])
        let typeDriver = FakeAppDriver(name: "typedriver", log: log)
        let executor = StepExecutor(driver: primary, typeDriver: typeDriver)
        let step = FlowStep(action: "clearInput")

        let outcome = await executor.execute(step)

        guard case .passed = outcome.status else {
            XCTFail("残存値検出→typeDriver フォールバックによる passed を期待したが \(outcome.status) だった");
            return
        }
        XCTAssertEqual(outcome.driverFallback, "fell back to XCUITest")
        XCTAssertTrue(log.entries.contains("typedriver.clearInput(ref:nil)"),
                      "残存値が消えるまで typeDriver へフォールバックすべき: \(log.entries)")
    }

    /// clearInput(ロケータなし)成功時、フォーカス要素が特定できなければ事後検証をスキップし
    /// 従来どおり成功すること(検証できないことを失敗にしない)
    func testClearInputWithoutLocatorSkipsVerificationWhenNoFocusedElement() async throws {
        let log = CallLog()
        let primary = FakeAppDriver(name: "primary", log: log, snapshotElements: [
            [inputField(ref: 1, id: "other_field", value: "unrelated")],
        ])
        let executor = StepExecutor(driver: primary)
        let step = FlowStep(action: "clearInput")

        let outcome = await executor.execute(step)

        guard case .passed = outcome.status else {
            XCTFail("検証不能時は passed を期待したが \(outcome.status) だった"); return
        }
        XCTAssertNil(outcome.driverFallback)
        XCTAssertEqual(primary.snapshotCallCount, 1,
                       "フォーカス要素が無ければ事後 snapshot は撮らないはず: \(log.entries)")
    }

    // MARK: - swipeElementToElement

    /// 両要素の中心座標で drag が呼ばれること。duration 省略時は既定 1.5 秒が渡ること
    func testSwipeElementToElementDragsBetweenCenters() async throws {
        let log = CallLog()
        let from = framed(ref: 1, id: "handle_from", x: 0, y: 100, width: 20, height: 20)
        let to = framed(ref: 2, id: "handle_to", x: 200, y: 300, width: 40, height: 40)
        let primary = FakeAppDriver(name: "primary", log: log, snapshotElements: [[from, to]])
        let executor = StepExecutor(driver: primary)
        let step = FlowStep(action: "swipeElementToElement", locator: FlowLocator(id: "handle_from"),
                            endLocator: FlowLocator(id: "handle_to"))

        let outcome = await executor.execute(step)

        guard case .passed = outcome.status else {
            XCTFail("swipeElementToElement の passed を期待したが \(outcome.status) だった"); return
        }
        XCTAssertEqual(log.entries, ["primary.snapshot", "primary.drag"])
        XCTAssertEqual(primary.lastDragArgs?.fromX, 10)
        XCTAssertEqual(primary.lastDragArgs?.fromY, 110)
        XCTAssertEqual(primary.lastDragArgs?.toX, 220)
        XCTAssertEqual(primary.lastDragArgs?.toY, 320)
        XCTAssertEqual(primary.lastDragArgs?.durationSeconds, FlowStep.defaultSwipeDurationSeconds)
    }

    /// 終点が見つからないときは failed(メッセージに "end locator" を含む)
    func testSwipeElementToElementFailsWhenEndLocatorNotFound() async throws {
        let log = CallLog()
        let from = element(ref: 1, id: "handle_from")
        let primary = FakeAppDriver(name: "primary", log: log, snapshotElements: [[from]])
        let executor = StepExecutor(driver: primary)
        let step = FlowStep(action: "swipeElementToElement", locator: FlowLocator(id: "handle_from"),
                            endLocator: FlowLocator(id: "handle_missing"))

        let outcome = await executor.execute(step)

        guard case .failed(let msg) = outcome.status else {
            XCTFail("終点未解決での失敗を期待したが \(outcome.status) だった"); return
        }
        XCTAssertTrue(msg.contains("end locator"), "失敗理由に end locator を含むこと: \(msg)")
    }

    /// in-app 相当(drag が 501)なら始点・終点の両方を typeDriver 側で取り直して drag すること
    func testSwipeElementToElementFallsBackToTypeDriverWhenEngineIncapable() async throws {
        let log = CallLog()
        let from = framed(ref: 1, id: "handle_from", x: 0, y: 100, width: 20, height: 20)
        let to = framed(ref: 2, id: "handle_to", x: 200, y: 300, width: 40, height: 40)
        let primary = FakeAppDriver(name: "primary", log: log, snapshotElements: [[from, to]])
        primary.dragError = DriverError.badResponse(status: 501, body: "in-app では drag が効きません")
        let typeFrom = framed(ref: 3, id: "handle_from", x: 0, y: 100, width: 20, height: 20)
        let typeTo = framed(ref: 4, id: "handle_to", x: 200, y: 300, width: 40, height: 40)
        let typeDriver = FakeAppDriver(name: "typedriver", log: log, snapshotElements: [[typeFrom, typeTo]])
        let executor = StepExecutor(driver: primary, typeDriver: typeDriver)
        let step = FlowStep(action: "swipeElementToElement", locator: FlowLocator(id: "handle_from"),
                            endLocator: FlowLocator(id: "handle_to"))

        let outcome = await executor.execute(step)

        guard case .passed = outcome.status else {
            XCTFail("501 からの typeDriver 切替による passed を期待したが \(outcome.status) だった"); return
        }
        XCTAssertEqual(outcome.driverFallback, "fell back to XCUITest")
        XCTAssertTrue(log.entries.contains("primary.drag(throws)"), "まず primary を試すこと: \(log.entries)")
        XCTAssertTrue(log.entries.contains("typedriver.drag"), "501 なら typeDriver へ回すこと: \(log.entries)")
        XCTAssertEqual(typeDriver.lastDragArgs?.fromX, 10)
        XCTAssertEqual(typeDriver.lastDragArgs?.toX, 220)
    }

    // MARK: - 探索直後に容器の外の ghost を掴む(Compose iOS の上流制約)

    /// 容器と交差しない子(ghost)を検出できること。**交差していれば ghost ではない**(通常の行)
    func testGhostDetectionFindsRowsReportedOutsideTheContainer() {
        let container = framed(ref: 100, id: "list_rows", x: 16, y: 230, width: 370, height: 462,
                               depth: 1)
        let inside1 = framed(ref: 1, id: "row_28", x: 16, y: 300, width: 370, height: 56, depth: 2)
        let inside2 = framed(ref: 2, id: "row_29", x: 16, y: 360, width: 370, height: 56, depth: 2)
        let ghost = framed(ref: 3, id: "row_30", x: 16, y: 783, width: 370, height: 56, depth: 2)
        let elements = [container, inside1, inside2, ghost]

        XCTAssertTrue(StepExecutor.isOutsideContainer(ghost, in: elements),
                      "容器の外に並ぶ行は ghost として検出すること")
        XCTAssertFalse(StepExecutor.isOutsideContainer(inside1, in: elements),
                       "容器と交差する行は通常の行(掴み直さない)")
    }

    /// **縁をまたぐ行は「掴み直し」の対象にしない**(2026-08-05 に試して撤回)。
    /// 掴み直しの対象を「容器に収まっていない要素」へ広げたら S0110 が **2/10 → 5/10 に悪化**した
    /// (縁で救済スワイプを撃つと数 pt 動き、その古い座標でタップして自傷する)。
    /// **またぎは探索ループの見切れ判定が担当する** —— あちらは掴む前に送るので座標が古くならない。
    /// 容器を返せること自体は必要(返せないと見切れ判定が画面基準に落ちる)
    func testStraddlingRowResolvesItsContainerButIsNotAGhost() {
        let container = framed(ref: 100, id: "list_rows", x: 16, y: 230, width: 370, height: 462,
                               depth: 1)
        let inside1 = framed(ref: 1, id: "row_31", x: 16, y: 249, width: 370, height: 56, depth: 2)
        let inside2 = framed(ref: 2, id: "row_32", x: 16, y: 305, width: 370, height: 56, depth: 2)
        // 実採取の値: 原点はクリップ前(206)・高さはクリップ後(43)= 中心 227.5 は容器の外
        let straddling = framed(ref: 3, id: "row_30", x: 16, y: 206, width: 370, height: 43, depth: 2)
        let elements = [container, inside1, inside2, straddling]

        XCTAssertEqual(StepExecutor.clippingContainer(of: straddling, in: elements), container.frame,
                       "またぐ行でも容器を特定できないと、見切れ判定が画面基準に落ちる")
        XCTAssertFalse(StepExecutor.isOutsideContainer(straddling, in: elements),
                       "またぐ行は ghost ではない(掴み直しの対象にすると自傷する)")
        XCTAssertTrue(StepExecutor.isClippedByViewport(straddling, screen: container.frame),
                      "容器基準なら見切れとして検出でき、探索ループがもう1回送る")
        XCTAssertFalse(StepExecutor.isClippedByViewport(straddling,
                                                        screen: FTRect(x: 0, y: 0, width: 402,
                                                                       height: 874)),
                       "画面基準では見えていることになってしまう = 旧実装が止まっていた理由")
    }

    /// **探索の直後に ghost を掴んだら掴み直す**。掴んだままタップすると容器の外を撃って
    /// 黙って飲まれる(値が変わらず、後段の検証だけが落ちて原因から遠い)
    func testTapAfterSearchReResolvesWhenItGrabsAGhostRow() async throws {
        let log = CallLog()
        let container = framed(ref: 100, id: "list_rows", x: 16, y: 230, width: 370, height: 462,
                               depth: 1)
        let inside1 = framed(ref: 1, id: "row_28", x: 16, y: 300, width: 370, height: 56, depth: 2)
        let inside2 = framed(ref: 2, id: "row_29", x: 16, y: 360, width: 370, height: 56, depth: 2)
        let target = framed(ref: 3, id: "row_30", x: 16, y: 420, width: 370, height: 56, depth: 2)
        let ghost = framed(ref: 4, id: "row_30", x: 16, y: 783, width: 370, height: 56, depth: 2)
        let settled = framed(ref: 5, id: "row_30", x: 16, y: 430, width: 370, height: 56, depth: 2)
        // **探索は2枚消費する**(見つけた周回 + 静止確認)。台本がズレると ghost が
        // 解決時点に届かず、この防波堤を素通りしたまま緑になる
        let primary = FakeAppDriver(name: "primary", log: log, snapshotElements: [
            [container, inside1, inside2, target],   // 探索: 容器の中で見つかる
            [container, inside1, inside2, target],   // 探索の静止確認
            [container, inside1, inside2, ghost],    // 探索直後の解決: 容器の外(ghost)
            [container, inside1, inside2, settled],  // 掴み直し: 容器の中
        ])
        let executor = StepExecutor(driver: primary)
        let step = FlowStep(action: "tap", locator: FlowLocator(id: "row_30"),
                            direction: "up", maxSwipes: 2)

        let outcome = await executor.execute(step)

        guard case .passed = outcome.status else {
            XCTFail("掴み直して tap する想定だが \(outcome.status) だった"); return
        }
        XCTAssertTrue(log.entries.contains("primary.tap(ref:5)"),
                      "掴み直した容器内の行をタップすること: \(log.entries)")
        XCTAssertFalse(log.entries.contains("primary.tap(ref:4)"),
                       "ghost をタップしてはいけない: \(log.entries)")
        XCTAssertEqual(outcome.driverFallback?.contains("re-resolved"), true,
                       "掴み直したことを注記に残すこと: \(outcome.driverFallback ?? "nil") 呼び出し=\(log.entries)")
    }

    /// 掴み直しても ghost のままなら**注記を残す**(黙ってタップして飲まれるのが最悪)。
    /// **ghost の中心は画面内に置くこと**: 容器の外(= ghost)であることがこの経路の条件で、
    /// 中心まで画面外に出すと探索側のゲートが先に「届いていない」で落とし、この注記まで来ない
    func testTapAfterSearchNotesWhenTheGhostPersists() async throws {
        let log = CallLog()
        let container = framed(ref: 100, id: "list_rows", x: 16, y: 230, width: 370, height: 462,
                               depth: 1)
        let inside1 = framed(ref: 1, id: "row_28", x: 16, y: 300, width: 370, height: 56, depth: 2)
        let inside2 = framed(ref: 2, id: "row_29", x: 16, y: 360, width: 370, height: 56, depth: 2)
        let target = framed(ref: 3, id: "row_30", x: 16, y: 420, width: 370, height: 56, depth: 2)
        // 容器(230..692)の外・画面(高さ800)の中心内: 740..796 → 中心 768
        let ghost = framed(ref: 4, id: "row_30", x: 16, y: 740, width: 370, height: 56, depth: 2)
        let primary = FakeAppDriver(name: "primary", log: log, snapshotElements: [
            [container, inside1, inside2, target],
            [container, inside1, inside2, ghost],    // 以降ずっと ghost(尽きたら最後を繰り返す)
        ])
        let executor = StepExecutor(driver: primary)
        let step = FlowStep(action: "tap", locator: FlowLocator(id: "row_30"),
                            direction: "up", maxSwipes: 2)

        let outcome = await executor.execute(step)

        XCTAssertEqual(outcome.driverFallback?.contains("still reported outside"), true,
                       "救えなかったことを注記に残すこと: \(outcome.driverFallback ?? "nil") 呼び出し=\(log.entries)")
    }

    /// **救済で送った直後は、容器が次の1タッチを吸う**ので空打ちで肩代わりしてからタップする。
    /// 探索終端では以前からやっているが、救済経路には無かった —— 実測(S0110 を8並列):
    /// 救済が走った 18 件のうち 4 件が失敗、走らなかった 22 件は 0 件(p≈0.03)。
    /// 肩代わりを足すと **fix 0/48 対 base 8/48**(p≈0.006)。
    /// **iOS だけ**(releasesScrollTouch)。Android では 2pt のドラッグがクリックとして発火する。
    ///
    /// **台本は「救済スワイプまで到達する」形でなければ意味がない**(2026-08-05 に一度失敗した):
    /// 探索の中で解決できてしまうと `ghostSwipes` が 0 のままで、この経路自体を通らない
    func testRecoverySwipeIsFollowedByTheEmptyDrag() async throws {
        let log = CallLog()
        let container = framed(ref: 100, id: "list_rows", x: 16, y: 230, width: 370, height: 462,
                               depth: 1)
        let inside1 = framed(ref: 1, id: "row_28", x: 16, y: 300, width: 370, height: 56, depth: 2)
        let inside2 = framed(ref: 2, id: "row_29", x: 16, y: 360, width: 370, height: 56, depth: 2)
        let target = framed(ref: 3, id: "row_30", x: 16, y: 420, width: 370, height: 56, depth: 2)
        let ghost = framed(ref: 4, id: "row_30", x: 16, y: 783, width: 370, height: 56, depth: 2)
        let settled = framed(ref: 5, id: "row_30", x: 16, y: 430, width: 370, height: 56, depth: 2)
        let primary = FakeAppDriver(name: "primary", log: log, snapshotElements: [
            [container, inside1, inside2, target],   // 探索: 容器の中で見つかる
            [container, inside1, inside2, target],   // 探索の静止確認
            [container, inside1, inside2, ghost],    // 探索直後の解決: ghost
            [container, inside1, inside2, ghost],    // 掴み直し1回目: まだ ghost(= ここで救済が走る)
            [container, inside1, inside2, settled],  // 救済後: 容器の中
        ])
        let executor = StepExecutor(driver: primary, releasesScrollTouch: true)
        let step = FlowStep(action: "tap", locator: FlowLocator(id: "row_30"),
                            direction: "up", maxSwipes: 2)

        _ = await executor.execute(step)

        // この台本では探索が attempt 0 で見つけるので**終端の空打ちは撃たれない** ——
        // 横のドラッグが出るなら、それは救済の後の肩代わりだけ
        let vertical = primary.dragCalls.filter { $0.fromY != $0.toY }
        XCTAssertFalse(vertical.isEmpty, "救済は距離ぶんの縦ドラッグで戻す: \(primary.dragCalls)")
        // 空打ちは**横へ抜ける**(縦だと容器がスクロールとして消費する。emptyDragEndX 参照)
        let horizontal = primary.dragCalls.filter { $0.fromY == $0.toY }
        XCTAssertFalse(horizontal.isEmpty,
                       "救済の後に容器の1タッチを肩代わりしていない: \(primary.dragCalls)")
    }

    // MARK: - マップ系ジェスチャ(pinchOut/pinchIn・doubleTap・swipeBy)

    /// 対象未指定のピンチは画面全体(frame = screen・identifier なし)で撃たれること
    func testPinchOutWithoutLocatorTargetsTheWholeScreen() async throws {
        let log = CallLog()
        let primary = FakeAppDriver(name: "primary", log: log, snapshotElements: [[]])
        let executor = StepExecutor(driver: primary)

        let outcome = await executor.execute(FlowStep(action: "pinchOut", scale: 2.0))

        guard case .passed = outcome.status else {
            XCTFail("pinchOut の passed を期待したが \(outcome.status) だった"); return
        }
        XCTAssertEqual(primary.lastPinch?.frame, FTRect(x: 0, y: 0, width: 400, height: 800))
        XCTAssertNil(primary.lastPinch?.identifier)
        XCTAssertEqual(primary.lastPinch?.scale, 2.0)
        XCTAssertEqual(primary.lastPinch?.durationSeconds, FlowStep.defaultPinchDurationSeconds)
    }

    /// セレクタ付きは**要素の frame と identifier の両方**が渡ること
    /// (Android は frame の中心で合成し、XCUITest は identifier で要素を引くため。
    /// 片方でも落ちると、対象を指定したのに画面中心がピンチされる)
    func testPinchWithLocatorPassesFrameAndIdentifier() async throws {
        let log = CallLog()
        let map = framed(ref: 1, id: "map", x: 10, y: 40, width: 300, height: 200)
        let primary = FakeAppDriver(name: "primary", log: log, snapshotElements: [[map]])
        let executor = StepExecutor(driver: primary)
        let step = FlowStep(action: "pinchIn", locator: FlowLocator(id: "map"), scale: 0.5)

        let outcome = await executor.execute(step)

        guard case .passed = outcome.status else {
            XCTFail("pinchIn の passed を期待したが \(outcome.status) だった"); return
        }
        XCTAssertEqual(primary.lastPinch?.frame, FTRect(x: 10, y: 40, width: 300, height: 200))
        XCTAssertEqual(primary.lastPinch?.identifier, "map")
        XCTAssertEqual(primary.lastPinch?.scale, 0.5)
    }

    /// 向きと倍率が食い違ったら**撃たずに失敗**(撃つと「pinchOut と書いたのに縮小」が緑になる)
    func testPinchRejectsScaleThatContradictsDirection() async throws {
        let log = CallLog()
        let primary = FakeAppDriver(name: "primary", log: log, snapshotElements: [[]])
        let executor = StepExecutor(driver: primary)

        let outOutcome = await executor.execute(FlowStep(action: "pinchOut", scale: 0.5))
        let inOutcome = await executor.execute(FlowStep(action: "pinchIn", scale: 2.0))

        guard case .failed(let outMsg) = outOutcome.status else {
            XCTFail("pinchOut(scale<1) は failed を期待したが \(outOutcome.status) だった"); return
        }
        guard case .failed = inOutcome.status else {
            XCTFail("pinchIn(scale>1) は failed を期待したが \(inOutcome.status) だった"); return
        }
        XCTAssertTrue(outMsg.contains("scale > 1"), "何が期待値かを述べること: \(outMsg)")
        XCTAssertFalse(log.entries.contains("primary.pinch"), "撃たないこと: \(log.entries)")
    }

    /// in-app 相当(501)なら typeDriver へ回すこと。**座標・identifier はそのまま**渡る
    /// (ref と違いブリッジ間で意味が変わらないので取り直しが要らない)
    func testPinchFallsBackToTypeDriverWhenEngineIncapable() async throws {
        let log = CallLog()
        let primary = FakeAppDriver(name: "primary", log: log, snapshotElements: [[]])
        primary.pinchError = DriverError.badResponse(status: 501, body: "in-app では pinch が効きません")
        let typeDriver = FakeAppDriver(name: "typedriver", log: log, snapshotElements: [[]])
        let executor = StepExecutor(driver: primary, typeDriver: typeDriver)

        let outcome = await executor.execute(FlowStep(action: "pinchOut", scale: 3.0))

        guard case .passed = outcome.status else {
            XCTFail("501 からの切替による passed を期待したが \(outcome.status) だった"); return
        }
        XCTAssertEqual(outcome.driverFallback, "fell back to XCUITest")
        XCTAssertEqual(typeDriver.lastPinch?.scale, 3.0)
    }

    /// ダブルタップは要素の中心座標で撃たれること
    func testDoubleTapUsesElementCenter() async throws {
        let log = CallLog()
        let map = framed(ref: 1, id: "map", x: 100, y: 200, width: 40, height: 60)
        let primary = FakeAppDriver(name: "primary", log: log, snapshotElements: [[map]])
        let executor = StepExecutor(driver: primary)

        let outcome = await executor.execute(FlowStep(action: "doubleTap",
                                                      locator: FlowLocator(id: "map")))

        guard case .passed = outcome.status else {
            XCTFail("doubleTap の passed を期待したが \(outcome.status) だった"); return
        }
        XCTAssertEqual(primary.lastDoubleTap?.x, 120)
        XCTAssertEqual(primary.lastDoubleTap?.y, 230)
    }

    /// swipeBy は**斜め**(dx/dy とも非 0)の経路を、対象領域の中心を挟んで対称に作ること
    func testSwipeByBuildsDiagonalPathAroundTheCenter() async throws {
        let log = CallLog()
        let primary = FakeAppDriver(name: "primary", log: log, snapshotElements: [[]])
        let executor = StepExecutor(driver: primary)
        // 画面 400x800 の中心 (200, 400) から、幅の -0.5・高さの -0.25 ぶん指を動かす
        let step = FlowStep(action: "swipeBy", dxRatio: -0.5, dyRatio: -0.25)

        let outcome = await executor.execute(step)

        guard case .passed = outcome.status else {
            XCTFail("swipeBy の passed を期待したが \(outcome.status) だった"); return
        }
        XCTAssertEqual(primary.lastDragArgs?.fromX, 300)
        XCTAssertEqual(primary.lastDragArgs?.fromY, 500)
        XCTAssertEqual(primary.lastDragArgs?.toX, 100)
        XCTAssertEqual(primary.lastDragArgs?.toY, 300)
        XCTAssertEqual(primary.lastDragArgs?.durationSeconds, FlowStep.defaultSwipeDurationSeconds)
    }

    /// 移動量が小さすぎて指が動かないときは**成功にしない**(比率の書き間違いに気付けなくなる)
    func testSwipeByFailsWhenTheOffsetIsTooSmallToMove() async throws {
        let log = CallLog()
        let primary = FakeAppDriver(name: "primary", log: log, snapshotElements: [[]])
        let executor = StepExecutor(driver: primary)

        let outcome = await executor.execute(FlowStep(action: "swipeBy",
                                                      dxRatio: 0.001, dyRatio: 0))

        guard case .failed = outcome.status else {
            XCTFail("動かない swipeBy は failed を期待したが \(outcome.status) だった"); return
        }
        XCTAssertNil(primary.lastDragArgs, "撃たないこと")
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
        // **1周目は静止確認で2枚撮る**(プログラム的スクロールの取りこぼし対策)。
        // 空の2枚で静止 → スワイプ → 3枚目で発見、の並びにする
        let primary = FakeAppDriver(name: "primary", log: log, snapshotElements: [[], [], [row]])
        primary.dragError = DriverError.badResponse(status: 501, body: "未対応")
        let typeDriver = FakeAppDriver(name: "typedriver", log: log)
        let executor = StepExecutor(driver: primary, typeDriver: typeDriver,
                                    releasesScrollTouch: true)
        let step = FlowStep(action: "scrollTo", locator: FlowLocator(id: "row_40"), maxSwipes: 2)

        guard case .passed = await executor.execute(step).status else {
            XCTFail("スワイプ後の snapshot で見つかるので pass のはず"); return
        }
        XCTAssertTrue(log.entries.contains("primary.drag(throws)"), "まず primary を試すこと: \(log.entries)")
        XCTAssertTrue(log.entries.contains("typedriver.drag"),
                      "501 なら typeDriver へ回すこと: \(log.entries)")
    }

    /// uiFramework=="uikit"(RN 含む)は探索終端の空打ちをスキップすること。
    /// RN は Pressable の pressRetentionOffset(既定20pt)内に空打ちの終点が収まり onPress が
    /// 成立してしまい、`scrollTo` しただけで行が選択される(2026-08-08 E2E-RN S0100 実測)。
    /// shouldEmptyDrag のコメント参照
    func testEmptyDragSkippedWhenUIFrameworkIsUIKit() async throws {
        let log = CallLog()
        let row = framed(ref: 1, id: "row_40", x: 16, y: 300, width: 370, height: 56)
        // 1周目は静止確認で2枚撮ってからスワイプで見つける(既存 testEmptyDragFallsBack... と同じ台本)
        let primary = FakeAppDriver(name: "primary", log: log, snapshotElements: [[], [], [row]])
        let executor = StepExecutor(driver: primary, releasesScrollTouch: true, uiFramework: "uikit")
        let step = FlowStep(action: "scrollTo", locator: FlowLocator(id: "row_40"), maxSwipes: 2)

        guard case .passed = await executor.execute(step).status else {
            XCTFail("スワイプ後の snapshot で見つかるので pass のはず"); return
        }
        XCTAssertTrue(primary.dragCalls.isEmpty,
                      "uiFramework=uikit では終端の空打ちを撃たないこと: \(primary.dragCalls)")
    }

    /// uiFramework が "compose"、または判定できず nil(不明)のときは**従来どおり**空打ちを撃つこと。
    /// nil を skip 側へ倒すと、実機や AppBundleInspector が判定失敗した経路まで一括で挙動が変わる
    func testEmptyDragStillFiresForComposeAndUnknownFramework() async throws {
        let frameworks: [String?] = [nil, "compose"]
        for framework in frameworks {
            let log = CallLog()
            let row = framed(ref: 1, id: "row_40", x: 16, y: 300, width: 370, height: 56)
            let primary = FakeAppDriver(name: "primary", log: log, snapshotElements: [[], [], [row]])
            let executor = StepExecutor(driver: primary, releasesScrollTouch: true, uiFramework: framework)
            let step = FlowStep(action: "scrollTo", locator: FlowLocator(id: "row_40"), maxSwipes: 2)

            guard case .passed = await executor.execute(step).status else {
                XCTFail("スワイプ後の snapshot で見つかるので pass のはず (\(String(describing: framework)))")
                continue
            }
            XCTAssertFalse(primary.dragCalls.isEmpty,
                           "uiFramework=\(String(describing: framework)) では空打ちを撃つこと: \(primary.dragCalls)")
        }
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

        XCTAssertEqual(log.entries.first, "primary.swipe",
                       "drag の 501 で swipe まで typeDriver へ回してはいけない: \(log.entries)")
        XCTAssertTrue(log.entries.dropFirst().allSatisfy { $0 == "primary.snapshot" },
                      "swipe 後は静止待ちの snapshot だけが続くはず: \(log.entries)")
    }

    // MARK: - scrollToEdge の端判定(静止署名)

    /// 静止画面なのにラベルだけが取得のたびに振れても、端に着いたと判定して止まること。
    /// 実機(E2E-iOS/ios-xcuitest・2026-07-31)の再現: SwiftUI List では画面外の再利用セルが
    /// 別の行のラベルを名乗り A↔B で交互に振れる(frame は 1pt も動かない)。署名にラベルを
    /// 入れていた頃はこれで永久に収束せず、scrollToTop が毎回 maxSwipes 上限まで回って 44〜55s
    /// かかっていた。**署名からラベルを外すと落ちる**ので、この防波堤を消さないこと
    func testScrollToEdgeStopsWhenOnlyLabelsFlapBetweenSnapshots() async throws {
        let log = CallLog()
        // frame は全スナップショットで同一。ラベルだけが1要素ぶん交互に入れ替わる
        func frame(_ label: String) -> [ElementInfo] {
            [ElementInfo(ref: 1, type: "cell", identifier: "row_01", label: label, value: nil,
                         placeholder: nil, enabled: true,
                         frame: FTRect(x: 16, y: 100, width: 370, height: 56), depth: 0)]
        }
        // 上限まで回った場合でも尽きない長さを与える(尽きると最後が繰り返され交互でなくなる)
        let flapping = (0..<200).map { frame($0.isMultiple(of: 2) ? "行 12" : "行 21") }
        let primary = FakeAppDriver(name: "primary", log: log, snapshotElements: flapping)
        let executor = StepExecutor(driver: primary)
        let step = FlowStep(action: "scrollToEdge", direction: "up", maxSwipes: 20)

        let outcome = await executor.execute(step)

        guard case .passed = outcome.status else { XCTFail("scrollToEdge は pass のはず"); return }
        XCTAssertNil(outcome.driverFallback,
                     "端に着いたと判定できていれば上限打ち切りの注記は付かない: \(outcome.driverFallback ?? "-")")
        let swipes = log.entries.filter { $0 == "primary.swipe" }.count
        XCTAssertLessThanOrEqual(swipes, 3,
                                 "連続2回不変で端と判定して止まるはず(実際は \(swipes) 回スワイプ)")
    }

    /// 端に着く前(スクロールで frame が動いている間)は止まらないこと。
    /// 上の防波堤を「常に即 break」で通してしまう実装を落とす対の検証
    func testScrollToEdgeKeepsSwipingWhileFramesStillMove() async throws {
        let log = CallLog()
        func frame(_ y: Double) -> [ElementInfo] {
            [ElementInfo(ref: 1, type: "cell", identifier: "row_01", label: "行 01", value: nil,
                         placeholder: nil, enabled: true,
                         frame: FTRect(x: 16, y: y, width: 370, height: 56), depth: 0)]
        }
        // 毎回 y が動き続ける = 端に着かない。上限まで回って注記が付く
        let moving = (0..<200).map { frame(Double($0) * 10) }
        let primary = FakeAppDriver(name: "primary", log: log, snapshotElements: moving)
        let executor = StepExecutor(driver: primary)
        let step = FlowStep(action: "scrollToEdge", direction: "up", maxSwipes: 3)

        let outcome = await executor.execute(step)

        XCTAssertEqual(log.entries.filter { $0 == "primary.swipe" }.count, 3,
                       "動き続ける間は上限まで送ること: \(log.entries)")
        let note = outcome.driverFallback ?? ""
        XCTAssertTrue(note.contains("stopped at the limit of 3 (may not have reached the edge yet)"),
                      "端に着いていないことを注記すること: \(note)")
        // 動き続ける画面なので整定の打ち切りも同時に申告される(両方出るのが正しい)
        XCTAssertTrue(note.contains("the screen did not settle (poll limit)"),
                      "静止を確認できなかったことも注記すること: \(note)")
    }

    // MARK: - scroll/scrollToEdge/flick(scrollFrame:) の fail-fast(2026-08-08)

    /// 明示 scrollFrame が解決できないなら、`scroll` は全画面スワイプへ黙って退化せず
    /// 1本も振らずに失敗する(A1 と同じ理由: 無関係な要素を誤発火させ得るため)
    func testScrollFailsWithoutSwipingWhenScrollFrameDoesNotResolve() async throws {
        let log = CallLog()
        let primary = FakeAppDriver(name: "primary", log: log, snapshotElements: [[]])
        let executor = StepExecutor(driver: primary)
        var step = FlowStep(action: "scroll", direction: "up", maxSwipes: 3)
        step.scrollFrame = FlowLocator(id: "no_such_container")

        let outcome = await executor.execute(step)

        guard case .failed(let msg) = outcome.status else { XCTFail("失敗のはず: \(outcome.status)"); return }
        XCTAssertTrue(msg.contains("the swipe was not sent"), msg)
        XCTAssertFalse(log.entries.contains { $0.contains(".swipe") },
                       "scrollFrame が解決できないなら1本も振らないこと")
    }

    func testScrollToEdgeFailsWithoutSwipingWhenScrollFrameDoesNotResolve() async throws {
        let log = CallLog()
        let primary = FakeAppDriver(name: "primary", log: log, snapshotElements: [[]])
        let executor = StepExecutor(driver: primary)
        var step = FlowStep(action: "scrollToEdge", direction: "up", maxSwipes: 3)
        step.scrollFrame = FlowLocator(id: "no_such_container")

        let outcome = await executor.execute(step)

        guard case .failed(let msg) = outcome.status else { XCTFail("失敗のはず: \(outcome.status)"); return }
        XCTAssertTrue(msg.contains("the swipe was not sent"), msg)
        XCTAssertFalse(log.entries.contains { $0.contains(".swipe") },
                       "scrollFrame が解決できないなら1本も振らないこと")
    }

    func testFlickFailsWithoutSwipingWhenScrollFrameDoesNotResolve() async throws {
        let log = CallLog()
        let primary = FakeAppDriver(name: "primary", log: log, snapshotElements: [[]])
        let executor = StepExecutor(driver: primary)
        var step = FlowStep(action: "flick", direction: "topToBottom", maxSwipes: 1)
        step.scrollFrame = FlowLocator(id: "no_such_container")

        let outcome = await executor.execute(step)

        guard case .failed(let msg) = outcome.status else { XCTFail("失敗のはず: \(outcome.status)"); return }
        XCTAssertTrue(msg.contains("the flick was not sent"), msg)
        XCTAssertFalse(log.entries.contains { $0.contains(".swipe") || $0.contains(".drag") },
                       "scrollFrame が解決できないなら1本も振らないこと")
    }

    // MARK: - scrollFrameRect(MCP の ref 経由スクロール容器。2026-08-10)
    //
    // id の重複・欠落でセレクタが書けない容器のため、MCPServer が ref から起こした矩形を
    // そのまま渡す経路。DSL は使わない(scrollFrame は文字列のまま)。

    /// **rect は locator を経ずにそのまま容器になる**
    func testScrollContainerReturnsScrollFrameRectDirectly() async throws {
        let log = CallLog()
        let primary = FakeAppDriver(name: "primary", log: log, snapshotElements: [[]])
        let executor = StepExecutor(driver: primary)
        var step = FlowStep(action: "scrollTo", locator: FlowLocator(id: "target"))
        let rect = FTRect(x: 10, y: 20, width: 300, height: 400)
        step.scrollFrameRect = rect
        let snapshot = SnapshotResponse(sessionBundleID: nil,
                                        screen: FTRect(x: 0, y: 0, width: 400, height: 800),
                                        elements: [], truncatedCount: 0)
        XCTAssertEqual(executor.scrollContainer(step: step, in: snapshot, vertical: true), rect)
    }

    /// **rect があれば scrollFrame(セレクタ)の解決失敗を無視する** —— rect は「常に解決済み」
    /// 扱いなので、id が重複・欠落した容器を指すための逃げ道が fail-fast に巻き込まれない
    func testScrollContainerPrefersRectEvenWhenTheLocatorCannotResolve() async throws {
        let log = CallLog()
        let primary = FakeAppDriver(name: "primary", log: log, snapshotElements: [[]])
        let executor = StepExecutor(driver: primary)
        var step = FlowStep(action: "scrollTo", locator: FlowLocator(id: "target"))
        step.scrollFrame = FlowLocator(id: "no_such_container")
        let rect = FTRect(x: 10, y: 20, width: 300, height: 400)
        step.scrollFrameRect = rect
        let snapshot = SnapshotResponse(sessionBundleID: nil,
                                        screen: FTRect(x: 0, y: 0, width: 400, height: 800),
                                        elements: [], truncatedCount: 0)
        XCTAssertEqual(executor.scrollContainer(step: step, in: snapshot, vertical: true), rect)
    }

    /// rect だけを指定した(scrollFrame セレクタ無しの)`scrollTo` は、対象が最初から画面に
    /// 居るとき fail-fast にも掛からず素直に成功すること(rect 経路の配線確認)
    func testScrollToSucceedsWithScrollFrameRectAndNoLocator() async throws {
        let log = CallLog()
        let row = framed(ref: 1, id: "row_40", x: 16, y: 100, width: 370, height: 40)
        let primary = FakeAppDriver(name: "primary", log: log, snapshotElements: [[row]])
        let executor = StepExecutor(driver: primary)
        var step = FlowStep(action: "scrollTo", locator: FlowLocator(id: "row_40"), direction: "up")
        step.scrollFrameRect = FTRect(x: 0, y: 0, width: 400, height: 800)

        guard case .passed = await executor.execute(step).status else {
            XCTFail("画面に既に居るので見つかるはず"); return
        }
    }

    // MARK: - notExist(scroll:) の内蔵探索(exist(scroll:) の裏返し)

    /// スクロール探索を尽くしても見つからなければ、現在のビューポート(最終フレーム)でも
    /// 不在なので pass すること
    func testNotExistWithScrollPassesWhenNeverFoundDuringSearch() async throws {
        let log = CallLog()
        let primary = FakeAppDriver(name: "primary", log: log, snapshotElements: [[], [], []])
        let executor = StepExecutor(driver: primary)
        let step = FlowStep(assert: "notExists", locator: FlowLocator(id: "row_99"),
                            direction: "up", timeout: 0, maxSwipes: 2)

        guard case .passed = await executor.execute(step).status else {
            XCTFail("スクロール探索で見つからなければ pass のはず"); return
        }
    }

    /// スクロール探索中に見つかったら、現在ビューポートでの消滅待ち(通常のポーリング)には進まず
    /// 即座に不在検証を失敗させること(exist(scroll:) の裏返しなので判定は逆)
    func testNotExistWithScrollFailsWhenFoundDuringSearch() async throws {
        let log = CallLog()
        let row = framed(ref: 1, id: "row_99", x: 16, y: 300, width: 370, height: 56)
        let primary = FakeAppDriver(name: "primary", log: log, snapshotElements: [[], [row]])
        let executor = StepExecutor(driver: primary, releasesScrollTouch: true)
        let step = FlowStep(assert: "notExists", locator: FlowLocator(id: "row_99"),
                            direction: "up", timeout: 0, maxSwipes: 2)

        guard case .failed(let msg) = await executor.execute(step).status else {
            XCTFail("スクロール探索で見つかったら失敗のはず"); return
        }
        XCTAssertTrue(msg.contains("found via scroll search"), msg)
    }

    /// **`!result.found` を成功材料にしない**: 明示 scrollFrame が解決できず1本も振らずに
    /// 打ち切った場合も found=false になるが、それは「無いことを確認した」ではなく
    /// 探索していないだけ(2026-08-08)。notExist(scroll:) は exist(scroll:) と同じ文言で失敗する
    func testNotExistWithScrollFailsWhenScrollFrameDoesNotResolve() async throws {
        let log = CallLog()
        let primary = FakeAppDriver(name: "primary", log: log, snapshotElements: [[]])
        let executor = StepExecutor(driver: primary)
        var step = FlowStep(assert: "notExists", locator: FlowLocator(id: "row_99"),
                            direction: "up", timeout: 0, maxSwipes: 2)
        step.scrollFrame = FlowLocator(id: "no_such_container")

        guard case .failed(let msg) = await executor.execute(step).status else {
            XCTFail("scrollFrame 未解決は失敗のはず"); return
        }
        XCTAssertTrue(msg.contains("search was not run"), msg)
        XCTAssertFalse(log.entries.contains { $0.contains(".swipe") },
                       "scrollFrame が解決できないなら1本も振らないこと")
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

    /// **全幅の行では空打ちの終点が作れない**ので撃たない。左右どちらへも 4pt 出られないとき、
    /// 以前は開始点をそのまま返しており、始点=終点の 0.30 秒プレスは**タップとして成立する**
    /// —— emptyDragEndX の doc が禁じている「矩形の中で離す」を実装自身が踏んでいた。
    /// 実機(iPhone 実機・SmartNews の全幅セル)で `ft_scroll_to` が記事を開く形で 2/2 再現(2026-08-14)
    func testEmptyDragEndXRefusesWhenItCannotLeaveTheElement() {
        let screen = FTRect(x: 0, y: 0, width: 393, height: 852)

        let fullBleed = framed(ref: 1, id: "cell", x: 0, y: 103, width: 393, height: 116)
        XCTAssertNil(StepExecutor.emptyDragEndX(of: fullBleed, from: 196.5, screen: screen),
                     "全幅の行は抜けられないので撃たないこと")

        // インセットの行(自前 SUT の形)は従来どおり右へ抜ける
        let inset = framed(ref: 2, id: "row_30", x: 16, y: 270, width: 330, height: 56)
        XCTAssertEqual(StepExecutor.emptyDragEndX(of: inset, from: 181, screen: screen), 350)
        // 右端に貼り付いた行は左へ抜ける
        let atRight = framed(ref: 3, id: "row", x: 200, y: 270, width: 193, height: 56)
        XCTAssertEqual(StepExecutor.emptyDragEndX(of: atRight, from: 296, screen: screen), 196)

        // 返す点は必ず矩形の外(この不変条件が破れた瞬間にタップになる)
        for element in [inset, atRight] {
            let end = StepExecutor.emptyDragEndX(of: element, from: element.frame.centerX,
                                                 screen: screen)
            XCTAssertNotNil(end)
            if let end {
                XCTAssertFalse(end > element.frame.x && end < element.frame.x + element.frame.width,
                               "終点が矩形の中に留まるとクリックとして成立する: \(end)")
            }
        }
    }

    /// 配線: 探索終端の空打ちが**全幅の行では1本も撃たれない**こと。純粋関数だけを固定すると
    /// 「呼び出しを外す」変異が生き残るので、同じ台本をインセット行でも回して
    /// **陽性対照を同じテストの中に置く**(空打ちに到達しない台本だと無条件に緑になる)
    func testSearchTerminalDoesNotEmptyDragAFullBleedRow() async throws {
        /// 台本: 1回目は対象が無く、スワイプ後に出現する(= 終端の空打ちが掛かる周回)
        func horizontalDrags(targetX: Double, width: Double) async -> [(fromX: Double,
                                                                       fromY: Double,
                                                                       toX: Double, toY: Double)] {
            let log = CallLog()
            let container = framed(ref: 100, id: "list", x: 0, y: 0, width: 400, height: 700,
                                   depth: 1)
            let filler = framed(ref: 1, id: "cell_01", x: targetX, y: 100, width: width,
                                height: 116, depth: 2)
            let target = framed(ref: 2, id: "cell_40", x: targetX, y: 300, width: width,
                                height: 116, depth: 2)
            // 先頭を対象なしで数枚埋める(1周が何枚読むかに依存せず、必ず attempt > 0 で
            // 見つかるようにする = 終端の空打ちが掛かる周回に入る)
            let primary = FakeAppDriver(name: "primary", log: log, snapshotElements: [
                [container, filler],
                [container, filler],
                [container, filler],
                [container, filler, target],
            ])
            let executor = StepExecutor(driver: primary, releasesScrollTouch: true)
            _ = await executor.execute(FlowStep(action: "tap",
                                                locator: FlowLocator(id: "cell_40"),
                                                direction: "up", maxSwipes: 6))
            return primary.dragCalls.filter { $0.fromY == $0.toY }
        }

        // 陽性対照: インセット(画面 400 幅に対し 16..386)なら従来どおり空打ちが出る
        let inset = await horizontalDrags(targetX: 16, width: 370)
        XCTAssertFalse(inset.isEmpty, "台本が終端の空打ちに到達していない(この検査は無力)")

        // 本題: 全幅(0..400)では1本も出ない
        let fullBleed = await horizontalDrags(targetX: 0, width: 400)
        XCTAssertTrue(fullBleed.isEmpty,
                      "全幅の行に空打ちを撃ってはいけない(矩形から出られずタップになる): \(fullBleed)")
    }

    /// 掃討: 空打ちの呼び出しは**2箇所**(探索終端と救済の後)。救済側も全幅の行では撃たない。
    /// 陽性対照は `testRecoverySwipeIsFollowedByTheEmptyDrag`(同じ台本のインセット版で
    /// 横ドラッグが出ることを固定している)
    func testRecoveryEmptyDragIsSkippedForAFullBleedRow() async throws {
        let log = CallLog()
        let container = framed(ref: 100, id: "list_rows", x: 0, y: 230, width: 400, height: 462,
                               depth: 1)
        let inside1 = framed(ref: 1, id: "row_28", x: 0, y: 300, width: 400, height: 56, depth: 2)
        let inside2 = framed(ref: 2, id: "row_29", x: 0, y: 360, width: 400, height: 56, depth: 2)
        let target = framed(ref: 3, id: "row_30", x: 0, y: 420, width: 400, height: 56, depth: 2)
        let ghost = framed(ref: 4, id: "row_30", x: 0, y: 783, width: 400, height: 56, depth: 2)
        let settled = framed(ref: 5, id: "row_30", x: 0, y: 430, width: 400, height: 56, depth: 2)
        let primary = FakeAppDriver(name: "primary", log: log, snapshotElements: [
            [container, inside1, inside2, target],
            [container, inside1, inside2, target],
            [container, inside1, inside2, ghost],
            [container, inside1, inside2, ghost],
            [container, inside1, inside2, settled],
        ])
        let executor = StepExecutor(driver: primary, releasesScrollTouch: true)
        let step = FlowStep(action: "tap", locator: FlowLocator(id: "row_30"),
                            direction: "up", maxSwipes: 2)

        _ = await executor.execute(step)

        let horizontal = primary.dragCalls.filter { $0.fromY == $0.toY }
        XCTAssertTrue(horizontal.isEmpty,
                      "救済後の空打ちも全幅の行では撃たないこと: \(primary.dragCalls)")
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
        XCTAssertTrue(dom.contains("DOM path"), dom)
        XCTAssertTrue(dom.contains("nothing responds"), "無反応タップの可能性まで書くこと: \(dom)")

        let delegated = StepExecutor.webViewPathHint(snapshot("delegated"))
        XCTAssertTrue(delegated.contains("XCUITest"), delegated)
        XCTAssertFalse(delegated.contains("無反応"), "委譲側は合成タッチを使わないので警告しない")

        // dom-interop: DOM は読めるが操作は実タッチ(XCUITest)で行う第三のモード。
        // "dom" と違い DOM-tap の無反応な成功記録という弱点を持たないので、その警告は出さない
        let domInterop = StepExecutor.webViewPathHint(snapshot("dom-interop"))
        XCTAssertTrue(domInterop.contains("XCUITest"), domInterop)
        XCTAssertTrue(domInterop.lowercased().contains("real") || domInterop.lowercased().contains("touch"),
                      domInterop)
        XCTAssertFalse(domInterop.contains("無反応"), "実タッチを使うので無反応警告は出さない: \(domInterop)")
        XCTAssertFalse(domInterop.contains("nothing responds"), "DOM-tap の弱点は無い: \(domInterop)")

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

    /// 見切れ回収の必要距離(符号は dragGesture 規約: + = 指を上/左)。
    /// 全幅フリングの往復振動(RN 横カルーセルで maxSwipes 使い切り)を距離指定で置き換える根拠
    func testClipRecoveryJumpPerEdge() {
        let vp = FTRect(x: 16, y: 690, width: 370, height: 60)
        func el(_ x: Double, _ y: Double, _ w: Double, _ h: Double) -> ElementInfo {
            ElementInfo(ref: 1, type: "button", identifier: "tag", label: nil, value: nil,
                        placeholder: nil, enabled: true,
                        frame: FTRect(x: x, y: y, width: w, height: h), depth: 1)
        }
        // 右へはみ出し(右端 500 > 386)→ 指を左(+)・量 = 114 + 24
        XCTAssertEqual(StepExecutor.clipRecoveryJump(for: el(380, 690, 120, 60), viewport: vp,
                                                     finger: .left) ?? 0, 138, accuracy: 0.5)
        // 左へはみ出し → 指を右(−)
        XCTAssertEqual(StepExecutor.clipRecoveryJump(for: el(-40, 690, 120, 60), viewport: vp,
                                                     finger: .right) ?? 0, -80, accuracy: 0.5)
        // 下へはみ出し → 指を上(+)
        XCTAssertEqual(StepExecutor.clipRecoveryJump(for: el(16, 740, 120, 56), viewport: vp,
                                                     finger: .up) ?? 0, 70, accuracy: 0.5)
        // 完全に見えている → nil(回収不要)
        XCTAssertNil(StepExecutor.clipRecoveryJump(for: el(20, 692, 120, 56), viewport: vp,
                                                   finger: .left))
    }

    /// 横方向のドラッグ(逆走査の横対応。2026-08-08: RN 横 FlatList の飛び越し救済が動機)。
    /// jump > 0 = 指を左(縦の「+ = 上」と同じ「進む向き」規約)・y は容器の中心線
    func testDragGestureHorizontalGeometry() {
        let container = FTRect(x: 16, y: 690, width: 370, height: 60)
        // 指を左へ: 右端マージンから左へ
        let left = StepExecutor.dragGesture(jump: 200, container: container, vertical: false)
        XCTAssertNotNil(left)
        XCTAssertEqual(left!.fromY, 720)                              // y = 中心線
        XCTAssertEqual(left!.toY, 720)
        XCTAssertEqual(left!.fromX, 16 + 370 - 370 * 0.15, accuracy: 0.5)
        XCTAssertEqual(left!.fromX - left!.toX, 180, accuracy: 0.5)   // 200 * 0.9
        // 指を右へ: 左端マージンから右へ
        let right = StepExecutor.dragGesture(jump: -200, container: container, vertical: false)
        XCTAssertEqual(right!.toX - right!.fromX, 180, accuracy: 0.5)
        // 幅が細い容器は nil(縦と同じ下限規則が幅に掛かる)
        XCTAssertNil(StepExecutor.dragGesture(
            jump: 200, container: FTRect(x: 0, y: 0, width: 120, height: 800), vertical: false))
    }

    /// **容器は画面と交差させる**(scrollFrame 側と同じ規則)。交差を取らないと画面外の座標を撃つ
    func testDragGestureClipsTheContainerToTheViewport() {
        // 画面(高さ 2400)より下へはみ出した容器
        let container = FTRect(x: 0, y: 332, width: 1080, height: 3000)
        let viewport = FTRect(x: 0, y: 0, width: 1080, height: 2400)
        let clipped = StepExecutor.dragGesture(jump: 5000, container: container, viewport: viewport)
        XCTAssertNotNil(clipped)
        // 交差は y 332..2400(高さ 2068)。始点は下端マージン(15%)の内側 = 画面内
        XCTAssertLessThanOrEqual(clipped!.fromY, 2400)
        XCTAssertEqual(clipped!.fromY, 332 + 2068 - 2068 * 0.15, accuracy: 0.5)
        // viewport を渡さなければ従来どおり(既存の呼び出しを壊さない)
        let raw = StepExecutor.dragGesture(jump: 5000, container: container)
        XCTAssertGreaterThan(raw!.fromY, 2400, "交差を取らないと画面外を撃つ = これが直した対象")
    }

    /// 探索終端の静止待ちを**打ち切ったら注記にする**。黙って返すと「まだ動いている画面で
    /// 掴んだ座標」を後段がタップし、失敗が沈黙(誤った成功)として現れる
    func testScrollSearchNoteReportsAnUnsettledSearch() {
        let capped = StepExecutor.ScrollSearchResult(found: true, fallback: nil, viaXCUITest: false,
                                                     hintJumps: 0, settleCapped: true)
        XCTAssertEqual(StepExecutor.scrollSearchNote(capped),
                       "the screen did not settle after the search (poll limit)")
        // 静止できていれば無言(通常運転で注記を出さない = 出たときに意味がある)
        let settled = StepExecutor.ScrollSearchResult(found: true, fallback: nil, viaXCUITest: false,
                                                      hintJumps: 0)
        XCTAssertNil(StepExecutor.scrollSearchNote(settled))
    }

    /// 飛び越しの拾い直しは**指定すべき容器の名前まで**返す。総称のままだと、読み手は
    /// 名前を探すためにスナップショットを撮り直すことになる
    func testScrollSearchNoteNamesTheContainerToSpecify() {
        var named = StepExecutor.ScrollSearchResult(found: true, fallback: nil, viaXCUITest: false,
                                                    hintJumps: 0)
        named.reverseSweeps = 1
        named.suggestedScrollFrame = "#list_rows"
        XCTAssertEqual(StepExecutor.scrollSearchNote(named),
                       "found by sweeping back after overshooting it"
                       + " (specify scrollFrame: #list_rows to step within the container instead)")
        // 名指しできない容器(id もラベルも無い)では総称のまま = 存在しない名前を勧めない
        var unnamed = named
        unnamed.suggestedScrollFrame = nil
        XCTAssertEqual(StepExecutor.scrollSearchNote(unnamed),
                       "found by sweeping back after overshooting it"
                       + " (specify scrollFrame: to step within the container instead)")
    }

    // MARK: - 機械可読な注記(StepNote)

    // MARK: - 半開きシートの逆走査の後回し(defersPartialSheetRecovery)

    /// 半開きシート(部分高の容器)で停滞する台本。1周目だけ動かして scrolledContainer を
    /// 立て、以後は同一ツリー(最後の要素が繰り返される規約で停滞になる)
    private func partialSheetStallScript() -> [[ElementInfo]] {
        func tree(offset: Double) -> [ElementInfo] {
            // 移動後も**2つ以上の行が容器の中に残る**こと(clippingContainer の推測条件)。
            // 残りが1つだと容器が特定できず、逆走査の前段で黙って諦めてしまい台本にならない
            [ElementInfo(ref: 1, type: "scrollView", identifier: "sheet_list", label: nil,
                         value: nil, placeholder: nil, enabled: true,
                         frame: FTRect(x: 0, y: 500, width: 400, height: 250), depth: 0,
                         scrollable: true),
             framed(ref: 2, id: "row_a", x: 16, y: 520 - offset, width: 368, height: 40, depth: 1),
             framed(ref: 3, id: "row_b", x: 16, y: 590 - offset, width: 368, height: 40, depth: 1),
             framed(ref: 4, id: "row_c", x: 16, y: 660 - offset, width: 368, height: 40, depth: 1)]
        }
        return [tree(offset: 0), tree(offset: 0), tree(offset: 60)]
    }

    /// defersPartialSheetRecovery=true(MCP の1回目)は、半開きシートの停滞で
    /// **逆走査を掛けずに** sheetCollapsed で即返すこと(実測 7.8s の丸損を払わない。
    /// 救済は呼び手の「展開して再試行」側の全画面高の逆走査が引き継ぐ)
    func testPartialSheetStallSkipsReverseSweepWhenDeferred() async throws {
        let log = CallLog()
        let primary = FakeAppDriver(name: "primary", log: log,
                                    snapshotElements: partialSheetStallScript())
        let executor = StepExecutor(driver: primary, defersPartialSheetRecovery: true)
        let step = FlowStep(action: "scrollTo", locator: FlowLocator(id: "row_target"),
                            maxSwipes: 6)

        let outcome = await executor.execute(step)

        guard case .failed = outcome.status else { XCTFail("見つからないので failed のはず"); return }
        XCTAssertTrue(executor.noteCodesThisStep.contains(.sheetCollapsed),
                      "シート展開の合図は従来どおり出すこと")
        XCTAssertTrue(primary.dragCalls.isEmpty,
                      "後回し指定では逆走査のドラッグを撃たないこと: \(primary.dragCalls)")
    }

    /// 既定(DSL・MCP の再試行)は従来どおり逆走査で拾い直しに行くこと。
    /// 上のテストと対(「常に逆走査を切る」変異はこちらが落とす)
    func testPartialSheetStallStillReverseSweepsByDefault() async throws {
        let log = CallLog()
        let primary = FakeAppDriver(name: "primary", log: log,
                                    snapshotElements: partialSheetStallScript())
        let executor = StepExecutor(driver: primary)
        let step = FlowStep(action: "scrollTo", locator: FlowLocator(id: "row_target"),
                            maxSwipes: 6)

        let outcome = await executor.execute(step)

        guard case .failed = outcome.status else { XCTFail("見つからないので failed のはず"); return }
        XCTAssertFalse(primary.dragCalls.isEmpty,
                       "既定では逆走査のドラッグで拾い直しに行くこと(DSL の唯一の救済)")
    }

    /// 探索の打ち切りは文言が別(「after the search」)でも同じコードで数えること
    func testScrollSearchNoteRecordsTheSameCode() {
        let executor = StepExecutor(driver: FakeAppDriver(name: "primary", log: CallLog()))
        var capped = StepExecutor.ScrollSearchResult(found: true, fallback: nil,
                                                     viaXCUITest: false, hintJumps: 0)
        capped.settleCapped = true

        let note = executor.recordedScrollSearchNote(capped)

        XCTAssertEqual(note, "the screen did not settle after the search (poll limit)")
        XCTAssertTrue(executor.noteCodesThisStep.contains(.settleCapped),
                      "文言を出したのにコードを立てないと集計に乗らない")
    }

    /// **シート展開の判定を機械可読でも出す**(2026-08-09): MCP はこのコードで
    /// 「グラバーを引いて1度だけ再試行」へ分岐する。文言(scrollNotFoundMessage の
    /// half-open bottom sheet)と**同じ条件**であること —— 片方だけ変わると、
    /// 案内は出るのに自動展開が黙って効かなくなる
    func testSheetCollapsedCodeFollowsTheSameConditionAsTheHint() {
        let executor = StepExecutor(driver: FakeAppDriver(name: "primary", log: CallLog()))
        var stopped = StepExecutor.ScrollSearchResult(found: false, fallback: nil,
                                                      viaXCUITest: false, hintJumps: 0)
        stopped.stoppedUnmoving = true
        stopped.containerIsPartialHeight = true

        _ = executor.recordedScrollSearchNote(stopped)

        XCTAssertTrue(executor.noteCodesThisStep.contains(.sheetCollapsed))
    }

    /// 全画面リストの末尾到達では立てない(毎回シートを広げにいかせない)
    func testSheetCollapsedCodeIsNotSetForAFullHeightContainer() {
        let executor = StepExecutor(driver: FakeAppDriver(name: "primary", log: CallLog()))
        var stopped = StepExecutor.ScrollSearchResult(found: false, fallback: nil,
                                                      viaXCUITest: false, hintJumps: 0)
        stopped.stoppedUnmoving = true
        stopped.containerIsPartialHeight = false

        _ = executor.recordedScrollSearchNote(stopped)

        XCTAssertFalse(executor.noteCodesThisStep.contains(.sheetCollapsed))
    }

    /// 打ち切っていないときは何も立てないこと(上の検証を「常に立てる」実装で通さないための対)
    func testScrollSearchNoteRecordsNothingWhenSettled() {
        let executor = StepExecutor(driver: FakeAppDriver(name: "primary", log: CallLog()))
        let settled = StepExecutor.ScrollSearchResult(found: true, fallback: nil,
                                                      viaXCUITest: false, hintJumps: 0)

        XCTAssertNil(executor.recordedScrollSearchNote(settled))
        XCTAssertTrue(executor.noteCodesThisStep.isEmpty)
    }

    /// 動き続ける画面で打ち切ったとき、注記の文言とコードが**両方**出ること
    /// (片方だけだと「レポートには出ているのに集計に乗らない」が起きる)
    func testSettleCapIsReportedAsBothTextAndCode() async throws {
        let log = CallLog()
        let moving = (0..<200).map { movingRow(y: Double($0) * 10) }
        let primary = FakeAppDriver(name: "primary", log: log, snapshotElements: moving)
        let executor = StepExecutor(driver: primary)

        let outcome = await executor.execute(
            FlowStep(action: "scrollToEdge", direction: "up", maxSwipes: 3))

        XCTAssertTrue(outcome.driverFallback?.contains(StepNote.settleCapped.text) == true,
                      "表示: \(outcome.driverFallback ?? "-")")
        XCTAssertEqual(outcome.notes, [.settleCapped])
    }

    /// 注記は**ステップごとに捨てる**こと(前ステップの打ち切りを次ステップへ持ち越さない)
    func testNotesAreResetBetweenSteps() async throws {
        let log = CallLog()
        let moving = (0..<200).map { movingRow(y: Double($0) * 10) }
        let primary = FakeAppDriver(name: "primary", log: log, snapshotElements: moving)
        let executor = StepExecutor(driver: primary)
        let capped = await executor.execute(
            FlowStep(action: "scrollToEdge", direction: "up", maxSwipes: 3))
        XCTAssertEqual(capped.notes, [.settleCapped], "前提: 1本目は打ち切られていること")

        // 以降は同じフレームを返し続ける(尽きたら最後を繰り返す規約)= 静止した画面
        primary.snapshotElements = [movingRow(y: 100)]

        let settled = await executor.execute(
            FlowStep(action: "scrollToEdge", direction: "up", maxSwipes: 3))

        XCTAssertEqual(settled.notes, [], "静止した画面のステップに前ステップの注記が残っている")
    }

    /// 「なぜ撮り直すか」→「実際に迂回するか」の対応。**ソース走査の guard では届かない**
    /// (方針が1箇所に寄ったので、call site の字面を見ても分からない)。
    /// とくに `.afterSearch(swiped: false)` が false になることが要 —— ここが true に倒れると
    /// 探索が1度もスワイプしていない場合まで毎回撮り直し、計測済みの所要が静かに増える
    func testBypassPolicyTruthTable() {
        let driver = FakeAppDriver(name: "primary", log: CallLog())
        let executor = StepExecutor(driver: driver)

        driver.bypassSupported = true
        XCTAssertTrue(executor.bypassesCache(.afterOwnMove))
        XCTAssertTrue(executor.bypassesCache(.afterSearch(swiped: true)))
        XCTAssertFalse(executor.bypassesCache(.afterSearch(swiped: false)),
                       "探索がスワイプしていないなら木は古くならない(撮り直しは無駄)")

        // 対応していないドライバでは理由によらず迂回しない(フラグを送っても意味が無い)
        driver.bypassSupported = false
        XCTAssertFalse(executor.bypassesCache(.afterOwnMove))
        XCTAssertFalse(executor.bypassesCache(.afterSearch(swiped: true)))
    }

    /// 理由が実際に driver まで届くこと(helper が握り潰していないこと)
    func testFreshSnapshotForwardsTheDecisionToTheDriver() async throws {
        let driver = FakeAppDriver(name: "primary", log: CallLog())
        driver.bypassSupported = true
        let executor = StepExecutor(driver: driver)

        _ = try await executor.freshSnapshot(.afterSearch(swiped: false))
        XCTAssertEqual(driver.bypassedSnapshotCount, 0)

        _ = try await executor.freshSnapshot(.afterOwnMove)
        XCTAssertEqual(driver.bypassedSnapshotCount, 1)
    }

    private func movingRow(y: Double) -> [ElementInfo] {
        [ElementInfo(ref: 1, type: "cell", identifier: "row_01", label: "行 01", value: nil,
                     placeholder: nil, enabled: true,
                     frame: FTRect(x: 16, y: y, width: 370, height: 56), depth: 0)]
    }

    // MARK: - 失敗の素性(結果 JSON の failureKind)

    /// 解決できないロケータは `not-found`。**「画面が違う」と「セレクタが古い」は区別しない**
    /// (どちらもこの経路。事実だけを言う)
    func testUnresolvableLocatorIsMarkedNotFound() async throws {
        let primary = FakeAppDriver(name: "primary", log: CallLog(),
                                    snapshotElements: [[element(ref: 1, id: "other")]])
        let executor = StepExecutor(driver: primary)
        let step = FlowStep(action: "tap", locator: FlowLocator(id: "missing"), timeout: 1)

        let outcome = await executor.execute(step)

        XCTAssertEqual(outcome.failureKind, .notFound)
    }

    /// 掴めたが期待値と違うのは `assertion`(見つからない・到達できないと分けられること)
    func testValueMismatchIsMarkedAssertion() async throws {
        let primary = FakeAppDriver(name: "primary", log: CallLog(),
                                    snapshotElements: [[textElement(id: "msg", label: "こんにちは")]])
        let executor = StepExecutor(driver: primary)
        var step = FlowStep(assert: "textEquals", locator: FlowLocator(id: "msg"), timeout: 1)
        step.expected = "さようなら"

        let outcome = await executor.execute(step)

        XCTAssertEqual(outcome.failureKind, .assertion)
    }

    /// 同じ assert でも**要素が居ない**なら not-found(assertion で塗り潰さない)
    func testMissingElementInAnAssertIsStillNotFound() async throws {
        let primary = FakeAppDriver(name: "primary", log: CallLog(), snapshotElements: [[]])
        let executor = StepExecutor(driver: primary)
        var step = FlowStep(assert: "textEquals", locator: FlowLocator(id: "msg"), timeout: 1)
        step.expected = "なんでも"

        let outcome = await executor.execute(step)

        XCTAssertEqual(outcome.failureKind, .notFound)
    }

    /// ブリッジへ到達できない失敗は `driver-unreachable`(ステップの内容と独立に起きる形)
    func testUnreachableDriverIsMarkedDriverUnreachable() async throws {
        let primary = FakeAppDriver(name: "primary", log: CallLog(),
                                    snapshotElements: [[element(ref: 1, id: "btn")]])
        primary.swipeError = DriverError.bridgeUnreachable("connection reset")
        let executor = StepExecutor(driver: primary)
        let step = FlowStep(action: "swipe", direction: "up")

        let outcome = await executor.execute(step)

        XCTAssertEqual(outcome.failureKind, .driverUnreachable)
    }

    /// 成功したステップに素性は付かない(「失敗の内訳」に成功が混ざらない)
    func testSuccessfulStepsCarryNoFailureKind() async throws {
        let primary = FakeAppDriver(name: "primary", log: CallLog(),
                                    snapshotElements: [[element(ref: 1, id: "btn")]])
        let executor = StepExecutor(driver: primary)
        let step = FlowStep(action: "tap", locator: FlowLocator(id: "btn"), timeout: 1)

        let outcome = await executor.execute(step)

        XCTAssertNil(outcome.failureKind)
    }

}
