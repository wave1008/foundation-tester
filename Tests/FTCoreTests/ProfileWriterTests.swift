// マシン/アプリ/実行プロファイルを揃えて書く純粋ロジック(`ftester profile setup` の中身)。
// 手書き運用で「machines の device 名と runs の参照名がずれる」「指示していない
// プラットフォームの run が残る」不整合が起きたため、書き手を1箇所にした経緯がある。
import XCTest
@testable import FTCore

final class ProfileWriterTests: XCTestCase {

    private let device: [String: Any] = ["name": "simulator1", "simulator": "iPhone 17 Pro"]

    func testUpsertAddsDeviceAndKeepsUnknownKeys() throws {
        let object: [String: Any] = ["note": "手編集で足したキー",
                                     "ios": ["devices": [], "extra": 1]]
        let updated = try ProfileWriter.upsertingDevice(
            inProfileObject: object, platform: "ios", device: device)
        let section = try XCTUnwrap(updated["ios"] as? [String: Any])
        let devices = try XCTUnwrap(section["devices"] as? [[String: Any]])
        XCTAssertEqual(devices.count, 1)
        XCTAssertEqual(devices[0]["name"] as? String, "simulator1")
        XCTAssertEqual(updated["note"] as? String, "手編集で足したキー", "未知キーを消さない")
        XCTAssertEqual(section["extra"] as? Int, 1, "セクション内の未知キーも消さない")
    }

    /// 同じ論理名の再実行で増えない(冪等)。設定値は新しい方で置き換わる
    func testUpsertReplacesSameName() throws {
        let first = try ProfileWriter.upsertingDevice(
            inProfileObject: [:], platform: "ios", device: device)
        let second = try ProfileWriter.upsertingDevice(
            inProfileObject: first, platform: "ios",
            device: ["name": "simulator1", "simulator": "iPhone 16"])
        let devices = try XCTUnwrap((second["ios"] as? [String: Any])?["devices"] as? [[String: Any]])
        XCTAssertEqual(devices.count, 1)
        XCTAssertEqual(devices[0]["simulator"] as? String, "iPhone 16")
    }

    /// 論理名は ios/android 横断で一意(runs からの参照が曖昧になるため)
    func testUpsertRejectsNameUsedByOtherPlatform() throws {
        let withIOS = try ProfileWriter.upsertingDevice(
            inProfileObject: [:], platform: "ios", device: device)
        XCTAssertThrowsError(try ProfileWriter.upsertingDevice(
            inProfileObject: withIOS, platform: "android",
            device: ["name": "simulator1", "avd": "Pixel_9"]))
    }

    func testAppProfilePlacesFieldsInFixedSections() {
        let object = ProfileWriter.mergingAppProfile(
            into: [:], platform: "ios", appName: "MyApp",
            appID: "com.example.myapp", appPath: "~/builds/MyApp.app")
        let common = object["common"] as? [String: Any]
        XCTAssertEqual(common?["appName"] as? String, "MyApp")
        XCTAssertEqual(common?["autoInstall"] as? Bool, true)
        XCTAssertNil(common?["app"], "app は platform セクションにだけ置く")
        let ios = object["ios"] as? [String: Any]
        XCTAssertEqual(ios?["app"] as? String, "com.example.myapp")
        XCTAssertEqual(ios?["appPath"] as? String, "~/builds/MyApp.app")
    }

    /// appPath が無ければ autoInstall は false(インストール済みアプリを使う)
    func testAppProfileWithoutPathDisablesAutoInstall() {
        let withPath = ProfileWriter.mergingAppProfile(
            into: [:], platform: "android", appName: "A", appID: "com.a", appPath: "~/a.apk")
        let withoutPath = ProfileWriter.mergingAppProfile(
            into: withPath, platform: "android", appName: "A", appID: "com.a", appPath: nil)
        XCTAssertEqual((withoutPath["common"] as? [String: Any])?["autoInstall"] as? Bool, false)
        XCTAssertNil((withoutPath["android"] as? [String: Any])?["appPath"],
                     "指定が無くなったら残骸を残さない")
    }

    /// runs は machines 側の論理名をそのまま参照する(ここがずれると解決できない)
    func testRunProfileReferencesDeviceName() {
        let run = ProfileWriter.runProfile(appRef: "myapp", deviceNames: ["simulator1"])
        XCTAssertEqual(run["app"] as? String, "myapp")
        XCTAssertEqual((run["devices"] as? [[String: String]])?.first?["name"], "simulator1")
        XCTAssertEqual(run["heal"] as? Bool, false)
    }

    func testDefaultDeviceNameMatchesScaffold() {
        XCTAssertEqual(ProfileWriter.defaultDeviceName(platform: "ios"), "simulator1")
        XCTAssertEqual(ProfileWriter.defaultDeviceName(platform: "android"), "emulator1")
    }
}
