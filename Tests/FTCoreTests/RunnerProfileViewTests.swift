// ランナー機へ送るプロファイルの姿(RunnerProfileView)。用語の定義は同ファイル冒頭:
// host = ホスト名/IP、machine = そのローカルエイリアス。**エイリアスをリモートへ出さない**のが
// この型の存在理由なので、「畳んだ結果にエイリアスが1文字も残らない」ことを等号で固定する。
// 注記の有無はプロジェクト単位の判定(isMachineAnnotated)で、localize には明示で渡す。

import XCTest
@testable import FTCore

final class RunnerProfileViewTests: XCTestCase {

    private func json(_ text: String) -> [String: Any] {
        try! JSONSerialization.jsonObject(with: Data(text.utf8)) as! [String: Any]
    }

    private func text(_ object: [String: Any]) -> String {
        String(data: try! OrderedProfileJSON.data(object), encoding: .utf8)!
    }

    private func devices(_ object: [String: Any]) -> [[String: Any]] {
        object["devices"] as! [[String: Any]]
    }

    func testKeepsOnlyThatRunnersDevicesAndCallsThemLocal() {
        let profile = json("""
        {"app": "sut", "heal": true, "devices": [
            {"platform": "ios", "machine": "local", "name": "iPhone-01", "udid": "AAA"},
            {"platform": "ios", "machine": "M1Ultra", "name": "iPhone-01", "udid": "BBB", "手書き": 1},
            {"platform": "ios", "machine": "M1Max", "name": "iPhone-02", "udid": "CCC"},
            {"platform": "android", "machine": "M1Ultra", "name": "Pixel 3a", "serial": "S", "enabled": false}]}
        """)
        let view = RunnerProfileView.localizeRunProfile(profile, alias: "M1Ultra",
                                                        projectIsMachineAnnotated: true)
        let list = devices(view)
        XCTAssertEqual(list.map { $0["name"] as? String }, ["iPhone-01", "Pixel 3a"])
        XCTAssertEqual(list[0]["udid"] as? String, "BBB", "残すのは そのランナーの台")
        XCTAssertEqual(list.map { $0["machine"] as? String }, ["local", "local"], "向こうでは実際に手元")
        XCTAssertEqual(list[0]["手書き"] as? Int, 1, "未知キーは温存する")
        XCTAssertEqual(list[1]["enabled"] as? Bool, false, "無効の印も運ぶ")
        XCTAssertEqual(view["app"] as? String, "sut")
        XCTAssertEqual(view["heal"] as? Bool, true)
        XCTAssertFalse(text(view).contains("M1Ultra"), "エイリアスが1文字も残ってはいけない")
        XCTAssertFalse(text(view).contains("M1Max"))
    }

    /// 旧キー "host" のまま書かれた台も畳める(持ち込まない)
    func testReadsTheLegacyHostKey() {
        let profile = json("""
        {"devices": [{"platform": "ios", "host": "M1Ultra", "name": "旧キー"},
                     {"platform": "ios", "host": "local", "name": "手元"}]}
        """)
        let view = RunnerProfileView.localizeRunProfile(profile, alias: "M1Ultra",
                                                        projectIsMachineAnnotated: true)
        let list = devices(view)
        XCTAssertEqual(list.map { $0["name"] as? String }, ["旧キー"])
        XCTAssertEqual(list[0]["machine"] as? String, "local")
        XCTAssertNil(list[0]["host"], "旧キーは持ち込まない(エイリアスが残る)")
    }

