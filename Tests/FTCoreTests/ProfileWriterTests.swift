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
        XCTAssertNil(common?["autoInstall"],
                     "書かない(未指定 = appPath の有無で決まる。false を焼き付けない)")
        XCTAssertNil(common?["app"], "app は platform セクションにだけ置く")
        let ios = object["ios"] as? [String: Any]
        XCTAssertEqual(ios?["app"] as? String, "com.example.myapp")
        XCTAssertEqual(ios?["appPath"] as? String, "~/builds/MyApp.app")
    }

    /// appPath を外したら残骸を残さない。autoInstall も書かない(あとで appPath を足したときに
    /// 「false が焼き付いていて入らない」を作らないため)
    func testAppProfileWithoutPathLeavesNoResidue() {
        let withPath = ProfileWriter.mergingAppProfile(
            into: [:], platform: "android", appName: "A", appID: "com.a", appPath: "~/a.apk")
        let withoutPath = ProfileWriter.mergingAppProfile(
            into: withPath, platform: "android", appName: "A", appID: "com.a", appPath: nil)
        XCTAssertNil((withoutPath["common"] as? [String: Any])?["autoInstall"])
        XCTAssertNil((withoutPath["android"] as? [String: Any])?["appPath"])
    }

    /// 利用者が明示した autoInstall は温存する(こちらの都合で消さない)
    func testAppProfileKeepsExplicitAutoInstall() {
        var object = ProfileWriter.mergingAppProfile(
            into: [:], platform: "ios", appName: "A", appID: "com.a", appPath: "~/a.app")
        var common = object["common"] as? [String: Any] ?? [:]
        common["autoInstall"] = false          // 利用者が opt-out した状態
        object["common"] = common
        let updated = ProfileWriter.mergingAppProfile(
            into: object, platform: "ios", appName: "A", appID: "com.a", appPath: "~/a.app")
        XCTAssertEqual((updated["common"] as? [String: Any])?["autoInstall"] as? Bool, false,
                       "利用者の明示指定を消さない")
    }

    /// runs は machines 側の論理名をそのまま参照する(ここがずれると解決できない)
    func testRunProfileReferencesDeviceName() {
        let run = ProfileWriter.runProfile(appRef: "myapp", deviceNames: ["simulator1"])
        XCTAssertEqual(run["app"] as? String, "myapp")
        XCTAssertEqual((run["devices"] as? [[String: String]])?.first?["name"], "simulator1")
        XCTAssertEqual(run["heal"] as? Bool, false)
        XCTAssertNil(run["machine"], "指定が無ければ書かない(登録名での解決に任せる)")
    }

    /// machine を書かないと拡張の実行プロファイル編集が「(未指定)」になりデバイスを選べない
    func testRunProfileRecordsMachineWhenGiven() {
        let run = ProfileWriter.runProfile(
            appRef: "myapp", deviceNames: ["simulator1", "emulator1"], machine: "MyMac")
        XCTAssertEqual(run["machine"] as? String, "MyMac")
        XCTAssertEqual((run["devices"] as? [[String: String]])?.compactMap { $0["name"] },
                       ["simulator1", "emulator1"])
    }

    func testDefaultDeviceNameMatchesScaffold() {
        XCTAssertEqual(ProfileWriter.defaultDeviceName(platform: "ios"), "simulator1")
        XCTAssertEqual(ProfileWriter.defaultDeviceName(platform: "android"), "emulator1")
    }
}
