// StepExecutor+Settle.swift
// ジェスチャのフォールバックと整定(settle・空打ち・逆走査・clip 補正。drag/doubleTap/pinch の
// フォールバックは +Actions 側)。本体は StepExecutor.swift(instance 状態はそちらに置く)

import Foundation

extension StepExecutor {

    /// swipe を通常ドライバ→(typeDriverGestures 申告/ラッチ済みなら最初から、501 ならキャッチしてから)
    /// typeDriver の順で試す。swipe は ref を使わないので要素再解決は不要。
    /// 戻り値: true = typeDriver(XCUITest)経由で実行した
    /// スクロール探索で要素を見つけた直後、**その要素の frame が動かなくなるまで**待つ。
    /// 連続2回同じ frame なら静止とみなす。見失った場合・上限に達した場合はそのまま抜ける
    /// (探索自体は成功しているので、ここで失敗にはしない = 判定を1箇所に保つ)。
    /// 上限はフリングの減速が収まる実測レンジに合わせた固定値で、調整ノブにはしない
    /// 戻り値: **静止を確認できたか**。false = 周回上限で打ち切った(= まだ動いているかもしれない)。
    /// 呼び手は注記にする(黙ると「動いている画面の座標をタップ」が誤った成功として通る)
    @discardableResult
    func settleAfterScroll(step: FlowStep, found: ElementInfo,
                                   phase: inout PhaseAccumulator) async throws -> Bool {
        let clock = ContinuousClock()
        var previous = found.frame
        var lastSnapshotMs = 0
        // settledSignature と同じ規律: 基本予算を超えて回すのは**まだ減速しているとき**だけ
        var motion: [Double?] = []
        for poll in 0..<Self.scrollSettleMaxDeceleratingPolls {
            let waitStart = clock.now
            try await Task.sleep(for: .milliseconds(
                Self.settleSleepMs(afterSnapshotMs: lastSnapshotMs,
                                   bypassing: bypassesCache(.afterOwnMove))))
            phase.waitMs += Self.ms(clock.now - waitStart)
            let start = clock.now
            // 静止判定も**キャッシュを捨てて**撮る。古いツリーは連続して同じ座標を返すので、
            // 素取得だと「2回続けて同じ = 止まった」が**遅れて公開された古い位置**で成立する
            // (runScrollSearch のスワイプ後の snapshot と同じ理由)
            let snapshot = try await freshSnapshot(.afterOwnMove)
            lastSnapshotMs = Self.ms(clock.now - start)
            phase.snapshotMs += lastSnapshotMs
            // 解決できなくなった = このスナップショットでは判定材料が無い。静止は名乗らない
            guard let (element, _) = Self.resolve(step: step, in: snapshot,
                                                  strictForAssert: true) else { return false }
            if element.frame == previous { return true }
            motion.append(max(abs(element.frame.x - previous.x), abs(element.frame.y - previous.y)))
            previous = element.frame
            if poll + 1 >= Self.scrollSettleMaxPolls, !SettleMotion.isDecelerating(motion) { break }
        }
        return false
    }

    /// スクロール探索終端の空打ちドラッグを (x,y) に打ってよいか。打たない条件は2つ
    /// (どちらも「空打ちが別の UI に渡って画面が変わる」実害の再発防止):
    /// 1. 対象より手前の要素が点を取る(タブバー等。pointIsTakenByFrontElement)
    /// 2. 点が**画面下端の帯**にある。タブバーの実ヒット域は a11y frame の下(ホームインジケータ域
    ///    =画面下端)まで伸びるのに、その帯は a11y 上は空白で 1 が効かない
    ///    (実測 2026-07-28: タブ frame 下端 840・画面高 874 で、帯内 y=841.8 への空打ちで
    ///    #tab_home が反応しホームへ遷移。E2E-iOS 07/16 の間欠フレークの根因)
    static func emptyDragIsSafe(x: Double, y: Double, of element: ElementInfo,
                                in elements: [ElementInfo], screen: FTRect) -> Bool {
        if pointIsTakenByFrontElement(x: x, y: y, of: element, in: elements) { return false }
        if y >= screen.y + screen.height - Self.bottomUncoveredBand { return false }
        return true
    }

    /// 画面下端の a11y 空白帯の高さ(pt)。実測の空白(874-840=34)+整定位置のブレの余裕
    static let bottomUncoveredBand: Double = 48

