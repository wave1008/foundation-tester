// StepExecutor+Actions.swift
// アクション実行(executeAction と drag/doubleTap/pinch のフォールバック。typeDriver 経由の type/press/clear は
// +TypeClear・swipe のフォールバックは +Settle 側)。本体は StepExecutor.swift(instance 状態はそちらに置く)

import Foundation

extension StepExecutor {

    /// `waitSeconds:` を省いた操作がロケータを探し直す回数。待ちは `PollBackoff` の最初のこの回数ぶん
    /// (`defaultLocatorRetrySeconds`)。変えるときは docs/commands.md の `waitSeconds:` 省略時の表と
    /// user-docs の tap / select_and_assert(約 0.7 秒と書いている)も直す
    static let defaultLocatorRetryAttempts = 3

    /// 既定の探し直しの待ちの合計[秒](撮影の時間は含まない)。失敗文に出す数字の唯一の出どころ
    static var defaultLocatorRetrySeconds: Double {
        var backoff = PollBackoff()
        let total = (0..<defaultLocatorRetryAttempts).reduce(Duration.zero) { sum, _ in sum + backoff.nextDelay() }
        return Double(total.components.seconds) + Double(total.components.attoseconds) / 1e18
    }

    /// 既定の短い待ち(`waitSeconds:` 省略)のまま見つからなかったときだけ、延ばし方を添える。
    /// 指定した待ちで見つからなかったなら待ちの長さが原因とは言えないので何も足さない
    static func defaultWaitHint(_ step: FlowStep) -> String {
        guard step.timeout == nil else { return "" }
        let seconds = String(format: "%.1f", defaultLocatorRetrySeconds)
        return ". Without waitSeconds: this command looks for the element for only about \(seconds) s;"
            + " if it appears later (for example right after a screen transition), add waitSeconds: to this step"
            + " (for example waitSeconds: 5)"
    }

