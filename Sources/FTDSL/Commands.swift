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

/// scene 失敗時に後続 scene も実行しない(データ依存の scene 連鎖用)
public func abortScenarioOnFailure(_ enabled: Bool = true) {
    FTRuntime.requireCore(command: "abortScenarioOnFailure").abortScenarioOnSceneFailure = enabled
}

// MARK: - 操作コマンド

/// timeout: 要素解決を待つ上限秒(0 = 初回スナップショットのみ。出るか不定な optional の
/// 空振り ~0.7s を数十msに短縮)。省略時は既定の再試行(約0.7秒)
public func tap(_ selector: String, optional: Bool = false, timeout: Int? = nil,
                file: StaticString = #filePath, line: UInt = #line) {
    let parsed = FTSelector.parse(selector)
    let step = FlowStep(action: "tap", locator: parsed.primary,
                        fallbacks: parsed.fallbacks.isEmpty ? nil : parsed.fallbacks,
                        timeout: timeout, optional: optional ? true : nil)
    FTRuntime.requireCore(command: "tap")
        .perform(step: step,
                 description: "tap \"\(selector)\"" + (optional ? " (optional)" : ""),
                 selectorText: selector, file: file, line: line)
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
    let parsed = FTSelector.parse(selector)
    let step = FlowStep(action: "type", locator: parsed.primary,
                        fallbacks: parsed.fallbacks.isEmpty ? nil : parsed.fallbacks,
                        text: text, timeout: timeout, optional: optional ? true : nil)
    FTRuntime.requireCore(command: "type")
        .perform(step: step, description: "type \"\(selector)\" \"\(text)\"",
                 selectorText: selector, file: file, line: line)
}

/// timeout: 要素解決を待つ上限秒(0 = 初回スナップショットのみ。出るか不定な optional の
/// 空振り ~0.7s を数十msに短縮)。省略時は既定の再試行(約0.7秒)
public func press(_ selector: String, duration: Double = 1.0, optional: Bool = false,
                  timeout: Int? = nil,
                  file: StaticString = #filePath, line: UInt = #line) {
    let parsed = FTSelector.parse(selector)
    let step = FlowStep(action: "press", locator: parsed.primary,
                        fallbacks: parsed.fallbacks.isEmpty ? nil : parsed.fallbacks,
                        timeout: timeout, optional: optional ? true : nil)
    FTRuntime.requireCore(command: "press")
        .perform(step: step, description: "press \"\(selector)\"",
                 selectorText: selector, file: file, line: line)
}

public func swipe(_ direction: FTSwipeDirection,
                  file: StaticString = #filePath, line: UInt = #line) {
    let step = FlowStep(action: "swipe", direction: direction.rawValue)
    FTRuntime.requireCore(command: "swipe")
        .perform(step: step, description: "swipe \(direction.rawValue)", file: file, line: line)
}

/// 要素が見つかるまでスクロールする(見つかったら成功。タップはしない)
public func scrollTo(_ selector: String, direction: FTSwipeDirection = .up, maxSwipes: Int = 8,
                     file: StaticString = #filePath, line: UInt = #line) {
    let parsed = FTSelector.parse(selector)
    let step = FlowStep(action: "scrollTo", locator: parsed.primary,
                        fallbacks: parsed.fallbacks.isEmpty ? nil : parsed.fallbacks,
                        direction: direction.rawValue, maxSwipes: maxSwipes)
    FTRuntime.requireCore(command: "scrollTo")
        .perform(step: step, description: "scrollTo \"\(selector)\"",
                 selectorText: selector, file: file, line: line)
}

// MARK: - 検証コマンド

