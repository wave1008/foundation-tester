package com.ftester.e2e

// testTag の唯一の正。値は docs/ui-contract.md の表と byte 一致させる。
// シナリオ側(Projects/E2E/Scenarios)が "#<値>" で参照するため、リネームは契約変更。
object Tags {
    // シェル
    const val SCREEN_TITLE = "txt_screen_title"
    const val BACK = "btn_back"
    const val TAB_HOME = "tab_home"
    const val TAB_CONTROLS = "tab_controls"
    const val TAB_ABOUT = "tab_about"

    // ホーム
    const val HOME_MARKER = "txt_home_marker"
    const val NAV_SELECTOR = "nav_selector"
    const val NAV_INPUT = "nav_input"
    const val NAV_GESTURE = "nav_gesture"
    const val NAV_SCROLL = "nav_scroll"
    const val NAV_ASYNC = "nav_async"
    const val NAV_DIALOG = "nav_dialog"
    const val NAV_LIFECYCLE = "nav_lifecycle"
    const val NAV_HEAL = "nav_heal"
    const val NAV_DIAGNOSTICS = "nav_diagnostics"

    // セレクタ
    const val SELECTOR_RESULT = "txt_selector_result"
    const val BTN_ALLOW = "btn_allow"
    const val BTN_ALLOW_NOTIFICATION = "btn_allow_notification"
    const val BTN_ITEM_1 = "btn_item_1"
    const val BTN_ITEM_2 = "btn_item_2"
    const val BTN_ITEM_3 = "btn_item_3"
    const val TXT_SHARED_LABEL = "txt_shared_label"
    const val BTN_SHARED_LABEL = "btn_shared_label"
    const val BTN_ALIAS_NEW = "btn_alias_new"
    const val BTN_SELECTOR_RESET = "btn_selector_reset"
    const val TXT_OFFSCREEN = "txt_offscreen"

    // テキスト入力
    const val FIELD_SINGLE = "field_single"
    const val FIELD_PASSWORD = "field_password"
    const val FIELD_MULTILINE = "field_multiline"
    const val ECHO_SINGLE = "txt_echo_single"
    const val ECHO_PASSWORD = "txt_echo_password"
    const val ECHO_MULTILINE = "txt_echo_multiline"
    const val ECHO_LENGTH = "txt_echo_length"
    const val BTN_INPUT_SUBMIT = "btn_input_submit"
    const val TXT_INPUT_SUBMITTED = "txt_input_submitted"
    const val BTN_INPUT_CLEAR = "btn_input_clear"

    // ジェスチャ
    const val BTN_TAP_COUNTER = "btn_tap_counter"
    const val TXT_TAP_COUNT = "txt_tap_count"
    const val BTN_LONG_PRESS = "btn_long_press"
    const val TXT_PRESS_COUNT = "txt_press_count"
    const val PAD_SWIPE = "pad_swipe"
    const val TXT_SWIPE_DIR = "txt_swipe_dir"
    const val TXT_LAST_GESTURE = "txt_last_gesture"
    const val BTN_GESTURE_RESET = "btn_gesture_reset"

    // スクロール
    const val TXT_ROW_SELECTED = "txt_row_selected"
    const val BTN_SCROLL_TOP = "btn_scroll_top"

    /** 行 tag。n は 1..ROW_COUNT。ゼロ詰め("row_01")= ラベルの部分一致衝突回避と対。 */
    fun row(n: Int): String = "row_" + n.toString().padStart(2, '0')

    /** 行ラベル("行 01")。 */
    fun rowLabel(n: Int): String = "行 " + n.toString().padStart(2, '0')

    const val ROW_COUNT = 40

    // 非同期表示
    const val TXT_DELAY_STATE = "txt_delay_state"
    const val BTN_DELAY_1 = "btn_delay_1"
    const val BTN_DELAY_3 = "btn_delay_3"
    const val BTN_DELAY_8 = "btn_delay_8"
    const val TXT_DELAYED = "txt_delayed"
    const val TXT_COUNTDOWN = "txt_countdown"
    const val BTN_ASYNC_RESET = "btn_async_reset"

    // ダイアログ
    const val TXT_DIALOG_RESULT = "txt_dialog_result"
    const val BTN_SHOW_DIALOG = "btn_show_dialog"
    const val BTN_MAYBE_DIALOG = "btn_maybe_dialog"
    const val TXT_DIALOG_TITLE = "txt_dialog_title"
    const val BTN_DIALOG_OK = "btn_dialog_ok"
    const val BTN_DIALOG_CANCEL = "btn_dialog_cancel"
    const val SW_AUTO_DIALOG = "sw_auto_dialog"
    const val TXT_AUTO_DIALOG = "txt_auto_dialog"

    // コントロール
    const val SW_NOTIFY = "sw_notify"
    const val TXT_SW_NOTIFY = "txt_sw_notify"
    const val CB_AGREE = "cb_agree"
    const val TXT_CB_AGREE = "txt_cb_agree"
    const val RADIO_A = "radio_a"
    const val RADIO_B = "radio_b"
    const val RADIO_C = "radio_c"
    const val TXT_RADIO = "txt_radio"
    const val SLIDER_VOLUME = "slider_volume"
    const val TXT_SLIDER = "txt_slider"
    const val BTN_CONTROLS_RESET = "btn_controls_reset"

    // ライフサイクル
    const val TXT_LAUNCH_COUNT = "txt_launch_count"
    const val TXT_SESSION_COUNT = "txt_session_count"
    const val BTN_SESSION_INC = "btn_session_inc"
    const val BTN_RESET_PERSISTED = "btn_reset_persisted"
    const val TXT_PLATFORM = "txt_platform"

    // 自己修復。ラベルは不変で id だけ入れ替わる(schema トグル)のが検証の核。
    const val SW_HEAL_SCHEMA = "sw_heal_schema"
    const val TXT_HEAL_SCHEMA = "txt_heal_schema"
    const val BTN_HEAL_V1 = "btn_heal_v1"
    const val BTN_HEAL_V2 = "btn_heal_v2"
    const val TXT_HEAL_RESULT = "txt_heal_result"
    const val BTN_HEAL_RESET = "btn_heal_reset"

    // 診断
    const val TXT_BUILD_INFO = "txt_build_info"
    const val TXT_DIAG_NOTE = "txt_diag_note"
    const val BTN_FREEZE_3S = "btn_freeze_3s"
    const val BTN_CRASH = "btn_crash"
    const val BTN_CRASH_CONFIRM = "btn_crash_confirm"
    const val BTN_CRASH_CANCEL = "btn_crash_cancel"

    // 情報
    const val TXT_ABOUT_MARKER = "txt_about_marker"
    const val TXT_ABOUT_APP = "txt_about_app"
    const val TXT_ABOUT_VERSION = "txt_about_version"
}

object AppInfo {
    const val VERSION = "1.0.0"
    const val APP_ID = "com.ftester.e2e"
}
