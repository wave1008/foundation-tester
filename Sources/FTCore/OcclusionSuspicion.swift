// [PoC occlusion-guard] FM/スクショを使わない Tier-0 の幾何ヒューリスティック。
// スナップショット(ツリー)だけで occlusion の疑いを検出し、疑わしい時だけ FM に回すための前段。
// ピクセル事前フィルタ([RegionInk])が苦手な「部分的な覆い(残テキストのインクが多く高分散に見える)」
// を、覆う要素がツリーに載っているケースで拾うのが主目的。OR で併用する。

import Foundation

public enum OcclusionSuspicion {
    /// ツリーのみで occlusion を疑うか。true=疑い(FM へ)/false=幾何的には無罪。
    /// - looseMatch: ロケータが部分一致(substring)で解決した=別要素を掴んだ疑い。
    /// - overlapFraction: 対象 frame をこの割合以上覆う「手前寄りの別要素」があれば疑う。
    ///   手前寄りは snapshot の記載順(後=手前に描かれやすい)で近似する。a11y 順は z 順の保証では
    ///   ないため過検出寄り(疑い側に倒す=FM を1回余計に呼ぶだけで安全側)。
    public static func geometric(element: ElementInfo, in elements: [ElementInfo],
                                 screen: FTRect, looseMatch: Bool,
                                 overlapFraction: Double = 0.4) -> Bool {
        if looseMatch { return true }
        let t = element.frame
        // 画面外へはみ出す=可視部分が切れる
        if t.x < -0.5 || t.y < -0.5
            || t.x + t.width > screen.width + 0.5
            || t.y + t.height > screen.height + 0.5 { return true }
        let area = max(1, t.width * t.height)
        guard let selfIndex = elements.firstIndex(where: { $0.ref == element.ref }) else { return false }
        for (i, other) in elements.enumerated() where i > selfIndex {   // 記載順で後=手前寄り
            if intersectionArea(t, other.frame) / area >= overlapFraction { return true }
        }
        return false
    }

    static func intersectionArea(_ a: FTRect, _ b: FTRect) -> Double {
        let x = max(a.x, b.x), y = max(a.y, b.y)
        let right = min(a.x + a.width, b.x + b.width)
        let bottom = min(a.y + a.height, b.y + b.height)
        return max(0, right - x) * max(0, bottom - y)
    }
}
