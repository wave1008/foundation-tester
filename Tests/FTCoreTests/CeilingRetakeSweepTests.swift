// レビューで見つかった掃討漏れの回帰: exists/tap は「解決できず truncatedCount > 0 なら
// 天井で撮り直す」を持つが、textIs/textIsNot/enabled/checked の4経路は持っておらず、
// 切り詰められた木のまま解決して**実在する要素で赤くなる**(flake)。
// スタブドライバの流儀は SnapshotTruncationTests.swift の TruncatingDriver を踏襲する。

import XCTest
@testable import FTCore

/// 天井で撮り直すと解決できるようになる木を返すスタブ。
/// **既定の1枚には対象が無く**(切り詰め)、`raiseElementLimitOnNextSnapshot` 後の1枚だけに現れる。
/// `target: nil` を渡すと天井まで上げても現れない(= まだ切り詰められている)ケースを模す。
private final class CeilingRetakeStubDriver: AppDriver {
    private(set) var reads = 0
    private var ceilingRequested = false
    private let screen = FTRect(x: 0, y: 0, width: 400, height: 800)
    private let target: ElementInfo?

    init(target: ElementInfo?) {
        self.target = target
    }

    func raiseElementLimitOnNextSnapshot(_ max: Int?) {
        ceilingRequested = (max ?? 0) >= BridgeAPI.maxSnapshotElementsCeiling
    }

    private func filler(_ count: Int) -> [ElementInfo] {
        (0..<count).map { index in
            ElementInfo(ref: index + 1, type: "staticText", identifier: "filler\(index)",
                        label: nil, value: nil, placeholder: nil, enabled: true,
                        frame: FTRect(x: 0, y: Double(index), width: 10, height: 10), depth: 1)
        }
    }

    func snapshot() async throws -> SnapshotResponse {
        reads += 1
        guard ceilingRequested else {
            return SnapshotResponse(sessionBundleID: nil, screen: screen, elements: filler(3),
                                    truncatedCount: 40)
        }
        guard let target else {
            // 天井まで上げても対象が無い = narrowTheScreen 側(まだ切り詰められている)
            return SnapshotResponse(sessionBundleID: nil, screen: screen,
                                    elements: filler(BridgeAPI.maxSnapshotElementsCeiling),
                                    truncatedCount: 5)
        }
        return SnapshotResponse(sessionBundleID: nil, screen: screen,
                                elements: filler(3) + [target], truncatedCount: 0)
    }

    func snapshot(bypassingCache: Bool) async throws -> SnapshotResponse { try await snapshot() }
    func status() async throws -> StatusResponse {
        StatusResponse(ready: true, device: "fake", osVersion: "-", sessionBundleID: nil)
    }
    func install(packagePath: String) async throws {}
    func uninstall(bundleID: String) async throws {}
    func launch(bundleID: String) async throws {}
    func isAppForeground(bundleID: String) async throws -> Bool { true }
    func foregroundAppID() async throws -> String? { nil }
    func tap(ref: Int) async throws {}
    func tap(x: Double, y: Double) async throws {}
    func type(ref: Int?, text: String) async throws {}
    func press(ref: Int, duration: Double) async throws {}
    func swipe(_ direction: FTSwipeDirection) async throws {}
    func screenshot() async throws -> Data { Data() }
    func terminate() async throws {}
}

/// 既定の1枚が最初から天井の大きさ(予算400)で、それでも切り詰められている木を返すスタブ
/// (プロファイルが上限を天井に設定した run など)。撮り直しても同じ木しか返らない形
private final class AlreadyAtCeilingStubDriver: AppDriver {
    private(set) var reads = 0
    private let screen = FTRect(x: 0, y: 0, width: 400, height: 800)

    func raiseElementLimitOnNextSnapshot(_ max: Int?) {}

    func snapshot() async throws -> SnapshotResponse {
        reads += 1
        let elements = (0..<BridgeAPI.maxSnapshotElementsCeiling).map { index in
            ElementInfo(ref: index + 1, type: "staticText", identifier: "filler\(index)",
                        label: nil, value: nil, placeholder: nil, enabled: true,
                        frame: FTRect(x: 0, y: Double(index), width: 10, height: 10), depth: 1)
        }
        return SnapshotResponse(sessionBundleID: nil, screen: screen, elements: elements,
                                truncatedCount: 5)
    }

    func snapshot(bypassingCache: Bool) async throws -> SnapshotResponse { try await snapshot() }
    func status() async throws -> StatusResponse {
        StatusResponse(ready: true, device: "fake", osVersion: "-", sessionBundleID: nil)
    }
    func install(packagePath: String) async throws {}
    func uninstall(bundleID: String) async throws {}
    func launch(bundleID: String) async throws {}
    func isAppForeground(bundleID: String) async throws -> Bool { true }
    func foregroundAppID() async throws -> String? { nil }
    func tap(ref: Int) async throws {}
    func tap(x: Double, y: Double) async throws {}
    func type(ref: Int?, text: String) async throws {}
    func press(ref: Int, duration: Double) async throws {}
    func swipe(_ direction: FTSwipeDirection) async throws {}
    func screenshot() async throws -> Data { Data() }
    func terminate() async throws {}
}

final class CeilingRetakeSweepTests: XCTestCase {

    private func textElement(label: String) -> ElementInfo {
        ElementInfo(ref: 99, type: "staticText", identifier: "msg", label: label,
                   value: nil, placeholder: nil, enabled: true,
                   frame: FTRect(x: 10, y: 200, width: 100, height: 40), depth: 1)
    }

