// 木の中に**同じ連続領域が2回**現れる形の判定。**MCP と DSL の唯一の定義元**。
//
// なぜ要るか(2026-08-13・jma.go.jp を横スクロールした後の iOS Safari で実測):
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

    /// 同じ行とみなす y の許容差(pt/px)。横スクロールの残骸は**行はそのまま x だけ動く**。
    ///
    /// 根拠(2026-08-15・witness `ios-browser_jma_hscroll` の複製10ペアを実測。
    /// refs 72-81 vs 158-167): 全ペアの y 差は**厳密に 0**(このアプリのレイアウトは pt に
    /// 整列済み)。2.0 は非0の実測差から出した値ではなく、**将来ずれうる丸め誤差への安全余裕**
    /// —— 行の高さ(witness で 19pt)からは一桁小さいので、隣接する別の行と誤認する余地は
    /// 無い。**流用の安全性**(pt/px の両方に同じ値を当てる理由): 丸め誤差はどちらの単位でも
    /// 1 未満で、セルの寸法(witness で 18〜59pt)からは同じく一桁小さい。桁が近いから安全なの
    /// ではなく、**どちらの単位でも「丸め」と「セル1つ分」の間に少なくとも一桁の余白がある**
    /// ことが流用の根拠。
    public static let sameRowTolerance = 2.0
    /// 別の列とみなす x の下限(pt/px)。これ以下は丸め差として無視する。
    ///
    /// 根拠: 同じ10ペアの x 差の実測は 25〜200pt(最小は「東京」列の25pt)。2.0 はこの最小の
    /// 実差より1桁小さく、かつ丸め誤差(<1)よりは大きい —— 両側に余裕を残して選んだ。
    public static let shiftedColumnMinimum = 2.0
    /// **尽きたとき**(実アプリで sameRowTolerance/shiftedColumnMinimum が誤検知・見逃しを
    /// 出す)は、数字を動かす前にその画面をコーパスへ足し、y/x のどちらがずれているのか
    /// (丸めか、実際に行/列が動いているのか)を実測してから直すこと(`minimumRun` と同じ規律)

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
    /// **主因は比較ではなく反復そのもの**だった。
    ///
    /// **常に最長の1件だけを返す**(2つ目以降の複製領域は取りこぼす)。全件が要るなら `findAll` を使う
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

        // **窓自身が周期的か**(ある 1 <= p < length で keys[k] == keys[k+p] が窓内全域で成り立つ)。
        // 周期的な窓は「パターンが繰り返されているだけの1本の行」と「2つの独立した領域」を
        // 幾何的に区別できない(A,B,A,B,… の前半と後半はつねに一致してしまう)。この判定は
        // 最終的な最長一致(採用直前)だけに掛ける ——「拾い直し」まではしない(棄却したら nil)
        func isPeriodic(from start: Int, length: Int) -> Bool {
            guard length >= 2 else { return false }
            for p in 1..<length {
                var matchesAllOffsets = true
                for k in 0..<(length - p) where keys[start + k] != keys[start + k + p] {
                    matchesAllOffsets = false
                    break
                }
                if matchesAllOffsets { return true }
            }
            return false
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
        // 重なり禁止(`j - i >= length`)は境界ちょうどでは素通しする(length=6 の周期2なら
        // j-i=6 で通過)ので、採用直前に周期性を明示的に見て黙る側に倒す
        guard !isPeriodic(from: bestI, length: bestLength) else { return nil }

        return Match(firstIndex: bestI, secondIndex: bestJ, length: bestLength,
                     firstRef: elements[bestI].ref, secondRef: elements[bestJ].ref)
    }

    /// `find` を貪欲に繰り返し、木の中の複製領域を尽くす(2つ目以降を取りこぼさない)。
    ///
    /// **偽の境界越え連続を作らない設計**: 見つかった領域を配列から取り除いて残りを詰め直すと、
    /// 取り除いた前後の要素が新たに隣接し、`extendsRun`(文書順の連続前提)が本来離れていた
    /// 要素同士を「連続」と誤認しうる。代わりに**元配列の範囲をセグメントに分割して独立に
    /// `find` を回す**(前方 / 両コピーの間 / 後方の3区間)。区間は常に元配列の連続部分列
    /// (詰め直さない)なので、取り除いた境界を跨ぐ隣接はそもそも起こらない。
    /// 添字はセグメントの開始位置を足して**元配列基準へ写像し直す**(`Match.covers` が
    /// 元添字で効くことが `riskFor` の要件)。
    ///
    /// 停止は自明: 1回のマッチが最低 `2 * minimumRun` 要素を消費するので、3つの部分区間の
    /// 合計は必ず縮む(上限定数は要らない)。
    static func findAll(in elements: [ElementInfo]) -> [Match] {
        var results: [Match] = []
        func search(_ range: Range<Int>) {
            guard range.count >= 2 * minimumRun else { return }
            guard let match = find(in: Array(elements[range])) else { return }
            let firstIndex = range.lowerBound + match.firstIndex
            let secondIndex = range.lowerBound + match.secondIndex
            results.append(Match(firstIndex: firstIndex, secondIndex: secondIndex,
                                  length: match.length,
                                  firstRef: match.firstRef, secondRef: match.secondRef))
            search(range.lowerBound..<firstIndex)
            search((firstIndex + match.length)..<secondIndex)
            search((secondIndex + match.length)..<range.upperBound)
        }
        search(0..<elements.count)
        return results
    }

    /// `index` を含む、文書順で連続する `minimumRun` 個の窓であって、①窓内の全要素が
    /// 各自「同じキー・同じ行・違う列」の双子を持ち、②窓内に2種類以上のキーがある、
    /// ものが存在するか。`riskFor` が `findAll` の DP を回す前に通す門(この形にした経緯は
    /// `riskFor` のコメント)。
    ///
    /// 実装は、キー→添字一覧の辞書を1回作り(O(n))、各要素の双子有無をその**同キー群の中だけ**
    /// 走査して判定する(O(群サイズ)。全要素との比較ではない)。窓は `index` の前後
    /// `minimumRun` 範囲だけを見る(新しい調整定数は置かない —— 窓長は `minimumRun` を使う)。
    ///
    /// **健全性**(false のとき `find`/`findAll` はこの添字を覆わない): 本物の複製領域
    /// (長さ L>=minimumRun)の内部にある要素は、その領域に収まる minimumRun 窓が①を満たす
    /// (領域内の全要素が offset d の双子を持つ)。②も、採用条件 `spansTwoKinds` が領域内に
    /// 隣接キー変化を要求するために満たされる —— 37枚の固定コーパスの複製領域(witness)は
    /// 変化が列ごとに分布しており、どの位置を含む窓を取っても2種以上になることを実測で
    /// 確認している(`DuplicateRegionTests` のコーパス不変条件がこれを継続して固定する)。
    /// **一様なラベル無し行**(同キーが並ぶだけ)は②で、**孤立した双子1組**は窓自体が
    /// 作れず①で、それぞれここで抜ける。
    static func hasQualifyingWindow(around index: Int, in elements: [ElementInfo]) -> Bool {
        let n = elements.count
        guard n >= minimumRun else { return false }
        let keys = elements.map { Key(type: $0.type, label: $0.label ?? "", value: $0.value ?? "") }
        var groups: [Key: [Int]] = [:]
        for i in 0..<n { groups[keys[i], default: []].append(i) }

        func hasTwin(_ i: Int) -> Bool {
            let fi = elements[i].frame
            return groups[keys[i], default: []].contains { j in
                j != i
                    && abs(elements[j].frame.y - fi.y) <= sameRowTolerance
                    && abs(elements[j].frame.x - fi.x) > shiftedColumnMinimum
            }
        }

        let lowStart = max(0, index - minimumRun + 1)
        let highStart = min(index, n - minimumRun)
        guard lowStart <= highStart else { return false }
        for start in lowStart...highStart {
            let window = start..<(start + minimumRun)
            guard window.allSatisfy(hasTwin) else { continue }
            if Set(window.map { keys[$0] }).count >= 2 { return true }
        }
        return false
    }

    /// **掴んだ要素が複製区間に入っているか**(DSL の入口)。
    ///
    /// `findAll` を毎ステップ無条件に呼ばないための安価な門(`hasQualifyingWindow`)を先に通す。
    /// **単に「相方が1つ居るか」だけの門では緩すぎた**(2026-08-15 に強化): ラベル無し同型要素の
    /// 行(写真グリッド・アイコン列・ページドット)は全要素が互いの相方になるので毎回門を通り、
    /// **毎タップ** O(n²) の DP を払ってほぼ常に nil を得ていた。窓に「2種類以上のキー」を
    /// 要求することで、一様な行は `find`/`findAll` を呼ぶ前に落とせる。
    ///
    /// **門は必要条件であって十分条件ではない**(窓の形だけでは「領域が2回」ではない)ので、
    /// 通った場合は必ず `findAll` で確かめる
    public static func riskFor(_ element: ElementInfo, in elements: [ElementInfo]) -> Match? {
        guard let index = elements.firstIndex(where: { $0.ref == element.ref }) else { return nil }
        guard hasQualifyingWindow(around: index, in: elements) else { return nil }
        return findAll(in: elements).first { $0.covers(index: index) }
    }

    private struct Key: Hashable {
        let type: String
        let label: String
        let value: String
    }
}
