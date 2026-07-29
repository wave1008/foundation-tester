// StepExecutor+Assert.swift
// executeAssert とその補助(occlusion-guard・失敗メッセージ整形)。挙動上の契約は
// StepExecutor.swift 冒頭のセマンティクス注記を参照。

import Foundation

extension StepExecutor {
    // MARK: - アサーション

    /// [occlusion-guard] ツリー一致した要素を FM でスクショ照合し、覆われ/切れ/減光/不在なら
    /// 偽陽性として反転する失敗ステータスを返す。反転不要(可視 or 判定不能 or 無効)なら nil。
    /// 呼び出し側(exists/textEquals)は覆いを即失敗にせず timeout まで可視化を待つ(poll-until-visible)。
    /// コストは足切り+低インクゲートで抑制(可視な高インク領域は FM を呼ばず nil で即通過)。
    private func occlusionFlip(element: ElementInfo, expectedText: String, elements: [ElementInfo],
                              screen: FTRect, looseMatch: Bool, perStepGuard: Bool?,
                              expectedIsUserText: Bool = false,
                              phase: inout PhaseAccumulator) async throws -> StepResult.Status? {
        // 有効化はステップ指定(DSL の visible())優先、無ければ executor 既定。
        // occlusionGuardEnabled はどちらより上位の実行プロファイル由来マスタースイッチ
        // FMVisionSupport が false(macOS 26)なら FM に画像を渡せないため、スクショを撮る前に素通り。
        guard occlusionGuardEnabled, (perStepGuard ?? occlusionGuard), let delegate,
              FMVisionSupport.isSupported else { return nil }
        // 退化 frame(サイズ 0・クランプで潰れた等)は視覚照合の意味がないのでスキップ(素通り)
        guard element.frame.width >= 1, element.frame.height >= 1, !expectedText.isEmpty else { return nil }
        // 足切り: label が verbatim 描画されない要素(アイコン/画像/絵文字/結合セマンティクス)は
        // FM で約50%誤反転する(実機確認)ため対象外=素通り(pass)。textEquals の期待値は結合規則を外す。
        guard OcclusionEligibility.eligible(type: element.type, label: expectedText,
                                            isUserText: expectedIsUserText).ok else { return nil }
        // 操作を挟まない連続ガードでは直近スクショを再利用(~125ms 削減)。
        let screenshot = try await guardScreenshot(phase: &phase)
        // Tier-0 幾何(ツリーのみ)で疑わしければインク量に関わらず FM へ(部分覆いの取りこぼし対策)。
        let geo = OcclusionSuspicion.geometric(element: element, in: elements, screen: screen,
                                               looseMatch: looseMatch)
        // Tier-1 事前フィルタ: 幾何的に無罪 かつ 領域に明瞭なインクがあれば FM を省略して素通り(pass)。
        // 疑いのある低インク領域(覆い/空/減光)だけ FM に回すことで FM 呼出を大幅削減する。
        if !geo, occlusionInkThreshold > 0,
           let sd = RegionInk.luminanceStdDev(pngData: screenshot, frame: element.frame, screen: screen),
           sd >= occlusionInkThreshold {
            return nil
        }
        guard let v = await delegate.verifyElementVisible(
            expectedText: expectedText, frame: element.frame, screen: screen, screenshotPNG: screenshot)
        else { return nil }
        if v.visible { return nil }
        // observedText は原因切り分けの鍵: 空なら「FM に画像が渡っていない/白紙を見た」
        // (SCA 劣化で添付が落ちる仮説・起動遷移画面)、期待どおりの文字列なら「読めたのに
        // 覆われていると答えた」= 純粋な判定誤り。これが無くて切り分けに窮した(2026-07-23)。
        return .failed("偽陽性(occlusion): ツリー上に存在するが視覚的に見えない [\(v.state)] \(v.reason)"
                       + " observed=\"\(v.observedText)\"")
    }

