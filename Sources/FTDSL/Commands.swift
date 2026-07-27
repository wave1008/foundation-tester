// ユーザーが書く DSL コマンド(モジュールレベル自由関数)。
// 全て同期・非 throw。カレント実行コンテキスト(FTRuntime)を暗黙参照するので
// レシーバも `try await` も不要:
//
//     scenario {
//         scene(1, "正しい認証情報でログインできる") {
//             condition { launchApp() }
//             .action { type("#email", "a@b.c"); tap("#login_btn||ログイン") }
//             .expectation { exist("ようこそ") }
//         }
//     }
//
// セレクタを取るコマンドは**文字列版と型付き版(Sel)を1対1で併設**する。両者は同じ FTSelector に
// 畳んでから共通の impl を通るので、記録・失敗セマンティクス・ヒールは完全に同一
// (型付き版の書き方は Sel.swift)。
//
// 失敗セマンティクス: コマンド NG → 同一 scene 内の以降のコマンドは自動スキップ(記録あり)。
// ブロック内の生 Swift コードはスキップされないため、失敗後に走らせたくない処理は procedure { } に包む。

import Foundation
import FTCore

// MARK: - 構造(scenario / scene / CAE)

public func scenario(_ body: () -> Void) {
    _ = FTRuntime.requireCore(command: "scenario")
    body()
}

/// case は Swift 予約語のため scene と命名
public func scene(_ number: Int, _ title: String = "", _ body: () -> Void) {
    FTRuntime.requireCore(command: "scene").runScene(number, title, body)
}

/// CAE チェーン: condition { }.action { }.expectation { }
public struct CAEChain {
    @discardableResult
    public func condition(_ body: () -> Void) -> CAEChain {
        FTRuntime.requireCore(command: "condition").runSection("condition", body)
        return self
    }

    @discardableResult
    public func action(_ body: () -> Void) -> CAEChain {
        FTRuntime.requireCore(command: "action").runSection("action", body)
        return self
    }

    @discardableResult
    public func expectation(_ body: () -> Void) -> CAEChain {
        FTRuntime.requireCore(command: "expectation").runSection("expectation", body)
        return self
    }
}

@discardableResult
public func condition(_ body: () -> Void) -> CAEChain { CAEChain().condition(body) }

@discardableResult
public func action(_ body: () -> Void) -> CAEChain { CAEChain().action(body) }

@discardableResult
public func expectation(_ body: () -> Void) -> CAEChain { CAEChain().expectation(body) }

/// **出たら閉じてほしいアプリ内メッセージ**を宣言する(お知らせダイアログ・キャンペーン等)。
/// setUp か scenario の冒頭で1回書けば、以降どのステップでも出た時点で自動的に閉じる
/// (各所に `ifCanSelect` を撒く必要がなくなる)。
///
///     onInterrupt("#promo_modal", dismiss: "#btn_promo_close")
///     onInterrupt("#btn_announce_close")   // 検出したものをそのままタップする場合
///
/// **閉じ方はアプリ作者しか知らない**のでツールは推測しない = 宣言が無ければ何もしない。
/// 閉じたことは必ずステップの注記に残る(黙って閉じると、出続けている異常に気付けないため)。
/// 追加のスナップショットは取らない(操作前に持っているものへ照合するだけ)ので正常系のコストはゼロ。
/// **OS 側のダイアログ(権限・IME の案内等)はここに書かない** — ツール側で吸収する範囲
public func onInterrupt(_ detect: String, dismiss: String? = nil) {
    let core = FTRuntime.requireCore(command: "onInterrupt")
    let detectSelector = FTSelector.parse(detect)
    let dismissSelector = dismiss.map { FTSelector.parse($0) } ?? detectSelector
    core.addInterruptHandler(detect: detectSelector.primary, dismiss: dismissSelector.primary)
}

public func onInterrupt(_ detect: Sel, dismiss: Sel? = nil) {
    let core = FTRuntime.requireCore(command: "onInterrupt")
    core.addInterruptHandler(detect: detect.ftSelector.primary,
                             dismiss: (dismiss ?? detect).ftSelector.primary)
}

/// scene 失敗時に後続 scene も実行しない(データ依存の scene 連鎖用)
public func abortScenarioOnFailure(_ enabled: Bool = true) {
    FTRuntime.requireCore(command: "abortScenarioOnFailure").abortScenarioOnSceneFailure = enabled
}

// MARK: - セレクタを取るコマンドの共通経路

extension FTSelector {
    /// FlowStep のフォールバック欄(空なら nil = 既存の JSON 表現を保つ)
    var stepFallbacks: [FlowLocator]? { fallbacks.isEmpty ? nil : fallbacks }
}

/// 型付きセレクタ由来なら構文検証を飛ばす(FTSelector.structured)
@discardableResult
private func perform(_ command: String, _ selector: FTSelector, step: FlowStep,
                     description: String,
                     file: StaticString, line: UInt) -> StepResult.Status {
    FTRuntime.requireCore(command: command)
        .perform(step: step, description: description, selectorText: selector.text,
                 validateSelector: !selector.structured, file: file, line: line)
}

// MARK: - 操作コマンド

/// timeout: 要素解決を待つ上限秒(0 = 初回スナップショットのみ。出るか不定な optional の
/// 空振り ~0.7s を数十msに短縮)。省略時は既定の再試行(約0.7秒)
/// scroll: 指定するとタップ前に**その方向へスクロールしながら要素を探す**
/// (Shirates の tapWithScrollDown 相当。省略時は現在画面だけを見る)
public func tap(_ selector: String, optional: Bool = false, timeout: Int? = nil,
                scroll: FTSwipeDirection? = nil, maxSwipes: Int = FlowStep.defaultMaxSwipes,
                file: StaticString = #filePath, line: UInt = #line) {
    tapImpl(FTSelector.parse(selector), optional: optional, timeout: timeout,
            scroll: scroll, maxSwipes: maxSwipes, file: file, line: line)
}

