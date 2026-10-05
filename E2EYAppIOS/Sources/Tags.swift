import Foundation

/// accessibilityIdentifier の唯一の正。値は E2EYAppCMP/docs/ui-contract.md と byte 一致させる。
enum Tags {
    static let screenTitle = "txt_screen_title"
    static let btnBack = "btn_back"

    // ホーム
    static let navNested = "nav_nested"
    static let navChat = "nav_chat"
    static let navLoading = "nav_loading"
    static let navSwipeActions = "nav_swipe_actions"
    static let navSelect = "nav_select"
    static let navLinks = "nav_links"
    static let navPin = "nav_pin"
    static let navBackGuard = "nav_back_guard"
    static let navPlayer = "nav_player"
    static let navHideBars = "nav_hide_bars"
    static let navTabHeader = "nav_tab_header"
    static let navStaggered = "nav_staggered"

    static func two(_ n: Int) -> String { String(format: "%02d", n) }
}
