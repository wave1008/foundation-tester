// StepExecutor+ScrollSearch.swift
// スクロール探索(runScrollSearch とその注記・ジャンプ計算)。本体は StepExecutor.swift(instance 状態はそちらに置く)

import Foundation

extension StepExecutor {

    struct ScrollSearchResult {
        var found: Bool
        /// 解決に使ったフォールバック節(プライマリで解決したら nil)
        var fallback: FlowLocator?
        /// 1回でも XCUITest 経由で swipe したか(記録の注記に載せる)
        let viaXCUITest: Bool
        /// スクロールヒントで置き換えた長距離ドラッグの回数(記録の注記に載せる)
        let hintJumps: Int
        /// 探索終端の静止待ちが**収束せずに打ち切られた**。黙って返すと「動いている画面で
        /// 掴んだ座標」を後段がタップすることになり、失敗は沈黙(誤った成功)として現れる
        var settleCapped: Bool = false
        /// 実際に撃ったスワイプ数(見つからなかったときの理由文に使う)
        var swipes: Int = 0
        /// **もう動かないので上限より手前で打ち切った**。上限まで振り続けても結果は変わらないため
        var stoppedUnmoving: Bool = false
        /// 探索中に木が**一度でも変わったか**。`stoppedUnmoving` の2形を分けるためだけに持つ:
        /// true = スクロールできていて末尾に着いた / false = 最初から1度も動いていない
        /// (指が容器の外・上に重なったモーダル・そもそもスクロールしない画面)。
        /// **この区別が無いと「stopped early」としか言えず**、末尾に着いただけの回を
        /// 「途中で諦めた」と読ませて maxSwipes の引き上げを繰り返させる(2026-08-15 の外部評価)
        var contentEverMoved: Bool = false
        /// 端まで来ても見つからず、**逆向きの細刻みで拾い直した**回数(0 か 1。注記に載せる)
        var reverseSweeps: Int = 0
        /// 拾い直しに使った容器を**そのまま書けるセレクタ**にしたもの(nil = 名指しできない)。
        /// 注記で `scrollFrame:` を勧めるときに実物の名前を出すために持つ
        var suggestedScrollFrame: String?
        /// `step.scrollFrame` が明示されているのに、探索開始時点(または探索中)の snapshot で
        /// 1件も解決できず、**スワイプを1本も送らずに**打ち切った。全画面スワイプへ黙って
        /// 退化すると画面上の別の物(カードのボタン等)を発火させ得るための fail-fast
        var scrollFrameMissing: Bool = false
        /// `stoppedUnmoving` の時点で、明示 scrollFrame が画面高の80%未満しかない(半開シート等)。
        /// シート展開ヒント(scrollNotFoundMessage)を**全画面リストの末尾到達**にまで出さないためのゲート
        var containerIsPartialHeight: Bool = false
        /// 探索の**どこか1周でも**木が要素上限で打ち切られていた件数の最大。
        ///
        /// **最終木だけを見ても分からない**(2026-08-12 のブラウザ監査): 目的の行が画面に
        /// 入っていた周回では打ち切られていても、探索が通り過ぎた先の最終画面は上限に
        /// 当たらないことがある。そのとき失敗文は「見つからない」としか言わず、
        /// **実在する行を探し続ける**。最終木だけで判定していたため、実測の2回のうち
        /// 1回はこの警告が出ないままだった
        var maxTruncatedDuringSearch: Int = 0
    }

    /// 探索の注記を組み立てつつ、**機械可読コードを今のステップへ記録する**。
    /// 探索の打ち切りは文言が別(「after the search」)だが `settleCapped` として同じ棚で数える ——
    /// 集計側の関心は「動いている画面のまま進んだか」で、どの経路で起きたかではない
    func recordedScrollSearchNote(_ result: ScrollSearchResult,
                                  scrollFrameNote: String? = nil) -> String? {
        scrollSwipesThisStep = result.swipes
        if result.settleCapped { noteCodesThisStep.insert(.settleCapped) }
        if result.scrollFrameMissing { noteCodesThisStep.insert(.scrollFrameMissing) }
        // 文言側のシート展開ヒント(scrollNotFoundMessage)と**同じ条件**を機械可読で出す。
        // 片方だけ変えない —— MCP はこのコードで自動展開へ分岐する
        if result.stoppedUnmoving, result.containerIsPartialHeight {
            noteCodesThisStep.insert(.sheetCollapsed)
        }
        // **見つかった回には出さない**: 打ち切りが害になるのは「不在」と読まれる回だけで、
        // 成功した探索にまで付けると毎回出る注記になる(StepNote の採用基準に反する)
        if !result.found, result.maxTruncatedDuringSearch > 0 {
            noteCodesThisStep.insert(.truncatedDuringSearch)
        }
        return Self.scrollSearchNote(result, scrollFrameNote: scrollFrameNote)
    }

