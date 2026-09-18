// 「書かれるが存在しない」コマンド名を **unavailable 宣言**で受け止め、正しい書き方を
// コンパイルエラーのメッセージで返す。`cannot find 'X' in scope` は「無い」ことしか伝えず、
// 書き手(とくにコード生成するエージェント)は別の当てずっぽうを試す。ここに1行足すだけで
// 1往復で直る。**実体は無い**(呼べない)ので実行時の挙動には一切影響しない。
//
// 収録する基準は次の2つだけ。**思い付きで足さない**(増やすほど補完候補が汚れる):
//   ① Shirates に実在する、または対称性から実在すると誤解されるスクロール別名(`*WithScroll*`・`*WithoutScroll`)。
//      置いていない理由は docs/commands.md「スクロールの指定は `scroll:` だけ」を参照
//   ② 他ツール(Appium / Espresso / Maestro 等)の頻出名で、fleetest に 1:1 の対応先があるもの
//
// 対応先を変えたら message も直す(名前だけ直しても案内が古いままになる)。

import Foundation

// MARK: - ① 置いていない別名(本体の `scroll:` 引数で書ける)
//
// **スクロールの指定は各コマンドの `scroll:` 引数だけ**(向き = `.down` 等 / この1コマンドだけ送らない = `.noScroll`)。
// 関数名で指定する `*WithScrollDown` 等・`*WithoutScroll` は1つも置かない(ユーザー決定 2026-09-19)。
// Shirates には実在する名前なので全部受け止める。引数は「書かれうるもの」を既定値つきで受ける
// (ラベル違いで `cannot find` に落ちると案内が出ない)

@available(*, unavailable, message: "fleetest has no tapWithScrollDown. Write tap(selector, scroll: .down) instead")
public func tapWithScrollDown(_ selector: String, maxSwipes: Int = 0, timeout: Double? = nil, holdSeconds: Double = 0) { fatalError() }

@available(*, unavailable, message: "fleetest has no tapWithScrollDown. Write tap(selector, scroll: .down) instead")
public func tapWithScrollDown(_ selector: Sel, maxSwipes: Int = 0, timeout: Double? = nil, holdSeconds: Double = 0) { fatalError() }

@available(*, unavailable, message: "fleetest has no existWithScrollDown. Write exist(selector, scroll: .down) instead")
public func existWithScrollDown(_ selector: String, maxSwipes: Int = 0, timeout: Double? = nil, requireVisible: Bool = true) { fatalError() }

@available(*, unavailable, message: "fleetest has no existWithScrollDown. Write exist(selector, scroll: .down) instead")
public func existWithScrollDown(_ selector: Sel, maxSwipes: Int = 0, timeout: Double? = nil, requireVisible: Bool = true) { fatalError() }

@available(*, unavailable, message: "fleetest has no notExistWithScrollDown. Write notExist(selector, scroll: .down) instead")
public func notExistWithScrollDown(_ selector: String, maxSwipes: Int = 0, timeout: Double? = nil) { fatalError() }

@available(*, unavailable, message: "fleetest has no notExistWithScrollDown. Write notExist(selector, scroll: .down) instead")
public func notExistWithScrollDown(_ selector: Sel, maxSwipes: Int = 0, timeout: Double? = nil) { fatalError() }

@available(*, unavailable, message: "fleetest has no selectWithScrollDown. Write select(selector, scroll: .down) instead")
public func selectWithScrollDown(_ selector: String, requireVisible: Bool = true, maxSwipes: Int = 0, timeout: Double? = nil) { fatalError() }

@available(*, unavailable, message: "fleetest has no selectWithScrollDown. Write select(selector, scroll: .down) instead")
public func selectWithScrollDown(_ selector: Sel, requireVisible: Bool = true, maxSwipes: Int = 0, timeout: Double? = nil) { fatalError() }

@available(*, unavailable, message: "fleetest has no findImageWithScrollDown. Write findImage(label, scroll: .down) instead")
public func findImageWithScrollDown(_ label: String, threshold: Double = 0, aspectRatioTolerance: Double = 0, maxSwipes: Int = 0) { fatalError() }