    func executeAction(_ action: String, step: FlowStep,
                               fingerprint: LocatorFingerprint? = nil,
                               phase: inout PhaseAccumulator) async throws -> StepOutcome {
        var step = step
        // waitForSettle は待ちの上限を必ず持たせてから解決する(ft_batch は waitSeconds 省略時に nil で来る)。
        // **上限の無いステップの解決は、容器の外の残骸(ghost)を戻すために容器を送る** = 待つだけのコマンドが画面を動かす。
        // 探す時間も waitSeconds ではなく約 0.7 秒(3回)になる
        if action == "waitForSettle", step.timeout == nil { step.timeout = waitForSettleSeconds(for: step).wait }
        // **デバイスに触る前に、入口1箇所で**ジェスチャの秒数を検査する(FlowStep.duration を
        // 使う action 全部: tap の長押し・flick・pinchOut/pinchIn・swipeBy・swipeElementToElement)。
        // duration が nil(既定のまま)は検査しない
        if let violation = FlowStep.gestureDurationViolation(
            action: action, duration: step.duration, maxGestureSeconds: step.maxGestureSeconds) {
            return StepOutcome(status: .failed(violation))
        }
        // waitForSettle の quietSeconds / waitSeconds もデバイスに触る前に入口で断る(範囲は BridgeAPI が定義元)
        if action == "waitForSettle", let violation = waitForSettleViolation(for: step) {
            return StepOutcome(status: .failed(violation))
        }
        let clock = ContinuousClock()
        let actionStart = clock.now   // waitForSettle の待ち時間(範囲の要素の解決を含む)の起点
        cachedScreenshot = nil   // 画面を変える操作 → occlusion-guard スクショ再利用を無効化
        // 直前の操作の記録は**次の操作が画面を変えるまで**有効(検証は画面を変えないので消さない)。
        // `select` は掴むだけでデバイス操作が無いので例外 —— `tap → select → textIs` という
        // 一番ありふれた形で、落ちるのは textIs 側だから、ここで消すと肝心なときに証跡が無くなる
        // 掴むだけでデバイスを動かさないアクション(スクロールしない findImage / findImages も同じ)。
        // waitForSettle は待つだけで画面にも焦点にも触れないので同じ扱い(`tap → waitForSettle → 検証` で証跡を消さない)
        let grabsOnly = action == "select" || action == "waitForSettle"
            || (Self.isFindImageAction(action) && step.direction == nil)
        if action == "tap" {
            previousTapTree = lastInteraction?.before
            // 前のタップは、このタップが解決に使う木と比べてから確定する(tapAwaitingNextTree の doc)
            tapAwaitingNextTree = lastInteraction
            lastInteraction = nil
        } else if !grabsOnly {
            lastInteraction = nil
            tapAwaitingNextTree = nil
            unchangedEarlierTaps = []
        }
        // 焦点救済の「直前」は tap → type の並びだけ(select は掴むだけで焦点を動かさない)
        if !grabsOnly, action != "type" { lastTapTarget = nil }
        pendingScrollFrameNote = nil
        spanScale = 1
        // **OS のシステム UI が被さっている間は、どのアクションも撃たない**(SystemUIGate)。
        // ロケータ不要のアクション(swipe / scroll / tap(x:y:) / pressEnter / type(文字列) 等)は
        // 下で早期 return するので、ここで通さないと覆いを素通りする。①(シナリオ自身が
        // アラートを操作している)の判定は step.locator が要るので、locator を取らない
        // アクションでは②③(閉じる/待って落ちる)だけが働く = 正しい
        if let blocked = try await waitOutSystemUI(step: step, phase: &phase) {
            return StepOutcome(status: blocked)
        }
        // **登録が無いとき**の安い防御: launch 系の直後の**最初の触る操作**で1回だけ SpringBoard に
        // 聞き、前面にアラートがあれば注記と助言(題名・ボタン)を残す。操作は止めない
        // (閉じるのはシナリオの責務)。受け手報告: 再インストール後の通知 → ATT の
        // 2枚が登録漏れのまま前面にあり、背面の操作が緑になっていた
        if systemAlertProbePending,
           Self.interactsByTouch(action) || action == "type" || action == "swipe" {
            systemAlertProbePending = false
            if let probe = await unregisteredSystemAlert(phase: &phase) {
                systemAlertAdvisoryThisStep = SystemUIGate.unregisteredAdvice(
                    SystemUIGate.describeUnregistered(probe), title: probe.title,
                    currentAppDisplayName: expectedAppDisplayName)
            }
        }
        // ロケータ不要のアクション
        if Self.isFindImageAction(action) {
            return try await executeFindImage(action, step: step, phase: &phase)
        }
        if action == "swipe" {
            return try await executeDirectSwipe(step: step, phase: &phase)
        }
        if action == "rotateTo" {
            return try await executeDirectRotateTo(step: step, phase: &phase)
        }
        if action == "scroll" {
            return try await executeDirectScroll(step: step, phase: &phase)
        }
        if action == "scrollToEdge" {
            return try await executeDirectScrollToEdge(step: step, phase: &phase)
        }
        if action == "flick" {
            return try await executeDirectFlick(step: step, phase: &phase)
        }
        if action == "tap", let x = step.x, let y = step.y, step.locator == nil,
           step.fallbacks?.isEmpty ?? true {
            return try await executeDirectCoordinateTap(step: step, x: x, y: y, phase: &phase)
        }
        if action == "swipePointToPoint" {
            return try await executeDirectPointToPoint(step: step, phase: &phase)
        }
        if Self.gestureActions.contains(action), step.locator == nil,
           step.fallbacks?.isEmpty ?? true {
            return try await executeDirectUntargetedGesture(action, step: step, phase: &phase)
        }
        if action == "scrollTo" {
            return try await executeDirectScrollTo(step: step, phase: &phase)
        }
        if action == "type", step.locator == nil, step.fallbacks?.isEmpty ?? true {
            return try await executeDirectUnfocusedType(step: step, phase: &phase)
        }
        if action == "pressEnter" {
            return try await executeDirectPressEnter(phase: &phase)
        }
        if action == "hideKeyboard" {
            return try await executeDirectHideKeyboard(step: step, phase: &phase)
        }
        if action == "clearInput", step.locator == nil, step.fallbacks?.isEmpty ?? true {
            return try await executeDirectUnfocusedClearInput(phase: &phase)
        }
        // holdEnd はロケータを取らない(何も送らない・ブリッジが離す時刻まで待つだけ)
        if action == "holdEnd" {
            return try await executeHoldEnd(step: step, phase: &phase)
        }
        // 範囲の指定が無い waitForSettle は画面全体。指定があるときは下の通常の解決(スクロールはしない)を通り、
        // 解決できなければ throwsException に関わらず失敗する(`case "waitForSettle"`)
        if action == "waitForSettle", step.locator == nil, step.fallbacks?.isEmpty ?? true {
            let waited = try await executeWaitForSettle(step: step, region: nil, startedAt: actionStart, phase: &phase)
            return StepOutcome(status: waited.status, driverFallback: waited.note)
        }

        // `tap(scroll:)` 等の内蔵スクロール探索。**別ステップにしない**のは
        // 利用者が書いたのは1コマンドだから(記録に scrollTo 行が増えると、書いていない行が
        // 現れ、しかもソース行を持たないためジャンプも修正提案の照合もできない)。
        // 探索は runScrollSearch が静止まで面倒を見るので、以降は通常の解決へ進んでよい
        // 探索がスワイプを撃ったか。直後の解決 snapshot も**キャッシュを捨てて**撮るために立てる
        // (探索が最後に見た木は新しいのに、ここで古い木を掴むと**見つけたはずの要素が消えて**
        // `cannot resolve the locator` になる。CMP/Android で実測した失敗そのもの)
        var searchSwiped = false
        if step.direction != nil, step.locator != nil {
            let result = try await runScrollSearch(step: step, phase: &phase)
            scrollSearchNote = recordedScrollSearchNote(result, scrollFrameNote: pendingScrollFrameNote)
            guard result.found else {
                // select はスクロール探索で見つからなくても空要素を返す契約(下の解決経路と同じ)
                if action == "select" {
                    return StepOutcome(status: .skipped(Self.selectNotFoundReason))
                }
                // **scrollFrame の申告は失敗文へ畳んで返す**: 探索が空振りした理由がそこにある
                // のに、`StepOutcome(status:)` だけの return は driverFallback を運ばないので
                // `scrollSearchNote` が捨てられていた(MCP の失敗文にも一度も出ていなかった)。
                // 実測: 同名 `#recycler_view` が4つある画面で先頭の横チップ行を
                // 掴んだまま「element not found」としか言わず、曖昧だったことが伝わらなかった
                let why = pendingScrollFrameNote.map { " (\($0))" } ?? ""
                return StepOutcome(status: failed(.notFound, Self.scrollNotFoundMessage(step, result, defaultMaxSwipes: tunables.defaultMaxSwipes) + why))
            }
            searchSwiped = true
        }

        // ロケータ解決の再試行(ファイル冒頭のセマンティクス参照: 最大3回、計700ms)
        var start = clock.now
        // 素取得が既に見た木より古いかもしれなければ、この 1 枚はキャッシュを迂回する(nextResolveBypassesCache の doc)
        let freshness: SnapshotFreshness = nextResolveBypassesCache
            ? .afterOwnMove : .afterSearch(swiped: searchSwiped)
        nextResolveBypassesCache = false
        var snapshot = try await freshSnapshot(freshness)
        phase.snapshotMs += Self.ms(clock.now - start)
        // 起動直後の最初のロケータ操作だけ、配置の静止を待ってから解決する(pendingLaunchSettle の doc)。
        // **settledSignature が自分で phase へ計上する**(ここでは足さない)
        if pendingLaunchSettle {
            pendingLaunchSettle = false
            let settled = try await settledSignature(phase: &phase)
            snapshot = settled.snapshot
            if settled.changed { noteCodesThisStep.insert(.settledAfterLaunch) }
        }
        // **直前の type が「打つ前後」でキーボードを動かしたか、ここで初めて確かめる**
        // (pendingTypeKeyboardCheck の doc)。上の freshSnapshot は元々撮る1枚なので、
        // 動いていなければ比較だけで追加コストはゼロ。動いていたときだけ収束を待って撮り直す。
        // **読み返し(verifiesTypedText)の有無やモードに依存しない** —— type を実行した
        // ドライバが何であれ、ここで木を見て比べる
        // 前の type の出現待ちを待ち切った後、キーボードが今ここで出ていれば上限不足の事例として数える
        if keyboardWaitExhausted,
           Self.keyboardOnScreen(snapshot.keyboardFrame, screen: snapshot.screen) {
            keyboardWaitExhausted = false
            noteCodesThisStep.insert(.keyboardAppearedLate)
        }
        if pendingTypeKeyboardCheck {
            snapshot = try await consumePendingTypeKeyboardCheck(snapshot, phase: &phase)
        }
        // hideKeyboard の後、木がまだキーボードを申告していれば消えるまで待つ(pendingHideKeyboardWait の doc)。
        // 消えた後は整定を見る(下端の要素が戻り、中身が伸びる)
        if pendingHideKeyboardWait != nil {
            snapshot = try await consumePendingHideKeyboardWait(snapshot, phase: &phase)
        }
        // 宣言された割り込み(アプリ内メッセージ等)が出ていれば先に閉じる。**解決を試みる前**に
        // 行う: 覆われているだけで要素自体は解決できてしまい、タップが吸われる形があるため
        // (層3 の coveringHint と同じ事象。あちらは診断、こちらは宣言があるときの自動処理)
        try await dismissInterruption(in: &snapshot, phase: &phase)
        var resolved = LocatorResolver.resolve(step: step, in: snapshot)
        // **切り詰めが原因の未発見に、リトライ/ghost 救済の予算を燃やさない**。
        // ここで撮り直さないと、下のリトライループが全予算(バックオフ3回 or step.timeout 全部)を
        // 当たるはずのない既定上限のスナップショットで使い切ってから、ループを抜けた後の
        // 1回でようやく天井に当たる。**ghost 救済(実ジェスチャで画面を動かす)より前**に置く ——
        // 切り詰めが原因なら画面を動かさずに解決できる。以後の読みは freshSnapshot がラッチ経由で
        // 自動的に天井を維持する(elementLimitCeilingLatchedThisStep の doc)
        if resolved == nil, snapshot.truncatedCount > 0, !elementLimitCeilingLatchedThisStep {
            elementLimitCeilingLatchedThisStep = true
            snapshot = try await retakenAtElementLimitCeiling(snapshot, phase: &phase)
            resolved = LocatorResolver.resolve(step: step, in: snapshot)
        }
        // **探索の直後は容器の外に並ぶ ghost 行を掴むことがある**(Compose iOS は容器の外にも
        // 子を報告する。docs/verification.md「Compose の探索直後タップ」)。掴んだままタップすると
        // 容器の外を撃って**黙って飲まれる**(値が変わらないので、後段の検証だけが落ちて原因が遠い)。
        // 探索ループの中では同じ判定で「もう1回送る」をしているが、**ループを抜けた後の再解決には
        // 効いていなかった**のが残存フレークの正体。
        // 判定は `isOutsideContainer`(容器と**交差しない** = 完全に外)。
        //
        // **またぎ(縁をまたぐ要素)まで対象に広げてはいけない**(試して撤回)。
        // 「掴み直し+送り直し」の対象を `isClippedByViewport`(= 完全に外もまたぎも拾う)へ
        // 統一したところ、S0110 の失敗が **2/10 → 5/10 に悪化**した。失敗はいずれも救済が発火し、
        // tap が 4.0s → 7.2〜8.2s に伸びたうえで**「対象があの後 9〜14pt 動いた」**で落ちている
        // = 縁で救済スワイプを撃つと、わずかに動いた先の座標でタップすることになり自傷する。
        // **またぎは探索ループ側の見切れ判定に任せる**(あちらは掴む前に送るので座標が古くならない)
        // **このステップが探索したかは条件にしない**(外した): ghost は
        // 「直前の探索」ではなく**アプリがスクロールしていること**の帰結で、木にはその後も
        // 残り続ける。`scrollTo` と `tap` を別ステップで書く(利用者の自然な書き方)と
        // searchSwiped が false になり、**防御がまるごと素通り**していた —— 実測では
        // `tap` が容器の外を撃って画面が何も変わらず、後段の検証だけが落ちていた
        func grabbedGhost(_ candidate: (ElementInfo, FlowLocator?)?) -> Bool {
            guard let element = candidate?.0, step.containerInference ?? true
            else { return false }
            return ContainerGeometry.isOutsideContainer(element, in: snapshot.elements, screen: snapshot.screen)
        }
        var ghostRetries = 0
        var ghostSwipes = 0
        if resolved == nil || grabbedGhost(resolved) {
            if let timeout = step.timeout {
                // timeout == 0: リトライなし(初回スナップショットのみ。ifCanSelect/select の空振り短縮用)
                if timeout > 0 {
                    let retryDeadline = clock.now.advanced(by: .seconds(timeout))
                    var backoff = PollBackoff()
                    while resolved == nil || grabbedGhost(resolved), clock.now < retryDeadline {
                        start = clock.now
                        try await Task.sleep(for: backoff.nextDelay())
                        phase.waitMs += Self.ms(clock.now - start)
                        start = clock.now
                        // 探索後の再試行もキャッシュを捨てる。古い木は撮り直しても同じものが
                        // 返るので、素取得だと**再試行の予算をまるごと空振りに使う**
                        snapshot = try await freshSnapshot(.repoll(afterSearchSwiped: searchSwiped))
                        phase.snapshotMs += Self.ms(clock.now - start)
                        // **探し直している間に湧いた割り込みも閉じる**(まだ撃つ前なので撃ち直しの問題は無い。
                        // 責務表の「操作可能になるのを待っている間」と同じ扱い)。実測(Apple マップ): 出発地を選んだ
                        // 後の「安全に目的地に到達するために」が、次の手の経路カードを探す間に出て、閉じないまま時間切れ
                        try await dismissInterruption(in: &snapshot, phase: &phase)
                        let previous = resolved
                        resolved = LocatorResolver.resolve(step: step, in: snapshot)
                        if previous != nil { ghostRetries += 1 }
                    }
                }
            } else {
                var backoff = PollBackoff()
                for attempt in 0..<Self.defaultLocatorRetryAttempts {
                    start = clock.now
                    try await Task.sleep(for: backoff.nextDelay())
                    phase.waitMs += Self.ms(clock.now - start)
                    // **撮り直しだけでは戻らないことがある**(実測: 3回撮り直しても
                    // 容器の外に報告されたまま = タップが飲まれて `selected=-`)。
                    // 探索ループと同じく**もう1回送って**容器の中へ入れる。1周目は撮り直しだけ
                    // (木の遅れなら送らずに直る)、2周目以降だけ送る = 正常系のコストを増やさない
                    // **指の向きを持たないステップでも救済に入る**: 素の `tap` は direction を
                    // 持たないが、ghost は容器の外に居ることが分かっているので、戻す向きは
                    // `recoveryJump` / `recoveryDirection` が幾何から決められる(既定の finger は
                    // 「内側に居るとき」しか使われない)
                    if attempt > 0, grabbedGhost(resolved),
                       let element = resolved?.0 {
                        let finger = FTSwipeDirection(rawValue: step.direction ?? "") ?? .up
                        let container = ContainerGeometry.clippingContainer(
                            of: element, in: snapshot.elements,
                            inferring: step.containerInference ?? true)
                        // **距離を測ってその分だけ動かす**(recoveryJump 参照)。全画面スワイプだと
                        // 100pt のずれに対して1ページ動いてしまい、**行き過ぎて往復する**。
                        // 容器が分かるときだけ使える手なので、駄目なら全画面スワイプへ落ちる
                        if let container,
                           let jump = Self.recoveryJump(for: element, container: container),
                           await hintDrag(jump: jump, container: container,
                                          viewport: snapshot.screen, phase: &phase) {
                            ghostSwipes += 1
                            _ = try await settledSignature(phase: &phase)
                            start = clock.now
                            snapshot = try await freshSnapshot(.repoll(afterSearchSwiped: searchSwiped))
                            phase.snapshotMs += Self.ms(clock.now - start)
                            try await dismissInterruption(in: &snapshot, phase: &phase)  // 再試行の読みと同じ
                            let previous = resolved
                            resolved = LocatorResolver.resolve(step: step, in: snapshot)
                            if previous != nil { ghostRetries += 1 }
                            if resolved != nil, !grabbedGhost(resolved) { break }
                            continue
                        }
                        // **行き過ぎた側なら逆へ送る**(recoveryDirection 参照)。同じ向きに
                        // 送り続けると遠ざかるだけで、実測でも2回撃って外のままだった
                        var recovery = step
                        recovery.direction = (container
                            .map { Self.recoveryDirection(for: element, container: $0,
                                                          searching: finger) } ?? finger).rawValue
                        _ = try await swipeWithFallback(
                            FTSwipeDirection(rawValue: recovery.direction ?? "") ?? finger,
                            intent: .search,
                            // **座標も逆向きで作り直す**(path は向きを内包している)
                            path: scrollPath(step: recovery, intent: .search, in: snapshot),
                            phase: &phase)
                        ghostSwipes += 1
                        _ = try await settledSignature(phase: &phase)
                    }
                    start = clock.now
                    snapshot = try await freshSnapshot(.repoll(afterSearchSwiped: searchSwiped))
                    phase.snapshotMs += Self.ms(clock.now - start)
                    try await dismissInterruption(in: &snapshot, phase: &phase)  // 上の timeout 付きの再試行と同じ
                    let previous = resolved
                    resolved = LocatorResolver.resolve(step: step, in: snapshot)
                    if previous != nil { ghostRetries += 1 }
                    if resolved != nil, !grabbedGhost(resolved) { break }
                }
            }
        }

        // driver フォールバック(ハイブリッド): primary(in-app)で解決できない、または primary が
        // label 部分一致(substring)でしか解決できていないとき、fallbackDriver(XCUITest=システム UI)
        // の snapshot でも解決を試す。act は解決した driver で行う。
        // substring 誤解決の誤検知(in-app の label がシステム UI label の部分文字列で contains 命中し、
        // 本来当てたいシステム UI 要素へフォールバックされない)を、fallback の exact 一致で上書きする。
        // primary が exact のときは fallback を照会しない(コスト増なし)。
        // **select は照会しない**: 掴むだけでデバイス操作が無く、掴めないことが答えになり得る
        // コマンドなので、システム UI 側を探す意味がない。実害もある — fb.snapshot() は
        // springboard セッションを張り、**同一デバイス1セッション制約でアプリ attach を潰す**。
        // WebView(domInterop)では直後の type が入らなくなった(実測。
        // `select("wv_result=*")` はワイルドカードが quality=substring になり毎回ここを踏む)
        // 掴み直しの結果を**必ず注記に残す**: 救えたなら「なぜ遅かったか」の説明になり、
        // 救えなかったなら「タップが飲まれた可能性」を失敗調査の起点にできる(黙るのが最悪)
        // **救済で送った直後は、容器が次の1タッチを吸う**(探索終端と同じ既知の形。
        // docs/verification.md「スクロールした直後のタップ」)。探索終端では空打ちドラッグで
        // 肩代わりしているが、**救済経路には無かった** —— 実測(8並列 40 サンプル):
        // 救済が走った 18 件のうち **4 件が失敗**、走らなかった 22 件は **0 件**(p≈0.03)。
        // しかも失敗時の対象は容器のど真ん中(y=519〜534 / 容器 230..692)で座標は正しい。
        // 探索終端と**同じ順序**で肩代わり → 静止 → 掴み直しを行う
        if ghostSwipes > 0, let target = resolved?.0, shouldEmptyDrag(for: target) {
            let x = target.frame.centerX
            let y = min(target.frame.centerY,
                        snapshot.screen.y + snapshot.screen.height - Self.bottomUncoveredBand - 1)
            if Self.emptyDragIsSafe(x: x, y: y, of: target, in: snapshot.elements,
                                    screen: snapshot.screen),
               let end = Self.emptyDragEnd(of: target, x: x, y: y, searching: step.direction,
                                           screen: snapshot.screen) {
                await emptyDrag(x: x, y: y, toX: end.x, toY: end.y)
                let settled = try await settledSignature(phase: &phase)
                snapshot = settled.snapshot
                // 空打ちで木が入れ替わるので ref を取り直す(古い ref は別要素を指す)。
                // **取り直せないなら撃たずに失敗させる**: 空打ちが画面を変えた(下の行・ボタンが
                // 発火した)形で、古い ref のまま撃つと新しい木の別の要素を押して ok になる
                // (物理 iPhone 13: 空打ちで診断画面へ遷移 → 古い ref が #tab_home を押して
                // ホームへ戻り ok)。救済(キャッシュ・指紋・FM)にも回さない —— 変わった画面で
                // 別の要素へ「修復」するのも同じ誤った緑。撃ち直しもしない(吸われた操作と同じ規律)
                guard let refreshed = LocatorResolver.resolve(step: step, in: snapshot) else {
                    return StepOutcome(status: failed(.notFound,
                        "the element was found, but the relief drag after \(ghostSwipes) extra swipe(s)"
                        + " changed the screen and it is gone from the tree (the drag may have fired a"
                        + " row or button under it). Nothing was tapped: the earlier reference would now"
                        + " point at another element"))
                }
                resolved = refreshed
            }
        }

        var straddleNote: String?
        var ghostNote: String?
        if grabbedGhost(resolved) {
            noteCodesThisStep.insert(.actedOutsideContainer)
            ghostNote = "the element is still reported outside its scroll container"
                + " (\(ghostRetries) re-resolve(s), \(ghostSwipes) extra swipe(s));"
                + " the interaction may be swallowed"
        } else if ghostRetries > 0 {
            ghostNote = "re-resolved \(ghostRetries) time(s)"
                + (ghostSwipes > 0 ? " with \(ghostSwipes) extra swipe(s)" : "")
                + " — the element was first reported outside its scroll container"
        }

        // **解決できないのは上限で間引かれたからかもしれない**。否定アサーションと
        // 同じ retake を操作側にも入れる —— こちらは誤った成功ではなく**実在する要素での赤**
        // (flake)になる形だが、直す手段は同じ。
        // **ドライバ切替と指紋照合より前**に置く: 切り詰められた木で指紋を照合すると、実在する本命が
        // 候補に無いまま同じ型+ラベルの別要素が「ちょうど1件」になり、修正提案が利用者の .swift へ書き戻される。
        // **`select` も対象にする**(下のドライバ切替は select を除外するが、あちらの理由は
        // fallbackDriver が springboard セッションを張ってアプリ attach を潰すことで、
        // ここには当てはまらない)。`ifCanSelect` が切り詰められた木で「無い」側の枝を選ぶのは
        // notExist の誤った成功と同じ形なので、掴めないことが答えになり得るコマンドこそ要る
        //
        // **ラッチが既に立っているならここは撮らない**: 上のリトライループ入口で先に撮り直して
        // いれば、以後の周回は freshSnapshot がラッチ経由で天井のまま読んでいるので、ここで
        // もう1枚撮っても同じ木が返るだけの無駄になる
        if resolved == nil, snapshot.truncatedCount > 0, !elementLimitCeilingLatchedThisStep {
            // **ラッチを立てる**: one-shot の arm はこの1枚にしか効かないので、このステップの
            // 後続読み(freshSnapshot 経由・下の readback ヘルパの直呼び)も天井で撮らせる
            // (elementLimitCeilingLatchedThisStep の doc)。立てないと縁またぎの撮り直し(下の
            // straddle 補正)や type/clearInput の読み返しが既定上限へ戻り、この撮り直しで
            // 拾えた対象がまた落ちる
            elementLimitCeilingLatchedThisStep = true
            snapshot = try await retakenAtElementLimitCeiling(snapshot, phase: &phase)
            resolved = LocatorResolver.resolve(step: step, in: snapshot)
        }

        var actingDriver: AppDriver = driver
        var switchedToFallbackDriver = false
        if action != "select", let fb = fallbackDriver {
            let primaryQuality = resolved == nil ? nil : LocatorResolver.resolveDetailed(step: step, in: snapshot)?.quality
            if resolved == nil || primaryQuality == .substring {
                start = clock.now
                var fsnap = try await fb.snapshot()
                phase.snapshotMs += Self.ms(clock.now - start)
                // **どちらでも解決できないときだけ**システム許可アラートを閉じる(閉じたら
                // 木を取り直して1回やり直す)。解決できているならシナリオ自身がそのアラートを
                // 操作しようとしているので奪わない(dismissSystemAlert の宣言)
                if resolved == nil, LocatorResolver.resolveDetailed(step: step, in: fsnap) == nil,
                   await dismissSystemAlert(in: fsnap, via: fb) != nil {
                    start = clock.now
                    fsnap = (try? await fb.snapshot()) ?? fsnap
                    phase.snapshotMs += Self.ms(clock.now - start)
                    snapshot = (try? await driver.snapshot()) ?? snapshot
                    resolved = LocatorResolver.resolve(step: step, in: snapshot)
                }
                if let r = LocatorResolver.resolveDetailed(step: step, in: fsnap),
                   resolved == nil || r.quality == .exact {
                    resolved = (r.element, r.usedFallback)
                    snapshot = fsnap
                    actingDriver = fb
                    switchedToFallbackDriver = true
                }
            }
        }

        var status: StepResult.Status = .passed
        var healedStep: FlowStep?
        var healedByFingerprint = false
        // ロケータのフォールバック(.passedViaFallback)とは別物。ドライバ切替の注記のみで、
        // FTRuntime の修正提案(セレクタ更新)は誘発しない
        var driverFallback: String?
        var element: ElementInfo

        if let (found, usedFallback) = resolved {
            element = found
            if let fallback = usedFallback { status = .passedViaFallback(fallback) }
        } else if action == "select" {
            // **select だけは掴めなくても失敗させない**(空要素を返して呼び出し側に .isEmpty で
            // 分岐させる契約)。自己修復の対象にもしない — 掴めないことが答えになり得るコマンドで
            // 別要素へ誤リダイレクトすると、空のはずが値を持って返る
            return StepOutcome(status: .skipped(Self.selectNotFoundReason))
        } else if let fingerprint,
                  let found = fingerprint.resolve(in: snapshot.elements.filter {
                      !ContainerGeometry.hasClampedCoordinates($0, in: snapshot.elements,
                                                  inferring: step.containerInference ?? true)
                  }) {
            // ロケータ指紋: 前回このロケータが解決できた要素の type+label が現在の木に
            // **ちょうど1件**だけ一致したので、決定的に解決する。0件・複数件のときは
            // `resolve(in:)` が nil を返し、下の「見つからない」へそのまま落ちる(採否は二値のみ)
            element = found
            var notes: [String] = []
            note(.healFingerprintMatch, into: &notes)
            if let graded = SelectorNaming(snapshot).graded(for: found, in: snapshot) {
                // 書けるセレクタは修正提案(FTRuntime.perform)に乗せる。**書けるセレクタは
                // `SelectorNaming` にだけ決めさせる**(一意性を見ずに id/label を採ると、同じ id を
                // 複数持つ画面で書いたセレクタが別要素に解決する)。indexed(位置依存)は
                // `Durability.caution` で必ず言う
                let parsed = FTSelector.parse(graded.selector)
                var healed = step
                healed.locator = parsed.primary
                healed.fallbacks = parsed.fallbacks.isEmpty ? nil : parsed.fallbacks
                healed.note = (step.note.map { $0 + " / " } ?? "")
                    + "self-healed: matched by locator fingerprint (type=\(found.type),"
                    + " label=\(found.label ?? "nil"))" + graded.durability.caution
                healedStep = healed
                healedByFingerprint = true
                status = .healed(parsed.primary)
            } else {
                // **操作は続けるが healedStep は立てない**(healUnwritable と同じ規律)。
                // 掴んだ要素は手元にあるので叩くこと自体は正しく、書き戻せないという理由だけで
                // 緑の run を赤にしない
                note(.healUnwritable, into: &notes)
            }
            driverFallback = Self.joinNotes(driverFallback, notes.joined(separator: " / "))
        } else if let reached = try await resolveAfterClosingKeyboard(action, step: step, in: snapshot, phase: &phase) {
            element = reached.element
            snapshot = reached.snapshot
            if let fallback = reached.usedFallback { status = .passedViaFallback(fallback) }
            driverFallback = Self.joinNotes(driverFallback, reached.note)
        } else {
            // 惜しい候補を添える。これが無いと直すために snapshot を取り直す往復が必要になる
            // (レポート側の全要素一覧は ScenarioReportWriter が別途出す)
            let hint = LocatorResolver.candidateHint(for: step, in: snapshot)
            return StepOutcome(status: failed(
                .notFound,
                "cannot resolve the locator: \(step.locatorSummary)" + (hint.map { ". \($0)" } ?? "")
                    + Self.defaultWaitHint(step)
                    + Self.truncationHint(snapshot)
                    + Self.keyboardResizedHint(snapshot)
                    + Self.webViewPathHint(snapshot)))
        }
        resolvedElementThisStep = element
        // セレクタが2件以上に一致していたら数を控える(1件目を撃った。ft_batch が行に添える)。
        // 序数・相対の指定は利用者が1つを選んでいるので数えない(candidates はそれらを見ない)
        if let locator = step.locator, locator.index == nil, locator.relative?.isEmpty ?? true,
           let count = LocatorResolver.candidates(locator, elements: snapshot.elements)?.count, count > 1 {
            ambiguousMatchCountThisStep = count
        }

        // **容器の縁にまたがった要素はそのまま撃たない**。見えている部分を撃っても、
        // Compose は focus 時に bringIntoView で内容を動かすため、離すまでに隣の行が指の下へ来る
        // (Emulator で約 50%・実測 135〜179px ずれて隣の行が反応した)。**容器の中へ寄せてから撃つ**。
        //
        // 撤回した「またぎも掴み直しの対象へ広げる」との違いは**送り方**:
        // あちらは全画面スワイプで行き過ぎて自傷した(S0110 が 2/10 → 5/10)。ここは
        // `straddleJump`(またぎ解消に必要な最小量。40% 位置への寄せは観測対象まで流す —
        // 定義部の実害参照)+ `slowDrag`(フリングを出さない)なので
        // 行き過ぎない。**1回だけ**(収束しなければ見えている部分を撃つ)
        // **fallback へ切り替えたステップでは寄せない**: 寄せは primary(`driver`)の木を撮り直して
        // ref を引くので、fallback の木から解決した要素に primary の名前空間を混ぜる
        if !switchedToFallbackDriver, Self.interactsByTouch(action), step.containerInference ?? true,
           let (container, jump) = TapTargetGeometry.straddlingContainerEdge(element, in: snapshot.elements),
           await slowDrag(jump: jump, container: container, phase: &phase) {
            _ = try await settledSignature(phase: &phase)
            let refreshed = try await freshSnapshot(.afterOwnMove)
            if let (moved, _) = LocatorResolver.resolve(step: step, in: refreshed) {
                snapshot = refreshed
                element = moved
                resolvedElementThisStep = element
                straddleNote = "nudged the element fully inside its container before touching it"
            }
        }

        // **無効な対象は操作可能になるまで待ってから撃つ**(ユーザー決定)。
        // 画面が出た直後は、要素は木に居るのに**まだ触れない**ことがある(受け手の実アプリ:
        // ログインフォームが読み込み中は入力欄が無効で、id を持たない透明な clickable が
        // 覆っていた)。撃つと空振りしたことは**後段のアサーションが落ちて初めて分かる**
        // = 原因から遠いので、待ってから撃つ。
        // **待ち切れなくても撃つ** —— 無効な要素をわざと叩いて「反応しない」ことを確かめる
        // 書き方は正当なので、失敗にはしない(注記は出る)
        var enabledWaitNote: String?
        // fallback へ切り替えたステップでは待たない(待ちは primary の木を読み直す = ref の名前空間が混ざる)
        if action == "tap", !switchedToFallbackDriver, !element.enabled,
           let waited = try await waitUntilEnabled(step: step, phase: &phase) {
            snapshot = waited.snapshot
            element = waited.element
            resolvedElementThisStep = element
            noteCodesThisStep.insert(.waitedForEnabled)
            enabledWaitNote = "waited \(waited.waitedMs)ms for the target to become enabled"
        }

        switch action {
        case "select":
            // 掴むだけでデバイス操作はしない。ただし**可視性は exist と同じ規律で確かめる**
            // (覆われた要素を掴んで値を読むと、画面に見えていない値でテストが通る)。
            // `requireVisible: false` で外せる(step.occlusionGuard が false のとき素通り)
            if try await occlusionFlip(
                element: element, expectedText: element.label ?? step.locator?.label ?? "",
                elements: snapshot.elements, screen: snapshot.screen,
                keyboardShown: KeyboardWait.isShown(snapshot),
                looseMatch: false, perStepGuard: step.occlusionGuard,
                expectedIsUserText: step.locator?.label != nil, phase: &phase) != nil {
                // **見えないときは失敗させず空要素を返す**(呼び出し側が `.text == nil` で分岐できる)。
                // exist(検証)と違い select は「掴む」操作なので、見えない事実は値で表す
                resolvedElementThisStep = nil
                notVisibleSelectionThisStep = element
                return StepOutcome(status: .passed,
                                   driverFallback: "not visible: returned an empty element")
            }
        case "tap":
            // 飲まれたタップの証跡(LastInteraction 参照)。**操作の前**に採る = 比較の基準は
            // 「この操作を撃つ直前の画面」でなければ意味がない
            recordInteraction(step: step, element: element, in: snapshot)
            lastTapTarget = element
            driverFallback = Self.joinNotes(driverFallback, enabledWaitNote)
            // **注記が出るときは解決先を1回だけ名乗る**(受け手報告)。
            // 連鎖(`A||B`)や型+順序(`.textField[1]`)では**書いた文字列から解決先が読めない**ので、
            // 「無効だ」「覆われている」と言われても**どの要素の話か分からない**
            // (Material の TextInputLayout/TextInputEditText のように、同じ矩形に容器と
            // 入力欄が重なる画面で実際に詰まった)。型も出す = 容器と中身を見分ける鍵はそこ。
            // **注記が1つも無いステップには付けない** = 通常の出力量は変わらない
            var namedTarget = false
            func adviseTarget(_ advisory: String?) {
                guard let advisory else { return }
                if !namedTarget {
                    namedTarget = true
                    driverFallback = Self.joinNotes(driverFallback,
                        "resolved to \(TapTargetGeometry.describe(element)) (\(element.type))")
                }
                driverFallback = Self.joinNotes(driverFallback, advisory)
            }
            // **撃つ前に言えることは言う**(判定は MCP と共有。TapTargetGeometry.advisory)。
            // 失敗にはしない —— 無効な要素をわざと叩いて反応しないことを確かめる書き方は正当で、
            // `enabledIsFalse` も用意されている。**注記に混ぜて、後段の失敗から原因へ辿れるようにする**
            // (これが無いと「押したのに何も起きない」が後段のアサーションでだけ落ち、原因から遠い)
            // **「そもそも無効」は撃つ座標に依らない**ので、この時点で載せてよい。
            // 中身外しのほうは**frame の中心を撃つと決まってから**(下の visibleTapRect で
            // 見えている部分へ寄せることがあり、寄せたなら「背後へ抜けた」は嘘になる)
            // **キーボード下は木の遮蔽判定が原理的に拾えない**(inputView は子孫が全部除外された
            // 空葉になり、既存の空葉コンテナ除外で候補から外れる)ので、ブリッジ申告の
            // keyboardFrame でだけ判定する。**disabled より先**(座標に依らず言えるのは同じだが、
            // 実害はキーボード誤タップのほうが具体的で誤操作に直結する)。
            // **offscreen/missedContent はここに混ぜない**: 撃つ座標(visibleTapRect で寄せるか
            // frame の中心か)が決まってからでないと嘘になる(下記2箇所参照)。混ぜると
            // keyboard/disabled が2回付く(発覚したバグ)ので、この2つだけをここで確定する。
            // **申告 keyboardFrame はキー面だけ**なので木の chrome で広げ、chrome 自身とその
            // 部分木(地球儀キー等)は除外して渡す(KeyboardOcclusion の doc。MCP 側も同じ型で揃える)
            let tapKeyboardOcclusion = KeyboardOcclusion.resolve(reported: snapshot.keyboardFrame, in: snapshot.elements, screen: snapshot.screen)
            // 押すだけの tap はキーボードの下なら閉じてから届かせる(下の reachPastKeyboard)ので、覆われたまま撃つのは長押しだけ
            if (step.duration ?? FlowStep.defaultTapHoldSeconds) > 0 {
                adviseTarget(tapKeyboardOcclusion.advisory(for: element))
            }
            // **木に出ないオーバーレイ・ウィンドウ**も同じ理由でここでしか言えない
            // (覆っている実体が elements に1要素も載らない。OverlayWindowOcclusion の doc)。
            // keyboard と同じく座標に依らないので、この時点で載せてよい
            adviseTarget(OverlayWindowOcclusion.resolve(
                reported: snapshot.overlayWindowFrames).advisory(for: element))
            adviseTarget(TapTargetGeometry.disabledAdvisory(for: element))
            adviseTarget(duplicateRegionAdvisory(element, in: snapshot))
            // 文中リンク: 要素の中の文字列の位置を座標で撃つ(中心へ黙って落とさない)
            if let linkText = step.linkText {
                return try await executeTapLinkText(linkText, element: element, snapshot: snapshot,
                                                    step: step, notes: driverFallback, phase: &phase)
            }
            // **長押しは tap の引数**(Shirates 準拠。`tap(sel, holdSeconds:)`)。0 より大きいときだけ
            // ブリッジの /press へ回す。in-app は座標ジェスチャを持たない(501)ので XCUITest へ
            // フォールバックする経路も長押し側だけが必要
            let hold = step.duration ?? FlowStep.defaultTapHoldSeconds
            if hold > 0 {
                // 長押しは press(ref:) = ブリッジが frame の中心へ解決するので、座標に依る
                // チェーン(画面外・遮蔽・中身外し等)が言える。**keyboard/disabled はここでは
                // 足さない**(上ですでに1回付けている。ここで足すと同文が2回付く)
                adviseTarget(TapTargetGeometry.occlusionAdvisory(
                    for: element, in: snapshot.elements, screen: snapshot.screen, isAndroid: isAndroid))
                if typeDriverGestures.contains("press") || pressFallbackLatched, let td = typeDriver,
                   try await pressViaTypeDriver(td, step: step, phase: &phase) {
                    return StepOutcome(status: .passed, healedStep: healedStep,
                                       healedByFingerprint: healedByFingerprint,
                                       driverFallback: Self.joinNotes(driverFallback,
                                                                      "fell back to XCUITest"))
                }
                do {
                    start = clock.now
                    if let bandY = await bottomBandTapY(for: element.frame, screen: snapshot.screen) {
                        try await actingDriver.press(x: element.frame.centerX, y: bandY, duration: hold)
                        driverFallback = Self.joinNotes(driverFallback, Self.bottomBandTapNote)
                    } else {
                        try await actingDriver.press(ref: element.ref, duration: hold)
                    }
                    phase.actionMs += Self.ms(clock.now - start)
                } catch {
                    // 「このブリッジでは不可」(501 / ルート不明 404)だけ XCUITest へ回す。
                    // 409 を含めない理由は DriverError.isBridgeIncapable 参照
                    guard DriverError.isBridgeIncapable(error), let td = typeDriver else { throw error }
                    guard try await pressViaTypeDriver(td, step: step, phase: &phase) else { throw error }
                    pressFallbackLatched = true
                    driverFallback = Self.joinNotes(driverFallback, "fell back to XCUITest")
                }
                break
            }
            // **縁の帯に潜っているだけなら、撃つ前に1回だけ送って外す**。
            // 判定と手順は liftCoveredTarget の1箇所。type も同じものを通る
            if let lifted = try await liftCoveredTarget(
                element, in: snapshot, step: step, verb: "touching",
                snapshotSource: switchedToFallbackDriver ? .driver(actingDriver) : .primary, phase: &phase) {
                guard let liftedElement = lifted.element else {
                    return StepOutcome(status: failed(.notFound, Self.coverLiftLostMessage(step, verb: "touching")))
                }
                element = liftedElement
                snapshot = lifted.snapshot
                // **飲まれたタップの基準を撮り直す**: 送った後の画面が「撃つ直前」なので、
                // 古い基準のままだと自分のスクロールを「画面が変わった」と数えてしまう
                recordInteraction(step: step, element: liftedElement, in: lifted.snapshot)
                lastTapTarget = liftedElement
                driverFallback = Self.joinNotes(driverFallback, lifted.note)
            }
            switch try await reachPastKeyboard(
                element, in: snapshot, step: step, action: "tap",
                snapshotSource: switchedToFallbackDriver ? .driver(actingDriver) : .primary, phase: &phase) {
            case nil: break
            case .refused(let message)?: return StepOutcome(status: .failed(message))
            case .reached(let reached, let after, let note)?:
                element = reached
                snapshot = after
                recordInteraction(step: step, element: reached, in: after)
                lastTapTarget = reached
                driverFallback = Self.joinNotes(driverFallback, note)
            }
            // **出てきたばかりのダイアログ・シートの中を、本物の指と同じ経路で押す前だけ待つ**(切り替えの最中の tap は
            // UIKit に捨てられる。判定と根拠は PresentedOverlayTapWait)。打ち直さない・画素を撮らない
            if PresentedOverlayTapWait.shouldWait(framework: uiFramework, tapsWithSystemTouch: actingDriver.tapsWithSystemTouch,
                                                  target: element, previousTapTree: previousTapTree, current: snapshot) {
                try await Task.sleep(nanoseconds: UInt64(PresentedOverlayTapWait.transitionSeconds * 1_000_000_000))
                noteCodesThisStep.insert(.waitedForPresentedOverlay)
                driverFallback = Self.joinNotes(driverFallback, StepNote.waitedForPresentedOverlay.text)
                // **待った後の位置で撃つ**(切り替えの途中に読んだ木 = せり上がる slide のシートなら動く前の枠)。
                // 撮り直しは primary の木なので、fallback へ切り替えたステップでは引き直さない(寄せと同じ規律)。
                // 引けなければ待つ前の要素のまま撃つ
                if !switchedToFallbackDriver {
                    let refreshed = try await freshSnapshot(.afterOwnMove)
                    if let (moved, _) = LocatorResolver.resolve(step: step, in: refreshed) {
                        snapshot = refreshed
                        element = moved
                        resolvedElementThisStep = element
                        // 飲まれたタップの基準も撃つ直前の木にする(寄せた後と同じ)
                        recordInteraction(step: step, element: moved, in: refreshed)
                        lastTapTarget = moved
                    }
                }
            }
            start = clock.now
            // **中心が容器の外に落ちる要素だけ、見えている部分の中心を座標で撃つ**
            // (visibleTapRect 参照)。ref で撃つとブリッジが frame の中心へ解決するので、
            // 壊れた frame ではそのまま容器の外を叩いて黙って飲まれる
            if let visible = Self.visibleTapRect(for: element, in: snapshot.elements,
                                                inferring: step.containerInference ?? true,
                                                scale: driver.pointScale) {
                let bandY = await bottomBandTapY(for: visible, screen: snapshot.screen)
                try await actingDriver.tap(x: visible.centerX, y: bandY ?? visible.centerY)
                driverFallback = Self.joinNotes(driverFallback,
                    "tapped the visible part (the reported frame's centre falls outside its container)")
                if bandY != nil { driverFallback = Self.joinNotes(driverFallback, Self.bottomBandTapNote) }
            } else if let bandY = await bottomBandTapY(for: element.frame, screen: snapshot.screen) {
                // ref で撃つと Android は frame の中心(帯の中)を押すので座標で撃つ
                adviseTarget(TapTargetGeometry.occlusionAdvisory(
                    for: element, in: snapshot.elements, screen: snapshot.screen, isAndroid: isAndroid))
                try await actingDriver.tap(x: element.frame.centerX, y: bandY)
                driverFallback = Self.joinNotes(driverFallback, Self.bottomBandTapNote)
            } else {
                // 寄せずに frame の中心を撃つ = 座標に依るチェーンが言える経路。
                // **keyboard/disabled はここでは足さない**(上ですでに1回付けている。
                // ここで足すと同文が2回付く)
                adviseTarget(TapTargetGeometry.occlusionAdvisory(
                    for: element, in: snapshot.elements, screen: snapshot.screen, isAndroid: isAndroid))
                do {
                    try await actingDriver.tap(ref: element.ref)
                    // 読むのは ref で撃った直後だけ(座標の経路は tap(ref:) を通らない = 前回の値が残る)
                    if let miss = actingDriver.lastTapHitAreaMiss {
                        let centre = "(\(Int(miss.x.rounded())), \(Int(miss.y.rounded())))"
                        switch miss.kind {
                        case .receivedBy(let receiver):
                            noteCodesThisStep.insert(.inAppTapOutsideHitArea)
                            driverFallback = Self.joinNotes(driverFallback, StepNote.inAppTapOutsideHitArea.text
                                + " (\(receiver) at \(centre))")
                        case .activationPoint(let x, let y):
                            noteCodesThisStep.insert(.inAppActivationPointOffCentre)
                            driverFallback = Self.joinNotes(driverFallback, StepNote.inAppActivationPointOffCentre.text
                                + " (activation point (\(Int(x.rounded())), \(Int(y.rounded()))), centre \(centre))")
                        case .movedBeforeFire:
                            noteCodesThisStep.insert(.staleRefAtTap)
                            driverFallback = Self.joinNotes(driverFallback, StepNote.staleRefAtTap.text + " (at \(centre))")
                        }
                    }
                } catch {
                    // in-app が「activate 不発・合成タッチは効かない」(SwiftUI)で 501 を返したら、
                    // 今の木の枠の中心を XCUITest の座標タップで押す(ref は別名前空間なので渡さない)。
                    // 撃ち直しではない: 501 は in-app が何も撃たずに返した場合だけ
                    guard DriverError.isBridgeIncapable(error),
                          let td = typeDriver else { throw error }
                    // 長押しと同じく XCUITest の木で引き直して ref で押す(木を撮る段でランナーのセッションが
                    // 今のアプリへ向く。座標を直に撃つと、直前のプロファイルのアプリに向いたままのランナーが
                    // 「対象アプリが動いていない」(503)で断った = E2E-iOS で実測)。引き直せなければ座標
                    if try await !tapViaTypeDriver(td, step: step, phase: &phase) {
                        try await td.tap(x: element.frame.centerX, y: element.frame.centerY)
                    }
                    driverFallback = Self.joinNotes(driverFallback, "fell back to XCUITest")
                }
            }
            phase.actionMs += Self.ms(clock.now - start)
            // ドライバが「無言 no-op になり得る経路を通った」と申告した注記(例: InAppBridge の
            // activate 不発→合成タッチ)。失敗ではないので driverFallback に載せて可視化するだけ。
            // **代入ではなく合流**: 上書きすると、直前に積んだ注記(無効な要素・中身外し)が
            // 消える —— しかも消えるのは activate 不発のような**まさに飲まれた場面**で、
            // 両方が要るときに片方を失っていた(レビューで発覚)
            driverFallback = Self.joinNotes(driverFallback, actingDriver.lastActionNote)
        case "waitForSettle":
            // 範囲 = 解決した要素の frame(解決できなかった失敗は上で確定済み)。待つだけで何も送らない
            let waited = try await executeWaitForSettle(step: step, region: element.frame,
                                                        startedAt: actionStart, phase: &phase)
            driverFallback = Self.joinNotes(driverFallback, waited.note)
            guard case .passed = waited.status else {
                return StepOutcome(status: waited.status, driverFallback: driverFallback)
            }
        case "holdStart":
            // 二重 hold は禁止: ブリッジは指を1本下ろすだけで、前の hold がまだ下がっている間は
            // 離し時刻を上書きすると先に下ろした指がいつ離れるか分からなくなる
            if let liftsAt = holdLiftsAt, liftsAt > clock.now {
                return StepOutcome(status: .failed(
                    "hold cannot be nested — a previous hold has not been released yet"
                        + " (let its block finish before starting another hold)"))
            }
            let held = try await executeHoldStart(element: element, snapshot: snapshot,
                                                  step: step, phase: &phase)
            if let refusal = held.refusal { return StepOutcome(status: failed(.notFound, refusal)) }
            element = held.element
            snapshot = held.snapshot
            resolvedElementThisStep = element
            driverFallback = Self.joinNotes(driverFallback, held.driverFallback)
        case "type":
            // "\n" を含む入力だけ typeDriver(XCUITest)を優先する: typeText は改行を Return
            // キー押下として発火し iOS 既定の挙動と揃うが、in-app の insertText は改行の解釈が
            // フレームワーク任せで揃わない。"\n" を含まない入力は両経路で結果が同じなので、この
            // 振り分けはモード間の観測可能な挙動差を生まない。
            let text = step.text ?? ""
            // **確実に入力欄でないものへは、撃つ前に断る**(nonTextInputPreflightRefusal の doc)。
            // replace のクリアもタップを伴うので、それより前に置く
            if let refusal = nonTextInputPreflightRefusal(element, in: snapshot.elements, action: "type") {
                return StepOutcome(status: .failed(refusal))
            }
            // **replace は3経路(typeDriver優先/通常/409フォールバック)より前に1回だけクリアする**。
            // 空にできていないのに書き足すと検証対象と違う値になるので、clear が失敗したら
            // type を撃たずこのステップを失敗させる
            var replaceFallbackNote: String?
            // 撃つ前の値(注記用)。replace は消去の後に要素を引き直すので、その前に控える
            let priorValue = TypeReadback.normalizedValue(of: element)
            if step.replace == true {
                switch try await performClearInput(element: element, step: step,
                                                   actingDriver: actingDriver, in: snapshot.elements,
                                                   phase: &phase) {
                case .cleared(let fallback, let actingSnapshot):
                    replaceFallbackNote = fallback
                    // **消去の後は撮り直した木で引き直してから撃つ**(ClearOutcome の doc)。最後の撮影が別のドライバなら
                    // actingDriver で撮る。引けなければ撃たない(撃つ前の ref で打つと別の欄へ入って成功を報告した)
                    let current: SnapshotResponse
                    if let actingSnapshot {
                        current = actingSnapshot
                    } else {
                        // one-shot なので撮る前に arm し直す(elementLimitCeilingLatchedThisStep の doc)
                        if elementLimitCeilingLatchedThisStep {
                            actingDriver.raiseElementLimitOnNextSnapshot(BridgeAPI.maxSnapshotElementsCeiling)
                        }
                        let snapStart = clock.now
                        current = try await actingDriver.snapshot()
                        phase.snapshotMs += Self.ms(clock.now - snapStart)
                    }
                    guard let refound = Self.relocateAfterClear(element, step: step, in: current) else {
                        return StepOutcome(status: failed(.notFound, Self.clearLostTargetMessage(step)))
                    }
                    element = refound
                    snapshot = current
                case .failed(let message):
                    return StepOutcome(status: .failed(message))
                }
            }
            // **既存値の連結警告**(MCP の同名警告と揃える)。追加のデバイス往復はしない —
            // 撃つ前に解決済みの `element.value` だけを見る。secureTextField は値を伏せる
            // (マスク欄の実値をログへ出さない)。**replace は clear 済みなので空として扱う**
            let existingValue = step.replace == true ? "" : priorValue
            let existingValueNote: String? = step.replace == true
                ? (priorValue.isEmpty ? nil : "replaced the field's prior content")
                : (priorValue.isEmpty ? nil
                    : element.type == "secureTextField"
                        ? "the field already holds a value; type appends, so the result will not"
                            + " simply be what you typed. Call clearInput first if you meant to replace it"
                        // **連結後の値を予告しない**(MCP 側の同名警告と同じ理由)——
                        // 空欄のヒント文字列が `value` に載り `placeholder` が来ないアプリ
                        // (Google メッセージの宛先欄が witness)では前の値が実在の内容ではなく、
                        // 予告は外れる。**ここでは読み返さない**(型ステップごとの往復を増やさない)
                        // ので、観測していない値は名乗らず「撃つ前に入っていた値」だけを言う
                        : "the field already held \"\(SnapshotRenderer.truncate(priorValue, 30))\";"
                            + " type appends, so the result will not simply be what you typed."
                            + " Call clearInput first if you meant to replace it")
            // **キーボードの下の欄へは打たない**。焦点を当てるタップがキーボードに
            // 当たるので焦点が移らず、**打鍵が直前に焦点のあった欄へ流れ込む**
            // (受け手の 4.7 インチ実機で実測: 市区町村の欄に住所が3回ぶん追記された。
            // 読み返しが 422 で止めるが、別の欄はすでに壊れている)。tap と同じ規則で
            // 容器を送り、外せたら送った後の木で解決し直す。**送っても中心がキーボードの下に残るなら閉じてから打つ**
            // (reachPastKeyboard の doc。送れない画面 = 内容が収まっているフォーム等)
            if let lifted = try await liftCoveredTarget(
                element, in: snapshot, step: step, verb: "typing",
                snapshotSource: switchedToFallbackDriver ? .driver(actingDriver) : .primary, phase: &phase) {
                guard let liftedElement = lifted.element else {
                    return StepOutcome(status: failed(.notFound, Self.coverLiftLostMessage(step, verb: "typing")))
                }
                element = liftedElement
                snapshot = lifted.snapshot
                driverFallback = Self.joinNotes(driverFallback, lifted.note)
            }
            switch try await reachPastKeyboard(
                element, in: snapshot, step: step, action: "type",
                snapshotSource: switchedToFallbackDriver ? .driver(actingDriver) : .primary, phase: &phase) {
            case nil: break
            case .refused(let message)?: return StepOutcome(status: .failed(message))
            case .reached(let reached, let after, let note)?:
                element = reached
                snapshot = after
                driverFallback = Self.joinNotes(driverFallback, note)
            }
            // **入力欄でないものへ打とうとしていないか**(TypeReadback の doc に実測)。
            // 検証は両側とも空になる経路なので、せめて内側の欄を名指しして知らせる
            let nonInputNote = TapTargetGeometry.nonInputTypeTargetNote(element, in: snapshot.elements)
            // **押し上げ検知の「打つ前」の基準**(keyboardFrameBeforeType の doc)。以下のどの経路
            // (typeDriver 優先/通常/409フォールバック)で打っても、成功したら等しく次のロケータ
            // 操作へ引き継ぐ —— モードで挙動を変えない(読み返しの有無に依存しない)
            let keyboardBefore = snapshot.keyboardFrame
            if let td = typeDriver, preferTypeDriver || text.contains("\n") {
                let routed = try await typeViaTypeDriver(td, step: step, phase: &phase)
                if routed.typed {
                    // settle:false は次のステップへ待ちを持ち越さない(印を立てない)
                    if !step.skipsSettle {
                        keyboardFrameBeforeType = keyboardBefore
                        pendingTypeKeyboardCheck = true
                        pendingTypeEndedWithNewline = text.hasSuffix("\n")
                    }
                    // ランナーの打ち直しの申告(OKResponse.note)はこの経路でも拾う(下の主経路と同じ)
                    return StepOutcome(status: .passed, healedStep: healedStep,
                                       healedByFingerprint: healedByFingerprint,
                                       driverFallback: Self.joinNotes(driverFallback, routed.note, td.lastActionNote,
                                                                      replaceFallbackNote, existingValueNote, nonInputNote))
                }
            }
            do {
                start = clock.now
                try await actingDriver.type(ref: element.ref, text: step.text ?? "")
                // ランナーの打ち直しの申告(TypeReadback.Plan.retype → OKResponse.note)。tap と同じく合流
                driverFallback = Self.joinNotes(driverFallback, actingDriver.lastActionNote)
                phase.actionMs += Self.ms(clock.now - start)
                driverFallback = Self.joinNotes(driverFallback, replaceFallbackNote, existingValueNote,
                                                nonInputNote)
                // in-app は「200 が返った = 入った」を保証しない(insertText の成否しか見ていない)。
                // xcuitest ランナー/Android 注入器は自前で読み返し済みなので二重にしない
                // (verifiesTypedText == true のドライバはここへ来ない)
                if !actingDriver.verifiesTypedText, TypeReadback.isTextInput(element) {
                    if let failure = try await verifyTypedText(actingDriver, element: element,
                                                                expected: existingValue + text,
                                                                typedOnly: text,
                                                                phase: &phase) {
                        return StepOutcome(status: .failed(failure))
                    }
                }
            } catch {
                // 409 = inapp が非 UIKit 入力欄で first responder を張れない兆候。type は要素個別の
                // フォーカス有無に依存する一時的競合なので、press/swipe と違い 501 化しない
                // (判定は DriverError.isTextInputFallback)。
                guard DriverError.isTextInputFallback(error), let td = typeDriver else { throw error }
                // **対象が確実に入力欄でないなら撃ち直さない**(TypeReadback.isPositivelyNonTextInput の
                // doc)。in-app の /type は撃つ前に合成タップを撃っており、ここで XCUITest が
                // もう一度タップすると対象(ボタン等)を2回押しかねない(送信・購入の二重実行)
                if TypeReadback.isPositivelyNonTextInput(element, selfRendered: uiFramework?.isSelfRendered) {
                    return StepOutcome(status: .failed(Self.nonTextInputFallbackRefusal(
                        element, in: snapshot.elements, action: "type")))
                }
                let routed = try await typeViaTypeDriver(td, step: step, phase: &phase)
                guard routed.typed else { throw error }
                // セレクタは正しくドライバが変わっただけ = .passedViaFallback(ロケータ用)は立てない
                // (typeDriver = xcuitest が自前で読み返し済みなので、ここでも読み返さない)
                driverFallback = Self.joinNotes("fell back to XCUITest", routed.note, td.lastActionNote,
                                                replaceFallbackNote, existingValueNote, nonInputNote)
            }
            // **打った(do 成功/409フォールバックのどちらでも)ので、次のロケータ操作の解決で
            // 打つ前後のキーボードを比べる**(keyboardFrameBeforeType の doc)
            if !step.skipsSettle {
                keyboardFrameBeforeType = keyboardBefore
                pendingTypeKeyboardCheck = true
                pendingTypeEndedWithNewline = text.hasSuffix("\n")
            }
        case "clearInput":
            if let refusal = nonTextInputPreflightRefusal(element, in: snapshot.elements, action: "clearInput") {
                return StepOutcome(status: .failed(refusal))
            }
            switch try await reachPastKeyboard(
                element, in: snapshot, step: step, action: "clearInput",
                snapshotSource: switchedToFallbackDriver ? .driver(actingDriver) : .primary, phase: &phase) {
            case nil: break
            case .refused(let message)?: return StepOutcome(status: .failed(message))
            case .reached(let reached, let after, let note)?:
                element = reached
                snapshot = after
                driverFallback = Self.joinNotes(driverFallback, note)
            }
            if let td = typeDriver, preferTypeDriver,
               try await clearViaTypeDriver(td, step: step, phase: &phase) {
                return StepOutcome(status: .passed, healedStep: healedStep,
                                   healedByFingerprint: healedByFingerprint, driverFallback: driverFallback)
            }
            switch try await performClearInput(element: element, step: step,
                                               actingDriver: actingDriver, in: snapshot.elements,
                                               phase: &phase) {
            case .cleared(let fallback, _):
                driverFallback = Self.joinNotes(driverFallback, fallback)
            case .failed(let message):
                return StepOutcome(status: .failed(message))
            }
        case "pinchOut", "pinchIn", "doubleTap", "swipeBy", "gesture":
            // 対象を指定した版。要素の frame(Android のピンチ中心・swipeBy の基準領域)と
            // identifier(XCUITest のピンチ対象)の両方を渡す(理由は BridgeDTO.PinchRequest)
            // **doubleTap も指で触る操作**なので、tap と同じ注記を載せる
            // (MCP の ft_double_tap も同じ内容を出す。片方だけ黙ると判断が食い違う)。
            // pinch / swipeBy は「要素を掴んで動かす」形で、無効でも意味があるので対象外
            let gestureAdvisory = action == "doubleTap"
                ? Self.joinNotes(
                    TapTargetGeometry.advisory(for: element, in: snapshot.elements,
                                               screen: snapshot.screen,
                                               keyboardOcclusion: KeyboardOcclusion.resolve(reported: snapshot.keyboardFrame,
                                                  in: snapshot.elements, screen: snapshot.screen),
                                               overlayWindows: OverlayWindowOcclusion.resolve(
                                                  reported: snapshot.overlayWindowFrames),
                                               isAndroid: isAndroid),
                    duplicateRegionAdvisory(element, in: snapshot))
                : nil
            let outcome = try await performGesture(action, step: step, target: element.frame,
                                                   identifier: element.identifier,
                                                   viewport: snapshot.screen, phase: &phase)
            guard case .passed = outcome.status else { return outcome }
            driverFallback = Self.joinNotes(driverFallback, gestureAdvisory,
                                            outcome.driverFallback)
        case "swipeElementToElement":
            guard let endLocator = step.endLocator else {
                return StepOutcome(status: .failed("swipeElementToElement requires an end locator"))
            }
            var endStep = step
            endStep.locator = endLocator
            endStep.fallbacks = nil
            var endResolved = LocatorResolver.resolve(step: endStep, in: snapshot)
            // **終点も上限で間引かれているなら撮り直す**(始点(上の truncatedCount
            // ブロック)だけ救済される非対称を埋める)。**始点も同じ撮り直した木から取り直す** ——
            // 片方だけ別の読みの座標のままだと frame の世代が混ざる
            if endResolved == nil, snapshot.truncatedCount > 0 {
                elementLimitCeilingLatchedThisStep = true
                snapshot = try await retakenAtElementLimitCeiling(snapshot, phase: &phase)
                endResolved = LocatorResolver.resolve(step: endStep, in: snapshot)
                if let (refreshedStart, _) = LocatorResolver.resolve(step: step, in: snapshot) {
                    element = refreshedStart
                    resolvedElementThisStep = element
                }
            }
            guard let (endElement, _) = endResolved else {
                let hint = LocatorResolver.candidateHint(for: endStep, in: snapshot)
                return StepOutcome(status: .failed(
                    "cannot resolve the end locator: \(endStep.locatorSummary)"
                        + (hint.map { ". \($0)" } ?? "")
                        + Self.truncationHint(snapshot)
                        + Self.keyboardResizedHint(snapshot)))
            }
            let swipeDuration = step.duration ?? tunables.defaultSwipeDuration
            let startY: Double
            if let band = await driver.backGestureEdgeWidths(), band.bottom > 0 {
                let cleared = ScrollGeometry.clearingBottomGestureBand(
                    y: element.frame.centerY, viewport: snapshot.screen, bottom: band.bottom)
                startY = cleared.y
                if cleared.moved { driverFallback = Self.joinNotes(driverFallback, Self.bottomBandNote) }
            } else {
                startY = element.frame.centerY
            }
            do {
                start = clock.now
                try await actingDriver.drag(fromX: element.frame.centerX, fromY: startY,
                                            toX: endElement.frame.centerX, toY: endElement.frame.centerY,
                                            pressSeconds: FlowStep.defaultDragPressSeconds, durationSeconds: swipeDuration)
                phase.actionMs += Self.ms(clock.now - start)
            } catch {
                // in-app の drag は自前描画だけ(それ以外は 501)ため、inapp モードでは typeDriver=XCUITest
                // で始点・終点を取り直す(ref はブリッジごとに別名前空間)
                guard DriverError.isBridgeIncapable(error), let td = typeDriver else { throw error }
                guard try await dragViaTypeDriver(td, step: step, endStep: endStep,
                                                  durationSeconds: swipeDuration, phase: &phase) else {
                    throw error
                }
                driverFallback = "fell back to XCUITest"
            }
        default:
            return StepOutcome(status: .skipped("unknown action: \(action)"))
        }
        return StepOutcome(status: status, healedStep: healedStep,
                           healedByFingerprint: healedByFingerprint,
                           driverFallback: Self.joinNotes(Self.joinNotes(driverFallback, ghostNote),
                                                          straddleNote))
    }

