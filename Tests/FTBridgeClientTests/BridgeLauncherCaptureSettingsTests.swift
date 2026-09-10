// BridgeLauncher.injectPort が XCTest の自動記録を止める設定を xctestrun へ書くこと。
//
// ビルドが書く既定は「動画で撮る・成功したら捨てる」で、**終わらない UI テストであるブリッジでは
// 捨てる時点が永久に来ず**、誰も読まない動画がシミュレータ内に溜まり続けた(実測 870 GB)。
// 実測(E2E-iOS の XCUITest 3本): 既定 = 動画 4 本・59.8 MB 増 / この設定 = 増加 0・合否と所要は同じ。
// **期待値はリテラル**(`captureSettings` から導くと、値を戻す変更が緑のまま通る)。
// 新形式(TestConfigurations[].TestTargets[])と旧形式(トップレベルに対象の辞書)の両方を見る ——
// 実際のビルドが書くのは旧形式で、新形式だけを試すと実物の経路を1度も通らない。

import XCTest
@testable import FTBridgeClient

final class BridgeLauncherCaptureSettingsTests: XCTestCase {
    private var root: URL!

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("ft-launcher-capture-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: root)
    }

    /// ビルドが書く既定(動画・成功時に捨てる)を持った対象の辞書
    private var buildDefaultTarget: [String: Any] {
        ["TestBundlePath": "FleetestRunnerUITests.xctest",
         "EnvironmentVariables": [String: Any](),
         "PreferredScreenCaptureFormat": "screenRecording",
         "SystemAttachmentLifetime": "deleteOnSuccess",
         "UserAttachmentLifetime": "deleteOnSuccess"]
    }

    private func write(_ plist: [String: Any], name: String) throws -> URL {
        let url = root.appendingPathComponent("\(name).xctestrun")
        try PropertyListSerialization.data(fromPropertyList: plist, format: .xml, options: 0).write(to: url)
        return url
    }

    private func read(_ url: URL) throws -> [String: Any] {
        let data = try Data(contentsOf: url)
        return try XCTUnwrap(PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any])
    }

    private func assertRecordingOff(_ target: [String: Any], file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertEqual(target["PreferredScreenCaptureFormat"] as? String, "screenshots",
                       "画面を動画で撮り続ける(終わらないテストでは永久に捨てられない)", file: file, line: line)
        XCTAssertEqual(target["SystemAttachmentLifetime"] as? String, "keepNever", file: file, line: line)
        XCTAssertEqual(target["UserAttachmentLifetime"] as? String, "keepNever", file: file, line: line)
    }

    /// 実際のビルドが書く旧形式
    func testLegacyFormatGetsRecordingTurnedOff() throws {
        let launcher = BridgeLauncher(repoRoot: root, device: "iPhone 17", port: 8911, physical: false)
        let url = try write(["FleetestRunnerUITests": buildDefaultTarget,
                             "__xctestrun_metadata__": ["FormatVersion": 1]], name: "legacy")
        let injected = try read(try launcher.injectPort(into: url))
        assertRecordingOff(try XCTUnwrap(injected["FleetestRunnerUITests"] as? [String: Any]))
    }

    /// 新形式(TestConfigurations[].TestTargets[])
    func testCurrentFormatGetsRecordingTurnedOff() throws {
        let launcher = BridgeLauncher(repoRoot: root, device: "iPhone 17", port: 8912, physical: false)
        let url = try write(["TestConfigurations": [["TestTargets": [buildDefaultTarget]]]], name: "current")
        let injected = try read(try launcher.injectPort(into: url))
        let configurations = try XCTUnwrap(injected["TestConfigurations"] as? [[String: Any]])
        let target = try XCTUnwrap((configurations.first?["TestTargets"] as? [[String: Any]])?.first)
        assertRecordingOff(target)
    }

    /// 結果の束と作業フォルダを**固定の場所**に渡す。渡さないと Xcode が既定の DerivedData に
    /// 起動ごとの新しいフォルダを作り、誰も読まない結果の束を積む(実測 100 個・1.8 GB)
    func testLaunchPinsTheResultBundleAndDerivedDataPerPort() {
        let launcher = BridgeLauncher(repoRoot: root, device: "iPhone 17", port: 8914, physical: false)
        let args = launcher.testWithoutBuildingArguments(xctestrun: root.appendingPathComponent("x.xctestrun"))
        func value(after flag: String) -> String? {
            args.firstIndex(of: flag).flatMap { args.indices.contains($0 + 1) ? args[$0 + 1] : nil }
        }
        XCTAssertEqual(value(after: "-resultBundlePath"),
                       root.appendingPathComponent(".fleetest/xcresult/bridge-8914.xcresult").path,
                       "結果の束が既定の場所へ積まれる")
        XCTAssertEqual(value(after: "-derivedDataPath"), launcher.derivedDataPath.path,
                       "既定の DerivedData に空のフォルダが起動ごとに増える")
    }

    /// 実機のランナーにも同じ設定を書く(実機の端末内はホストの掃除の対象外なので、作らせないのが唯一の手)
    func testPhysicalDeviceGetsRecordingTurnedOffToo() throws {
        let launcher = BridgeLauncher(repoRoot: root, device: "00008130-000A1B2C3D4E5678",
                                      port: 8913, physical: true)
        let url = try write(["FleetestRunnerUITests": buildDefaultTarget], name: "physical")
        let injected = try read(try launcher.injectPort(into: url))
        assertRecordingOff(try XCTUnwrap(injected["FleetestRunnerUITests"] as? [String: Any]))
    }
}
