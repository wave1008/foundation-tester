import FTCore
import XCTest

/// 一時ディレクトリだけを使う(本物の `.fleetest/` に触らない)
final class LaneFailureStreakStoreTests: XCTestCase {
    private var dir: URL!

    override func setUpWithError() throws {
        dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("lane-streak-\(UUID().uuidString)")
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: dir)
    }

    func testRoundTripAndClear() {
        let key = "android:Pixel 8 (emu):1"
        XCTAssertEqual(LaneFailureStreakStore.load(stateDir: dir, key: key), 0)
        LaneFailureStreakStore.save(stateDir: dir, key: key, consecutiveFailures: 2)
        XCTAssertEqual(LaneFailureStreakStore.load(stateDir: dir, key: key), 2)
        LaneFailureStreakStore.save(stateDir: dir, key: key, consecutiveFailures: 3)
        XCTAssertEqual(LaneFailureStreakStore.load(stateDir: dir, key: key), 3)
        LaneFailureStreakStore.clear(stateDir: dir, key: key)
        XCTAssertEqual(LaneFailureStreakStore.load(stateDir: dir, key: key), 0)
        XCTAssertFalse(FileManager.default.fileExists(
            atPath: LaneFailureStreakStore.entryURL(stateDir: dir, key: key).path))
    }

    /// 0 を書くと「0 のファイル」ではなく削除
    func testSavingZeroRemovesTheFile() {
        let key = "ios:iPhone"
        LaneFailureStreakStore.save(stateDir: dir, key: key, consecutiveFailures: 1)
        LaneFailureStreakStore.save(stateDir: dir, key: key, consecutiveFailures: 0)
        XCTAssertFalse(FileManager.default.fileExists(
            atPath: LaneFailureStreakStore.entryURL(stateDir: dir, key: key).path))
    }

    func testCorruptFileReadsAsZero() throws {
        let key = "android:emu"
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try Data("{not json".utf8).write(to: LaneFailureStreakStore.entryURL(stateDir: dir, key: key))
        XCTAssertEqual(LaneFailureStreakStore.load(stateDir: dir, key: key), 0)
        try Data("{\"consecutiveFailures\":-4,\"at\":0}".utf8)
            .write(to: LaneFailureStreakStore.entryURL(stateDir: dir, key: key))
        XCTAssertEqual(LaneFailureStreakStore.load(stateDir: dir, key: key), 0)
    }

    /// 鍵ごとに別ファイル(":" を含む鍵が潰れない)
    func testKeysDoNotCollide() {
        LaneFailureStreakStore.save(stateDir: dir, key: "android:a", consecutiveFailures: 1)
        LaneFailureStreakStore.save(stateDir: dir, key: "android_a", consecutiveFailures: 2)
        XCTAssertEqual(LaneFailureStreakStore.load(stateDir: dir, key: "android:a"), 1)
        XCTAssertEqual(LaneFailureStreakStore.load(stateDir: dir, key: "android_a"), 2)
    }
}
