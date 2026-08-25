// CommandsVerify.swift
// 検証コマンド(exist/notExist/select・lastElement 系・FTElement のチェーン検証)。
// 操作コマンドと共通経路の解説は Commands.swift 冒頭のコメント参照。

import Foundation
import FTCore

// MARK: - 検証コマンド

/// 要素の存在検証。戻り値に .textIs / .valueIs をチェーンできる
/// (timeout 省略時は実行プロファイルの defaultTimeout、それも無ければ 5 秒)
/// 存在検証。既定で可視性も確認(= 実際に見えていることも確認): ツリー存在に加え、
/// ①幾何(収まる軸の中心が画面外なら不可視。FM 不要)②FM(覆われ/減光/不在)の2段で
/// 確認する(見えなければ失敗)。ツリー存在だけ見たい(高速・アイコン等)場合は requireVisible: false。
/// 実行プロファイルの falsePositiveCheck が無効(既定)の run では guard は素通り(存在のみと同じ)。
/// FM が判定を返さなかったステップは①だけで通り `visibility-guard-skipped` の注記が残る
/// (判定は StepExecutor.occlusionFlip)。
/// scroll: 指定すると検証前に**その方向へスクロールしながら要素を探す**
/// (Shirates の existWithScrollDown 相当。省略時は現在画面だけを見る)。
/// 方向は**コンテンツ基準**(`.down` = 下に読み進める)
@discardableResult
public func exist(_ selector: String, timeout: Double? = nil, requireVisible: Bool = true,
                  scroll: FTScrollDirection? = nil, maxSwipes: Int = FlowStep.defaultMaxSwipes,
                  file: StaticString = #filePath, line: UInt = #line) -> FTElement {
    existImpl(FTSelector.parse(selector), timeout: timeout, requireVisible: requireVisible,
              scroll: scroll, maxSwipes: maxSwipes, file: file, line: line)
}

@discardableResult
public func exist(_ selector: Sel, timeout: Double? = nil, requireVisible: Bool = true,
                  scroll: FTScrollDirection? = nil, maxSwipes: Int = FlowStep.defaultMaxSwipes,
                  file: StaticString = #filePath, line: UInt = #line) -> FTElement {
    existImpl(selector.ftSelector, timeout: timeout, requireVisible: requireVisible,
              scroll: scroll, maxSwipes: maxSwipes, file: file, line: line)
}

@discardableResult
private func existImpl(_ selector: FTSelector, timeout: Double?, requireVisible: Bool,
                       scroll: FTScrollDirection?, maxSwipes: Int,
                       file: StaticString, line: UInt) -> FTElement {
    let core = FTRuntime.requireCore(command: "exist")
    let scroll = core.effectiveScroll(scroll)
    let step = FlowStep(assert: "exists", locator: selector.primary,
                        fallbacks: selector.stepFallbacks,
                        direction: scroll?.swipe.rawValue,
                        timeout: timeout ?? core.defaultTimeout,
                        maxSwipes: scroll == nil ? nil : maxSwipes,
                        occlusionGuard: requireVisible,
                        scrollFrame: contextScrollFrame(core, scrolling: scroll != nil))
    let result = perform("exist", selector, step: step, description: "exist \"\(selector.text)\"",
                        file: file, line: line)
    return FTElement(selector: selector, matched: result.element)
}

// MARK: - select(要素を掴む。exist(検証)との違いは直下の doc コメント参照)

/// **検証ではなく要素を掴む操作**(Shirates の select 相当)。FlowStep は `action: "select"`
/// (exist は `assert: "exists"`)なので検証ステップとしては記録されない。
/// 値の読み出し(`.text`/`.value`/`.id`)や検証コマンドへのチェーンの起点に使う。
/// **掴めなければ失敗させず空要素を返す**(`.isEmpty` で分岐する)。「見つからない」と
/// 「見つかったが見えない(覆われ・見切れ)」を同じ形で返すのは、どちらも
/// 「値を読める状態ではない」という同じ意味だから。`requireVisible: false` で可視性照合を外す。
/// **在ることを保証したいなら `exist`**(あちらは掴めなければ失敗する)。
/// scroll: 指定すると解決前に**その方向へスクロールしながら要素を探す**(exist(scroll:) と同じ)
@discardableResult
public func select(_ selector: String, timeout: Double? = nil,
                   requireVisible: Bool = true,
                   scroll: FTScrollDirection? = nil, maxSwipes: Int = FlowStep.defaultMaxSwipes,
                   file: StaticString = #filePath, line: UInt = #line) -> FTElement {
    selectImpl(FTSelector.parse(selector), timeout: timeout,
              requireVisible: requireVisible,
              scroll: scroll, maxSwipes: maxSwipes, file: file, line: line)
}

@discardableResult
public func select(_ selector: Sel, timeout: Double? = nil,
                   requireVisible: Bool = true,
                   scroll: FTScrollDirection? = nil, maxSwipes: Int = FlowStep.defaultMaxSwipes,
                   file: StaticString = #filePath, line: UInt = #line) -> FTElement {
    selectImpl(selector.ftSelector, timeout: timeout,
              requireVisible: requireVisible,
              scroll: scroll, maxSwipes: maxSwipes, file: file, line: line)
}

@discardableResult
private func selectImpl(_ selector: FTSelector, timeout: Double?,
                        requireVisible: Bool,
                        scroll: FTScrollDirection?, maxSwipes: Int,
                        file: StaticString, line: UInt) -> FTElement {
    let core = FTRuntime.requireCore(command: "select")
    let scroll = core.effectiveScroll(scroll)
    let step = FlowStep(action: "select", locator: selector.primary,
                        fallbacks: selector.stepFallbacks,
                        direction: scroll?.swipe.rawValue,
                        timeout: timeout ?? core.defaultTimeout,
                        maxSwipes: scroll == nil ? nil : maxSwipes,
                        occlusionGuard: requireVisible,
                        scrollFrame: contextScrollFrame(core, scrolling: scroll != nil))
    let result = perform("select", selector, step: step,
                        description: "select \"\(selector.text)\"",
                        file: file, line: line)
    return FTElement(selector: selector, matched: result.element)
}

@discardableResult
public func selectWithScrollDown(_ selector: String, requireVisible: Bool = true,
                                 maxSwipes: Int = FlowStep.defaultMaxSwipes,
                                 file: StaticString = #filePath, line: UInt = #line) -> FTElement {
    select(selector, requireVisible: requireVisible, scroll: .down,
           maxSwipes: maxSwipes, file: file, line: line)
}

@discardableResult
public func selectWithScrollDown(_ selector: Sel, requireVisible: Bool = true,
                                 maxSwipes: Int = FlowStep.defaultMaxSwipes,
                                 file: StaticString = #filePath, line: UInt = #line) -> FTElement {
    select(selector, requireVisible: requireVisible, scroll: .down,
           maxSwipes: maxSwipes, file: file, line: line)
}

