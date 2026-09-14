// AppUIFrameworkQuery の答える順(静的 → 動的 → 不明)と、答えてはいけない材料を捨てることの固定。
// 台帳は一時ディレクトリへ差し替え、プロセス内の控えは毎回消す(同じプロセスの他テストと混ざらない)

import XCTest
@testable import FTCore

final class AppUIFrameworkQueryTests: XCTestCase {
    private var tempDir: URL!
    private var savedLedgerDir: String?

    override func setUpWithError() throws {
        tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("AppUIFrameworkQueryTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        savedLedgerDir = ProcessInfo.processInfo.environment[AppFrameworkLedger.directoryOverrideKey]
        setenv(AppFrameworkLedger.directoryOverrideKey, tempDir.appendingPathComponent("ledger").path, 1)
        AppUIFrameworkQuery.forgetRememberedAnswers()
    }

    override func tearDownWithError() throws {
        if let savedLedgerDir { setenv(AppFrameworkLedger.directoryOverrideKey, savedLedgerDir, 1) }
        else { unsetenv(AppFrameworkLedger.directoryOverrideKey) }
        AppUIFrameworkQuery.forgetRememberedAnswers()
        try? FileManager.default.removeItem(at: tempDir)
    }

    /// bundleID を宣言した .app(compose は実行ファイルの `SkikoUIView` = in-app の自己申告が見ない目印)
    private func makeApp(_ name: String, bundleID: String?, executable: String = "plain binary") throws -> String {
        let app = tempDir.appendingPathComponent("\(name).app")
        try FileManager.default.createDirectory(at: app, withIntermediateDirectories: true)
        var plist: [String: Any] = ["CFBundleExecutable": name]
        if let bundleID { plist["CFBundleIdentifier"] = bundleID }
        try PropertyListSerialization.data(fromPropertyList: plist, format: .binary, options: 0)
            .write(to: app.appendingPathComponent("Info.plist"))
        try Data(executable.utf8).write(to: app.appendingPathComponent(name))
        return app.path
    }

    private func subject(_ bundleID: String?, appPath: String? = nil, platform: String = "ios",
                         physical: Bool = true) -> AppUIFrameworkQuery.Subject {
        // physical = true: 単体テストから simctl を撃たない
        .init(platform: platform, bundleID: bundleID, appPath: appPath, udid: nil, physical: physical)
    }

    // MARK: - 答える順

    /// 静的に決まればブリッジには聞かない。自己申告が違うことを言っても静的な答えが勝つ
    /// (リソースを使わない Compose アプリを in-app ブリッジは uikit と申告する)
    func testStaticAnswerWinsAndTheBridgeIsNotAsked() async throws {
        let app = try makeApp("Cmp", bundleID: "com.example.cmp", executable: "…SkikoUIView…")
        var asked = false
        let answer = await AppUIFrameworkQuery.resolve(subject("com.example.cmp", appPath: app)) {
            asked = true
            return "uikit"
        }
        XCTAssertEqual(answer, .known(.compose, source: .package))
        XCTAssertFalse(asked, "静的に決まったのにブリッジへ往復した")
    }

    func testBridgeReportAnswersOnlyWhenNothingStaticDoes() async {
        let answer = await AppUIFrameworkQuery.resolve(subject("com.example.fresh")) { "flutter" }
        XCTAssertEqual(answer, .known(.flutter, source: .bridgeReport))
        XCTAssertNil(AppFrameworkLedger.load(bundleID: "com.example.fresh", platform: "ios"),
                     "自己申告を台帳へ書いた(弱い規則の答えで材料由来の答えを上書きする)")
        let again = await AppUIFrameworkQuery.resolve(subject("com.example.fresh")) { nil }
        XCTAssertEqual(again, .unknown, "自己申告をプロセス内に覚えた")
    }

    /// 不明は不明のまま返す(既定値で埋めない)。知らない語彙の申告も不明
    func testUnknownIsReturnedAsUnknown() async {
        let silent = await AppUIFrameworkQuery.resolve(subject("com.example.none")) { nil }
        XCTAssertEqual(silent, .unknown)
        XCTAssertNil(silent.framework)
        let foreign = await AppUIFrameworkQuery.resolve(subject("com.example.none")) { "swiftui" }
        XCTAssertEqual(foreign, .unknown)
    }

    /// Android のブリッジは申告を持たない = 静的に決まらなければ不明で、ブリッジには聞かない
    func testAndroidNeverAsksTheBridge() async throws {
        let app = try makeApp("Any", bundleID: "com.example.android", executable: "…SkikoUIView…")
        var asked = false
        let answer = await AppUIFrameworkQuery.resolve(subject("com.example.android", appPath: app,
                                                               platform: "android")) {
            asked = true
            return "compose"
        }
        XCTAssertEqual(answer, .unknown)
        XCTAssertFalse(asked)
        // staticAnswer は単独でも呼ばれる(MCP のドライバ生成・xcuitest の run)
        XCTAssertEqual(AppUIFrameworkQuery.staticAnswer(for: subject("com.example.android", appPath: app,
                                                                    platform: "android")), .unknown)
    }

    // MARK: - 静的な材料

    /// プロファイルのアプリ(appPath)とシナリオの対象アプリは別になりうる。別アプリのパッケージで答えない
    func testPackageOfAnotherAppIsNotUsed() async throws {
        let app = try makeApp("Cmp", bundleID: "com.example.profileapp", executable: "…SkikoUIView…")
        let answer = await AppUIFrameworkQuery.resolve(subject("com.apple.Preferences", appPath: app)) { nil }
        XCTAssertEqual(answer, .unknown)
        XCTAssertNil(AppFrameworkLedger.load(bundleID: "com.apple.Preferences", platform: "ios"),
                     "別アプリの判定を対象アプリの名で台帳に残した")
    }

    /// 材料が無くなっても、以前に材料を見た bundle ID は台帳で答える(物理端末の唯一の静的な答え)
    func testLedgerAnswersOnceThePackageIsGone() throws {
        let app = try makeApp("Rn", bundleID: "com.example.rn")
        XCTAssertEqual(AppUIFrameworkQuery.staticAnswer(for: subject("com.example.rn", appPath: app)),
                       .known(.uikit, source: .package))
        AppUIFrameworkQuery.forgetRememberedAnswers()   // 別プロセス = 控えが無い
        XCTAssertEqual(AppUIFrameworkQuery.staticAnswer(for: subject("com.example.rn")),
                       .known(.uikit, source: .ledger))
    }

    /// 同じプロセスでは、appPath を持たない呼び手(InAppDriver)にも同じ答えを返す
    func testAnswerIsSharedWithCallersWithoutThePackageInTheSameProcess() throws {
        let app = try makeApp("Cmp", bundleID: "com.example.shared", executable: "…SkikoUIView…")
        _ = AppUIFrameworkQuery.staticAnswer(for: subject("com.example.shared", appPath: app))
        XCTAssertEqual(AppUIFrameworkQuery.staticAnswer(for: subject("com.example.shared")).framework, .compose)
    }

    /// 確かめずに書かれた控え(旧版: 別アプリの判定を対象アプリの名で残しえた)と、古い規則の控え
    /// (RN を uikit と言っていた頃)は、指紋が合っても・材料が無くても使わない
    func testUntrustedLedgerEntriesAreNotUsed() throws {
        let app = try makeApp("Cmp", bundleID: nil, executable: "…SkikoUIView…")
        let fingerprint = try XCTUnwrap(AppFrameworkLedger.fingerprint(path: app))
        func entry(bundle: String?, rules: Int?) -> AppFrameworkLedger.Entry {
            .init(framework: "flutter", sourcePath: app, sourceModified: fingerprint.modified,
                  sourceSize: fingerprint.size, sourceBundleID: bundle, rules: rules)
        }
        let current = UIFrameworkMarkers.rulesVersion
        for (label, stale) in [("確かめていない", entry(bundle: nil, rules: current)),
                               ("古い規則", entry(bundle: "com.example.legacy", rules: current - 1)),
                               ("規則の版が無い", entry(bundle: "com.example.legacy", rules: nil))] {
            AppUIFrameworkQuery.forgetRememberedAnswers()
            AppFrameworkLedger.store(bundleID: "com.example.legacy", platform: "ios", entry: stale)
            XCTAssertEqual(AppUIFrameworkQuery.staticAnswer(for: subject("com.example.legacy")), .unknown,
                           "\(label)の控えを材料無しで使った")
            XCTAssertEqual(AppUIFrameworkQuery.staticAnswer(for: subject("com.example.legacy", appPath: app)),
                           .known(.compose, source: .package), "\(label)の控えを指紋の一致で使った")
        }
        XCTAssertTrue(AppUIFrameworkQuery.ledgerEntryIsTrusted(entry(bundle: "com.example.legacy", rules: current),
                                                               bundleID: "com.example.legacy", rules: current))
    }

    /// simctl の控えは、その台の置き場で指紋も同じときだけ使う
    func testInstalledBundleCacheIsPerSimulatorAndFingerprint() {
        let udid = "11111111-2222-3333-4444-555555555555"
        let path = "/Users/x/Library/Developer/CoreSimulator/Devices/\(udid)/data/Containers/Bundle/Application/U/A.app"
        let entry = AppFrameworkLedger.Entry(framework: "flutter", sourcePath: path, sourceModified: 10,
                                             sourceSize: 20, sourceBundleID: "com.example.fl",
                                             rules: UIFrameworkMarkers.rulesVersion)
        XCTAssertEqual(AppUIFrameworkQuery.installedBundleCacheHit(entry: entry, udid: udid,
                                                                   fingerprint: (10, 20)), .flutter)
        XCTAssertNil(AppUIFrameworkQuery.installedBundleCacheHit(entry: entry, udid: "99999999-0000-0000-0000-000000000000",
                                                                 fingerprint: (10, 20)), "別の台の控え")
        XCTAssertNil(AppUIFrameworkQuery.installedBundleCacheHit(entry: entry, udid: udid,
                                                                 fingerprint: (11, 20)), "入れ直した(指紋が違う)")
        XCTAssertNil(AppUIFrameworkQuery.installedBundleCacheHit(entry: entry, udid: udid, fingerprint: nil),
                     "置き場がもう無い")
    }

    // MARK: - Android

    /// 実マニフェスト(Tests/Fixtures/AndroidManifest)と目印のファイルを zip に固めた .apk
    private func makeAPK(manifest: String, files: [String]) throws -> String {
        let stage = tempDir.appendingPathComponent("apk-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: stage, withIntermediateDirectories: true)
        let fixture = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("Fixtures/AndroidManifest/\(manifest).axml")
        try FileManager.default.copyItem(at: fixture, to: stage.appendingPathComponent("AndroidManifest.xml"))
        for file in files {
            let url = stage.appendingPathComponent(file)
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try Data("x".utf8).write(to: url)
        }
        let apk = tempDir.appendingPathComponent("\(UUID().uuidString).apk").path
        let zip = try Shell.run(["zip", "-qry", apk, "."], cwd: stage, timeout: 60)
        XCTAssertEqual(zip.status, 0, zip.output)
        return apk
    }

    private func android(_ bundleID: String, appPath: String? = nil) -> AppUIFrameworkQuery.Subject {
        .init(platform: "android", bundleID: bundleID, appPath: appPath, udid: nil, physical: false)
    }

    func testAndroidAPKIsJudgedAndRemembered() throws {
        let apk = try makeAPK(manifest: "e2e-flutter", files: ["lib/arm64-v8a/libflutter.so"])
        XCTAssertEqual(AppUIFrameworkQuery.staticAnswer(for: android("com.ftester.e2e.flutter", appPath: apk)),
                       .known(.flutter, source: .package))
        AppUIFrameworkQuery.forgetRememberedAnswers()
        XCTAssertEqual(AppUIFrameworkQuery.staticAnswer(for: android("com.ftester.e2e.flutter")),
                       .known(.flutter, source: .ledger))
    }

    /// パッケージ名の違う APK(= 別アプリ)では答えない
    func testAndroidAPKOfAnotherPackageIsNotUsed() throws {
        let apk = try makeAPK(manifest: "e2e-rn", files: ["lib/x86_64/libreactnative.so"])
        XCTAssertEqual(AppUIFrameworkQuery.staticAnswer(for: android("com.ftester.e2e.flutter", appPath: apk)), .unknown)
    }

    /// CMP は iOS の bundle ID と Android のパッケージ名が同じ。台帳・控えを OS で分けないと互いに上書きする
    func testTheSameIDOnBothOSesDoesNotCollide() throws {
        let apk = try makeAPK(manifest: "e2e-cmp", files: ["lib/arm64-v8a/libflutter.so"])
        let app = try makeApp("Rn", bundleID: "com.ftester.e2e", executable: "…RCTBridge…")
        _ = AppUIFrameworkQuery.staticAnswer(for: android("com.ftester.e2e", appPath: apk))
        _ = AppUIFrameworkQuery.staticAnswer(for: subject("com.ftester.e2e", appPath: app))
        // プロセス内の控えだけで(台帳を消して)答える
        try FileManager.default.removeItem(at: tempDir.appendingPathComponent("ledger"))
        XCTAssertEqual(AppUIFrameworkQuery.staticAnswer(for: android("com.ftester.e2e")), .known(.flutter, source: .package))
        XCTAssertEqual(AppUIFrameworkQuery.staticAnswer(for: subject("com.ftester.e2e")), .known(.reactNative, source: .package))
        // 台帳だけで(控えを消して)答える
        _ = AppUIFrameworkQuery.staticAnswer(for: android("com.ftester.e2e", appPath: apk))
        _ = AppUIFrameworkQuery.staticAnswer(for: subject("com.ftester.e2e", appPath: app))
        AppUIFrameworkQuery.forgetRememberedAnswers()
        XCTAssertEqual(AppUIFrameworkQuery.staticAnswer(for: android("com.ftester.e2e")).framework, .flutter)
        XCTAssertEqual(AppUIFrameworkQuery.staticAnswer(for: subject("com.ftester.e2e")).framework, .reactNative)
    }

    /// OS と材料の種類が食い違うパッケージは読まない(iOS に .apk・Android に .app)
    func testPackageOfTheOtherOSIsNotRead() throws {
        let apk = try makeAPK(manifest: "e2e-cmp", files: ["lib/arm64-v8a/libflutter.so"])
        XCTAssertEqual(AppUIFrameworkQuery.staticAnswer(for: subject("com.ftester.e2e", appPath: apk)), .unknown)
        let app = try makeApp("Cmp", bundleID: "com.ftester.e2e", executable: "…SkikoUIView…")
        XCTAssertEqual(AppUIFrameworkQuery.staticAnswer(for: android("com.ftester.e2e", appPath: app)), .unknown)
    }

    // MARK: - 自己申告の照合

    func testBridgeReportIsUsedOnlyForTheAppThatMadeIt() {
        let status = StatusResponse(ready: true, device: "d", osVersion: "iOS 27", sessionBundleID: "com.example.a",
                                    uiFramework: "compose")
        XCTAssertEqual(AppUIFrameworkQuery.bridgeReport(status, about: "com.example.a"), "compose")
        XCTAssertNil(AppUIFrameworkQuery.bridgeReport(status, about: "com.example.b"), "注入先は別アプリ")
        XCTAssertNil(AppUIFrameworkQuery.bridgeReport(status, about: nil), "照合できない")
        XCTAssertNil(AppUIFrameworkQuery.bridgeReport(nil, about: "com.example.a"))
    }

    // MARK: - 要素単位

    func testElementLevelAnswerFollowsTheAppAndFallsBackToTheElementClass() {
        func element(_ ref: Int, axClass: String?) -> ElementInfo {
            ElementInfo(ref: ref, type: "Button", identifier: nil, label: "e\(ref)", value: nil,
                        placeholder: nil, enabled: true, frame: FTRect(x: 0, y: 0, width: 10, height: 10),
                        depth: 1, axClass: axClass)
        }
        let hosted = element(1, axClass: "UIAccessibilityElement")
        let viewBacked = element(2, axClass: "UIView")
        let classless = element(3, axClass: nil)
        XCTAssertEqual(AppUIFrameworkQuery.hostsOwnTouches(hosted, app: .uikit), false, "アプリの答えが勝つ")
        XCTAssertEqual(AppUIFrameworkQuery.hostsOwnTouches(classless, app: .flutter), true)
        XCTAssertEqual(AppUIFrameworkQuery.hostsOwnTouches(hosted, app: nil), true)
        XCTAssertEqual(AppUIFrameworkQuery.hostsOwnTouches(viewBacked, app: nil), false)
        XCTAssertNil(AppUIFrameworkQuery.hostsOwnTouches(classless, app: nil), "どちらも無ければ不明")
    }
}