@available(*, unavailable, message: "fleetest has no existImageWithScrollDown. Write existImage(label, scroll: .down) instead")
public func existImageWithScrollDown(_ label: String, threshold: Double = 0, aspectRatioTolerance: Double = 0, maxSwipes: Int = 0) { fatalError() }

@available(*, unavailable, message: "fleetest has no tapWithScrollUp. Write tap(selector, scroll: .up) instead")
public func tapWithScrollUp(_ selector: String, maxSwipes: Int = 0, timeout: Double? = nil, holdSeconds: Double = 0) { fatalError() }

@available(*, unavailable, message: "fleetest has no tapWithScrollUp. Write tap(selector, scroll: .up) instead")
public func tapWithScrollUp(_ selector: Sel, maxSwipes: Int = 0, timeout: Double? = nil, holdSeconds: Double = 0) { fatalError() }

@available(*, unavailable, message: "fleetest has no existWithScrollUp. Write exist(selector, scroll: .up) instead")
public func existWithScrollUp(_ selector: String, maxSwipes: Int = 0, timeout: Double? = nil, requireVisible: Bool = true) { fatalError() }

@available(*, unavailable, message: "fleetest has no existWithScrollUp. Write exist(selector, scroll: .up) instead")
public func existWithScrollUp(_ selector: Sel, maxSwipes: Int = 0, timeout: Double? = nil, requireVisible: Bool = true) { fatalError() }

@available(*, unavailable, message: "fleetest has no notExistWithScrollUp. Write notExist(selector, scroll: .up) instead")
public func notExistWithScrollUp(_ selector: String, maxSwipes: Int = 0, timeout: Double? = nil) { fatalError() }

@available(*, unavailable, message: "fleetest has no notExistWithScrollUp. Write notExist(selector, scroll: .up) instead")
public func notExistWithScrollUp(_ selector: Sel, maxSwipes: Int = 0, timeout: Double? = nil) { fatalError() }

@available(*, unavailable, message: "fleetest has no selectWithScrollUp. Write select(selector, scroll: .up) instead")
public func selectWithScrollUp(_ selector: String, requireVisible: Bool = true, maxSwipes: Int = 0, timeout: Double? = nil) { fatalError() }

@available(*, unavailable, message: "fleetest has no selectWithScrollUp. Write select(selector, scroll: .up) instead")
public func selectWithScrollUp(_ selector: Sel, requireVisible: Bool = true, maxSwipes: Int = 0, timeout: Double? = nil) { fatalError() }

@available(*, unavailable, message: "fleetest has no findImageWithScrollUp. Write findImage(label, scroll: .up) instead")
public func findImageWithScrollUp(_ label: String, threshold: Double = 0, aspectRatioTolerance: Double = 0, maxSwipes: Int = 0) { fatalError() }

@available(*, unavailable, message: "fleetest has no existImageWithScrollUp. Write existImage(label, scroll: .up) instead")
public func existImageWithScrollUp(_ label: String, threshold: Double = 0, aspectRatioTolerance: Double = 0, maxSwipes: Int = 0) { fatalError() }

@available(*, unavailable, message: "fleetest has no tapWithScrollRight. Write tap(selector, scroll: .right) instead")
public func tapWithScrollRight(_ selector: String, maxSwipes: Int = 0, timeout: Double? = nil, holdSeconds: Double = 0) { fatalError() }

@available(*, unavailable, message: "fleetest has no tapWithScrollRight. Write tap(selector, scroll: .right) instead")
public func tapWithScrollRight(_ selector: Sel, maxSwipes: Int = 0, timeout: Double? = nil, holdSeconds: Double = 0) { fatalError() }

@available(*, unavailable, message: "fleetest has no existWithScrollRight. Write exist(selector, scroll: .right) instead")
public func existWithScrollRight(_ selector: String, maxSwipes: Int = 0, timeout: Double? = nil, requireVisible: Bool = true) { fatalError() }

@available(*, unavailable, message: "fleetest has no existWithScrollRight. Write exist(selector, scroll: .right) instead")
public func existWithScrollRight(_ selector: Sel, maxSwipes: Int = 0, timeout: Double? = nil, requireVisible: Bool = true) { fatalError() }

