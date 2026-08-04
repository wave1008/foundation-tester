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

@available(*, unavailable, message: "To read the content of an element, write select(selector).text (or .value / .id). To assert it, write textIs(selector, expected)")
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

// MARK: - ③ ftester 内の改名(2026-08-04: Shirates(Classic) 準拠の糖衣形へ)

@available(*, unavailable, message: "ftester renamed isEnabled to enabledIsTrue (Shirates-compliant name). Write select(selector).enabledIsTrue() instead")
public func isEnabled(_ selector: String) { fatalError() }

@available(*, unavailable, message: "ftester renamed isDisabled to enabledIsFalse (Shirates-compliant name). Write select(selector).enabledIsFalse() instead")
public func isDisabled(_ selector: String) { fatalError() }

@available(*, unavailable, message: "ftester renamed isChecked to checkIsON (Shirates-compliant name). Write select(selector).checkIsON() instead")
public func isChecked(_ selector: String) { fatalError() }

@available(*, unavailable, message: "ftester renamed isNotChecked to checkIsOFF (Shirates-compliant name). Write select(selector).checkIsOFF() instead")
public func isNotChecked(_ selector: String) { fatalError() }


// MARK: - ④ 検証のセレクタ引数(2026-08-04 廃止: 掴んでから検証する形に統一)

// `textIs("#id", "OK")` は**書けなくなった**。対象は直前に掴んだ要素(lastElement)に固定で、
// 3つの書き方が同義: `select("#id").textIs("OK")` / `select("#id"); lastElement.textIs("OK")` /
// `select("#id"); textIs("OK")`。ここのスタブが無いと `extra argument in call` としか出ず、
// 書き手は「引数を減らす」= 対象を失った検証を書いてしまう(docs/commands.md「テキスト・値の検証」)。
// **String 版と Sel 版の両方**を置く(型付きセレクタで書いていたコードも同じ案内に着地させる)。

@available(*, unavailable, message: "ftester no longer takes a selector in textIs. Write select(selector).textIs(expected), or select(selector) followed by textIs(expected)")
public func textIs(_ selector: String, _ expected: String, timeout: Double = 0,
                   requireVisible: Bool = true) -> FTElement { fatalError() }

@available(*, unavailable, message: "ftester no longer takes a selector in textIs. Write select(selector).textIs(expected), or select(selector) followed by textIs(expected)")
public func textIs(_ selector: Sel, _ expected: String, timeout: Double = 0,
                   requireVisible: Bool = true) -> FTElement { fatalError() }

@available(*, unavailable, message: "ftester no longer takes a selector in textIsNot. Write select(selector).textIsNot(expected), or select(selector) followed by textIsNot(expected)")
public func textIsNot(_ selector: String, _ expected: String, timeout: Double = 0,
                   requireVisible: Bool = true) -> FTElement { fatalError() }

@available(*, unavailable, message: "ftester no longer takes a selector in textIsNot. Write select(selector).textIsNot(expected), or select(selector) followed by textIsNot(expected)")
public func textIsNot(_ selector: Sel, _ expected: String, timeout: Double = 0,
                   requireVisible: Bool = true) -> FTElement { fatalError() }

@available(*, unavailable, message: "ftester no longer takes a selector in textContains. Write select(selector).textContains(expected), or select(selector) followed by textContains(expected)")
public func textContains(_ selector: String, _ expected: String, timeout: Double = 0,
                   requireVisible: Bool = true) -> FTElement { fatalError() }

@available(*, unavailable, message: "ftester no longer takes a selector in textContains. Write select(selector).textContains(expected), or select(selector) followed by textContains(expected)")
public func textContains(_ selector: Sel, _ expected: String, timeout: Double = 0,
                   requireVisible: Bool = true) -> FTElement { fatalError() }

@available(*, unavailable, message: "ftester no longer takes a selector in textContainsNot. Write select(selector).textContainsNot(expected), or select(selector) followed by textContainsNot(expected)")
public func textContainsNot(_ selector: String, _ expected: String, timeout: Double = 0,
                   requireVisible: Bool = true) -> FTElement { fatalError() }

@available(*, unavailable, message: "ftester no longer takes a selector in textContainsNot. Write select(selector).textContainsNot(expected), or select(selector) followed by textContainsNot(expected)")
public func textContainsNot(_ selector: Sel, _ expected: String, timeout: Double = 0,
                   requireVisible: Bool = true) -> FTElement { fatalError() }

