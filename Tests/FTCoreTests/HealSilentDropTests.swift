import XCTest
@testable import FTCore

/// 2026-09-02 の `Scripts/fm-verify.sh` 実測(TestProjects/E2E-CMP/scenarios/_disabled/90_自己修復.swift):
/// FM は `#btn_heal_v1` の代わりを `#btn_heal_v2`(medium confidence)として正しく提案していたのに、
/// 採用条件(`proposal.confidence == "high"`)を満たさずに捨てられ、失敗は
/// 「一度も heal を試さなかった」場合と1文字も違わない `cannot resolve the locator: id=btn_heal_v1`
/// になった —— FM が答えを持っていた事実が結果 JSON からも失敗文言からも読めなかった。
///
/// ここでは `StepExecutor+Actions.swift` の healLocator 分岐が、**採用基準(confidence == "high")は
/// 変えないまま**、却下された提案を `StepNote.healProposalRejected` と失敗文言の両方で
/// 観測可能にしていることを固定する。
final class HealSilentDropTests: XCTestCase {

    /// snapshot() は固定の木を1つだけ返す最小ドライバ(必須メンバのみ実装。他は
    /// AppDriver のプロトコル既定実装に委ねる — StepExecutorHealSelectorNamingTests.swift と同じ形)
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

    /// FM の代わり: 指定した ref を、指定した confidence で提案する(実測の 90_自己修復.swift で
    /// FM が返した medium と、採用される high の両方を同じ delegate で作れるようにする)
    private final class ScriptedConfidenceHealer: ReplayDelegate {
        let ref: Int
        let confidence: String
        init(ref: Int, confidence: String) {
            self.ref = ref
            self.confidence = confidence
        }
        func healLocator(step: FlowStep, snapshot: SnapshotResponse) async -> HealAttempt? {
            snapshot.elements.first { $0.ref == ref }
                .map { .proposed(HealProposal(element: $0, confidence: confidence, rationale: "test heal")) }
        }
        func verifyScreen(expected: String, screenshotPNG: Data) async -> (pass: Bool, reason: String)? { nil }
        func triage(goal: String?, stepDescription: String, failureReason: String,
                    snapshot: SnapshotResponse?, screenshotPNG: Data?) async -> TriageInfo? { nil }
    }

    private func element(_ ref: Int, type: String = "clickable", id: String? = nil,
                         label: String? = nil, depth: Int = 2, y: Double = 100) -> ElementInfo {
        ElementInfo(ref: ref, type: type, identifier: id, label: label, value: nil,
                    placeholder: nil, enabled: true,
                    frame: FTRect(x: 0, y: y, width: 100, height: 40), depth: depth)
    }

    private func snapshot(_ elements: [ElementInfo]) -> SnapshotResponse {
        SnapshotResponse(sessionBundleID: nil, screen: FTRect(x: 0, y: 0, width: 400, height: 800),
                         elements: elements, truncatedCount: 0)
    }

    /// 注記は結果 JSON に出る対外的な契約(run 横断の集計・MCP・受け手のダッシュボードが鍵の
    /// 文字列で拾う)なので、**改名が黙って通らないようリテラルで固定する**
    func testNoteKeyIsStableKebabCase() {
        XCTAssertEqual(StepNote.healProposalRejected.rawValue, "heal-proposal-rejected")
    }

    /// high confidence は従来どおり採用される。「却下注記を常に立てる」変異が入っていたら、
    /// 採用できた回にも注記が付いてここが落ちる
    func testHighConfidenceProposalIsAcceptedAndDoesNotSetTheRejectedNote() async throws {
        let snap = snapshot([element(1, type: "clickable", id: "btn_heal_v2", depth: 1)])
        let driver = StubDriver(snap)
        let executor = StepExecutor(driver: driver,
                                    delegate: ScriptedConfidenceHealer(ref: 1, confidence: "high"),
                                    healingEnabled: true, isAndroid: false)
        let step = FlowStep(action: "tap", locator: FlowLocator(id: "btn_heal_v1"))
        let outcome = await executor.execute(step)

        XCTAssertTrue(StepExecutor.isSuccess(outcome.status),
                      "high confidence の提案は採用されるべき: \(outcome.status)")
        XCTAssertFalse(outcome.notes.contains(.healProposalRejected),
                       "採用できた回に却下注記を立ててはいけない: \(outcome.notes)")
    }

    /// **本題**: high に届かない confidence(実測は medium)の提案は不採用のままでよいが、
    /// **黙って「探しても見つからなかった」と同じ形にしてはいけない**。注記と失敗文言の両方に、
    /// 却下された提案があったことが残ることを固定する。「却下注記を決して立てない」変異が
    /// 入っていたら、ここが落ちる
    func testBelowHighConfidenceProposalIsRejectedButNotSilently() async throws {
        let snap = snapshot([element(1, type: "clickable", id: "btn_heal_v2",
                                     label: "修復対象", depth: 1)])
        let driver = StubDriver(snap)
        let executor = StepExecutor(driver: driver,
                                    delegate: ScriptedConfidenceHealer(ref: 1, confidence: "medium"),
                                    healingEnabled: true, isAndroid: false)
        let step = FlowStep(action: "tap", locator: FlowLocator(id: "btn_heal_v1"))
        let outcome = await executor.execute(step)

        XCTAssertTrue(outcome.notes.contains(.healProposalRejected),
                      "confidence 不足の却下を黙ってはいけない: \(outcome.notes)")
        guard case .failed(let message) = outcome.status else {
            return XCTFail("採用基準に届かない提案は失敗のはず(操作を続ける対象にはしない): \(outcome.status)")
        }
        XCTAssertTrue(message.contains("cannot resolve the locator: id=btn_heal_v1"), message)
        // FM は答えを持っていたことが失敗文言からも読めること(利用者が結果だけで気付ける形)
        XCTAssertTrue(message.contains("self-heal proposed"), message)
        XCTAssertTrue(message.contains("\"medium\""), message)
        XCTAssertTrue(message.contains("not \"high\""), message)
    }
}