@discardableResult
public func selectWithScrollUp(_ selector: String, requireVisible: Bool = true,
                               maxSwipes: Int = FlowStep.defaultMaxSwipes,
                               file: StaticString = #filePath, line: UInt = #line) -> FTElement {
    select(selector, requireVisible: requireVisible, scroll: .up,
           maxSwipes: maxSwipes, file: file, line: line)
}

@discardableResult
public func selectWithScrollUp(_ selector: Sel, requireVisible: Bool = true,
                               maxSwipes: Int = FlowStep.defaultMaxSwipes,
                               file: StaticString = #filePath, line: UInt = #line) -> FTElement {
    select(selector, requireVisible: requireVisible, scroll: .up,
           maxSwipes: maxSwipes, file: file, line: line)
}

@discardableResult
public func selectWithScrollLeft(_ selector: String, requireVisible: Bool = true,
                                 maxSwipes: Int = FlowStep.defaultMaxSwipes,
                                 file: StaticString = #filePath, line: UInt = #line) -> FTElement {
    select(selector, requireVisible: requireVisible, scroll: .left,
           maxSwipes: maxSwipes, file: file, line: line)
}

@discardableResult
public func selectWithScrollLeft(_ selector: Sel, requireVisible: Bool = true,
                                 maxSwipes: Int = FlowStep.defaultMaxSwipes,
                                 file: StaticString = #filePath, line: UInt = #line) -> FTElement {
    select(selector, requireVisible: requireVisible, scroll: .left,
           maxSwipes: maxSwipes, file: file, line: line)
}

@discardableResult
public func selectWithScrollRight(_ selector: String, requireVisible: Bool = true,
                                  maxSwipes: Int = FlowStep.defaultMaxSwipes,
                                  file: StaticString = #filePath, line: UInt = #line) -> FTElement {
    select(selector, requireVisible: requireVisible, scroll: .right,
           maxSwipes: maxSwipes, file: file, line: line)
}

@discardableResult
public func selectWithScrollRight(_ selector: Sel, requireVisible: Bool = true,
                                  maxSwipes: Int = FlowStep.defaultMaxSwipes,
                                  file: StaticString = #filePath, line: UInt = #line) -> FTElement {
    select(selector, requireVisible: requireVisible, scroll: .right,
           maxSwipes: maxSwipes, file: file, line: line)
}

/// withScroll* の中でも**この1コマンドだけ**現在画面から解決する(existWithoutScroll と同じ仕組み)
@discardableResult
public func selectWithoutScroll(_ selector: String,
                                timeout: Double? = nil, requireVisible: Bool = true,
                                file: StaticString = #filePath, line: UInt = #line) -> FTElement {
    var element: FTElement?
    FTRuntime.requireCore(command: "selectWithoutScroll").runWithScrollContext(.none) {
        element = select(selector, timeout: timeout,
                         requireVisible: requireVisible, file: file, line: line)
    }
    return element ?? FTElement(selector: FTSelector.parse(selector))
}

/// フォールバックは selector.ftSelector から作る(existWithoutScroll と同じ理由)
@discardableResult
public func selectWithoutScroll(_ selector: Sel,
                                timeout: Double? = nil, requireVisible: Bool = true,
                                file: StaticString = #filePath, line: UInt = #line) -> FTElement {
    var element: FTElement?
    FTRuntime.requireCore(command: "selectWithoutScroll").runWithScrollContext(.none) {
        element = select(selector, timeout: timeout,
                         requireVisible: requireVisible, file: file, line: line)
    }
    return element ?? FTElement(selector: selector.ftSelector)
}

/// 何も掴んでいない `lastElement` が持つセレクタ。**実在しないラベル**なので、そのまま
/// チェーンした検証は必ず落ちる(空要素を黙って通さないため)
private let lastElementPlaceholder = "<lastElement: nothing has been grabbed yet>"

/// **直前に掴んだ要素**(Shirates の `TestDriver.lastElement` 相当)。
/// 要素を1つに定めて解決したコマンド(`select` / `exist` / `tap` / `type` / `waitForDisplay` /
/// テキスト・値の検証など)が通るたびに差し替わる。差し替えないのは**要素を1つに定めないもの**
/// (`notExist` / `countIs`)と**セレクタを取らないもの**(`swipe` / `launchApp` など)。
///
///     select("#txt_total")
///     lastElement.text.thisContains("1,200")
///
/// **値(`.text`/`.value`/`.id`)は掴んだ時点の凍結値**で、読んでも画面を取り直さない。
/// 掴んだ後にスクロールやタップを挟むと**古い値**を読む(座標も古い)ので、値を読むのは
/// 掴んだ直後だけにする —— 離れた場所で使うなら変数に受けるほうが読み手に事故が見える。
/// `.textIs(...)` 等のチェーンは**掴んだ値で先に判定し、満たしていなければセレクタから
/// 取り直してポーリングする**(古い値では通らないが、古い値で通ってしまう向きの誤りは残る)。
/// **掴めなかったコマンドは空要素で上書きする**(前の要素が残ると別要素の値を読んでしまう)。
/// **scene を跨ぐと空**(前の画面の要素を読むのは事故なので持ち越さない)。
/// 一度も掴んでいない状態で読むと空要素 + 警告(黙って通る形にしない)
public var lastElement: FTElement {
    let core = FTRuntime.requireCore(command: "lastElement")
    guard let element = core.lastResolvedElement else {
        core.warnLastElementUnavailable()
        return FTElement(selector: FTSelector.label(lastElementPlaceholder))
    }
    return element
}

// MARK: - 検証コマンド(**対象は直前に掴んだ要素** = 暗黙の lastElement)

// 検証はすべて「掴んでから検証する」形に統一されている(ユーザー決定)。
// **次の3つは同義**で、どれで書いても同じステップ・同じ判定になる:
//
//     select("#btn_ok").textIs("OK")     // 戻り値へチェーン
//     select("#btn_ok"); lastElement.textIs("OK")   // 保持要素を明示
//     select("#btn_ok"); textIs("OK")    // 暗黙の lastElement(ここの自由関数)
//
// **セレクタを取る版(`textIs("#btn_ok", "OK")`)は置かない**(未リリースで移行案内は不要・
// ユーザー決定。コンパイラの素のエラーになる)。対象を暗黙にしたのは、検証のたびにセレクタを書くと
// 「どの要素を見ているか」が select と検証で二重に現れ、片方だけ直す事故が起きるため。
// **要素を1つに定めないコマンド(`exist` / `notExist` / `countIs` / `screenLooksLike`)はセレクタを取り続ける**。
//
// 共通の規律(以下 31 関数すべてに効く):
// - **`scroll:` は足さない**(ユーザー決定)。これらは静止した画面を詳細に検証する
//   ためのもので、条件を満たすまで自動でスクロールする挙動は望まれていない。`exist` / `tap` が
//   `scroll:` を持つのは「在るか」を探す・操作するコマンドだから。**一貫性を理由に対称化しないこと**。
//   画面外を見たいときは直前に `scrollTo`(docs/design.md §10)
// - **否定形と空判定は可視性を見ない**(見えていないことは画面照合できない)。肯定形は既定で
//   可視性も確認し、部分一致系は**実際に一致した部分文字列**で照合する(パターンは画面に出ない)
// - 判定の実体は FTElement の同名メソッド1か所(ここは委譲だけ)。**片方だけ足さない**
//   (`ftElementChainSync.test.mjs` が3つの書き方の対応を見張る)