    /// 失敗メッセージに「対象を覆っているアプリ内要素」を添える(あれば)。
    /// **アプリ内メッセージ・モーダルの検出はこれが唯一の手段**(同一プロセスなので
    /// AndroidForegroundWindows では捕まらない)。FM が落ちていても効く幾何判定。
    /// 過検出寄りなので**判定は変えず、文言を足すだけ**にする(ステップの成否には触らない)
    static func coveringHint(element: ElementInfo?, elements: [ElementInfo], screen: FTRect) -> String {
        guard let element,
              let cover = OcclusionSuspicion.covering(element: element, in: elements, screen: screen)
        else { return "" }
        let label = cover.identifier.map { "#\($0)" } ?? cover.label.map { "\"\($0)\"" } ?? cover.type
        return "(対象は \(label) に覆われています。操作がそこへ吸われた可能性があります)"
    }

    /// スナップショットが上限で打ち切られていたときの注記。**要素数の上限に当たると
    /// 「見つかりません」と区別が付かない**(実在するのに送られていないだけ)ため、
    /// 失敗文言に必ず添える。WebView は1画面に要素が数百並ぶことがあり最も当たりやすい
    static func truncationHint(_ snapshot: SnapshotResponse?) -> String {
        guard let snapshot, snapshot.truncatedCount > 0 else { return "" }
        let webView = snapshot.elements.contains { $0.type == "webView" }
            ? "。WebView 画面では中身の要素が多く、上限に当たりやすいです(スコープを `.webView >> ...` で絞るか、対象の近くまでスクロールしてください)"
            : ""
        return "(スナップショットは \(snapshot.elements.count) 要素で打ち切られています"
            + "。あと \(snapshot.truncatedCount) 要素が省かれました\(webView))"
    }

    /// WebView 画面での失敗に「どの経路で読んだ画面か」を添える。
    ///
    /// **DOM 経路の未検出は無反応タップとして現れる**: 合成タッチが interop(Compose/Flutter 等)に
    /// 横取りされてもタップは成功として記録され、2ステップ先の検証が別の文言で落ちる。
    /// 原因が離れているので、失敗した側に経路を書いておかないと追跡コストが跳ね上がる。
    /// 目印(`WebViewDOM.isInteropHosted`)は React Native / Capacitor / Flutter のクラス名変更で
    /// いつでも取りこぼし得るため、この注記は「目印が正しい間も」必要。
    static func webViewPathHint(_ snapshot: SnapshotResponse?) -> String {
        // **要素の形から推測しない**。Android は webView 型を出すが web フラグを持たないため、
        // 推測すると「XCUITest へ委譲」と名乗って Android のデバッグを誤誘導する(2026-07-29 実害)。
        // 申告が無いドライバ(Android・engine=xcuitest 単独・旧ブリッジ)では何も足さない
        switch snapshot?.webViewPath {
        case "dom":
            return "(WebView の中身は DOM 経路で読みました。タップは DOM の矩形へ合成タッチで打つため、"
                + "interop 越しに埋め込まれた WebView では**無反応でも成功として記録されます**。"
                + "直前の操作が効いていない可能性を疑ってください)"
        case "delegated":
            return "(WebView の中身は XCUITest へ委譲して読みました)"
        default:
            return ""
        }
    }