    /// 要素を **clip している容器**の矩形(見切れ判定の viewport)。**スクロールの座標化には
    /// 使わない** = 暗黙の座標化とは別物(あちらは2度撤回済みで3度目は無い)。
    ///
    /// Compose iOS は容器の外・縁に子を報告する。`scrollable` の申告は Compose では出ないので、
    /// **報告された木そのものから容器を採る**: スナップショットは pre-order + depth なので、
    /// 直前にある depth の小さい要素が容器の候補。ただし**ブリッジは要素を間引く**
    /// (identifier の無い other 等)ので候補が叔父のことがある。そこで
    /// 「同じ depth の兄弟が2つ以上その中に居る」ことを確かめてから採用する ——
    /// 叔父を掴んだときは兄弟が誰も中に居ないので nil に落ちる。
    ///
    /// **交差の有無で絞らない**(2026-08-05 に条件を外した)。旧実装は「容器と交差しないときだけ」
    /// 容器を返していたため、**縁をまたぐ要素で nil に落ちて viewport が画面全体になっていた**。
    /// Compose は縁をまたぐ行を「原点はクリップ前・サイズはクリップ後」の混成で返すので、
    /// `#list_rows` が y 230..692 のとき `#row_30` が `(16,206 370x43)` = **中心 227.5 が容器の外**
    /// になる。画面基準では「見えている」と判定されて探索が止まり、隙間をタップして飲まれていた
    /// (S0110 の失敗 21 件中 **12 件**がこの形)。
    ///
    /// **scrollable を申告している祖先があればそれを優先する**(2026-08-23・受け手の最小再現):
    /// 横カルーセル(`other scroll`)> カード(`clickable`)> ラベル+バッジ、の木では上の規則が
    /// **カード自身**を容器に選ぶ(同じ深さの子を2つ持つ直近の祖先だから)。右にはみ出したカードを
    /// 画面と交差させると幅 42pt しか残らず、幅 98pt のラベルが「viewport より大きい」扱いになって
    /// 見切れ判定が免除され、回復ドラッグに入らないまま既定の全画面スワイプ(縦容器基準)が
    /// 横カルーセルに届かず `nothing moved` で落ちた。クリップするのはカードではなくスクロール容器
    /// なので、**申告があるときはそれが正**。申告の無い木(Compose iOS は xcuitest で申告できない)は
    /// 従来の規則のまま = 挙動は変わらない
    static func clippingContainer(of element: ElementInfo, in elements: [ElementInfo],
                                  inferring enabled: Bool = containerInferenceEnabled) -> FTRect? {
        guard enabled,
              let index = elements.firstIndex(where: { $0.ref == element.ref }) else { return nil }
        let tight = siblingRuleContainer(of: element, at: index, in: elements)
        // **申告の祖先へ倒すのは「深さ由来の候補が小さすぎる」ときだけ**(2026-08-28)。
        //
        // 2026-08-23 に申告を無条件で優先したところ、縦リストのように**行の容器が scrollable を
        // 申告せず外側の全画面 scrollView だけが申告する**木で容器が画面全体へ広がり、
        // 慣性で動いている最中の見切れ・整定判定が効かなくなった(iOS xcuitest 限定の退行。
        // maintainer-notes §4.5.1)。**それ以外は 2026-08-23 以前とまったく同じ経路**にする ——
        // 候補が無ければ nil を返すところまで含めて(nil と「画面全体」は下流で別物として効く)。
        //
        // 倒す条件は**元の不具合そのものの形**: 横カルーセルではカード(164 幅)を容器に選び、
        // カルーセル(402 幅)で切ると **42 幅**になって要素「スタンプラリー」(98 幅)を収められず、
        // 「viewport より大きい」扱いで見切れ判定が免除された。**小さすぎる候補だけを退ける**。
        //
        // **収まり・重なりでは判定しない**(2026-08-28 に2案とも実機で否定)。動いている最中は
        // 行が容器の縁・外に報告されるので、位置を見る述語は**効いてほしい瞬間だけ**申告容器へ
        // 倒れる。代償として、位置的に無関係な候補を退ける力は失う(実アプリのコーパス
        // `and-browser_weather_weekly` の ghost 1件。2026-08-23 以前の基準値へ戻る)——
        // スクロール探索が別の行を撃つ実害と、警告レベルの検知1件を秤にかけた判断
        if let tight, let scroller = nearestScrollableAncestor(of: element, at: index, in: elements),
           let clipped = ScrollGeometry.intersection(tight, scroller.frame),
           !canHold(clipped, element.frame) {
            return scroller.frame
        }
        return tight
    }

    /// 「同じ深さの子を2つ持つ直近の祖先」= Compose iOS 向けの近似(申告の無い木ではこれが唯一の手)。
    /// preorder 祖先の連鎖(ancestors(of:in:) と同じ復元)を辿り、**同じ depth の行を1件も含まない
    /// 候補は飛ばす**(実機 iPhone 13・2026-08-31: 見出し `staticText "アカウント"` d11 95x22 が
    /// `#btn_logout` d12 の直前に来て「直前の depth の小さい要素=親」の旧仮定を崩し、容器を丸ごと
    /// 見失っていた。見出しは行を1件も含まないので葉と分かる)。
    /// **要素自身との交差を gate にしてはいけない**: ghost(容器の完全に外へ報告された行)は容器と
    /// 交差しないが、その容器こそ `isOutsideContainer` が要る答え。行を1件でも含む候補は旧規則の
    /// まま(2件未満なら nil で確定、上へは辿らない = 2026-08-23 以前の「直近の祖先1つ」の規律)
    private static func siblingRuleContainer(of element: ElementInfo, at index: Int,
                                             in elements: [ElementInfo]) -> FTRect? {
        var depth = element.depth
        var cursor = index
        while cursor > 0 {
            cursor -= 1
            let candidate = elements[cursor]
            guard candidate.depth < depth else { continue }
            depth = candidate.depth
            guard candidate.frame.width > 0, candidate.frame.height > 0 else { continue }
            let siblings = descendants(of: candidate, in: elements).filter { $0.depth == element.depth }
            let inside = siblings.filter { ScrollGeometry.intersection($0.frame, candidate.frame) != nil }
            if inside.isEmpty { continue }
            return inside.count >= 2 ? candidate.frame : nil
        }
        return nil
    }

    /// `outer` が `inner` を**収められる大きさ**か(位置は見ない。上の doc)。
    /// 偽 = 「viewport として成立しない candidate」で、そのときだけ申告容器へ倒す
    /// **1pt の丸めは許容**(木の座標は丸められて届く。ランナーの frame 照合と同じ許容値)
    private static func canHold(_ outer: FTRect, _ inner: FTRect) -> Bool {
        let tol = 1.0
        return outer.width + tol >= inner.width && outer.height + tol >= inner.height
    }

    /// 祖先の連鎖(pre-order + depth: 手前に遡って depth が下がるたびに1段上の祖先)を辿り、
    /// `scrollable == true` を申告する**最も近い**ものを返す。サイズ 0 の申告は容器として無意味なので飛ばす
    static func nearestScrollableAncestor(of element: ElementInfo, at index: Int,
                                          in elements: [ElementInfo]) -> ElementInfo? {
        var depth = element.depth
        var cursor = index
        while cursor > 0 {
            cursor -= 1
            let candidate = elements[cursor]
            guard candidate.depth < depth else { continue }
            depth = candidate.depth
            if candidate.scrollable == true, candidate.frame.width > 0, candidate.frame.height > 0 {
                return candidate
            }
        }
        return nil
    }

