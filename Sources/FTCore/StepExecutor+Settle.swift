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
            guard let (element, _) = LocatorResolver.resolve(step: step, in: snapshot,
                                                  strictForAssert: true) else { return false }
            if element.frame == previous { return true }
            motion.append(max(abs(element.frame.x - previous.x), abs(element.frame.y - previous.y)))
            previous = element.frame
            if poll + 1 >= Self.scrollSettleMaxPolls, !SettleMotion.isDecelerating(motion) { break }
        }
        return false
    }

    /// `launchApp(url:)` が URL を配送する前に、最初の画面が描かれる(利用者が触れる要素が木に載る)
    /// まで待つ(規則は LaunchURLReadiness)。戻り値 false = `timeoutMs` 内に載らなかった(呼び手は
    /// 配送はしたうえで注記 `launch-url-before-interactive-ui` を残す —— 触れる要素の無い最初の画面も
    /// 正当にあり得るので失敗にはしない)。周期は整定ポーリングと同じ規則(settleSleepMs)
    public func awaitInteractiveUI(timeoutMs: Int) async throws -> Bool {
        let clock = ContinuousClock()
        let deadline = clock.now + .milliseconds(timeoutMs)
        var lastSnapshotMs = 0
        while true {
            let start = clock.now
            let bypass = bypassesCache(.afterOwnMove)
            if bypass { markRepollBypassed() }
            let snapshot = try await driver.snapshot(bypassingCache: bypass)
            lastSnapshotMs = Self.ms(clock.now - start)
            if LaunchURLReadiness.hasInteractiveElement(snapshot.elements) { return true }
            if clock.now >= deadline { return false }
            try await Task.sleep(for: .milliseconds(
                Self.settleSleepMs(afterSnapshotMs: lastSnapshotMs, bypassing: bypassesCache(.afterOwnMove))))
        }
    }

    /// スクロール探索終端の空打ちドラッグを (x,y) に打ってよいか。打たない条件は2つ
    /// (どちらも「空打ちが別の UI に渡って画面が変わる」実害の再発防止):
    /// 1. 対象より手前の要素が点を取る(タブバー等。pointIsTakenByFrontElement)
    /// 2. 点が**画面下端の帯**にある。タブバーの実ヒット域は a11y frame の下(ホームインジケータ域
    ///    =画面下端)まで伸びるのに、その帯は a11y 上は空白で 1 が効かない
    ///    (実測: タブ frame 下端 840・画面高 874 で、帯内 y=841.8 への空打ちで
    ///    #tab_home が反応しホームへ遷移。E2E-iOS 07/16 の間欠フレークの根因)
    static func emptyDragIsSafe(x: Double, y: Double, of element: ElementInfo,
                                in elements: [ElementInfo], screen: FTRect) -> Bool {
        if pointIsTakenByFrontElement(x: x, y: y, of: element, in: elements) { return false }
        if y >= screen.y + screen.height - Self.bottomUncoveredBand { return false }
        return true
    }

    /// 画面下端の a11y 空白帯の高さ(pt)。実測の空白(874-840=34)+整定位置のブレの余裕
    static let bottomUncoveredBand: Double = 48

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
        // (Emulator で観測: path 付きスワイプでは1本も拾えなかった)。
        // slowDrag は距離ぶんの時間を必ず取るのでフリング閾値を下回る
        let vertical = back == .up || back == .down
        let extent = vertical ? container.height : container.width
        // + = 進む向き(縦は指を上・横は指を左)。dragGesture の規約と対
        let jump = (back == .up || back == .left ? 1.0 : -1.0)
            * extent * Self.reverseSweepSpanRatio
        // 横方向も同じ経路を通す —— RN の横 FlatList がフリングで #tag_15 を飛び越して右端に着き、
        // 救済されず 4/10 で失敗した実測が動機

        var previous: String?
        for _ in 0..<Self.reverseSweepMaxSwipes {
            guard await slowDrag(jump: jump, container: container, vertical: vertical,
                                 phase: &phase) else { return nil }
            let snapshot = try await freshSnapshot(.afterOwnMove)
            if let (element, fallback) = LocatorResolver.resolve(step: step, in: snapshot,
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
                    // タップまでにずれる**(実測: 176px ずれて隣の行を叩いた)
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
    /// **順序に意味がある**(逆にすると Android で誤タップが再発する。実測)
    func settleAfterFind(step: FlowStep, element: ElementInfo,
                                 snapshot: SnapshotResponse,
                                 phase: inout PhaseAccumulator) async throws -> Bool {
        // 順序:
        //  1. **空打ちの極小ドラッグ**: iOS(Compose)のスクロール容器は次の1タッチを
        //     消費してしまい、タップもプレスも効かない(待っても解けない。2回目は効く)。
        //     **横へ抜けるドラッグ**でその1回ぶんを肩代わりする。向きの根拠は
        //     `emptyDragEndX` に書いてある(縦に抜くと容器がスクロールとして消費し、
        //     直後のアサーションが壊れる / 矩形の中で離すとクリックとして成立してしまう)
        //  2. **静止待ち**: 空打ちでリストが微動するので、止まってから返す
        //  **uikit はスキップ**(容器がタッチを消費しない。RN は横抜き4ptが pressRetentionOffset
        //  20pt 内でクリック成立し scrollTo が行を選択した。S0100 実測。shouldEmptyDrag 参照)
        // **触る点が他の要素に取られるなら打たない**。空打ちは手前の要素
        // (タブバー等)に届き、そのボタンが反応してしまう
        // (実測: E2E-iOS の #txt_offscreen はタブバーの帯の中に出るため、
        // 空打ちでホームタブへ切り替わっていた)
        // **点は容器の中でありさえすればよい**(容器の1タッチを肩代わりするだけで、
        // 対象要素に当てる必要は無い)。そこで下端の a11y 空白帯に掛かるときは
        // 上へずらす —— 探索は「見えた瞬間」に止まるので、**1回の移動量が小さいほど
        // 対象は下端で見つかり**、ずらさないと空打ちが常に抑止される
        // (実測: CMP で scrollFrame 指定時に #row_40 が y=829 で見つかり、
        // 空打ちが飛ばされてタップが容器に吸われた。従来の全画面スワイプでは y=720)
        let x: Double = element.frame.x + element.frame.width / 2
        let y: Double = min(element.frame.y + element.frame.height / 2,
                            snapshot.screen.y + snapshot.screen.height
                                - Self.bottomUncoveredBand - 1)
        if shouldEmptyDrag(for: element),
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
    /// 実測: `withScrollDown` の探索(指は上)で `#row_30` が容器(230..692)の**上**
    /// y=76 に報告され、ghost 検出後の追加スワイプ2回でも外のままだった
    /// (注記が `3 re-resolve(s), 2 extra swipe(s)` で残っていた = 検出はできていて救済が収束しない)。
    ///
    /// **`direction` は指の向き**(ブリッジへ渡る語彙)なので、内容を下へ戻すには指を下へ動かす。
    /// 中心が容器の内側にある間は探索方向のまま = 「まだ届いていない」ときの挙動は変わらない
    /// 見切れ回収に必要な移動量(符号は dragGesture の規約: + = 指を上/左)。
    /// 見切れていなければ nil。**全幅フリングで戻すと既定経路(scrollFrame 無し)では
    /// 逆側へ飛び越して往復振動になり maxSwipes を使い切る**(実測:
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
        // `<` にすると幅一致の行が丸ごと判定から漏れる(実測: 下端で見切れた行が
        // 可視とみなされ、タップが容器の外のタブバーに当たって別画面へ遷移した)
        guard frame.height > 0, frame.width > 0,
              frame.height <= screen.height, frame.width <= screen.width else { return false }
        return frame.y < screen.y
            || frame.y + frame.height > screen.y + screen.height
            || frame.x < screen.x
            || frame.x + frame.width > screen.x + screen.width
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
        let ownRefs = Set(LocatorResolver.descendants(of: element, in: elements).map(\.ref))
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
    /// (実測: scroll 系ステップ合計 +3.2s。差し引きで -2.0s 回収)。
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

    /// **端の判定(scrollToEdge の「続けて不変」)に使う署名 = 描かれていない残骸を除いた木**。
    /// XCUITest の木は、容器の外へ出た行のラベルを容器の縁へ寄せて積み(`OcclusionGeometry.stackedRefs`)、
    /// 容器の外の行も frame ごと残す(`TapTargetGeometry.outsideDeclaredScroller`)。その顔ぶれが撮るたびに
    /// 1つずつ揺れ、しかも整定の判定の後から遅れて出入りする(実測: E2E-iOS の一覧の先頭に止まったまま
    /// 63 ↔ 64 要素)ので、素の署名では端に着いても「不変」が成立せず上限まで払い切っていた
    /// (E2E-iOS の scrollToTop が 17 回中 9 回・1 回約 32 秒)。**整定の判定(`settledSignature`)には
    /// 使わない** —— あちらは「動いている最中か」を見るので、残骸の動きも動きとして数えてよい。
    ///
    /// **id とラベルも入れる**: 型と座標だけだと、同じレイアウトの面が同じ位置へスナップする容器
    /// (HorizontalPager・カルーセル)では送っても署名が変わらず、途中で端と誤認して緑のまま止まる
    /// (実測: E2EX-CMP のページャで page=4 → 2)。value は入れない(スライダー等が送りと無関係に動く)。
    /// **id とラベルを比べるのは `contentRegion`(送っている容器)の中の要素だけ**: 容器の外の表示
    /// (引っ張って更新の回数など)は送りの副作用で変わるので、入れると端でも「動いた」に見えて上限まで
    /// 送り続ける(実測: Flutter の RefreshIndicator で scrollToTop が refresh=25)。nil = 全要素
    static func edgeSignature(_ snapshot: SnapshotResponse, contentRegion: FTRect?) -> String {
        let stacked = OcclusionGeometry.stackedRefs(snapshot.elements)
        return snapshot.elements
            .filter { element in
                !stacked.contains(element.ref)
                    && TapTargetGeometry.outsideDeclaredScroller(
                        element, in: snapshot.elements, screen: snapshot.screen) == nil
            }
            .map { element -> String in
                let base = "\(element.type)|\(element.frame.x),\(element.frame.y)"
                if let region = contentRegion,
                   !StepExecutor.frame(region, containsX: element.frame.centerX, y: element.frame.centerY) {
                    return base
                }
                return base + "|\(element.identifier ?? "")|\(element.label ?? "")"
            }
            .joined(separator: ",")
    }

    /// 端の署名で id とラベルを比べる領域(`edgeSignature` の doc)。`scrollFrame` があればそれ、
    /// 無ければエンジンが払う画面中央を含む最小のスクロール可能な要素。どちらも無ければ nil
    func edgeContentRegion(step: FlowStep, in snapshot: SnapshotResponse) -> FTRect? {
        let finger = FTSwipeDirection(rawValue: step.direction ?? "") ?? .up
        if let container = scrollContainer(step: step, in: snapshot,
                                           vertical: finger == .up || finger == .down) {
            return container
        }
        let screen = snapshot.screen
        return snapshot.elements
            .filter { $0.scrollable == true
                && StepExecutor.frame($0.frame, containsX: screen.centerX, y: screen.centerY) }
            .min { $0.frame.width * $0.frame.height < $1.frame.width * $1.frame.height }?
            .frame
    }

    /// 画面が静止するまで待ち、そのときの要素配置の署名を返す(scrollToEdge の整定待ち。到達判定は `edgeSignature`)。
    /// **横スクロールでは y が動かない**ので x と y の両方を入れる。
    /// ref は取り直しで振り直されるため使わない(型と座標だけで比較する)。
    /// 静止時点のスナップショットも返す(scrollToEdge のヒント跳躍が再利用する。
    /// 別途撮り直すと iOS xcuitest では1周 約380ms の追加になるため)
    ///
    /// **label を署名に入れてはいけない**(実測。入れると SwiftUI List で永久に
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
    /// 続き、実際そうなっていた(ラベル振れによる非収束)
    /// `changed` = 収束するまでの間に**少なくとも1回**署名が変わったか(= 待った甲斐があったか)。
    /// 最初の2枚が既に一致していれば false。type 後のキーボード押し上げ待ちのように
    /// 「実際に救えた回だけ」を注記したい呼び出し側が使う(guard-retaken と同じ思想)
    func settledSignature(
        phase: inout PhaseAccumulator) async throws
        -> (signature: String, snapshot: SnapshotResponse, settled: Bool, changed: Bool) {
        func signature(_ snapshot: SnapshotResponse) -> String {
            snapshot.elements
                .map { "\($0.type)|\($0.frame.x),\($0.frame.y)" }
                .joined(separator: ",")
        }
        // **全周キャッシュを捨てて撮る**(Android のみ実費。iOS は素通し)。素取得だと
        // 遅れて公開された古いツリーが2回続けて同じ署名を返し、**動いている最中に
        // 「静止した」が成立する** —— しかも返す `last` が古い木なので、呼び出し側は
        // そのまま古い座標で解決する(settleAfterScroll と同じ理由)。
        // 落ち着いた画面なら 2 枚で返るので固定費は約 +130ms/呼び出しに収まる
        let clock = ContinuousClock()
        var start = clock.now
        nextResolveBypassesCache = true   // 次のロケータ操作は解決の 1 枚をキャッシュ迂回で撮る
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
            if current == previous { return (current, last, true, !motion.isEmpty) }
            motion.append(SettleMotion.displacement(from: previousElements, to: last.elements))
            previous = current
            previousElements = last.elements
            // 基本予算(6周)を超えて回すのは**まだ減速しているとき**だけ。
            // 横ばい・増加は等速のアニメーションで、待っても止まらない
            if poll + 1 >= Self.scrollSettleMaxPolls, !SettleMotion.isDecelerating(motion) { break }
        }
        return (previous, last, false, !motion.isEmpty)
    }


    /// 空打ちの所要。速いとフリングになり、遅いと長押しになる
    static let emptyDragSeconds: Double = 0.30

    /// 空打ちドラッグの終点。**対象の矩形の外へ横に抜ける**のが要件。
    /// Compose iOS は「離した点が要素の中」ならクリックとして成立させるので、中に留まる限り
    /// **距離では消せない**(実測: 2pt / 24pt / 120pt、0.05s / 0.30s のどれでも
    /// `scrollTo("#row_40")` だけで `selected=row_40` が入った = 読み取り専用のはずの
    /// コマンドがアプリの状態を書き換える)。矩形の外で離せばクリックは取り消される。
    /// **縦に抜いてはいけない**: 容器がスクロールとして消費して内容が動き、直後に
    /// 「今ここにある」を確かめる assertion が壊れる(実測: E2E-CMP/ios-inapp の S0020 が 0/3)。
    /// **止めるという選択肢も無い**: 完全に外すと肩代わりが効かず S0080 が CMP/ios で落ちる。
    /// **抜けられないときだけ nil**(= その回は撃たない)。矩形が画面幅いっぱいだと左右どちらへも
    /// 出られない —— そこで**開始点をそのまま返すと**、始点と終点が同じ 0.30 秒のプレスは
    /// タップそのもので、この doc が禁じている「矩形の中で離す」をそのまま実装してしまう。
    /// 実機(iPhone 実機・SmartNews)の全幅セルで `ft_scroll_to` が**記事を開く**形で 2/2 再現
    ///。自前 SUT の行はすべてインセット(例 16,270 330x56)なので E2E には出ない
    /// —— 全幅の行は実アプリに固有。撃つのは Compose / Flutter と判定できたときだけ
    /// (`shouldEmptyDrag`。不明なら撃たない)。
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
    /// (両経路とも失敗したら黙って進む = `try?` と同じ扱い)
    func emptyDrag(x: Double, y: Double, toX: Double) async {
        try? await dragWithFallback(fromX: x, fromY: y, toX: toX, toY: y,
                                    pressSeconds: 0.05, durationSeconds: Self.emptyDragSeconds)
    }

    /// **座標ドラッグの唯一の入口**(空打ち・見切れ回復の slowDrag・ヒント跳躍の hintDrag)。
    /// in-app エンジンは drag を一切実装しない(501)ので、hybrid では typeDriver=XCUITest へ回す。
    /// slowDrag / hintDrag が `driver.drag` を直に呼んで 501 を「失敗」として握りつぶすと、
    /// **in-app 主の run(利用者の既定 hybrid)では見切れ回復のドラッグが一度も出なくなる**
    /// (受け手の最小再現 R0020: 容器推定を直しても全画面スワイプに落ちて届かず not-found。
    /// MCP は HybridFallbackDriver が drag を転送するので同じ探索が通った)。
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