/// 1引数の検証に**セレクタらしい文字列**が渡された誤り(旧2引数形の書き癖)を実行前に落とす。
/// とくに否定形は「そのテキストではない」が常に真になり**黙って緑**になる。
/// 本当にその文字列を期待値にしたいならチェーン形で書く(対象が明示なので曖昧さが無い)
private func expectedLooksLikeSelector(_ expected: String, verb: String,
                                       file: StaticString, line: UInt) -> FTElement? {
    guard FTSelector.selectorLikeInputError(expected) != nil else { return nil }
    let core = FTRuntime.requireCore(command: verb)
    core.perform(step: FlowStep(assert: verb), description: "\(verb) \"\(expected)\"",
                 command: verb,
                 commandError: "`\(verb)(\"\(expected)\")` checks the text of the element grabbed last"
                     + " — the single-argument form takes an expected value, not a selector."
                     + " Write select(\"\(expected)\") first, or use select(<selector>).\(verb)(<expected>).",
                 file: file, line: line)
    return FTElement(selector: FTSelector.label(expected))
}

@discardableResult
public func textIs(_ expected: String, timeout: Double? = nil, requireVisible: Bool = true,
                   strict: Bool = false,
                   file: StaticString = #filePath, line: UInt = #line) -> FTElement {
    if let rejected = expectedLooksLikeSelector(expected, verb: "textIs",
                                                file: file, line: line) { return rejected }
    return lastElement.textIs(expected, timeout: timeout, requireVisible: requireVisible,
                              strict: strict, file: file, line: line)
}

/// テキストが期待値と**一致しない**ことの検証(タイムアウトまで変化を待つ)。
/// 「その要素が無いこと」は notExist、「別の値になったこと」はこちら
@discardableResult
public func textIsNot(_ expected: String, timeout: Double? = nil,
                      strict: Bool = false,
                   file: StaticString = #filePath, line: UInt = #line) -> FTElement {
    if let rejected = expectedLooksLikeSelector(expected, verb: "textIsNot",
                                                file: file, line: line) { return rejected }
    return lastElement.textIsNot(expected, timeout: timeout, strict: strict, file: file, line: line)
}

@discardableResult
public func textContains(_ expected: String, timeout: Double? = nil, requireVisible: Bool = true,
                         strict: Bool = false,
                   file: StaticString = #filePath, line: UInt = #line) -> FTElement {
    if let rejected = expectedLooksLikeSelector(expected, verb: "textContains",
                                                file: file, line: line) { return rejected }
    return lastElement.textContains(expected, timeout: timeout, requireVisible: requireVisible,
                                    strict: strict, file: file, line: line)
}

@discardableResult
public func textContainsNot(_ expected: String, timeout: Double? = nil,
                            strict: Bool = false,
                   file: StaticString = #filePath, line: UInt = #line) -> FTElement {
    if let rejected = expectedLooksLikeSelector(expected, verb: "textContainsNot",
                                                file: file, line: line) { return rejected }
    return lastElement.textContainsNot(expected, timeout: timeout, strict: strict, file: file, line: line)
}

@discardableResult
public func textStartsWith(_ expected: String, timeout: Double? = nil, requireVisible: Bool = true,
                           strict: Bool = false,
                   file: StaticString = #filePath, line: UInt = #line) -> FTElement {
    if let rejected = expectedLooksLikeSelector(expected, verb: "textStartsWith",
                                                file: file, line: line) { return rejected }
    return lastElement.textStartsWith(expected, timeout: timeout, requireVisible: requireVisible,
                                      strict: strict, file: file, line: line)
}

@discardableResult
public func textStartsWithNot(_ expected: String, timeout: Double? = nil,
                              strict: Bool = false,
                   file: StaticString = #filePath, line: UInt = #line) -> FTElement {
    if let rejected = expectedLooksLikeSelector(expected, verb: "textStartsWithNot",
                                                file: file, line: line) { return rejected }
    return lastElement.textStartsWithNot(expected, timeout: timeout, strict: strict, file: file, line: line)
}

@discardableResult
public func textEndsWith(_ expected: String, timeout: Double? = nil, requireVisible: Bool = true,
                         strict: Bool = false,
                   file: StaticString = #filePath, line: UInt = #line) -> FTElement {
    if let rejected = expectedLooksLikeSelector(expected, verb: "textEndsWith",
                                                file: file, line: line) { return rejected }
    return lastElement.textEndsWith(expected, timeout: timeout, requireVisible: requireVisible,
                                    strict: strict, file: file, line: line)
}

@discardableResult
public func textEndsWithNot(_ expected: String, timeout: Double? = nil,
                            strict: Bool = false,
                   file: StaticString = #filePath, line: UInt = #line) -> FTElement {
    if let rejected = expectedLooksLikeSelector(expected, verb: "textEndsWithNot",
                                                file: file, line: line) { return rejected }
    return lastElement.textEndsWithNot(expected, timeout: timeout, strict: strict, file: file, line: line)
}

/// **部分一致**の正規表現(全体一致にしたいときは `^...$` を書く)
@discardableResult
public func textMatches(_ pattern: String, timeout: Double? = nil, requireVisible: Bool = true,
                        strict: Bool = false,
                   file: StaticString = #filePath, line: UInt = #line) -> FTElement {
    if let rejected = expectedLooksLikeSelector(pattern, verb: "textMatches",
                                                file: file, line: line) { return rejected }
    return lastElement.textMatches(pattern, timeout: timeout, requireVisible: requireVisible,
                                   strict: strict, file: file, line: line)
}

@discardableResult
public func textMatchesNot(_ pattern: String, timeout: Double? = nil,
                           strict: Bool = false,
                   file: StaticString = #filePath, line: UInt = #line) -> FTElement {
    if let rejected = expectedLooksLikeSelector(pattern, verb: "textMatchesNot",
                                                file: file, line: line) { return rejected }
    return lastElement.textMatchesNot(pattern, timeout: timeout, strict: strict, file: file, line: line)
}

/// DateFormatter の書式(`yyyy/MM/dd` 等)で解釈できることの検証
@discardableResult
public func textMatchesDateFormat(_ format: String, timeout: Double? = nil, requireVisible: Bool = true,
                                  file: StaticString = #filePath, line: UInt = #line) -> FTElement {
    if let rejected = expectedLooksLikeSelector(format, verb: "textMatchesDateFormat",
                                                file: file, line: line) { return rejected }
    return lastElement.textMatchesDateFormat(format, timeout: timeout, requireVisible: requireVisible,
                                             file: file, line: line)
}

