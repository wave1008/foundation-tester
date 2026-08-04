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
/// Shirates の**イレギュラーハンドラー**(TestContext.irregularHandler)に相当する。
/// 以降どのステップでも、出た時点で閉じてから本来の操作を続ける(アクションでも検証でも効く。
/// 各所に `ifCanSelect` を撒く必要がなくなる)。
/// **宣言の寿命はシナリオ1本**なので `setUp()` に書くのが定石(各 `@Test` の前に自動で入る)。
///
///     irregularHandler("#promo_modal", dismiss: "#btn_promo_close")
///     irregularHandler("#btn_announce_close")   // 検出したものをそのままタップする場合
///
/// **閉じ方はアプリ作者しか知らない**のでツールは推測しない = 宣言が無ければ何もしない。
/// 閉じたことは必ずステップの注記に残る(黙って閉じると、出続けている異常に気付けないため)。
/// 追加のスナップショットは取らない(操作前に持っているものへ照合するだけ)ので正常系のコストはゼロ。
/// **OS 側のダイアログ(権限・IME の案内等)はここに書かない** — ツール側で吸収する範囲
public func irregularHandler(_ detect: String, dismiss: String? = nil) {
    let core = FTRuntime.requireCore(command: "irregularHandler")
    let detectSelector = FTSelector.parse(detect)
    let dismissSelector = dismiss.map { FTSelector.parse($0) } ?? detectSelector
    core.addInterruptHandler(detect: detectSelector.primary, dismiss: dismissSelector.primary)
}

public func irregularHandler(_ detect: Sel, dismiss: Sel? = nil) {
    let core = FTRuntime.requireCore(command: "irregularHandler")
    core.addInterruptHandler(detect: detect.ftSelector.primary,
                             dismiss: (dismiss ?? detect).ftSelector.primary)
}

// MARK: - セレクタを取るコマンドの共通経路

extension FTSelector {
    /// FlowStep のフォールバック欄(空なら nil = 既存の JSON 表現を保つ)
    var stepFallbacks: [FlowLocator]? { fallbacks.isEmpty ? nil : fallbacks }
}

/// 実行前の検証は FTSelector.preflightError に集約(文字列=構文検証 / 型付き=組み立て時の誤り)。
/// 戻り値は status に加え**照合済み要素**も運ぶ(exist 系だけが使い、他は status のみ見て捨てる)。
/// **暗黙保持(`lastElement`)の唯一の更新点でもある** —— セレクタを取るコマンドは全部ここを通るので、
/// 個々のコマンドへ書き足す必要が無い(足し忘れが「更新されるコマンド」の一貫性を壊す)
/// held: FTElement のチェーンだけが渡す「既に掴んである要素」。満たしていればデバイスを見ない
/// (FTDriveCore.perform の高速経路)
@discardableResult
private func perform(_ command: String, _ selector: FTSelector, step: FlowStep,
                     description: String, held: ElementInfo? = nil,
                     file: StaticString, line: UInt) -> PerformResult {
    let core = FTRuntime.requireCore(command: command)
    let result = core.perform(step: step, description: description, selectorText: selector.text,
                              selectorError: selector.preflightError, heldElement: held,
                              file: file, line: line)
    if definesSingleElement(step) {
        core.lastResolvedElement = FTElement(selector: selector, matched: result.element)
    }
    return result
}

/// `lastElement` を差し替えるステップか。**要素を1つに定めないもの**(不在・個数)は差し替えない
/// = 直前に掴んだ要素をそのまま残す(`notExist` は「何も掴んでいない」であって
/// 「掴めなかった」ではないため。Shirates も dontExist で lastElement を差し替えない)。
/// ここを通るのはセレクタを取るコマンドだけなので locator の有無は見ない
/// (セレクタを取らない `swipe` / `launchApp` 等は core.perform を直接呼ぶ = 差し替わらない)
private func definesSingleElement(_ step: FlowStep) -> Bool {
    step.assert != "notExists" && step.assert != "count"
}

// MARK: - 操作コマンド

/// timeout: 要素解決を待つ上限秒(0 = 初回スナップショットのみ。出るか不定の要素を
/// `ifCanSelect` で見るときの空振り ~0.7s を数十msに短縮)。省略時は既定の再試行(約0.7秒)
/// scroll: 指定するとタップ前に**その方向へスクロールしながら要素を探す**
/// (Shirates の tapWithScrollDown 相当。省略時は現在画面だけを見る)。
/// 方向は**コンテンツ基準**(標準用語どおり `.down` = 下に読み進める。Shirates の ScrollDirection と同じ)
public func tap(_ selector: String, holdSeconds: Double = FlowStep.defaultTapHoldSeconds,
                timeout: Double? = nil,
                scroll: FTScrollDirection? = nil, maxSwipes: Int = FlowStep.defaultMaxSwipes,
                file: StaticString = #filePath, line: UInt = #line) {
    tapImpl(FTSelector.parse(selector), holdSeconds: holdSeconds, timeout: timeout,
            scroll: scroll, maxSwipes: maxSwipes, file: file, line: line)
}

public func tap(_ selector: Sel, holdSeconds: Double = FlowStep.defaultTapHoldSeconds,
                timeout: Double? = nil,
                scroll: FTScrollDirection? = nil, maxSwipes: Int = FlowStep.defaultMaxSwipes,
                file: StaticString = #filePath, line: UInt = #line) {
    tapImpl(selector.ftSelector, holdSeconds: holdSeconds, timeout: timeout,
            scroll: scroll, maxSwipes: maxSwipes, file: file, line: line)
}

/// `scroll:` は**同じステップに畳む**(別の scrollTo ステップを作らない)。
/// 利用者が書いたのは1コマンドなので記録も1行にする — 書いていない行が現れると、
/// その行はソース行を持たないためジャンプも修正提案の照合もできず、説明の要る状態になる。
/// `withScrollDown(scrollFrame:) { }` が積んだスクロール領域を FlowStep 用に解決する。
/// **探索するときだけ意味を持つ**(scroll 未指定 = 現在画面だけを見るので領域は無関係)
private func contextScrollFrame(_ core: FTDriveCore, scrolling: Bool) -> FlowLocator? {
    guard scrolling, let expression = core.effectiveScrollFrame(nil) else { return nil }
    return FTSelector.parse(expression).primary
}

/// 探索の実体は StepExecutor.runScrollSearch(scrollTo コマンドと共有)
private func tapImpl(_ selector: FTSelector, holdSeconds: Double, timeout: Double?,
                     scroll: FTScrollDirection?, maxSwipes: Int,
                     file: StaticString, line: UInt) {
    let core = FTRuntime.requireCore(command: "tap")
    let scroll = core.effectiveScroll(scroll)
    let step = FlowStep(action: "tap", locator: selector.primary,
                        fallbacks: selector.stepFallbacks,
                        direction: scroll?.swipe.rawValue,
                        timeout: timeout, maxSwipes: scroll == nil ? nil : maxSwipes,
                        // 既定(0 = 通常タップ)は載せない(生成コード・ヒールキャッシュを太らせない)
                        duration: holdSeconds == FlowStep.defaultTapHoldSeconds ? nil : holdSeconds,
                        scrollFrame: contextScrollFrame(core, scrolling: scroll != nil))
    let hold = holdSeconds == FlowStep.defaultTapHoldSeconds ? "" : " (hold \(FTSeconds.format(holdSeconds))s)"
    perform("tap", selector, step: step,
            description: "tap \"\(selector.text)\"" + hold,
            file: file, line: line)
}

/// フォーカス中の要素にテキストを送信する(直前の tap でフォーカスした欄など。ロケータ指定なし)。
/// ref なし = ブリッジがフォーカス中要素へ入力する(StepExecutor がロケータ解決を挟まず driver.type(ref: nil) を呼ぶ)。
/// **セレクタを渡す引数落としは実行前に落とす**(FTSelector.selectorLikeInputError)
public func type(_ text: String,
                 file: StaticString = #filePath, line: UInt = #line) {
    let step = FlowStep(action: "type", text: text)
    FTRuntime.requireCore(command: "type")
        .perform(step: step, description: "type \"\(text)\"",
                 commandError: FTSelector.selectorLikeInputError(text),
                 file: file, line: line)
}

/// フォーカス中の入力欄で Enter を押す(IME の改行/送信アクション相当。Shirates pressEnter 対応。
/// ref なし=ブリッジがフォーカス中要素へ作用する)。
public func pressEnter(file: StaticString = #filePath, line: UInt = #line) {
    let step = FlowStep(action: "pressEnter")
    FTRuntime.requireCore(command: "pressEnter")
        .perform(step: step, description: "pressEnter", file: file, line: line)
}

/// フォーカス中の入力欄を空にする(ref なし。ブリッジがフォーカス中要素へ作用する)。
public func clearInput(file: StaticString = #filePath, line: UInt = #line) {
    let step = FlowStep(action: "clearInput")
    FTRuntime.requireCore(command: "clearInput")
        .perform(step: step, description: "clearInput", file: file, line: line)
}

/// timeout: 要素解決を待つ上限秒(0 = 初回スナップショットのみ)。省略時は既定の再試行(約0.7秒)
public func type(_ selector: String, _ text: String, timeout: Double? = nil,
                 scroll: FTScrollDirection? = nil, maxSwipes: Int = FlowStep.defaultMaxSwipes,
                 file: StaticString = #filePath, line: UInt = #line) {
    typeImpl(FTSelector.parse(selector), text, timeout: timeout,
             scroll: scroll, maxSwipes: maxSwipes, file: file, line: line)
}

public func type(_ selector: Sel, _ text: String, timeout: Double? = nil,
                 scroll: FTScrollDirection? = nil, maxSwipes: Int = FlowStep.defaultMaxSwipes,
                 file: StaticString = #filePath, line: UInt = #line) {
    typeImpl(selector.ftSelector, text, timeout: timeout,
             scroll: scroll, maxSwipes: maxSwipes, file: file, line: line)
}

private func typeImpl(_ selector: FTSelector, _ text: String, timeout: Double?,
                      scroll: FTScrollDirection?, maxSwipes: Int,
                      file: StaticString, line: UInt) {
    let core = FTRuntime.requireCore(command: "type")
    let scroll = core.effectiveScroll(scroll)
    let step = FlowStep(action: "type", locator: selector.primary,
                        fallbacks: selector.stepFallbacks,
                        text: text, direction: scroll?.swipe.rawValue, timeout: timeout,
                        maxSwipes: scroll == nil ? nil : maxSwipes,
                        scrollFrame: contextScrollFrame(core, scrolling: scroll != nil))
    perform("type", selector, step: step,
            description: "type \"\(selector.text)\" \"\(text)\"", file: file, line: line)
}

/// timeout: 要素解決を待つ上限秒(0 = 初回スナップショットのみ)。省略時は既定の再試行(約0.7秒)
/// scroll: 指定するとクリア前に**その方向へスクロールしながら要素を探す**
public func clearInput(_ selector: String, timeout: Double? = nil,
                       scroll: FTScrollDirection? = nil, maxSwipes: Int = FlowStep.defaultMaxSwipes,
                       file: StaticString = #filePath, line: UInt = #line) {
    clearInputImpl(FTSelector.parse(selector), timeout: timeout,
                   scroll: scroll, maxSwipes: maxSwipes, file: file, line: line)
}

public func clearInput(_ selector: Sel, timeout: Double? = nil,
                       scroll: FTScrollDirection? = nil, maxSwipes: Int = FlowStep.defaultMaxSwipes,
                       file: StaticString = #filePath, line: UInt = #line) {
    clearInputImpl(selector.ftSelector, timeout: timeout,
                   scroll: scroll, maxSwipes: maxSwipes, file: file, line: line)
}