    /// スクロール探索の注記(XCUITest フォールバック / ヒント跳躍)。無ければ nil
    static func scrollSearchNote(_ result: ScrollSearchResult,
                                 scrollFrameNote: String? = nil) -> String? {
        var parts: [String] = []
        if result.viaXCUITest { parts.append("fell back to XCUITest") }
        if result.hintJumps > 0 { parts.append("\(result.hintJumps) long drag(s) from scroll hints") }
        if result.settleCapped { parts.append("the screen did not settle after the search (poll limit)") }
        // **黙って拾い直さない**: 順方向で飛び越したことは利用者の書き方(scrollFrame 未指定)に
        // 由来するので、逆走査で救えたことを見せて `scrollFrame` を書く判断材料にする
        if result.reverseSweeps > 0 {
            // **具体名まで出す**: 総称の「scrollFrame を書け」だけだと、読み手は容器の名前を
            // 探すためにスナップショットを撮り直すことになる(困った瞬間に答えを渡す)
            let how = result.suggestedScrollFrame.map { "specify scrollFrame: \($0)" }
                ?? "specify scrollFrame:"
            parts.append("found by sweeping back after overshooting it"
                + " (\(how) to step within the container instead)")
        }
        if let scrollFrameNote { parts.append(scrollFrameNote) }
        return parts.isEmpty ? nil : parts.joined(separator: " / ")
    }

    /// `select` が掴めなかったときの skip 理由。**失敗ではない**(DSL は空要素を返す)ので、
    /// 読み手が「見つからないのに緑」と誤読しないよう理由文で契約を名乗る
    static let selectNotFoundReason = "element not found; select returned an empty element"

    static func scrollNotFoundMessage(_ step: FlowStep,
                                      _ result: ScrollSearchResult? = nil) -> String {
        // **fail-fast は別の文**: 実際にはスワイプを1本も送っていないので、通常の
        // 「N 回振って見つからなかった」は嘘になる
        if result?.scrollFrameMissing == true {
            return Self.scrollFrameFailFastMessage(step, action: "search", swipes: result?.swipes ?? 0)
        }
        let limit = max(0, step.maxSwipes ?? FlowStep.defaultMaxSwipes)
        // 打ち切ったときは**実際の回数**を出す(上限を名乗ると「8回も振ったのに」と読めてしまう)
        let swipes = result?.stoppedUnmoving == true ? (result?.swipes ?? limit) : limit
        // **「stopped early」と言わない**(2026-08-15 の外部評価)。旧文言は「途中で諦めた」としか
        // 読めず、実際には**リストの末尾に着いていた**回(iOS の設定アプリで実測)を欠陥と
        // 受け取らせ、maxSwipes を上げた再試行を誘っていた。上げても結果は変わらないので明言する。
        // 2形を分けるのは `contentEverMoved` —— 動いた末の停止と、1度も動かなかったのとでは次の手が違う
        let stopped: String
        if result?.stoppedUnmoving == true {
            stopped = result?.contentEverMoved == true
                ? " (the scroll area reached its end — the content stopped moving,"
                    + " so raising maxSwipes will not help)"
                : " (nothing moved at all during the search — the swipes are not reaching a"
                    + " scrolling area, so raising maxSwipes will not help)"
        } else {
            stopped = ""
        }
        // **シート展開のヒント**: 半開ボトムシート内のリストは容器が動いても中身は動かず、
        // 「動かなくなった」だけでは利用者がシートの状態に気付けない(2026-08-08・Google マップ実測)。
        // **全画面リストの末尾到達には出さない**(containerIsPartialHeight。2026-08-08)
        let sheetHint = result?.stoppedUnmoving == true && result?.containerIsPartialHeight == true
            ? " If the list sits inside a half-open bottom sheet, expand the sheet first"
                + " (drag its grabber upward) and retry."
            : ""
        return "element not found after \(swipes) scroll(s)\(stopped): \(step.locatorSummary)"
            + sheetHint
    }

    /// `notExist(scroll:)` の裏返し: スクロール探索中に見つかってしまったら不在検証は失敗
    /// (executeAssertNotExists の scroll-search prelude が使う。scrollNotFoundMessage の対)
    static func scrollFoundMessage(_ step: FlowStep) -> String {
        "element found via scroll search: \(step.locatorSummary)"
    }

    /// 明示 scrollFrame が「解決できない」ことの判定。**scrollContainer には委ねない** ——
    /// scrollContainer は殺しスイッチ(`FT_SCROLL_TARGET=legacy`)のとき常に nil を返すため、
    /// それを fail-fast の根拠にすると legacy 指定時に「セレクタが実在するのに matched nothing」
    /// と誤判定する。殺しスイッチ有効時は判定自体をスキップし、従来(legacy)挙動へ流す。
    /// runScrollSearch(scrollTo/exist/notExist 系)と scroll/scrollToEdge/flick の両方から呼ぶ
    static func scrollFrameUnresolved(_ step: FlowStep, in snapshot: SnapshotResponse) -> Bool {
        guard Self.coordinateScrollEnabled, let locator = step.scrollFrame else { return false }
        return Self.match(locator, in: snapshot) == nil
    }