    /// **横スクロールの残骸を掴んでいないか**(判定は `DuplicateRegion` = MCP の
    /// `duplicateRegionNote` と共有)。**座標に依らない**ので keyboard/disabled と同じく
    /// 掴んだ時点で確定してよい —— 言っているのは「この ref はもう描かれていないコピーかも
    /// しれない」であって、撃つ点をどこへ寄せるかとは無関係。
    ///
    /// **注記だけで拒否しない**: どちらのコピーが生きているかは木から決められないので、
    /// 撃たずに止めると正しい操作まで殺す。
    /// **tap と doubleTap の両方から呼ぶ**(どちらも指で触る操作。片方だけ黙ると判断が食い違う)
    func duplicateRegionAdvisory(_ element: ElementInfo, in snapshot: SnapshotResponse) -> String? {
        guard let duplicate = DuplicateRegion.riskFor(element, in: snapshot.elements) else {
            return nil
        }
        noteCodesThisStep.insert(.staleDuplicateRegion)
        return "the tree lists this row twice ([\(duplicate.firstRef)] and"
            + " [\(duplicate.secondRef)], \(duplicate.length) elements each);"
            + " one copy is a leftover from horizontal scrolling"
    }

    /// 注記の合流(どちらか片方だけのことが多いので nil を潰して " / " で繋ぐ)
    static func joinNotes(_ notes: String?...) -> String? {
        let present = notes.compactMap { $0 }.filter { !$0.isEmpty }
        return present.isEmpty ? nil : present.joined(separator: " / ")
    }