private func clearInputImpl(_ selector: FTSelector, timeout: Double?,
                            scroll: FTScrollDirection?, maxSwipes: Int,
                            file: StaticString, line: UInt) {
    let core = FTRuntime.requireCore(command: "clearInput")
    let scroll = core.effectiveScroll(scroll)
    let step = FlowStep(action: "clearInput", locator: selector.primary,
                        fallbacks: selector.stepFallbacks,
                        direction: scroll?.swipe.rawValue, timeout: timeout,
                        maxSwipes: scroll == nil ? nil : maxSwipes,
                        scrollFrame: contextScrollFrame(core, scrolling: scroll != nil))
    perform("clearInput", selector, step: step,
            description: "clearInput \"\(selector.text)\"",
            file: file, line: line)
}

public func swipe(_ direction: FTSwipeDirection,
                  file: StaticString = #filePath, line: UInt = #line) {
    let step = FlowStep(action: "swipe", direction: direction.rawValue)
    FTRuntime.requireCore(command: "swipe")
        .perform(step: step, description: "swipe \(direction.rawValue)", file: file, line: line)
}

/// 2点間ドラッグ(座標は snapshot の screen と同じ座標系。iOS = pt / Android = px)。
/// スライダー・並べ替え等、要素ではなく座標で操作したいときに使う。既定 1.5 秒は
/// Shirates(shirates-core Const.SWIPE_DURATION_SECONDS)準拠
public func swipePointToPoint(startX: Double, startY: Double, endX: Double, endY: Double,
                              durationSeconds: Double = FlowStep.defaultSwipeDurationSeconds,
                              file: StaticString = #filePath, line: UInt = #line) {
    let core = FTRuntime.requireCore(command: "swipePointToPoint")
    let driver = core.driver
    let typeDriver = core.executor.typeDriver
    core.performCustom(
        description: "swipePointToPoint (\(startX), \(startY)) → (\(endX), \(endY))",
        file: file, line: line) {
        do {
            try await driver.drag(fromX: startX, fromY: startY, toX: endX, toY: endY,
                                  pressSeconds: 0.05, durationSeconds: durationSeconds)
        } catch {
            // in-app エンジンは drag を一切実装しない(501)。hybrid では typeDriver(XCUITest)へ回す
            guard DriverError.isEngineIncapable(error), let typeDriver else { throw error }
            try await typeDriver.drag(fromX: startX, fromY: startY, toX: endX, toY: endY,
                                      pressSeconds: 0.05, durationSeconds: durationSeconds)
        }
    }
}

// MARK: - マップ系のジェスチャ(ピンチ・ダブルタップ・斜めパン)

/// **対象領域の中心を基点に、比率で指を動かす**(斜め可)。マップ・キャンバスのパン用。
/// 比率は対象の幅・高さに対する割合で、**符号は指の向き**(dxRatio > 0 = 指を右へ =
/// コンテンツは左へ動く。`swipe` と同じ規約)。対角に動かすには両方を非 0 にする。
/// 座標を直接指定したいときは `swipePointToPoint`(こちらは pt/px)。
///
///     swipeBy(dxRatio: -0.3, dyRatio: -0.3)          // 画面中心から左上へ
///     swipeBy("#map", dxRatio: 0.4, dyRatio: -0.2)   // その要素の中で右上へ
///
/// 既定の移動時間は `swipePointToPoint` と同じ 1.5 秒(**ゆっくり引くと慣性が乗らない**ので、
/// 移動量を読みたいマップのパンでは短くしない)
public func swipeBy(dxRatio: Double, dyRatio: Double,
                    durationSeconds: Double = FlowStep.defaultSwipeDurationSeconds,
                    file: StaticString = #filePath, line: UInt = #line) {
    let step = FlowStep(action: "swipeBy",
                        duration: durationSeconds == FlowStep.defaultSwipeDurationSeconds
                            ? nil : durationSeconds,
                        dxRatio: dxRatio, dyRatio: dyRatio)
    FTRuntime.requireCore(command: "swipeBy")
        .perform(step: step, description: "swipeBy (\(dxRatio), \(dyRatio))",
                 file: file, line: line)
}

public func swipeBy(_ selector: String, dxRatio: Double, dyRatio: Double,
                    durationSeconds: Double = FlowStep.defaultSwipeDurationSeconds,
                    timeout: Double? = nil,
                    file: StaticString = #filePath, line: UInt = #line) {
    swipeByImpl(FTSelector.parse(selector), dxRatio: dxRatio, dyRatio: dyRatio,
                durationSeconds: durationSeconds, timeout: timeout, file: file, line: line)
}

public func swipeBy(_ selector: Sel, dxRatio: Double, dyRatio: Double,
                    durationSeconds: Double = FlowStep.defaultSwipeDurationSeconds,
                    timeout: Double? = nil,
                    file: StaticString = #filePath, line: UInt = #line) {
    swipeByImpl(selector.ftSelector, dxRatio: dxRatio, dyRatio: dyRatio,
                durationSeconds: durationSeconds, timeout: timeout, file: file, line: line)
}

private func swipeByImpl(_ selector: FTSelector, dxRatio: Double, dyRatio: Double,
                         durationSeconds: Double, timeout: Double?,
                         file: StaticString, line: UInt) {
    let step = FlowStep(action: "swipeBy", locator: selector.primary,
                        fallbacks: selector.stepFallbacks, timeout: timeout,
                        duration: durationSeconds == FlowStep.defaultSwipeDurationSeconds
                            ? nil : durationSeconds,
                        dxRatio: dxRatio, dyRatio: dyRatio)
    perform("swipeBy", selector, step: step,
            description: "swipeBy \"\(selector.text)\" (\(dxRatio), \(dyRatio))",
            file: file, line: line)
}

/// ダブルタップ(マップの拡大・カード展開等)。セレクタ無しは**画面中心**。
/// **2回タップに分解しない**: ホスト↔ブリッジの往復が入ると OS のダブルタップ判定時間を
/// 超えて2回の単タップになる。ブリッジ側の1操作として撃つ
public func doubleTap(file: StaticString = #filePath, line: UInt = #line) {
    FTRuntime.requireCore(command: "doubleTap")
        .perform(step: FlowStep(action: "doubleTap"), description: "doubleTap",
                 file: file, line: line)
}

public func doubleTap(_ selector: String, timeout: Double? = nil,
                      file: StaticString = #filePath, line: UInt = #line) {
    doubleTapImpl(FTSelector.parse(selector), timeout: timeout, file: file, line: line)
}

public func doubleTap(_ selector: Sel, timeout: Double? = nil,
                      file: StaticString = #filePath, line: UInt = #line) {
    doubleTapImpl(selector.ftSelector, timeout: timeout, file: file, line: line)
}

private func doubleTapImpl(_ selector: FTSelector, timeout: Double?,
                           file: StaticString, line: UInt) {
    let step = FlowStep(action: "doubleTap", locator: selector.primary,
                        fallbacks: selector.stepFallbacks, timeout: timeout)
    perform("doubleTap", selector, step: step,
            description: "doubleTap \"\(selector.text)\"", file: file, line: line)
}

/// 2本指を開くピンチ = **拡大**(scale > 1)。セレクタ無しは画面全体が対象。
///
///     pinchOut()                    // 2倍に拡大
///     pinchOut("#map", scale: 3.0)  // その要素を対象に3倍
///
/// **iOS の XCUITest 経路では対象要素を identifier で引く**(座標指定の多点ジェスチャが無い)。
/// identifier の無い要素を指定した場合はアプリ全体のピンチに落ち、注記が残る。
/// Android と iOS の in-app は領域の中心で2本指を合成するので identifier に依らない。
/// **フレームワークとエンジンで成否が分かれる**組み合わせがある(表は docs/commands.md)
public func pinchOut(scale: Double = FlowStep.defaultPinchOutScale,
                     durationSeconds: Double = FlowStep.defaultPinchDurationSeconds,
                     file: StaticString = #filePath, line: UInt = #line) {
    pinchImpl(nil, action: "pinchOut", scale: scale, durationSeconds: durationSeconds,
              timeout: nil, file: file, line: line)
}

public func pinchOut(_ selector: String, scale: Double = FlowStep.defaultPinchOutScale,
                     durationSeconds: Double = FlowStep.defaultPinchDurationSeconds,
                     timeout: Double? = nil,
                     file: StaticString = #filePath, line: UInt = #line) {
    pinchImpl(FTSelector.parse(selector), action: "pinchOut", scale: scale,
              durationSeconds: durationSeconds, timeout: timeout, file: file, line: line)
}

public func pinchOut(_ selector: Sel, scale: Double = FlowStep.defaultPinchOutScale,
                     durationSeconds: Double = FlowStep.defaultPinchDurationSeconds,
                     timeout: Double? = nil,
                     file: StaticString = #filePath, line: UInt = #line) {
    pinchImpl(selector.ftSelector, action: "pinchOut", scale: scale,
              durationSeconds: durationSeconds, timeout: timeout, file: file, line: line)
}

/// 2本指を閉じるピンチ = **縮小**(0 < scale < 1)。対象の決め方は `pinchOut` と同じ
public func pinchIn(scale: Double = FlowStep.defaultPinchInScale,
                    durationSeconds: Double = FlowStep.defaultPinchDurationSeconds,
                    file: StaticString = #filePath, line: UInt = #line) {
    pinchImpl(nil, action: "pinchIn", scale: scale, durationSeconds: durationSeconds,
              timeout: nil, file: file, line: line)
}

public func pinchIn(_ selector: String, scale: Double = FlowStep.defaultPinchInScale,
                    durationSeconds: Double = FlowStep.defaultPinchDurationSeconds,
                    timeout: Double? = nil,
                    file: StaticString = #filePath, line: UInt = #line) {
    pinchImpl(FTSelector.parse(selector), action: "pinchIn", scale: scale,
              durationSeconds: durationSeconds, timeout: timeout, file: file, line: line)
}

public func pinchIn(_ selector: Sel, scale: Double = FlowStep.defaultPinchInScale,
                    durationSeconds: Double = FlowStep.defaultPinchDurationSeconds,
                    timeout: Double? = nil,
                    file: StaticString = #filePath, line: UInt = #line) {
    pinchImpl(selector.ftSelector, action: "pinchIn", scale: scale,
              durationSeconds: durationSeconds, timeout: timeout, file: file, line: line)
}

/// selector nil = 画面全体。倍率と向きの食い違い(pinchOut に scale < 1 等)は
/// StepExecutor が失敗にする(判定を1箇所に置く)
private func pinchImpl(_ selector: FTSelector?, action: String, scale: Double,
                       durationSeconds: Double, timeout: Double?,
                       file: StaticString, line: UInt) {
    let step = FlowStep(action: action, locator: selector?.primary,
                        fallbacks: selector?.stepFallbacks, timeout: timeout,
                        duration: durationSeconds == FlowStep.defaultPinchDurationSeconds
                            ? nil : durationSeconds,
                        scale: scale)
    let description = selector.map { "\(action) \"\($0.text)\" x\(scale)" } ?? "\(action) x\(scale)"
    guard let selector else {
        FTRuntime.requireCore(command: action)
            .perform(step: step, description: description, file: file, line: line)
        return
    }
    perform(action, selector, step: step, description: description, file: file, line: line)
}

/// 要素間のドラッグ(スライダー・並べ替え・部分領域のスクロール等、要素を掴んで動かす操作用)。
/// **終点(to)はヒール・自己修復の対象外**(始点だけが解決連鎖を持つ)
public func swipeElementToElement(_ from: String, _ to: String,
                                  durationSeconds: Double = FlowStep.defaultSwipeDurationSeconds,
                                  timeout: Double? = nil,
                                  file: StaticString = #filePath, line: UInt = #line) {
    swipeElementToElementImpl(FTSelector.parse(from), FTSelector.parse(to),
                              durationSeconds: durationSeconds, timeout: timeout,
                              file: file, line: line)
}

