package com.ftester.e2ex

// NavHost のルート文字列の唯一の正。DETAIL は引数込みのテンプレート("detail/{id}")で、
// currentBackStackEntry.destination.route もこの形で返る(遷移先の実引数入り文字列ではない)。
object Routes {
    const val HOME = "home"
    const val PAGER = "pager"
    const val SHEET = "sheet"
    const val MENU = "menu"
    const val DATE = "date"
    const val DRAWER = "drawer"
    const val REFRESH = "refresh"
    const val SNACKBAR = "snackbar"
    const val GRID = "grid"
    const val SWIPE = "swipe"
    const val TABS = "tabs"
    const val ANIM = "anim"
    const val TOOLTIP = "tooltip"
    const val CHIPS = "chips"
    const val SEARCH = "search"
    const val ARG_NAV = "argnav"
    const val DETAIL = "detail/{id}"

    fun detail(id: Int) = "detail/$id"
}

fun titleForRoute(route: String?): String = when (route) {
    Routes.HOME, null -> "E2EX ホーム"
    Routes.PAGER -> "ページャ"
    Routes.SHEET -> "ボトムシート"
    Routes.MENU -> "メニュー"
    Routes.DATE -> "日付ピッカー"
    Routes.DRAWER -> "ドロワー"
    Routes.REFRESH -> "引っ張って更新"
    Routes.SNACKBAR -> "スナックバー"
    Routes.GRID -> "グリッド"
    Routes.SWIPE -> "スワイプで削除"
    Routes.TABS -> "タブ"
    Routes.ANIM -> "アニメーション"
    Routes.TOOLTIP -> "ツールチップ"
    Routes.CHIPS -> "チップと分割ボタン"
    Routes.SEARCH -> "検索バー"
    Routes.ARG_NAV -> "引数付き遷移"
    Routes.DETAIL -> "詳細"
    else -> "E2EX ホーム"
}