@discardableResult
public func textIsEmpty(timeout: Double? = nil,
                        strict: Bool = false,
                   file: StaticString = #filePath, line: UInt = #line) -> FTElement {
    return lastElement.textIsEmpty(timeout: timeout, strict: strict, file: file, line: line)
}

@discardableResult
public func textIsNotEmpty(timeout: Double? = nil,
                           strict: Bool = false,
                   file: StaticString = #filePath, line: UInt = #line) -> FTElement {
    return lastElement.textIsNotEmpty(timeout: timeout, strict: strict, file: file, line: line)
}

@discardableResult
public func valueIs(_ expected: String, timeout: Double? = nil, requireVisible: Bool = true,
                    strict: Bool = false,
                   file: StaticString = #filePath, line: UInt = #line) -> FTElement {
    if let rejected = expectedLooksLikeSelector(expected, verb: "valueIs",
                                                file: file, line: line) { return rejected }
    return lastElement.valueIs(expected, timeout: timeout, requireVisible: requireVisible,
                               strict: strict, file: file, line: line)
}

@discardableResult
public func valueIsNot(_ expected: String, timeout: Double? = nil,
                       strict: Bool = false,
                   file: StaticString = #filePath, line: UInt = #line) -> FTElement {
    if let rejected = expectedLooksLikeSelector(expected, verb: "valueIsNot",
                                                file: file, line: line) { return rejected }
    return lastElement.valueIsNot(expected, timeout: timeout, strict: strict, file: file, line: line)
}

@discardableResult
public func valueContains(_ expected: String, timeout: Double? = nil, requireVisible: Bool = true,
                          strict: Bool = false,
                   file: StaticString = #filePath, line: UInt = #line) -> FTElement {
    if let rejected = expectedLooksLikeSelector(expected, verb: "valueContains",
                                                file: file, line: line) { return rejected }
    return lastElement.valueContains(expected, timeout: timeout, requireVisible: requireVisible,
                                     strict: strict, file: file, line: line)
}

@discardableResult
public func valueContainsNot(_ expected: String, timeout: Double? = nil,
                             strict: Bool = false,
                   file: StaticString = #filePath, line: UInt = #line) -> FTElement {
    if let rejected = expectedLooksLikeSelector(expected, verb: "valueContainsNot",
                                                file: file, line: line) { return rejected }
    return lastElement.valueContainsNot(expected, timeout: timeout, strict: strict, file: file, line: line)
}

@discardableResult
public func valueStartsWith(_ expected: String, timeout: Double? = nil, requireVisible: Bool = true,
                            strict: Bool = false,
                   file: StaticString = #filePath, line: UInt = #line) -> FTElement {
    if let rejected = expectedLooksLikeSelector(expected, verb: "valueStartsWith",
                                                file: file, line: line) { return rejected }
    return lastElement.valueStartsWith(expected, timeout: timeout, requireVisible: requireVisible,
                                       strict: strict, file: file, line: line)
}

@discardableResult
public func valueStartsWithNot(_ expected: String, timeout: Double? = nil,
                               strict: Bool = false,
                   file: StaticString = #filePath, line: UInt = #line) -> FTElement {
    if let rejected = expectedLooksLikeSelector(expected, verb: "valueStartsWithNot",
                                                file: file, line: line) { return rejected }
    return lastElement.valueStartsWithNot(expected, timeout: timeout, strict: strict, file: file, line: line)
}

@discardableResult
public func valueEndsWith(_ expected: String, timeout: Double? = nil, requireVisible: Bool = true,
                          strict: Bool = false,
                   file: StaticString = #filePath, line: UInt = #line) -> FTElement {
    if let rejected = expectedLooksLikeSelector(expected, verb: "valueEndsWith",
                                                file: file, line: line) { return rejected }
    return lastElement.valueEndsWith(expected, timeout: timeout, requireVisible: requireVisible,
                                     strict: strict, file: file, line: line)
}

@discardableResult
public func valueEndsWithNot(_ expected: String, timeout: Double? = nil,
                             strict: Bool = false,
                   file: StaticString = #filePath, line: UInt = #line) -> FTElement {
    if let rejected = expectedLooksLikeSelector(expected, verb: "valueEndsWithNot",
                                                file: file, line: line) { return rejected }
    return lastElement.valueEndsWithNot(expected, timeout: timeout, strict: strict, file: file, line: line)
}

/// **部分一致**の正規表現(textMatches と同じ規則)
@discardableResult
public func valueMatches(_ pattern: String, timeout: Double? = nil, requireVisible: Bool = true,
                         strict: Bool = false,
                   file: StaticString = #filePath, line: UInt = #line) -> FTElement {
    if let rejected = expectedLooksLikeSelector(pattern, verb: "valueMatches",
                                                file: file, line: line) { return rejected }
    return lastElement.valueMatches(pattern, timeout: timeout, requireVisible: requireVisible,
                                    strict: strict, file: file, line: line)
}

@discardableResult
public func valueMatchesNot(_ pattern: String, timeout: Double? = nil,
                            strict: Bool = false,
                   file: StaticString = #filePath, line: UInt = #line) -> FTElement {
    if let rejected = expectedLooksLikeSelector(pattern, verb: "valueMatchesNot",
                                                file: file, line: line) { return rejected }
    return lastElement.valueMatchesNot(pattern, timeout: timeout, strict: strict, file: file, line: line)
}

/// DateFormatter の書式で解釈できることの検証
@discardableResult
public func valueMatchesDateFormat(_ format: String, timeout: Double? = nil, requireVisible: Bool = true,
                                   file: StaticString = #filePath, line: UInt = #line) -> FTElement {
    if let rejected = expectedLooksLikeSelector(format, verb: "valueMatchesDateFormat",
                                                file: file, line: line) { return rejected }
    return lastElement.valueMatchesDateFormat(format, timeout: timeout, requireVisible: requireVisible,
                                              file: file, line: line)
}

@discardableResult
public func valueIsEmpty(timeout: Double? = nil,
                         strict: Bool = false,
                   file: StaticString = #filePath, line: UInt = #line) -> FTElement {
    return lastElement.valueIsEmpty(timeout: timeout, strict: strict, file: file, line: line)
}

@discardableResult
public func valueIsNotEmpty(timeout: Double? = nil,
                            strict: Bool = false,
                   file: StaticString = #filePath, line: UInt = #line) -> FTElement {
    return lastElement.valueIsNotEmpty(timeout: timeout, strict: strict, file: file, line: line)
}

