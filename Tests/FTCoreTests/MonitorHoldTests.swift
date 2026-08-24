// `ftester monitor pause` の保持ファイル(FTCore.MonitorHold)。
// 期限の判定・冪等な解除・ファイル破損時の安全側(hold 無し扱い)を固定する。
// 既定パスはホスト共有なので使わない(テストは一時ディレクトリへ隔離)。

import XCTest
@testable import FTCore

final class MonitorHoldTests: XCTestCase {
    private var dir: URL!

    override func setUpWithError() throws {
        dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("ft-monitor-hold-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: dir)
    }

    func testUnlimitedHoldStaysActiveUntilCleared() throws {
        let hold = MonitorHold(until: nil, startedAt: 0)
        try MonitorHold.save(hold, stateDir: dir)
        XCTAssertEqual(MonitorHold.load(stateDir: dir)?.isActive(
            now: Date(timeIntervalSince1970: 1e12)), true)
        XCTAssertTrue(MonitorHold.clear(stateDir: dir))
        XCTAssertNil(MonitorHold.load(stateDir: dir))
    }

    func testTimedHoldExpiresOnItsOwn() throws {
        let hold = MonitorHold(until: 1000, startedAt: 0)
        try MonitorHold.save(hold, stateDir: dir)
        let loaded = try XCTUnwrap(MonitorHold.load(stateDir: dir))
        XCTAssertTrue(loaded.isActive(now: Date(timeIntervalSince1970: 999)))
        XCTAssertFalse(loaded.isActive(now: Date(timeIntervalSince1970: 1000)))
    }

    // 解除は冪等(ファイルが無くても成功)。戻り値は「消す前に active だったか」——
    // 期限切れのファイルを消しても false(status 表示が「解除した」と嘘をつかない)
    func testClearIsIdempotentAndReportsExpiredAsInactive() throws {
        XCTAssertFalse(MonitorHold.clear(stateDir: dir))
        try MonitorHold.save(MonitorHold(until: 1, startedAt: 0), stateDir: dir)
        XCTAssertFalse(MonitorHold.clear(stateDir: dir, now: Date(timeIntervalSince1970: 10)))
    }

    // 壊れたファイルは「hold 無し」に倒す(モニターが読めないゴミで永久停止しない)
    func testCorruptFileMeansNoHold() throws {
        try Data("not json".utf8).write(to: MonitorHold.url(stateDir: dir))
        XCTAssertNil(MonitorHold.load(stateDir: dir))
    }
}
