// ContainerGeometry.swift
// 容器推定・chrome 判定・クランプ座標の検知(純粋な幾何判定)。StepExecutor+Settle.swift のジェスチャ整定とは別領域

import Foundation

public enum ContainerGeometry {

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
    /// **交差の有無で絞らない** —— 「容器と交差しないときだけ容器を返す」条件を入れると、
    /// **縁をまたぐ要素で nil に落ちて viewport が画面全体になる**。
    /// Compose は縁をまたぐ行を「原点はクリップ前・サイズはクリップ後」の混成で返すので、
    /// `#list_rows` が y 230..692 のとき `#row_30` が `(16,206 370x43)` = **中心 227.5 が容器の外**
    /// になる。画面基準では「見えている」と判定されて探索が止まり、隙間をタップして飲まれていた
    /// (S0110 の失敗 21 件中 **12 件**がこの形)。
    ///
    /// **scrollable を申告している祖先があればそれを優先する**(受け手の最小再現):
    /// 横カルーセル(`other scroll`)> カード(`clickable`)> ラベル+バッジ、の木では上の規則が
    /// **カード自身**を容器に選ぶ(同じ深さの子を2つ持つ直近の祖先だから)。右にはみ出したカードを
    /// 画面と交差させると幅 42pt しか残らず、幅 98pt のラベルが「viewport より大きい」扱いになって
    /// 見切れ判定が免除され、回復ドラッグに入らないまま既定の全画面スワイプ(縦容器基準)が
    /// 横カルーセルに届かず `nothing moved` で落ちた。クリップするのはカードではなくスクロール容器
    /// なので、**申告があるときはそれが正**。申告の無い木(Compose iOS は xcuitest で申告できない)は
    /// 上の規則のみ = 挙動は変わらない
    static func clippingContainer(of element: ElementInfo, in elements: [ElementInfo],
                                  inferring enabled: Bool = ContainerGeometry.containerInferenceEnabled) -> FTRect? {
        guard enabled,
              let index = elements.firstIndex(where: { $0.ref == element.ref }) else { return nil }
        let tight = siblingRuleContainer(of: element, at: index, in: elements)
        // **申告の祖先へ倒すのは「深さ由来の候補が小さすぎる」ときだけ**。
        //
        // 申告を無条件で優先すると、縦リストのように**行の容器が scrollable を
        // 申告せず外側の全画面 scrollView だけが申告する**木で容器が画面全体へ広がり、
        // 慣性で動いている最中の見切れ・整定判定が効かなくなる(iOS xcuitest 限定の退行。
        // maintainer-notes §4.5.1)。**それ以外は元の経路とまったく同じ**にする ——
        // 候補が無ければ nil を返すところまで含めて(nil と「画面全体」は下流で別物として効く)。
        //
        // 倒す条件は**元の不具合そのものの形**: 横カルーセルではカード(164 幅)を容器に選び、
        // カルーセル(402 幅)で切ると **42 幅**になって要素「スタンプラリー」(98 幅)を収められず、
        // 「viewport より大きい」扱いで見切れ判定が免除された。**小さすぎる候補だけを退ける**。
        //
        // **収まり・重なりでは判定しない**(2案とも実機で否定した)。動いている最中は
        // 行が容器の縁・外に報告されるので、位置を見る述語は**効いてほしい瞬間だけ**申告容器へ
        // 倒れる。代償として、位置的に無関係な候補を退ける力は失う(実アプリのコーパス
        // `and-browser_weather_weekly` の ghost 1件ぶん、基準値が戻る)——
        // スクロール探索が別の行を撃つ実害と、警告レベルの検知1件を秤にかけた判断
        guard let tight else {
            // 深さの規則が候補を出せない木でも、scrollable を申告する祖先があればそれが clip 元。
            // 実測(E2E-iOS in-app・#txt_offscreen): 700pt の余白の後ろの最後の要素は
            // 可視域に兄弟が 1 つしか居ないので nil に落ち、viewport が画面全体へ広がって
            // 容器の下端(778)を 18pt はみ出した要素(776..796)が「見えている」で探索を止めていた。
            // 実際にはタブバーの裏で 2pt しか描かれておらず、FM の転写が正しく反転する = 探索側の穴。
            // 申告が無い木は nil のまま(下流は nil と画面全体を別物として扱う)
            return nearestScrollableAncestor(of: element, at: index, in: elements)?.frame
        }
        if let scroller = nearestScrollableAncestor(of: element, at: index, in: elements),
           let clipped = ScrollGeometry.intersection(tight, scroller.frame),
           !canHold(clipped, element.frame) {
            return scroller.frame
        }
        return tight
    }