    /// 対象を取り得るジェスチャ(対象未指定なら画面全体)。ロケータ有無で解決だけが違うので
    /// 実体はここ1箇所に置く
    static let gestureActions: Set<String> = ["pinchOut", "pinchIn", "doubleTap", "swipeBy", "gesture"]

    /// ピンチ / ダブルタップ / 相対ドラッグの実行。target = 対象領域(要素の frame か画面)、
    /// viewport = 画面矩形。**慣性が乗るので末尾で必ず整定を待つ**(ランナーはこれらのルートを
    /// 整定対象に入れていない。理由は BridgeRouter.mutatingPaths のコメント)
    ///
    /// **private ではない**: StepExecutor+DirectActions.swift の executeDirectUntargetedGesture からも呼ぶ
    func performGesture(_ action: String, step: FlowStep, target: FTRect,
                        identifier: String?, viewport: FTRect,
                        phase: inout PhaseAccumulator) async throws -> StepOutcome {
        var viaXCUITest = false
        var bandNote: String?
        switch action {
        case "pinchOut", "pinchIn":
            let out = action == "pinchOut"
            let scale = step.scale
                ?? (out ? FlowStep.defaultPinchOutScale : FlowStep.defaultPinchInScale)
            // **向きと倍率が食い違ったら実行しない**。撃ってしまうと「pinchOut と書いたのに
            // 縮小された」が成功として記録され、書き間違いに気付けない
            guard scale.isFinite, out ? scale > 1 : (scale > 0 && scale < 1) else {
                return StepOutcome(status: .failed(
                    out ? "pinchOut requires scale > 1 (got \(scale)). Use pinchIn to zoom out."
                        : "pinchIn requires 0 < scale < 1 (got \(scale)). Use pinchOut to zoom in."))
            }
            viaXCUITest = try await pinchWithFallback(
                frame: target, identifier: identifier, scale: scale,
                durationSeconds: step.duration ?? tunables.defaultPinchDuration,
                phase: &phase)
        case "doubleTap":
            let bandY = await bottomBandTapY(for: target, screen: viewport)
            viaXCUITest = try await doubleTapWithFallback(x: target.centerX, y: bandY ?? target.centerY,
                                                          phase: &phase)
            if bandY != nil { bandNote = Self.bottomBandTapNote }
        case "swipeBy":
            // iOS/3ボタン navigation は nil → 除外なし(0, 0)。既定値を panPath 側に置かないのは
            // この分岐に確実に決めさせるため(ScrollGeometry.panPath の doc 参照)
            let backGestureEdgeWidths = await driver.backGestureEdgeWidths() ?? (left: 0, right: 0, bottom: 0)
            guard let path = ScrollGeometry.panPath(container: target, viewport: viewport,
                                                    dxRatio: step.dxRatio ?? 0,
                                                    dyRatio: step.dyRatio ?? 0,
                                                    backGestureEdgeWidths: backGestureEdgeWidths) else {
                // 動かないドラッグを撃って「成功」と記録すると、比率の書き間違いに気付けない
                return StepOutcome(status: .failed(
                    "swipeBy cannot build a usable path (the target area is off-screen, "
                        + "or dxRatio/dyRatio are too small to move a finger)"))
            }
            viaXCUITest = try await dragWithFallback(
                path: path,
                durationSeconds: step.duration ?? tunables.defaultSwipeDuration,
                phase: &phase)
        case "gesture":
            // 検査は写す前(比率)の段で言う(TouchGesture.resolve の doc)。失敗はデバイスに触らず返す
            // —— 以降の共通処理(末尾の整定待ち)は実際に撃った回だけ通したいので、ここで早期 return する
            switch TouchGesture.resolve(step.gesture ?? [], in: target, screen: viewport,
                                        maxGestureSeconds: step.maxGestureSeconds
                                            ?? BridgeAPI.defaultMaxGestureSeconds) {
            case .failure(let rejection):
                return StepOutcome(status: .failed(rejection.message))
            case .success(let request):
                viaXCUITest = try await gestureWithFallback(phase: &phase) {
                    try await $0.gesture(request)
                }
            }
        default:
            return StepOutcome(status: .skipped("unknown gesture: \(action)"))
        }
        let settled = skippingSettle(step) ? true : try await settledSignature(phase: &phase).settled
        var notes: [String] = []
        if viaXCUITest { notes.append("fell back to XCUITest") }
        if let bandNote { notes.append(bandNote) }
        if !settled { note(.settleCapped, into: &notes) }
        // 比率は対象の大きさに対する割合で片側 maxPanRatio が上限。超えた指定を黙って丸めると、小さい要素で
        // 「14 倍払った」つもりが数 pt しか動かず緑になる(実測: シートの見出しで閉じなかった)
        if action == "swipeBy",
           [step.dxRatio, step.dyRatio].contains(where: { abs($0 ?? 0) > ScrollGeometry.maxPanRatio }) {
            note(.swipeByRatioCapped, into: &notes)
        }
        return StepOutcome(status: .passed,
                           driverFallback: notes.isEmpty ? nil : notes.joined(separator: " / "))
    }

