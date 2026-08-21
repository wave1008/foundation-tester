// StepExecutor+Assert.swift
// executeAssert とその補助(occlusion-guard・失敗メッセージ整形)。挙動上の契約は
// StepExecutor.swift 冒頭のセマンティクス注記を参照。

import Foundation

/// キャッシュを捨てた snapshot でもう1周だけ確かめる仕掛け。撃つ場面が**2つ**ある。
/// Android の a11y ツリーは IME 等が前面のとき数秒古い値を返し続ける
/// (docs/verification.md「ブリッジの『偽陰性』を疑う手順」)。
/// 対応しないドライバ(iOS 系。鮮度問題を持たない)ではどちらも行わず周回を増やさない。
///
/// - `arm`: **失敗と決める前**(期限切れ)。アプリは正しいのに検証だけが落ちるのを防ぐ。
///   誤った**失敗**を潰す側で、通るアサーションは1円も払わない
/// - `confirmPass`: **否定形を通す前**。古い木は「まだ現れていない」姿を返すので、
///   不在・不一致での pass は**誤った成功**になりうる(2026-08-14 の掃討で発見)。
///   肯定形が同じ穴を持たないのは、古い木が期待値に一致せずポーリングが続くから ——
///   つまり肯定形は運で守られているだけで、**否定形だけが通る側にも払う必要がある**
///
/// **予算は別々に持つ**(片方を使っても他方は残る)。共有にすると、pass の確認で使い切った
/// アサーションが期限切れ時に取り直せず、塞いだ穴の隣に誤った失敗を作る
struct AssertFreshRetry {
    private var failUsed = false
    private var passUsed = false
    private var armed = false

    /// 期限到達時に呼ぶ。true なら「取り直してもう1周」
    mutating func arm(ifSupported supported: Bool) -> Bool {
        guard supported, !failUsed else { return false }
        failUsed = true
        armed = true
        return true
    }

    /// **否定形が pass を返す直前**に呼ぶ。true なら「取り直して確かめ直す」。
    /// 1アサーションにつき1回だけなので、確認の周で再び pass に達したらそのまま通る
    mutating func confirmPass(ifSupported supported: Bool) -> Bool {
        guard supported, !passUsed else { return false }
        passUsed = true
        armed = true
        return true
    }

    /// snapshot 取得時に呼ぶ。arm/confirmPass した直後の1周だけ true
    mutating func takeArmed() -> Bool {
        defer { armed = false }
        return armed
    }
}

extension StepExecutor {
    // MARK: - アサーション

