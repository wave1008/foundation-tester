// 容量不足(INSTALL_FAILED_INSUFFICIENT_STORAGE)のインストール失敗を Wipe Data で救う配線。
// 実測 M1Ultra Pixel-07: guest の /data が 90% で2スイートともレーン離脱した。
// wipeDataOnBloat はホスト側のファイルの合計を見るので、この形は拾えない(AndroidInstallFailure の doc)。
// Wipe そのものは実 AVD が要るので、記録する偽物(AndroidStorageRecovery)を渡して配線だけを見る。

import XCTest
@testable import FTCore
@testable import FTAndroid

private struct InstallFailure: Error, LocalizedError {
    let text: String
    var errorDescription: String? { text }
}

/// install が `failures` 回だけ失敗し、その後は成功する(呼ばれた回数を数える)
private final class FlakyInstallDriver: AppDriver, @unchecked Sendable {
    private let lock = NSLock()
    private var remainingFailures: Int
    private let failureText: String
    private(set) var installCalls = 0
    init(failures: Int, failureText: String) {
        remainingFailures = failures
        self.failureText = failureText
    }
    func install(packagePath: String) async throws {
        lock.lock(); defer { lock.unlock() }
        installCalls += 1
        if remainingFailures > 0 { remainingFailures -= 1; throw InstallFailure(text: failureText) }
    }
    func status() async throws -> StatusResponse {
        StatusResponse(ready: true, device: "-", osVersion: "-", sessionBundleID: nil)
    }
    func uninstall(bundleID: String) async throws {}
    func launch(bundleID: String) async throws {}
    func isAppForeground(bundleID: String) async throws -> Bool { false }
    func foregroundAppID() async throws -> String? { nil }
    func snapshot() async throws -> SnapshotResponse {
        SnapshotResponse(sessionBundleID: nil, screen: FTRect(x: 0, y: 0, width: 0, height: 0),
                         elements: [], truncatedCount: 0)
    }
    func tap(ref: Int) async throws {}
    func tap(x: Double, y: Double) async throws {}
    func type(ref: Int?, text: String) async throws {}
    func swipe(_ direction: FTSwipeDirection) async throws {}
    func press(ref: Int, duration: Double) async throws {}
    func screenshot() async throws -> Data { Data() }
    func terminate() async throws {}
}

/// Wipe の呼び出しを記録し、Wipe 後の serial → AVD を差し替えられる偽物
private final class RecordingRecovery: @unchecked Sendable {
    private let lock = NSLock()
    private(set) var wipes: [(device: String, avd: String, locale: String)] = []
    /// 起きた順("wipe" / "await:<serial>")。入れ直しの前に待ったことを確かめる
    private(set) var order: [String] = []
    var mapBefore: [String: String]
    var mapAfter: [String: String]
    init(mapBefore: [String: String], mapAfter: [String: String]? = nil) {
        self.mapBefore = mapBefore
        self.mapAfter = mapAfter ?? mapBefore
    }
    var recovery: AndroidStorageRecovery {
        AndroidStorageRecovery(
            avdBySerial: { [self] in
                self.lock.lock(); defer { self.lock.unlock() }
                return self.wipes.isEmpty ? self.mapBefore : self.mapAfter
            },
            wipe: { [self] device, avd, locale, _ in
                self.lock.lock(); defer { self.lock.unlock() }
                self.wipes.append((device, avd, locale))
                self.order.append("wipe")
            },
            awaitPackageManager: { [self] serial in
                self.lock.lock(); defer { self.lock.unlock() }
                self.order.append("await:\(serial)")
                return 0
            })
    }
}

final class InstallStorageRecoveryTests: XCTestCase {

    private let storageFailure = "failed to install the app: Performing Streamed Install\n"
        + "adb: failed to install /x/app.apk: Failure [INSTALL_FAILED_INSUFFICIENT_STORAGE: Failed to override installation location]"

    private var apkPath: String!

    override func setUpWithError() throws {
        // installIfNeeded は appPath の実在を先に確かめる
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("storage-recovery-\(UUID().uuidString).apk")
        try Data("apk".utf8).write(to: url)
        apkPath = url.path
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(atPath: apkPath)
    }

    private func worker(_ driver: AppDriver, serial: String = "emulator-5566") -> RunWorker {
        RunWorker(label: "Pixel-07(android:\(serial))", platform: "android", driver: driver,
                  connection: DriverConnection(platform: "android", serial: serial),
                  logicalName: "Pixel-07")
    }

    private func apps() -> [String: ResolvedAppTarget] {
        ["android": ResolvedAppTarget(bundleID: "com.example.app", appPath: apkPath, autoInstall: true)]
    }

    // MARK: - 判定(純粋関数)

    func testRecognisesTheInsufficientStorageCode() {
        XCTAssertTrue(AndroidInstallFailure.isInsufficientStorage(storageFailure))
        // さらに詰まった段: セッションを作る前に落ち、状態コードが出ない(陽性対照の実出力)
        XCTAssertTrue(AndroidInstallFailure.isInsufficientStorage(
            "failed to install the app: Performing Streamed Install\nadb: failed to install /x/app.apk: \n"
            + "Exception occurred while executing 'install':\n"
            + "android.os.ParcelableException: java.io.IOException: Requested internal only, but not enough space"))
        XCTAssertFalse(AndroidInstallFailure.isInsufficientStorage(
            "failed to install the app: Failure [INSTALL_FAILED_UPDATE_INCOMPATIBLE]"))
        XCTAssertFalse(AndroidInstallFailure.isInsufficientStorage("adb: device offline"))
    }

