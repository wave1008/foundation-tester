// SimulatorPosterCache: SnapshotCache.cachedb だけを消す・入れ子には降りない・
// Booted の台には撃たない(状態注入。simctl は撃たない)。

import XCTest
@testable import FTBridgeClient

final class SimulatorPosterCacheTests: XCTestCase {

    private var root: URL!

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("poster-cache-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: root)
    }

    private func write(_ text: String, at url: URL) throws {
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try text.write(to: url, atomically: true, encoding: .utf8)
    }

    /// libc の realpath(3)(Foundation の `resolvingSymlinksInPath` と違い `/var` を
    /// `/private/var` へ解決する)。パスが存在しなければ元の文字列のまま
    private static func realPath(_ url: URL) -> String {
        guard let resolved = realpath(url.path, nil) else { return url.path }
        defer { free(resolved) }
        return String(cString: resolved)
    }

    // MARK: - 削除対象の選別

    func testRemovesOnlySnapshotCacheDirectoriesAndLeavesOtherFilesAlone() throws {
        let store = root.appendingPathComponent("PRBPosterExtensionDataStore")
        let cache = store.appendingPathComponent("com.apple.PosterKit/versions/1/scratch/SnapshotCache.cachedb")
        try write("atx-bytes", at: cache.appendingPathComponent("Resources/thumb.atx"))
        let configurations = store.appendingPathComponent("configurations/config.plist")
        try write("keep-me", at: configurations)
        let descriptors = store.appendingPathComponent("descriptors/desc.plist")
        try write("keep-me-too", at: descriptors)

        let result = SimulatorPosterCache.purgeCacheDirectories(under: store)

        XCTAssertEqual(result.directoriesRemoved, 1)
        XCTAssertGreaterThan(result.bytesFreed, 0)
        XCTAssertFalse(FileManager.default.fileExists(atPath: cache.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: configurations.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: descriptors.path))
    }

    func testEmptyStoreRemovesNothing() {
        let store = root.appendingPathComponent("PRBPosterExtensionDataStore")
        try? FileManager.default.createDirectory(at: store, withIntermediateDirectories: true)
        let result = SimulatorPosterCache.purgeCacheDirectories(under: store)
        XCTAssertEqual(result.directoriesRemoved, 0)
        XCTAssertEqual(result.bytesFreed, 0)
    }

    func testMissingStoreRemovesNothing() {
        let result = SimulatorPosterCache.purgeCacheDirectories(
            under: root.appendingPathComponent("does-not-exist"))
        XCTAssertEqual(result.directoriesRemoved, 0)
        XCTAssertEqual(result.bytesFreed, 0)
    }

    /// 入れ子の同名ディレクトリの中へは降りない —— 外側の1個を丸ごと消すだけ
    func testDoesNotDescendIntoNestedSnapshotCacheDirectories() throws {
        let store = root.appendingPathComponent("PRBPosterExtensionDataStore")
        let outer = store.appendingPathComponent("versions/1/scratch/SnapshotCache.cachedb")
        try write("outer", at: outer.appendingPathComponent("thumb.atx"))
        let inner = outer.appendingPathComponent("nested/SnapshotCache.cachedb")
        try write("inner", at: inner.appendingPathComponent("thumb.atx"))

        let found = SimulatorPosterCache.findSnapshotCacheDirectories(under: store)

        // 生の realpath(3) で比べる —— Foundation の `resolvingSymlinksInPath` は `/var`→`/private/var`
        // を意図的に解決しない(Apple の特別扱い)が、`FileManager.contentsOfDirectory` が返す
        // 実エントリの URL は解決済みなので、素朴な文字列比較(`.path` 同士)は食い違う
        XCTAssertEqual(found.map(Self.realPath), [Self.realPath(outer)])
    }

