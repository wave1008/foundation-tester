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
