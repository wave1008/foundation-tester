// #id の唯一の正は E2EXAppCMP/docs/ui-contract.md。値はそこの表と byte 一致させる
// (シナリオが "#<値>" で参照するため、リネームは契約変更)。
class Tags {
  // シェル
  static const screenTitle = 'txt_screen_title';
  static const back = 'btn_back';

  // ホーム
  static const navPager = 'nav_pager';
  static const navSheet = 'nav_sheet';
  static const navMenu = 'nav_menu';
  static const navDate = 'nav_date';
  static const navDrawer = 'nav_drawer';
  static const navRefresh = 'nav_refresh';
  static const navSnackbar = 'nav_snackbar';
  static const navGrid = 'nav_grid';
  static const navSwipe = 'nav_swipe';
  static const navTabs = 'nav_tabs';
  static const navAnim = 'nav_anim';
  static const navTooltip = 'nav_tooltip';
  static const navChips = 'nav_chips';
  static const navSearch = 'nav_search';
  static const navDetail = 'nav_detail';

  // ページャ
  static const pagerMain = 'pager_main';
  static String page(int n) => 'txt_page_$n';
  static String pageLabel(int n) => 'ページ $n';
  static String pageButton(int n) => 'btn_page_$n';
  static String pageButtonLabel(int n) => 'ページ $n のボタン';
  static const pagerState = 'txt_pager_state';
  static const pagerResult = 'txt_pager_result';
  static const pagerNext = 'btn_pager_next';
  static const pageCount = 5;

  // ボトムシート
  static const btnOpenSheet = 'btn_open_sheet';
  static const sheetTitle = 'txt_sheet_title';
  static String sheetOpt(int n) => 'btn_sheet_opt_$n';
  static String sheetOptLabel(int n) => '選択肢 $n';
  static String sheetRow(int n) => 'row_sheet_${n.toString().padLeft(2, '0')}';
  static String sheetRowLabel(int n) => 'シート行 ${n.toString().padLeft(2, '0')}';
  static const sheetRowCount = 30;
  static const sheetResult = 'txt_sheet_result';

  // メニュー
  static const btnOpenMenu = 'btn_open_menu';
  static const menuItemCopy = 'menu_item_copy';
  static const menuItemShare = 'menu_item_share';
  static const menuItemDelete = 'menu_item_delete';
  static const menuResult = 'txt_menu_result';
  static const fieldFruit = 'field_fruit';
  static const optFruitApple = 'opt_fruit_apple';
  static const optFruitBanana = 'opt_fruit_banana';
  static const optFruitCherry = 'opt_fruit_cherry';
  static const fruitResult = 'txt_fruit_result';

  // 日付ピッカー
  static const btnOpenDate = 'btn_open_date';
  static const btnDateOk = 'btn_date_ok';
  static const btnDateCancel = 'btn_date_cancel';
  static const dateResult = 'txt_date_result';

  // ドロワー
  static const btnOpenDrawer = 'btn_open_drawer';
  static const drawerHeader = 'txt_drawer_header';
  static const drawerItemInbox = 'drawer_item_inbox';
  static const drawerItemSent = 'drawer_item_sent';
  static const drawerItemTrash = 'drawer_item_trash';
  static const drawerResult = 'txt_drawer_result';
  static const drawerState = 'txt_drawer_state';

  // 引っ張って更新
  static const boxRefresh = 'box_refresh';
  static String refreshRow(int n) => 'row_refresh_${n.toString().padLeft(2, '0')}';
  static String refreshRowLabel(int n) => '更新行 ${n.toString().padLeft(2, '0')}';
  static const refreshRowCount = 20;
  static const refreshCount = 'txt_refresh_count';

  // スナックバー
  static const btnShowSnackbar = 'btn_show_snackbar';
  static const btnShowSnackbarShort = 'btn_show_snackbar_short';
  static const snackbarResult = 'txt_snackbar_result';

  // グリッド
  static const gridMain = 'grid_main';
  static String cell(int n) => 'cell_${n.toString().padLeft(2, '0')}';
  static String cellLabel(int n) => 'セル ${n.toString().padLeft(2, '0')}';
  static const gridCellCount = 90;
  static const gridResult = 'txt_grid_result';

  // スワイプで削除
  static String swipeRow(int n) => 'swipe_row_$n';
  static String swipeRowLabel(int n) => 'スワイプ行 $n';
  static const swipeRowCount = 5;
  static const swipeResult = 'txt_swipe_result';
  static const swipeCount = 'txt_swipe_count';

