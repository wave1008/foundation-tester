import FTCore
import XCTest
@testable import FTBridgeClient

/// iOS 実機のアプリ一覧(欠陥⑤: `ft_list_apps` が実機で simctl を叩いて落ちていた)。
/// `devicectl device info apps --json-output` の JSON → アプリ一覧の純粋変換だけを見る。
/// 実機の接続を要する `apps(udid:)` 自体(devicectl の実行)はここでは検証しない。
final class IOSPhysicalAppCatalogTests: XCTestCase {

    /// 実機で実測した JSON の形(`--include-all-apps` 有り)。3件で
    /// user/system の両方と、Apple 製でも system 側に来ないケース(Apple マップ以外)を含める
    private static func devicectlJSON(apps: [[String: Any]]) -> [String: Any] {
        ["info": ["arch": "arm64", "version": "5.0"],
         "result": ["apps": apps]]
    }

    private static let fleetestEntry: [String: Any] = [
        "bundleIdentifier": "com.ftester.e2e.ios", "name": "FT E2E iOS",
        "url": "file:///private/var/containers/Bundle/Application/AAAA/E2EAppIOS.app",
        "internalApp": false, "hidden": false, "removable": true, "builtByDeveloper": true,
        "appClip": false, "containerAccessible": true, "defaultApp": false,
        "version": "1.0.0", "bundleVersion": "1",
    ]
    private static let safariEntry: [String: Any] = [
        "bundleIdentifier": "com.apple.mobilesafari", "name": "Safari",
        "url": "file:///private/var/containers/Bundle/Application/BBBB/MobileSafari.app",
    ]
    private static let appleMapsEntry: [String: Any] = [
        "bundleIdentifier": "com.apple.Maps", "name": "Maps",
        "url": "file:///private/var/containers/Bundle/Application/CCCC/Maps.app",
    ]
    private static let googleMapsEntry: [String: Any] = [
        "bundleIdentifier": "com.google.Maps", "name": "Google Maps",
        "url": "file:///private/var/containers/Bundle/Application/DDDD/Maps.app",
    ]

    // MARK: - 分類(欠陥⑤の核心: bundleIdentifier の "com.apple." 接頭辞で決める)

    /// **`url` の `/System` 接頭辞では分類できない**(実測): Safari も Apple マップも他アプリと
    /// 同じ /private/var/containers に居るので、bundleIdentifier だけを見ること
    func testClassifiesAppleBundlesAsSystemAndOthersAsUser() throws {
        let json = Self.devicectlJSON(apps: [
            Self.fleetestEntry, Self.safariEntry, Self.appleMapsEntry, Self.googleMapsEntry,
        ])
        let apps = try XCTUnwrap(IOSPhysicalAppCatalog.parse(json: json))
        let byID = Dictionary(uniqueKeysWithValues: apps.map { ($0.id, $0) })
        XCTAssertEqual(byID["com.ftester.e2e.ios"]?.isUser, true)
        XCTAssertEqual(byID["com.google.Maps"]?.isUser, true,
                       "com.apple. 以外は user 側に来ること")
        XCTAssertEqual(byID["com.apple.mobilesafari"]?.isUser, false)
        XCTAssertEqual(byID["com.apple.Maps"]?.isUser, false)
    }

    func testIsSystemAppMatchesOnTheBundleIdentifierPrefixOnly() {
        XCTAssertTrue(IOSPhysicalAppCatalog.isSystemApp("com.apple.springboard"))
        XCTAssertFalse(IOSPhysicalAppCatalog.isSystemApp("com.google.Maps"))
        XCTAssertFalse(IOSPhysicalAppCatalog.isSystemApp("com.ftester.e2e.ios"))
        // "com.apple" を含むが接頭辞ではない id を system と誤判定しない
        XCTAssertFalse(IOSPhysicalAppCatalog.isSystemApp("com.example.not-com.apple.anything"))
    }

    // MARK: - パース

    func testParseReadsNameAndBundleIdentifier() throws {
        let apps = try XCTUnwrap(IOSPhysicalAppCatalog.parse(json: Self.devicectlJSON(apps: [Self.fleetestEntry])))
        let app = try XCTUnwrap(apps.first)
        XCTAssertEqual(app.id, "com.ftester.e2e.ios")
        XCTAssertEqual(app.name, "FT E2E iOS")
    }

    /// name が無いエントリ(実測では常に有るが、devicectl の将来のバージョン差に備える)は
    /// bundleIdentifier を表示名の代わりに使う
    func testParseFallsBackToBundleIdentifierWhenNameIsMissing() throws {
        let entry: [String: Any] = ["bundleIdentifier": "com.example.noname"]
        let apps = try XCTUnwrap(IOSPhysicalAppCatalog.parse(json: Self.devicectlJSON(apps: [entry])))
        XCTAssertEqual(apps.first?.name, "com.example.noname")
    }

    /// bundleIdentifier を欠くエントリは捨てる(壊れたエントリで一覧全体を諦めない)
    func testParseDropsEntriesWithoutBundleIdentifier() throws {
        let broken: [String: Any] = ["name": "no id"]
        let apps = try XCTUnwrap(
            IOSPhysicalAppCatalog.parse(json: Self.devicectlJSON(apps: [broken, Self.fleetestEntry])))
        XCTAssertEqual(apps.map(\.id), ["com.ftester.e2e.ios"])
    }

    /// **形が違えば nil**(devicectlFailed とは別のエラーへ呼び手が振り分ける材料)。
    /// 空配列(0件)とは区別すること —— 0件はエラーではない
    func testParseReturnsNilWhenResultShapeIsUnexpected() {
        XCTAssertNil(IOSPhysicalAppCatalog.parse(json: ["result": ["apps": "not-an-array"]]))
        XCTAssertNil(IOSPhysicalAppCatalog.parse(json: ["unexpected": "shape"]))
    }

    func testParseReturnsEmptyArrayForZeroApps() throws {
        let apps = try XCTUnwrap(IOSPhysicalAppCatalog.parse(json: Self.devicectlJSON(apps: [])))
        XCTAssertEqual(apps, [])
    }

    /// user が先、同じ区分内は表示名の小文字比較の昇順(SimulatorAppCatalog.parse と揃える)
    func testParseSortsUserAppsFirstThenAlphabetically() throws {
        let zebra: [String: Any] = ["bundleIdentifier": "com.example.zebra", "name": "Zebra"]
        let apple: [String: Any] = ["bundleIdentifier": "com.example.apple-fruit", "name": "apple"]
        let apps = try XCTUnwrap(IOSPhysicalAppCatalog.parse(
            json: Self.devicectlJSON(apps: [Self.safariEntry, zebra, apple])))
        XCTAssertEqual(apps.map(\.id),
                       ["com.example.apple-fruit", "com.example.zebra", "com.apple.mobilesafari"])
    }
}