@available(*, unavailable, message: "fleetest has no notExistWithScrollRight. Write notExist(selector, scroll: .right) instead")
public func notExistWithScrollRight(_ selector: String, maxSwipes: Int = 0, timeout: Double? = nil) { fatalError() }

@available(*, unavailable, message: "fleetest has no notExistWithScrollRight. Write notExist(selector, scroll: .right) instead")
public func notExistWithScrollRight(_ selector: Sel, maxSwipes: Int = 0, timeout: Double? = nil) { fatalError() }

@available(*, unavailable, message: "fleetest has no selectWithScrollRight. Write select(selector, scroll: .right) instead")
public func selectWithScrollRight(_ selector: String, requireVisible: Bool = true, maxSwipes: Int = 0, timeout: Double? = nil) { fatalError() }

@available(*, unavailable, message: "fleetest has no selectWithScrollRight. Write select(selector, scroll: .right) instead")
public func selectWithScrollRight(_ selector: Sel, requireVisible: Bool = true, maxSwipes: Int = 0, timeout: Double? = nil) { fatalError() }

@available(*, unavailable, message: "fleetest has no findImageWithScrollRight. Write findImage(label, scroll: .right) instead")
public func findImageWithScrollRight(_ label: String, threshold: Double = 0, aspectRatioTolerance: Double = 0, maxSwipes: Int = 0) { fatalError() }

@available(*, unavailable, message: "fleetest has no existImageWithScrollRight. Write existImage(label, scroll: .right) instead")
public func existImageWithScrollRight(_ label: String, threshold: Double = 0, aspectRatioTolerance: Double = 0, maxSwipes: Int = 0) { fatalError() }

@available(*, unavailable, message: "fleetest has no tapWithScrollLeft. Write tap(selector, scroll: .left) instead")
public func tapWithScrollLeft(_ selector: String, maxSwipes: Int = 0, timeout: Double? = nil, holdSeconds: Double = 0) { fatalError() }

@available(*, unavailable, message: "fleetest has no tapWithScrollLeft. Write tap(selector, scroll: .left) instead")
public func tapWithScrollLeft(_ selector: Sel, maxSwipes: Int = 0, timeout: Double? = nil, holdSeconds: Double = 0) { fatalError() }

@available(*, unavailable, message: "fleetest has no existWithScrollLeft. Write exist(selector, scroll: .left) instead")
public func existWithScrollLeft(_ selector: String, maxSwipes: Int = 0, timeout: Double? = nil, requireVisible: Bool = true) { fatalError() }

@available(*, unavailable, message: "fleetest has no existWithScrollLeft. Write exist(selector, scroll: .left) instead")
public func existWithScrollLeft(_ selector: Sel, maxSwipes: Int = 0, timeout: Double? = nil, requireVisible: Bool = true) { fatalError() }

@available(*, unavailable, message: "fleetest has no notExistWithScrollLeft. Write notExist(selector, scroll: .left) instead")
public func notExistWithScrollLeft(_ selector: String, maxSwipes: Int = 0, timeout: Double? = nil) { fatalError() }

@available(*, unavailable, message: "fleetest has no notExistWithScrollLeft. Write notExist(selector, scroll: .left) instead")
public func notExistWithScrollLeft(_ selector: Sel, maxSwipes: Int = 0, timeout: Double? = nil) { fatalError() }

@available(*, unavailable, message: "fleetest has no selectWithScrollLeft. Write select(selector, scroll: .left) instead")
public func selectWithScrollLeft(_ selector: String, requireVisible: Bool = true, maxSwipes: Int = 0, timeout: Double? = nil) { fatalError() }

@available(*, unavailable, message: "fleetest has no selectWithScrollLeft. Write select(selector, scroll: .left) instead")
public func selectWithScrollLeft(_ selector: Sel, requireVisible: Bool = true, maxSwipes: Int = 0, timeout: Double? = nil) { fatalError() }

@available(*, unavailable, message: "fleetest has no findImageWithScrollLeft. Write findImage(label, scroll: .left) instead")
public func findImageWithScrollLeft(_ label: String, threshold: Double = 0, aspectRatioTolerance: Double = 0, maxSwipes: Int = 0) { fatalError() }

