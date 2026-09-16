// 手動 Wipe Data(fleetest api wipe-device)の**振り分けだけ**を検証する。
// 実際の削除・停止・再起動はデバイスに触るのでここでは対象外
// (Android の対象ファイル列挙は AndroidDataWiperTests)。
// ここが守るのは「消せないものを途中まで進めない」—— 実機・avd 未設定・未知の platform は
// **停止する前に**弾く。

import XCTest
import FTBridgeClient
import FTCore
@testable import FTAndroid

final class DeviceWiperTests: XCTestCase {

    func testIOSSimulatorGoesToTheErasePath() throws {
        let spec = DeviceSpec(name: "シミュ1", udid: "UDID-1")
        XCTAssertEqual(try DeviceWiper.target(spec: spec, platform: "ios"), .ios)
    }

    func testAndroidEmulatorCarriesItsAVD() throws {
        let spec = DeviceSpec(name: "エミュ1", avd: "Pixel_8")
        XCTAssertEqual(try DeviceWiper.target(spec: spec, platform: "android"), .android(avd: "Pixel_8"))
    }

    func testPhysicalDeviceIsRejectedOnBothPlatforms() {
        for platform in ["ios", "android"] {
            let spec = DeviceSpec(name: "実機1", kind: .physical, udid: "UDID-P", avd: "Pixel_8")
            XCTAssertThrowsError(try DeviceWiper.target(spec: spec, platform: platform)) { error in
                XCTAssertEqual(error as? DeviceWiperError, .physicalDevice(name: "実機1"))
            }
        }
    }

    func testAndroidWithoutAVDIsRejected() {
        let spec = DeviceSpec(name: "エミュ1")
        XCTAssertThrowsError(try DeviceWiper.target(spec: spec, platform: "android")) { error in
            XCTAssertEqual(error as? DeviceWiperError, .noAVD(name: "エミュ1"))
        }
    }

    func testUnknownPlatformIsRejected() {
        let spec = DeviceSpec(name: "なにか", avd: "Pixel_8")
        XCTAssertThrowsError(try DeviceWiper.target(spec: spec, platform: "web")) { error in
            XCTAssertEqual(error as? DeviceWiperError, .unsupportedPlatform("web"))
        }
    }

    // MARK: - SimulatorLocalePreservation(純粋関数だけ。simctl 自体はデバイスが要るので対象外)

    func testParseLanguagesReadsTheOpenStepArray() {
        let output = "(\n    \"ja-JP\",\n    \"en-US\"\n)\n"
        XCTAssertEqual(SimulatorLocalePreservation.parseLanguages(output), ["ja-JP", "en-US"])
    }

    func testParseLanguagesHandlesASingleEntry() {
        XCTAssertEqual(SimulatorLocalePreservation.parseLanguages("(\n    \"ja-JP\"\n)\n"), ["ja-JP"])
    }

    // 実際のエラー出力(exit != 0)は readSimulatorLocale が status で弾いてから呼ぶので、
    // ここが見るのは空出力(未設定)だけでよい
    func testParseLanguagesReturnsEmptyForEmptyOutput() {
        XCTAssertEqual(SimulatorLocalePreservation.parseLanguages(""), [])
    }

    func testParseLocaleReadsTheIdentifier() {
        XCTAssertEqual(SimulatorLocalePreservation.parseLocale("ja_JP\n"), "ja_JP")
    }

    func testParseLocaleReturnsNilForEmptyOutput() {
        XCTAssertNil(SimulatorLocalePreservation.parseLocale(""))
        XCTAssertNil(SimulatorLocalePreservation.parseLocale("\n"))
    }

    /// 停止中だった台/読み取り失敗時のフォールバック。**日本語だけにせず英語も残す**
    /// (言語を1つしか持たないと英語の文言が一切出せなくなる)
    func testFallbackBuildsFromTheLocaleArgument() {
        let snapshot = SimulatorLocalePreservation.fallback(locale: "ja_JP")
        XCTAssertEqual(snapshot.languages, ["ja-JP", "en-US"])
        XCTAssertEqual(snapshot.locale, "ja_JP")
    }

    func testReadCommandsTargetTheGlobalDomainOnTheGivenUDID() {
        XCTAssertEqual(SimulatorLocalePreservation.readLanguagesCommand(udid: "UDID-1"),
                       ["xcrun", "simctl", "spawn", "UDID-1", "defaults", "read", "-g", "AppleLanguages"])
        XCTAssertEqual(SimulatorLocalePreservation.readLocaleCommand(udid: "UDID-1"),
                       ["xcrun", "simctl", "spawn", "UDID-1", "defaults", "read", "-g", "AppleLocale"])
    }