/// 掴んだ要素の id 検証。**セレクタに `#id` を足す形にはしない**(`||` を含む式で結合が変わり、
/// 落ちたときに実際の id を出せないため)
@discardableResult
public func idIs(_ expected: String, timeout: Double? = nil,
                 strict: Bool = false,
                   file: StaticString = #filePath, line: UInt = #line) -> FTElement {
    if let rejected = expectedLooksLikeSelector(expected, verb: "idIs",
                                                file: file, line: line) { return rejected }
    return lastElement.idIs(expected, timeout: timeout, strict: strict, file: file, line: line)
}

@discardableResult
public func enabledIsTrue(timeout: Double? = nil,
                          file: StaticString = #filePath, line: UInt = #line) -> FTElement {
    return lastElement.enabledIsTrue(timeout: timeout, file: file, line: line)
}

@discardableResult
public func enabledIsFalse(timeout: Double? = nil,
                           file: StaticString = #filePath, line: UInt = #line) -> FTElement {
    return lastElement.enabledIsFalse(timeout: timeout, file: file, line: line)
}

/// スイッチ・チェックボックス・ラジオが**オン**であることの検証。取得元は
/// iOS=accessibility の selected trait / Android=isChecked。**型が OS で揃わない要素でも使える**
@discardableResult
public func checkIsON(timeout: Double? = nil,
                      file: StaticString = #filePath, line: UInt = #line) -> FTElement {
    return lastElement.checkIsON(timeout: timeout, file: file, line: line)
}

/// **オフ**であることの検証。状態を持たない要素(ただのボタン等)も「オフ」として通る
/// (ブリッジは true のときだけ送るため。誤用は run 終了時に警告が出る)
@discardableResult
public func checkIsOFF(timeout: Double? = nil,
                       file: StaticString = #filePath, line: UInt = #line) -> FTElement {
    return lastElement.checkIsOFF(timeout: timeout, file: file, line: line)
}
















/// textIsEmpty / textIsNotEmpty の共通実装(期待値を取らないアサート)
private func emptyAssert(_ assert: String, verb: String, selector: FTSelector, timeout: Double?,
                         held: ElementInfo? = nil, strict: Bool = false,
                         file: StaticString, line: UInt) {
    let core = FTRuntime.requireCore(command: verb)
    var step = FlowStep(assert: assert, locator: selector.primary,
                        fallbacks: selector.stepFallbacks,
                        timeout: timeout ?? core.defaultTimeout)
    // 空判定も正規化を通る(ゼロ幅だけの文字列は「空」)。strict では素の空だけを空とみなす
    step.strictText = strict ? true : nil
    perform(verb, selector, step: step, description: "\(verb) \"\(selector.text)\"",
            held: held, file: file, line: line)
}





































/// textIs / valueIs / textContains / textMatches の共通実装。
/// operatorText は説明文の記号だけを分ける(完全一致系は `==`、部分一致系は `~`)。
/// held は FTElement のチェーンだけが渡す(自由関数版は nil = 常に実機を見る)
private func textAssert(_ assert: String, verb: String, selector: FTSelector, expected: String,
                        timeout: Double?, requireVisible: Bool, operatorText: String = "~",
                        held: ElementInfo? = nil, strict: Bool = false,
                        file: StaticString, line: UInt) {
    let core = FTRuntime.requireCore(command: verb)
    var step = FlowStep(assert: assert, locator: selector.primary,
                        fallbacks: selector.stepFallbacks,
                        expected: expected, timeout: timeout ?? core.defaultTimeout,
                        occlusionGuard: requireVisible)
    // **既定は nil のまま**(JSON・生成コードを既定ケースで太らせない。duration と同じ方針)
    step.strictText = strict ? true : nil
    perform(verb, selector, step: step,
            description: "\(verb) \"\(selector.text)\" \(operatorText) \"\(expected)\"",
            held: held, file: file, line: line)
}

/// 不在検証。**消えるまで待つ**(初回で不在なら即成功、在ればタイムアウトまで消滅を待つ)。
/// exist の裏返しであり、ダイアログ・ローディング・トーストが閉じたことの確認に使う。
/// 可視性(occlusion)は見ない — ツリーから消えたことが判定基準。
/// scroll: 指定すると**その方向へスクロールしながら探し、見つかったら不在検証を即失敗させる**
/// (exist(scroll:) の裏返し。見つからなければ従来どおり現在のビューポートでの消滅待ちへ進む)
public func notExist(_ selector: String, timeout: Double? = nil,
                     scroll: FTScrollDirection? = nil, maxSwipes: Int = FlowStep.defaultMaxSwipes,
                     file: StaticString = #filePath, line: UInt = #line) {
    notExistImpl(FTSelector.parse(selector), timeout: timeout,
                scroll: scroll, maxSwipes: maxSwipes, file: file, line: line)
}

public func notExist(_ selector: Sel, timeout: Double? = nil,
                     scroll: FTScrollDirection? = nil, maxSwipes: Int = FlowStep.defaultMaxSwipes,
                     file: StaticString = #filePath, line: UInt = #line) {
    notExistImpl(selector.ftSelector, timeout: timeout,
                scroll: scroll, maxSwipes: maxSwipes, file: file, line: line)
}

private func notExistImpl(_ selector: FTSelector, timeout: Double?,
                          scroll: FTScrollDirection?, maxSwipes: Int,
                          file: StaticString, line: UInt) {
    let core = FTRuntime.requireCore(command: "notExist")
    let scroll = core.effectiveScroll(scroll)
    let step = FlowStep(assert: "notExists", locator: selector.primary,
                        fallbacks: selector.stepFallbacks,
                        direction: scroll?.swipe.rawValue,
                        timeout: timeout ?? core.defaultTimeout,
                        maxSwipes: scroll == nil ? nil : maxSwipes,
                        scrollFrame: contextScrollFrame(core, scrolling: scroll != nil))
    perform("notExist", selector, step: step, description: "notExist \"\(selector.text)\"",
            file: file, line: line)
}

/// 要素が表示されるまで待つ(スクロールしない)。exist の可視性確認込みの形にタイムアウトだけ差し替えたもの
@discardableResult
public func waitForDisplay(_ expression: String, waitSeconds: Double = FlowStep.defaultIsScreenWaitSeconds,
                           file: StaticString = #filePath, line: UInt = #line) -> FTElement {
    waitForDisplayImpl(FTSelector.parse(expression), waitSeconds: waitSeconds, file: file, line: line)
}

@discardableResult
public func waitForDisplay(_ expression: Sel, waitSeconds: Double = FlowStep.defaultIsScreenWaitSeconds,
                           file: StaticString = #filePath, line: UInt = #line) -> FTElement {
    waitForDisplayImpl(expression.ftSelector, waitSeconds: waitSeconds, file: file, line: line)
}

@discardableResult
private func waitForDisplayImpl(_ selector: FTSelector, waitSeconds: Double,
                                file: StaticString, line: UInt) -> FTElement {
    let step = FlowStep(assert: "exists", locator: selector.primary,
                        fallbacks: selector.stepFallbacks,
                        timeout: waitSeconds, occlusionGuard: true)
    let result = perform("waitForDisplay", selector, step: step,
                         description: "waitForDisplay \"\(selector.text)\"", file: file, line: line)
    return FTElement(selector: selector, matched: result.element)
}