    /// `pendingTypeKeyboardCheck` を消化する: 直前の type の前後でキーボードが動いた(出た・出る途中・出し直しで隠れた)なら、
    /// 出きるまで待って整定を見る。ロケータ操作の解決と、ロケータを持たない `back()`(`awaitKeyboardBeforeBack`)・`hideKeyboard` が呼ぶ
    /// —— back() が待たずに撃つと、上がってくる途中のキーボードの前に戻るが届き、横取りの確認ダイアログが出ない
    /// (E2EY-iOS の XCUITest の戻るの横取り S0040)
    func consumePendingTypeKeyboardCheck(_ snapshot: SnapshotResponse,
                                         phase: inout PhaseAccumulator) async throws -> SnapshotResponse {
        guard pendingTypeKeyboardCheck else { return snapshot }
        let clock = ContinuousClock()
        var snapshot = snapshot
        pendingTypeKeyboardCheck = false
        keyboardWaitExhausted = false
        // 出し直しの途中で隠れているなら、戻るまで待ってから整定を見る(keyboardHiddenAfterType の doc)。
        // 上限は焦点待ちの共有値(戻らなければ正当に閉じたと見てそのまま進む)
        // 戻りを待った回は、戻った位置が打つ前と同じでも中身はこれから動くので必ず整定を見る
        let waitedForKeyboard = Self.keyboardHiddenAfterType(
            before: keyboardFrameBeforeType, after: snapshot.keyboardFrame,
            screen: snapshot.screen, typedNewline: pendingTypeEndedWithNewline)
        if waitedForKeyboard {
            let deadline = clock.now + .milliseconds(Int(FocusWait.waitSeconds * 1000))
            while clock.now < deadline,
                  !Self.keyboardOnScreen(snapshot.keyboardFrame, screen: snapshot.screen) {
                let waitStart = clock.now
                try await Task.sleep(for: .milliseconds(Int(FocusWait.pollSeconds * 1000)))
                phase.waitMs += Self.ms(clock.now - waitStart)
                let start = clock.now
                snapshot = try await freshSnapshot(.afterOwnMove)
                phase.snapshotMs += Self.ms(clock.now - start)
            }
        }
        // type はキーボードの表示を待たずに返る(Android・iOS は画面の外の申告のとき): 出るまで撮り直す(KeyboardWait の doc)。
        // 出れば下の keyboardShifted(nil → 矩形)が true になり整定へつながる
        if KeyboardWait.shouldAwaitAppearance(
            isAndroid: isAndroid, before: keyboardFrameBeforeType, after: snapshot.keyboardFrame,
            screen: snapshot.screen, typedNewline: pendingTypeEndedWithNewline) {
            let deadline = clock.now + .milliseconds(Int(KeyboardWait.appearSeconds * 1000))
            while clock.now < deadline,
                  !Self.keyboardOnScreen(snapshot.keyboardFrame, screen: snapshot.screen) {
                let waitStart = clock.now
                try await Task.sleep(for: .milliseconds(Int(KeyboardWait.pollSeconds * 1000)))
                phase.waitMs += Self.ms(clock.now - waitStart)
                let start = clock.now
                snapshot = try await freshSnapshot(.afterOwnMove)
                phase.snapshotMs += Self.ms(clock.now - start)
            }
            if !Self.keyboardOnScreen(snapshot.keyboardFrame, screen: snapshot.screen) {
                noteCodesThisStep.insert(.keyboardNotShownAfterType)
                keyboardWaitExhausted = true
            }
        }
        if waitedForKeyboard
            || Self.keyboardShifted(before: keyboardFrameBeforeType, after: snapshot.keyboardFrame) {
            // **settledSignature が自分で phase へ計上する**ので、ここでは足さない
            // (足すと待ち時間を snapshotMs へ二重計上する)
            let settled = try await settledSignature(phase: &phase)
            snapshot = settled.snapshot
            // **待っている間に実際に木が変わった回だけ**数える(settledAfterKeyboard の doc)
            if settled.changed { noteCodesThisStep.insert(.settledAfterKeyboard) }
        }
        return snapshot
    }

