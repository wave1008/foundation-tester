// iOS の back が「戻るボタンを押す」か「エッジスワイプに落ちる」かの判定。
//
// エッジスワイプは interactive pop の成立を保証できず、成立しなければ同じタッチが
// 下の要素へ渡る(押していない行が反応し得る)。UIKit/SwiftUI が付ける `BackButton`
// 識別子があるときは決定的な経路を選ぶ。**Compose/Flutter はシステムのナビゲーションバーを
// 持たない**ので nil = 従来のスワイプへ落ちること(既存挙動を変えない)まで固定する。

import XCTest
import FTCore
@testable import FTBridgeClient

final class NavigationBackButtonTests: XCTestCase {

    private func element(_ ref: Int, type: String, id: String?, enabled: Bool = true) -> ElementInfo {
        ElementInfo(ref: ref, type: type, identifier: id, label: nil, value: nil,
                    placeholder: nil, enabled: enabled,
                    frame: FTRect(x: 16, y: 62, width: 44, height: 44), depth: 12)
    }

    private func snapshot(_ elements: [ElementInfo]) -> SnapshotResponse {
        SnapshotResponse(sessionBundleID: "com.example.app",
                         screen: FTRect(x: 0, y: 0, width: 402, height: 874),
                         elements: elements, truncatedCount: 0)
    }

    func testFindsTheUIKitBackButton() {
        let tree = snapshot([
            element(1, type: "navigationBar", id: "一般"),
            element(2, type: "button", id: "BackButton"),
            element(3, type: "button", id: "com.apple.settings.general"),
        ])
        XCTAssertEqual(BridgeClient.navigationBackButton(in: tree)?.ref, 2)
    }

    /// **自前描画のフレームワークでは見つからない**(= 従来のエッジスワイプへ落ちる)
    func testFallsBackWhenThereIsNoSystemNavigationBar() {
        let tree = snapshot([
            element(1, type: "button", id: "btn_back"),   // アプリ内の自前ボタン
            element(2, type: "button", id: "nav_selector"),
        ])
        XCTAssertNil(BridgeClient.navigationBackButton(in: tree))
    }

    /// 戻れない状態(無効)のボタンは押さない —— 押しても進まないうえ、
    /// スワイプという代替手段まで捨てることになる
    func testIgnoresADisabledBackButton() {
        let tree = snapshot([element(1, type: "button", id: "BackButton", enabled: false)])
        XCTAssertNil(BridgeClient.navigationBackButton(in: tree))
    }

    /// 識別子が同じでもボタンでなければ採らない(ラベルや画像を押しにいかない)
    func testIgnoresNonButtonsWithTheSameIdentifier() {
        let tree = snapshot([element(1, type: "staticText", id: "BackButton")])
        XCTAssertNil(BridgeClient.navigationBackButton(in: tree))
    }
}