public func swipeElementToElement(_ from: Sel, _ to: Sel,
                                  durationSeconds: Double = FlowStep.defaultSwipeDurationSeconds,
                                  timeout: Double? = nil,
                                  file: StaticString = #filePath, line: UInt = #line) {
    swipeElementToElementImpl(from.ftSelector, to.ftSelector,
                              durationSeconds: durationSeconds, timeout: timeout,
                              file: file, line: line)
}

private func swipeElementToElementImpl(_ from: FTSelector, _ to: FTSelector,
                                       durationSeconds: Double, timeout: Double?,
                                       file: StaticString, line: UInt) {
    let step = FlowStep(action: "swipeElementToElement", locator: from.primary,
                        fallbacks: from.stepFallbacks, endLocator: to.primary,
                        timeout: timeout,
                        duration: durationSeconds == FlowStep.defaultSwipeDurationSeconds
                            ? nil : durationSeconds)
    perform("swipeElementToElement", from, step: step,
            description: "swipeElementToElement \"\(from.text)\" → \"\(to.text)\"",
            file: file, line: line)
}

// MARK: - フリック(Shirates 準拠のコマンド名。画面基点8種)

/// swipe/scroll と低レベル実装は同じ(等速の1ストローク・加速なし)だが、既定の
/// durationSeconds/intervalSeconds が短い(Shirates の FLICK_DURATION/INTERVAL_SECONDS 準拠)。
/// `scrollableElement` 引数は持たない(scrollFrame のセレクタ式で足りる)。
/// centerTo系4種は startMarginRatio を取らない(始点は常に中心)。
public func flickCenterToTop(scrollFrame: String? = nil,
                             durationSeconds: Double = FlowStep.defaultFlickDurationSeconds,
                             repeat times: Int = 1,
                             intervalSeconds: Double = FlowStep.defaultFlickIntervalSeconds,
                             file: StaticString = #filePath, line: UInt = #line) {
    flickImpl(.centerToTop, scrollFrame: scrollFrame, startMarginRatio: nil,
             durationSeconds: durationSeconds, times: times, intervalSeconds: intervalSeconds,
             file: file, line: line)
}

public func flickCenterToBottom(scrollFrame: String? = nil,
                                durationSeconds: Double = FlowStep.defaultFlickDurationSeconds,
                                repeat times: Int = 1,
                                intervalSeconds: Double = FlowStep.defaultFlickIntervalSeconds,
                                file: StaticString = #filePath, line: UInt = #line) {
    flickImpl(.centerToBottom, scrollFrame: scrollFrame, startMarginRatio: nil,
             durationSeconds: durationSeconds, times: times, intervalSeconds: intervalSeconds,
             file: file, line: line)
}

public func flickCenterToLeft(scrollFrame: String? = nil,
                              durationSeconds: Double = FlowStep.defaultFlickDurationSeconds,
                              repeat times: Int = 1,
                              intervalSeconds: Double = FlowStep.defaultFlickIntervalSeconds,
                              file: StaticString = #filePath, line: UInt = #line) {
    flickImpl(.centerToLeft, scrollFrame: scrollFrame, startMarginRatio: nil,
             durationSeconds: durationSeconds, times: times, intervalSeconds: intervalSeconds,
             file: file, line: line)
}

public func flickCenterToRight(scrollFrame: String? = nil,
                               durationSeconds: Double = FlowStep.defaultFlickDurationSeconds,
                               repeat times: Int = 1,
                               intervalSeconds: Double = FlowStep.defaultFlickIntervalSeconds,
                               file: StaticString = #filePath, line: UInt = #line) {
    flickImpl(.centerToRight, scrollFrame: scrollFrame, startMarginRatio: nil,
             durationSeconds: durationSeconds, times: times, intervalSeconds: intervalSeconds,
             file: file, line: line)
}

/// startMarginRatio 省略時は scrollRight 等と同じ既定(`FTScrollDefaults`。実測値 0.2)を使う ——
/// Shirates の 0.2 を別途持ち込まない(承認済み差分)
public func flickLeftToRight(scrollFrame: String? = nil,
                             startMarginRatio: Double? = nil,
                             durationSeconds: Double = FlowStep.defaultFlickDurationSeconds,
                             repeat times: Int = 1,
                             intervalSeconds: Double = FlowStep.defaultFlickIntervalSeconds,
                             file: StaticString = #filePath, line: UInt = #line) {
    flickImpl(.leftToRight, scrollFrame: scrollFrame, startMarginRatio: startMarginRatio,
             durationSeconds: durationSeconds, times: times, intervalSeconds: intervalSeconds,
             file: file, line: line)
}

public func flickRightToLeft(scrollFrame: String? = nil,
                             startMarginRatio: Double? = nil,
                             durationSeconds: Double = FlowStep.defaultFlickDurationSeconds,
                             repeat times: Int = 1,
                             intervalSeconds: Double = FlowStep.defaultFlickIntervalSeconds,
                             file: StaticString = #filePath, line: UInt = #line) {
    flickImpl(.rightToLeft, scrollFrame: scrollFrame, startMarginRatio: startMarginRatio,
             durationSeconds: durationSeconds, times: times, intervalSeconds: intervalSeconds,
             file: file, line: line)
}

public func flickBottomToTop(scrollFrame: String? = nil,
                             startMarginRatio: Double? = nil,
                             durationSeconds: Double = FlowStep.defaultFlickDurationSeconds,
                             repeat times: Int = 1,
                             intervalSeconds: Double = FlowStep.defaultFlickIntervalSeconds,
                             file: StaticString = #filePath, line: UInt = #line) {
    flickImpl(.bottomToTop, scrollFrame: scrollFrame, startMarginRatio: startMarginRatio,
             durationSeconds: durationSeconds, times: times, intervalSeconds: intervalSeconds,
             file: file, line: line)
}

public func flickTopToBottom(scrollFrame: String? = nil,
                             startMarginRatio: Double? = nil,
                             durationSeconds: Double = FlowStep.defaultFlickDurationSeconds,
                             repeat times: Int = 1,
                             intervalSeconds: Double = FlowStep.defaultFlickIntervalSeconds,
                             file: StaticString = #filePath, line: UInt = #line) {
    flickImpl(.topToBottom, scrollFrame: scrollFrame, startMarginRatio: startMarginRatio,
             durationSeconds: durationSeconds, times: times, intervalSeconds: intervalSeconds,
             file: file, line: line)
}

private let flickCommandNames: [FlickKind: String] = [
    .centerToTop: "flickCenterToTop", .centerToBottom: "flickCenterToBottom",
    .centerToLeft: "flickCenterToLeft", .centerToRight: "flickCenterToRight",
    .leftToRight: "flickLeftToRight", .rightToLeft: "flickRightToLeft",
    .bottomToTop: "flickBottomToTop", .topToBottom: "flickTopToBottom",
]

private func flickImpl(_ kind: FlickKind, scrollFrame: String?, startMarginRatio: Double?,
                       durationSeconds: Double, times: Int, intervalSeconds: Double,
                       file: StaticString, line: UInt) {
    let name = flickCommandNames[kind] ?? "flick"
    let core = FTRuntime.requireCore(command: name)
    let step = FlowStep(action: "flick", direction: kind.rawValue,
                        maxSwipes: max(1, times),
                        duration: durationSeconds == FlowStep.defaultFlickDurationSeconds
                            ? nil : durationSeconds,
                        scrollFrame: core.effectiveScrollFrame(scrollFrame).map(FTSelector.parse)?.primary,
                        startMarginRatio: startMarginRatio,
                        intervalSeconds: intervalSeconds == FlowStep.defaultFlickIntervalSeconds
                            ? nil : intervalSeconds)
    core.perform(step: step, description: name + (times > 1 ? " ×\(times)" : ""),
                file: file, line: line)
}

// MARK: - スクロール(Shirates 準拠のコマンド名)

/// 1回スクロールする(`repeat` 回ぶん繰り返す)。**コンテンツ基準**なので `scrollDown` は
/// 下に読み進める = 指は上へ動く。ftester のブリッジは全画面スワイプのみなので、
/// `scrollFrame` はスクロールさせたい領域のセレクタ式(Shirates と同じく式で受ける)。
/// **省略時は従来どおり画面中央基準の全画面スワイプ**で、マージン指定も無視される
/// (全画面固定のままスパンを変えると始点がスクロール領域の外に出る。design.md 参照)。
/// 時間指定(scrollDurationSeconds / scrollIntervalSeconds)は持たない(承認済み差分)
public func scrollDown(scrollFrame: String? = nil,
                       startMarginRatio: Double? = nil, endMarginRatio: Double? = nil,
                       repeat times: Int = 1,
                       file: StaticString = #filePath, line: UInt = #line) {
    scrollImpl(.down, scrollFrame: scrollFrame, startMarginRatio: startMarginRatio,
               endMarginRatio: endMarginRatio, times: times, file: file, line: line)
}

public func scrollUp(scrollFrame: String? = nil,
                     startMarginRatio: Double? = nil, endMarginRatio: Double? = nil,
                     repeat times: Int = 1,
                     file: StaticString = #filePath, line: UInt = #line) {
    scrollImpl(.up, scrollFrame: scrollFrame, startMarginRatio: startMarginRatio,
               endMarginRatio: endMarginRatio, times: times, file: file, line: line)
}

public func scrollRight(scrollFrame: String? = nil,
                        startMarginRatio: Double? = nil, endMarginRatio: Double? = nil,
                        repeat times: Int = 1,
                        file: StaticString = #filePath, line: UInt = #line) {
    scrollImpl(.right, scrollFrame: scrollFrame, startMarginRatio: startMarginRatio,
               endMarginRatio: endMarginRatio, times: times, file: file, line: line)
}

public func scrollLeft(scrollFrame: String? = nil,
                       startMarginRatio: Double? = nil, endMarginRatio: Double? = nil,
                       repeat times: Int = 1,
                       file: StaticString = #filePath, line: UInt = #line) {
    scrollImpl(.left, scrollFrame: scrollFrame, startMarginRatio: startMarginRatio,
               endMarginRatio: endMarginRatio, times: times, file: file, line: line)
}

private func scrollImpl(_ direction: FTScrollDirection, scrollFrame: String?,
                        startMarginRatio: Double?, endMarginRatio: Double?, times: Int,
                        file: StaticString, line: UInt) {
    let core = FTRuntime.requireCore(command: "scroll\(direction.rawValue.capitalized)")
    let step = FlowStep(action: "scroll", direction: direction.swipe.rawValue,
                        maxSwipes: max(1, times),
                        scrollFrame: core.effectiveScrollFrame(scrollFrame).map(FTSelector.parse)?.primary,
                        startMarginRatio: startMarginRatio, endMarginRatio: endMarginRatio)
    core.perform(step: step,
                 description: "scroll\(direction.rawValue.capitalized)"
                     + (times > 1 ? " ×\(times)" : ""),
                 file: file, line: line)
}

/// スクロール領域の端まで送る(**画面が変化しなくなるまで**。maxSwipes は暴走を止める上限で、
/// 到達しなかったときはステップに注記が付く)
public func scrollToBottom(scrollFrame: String? = nil,
                           startMarginRatio: Double? = nil, endMarginRatio: Double? = nil,
                           maxSwipes: Int = FlowStep.defaultMaxEdgeSwipes,
                           file: StaticString = #filePath, line: UInt = #line) {
    scrollToEdgeImpl(.down, scrollFrame: scrollFrame, startMarginRatio: startMarginRatio,
                     endMarginRatio: endMarginRatio, maxSwipes: maxSwipes, file: file, line: line)
}

public func scrollToTop(scrollFrame: String? = nil,
                        startMarginRatio: Double? = nil, endMarginRatio: Double? = nil,
                        maxSwipes: Int = FlowStep.defaultMaxEdgeSwipes,
                        file: StaticString = #filePath, line: UInt = #line) {
    scrollToEdgeImpl(.up, scrollFrame: scrollFrame, startMarginRatio: startMarginRatio,
                     endMarginRatio: endMarginRatio, maxSwipes: maxSwipes, file: file, line: line)
}

