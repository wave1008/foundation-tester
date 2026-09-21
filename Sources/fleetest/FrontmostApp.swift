// ライブ操作で「今 前面にあるアプリ」を決める純粋ロジック。
//
// **XCTest に前面アプリを返す API は無い**ので、次の2つを掛け合わせて採る:
//   ① 起動中アプリの bundle ID(ホスト: `simctl spawn <udid> launchctl list` の UIKitApplication 行)
//   ② それぞれが前面か(ブリッジ: `POST /appstate` = XCUIApplication.state。公開 API)
// ②単独では決まらない —— **SpringBoard は system shell で常に前面と答える**(実測 2026-09-22:
// 設定アプリを開いた状態で springboard / Preferences の両方が true、他の起動中 9 アプリは false)。
// 除外してちょうど1つ残ったときだけ採る。
//
// 非公開 API(XCTRunnerDaemonSession.activeApplication 等)は使わない —— Xcode 27 では
// その経路自体が消えていた(XCAXClientProxy が存在しない)。

import Foundation

enum FrontmostApp {
    /// 前面かどうかを聞いても答えにならない bundle ID。**利用者が見ている「アプリ」ではないもの**を落とす。
    /// - SpringBoard: system shell。背面に回らないので常に前面と答える
    /// - ランナー自身: XCUITest のランナーアプリ
    /// - SpringBoard の裏方(ウィジェットのレンダラ・ビューサービス): 画面の一部を描くだけで、
    ///   利用者から見ればホーム画面。**実測 2026-09-22: ホーム画面で
    ///   `com.apple.chrono.WidgetRenderer-Default` が前面と答える**(SpringBoard も true、他は false)。
    ///   落とさないとセッションがここを向き、**home が効かなくなる**
    ///   (`XCUIDevice.press(.home)` の検証が「前面のまま」で 422。BridgeRouter.handleHome)
    ///
    /// **網羅はできない** —— 裏方プロセスは OS の版で増えるので、ここは「知っている型を落とす」
    /// だけ。取りこぼしても `pick` の「ちょうど1つ」条件が、複数が前面と答える場合は選ばせない。
    static func isExcluded(_ bundleID: String) -> Bool {
        if bundleID == LiveSessionTarget.springboard { return true }
        if bundleID.hasSuffix(".xctrunner") { return true }
        if bundleID.hasPrefix("com.apple.chrono.") { return true }
        return bundleID.hasSuffix("ViewService")
    }

    /// `launchctl list` の1行から UIKitApplication の bundle ID を取り出す。
    /// 形: `<pid>\t<status>\tUIKitApplication:<bundleID>[<token>][<flags>]`。
    /// UIKitApplication 行でなければ nil(システムサービスの行が大半)。
    static func bundleID(fromLaunchctlLine line: String) -> String? {
        guard let marker = line.range(of: "UIKitApplication:") else { return nil }
        let rest = line[marker.upperBound...]
        guard let bracket = rest.firstIndex(of: "[") else { return nil }
        let bundleID = String(rest[..<bracket])
        return bundleID.isEmpty ? nil : bundleID
    }

    /// 起動中アプリの一覧(`launchctl list` の出力全体)から、前面かを聞く候補を作る。
    /// 重複を畳み、聞いても無駄なものを落とす。**順序は入力のまま**(安定して同じ順で聞く)。
    static func candidates(launchctlOutput: String) -> [String] {
        var seen = Set<String>()
        var result: [String] = []
        for line in launchctlOutput.split(separator: "\n", omittingEmptySubsequences: true) {
            guard let bundleID = bundleID(fromLaunchctlLine: String(line)),
                  !isExcluded(bundleID), seen.insert(bundleID).inserted
            else { continue }
            result.append(bundleID)
        }
        return result
    }

    /// 前面と答えたものから1つ決める。**ちょうど1つのときだけ採る** ——
    /// 0個は「アプリは前面にない」(ホーム画面・アプリスイッチャー)で、呼び手は SpringBoard へ倒す。
    /// 2個以上は判定材料が足りないということなので、黙って選ばない(別のアプリの木を読ませない)。
    static func pick(foreground: [String]) -> String? {
        let usable = foreground.filter { !isExcluded($0) }
        return usable.count == 1 ? usable[0] : nil
    }
}
