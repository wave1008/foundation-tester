import Foundation

/// accessibilityIdentifier の唯一の正。値は E2EXAppCMP/docs/ui-contract.md の表と byte 一致させる。
/// Compose 版(E2EXAppCMP)と id・ラベル・echo 文字列を共通にしてあり、同じシナリオを両 SUT に
/// 当てられる(型セレクタと、iOS ネイティブに無い部品だけが SUT ごとに異なる。差分は docs/ui-contract.md)。
enum Tags {
    static let screenTitle = "txt_screen_title"

    // ホーム
    static let navPager = "nav_pager"
    static let navSheet = "nav_sheet"
    static let navMenu = "nav_menu"
    static let navDate = "nav_date"
    static let navRefresh = "nav_refresh"
    static let navSnackbar = "nav_snackbar"
    static let navGrid = "nav_grid"
    static let navSwipe = "nav_swipe"
    static let navTabs = "nav_tabs"
    static let navAnim = "nav_anim"
    static let navChips = "nav_chips"
    static let navSearch = "nav_search"
    static let navDetail = "nav_detail"
    static let navCollapse = "nav_collapse"
    static let navSticky = "nav_sticky"
    static let navTime = "nav_time"
    static let navDialogs = "nav_dialogs"
    static let navContext = "nav_context"
    static let navReorder = "nav_reorder"
    static let navInputs = "nav_inputs"
    static let navFab = "nav_fab"
    static let navExpand = "nav_expand"
    static let navStepper = "nav_stepper"
    static let navInfinite = "nav_infinite"
    static let navZoom = "nav_zoom"
    static let navNative = "nav_native"

    // ページャ
    static let pagerMain = "pager_main"
    static func txtPage(_ n: Int) -> String { "txt_page_\(n)" }
    static func btnPage(_ n: Int) -> String { "btn_page_\(n)" }
    static let txtPagerState = "txt_pager_state"
    static let txtPagerResult = "txt_pager_result"
    static let btnPagerNext = "btn_pager_next"

    // ボトムシート
    static let btnOpenSheet = "btn_open_sheet"
    static let txtSheetTitle = "txt_sheet_title"
    static func btnSheetOpt(_ n: Int) -> String { "btn_sheet_opt_\(n)" }
    static func rowSheet(_ n: Int) -> String { String(format: "row_sheet_%02d", n) }
    static let txtSheetResult = "txt_sheet_result"

    // メニュー
    static let btnOpenMenu = "btn_open_menu"
    static let menuItemCopy = "menu_item_copy"
    static let menuItemShare = "menu_item_share"
    static let menuItemDelete = "menu_item_delete"
    static let txtMenuResult = "txt_menu_result"
    static let fieldFruit = "field_fruit"
    static let txtFruitResult = "txt_fruit_result"

    // 日付ピッカー
    static let btnOpenDate = "btn_open_date"
    static let btnDateOk = "btn_date_ok"
    static let btnDateCancel = "btn_date_cancel"
    static let txtDateResult = "txt_date_result"

    // 引っ張って更新
    static func rowRefresh(_ n: Int) -> String { String(format: "row_refresh_%02d", n) }
    static let txtRefreshCount = "txt_refresh_count"

    // スナックバー(iOS はカスタム toast。docs/ui-contract.md 参照)
    static let btnShowSnackbar = "btn_show_snackbar"
    static let btnShowSnackbarShort = "btn_show_snackbar_short"
    static let txtSnackbarResult = "txt_snackbar_result"

    // グリッド
    static let gridMain = "grid_main"
    static func cell(_ n: Int) -> String { String(format: "cell_%02d", n) }
    static let txtGridResult = "txt_grid_result"

    // スワイプで削除
    static func swipeRow(_ n: Int) -> String { "swipe_row_\(n)" }
    static let txtSwipeResult = "txt_swipe_result"
    static let txtSwipeCount = "txt_swipe_count"

    // タブ
    static let tabA = "tab_a"
    static let tabB = "tab_b"
    static let tabC = "tab_c"
    static let txtTabContent = "txt_tab_content"
    static let stabRow = "stab_row"
    static func stab(_ n: Int) -> String { String(format: "stab_%02d", n) }
    static let txtStabContent = "txt_stab_content"
    static let navbarHome = "navbar_home"
    static let navbarSearch = "navbar_search"
    static let navbarSettings = "navbar_settings"
    static let txtNavbarResult = "txt_navbar_result"

    // アニメーション
    static let btnToggleAnim = "btn_toggle_anim"
    static let txtAnimTarget = "txt_anim_target"
    static let txtAnimVisible = "txt_anim_visible"
    static let btnAnimInc = "btn_anim_inc"
    static let txtAnimCount = "txt_anim_count"

    // チップと分割ボタン
    static let chipWifi = "chip_wifi"
    static let txtChipResult = "txt_chip_result"
    static let chipAssist = "chip_assist"
    static let txtAssistResult = "txt_assist_result"
    static let segDay = "seg_day"
    static let segWeek = "seg_week"
    static let segMonth = "seg_month"
    static let txtSegResult = "txt_seg_result"
    static let txtRangeResult = "txt_range_result"