    /// 明示 scrollFrame が解決できないときの fail-fast 文言。呼び手ごとに動詞(action)を渡す
    /// (scrollTo/exist/notExist 系="search"・scroll/scrollToEdge="swipe"・flick="flick")。
    /// **`swipes > 0`(容器が解決していたのに送信中に消えた)なら文言を差し替える** ——
    /// スワイプ送信後にも「送られなかった」と言うのは嘘になるため
    static func scrollFrameFailFastMessage(_ step: FlowStep, action: String, swipes: Int) -> String {
        let sel = step.scrollFrame?.summary ?? "?"
        guard swipes > 0 else {
            let verb = action == "search" ? "the search was not run" : "the \(action) was not sent"
            return "scrollFrame \"\(sel)\" matched nothing on this screen, so \(verb) —"
                + " a whole-screen swipe could tap something under the finger."
                + " Fix the scrollFrame selector, or remove it to search the whole screen."
        }
        return "scrollFrame \"\(sel)\" disappeared from the tree after \(swipes) swipe(s),"
            + " so the search stopped."
    }

    /// スクロールヒント(WebView の画面外ノード・実座標付き)から「あと何 px 先か」を出す。
    ///
    /// **なぜ**: スクロール探索の支配項はスワイプ1回のジェスチャ時間(Android 実測 1.05s / 974px。
    /// スナップショットは 25ms)。距離が分かれば、固定幅スワイプ N 回を少数の長距離ドラッグに
    /// 置き換えられる(1500px を 0.44s)。ヒントは Android の WebView だけが供給する
    /// (Chromium が全ドキュメントをツリーに載せる。ネイティブのリストは画面外を載せないため、
    /// **ヒントが無いことは不在の根拠にならない** = 従来ループの代替であって不在の即断には使わない)。
    ///
    /// 戻り値: 正 = 指を上へ(内容を下へ読み進める)動かす px。ヒント不一致・方向不一致・
    /// 水平方向・既に画面内なら nil(呼び手は従来のスワイプに落ちる)。
    /// 呼び手はスナップショットごとに再計算する(ドラッグの実移動はフリングで揺れるが、
    /// 毎回測り直す自己補正で収束する。較正は持たない)
    static func offscreenJump(step: FlowStep, snapshot: SnapshotResponse,
                              finger: FTSwipeDirection) -> Double? {
        guard finger == .up || finger == .down,
              let hints = snapshot.offscreen, !hints.isEmpty else { return nil }
        let pseudo = SnapshotResponse(sessionBundleID: nil, screen: snapshot.screen,
                                      elements: hints, truncatedCount: 0)
        guard let (hint, _) = Self.resolve(step: step, in: pseudo, strictForAssert: true) else {
            return nil
        }
        let screen = snapshot.screen
        // 着地目標: 要素の上端を画面の 40% 位置へ(中央より上 = 下端の固定要素・タブに重ねない)
        let jump = hint.frame.y - (screen.y + screen.height * 0.4)
        // 方向が合っているときだけ(逆向きのヒントで往復しない。ドラッグ過走の戻しは
        // ここではなく通常ループの資格 = 見えたら resolve が拾う、に任せる)
        if finger == .up, jump > screen.height * 0.3 { return jump }
        if finger == .down, jump < -screen.height * 0.3 { return jump }
        return nil
    }

    /// `scrollToEdge` が端と認めるまでに必要な「署名が不変だった周回数」。
    ///
    /// 既定は **2**。Android では次のスワイプがフリングの停止だけに消費されて1回空振りすることがあり、
    /// 1回で打ち切ると途中で止まる(2026-07-27 実測: scrollToTop が row_22 付近で停止)。
    ///
    /// **ヒントを供給する画面(WebView)だけ 1 に下げる**。`offscreen` はその方向にまだ内容が
    /// あるかの**肯定的な証拠**で、`remainingJump == nil` = 「もう先が無い」。これがあるなら
    /// 署名の不変化を2回重ねる必要はない。
    /// 効くのは iOS xcuitest の WebView で、**端に着いた後に捨てのスワイプを2回撃っていた**
    /// (1スワイプ約2.5秒 = 実測 scrollToTop 中央値 12.1s の主成分。docs/performance-tuning.md §8)。
    /// 供給の無い画面(ネイティブ・旧ブリッジ・hybrid の WebViewDelegatingDriver)は
    /// `offscreen` が nil なので従来どおり 2 のまま = 挙動は変わらない
    static func unchangedRoundsForEdge(snapshot: SnapshotResponse,
                                       remainingJump: Double?) -> Int {
        guard remainingJump == nil, let hints = snapshot.offscreen, !hints.isEmpty else { return 2 }
        return 1
    }

