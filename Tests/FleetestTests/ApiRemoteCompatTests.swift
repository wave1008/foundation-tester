// `fleetest api remote-compat` が問い合わせるリモートホスト集合の導出(純粋関数)。
// I/O は一切行わない ApiRemoteCompat.remoteMachineLabels だけを対象にする
// (ssh を伴う本体は Tests/FleetestTests では検証しない=デバイス境界のバグは docs/verification.md 方針)。

import FTCore
import XCTest

@testable import fleetest

final class ApiRemoteCompatTests: XCTestCase {

    private func group(host: String?) -> DeviceMachineRunner.Group {
        DeviceMachineRunner.Group(machine: host, deviceNames: ["d"], platforms: ["ios"])
    }

    func testNoGroupsAndNoAutoDispatchIsEmpty() {
        XCTAssertEqual(ApiRemoteCompat.remoteMachineLabels(planGroups: nil, autoDispatchMachine: nil), [])
    }

    func testMixedGroupsKeepOnlyRemoteHosts() {
        let groups = [group(host: nil), group(host: "M1Max"), group(host: "M1Ultra")]
        XCTAssertEqual(
            ApiRemoteCompat.remoteMachineLabels(planGroups: groups, autoDispatchMachine: nil),
            ["M1Max", "M1Ultra"],
            "ローカル(host == nil)のグループは除く")
    }

    func testNilGroupsFallsBackToAutoDispatchHost() {
        XCTAssertEqual(
            ApiRemoteCompat.remoteMachineLabels(planGroups: nil, autoDispatchMachine: "M1Max"),
            ["M1Max"],
            "単一機械の自動ディスパッチはその host を1件だけ返す")
    }

    func testDuplicateHostsAreDeduplicatedInOrder() {
        let groups = [group(host: "M1Max"), group(host: "M1Ultra"), group(host: "M1Max")]
        XCTAssertEqual(
            ApiRemoteCompat.remoteMachineLabels(planGroups: groups, autoDispatchMachine: nil),
            ["M1Max", "M1Ultra"],
            "重複除去は出現順を保つ")
    }
}
