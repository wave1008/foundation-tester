// **回す本数を超える台数を用意しない**(ResolvedProfile.deviceKeepCount)。
//
// 1本のシナリオでもプロファイルの全台にブリッジを供給しアプリの版を確認していたため、
// 実測で iOS の固定費が 14.8s(合計 21.8s のうちテスト実行は 7.0s)あった。絞ると 2.9s。
// 守るのは両方向 —— **絞りすぎ**(全件実行で並列度が死ぬ)と**予備の復活**(本数を超える台を用意する。
// 予備を廃止した理由は maintainer-notes §103)の両方を落とす。

import XCTest
@testable import FTCore

final class ResolvedProfileDeviceLimitTests: XCTestCase {

    /// 1本なら1台(予備は置かない)
    func testOneScenarioKeepsOneDevice() {
        XCTAssertEqual(ResolvedProfile.deviceKeepCount(available: 10, scenarios: 1), 1)
    }

    /// **本数を超える台を用意しない**(予備を置かない)
    func testKeepsExactlyTheScenarioCount() {
        XCTAssertEqual(ResolvedProfile.deviceKeepCount(available: 10, scenarios: 3), 3)
    }

    /// **絞りすぎない**: 本数が台数以上なら全台(全件実行で並列度を落とさない)
    func testManyScenariosKeepEveryDevice() {
        XCTAssertEqual(ResolvedProfile.deviceKeepCount(available: 4, scenarios: 50), 4)
        XCTAssertEqual(ResolvedProfile.deviceKeepCount(available: 4, scenarios: 4), 4)
    }

    /// 本数が分からない(nil = 一覧の前に台数を決める経路で ID が `Class.method` だけでない)なら絞らない
    func testUnknownScenarioCountDoesNotLimit() {
        XCTAssertEqual(ResolvedProfile.deviceKeepCount(available: 8, scenarios: nil), 8)
    }

    /// **0 は「分からない」ではない** —— その OS で走るシナリオが無い = 1台も用意しない
    func testZeroScenariosKeepsNoDevice() {
        XCTAssertEqual(ResolvedProfile.deviceKeepCount(available: 8, scenarios: 0), 0)
    }

    /// 台数より多く要求しても台数を超えない
    func testNeverExceedsAvailable() {
        XCTAssertEqual(ResolvedProfile.deviceKeepCount(available: 2, scenarios: 3), 2)
    }

    // MARK: - platform 未宣言のシナリオの数え方(実行時の既定 platform と同じ規則)

    private func device(_ name: String, _ platform: String) -> ResolvedDevice {
        ResolvedDevice(platform: platform, spec: DeviceSpec(name: name, kind: .physical, udid: "U-\(name)"))
    }

    private func profile(_ devices: [ResolvedDevice]) -> ResolvedProfile {
        ResolvedProfile(
            project: TestProject(name: "dummy", rootURL: URL(fileURLWithPath: "/tmp/dummy")),
            runName: "r", appName: "app", apps: [:],
            devices: devices, fm: FMConfig(), heal: false,
            reportDir: URL(fileURLWithPath: "/tmp/dummy/reports"),
            defaultTimeout: nil, scenarioTimeout: nil, wipeDataOnBloat: true, updateWebView: false,
            wipeDataThresholdGB: 8, recoverCpuFallbackToGpu: false, locale: "ja_JP",
            iosPreActionPing: true, containerInference: true, ocrTextVisibilityCheck: true,
            preferCheckStateClassifier: true,
            enableAnimations: false, responseMeasurement: false, responseRepeat: 5,
            homeOnStart: true, playProtectBypass: true, record: false, recordFailuresOnly: false,
            recordBitrateKbps: 1500, recordFullResolution: false, warnings: [])
    }

    /// 混在プロファイルでは未宣言のシナリオは iOS でだけ走るので、Android の本数に数えない
    func testUndeclaredScenariosCountOnlyTowardIOSInAMixedProfile() {
        let mixed = profile([device("i1", "ios"), device("a1", "android")])
        XCTAssertEqual(mixed.undeclaredScenarioPlatform, "ios")
        let counts = mixed.scenarioCounts(platforms: [nil, nil, "android"])
        XCTAssertEqual(counts.ios, 2)
        XCTAssertEqual(counts.android, 1)
    }

    /// iOS のデバイスが無ければ未宣言は Android に数える
    func testUndeclaredScenariosCountTowardAndroidWithoutIOSDevices() {
        let androidOnly = profile([device("a1", "android"), device("a2", "android")])
        XCTAssertEqual(androidOnly.undeclaredScenarioPlatform, "android")
        XCTAssertEqual(androidOnly.scenarioCounts(platforms: [nil, "ios"]).android, 1)
    }

    /// 未宣言1本を混在プロファイルで回すと iOS の1台だけを用意する(走らない Android の台を用意しない)
    func testOneUndeclaredScenarioInAMixedProfileKeepsOnlyOneIOSDevice() {
        let mixed = profile([device("i1", "ios"), device("i2", "ios"), device("a1", "android"), device("a2", "android")])
        let counts = mixed.scenarioCounts(platforms: [nil])
        let limited = mixed.limitingDevices(iosScenarios: counts.ios, androidScenarios: counts.android,
                                            avoiding: { _ in false })
        XCTAssertEqual(limited.devices.map(\.name), ["i1"])
    }

    /// 本数が分からない(nil)の OS は今までどおり全台を残す(一覧の前に台数を決める経路)
    func testUnknownCountKeepsEveryDeviceOfThatPlatform() {
        let mixed = profile([device("i1", "ios"), device("i2", "ios"), device("a1", "android")])
        let limited = mixed.limitingDevices(iosScenarios: nil, androidScenarios: 0, avoiding: { _ in false })
        XCTAssertEqual(limited.devices.map(\.name), ["i1", "i2"])
    }
}