    /// 要素が**容器の完全に外**に報告されているか(ghost)。`clippingContainer` と違い
    /// **交差しないことが条件**で、こちらは「掴んでしまった要素を捨てて掴み直す」判断に使う。
    /// **またぐ要素を含めてはいけない** —— 縁で救済スワイプを撃つと自傷する(grabbedGhost の記録)
    ///
    /// public なのは fleetest-mcp の RefGuard が同じ判定を使うため(ref を撃つ直前の照合)。
    /// **判定はここ1箇所** —— MCP 側に別の閾値を置くと、DSL と MCP で「ghost の定義」が割れる
    ///
    /// **容器の外側の帯に固定された chrome は ghost から除く**(2026-08-31・and-sutec_home):
    /// Android ブリッジが無ラベルの NavigationBar を間引く(`SnapshotBuilder.shouldInclude`)と、
    /// preorder+depth の復元がタブを容器(`#screen_home`)の子に再配線し、非交差になる。
    /// `isChromePinnedOutside` の doc を参照
    public static func isOutsideContainer(_ element: ElementInfo, in elements: [ElementInfo],
                                          screen: FTRect) -> Bool {
        guard let container = clippingContainer(of: element, in: elements) else { return false }
        guard ScrollGeometry.intersection(element.frame, container) == nil else { return false }
        let containerIsViewport = TapTargetGeometry.ancestors(of: element, in: elements)
            .contains { $0.scrollable == true && sameFrame($0.frame, container) }
        return !isChromePinnedOutside(element, container: container,
                                      containerIsViewport: containerIsViewport,
                                      in: elements, screen: screen)
    }

    /// 容器の外側の帯に固定された chrome(下部タブ・上部バー)か。ghost(スクロールで容器の外へ
    /// 押し出された行)と区別する。判定は自分自身、または**自分を含む祖先**(タブのラベルのように
    /// chrome の中に居る要素)のどれかが帯の一員であること。
    ///
    /// 実測(2026-08-31・and-sutec_home): Compose Scaffold の NavigationBar が無ラベルで
    /// 間引かれ(`SnapshotBuilder.shouldInclude`)、preorder+depth の復元がタブを
    /// `#screen_home`(scrollView・d9)の子(d10)に再配線する。タブは容器と交差せず、
    /// `isOutsideContainer` / `outsideDeclaredScroller` の両方が ghost/scrolledOut と判定していた。
    ///
    /// 呼び出し側は**非交差(1)を確認済み**という前提。ここで見るのは (5) 容器が本物の viewport
    /// (scrollable 申告、または画面の `TapTargetGeometry.fullScreenContainerAreaRatio` 以上)——
    /// 小さな推測容器を viewport 扱いすると、本物の ghost(`and-browser_weather_weekly` の
    /// 「洗濯指数10」= 517x97 の偶発的な祖先)まで免除してしまう。残りは `chromeBarMember`。
    /// **祖先以外の要素を host にしない** —— 幾何的に含むだけの無関係なパネルで免除されないため
    static func isChromePinnedOutside(_ element: ElementInfo, container: FTRect,
                                      containerIsViewport: Bool, in elements: [ElementInfo],
                                      screen: FTRect) -> Bool {
        let screenArea = screen.width * screen.height
        let containerArea = container.width * container.height
        guard containerIsViewport
            || (screenArea > 0
                && containerArea >= screenArea * TapTargetGeometry.fullScreenContainerAreaRatio)
        else { return false }
        let f = element.frame
        let hosts = TapTargetGeometry.ancestors(of: element, in: elements).filter {
            TapTargetGeometry.contains($0.frame, f)
                && ScrollGeometry.intersection($0.frame, container) == nil
        }
        return ([element] + hosts).contains {
            chromeBarMember($0, container: container, in: elements, screen: screen)
        }
    }

    /// 要素自身が「容器の外側に固定された帯」の一員か。全部そろって初めて chrome:
    ///  (2) 進行軸の**外側の帯**(容器の下端/上端に接する側)に居る
    ///  (3) 画面に**完全に収まる**(はみ出す ghost は「今そこに無い」ので対象外のまま)
    ///  (4) その画面端に**固定**されている: 残りの隙間が自分の高さ以下。上帯だけは
    ///      `chromeTopBandGapFactor` 倍まで許す(status bar のぶん下がって始まる)。
    ///      スケールに依らない相対条件 —— pt 固定値の `bottomUncoveredBand` は使わない
    ///      (px の木で黙って誤る)
    ///  (6) **バーの形**: 同じ depth・同じ y/height(±1)・水平に重ならない兄弟が、容器の外・
    ///      画面内にもう1件いる
    ///  (7) **行ではない**: 容器の内側に同じ depth・同じ高さ(±1)の要素が無い —— スクロールで
    ///      容器の外へ出た行(2列グリッドの最終行など)は内側の兄弟と同じ高さで並ぶが、
    ///      chrome は内側の何とも高さが揃わない
    ///
    /// **残差**(意図して塞がない): 単独の固定 chrome(FAB・1タブだけのバー)は(6)で弾かれず
    /// 保守的に ghost 側へ残る。`hasClampedCoordinates`・`stackedRefs`・`isOriginClamped`
    /// (クランプ系)とは無関係 —— `.stacked` が優先されるチェーンの順序は変えない
    private static func chromeBarMember(_ element: ElementInfo, container: FTRect,
                                        in elements: [ElementInfo], screen: FTRect) -> Bool {
        let tol = chromePinnedEdgeTolerance
        let f = element.frame
        let bottomBand = f.y >= container.y + container.height - tol
        let topBand = f.y + f.height <= container.y + tol
        guard bottomBand || topBand else { return false }
        guard TapTargetGeometry.contains(screen, f) else { return false }
        let gap = bottomBand
            ? (screen.y + screen.height) - (f.y + f.height)
            : f.y - screen.y
        let allowance = bottomBand ? f.height : f.height * chromeTopBandGapFactor
        guard gap >= -tol, gap <= allowance else { return false }
        let sameHeightInside = elements.contains { other in
            other.ref != element.ref && other.depth == element.depth
                && abs(other.frame.height - f.height) <= tol
                && ScrollGeometry.intersection(other.frame, container) != nil
        }
        guard !sameHeightInside else { return false }
        return elements.contains { other in
            other.ref != element.ref && other.depth == element.depth
                && abs(other.frame.y - f.y) <= tol && abs(other.frame.height - f.height) <= tol
                && (other.frame.x + other.frame.width <= f.x + tol
                    || other.frame.x >= f.x + f.width - tol)
                && ScrollGeometry.intersection(other.frame, container) == nil
                && TapTargetGeometry.contains(screen, other.frame)
        }
    }