public func scrollToRightEdge(scrollFrame: String? = nil,
                              startMarginRatio: Double? = nil, endMarginRatio: Double? = nil,
                              maxSwipes: Int = FlowStep.defaultMaxEdgeSwipes,
                              file: StaticString = #filePath, line: UInt = #line) {
    scrollToEdgeImpl(.right, scrollFrame: scrollFrame, startMarginRatio: startMarginRatio,
                     endMarginRatio: endMarginRatio, maxSwipes: maxSwipes, file: file, line: line)
}

public func scrollToLeftEdge(scrollFrame: String? = nil,
                             startMarginRatio: Double? = nil, endMarginRatio: Double? = nil,
                             maxSwipes: Int = FlowStep.defaultMaxEdgeSwipes,
                             file: StaticString = #filePath, line: UInt = #line) {
    scrollToEdgeImpl(.left, scrollFrame: scrollFrame, startMarginRatio: startMarginRatio,
                     endMarginRatio: endMarginRatio, maxSwipes: maxSwipes, file: file, line: line)
}

private func scrollToEdgeImpl(_ direction: FTScrollDirection, scrollFrame: String?,
                              startMarginRatio: Double?, endMarginRatio: Double?,
                              maxSwipes: Int, file: StaticString, line: UInt) {
    let names: [FTScrollDirection: String] = [
        .down: "scrollToBottom", .up: "scrollToTop",
        .right: "scrollToRightEdge", .left: "scrollToLeftEdge",
    ]
    let core = FTRuntime.requireCore(command: names[direction] ?? "scrollToEdge")
    let step = FlowStep(action: "scrollToEdge", direction: direction.swipe.rawValue,
                        maxSwipes: maxSwipes,
                        scrollFrame: core.effectiveScrollFrame(scrollFrame).map(FTSelector.parse)?.primary,
                        startMarginRatio: startMarginRatio, endMarginRatio: endMarginRatio)
    core.perform(step: step, description: names[direction] ?? "scrollToEdge",
                 file: file, line: line)
}

/// ブロック内の `tap` / `exist` を**スクロールしながら**解決する(明示の `scroll:` があればそちらが優先)。
/// Shirates の withScrollDown { } 相当
public func withScrollDown(scrollFrame: String? = nil, _ body: () -> Void) {
    FTRuntime.requireCore(command: "withScrollDown")
        .runWithScrollContext(.direction(.down), scrollFrame: scrollFrame, body)
}

public func withScrollUp(scrollFrame: String? = nil, _ body: () -> Void) {
    FTRuntime.requireCore(command: "withScrollUp")
        .runWithScrollContext(.direction(.up), scrollFrame: scrollFrame, body)
}

public func withScrollRight(scrollFrame: String? = nil, _ body: () -> Void) {
    FTRuntime.requireCore(command: "withScrollRight")
        .runWithScrollContext(.direction(.right), scrollFrame: scrollFrame, body)
}

public func withScrollLeft(scrollFrame: String? = nil, _ body: () -> Void) {
    FTRuntime.requireCore(command: "withScrollLeft")
        .runWithScrollContext(.direction(.left), scrollFrame: scrollFrame, body)
}

/// 外側の withScroll* を打ち消して、ブロック内は現在画面だけで解決する
public func withoutScroll(_ body: () -> Void) {
    FTRuntime.requireCore(command: "withoutScroll").runWithScrollContext(.none, body)
}

// MARK: - スクロール付きの操作・検証(Shirates 準拠の別名)

public func tapWithScrollDown(_ selector: String, maxSwipes: Int = FlowStep.defaultMaxSwipes,
                              file: StaticString = #filePath, line: UInt = #line) {
    tap(selector, scroll: .down, maxSwipes: maxSwipes, file: file, line: line)
}

public func tapWithScrollDown(_ selector: Sel, maxSwipes: Int = FlowStep.defaultMaxSwipes,
                              file: StaticString = #filePath, line: UInt = #line) {
    tap(selector, scroll: .down, maxSwipes: maxSwipes, file: file, line: line)
}

public func tapWithScrollUp(_ selector: String, maxSwipes: Int = FlowStep.defaultMaxSwipes,
                            file: StaticString = #filePath, line: UInt = #line) {
    tap(selector, scroll: .up, maxSwipes: maxSwipes, file: file, line: line)
}

public func tapWithScrollUp(_ selector: Sel, maxSwipes: Int = FlowStep.defaultMaxSwipes,
                            file: StaticString = #filePath, line: UInt = #line) {
    tap(selector, scroll: .up, maxSwipes: maxSwipes, file: file, line: line)
}

public func tapWithScrollRight(_ selector: String, maxSwipes: Int = FlowStep.defaultMaxSwipes,
                               file: StaticString = #filePath, line: UInt = #line) {
    tap(selector, scroll: .right, maxSwipes: maxSwipes, file: file, line: line)
}

public func tapWithScrollRight(_ selector: Sel, maxSwipes: Int = FlowStep.defaultMaxSwipes,
                               file: StaticString = #filePath, line: UInt = #line) {
    tap(selector, scroll: .right, maxSwipes: maxSwipes, file: file, line: line)
}

public func tapWithScrollLeft(_ selector: String, maxSwipes: Int = FlowStep.defaultMaxSwipes,
                              file: StaticString = #filePath, line: UInt = #line) {
    tap(selector, scroll: .left, maxSwipes: maxSwipes, file: file, line: line)
}

public func tapWithScrollLeft(_ selector: Sel, maxSwipes: Int = FlowStep.defaultMaxSwipes,
                              file: StaticString = #filePath, line: UInt = #line) {
    tap(selector, scroll: .left, maxSwipes: maxSwipes, file: file, line: line)
}

/// withScroll* の中でも**この1コマンドだけ**スクロールしない
public func tapWithoutScroll(_ selector: String, timeout: Double? = nil,
                             file: StaticString = #filePath, line: UInt = #line) {
    FTRuntime.requireCore(command: "tapWithoutScroll").runWithScrollContext(.none) {
        tap(selector, timeout: timeout, file: file, line: line)
    }
}

public func tapWithoutScroll(_ selector: Sel, timeout: Double? = nil,
                             file: StaticString = #filePath, line: UInt = #line) {
    FTRuntime.requireCore(command: "tapWithoutScroll").runWithScrollContext(.none) {
        tap(selector, timeout: timeout, file: file, line: line)
    }
}

@discardableResult
public func existWithScrollDown(_ selector: String, maxSwipes: Int = FlowStep.defaultMaxSwipes,
                                file: StaticString = #filePath, line: UInt = #line) -> FTElement {
    exist(selector, scroll: .down, maxSwipes: maxSwipes, file: file, line: line)
}

@discardableResult
public func existWithScrollDown(_ selector: Sel, maxSwipes: Int = FlowStep.defaultMaxSwipes,
                                file: StaticString = #filePath, line: UInt = #line) -> FTElement {
    exist(selector, scroll: .down, maxSwipes: maxSwipes, file: file, line: line)
}

@discardableResult
public func existWithScrollUp(_ selector: String, maxSwipes: Int = FlowStep.defaultMaxSwipes,
                              file: StaticString = #filePath, line: UInt = #line) -> FTElement {
    exist(selector, scroll: .up, maxSwipes: maxSwipes, file: file, line: line)
}

@discardableResult
public func existWithScrollUp(_ selector: Sel, maxSwipes: Int = FlowStep.defaultMaxSwipes,
                              file: StaticString = #filePath, line: UInt = #line) -> FTElement {
    exist(selector, scroll: .up, maxSwipes: maxSwipes, file: file, line: line)
}

@discardableResult
public func existWithoutScroll(_ selector: String, timeout: Double? = nil,
                               requireVisible: Bool = true,
                               file: StaticString = #filePath, line: UInt = #line) -> FTElement {
    var element: FTElement?
    FTRuntime.requireCore(command: "existWithoutScroll").runWithScrollContext(.none) {
        element = exist(selector, timeout: timeout, requireVisible: requireVisible,
                        file: file, line: line)
    }
    return element ?? FTElement(selector: FTSelector.parse(selector))
}

/// フォールバックは selector.ftSelector から作る(空の FTElement に文字列版と同じ FlowLocator を持たせるため)
@discardableResult
public func existWithoutScroll(_ selector: Sel, timeout: Double? = nil,
                               requireVisible: Bool = true,
                               file: StaticString = #filePath, line: UInt = #line) -> FTElement {
    var element: FTElement?
    FTRuntime.requireCore(command: "existWithoutScroll").runWithScrollContext(.none) {
        element = exist(selector, timeout: timeout, requireVisible: requireVisible,
                        file: file, line: line)
    }
    return element ?? FTElement(selector: selector.ftSelector)
}

/// 要素が見つかるまでスクロールする(見つかったら成功。タップはしない)
public func scrollTo(_ selector: String, direction: FTScrollDirection = .down,
                     scrollFrame: String? = nil,
                     startMarginRatio: Double? = nil, endMarginRatio: Double? = nil,
                     maxSwipes: Int = FlowStep.defaultMaxSwipes,
                     file: StaticString = #filePath, line: UInt = #line) {
    scrollToImpl(FTSelector.parse(selector), direction: direction, scrollFrame: scrollFrame,
                 startMarginRatio: startMarginRatio, endMarginRatio: endMarginRatio,
                 maxSwipes: maxSwipes, file: file, line: line)
}

public func scrollTo(_ selector: Sel, direction: FTScrollDirection = .down,
                     scrollFrame: String? = nil,
                     startMarginRatio: Double? = nil, endMarginRatio: Double? = nil,
                     maxSwipes: Int = FlowStep.defaultMaxSwipes,
                     file: StaticString = #filePath, line: UInt = #line) {
    scrollToImpl(selector.ftSelector, direction: direction, scrollFrame: scrollFrame,
                 startMarginRatio: startMarginRatio, endMarginRatio: endMarginRatio,
                 maxSwipes: maxSwipes, file: file, line: line)
}

private func scrollToImpl(_ selector: FTSelector, direction: FTScrollDirection,
                          scrollFrame: String?, startMarginRatio: Double?,
                          endMarginRatio: Double?, maxSwipes: Int,
                          file: StaticString, line: UInt) {
    let frame = FTRuntime.requireCore(command: "scrollTo").effectiveScrollFrame(scrollFrame)
    let step = FlowStep(action: "scrollTo", locator: selector.primary,
                        fallbacks: selector.stepFallbacks,
                        direction: direction.swipe.rawValue, maxSwipes: maxSwipes,
                        scrollFrame: frame.map(FTSelector.parse)?.primary,
                        startMarginRatio: startMarginRatio, endMarginRatio: endMarginRatio)
    perform("scrollTo", selector, step: step, description: "scrollTo \"\(selector.text)\"",
            file: file, line: line)
}

// MARK: - 検証コマンド

/// 要素の存在検証。戻り値に .textIs / .valueIs をチェーンできる
/// (timeout 省略時は実行プロファイルの defaultTimeout、それも無ければ 5 秒)
/// 存在検証。既定で可視性も確認(= 実際に見えていることも確認): ツリー存在に加え、要素が別要素に
/// 覆われ/切れ/不在で見えていないかを FM で確認する(見えなければ失敗)。ツリー存在だけ見たい
/// (高速・アイコン等)場合は requireVisible: false。FM 未配線時と、実行プロファイルの
/// falsePositiveCheck が無効(既定)の run では guard は素通り(存在のみと同じ)。
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

