import XCTest
@testable import FTCore

/// 却下された自己修復の提案(confidence != "high")に、フォールバック機構(`primary||fallback`)
/// を教える一文が失敗文言へ添えられることを固定する。
///
/// **具体的な貼れるセレクタ連鎖を組み立てないことが本題**。一度
/// `SelectorNaming` + `FTSelector.serialize` で「元のロケータ||提案セレクタ」の具体的な連鎖を
/// 組み立てて出す版を実装したが、2026-09-02 のデバイス実行(`Scripts/fm-verify.sh`)で撤回した:
/// 93_triage(存在しない要素をわざと叩く陽性対照)で FM が無関係な要素を提案し、それが
/// `"#btn_triage_check_does_not_exist||#nav_input"` というそのまま貼れる形の助言になった。
/// confidence は信号を持たない(正解にも誤答にも "low" が付く。docs/design.md §10)ため、
/// ツール側は提案の正しさを判定できず、貼れる形にすると誤った提案が「誤った緑」(別要素を
/// 叩き続けるテスト)に化ける。だから**機構だけを教え、どの要素を使うかは読み手に委ねる**。
///
/// **採用基準(confidence == "high")はここでは変えない** —— この一連のテストは文言だけを見る。
/// high 経路(従来どおり自己修復して healed になる)にはこの一文が出ないことも併せて確認する。
final class HealProposalRejectedFallbackHintTests: XCTestCase {

    /// snapshot() は固定の木を1つだけ返す最小ドライバ(必須メンバのみ実装。他は
    /// AppDriver のプロトコル既定実装に委ねる — 既存の Heal*Tests.swift と同じ形)
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

    /// FM の代わり: 呼ぶたびに固定の `HealAttempt` を返す
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

    /// **本題(陽性)**: 却下された提案があるとき、フォールバック機構(`primary||fallback`)を
    /// 教える一文が失敗文言に含まれる。「決して出さない」変異が入っていたら、ここが落ちる
    func testRejectedProposalMentionsTheFallbackMechanism() async throws {
        let target = element(1, type: "button", id: "btn_heal_v2", label: "修復対象", depth: 1)
        let snap = snapshot([target])
        let driver = StubDriver(snap)
        let proposal = HealProposal(element: target, confidence: "low", rationale: "looks plausible")
        let executor = StepExecutor(driver: driver,
                                    delegate: ScriptedAttemptHealer(.proposed(proposal)),
                                    healingEnabled: true, isAndroid: false)
        let step = FlowStep(action: "tap", locator: FlowLocator(id: "btn_heal_v1"))
        let outcome = await executor.execute(step)

        guard case .failed(let message) = outcome.status else {
            return XCTFail("low confidence の提案は従来どおり失敗のはず: \(outcome.status)")
        }
        XCTAssertTrue(message.contains("write the locator with a fallback"),
                      "フォールバック機構を教える一文が無い: \(message)")
        XCTAssertTrue(message.contains("primary||fallback"),
                      "機構の形(primary||fallback)を教えるべき: \(message)")
    }

