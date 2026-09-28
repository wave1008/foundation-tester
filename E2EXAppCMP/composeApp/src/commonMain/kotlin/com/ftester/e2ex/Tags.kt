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

    // 第2弾ホーム(docs/ui-contract-wave2.md)
    const val NAV_COLLAPSE = "nav_collapse"
    const val NAV_STICKY = "nav_sticky"
    const val NAV_TIME = "nav_time"
    const val NAV_DIALOGS = "nav_dialogs"
    const val NAV_CONTEXT = "nav_context"
    const val NAV_REORDER = "nav_reorder"
    const val NAV_INPUTS = "nav_inputs"
    const val NAV_FAB = "nav_fab"
    const val NAV_EXPAND = "nav_expand"
    const val NAV_STEPPER = "nav_stepper"
    const val NAV_INFINITE = "nav_infinite"
    const val NAV_ZOOM = "nav_zoom"
    const val NAV_NATIVE = "nav_native"

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

    // 伸縮するヘッダ
    const val COLLAPSE_HEADER = "txt_collapse_header"
    fun collapseRow(n: Int) = "row_c_" + n.toString().padStart(2, '0')
    fun collapseRowLabel(n: Int) = "行 C" + n.toString().padStart(2, '0')
    const val COLLAPSE_ROW_COUNT = 50
    const val COLLAPSE_RESULT = "txt_collapse_result"

    // 貼り付く見出し
    val STICKY_SECTIONS = ('A'..'H').toList()
    const val STICKY_ROWS_PER_SECTION = 10
    fun stickyHeader(section: Char) = "hdr_$section"
    fun stickyHeaderLabel(section: Char) = "セクション $section"
    fun stickyRow(section: Char, n: Int) = "row_s_$section$n"
    fun stickyRowLabel(section: Char, n: Int) = "行 $section$n"
    const val STICKY_RESULT = "txt_sticky_result"

    // 時刻ピッカー
    const val BTN_OPEN_TIME = "btn_open_time"
    const val BTN_TIME_MODE_TOGGLE = "btn_time_mode_toggle"
    const val BTN_TIME_OK = "btn_time_ok"
    const val BTN_TIME_CANCEL = "btn_time_cancel"
    const val TIME_RESULT = "txt_time_result"
    const val TIME_INITIAL_HOUR = 9
    const val TIME_INITIAL_MINUTE = 30

    // ダイアログ
    const val BTN_ALERT = "btn_alert"
    const val BTN_ALERT_OK = "btn_alert_ok"
    const val BTN_ALERT_CANCEL = "btn_alert_cancel"
    const val BTN_PROMPT = "btn_prompt"
    const val FIELD_PROMPT = "field_prompt"
    const val BTN_PROMPT_SAVE = "btn_prompt_save"
    const val BTN_PROMPT_CANCEL = "btn_prompt_cancel"
    const val BTN_ACTION_SHEET = "btn_action_sheet"
    const val BTN_SHEET_CAMERA = "btn_sheet_camera"
    const val BTN_SHEET_LIBRARY = "btn_sheet_library"
    const val BTN_SHEET_CANCEL = "btn_sheet_cancel"
    const val BTN_FULLSCREEN = "btn_fullscreen"
    const val FULLSCREEN_TITLE = "txt_fullscreen_title"
    const val BTN_FULLSCREEN_SAVE = "btn_fullscreen_save"
    const val BTN_FULLSCREEN_CLOSE = "btn_fullscreen_close"
    const val DIALOGS_RESULT = "txt_dialogs_result"

    // 長押しメニュー
    fun ctxRow(n: Int) = "ctx_row_$n"
    fun ctxRowLabel(n: Int) = "長押し行 $n"
    const val CTX_ROW_COUNT = 3
    const val CTX_ITEM_EDIT = "ctx_item_edit"
    const val CTX_ITEM_COPY = "ctx_item_copy"
    const val CTX_ITEM_DELETE = "ctx_item_delete"
    const val CONTEXT_RESULT = "txt_context_result"

    // 並べ替え
    fun reorderRow(n: Int) = "reorder_row_$n"
    fun reorderRowLabel(n: Int) = "並べ替え $n"
    const val REORDER_ROW_COUNT = 5
    const val REORDER_RESULT = "txt_reorder_result"

    // 入力の種類
    const val FIELD_NUMBER = "field_number"
    const val NUMBER_ECHO = "txt_number_echo"
    const val FIELD_PASSWORD = "field_password"
    const val PASSWORD_ECHO = "txt_password_echo"
    const val FIELD_MULTILINE = "field_multiline"
    const val MULTILINE_ECHO = "txt_multiline_echo"
    const val FIELD_FIRST = "field_first"
    const val FIELD_SECOND = "field_second"
    const val FOCUS_ECHO = "txt_focus_echo"
    const val FIELD_AUTO = "field_auto"
    const val AUTO_OPT_JAPAN = "auto_opt_japan"
    const val AUTO_OPT_JAMAICA = "auto_opt_jamaica"
    const val AUTO_OPT_JORDAN = "auto_opt_jordan"
    const val AUTO_ECHO = "txt_auto_echo"
    const val FIELD_BOTTOM = "field_bottom"
    const val BOTTOM_ECHO = "txt_bottom_echo"

    // FAB
    const val FAB_ADD = "fab_add"
    const val FAB_EXTENDED = "fab_extended"
    const val BAR_ACTION_SEARCH = "bar_action_search"
    const val BAR_ACTION_SHARE = "bar_action_share"
    const val FAB_RESULT = "txt_fab_result"
    fun fabRow(n: Int) = "row_f_" + n.toString().padStart(2, '0')
    fun fabRowLabel(n: Int) = "行 F" + n.toString().padStart(2, '0')
    const val FAB_ROW_COUNT = 30

    // 展開するリスト
    const val GROUP_FRUIT = "group_fruit"
    const val GROUP_VEG = "group_veg"
    const val GROUP_DRINK = "group_drink"
    val FRUIT_ITEMS = listOf("りんご", "みかん", "ぶどう")
    val VEG_ITEMS = listOf("にんじん", "たまねぎ", "キャベツ")
    val DRINK_ITEMS = listOf("水", "お茶", "コーヒー")
    fun expandItem(group: String, n: Int) = "item_${group}_$n"
    const val EXPAND_RESULT = "txt_expand_result"

    // ステッパーと進捗
    const val STEPPER_QTY = "stepper_qty"
    const val BTN_QTY_PLUS = "btn_qty_plus"
    const val BTN_QTY_MINUS = "btn_qty_minus"
    const val QTY_RESULT = "txt_qty"
    const val QTY_MIN = 0
    const val QTY_MAX = 10
    const val QTY_INITIAL = 1
    const val BTN_START_PROGRESS = "btn_start_progress"
    const val PROGRESS_MAIN = "progress_main"
    const val PROGRESS_RESULT = "txt_progress"
    const val SPINNER_BUSY = "spinner_busy"
    const val PROGRESS_DURATION_MS = 2000

    // 無限スクロール
    const val LIST_INFINITE = "list_infinite"
    fun infiniteRow(n: Int) = "row_i_" + n.toString().padStart(2, '0')
    fun infiniteRowLabel(n: Int) = "項目 " + n.toString().padStart(2, '0')
    const val TXT_LOADING = "txt_loading"
    const val INFINITE_COUNT = "txt_infinite_count"
    const val INFINITE_RESULT = "txt_infinite_result"
    const val INFINITE_INITIAL_COUNT = 20
    const val INFINITE_PAGE_SIZE = 20
    const val INFINITE_MAX_COUNT = 100
    const val INFINITE_LOAD_DELAY_MS = 800L
    const val INFINITE_PREFETCH_THRESHOLD = 3

    // ピンチで拡大
    const val ZOOM_TARGET = "zoom_target"
    const val ZOOM_SCALE = "txt_zoom_scale"
    const val BTN_ZOOM_RESET = "btn_zoom_reset"
    const val ZOOM_MIN = 1.0f
    const val ZOOM_MAX = 4.0f

    // 固有部品
    fun carouselItem(n: Int) = "carousel_item_$n"
    const val CAROUSEL_ITEM_COUNT = 5
    const val RAIL_ITEM_HOME = "rail_item_home"
    const val RAIL_ITEM_SEARCH = "rail_item_search"
    const val RAIL_ITEM_SETTINGS = "rail_item_settings"
    const val BSS_PEEK_BUTTON = "bss_peek_button"
    const val NATIVE_RESULT = "txt_native_result"
}

// ピンチで拡大の scale echo(小数1桁固定)。commonMain に String.format が無いため自前で丸める。
fun formatScale(value: Float): String {
    val tenths = kotlin.math.round(value * 10).toInt()
    val whole = tenths / 10
    val frac = tenths % 10
    return "$whole.$frac"
}

object AppInfo {
    const val VERSION = "1.0.0"
    const val APP_ID = "com.ftester.e2ex"
}
