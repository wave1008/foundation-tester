// testID の唯一の正は E2EAppCMP/docs/ui-contract.md。値はその表と byte 一致させる。
// RN の testID は iOS = accessibilityIdentifier / Android = resource-id に自動でマップされる
// (他 3 SUT の identifier/testTag と同じ機構)ため、両 OS で同じ #id が引ける。

export const Tags = {
  // シェル
  screenTitle: 'txt_screen_title',
  back: 'btn_back',
  tabHome: 'tab_home',
  tabControls: 'tab_controls',
  tabAbout: 'tab_about',

  // ホーム
  homeMarker: 'txt_home_marker',
  navSelector: 'nav_selector',
  navInput: 'nav_input',
  navGesture: 'nav_gesture',
  navMap: 'nav_map',
  navScroll: 'nav_scroll',
  navAsync: 'nav_async',
  navDialog: 'nav_dialog',
  navLifecycle: 'nav_lifecycle',
  navHeal: 'nav_heal',
  navDiagnostics: 'nav_diagnostics',
  navWebview: 'nav_webview',
  navNoid: 'nav_noid',

  // セレクタ
  selectorResult: 'txt_selector_result',
  btnAllow: 'btn_allow',
  btnAllowNotification: 'btn_allow_notification',
  btnItem1: 'btn_item_1',
  btnItem2: 'btn_item_2',
  btnItem3: 'btn_item_3',
  txtSharedLabel: 'txt_shared_label',
  btnSharedLabel: 'btn_shared_label',
  btnAliasNew: 'btn_alias_new',
  btnSelectorReset: 'btn_selector_reset',
  txtOffscreen: 'txt_offscreen',

  // テキスト入力
  fieldSingle: 'field_single',
  fieldPassword: 'field_password',
  fieldMultiline: 'field_multiline',
  echoSingle: 'txt_echo_single',
  echoPassword: 'txt_echo_password',
  echoMultiline: 'txt_echo_multiline',
  echoLength: 'txt_echo_length',
  imeAction: 'txt_ime_action',
  btnInputSubmit: 'btn_input_submit',
  txtInputSubmitted: 'txt_input_submitted',
  btnInputClear: 'btn_input_clear',

  // ジェスチャ
  btnTapCounter: 'btn_tap_counter',
  txtTapCount: 'txt_tap_count',
  btnLongPress: 'btn_long_press',
  txtPressCount: 'txt_press_count',
  padSwipe: 'pad_swipe',
  txtSwipeDir: 'txt_swipe_dir',
  txtLastGesture: 'txt_last_gesture',
  btnGestureReset: 'btn_gesture_reset',

  // マップ(ピンチ・ダブルタップ・斜めドラッグ)
  padMap: 'pad_map',
  txtZoomDir: 'txt_zoom_dir',
  txtZoom: 'txt_zoom',
  txtPan: 'txt_pan',
  txtDoubleCount: 'txt_double_count',
  btnMapReset: 'btn_map_reset',

  // スクロール
  txtRowSelected: 'txt_row_selected',
  btnScrollTop: 'btn_scroll_top',
  listRows: 'list_rows',
  txtTagSelected: 'txt_tag_selected',
  carouselTags: 'carousel_tags',

  // 非同期表示
  txtDelayState: 'txt_delay_state',
  btnDelay1: 'btn_delay_1',
  btnDelay3: 'btn_delay_3',
  btnDelay8: 'btn_delay_8',
  txtDelayed: 'txt_delayed',
  txtCountdown: 'txt_countdown',
  btnAsyncReset: 'btn_async_reset',

  // ダイアログ
  txtDialogResult: 'txt_dialog_result',
  btnShowDialog: 'btn_show_dialog',
  btnMaybeDialog: 'btn_maybe_dialog',
  txtDialogTitle: 'txt_dialog_title',
  btnDialogOk: 'btn_dialog_ok',
  btnDialogCancel: 'btn_dialog_cancel',
  swAutoDialog: 'sw_auto_dialog',
  txtAutoDialog: 'txt_auto_dialog',

  // コントロール
  swNotify: 'sw_notify',
  txtSwNotify: 'txt_sw_notify',
  cbAgree: 'cb_agree',
  txtCbAgree: 'txt_cb_agree',
  radioA: 'radio_a',
  radioB: 'radio_b',
  radioC: 'radio_c',
  txtRadio: 'txt_radio',
  sliderVolume: 'slider_volume',
  txtSlider: 'txt_slider',
  btnAlwaysDisabled: 'btn_always_disabled',
  btnToggleTarget: 'btn_toggle_target',
  btnControlsReset: 'btn_controls_reset',

  // ライフサイクル
  txtLaunchCount: 'txt_launch_count',
  txtSessionCount: 'txt_session_count',
  btnSessionInc: 'btn_session_inc',
  btnResetPersisted: 'btn_reset_persisted',
  txtPlatform: 'txt_platform',

  // 自己修復。ラベルは不変で id だけ入れ替わる(schema トグル)のが検証の核。
  swHealSchema: 'sw_heal_schema',
  txtHealSchema: 'txt_heal_schema',
  btnHealV1: 'btn_heal_v1',
  btnHealV2: 'btn_heal_v2',
  txtHealResult: 'txt_heal_result',
  btnHealReset: 'btn_heal_reset',

  // 診断。「飛び越し画面」は CMP 専用のため #btn_open_jump は作らない。
  txtBuildInfo: 'txt_build_info',
  txtDiagNote: 'txt_diag_note',
  btnFreeze3s: 'btn_freeze_3s',
  btnCrash: 'btn_crash',
  btnCrashConfirm: 'btn_crash_confirm',
  btnCrashCancel: 'btn_crash_cancel',

  // 情報
  txtAboutMarker: 'txt_about_marker',
  txtAboutApp: 'txt_about_app',
  txtAboutVersion: 'txt_about_version',
} as const;

/** 行 tag。n は 1..rowCount。ゼロ詰め("row_01")= ラベルの部分一致衝突回避と対。 */
export const row = (n: number): string => `row_${String(n).padStart(2, '0')}`;
export const rowLabel = (n: number): string => `行 ${String(n).padStart(2, '0')}`;
export const rowCount = 40;

/** 横スクロールの検証材料(scrollFrame。縦と横が同居していないと「指定した方だけ動く」を確かめられない) */
export const tag = (n: number): string => `tag_${String(n).padStart(2, '0')}`;
export const tagLabel = (n: number): string => `タグ ${String(n).padStart(2, '0')}`;
export const tagCount = 20;

export const APP_VERSION = '1.0.0';

export const AppInfo = {
  version: APP_VERSION,
  appId: 'com.ftester.e2e.rn',
} as const;
