// 木の中に**同じ連続領域が2回**現れる形の判定。**MCP と DSL の唯一の定義元**。
//
// なぜ要るか(監査ラウンド5・2026-08-13・jma.go.jp を横スクロールした後の iOS Safari で実測):
// 横スクロールで前後のコピーが両方残ると、片方は既にスクロールで動いた実座標を持たないまま
// 木に残る。**片方のコピーは画面に描かれていない**ので、そちらを掴んで撃つと何も起きないか、
// 現在そこに描かれている別の要素へ当たる。
//
// **`hasClampedCoordinates` では代替できない**(≥3要素が**同じ深さで同一 frame**を共有することを
// 要求する。ここでの重複行は frame が違う(x だけ違う)ので、流用しようとしても発火し得ない)。
// 遮蔽・ghost と同じ「一覧の ref を信用してよいか」の系統だが、判定軸が別なので独立に持つ。
//
// 呼び手は2つ: MCP は `duplicateRegionNote` で一覧の上に注記する / DSL は掴んだ要素が
// 複製区間に入っているときだけ `StepNote.staleDuplicateRegion` を運ぶ(`riskFor`)。

import Foundation

public enum DuplicateRegion {

    /// 「同じ領域が2回出ている」と数える連続一致の下限。
    ///
    /// 根拠(2026-08-13・37枚の固定コーパス。下の y/x 制約を入れた後の実測):
    /// witness の `ios-browser_jma_hscroll` = 10、他の全画面は最大3(`and-home`。それ以外は 0〜2)。
    /// 6 はその倍近く上に置いてある。**尽きたとき**(実アプリで誤検知)は数字を動かす前に
    /// その画面をコーパスへ足し、何が一致しているのかを見ること
    public static let minimumRun = 6

    /// 同じ行とみなす y の許容差(pt/px)。横スクロールの残骸は**行はそのまま x だけ動く**
    public static let sameRowTolerance = 2.0
    /// 別の列とみなす x の下限(pt/px)。これ以下は丸め差
    public static let shiftedColumnMinimum = 2.0

    /// 見つかった複製。`firstIndex`/`secondIndex` は `elements` の添字(ref ではない)
    public struct Match: Sendable, Equatable {
        public let firstIndex: Int
        public let secondIndex: Int
        public let length: Int
        public let firstRef: Int
        public let secondRef: Int

        /// `index` がどちらかのコピーの中に入っているか
        public func covers(index: Int) -> Bool {
            (firstIndex..<(firstIndex + length)).contains(index)
                || (secondIndex..<(secondIndex + length)).contains(index)
        }
    }

