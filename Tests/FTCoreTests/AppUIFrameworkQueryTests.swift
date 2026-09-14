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
        XCTAssertNil(AppFrameworkLedger.load(bundleID: "com.example.fresh"),
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

    func testAndroidIsUnknownAndTheBridgeIsNotAsked() async throws {
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
        XCTAssertNil(AppFrameworkLedger.load(bundleID: "com.apple.Preferences"),
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

    /// 確かめずに書かれた控え(旧版: 別アプリの判定を対象アプリの名で残しえた)は、指紋が合っても使わない
    func testUnverifiedLedgerEntryIsNotTrusted() throws {
        let app = try makeApp("Cmp", bundleID: nil, executable: "…SkikoUIView…")
        let fingerprint = try XCTUnwrap(AppFrameworkLedger.fingerprint(path: app))
        let legacy = AppFrameworkLedger.Entry(framework: "flutter", sourcePath: app,
                                              sourceModified: fingerprint.modified, sourceSize: fingerprint.size,
                                              sourceBundleID: nil)
        AppFrameworkLedger.store(bundleID: "com.example.legacy", entry: legacy)
        XCTAssertEqual(AppUIFrameworkQuery.staticAnswer(for: subject("com.example.legacy", appPath: app)),
                       .known(.compose, source: .package), "確かめていない控えの答えを使った")
        XCTAssertFalse(AppUIFrameworkQuery.ledgerEntryIsTrusted(legacy, bundleID: "com.example.legacy"))
        let simctlDerived = AppFrameworkLedger.Entry(framework: "uikit", sourcePath: nil, sourceModified: nil,
                                                     sourceSize: nil, sourceBundleID: nil)
        XCTAssertTrue(AppUIFrameworkQuery.ledgerEntryIsTrusted(simctlDerived, bundleID: "com.example.legacy"),
                      "bundle ID で引いた答え(材料のパス無し)は確かめるまでもない")
    }

    /// simctl の控えは、その台の置き場で指紋も同じときだけ使う
    func testInstalledBundleCacheIsPerSimulatorAndFingerprint() {
        let udid = "11111111-2222-3333-4444-555555555555"
        let path = "/Users/x/Library/Developer/CoreSimulator/Devices/\(udid)/data/Containers/Bundle/Application/U/A.app"
        let entry = AppFrameworkLedger.Entry(framework: "flutter", sourcePath: path, sourceModified: 10,
                                             sourceSize: 20, sourceBundleID: "com.example.fl")
        XCTAssertEqual(AppUIFrameworkQuery.installedBundleCacheHit(entry: entry, udid: udid,
                                                                   fingerprint: (10, 20)), .flutter)
        XCTAssertNil(AppUIFrameworkQuery.installedBundleCacheHit(entry: entry, udid: "99999999-0000-0000-0000-000000000000",
                                                                 fingerprint: (10, 20)), "別の台の控え")
        XCTAssertNil(AppUIFrameworkQuery.installedBundleCacheHit(entry: entry, udid: udid,
                                                                 fingerprint: (11, 20)), "入れ直した(指紋が違う)")
        XCTAssertNil(AppUIFrameworkQuery.installedBundleCacheHit(entry: entry, udid: udid, fingerprint: nil),
                     "置き場がもう無い")
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
