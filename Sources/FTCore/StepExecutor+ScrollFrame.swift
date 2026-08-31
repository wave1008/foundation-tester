// StepExecutor+ScrollFrame.swift
// scrollFrame の解決とスクロール経路の合成。本体は StepExecutor.swift(instance 状態はそちらに置く)

import Foundation

extension StepExecutor {

    /// `scrollFrame` を解決するためだけの snapshot。**scroll/flick は scrollFrame の有無に
    /// 関わらず毎回呼ぶ**(未指定でも画面全体を対象に座標を作る必要があり、かつ
    /// キーボード表示中かどうかの唯一の検知手段でもある。2026-08-31 に scroll 側の
    /// 「指定時だけ」を撤廃した)。scrollToEdge はこの関数を使わない
    /// (settledSignature が毎周すでに撮っている木をそのまま使い回す)
    func snapshotForScrollFrame(phase: inout PhaseAccumulator) async throws -> SnapshotResponse {
        let clock = ContinuousClock()
        let start = clock.now
        let snapshot = try await driver.snapshot()
        phase.snapshotMs += Self.ms(clock.now - start)
        return snapshot
    }


    /// 実移動量が容器のこの割合を超えたら刻みを詰める(飛び越しの余裕を残す)
    /// **もう動かない**と判定するまでの連続周回数。1 だと遅れて描画される行を取りこぼす
    static let unmovedRoundsToStopSearch = 2

    /// 逆走査の刻み(容器に対する割合)と上限本数。**失敗が確定してからしか撃たない**ので
    /// 上限は「近くを通り過ぎた」を拾える程度でよい(遠くまで戻すと失敗が遅くなるだけ)
    static let reverseSweepSpanRatio: Double = 0.5
    static let reverseSweepMaxSwipes = 8
    /// 逆走査のドラッグ速度(px/s)。**フリングの閾値を下回る**ことが目的で、速いと慣性で走り、
    /// 遅いと1周が高くつく
    static let reverseSweepDragSpeed: Double = 120

    static let travelCeilingRatio: Double = 0.8
    /// 詰めるときの倍率(急に効かせすぎると往復が増えるので緩やかに)
    static let spanShrinkFactor: Double = 0.6
    /// 刻みの下限(これ以上小さくすると周回数が増えるだけ)
    static let minSpanScale: Double = 0.25

    /// 直前のスワイプで**実際に動いた量**。前後のスナップショットに共通する要素の frame 差の
    /// 中央値で測る(1要素だと再利用セルのラベル振れに引きずられる)。
    ///
    /// **共通要素が無いときは nil(不明)を返す**。「1画面ぶん動いた」とは限らず、画面遷移や
    /// id を持たない画面でも同じ状態になるため、行き過ぎと読むと**刻みを縮め続けて到達できなくなる**
    /// (2026-08-02 に実際に踏んだ: #txt_offscreen への scrollTo が maxSwipes を使い切って失敗)
    /// **スワイプで中身が入れ替わった領域**の推測 = スクロールした容器。
    /// 2枚の木を比べ、**後の木にだけ現れた要素**の clip 元を数えて最頻のものを採る。
    ///
    /// **スワイプ点から推測してはいけない**: 既定スワイプの始点はブリッジ側の比率
    /// (Android は画面 70%)で、ホストは知らない。中央と決め打つと、下寄せの容器で nil になる
    /// (2026-08-06 に実測)。**動いた要素から採るのも駄目** —— 飛び越したときは
    /// 2枚の木に共通の要素が1つも無い(だから「消えた/現れた」で見る)
    static func changedContentContainer(before: SnapshotResponse, after: SnapshotResponse)
        -> FTRect? {
        let known = Set(before.elements.compactMap(\.identifier).filter { !$0.isEmpty })
        var tally: [String: (rect: FTRect, count: Int)] = [:]
        for element in after.elements {
            guard let id = element.identifier, !id.isEmpty, !known.contains(id),
                  let container = clippingContainer(of: element, in: after.elements,
                                                    inferring: true)
            else { continue }
            let key = "\(container.x),\(container.y),\(container.width),\(container.height)"
            tally[key] = (container, (tally[key]?.count ?? 0) + 1)
        }
        return tally.values.max { $0.count < $1.count }?.rect
    }

