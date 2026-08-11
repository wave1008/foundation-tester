// 「書かれるが存在しない」コマンド名を **unavailable 宣言**で受け止め、正しい書き方を
// コンパイルエラーのメッセージで返す。`cannot find 'X' in scope` は「無い」ことしか伝えず、
// 書き手(とくにコード生成するエージェント)は別の当てずっぽうを試す。ここに1行足すだけで
// 1往復で直る。**実体は無い**(呼べない)ので実行時の挙動には一切影響しない。
//
// 収録する基準は次の2つだけ。**思い付きで足さない**(増やすほど補完候補が汚れる):
//   ① 対称性から実在すると誤解される別名(`existWithScrollLeft`・`*WithScroll*(timeout:)`)。
//      置いていない理由は docs/commands.md「`*WithScroll*` の別名は…」を参照
//   ② 他ツール(Appium / Espresso / Maestro 等)の頻出名で、ftester に 1:1 の対応先があるもの
//
// 対応先を変えたら message も直す(名前だけ直しても案内が古いままになる)。

import Foundation

// MARK: - ① 置いていない別名(本体の引数で書ける)

@available(*, unavailable, message: "ftester has no existWithScrollLeft. Write exist(selector, scroll: .left) instead")
public func existWithScrollLeft(_ selector: String, maxSwipes: Int = 0) { fatalError() }

@available(*, unavailable, message: "ftester has no existWithScrollRight. Write exist(selector, scroll: .right) instead")
public func existWithScrollRight(_ selector: String, maxSwipes: Int = 0) { fatalError() }

@available(*, unavailable, message: "ftester has no notExistWithScrollDown. Write notExist(selector, scroll: .down) instead")
public func notExistWithScrollDown(_ selector: String, maxSwipes: Int = 0) { fatalError() }

@available(*, unavailable, message: "ftester has no notExistWithScrollUp. Write notExist(selector, scroll: .up) instead")
public func notExistWithScrollUp(_ selector: String, maxSwipes: Int = 0) { fatalError() }

@available(*, unavailable, message: "ftester has no notExistWithScrollLeft. Write notExist(selector, scroll: .left) instead")
public func notExistWithScrollLeft(_ selector: String, maxSwipes: Int = 0) { fatalError() }

@available(*, unavailable, message: "ftester has no notExistWithScrollRight. Write notExist(selector, scroll: .right) instead")
public func notExistWithScrollRight(_ selector: String, maxSwipes: Int = 0) { fatalError() }

// `*WithScroll*` の別名は maxSwipes(select 系は requireVisible も)しか取らない糖衣。
// timeout / holdSeconds を渡したいときは本体の scroll: を使う(docs/commands.md)

@available(*, unavailable, message: "The *WithScroll* aliases take only maxSwipes. Write tap(selector, scroll: .down, timeout: ...) instead")
public func tapWithScrollDown(_ selector: String, timeout: Double) { fatalError() }

@available(*, unavailable, message: "The *WithScroll* aliases take only maxSwipes. Write tap(selector, scroll: .up, timeout: ...) instead")
public func tapWithScrollUp(_ selector: String, timeout: Double) { fatalError() }

@available(*, unavailable, message: "The *WithScroll* aliases take only maxSwipes. Write tap(selector, scroll: .left, timeout: ...) instead")
public func tapWithScrollLeft(_ selector: String, timeout: Double) { fatalError() }

@available(*, unavailable, message: "The *WithScroll* aliases take only maxSwipes. Write tap(selector, scroll: .right, timeout: ...) instead")
public func tapWithScrollRight(_ selector: String, timeout: Double) { fatalError() }

@available(*, unavailable, message: "The *WithScroll* aliases take only maxSwipes. Write exist(selector, scroll: .down, timeout: ...) instead")
public func existWithScrollDown(_ selector: String, timeout: Double) { fatalError() }

@available(*, unavailable, message: "The *WithScroll* aliases take only maxSwipes. Write exist(selector, scroll: .up, timeout: ...) instead")
public func existWithScrollUp(_ selector: String, timeout: Double) { fatalError() }

@available(*, unavailable, message: "The *WithScroll* aliases take only maxSwipes and requireVisible. Write select(selector, scroll: .down, timeout: ...) instead")
public func selectWithScrollDown(_ selector: String, timeout: Double) { fatalError() }