@available(*, unavailable, message: "ftester no longer takes a selector in textStartsWith. Write select(selector).textStartsWith(expected), or select(selector) followed by textStartsWith(expected)")
public func textStartsWith(_ selector: String, _ expected: String, timeout: Double = 0,
                   requireVisible: Bool = true) -> FTElement { fatalError() }

@available(*, unavailable, message: "ftester no longer takes a selector in textStartsWith. Write select(selector).textStartsWith(expected), or select(selector) followed by textStartsWith(expected)")
public func textStartsWith(_ selector: Sel, _ expected: String, timeout: Double = 0,
                   requireVisible: Bool = true) -> FTElement { fatalError() }

@available(*, unavailable, message: "ftester no longer takes a selector in textStartsWithNot. Write select(selector).textStartsWithNot(expected), or select(selector) followed by textStartsWithNot(expected)")
public func textStartsWithNot(_ selector: String, _ expected: String, timeout: Double = 0,
                   requireVisible: Bool = true) -> FTElement { fatalError() }

@available(*, unavailable, message: "ftester no longer takes a selector in textStartsWithNot. Write select(selector).textStartsWithNot(expected), or select(selector) followed by textStartsWithNot(expected)")
public func textStartsWithNot(_ selector: Sel, _ expected: String, timeout: Double = 0,
                   requireVisible: Bool = true) -> FTElement { fatalError() }

@available(*, unavailable, message: "ftester no longer takes a selector in textEndsWith. Write select(selector).textEndsWith(expected), or select(selector) followed by textEndsWith(expected)")
public func textEndsWith(_ selector: String, _ expected: String, timeout: Double = 0,
                   requireVisible: Bool = true) -> FTElement { fatalError() }

@available(*, unavailable, message: "ftester no longer takes a selector in textEndsWith. Write select(selector).textEndsWith(expected), or select(selector) followed by textEndsWith(expected)")
public func textEndsWith(_ selector: Sel, _ expected: String, timeout: Double = 0,
                   requireVisible: Bool = true) -> FTElement { fatalError() }

@available(*, unavailable, message: "ftester no longer takes a selector in textEndsWithNot. Write select(selector).textEndsWithNot(expected), or select(selector) followed by textEndsWithNot(expected)")
public func textEndsWithNot(_ selector: String, _ expected: String, timeout: Double = 0,
                   requireVisible: Bool = true) -> FTElement { fatalError() }

@available(*, unavailable, message: "ftester no longer takes a selector in textEndsWithNot. Write select(selector).textEndsWithNot(expected), or select(selector) followed by textEndsWithNot(expected)")
public func textEndsWithNot(_ selector: Sel, _ expected: String, timeout: Double = 0,
                   requireVisible: Bool = true) -> FTElement { fatalError() }

@available(*, unavailable, message: "ftester no longer takes a selector in textMatches. Write select(selector).textMatches(expected), or select(selector) followed by textMatches(expected)")
public func textMatches(_ selector: String, _ expected: String, timeout: Double = 0,
                   requireVisible: Bool = true) -> FTElement { fatalError() }

@available(*, unavailable, message: "ftester no longer takes a selector in textMatches. Write select(selector).textMatches(expected), or select(selector) followed by textMatches(expected)")
public func textMatches(_ selector: Sel, _ expected: String, timeout: Double = 0,
                   requireVisible: Bool = true) -> FTElement { fatalError() }

@available(*, unavailable, message: "ftester no longer takes a selector in textMatchesNot. Write select(selector).textMatchesNot(expected), or select(selector) followed by textMatchesNot(expected)")
public func textMatchesNot(_ selector: String, _ expected: String, timeout: Double = 0,
                   requireVisible: Bool = true) -> FTElement { fatalError() }

@available(*, unavailable, message: "ftester no longer takes a selector in textMatchesNot. Write select(selector).textMatchesNot(expected), or select(selector) followed by textMatchesNot(expected)")
public func textMatchesNot(_ selector: Sel, _ expected: String, timeout: Double = 0,
                   requireVisible: Bool = true) -> FTElement { fatalError() }