    /// chrome 判定の縁の丸め許容(pt/px)。`sameFrame`/`TapTargetGeometry.contains` と同じ
    /// オーダーの丸め差(1pt)を許す。根拠を持たない緩め値ではなく、**既存の許容と揃えた**もの
    static let chromePinnedEdgeTolerance: Double = 1

    /// 上帯(容器の上端側)の固定判定で許す隙間の倍率。iOS の safe-area 上端(status bar・
    /// Dynamic Island)は最大 59pt で nav bar は 44pt 以上 = 隙間/高さ ≈ 1.3、Android は
    /// status bar < app bar なので 1 未満。2 なら両方を含み、それより下がった要素は chrome ではない
    static let chromeTopBandGapFactor: Double = 2

    /// 端まで送っても見つからなかったときの**拾い直し**。探索方向を反転し、
    /// **容器基準の細刻み**(容器の約半分)で戻りながら毎周解決を試す。
    ///
    /// **なぜ失敗が確定してからだけ掛けるか**: 既定経路(`scrollFrame` 未指定)は刻みが
    /// エンジン任せで、1回の移動が容器を超えると要素がスワイプの合間に一度も木へ出ない。
    /// 通常の送りを容器基準に変える案は**2度実装して2度撤回**している(到達距離が縮んで
    /// 既定 maxSwipes で届かなくなる。docs/performance-tuning.md §3.19)。ここは
    /// **もう届かないと確定した後**なので、その撤回理由に触れない。
    /// 容器は推測なので `containerInference` で切れる(呼び出し側で判定済み)
    func reverseSweep(step: FlowStep, container: FTRect,
                              searching finger: FTSwipeDirection,
                              phase: inout PhaseAccumulator) async throws -> FlowLocator?? {
        let back: FTSwipeDirection = switch finger {
        case .up: .down
        case .down: .up
        case .left: .right
        case .right: .left
        }
        // **スワイプではなくドラッグで戻す**。スワイプはフリングになり、この局面(端に着いている =
        // 残りの可動域が短い)では1回で反対の端まで走り切って、また同じ飛び越しを起こす
        // (2026-08-06 に Emulator で観測: path 付きスワイプでは1本も拾えなかった)。
        // slowDrag は距離ぶんの時間を必ず取るのでフリング閾値を下回る
        let vertical = back == .up || back == .down
        let extent = vertical ? container.height : container.width
        // + = 進む向き(縦は指を上・横は指を左)。dragGesture の規約と対
        let jump = (back == .up || back == .left ? 1.0 : -1.0)
            * extent * Self.reverseSweepSpanRatio
        // 横は 2026-08-08 まで未対応で即 nil だった(RN の横 FlatList がフリングで
        // #tag_15 を飛び越して右端に着き、救済されず 4/10 で失敗した実測が動機)

        var previous: String?
        for _ in 0..<Self.reverseSweepMaxSwipes {
            guard await slowDrag(jump: jump, container: container, vertical: vertical,
                                 phase: &phase) else { return nil }
            let snapshot = try await freshSnapshot(.afterOwnMove)
            if let (element, fallback) = Self.resolve(step: step, in: snapshot,
                                                     strictForAssert: true) {
                // **見つけただけでは足りない**(本編の探索と同じ規則): 容器の縁で見切れている
                // 要素は frame がクランプされていてタップが外れる。まだ戻せるなら送り続ける
                // (iOS/Compose は可視域の外の行も木に残すので、ここを省くと ghost を掴む)。
                // **画面外ゲートも本編と同じ**(offscreenScrollGateCentre): isClippedByViewport は
                // 容器より大きい/ゼロサイズの要素を意図的に false にするので、縦が oversized なだけで
                // 横に完全に画面外の要素を「拾い直した」と返していた(探索本体は 81db3385 で塞いだが、
                // この逆走査には無かった = 通り過ぎた要素への exist(scroll:) が遅い成功に化ける経路)
                if !Self.isClippedByViewport(element, screen: container),
                   TapTargetGeometry.offscreenScrollGateCentre(for: element,
                                                              screen: snapshot.screen) == nil {
                    _ = try await settleAfterFind(step: step, element: element,
                                                  snapshot: snapshot, phase: &phase)
                    // **連続2回一致まで待つ**(settleAfterScroll より強い)。逆走査のドラッグは
                    // 遅い代わりに離した後もしばらく減速しながら動き、**掴んだ座標が
                    // タップまでにずれる**(2026-08-06 実測: 176px ずれて隣の行を叩いた)
                    _ = try await settledSignature(phase: &phase)
                    return .some(fallback)
                }
            }
            // 反対の端まで戻った(もう動かない)なら、この画面には無い
            let signature = Self.contentSignature(snapshot.elements)
            if signature == previous { return nil }
            previous = signature
        }
        return nil
    }

