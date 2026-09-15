import XCTest
@testable import FTCore

/// FM ヒールの採用門の注入口(`HealConfidenceInjection` / `StepExecutor.healConfidenceGateInjected`)。
/// 門だけを開け、提案(FM が選んだ要素)は本物のまま使うこと・注入した事実が必ず記録に残ること・
/// 「代わりは無い」「答えを引き戻せない」の経路は変えないことを固定する。
final class HealConfidenceInjectionTests: XCTestCase {

    private final class StubDriver: AppDriver {
        let response: SnapshotResponse
        init(_ response: SnapshotResponse) { self.response = response }
        func status() async throws -> StatusResponse {
            StatusResponse(ready: true, device: "stub", osVersion: "-", sessionBundleID: nil)
        }
        func install(packagePath: String) async throws {}
        func uninstall(bundleID: String) async throws {}
        func isAppForeground(bundleID: String) async throws -> Bool { false }
        func foregroundAppID() async throws -> String? { nil }
        func launch(bundleID: String) async throws {}
        func snapshot() async throws -> SnapshotResponse { response }
        func tap(ref: Int) async throws {}
        func tap(x: Double, y: Double) async throws {}
        func type(ref: Int?, text: String) async throws {}
        func swipe(_ direction: FTSwipeDirection) async throws {}
        func press(ref: Int, duration: Double) async throws {}
        func screenshot() async throws -> Data { Data() }
        func terminate() async throws {}
    }

    private final class ScriptedAttemptHealer: ReplayDelegate {
        let attempt: HealAttempt
        init(_ attempt: HealAttempt) { self.attempt = attempt }
        func healLocator(step: FlowStep, snapshot: SnapshotResponse) async -> HealAttempt? { attempt }
        func verifyScreen(expected: String, screenshotPNG: Data) async -> (pass: Bool, reason: String)? { nil }
    }

    private let target = ElementInfo(ref: 1, type: "button", identifier: "btn_heal_v2", label: "修復対象",
                                     value: nil, placeholder: nil, enabled: true,
                                     frame: FTRect(x: 0, y: 100, width: 100, height: 40), depth: 1)

    private func executor(_ attempt: HealAttempt, injected: Bool) -> StepExecutor {
        let snap = SnapshotResponse(sessionBundleID: nil, screen: FTRect(x: 0, y: 0, width: 400, height: 800),
                                    elements: [target], truncatedCount: 0)
        let executor = StepExecutor(driver: StubDriver(snap), delegate: ScriptedAttemptHealer(attempt),
                                    healingEnabled: true, isAndroid: false)
        executor.healConfidenceGateInjected = injected
        return executor
    }

    private let step = FlowStep(action: "tap", locator: FlowLocator(id: "btn_heal_v1"))

    /// 鍵の名前と値の解釈は保守者の手順(fm-verify.sh・docs)が綴るのでリテラルで固定する。
    /// `1` 以外で効かせない(暴発させない)
    func testEnvironmentKeyAndActivationAreLiteral() {
        XCTAssertEqual(HealConfidenceInjection.environmentKey, "FT_FAKE_HEAL_CONFIDENCE_HIGH")
        XCTAssertEqual(StepNote.healConfidenceInjected.rawValue, "heal-confidence-injected")
        XCTAssertTrue(HealConfidenceInjection.isActive(environment: ["FT_FAKE_HEAL_CONFIDENCE_HIGH": "1"]))
        for value in ["0", "", "true", "yes", "high"] {
            XCTAssertFalse(HealConfidenceInjection.isActive(environment: ["FT_FAKE_HEAL_CONFIDENCE_HIGH": value]),
                           "値 \"\(value)\" で効いてはいけない")
        }
        XCTAssertFalse(HealConfidenceInjection.isActive(environment: [:]))
    }

    /// **本題**: 注入時は low の提案も採用し、提案された要素へのセレクタで healed になる。
    /// 注記と rationale の印が両方残る(キャッシュ・修正提案に写るのは rationale のほう)
    func testInjectedGateAdoptsLowConfidenceProposalAndMarksIt() async {
        let proposal = HealProposal(element: target, confidence: "low", rationale: "same label")
        let outcome = await executor(.proposed(proposal), injected: true).execute(step)

        guard case .healed(let locator) = outcome.status else {
            return XCTFail("注入時は low でも採用されるはず: \(outcome.status)")
        }
        XCTAssertEqual(locator.id, "btn_heal_v2")
        XCTAssertTrue(outcome.notes.contains(.healConfidenceInjected), "\(outcome.notes)")
        XCTAssertFalse(outcome.notes.contains(.healProposalRejected), "\(outcome.notes)")
        let note = outcome.healedStep?.note ?? ""
        XCTAssertTrue(note.contains("self-healed: [confidence low, adopted by FT_FAKE_HEAL_CONFIDENCE_HIGH] same label"),
                      "rationale に注入の印が無い: \(note)")
    }

    /// 陰性対照: 同じ提案でも注入しなければ従来どおり却下(本番の門は変えていない)
    func testWithoutInjectionLowConfidenceIsStillRejected() async {
        let proposal = HealProposal(element: target, confidence: "low", rationale: "same label")
        let outcome = await executor(.proposed(proposal), injected: false).execute(step)

        guard case .failed = outcome.status else {
            return XCTFail("注入なしでは low は却下のはず: \(outcome.status)")
        }
        XCTAssertTrue(outcome.notes.contains(.healProposalRejected), "\(outcome.notes)")
        XCTAssertFalse(outcome.notes.contains(.healConfidenceInjected), "\(outcome.notes)")
    }

    /// high の提案は注入の有無で何も変わらない(注記も印も付けない = 本番と同じ記録)
    func testHighConfidenceIsUnmarkedEvenWhenInjected() async {
        let proposal = HealProposal(element: target, confidence: "high", rationale: "same label")
        let outcome = await executor(.proposed(proposal), injected: true).execute(step)

        guard case .healed = outcome.status else {
            return XCTFail("high は採用されるはず: \(outcome.status)")
        }
        XCTAssertFalse(outcome.notes.contains(.healConfidenceInjected), "\(outcome.notes)")
        XCTAssertFalse((outcome.healedStep?.note ?? "").contains("FT_FAKE_HEAL_CONFIDENCE_HIGH"))
    }

    /// 注入は `.proposed` の採否だけに効く。「代わりは無い」「答えを木へ引き戻せない」は失敗のまま
    func testInjectionDoesNotTouchNoReplacementOrUnresolved() async {
        for attempt in [HealAttempt.noReplacement(rationale: "none"), .unresolved(rawAnswer: "btn_x")] {
            let outcome = await executor(attempt, injected: true).execute(step)
            guard case .failed = outcome.status else {
                return XCTFail("\(attempt) は注入でも失敗のはず: \(outcome.status)")
            }
            XCTAssertFalse(outcome.notes.contains(.healConfidenceInjected), "\(outcome.notes)")
        }
    }
}