    // MARK: - 配線

    /// 容量不足 → その AVD を Wipe → 入れ直して**ワーカーは残る**(離脱しない)
    func testInsufficientStorageWipesTheAVDAndReinstallsOnce() async throws {
        let driver = FlakyInstallDriver(failures: 1, failureText: storageFailure)
        let recording = RecordingRecovery(mapBefore: ["emulator-5566": "Pixel_9_Android_15_-07"])
        var logs: [String] = []

        let kept = try await ProfileWorkerFactory.installIfNeeded(
            apps: apps(), workers: [worker(driver)], wipeOnInsufficientStorage: true, locale: "ja_JP",
            storageRecovery: recording.recovery) { logs.append($0) }

        XCTAssertEqual(kept.count, 1, "救えたワーカーは残る: \(logs)")
        XCTAssertEqual(recording.wipes.count, 1)
        XCTAssertEqual(recording.wipes.first?.avd, "Pixel_9_Android_15_-07")
        XCTAssertEqual(recording.wipes.first?.locale, "ja_JP")
        XCTAssertEqual(driver.installCalls, 2, "失敗 1 回 + 入れ直し 1 回")
        XCTAssertEqual(recording.order, ["wipe", "await:emulator-5566"],
                       "入れ直す前にパッケージマネージャの応答を待つ")
        XCTAssertTrue(logs.contains { $0.contains("install complete (after Wipe Data)") }, "\(logs)")
    }

    /// 実行プロファイルの wipeDataOnBloat が OFF なら、容量不足でも Wipe しない(従来どおり離脱し、理由を言う)
    func testWipeIsNotFiredWhenTheProfileForbidsAutoWipe() async throws {
        let driver = FlakyInstallDriver(failures: 1, failureText: storageFailure)
        let recording = RecordingRecovery(mapBefore: ["emulator-5566": "Pixel_9_Android_15_-07"])
        let healthy = worker(FlakyInstallDriver(failures: 0, failureText: ""), serial: "emulator-5554")
        var logs: [String] = []

        let kept = try await ProfileWorkerFactory.installIfNeeded(
            apps: apps(), workers: [worker(driver), healthy],
            wipeOnInsufficientStorage: false, locale: "ja_JP",
            storageRecovery: recording.recovery) { logs.append($0) }

        XCTAssertEqual(kept.map(\.connection.serial), ["emulator-5554"])
        XCTAssertTrue(recording.wipes.isEmpty, "OFF のときは Wipe を撃たない")
        XCTAssertEqual(driver.installCalls, 1)
        XCTAssertTrue(logs.contains { $0.contains("wipeDataOnBloat is off") }, "\(logs)")
    }

    /// 容量不足でない失敗は従来どおり離脱(Wipe を撃たない)
    func testOtherInstallFailuresDoNotWipe() async throws {
        let driver = FlakyInstallDriver(failures: 1, failureText: "failed to install the app: Failure [INSTALL_FAILED_UPDATE_INCOMPATIBLE]")
        let recording = RecordingRecovery(mapBefore: ["emulator-5566": "Pixel_9_Android_15_-07"])
        // 全滅は throw(F5)なので、健全な相方を1台添えて離脱の形で観測する
        let healthy = worker(FlakyInstallDriver(failures: 0, failureText: ""), serial: "emulator-5554")

        let kept = try await ProfileWorkerFactory.installIfNeeded(
            apps: apps(), workers: [worker(driver), healthy], wipeOnInsufficientStorage: true, locale: "ja_JP",
            storageRecovery: recording.recovery) { _ in }

        XCTAssertEqual(kept.map(\.connection.serial), ["emulator-5554"])
        XCTAssertTrue(recording.wipes.isEmpty)
        XCTAssertEqual(driver.installCalls, 1, "入れ直さない")
    }

    /// Wipe 後に別の serial で戻ってきたら、そのワーカーは使わない(接続情報が古い)
    func testWorkerIsDroppedWhenTheAVDComesBackOnAnotherSerial() async throws {
        let driver = FlakyInstallDriver(failures: 1, failureText: storageFailure)
        let recording = RecordingRecovery(mapBefore: ["emulator-5566": "Pixel_9_Android_15_-07"],
                                          mapAfter: ["emulator-5570": "Pixel_9_Android_15_-07"])
        let healthy = worker(FlakyInstallDriver(failures: 0, failureText: ""), serial: "emulator-5554")

        let kept = try await ProfileWorkerFactory.installIfNeeded(
            apps: apps(), workers: [worker(driver), healthy], wipeOnInsufficientStorage: true, locale: "ja_JP",
            storageRecovery: recording.recovery) { _ in }

        XCTAssertEqual(kept.map(\.connection.serial), ["emulator-5554"])
        XCTAssertEqual(recording.wipes.count, 1)
        XCTAssertEqual(driver.installCalls, 1, "serial が変わったら入れ直さない")
    }
}