    /// assert ディスパッチャ。判定ロジックはグループ単位の executeAssert* へ切り出し、ここは
    /// 振り分けだけ行う。
    func executeAssert(_ assert: String, step: FlowStep,
                       phase: inout PhaseAccumulator) async throws -> StepResult.Status {
        switch assert {
        case "exists":
            return try await executeAssertExists(step: step, phase: &phase)
        case "valueEquals", "textEquals", "textContains", "textMatches",
             "textStartsWith", "textEndsWith", "textMatchesDateFormat",
             "valueContains", "valueMatches", "valueStartsWith", "valueEndsWith",
             "valueMatchesDateFormat", "idEquals":
            return try await executeAssertTextComparison(assert, step: step, phase: &phase)
        case "notExists":
            return try await executeAssertNotExists(step: step, phase: &phase)
        case "textNotEquals", "textIsEmpty", "textIsNotEmpty",
             "textStartsWithNot", "textContainsNot", "textEndsWithNot", "textMatchesNot",
             "valueNotEquals", "valueIsEmpty", "valueIsNotEmpty",
             "valueStartsWithNot", "valueContainsNot", "valueEndsWithNot", "valueMatchesNot":
            return try await executeAssertNegativeTextComparison(assert, step: step, phase: &phase)
        case "enabled", "disabled":
            return try await executeAssertEnabledDisabled(assert, step: step, phase: &phase)
        case "checked", "notChecked":
            return try await executeAssertChecked(assert, step: step, phase: &phase)
        case "count":
            return try await executeAssertCount(step: step, phase: &phase)
        case "screenMatches":
            return try await executeAssertScreenMatches(step: step, phase: &phase)
        default:
            return .skipped("未知のアサーション: \(assert)")
        }
    }

    private func executeAssertExists(step: FlowStep,
                                     phase: inout PhaseAccumulator) async throws -> StepResult.Status {
        let clock = ContinuousClock()
        // `exist(scroll:)` の内蔵探索(アクション側と同じ理由で別ステップにしない)
        if step.direction != nil, step.locator != nil {
            let result = try await runScrollSearch(step: step, phase: &phase)
            scrollSearchNote = Self.scrollSearchNote(result)
            guard result.found else { return .failed(Self.scrollNotFoundMessage(step)) }
        }
        let deadline = Date().addingTimeInterval(step.timeout ?? 5)
        var backoff = PollBackoff()
        var primaryMisses = 0
        // occlusion-guard: 要素が見つかっても覆われている場合、過渡的オーバーレイ(ローディング/
        // スナックバー等)が消えるのを timeout まで待ってから失敗にする(即失敗の脆さを回避)。
        // 最後に観測した occlusion 失敗を保持し、可視化されなければこれを返す。
        var lastOcclusion: StepResult.Status?
        var lastSnapshot: SnapshotResponse?
        // timeout==0 でも初回照会は必ず1回行う(ループ後段の deadline チェックで離脱)。
        while true {
            var start = clock.now
            var snapshot = try await driver.snapshot()
            phase.snapshotMs += Self.ms(clock.now - start)
            try await dismissInterruption(in: &snapshot, phase: &phase)
            lastSnapshot = snapshot
            // アサーションでは type+index のみのフォールバックを使わない。
            // 別画面の無関係な要素にマッチして偽陽性になる(実測済み)
            if let d = Self.resolveDetailed(step: step, in: snapshot, strictForAssert: true) {
                if let flip = try await occlusionFlip(
                    element: d.element, expectedText: d.element.label ?? step.locator?.label ?? "",
                    elements: snapshot.elements, screen: snapshot.screen,
                    looseMatch: d.quality == .substring, perStepGuard: step.occlusionGuard,
                    // #4: label セレクタ一致はユーザー期待値。結合ラベル `, ` 規則を当てず
                    // exist("Hello, World") でガードがスキップされる欠陥を防ぐ(textEquals と同契約)。
                    expectedIsUserText: step.locator?.label != nil, phase: &phase) {
                    lastOcclusion = flip   // 覆われている: 可視化を待つ(下の sleep へ)
                } else {
                    resolvedElementThisStep = d.element
                    if let fallback = d.usedFallback { return .passedViaFallback(fallback) }
                    return .passed
                }
            } else {
                lastOcclusion = nil   // #5: 直近は未発見 → 過去の occlusion 失敗を無効化(消失時に stale を返さない)
                primaryMisses += 1
                // fallback(SystemUIDriver)の snapshot は springboard 再session+XCUITest snapshot で
                // 数百ms。primary(in-app ~0.05ms)ミス毎に払うと通常のアプリ内要素待ちを支配するため
                // 間引く: 2・4・6…回目のミスでのみ照会。実在するシステムUI要素の検知遅れは最大で
                // バックオフ1段+1周期
                if primaryMisses >= 2, primaryMisses % 2 == 0, let fb = fallbackDriver {
                    start = clock.now
                    let fsnap = try await fb.snapshot()
                    phase.snapshotMs += Self.ms(clock.now - start)
                    if let (element, fallback) = Self.resolve(step: step, in: fsnap, strictForAssert: true) {
                        resolvedElementThisStep = element
                        if let fallback { return .passedViaFallback(fallback) }
                        return .passed
                    }
                }
            }
            if Date() >= deadline { break }   // 初回照会後にここで離脱(timeout==0 も含む)
            start = clock.now
            try await Task.sleep(for: backoff.nextDelay())
            phase.waitMs += Self.ms(clock.now - start)
            cachedScreenshot = nil   // 待機中に画面が変わり得る → 次周回は取り直す
        }
        // timeout: 覆われ続けた occlusion があればそれを、無ければ未発見を返す
        if let lastOcclusion { return lastOcclusion }
        return .failed("要素が見つかりません: \(step.locatorSummary)(timeout \(FTSeconds.format(step.timeout ?? 5))s)"
                       + Self.truncationHint(lastSnapshot)
                       + Self.webViewPathHint(lastSnapshot))
    }