@available(*, unavailable, message: "ftester no longer takes a selector in textMatchesDateFormat. Write select(selector).textMatchesDateFormat(expected), or select(selector) followed by textMatchesDateFormat(expected)")
public func textMatchesDateFormat(_ selector: String, _ expected: String, timeout: Double = 0,
                   requireVisible: Bool = true) -> FTElement { fatalError() }

@available(*, unavailable, message: "ftester no longer takes a selector in textMatchesDateFormat. Write select(selector).textMatchesDateFormat(expected), or select(selector) followed by textMatchesDateFormat(expected)")
public func textMatchesDateFormat(_ selector: Sel, _ expected: String, timeout: Double = 0,
                   requireVisible: Bool = true) -> FTElement { fatalError() }

@available(*, unavailable, message: "ftester no longer takes a selector in valueIs. Write select(selector).valueIs(expected), or select(selector) followed by valueIs(expected)")
public func valueIs(_ selector: String, _ expected: String, timeout: Double = 0,
                   requireVisible: Bool = true) -> FTElement { fatalError() }

@available(*, unavailable, message: "ftester no longer takes a selector in valueIs. Write select(selector).valueIs(expected), or select(selector) followed by valueIs(expected)")
public func valueIs(_ selector: Sel, _ expected: String, timeout: Double = 0,
                   requireVisible: Bool = true) -> FTElement { fatalError() }

@available(*, unavailable, message: "ftester no longer takes a selector in valueIsNot. Write select(selector).valueIsNot(expected), or select(selector) followed by valueIsNot(expected)")
public func valueIsNot(_ selector: String, _ expected: String, timeout: Double = 0,
                   requireVisible: Bool = true) -> FTElement { fatalError() }

@available(*, unavailable, message: "ftester no longer takes a selector in valueIsNot. Write select(selector).valueIsNot(expected), or select(selector) followed by valueIsNot(expected)")
public func valueIsNot(_ selector: Sel, _ expected: String, timeout: Double = 0,
                   requireVisible: Bool = true) -> FTElement { fatalError() }

@available(*, unavailable, message: "ftester no longer takes a selector in valueContains. Write select(selector).valueContains(expected), or select(selector) followed by valueContains(expected)")
public func valueContains(_ selector: String, _ expected: String, timeout: Double = 0,
                   requireVisible: Bool = true) -> FTElement { fatalError() }

@available(*, unavailable, message: "ftester no longer takes a selector in valueContains. Write select(selector).valueContains(expected), or select(selector) followed by valueContains(expected)")
public func valueContains(_ selector: Sel, _ expected: String, timeout: Double = 0,
                   requireVisible: Bool = true) -> FTElement { fatalError() }

@available(*, unavailable, message: "ftester no longer takes a selector in valueContainsNot. Write select(selector).valueContainsNot(expected), or select(selector) followed by valueContainsNot(expected)")
public func valueContainsNot(_ selector: String, _ expected: String, timeout: Double = 0,
                   requireVisible: Bool = true) -> FTElement { fatalError() }

@available(*, unavailable, message: "ftester no longer takes a selector in valueContainsNot. Write select(selector).valueContainsNot(expected), or select(selector) followed by valueContainsNot(expected)")
public func valueContainsNot(_ selector: Sel, _ expected: String, timeout: Double = 0,
                   requireVisible: Bool = true) -> FTElement { fatalError() }

@available(*, unavailable, message: "ftester no longer takes a selector in valueStartsWith. Write select(selector).valueStartsWith(expected), or select(selector) followed by valueStartsWith(expected)")
public func valueStartsWith(_ selector: String, _ expected: String, timeout: Double = 0,
                   requireVisible: Bool = true) -> FTElement { fatalError() }

@available(*, unavailable, message: "ftester no longer takes a selector in valueStartsWith. Write select(selector).valueStartsWith(expected), or select(selector) followed by valueStartsWith(expected)")
public func valueStartsWith(_ selector: Sel, _ expected: String, timeout: Double = 0,
                   requireVisible: Bool = true) -> FTElement { fatalError() }

@available(*, unavailable, message: "ftester no longer takes a selector in valueStartsWithNot. Write select(selector).valueStartsWithNot(expected), or select(selector) followed by valueStartsWithNot(expected)")
public func valueStartsWithNot(_ selector: String, _ expected: String, timeout: Double = 0,
                   requireVisible: Bool = true) -> FTElement { fatalError() }

