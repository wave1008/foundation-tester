import XCTest
@testable import FTCore

/// `StepExecutor+Actions.swift` の解決分岐に足したロケータ指紋の階層(matchCached の後・
/// select の特例の後・FM ヒールより前)を、`executor.execute(step, fingerprint:)` 経由で
/// end-to-end に確かめる。プライマリ/フォールバック/キャッシュがどれも解決できない失敗経路
/// だけで効く機構なので、ここでは常にプライマリが解決できない `FlowLocator` を渡す。
final class LocatorFingerprintResolutionTests: XCTestCase {

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

    /// 呼ばれたら即失敗させる delegate。「指紋が一意に解決した回は FM を呼ばない」ことを
    /// 確かめるのに使う(呼ばれてしまえばテストがすぐ落ちる)
    private final class MustNotBeCalledHealer: ReplayDelegate {
        func healLocator(step: FlowStep, snapshot: SnapshotResponse) async -> HealAttempt? {
            XCTFail("指紋が一意に解決できたのに FM を呼んではいけない")
            return nil
        }
        func verifyScreen(expected: String, screenshotPNG: Data) async -> (pass: Bool, reason: String)? { nil }
        func triage(goal: String?, stepDescription: String, failureReason: String,
                    snapshot: SnapshotResponse?, screenshotPNG: Data?) async -> TriageInfo? { nil }
    }

    private final class ScriptedAttemptHealer: ReplayDelegate {
        let attempt: HealAttempt
        init(_ attempt: HealAttempt) { self.attempt = attempt }
        func healLocator(step: FlowStep, snapshot: SnapshotResponse) async -> HealAttempt? { attempt }
        func verifyScreen(expected: String, screenshotPNG: Data) async -> (pass: Bool, reason: String)? { nil }
        func triage(goal: String?, stepDescription: String, failureReason: String,
                    snapshot: SnapshotResponse?, screenshotPNG: Data?) async -> TriageInfo? { nil }
    }

    private func element(_ ref: Int, type: String = "button", id: String? = nil,
                         label: String? = nil, depth: Int = 0) -> ElementInfo {
        ElementInfo(ref: ref, type: type, identifier: id, label: label, value: nil,
                    placeholder: nil, enabled: true,
                    frame: FTRect(x: 0, y: 0, width: 100, height: 40), depth: depth)
    }

    private func snapshot(_ elements: [ElementInfo]) -> SnapshotResponse {
        SnapshotResponse(sessionBundleID: nil, screen: FTRect(x: 0, y: 0, width: 400, height: 800),
                         elements: elements, truncatedCount: 0)
    }

    /// 注記は結果 JSON に出る対外的な契約なので、改名が黙って通らないようリテラルで固定する
    func testNoteKeyIsStableKebabCase() {
        XCTAssertEqual(StepNote.healFingerprintMatch.rawValue, "heal-fingerprint-match")
    }

    /// **本題**: id がドリフトした(`#btn_old` → `#btn_new`)が type+label は不変。指紋がちょうど
    /// 1件に決定的に解決し、書けるセレクタ(`#btn_new` が画面で一意な id)があるので healedStep が
    /// 立って `.healed` になる。FM は呼ばれない(healingEnabled=true でも delegate が呼ばれたら落ちる)
    func testUniqueFingerprintMatchHealsWithoutCallingFM() async {
        let snap = snapshot([element(1, id: "btn_new", label: "修復対象")])
        let driver = StubDriver(snap)
        let executor = StepExecutor(driver: driver, delegate: MustNotBeCalledHealer(),
                                    healingEnabled: true, isAndroid: false)
        let step = FlowStep(action: "tap", locator: FlowLocator(id: "btn_old"))
        let fp = LocatorFingerprint(type: "button", label: "修復対象", placeholder: nil)

        let outcome = await executor.execute(step, fingerprint: fp)

        XCTAssertTrue(outcome.notes.contains(.healFingerprintMatch), "\(outcome.notes)")
        XCTAssertTrue(outcome.healedByFingerprint)
        XCTAssertFalse(outcome.healedByCache)
        guard case .healed(let locator) = outcome.status else {
            return XCTFail("一意な指紋一致は healed のはず: \(outcome.status)")
        }
        XCTAssertEqual(locator.id, "btn_new")
        XCTAssertEqual(outcome.healedStep?.locator?.id, "btn_new")
    }