    /// [occlusion-guard] ツリー一致した要素を FM でスクショ照合し、覆われ/切れ/減光/不在なら
    /// 偽陽性として反転する失敗ステータスを返す。反転不要(可視 or 判定不能 or 無効)なら nil。
    /// 呼び出し側(exists/textEquals)は覆いを即失敗にせず timeout まで可視化を待つ(poll-until-visible)。
    /// コストは足切り+低インクゲートで抑制(可視な高インク領域は FM を呼ばず nil で即通過)。
    func occlusionFlip(element: ElementInfo, expectedText: String, elements: [ElementInfo],
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
        let captured = try await guardScreenshot(phase: &phase)
        var screenshot = captured.data
        // [StaleFrameDetector] キャッシュ供給(同一 Data 使い回し)は判定しない —— 供給元が
        // guardScreenshot 自身なので比較すると木のわずかな揺れで必ず偽 stale になる(guardScreenshot 参照)。
        // 新規撮影のときだけ「木は変わったのに絵が前回とバイト同一」を確認し、疑いなら1回だけ撮り直す。
        // それでも stale なら古い絵を根拠に偽陽性反転を宣言せず素通りする(flip しない)。
        if captured.freshlyCaptured {
            // **両方の判定を同じ元の baseline に対して行う**(2回目の判定を1回目の record に対して
            // 行うと、elements はこの呼び出し内で不変なので treeFingerprint が必ず一致し
            // 「撮り直しても stale のまま」が原理的に起こり得なくなる)。
            let baseline = lastGuardFrameRecord
            let (record, isStale) = StaleFrameDetector.judge(
                png: screenshot, elements: elements, previous: baseline)
            lastGuardFrameRecord = record
            if isStale {
                invalidateScreenshotCache()
                let retaken = try await guardScreenshot(phase: &phase)
                let (record2, stillStale) = StaleFrameDetector.judge(
                    png: retaken.data, elements: elements, previous: baseline)
                lastGuardFrameRecord = record2
                if stillStale {
                    noteCodesThisStep.insert(.staleScreenshot)
                    return nil
                }
                screenshot = retaken.data
            }
        }
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
        return .failed("false positive (occlusion): present in the tree but not visually visible [\(v.state)] \(v.reason)"
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
        // **`TapTargetGeometry.describe` と同じ「名指し」**(2026-08-15)。失敗文言に混ぜる
        // 説明であって、読み手がそのまま貼れるセレクタである保証はしない(エスケープ未対応)
        let label = cover.identifier.map { "#\($0)" } ?? cover.label.map { "\"\($0)\"" } ?? cover.type
        return " (the target is covered by \(label); the interaction may have been swallowed by it)"
    }

    /// スナップショットが上限で打ち切られていたときの注記。**要素数の上限に当たると
    /// 「見つかりません」と区別が付かない**(実在するのに送られていないだけ)ため、
    /// 失敗文言に必ず添える。WebView は1画面に要素が数百並ぶことがあり最も当たりやすい。
    ///
    /// **残っている手の判定は `SnapshotTruncation.remedy`(MCP と共有)**。以前ここだけが
    /// 「対象に近づくようスクロールする」と勧めており、同じ事実に対して MCP は
    /// 「スクロールしても戻ってこない」と書いていた —— 打ち切りは配列からの脱落なので
    /// MCP のほうが正しく、この助言は読み手に空振りの探索を撃たせる(2026-08-15 に統一)。
    /// 文言(スコープの絞り方)は DSL の語彙で持つ
    static func truncationHint(_ snapshot: SnapshotResponse?) -> String {
        guard let snapshot, let remedy = SnapshotTruncation.remedy(for: snapshot) else { return "" }
        // **実行側が何をしたかは書かない**(2026-08-15)。「天井で撮り直してある」と書きたく
        // なるが、撮り直すのは**解決できなかったとき**だけで、要素は見つかったが覆われていた
        // 周回ではその文が嘘になる。書いてよいのは木から読み取れる事実と、読み手にできる手だけ
        let ceiling = remedy == .narrowTheScreen
            ? " even at the \(BridgeAPI.maxSnapshotElementsCeiling)-element ceiling" : ""
        // WebView は文脈として残す(この上限に最も当たりやすい画面がどれかは有用)。
        // **`.webView >> ...` でスコープを狭めることは勧めない** —— あれは照合の範囲であって
        // スナップショットの母数ではないので、打ち切りには1件も効かない
        let webView = snapshot.elements.contains { $0.type == "webView" }
            ? " WebView screens hold many elements and hit this limit easily." : ""
        // **スクロールを勧めない**: 落ちた要素は配列から抜けているので、スクロールしても戻らない
        // **`elements.count` を印字しない**(SnapshotTruncation.budgetedCount のレビュー参照):
        // bulk 群は予算の外で送られるので、生の件数は勧める上限より大きく見え、読み手には
        // 矛盾に映る。予算ぶんの件数(budgetedCount)を出し、bulk が居るときだけ内訳を添える
        let budgeted = SnapshotTruncation.budgetedCount(snapshot)
        let bulk = SnapshotTruncation.bulkExemptPresentCount(snapshot)
        let bulkClause = bulk > 0 ? " (plus \(bulk) bulk-exempt elements outside the budget)" : ""
        return " (the snapshot was truncated at \(budgeted) elements\(bulkClause);"
            + " \(snapshot.truncatedCount) more were omitted\(ceiling) — they are gone from the"
            + " tree, not just off screen, so scrolling will not bring them back.\(webView)"
            + " Narrow the screen before this step (close a sheet, collapse a long list) so fewer"
            + " elements compete for the limit)"
    }

    /// **切り詰められた木で「不在」を結論にしない**ための撮り直し(2026-08-15)。
    ///
    /// 要素数の上限(`BridgeAPI.maxSnapshotElements`)は **LLM の読み手が読み切れる量**として
    /// 決めた値で、上限を引き上げるのは MCP だけ。**読み手の居ない DSL のシナリオ実行も同じ木を
    /// 受け取る**ので、密な画面(WebView・地図・長いリスト)では実在する要素が間引かれる。
    /// 間引かれた要素は木の上で「存在しない要素」と1文字も違わない = 否定判定
    /// (notExists / count)がそのまま**誤った成功**になる。
    ///
    /// 切り詰められていなければ**撮らない**(通る側の固定費はゼロ)。
    /// **呼び手は1回当たったら以後の周を最初から天井で撮ること**(`needsCeiling` の latch)——
    /// 毎周2枚払わずに済むうえ、判定に使う木が常に天井のものになるので
    /// 「天井でも足りなかった」という文言が嘘にならない(2026-08-15 のデバイス実行で
    /// 予算方式の文言が実際に嘘をついた)
    func retakenAtElementLimitCeiling(_ snapshot: SnapshotResponse,
                                      phase: inout PhaseAccumulator) async throws -> SnapshotResponse {
        guard snapshot.truncatedCount > 0 else { return snapshot }
        // 既に天井で読まれた木なら、上げて撮り直しても同じ木が返るだけ(1枚ぶんのデバイス I/O)。
        // 呼び手のラッチはそのまま立ってよい(以後の arm は同じ上限なので無害)
        guard !SnapshotTruncation.isAtCeiling(snapshot) else { return snapshot }
        let clock = ContinuousClock()
        let start = clock.now
        driver.raiseElementLimitOnNextSnapshot(BridgeAPI.maxSnapshotElementsCeiling)
        var full = try await driver.snapshot()
        phase.snapshotMs += Self.ms(clock.now - start)
        try await dismissInterruption(in: &full, phase: &phase)
        return full
    }

    /// **空の WebView で判定したことを黙らない**(2026-08-15)。委譲した WebView が中身を出さない
    /// まま待ちの上限に達した木では、「無い」と「まだ公開されていない」を区別できない。
    /// 判定は変えない(区別できないものを失敗にすると空ページの検証が書けなくなる)ので、
    /// **通った回にも残る機械可読な注記**にする —— 黙ると、空の木で成立した不在が後から見分けられない
    func noteEmptyWebView(_ snapshot: SnapshotResponse) {
        if snapshot.webViewPath == WebViewPath.delegatedEmpty {
            noteCodesThisStep.insert(.webViewNotRendered)
        }
    }

    /// **木が画面を代表していない疑いを黙らない**(2026-08-15)。`noteEmptyWebView` は
    /// ドライバ申告の「委譲した WebView が空」しか見ないので、**中身が部分的にしか公開されない**
    /// 形(Android の Chrome)と、**webView 容器すら出ない**形をどちらも取り逃がす。
    /// 判定は `FTCore.TreeCoverage`(MCP の webViewGapNote / missingPageContentNote と共有)。
    ///
    /// **注記だけで判定は変えない**: 打ち切りと違いブリッジの申告ではなく幾何からの疑いなので、
    /// 失敗にすると空のページに対する正当な `notExist` が書けなくなる。
    ///
    /// **呼ぶのは不在を結論する2経路(notExists / count)だけ**(2026-08-15 のデバイス実行で確定)。
    /// 隣の `noteEmptyWebView` は4経路すべてから呼ぶので揃えたくなるが、**あちらの条件
    /// (委譲 WebView が完全に空)は稀**なのに対し、こちらは a11y に出ない部分がある WebView
    /// なら**どの画面でも立つ**。4経路へ広げたところ、5 SUT の緑の run すべてで
    /// `exist "WebView 画面外テキスト"` に毎回付いた(真陽性 —— あのページは
    /// `aria-hidden` の見出しを持つ `webViewGapNote` の offline witness そのもの)。
    /// **毎回出る注記は率を見る役に立たない**(StepNote 冒頭の規律)うえ、通った `exist` に
    /// 「不在の証拠にならない」と書くのは文としても噛み合わない
    func noteUnderreportedTree(_ snapshot: SnapshotResponse) {
        if TreeCoverage.underreports(snapshot) {
            noteCodesThisStep.insert(.treeUnderreported)
        }
    }

    /// 「不在(件数)を結論できない」ことの失敗文言。**「見つからない」と言わない**のが要点 ——
    /// 送られていないだけの要素を「無い」と報告するのがこの欠陥そのもので、同じ言葉で返すと
    /// 読み手は塞いだ穴と区別が付かない。`evidence` は何がどれだけ落ちたか(呼び手が組み立てる)
    static func undecidableTruncationMessage(_ what: String, step: FlowStep,
                                             evidence: String) -> String {
        // **truncationHint(165〜166行)と同じ助言に揃える**: 「.webView >> で絞る」「対象へ
        // スクロールする」は truncationHint が撤回した2助言そのもの(スコープは母数に効かず、
        // 落ちた要素はスクロールで戻らない)。天井かどうかは evidence 側の文言が言うので、
        // ここは remedy に依存しない中立な1文にする
        "cannot decide \(what): \(step.locatorSummary) — \(evidence), so an element that is absent"
            + " cannot be told apart from one the snapshot dropped."
            + " Narrow the screen before this step (close a sheet, collapse a long list) so fewer"
            + " elements compete for the limit."
    }

    /// 天井まで上げてもまだ上限に当たっている木の証拠文(undecidableTruncationMessage 用)。
    /// **予算ぶんの件数(budgetedCount)を印字する**(truncationHint と同じ理由 — `elements.count`
    /// は bulk 群を含み天井を超えて見えるが、天井そのものは予算ぶんに掛かる)
    static func ceilingTruncationEvidence(_ snapshot: SnapshotResponse) -> String {
        let budgeted = SnapshotTruncation.budgetedCount(snapshot)
        let bulk = SnapshotTruncation.bulkExemptPresentCount(snapshot)
        let bulkClause = bulk > 0 ? " (plus \(bulk) bulk-exempt elements outside the budget)" : ""
        return "the snapshot is still truncated at \(budgeted) elements\(bulkClause)"
            + " (\(snapshot.truncatedCount) more were omitted even at the"
            + " \(BridgeAPI.maxSnapshotElementsCeiling)-element ceiling)"
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
        case WebViewPath.delegatedEmpty:
            return " (the WebView was delegated to XCUITest but produced no content before the wait"
                + " ran out, so this tree cannot tell \"the element is not there\" from \"the web"
                + " content had not been published to accessibility yet\". Give the screen more time"
                + " (a preceding exist() on a known element waits for it), or check the page loaded.)"
        case WebViewPath.dom:
            return " (WebView contents were read through the DOM path. Taps are synthesized onto DOM rects, so "
                + "a WebView embedded through interop **records success even when nothing responds**. "
                + "Suspect that the preceding interaction had no effect.)"
        case WebViewPath.domInterop:
            return " (WebView contents were read through the DOM path, and interactions were routed to real "
                + "XCUITest touches, so this does not have the DOM-tap blind spot that plain \"dom\" has.)"
        case WebViewPath.delegated:
            return " (WebView contents were read by delegating to XCUITest)"
        default:
            return ""
        }
    }