public func tap(_ selector: Sel, optional: Bool = false, timeout: Int? = nil,
                scroll: FTSwipeDirection? = nil, maxSwipes: Int = FlowStep.defaultMaxSwipes,
                file: StaticString = #filePath, line: UInt = #line) {
    tapImpl(selector.ftSelector, optional: optional, timeout: timeout,
            scroll: scroll, maxSwipes: maxSwipes, file: file, line: line)
}

private func tapImpl(_ selector: FTSelector, optional: Bool, timeout: Int?,
                     scroll: FTSwipeDirection?, maxSwipes: Int,
                     file: StaticString, line: UInt) {
    scrollSearch(selector, direction: scroll, maxSwipes: maxSwipes, optional: optional,
                 file: file, line: line)
    let step = FlowStep(action: "tap", locator: selector.primary,
                        fallbacks: selector.stepFallbacks,
                        timeout: timeout, optional: optional ? true : nil)
    perform("tap", selector, step: step,
            description: "tap \"\(selector.text)\"" + (optional ? " (optional)" : ""),
            file: file, line: line)
}

/// `scroll:` 引数の共通実装。**別ステップとして** scrollTo を先に流す
/// (記録に「探した」ことを残し、失敗理由が「スクロールしても無い」と分かるようにする)。
/// optional は scrollTo にも伝える(空振りで scene を落とさないため。StepExecutor の
/// scrollTo 経路が同じ契約で skipped を返す)。
/// **説明文の末尾 `(探索)` は必須**: この1ステップはソース行を持たない(呼び出し元は
/// `tap(..., scroll:)` の1行)ため、StepCommandText.parse に解釈させてはいけない。
/// 解釈できるとステップ表からの編集が `tap(...)` 行を `scrollTo(...)` に書き換えてしまう
private func scrollSearch(_ selector: FTSelector, direction: FTSwipeDirection?, maxSwipes: Int,
                          optional: Bool, file: StaticString, line: UInt) {
    guard let direction else { return }
    let step = FlowStep(action: "scrollTo", locator: selector.primary,
                        fallbacks: selector.stepFallbacks,
                        direction: direction.rawValue, maxSwipes: maxSwipes,
                        optional: optional ? true : nil)
    perform("scrollTo", selector, step: step,
            description: "scrollTo \"\(selector.text)\" (探索)", file: file, line: line)
}

/// フォーカス中の要素にテキストを送信する(直前の tap でフォーカスした欄など。ロケータ指定なし)。
/// ref なし = ブリッジがフォーカス中要素へ入力する(StepExecutor がロケータ解決を挟まず driver.type(ref: nil) を呼ぶ)。
public func type(_ text: String, optional: Bool = false,
                 file: StaticString = #filePath, line: UInt = #line) {
    let step = FlowStep(action: "type", text: text, optional: optional ? true : nil)
    FTRuntime.requireCore(command: "type")
        .perform(step: step, description: "type \"\(text)\"", file: file, line: line)
}

/// timeout: 要素解決を待つ上限秒(0 = 初回スナップショットのみ。出るか不定な optional の
/// 空振り ~0.7s を数十msに短縮)。省略時は既定の再試行(約0.7秒)
public func type(_ selector: String, _ text: String, optional: Bool = false, timeout: Int? = nil,
                 file: StaticString = #filePath, line: UInt = #line) {
    typeImpl(FTSelector.parse(selector), text, optional: optional, timeout: timeout,
             file: file, line: line)
}

public func type(_ selector: Sel, _ text: String, optional: Bool = false, timeout: Int? = nil,
                 file: StaticString = #filePath, line: UInt = #line) {
    typeImpl(selector.ftSelector, text, optional: optional, timeout: timeout,
             file: file, line: line)
}

private func typeImpl(_ selector: FTSelector, _ text: String, optional: Bool, timeout: Int?,
                      file: StaticString, line: UInt) {
    let step = FlowStep(action: "type", locator: selector.primary,
                        fallbacks: selector.stepFallbacks,
                        text: text, timeout: timeout, optional: optional ? true : nil)
    perform("type", selector, step: step,
            description: "type \"\(selector.text)\" \"\(text)\"", file: file, line: line)
}

/// timeout: 要素解決を待つ上限秒(0 = 初回スナップショットのみ。出るか不定な optional の
/// 空振り ~0.7s を数十msに短縮)。省略時は既定の再試行(約0.7秒)
/// duration: 長押しする秒数
public func press(_ selector: String, duration: Double = FlowStep.defaultPressDuration,
                  optional: Bool = false, timeout: Int? = nil,
                  file: StaticString = #filePath, line: UInt = #line) {
    pressImpl(FTSelector.parse(selector), duration: duration, optional: optional, timeout: timeout,
              file: file, line: line)
}

public func press(_ selector: Sel, duration: Double = FlowStep.defaultPressDuration,
                  optional: Bool = false, timeout: Int? = nil,
                  file: StaticString = #filePath, line: UInt = #line) {
    pressImpl(selector.ftSelector, duration: duration, optional: optional, timeout: timeout,
              file: file, line: line)
}

private func pressImpl(_ selector: FTSelector, duration: Double, optional: Bool, timeout: Int?,
                       file: StaticString, line: UInt) {
    let step = FlowStep(action: "press", locator: selector.primary,
                        fallbacks: selector.stepFallbacks,
                        timeout: timeout,
                        // 既定値は載せない(生成コード・ヒールキャッシュを既定ケースで太らせない)
                        duration: duration == FlowStep.defaultPressDuration ? nil : duration,
                        optional: optional ? true : nil)
    perform("press", selector, step: step, description: "press \"\(selector.text)\"",
            file: file, line: line)
}