    /// 最長の複製区間。無ければ nil。
    ///
    /// **単純な「(type,label,value) の最長共通連続列」では誤検知する**(2026-08-13 に実装して
    /// すぐ撤回): witness フィクスチャの最長一致(11)の正体は、**別々の2つの表が同じ8列の
    /// 日付見出し行を共有している**形だった(「東京地方」の見出し y=463 と「伊豆諸島」の見出し
    /// y=722 —— どちらも `["日付","今夜 12日(水)", …]` を名乗る、正当なページ構造)。
    /// **同じ行(y がほぼ同じ)で x だけがずれた一致だけを候補にする**ことでこれを機械的に除く。
    /// **この y/x 制約を外して「キーだけの一致」へ単純化しないこと**(上の誤検知が戻る)。
    ///
    /// witness(`ios-browser_jma_hscroll`、refs 72-81 vs 158-167。全10ペアとも同じ y・
    /// x が定数200ptずれる。最左列は 0 にクランプされる):
    ///   東京(x=25,y=629 / x=0,y=629)・最高(x=70,y=627 / x=0,y=627)・
    ///   29(x=220,y=627 / x=20,y=627)・(28〜32)(x=277,y=638 / x=77,y=638)
    ///
    /// アルゴリズムは longest-repeated-substring の変形(2行だけ持つ DP)。
    /// **O(n²) だが最適化しない**(2026-08-13 に実測してから決めた): debug ビルドで n=233 が
    /// 8.5ms・n=120 が 2.2ms で、同じ木の全注記の合計に対して 1〜5% に過ぎない。
    /// キーを Int へ畳んで String 比較を無くす案は 8.6 → 7.8ms にしかならず、
    /// **主因は比較ではなく反復そのもの**だった
    public static func find(in elements: [ElementInfo]) -> Match? {
        let n = elements.count
        guard n >= 2 else { return nil }
        let keys = elements.map { Key(type: $0.type, label: $0.label ?? "", value: $0.value ?? "") }

        func extendsRun(_ a: Int, _ b: Int) -> Bool {
            guard keys[a] == keys[b] else { return false }
            let fa = elements[a].frame, fb = elements[b].frame
            return abs(fa.y - fb.y) <= sameRowTolerance
                && abs(fa.x - fb.x) > shiftedColumnMinimum
        }

        // **一様な1行を「2回出ている」と読まないための材料**。重なり禁止だけでは足りない ——
        // 同じキーのセルが 12 個並ぶと 6+6 の**重ならない**2区間に割れて発火する(独立に再現済み)。
        // 本物の複製は「**変化のある並び**がそのまま繰り返される」形なので、**採った区間が
        // 2種類以上のキーを含むこと**を要求する。区間ごとに数えると O(n³) になるので、
        // 隣接が変わる位置の累積で O(1) 判定にする
        var variedPrefix = [Int](repeating: 0, count: n + 1)
        for k in 1..<max(n, 1) {
            variedPrefix[k + 1] = variedPrefix[k] + (keys[k] == keys[k - 1] ? 0 : 1)
        }
        func spansTwoKinds(from start: Int, length: Int) -> Bool {
            guard length >= 2, start + length <= n else { return false }
            return variedPrefix[start + length] - variedPrefix[start + 1] > 0
        }

        var bestLength = 0, bestI = 0, bestJ = 0
        var previous = [Int](repeating: 0, count: n + 1)
        for i in 1...n {
            var current = [Int](repeating: 0, count: n + 1)
            for j in 1...n where i < j {
                guard extendsRun(i - 1, j - 1) else { continue }
                let length = previous[j - 1] + 1
                current[j] = length
                // **2つの区間が重なっていないこと**。この制約が無いと、**同じ行に同種・同ラベルの
                // セルが並んでいるだけ**で自分自身と一致する(`minimumRun=6` なので7個並べば発火する。
                // 無ラベルのセル・ページ送りのドット等)。言いたいのは「同じ領域が2回出ている」なので、
                // 重なる区間は候補にしない。**採用時に弾く**(最後に弾くと、重なる長い一致が
                // 本物の短い一致を隠して黙る)
                if length > bestLength, j - i >= length,
                   spansTwoKinds(from: i - length, length: length) {
                    bestLength = length
                    bestI = i - length
                    bestJ = j - length
                }
            }
            previous = current
        }
        guard bestLength >= minimumRun else { return nil }
        return Match(firstIndex: bestI, secondIndex: bestJ, length: bestLength,
                     firstRef: elements[bestI].ref, secondRef: elements[bestJ].ref)
    }

    /// **掴んだ要素が複製区間に入っているか**(DSL の入口)。
    ///
    /// `find` を毎ステップ無条件に呼ばないための安価な門を先に通す: 複製が成立するには
    /// `element` 自身に「同じキー・同じ行・違う列」の相方が居なければならないので、
    /// **O(n) のその検査で落ちる木では DP を回さない**(横スクロールの残骸が無い普通の画面は
    /// ここで抜ける = 固定費は要素の1走査だけ)。
    ///
    /// **門は必要条件であって十分条件ではない**(相方が居るだけでは「領域が2回」ではない)ので、
    /// 通った場合は必ず `find` で確かめる
    public static func riskFor(_ element: ElementInfo, in elements: [ElementInfo]) -> Match? {
        let key = Key(type: element.type, label: element.label ?? "", value: element.value ?? "")
        let hasTwin = elements.contains { other in
            other.ref != element.ref
                && Key(type: other.type, label: other.label ?? "",
                       value: other.value ?? "") == key
                && abs(other.frame.y - element.frame.y) <= sameRowTolerance
                && abs(other.frame.x - element.frame.x) > shiftedColumnMinimum
        }
        guard hasTwin else { return nil }
        guard let match = find(in: elements),
              let index = elements.firstIndex(where: { $0.ref == element.ref }),
              match.covers(index: index)
        else { return nil }
        return match
    }

    private struct Key: Equatable {
        let type: String
        let label: String
        let value: String
    }
}
