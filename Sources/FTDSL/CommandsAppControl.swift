// CommandsAppControl.swift
// アプリ制御・スクリーンショット・分岐(ifCanSelect/FTBranch)・共通ステップとライフサイクル。
// 操作コマンドと共通経路の解説は Commands.swift 冒頭のコメント参照。

import Foundation
import FTCore


// MARK: - アプリ制御

/// アプリを起動する(引数省略時は実行プロファイルのアプリ)。url を渡すと「起動 → URL 配送」を
/// 1ステップで行う(driver.openURL が再起動直後の warm な状態へそのまま届く)。
/// **配送は最初の画面が描かれてから**(`StepExecutor.awaitInteractiveUI` / LaunchURLReadiness): in-app の
/// launch はブリッジが答えた時点で返るので、JS が listener を登録する前に撃つと React Native は URL を捨てる
public func launchApp(_ appID: String? = nil, url: String? = nil,
                      file: StaticString = #filePath, line: UInt = #line) {
    let core = FTRuntime.requireCore(command: "launchApp")
    let bundle = appID ?? core.appBundleID
    let driver = core.driver
    let description = url.map { "launch \(bundle) and open \($0)" } ?? "launch \(bundle)"
    var deliveredBeforeUI = false
    core.performCustom(description: description, command: "launchApp", file: file, line: line,
                       launchTiming: { driver.lastLaunchTiming },
                       note: {
                           if deliveredBeforeUI { return .launchURLBeforeInteractiveUI }
                           return driver.lastLaunchTiming?.activatedBeforeForeground == true
                               ? .launchActivatedBeforeForeground : nil
                       }) {
        try await driver.launch(bundleID: bundle)
        if let url {
            deliveredBeforeUI = try await !core.executor.awaitInteractiveUI(
                timeoutMs: Int(core.defaultTimeout * 1000))
            try await driver.openURL(url, bundleID: bundle)
        }
    }
}

/// 起動済みのアプリへ URL(ディープリンク)を配送する。画面遷移を飛ばして目的の画面から
/// 始めるためのもの
public func openURL(_ url: String, file: StaticString = #filePath, line: UInt = #line) {
    let core = FTRuntime.requireCore(command: "openURL")
    let driver = core.driver
    core.performCustom(description: "openURL \"\(url)\"", command: "openURL", file: file, line: line) {
        try await driver.openURL(url, bundleID: core.appBundleID)
    }
}

/// アプリを終了してから起動し直す(scene 間の状態リセット用)。**データは消えない**
/// (消したいときは clearAppData)
public func restartApp(_ appID: String? = nil,
                       file: StaticString = #filePath, line: UInt = #line) {
    let core = FTRuntime.requireCore(command: "restartApp")
    let bundle = appID ?? core.appBundleID
    let driver = core.driver
    core.performCustom(description: "restart \(bundle)", command: "restartApp", file: file, line: line,
                       launchTiming: { driver.lastLaunchTiming },
                       note: {
                           driver.lastLaunchTiming?.activatedBeforeForeground == true
                               ? .launchActivatedBeforeForeground : nil
                       }) {
        try? await driver.terminate()
        try await driver.launch(bundleID: bundle)
    }
}

/// データだけ消す。初回起動・オンボーディング・権限ダイアログを何度でも再現するために使う。
/// Android は `pm clear` 相当。
///
/// **iOS の実機だけは「入れ直し」で代替する**(`ReinstallSource`)—— devicectl に同等手段が無く
/// ブリッジが 501 を返すため。MCP の `ft_clear_app_data` も同じ扱いをしている ——
/// DSL に受け皿が無いと**同じ端末・同じ意図の操作が経路によって割れる**。
/// 意味の差は2つ: **権限の付与も消える**(次の起動で OS のアラートが出る)/ install のぶん遅い。
/// どちらも注記 `reinstalled-to-clear-data` で報告に残す。
/// **消す前に入れ直せることを確かめる** —— 確かめずに uninstall すると端末からアプリだけ消える
public func clearAppData(_ appID: String? = nil,
                         file: StaticString = #filePath, line: UInt = #line) {
    let core = FTRuntime.requireCore(command: "clearAppData")
    let bundle = appID ?? core.appBundleID
    let driver = core.driver
    // 実行プロファイルが解決した配布物。実機の run では `appPathPhysical` が入っている
    // (RunOrchestrator / ApiRunCommand が `packagePath(physical:)` で決め、`--app-path` で届く)
    let profilePackage = core.appPackagePath
    let outcome = ClearAppDataOutcome()
    core.performCustom(description: "clearAppData \(bundle)", command: "clearAppData",
                       file: file, line: line,
                       note: { outcome.viaReinstall ? .reinstalledToClearData : nil }) {
        do {
            try await driver.clearAppData(bundleID: bundle)
        } catch let error where ReinstallSource.isClearAppDataUnsupported(error) {
            switch ReinstallSource.resolve(
                explicit: nil, remembered: profilePackage,
                exists: { FileManager.default.fileExists(atPath: $0) }
            ) {
            case .usable(let path):
                try await driver.uninstall(bundleID: bundle)
                if let note = try await driver.install(packagePath: path) { core.emit(.log("⚠️ \(note)")) }
                outcome.viaReinstall = true
            case .unknown:
                throw FTCommandError.message(
                    "clearAppData: a physical iOS device has no clearAppData, so the data is wiped"
                    + " by reinstalling the app — but no package path is known. Set"
                    + " \"appPathPhysical\" in the app profile to a device build, and run with"
                    + " --profile so it reaches the scenario.")
            case .missing(let path):
                throw FTCommandError.message(
                    "clearAppData: the app was NOT uninstalled. The reinstall source \(path) does"
                    + " not exist (a rebuild or clearing DerivedData can move or remove it) —"
                    + " rebuild the device package or fix \"appPathPhysical\" in the app profile.")
            }
        }
    }
}

/// `clearAppData` が実機で入れ直しに化けたかを、注記の評価まで運ぶだけの箱。
/// `performCustom` の body と note は別クロージャなので、可変ローカルでは渡せない
private final class ClearAppDataOutcome: @unchecked Sendable {
    var viaReinstall = false
}

public func terminateApp(file: StaticString = #filePath, line: UInt = #line) {
    let core = FTRuntime.requireCore(command: "terminateApp")
    let driver = core.driver
    core.performCustom(description: "terminate", command: "terminateApp", file: file, line: line) {
        try await driver.terminate()
    }
}