/// 要素の存在検証。戻り値に .textIs / .valueIs をチェーンできる
/// (timeout 省略時は実行プロファイルの defaultTimeout、それも無ければ 5 秒)
/// 存在検証。既定で可視性も確認(= 実際に見えていることも確認): ツリー存在に加え、要素が別要素に
/// 覆われ/切れ/不在で見えていないかを FM で確認する(見えなければ失敗)。ツリー存在だけ見たい
/// (高速・アイコン等)場合は requireVisible: false。FM 未配線時は guard は素通り(存在のみと同じ)。
@discardableResult
public func exist(_ selector: String, timeout: Int? = nil, requireVisible: Bool = true,
                  file: StaticString = #filePath, line: UInt = #line) -> FTElement {
    let core = FTRuntime.requireCore(command: "exist")
    let parsed = FTSelector.parse(selector)
    let step = FlowStep(assert: "exists", locator: parsed.primary,
                        fallbacks: parsed.fallbacks.isEmpty ? nil : parsed.fallbacks,
                        timeout: timeout ?? core.defaultTimeout, occlusionGuard: requireVisible)
    core.perform(step: step, description: "exist \"\(selector)\"",
                 selectorText: selector, file: file, line: line)
    return FTElement(selector: selector)
}

/// テキスト一致検証。既定で可視性も確認(一致かつ実際に見えていること)。
/// 可視性を問わずテキスト一致だけ見たい場合は requireVisible: false。
public func textIs(_ selector: String, _ expected: String, timeout: Int? = nil,
                   requireVisible: Bool = true,
                   file: StaticString = #filePath, line: UInt = #line) {
    let core = FTRuntime.requireCore(command: "textIs")
    let parsed = FTSelector.parse(selector)
    let step = FlowStep(assert: "textEquals", locator: parsed.primary,
                        fallbacks: parsed.fallbacks.isEmpty ? nil : parsed.fallbacks,
                        expected: expected, timeout: timeout ?? core.defaultTimeout,
                        occlusionGuard: requireVisible)
    core.perform(step: step, description: "textIs \"\(selector)\" == \"\(expected)\"",
                 selectorText: selector, file: file, line: line)
}

/// 値一致検証。既定で可視性も確認(一致かつ実際に見えていること)。
/// 可視性を問わず値一致だけ見たい場合は requireVisible: false。
public func valueIs(_ selector: String, _ expected: String, timeout: Int? = nil,
                    requireVisible: Bool = true,
                    file: StaticString = #filePath, line: UInt = #line) {
    let core = FTRuntime.requireCore(command: "valueIs")
    let parsed = FTSelector.parse(selector)
    let step = FlowStep(assert: "valueEquals", locator: parsed.primary,
                        fallbacks: parsed.fallbacks.isEmpty ? nil : parsed.fallbacks,
                        expected: expected, timeout: timeout ?? core.defaultTimeout,
                        occlusionGuard: requireVisible)
    core.perform(step: step, description: "valueIs \"\(selector)\" == \"\(expected)\"",
                 selectorText: selector, file: file, line: line)
}

/// テキストの**部分一致**検証(動的な数値・日時を含む表示に使う)。
/// 完全一致は textIs。可視性の確認は「一致した部分文字列」で行う
public func textContains(_ selector: String, _ expected: String, timeout: Int? = nil,
                         requireVisible: Bool = true,
                         file: StaticString = #filePath, line: UInt = #line) {
    textAssert("textContains", verb: "textContains", selector: selector, expected: expected,
               timeout: timeout, requireVisible: requireVisible, file: file, line: line)
}

/// テキストの**正規表現一致**検証(部分一致。全体一致にしたいときは `^...$` を書く)。
/// 可視性の確認は「実際に一致した部分文字列」で行う(パターン文字列は画面に出ないため)
public func textMatches(_ selector: String, _ pattern: String, timeout: Int? = nil,
                        requireVisible: Bool = true,
                        file: StaticString = #filePath, line: UInt = #line) {
    textAssert("textMatches", verb: "textMatches", selector: selector, expected: pattern,
               timeout: timeout, requireVisible: requireVisible, file: file, line: line)
}

