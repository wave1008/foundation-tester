import SwiftUI

/// ドロワー・ツールチップは iOS に定番の慣用が無いため行ごと省く(docs/ui-contract.md §省いた画面)。
struct HomeScreen: View {
    var body: some View {
        List {
            row(.pager, "ページャ", Tags.navPager)
            row(.sheet, "ボトムシート", Tags.navSheet)
            row(.menu, "メニュー", Tags.navMenu)
            row(.date, "日付ピッカー", Tags.navDate)
            row(.refresh, "引っ張って更新", Tags.navRefresh)
            row(.snackbar, "スナックバー", Tags.navSnackbar)
            row(.grid, "グリッド", Tags.navGrid)
            row(.swipe, "スワイプで削除", Tags.navSwipe)
            row(.tabs, "タブ", Tags.navTabs)
            row(.anim, "アニメーション", Tags.navAnim)
            row(.chips, "チップと分割ボタン", Tags.navChips)
            row(.search, "検索バー", Tags.navSearch)
            row(.detailMenu, "引数付き遷移", Tags.navDetail)
            row(.collapse, "伸縮するヘッダ", Tags.navCollapse)
            row(.sticky, "貼り付く見出し", Tags.navSticky)
            row(.time, "時刻ピッカー", Tags.navTime)
            row(.dialogs, "ダイアログ", Tags.navDialogs)
            row(.context, "長押しメニュー", Tags.navContext)
            row(.reorder, "並べ替え", Tags.navReorder)
            row(.inputs, "入力の種類", Tags.navInputs)
            row(.fab, "FAB", Tags.navFab)
            row(.expand, "展開するリスト", Tags.navExpand)
            row(.stepper, "ステッパーと進捗", Tags.navStepper)
            row(.infinite, "無限スクロール", Tags.navInfinite)
            row(.zoom, "ピンチで拡大", Tags.navZoom)
            row(.native, "固有部品", Tags.navNative)
        }
        .screenTitleTag("E2EX ホーム")
    }

    private func row(_ route: Route, _ label: String, _ tag: String) -> some View {
        NavigationLink(value: route) { Text(label) }
            .accessibilityIdentifier(tag)
    }
}