    /// スクロールヒントの端(その方向にまだ続く実座標の限界)までの距離。scrollToEdge 用。
    /// 正 = 指を上へ。ヒントがその方向に無ければ nil(従来の署名ループへ)
    static func offscreenEdgeJump(snapshot: SnapshotResponse,
                                  finger: FTSwipeDirection) -> Double? {
        guard finger == .up || finger == .down,
              let hints = snapshot.offscreen, !hints.isEmpty else { return nil }
        let screen = snapshot.screen
        // 閾値は小さくてよい(100px): 端スクロールは行き過ぎても端で止まる(クランプされる)ので
        // 過走が無害。scrollTo(offscreenJump)の 30% 閾値とは安全条件が違う
        switch finger {
        case .up:
            // 下端: いちばん下のヒント下端が画面下端に来るまでの残り
            guard let maxBottom = hints.map({ $0.frame.y + $0.frame.height }).max() else { return nil }
            let jump = maxBottom - (screen.y + screen.height)
            return jump > 100 ? jump : nil
        case .down:
            // 上端: いちばん上のヒント上端(負)が画面上端に来るまでの残り
            guard let minTop = hints.map({ $0.frame.y }).min() else { return nil }
            let jump = minTop - screen.y
            return jump < -100 ? jump : nil
        default:
            return nil
        }
    }

    /// 長距離ドラッグの1ジェスチャ分の始点・終点(純粋関数・単体テスト対象)。
    /// container(webView の可視矩形)内で、上下 15% のマージンを避けて縦線上を動かす。
    /// 1ジェスチャで賄えない距離は呼び手のループ(スナップショット→再計算)が刻む。
    ///
    /// **容器は画面と交差させる**(`ScrollGeometry.intersection` と同じ規則)。
    /// 交差を取らないと、画面からはみ出した容器で**画面外の座標を撃つ**ことになる
    /// (WebView が画面より高いときに起き得た。2026-08-03 に scrollFrame 側と規則を揃えた)
    static func dragGesture(jump: Double, container rawContainer: FTRect,
                            viewport: FTRect? = nil, vertical: Bool = true)
        -> (fromX: Double, fromY: Double, toX: Double, toY: Double)? {
        let container = viewport.flatMap { ScrollGeometry.intersection(rawContainer, $0) }
            ?? rawContainer
        let extent = vertical ? container.height : container.width
        let margin = extent * 0.15
        let usable = extent - margin * 2
        guard usable > 100 else { return nil }
        // 0.9 掛け: フリング分の過走を抑える(過走しても次周回の再計算で戻るが、往復は遅い)
        let distance = min(abs(jump) * 0.9, usable)
        guard distance > 50 else { return nil }
        if vertical {
            let x = container.x + container.width / 2
            if jump > 0 {   // 指を上へ
                let fromY = container.y + container.height - margin
                return (x, fromY, x, fromY - distance)
            }
            let fromY = container.y + margin
            return (x, fromY, x, fromY + distance)
        }
        // 横: y は容器の中心線。jump > 0 = 指を左へ(縦の「+ = 上」と同じ「進む向き」規約)
        let y = container.y + container.height / 2
        if jump > 0 {
            let fromX = container.x + container.width - margin
            return (fromX, y, fromX - distance, y)
        }
        let fromX = container.x + margin
        return (fromX, y, fromX + distance, y)
    }

    /// ヒント跳躍のドラッグ実行。ゆっくり終える(pressSeconds でフリングを抑えつつ、
    /// 距離に応じた duration)。失敗したら false(呼び手は従来のスワイプへ落ちる)
    func hintDrag(jump: Double, container: FTRect, viewport: FTRect,
                          phase: inout PhaseAccumulator) async -> Bool {
        guard let g = Self.dragGesture(jump: jump, container: container,
                                       viewport: viewport) else { return false }
        let clock = ContinuousClock()
        let start = clock.now
        let duration = min(max(abs(g.toY - g.fromY) / 2500, 0.3), 0.7)
        do {
            // **driver.drag を直に呼ばない**(in-app は 501。StepExecutor+Settle の dragWithFallback)
            try await dragWithFallback(fromX: g.fromX, fromY: g.fromY, toX: g.toX, toY: g.toY,
                                       pressSeconds: 0.08, durationSeconds: duration)
            phase.actionMs += Self.ms(clock.now - start)
            return true
        } catch {
            phase.actionMs += Self.ms(clock.now - start)
            return false   // drag 未対応ドライバ等 → このヒントは諦めて通常スワイプ
        }
    }

    /// **フリングを出さないドラッグ**。逆走査専用。hintDrag(0.3〜0.7s)は Android では
    /// まだ速く、189px のドラッグが慣性で 700px 走って**逆向きの飛び越し**になった
    /// (2026-08-06 に Emulator で観測)。指を離す直前の速度が閾値を下回るよう、
    /// **距離ぶんの時間を必ず取る**(reverseSweepDragSpeed px/s)
    func slowDrag(jump: Double, container: FTRect, vertical: Bool = true,
                          phase: inout PhaseAccumulator) async -> Bool {
        guard let g = Self.dragGesture(jump: jump, container: container,
                                       viewport: container, vertical: vertical) else { return false }
        let clock = ContinuousClock()
        let start = clock.now
        let distance = vertical ? abs(g.toY - g.fromY) : abs(g.toX - g.fromX)
        let duration = min(max(distance / Self.reverseSweepDragSpeed, 0.6), 3.0)
        defer { phase.actionMs += Self.ms(clock.now - start) }
        do {
            // **driver.drag を直に呼ばない**(in-app は 501。StepExecutor+Settle の dragWithFallback)
            try await dragWithFallback(fromX: g.fromX, fromY: g.fromY, toX: g.toX, toY: g.toY,
                                       pressSeconds: 0.15, durationSeconds: duration)
            return true
        } catch {
            return false
        }
    }

