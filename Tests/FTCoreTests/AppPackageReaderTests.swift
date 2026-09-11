// .app と .ipa を同じ口で読めること、UI フレームワークの判定がどちらからも同じ答えを出すこと、
// 判定の結果が bundle ID ごとの台帳に残って材料が無いときに使われることの固定。
// .ipa は本物の zip(/usr/bin/zip)で作る —— 一覧・取り出しは unzip に頼るので偽物では確かめられない

import XCTest
@testable import FTCore

final class AppPackageReaderTests: XCTestCase {
    private var tempDir: URL!
    private var savedLedgerDir: String?

    override func setUpWithError() throws {
        tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("AppPackageReaderTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        savedLedgerDir = ProcessInfo.processInfo.environment[AppFrameworkLedger.directoryOverrideKey]
        setenv(AppFrameworkLedger.directoryOverrideKey, tempDir.appendingPathComponent("ledger").path, 1)
    }

    override func tearDownWithError() throws {
        if let savedLedgerDir { setenv(AppFrameworkLedger.directoryOverrideKey, savedLedgerDir, 1) }
        else { unsetenv(AppFrameworkLedger.directoryOverrideKey) }
        try? FileManager.default.removeItem(at: tempDir)
    }

    // MARK: - 材料

    /// executable: 実行ファイルの中身 / debugDylibMarker: `<exe>.debug.dylib` に入れる文字列 /
    /// flutter: Frameworks/Flutter.framework を置く / composeResources: compose-resources を置く
    private func makeApp(_ name: String, info: [String: Any] = [:], executable: String = "plain binary",
                         debugDylib: String? = nil, flutter: Bool = false,
                         composeResources: Bool = false) throws -> String {
        let app = tempDir.appendingPathComponent("\(name).app")
        try FileManager.default.createDirectory(at: app, withIntermediateDirectories: true)
        var plist = info
        plist["CFBundleExecutable"] = plist["CFBundleExecutable"] ?? name
        try PropertyListSerialization.data(fromPropertyList: plist, format: .binary, options: 0)
            .write(to: app.appendingPathComponent("Info.plist"))
        try executable.data(using: .utf8)!.write(to: app.appendingPathComponent(name))
        if let debugDylib {
            try debugDylib.data(using: .utf8)!.write(to: app.appendingPathComponent("\(name).debug.dylib"))
        }
        if flutter {
            try FileManager.default.createDirectory(
                at: app.appendingPathComponent("Frameworks/Flutter.framework"), withIntermediateDirectories: true)
            try Data("x".utf8).write(to: app.appendingPathComponent("Frameworks/Flutter.framework/Flutter"))
        }
        if composeResources {
            try FileManager.default.createDirectory(
                at: app.appendingPathComponent("compose-resources"), withIntermediateDirectories: true)
        }
        return app.path
    }

    /// Payload/<Name>.app/… を zip に固めた .ipa
    private func makeIPA(from appPath: String) throws -> String {
        let stage = tempDir.appendingPathComponent("stage-\(UUID().uuidString)")
        let payload = stage.appendingPathComponent("Payload")
        try FileManager.default.createDirectory(at: payload, withIntermediateDirectories: true)
        let name = (appPath as NSString).lastPathComponent
        try FileManager.default.copyItem(atPath: appPath, toPath: payload.appendingPathComponent(name).path)
        let ipa = tempDir.appendingPathComponent("\(UUID().uuidString).ipa").path
        let zip = try Shell.run(["zip", "-qry", ipa, "Payload"], cwd: stage, timeout: 60)
        XCTAssertEqual(zip.status, 0, zip.output)
        return ipa
    }

    // MARK: - 読み口

    func testBundleAndIPAReadTheSameThings() throws {
        let app = try makeApp("Loc", info: ["CFBundleDisplayName": "Store"], executable: "abc SkikoUIView xyz")
        let lproj = URL(fileURLWithPath: app).appendingPathComponent("ja.lproj")
        try FileManager.default.createDirectory(at: lproj, withIntermediateDirectories: true)
        try Data("\"CFBundleDisplayName\" = \"ストア\";\n".utf8).write(to: lproj.appendingPathComponent("InfoPlist.strings"))
        let ipa = try makeIPA(from: app)

        for path in [app, ipa] {
            let reader = try XCTUnwrap(AppPackageReader.open(path: path), path)
            XCTAssertEqual(reader.infoPlist?["CFBundleDisplayName"] as? String, "Store", path)
            XCTAssertTrue(reader.exists("Info.plist"), path)
            XCTAssertTrue(reader.exists("ja.lproj"), "ディレクトリも exists で見える: \(path)")
            XCTAssertFalse(reader.exists("Frameworks/Flutter.framework"), path)
            XCTAssertEqual(Set(reader.rootEntries()), ["Info.plist", "Loc", "ja.lproj"], path)
            XCTAssertEqual(reader.contains("SkikoUIView", in: "Loc"), true, path)
            XCTAssertEqual(reader.contains("Flutter", in: "Loc"), false, path)
            XCTAssertNil(reader.contains("x", in: "missing"), "無いファイルは nil: \(path)")
            XCTAssertEqual(AppBundleInspector.iconNameCandidates(appPath: path), ["Store", "ストア"], path)
        }
    }

    func testOpenRejectsMissingOrForeignFiles() throws {
        XCTAssertNil(AppPackageReader.open(path: nil))
        XCTAssertNil(AppPackageReader.open(path: tempDir.appendingPathComponent("nope.app").path))
        let notZip = tempDir.appendingPathComponent("bogus.ipa")
        try Data("not a zip".utf8).write(to: notZip)
        XCTAssertNil(AppPackageReader.open(path: notZip.path))
    }

    func testAppPrefixIsFoundEvenWithoutDirectoryEntries() {
        XCTAssertEqual(AppPackageReader.appPrefix(entries: ["Payload/My App.app/Info.plist"]), "Payload/My App.app/")
        XCTAssertNil(AppPackageReader.appPrefix(entries: ["README", "Payload/notes.txt"]))
    }

    // MARK: - UI フレームワークの判定(.app / .ipa で同じ)

    func testFlutterIsDetectedByTheEngineFramework() throws {
        let app = try makeApp("Fl", flutter: true)
        XCTAssertEqual(AppBundleInspector.detect(appPath: app), "flutter")
        XCTAssertEqual(AppBundleInspector.detect(appPath: try makeIPA(from: app)), "flutter")
    }

    /// Compose の目印は実行ファイルの中のクラス名。デバッグビルドは本体が `<exe>.debug.dylib` に居る
    func testComposeIsDetectedByTheBinaryMarkerInEitherPlace() throws {
        let release = try makeApp("Rel", executable: "…SkikoUIView…")
        XCTAssertEqual(AppBundleInspector.detect(appPath: release), "compose")
        XCTAssertEqual(AppBundleInspector.detect(appPath: try makeIPA(from: release)), "compose")

        let debug = try makeApp("Dbg", executable: "tiny stub", debugDylib: "…SkikoUIView…")
        XCTAssertEqual(AppBundleInspector.detect(appPath: debug), "compose")
        XCTAssertEqual(AppBundleInspector.detect(appPath: try makeIPA(from: debug)), "compose")
    }

    func testNoMarkerIsUIKitNotUnknown() throws {
        let app = try makeApp("Plain")
        XCTAssertEqual(AppBundleInspector.detect(appPath: app), "uikit")
        XCTAssertEqual(AppBundleInspector.detect(appPath: try makeIPA(from: app)), "uikit")
    }

    func testDevicePlatformIsReadFromAnIPA() throws {
        let app = try makeApp("Dev", info: ["CFBundleSupportedPlatforms": ["iPhoneOS"]])
        XCTAssertEqual(AppBundleInspector.declaresDevicePlatform(appPath: try makeIPA(from: app)), true)
    }

    // MARK: - 台帳(材料が無いときの答え)

    func testDetectionIsRememberedByBundleIDAndUsedWithoutTheFile() throws {
        let app = try makeApp("Fl", flutter: true)
        XCTAssertEqual(AppBundleInspector.detect(appPath: app, udid: nil, bundleID: "com.example.fl", physical: true),
                       "flutter")
        // 材料も udid も無い実機: 台帳だけで答える
        XCTAssertEqual(AppBundleInspector.detect(appPath: nil, udid: nil, bundleID: "com.example.fl", physical: true),
                       "flutter")
        XCTAssertNil(AppBundleInspector.detect(appPath: nil, udid: nil, bundleID: "com.example.other", physical: true),
                     "見たことのない bundle ID は不明のまま")
    }

    func testRememberedResultIsReusedOnlyForTheSameFile() throws {
        let app = try makeApp("Rel", executable: "…SkikoUIView…")
        XCTAssertEqual(AppBundleInspector.detect(appPath: app, udid: nil, bundleID: "com.example.c", physical: true),
                       "compose")
        let stored = try XCTUnwrap(AppFrameworkLedger.load(bundleID: "com.example.c"))
        XCTAssertEqual(stored.sourcePath, app)
        XCTAssertNotNil(stored.sourceModified)
        // 同じ場所にビルドし直したら読み直す(Info.plist の大きさで気づく)
        try PropertyListSerialization.data(fromPropertyList: ["CFBundleExecutable": "Rel", "K": "v"],
                                           format: .binary, options: 0)
            .write(to: URL(fileURLWithPath: app).appendingPathComponent("Info.plist"))
        try Data("plain now".utf8).write(to: URL(fileURLWithPath: app).appendingPathComponent("Rel"))
        XCTAssertEqual(AppBundleInspector.detect(appPath: app, udid: nil, bundleID: "com.example.c", physical: true),
                       "uikit")
    }
}