  // タブ
  static const tabA = 'tab_a';
  static const tabB = 'tab_b';
  static const tabC = 'tab_c';
  static const tabContent = 'txt_tab_content';
  static String stab(int n) => 'stab_${n.toString().padLeft(2, '0')}';
  static String stabLabel(int n) => '項目タブ${n.toString().padLeft(2, '0')}';
  static const stabRow = 'stab_row';
  static const stabCount = 12;
  static const stabContent = 'txt_stab_content';
  static const navbarHome = 'navbar_home';
  static const navbarSearch = 'navbar_search';
  static const navbarSettings = 'navbar_settings';
  static const navbarResult = 'txt_navbar_result';

  // アニメーション
  static const btnToggleAnim = 'btn_toggle_anim';
  static const animTarget = 'txt_anim_target';
  static const animVisible = 'txt_anim_visible';
  static const btnAnimInc = 'btn_anim_inc';
  static const animCount = 'txt_anim_count';

  // ツールチップ
  static const btnTooltipAnchor = 'btn_tooltip_anchor';
  static const tooltipText = 'txt_tooltip';
  static const tooltipState = 'txt_tooltip_state';

  // チップと分割ボタン
  static const chipWifi = 'chip_wifi';
  static const chipResult = 'txt_chip_result';
  static const chipAssist = 'chip_assist';
  static const assistResult = 'txt_assist_result';
  static const segDay = 'seg_day';
  static const segWeek = 'seg_week';
  static const segMonth = 'seg_month';
  static const segResult = 'txt_seg_result';
  static const rangeSlider = 'range_slider';
  static const rangeResult = 'txt_range_result';

  // 検索バー
  static const fieldSearch = 'field_search';
  static const suggestionApple = 'suggestion_apple';
  static const suggestionApricot = 'suggestion_apricot';
  static const suggestionBanana = 'suggestion_banana';
  static const searchResult = 'txt_search_result';

  // 引数付き遷移
  static String detailLink(int n) => 'detail_link_$n';
  static String detailLinkLabel(int n) => '詳細 $n';
  static const detailLinkCount = 3;
  static const detailId = 'txt_detail_id';
  static const btnDetailNext = 'btn_detail_next';

  // ホーム(第2弾)
  static const navCollapse = 'nav_collapse';
  static const navSticky = 'nav_sticky';
  static const navTime = 'nav_time';
  static const navDialogs = 'nav_dialogs';
  static const navContext = 'nav_context';
  static const navReorder = 'nav_reorder';
  static const navInputs = 'nav_inputs';
  static const navFab = 'nav_fab';
  static const navExpand = 'nav_expand';
  static const navStepper = 'nav_stepper';
  static const navInfinite = 'nav_infinite';
  static const navZoom = 'nav_zoom';
  static const navNative = 'nav_native';

  // 伸縮するヘッダ
  static const collapseHeader = 'txt_collapse_header';
  static String rowC(int n) => 'row_c_${n.toString().padLeft(2, '0')}';
  static String rowCLabel(int n) => '行 C${n.toString().padLeft(2, '0')}';
  static const collapseRowCount = 50;
  static const collapseResult = 'txt_collapse_result';

  // 貼り付く見出し
  static const stickySections = ['A', 'B', 'C', 'D', 'E', 'F', 'G', 'H'];
  static String hdr(String section) => 'hdr_$section';
  static String hdrLabel(String section) => 'セクション $section';
  static String rowS(String section, int n) => 'row_s_$section$n';
  static String rowSLabel(String section, int n) => '行 $section$n';
  static const stickyRowsPerSection = 10;
  static const stickyResult = 'txt_sticky_result';

  // 時刻ピッカー
  static const btnOpenTime = 'btn_open_time';
  static const btnTimeOk = 'btn_time_ok';
  static const btnTimeCancel = 'btn_time_cancel';
  static const timeResult = 'txt_time_result';

  // ダイアログ
  static const btnAlert = 'btn_alert';
  static const btnPrompt = 'btn_prompt';
  static const fieldPrompt = 'field_prompt';
  static const btnActionSheet = 'btn_action_sheet';
  static const btnFullscreen = 'btn_fullscreen';
  static const txtFullscreenTitle = 'txt_fullscreen_title';
  static const btnFullscreenSave = 'btn_fullscreen_save';
  static const btnFullscreenClose = 'btn_fullscreen_close';
  static const dialogsResult = 'txt_dialogs_result';