// 検証はすべて「掴んでから検証する」形に統一されている(2026-08-04 ユーザー決定)。
// **次の3つは同義**で、どれで書いても同じステップ・同じ判定になる:
//
//     select("#btn_ok").textIs("OK")     // 戻り値へチェーン
//     select("#btn_ok"); lastElement.textIs("OK")   // 保持要素を明示
//     select("#btn_ok"); textIs("OK")    // 暗黙の lastElement(ここの自由関数)
//
// **セレクタを取る版(`textIs("#btn_ok", "OK")`)は置かない**(未リリースで移行案内は不要・
// ユーザー決定 2026-08-04。コンパイラの素のエラーになる)。対象を暗黙にしたのは、検証のたびにセレクタを書くと
// 「どの要素を見ているか」が select と検証で二重に現れ、片方だけ直す事故が起きるため。
// **要素を1つに定めないコマンド(`exist` / `notExist` / `countIs` / `screenIs`)はセレクタを取り続ける**。
//
// 共通の規律(以下 31 関数すべてに効く):
// - **`scroll:` は足さない**(ユーザー決定 2026-07-27)。これらは静止した画面を詳細に検証する
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
                 commandError: "`\(verb)(\"\(expected)\")` checks the text of the element grabbed last"
                     + " — the single-argument form takes an expected value, not a selector."
                     + " Write select(\"\(expected)\") first, or use select(<selector>).\(verb)(<expected>).",
                 file: file, line: line)
    return FTElement(selector: FTSelector.label(expected))
}

@discardableResult
public func textIs(_ expected: String, timeout: Double? = nil, requireVisible: Bool = true,
                   file: StaticString = #filePath, line: UInt = #line) -> FTElement {
    if let rejected = expectedLooksLikeSelector(expected, verb: "textIs",
                                                file: file, line: line) { return rejected }
    return lastElement.textIs(expected, timeout: timeout, requireVisible: requireVisible,
                              file: file, line: line)
}

/// テキストが期待値と**一致しない**ことの検証(タイムアウトまで変化を待つ)。
/// 「その要素が無いこと」は notExist、「別の値になったこと」はこちら
@discardableResult
public func textIsNot(_ expected: String, timeout: Double? = nil,
                      file: StaticString = #filePath, line: UInt = #line) -> FTElement {
    if let rejected = expectedLooksLikeSelector(expected, verb: "textIsNot",
                                                file: file, line: line) { return rejected }
    return lastElement.textIsNot(expected, timeout: timeout, file: file, line: line)
}

@discardableResult
public func textContains(_ expected: String, timeout: Double? = nil, requireVisible: Bool = true,
                         file: StaticString = #filePath, line: UInt = #line) -> FTElement {
    if let rejected = expectedLooksLikeSelector(expected, verb: "textContains",
                                                file: file, line: line) { return rejected }
    return lastElement.textContains(expected, timeout: timeout, requireVisible: requireVisible,
                                    file: file, line: line)
}

@discardableResult
public func textContainsNot(_ expected: String, timeout: Double? = nil,
                            file: StaticString = #filePath, line: UInt = #line) -> FTElement {
    if let rejected = expectedLooksLikeSelector(expected, verb: "textContainsNot",
                                                file: file, line: line) { return rejected }
    return lastElement.textContainsNot(expected, timeout: timeout, file: file, line: line)
}

@discardableResult
public func textStartsWith(_ expected: String, timeout: Double? = nil, requireVisible: Bool = true,
                           file: StaticString = #filePath, line: UInt = #line) -> FTElement {
    if let rejected = expectedLooksLikeSelector(expected, verb: "textStartsWith",
                                                file: file, line: line) { return rejected }
    return lastElement.textStartsWith(expected, timeout: timeout, requireVisible: requireVisible,
                                      file: file, line: line)
}

@discardableResult
public func textStartsWithNot(_ expected: String, timeout: Double? = nil,
                              file: StaticString = #filePath, line: UInt = #line) -> FTElement {
    if let rejected = expectedLooksLikeSelector(expected, verb: "textStartsWithNot",
                                                file: file, line: line) { return rejected }
    return lastElement.textStartsWithNot(expected, timeout: timeout, file: file, line: line)
}

@discardableResult
public func textEndsWith(_ expected: String, timeout: Double? = nil, requireVisible: Bool = true,
                         file: StaticString = #filePath, line: UInt = #line) -> FTElement {
    if let rejected = expectedLooksLikeSelector(expected, verb: "textEndsWith",
                                                file: file, line: line) { return rejected }
    return lastElement.textEndsWith(expected, timeout: timeout, requireVisible: requireVisible,
                                    file: file, line: line)
}

@discardableResult
public func textEndsWithNot(_ expected: String, timeout: Double? = nil,
                            file: StaticString = #filePath, line: UInt = #line) -> FTElement {
    if let rejected = expectedLooksLikeSelector(expected, verb: "textEndsWithNot",
                                                file: file, line: line) { return rejected }
    return lastElement.textEndsWithNot(expected, timeout: timeout, file: file, line: line)
}

/// **部分一致**の正規表現(全体一致にしたいときは `^...$` を書く)
@discardableResult
public func textMatches(_ pattern: String, timeout: Double? = nil, requireVisible: Bool = true,
                        file: StaticString = #filePath, line: UInt = #line) -> FTElement {
    if let rejected = expectedLooksLikeSelector(pattern, verb: "textMatches",
                                                file: file, line: line) { return rejected }
    return lastElement.textMatches(pattern, timeout: timeout, requireVisible: requireVisible,
                                   file: file, line: line)
}

@discardableResult
public func textMatchesNot(_ pattern: String, timeout: Double? = nil,
                           file: StaticString = #filePath, line: UInt = #line) -> FTElement {
    if let rejected = expectedLooksLikeSelector(pattern, verb: "textMatchesNot",
                                                file: file, line: line) { return rejected }
    return lastElement.textMatchesNot(pattern, timeout: timeout, file: file, line: line)
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
                        file: StaticString = #filePath, line: UInt = #line) -> FTElement {
    return lastElement.textIsEmpty(timeout: timeout, file: file, line: line)
}

@discardableResult
public func textIsNotEmpty(timeout: Double? = nil,
                           file: StaticString = #filePath, line: UInt = #line) -> FTElement {
    return lastElement.textIsNotEmpty(timeout: timeout, file: file, line: line)
}

@discardableResult
public func valueIs(_ expected: String, timeout: Double? = nil, requireVisible: Bool = true,
                    file: StaticString = #filePath, line: UInt = #line) -> FTElement {
    if let rejected = expectedLooksLikeSelector(expected, verb: "valueIs",
                                                file: file, line: line) { return rejected }
    return lastElement.valueIs(expected, timeout: timeout, requireVisible: requireVisible,
                               file: file, line: line)
}

@discardableResult
public func valueIsNot(_ expected: String, timeout: Double? = nil,
                       file: StaticString = #filePath, line: UInt = #line) -> FTElement {
    if let rejected = expectedLooksLikeSelector(expected, verb: "valueIsNot",
                                                file: file, line: line) { return rejected }
    return lastElement.valueIsNot(expected, timeout: timeout, file: file, line: line)
}

@discardableResult
public func valueContains(_ expected: String, timeout: Double? = nil, requireVisible: Bool = true,
                          file: StaticString = #filePath, line: UInt = #line) -> FTElement {
    if let rejected = expectedLooksLikeSelector(expected, verb: "valueContains",
                                                file: file, line: line) { return rejected }
    return lastElement.valueContains(expected, timeout: timeout, requireVisible: requireVisible,
                                     file: file, line: line)
}

@discardableResult
public func valueContainsNot(_ expected: String, timeout: Double? = nil,
                             file: StaticString = #filePath, line: UInt = #line) -> FTElement {
    if let rejected = expectedLooksLikeSelector(expected, verb: "valueContainsNot",
                                                file: file, line: line) { return rejected }
    return lastElement.valueContainsNot(expected, timeout: timeout, file: file, line: line)
}

@discardableResult
public func valueStartsWith(_ expected: String, timeout: Double? = nil, requireVisible: Bool = true,
                            file: StaticString = #filePath, line: UInt = #line) -> FTElement {
    if let rejected = expectedLooksLikeSelector(expected, verb: "valueStartsWith",
                                                file: file, line: line) { return rejected }
    return lastElement.valueStartsWith(expected, timeout: timeout, requireVisible: requireVisible,
                                       file: file, line: line)
}

@discardableResult
public func valueStartsWithNot(_ expected: String, timeout: Double? = nil,
                               file: StaticString = #filePath, line: UInt = #line) -> FTElement {
    if let rejected = expectedLooksLikeSelector(expected, verb: "valueStartsWithNot",
                                                file: file, line: line) { return rejected }
    return lastElement.valueStartsWithNot(expected, timeout: timeout, file: file, line: line)
}

@discardableResult
public func valueEndsWith(_ expected: String, timeout: Double? = nil, requireVisible: Bool = true,
                          file: StaticString = #filePath, line: UInt = #line) -> FTElement {
    if let rejected = expectedLooksLikeSelector(expected, verb: "valueEndsWith",
                                                file: file, line: line) { return rejected }
    return lastElement.valueEndsWith(expected, timeout: timeout, requireVisible: requireVisible,
                                     file: file, line: line)
}

@discardableResult
public func valueEndsWithNot(_ expected: String, timeout: Double? = nil,
                             file: StaticString = #filePath, line: UInt = #line) -> FTElement {
    if let rejected = expectedLooksLikeSelector(expected, verb: "valueEndsWithNot",
                                                file: file, line: line) { return rejected }
    return lastElement.valueEndsWithNot(expected, timeout: timeout, file: file, line: line)
}

/// **部分一致**の正規表現(textMatches と同じ規則)
@discardableResult
public func valueMatches(_ pattern: String, timeout: Double? = nil, requireVisible: Bool = true,
                         file: StaticString = #filePath, line: UInt = #line) -> FTElement {
    if let rejected = expectedLooksLikeSelector(pattern, verb: "valueMatches",
                                                file: file, line: line) { return rejected }
    return lastElement.valueMatches(pattern, timeout: timeout, requireVisible: requireVisible,
                                    file: file, line: line)
}

@discardableResult
public func valueMatchesNot(_ pattern: String, timeout: Double? = nil,
                            file: StaticString = #filePath, line: UInt = #line) -> FTElement {
    if let rejected = expectedLooksLikeSelector(pattern, verb: "valueMatchesNot",
                                                file: file, line: line) { return rejected }
    return lastElement.valueMatchesNot(pattern, timeout: timeout, file: file, line: line)
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
                         file: StaticString = #filePath, line: UInt = #line) -> FTElement {
    return lastElement.valueIsEmpty(timeout: timeout, file: file, line: line)
}

@discardableResult
public func valueIsNotEmpty(timeout: Double? = nil,
                            file: StaticString = #filePath, line: UInt = #line) -> FTElement {
    return lastElement.valueIsNotEmpty(timeout: timeout, file: file, line: line)
}

/// 掴んだ要素の id 検証。**セレクタに `#id` を足す形にはしない**(`||` を含む式で結合が変わり、
/// 落ちたときに実際の id を出せないため)
@discardableResult
public func idIs(_ expected: String, timeout: Double? = nil,
                 file: StaticString = #filePath, line: UInt = #line) -> FTElement {
    if let rejected = expectedLooksLikeSelector(expected, verb: "idIs",
                                                file: file, line: line) { return rejected }
    return lastElement.idIs(expected, timeout: timeout, file: file, line: line)
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
                         held: ElementInfo? = nil,
                         file: StaticString, line: UInt) {
    let core = FTRuntime.requireCore(command: verb)
    let step = FlowStep(assert: assert, locator: selector.primary,
                        fallbacks: selector.stepFallbacks,
                        timeout: timeout ?? core.defaultTimeout)
    perform(verb, selector, step: step, description: "\(verb) \"\(selector.text)\"",
            held: held, file: file, line: line)
}





































