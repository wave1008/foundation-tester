// occlusion-guard の FM 段の判定規則(純粋関数)。FM には期待文字列を渡さず「描かれている文字」だけを
// 転写させ、可否はここで期待文字列と突き合わせて決める。
//
// **期待文字列を FM に渡さない理由**(2026-09-15 の実測・ja 70 / en 80 要素 × 合成変種 + 実 run の crop 158 枚):
// 期待文字列を prompt に入れて「見えるか」を訊く形は、空白・別の文字の crop でも observedText に
// **期待文字列をそのまま写して visible=true** と答えた(空白で 20〜23% / 別の文字で 33〜56% の見逃し。
// 同じ crop を OCR は正しく読めていた = 画像が読めないのではなく手本を写している)。転写だけを
// 求める形にすると、空白・別の文字・全面の覆いの見逃しは 0、見えている要素の誤った赤は
// ja 1/70(旧字体「擴」の誤読)・en 0/80・実 run 0/153。
//
// **反転の根拠は FM の読みだけ**(OCR の「読めなかった」は使わない。RegionText の規律と同じ)。

import Foundation

public enum TranscriptMatch {

    public enum State: String, Sendable {
        /// 期待文字列(またはその先頭)が転写に含まれる
        case fullyVisible
        /// 転写は期待文字列の途中〜末尾だけ = 先頭側が覆われている(左から覆う形の実測: 「キーボード」→「ボード」)
        case covered
        /// 転写が空 = その位置に読める文字が描かれていない(覆い・空白・画面外はここに畳む)
        case notRendered
        /// 期待と無関係な文字が描かれている
        case textMismatch
    }

    public struct Verdict: Equatable, Sendable {
        public let visible: Bool
        public let state: State
        public let reason: String
    }

    /// 切り詰めとして認める転写の最短長(正規化後の文字数)。1 文字だけの一致は偶然が多すぎる
    /// (「一」「A」のような 1 文字は期待文字列の先頭に頻出する)ので 2 文字から
    public static let truncatedPrefixMinimum = 2

    /// 許す誤読の文字数 = 正規化後の期待文字列の長さ ÷ この値(切り捨て)。
    /// 実測の誤読は 1 文字の置換・挿入(「ここに」→「こちらに」・「辞書」→「辞典」・「ォ」→「オ」)で、
    /// 5 文字未満の短い語に誤読を許すと「検索」「検定」型の別の文字を見逃すので、5 文字以上から 1 文字。
    /// ÷6 では 5 文字の 1 文字誤読(「ユーザ辞書」)が誤った赤になり、÷4 では別の文字を 1 件見逃した
    /// (「ウォレットの新機能」に「Siriによるウォレットの機能」)。値を動かすときも同じコーパスで
    /// 誤った赤と見逃しの両方を見る
    public static let misreadDivisor = 5

    /// 転写と期待文字列から可否を決める。`transcript` は FM が返した生の転写。
    public static func judge(transcript: String, expected: String) -> Verdict {
        let o = RegionText.normalize(transcript)
        let e = RegionText.normalize(expected)
        guard !o.isEmpty else {
            return Verdict(visible: false, state: .notRendered,
                           reason: "no legible text is drawn in the element's area")
        }
        guard !e.isEmpty else {
            // 期待側が空(記号だけ等)は照合のしようがない。FM が何かを読めた以上、描かれてはいる
            return Verdict(visible: true, state: .fullyVisible, reason: "")
        }
        if o.contains(e) {
            return Verdict(visible: true, state: .fullyVisible, reason: "")
        }
        if o.count >= truncatedPrefixMinimum, e.hasPrefix(o) {
            return Verdict(visible: true, state: .fullyVisible, reason: "")
        }
        // 誤読の許容。**期待文字列の先頭の文字が転写に無ければ許さない** —— 先頭が読めていない形は
        // 左からの覆い(「About」→「bout」)で、1 文字の欠けとして通すと覆いを見逃す
        let tolerance = e.count / misreadDivisor
        if tolerance > 0, let head = e.first, o.contains(head),
           approximateSubstringDistance(haystack: o, needle: e) <= tolerance {
            return Verdict(visible: true, state: .fullyVisible, reason: "")
        }
        if o.count >= truncatedPrefixMinimum, e.contains(o) {
            return Verdict(visible: false, state: .covered,
                           reason: "only the tail \"\(transcript)\" of the expected text is drawn; its beginning is covered")
        }
        return Verdict(visible: false, state: .textMismatch,
                       reason: "the text drawn there reads \"\(transcript)\", not the expected text")
    }

    /// 期待文字列と、転写の任意の部分文字列との最小編集距離(開始・終了は自由)。転写に前後の
    /// 文脈が混ざっていても、期待文字列に相当する区間だけで誤読を数える
    static func approximateSubstringDistance(haystack: String, needle: String) -> Int {
        let h = Array(haystack), n = Array(needle)
        guard !n.isEmpty else { return 0 }
        guard !h.isEmpty else { return n.count }
        var previous = [Int](repeating: 0, count: h.count + 1)
        for (i, cn) in n.enumerated() {
            var current = [i + 1]
            for (j, ch) in h.enumerated() {
                current.append(min(previous[j + 1] + 1, current[j] + 1, previous[j] + (cn == ch ? 0 : 1)))
            }
            previous = current
        }
        return previous.min() ?? n.count
    }
}
