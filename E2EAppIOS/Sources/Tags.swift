import Foundation

// accessibilityIdentifier の唯一の正。値は docs/ui-contract.md の表と byte 一致させる。
// シナリオ側(Projects/E2E-iOS/Scenarios)が "#<値>" で参照するため、リネームは契約変更。
// Compose 版(E2EApp/composeApp/.../Tags.kt)と id/ラベルを共通にしてあり、
// 同じシナリオを両 SUT に当てられる(型セレクタだけが SUT ごとに異なる)。
enum Tags {
    // シェル
    static let screenTitle = "txt_screen_title"
    static let back = "btn_back"
    static let tabHome = "tab_home"
    static let tabControls = "tab_controls"
    static let tabAbout = "tab_about"

    // ホーム
    static let homeMarker = "txt_home_marker"
    static let navSelector = "nav_selector"
    static let navInput = "nav_input"
    static let navGesture = "nav_gesture"
    static let navScroll = "nav_scroll"
    static let navAsync = "nav_async"
    static let navDialog = "nav_dialog"
    static let navLifecycle = "nav_lifecycle"
    static let navHeal = "nav_heal"
    static let navDiagnostics = "nav_diagnostics"

    // セレクタ
    static let selectorResult = "txt_selector_result"
    static let btnAllow = "btn_allow"
    static let btnAllowNotification = "btn_allow_notification"
    static let btnItem1 = "btn_item_1"
    static let btnItem2 = "btn_item_2"
    static let btnItem3 = "btn_item_3"
    static let txtSharedLabel = "txt_shared_label"
    static let btnSharedLabel = "btn_shared_label"
    static let btnAliasNew = "btn_alias_new"
    static let btnSelectorReset = "btn_selector_reset"
    static let txtOffscreen = "txt_offscreen"

    // テキスト入力
    static let fieldSingle = "field_single"
    static let fieldPassword = "field_password"
    static let fieldMultiline = "field_multiline"
    static let echoSingle = "txt_echo_single"
    static let echoPassword = "txt_echo_password"
    static let echoMultiline = "txt_echo_multiline"
    static let echoLength = "txt_echo_length"
    static let btnInputSubmit = "btn_input_submit"
    static let txtInputSubmitted = "txt_input_submitted"
    static let btnInputClear = "btn_input_clear"

    // ジェスチャ
    static let btnTapCounter = "btn_tap_counter"
    static let txtTapCount = "txt_tap_count"
    static let btnLongPress = "btn_long_press"
    static let txtPressCount = "txt_press_count"
    static let padSwipe = "pad_swipe"
    static let txtSwipeDir = "txt_swipe_dir"
    static let txtLastGesture = "txt_last_gesture"
    static let btnGestureReset = "btn_gesture_reset"

    // スクロール
    static let txtRowSelected = "txt_row_selected"
    static let btnScrollTop = "btn_scroll_top"

    static let rowCount = 40

    /// 行 tag。n は 1...rowCount。ゼロ詰め("row_01")= ラベルの部分一致衝突回避と対。
    static func row(_ n: Int) -> String { String(format: "row_%02d", n) }

    /// 行ラベル("行 01")。
    static func rowLabel(_ n: Int) -> String { String(format: "行 %02d", n) }

    // 非同期表示
    static let txtDelayState = "txt_delay_state"
    static let btnDelay1 = "btn_delay_1"
    static let btnDelay3 = "btn_delay_3"
    static let btnDelay8 = "btn_delay_8"
    static let txtDelayed = "txt_delayed"
    static let txtCountdown = "txt_countdown"
    static let btnAsyncReset = "btn_async_reset"

    // ダイアログ
    static let txtDialogResult = "txt_dialog_result"
    static let btnShowDialog = "btn_show_dialog"
    static let btnMaybeDialog = "btn_maybe_dialog"
    static let txtDialogTitle = "txt_dialog_title"
    static let btnDialogOK = "btn_dialog_ok"
    static let btnDialogCancel = "btn_dialog_cancel"
    static let swAutoDialog = "sw_auto_dialog"
    static let txtAutoDialog = "txt_auto_dialog"

    // コントロール
    static let swNotify = "sw_notify"
    static let txtSwNotify = "txt_sw_notify"
    static let cbAgree = "cb_agree"
    static let txtCbAgree = "txt_cb_agree"
    static let radioA = "radio_a"
    static let radioB = "radio_b"
    static let radioC = "radio_c"
    static let txtRadio = "txt_radio"
    static let sliderVolume = "slider_volume"
    static let txtSlider = "txt_slider"
    static let btnControlsReset = "btn_controls_reset"

    // ライフサイクル
    static let txtLaunchCount = "txt_launch_count"
    static let txtSessionCount = "txt_session_count"
    static let btnSessionInc = "btn_session_inc"
    static let btnResetPersisted = "btn_reset_persisted"
    static let txtPlatform = "txt_platform"

    // 自己修復。ラベルは不変で id だけ入れ替わる(schema トグル)のが検証の核。
    static let swHealSchema = "sw_heal_schema"
    static let txtHealSchema = "txt_heal_schema"
    static let btnHealV1 = "btn_heal_v1"
    static let btnHealV2 = "btn_heal_v2"
    static let txtHealResult = "txt_heal_result"
    static let btnHealReset = "btn_heal_reset"

    // 診断
    static let txtBuildInfo = "txt_build_info"
    static let txtDiagNote = "txt_diag_note"
    static let btnFreeze3s = "btn_freeze_3s"
    static let btnCrash = "btn_crash"
    static let btnCrashConfirm = "btn_crash_confirm"
    static let btnCrashCancel = "btn_crash_cancel"

    // 情報
    static let txtAboutMarker = "txt_about_marker"
    static let txtAboutApp = "txt_about_app"
    static let txtAboutVersion = "txt_about_version"
}

enum AppInfo {
    static let version = "1.0.0"
    static let appID = "com.ftester.e2e.ios"
}
