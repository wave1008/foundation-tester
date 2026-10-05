package com.ftester.e2ey

// NavHost のルート文字列の唯一の正。
object Routes {
    const val HOME = "home"
    const val NESTED = "nested"
    const val CHAT = "chat"
    const val LOADING = "loading"
    const val SWIPE_ACTIONS = "swipe_actions"
    const val SELECT = "select"
    const val LINKS = "links"
    const val PIN = "pin"
    const val BACK_GUARD = "back_guard"
    const val EDITOR = "editor"
    const val PLAYER = "player"
    const val HIDE_BARS = "hide_bars"
    const val TAB_HEADER = "tab_header"
    const val STAGGERED = "staggered"
}

fun titleForRoute(route: String?): String = when (route) {
    Routes.NESTED -> "入れ子スクロール"
    Routes.CHAT -> "反転チャット"
    Routes.LOADING -> "読み込みの状態"
    Routes.SWIPE_ACTIONS -> "スワイプの操作"
    Routes.SELECT -> "選択モード"
    Routes.LINKS -> "文中リンク"
    Routes.PIN -> "PIN と OTP"
    Routes.BACK_GUARD -> "戻るの横取り"
    Routes.EDITOR -> "編集"
    Routes.PLAYER -> "引き伸ばせるシート"
    Routes.HIDE_BARS -> "スクロールで隠れるバー"
    Routes.TAB_HEADER -> "折りたたみヘッダとタブ"
    Routes.STAGGERED -> "高さの揃わないグリッド"
    else -> "E2EY ホーム"
}