    /// dryRun は数えるだけで1バイトも消さない
    func testDryRunCountsWithoutDeleting() throws {
        let store = root.appendingPathComponent("PRBPosterExtensionDataStore")
        let cache = store.appendingPathComponent("versions/1/scratch/SnapshotCache.cachedb")
        try write("atx-bytes", at: cache.appendingPathComponent("thumb.atx"))

        let result = SimulatorPosterCache.purgeCacheDirectories(under: store, dryRun: true)

        XCTAssertEqual(result.directoriesRemoved, 1)
        XCTAssertGreaterThan(result.bytesFreed, 0)
        XCTAssertTrue(FileManager.default.fileExists(atPath: cache.path), "dry run は消してはいけない")
    }

    // MARK: - Booted の台には撃たない(状態注入)

    func testShouldPurgeOnlyWhenStopped() {
        XCTAssertTrue(SimulatorPosterCache.shouldPurge(observation: .stopped))
        XCTAssertFalse(SimulatorPosterCache.shouldPurge(observation: .stillBooted))
        XCTAssertFalse(SimulatorPosterCache.shouldPurge(observation: .unreadable("boom")))
    }

    func testBootedSimulatorIsSkippedEntirely() throws {
        let cache = SimulatorPosterCache.posterStoreDirectory(udid: "FAKE-UDID", home: root)
            .appendingPathComponent("versions/1/scratch/SnapshotCache.cachedb")
        try write("atx-bytes", at: cache.appendingPathComponent("thumb.atx"))

        let result = SimulatorPosterCache.purge(
            observation: .stillBooted, udid: "FAKE-UDID", home: root)

        XCTAssertTrue(result.skippedBooted)
        XCTAssertEqual(result.directoriesRemoved, 0)
        XCTAssertTrue(FileManager.default.fileExists(atPath: cache.path), "Booted の台を消してはいけない")
    }

    func testUnreadableStateIsSkippedTheSameAsBooted() {
        let result = SimulatorPosterCache.purge(
            observation: .unreadable("simctl list failed"), udid: "FAKE-UDID", home: root)
        XCTAssertTrue(result.skippedBooted)
        XCTAssertEqual(result.directoriesRemoved, 0)
    }

    func testStoppedSimulatorIsPurgedViaTheUDIDPath() throws {
        let cache = SimulatorPosterCache.posterStoreDirectory(udid: "FAKE-UDID", home: root)
            .appendingPathComponent("versions/1/scratch/SnapshotCache.cachedb")
        try write("atx-bytes", at: cache.appendingPathComponent("thumb.atx"))

        let result = SimulatorPosterCache.purge(
            observation: .stopped, udid: "FAKE-UDID", logOnRemoval: false, home: root)

        XCTAssertFalse(result.skippedBooted)
        XCTAssertEqual(result.directoriesRemoved, 1)
        XCTAssertFalse(FileManager.default.fileExists(atPath: cache.path))
        // 起動の直前(既定)は容量を数えない(全ファイルをもう一周なめて供給を遅らせない)
        XCTAssertEqual(result.bytesFreed, 0)
    }

    func testMeasureBytesIsOnlyForTheManualClean() throws {
        let cache = SimulatorPosterCache.posterStoreDirectory(udid: "FAKE-UDID", home: root)
            .appendingPathComponent("versions/1/scratch/SnapshotCache.cachedb")
        try write("atx-bytes", at: cache.appendingPathComponent("thumb.atx"))

        let result = SimulatorPosterCache.purge(
            observation: .stopped, udid: "FAKE-UDID", logOnRemoval: false, measureBytes: true, home: root)

        XCTAssertEqual(result.directoriesRemoved, 1)
        XCTAssertGreaterThan(result.bytesFreed, 0)
    }

    func testPosterStoreDirectoryPath() {
        let url = SimulatorPosterCache.posterStoreDirectory(udid: "ABCD", home: root)
        XCTAssertEqual(url.path, root.appendingPathComponent(
            "Library/Developer/CoreSimulator/Devices/ABCD/data/Library/Application Support"
                + "/PRBPosterExtensionDataStore").path)
    }
}
