import XCTest
@testable import FTCore

final class ProfileResolverTests: XCTestCase {
    var tempDir: URL!
    var project: TestProject!

    override func setUpWithError() throws {
        tempDir = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("FTCoreTests-\(UUID().uuidString)")
        let root = tempDir.appendingPathComponent("TestProjects/SampleApp")
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
        // common で有効なキーは autoInstall のみ。appName/app/appPath は platform セクション
        try write("""
        { "common":  { "autoInstall": true },
          "ios":     { "appName": "サンプルアプリ", "app": "com.example.sampleapp", "appPath": "builds/SampleApp.app" },
          "android": { "appName": "サンプルアプリ", "app": "com.example.sampleapp", "appPath": "builds/app-debug.apk" } }
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
        // 原本(sourcePath)の相対パスはリポジトリルート基準(= project.rootURL の 2 階層上 = tempDir)。
        // インストールに使う appPath は既定ワークスペースの apps/ へ向く(docs/remote-runner.md §17)
        XCTAssertEqual(ios.sourcePath,
                       tempDir.appendingPathComponent("builds/SampleApp.app").path,
                       "appPath 相対はリポジトリルート(<repoRoot>/TestProjects/<name> の 2 階層上)基準")
        XCTAssertEqual(ios.appPath,
                       project.rootURL.appendingPathComponent("workspace/apps/SampleApp.app").path,
                       "インストール元は既定ワークスペースのステージ先")
        XCTAssertTrue(ios.autoInstall, "common の autoInstall: true が両 platform に効く")
        let android = try XCTUnwrap(resolved.apps["android"])
        XCTAssertEqual(android.bundleID, "com.example.sampleapp")
        XCTAssertEqual(android.sourcePath,
                       tempDir.appendingPathComponent("builds/app-debug.apk").path,
                       "android の appPath 相対もリポジトリルート基準")
        XCTAssertEqual(android.appPath,
                       project.rootURL.appendingPathComponent("workspace/apps/app-debug.apk").path,
                       "android のインストール元も既定ワークスペースのステージ先")
        XCTAssertTrue(android.autoInstall, "common の autoInstall: true が両 platform に効く")

        XCTAssertEqual(resolved.reportDir.path,
                       project.rootURL.appendingPathComponent("reports").path)

        XCTAssertEqual(resolved.devices[0].spec.udid, "AAAA-1111")
        XCTAssertEqual(resolved.devices[2].spec.avd, "Pixel_9")
    }

    /// defaultTimeout が小数(秒未満)でも解決できること(Int→Double 化の回帰ガード)。
    /// 整数 JSON との後方互換は testResolveMixedPlatforms(8)で別途固定済み
    func testResolveAcceptsFractionalDefaultTimeout() throws {
        try writeStandardFixture()
        try write("""
        { "app": "sampleapp", "devices": [ { "name": "メイン機" } ], "defaultTimeout": 1.5 }
        """, to: project.runsDir, name: "fractional")
        let resolved = try ProfileResolver.resolve(
            project: project, runName: "fractional", machineName: "M1 Max(64GB)")
        XCTAssertEqual(resolved.defaultTimeout, 1.5)
    }

    func testAppSectionOverridesCommon() throws {
        // common.app は廃止済みで resolve では無視される(validate は警告のみ)
        try write("""
        { "common":  { "app": "com.example.common" },
          "android": { "appName": "A", "app": "com.example.android" } }
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
                       "appPath が無ければ入れようがないので既定は無効")
    }

