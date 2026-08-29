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

    // MARK: - 停止確認(プロセス走査)
    // **中止を成功として返さない**ための2本目の根拠。adb が詰まっているときに serial だけを
    // 見ていると「本当は止まっているのに確認が取れない」で中止してしまう(2026-08-29 の実例)。

    private static let psSample = """
    /Users/x/Library/Android/sdk/emulator/qemu/darwin-aarch64/qemu-system-aarch64 -avd Pixel_9_Android_15_-01 -no-window
    /Users/x/Library/Android/sdk/emulator/qemu/darwin-aarch64/qemu-system-aarch64 -avd Pixel_10_Android_16_-07 -no-window
    /usr/bin/some-other-process
    """

    func testAVDProcessPresentFindsTheRunningEmulator() {
        XCTAssertTrue(AndroidDataWiper.avdProcessPresent(psOutput: Self.psSample, avdID: "Pixel_9_Android_15_-01"))
        XCTAssertTrue(AndroidDataWiper.avdProcessPresent(psOutput: Self.psSample, avdID: "Pixel_10_Android_16_-07"))
    }

    func testAVDProcessPresentIsFalseWhenTheEmulatorIsGone() {
        XCTAssertFalse(AndroidDataWiper.avdProcessPresent(psOutput: Self.psSample, avdID: "Pixel_9_Android_15_-02"))
        XCTAssertFalse(AndroidDataWiper.avdProcessPresent(psOutput: "", avdID: "Pixel_9_Android_15_-01"))
    }

    /// **前方一致で判定しない** —— 片方がもう片方の接頭辞になる AVD 名は普通にある。
    /// 前方一致だと「-01 が動いているから -0 も動いている」と誤判定し、止まっている台の wipe を
    /// 締切まで待たせる(逆に -0 の走査で -01 を消しにいくことはない = 安全側だが遅い)
    func testAVDProcessPresentDoesNotMatchAPrefixOfAnotherAVD() {
        XCTAssertFalse(AndroidDataWiper.avdProcessPresent(psOutput: Self.psSample, avdID: "Pixel_9_Android_15_-0"))
        XCTAssertFalse(AndroidDataWiper.avdProcessPresent(psOutput: Self.psSample, avdID: "Pixel_9"))
    }

    /// 停止を確認できなかったときの文言は**「何も消していない」ことを言う**(利用者はここだけ見て
    /// 「消えたのか残ったのか」を判断する)
    func testStopNotConfirmedSaysNothingWasWiped() {
        let error = AndroidDataWiperError.stopNotConfirmed(
            device: "エミュ1", serial: "emulator-5554", seconds: 60)
        let message = error.errorDescription ?? ""
        XCTAssertTrue(message.contains("nothing was wiped"), message)
        XCTAssertTrue(message.contains("emulator-5554"), message)
        XCTAssertTrue(message.contains("60"), message)
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
