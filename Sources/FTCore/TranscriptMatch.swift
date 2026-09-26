// occlusion-guard の FM 段の判定規則(純粋関数)。FM には期待文字列を渡さず「描かれている文字」だけを
// 転写させ、可否はここで期待文字列と突き合わせて決める。
//
// **期待文字列を FM に渡さない理由**(実測・ja 70 / en 80 要素 × 合成変種 + 実 run の crop 158 枚):
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
        /// 転写が期待文字列の真の先頭部分で、生の転写(正規化前)の末尾に省略記号(`…`/`...`)がある
        /// = アプリの意図した省略。読めた割合に関わらず緑
        case ellipsized
        /// 転写が期待文字列の真の先頭部分で、省略記号は無いが読めた割合が `mostlyHiddenRatio` を
        /// 超える(緑・一部だけ隠れている)
        case partiallyHidden
        /// 転写が期待文字列の真の先頭部分だが、読めた割合が `mostlyHiddenRatio` 以下(赤)
        case mostlyHidden
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
        public init(visible: Bool, state: State, reason: String) {
            self.visible = visible
            self.state = state
            self.reason = reason
        }
    }

    /// **末尾だけ読めた `covered` 判定だけで使う**最短長(正規化後の文字数)。1 文字だけの一致は
    /// 偶然が多すぎる(「一」「A」のような 1 文字は期待文字列の末尾に頻出する)ので 2 文字から。
    /// 先頭一致(`mostlyHidden`/`partiallyHidden`/`ellipsized`)の分岐はこれを使わない ——
    /// 期待が2文字以上なら1文字の先頭一致は必ず比 ≤ `mostlyHiddenRatio` で赤になるので包含される
    public static let truncatedPrefixMinimum = 2

    /// 先頭一致の読めた割合がこれ以下なら赤(`mostlyHidden`)、これを超えれば緑(`partiallyHidden`)。
    /// 根拠: ユーザー決定(読めたのが期待テキストの半分以下なら赤)。単位は正規化後の文字数の比。
    /// 「以下」なので境界ちょうど 0.5 は赤
    public static let mostlyHiddenRatio = 0.5

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
        // 先頭一致(o は e の真の先頭部分。o == e は上の contains(e) が既に拾っている)。
        // 省略記号 → 割合次第で緑/赤の3分岐。
        // **省略記号があるときだけ先頭一致に誤読を許す**(長さ÷misreadDivisor 文字)—— 長い省略で
        // 1 文字を読み落とした形(「全体的な設定や自…」→「全体な設定や自…」)が「別の文字」で赤になっていた。
        // 省略記号が無いときに許すと、値だけ違う読み(「tap=0」に「tap=3」)が「一部が隠れている」に化ける
        let ellipsized = RegionText.endsWithEllipsis(transcript)
        let prefixLength = e.hasPrefix(o) ? o.count
            : (ellipsized ? approximatePrefixLength(of: o, in: e) : nil)
        if let prefixLength, prefixLength < e.count {
            if ellipsized {
                return Verdict(visible: true, state: .ellipsized, reason: "")
            }
            let ratio = Double(prefixLength) / Double(e.count)
            if ratio > mostlyHiddenRatio {
                return Verdict(visible: true, state: .partiallyHidden, reason: "")
            }
            return Verdict(visible: false, state: .mostlyHidden,
                           reason: "most of the text is hidden")
        }
        // 誤読の許容。**転写が期待より短いときだけ、期待文字列の先頭の文字が転写に無ければ許さない**
        // —— 短くなる形は左からの覆い(「About」→「bout」)で、1 文字の欠けとして通すと覆いを
        // 見逃す。**転写が期待と同じ長さ以上ならこの条件を課さない** —— 同じ長さでの先頭 1 文字の
        // 誤読(「iCloud」→「¡Cloud」)まで赤にしていた(覆いなら必ず短くなるので、同じ長さ以上は
        // 覆いではなく誤読)
        let tolerance = e.count / misreadDivisor
        let headOK = o.count >= e.count || (e.first.map { o.contains($0) } ?? false)
        if tolerance > 0, headOK,
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

    /// `judge` が退けた転写のうち、**誤読の可能性が残る**もの(1 文字、または len÷5 文字までの差。
    /// 先頭の文字・長さの条件は問わない)。呼び手はこのときだけ OCR に読ませ、期待文字列が丸ごと
    /// 読めれば見えている側へ倒す(OCR は素通りの根拠にしかしない = RegionText の規律)。
    /// 実測(E2E-RN M1Max): 入力欄の placeholder「単一行」を FM が簡体字で「单一行」と転写し、
    /// 3 文字で許容 0 → 誤った赤。旧字体「擴張」も同型。OCR はどちらも正しく読める
    public static func isNearMiss(transcript: String, expected: String) -> Bool {
        let o = RegionText.normalize(transcript)
        let e = RegionText.normalize(expected)
        guard !o.isEmpty, !e.isEmpty else { return false }
        return approximateSubstringDistance(haystack: o, needle: e) <= max(1, e.count / misreadDivisor)
    }

    /// `transcript` が `expected` の先頭(誤読 transcript.count ÷ misreadDivisor 文字まで)に当たるなら、
    /// 当たった先頭の長さ。許容が 0 文字(5 文字未満)なら厳密な先頭一致だけ = 呼び手の hasPrefix と同じなので nil
    static func approximatePrefixLength(of transcript: String, in expected: String) -> Int? {
        let o = Array(transcript), e = Array(expected)
        let tolerance = o.count / misreadDivisor
        let lower = max(1, o.count - tolerance), upper = min(e.count, o.count + tolerance)
        guard tolerance > 0, lower <= upper else { return nil }
        var best: (distance: Int, length: Int)?
        for length in lower...upper {
            let d = editDistance(o, Array(e[0..<length]))
            if d <= tolerance, d < (best?.distance ?? .max) { best = (d, length) }
        }
        return best?.length
    }

    static func editDistance(_ a: [Character], _ b: [Character]) -> Int {
        guard !a.isEmpty else { return b.count }
        guard !b.isEmpty else { return a.count }
        var previous = Array(0...b.count)
        for (i, ca) in a.enumerated() {
            var current = [i + 1]
            for (j, cb) in b.enumerated() {
                current.append(min(previous[j + 1] + 1, current[j] + 1, previous[j] + (ca == cb ? 0 : 1)))
            }
            previous = current
        }
        return previous[b.count]
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
