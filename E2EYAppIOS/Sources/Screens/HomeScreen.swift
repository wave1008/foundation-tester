import SwiftUI

struct HomeScreen: View {
    var body: some View {
        List {
            row(.nested, "入れ子スクロール", Tags.navNested)
            row(.chat, "反転チャット", Tags.navChat)
            row(.loading, "読み込みの状態", Tags.navLoading)
            row(.swipeActions, "スワイプの操作", Tags.navSwipeActions)
            row(.select, "選択モード", Tags.navSelect)
            row(.links, "文中リンク", Tags.navLinks)
            row(.pin, "PIN と OTP", Tags.navPin)
            row(.backGuard, "戻るの横取り", Tags.navBackGuard)
            row(.player, "引き伸ばせるシート", Tags.navPlayer)
            row(.hideBars, "スクロールで隠れるバー", Tags.navHideBars)
            row(.tabHeader, "折りたたみヘッダとタブ", Tags.navTabHeader)
            row(.staggered, "高さの揃わないグリッド", Tags.navStaggered)
        }
        .screenTitleTag("E2EY ホーム")
    }

    private func row(_ route: Route, _ label: String, _ tag: String) -> some View {
        NavigationLink(value: route) { Text(label) }
            .accessibilityIdentifier(tag)
    }
}
