import XCTest
@testable import FTAndroid

/// `dumpsys window windows` から「アプリより手前の別 window」を拾う規則。
/// 入力は実機(Pixel 9 / Android 15)の実出力を要点だけ残したもの。
final class ForegroundWindowsTests: XCTestCase {

    private let package = "com.ftester.e2e"

    /// name と可視性だけを持つ最小のブロックを組み立てる(実出力と同じ字面・字下げ)
    private func dump(_ windows: [(String, Bool)]) -> String {
        windows.enumerated().map { index, entry in
            """
              Window #\(index) Window{abc\(index) u0 \(entry.0)}:
                mViewVisibility=0x0 mHaveFrame=true mObscured=false
                isVisible=\(entry.1)
            """
        }.joined(separator: "\n")
    }

    func testReportsNothingWhenOnlyChromeIsInFront() {
        let text = dump([
            ("ScreenDecorOverlay", false), ("Taskbar", true), ("NotificationShade", false),
            ("StatusBar", true), ("InputMethod", false),
            ("\(package)/\(package).MainActivity", true),
        ])
        XCTAssertEqual(AndroidForegroundWindows.overlaying(package: package, dumpsys: text), [])
    }

    func testReportsVisibleForeignWindowAboveTheApp() {
        let text = dump([
            ("Taskbar", true), ("NotificationShade", true), ("StatusBar", true),
            ("\(package)/\(package).MainActivity", true),
        ])
        XCTAssertEqual(AndroidForegroundWindows.overlaying(package: package, dumpsys: text),
                       ["NotificationShade"])
    }

    /// 実害の形: IME(Gboard)の案内シートがアプリの上に出る
    func testReportsImeDialogInZOrder() {
        let ime = "com.google.android.inputmethod.latin/…StylusOnboardingActivity"
        let text = dump([
            ("StatusBar", true), (ime, true), ("InputMethod", true),
            ("\(package)/\(package).MainActivity", true),
        ])
        XCTAssertEqual(AndroidForegroundWindows.overlaying(package: package, dumpsys: text),
                       [ime, "InputMethod"])
    }

    func testIgnoresWindowsBehindTheAppAndOtherAppsThatAreHidden() {
        let text = dump([
            ("StatusBar", true),
            ("\(package)/\(package).MainActivity", true),
            ("com.other.app/com.other.app.MainActivity", true),   // 背面(z 順が下)
            ("com.hidden.app/com.hidden.app.MainActivity", false),
        ])
        XCTAssertEqual(AndroidForegroundWindows.overlaying(package: package, dumpsys: text), [])
    }

    /// アプリの window が見つからない(別アプリが前面・取得失敗)ときは黙る
    func testReturnsEmptyWhenAppWindowIsAbsent() {
        let text = dump([("StatusBar", true), ("com.other.app/com.other.app.MainActivity", true)])
        XCTAssertEqual(AndroidForegroundWindows.overlaying(package: package, dumpsys: text), [])
    }

    /// アプリ自身の別 window(ダイアログ等)は「別プロセス」ではないので報告しない
    func testIgnoresAppsOwnAdditionalWindow() {
        let text = dump([
            ("\(package)/\(package).DialogActivity", true),
            ("\(package)/\(package).MainActivity", true),
        ])
        XCTAssertEqual(AndroidForegroundWindows.overlaying(package: package, dumpsys: text), [])
    }

    /// Android 15 の実出力形: mCurrentFocus 行は無く、可視のアプリ窓は前面の1つだけ
    /// (背面アプリ・ランチャーは isVisible=false)。E2E で appIs が必ずタイムアウトした退行の再発防止
    func testTopmostAppPackageFromZOrderWithoutCurrentFocusLine() {
        let text = dump([
            ("ScreenDecorOverlay", true), ("Taskbar", true), ("StatusBar", true),
            ("InputMethod", false),
            ("com.ftester.e2e.flutter/com.ftester.e2e.flutter.MainActivity", true),
            ("com.ftester.e2e/com.ftester.e2e.MainActivity", false),
            ("com.google.android.apps.nexuslauncher/….NexusLauncherActivity", false),
        ])
        XCTAssertEqual(AndroidForegroundWindows.topmostAppPackage(dumpsys: text),
                       "com.ftester.e2e.flutter")
    }

    /// mCurrentFocus 行がある(旧形式)ときはそちらを優先する
    func testTopmostAppPackagePrefersCurrentFocusLineWhenPresent() {
        let text = dump([
            ("com.zorder.top/com.zorder.top.MainActivity", true),
        ]) + "\n  mCurrentFocus=Window{1755f66 u0 com.focused.app/com.focused.app.MainActivity}"
        XCTAssertEqual(AndroidForegroundWindows.topmostAppPackage(dumpsys: text),
                       "com.focused.app")
    }

    /// 可視のアプリ窓が1つも無い(ホーム画面すら取れない・取得失敗)ときは nil で黙る
    func testTopmostAppPackageReturnsNilWhenNoVisibleAppWindow() {
        let text = dump([("StatusBar", true), ("InputMethod", true),
                         ("com.hidden.app/com.hidden.app.MainActivity", false)])
        XCTAssertNil(AndroidForegroundWindows.topmostAppPackage(dumpsys: text))
    }

    func testParsesWindowNameFromRealLine() {
        XCTAssertEqual(
            AndroidForegroundWindows.windowName("Window #7 Window{b9b01a8 u0 InputMethod}:"),
            "InputMethod")
        XCTAssertEqual(
            AndroidForegroundWindows.windowName(
                "Window #8 Window{f2f739c u0 com.ftester.e2e/com.ftester.e2e.MainActivity}:"),
            "com.ftester.e2e/com.ftester.e2e.MainActivity")
        XCTAssertNil(AndroidForegroundWindows.windowName("Window #9 なにか別の行"))
    }
}
