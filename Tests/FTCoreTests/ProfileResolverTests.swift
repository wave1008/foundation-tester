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
        for dir in [project.appsDir, project.runsDir] {
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
        { "app": "sampleapp",
          "devices": [
            { "platform": "ios", "machine": "local", "name": "メイン機", "osVersion": "iOS 27.0", "udid": "AAAA-1111" },
            { "platform": "ios", "machine": "local", "name": "サブ機", "osVersion": "iOS 27.0" },
            { "platform": "android", "machine": "local", "name": "エミュ1", "avd": "Pixel_9" },
            { "platform": "android", "machine": "local", "name": "エミュ2", "enabled": false, "avd": "Pixel 8(Android 14)" } ],
          "heal": true, "reportDir": "reports", "defaultTimeout": 8, "scenarioTimeout": 60 }
        """, to: project.runsDir, name: "all")
    }

    func testResolveMixedPlatforms() throws {
        try writeStandardFixture()
        let resolved = try ProfileResolver.resolve(
            project: project, runName: "all")

        XCTAssertEqual(resolved.appName, "サンプルアプリ")
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
                       WorkspaceAppStaging.installPath(
                           declared: "builds/SampleApp.app",
                           workspaceRoot: project.rootURL.appendingPathComponent("workspace")),
                       "インストール元は既定ワークスペースのステージ先")
        XCTAssertTrue(ios.autoInstall, "common の autoInstall: true が両 platform に効く")
        let android = try XCTUnwrap(resolved.apps["android"])
        XCTAssertEqual(android.bundleID, "com.example.sampleapp")
        XCTAssertEqual(android.sourcePath,
                       tempDir.appendingPathComponent("builds/app-debug.apk").path,
                       "android の appPath 相対もリポジトリルート基準")
        XCTAssertEqual(android.appPath,
                       WorkspaceAppStaging.installPath(
                           declared: "builds/app-debug.apk",
                           workspaceRoot: project.rootURL.appendingPathComponent("workspace")),
                       "android のインストール元も既定ワークスペースのステージ先")
        XCTAssertTrue(android.autoInstall, "common の autoInstall: true が両 platform に効く")

        XCTAssertEqual(resolved.reportDir.path,
                       project.rootURL.appendingPathComponent("reports").path)

        XCTAssertEqual(resolved.devices[0].spec.udid, "AAAA-1111")
        XCTAssertEqual(resolved.devices[2].spec.avd, "Pixel_9")
    }

    /// defaultTimeout が小数(秒未満)でも解決できること(Int→Double 化の回帰ガード)。
    /// 整数 JSON との後方互換は testResolveMixedPlatforms(8)で別途固定済み
    /// `playProtectBypass` は**既定 true**(リテラルで固定: 未指定でも Play Protect の照会を通さない =
    /// アプリを Google へ送らない側)。false を書いたときだけキルスイッチが効く
    func testPlayProtectBypassDefaultsToTrueAndFalseIsHonoured() throws {
        try writeStandardFixture()
        let byDefault = try ProfileResolver.resolve(
            project: project, runName: "all")
        XCTAssertTrue(byDefault.playProtectBypass)
        try write("""
        { "app": "sampleapp", "devices": [ { "platform": "ios", "machine": "local", "name": "メイン機", "osVersion": "iOS 27.0", "udid": "AAAA-1111" } ], "playProtectBypass": false }
        """, to: project.runsDir, name: "killswitch")
        let killed = try ProfileResolver.resolve(
            project: project, runName: "killswitch")
        XCTAssertFalse(killed.playProtectBypass)
        XCTAssertTrue(killed.warnings.isEmpty, "既知のキーなので unknown-key 警告を出さない: \(killed.warnings)")
    }

    func testResolveAcceptsFractionalDefaultTimeout() throws {
        try writeStandardFixture()
        try write("""
        { "app": "sampleapp", "devices": [ { "platform": "ios", "machine": "local", "name": "メイン機", "osVersion": "iOS 27.0", "udid": "AAAA-1111" } ], "defaultTimeout": 1.5 }
        """, to: project.runsDir, name: "fractional")
        let resolved = try ProfileResolver.resolve(
            project: project, runName: "fractional")
        XCTAssertEqual(resolved.defaultTimeout, 1.5)
    }

    func testAppSectionOverridesCommon() throws {
        // common.app は廃止済みで resolve では無視される(validate は警告のみ)
        try write("""
        { "common":  { "app": "com.example.common" },
          "android": { "appName": "A", "app": "com.example.android" } }
        """, to: project.appsDir, name: "app2")
        try write("""
        { "app": "app2", "devices": [ { "platform": "android", "machine": "local", "name": "d1", "avd": "Pixel_9" } ] }
        """, to: project.runsDir, name: "r")

        let resolved = try ProfileResolver.resolve(project: project, runName: "r")
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
        { "app": "app4", "devices": [ { "platform": "android", "machine": "local", "name": "d1", "avd": "Pixel_9" } ] }
        """, to: project.runsDir, name: "r")

        let resolved = try ProfileResolver.resolve(project: project, runName: "r")
        XCTAssertEqual(resolved.apps["android"]?.autoInstall, false)
    }

    // MARK: - common セクションの app / appPath 廃止

    func testCommonAppNotInheritedFailsWithMissingBundleID() throws {
        try write("""
        { "common": { "app": "com.example.common" },
          "ios":    { "appPath": "a.app" } }
        """, to: project.appsDir, name: "app2")
        try write(#"{ "app": "app2", "devices": [ { "platform": "ios", "machine": "local", "name": "d", "osVersion": "iOS 27.0" } ] }"#,
                  to: project.runsDir, name: "r")

        XCTAssertThrowsError(try ProfileResolver.resolve(
            project: project, runName: "r")) { error in
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
        try write(#"{ "app": "app2", "devices": [ { "platform": "ios", "machine": "local", "name": "d", "osVersion": "iOS 27.0" } ] }"#,
                  to: project.runsDir, name: "r")

        XCTAssertThrowsError(try ProfileResolver.resolve(
            project: project, runName: "r")) { error in
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
        try write(#"{ "app": "app2", "devices": [ { "platform": "ios", "machine": "local", "name": "d", "osVersion": "iOS 27.0" } ] }"#,
                  to: project.runsDir, name: "r")

        let resolved = try ProfileResolver.resolve(project: project, runName: "r")
        XCTAssertNil(resolved.apps["ios"]?.appPath, "common の appPath は引き継がれないはず")
    }

    /// 合成が読まないキーは**未知キーとして警告する**(移行の案内は置かない。黙って無視しないことだけ守る)
    func testValidateWarnsOnCommonAppAndAppPathAsUnknownKeys() throws {
        let data = #"""
        { "common": { "app": "com.example.app", "appPath": "x.app" } }
        """#.data(using: .utf8)!

        let (errors, warnings) = ProfileResolver.validate(
            kind: .app, data: data, context: "apps/app2.json")
        XCTAssertTrue(errors.isEmpty, "警告のみでエラーにはしないはず: \(errors)")
        XCTAssertTrue(warnings.contains("apps/app2.json common: unknown key \"app\" is ignored"),
                      "\(warnings)")
        XCTAssertTrue(warnings.contains("apps/app2.json common: unknown key \"appPath\" is ignored"),
                      "\(warnings)")
    }

    /// 読まなくなった `iosSystemAlertButtons` は未知キーとして警告する(黙って無視しない)
    func testValidateWarnsOnRemovedSystemAlertKeyAsUnknown() throws {
        let data = #"""
        { "app": "sampleapp", "devices": [{ "name": "x" }],
          "iosSystemAlertButtons": ["許可"] }
        """#.data(using: .utf8)!
        let (_, warnings) = ProfileResolver.validate(
            kind: .run, data: data, context: "runs/legacy.json")
        XCTAssertTrue(warnings.contains("runs/legacy.json: unknown key \"iosSystemAlertButtons\" is ignored"),
                      "\(warnings)")
    }

    /// common.appName は読まない: 黙って無視せず未知キーとして警告する
    func testValidateWarnsWhenAppNameInCommonSection() throws {
        let data = #"""
        { "common": { "appName": "A" }, "ios": { "app": "com.example.app" } }
        """#.data(using: .utf8)!

        let (errors, warnings) = ProfileResolver.validate(
            kind: .app, data: data, context: "apps/app2.json")
        XCTAssertTrue(errors.isEmpty, "警告のみでエラーにはしないはず: \(errors)")
        XCTAssertTrue(warnings.contains("apps/app2.json common: unknown key \"appName\" is ignored"),
                      "\(warnings)")
    }

    func testValidateNoWarningWhenAppAndAppPathInPlatformSection() throws {
        let data = #"""
        { "ios": { "appName": "A", "app": "com.example.app", "appPath": "x.app" } }
        """#.data(using: .utf8)!

        let (errors, warnings) = ProfileResolver.validate(
            kind: .app, data: data, context: "apps/app2.json")
        XCTAssertTrue(errors.isEmpty, "エラーは出ないはず: \(errors)")
        XCTAssertTrue(warnings.isEmpty, "platform 側の指定では警告は出ないはず: \(warnings)")
    }

    // MARK: - autoInstall(common でのみ指定可+既定 false)

    func testAutoInstallExplicitTrueInCommonSectionIsEnabled() throws {
        try write("""
        { "common": { "autoInstall": true },
          "ios":    { "app": "com.example.app", "appPath": "a.app" } }
        """, to: project.appsDir, name: "app3")
        try write(#"{ "app": "app3", "devices": [ { "platform": "ios", "machine": "local", "name": "d", "osVersion": "iOS 27.0" } ] }"#,
                  to: project.runsDir, name: "r")

        let resolved = try ProfileResolver.resolve(project: project, runName: "r")
        XCTAssertEqual(resolved.apps["ios"]?.autoInstall, true)
    }

    func testAutoInstallExplicitFalseInCommonSectionIsDisabled() throws {
        try write("""
        { "common": { "autoInstall": false },
          "ios":    { "app": "com.example.app", "appPath": "a.app" } }
        """, to: project.appsDir, name: "app3")
        try write(#"{ "app": "app3", "devices": [ { "platform": "ios", "machine": "local", "name": "d", "osVersion": "iOS 27.0" } ] }"#,
                  to: project.runsDir, name: "r")

        let resolved = try ProfileResolver.resolve(project: project, runName: "r")
        XCTAssertEqual(resolved.apps["ios"]?.autoInstall, false)
    }

    /// **appPath があれば既定で有効**(パスを書いたのに入らない方が事故だった)
    func testAutoInstallUnspecifiedFollowsAppPath() throws {
        try write("""
        { "ios": { "app": "com.example.app", "appPath": "a.app" } }
        """, to: project.appsDir, name: "app3")
        try write(#"{ "app": "app3", "devices": [ { "platform": "ios", "machine": "local", "name": "d", "osVersion": "iOS 27.0" } ] }"#,
                  to: project.runsDir, name: "r")

        let resolved = try ProfileResolver.resolve(project: project, runName: "r")
        XCTAssertEqual(resolved.apps["ios"]?.autoInstall, true,
                       "appPath があるので既定で有効")
    }

    /// platform セクションの autoInstall は無視される(置き場所は common に一本化)。
    /// ここでは false を置いても効かない = appPath 由来の既定(有効)のままになる
    func testAutoInstallInPlatformSectionIsIgnored() throws {
        try write("""
        { "ios": { "app": "com.example.app", "appPath": "a.app", "autoInstall": false } }
        """, to: project.appsDir, name: "app3")
        try write(#"{ "app": "app3", "devices": [ { "platform": "ios", "machine": "local", "name": "d", "osVersion": "iOS 27.0" } ] }"#,
                  to: project.runsDir, name: "r")

        let resolved = try ProfileResolver.resolve(project: project, runName: "r")
        XCTAssertEqual(resolved.apps["ios"]?.autoInstall, true,
                       "platform セクションの autoInstall は無視されるはず")
    }

    func testAutoInstallPlatformValueDoesNotOverrideCommon() throws {
        try write("""
        { "common": { "autoInstall": false },
          "ios":    { "app": "com.example.app", "appPath": "a.app", "autoInstall": true } }
        """, to: project.appsDir, name: "app3")
        try write(#"{ "app": "app3", "devices": [ { "platform": "ios", "machine": "local", "name": "d", "osVersion": "iOS 27.0" } ] }"#,
                  to: project.runsDir, name: "r")

        let resolved = try ProfileResolver.resolve(project: project, runName: "r")
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
        try write(#"{ "app": "app5", "devices": [ { "platform": "ios", "machine": "local", "name": "d", "osVersion": "iOS 27.0" } ] }"#,
                  to: project.runsDir, name: "r")

        let resolved = try ProfileResolver.resolve(project: project, runName: "r")
        XCTAssertEqual(resolved.appName, "app5",
                       "common.appName は継承されないので、参照名 app5 にフォールバックするはず")
    }

    /// autoInstall は common でしか読まない = platform 側は未知キーとして警告する
    func testValidateWarnsOnPlatformAutoInstallAsUnknown() throws {
        let data = #"""
        { "ios":     { "appName": "A", "app": "com.example.app", "autoInstall": true },
          "android": { "app": "com.example.app", "autoInstall": false } }
        """#.data(using: .utf8)!

        let (errors, warnings) = ProfileResolver.validate(
            kind: .app, data: data, context: "apps/app3.json")
        XCTAssertTrue(errors.isEmpty, "警告のみでエラーにはしないはず: \(errors)")
        XCTAssertTrue(warnings.contains("apps/app3.json ios: unknown key \"autoInstall\" is ignored"),
                      "\(warnings)")
        XCTAssertTrue(warnings.contains("apps/app3.json android: unknown key \"autoInstall\" is ignored"),
                      "\(warnings)")
    }

    func testValidateNoWarningWhenAutoInstallInCommonSection() throws {
        let data = #"""
        { "common": { "autoInstall": true },
          "ios":    { "appName": "A", "app": "com.example.app" } }
        """#.data(using: .utf8)!

        let (errors, warnings) = ProfileResolver.validate(
            kind: .app, data: data, context: "apps/app3.json")
        XCTAssertTrue(errors.isEmpty, "エラーは出ないはず: \(errors)")
        XCTAssertTrue(warnings.isEmpty,
                      "common の autoInstall は正当な設定場所なので警告は出ないはず: \(warnings)")
    }

    /// enabled: false の台は解決対象から外す(警告も出さない = 意図した状態)
    func testDisabledDeviceIsNotRun() throws {
        try writeStandardFixture()
        let resolved = try ProfileResolver.resolve(project: project, runName: "all")
        XCTAssertFalse(resolved.devices.map(\.name).contains("エミュ2"))
        XCTAssertTrue(resolved.warnings.isEmpty, "\(resolved.warnings)")
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
        { "app": "sampleapp", "devices": [ { "platform": "ios", "machine": "local", "name": "メイン機", "osVersion": "iOS 27.0", "udid": "AAAA-1111" } ], "maxParallel": 4 }
        """, to: project.runsDir, name: "typo")

        let resolved = try ProfileResolver.resolve(
            project: project, runName: "typo")
        XCTAssertTrue(resolved.warnings.contains { $0.contains("maxParallel") },
                      "未知キー警告が出るはず: \(resolved.warnings)")
    }

    /// enableAnimations は既定 false(= 実行開始時にアニメーションを無効化する)。
    /// true 指定は素通しし、未知キー警告を出さない(knownKeys 登録漏れの検出)
    func testEnableAnimationsDefaultsToFalseAndIsKnown() throws {
        try writeStandardFixture()
        let defaulted = try ProfileResolver.resolve(
            project: project, runName: "all")
        XCTAssertFalse(defaulted.enableAnimations)

        try write("""
        { "app": "sampleapp", "devices": [ { "platform": "ios", "machine": "local", "name": "メイン機", "osVersion": "iOS 27.0", "udid": "AAAA-1111" } ], "enableAnimations": true }
        """, to: project.runsDir, name: "animated")
        let enabled = try ProfileResolver.resolve(
            project: project, runName: "animated")
        XCTAssertTrue(enabled.enableAnimations)
        XCTAssertFalse(enabled.warnings.contains { $0.contains("enableAnimations") },
                       "既知キーなので未知キー警告を出さない: \(enabled.warnings)")
    }

    /// トップレベルの "machine" はもう読まない(未知キーとして名指しする)
    func testTopLevelMachineKeyIsAnUnknownKey() throws {
        try writeStandardFixture()
        try write("""
        { "app": "sampleapp", "machine": "M1", "devices": [ { "platform": "ios", "machine": "local", "name": "メイン機", "osVersion": "iOS 27.0", "udid": "AAAA-1111" } ] }
        """, to: project.runsDir, name: "legacy")
        let resolved = try ProfileResolver.resolve(project: project, runName: "legacy")
        XCTAssertTrue(resolved.warnings.contains { $0.contains("unknown key \"machine\"") },
                      "\(resolved.warnings)")
    }

    /// devices[] の未知キーも名指しする(タイポ検出)
    func testUnknownDeviceKeyIsWarned() throws {
        try writeStandardFixture()
        try write("""
        { "app": "sampleapp", "devices": [ { "platform": "ios", "machine": "local", "name": "x", "simulater": "iPhone" } ] }
        """, to: project.runsDir, name: "typo")
        let resolved = try ProfileResolver.resolve(project: project, runName: "typo")
        XCTAssertTrue(resolved.warnings.contains { $0.contains("unknown key \"simulater\"") },
                      "\(resolved.warnings)")
    }

    func testDuplicateDeviceNameAcrossPlatformsFails() throws {
        try writeStandardFixture()
        try write("""
        { "app": "sampleapp", "devices": [
          { "platform": "ios", "machine": "local", "name": "同名", "osVersion": "iOS 27.0" },
          { "platform": "android", "machine": "local", "name": "同名", "avd": "Pixel_9", "enabled": false } ] }
        """, to: project.runsDir, name: "r")

        XCTAssertThrowsError(try ProfileResolver.resolve(
            project: project, runName: "r")) { error in
            guard case ProfileError.duplicateDeviceName(let name, let machine, let run) = error else {
                return XCTFail("duplicateDeviceName のはず: \(error)")
            }
            XCTAssertEqual(name, "同名")
            XCTAssertNil(machine)
            XCTAssertEqual(run, "r")
        }
    }

    /// 無効化された行(enabled: false)だけが同名でも重複として断る(T7)。編集画面には見えない
    /// 無効行が原因になりうるので、文言にもそれを言う
    func testDuplicateDeviceNameCountsDisabledEntry() throws {
        try writeStandardFixture()
        try write("""
        { "app": "sampleapp", "devices": [
          { "platform": "android", "machine": "local", "name": "Pixel 3a", "avd": "Pixel_3a", "enabled": false },
          { "platform": "android", "machine": "local", "name": "Pixel 3a", "avd": "Pixel_3a" } ] }
        """, to: project.runsDir, name: "r")

        XCTAssertThrowsError(try ProfileResolver.resolve(
            project: project, runName: "r")) { error in
            guard case ProfileError.duplicateDeviceName = error else {
                return XCTFail("duplicateDeviceName のはず: \(error)")
            }
            let message = (error as? LocalizedError)?.errorDescription ?? ""
            XCTAssertTrue(message.contains("enabled"), message)
        }
    }

    /// 同名でも機械が違えば重複ではない
    func testSameNameOnAnotherMachineIsNotADuplicate() throws {
        try writeStandardFixture()
        try write("""
        { "app": "sampleapp", "devices": [
          { "platform": "ios", "machine": "local", "name": "同名", "udid": "LOCAL" },
          { "platform": "ios", "machine": "M1Ultra", "name": "同名", "udid": "REMOTE" } ] }
        """, to: project.runsDir, name: "r")
        let resolved = try ProfileResolver.resolve(project: project, runName: "r")
        XCTAssertEqual(resolved.devices.map(\.spec.udid), ["LOCAL", "REMOTE"])
        XCTAssertEqual(resolved.devices.map(\.spec.machine), [nil, "M1Ultra"])
    }

    func testNoEnabledDevicesFails() throws {
        try writeStandardFixture()
        try write("""
        { "app": "sampleapp", "devices": [
          { "platform": "ios", "machine": "local", "name": "a", "enabled": false } ] }
        """, to: project.runsDir, name: "r")

        XCTAssertThrowsError(try ProfileResolver.resolve(
            project: project, runName: "r")) { error in
            guard case ProfileError.noEnabledDevices(let run) = error else {
                return XCTFail("noEnabledDevices のはず: \(error)")
            }
            XCTAssertEqual(run, "r")
        }
    }

    func testMissingPlatformFailsToDecode() throws {
        try writeStandardFixture()
        try write("""
        { "app": "sampleapp", "devices": [ { "machine": "local", "name": "a" } ] }
        """, to: project.runsDir, name: "r")
        XCTAssertThrowsError(try ProfileResolver.resolve(project: project, runName: "r")) { error in
            guard case ProfileError.decodeFailed = error else {
                return XCTFail("decodeFailed のはず: \(error)")
            }
        }
        try write("""
        { "app": "sampleapp", "devices": [ { "platform": "windows", "machine": "local", "name": "a" } ] }
        """, to: project.runsDir, name: "r2")
        XCTAssertThrowsError(try ProfileResolver.resolve(project: project, runName: "r2"))
    }

    func testMissingReferencesFail() throws {
        try writeStandardFixture()
        // 実行プロファイルが無い
        XCTAssertThrowsError(try ProfileResolver.resolve(
            project: project, runName: "nope")) { error in
            guard case ProfileError.runProfileNotFound(_, let available) = error else {
                return XCTFail("runProfileNotFound のはず: \(error)")
            }
            XCTAssertEqual(available, ["all"])
        }
        // apps 参照切れ
        try write("""
        { "app": "ghost", "devices": [ { "platform": "ios", "machine": "local", "name": "メイン機", "osVersion": "iOS 27.0", "udid": "AAAA-1111" } ] }
        """, to: project.runsDir, name: "badapp")
        XCTAssertThrowsError(try ProfileResolver.resolve(
            project: project, runName: "badapp")) { error in
            guard case ProfileError.appProfileNotFound = error else {
                return XCTFail("appProfileNotFound のはず: \(error)")
            }
        }
    }

    func testMissingBundleIDFails() throws {
        try write("""
        { "ios": { "appPath": "a.app" } }
        """, to: project.appsDir, name: "noid")
        try write("""
        { "app": "noid", "devices": [ { "platform": "ios", "machine": "local", "name": "d", "osVersion": "iOS 27.0" } ] }
        """, to: project.runsDir, name: "r")

        XCTAssertThrowsError(try ProfileResolver.resolve(
            project: project, runName: "r")) { error in
            guard case ProfileError.missingBundleID(let platform, _) = error else {
                return XCTFail("missingBundleID のはず: \(error)")
            }
            XCTAssertEqual(platform, "ios")
        }
    }

    func testRunProfileWithoutAppOrDevicesFails() throws {
        try writeStandardFixture()
        try write(#"{ "devices": [ { "platform": "ios", "machine": "local", "name": "メイン機", "osVersion": "iOS 27.0", "udid": "AAAA-1111" } ] }"#, to: project.runsDir, name: "noapp")
        XCTAssertThrowsError(try ProfileResolver.resolve(
            project: project, runName: "noapp")) { error in
            guard case ProfileError.missingAppReference = error else {
                return XCTFail("missingAppReference のはず: \(error)")
            }
        }
        try write(#"{ "app": "sampleapp" }"#, to: project.runsDir, name: "nodev")
        XCTAssertThrowsError(try ProfileResolver.resolve(
            project: project, runName: "nodev")) { error in
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
            project: project, runName: "all")
        XCTAssertEqual(resolved.iosDevices.map { $0.spec.engine }, ["hybrid", "hybrid"])
        XCTAssertNil(resolved.androidDevices.first?.spec.engine, "Android には影響しないはず")
    }

    func testIosInappEngineFalseUsesXcuitest() throws {
        try writeStandardFixture()
        try write("""
        { "app": "sampleapp", "devices": [ { "platform": "ios", "machine": "local", "name": "メイン機", "osVersion": "iOS 27.0", "udid": "AAAA-1111" }, { "platform": "ios", "machine": "local", "name": "サブ機", "osVersion": "iOS 27.0" } ],
          "iosInappEngine": false }
        """, to: project.runsDir, name: "xc")
        let resolved = try ProfileResolver.resolve(
            project: project, runName: "xc")
        XCTAssertEqual(resolved.iosDevices.map { $0.spec.engine }, ["xcuitest", "xcuitest"])
    }

    func testExplicitDeviceEngineOverridesFlag() throws {
        // マシンでデバイスに engine を明示している場合はフラグより優先(上書きしない)。
        try write("""
        { "ios": { "app": "com.example.app" } }
        """, to: project.appsDir, name: "app4")
        // フラグ OFF(xcuitest 既定)でも engine 明示の "注入機" は inapp のまま、
        // 明示なしの "素機" はフラグどおり xcuitest。
        try write("""
        { "app": "app4", "devices": [ { "platform": "ios", "machine": "local", "name": "注入機", "osVersion": "iOS 27.0", "engine": "inapp" }, { "platform": "ios", "machine": "local", "name": "素機", "osVersion": "iOS 27.0" } ],
          "iosInappEngine": false }
        """, to: project.runsDir, name: "r")
        let resolved = try ProfileResolver.resolve(project: project, runName: "r")
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
        { "app": "app5", "devices": [ { "platform": "ios", "machine": "local", "name": "注入機", "osVersion": "iOS 27.0", "engine": "inapp" } ] }
        """, to: project.runsDir, name: "r")
        let resolved = try ProfileResolver.resolve(project: project, runName: "r")
        XCTAssertFalse(resolved.warnings.contains { $0.contains("適用されません") },
                       "フラグ未指定では警告しないはず: \(resolved.warnings)")
    }

    // MARK: - wipeDataOnBloat / wipeDataThresholdGB

    func testWipeDataDefaultsWhenUnspecified() throws {
        try writeStandardFixture()  // "all" は wipeDataOnBloat/wipeDataThresholdGB 未指定
        let resolved = try ProfileResolver.resolve(
            project: project, runName: "all")
        XCTAssertTrue(resolved.wipeDataOnBloat, "省略時は既定 true(ON)のはず")
        XCTAssertEqual(resolved.wipeDataThresholdGB, 8, "省略時は既定 8GB のはず")
    }

    func testWipeDataExplicitValuesAreReflected() throws {
        try writeStandardFixture()
        try write("""
        { "app": "sampleapp", "devices": [ { "platform": "ios", "machine": "local", "name": "メイン機", "osVersion": "iOS 27.0", "udid": "AAAA-1111" } ],
          "wipeDataOnBloat": false, "wipeDataThresholdGB": 3.5 }
        """, to: project.runsDir, name: "wipe")
        let resolved = try ProfileResolver.resolve(
            project: project, runName: "wipe")
        XCTAssertFalse(resolved.wipeDataOnBloat)
        XCTAssertEqual(resolved.wipeDataThresholdGB, 3.5)
    }

    func testWipeDataThresholdZeroOrLessFails() throws {
        try writeStandardFixture()
        try write("""
        { "app": "sampleapp", "devices": [ { "platform": "ios", "machine": "local", "name": "メイン機", "osVersion": "iOS 27.0", "udid": "AAAA-1111" } ], "wipeDataThresholdGB": 0 }
        """, to: project.runsDir, name: "badThreshold")
        XCTAssertThrowsError(try ProfileResolver.resolve(
            project: project, runName: "badThreshold")) { error in
            guard case ProfileError.invalidWipeDataThreshold(let run) = error else {
                return XCTFail("invalidWipeDataThreshold のはず: \(error)")
            }
            XCTAssertEqual(run, "badThreshold")
        }

        try write("""
        { "app": "sampleapp", "devices": [ { "platform": "ios", "machine": "local", "name": "メイン機", "osVersion": "iOS 27.0", "udid": "AAAA-1111" } ], "wipeDataThresholdGB": -2 }
        """, to: project.runsDir, name: "negativeThreshold")
        XCTAssertThrowsError(try ProfileResolver.resolve(
            project: project, runName: "negativeThreshold")) { error in
            guard case ProfileError.invalidWipeDataThreshold = error else {
                return XCTFail("invalidWipeDataThreshold のはず: \(error)")
            }
        }
    }

    func testValidateRunWipeDataThresholdZeroOrLessErrors() throws {
        try writeStandardFixture()
        let data = #"""
        { "app": "sampleapp", "devices": [ { "platform": "ios", "machine": "local", "name": "メイン機", "osVersion": "iOS 27.0", "udid": "AAAA-1111" } ], "wipeDataThresholdGB": 0 }
        """#.data(using: .utf8)!

        let (errors, _) = ProfileResolver.validate(
            kind: .run, data: data, context: "runs/badThreshold.json")
        XCTAssertTrue(errors.contains { $0.contains("wipeDataThresholdGB") },
                      "wipeDataThresholdGB エラーが出るはず: \(errors)")
    }

    // MARK: - scenarioTimeout / defaultTimeout(負値・0・NaN が
    // ScenarioHost の watchdog(UInt64 変換 → trap)まで届かないよう入口で弾く)

    func testValidateRunScenarioTimeoutZeroOrNegativeErrors() throws {
        try writeStandardFixture()
        for bad in ["0", "-5"] {
            let data = #"{ "app": "sampleapp", "devices": [ { "platform": "ios", "machine": "local", "name": "メイン機", "osVersion": "iOS 27.0", "udid": "AAAA-1111" } ], "scenarioTimeout": \#(bad) }"#
                .data(using: .utf8)!
            let (errors, _) = ProfileResolver.validate(
                kind: .run, data: data, context: "runs/badScenarioTimeout.json")
            XCTAssertTrue(errors.contains { $0.contains("scenarioTimeout") },
                          "scenarioTimeout=\(bad) はエラーになるはず: \(errors)")
        }
    }

    func testValidateRunScenarioTimeoutPositiveIsFine() throws {
        try writeStandardFixture()
        let data = #"""
        { "app": "sampleapp", "devices": [ { "platform": "ios", "machine": "local", "name": "メイン機", "osVersion": "iOS 27.0", "udid": "AAAA-1111" } ], "scenarioTimeout": 45 }
        """#.data(using: .utf8)!
        let (errors, _) = ProfileResolver.validate(
            kind: .run, data: data, context: "runs/goodScenarioTimeout.json")
        XCTAssertFalse(errors.contains { $0.contains("scenarioTimeout") }, "\(errors)")
    }

    /// **NaN は JSON の literal ではない**ので profile JSON からは書けない(`--set defaultTimeout=nan`
    /// 側のテストで確認する)。ここでは負値だけを見る。**0 は正当**(初回スナップショットだけ)
    func testValidateRunDefaultTimeoutNegativeErrorsButZeroIsAccepted() throws {
        try writeStandardFixture()
        let zero = #"{ "app": "sampleapp", "devices": [ { "platform": "ios", "machine": "local", "name": "メイン機", "osVersion": "iOS 27.0", "udid": "AAAA-1111" } ], "defaultTimeout": 0 }"#
            .data(using: .utf8)!
        let (zeroErrors, _) = ProfileResolver.validate(
            kind: .run, data: zero, context: "runs/zeroDefaultTimeout.json")
        XCTAssertFalse(zeroErrors.contains { $0.contains("defaultTimeout") }, "\(zeroErrors)")
        for bad in ["-1.5"] {
            let data = #"{ "app": "sampleapp", "devices": [ { "platform": "ios", "machine": "local", "name": "メイン機", "osVersion": "iOS 27.0", "udid": "AAAA-1111" } ], "defaultTimeout": \#(bad) }"#
                .data(using: .utf8)!
            let (errors, _) = ProfileResolver.validate(
                kind: .run, data: data, context: "runs/badDefaultTimeout.json")
            XCTAssertTrue(errors.contains { $0.contains("defaultTimeout") },
                          "defaultTimeout=\(bad) はエラーになるはず: \(errors)")
        }
    }

    // MARK: - record

    func testRecordDefaultsToFalseWhenUnspecified() throws {
        try writeStandardFixture()  // "all" は record 未指定
        let resolved = try ProfileResolver.resolve(
            project: project, runName: "all")
        XCTAssertFalse(resolved.record, "省略時は既定 false のはず")
    }

    func testRecordExplicitTrueIsReflected() throws {
        try writeStandardFixture()
        try write("""
        { "app": "sampleapp", "devices": [ { "platform": "ios", "machine": "local", "name": "メイン機", "osVersion": "iOS 27.0", "udid": "AAAA-1111" } ], "record": true }
        """, to: project.runsDir, name: "record")
        let resolved = try ProfileResolver.resolve(
            project: project, runName: "record")
        XCTAssertTrue(resolved.record)
    }

    func testRecordOptionsDefaultWhenUnspecified() throws {
        try writeStandardFixture()  // "all" は recordFailuresOnly/recordBitrateKbps/recordFullResolution 未指定
        let resolved = try ProfileResolver.resolve(
            project: project, runName: "all")
        XCTAssertFalse(resolved.recordFailuresOnly, "省略時は既定 false のはず")
        XCTAssertEqual(resolved.recordBitrateKbps, 1500, "省略時は既定 1500kbps のはず")
        XCTAssertFalse(resolved.recordFullResolution, "省略時は既定 false のはず")
    }

    func testRecordOptionsExplicitValuesAreReflected() throws {
        try writeStandardFixture()
        try write("""
        { "app": "sampleapp", "devices": [ { "platform": "ios", "machine": "local", "name": "メイン機", "osVersion": "iOS 27.0", "udid": "AAAA-1111" } ], "record": true,
          "recordFailuresOnly": true, "recordBitrateKbps": 3000, "recordFullResolution": true }
        """, to: project.runsDir, name: "recordOptions")
        let resolved = try ProfileResolver.resolve(
            project: project, runName: "recordOptions")
        XCTAssertTrue(resolved.recordFailuresOnly)
        XCTAssertEqual(resolved.recordBitrateKbps, 3000)
        XCTAssertTrue(resolved.recordFullResolution)
    }

    func testRecordBitrateKbpsNonPositiveFallsBackToDefault() throws {
        try writeStandardFixture()
        try write("""
        { "app": "sampleapp", "devices": [ { "platform": "ios", "machine": "local", "name": "メイン機", "osVersion": "iOS 27.0", "udid": "AAAA-1111" } ], "recordBitrateKbps": 0 }
        """, to: project.runsDir, name: "recordBadBitrate")
        let resolved = try ProfileResolver.resolve(
            project: project, runName: "recordBadBitrate")
        XCTAssertEqual(resolved.recordBitrateKbps, 1500, "0以下は既定にフォールバックするはず")
    }

    // MARK: - locale

    func testLocaleDefaultsWhenUnspecified() throws {
        try writeStandardFixture()  // "all" は locale 未指定
        let resolved = try ProfileResolver.resolve(
            project: project, runName: "all")
        XCTAssertEqual(resolved.locale, "ja_JP", "省略時は既定 ja_JP のはず")
    }

    func testLocaleExplicitValueIsReflected() throws {
        try writeStandardFixture()
        try write("""
        { "app": "sampleapp", "devices": [ { "platform": "ios", "machine": "local", "name": "メイン機", "osVersion": "iOS 27.0", "udid": "AAAA-1111" } ], "locale": "en-US" }
        """, to: project.runsDir, name: "locale")
        let resolved = try ProfileResolver.resolve(
            project: project, runName: "locale")
        XCTAssertEqual(resolved.locale, "en-US")
    }

    func testLocaleInvalidFormatFails() throws {
        try writeStandardFixture()
        for (name, value) in [("badLocaleSpace", "ja JP"), ("badLocaleEmpty", ""),
                               ("badLocaleNonAscii", "日本語")] {
            try write("""
            { "app": "sampleapp", "devices": [ { "platform": "ios", "machine": "local", "name": "メイン機", "osVersion": "iOS 27.0", "udid": "AAAA-1111" } ], "locale": "\(value)" }
            """, to: project.runsDir, name: name)
            XCTAssertThrowsError(try ProfileResolver.resolve(
                project: project, runName: name)) { error in
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
        { "app": "sampleapp", "devices": [ { "platform": "ios", "machine": "local", "name": "メイン機", "osVersion": "iOS 27.0", "udid": "AAAA-1111" } ], "locale": "ja JP" }
        """#.data(using: .utf8)!

        let (errors, _) = ProfileResolver.validate(
            kind: .run, data: data, context: "runs/badLocale.json")
        XCTAssertTrue(errors.contains { $0.contains("locale") },
                      "locale エラーが出るはず: \(errors)")
    }

    // MARK: - 実機(kind: physical)

    /// 実機 1 台ずつを含む実行プロファイル一式を書く
    private func writePhysicalFixture(iosEngine: String? = nil) throws {
        try write("""
        { "ios":     { "app": "com.example.app" },
          "android": { "app": "com.example.app" } }
        """, to: project.appsDir, name: "app")
        let engineField = iosEngine.map { ", \"engine\": \"\($0)\"" } ?? ""
        try write("""
        { "app": "app", "devices": [
              { "platform": "ios", "machine": "local", "name": "実機iPhone", "kind": "physical",
                "udid": "00008130-000A1B2C3D4E5678"\(engineField) },
              { "platform": "android", "machine": "local", "name": "実機Pixel", "kind": "physical",
                "serial": "14141JEC204922" } ] }
        """, to: project.runsDir, name: "r")
    }

    func testPhysicalDeviceKeepsIdentifiers() throws {
        try writePhysicalFixture()
        let resolved = try ProfileResolver.resolve(project: project, runName: "r")
        XCTAssertTrue(resolved.iosDevices[0].spec.isPhysical)
        XCTAssertEqual(resolved.iosDevices[0].spec.udid, "00008130-000A1B2C3D4E5678")
        XCTAssertTrue(resolved.androidDevices[0].spec.isPhysical)
        XCTAssertEqual(resolved.androidDevices[0].spec.serial, "14141JEC204922")
    }

    func testPhysicalIosDeviceForcesXcuitestEngine() throws {
        // iosInappEngine の既定(true→hybrid)を実機は無視する。ここで潰さないと inapp 経路に入る
        try writePhysicalFixture()
        let resolved = try ProfileResolver.resolve(project: project, runName: "r")
        XCTAssertEqual(resolved.iosDevices[0].spec.engine, "xcuitest")
    }

    func testPhysicalIosDeviceRejectsInappEngine() throws {
        try writePhysicalFixture(iosEngine: "inapp")
        XCTAssertThrowsError(
            try ProfileResolver.resolve(project: project, runName: "r")
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
        { "app": "app", "devices": [ { "platform": "android", "machine": "local", "name": "実機", "kind": "physical" } ] }
        """, to: project.runsDir, name: "r")
        XCTAssertThrowsError(
            try ProfileResolver.resolve(project: project, runName: "r")
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
        { "app": "app", "devices": [ { "platform": "ios", "machine": "local", "name": "シミュ", "osVersion": "iOS 27.0" }, { "platform": "ios", "machine": "local", "name": "壊れた実機", "enabled": false, "kind": "physical" } ] }
        """, to: project.runsDir, name: "r")
        let resolved = try ProfileResolver.resolve(project: project, runName: "r")
        XCTAssertEqual(resolved.devices.map(\.name), ["シミュ"])
    }

    func testPhysicalDeviceKeepsDisplayOnlyModelAndOS() throws {
        // model/osVersion は表示専用(同定には使わない)。未知キー警告を出さず素通しすること
        try write("""
        { "ios": { "app": "com.example.app" } }
        """, to: project.appsDir, name: "app")
        try write("""
        { "app": "app", "devices": [ { "platform": "ios", "machine": "local", "name": "実機", "kind": "physical", "udid": "00008130-AAAA", "model": "iPhone 15 Pro", "osVersion": "iOS 26.5.2" } ] }
        """, to: project.runsDir, name: "r")
        let resolved = try ProfileResolver.resolve(project: project, runName: "r")
        XCTAssertEqual(resolved.iosDevices[0].spec.model, "iPhone 15 Pro")
        XCTAssertEqual(resolved.iosDevices[0].spec.osVersion, "iOS 26.5.2")
        XCTAssertTrue(resolved.warnings.isEmpty, "model は既知キー: \(resolved.warnings)")
    }

    // MARK: - appPathPhysical 未指定の警告(F2: リモートの子は原本を持たずステージ済みの
    // 複製(installPath)だけを持つ。sourcePath だけを見ると常に nil になり誤って鳴っていた)

    private func writePhysicalWithoutAppPathPhysicalFixture() throws {
        try write("""
        { "ios": { "app": "com.example.app", "appPath": "builds/SampleApp.app" } }
        """, to: project.appsDir, name: "app")
        try write("""
        { "app": "app", "devices": [ { "platform": "ios", "machine": "local", "name": "実機", "kind": "physical", "udid": "00008130-AAAA" } ] }
        """, to: project.runsDir, name: "r")
    }

    private func writeDeviceBuildInfoPlist(at appBundle: URL) throws {
        try FileManager.default.createDirectory(at: appBundle, withIntermediateDirectories: true)
        let plist: [String: Any] = ["CFBundleSupportedPlatforms": ["iPhoneOS"]]
        let data = try PropertyListSerialization.data(fromPropertyList: plist, format: .xml, options: 0)
        try data.write(to: appBundle.appendingPathComponent("Info.plist"))
    }

    /// 原本(sourcePath)が読めなくても、ステージ済みの複製(installPath)が実機用ビルドなら鳴らさない
    func testPhysicalDeviceWarningFallsBackToStagedInstallPathWhenSourceIsMissing() throws {
        try writePhysicalWithoutAppPathPhysicalFixture()
        // 原本は作らない(リモートの子を模す)。ステージ済みの複製だけを実機用ビルドとして用意する
        let workspaceRoot = project.rootURL.appendingPathComponent("workspace")
        let installPath = WorkspaceAppStaging.installPath(
            declared: "builds/SampleApp.app", workspaceRoot: workspaceRoot)
        try writeDeviceBuildInfoPlist(at: URL(fileURLWithPath: installPath))

        let resolved = try ProfileResolver.resolve(project: project, runName: "r")
        XCTAssertTrue(resolved.warnings.isEmpty,
                      "複製が実機用ビルドなら appPathPhysical 未指定の警告は鳴らさない: \(resolved.warnings)")
    }

    /// 原本もステージ済みの複製も読めなければ、従来どおり(安全側に倒して)鳴らす
    func testPhysicalDeviceWarningFiresWhenNeitherSourceNorInstallPathIsReadable() throws {
        try writePhysicalWithoutAppPathPhysicalFixture()
        let resolved = try ProfileResolver.resolve(project: project, runName: "r")
        XCTAssertTrue(resolved.warnings.contains { $0.contains("appPathPhysical") },
                      "原本も複製も読めなければ従来どおり鳴らす: \(resolved.warnings)")
    }

    // MARK: - FM トグル(heal/fmTextOcclusionCheck/screenLooksLike)

    func testFMTogglesDefaultsWhenUnspecified() throws {
        try writeStandardFixture()  // "all" は heal:true 明示。fmTextOcclusionCheck/screenLooksLike は未指定
        let resolved = try ProfileResolver.resolve(
            project: project, runName: "all")
        XCTAssertTrue(resolved.fm.enabled)
        XCTAssertTrue(resolved.heal, "heal 明示 true")
        // **2026-09-03 にオプトインをやめた**(ユーザー決定)。3箇所(ここ / JSON スキーマ /
        // 拡張のフォーム)で既定が一致していないと、GUI で作ったプロファイルと CLI の挙動がずれる
        XCTAssertTrue(resolved.fm.fmTextOcclusionCheck, "テキストの視覚検証の既定は true")
        XCTAssertTrue(resolved.fm.screenLooksLike, "省略時は既定 true のはず")
    }

    func testHealDefaultsToTrueWhenFullyUnspecified() throws {
        try write("""
        { "ios": { "app": "com.example.app" } }
        """, to: project.appsDir, name: "app6")
        try write(#"{ "app": "app6", "devices": [ { "platform": "ios", "machine": "local", "name": "d", "osVersion": "iOS 27.0" } ] }"#,
                  to: project.runsDir, name: "r")
        let resolved = try ProfileResolver.resolve(project: project, runName: "r")
        XCTAssertTrue(resolved.fm.enabled)
        XCTAssertTrue(resolved.heal, "heal の既定は true")
        XCTAssertTrue(resolved.fm.fmTextOcclusionCheck, "テキストの視覚検証の既定は true(2026-09-03 に変更)")
        XCTAssertTrue(resolved.fm.screenLooksLike)
    }

    /// FMConfig.enabled は fmTextOcclusionCheck/screenLooksLike のどちらかが true のときだけ true
    /// (両方 false のとき、実行バイナリへ --no-fm が渡って FM を一切呼ばない。親スイッチは無い)
    func testFMEnabledIsFalseOnlyWhenBothSubFlagsAreFalse() throws {
        try writeStandardFixture()
        try write("""
        { "app": "sampleapp", "devices": [ { "platform": "ios", "machine": "local", "name": "メイン機", "osVersion": "iOS 27.0", "udid": "AAAA-1111" } ],
          "heal": true, "fmTextOcclusionCheck": false, "screenLooksLike": false }
        """, to: project.runsDir, name: "bothoff")
        let bothOff = try ProfileResolver.resolve(
            project: project, runName: "bothoff")
        XCTAssertFalse(bothOff.fm.enabled)
        XCTAssertTrue(bothOff.heal, "heal は FM の配下ではない(両方 false でも heal:true のまま)")
        XCTAssertFalse(bothOff.fm.fmTextOcclusionCheck)
        XCTAssertFalse(bothOff.fm.screenLooksLike)

        try write("""
        { "app": "sampleapp", "devices": [ { "platform": "ios", "machine": "local", "name": "メイン機", "osVersion": "iOS 27.0", "udid": "AAAA-1111" } ],
          "fmTextOcclusionCheck": true, "screenLooksLike": false }
        """, to: project.runsDir, name: "fpconly")
        let fpcOnly = try ProfileResolver.resolve(
            project: project, runName: "fpconly")
        XCTAssertTrue(fpcOnly.fm.enabled, "片方だけでも true なら enabled")

        try write("""
        { "app": "sampleapp", "devices": [ { "platform": "ios", "machine": "local", "name": "メイン機", "osVersion": "iOS 27.0", "udid": "AAAA-1111" } ],
          "fmTextOcclusionCheck": false, "screenLooksLike": true }
        """, to: project.runsDir, name: "sllonly")
        let sllOnly = try ProfileResolver.resolve(
            project: project, runName: "sllonly")
        XCTAssertTrue(sllOnly.fm.enabled, "片方だけでも true なら enabled")
    }

    /// 撤去した `triage` キー(FM の失敗トリアージ。maintainer-notes §21)が残ったプロファイルも
    /// 解決でき、run を止めずに「無視する」とだけ言う。他の FM トグルは巻き添えにしない
    func testLeftoverTriageKeyIsIgnoredWithAWarning() throws {
        try writeStandardFixture()
        try write("""
        { "app": "sampleapp", "devices": [ { "platform": "ios", "machine": "local", "name": "メイン機", "osVersion": "iOS 27.0", "udid": "AAAA-1111" } ], "triage": false }
        """, to: project.runsDir, name: "leftover")
        let resolved = try ProfileResolver.resolve(
            project: project, runName: "leftover")
        XCTAssertTrue(resolved.fm.enabled)
        XCTAssertTrue(resolved.heal)
        XCTAssertTrue(resolved.fm.fmTextOcclusionCheck)
        XCTAssertTrue(resolved.fm.screenLooksLike)
        XCTAssertEqual(resolved.warnings, ["runs/leftover.json: unknown key \"triage\" is ignored"])
    }

    func testIndividualSubFlagsFollowExplicitValues() throws {
        try writeStandardFixture()
        // 既定と逆向きの明示指定(heal/screenLooksLike=OFF・fmTextOcclusionCheck=ON)が個別に効くこと
        try write("""
        { "app": "sampleapp", "devices": [ { "platform": "ios", "machine": "local", "name": "メイン機", "osVersion": "iOS 27.0", "udid": "AAAA-1111" } ],
          "heal": false, "fmTextOcclusionCheck": true, "screenLooksLike": false }
        """, to: project.runsDir, name: "subsoff")
        let resolved = try ProfileResolver.resolve(
            project: project, runName: "subsoff")
        XCTAssertTrue(resolved.fm.enabled, "fm 自体は既定 true のまま")
        XCTAssertFalse(resolved.heal)
        XCTAssertTrue(resolved.fm.fmTextOcclusionCheck, "明示 true で有効化できること")
        XCTAssertFalse(resolved.fm.screenLooksLike)
    }

    /// 改名前のキー `screenIs` は読まない(未公開のツールなので移行処理を置かない)。
    /// 未知キーとして警告し、screenLooksLike は既定の true のまま
    func testOldScreenIsKeyIsAnUnknownKey() throws {
        try writeStandardFixture()
        try write("""
        { "app": "sampleapp", "devices": [ { "platform": "ios", "machine": "local", "name": "メイン機", "osVersion": "iOS 27.0", "udid": "AAAA-1111" } ], "screenIs": false }
        """, to: project.runsDir, name: "oldkey")
        let resolved = try ProfileResolver.resolve(project: project, runName: "oldkey")
        XCTAssertTrue(resolved.fm.screenLooksLike)
        XCTAssertEqual(resolved.warnings, ["runs/oldkey.json: unknown key \"screenIs\" is ignored"])
    }

    // MARK: - containerInference(FM とは独立。既定 true)

    func testContainerInferenceDefaultsToTrueAndFollowsExplicitFalse() throws {
        try writeStandardFixture()
        let onByDefault = try ProfileResolver.resolve(
            project: project, runName: "all")
        XCTAssertTrue(onByDefault.containerInference, "省略時は既定 true のはず")

        // FM が実質無効(両トグル false)でも巻き込まれない(FM のサブフラグではない)ことも同時に見る
        try write("""
        { "app": "sampleapp", "devices": [ { "platform": "ios", "machine": "local", "name": "メイン機", "osVersion": "iOS 27.0", "udid": "AAAA-1111" } ],
          "fmTextOcclusionCheck": false, "screenLooksLike": false, "containerInference": false }
        """, to: project.runsDir, name: "ciofffmoff")
        let off = try ProfileResolver.resolve(
            project: project, runName: "ciofffmoff")
        XCTAssertFalse(off.containerInference)

        try write("""
        { "app": "sampleapp", "devices": [ { "platform": "ios", "machine": "local", "name": "メイン機", "osVersion": "iOS 27.0", "udid": "AAAA-1111" } ],
          "fmTextOcclusionCheck": false, "screenLooksLike": false }
        """, to: project.runsDir, name: "fmoffonly")
        let fmOffOnly = try ProfileResolver.resolve(
            project: project, runName: "fmoffonly")
        XCTAssertTrue(fmOffOnly.containerInference, "FM が無効でも補正は止まらない")
        XCTAssertTrue(fmOffOnly.warnings.isEmpty, "containerInference は既知キー: \(fmOffOnly.warnings)")
    }

    // MARK: - ocrTextOcclusionCheck(occlusion guard 前段の Vision OCR 事前判定。既定 true。親スイッチは無い)

    func testOcrTextOcclusionCheckDefaultsToTrueAndFollowsExplicitValue() throws {
        try writeStandardFixture()
        let onByDefault = try ProfileResolver.resolve(
            project: project, runName: "all")
        XCTAssertTrue(onByDefault.ocrTextOcclusionCheck, "省略時は既定 true のはず")

        try write("""
        { "app": "sampleapp", "devices": [ { "platform": "ios", "machine": "local", "name": "メイン機", "osVersion": "iOS 27.0", "udid": "AAAA-1111" } ], "ocrTextOcclusionCheck": false }
        """, to: project.runsDir, name: "ocrfpcoff")
        let off = try ProfileResolver.resolve(
            project: project, runName: "ocrfpcoff")
        XCTAssertFalse(off.ocrTextOcclusionCheck)
        XCTAssertFalse(off.warnings.contains { $0.contains("ocrTextOcclusionCheck") },
                       "ocrTextOcclusionCheck は既知キー: \(off.warnings)")

        // fmTextOcclusionCheck(FM 側)が off でも resolve 層では巻き込まれない(ゲートは downstream の
        // occlusion guard 実行有無であって、ここではない)ことを同時に見る
        try write("""
        { "app": "sampleapp", "devices": [ { "platform": "ios", "machine": "local", "name": "メイン機", "osVersion": "iOS 27.0", "udid": "AAAA-1111" } ], "fmTextOcclusionCheck": false }
        """, to: project.runsDir, name: "ocrfpcfmoffonly")
        let fpcOffOnly = try ProfileResolver.resolve(
            project: project, runName: "ocrfpcfmoffonly")
        XCTAssertTrue(fpcOffOnly.ocrTextOcclusionCheck,
                      "fmTextOcclusionCheck:false でも ocrTextOcclusionCheck は既定のまま")
        XCTAssertFalse(fpcOffOnly.fm.fmTextOcclusionCheck)
    }

    /// 実機の検査は enabled の台だけ(無効の台の不備で保存・実行を止めない)
    func testValidateRunReportsPhysicalErrorsOnlyForEnabledDevices() throws {
        let data = #"""
        { "app": "a", "devices": [
          { "platform": "ios", "machine": "local", "name": "実機", "kind": "physical", "engine": "inapp" },
          { "platform": "android", "machine": "local", "name": "実機A", "kind": "physical" },
          { "platform": "android", "machine": "local", "name": "無効の実機", "kind": "physical", "enabled": false } ] }
        """#.data(using: .utf8)!
        let (errors, warnings) = ProfileResolver.validate(
            kind: .run, data: data, context: "runs/r.json")
        XCTAssertFalse(errors.contains { $0.contains("無効の実機") }, "\(errors)")
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