@available(*, unavailable, message: "fleetest has no existImageWithScrollLeft. Write existImage(label, scroll: .left) instead")
public func existImageWithScrollLeft(_ label: String, threshold: Double = 0, aspectRatioTolerance: Double = 0, maxSwipes: Int = 0) { fatalError() }

@available(*, unavailable, message: "fleetest has no tapWithoutScroll. Write tap(selector, scroll: .noScroll) instead")
public func tapWithoutScroll(_ selector: String, timeout: Double? = nil) { fatalError() }

@available(*, unavailable, message: "fleetest has no tapWithoutScroll. Write tap(selector, scroll: .noScroll) instead")
public func tapWithoutScroll(_ selector: Sel, timeout: Double? = nil) { fatalError() }

@available(*, unavailable, message: "fleetest has no existWithoutScroll. Write exist(selector, scroll: .noScroll) instead")
public func existWithoutScroll(_ selector: String, timeout: Double? = nil, requireVisible: Bool = true) { fatalError() }

@available(*, unavailable, message: "fleetest has no existWithoutScroll. Write exist(selector, scroll: .noScroll) instead")
public func existWithoutScroll(_ selector: Sel, timeout: Double? = nil, requireVisible: Bool = true) { fatalError() }

@available(*, unavailable, message: "fleetest has no notExistWithoutScroll. Write notExist(selector, scroll: .noScroll) instead")
public func notExistWithoutScroll(_ selector: String, timeout: Double? = nil) { fatalError() }

@available(*, unavailable, message: "fleetest has no notExistWithoutScroll. Write notExist(selector, scroll: .noScroll) instead")
public func notExistWithoutScroll(_ selector: Sel, timeout: Double? = nil) { fatalError() }

@available(*, unavailable, message: "fleetest has no selectWithoutScroll. Write select(selector, scroll: .noScroll) instead")
public func selectWithoutScroll(_ selector: String, timeout: Double? = nil, requireVisible: Bool = true) { fatalError() }

@available(*, unavailable, message: "fleetest has no selectWithoutScroll. Write select(selector, scroll: .noScroll) instead")
public func selectWithoutScroll(_ selector: Sel, timeout: Double? = nil, requireVisible: Bool = true) { fatalError() }

@available(*, unavailable, message: "fleetest has no findImageWithoutScroll. Write findImage(label, scroll: .noScroll) instead")
public func findImageWithoutScroll(_ label: String, threshold: Double = 0, aspectRatioTolerance: Double = 0, timeout: Double? = nil) { fatalError() }

@available(*, unavailable, message: "fleetest has no existImageWithoutScroll. Write existImage(label, scroll: .noScroll) instead")
public func existImageWithoutScroll(_ label: String, threshold: Double = 0, aspectRatioTolerance: Double = 0, timeout: Double? = nil) { fatalError() }

// MARK: - ② 他ツールの名前(1:1 の対応先がある)

@available(*, unavailable, message: "fleetest spells this exist(selector). It fails the scenario when the element is missing")
public func assertExists(_ selector: String) { fatalError() }

@available(*, unavailable, message: "fleetest spells this exist(selector). Visibility is checked by requireVisible (default true)")
public func assertVisible(_ selector: String) { fatalError() }

@available(*, unavailable, message: "fleetest spells this notExist(selector). It waits until the element is gone")
public func assertNotExists(_ selector: String) { fatalError() }

@available(*, unavailable, message: "fleetest spells this notExist(selector). It waits until the element is gone")
public func assertNotVisible(_ selector: String) { fatalError() }

@available(*, unavailable, message: "fleetest waits for elements implicitly: exist(selector) polls until timeout. To wait explicitly, write waitForDisplay(selector)")
public func waitFor(_ selector: String) { fatalError() }

@available(*, unavailable, message: "fleetest waits for elements implicitly: exist(selector) polls until timeout. To wait explicitly, write waitForDisplay(selector)")
public func waitForElement(_ selector: String) { fatalError() }

