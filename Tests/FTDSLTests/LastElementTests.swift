import XCTest

@testable import FTDSL
import FTCore

/// 暗黙の要素保持(`lastElement`)。**どのコマンドが差し替えるか**と**いつ空になるか**を実行して固定する。
/// ここがズレると「別の要素の値を今掴んだものとして読む」= 失敗が沈黙する形になり、
/// レポートは緑のまま嘘の値で通る(値の凍結そのものは承認済みの仕様。docs/commands.md)。
final class LastElementTests: XCTestCase {

    /// 属性の違う2要素(掴み直しで差し替わったことを id で見分けるため)
    private final class TwoElementDriver: AppDriver {
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
                elements: [
                    ElementInfo(ref: 1, type: "staticText", identifier: "total",
                                label: "合計 1,200 円", value: "2026/07/30",
                                placeholder: nil, enabled: true,
                                frame: FTRect(x: 0, y: 0, width: 100, height: 20), depth: 0),
                    ElementInfo(ref: 2, type: "button", identifier: "order",
                                label: "注文する", value: nil,
                                placeholder: nil, enabled: true,
                                frame: FTRect(x: 0, y: 100, width: 100, height: 20), depth: 0),
                ],
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

    private func makeCore() -> FTDriveCore {
        FTDriveCore(driver: TwoElementDriver(), platform: "ios", app: "com.example.app",
                    scenarioID: "T.S0010", scenarioTitle: "t",
                    delegate: nil, healingEnabled: false, dryRun: false,
                    healCacheURL: URL(fileURLWithPath: NSTemporaryDirectory())
                        .appendingPathComponent("ft-last-element-test.json"),
                    emit: { _ in })
    }

    /// scene 1本ぶんを走らせる(section は action = XCTestCase.expectation との名前衝突を避ける)
    @discardableResult
    private func run(_ body: @escaping () -> Void) -> FTDriveCore {
        let core = makeCore()
        FTRuntime.bootstrap(core: core, dslThread: Thread.current)
        defer { FTRuntime.tearDown() }
        scenario { scene(1, "s") { action { body() } } }
        return core
    }

    // MARK: - 差し替える / 差し替えない

    func testSelectHoldsTheGrabbedElement() {
        var held: FTElement!
        run {
            select("#total")
            held = lastElement
        }
        XCTAssertEqual(held.id, "total")
        XCTAssertEqual(held.text, "合計 1,200 円")
        XCTAssertEqual(held.value, "2026/07/30")
    }

    /// 操作コマンド(tap)も掴んだ要素を差し替える。exist だけだと「検証しないと持てない」形になる
    func testOperationCommandsReplaceTheHeldElement() {
        var held: FTElement!
        run {
            select("#total")
            tap("#order")
            held = lastElement
        }
        XCTAssertEqual(held.id, "order", "tap が掴んだ要素に差し替わっていない")
    }

    /// 掴めなかったコマンドは**空で上書きする**。前の要素が残ると、別要素の値を
    /// 「今掴んだもの」として読んでしまう(この検査が本命)
    func testFailedGrabClearsTheHeldElement() {
        var held: FTElement!
        run {
            select("#total")
            select("#missing", timeout: 0)
            held = lastElement
        }
        XCTAssertTrue(held.isEmpty, "掴めなかったのに前の要素が残っている: \(held.id ?? "-")")
        XCTAssertNil(held.text)
    }

    /// 要素を1つに定めないコマンド(不在・個数)は差し替えない
    func testNegativeChecksDoNotReplaceTheHeldElement() {
        var afterNotExist: FTElement!
        var afterCountIs: FTElement!
        run {
            select("#total")
            notExist("#missing", timeout: 0)
            afterNotExist = lastElement
            countIs("#missing", 0, timeout: 0)
            afterCountIs = lastElement
        }
        XCTAssertEqual(afterNotExist.id, "total", "notExist が保持要素を消している")
        XCTAssertEqual(afterCountIs.id, "total", "countIs が保持要素を消している")
    }

    /// セレクタを取らないコマンドも差し替えない(掴んだ要素は swipe を跨いで残る)
    func testCommandsWithoutASelectorDoNotReplaceTheHeldElement() {
        var held: FTElement!
        run {
            select("#total")
            swipe(.up)
            held = lastElement
        }
        XCTAssertEqual(held.id, "total")
    }

    // MARK: - 空になる条件

    /// scene を跨いだら捨てる(前の画面の要素を読むのは事故)
    func testHeldElementIsClearedBetweenScenes() {
        var held: FTElement!
        let core = makeCore()
        FTRuntime.bootstrap(core: core, dslThread: Thread.current)
        defer { FTRuntime.tearDown() }
        scenario {
            scene(1, "掴む") { action { select("#total") } }
            scene(2, "次の画面") { action { held = lastElement } }
        }
        XCTAssertTrue(held.isEmpty, "scene を跨いで前の要素が残っている: \(held.id ?? "-")")
    }

    /// 一度も掴んでいないなら空 + 警告(黙って空を返すと「掴んだが空だった」と区別できない)
    func testReadingBeforeAnyGrabWarns() {
        var held: FTElement!
        let core = run { held = lastElement }
        XCTAssertTrue(held.isEmpty)
        let messages = core.finalRecord.fixSuggestions.map(\.message)
        XCTAssertTrue(messages.contains { $0.contains("lastElement was read before") },
                      "警告が出ていない: \(messages)")
    }

    /// 空の保持要素にチェーンした検証は落ちる(存在しないセレクタを持たせてあるため)
    func testChainingOnAnEmptyHeldElementFails() {
        let core = run { lastElement.textIs("合計 1,200 円", timeout: 0) }
        let steps = core.finalRecord.scenes.flatMap(\.steps)
        guard case .failed = steps.last?.status else {
            return XCTFail("空の lastElement へのチェーンが通ってしまった: \(steps.map(\.description))")
        }
    }
}
