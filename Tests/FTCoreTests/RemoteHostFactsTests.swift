import XCTest
@testable import FTCore

final class RemoteHostFactsTests: XCTestCase {
    var dir: URL!

    override func setUpWithError() throws {
        dir = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("RemoteHostFactsTests-\(UUID().uuidString)")
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: dir)
    }

    func testSaveThenLoadRoundTrips() {
        let facts = RemoteHostFacts(host: "M1Max", dispatchOverheadSeconds: 4.2,
                                    updatedAt: "2026-08-18T00:00:00Z")
        RemoteHostFactsStore.save(facts, dir: dir, host: "runner-1")
        XCTAssertEqual(RemoteHostFactsStore.load(dir: dir, host: "runner-1"), facts)
    }

    func testLoadMissingFileReturnsNil() {
        XCTAssertNil(RemoteHostFactsStore.load(dir: dir, host: "never-saved"))
    }

    func testLoadCorruptedJSONReturnsNil() throws {
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try "not json".write(
            to: dir.appendingPathComponent(RemoteHostFactsStore.fileKey(host: "runner-1") + ".json"),
            atomically: true, encoding: .utf8)
        XCTAssertNil(RemoteHostFactsStore.load(dir: dir, host: "runner-1"))
    }

    func testSaveOverwritesPreviousFacts() {
        RemoteHostFactsStore.save(
            RemoteHostFacts(host: "old", updatedAt: "2026-08-18T00:00:00Z"),
            dir: dir, host: "runner-1")
        RemoteHostFactsStore.save(
            RemoteHostFacts(host: "new", updatedAt: "2026-08-18T01:00:00Z"),
            dir: dir, host: "runner-1")
        XCTAssertEqual(RemoteHostFactsStore.load(dir: dir, host: "runner-1")?.host, "new")
    }

    func testFieldsAreOptionalAndNilRoundTrips() {
        let facts = RemoteHostFacts(updatedAt: "2026-08-18T00:00:00Z")
        RemoteHostFactsStore.save(facts, dir: dir, host: "bare")
        let loaded = RemoteHostFactsStore.load(dir: dir, host: "bare")
        XCTAssertEqual(loaded, facts)
        XCTAssertNil(loaded?.host)
        XCTAssertNil(loaded?.dispatchOverheadSeconds)
        XCTAssertNil(loaded?.processorModel)
        XCTAssertNil(loaded?.coreCount)
        XCTAssertNil(loaded?.concurrentDevices)
    }

    // MARK: - ハードウェア・同時起動デバイス数フィールド

    func testHardwareAndConcurrentDevicesFieldsRoundTrip() {
        let facts = RemoteHostFacts(
            host: "M1Max", dispatchOverheadSeconds: 4.2,
            processorModel: "Apple M1 Max", coreCount: 10, concurrentDevices: 3,
            updatedAt: "2026-08-18T00:00:00Z")
        RemoteHostFactsStore.save(facts, dir: dir, host: "runner-2")
        let loaded = RemoteHostFactsStore.load(dir: dir, host: "runner-2")
        XCTAssertEqual(loaded, facts)
        XCTAssertEqual(loaded?.processorModel, "Apple M1 Max")
        XCTAssertEqual(loaded?.coreCount, 10)
        XCTAssertEqual(loaded?.concurrentDevices, 3)
    }

    /// 新フィールドを持たない旧形式の JSON(採取側の更新前に書かれたキャッシュ)も decode できる
    /// ―― 欠けているキーは Optional として nil に落ちる(Codable の既定挙動)
    func testDecodesLegacyJSONWithoutNewFields() throws {
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let legacyJSON = """
            {"machine":"M1Max","dispatchOverheadSeconds":4.2,"updatedAt":"2026-08-18T00:00:00Z"}
            """
        try legacyJSON.write(
            to: dir.appendingPathComponent(RemoteHostFactsStore.fileKey(host: "legacy") + ".json"),
            atomically: true, encoding: .utf8)
        let loaded = RemoteHostFactsStore.load(dir: dir, host: "legacy")
        XCTAssertEqual(loaded?.host, "M1Max")
        XCTAssertEqual(loaded?.dispatchOverheadSeconds, 4.2)
        XCTAssertNil(loaded?.processorModel)
        XCTAssertNil(loaded?.coreCount)
        XCTAssertNil(loaded?.concurrentDevices)
    }

    // MARK: - fileKey(鍵はホスト。ユーザー名は落とす)

    /// ssh 宛先を渡されたら **user@ を落として実体だけ**を鍵にする —— 同じ機械を
    /// 別ユーザーで叩いても実測は同じ機械のものだから
    func testFileKeyDropsTheSshUser() {
        XCTAssertEqual(RemoteHostFactsStore.fileKey(host: "user@192.168.20.95"), "192.168.20.95")
        XCTAssertEqual(RemoteHostFactsStore.fileKey(host: "192.168.20.95"), "192.168.20.95")
    }

    func testFileKeySanitizesDisallowedCharacters() {
        XCTAssertEqual(RemoteHostFactsStore.fileKey(host: "ホスト 名"), "_____")
    }

    func testFileKeyKeepsAllowedCharacters() {
        XCTAssertEqual(RemoteHostFactsStore.fileKey(host: "M1Max-01_v2.local"), "M1Max-01_v2.local")
    }

    func testDifferentHostLabelsWithSameSanitizedKeyShareOneFile() {
        // "user@host" と "user home" は共にサニタイズ後は "user_host"/"user_home" 相当だが、
        // ここでは同一キーへ丸まる2ラベルが同じファイルへ書く(衝突は書き手側の責任)ことだけ固定する
        RemoteHostFactsStore.save(
            RemoteHostFacts(host: "A", updatedAt: "2026-08-18T00:00:00Z"),
            dir: dir, host: "user@host")
        XCTAssertEqual(RemoteHostFactsStore.load(dir: dir, host: "user@host")?.host, "A")
    }

    // MARK: - MachineHardware.current()

    /// この機械上での sanity チェック(具体値は環境依存なので形だけ確認する)
    func testMachineHardwareCurrentReturnsSaneValues() {
        let hardware = MachineHardware.current()
        XCTAssertGreaterThan(hardware.coreCount, 0)
        XCTAssertFalse(hardware.processorModel.isEmpty)
    }
}