    // 検索バー
    static func suggestion(_ name: String) -> String { "suggestion_\(name)" }
    static let txtSearchResult = "txt_search_result"

    // 引数付き遷移
    static func detailLink(_ n: Int) -> String { "detail_link_\(n)" }
    static let txtDetailId = "txt_detail_id"
    static let btnDetailNext = "btn_detail_next"

    // 伸縮するヘッダ
    static let txtCollapseHeader = "txt_collapse_header"
    static func rowC(_ n: Int) -> String { String(format: "row_c_%02d", n) }
    static let txtCollapseResult = "txt_collapse_result"

    // 貼り付く見出し
    static func hdr(_ letter: String) -> String { "hdr_\(letter)" }
    static func rowSticky(_ letter: String, _ n: Int) -> String { "row_s_\(letter)\(n)" }
    static let txtStickyResult = "txt_sticky_result"

    // 時刻ピッカー
    static let btnOpenTime = "btn_open_time"
    static let btnTimeOk = "btn_time_ok"
    static let btnTimeCancel = "btn_time_cancel"
    static let txtTimeResult = "txt_time_result"

    // ダイアログ(トーストは省く。docs/ui-contract.md 参照)
    static let btnAlert = "btn_alert"
    static let btnPrompt = "btn_prompt"
    static let fieldPrompt = "field_prompt"
    static let btnActionSheet = "btn_action_sheet"
    static let btnFullscreen = "btn_fullscreen"
    static let txtFullscreenTitle = "txt_fullscreen_title"
    static let btnFullscreenSave = "btn_fullscreen_save"
    static let btnFullscreenClose = "btn_fullscreen_close"
    static let txtDialogsResult = "txt_dialogs_result"

    // 長押しメニュー
    static func ctxRow(_ n: Int) -> String { "ctx_row_\(n)" }
    static let txtContextResult = "txt_context_result"

    // 並べ替え
    static func reorderRow(_ n: Int) -> String { "reorder_row_\(n)" }
    static let txtReorderResult = "txt_reorder_result"

    // 入力の種類
    static let fieldNumber = "field_number"
    static let txtNumberEcho = "txt_number_echo"
    static let fieldPassword = "field_password"
    static let txtPasswordEcho = "txt_password_echo"
    static let fieldMultiline = "field_multiline"
    static let txtMultilineEcho = "txt_multiline_echo"
    static let fieldFirst = "field_first"
    static let fieldSecond = "field_second"
    static let txtFocusEcho = "txt_focus_echo"
    static let fieldAuto = "field_auto"
    static let txtAutoEcho = "txt_auto_echo"
    static func autoOpt(_ name: String) -> String { "auto_opt_\(name.lowercased())" }
    static let fieldBottom = "field_bottom"
    static let txtBottomEcho = "txt_bottom_echo"

    // FAB(行ラベルは契約が明記しないため他画面と揃えて命名)
    static let fabAdd = "fab_add"
    static let fabExtended = "fab_extended"
    static let barActionSearch = "bar_action_search"
    static let barActionShare = "bar_action_share"
    static let txtFabResult = "txt_fab_result"
    static func rowF(_ n: Int) -> String { String(format: "row_f_%02d", n) }

    // 展開するリスト
    static let groupFruit = "group_fruit"
    static let groupVeg = "group_veg"
    static let groupDrink = "group_drink"
    static func item(_ kind: String, _ n: Int) -> String { "item_\(kind)_\(n)" }
    static let txtExpandResult = "txt_expand_result"

    // ステッパーと進捗(+/- は Stepper 本体に一体化。btn_qty_plus/minus は存在しない)
    static let stepperQty = "stepper_qty"
    static let txtQty = "txt_qty"
    static let btnStartProgress = "btn_start_progress"
    static let progressMain = "progress_main"
    static let txtProgress = "txt_progress"
    static let spinnerBusy = "spinner_busy"

    // 無限スクロール
    static let listInfinite = "list_infinite"
    static func rowI(_ n: Int) -> String { String(format: "row_i_%02d", n) }
    static let txtLoading = "txt_loading"
    static let txtInfiniteCount = "txt_infinite_count"
    static let txtInfiniteResult = "txt_infinite_result"

    // ピンチで拡大
    static let zoomTarget = "zoom_target"
    static let txtZoomScale = "txt_zoom_scale"
    static let btnZoomReset = "btn_zoom_reset"

    // 固有部品(btn_detent / btn_detent_tapped は契約が id を明記しないため独自に追加)
    static func cvItem(_ n: Int) -> String { "cv_item_\(n)" }
    static let btnPopover = "btn_popover"
    static let btnPopoverOk = "btn_popover_ok"
    static let btnDetent = "btn_detent"
    static let btnDetentTapped = "btn_detent_tapped"
    static let txtNativeResult = "txt_native_result"
}

enum AppInfo {
    static let version = "1.0.0"
    static let appID = "com.ftester.e2ex.ios"
}
