// StepExecutor+TypeClear.swift
// typeDriver 経由の type/tap/press/clear・入力の読み返し検証・キーボードの下の対象への到達・clearInput の残り値判定。
// 呼び口は +Actions の executeAction(verifyTypedText・performClearInputFocused は +DirectActions からも)

import Foundation

extension StepExecutor {
    /// typeDriver で type を試みる。ref はブリッジごとに別名前空間なので typeDriver 側 snapshot で
    /// 取り直す。解決できなければ false(呼び出し側で通常経路[inapp]へフォールバック/再スロー)。
    /// 戻り値の note は撃つ前に送ったときの注記(liftCoveredTarget)
    func typeViaTypeDriver(_ td: AppDriver, step: FlowStep,
                                   phase: inout PhaseAccumulator) async throws -> (typed: Bool, note: String?) {
        let clock = ContinuousClock()
        var start = clock.now
        var snapshot = try await td.snapshot()
        phase.snapshotMs += Self.ms(clock.now - start)
        guard var resolved = LocatorResolver.resolveDetailed(step: step, in: snapshot) else { return (false, nil) }
        // **XCUITest へ回した打鍵も、キーボードの下・見切れた欄なら撃つ前に送る**(主経路と同じ liftCoveredTarget)。
        // XCUITest は欄を座標でタップしてから打つので、キーボードに当たると焦点が前の欄に残って打鍵が流れ込む
        // (実測: hybrid で改行を含む type が XCUITest へ回り、キーボードの下の複数行の欄の代わりにパスワードの欄へ入った)。
        // 判断は XCUITest の木で行う(in-app の木はキーボードを申告しない)。送った後は XCUITest の木で引き当て直す
        var note: String?
        if let lifted = try await liftCoveredTarget(resolved.element, in: snapshot, step: step,
                                                    verb: "typing", snapshotSource: .driver(td), phase: &phase) {
            note = lifted.note
            snapshot = lifted.snapshot
            guard let again = LocatorResolver.resolveDetailed(step: step, in: snapshot) else { return (false, note) }
            resolved = again
        }
        start = clock.now
        try await td.type(ref: resolved.element.ref, text: step.text ?? "")
        phase.actionMs += Self.ms(clock.now - start)
        return (true, note)
    }

