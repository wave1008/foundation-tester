// ProfileResolverTests.swift
// 実行プロファイル(組み合わせ型)の合成・検証ロジックのテスト。

import XCTest
@testable import FTCore

final class ProfileResolverTests: XCTestCase {
    var tempDir: URL!
    var project: TestProject!

    override func setUpWithError() throws {
        tempDir = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("FTCoreTests-\(UUID().uuidString)")
        let root = tempDir.appendingPathComponent("Projects/SampleApp")
        project = TestProject(name: "SampleApp", rootURL: root)
        for dir in [project.appsDir, project.machinesDir, project.runsDir] {
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        }
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: tempDir)
    }

    private func write(_ json: String, to dir: URL, name: String) throws {
        try json.data(using: .utf8)!.write(to: dir.appendingPathComponent("\(name).json"))
    }

    private func writeStandardFixture() throws {
        try write("""
        { "common":  { "appName": "サンプルアプリ", "app": "com.example.sampleapp" },
          "ios":     { "appPath": "builds/SampleApp.app", "autoInstall": true },
          "android": { "appPath": "builds/app-debug.apk", "autoInstall": false } }
        """, to: project.appsDir, name: "sampleapp")
        try write("""
        { "ios":     { "devices": [
              { "name": "メイン機", "simulator": "iPhone 17 Pro", "os": "27.0", "udid": "AAAA-1111" },
              { "name": "サブ機", "simulator": "iPhone Air" } ] },
          "android": { "devices": [
              { "name": "エミュ1", "avd": "Pixel_9" },
              { "name": "エミュ2", "avd": "Pixel 8(Android 14)" } ] } }
        """, to: project.machinesDir, name: "M1 Max(64GB)")
        try write("""
        { "app": "sampleapp",
          "devices": [ { "name": "メイン機" }, { "name": "サブ機" }, { "name": "エミュ1" } ],
          "heal": true, "reportDir": "reports", "defaultTimeout": 8 }
        """, to: project.runsDir, name: "all")
    }

    // MARK: - 正常系

    func testResolveMixedPlatforms() throws {
        try writeStandardFixture()
        let resolved = try ProfileResolver.resolve(
            project: project, runName: "all", machineName: "M1 Max(64GB)")

        XCTAssertEqual(resolved.appName, "サンプルアプリ")
        XCTAssertEqual(resolved.machineName, "M1 Max(64GB)")
        XCTAssertEqual(resolved.devices.map(\.name), ["メイン機", "サブ機", "エミュ1"])
        XCTAssertEqual(resolved.iosDevices.count, 2)
        XCTAssertEqual(resolved.androidDevices.count, 1)
        XCTAssertTrue(resolved.heal)
        XCTAssertEqual(resolved.defaultTimeout, 8)
        XCTAssertTrue(resolved.warnings.isEmpty, "警告なしのはず: \(resolved.warnings)")

        // アプリ解決: common → platform セクションの後勝ちマージ
        let ios = try XCTUnwrap(resolved.apps["ios"])
        XCTAssertEqual(ios.bundleID, "com.example.sampleapp")
        XCTAssertEqual(ios.appPath, project.rootURL.appendingPathComponent("builds/SampleApp.app").path)
        XCTAssertTrue(ios.autoInstall)
        let android = try XCTUnwrap(resolved.apps["android"])
        XCTAssertEqual(android.bundleID, "com.example.sampleapp")
        XCTAssertFalse(android.autoInstall)

        // reportDir はプロジェクトルート基準の絶対パス
        XCTAssertEqual(resolved.reportDir.path,
                       project.rootURL.appendingPathComponent("reports").path)

        // UDID / avd がそのまま引き継がれる
        XCTAssertEqual(resolved.devices[0].spec.udid, "AAAA-1111")
        XCTAssertEqual(resolved.devices[2].spec.avd, "Pixel_9")
    }

    func testAppSectionOverridesCommon() throws {
        try write("""
        { "common":  { "appName": "A", "app": "com.example.common" },
          "android": { "app": "com.example.android" } }
        """, to: project.appsDir, name: "app2")
        try write("""
        { "android": { "devices": [ { "name": "d1", "avd": "Pixel_9" } ] } }
        """, to: project.machinesDir, name: "m")
        try write("""
        { "app": "app2", "devices": [ { "name": "d1" } ] }
        """, to: project.runsDir, name: "r")

        let resolved = try ProfileResolver.resolve(project: project, runName: "r", machineName: "m")
        XCTAssertEqual(resolved.apps["android"]?.bundleID, "com.example.android")
        XCTAssertNil(resolved.apps["ios"], "デバイスの無い platform のアプリは解決しない")
        XCTAssertEqual(resolved.apps["android"]?.autoInstall, true, "autoInstall の既定は true")
    }

    func testMissingDeviceIsSkippedWithWarning() throws {
        try writeStandardFixture()
        try write("""
        { "app": "sampleapp",
          "devices": [ { "name": "メイン機" }, { "name": "M2にしかない機" } ] }
        """, to: project.runsDir, name: "partial")

        let resolved = try ProfileResolver.resolve(
            project: project, runName: "partial", machineName: "M1 Max(64GB)")
        XCTAssertEqual(resolved.devices.map(\.name), ["メイン機"])
        XCTAssertEqual(resolved.warnings.count, 1)
        XCTAssertTrue(resolved.warnings[0].contains("M2にしかない機"))
    }

    func testTildeAndAbsolutePathResolution() throws {
        XCTAssertEqual(
            ProfileResolver.resolvePath("~/x/y.app", base: project.rootURL),
            (("~/x/y.app" as NSString).expandingTildeInPath))
        XCTAssertEqual(ProfileResolver.resolvePath("/abs/y.apk", base: project.rootURL),
                       "/abs/y.apk")
        XCTAssertEqual(ProfileResolver.resolvePath("rel/y.apk", base: project.rootURL),
                       project.rootURL.appendingPathComponent("rel/y.apk").path)
    }

    func testUnknownKeysProduceWarnings() throws {
        try writeStandardFixture()
        try write("""
        { "app": "sampleapp", "devices": [ { "name": "メイン機" } ], "maxParallel": 4 }
        """, to: project.runsDir, name: "typo")

        let resolved = try ProfileResolver.resolve(
            project: project, runName: "typo", machineName: "M1 Max(64GB)")
        XCTAssertTrue(resolved.warnings.contains { $0.contains("maxParallel") },
                      "未知キー警告が出るはず: \(resolved.warnings)")
    }

    // MARK: - マシン決定

    func testDetermineMachinePriority() throws {
        try writeStandardFixture()
        // FT_MACHINE が最優先
        var result = try ProfileResolver.determineMachine(
            project: project, environment: ["FT_MACHINE": "EnvMachine"], registered: "Reg")
        XCTAssertEqual(result.name, "EnvMachine")
        XCTAssertFalse(result.auto)
        // 次に登録名
        result = try ProfileResolver.determineMachine(
            project: project, environment: [:], registered: "Reg")
        XCTAssertEqual(result.name, "Reg")
        // 未登録でも machines/ が 1 ファイルなら自動採用
        result = try ProfileResolver.determineMachine(
            project: project, environment: [:], registered: nil)
        XCTAssertEqual(result.name, "M1 Max(64GB)")
        XCTAssertTrue(result.auto)
        // 複数ファイルならエラー
        try write("{}", to: project.machinesDir, name: "M2 Ultra(192GB)")
        XCTAssertThrowsError(try ProfileResolver.determineMachine(
            project: project, environment: [:], registered: nil)) { error in
            guard case ProfileError.machineUndetermined(let available) = error else {
                return XCTFail("machineUndetermined のはず: \(error)")
            }
            XCTAssertEqual(available, ["M1 Max(64GB)", "M2 Ultra(192GB)"])
        }
    }

    // MARK: - 異常系

    func testDuplicateDeviceNameAcrossPlatformsFails() throws {
        try writeStandardFixture()
        try write("""
        { "ios":     { "devices": [ { "name": "同名", "simulator": "iPhone Air" } ] },
          "android": { "devices": [ { "name": "同名", "avd": "Pixel_9" } ] } }
        """, to: project.machinesDir, name: "dup")
        try write("""
        { "app": "sampleapp", "devices": [ { "name": "同名" } ] }
        """, to: project.runsDir, name: "r")

        XCTAssertThrowsError(try ProfileResolver.resolve(
            project: project, runName: "r", machineName: "dup")) { error in
            guard case ProfileError.duplicateDeviceName(let name, _) = error else {
                return XCTFail("duplicateDeviceName のはず: \(error)")
            }
            XCTAssertEqual(name, "同名")
        }
    }

    func testNoDevicesResolvedFails() throws {
        try writeStandardFixture()
        try write("""
        { "app": "sampleapp", "devices": [ { "name": "存在しない" } ] }
        """, to: project.runsDir, name: "r")

        XCTAssertThrowsError(try ProfileResolver.resolve(
            project: project, runName: "r", machineName: "M1 Max(64GB)")) { error in
            guard case ProfileError.noDevicesResolved = error else {
                return XCTFail("noDevicesResolved のはず: \(error)")
            }
        }
    }

    func testMissingReferencesFail() throws {
        try writeStandardFixture()
        // 実行プロファイルが無い
        XCTAssertThrowsError(try ProfileResolver.resolve(
            project: project, runName: "nope", machineName: "M1 Max(64GB)")) { error in
            guard case ProfileError.runProfileNotFound(_, let available) = error else {
                return XCTFail("runProfileNotFound のはず: \(error)")
            }
            XCTAssertEqual(available, ["all"])
        }
        // apps 参照切れ
        try write("""
        { "app": "ghost", "devices": [ { "name": "メイン機" } ] }
        """, to: project.runsDir, name: "badapp")
        XCTAssertThrowsError(try ProfileResolver.resolve(
            project: project, runName: "badapp", machineName: "M1 Max(64GB)")) { error in
            guard case ProfileError.appProfileNotFound = error else {
                return XCTFail("appProfileNotFound のはず: \(error)")
            }
        }
        // マシンプロファイルが無い
        XCTAssertThrowsError(try ProfileResolver.resolve(
            project: project, runName: "all", machineName: "Nope")) { error in
            guard case ProfileError.machineProfileNotFound = error else {
                return XCTFail("machineProfileNotFound のはず: \(error)")
            }
        }
    }

    func testMissingBundleIDFails() throws {
        try write("""
        { "ios": { "appPath": "a.app" } }
        """, to: project.appsDir, name: "noid")
        try write("""
        { "ios": { "devices": [ { "name": "d", "simulator": "iPhone Air" } ] } }
        """, to: project.machinesDir, name: "m")
        try write("""
        { "app": "noid", "devices": [ { "name": "d" } ] }
        """, to: project.runsDir, name: "r")

        XCTAssertThrowsError(try ProfileResolver.resolve(
            project: project, runName: "r", machineName: "m")) { error in
            guard case ProfileError.missingBundleID(let platform, _) = error else {
                return XCTFail("missingBundleID のはず: \(error)")
            }
            XCTAssertEqual(platform, "ios")
        }
    }

    func testRunProfileWithoutAppOrDevicesFails() throws {
        try writeStandardFixture()
        try write(#"{ "devices": [ { "name": "メイン機" } ] }"#, to: project.runsDir, name: "noapp")
        XCTAssertThrowsError(try ProfileResolver.resolve(
            project: project, runName: "noapp", machineName: "M1 Max(64GB)")) { error in
            guard case ProfileError.missingAppReference = error else {
                return XCTFail("missingAppReference のはず: \(error)")
            }
        }
        try write(#"{ "app": "sampleapp" }"#, to: project.runsDir, name: "nodev")
        XCTAssertThrowsError(try ProfileResolver.resolve(
            project: project, runName: "nodev", machineName: "M1 Max(64GB)")) { error in
            guard case ProfileError.missingDevices = error else {
                return XCTFail("missingDevices のはず: \(error)")
            }
        }
    }
}
