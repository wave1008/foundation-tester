import XCTest
@testable import FTCore

/// 自己修復(`healLocator`)の結果は `ftester api apply-heal` が利用者の .swift ソースへ
/// 書き戻す(FTRuntime.perform → FixSuggestion → apply-heal)。書き戻すセレクタの選び方は
/// `SelectorNaming`(MCP と共有)に一本化されており、**一意に書けるセレクタが無い要素では
/// ヒールを成立させてはいけない**(2026-08-15)。
///
/// 背景: 旧実装 `FlowLocatorBuilder.chain` は画面内の一意性を見ずに id/label をそのまま
/// 採っていたため、同じ id を持つ要素が複数ある画面では「ヒールが選んだ要素とは別の要素に
/// 解決するセレクタ」を書き戻していた。ここでは StepExecutor 単体で、その書き戻しに載る
/// `healedStep` が ambiguous な画面では**作られないこと**を固定する。
final class StepExecutorHealSelectorNamingTests: XCTestCase {

    /// snapshot() は固定の木を1つだけ返す最小ドライバ(必須メンバのみ実装。他は
    /// AppDriver のプロトコル既定実装に委ねる — HealSuggestionRecordingTests.swift と同じ形)
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

    /// FM の代わり: 常に指定した ref を "high" confidence で提案する
    private final class FixedHealer: ReplayDelegate {
        let ref: Int
        init(ref: Int) { self.ref = ref }
        func healLocator(step: FlowStep, snapshot: SnapshotResponse) async -> HealProposal? {
            snapshot.elements.first { $0.ref == ref }
                .map { HealProposal(element: $0, confidence: "high", rationale: "test heal") }
        }
        func verifyScreen(expected: String, screenshotPNG: Data) async -> (pass: Bool, reason: String)? { nil }
        func triage(goal: String?, stepDescription: String, failureReason: String,
                    snapshot: SnapshotResponse?, screenshotPNG: Data?) async -> TriageInfo? { nil }
    }

    /// MCPWritableSelectorTests と同じ既定(同じ y にすると contains の同一矩形判定が通り、
    /// スコープの祖先包含テストが素直に書ける)
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

    /// **本題**: 同じ id を持つ要素が2つあり、どちらにもラベルも一意なスコープも無い画面では、
    /// ヒールの提案先がその片方でも、SelectorNaming は一意に書けるセレクタを返さない(nil)。
    /// この回は**操作は続く(passed)が healedStep は作られない** —— 掴んだ要素は手元にあるので
    /// 叩くこと自体は正しく、書き戻せないという理由だけでシナリオを中断しない。
    /// `healedStep` が作られていたら「書けないセレクタが書き戻される」欠陥が再発している
    func testAmbiguousDuplicateIDCandidateDoesNotWriteBackButStillActs() async throws {
        let snap = snapshot([
            element(1, type: "textField", id: "row_input", depth: 1),
            element(2, type: "textField", id: "row_input", depth: 1, y: 200),
        ])
        let driver = StubDriver(snap)
        let executor = StepExecutor(driver: driver, delegate: FixedHealer(ref: 1), healingEnabled: true)
        // 素の locator は木のどこにも無い(旧セレクタが古くなった想定)→ cache miss →
        // delegate.healLocator へ進む
        let step = FlowStep(action: "tap", locator: FlowLocator(id: "stale_id"))
        let outcome = await executor.execute(step)

        XCTAssertTrue(StepExecutor.isSuccess(outcome.status),
                      "書き戻せないだけで失敗させてはいけない: \(outcome.status)")
        if case .healed = outcome.status {
            XCTFail("一意に書けないのに healed を名乗ってはいけない: \(outcome.status)")
        }
        XCTAssertNil(outcome.healedStep, "書けないセレクタで healedStep を作ってはいけない")
        XCTAssertTrue(outcome.notes.contains(.healUnwritable),
                      "書き戻せなかったことを黙ってはいけない: \(outcome.notes)")
    }

    /// 対照: 一意な id が付いた要素なら従来どおり成立し、`SelectorNaming` が選んだ形
    /// (`#id`)がそのまま healedStep.locator になる
    func testUniqueIDCandidateHealsNormally() async throws {
        let snap = snapshot([element(1, type: "textField", id: "unique_input", depth: 1)])
        let driver = StubDriver(snap)
        let executor = StepExecutor(driver: driver, delegate: FixedHealer(ref: 1), healingEnabled: true)
        let step = FlowStep(action: "tap", locator: FlowLocator(id: "stale_id"))
        let outcome = await executor.execute(step)

        guard case .healed(let locator) = outcome.status else {
            return XCTFail("一意な候補は healed であるべき: \(outcome.status)")
        }
        XCTAssertEqual(locator, FlowLocator(id: "unique_input"))
        XCTAssertEqual(outcome.healedStep?.locator, FlowLocator(id: "unique_input"))
    }

    /// id もラベルも無いがスコープ添字(`#tabs >> .clickable[n]`)でだけ書ける要素は healed に
    /// なるが、**位置に依存する**ことを note へ残す(Durability.indexed.caution)。
    /// 黙って位置依存セレクタを利用者のソースへ書かない、が要点
    func testIndexedOnlyCandidateHealsWithACautionNote() async throws {
        let snap = snapshot([
            element(1, type: "other", id: "tabs", depth: 1),
            element(2, type: "clickable", depth: 2),
            element(3, type: "clickable", depth: 2),
        ])
        let driver = StubDriver(snap)
        let executor = StepExecutor(driver: driver, delegate: FixedHealer(ref: 2), healingEnabled: true)
        let step = FlowStep(action: "tap", locator: FlowLocator(id: "stale_id"))
        let outcome = await executor.execute(step)

        guard case .healed = outcome.status else {
            return XCTFail("スコープ添字で書けるなら healed であるべき: \(outcome.status)")
        }
        let note = try XCTUnwrap(outcome.healedStep?.note)
        XCTAssertTrue(note.contains("index-based"), note)
    }
}