    private func executeAssertTextComparison(
        _ assert: String, step: FlowStep,
        phase: inout PhaseAccumulator) async throws -> StepResult.Status {
        let clock = ContinuousClock()
        guard let expected = step.expected else {
            return .skipped("expected が未指定")
        }
        let deadline = Date().addingTimeInterval(step.timeout ?? 5)
        var lastActual: String?
        var found = false
        var backoff = PollBackoff()
        var primaryMisses = 0
        var lastOcclusion: StepResult.Status?   // occlusion-guard: 可視化待ち(exists と同契約)
        // 失敗メッセージに「覆っている要素」を添えるための直近の観測(coveringHint 参照)
        var lastElement: ElementInfo?
        var lastElements: [ElementInfo] = []
        var lastScreen = FTRect(x: 0, y: 0, width: 0, height: 0)
        /// 失敗文言に WebView の経路を添えるために最後のスナップショットを保持する
        var lastSnapshot: SnapshotResponse?
        // timeout==0 でも初回照会は必ず1回行う(ループ後段の deadline チェックで離脱)。
        while true {
            var start = clock.now
            var snapshot = try await driver.snapshot()
            phase.snapshotMs += Self.ms(clock.now - start)
            try await dismissInterruption(in: &snapshot, phase: &phase)
            lastSnapshot = snapshot
            var candidate = Self.resolve(step: step, in: snapshot, strictForAssert: true)
            var fromFallbackDriver = false
            if candidate == nil { primaryMisses += 1 }
            // driver フォールバック(ハイブリッド): primary で見つからなければシステム UI を確認。
            // 間引きの契約は exists ケース参照
            if candidate == nil, primaryMisses >= 2, primaryMisses % 2 == 0,
               let fb = fallbackDriver {
                start = clock.now
                let fsnap = try await fb.snapshot()
                phase.snapshotMs += Self.ms(clock.now - start)
                candidate = Self.resolve(step: step, in: fsnap, strictForAssert: true)
                fromFallbackDriver = candidate != nil
            }
            if let (element, fallback) = candidate {
                found = true
                // id は画面に描かれないので occlusion-guard は掛からない(DSL 側が
                // occlusionGuard: false を立てる)
                let actual = assert == "idEquals" ? element.identifier
                    : (assert.hasPrefix("value") ? element.value : element.label)
                lastActual = actual
                lastElement = element
                lastElements = snapshot.elements
                lastScreen = snapshot.screen
                // 一致したテキスト。occlusion-guard には**実際に一致した文字列**を渡す
                // (textMatches の期待値は正規表現で、そのまま画面と照合しても意味がないため)
                let matched = Self.matchedText(actual, expected: expected, assert: assert)
                if let expectedForGuard = matched {
                    // ロケータを label 指定していて実 label と不一致=部分一致で掴んだ疑い
                    let loose = step.locator?.label != nil && element.label != step.locator?.label
                    // フォールバックドライバ(システムUI/springboard)由来の要素は primary の座標系・
                    // スクショと食い違うためガードを掛けない(exist の fsnap 経路と同契約)。
                    if fromFallbackDriver {
                        resolvedElementThisStep = element
                        if let fallback { return .passedViaFallback(fallback) }
                        return .passed
                    }
                    if let flip = try await occlusionFlip(
                        element: element, expectedText: expectedForGuard,
                        elements: snapshot.elements, screen: snapshot.screen,
                        looseMatch: loose, perStepGuard: step.occlusionGuard,
                        expectedIsUserText: true, phase: &phase) {
                        lastOcclusion = flip   // 覆われている: 可視化を待つ
                    } else {
                        resolvedElementThisStep = element
                        if let fallback { return .passedViaFallback(fallback) }
                        return .passed
                    }
                } else {
                    lastOcclusion = nil   // 直近の観測はテキスト不一致 → 過去の occlusion 失敗は無効化
                }
            } else {
                lastOcclusion = nil   // #5: 要素未発見 → 過去の occlusion 失敗を無効化(消失時に stale を返さない)
            }
            if Date() >= deadline { break }   // 初回照会後にここで離脱(timeout==0 も含む)
            start = clock.now
            try await Task.sleep(for: backoff.nextDelay())
            phase.waitMs += Self.ms(clock.now - start)
            cachedScreenshot = nil   // 待機中に画面が変わり得る → 次周回は取り直す
        }
        if let lastOcclusion { return lastOcclusion }   // 覆われ続けた
        let subject = assert == "idEquals" ? "id"
            : (assert.hasPrefix("value") ? "値" : "テキスト")
        let relation = Self.textMismatchRelation(assert)
        return found
            ? .failed("\(subject)\(relation): 期待 \"\(expected)\"、実際 \"\(lastActual ?? "nil")\""
                      + Self.coveringHint(element: lastElement, elements: lastElements,
                                          screen: lastScreen)
                      + Self.webViewPathHint(lastSnapshot))
            : .failed("要素が見つかりません: \(step.locatorSummary)"
                      + Self.webViewPathHint(lastSnapshot))
    }

