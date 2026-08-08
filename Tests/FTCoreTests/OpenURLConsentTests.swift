// OpenURLConsent.confirmButtonRef の単体テスト。フィクスチャは実測(iOS 27 シミュレータ、
// openURL 直後に SpringBoard が出す確認アラート)をそのまま使う。実測は depth を記録していない
// ため、記述された入れ子構造(タイトルを持つ scrollView / ボタン2つを持つ scrollView がそれぞれ
// アラートの子で、その中身がさらに1段深い)から depth を復元してある。

import XCTest
@testable import FTCore

final class OpenURLConsentTests: XCTestCase {

    private func element(_ ref: Int, _ type: String, _ label: String?, depth: Int) -> ElementInfo {
        ElementInfo(ref: ref, type: type, identifier: nil, label: label, value: nil,
                    placeholder: nil, enabled: true,
                    frame: FTRect(x: 0, y: 0, width: 10, height: 10), depth: depth)
    }

    private func snapshot(_ elements: [ElementInfo]) -> SnapshotResponse {
        SnapshotResponse(sessionBundleID: nil, screen: FTRect(x: 0, y: 0, width: 390, height: 844),
                         elements: elements, truncatedCount: 0)
    }

    /// 実測木そのもの: [1] alert / [2-3] タイトルの scrollView / [4-6] ボタン2つの scrollView
    private func realisticAlertTree(alertLabel: String = "\u{201C}FT E2E RN\u{201D}\u{3067}\u{958B}\u{304D}\u{307E}\u{3059}\u{304B}?") -> [ElementInfo] {
        [
            element(1, "alert", alertLabel, depth: 0),
            element(2, "scrollView", "scroll", depth: 1),
            element(3, "staticText", alertLabel, depth: 2),
            element(4, "scrollView", "scroll", depth: 1),
            element(5, "button", "\u{30AD}\u{30E3}\u{30F3}\u{30BB}\u{30EB}", depth: 2),   // キャンセル
            element(6, "button", "\u{958B}\u{304F}", depth: 2),                          // 開く
        ]
    }

    func testPicksTheLastButtonInTreeOrderAsTheConfirmButton() {
        let tree = snapshot(realisticAlertTree())
        XCTAssertEqual(OpenURLConsent.confirmButtonRef(in: tree, appDisplayName: "FT E2E RN"), 6)
    }

    func testDoesNotPressWhenNoAlertIsPresent() {
        let tree = snapshot([
            element(1, "staticText", "Home", depth: 0),
            element(2, "button", "Settings", depth: 1),
        ])
        XCTAssertNil(OpenURLConsent.confirmButtonRef(in: tree, appDisplayName: "FT E2E RN"))
    }

    /// ラベル文字列("で開きますか?"/"開く")では同定しない —— 端末ロケールで変わるため。
    /// アラートの label に**対象アプリの表示名**が無ければ、他アプリ宛のアラートとして無視する
    func testDoesNotPressAnAlertForADifferentApp() {
        let tree = snapshot(realisticAlertTree(
            alertLabel: "\u{201C}Some Other App\u{201D} Wants to Open This Page"))
        XCTAssertNil(OpenURLConsent.confirmButtonRef(in: tree, appDisplayName: "FT E2E RN"))
    }

    /// **表示名は互いの部分文字列になり得る**(`FT E2E` ⊂ `FT E2E RN`)。同じスキームを複数アプリが
    /// 登録している端末では、素の contains だと別アプリ宛の確認を了承してしまう。引用符込みで
    /// 照合するため、これは一致しない(2026-08-09 に E2E で実際に踏んだ形)
    func testDoesNotPressWhenTheAppNameIsOnlyAPrefixOfTheAlertsApp() {
        let tree = snapshot(realisticAlertTree())   // ラベルは “FT E2E RN”
        XCTAssertNil(OpenURLConsent.confirmButtonRef(in: tree, appDisplayName: "FT E2E"))
    }

    /// ボタンが2つちょうどでなければ同定しない(3択の共有シート等、openURL 確認と別物の可能性)
    func testDoesNotPressWhenTheAlertHasThreeButtons() {
        var elements = realisticAlertTree()
        elements.append(element(7, "button", "Always Allow", depth: 2))
        XCTAssertNil(OpenURLConsent.confirmButtonRef(in: snapshot(elements), appDisplayName: "FT E2E RN"))
    }

    /// ボタンが1つしか無ければ同定しない(2択の openURL 確認とは別物)
    func testDoesNotPressWhenTheAlertHasOnlyOneButton() {
        let tree = snapshot([
            element(1, "alert", "\u{201C}FT E2E RN\u{201D} needs your attention", depth: 0),
            element(2, "button", "OK", depth: 1),
        ])
        XCTAssertNil(OpenURLConsent.confirmButtonRef(in: tree, appDisplayName: "FT E2E RN"))
    }

    /// アラートの外にある要素は無関係(たまたま2ボタンの別 UI が同じ木にある場合の誤爆防止)
    func testIgnoresButtonsOutsideTheAlertsSubtree() {
        var elements = realisticAlertTree()
        // アラートと同格(depth 0)の兄弟要素にボタンを2つ追加しても、そちらは数えない
        elements.append(contentsOf: [
            element(7, "button", "A", depth: 0),
            element(8, "button", "B", depth: 0),
        ])
        XCTAssertEqual(OpenURLConsent.confirmButtonRef(in: snapshot(elements), appDisplayName: "FT E2E RN"), 6)
    }

    func testEmptyDisplayNameNeverMatches() {
        let tree = snapshot(realisticAlertTree())
        XCTAssertNil(OpenURLConsent.confirmButtonRef(in: tree, appDisplayName: ""))
    }
}
