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

public func tap(_ selector: String, optional: Bool = false,
                file: StaticString = #filePath, line: UInt = #line) {
    let parsed = FTSelector.parse(selector)
    let step = FlowStep(action: "tap", locator: parsed.primary,
                        fallbacks: parsed.fallbacks.isEmpty ? nil : parsed.fallbacks,
                        optional: optional ? true : nil)
    FTRuntime.requireCore(command: "tap")
        .perform(step: step,
                 description: "tap \"\(selector)\"" + (optional ? " (optional)" : ""),
                 selectorText: selector, file: file, line: line)
}

public func type(_ selector: String, _ text: String, optional: Bool = false,
                 file: StaticString = #filePath, line: UInt = #line) {
    let parsed = FTSelector.parse(selector)
    let step = FlowStep(action: "type", locator: parsed.primary,
                        fallbacks: parsed.fallbacks.isEmpty ? nil : parsed.fallbacks,
                        text: text, optional: optional ? true : nil)
    FTRuntime.requireCore(command: "type")
        .perform(step: step, description: "type \"\(selector)\" \"\(text)\"",
                 selectorText: selector, file: file, line: line)
}

public func press(_ selector: String, duration: Double = 1.0, optional: Bool = false,
                  file: StaticString = #filePath, line: UInt = #line) {
    let parsed = FTSelector.parse(selector)
    let step = FlowStep(action: "press", locator: parsed.primary,
                        fallbacks: parsed.fallbacks.isEmpty ? nil : parsed.fallbacks,
                        optional: optional ? true : nil)
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
@discardableResult
public func exist(_ selector: String, timeout: Int? = nil,
                  file: StaticString = #filePath, line: UInt = #line) -> FTElement {
    let core = FTRuntime.requireCore(command: "exist")
    let parsed = FTSelector.parse(selector)
    let step = FlowStep(assert: "exists", locator: parsed.primary,
                        fallbacks: parsed.fallbacks.isEmpty ? nil : parsed.fallbacks,
                        timeout: timeout ?? core.defaultTimeout)
    core.perform(step: step, description: "exist \"\(selector)\"",
                 selectorText: selector, file: file, line: line)
    return FTElement(selector: selector)
}

public func textIs(_ selector: String, _ expected: String, timeout: Int? = nil,
                   file: StaticString = #filePath, line: UInt = #line) {
    let core = FTRuntime.requireCore(command: "textIs")
    let parsed = FTSelector.parse(selector)
    let step = FlowStep(assert: "textEquals", locator: parsed.primary,
                        fallbacks: parsed.fallbacks.isEmpty ? nil : parsed.fallbacks,
                        expected: expected, timeout: timeout ?? core.defaultTimeout)
    core.perform(step: step, description: "textIs \"\(selector)\" == \"\(expected)\"",
                 selectorText: selector, file: file, line: line)
}

public func valueIs(_ selector: String, _ expected: String, timeout: Int? = nil,
                    file: StaticString = #filePath, line: UInt = #line) {
    let core = FTRuntime.requireCore(command: "valueIs")
    let parsed = FTSelector.parse(selector)
    let step = FlowStep(assert: "valueEquals", locator: parsed.primary,
                        fallbacks: parsed.fallbacks.isEmpty ? nil : parsed.fallbacks,
                        expected: expected, timeout: timeout ?? core.defaultTimeout)
    core.perform(step: step, description: "valueIs \"\(selector)\" == \"\(expected)\"",
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
    public func textIs(_ expected: String, timeout: Int? = nil,
                       file: StaticString = #filePath, line: UInt = #line) -> FTElement {
        FTDSL.textIs(selector, expected, timeout: timeout, file: file, line: line)
        return self
    }

    @discardableResult
    public func valueIs(_ expected: String, timeout: Int? = nil,
                        file: StaticString = #filePath, line: UInt = #line) -> FTElement {
        FTDSL.valueIs(selector, expected, timeout: timeout, file: file, line: line)
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
    let found = core.canSelect(FTSelector.parse(selector), waitSeconds: waitSeconds)
    core.recordStep(description: "ifCanSelect \"\(selector)\" → \(found ? "実行" : "不成立")",
                    status: .passed, file: "\(file)", line: Int(line))
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

/// 任意の Swift コード(データセットアップ等)を 1 ステップとして実行・記録する。
/// クロージャ内では try / await が使える。throw は NG として記録され scene を中断する
public func procedure(_ title: String,
                      file: StaticString = #filePath, line: UInt = #line,
                      _ body: @escaping () async throws -> Void) {
    FTRuntime.requireCore(command: "procedure")
        .performCustom(description: "procedure \"\(title)\"", file: file, line: line, body)
}