    /// executeAssertTextComparison の失敗文言用: 期待した関係のどれに反したかを表す語尾。
    /// 純粋関数(判定ロジックとは無関係。単体テストしやすいよう分離)。
    private static func textMismatchRelation(_ assert: String) -> String {
        switch assert {
        case "textContains": return "を含みません"
        case "textMatches": return "に一致しません(正規表現)"
        case "textStartsWith", "valueStartsWith": return "で始まりません"
        case "textEndsWith", "valueEndsWith": return "で終わりません"
        case "textMatchesDateFormat", "valueMatchesDateFormat":
            return "が日付書式に一致しません"
        case "valueContains": return "を含みません"
        case "valueMatches": return "に一致しません(正規表現)"
        default: return "が一致しません"
        }
    }

    private func executeAssertNotExists(step: FlowStep,
                                        phase: inout PhaseAccumulator) async throws -> StepResult.Status {
        let clock = ContinuousClock()
        // 「消えるまで待つ」。初回で不在なら即 pass、在るならタイムアウトまで消滅を待つ。
        // 可視性(occlusion)は見ない: ツリーから消えたことが唯一の判定。
        let deadline = Date().addingTimeInterval(step.timeout ?? 5)
        var backoff = PollBackoff()
        while true {
            let start = clock.now
            var snapshot = try await driver.snapshot()
            phase.snapshotMs += Self.ms(clock.now - start)
            try await dismissInterruption(in: &snapshot, phase: &phase)
            if Self.resolve(step: step, in: snapshot, strictForAssert: true) == nil {
                // primary で不在 = pass だが、hybrid ではシステム UI(別プロセスのダイアログ)が
                // primary の snapshot に映らない。不在を確定する側でだけ fallbackDriver を1回照会する
                // (pass 経路の固定費 1 回のみ。miss 毎に払う exists 側の間引きとは事情が逆)
                if let fb = fallbackDriver {
                    let fbStart = clock.now
                    let fsnap = try await fb.snapshot()
                    phase.snapshotMs += Self.ms(clock.now - fbStart)
                    if Self.resolve(step: step, in: fsnap, strictForAssert: true) != nil {
                        if Date() >= deadline {
                            return .failed("要素がまだ存在します(システム UI): \(step.locatorSummary)")
                        }
                        let waitStart = clock.now
                        try await Task.sleep(for: backoff.nextDelay())
                        phase.waitMs += Self.ms(clock.now - waitStart)
                        continue
                    }
                }
                return .passed
            }
            if Date() >= deadline { break }
            let waitStart = clock.now
            try await Task.sleep(for: backoff.nextDelay())
            phase.waitMs += Self.ms(clock.now - waitStart)
        }
        return .failed("要素がまだ存在します: \(step.locatorSummary)(timeout \(FTSeconds.format(step.timeout ?? 5))s)")
    }