@available(*, unavailable, message: "fleetest spells this waitForDisplay(selector)")
public func waitUntilVisible(_ selector: String) { fatalError() }

@available(*, unavailable, message: "fleetest spells this waitForClose(selector)")
public func waitForGone(_ selector: String) { fatalError() }

@available(*, unavailable, message: "fleetest spells this wait(seconds). Do not use it to wait for an element — every command already polls until its timeout")
public func sleep(_ seconds: Double) { fatalError() }

@available(*, unavailable, message: "fleetest spells this type(selector, text), or type(text) for the focused field")
public func sendKeys(_ selector: String, _ text: String) { fatalError() }

@available(*, unavailable, message: "fleetest spells this type(selector, text). Note that type appends — call clearInput(selector) first to replace")
public func inputText(_ selector: String, _ text: String) { fatalError() }

@available(*, unavailable, message: "fleetest spells this type(selector, text). Note that type appends — call clearInput(selector) first to replace")
public func setText(_ selector: String, _ text: String) { fatalError() }

@available(*, unavailable, message: "fleetest spells this tap(selector)")
public func click(_ selector: String) { fatalError() }

@available(*, unavailable, message: "fleetest spells this tap(selector)")
public func clickOn(_ selector: String) { fatalError() }

@available(*, unavailable, message: "fleetest spells this tap(selector)")
public func tapOn(_ selector: String) { fatalError() }

@available(*, unavailable, message: "fleetest spells this tap(selector, holdSeconds: 1.0)")
public func longPress(_ selector: String) { fatalError() }

@available(*, unavailable, message: "To read the content of an element, write select(selector).text (or .value / .id). To assert it, write select(selector).textIs(expected)")
public func getText(_ selector: String) -> String { fatalError() }

@available(*, unavailable, message: "fleetest spells this scrollTo(selector, direction: .down)")
public func scrollToElement(_ selector: String) { fatalError() }

@available(*, unavailable, message: "fleetest spells this screenshot()")
public func takeScreenshot() { fatalError() }

@available(*, unavailable, message: "fleetest spells this back(). Android sends the back key; iOS swipes from the left edge")
public func pressBack() { fatalError() }

@available(*, unavailable, message: "fleetest spells this home()")
public func pressHome() { fatalError() }

@available(*, unavailable, message: "fleetest spells this hideKeyboard() (Android only; on iOS use pressEnter())")
public func closeKeyboard() { fatalError() }

// スワイプ系は**指の向きとコンテンツの向きが逆**なので、名前だけ直すと意味が反転する。
// メッセージで両方の候補を出す(docs/commands.md「スクロールの方向はすべてコンテンツ基準」)

@available(*, unavailable, message: "Write swipe(.up) for the raw finger gesture, or scrollDown() to read further down the content (the two are the same motion, opposite naming)")
public func swipeUp() { fatalError() }

@available(*, unavailable, message: "Write swipe(.down) for the raw finger gesture, or scrollUp() to go back up the content (the two are the same motion, opposite naming)")
public func swipeDown() { fatalError() }

@available(*, unavailable, message: "Write swipe(.left) for the raw finger gesture, or scrollRight() to read further right in the content (the two are the same motion, opposite naming)")
public func swipeLeft() { fatalError() }

@available(*, unavailable, message: "Write swipe(.right) for the raw finger gesture, or scrollLeft() to go back left in the content (the two are the same motion, opposite naming)")
public func swipeRight() { fatalError() }

// Shirates の `screenIs` は**画面ニックネームの同定**(識別要素の宣言に照らす)。fleetest は
// ニックネーム機構を持たず、同名だった `screenIs` は FM の**見た目の照合**だったので改名した
// (docs/shirates-parity.md)。移行してきた書き手が最初に打つ名前なので、両方の行き先を出す

@available(*, unavailable, message: "fleetest has no screen nickname mechanism. To check the screen by sight, write screenLooksLike(description) (Foundation Models). To identify a screen deterministically, write exist() on an element unique to it")
public func screenIs(_ nickname: String) { fatalError() }

@available(*, unavailable, message: "fleetest spells this iosAlertHandler(alert:button:)")
public func systemAlertHandler(alert: String, button: String) { fatalError() }