/// textIs / valueIs / textContains / textMatches の共通実装。
/// operatorText は説明文の記号だけを分ける(完全一致系は `==`、部分一致系は `~`)。
/// held は FTElement のチェーンだけが渡す(自由関数版は nil = 常に実機を見る)
private func textAssert(_ assert: String, verb: String, selector: FTSelector, expected: String,
                        timeout: Double?, requireVisible: Bool, operatorText: String = "~",
                        held: ElementInfo? = nil,
                        file: StaticString, line: UInt) {
    let core = FTRuntime.requireCore(command: verb)
    let step = FlowStep(assert: assert, locator: selector.primary,
                        fallbacks: selector.stepFallbacks,
                        expected: expected, timeout: timeout ?? core.defaultTimeout,
                        occlusionGuard: requireVisible)
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
/// (ftester に lastElement 概念が無いため)
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
public func screenIs(_ expected: String,
                     file: StaticString = #filePath, line: UInt = #line) {
    let step = FlowStep(assert: "screenMatches", expected: expected)
    FTRuntime.requireCore(command: "screenIs")
        .perform(step: step, description: "screenIs \"\(expected)\"", file: file, line: line)
}

/// キーボードが表示されていることの検証。開閉はアニメーションを伴うためタイムアウトまでポーリングする
/// (1回のスナップショット照会だとフレークする)
public func keyboardIsShown(timeout: Double? = nil,
                            file: StaticString = #filePath, line: UInt = #line) {
    let core = FTRuntime.requireCore(command: "keyboardIsShown")
    let step = FlowStep(assert: "keyboardShown", timeout: timeout ?? core.defaultTimeout)
    core.perform(step: step, description: "keyboardIsShown", file: file, line: line)
}

/// キーボードが表示されていないことの検証(タイムアウトまでポーリング。理由は keyboardIsShown 参照)
public func keyboardIsNotShown(timeout: Double? = nil,
                               file: StaticString = #filePath, line: UInt = #line) {
    let core = FTRuntime.requireCore(command: "keyboardIsNotShown")
    let step = FlowStep(assert: "keyboardNotShown", timeout: timeout ?? core.defaultTimeout)
    core.perform(step: step, description: "keyboardIsNotShown", file: file, line: line)
}

/// exist の戻り値。検証をチェーンできる。
/// **網羅の規則**: セレクタを取り「その要素」を検証する自由関数は**すべて同名でここにも生える**
/// (text/value の全対称 + `enabledIsTrue` / `enabledIsFalse` / `checkIsON` / `checkIsOFF` + `idIs`)。
/// 一部だけ生やすと「どれがチェーンできるか」が覚えられず、書いてみるまで分からない。
/// **例外は要素を1つに定めないコマンド**(`notExist` / `countIs` / `screenIs`)で、これらは
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
                       file: StaticString = #filePath, line: UInt = #line) -> FTElement {
        textAssert("textEquals", verb: "textIs", selector: selector, expected: expected,
                   timeout: timeout, requireVisible: requireVisible, operatorText: "==",
                   held: matched, file: file, line: line)
        return self
    }

    @discardableResult
    public func valueIs(_ expected: String, timeout: Double? = nil, requireVisible: Bool = true,
                        file: StaticString = #filePath, line: UInt = #line) -> FTElement {
        textAssert("valueEquals", verb: "valueIs", selector: selector, expected: expected,
                   timeout: timeout, requireVisible: requireVisible, operatorText: "==",
                   held: matched, file: file, line: line)
        return self
    }

    @discardableResult
    public func textStartsWith(_ expected: String, timeout: Double? = nil,
                               requireVisible: Bool = true,
                               file: StaticString = #filePath, line: UInt = #line) -> FTElement {
        textAssert("textStartsWith", verb: "textStartsWith", selector: selector,
                   expected: expected, timeout: timeout, requireVisible: requireVisible,
                   held: matched, file: file, line: line)
        return self
    }

    @discardableResult
    public func textEndsWith(_ expected: String, timeout: Double? = nil,
                             requireVisible: Bool = true,
                             file: StaticString = #filePath, line: UInt = #line) -> FTElement {
        textAssert("textEndsWith", verb: "textEndsWith", selector: selector,
                   expected: expected, timeout: timeout, requireVisible: requireVisible,
                   held: matched, file: file, line: line)
        return self
    }

    @discardableResult
    public func textIsNot(_ expected: String, timeout: Double? = nil,
                          file: StaticString = #filePath, line: UInt = #line) -> FTElement {
        textAssert("textNotEquals", verb: "textIsNot", selector: selector, expected: expected,
                   timeout: timeout, requireVisible: false, operatorText: "!=",
                   held: matched, file: file, line: line)
        return self
    }

    /// 掴んだ要素の id 検証(Shirates の TestElement.idIs)。
    /// **セレクタに `#id` を足す形にはしない** — `||` を含む式で結合が変わるうえ、
    /// 落ちたときに「見つからない」としか言えず**実際の id** を出せないため
    @discardableResult
    public func idIs(_ expected: String, timeout: Double? = nil,
                     file: StaticString = #filePath, line: UInt = #line) -> FTElement {
        let core = FTRuntime.requireCore(command: "idIs")
        let step = FlowStep(assert: "idEquals", locator: selector.primary,
                            fallbacks: selector.stepFallbacks, expected: expected,
                            timeout: timeout ?? core.defaultTimeout, occlusionGuard: false)
        perform("idIs", selector, step: step,
                description: "idIs \"\(selector.text)\" == \"\(expected)\"",
                held: matched, file: file, line: line)
        return self
    }

    @discardableResult
    public func textIsNotEmpty(timeout: Double? = nil,
                               file: StaticString = #filePath, line: UInt = #line) -> FTElement {
        emptyAssert("textIsNotEmpty", verb: "textIsNotEmpty", selector: selector,
                    timeout: timeout, held: matched, file: file, line: line)
        return self
    }

    @discardableResult
    public func textIsEmpty(timeout: Double? = nil,
                            file: StaticString = #filePath, line: UInt = #line) -> FTElement {
        emptyAssert("textIsEmpty", verb: "textIsEmpty", selector: selector,
                    timeout: timeout, held: matched, file: file, line: line)
        return self
    }

    @discardableResult
    public func textContains(_ expected: String, timeout: Double? = nil,
                             requireVisible: Bool = true,
                             file: StaticString = #filePath, line: UInt = #line) -> FTElement {
        textAssert("textContains", verb: "textContains", selector: selector, expected: expected,
                   timeout: timeout, requireVisible: requireVisible, held: matched, file: file, line: line)
        return self
    }

    @discardableResult
    public func textMatches(_ pattern: String, timeout: Double? = nil,
                            requireVisible: Bool = true,
                            file: StaticString = #filePath, line: UInt = #line) -> FTElement {
        textAssert("textMatches", verb: "textMatches", selector: selector, expected: pattern,
                   timeout: timeout, requireVisible: requireVisible, held: matched, file: file, line: line)
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
                                  file: StaticString = #filePath, line: UInt = #line) -> FTElement {
        textAssert("textStartsWithNot", verb: "textStartsWithNot", selector: selector,
                   expected: expected, timeout: timeout, requireVisible: false,
                   operatorText: "!=", held: matched, file: file, line: line)
        return self
    }

    @discardableResult
    public func textContainsNot(_ expected: String, timeout: Double? = nil,
                                file: StaticString = #filePath, line: UInt = #line) -> FTElement {
        textAssert("textContainsNot", verb: "textContainsNot", selector: selector,
                   expected: expected, timeout: timeout, requireVisible: false,
                   operatorText: "!=", held: matched, file: file, line: line)
        return self
    }

    @discardableResult
    public func textEndsWithNot(_ expected: String, timeout: Double? = nil,
                                file: StaticString = #filePath, line: UInt = #line) -> FTElement {
        textAssert("textEndsWithNot", verb: "textEndsWithNot", selector: selector,
                   expected: expected, timeout: timeout, requireVisible: false,
                   operatorText: "!=", held: matched, file: file, line: line)
        return self
    }

    @discardableResult
    public func textMatchesNot(_ pattern: String, timeout: Double? = nil,
                               file: StaticString = #filePath, line: UInt = #line) -> FTElement {
        textAssert("textMatchesNot", verb: "textMatchesNot", selector: selector,
                   expected: pattern, timeout: timeout, requireVisible: false,
                   operatorText: "!=", held: matched, file: file, line: line)
        return self
    }

    // MARK: value 系

    @discardableResult
    public func valueIsNot(_ expected: String, timeout: Double? = nil,
                           file: StaticString = #filePath, line: UInt = #line) -> FTElement {
        textAssert("valueNotEquals", verb: "valueIsNot", selector: selector, expected: expected,
                   timeout: timeout, requireVisible: false, operatorText: "!=",
                   held: matched, file: file, line: line)
        return self
    }

    @discardableResult
    public func valueContains(_ expected: String, timeout: Double? = nil,
                              requireVisible: Bool = true,
                              file: StaticString = #filePath, line: UInt = #line) -> FTElement {
        textAssert("valueContains", verb: "valueContains", selector: selector, expected: expected,
                   timeout: timeout, requireVisible: requireVisible, held: matched, file: file, line: line)
        return self
    }

    @discardableResult
    public func valueStartsWith(_ expected: String, timeout: Double? = nil,
                                requireVisible: Bool = true,
                                file: StaticString = #filePath, line: UInt = #line) -> FTElement {
        textAssert("valueStartsWith", verb: "valueStartsWith", selector: selector,
                   expected: expected, timeout: timeout, requireVisible: requireVisible,
                   held: matched, file: file, line: line)
        return self
    }

    @discardableResult
    public func valueEndsWith(_ expected: String, timeout: Double? = nil,
                              requireVisible: Bool = true,
                              file: StaticString = #filePath, line: UInt = #line) -> FTElement {
        textAssert("valueEndsWith", verb: "valueEndsWith", selector: selector, expected: expected,
                   timeout: timeout, requireVisible: requireVisible, held: matched, file: file, line: line)
        return self
    }

    @discardableResult
    public func valueMatches(_ pattern: String, timeout: Double? = nil,
                             requireVisible: Bool = true,
                             file: StaticString = #filePath, line: UInt = #line) -> FTElement {
        textAssert("valueMatches", verb: "valueMatches", selector: selector, expected: pattern,
                   timeout: timeout, requireVisible: requireVisible, held: matched, file: file, line: line)
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
                                   file: StaticString = #filePath, line: UInt = #line) -> FTElement {
        textAssert("valueStartsWithNot", verb: "valueStartsWithNot", selector: selector,
                   expected: expected, timeout: timeout, requireVisible: false,
                   operatorText: "!=", held: matched, file: file, line: line)
        return self
    }

    @discardableResult
    public func valueContainsNot(_ expected: String, timeout: Double? = nil,
                                 file: StaticString = #filePath, line: UInt = #line) -> FTElement {
        textAssert("valueContainsNot", verb: "valueContainsNot", selector: selector,
                   expected: expected, timeout: timeout, requireVisible: false,
                   operatorText: "!=", held: matched, file: file, line: line)
        return self
    }

    @discardableResult
    public func valueEndsWithNot(_ expected: String, timeout: Double? = nil,
                                 file: StaticString = #filePath, line: UInt = #line) -> FTElement {
        textAssert("valueEndsWithNot", verb: "valueEndsWithNot", selector: selector,
                   expected: expected, timeout: timeout, requireVisible: false,
                   operatorText: "!=", held: matched, file: file, line: line)
        return self
    }

    @discardableResult
    public func valueMatchesNot(_ pattern: String, timeout: Double? = nil,
                                file: StaticString = #filePath, line: UInt = #line) -> FTElement {
        textAssert("valueMatchesNot", verb: "valueMatchesNot", selector: selector,
                   expected: pattern, timeout: timeout, requireVisible: false,
                   operatorText: "!=", held: matched, file: file, line: line)
        return self
    }

    @discardableResult
    public func valueIsEmpty(timeout: Double? = nil,
                             file: StaticString = #filePath, line: UInt = #line) -> FTElement {
        emptyAssert("valueIsEmpty", verb: "valueIsEmpty", selector: selector,
                    timeout: timeout, held: matched, file: file, line: line)
        return self
    }

    @discardableResult
    public func valueIsNotEmpty(timeout: Double? = nil,
                                file: StaticString = #filePath, line: UInt = #line) -> FTElement {
        emptyAssert("valueIsNotEmpty", verb: "valueIsNotEmpty", selector: selector,
                    timeout: timeout, held: matched, file: file, line: line)
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

// MARK: - アプリ制御

/// アプリを起動する(引数省略時は @TestClass の app)
public func launchApp(_ bundleID: String? = nil,
                      file: StaticString = #filePath, line: UInt = #line) {
    let core = FTRuntime.requireCore(command: "launchApp")
    let bundle = bundleID ?? core.appBundleID
    let driver = core.driver
    core.performCustom(description: "launch \(bundle)", file: file, line: line,
                       launchTiming: { driver.lastLaunchTiming }) {
        try await driver.launch(bundleID: bundle)
    }
}

/// アプリを終了してから起動し直す(scene 間の状態リセット用)。**データは消えない**
/// (消したいときは clearAppData)
public func restartApp(_ bundleID: String? = nil,
                       file: StaticString = #filePath, line: UInt = #line) {
    let core = FTRuntime.requireCore(command: "restartApp")
    let bundle = bundleID ?? core.appBundleID
    let driver = core.driver
    core.performCustom(description: "restart \(bundle)", file: file, line: line,
                       launchTiming: { driver.lastLaunchTiming }) {
        try? await driver.terminate()
        try await driver.launch(bundleID: bundle)
    }
}

/// アプリは残したままデータだけ消す(再インストールは伴わない)。初回起動・オンボーディング・
/// 権限ダイアログを何度でも再現するために使う。**iOS はシミュレータ専用**(実機は 501)。
/// Android は `pm clear` 相当
public func clearAppData(_ bundleID: String? = nil,
                         file: StaticString = #filePath, line: UInt = #line) {
    let core = FTRuntime.requireCore(command: "clearAppData")
    let bundle = bundleID ?? core.appBundleID
    let driver = core.driver
    core.performCustom(description: "clearAppData \(bundle)", file: file, line: line) {
        try await driver.clearAppData(bundleID: bundle)
    }
}

public func terminateApp(file: StaticString = #filePath, line: UInt = #line) {
    let core = FTRuntime.requireCore(command: "terminateApp")
    let driver = core.driver
    core.performCustom(description: "terminate", file: file, line: line) {
        try await driver.terminate()
    }
}

/// アプリをインストールする。**実行はオーケストレータ(親プロセス)の仕事**(2026-08-03 決定): 子は
/// installControl 経由で依頼を送るだけで、親が実行プロファイルの appPath 解決・実インストール・
/// (iOS inapp/hybrid の)再注入注記までを担う。appPackageFile 省略時は親側でプロファイルの appPath を
/// 解決する。ホスト無しの単独実行(installControl が nil)では従来どおり子が直接
/// driver.install を呼び、パス解決は 明示引数 ?? --app-path(親が解決して渡した場合) ?? 明示エラー
public func installApp(_ appPackageFile: String? = nil,
                       file: StaticString = #filePath, line: UInt = #line) {
    let core = FTRuntime.requireCore(command: "installApp")
    let driver = core.driver
    let description = appPackageFile.map { "installApp \"\($0)\"" } ?? "installApp"
    core.performCustom(description: description, file: file, line: line) {
        if let installControl = core.installControl {
            // 110s: FTSync.commandTimeout(120s。performCustom を包む外枠)より内側に収め、
            // ここで先に installApp 固有の理由を返す(外枠だと汎用の "operation timed out" になる)
            let result = await installControl.request(timeoutSeconds: 110) { id in
                var event = ScenarioEvent(kind: "installRequest")
                event.scenario = core.scenarioID
                event.requestID = id
                event.installPath = appPackageFile
                core.emit(event)
            }
            guard result.ok else { throw FTCommandError.message(result.message) }
            if !result.message.isEmpty { core.emit(.log("ℹ️ \(result.message)")) }
            return
        }
        let resolvedPath = appPackageFile ?? core.appPathOverride
        guard let resolvedPath else {
            throw FTCommandError.message(
                "installApp: no package path was given and it cannot be resolved automatically "
                + "(the scenario process only knows the app's bundle ID, not a package file path). "
                + "Pass the path explicitly: installApp(\"/path/to/App.app\")")
        }
        let expanded = (resolvedPath as NSString).expandingTildeInPath
        guard FileManager.default.fileExists(atPath: expanded) else {
            throw FTCommandError.message("installApp: package not found at \(expanded)")
        }
        try await driver.install(packagePath: expanded)
    }
}

/// アプリをアンインストールする。nil のときは実行中アプリの既定 bundleID/package
/// (launchApp() 引数なしと同じ解決 = core.appBundleID)
public func removeApp(_ packageOrBundleId: String? = nil,
                      file: StaticString = #filePath, line: UInt = #line) {
    let core = FTRuntime.requireCore(command: "removeApp")
    let driver = core.driver
    let target = packageOrBundleId ?? core.appBundleID
    core.performCustom(description: "removeApp \"\(target)\"", file: file, line: line) {
        try await driver.uninstall(bundleID: target)
    }
}

/// appIs のポーリング(PollBackoff の再利用はコピペ禁止の契約。
/// Sources/FTCore/PollBackoff.swift 参照)。timeout==0 でも初回照会は必ず1回行う
private func pollForegroundMatch(driver: AppDriver, target: String,
                                 waitSeconds: Double) async throws -> Bool {
    let deadline = Date().addingTimeInterval(waitSeconds)
    var backoff = PollBackoff()
    while true {
        if try await driver.isAppForeground(bundleID: target) { return true }
        if Date() >= deadline { return false }
        try await Task.sleep(for: backoff.nextDelay())
    }
}

/// フォアグラウンドのアプリが appNameOrAppId(iOS=bundle ID / Android=package 名)と一致することの検証。
/// ftester はニックネーム機構を持たないため、引数は ID そのもの(引数名だけ Shirates 準拠)。
/// waitSeconds までポーリングする。Android は失敗メッセージに actual の package 名を含める
/// (iOS は前面 bundle ID を取得する手段が無いため自然と省かれる。foregroundAppID 参照)
public func appIs(_ appNameOrAppId: String, waitSeconds: Double = FlowStep.defaultIsScreenWaitSeconds,
                  file: StaticString = #filePath, line: UInt = #line) {
    let core = FTRuntime.requireCore(command: "appIs")
    let driver = core.driver
    core.performCustom(description: "appIs \"\(appNameOrAppId)\"", file: file, line: line,
                       isAssertion: true) {
        let matched = try await pollForegroundMatch(
            driver: driver, target: appNameOrAppId, waitSeconds: waitSeconds)
        guard !matched else { return }
        var message = "appIs \"\(appNameOrAppId)\" did not hold within \(FTSeconds.format(waitSeconds))s"
        // try? はネストした Optional を1段へ平坦化する(SE-0230): throw でも nil 返却でも actual は
        // nil になり、両方の場合を区別なく「省く」で扱える
        if let actual = try? await driver.foregroundAppID() {
            message += " (actual=\"\(actual)\")"
        }
        throw FTCommandError.message(message)
    }
}

// MARK: - スクリーンショット

/// 現在の画面をスクリーンショットとして撮り、レポートのこのステップの直後に埋め込む。
/// ファイル名省略時はステップ連番(.png)。Shirates の force/onChangedOnly/withXmlSource は未実装
public func screenshot(filename: String? = nil,
                       file: StaticString = #filePath, line: UInt = #line) {
    FTRuntime.requireCore(command: "screenshot").performScreenshot(
        filename: filename, file: file, line: line)
}

/// ホーム画面へ戻る
public func home(file: StaticString = #filePath, line: UInt = #line) {
    let core = FTRuntime.requireCore(command: "home")
    let driver = core.systemDriver
    core.performCustom(description: "home", file: file, line: line) {
        try await driver.home()
    }
}

/// 前の画面へ戻る(Android = 戻るキー / iOS = 左端エッジスワイプ。Shirates の pressBack 相当)
public func back(file: StaticString = #filePath, line: UInt = #line) {
    let core = FTRuntime.requireCore(command: "back")
    let driver = core.systemDriver
    core.performCustom(description: "back", file: file, line: line) {
        try await driver.back()
    }
}

/// フォーカス中の入力のキーボードを閉じる(冪等: 非表示中でも成功扱い)。
/// home/back と違い**アプリ内**のフォーカス操作なので systemDriver ではなく driver を使う
public func hideKeyboard(file: StaticString = #filePath, line: UInt = #line) {
    let core = FTRuntime.requireCore(command: "hideKeyboard")
    let driver = core.driver
    core.performCustom(description: "hideKeyboard", file: file, line: line) {
        try await driver.hideKeyboard()
    }
}

/// アプリスイッチャー(タスク一覧)を開く
public func appSwitcher(file: StaticString = #filePath, line: UInt = #line) {
    let core = FTRuntime.requireCore(command: "appSwitcher")
    let driver = core.systemDriver
    core.performCustom(description: "appSwitcher", file: file, line: line) {
        try await driver.openAppSwitcher()
    }
}

/// ホーム画面のドロワー探索(Android)で試す上限回数。Shirates は無指定(打ち切りは
/// canSelectWithScrollDown の既定に委ねる)なので、ここでは妥当な値を独自に決める
private let tapAppIconAndroidMaxFlicks = 8
/// iOS のページ送り上限。ページインジケータを読めない(Runner が未対応)ため既定値固定
/// (docs 化していない残課題。ページ数が分かればそちらを使う設計に変更余地あり)
private let tapAppIconIOSMaxPages = 5
/// アイコンタップ後の整定待ち(Shirates 準拠。ホーム画面遷移直後の描画完了を待つ)
private let tapAppIconSettleSeconds = 1.5

/// ホーム画面のアプリアイコンをタップする(Shirates tapAppIcon の auto 相当。
/// tapAppIconMethod・マクロ・カスタム関数は持たない)。
/// 名前省略時は親(オーケストレータ)が解決して渡したプロファイルの appName
/// (Shirates の appIconName 既定=プロファイル、に相当)。
/// 手順: home()(iOS はもう1回。Shirates 準拠) → 現在の画面で探す → 無ければ
/// Android はドロワーを開いてスクロール探索、iOS はページ送りしながら探索。
public func tapAppIcon(_ appIconName: String? = nil,
                       file: StaticString = #filePath, line: UInt = #line) {
    let core = FTRuntime.requireCore(command: "tapAppIcon")
    let driver = core.homeScreenDriver
    let platform = core.platform
    let resolvedName = appIconName ?? core.appDisplayName
    let description = resolvedName.map { "tapAppIcon \"\($0)\"" } ?? "tapAppIcon"
    core.performCustom(description: description, file: file, line: line) {
        // 親(プロファイルの appName)からも取れないときだけ明示エラー
        guard let appIconName = resolvedName else {
            throw FTCommandError.message(
                "tapAppIcon: no icon name was given and the profile has no appName to resolve it "
                + "from. Pass the name explicitly (tapAppIcon(\"App Name\")) or set appName in "
                + "the app profile")
        }

        // タップ成功後の共通処理。xcuitest 単独では springboard 参照が**主ドライバと同じランナーの
        // セッションを springboard に付け替える**ため、張り直さないと以降の要素コマンドが
        // springboard のツリーを黙って読む(実機で確認)。タップ先がシナリオ対象アプリのときだけ
        // 張り直す(activate は /session の再バインド+前面化で状態を保持する。
        // 対象外アプリを開いた場合はそのまま = xcuitest は対象アプリ以外を駆動しない)
        func settleAndRestoreSession() async throws {
            try await Task.sleep(nanoseconds: ftSleepNanoseconds(tapAppIconSettleSeconds))
            if core.homeScreenSharesRunnerSession,
               (try? await driver.isAppForeground(bundleID: core.appBundleID)) == true {
                try await core.driver.activate(bundleID: core.appBundleID)
            }
        }

        try await driver.home()
        if platform == "ios" { try await driver.home() }

        var last = try await driver.snapshot()
        if let icon = AppIconLocator.findIcon(appIconName, in: last) {
            try await driver.tap(ref: icon.ref)
            try await settleAndRestoreSession()
            return
        }

        // 画面の矩形はドロワー/ページ送りの間ずっと同じ(内容だけが変わる)ので1回だけ取る
        let screen = last.screen
        let kind: FlickKind = platform == "android" ? .centerToTop : .rightToLeft
        let maxAttempts = platform == "android" ? tapAppIconAndroidMaxFlicks : tapAppIconIOSMaxPages
        var previousSignature = AppIconLocator.signature(of: last)
        var unchanged = 0
        var attempt = 0
        while true {
            attempt += 1
            let startRatio = FTScrollDefaults.startMarginRatio(intent: .gesture, vertical: kind.isVertical)
            if let path = ScrollGeometry.flickPath(container: screen, viewport: screen,
                                                    kind: kind, startMarginRatio: startRatio) {
                try await driver.drag(fromX: path.fromX, fromY: path.fromY,
                                      toX: path.toX, toY: path.toY,
                                      pressSeconds: 0.05, durationSeconds: FlowStep.defaultFlickDurationSeconds)
            } else {
                // 座標を作れない(画面が小さすぎる等): 向き基準の汎用スワイプへ落ちる
                // (flick アクションの座標算出失敗と同じ扱い)
                try await driver.swipe(kind.fingerDirection)
            }

            last = try await driver.snapshot()
            if let icon = AppIconLocator.findIcon(appIconName, in: last) {
                try await driver.tap(ref: icon.ref)
                try await settleAndRestoreSession()
                return
            }

            let signature = AppIconLocator.signature(of: last)
            unchanged = signature == previousSignature ? unchanged + 1 : 0
            previousSignature = signature
            if AppIconLocator.shouldStopSearch(consecutiveUnchanged: unchanged,
                                               attempts: attempt, maxAttempts: maxAttempts) {
                throw FTCommandError.message("App icon not found.(\(appIconName))")
            }
        }
    }
}

/// 秒 → ナノ秒。**範囲外の Double で `UInt64(_:)` は trap する**(負値も無限大も
/// UInt64 に入らない巨大値も)。1プロセス=1シナリオなので trap するとレポートごと消えるため、
/// ここで丸める(design.md §10)。上限が壁時計上限なのは、**それより長くは待てない**から
/// (超えたステップは FTSync がキャンセルする。docs/commands.md にも書いてある契約)。
/// 負値と NaN は `seconds > 0` が false になって 0 に落ちる
func ftSleepNanoseconds(_ seconds: Double) -> UInt64 {
    guard seconds > 0 else { return 0 }
    return UInt64(min(seconds, FTSync.commandTimeout) * 1_000_000_000)
}

/// 固定秒数待つ(記録に残る)
public func wait(_ seconds: Double,
                 file: StaticString = #filePath, line: UInt = #line) {
    FTRuntime.requireCore(command: "wait")
        .performCustom(description: "wait \(FTSeconds.format(seconds))s", file: file, line: line) {
            try await Task.sleep(nanoseconds: ftSleepNanoseconds(seconds))
        }
}

// MARK: - 分岐・任意コード

/// セレクタが解決できる場合のみブロックを実行する(出るかどうか不定なダイアログ処理用)。
/// 戻り値の .ifElse { } で不成立時の処理を書ける
@discardableResult
public func ifCanSelect(_ selector: String, waitSeconds: Double = 0,
                        file: StaticString = #filePath, line: UInt = #line,
                        _ body: () -> Void) -> FTBranch {
    ifCanSelectImpl(FTSelector.parse(selector), waitSeconds: waitSeconds,
                    file: file, line: line, body)
}

@discardableResult
public func ifCanSelect(_ selector: Sel, waitSeconds: Double = 0,
                        file: StaticString = #filePath, line: UInt = #line,
                        _ body: () -> Void) -> FTBranch {
    ifCanSelectImpl(selector.ftSelector, waitSeconds: waitSeconds, file: file, line: line, body)
}

@discardableResult
private func ifCanSelectImpl(_ selector: FTSelector, waitSeconds: Double,
                             file: StaticString, line: UInt,
                             _ body: () -> Void) -> FTBranch {
    let core = FTRuntime.requireCore(command: "ifCanSelect")
    // 構文誤りは「不成立」と区別できない(どちらもブロックを飛ばして緑になる)ため、
    // perform を通らないこのコマンドでも実行前に検証する
    if let error = validationError(selector) {
        let reason = "invalid selector syntax: \(error)"
        core.recordStep(description: "ifCanSelect \"\(selector.text)\"", status: .failed(reason),
                        file: "\(file)", line: Int(line))
        core.handleFailure(stepDescription: "ifCanSelect \"\(selector.text)\"", reason: reason)
        return FTBranch(taken: false)
    }
    let found = core.canSelect(selector, waitSeconds: waitSeconds)
    // 不成立は **skipped** で記録する(passed にすると「セレクタが腐って毎回飛んでいる」状態が
    // 緑のまま見えなくなる)。run 終了時のサマリにも不成立を残す
    let description = "ifCanSelect \"\(selector.text)\" → \(found ? "ran" : "not met")"
    core.recordStep(description: description,
                    status: found ? .passed : .skipped("condition not met"),
                    file: "\(file)", line: Int(line))
    core.noteBranchOutcome(selector: selector.text, met: found)
    if found { body() } else { core.noteUnexecutedBlock() }
    return FTBranch(taken: found)
}

/// perform を通らないコマンド(ifCanSelect / repeatWhileCanSelect)用。判定は perform と同じ源
private func validationError(_ selector: FTSelector) -> String? {
    selector.preflightError
}

public struct FTBranch {
    let taken: Bool

    /// 直前の分岐が不成立だった場合にブロックを実行する。
    /// **成立していた場合はこちらが未実行**なので記録する(ifCanSelect 側と対称。理由は
    /// FTDriveCore.sectionUnexecutedBlocks)
    public func ifElse(_ body: () -> Void) {
        if taken {
            FTRuntime.requireCore(command: "ifElse").noteUnexecutedBlock()
        } else {
            body()
        }
    }
}

/// プラットフォームが iOS のときのみブロックを実行する。
/// 実行しなかったことは noteUnexecutedBlock で残す(中身は実行しないと分からないので、
/// 「アサーションが無い」の判定を誤らせないため。FTDriveCore.runSection 参照)
public func ios(_ body: () -> Void) {
    let core = FTRuntime.requireCore(command: "ios")
    if core.platform == "ios" { body() } else { core.noteUnexecutedBlock() }
}

/// プラットフォームが Android のときのみブロックを実行する
public func android(_ body: () -> Void) {
    let core = FTRuntime.requireCore(command: "android")
    if core.platform == "android" { body() } else { core.noteUnexecutedBlock() }
}

/// セレクタが解決できる限り本体を繰り返す(件数不定の一括操作用。上限 max 回)。
/// DSL にループが無いため、従来は「ガード付き反復を上限回数ぶん並べる」必要があった。
/// **各周回のステップ説明には `[名前 #n]` が前置される**(group と同じ記録規約)。
/// 上限に達しても失敗にはしない(消化しきれなかったことは記録に残る)。
/// 本体が要素を減らさないと上限まで空回りするので、max は想定最大件数に合わせる
public func repeatWhileCanSelect(_ selector: String, max: Int = 10, waitSeconds: Double = 0,
                                 title: String? = nil,
                                 file: StaticString = #filePath, line: UInt = #line,
                                 _ body: () -> Void) {
    repeatWhileCanSelectImpl(FTSelector.parse(selector), max: max, waitSeconds: waitSeconds,
                             title: title, file: file, line: line, body)
}

public func repeatWhileCanSelect(_ selector: Sel, max: Int = 10, waitSeconds: Double = 0,
                                 title: String? = nil,
                                 file: StaticString = #filePath, line: UInt = #line,
                                 _ body: () -> Void) {
    repeatWhileCanSelectImpl(selector.ftSelector, max: max, waitSeconds: waitSeconds,
                             title: title, file: file, line: line, body)
}

private func repeatWhileCanSelectImpl(_ selector: FTSelector, max: Int, waitSeconds: Double,
                                      title: String?,
                                      file: StaticString, line: UInt,
                                      _ body: () -> Void) {
    let core = FTRuntime.requireCore(command: "repeatWhileCanSelect")
    if let error = validationError(selector) {
        let reason = "invalid selector syntax: \(error)"
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
    // **上限で止まったのか、出尽くしたのかを区別できるようにする**。`→ 10 回` だけだと
    // 「ちょうど 10 件だった」のか「まだ残っているのに打ち切った」のかが記録から読めない
    // (成功扱いにする契約は変えない = 上限到達を失敗にはしない)
    let reachedMax = iterations >= max && max > 0 && !core.isDryRun
    // 0 周 = 本体を一度も実行していない(ios/android の不一致と同じ扱い。runSection 参照)
    if iterations == 0 { core.noteUnexecutedBlock() }
    let suffix = reachedMax ? " (stopped at the limit; more may remain)" : ""
    core.recordStep(description: "repeatWhileCanSelect \"\(selector.text)\" → \(iterations) time(s)\(suffix)",
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

/// ブロックを実行し、1ステップ(check)として message を記録する。ブロック内で1つ以上の
/// アサーション(assert 系コマンド・thisIs 系)が実行され全て成功すれば passed。
/// ブロック内のコマンドが失敗した場合は既定どおりシナリオを中断する(handleFailure は
/// 失敗した内側のコマンドが既に呼んでいるので、ここでは呼ばない=二重に証跡を撮らない)。
/// アサーションが1つも無ければ **inconclusive**(2026-08-03 ユーザー決定。Shirates の MANUAL
/// 相当は持たないが、失敗にもしない。理由つきステップ + 弱い修正提案で気付かせる)
public func verify(_ message: String, file: StaticString = #filePath, line: UInt = #line,
                   _ block: () -> Void) {
    let core = FTRuntime.requireCore(command: "verify")
    let description = "verify \"\(message)\""
    if core.scenarioAborted {
        core.recordStep(description: description, status: .skipped(core.skipReason),
                        file: "\(file)", line: Int(line))
        return
    }
    let outcome = core.runVerify(block)
    if outcome.failed {
        core.recordStep(description: description, status: .failed(message),
                        file: "\(file)", line: Int(line))
        return
    }
    if outcome.assertionCount == 0 {
        core.suggestVerifyWithoutAssertions(message: message)
        core.recordStep(description: description,
                        status: .inconclusive("verify block contains no assertions "
                                              + "(add exist / textIs / thisIs etc.)"),
                        file: "\(file)", line: Int(line))
        return
    }
    core.recordStep(description: description, status: .passed, file: "\(file)", line: Int(line))
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
/// action が true を返せば成功。waitSeconds 経過または maxLoopCount 到達で NG(シナリオ中断)。
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
                        "doUntilTrue \"\(title)\" did not hold within the \(maxLoopCount)-attempt limit")
                }
                if Date() >= deadline {
                    throw FTCommandError.message(
                        "doUntilTrue \"\(title)\" did not hold within \(FTSeconds.format(waitSeconds))s"
                        + " (\(loops) attempt(s))")
                }
                try await Task.sleep(nanoseconds: ftSleepNanoseconds(intervalSeconds))
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
/// クロージャ内では try / await が使える。throw は NG として記録されシナリオを中断する
public func procedure(_ title: String,
                      file: StaticString = #filePath, line: UInt = #line,
                      _ body: @escaping () async throws -> Void) {
    FTRuntime.requireCore(command: "procedure")
        .performCustom(description: "procedure \"\(title)\"", file: file, line: line, body)
}