    /// 注記の無いプロジェクト(全台が手元 = `profile setup` の素の出力)。
    /// **全台を alias の台として残す**(落とすと向こうで0台になる)
    func testUnannotatedProjectKeepsEveryDeviceAsLocal() {
        let profile = json("""
        {"devices": [{"platform": "ios", "name": "iPhone-01", "udid": "AAA"},
                     {"platform": "ios", "machine": "local", "name": "iPhone-02"},
                     {"platform": "android", "host": "local", "name": "Pixel 3a", "serial": "S"}]}
        """)
        let view = RunnerProfileView.localizeRunProfile(profile, alias: "M1Max",
                                                        projectIsMachineAnnotated: false)
        let list = devices(view)
        XCTAssertEqual(list.map { $0["name"] as? String }, ["iPhone-01", "iPhone-02", "Pixel 3a"])
        XCTAssertEqual(list.map { $0["machine"] as? String }, ["local", "local", "local"])
        XCTAssertNil(list[2]["host"])
        XCTAssertFalse(text(view).contains("M1Max"), "エイリアスが1文字も残ってはいけない")
    }

    /// 同じ全台手元のプロファイルでも**注記済みプロジェクト**なら 0 台に畳む(発行側の台)。
    /// 丸ごと送るとランナー機の台として再スタンプされ、実在する台と id が衝突する
    func testAllLocalProfileIsDroppedWhenTheProjectIsAnnotated() {
        let profile = json("""
        {"devices": [{"platform": "ios", "machine": "local", "name": "A"},
                     {"platform": "ios", "name": "B"}]}
        """)
        let view = RunnerProfileView.localizeRunProfile(profile, alias: "M1Ultra",
                                                        projectIsMachineAnnotated: true)
        XCTAssertTrue(devices(view).isEmpty)
    }

    /// 混在のプロファイル: 注記の無い台は発行側の台として落とす
    func testMixedProfileDropsLocalDevicesForEveryRunner() {
        let profile = json("""
        {"devices": [{"platform": "ios", "machine": "M1Max", "name": "A"},
                     {"platform": "ios", "name": "B"},
                     {"platform": "android", "machine": "local", "name": "C"}]}
        """)
        let toM1Max = RunnerProfileView.localizeRunProfile(profile, alias: "M1Max",
                                                           projectIsMachineAnnotated: true)
        XCTAssertEqual(devices(toM1Max).map { $0["name"] as? String }, ["A"])
        let toOther = RunnerProfileView.localizeRunProfile(profile, alias: "Other",
                                                           projectIsMachineAnnotated: true)
        XCTAssertTrue(devices(toOther).isEmpty)
    }

    func testProfileWithoutDevicesIsUnchanged() {
        let profile = json(#"{"app": "sut"}"#)
        let view = RunnerProfileView.localizeRunProfile(profile, alias: "M1Max",
                                                        projectIsMachineAnnotated: true)
        XCTAssertEqual(view as NSDictionary, profile as NSDictionary)
    }

    // MARK: - プロジェクト単位の注記判定

    /// 注記無しと、全台が明示 "local"(旧キー含む)のプロファイルだけ = 注記なし
    func testProjectWithOnlyLocalDevicesIsNotAnnotated() {
        let unannotated = json(#"{"devices": [{"platform": "ios", "name": "A"}]}"#)
        let allLocal = json("""
        {"devices": [{"platform": "ios", "machine": "local", "name": "C"},
                     {"platform": "android", "host": "local", "name": "D"},
                     {"platform": "android", "machine": "", "name": "E"}]}
        """)
        XCTAssertFalse(RunnerProfileView.isMachineAnnotated(runProfiles: []))
        XCTAssertFalse(RunnerProfileView.isMachineAnnotated(runProfiles: [unannotated, allLocal, [:]]))
    }

    /// 1枚でも別マシン名を持つ台が居れば注記済み(無効の台でも)
    func testProjectIsAnnotatedWhenAnyProfileNamesAnotherMachine() {
        let allLocal = json(#"{"devices": [{"platform": "ios", "machine": "local", "name": "A"}]}"#)
        let remote = json("""
        {"devices": [{"platform": "android", "machine": "M1Ultra", "name": "P", "enabled": false}]}
        """)
        XCTAssertTrue(RunnerProfileView.isMachineAnnotated(runProfiles: [allLocal, remote]))
    }
}
