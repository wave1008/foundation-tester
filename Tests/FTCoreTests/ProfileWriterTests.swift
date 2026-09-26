// アプリ/実行プロファイルを揃えて書く純粋ロジック(`fleetest profile setup` の中身)。
import XCTest
@testable import FTCore

final class ProfileWriterTests: XCTestCase {

    func testAppProfilePlacesFieldsInFixedSections() {
        let object = ProfileWriter.mergingAppProfile(
            into: [:], platform: "ios", appName: "MyApp",
            appID: "com.example.myapp", appPath: "~/builds/MyApp.app")
        let common = object["common"] as? [String: Any]
        XCTAssertNil(common?["appName"], "appName は common に書かない(platform セクションのみ)")
        XCTAssertNil(common?["autoInstall"],
                     "書かない(未指定 = appPath の有無で決まる。false を焼き付けない)")
        XCTAssertNil(common?["app"], "app は platform セクションにだけ置く")
        let ios = object["ios"] as? [String: Any]
        XCTAssertEqual(ios?["appName"] as? String, "MyApp", "appName は platform セクションに書く")
        XCTAssertEqual(ios?["app"] as? String, "com.example.myapp")
        XCTAssertEqual(ios?["appPath"] as? String, "~/builds/MyApp.app")
    }

    /// ios と android を別々に呼べば、それぞれ別の表示名を持てる(この契約変更の核)
    func testAppProfileAllowsDifferentAppNamePerPlatform() {
        var object = ProfileWriter.mergingAppProfile(
            into: [:], platform: "ios", appName: "MyApp (iOS)",
            appID: "com.example.myapp", appPath: nil)
        object = ProfileWriter.mergingAppProfile(
            into: object, platform: "android", appName: "MyApp (Android)",
            appID: "com.example.myapp", appPath: nil)
        XCTAssertEqual((object["ios"] as? [String: Any])?["appName"] as? String, "MyApp (iOS)")
        XCTAssertEqual((object["android"] as? [String: Any])?["appName"] as? String, "MyApp (Android)")
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

    func testRunProfileCarriesTheDeviceEntities() {
        let device: [String: Any] = ["platform": "ios", "machine": "local", "name": "simulator1",
                                     "model": "iPhone 17 Pro"]
        let run = ProfileWriter.runProfile(appRef: "myapp", devices: [device])
        XCTAssertEqual(run["app"] as? String, "myapp")
        let devices = run["devices"] as? [[String: Any]]
        XCTAssertEqual(devices?.first?["name"] as? String, "simulator1")
        XCTAssertEqual(devices?.first?["model"] as? String, "iPhone 17 Pro")
        XCTAssertEqual(run["heal"] as? Bool, true)
        XCTAssertEqual(run["fmTextOcclusionCheck"] as? Bool, true)
        XCTAssertNil(run["reportDir"], "既定(reports)は書かない = フォームで空欄+透かしになる")
        XCTAssertNil(run["machine"], "トップレベルの machine は無い(台ごとに持つ)")
    }

    /// 書き出しのキー順: platform → machine → name → enabled → 残りはアルファベット順
    func testRunProfileJSONPutsDeviceIdentityFirst() throws {
        let run = ProfileWriter.runProfile(appRef: "myapp", devices: [
            ["udid": "U", "name": "s", "enabled": false, "machine": "local", "platform": "ios", "osVersion": "iOS 27.0"],
        ])
        let text = String(decoding: try ProfileWriter.json(run), as: UTF8.self)
        let keys = ["\"app\"", "\"devices\"", "\"platform\"", "\"machine\"", "\"name\"",
                    "\"enabled\"", "\"osVersion\"", "\"udid\""]
        let positions = keys.compactMap { text.range(of: $0)?.lowerBound }
        XCTAssertEqual(positions.count, keys.count, text)
        XCTAssertEqual(positions, positions.sorted(), text)
    }

    func testDefaultDeviceNameMatchesScaffold() {
        XCTAssertEqual(ProfileWriter.defaultDeviceName(platform: "ios"), "simulator1")
        XCTAssertEqual(ProfileWriter.defaultDeviceName(platform: "android"), "emulator1")
    }

    // MARK: - 実体の有無(キー数で判定してはいけない)

    /// **本丸**: platform + machine + name だけの1件は「実体なし」。ここが true になると
    /// `profile setup --auto-device` が一度も発火せず、機種も OS も UDID も無い simulator1 /
    /// emulator1 が受け手のプロファイルへ書かれる
    func testIdentityAloneIsNotADeviceBody() {
        XCTAssertFalse(ProfileWriter.hasDeviceBody(["platform": "ios", "machine": "local", "name": "simulator1"]))
        XCTAssertFalse(ProfileWriter.hasDeviceBody([:]))
    }

    /// 実体を指さないキーが増えても「実体なし」のまま(キー数で数えると false → true に化ける)
    func testNonBodyKeysDoNotCountAsADeviceBody() {
        XCTAssertFalse(ProfileWriter.hasDeviceBody(
            ["platform": "ios", "machine": "local", "name": "simulator1", "engine": "inapp", "port": 8100]))
    }

    /// JSON 側(deviceBodyKeys)と型側(DeviceSpec.lacksConcreteTarget)は同じ集合を見る。
    /// 片方だけにキーを足すと、書くときは実体扱い・走るときは「実体なし」の警告(または逆)になる
    func testDeviceSpecAndBodyKeysAgree() {
        XCTAssertTrue(DeviceSpec(name: "d", machine: "local").lacksConcreteTarget)
        XCTAssertTrue(DeviceSpec(name: "d", machine: "local", port: 8100, engine: "inapp")
            .lacksConcreteTarget, "port/engine は実体ではない")
        let specs: [String: DeviceSpec] = [
            "osVersion": DeviceSpec(name: "d", osVersion: "iOS 27.0"),
            "udid": DeviceSpec(name: "d", udid: "XXXX"),
            "avd": DeviceSpec(name: "d", avd: "Pixel_9"),
            "serial": DeviceSpec(name: "d", serial: "emulator-5554"),
        ]
        XCTAssertEqual(Set(specs.keys), ProfileWriter.deviceBodyKeys)
        for (key, spec) in specs {
            XCTAssertFalse(spec.lacksConcreteTarget, "\(key) は実体")
        }
    }

    func testConcreteDeviceIsADeviceBody() {
        for body in [["osVersion": "iOS 27.0"], ["udid": "XXXX"],
                     ["avd": "Pixel_9"], ["serial": "emulator-5554"]] {
            var device: [String: Any] = ["platform": "ios", "machine": "local", "name": "device1"]
            for (key, value) in body { device[key] = value }
            XCTAssertTrue(ProfileWriter.hasDeviceBody(device), "\(body) は実体")
        }
    }
}