    /// **最重要の陰性テスト**: 型+ラベルが同じ要素が2つあるとき、指紋は不採用のまま従来の
    /// FM ヒールへ委ねる(別要素へ静かに解決してはいけない)。「常に解決する」変異が入っていたら、
    /// この回だけ MustNotBeCalledHealer が呼ばれてテストが落ちる
    func testAmbiguousFingerprintFallsThroughToFM() async {
        let a = element(1, id: "row_a", label: "修復対象")
        let b = element(2, id: "row_b", label: "修復対象")
        let snap = snapshot([a, b])
        let driver = StubDriver(snap)
        let proposal = HealProposal(element: a, confidence: "high", rationale: "fm chose a")
        let executor = StepExecutor(driver: driver,
                                    delegate: ScriptedAttemptHealer(.proposed(proposal)),
                                    healingEnabled: true, isAndroid: false)
        let step = FlowStep(action: "tap", locator: FlowLocator(id: "btn_old"))
        let fp = LocatorFingerprint(type: "button", label: "修復対象", placeholder: nil)

        let outcome = await executor.execute(step, fingerprint: fp)

        XCTAssertFalse(outcome.notes.contains(.healFingerprintMatch),
                       "複数一致では指紋の注記を立ててはいけない: \(outcome.notes)")
        XCTAssertFalse(outcome.healedByFingerprint)
        // FM 側(ScriptedAttemptHealer)が実際に採用されたことで、指紋を素通りして
        // FM ヒールまで落ちたことを確認する
        guard case .healed(let locator) = outcome.status else {
            return XCTFail("FM ヒールで解決したはず: \(outcome.status)")
        }
        XCTAssertEqual(locator.id, "row_a")
    }

    /// 0件一致でも同じく FM ヒールへ委ねる(型が違う=1件も一致しない)
    func testNoFingerprintMatchFallsThroughToFM() async {
        let snap = snapshot([element(1, type: "cell", id: "btn_new", label: "修復対象")])
        let driver = StubDriver(snap)
        let target = element(1, type: "cell", id: "btn_new", label: "修復対象")
        let proposal = HealProposal(element: target, confidence: "high", rationale: "fm chose it")
        let executor = StepExecutor(driver: driver,
                                    delegate: ScriptedAttemptHealer(.proposed(proposal)),
                                    healingEnabled: true, isAndroid: false)
        let step = FlowStep(action: "tap", locator: FlowLocator(id: "btn_old"))
        // 指紋の type は "button" だが現在の要素は "cell" = 0件一致
        let fp = LocatorFingerprint(type: "button", label: "修復対象", placeholder: nil)

        let outcome = await executor.execute(step, fingerprint: fp)

        XCTAssertFalse(outcome.notes.contains(.healFingerprintMatch), "\(outcome.notes)")
        guard case .healed = outcome.status else {
            return XCTFail("0件一致は FM ヒールへ落ちるはず: \(outcome.status)")
        }
    }

    /// 指紋が一意に解決しても、この画面でその要素を一意に指せる書き方が無ければ
    /// (id 無し・ラベル無し・一意な祖先も無し)`healedStep` は立てない。だが**操作は続く**
    /// (`.passed` のまま失敗にしない)。healUnwritable も併せて立つ
    func testUnwritableFingerprintMatchDoesNotHealButStillPasses() async {
        // id もラベルも無い単独要素(SelectorNaming が書けるセレクタを一切作れない形)
        let snap = snapshot([element(1, type: "cell", id: nil, label: nil)])
        let driver = StubDriver(snap)
        let executor = StepExecutor(driver: driver, delegate: MustNotBeCalledHealer(),
                                    healingEnabled: true, isAndroid: false)
        let step = FlowStep(action: "tap", locator: FlowLocator(id: "btn_old"))
        let fp = LocatorFingerprint(type: "cell", label: nil, placeholder: nil)

        let outcome = await executor.execute(step, fingerprint: fp)

        XCTAssertTrue(outcome.notes.contains(.healFingerprintMatch), "\(outcome.notes)")
        XCTAssertTrue(outcome.notes.contains(.healUnwritable), "\(outcome.notes)")
        XCTAssertNil(outcome.healedStep, "書けないセレクタを healedStep に積んではいけない")
        XCTAssertFalse(outcome.healedByFingerprint)
        XCTAssertTrue(StepExecutor.isSuccess(outcome.status),
                      "掴めた要素があるので操作自体は続くはず: \(outcome.status)")
    }

    /// `select` は指紋照合の対象にしない(掴めないことが答えになり得るコマンドで、
    /// 別要素へ誤リダイレクトすると空のはずが値を持って返るため)。指紋が一意に解決できる
    /// 状況でも、select は空要素を返す契約のまま
    func testSelectIsNotResolvedByFingerprint() async {
        let snap = snapshot([element(1, id: "btn_new", label: "修復対象")])
        let driver = StubDriver(snap)
        let executor = StepExecutor(driver: driver, delegate: MustNotBeCalledHealer(),
                                    healingEnabled: true, isAndroid: false)
        let step = FlowStep(action: "select", locator: FlowLocator(id: "btn_old"))
        let fp = LocatorFingerprint(type: "button", label: "修復対象", placeholder: nil)

        let outcome = await executor.execute(step, fingerprint: fp)

        XCTAssertFalse(outcome.notes.contains(.healFingerprintMatch),
                       "select は指紋照合より先に空要素で返るはず: \(outcome.notes)")
        guard case .skipped = outcome.status else {
            return XCTFail("select は従来どおり skipped のはず: \(outcome.status)")
        }
    }
}