    /// 探索が要素を見つけた直後の後始末。**スワイプを撃った周回だけ**呼ぶ。戻り値は
    /// 「静止待ちが収束せず打ち切られた」= 呼び手はそれを注記に載せる。
    /// **順序に意味がある**(逆にすると Android で誤タップが再発する。2026-07-27 実測)
    func settleAfterFind(step: FlowStep, element: ElementInfo,
                                 snapshot: SnapshotResponse,
                                 phase: inout PhaseAccumulator) async throws -> Bool {
        // 順序に意味がある(逆にすると Android で誤タップが再発する。2026-07-27 実測):
        //  1. **空打ちの極小ドラッグ**: iOS(Compose)のスクロール容器は次の1タッチを
        //     消費してしまい、タップもプレスも効かない(待っても解けない。2回目は効く)。
        //     **横へ抜けるドラッグ**でその1回ぶんを肩代わりする。向きの根拠は
        //     `emptyDragEndX` に書いてある(縦に抜くと容器がスクロールとして消費し、
        //     直後のアサーションが壊れる / 矩形の中で離すとクリックとして成立してしまう)
        //  2. **静止待ち**: 空打ちでリストが微動するので、止まってから返す
        //  **uikit はスキップ**(容器がタッチを消費しない。RN は横抜き4ptが pressRetentionOffset
        //  20pt 内でクリック成立し scrollTo が行を選択した。2026-08-08 S0100 実測。shouldEmptyDrag 参照)
        // **触る点が他の要素に取られるなら打たない**。空打ちは手前の要素
        // (タブバー等)に届き、そのボタンが反応してしまう
        // (2026-07-27 実測: E2E-iOS の #txt_offscreen はタブバーの帯の中に出るため、
        // 空打ちでホームタブへ切り替わっていた)
        // **点は容器の中でありさえすればよい**(容器の1タッチを肩代わりするだけで、
        // 対象要素に当てる必要は無い)。そこで下端の a11y 空白帯に掛かるときは
        // 上へずらす —— 探索は「見えた瞬間」に止まるので、**1回の移動量が小さいほど
        // 対象は下端で見つかり**、ずらさないと空打ちが常に抑止される
        // (2026-08-02 実測: CMP で scrollFrame 指定時に #row_40 が y=829 で見つかり、
        // 空打ちが飛ばされてタップが容器に吸われた。従来の全画面スワイプでは y=720)
        let x: Double = element.frame.x + element.frame.width / 2
        let y: Double = min(element.frame.y + element.frame.height / 2,
                            snapshot.screen.y + snapshot.screen.height
                                - Self.bottomUncoveredBand - 1)
        if shouldEmptyDrag,
           Self.emptyDragIsSafe(x: x, y: y, of: element,
                                in: snapshot.elements, screen: snapshot.screen),
           let toX = Self.emptyDragEndX(of: element, from: x, screen: snapshot.screen) {
            await emptyDrag(x: x, y: y, toX: toX)
        }
        return try await !settleAfterScroll(step: step, found: element, phase: &phase)
    }

    /// 掴んだ要素を可視域へ入れ直すために**次に送る向き**。
    ///
    /// **探索方向へ送り続けてはいけない** —— 行き過ぎた側の要素は**さらに遠ざかる**。
    /// 2026-08-05 実測: `withScrollDown` の探索(指は上)で `#row_30` が容器(230..692)の**上**
    /// y=76 に報告され、ghost 検出後の追加スワイプ2回でも外のままだった
    /// (注記が `3 re-resolve(s), 2 extra swipe(s)` で残っていた = 検出はできていて救済が収束しない)。
    ///
    /// **`direction` は指の向き**(ブリッジへ渡る語彙)なので、内容を下へ戻すには指を下へ動かす。
    /// 中心が容器の内側にある間は探索方向のまま = 「まだ届いていない」ときの挙動は変わらない
    /// 見切れ回収に必要な移動量(符号は dragGesture の規約: + = 指を上/左)。
    /// 見切れていなければ nil。**全幅フリングで戻すと既定経路(scrollFrame 無し)では
    /// 逆側へ飛び越して往復振動になり maxSwipes を使い切る**(2026-08-08 実測:
    /// RN 横カルーセルで "after 10 scroll(s)")。量が分かっている局面なので距離で寄せる
    static func clipRecoveryJump(for element: ElementInfo, viewport: FTRect,
                                 finger back: FTSwipeDirection) -> Double? {
        let f = element.frame
        let pad = 24.0   // 縁ぴったりで止めない(クランプ座標の既知の罠を避ける)
        let magnitude: Double
        switch back {
        case .up:    magnitude = (f.y + f.height) - (viewport.y + viewport.height)
        case .down:  magnitude = viewport.y - f.y
        case .left:  magnitude = (f.x + f.width) - (viewport.x + viewport.width)
        case .right: magnitude = viewport.x - f.x
        }
        guard magnitude > 0 else { return nil }
        let signed = (back == .up || back == .left) ? 1.0 : -1.0
        return signed * (magnitude + pad)
    }

    static func recoveryDirection(for element: ElementInfo, container: FTRect,
                                  searching finger: FTSwipeDirection) -> FTSwipeDirection {
        let frame = element.frame
        switch finger {
        case .up, .down:
            if frame.centerY < container.y { return .down }
            if frame.centerY > container.y + container.height { return .up }
        case .left, .right:
            if frame.centerX < container.x { return .right }
            if frame.centerX > container.x + container.width { return .left }
        }
        return finger
    }


    /// 要素が画面の縁で**見切れている**か。ビューポートより大きい要素(長文など)は
    /// どう送っても収まらないので false(送り続けて maxSwipes を使い切らせない)
    static func isClippedByViewport(_ element: ElementInfo, screen: FTRect) -> Bool {
        let frame = element.frame
        // **等しいときは「大きい」ではない**: リストの行は容器と同じ幅を持つのが普通で、
        // `<` にすると幅一致の行が丸ごと判定から漏れる(2026-08-02 実測: 下端で見切れた行が
        // 可視とみなされ、タップが容器の外のタブバーに当たって別画面へ遷移した)
        guard frame.height > 0, frame.width > 0,
              frame.height <= screen.height, frame.width <= screen.width else { return false }
        return frame.y < screen.y
            || frame.y + frame.height > screen.y + screen.height
            || frame.x < screen.x
            || frame.x + frame.width > screen.x + screen.width
    }