/// アプリをインストールする。**実行はオーケストレータ(親プロセス)の仕事**: 子は
/// installControl 経由で依頼を送るだけで、親が実行プロファイルの appPath 解決・実インストール・
/// (iOS inapp/hybrid の)再注入注記までを担う。appPackageFile 省略時は親側でプロファイルの appPath を
/// 解決する。ホスト無しの単独実行(installControl が nil)では子が直接
/// driver.install を呼び、パス解決は 明示引数 ?? --app-path(親が解決して渡した場合) ?? 明示エラー
public func installApp(_ appPackageFile: String? = nil,
                       file: StaticString = #filePath, line: UInt = #line) {
    let core = FTRuntime.requireCore(command: "installApp")
    let driver = core.driver
    let description = appPackageFile.map { "installApp \"\($0)\"" } ?? "installApp"
    core.performCustom(description: description, command: "installApp", file: file, line: line) {
        if let installControl = core.installControl {
            // 110s: FTSync.commandTimeout(120s。performCustom を包む外枠)より内側に収め、
            // ここで先に installApp 固有の理由を返す(外枠だと汎用の "operation timed out" になる)
            let (emit, scenarioID) = (core.emit, core.scenarioID)
            let result = await installControl.request(timeoutSeconds: 110) { id in
                var event = ScenarioEvent(kind: "installRequest")
                event.scenario = scenarioID
                event.requestID = id
                event.installPath = appPackageFile
                emit(event)
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
        if let note = try await driver.install(packagePath: expanded) { core.emit(.log("⚠️ \(note)")) }
    }
}

/// アプリをアンインストールする。nil のときは実行中アプリの既定 bundleID/package
/// (launchApp() 引数なしと同じ解決 = core.appBundleID)
public func removeApp(_ appID: String? = nil,
                      file: StaticString = #filePath, line: UInt = #line) {
    let core = FTRuntime.requireCore(command: "removeApp")
    let driver = core.driver
    let target = appID ?? core.appBundleID
    core.performCustom(description: "removeApp \"\(target)\"", command: "removeApp", file: file, line: line) {
        try await driver.uninstall(bundleID: target)
    }
}

/// appIs のポーリング(PollBackoff の再利用はコピペ禁止の契約。
/// Sources/FTCore/PollBackoff.swift 参照)。waitSeconds==0 でも初回照会は必ず1回行う
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

/// フォアグラウンドのアプリが appID(iOS=bundle ID / Android=package 名)と一致することの検証。
/// fleetest はニックネーム機構を持たないため、引数は ID そのもの。
/// waitSeconds までポーリングする。Android は失敗メッセージに actual の package 名を含める
/// (iOS は前面 bundle ID を取得する手段が無いため自然と省かれる。foregroundAppID 参照)
public func appIs(_ appID: String, waitSeconds: Double? = nil,
                  file: StaticString = #filePath, line: UInt = #line) {
    let core = FTRuntime.requireCore(command: "appIs")
    let waitSeconds = waitSeconds ?? core.tunables.screenWaitTimeout
    // **前面のアプリは XCUITest のランナーに聞く**(hybrid / xcuitest では `homeScreenDriver` = SpringBoard 参照のドライバ)。
    // 主ドライバ(hybrid では in-app)は自分のアプリが前面かどうかしか答えられず、`appIs("com.apple.Preferences")` が
    // 既定の hybrid で必ず赤になった。inapp 単独と Android は主ドライバに戻る(homeScreenDriver の既定)
    let driver = core.homeScreenDriver
    core.performCustom(description: "appIs \"\(appID)\"", command: "appIs", file: file, line: line,
                       isAssertion: true) {
        let matched = try await pollForegroundMatch(
            driver: driver, target: appID, waitSeconds: waitSeconds)
        guard !matched else { return }
        var message = "appIs \"\(appID)\" did not hold within \(FTSeconds.format(waitSeconds))s"
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
/// ファイル名省略時はステップ連番(.png)。Shirates の force/onChangedOnly/withXmlSource は未実装。
/// **ファイル名はラベル無し**(他の1引数コマンドと同じ。`screenshot(filename:)` は置かない =
/// UnavailableCommands.swift が受け止める)
public func screenshot(_ filename: String? = nil,
                       file: StaticString = #filePath, line: UInt = #line) {
    FTRuntime.requireCore(command: "screenshot").performScreenshot(
        filename: filename, file: file, line: line)
}

/// ホーム画面へ戻る
public func home(file: StaticString = #filePath, line: UInt = #line) {
    let core = FTRuntime.requireCore(command: "home")
    let driver = core.systemDriver
    core.performCustom(description: "home", command: "home", file: file, line: line) {
        try await driver.home()
    }
}

/// 前の画面へ戻る(Android = 戻るキー / iOS = ナビゲーションバーの戻るボタン、
/// 無ければ左端エッジスワイプ。Shirates の pressBack 相当)。
/// **自前ナビの画面(SwiftUI の `#btn_back` 等)はシステム back を無視することがある** ——
/// 判定・文言は MCP の ft_navigate と共有(FTCore.BackEffect)。before は毎回素直に1枚読む
/// (前回の back() の木を使い回すキャッシュは持たない。理由は BackEffect.swift 参照。
/// 「間に他のコマンドが挟まっていなければ使い回せる」形は back() が連続しない限り一度も
/// 発火せず、E2E 全 SUT で back() は各1回しか呼ばれないため実質恒久的に沈黙していた)
public func back(settle: Bool = true, file: StaticString = #filePath, line: UInt = #line) {
    let core = FTRuntime.requireCore(command: "back")
    let driver = core.systemDriver
    // **木を読むのは systemDriver ではなく driver**: hybrid の systemDriver は typeDriver
    // (AppAttachDriver)で、snapshot のたびに**テスト対象アプリを再前面化する**(このファイルの
    // homeScreenDriver の宣言参照)。前後で2回読むこの経路で使うと、観測のはずが画面を動かす。
    // 見たいのは「アプリの画面が back で変わったか」なので、対象アプリを映す driver が正しい。
    // 読めなければ黙る(判定材料が無いのに断定しない = MCP の ft_navigate と同じ規律)
    let observer = core.driver
    let executor = core.executor
    var observedNote: StepNote?
    core.performCustom(description: "back", command: "back", file: file, line: line, note: { observedNote }) {
        // 直前の type のキーボードが出きるのを先に待つ(StepExecutor.awaitKeyboardBeforeBack)
        try await executor.awaitKeyboardBeforeBack()
        let before = try? await observer.snapshot()
        // performCustom は FlowStep を通らないので、ドライバへ届く TaskLocal はここで入れる(`settle:` は tap を参照)
        try await SettleOverride.$skip.withValue(!settle) { try await driver.back() }
        guard let before, let after = try? await observer.snapshot() else { return }
        if BackEffect.shouldWarn(before: before, afterObservations: [after]) {
            observedNote = .backIneffective
        }
    }
}

/// フォーカス中の入力のキーボードを閉じる(冪等: 非表示中でも成功扱い)。
/// home/back と違い**アプリ内**のフォーカス操作なので systemDriver ではなく driver を使う
public func hideKeyboard(settle: Bool = true, file: StaticString = #filePath, line: UInt = #line) {
    // **StepExecutor を通す**(ドライバを直に呼ばない): 次のロケータ操作が木からキーボードが消えるのを
    // 待つ印(pendingHideKeyboardWait)を立てるのは executor の hideKeyboard だけ。MCP の ft_batch と同じ経路
    let step = FlowStep(action: "hideKeyboard", settle: stepSettle(settle))
    FTRuntime.requireCore(command: "hideKeyboard")
        .perform(step: step, description: "hideKeyboard", command: "hideKeyboard", file: file, line: line)
}

/// ホームボタンの iPhone で appSwitcher() をスキップとして記録するときの理由
/// (結果 JSON の skipReason・docs/commands.md と同文)
let appSwitcherHomeButtonSkipReason = "appSwitcher is not available on a home-button iPhone"
    + " (the switcher is a hardware double-press XCUITest cannot send)"

/// アプリスイッチャー(タスク一覧)を開く。
/// **ホームボタンの iPhone では撃たず、シナリオを「対象外(skipped)」で記録する**(失敗ではない)—— ブリッジが
/// 設計上 422 で断る操作(下端スワイプ上はコントロールセンター)で、書き手に直せる誤りではない。
/// 判定は文言ではなく画面の寸法(`BridgeAPI.isHomeButtonPhoneScreen`。iOS だけ・Android は対象外)
public func appSwitcher(file: StaticString = #filePath, line: UInt = #line) {
    let core = FTRuntime.requireCore(command: "appSwitcher")
    let driver = core.systemDriver
    if core.platform == "ios", !core.isDryRun, !core.scenarioAborted {
        // 観測は systemDriver ではなく driver(back() と同じ理由: hybrid の systemDriver は snapshot で対象アプリを前面化する)
        let observer = core.driver
        if let screen = FTSync.run({ try? await observer.snapshot().screen }) ?? nil,
           BridgeAPI.isHomeButtonPhoneScreen(width: screen.width, height: screen.height) {
            core.skipScenarioNotApplicable(description: "appSwitcher", command: "appSwitcher",
                                           reason: appSwitcherHomeButtonSkipReason, file: file, line: line)
            return
        }
    }
    core.performCustom(description: "appSwitcher", command: "appSwitcher", file: file, line: line) {
        try await driver.openAppSwitcher()
    }
}

/// ホーム画面のドロワー探索(Android)で試す上限回数。Shirates は無指定(打ち切りは
/// canSelectWithScrollDown の既定に委ねる)なので、ここでは妥当な値を独自に決める
private let tapAppIconAndroidMaxFlicks = 8
/// iOS のページ送り上限。ページインジケータを読めない(Runner が未対応)ため既定値固定
/// (docs 化していない残課題。ページ数が分かればそちらを使う設計に変更余地あり)
private let tapAppIconIOSMaxPages = 5
/// 対象アプリ以外のアイコンをタップした後の整定待ち(Shirates 準拠)。前面になったかを問える相手
/// (シナリオの対象アプリ)は `waitForAppForeground` が待つので、これは問えない相手の分だけ
private let tapAppIconSettleSeconds = 1.5

/// 前面になるまで `waitSeconds`(= `tunables.screenWaitTimeout`)ポーリングする。
/// 戻り値: true = 前面 / false = 問えて前面でなかった / nil = 一度も問えなかった(判定材料なし)。
/// **iOS 実機では `isAppForeground` が前面でなくても true を返しうる**(XCUIApplication.state が実機で
/// 信用できない)—— 検知が弱まるだけで、誤って赤にはならない
private func waitForAppForeground(driver: AppDriver, bundleID: String,
                                  waitSeconds: Double) async throws -> Bool? {
    let deadline = Date().addingTimeInterval(waitSeconds)
    var backoff = PollBackoff()
    var answered = false
    while true {
        try Task.checkCancellation()
        if let foreground = try? await driver.isAppForeground(bundleID: bundleID) {
            answered = true
            if foreground { return true }
        }
        if Date() >= deadline { return answered ? false : nil }
        try await Task.sleep(for: backoff.nextDelay())
    }
}

/// ホーム画面のアプリアイコンをタップする(Shirates tapAppIcon の auto 相当。
/// tapAppIconMethod・マクロ・カスタム関数は持たない)。
/// 名前省略時は親(オーケストレータ)が解決して渡したプロファイルの appName
/// (Shirates の appIconName 既定=プロファイル、に相当)。
/// 手順: home()(iOS はもう1回。Shirates 準拠) → 現在の画面で探す → 無ければ
/// Android はドロワーを開いてスクロール探索、iOS はページ送りしながら探索。
/// **撃つ前**: 画面を動かした直後のランチャー(ドロワーの慣性・ページ送り)は動いたままタップを
/// 「流れを止める操作」として飲む —— 目的のアイコンの枠が連続2枚の木で同じになるまで読み直してから撃つ。
/// **撃った後**: 対象アプリのアイコンなら前面になったかを確かめ、ならなければ失敗にする(**撃ち直さない**:
/// 届いていた場合の二重実行を避ける)
public func tapAppIcon(_ appIconName: String? = nil,
                       file: StaticString = #filePath, line: UInt = #line) {
    let core = FTRuntime.requireCore(command: "tapAppIcon")
    let driver = core.homeScreenDriver
    let platform = core.platform
    let resolvedName = appIconName ?? core.appDisplayName
    let description = resolvedName.map { "tapAppIcon \"\($0)\"" } ?? "tapAppIcon"
    core.performCustom(description: description, command: "tapAppIcon", file: file, line: line) {
        // 親(プロファイルの appName)からも取れないときだけ明示エラー
        guard let appIconName = resolvedName else {
            throw FTCommandError.message(
                "tapAppIcon: no icon name was given and the profile has no appName to resolve it "
                + "from. Pass the name explicitly (tapAppIcon(\"App Name\")) or set appName in "
                + "the app profile")
        }
        let waitSeconds = core.tunables.screenWaitTimeout

        // 枠が連続2枚で同じになるまで読み直す。待ちの上限は screenWaitTimeout(尽きたら最後の枠で撃つ —
        // 撃った後の前面確認が受ける)。消えたら nil(呼び手は探索を続ける)
        func settledIcon(from first: ElementInfo) async throws -> (icon: ElementInfo?, snapshot: SnapshotResponse?) {
            var icon = first
            var latest: SnapshotResponse?
            let deadline = Date().addingTimeInterval(waitSeconds)
            while Date() < deadline {
                try Task.checkCancellation()
                let next = try await driver.snapshot()
                latest = next
                guard let found = AppIconLocator.findIcon(appIconName, in: next) else { return (nil, next) }
                if found.frame == icon.frame { return (found, next) }
                icon = found
            }
            return (icon, latest)
        }

        // タップ後の共通処理。xcuitest 単独では springboard 参照が**主ドライバと同じランナーの
        // セッションを springboard に付け替える**ため、張り直さないと以降の要素コマンドが
        // springboard のツリーを黙って読む(実機で確認)。タップ先がシナリオ対象アプリのときだけ
        // 張り直す(activate は /session の再バインド+前面化で状態を保持する。
        // 対象外アプリを開いた場合はそのまま = xcuitest は対象アプリ以外を駆動しない)
        func afterTap(_ icon: ElementInfo) async throws {
            guard appIconName == core.appDisplayName else {
                // 前面かを問える相手がいない(任意の名前のアプリ)ので固定の整定待ちだけ
                try await Task.sleep(nanoseconds: ftSleepNanoseconds(tapAppIconSettleSeconds))
                return
            }
            let foreground = try await waitForAppForeground(driver: driver, bundleID: core.appBundleID,
                                                            waitSeconds: waitSeconds)
            if foreground == nil {
                // 一度も問えなかった = 判定材料なし。失敗にはせず、従来どおり固定の整定待ち
                try await Task.sleep(nanoseconds: ftSleepNanoseconds(tapAppIconSettleSeconds))
                return
            }
            guard foreground == true else {
                let x = icon.frame.x + icon.frame.width / 2
                let y = icon.frame.y + icon.frame.height / 2
                throw FTCommandError.message(
                    "tapAppIcon \"\(appIconName)\": tapped the icon at (\(Int(x)),\(Int(y))) but "
                    + "\(core.appBundleID) did not come to the foreground within \(FTSeconds.format(waitSeconds))s")
            }
            if core.homeScreenSharesRunnerSession {
                try await core.driver.activate(bundleID: core.appBundleID)
            }
        }

        // 中心が画面の外にある枠は撃たない(AppIconLocator.isCentreOnScreen の doc)。木が直るまで読み直し
        // (上限 waitSeconds)、直らなければ失敗(消えたら nil = 呼び手は探索を続ける)
        func onScreenIcon(_ first: ElementInfo, in tree: SnapshotResponse) async throws
            -> (icon: ElementInfo?, snapshot: SnapshotResponse) {
            var icon = first
            var latest = tree
            let deadline = Date().addingTimeInterval(waitSeconds)
            while !AppIconLocator.isCentreOnScreen(icon, in: latest) {
                guard Date() < deadline else {
                    let centre = AppIconLocator.centre(of: icon)
                    let where_ = "(centre (\(Int(centre.x)),\(Int(centre.y))) of "
                        + "\(Int(latest.screen.width))x\(Int(latest.screen.height)))"
                    let waited = "\(FTSeconds.format(waitSeconds))s"
                    throw FTCommandError.message(
                        "tapAppIcon \"\(appIconName)\": the home screen reports the icon outside the screen "
                        + where_ + " and it stayed there for " + waited
                        + ", so it was not tapped — the system UI tree does not match the shown display on this device")
                }
                try Task.checkCancellation()
                latest = try await driver.snapshot()
                guard let found = AppIconLocator.findIcon(appIconName, in: latest) else { return (nil, latest) }
                icon = found
            }
            return (icon, latest)
        }

        // 安定した枠のアイコンを1回だけ撃ち、後始末をする。撃てたら true
        // (安定待ちの間にアイコンが消えた・画面の外のままなら撃たず false)
        func tapSettled(_ first: ElementInfo) async throws -> (tapped: Bool, snapshot: SnapshotResponse?) {
            let (settled, snapshot) = try await settledIcon(from: first)
            guard var icon = settled else { return (false, snapshot) }
            if let tree = snapshot {
                let (onScreen, latest) = try await onScreenIcon(icon, in: tree)
                guard let onScreen else { return (false, latest) }
                icon = onScreen
            }
            try await driver.tap(ref: icon.ref)
            try await afterTap(icon)
            return (true, snapshot)
        }

        // 内蔵画面が2枚の Simulator だけ: 木の画面が表示中の画面の大きさと違えば、探しても撃っても当たらないので失敗
        // (AppIconLocator.treeMatchesShownDisplay の doc)。実機・udid 不明は何もしない。単画面の Simulator も devicectl を1回
        // 呼んで nil を受け(0.14 秒・M2 Ultra)何もしない —— 木の画面の寸法だけでは「内側の画面の寸法か」を決められない
        func checkHomeScreenTreeMatchesDisplay(_ tree: SnapshotResponse) throws {
            guard platform == "ios", !core.physical, let udid = core.deviceIdentifier,
                  let shown = SimulatorActiveDisplay.resolve(udid: udid)?.pointSize,
                  !AppIconLocator.treeMatchesShownDisplay(screen: tree.screen,
                                                          shownWidth: shown.width, shownHeight: shown.height)
            else { return }
            throw FTCommandError.message(
                "tapAppIcon \"\(appIconName)\": the home screen tree reports a "
                + "\(Int(tree.screen.width))x\(Int(tree.screen.height)) screen but the shown display is "
                + "\(Int(shown.width))x\(Int(shown.height)) — the system UI tree does not match the shown display "
                + "on this device, so nothing was tapped")
        }

        try await driver.home()
        if platform == "ios" { try await driver.home() }

        var last = try await driver.snapshot()
        try checkHomeScreenTreeMatchesDisplay(last)
        if let icon = AppIconLocator.findIcon(appIconName, in: last) {
            let (tapped, snapshot) = try await tapSettled(icon)
            if tapped { return }
            if let snapshot { last = snapshot }
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
                                      pressSeconds: FlowStep.defaultDragPressSeconds, durationSeconds: core.tunables.defaultFlickDuration)
            } else {
                // 座標を作れない(画面が小さすぎる等): 向き基準の汎用スワイプへ落ちる
                // (flick アクションの座標算出失敗と同じ扱い)
                try await driver.swipe(kind.fingerDirection)
            }

            last = try await driver.snapshot()
            if let icon = AppIconLocator.findIcon(appIconName, in: last) {
                let (tapped, snapshot) = try await tapSettled(icon)
                if tapped { return }
                if let snapshot { last = snapshot }
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
        .performCustom(description: "wait \(FTSeconds.format(seconds))s", command: "wait", file: file, line: line,
                       paced: false) {
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

/// FlowStep を通らない待ち(ifCanSelect / repeatWhileCanSelect / doUntilTrue)の秒数の検査。範囲外は
/// `IdleAllowance.during` の `Int(秒 * 1000)` で trap し、`.infinity` は期限が無くなる。断ったら失敗を記録して true。
/// dry-run でも断る(実行より前の検査 = セレクタの構文誤りと同じ扱い)
private func rejectsOutOfRangeSeconds(_ core: FTDriveCore, _ values: KeyValuePairs<String, Double>,
                                      description: String, command: String,
                                      file: StaticString, line: UInt) -> Bool {
    guard let reason = values.lazy.compactMap({ FlowStep.secondsViolation($0.key, $0.value) }).first else {
        return false
    }
    core.recordStep(description: description, status: .failed(reason), file: "\(file)", line: Int(line),
                    command: command)
    core.handleFailure(stepDescription: description, reason: reason)
    return true
}

@discardableResult
private func ifCanSelectImpl(_ selector: FTSelector, waitSeconds: Double,
                             file: StaticString, line: UInt,
                             _ body: () -> Void) -> FTBranch {
    let core = FTRuntime.requireCore(command: "ifCanSelect")
    if rejectsOutOfRangeSeconds(core, ["waitSeconds": waitSeconds], description: "ifCanSelect \"\(selector.text)\"",
                                command: "ifCanSelect", file: file, line: line) {
        return FTBranch(taken: false)
    }
    // 構文誤りは「不成立」と区別できない(どちらもブロックを飛ばして緑になる)ため、
    // perform を通らないこのコマンドでも実行前に検証する
    if let error = validationError(selector) {
        let reason = "invalid selector syntax: \(error)"
        core.recordStep(description: "ifCanSelect \"\(selector.text)\"", status: .failed(reason),
                        file: "\(file)", line: Int(line), command: "ifCanSelect")
        core.handleFailure(stepDescription: "ifCanSelect \"\(selector.text)\"", reason: reason)
        return FTBranch(taken: false)
    }
    let outcome = core.canSelect(selector, waitSeconds: waitSeconds)
    let found = outcome.found
    // 不成立は **skipped** で記録する(passed にすると「セレクタが腐って毎回飛んでいる」状態が
    // 緑のまま見えなくなる)。run 終了時のサマリにも不成立を残す
    let description = "ifCanSelect \"\(selector.text)\" → \(found ? "ran" : "not met")"
        + interruptSuffix(outcome)
    core.recordStep(description: description,
                    status: found ? .passed : .skipped("condition not met"),
                    file: "\(file)", line: Int(line),
                    notes: outcome.dismissed == nil ? [] : [.interruptionDismissed],
                    command: "ifCanSelect")
    core.noteBranchOutcome(selector: selector.text, met: found)
    if found { body() } else { core.noteUnexecutedBlock() }
    return FTBranch(taken: found, enumeratesBothBranches: core.isDryRun)
}

/// **宣言済みの割り込みを自動で閉じない区間**(Shirates 準拠の名前)。
/// シナリオ自身がそのモーダルを検証・操作したいときに使う —— これが無いと
/// 「`irregularHandler` を宣言する場所をずらす」という回避策になる(自前 E2E でも実際にそうしていた)。
///
/// **止まるのは「ツールが閉じること」だけ**: 割り込みが出ること自体はアプリの都合なので、
/// 抑止しても「送った操作が吸われる」形は変わらない(責務は docs/commands.md の表)。
///
/// **ブロック形と命令形の使い分け**: こちらは**出口で必ず戻る**(途中で失敗しても戻る)が、
/// **1つの CAE ブロックの内側にしか置けない**。`condition` で止めて `expectation` で戻す形は
/// `disableHandler()` / `enableHandler()` でしか書けない(ユーザー指摘)。
///
/// **OS のシステムダイアログ(権限の許可等)はここでは止まらない** —— あちらはシナリオの
/// `iosAlertHandler` による自動押下で、別の機構(そもそも要求した要素が解決できるときは
/// 自動押下は走らない = シナリオの操作を奪わない)
public func suppressHandler(_ body: () -> Void) {
    let core = FTRuntime.requireCore(command: "suppressHandler")
    core.executor.handlerSuppressionDepth += 1
    defer { core.executor.handlerSuppressionDepth -= 1 }
    body()
}

/// `suppressHandler { }` / `disableHandler()` の内側で**一時的に自動クローズを戻す**。
/// 抑止していない場所で呼んでも何も変わらない
public func useHandler(_ body: () -> Void) {
    let core = FTRuntime.requireCore(command: "useHandler")
    let savedDepth = core.executor.handlerSuppressionDepth
    let savedDisabled = core.executor.handlersDisabled
    core.executor.handlerSuppressionDepth = 0
    core.executor.handlersDisabled = false
    defer {
        core.executor.handlerSuppressionDepth = savedDepth
        core.executor.handlersDisabled = savedDisabled
    }
    body()
}

/// **CAE のブロックを跨いで**自動クローズを止める(Shirates 準拠。`enableHandler()` で戻す)。
/// `suppressHandler { }` は1つの CAE ブロックの内側にしか置けないので、
/// 「`condition` で止めて `expectation` で戻す」はこちらでしか書けない(ユーザー指摘)。
///
/// **戻し忘れはシナリオの終わりまで効く**。中断した場合、以降の画面操作は afterEach だけなので、
/// 片付けが割り込みに吸われうる点だけ意識する(気になるなら `suppressHandler { }` を使う)
public func disableHandler() {
    FTRuntime.requireCore(command: "disableHandler").executor.handlersDisabled = true
}

/// `disableHandler()` を戻す。`suppressHandler { }` の抑止には影響しない
/// (ブロック形はブロックの出口で必ず戻るため)
public func enableHandler() {
    FTRuntime.requireCore(command: "enableHandler").executor.handlersDisabled = false
}

/// perform を通らないコマンド(ifCanSelect / repeatWhileCanSelect)用。判定は perform と同じ源
private func validationError(_ selector: FTSelector) -> String? {
    selector.preflightError
}

/// 条件判定の最中に割り込みを閉じたことを説明文へ足す。**文言は perform 経路と同じ形**
/// (StepExecutor.noteWithInterrupt。読み手が同じものだと分かるように揃える)。
/// **不成立でも必ず出す** —— 「覆いを閉じたうえで無かった」と「覆われたまま無いことにした」は
/// 読み手にとって別物で、後者を黙って返すのは不具合
private func interruptSuffix(_ outcome: FTDriveCore.CanSelectOutcome) -> String {
    guard let dismissed = outcome.dismissed else { return "" }
    let times = dismissed.count > 1 ? " ×\(dismissed.count)" : ""
    return "(dismissed the interruption \(dismissed.key)\(times))"
}

public struct FTBranch {
    let taken: Bool
    /// dry-run(デバイス無しの列挙)。**成立側に加えて `.ifElse` 側も列挙する** ——
    /// dry-run の `canSelect` は常に成立なので、ここを実行しないと else 側のセレクタ構文誤り・
    /// 台帳に無い `#id` がデバイス実行まで出てこない(3段検証「誤りは早い段の言葉で返す」に反する)。
    /// デバイス実行では成立側が走ったら else は未実行
    let enumeratesBothBranches: Bool

    init(taken: Bool, enumeratesBothBranches: Bool = false) {
        self.taken = taken
        self.enumeratesBothBranches = enumeratesBothBranches
    }

    /// 直前の分岐が不成立だった場合にブロックを実行する。
    /// **成立していた場合はこちらが未実行**なので記録する(ifCanSelect 側と対称。理由は
    /// FTDriveCore.sectionUnexecutedBlocks)。dry-run では両側を列挙するので未実行の記録はしない
    /// (アサーションは両側から数えられる)
    public func ifElse(_ body: () -> Void) {
        if taken, !enumeratesBothBranches {
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
/// DSL にループが無いので、これが無いと「ガード付き反復を上限回数ぶん並べる」形になる。
/// **各周回のステップ説明には `[名前 #n]` が前置される**(group と同じ記録規約)。
/// 上限に達しても失敗にはしない(消化しきれなかったことは記録に残る)。
/// 本体が要素を減らさないと上限まで空回りするので、max は想定最大件数に合わせる
public func repeatWhileCanSelect(_ selector: String, maxLoopCount: Int = 10, waitSeconds: Double = 0,
                                 title: String? = nil,
                                 file: StaticString = #filePath, line: UInt = #line,
                                 _ body: () -> Void) {
    repeatWhileCanSelectImpl(FTSelector.parse(selector), maxLoopCount: maxLoopCount, waitSeconds: waitSeconds,
                             title: title, file: file, line: line, body)
}

public func repeatWhileCanSelect(_ selector: Sel, maxLoopCount: Int = 10, waitSeconds: Double = 0,
                                 title: String? = nil,
                                 file: StaticString = #filePath, line: UInt = #line,
                                 _ body: () -> Void) {
    repeatWhileCanSelectImpl(selector.ftSelector, maxLoopCount: maxLoopCount, waitSeconds: waitSeconds,
                             title: title, file: file, line: line, body)
}

private func repeatWhileCanSelectImpl(_ selector: FTSelector, maxLoopCount: Int, waitSeconds: Double,
                                      title: String?,
                                      file: StaticString, line: UInt,
                                      _ body: () -> Void) {
    let core = FTRuntime.requireCore(command: "repeatWhileCanSelect")
    if rejectsOutOfRangeSeconds(core, ["waitSeconds": waitSeconds],
                                description: "repeatWhileCanSelect \"\(selector.text)\"",
                                command: "repeatWhileCanSelect", file: file, line: line) {
        return
    }
    if let error = validationError(selector) {
        let reason = "invalid selector syntax: \(error)"
        core.recordStep(description: "repeatWhileCanSelect \"\(selector.text)\"",
                        status: .failed(reason), file: "\(file)", line: Int(line),
                        command: "repeatWhileCanSelect")
        core.handleFailure(stepDescription: "repeatWhileCanSelect \"\(selector.text)\"",
                           reason: reason)
        return
    }
    let label = title ?? "repeat \"\(selector.text)\""
    var iterations = 0
    var dismissedInterruption: FTDriveCore.CanSelectOutcome = .init(found: false, dismissed: nil)
    while iterations < maxLoopCount {
        let outcome = core.canSelect(selector, waitSeconds: waitSeconds)
        // 閉じた事実は**最後に閉じた周回のもの**を残す(周回ごとに記録を増やさない)
        if outcome.dismissed != nil { dismissedInterruption = outcome }
        guard outcome.found else { break }
        iterations += 1
        core.runGroup("\(label) #\(iterations)", body)
        // dry-run は canSelect が常に true を返すため、1 周だけ回してステップ列挙に留める
        if core.isDryRun { break }
    }
    // **上限で止まったのか、出尽くしたのかを区別できるようにする**。`→ 10 回` だけだと
    // 「ちょうど 10 件だった」のか「まだ残っているのに打ち切った」のかが記録から読めない
    // (成功扱いにする契約は変えない = 上限到達を失敗にはしない)
    let reachedMax = iterations >= maxLoopCount && maxLoopCount > 0 && !core.isDryRun
    // 0 周 = 本体を一度も実行していない(ios/android の不一致と同じ扱い。runSection 参照)
    if iterations == 0 { core.noteUnexecutedBlock() }
    let suffix = reachedMax ? " (stopped at the limit; more may remain)" : ""
    core.recordStep(description: "repeatWhileCanSelect \"\(selector.text)\" → \(iterations) time(s)\(suffix)"
                        + interruptSuffix(dismissedInterruption),
                    status: .passed, file: "\(file)", line: Int(line),
                    notes: dismissedInterruption.dismissed == nil ? [] : [.interruptionDismissed],
                    command: "repeatWhileCanSelect")
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
/// アサーションが1つも無ければ **inconclusive**(ユーザー決定。Shirates の MANUAL
/// 相当は持たないが、失敗にもしない。理由つきステップ + 弱い修正提案で気付かせる)
public func verify(_ message: String, file: StaticString = #filePath, line: UInt = #line,
                   _ body: () -> Void) {
    let core = FTRuntime.requireCore(command: "verify")
    let description = "verify \"\(message)\""
    if core.scenarioAborted {
        core.recordStep(description: description, status: .skipped(core.skipReason),
                        file: "\(file)", line: Int(line), command: "verify")
        return
    }
    let outcome = core.runVerify(body)
    if outcome.failed {
        core.recordStep(description: description, status: .failed(message),
                        file: "\(file)", line: Int(line), command: "verify")
        return
    }
    if outcome.assertionCount == 0 {
        core.suggestVerifyWithoutAssertions(message: message)
        core.recordStep(description: description,
                        status: .inconclusive("verify block contains no assertions "
                                              + "(add exist / textIs / thisIs etc.)"),
                        file: "\(file)", line: Int(line), command: "verify")
        return
    }
    core.recordStep(description: description, status: .passed, file: "\(file)", line: Int(line),
                    command: "verify")
}

/// @TestClass マクロが beforeEach() の呼び出しを包むために生成する(利用者が直接書くものではない)。
/// beforeEach 内の失敗はシナリオ全体を中断させる(前提が崩れた状態で本体を走らせない)。
public func ftRunBeforeEach(_ body: () -> Void) {
    FTRuntime.requireCore(command: "beforeEach").runLifecycle("beforeEach", allowAfterFailure: false, body)
}

/// @TestClass マクロが beforeAll() の呼び出しを包むために生成する(利用者が直接書くものではない)。
/// **run 全体でクラスごとに1回**(Shirates の beforeAll と同じ名前)。受け持つシナリオは親が決め(`core.runBeforeAll`)、
/// 親はそれが終わるまで他のデバイスでこのクラスのシナリオを起動しない。"began" を出した後は結果が不明でも撃ち直さない
/// (at-most-once)。失敗はシナリオ中断で、このクラスの残りのシナリオは親が走らせずに落とす。
/// 中断・画面凍結・ユーザー停止で本体が走らなかったときは "began" も出さない(親は未試行へ戻し、別のシナリオが受け持ち直す)。
/// 値を他のシナリオへ渡すのは writeMemo(メモは run 全体で共有)
public func ftRunBeforeAll(_ body: () -> Void) {
    let core = FTRuntime.requireCore(command: "beforeAll")
    guard core.runBeforeAll, !core.scenarioAborted, !core.deviceFrozen, !core.stoppedByUser else { return }
    func event(_ status: String) -> ScenarioEvent {
        var event = ScenarioEvent(kind: "beforeAll")
        event.status = status
        return event
    }
    core.emit(event("began"))
    core.runLifecycle("beforeAll", allowAfterFailure: false, body)
    core.emit(event(core.scenarioAborted || core.deviceFrozen || core.stoppedByUser ? "failed" : "passed"))
}

/// @TestClass マクロが setUpDevice() の呼び出しを包むために生成する(利用者が直接書くものではない)。
/// 走らせるかは親が決める(`core.runSetUpDevice`)。**親は「試行した」時点で済み印を付ける**ので、
/// 結果が不明でも同じデバイスで撃ち直されない。失敗はシナリオ中断(後続シナリオは親が走らせずに落とす)。
/// 中断・画面凍結・ユーザー停止で本体が走らなかったときは "began" も出さない。
/// setUpDevice で設定したインスタンスのプロパティは**このシナリオのプロセスだけ**で見える
/// (他のシナリオへは writeMemo / readMemo で渡す)
public func ftRunSetUpDevice(_ body: () -> Void) {
    let core = FTRuntime.requireCore(command: "setUpDevice")
    guard core.runSetUpDevice, !core.scenarioAborted, !core.deviceFrozen, !core.stoppedByUser else { return }
    func event(_ status: String) -> ScenarioEvent {
        var event = ScenarioEvent(kind: "deviceSetUp")
        event.status = status
        return event
    }
    core.emit(event("began"))
    core.runLifecycle("setUpDevice", allowAfterFailure: false, body)
    core.emit(event(core.scenarioAborted || core.deviceFrozen || core.stoppedByUser ? "failed" : "passed"))
}

/// @TestClass マクロが afterEach() の呼び出しを包むために生成する(利用者が直接書くものではない)。
/// **失敗後でも実行される**(片付けが飛ぶと後続シナリオを汚すため)。中断フラグは実行後に復元する。
public func ftRunAfterEach(_ body: () -> Void) {
    let core = FTRuntime.requireCore(command: "afterEach")
    // 本体の検証の描画崩壊は afterEach が画面を動かす前に確かめる(片付けの起動で壊れた絵が消える)
    core.renderCollapseCheckpoint("at the end of the scenario")
    core.runLifecycle("afterEach", allowAfterFailure: true, body)
}

/// @TestClass マクロが afterAll() の呼び出しを包むために生成する(利用者が直接書くものではない)。
/// 呼ばれるのは `--after-all-only` の専用の子だけ(親が run の全デバイスの仕事の後に、run × クラスで1回起こす)。
/// beforeAll の成否に関わらず走る(片付け)。メモは読める
public func ftRunAfterAll(_ body: () -> Void) {
    FTRuntime.requireCore(command: "afterAll").runLifecycle("afterAll", allowAfterFailure: true, body)
}

/// @TestClass マクロが tearDownDevice() の呼び出しを包むために生成する(利用者が直接書くものではない)。
/// 呼ばれるのは `--device-teardown-only` の専用の子だけ(親がデバイスの仕事の後に1クラス1回起こす)
public func ftRunTearDownDevice(_ body: () -> Void) {
    FTRuntime.requireCore(command: "tearDownDevice").runLifecycle("tearDownDevice", allowAfterFailure: true, body)
}

/// 条件が満たされるまでブロックを繰り返す(Shirates の doUntilTrue 相当)。**ブロックの中で DSL のコマンドを呼べる**
/// (Shirates の基本形 `{ scrollDown(); canSelect(...) }`)—— DSL スレッドで同期に実行する(repeatWhileCanSelect と同じ)。
/// 1周ごとに `"<title> #n"` のまとまりとして記録し、最後に結果を1ステップ残す。
/// ブロックが true を返せば成功。waitSeconds 経過または maxLoopCount 到達で NG(シナリオ中断)。
/// ブロックが throw したら**リトライせず**その場で NG(状態の待ちと実行時エラーを混ぜない)。
/// 中の DSL コマンドが失敗したらシナリオの中断に従って止まる(その失敗は記録済みなので重ねて記録しない)。
/// **1つのステップではない**ので、コマンド1つの締切(FTSync.commandTimeout)は掛からず waitSeconds だけで止まる。
/// 上限は時計で測り、中の操作の前でステップの減速が待った分は差し引く(負荷が高いときだけ試せる回数が減らないように)。
/// dry-run は1周だけ回して中のステップを列挙する
public func doUntilTrue(_ title: String, waitSeconds: Double? = nil, intervalSeconds: Double? = nil,
                        maxLoopCount: Int? = nil,
                        file: StaticString = #filePath, line: UInt = #line,
                        _ body: () throws -> Bool) {
    let core = FTRuntime.requireCore(command: "doUntilTrue")
    let description = "doUntilTrue \"\(title)\""
    if core.scenarioAborted {
        core.recordStep(description: description, status: .skipped(core.skipReason), file: "\(file)", line: Int(line),
                        command: "doUntilTrue")
        return
    }
    let waitSeconds = waitSeconds ?? core.tunables.doUntilTrueTimeout
    let intervalSeconds = intervalSeconds ?? core.tunables.doUntilTrueInterval
    let maxLoopCount = maxLoopCount ?? core.tunables.doUntilTrueMaxLoopCount
    if rejectsOutOfRangeSeconds(core, ["waitSeconds": waitSeconds, "intervalSeconds": intervalSeconds],
                                description: description, command: "doUntilTrue", file: file, line: line) {
        return
    }
    let clock = ContinuousClock()
    let start = clock.now
    var deadline = Date().addingTimeInterval(waitSeconds)
    var loops = 0
    var failure: (reason: String, kind: StepFailureKind?)?
    // 本体が DSL を呼ばない素の Swift なら周回の間は出力が無い。期限を越える最後の1周の間隔までを親の idle 打ち切りへ
    // 申告する(1周の本体そのものの長さは分からない = 本体が長く黙るなら申告の外)
    IdleAllowance.during(seconds: waitSeconds + (intervalSeconds.isFinite ? max(0, intervalSeconds) : 0)) {
        while true {
            let pacedBefore = core.pacedMsTotal.value
            var held = false
            var thrown: Error?
            core.runGroup("\(title) #\(loops + 1)") {
                do { held = try body() } catch { thrown = error }
            }
            loops += 1
            deadline += Double(core.pacedMsTotal.value - pacedBefore) / 1000
            if core.scenarioAborted { return }  // 申告を閉じてから下でもう一度見て抜ける
            if let thrown {
                failure = (thrown.localizedDescription, StepExecutor.failureKind(thrown: thrown))
                break
            }
            if held || core.isDryRun { break }
            if loops >= maxLoopCount {
                failure = ("doUntilTrue \"\(title)\" did not hold within the \(maxLoopCount)-attempt limit", nil)
                break
            }
            if Date() >= deadline {
                failure = ("doUntilTrue \"\(title)\" did not hold within \(FTSeconds.format(waitSeconds))s"
                           + " (\(loops) attempt(s))", nil)
                break
            }
            // 負値・NaN は 0 に丸める(UInt64 へ直す経路と同じ規律。trap させない)
            Thread.sleep(forTimeInterval: intervalSeconds.isFinite ? max(0, intervalSeconds) : 0)
        }
    }
    if core.scenarioAborted { return }
    let durationMs = continuousClockMilliseconds(clock.now - start)
    if let failure {
        core.recordStep(description: description, status: .failed(failure.reason), file: "\(file)", line: Int(line),
                        durationMs: durationMs, command: "doUntilTrue", failureKind: failure.kind)
        core.handleFailure(stepDescription: description, reason: failure.reason)
    } else {
        core.recordStep(description: "\(description) → \(loops) attempt(s)", status: .passed, file: "\(file)",
                        line: Int(line), durationMs: durationMs, command: "doUntilTrue")
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

/// 手順に名前を付けて1つにまとめる(Shirates の procedure = describe + silent)。**ブロックの中で DSL のコマンドを呼べる**
/// —— DSL スレッドで同期に実行する(repeatWhileCanSelect / doUntilTrue と同じ)。中のステップは `[title]` を前置して
/// 記録し、**レポート(.md)では畳む**(成功・skip は出さず `procedure "title"` の1行だけ。失敗・判定不能・フォールバック・
/// 自己修復・screenshot() の絵は畳まない = ScenarioReportWriter)。結果 JSON・イベントには全部残す。
/// 中のコマンドが失敗したらシナリオ中断に従って止まる(その失敗が記録に残るので重ねて記録しない)。
/// throw したらその場で NG。**1つのステップではない**ので FTSync のコマンド上限は掛からない。
/// 中の生の Swift コードは、前段が失敗していれば走らない(scene のブロックと違う = 失敗後に走らせたくない処理の置き場)。
/// dry-run でも中を実行する(中の DSL は dry-run の扱いになる。生の Swift は scene のブロックと同じく走る)
public func procedure(_ title: String,
                      file: StaticString = #filePath, line: UInt = #line,
                      _ body: () throws -> Void) {
    let core = FTRuntime.requireCore(command: "procedure")
    let description = "procedure \"\(title)\""
    if core.scenarioAborted {
        core.recordStep(description: description, status: .skipped(core.skipReason), file: "\(file)", line: Int(line),
                        command: "procedure")
        return
    }
    let clock = ContinuousClock()
    let start = clock.now
    var thrown: Error?
    core.procedureDepth += 1
    core.runGroup(title) {
        do { try body() } catch { thrown = error }
    }
    core.procedureDepth -= 1
    if core.scenarioAborted { return }
    let durationMs = continuousClockMilliseconds(clock.now - start)
    if let thrown {
        let reason = thrown.localizedDescription
        core.recordStep(description: description, status: .failed(reason), file: "\(file)", line: Int(line),
                        durationMs: durationMs, command: "procedure", failureKind: StepExecutor.failureKind(thrown: thrown))
        core.handleFailure(stepDescription: description, reason: reason)
    } else {
        core.recordStep(description: description, status: .passed, file: "\(file)", line: Int(line),
                        durationMs: durationMs, command: "procedure")
    }
}