public func swipe(_ direction: FTSwipeDirection,
                  file: StaticString = #filePath, line: UInt = #line) {
    let step = FlowStep(action: "swipe", direction: direction.rawValue)
    FTRuntime.requireCore(command: "swipe")
        .perform(step: step, description: "swipe \(direction.rawValue)", file: file, line: line)
}

/// 要素が見つかるまでスクロールする(見つかったら成功。タップはしない)
public func scrollTo(_ selector: String, direction: FTSwipeDirection = .up,
                     maxSwipes: Int = FlowStep.defaultMaxSwipes,
                     file: StaticString = #filePath, line: UInt = #line) {
    scrollToImpl(FTSelector.parse(selector), direction: direction, maxSwipes: maxSwipes,
                 file: file, line: line)
}

public func scrollTo(_ selector: Sel, direction: FTSwipeDirection = .up,
                     maxSwipes: Int = FlowStep.defaultMaxSwipes,
                     file: StaticString = #filePath, line: UInt = #line) {
    scrollToImpl(selector.ftSelector, direction: direction, maxSwipes: maxSwipes,
                 file: file, line: line)
}

private func scrollToImpl(_ selector: FTSelector, direction: FTSwipeDirection, maxSwipes: Int,
                          file: StaticString, line: UInt) {
    let step = FlowStep(action: "scrollTo", locator: selector.primary,
                        fallbacks: selector.stepFallbacks,
                        direction: direction.rawValue, maxSwipes: maxSwipes)
    perform("scrollTo", selector, step: step, description: "scrollTo \"\(selector.text)\"",
            file: file, line: line)
}

// MARK: - 検証コマンド

/// 要素の存在検証。戻り値に .textIs / .valueIs をチェーンできる
/// (timeout 省略時は実行プロファイルの defaultTimeout、それも無ければ 5 秒)
/// 存在検証。既定で可視性も確認(= 実際に見えていることも確認): ツリー存在に加え、要素が別要素に
/// 覆われ/切れ/不在で見えていないかを FM で確認する(見えなければ失敗)。ツリー存在だけ見たい
/// (高速・アイコン等)場合は requireVisible: false。FM 未配線時は guard は素通り(存在のみと同じ)。
/// scroll: 指定すると検証前に**その方向へスクロールしながら要素を探す**
/// (Shirates の existWithScrollDown 相当。省略時は現在画面だけを見る)
@discardableResult
public func exist(_ selector: String, timeout: Int? = nil, requireVisible: Bool = true,
                  scroll: FTSwipeDirection? = nil, maxSwipes: Int = FlowStep.defaultMaxSwipes,
                  file: StaticString = #filePath, line: UInt = #line) -> FTElement {
    existImpl(FTSelector.parse(selector), timeout: timeout, requireVisible: requireVisible,
              scroll: scroll, maxSwipes: maxSwipes, file: file, line: line)
}

@discardableResult
public func exist(_ selector: Sel, timeout: Int? = nil, requireVisible: Bool = true,
                  scroll: FTSwipeDirection? = nil, maxSwipes: Int = FlowStep.defaultMaxSwipes,
                  file: StaticString = #filePath, line: UInt = #line) -> FTElement {
    existImpl(selector.ftSelector, timeout: timeout, requireVisible: requireVisible,
              scroll: scroll, maxSwipes: maxSwipes, file: file, line: line)
}

@discardableResult
private func existImpl(_ selector: FTSelector, timeout: Int?, requireVisible: Bool,
                       scroll: FTSwipeDirection?, maxSwipes: Int,
                       file: StaticString, line: UInt) -> FTElement {
    scrollSearch(selector, direction: scroll, maxSwipes: maxSwipes, optional: false,
                 file: file, line: line)
    let core = FTRuntime.requireCore(command: "exist")
    let step = FlowStep(assert: "exists", locator: selector.primary,
                        fallbacks: selector.stepFallbacks,
                        timeout: timeout ?? core.defaultTimeout, occlusionGuard: requireVisible)
    perform("exist", selector, step: step, description: "exist \"\(selector.text)\"",
            file: file, line: line)
    return FTElement(selector: selector)
}

/// テキスト一致検証。既定で可視性も確認(一致かつ実際に見えていること)。
/// 可視性を問わずテキスト一致だけ見たい場合は requireVisible: false。
public func textIs(_ selector: String, _ expected: String, timeout: Int? = nil,
                   requireVisible: Bool = true,
                   file: StaticString = #filePath, line: UInt = #line) {
    textAssert("textEquals", verb: "textIs", selector: FTSelector.parse(selector),
               expected: expected, timeout: timeout, requireVisible: requireVisible,
               operatorText: "==", file: file, line: line)
}

public func textIs(_ selector: Sel, _ expected: String, timeout: Int? = nil,
                   requireVisible: Bool = true,
                   file: StaticString = #filePath, line: UInt = #line) {
    textAssert("textEquals", verb: "textIs", selector: selector.ftSelector,
               expected: expected, timeout: timeout, requireVisible: requireVisible,
               operatorText: "==", file: file, line: line)
}

/// 値一致検証。既定で可視性も確認(一致かつ実際に見えていること)。
/// 可視性を問わず値一致だけ見たい場合は requireVisible: false。
public func valueIs(_ selector: String, _ expected: String, timeout: Int? = nil,
                    requireVisible: Bool = true,
                    file: StaticString = #filePath, line: UInt = #line) {
    textAssert("valueEquals", verb: "valueIs", selector: FTSelector.parse(selector),
               expected: expected, timeout: timeout, requireVisible: requireVisible,
               operatorText: "==", file: file, line: line)
}