  // 長押しメニュー
  static String ctxRow(int n) => 'ctx_row_$n';
  static String ctxRowLabel(int n) => '長押し行 $n';
  static const ctxRowCount = 3;
  static const contextResult = 'txt_context_result';

  // 並べ替え
  static String reorderRow(int n) => 'reorder_row_$n';
  static String reorderRowLabel(int n) => '並べ替え $n';
  static const reorderRowCount = 5;
  static const reorderResult = 'txt_reorder_result';

  // 入力の種類
  static const fieldNumber = 'field_number';
  static const numberEcho = 'txt_number_echo';
  static const fieldPassword = 'field_password';
  static const passwordEcho = 'txt_password_echo';
  static const fieldMultiline = 'field_multiline';
  static const multilineEcho = 'txt_multiline_echo';
  static const fieldFirst = 'field_first';
  static const fieldSecond = 'field_second';
  static const focusEcho = 'txt_focus_echo';
  static const fieldAuto = 'field_auto';
  static const autoOptJapan = 'auto_opt_japan';
  static const autoOptJamaica = 'auto_opt_jamaica';
  static const autoOptJordan = 'auto_opt_jordan';
  static const autoEcho = 'txt_auto_echo';
  static const fieldBottom = 'field_bottom';
  static const bottomEcho = 'txt_bottom_echo';

  // FAB
  static const fabAdd = 'fab_add';
  static const fabExtended = 'fab_extended';
  static const barActionSearch = 'bar_action_search';
  static const barActionShare = 'bar_action_share';
  static const fabResult = 'txt_fab_result';
  static String rowF(int n) => 'row_f_${n.toString().padLeft(2, '0')}';
  static String rowFLabel(int n) => '行 F${n.toString().padLeft(2, '0')}';
  static const fabRowCount = 30;

  // 展開するリスト
  static const groupFruit = 'group_fruit';
  static const groupVeg = 'group_veg';
  static const groupDrink = 'group_drink';
  static const expandResult = 'txt_expand_result';
  static const fruitItems = ['りんご', 'みかん', 'ぶどう'];
  static const vegItems = ['にんじん', 'たまねぎ', 'キャベツ'];
  static const drinkItems = ['水', 'お茶', 'コーヒー'];
  static String itemFruit(int n) => 'item_fruit_$n';
  static String itemVeg(int n) => 'item_veg_$n';
  static String itemDrink(int n) => 'item_drink_$n';

  // ステッパーと進捗
  static const stepperQty = 'stepper_qty';
  static const btnQtyPlus = 'btn_qty_plus';
  static const btnQtyMinus = 'btn_qty_minus';
  static const txtQty = 'txt_qty';
  static const btnStartProgress = 'btn_start_progress';
  static const progressMain = 'progress_main';
  static const txtProgress = 'txt_progress';
  static const spinnerBusy = 'spinner_busy';

  // 無限スクロール
  static const listInfinite = 'list_infinite';
  static String rowI(int n) => 'row_i_${n.toString().padLeft(2, '0')}';
  static String rowILabel(int n) => '項目 ${n.toString().padLeft(2, '0')}';
  static const infiniteInitialCount = 20;
  static const infinitePageSize = 20;
  static const infiniteMaxCount = 100;
  static const txtLoading = 'txt_loading';
  static const infiniteCount = 'txt_infinite_count';
  static const infiniteResult = 'txt_infinite_result';

  // ピンチで拡大
  static const zoomTarget = 'zoom_target';
  static const zoomScale = 'txt_zoom_scale';
  static const btnZoomReset = 'btn_zoom_reset';

  // 固有部品
  static const btnHero = 'btn_hero';
  static const btnHeroBack = 'btn_hero_back';
  static const swCupertino = 'sw_cupertino';
  static const pickerCupertino = 'picker_cupertino';
  static const nativeLabel = 'native_label';
  static const btnPlatformViewSeen = 'btn_platform_view_seen';
  static const nativeResult = 'txt_native_result';
  static const cupertinoPickerItems = ['S', 'M', 'L'];
}

class AppInfo {
  static const version = '1.0.0';
  static const appId = 'com.ftester.e2ex.flutter';
}
