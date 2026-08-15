// 2026-08-15 の外部評価(まっさらなエージェントが iOS の設定アプリと Safari を操作した記録)
// 由来の修正。**どれも「判定は正しいのに次の手が出せない」形**なので、直したのは文言と経路。
//
//   ① `Shop` が8スワイプ空振り → 「`*Shop*` と書け」と勧められたが、勧めどおりに撃っても同じ結果
//      → ヒントの供給元が**最終木だけ**で、部分一致の相手が探索で画面外へ流れた回は
//        黙るか、出ても「もう後ろにある」ことを言っていなかった(scrollNotationHint)
//   ② ホーム画面のアイコンをタップして「安定セレクタが無い」で終わる
//      → その画面では永久に書けないので、欲しいのは別のセレクタではなく ft_launch(homeScreenLaunchHint)
//
// 打ち切り文言(`stopped early`)側の修正は FTCoreTests/ScrollSearchStopTests にある。

import XCTest
@testable import ftester_mcp
import FTCore

final class MCPEvaluationFixes20260815Tests: XCTestCase {

    private func text(_ ref: Int, _ label: String, y: Double) -> ElementInfo {
        ElementInfo(ref: ref, type: "link", identifier: nil, label: label, value: nil,
                    placeholder: nil, enabled: true,
                    frame: FTRect(x: 10, y: y, width: 200, height: 20), depth: 3)
    }

    private func snapshot(_ elements: [ElementInfo], session: String? = nil) -> SnapshotResponse {
        SnapshotResponse(sessionBundleID: session,
                         screen: FTRect(x: 0, y: 0, width: 402, height: 874),
                         elements: elements, truncatedCount: 0)
    }

    // MARK: - ① 記法ヒントは探索で流れても消えない

    /// 最終木に部分一致の相手が残っているなら、従来どおりそれだけを言う
    /// (「開始画面にあった」は嘘になるので付けない)
    func testTakesTheHintFromTheFinalTreeWhenItIsStillThere() {
        let after = snapshot([text(1, "Shop, Education Store", y: 400)])

        let hint = MCPServer.scrollNotationHint("Shop", after: after,
                                                beforeScroll: snapshot([]), backDirection: "up")

        XCTAssertTrue(hint.contains("*Shop*"), hint)
        XCTAssertFalse(hint.contains("STARTED"),
                       "最終木で出せたのに「開始画面にあった」と言っている: \(hint)")
    }

    /// **探索で流れた回でも黙らない**。旧実装は最終木しか見ないので、
    /// スクロールで相手が画面外へ出ると「`*Shop*` と書け」ごと消えていた
    func testFallsBackToTheScreenTheSearchStartedOn() {
        let before = snapshot([text(1, "Shop, Education Store", y: 400)])
        let after = snapshot([text(2, "Privacy Policy", y: 400)])

        let hint = MCPServer.scrollNotationHint("Shop", after: after,
                                                beforeScroll: before, backDirection: "up")

        XCTAssertTrue(hint.contains("*Shop*"), hint)
        XCTAssertTrue(hint.contains("STARTED"), "開始画面の話だと断っていない: \(hint)")
        XCTAssertTrue(hint.contains("direction: up"),
                      "同じ向きで撃ち直しても届かないことを言っていない: \(hint)")
    }

    /// どちらの木にも無いなら何も言わない(推測の助言を足さない)
    func testStaysSilentWhenNeitherTreeHasAPartialMatch() {
        XCTAssertEqual(MCPServer.scrollNotationHint("Shop",
                                                    after: snapshot([text(1, "Privacy", y: 400)]),
                                                    beforeScroll: snapshot([text(2, "Legal", y: 10)]),
                                                    backDirection: "up"), "")
    }

    /// 戻る向きは探索方向の逆(4方向とも)
    func testReversedDirectionCoversEveryDirection() {
        XCTAssertEqual(MCPServer.reversedDirection(.down), "up")
        XCTAssertEqual(MCPServer.reversedDirection(.up), "down")
        XCTAssertEqual(MCPServer.reversedDirection(.right), "left")
        XCTAssertEqual(MCPServer.reversedDirection(.left), "right")
    }

    // MARK: - ② ホーム画面では ft_launch を名指しする

    func testHomeScreenHintFiresOnTheAndroidLauncher() {
        let hint = MCPServer.homeScreenLaunchHint("com.google.android.apps.nexuslauncher")
        XCTAssertTrue(hint.contains("ft_launch"), hint)
        XCTAssertTrue(hint.contains("ft_list_apps"), "id の調べ方まで書くこと: \(hint)")
    }

    func testHomeScreenHintFiresOnSpringboard() {
        XCTAssertTrue(MCPServer.homeScreenLaunchHint("com.apple.springboard").contains("ft_launch"))
    }

    /// **普通のアプリでは出さない**: 「セレクタが無い」の次の手は ft_launch ではないので、
    /// ここで鳴ると毎回ノイズになる
    func testHomeScreenHintStaysSilentInsideAnApp() {
        XCTAssertEqual(MCPServer.homeScreenLaunchHint("com.example.shop"), "")
        XCTAssertEqual(MCPServer.homeScreenLaunchHint(nil), "")
    }
}
