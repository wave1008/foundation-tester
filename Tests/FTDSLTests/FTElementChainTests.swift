import XCTest

@testable import FTDSL
import FTCore

/// `exist` の戻り値へのチェーン。**自由関数と同じ assert に繋がっていること**を実行して固定する。
/// 「どれがチェーンできるか」の網羅は vscode-ftester/test/ftElementChainSync.test.mjs が見張るが、
/// そちらはソースの形しか見ないので、**繋ぎ先を取り違えても気付けない**(textContains が
/// textStartsWith を呼んでいても網羅としては成立してしまう)。ここは実際に判定させて分ける。
final class FTElementChainTests: XCTestCase {

    /// 検証の材料になる属性を一通り持つ 1 要素だけを返す
    private final class ElementDriver: AppDriver {
        func status() async throws -> StatusResponse {
            StatusResponse(ready: true, device: "stub", osVersion: "-", sessionBundleID: nil)
        }
        func install(packagePath: String) async throws {}
        func uninstall(bundleID: String) async throws {}
        func isAppForeground(bundleID: String) async throws -> Bool { false }
        func foregroundAppID() async throws -> String? { nil }
        func launch(bundleID: String) async throws {}
        func snapshot() async throws -> SnapshotResponse {
            SnapshotResponse(
                sessionBundleID: nil,
                screen: FTRect(x: 0, y: 0, width: 400, height: 800),
                elements: [ElementInfo(ref: 1, type: "staticText", identifier: "total",
                                       label: "合計 1,200 円", value: "2026/07/30",
                                       placeholder: nil, enabled: true,
                                       frame: FTRect(x: 0, y: 0, width: 10, height: 10), depth: 0)],
                truncatedCount: 0)
        }
        func tap(ref: Int) async throws {}
        func tap(x: Double, y: Double) async throws {}
        func type(ref: Int?, text: String) async throws {}
        func swipe(_ direction: FTSwipeDirection) async throws {}
        func press(ref: Int, duration: Double) async throws {}
        func screenshot() async throws -> Data { Data() }
        func terminate() async throws {}
    }

    private func makeCore(driver: AppDriver) -> FTDriveCore {
        FTDriveCore(driver: driver, platform: "ios", app: "com.example.app",
                    scenarioID: "T.S0010", scenarioTitle: "t",
                    delegate: nil, healingEnabled: false, dryRun: false,
                    healCacheURL: URL(fileURLWithPath: NSTemporaryDirectory())
                        .appendingPathComponent("ft-chain-test.json"),
                    emit: { _ in })
    }

    private func run(_ body: () -> Void) -> FTDriveCore {
        let core = makeCore(driver: ElementDriver())
        FTRuntime.bootstrap(core: core, dslThread: Thread.current)
        defer { FTRuntime.tearDown() }
        // section は action にする(XCTestCase.expectation(description:) と名前が衝突するため。
        // 検証内容には影響しない)
        scenario { scene(1, "s") { action { body() } } }
        return core
    }

    private func steps(_ core: FTDriveCore) -> [DSLStepRecord] {
        core.finalRecord.scenes.flatMap(\.steps)
    }

    /// 全チェーンを一続きに通す。1つでも別の assert へ繋がっていれば材料に合わず落ちる
    func testEveryChainedAssertionResolvesToItsOwnCheck() {
        let core = run {
            exist("#total")
                .textIs("合計 1,200 円")
                .textContains("1,200")
                .textStartsWith("合計")
                .textEndsWith("円")
                .textMatches("[0-9,]+ 円$")
                .textIsNot("合計 0 円")
                .textContainsNot("税込")
                .textStartsWithNot("小計")
                .textEndsWithNot("ドル")
                .textMatchesNot("^[0-9]+$")
                .textIsNotEmpty()
                .valueIs("2026/07/30")
                .valueContains("07")
                .valueStartsWith("2026")
                .valueEndsWith("30")
                .valueMatches("^[0-9]{4}/")
                .valueMatchesDateFormat("yyyy/MM/dd")
                .valueIsNot("2025/01/01")
                .valueContainsNot("1999")
                .valueStartsWithNot("1999")
                .valueEndsWithNot("01")
                .valueMatchesNot("^[a-z]+$")
                .valueIsNotEmpty()
                .enabledIsTrue()
                .checkIsOFF()
                .idIs("total")
        }
        let recorded = steps(core)
        XCTAssertEqual(recorded.count, 1 + 26, "exist + チェーン26本ぶんのステップが記録されるはず")
        for step in recorded {
            if case .failed(let reason) = step.status {
                XCTFail("\(step.description) が落ちた: \(reason)")
            }
        }
    }

    /// チェーンは**掴んだ要素**を検証する: 期待に合わなければその1件だけが落ちる
    /// (通してしまうと「何を書いても緑」になり、チェーンが飾りになる)
    func testChainedAssertionFailsOnMismatch() {
        // timeout を詰める(既定 5 秒ぶん変化を待ってから落ちるため)
        let core = run { exist("#total").textContains("送料", timeout: 0.2) }
        guard case .failed = steps(core).last?.status else {
            return XCTFail("合致しない textContains が通ってしまった: \(steps(core).map(\.description))")
        }
    }

    /// 値の読み出し(.text/.value/.id)はチェーンを跨いでも最初の exist の値のまま
    func testMatchedValuesSurviveChaining() {
        var element: FTElement!
        _ = run { element = exist("#total").textIs("合計 1,200 円").textIsNotEmpty() }
        XCTAssertEqual(element.text, "合計 1,200 円")
        XCTAssertEqual(element.value, "2026/07/30")
        XCTAssertEqual(element.id, "total")
    }
}