    /// 中身の**入れ替わり**では採れないときの対**: 位置が動いた要素の clip 元。
    /// iOS(Compose)は可視域の外の行も木に残す(ghost)ので id 集合が変わらず、
    /// `changedContentContainer` が nil になる —— そのぶんフレームは動くのでこちらで拾える
    static func movedContentContainer(before: SnapshotResponse, after: SnapshotResponse,
                                      vertical: Bool) -> FTRect? {
        let index = Dictionary(before.elements.compactMap { element -> (String, ElementInfo)? in
            guard let id = element.identifier, !id.isEmpty else { return nil }
            return (id, element)
        }, uniquingKeysWith: { first, _ in first })
        var tally: [String: (rect: FTRect, count: Int)] = [:]
        for element in after.elements {
            guard let id = element.identifier, let old = index[id] else { continue }
            let delta = vertical ? element.frame.y - old.frame.y : element.frame.x - old.frame.x
            guard abs(delta) > 1,
                  let container = clippingContainer(of: element, in: after.elements,
                                                    inferring: true)
            else { continue }
            let key = "\(container.x),\(container.y),\(container.width),\(container.height)"
            tally[key] = (container, (tally[key]?.count ?? 0) + 1)
        }
        return tally.values.max { $0.count < $1.count }?.rect
    }

    /// 木の**形だけ**から採るスクロール容器(2枚の比較が要らない最後の手段)。
    /// **子がはみ出している clip 領域**を探す —— はみ出しはスクロールで外へ出た子の姿で、
    /// 静止した木にも残る。iOS(Compose)は id 集合も frame も変わらないことがあり、
    /// `changedContentContainer` / `movedContentContainer` がどちらも nil になる
    /// 半開きシートらしいスクロール容器が画面に居るか(`scrollFrame` 未指定のときの
    /// シート展開ヒントのゲート)。**申告された容器だけ**を見る —— 推測まで混ぜると
    /// 全画面リストの末尾到達でも鳴る。
    ///
    /// 高さの帯 15〜80% が要点: 上端はチップ行・横カルーセル(実測 5%前後)を落とし、
    /// 下端は全画面リストを落とす。実測でヒントが要った容器は
    /// `#TransitDirectionsListView`(189/874 = 22%)と `#directions_group_list`(871/2361 = 37%)
    static let sheetHeightBand = (low: 0.15, high: 0.8)

    static func partialHeightSheetExists(in snapshot: SnapshotResponse) -> Bool {
        let height = snapshot.screen.height
        guard height > 0 else { return false }
        return snapshot.elements.contains {
            $0.scrollable == true
                && $0.frame.height > height * sheetHeightBand.low
                && $0.frame.height < height * sheetHeightBand.high
        }
    }

    static func overflowingContainer(in snapshot: SnapshotResponse) -> FTRect? {
        var tally: [String: (rect: FTRect, count: Int)] = [:]
        for element in snapshot.elements {
            guard let container = clippingContainer(of: element, in: snapshot.elements,
                                                    inferring: true),
                  // 完全に外 = スクロールで押し出された子(またぎは数えない)
                  ScrollGeometry.intersection(element.frame, container) == nil
            else { continue }
            let key = "\(container.x),\(container.y),\(container.width),\(container.height)"
            tally[key] = (container, (tally[key]?.count ?? 0) + 1)
        }
        return tally.values.max { $0.count < $1.count }?.rect
    }