/// 要素が消えるまで待つ(スクロールしない)。expression 省略(直前セレクタ再利用)は実装しない
/// (`lastElement` はあるが、待ち対象がソース上で読めなくなるため待ち系には省略形を置かない)
public func waitForClose(_ expression: String, waitSeconds: Double = FlowStep.defaultIsScreenWaitSeconds,
                         file: StaticString = #filePath, line: UInt = #line) {
    waitForCloseImpl(FTSelector.parse(expression), waitSeconds: waitSeconds, file: file, line: line)
}

public func waitForClose(_ expression: Sel, waitSeconds: Double = FlowStep.defaultIsScreenWaitSeconds,
                         file: StaticString = #filePath, line: UInt = #line) {
    waitForCloseImpl(expression.ftSelector, waitSeconds: waitSeconds, file: file, line: line)
}

private func waitForCloseImpl(_ selector: FTSelector, waitSeconds: Double,
                              file: StaticString, line: UInt) {
    let step = FlowStep(assert: "notExists", locator: selector.primary,
                        fallbacks: selector.stepFallbacks,
                        timeout: waitSeconds)
    perform("waitForClose", selector, step: step,
            description: "waitForClose \"\(selector.text)\"", file: file, line: line)
}









/// enabled/disabled/checked/notChecked の共通実装(アサート名だけが違う)。
/// **checked/notChecked は held を渡されても実機を見る**(HeldElementAssert の除外理由参照)
private func enabledAssert(_ assert: String, verb: String, selector: FTSelector, timeout: Double?,
                           held: ElementInfo? = nil,
                           file: StaticString, line: UInt) {
    let core = FTRuntime.requireCore(command: verb)
    let step = FlowStep(assert: assert, locator: selector.primary,
                        fallbacks: selector.stepFallbacks,
                        timeout: timeout ?? core.defaultTimeout)
    perform(verb, selector, step: step, description: "\(verb) \"\(selector.text)\"",
            held: held, file: file, line: line)
}

/// 一致する要素の個数を検証する(リスト件数の確認など)。タイムアウトまで個数の変化を待つ。
/// `||` は**候補集合の和**を数える(Shirates 準拠。同じ要素が複数の節にマッチしても1度だけ)。
/// スコープと併用すると容器の中だけ数えられる:
/// countIs("#list >> .Cell", 3)
public func countIs(_ selector: String, _ expected: Int, timeout: Double? = nil,
                    file: StaticString = #filePath, line: UInt = #line) {
    countIsImpl(FTSelector.parse(selector), expected, timeout: timeout, file: file, line: line)
}

public func countIs(_ selector: Sel, _ expected: Int, timeout: Double? = nil,
                    file: StaticString = #filePath, line: UInt = #line) {
    countIsImpl(selector.ftSelector, expected, timeout: timeout, file: file, line: line)
}

private func countIsImpl(_ selector: FTSelector, _ expected: Int, timeout: Double?,
                         file: StaticString, line: UInt) {
    let core = FTRuntime.requireCore(command: "countIs")
    let step = FlowStep(assert: "count", locator: selector.primary,
                        fallbacks: selector.stepFallbacks,
                        timeout: timeout ?? core.defaultTimeout, expectedCount: expected)
    perform("countIs", selector, step: step,
            description: "countIs \"\(selector.text)\" == \(expected)", file: file, line: line)
}

/// 画面全体の検証(自然言語+Foundation Models のマルチモーダル判定)
public func screenLooksLike(_ expected: String,
                            file: StaticString = #filePath, line: UInt = #line) {
    let step = FlowStep(assert: "screenMatches", expected: expected)
    FTRuntime.requireCore(command: "screenLooksLike")
        .perform(step: step, description: "screenLooksLike \"\(expected)\"",
                 command: "screenLooksLike", file: file, line: line)
}

/// キーボードが表示されていることの検証。開閉はアニメーションを伴うためタイムアウトまでポーリングする
/// (1回のスナップショット照会だとフレークする)
public func keyboardIsShown(timeout: Double? = nil,
                            file: StaticString = #filePath, line: UInt = #line) {
    let core = FTRuntime.requireCore(command: "keyboardIsShown")
    let step = FlowStep(assert: "keyboardShown", timeout: timeout ?? core.defaultTimeout)
    core.perform(step: step, description: "keyboardIsShown", command: "keyboardIsShown", file: file, line: line)
}

/// キーボードが表示されていないことの検証(タイムアウトまでポーリング。理由は keyboardIsShown 参照)
public func keyboardIsNotShown(timeout: Double? = nil,
                               file: StaticString = #filePath, line: UInt = #line) {
    let core = FTRuntime.requireCore(command: "keyboardIsNotShown")
    let step = FlowStep(assert: "keyboardNotShown", timeout: timeout ?? core.defaultTimeout)
    core.perform(step: step, description: "keyboardIsNotShown", command: "keyboardIsNotShown", file: file, line: line)
}

/// exist の戻り値。検証をチェーンできる。
/// **網羅の規則**: セレクタを取り「その要素」を検証する自由関数は**すべて同名でここにも生える**
/// (text/value の全対称 + `enabledIsTrue` / `enabledIsFalse` / `checkIsON` / `checkIsOFF` + `idIs`)。
/// 一部だけ生やすと「どれがチェーンできるか」が覚えられず、書いてみるまで分からない。
/// **例外は要素を1つに定めないコマンド**(`notExist` / `countIs` / `screenLooksLike`)で、これらは
/// 掴んだ要素に対する検証ではないのでチェーンにしない。新しい検証コマンドを足すときは両方に足す
public struct FTElement {
    let selector: FTSelector
    /// exist が照合した時点の要素(**再取得しない**。追加のデバイス往復は発生させない)。
    /// 掴めなかった・失敗後スキップ・dry-run では nil。以降の .textIs 等のチェーンは
    /// 再照合しても matched は更新しない(値の出所は最初の exist に固定)。
    /// **チェーンの初回判定にはこの値を使う**(満たしていればデバイスを見ない。
    /// FTDriveCore.perform の高速経路 / 判定範囲は HeldElementAssert)
    let matched: ElementInfo?

    init(selector: FTSelector, matched: ElementInfo? = nil) {
        self.selector = selector
        self.matched = matched
    }

    /// **要素を掴めていないか**(Shirates の `TestElement.isEmpty` 相当)。
    /// `select` が見えない要素で空要素を返したとき・掴めなかったとき・dry-run で true。
    /// `.text` 等が nil かどうかで判定すると「掴めたが label が無い要素」と区別できない
    public var isEmpty: Bool { matched == nil }
    /// 掴めているか(`isEmpty` の逆)
    public var isNotEmpty: Bool { matched != nil }

