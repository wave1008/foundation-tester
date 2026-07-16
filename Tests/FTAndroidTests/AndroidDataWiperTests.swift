// wipe 対象の列挙・サイズ合計・しきい値判定のみを検証する(エミュレータ・adb には触れない)。
// 実機の kill/再起動を含む経路は AndroidDataWiper.wipeBloatedAVDs 側にあり、ここでは対象外。

import XCTest
@testable import FTAndroid

final class AndroidDataWiperTests: XCTestCase {
    var avdDir: URL!

    override func setUpWithError() throws {
        avdDir = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("AndroidDataWiperTests-\(UUID().uuidString).avd")
        try FileManager.default.createDirectory(at: avdDir, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: avdDir)
    }

    private func writeFile(_ name: String, bytes: Int) throws -> URL {
        let url = avdDir.appendingPathComponent(name)
        try Data(count: bytes).write(to: url)
        return url
    }

    func testWipeTargetsListsOnlyExistingCandidates() throws {
        _ = try writeFile("userdata-qemu.img.qcow2", bytes: 10)
        _ = try writeFile("cache.img", bytes: 10)
        // sdcard.img は wipe 対象外
        _ = try writeFile("sdcard.img", bytes: 999)

        let targets = AndroidDataWiper.wipeTargets(avdDir: avdDir)
        let names = Set(targets.map { $0.lastPathComponent })
        XCTAssertEqual(names, ["userdata-qemu.img.qcow2", "cache.img"])
    }

    func testWipeTargetsIncludesSnapshotsDirectory() throws {
        let snapshots = avdDir.appendingPathComponent("snapshots")
        try FileManager.default.createDirectory(at: snapshots, withIntermediateDirectories: true)
        try Data(count: 100).write(to: snapshots.appendingPathComponent("default_boot.img"))

        let targets = AndroidDataWiper.wipeTargets(avdDir: avdDir)
        XCTAssertTrue(targets.contains { $0.lastPathComponent == "snapshots" })
    }

    func testWipeTargetsEmptyWhenNothingPresent() {
        XCTAssertTrue(AndroidDataWiper.wipeTargets(avdDir: avdDir).isEmpty)
    }

    func testTotalSizeSumsFilesDirectly() throws {
        _ = try writeFile("userdata-qemu.img.qcow2", bytes: 1000)
        _ = try writeFile("cache.img", bytes: 500)
        let targets = AndroidDataWiper.wipeTargets(avdDir: avdDir)
        XCTAssertEqual(AndroidDataWiper.totalSize(paths: targets), 1500)
    }

    func testTotalSizeRecursesIntoSnapshotsDirectory() throws {
        let snapshots = avdDir.appendingPathComponent("snapshots")
        let snap1 = snapshots.appendingPathComponent("snap1")
        try FileManager.default.createDirectory(at: snap1, withIntermediateDirectories: true)
        try Data(count: 300).write(to: snap1.appendingPathComponent("ram.img"))
        try Data(count: 200).write(to: snap1.appendingPathComponent("screenshot.png"))

        let targets = AndroidDataWiper.wipeTargets(avdDir: avdDir)
        XCTAssertEqual(AndroidDataWiper.totalSize(paths: targets), 500)
    }

    func testTotalSizeIsZeroForMissingPaths() {
        let ghost = avdDir.appendingPathComponent("does-not-exist.img")
        XCTAssertEqual(AndroidDataWiper.totalSize(paths: [ghost]), 0)
    }

    // MARK: - avdContentDirectory(ini の path= が正。<id>.avd 直組みは実体とずれることがある)

    func testAVDContentDirectoryFollowsIniPath() throws {
        let home = avdDir.deletingLastPathComponent()
        let actual = home.appendingPathComponent("Renamed__1.avd")
        try FileManager.default.createDirectory(at: actual, withIntermediateDirectories: true)
        try "avd.ini.encoding=UTF-8\npath=\(actual.path)\npath.rel=avd/Renamed__1.avd\n"
            .write(to: home.appendingPathComponent("Renamed.ini"), atomically: true, encoding: .utf8)

        XCTAssertEqual(AndroidDeviceCatalog.avdContentDirectory(id: "Renamed", home: home).path,
                       actual.path)
    }

    func testAVDContentDirectoryFallsBackWithoutIni() {
        let home = avdDir.deletingLastPathComponent()
        XCTAssertEqual(AndroidDeviceCatalog.avdContentDirectory(id: "NoIni", home: home).path,
                       home.appendingPathComponent("NoIni.avd").path)
    }

    func testAVDContentDirectoryFallsBackWhenIniPathMissing() throws {
        let home = avdDir.deletingLastPathComponent()
        try "path=/nonexistent/dir.avd\n"
            .write(to: home.appendingPathComponent("Ghost.ini"), atomically: true, encoding: .utf8)
        XCTAssertEqual(AndroidDeviceCatalog.avdContentDirectory(id: "Ghost", home: home).path,
                       home.appendingPathComponent("Ghost.avd").path)
    }
}
