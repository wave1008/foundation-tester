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
func perform(_ command: String, _ selector: FTSelector, step: FlowStep,
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
                containerInference: Bool? = nil,
                file: StaticString = #filePath, line: UInt = #line) {
    tapImpl(FTSelector.parse(selector), holdSeconds: holdSeconds, timeout: timeout,
            scroll: scroll, maxSwipes: maxSwipes, containerInference: containerInference,
            file: file, line: line)
}

public func tap(_ selector: Sel, holdSeconds: Double = FlowStep.defaultTapHoldSeconds,
                timeout: Double? = nil,
                scroll: FTScrollDirection? = nil, maxSwipes: Int = FlowStep.defaultMaxSwipes,
                containerInference: Bool? = nil,
                file: StaticString = #filePath, line: UInt = #line) {
    tapImpl(selector.ftSelector, holdSeconds: holdSeconds, timeout: timeout,
            scroll: scroll, maxSwipes: maxSwipes, containerInference: containerInference,
            file: file, line: line)
}

/// `scroll:` は**同じステップに畳む**(別の scrollTo ステップを作らない)。
/// 利用者が書いたのは1コマンドなので記録も1行にする — 書いていない行が現れると、
/// その行はソース行を持たないためジャンプも修正提案の照合もできず、説明の要る状態になる。
/// `withScrollDown(scrollFrame:) { }` が積んだスクロール領域を FlowStep 用に解決する。
/// **探索するときだけ意味を持つ**(scroll 未指定 = 現在画面だけを見るので領域は無関係)
func contextScrollFrame(_ core: FTDriveCore, scrolling: Bool) -> FlowLocator? {
    guard scrolling, let expression = core.effectiveScrollFrame(nil) else { return nil }
    return FTSelector.parse(expression).primary
}

/// 探索の実体は StepExecutor.runScrollSearch(scrollTo コマンドと共有)
private func tapImpl(_ selector: FTSelector, holdSeconds: Double, timeout: Double?,
                     scroll: FTScrollDirection?, maxSwipes: Int, containerInference: Bool?,
                     file: StaticString, line: UInt) {
    let core = FTRuntime.requireCore(command: "tap")
    let scroll = core.effectiveScroll(scroll)
    let step = FlowStep(action: "tap", locator: selector.primary,
                        fallbacks: selector.stepFallbacks,
                        direction: scroll?.swipe.rawValue,
                        timeout: timeout, maxSwipes: scroll == nil ? nil : maxSwipes,
                        // 既定(0 = 通常タップ)は載せない(生成コード・ヒールキャッシュを太らせない)
                        duration: holdSeconds == FlowStep.defaultTapHoldSeconds ? nil : holdSeconds,
                        containerInference: core.effectiveContainerInference(containerInference),
                        scrollFrame: contextScrollFrame(core, scrolling: scroll != nil))
    let hold = holdSeconds == FlowStep.defaultTapHoldSeconds ? "" : " (hold \(FTSeconds.format(holdSeconds))s)"
    perform("tap", selector, step: step,
            description: "tap \"\(selector.text)\"" + hold,
            file: file, line: line)
}

