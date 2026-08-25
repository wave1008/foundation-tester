// SettleMotion.swift
// 「まだ減速中か」の判定。整定待ちを**時間予算ではなく観測できる事象**に載せ替えるための純粋ロジック。
//
// なぜ要るか(2026-08-25): 整定は `scrollSettleMaxPolls`(6×100ms)で打ち切られ、打ち切っても
// `settle-capped` を注記して先へ進んでいた。**223/223 が緑だった run でも 34 回打ち切られており**
// (Flutter 16 / CMP 12 / iOS 3 / RN 3・Android は 0 = 慣性を持つのは iOS の XCUITest
// ジェスチャだけ)、動いている画面で次へ進むのが常態化していた。無害に見えていたのは
// 直後のステップが偶然時間を食っていたからで、その費用が消えた瞬間に横カルーセルが 3/3 で落ちた。
//
// 上限を増やすのでも静止するまで待つのでもなく、**待ち続ける根拠を観測から取る**:
// フリングの変位は単調に縮む。縮んでいる間は待ち、縮まなくなったら抜ける。

import Foundation

public enum SettleMotion {

    /// 連続する2枚の木の「動いた量」(pt)。**共通する要素だけ**で測る ——
    /// スクロールでは行が出入りするので、集合が変わること自体を動きと混同しない。
    ///
    /// 対応付けは `type` + 名前(identifier 優先・無ければ label)。どちらも無い要素は
    /// 同一性が決まらないので**数えない**(装飾の staticText が大量にある画面で、
    /// 別物どうしを引き算して巨大な変位を捏造しないため)。
    ///
    /// 共通の要素が1つも無いときは nil = **判定不能**。呼び手は「まだ動いている」側に倒す
    /// (画面がまるごと入れ替わった直後で、静止したと言える根拠が無い)。
    public static func displacement(from previous: [ElementInfo],
                                    to current: [ElementInfo]) -> Double? {
        func key(_ e: ElementInfo) -> String? {
            guard let name = e.identifier ?? e.label, !name.isEmpty else { return nil }
            return "\(e.type)|\(name)"
        }
        // 同じ鍵が複数あるとどれと引き算するか決まらないので、重複した鍵は捨てる
        func index(_ elements: [ElementInfo]) -> [String: FTRect] {
            var seen: [String: FTRect] = [:]
            var duplicated: Set<String> = []
            for element in elements {
                guard let k = key(element) else { continue }
                if seen[k] != nil { duplicated.insert(k); continue }
                seen[k] = element.frame
            }
            for k in duplicated { seen.removeValue(forKey: k) }
            return seen
        }
        let before = index(previous)
        let after = index(current)
        var maximum: Double?
        for (k, from) in before {
            guard let to = after[k] else { continue }
            let moved = max(abs(to.x - from.x), abs(to.y - from.y))
            maximum = max(maximum ?? 0, moved)
        }
        return maximum
    }

    /// 変位の履歴(古い順)から「まだ減速中か」を返す = 待ち続けてよいか。
    ///
    /// - 直近が 0 → 止まった。待たない(署名一致の判定が別に拾うが、こちらでも false)
    /// - 直近が**その前より小さい** → 減速中。待つ
    /// - 横ばい・増加 → スクロールの減速ではない。待たない
    ///   (等速で動き続けるアニメーションを待つと、その画面では毎ジェスチャが上限まで待つ)
    /// - 判定材料が1つしか無い(履歴が1件)→ もう1周は待つ。1点では傾きが出ない
    ///
    /// **nil(判定不能)は「動いている」扱い** —— 共通要素が無いのは画面が入れ替わった直後で、
    /// 静止したと言える根拠が無い。
    public static func isDecelerating(_ history: [Double?]) -> Bool {
        guard let latest = history.last else { return false }
        guard let latest else { return true }
        if latest == 0 { return false }
        guard history.count >= 2 else { return true }
        guard let previous = history[history.count - 2] else { return true }
        return latest < previous
    }
}
