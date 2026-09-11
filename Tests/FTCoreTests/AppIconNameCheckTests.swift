import XCTest
@testable import FTCore

/// appName はアイコン名を兼ねる(tapAppIcon() の既定名・アラートの「前の run の残り」判定)。
/// バンドルの表示名と食い違う appName をプロファイル解決で警告する規則の固定
/// (AppBundleInspector.appNameMismatchWarning)
final class AppIconNameCheckTests: XCTestCase {
    var tempDir: URL!
    var project: TestProject!

    override func setUpWithError() throws {
        tempDir = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("AppIconNameCheckTests-\(UUID().uuidString)")
        project = TestProject(name: "P", rootURL: tempDir.appendingPathComponent("TestProjects/P"))
        for dir in [project.appsDir, project.machinesDir, project.runsDir] {
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        }
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: tempDir)
    }

    // MARK: - 候補(純粋関数)

    func testDisplayNameWinsOverBundleName() {
        XCTAssertEqual(AppBundleInspector.iconNameCandidates(
            infoPlist: ["CFBundleDisplayName": "FT E2E iOS", "CFBundleName": "FTE2EIOS"], localized: []),
            ["FT E2E iOS"])
    }

    func testBundleNameIsTheFallback() {
        XCTAssertEqual(AppBundleInspector.iconNameCandidates(
            infoPlist: ["CFBundleName": "FTE2EIOS"], localized: []), ["FTE2EIOS"])
    }

    func testLocalizedNamesAreAllCandidates() {
        XCTAssertEqual(AppBundleInspector.iconNameCandidates(
            infoPlist: ["CFBundleDisplayName": "Store"],
            localized: [["CFBundleDisplayName": "ストア"], ["CFBundleDisplayName": "Store"], [:]]),
            ["Store", "ストア"])
    }

    func testNoNameMeansUnknown() {
        XCTAssertEqual(AppBundleInspector.iconNameCandidates(infoPlist: [:], localized: []), [])
        XCTAssertEqual(AppBundleInspector.iconNameCandidates(appPath: nil), [])
    }

    // MARK: - 警告(純粋関数)

    func testMismatchWarnsAndNamesBothSides() throws {
        let warning = try XCTUnwrap(AppBundleInspector.appNameMismatchWarning(
            appRef: "ft_e2e_ios_device", platform: "ios", appName: "FT E2E iOS(実機)",
            candidates: ["FT E2E iOS"]))
        XCTAssertTrue(warning.contains("apps/ft_e2e_ios_device.json"), warning)
        XCTAssertTrue(warning.contains("\"FT E2E iOS(実機)\""), warning)
        XCTAssertTrue(warning.contains("\"FT E2E iOS\""), warning)
        XCTAssertTrue(warning.contains("tapAppIcon()"), warning)
    }

    func testMatchOrUnknownStaysSilent() {
        XCTAssertNil(AppBundleInspector.appNameMismatchWarning(
            appRef: "a", platform: "ios", appName: "ストア", candidates: ["Store", "ストア"]))
        XCTAssertNil(AppBundleInspector.appNameMismatchWarning(
            appRef: "a", platform: "ios", appName: "anything", candidates: []))
    }

    // MARK: - 実ファイルの .app

    func testReadsInfoPlistStringsAndLoctable() throws {
        let app = try makeApp("builds/Loc.app", info: ["CFBundleDisplayName": "Store"],
                              lprojStrings: ["ja": "\"CFBundleDisplayName\" = \"ストア\";\n"],
                              loctable: ["de": ["CFBundleDisplayName": "Laden"]])
        XCTAssertEqual(AppBundleInspector.iconNameCandidates(appPath: app.path),
                       ["Store", "ストア", "Laden"])
    }

    // MARK: - プロファイル解決(run・validate-profile・MCP が表示する warnings)

    func testResolveWarnsWhenAppNameDiffersFromTheBundle() throws {
        _ = try makeApp("builds/Dev.app", info: ["CFBundleDisplayName": "FT E2E iOS"])
        let resolved = try resolve(appName: "FT E2E iOS(実機)", appPath: "builds/Dev.app")
        let hits = resolved.warnings.filter { $0.contains("is not the name shown under the app icon") }
        XCTAssertEqual(hits.count, 1, "\(resolved.warnings)")
    }

    func testResolveIsSilentWhenAppNameMatches() throws {
        _ = try makeApp("builds/Dev.app", info: ["CFBundleDisplayName": "FT E2E iOS"])
        let resolved = try resolve(appName: "FT E2E iOS", appPath: "builds/Dev.app")
        XCTAssertFalse(resolved.warnings.contains { $0.contains("app icon") }, "\(resolved.warnings)")
    }

    func testResolveIsSilentWhenAppNameMatchesALocalizedName() throws {
        _ = try makeApp("builds/Loc.app", info: ["CFBundleDisplayName": "Store"],
                        lprojStrings: ["ja": "\"CFBundleDisplayName\" = \"ストア\";\n"])
        let resolved = try resolve(appName: "ストア", appPath: "builds/Loc.app")
        XCTAssertFalse(resolved.warnings.contains { $0.contains("app icon") }, "\(resolved.warnings)")
    }

    func testResolveIsSilentWhenTheBundleCannotBeRead() throws {
        let resolved = try resolve(appName: "whatever", appPath: "builds/Missing.app")
        XCTAssertFalse(resolved.warnings.contains { $0.contains("app icon") }, "\(resolved.warnings)")
    }

    // MARK: - helpers

    @discardableResult
    private func makeApp(_ relative: String, info: [String: Any],
                         lprojStrings: [String: String] = [:],
                         loctable: [String: [String: String]] = [:]) throws -> URL {
        let app = tempDir.appendingPathComponent(relative)
        try FileManager.default.createDirectory(at: app, withIntermediateDirectories: true)
        try PropertyListSerialization.data(fromPropertyList: info, format: .binary, options: 0)
            .write(to: app.appendingPathComponent("Info.plist"))
        for (language, text) in lprojStrings {
            let dir = app.appendingPathComponent("\(language).lproj")
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            try text.data(using: .utf8)!.write(to: dir.appendingPathComponent("InfoPlist.strings"))
        }
        if !loctable.isEmpty {
            try PropertyListSerialization.data(fromPropertyList: loctable, format: .binary, options: 0)
                .write(to: app.appendingPathComponent("InfoPlist.loctable"))
        }
        return app
    }

    private func resolve(appName: String, appPath: String) throws -> ResolvedProfile {
        try """
        { "ios": { "appName": "\(appName)", "app": "com.example.app", "appPath": "\(appPath)",
                   "autoInstall": false } }
        """.data(using: .utf8)!.write(to: project.appsDir.appendingPathComponent("app.json"))
        try """
        { "ios": { "devices": [ { "name": "機1", "simulator": "iPhone 17 Pro", "os": "27.0",
                                  "udid": "AAAA-1111" } ] } }
        """.data(using: .utf8)!.write(to: project.machinesDir.appendingPathComponent("M.json"))
        try """
        { "app": "app", "devices": [ { "name": "機1" } ] }
        """.data(using: .utf8)!.write(to: project.runsDir.appendingPathComponent("r.json"))
        return try ProfileResolver.resolve(project: project, runName: "r", machineName: "M")
    }
}
