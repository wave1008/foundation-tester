package com.ftester.e2ex

// testTag の唯一の正。値は docs/ui-contract.md の表と byte 一致させる。
// シナリオ側(TestProjects/E2EX-CMP/scenarios)が "#<値>" で参照するため、リネームは契約変更。
object Tags {
    // シェル
    const val SCREEN_TITLE = "txt_screen_title"
    const val BACK = "btn_back"

    // ホーム
    const val NAV_PAGER = "nav_pager"
    const val NAV_SHEET = "nav_sheet"
    const val NAV_MENU = "nav_menu"
    const val NAV_DATE = "nav_date"
    const val NAV_DRAWER = "nav_drawer"
    const val NAV_REFRESH = "nav_refresh"
    const val NAV_SNACKBAR = "nav_snackbar"
    const val NAV_GRID = "nav_grid"
    const val NAV_SWIPE = "nav_swipe"
    const val NAV_TABS = "nav_tabs"
    const val NAV_ANIM = "nav_anim"
    const val NAV_TOOLTIP = "nav_tooltip"
    const val NAV_CHIPS = "nav_chips"
    const val NAV_SEARCH = "nav_search"
    const val NAV_DETAIL = "nav_detail"

    // ページャ
    const val PAGER_MAIN = "pager_main"
    fun page(n: Int) = "txt_page_$n"
    fun pageLabel(n: Int) = "ページ $n"
    fun pageButton(n: Int) = "btn_page_$n"
    fun pageButtonLabel(n: Int) = "ページ $n のボタン"
    const val PAGER_STATE = "txt_pager_state"
    const val PAGER_RESULT = "txt_pager_result"
    const val PAGER_NEXT = "btn_pager_next"
    const val PAGE_COUNT = 5

    // ボトムシート
    const val BTN_OPEN_SHEET = "btn_open_sheet"
    const val SHEET_TITLE = "txt_sheet_title"
    fun sheetOpt(n: Int) = "btn_sheet_opt_$n"
    fun sheetOptLabel(n: Int) = "選択肢 $n"
    fun sheetRow(n: Int) = "row_sheet_" + n.toString().padStart(2, '0')
    fun sheetRowLabel(n: Int) = "シート行 " + n.toString().padStart(2, '0')
    const val SHEET_ROW_COUNT = 30
    const val SHEET_RESULT = "txt_sheet_result"

    // メニュー
    const val BTN_OPEN_MENU = "btn_open_menu"
    const val MENU_ITEM_COPY = "menu_item_copy"
    const val MENU_ITEM_SHARE = "menu_item_share"
    const val MENU_ITEM_DELETE = "menu_item_delete"
    const val MENU_RESULT = "txt_menu_result"
    const val FIELD_FRUIT = "field_fruit"
    const val OPT_FRUIT_APPLE = "opt_fruit_apple"
    const val OPT_FRUIT_BANANA = "opt_fruit_banana"
    const val OPT_FRUIT_CHERRY = "opt_fruit_cherry"
    const val FRUIT_RESULT = "txt_fruit_result"

    // 日付ピッカー
    const val BTN_OPEN_DATE = "btn_open_date"
    const val BTN_DATE_OK = "btn_date_ok"
    const val BTN_DATE_CANCEL = "btn_date_cancel"
    const val DATE_RESULT = "txt_date_result"

    // ドロワー
    const val BTN_OPEN_DRAWER = "btn_open_drawer"
    const val DRAWER_HEADER = "txt_drawer_header"
    const val DRAWER_ITEM_INBOX = "drawer_item_inbox"
    const val DRAWER_ITEM_SENT = "drawer_item_sent"
    const val DRAWER_ITEM_TRASH = "drawer_item_trash"
    const val DRAWER_RESULT = "txt_drawer_result"
    const val DRAWER_STATE = "txt_drawer_state"