    /// 掴んだ要素の表示テキスト(label)
    public var text: String? { matched?.label }
    /// 掴んだ要素の value
    public var value: String? { matched?.value }
    /// 掴んだ要素の identifier
    public var id: String? { matched?.identifier }

    @discardableResult
    public func textIs(_ expected: String, timeout: Double? = nil, requireVisible: Bool = true,
                       strict: Bool = false,
                       file: StaticString = #filePath, line: UInt = #line) -> FTElement {
        textAssert("textEquals", verb: "textIs", selector: selector, expected: expected,
                   timeout: timeout, requireVisible: requireVisible, operatorText: "==",
                   held: matched, strict: strict, file: file, line: line)
        return self
    }

    @discardableResult
    public func valueIs(_ expected: String, timeout: Double? = nil, requireVisible: Bool = true,
                        strict: Bool = false,
                       file: StaticString = #filePath, line: UInt = #line) -> FTElement {
        textAssert("valueEquals", verb: "valueIs", selector: selector, expected: expected,
                   timeout: timeout, requireVisible: requireVisible, operatorText: "==",
                   held: matched, strict: strict, file: file, line: line)
        return self
    }

    @discardableResult
    public func textStartsWith(_ expected: String, timeout: Double? = nil,
                               requireVisible: Bool = true,
                               strict: Bool = false,
                       file: StaticString = #filePath, line: UInt = #line) -> FTElement {
        textAssert("textStartsWith", verb: "textStartsWith", selector: selector,
                   expected: expected, timeout: timeout, requireVisible: requireVisible,
                   held: matched, strict: strict, file: file, line: line)
        return self
    }

    @discardableResult
    public func textEndsWith(_ expected: String, timeout: Double? = nil,
                             requireVisible: Bool = true,
                             strict: Bool = false,
                       file: StaticString = #filePath, line: UInt = #line) -> FTElement {
        textAssert("textEndsWith", verb: "textEndsWith", selector: selector,
                   expected: expected, timeout: timeout, requireVisible: requireVisible,
                   held: matched, strict: strict, file: file, line: line)
        return self
    }

    @discardableResult
    public func textIsNot(_ expected: String, timeout: Double? = nil,
                          strict: Bool = false,
                       file: StaticString = #filePath, line: UInt = #line) -> FTElement {
        textAssert("textNotEquals", verb: "textIsNot", selector: selector, expected: expected,
                   timeout: timeout, requireVisible: false, operatorText: "!=",
                   held: matched, strict: strict, file: file, line: line)
        return self
    }

    /// 掴んだ要素の id 検証(Shirates の TestElement.idIs)。
    /// **セレクタに `#id` を足す形にはしない** — `||` を含む式で結合が変わるうえ、
    /// 落ちたときに「見つからない」としか言えず**実際の id** を出せないため
    @discardableResult
    public func idIs(_ expected: String, timeout: Double? = nil,
                     strict: Bool = false,
                       file: StaticString = #filePath, line: UInt = #line) -> FTElement {
        let core = FTRuntime.requireCore(command: "idIs")
        var step = FlowStep(assert: "idEquals", locator: selector.primary,
                            fallbacks: selector.stepFallbacks, expected: expected,
                            timeout: timeout ?? core.defaultTimeout, occlusionGuard: false)
        step.strictText = strict ? true : nil
        perform("idIs", selector, step: step,
                description: "idIs \"\(selector.text)\" == \"\(expected)\"",
                held: matched, file: file, line: line)
        return self
    }

    @discardableResult
    public func textIsNotEmpty(timeout: Double? = nil,
                               strict: Bool = false,
                       file: StaticString = #filePath, line: UInt = #line) -> FTElement {
        emptyAssert("textIsNotEmpty", verb: "textIsNotEmpty", selector: selector,
                    timeout: timeout, held: matched, strict: strict, file: file, line: line)
        return self
    }

    @discardableResult
    public func textIsEmpty(timeout: Double? = nil,
                            strict: Bool = false,
                       file: StaticString = #filePath, line: UInt = #line) -> FTElement {
        emptyAssert("textIsEmpty", verb: "textIsEmpty", selector: selector,
                    timeout: timeout, held: matched, strict: strict, file: file, line: line)
        return self
    }

    @discardableResult
    public func textContains(_ expected: String, timeout: Double? = nil,
                             requireVisible: Bool = true,
                             strict: Bool = false,
                       file: StaticString = #filePath, line: UInt = #line) -> FTElement {
        textAssert("textContains", verb: "textContains", selector: selector, expected: expected,
                   timeout: timeout, requireVisible: requireVisible, held: matched, strict: strict, file: file, line: line)
        return self
    }

    @discardableResult
    public func textMatches(_ pattern: String, timeout: Double? = nil,
                            requireVisible: Bool = true,
                            strict: Bool = false,
                       file: StaticString = #filePath, line: UInt = #line) -> FTElement {
        textAssert("textMatches", verb: "textMatches", selector: selector, expected: pattern,
                   timeout: timeout, requireVisible: requireVisible, held: matched, strict: strict, file: file, line: line)
        return self
    }

    @discardableResult
    public func textMatchesDateFormat(_ format: String, timeout: Double? = nil,
                                      requireVisible: Bool = true,
                                      file: StaticString = #filePath, line: UInt = #line) -> FTElement {
        textAssert("textMatchesDateFormat", verb: "textMatchesDateFormat", selector: selector,
                   expected: format, timeout: timeout, requireVisible: requireVisible,
                   operatorText: "~", held: matched, file: file, line: line)
        return self
    }

    @discardableResult
    public func textStartsWithNot(_ expected: String, timeout: Double? = nil,
                                  strict: Bool = false,
                       file: StaticString = #filePath, line: UInt = #line) -> FTElement {
        textAssert("textStartsWithNot", verb: "textStartsWithNot", selector: selector,
                   expected: expected, timeout: timeout, requireVisible: false,
                   operatorText: "!=", held: matched, strict: strict, file: file, line: line)
        return self
    }

    @discardableResult
    public func textContainsNot(_ expected: String, timeout: Double? = nil,
                                strict: Bool = false,
                       file: StaticString = #filePath, line: UInt = #line) -> FTElement {
        textAssert("textContainsNot", verb: "textContainsNot", selector: selector,
                   expected: expected, timeout: timeout, requireVisible: false,
                   operatorText: "!=", held: matched, strict: strict, file: file, line: line)
        return self
    }

    @discardableResult
    public func textEndsWithNot(_ expected: String, timeout: Double? = nil,
                                strict: Bool = false,
                       file: StaticString = #filePath, line: UInt = #line) -> FTElement {
        textAssert("textEndsWithNot", verb: "textEndsWithNot", selector: selector,
                   expected: expected, timeout: timeout, requireVisible: false,
                   operatorText: "!=", held: matched, strict: strict, file: file, line: line)
        return self
    }

