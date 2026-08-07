// TapTargetGeometry.swift
// 「その座標を撃つと本当に狙った物へ当たるか」を木の幾何だけで判定する共有ロジック。
// **MCP(RefGuard)と DSL(StepExecutor)の両方が使う** —— 別々に持つと、同じ画面で
// 「危ないタップ」の定義が食い違う(塗り順を PaintOrder へ寄せたのと同じ理由)。
//
// ここにあるのは**幾何と木の形だけ**で、警告するか・拒否するか・注記に留めるかは呼び出し側が決める。

import Foundation

public enum TapTargetGeometry {

    /// 完全包含でも「容器」とみなす面積比の下限。実測: app bar (0,0 1080x290) は画面
    /// (1080x2424) の約 12% で、これを容器扱いすると下に潜った行への遮蔽が丸ごと無警告になる。
    /// 全画面の toolbar/collectionView・`#AdditionalDimmingOverlay` は 100% なので下回らない
    public static let fullScreenContainerAreaRatio = 0.5

    /// タップを受け止める型(ブリッジの型語彙。`other` は含めない)
    public static let interactiveTypes: Set<String> = [
        "clickable", "button", "cell", "link", "switch", "checkBox", "radioButton", "tab",
    ]

    /// outer が inner を完全に含むか(縁の丸め差 1pt は許容)
    public static func contains(_ outer: FTRect, _ inner: FTRect) -> Bool {
        outer.x <= inner.x + 1 && outer.y <= inner.y + 1
            && outer.x + outer.width >= inner.x + inner.width - 1
            && outer.y + outer.height >= inner.y + inner.height - 1
    }

    /// 自分・祖先・子孫の ref(preorder + depth から復元する)
    public static func lineage(of element: ElementInfo, in elements: [ElementInfo]) -> Set<Int> {
        var result: Set<Int> = [element.ref]
        guard let index = elements.firstIndex(where: { $0.ref == element.ref }) else { return result }
        var depth = element.depth
        for ancestor in elements[..<index].reversed() where ancestor.depth < depth {
            result.insert(ancestor.ref)
            depth = ancestor.depth
        }
        var i = elements.index(after: index)
        while i < elements.endIndex, elements[i].depth > element.depth {
            result.insert(elements[i].ref)
            i = elements.index(after: i)
        }
        return result
    }

    /// ghost ではないが**別の物に当たったかもしれない**2形の注記。空文字なら心当たり無し。
    ///
    /// ghostWarning と同じ方針で**撃ってから言う**(拒否しない)。木の幾何だけでは
    /// 「本当に描かれているか」を決められないという 2026-08-06 の結論は、この2形にも効く。
    /// **中身のどこでもない点を叩こうとしている**か。対話的でない容器(`other`)で、
    /// 子孫を持つのに**中心がそのどれの上にも無い**とき、タップは背後(地図・背景)へ抜ける。
    ///
    /// 実測(2026-08-07・Google マップ Android): `#layers_fab_button` は全幅 (0,442 1080x157) の
    /// 非 clickable コンテナで、中身は右端の FAB 1つだけ。中心 (540,520) は地図の上にあり、
    /// `ft_tap` は "done" を返しながら**海上の座標にピンを落として place page を開いた**。
    /// 名前が `..._button` で終わるのでエージェントが選びがちな形。
    ///
    /// **子の中心へ寄せる自動補正はしない** —— 黙って別の物を叩くのと同じになる。
    /// 遮蔽でも ghost でも積み重なりでもないので、既存の3つには1つも掛からない
    public static func missesItsOwnContent(_ element: ElementInfo, in elements: [ElementInfo],
                                    screen: FTRect) -> ElementInfo? {
        guard element.type == "other" else { return nil }
        let children = StepExecutor.descendants(of: element, in: elements)
        guard !children.isEmpty else { return nil }
        let cx = element.frame.x + element.frame.width / 2
        let cy = element.frame.y + element.frame.height / 2
        func covers(_ e: ElementInfo) -> Bool {
            e.frame.x <= cx && cx <= e.frame.x + e.frame.width
                && e.frame.y <= cy && cy <= e.frame.y + e.frame.height
        }
        guard !children.contains(where: covers) else { return nil }
        // **囲っている対話要素がタップを受け止めるなら黙る**: 中心が空白でも、外側の
        // 行やカードが clickable なら押した結果は妥当。**画面規模のものは数えない** ——
        // 地図やキャンバスは全画面 clickable で、そこへ抜けること自体が今回の実害
        // (実測: `#business_place_card` の中心は空白だが、包む place card が clickable で
        // 正しく開く。一方 `#layers_fab_button` を包むのは全画面の地図だけだった)
        let screenArea = screen.width * screen.height
        let absorbed = lineage(of: element, in: elements).contains { ref in
            guard ref != element.ref, let ancestor = elements.first(where: { $0.ref == ref }),
                  interactiveTypes.contains(ancestor.type), covers(ancestor) else { return false }
            let area = ancestor.frame.width * ancestor.frame.height
            return screenArea <= 0 || area < screenArea * fullScreenContainerAreaRatio
        }
        guard !absorbed else { return nil }
        // 「代わりにこれを狙え」は**自分の矩形の内側にある子**から選ぶ。木の depth だけで
        // 子孫を採ると、間引きの副作用で**視覚的に無関係な要素**が混ざる
        // (実測: `#search_omnibox_container` の子孫にページ下端のカード束が入っていた)
        return children
            .filter { contains(element.frame, $0.frame) }
            .max { ($0.frame.width * $0.frame.height) < ($1.frame.width * $1.frame.height) }
    }

    /// **撃つ前に言える「たぶん何も起きない/別の物に当たる」**を1文にする。空 = 心当たり無し。
    ///
    /// 判断はしない —— 呼び出し側が注記に混ぜるか警告にするかを決める。
    /// DSL は**ステップ注記**に混ぜる(失敗にはしない): 無効な要素をわざと叩いて
    /// 「反応しないこと」を確かめる書き方は正当で、`enabledIsFalse` も用意されている。
    ///
    /// 2つとも実測に基づく(2026-08-07):
    /// - `disabled`: 木には印字しているのに操作経路が `enabled` を一度も見ておらず、
    ///   E2E-CMP の契約上「押しても何も起きない」ボタンへ tap/press/doubleTap の3つとも
    ///   無警告で成功を返していた
    /// - 中身外し: `#layers_fab_button`(全幅・中身は右端の FAB だけ)を叩くと、
    ///   中心が地図の上にあるので**海上の座標にピンが落ちて place page が開いた**
    public static func advisory(for element: ElementInfo, in elements: [ElementInfo],
                                screen: FTRect) -> String? {
        if !element.enabled {
            return "the target is disabled, so this almost certainly did nothing"
        }
        guard let inner = missesItsOwnContent(element, in: elements, screen: screen) else {
            return nil
        }
        let name = inner.identifier.map { "#\($0)" } ?? inner.label.map { "\"\($0)\"" } ?? inner.type
        return "the target is not interactive and its centre is not over any of its own content,"
            + " so the touch went to whatever is behind it (aim at \(name) instead)"
    }
}