    /// 塞ぐ穴: textIs が切り詰められた木のまま解決し、実在する要素を「見つからない」で落としていた
    func testTextIsRetakesAtTheCeilingBeforeFailing() async {
        let driver = CeilingRetakeStubDriver(target: textElement(label: "Hello"))
        let step = FlowStep(assert: "textEquals", locator: FlowLocator(id: "msg"),
                            expected: "Hello", timeout: 0, occlusionGuard: false)
        let outcome = await StepExecutor(driver: driver, isAndroid: false).execute(step)
        XCTAssertTrue(StepExecutor.isSuccess(outcome.status),
                      "切り詰めで落ちていた実在要素を「見つからない」と報告した: \(outcome.status)")
        XCTAssertGreaterThanOrEqual(driver.reads, 2, "天井で撮り直していない")
    }

    /// 塞ぐ穴: 負の比較(textIsNot 等)も肯定側と同じ穴を持つ(要素は在ることが前提の経路)
    func testTextIsNotRetakesAtTheCeilingBeforeFailing() async {
        let driver = CeilingRetakeStubDriver(target: textElement(label: "Hello"))
        let step = FlowStep(assert: "textNotEquals", locator: FlowLocator(id: "msg"),
                            expected: "World", timeout: 0, occlusionGuard: false)
        let outcome = await StepExecutor(driver: driver, isAndroid: false).execute(step)
        XCTAssertTrue(StepExecutor.isSuccess(outcome.status),
                      "負の比較でも切り詰めで落ちていた実在要素を掴めなかった: \(outcome.status)")
        XCTAssertGreaterThanOrEqual(driver.reads, 2, "天井で撮り直していない")
    }

    /// 塞ぐ穴: enabled/disabled も同型
    func testEnabledRetakesAtTheCeilingBeforeFailing() async {
        let target = ElementInfo(ref: 99, type: "button", identifier: "submit", label: "送信",
                                 value: nil, placeholder: nil, enabled: true,
                                 frame: FTRect(x: 10, y: 200, width: 100, height: 40), depth: 1)
        let driver = CeilingRetakeStubDriver(target: target)
        let step = FlowStep(assert: "enabled", locator: FlowLocator(id: "submit"),
                            timeout: 0, occlusionGuard: false)
        let outcome = await StepExecutor(driver: driver, isAndroid: false).execute(step)
        XCTAssertTrue(StepExecutor.isSuccess(outcome.status),
                      "enabled が切り詰めで落ちていた実在要素を「見つからない」と報告した: \(outcome.status)")
        XCTAssertGreaterThanOrEqual(driver.reads, 2, "天井で撮り直していない")
    }

    /// 塞ぐ穴: checked/notChecked も同型
    func testCheckedRetakesAtTheCeilingBeforeFailing() async {
        let target = ElementInfo(ref: 99, type: "checkbox", identifier: "agree", label: "同意する",
                                 value: nil, placeholder: nil, enabled: true,
                                 frame: FTRect(x: 10, y: 200, width: 100, height: 40), depth: 1,
                                 checked: true)
        let driver = CeilingRetakeStubDriver(target: target)
        let step = FlowStep(assert: "checked", locator: FlowLocator(id: "agree"),
                            timeout: 0, occlusionGuard: false)
        let outcome = await StepExecutor(driver: driver, isAndroid: false).execute(step)
        XCTAssertTrue(StepExecutor.isSuccess(outcome.status),
                      "checked が切り詰めで落ちていた実在要素を「見つからない」と報告した: \(outcome.status)")
        XCTAssertGreaterThanOrEqual(driver.reads, 2, "天井で撮り直していない")
    }

    /// 塞ぐ穴: 天井まで上げても解決できないときの失敗文言が、切り詰めが原因であることを黙っていた
    func testTextIsFailureMessageExplainsTruncationEvenAtCeiling() async {
        let driver = CeilingRetakeStubDriver(target: nil)
        let step = FlowStep(assert: "textEquals", locator: FlowLocator(id: "msg"),
                            expected: "Hello", timeout: 0, occlusionGuard: false)
        let outcome = await StepExecutor(driver: driver, isAndroid: false).execute(step)
        guard case .failed(let message) = outcome.status else {
            XCTFail("expected a failure, got \(outcome.status)")
            return
        }
        XCTAssertTrue(message.contains("truncated"),
                      "切り詰めが原因でも黙って「見つからない」とだけ言っている: \(message)")
    }

    /// 塞ぐ穴: 既に天井で読まれた木への撮り直しは同じ木が返るだけの1枚 —— 撮らずに済ませる
    /// (retakenAtElementLimitCeiling の isAtCeiling ガード)
    func testRetakeIsSkippedWhenTheTreeIsAlreadyAtTheCeiling() async {
        let driver = AlreadyAtCeilingStubDriver()
        let step = FlowStep(assert: "exists", locator: FlowLocator(id: "missing"),
                            timeout: 0, occlusionGuard: false)
        _ = await StepExecutor(driver: driver, isAndroid: false).execute(step)
        XCTAssertEqual(driver.reads, 1,
                       "天井の木への撮り直しが走った(同じ木が返るだけのデバイス I/O)")
    }

    /// 塞ぐ穴: undecidableTruncationMessage が truncationHint の撤回済みの助言
    /// (`.webView >>` で絞る / 対象へスクロールする)をまだ勧めていた
    func testUndecidableTruncationMessageDoesNotRepeatTheWithdrawnAdvice() {
        let step = FlowStep(assert: "notExists", locator: FlowLocator(id: "msg"))
        let message = StepExecutor.undecidableTruncationMessage(
            "absence", step: step, evidence: "the tree hit the element limit")
        XCTAssertFalse(message.contains("scroll closer"), message)
        XCTAssertFalse(message.contains(".webView >>"), message)
    }
}
