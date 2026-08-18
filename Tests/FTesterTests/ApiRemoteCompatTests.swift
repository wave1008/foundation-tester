// `ftester api remote-compat` が問い合わせるリモートホスト集合の導出(純粋関数)。
// I/O は一切行わない ApiRemoteCompat.remoteHostLabels だけを対象にする
// (ssh を伴う本体は Tests/FTesterTests では検証しない=デバイス境界のバグは docs/verification.md 方針)。

import FTCore
import XCTest

@testable import ftester

final class ApiRemoteCompatTests: XCTestCase {

    private func group(host: String?) -> DeviceHostRunner.Group {
        DeviceHostRunner.Group(host: host, deviceNames: ["d"], platforms: ["ios"])
    }

    func testNoGroupsAndNoAutoDispatchIsEmpty() {
        XCTAssertEqual(ApiRemoteCompat.remoteHostLabels(planGroups: nil, autoDispatchHost: nil), [])
    }

    func testMixedGroupsKeepOnlyRemoteHosts() {
        let groups = [group(host: nil), group(host: "M1Max"), group(host: "M1Ultra")]
        XCTAssertEqual(
            ApiRemoteCompat.remoteHostLabels(planGroups: groups, autoDispatchHost: nil),
            ["M1Max", "M1Ultra"],
            "ローカル(host == nil)のグループは除く")
    }

    func testNilGroupsFallsBackToAutoDispatchHost() {
        XCTAssertEqual(
            ApiRemoteCompat.remoteHostLabels(planGroups: nil, autoDispatchHost: "M1Max"),
            ["M1Max"],
            "単一機械の自動ディスパッチはその host を1件だけ返す")
    }

    func testDuplicateHostsAreDeduplicatedInOrder() {
        let groups = [group(host: "M1Max"), group(host: "M1Ultra"), group(host: "M1Max")]
        XCTAssertEqual(
            ApiRemoteCompat.remoteHostLabels(planGroups: groups, autoDispatchHost: nil),
            ["M1Max", "M1Ultra"],
            "重複除去は出現順を保つ")
    }
}
