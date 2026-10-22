// 古い ref を撃たずに断る判定(StaleRefGuard)と、断りのワイヤ形式・ホスト側の引き直しを固定する。
// 実例: 検索バーを押して全画面の検索に切り替わった後、切り替わる前の欄の ref の座標を撃って、
// 同じ座標に来ていた候補の行を押した(E2EX-Flutter)。

import XCTest
@testable import FTCore

private func element(ref: Int = 1, type: String = "textField", id: String? = "field_search",
                     label: String? = nil, frame: FTRect = FTRect(x: 16, y: 162, width: 370, height: 56))
    -> ElementInfo {
    ElementInfo(ref: ref, type: type, identifier: id, label: label, value: nil, placeholder: nil,
                enabled: true, frame: frame, depth: 1)
}

final class StaleRefGuardTests: XCTestCase {

    // MARK: A: 控えた要素がまだ同じ枠に居るか

    func testPresentWhenSameIdentifierAndFrame() {
        XCTAssertTrue(StaleRefGuard.isStillPresent(element(), in: [element(ref: 9)]))
    }

    func testPresentWithinOnePointTolerance() {
        let near = element(ref: 9, frame: FTRect(x: 16.9, y: 162.9, width: 370.9, height: 56.9))
        XCTAssertTrue(StaleRefGuard.isStillPresent(element(), in: [near]))
    }

    func testMovedElementIsNotPresent() {
        let moved = element(ref: 9, frame: FTRect(x: 16, y: 65, width: 370, height: 72))
        XCTAssertFalse(StaleRefGuard.isStillPresent(element(), in: [moved]))
    }

    func testGoneElementIsNotPresent() {
        let other = element(ref: 9, type: "button", id: "suggestion_apple")
        XCTAssertFalse(StaleRefGuard.isStillPresent(element(), in: [other]))
        XCTAssertFalse(StaleRefGuard.isStillPresent(element(), in: []))
    }

    func testSameFrameButDifferentIdentifierIsNotPresent() {
        XCTAssertFalse(StaleRefGuard.isStillPresent(element(), in: [element(ref: 9, id: "suggestion_apple")]))
    }

    func testWithoutIdentifierMatchesByTypeAndLabel() {
        let stored = element(id: nil, label: "Search")
        XCTAssertTrue(StaleRefGuard.isStillPresent(stored, in: [element(ref: 9, id: nil, label: "Search")]))
        XCTAssertFalse(StaleRefGuard.isStillPresent(stored, in: [element(ref: 9, id: nil, label: "Other")]))
        XCTAssertFalse(StaleRefGuard.isStillPresent(stored, in: [element(ref: 9, type: "button", id: nil, label: "Search")]))
    }

    // MARK: B: ホストの期待との矛盾

    func testNoExpectationNeverContradicts() {
        XCTAssertFalse(StaleRefGuard.contradicts(nil, stored: element()))
    }

    func testMatchingExpectationDoesNotContradict() {
        XCTAssertFalse(StaleRefGuard.contradicts(RefExpectation(element()), stored: element()))
    }

    func testIdentifierMismatchContradicts() {
        let expect = RefExpectation(identifier: "field_search", type: "textField")
        XCTAssertTrue(StaleRefGuard.contradicts(expect, stored: element(id: "suggestion_apple")))
    }

    func testTypeMismatchContradicts() {
        let expect = RefExpectation(identifier: "field_search", type: "button")
        XCTAssertTrue(StaleRefGuard.contradicts(expect, stored: element()))
    }

    func testMissingIdentifierOnEitherSideIsAllowed() {
        XCTAssertFalse(StaleRefGuard.contradicts(RefExpectation(identifier: nil, type: "textField"), stored: element()))
        XCTAssertFalse(StaleRefGuard.contradicts(RefExpectation(identifier: "field_search", type: "textField"),
                                                 stored: element(id: nil)))
    }

    // MARK: ワイヤ

