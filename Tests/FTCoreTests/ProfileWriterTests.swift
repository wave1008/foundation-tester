// アプリ/実行プロファイルを揃えて書く純粋ロジック(`fleetest profile setup` の中身)。
import XCTest
@testable import FTCore

final class ProfileWriterTests: XCTestCase {

    func testAppProfilePlacesFieldsInFixedSections() {
        let object = ProfileWriter.mergingAppProfile(
            into: [:], platform: "ios", appName: "MyApp", defaultAppName: "Project",
            appID: "com.example.myapp", appPath: "~/builds/MyApp.app")
        XCTAssertNil(object["common"], "common セクションは廃止")
        XCTAssertNil(object["appName"], "appName は最上位に書かない(platform セクションのみ)")
        XCTAssertNil(object["autoInstall"],
                     "書かない(未指定 = appPath の有無で決まる。false を焼き付けない)")
        XCTAssertNil(object["app"], "app は platform セクションにだけ置く")
        let ios = object["ios"] as? [String: Any]
        XCTAssertEqual(ios?["appName"] as? String, "MyApp", "appName は platform セクションに書く")
        XCTAssertEqual(ios?["app"] as? String, "com.example.myapp")
        XCTAssertEqual(ios?["appPath"] as? String, "~/builds/MyApp.app")
    }

    /// ios と android を別々に呼べば、それぞれ別の表示名を持てる(この契約変更の核)
    func testAppProfileAllowsDifferentAppNamePerPlatform() {
        var object = ProfileWriter.mergingAppProfile(
            into: [:], platform: "ios", appName: "MyApp (iOS)", defaultAppName: "Project",
            appID: "com.example.myapp", appPath: nil)
        object = ProfileWriter.mergingAppProfile(
            into: object, platform: "android", appName: "MyApp (Android)", defaultAppName: "Project",
            appID: "com.example.myapp", appPath: nil)
        XCTAssertEqual((object["ios"] as? [String: Any])?["appName"] as? String, "MyApp (iOS)")
        XCTAssertEqual((object["android"] as? [String: Any])?["appName"] as? String, "MyApp (Android)")
    }

    /// 省略は「既存を残す」。デバイスを足すために appPath / appName 無しで呼び直しても、
    /// 先に書いた appPath(= 自動インストール)と表示名を消さない。autoInstall も書かない
    func testOmittedAppPathAndNameKeepExistingValues() {
        let first = ProfileWriter.mergingAppProfile(
            into: [:], platform: "android", appName: "Shop", defaultAppName: "Project",
            appID: "com.a", appPath: "~/a.apk")
        let again = ProfileWriter.mergingAppProfile(
            into: first, platform: "android", appName: nil, defaultAppName: "Project",
            appID: "com.a", appPath: nil)
        let section = again["android"] as? [String: Any]
        XCTAssertEqual(section?["appPath"] as? String, "~/a.apk")
        XCTAssertEqual(section?["appName"] as? String, "Shop")
        XCTAssertNil(again["autoInstall"])
    }

    /// 対象 OS は必ず書く(省略 = hybrid なので、書かないと iOS だけで作っても両 OS 対象になる)
    func testNewAppProfileTargetsOnlyTheRequestedPlatform() {
        let ios = ProfileWriter.mergingAppProfile(
            into: [:], platform: "ios", appName: "A", defaultAppName: "Project", appID: "com.a", appPath: nil)
        XCTAssertEqual(ios["platform"] as? String, "ios")
        let android = ProfileWriter.mergingAppProfile(
            into: [:], platform: "android", appName: "A", defaultAppName: "Project", appID: "com.a", appPath: nil)
        XCTAssertEqual(android["platform"] as? String, "android")
    }

    /// 同じ OS の呼び直しは狭めも広げもしない。別の OS を足すと hybrid(--platform hybrid は ios → android の順に呼ぶ)
    func testAddingTheOtherPlatformMakesItHybrid() {
        let ios = ProfileWriter.mergingAppProfile(
            into: [:], platform: "ios", appName: "A", defaultAppName: "Project", appID: "com.a", appPath: nil)
        let again = ProfileWriter.mergingAppProfile(
            into: ios, platform: "ios", appName: nil, defaultAppName: "Project", appID: "com.a", appPath: nil)
        XCTAssertEqual(again["platform"] as? String, "ios")
        let both = ProfileWriter.mergingAppProfile(
            into: ios, platform: "android", appName: "A", defaultAppName: "Project", appID: "com.a", appPath: nil)
        XCTAssertEqual(both["platform"] as? String, "hybrid")
        let stillBoth = ProfileWriter.mergingAppProfile(
            into: both, platform: "ios", appName: nil, defaultAppName: "Project", appID: "com.a", appPath: nil)
        XCTAssertEqual(stillBoth["platform"] as? String, "hybrid", "hybrid を片方の OS へ狭めない")
    }

    /// platform キーの無い既存(= resolve は hybrid と読む)は、セクションがあれば hybrid のまま書き出す
    func testExistingProfileWithoutPlatformKeyStaysHybrid() {
        let legacy: [String: Any] = ["ios": ["app": "com.a", "appName": "A"]]
        XCTAssertEqual(ProfileWriter.mergedAppPlatform(existing: legacy, adding: "ios"), "hybrid")
        XCTAssertEqual(ProfileWriter.mergedAppPlatform(existing: ["platform": "IOS"], adding: "ios"), "hybrid",
                       "読めない値は狭めない")
        XCTAssertEqual(ProfileWriter.mergedAppPlatform(existing: ["autoInstall": false], adding: "android"), "android",
                       "OS のセクションが無ければ新規と同じ")
    }

    /// --app-ref の省略は「既存の実行プロファイルのアプリ」。無ければプロジェクト名の小文字。明示が最優先
    func testAppRefFollowsExistingRunProfileWhenOmitted() {
        XCTAssertEqual(ProfileWriter.resolvedAppRef(
            explicit: nil, existingRunProfile: ["app": "sut-store"], projectName: "TutVerify"), "sut-store")
        XCTAssertEqual(ProfileWriter.resolvedAppRef(
            explicit: nil, existingRunProfile: [:], projectName: "TutVerify"), "tutverify")
        XCTAssertEqual(ProfileWriter.resolvedAppRef(
            explicit: "other", existingRunProfile: ["app": "sut-store"], projectName: "TutVerify"), "other")
    }

    /// 表示名が既存にも無いときだけ defaultAppName(プロジェクト名)を書く
    func testOmittedAppNameFallsBackToDefaultOnlyWhenAbsent() {
        let object = ProfileWriter.mergingAppProfile(
            into: [:], platform: "ios", appName: nil, defaultAppName: "Project",
            appID: "com.a", appPath: nil)
        XCTAssertEqual((object["ios"] as? [String: Any])?["appName"] as? String, "Project")
        XCTAssertNil((object["ios"] as? [String: Any])?["appPath"])
    }

    /// 利用者が明示した autoInstall は温存する(こちらの都合で消さない)
    func testAppProfileKeepsExplicitAutoInstall() {
        var object = ProfileWriter.mergingAppProfile(
            into: [:], platform: "ios", appName: "A", defaultAppName: "Project", appID: "com.a", appPath: "~/a.app")
        object["autoInstall"] = false          // 利用者が opt-out した状態
        let updated = ProfileWriter.mergingAppProfile(
            into: object, platform: "ios", appName: "A", defaultAppName: "Project", appID: "com.a", appPath: "~/a.app")
        XCTAssertEqual(updated["autoInstall"] as? Bool, false,
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