private func textAssert(_ assert: String, verb: String, selector: String, expected: String,
                        timeout: Int?, requireVisible: Bool,
                        file: StaticString, line: UInt) {
    let core = FTRuntime.requireCore(command: verb)
    let parsed = FTSelector.parse(selector)
    let step = FlowStep(assert: assert, locator: parsed.primary,
                        fallbacks: parsed.fallbacks.isEmpty ? nil : parsed.fallbacks,
                        expected: expected, timeout: timeout ?? core.defaultTimeout,
                        occlusionGuard: requireVisible)
    core.perform(step: step, description: "\(verb) \"\(selector)\" ~ \"\(expected)\"",
                 selectorText: selector, file: file, line: line)
}

/// 不在検証。**消えるまで待つ**(初回で不在なら即成功、在ればタイムアウトまで消滅を待つ)。
/// exist の裏返しであり、ダイアログ・ローディング・トーストが閉じたことの確認に使う。
/// 可視性(occlusion)は見ない — ツリーから消えたことが判定基準。
public func notExist(_ selector: String, timeout: Int? = nil,
                     file: StaticString = #filePath, line: UInt = #line) {
    let core = FTRuntime.requireCore(command: "notExist")
    let parsed = FTSelector.parse(selector)
    let step = FlowStep(assert: "notExists", locator: parsed.primary,
                        fallbacks: parsed.fallbacks.isEmpty ? nil : parsed.fallbacks,
                        timeout: timeout ?? core.defaultTimeout)
    core.perform(step: step, description: "notExist \"\(selector)\"",
                 selectorText: selector, file: file, line: line)
}

/// 要素が操作可能(enabled)であることの検証。タイムアウトまで状態変化を待つ
public func isEnabled(_ selector: String, timeout: Int? = nil,
                      file: StaticString = #filePath, line: UInt = #line) {
    enabledAssert("enabled", verb: "isEnabled", selector: selector, timeout: timeout,
                  file: file, line: line)
}

/// 要素が操作不可(disabled)であることの検証。タイムアウトまで状態変化を待つ
public func isDisabled(_ selector: String, timeout: Int? = nil,
                       file: StaticString = #filePath, line: UInt = #line) {
    enabledAssert("disabled", verb: "isDisabled", selector: selector, timeout: timeout,
                  file: file, line: line)
}

/// スイッチ・チェックボックス・ラジオが**オン**であることの検証。タイムアウトまで状態変化を待つ。
/// 取得元は iOS=accessibility の selected trait / Android=isChecked(ElementInfo.checked)。
/// **型が OS で揃わない要素(checkbox/radio)でも使える** — 状態は型と独立に取れるため
public func isChecked(_ selector: String, timeout: Int? = nil,
                      file: StaticString = #filePath, line: UInt = #line) {
    enabledAssert("checked", verb: "isChecked", selector: selector, timeout: timeout,
                  file: file, line: line)
}

/// スイッチ・チェックボックス・ラジオが**オフ**であることの検証。
/// 状態を持たない要素(ただのボタン等)も「オフ」として通る(ブリッジは true のときだけ送るため)
public func isNotChecked(_ selector: String, timeout: Int? = nil,
                         file: StaticString = #filePath, line: UInt = #line) {
    enabledAssert("notChecked", verb: "isNotChecked", selector: selector, timeout: timeout,
                  file: file, line: line)
}

/// enabled/disabled/checked/notChecked の共通実装(アサート名だけが違う)
private func enabledAssert(_ assert: String, verb: String, selector: String, timeout: Int?,
                           file: StaticString, line: UInt) {
    let core = FTRuntime.requireCore(command: verb)
    let parsed = FTSelector.parse(selector)
    let step = FlowStep(assert: assert, locator: parsed.primary,
                        fallbacks: parsed.fallbacks.isEmpty ? nil : parsed.fallbacks,
                        timeout: timeout ?? core.defaultTimeout)
    core.perform(step: step, description: "\(verb) \"\(selector)\"",
                 selectorText: selector, file: file, line: line)
}