    /// assert ディスパッチャ。判定ロジックはグループ単位の executeAssert* へ切り出し、ここは
    /// 振り分けだけ行う。
    ///
    /// **成功したときだけ、OS のシステム UI に覆われていなかったかを確かめる**(SystemUIGate)。
    /// 覆われている画面で緑になるのは、別ウィンドウのモーダルと同じ形の偽陽性 ——
    /// 人手には見えていないものを「見えた」と言っていることになる。
    /// 判定は**1ステップにつき1往復**(約 73ms)。ポーリングの周回ごとには払わない ——
    /// 誤りは「緑になったこと」に宿るので、緑になった瞬間に1度確かめれば足りる。
    /// **失敗したときは聞かない**(既にシナリオは止まるので、往復を足す価値がない)。
    /// **`systemAlertHandler` の登録が残っているときだけ**(操作側と同じ。waitOutSystemUI の doc)
    func executeAssert(_ assert: String, step: FlowStep,
                       phase: inout PhaseAccumulator) async throws -> StepResult.Status {
        resolvedViaSystemUIThisStep = false
        let status = try await dispatchAssert(assert, step: step, phase: &phase)
        // シナリオ自身がアラートを検証しているなら奪わない(操作側の①と同じ規律)
        guard Self.isSuccess(status), !resolvedViaSystemUIThisStep,
              systemAlertWatchlist.isWatching, let fb = fallbackDriver else { return status }
        let clock = ContinuousClock()
        var start = clock.now
        var probe = try? await fb.systemAlert()
        phase.snapshotMs += Self.ms(clock.now - start)
        guard SystemUIGate.isCovered(probe) else { return status }

        // **登録があるなら、まず閉じてみる**。照合せずに失敗へ落とすと、失敗メッセージの
        // 「どの登録も一致しなかった」が**やっていないことをやったと書く**ことになる
        // (アラートにも登録にも「許可」があるのに一致しないと報告される)。
        // 重なりもあるので、閉じられる限り繰り返す(操作側②と同じ)
        var actualButtons = probe?.buttons ?? []
        var dismissedAny = false
        while SystemUIGate.isCovered(probe) {
            start = clock.now
            guard let fsnap = try? await fb.snapshot() else { break }
            phase.snapshotMs += Self.ms(clock.now - start)
            guard await dismissSystemAlert(in: fsnap, via: fb) != nil else { break }
            dismissedAny = true
            noteCodesThisStep.insert(.waitedForSystemUI)
            start = clock.now
            probe = try? await fb.systemAlert()
            phase.snapshotMs += Self.ms(clock.now - start)
            if let read = probe?.buttons, !read.isEmpty { actualButtons = read }
        }
        // **覆いの下で出した緑は捨てて判定し直す**: 人手には見えていない画面で下した判定は
        // 根拠にならない。閉じたあとの画面で改めて答えを出す(検証は読み取りだけなので
        // 撃ち直しの危険は無い)。やり直しは1回だけ = ここから先は再入しない
        if dismissedAny, !SystemUIGate.isCovered(probe) {
            resolvedViaSystemUIThisStep = false
            return try await dispatchAssert(assert, step: step, phase: &phase)
        }
        return failed(.systemUICovered,
                      SystemUIGate.failureMessage(
                          covering: SystemUIGate.describeCovering(probe),
                          actualButtons: actualButtons,
                          declaredButtons: systemAlertWatchlist.describedRules))
    }