    /// **本題(いちばん重要な陰性)**: 提案要素の id と元のロケータを `||` で連ねた**具体的な
    /// セレクタ連鎖**は失敗文言に現れない。「提案の要素が分かっているのだから貼れる連鎖を
    /// 組み立てて出せばよい」という退行(2026-09-02 に一度実装され、デバイス実行で危険と
    /// 判明して撤回された変更)が戻っていないかを直接落とす。
    ///
    /// **`#btn_heal_v2` 自体が消えることは期待しない** —— `self-heal proposed button #btn_heal_v2
    /// "修復対象" ...` という**提案の表示**は引き続き残ってよい(読み手が自分で判断する材料)。
    /// 消えるべきは「元のロケータ||提案セレクタ」という**連鎖の形**だけ
    func testRejectedProposalDoesNotAssembleAConcreteFallbackChain() async throws {
        let target = element(1, type: "button", id: "btn_heal_v2", label: "修復対象", depth: 1)
        let snap = snapshot([target])
        let driver = StubDriver(snap)
        let proposal = HealProposal(element: target, confidence: "low", rationale: "looks plausible")
        let executor = StepExecutor(driver: driver,
                                    delegate: ScriptedAttemptHealer(.proposed(proposal)),
                                    healingEnabled: true, isAndroid: false)
        let step = FlowStep(action: "tap", locator: FlowLocator(id: "btn_heal_v1"))
        let outcome = await executor.execute(step)

        guard case .failed(let message) = outcome.status else {
            return XCTFail("low confidence の提案は従来どおり失敗のはず: \(outcome.status)")
        }
        // 提案そのものの表示(自然文)は残ってよい
        XCTAssertTrue(message.contains("self-heal proposed"), message)
        XCTAssertTrue(message.contains("#btn_heal_v2"), message)
        // だが「元のロケータ||提案セレクタ」という貼れる連鎖の形は絶対に出てはいけない
        XCTAssertFalse(message.contains("#btn_heal_v1||#btn_heal_v2"),
                       "貼れる具体的な連鎖を組み立ててはいけない(誤った緑を生む): \(message)")
        XCTAssertFalse(message.contains("id=btn_heal_v1||#btn_heal_v2"),
                       "貼れる具体的な連鎖を組み立ててはいけない(誤った緑を生む): \(message)")
    }

    /// **陰性(同型)**: 対象が存在しない要素へのタップで、FM が無関係な要素を提案した
    /// 実測の型(93_triage)を模した回でも、連鎖は組み立てられない。
    /// 「常に連鎖を組み立てる」変異が入っていたら、ここが落ちる
    func testRejectedProposalForUnrelatedElementDoesNotAssembleAChainEither() async throws {
        let unrelated = element(1, type: "button", id: "nav_input", label: "ナビゲーション入力", depth: 1)
        let snap = snapshot([unrelated])
        let driver = StubDriver(snap)
        let proposal = HealProposal(element: unrelated, confidence: "low",
                                    rationale: "closest match in the element list")
        let executor = StepExecutor(driver: driver,
                                    delegate: ScriptedAttemptHealer(.proposed(proposal)),
                                    healingEnabled: true, isAndroid: false)
        let step = FlowStep(action: "tap",
                            locator: FlowLocator(id: "btn_triage_check_does_not_exist"))
        let outcome = await executor.execute(step)

        guard case .failed(let message) = outcome.status else {
            return XCTFail("low confidence の提案は従来どおり失敗のはず: \(outcome.status)")
        }
        XCTAssertFalse(message.contains("#btn_triage_check_does_not_exist||#nav_input"),
                       "実測で危険と判明した具体的な連鎖を組み立ててはいけない: \(message)")
        XCTAssertFalse(message.contains("id=btn_triage_check_does_not_exist||#nav_input"),
                       "実測で危険と判明した具体的な連鎖を組み立ててはいけない: \(message)")
    }

    /// **対照**: confidence が "high" のときは従来どおり修復され(healed)、
    /// 却下経路の一文(この関数の hint)はそもそも出ない
    func testHighConfidenceStillHealsWithoutTheRejectedProposalHint() async throws {
        let target = element(1, type: "button", id: "btn_heal_v2", label: "修復対象", depth: 1)
        let snap = snapshot([target])
        let driver = StubDriver(snap)
        let proposal = HealProposal(element: target, confidence: "high", rationale: "clear match")
        let executor = StepExecutor(driver: driver,
                                    delegate: ScriptedAttemptHealer(.proposed(proposal)),
                                    healingEnabled: true, isAndroid: false)
        let step = FlowStep(action: "tap", locator: FlowLocator(id: "btn_heal_v1"))
        let outcome = await executor.execute(step)

        guard case .healed(let locator) = outcome.status else {
            return XCTFail("high confidence は healed であるべき: \(outcome.status)")
        }
        XCTAssertEqual(locator, FlowLocator(id: "btn_heal_v2"))
        XCTAssertFalse(outcome.notes.contains(.healProposalRejected),
                       "採用できた回に healProposalRejected を立ててはいけない: \(outcome.notes)")
    }
}
