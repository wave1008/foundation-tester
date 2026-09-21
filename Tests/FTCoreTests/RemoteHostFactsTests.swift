import XCTest
@testable import FTCore
import FTRemote

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
        XCTAssertNil(loaded?.hardwareUUID)
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
        XCTAssertNil(loaded?.hardwareUUID)
    }

    // MARK: - hardwareUUID(機械を一意に識別する値)

    func testHardwareUUIDRoundTrips() {
        let facts = RemoteHostFacts(host: "M1Max", machineAlias: "M1Max",
                                    hardwareUUID: "0A1B2C3D-4E5F-6071-8293-A4B5C6D7E8F9",
                                    dispatchOverheadSeconds: 4.2,
                                    updatedAt: "2026-09-21T00:00:00Z")
        RemoteHostFactsStore.save(facts, dir: dir, host: "runner-3")
        let loaded = RemoteHostFactsStore.load(dir: dir, host: "runner-3")
        XCTAssertEqual(loaded, facts)
        XCTAssertEqual(loaded?.hardwareUUID, "0A1B2C3D-4E5F-6071-8293-A4B5C6D7E8F9")
    }

    /// **片方だけ取れなかった回に既存値を消さない**: UUID を書いた後、UUID を採れなかった
    /// ディスパッチ(= resolve が既存値を stored に返す)が他の欄だけ更新しても UUID は残る
    func testSavingWithoutTheUUIDKeepsTheCachedOneWhenTheWriterCarriesItForward() {
        RemoteHostFactsStore.save(
            RemoteHostFacts(host: "M1Max", hardwareUUID: "0A1B2C3D-4E5F-6071-8293-A4B5C6D7E8F9",
                            coreCount: 10, updatedAt: "2026-09-21T00:00:00Z"),
            dir: dir, host: "runner-4")
        let existing = RemoteHostFactsStore.load(dir: dir, host: "runner-4")
        let carried = RemoteHardwareUUIDChange.resolve(
            cached: existing?.hardwareUUID, observed: nil, host: "runner-4")
        RemoteHostFactsStore.save(
            RemoteHostFacts(host: "M1Max", hardwareUUID: carried.stored, coreCount: 12,
                            updatedAt: "2026-09-21T01:00:00Z"),
            dir: dir, host: "runner-4")
        let loaded = RemoteHostFactsStore.load(dir: dir, host: "runner-4")
        XCTAssertEqual(loaded?.hardwareUUID, "0A1B2C3D-4E5F-6071-8293-A4B5C6D7E8F9")
        XCTAssertEqual(loaded?.coreCount, 12)
    }

    // MARK: - RemoteHardwareUUIDChange(変化の検出。文言まで固定する)

    /// キャッシュ無し = 初回。黙って保存する
    func testChangeIsSilentWhenNothingWasCached() {
        let outcome = RemoteHardwareUUIDChange.resolve(
            cached: nil, observed: "0A1B2C3D-4E5F-6071-8293-A4B5C6D7E8F9", host: "ci@runner-1")
        XCTAssertEqual(outcome, RemoteHardwareUUIDChange.Outcome(
            warning: nil, stored: "0A1B2C3D-4E5F-6071-8293-A4B5C6D7E8F9"))
    }

    func testChangeIsSilentWhenTheUUIDIsUnchanged() {
        let outcome = RemoteHardwareUUIDChange.resolve(
            cached: "0A1B2C3D-4E5F-6071-8293-A4B5C6D7E8F9",
            observed: "0A1B2C3D-4E5F-6071-8293-A4B5C6D7E8F9", host: "ci@runner-1")
        XCTAssertEqual(outcome, RemoteHardwareUUIDChange.Outcome(
            warning: nil, stored: "0A1B2C3D-4E5F-6071-8293-A4B5C6D7E8F9"))
    }

    /// **不明(今回読めなかった)を「変化した」と言わない**・既存値も消さない
    func testChangeIsSilentWhenTheProbeCouldNotReadTheUUID() {
        let outcome = RemoteHardwareUUIDChange.resolve(
            cached: "0A1B2C3D-4E5F-6071-8293-A4B5C6D7E8F9", observed: nil, host: "ci@runner-1")
        XCTAssertEqual(outcome, RemoteHardwareUUIDChange.Outcome(
            warning: nil, stored: "0A1B2C3D-4E5F-6071-8293-A4B5C6D7E8F9"))
    }

    /// キャッシュも観測も無いときは黙って nil のまま
    func testChangeIsSilentWhenBothSidesAreUnknown() {
        XCTAssertEqual(RemoteHardwareUUIDChange.resolve(cached: nil, observed: nil, host: "ci@runner-1"),
                       RemoteHardwareUUIDChange.Outcome(warning: nil, stored: nil))
    }

    /// 違う値 = 別のマシン。**1行の警告を出し、キャッシュは新しい値で更新する**(run は止めない)
    func testChangeWarnsAndUpdatesTheCacheWhenTheUUIDDiffers() {
        let outcome = RemoteHardwareUUIDChange.resolve(
            cached: "0A1B2C3D-4E5F-6071-8293-A4B5C6D7E8F9",
            observed: "11111111-2222-3333-4444-555555555555", host: "ci@runner-1")
        XCTAssertEqual(outcome.stored, "11111111-2222-3333-4444-555555555555")
        XCTAssertEqual(outcome.warning,
            "warning: ci@runner-1 reports a different hardware UUID than the last dispatch"
            + " (was 0A1B2C3D-4E5F-6071-8293-A4B5C6D7E8F9,"
            + " now 11111111-2222-3333-4444-555555555555)"
            + " — this host now resolves to a different Mac")
        XCTAssertEqual(outcome.warning?.components(separatedBy: "\n").count, 1, "警告は1行")
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

    // MARK: - aliasPairs(dir:)

    func testAliasPairsCollectsHostToMachineSorted() {
        RemoteHostFactsStore.save(
            RemoteHostFacts(host: "SNB-M1", machineAlias: "M1Max", updatedAt: "2026-08-31T00:00:00Z"),
            dir: dir, host: "192.168.20.101")
        RemoteHostFactsStore.save(
            RemoteHostFacts(host: "LDIPC96", machineAlias: "local", updatedAt: "2026-08-31T00:00:00Z"),
            dir: dir, host: "LDIPC96")
        // machineAlias 欠落は表に入れない
        RemoteHostFactsStore.save(
            RemoteHostFacts(host: "NOALIAS", updatedAt: "2026-08-31T00:00:00Z"),
            dir: dir, host: "10.0.0.9")
        let pairs = RemoteHostFactsStore.aliasPairs(dir: dir)
        XCTAssertEqual(pairs.map(\.host), ["LDIPC96", "SNB-M1"], "host 昇順・欠落は除外")
        XCTAssertEqual(pairs.map(\.machine), ["local", "M1Max"])
    }

    /// 同じ host が IP キーと名前キーの両ファイルに居るとき、updatedAt の新しい方のエイリアスを採る
    func testAliasPairsPrefersNewerEntryForDuplicateHost() {
        RemoteHostFactsStore.save(
            RemoteHostFacts(host: "SNB-M1", machineAlias: "old-name", updatedAt: "2026-08-01T00:00:00Z"),
            dir: dir, host: "SNB-M1")
        RemoteHostFactsStore.save(
            RemoteHostFacts(host: "SNB-M1", machineAlias: "M1Max", updatedAt: "2026-08-31T00:00:00Z"),
            dir: dir, host: "192.168.20.101")
        let pairs = RemoteHostFactsStore.aliasPairs(dir: dir)
        XCTAssertEqual(pairs.count, 1)
        XCTAssertEqual(pairs.first?.machine, "M1Max")
    }

    // MARK: - MachineHardware.current()

    /// この機械上での sanity チェック(具体値は環境依存なので形だけ確認する)
    func testMachineHardwareCurrentReturnsSaneValues() {
        let hardware = MachineHardware.current()
        XCTAssertGreaterThan(hardware.coreCount, 0)
        XCTAssertFalse(hardware.processorModel.isEmpty)
    }
}
