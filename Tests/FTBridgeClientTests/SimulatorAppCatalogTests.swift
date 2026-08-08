// SimulatorAppCatalog.parse は `xcrun simctl listapps <udid>` の OpenStep 形式 plist を食べる。
// ここでは実出力を模した文字列を直接当てて、移設元(旧 ApiListAppsCommand.iosApps)の
// 既存仕様を機械的に固定する: .xctrunner 除外・表示名フォールバック・user/system 判定・並び順。

import XCTest
@testable import FTBridgeClient

final class SimulatorAppCatalogTests: XCTestCase {

    private let sample = """
    {
        "com.example.zeta" =     {
            ApplicationType = User;
            CFBundleDisplayName = "Zeta App";
            CFBundleName = Zeta;
        };
        "com.example.alpha" =     {
            ApplicationType = User;
            CFBundleName = "Alpha App";
        };
        "com.example.alpha.xctrunner" =     {
            ApplicationType = User;
            CFBundleName = "AlphaUITests-Runner";
        };
        "com.apple.system.settings" =     {
            ApplicationType = System;
            CFBundleDisplayName = "Settings";
        };
        "com.example.noname" =     {
            ApplicationType = User;
        };
    }
    """

    func testExcludesXCTestRunnerBundle() throws {
        let apps = try SimulatorAppCatalog.parse(listAppsOutput: sample)
        XCTAssertFalse(apps.contains { $0.id == "com.example.alpha.xctrunner" },
                       "XCUITest ランナー自身は一覧から除外すること")
    }

    func testDisplayNameFallsBackToBundleNameThenID() throws {
        let apps = try SimulatorAppCatalog.parse(listAppsOutput: sample)
        let byID = Dictionary(uniqueKeysWithValues: apps.map { ($0.id, $0) })
        XCTAssertEqual(byID["com.example.zeta"]?.name, "Zeta App", "CFBundleDisplayName を優先する")
        XCTAssertEqual(byID["com.example.alpha"]?.name, "Alpha App", "無ければ CFBundleName")
        XCTAssertEqual(byID["com.example.noname"]?.name, "com.example.noname", "どちらも無ければ id")
    }

    func testApplicationTypeDeterminesUserVsSystem() throws {
        let apps = try SimulatorAppCatalog.parse(listAppsOutput: sample)
        let byID = Dictionary(uniqueKeysWithValues: apps.map { ($0.id, $0) })
        XCTAssertEqual(byID["com.example.zeta"]?.isUser, true)
        XCTAssertEqual(byID["com.apple.system.settings"]?.isUser, false)
    }

    /// user が先、同じ type 内は表示名の小文字比較の昇順
    func testOrderingIsUserFirstThenCaseInsensitiveName() throws {
        let apps = try SimulatorAppCatalog.parse(listAppsOutput: sample)
        XCTAssertEqual(apps.map(\.id),
                       ["com.example.alpha", "com.example.noname", "com.example.zeta",
                        "com.apple.system.settings"])
    }

    func testUnparsableInputThrows() {
        XCTAssertThrowsError(try SimulatorAppCatalog.parse(listAppsOutput: "not a plist")) { error in
            guard case .unparsableOutput = error as? SimulatorAppCatalog.SimulatorAppCatalogError else {
                return XCTFail("expected .unparsableOutput, got \(error)")
            }
        }
    }

    /// トップレベルが配列など辞書以外だと unexpectedFormat
    func testTopLevelNonDictionaryThrowsUnexpectedFormat() {
        XCTAssertThrowsError(try SimulatorAppCatalog.parse(listAppsOutput: "( 1, 2, 3 )")) { error in
            XCTAssertEqual(error as? SimulatorAppCatalog.SimulatorAppCatalogError, .unexpectedFormat)
        }
    }
}