    /// `pendingHideKeyboardWait` を消化する: 木がまだキーボードを申告していれば消えるまで待ち、消えたら整定を見る
    /// (下端の要素が戻り、中身が伸びる)。印が無ければ渡した木をそのまま返す。ロケータ操作の解決が呼ぶ
    func consumePendingHideKeyboardWait(_ snapshot: SnapshotResponse,
                                        phase: inout PhaseAccumulator) async throws -> SnapshotResponse {
        guard let cap = pendingHideKeyboardWait else { return snapshot }
        pendingHideKeyboardWait = nil
        guard Self.keyboardOnScreen(snapshot.keyboardFrame, screen: snapshot.screen) else { return snapshot }
        let clock = ContinuousClock()
        var snapshot = snapshot
        let deadline = clock.now + .milliseconds(Int(cap * 1000))
        while clock.now < deadline, Self.keyboardOnScreen(snapshot.keyboardFrame, screen: snapshot.screen) {
            let waitStart = clock.now
            try await Task.sleep(for: .milliseconds(Int(FocusWait.pollSeconds * 1000)))
            phase.waitMs += Self.ms(clock.now - waitStart)
            let start = clock.now
            snapshot = try await freshSnapshot(.afterOwnMove)
            phase.snapshotMs += Self.ms(clock.now - start)
        }
        // **settledSignature が自分で phase へ計上する**(ここでは足さない)
        return try await settledSignature(phase: &phase).snapshot
    }

