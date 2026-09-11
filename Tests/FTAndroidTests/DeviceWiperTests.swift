// 手動 Wipe Data(fleetest api wipe-device)の**振り分けだけ**を検証する。
// 実際の削除・停止・再起動はデバイスに触るのでここでは対象外
// (Android の対象ファイル列挙は AndroidDataWiperTests)。
// ここが守るのは「消せないものを途中まで進めない」—— 実機・avd 未設定・未知の platform は
// **停止する前に**弾く。

import XCTest
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
}