public func valueIs(_ selector: Sel, _ expected: String, timeout: Int? = nil,
                    requireVisible: Bool = true,
                    file: StaticString = #filePath, line: UInt = #line) {
    textAssert("valueEquals", verb: "valueIs", selector: selector.ftSelector,
               expected: expected, timeout: timeout, requireVisible: requireVisible,
               operatorText: "==", file: file, line: line)
}

/// テキストの**部分一致**検証(動的な数値・日時を含む表示に使う)。
/// 完全一致は textIs。可視性の確認は「一致した部分文字列」で行う
public func textContains(_ selector: String, _ expected: String, timeout: Int? = nil,
                         requireVisible: Bool = true,
                         file: StaticString = #filePath, line: UInt = #line) {
    textAssert("textContains", verb: "textContains", selector: FTSelector.parse(selector),
               expected: expected, timeout: timeout, requireVisible: requireVisible,
               file: file, line: line)
}

public func textContains(_ selector: Sel, _ expected: String, timeout: Int? = nil,
                         requireVisible: Bool = true,
                         file: StaticString = #filePath, line: UInt = #line) {
    textAssert("textContains", verb: "textContains", selector: selector.ftSelector,
               expected: expected, timeout: timeout, requireVisible: requireVisible,
               file: file, line: line)
}

/// テキストの**前方一致**検証。可視性の確認は「一致した部分文字列」で行う
public func textStartsWith(_ selector: String, _ expected: String, timeout: Int? = nil,
                           requireVisible: Bool = true,
                           file: StaticString = #filePath, line: UInt = #line) {
    textAssert("textStartsWith", verb: "textStartsWith", selector: FTSelector.parse(selector),
               expected: expected, timeout: timeout, requireVisible: requireVisible,
               file: file, line: line)
}

public func textStartsWith(_ selector: Sel, _ expected: String, timeout: Int? = nil,
                           requireVisible: Bool = true,
                           file: StaticString = #filePath, line: UInt = #line) {
    textAssert("textStartsWith", verb: "textStartsWith", selector: selector.ftSelector,
               expected: expected, timeout: timeout, requireVisible: requireVisible,
               file: file, line: line)
}

/// テキストの**後方一致**検証。可視性の確認は「一致した部分文字列」で行う
public func textEndsWith(_ selector: String, _ expected: String, timeout: Int? = nil,
                         requireVisible: Bool = true,
                         file: StaticString = #filePath, line: UInt = #line) {
    textAssert("textEndsWith", verb: "textEndsWith", selector: FTSelector.parse(selector),
               expected: expected, timeout: timeout, requireVisible: requireVisible,
               file: file, line: line)
}

public func textEndsWith(_ selector: Sel, _ expected: String, timeout: Int? = nil,
                         requireVisible: Bool = true,
                         file: StaticString = #filePath, line: UInt = #line) {
    textAssert("textEndsWith", verb: "textEndsWith", selector: selector.ftSelector,
               expected: expected, timeout: timeout, requireVisible: requireVisible,
               file: file, line: line)
}

/// テキストが期待値と**一致しない**ことの検証(タイムアウトまで変化を待つ)。
/// 「その要素が無いこと」は notExist、「別の値になったこと」はこちら。
/// 否定なので**可視性は見ない**(見えていないことは画面照合できない)
public func textIsNot(_ selector: String, _ expected: String, timeout: Int? = nil,
                      file: StaticString = #filePath, line: UInt = #line) {
    textAssert("textNotEquals", verb: "textIsNot", selector: FTSelector.parse(selector),
               expected: expected, timeout: timeout, requireVisible: false,
               operatorText: "!=", file: file, line: line)
}

public func textIsNot(_ selector: Sel, _ expected: String, timeout: Int? = nil,
                      file: StaticString = #filePath, line: UInt = #line) {
    textAssert("textNotEquals", verb: "textIsNot", selector: selector.ftSelector,
               expected: expected, timeout: timeout, requireVisible: false,
               operatorText: "!=", file: file, line: line)
}

/// テキストが空であることの検証(要素は在ることが前提。タイムアウトまで変化を待つ)
public func textIsEmpty(_ selector: String, timeout: Int? = nil,
                        file: StaticString = #filePath, line: UInt = #line) {
    emptyAssert("textIsEmpty", verb: "textIsEmpty", selector: FTSelector.parse(selector),
                timeout: timeout, file: file, line: line)
}

public func textIsEmpty(_ selector: Sel, timeout: Int? = nil,
                        file: StaticString = #filePath, line: UInt = #line) {
    emptyAssert("textIsEmpty", verb: "textIsEmpty", selector: selector.ftSelector,
                timeout: timeout, file: file, line: line)
}

/// テキストが空でないことの検証(値は問わず「何か表示されている」ことだけを見る)
public func textIsNotEmpty(_ selector: String, timeout: Int? = nil,
                           file: StaticString = #filePath, line: UInt = #line) {
    emptyAssert("textIsNotEmpty", verb: "textIsNotEmpty", selector: FTSelector.parse(selector),
                timeout: timeout, file: file, line: line)
}

public func textIsNotEmpty(_ selector: Sel, timeout: Int? = nil,
                           file: StaticString = #filePath, line: UInt = #line) {
    emptyAssert("textIsNotEmpty", verb: "textIsNotEmpty", selector: selector.ftSelector,
                timeout: timeout, file: file, line: line)
}