    // 引っ張って更新
    const val BOX_REFRESH = "box_refresh"
    fun refreshRow(n: Int) = "row_refresh_" + n.toString().padStart(2, '0')
    fun refreshRowLabel(n: Int) = "更新行 " + n.toString().padStart(2, '0')
    const val REFRESH_ROW_COUNT = 20
    const val REFRESH_COUNT = "txt_refresh_count"

    // スナックバー
    const val BTN_SHOW_SNACKBAR = "btn_show_snackbar"
    const val BTN_SHOW_SNACKBAR_SHORT = "btn_show_snackbar_short"
    const val SNACKBAR_RESULT = "txt_snackbar_result"

    // グリッド
    const val GRID_MAIN = "grid_main"
    fun cell(n: Int) = "cell_" + n.toString().padStart(2, '0')
    fun cellLabel(n: Int) = "セル " + n.toString().padStart(2, '0')
    const val GRID_CELL_COUNT = 90
    const val GRID_RESULT = "txt_grid_result"

    // スワイプで削除
    fun swipeRow(n: Int) = "swipe_row_$n"
    fun swipeRowLabel(n: Int) = "スワイプ行 $n"
    const val SWIPE_ROW_COUNT = 5
    const val SWIPE_RESULT = "txt_swipe_result"
    const val SWIPE_COUNT = "txt_swipe_count"

    // タブ
    const val TAB_A = "tab_a"
    const val TAB_B = "tab_b"
    const val TAB_C = "tab_c"
    const val TAB_CONTENT = "txt_tab_content"
    fun stab(n: Int) = "stab_" + n.toString().padStart(2, '0')
    fun stabLabel(n: Int) = "項目タブ" + n.toString().padStart(2, '0')
    const val STAB_ROW = "stab_row"
    const val STAB_COUNT = 12
    const val STAB_CONTENT = "txt_stab_content"
    const val NAVBAR_HOME = "navbar_home"
    const val NAVBAR_SEARCH = "navbar_search"
    const val NAVBAR_SETTINGS = "navbar_settings"
    const val NAVBAR_RESULT = "txt_navbar_result"

    // アニメーション
    const val BTN_TOGGLE_ANIM = "btn_toggle_anim"
    const val ANIM_TARGET = "txt_anim_target"
    const val ANIM_VISIBLE = "txt_anim_visible"
    const val BTN_ANIM_INC = "btn_anim_inc"
    const val ANIM_COUNT = "txt_anim_count"

    // ツールチップ
    const val BTN_TOOLTIP_ANCHOR = "btn_tooltip_anchor"
    const val TOOLTIP_TEXT = "txt_tooltip"
    const val TOOLTIP_STATE = "txt_tooltip_state"

    // チップと分割ボタン
    const val CHIP_WIFI = "chip_wifi"
    const val CHIP_RESULT = "txt_chip_result"
    const val CHIP_ASSIST = "chip_assist"
    const val ASSIST_RESULT = "txt_assist_result"
    const val SEG_DAY = "seg_day"
    const val SEG_WEEK = "seg_week"
    const val SEG_MONTH = "seg_month"
    const val SEG_RESULT = "txt_seg_result"
    const val RANGE_SLIDER = "range_slider"
    const val RANGE_RESULT = "txt_range_result"

    // 検索バー
    const val FIELD_SEARCH = "field_search"
    const val SUGGESTION_APPLE = "suggestion_apple"
    const val SUGGESTION_APRICOT = "suggestion_apricot"
    const val SUGGESTION_BANANA = "suggestion_banana"
    const val SEARCH_RESULT = "txt_search_result"

    // 引数付き遷移
    fun detailLink(n: Int) = "detail_link_$n"
    fun detailLinkLabel(n: Int) = "詳細 $n"
    const val DETAIL_LINK_COUNT = 3
    const val DETAIL_ID = "txt_detail_id"
    const val BTN_DETAIL_NEXT = "btn_detail_next"
}

object AppInfo {
    const val VERSION = "1.0.0"
    const val APP_ID = "com.ftester.e2ex"
}
