// ScrollGeometry.swift
// スクロール対象の矩形から、スワイプの始点・終点を決める純ロジック。
// shirates-core の ScrollingInfo(bounds ∩ viewport をマージン比で削る)の移植。
// **実機を必要としない**ので、境界の扱いは全て単体テストで固定する。

import Foundation

// FTSwipePath は**ワイヤ型なので BridgeDTO.swift 側**にある(あちらはランナーのターゲットにも
// 直接コンパイルされる。このファイルは入っていないので、こちらに置くとランナーが壊れる)

public enum ScrollGeometry {
    /// マージン比の上限。start + end が 1 に達すると始点と終点が重なって**1ミリも動かない**ので、
    /// 片側 0.45(= スパン最小 0.1)で頭打ちにする
    public static let maxMarginRatio: Double = 0.45

    /// この距離(pt/px)未満のスワイプは注入しても意味がない = 呼び出し側が従来経路へ落ちる
    public static let minUsableDistance: Double = 8

    /// スクロール対象の矩形から始点・終点を出す。**戻り値 nil = この矩形では座標を作れない**
    /// (画面と交差しない / 削りすぎて動かせない)。呼び出し側は従来の全画面固定へ落ちる。
    ///
    /// - Parameters:
    ///   - container: スクロール対象の矩形(scrollFrame で解決した要素の frame)
    ///   - viewport: 画面矩形(`SnapshotResponse.screen`)。**必ず交差を取る**:
    ///     Compose iOS は画面外要素の frame がクランプされる一方、画面より大きい容器を返す
    ///     フレームワークもあり、はみ出した座標は注入しても届かない
    ///   - direction: **コンテンツ基準**(`.down` = 下に読み進める)。指の向きとは逆
    ///   - startMarginRatio: 指を置く側の余白比。**始点が容器の縁ぎりぎりだと掴めない**ため空ける
    ///   - endMarginRatio: 指を離す側の余白比
    public static func path(container: FTRect,
                            viewport: FTRect,
                            direction: FTScrollDirection,
                            startMarginRatio: Double,
                            endMarginRatio: Double) -> FTSwipePath? {
        guard let area = intersection(container, viewport) else { return nil }
        let start = clampMargin(startMarginRatio)
        let end = clampMargin(endMarginRatio)

        let path: FTSwipePath
        switch direction {
        case .down:   // 指は上へ: 下の縁から上の縁へ
            let x = area.centerX
            path = FTSwipePath(fromX: x, fromY: area.y + area.height * (1 - start),
                               toX: x, toY: area.y + area.height * end)
        case .up:     // 指は下へ
            let x = area.centerX
            path = FTSwipePath(fromX: x, fromY: area.y + area.height * start,
                               toX: x, toY: area.y + area.height * (1 - end))
        case .right:  // 指は左へ
            let y = area.centerY
            path = FTSwipePath(fromX: area.x + area.width * (1 - start), fromY: y,
                               toX: area.x + area.width * end, toY: y)
        case .left:   // 指は右へ
            let y = area.centerY
            path = FTSwipePath(fromX: area.x + area.width * start, fromY: y,
                               toX: area.x + area.width * (1 - end), toY: y)
        }
        return path.distance >= minUsableDistance ? path : nil
    }

    /// 交差矩形。幅・高さが 0 以下なら nil(接しているだけ = 操作できない)
    static func intersection(_ a: FTRect, _ b: FTRect) -> FTRect? {
        let left = max(a.x, b.x)
        let top = max(a.y, b.y)
        let right = min(a.x + a.width, b.x + b.width)
        let bottom = min(a.y + a.height, b.y + b.height)
        guard right > left, bottom > top else { return nil }
        return FTRect(x: left, y: top, width: right - left, height: bottom - top)
    }

    static func clampMargin(_ ratio: Double) -> Double {
        guard ratio.isFinite else { return 0 }
        return min(max(ratio, 0), maxMarginRatio)
    }
}

/// スクロールの既定マージン。**用途で危険の中身が違う**ので用途ごとに持つ:
/// 探索は行き過ぎると戻らず `maxSwipes` を使い切って**シナリオ全体が中断**するため保守側、
/// 端送りは行き過ぎても無害なので速度優先。
///
/// **これらは `scrollFrame` を明示したときの値**。未指定の従来経路(ブリッジ側の軸別既定)には
/// 影響しない —— 全画面固定のままスパンを広げると始点がスクロール領域の外に出て
/// 1ミリも動かない(docs/performance-tuning.md §3.16 の実害)。
public enum FTScrollDefaults {
    public static func startMarginRatio(intent: FTSwipeIntent, vertical: Bool) -> Double {
        margin(intent: intent, vertical: vertical)
    }

    public static func endMarginRatio(intent: FTSwipeIntent, vertical: Bool) -> Double {
        margin(intent: intent, vertical: vertical)
    }

    private static func margin(intent: FTSwipeIntent, vertical: Bool) -> Double {
        guard vertical else { return 0.2 }   // 横は現行(0.2↔0.8 = スパン 0.6)と同じ
        switch intent {
        // 探索は保守側(重なり 50%)。**慣性を消せないので刻み = 実移動量にはならない** ——
        // 速度を落として慣性を消す案は iOS では効くが Android に同じノブが無く、
        // 実測で収束しなかった(2026-08-02)。行き過ぎは探索の失敗に直結するので控えめに取る
        case .search: return 0.25            // スパン 0.5・重なり 50%
        case .gesture, .edge: return 0.2     // スパン 0.6
        }
    }
}