    private func dispatchAssert(_ assert: String, step: FlowStep,
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
        case "keyboardShown", "keyboardNotShown":
            return try await executeAssertKeyboardShown(assert, step: step, phase: &phase)
        default:
            return .skipped("unknown assertion: \(assert)")
        }
    }

    private func executeAssertExists(step: FlowStep,
                                     phase: inout PhaseAccumulator) async throws -> StepResult.Status {
        let clock = ContinuousClock()
        // `exist(scroll:)` の内蔵探索(アクション側と同じ理由で別ステップにしない)
        if step.direction != nil, step.locator != nil {
            let result = try await runScrollSearch(step: step, phase: &phase)
            scrollSearchNote = recordedScrollSearchNote(result)
            guard result.found else { return failed(.notFound, Self.scrollNotFoundMessage(step, result)) }
        }
        let deadline = Date().addingTimeInterval(step.timeout ?? FlowStep.defaultWaitSeconds)
        var freshRetry = AssertFreshRetry()
        var backoff = PollBackoff()
        var primaryMisses = 0
        // occlusion-guard: 要素が見つかっても覆われている場合、過渡的オーバーレイ(ローディング/
        // スナックバー等)が消えるのを timeout まで待ってから失敗にする(即失敗の脆さを回避)。
        // 最後に観測した occlusion 失敗を保持し、可視化されなければこれを返す。
        var lastOcclusion: StepResult.Status?
        var lastSnapshot: SnapshotResponse?
        // 一度でも上限に当たったら以後は最初から天井で撮る(notExists と同じ latch)
        var needsCeiling = false
        // timeout==0 でも初回照会は必ず1回行う(ループ後段の deadline チェックで離脱)。
        while true {
            var start = clock.now
            if needsCeiling { driver.raiseElementLimitOnNextSnapshot(BridgeAPI.maxSnapshotElementsCeiling) }
            var snapshot = try await driver.snapshot(bypassingCache: freshRetry.takeArmed())
            phase.snapshotMs += Self.ms(clock.now - start)
            try await dismissInterruption(in: &snapshot, phase: &phase)
            noteEmptyWebView(snapshot)
            // **見つからないのは上限で間引かれたからかもしれない**(2026-08-15)。否定側だけ
            // 塞いであったが、肯定側は**実在する要素で赤くなる** = flake になる。
            // 誤った成功ではないので優先度は下だが、直す手段は同じファイルに既にある。
            // 撮り直しは切り詰められていて解決できなかったときだけ(通る側の固定費はゼロ)。
            // 解決は1周1回(撮り直した周だけ2回)—— ゲートと本判定で同じ木に2回払わない
            var resolvedDetail = Self.resolveDetailed(step: step, in: snapshot, strictForAssert: true)
            if resolvedDetail == nil, snapshot.truncatedCount > 0, !needsCeiling {
                needsCeiling = true
                snapshot = try await retakenAtElementLimitCeiling(snapshot, phase: &phase)
                resolvedDetail = Self.resolveDetailed(step: step, in: snapshot, strictForAssert: true)
            }
            lastSnapshot = snapshot
            // アサーションでは type+index のみのフォールバックを使わない。
            // 別画面の無関係な要素にマッチして偽陽性になる(実測済み)
            if let d = resolvedDetail {
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
                        // **SpringBoard 側で解決した** = この検証はアラート自身が対象
                        resolvedViaSystemUIThisStep = true
                        if let fallback { return .passedViaFallback(fallback) }
                        return .passed
                    }
                    // 待っている要素がどちらにも居ないなら、システム許可アラートが被さって
                    // いないかを見る(閉じたら次の周回で普通に解決される)。
                    // **解決できたときは通らない** = シナリオ自身のアラート操作を奪わない
                    await dismissSystemAlert(in: fsnap, via: fb)
                }
            }
            if Date() >= deadline {   // 初回照会後にここで離脱(timeout==0 も含む)
                // 失敗と決める前に、キャッシュを捨てた1周だけ確かめる(AssertFreshRetry)
                if freshRetry.arm(ifSupported: driver.supportsCacheBypass) { continue }
                break
            }
            start = clock.now
            try await Task.sleep(for: backoff.nextDelay())
            phase.waitMs += Self.ms(clock.now - start)
            cachedScreenshot = nil   // 待機中に画面が変わり得る → 次周回は取り直す
        }
        // timeout: 覆われ続けた occlusion があればそれを、無ければ未発見を返す
        if let lastOcclusion { return lastOcclusion }
        return failed(.notFound, "element not found: \(step.locatorSummary) (timeout \(FTSeconds.format(step.timeout ?? FlowStep.defaultWaitSeconds))s)"
                       + Self.truncationHint(lastSnapshot)
                       + tapDiagnosisHint(lastSnapshot?.elements)
                       + Self.webViewPathHint(lastSnapshot))
    }

    private func executeAssertTextComparison(
        _ assert: String, step: FlowStep,
        phase: inout PhaseAccumulator) async throws -> StepResult.Status {
        let clock = ContinuousClock()
        guard let expected = step.expected else {
            return .skipped("expected was not specified")
        }
        let deadline = Date().addingTimeInterval(step.timeout ?? FlowStep.defaultWaitSeconds)
        var freshRetry = AssertFreshRetry()
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
        // 一度でも上限に当たったら以後は最初から天井で撮る(exists と同じ latch)
        var needsCeiling = false
        // timeout==0 でも初回照会は必ず1回行う(ループ後段の deadline チェックで離脱)。
        while true {
            var start = clock.now
            if needsCeiling { driver.raiseElementLimitOnNextSnapshot(BridgeAPI.maxSnapshotElementsCeiling) }
            var snapshot = try await driver.snapshot(bypassingCache: freshRetry.takeArmed())
            phase.snapshotMs += Self.ms(clock.now - start)
            try await dismissInterruption(in: &snapshot, phase: &phase)
            // 見つからないのは上限で間引かれたからかもしれない(exists 側 331〜334行と同じ型)
            if snapshot.truncatedCount > 0, !needsCeiling,
               Self.resolve(step: step, in: snapshot, strictForAssert: true) == nil {
                needsCeiling = true
                snapshot = try await retakenAtElementLimitCeiling(snapshot, phase: &phase)
            }
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
                let matched = Self.matchedText(actual, expected: expected, assert: assert,
                                               normalization: Self.textNormalization(for: step))
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
            if Date() >= deadline {   // 初回照会後にここで離脱(timeout==0 も含む)
                // 失敗と決める前に、キャッシュを捨てた1周だけ確かめる(AssertFreshRetry)
                if freshRetry.arm(ifSupported: driver.supportsCacheBypass) { continue }
                break
            }
            start = clock.now
            try await Task.sleep(for: backoff.nextDelay())
            phase.waitMs += Self.ms(clock.now - start)
            cachedScreenshot = nil   // 待機中に画面が変わり得る → 次周回は取り直す
        }
        if let lastOcclusion { return lastOcclusion }   // 覆われ続けた
        let subject = assert == "idEquals" ? "id"
            : (assert.hasPrefix("value") ? "value" : "text")
        let relation = Self.textMismatchRelation(assert)
        return found
            ? .failed("\(subject) \(relation): expected \"\(expected)\", actual \"\(lastActual ?? "nil")\""
                      // **どちらの規則なら一致したか**を必ず添える(2026-08-09 のユーザー指示)。
                      // 「見えない差で落ちたのか、本当に違う文字列なのか」で次の一手が変わる
                      + Self.normalizationVerdict(actual: lastActual, expected: expected,
                                                  assert: assert)
                      + Self.coveringHint(element: lastElement, elements: lastElements,
                                          screen: lastScreen)
                      + tapDiagnosisHint(lastSnapshot?.elements)
                      + Self.webViewPathHint(lastSnapshot))
            : failed(.notFound, "element not found: \(step.locatorSummary)"
                      + Self.truncationHint(lastSnapshot)
                      + tapDiagnosisHint(lastSnapshot?.elements)
                      + Self.webViewPathHint(lastSnapshot))
    }

    /// このステップで使う正規化。**既定は `.text`**(見た目が同じなら同じ)。
    /// `strict: true` を明示したときだけ一切正規化しない
    static func textNormalization(for step: FlowStep) -> TextNormalization {
        step.strictText == true ? .strict : .text
    }

    /// executeAssertTextComparison の失敗文言用: 期待した関係のどれに反したかを表す語尾。
    /// 純粋関数(判定ロジックとは無関係。単体テストしやすいよう分離)。
    private static func textMismatchRelation(_ assert: String) -> String {
        switch assert {
        case "textContains": return "does not contain"
        case "textMatches": return "does not match (regex)"
        case "textStartsWith", "valueStartsWith": return "does not start with"
        case "textEndsWith", "valueEndsWith": return "does not end with"
        case "textMatchesDateFormat", "valueMatchesDateFormat":
            return "does not match the date format"
        case "valueContains": return "does not contain"
        case "valueMatches": return "does not match (regex)"
        default: return "does not equal"
        }
    }

    private func executeAssertNotExists(step: FlowStep,
                                        phase: inout PhaseAccumulator) async throws -> StepResult.Status {
        let clock = ContinuousClock()
        // `notExist(scroll:)` の内蔵探索(exist(scroll:) と対だが判定は逆: 見つかったら即失敗)。
        // これは**空間**の判定(スクロールして探しても無いか)で、下のポーリングは**時間**の判定
        // (現在のビューポートから消えるのを待つ)。前者が「無い」で終わっても、消滅アニメーションの
        // 途中(ツリーにはまだ残っている)ことがあるため後者を差し替えず両方通す
        if step.direction != nil, step.locator != nil {
            // **拾い直しは掛けない**: 見つからないのが期待値なので、逆走査は丸損になる
            let result = try await runScrollSearch(step: step, recoverOnMiss: false, phase: &phase)
            scrollSearchNote = recordedScrollSearchNote(result)
            guard !result.found else { return .failed(Self.scrollFoundMessage(step)) }
            // **`!result.found` を成功材料にしない**: scrollFrame が解決できず1本も振らずに
            // 打ち切った場合も found=false になるが、それは「無いことを確認した」ではなく
            // 探索していない(2026-08-08)。exist 側(executeAssertExists)と同じく
            // scrollNotFoundMessage 経由の文言でその場に失敗させる
            if result.scrollFrameMissing {
                return failed(.notFound, Self.scrollNotFoundMessage(step, result))
            }
            // **探索中に上限で切り詰められていたら「無い」を結論にしない**(同じ理由。
            // `truncatedDuringSearch` の注記だけでは**検証は通ってしまう**)。通り過ぎた
            // 画面の木はもう手元に無いので、ここは撮り直しでは救えない = その場で判定不能にする
            if result.maxTruncatedDuringSearch > 0 {
                return .failed(Self.undecidableTruncationMessage(
                    "absence", step: step,
                    evidence: "the tree hit the element limit during the scroll search"
                        + " (\(result.maxTruncatedDuringSearch) element(s) were omitted in at"
                        + " least one round)"))
            }
        }
        // 「消えるまで待つ」。初回で不在なら即 pass、在るならタイムアウトまで消滅を待つ。
        // 可視性(occlusion)は見ない: ツリーから消えたことが唯一の判定。
        let deadline = Date().addingTimeInterval(step.timeout ?? FlowStep.defaultWaitSeconds)
        var freshRetry = AssertFreshRetry()
        // 否定形を通す前の確認は1周だけ(上の continue が deadline 検査を飛ばすため)
        var passConfirmed = false
        var backoff = PollBackoff()
        var lastElements: [ElementInfo] = []   // 失敗文言の tapDiagnosisHint 用
        // 一度でも上限に当たったら、この検証の残りは**最初から天井で撮る**(needsCeiling)
        var needsCeiling = false
        while true {
            let start = clock.now
            if needsCeiling { driver.raiseElementLimitOnNextSnapshot(BridgeAPI.maxSnapshotElementsCeiling) }
            var snapshot = try await driver.snapshot(bypassingCache: freshRetry.takeArmed())
            phase.snapshotMs += Self.ms(clock.now - start)
            try await dismissInterruption(in: &snapshot, phase: &phase)
            noteEmptyWebView(snapshot)
            var resolved = Self.resolve(step: step, in: snapshot, strictForAssert: true)
            // **見つからないのは上限で間引かれたからかもしれない**。切り詰められた木で
            // 不在に見えたときだけ天井まで上げて撮り直す(retakenAtElementLimitCeiling)
            if resolved == nil, snapshot.truncatedCount > 0, !needsCeiling {
                needsCeiling = true
                snapshot = try await retakenAtElementLimitCeiling(snapshot, phase: &phase)
                resolved = Self.resolve(step: step, in: snapshot, strictForAssert: true)
            }
            lastElements = snapshot.elements
            if resolved == nil {
                // **不在を見た周でだけ評価する**(2026-08-15 の実測)。毎周だと 400 要素の
                // ブラウザ画面で 11.9ms/回(debug)を全ポーリングぶん払う —— 見えている
                // 要素があった周の木は結論に使われないので、測る意味が無い
                noteUnderreportedTree(snapshot)
                // 天井でも切り詰められている = 「無い」と「送られていない」を分けられない。
                // ここで pass を返すのが 2026-08-15 に掃討した誤った成功そのもの
                if snapshot.truncatedCount > 0 {
                    return .failed(Self.undecidableTruncationMessage(
                        "absence", step: step,
                        evidence: Self.ceilingTruncationEvidence(snapshot)))
                }
                // **不在は古い木でも成立する**(要素が現れた直後はキャッシュが追いつかない)ので、
                // 通す前にキャッシュを捨てて1周だけ確かめる。ここを省くと誤った成功になる。
                // `continue` は deadline 検査を飛ばすため、**確認は1周だけ**が無限ループを
                // 防ぐ不変条件になっている。AssertFreshRetry の予算だけに頼らず局所でも止める
                // (予算側が壊れたときの症状が「失敗」でなく「ハング」になるのを避ける)
                if !passConfirmed,
                   freshRetry.confirmPass(ifSupported: driver.supportsCacheBypass) {
                    passConfirmed = true
                    continue
                }
                // primary で不在 = pass だが、hybrid ではシステム UI(別プロセスのダイアログ)が
                // primary の snapshot に映らない。不在を確定する側でだけ fallbackDriver を1回照会する
                // (pass 経路の固定費 1 回のみ。miss 毎に払う exists 側の間引きとは事情が逆)
                if let fb = fallbackDriver {
                    let fbStart = clock.now
                    let fsnap = try await fb.snapshot()
                    phase.snapshotMs += Self.ms(clock.now - fbStart)
                    if Self.resolve(step: step, in: fsnap, strictForAssert: true) != nil {
                        if Date() >= deadline {
                            return .failed("element still exists (system UI): \(step.locatorSummary)")
                        }
                        let waitStart = clock.now
                        try await Task.sleep(for: backoff.nextDelay())
                        phase.waitMs += Self.ms(clock.now - waitStart)
                        continue
                    }
                }
                return .passed
            }
            if Date() >= deadline {
                // 失敗と決める前に、キャッシュを捨てた1周だけ確かめる(AssertFreshRetry)
                if freshRetry.arm(ifSupported: driver.supportsCacheBypass) { continue }
                break
            }
            let waitStart = clock.now
            try await Task.sleep(for: backoff.nextDelay())
            phase.waitMs += Self.ms(clock.now - waitStart)
        }
        return .failed("element still exists: \(step.locatorSummary) (timeout \(FTSeconds.format(step.timeout ?? FlowStep.defaultWaitSeconds))s)"
                       + tapDiagnosisHint(lastElements))
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
            return .skipped("expected was not specified")
        }
        let deadline = Date().addingTimeInterval(step.timeout ?? FlowStep.defaultWaitSeconds)
        var freshRetry = AssertFreshRetry()
        // 否定形を通す前の確認は1周だけ(上の continue が deadline 検査を飛ばすため)
        var passConfirmed = false
        var backoff = PollBackoff()
        var found = false
        var lastActual: String?
        var lastElement: ElementInfo?
        var lastElements: [ElementInfo] = []
        var lastScreen = FTRect(x: 0, y: 0, width: 0, height: 0)
        // **lastElements とは別に持つ**: あちらは lastElement と対で coveringHint が ref を引くため、
        // 見つかった周のものでなければならない。こちらは木の同一性だけを見るので毎周更新する
        var lastSeenElements: [ElementInfo] = []
        /// 失敗文言に切り詰めを添えるための直近の観測
        var lastSnapshot: SnapshotResponse?
        // 一度でも上限に当たったら以後は最初から天井で撮る(exists と同じ latch)
        var needsCeiling = false
        while true {
            let start = clock.now
            if needsCeiling { driver.raiseElementLimitOnNextSnapshot(BridgeAPI.maxSnapshotElementsCeiling) }
            var snapshot = try await driver.snapshot(bypassingCache: freshRetry.takeArmed())
            phase.snapshotMs += Self.ms(clock.now - start)
            try await dismissInterruption(in: &snapshot, phase: &phase)
            noteEmptyWebView(snapshot)
            // **要素は在ることが前提の経路**: 未発見のときだけ撮り直す(exists 側 331〜334行と同じ型)。
            // 発見済みで値の変化を待っている周には不要
            if snapshot.truncatedCount > 0, !needsCeiling,
               Self.resolve(step: step, in: snapshot, strictForAssert: true) == nil {
                needsCeiling = true
                snapshot = try await retakenAtElementLimitCeiling(snapshot, phase: &phase)
            }
            lastSeenElements = snapshot.elements
            lastSnapshot = snapshot
            if let (element, fallback) = Self.resolve(step: step, in: snapshot,
                                                      strictForAssert: true) {
                found = true
                let actual = assert.hasPrefix("value") ? element.value : element.label
                lastActual = actual
                lastElement = element
                lastElements = snapshot.elements
                lastScreen = snapshot.screen
                let satisfied = Self.negativeAssertSatisfied(
                    assert, actual: actual, expected: step.expected,
                    normalization: Self.textNormalization(for: step))
                if satisfied {
                    // 否定形の成立は古い値でも起きる(変わる前の値が条件を満たす)。
                    // 通す前にキャッシュを捨てて1周だけ確かめる(局所ガードの理由も notExists と同じ)
                    if !passConfirmed,
                       freshRetry.confirmPass(ifSupported: driver.supportsCacheBypass) {
                        passConfirmed = true
                        continue
                    }
                    if let fallback { return .passedViaFallback(fallback) }
                    return .passed
                }
            }
            if Date() >= deadline {
                // 失敗と決める前に、キャッシュを捨てた1周だけ確かめる(AssertFreshRetry)
                if freshRetry.arm(ifSupported: driver.supportsCacheBypass) { continue }
                break
            }
            let waitStart = clock.now
            try await Task.sleep(for: backoff.nextDelay())
            phase.waitMs += Self.ms(clock.now - waitStart)
        }
        guard found else {
            return failed(.notFound, "element not found: \(step.locatorSummary)"
                           + Self.truncationHint(lastSnapshot)
                           + tapDiagnosisHint(lastSeenElements))
        }
        let hint = Self.coveringHint(element: lastElement, elements: lastElements,
                                     screen: lastScreen)
            + tapDiagnosisHint(lastSeenElements)
        let subject = assert.hasPrefix("value") ? "value" : "text"
        switch assert {
        case "textIsEmpty", "valueIsEmpty":
            return .failed("\(subject) is not empty: actual \"\(lastActual ?? "nil")\"" + hint)
        case "textIsNotEmpty", "valueIsNotEmpty":
            return .failed("\(subject) is empty: \(step.locatorSummary)" + hint)
        default:
            // 否定の種類ごとに何が成立してしまったのかを書く(「条件不成立」だけだと
            // 期待値のどの関係で引っかかったのか読めない)
            let expected = step.expected ?? ""
            let relation = Self.negativeAssertViolationRelation(assert, expected: expected)
            return .failed("\(subject) \(relation): actual \"\(lastActual ?? "nil")\"" + hint)
        }
    }

    /// executeAssertNegativeTextComparison の失敗文言用: `*Not` 系のどの関係が成立してしまったか。
    /// 純粋関数(判定ロジックとは無関係。単体テストしやすいよう分離)。
    private static func negativeAssertViolationRelation(_ assert: String, expected: String) -> String {
        switch assert {
        case "textContainsNot", "valueContainsNot": return "contains \"\(expected)\""
        case "textStartsWithNot", "valueStartsWithNot":
            return "starts with \"\(expected)\""
        case "textEndsWithNot", "valueEndsWithNot": return "ends with \"\(expected)\""
        case "textMatchesNot", "valueMatchesNot":
            return "matches the regex \"\(expected)\""
        default: return "equals it"
        }
    }

    private func executeAssertEnabledDisabled(
        _ assert: String, step: FlowStep,
        phase: inout PhaseAccumulator) async throws -> StepResult.Status {
        let clock = ContinuousClock()
        let wantEnabled = assert == "enabled"
        let deadline = Date().addingTimeInterval(step.timeout ?? FlowStep.defaultWaitSeconds)
        var freshRetry = AssertFreshRetry()
        var backoff = PollBackoff()
        var found = false
        /// 失敗文言に切り詰めを添えるための直近の観測
        var lastSnapshot: SnapshotResponse?
        // 一度でも上限に当たったら以後は最初から天井で撮る(exists と同じ latch)
        var needsCeiling = false
        while true {
            let start = clock.now
            if needsCeiling { driver.raiseElementLimitOnNextSnapshot(BridgeAPI.maxSnapshotElementsCeiling) }
            var snapshot = try await driver.snapshot(bypassingCache: freshRetry.takeArmed())
            phase.snapshotMs += Self.ms(clock.now - start)
            try await dismissInterruption(in: &snapshot, phase: &phase)
            // 見つからないのは上限で間引かれたからかもしれない(exists 側 331〜334行と同じ型)
            if snapshot.truncatedCount > 0, !needsCeiling,
               Self.resolve(step: step, in: snapshot, strictForAssert: true) == nil {
                needsCeiling = true
                snapshot = try await retakenAtElementLimitCeiling(snapshot, phase: &phase)
            }
            lastSnapshot = snapshot
            if let (element, fallback) = Self.resolve(step: step, in: snapshot,
                                                      strictForAssert: true) {
                found = true
                if element.enabled == wantEnabled {
                    resolvedElementThisStep = element
                    if let fallback { return .passedViaFallback(fallback) }
                    return .passed
                }
            }
            if Date() >= deadline {
                // 失敗と決める前に、キャッシュを捨てた1周だけ確かめる(AssertFreshRetry)
                if freshRetry.arm(ifSupported: driver.supportsCacheBypass) { continue }
                break
            }
            let waitStart = clock.now
            try await Task.sleep(for: backoff.nextDelay())
            phase.waitMs += Self.ms(clock.now - waitStart)
        }
        return found
            ? .failed("the element is \(wantEnabled ? "disabled" : "enabled"): \(step.locatorSummary)")
            : failed(.notFound, "element not found: \(step.locatorSummary)" + Self.truncationHint(lastSnapshot))
    }

    /// キーボード開閉はアニメーションを伴うため単発チェックはフレークする → notExists と同じ
    /// 「状態が変わるまで待つ」ポーリング。ロケータは無いので resolve は挟まず、
    /// snapshot.keyboardShown を直接見る。captureKeyboardStateOnNextSnapshot() は毎周回立て直す
    /// (Android は1回の snapshot でしか有効でないフラグのため。iOS は no-op)。
    /// **nil(不明)を非表示と解釈しない** — Android の旧ブリッジ/フラグ未着火を「非表示」の
    /// 偽成功にすり替えると、キーボードが実際は開いたままでも keyboardIsNotShown が通ってしまう
    private func executeAssertKeyboardShown(
        _ assert: String, step: FlowStep,
        phase: inout PhaseAccumulator) async throws -> StepResult.Status {
        let clock = ContinuousClock()
        let wantShown = assert == "keyboardShown"
        let deadline = Date().addingTimeInterval(step.timeout ?? FlowStep.defaultWaitSeconds)
        var freshRetry = AssertFreshRetry()
        // 否定形を通す前の確認は1周だけ(上の continue が deadline 検査を飛ばすため)
        var passConfirmed = false
        var backoff = PollBackoff()
        var lastShown: Bool?
        while true {
            driver.captureKeyboardStateOnNextSnapshot()
            let start = clock.now
            var snapshot = try await driver.snapshot(bypassingCache: freshRetry.takeArmed())
            phase.snapshotMs += Self.ms(clock.now - start)
            try await dismissInterruption(in: &snapshot, phase: &phase)
            lastShown = snapshot.keyboardShown
            if snapshot.keyboardShown == wantShown {
                // **否定側(keyboardIsNotShown)だけ**通す前に確かめる。閉じたと読めた木が
                // 古いと、開いたままのキーボードを「閉じている」と通す。肯定側は
                // 「開くのを待つ」用途なので古い木では一致せずポーリングが続く
                if !wantShown, !passConfirmed,
                   freshRetry.confirmPass(ifSupported: driver.supportsCacheBypass) {
                    passConfirmed = true
                    continue
                }
                return .passed
            }
            if Date() >= deadline {
                // 失敗と決める前に、キャッシュを捨てた1周だけ確かめる(AssertFreshRetry)
                if freshRetry.arm(ifSupported: driver.supportsCacheBypass) { continue }
                break
            }
            let waitStart = clock.now
            try await Task.sleep(for: backoff.nextDelay())
            phase.waitMs += Self.ms(clock.now - waitStart)
        }
        guard let lastShown else {
            return .failed("cannot determine the keyboard state (the bridge may be outdated)")
        }
        return .failed(wantShown
            ? "keyboard is not shown (timeout \(FTSeconds.format(step.timeout ?? FlowStep.defaultWaitSeconds))s)"
            : "keyboard is still shown (timeout \(FTSeconds.format(step.timeout ?? FlowStep.defaultWaitSeconds))s)")
    }

    private func executeAssertChecked(
        _ assert: String, step: FlowStep,
        phase: inout PhaseAccumulator) async throws -> StepResult.Status {
        let clock = ContinuousClock()
        // checked は true のときだけブリッジが送る(省略 = オフ / 状態を持たない要素)。
        // 「状態が違う」と「見つからない」を別メッセージにするのは enabled と同じ規律
        let wantChecked = assert == "checked"
        let deadline = Date().addingTimeInterval(step.timeout ?? FlowStep.defaultWaitSeconds)
        var freshRetry = AssertFreshRetry()
        var backoff = PollBackoff()
        var found = false
        /// 失敗文言に切り詰めを添えるための直近の観測
        var lastSnapshot: SnapshotResponse?
        // 一度でも上限に当たったら以後は最初から天井で撮る(exists と同じ latch)
        var needsCeiling = false
        while true {
            let start = clock.now
            if needsCeiling { driver.raiseElementLimitOnNextSnapshot(BridgeAPI.maxSnapshotElementsCeiling) }
            var snapshot = try await driver.snapshot(bypassingCache: freshRetry.takeArmed())
            phase.snapshotMs += Self.ms(clock.now - start)
            try await dismissInterruption(in: &snapshot, phase: &phase)
            // 見つからないのは上限で間引かれたからかもしれない(exists 側 331〜334行と同じ型)
            if snapshot.truncatedCount > 0, !needsCeiling,
               Self.resolve(step: step, in: snapshot, strictForAssert: true) == nil {
                needsCeiling = true
                snapshot = try await retakenAtElementLimitCeiling(snapshot, phase: &phase)
            }
            lastSnapshot = snapshot
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
            if Date() >= deadline {
                // 失敗と決める前に、キャッシュを捨てた1周だけ確かめる(AssertFreshRetry)
                if freshRetry.arm(ifSupported: driver.supportsCacheBypass) { continue }
                break
            }
            let waitStart = clock.now
            try await Task.sleep(for: backoff.nextDelay())
            phase.waitMs += Self.ms(clock.now - waitStart)
        }
        return found
            ? .failed("the element is \(wantChecked ? "off" : "on"): \(step.locatorSummary)")
            : failed(.notFound, "element not found: \(step.locatorSummary)" + Self.truncationHint(lastSnapshot))
    }

    private func executeAssertCount(step: FlowStep,
                                    phase: inout PhaseAccumulator) async throws -> StepResult.Status {
        let clock = ContinuousClock()
        guard let expectedCount = step.expectedCount else {
            return .skipped("expectedCount was not specified")
        }
        guard let locator = step.locator else {
            return .skipped("no locator specified")
        }
        // `||` は**候補集合の和**(Shirates 準拠)。全節の候補を合わせ、同じ要素は1度だけ数える。
        // 節の優先順位が効くのは要素を1つ選ぶときだけで、数えるときは節を跨いで合計する
        let chain = [locator] + (step.fallbacks ?? [])
        let deadline = Date().addingTimeInterval(step.timeout ?? FlowStep.defaultWaitSeconds)
        var freshRetry = AssertFreshRetry()
        var backoff = PollBackoff()
        var actual = 0
        var breakdown: [(clause: FlowLocator, elements: [ElementInfo])] = []
        var nestingHint = ""
        /// 失敗文言に切り詰めを添えるための直近の観測
        var lastSnapshot: SnapshotResponse?
        // 一度でも上限に当たったら以後は天井で撮る(notExists と同じ latch)
        var needsCeiling = false
        while true {
            let start = clock.now
            if needsCeiling { driver.raiseElementLimitOnNextSnapshot(BridgeAPI.maxSnapshotElementsCeiling) }
            var snapshot = try await driver.snapshot(bypassingCache: freshRetry.takeArmed())
            phase.snapshotMs += Self.ms(clock.now - start)
            try await dismissInterruption(in: &snapshot, phase: &phase)
            noteEmptyWebView(snapshot)
            // **件数は木の完全性がそのまま結果になる**(間引かれた分は「無い」と区別が付かない)。
            // 不在と違い一致・不一致のどちらにも効くので、数える前に撮り直す
            if snapshot.truncatedCount > 0, !needsCeiling {
                needsCeiling = true
                snapshot = try await retakenAtElementLimitCeiling(snapshot, phase: &phase)
            }
            lastSnapshot = snapshot
            breakdown = Self.unionByClause(chain, elements: snapshot.elements)
            actual = breakdown.reduce(0) { $0 + $1.elements.count }
            nestingHint = Self.nestingHint(breakdown.flatMap(\.elements),
                                           in: snapshot.elements)
            if actual == expectedCount {
                // **一致した周でだけ評価する**(notExists と同じ理由。不一致はそのまま赤くなるので
                // 「不在の証拠にならない」と言う相手が居ない)
                noteUnderreportedTree(snapshot)
                // 天井でも足りない木で数えた一致は根拠にならない(notExists と同じ誤った成功)
                if snapshot.truncatedCount > 0 {
                    return .failed(Self.undecidableTruncationMessage(
                        "the count", step: step,
                        evidence: Self.ceilingTruncationEvidence(snapshot)))
                }
                return .passed
            }
            if Date() >= deadline {
                // 失敗と決める前に、キャッシュを捨てた1周だけ確かめる(AssertFreshRetry)
                if freshRetry.arm(ifSupported: driver.supportsCacheBypass) { continue }
                break
            }
            let waitStart = clock.now
            try await Task.sleep(for: backoff.nextDelay())
            phase.waitMs += Self.ms(clock.now - waitStart)
        }
        // 節が複数あるときは**どの節が何件拾ったか**まで出す。和集合の総数だけだと
        // 「どれが想定より多く拾ったのか」が分からず、セレクタを直すのに snapshot を
        // 取り直す往復が要る(実例: ラベルで数えてボタンの内側の Text も拾っていた)
        let detail = breakdown.count > 1
            ? "breakdown: " + breakdown.map { "\($0.clause.summary) \($0.elements.count)" }
                .joined(separator: " / ")
            : step.locatorSummary
        // **切り詰めは不一致の側にも効く**(間引かれた分だけ actual が少ない)。天井まで上げても
        // 残っているときは判定不能だが、既に不一致なので誤った成功にはならない = 注記で足りる
        return .failed("count mismatch: expected \(expectedCount), actual \(actual) (\(detail))"
                       + nestingHint + Self.truncationHint(lastSnapshot))
    }

    private func executeAssertScreenMatches(
        step: FlowStep, phase: inout PhaseAccumulator) async throws -> StepResult.Status {
        let clock = ContinuousClock()
        guard screenLooksLikeEnabled else {
            return .skipped("screenLooksLike is disabled (run profile setting)")
        }
        guard let expected = step.expected, !expected.isEmpty else {
            return .skipped("expected was not specified")
        }
        guard let delegate else {
            return .skipped("FM verification is disabled (Foundation Models unavailable)")
        }
        // スクショを撮る前に落とす(画像を渡せない環境では検証自体が成立しない)
        guard FMVisionSupport.isSupported else {
            return .skipped("screen verification is disabled (\(FMVisionSupport.requirement))")
        }
        let frozen = StepResult.Status
            .skipped("aborted due to a frozen display (blank frame) — requeued onto another device")
        guard let screenshot = try await unfrozenScreenshot(phase: &phase) else {
            onDeviceFrozen?()
            return frozen
        }
        guard let verdict = await delegate.verifyScreen(expected: expected, screenshotPNG: screenshot) else {
            return .skipped("could not run screen verification")
        }
        if verdict.pass { return .passed }
        // **不一致なら1回だけ撮り直して判定し直す**。他の検証は timeout までポーリングして遷移の
        // 整定を吸収するが、screenLooksLike にそれを許すと FM 照合(ホスト全体で直列・約1回/秒)を
        // 何度も焼くので、**回数を1回に固定**する(正常系のコストは増えない・失敗系で +1 回)。
        // 狙いは「遷移直後のまだ描き終わっていない画面」の1件だけを救うこと
        let start = clock.now
        try await Task.sleep(nanoseconds: UInt64(Self.screenMatchRetryDelayMs) * 1_000_000)
        phase.waitMs += Self.ms(clock.now - start)
        // **撮り直しも白フレーム検査を通す**。素の screenshot() を呼ぶと、凍結した画面を FM に渡して
        // 「画面が一致しない」で落ち、requeue すべき凍結を検証失敗に見せかける
        guard let retryShot = try await unfrozenScreenshot(phase: &phase) else {
            onDeviceFrozen?()
            return frozen
        }
        guard let retryVerdict = await delegate.verifyScreen(expected: expected,
                                                             screenshotPNG: retryShot) else {
            return .failed("the screen does not match the expectation: \(verdict.reason)")
        }
        if retryVerdict.pass { return .passed }
        return .failed("the screen does not match the expectation: \(retryVerdict.reason)")
    }

    /// スクショを撮り、白フレーム(画面凍結)なら回復を待って最大2回まで撮り直す。
    /// **白のままなら nil**(呼び手が onDeviceFrozen + requeue する)。
    /// 白フレームを FM 検証に渡すと必ず不一致になり、凍結が「検証失敗」に化けるための防波堤
    private func unfrozenScreenshot(phase: inout PhaseAccumulator) async throws -> Data? {
        let clock = ContinuousClock()
        var start = clock.now
        var screenshot = try await driver.screenshot()
        phase.actionMs += Self.ms(clock.now - start)
        guard BlankFrameDetector.isUniformBlank(pngData: screenshot) else { return screenshot }
        for _ in 0..<2 {
            start = clock.now
            try await Task.sleep(nanoseconds: 2_000_000_000)
            phase.waitMs += Self.ms(clock.now - start)
            start = clock.now
            screenshot = try await driver.screenshot()
            phase.actionMs += Self.ms(clock.now - start)
            if !BlankFrameDetector.isUniformBlank(pngData: screenshot) { return screenshot }
        }
        return nil
    }
}
