// StepExecutor+DirectActions.swift
// executeAction(StepExecutor+Actions.swift)の入口分岐にある、ロケータ解決を経由しない早期 return の
// アクション本体(swipe/rotateTo/scroll/scrollToEdge/flick/座標 tap/対象未指定ジェスチャ/scrollTo/
// フォーカス中要素への type・pressEnter・hideKeyboard・clearInput)。呼び出し条件は
// StepExecutor+Actions.swift 側に残る(本体だけをここへ委譲する)

import Foundation

extension StepExecutor {

    func executeDirectSwipe(step: FlowStep, phase: inout PhaseAccumulator) async throws -> StepOutcome {
        let direction = FTSwipeDirection(rawValue: step.direction ?? "") ?? .up
        // **未指定でも撮る**(2026-08-31): キーボード表示中かどうかは snapshot でしか
        // 分からない。キーボードが無ければ path は nil のまま = エンジン既定(1バイトも
        // 変わらない)。**path を付けるのはキーボードがあるときだけ** —— in-app の
        // contentOffset 経路はキーボードに塞がれないが、座標つきは Compose/Flutter で
        // 501 を返すため、swipeWithFallback が XCUITest の実ジェスチャへ回す
        // (キーボード上はそちらでないと動かないので、これが望ましい)
        let snapshot = try await snapshotForScrollFrame(phase: &phase)
        let hasKeyboard = snapshot.keyboardFrame != nil || snapshot.keyboardShown == true
        let path = hasKeyboard ? scrollPath(step: step, intent: .gesture, in: snapshot) : nil
        let viaXCUITest = try await swipeWithFallback(direction, path: path, phase: &phase)
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
    func executeDirectRotateTo(step: FlowStep, phase: inout PhaseAccumulator) async throws -> StepOutcome {
        guard let raw = step.direction, let orientation = FTOrientation(rawValue: raw) else {
            return StepOutcome(status: .failed("rotateTo requires an orientation"))
        }
        let clock = ContinuousClock()
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
    func executeDirectScroll(step: FlowStep, phase: inout PhaseAccumulator) async throws -> StepOutcome {
        let direction = FTSwipeDirection(rawValue: step.direction ?? "") ?? .up
        let times = max(1, step.maxSwipes ?? 1)
        var viaXCUITest = false
        var unsettled = false
        var sentSwipes = 0
        // **未指定でも撮る**(2026-08-31): scrollPath には viewport(snapshot.screen)が要るので、
        // 木が無いと path ごと nil になり黙って全画面スワイプへ退化する
        // (scrollToEdge/flick は rect を見ている。2026-08-12)。
        // **キーボード表示中はこれが唯一の検知手段でもある** —— ソフトキーボードの上で
        // スワイプすると始点がキーボード面に乗って何も動かない(scrollContainer 参照)。
        // 木を1枚読む固定費は scrollDown/scrollUp のたび毎回払う
        var latest: SnapshotResponse? = try await snapshotForScrollFrame(phase: &phase)
        for _ in 0..<times {
            // **明示 scrollFrame が解決できないなら、ここで打ち切る(1本も振らない)**。
            // 黙って全画面スワイプへ退化させない(runScrollSearch の fail-fast と同じ理由。2026-08-08)
            if let latest, Self.scrollFrameUnresolved(step, in: latest) {
                noteCodesThisStep.insert(.scrollFrameMissing)
                return StepOutcome(status: failed(
                    .notFound,
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
            // **常に引き継ぐ**(2026-08-31): settledSignature は毎回木を撮り直しているので
            // 追加コストは無い。scrollFrame 未指定でもキーボードの開閉は周回ごとに変わりうる
            latest = settled.snapshot
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
    func executeDirectScrollToEdge(step: FlowStep, phase: inout PhaseAccumulator) async throws -> StepOutcome {
        let direction = FTSwipeDirection(rawValue: step.direction ?? "") ?? .up
        var viaXCUITest = false
        var previous: String?
        var unchanged = 0
        var reachedEdge = false
        var sawUnsettled = false
        let limit = max(1, step.maxSwipes ?? FlowStep.defaultMaxEdgeSwipes)
        var hintJumps = 0
        var sentSwipes = 0
        // 見えている中身が最後に変わった時刻(端を確定してよいかの起点)。nil = 一度も変わっていない
        // = 送る前から端だった → 猶予を待たない
        let clock = ContinuousClock()
        var lastChangeAt: ContinuousClock.Instant?
        var retryAfterGrace = false
        // 端を確定する前に、最後の変化から `edgeClaimGraceAfterMove` 経っているかを見る。
        // 経っていなければ残りを待って true(= もう1本送ってから判断し直す)
        func waitedForGrace() async throws -> Bool {
            guard let lastChangeAt else { return false }
            let remaining = Self.edgeClaimGraceAfterMove - (clock.now - lastChangeAt)
            guard remaining > .zero else { return false }
            let waitStart = clock.now
            try await Task.sleep(for: remaining)
            phase.waitMs += Self.ms(clock.now - waitStart)
            return true
        }
        // ドライバの端申告を確かめた読みは**次の周回の読みとして使い回す**
        // (捨てて撮り直すと、端の確定のために木を1周ぶん余計に読む)
        var carried: (signature: String, snapshot: SnapshotResponse, settled: Bool, changed: Bool)?
        for _ in 0..<limit {
            let settled: (signature: String, snapshot: SnapshotResponse, settled: Bool, changed: Bool)
            if let carried {
                settled = carried
            } else {
                settled = try await settledSignature(phase: &phase)
            }
            carried = nil
            if !settled.settled { sawUnsettled = true }
            let contentSignature = Self.edgeSignature(settled.snapshot)
            unchanged = contentSignature == previous ? unchanged + 1 : 0
            if let previous, contentSignature != previous { lastChangeAt = clock.now }
            // ヒント跳躍(WebView): 端までの残り距離が分かるときは長距離ドラッグで寄せる
            let jump = Self.offscreenEdgeJump(snapshot: settled.snapshot, finger: direction)
            // **変わってから `edgeClaimGraceAfterMove` 経つまでは端と確定しない**: 端へ飛ぶと続きを
            // 非同期に描き足す仮想化リスト(RN の FlatList)は、描き足しが**窓の外**に起きるので
            // 見えている署名が変わらない。待った直後の周回は必ず1本送る(描き足されていれば先へ進む)
            if !retryAfterGrace,
               unchanged >= Self.unchangedRoundsForEdge(snapshot: settled.snapshot,
                                                        remainingJump: jump) {
                guard try await waitedForGrace() else { reachedEdge = true; break }
            }
            retryAfterGrace = false
            // **明示 scrollFrame が解決できないなら、ここで打ち切る(1本も振らない)**。
            // 黙って全画面スワイプへ退化させない
            if Self.scrollFrameUnresolved(step, in: settled.snapshot) {
                noteCodesThisStep.insert(.scrollFrameMissing)
                return StepOutcome(status: failed(
                    .notFound,
                    Self.scrollFrameFailFastMessage(step, action: "swipe", swipes: sentSwipes)))
            }
            previous = contentSignature
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
            // **ドライバが「もう端」と言えるなら、署名の2回不変を待たない**。
            // 位置を直接動かせる経路(Android の CDP・in-app の contentOffset)は
            // 「余地が無い」を**事実として**知っており、こちらの推測より強い。
            // 申告も上の「不変」と同じく、最後の変化から `edgeClaimGraceAfterMove` 経つまでは確定しない
            // (飛んだ直後の申告は、描き足す前の「今は余地が無い」でしかない)。確認の読みで木が
            // 変わっていたらループへ戻る
            // **false(= 確かに動かした)は署名より強い「動いた」**: 端へ飛ぶたびにセルが同じ座標に並ぶ
            // 画面(RN の FlatList)では、動いても型と座標の署名が変わらず「不変」に見える
            if driver.reachedEdgeOnLastSwipe == false {
                lastChangeAt = clock.now
                previous = nil
            }
            if driver.reachedEdgeOnLastSwipe == true {
                let confirm = try await settledSignature(phase: &phase)
                if !confirm.settled { sawUnsettled = true }
                let confirmed = Self.edgeSignature(confirm.snapshot)
                if confirmed == previous {
                    guard try await waitedForGrace() else { reachedEdge = true; break }
                    retryAfterGrace = true
                } else {
                    previous = confirmed
                    lastChangeAt = clock.now
                }
                carried = confirm
            }
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
    func executeDirectFlick(step: FlowStep, phase: inout PhaseAccumulator) async throws -> StepOutcome {
        let clock = ContinuousClock()
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
                return StepOutcome(status: failed(
                    .notFound,
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

    // **座標タップ**(`tap(x:y:)`)。要素解決を一切通さない = アプリが要素を1つも公開しない
    // 画面のための経路。**locator があるときはここへ来ない** —— セレクタで指せるなら常に
    // そちらを使う(FlowStep.x の宣言。用途を問わない規律)
    func executeDirectCoordinateTap(step: FlowStep, x: Double, y: Double,
                                    phase: inout PhaseAccumulator) async throws -> StepOutcome {
        let clock = ContinuousClock()
        let start = clock.now
        let hold = step.duration ?? FlowStep.defaultTapHoldSeconds
        var note: String?
        do {
            if hold > 0 {
                try await driver.press(x: x, y: y, duration: hold)
            } else {
                try await driver.tap(x: x, y: y)
            }
        } catch {
            // in-app は座標ジェスチャを持たない(501)。hybrid では XCUITest へ回す
            guard DriverError.isEngineIncapable(error), let td = typeDriver else { throw error }
            if hold > 0 {
                try await td.press(x: x, y: y, duration: hold)
            } else {
                try await td.tap(x: x, y: y)
            }
            note = "fell back to XCUITest"
        }
        phase.actionMs += Self.ms(clock.now - start)
        return StepOutcome(status: .passed, driverFallback: note)
    }

    // ピンチ・ダブルタップ・相対ドラッグ(斜め可)の**対象未指定版** = 画面全体を対象にする。
    // ロケータ付きは下の switch(要素解決・ヒール・スクロール探索にそのまま乗せるため)で、
    // 対象の決め方以外は performGesture に集約してある
    func executeDirectUntargetedGesture(_ action: String, step: FlowStep,
                                        phase: inout PhaseAccumulator) async throws -> StepOutcome {
        let snapshot = try await snapshotForScrollFrame(phase: &phase)
        // **ピンチだけは領域を絞る** —— 指の2点が別々のものに載るとパンに化ける
        // (理由と実測は PinchRegion)。doubleTap は中心を叩くだけ・swipeBy は比率の基準が
        // 変わるので絞らない。Android は領域の短辺から指の幅を決めるので渡さない
        let area = !isAndroid && ["pinchOut", "pinchIn"].contains(action)
            ? PinchRegion.area(elements: snapshot.elements, screen: snapshot.screen) : nil
        let outcome = try await performGesture(
            action, step: step, target: area ?? snapshot.screen, identifier: nil,
            viewport: snapshot.screen, phase: &phase)
        guard area != nil else { return outcome }
        return StepOutcome(status: outcome.status, driverFallback: Self.joinNotes(
            outcome.driverFallback,
            "pinched the middle of the screen so both fingers stay on the same thing"))
    }

    // 要素が見つかるまでスクロール(見つかったら成功。操作はしない)
    func executeDirectScrollTo(step: FlowStep, phase: inout PhaseAccumulator) async throws -> StepOutcome {
        let result = try await runScrollSearch(step: step, phase: &phase)
        let note = recordedScrollSearchNote(result, scrollFrameNote: pendingScrollFrameNote)
        guard result.found else {
            return StepOutcome(status: failed(.notFound, Self.scrollNotFoundMessage(step, result)))
        }
        if let fallback = result.fallback {
            return StepOutcome(status: .passedViaFallback(fallback), driverFallback: note)
        }
        return StepOutcome(status: .passed, driverFallback: note)
    }

    // ロケータ指定のない type はフォーカス中の要素へ送る(直前の tap でフォーカスした欄など)。
    // ref: nil = ブリッジがフォーカス中要素へ入力(iOS/Android とも)。ロケータ解決を挟まない。
    func executeDirectUnfocusedType(step: FlowStep, phase: inout PhaseAccumulator) async throws -> StepOutcome {
        let clock = ContinuousClock()
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
        let text = step.text ?? ""
        // **`tap(入力欄)` → `type("文字列")` を成立させる**(2026-08-21。Shirates 伝統の書き方)。
        // Android の入力欄は容器(TextInputLayout)と中身(TextInputEditText)に分かれ、
        // **id は容器側に付くことが多い** —— 容器を叩いても入力フォーカスは中身へ移らないので、
        // 素直に書くと次の type が「フォーカスが無い」で落ちていた。
        // **払うのは tap の直後だけ**(木を1枚読む)。自動フォーカスに任せる書き方や、
        // pressEnter で欄を移った直後の type は従来どおり読み足さない。
        // 改行入りは typeDriver(XCUITest)へ回す経路があり ref の体系が別なので触らない
        if let tapped = lastTapTarget, !text.contains("\n"),
           let recovered = try await retypeTargetIfUnfocused(after: tapped, phase: &phase) {
            // retypeTargetIfUnfocused が撮った撮り直し後の snapshot の keyboardFrame
            // (= 打つ前の状態。retypeRescueKeyboardFrame の doc)
            let keyboardBefore = retypeRescueKeyboardFrame
            let start = clock.now
            try await driver.type(ref: recovered.ref, text: text)
            phase.actionMs += Self.ms(clock.now - start)
            // 文言は動的(入れた先を名指しする)のでコードだけ立てる
            // —— 外側の execute が collectedNotes() で拾う(StepOutcome.notes の doc)
            noteCodesThisStep.insert(.typeFocusRecovered)
            // ロケータ有り type(case "type")と同じ読み返し規律: in-app は「200 が返った = 入った」
            // を保証しない。**ここには actingDriver が無い**(この分岐はロケータ解決前の早期
            // return で、フォールバックドライバの選定を通らない)ので driver で判定する。
            // recovered は retypeTargetIfUnfocused が撮った撮り直し後のスナップショット由来
            // なので、その時点の値をそのまま「撃つ前の値」として使ってよい(clearInput 等の
            // 反映も込み)
            if !driver.verifiesTypedText, TypeReadback.isTextInput(recovered) {
                let existingValue = TypeReadback.normalizedValue(of: recovered)
                if let failure = try await verifyTypedText(driver, element: recovered,
                                                            expected: existingValue + text,
                                                            typedOnly: text, phase: &phase) {
                    return StepOutcome(status: .failed(failure))
                }
            }
            // ロケータ有り type(case "type")と同じ判定(keyboardFrameBeforeType の doc)。
            // 「打った後」はここでは読まない —— 次のロケータ操作が解決のために撮る最初の
            // 木で比べる(エンジンに依存しない)
            keyboardFrameBeforeType = keyboardBefore
            pendingTypeKeyboardCheck = true
            pendingTypeEndedWithNewline = text.hasSuffix("\n")
            return StepOutcome(status: .passed,
                               driverFallback: Self.joinNotes(replaceFallbackNote,
                                   "typed into \(TapTargetGeometry.describe(recovered))"
                                       + " (the preceding tap did not put a field in focus)"))
        }
        // ロケータ有り type(下記 case "type")と同じ規則: "\n" を含むときだけ
        // typeDriver(XCUITest)へ回し、iOS の Return キー既定挙動に揃える(理由は同 case のコメント参照)。
        // **tap の直後なら、先に焦点が立つのを待つ**(pressEnter と同じ待ち)。この経路は焦点救済
        // (上の retypeTargetIfUnfocused)も読み返しも通らず、Return で即確定するので打ち直せない ——
        // E2E-RN で tap(#field_single) → type("pqr\n") が "pq" で確定した(tap が速くなった v110 以降に初出)。
        // 焦点が既に立っていれば 1 枚読むだけで抜ける
        var focusNote: String?
        if text.contains("\n"), typeDriver != nil, lastTapTarget != nil {
            focusNote = try await awaitFocusBeforeKeyInput("type", phase: &phase)
        }
        let start = clock.now
        if text.contains("\n"), let td = typeDriver {
            try await td.type(ref: nil, text: text)
        } else {
            try await driver.type(ref: nil, text: text)
        }
        phase.actionMs += Self.ms(clock.now - start)
        return StepOutcome(status: .passed, driverFallback: Self.joinNotes(replaceFallbackNote, focusNote))
    }

    // pressEnter もロケータを持たない(フォーカス中の入力欄への Enter 押下)ので、type(ref: nil)
    // と同じ理由でロケータ解決を挟まない。409(inapp が Compose 以外の入力欄/フォーカス無しで
    // 出す。InAppBridge.handlePressEnter 参照)は type のロケータ版と同じ形で
    // typeDriver(xcuitest)へフォールバックする(判定は DriverError.isTextInputFallback)
    func executeDirectPressEnter(phase: inout PhaseAccumulator) async throws -> StepOutcome {
        let clock = ContinuousClock()
        let focusNote = try await awaitFocusBeforeKeyInput("pressEnter", phase: &phase)
        let start = clock.now
        do {
            try await driver.pressEnter()
        } catch {
            guard DriverError.isTextInputFallback(error), let td = typeDriver else { throw error }
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
    func executeDirectHideKeyboard(step: FlowStep, phase: inout PhaseAccumulator) async throws -> StepOutcome {
        let clock = ContinuousClock()
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
        // 木からキーボードが消えるのを待つのは次のロケータ操作の解決(pendingHideKeyboardWait の doc)
        if isAndroid { pendingHideKeyboardWait = step.timeout ?? FlowStep.defaultWaitSeconds }
        return StepOutcome(status: .passed)
    }

    // clearInput もロケータ無しならフォーカス中欄へ作用する(type(ref: nil) と同じくロケータ解決を
    // 挟まない)。対象なし(409)またはこのエンジンでは未対応(isEngineIncapable)なら
    // typeDriver(xcuitest)へフォールバックする
    func executeDirectUnfocusedClearInput(phase: inout PhaseAccumulator) async throws -> StepOutcome {
        switch try await performClearInputFocused(phase: &phase) {
        case .cleared(let fallback):
            return StepOutcome(status: .passed, driverFallback: fallback)
        case .failed(let message):
            return StepOutcome(status: .failed(message))
        }
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
    /// 合図が出ないまま waitSeconds 経過したら拒否せず注記を返す(呼び出し側で driverFallback へ合流)。
    /// **ロケータ無しで改行入りの type も同じ待ちを通す**(tap の直後だけ。下記 case "type" の呼び出し参照)
    private func awaitFocusBeforeKeyInput(_ operation: String,
                                          phase: inout PhaseAccumulator) async throws -> String? {
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
                return "no field ever took focus within \(FocusWait.waitSeconds)s before \(operation)"
                    + " — the keys may have gone to whichever field still had it"
            }
            let waitStart = clock.now
            try? await Task.sleep(for: .seconds(FocusWait.pollSeconds))
            phase.waitMs += Self.ms(clock.now - waitStart)
        }
    }
}
