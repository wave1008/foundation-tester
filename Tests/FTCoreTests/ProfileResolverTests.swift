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
        // common で有効なキーは appName と autoInstall。app/appPath は platform セクション
        try write("""
        { "common":  { "appName": "サンプルアプリ", "autoInstall": true },
          "ios":     { "app": "com.example.sampleapp", "appPath": "builds/SampleApp.app" },
          "android": { "app": "com.example.sampleapp", "appPath": "builds/app-debug.apk" } }
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
          "heal": true, "reportDir": "reports", "defaultTimeout": 8, "scenarioTimeout": 60 }
        """, to: project.runsDir, name: "all")
    }

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
        XCTAssertEqual(resolved.scenarioTimeout, 60, "scenarioTimeout が RunProfileDocument→ResolvedProfile へ透過する")
        XCTAssertTrue(resolved.warnings.isEmpty, "警告なしのはず: \(resolved.warnings)")

        let ios = try XCTUnwrap(resolved.apps["ios"])
        XCTAssertEqual(ios.bundleID, "com.example.sampleapp")
        XCTAssertEqual(ios.appPath, project.rootURL.appendingPathComponent("builds/SampleApp.app").path)
        XCTAssertTrue(ios.autoInstall, "common の autoInstall: true が両 platform に効く")
        let android = try XCTUnwrap(resolved.apps["android"])
        XCTAssertEqual(android.bundleID, "com.example.sampleapp")
        XCTAssertTrue(android.autoInstall, "common の autoInstall: true が両 platform に効く")

        XCTAssertEqual(resolved.reportDir.path,
                       project.rootURL.appendingPathComponent("reports").path)

        XCTAssertEqual(resolved.devices[0].spec.udid, "AAAA-1111")
        XCTAssertEqual(resolved.devices[2].spec.avd, "Pixel_9")
    }

    func testAppSectionOverridesCommon() throws {
        // common.app は廃止済みで resolve では無視される(validate は警告のみ)
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
        XCTAssertEqual(resolved.apps["android"]?.autoInstall, false,
                       "autoInstall の既定は false(無効)")
    }

    // MARK: - common セクションの app / appPath 廃止

    func testCommonAppNotInheritedFailsWithMissingBundleID() throws {
        try write("""
        { "common": { "app": "com.example.common" },
          "ios":    { "appPath": "a.app" } }
        """, to: project.appsDir, name: "app2")
        try write("""
        { "ios": { "devices": [ { "name": "d", "simulator": "iPhone Air" } ] } }
        """, to: project.machinesDir, name: "m")
        try write(#"{ "app": "app2", "devices": [ { "name": "d" } ] }"#,
                  to: project.runsDir, name: "r")

        XCTAssertThrowsError(try ProfileResolver.resolve(
            project: project, runName: "r", machineName: "m")) { error in
            guard case ProfileError.missingBundleID(let platform, _) = error else {
                return XCTFail("missingBundleID のはず: \(error)")
            }
            XCTAssertEqual(platform, "ios")
        }
    }

    func testCommonAppNotInheritedWhenPlatformSectionMissing() throws {
        try write("""
        { "common": { "app": "com.example.common" } }
        """, to: project.appsDir, name: "app2")
        try write("""
        { "ios": { "devices": [ { "name": "d", "simulator": "iPhone Air" } ] } }
        """, to: project.machinesDir, name: "m")
        try write(#"{ "app": "app2", "devices": [ { "name": "d" } ] }"#,
                  to: project.runsDir, name: "r")

        XCTAssertThrowsError(try ProfileResolver.resolve(
            project: project, runName: "r", machineName: "m")) { error in
            guard case ProfileError.missingBundleID = error else {
                return XCTFail("missingBundleID のはず: \(error)")
            }
        }
    }

    func testCommonAppPathNotInherited() throws {
        try write("""
        { "common": { "appPath": "common/x.app" },
          "ios":    { "app": "com.example.app" } }
        """, to: project.appsDir, name: "app2")
        try write("""
        { "ios": { "devices": [ { "name": "d", "simulator": "iPhone Air" } ] } }
        """, to: project.machinesDir, name: "m")
        try write(#"{ "app": "app2", "devices": [ { "name": "d" } ] }"#,
                  to: project.runsDir, name: "r")

        let resolved = try ProfileResolver.resolve(project: project, runName: "r", machineName: "m")
        XCTAssertNil(resolved.apps["ios"]?.appPath, "common の appPath は引き継がれないはず")
    }

    func testValidateWarnsOnDeprecatedCommonAppAndAppPath() throws {
        let data = #"""
        { "common": { "appName": "A", "app": "com.example.app", "appPath": "x.app" } }
        """#.data(using: .utf8)!

        let (errors, warnings) = ProfileResolver.validate(
            kind: .app, data: data, context: "apps/app2.json", project: project)
        XCTAssertTrue(errors.isEmpty, "警告のみでエラーにはしないはず: \(errors)")
        XCTAssertTrue(warnings.contains { $0.contains("common") && $0.contains("\"app\"")
                                          && $0.contains("廃止") },
                      "common.app 廃止警告が出るはず: \(warnings)")
        XCTAssertTrue(warnings.contains { $0.contains("common") && $0.contains("\"appPath\"")
                                          && $0.contains("廃止") },
                      "common.appPath 廃止警告が出るはず: \(warnings)")
        XCTAssertFalse(warnings.contains { $0.contains("appName") },
                       "common の appName は有効なので警告は出ないはず: \(warnings)")
    }

    func testValidateNoWarningWhenAppAndAppPathInPlatformSection() throws {
        let data = #"""
        { "common": { "appName": "A" },
          "ios":    { "app": "com.example.app", "appPath": "x.app" } }
        """#.data(using: .utf8)!

        let (errors, warnings) = ProfileResolver.validate(
            kind: .app, data: data, context: "apps/app2.json", project: project)
        XCTAssertTrue(errors.isEmpty, "エラーは出ないはず: \(errors)")
        XCTAssertTrue(warnings.isEmpty, "platform 側の指定では警告は出ないはず: \(warnings)")
    }

    // MARK: - autoInstall(common でのみ指定可+既定 false)

    func testAutoInstallExplicitTrueInCommonSectionIsEnabled() throws {
        try write("""
        { "common": { "autoInstall": true },
          "ios":    { "app": "com.example.app", "appPath": "a.app" } }
        """, to: project.appsDir, name: "app3")
        try write("""
        { "ios": { "devices": [ { "name": "d", "simulator": "iPhone Air" } ] } }
        """, to: project.machinesDir, name: "m")
        try write(#"{ "app": "app3", "devices": [ { "name": "d" } ] }"#,
                  to: project.runsDir, name: "r")

        let resolved = try ProfileResolver.resolve(project: project, runName: "r", machineName: "m")
        XCTAssertEqual(resolved.apps["ios"]?.autoInstall, true)
    }

    func testAutoInstallExplicitFalseInCommonSectionIsDisabled() throws {
        try write("""
        { "common": { "autoInstall": false },
          "ios":    { "app": "com.example.app", "appPath": "a.app" } }
        """, to: project.appsDir, name: "app3")
        try write("""
        { "ios": { "devices": [ { "name": "d", "simulator": "iPhone Air" } ] } }
        """, to: project.machinesDir, name: "m")
        try write(#"{ "app": "app3", "devices": [ { "name": "d" } ] }"#,
                  to: project.runsDir, name: "r")

        let resolved = try ProfileResolver.resolve(project: project, runName: "r", machineName: "m")
        XCTAssertEqual(resolved.apps["ios"]?.autoInstall, false)
    }

    func testAutoInstallUnspecifiedDefaultsToDisabled() throws {
        try write("""
        { "ios": { "app": "com.example.app", "appPath": "a.app" } }
        """, to: project.appsDir, name: "app3")
        try write("""
        { "ios": { "devices": [ { "name": "d", "simulator": "iPhone Air" } ] } }
        """, to: project.machinesDir, name: "m")
        try write(#"{ "app": "app3", "devices": [ { "name": "d" } ] }"#,
                  to: project.runsDir, name: "r")

        let resolved = try ProfileResolver.resolve(project: project, runName: "r", machineName: "m")
        XCTAssertEqual(resolved.apps["ios"]?.autoInstall, false,
                       "未指定時の既定は false(無効)")
    }

    func testAutoInstallInPlatformSectionIsIgnored() throws {
        try write("""
        { "ios": { "app": "com.example.app", "appPath": "a.app", "autoInstall": true } }
        """, to: project.appsDir, name: "app3")
        try write("""
        { "ios": { "devices": [ { "name": "d", "simulator": "iPhone Air" } ] } }
        """, to: project.machinesDir, name: "m")
        try write(#"{ "app": "app3", "devices": [ { "name": "d" } ] }"#,
                  to: project.runsDir, name: "r")

        let resolved = try ProfileResolver.resolve(project: project, runName: "r", machineName: "m")
        XCTAssertEqual(resolved.apps["ios"]?.autoInstall, false,
                       "platform セクションの autoInstall は無視されるはず")
    }

    func testAutoInstallPlatformValueDoesNotOverrideCommon() throws {
        try write("""
        { "common": { "autoInstall": false },
          "ios":    { "app": "com.example.app", "appPath": "a.app", "autoInstall": true } }
        """, to: project.appsDir, name: "app3")
        try write("""
        { "ios": { "devices": [ { "name": "d", "simulator": "iPhone Air" } ] } }
        """, to: project.machinesDir, name: "m")
        try write(#"{ "app": "app3", "devices": [ { "name": "d" } ] }"#,
                  to: project.runsDir, name: "r")

        let resolved = try ProfileResolver.resolve(project: project, runName: "r", machineName: "m")
        XCTAssertEqual(resolved.apps["ios"]?.autoInstall, false,
                       "common の autoInstall が platform 側の指定より優先されるはず")
    }

    func testSectionMergingFieldSources() throws {
        // resolve() を経由せず section(for:) を直接検証(platform セクション欠落ケース)
        let profile = AppProfile(common: AppProfileSection(
            appName: "A", app: "com.example.app", appPath: "x.app", autoInstall: true))
        let section = profile.section(for: "ios")
        XCTAssertEqual(section.appName, "A", "appName は common から引き継ぐ")
        XCTAssertNil(section.app, "common の app は引き継がれないはず")
        XCTAssertNil(section.appPath, "common の appPath は引き継がれないはず")
        XCTAssertEqual(section.autoInstall, true, "autoInstall は common から引き継ぐはず")
    }

    func testValidateWarnsOnDeprecatedPlatformAutoInstall() throws {
        let data = #"""
        { "common":  { "appName": "A" },
          "ios":     { "app": "com.example.app", "autoInstall": true },
          "android": { "app": "com.example.app", "autoInstall": false } }
        """#.data(using: .utf8)!

        let (errors, warnings) = ProfileResolver.validate(
            kind: .app, data: data, context: "apps/app3.json", project: project)
        XCTAssertTrue(errors.isEmpty, "警告のみでエラーにはしないはず: \(errors)")
        XCTAssertTrue(warnings.contains { $0.contains("ios") && $0.contains("autoInstall")
                                          && $0.contains("廃止") },
                      "ios.autoInstall 廃止警告が出るはず: \(warnings)")
        XCTAssertTrue(warnings.contains { $0.contains("android") && $0.contains("autoInstall")
                                          && $0.contains("廃止") },
                      "android.autoInstall 廃止警告が出るはず: \(warnings)")
    }

    func testValidateNoWarningWhenAutoInstallInCommonSection() throws {
        let data = #"""
        { "common": { "appName": "A", "autoInstall": true },
          "ios":    { "app": "com.example.app" } }
        """#.data(using: .utf8)!

        let (errors, warnings) = ProfileResolver.validate(
            kind: .app, data: data, context: "apps/app3.json", project: project)
        XCTAssertTrue(errors.isEmpty, "エラーは出ないはず: \(errors)")
        XCTAssertTrue(warnings.isEmpty,
                      "common の autoInstall は正当な設定場所なので警告は出ないはず: \(warnings)")
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

    // MARK: - 実行プロファイルの machine フィールド

    /// machine 指定による切り替えを確認するため、B 専用デバイスを持つ別マシンを追加する
    private func writeSecondMachineFixture() throws {
        try write("""
        { "ios": { "devices": [ { "name": "B専用機", "simulator": "iPad Pro" } ] } }
        """, to: project.machinesDir, name: "B")
    }

    func testResolveWithExplicitMachineOverridesPassedMachineName() throws {
        try writeStandardFixture()
        try writeSecondMachineFixture()
        try write("""
        { "app": "sampleapp", "devices": [ { "name": "B専用機" } ], "machine": "B" }
        """, to: project.runsDir, name: "withMachine")

        // 渡した "M1 Max(64GB)" より実行プロファイルの machine 指定("B")が優先される
        let resolved = try ProfileResolver.resolve(
            project: project, runName: "withMachine", machineName: "M1 Max(64GB)")
        XCTAssertEqual(resolved.machineName, "B")
        XCTAssertEqual(resolved.devices.map(\.name), ["B専用機"])
    }

    func testResolveWithExplicitMachineNotFoundFails() throws {
        try writeStandardFixture()
        try write("""
        { "app": "sampleapp", "devices": [ { "name": "メイン機" } ], "machine": "存在しない名前" }
        """, to: project.runsDir, name: "badMachine")

        XCTAssertThrowsError(try ProfileResolver.resolve(
            project: project, runName: "badMachine", machineName: "M1 Max(64GB)")) { error in
            guard case ProfileError.runSpecifiedMachineNotFound(let run, let machine, _) = error else {
                return XCTFail("runSpecifiedMachineNotFound のはず: \(error)")
            }
            XCTAssertEqual(run, "badMachine")
            XCTAssertEqual(machine, "存在しない名前")
        }
    }

    func testResolveWithoutMachineFieldUsesPassedMachineName() throws {
        // machine 未指定時に渡された machineName で解決されることの回帰検知
        // (testResolveMixedPlatforms 等、他の既存テストもこれを暗黙に前提としている)
        try writeStandardFixture()
        let resolved = try ProfileResolver.resolve(
            project: project, runName: "all", machineName: "M1 Max(64GB)")
        XCTAssertEqual(resolved.machineName, "M1 Max(64GB)")
    }

    func testDetermineMachineHonorsRunProfileMachine() throws {
        try writeStandardFixture()
        try writeSecondMachineFixture()
        try write("""
        { "app": "sampleapp", "devices": [ { "name": "B専用機" } ], "machine": "B" }
        """, to: project.runsDir, name: "withMachine")

        // FT_MACHINE/登録名より実行プロファイルの machine 指定が優先される
        let result = try ProfileResolver.determineMachine(
            project: project, environment: ["FT_MACHINE": "EnvMachine"], registered: "Reg",
            runProfileName: "withMachine")
        XCTAssertEqual(result.name, "B")
        XCTAssertFalse(result.auto)
    }

    func testDetermineMachineRunProfileMachineNotFoundFails() throws {
        try writeStandardFixture()
        try write("""
        { "app": "sampleapp", "devices": [ { "name": "メイン機" } ], "machine": "存在しない名前" }
        """, to: project.runsDir, name: "badMachine")

        XCTAssertThrowsError(try ProfileResolver.determineMachine(
            project: project, environment: [:], registered: nil,
            runProfileName: "badMachine")) { error in
            guard case ProfileError.runSpecifiedMachineNotFound = error else {
                return XCTFail("runSpecifiedMachineNotFound のはず: \(error)")
            }
        }
    }

    // MARK: - validate(kind: .run) の machine フィールド検証

    func testValidateRunMachineFieldTypeErrorWhenNotString() throws {
        try writeStandardFixture()
        let data = #"""
        { "app": "sampleapp", "devices": [ { "name": "メイン機" } ], "machine": 123 }
        """#.data(using: .utf8)!

        let (errors, _) = ProfileResolver.validate(
            kind: .run, data: data, context: "runs/typo.json", project: project)
        XCTAssertTrue(errors.contains { $0.contains("\"machine\"") && $0.contains("文字列") },
                      "machine 型不正エラーが出るはず: \(errors)")
    }

    func testValidateRunMachineFieldNotFoundError() throws {
        try writeStandardFixture()
        let data = #"""
        { "app": "sampleapp", "devices": [ { "name": "メイン機" } ], "machine": "存在しない名前" }
        """#.data(using: .utf8)!

        let (errors, _) = ProfileResolver.validate(
            kind: .run, data: data, context: "runs/badmachine.json", project: project)
        XCTAssertTrue(errors.contains { $0.contains("存在しない名前") },
                      "machine 参照先なしエラーが出るはず: \(errors)")
    }

    func testValidateRunMachineFieldUnspecifiedWarns() throws {
        try writeStandardFixture()
        let data = #"""
        { "app": "sampleapp", "devices": [ { "name": "メイン機" } ] }
        """#.data(using: .utf8)!

        let (errors, warnings) = ProfileResolver.validate(
            kind: .run, data: data, context: "runs/nomachine.json", project: project)
        XCTAssertTrue(errors.isEmpty, "machine 未指定はエラーにしないはず: \(errors)")
        XCTAssertTrue(warnings.contains { $0.contains("machine") && $0.contains("未指定") },
                      "machine 未指定警告が出るはず: \(warnings)")
    }

    func testValidateRunMachineFieldValidReferenceHasNoMachineErrorOrWarning() throws {
        try writeStandardFixture()
        let data = #"""
        { "app": "sampleapp", "devices": [ { "name": "メイン機" } ], "machine": "M1 Max(64GB)" }
        """#.data(using: .utf8)!

        let (errors, warnings) = ProfileResolver.validate(
            kind: .run, data: data, context: "runs/withmachine.json", project: project)
        XCTAssertTrue(errors.isEmpty, "machine 指定が正しければエラーは出ないはず: \(errors)")
        XCTAssertFalse(warnings.contains { $0.contains("未指定") },
                       "machine 指定済みなら未指定警告は出ないはず: \(warnings)")
    }

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

    // MARK: - iosInappEngine(iOS 実効エンジンの選択)

    func testIosInappEngineDefaultsToHybrid() throws {
        // iosInappEngine 未指定(既定 true)→ engine 未指定の iOS デバイスは hybrid。Android は不変。
        try writeStandardFixture()  // "all" は iosInappEngine 未指定
        let resolved = try ProfileResolver.resolve(
            project: project, runName: "all", machineName: "M1 Max(64GB)")
        XCTAssertEqual(resolved.iosDevices.map { $0.spec.engine }, ["hybrid", "hybrid"])
        XCTAssertNil(resolved.androidDevices.first?.spec.engine, "Android には影響しないはず")
    }

    func testIosInappEngineFalseUsesXcuitest() throws {
        try writeStandardFixture()
        try write("""
        { "app": "sampleapp", "devices": [ { "name": "メイン機" }, { "name": "サブ機" } ],
          "iosInappEngine": false }
        """, to: project.runsDir, name: "xc")
        let resolved = try ProfileResolver.resolve(
            project: project, runName: "xc", machineName: "M1 Max(64GB)")
        XCTAssertEqual(resolved.iosDevices.map { $0.spec.engine }, ["xcuitest", "xcuitest"])
    }

    func testExplicitDeviceEngineOverridesFlag() throws {
        // マシンでデバイスに engine を明示している場合はフラグより優先(上書きしない)。
        try write("""
        { "ios": { "app": "com.example.app" } }
        """, to: project.appsDir, name: "app4")
        try write("""
        { "ios": { "devices": [
              { "name": "注入機", "simulator": "iPhone 17 Pro", "engine": "inapp" },
              { "name": "素機", "simulator": "iPhone Air" } ] } }
        """, to: project.machinesDir, name: "m")
        // フラグ OFF(xcuitest 既定)でも engine 明示の "注入機" は inapp のまま、
        // 明示なしの "素機" はフラグどおり xcuitest。
        try write("""
        { "app": "app4", "devices": [ { "name": "注入機" }, { "name": "素機" } ],
          "iosInappEngine": false }
        """, to: project.runsDir, name: "r")
        let resolved = try ProfileResolver.resolve(project: project, runName: "r", machineName: "m")
        XCTAssertEqual(resolved.iosDevices.map { $0.spec.engine }, ["inapp", "xcuitest"])
        // フラグ明示 × デバイス engine 明示 → 「適用されません」警告(GUI チェックボックスの空振り検知)
        XCTAssertTrue(resolved.warnings.contains { $0.contains("注入機") && $0.contains("適用されません") },
                      "engine 明示デバイスへのフラグ空振り警告が出るはず: \(resolved.warnings)")
        XCTAssertFalse(resolved.warnings.contains { $0.contains("素機") },
                       "engine 無指定デバイスには警告を出さないはず: \(resolved.warnings)")
    }

    func testNoWarningWhenFlagUnspecifiedWithExplicitDeviceEngine() throws {
        // フラグ未指定(既定)なら engine 明示デバイスがあっても警告しない(従来プロファイルを騒がせない)
        try write("""
        { "ios": { "app": "com.example.app" } }
        """, to: project.appsDir, name: "app5")
        try write("""
        { "ios": { "devices": [ { "name": "注入機", "simulator": "iPhone 17 Pro", "engine": "inapp" } ] } }
        """, to: project.machinesDir, name: "m")
        try write("""
        { "app": "app5", "devices": [ { "name": "注入機" } ] }
        """, to: project.runsDir, name: "r")
        let resolved = try ProfileResolver.resolve(project: project, runName: "r", machineName: "m")
        XCTAssertFalse(resolved.warnings.contains { $0.contains("適用されません") },
                       "フラグ未指定では警告しないはず: \(resolved.warnings)")
    }

    // MARK: - wipeDataOnBloat / wipeDataThresholdGB

    func testWipeDataDefaultsWhenUnspecified() throws {
        try writeStandardFixture()  // "all" は wipeDataOnBloat/wipeDataThresholdGB 未指定
        let resolved = try ProfileResolver.resolve(
            project: project, runName: "all", machineName: "M1 Max(64GB)")
        XCTAssertTrue(resolved.wipeDataOnBloat, "省略時は既定 true(ON)のはず")
        XCTAssertEqual(resolved.wipeDataThresholdGB, 8, "省略時は既定 8GB のはず")
    }

    func testWipeDataExplicitValuesAreReflected() throws {
        try writeStandardFixture()
        try write("""
        { "app": "sampleapp", "devices": [ { "name": "メイン機" } ],
          "wipeDataOnBloat": false, "wipeDataThresholdGB": 3.5 }
        """, to: project.runsDir, name: "wipe")
        let resolved = try ProfileResolver.resolve(
            project: project, runName: "wipe", machineName: "M1 Max(64GB)")
        XCTAssertFalse(resolved.wipeDataOnBloat)
        XCTAssertEqual(resolved.wipeDataThresholdGB, 3.5)
    }

    func testWipeDataThresholdZeroOrLessFails() throws {
        try writeStandardFixture()
        try write("""
        { "app": "sampleapp", "devices": [ { "name": "メイン機" } ], "wipeDataThresholdGB": 0 }
        """, to: project.runsDir, name: "badThreshold")
        XCTAssertThrowsError(try ProfileResolver.resolve(
            project: project, runName: "badThreshold", machineName: "M1 Max(64GB)")) { error in
            guard case ProfileError.invalidWipeDataThreshold(let run) = error else {
                return XCTFail("invalidWipeDataThreshold のはず: \(error)")
            }
            XCTAssertEqual(run, "badThreshold")
        }

        try write("""
        { "app": "sampleapp", "devices": [ { "name": "メイン機" } ], "wipeDataThresholdGB": -2 }
        """, to: project.runsDir, name: "negativeThreshold")
        XCTAssertThrowsError(try ProfileResolver.resolve(
            project: project, runName: "negativeThreshold", machineName: "M1 Max(64GB)")) { error in
            guard case ProfileError.invalidWipeDataThreshold = error else {
                return XCTFail("invalidWipeDataThreshold のはず: \(error)")
            }
        }
    }

    func testValidateRunWipeDataThresholdZeroOrLessErrors() throws {
        try writeStandardFixture()
        let data = #"""
        { "app": "sampleapp", "devices": [ { "name": "メイン機" } ], "wipeDataThresholdGB": 0 }
        """#.data(using: .utf8)!

        let (errors, _) = ProfileResolver.validate(
            kind: .run, data: data, context: "runs/badThreshold.json", project: project)
        XCTAssertTrue(errors.contains { $0.contains("wipeDataThresholdGB") },
                      "wipeDataThresholdGB エラーが出るはず: \(errors)")
    }

    // MARK: - locale

    func testLocaleDefaultsWhenUnspecified() throws {
        try writeStandardFixture()  // "all" は locale 未指定
        let resolved = try ProfileResolver.resolve(
            project: project, runName: "all", machineName: "M1 Max(64GB)")
        XCTAssertEqual(resolved.locale, "ja_JP", "省略時は既定 ja_JP のはず")
    }

    func testLocaleExplicitValueIsReflected() throws {
        try writeStandardFixture()
        try write("""
        { "app": "sampleapp", "devices": [ { "name": "メイン機" } ], "locale": "en-US" }
        """, to: project.runsDir, name: "locale")
        let resolved = try ProfileResolver.resolve(
            project: project, runName: "locale", machineName: "M1 Max(64GB)")
        XCTAssertEqual(resolved.locale, "en-US")
    }

    func testLocaleInvalidFormatFails() throws {
        try writeStandardFixture()
        for (name, value) in [("badLocaleSpace", "ja JP"), ("badLocaleEmpty", ""),
                               ("badLocaleNonAscii", "日本語")] {
            try write("""
            { "app": "sampleapp", "devices": [ { "name": "メイン機" } ], "locale": "\(value)" }
            """, to: project.runsDir, name: name)
            XCTAssertThrowsError(try ProfileResolver.resolve(
                project: project, runName: name, machineName: "M1 Max(64GB)")) { error in
                guard case ProfileError.invalidLocale(let run) = error else {
                    return XCTFail("invalidLocale のはず(\(name)): \(error)")
                }
                XCTAssertEqual(run, name)
            }
        }
    }

    func testValidateRunLocaleInvalidFormatErrors() throws {
        try writeStandardFixture()
        let data = #"""
        { "app": "sampleapp", "devices": [ { "name": "メイン機" } ], "locale": "ja JP" }
        """#.data(using: .utf8)!

        let (errors, _) = ProfileResolver.validate(
            kind: .run, data: data, context: "runs/badLocale.json", project: project)
        XCTAssertTrue(errors.contains { $0.contains("locale") },
                      "locale エラーが出るはず: \(errors)")
    }
}
