import XCTest
@testable import FTCore

/// **上に貼り付いたヘッダの下へ潜った要素**の2つの壊れ方(2026-09-01・実機 iPhone 13 /
/// xcuitest / sut-ec-mobile の検索結果で実測)。木は当時の実物の転記で、同じ画面が
/// **両方向に**壊れていた:
///   - 本当にヘッダの下に潜っている `#btn_wishlist_electronics_4` は無警告で撃たれ、
///     実際には「クリア」ボタンに当たって検索語が消えた(沈黙した誤操作)
///   - 正しく描かれている `#btn_wishlist_electronics_5` には ⚠️scroll-leftover が付いた
///     (容器の推定が sticky な検索欄を掴んでいた)
final class StickyHeaderOcclusionTests: XCTestCase {

    private let screen = FTRect(x: 0, y: 0, width: 390, height: 844)

    private func node(_ ref: Int, _ type: String, _ identifier: String?, _ label: String?,
                      _ x: Double, _ y: Double, _ w: Double, _ h: Double,
                      depth: Int, scrollable: Bool? = nil) -> ElementInfo {
        ElementInfo(ref: ref, type: type, identifier: identifier, label: label, value: nil,
                    placeholder: nil, enabled: true,
                    frame: FTRect(x: x, y: y, width: w, height: h), depth: depth,
                    scrollable: scrollable)
    }

    /// 実測の転記(preorder + depth もそのまま)。**平坦な木**なので、depth からの祖先復元は
    /// 検索欄を全カードの「親」と見なす —— それが両方の誤りの土台になっている
    private func tree() -> [ElementInfo] {
        [
            node(1, "scrollView", nil, nil, 0, 0, 390, 844, depth: 7, scrollable: true),
            node(2, "button", "btn_back", "戻る", 8, 60, 48, 48, depth: 10),
            node(3, "other", "screen_search", nil, 0, 47, 390, 683, depth: 10),
            node(4, "textView", "field_search", "商品を検索", 56, 55, 326, 57, depth: 10),
            node(5, "staticText", nil, "商品を検索", 108, 72, 80, 24, depth: 12),
            node(6, "button", "chip_category_electronics", "家電・電化製品", 16, 124, 130, 28, depth: 12),
            // ヘッダの下へ潜った2件(ラベルまで落ちているのも実測どおり)
            node(7, "button", "btn_wishlist_electronics_3", "", 149, 85, 32, 32, depth: 12),
            node(8, "button", "btn_wishlist_electronics_4", "", 332, 85, 32, 32, depth: 12),
            node(9, "button", "product_card_electronics_3", "メカニカルキーボード 日本語配列",
                 16, 152, 175, 200, depth: 12),
            node(10, "image", nil, "メカニカルキーボード 日本語配列", 24, 176, 159, 66, depth: 14),
            node(11, "staticText", nil, "¥12,500", 24, 328, 59, 17, depth: 13),
            node(12, "button", "product_card_electronics_5", "ロボット掃除機 スマートナビ",
                 16, 360, 175, 277, depth: 12),
            node(13, "image", nil, "ロボット掃除機 スマートナビ", 24, 368, 159, 159, depth: 14),
            node(14, "staticText", nil, "¥45,000", 24, 613, 61, 17, depth: 13),
            // 写真の上に重ねて描かれた、**正しい位置の**ハート
            node(15, "button", "btn_wishlist_electronics_5", "お気に入りに追加",
                 141, 362, 48, 48, depth: 12),
            node(16, "image", nil, "お気に入りに追加", 156, 377, 18, 18, depth: 13),
        ]
    }

    private func find(_ identifier: String) -> ElementInfo {
        tree().first { $0.identifier == identifier }!
    }

    // MARK: - ヘッダの下に潜った要素をプラットフォームへ聞きに行く

    func testAnElementUnderTheStickyHeaderIsSuspected() {
        let elements = tree()
        let hidden = find("btn_wishlist_electronics_4")
        XCTAssertNil(OcclusionGeometry.overlayCovering(hidden, in: elements, screen: screen),
                     "前提: 既存の遮蔽判定は黙っている(だから聞きに行く必要がある)")
        XCTAssertTrue(TapTargetGeometry.suspectedHiddenUnderChrome(hidden, in: elements,
                                                                   screen: screen),
                      "ヘッダの下に潜った要素が無警告のまま撃たれる")
    }

    /// **陰性対照**: 写真の上に重ねただけの普通のボタンには聞きに行かない
    /// (毎タップ 72〜146ms を払わないため。ここが破れると照会が常時走る)
    func testAButtonDrawnOverItsOwnCardImageIsNotSuspected() {
        let elements = tree()
        XCTAssertFalse(TapTargetGeometry.suspectedHiddenUnderChrome(
            find("btn_wishlist_electronics_5"), in: elements, screen: screen))
        XCTAssertFalse(TapTargetGeometry.suspectedHiddenUnderChrome(
            find("product_card_electronics_5"), in: elements, screen: screen))
    }

    // MARK: - 容器の推定が sticky な入力欄を掴まない

    /// 正しい位置のハートに ⚠️scroll-leftover が付いていた原因は、平坦な木で
    /// `textView #field_search` が「同じ depth の行を2件以上含む候補」を満たしてしまうこと。
    /// 行を2件供給していたのは**ヘッダの下に潜った残骸そのもの**だった
    func testTheStickyInputFieldIsNotTakenForAClippingContainer() {
        let elements = tree()
        let heart = find("btn_wishlist_electronics_5")
        let container = StepExecutor.clippingContainer(of: heart, in: elements, inferring: true)
        XCTAssertNotEqual(container, FTRect(x: 56, y: 55, width: 326, height: 57),
                          "検索欄がカードのハートの容器に選ばれた")
        XCTAssertFalse(StepExecutor.isOutsideContainer(heart, in: elements, screen: screen),
                       "画面に見えているハートが「容器の外」と判定された")
        XCTAssertFalse(OcclusionGeometry.isUntappableGhost(heart, in: elements, screen: screen),
                       "正しく描かれているハートに ⚠️scroll-leftover が付いた")
    }

    /// **陰性対照**: 入力欄を飛ばしても容器を見失わないこと(「常に nil を返す」変異を殺す ——
    /// 容器が nil になると ghost 判定そのものが死ぬ)。
    /// 落ち着く先は `#screen_search` ではなく**根の scrollView**: 平坦な木では
    /// `#screen_search` の直後に同じ depth の `#field_search` が来るため、preorder+depth の
    /// 子孫の範囲がそこで閉じ、同 depth の行を1件も持たない候補として飛ばされる
    func testTheRealContentContainerIsStillFound() {
        let elements = tree()
        XCTAssertEqual(StepExecutor.clippingContainer(of: find("btn_wishlist_electronics_5"),
                                                      in: elements, inferring: true),
                       FTRect(x: 0, y: 0, width: 390, height: 844),
                       "スクロール容器そのものが掴めていること")
    }
}