@available(*, unavailable, message: "ftester no longer takes a selector in valueStartsWithNot. Write select(selector).valueStartsWithNot(expected), or select(selector) followed by valueStartsWithNot(expected)")
public func valueStartsWithNot(_ selector: Sel, _ expected: String, timeout: Double = 0,
                   requireVisible: Bool = true) -> FTElement { fatalError() }

@available(*, unavailable, message: "ftester no longer takes a selector in valueEndsWith. Write select(selector).valueEndsWith(expected), or select(selector) followed by valueEndsWith(expected)")
public func valueEndsWith(_ selector: String, _ expected: String, timeout: Double = 0,
                   requireVisible: Bool = true) -> FTElement { fatalError() }

@available(*, unavailable, message: "ftester no longer takes a selector in valueEndsWith. Write select(selector).valueEndsWith(expected), or select(selector) followed by valueEndsWith(expected)")
public func valueEndsWith(_ selector: Sel, _ expected: String, timeout: Double = 0,
                   requireVisible: Bool = true) -> FTElement { fatalError() }

@available(*, unavailable, message: "ftester no longer takes a selector in valueEndsWithNot. Write select(selector).valueEndsWithNot(expected), or select(selector) followed by valueEndsWithNot(expected)")
public func valueEndsWithNot(_ selector: String, _ expected: String, timeout: Double = 0,
                   requireVisible: Bool = true) -> FTElement { fatalError() }

@available(*, unavailable, message: "ftester no longer takes a selector in valueEndsWithNot. Write select(selector).valueEndsWithNot(expected), or select(selector) followed by valueEndsWithNot(expected)")
public func valueEndsWithNot(_ selector: Sel, _ expected: String, timeout: Double = 0,
                   requireVisible: Bool = true) -> FTElement { fatalError() }

@available(*, unavailable, message: "ftester no longer takes a selector in valueMatches. Write select(selector).valueMatches(expected), or select(selector) followed by valueMatches(expected)")
public func valueMatches(_ selector: String, _ expected: String, timeout: Double = 0,
                   requireVisible: Bool = true) -> FTElement { fatalError() }

@available(*, unavailable, message: "ftester no longer takes a selector in valueMatches. Write select(selector).valueMatches(expected), or select(selector) followed by valueMatches(expected)")
public func valueMatches(_ selector: Sel, _ expected: String, timeout: Double = 0,
                   requireVisible: Bool = true) -> FTElement { fatalError() }

@available(*, unavailable, message: "ftester no longer takes a selector in valueMatchesNot. Write select(selector).valueMatchesNot(expected), or select(selector) followed by valueMatchesNot(expected)")
public func valueMatchesNot(_ selector: String, _ expected: String, timeout: Double = 0,
                   requireVisible: Bool = true) -> FTElement { fatalError() }

@available(*, unavailable, message: "ftester no longer takes a selector in valueMatchesNot. Write select(selector).valueMatchesNot(expected), or select(selector) followed by valueMatchesNot(expected)")
public func valueMatchesNot(_ selector: Sel, _ expected: String, timeout: Double = 0,
                   requireVisible: Bool = true) -> FTElement { fatalError() }

@available(*, unavailable, message: "ftester no longer takes a selector in valueMatchesDateFormat. Write select(selector).valueMatchesDateFormat(expected), or select(selector) followed by valueMatchesDateFormat(expected)")
public func valueMatchesDateFormat(_ selector: String, _ expected: String, timeout: Double = 0,
                   requireVisible: Bool = true) -> FTElement { fatalError() }

@available(*, unavailable, message: "ftester no longer takes a selector in valueMatchesDateFormat. Write select(selector).valueMatchesDateFormat(expected), or select(selector) followed by valueMatchesDateFormat(expected)")
public func valueMatchesDateFormat(_ selector: Sel, _ expected: String, timeout: Double = 0,
                   requireVisible: Bool = true) -> FTElement { fatalError() }

@available(*, unavailable, message: "ftester no longer takes a selector in textIsEmpty. Write select(selector).textIsEmpty(), or select(selector) followed by textIsEmpty()")
public func textIsEmpty(_ selector: String, timeout: Double = 0) -> FTElement { fatalError() }

