import SwiftUI

/// **キーボードの下に潜った入力欄**の witness(iOS SUT だけが持つ)。
///
/// 上の欄(`#field_above_keyboard`)で焦点を取るとキーボードが立ち、下の欄
/// (`#field_under_keyboard`)がその下に潜る。潜ったまま打つと**焦点が移らず、打鍵が
/// 直前に焦点のあった上の欄へ流れ込む**(受け手の 4.7 インチ実機で実測。市区町村の欄に
/// 住所が3回ぶん追記された)。ツールが打つ前に容器を送って外せていれば、下の欄に入る。
///
/// **容器は UIKit の素の UIScrollView**(`KeyboardCoverScroll`)。SwiftUI の ScrollView は
/// キーボードぶん縮むので、その下の欄は「容器の外」になり別の復帰が働いてしまう。
struct KeyboardCoverScreen: View {
    @State private var above = ""
    @State private var under = ""

    var body: some View {
        KeyboardCoverScroll(above: $above, under: $under, rowCount: 6)
            // **キーボードぶん容器を縮めない**。縮むと対象は「容器の外」になり、既存の
            // 復帰(容器外の再解決)が働いて witness にならない。
            // **高さは固定する**(埋める形にすると、ignoresSafeArea があってもキーボードぶん
            // 縮んで対象が「容器の外」になり witness にならない。2026-09-05 に実測: 491 → 258)。
            // ただし**最小サポート画面(375x667)に入る値**にする —— 固定 700pt はあちらに入らず、
            // キーボードが立った瞬間に容器の枠ごと上へずれて `#field_above_keyboard` が
            // 木から消えていた(実測: 枠 y=9 → -107)。
            .frame(height: 460)
            .ignoresSafeArea(.keyboard, edges: .bottom)
    }
}
