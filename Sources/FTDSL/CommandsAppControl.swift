// CommandsAppControl.swift
// アプリ制御・スクリーンショット・分岐(ifCanSelect/FTBranch)・共通ステップとライフサイクル。
// 操作コマンドと共通経路の解説は Commands.swift 冒頭のコメント参照。

import Foundation
import FTCore


// MARK: - アプリ制御

/// アプリを起動する(引数省略時は @TestClass の app)。url を渡すと「起動 → URL 配送」を
/// 1ステップで行う(driver.openURL が再起動直後の warm な状態へそのまま届く)
public func launchApp(_ bundleID: String? = nil, url: String? = nil,
                      file: StaticString = #filePath, line: UInt = #line) {
    let core = FTRuntime.requireCore(command: "launchApp")
    let bundle = bundleID ?? core.appBundleID
    let driver = core.driver
    let description = url.map { "launch \(bundle) and open \($0)" } ?? "launch \(bundle)"
    core.performCustom(description: description, file: file, line: line,
                       launchTiming: { driver.lastLaunchTiming }) {
        try await driver.launch(bundleID: bundle)
        if let url {
            try await driver.openURL(url, bundleID: bundle)
        }
    }
}

/// 起動済みのアプリへ URL(ディープリンク)を配送する。画面遷移を飛ばして目的の画面から
/// 始めるためのもの
public func openURL(_ url: String, file: StaticString = #filePath, line: UInt = #line) {
    let core = FTRuntime.requireCore(command: "openURL")
    let driver = core.driver
    core.performCustom(description: "openURL \"\(url)\"", file: file, line: line) {
        try await driver.openURL(url, bundleID: core.appBundleID)
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

/// 前の画面へ戻る(Android = 戻るキー / iOS = ナビゲーションバーの戻るボタン、
/// 無ければ左端エッジスワイプ。Shirates の pressBack 相当)
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