/// textIsEmpty / textIsNotEmpty の共通実装(期待値を取らないアサート)
private func emptyAssert(_ assert: String, verb: String, selector: FTSelector, timeout: Int?,
                         file: StaticString, line: UInt) {
    let core = FTRuntime.requireCore(command: verb)
    let step = FlowStep(assert: assert, locator: selector.primary,
                        fallbacks: selector.stepFallbacks,
                        timeout: timeout ?? core.defaultTimeout)
    perform(verb, selector, step: step, description: "\(verb) \"\(selector.text)\"",
            file: file, line: line)
}

/// テキストの**正規表現一致**検証(部分一致。全体一致にしたいときは `^...$` を書く)。
/// 可視性の確認は「実際に一致した部分文字列」で行う(パターン文字列は画面に出ないため)
public func textMatches(_ selector: String, _ pattern: String, timeout: Int? = nil,
                        requireVisible: Bool = true,
                        file: StaticString = #filePath, line: UInt = #line) {
    textAssert("textMatches", verb: "textMatches", selector: FTSelector.parse(selector),
               expected: pattern, timeout: timeout, requireVisible: requireVisible,
               file: file, line: line)
}

public func textMatches(_ selector: Sel, _ pattern: String, timeout: Int? = nil,
                        requireVisible: Bool = true,
                        file: StaticString = #filePath, line: UInt = #line) {
    textAssert("textMatches", verb: "textMatches", selector: selector.ftSelector,
               expected: pattern, timeout: timeout, requireVisible: requireVisible,
               file: file, line: line)
}

/// textIs / valueIs / textContains / textMatches の共通実装。
/// operatorText は説明文の記号だけを分ける(完全一致系は `==`、部分一致系は `~`)
private func textAssert(_ assert: String, verb: String, selector: FTSelector, expected: String,
                        timeout: Int?, requireVisible: Bool, operatorText: String = "~",
                        file: StaticString, line: UInt) {
    let core = FTRuntime.requireCore(command: verb)
    let step = FlowStep(assert: assert, locator: selector.primary,
                        fallbacks: selector.stepFallbacks,
                        expected: expected, timeout: timeout ?? core.defaultTimeout,
                        occlusionGuard: requireVisible)
    perform(verb, selector, step: step,
            description: "\(verb) \"\(selector.text)\" \(operatorText) \"\(expected)\"",
            file: file, line: line)
}

/// 不在検証。**消えるまで待つ**(初回で不在なら即成功、在ればタイムアウトまで消滅を待つ)。
/// exist の裏返しであり、ダイアログ・ローディング・トーストが閉じたことの確認に使う。
/// 可視性(occlusion)は見ない — ツリーから消えたことが判定基準。
public func notExist(_ selector: String, timeout: Int? = nil,
                     file: StaticString = #filePath, line: UInt = #line) {
    notExistImpl(FTSelector.parse(selector), timeout: timeout, file: file, line: line)
}

public func notExist(_ selector: Sel, timeout: Int? = nil,
                     file: StaticString = #filePath, line: UInt = #line) {
    notExistImpl(selector.ftSelector, timeout: timeout, file: file, line: line)
}

private func notExistImpl(_ selector: FTSelector, timeout: Int?,
                          file: StaticString, line: UInt) {
    let core = FTRuntime.requireCore(command: "notExist")
    let step = FlowStep(assert: "notExists", locator: selector.primary,
                        fallbacks: selector.stepFallbacks,
                        timeout: timeout ?? core.defaultTimeout)
    perform("notExist", selector, step: step, description: "notExist \"\(selector.text)\"",
            file: file, line: line)
}

/// 要素が操作可能(enabled)であることの検証。タイムアウトまで状態変化を待つ
public func isEnabled(_ selector: String, timeout: Int? = nil,
                      file: StaticString = #filePath, line: UInt = #line) {
    enabledAssert("enabled", verb: "isEnabled", selector: FTSelector.parse(selector),
                  timeout: timeout, file: file, line: line)
}

public func isEnabled(_ selector: Sel, timeout: Int? = nil,
                      file: StaticString = #filePath, line: UInt = #line) {
    enabledAssert("enabled", verb: "isEnabled", selector: selector.ftSelector,
                  timeout: timeout, file: file, line: line)
}

/// 要素が操作不可(disabled)であることの検証。タイムアウトまで状態変化を待つ
public func isDisabled(_ selector: String, timeout: Int? = nil,
                       file: StaticString = #filePath, line: UInt = #line) {
    enabledAssert("disabled", verb: "isDisabled", selector: FTSelector.parse(selector),
                  timeout: timeout, file: file, line: line)
}

public func isDisabled(_ selector: Sel, timeout: Int? = nil,
                       file: StaticString = #filePath, line: UInt = #line) {
    enabledAssert("disabled", verb: "isDisabled", selector: selector.ftSelector,
                  timeout: timeout, file: file, line: line)
}

/// スイッチ・チェックボックス・ラジオが**オン**であることの検証。タイムアウトまで状態変化を待つ。
/// 取得元は iOS=accessibility の selected trait / Android=isChecked(ElementInfo.checked)。
/// **型が OS で揃わない要素(checkbox/radio)でも使える** — 状態は型と独立に取れるため
public func isChecked(_ selector: String, timeout: Int? = nil,
                      file: StaticString = #filePath, line: UInt = #line) {
    enabledAssert("checked", verb: "isChecked", selector: FTSelector.parse(selector),
                  timeout: timeout, file: file, line: line)
}

public func isChecked(_ selector: Sel, timeout: Int? = nil,
                      file: StaticString = #filePath, line: UInt = #line) {
    enabledAssert("checked", verb: "isChecked", selector: selector.ftSelector,
                  timeout: timeout, file: file, line: line)
}

