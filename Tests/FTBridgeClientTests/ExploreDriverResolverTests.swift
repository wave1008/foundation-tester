// profile を渡さない探索(MCP の ft_*)が**稼働中の in-app ブリッジを主にする**ことを固定する
// (2026-08-05。それ以前は XCUITest へ振り替えていた)。
//
// ここが静かに振り替えへ戻ると、**探索と実行(既定 hybrid)でジェスチャの成否が変わる** ——
// Compose のダブルタップと Flutter のピンチは XCUITest では届かないので、MCP で無反応
// だったものがシナリオでは通る(およびその逆)になる。
//
// 決定だけを純粋関数に切ってあるので、デバイス無しで全分岐を試せる(IO 部分の resolve は
// ブリッジ走査を伴うため対象外)。

import XCTest
@testable import FTBridgeClient

final class ExploreDriverResolverTests: XCTestCase {

    private typealias Plan = ExploreDriverResolver.Plan

    private func plan(engine: String?, bundleID: String? = "com.example.app",
                      udid: String? = "UDID-1", xcuiPort: UInt16? = 8124) -> Plan {
        ExploreDriverResolver.plan(preferred: 8123, engine: engine, sessionBundleID: bundleID,
                                   udid: udid, xcuiPort: xcuiPort)
    }

    /// in-app が居れば**実行の既定と同じ hybrid**を組む(in-app 主 + XCUITest フォールバック)
    func testInAppBridgeBecomesTheHybridPrimary() {
        XCTAssertEqual(plan(engine: "inapp"),
                       .hybrid(inappPort: 8123, xcuiPort: 8124, bundleID: "com.example.app"))
    }

    /// XCUITest ブリッジや無応答はそのまま(振る舞いを変えない)
    func testNonInAppPortsAreUsedAsIs() {
        XCTAssertEqual(plan(engine: "xcuitest"), .direct(port: 8123))
        XCTAssertEqual(plan(engine: nil), .direct(port: 8123), "無応答のポートを勝手に読み替えない")
    }

    /// **フォールバック先が用意できなければ in-app 単独**(タップ・入力・ジェスチャは通る。
    /// home/appSwitcher/drag/座標 press だけが 501 になる)
    func testWithoutAnXCUITestBridgeItStillUsesTheInAppOne() {
        XCTAssertEqual(plan(engine: "inapp", xcuiPort: nil), .inappOnly(port: 8123))
    }

    /// **注入できない相手には in-app を作らない**(実機・同名デバイス複数で udid が引けない)。
    /// この場合は従来どおり XCUITest へ振り替える = 機能が減る方向に倒さない
    func testFallsBackToTheXCUITestBridgeWhenTheSimulatorIsNotIdentifiable() {
        XCTAssertEqual(plan(engine: "inapp", udid: nil), .rerouteToXCUI(port: 8124))
        XCTAssertEqual(plan(engine: "inapp", udid: nil, xcuiPort: nil), .direct(port: 8123),
                       "振り替え先も無ければ指定ポートのまま(従来と同じ)")
    }

    /// 対象アプリが分からなければ attach できない(AppAttachDriver は bundleID 必須)ので
    /// 振り替える。in-app ブリッジは対象アプリの中に住むため、通常は必ず名乗る
    func testFallsBackWhenTheBridgeDoesNotReportItsApp() {
        XCTAssertEqual(plan(engine: "inapp", bundleID: nil), .rerouteToXCUI(port: 8124))
    }
}