    /// **ロケータを持たない `back()` の前に、直前の type のキーボードが出きるのを待つ**(consumePendingTypeKeyboardCheck)。
    /// iOS の XCUITest の /type はキーボードが出る前に返り、待たずに撃った戻るは上がってくる途中のキーボードの前に届いて
    /// 横取りの確認ダイアログが出なかった(E2EY-iOS の XCUITest の戻るの横取り S0040)。印が無ければ何も読まない(費用ゼロ)
    public func awaitKeyboardBeforeBack() async throws {
        guard pendingTypeKeyboardCheck else { return }
        var phase = PhaseAccumulator()
        _ = try await consumePendingTypeKeyboardCheck(try await freshSnapshot(.afterOwnMove), phase: &phase)
    }

    /// **縁の帯に潜っている対象を、容器を送って外す**(tap と type が共有する)。
    /// 覆いは2種類: 木に載る操作可能な帯(タブバー・固定フッタ = `overlayCoveringForUncover`)と、
    /// 木に要素として渡せないソフトキーボード(`KeyboardOcclusion.frame`)。
    /// 何も送らなかったら nil(呼び手は警告付きで撃つ。**拒否はしない**)。
    ///
    /// **1回でも送ったら、撃つ前の木の ref は使えない**: 撮り直しでブリッジの ref の表が振り直される
    /// (in-app は最後の `/snapshot` の表しか持たない)。外れきらなくても `.stillCovered` で撮り直した木の要素を
    /// 返す —— 古い ref で撃つと表に無ければ 404、**有れば別の要素を黙って押す**(E2EY-iOS の OTP で 404 が
    /// 3/3 再現)。撮り直しは**撃つドライバ**の木で行う(`snapshotSource`。既定値を置かない = 呼び手の渡し忘れを
    /// コンパイルで止める。主ドライバで撮ると、フォールバックへ切り替えた回で in-app の ref を XCUITest へ撃つ)。
    ///
    /// **1回では足りないことがあるので、動いている限り最大 `maxLifts` 回送る**
    /// (実測: 191pt 要求して実際の移動は 144pt で、中心がまだ覆いの内側だった)。
    /// 動かなくなったら諦める = 端まで来ている画面で無限に粘らない。
    /// verb は注記の文言(touching / typing)。判定は共通で、言い回しだけ呼び手が持つ
    /// **private ではない**: StepExecutor+Hold.swift の executeHoldStart からも呼ぶ
    func liftCoveredTarget(_ element: ElementInfo, in snapshot: SnapshotResponse,
                           step: FlowStep, verb: String, snapshotSource: CoverLiftSnapshotSource,
                           maxLifts: Int = 3,
                           phase: inout PhaseAccumulator) async throws -> CoverLift? {
        var current = element
        var currentSnapshot = snapshot
        var coverName: String?
        var retook = false
        let clock = ContinuousClock()
        for _ in 0..<maxLifts {
            // 対象を含む容器が無い(隠れるバー等)なら、画面の主たる縦の容器を送り先にする
            // (`uncoverOutsideScrollJump`。覆いが名前つきで容器の縁に接しているときだけ jump が出る)
            let ownContainer = ContainerGeometry.clippingContainer(
                of: current, in: currentSnapshot.elements, inferring: step.containerInference ?? true)
            let outsideContainer = ownContainer == nil
                ? TapTargetGeometry.primaryScrollContainer(in: currentSnapshot.elements,
                                                           screen: currentSnapshot.screen)?.frame
                : nil
            guard let container = ownContainer ?? outsideContainer else {
                return retook ? .stillCovered(element: current, snapshot: currentSnapshot) : nil
            }
            let keyboard = KeyboardOcclusion.resolve(reported: currentSnapshot.keyboardFrame,
                                                     in: currentSnapshot.elements, screen: currentSnapshot.screen)
            var jump: Double?
            var coverRect: FTRect?
            var coverIsKeyboard = false
            // 申告が無い木では chrome から推定する(意味は変えない。理由は keyboardBandFromChrome)。
            // **申告が画面の外(隠れた)なら推定しない** —— 申告がある以上「無い」ではない
            let keyboardBand = keyboard.frame
                ?? (currentSnapshot.keyboardFrame == nil
                    ? TapTargetGeometry.keyboardBandFromChrome(in: currentSnapshot.elements,
                                                               screen: currentSnapshot.screen) : nil)
            if let keyboardFrame = keyboardBand,
               TapTargetGeometry.keyboardCoveredAdvisory(current, keyboardFrame: keyboardFrame) != nil {
                jump = TapTargetGeometry.uncoverKeyboardScrollJump(target: current, keyboard: keyboardFrame,
                                                                   container: container)
                coverName = coverName ?? "the keyboard"
                coverRect = keyboardFrame
                coverIsKeyboard = jump != nil
            }
            if jump == nil,
               let over = TapTargetGeometry.overlayCoveringForUncover(
                   current, in: currentSnapshot.elements, screen: currentSnapshot.screen) {
                jump = outsideContainer == nil
                    ? TapTargetGeometry.uncoverScrollJump(target: current, coveredBy: over,
                                                          container: container)
                    : TapTargetGeometry.uncoverOutsideScrollJump(target: current, coveredBy: over,
                                                                 container: container)
                coverName = coverName ?? TapTargetGeometry.describe(over)
                coverRect = over.frame
            }
            // **容器の縁に貼り付いた見出しの下に潜った対象**(木の並びでは見出しが奥 = 上の判定は拾えない。pinnedBandCovering の doc)
            if jump == nil, ownContainer != nil,
               let band = TapTargetGeometry.pinnedBandCovering(current, in: currentSnapshot.elements,
                                                               container: container) {
                jump = TapTargetGeometry.uncoverScrollJump(target: current, coveredBy: band, container: container)
                coverName = coverName ?? TapTargetGeometry.describe(band)
                coverRect = band.frame
            }
            // **iOS: 容器の下端で見切れた対象**(覆いは無いが中心が描かれていない。bottomEdgeClipLift の doc)。
            // 指は見切れた行より上に当てる(行そのものを覆いとして避ける)
            if jump == nil, !isAndroid,
               let lift = TapTargetGeometry.bottomEdgeClipLift(current, in: currentSnapshot.elements) {
                jump = lift
                coverName = coverName ?? "the bottom edge of its scroll container"
                coverRect = FTRect(x: container.x, y: current.frame.y, width: container.width,
                                   height: max(0, container.y + container.height - current.frame.y))
            }
            // **指を当てるのは覆いを避けた領域**(理由は uncoverDragArea)
            guard let jump, let coverRect,
                  let dragArea = coverIsKeyboard
                      ? TapTargetGeometry.keyboardUncoverDragArea(container: container, keyboard: coverRect)
                      : TapTargetGeometry.uncoverDragArea(container: container, cover: coverRect),
                  await slowDrag(jump: jump, container: dragArea,
                                 avoidingInputsIn: currentSnapshot.elements, phase: &phase) else {
                return retook ? .stillCovered(element: current, snapshot: currentSnapshot) : nil
            }
            let start = clock.now
            let after: SnapshotResponse
            switch snapshotSource {
            case .primary: after = try await freshSnapshot(.afterOwnMove)
            case .driver(let other): after = try await other.snapshot(bypassingCache: true)
            }
            phase.snapshotMs += Self.ms(clock.now - start)
            retook = true
            guard let (moved, _) = LocatorResolver.resolve(step: step, in: after) else {
                return .lost(snapshot: after)
            }
            let afterBand = KeyboardOcclusion.resolve(reported: after.keyboardFrame,
                                                      in: after.elements, screen: after.screen).frame
                ?? (after.keyboardFrame == nil
                    ? TapTargetGeometry.keyboardBandFromChrome(in: after.elements, screen: after.screen) : nil)
            let stillCovered = (afterBand.flatMap {
                    TapTargetGeometry.keyboardCoveredAdvisory(moved, keyboardFrame: $0)
                } != nil)
                || TapTargetGeometry.overlayCoveringForUncover(
                       moved, in: after.elements, screen: after.screen) != nil
                || (!isAndroid && TapTargetGeometry.bottomEdgeClipLift(moved, in: after.elements) != nil)
                || TapTargetGeometry.pinnedBandCovering(moved, in: after.elements, container: container) != nil
            if !stillCovered {
                return .lifted(element: moved, snapshot: after,
                               note: "scrolled the container to bring the target out from under"
                                   + " \(coverName ?? "the cover") before \(verb) it")
            }
            // 動かなくなったら諦める(端まで来ている・容器がスクロールしない画面)。
            // **y だけで比べない**: 容器の縁で切られた対象は、動いても y が縁のまま高さだけ変わる
            // (実測 RN Android: 行の上端が容器の上端 403 に張り付いたまま 109 へ伸びた)
            guard moved.frame.y != current.frame.y
                || moved.frame.height != current.frame.height else {
                return .stillCovered(element: moved, snapshot: after)
            }
            current = moved
            currentSnapshot = after
        }
        return retook ? .stillCovered(element: current, snapshot: currentSnapshot) : nil
    }

    /// 呼び手が撃つ ref を、送った後の木から取り直すための結果(`liftCoveredTarget` の doc)
    enum CoverLift {
        case lifted(element: ElementInfo, snapshot: SnapshotResponse, note: String)
        /// 送ったが外れきらなかった。**要素と木は撮り直した後のもの**(撃つ前の ref は無効)
        case stillCovered(element: ElementInfo, snapshot: SnapshotResponse)
        /// 送った後の木で対象を引き当てられない(撃つ前の ref で撃ってはいけない)
        case lost(snapshot: SnapshotResponse)

        var element: ElementInfo? {
            switch self {
            case .lifted(let element, _, _), .stillCovered(let element, _): return element
            case .lost: return nil
            }
        }
        var snapshot: SnapshotResponse {
            switch self {
            case .lifted(_, let snapshot, _), .stillCovered(_, let snapshot), .lost(let snapshot): return snapshot
            }
        }
        var note: String? {
            if case .lifted(_, _, let note) = self { return note }
            return nil
        }
    }

    /// `liftCoveredTarget` が撮り直す木の取得元 = **撃つドライバ**(ref の名前空間を合わせる)
    enum CoverLiftSnapshotSource {
        /// 主ドライバ(`freshSnapshot` の迂回の規則を通す)
        case primary
        /// フォールバック・typeDriver で撃つとき
        case driver(AppDriver)
    }

    /// 消去の後の木で、消した欄と**同じ欄**を引き直す(nil = 撃たない)。順は ①空でない identifier と型が同じ要素が1つ
    /// ②ロケータの解決結果で型が同じもの ③型と枠が同じ要素が1つ。**ロケータの結果をそのまま採らない** —— ラベル・値で
    /// 指したロケータは、欄を空にすると現れるヒントの文字(別の staticText になる実装がある = E2E-CMP の iOS)に当たりうる
    static func relocateAfterClear(_ element: ElementInfo, step: FlowStep, in snapshot: SnapshotResponse) -> ElementInfo? {
        func only(_ matches: [ElementInfo]) -> ElementInfo? { matches.count == 1 ? matches[0] : nil }
        if let id = element.identifier, !id.isEmpty {
            return only(snapshot.elements.filter { $0.identifier == id && $0.type == element.type })
        }
        if let (found, _) = LocatorResolver.resolve(step: step, in: snapshot), found.type == element.type { return found }
        return only(snapshot.elements.filter { $0.type == element.type && $0.frame == element.frame })
    }

    static func clearLostTargetMessage(_ step: FlowStep) -> String {
        "the field was cleared for replace:, but it could not be found on the screen afterwards:"
            + " \(step.locatorSummary) (nothing was typed)"
    }

    /// 送った後に対象を見失ったときの失敗文(撃つ前の ref で撃たない理由を言う)
    static func coverLiftLostMessage(_ step: FlowStep, verb: String) -> String {
        "the target was covered, so the container was scrolled before \(verb) it, but the target could not be"
            + " found on the screen afterwards: \(step.locatorSummary) (nothing was \(verb == "typing" ? "typed" : "touched"))"
    }