    func testExpectationRidesOnRefRequestsAndIsOptional() throws {
        let encoded = try JSONEncoder().encode(TapRequest(ref: 3, expect: RefExpectation(identifier: "a", type: "button")))
        let decoded = try JSONDecoder().decode(TapRequest.self, from: encoded)
        XCTAssertEqual(decoded.expect, RefExpectation(identifier: "a", type: "button"))
        let bare = try JSONDecoder().decode(TypeRequest.self, from: Data(#"{"ref":3,"text":"x"}"#.utf8))
        XCTAssertNil(bare.expect)
    }

    func testErrorReasonRoundTripsAndIsOmittedWhenAbsent() throws {
        let stale = try JSONEncoder().encode(ErrorResponse(error: "x", reason: BridgeAPI.staleRefReason))
        XCTAssertEqual(try JSONDecoder().decode(ErrorResponse.self, from: stale).reason, BridgeAPI.staleRefReason)
        let plain = try JSONEncoder().encode(ErrorResponse(error: "x"))
        XCTAssertFalse(String(decoding: plain, as: UTF8.self).contains("reason"))
    }
}

/// 断りを受けたときの引き直し。撃たずに断られたものだけ撃ち直し、他の 422 は撃ち直さない
private final class RefusingDriver: AppDriver {
    private(set) var tapAttempts = 0
    private(set) var snapshots = 0
    let refusal: Error?
    /// 最初の何回を断るか
    let refusals: Int

    init(refusal: Error?, refusals: Int = 1) {
        self.refusal = refusal
        self.refusals = refusals
    }

    func status() async throws -> StatusResponse {
        StatusResponse(ready: true, device: "fake", osVersion: "-", sessionBundleID: nil)
    }
    func install(packagePath: String) async throws -> String? { nil }
    func uninstall(bundleID: String) async throws {}
    func launch(bundleID: String) async throws {}
    func isAppForeground(bundleID: String) async throws -> Bool { true }
    func foregroundAppID() async throws -> String? { nil }
    func terminate() async throws {}
    func screenshot() async throws -> Data { Data() }
    func type(ref: Int?, text: String) async throws {}
    func tap(ref: Int) async throws {
        tapAttempts += 1
        if tapAttempts <= refusals, let refusal { throw refusal }
    }
    func tap(x: Double, y: Double) async throws {}
    func press(ref: Int, duration: Double) async throws {}
    func swipe(_ direction: FTSwipeDirection) async throws {}
    func snapshot() async throws -> SnapshotResponse {
        snapshots += 1
        return SnapshotResponse(
            sessionBundleID: nil, screen: FTRect(x: 0, y: 0, width: 402, height: 874),
            elements: [ElementInfo(ref: snapshots, type: "button", identifier: "go", label: "Go", value: nil,
                                   placeholder: nil, enabled: true,
                                   frame: FTRect(x: 16, y: 300, width: 200, height: 44), depth: 1)],
            truncatedCount: 0)
    }
}

final class StaleRefRetryTests: XCTestCase {

    private func run(_ driver: RefusingDriver, timeout: Double = 5) async -> StepOutcome {
        let step = FlowStep(action: "tap", locator: FlowLocator(id: "go"), timeout: timeout)
        return await StepExecutor(driver: driver, isAndroid: false, tunables: RunTunables()).execute(step)
    }

    /// 撃たずに断られたら、木を撮り直して引き直し、撃ち直す
    func testStaleRefRefusalReResolvesAndRetries() async {
        let driver = RefusingDriver(refusal: DriverError.staleRef(detail: "moved"))
        let outcome = await run(driver)
        XCTAssertEqual(driver.tapAttempts, 2, "断られたのに撃ち直していない")
        XCTAssertTrue(StepExecutor.isSuccess(outcome.status), "引き直した2回目で成功するはず: \(outcome.status)")
    }

    /// 予算が尽きるまで断られ続けたら失敗にする(無限に撃ち直さない)
    func testStaleRefRefusalStopsWhenBudgetRunsOut() async {
        let driver = RefusingDriver(refusal: DriverError.staleRef(detail: "moved"), refusals: .max)
        let outcome = await run(driver, timeout: 0.5)
        XCTAssertFalse(StepExecutor.isSuccess(outcome.status))
        XCTAssertGreaterThan(driver.tapAttempts, 1)
    }

    /// 他の 422 は撃っていないことの保証が無いので撃ち直さない
    func testOtherBadResponsesAreNotRetried() async {
        let driver = RefusingDriver(refusal: DriverError.badResponse(status: 422, body: "did not end up holding"))
        let outcome = await run(driver)
        XCTAssertEqual(driver.tapAttempts, 1, "届いたかもしれない失敗を撃ち直している")
        XCTAssertFalse(StepExecutor.isSuccess(outcome.status))
    }

    /// 引き直した事実は注記で残る(緑の run でこの経路が働いた回を数える唯一の印)
    func testRetriedNoteIsRecordedWhenRefused() async {
        let outcome = await run(RefusingDriver(refusal: DriverError.staleRef(detail: "moved")))
        XCTAssertTrue(StepExecutor.isSuccess(outcome.status), "\(outcome.status)")
        XCTAssertTrue(outcome.notes.contains(.staleRefRetried), "引き直した事実が記録に残らない: \(outcome.notes)")
    }

    /// 注記は断られた回だけ(1回目で通ったステップ・他の 422 で落ちたステップには立てない)
    func testRetriedNoteOnlyOnStepsThatWereRefused() async {
        let clean = await run(RefusingDriver(refusal: nil, refusals: 0))
        XCTAssertTrue(StepExecutor.isSuccess(clean.status), "\(clean.status)")
        XCTAssertFalse(clean.notes.contains(.staleRefRetried), "断られていないのに注記が立っている")
        let other = await run(RefusingDriver(refusal: DriverError.badResponse(status: 422, body: "x")))
        XCTAssertFalse(other.notes.contains(.staleRefRetried), "引き直していないのに注記が立っている")
    }

    func testOnlyStaleRefIsRetryable() {
        XCTAssertTrue(StepExecutor.isRetryableStaleRef(DriverError.staleRef(detail: "")))
        XCTAssertFalse(StepExecutor.isRetryableStaleRef(DriverError.badResponse(status: 422, body: "stale-ref")))
        XCTAssertFalse(StepExecutor.isRetryableStaleRef(DriverError.badResponse(status: 409, body: "")))
    }
}

/// ランナー(Runner/ は SPM ターゲットではなく単体テストできない)の配線をソース走査で固定する。
/// 判定そのものは StaleRefGuardTests が通す
final class StaleRefRunnerWiringTests: XCTestCase {

    private func runnerSource(_ name: String) throws -> String {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let source = try String(contentsOf: root.appendingPathComponent("Runner/FleetestRunnerUITests/\(name)"),
                                encoding: .utf8)
        XCTAssertFalse(source.isEmpty, "\(name) が読めていない")
        return source
    }

    /// 関数本体(宣言の行から次の `\n    }\n` まで)
    private func body(of signature: String, in source: String) throws -> String {
        let start = try XCTUnwrap(source.range(of: signature), "\(signature) が見つからない")
        let rest = source[start.lowerBound...]
        let end = rest.range(of: "\n    }\n")?.upperBound ?? rest.endIndex
        return String(rest[..<end])
    }

    /// 断りは 422 + 構造化された理由。409 は requireApp() 専用
    func testRefusalIsA422WithTheStructuredReason() throws {
        let router = try runnerSource("BridgeRouter.swift")
        let refuse = try body(of: "func refuseStaleRef(", in: router)
        XCTAssertTrue(refuse.contains("BridgeError(422,"))
        XCTAssertTrue(refuse.contains("reason: BridgeAPI.staleRefReason"))
        XCTAssertTrue(router.contains("reason: error.reason"), "BridgeError の理由が応答に載っていない")
    }

    /// /type と /clear は、打つ前のタップの**前に**木を撮り直して確かめる
    func testTypeAndClearCheckFreshTreeBeforeTapping() throws {
        let input = try runnerSource("BridgeRouter+TextInput.swift")
        for signature in ["private func typeAndReadBack(", "private func clearFocusedInput("] {
            let function = try body(of: signature, in: input)
            let guardAt = try XCTUnwrap(function.range(of: "requireRefStillOnScreen(")?.lowerBound,
                                        "\(signature) が撃つ前に確かめていない")
            let tapAt = try XCTUnwrap(function.range(of: "tapBeforeTyping(")?.lowerBound)
            XCTAssertLessThan(guardAt, tapAt, "\(signature): 確かめる前にタップしている")
            XCTAssertTrue(function.contains("requireExpectedRef("), "\(signature): ホストの期待を見ていない")
        }
    }

    /// 測定用のプローブ: /tap は probeStaleRef のときだけ、整定の待ちの後・撃つ前に確かめ、**断らず**全部の返し口で結果を返す
    func testTapProbeChecksBeforeFiringWithoutRefusing() throws {
        let router = try runnerSource("BridgeRouter.swift")
        let tap = try body(of: "private func handleTap(", in: router)
        let probeAt = try XCTUnwrap(tap.range(of: "req.probeStaleRef == true ? movedBeforeFire(")?.lowerBound,
                                    "handleTap がプローブを見ていない")
        let waitAt = try XCTUnwrap(tap.range(of: "QuiescenceWait.waitBeforeTouch(")?.lowerBound)
        XCTAssertLessThan(waitAt, probeAt, "整定の待ちの前に確かめている(撃つ瞬間から遠い)")
        for fire in ["CoordinatePinch.tap(at:", "CoordinatePinch.tapOnMainScreen(", "coordinate(app, point).tap()"] {
            let fireAt = try XCTUnwrap(tap.range(of: fire)?.lowerBound, fire)
            XCTAssertLessThan(probeAt, fireAt, "\(fire) の後に確かめている")
        }
        XCTAssertEqual(tap.components(separatedBy: "hitAreaMiss: moved").count - 1, 3, "返し口のどれかが結果を落としている")
        let probe = try body(of: "func movedBeforeFire(", in: router)
        XCTAssertTrue(probe.contains("StaleRefGuard.isStillPresent("))
        XCTAssertFalse(probe.contains("throw"), "プローブが断っている(測定は挙動を変えない)")
    }

    /// ref 無しの /type も、末尾の改行の有無に関わらず焦点の欄を読み返す(XCUITest はホストが読み返さない =
    /// ここで確かめないと打鍵が失われても緑。RN の検索欄で 240 回中 23 回)。改行は読み返しの後に送る
    func testRefLessTypeReadsBackWithoutATrailingNewline() throws {
        let input = try runnerSource("BridgeRouter+TextInput.swift")
        let function = try body(of: "private func typeAndReadBack(", in: input)
        let focusMatch = try XCTUnwrap(function.range(of: "matchFocusedElement(focusAfter")?.lowerBound,
                                       "ref 無しの経路が焦点の欄を特定していない")
        let branchStart = try XCTUnwrap(function[..<focusMatch].range(of: "if ", options: .backwards)?.lowerBound)
        let condition = function[branchStart..<focusMatch]
        XCTAssertFalse(condition.contains("hasTrailingNewline"), "読み返しが末尾の改行のある形に限られている: \(condition)")
        let readback = try XCTUnwrap(function[focusMatch...].range(of: "performTypeReadback(")?.lowerBound)
        let newline = try XCTUnwrap(function[readback...].range(of: "app.typeText(\"\\n\")")?.lowerBound,
                                    "読み返しの後に改行を送っていない")
        XCTAssertLessThan(readback, newline)
    }

    /// 撮り直した木で ref の表を置き換えない(番号がずれて別の要素に撃つ)
    func testFreshCaptureDoesNotReplaceTheRefTables() throws {
        let router = try runnerSource("BridgeRouter.swift")
        let check = try body(of: "func requireRefStillOnScreen(", in: router)
        XCTAssertTrue(check.contains("captureOnce("))
        XCTAssertFalse(check.contains("refFrames =") || check.contains("refElements =")
                       || check.contains("refIdentity ="), "確認の撮り直しが ref の表を置き換えている")
    }

    /// tap / doubleTap / press は ref の点解決にホストの期待を渡す
    func testRefFiringHandlersPassTheExpectation() throws {
        let router = try runnerSource("BridgeRouter.swift")
        let resolve = try body(of: "func resolvePoint(", in: router)
        XCTAssertTrue(resolve.contains("requireExpectedRef("))
        for signature in ["private func handleTap(", "private func handleDoubleTap(", "private func handlePress("] {
            XCTAssertTrue(try body(of: signature, in: router).contains("expect: req.expect"),
                          "\(signature) がホストの期待を渡していない")
        }
    }
}