/// スイッチ・チェックボックス・ラジオが**オフ**であることの検証。
/// 状態を持たない要素(ただのボタン等)も「オフ」として通る(ブリッジは true のときだけ送るため)
public func isNotChecked(_ selector: String, timeout: Int? = nil,
                         file: StaticString = #filePath, line: UInt = #line) {
    enabledAssert("notChecked", verb: "isNotChecked", selector: FTSelector.parse(selector),
                  timeout: timeout, file: file, line: line)
}

public func isNotChecked(_ selector: Sel, timeout: Int? = nil,
                         file: StaticString = #filePath, line: UInt = #line) {
    enabledAssert("notChecked", verb: "isNotChecked", selector: selector.ftSelector,
                  timeout: timeout, file: file, line: line)
}

/// enabled/disabled/checked/notChecked の共通実装(アサート名だけが違う)
private func enabledAssert(_ assert: String, verb: String, selector: FTSelector, timeout: Int?,
                           file: StaticString, line: UInt) {
    let core = FTRuntime.requireCore(command: verb)
    let step = FlowStep(assert: assert, locator: selector.primary,
                        fallbacks: selector.stepFallbacks,
                        timeout: timeout ?? core.defaultTimeout)
    perform(verb, selector, step: step, description: "\(verb) \"\(selector.text)\"",
            file: file, line: line)
}

/// 一致する要素の個数を検証する(リスト件数の確認など)。タイムアウトまで個数の変化を待つ。
/// `||` は**候補集合の和**を数える(Shirates 準拠。同じ要素が複数の節にマッチしても1度だけ)。
/// スコープと併用すると容器の中だけ数えられる:
/// countIs("#list >> .Cell", 3)
public func countIs(_ selector: String, _ expected: Int, timeout: Int? = nil,
                    file: StaticString = #filePath, line: UInt = #line) {
    countIsImpl(FTSelector.parse(selector), expected, timeout: timeout, file: file, line: line)
}

public func countIs(_ selector: Sel, _ expected: Int, timeout: Int? = nil,
                    file: StaticString = #filePath, line: UInt = #line) {
    countIsImpl(selector.ftSelector, expected, timeout: timeout, file: file, line: line)
}

private func countIsImpl(_ selector: FTSelector, _ expected: Int, timeout: Int?,
                         file: StaticString, line: UInt) {
    let core = FTRuntime.requireCore(command: "countIs")
    let step = FlowStep(assert: "count", locator: selector.primary,
                        fallbacks: selector.stepFallbacks,
                        timeout: timeout ?? core.defaultTimeout, expectedCount: expected)
    perform("countIs", selector, step: step,
            description: "countIs \"\(selector.text)\" == \(expected)", file: file, line: line)
}

/// 画面全体の検証(自然言語+Foundation Models のマルチモーダル判定)
public func screenIs(_ expected: String,
                     file: StaticString = #filePath, line: UInt = #line) {
    let step = FlowStep(assert: "screenMatches", expected: expected)
    FTRuntime.requireCore(command: "screenIs")
        .perform(step: step, description: "screenIs \"\(expected)\"", file: file, line: line)
}

/// exist の戻り値。検証をチェーンできる
public struct FTElement {
    let selector: FTSelector

    @discardableResult
    public func textIs(_ expected: String, timeout: Int? = nil, requireVisible: Bool = true,
                       file: StaticString = #filePath, line: UInt = #line) -> FTElement {
        textAssert("textEquals", verb: "textIs", selector: selector, expected: expected,
                   timeout: timeout, requireVisible: requireVisible, operatorText: "==",
                   file: file, line: line)
        return self
    }

    @discardableResult
    public func valueIs(_ expected: String, timeout: Int? = nil, requireVisible: Bool = true,
                        file: StaticString = #filePath, line: UInt = #line) -> FTElement {
        textAssert("valueEquals", verb: "valueIs", selector: selector, expected: expected,
                   timeout: timeout, requireVisible: requireVisible, operatorText: "==",
                   file: file, line: line)
        return self
    }

    @discardableResult
    public func textStartsWith(_ expected: String, timeout: Int? = nil,
                               requireVisible: Bool = true,
                               file: StaticString = #filePath, line: UInt = #line) -> FTElement {
        textAssert("textStartsWith", verb: "textStartsWith", selector: selector,
                   expected: expected, timeout: timeout, requireVisible: requireVisible,
                   file: file, line: line)
        return self
    }

    @discardableResult
    public func textEndsWith(_ expected: String, timeout: Int? = nil,
                             requireVisible: Bool = true,
                             file: StaticString = #filePath, line: UInt = #line) -> FTElement {
        textAssert("textEndsWith", verb: "textEndsWith", selector: selector,
                   expected: expected, timeout: timeout, requireVisible: requireVisible,
                   file: file, line: line)
        return self
    }

    @discardableResult
    public func textIsNot(_ expected: String, timeout: Int? = nil,
                          file: StaticString = #filePath, line: UInt = #line) -> FTElement {
        textAssert("textNotEquals", verb: "textIsNot", selector: selector, expected: expected,
                   timeout: timeout, requireVisible: false, operatorText: "!=",
                   file: file, line: line)
        return self
    }

    @discardableResult
    public func textIsNotEmpty(_ timeout: Int? = nil,
                               file: StaticString = #filePath, line: UInt = #line) -> FTElement {
        emptyAssert("textIsNotEmpty", verb: "textIsNotEmpty", selector: selector,
                    timeout: timeout, file: file, line: line)
        return self
    }
}

// MARK: - アプリ制御

/// アプリを起動する(引数省略時は @TestClass の app)
public func launchApp(_ bundleID: String? = nil,
                      file: StaticString = #filePath, line: UInt = #line) {
    let core = FTRuntime.requireCore(command: "launchApp")
    let bundle = bundleID ?? core.appBundleID
    let driver = core.driver
    core.performCustom(description: "launch \(bundle)", file: file, line: line,
                       abortsScenario: true) {
        try await driver.launch(bundleID: bundle)
    }
}