    /// 「同じ深さの子を2つ持つ直近の祖先」= Compose iOS 向けの近似(申告の無い木ではこれが唯一の手)。
    /// preorder 祖先の連鎖(ancestors(of:in:) と同じ復元)を辿り、**同じ depth の行を1件も含まない
    /// 候補は飛ばす**(実機 iPhone 13: 見出し `staticText "アカウント"` d11 95x22 が
    /// `#btn_logout` d12 の直前に来て、単純な「直前の depth の小さい要素=親」という仮定を崩し、
    /// 容器を丸ごと見失っていた。見出しは行を1件も含まないので葉と分かる)。
    /// **要素自身との交差を gate にしてはいけない**: ghost(容器の完全に外へ報告された行)は容器と
    /// 交差しないが、その容器こそ `isOutsideContainer` が要る答え。行を1件でも含む候補はそのまま
    /// (2件未満なら nil で確定、上へは辿らない = 「直近の祖先1つ」の規律)
    private static func siblingRuleContainer(of element: ElementInfo, at index: Int,
                                             in elements: [ElementInfo]) -> FTRect? {
        var depth = element.depth
        var cursor = index
        while cursor > 0 {
            cursor -= 1
            let candidate = elements[cursor]
            guard candidate.depth < depth else { continue }
            // **入力欄は容器候補にしない**(`depth` も下げない = 本物の容器まで遡り続ける)。
            // 実機 iPhone 13 の検索結果で実測: 上に貼り付いた
            // `textView #field_search` (56,55 326x57) は、平坦な木では後続の全要素を「子孫」に
            // 持つため「同じ depth の行を2件以上含む候補」を満たして採用され、画面の下半分に
            // ある**正しく描かれたカードのハート4件**まで「容器の外」= ⚠️scroll-leftover に
            // なった(本当に潜っている2件は別経路なので無印のまま)。行を2件供給していたのは
            // その欄の下に潜り込んだクランプ残骸そのもので、**誤りが強いほど条件を満たす**形
            if TypeReadback.isTextInput(candidate) { continue }
            depth = candidate.depth
            guard candidate.frame.width > 0, candidate.frame.height > 0 else { continue }
            let siblings = LocatorResolver.descendants(of: candidate, in: elements).filter { $0.depth == element.depth }
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
    /// **容器の外側の帯に固定された chrome は ghost から除く**(and-sutec_home で実際に踏んだ):
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
    /// 実測(and-sutec_home): Compose Scaffold の NavigationBar が無ラベルで
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

    /// **報告された座標が壊れている要素**か(= 同じ場所に同じ深さの兄弟が積み上がっている)。
    ///
    /// フレームワークは**容器の可視域を外れた子孫の frame の原点を、容器の原点へクランプする**。
    /// XCUITest の `UITableView` では**実体化していない行のラベルまでツリーに載り**、
    /// 全部が容器の原点に積み上がる(実採取: 40 行のうち **32 個**が
    /// `(16,270 330x56)` に重なり、**すべて depth 8**)。これを掴むと:
    ///   - `tap("行 15")` が**先頭行をタップする**(実採取で再現。可視性ガードを通らないので沈黙)
    ///   - `exist("行 15")` が画面外なのに真を返す(「exist は非スクロール」の契約に反する)
    ///
    /// **判定に depth の一致が要る**(過去レポート 466 件へ当てて確認): frame だけで
    /// 判定すると `homepage_container > main_content > list_container > recycler_view` のような
    /// **入れ子の連鎖**(親子が同じ矩形を持つのは普通)を巻き込む。祖先と子孫は depth が違うので、
    /// 「同じ depth = 兄弟」を条件にすれば連鎖は残る。
    ///
    /// **「同じ場所に3つ」だけでは足りない**(症状で判定したら既存テスト 13 件が落ちた)。
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
                                      inferring enabled: Bool = ContainerGeometry.containerInferenceEnabled) -> Bool {
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
}