    /// false を明示したときだけ止まる(opt-out)
    func testExplicitFalseOptsOutEvenWithAppPath() throws {
        try write("""
        { "common": { "autoInstall": false },
          "android": { "appName": "アプリ", "app": "com.example.android", "appPath": "builds/app.apk" } }
        """, to: project.appsDir, name: "app4")
        try write("""
        { "android": { "devices": [ { "name": "d1", "avd": "Pixel_9" } ] } }
        """, to: project.machinesDir, name: "m")
        try write("""
        { "app": "app4", "devices": [ { "name": "d1" } ] }
        """, to: project.runsDir, name: "r")

        let resolved = try ProfileResolver.resolve(project: project, runName: "r", machineName: "m")
        XCTAssertEqual(resolved.apps["android"]?.autoInstall, false)
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
        { "common": { "app": "com.example.app", "appPath": "x.app" } }
        """#.data(using: .utf8)!

        let (errors, warnings) = ProfileResolver.validate(
            kind: .app, data: data, context: "apps/app2.json", project: project)
        XCTAssertTrue(errors.isEmpty, "警告のみでエラーにはしないはず: \(errors)")
        XCTAssertTrue(warnings.contains { $0.contains("common") && $0.contains("\"app\"")
                                          && $0.contains("deprecated") },
                      "common.app 廃止警告が出るはず: \(warnings)")
        XCTAssertTrue(warnings.contains { $0.contains("common") && $0.contains("\"appPath\"")
                                          && $0.contains("deprecated") },
                      "common.appPath 廃止警告が出るはず: \(warnings)")
    }

    /// 読まなくなった `iosSystemAlertButtons` は、**validate 経路でも**行き先を案内する
    /// (resolve だけだと `profile check`/エディタで沈黙する ← レビュー指摘 2026-08-22)
    func testValidateWarnsWhenLegacySystemAlertKeyPresent() throws {
        let data = #"""
        { "app": "sampleapp", "devices": [{ "name": "x" }],
          "iosSystemAlertButtons": ["許可"] }
        """#.data(using: .utf8)!
        let (_, warnings) = ProfileResolver.validate(
            kind: .run, data: data, context: "runs/legacy.json", project: project)
        XCTAssertTrue(warnings.contains { $0.contains("iosSystemAlertButtons")
                                          && $0.contains("iosAlertHandler") },
                      "旧キーの行き先(iosAlertHandler)を案内する警告が出るはず: \(warnings)")
    }

    /// common.appName は廃止(この契約変更の核): 黙って無視せず、ios/android への移動を促す
    /// 警告が出ること
    func testValidateWarnsWhenAppNameInCommonSection() throws {
        let data = #"""
        { "common": { "appName": "A" }, "ios": { "app": "com.example.app" } }
        """#.data(using: .utf8)!

        let (errors, warnings) = ProfileResolver.validate(
            kind: .app, data: data, context: "apps/app2.json", project: project)
        XCTAssertTrue(errors.isEmpty, "警告のみでエラーにはしないはず: \(errors)")
        XCTAssertTrue(warnings.contains { $0.contains("common") && $0.contains("\"appName\"")
                                          && $0.contains("ios/android") },
                      "common.appName は ios/android への移動を促す警告が出るはず: \(warnings)")
    }

    func testValidateNoWarningWhenAppAndAppPathInPlatformSection() throws {
        let data = #"""
        { "ios": { "appName": "A", "app": "com.example.app", "appPath": "x.app" } }
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

    /// **appPath があれば既定で有効**(パスを書いたのに入らない方が事故だった)
    func testAutoInstallUnspecifiedFollowsAppPath() throws {
        try write("""
        { "ios": { "app": "com.example.app", "appPath": "a.app" } }
        """, to: project.appsDir, name: "app3")
        try write("""
        { "ios": { "devices": [ { "name": "d", "simulator": "iPhone Air" } ] } }
        """, to: project.machinesDir, name: "m")
        try write(#"{ "app": "app3", "devices": [ { "name": "d" } ] }"#,
                  to: project.runsDir, name: "r")

        let resolved = try ProfileResolver.resolve(project: project, runName: "r", machineName: "m")
        XCTAssertEqual(resolved.apps["ios"]?.autoInstall, true,
                       "appPath があるので既定で有効")
    }

    /// platform セクションの autoInstall は無視される(置き場所は common に一本化)。
    /// ここでは false を置いても効かない = appPath 由来の既定(有効)のままになる
    func testAutoInstallInPlatformSectionIsIgnored() throws {
        try write("""
        { "ios": { "app": "com.example.app", "appPath": "a.app", "autoInstall": false } }
        """, to: project.appsDir, name: "app3")
        try write("""
        { "ios": { "devices": [ { "name": "d", "simulator": "iPhone Air" } ] } }
        """, to: project.machinesDir, name: "m")
        try write(#"{ "app": "app3", "devices": [ { "name": "d" } ] }"#,
                  to: project.runsDir, name: "r")

        let resolved = try ProfileResolver.resolve(project: project, runName: "r", machineName: "m")
        XCTAssertEqual(resolved.apps["ios"]?.autoInstall, true,
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
        XCTAssertNil(section.appName, "common の appName は引き継がれないはず(この契約変更の核)")
        XCTAssertNil(section.app, "common の app は引き継がれないはず")
        XCTAssertNil(section.appPath, "common の appPath は引き継がれないはず")
        XCTAssertEqual(section.autoInstall, true, "autoInstall は common から引き継ぐはず")
    }

    /// appName は platform セクション自身の値が採用される(ios/android で異なる表示名を持てる)
    func testSectionMergingUsesPlatformAppName() throws {
        let profile = AppProfile(
            common: AppProfileSection(autoInstall: true),
            ios: AppProfileSection(appName: "iOS 版", app: "com.example.app"),
            android: AppProfileSection(appName: "Android 版", app: "com.example.app"))
        XCTAssertEqual(profile.section(for: "ios").appName, "iOS 版")
        XCTAssertEqual(profile.section(for: "android").appName, "Android 版")
    }

    /// resolve() を経由した契約確認: common.appName は継承されず、appRef へフォールバックする
    func testResolveDoesNotInheritAppNameFromCommon() throws {
        try write("""
        { "common": { "appName": "共通表示名" },
          "ios":    { "app": "com.example.app" } }
        """, to: project.appsDir, name: "app5")
        try write("""
        { "ios": { "devices": [ { "name": "d", "simulator": "iPhone Air" } ] } }
        """, to: project.machinesDir, name: "m")
        try write(#"{ "app": "app5", "devices": [ { "name": "d" } ] }"#,
                  to: project.runsDir, name: "r")

        let resolved = try ProfileResolver.resolve(project: project, runName: "r", machineName: "m")
        XCTAssertEqual(resolved.appName, "app5",
                       "common.appName は継承されないので、参照名 app5 にフォールバックするはず")
    }

    func testValidateWarnsOnDeprecatedPlatformAutoInstall() throws {
        let data = #"""
        { "ios":     { "appName": "A", "app": "com.example.app", "autoInstall": true },
          "android": { "app": "com.example.app", "autoInstall": false } }
        """#.data(using: .utf8)!

        let (errors, warnings) = ProfileResolver.validate(
            kind: .app, data: data, context: "apps/app3.json", project: project)
        XCTAssertTrue(errors.isEmpty, "警告のみでエラーにはしないはず: \(errors)")
        XCTAssertTrue(warnings.contains { $0.contains("ios") && $0.contains("autoInstall")
                                          && $0.contains("deprecated") },
                      "ios.autoInstall 廃止警告が出るはず: \(warnings)")
        XCTAssertTrue(warnings.contains { $0.contains("android") && $0.contains("autoInstall")
                                          && $0.contains("deprecated") },
                      "android.autoInstall 廃止警告が出るはず: \(warnings)")
    }

    func testValidateNoWarningWhenAutoInstallInCommonSection() throws {
        let data = #"""
        { "common": { "autoInstall": true },
          "ios":    { "appName": "A", "app": "com.example.app" } }
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

    /// enableAnimations は既定 false(= 実行開始時にアニメーションを無効化する)。
    /// true 指定は素通しし、未知キー警告を出さない(knownKeys 登録漏れの検出)
    func testEnableAnimationsDefaultsToFalseAndIsKnown() throws {
        try writeStandardFixture()
        let defaulted = try ProfileResolver.resolve(
            project: project, runName: "all", machineName: "M1 Max(64GB)")
        XCTAssertFalse(defaulted.enableAnimations)

        try write("""
        { "app": "sampleapp", "devices": [ { "name": "メイン機" } ], "enableAnimations": true }
        """, to: project.runsDir, name: "animated")
        let enabled = try ProfileResolver.resolve(
            project: project, runName: "animated", machineName: "M1 Max(64GB)")
        XCTAssertTrue(enabled.enableAnimations)
        XCTAssertFalse(enabled.warnings.contains { $0.contains("enableAnimations") },
                       "既知キーなので未知キー警告を出さない: \(enabled.warnings)")
    }

    /// 決定順: 実行プロファイルの machine > FT_MACHINE > machines/ が1つ。
    /// **「この Mac の登録名」は見ない**(プロファイル名と機械の身元を1つの値に載せると、
    /// プロファイルを改名しただけでこの Mac の身元まで変わる)
    func testDetermineMachinePriority() throws {
        try writeStandardFixture()
        // FT_MACHINE が最優先
        var result = try ProfileResolver.determineMachine(
            project: project, environment: ["FT_MACHINE": "EnvMachine"])
        XCTAssertEqual(result.name, "EnvMachine")
        XCTAssertFalse(result.auto)
        // machines/ が 1 ファイルなら自動採用
        result = try ProfileResolver.determineMachine(project: project, environment: [:])
        XCTAssertEqual(result.name, "M1 Max(64GB)")
        XCTAssertTrue(result.auto)
        // 複数ファイルで machine 未指定ならエラー(候補を挙げる)
        try write("{}", to: project.machinesDir, name: "M2 Ultra(192GB)")
        XCTAssertThrowsError(try ProfileResolver.determineMachine(
            project: project, environment: [:])) { error in
            guard case ProfileError.machineUndetermined(let available) = error else {
                return XCTFail("machineUndetermined のはず: \(error)")
            }
            XCTAssertEqual(available, ["M1 Max(64GB)", "M2 Ultra(192GB)"])
        }
        // 実行プロファイルが machine を書いていれば、複数あっても解決する
        try write("""
        { "app": "sampleapp", "machine": "M1 Max(64GB)", "devices": [ { "name": "メイン機" } ] }
        """, to: project.runsDir, name: "all-on-M1")
        result = try ProfileResolver.determineMachine(
            project: project, environment: [:], runProfileName: "all-on-M1")
        XCTAssertEqual(result.name, "M1 Max(64GB)")
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

        // FT_MACHINE より実行プロファイルの machine 指定が優先される
        let result = try ProfileResolver.determineMachine(
            project: project, environment: ["FT_MACHINE": "EnvMachine"],
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
            project: project, environment: [:], runProfileName: "badMachine")) { error in
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
        XCTAssertTrue(errors.contains { $0.contains("\"machine\"") && $0.contains("must be a string") },
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
        XCTAssertTrue(warnings.contains { $0.contains("machine") && $0.contains("not specified") },
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
        XCTAssertFalse(warnings.contains { $0.contains("not specified") },
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
            guard case ProfileError.duplicateDeviceName(let name, _, _) = error else {
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
        XCTAssertTrue(resolved.warnings.contains { $0.contains("注入機") && $0.contains("does not apply") },
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

    // MARK: - record

    func testRecordDefaultsToFalseWhenUnspecified() throws {
        try writeStandardFixture()  // "all" は record 未指定
        let resolved = try ProfileResolver.resolve(
            project: project, runName: "all", machineName: "M1 Max(64GB)")
        XCTAssertFalse(resolved.record, "省略時は既定 false のはず")
    }

    func testRecordExplicitTrueIsReflected() throws {
        try writeStandardFixture()
        try write("""
        { "app": "sampleapp", "devices": [ { "name": "メイン機" } ], "record": true }
        """, to: project.runsDir, name: "record")
        let resolved = try ProfileResolver.resolve(
            project: project, runName: "record", machineName: "M1 Max(64GB)")
        XCTAssertTrue(resolved.record)
    }

    func testRecordOptionsDefaultWhenUnspecified() throws {
        try writeStandardFixture()  // "all" は recordFailuresOnly/recordBitrateKbps/recordFullResolution 未指定
        let resolved = try ProfileResolver.resolve(
            project: project, runName: "all", machineName: "M1 Max(64GB)")
        XCTAssertFalse(resolved.recordFailuresOnly, "省略時は既定 false のはず")
        XCTAssertEqual(resolved.recordBitrateKbps, 1500, "省略時は既定 1500kbps のはず")
        XCTAssertFalse(resolved.recordFullResolution, "省略時は既定 false のはず")
    }

    func testRecordOptionsExplicitValuesAreReflected() throws {
        try writeStandardFixture()
        try write("""
        { "app": "sampleapp", "devices": [ { "name": "メイン機" } ], "record": true,
          "recordFailuresOnly": true, "recordBitrateKbps": 3000, "recordFullResolution": true }
        """, to: project.runsDir, name: "recordOptions")
        let resolved = try ProfileResolver.resolve(
            project: project, runName: "recordOptions", machineName: "M1 Max(64GB)")
        XCTAssertTrue(resolved.recordFailuresOnly)
        XCTAssertEqual(resolved.recordBitrateKbps, 3000)
        XCTAssertTrue(resolved.recordFullResolution)
    }

    func testRecordBitrateKbpsNonPositiveFallsBackToDefault() throws {
        try writeStandardFixture()
        try write("""
        { "app": "sampleapp", "devices": [ { "name": "メイン機" } ], "recordBitrateKbps": 0 }
        """, to: project.runsDir, name: "recordBadBitrate")
        let resolved = try ProfileResolver.resolve(
            project: project, runName: "recordBadBitrate", machineName: "M1 Max(64GB)")
        XCTAssertEqual(resolved.recordBitrateKbps, 1500, "0以下は既定にフォールバックするはず")
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

    // MARK: - 実機(kind: physical)

    /// 実機 1 台ずつを含むマシン+実行プロファイル一式を書く
    private func writePhysicalFixture(iosEngine: String? = nil) throws {
        try write("""
        { "ios":     { "app": "com.example.app" },
          "android": { "app": "com.example.app" } }
        """, to: project.appsDir, name: "app")
        let engineField = iosEngine.map { ", \"engine\": \"\($0)\"" } ?? ""
        try write("""
        { "ios": { "devices": [
              { "name": "実機iPhone", "kind": "physical",
                "udid": "00008130-000A1B2C3D4E5678"\(engineField) } ] },
          "android": { "devices": [
              { "name": "実機Pixel", "kind": "physical", "serial": "14141JEC204922" } ] } }
        """, to: project.machinesDir, name: "m")
        try write("""
        { "app": "app", "devices": [ { "name": "実機iPhone" }, { "name": "実機Pixel" } ] }
        """, to: project.runsDir, name: "r")
    }

    func testPhysicalDeviceKeepsIdentifiers() throws {
        try writePhysicalFixture()
        let resolved = try ProfileResolver.resolve(project: project, runName: "r", machineName: "m")
        XCTAssertTrue(resolved.iosDevices[0].spec.isPhysical)
        XCTAssertEqual(resolved.iosDevices[0].spec.udid, "00008130-000A1B2C3D4E5678")
        XCTAssertTrue(resolved.androidDevices[0].spec.isPhysical)
        XCTAssertEqual(resolved.androidDevices[0].spec.serial, "14141JEC204922")
    }

    func testPhysicalIosDeviceForcesXcuitestEngine() throws {
        // iosInappEngine の既定(true→hybrid)を実機は無視する。ここで潰さないと inapp 経路に入る
        try writePhysicalFixture()
        let resolved = try ProfileResolver.resolve(project: project, runName: "r", machineName: "m")
        XCTAssertEqual(resolved.iosDevices[0].spec.engine, "xcuitest")
    }

    func testPhysicalIosDeviceRejectsInappEngine() throws {
        try writePhysicalFixture(iosEngine: "inapp")
        XCTAssertThrowsError(
            try ProfileResolver.resolve(project: project, runName: "r", machineName: "m")
        ) { error in
            guard case ProfileError.physicalDeviceUnsupportedEngine(let name, let engine, _) = error else {
                return XCTFail("physicalDeviceUnsupportedEngine のはず: \(error)")
            }
            XCTAssertEqual(name, "実機iPhone")
            XCTAssertEqual(engine, "inapp")
        }
    }

    func testPhysicalDeviceWithoutIdentifierFails() throws {
        try write("""
        { "android": { "app": "com.example.app" } }
        """, to: project.appsDir, name: "app")
        try write("""
        { "android": { "devices": [ { "name": "実機", "kind": "physical" } ] } }
        """, to: project.machinesDir, name: "m")
        try write("""
        { "app": "app", "devices": [ { "name": "実機" } ] }
        """, to: project.runsDir, name: "r")
        XCTAssertThrowsError(
            try ProfileResolver.resolve(project: project, runName: "r", machineName: "m")
        ) { error in
            guard case ProfileError.physicalDeviceMissingIdentifier(_, let platform, _) = error else {
                return XCTFail("physicalDeviceMissingIdentifier のはず: \(error)")
            }
            XCTAssertEqual(platform, "android")
        }
    }

    func testUnreferencedBrokenPhysicalDeviceDoesNotBlockRun() throws {
        // 実機検査は「参照されたデバイス」のみ。無関係な定義の不備で run を止めない
        try write("""
        { "ios": { "app": "com.example.app" } }
        """, to: project.appsDir, name: "app")
        try write("""
        { "ios": { "devices": [
              { "name": "シミュ", "simulator": "iPhone 17 Pro" },
              { "name": "壊れた実機", "kind": "physical" } ] } }
        """, to: project.machinesDir, name: "m")
        try write("""
        { "app": "app", "devices": [ { "name": "シミュ" } ] }
        """, to: project.runsDir, name: "r")
        let resolved = try ProfileResolver.resolve(project: project, runName: "r", machineName: "m")
        XCTAssertEqual(resolved.devices.map(\.name), ["シミュ"])
    }

    func testPhysicalDeviceKeepsDisplayOnlyModelAndOS() throws {
        // model/os は表示専用(同定には使わない)。未知キー警告を出さず素通しすること
        try write("""
        { "ios": { "app": "com.example.app" } }
        """, to: project.appsDir, name: "app")
        try write("""
        { "ios": { "devices": [
              { "name": "実機", "kind": "physical", "udid": "00008130-AAAA",
                "model": "iPhone 15 Pro", "os": "26.5.2" } ] } }
        """, to: project.machinesDir, name: "m")
        try write("""
        { "app": "app", "devices": [ { "name": "実機" } ] }
        """, to: project.runsDir, name: "r")
        let resolved = try ProfileResolver.resolve(project: project, runName: "r", machineName: "m")
        XCTAssertEqual(resolved.iosDevices[0].spec.model, "iPhone 15 Pro")
        XCTAssertEqual(resolved.iosDevices[0].spec.os, "26.5.2")
        XCTAssertTrue(resolved.warnings.isEmpty, "model は既知キー: \(resolved.warnings)")
    }

    // MARK: - FM トグル(fm/heal/falsePositiveCheck/screenLooksLike)

    func testFMTogglesDefaultsWhenUnspecified() throws {
        try writeStandardFixture()  // "all" は heal:true 明示。fm/falsePositiveCheck/screenLooksLike は未指定
        let resolved = try ProfileResolver.resolve(
            project: project, runName: "all", machineName: "M1 Max(64GB)")
        XCTAssertTrue(resolved.fm.enabled)
        XCTAssertTrue(resolved.fm.heal, "heal 明示 true")
        XCTAssertFalse(resolved.fm.falsePositiveCheck, "偽陽性検証は既定 false(オプトイン)のはず")
        XCTAssertTrue(resolved.fm.screenLooksLike, "省略時は既定 true のはず")
    }

    func testHealDefaultsToTrueWhenFullyUnspecified() throws {
        try write("""
        { "ios": { "app": "com.example.app" } }
        """, to: project.appsDir, name: "app6")
        try write("""
        { "ios": { "devices": [ { "name": "d", "simulator": "iPhone Air" } ] } }
        """, to: project.machinesDir, name: "m")
        try write(#"{ "app": "app6", "devices": [ { "name": "d" } ] }"#,
                  to: project.runsDir, name: "r")
        let resolved = try ProfileResolver.resolve(project: project, runName: "r", machineName: "m")
        XCTAssertTrue(resolved.fm.enabled)
        XCTAssertTrue(resolved.fm.heal, "heal の既定は true(既定 false→true への変更)")
        XCTAssertFalse(resolved.fm.falsePositiveCheck, "偽陽性検証の既定は false")
        XCTAssertTrue(resolved.fm.screenLooksLike)
        XCTAssertTrue(resolved.heal, "heal エイリアスも同じ値を返す")
    }

    func testFMFalseDisablesAllSubFlagsEvenIfExplicitlyTrue() throws {
        try writeStandardFixture()
        try write("""
        { "app": "sampleapp", "devices": [ { "name": "メイン機" } ],
          "fm": false, "heal": true, "falsePositiveCheck": true, "screenLooksLike": true }
        """, to: project.runsDir, name: "fmoff")
        let resolved = try ProfileResolver.resolve(
            project: project, runName: "fmoff", machineName: "M1 Max(64GB)")
        XCTAssertFalse(resolved.fm.enabled)
        XCTAssertFalse(resolved.fm.heal, "fm:false は個別の heal:true より優先される")
        XCTAssertFalse(resolved.fm.falsePositiveCheck)
        XCTAssertFalse(resolved.fm.screenLooksLike)
    }

    func testIndividualSubFlagsFollowExplicitValues() throws {
        try writeStandardFixture()
        // 既定と逆向きの明示指定(heal/screenLooksLike=OFF・falsePositiveCheck=ON)が個別に効くこと
        try write("""
        { "app": "sampleapp", "devices": [ { "name": "メイン機" } ],
          "heal": false, "falsePositiveCheck": true, "screenLooksLike": false }
        """, to: project.runsDir, name: "subsoff")
        let resolved = try ProfileResolver.resolve(
            project: project, runName: "subsoff", machineName: "M1 Max(64GB)")
        XCTAssertTrue(resolved.fm.enabled, "fm 自体は既定 true のまま")
        XCTAssertFalse(resolved.fm.heal)
        XCTAssertTrue(resolved.fm.falsePositiveCheck, "明示 true で有効化できること")
        XCTAssertFalse(resolved.fm.screenLooksLike)
    }

    /// 改名前の旧キー `screenIs` を書いた受け手のプロファイルが動き続けること。
    /// **未知キー警告も出さない**(knownKeys に残してある)
    func testLegacyScreenIsKeyStillDisablesScreenLooksLike() throws {
        try writeStandardFixture()
        try write("""
        { "app": "sampleapp", "devices": [ { "name": "メイン機" } ], "screenIs": false }
        """, to: project.runsDir, name: "legacykey")
        let resolved = try ProfileResolver.resolve(
            project: project, runName: "legacykey", machineName: "M1 Max(64GB)")
        XCTAssertFalse(resolved.fm.screenLooksLike, "旧キーを読み落とすと設定が黙って既定へ戻る")
        XCTAssertTrue(resolved.fm.enabled)
    }

    /// 新旧が両方書かれていたら**新キーが勝つ**(拡張は保存時に旧キーを落とすので、
    /// 両方あるのは手で足した場合だけ。優先順を決めておかないと画面と実行が食い違う)
    func testNewKeyWinsOverLegacyScreenIsKey() throws {
        try writeStandardFixture()
        try write("""
        { "app": "sampleapp", "devices": [ { "name": "メイン機" } ],
          "screenLooksLike": true, "screenIs": false }
        """, to: project.runsDir, name: "bothkeys")
        let resolved = try ProfileResolver.resolve(
            project: project, runName: "bothkeys", machineName: "M1 Max(64GB)")
        XCTAssertTrue(resolved.fm.screenLooksLike)
    }

    // MARK: - containerInference(FM とは独立。既定 true)

    func testContainerInferenceDefaultsToTrueAndFollowsExplicitFalse() throws {
        try writeStandardFixture()
        let onByDefault = try ProfileResolver.resolve(
            project: project, runName: "all", machineName: "M1 Max(64GB)")
        XCTAssertTrue(onByDefault.containerInference, "省略時は既定 true のはず")

        // fm:false に巻き込まれない(FM のサブフラグではない)ことも同時に見る
        try write("""
        { "app": "sampleapp", "devices": [ { "name": "メイン機" } ],
          "fm": false, "containerInference": false }
        """, to: project.runsDir, name: "ciofffmoff")
        let off = try ProfileResolver.resolve(
            project: project, runName: "ciofffmoff", machineName: "M1 Max(64GB)")
        XCTAssertFalse(off.containerInference)

        try write("""
        { "app": "sampleapp", "devices": [ { "name": "メイン機" } ], "fm": false }
        """, to: project.runsDir, name: "fmoffonly")
        let fmOffOnly = try ProfileResolver.resolve(
            project: project, runName: "fmoffonly", machineName: "M1 Max(64GB)")
        XCTAssertTrue(fmOffOnly.containerInference, "fm:false でも補正は止まらない")
        XCTAssertTrue(fmOffOnly.warnings.isEmpty, "containerInference は既知キー: \(fmOffOnly.warnings)")
    }

    func testValidateMachineProfileReportsPhysicalErrors() throws {
        let data = #"""
        { "ios": { "devices": [ { "name": "実機", "kind": "physical", "engine": "inapp" } ] },
          "android": { "devices": [ { "name": "実機A", "kind": "physical" } ] } }
        """#.data(using: .utf8)!
        let (errors, warnings) = ProfileResolver.validate(
            kind: .machine, data: data, context: "machines/m.json", project: project)
        XCTAssertTrue(errors.contains { $0.contains("実機") && $0.contains("udid") },
                      "iOS 実機の udid 欠落エラーが出るはず: \(errors)")
        XCTAssertTrue(errors.contains { $0.contains("inapp") },
                      "iOS 実機の inapp 拒否エラーが出るはず: \(errors)")
        XCTAssertTrue(errors.contains { $0.contains("実機A") && $0.contains("serial") },
                      "Android 実機の serial 欠落エラーが出るはず: \(errors)")
        XCTAssertFalse(warnings.contains { $0.contains("kind") || $0.contains("serial") },
                       "kind/serial は既知キーなので未知キー警告を出さない: \(warnings)")
    }
}

// MARK: - デバイス単位の host(混在プロファイル)

extension ProfileResolverTests {

    private func writeMixedHostFixture(runDevices: String) throws {
        try write("""
        { "ios": { "appName": "サンプル", "app": "com.example.sampleapp" } }
        """, to: project.appsDir, name: "sampleapp")
        try write("""
        { "ios": { "devices": [
              { "name": "iPhone-01", "simulator": "iPhone 17 Pro", "udid": "LOCAL-UDID" },
              { "name": "iPhone-01", "host": "M1Ultra", "simulator": "iPhone 17 Pro",
                "udid": "REMOTE-UDID" } ] } }
        """, to: project.machinesDir, name: "mixed")
        try write("""
        { "app": "sampleapp", "devices": \(runDevices) }
        """, to: project.runsDir, name: "r")
    }

    /// 同名が2つの機械に居るのは通常(各機が同じ命名規則でシミュレータを作る)。
    /// 重複エラーにしてはいけない —— ここが壊れると混在プロファイルが1台も作れない
    func testSameDeviceNameOnDifferentHostsResolves() throws {
        try writeMixedHostFixture(runDevices: #"[ { "name": "iPhone-01", "host": "M1Ultra" } ]"#)
        let resolved = try ProfileResolver.resolve(project: project, runName: "r",
                                                   machineName: "mixed")
        XCTAssertEqual(resolved.devices.map(\.spec.udid), ["REMOTE-UDID"])
        XCTAssertEqual(resolved.devices.map(\.spec.machine), ["M1Ultra"])
    }

    func testExplicitLocalHostInARunRefPicksTheLocalDevice() throws {
        try writeMixedHostFixture(runDevices: #"[ { "name": "iPhone-01", "host": "local" } ]"#)
        let resolved = try ProfileResolver.resolve(project: project, runName: "r",
                                                   machineName: "mixed")
        XCTAssertEqual(resolved.devices.map(\.spec.udid), ["LOCAL-UDID"])
        XCTAssertNil(resolved.devices[0].spec.machine)
    }

    /// host を書いていない参照が2台に当たるときは**候補を挙げて止める**。
    /// どちらかを選ぶと「別の機械のデバイスを操作した」になり、しかも気づけない
    func testAmbiguousRunRefIsRejectedWithBothHostsNamed() throws {
        try writeMixedHostFixture(runDevices: #"[ { "name": "iPhone-01" } ]"#)
        XCTAssertThrowsError(try ProfileResolver.resolve(
            project: project, runName: "r", machineName: "mixed")) { error in
            guard case ProfileError.ambiguousDeviceRef(let name, let hosts, _, _) = error else {
                return XCTFail("ambiguousDeviceRef のはず: \(error)")
            }
            XCTAssertEqual(name, "iPhone-01")
            XCTAssertEqual(hosts, ["local", "M1Ultra"])
        }
    }

    /// runDeviceHosts はディスパッチ先の判定に使う(resolve() より前に呼ばれる)。
    /// resolve() と同じ規則で解決していないと、配る先と実際に走る台がズレる
    func testRunDeviceHostsReportsWhereEachDeviceLives() throws {
        try writeMixedHostFixture(runDevices:
            #"[ { "name": "iPhone-01", "host": "local" }, { "name": "iPhone-01", "host": "M1Ultra" } ]"#)
        let devices = try ProfileResolver.runDeviceHosts(
            project: project, runProfileName: "r", machineName: "mixed")
        XCTAssertEqual(devices.map(\.host), [nil, "M1Ultra"])
        XCTAssertEqual(Set(devices.map(\.platform)), ["ios"])
    }
}