    static func measuredTravel(before: SnapshotResponse, after: SnapshotResponse,
                               vertical: Bool) -> Double? {
        var deltas: [Double] = []
        let index = Dictionary(before.elements.compactMap { element -> (Int, ElementInfo)? in
            guard let id = element.identifier, !id.isEmpty else { return nil }
            return (id.hashValue, element)
        }, uniquingKeysWith: { first, _ in first })
        for element in after.elements {
            guard let id = element.identifier, !id.isEmpty,
                  let previous = index[id.hashValue] else { continue }
            deltas.append(vertical ? previous.frame.y - element.frame.y
                                   : previous.frame.x - element.frame.x)
        }
        guard !deltas.isEmpty else { return nil }
        let sorted = deltas.map(abs).sorted()
        return sorted[sorted.count / 2]
    }

    /// 指定した `scrollFrame` が**スクロールできない領域**を指していないか。
    /// 指していれば座標は正しく作られ、スワイプは 200 を返し、**何も起きない**(端に達したのと
    /// 区別できないので署名では検出できない)= 黙った空振りになる。
    ///
    /// **判定に使えるのは「true を見つけたとき」だけ**: `scrollable` を申告できないエンジン
    /// (Compose/Flutter の in-app)では全要素が nil になるので、そこで警告すると誤報になる。
    /// だから**画面のどこかに scrollable=true が1つでもあるとき**にだけ判定する。
    /// 戻り値は注記(nil = 問題なし・申告できないエンジン)
    static func scrollFrameNote(_ frame: ElementInfo, in snapshot: SnapshotResponse) -> String? {
        guard snapshot.elements.contains(where: { $0.scrollable == true }) else { return nil }
        if frame.scrollable == true { return nil }
        // 容器そのものが scrollable でなくても、**中のスクロール可能な要素**が動けば意図は満たされる
        // (「リストを包む枠」を指定するのは自然な書き方)
        let inside = snapshot.elements.contains { element in
            element.scrollable == true && ScrollGeometry.intersection(element.frame, frame.frame) != nil
        }
        if inside { return nil }
        return "the specified scrollFrame is not scrollable"
            + " (the swipe lands there but nothing moves)"
    }

    /// 指定した `scrollFrame` が**複数の要素に当たった**ときの申告。`matchDetailed` は
    /// 添字が無ければ `matches[0]` を黙って採るので、同名の容器が並ぶ画面
    /// (Android の `#recycler_view` は1画面に3〜4個)では**preorder 先頭の横カルーセル**を
    /// 掴んだまま「見つからない」で終わる。何を掴んだかと `[n]` の書き方まで出す。
    /// 添字を明示しているときは選択済みなので黙る
    static func ambiguousScrollFrameNote(_ locator: FlowLocator, picked: ElementInfo,
                                         in snapshot: SnapshotResponse) -> String? {
        guard locator.index == nil,
              let matches = candidates(locator, elements: snapshot.elements),
              matches.count >= 2 else { return nil }
        let f = picked.frame
        return "the scrollFrame selector matched \(matches.count) elements; the first one"
            + " (\(Int(f.x)),\(Int(f.y)) \(Int(f.width))x\(Int(f.height))) was used"
            + " — add [n] to pick another"
    }