    private func executeAssertNegativeTextComparison(
        _ assert: String, step: FlowStep,
        phase: inout PhaseAccumulator) async throws -> StepResult.Status {
        let clock = ContinuousClock()
        // 否定・空判定は occlusion-guard を掛けない(「見えていないこと」は画面照合できない)。
        // 要素自体は在ることが前提で、タイムアウトまでテキストの変化を待つ
        // Empty 系だけが期待値を取らない(それ以外で未指定なら空文字と比べて必ず落ちる)
        if !assert.hasSuffix("IsEmpty"), !assert.hasSuffix("IsNotEmpty"),
           step.expected == nil {
            return .skipped("expected が未指定")
        }
        let deadline = Date().addingTimeInterval(step.timeout ?? 5)
        var backoff = PollBackoff()
        var found = false
        var lastActual: String?
        var lastElement: ElementInfo?
        var lastElements: [ElementInfo] = []
        var lastScreen = FTRect(x: 0, y: 0, width: 0, height: 0)
        while true {
            let start = clock.now
            var snapshot = try await driver.snapshot()
            phase.snapshotMs += Self.ms(clock.now - start)
            try await dismissInterruption(in: &snapshot, phase: &phase)
            if let (element, fallback) = Self.resolve(step: step, in: snapshot,
                                                      strictForAssert: true) {
                found = true
                let actual = assert.hasPrefix("value") ? element.value : element.label
                lastActual = actual
                lastElement = element
                lastElements = snapshot.elements
                lastScreen = snapshot.screen
                let satisfied = Self.negativeAssertSatisfied(assert, actual: actual,
                                                              expected: step.expected)
                if satisfied {
                    if let fallback { return .passedViaFallback(fallback) }
                    return .passed
                }
            }
            if Date() >= deadline { break }
            let waitStart = clock.now
            try await Task.sleep(for: backoff.nextDelay())
            phase.waitMs += Self.ms(clock.now - waitStart)
        }
        guard found else { return .failed("要素が見つかりません: \(step.locatorSummary)") }
        let hint = Self.coveringHint(element: lastElement, elements: lastElements,
                                     screen: lastScreen)
        let subject = assert.hasPrefix("value") ? "値" : "テキスト"
        switch assert {
        case "textIsEmpty", "valueIsEmpty":
            return .failed("\(subject)が空ではありません: 実際 \"\(lastActual ?? "nil")\"" + hint)
        case "textIsNotEmpty", "valueIsNotEmpty":
            return .failed("\(subject)が空です: \(step.locatorSummary)" + hint)
        default:
            // 否定の種類ごとに何が成立してしまったのかを書く(「条件不成立」だけだと
            // 期待値のどの関係で引っかかったのか読めない)
            let expected = step.expected ?? ""
            let relation = Self.negativeAssertViolationRelation(assert, expected: expected)
            return .failed("\(subject)が\(relation): 実際 \"\(lastActual ?? "nil")\"" + hint)
        }
    }