    /// **報告された座標が壊れている要素**か(= 同じ場所に同じ深さの兄弟が積み上がっている)。
    ///
    /// フレームワークは**容器の可視域を外れた子孫の frame の原点を、容器の原点へクランプする**。
    /// XCUITest の `UITableView` では**実体化していない行のラベルまでツリーに載り**、
    /// 全部が容器の原点に積み上がる(2026-08-05 実採取: 40 行のうち **32 個**が
    /// `(16,270 330x56)` に重なり、**すべて depth 8**)。これを掴むと:
    ///   - `tap("行 15")` が**先頭行をタップする**(実採取で再現。可視性ガードを通らないので沈黙)
    ///   - `exist("行 15")` が画面外なのに真を返す(「exist は非スクロール」の契約に反する)
    ///
    /// **判定に depth の一致が要る**(2026-08-05 に過去レポート 466 件へ当てて確認): frame だけで
    /// 判定すると `homepage_container > main_content > list_container > recycler_view` のような
    /// **入れ子の連鎖**(親子が同じ矩形を持つのは普通)を巻き込む。祖先と子孫は depth が違うので、
    /// 「同じ depth = 兄弟」を条件にすれば連鎖は残る。
    ///
    /// **「同じ場所に3つ」だけでは足りない**(2026-08-05: 症状で判定したら既存テスト 13 件が落ちた)。
    /// 同 depth の兄弟が同じ矩形を持つこと自体は珍しくない —— 重ねたオーバーレイや、
    /// 属性だけが違う要素群がそうなる。**機構そのもの**を条件にする:
    ///   「容器の**原点にちょうど固定**され、かつ容器より**小さい**要素が3つ以上重なっている」
    /// 実採取と一致する(容器 `#list_rows` (16,270.33 370x395.33) / 群 (16,270.33 **330x56**))。
    /// 全面に重ねた正当なオーバーレイは**容器と同じ大きさ**になるので、この条件では残る。
    ///
    /// 閾値3は `OcclusionSuspicion.isClampGhost` と同じ(親子2重で誤爆させない)。
    /// **あちらとは用途も条件も違う**ので統合しないこと —— あちらは「画面端に接する」ものを
    /// occluder の判定から外す話(FM を余計に呼ばないため)で、こちらは解決候補から外す話
    static func hasClampedCoordinates(_ element: ElementInfo, in elements: [ElementInfo],
                                      inferring enabled: Bool = containerInferenceEnabled) -> Bool {
        guard enabled else { return false }
        let frame = element.frame
        var count = 0
        for other in elements
        where other.depth == element.depth && Self.sameFrame(other.frame, frame) {
            count += 1
            if count >= Self.clampedStackThreshold { break }
        }
        guard count >= Self.clampedStackThreshold else { return false }
        // クランプ先(= 原点を貸している祖先候補)が居るか。**同じ大きさなら別物**
        return elements.contains { container in
            container.depth < element.depth
                && abs(container.frame.x - frame.x) <= 0.5
                && abs(container.frame.y - frame.y) <= 0.5
                && container.frame.width >= frame.width && container.frame.height >= frame.height
                && (container.frame.width > frame.width + 0.5
                    || container.frame.height > frame.height + 0.5)
        }
    }

    /// 同じ場所に積み上がっているとみなす数(自分を含む)
    static let clampedStackThreshold = 3

    /// frame の同一判定。**丸めではなく許容差**で見る(実採取の値は 270.3333… のような
    /// 分数座標で、同じ木の中では同値だが、丸めると隣接する別要素と衝突し得る)
    static func sameFrame(_ a: FTRect, _ b: FTRect, tolerance: Double = 0.5) -> Bool {
        abs(a.x - b.x) <= tolerance && abs(a.y - b.y) <= tolerance
            && abs(a.width - b.width) <= tolerance && abs(a.height - b.height) <= tolerance
    }

    /// その座標のタッチが**対象ではなく手前の別要素に渡る**か。スナップショットは pre-order
    /// (後 = 手前寄り)なので、対象より後ろにあって点を含む要素が居れば取られ得る。
    /// 対象の子孫は同じ見た目の一部なので除く。空打ちドラッグの安全判定に使う
    static func pointIsTakenByFrontElement(x: Double, y: Double, of element: ElementInfo,
                                           in elements: [ElementInfo]) -> Bool {
        frontElementTakingPoint(x: x, y: y, of: element, in: elements) != nil
    }

    /// 同上で、**取っている要素そのもの**を返す(失敗診断に名前を出すため)。
    /// 判定規則は pointIsTakenByFrontElement と1つの実装を共有する(片方だけ変わらないように)
    static func frontElementTakingPoint(x: Double, y: Double, of element: ElementInfo,
                                        in elements: [ElementInfo]) -> ElementInfo? {
        guard let index = elements.firstIndex(where: { $0.ref == element.ref }) else { return nil }
        let ownRefs = Set(descendants(of: element, in: elements).map(\.ref))
        return elements[elements.index(after: index)...].first { other in
            guard !ownRefs.contains(other.ref) else { return false }
            let f = other.frame
            return x >= f.x && x <= f.x + f.width && y >= f.y && y <= f.y + f.height
        }
    }

    /// 整定ポーリングの**周期を一定に保つ**待ち時間。判定したいのは
    /// 「約 `scrollSettleIntervalMs` の周期で画面が変わらないこと」であって sleep の長さではない。
    /// キャッシュ迂回の snapshot は Android で約 +35ms 掛かる(ブリッジ直叩きで 5.1ms → 39.9ms)ので、
    /// 差し引かないと周期が 100ms → 140ms へ伸び、**スクロール系のステップが丸ごと遅くなる**
    /// (2026-08-03 実測: scroll 系ステップ合計 +3.2s。差し引きで -2.0s 回収)。
    /// **迂回しないエンジン(iOS)では引かない** —— あちらは snapshot 自体が重く(xcuitest は
    /// 数百 ms)、引くと周期が大きく縮んで「早すぎる静止判定」に倒れる
    static func settleSleepMs(afterSnapshotMs: Int, bypassing: Bool) -> Int {
        guard bypassing else { return Self.scrollSettleIntervalMs }
        return max(Self.scrollSettleMinSleepMs, Self.scrollSettleIntervalMs - afterSnapshotMs)
    }

    /// 整定ポーリングの待ちの下限(busy loop 防止)
    static let scrollSettleMinSleepMs = 30