@available(*, unavailable, message: "The *WithScroll* aliases take only maxSwipes and requireVisible. Write select(selector, scroll: .up, timeout: ...) instead")
public func selectWithScrollUp(_ selector: String, timeout: Double) { fatalError() }

@available(*, unavailable, message: "The *WithScroll* aliases take only maxSwipes and requireVisible. Write select(selector, scroll: .left, timeout: ...) instead")
public func selectWithScrollLeft(_ selector: String, timeout: Double) { fatalError() }

@available(*, unavailable, message: "The *WithScroll* aliases take only maxSwipes and requireVisible. Write select(selector, scroll: .right, timeout: ...) instead")
public func selectWithScrollRight(_ selector: String, timeout: Double) { fatalError() }

// MARK: - ② 他ツールの名前(1:1 の対応先がある)

@available(*, unavailable, message: "ftester spells this exist(selector). It fails the scenario when the element is missing")
public func assertExists(_ selector: String) { fatalError() }

@available(*, unavailable, message: "ftester spells this exist(selector). Visibility is checked by requireVisible (default true)")
public func assertVisible(_ selector: String) { fatalError() }

@available(*, unavailable, message: "ftester spells this notExist(selector). It waits until the element is gone")
public func assertNotExists(_ selector: String) { fatalError() }

@available(*, unavailable, message: "ftester spells this notExist(selector). It waits until the element is gone")
public func assertNotVisible(_ selector: String) { fatalError() }

@available(*, unavailable, message: "ftester waits for elements implicitly: exist(selector) polls until timeout. To wait explicitly, write waitForDisplay(selector)")
public func waitFor(_ selector: String) { fatalError() }

@available(*, unavailable, message: "ftester waits for elements implicitly: exist(selector) polls until timeout. To wait explicitly, write waitForDisplay(selector)")
public func waitForElement(_ selector: String) { fatalError() }

@available(*, unavailable, message: "ftester spells this waitForDisplay(selector)")
public func waitUntilVisible(_ selector: String) { fatalError() }

@available(*, unavailable, message: "ftester spells this waitForClose(selector)")
public func waitForGone(_ selector: String) { fatalError() }

@available(*, unavailable, message: "ftester spells this wait(seconds). Do not use it to wait for an element — every command already polls until its timeout")
public func sleep(_ seconds: Double) { fatalError() }

@available(*, unavailable, message: "ftester spells this type(selector, text), or type(text) for the focused field")
public func sendKeys(_ selector: String, _ text: String) { fatalError() }

@available(*, unavailable, message: "ftester spells this type(selector, text). Note that type appends — call clearInput(selector) first to replace")
public func inputText(_ selector: String, _ text: String) { fatalError() }

@available(*, unavailable, message: "ftester spells this type(selector, text). Note that type appends — call clearInput(selector) first to replace")
public func setText(_ selector: String, _ text: String) { fatalError() }

@available(*, unavailable, message: "ftester spells this tap(selector)")
public func click(_ selector: String) { fatalError() }

@available(*, unavailable, message: "ftester spells this tap(selector)")
public func clickOn(_ selector: String) { fatalError() }

@available(*, unavailable, message: "ftester spells this tap(selector)")
public func tapOn(_ selector: String) { fatalError() }

@available(*, unavailable, message: "ftester spells this tap(selector, holdSeconds: 1.0)")
public func longPress(_ selector: String) { fatalError() }

@available(*, unavailable, message: "To read the content of an element, write select(selector).text (or .value / .id). To assert it, write select(selector).textIs(expected)")
public func getText(_ selector: String) -> String { fatalError() }

@available(*, unavailable, message: "ftester spells this scrollTo(selector, direction: .down)")
public func scrollToElement(_ selector: String) { fatalError() }

@available(*, unavailable, message: "ftester spells this screenshot()")
public func takeScreenshot() { fatalError() }

@available(*, unavailable, message: "ftester spells this back(). Android sends the back key; iOS swipes from the left edge")
public func pressBack() { fatalError() }

@available(*, unavailable, message: "ftester spells this home()")
public func pressHome() { fatalError() }

@available(*, unavailable, message: "ftester spells this hideKeyboard() (Android only; on iOS use pressEnter())")
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
