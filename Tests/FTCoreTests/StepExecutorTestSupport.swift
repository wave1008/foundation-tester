import XCTest
import CoreGraphics
import ImageIO
import UniformTypeIdentifiers
@testable import FTCore

// StepExecutorTests 用の共有テストダブル(CallLog / FakeAppDriver / 各種 ReplayDelegate)


/// primary/fallback 2 台の FakeAppDriver 間で呼び出し順序を検証するための共有ログ
/// (StepExecutor は 1 タスク内で順に await するだけなので単純な配列で十分)
final class CallLog {
    var entries: [String] = []
}

/// snapshot() はスクリプト可能(呼び出し回数ごとの要素列。列を使い切ったら最後の要素を繰り返す)。
/// tap/type/press 等その他のメソッドは記録するだけで何もしない
final class FakeAppDriver: AppDriver {
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
    /// SnapshotResponse.overlayWindowFrames(木に出ないオーバーレイ・ウィンドウの申告。
    /// keyboardFrame と同じく全 snapshot() 呼び出しに一律で乗せる)
    var overlayWindowFrames: [FTRect]?

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
                                keyboardFrame: keyboardFrame,
                                overlayWindowFrames: overlayWindowFrames)
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
    /// tap(ref:) が呼ばれた後に実行するフック。**アラートのボタンを押した結果として
    /// アプリの状態が変わる**因果を模す(このフックが無いと fake は snapshot ごとに
    /// フレームを進めるので、覆いの下でも値が勝手に更新され Fix B を検証できない)
    var afterTap: (() -> Void)?

    func tap(ref: Int) async throws {
        log.entries.append("\(name).tap(ref:\(ref))")
        afterTap?()
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
final class FakeVisibilityDelegate: ReplayDelegate {
    /// テスト中に切り替えられる(門が可視の判定で消費されることを見るテストが使う)
    var visible: Bool
    private(set) var visibleCalls = 0
    init(visible: Bool) { self.visible = visible }
    func healLocator(step: FlowStep, snapshot: SnapshotResponse) async -> HealAttempt? { nil }
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

/// FM が判定を返せない(実呼び出しの失敗・ブレーカ開・直列化待ちの期限切れ)ときの delegate。
/// `verifyElementVisible` は nil を返す = 実装(ReplayAssist)が FM 失敗時に返す形そのもの
final class NoVerdictVisibilityDelegate: ReplayDelegate {
    private(set) var visibleCalls = 0
    func healLocator(step: FlowStep, snapshot: SnapshotResponse) async -> HealAttempt? { nil }
    func verifyScreen(expected: String, screenshotPNG: Data) async -> (pass: Bool, reason: String)? { nil }
    func triage(goal: String?, stepDescription: String, failureReason: String,
                snapshot: SnapshotResponse?, screenshotPNG: Data?) async -> TriageInfo? { nil }
    func verifyElementVisible(expectedText: String, frame: FTRect, screen: FTRect,
                              screenshotPNG: Data) async
        -> (visible: Bool, state: String, reason: String, observedText: String)? {
        visibleCalls += 1
        return nil
    }
}

/// verifyElementVisible が呼び出しごとに指定の visible 列を返す(尽きたら最後を繰り返す)。
/// 過渡的オーバーレイ(covered→visible)の poll-until-visible 検証用。
final class SequenceVisibilityDelegate: ReplayDelegate {
    private let results: [Bool]
    private(set) var calls = 0
    init(_ results: [Bool]) { self.results = results }
    func healLocator(step: FlowStep, snapshot: SnapshotResponse) async -> HealAttempt? { nil }
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
final class ScriptedScreenDelegate: ReplayDelegate {
    private(set) var verifyScreenCalls = 0
    private let verdicts: [Bool]
    init(_ verdicts: [Bool]) { self.verdicts = verdicts }
    func healLocator(step: FlowStep, snapshot: SnapshotResponse) async -> HealAttempt? { nil }
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
final class CountingScreenDelegate: ReplayDelegate {
    private(set) var verifyScreenCalls = 0
    func healLocator(step: FlowStep, snapshot: SnapshotResponse) async -> HealAttempt? { nil }
    func verifyScreen(expected: String, screenshotPNG: Data) async -> (pass: Bool, reason: String)? {
        verifyScreenCalls += 1
        return (true, "ok")
    }
    func triage(goal: String?, stepDescription: String, failureReason: String,
                snapshot: SnapshotResponse?, screenshotPNG: Data?) async -> TriageInfo? { nil }
}