/// 一致する要素の個数を検証する(リスト件数の確認など)。タイムアウトまで個数の変化を待つ。
/// `||` は他コマンドと同じ「解決できる方を使う」= **候補が見つかった最初の節だけ**を数える
/// (候補集合の合併ではない)。スコープと併用すると容器の中だけ数えられる:
/// countIs("#list >> .Cell", 3)
public func countIs(_ selector: String, _ expected: Int, timeout: Int? = nil,
                    file: StaticString = #filePath, line: UInt = #line) {
    let core = FTRuntime.requireCore(command: "countIs")
    let parsed = FTSelector.parse(selector)
    let step = FlowStep(assert: "count", locator: parsed.primary,
                        fallbacks: parsed.fallbacks.isEmpty ? nil : parsed.fallbacks,
                        timeout: timeout ?? core.defaultTimeout, expectedCount: expected)
    core.perform(step: step, description: "countIs \"\(selector)\" == \(expected)",
                 selectorText: selector, file: file, line: line)
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
    let selector: String

    @discardableResult
    public func textIs(_ expected: String, timeout: Int? = nil, requireVisible: Bool = true,
                       file: StaticString = #filePath, line: UInt = #line) -> FTElement {
        FTDSL.textIs(selector, expected, timeout: timeout, requireVisible: requireVisible,
                     file: file, line: line)
        return self
    }

    @discardableResult
    public func valueIs(_ expected: String, timeout: Int? = nil, requireVisible: Bool = true,
                        file: StaticString = #filePath, line: UInt = #line) -> FTElement {
        FTDSL.valueIs(selector, expected, timeout: timeout, requireVisible: requireVisible,
                      file: file, line: line)
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
    let core = FTRuntime.requireCore(command: "ifCanSelect")
    // 構文誤りは「不成立」と区別できない(どちらもブロックを飛ばして緑になる)ため、
    // perform を通らないこのコマンドでも実行前に検証する
    if let error = FTSelector.validationError(selector) {
        let reason = "セレクタの構文が不正です: \(error)"
        core.recordStep(description: "ifCanSelect \"\(selector)\"", status: .failed(reason),
                        file: "\(file)", line: Int(line))
        core.handleFailure(stepDescription: "ifCanSelect \"\(selector)\"", reason: reason)
        return FTBranch(taken: false)
    }
    let found = core.canSelect(FTSelector.parse(selector), waitSeconds: waitSeconds)
    // 不成立は **skipped** で記録する(passed にすると「セレクタが腐って毎回飛んでいる」状態が
    // 緑のまま見えなくなる)。run 終了時のサマリにも不成立を残す
    let description = "ifCanSelect \"\(selector)\" → \(found ? "実行" : "不成立")"
    core.recordStep(description: description,
                    status: found ? .passed : .skipped("条件不成立"),
                    file: "\(file)", line: Int(line))
    core.noteBranchOutcome(selector: selector, met: found)
    if found { body() }
    return FTBranch(taken: found)
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
    let core = FTRuntime.requireCore(command: "repeatWhileCanSelect")
    if let error = FTSelector.validationError(selector) {
        let reason = "セレクタの構文が不正です: \(error)"
        core.recordStep(description: "repeatWhileCanSelect \"\(selector)\"",
                        status: .failed(reason), file: "\(file)", line: Int(line))
        core.handleFailure(stepDescription: "repeatWhileCanSelect \"\(selector)\"", reason: reason)
        return
    }
    let label = title ?? "repeat \"\(selector)\""
    var iterations = 0
    let parsed = FTSelector.parse(selector)
    while iterations < max, core.canSelect(parsed, waitSeconds: waitSeconds) {
        iterations += 1
        core.runGroup("\(label) #\(iterations)", body)
        // dry-run は canSelect が常に true を返すため、1 周だけ回してステップ列挙に留める
        if core.isDryRun { break }
    }
    core.recordStep(description: "repeatWhileCanSelect \"\(selector)\" → \(iterations) 回",
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

/// 任意の Swift コード(データセットアップ等)を 1 ステップとして実行・記録する。
/// クロージャ内では try / await が使える。throw は NG として記録され scene を中断する
public func procedure(_ title: String,
                      file: StaticString = #filePath, line: UInt = #line,
                      _ body: @escaping () async throws -> Void) {
    FTRuntime.requireCore(command: "procedure")
        .performCustom(description: "procedure \"\(title)\"", file: file, line: line, body)
}
