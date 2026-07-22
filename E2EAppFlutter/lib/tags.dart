// Semantics identifier の唯一の正。値は E2EApp/docs/ui-contract.md の表と byte 一致させる。
// シナリオ側(Projects/E2E-Flutter/Scenarios)が "#<値>" で参照するため、リネームは契約変更。
// Flutter の `Semantics(identifier:)` は iOS = accessibilityIdentifier / Android = resource-id
// にマップされるため、両 OS で同じ #id が引ける。
class Tags {
  // シェル
  static const screenTitle = 'txt_screen_title';
  static const back = 'btn_back';
  static const tabHome = 'tab_home';
  static const tabControls = 'tab_controls';
  static const tabAbout = 'tab_about';

  // ホーム
  static const homeMarker = 'txt_home_marker';
  static const navSelector = 'nav_selector';
  static const navInput = 'nav_input';
  static const navGesture = 'nav_gesture';
  static const navScroll = 'nav_scroll';
  static const navAsync = 'nav_async';
  static const navDialog = 'nav_dialog';
  static const navLifecycle = 'nav_lifecycle';
  static const navHeal = 'nav_heal';
  static const navDiagnostics = 'nav_diagnostics';

  // セレクタ
  static const selectorResult = 'txt_selector_result';
  static const btnAllow = 'btn_allow';
  static const btnAllowNotification = 'btn_allow_notification';
  static const btnItem1 = 'btn_item_1';
  static const btnItem2 = 'btn_item_2';
  static const btnItem3 = 'btn_item_3';
  static const txtSharedLabel = 'txt_shared_label';
  static const btnSharedLabel = 'btn_shared_label';
  static const btnAliasNew = 'btn_alias_new';
  static const btnSelectorReset = 'btn_selector_reset';
  static const txtOffscreen = 'txt_offscreen';

  // テキスト入力
  static const fieldSingle = 'field_single';
  static const fieldPassword = 'field_password';
  static const fieldMultiline = 'field_multiline';
  static const echoSingle = 'txt_echo_single';
  static const echoPassword = 'txt_echo_password';
  static const echoMultiline = 'txt_echo_multiline';
  static const echoLength = 'txt_echo_length';
  static const btnInputSubmit = 'btn_input_submit';
  static const txtInputSubmitted = 'txt_input_submitted';
  static const btnInputClear = 'btn_input_clear';

  // ジェスチャ
  static const btnTapCounter = 'btn_tap_counter';
  static const txtTapCount = 'txt_tap_count';
  static const btnLongPress = 'btn_long_press';
  static const txtPressCount = 'txt_press_count';
  static const padSwipe = 'pad_swipe';
  static const txtSwipeDir = 'txt_swipe_dir';
  static const txtLastGesture = 'txt_last_gesture';
  static const btnGestureReset = 'btn_gesture_reset';

  // スクロール
  static const txtRowSelected = 'txt_row_selected';
  static const btnScrollTop = 'btn_scroll_top';
  static const rowCount = 40;

  /// 行 tag。n は 1..rowCount。ゼロ詰め("row_01")= ラベルの部分一致衝突回避と対。
  static String row(int n) => 'row_${n.toString().padLeft(2, '0')}';

  /// 行ラベル("行 01")。
  static String rowLabel(int n) => '行 ${n.toString().padLeft(2, '0')}';

  // 非同期表示
  static const txtDelayState = 'txt_delay_state';
  static const btnDelay1 = 'btn_delay_1';
  static const btnDelay3 = 'btn_delay_3';
  static const btnDelay8 = 'btn_delay_8';
  static const txtDelayed = 'txt_delayed';
  static const txtCountdown = 'txt_countdown';
  static const btnAsyncReset = 'btn_async_reset';

  // ダイアログ
  static const txtDialogResult = 'txt_dialog_result';
  static const btnShowDialog = 'btn_show_dialog';
  static const btnMaybeDialog = 'btn_maybe_dialog';
  static const txtDialogTitle = 'txt_dialog_title';
  static const btnDialogOk = 'btn_dialog_ok';
  static const btnDialogCancel = 'btn_dialog_cancel';
  static const swAutoDialog = 'sw_auto_dialog';
  static const txtAutoDialog = 'txt_auto_dialog';

  // コントロール
  static const swNotify = 'sw_notify';
  static const txtSwNotify = 'txt_sw_notify';
  static const cbAgree = 'cb_agree';
  static const txtCbAgree = 'txt_cb_agree';
  static const radioA = 'radio_a';
  static const radioB = 'radio_b';
  static const radioC = 'radio_c';
  static const txtRadio = 'txt_radio';
  static const sliderVolume = 'slider_volume';
  static const txtSlider = 'txt_slider';
  static const btnControlsReset = 'btn_controls_reset';

  // ライフサイクル
  static const txtLaunchCount = 'txt_launch_count';
  static const txtSessionCount = 'txt_session_count';
  static const btnSessionInc = 'btn_session_inc';
  static const btnResetPersisted = 'btn_reset_persisted';
  static const txtPlatform = 'txt_platform';

  // 自己修復。ラベルは不変で id だけ入れ替わる(schema トグル)のが検証の核。
  static const swHealSchema = 'sw_heal_schema';
  static const txtHealSchema = 'txt_heal_schema';
  static const btnHealV1 = 'btn_heal_v1';
  static const btnHealV2 = 'btn_heal_v2';
  static const txtHealResult = 'txt_heal_result';
  static const btnHealReset = 'btn_heal_reset';

  // 診断
  static const txtBuildInfo = 'txt_build_info';
  static const txtDiagNote = 'txt_diag_note';
  static const btnFreeze3s = 'btn_freeze_3s';
  static const btnCrash = 'btn_crash';
  static const btnCrashConfirm = 'btn_crash_confirm';
  static const btnCrashCancel = 'btn_crash_cancel';

  // 情報
  static const txtAboutMarker = 'txt_about_marker';
  static const txtAboutApp = 'txt_about_app';
  static const txtAboutVersion = 'txt_about_version';
}

class AppInfo {
  static const version = '1.0.0';
  static const appId = 'com.ftester.e2e.flutter';
}