    /// スクロール静止待ちの**基本予算**(回数 × 間隔 = 600ms)。多くのフリングはこの範囲で収まる。
    /// ここを超えても、**まだ減速しているうちは** scrollSettleMaxDeceleratingPolls まで待つ
    static let scrollSettleMaxPolls = 6
    /// 減速が続いている場合の周回上限(= 最大 2.4s)。**当たるのは異常**で、当たれば
    /// `settle-capped` が注記に出る —— 出たら「2.4 秒経っても減速し続ける画面」の実測を
    /// 取ってから見直すこと(数字を増やす前に、何が動き続けているのかを見る)。
    /// 基本予算の4倍にしてあるのは、600ms で打ち切られていた実測(全緑の run で 34 回・
    /// うち横カルーセルは 0.25 秒の肩代わりが消えると赤)に対して十分な余裕を取るため
    static let scrollSettleMaxDeceleratingPolls = 24
    static let scrollSettleIntervalMs = 100
    /// screenLooksLike が不一致だったときに撮り直すまでの待ち(ms)。**遷移の描き終わりを待つだけ**なので
    /// スクロールの整定待ち(6×100ms)と同じオーダーに置く。長くすると失敗の確定が遅れる
    static let screenMatchRetryDelayMs = 600

    /// 画面が静止するまで待ち、そのときの要素配置の署名を返す(scrollToEdge の到達判定)。
    /// **横スクロールでは y が動かない**ので x と y の両方を入れる。
    /// ref は取り直しで振り直されるため使わない(型と座標だけで比較する)。
    /// 静止時点のスナップショットも返す(scrollToEdge のヒント跳躍が再利用する。
    /// 別途撮り直すと iOS xcuitest では1周 約380ms の追加になるため)
    ///
    /// **label を署名に入れてはいけない**(2026-07-31 実測。入れると SwiftUI List で永久に
    /// 収束しない): 画面外まで含む行のうち 2 件が、静止画面でも取得のたびに別の行のラベルを
    /// 名乗り、A↔B で交互に振れ続ける(XCUITest が再利用セル群の古いラベルを読むため。
    /// frame は 1pt も動かない)。結果 settledSignature は毎回 6 poll を使い切り、
    /// scrollToEdge の「連続2回不変=端」も成立せず maxSwipes 上限まで回っていた
    /// (E2E-iOS/ios-xcuitest の scrollToTop で 44〜55s。同じ画面が in-app では 1.5s)。
    /// **判定したいのは「動いているか」なので frame だけで足りる**
    /// (settleAfterScroll も同じ理由で frame だけを見ている)。
    /// 逆に**ランナー側の captureSettled では label を外さない** — あちらは tap 直後の
    /// 「内容が更新されたか」を待つので、レイアウトが変わらずテキストだけ変わる更新を
    /// 取りこぼすと stale なツリーを返す
    /// 戻り値の `settled` は false = **ポーリング上限で打ち切った**(静止を確認できていない)。
    /// 呼び出し側は note にして可視化する。黙って返すと「毎回上限を使い切っているのに緑」が
    /// 続き、実際そうなっていた(ラベル振れによる非収束。2026-07-31 修正)
    func settledSignature(
        phase: inout PhaseAccumulator) async throws
        -> (signature: String, snapshot: SnapshotResponse, settled: Bool) {
        func signature(_ snapshot: SnapshotResponse) -> String {
            snapshot.elements
                .map { "\($0.type)|\($0.frame.x),\($0.frame.y)" }
                .joined(separator: ",")
        }
        // **全周キャッシュを捨てて撮る**(Android のみ実費。iOS は素通し)。素取得だと
        // 遅れて公開された古いツリーが2回続けて同じ署名を返し、**動いている最中に
        // 「静止した」が成立する** —— しかも返す `last` が古い木なので、呼び出し側は
        // そのまま古い座標で解決する(settleAfterScroll と同じ理由。掃討 2026-08-03)。
        // 落ち着いた画面なら 2 枚で返るので固定費は約 +130ms/呼び出しに収まる
        let clock = ContinuousClock()
        var start = clock.now
        var last = try await freshSnapshot(.afterOwnMove)
        var previous = signature(last)
        var previousElements = last.elements
        var lastSnapshotMs = Self.ms(clock.now - start)
        phase.snapshotMs += lastSnapshotMs
        // 変位の履歴(古い順)。**縮んでいる間は待つ**ので、周回上限は日常的には当たらない
        var motion: [Double?] = []
        for poll in 0..<Self.scrollSettleMaxDeceleratingPolls {
            let waitStart = clock.now
            try await Task.sleep(for: .milliseconds(
                Self.settleSleepMs(afterSnapshotMs: lastSnapshotMs,
                                   bypassing: bypassesCache(.afterOwnMove))))
            phase.waitMs += Self.ms(clock.now - waitStart)
            start = clock.now
            last = try await freshSnapshot(.afterOwnMove)
            let current = signature(last)
            lastSnapshotMs = Self.ms(clock.now - start)
            phase.snapshotMs += lastSnapshotMs
            if current == previous { return (current, last, true) }
            motion.append(SettleMotion.displacement(from: previousElements, to: last.elements))
            previous = current
            previousElements = last.elements
            // 従来の予算(6周)を超えて回すのは**まだ減速しているとき**だけ。
            // 横ばい・増加は等速のアニメーションで、待っても止まらない
            if poll + 1 >= Self.scrollSettleMaxPolls, !SettleMotion.isDecelerating(motion) { break }
        }
        return (previous, last, false)
    }


    /// 空打ちの所要。速いとフリングになり、遅いと長押しになる
    static let emptyDragSeconds: Double = 0.30

