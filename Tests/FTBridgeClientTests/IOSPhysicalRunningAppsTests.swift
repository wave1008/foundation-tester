// 実機の起動中アプリ(devicectl の processes × apps)の突き合わせ。純粋関数なので実機無しで当てる。
// 形は実測(2026-09-24・iPhone SE3・iOS 26)の JSON をそのまま縮めたもの。

import XCTest
@testable import FTBridgeClient

final class IOSPhysicalRunningAppsTests: XCTestCase {
    private let maps = IOSPhysicalAppCatalog.App(
        id: "com.apple.Maps", name: "Maps", isUser: false,
        url: "file:///private/var/containers/Bundle/Application/44BC62D2/Maps.app/")
    private let tips = IOSPhysicalAppCatalog.App(
        id: "com.apple.tips", name: "Tips", isUser: false,
        url: "file:///private/var/containers/Bundle/Application/BC213E3A/Tips.app/")
    private let noURL = IOSPhysicalAppCatalog.App(id: "com.example.nourl", name: "x", isUser: true, url: nil)

    private func processes(_ executables: [String]) -> [String: Any] {
        ["result": ["runningProcesses": executables.enumerated().map { index, executable in
            ["processIdentifier": 100 + index, "executable": executable] as [String: Any]
        }]]
    }

    func testMatchesAppProcessesByInstallURL() {
        let ids = IOSPhysicalRunningApps.bundleIDs(apps: [maps, tips, noURL], processesJSON: processes([
            "file:///usr/libexec/backboardd",
            "file:///private/var/containers/Bundle/Application/44BC62D2/Maps.app/Maps",
            "file:///private/var/containers/Bundle/Application/BC213E3A/Tips.app/Tips",
        ]))
        XCTAssertEqual(ids, ["com.apple.Maps", "com.apple.tips"], "processes の順のまま・本体のプロセスだけ")
    }

    /// 拡張(ウィジェット等)は「アプリ」ではない —— 前面と答えることがあり、採ると本体を差し置いて
    /// セッションがそちらを向く(FrontmostApp.isExcluded の chrono と同型)
    func testIgnoresAppExtensionsUnderPlugIns() {
        let ids = IOSPhysicalRunningApps.bundleIDs(apps: [maps], processesJSON: processes([
            "file:///private/var/containers/Bundle/Application/44BC62D2/Maps.app/PlugIns/GeneralMapsWidget.appex/GeneralMapsWidget",
        ]))
        XCTAssertEqual(ids, [], "PlugIns の下の実行ファイルは採らない")
    }

    func testDedupesAndIgnoresUnknownShapes() {
        let ids = IOSPhysicalRunningApps.bundleIDs(apps: [maps], processesJSON: processes([
            "file:///private/var/containers/Bundle/Application/44BC62D2/Maps.app/Maps",
            "file:///private/var/containers/Bundle/Application/44BC62D2/Maps.app/Maps",
        ]))
        XCTAssertEqual(ids, ["com.apple.Maps"])
        XCTAssertEqual(IOSPhysicalRunningApps.bundleIDs(apps: [maps], processesJSON: ["result": "?"]), [])
        XCTAssertEqual(IOSPhysicalRunningApps.bundleIDs(apps: [maps], processesJSON: [:]), [])
    }

    func testCatalogParseCarriesTheInstallURL() {
        let apps = IOSPhysicalAppCatalog.parse(json: ["result": ["apps": [
            ["bundleIdentifier": "com.apple.Maps", "name": "Maps",
             "url": "file:///private/var/containers/Bundle/Application/44BC62D2/Maps.app/"],
            ["bundleIdentifier": "com.example.old", "name": "old"],
        ]]])
        XCTAssertEqual(apps?.map(\.url), [nil, "file:///private/var/containers/Bundle/Application/44BC62D2/Maps.app/"],
                       "user が先に並ぶ(既存の順序規則)。url は devicectl の値をそのまま運ぶ")
    }
}