    /// スナップショット中の webView コンテナ(ヒントのドラッグ領域)。無ければ nil
    static func webViewContainer(in snapshot: SnapshotResponse) -> FTRect? {
        snapshot.elements.first(where: { $0.type == "webView" })?.frame
    }

    /// **スクロール探索の本体**。`scrollTo` コマンドと、`tap(scroll:)` / `exist(scroll:)` の
    /// 内蔵探索が共有する(同じ挙動を2箇所に書かない)。見つけたら静止させてから返すので、
    /// 呼び手はそのまま解決・操作してよい
    /// StepExecutor+Assert.swift の executeAssertExists(`exist(scroll:)`)からも呼ぶため internal。
    /// `recoverOnMiss` = 見つからずに端まで来たとき、**逆向きの細刻みで1往復だけ拾い直す**か。
    /// `notExist(scroll:)` の前奏だけは false(見つからないのが期待値なので、往復は丸損)
    func runScrollSearch(step: FlowStep, recoverOnMiss: Bool = true,
                         phase: inout PhaseAccumulator) async throws -> ScrollSearchResult {
        let clock = ContinuousClock()
        let direction = FTSwipeDirection(rawValue: step.direction ?? "") ?? .up
        // 負値だと 0...(-1) が ClosedRange 生成で trap(クラッシュ)するため 0 で下限クランプ
        let maxSwipes = max(0, step.maxSwipes ?? FlowStep.defaultMaxSwipes)
        var viaXCUITest = false
        var hintJumps = 0
        var settleCapped = false
        // 自己補正の材料(直前の周回のツリー)。**較正値は持たず毎周測り直す**
        var previousSnapshot: SnapshotResponse?
        // 撃ったスワイプ数と、**振っても木が1文字も変わらなかった**連続回数。
        // 端に着いた後も上限まで振り続けるのは丸損なので、2周続けて変化が無ければ打ち切る
        // (1周で切らないのは、遅れて描画される行を「動かなかった」と誤断しないため)
        var swipes = 0
        var unmovedRounds = 0
        // 打ち切りの理由文を分けるためだけの記録(ScrollSearchResult.contentEverMoved 参照)
        var contentEverMoved = false
        var truncatedDuringSearch = 0
        // スクロールした容器(中身が入れ替わった領域)。逆走査の刻みの基準
        var scrolledContainer: FTRect?
        for attempt in 0...maxSwipes {
            // **1周目だけは静止を待ってから撮る**。直前の操作がプログラム的な
            // アニメーションスクロール(「先頭へ」等)だと、ブリッジの整定はすり抜けることがあり
            // (アニメが始まる前に「変化なし」と判定される)、動く前のツリーで解決すると
            // **古い座標をタップして別の要素が選ばれる**(2026-08-02 に CMP で実測。
            // ステップは成功のまま = 黙って誤った結果)。2周目以降はスワイプ後の
            // settleAfterScroll / settledSignature が既に待っているので素取得でよい
            var snapshot: SnapshotResponse
            if attempt == 0 {
                snapshot = try await settledSignature(phase: &phase).snapshot
            } else {
                let start = clock.now
                // **スワイプ直後は必ずキャッシュを捨てて撮る**(Android のみ実費。iOS は素通し)。
                // ブリッジの整定(a11y の静穏待ち)を通っても、**Compose の a11y ツリーは
                // 数十 ms 遅れて公開される** —— 応答時点の素の snapshot が**スワイプ前の位置**を
                // 返す瞬間があり(2026-08-03 実測: 4回中2回。素=row_01 / refresh=1=row_06)、
                // 古いツリーで探索を続けると「動かなかった」と誤認する・見つけた要素が直後の
                // 解決で消える(`cannot resolve the locator` として現れる)。
                // 検証系の期限切れ直前の1回とは別で、ここは**毎周払う**必要がある
                snapshot = try await freshSnapshot(.afterOwnMove)
                phase.snapshotMs += Self.ms(clock.now - start)
            }
            try await dismissInterruption(in: &snapshot, phase: &phase)
            // **周回ごとに記録する**(最終木では消えている情報。ScrollSearchResult の宣言参照)
            truncatedDuringSearch = max(truncatedDuringSearch, snapshot.truncatedCount)
            if let previousSnapshot {
                scrolledContainer = Self.changedContentContainer(before: previousSnapshot,
                                                                 after: snapshot)
                    ?? Self.movedContentContainer(before: previousSnapshot, after: snapshot,
                                                  vertical: direction == .up || direction == .down)
                    ?? scrolledContainer
            }
            // **1回の移動量が容器を超えると要素を飛び越す**(スクロール探索は行き過ぎた要素を
            // 拾い直さない)。実測して超えていたら次の刻みを詰める。
            //
            // **基準は画面ではなく容器**(2026-08-05 修正)。旧実装は画面の高さで割っており、
            // 容器は定義上それより小さいので**ほぼ発火しなかった** —— §3.18(f) の実測を当てると
            // SwiftUI は 1 スワイプ 681pt に対し閾値 0.8×874=699pt で素通りする一方、
            // リストの可視高は 492pt = **1.38 倍の超過**(いちばん取りこぼす SUT で無効だった)。
            //
            // **効くのは `scrollFrame` を書いた経路だけ**。刻みを縮める唯一の口は `spanScale` →
            // `scrollPath` で、あちらは領域未指定なら nil を返してエンジン既定に任せるため。
            // 既定経路の飛び越しをホスト側で塞ぐには座標スワイプを常用するしかなく、それは
            // 2度撤回済み(docs/performance-tuning.md §3.19)。**ここを既定経路へ広げないこと**
            let vertical = direction == .up || direction == .down
            if let previousSnapshot,
               let travel = Self.measuredTravel(before: previousSnapshot, after: snapshot,
                                                vertical: vertical) {
                let container = scrollContainer(step: step, in: snapshot, vertical: vertical)
                    .flatMap { ScrollGeometry.intersection($0, snapshot.screen) } ?? snapshot.screen
                let extent = vertical ? container.height : container.width
                if travel > extent * Self.travelCeilingRatio {
                    spanScale = max(Self.minSpanScale, spanScale * Self.spanShrinkFactor)
                }
            }
            // スクロール探索でも type+index フォールバックは偽陽性のもとなので使わない
            if let (element, fallback) = Self.resolve(step: step, in: snapshot, strictForAssert: true) {
                // **見つけただけでは足りない**: 画面の縁で見切れている要素は、フレームワークに
                // よっては frame がクランプされて**タップが外れる**(Compose iOS の既知の上流制約)。
                // まだ送れるなら、完全に見えるまでもう1回スワイプする。
                // 1回の移動量が小さいほど「見えた瞬間 = 見切れ位置」で止まるので、
                // 領域指定(scrollFrame)や刻みの細かい設定ほどここに掛かる
                // (2026-08-02 実測: CMP で #row_40 が y=829/高さ56 = 下端 885 > 画面 874 で見つかり、
                // タップが別の行に取られた。従来の全画面スワイプでは y=720 で見つかっていた)
                // 領域が指定されていないときは**報告された木から clip 元の祖先**を採る。
                // これが無いと viewport が画面全体になり、容器の外に並ぶ ghost 要素を
                // 「見えている」と判定して探索がそこで止まる(2026-08-03 実測: #row_30 が
                // label=nil・y=783 = 容器 230..692 の外で見つかり、タップが飲まれた)
                let viewport = (scrollContainer(step: step, in: snapshot,
                                                vertical: direction == .up || direction == .down)
                                ?? Self.clippingContainer(of: element, in: snapshot.elements,
                                                          inferring: step.containerInference ?? true))
                    .flatMap { ScrollGeometry.intersection($0, snapshot.screen) } ?? snapshot.screen
                if attempt < maxSwipes,
                   Self.isClippedByViewport(element, screen: viewport) {
                    // **行き過ぎた側なら逆へ送る**(recoveryDirection 参照)。探索方向のまま
                    // 送り続けると、既に通り過ぎた要素は遠ざかるだけで永久に可視域へ戻らない
                    var recovery = step
                    let back = Self.recoveryDirection(for: element, container: viewport,
                                                      searching: direction)
                    recovery.direction = back.rawValue
                    let path = scrollPath(step: recovery, intent: .search, in: snapshot)
                    // **path が無い(= 全幅フリングになる)既定経路だけ**、必要距離の遅いドラッグで
                    // 寄せる(clipRecoveryJump 参照。フリングは逆側へ再飛び越しして往復振動する)。
                    // scrollFrame あり = path は元々容器基準の短い送りなので置き換えない
                    // (置き換えると SwiftUI で +28% の実退行。2026-08-08 に 92s/72s の A/B で確定)。
                    // ジャンプ量 40pt 未満は嘘 frame(クランプ)の兆候なので従来スワイプへ
                    if path == nil,
                       let jump = Self.clipRecoveryJump(for: element, viewport: viewport,
                                                        finger: back),
                       abs(jump) >= 40,
                       await slowDrag(jump: jump, container: viewport,
                                      vertical: back == .up || back == .down, phase: &phase) {
                        continue
                    }
                    let finger = FTSwipeDirection(rawValue: recovery.direction ?? "") ?? direction
                    if try await swipeWithFallback(finger, intent: .search, path: path,
                                                   phase: &phase) { viaXCUITest = true }
                    continue
                }
                // **木に居ること ≠ 画面に居ること**: 中心が**画面**の外なら「見つかった」に
                // しない(下の未検出経路へ合流)。**効くのは弾切れの周回だけ** —— それ以外は上の
                // isClippedByViewport が先に寄せに行く。
                // **isClippedByViewport と同じサイズ免除が要る**(offscreenScrollGateAdvisory 参照):
                // ビューポートより大きい/ゼロサイズの要素は isClippedByViewport が false を返し
                // 続けるので、免除しないとゲートだけが弾切れ前から found を拒否し、探索方向へ
                // 進むたび遠ざかる(縦3000pt の要素で確認)。
                // **基準は viewport(容器)ではなく screen**: 容器の外だが画面には映っている
                // ghost は、掴み直し + `RefGuard` の警告つきタップという既存の設計で扱う
                // (ここで failed にすると、その警告が拒否へ格上げされて
                // `testTapAfterSearchNotesWhenTheGhostPersists` の経路ごと消える)。
                // 見切れ(中心は画面内)も同じ理由で found のまま —— タップは通る。
                // 判定は MCP の ⚠️offscreen と共有(TapTargetGeometry.offscreenScrollGateAdvisory)
                if TapTargetGeometry.offscreenScrollGateAdvisory(for: element, screen: snapshot.screen) == nil {
                    // **スワイプしたなら静止を待つ**(空打ち→静止待ちの順。settleAfterFind 参照)。
                    // スワイプしていない周回(attempt == 0)は静止しているので追加コストを払わない
                    if attempt > 0 {
                        settleCapped = try await settleAfterFind(step: step, element: element,
                                                                 snapshot: snapshot, phase: &phase)
                    }
                    // **成功時も swipes を載せる**: 失敗文にしか使わなかった頃は既定の 0 で
                    // 害が無かったが、MCP の ft_scroll_to が所要時間の内訳へ出すようになり、
                    // 「何本振って辿り着いたか」が常に 0 と報告されるようになった
                    return ScrollSearchResult(found: true, fallback: fallback, viaXCUITest: viaXCUITest,
                                              hintJumps: hintJumps, settleCapped: settleCapped,
                                              swipes: swipes,
                                              maxTruncatedDuringSearch: truncatedDuringSearch)
                }
            }
            if attempt < maxSwipes {
                // **明示 scrollFrame が解決できないなら、ここで打ち切る(1本も振らない)**。
                // 空振りしたまま全画面スワイプへ黙って退化すると、カード上のボタン等
                // 無関係な要素を発火させ得る(2026-08-08・Apple マップの実害: 申告した
                // #MUScrollableStackView が次の瞬間ツリーから落ち、退化したスワイプが
                // カードの「計画」ボタンを叩いて画面遷移した)。**探索中に容器が消えた場合も同型**
                // なので、初回だけでなく毎周チェックする。
                // **scrollContainer ではなく Self.scrollFrameUnresolved で判定する**
                // (scrollContainer は殺しスイッチ時に常に nil を返すため、それをそのまま使うと
                // legacy 指定時に「セレクタが実在するのに matched nothing」と誤検知する。2026-08-08)
                if Self.scrollFrameUnresolved(step, in: snapshot) {
                    return ScrollSearchResult(found: false, fallback: nil, viaXCUITest: viaXCUITest,
                                              hintJumps: hintJumps, swipes: swipes,
                                              scrollFrameMissing: true,
                                              maxTruncatedDuringSearch: truncatedDuringSearch)
                }
                if let earlier = previousSnapshot,
                   Self.contentSignature(earlier.elements)
                       == Self.contentSignature(snapshot.elements) {
                    unmovedRounds += 1
                    if unmovedRounds >= Self.unmovedRoundsToStopSearch {
                        // **打ち切る前に整定まで待って確かめる**(2026-08-06 に Flutter/Android で
                        // 誤発火): a11y ツリーは遅れて公開されるので、**動いている最中でも
                        // 2周続けて同じ木**が返ることがある。`settledSignature` は
                        // キャッシュを捨てて連続2回一致まで待つので、遅れと停止を区別できる。
                        // 費用は打ち切る局面の1回だけ(正常系には掛からない)
                        let confirmed = try await settledSignature(phase: &phase)
                        if Self.contentSignature(confirmed.snapshot.elements)
                            != Self.contentSignature(snapshot.elements) {
                            snapshot = confirmed.snapshot
                            previousSnapshot = snapshot
                            unmovedRounds = 0
                            contentEverMoved = true
                            continue
                        }
                        // シート展開ヒントは**対象の容器が画面の大半を占めない**ときだけ
                        // (全画面リストの末尾到達で毎回シートを探しに行かせないためのゲート。2026-08-08)。
                        // **scrollFrame 未指定でも判定する**: 半開きシートの中で
                        // 止まる形は指定の有無に関係なく起きるのに、指定したときにしかヒントが
                        // 出ていなかった —— 実測(Apple マップの経路手順)では、未指定の1回目が
                        // 「動かなくなった」としか言わず、同じ画面で scrollFrame を渡した2回目に
                        // だけ「シートを広げろ」が出て、そこで初めて解けた
                        let containerIsPartialHeight = snapshot.screen.height > 0
                            && (scrollContainer(step: step, in: snapshot, vertical: vertical)
                                .map { $0.height < snapshot.screen.height * 0.8 }
                                ?? Self.partialHeightSheetExists(in: snapshot))
                        var result = ScrollSearchResult(found: false, fallback: nil,
                                                        viaXCUITest: viaXCUITest,
                                                        hintJumps: hintJumps,
                                                        swipes: swipes, stoppedUnmoving: true,
                                                        contentEverMoved: contentEverMoved,
                                                        containerIsPartialHeight: containerIsPartialHeight,
                                                        maxTruncatedDuringSearch: truncatedDuringSearch)
                        guard recoverOnMiss, step.containerInference ?? true,
                              // 半開きシートで呼び手が展開・再試行するなら、逆走査はそちらの
                              // 再試行(全画面高)に譲る(defersPartialSheetRecovery の宣言参照)
                              !(defersPartialSheetRecovery && containerIsPartialHeight),
                              let container = (scrolledContainer
                                               ?? Self.overflowingContainer(in: snapshot))
                                  .flatMap({ ScrollGeometry.intersection($0, snapshot.screen) })
                        else { return result }
                        // **端に着いたのに見つからない = 途中で飛び越した可能性**。
                        // 既定経路(scrollFrame 未指定)は刻みがエンジン任せで縮められないので、
                        // ここでだけ推測した容器で細刻みの逆走査を掛ける
                        // (通常の送りには触らない = 2度撤回した「暗黙の座標化」にならない)
                        if let recovered = try await reverseSweep(step: step, container: container,
                                                                  searching: direction,
                                                                  phase: &phase) {
                            result.found = true
                            result.fallback = recovered
                            result.reverseSweeps += 1
                            // 推測した容器に**申告済みの容器**が重なっていればその名前を出す。
                            // 重ならなければ nil のまま = 注記は総称に留める(推測した矩形を
                            // 座標で名乗っても `scrollFrame:` には書けない)
                            result.suggestedScrollFrame = ScrollFrameCandidates.selector(
                                matching: container, in: snapshot)
                        }
                        return result
                    }
                } else {
                    // **比較が成立した回だけ**「動いた」と数える(1周目は previousSnapshot が
                    // 無いので、ここへ来ても何とも比べていない)
                    if previousSnapshot != nil { contentEverMoved = true }
                    unmovedRounds = 0
                }
                // ヒント跳躍: 距離が分かるときは固定幅スワイプでなく長距離ドラッグで寄せる。
                // ドラッグ後は静止を待たず次周回のスナップショット(25ms)で測り直す(自己補正)
                if let jump = Self.offscreenJump(step: step, snapshot: snapshot, finger: direction),
                   let container = Self.webViewContainer(in: snapshot),
                   await hintDrag(jump: jump, container: container,
                                  viewport: snapshot.screen, phase: &phase) {
                    hintJumps += 1
                    swipes += 1
                    previousSnapshot = snapshot
                    continue
                }
                if try await swipeWithFallback(direction, intent: .search,
                                               path: scrollPath(step: step, intent: .search,
                                                                in: snapshot),
                                               phase: &phase) { viaXCUITest = true }
                swipes += 1
                previousSnapshot = snapshot
            }
        }
        // **弾切れでも逆走査を1回だけ試す**(2026-08-08 実測: 端のバウンスで内容署名が毎周
        // 揺れ、「2周連続不変」の端判定に到達しないまま maxSwipes を使い切る形が RN の
        // 横カルーセルで 2/10 残った。既に通り過ぎている公算が高い局面で、失敗経路限定なので
        // 正常系のコストはゼロ。ゲートは stoppedUnmoving 側の逆走査と同じ)
        if recoverOnMiss, step.containerInference ?? true,
           let latest = previousSnapshot,
           let container = (scrolledContainer ?? Self.overflowingContainer(in: latest))
               .flatMap({ ScrollGeometry.intersection($0, latest.screen) }),
           let recovered = try await reverseSweep(step: step, container: container,
                                                  searching: direction, phase: &phase) {
            var result = ScrollSearchResult(found: true, fallback: recovered,
                                            viaXCUITest: viaXCUITest,
                                            hintJumps: hintJumps, swipes: swipes,
                                            maxTruncatedDuringSearch: truncatedDuringSearch)
            result.reverseSweeps = 1
            result.suggestedScrollFrame = ScrollFrameCandidates.selector(matching: container,
                                                                         in: latest)
            return result
        }
        return ScrollSearchResult(found: false, fallback: nil, viaXCUITest: viaXCUITest,
                                  hintJumps: hintJumps, swipes: swipes,
                                  maxTruncatedDuringSearch: truncatedDuringSearch)
    }
}
