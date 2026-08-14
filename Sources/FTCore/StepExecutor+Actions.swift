// StepExecutor+Actions.swift
// アクション実行(executeAction・typeDriver 経由の type/press/clear と drag/doubleTap/pinch の
// フォールバック。swipe のフォールバックは +Settle 側)。本体は StepExecutor.swift(instance 状態はそちらに置く)

import Foundation

extension StepExecutor {

    func executeAction(_ action: String, step: FlowStep,
                               cached: [FlowLocator] = [],
                               phase: inout PhaseAccumulator) async throws -> StepOutcome {
        let clock = ContinuousClock()
        cachedScreenshot = nil   // 画面を変える操作 → occlusion-guard スクショ再利用を無効化
        // 直前の操作の記録は**次の操作が画面を変えるまで**有効(検証は画面を変えないので消さない)。
        // `select` は掴むだけでデバイス操作が無いので例外 —— `tap → select → textIs` という
        // 一番ありふれた形で、落ちるのは textIs 側だから、ここで消すと肝心なときに証跡が無くなる
        if action != "select" { lastInteraction = nil }
        pendingScrollFrameNote = nil
        spanScale = 1
        // ロケータ不要のアクション
        if action == "swipe" {
            let direction = FTSwipeDirection(rawValue: step.direction ?? "") ?? .up
            let viaXCUITest = try await swipeWithFallback(direction, phase: &phase)
            // 慣性が止まるまで待つ。ランナー側は /swipe を整定対象から外している(そこで待っても
            // budget 内に収束しないため)ので、直後に tap する書き方をここで支える
            let settled = try await settledSignature(phase: &phase).settled
            var notes: [String] = []
            if viaXCUITest { notes.append("fell back to XCUITest") }
            if !settled { note(.settleCapped, into: &notes) }
            return StepOutcome(status: .passed,
                               driverFallback: notes.isEmpty ? nil : notes.joined(separator: " / "))
        }

        // Device-level, no locator. Per policy this does NOT fall back to typeDriver on failure —
        // rotation uses whichever engine this connection already runs. The driver throws (never
        // returns a mismatched orientation) if it didn't settle, so no post-hoc mismatch check needed.
        if action == "rotateTo" {
            guard let raw = step.direction, let orientation = FTOrientation(rawValue: raw) else {
                return StepOutcome(status: .failed("rotateTo requires an orientation"))
            }
            let start = clock.now
            _ = try await driver.rotate(to: orientation)
            phase.actionMs += Self.ms(clock.now - start)
            // **向きが変わっただけでは終わりではない**: ドライバは「向きが要求と一致したか」までしか
            // 見ておらず、その時点でレイアウトはまだ動いている。直後のタップは動く前の座標を撃つ
            // (2026-08-10 実測: 回転直後の `#tab_home` が (-6,45) 動いた後の位置に当たらず、
            // 別の要素を押していた)。スクロール後の静止をホスト側が担うのと同じ規律で、
            // 木が2回続けて同じ署名になるまで待つ
            _ = try? await settledSignature(phase: &phase)
            return StepOutcome(status: .passed)
        }

        // スクロールだけ行う(Shirates の scrollDown 等)。maxSwipes を繰り返し回数として使う
        if action == "scroll" {
            let direction = FTSwipeDirection(rawValue: step.direction ?? "") ?? .up
            let times = max(1, step.maxSwipes ?? 1)
            var viaXCUITest = false
            var unsettled = false
            var sentSwipes = 0
            // **rect だけの指定でも撮る**: scrollContainer は rect を先に返すが、scrollPath には
            // viewport(snapshot.screen)が要るので、木が無いと path ごと nil になり
            // 黙って全画面スワイプへ退化する(scrollToEdge/flick は rect を見ている。2026-08-12)
            var latest = (step.scrollFrame == nil && step.scrollFrameRect == nil)
                ? nil : try await snapshotForScrollFrame(phase: &phase)
            for index in 0..<times {
                // **明示 scrollFrame が解決できないなら、ここで打ち切る(1本も振らない)**。
                // 黙って全画面スワイプへ退化させない(runScrollSearch の fail-fast と同じ理由。2026-08-08)
                if let latest, Self.scrollFrameUnresolved(step, in: latest) {
                    noteCodesThisStep.insert(.scrollFrameMissing)
                    return StepOutcome(status: .failed(
                        Self.scrollFrameFailFastMessage(step, action: "swipe", swipes: sentSwipes)))
                }
                let path = latest.flatMap { scrollPath(step: step, intent: .search, in: $0) }
                if try await swipeWithFallback(direction, intent: .search, path: path,
                                               phase: &phase) { viaXCUITest = true }
                sentSwipes += 1
                // 続けて投げるとフリングの停止だけに消費されて空振りする(Android 実測)。
                // 「repeat 回ぶん送る」を守るため、次のスワイプ前に静止を待つ。
                // 最後の1回の後も待つ: ランナーは /swipe を整定対象から外しているので、
                // 直後に tap する書き方をここで支える(index 条件を外した理由)
                let settled = try await settledSignature(phase: &phase)
                if !settled.settled { unsettled = true }
                if step.scrollFrame != nil || step.scrollFrameRect != nil { latest = settled.snapshot }
            }
            var notes: [String] = []
            if viaXCUITest { notes.append("fell back to XCUITest") }
            if unsettled { note(.settleCapped, into: &notes) }
            if let note = pendingScrollFrameNote { notes.append(note) }
            return StepOutcome(status: .passed,
                               driverFallback: notes.isEmpty ? nil : notes.joined(separator: " / "))
        }

        // 端まで送る(Shirates の scrollToBottom 等)。**画面が変化しなくなったら端**とみなす。
        // 比較は**静止してから**行う(フリングの減速中に撮ると動いていないように見える)。
        // さらに **2 回続けて変化なし**を条件にする — Android では次のスワイプがフリングの
        // 停止だけに消費されて 1 回空振りすることがあり、1 回で打ち切ると途中で止まる
        // (2026-07-27 実測: scrollToTop が row_22 付近で停止した)
        if action == "scrollToEdge" {
            let direction = FTSwipeDirection(rawValue: step.direction ?? "") ?? .up
            var viaXCUITest = false
            var previous: String?
            var unchanged = 0
            var reachedEdge = false
            var sawUnsettled = false
            let limit = max(1, step.maxSwipes ?? FlowStep.defaultMaxEdgeSwipes)
            var hintJumps = 0
            var sentSwipes = 0
            for _ in 0..<limit {
                let settled = try await settledSignature(phase: &phase)
                if !settled.settled { sawUnsettled = true }
                unchanged = settled.signature == previous ? unchanged + 1 : 0
                // ヒント跳躍(WebView): 端までの残り距離が分かるときは長距離ドラッグで寄せる
                let jump = Self.offscreenEdgeJump(snapshot: settled.snapshot, finger: direction)
                if unchanged >= Self.unchangedRoundsForEdge(snapshot: settled.snapshot,
                                                            remainingJump: jump) {
                    reachedEdge = true
                    break
                }
                // **明示 scrollFrame が解決できないなら、ここで打ち切る(1本も振らない)**。
                // 黙って全画面スワイプへ退化させない(2026-08-08)
                if Self.scrollFrameUnresolved(step, in: settled.snapshot) {
                    noteCodesThisStep.insert(.scrollFrameMissing)
                    return StepOutcome(status: .failed(
                        Self.scrollFrameFailFastMessage(step, action: "swipe", swipes: sentSwipes)))
                }
                previous = settled.signature
                if let jump, let container = Self.webViewContainer(in: settled.snapshot),
                   await hintDrag(jump: jump, container: container,
                                  viewport: settled.snapshot.screen, phase: &phase) {
                    hintJumps += 1
                    sentSwipes += 1
                    continue
                }
                if try await swipeWithFallback(direction, intent: .edge,
                                               path: scrollPath(step: step, intent: .edge,
                                                                in: settled.snapshot),
                                               phase: &phase) { viaXCUITest = true }
                sentSwipes += 1
            }
            // 上限で抜けたら**端に着いたとは限らない**。黙って成功にすると
            // 「scrollToBottom したのに末尾が無い」の原因が読めなくなる
            var notes: [String] = []
            if !reachedEdge { notes.append("stopped at the limit of \(limit) (may not have reached the edge yet)") }
            if let note = pendingScrollFrameNote { notes.append(note) }
            if viaXCUITest { notes.append("fell back to XCUITest") }
            if hintJumps > 0 { notes.append("\(hintJumps) long drag(s) from scroll hints") }
            if sawUnsettled { note(.settleCapped, into: &notes) }
            return StepOutcome(status: .passed,
                               driverFallback: notes.isEmpty ? nil : notes.joined(separator: " / "))
        }

        // フリック(Shirates flickXxx 8種)。scrollableElement は持たず scrollFrame のセレクタ式
        // (nil = 画面全体)で表す。**repeat 回とも同じ座標を撃つ**(Shirates は容器を毎回測り直さない。
        // TestDriveSwipeExtension.kt 参照)。整定待ちは「swipe」アクションと同じ形で末尾に1回だけ
        // (ランナー側は /swipe を整定対象から外しているため)
        if action == "flick" {
            guard let kind = FlickKind(rawValue: step.direction ?? "") else {
                return StepOutcome(status: .failed("unknown flick kind: \(step.direction ?? "")"))
            }
            let times = max(1, step.maxSwipes ?? 1)
            let durationSeconds = step.duration ?? FlowStep.defaultFlickDurationSeconds
            let intervalSeconds = step.intervalSeconds ?? FlowStep.defaultFlickIntervalSeconds

            var path: FTSwipePath?
            if Self.coordinateScrollEnabled {
                let snapshot = try await snapshotForScrollFrame(phase: &phase)
                let container: FTRect?
                if let rect = step.scrollFrameRect {
                    container = rect
                } else if let locator = step.scrollFrame {
                    container = Self.match(locator, in: snapshot)?.frame
                } else {
                    container = snapshot.screen
                }
                // **明示 scrollFrame が解決できないなら、ここで打ち切る(1本も振らない)**。
                // 黙って全画面スワイプへ退化させない(scroll/scrollToEdge と同じ理由。2026-08-08)。
                // rect は常に解決済みなのでこの分岐に来ない
                if step.scrollFrame != nil, container == nil {
                    noteCodesThisStep.insert(.scrollFrameMissing)
                    return StepOutcome(status: .failed(
                        Self.scrollFrameFailFastMessage(step, action: "flick", swipes: 0)))
                }
                if let container {
                    path = ScrollGeometry.flickPath(
                        container: container, viewport: snapshot.screen, kind: kind,
                        startMarginRatio: step.startMarginRatio
                            ?? FTScrollDefaults.startMarginRatio(intent: .gesture, vertical: kind.isVertical))
                    // **容器は解決したが動かせる幅が無い**(margin で潰れた等)。黙って全画面へ
                    // 落ちると理由が読めなくなる(scrollPath と同じ注記。2026-08-08)
                    if path == nil, step.scrollFrame != nil || step.scrollFrameRect != nil {
                        pendingScrollFrameNote = "the specified scrollFrame resolved but leaves"
                            + " nothing to move, so the whole screen was swiped"
                    }
                }
            }

            var viaXCUITest = false
            if let path {
                for _ in 0..<times {
                    if times > 1 {
                        let waitStart = clock.now
                        try await Task.sleep(for: .milliseconds(Int(intervalSeconds * 1000)))
                        phase.waitMs += Self.ms(clock.now - waitStart)
                    }
                    // in-app エンジンは drag を一切実装しない(501)ため、hybrid では
                    // typeDriver(XCUITest)へ回す(swipePointToPoint と同じ理由)
                    if try await dragWithFallback(path: path, durationSeconds: durationSeconds,
                                                  phase: &phase) {
                        viaXCUITest = true
                    }
                }
            } else {
                // 殺しスイッチ有効時、または領域を削りすぎて座標を作れないとき: 向き基準の汎用スワイプへ
                // 落ちる(scroll アクションが scrollPath nil のとき辿る経路と同じ考え方)
                if try await swipeWithFallback(kind.fingerDirection, phase: &phase) { viaXCUITest = true }
            }
            let settled = try await settledSignature(phase: &phase).settled
            var notes: [String] = []
            if let note = pendingScrollFrameNote { notes.append(note) }
            if viaXCUITest { notes.append("fell back to XCUITest") }
            if !settled { note(.settleCapped, into: &notes) }
            return StepOutcome(status: .passed,
                               driverFallback: notes.isEmpty ? nil : notes.joined(separator: " / "))
        }

        // ピンチ・ダブルタップ・相対ドラッグ(斜め可)の**対象未指定版** = 画面全体を対象にする。
        // ロケータ付きは下の switch(要素解決・ヒール・スクロール探索にそのまま乗せるため)で、
        // 対象の決め方以外は performGesture に集約してある
        if Self.gestureActions.contains(action), step.locator == nil,
           step.fallbacks?.isEmpty ?? true {
            let snapshot = try await snapshotForScrollFrame(phase: &phase)
            return try await performGesture(action, step: step, target: snapshot.screen,
                                            identifier: nil, viewport: snapshot.screen,
                                            phase: &phase)
        }

        // 要素が見つかるまでスクロール(見つかったら成功。操作はしない)
        if action == "scrollTo" {
            let result = try await runScrollSearch(step: step, phase: &phase)
            let note = recordedScrollSearchNote(result, scrollFrameNote: pendingScrollFrameNote)
            guard result.found else {
                return StepOutcome(status: .failed(Self.scrollNotFoundMessage(step, result)))
            }
            if let fallback = result.fallback {
                return StepOutcome(status: .passedViaFallback(fallback), driverFallback: note)
            }
            return StepOutcome(status: .passed, driverFallback: note)
        }

        // ロケータ指定のない type はフォーカス中の要素へ送る(直前の tap でフォーカスした欄など)。
        // ref: nil = ブリッジがフォーカス中要素へ入力(iOS/Android とも)。ロケータ解決を挟まない。
        if action == "type", step.locator == nil, step.fallbacks?.isEmpty ?? true {
            // **replace はここでも型の有無に関わらず効かせる**(下の clearInput ロケータなし版と
            // 同じヘルパを通す)。ここで見落とすと `type(text, replace: true)` だけ無言で追記に戻る
            var replaceFallbackNote: String?
            if step.replace == true {
                switch try await performClearInputFocused(phase: &phase) {
                case .cleared(let fallback):
                    replaceFallbackNote = fallback
                case .failed(let message):
                    return StepOutcome(status: .failed(message))
                }
            }
            let start = clock.now
            let text = step.text ?? ""
            // ロケータ有り type(下記 case "type")と同じ規則: "\n" を含むときだけ
            // typeDriver(XCUITest)へ回し、iOS の Return キー既定挙動に揃える(理由は同 case のコメント参照)。
            if text.contains("\n"), let td = typeDriver {
                try await td.type(ref: nil, text: text)
            } else {
                try await driver.type(ref: nil, text: text)
            }
            phase.actionMs += Self.ms(clock.now - start)
            return StepOutcome(status: .passed, driverFallback: replaceFallbackNote)
        }

        // pressEnter もロケータを持たない(フォーカス中の入力欄への Enter 押下)ので、type(ref: nil)
        // と同じ理由でロケータ解決を挟まない。409(inapp が Compose 以外の入力欄/フォーカス無しで
        // 出す。InAppBridge.handlePressEnter 参照)は type のロケータ版と同じ形で
        // typeDriver(xcuitest)へフォールバックする
        if action == "pressEnter" {
            let focusNote = try await awaitFocusBeforePressEnter(phase: &phase)
            let start = clock.now
            do {
                try await driver.pressEnter()
            } catch {
                guard case DriverError.badResponse(let code, _) = error, code == 409,
                      let td = typeDriver else { throw error }
                try await td.pressEnter()
                phase.actionMs += Self.ms(clock.now - start)
                return StepOutcome(status: .passed,
                                   driverFallback: Self.joinNotes(focusNote, "fell back to XCUITest"))
            }
            phase.actionMs += Self.ms(clock.now - start)
            return StepOutcome(status: .passed, driverFallback: focusNote)
        }

        // hideKeyboard もロケータを持たない(フォーカス中の入力欄からファーストレスポンダを外す)。
        // pressEnter と同じ理由でロケータ解決を挟まないが、フォールバック判定は 409 ではなく
        // isEngineIncapable(501/ルート不明404): このエンジンでは原理的に非対応、という意味だから
        // (409 は「今フォーカス無し」等の一時的競合で、pressEnter/type の 409 とは事情が違う)
        if action == "hideKeyboard" {
            let start = clock.now
            do {
                try await driver.hideKeyboard()
            } catch {
                guard DriverError.isEngineIncapable(error), let td = typeDriver else { throw error }
                try await td.hideKeyboard()
                phase.actionMs += Self.ms(clock.now - start)
                return StepOutcome(status: .passed, driverFallback: "fell back to XCUITest")
            }
            phase.actionMs += Self.ms(clock.now - start)
            return StepOutcome(status: .passed)
        }

        // clearInput もロケータ無しならフォーカス中欄へ作用する(type(ref: nil) と同じくロケータ解決を
        // 挟まない)。対象なし(409)またはこのエンジンでは未対応(isEngineIncapable)なら
        // typeDriver(xcuitest)へフォールバックする
        if action == "clearInput", step.locator == nil, step.fallbacks?.isEmpty ?? true {
            switch try await performClearInputFocused(phase: &phase) {
            case .cleared(let fallback):
                return StepOutcome(status: .passed, driverFallback: fallback)
            case .failed(let message):
                return StepOutcome(status: .failed(message))
            }
        }

        // `tap(scroll:)` 等の内蔵スクロール探索。**別ステップにしない**のは
        // 利用者が書いたのは1コマンドだから(記録に scrollTo 行が増えると、書いていない行が
        // 現れ、しかもソース行を持たないためジャンプも修正提案の照合もできない)。
        // 探索は runScrollSearch が静止まで面倒を見るので、以降は通常の解決へ進んでよい
        // 探索がスワイプを撃ったか。直後の解決 snapshot も**キャッシュを捨てて**撮るために立てる
        // (探索が最後に見た木は新しいのに、ここで古い木を掴むと**見つけたはずの要素が消えて**
        // `cannot resolve the locator` になる。2026-08-03 に CMP/Android で実測した失敗そのもの)
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
                // 実測(2026-08-07): 同名 `#recycler_view` が4つある画面で先頭の横チップ行を
                // 掴んだまま「element not found」としか言わず、曖昧だったことが伝わらなかった
                let why = pendingScrollFrameNote.map { " (\($0))" } ?? ""
                return StepOutcome(status: .failed(Self.scrollNotFoundMessage(step, result) + why))
            }
            searchSwiped = true
        }

        // ロケータ解決の再試行(ファイル冒頭のセマンティクス参照: 最大3回、計700ms)
        var start = clock.now
        var snapshot = try await freshSnapshot(.afterSearch(swiped: searchSwiped))
        phase.snapshotMs += Self.ms(clock.now - start)
        // 宣言された割り込み(アプリ内メッセージ等)が出ていれば先に閉じる。**解決を試みる前**に
        // 行う: 覆われているだけで要素自体は解決できてしまい、タップが吸われる形があるため
        // (層3 の coveringHint と同じ事象。あちらは診断、こちらは宣言があるときの自動処理)
        try await dismissInterruption(in: &snapshot, phase: &phase)
        var resolved = Self.resolve(step: step, in: snapshot)
        // **探索の直後は容器の外に並ぶ ghost 行を掴むことがある**(Compose iOS は容器の外にも
        // 子を報告する。docs/verification.md「Compose の探索直後タップ」)。掴んだままタップすると
        // 容器の外を撃って**黙って飲まれる**(値が変わらないので、後段の検証だけが落ちて原因が遠い)。
        // 探索ループの中では同じ判定で「もう1回送る」をしているが、**ループを抜けた後の再解決には
        // 効いていなかった**のが残存フレークの正体(2026-08-04)。
        // 判定は `isOutsideContainer`(容器と**交差しない** = 完全に外)。
        //
        // **またぎ(縁をまたぐ要素)まで対象に広げてはいけない**(2026-08-05 に試して撤回)。
        // 「掴み直し+送り直し」の対象を `isClippedByViewport`(= 完全に外もまたぎも拾う)へ
        // 統一したところ、S0110 の失敗が **2/10 → 5/10 に悪化**した。失敗はいずれも救済が発火し、
        // tap が 4.0s → 7.2〜8.2s に伸びたうえで**「対象があの後 9〜14pt 動いた」**で落ちている
        // = 縁で救済スワイプを撃つと、わずかに動いた先の座標でタップすることになり自傷する。
        // **またぎは探索ループ側の見切れ判定に任せる**(あちらは掴む前に送るので座標が古くならない)
        // **このステップが探索したかは条件にしない**(2026-08-06 に外した): ghost は
        // 「直前の探索」ではなく**アプリがスクロールしていること**の帰結で、木にはその後も
        // 残り続ける。`scrollTo` と `tap` を別ステップで書く(利用者の自然な書き方)と
        // searchSwiped が false になり、**防御がまるごと素通り**していた —— 実測では
        // `tap` が容器の外を撃って画面が何も変わらず、後段の検証だけが落ちていた
        func grabbedGhost(_ candidate: (ElementInfo, FlowLocator?)?) -> Bool {
            guard let element = candidate?.0, step.containerInference ?? true
            else { return false }
            return Self.isOutsideContainer(element, in: snapshot.elements)
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
                        snapshot = try await freshSnapshot(.afterSearch(swiped: searchSwiped))
                        phase.snapshotMs += Self.ms(clock.now - start)
                        let previous = resolved
                        resolved = Self.resolve(step: step, in: snapshot)
                        if previous != nil { ghostRetries += 1 }
                    }
                }
            } else {
                var backoff = PollBackoff()
                for attempt in 0..<3 {
                    start = clock.now
                    try await Task.sleep(for: backoff.nextDelay())
                    phase.waitMs += Self.ms(clock.now - start)
                    // **撮り直しだけでは戻らないことがある**(2026-08-04 実測: 3回撮り直しても
                    // 容器の外に報告されたまま = タップが飲まれて `selected=-`)。
                    // 探索ループと同じく**もう1回送って**容器の中へ入れる。1周目は撮り直しだけ
                    // (木の遅れなら送らずに直る)、2周目以降だけ送る = 正常系のコストを増やさない
                    // **指の向きを持たないステップでも救済に入る**(2026-08-06): 素の `tap` は
                    // direction を持たないため、旧実装は ghost を検出しておきながら
                    // **1本も送らずにそのままタップ**していた。ghost は容器の外に居ることが
                    // 分かっているので、戻す向きは `recoveryJump` / `recoveryDirection` が
                    // 幾何から決められる(既定の finger は「内側に居るとき」しか使われない)
                    if attempt > 0, grabbedGhost(resolved),
                       let element = resolved?.0 {
                        let finger = FTSwipeDirection(rawValue: step.direction ?? "") ?? .up
                        let container = Self.clippingContainer(
                            of: element, in: snapshot.elements,
                            inferring: step.containerInference ?? true)
                        // **距離を測ってその分だけ動かす**(recoveryJump 参照)。全画面スワイプだと
                        // 100pt のずれに対して1ページ動いてしまい、**行き過ぎて往復する**。
                        // 容器が分かるときだけ使える手なので、駄目なら従来のスワイプへ落ちる
                        if let container,
                           let jump = Self.recoveryJump(for: element, container: container),
                           await hintDrag(jump: jump, container: container,
                                          viewport: snapshot.screen, phase: &phase) {
                            ghostSwipes += 1
                            _ = try await settledSignature(phase: &phase)
                            start = clock.now
                            snapshot = try await freshSnapshot(.afterSearch(swiped: searchSwiped))
                            phase.snapshotMs += Self.ms(clock.now - start)
                            let previous = resolved
                            resolved = Self.resolve(step: step, in: snapshot)
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
                    snapshot = try await freshSnapshot(.afterSearch(swiped: searchSwiped))
                    phase.snapshotMs += Self.ms(clock.now - start)
                    let previous = resolved
                    resolved = Self.resolve(step: step, in: snapshot)
                    if previous != nil { ghostRetries += 1 }
                    if resolved != nil, !grabbedGhost(resolved) { break }
                }
            }
        }

        // driver フォールバック(ハイブリッド): primary(in-app)で解決できない、または primary が
        // label 部分一致(substring)でしか解決できていないとき、fallbackDriver(XCUITest=システム UI)
        // の snapshot でも解決を試す。act は解決した driver で行う。
        // substring 誤解決の偽陽性(in-app の label がシステム UI label の部分文字列で contains 命中し、
        // 本来当てたいシステム UI 要素へフォールバックされない)を、fallback の exact 一致で上書きする。
        // primary が exact のときは fallback を照会しない(従来どおりコスト増なし)。
        // **select は照会しない**: 掴むだけでデバイス操作が無く、掴めないことが答えになり得る
        // コマンドなので、システム UI 側を探す意味がない。実害もある — fb.snapshot() は
        // springboard セッションを張り、**同一デバイス1セッション制約でアプリ attach を潰す**。
        // WebView(domInterop)では直後の type が入らなくなった(2026-08-04 実測。
        // `select("wv_result=*")` はワイルドカードが quality=substring になり毎回ここを踏む)
        // 掴み直しの結果を**必ず注記に残す**: 救えたなら「なぜ遅かったか」の説明になり、
        // 救えなかったなら「タップが飲まれた可能性」を失敗調査の起点にできる(黙るのが最悪)
        // **救済で送った直後は、容器が次の1タッチを吸う**(探索終端と同じ既知の形。
        // docs/verification.md「スクロールした直後のタップ」)。探索終端では空打ちドラッグで
        // 肩代わりしているが、**救済経路には無かった** —— 実測(8並列 40 サンプル):
        // 救済が走った 18 件のうち **4 件が失敗**、走らなかった 22 件は **0 件**(p≈0.03)。
        // しかも失敗時の対象は容器のど真ん中(y=519〜534 / 容器 230..692)で座標は正しい。
        // 探索終端と**同じ順序**で肩代わり → 静止 → 掴み直しを行う
        if ghostSwipes > 0, shouldEmptyDrag, let target = resolved?.0 {
            let x = target.frame.centerX
            let y = min(target.frame.centerY,
                        snapshot.screen.y + snapshot.screen.height - Self.bottomUncoveredBand - 1)
            if Self.emptyDragIsSafe(x: x, y: y, of: target, in: snapshot.elements,
                                    screen: snapshot.screen),
               let toX = Self.emptyDragEndX(of: target, from: x, screen: snapshot.screen) {
                await emptyDrag(x: x, y: y, toX: toX)
                let settled = try await settledSignature(phase: &phase)
                snapshot = settled.snapshot
                // 空打ちで木が入れ替わるので ref を取り直す(古い ref は別要素を指す)
                if let refreshed = Self.resolve(step: step, in: snapshot) { resolved = refreshed }
            }
        }

        var straddleNote: String?
        var ghostNote: String?
        if grabbedGhost(resolved) {
            ghostNote = "the element is still reported outside its scroll container"
                + " (\(ghostRetries) re-resolve(s), \(ghostSwipes) extra swipe(s));"
                + " the interaction may be swallowed"
        } else if ghostRetries > 0 {
            ghostNote = "re-resolved \(ghostRetries) time(s)"
                + (ghostSwipes > 0 ? " with \(ghostSwipes) extra swipe(s)" : "")
                + " — the element was first reported outside its scroll container"
        }

        var actingDriver: AppDriver = driver
        if action != "select", let fb = fallbackDriver {
            let primaryQuality = resolved == nil ? nil : Self.resolveDetailed(step: step, in: snapshot)?.quality
            if resolved == nil || primaryQuality == .substring {
                start = clock.now
                let fsnap = try await fb.snapshot()
                phase.snapshotMs += Self.ms(clock.now - start)
                if let r = Self.resolveDetailed(step: step, in: fsnap),
                   resolved == nil || r.quality == .exact {
                    resolved = (r.element, r.usedFallback)
                    snapshot = fsnap
                    actingDriver = fb
                }
            }
        }

        var status: StepResult.Status = .passed
        var healedStep: FlowStep?
        var healedByCache = false
        // ロケータのフォールバック(.passedViaFallback)とは別物。ドライバ切替の注記のみで、
        // FTRuntime の修正提案(セレクタ更新)は誘発しない
        var driverFallback: String?
        var element: ElementInfo

        if let (found, usedFallback) = resolved {
            element = found
            if let fallback = usedFallback { status = .passedViaFallback(fallback) }
        } else if let (found, locator) = matchCached(cached, in: snapshot) {
            // ヒールキャッシュ命中: FM なしで決定的に解決(healed 扱いで記録し、提案を出し続ける)
            element = found
            var healed = step
            healed.locator = locator
            healed.fallbacks = cached.count > 1 ? cached.filter { $0 != locator } : nil
            healedStep = healed
            healedByCache = true
            status = .healed(locator)
        } else if action == "select" {
            // **select だけは掴めなくても失敗させない**(空要素を返して呼び出し側に .isEmpty で
            // 分岐させる契約)。自己修復の対象にもしない — 掴めないことが答えになり得るコマンドで
            // 別要素へ誤リダイレクトすると、空のはずが値を持って返る
            return StepOutcome(status: .skipped(Self.selectNotFoundReason))
        } else if healingEnabled, let delegate,
                  let proposal = await delegate.healLocator(step: step, snapshot: snapshot),
                  proposal.confidence == "high" {
            // 自己修復: 新しいロケータ連鎖に置き換えたステップを返す(永続化は呼び出し側 →
            // `ftester api apply-heal` が利用者の .swift ソースへ直接書き込む経路がある)。
            // **書けるセレクタは `SelectorNaming` にだけ決めさせる**(2026-08-15。旧実装
            // `FlowLocatorBuilder.chain` は一意性を見ずに id/label をそのまま採っていたため、
            // 同じ id を複数持つ画面では書いたセレクタが別要素に解決していた)。
            element = proposal.element
            // **`graded` が nil = この画面でその要素を一意に指せる書き方が無い**。
            // **操作は続け、修復だけ成立させない**(2026-08-15)。掴んだ要素は手元にあるので
            // 叩くこと自体は正しく、ここで失敗させるとシナリオ全体が中断する = 書き戻せない
            // という理由だけで緑の run を赤にすることになる。塞ぎたい欠陥は「壊れたセレクタが
            // 利用者の資産へ書かれる」ことなので、`healedStep` を立てない(= 修正提案も
            // ヒールキャッシュも作らない)だけで足りる。**黙らない** —— 毎回 FM を呼び直す
            // 状態が続くので、率が上がったら id/ラベルの一意性を疑う手掛かりとして数える
            if let graded = SelectorNaming(snapshot).graded(for: proposal.element, in: snapshot) {
                // 得たセレクタは `FTSelector.parse` で往復させ、綴りと意味の唯一の写像を通す
                let parsed = FTSelector.parse(graded.selector)
                var healed = step
                healed.locator = parsed.primary
                healed.fallbacks = parsed.fallbacks.isEmpty ? nil : parsed.fallbacks
                // **indexed(位置依存)は書き込む前に必ず言う**(Durability.caution が文言を持つ)
                // —— 兄弟の増減で別要素を指すようになるセレクタを、黙って利用者のソースへ書かない
                healed.note = (step.note.map { $0 + " / " } ?? "") + "self-healed: \(proposal.rationale)"
                    + graded.durability.caution
                healedStep = healed
                status = .healed(parsed.primary)
            } else {
                var notes: [String] = []
                note(.healUnwritable, into: &notes)
                driverFallback = Self.joinNotes(driverFallback, notes.joined(separator: " / "))
            }
        } else {
            // 惜しい候補を添える。これが無いと直すために snapshot を取り直す往復が必要になる
            // (レポート側の全要素一覧は ScenarioReportWriter が別途出す)
            let hint = Self.candidateHint(for: step, in: snapshot)
            return StepOutcome(status: .failed(
                "cannot resolve the locator: \(step.locatorSummary)" + (hint.map { ". \($0)" } ?? "")
                    + Self.truncationHint(snapshot)
                    + Self.webViewPathHint(snapshot)))
        }
        resolvedElementThisStep = element

        // **容器の縁にまたがった要素はそのまま撃たない**(2026-08-06)。見えている部分を撃っても、
        // Compose は focus 時に bringIntoView で内容を動かすため、離すまでに隣の行が指の下へ来る
        // (Emulator で約 50%・実測 135〜179px ずれて隣の行が反応した)。**容器の中へ寄せてから撃つ**。
        //
        // 2026-08-05 に撤回した「またぎも掴み直しの対象へ広げる」との違いは**送り方**:
        // あちらは全画面スワイプで行き過ぎて自傷した(S0110 が 2/10 → 5/10)。ここは
        // `straddleJump`(またぎ解消に必要な最小量。40% 位置への寄せは観測対象まで流す —
        // 定義部の 2026-08-08 実害参照)+ `slowDrag`(フリングを出さない)なので
        // 行き過ぎない。**1回だけ**(収束しなければ従来どおり見えている部分を撃つ)
        if Self.interactsByTouch(action), step.containerInference ?? true,
           let container = Self.clippingContainer(of: element, in: snapshot.elements,
                                                  inferring: true),
           ScrollGeometry.intersection(element.frame, container) != nil,
           Self.isClippedByViewport(element, screen: container),
           let jump = Self.straddleJump(for: element, container: container),
           await slowDrag(jump: jump, container: container, phase: &phase) {
            _ = try await settledSignature(phase: &phase)
            let refreshed = try await freshSnapshot(.afterOwnMove)
            if let (moved, _) = Self.resolve(step: step, in: refreshed) {
                snapshot = refreshed
                element = moved
                resolvedElementThisStep = element
                straddleNote = "nudged the element fully inside its container before touching it"
            }
        }

        switch action {
        case "select":
            // 掴むだけでデバイス操作はしない。ただし**可視性は exist と同じ規律で確かめる**
            // (覆われた要素を掴んで値を読むと、画面に見えていない値でテストが通る)。
            // `requireVisible: false` で外せる(step.occlusionGuard が false のとき素通り)
            if try await occlusionFlip(
                element: element, expectedText: element.label ?? step.locator?.label ?? "",
                elements: snapshot.elements, screen: snapshot.screen,
                looseMatch: false, perStepGuard: step.occlusionGuard,
                expectedIsUserText: step.locator?.label != nil, phase: &phase) != nil {
                // **見えないときは失敗させず空要素を返す**(呼び出し側が `.text == nil` で分岐できる)。
                // exist(検証)と違い select は「掴む」操作なので、見えない事実は値で表す
                resolvedElementThisStep = nil
                return StepOutcome(status: .passed,
                                   driverFallback: "not visible: returned an empty element")
            }
        case "tap":
            // 飲まれたタップの証跡(LastInteraction 参照)。**操作の前**に採る = 比較の基準は
            // 「この操作を撃つ直前の画面」でなければ意味がない
            recordInteraction(step: step, element: element, in: snapshot)
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
            // keyboard/disabled が2回付く(2026-08-08 に発覚したバグ)ので、この2つだけをここで確定する。
            // **申告 keyboardFrame はキー面だけ**なので木の chrome で広げ、chrome 自身とその
            // 部分木(地球儀キー等)は除外して渡す(KeyboardOcclusion の doc。MCP 側も同じ型で揃える)
            let tapKeyboardOcclusion = KeyboardOcclusion.resolve(
                reported: snapshot.keyboardFrame, in: snapshot.elements)
            driverFallback = Self.joinNotes(driverFallback,
                tapKeyboardOcclusion.advisory(for: element),
                TapTargetGeometry.disabledAdvisory(for: element))
            // **長押しは tap の引数**(Shirates 準拠。`tap(sel, holdSeconds:)`)。0 より大きいときだけ
            // ブリッジの /press へ回す。in-app は座標ジェスチャを持たない(501)ので XCUITest へ
            // フォールバックする経路も長押し側だけが必要
            let hold = step.duration ?? FlowStep.defaultTapHoldSeconds
            if hold > 0 {
                // 長押しは press(ref:) = ブリッジが frame の中心へ解決するので、座標に依る
                // チェーン(画面外・遮蔽・中身外し等)が言える。**keyboard/disabled はここでは
                // 足さない**(上ですでに1回付けている。ここで足すと同文が2回付く)
                driverFallback = Self.joinNotes(driverFallback,
                    TapTargetGeometry.occlusionAdvisory(
                        for: element, in: snapshot.elements, screen: snapshot.screen))
                if typeDriverGestures.contains("press") || gestureFallbackLatched, let td = typeDriver,
                   try await pressViaTypeDriver(td, step: step, phase: &phase) {
                    return StepOutcome(status: .passed, healedStep: healedStep,
                                       healedByCache: healedByCache,
                                       driverFallback: Self.joinNotes(driverFallback,
                                                                      "fell back to XCUITest"))
                }
                do {
                    start = clock.now
                    try await actingDriver.press(ref: element.ref, duration: hold)
                    phase.actionMs += Self.ms(clock.now - start)
                } catch {
                    // 「このエンジンでは不可」(501 / ルート不明 404)だけ XCUITest へ回す。
                    // 409 を含めない理由は DriverError.isEngineIncapable 参照
                    guard DriverError.isEngineIncapable(error), let td = typeDriver else { throw error }
                    guard try await pressViaTypeDriver(td, step: step, phase: &phase) else { throw error }
                    gestureFallbackLatched = true
                    driverFallback = Self.joinNotes(driverFallback, "fell back to XCUITest")
                }
                break
            }
            start = clock.now
            // **中心が容器の外に落ちる要素だけ、見えている部分の中心を座標で撃つ**
            // (visibleTapRect 参照)。ref で撃つとブリッジが frame の中心へ解決するので、
            // 壊れた frame ではそのまま容器の外を叩いて黙って飲まれる
            if let visible = Self.visibleTapRect(for: element, in: snapshot.elements,
                                                inferring: step.containerInference ?? true,
                                                scale: driver.pointScale) {
                try await actingDriver.tap(x: visible.centerX, y: visible.centerY)
                driverFallback = Self.joinNotes(driverFallback,
                    "tapped the visible part (the reported frame's centre falls outside its container)")
            } else {
                // 寄せずに frame の中心を撃つ = 座標に依るチェーンが言える経路。
                // **keyboard/disabled はここでは足さない**(上ですでに1回付けている。
                // ここで足すと同文が2回付く)
                driverFallback = Self.joinNotes(driverFallback,
                    TapTargetGeometry.occlusionAdvisory(
                        for: element, in: snapshot.elements, screen: snapshot.screen))
                try await actingDriver.tap(ref: element.ref)
            }
            phase.actionMs += Self.ms(clock.now - start)
            // ドライバが「無言 no-op になり得る経路を通った」と申告した注記(例: InAppBridge の
            // activate 不発→合成タッチ)。失敗ではないので driverFallback に載せて可視化するだけ。
            // **代入ではなく合流**: 上書きすると、直前に積んだ注記(無効な要素・中身外し)が
            // 消える —— しかも消えるのは activate 不発のような**まさに飲まれた場面**で、
            // 両方が要るときに片方を失っていた(2026-08-07 のレビューで発覚)
            driverFallback = Self.joinNotes(driverFallback, actingDriver.lastActionNote)
        case "type":
            // "\n" を含む入力だけ typeDriver(XCUITest)を優先する: typeText は改行を Return
            // キー押下として発火し iOS 既定の挙動と揃うが、in-app の insertText は改行の解釈が
            // フレームワーク任せで揃わない。"\n" を含まない入力は両経路で結果が同じなので、この
            // 振り分けはエンジン間の観測可能な挙動差を生まない。
            let text = step.text ?? ""
            // **replace は3経路(typeDriver優先/通常/409フォールバック)より前に1回だけクリアする**。
            // 空にできていないのに書き足すと検証対象と違う値になるので、clear が失敗したら
            // type を撃たずこのステップを失敗させる
            var replaceFallbackNote: String?
            if step.replace == true {
                switch try await performClearInput(element: element, step: step,
                                                   actingDriver: actingDriver, phase: &phase) {
                case .cleared(let fallback):
                    replaceFallbackNote = fallback
                case .failed(let message):
                    return StepOutcome(status: .failed(message))
                }
            }
            // **既存値の連結警告**(MCP の同名警告と揃える)。追加のデバイス往復はしない —
            // 撃つ前に解決済みの `element.value` だけを見る。secureTextField は値を伏せる
            // (マスク欄の実値をログへ出さない)。**replace は clear 済みなので空として扱う**
            let priorValue = TypeReadback.normalizedValue(of: element)
            let existingValue = step.replace == true ? "" : priorValue
            let existingValueNote: String? = step.replace == true
                ? (priorValue.isEmpty ? nil : "replaced the field's prior content")
                : (priorValue.isEmpty ? nil
                    : element.type == "secureTextField"
                        ? "the field already holds a value; type appends, so the result will not"
                            + " simply be what you typed. Call clearInput first if you meant to replace it"
                        // **連結後の値を予告しない**(2026-08-13。MCP 側の同名警告と同じ理由)——
                        // 空欄のヒント文字列が `value` に載り `placeholder` が来ないアプリ
                        // (Google メッセージの宛先欄が witness)では前の値が実在の内容ではなく、
                        // 予告は外れる。**ここでは読み返さない**(型ステップごとの往復を増やさない)
                        // ので、観測していない値は名乗らず「撃つ前に入っていた値」だけを言う
                        : "the field already held \"\(SnapshotRenderer.truncate(priorValue, 30))\";"
                            + " type appends, so the result will not simply be what you typed."
                            + " Call clearInput first if you meant to replace it")
            // **入力欄でないものへ打とうとしていないか**(2026-08-14。TypeReadback の doc に実測)。
            // 検証は両側とも空になる経路なので、せめて内側の欄を名指しして知らせる
            let nonInputNote = TapTargetGeometry.nonInputTypeTargetNote(element, in: snapshot.elements)
            if let td = typeDriver, preferTypeDriver || text.contains("\n"),
               try await typeViaTypeDriver(td, step: step, phase: &phase) {
                return StepOutcome(status: .passed, healedStep: healedStep, healedByCache: healedByCache,
                                   driverFallback: Self.joinNotes(replaceFallbackNote, existingValueNote,
                                                                  nonInputNote))
            }
            do {
                start = clock.now
                try await actingDriver.type(ref: element.ref, text: step.text ?? "")
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
                // フォーカス有無に依存する一時的競合なので、press/swipe と違い 501 化しない。
                guard case DriverError.badResponse(let code, _) = error, code == 409,
                      let td = typeDriver else { throw error }
                guard try await typeViaTypeDriver(td, step: step, phase: &phase) else { throw error }
                // セレクタは正しくドライバが変わっただけ = .passedViaFallback(ロケータ用)は立てない
                // (typeDriver = xcuitest が自前で読み返し済みなので、ここでも読み返さない)
                driverFallback = Self.joinNotes("fell back to XCUITest", replaceFallbackNote,
                                                existingValueNote, nonInputNote)
            }
        case "clearInput":
            if let td = typeDriver, preferTypeDriver,
               try await clearViaTypeDriver(td, step: step, phase: &phase) {
                return StepOutcome(status: .passed, healedStep: healedStep, healedByCache: healedByCache)
            }
            switch try await performClearInput(element: element, step: step,
                                               actingDriver: actingDriver, phase: &phase) {
            case .cleared(let fallback):
                driverFallback = fallback
            case .failed(let message):
                return StepOutcome(status: .failed(message))
            }
        case "pinchOut", "pinchIn", "doubleTap", "swipeBy":
            // 対象を指定した版。要素の frame(Android のピンチ中心・swipeBy の基準領域)と
            // identifier(XCUITest のピンチ対象)の両方を渡す(理由は BridgeDTO.PinchRequest)
            // **doubleTap も指で触る操作**なので、tap と同じ注記を載せる
            // (MCP の ft_double_tap も同じ内容を出す。片方だけ黙ると判断が食い違う)。
            // pinch / swipeBy は「要素を掴んで動かす」形で、無効でも意味があるので対象外
            let gestureAdvisory = action == "doubleTap"
                ? TapTargetGeometry.advisory(for: element, in: snapshot.elements,
                                             screen: snapshot.screen,
                                             keyboardOcclusion: KeyboardOcclusion.resolve(
                                                reported: snapshot.keyboardFrame, in: snapshot.elements))
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
            guard let (endElement, _) = Self.resolve(step: endStep, in: snapshot) else {
                let hint = Self.candidateHint(for: endStep, in: snapshot)
                return StepOutcome(status: .failed(
                    "cannot resolve the end locator: \(endStep.locatorSummary)"
                        + (hint.map { ". \($0)" } ?? "")))
            }
            let swipeDuration = step.duration ?? FlowStep.defaultSwipeDurationSeconds
            do {
                start = clock.now
                try await actingDriver.drag(fromX: element.frame.centerX, fromY: element.frame.centerY,
                                            toX: endElement.frame.centerX, toY: endElement.frame.centerY,
                                            pressSeconds: 0.05, durationSeconds: swipeDuration)
                phase.actionMs += Self.ms(clock.now - start)
            } catch {
                // in-app エンジンは drag を一切実装しない(501)ため、hybrid では typeDriver=XCUITest
                // で始点・終点を取り直す(ref はブリッジごとに別名前空間)
                guard DriverError.isEngineIncapable(error), let td = typeDriver else { throw error }
                guard try await dragViaTypeDriver(td, step: step, endStep: endStep,
                                                  durationSeconds: swipeDuration, phase: &phase) else {
                    throw error
                }
                driverFallback = "fell back to XCUITest"
            }
        default:
            return StepOutcome(status: .skipped("unknown action: \(action)"))
        }
        return StepOutcome(status: status, healedStep: healedStep, healedByCache: healedByCache,
                           driverFallback: Self.joinNotes(Self.joinNotes(driverFallback, ghostNote),
                                                          straddleNote))
    }

    /// pressEnter 直前の焦点待ち(MCP の awaitFocus と同じレース対策: タップ直後、対象欄へ
    /// フォーカスが立つ前の Enter は前の欄へ飛ぶ)。pressEnter はロケータを持たないので特定の
    /// 要素は狙わず、**木のどこかが focused を申告する / キーボードが出ている**のどちらかを
    /// 合図として待つ。値は FTCore.FocusWait(MCP と共有)。
    ///
    /// **keyboardShown はプラットフォーム分岐せず毎回確かめる**: xcuitest/in-app は
    /// snapshot のたびに申告するが、Android は captureKeyboardStateOnNextSnapshot() を
    /// 撮る前に立てないと申告されない(executeAssertKeyboardShown と同じ制約)ので、
    /// 毎周回立て直す(iOS では no-op)。focused だけでは Compose iOS(in-app は
    /// UIResponder でない a11y 要素の focused を申告しない)を待ち続けてしまうので、
    /// keyboardShown を第二の合図として持つ。
    ///
    /// 合図が出ないまま waitSeconds 経過したら拒否せず注記を返す(呼び出し側で driverFallback へ合流)
    private func awaitFocusBeforePressEnter(phase: inout PhaseAccumulator) async throws -> String? {
        let clock = ContinuousClock()
        let deadline = Date().addingTimeInterval(FocusWait.waitSeconds)
        while true {
            driver.captureKeyboardStateOnNextSnapshot()
            let start = clock.now
            let snapshot = try await driver.snapshot(bypassingCache: driver.supportsCacheBypass)
            phase.snapshotMs += Self.ms(clock.now - start)
            if snapshot.elements.contains(where: { $0.focused == true })
                || snapshot.keyboardShown == true { return nil }
            guard Date() < deadline else {
                return "no field ever took focus within \(FocusWait.waitSeconds)s before pressEnter"
                    + " — the Enter may have gone to whichever field still had it"
            }
            let waitStart = clock.now
            try? await Task.sleep(for: .seconds(FocusWait.pollSeconds))
            phase.waitMs += Self.ms(clock.now - waitStart)
        }
    }

    /// typeDriver で type を試みる。ref はブリッジごとに別名前空間なので typeDriver 側 snapshot で
    /// 取り直す。解決できなければ false(呼び出し側で通常経路[inapp]へフォールバック/再スロー)。
    private func typeViaTypeDriver(_ td: AppDriver, step: FlowStep,
                                   phase: inout PhaseAccumulator) async throws -> Bool {
        let clock = ContinuousClock()
        var start = clock.now
        let snapshot = try await td.snapshot()
        phase.snapshotMs += Self.ms(clock.now - start)
        guard let resolved = Self.resolveDetailed(step: step, in: snapshot) else { return false }
        start = clock.now
        try await td.type(ref: resolved.element.ref, text: step.text ?? "")
        phase.actionMs += Self.ms(clock.now - start)
        return true
    }

    /// in-app 経由の type 読み返し(AppDriver.verifiesTypedText == false のときだけ呼ばれる)。
    /// BridgeRouter.handleType/awaitCommit(Runner ターゲット。TypeReadback 以外を import できず
    /// 共有できないので独立実装。値は同期: 8s/4周/安定1.5s)と同じ規律 —— 期待値どおりになるまで
    /// 待ち、前方一致で止まっていれば追送、超過していれば削除して全文を打ち直す。
    /// expected は**撃つ前**の値から呼び出し側が組む(読み直した値から作り直すとマスク欄の
    /// 伏せ字を書き込む)。戻り値: nil = 検証済み(一致・検証不能とも受理)/ 非nil = 失敗理由
    /// (値そのものは含めない。パスワード欄も通る経路)
    private func verifyTypedText(_ driver: AppDriver, element: ElementInfo, expected: String,
                                 typedOnly: String,
                                 phase: inout PhaseAccumulator) async throws -> String? {
        let clock = ContinuousClock()
        let deadline = Date().addingTimeInterval(Self.typeVerifyBudgetSeconds)
        var rounds = 0
        var stagnantRounds = 0
        var previous: String?
        // 不可視文字を正規化する(2026-08-15): MCP の replaceVerificationNote/appendVerificationNote
        // と同じ規律 —— これが無いと、実データが混入させるゼロ幅文字(Flow.swift 参照)だけで
        // 実質同じ文字列が不一致と判定され、8秒待った末にシナリオごと失敗する。TypeReadback.swift は
        // ブリッジ共有ファイルで編集不可なので、正規化は呼び出し側(ここ・readbackTarget・
        // awaitTypeCommit)に置く。expected.count は正規化後を使う —— 不可視文字は利用者の目に
        // 映らないので、見えている文字数で失敗を語るほうが親切
        let expected = FlowMatchMode.normalizeInvisibleCharacters(expected)
        let typedOnly = FlowMatchMode.normalizeInvisibleCharacters(typedOnly)

        while true {
            rounds += 1
            guard let actual = try await awaitTypeCommit(driver, element: element, expected: expected,
                                                          typedOnly: typedOnly,
                                                          deadline: deadline, phase: &phase) else {
                return nil   // 読めない/曖昧 = 検証不能なので受理する(TypeReadback.value 参照)
            }
            let target = Self.readbackTarget(expected: expected, typedOnly: typedOnly, actual: actual)
            switch TypeReadback.plan(expected: target, actual: actual) {
            case .done, .unverifiable:
                return nil
            case .resend(let missing):
                // target は正規化済み(readbackTarget)なので missing も正規化済み = 不可視文字を
                // 落とした形。**原文の不可視文字は再現できない**(expected は既存値+本文の連結で、
                // どちらの由来かここでは分からない)が、不可視文字は表示に現れないので、
                // 見える文字を送り損ねるより実害が小さい
                let start = clock.now
                try await driver.type(ref: element.ref, text: missing)
                phase.actionMs += Self.ms(clock.now - start)
            case .deleteExcess:
                // in-app はバックスペースを送れないので、丸ごとクリアしてから全文を打ち直す
                // (handleClear と同じ 422 系の判断。clearInput のケースの既存実装と同じ API 形)。
                // target は正規化済み(上と同じ理由で受け入れる)
                let start = clock.now
                try await driver.clearInput(ref: element.ref)
                try await driver.type(ref: element.ref, text: target)
                phase.actionMs += Self.ms(clock.now - start)
            }
            stagnantRounds = (actual == previous) ? stagnantRounds + 1 : 0
            previous = actual
            if stagnantRounds >= Self.typeVerifyMaxStagnantRounds || Date() >= deadline {
                return "type reported success but the value did not settle after \(rounds) round(s)"
                    + " of readback (expected \(expected.count) character(s))"
            }
        }
    }

    /// 値が期待値になる/変わらなくなる(stableSeconds)/期限切れ、のいずれかまで snapshot を撮り直して
    /// 読む。awaitCommit(BridgeRouter)と同じ二重終了条件だが、取得手段がスナップショット1枚
    /// (0.3〜0.6s)なのでポーリング間隔は typePollSeconds(0.05s)より粗い typeVerifyPollSeconds を使う。
    /// 戻り値 nil = 読めない/複数候補(検証不能。TypeReadback.value 参照)
    private func awaitTypeCommit(_ driver: AppDriver, element: ElementInfo, expected: String,
                                 typedOnly: String,
                                 deadline: Date, phase: inout PhaseAccumulator) async throws -> String? {
        let clock = ContinuousClock()
        // 正規化(readbackTarget と同じ理由・同じ関数)。呼び出し側(verifyTypedText)は既に
        // 正規化済みを渡すが、ここでも掛け直す(冪等なので害はない) —— これが無いと下の早期終了
        // 条件だけ素通りし、実質一致していても stableSeconds ぶん待たされる
        let expected = FlowMatchMode.normalizeInvisibleCharacters(expected)
        let typedOnly = FlowMatchMode.normalizeInvisibleCharacters(typedOnly)
        func read() async throws -> String? {
            let start = clock.now
            let snap = try await driver.snapshot()
            phase.snapshotMs += Self.ms(clock.now - start)
            return TypeReadback.value(of: element, in: snap.elements)
                .map(FlowMatchMode.normalizeInvisibleCharacters)
        }
        guard var lastValue = try await read() else { return nil }
        var lastChange = Date()
        while true {
            // **撃った文字だけになった形も「着いた」**(下の readbackTarget)。これが無いと
            // ヒントを value に載せる欄では毎回 stableSeconds ぶん待たされる
            if lastValue == expected || lastValue == typedOnly { return lastValue }
            if Date() >= deadline { return lastValue }
            if Date().timeIntervalSince(lastChange) >= Self.typeVerifyStableSeconds { return lastValue }
            let waitStart = clock.now
            try? await Task.sleep(for: .seconds(Self.typeVerifyPollSeconds))
            phase.waitMs += Self.ms(clock.now - waitStart)
            guard let current = try await read() else { return nil }
            if current != lastValue { lastChange = Date(); lastValue = current }
        }
    }

    /// 読み返しが目標にする値(2026-08-13)。**既定は `expected`(撃つ前の値 + 本文)**で、
    /// それが `.unverifiable`(前方一致でも超過でもない = 追送も削除も効かない)のときだけ
    /// 「撃った文字だけ」を目標に採り直す。
    ///
    /// **なぜ要るか**: 空欄のヒント文字列を `value` に載せ `placeholder` を出さないアプリでは
    /// 撃つ前の値が実在の内容ではないので、`expected` が最初から偽になる。すると plan は必ず
    /// `.unverifiable` に落ち、**追送も打ち直しも走らないまま受理される** —— 読み返しという砦が
    /// 丸ごと外れる。
    ///
    /// **この退化は再現していない**(2026-08-13 時点)。値にヒントが載る盤面として確かめられたのは
    /// **Android の E2E-CMP `#field_single`**(value="単一行" / placeholder なし。同じシナリオの
    /// `textIs "#txt_echo_length" == "len=8"` が通るので "単一行hello123" は偽)と
    /// **Google メッセージの宛先欄**の2つで、どちらも `verifiesTypedText == true` の
    /// ドライバなのでこの関数は通らない。iOS の in-app(唯一の `false`)で当たる盤面はまだ無い ——
    /// `#field_single` は iOS では placeholder を**ラベル**として出すので `priorValue` が空になる。
    /// **失敗モードが沈黙(検証を諦めたことを誰にも言わない)なので、witness が無くても塞ぐ**。
    ///
    /// **順序を入れ替えないこと**: `typedOnly` を先に見ると、撃つ前の値と本文が同じ欄
    /// (prior="abc" に "abc" を追記)で**追記が届かなかった失敗**が `.done` に見える。
    /// 採り直しは「今なら諦めていた」場合だけに限る = 既存の検査を弱めない
    static func readbackTarget(expected: String, typedOnly: String, actual: String) -> String {
        // 不可視文字を正規化してから比較する(2026-08-15。MCP の
        // replaceVerificationNote/appendVerificationNote と同じ規律)。self-contained にする
        // (呼び出し側での正規化に依存しない) —— これが無いと、ゼロ幅文字が expected/typedOnly/actual
        // のどれか1つにだけ混じった時点で .unverifiable に落ち、追送も打ち直しも走らず受理される
        let expected = FlowMatchMode.normalizeInvisibleCharacters(expected)
        let typedOnly = FlowMatchMode.normalizeInvisibleCharacters(typedOnly)
        let actual = FlowMatchMode.normalizeInvisibleCharacters(actual)
        guard expected != typedOnly else { return expected }
        guard case .unverifiable = TypeReadback.plan(expected: expected, actual: actual) else {
            return expected
        }
        if case .unverifiable = TypeReadback.plan(expected: typedOnly, actual: actual) {
            return expected
        }
        return typedOnly
    }

    /// 読み返しの打ち切り時間・停滞許容周回数・安定待ち。BridgeRouter.handleType の
    /// typeBudgetSeconds/typeMaxStagnantRounds/typeStableSeconds と値を揃える(Runner は
    /// SPM ターゲットではなく TypeReadback 以外を共有 import できないため定数は独立管理)
    private static let typeVerifyBudgetSeconds: TimeInterval = 8
    private static let typeVerifyMaxStagnantRounds = 4
    private static let typeVerifyStableSeconds: TimeInterval = 1.5
    /// ポーリング間隔。BridgeRouter の typePollSeconds(0.05s)より粗い(取得がスナップショット
    /// 1枚 0.3〜0.6s かかるため、それより細かく刻んでも意味がない)
    private static let typeVerifyPollSeconds: TimeInterval = 0.3

    /// typeDriver で press を試みる。ref はブリッジごとに別名前空間なので typeDriver 側 snapshot で
    /// 取り直す(typeViaTypeDriver と同じ理由)。解決できなければ false(呼び出し側で再スロー)。
    private func pressViaTypeDriver(_ td: AppDriver, step: FlowStep,
                                    phase: inout PhaseAccumulator) async throws -> Bool {
        let clock = ContinuousClock()
        var start = clock.now
        let snapshot = try await td.snapshot()
        phase.snapshotMs += Self.ms(clock.now - start)
        guard let resolved = Self.resolveDetailed(step: step, in: snapshot) else { return false }
        start = clock.now
        try await td.press(ref: resolved.element.ref,
                           duration: step.duration ?? FlowStep.defaultTapHoldSeconds)
        phase.actionMs += Self.ms(clock.now - start)
        return true
    }

    /// clearInput のフォールバック判定: 409(in-app の対象なし/フォーカス無し。type の 409 と同じ
    /// 一時的競合)、422(XCUITest ランナーの同じ事情。**あちらは 409 を使えない** —
    /// SessionRecoveryDriver がセッション消失と断定するため。BridgeRouter.handleClear 参照)、
    /// または isEngineIncapable(このエンジンでは未対応)なら typeDriver へ回してよい
    private static func isClearInputFallback(_ error: Error) -> Bool {
        if DriverError.isEngineIncapable(error) { return true }
        if case DriverError.badResponse(let status, _) = error, status == 409 || status == 422 {
            return true
        }
        return false
    }

    /// typeDriver で clearInput を試みる。ref はブリッジごとに別名前空間なので typeDriver 側 snapshot で
    /// 取り直す(typeViaTypeDriver と同じ理由)。解決できなければ false(呼び出し側で再スロー)。
    private func clearViaTypeDriver(_ td: AppDriver, step: FlowStep,
                                    phase: inout PhaseAccumulator) async throws -> Bool {
        let clock = ContinuousClock()
        var start = clock.now
        let snapshot = try await td.snapshot()
        phase.snapshotMs += Self.ms(clock.now - start)
        guard let resolved = Self.resolveDetailed(step: step, in: snapshot) else { return false }
        start = clock.now
        try await td.clearInput(ref: resolved.element.ref)
        phase.actionMs += Self.ms(clock.now - start)
        return true
    }

    enum ClearOutcome {
        case cleared(driverFallback: String?)
        case failed(String)
    }

    /// clearInput(ref なし = フォーカス中要素)の本体。**ロケータ有り版(performClearInput)とは
    /// 別実装**: 対象を再解決できないので、クリア前に覚えたフォーカス要素を identifier/frame で
    /// 事後突き合わせる(residualClearValue(of:in:) 参照)。ロケータ無し `clearInput()` と
    /// `type(text, replace: true)` の両方がここを通る
    private func performClearInputFocused(phase: inout PhaseAccumulator) async throws -> ClearOutcome {
        let clock = ContinuousClock()
        let snapStart = clock.now
        // **キャッシュを捨てて読む**(理由は valueBeforeClear。ロケータ有りの経路と同じ穴)
        let beforeSnapshot = try await driver.snapshot(bypassingCache: driver.supportsCacheBypass)
        phase.snapshotMs += Self.ms(clock.now - snapStart)
        let focusedBefore = beforeSnapshot.elements.first { $0.focused == true }

        let start = clock.now
        do {
            try await driver.clearInput(ref: nil)
        } catch {
            guard Self.isClearInputFallback(error), let td = typeDriver else { throw error }
            try await td.clearInput(ref: nil)
            phase.actionMs += Self.ms(clock.now - start)
            if let focusedBefore,
               let residual = try await residualClearValue(td, focusedBefore: focusedBefore,
                                                           phase: &phase) {
                return .failed("clearInput reported success but the value remained: \"\(residual)\"")
            }
            return .cleared(driverFallback: "fell back to XCUITest")
        }
        phase.actionMs += Self.ms(clock.now - start)

        if let focusedBefore,
           let residual = try await residualClearValue(driver, focusedBefore: focusedBefore,
                                                       phase: &phase) {
            guard let td = typeDriver else {
                return .failed("clearInput reported success but the value remained: \"\(residual)\"")
            }
            let retryStart = clock.now
            try await td.clearInput(ref: nil)
            phase.actionMs += Self.ms(clock.now - retryStart)
            if let residual2 = try await residualClearValue(td, focusedBefore: focusedBefore,
                                                            phase: &phase) {
                return .failed("clearInput reported success but the value remained: \"\(residual2)\"")
            }
            return .cleared(driverFallback: "fell back to XCUITest")
        }
        return .cleared(driverFallback: nil)
    }

    /// clearInput の本体(driver.clearInput → 事後検証 → typeDriver フォールバック → 再検証)。
    /// **clearInput ケースと type の replace 前処理の両方がここを通る**(どのパスなら検証されるかに
    /// 例外を作らない、という既存の規律を replace 経路にも効かせるため)
    private func performClearInput(element: ElementInfo, step: FlowStep, actingDriver: AppDriver,
                                   phase: inout PhaseAccumulator) async throws -> ClearOutcome {
        let clock = ContinuousClock()
        let before = try await valueBeforeClear(element: element, step: step,
                                                driver: actingDriver, phase: &phase)
        do {
            let start = clock.now
            try await actingDriver.clearInput(ref: element.ref)
            phase.actionMs += Self.ms(clock.now - start)
            // 事後検証: ブリッジが 200 を返しても実際に消えていない(嘘の成功)場合の保険。
            // 同じ driver で snapshot を撮り直し、同じ locator を再解決して value を見る
            if let residual = try await residualClearValue(actingDriver, step: step,
                                                          before: before, phase: &phase) {
                guard let td = typeDriver,
                      try await clearViaTypeDriver(td, step: step, phase: &phase) else {
                    return .failed("clearInput reported success but the value remained: \"\(residual)\"")
                }
                if let residual2 = try await residualClearValue(td, step: step,
                                                               before: before,
                                                               phase: &phase) {
                    return .failed("clearInput reported success but the value remained: \"\(residual2)\"")
                }
                return .cleared(driverFallback: "fell back to XCUITest")
            }
            return .cleared(driverFallback: nil)
        } catch {
            guard Self.isClearInputFallback(error), let td = typeDriver else { throw error }
            guard try await clearViaTypeDriver(td, step: step, phase: &phase) else { throw error }
            // フォールバック経路も同じ事後検証を通す(**どのパスなら検証されるかに例外を作らない**。
            // 規則が無いと将来の変更で無検証の穴が復活する)
            if let residual = try await residualClearValue(td, step: step,
                                                          before: before, phase: &phase) {
                return .failed("clearInput reported success but the value remained: \"\(residual)\"")
            }
            return .cleared(driverFallback: "fell back to XCUITest")
        }
    }

    /// clearInput 事後検証の**最後の1周だけ**キャッシュを捨てるか。
    ///
    /// ポーリングは「撮り直せば新しい値が来る」を前提にしているが、**a11y キャッシュは撮り直しても
    /// 同じ古い値を返す**ので、周回数を増やしてもこの穴からは抜けられない(3周とも同じ古い値を読み、
    /// `after == before` が成立して**誤って「消えていない」と報告する**)。`valueBeforeClear` が
    /// 塞いだのは `before` 側で、こちらは対になる `after` 側。
    ///
    /// **失敗と決まる直前の1周にだけ払う**(既存の `AssertFreshRetry` と同じ規律)。
    /// 通常は消えているので1周目で `nil` を返して終わり、追加費用は発生しない
    private static func bypassOnLastAttempt(attempt: Int, driver: AppDriver) -> Bool {
        attempt == residualClearAttempts - 1 && driver.supportsCacheBypass
    }

    /// clearInput 事後検証のポーリング回数(両経路で共有。`bypassOnLastAttempt` が最終周の判定に使う)
    private static let residualClearAttempts = 3

    /// clearInput 事後検証が使う「クリア前の値」。**撃つ直前にキャッシュを捨てて採り直す**。
    ///
    /// 解決済みの `element.value` をそのまま使うと、Android の a11y キャッシュが古い値を返した
    /// とき `before == after` が成立し、**実際には消えているのに「消えていない」と報告する**。
    /// 2026-08-14 に E2E-CMP/android の S0040 で並列負荷 10 周中 8 周再現:
    /// 空欄の `value` にヒント文字列が載る欄(CMP の `#field_single` は placeholder を送らない)では、
    /// 撃つ前の古い読みが「ヒント」・クリア後も「ヒント」で一致してしまう。
    /// ブリッジ側は撃つ前に `refresh()` してから読むので、**同じノードをブリッジは「入っている」・
    /// snapshot は「空」と読む**のが元の食い違い。
    ///
    /// **キャッシュ迂回でなければならない**(2026-08-14 の実測):
    /// ブリッジの木で editable ノードだけ `refresh()` する案は、step5 の誤検出を 12/28 → 0/4 に
    /// したが、**木が混世代になり ref の座標が別版のレイアウトを指す**ため、後段の clearInput が
    /// **別の入力欄を消す**退行(step12 が 0/17 → 2/4)を生んで棄却した。`bypassingCache` は
    /// 全ノードを取り直すので木の世代が揃い、この危険が無い。
    ///
    /// 迂回を持たないドライバ(iOS)は従来どおり解決時の値を使う(費用ゼロ)。
    /// Android は 1 clearInput につき約 +65ms —— 沈黙する誤判定と引き換えなら安い
    private func valueBeforeClear(element: ElementInfo, step: FlowStep, driver clearDriver: AppDriver,
                                  phase: inout PhaseAccumulator) async throws -> String? {
        guard clearDriver.supportsCacheBypass else { return element.value }
        let clock = ContinuousClock()
        let start = clock.now
        let snapshot = try await clearDriver.snapshot(bypassingCache: true)
        phase.snapshotMs += Self.ms(clock.now - start)
        // 撃つ前に消えた/解決できないときは、判定を弱めるより解決時の値を残す
        guard let (found, _) = Self.resolve(step: step, in: snapshot) else { return element.value }
        return found.value
    }

    /// clearInput 事後検証: 残っている値(nil = 消えている/判定不能)。
    /// **`placeholder` フィールドとの一致では判定できない**ので「クリア前の値からの変化」で見る:
    /// 空欄の `value` に placeholder 文字列が入る実装があり(iOS 全般 / **Android の CMP は
    /// `placeholder` を送らないまま value に入れる** ―― 2026-07-30 実測)、一致判定は素通りする。
    /// **層3は保険なので誤検出ゼロに倒す**(検出漏れは層2 = 受け口側の読み返しが拾う):
    /// 値が変わっていれば消えたと見なし、`before` が空/placeholder なら「消すものが無かった」
    /// として検証しない
    private static func residualClearValue(before: String?, after: String?,
                                          placeholder: String?) -> String? {
        guard let before, !before.isEmpty, before != placeholder else { return nil }
        guard let after, !after.isEmpty, after != placeholder else { return nil }
        return after == before ? after : nil
    }

    /// clearInput(ref あり)の事後検証。渡された snapshot 内で同じ step(locator)を解決し直して
    /// クリア前の値と比べる。解決できない(要素が消えた等)ときは検証不能なので nil
    /// (検証できないことを失敗にしない)
    private static func residualClearValue(step: FlowStep, before: String?,
                                          in snapshot: SnapshotResponse) -> String? {
        guard let (found, _) = Self.resolve(step: step, in: snapshot) else { return nil }
        return Self.residualClearValue(before: before, after: found.value,
                                       placeholder: found.placeholder)
    }

    /// clearInput(ref あり)の事後検証: 同じ driver で snapshot を撮り直してから残存値を見る。
    /// **単発では判定しない**(ロケータ解決の再試行と同じ規律で最大3回・計約700ms):
    /// Android の `ACTION_SET_TEXT` は a11y ツリーへの反映が数十〜数百ms遅れ、1発勝負では
    /// 消えているのに古い値を読んで誤検出する(2026-07-30 実測。textIs がポーリングで
    /// 吸収しているのと同じ事情)
    private func residualClearValue(_ driver: AppDriver, step: FlowStep, before: String?,
                                    phase: inout PhaseAccumulator) async throws -> String? {
        let clock = ContinuousClock()
        var backoff = PollBackoff()
        var residual: String?
        for attempt in 0..<Self.residualClearAttempts {
            if attempt > 0 {
                let waitStart = clock.now
                try await Task.sleep(for: backoff.nextDelay())
                phase.waitMs += Self.ms(clock.now - waitStart)
            }
            let start = clock.now
            let snapshot = try await driver.snapshot(bypassingCache: Self.bypassOnLastAttempt(
                attempt: attempt, driver: driver))
            phase.snapshotMs += Self.ms(clock.now - start)
            residual = Self.residualClearValue(step: step, before: before, in: snapshot)
            if residual == nil { return nil }
        }
        return residual
    }

    /// clearInput(ref なし)の事後検証: クリア前に覚えた要素を撮り直した snapshot で突き合わせる。
    /// ref あり版と同じ理由でポーリングする(単発では反映遅れを誤検出する)
    private func residualClearValue(_ driver: AppDriver, focusedBefore: ElementInfo,
                                    phase: inout PhaseAccumulator) async throws -> String? {
        let clock = ContinuousClock()
        var backoff = PollBackoff()
        var residual: String?
        for attempt in 0..<Self.residualClearAttempts {
            if attempt > 0 {
                let waitStart = clock.now
                try await Task.sleep(for: backoff.nextDelay())
                phase.waitMs += Self.ms(clock.now - waitStart)
            }
            let start = clock.now
            let snapshot = try await driver.snapshot(bypassingCache: Self.bypassOnLastAttempt(
                attempt: attempt, driver: driver))
            phase.snapshotMs += Self.ms(clock.now - start)
            residual = Self.residualClearValue(of: focusedBefore, in: snapshot)
            if residual == nil { return nil }
        }
        return residual
    }

    /// clearInput(ref なし)の事後検証。クリア前に覚えた要素をクリア後の snapshot で同一要素として
    /// 突き合わせる。**identifier 優先、無ければ frame 一致**(ref はスナップショット毎に振り直され
    /// フォールバック後は driver も変わるため使えない)。見つからなければ検証不能なので nil
    private static func residualClearValue(of before: ElementInfo, in snapshot: SnapshotResponse) -> String? {
        let match: ElementInfo?
        if let identifier = before.identifier {
            match = snapshot.elements.first { $0.identifier == identifier }
        } else {
            match = snapshot.elements.first { $0.frame == before.frame }
        }
        guard let match else { return nil }
        return Self.residualClearValue(before: before.value, after: match.value,
                                       placeholder: match.placeholder)
    }

    /// 注記の合流(どちらか片方だけのことが多いので nil を潰して " / " で繋ぐ)
    static func joinNotes(_ notes: String?...) -> String? {
        let present = notes.compactMap { $0 }.filter { !$0.isEmpty }
        return present.isEmpty ? nil : present.joined(separator: " / ")
    }

    /// 対象を取り得るジェスチャ(対象未指定なら画面全体)。ロケータ有無で解決だけが違うので
    /// 実体はここ1箇所に置く
    static let gestureActions: Set<String> = ["pinchOut", "pinchIn", "doubleTap", "swipeBy"]

    /// ピンチ / ダブルタップ / 相対ドラッグの実行。target = 対象領域(要素の frame か画面)、
    /// viewport = 画面矩形。**慣性が乗るので末尾で必ず整定を待つ**(ランナーはこれらのルートを
    /// 整定対象に入れていない。理由は BridgeRouter.mutatingPaths のコメント)
    private func performGesture(_ action: String, step: FlowStep, target: FTRect,
                                identifier: String?, viewport: FTRect,
                                phase: inout PhaseAccumulator) async throws -> StepOutcome {
        var viaXCUITest = false
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
                durationSeconds: step.duration ?? FlowStep.defaultPinchDurationSeconds,
                phase: &phase)
        case "doubleTap":
            viaXCUITest = try await doubleTapWithFallback(x: target.centerX, y: target.centerY,
                                                          phase: &phase)
        case "swipeBy":
            guard let path = ScrollGeometry.panPath(container: target, viewport: viewport,
                                                    dxRatio: step.dxRatio ?? 0,
                                                    dyRatio: step.dyRatio ?? 0) else {
                // 動かないドラッグを撃って「成功」と記録すると、比率の書き間違いに気付けない
                return StepOutcome(status: .failed(
                    "swipeBy cannot build a usable path (the target area is off-screen, "
                        + "or dxRatio/dyRatio are too small to move a finger)"))
            }
            viaXCUITest = try await dragWithFallback(
                path: path,
                durationSeconds: step.duration ?? FlowStep.defaultSwipeDurationSeconds,
                phase: &phase)
        default:
            return StepOutcome(status: .skipped("unknown gesture: \(action)"))
        }
        let settled = try await settledSignature(phase: &phase).settled
        var notes: [String] = []
        if viaXCUITest { notes.append("fell back to XCUITest") }
        if !settled { note(.settleCapped, into: &notes) }
        return StepOutcome(status: .passed,
                           driverFallback: notes.isEmpty ? nil : notes.joined(separator: " / "))
    }

    /// 座標ドラッグを通常ドライバ →(501/ルート不明404 なら)typeDriver の順で撃つ。
    /// 座標はブリッジ間で共通(ref と違い取り直しが要らない)ので、そのまま渡すだけでよい。
    /// 戻り値: true = typeDriver(XCUITest)経由
    private func dragWithFallback(path: FTSwipePath, durationSeconds: Double,
                                  phase: inout PhaseAccumulator) async throws -> Bool {
        try await gestureWithFallback(phase: &phase) {
            try await $0.drag(fromX: path.fromX, fromY: path.fromY,
                              toX: path.toX, toY: path.toY,
                              pressSeconds: 0.05, durationSeconds: durationSeconds)
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

    /// 座標だけで完結するジェスチャの共通フォールバック。in-app が「このエンジンでは不可」と
    /// 返したとき(501 / ルート不明 404)だけ XCUITest へ回す —— in-app は自前描画の
    /// フレームワークなら多点も撃てるが、UIKit/SwiftUI では合成タッチが受理されず 501 を返す。
    /// **409 は含めない**(理由は DriverError.isEngineIncapable)
    private func gestureWithFallback(phase: inout PhaseAccumulator,
                                     _ body: (AppDriver) async throws -> Void) async throws -> Bool {
        let clock = ContinuousClock()
        let start = clock.now
        do {
            try await body(driver)
            phase.actionMs += Self.ms(clock.now - start)
            return false
        } catch {
            guard DriverError.isEngineIncapable(error), let td = typeDriver else { throw error }
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
        guard let (from, _) = Self.resolve(step: step, in: snapshot),
              let (to, _) = Self.resolve(step: endStep, in: snapshot) else { return false }
        start = clock.now
        try await td.drag(fromX: from.frame.centerX, fromY: from.frame.centerY,
                          toX: to.frame.centerX, toY: to.frame.centerY,
                          pressSeconds: 0.05, durationSeconds: durationSeconds)
        phase.actionMs += Self.ms(clock.now - start)
        return true
    }
}