    /// 空打ちドラッグの終点。**対象の矩形の外へ横に抜ける**のが要件。
    /// Compose iOS は「離した点が要素の中」ならクリックとして成立させるので、中に留まる限り
    /// **距離では消せない**(2026-08-03 実測: 2pt / 24pt / 120pt、0.05s / 0.30s のどれでも
    /// `scrollTo("#row_40")` だけで `selected=row_40` が入った = 読み取り専用のはずの
    /// コマンドがアプリの状態を書き換える)。矩形の外で離せばクリックは取り消される。
    /// **縦に抜いてはいけない**: 容器がスクロールとして消費して内容が動き、直後に
    /// 「今ここにある」を確かめる assertion が壊れる(実測: E2E-CMP/ios-inapp の S0020 が 0/3)。
    /// **止めるという選択肢も無い**: 完全に外すと肩代わりが効かず S0080 が CMP/ios で落ちる。
    /// **抜けられないときだけ nil**(= その回は撃たない)。矩形が画面幅いっぱいだと左右どちらへも
    /// 出られず、ここは以前**開始点をそのまま返していた** —— 始点と終点が同じ 0.30 秒のプレスは
    /// タップそのもので、この doc が禁じている「矩形の中で離す」を実装自身が踏んでいた。
    /// 実機(iPhone 実機・SmartNews)の全幅セルで `ft_scroll_to` が**記事を開く**形で 2/2 再現
    ///。自前 SUT の行はすべてインセット(例 16,270 330x56)なので E2E には出ない
    /// —— 全幅の行は実アプリに固有。実機は `AppBundleInspector` が必ず nil を返すので
    /// `shouldEmptyDrag` が常に true になり、全アプリが対象になる。
    /// 撃たない代償は「容器が次の1タッチを消費したまま」= 呼び手のやり直しで回復するが、
    /// 撃った場合の代償は**アプリの状態が変わって戻せない**(読み取り専用のはずの scrollTo が書き込む)
    static func emptyDragEndX(of element: ElementInfo, from x: Double, screen: FTRect) -> Double? {
        let right = element.frame.x + element.frame.width + 4
        if right <= screen.x + screen.width - 1 { return right }
        let left = element.frame.x - 4
        return left >= screen.x + 1 ? left : nil
    }

    /// スクロール探索直後の「空打ち」極小ドラッグ(呼ぶ条件は呼び出し側の判定を参照)。
    /// **in-app エンジンは drag を一切実装しない**(501)ため、hybrid では typeDriver=XCUITest へ
    /// 回さないとこの対策が丸ごと不発になる(= Compose の容器がタッチを1回吸ったままになり、
    /// 直後の tap/press が空振りする)。空打ちは補助でありこれ自体の失敗はステップの失敗にしない
    /// (両経路とも失敗したら黙って進む = 従来の `try?` と同じ扱い)
    func emptyDrag(x: Double, y: Double, toX: Double) async {
        try? await dragWithFallback(fromX: x, fromY: y, toX: toX, toY: y,
                                    pressSeconds: 0.05, durationSeconds: Self.emptyDragSeconds)
    }

    /// **座標ドラッグの唯一の入口**(空打ち・見切れ回復の slowDrag・ヒント跳躍の hintDrag)。
    /// in-app エンジンは drag を一切実装しない(501)ので、hybrid では typeDriver=XCUITest へ回す。
    /// 2026-08-23 まで slowDrag / hintDrag は `driver.drag` を直に呼んで 501 を「失敗」として
    /// 握りつぶしていた = **in-app 主の run(利用者の既定 hybrid)では見切れ回復のドラッグが
    /// 一度も出ていなかった**(受け手の最小再現 R0020: 容器推定を直しても全画面スワイプに落ちて
    /// 届かず not-found。MCP は HybridFallbackDriver が drag を転送するので同じ探索が通った)。
    /// 501 を見たら以後は latch して typeDriver から撃つ(emptyDrag と同じ規律)。
    /// typeDriver が無いエンジン非対応はそのまま投げる(呼び手が「ドラッグできない」として扱う)
    func dragWithFallback(fromX: Double, fromY: Double, toX: Double, toY: Double,
                          pressSeconds: Double, durationSeconds: Double) async throws {
        func drag(_ target: AppDriver) async throws {
            try await target.drag(fromX: fromX, fromY: fromY, toX: toX, toY: toY,
                                  pressSeconds: pressSeconds, durationSeconds: durationSeconds)
        }
        if dragFallbackLatched, let td = typeDriver {
            try await drag(td)
            return
        }
        do {
            try await drag(driver)
        } catch {
            guard DriverError.isEngineIncapable(error), let td = typeDriver else { throw error }
            dragFallbackLatched = true
            try await drag(td)
        }
    }

    /// intent: swipe の用途(`FTSwipeIntent`)。in-app の Compose/Flutter は
    /// gesture かどうかだけを見る(混ぜるとジェスチャ画面が黙って空振りする)。
    /// Android ブリッジは edge のときだけ強いフリングを使う(`SwipeRequest.fling`)
    func swipeWithFallback(_ direction: FTSwipeDirection,
                                   intent: FTSwipeIntent = .gesture,
                                   path: FTSwipePath? = nil,
                                   phase: inout PhaseAccumulator) async throws -> Bool {
        let clock = ContinuousClock()
        if typeDriverGestures.contains("swipe") || gestureFallbackLatched, let td = typeDriver {
            let start = clock.now
            try await td.swipe(direction, intent: intent, path: path)
            phase.actionMs += Self.ms(clock.now - start)
            return true
        }
        do {
            let start = clock.now
            try await driver.swipe(direction, intent: intent, path: path)
            phase.actionMs += Self.ms(clock.now - start)
            return false
        } catch {
            // 「このエンジンでは不可」(501 / ルート不明 404)だけ XCUITest へ回す。
            // 409 を含めない理由は DriverError.isEngineIncapable 参照。
            // **座標つきは in-app が必ず 501 を返す**(合成タッチの drag を受理しないため)ので、
            // scrollFrame 指定時の hybrid はここで XCUITest へ落ちる
            guard DriverError.isEngineIncapable(error), let td = typeDriver else { throw error }
            let start = clock.now
            try await td.swipe(direction, intent: intent, path: path)
            phase.actionMs += Self.ms(clock.now - start)
            gestureFallbackLatched = true
            return true
        }
    }
}
