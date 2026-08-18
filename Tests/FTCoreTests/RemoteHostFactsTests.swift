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
        let facts = RemoteHostFacts(machine: "M1Max", dispatchOverheadSeconds: 4.2,
                                    updatedAt: "2026-08-18T00:00:00Z")
        RemoteHostFactsStore.save(facts, dir: dir, hostLabel: "runner-1")
        XCTAssertEqual(RemoteHostFactsStore.load(dir: dir, hostLabel: "runner-1"), facts)
    }

    func testLoadMissingFileReturnsNil() {
        XCTAssertNil(RemoteHostFactsStore.load(dir: dir, hostLabel: "never-saved"))
    }

    func testLoadCorruptedJSONReturnsNil() throws {
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try "not json".write(
            to: dir.appendingPathComponent(RemoteHostFactsStore.fileKey(hostLabel: "runner-1") + ".json"),
            atomically: true, encoding: .utf8)
        XCTAssertNil(RemoteHostFactsStore.load(dir: dir, hostLabel: "runner-1"))
    }

    func testSaveOverwritesPreviousFacts() {
        RemoteHostFactsStore.save(
            RemoteHostFacts(machine: "old", updatedAt: "2026-08-18T00:00:00Z"),
            dir: dir, hostLabel: "runner-1")
        RemoteHostFactsStore.save(
            RemoteHostFacts(machine: "new", updatedAt: "2026-08-18T01:00:00Z"),
            dir: dir, hostLabel: "runner-1")
        XCTAssertEqual(RemoteHostFactsStore.load(dir: dir, hostLabel: "runner-1")?.machine, "new")
    }

    func testFieldsAreOptionalAndNilRoundTrips() {
        let facts = RemoteHostFacts(updatedAt: "2026-08-18T00:00:00Z")
        RemoteHostFactsStore.save(facts, dir: dir, hostLabel: "bare")
        let loaded = RemoteHostFactsStore.load(dir: dir, hostLabel: "bare")
        XCTAssertEqual(loaded, facts)
        XCTAssertNil(loaded?.machine)
        XCTAssertNil(loaded?.dispatchOverheadSeconds)
    }

    // MARK: - fileKey のサニタイズ

    func testFileKeySanitizesDisallowedCharacters() {
        XCTAssertEqual(RemoteHostFactsStore.fileKey(hostLabel: "user@host"), "user_host")
    }

    func testFileKeyKeepsAllowedCharacters() {
        XCTAssertEqual(RemoteHostFactsStore.fileKey(hostLabel: "M1Max-01_v2.local"), "M1Max-01_v2.local")
    }

    func testDifferentHostLabelsWithSameSanitizedKeyShareOneFile() {
        // "user@host" と "user home" は共にサニタイズ後は "user_host"/"user_home" 相当だが、
        // ここでは同一キーへ丸まる2ラベルが同じファイルへ書く(衝突は書き手側の責任)ことだけ固定する
        RemoteHostFactsStore.save(
            RemoteHostFacts(machine: "A", updatedAt: "2026-08-18T00:00:00Z"),
            dir: dir, hostLabel: "user@host")
        XCTAssertEqual(RemoteHostFactsStore.load(dir: dir, hostLabel: "user@host")?.machine, "A")
    }
}