@available(*, unavailable, message: "ftester no longer takes a selector in textIsEmpty. Write select(selector).textIsEmpty(), or select(selector) followed by textIsEmpty()")
public func textIsEmpty(_ selector: Sel, timeout: Double = 0) -> FTElement { fatalError() }

@available(*, unavailable, message: "ftester no longer takes a selector in textIsNotEmpty. Write select(selector).textIsNotEmpty(), or select(selector) followed by textIsNotEmpty()")
public func textIsNotEmpty(_ selector: String, timeout: Double = 0) -> FTElement { fatalError() }

@available(*, unavailable, message: "ftester no longer takes a selector in textIsNotEmpty. Write select(selector).textIsNotEmpty(), or select(selector) followed by textIsNotEmpty()")
public func textIsNotEmpty(_ selector: Sel, timeout: Double = 0) -> FTElement { fatalError() }

@available(*, unavailable, message: "ftester no longer takes a selector in valueIsEmpty. Write select(selector).valueIsEmpty(), or select(selector) followed by valueIsEmpty()")
public func valueIsEmpty(_ selector: String, timeout: Double = 0) -> FTElement { fatalError() }

@available(*, unavailable, message: "ftester no longer takes a selector in valueIsEmpty. Write select(selector).valueIsEmpty(), or select(selector) followed by valueIsEmpty()")
public func valueIsEmpty(_ selector: Sel, timeout: Double = 0) -> FTElement { fatalError() }

@available(*, unavailable, message: "ftester no longer takes a selector in valueIsNotEmpty. Write select(selector).valueIsNotEmpty(), or select(selector) followed by valueIsNotEmpty()")
public func valueIsNotEmpty(_ selector: String, timeout: Double = 0) -> FTElement { fatalError() }

@available(*, unavailable, message: "ftester no longer takes a selector in valueIsNotEmpty. Write select(selector).valueIsNotEmpty(), or select(selector) followed by valueIsNotEmpty()")
public func valueIsNotEmpty(_ selector: Sel, timeout: Double = 0) -> FTElement { fatalError() }

@available(*, unavailable, message: "ftester no longer takes a selector in enabledIsTrue. Write select(selector).enabledIsTrue(), or select(selector) followed by enabledIsTrue()")
public func enabledIsTrue(_ selector: String, timeout: Double = 0) -> FTElement { fatalError() }

@available(*, unavailable, message: "ftester no longer takes a selector in enabledIsTrue. Write select(selector).enabledIsTrue(), or select(selector) followed by enabledIsTrue()")
public func enabledIsTrue(_ selector: Sel, timeout: Double = 0) -> FTElement { fatalError() }

@available(*, unavailable, message: "ftester no longer takes a selector in enabledIsFalse. Write select(selector).enabledIsFalse(), or select(selector) followed by enabledIsFalse()")
public func enabledIsFalse(_ selector: String, timeout: Double = 0) -> FTElement { fatalError() }

@available(*, unavailable, message: "ftester no longer takes a selector in enabledIsFalse. Write select(selector).enabledIsFalse(), or select(selector) followed by enabledIsFalse()")
public func enabledIsFalse(_ selector: Sel, timeout: Double = 0) -> FTElement { fatalError() }

@available(*, unavailable, message: "ftester no longer takes a selector in checkIsON. Write select(selector).checkIsON(), or select(selector) followed by checkIsON()")
public func checkIsON(_ selector: String, timeout: Double = 0) -> FTElement { fatalError() }

@available(*, unavailable, message: "ftester no longer takes a selector in checkIsON. Write select(selector).checkIsON(), or select(selector) followed by checkIsON()")
public func checkIsON(_ selector: Sel, timeout: Double = 0) -> FTElement { fatalError() }

@available(*, unavailable, message: "ftester no longer takes a selector in checkIsOFF. Write select(selector).checkIsOFF(), or select(selector) followed by checkIsOFF()")
public func checkIsOFF(_ selector: String, timeout: Double = 0) -> FTElement { fatalError() }

@available(*, unavailable, message: "ftester no longer takes a selector in checkIsOFF. Write select(selector).checkIsOFF(), or select(selector) followed by checkIsOFF()")
public func checkIsOFF(_ selector: Sel, timeout: Double = 0) -> FTElement { fatalError() }