    /// `defaults write` は1呼び出し1キーなので2本に分かれる。両方とも同じ udid・`-g` を通す
    func testWriteCommandsCoverBothKeysSeparately() {
        let snapshot = SimulatorLocalePreservation.Snapshot(languages: ["ja-JP", "en-US"], locale: "ja_JP")
        let commands = SimulatorLocalePreservation.writeCommands(udid: "UDID-1", snapshot: snapshot)
        XCTAssertEqual(commands.count, 2)
        XCTAssertEqual(commands[0],
                       ["xcrun", "simctl", "spawn", "UDID-1", "defaults", "write", "-g",
                        "AppleLanguages", "-array", "ja-JP", "en-US"])
        XCTAssertEqual(commands[1],
                       ["xcrun", "simctl", "spawn", "UDID-1", "defaults", "write", "-g",
                        "AppleLocale", "-string", "ja_JP"])
    }

    // MARK: - Android の run-lease 判定(消す前に他人の run を殺さない。docs/remote-runner.md
    // §18.7 規律④)。simctl/adb/実エミュレータには触れず、一時ディレクトリの RunLease.write で
    // 偽の保持者を作って確かめる(DeviceBooterStopRefusalTests と同じ作法)。

    private func makeStateDir() -> URL {
        FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    }

    // 戻すと落ちる根拠: 変更前は Android 経路が DeviceBooter.stopRefusal を1度も通らず、
    // lease 保持中でも待たずに wipe が進んでいた(AndroidDataWiper.wipeOne まで到達し、
    // このテストでは avdDirectoryNotFound で「拒否ではない別の理由」で失敗してしまう)。
    func testAndroidWipeRefusesWhileALeaseIsHeld() async {
        let dir = makeStateDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let holder = getppid()  // 生きた別プロセスと同じ形(生存確認だけが要件)
        RunLease.write(stateDir: dir, key: "emulator-5554", pid: holder)
        let spec = DeviceSpec(name: "エミュ1", avd: "Pixel_8")

        do {
            try await DeviceWiper.wipeOne(
                spec: spec, platform: "android", repoRoot: nil,
                leaseStateDir: dir, androidLeaseKey: { "emulator-5554" }, log: { _ in })
            XCTFail("lease 保持中は拒否されるはず")
        } catch let error as DeviceBooterError {
            guard case .commandFailed(let message) = error else {
                XCTFail("expected .commandFailed, got \(error)")
                return
            }
            XCTAssertTrue(message.contains("エミュ1"), "台名を名指しする")
            XCTAssertTrue(message.contains("\(holder)"), "保持者 pid を名指しする")
            XCTAssertTrue(message.contains("--force"), "押し切る手段を添える")
        } catch {
            XCTFail("unexpected error type: \(error)")
        }
    }

    // --force は「押し切って AndroidDataWiper.wipeOne まで進む」ことで確かめる。実 AVD が無いので
    // そこは avdDirectoryNotFound で失敗するが、それは拒否ではなく「先へ進んだ」証拠になる。
    func testAndroidWipeForceBypassesTheLeaseRefusal() async {
        let dir = makeStateDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        RunLease.write(stateDir: dir, key: "emulator-5554", pid: getppid())
        let spec = DeviceSpec(name: "エミュ1", avd: "Pixel_8_nonexistent_\(UUID().uuidString)")

        do {
            try await DeviceWiper.wipeOne(
                spec: spec, platform: "android", repoRoot: nil, force: true,
                leaseStateDir: dir, androidLeaseKey: { "emulator-5554" }, log: { _ in })
            XCTFail("実在しない AVD なので avdDirectoryNotFound で失敗するはず")
        } catch let error as AndroidDataWiperError {
            guard case .avdDirectoryNotFound = error else {
                XCTFail("unexpected AndroidDataWiperError: \(error)")
                return
            }
        } catch {
            XCTFail("unexpected error type: \(error)")
        }
    }

    // 保持者が居なければ(force 無しでも)拒否されず先へ進む
    func testAndroidWipeProceedsWhenNoLeaseIsHeld() async {
        let dir = makeStateDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let spec = DeviceSpec(name: "エミュ1", avd: "Pixel_8_nonexistent_\(UUID().uuidString)")

        do {
            try await DeviceWiper.wipeOne(
                spec: spec, platform: "android", repoRoot: nil,
                leaseStateDir: dir, androidLeaseKey: { "emulator-5554" }, log: { _ in })
            XCTFail("実在しない AVD なので avdDirectoryNotFound で失敗するはず")
        } catch let error as AndroidDataWiperError {
            guard case .avdDirectoryNotFound = error else {
                XCTFail("unexpected AndroidDataWiperError: \(error)")
                return
            }
        } catch {
            XCTFail("unexpected error type: \(error)")
        }
    }
}
