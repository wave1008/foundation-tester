import XCTest
@testable import FTCore

/// 2026-09-02 の実測(TestProjects/E2E-CMP/scenarios/_disabled/93_triage.swift、5周で完全再現):
/// 存在しない要素をわざと叩く陽性対照シナリオ(正解は「代わりは無い」)で、モデルが5周とも
/// 無関係な `#nav_selector` を medium confidence で提案した。真因は
/// `LocatorRepairSuggestion.elementText` が非オプショナルで、モデルに「代わりは無い」と
/// 答える余地を与えていなかったこと(選択肢を与えていない設計の帰結であって、モデルの誤りではない)。
///
/// ここでは `StepExecutor+Actions.swift` の healLocator 分岐が、`ReplayDelegate.healLocator` の
/// 戻り値 `HealAttempt.noReplacement(rationale:)` を受けたとき、`StepNote.healNoReplacement` を立て、
/// 失敗文言に rationale を添えることを固定する。**隣接する `healAnswerUnresolved`(答えを要素へ
/// 引き戻せなかった)・`healProposalRejected`(採用基準未達)とは意味が違う別の経路**であることを、
/// 3つの注記が混ざらないことで確認する(陰性テストがいちばん重要)。
final class HealNoReplacementTests: XCTestCase {

    /// snapshot() は固定の木を1つだけ返す最小ドライバ(必須メンバのみ実装。他は
    /// AppDriver のプロトコル既定実装に委ねる — HealAnswerUnresolvedTests.swift と同じ形)
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

    /// 注記は結果 JSON に出る対外的な契約なので、改名が黙って通らないようリテラルで固定する
    func testNoteKeyIsStableKebabCase() {
        XCTAssertEqual(StepNote.healNoReplacement.rawValue, "heal-no-replacement")
    }

    /// **本題**: FM は一覧を見たうえで「妥当な代わりが無い」と判断した(`.noReplacement`)。
    /// `healNoReplacement` が立ち、失敗文言に rationale が含まれること。
    /// 「決して立てない」変異が入っていたら、ここが落ちる
    func testNoReplacementSetsNoteAndCarriesTheRationale() async throws {
        let snap = snapshot([element(1, type: "clickable", id: "nav_selector", label: "セレクタ", depth: 1)])
        let driver = StubDriver(snap)
        let rationale = "None of the listed elements share the role of the missing target."
        let executor = StepExecutor(driver: driver,
                                    delegate: ScriptedAttemptHealer(.noReplacement(rationale: rationale)),
                                    healingEnabled: true, isAndroid: false)
        let step = FlowStep(action: "tap", locator: FlowLocator(id: "btn_triage_check_does_not_exist"))
        let outcome = await executor.execute(step)

        XCTAssertTrue(outcome.notes.contains(.healNoReplacement),
                      "FM が「代わりは無い」と判断した回を黙ってはいけない: \(outcome.notes)")
        guard case .failed(let message) = outcome.status else {
            return XCTFail("代わりが無いと判断された回は失敗のはず: \(outcome.status)")
        }
        XCTAssertTrue(message.contains("cannot resolve the locator: id=btn_triage_check_does_not_exist"),
                      message)
        // rationale がそのまま読めること —— なぜ無いと判断したかが利用者に有用
        XCTAssertTrue(message.contains(rationale), message)

        // **いちばん重要な陰性テスト**: 3つの経路が混ざっていないこと
        XCTAssertFalse(outcome.notes.contains(.healAnswerUnresolved),
                       "別経路(答えを要素へ引き戻せなかった)の注記を誤って立ててはいけない: \(outcome.notes)")
        XCTAssertFalse(outcome.notes.contains(.healProposalRejected),
                       "別経路(採用基準未達)の注記を誤って立ててはいけない: \(outcome.notes)")
        XCTAssertFalse(message.contains("self-heal proposed"),
                       "却下された提案(healProposalRejected)の文言と混同してはいけない: \(message)")
        XCTAssertFalse(message.contains("self-heal answered"),
                       "引き戻せなかった答え(healAnswerUnresolved)の文言と混同してはいけない: \(message)")
    }

    /// 逆方向: 名指しがあって引き戻せないケース(`.unresolved`)では、新しい注記
    /// `healNoReplacement` は立たず、従来どおり `healAnswerUnresolved` が立つこと。
    /// 「常に新ケースにする」変異が入っていたら、ここが落ちる
    func testUnresolvedAnswerDoesNotSetTheNoReplacementNote() async throws {
        let snap = snapshot([element(1, type: "clickable", id: "btn_heal_v2", depth: 1)])
        let driver = StubDriver(snap)
        let rawAnswer = "戻るボタン(見当たらない)"
        let executor = StepExecutor(driver: driver,
                                    delegate: ScriptedAttemptHealer(.unresolved(rawAnswer: rawAnswer)),
                                    healingEnabled: true, isAndroid: false)
        let step = FlowStep(action: "tap", locator: FlowLocator(id: "btn_heal_v1"))
        let outcome = await executor.execute(step)

        XCTAssertTrue(outcome.notes.contains(.healAnswerUnresolved), "\(outcome.notes)")
        XCTAssertFalse(outcome.notes.contains(.healNoReplacement),
                       "答えはあった以上、新しい注記(代わりが無いという判断)を立ててはいけない: \(outcome.notes)")
        guard case .failed(let message) = outcome.status else {
            return XCTFail("引き戻せない答えは失敗のはず: \(outcome.status)")
        }
        XCTAssertFalse(message.contains("looked at the element list but found no valid replacement"),
                       "healNoReplacement 側の文言が混ざってはいけない: \(message)")
    }

    /// high confidence の提案は従来どおり採用される。「常に新ケースにする」変異が入っていたら、
    /// 採用できた回にも healNoReplacement が付いてここが落ちる
    func testProposedHighConfidenceDoesNotSetTheNoReplacementNote() async throws {
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
        XCTAssertFalse(outcome.notes.contains(.healNoReplacement),
                       "採用できた回に heal-no-replacement を立ててはいけない: \(outcome.notes)")
    }
}
