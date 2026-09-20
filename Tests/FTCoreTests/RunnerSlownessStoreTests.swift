import XCTest
@testable import FTCore

/// XCUITest ランナーの劣化が run をまたいで放置される問題に対する印(RunnerSlownessStore)。
/// DeviceFrozenStore と同じ棚(.fleetest/)・同じキー体系(UDID)だが、鮮度(pid 生存・mtime)は
/// 持たない(この印は特定の観測者に紐付かない「その台の実測結果」なので)。
final class RunnerSlownessStoreTests: XCTestCase {
    private var stateDir: URL!

    override func setUpWithError() throws {
        stateDir = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("ft-runner-slowness-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: stateDir, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: stateDir)
    }

    /// 変異①「印が永続しない」の陽性対照: mark→current が値を返さなければここが落ちる
    func testMarkThenRead() {
        XCTAssertNil(RunnerSlownessStore.current(stateDir: stateDir, key: "udid-a"))
        RunnerSlownessStore.mark(stateDir: stateDir, key: "udid-a", state: .runnerRestartDidNotHelp)
        XCTAssertEqual(RunnerSlownessStore.current(stateDir: stateDir, key: "udid-a"), .runnerRestartDidNotHelp)
    }

    /// **プロセスを跨いで残る**ことの直接的な確認: 新しい呼び出し(別の Entry の読み)でも同じ値が読める
    /// (プロセス内メモリに頼っていない = ファイルだけが正)
    func testEntryIsReadableAcrossFreshReads() {
        RunnerSlownessStore.mark(stateDir: stateDir, key: "udid-a", state: .simulatorRestartDidNotHelp)
        // 別の読み(同じファイルを毎回読み直すだけの単純な API なので、プロセスを跨いだ読みを模する)
        XCTAssertEqual(RunnerSlownessStore.current(stateDir: stateDir, key: "udid-a"), .simulatorRestartDidNotHelp)
        XCTAssertTrue(FileManager.default.fileExists(
            atPath: RunnerSlownessStore.entryURL(stateDir: stateDir, key: "udid-a").path))
    }

    /// 段階の上書き(runnerRestartDidNotHelp → simulatorRestartDidNotHelp)
    func testMarkOverwritesThePreviousState() {
        RunnerSlownessStore.mark(stateDir: stateDir, key: "udid-a", state: .runnerRestartDidNotHelp)
        RunnerSlownessStore.mark(stateDir: stateDir, key: "udid-a", state: .simulatorRestartDidNotHelp)
        XCTAssertEqual(RunnerSlownessStore.current(stateDir: stateDir, key: "udid-a"), .simulatorRestartDidNotHelp)
    }

    func testClearRemovesTheEntry() {
        RunnerSlownessStore.mark(stateDir: stateDir, key: "udid-a", state: .runnerRestartDidNotHelp)
        RunnerSlownessStore.clear(stateDir: stateDir, key: "udid-a")
        XCTAssertNil(RunnerSlownessStore.current(stateDir: stateDir, key: "udid-a"))
    }

    func testUnknownKeyIsNil() {
        XCTAssertNil(RunnerSlownessStore.current(stateDir: stateDir, key: "udid-missing"))
    }

    /// 別の台には及ばない(キーごとに独立)
    func testDoesNotLeakAcrossKeys() {
        RunnerSlownessStore.mark(stateDir: stateDir, key: "udid-a", state: .runnerRestartDidNotHelp)
        XCTAssertNil(RunnerSlownessStore.current(stateDir: stateDir, key: "udid-b"))
    }
}
