import XCTest
@testable import FTDSL
import FTCore

/// `withoutContainerInference { }` の土台(`FTDriveCore.effectiveContainerInference` /
/// `runWithContainerInference`)の純粋ロジック。**FlowStep へ実際に埋め込まれる経路**
/// (`tapImpl`/`scrollToImpl`/`FTDriveCore.perform` の入口)は、どれもこの2関数への1行の委譲で
/// 分岐を持たないため、ここでの検証で足りると判断した(FlowStep.containerInference 自体は
/// StepResult に残らず、DSL 経由での観測に別の仕組みが要るため。詳細は報告参照)。
final class ContainerInferenceScopeTests: XCTestCase {

    /// FTDriveCore を作るだけの最小ドライバ(このテストではデバイス操作を一切発火しない)
    private final class StubDriver: AppDriver {
        func status() async throws -> StatusResponse {
            StatusResponse(ready: true, device: "stub", osVersion: "-", sessionBundleID: nil)
        }
        func install(packagePath: String) async throws {}
        func uninstall(bundleID: String) async throws {}
        func isAppForeground(bundleID: String) async throws -> Bool { false }
        func foregroundAppID() async throws -> String? { nil }
        func launch(bundleID: String) async throws {}
        func snapshot() async throws -> SnapshotResponse {
            SnapshotResponse(sessionBundleID: nil,
                             screen: FTRect(x: 0, y: 0, width: 400, height: 800),
                             elements: [], truncatedCount: 0)
        }
        func tap(ref: Int) async throws {}
        func tap(x: Double, y: Double) async throws {}
        func type(ref: Int?, text: String) async throws {}
        func swipe(_ direction: FTSwipeDirection) async throws {}
        func press(ref: Int, duration: Double) async throws {}
        func screenshot() async throws -> Data { Data() }
        func terminate() async throws {}
    }

    private func makeCore() -> FTDriveCore {
        FTDriveCore(driver: StubDriver(), platform: "ios", app: "com.example.app",
                    scenarioID: "T.S0010", scenarioTitle: "t",
                    delegate: nil, healingEnabled: false, dryRun: true,
                    healCacheURL: URL(fileURLWithPath: NSTemporaryDirectory())
                        .appendingPathComponent("ft-container-inference-test.json"),
                    emit: { _ in })
    }

    /// 既定(明示引数なし・ブロックの外)は nil のまま = 実行プロファイル既定に委ねる
    func testDefaultDefersToProfile() {
        let core = makeCore()
        XCTAssertNil(core.effectiveContainerInference(nil))
    }

    /// ブロックの文脈(`withoutContainerInference` 相当の false)が既定より優先される
    func testBlockContextAppliesInsideAndClearsAfter() {
        let core = makeCore()
        core.runWithContainerInference(false) {
            XCTAssertEqual(core.effectiveContainerInference(nil), false)
        }
        XCTAssertNil(core.effectiveContainerInference(nil), "ブロックを抜けたら文脈は残らない")
    }

    /// 明示引数(`tap(..., containerInference: true)` 相当)はブロックの文脈より優先される
    func testExplicitArgumentOverridesBlockContext() {
        let core = makeCore()
        core.runWithContainerInference(false) {
            XCTAssertEqual(core.effectiveContainerInference(true), true)
        }
    }

    /// ネストしたブロックは内側が優先し、抜けると外側の文脈に戻る(runWithScrollContext と同じスタック規律)
    func testNestedBlocksRestorePreviousContext() {
        let core = makeCore()
        core.runWithContainerInference(false) {
            XCTAssertEqual(core.effectiveContainerInference(nil), false)
            core.runWithContainerInference(true) {
                XCTAssertEqual(core.effectiveContainerInference(nil), true)
            }
            XCTAssertEqual(core.effectiveContainerInference(nil), false,
                           "内側のブロックを抜けたら外側の文脈に戻ること")
        }
        XCTAssertNil(core.effectiveContainerInference(nil))
    }

    /// `withoutContainerInference { }` の DSL 経由の呼び出しがスタックを正しく積み降ろしすること
    /// (FTRuntime.bootstrap 経由。ブロック内で直接 core を読み、抜けた後に元へ戻ることも確認)
    func testWithoutContainerInferenceDSLPushesAndPops() {
        let core = makeCore()
        FTRuntime.bootstrap(core: core, dslThread: Thread.current)
        defer { FTRuntime.tearDown() }

        var insideValue: Bool?
        scenario {
            scene(1, "s") {
                action {
                    withoutContainerInference {
                        insideValue = core.effectiveContainerInference(nil)
                    }
                }
            }
        }

        XCTAssertEqual(insideValue, false)
        XCTAssertNil(core.effectiveContainerInference(nil), "ブロックを抜けたら文脈は残らない")
    }
}