    /// executeAssertNegativeTextComparison の失敗文言用: `*Not` 系のどの関係が成立してしまったか。
    /// 純粋関数(判定ロジックとは無関係。単体テストしやすいよう分離)。
    private static func negativeAssertViolationRelation(_ assert: String, expected: String) -> String {
        switch assert {
        case "textContainsNot", "valueContainsNot": return "\"\(expected)\" を含んでいます"
        case "textStartsWithNot", "valueStartsWithNot":
            return "\"\(expected)\" で始まっています"
        case "textEndsWithNot", "valueEndsWithNot": return "\"\(expected)\" で終わっています"
        case "textMatchesNot", "valueMatchesNot":
            return "正規表現 \"\(expected)\" に一致しています"
        default: return "一致しています"
        }
    }

    private func executeAssertEnabledDisabled(
        _ assert: String, step: FlowStep,
        phase: inout PhaseAccumulator) async throws -> StepResult.Status {
        let clock = ContinuousClock()
        let wantEnabled = assert == "enabled"
        let deadline = Date().addingTimeInterval(step.timeout ?? 5)
        var backoff = PollBackoff()
        var found = false
        while true {
            let start = clock.now
            var snapshot = try await driver.snapshot()
            phase.snapshotMs += Self.ms(clock.now - start)
            try await dismissInterruption(in: &snapshot, phase: &phase)
            if let (element, fallback) = Self.resolve(step: step, in: snapshot,
                                                      strictForAssert: true) {
                found = true
                if element.enabled == wantEnabled {
                    resolvedElementThisStep = element
                    if let fallback { return .passedViaFallback(fallback) }
                    return .passed
                }
            }
            if Date() >= deadline { break }
            let waitStart = clock.now
            try await Task.sleep(for: backoff.nextDelay())
            phase.waitMs += Self.ms(clock.now - waitStart)
        }
        return found
            ? .failed("要素は\(wantEnabled ? "無効" : "有効")です: \(step.locatorSummary)")
            : .failed("要素が見つかりません: \(step.locatorSummary)")
    }

    private func executeAssertChecked(
        _ assert: String, step: FlowStep,
        phase: inout PhaseAccumulator) async throws -> StepResult.Status {
        let clock = ContinuousClock()
        // checked は true のときだけブリッジが送る(省略 = オフ / 状態を持たない要素)。
        // 「状態が違う」と「見つからない」を別メッセージにするのは enabled と同じ規律
        let wantChecked = assert == "checked"
        let deadline = Date().addingTimeInterval(step.timeout ?? 5)
        var backoff = PollBackoff()
        var found = false
        while true {
            let start = clock.now
            var snapshot = try await driver.snapshot()
            phase.snapshotMs += Self.ms(clock.now - start)
            try await dismissInterruption(in: &snapshot, phase: &phase)
            if let (element, fallback) = Self.resolve(step: step, in: snapshot,
                                                      strictForAssert: true) {
                found = true
                // ブリッジは true のときだけ送る = 観測できたのは「オンだった」ときだけ
                if element.checked == true { observedCheckedThisStep = true }
                if (element.checked == true) == wantChecked {
                    resolvedElementThisStep = element
                    if let fallback { return .passedViaFallback(fallback) }
                    return .passed
                }
            }
            if Date() >= deadline { break }
            let waitStart = clock.now
            try await Task.sleep(for: backoff.nextDelay())
            phase.waitMs += Self.ms(clock.now - waitStart)
        }
        return found
            ? .failed("要素は\(wantChecked ? "オフ" : "オン")です: \(step.locatorSummary)")
            : .failed("要素が見つかりません: \(step.locatorSummary)")
    }

