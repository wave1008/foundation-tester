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

    /// 無いプロファイルは解決エラー(非0)。以前は plan も単一機械の解決も nil に畳まれ、
    /// machines:[] = 「ズレ無し」を exit 0 で返していた(契約は「解決エラーだけ非0」)。
    /// 実在する E2E-iOS を使う —— 実在確認より前で落ちたのでは検証にならない
    func testUnknownProfileIsAResolutionError() async throws {
        let command = try ApiRemoteCompatCommand.parse(
            ["--project", "E2E-iOS", "--profile", "no-such-profile-remote-compat"])
        do {
            try await command.run()
            XCTFail("無いプロファイルで成功した")
        } catch let error as ProfileError {
            guard case .runProfileNotFound(let name, let available) = error else {
                return XCTFail("別の解決エラー: \(error)")
            }
            XCTAssertEqual(name, "no-such-profile-remote-compat")
            XCTAssertTrue(available.contains("ios-inapp"), "実在するプロジェクトを読めていない: \(available)")
        }
    }
}