    /// `scrollFrame` 指定時のスワイプ座標。**nil = 従来の全画面固定へ落ちる**。
    /// 落ちる条件は「指定が無い」「削りすぎて動かせない」の2つ(「その画面で解決できない」は
    /// 2026-08-08 に runScrollSearch と scroll/scrollToEdge/flick の fail-fast へ移した ——
    /// ここで黙って nil を返すと、呼び手が全画面スワイプへ退化してしまう)。
    ///
    /// **毎回の snapshot から解決し直す**: 容器の矩形はスクロールやレイアウト変化で動く。
    /// 較正値は持たない(WebView のヒント跳躍と同じ自己補正の方針)
    func scrollPath(step: FlowStep, intent: FTSwipeIntent,
                            in snapshot: SnapshotResponse) -> FTSwipePath? {
        guard Self.coordinateScrollEnabled else { return nil }
        // FlowStep.direction は**指の向き**(ブリッジへ渡る語彙)。コンテンツ基準へ戻すのに
        // 逆写像を書き足さない —— 写像は `FTScrollDirection.swipe` の1箇所だけという契約
        let finger = FTSwipeDirection(rawValue: step.direction ?? "") ?? .up
        let direction = FTScrollDirection.allCases.first { $0.swipe == finger } ?? .down
        let vertical = direction == .up || direction == .down

        guard let container = scrollContainer(step: step, in: snapshot, vertical: vertical) else {
            return nil
        }

        // 自己補正(spanScale)は探索だけに掛ける。**較正表を持たない**のが方針で、
        // 実移動量を毎周測って次の刻みを詰める(WebView のヒント跳躍と同じ考え方)
        let base = step.startMarginRatio
            ?? FTScrollDefaults.startMarginRatio(intent: intent, vertical: vertical)
        let baseEnd = step.endMarginRatio
            ?? FTScrollDefaults.endMarginRatio(intent: intent, vertical: vertical)
        let scaled = Self.scaledMargins(start: base, end: baseEnd, scale: spanScale)
        // **ソフトキーボードの上でスワイプの始点を作らない**: viewport は常に `snapshot.screen`
        // だったため、キーボード表示中は始点がキーボード面に乗り(常にタッチを飲む)、
        // 中身がほぼ動かなかった(iPhone 13 実測: .search マージンで始点 y=633、
        // キーボード上端 y=509)。**container の式は変えない** —— viewport 側だけを実効
        // キーボード矩形(chrome 込み)で削る。キーボードが無ければ excludingKeyboard: nil で
        // screen がそのまま返るので、無キーボード時は1バイトも変わらない
        let keyboard = KeyboardOcclusion.resolve(reported: snapshot.keyboardFrame,
                                                 in: snapshot.elements).frame
        let path = ScrollGeometry.path(
            container: container,
            viewport: ScrollGeometry.viewport(snapshot.screen, excludingKeyboard: keyboard),
            direction: direction,
            startMarginRatio: scaled.start,
            endMarginRatio: scaled.end)
        // **容器は解決したのに動かせる幅が無い**(margin で潰れた・画面と交差しない等)。
        // fail-fast はここを通らない(容器自体は見つかっている)ので、黙って全画面へ落ちる前に
        // 理由を残す(2026-08-08。1ステップにつき1回 = pendingScrollFrameNote の空きで判定)
        if path == nil, step.scrollFrame != nil || step.scrollFrameRect != nil,
           pendingScrollFrameNote == nil {
            pendingScrollFrameNote = "the specified scrollFrame resolved but leaves nothing to move,"
                + " so the whole screen was swiped"
        }
        return path
    }