/// アプリを終了してから起動し直す(scene 間の状態リセット用)
public func relaunchApp(_ bundleID: String? = nil,
                        file: StaticString = #filePath, line: UInt = #line) {
    let core = FTRuntime.requireCore(command: "relaunchApp")
    let bundle = bundleID ?? core.appBundleID
    let driver = core.driver
    core.performCustom(description: "relaunch \(bundle)", file: file, line: line,
                       abortsScenario: true) {
        try? await driver.terminate()
        try await driver.launch(bundleID: bundle)
    }
}

public func terminateApp(file: StaticString = #filePath, line: UInt = #line) {
    let core = FTRuntime.requireCore(command: "terminateApp")
    let driver = core.driver
    core.performCustom(description: "terminate", file: file, line: line) {
        try await driver.terminate()
    }
}

/// ホーム画面へ戻る
public func home(file: StaticString = #filePath, line: UInt = #line) {
    let core = FTRuntime.requireCore(command: "home")
    let driver = core.driver
    core.performCustom(description: "home", file: file, line: line) {
        try await driver.home()
    }
}

/// アプリスイッチャー(タスク一覧)を開く
public func appSwitcher(file: StaticString = #filePath, line: UInt = #line) {
    let core = FTRuntime.requireCore(command: "appSwitcher")
    let driver = core.driver
    core.performCustom(description: "appSwitcher", file: file, line: line) {
        try await driver.openAppSwitcher()
    }
}

/// 固定秒数待つ(記録に残る)
public func wait(_ seconds: Double,
                 file: StaticString = #filePath, line: UInt = #line) {
    FTRuntime.requireCore(command: "wait")
        .performCustom(description: "wait \(seconds)s", file: file, line: line) {
            try await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
        }
}

// MARK: - 分岐・任意コード

/// セレクタが解決できる場合のみブロックを実行する(出るかどうか不定なダイアログ処理用)。
/// 戻り値の .ifElse { } で不成立時の処理を書ける
@discardableResult
public func ifCanSelect(_ selector: String, waitSeconds: Int = 0,
                        file: StaticString = #filePath, line: UInt = #line,
                        _ body: () -> Void) -> FTBranch {
    ifCanSelectImpl(FTSelector.parse(selector), waitSeconds: waitSeconds,
                    file: file, line: line, body)
}

@discardableResult
public func ifCanSelect(_ selector: Sel, waitSeconds: Int = 0,
                        file: StaticString = #filePath, line: UInt = #line,
                        _ body: () -> Void) -> FTBranch {
    ifCanSelectImpl(selector.ftSelector, waitSeconds: waitSeconds, file: file, line: line, body)
}

@discardableResult
private func ifCanSelectImpl(_ selector: FTSelector, waitSeconds: Int,
                             file: StaticString, line: UInt,
                             _ body: () -> Void) -> FTBranch {
    let core = FTRuntime.requireCore(command: "ifCanSelect")
    // 構文誤りは「不成立」と区別できない(どちらもブロックを飛ばして緑になる)ため、
    // perform を通らないこのコマンドでも実行前に検証する
    if let error = validationError(selector) {
        let reason = "セレクタの構文が不正です: \(error)"
        core.recordStep(description: "ifCanSelect \"\(selector.text)\"", status: .failed(reason),
                        file: "\(file)", line: Int(line))
        core.handleFailure(stepDescription: "ifCanSelect \"\(selector.text)\"", reason: reason)
        return FTBranch(taken: false)
    }
    let found = core.canSelect(selector, waitSeconds: waitSeconds)
    // 不成立は **skipped** で記録する(passed にすると「セレクタが腐って毎回飛んでいる」状態が
    // 緑のまま見えなくなる)。run 終了時のサマリにも不成立を残す
    let description = "ifCanSelect \"\(selector.text)\" → \(found ? "実行" : "不成立")"
    core.recordStep(description: description,
                    status: found ? .passed : .skipped("条件不成立"),
                    file: "\(file)", line: Int(line))
    core.noteBranchOutcome(selector: selector.text, met: found)
    if found { body() }
    return FTBranch(taken: found)
}

/// 型付きセレクタは組み立て段階で綴りが保証されているので検証しない(FTSelector.structured)
private func validationError(_ selector: FTSelector) -> String? {
    selector.structured ? nil : FTSelector.validationError(selector.text)
}

public struct FTBranch {
    let taken: Bool

    /// 直前の分岐が不成立だった場合にブロックを実行する
    public func ifElse(_ body: () -> Void) {
        if !taken { body() }
    }
}

/// プラットフォームが iOS のときのみブロックを実行する
public func ios(_ body: () -> Void) {
    if FTRuntime.requireCore(command: "ios").platform == "ios" { body() }
}

/// プラットフォームが Android のときのみブロックを実行する
public func android(_ body: () -> Void) {
    if FTRuntime.requireCore(command: "android").platform == "android" { body() }
}

/// セレクタが解決できる限り本体を繰り返す(件数不定の一括操作用。上限 max 回)。
/// DSL にループが無いため、従来は「ガード付き反復を上限回数ぶん並べる」必要があった。
/// **各周回のステップ説明には `[名前 #n]` が前置される**(group と同じ記録規約)。
/// 上限に達しても失敗にはしない(消化しきれなかったことは記録に残る)。
/// 本体が要素を減らさないと上限まで空回りするので、max は想定最大件数に合わせる
public func repeatWhileCanSelect(_ selector: String, max: Int = 10, waitSeconds: Int = 0,
                                 title: String? = nil,
                                 file: StaticString = #filePath, line: UInt = #line,
                                 _ body: () -> Void) {
    repeatWhileCanSelectImpl(FTSelector.parse(selector), max: max, waitSeconds: waitSeconds,
                             title: title, file: file, line: line, body)
}