/// フォーカス中の要素にテキストを送信する(直前の tap でフォーカスした欄など。ロケータ指定なし)。
/// ref なし = ブリッジがフォーカス中要素へ入力する(StepExecutor がロケータ解決を挟まず driver.type(ref: nil) を呼ぶ)。
/// **セレクタを渡す引数落としは実行前に落とす**(FTSelector.selectorLikeInputError)
public func type(_ text: String, replace: Bool = false,
                 file: StaticString = #filePath, line: UInt = #line) {
    var step = FlowStep(action: "type", text: text)
    step.replace = replace ? true : nil
    let suffix = replace ? " (replace)" : ""
    FTRuntime.requireCore(command: "type")
        .perform(step: step, description: "type \"\(text)\"\(suffix)",
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
public func type(_ selector: String, _ text: String, replace: Bool = false, timeout: Double? = nil,
                 scroll: FTScrollDirection? = nil, maxSwipes: Int = FlowStep.defaultMaxSwipes,
                 file: StaticString = #filePath, line: UInt = #line) {
    typeImpl(FTSelector.parse(selector), text, replace: replace, timeout: timeout,
             scroll: scroll, maxSwipes: maxSwipes, file: file, line: line)
}

public func type(_ selector: Sel, _ text: String, replace: Bool = false, timeout: Double? = nil,
                 scroll: FTScrollDirection? = nil, maxSwipes: Int = FlowStep.defaultMaxSwipes,
                 file: StaticString = #filePath, line: UInt = #line) {
    typeImpl(selector.ftSelector, text, replace: replace, timeout: timeout,
             scroll: scroll, maxSwipes: maxSwipes, file: file, line: line)
}

private func typeImpl(_ selector: FTSelector, _ text: String, replace: Bool, timeout: Double?,
                      scroll: FTScrollDirection?, maxSwipes: Int,
                      file: StaticString, line: UInt) {
    let core = FTRuntime.requireCore(command: "type")
    let scroll = core.effectiveScroll(scroll)
    var step = FlowStep(action: "type", locator: selector.primary,
                        fallbacks: selector.stepFallbacks,
                        text: text, direction: scroll?.swipe.rawValue, timeout: timeout,
                        maxSwipes: scroll == nil ? nil : maxSwipes,
                        scrollFrame: contextScrollFrame(core, scrolling: scroll != nil))
    step.replace = replace ? true : nil
    let suffix = replace ? " (replace)" : ""
    perform("type", selector, step: step,
            description: "type \"\(selector.text)\" \"\(text)\"\(suffix)", file: file, line: line)
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

/// Rotates the app UI to the given orientation (`.portrait` / `.landscape` — the contract is what
/// the app ends up in, not how the device is tilted; see `FTOrientation`). The original orientation
/// (captured on the first call in this scenario) is restored automatically when the scenario ends.
public func rotateTo(_ orientation: FTOrientation,
                     file: StaticString = #filePath, line: UInt = #line) {
    let step = FlowStep(action: "rotateTo", direction: orientation.rawValue)
    FTRuntime.requireCore(command: "rotateTo")
        .perform(step: step, description: "rotateTo \(orientation.rawValue)", file: file, line: line)
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

/// ブロック内のコマンドで、容器の推測に依存する補正(見切れ判定・掴み直し・救済ドラッグ・
/// 見えている部分を撃つ座標補正・壊れた座標の候補除外)を止める
public func withoutContainerInference(_ body: () -> Void) {
    FTRuntime.requireCore(command: "withoutContainerInference").runWithContainerInference(false, body)
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
                     containerInference: Bool? = nil,
                     file: StaticString = #filePath, line: UInt = #line) {
    scrollToImpl(FTSelector.parse(selector), direction: direction, scrollFrame: scrollFrame,
                 startMarginRatio: startMarginRatio, endMarginRatio: endMarginRatio,
                 maxSwipes: maxSwipes, containerInference: containerInference,
                 file: file, line: line)
}

public func scrollTo(_ selector: Sel, direction: FTScrollDirection = .down,
                     scrollFrame: String? = nil,
                     startMarginRatio: Double? = nil, endMarginRatio: Double? = nil,
                     maxSwipes: Int = FlowStep.defaultMaxSwipes,
                     containerInference: Bool? = nil,
                     file: StaticString = #filePath, line: UInt = #line) {
    scrollToImpl(selector.ftSelector, direction: direction, scrollFrame: scrollFrame,
                 startMarginRatio: startMarginRatio, endMarginRatio: endMarginRatio,
                 maxSwipes: maxSwipes, containerInference: containerInference,
                 file: file, line: line)
}

private func scrollToImpl(_ selector: FTSelector, direction: FTScrollDirection,
                          scrollFrame: String?, startMarginRatio: Double?,
                          endMarginRatio: Double?, maxSwipes: Int, containerInference: Bool?,
                          file: StaticString, line: UInt) {
    let core = FTRuntime.requireCore(command: "scrollTo")
    let frame = core.effectiveScrollFrame(scrollFrame)
    let step = FlowStep(action: "scrollTo", locator: selector.primary,
                        fallbacks: selector.stepFallbacks,
                        direction: direction.swipe.rawValue, maxSwipes: maxSwipes,
                        containerInference: core.effectiveContainerInference(containerInference),
                        scrollFrame: frame.map(FTSelector.parse)?.primary,
                        startMarginRatio: startMarginRatio, endMarginRatio: endMarginRatio)
    perform("scrollTo", selector, step: step, description: "scrollTo \"\(selector.text)\"",
            file: file, line: line)
}

