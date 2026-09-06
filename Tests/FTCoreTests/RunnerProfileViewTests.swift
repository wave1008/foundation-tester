// ランナー機へ送るプロファイルの姿(RunnerProfileView)。用語の定義は同ファイル冒頭:
// host = ホスト名/IP、machine = そのローカルエイリアス。**エイリアスをリモートへ出さない**のが
// この型の存在理由なので、「畳んだ結果にエイリアスが1文字も残らない」ことを等号で固定する。

import XCTest
@testable import FTCore

final class RunnerProfileViewTests: XCTestCase {

    private func json(_ text: String) -> [String: Any] {
        try! JSONSerialization.jsonObject(with: Data(text.utf8)) as! [String: Any]
    }

    private func text(_ object: [String: Any]) -> String {
        String(data: try! OrderedProfileJSON.data(object), encoding: .utf8)!
    }

    func testMachineProfileKeepsOnlyThatRunnersDevicesAndCallsThemLocal() {
        let profile = json("""
        {"ios": {"devices": [
            {"machine": "local", "name": "iPhone-01", "udid": "AAA"},
            {"machine": "M1Ultra", "name": "iPhone-01", "udid": "BBB", "手書き": 1},
            {"machine": "M1Max", "name": "iPhone-02", "udid": "CCC"}]},
         "android": {"devices": [{"machine": "M1Ultra", "name": "Pixel 3a", "serial": "S"}]}}
        """)
        let view = RunnerProfileView.localizeMachineProfile(profile, alias: "M1Ultra")

        let ios = (view["ios"] as! [String: Any])["devices"] as! [[String: Any]]
        XCTAssertEqual(ios.count, 1)
        XCTAssertEqual(ios[0]["name"] as? String, "iPhone-01")
        XCTAssertEqual(ios[0]["udid"] as? String, "BBB", "残すのは そのランナーの台")
        XCTAssertEqual(ios[0]["machine"] as? String, "local", "向こうでは実際に手元")
        XCTAssertEqual(ios[0]["手書き"] as? Int, 1, "未知キーは温存する")
        let android = (view["android"] as! [String: Any])["devices"] as! [[String: Any]]
        XCTAssertEqual(android.map { $0["name"] as? String }, ["Pixel 3a"])
        XCTAssertFalse(text(view).contains("M1Ultra"), "エイリアスが1文字も残ってはいけない")
        XCTAssertFalse(text(view).contains("M1Max"))
    }

    /// 直下の既定に居る台(デバイス側に machine を書いていない)も対象。畳んだ後に既定は消す
    func testMachineProfileFoldsTheProfileDefault() {
        let profile = json("""
        {"machine": "M1Max",
         "ios": {"devices": [{"name": "継承する台"}, {"machine": "local", "name": "手元の台"}]}}
        """)
        let view = RunnerProfileView.localizeMachineProfile(profile, alias: "M1Max")
        XCTAssertNil(view["machine"], "全台が local になった後の既定は意味を持たない")
        let ios = (view["ios"] as! [String: Any])["devices"] as! [[String: Any]]
        XCTAssertEqual(ios.map { $0["name"] as? String }, ["継承する台"])
        XCTAssertEqual(ios[0]["machine"] as? String, "local")
    }

    /// 旧キー "host" のままのプロファイル(改名前に書かれたもの)も畳める
    func testMachineProfileReadsTheLegacyHostKey() {
        let profile = json("""
        {"ios": {"devices": [{"host": "M1Ultra", "name": "旧キー"}, {"host": "local", "name": "手元"}]}}
        """)
        let view = RunnerProfileView.localizeMachineProfile(profile, alias: "M1Ultra")
        let ios = (view["ios"] as! [String: Any])["devices"] as! [[String: Any]]
        XCTAssertEqual(ios.map { $0["name"] as? String }, ["旧キー"])
        XCTAssertEqual(ios[0]["machine"] as? String, "local")
        XCTAssertNil(ios[0]["host"], "旧キーは持ち込まない(エイリアスが残る)")
    }

    /// `profile setup` の素の出力(どの台にも machine が無い)= RemoteDispatchDeviceScope の
    /// `.wholeProfile`。**全台を alias の台として残す**(落とすと向こうで「none of the devices
    /// referenced by run profile … exist in machine profile」になる)
    func testUnannotatedMachineProfileKeepsEveryDeviceAsLocal() {
        let profile = json("""
        {"ios": {"devices": [{"name": "iPhone-01", "udid": "AAA"}, {"name": "iPhone-02", "udid": "BBB"}]},
         "android": {"devices": [{"name": "Pixel 3a", "serial": "S"}]}}
        """)
        let view = RunnerProfileView.localizeMachineProfile(profile, alias: "M1Max")
        let ios = (view["ios"] as! [String: Any])["devices"] as! [[String: Any]]
        XCTAssertEqual(ios.map { $0["name"] as? String }, ["iPhone-01", "iPhone-02"])
        XCTAssertEqual(ios.map { $0["machine"] as? String }, ["local", "local"], "向こうでは実際に手元")
        let android = (view["android"] as! [String: Any])["devices"] as! [[String: Any]]
        XCTAssertEqual(android.map { $0["name"] as? String }, ["Pixel 3a"])
        XCTAssertEqual(android[0]["machine"] as? String, "local")
        XCTAssertNil(view["machine"])
        XCTAssertFalse(text(view).contains("M1Max"), "エイリアスが1文字も残ってはいけない")
    }