    /// in-app 経由の type 読み返し(AppDriver.verifiesTypedText == false のときだけ呼ばれる)。
    /// BridgeRouter.handleType/awaitCommit(Runner ターゲット。TypeReadback 以外を import できず
    /// 共有できないので独立実装。値は同期: 8s/4周/安定1.5s)と同じ規律 —— 期待値どおりになるまで
    /// 待ち、前方一致で止まっていれば追送、超過していれば削除して全文を打ち直す。
    /// expected は**撃つ前**の値から呼び出し側が組む(読み直した値から作り直すとマスク欄の
    /// 伏せ字を書き込む)。戻り値: nil = 検証済み(一致・検証不能とも受理)/ 非nil = 失敗理由
    /// (値そのものは含めない。パスワード欄も通る経路)
    ///
    /// **private ではない**: StepExecutor+DirectActions.swift の executeDirectUnfocusedType からも呼ぶ
    func verifyTypedText(_ driver: AppDriver, element: ElementInfo, expected: String,
                                 typedOnly: String,
                                 phase: inout PhaseAccumulator) async throws -> String? {
        let clock = ContinuousClock()
        // var: OCR のコンパイルを待った分だけ後ろへずらす(アプリの応答ではない待ちを予算から引かない)
        var deadline = Date().addingTimeInterval(Self.typeVerifyBudgetSeconds)
        var rounds = 0
        var stagnantRounds = 0
        var previous: String?
        var retypes = 0
        // 直前の追送を撃った時点の値。追送の後も同じ値なら、それ以上撃っても重複するだけ
        var valueAtLastResend: String?
        var checkedScreenForTypedText = false
        // 画面を見たときに何が観測できたか(失敗の文言に事実として添える。読めなかった理由が
        // 「描かれていない」か「読みが成立しなかった」かで、読み手の次の一手が変わる)
        var screenCheckFact: String?
        // 不可視文字を正規化する: MCP の replaceVerificationNote/appendVerificationNote
        // と同じ規律。実データが混入させるゼロ幅文字(Flow.swift 参照)だけで、実質同じ文字列が
        // `TypeReadback.plan` の前方一致から外れる。**壊れ方は混入位置で2つに割れる**:
        //   途中(`Hel<ZWSP>lo`)= どちらの前方一致も成立せず `.unverifiable` で**黙って受理** ——
        //     ステップは緑のまま通り、読み返しの砦が丸ごと外れたことに気付けない
        //   末尾(`Hello<ZWSP>`)= `actual.hasPrefix(expected)` が成立して `.deleteExcess` へ落ち、
        //     clearInput + 全文打ち直しが走る。欄は同じ値を返すので停滞し、最大 8 秒で
        //     "did not settle" として**失敗する**(緑の run が赤になる)
        // TypeReadback.swift はブリッジ共有ファイルで編集不可(BridgeSourceSet)なので、正規化は
        // 呼び出し側(ここ・readbackTarget・awaitTypeCommit)に置く。expected.count は正規化後を
        // 使う —— 不可視文字は利用者の目に映らないので、見えている文字数で失敗を語るほうが親切
        let expected = FlowMatchMode.normalizeInvisibleCharacters(expected)
        let typedOnly = FlowMatchMode.normalizeInvisibleCharacters(typedOnly)

        while true {
            rounds += 1
            guard let (actual, liveRef) = try await awaitTypeCommit(driver, element: element, expected: expected,
                                                                     typedOnly: typedOnly,
                                                                     deadline: deadline, phase: &phase) else {
                return nil   // 読めない/曖昧 = 検証不能なので受理する(TypeReadback.value 参照)
            }
            let target = Self.readbackTarget(expected: expected, typedOnly: typedOnly, actual: actual)
            let plan = TypeReadback.plan(expected: target, actual: actual)
            switch plan {
            case .done, .unverifiable:
                return nil
            case .resend where valueAtLastResend == actual:
                // **追送しても値が動かなければ2回目は撃たない**(撃つたびに重複しうる。実測
                // `ap` → `apapapapap`)。値は入力を映しているのに正しくない = 失敗
                return "type reported success but the value did not change after re-sending the"
                    + " missing text (expected \(expected.count) character(s))"
                    + (screenCheckFact.map { "; before re-sending, the screen was checked for the"
                        + " typed text: \($0)" } ?? "")
            case .resend(let missing):
                // **1文字も動いていない**(足りない分が打った全文)なら、追送の前に画面を見る。
                // 届かなかったのか、欄の値が入力を映さない(M3 SearchBar の iOS は value に説明文を
                // 出す)のかは値からは区別できず、後者で追送すると入力が重複する。欄に打った文字が
                // 描かれていれば後者として受理する。読めなければ届かなかった側として追送する(1回まで)
                if !checkedScreenForTypedText, missing == typedOnly || missing == target {
                    checkedScreenForTypedText = true
                    let seen = await typedTextIsOnScreen(driver, element: element, text: typedOnly,
                                                         deadline: deadline)
                    deadline = deadline.addingTimeInterval(seen.compileWaitSeconds)
                    screenCheckFact = seen.fact
                    if seen.visible == true {
                        noteCodesThisStep.insert(.typeReadbackUnchanged)
                        return nil
                    }
                    // **確かめられないなら追送しない**: 届いていればアプリへ同じ文字列が二度入る
                    if seen.visible == nil {
                        return "type reported success but the field's value did not change, and whether the text"
                            + " reached the field could not be checked (\(seen.fact ?? Self.ocrDeadFact)) — not re-sent,"
                            + " so the field does not receive the same text twice"
                    }
                }
                valueAtLastResend = actual
                // target は正規化済み(readbackTarget)なので missing も正規化済み = 不可視文字を
                // 落とした形。**原文の不可視文字は再現できない**(expected は既存値+本文の連結で、
                // どちらの由来かここでは分からない)が、不可視文字は表示に現れないので、
                // 見える文字を送り損ねるより実害が小さい
                let start = clock.now
                // 読み返しで撮り直した後なので、その木の ref で撃つ(element.ref は別の要素を指しうる)
                try await driver.type(ref: liveRef, text: missing)
                phase.actionMs += Self.ms(clock.now - start)
            case .retype where retypes >= TypeReadback.maxRetypes:
                // 打ち直しても同じ形 = アプリ側の加工。v104 より前と同じく受理する(TypeReadback.maxRetypes)
                noteCodesThisStep.insert(.typeRetypeAbandoned)
                return nil
            case .deleteExcess, .retype:
                // in-app はバックスペースを送れないので、丸ごとクリアしてから全文を打ち直す
                // (handleClear と同じ 422 系の判断。clearInput のケースの既存実装と同じ API 形)。
                // target は正規化済み(上と同じ理由で受け入れる)。**.retype は数える**(緑の run で
                // 打ち直しが起きた回数 = 誤検知の監視。TypeReadback.Plan.retype)
                if case .retype = plan {
                    retypes += 1
                    noteCodesThisStep.insert(.typeRetyped)
                }
                let start = clock.now
                try await driver.clearInput(ref: liveRef)
                try await driver.type(ref: liveRef, text: target)
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

    /// 打った文字が欄の領域に描かれているかを OCR で見る(`verifyTypedText` の「値が1文字も動かない」形の
    /// 判別だけに使う)。**認識器のコンパイルが終わるまで待ってから読む**(コンパイル前のまま読むと読み返しの予算を
    /// 使い切って届かなかった側へ倒れ、追送で重複した。実測 `apap`)。待った時間は `DeadlineExclusion` が
    /// ステップの締め切りから引き、呼び手は読み返しの締め切りをずらす。読みの予算は読み返しの締め切りの
    /// 残り(新しい定数を置かない)。**ocrTextVisibilityCheck を見ない**(可視性検証の OCR 段のスイッチ。
    /// 近い誤読の読み直しと同じく精度側の用途)。撮れない・読めない・予算切れは visible=false。
    /// **`fact` は visible=false の内訳**(描かれていない / 読みが成立しなかった を混ぜない。値は含めない)
    /// `visible` が nil = 分からない(OCR そのものが働いていない。RegionText.readerIsAlive)。呼び手は追送しない
    func typedTextIsOnScreen(_ driver: AppDriver, element: ElementInfo, text: String, deadline: Date) async
        -> (visible: Bool?, compileWaitSeconds: TimeInterval, fact: String?) {
        if let override = Self.typedTextOnScreenOverrideForTesting {
            let answer = override(text)
            return (answer.visible, 0, answer.fact)
        }
        guard !text.isEmpty else { return (false, 0, nil) }
        guard let snapshot = try? await driver.snapshot(),
              let png = try? await driver.screenshot() else {
            return (false, 0, "the screen could not be captured")
        }
        // 黒い絵は読めなかったのと同じ扱い(追送する側)。事実だけ言い分ける
        if BlankFrameDetector.isBlackApartFromSystemBars(pngData: png) {
            return (false, 0, "the screenshot was black apart from the system bars")
        }
        let waited: TimeInterval
        switch await RegionText.awaitModelCompile(mode: .on) {
        case .alreadyReady: waited = 0
        case .compiled(let d), .finishedUnready(let d), .capped(let d):
            waited = Double(d.components.seconds) + Double(d.components.attoseconds) / 1e18
        }
        let deadline = deadline.addingTimeInterval(waited)
        let frame = snapshot.elements.first { $0.ref == element.ref || $0.identifier == element.identifier
            && element.identifier?.isEmpty == false }?.frame ?? element.frame
        let remaining = max(0, deadline.timeIntervalSinceNow)
        let result = await RegionText.resolveWithinBudget(
            expected: text, pngData: png, frame: frame, screen: snapshot.screen,
            budget: .milliseconds(Int(remaining * 1000)))
        let reading: RegionText.Reading
        switch result {
        case .read(true, _): return (true, waited, nil)
        case .read(false, let read): reading = read
        case .unreadable:
            if !(await RegionText.readerIsAlive()) { return (nil, waited, Self.ocrDeadFact) }
            return (false, waited, "the field's area could not be read (OCR returned no reading)")
        case .budgetExhausted: return (false, waited, "reading the field's area ran out of time")
        }
        if reading.lines.isEmpty, !(await RegionText.readerIsAlive()) { return (nil, waited, Self.ocrDeadFact) }
        let notFound = "OCR read \(reading.lines.count) line(s) in the field's area, none of them the typed text"
        // 英語モデルの同形異字(`ap` → `аpар`)は畳んでから見直す(OCRHomoglyphs)
        guard text.allSatisfy(\.isASCII) else { return (false, waited, notFound) }
        let folded = RegionText.readable(expected: text, lines: reading.lines.map(OCRHomoglyphs.foldToLatin))
        return (folded, waited, folded ? nil : notFound)
    }

    /// 確かめたのは「このプロセスの OCR が今、既知の文字の絵も読めなかった」だけ —— 機械全体の死とは言わない
    /// (同じ時刻に別のプロセスの OCR が読めていた例がある。一時的な失敗のこともある)
    static let ocrDeadFact = "OCR read nothing from a built-in image with known text either, just now"
        + " (the reader itself failed at that moment)"

    /// テスト用(本番では nil)。OCR を撃たずに「描かれていたか」を差し替える
    nonisolated(unsafe) static var typedTextOnScreenOverrideForTesting:
        ((String) -> (visible: Bool?, fact: String?))?

    /// 値が期待値になる/変わらなくなる(stableSeconds)/期限切れ、のいずれかまで snapshot を撮り直して
    /// 読む。awaitCommit(BridgeRouter)と同じ二重終了条件だが、取得手段がスナップショット1枚
    /// (0.3〜0.6s)なのでポーリング間隔は typePollSeconds(0.05s)より粗い typeVerifyPollSeconds を使う。
    /// 戻り値 nil = 読めない/複数候補(検証不能。TypeReadback.value 参照)
    private func awaitTypeCommit(_ driver: AppDriver, element: ElementInfo, expected: String,
                                 typedOnly: String,
                                 deadline: Date, phase: inout PhaseAccumulator) async throws
        -> (value: String, liveRef: Int)? {
        let clock = ContinuousClock()
        // 正規化(readbackTarget と同じ理由・同じ関数)。呼び出し側(verifyTypedText)は既に
        // 正規化済みを渡すが、ここでも掛け直す(冪等なので害はない) —— これが無いと下の早期終了
        // 条件だけ素通りし、実質一致していても stableSeconds ぶん待たされる
        let expected = FlowMatchMode.normalizeInvisibleCharacters(expected)
        let typedOnly = FlowMatchMode.normalizeInvisibleCharacters(typedOnly)
        /// 値と、最後に撮った木でのその欄の ref(追送・打ち直しはこの ref で撃つ)
        func read() async throws -> (value: String, liveRef: Int)? {
            // one-shot なので毎回 arm し直す(elementLimitCeilingLatchedThisStep の doc)。
            // 無いと、上限で間引かれて撮り直した木で解決した対象を、この読み返しがまた
            // 既定上限で撮って見失う
            if elementLimitCeilingLatchedThisStep {
                driver.raiseElementLimitOnNextSnapshot(BridgeAPI.maxSnapshotElementsCeiling)
            }
            let start = clock.now
            let snap = try await driver.snapshot()
            phase.snapshotMs += Self.ms(clock.now - start)
            return TypeReadback.match(of: element, in: snap.elements).map {
                (FlowMatchMode.normalizeInvisibleCharacters(TypeReadback.normalizedValue(of: $0)), $0.ref)
            }
        }
        guard var (lastValue, liveRef) = try await read() else { return nil }
        var lastChange = Date()
        while true {
            // **撃った文字だけになった形も「着いた」**(下の readbackTarget)。これが無いと
            // ヒントを value に載せる欄では毎回 stableSeconds ぶん待たされる
            if lastValue == expected || lastValue == typedOnly { return (lastValue, liveRef) }
            if Date() >= deadline { return (lastValue, liveRef) }
            if Date().timeIntervalSince(lastChange) >= Self.typeVerifyStableSeconds { return (lastValue, liveRef) }
            let waitStart = clock.now
            try? await Task.sleep(for: .seconds(Self.typeVerifyPollSeconds))
            phase.waitMs += Self.ms(clock.now - waitStart)
            guard let current = try await read() else { return nil }
            liveRef = current.liveRef
            if current.value != lastValue { lastChange = Date(); lastValue = current.value }
        }
    }

    /// 読み返しが目標にする値(順序の規則と理由は `TypeReadback.readbackTarget`)。
    ///
    /// **この退化は再現していない**(現時点)。値にヒントが載る盤面として確かめられたのは
    /// **Android の E2E-CMP `#field_single`**(value="単一行" / placeholder なし。同じシナリオの
    /// `textIs "#txt_echo_length" == "len=8"` が通るので "単一行hello123" は偽)と
    /// **Google メッセージの宛先欄**の2つで、どちらも `verifiesTypedText == true` の
    /// ドライバなのでこの関数は通らない(ランナー側は同じ規則を自前で通す)。iOS の in-app(唯一の
    /// `false`)で当たる盤面はまだ無い —— `#field_single` は iOS では placeholder を**ラベル**として
    /// 出すので `priorValue` が空になる。**失敗モードが沈黙(検証を諦めたことを誰にも言わない)なので、
    /// witness が無くても塞ぐ**
    static func readbackTarget(expected: String, typedOnly: String, actual: String) -> String {
        // 不可視文字を正規化してから比較する(MCP の
        // replaceVerificationNote/appendVerificationNote と同じ規律)。self-contained にする
        // (呼び出し側での正規化に依存しない) —— これが無いと、ゼロ幅文字が expected/typedOnly/actual
        // のどれか1つにだけ混じった時点で .unverifiable に落ち、追送も打ち直しも走らず受理される。
        // 順序の規則は TypeReadback.readbackTarget(ランナーと共有)
        TypeReadback.readbackTarget(expected: FlowMatchMode.normalizeInvisibleCharacters(expected),
                                    typedOnly: FlowMatchMode.normalizeInvisibleCharacters(typedOnly),
                                    actual: FlowMatchMode.normalizeInvisibleCharacters(actual))
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
    /// typeDriver で tap する(`pressViaTypeDriver` と同じ: ref はブリッジごとに別名前空間なので取り直す)。
    /// 解決できなければ false
    func tapViaTypeDriver(_ td: AppDriver, step: FlowStep,
                                  phase: inout PhaseAccumulator) async throws -> Bool {
        let clock = ContinuousClock()
        var start = clock.now
        let snapshot = try await td.snapshot()
        phase.snapshotMs += Self.ms(clock.now - start)
        guard let resolved = LocatorResolver.resolveDetailed(step: step, in: snapshot) else { return false }
        start = clock.now
        try await td.tap(ref: resolved.element.ref)
        phase.actionMs += Self.ms(clock.now - start)
        return true
    }

    func pressViaTypeDriver(_ td: AppDriver, step: FlowStep,
                                    phase: inout PhaseAccumulator) async throws -> Bool {
        let clock = ContinuousClock()
        var start = clock.now
        let snapshot = try await td.snapshot()
        phase.snapshotMs += Self.ms(clock.now - start)
        guard let resolved = LocatorResolver.resolveDetailed(step: step, in: snapshot) else { return false }
        start = clock.now
        try await td.press(ref: resolved.element.ref,
                           duration: step.duration ?? FlowStep.defaultTapHoldSeconds)
        phase.actionMs += Self.ms(clock.now - start)
        return true
    }

    /// typeDriver で clearInput を試みる。ref はブリッジごとに別名前空間なので typeDriver 側 snapshot で
    /// 取り直す(typeViaTypeDriver と同じ理由)。解決できなければ false(呼び出し側で再スロー)。
    func clearViaTypeDriver(_ td: AppDriver, step: FlowStep,
                                    phase: inout PhaseAccumulator) async throws -> Bool {
        let clock = ContinuousClock()
        var start = clock.now
        let snapshot = try await td.snapshot()
        phase.snapshotMs += Self.ms(clock.now - start)
        guard let resolved = LocatorResolver.resolveDetailed(step: step, in: snapshot) else { return false }
        start = clock.now
        try await td.clearInput(ref: resolved.element.ref)
        phase.actionMs += Self.ms(clock.now - start)
        return true
    }

    enum ClearOutcome {
        /// `actingDriverSnapshot` = 消去の中で**最後に撮った木が actingDriver のものだったとき**のその木(nil = 撮っていない・
        /// 最後の撮影が別のドライバ)。ブリッジは撮るたびに ref の表を作り直すので、消去の後に撃つ ref はこの木か
        /// 撮り直した木から引く(撮る前の ref は別の欄を指しうる = E2E-CMP S0040 で xyz がパスワード欄へ入った)
        case cleared(driverFallback: String?, actingDriverSnapshot: SnapshotResponse?)
        case failed(String)
    }

    /// type/clearInput を**撃つ前に**断る文言(nil = 撃ってよい)。ドライバは打つ・消す前に対象をタップするので、
    /// 対象がボタン等なら押してしまう(送信・購入)。断るのは型が `positivelyNonTextInputTypes`(ボタン等)のとき。
    /// **自前描画でも断る**: 編集できる要素は全経路で入力型を名乗る(iOS in-app = テキスト入力の trait、XCUITest =
    /// elementType、Android = Compose/Flutter とも EditText)。自前描画の本物の欄が別の型に落ちるのは `clickable`
    /// で、この集合に無い。MCP の ft_type は入力型以外を全部断る(より厳しい)ので、判断はこれで揃う側へ寄る。
    /// 内側に入力欄がちょうど1つある容器(`nonInputTypeTargetNote` が non-nil)は従来どおり撃つ
    func nonTextInputPreflightRefusal(_ element: ElementInfo, in elements: [ElementInfo],
                                      action: String) -> String? {
        guard TapTargetGeometry.typeTargetVerdict(element, in: elements) == .notATextField(positively: true) else {
            return nil
        }
        return "the target is a \(element.type), not a text field — refusing before anything is"
            + " \(action == "type" ? "typed" : "cleared") (\(action) taps its target first, so the"
            + " \(element.type) would fire — a submit or a purchase). Point the selector at the input field itself."
    }

    /// **キーボードの下の対象へ届かせる**(tap・type・clearInput)。ユーザー決定「人が操作できないときだけ失敗にし、
    /// 人ができる操作はツールも最善を尽くす」—— 人はキーボードを閉じてから押す。送って外せる画面は呼び手が先に
    /// `liftCoveredTarget` で外している。残ったら**副作用の無い手段だけで**閉じ(`closeKeyboardWithoutSideEffects`)、
    /// 閉じた後の木で引き当て直す。閉じなければ失敗 —— 閉じられるのが Enter だけの画面(Compose の iOS の住所フォーム)で
    /// Enter を勝手に撃つと欄の確定操作(送信・検索)が走るので撃たない(ユーザー決定)。シナリオが pressEnter を書く。
    /// 覆われたまま撃たない理由: 焦点を当てるタップがキーボードに当たり、打鍵が前の欄へ流れ込む(受け手の 4.7 インチ実機で
    /// 市区町村の欄に住所が3回追記された)。in-app は座標を使わず焦点を当てるので、**人ができない操作が iOS だけ緑になっていた**。
    /// 判定は MCP の門(`MCPServer.keyboardRefusal`)と同じ `KeyboardOcclusion`。nil = 覆われていない
    func reachPastKeyboard(_ element: ElementInfo, in snapshot: SnapshotResponse, step: FlowStep, action: String,
                           snapshotSource: CoverLiftSnapshotSource,
                           phase: inout PhaseAccumulator) async throws -> KeyboardReach? {
        let occlusion = KeyboardOcclusion.resolve(reported: snapshot.keyboardFrame, in: snapshot.elements,
                                                  screen: snapshot.screen)
        guard occlusion.advisory(for: element) != nil else { return nil }
        let nothing = "nothing was " + (action == "type" ? "typed" : action == "clearInput" ? "cleared" : "tapped")
        let note: String
        switch try await closeKeyboardWithoutSideEffects(step: step, phase: &phase) {
        case .notClosed(let tried):
            return .refused("the target's centre (\(Int(element.frame.centerX)), \(Int(element.frame.centerY))) is under"
                + " the soft keyboard and the keyboard could not be closed without side effects (\(tried)) — \(nothing)."
                + " The return key may close it, but it also fires the field's action (submit, search or moving to the"
                + " next field), so it is not pressed automatically: call pressEnter() before this step if that is"
                + " intended")
        case .notShown: note = "the keyboard had closed by itself before reaching the target"
        case .closed(let closedNote, _): note = closedNote + " — the target was under it"
        }
        let clock = ContinuousClock()
        let start = clock.now
        let after: SnapshotResponse
        switch snapshotSource {
        case .primary: after = try await freshSnapshot(.afterOwnMove)
        case .driver(let other): after = try await other.snapshot(bypassingCache: true)
        }
        phase.snapshotMs += Self.ms(clock.now - start)
        guard let (found, _) = LocatorResolver.resolve(step: step, in: after) else {
            return .refused("\(note), but the target is not on the screen afterwards: \(step.locatorSummary) (\(nothing))")
        }
        let still = KeyboardOcclusion.resolve(reported: after.keyboardFrame, in: after.elements, screen: after.screen)
        guard still.advisory(for: found) == nil else {
            return .refused("\(note), but the target is still under the soft keyboard afterwards (\(nothing))")
        }
        return .reached(element: found, snapshot: after, note: note)
    }

    /// **窓がキーボードの上へ縮んで、下の要素が木から消えている**(Android の adjustResize)ときの解決。Android は
    /// キーボードの矩形を申告せず `keyboardShown` だけ来ることがある(sut-ec-mobile の住所フォーム)ので、出ていれば対象にする。
    /// iOS は覆われた要素も木に載るので、窓が縮んだと言える木だけ。人はキーボードを
    /// 閉じれば押せるので、見つからないと言う前に副作用の無い手段で閉じて探し直す(`reachPastKeyboard` と同じ方針)。
    /// **待ち切った後だけ**撃つ(先に閉じると、キーボードと一緒に出る候補一覧などを待たずに消してしまう)。
    /// tap・type・clearInput だけ(他の操作はキーボードの下を狙わない)。nil = 対象外・閉じても見つからない
    func resolveAfterClosingKeyboard(_ action: String, step: FlowStep, in snapshot: SnapshotResponse,
                                     phase: inout PhaseAccumulator)
        async throws -> (element: ElementInfo, usedFallback: FlowLocator?, snapshot: SnapshotResponse, note: String)? {
        guard ["tap", "type", "clearInput"].contains(action),
              isAndroid ? KeyboardWait.isShown(snapshot)
                : KeyboardOcclusion.resolve(reported: snapshot.keyboardFrame, in: snapshot.elements,
                                            screen: snapshot.screen).windowResizedAboveKeyboard,
              case .closed(let note, _) = try await closeKeyboardWithoutSideEffects(step: step, phase: &phase) else {
            return nil
        }
        let clock = ContinuousClock()
        let start = clock.now
        let after = try await freshSnapshot(.afterOwnMove)
        phase.snapshotMs += Self.ms(clock.now - start)
        guard let (found, usedFallback) = LocatorResolver.resolve(step: step, in: after) else { return nil }
        return (found, usedFallback, after, note + " — the target was not on the screen while the keyboard was up")
    }

    enum KeyboardReach {
        /// 閉じた後の木で引き当て直した対象(撃つ前の ref は無効)
        case reached(element: ElementInfo, snapshot: SnapshotResponse, note: String)
        case refused(String)
    }

    /// type/clearInput が `TypeReadback.isPositivelyNonTextInput` で撃ち直しを断ったときの文言。
    /// 内側にちょうど1つ入力欄があれば名指しする(`TapTargetGeometry.nonInputTypeTargetNote` と同じ規則)
    static func nonTextInputFallbackRefusal(_ element: ElementInfo, in elements: [ElementInfo],
                                                     action: String) -> String {
        var message = "the target is a \(element.type), not a text field — \(action) cannot succeed on"
            + " either engine. The tap that resolved this element may already have landed, so it was"
            + " not retried via XCUITest (a retry could trigger the \(element.type) a second time)."
        if let note = TapTargetGeometry.nonInputTypeTargetNote(element, in: elements) {
            message += " " + note
        }
        return message
    }

    /// clearInput(ref なし = フォーカス中要素)の本体。**ロケータ有り版(performClearInput)とは
    /// 別実装**: 対象を再解決できないので、クリア前に覚えたフォーカス要素を identifier/frame で
    /// 事後突き合わせる(residualClearValue(of:in:) 参照)。ロケータ無し `clearInput()` と
    /// `type(text, replace: true)` の両方がここを通る
    ///
    /// **private ではない**: StepExecutor+DirectActions.swift の executeDirectUnfocusedType /
    /// executeDirectUnfocusedClearInput からも呼ぶ
    func performClearInputFocused(phase: inout PhaseAccumulator) async throws -> ClearOutcome {
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
            guard DriverError.isClearInputFallback(error), let td = typeDriver else { throw error }
            try await td.clearInput(ref: nil)
            phase.actionMs += Self.ms(clock.now - start)
            // 焦点のある欄が木に無ければ読み返す材料が無い。黙って緑にせず注記で言う
            guard let focusedBefore else { return .cleared(driverFallback: unverifiedClearNote("fell back to XCUITest"), actingDriverSnapshot: nil) }
            if let residual = try await residualClearValue(td, focusedBefore: focusedBefore,
                                                           phase: &phase) {
                return .failed("clearInput reported success but the value remained: \"\(residual)\"")
            }
            return .cleared(driverFallback: "fell back to XCUITest", actingDriverSnapshot: nil)
        }
        phase.actionMs += Self.ms(clock.now - start)

        guard let focusedBefore else { return .cleared(driverFallback: unverifiedClearNote(nil), actingDriverSnapshot: nil) }
        if let residual = try await residualClearValue(driver, focusedBefore: focusedBefore,
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
            return .cleared(driverFallback: "fell back to XCUITest", actingDriverSnapshot: nil)
        }
        return .cleared(driverFallback: nil, actingDriverSnapshot: nil)
    }

    /// 焦点のある欄が木に無く読み返せなかったことを注記に立て、括弧書きの文言へ足す(`StepNote.clearInputUnverified`)
    private func unverifiedClearNote(_ fallback: String?) -> String? {
        noteCodesThisStep.insert(.clearInputUnverified)
        return Self.joinNotes(fallback, StepNote.clearInputUnverified.text)
    }

    /// clearInput の本体(driver.clearInput → 事後検証 → typeDriver フォールバック → 再検証)。
    /// **clearInput ケースと type の replace 前処理の両方がここを通る**(どのパスなら検証されるかに
    /// 例外を作らない、という既存の規律を replace 経路にも効かせるため)
    func performClearInput(element: ElementInfo, step: FlowStep, actingDriver: AppDriver,
                                   in elements: [ElementInfo],
                                   phase: inout PhaseAccumulator) async throws -> ClearOutcome {
        let clock = ContinuousClock()
        let (before, refreshed) = try await valueBeforeClear(element: element, step: step,
                                                             driver: actingDriver, phase: &phase)
        // 撮り直したなら、その木の番号で撃つ(撮る前の番号はブリッジの新しい表で別の要素を指しうる)
        var actingSnapshot = refreshed?.snapshot
        do {
            let start = clock.now
            try await actingDriver.clearInput(ref: refreshed?.element.ref ?? element.ref)
            phase.actionMs += Self.ms(clock.now - start)
            // 事後検証: ブリッジが 200 を返しても実際に消えていない(嘘の成功)場合の保険。
            // 同じ driver で snapshot を撮り直し、同じ locator を再解決して value を見る
            let check = try await residualClearValue(actingDriver, step: step, before: before, phase: &phase)
            actingSnapshot = check.snapshot ?? actingSnapshot
            if let residual = check.residual {
                guard let td = typeDriver,
                      try await clearViaTypeDriver(td, step: step, phase: &phase) else {
                    return .failed("clearInput reported success but the value remained: \"\(residual)\"")
                }
                if let residual2 = try await residualClearValue(td, step: step,
                                                               before: before,
                                                               phase: &phase).residual {
                    return .failed("clearInput reported success but the value remained: \"\(residual2)\"")
                }
                // 最後に撮ったのは typeDriver(同じブリッジなら actingDriver の表も作り直されている)
                return .cleared(driverFallback: "fell back to XCUITest", actingDriverSnapshot: nil)
            }
            return .cleared(driverFallback: nil, actingDriverSnapshot: actingSnapshot)
        } catch {
            guard DriverError.isClearInputFallback(error), let td = typeDriver else { throw error }
            // **対象が確実に入力欄でないなら撃ち直さない**(type ケースの catch と同じ理由・
            // TypeReadback.isPositivelyNonTextInput の doc)
            if TypeReadback.isPositivelyNonTextInput(element, selfRendered: uiFramework?.isSelfRendered) {
                return .failed(Self.nonTextInputFallbackRefusal(element, in: elements, action: "clearInput"))
            }
            guard try await clearViaTypeDriver(td, step: step, phase: &phase) else { throw error }
            // フォールバック経路も同じ事後検証を通す(**どのパスなら検証されるかに例外を作らない**。
            // 規則が無いと将来の変更で無検証の穴が復活する)
            if let residual = try await residualClearValue(td, step: step,
                                                          before: before, phase: &phase).residual {
                return .failed("clearInput reported success but the value remained: \"\(residual)\"")
            }
            return .cleared(driverFallback: "fell back to XCUITest", actingDriverSnapshot: nil)
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
    /// E2E-CMP/android の S0040 で並列負荷 10 周中 8 周再現:
    /// 空欄の `value` にヒント文字列が載る欄(CMP の `#field_single` は placeholder を送らない)では、
    /// 撃つ前の古い読みが「ヒント」・クリア後も「ヒント」で一致してしまう。
    /// ブリッジ側は撃つ前に `refresh()` してから読むので、**同じノードをブリッジは「入っている」・
    /// snapshot は「空」と読む**のが元の食い違い。
    ///
    /// **キャッシュ迂回でなければならない**(実測):
    /// ブリッジの木で editable ノードだけ `refresh()` する案は、step5 の誤検出を 12/28 → 0/4 に
    /// したが、**木が混世代になり ref の座標が別版のレイアウトを指す**ため、後段の clearInput が
    /// **別の入力欄を消す**退行(step12 が 0/17 → 2/4)を生んで棄却した。`bypassingCache` は
    /// 全ノードを取り直すので木の世代が揃い、この危険が無い。
    ///
    /// 迂回を持たないドライバ(iOS)は解決時の値を使う(費用ゼロ)。
    /// Android は 1 clearInput につき約 +65ms —— 沈黙する誤判定と引き換えなら安い
    /// `refreshed` = 撮り直した木とそこで引き直した要素(撮っていない・引けないときは nil)
    private func valueBeforeClear(element: ElementInfo, step: FlowStep, driver clearDriver: AppDriver,
                                  phase: inout PhaseAccumulator) async throws
        -> (value: String?, refreshed: (element: ElementInfo, snapshot: SnapshotResponse)?) {
        guard clearDriver.supportsCacheBypass else { return (element.value, nil) }
        let clock = ContinuousClock()
        // one-shot なので毎回 arm し直す(elementLimitCeilingLatchedThisStep の doc)
        if elementLimitCeilingLatchedThisStep {
            clearDriver.raiseElementLimitOnNextSnapshot(BridgeAPI.maxSnapshotElementsCeiling)
        }
        let start = clock.now
        let snapshot = try await clearDriver.snapshot(bypassingCache: true)
        phase.snapshotMs += Self.ms(clock.now - start)
        // 撃つ前に消えた/解決できないときは、判定を弱めるより解決時の値を残す
        guard let (found, _) = LocatorResolver.resolve(step: step, in: snapshot) else { return (element.value, nil) }
        return (found.value, (found, snapshot))
    }

    /// clearInput 事後検証: 残っている値(nil = 消えている/判定不能)。
    /// **`placeholder` フィールドとの一致では判定できない**ので「クリア前の値からの変化」で見る:
    /// 空欄の `value` に placeholder 文字列が入る実装があり(iOS 全般 / **Android の CMP は
    /// `placeholder` を送らないまま value に入れる** ―― 実測)、一致判定は素通りする。
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
        guard let (found, _) = LocatorResolver.resolve(step: step, in: snapshot) else { return nil }
        return Self.residualClearValue(before: before, after: found.value,
                                       placeholder: found.placeholder)
    }

    /// clearInput(ref あり)の事後検証: 同じ driver で snapshot を撮り直してから残存値を見る。
    /// **単発では判定しない**(ロケータ解決の再試行と同じ規律で最大3回・計約700ms):
    /// Android の `ACTION_SET_TEXT` は a11y ツリーへの反映が数十〜数百ms遅れ、1発勝負では
    /// 消えているのに古い値を読んで誤検出する(実測。textIs がポーリングで
    /// 吸収しているのと同じ事情)
    /// `snapshot` = 最後に撮った木(呼び手が次に撃つ ref をこの木から引くため)
    private func residualClearValue(_ driver: AppDriver, step: FlowStep, before: String?,
                                    phase: inout PhaseAccumulator) async throws
        -> (residual: String?, snapshot: SnapshotResponse?) {
        let clock = ContinuousClock()
        var backoff = PollBackoff()
        var residual: String?
        var last: SnapshotResponse?
        for attempt in 0..<Self.residualClearAttempts {
            if attempt > 0 {
                let waitStart = clock.now
                try await Task.sleep(for: backoff.nextDelay())
                phase.waitMs += Self.ms(clock.now - waitStart)
            }
            // one-shot なので毎回 arm し直す(elementLimitCeilingLatchedThisStep の doc)
            if elementLimitCeilingLatchedThisStep {
                driver.raiseElementLimitOnNextSnapshot(BridgeAPI.maxSnapshotElementsCeiling)
            }
            let start = clock.now
            let snapshot = try await driver.snapshot(bypassingCache: Self.bypassOnLastAttempt(
                attempt: attempt, driver: driver))
            phase.snapshotMs += Self.ms(clock.now - start)
            last = snapshot
            residual = Self.residualClearValue(step: step, before: before, in: snapshot)
            if residual == nil { return (nil, last) }
        }
        return (residual, last)
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
}
