import XCTest
@testable import FTCore

/// 2026-09-02 の実測(TestProjects/E2E-CMP/scenarios/_disabled/90_自己修復.swift):
/// 結果 JSON は heal calls=1/failures=0/skipped=0(FM は呼べて答えも返した)なのに、失敗は
/// 「一度も heal を試さなかった」場合と1文字も違わない `cannot resolve the locator: id=btn_heal_v1`
/// になった —— `ReplayAssist.healLocator` が `resolveByText` の nil を単に `nil` へ潰しており、
/// モデルが実際に何を返したかが結果 JSON からも失敗文言からも読めなかった(黙る経路)。
///
/// ここでは `StepExecutor+Actions.swift` の healLocator 分岐が、`ReplayDelegate.healLocator` の
/// 戻り値 `HealAttempt.unresolved(rawAnswer:)` を受けたとき、**その生テキストを失敗文言へそのまま
/// 添え**、`StepNote.healAnswerUnresolved` を立てることを固定する。
/// 隣接する `StepNote.healProposalRejected`(採用基準未達で捨てた)とは別の経路であることも、
/// 「常に立てる」「決して立てない」の両方向の変異で区別できる形にする。
final class HealAnswerUnresolvedTests: XCTestCase {

    /// snapshot() は固定の木を1つだけ返す最小ドライバ(必須メンバのみ実装。他は
    /// AppDriver のプロトコル既定実装に委ねる — HealSilentDropTests.swift と同じ形)
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

    /// FM の代わり: 呼ぶたびに固定の `HealAttempt` を返す(ReplayAssist を経由せず
    /// StepExecutor+Actions 側の分岐だけを狙って通す)
    private final class ScriptedAttemptHealer: ReplayDelegate {
        let attempt: HealAttempt
        init(_ attempt: HealAttempt) { self.attempt = attempt }
        func healLocator(step: FlowStep, snapshot: SnapshotResponse) async -> HealAttempt? { attempt }
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
        XCTAssertEqual(StepNote.healAnswerUnresolved.rawValue, "heal-answer-unresolved")
    }

    /// **本題**: FM は呼べて答えも返したが、その生テキストが木のどの要素にも一致しなかった
    /// (`resolveByText` が nil)。注記が立ち、失敗文言に**生の答えの文字列がそのまま**含まれること。
    /// 「決して立てない」変異が入っていたら、ここが落ちる
    func testUnresolvedAnswerSetsNoteAndCarriesTheRawAnswerVerbatim() async throws {
        let snap = snapshot([element(1, type: "clickable", id: "btn_heal_v2", depth: 1)])
        let driver = StubDriver(snap)
        let rawAnswer = "「元の商品ページへ戻る」ボタン"
        let executor = StepExecutor(driver: driver,
                                    delegate: ScriptedAttemptHealer(.unresolved(rawAnswer: rawAnswer)),
                                    healingEnabled: true, isAndroid: false)
        let step = FlowStep(action: "tap", locator: FlowLocator(id: "btn_heal_v1"))
        let outcome = await executor.execute(step)

        XCTAssertTrue(outcome.notes.contains(.healAnswerUnresolved),
                      "FM が引き戻せなかった答えを黙ってはいけない: \(outcome.notes)")
        XCTAssertFalse(outcome.notes.contains(.healProposalRejected),
                       "別経路の注記(採用基準未達)を誤って立ててはいけない: \(outcome.notes)")
        guard case .failed(let message) = outcome.status else {
            return XCTFail("要素へ引き戻せない答えは失敗のはず: \(outcome.status)")
        }
        XCTAssertTrue(message.contains("cannot resolve the locator: id=btn_heal_v1"), message)
        // 生の答え(モデルが実際に返した文字列)がそのまま読めること —— 推測でなく原因特定の材料
        XCTAssertTrue(message.contains(rawAnswer), message)
        XCTAssertFalse(message.contains("self-heal proposed"),
                       "却下された提案(healProposalRejected)の文言と混同してはいけない: \(message)")
    }

    /// high confidence の提案は従来どおり採用される。「常に立てる」変異が入っていたら、
    /// 採用できた回にも新しい注記が付いてここが落ちる
    func testProposedHighConfidenceDoesNotSetTheUnresolvedNote() async throws {
        let target = element(1, type: "clickable", id: "btn_heal_v2", depth: 1)
        let snap = snapshot([target])
        let driver = StubDriver(snap)
        let proposal = HealProposal(element: target, confidence: "high", rationale: "test heal")
        let executor = StepExecutor(driver: driver,
                                    delegate: ScriptedAttemptHealer(.proposed(proposal)),
                                    healingEnabled: true, isAndroid: false)
        let step = FlowStep(action: "tap", locator: FlowLocator(id: "btn_heal_v1"))
        let outcome = await executor.execute(step)

        XCTAssertTrue(StepExecutor.isSuccess(outcome.status),
                      "high confidence の提案は採用されるべき: \(outcome.status)")
        XCTAssertFalse(outcome.notes.contains(.healAnswerUnresolved),
                       "採用できた回に heal-answer-unresolved を立ててはいけない: \(outcome.notes)")
    }

    /// high に届かない confidence の提案は `healProposalRejected` の対象であって、
    /// `healAnswerUnresolved` の対象ではない(別の経路)。「常に立てる」変異が入っていたら、
    /// ここが落ちる
    func testProposedBelowHighConfidenceDoesNotSetTheUnresolvedNote() async throws {
        let target = element(1, type: "clickable", id: "btn_heal_v2", label: "修復対象", depth: 1)
        let snap = snapshot([target])
        let driver = StubDriver(snap)
        let proposal = HealProposal(element: target, confidence: "medium", rationale: "test heal")
        let executor = StepExecutor(driver: driver,
                                    delegate: ScriptedAttemptHealer(.proposed(proposal)),
                                    healingEnabled: true, isAndroid: false)
        let step = FlowStep(action: "tap", locator: FlowLocator(id: "btn_heal_v1"))
        let outcome = await executor.execute(step)

        XCTAssertTrue(outcome.notes.contains(.healProposalRejected), "\(outcome.notes)")
        XCTAssertFalse(outcome.notes.contains(.healAnswerUnresolved),
                       "採用基準未達は healProposalRejected の対象であり healAnswerUnresolved ではない: \(outcome.notes)")
    }
}
