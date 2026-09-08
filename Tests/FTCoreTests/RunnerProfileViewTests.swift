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

    private func devices(_ object: [String: Any], _ platform: String) -> [[String: Any]] {
        (object[platform] as! [String: Any])["devices"] as! [[String: Any]]
    }

    func testMachineProfileKeepsOnlyThatRunnersDevicesAndCallsThemLocal() {
        let profile = json("""
        {"ios": {"devices": [
            {"machine": "local", "name": "iPhone-01", "udid": "AAA"},
            {"machine": "M1Ultra", "name": "iPhone-01", "udid": "BBB", "手書き": 1},
            {"machine": "M1Max", "name": "iPhone-02", "udid": "CCC"}]},
         "android": {"devices": [{"machine": "M1Ultra", "name": "Pixel 3a", "serial": "S"}]}}
        """)
        let view = RunnerProfileView.localizeMachineProfile(profile, alias: "M1Ultra",
                                                            projectIsMachineAnnotated: true)

        let ios = devices(view, "ios")
        XCTAssertEqual(ios.count, 1)
        XCTAssertEqual(ios[0]["name"] as? String, "iPhone-01")
        XCTAssertEqual(ios[0]["udid"] as? String, "BBB", "残すのは そのランナーの台")
        XCTAssertEqual(ios[0]["machine"] as? String, "local", "向こうでは実際に手元")
        XCTAssertEqual(ios[0]["手書き"] as? Int, 1, "未知キーは温存する")
        XCTAssertEqual(devices(view, "android").map { $0["name"] as? String }, ["Pixel 3a"])
        XCTAssertFalse(text(view).contains("M1Ultra"), "エイリアスが1文字も残ってはいけない")
        XCTAssertFalse(text(view).contains("M1Max"))
    }

    /// 直下の既定に居る台(デバイス側に machine を書いていない)も対象。畳んだ後に既定は消す
    func testMachineProfileFoldsTheProfileDefault() {
        let profile = json("""
        {"machine": "M1Max",
         "ios": {"devices": [{"name": "継承する台"}, {"machine": "local", "name": "手元の台"}]}}
        """)
        let view = RunnerProfileView.localizeMachineProfile(profile, alias: "M1Max",
                                                            projectIsMachineAnnotated: true)
        XCTAssertNil(view["machine"], "全台が local になった後の既定は意味を持たない")
        let ios = devices(view, "ios")
        XCTAssertEqual(ios.map { $0["name"] as? String }, ["継承する台"])
        XCTAssertEqual(ios[0]["machine"] as? String, "local")
    }

    /// 旧キー "host" のままのプロファイル(改名前に書かれたもの)も畳める
    func testMachineProfileReadsTheLegacyHostKey() {
        let profile = json("""
        {"ios": {"devices": [{"host": "M1Ultra", "name": "旧キー"}, {"host": "local", "name": "手元"}]}}
        """)
        let view = RunnerProfileView.localizeMachineProfile(profile, alias: "M1Ultra",
                                                            projectIsMachineAnnotated: true)
        let ios = devices(view, "ios")
        XCTAssertEqual(ios.map { $0["name"] as? String }, ["旧キー"])
        XCTAssertEqual(ios[0]["machine"] as? String, "local")
        XCTAssertNil(ios[0]["host"], "旧キーは持ち込まない(エイリアスが残る)")
    }

    /// `profile setup` の素の出力(どの台にも machine が無い)= 注記の無いプロジェクト。
    /// **全台を alias の台として残す**(落とすと向こうで「none of the devices referenced by
    /// run profile … exist in machine profile」になる)
    func testUnannotatedMachineProfileKeepsEveryDeviceAsLocal() {
        let profile = json("""
        {"ios": {"devices": [{"name": "iPhone-01", "udid": "AAA"}, {"name": "iPhone-02", "udid": "BBB"}]},
         "android": {"devices": [{"name": "Pixel 3a", "serial": "S"}]}}
        """)
        let view = RunnerProfileView.localizeMachineProfile(profile, alias: "M1Max",
                                                            projectIsMachineAnnotated: false)
        let ios = devices(view, "ios")
        XCTAssertEqual(ios.map { $0["name"] as? String }, ["iPhone-01", "iPhone-02"])
        XCTAssertEqual(ios.map { $0["machine"] as? String }, ["local", "local"], "向こうでは実際に手元")
        XCTAssertEqual(devices(view, "android").map { $0["name"] as? String }, ["Pixel 3a"])
        XCTAssertEqual(devices(view, "android")[0]["machine"] as? String, "local")
        XCTAssertNil(view["machine"])
        XCTAssertFalse(text(view).contains("M1Max"), "エイリアスが1文字も残ってはいけない")
    }

    /// 全台が明示の "local" / 旧キー "host": "local"(= `profile setup` が書く形)。
    /// 注記の無いプロジェクトでは丸ごと残す —— ここで落とすと台帳1枚だけの受け手が 0 台になる
    func testAllLocalMachineProfileIsKeptWhenTheProjectHasNoAnnotation() {
        let profile = json("""
        {"ios": {"devices": [{"machine": "local", "name": "A"}, {"host": "local", "name": "B"}]}}
        """)
        let view = RunnerProfileView.localizeMachineProfile(profile, alias: "M1Max",
                                                            projectIsMachineAnnotated: false)
        let ios = devices(view, "ios")
        XCTAssertEqual(ios.map { $0["name"] as? String }, ["A", "B"])
        XCTAssertEqual(ios.map { $0["machine"] as? String }, ["local", "local"])
        XCTAssertNil(ios[1]["host"], "旧キーは持ち込まない")
    }

    /// 同じ台帳でも**注記済みプロジェクト**なら 0 台に畳む(明示 "local" = 発行側の台)。
    /// 丸ごと送るとランナー機の台として再スタンプされ、実在する台と id が衝突する
    func testAllLocalMachineProfileIsDroppedWhenTheProjectIsAnnotated() {
        let profile = json("""
        {"ios": {"devices": [{"machine": "local", "name": "A"}, {"host": "local", "name": "B"}]},
         "android": {"devices": [{"machine": "local", "name": "Pixel 3a"}]}}
        """)
        let view = RunnerProfileView.localizeMachineProfile(profile, alias: "M1Ultra",
                                                            projectIsMachineAnnotated: true)
        XCTAssertTrue(devices(view, "ios").isEmpty, "明示 local は発行側の台(旧キー host も同じ)")
        XCTAssertTrue(devices(view, "android").isEmpty)
    }

    /// 1台でも注記があれば混在プロファイル。**注記の無い台は「どこの台か不明」で落とす**
    /// (プラットフォームを跨いで判定する = android 側の注記だけでも混在になる)
    func testMixedMachineProfileDropsUnannotatedDevices() {
        let profile = json("""
        {"ios": {"devices": [{"machine": "M1Max", "name": "注記あり"}, {"name": "注記なし"}]},
         "android": {"devices": [{"name": "Pixel 3a"}]}}
        """)
        let toM1Max = RunnerProfileView.localizeMachineProfile(profile, alias: "M1Max",
                                                               projectIsMachineAnnotated: true)
        let ios = devices(toM1Max, "ios")
        XCTAssertEqual(ios.map { $0["name"] as? String }, ["注記あり"])
        XCTAssertEqual(ios[0]["machine"] as? String, "local")
        XCTAssertTrue(devices(toM1Max, "android").isEmpty,
                      "混在プロファイルでは注記の無い台を残さない(android 側も)")

        let toOther = RunnerProfileView.localizeMachineProfile(profile, alias: "Other",
                                                               projectIsMachineAnnotated: true)
        XCTAssertTrue(devices(toOther, "ios").isEmpty)
        XCTAssertTrue(devices(toOther, "android").isEmpty)
    }

    // MARK: - プロジェクト単位の注記判定

    /// 注記無しの台帳と、全台が明示 "local"(旧キー含む)の台帳だけ = 注記なし
    func testProjectWithOnlyLocalOrUnannotatedLedgersIsNotAnnotated() {
        let unannotated = json("""
        {"ios": {"devices": [{"name": "A"}, {"name": "B"}]}}
        """)
        let allLocal = json("""
        {"machine": "local",
         "ios": {"devices": [{"machine": "local", "name": "C"}, {"host": "local", "name": "D"}]},
         "android": {"devices": [{"name": "E"}]}}
        """)
        XCTAssertFalse(RunnerProfileView.isMachineAnnotated(machineProfiles: []))
        XCTAssertFalse(RunnerProfileView.isMachineAnnotated(machineProfiles: [unannotated, allLocal]))
    }

    /// 1枚でも別マシン名を持つ台が居れば注記済み(android 側だけでも)
    func testProjectIsAnnotatedWhenAnyLedgerNamesAnotherMachine() {
        let allLocal = json("""
        {"ios": {"devices": [{"machine": "local", "name": "A"}]}}
        """)
        let mixed = json("""
        {"ios": {"devices": [{"name": "B"}]},
         "android": {"devices": [{"machine": "M1Ultra", "name": "Pixel 3a"}]}}
        """)
        XCTAssertTrue(RunnerProfileView.isMachineAnnotated(machineProfiles: [allLocal, mixed]))
    }

    /// プロファイル直下の既定 machine("host" も)だけで注記されている台帳も注記済み
    func testProjectIsAnnotatedByTheProfileDefaultAlone() {
        let byMachineKey = json("""
        {"machine": "M1Max", "ios": {"devices": [{"name": "継承する台"}]}}
        """)
        let byLegacyHostKey = json("""
        {"host": "M1Max", "ios": {"devices": [{"name": "継承する台"}]}}
        """)
        XCTAssertTrue(RunnerProfileView.isMachineAnnotated(machineProfiles: [byMachineKey]))
        XCTAssertTrue(RunnerProfileView.isMachineAnnotated(machineProfiles: [byLegacyHostKey]))
    }

    // MARK: - 実行プロファイル

    /// 注記の無いプロジェクトなら、全参照が machine 未指定("local" 含む)で全部残る
    func testUnannotatedRunProfileKeepsEveryRef() {
        let profile = json("""
        {"machine": "mine", "app": "sut",
         "devices": [{"name": "A"}, {"machine": "local", "name": "B"}, {"host": "local", "name": "C"}]}
        """)
        let view = RunnerProfileView.localizeRunProfile(profile, alias: "M1Max",
                                                        projectIsMachineAnnotated: false)
        let devices = view["devices"] as! [[String: Any]]
        XCTAssertEqual(devices.map { $0["name"] as? String }, ["A", "B", "C"])
        XCTAssertNil(devices[0]["machine"], "名前だけの参照はそのまま")
        XCTAssertEqual(devices[1]["machine"] as? String, "local")
        XCTAssertEqual(devices[2]["machine"] as? String, "local")
        XCTAssertNil(devices[2]["host"])
        XCTAssertFalse(text(view).contains("M1Max"))
    }

    /// 注記済みプロジェクトでは同じ参照でも "local" は落ちる —— マシンプロファイル側が
    /// 0 台に畳まれるので、残すと向こうで解決できない参照になる。名前だけの参照は残す
    func testAnnotatedProjectDropsLocalRefsFromTheRunProfile() {
        let profile = json("""
        {"machine": "mine", "app": "sut",
         "devices": [{"name": "A"}, {"machine": "local", "name": "B"}, {"host": "local", "name": "C"}]}
        """)
        let view = RunnerProfileView.localizeRunProfile(profile, alias: "M1Max",
                                                        projectIsMachineAnnotated: true)
        let devices = view["devices"] as! [[String: Any]]
        XCTAssertEqual(devices.map { $0["name"] as? String }, ["A"])
        XCTAssertNil(devices[0]["machine"])
    }

    /// 混在の実行プロファイル: alias の参照だけ "local" に、他機と発行側の "local" は落とす。
    /// 名前だけの参照は(混在でも)残す = testRunProfileKeepsOnlyThatRunnersRefs と同じ規律
    func testMixedRunProfileKeepsOnlyThatRunnersRefs() {
        let profile = json("""
        {"machine": "mine", "app": "sut",
         "devices": [{"machine": "M1Max", "name": "A"}, {"machine": "local", "name": "B"}, {"name": "C"}]}
        """)
        let m1max = RunnerProfileView.localizeRunProfile(profile, alias: "M1Max",
                                                         projectIsMachineAnnotated: true)
        let toM1Max = m1max["devices"] as! [[String: Any]]
        XCTAssertEqual(toM1Max.map { $0["name"] as? String }, ["A", "C"])
        XCTAssertEqual(toM1Max[0]["machine"] as? String, "local")
        let other = RunnerProfileView.localizeRunProfile(profile, alias: "Other",
                                                         projectIsMachineAnnotated: true)
        let toOther = other["devices"] as! [[String: Any]]
        XCTAssertEqual(toOther.map { $0["name"] as? String }, ["C"], "注記のある参照は1つも残らない")
    }

    func testRunProfileKeepsOnlyThatRunnersRefs() {
        let profile = json("""
        {"machine": "local+remote", "app": "sut",
         "devices": [{"machine": "local", "name": "A"},
                     {"machine": "M1Ultra", "name": "B"},
                     {"host": "M1Max", "name": "C"},
                     {"name": "名前だけ"}]}
        """)
        let view = RunnerProfileView.localizeRunProfile(profile, alias: "M1Ultra",
                                                        projectIsMachineAnnotated: true)
        let devices = view["devices"] as! [[String: Any]]
        XCTAssertEqual(devices.map { $0["name"] as? String }, ["B", "名前だけ"])
        XCTAssertEqual(devices[0]["machine"] as? String, "local")
        XCTAssertNil(devices[1]["machine"], "名前だけの参照はそのまま(畳んだ後の1台に解決する)")
        XCTAssertEqual(view["machine"] as? String, "local+remote",
                       "実行プロファイルの machine は**マシンプロファイル名**で、機械の別名ではない")
        XCTAssertFalse(text(view).contains("M1Ultra"))
        XCTAssertFalse(text(view).contains("M1Max"))
    }
}
