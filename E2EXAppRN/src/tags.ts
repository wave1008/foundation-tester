// #id の唯一の正は E2EXAppCMP/docs/ui-contract.md。値はその表と byte 一致させる。
// RN の testID は iOS = accessibilityIdentifier / Android = resource-id に自動でマップされる。

export const Tags = {
  // シェル
  screenTitle: 'txt_screen_title',
  back: 'btn_back',

  // ホーム
  navPager: 'nav_pager',
  navSheet: 'nav_sheet',
  navMenu: 'nav_menu',
  navDate: 'nav_date',
  navDrawer: 'nav_drawer',
  navRefresh: 'nav_refresh',
  navSnackbar: 'nav_snackbar',
  navGrid: 'nav_grid',
  navSwipe: 'nav_swipe',
  navTabs: 'nav_tabs',
  navAnim: 'nav_anim',
  navTooltip: 'nav_tooltip',
  navChips: 'nav_chips',
  navSearch: 'nav_search',
  navDetail: 'nav_detail',

  // ページャ
  pagerMain: 'pager_main',
  txtPagerState: 'txt_pager_state',
  txtPagerResult: 'txt_pager_result',
  btnPagerNext: 'btn_pager_next',
  txtPage: (n: number) => `txt_page_${n}`,
  btnPage: (n: number) => `btn_page_${n}`,

  // ボトムシート
  btnOpenSheet: 'btn_open_sheet',
  txtSheetTitle: 'txt_sheet_title',
  txtSheetResult: 'txt_sheet_result',
  btnSheetOpt: (n: number) => `btn_sheet_opt_${n}`,
  rowSheet: (n: number) => `row_sheet_${String(n).padStart(2, '0')}`,

  // メニュー
  btnOpenMenu: 'btn_open_menu',
  menuItemCopy: 'menu_item_copy',
  menuItemShare: 'menu_item_share',
  menuItemDelete: 'menu_item_delete',
  txtMenuResult: 'txt_menu_result',
  fieldFruit: 'field_fruit',
  optFruitApple: 'opt_fruit_apple',
  optFruitBanana: 'opt_fruit_banana',
  optFruitCherry: 'opt_fruit_cherry',
  txtFruitResult: 'txt_fruit_result',

  // 日付ピッカー
  btnOpenDate: 'btn_open_date',
  btnDateOk: 'btn_date_ok',
  btnDateCancel: 'btn_date_cancel',
  txtDateResult: 'txt_date_result',

  // ドロワー
  btnOpenDrawer: 'btn_open_drawer',
  txtDrawerHeader: 'txt_drawer_header',
  drawerItemInbox: 'drawer_item_inbox',
  drawerItemSent: 'drawer_item_sent',
  drawerItemTrash: 'drawer_item_trash',
  txtDrawerResult: 'txt_drawer_result',
  txtDrawerState: 'txt_drawer_state',

  // 引っ張って更新
  boxRefresh: 'box_refresh',
  txtRefreshCount: 'txt_refresh_count',
  rowRefresh: (n: number) => `row_refresh_${String(n).padStart(2, '0')}`,

  // スナックバー
  btnShowSnackbar: 'btn_show_snackbar',
  btnShowSnackbarShort: 'btn_show_snackbar_short',
  txtSnackbarResult: 'txt_snackbar_result',

  // グリッド
  gridMain: 'grid_main',
  txtGridResult: 'txt_grid_result',
  cell: (n: number) => `cell_${String(n).padStart(2, '0')}`,

  // スワイプで削除
  txtSwipeResult: 'txt_swipe_result',
  txtSwipeCount: 'txt_swipe_count',
  swipeRow: (n: number) => `swipe_row_${n}`,

  // タブ
  tabA: 'tab_a',
  tabB: 'tab_b',
  tabC: 'tab_c',
  txtTabContent: 'txt_tab_content',
  stabRow: 'stab_row',
  txtStabContent: 'txt_stab_content',
  stab: (n: number) => `stab_${String(n).padStart(2, '0')}`,
  navbarHome: 'navbar_home',
  navbarSearch: 'navbar_search',
  navbarSettings: 'navbar_settings',
  txtNavbarResult: 'txt_navbar_result',

  // アニメーション
  btnToggleAnim: 'btn_toggle_anim',
  txtAnimTarget: 'txt_anim_target',
  txtAnimVisible: 'txt_anim_visible',
  btnAnimInc: 'btn_anim_inc',
  txtAnimCount: 'txt_anim_count',

  // ツールチップ
  btnTooltipAnchor: 'btn_tooltip_anchor',
  txtTooltip: 'txt_tooltip',
  txtTooltipState: 'txt_tooltip_state',

  // チップと分割ボタン
  chipWifi: 'chip_wifi',
  txtChipResult: 'txt_chip_result',
  chipAssist: 'chip_assist',
  txtAssistResult: 'txt_assist_result',
  segDay: 'seg_day',
  segWeek: 'seg_week',
  segMonth: 'seg_month',
  txtSegResult: 'txt_seg_result',
  rangeSlider: 'range_slider',
  rangeSliderMin: 'range_slider_min',
  rangeSliderMax: 'range_slider_max',
  txtRangeResult: 'txt_range_result',

  // 検索バー
  fieldSearch: 'field_search',
  suggestionApple: 'suggestion_apple',
  suggestionApricot: 'suggestion_apricot',
  suggestionBanana: 'suggestion_banana',
  txtSearchResult: 'txt_search_result',

  // 引数付き遷移
  detailLink: (n: number) => `detail_link_${n}`,
  txtDetailId: 'txt_detail_id',
  btnDetailNext: 'btn_detail_next',

  // 第2弾: 伸縮するヘッダ
  navCollapse: 'nav_collapse',
  txtCollapseHeader: 'txt_collapse_header',
  txtCollapseResult: 'txt_collapse_result',
  rowC: (n: number) => `row_c_${String(n).padStart(2, '0')}`,

  // 第2弾: 貼り付く見出し
  navSticky: 'nav_sticky',
  hdr: (letter: string) => `hdr_${letter}`,
  rowS: (letter: string, n: number) => `row_s_${letter}${n}`,
  txtStickyResult: 'txt_sticky_result',

  // 第2弾: 時刻ピッカー
  navTime: 'nav_time',
  btnOpenTime: 'btn_open_time',
  btnTimeOk: 'btn_time_ok',
  btnTimeCancel: 'btn_time_cancel',
  txtTimeResult: 'txt_time_result',

  // 第2弾: ダイアログ
  navDialogs: 'nav_dialogs',
  btnAlert: 'btn_alert',
  btnPrompt: 'btn_prompt',
  fieldPrompt: 'field_prompt',
  btnActionSheet: 'btn_action_sheet',
  btnFullscreen: 'btn_fullscreen',
  txtFullscreenTitle: 'txt_fullscreen_title',
  btnFullscreenSave: 'btn_fullscreen_save',
  btnFullscreenClose: 'btn_fullscreen_close',
  btnToast: 'btn_toast',
  txtDialogsResult: 'txt_dialogs_result',

  // 第2弾: 長押しメニュー
  navContext: 'nav_context',
  ctxRow: (n: number) => `ctx_row_${n}`,
  txtContextResult: 'txt_context_result',

  // 第2弾: 並べ替え
  navReorder: 'nav_reorder',
  reorderRow: (n: number) => `reorder_row_${n}`,
  txtReorderResult: 'txt_reorder_result',

  // 第2弾: 入力の種類
  navInputs: 'nav_inputs',
  fieldNumber: 'field_number',
  txtNumberEcho: 'txt_number_echo',
  fieldPassword: 'field_password',
  txtPasswordEcho: 'txt_password_echo',
  fieldMultiline: 'field_multiline',
  txtMultilineEcho: 'txt_multiline_echo',
  fieldFirst: 'field_first',
  fieldSecond: 'field_second',
  txtFocusEcho: 'txt_focus_echo',
  fieldAuto: 'field_auto',
  autoOpt: (key: string) => `auto_opt_${key}`,
  txtAutoEcho: 'txt_auto_echo',
  fieldBottom: 'field_bottom',
  txtBottomEcho: 'txt_bottom_echo',

  // 第2弾: FAB
  navFab: 'nav_fab',
  fabAdd: 'fab_add',
  fabExtended: 'fab_extended',
  barActionSearch: 'bar_action_search',
  barActionShare: 'bar_action_share',
  txtFabResult: 'txt_fab_result',
  rowF: (n: number) => `row_f_${String(n).padStart(2, '0')}`,

  // 第2弾: 展開するリスト
  navExpand: 'nav_expand',
  groupFruit: 'group_fruit',
  groupVeg: 'group_veg',
  groupDrink: 'group_drink',
  itemFruit: (n: number) => `item_fruit_${n}`,
  itemVeg: (n: number) => `item_veg_${n}`,
  itemDrink: (n: number) => `item_drink_${n}`,
  txtExpandResult: 'txt_expand_result',

  // 第2弾: ステッパーと進捗
  navStepper: 'nav_stepper',
  stepperQty: 'stepper_qty',
  btnQtyPlus: 'btn_qty_plus',
  btnQtyMinus: 'btn_qty_minus',
  txtQty: 'txt_qty',
  btnStartProgress: 'btn_start_progress',
  progressMain: 'progress_main',
  txtProgress: 'txt_progress',
  spinnerBusy: 'spinner_busy',

  // 第2弾: 無限スクロール
  navInfinite: 'nav_infinite',
  listInfinite: 'list_infinite',
  rowI: (n: number) => `row_i_${String(n).padStart(2, '0')}`,
  txtLoading: 'txt_loading',
  txtInfiniteCount: 'txt_infinite_count',
  txtInfiniteResult: 'txt_infinite_result',

  // 第2弾: ピンチで拡大
  navZoom: 'nav_zoom',
  zoomTarget: 'zoom_target',
  txtZoomScale: 'txt_zoom_scale',
  btnZoomReset: 'btn_zoom_reset',

  // 第2弾: 固有部品
  navNative: 'nav_native',
  txtNativeResult: 'txt_native_result',
  flashRow: (n: number) => `flash_row_${String(n).padStart(2, '0')}`,
  btnModalOpen: 'btn_modal_open',
  btnModalOk: 'btn_modal_ok',
  swCore: 'sw_core',
} as const;