    /// このステップのスクロール対象領域。**nil = 従来の全画面固定へ落ちる**。
    /// スワイプ座標の計算(`scrollPath`)と、見つけた要素の見切れ判定の**両方**がこれを使う ——
    /// 見切れは画面ではなく**容器の縁**で起きるので、判定を画面基準にすると
    /// 「容器の外にはみ出した行」を可視とみなしてタップが容器の外(タブバー等)へ落ちる
    /// (2026-08-02 実測: #row_30 が y=745・容器の下端 762 で見つかり、中心 773 のタップが
    /// タブバーに当たって別画面へ遷移した)
    func scrollContainer(step: FlowStep, in snapshot: SnapshotResponse,
                         vertical: Bool) -> FTRect? {
        guard Self.coordinateScrollEnabled else { return nil }
        // **rect は常に解決済み**(MCP が ref から起こした矩形。id の重複・欠落で
        // セレクタが書けない容器のための経路): scrollFrameUnresolved は locator しか見ないので、
        // これを先に返すだけで fail-fast を素通りできる — 別途の分岐は要らない
        if let rect = step.scrollFrameRect { return rect }
        if let locator = step.scrollFrame {
            guard let element = Self.match(locator, in: snapshot) else {
                // **未解決は呼び手(runScrollSearch / scroll・scrollToEdge・flick アクション)が
                // fail-fast する**(2026-08-08。全画面スワイプへの黙った退化がカードのボタン等を
                // 誤発火させた実害があったため)。この関数自身は判定せず nil を返すだけでよい
                return nil
            }
            // 空振りの申告は1ステップにつき1回だけ(周回ごとに積むとレポートが埋まる)
            if pendingScrollFrameNote == nil {
                pendingScrollFrameNote = Self.scrollFrameNote(element, in: snapshot)
                    ?? Self.ambiguousScrollFrameNote(locator, picked: element, in: snapshot)
            }
            return element.frame
        }
        // **未指定は従来のエンジン既定に任せる**(2026-08-02 に実装 → 撤回 → 08-03 に条件を
        // 変えて再投入 → 再び撤回。**3度目は無い**)。2度目の撤回理由:
        //  - 狙いだった Compose の飛び越しには**効かない**。Compose の容器は xcuitest で
        //    `other` として出て `scrollable` を申告できず、そもそも対象に選べない
        //  - in-app では**到達距離が縮んで既定 maxSwipes(8)で届かなくなる**(実測:
        //    E2E-iOS/ios-inapp の `tap("#row_40")` が失敗)。in-app の 0.85 ページ送りは
        //    エンジン既定として維持する、という決定にも反する
        // 領域を絞りたい利用者は `scrollFrame` を書く(そこでは価値が出ている)
        //
        // **例外: ソフトキーボードが立っているとき**。エンジン既定(`app.swipeUp()` 等)は
        // 画面全体の固定比率で始点を作るため、キーボードの上を撃って何も動かない
        // (キーボードは常にタッチを飲む)。ここで screen を返すだけで、scrollPath 側の
        // viewport クリップ(ScrollGeometry.viewport)がキーボードを避けた始点を作るようになる。
        // キーボードが無ければ従来どおり nil のまま(3度目の暗黙座標化にはしない)
        if snapshot.keyboardFrame != nil || snapshot.keyboardShown == true {
            return snapshot.screen
        }
        return nil
    }

    /// 自己補正の倍率をマージンへ写す。span = 1 - start - end を scale 倍し、両端へ等分に戻す
    static func scaledMargins(start: Double, end: Double, scale: Double)
        -> (start: Double, end: Double) {
        guard scale < 0.999 else { return (start, end) }
        let span = max(0.05, (1 - start - end) * scale)
        let margin = max(0, (1 - span) / 2)
        return (margin, margin)
    }

    /// 座標スクロールの殺しスイッチ。`FT_SCROLL_TARGET=legacy` でブリッジ側の
    /// 固定比率(従来経路)へ丸ごと戻す
    static let coordinateScrollEnabled =
        ProcessInfo.processInfo.environment["FT_SCROLL_TARGET"] != "legacy"

    /// **容器をツリーから推測して行う補正**の殺しスイッチ。`FT_CONTAINER_INFERENCE=off` で
    /// まとめて止め、推測を持たなかった頃の挙動(見切れ判定は画面基準・掴み直し無し・
    /// 座標補正無し・候補の除外無し)へ戻す。
    ///
    /// **なぜ要るか**: 容器は「pre-order で直前にある depth の小さい要素」+「同 depth の兄弟が
    /// 2つ以上その中に居る」という**推測**で決めている(`clippingContainer`)。E2E は 4 SUT しか
    /// 見ていないので、想定外のツリーでは推測が外れ得る。外れたときに起きるのは
    /// **より悪い事態**(別の場所を叩く・明後日の方向へ送る・正当な要素が候補から消える)なので、
    /// 利用者が1つの環境変数で全部止められるようにしておく。
    /// 影響範囲を1箇所に閉じるため、**推測の入口(`clippingContainer`)と
    /// `hasClampedCoordinates` の2箇所だけ**でこのフラグを見る
    public static let containerInferenceEnabled =
        ProcessInfo.processInfo.environment["FT_CONTAINER_INFERENCE"] != "off"

    /// ヒールキャッシュのロケータ連鎖を順に照合する
    func matchCached(_ cached: [FlowLocator],
                             in snapshot: SnapshotResponse) -> (ElementInfo, FlowLocator)? {
        for locator in cached {
            if let element = Self.match(locator, in: snapshot) {
                return (element, locator)
            }
        }
        return nil
    }
}