    private func executeAssertCount(step: FlowStep,
                                    phase: inout PhaseAccumulator) async throws -> StepResult.Status {
        let clock = ContinuousClock()
        guard let expectedCount = step.expectedCount else {
            return .skipped("expectedCount が未指定")
        }
        guard let locator = step.locator else {
            return .skipped("ロケータが未指定")
        }
        // `||` は**候補集合の和**(Shirates 準拠)。全節の候補を合わせ、同じ要素は1度だけ数える。
        // 節の優先順位が効くのは要素を1つ選ぶときだけで、数えるときは節を跨いで合計する
        let chain = [locator] + (step.fallbacks ?? [])
        let deadline = Date().addingTimeInterval(step.timeout ?? 5)
        var backoff = PollBackoff()
        var actual = 0
        var breakdown: [(clause: FlowLocator, elements: [ElementInfo])] = []
        var nestingHint = ""
        while true {
            let start = clock.now
            var snapshot = try await driver.snapshot()
            phase.snapshotMs += Self.ms(clock.now - start)
            try await dismissInterruption(in: &snapshot, phase: &phase)
            breakdown = Self.unionByClause(chain, elements: snapshot.elements)
            actual = breakdown.reduce(0) { $0 + $1.elements.count }
            nestingHint = Self.nestingHint(breakdown.flatMap(\.elements),
                                           in: snapshot.elements)
            if actual == expectedCount { return .passed }
            if Date() >= deadline { break }
            let waitStart = clock.now
            try await Task.sleep(for: backoff.nextDelay())
            phase.waitMs += Self.ms(clock.now - waitStart)
        }
        // 節が複数あるときは**どの節が何件拾ったか**まで出す。和集合の総数だけだと
        // 「どれが想定より多く拾ったのか」が分からず、セレクタを直すのに snapshot を
        // 取り直す往復が要る(実例: ラベルで数えてボタンの内側の Text も拾っていた)
        let detail = breakdown.count > 1
            ? "内訳: " + breakdown.map { "\($0.clause.summary) \($0.elements.count)件" }
                .joined(separator: " / ")
            : step.locatorSummary
        return .failed("個数が一致しません: 期待 \(expectedCount)、実際 \(actual)(\(detail))"
                       + nestingHint)
    }

    private func executeAssertScreenMatches(
        step: FlowStep, phase: inout PhaseAccumulator) async throws -> StepResult.Status {
        let clock = ContinuousClock()
        guard screenIsEnabled else {
            return .skipped("screenIs が無効(実行プロファイルの設定)")
        }
        guard let expected = step.expected, !expected.isEmpty else {
            return .skipped("expected が未指定")
        }
        guard let delegate else {
            return .skipped("FM 検証が無効(Foundation Models 利用不可)")
        }
        // スクショを撮る前に落とす(画像を渡せない環境では検証自体が成立しない)
        guard FMVisionSupport.isSupported else {
            return .skipped("画面検証が無効(\(FMVisionSupport.requirement))")
        }
        var start = clock.now
        var screenshot = try await driver.screenshot()
        phase.actionMs += Self.ms(clock.now - start)
        // 白フレーム(画面凍結)を FM 検証に渡すと必ず不一致で誤失敗するため、リトライで回復を待つ
        if BlankFrameDetector.isUniformBlank(pngData: screenshot) {
            for _ in 0..<2 {
                try await Task.sleep(nanoseconds: 2_000_000_000)
                start = clock.now
                let retry = try await driver.screenshot()
                phase.actionMs += Self.ms(clock.now - start)
                screenshot = retry
                if !BlankFrameDetector.isUniformBlank(pngData: retry) { break }
            }
            if BlankFrameDetector.isUniformBlank(pngData: screenshot) {
                onDeviceFrozen?()
                return .skipped("画面凍結(白フレーム)のため中断・別デバイスへ振り直し")
            }
        }
        guard let verdict = await delegate.verifyScreen(expected: expected, screenshotPNG: screenshot) else {
            return .skipped("画面検証を実行できませんでした")
        }
        if verdict.pass { return .passed }
        return .failed("画面が期待と一致しません: \(verdict.reason)")
    }
}
