import XCTest
@testable import FTCore

/// StepExecutor+Actions.swift の指紋解決(~line 730)は `hasClampedCoordinates` で除外した
/// プールを渡さないと、クランプされた幽霊要素(未実体化行が容器の原点へ積み上がったもの)へ
/// 静かに解決し得た。`candidates`(StepExecutor+Resolve.swift)が同じ除外を最後に必ず引くのと
/// 対称にする修正の回帰テスト
final class LocatorFingerprintClampedResolutionTests: XCTestCase {

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
        func triage(goal: String?, stepDescription: String, failureReason: String,
                    snapshot: SnapshotResponse?, screenshotPNG: Data?) async -> TriageInfo? { nil }
    }

    private func snapshot(_ elements: [ElementInfo]) -> SnapshotResponse {
        SnapshotResponse(sessionBundleID: nil, screen: FTRect(x: 0, y: 0, width: 400, height: 800),
                         elements: elements, truncatedCount: 0)
    }

    /// **本題**: 実体化していない行が容器の原点へクランプされ、depth が同じ 5 件が同一 frame に
    /// 重なっている(`hasClampedCoordinates` の閾値3を満たす)。そのうち1件("行 15")は
    /// type+label の raw 一致が**ちょうど1件**なので、除外せずに resolve すると指紋が
    /// この幽霊へ解決してしまう。`candidates` と同じ除外を通せば、この行は候補から落ち、
    /// FM ヒール(ここでは実在する行 "行 16" を返すよう仕込む)へ委ねられるはず
    func testFingerprintDoesNotResolveToClampedGhost() async {
        let container = ElementInfo(ref: 0, type: "other", identifier: "list_rows", label: nil,
                                    value: nil, placeholder: nil, enabled: true,
                                    frame: FTRect(x: 16, y: 270, width: 370, height: 395), depth: 0)
        let clampedFrame = FTRect(x: 16, y: 270, width: 330, height: 56)
        let clampedRows = (11...15).map { n in
            ElementInfo(ref: n, type: "cell", identifier: nil, label: "行 \(n)", value: nil,
                        placeholder: nil, enabled: true, frame: clampedFrame, depth: 1)
        }
        let realRow = ElementInfo(ref: 16, type: "cell", identifier: nil, label: "行 16", value: nil,
                                  placeholder: nil, enabled: true,
                                  frame: FTRect(x: 16, y: 326, width: 330, height: 56), depth: 1)
        let snap = snapshot([container] + clampedRows + [realRow])
        let driver = StubDriver(snap)
        let proposal = HealProposal(element: realRow, confidence: "high", rationale: "fm chose the real row")
        let executor = StepExecutor(driver: driver,
                                    delegate: ScriptedAttemptHealer(.proposed(proposal)),
                                    healingEnabled: true, isAndroid: false)
        let step = FlowStep(action: "tap", locator: FlowLocator(id: "btn_old"))
        // raw では type+label の一致がちょうど1件("行 15")だが、その要素はクランプされた幽霊
        let fp = LocatorFingerprint(type: "cell", label: "行 15", placeholder: nil)

        let outcome = await executor.execute(step, fingerprint: fp)

        XCTAssertFalse(outcome.notes.contains(.healFingerprintMatch),
                       "クランプされた幽霊要素で指紋を成立させてはいけない: \(outcome.notes)")
        XCTAssertFalse(outcome.healedByFingerprint)
        guard case .healed(let locator) = outcome.status else {
            return XCTFail("指紋が不採用になり FM ヒールへ落ちて解決したはず: \(outcome.status)")
        }
        XCTAssertEqual(locator.label, "行 16", "幽霊(行15)ではなく実在する行(行16)へ解決したはず")
    }
}
