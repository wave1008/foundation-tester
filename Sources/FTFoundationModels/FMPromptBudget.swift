// FM へ渡す木の文字数の上限。
//
// **モデルの文脈長は 4,096 トークンで、超えると呼び出しごと失敗する**
// (2026-09-03 実測: `Content contains 7957 tokens, which exceeds the maximum allowed
// context size of 4096`)。heal も triage も**失敗は nil = 黙って素通り**なので、
// 密な画面では「自己修復もトリアージも一度も効かない」が無警告で起きる。
// 自前 SUT の画面は小さく1度も踏まなかったが、実アプリのスナップショット
// (`Tests/Fixtures/RealAppSnapshots`)では 234 行 / 11,771 文字の木が実際に溢れた。
//
// **文字数で持つ理由**: トークン数はここでは数えられない(モデル側の tokenizer)。
// 実測の比は **1.40〜1.48 文字/トークン**(日本語のラベルが多い実アプリの木)。
// 木に 2,600 トークンを割り当てると 3,600 文字 ≈ 2,430〜2,570 トークンで収まり、
// instructions・失敗の記述・スキーマ・出力(250〜300 トークン)に十分な余りが残る。
// **英語だけの木ではもっと余る**(1文字あたりのトークンが少ない)ので、この見積もりは安全側。
//
// **切るのは溢れるときだけ**。budget 以内の木は1バイトも変えない —— 木を削ると分類が変わる
// ことが実測で分かっている(40 行に切り詰めた triage は 36 件中 11 件で failureClass が変わり、
// `locatorDrift` は 7 件 → 0 件になった。docs/performance-tuning.md §3.5.1)。
// 溢れる画面では今日どのみち**判定が1つも返っていない**ので、切ってでも答えを得るほうがよい。

import Foundation

enum FMPromptBudget {

    /// 木に割ける文字数。根拠と単位はファイル冒頭
    static let treeCharacterBudget = 3_600

    /// 溢れるときだけ切り詰める。切ったときは**切ったと明示する**
    /// (黙って減らすと、モデルは「画面にその要素は無い」と読んでしまう)
    static func fit(_ rendered: String, budget: Int = treeCharacterBudget) -> String {
        guard rendered.count > budget else { return rendered }
        let lines = rendered.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
        guard let header = lines.first else { return rendered }
        // 意味を運ぶ行(ラベルか id を持つ)を優先して残す。**木の順序は変えない**
        let body = lines.dropFirst()
        let meaningful = body.filter { $0.contains("\"") || $0.contains("id=") }
        var kept: [String] = []
        var used = header.count
        for line in meaningful {
            let cost = line.count + 1
            if used + cost > budget { break }
            kept.append(line)
            used += cost
        }
        let dropped = body.count - kept.count
        return ([header] + kept
                + ["(\(dropped) more line(s) omitted — the element list was truncated to fit the"
                   + " model's context, so absence here does not mean the element is missing)"])
            .joined(separator: "\n")
    }
}