    /// 座標ドラッグを通常ドライバ →(501/ルート不明404 なら)typeDriver の順で撃つ。
    /// 座標はブリッジ間で共通(ref と違い取り直しが要らない)ので、そのまま渡すだけでよい。
    /// 戻り値: true = typeDriver(XCUITest)経由
    /// **private ではない**: StepExecutor+DirectActions.swift の executeDirectFlick からも呼ぶ
    func dragWithFallback(path: FTSwipePath, durationSeconds: Double,
                          phase: inout PhaseAccumulator) async throws -> Bool {
        try await gestureWithFallback(phase: &phase) {
            try await $0.drag(fromX: path.fromX, fromY: path.fromY,
                              toX: path.toX, toY: path.toY,
                              pressSeconds: FlowStep.defaultDragPressSeconds, durationSeconds: durationSeconds)
        }
    }

    private func doubleTapWithFallback(x: Double, y: Double,
                                       phase: inout PhaseAccumulator) async throws -> Bool {
        try await gestureWithFallback(phase: &phase) { try await $0.doubleTap(x: x, y: y) }
    }

    private func pinchWithFallback(frame: FTRect, identifier: String?, scale: Double,
                                   durationSeconds: Double,
                                   phase: inout PhaseAccumulator) async throws -> Bool {
        try await gestureWithFallback(phase: &phase) {
            try await $0.pinch(frame: frame, identifier: identifier, scale: scale,
                               durationSeconds: durationSeconds)
        }
    }

    /// 座標だけで完結するジェスチャの共通フォールバック。in-app が「このブリッジでは不可」と
    /// 返したとき(501 / ルート不明 404)だけ XCUITest へ回す —— in-app は自前描画の
    /// フレームワークなら多点も撃てるが、UIKit/SwiftUI では合成タッチが受理されず 501 を返す。
    /// **409 は含めない**(理由は DriverError.isBridgeIncapable)。
    /// **private ではない**: StepExecutor+Hold.swift の executeHoldStart からも呼ぶ
    func gestureWithFallback(phase: inout PhaseAccumulator,
                             _ body: (AppDriver) async throws -> Void) async throws -> Bool {
        let clock = ContinuousClock()
        let start = clock.now
        do {
            try await body(driver)
            phase.actionMs += Self.ms(clock.now - start)
            return false
        } catch {
            guard DriverError.isBridgeIncapable(error), let td = typeDriver else { throw error }
            try await body(td)
            phase.actionMs += Self.ms(clock.now - start)
            return true
        }
    }

    /// typeDriver で始点・終点を取り直してドラッグする(ref はブリッジごとに別名前空間なので、
    /// typeViaTypeDriver と同じ理由で両方とも撮り直す)。解決できなければ false(呼び出し側で再スロー)。
    private func dragViaTypeDriver(_ td: AppDriver, step: FlowStep, endStep: FlowStep,
                                   durationSeconds: Double,
                                   phase: inout PhaseAccumulator) async throws -> Bool {
        let clock = ContinuousClock()
        var start = clock.now
        let snapshot = try await td.snapshot()
        phase.snapshotMs += Self.ms(clock.now - start)
        guard let (from, _) = LocatorResolver.resolve(step: step, in: snapshot),
              let (to, _) = LocatorResolver.resolve(step: endStep, in: snapshot) else { return false }
        start = clock.now
        try await td.drag(fromX: from.frame.centerX, fromY: from.frame.centerY,
                          toX: to.frame.centerX, toY: to.frame.centerY,
                          pressSeconds: FlowStep.defaultDragPressSeconds, durationSeconds: durationSeconds)
        phase.actionMs += Self.ms(clock.now - start)
        return true
    }
}

extension StepExecutor {
    /// **OS のシステム UI が被さっている間は操作させない**(`FTCore.SystemUIGate`)。
    /// 戻り値 nil = 進んでよい / 非 nil = そのままステップの結果にする(失敗)。
    ///
    /// in-app の注入は OS のイベント経路を通らないので、覆われていても届いてしまう
    /// (= 人手では不可能な操作)。判定は XCUITest ランナーの `GET /systemalert` だけを見る
    /// (**約 73ms**。木を全部撮る 185ms は毎ステップ払えない。`applicationState` は
    /// 端末で割れて使えなかった —— SystemUIGate の doc)。
    ///
    /// 順序は3つ。**今の挙動を包含する**ように並べてある:
    ///   ① 対象が fallback(SpringBoard)の木で解決できる → 何もしない
    ///      = シナリオ自身がそのアラートを操作している。下のドライバ切替がそのまま拾う
    ///   ② 登録済みの `iosAlertHandler` で閉じられる → 閉じて木を取り直す
    ///   ③ どちらでもない → **撃たずに待つ**。消えたら進み、待ち切れなければ失敗
    ///
    /// 予算はステップの `timeout`、無ければ既定の待ち(**新しい数字は作らない**。
    /// `waitUntilEnabled` と同じ規律)。
    ///
    /// **`iosAlertHandler` の登録が残っているときだけ働く**。
    /// アラートが出る操作は書き手が知っているので直前に登録でき、**登録の無い実行に
    /// 1往復(約 73ms)も払わせない**。登録があるのに一致するボタンが無いときは③で止める ——
    /// 登録は「次にアラートが出る」という予告でもあるため。
    /// fallback(XCUITest ランナー)が無い構成も同様に何もしない。
    ///
    /// **発火した登録は台帳から外れる**(1回の登録 = 1枚のアラート)。全部外れたら
    /// 以後この関数は即 nil を返す = 監視の解除。
    /// **アラートは重なり得る**ので、閉じたあとは戻らずに**もう一度確かめてから**進む
    func waitOutSystemUI(step: FlowStep,
                         phase: inout PhaseAccumulator) async throws -> StepResult.Status? {
        guard systemAlertWatchlist.isWatching, let fb = fallbackDriver else { return nil }
        let clock = ContinuousClock()
        var start = clock.now
        var probe = await probeSystemAlert(fb, phase: &phase)
        guard SystemUIGate.isCovered(probe) else { return nil }

        let deadline = clock.now.advanced(by: .seconds(step.timeout ?? tunables.defaultTimeout))
        var backoff = PollBackoff()
        var covering = SystemUIGate.describeCovering(probe)
        // **最後に読めたボタンの並び**を持ち回る(失敗の言い分に実際の名前を出すため。
        // 読めた回のものを残す = 消えかけの1枚で空になっても直前の観測を捨てない)
        var actualButtons = probe?.buttons ?? []
        while true {
            // **予算は毎周確かめる**(②で閉じ続けられる限り回るので、③だけに置くと
            // 「閉じても消えない」画面で無限に回る ——
            // 変異テストで実際にハングして見つけた。消費が有限なのは偶然の歯止めであって設計ではない)
            guard clock.now < deadline else {
                return failed(.systemUICovered,
                              SystemUIGate.failureMessage(covering: covering,
                                                          actualButtons: actualButtons,
                                                          declaredButtons: systemAlertWatchlist.describedRules))
            }
            start = clock.now
            let fsnap = try await fb.snapshot()
            phase.snapshotMs += Self.ms(clock.now - start)
            // ① シナリオ自身がアラートを操作している
            if LocatorResolver.resolveDetailed(step: step, in: fsnap) != nil { return nil }
            // ② 宣言があれば閉じる。**閉じたら戻らずに確かめ直す** —— 権限アラートは
            //    重なることがあり(位置情報の直後に通知など)、1枚閉じただけで進むと
            //    2枚目に覆われたまま撃つことになる
            if await dismissSystemAlert(in: fsnap, via: fb) != nil {
                noteCodesThisStep.insert(.waitedForSystemUI)
                probe = await probeSystemAlert(fb, phase: &phase)
                covering = SystemUIGate.describeCovering(probe) ?? covering
                if let read = probe?.buttons, !read.isEmpty { actualButtons = read }
                if !SystemUIGate.isCovered(probe) { return nil }
                continue   // 次の1枚を同じ順序で扱う
            }
            // ③ 撃たずに待つ(予算の確認はループ先頭)
            start = clock.now
            try await Task.sleep(for: backoff.nextDelay())
            phase.waitMs += Self.ms(clock.now - start)
            probe = await probeSystemAlert(fb, phase: &phase)
            covering = SystemUIGate.describeCovering(probe) ?? covering
            if let read = probe?.buttons, !read.isEmpty { actualButtons = read }
            if !SystemUIGate.isCovered(probe) {
                noteCodesThisStep.insert(.waitedForSystemUI)
                return nil
            }
        }
    }

    /// **fallback の木にシステム許可アラートが居たら、登録(iosAlertHandler)のボタンを押す**。
    /// 戻り値 = 押したラベル(nil = 押していない)。呼び出し側は木を取り直して解決をやり直す。
    ///
    /// 呼ぶのは「**要求された要素が primary でも fallback でも解決できなかった**」ときだけ ——
    /// 解決できているなら、シナリオ自身がそのアラートを操作しようとしている(`tap("許可")` /
    /// `ifCanSelect("許可")`)ので、自動処理が横から奪ってはいけない。
    /// 判断は FTCore.SystemAlertDismissal の1箇所(推測しない理由もそこ)。
    ///
    /// どれを押すか・押した後の台帳からの除去は **台帳(`SystemAlertWatchlist`)が全部持つ**。
    /// ここは選定 → タップ → 確定記録の順序だけ: タップは失敗し得るので、押せたと確定してから
    /// 記録する。押し続けても終わらない画面は `waitOutSystemUI` の予算が打ち切る
    @discardableResult
    public func dismissSystemAlert(in snapshot: SnapshotResponse,
                                   via fallback: AppDriver) async -> String? {
        guard let (button, index) = systemAlertWatchlist.buttonToTap(in: snapshot.elements),
              let label = button.label else {
            return nil
        }
        do { try await fallback.tap(ref: button.ref) } catch { return nil }
        systemAlertWatchlist.notePressed(index)
        onSystemAlertDismissed?(
            SystemAlertDismissal.actionDescription(pressed: button, in: snapshot.elements))
        return label
    }

    /// 対象が**操作可能になるまで**待つ(`tap` だけ)。戻り値 nil = 待たなかった/待ち切れなかった
    /// (呼び手はそのまま撃つ)。予算はステップの `timeout`、無ければ既定の待ち
    /// (`tunables.defaultTimeout`。**新しい数字は作らない**)。
    ///
    /// **`enabled` を明示したセレクタでは待たない** —— `&&enabled=false` は
    /// 「無効なものを狙って掴む」宣言なので、待つと必ず予算を捨てる
    func waitUntilEnabled(step: FlowStep, phase: inout PhaseAccumulator) async throws
        -> (element: ElementInfo, snapshot: SnapshotResponse, waitedMs: Int)? {
        let constrained = ([step.locator] + (step.fallbacks ?? []))
            .contains { $0?.enabled != nil }
        guard !constrained else { return nil }
        let clock = ContinuousClock()
        let began = clock.now
        let deadline = began.advanced(by: .seconds(step.timeout ?? tunables.defaultTimeout))
        var backoff = PollBackoff()
        while clock.now < deadline {
            var start = clock.now
            try await Task.sleep(for: backoff.nextDelay())
            phase.waitMs += Self.ms(clock.now - start)
            start = clock.now
            var snapshot = try await freshSnapshot(.afterOwnMove)
            phase.snapshotMs += Self.ms(clock.now - start)
            // **待っている間に湧いた割り込みはここで閉じる**。待ちは
            // 「撃つまでの時間」を伸ばすので、閉じないと**モーダルが被さる窓を自分で広げる**
            // ことになる(有効になった瞬間に覆いの上を撃つ)。解決の前に閉じるのは
            // executeAction 入口と同じ規律。宣言が無ければコストゼロ
            try await dismissInterruption(in: &snapshot, phase: &phase)
            guard let (element, _) = LocatorResolver.resolve(step: step, in: snapshot) else { continue }
            if element.enabled {
                return (element, snapshot, Self.ms(clock.now - began))
            }
        }
        return nil
    }

    /// 直前のタップが**叩いた対象へ焦点を立てられていなかった**ときに、入れ直す先を決める。
    /// nil = フォーカス中要素へそのまま送ってよい(焦点が叩いた対象そのもの/内側にある、
    /// または先が一意に決まらない)。**焦点が叩いた対象の外の別の欄に残っているだけでも
    /// 救済へ進む**(前の欄の焦点が外れないまま容器を叩く Android の形)。
    /// **木は撮り直す** —— ref は木ごとに振り直されるので、タップ時の ref は使えない。
    /// 判定と選び方は `InputFocusRescue`(純関数)に置く
    func retypeTargetIfUnfocused(after tapped: ElementInfo,
                                 phase: inout PhaseAccumulator) async throws -> ElementInfo? {
        let clock = ContinuousClock()
        let start = clock.now
        var snapshot = try await freshSnapshot(.afterOwnMove)
        phase.snapshotMs += Self.ms(clock.now - start)
        // 焦点が無い理由が**割り込みに持っていかれた**ことなら、閉じてから見る
        // (閉じずに入れ先を選ぶと、覆いの下の欄を名指しして ref で撃つことになる)
        try await dismissInterruption(in: &snapshot, phase: &phase)
        guard InputFocusRescue.focusIsElsewhere(from: tapped, in: snapshot.elements) else { return nil }
        guard let field = InputFocusRescue.fieldToType(after: tapped, in: snapshot.elements) else { return nil }
        // 呼び出し元(type のキーボード押し上げ検知)へ「打つ前」の状態を渡す橋渡し
        // (retypeRescueKeyboardFrame の doc。戻り値の型は変えない)
        retypeRescueKeyboardFrame = snapshot.keyboardFrame
        return field
    }

}