    /// 全台が明示の "local" / 旧キー "host": "local" でも同じ(normalize では local = 未指定)
    func testAllLocalMachineProfileIsWholeProfileToo() {
        let profile = json("""
        {"ios": {"devices": [{"machine": "local", "name": "A"}, {"host": "local", "name": "B"}]}}
        """)
        let view = RunnerProfileView.localizeMachineProfile(profile, alias: "M1Max")
        let ios = (view["ios"] as! [String: Any])["devices"] as! [[String: Any]]
        XCTAssertEqual(ios.map { $0["name"] as? String }, ["A", "B"])
        XCTAssertEqual(ios.map { $0["machine"] as? String }, ["local", "local"])
        XCTAssertNil(ios[1]["host"], "旧キーは持ち込まない")
    }

    /// 1台でも注記があれば混在プロファイル。**注記の無い台は「どこの台か不明」で落とす**
    /// (従来の挙動。プラットフォームを跨いで判定する = android 側の注記だけでも混在になる)
    func testMixedMachineProfileDropsUnannotatedDevices() {
        let profile = json("""
        {"ios": {"devices": [{"machine": "M1Max", "name": "注記あり"}, {"name": "注記なし"}]},
         "android": {"devices": [{"name": "Pixel 3a"}]}}
        """)
        let toM1Max = RunnerProfileView.localizeMachineProfile(profile, alias: "M1Max")
        let ios = (toM1Max["ios"] as! [String: Any])["devices"] as! [[String: Any]]
        XCTAssertEqual(ios.map { $0["name"] as? String }, ["注記あり"])
        XCTAssertEqual(ios[0]["machine"] as? String, "local")
        let android = (toM1Max["android"] as! [String: Any])["devices"] as! [[String: Any]]
        XCTAssertTrue(android.isEmpty, "混在プロファイルでは注記の無い台を残さない(android 側も)")

        let toOther = RunnerProfileView.localizeMachineProfile(profile, alias: "Other")
        XCTAssertTrue(((toOther["ios"] as! [String: Any])["devices"] as! [[String: Any]]).isEmpty)
        XCTAssertTrue(((toOther["android"] as! [String: Any])["devices"] as! [[String: Any]]).isEmpty)
    }

    /// 実行プロファイルも同じ定義: 全参照が machine 未指定("local" 含む)なら全部残す
    func testUnannotatedRunProfileKeepsEveryRef() {
        let profile = json("""
        {"machine": "mine", "app": "sut",
         "devices": [{"name": "A"}, {"machine": "local", "name": "B"}, {"host": "local", "name": "C"}]}
        """)
        let view = RunnerProfileView.localizeRunProfile(profile, alias: "M1Max")
        let devices = view["devices"] as! [[String: Any]]
        XCTAssertEqual(devices.map { $0["name"] as? String }, ["A", "B", "C"])
        XCTAssertNil(devices[0]["machine"], "名前だけの参照はそのまま")
        XCTAssertEqual(devices[1]["machine"] as? String, "local")
        XCTAssertEqual(devices[2]["machine"] as? String, "local")
        XCTAssertNil(devices[2]["host"])
        XCTAssertFalse(text(view).contains("M1Max"))
    }

    /// 混在の実行プロファイルは従来どおり: alias の参照だけ "local" に、他機と発行側の "local" は落とす。
    /// 名前だけの参照は(混在でも)残す = testRunProfileKeepsOnlyThatRunnersRefs と同じ規律
    func testMixedRunProfileKeepsOnlyThatRunnersRefs() {
        let profile = json("""
        {"machine": "mine", "app": "sut",
         "devices": [{"machine": "M1Max", "name": "A"}, {"machine": "local", "name": "B"}, {"name": "C"}]}
        """)
        let toM1Max = (RunnerProfileView.localizeRunProfile(profile, alias: "M1Max")["devices"] as! [[String: Any]])
        XCTAssertEqual(toM1Max.map { $0["name"] as? String }, ["A", "C"])
        XCTAssertEqual(toM1Max[0]["machine"] as? String, "local")
        let toOther = (RunnerProfileView.localizeRunProfile(profile, alias: "Other")["devices"] as! [[String: Any]])
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
        let view = RunnerProfileView.localizeRunProfile(profile, alias: "M1Ultra")
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
