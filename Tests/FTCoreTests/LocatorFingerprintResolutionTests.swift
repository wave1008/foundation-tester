import XCTest
@testable import FTCore

/// `StepExecutor+Actions.swift` の解決分岐にあるロケータ指紋の階層(select の特例の後)を、
/// `executor.execute(step, fingerprint:)` 経由で end-to-end に確かめる。プライマリ/フォールバックが
/// どちらも解決できない失敗経路だけで効く機構なので、ここでは常にプライマリが解決できない
/// `FlowLocator` を渡す。
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
    /// 立って `.healed` になる
    func testUniqueFingerprintMatchHeals() async {
        let snap = snapshot([element(1, id: "btn_new", label: "修復対象")])
        let driver = StubDriver(snap)
        let executor = StepExecutor(driver: driver, healingEnabled: true, isAndroid: false)
        let step = FlowStep(action: "tap", locator: FlowLocator(id: "btn_old"))
        let fp = LocatorFingerprint(type: "button", label: "修復対象", placeholder: nil)

        let outcome = await executor.execute(step, fingerprint: fp)

        XCTAssertTrue(outcome.notes.contains(.healFingerprintMatch), "\(outcome.notes)")
        XCTAssertTrue(outcome.healedByFingerprint)
        guard case .healed(let locator) = outcome.status else {
            return XCTFail("一意な指紋一致は healed のはず: \(outcome.status)")
        }
        XCTAssertEqual(locator.id, "btn_new")
        XCTAssertEqual(outcome.healedStep?.locator?.id, "btn_new")
    }

    /// **最重要の陰性テスト**: 型+ラベルが同じ要素が2つあるとき、指紋は不採用(別要素へ静かに
    /// 解決してはいけない)で、ロケータ未解決の失敗になる。「常に解決する」変異はここで落ちる
    func testAmbiguousFingerprintIsNotAdopted() async {
        let snap = snapshot([element(1, id: "row_a", label: "修復対象"),
                             element(2, id: "row_b", label: "修復対象")])
        let executor = StepExecutor(driver: StubDriver(snap), healingEnabled: true, isAndroid: false)
        let step = FlowStep(action: "tap", locator: FlowLocator(id: "btn_old"))
        let fp = LocatorFingerprint(type: "button", label: "修復対象", placeholder: nil)

        let outcome = await executor.execute(step, fingerprint: fp)

        XCTAssertFalse(outcome.notes.contains(.healFingerprintMatch),
                       "複数一致では指紋の注記を立ててはいけない: \(outcome.notes)")
        XCTAssertFalse(outcome.healedByFingerprint)
        guard case .failed = outcome.status else {
            return XCTFail("複数一致はロケータ未解決の失敗のはず: \(outcome.status)")
        }
    }

    /// 0件一致でも同じく不採用(型が違う=1件も一致しない)
    func testNoFingerprintMatchIsNotAdopted() async {
        let snap = snapshot([element(1, type: "cell", id: "btn_new", label: "修復対象")])
        let executor = StepExecutor(driver: StubDriver(snap), healingEnabled: true, isAndroid: false)
        let step = FlowStep(action: "tap", locator: FlowLocator(id: "btn_old"))
        // 指紋の type は "button" だが現在の要素は "cell" = 0件一致
        let fp = LocatorFingerprint(type: "button", label: "修復対象", placeholder: nil)

        let outcome = await executor.execute(step, fingerprint: fp)

        XCTAssertFalse(outcome.notes.contains(.healFingerprintMatch), "\(outcome.notes)")
        guard case .failed = outcome.status else {
            return XCTFail("0件一致はロケータ未解決の失敗のはず: \(outcome.status)")
        }
    }

    /// 指紋が一意に解決しても、この画面でその要素を一意に指せる書き方が無ければ
    /// (id 無し・ラベル無し・一意な祖先も無し)`healedStep` は立てない。だが**操作は続く**
    /// (`.passed` のまま失敗にしない)。healUnwritable も併せて立つ
    func testUnwritableFingerprintMatchDoesNotHealButStillPasses() async {
        // id もラベルも無く placeholder だけを持つ入力欄(指紋は名指しになるが、SelectorNaming は
        // placeholder を候補にしないので書けるセレクタを作れない形)
        let field = ElementInfo(ref: 1, type: "textField", identifier: nil, label: nil, value: nil,
                                placeholder: "検索", enabled: true,
                                frame: FTRect(x: 0, y: 0, width: 100, height: 40), depth: 0)
        let snap = snapshot([field])
        let driver = StubDriver(snap)
        let executor = StepExecutor(driver: driver, healingEnabled: true, isAndroid: false)
        let step = FlowStep(action: "tap", locator: FlowLocator(id: "btn_old"))
        let fp = LocatorFingerprint(type: "textField", label: nil, placeholder: "検索")

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
        let executor = StepExecutor(driver: driver, healingEnabled: true, isAndroid: false)
        let step = FlowStep(action: "select", locator: FlowLocator(id: "btn_old"))
        let fp = LocatorFingerprint(type: "button", label: "修復対象", placeholder: nil)

        let outcome = await executor.execute(step, fingerprint: fp)

        XCTAssertFalse(outcome.notes.contains(.healFingerprintMatch),
                       "select は指紋照合より先に空要素で返るはず: \(outcome.notes)")
        guard case .skipped = outcome.status else {
            return XCTFail("select は従来どおり skipped のはず: \(outcome.status)")
        }
    }

    /// **`heal=false` は指紋照合(= 自己修復)を止める**。指紋が一意に解決できる画面でも
    /// 注記を立てず、ロケータ未解決の失敗のまま返す。対になる陽性は
    /// `testUniqueFingerprintMatchHeals`(同じ画面・同じ指紋で healingEnabled=true)
    func testHealingDisabledIgnoresFingerprint() async {
        let snap = snapshot([element(1, id: "btn_new", label: "修復対象")])
        let executor = StepExecutor(driver: StubDriver(snap), healingEnabled: false, isAndroid: false)
        let step = FlowStep(action: "tap", locator: FlowLocator(id: "btn_old"))
        let fp = LocatorFingerprint(type: "button", label: "修復対象", placeholder: nil)

        let outcome = await executor.execute(step, fingerprint: fp)

        XCTAssertFalse(outcome.notes.contains(.healFingerprintMatch), "\(outcome.notes)")
        XCTAssertFalse(outcome.healedByFingerprint)
        XCTAssertNil(outcome.healedStep)
        guard case .failed = outcome.status else {
            return XCTFail("heal=false では指紋で解決せず失敗のはず: \(outcome.status)")
        }
    }
}