public func repeatWhileCanSelect(_ selector: Sel, max: Int = 10, waitSeconds: Int = 0,
                                 title: String? = nil,
                                 file: StaticString = #filePath, line: UInt = #line,
                                 _ body: () -> Void) {
    repeatWhileCanSelectImpl(selector.ftSelector, max: max, waitSeconds: waitSeconds,
                             title: title, file: file, line: line, body)
}

private func repeatWhileCanSelectImpl(_ selector: FTSelector, max: Int, waitSeconds: Int,
                                      title: String?,
                                      file: StaticString, line: UInt,
                                      _ body: () -> Void) {
    let core = FTRuntime.requireCore(command: "repeatWhileCanSelect")
    if let error = validationError(selector) {
        let reason = "セレクタの構文が不正です: \(error)"
        core.recordStep(description: "repeatWhileCanSelect \"\(selector.text)\"",
                        status: .failed(reason), file: "\(file)", line: Int(line))
        core.handleFailure(stepDescription: "repeatWhileCanSelect \"\(selector.text)\"",
                           reason: reason)
        return
    }
    let label = title ?? "repeat \"\(selector.text)\""
    var iterations = 0
    while iterations < max, core.canSelect(selector, waitSeconds: waitSeconds) {
        iterations += 1
        core.runGroup("\(label) #\(iterations)", body)
        // dry-run は canSelect が常に true を返すため、1 周だけ回してステップ列挙に留める
        if core.isDryRun { break }
    }
    core.recordStep(description: "repeatWhileCanSelect \"\(selector.text)\" → \(iterations) 回",
                    status: .passed, file: "\(file)", line: Int(line))
}

// MARK: - 共通ステップ・ライフサイクル

/// 複数コマンドを名前付きのまとまりとして記録する(ログイン手順などの共通サブルーチン用)。
/// 実行順・失敗セマンティクスは素のコマンド列と全く同じで、変わるのは記録の見え方だけ:
/// 内側のステップの説明に `[名前]` が前置される(入れ子は `[外/内]`)。
/// 再利用は普通の Swift 関数で行い、その中身をこれで包む。
public func group(_ title: String, _ body: () -> Void) {
    FTRuntime.requireCore(command: "group").runGroup(title, body)
}

/// @TestClass マクロが setUp() の呼び出しを包むために生成する(利用者が直接書くものではない)。
/// setUp 内の失敗はシナリオ全体を中断させる(前提が崩れた状態で本体を走らせない)。
public func ftRunSetUp(_ body: () -> Void) {
    FTRuntime.requireCore(command: "setUp").runLifecycle("setUp", allowAfterFailure: false, body)
}

/// @TestClass マクロが tearDown() の呼び出しを包むために生成する(利用者が直接書くものではない)。
/// **失敗後でも実行される**(片付けが飛ぶと後続シナリオを汚すため)。中断フラグは実行後に復元する。
public func ftRunTearDown(_ body: () -> Void) {
    FTRuntime.requireCore(command: "tearDown").runLifecycle("tearDown", allowAfterFailure: true, body)
}

/// 条件が満たされるまで任意の Swift コードを繰り返す(Shirates の doUntilTrue 相当)。
/// **アプリ側・外部の状態を待つためのもの**で、画面要素の出現待ちは各コマンドの `timeout:` を使う
/// (こちらは記録が1ステップに畳まれるため、要素待ちに使うと失敗時の情報が減る)。
/// action が true を返せば成功。waitSeconds 経過または maxLoopCount 到達で NG(scene 中断)。
/// action が throw した場合は**リトライせず**その場で NG にする(状態の待ちと実行時エラーを混ぜない)。
/// dry-run では body を実行せず1ステップとして記録するだけ(performCustom の既定動作)
public func doUntilTrue(_ title: String, waitSeconds: Double = 10, intervalSeconds: Double = 0.5,
                        maxLoopCount: Int = 100,
                        file: StaticString = #filePath, line: UInt = #line,
                        _ action: @escaping () async throws -> Bool) {
    FTRuntime.requireCore(command: "doUntilTrue")
        .performCustom(description: "doUntilTrue \"\(title)\"", file: file, line: line) {
            let deadline = Date().addingTimeInterval(waitSeconds)
            var loops = 0
            while true {
                if try await action() { return }
                loops += 1
                if loops >= maxLoopCount {
                    throw FTCommandError.message(
                        "doUntilTrue \"\(title)\" が上限 \(maxLoopCount) 回で成立しませんでした")
                }
                if Date() >= deadline {
                    throw FTCommandError.message(
                        "doUntilTrue \"\(title)\" が \(waitSeconds)s で成立しませんでした"
                        + "(\(loops) 回試行)")
                }
                try await Task.sleep(nanoseconds: UInt64(intervalSeconds * 1_000_000_000))
            }
        }
}

/// DSL コマンドが自前で NG にするときのエラー(メッセージがそのままステップの失敗理由になる)
enum FTCommandError: LocalizedError {
    case message(String)

    var errorDescription: String? {
        switch self {
        case .message(let text): return text
        }
    }
}

/// 任意の Swift コード(データセットアップ等)を 1 ステップとして実行・記録する。
/// クロージャ内では try / await が使える。throw は NG として記録され scene を中断する
public func procedure(_ title: String,
                      file: StaticString = #filePath, line: UInt = #line,
                      _ body: @escaping () async throws -> Void) {
    FTRuntime.requireCore(command: "procedure")
        .performCustom(description: "procedure \"\(title)\"", file: file, line: line, body)
}