    @discardableResult
    public func textMatchesNot(_ pattern: String, timeout: Double? = nil,
                               strict: Bool = false,
                       file: StaticString = #filePath, line: UInt = #line) -> FTElement {
        textAssert("textMatchesNot", verb: "textMatchesNot", selector: selector,
                   expected: pattern, timeout: timeout, requireVisible: false,
                   operatorText: "!=", held: matched, strict: strict, file: file, line: line)
        return self
    }

    // MARK: value 系

    @discardableResult
    public func valueIsNot(_ expected: String, timeout: Double? = nil,
                           strict: Bool = false,
                       file: StaticString = #filePath, line: UInt = #line) -> FTElement {
        textAssert("valueNotEquals", verb: "valueIsNot", selector: selector, expected: expected,
                   timeout: timeout, requireVisible: false, operatorText: "!=",
                   held: matched, strict: strict, file: file, line: line)
        return self
    }

    @discardableResult
    public func valueContains(_ expected: String, timeout: Double? = nil,
                              requireVisible: Bool = true,
                              strict: Bool = false,
                       file: StaticString = #filePath, line: UInt = #line) -> FTElement {
        textAssert("valueContains", verb: "valueContains", selector: selector, expected: expected,
                   timeout: timeout, requireVisible: requireVisible, held: matched, strict: strict, file: file, line: line)
        return self
    }

    @discardableResult
    public func valueStartsWith(_ expected: String, timeout: Double? = nil,
                                requireVisible: Bool = true,
                                strict: Bool = false,
                       file: StaticString = #filePath, line: UInt = #line) -> FTElement {
        textAssert("valueStartsWith", verb: "valueStartsWith", selector: selector,
                   expected: expected, timeout: timeout, requireVisible: requireVisible,
                   held: matched, strict: strict, file: file, line: line)
        return self
    }

    @discardableResult
    public func valueEndsWith(_ expected: String, timeout: Double? = nil,
                              requireVisible: Bool = true,
                              strict: Bool = false,
                       file: StaticString = #filePath, line: UInt = #line) -> FTElement {
        textAssert("valueEndsWith", verb: "valueEndsWith", selector: selector, expected: expected,
                   timeout: timeout, requireVisible: requireVisible, held: matched, strict: strict, file: file, line: line)
        return self
    }

    @discardableResult
    public func valueMatches(_ pattern: String, timeout: Double? = nil,
                             requireVisible: Bool = true,
                             strict: Bool = false,
                       file: StaticString = #filePath, line: UInt = #line) -> FTElement {
        textAssert("valueMatches", verb: "valueMatches", selector: selector, expected: pattern,
                   timeout: timeout, requireVisible: requireVisible, held: matched, strict: strict, file: file, line: line)
        return self
    }

    @discardableResult
    public func valueMatchesDateFormat(_ format: String, timeout: Double? = nil,
                                       requireVisible: Bool = true,
                                       file: StaticString = #filePath, line: UInt = #line) -> FTElement {
        textAssert("valueMatchesDateFormat", verb: "valueMatchesDateFormat", selector: selector,
                   expected: format, timeout: timeout, requireVisible: requireVisible,
                   operatorText: "~", held: matched, file: file, line: line)
        return self
    }

    @discardableResult
    public func valueStartsWithNot(_ expected: String, timeout: Double? = nil,
                                   strict: Bool = false,
                       file: StaticString = #filePath, line: UInt = #line) -> FTElement {
        textAssert("valueStartsWithNot", verb: "valueStartsWithNot", selector: selector,
                   expected: expected, timeout: timeout, requireVisible: false,
                   operatorText: "!=", held: matched, strict: strict, file: file, line: line)
        return self
    }

    @discardableResult
    public func valueContainsNot(_ expected: String, timeout: Double? = nil,
                                 strict: Bool = false,
                       file: StaticString = #filePath, line: UInt = #line) -> FTElement {
        textAssert("valueContainsNot", verb: "valueContainsNot", selector: selector,
                   expected: expected, timeout: timeout, requireVisible: false,
                   operatorText: "!=", held: matched, strict: strict, file: file, line: line)
        return self
    }

    @discardableResult
    public func valueEndsWithNot(_ expected: String, timeout: Double? = nil,
                                 strict: Bool = false,
                       file: StaticString = #filePath, line: UInt = #line) -> FTElement {
        textAssert("valueEndsWithNot", verb: "valueEndsWithNot", selector: selector,
                   expected: expected, timeout: timeout, requireVisible: false,
                   operatorText: "!=", held: matched, strict: strict, file: file, line: line)
        return self
    }

    @discardableResult
    public func valueMatchesNot(_ pattern: String, timeout: Double? = nil,
                                strict: Bool = false,
                       file: StaticString = #filePath, line: UInt = #line) -> FTElement {
        textAssert("valueMatchesNot", verb: "valueMatchesNot", selector: selector,
                   expected: pattern, timeout: timeout, requireVisible: false,
                   operatorText: "!=", held: matched, strict: strict, file: file, line: line)
        return self
    }

    @discardableResult
    public func valueIsEmpty(timeout: Double? = nil,
                             strict: Bool = false,
                       file: StaticString = #filePath, line: UInt = #line) -> FTElement {
        emptyAssert("valueIsEmpty", verb: "valueIsEmpty", selector: selector,
                    timeout: timeout, held: matched, strict: strict, file: file, line: line)
        return self
    }

    @discardableResult
    public func valueIsNotEmpty(timeout: Double? = nil,
                                strict: Bool = false,
                       file: StaticString = #filePath, line: UInt = #line) -> FTElement {
        emptyAssert("valueIsNotEmpty", verb: "valueIsNotEmpty", selector: selector,
                    timeout: timeout, held: matched, strict: strict, file: file, line: line)
        return self
    }

    // MARK: 状態

    @discardableResult
    public func enabledIsTrue(timeout: Double? = nil,
                          file: StaticString = #filePath, line: UInt = #line) -> FTElement {
        enabledAssert("enabled", verb: "enabledIsTrue", selector: selector,
                      timeout: timeout, held: matched, file: file, line: line)
        return self
    }

    @discardableResult
    public func enabledIsFalse(timeout: Double? = nil,
                           file: StaticString = #filePath, line: UInt = #line) -> FTElement {
        enabledAssert("disabled", verb: "enabledIsFalse", selector: selector,
                      timeout: timeout, held: matched, file: file, line: line)
        return self
    }

    @discardableResult
    public func checkIsON(timeout: Double? = nil,
                          file: StaticString = #filePath, line: UInt = #line) -> FTElement {
        enabledAssert("checked", verb: "checkIsON", selector: selector,
                      timeout: timeout, held: matched, file: file, line: line)
        return self
    }

    @discardableResult
    public func checkIsOFF(timeout: Double? = nil,
                             file: StaticString = #filePath, line: UInt = #line) -> FTElement {
        enabledAssert("notChecked", verb: "checkIsOFF", selector: selector,
                      timeout: timeout, held: matched, file: file, line: line)
        return self
    }
}
