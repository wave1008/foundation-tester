// 文字列を比較する前の正規化。**用途で規則が違う**ので1つの enum に閉じ込める。
//
// 用途は2つあり、求められるものが逆を向いている(2026-08-09 のユーザー決定):
//
//   セレクタでフィルタする … **見つけたい**。書き手が打った式と実データの些細な差で
//                             空振りしないよう、寛容に寄せる(両端トリム・空白の種類を吸収)
//   テキストを期待値と比較 … **確かめたい**。「見た目が完全に一致していれば同じ」が基準なので、
//                             見えない差だけを吸収し、**見える差は残す**(半角と全角は別物)
//
// **クラスタ内の制御文字は消さない**のが両者共通の要。ZWJ / 異体字セレクタ / 結合文字は
// 「不可視の制御文字」であると同時に**書記素クラスタを形成する**ので、落とすと
// 👨‍👩‍👦(1クラスタ)が 👨👩👦(3クラスタ)と等しくなり、❤️ が ❤ になる = 見た目が変わる。
// 実測でこの分類を確定させた(`"A" + 対象 + "B"` のクラスタ数):
//   クラスタ内(残す)… ZWNJ U+200C / ZWJ U+200D / CGJ U+034F / VS15,16 U+FE0E,FE0F / 結合文字
//   単独  (消す)… ZWSP U+200B / BOM U+FEFF / WJ U+2060 / SOFT HYPHEN U+00AD /
//                    LRM,RLM,LRE,PDF,LRI / ALM U+061C / MVS U+180E / C0,C1
//
// **列挙で持たない**: 判定は「そのクラスタが `Cf`(書式)と `Cc`(制御)だけで出来ているか」。
// 単独で立つ不可視文字はクラスタ全体が不可視になるので落ち、クラスタ内の制御文字は
// 可視の文字と同じクラスタに居るので残る。数え漏らした文字にも自動で効く。

import Foundation

/// 比較前の正規化規則。**どちらで比較したか**は失敗メッセージにも出す(読み手の次の一手が変わる)
public enum TextNormalization: String, Sendable, CaseIterable {

    /// セレクタのフィルタ用。両端をトリムし、空白は種類を問わず U+0020 へ寄せて連続を畳む
    case selector

    /// テキストと期待値の比較用(既定)。**見た目が同じものだけ**同一視する ——
    /// 不可視文字は落とすが、幅の違う空白(全角・thin space 等)は別物のまま
    case text

    /// 厳密比較。**一切正規化しない**。`strict: true` を明示したときだけ使う
    case strict

    /// 空白として U+0020 へ寄せる文字。**`text` では NBSP だけ** —— NBSP は半角空白と
    /// 同じ幅・同じ見た目で、違うのは改行の可否だけだから。全角(U+3000)や thin space
    /// (U+2009)・narrow NBSP(U+202F)は**幅が違う = 見た目が違う**ので寄せない。
    /// `selector` は「見つける」側なので空白の種類を問わず寄せる
    func foldsToSpace(_ scalar: Unicode.Scalar) -> Bool {
        switch self {
        case .strict:
            return false
        case .text:
            return scalar == "\u{00A0}"
        case .selector:
            // **列挙しない**: Unicode の White_Space 性質そのものを使う。タブ・改行・
            // 垂直タブ・改頁・NEL(U+0085)・全角・NBSP・U+2028/2029 が一度に入る。
            // ゼロ幅(U+200B 等)は White_Space ではないので、ここではなく削除規則の側で落ちる
            return scalar.properties.isWhitespace
        }
    }

    /// 結合子(ZWJ / ZWNJ)。**後ろに繋ぐ相手が居るときだけ意味を持つ**ので、クラスタの末尾に
    /// 余っているものは落とす。実データの根拠(Google マップの路線ラベル):
    /// `"…中央線\u{200D}\u{FEFF}\u{2060}"` の ZWJ は 線 と1クラスタになるが**繋ぐ相手が無く**、
    /// 見た目は `"中央線"` そのもの。残すと目視で同一の文字列が完全一致に失敗する。
    /// 一方 `"👨\u{200D}👩"` の ZWJ は2つの絵文字を繋いでおり、落とすと見た目が変わる。
    /// **異体字セレクタ(VS15/16)は末尾でも落とさない** —— あれは直前の文字の見え方を変えるので、
    /// 繋ぐ相手が要らない(❤ と ❤️ は別の見た目)
    private static let danglingJoiners: Set<Unicode.Scalar> = ["\u{200C}", "\u{200D}"]

    public func apply(_ s: String) -> String {
        guard self != .strict else { return s }
        var out = ""
        out.reserveCapacity(s.count)
        for cluster in s {
            // **空白は「不可視」ではない**(桁を食う = 見える)。タブ・改行は分類上 `Cc` なので、
            // 下の削除規則より**先に**寄せる —— 順序を逆にすると `"A\tB"` が `"AB"` になり、
            // 空白の正規化ではなく消去になってしまう(2026-08-09 にテストで検出)
            if cluster.unicodeScalars.count == 1,
               let only = cluster.unicodeScalars.first, foldsToSpace(only) {
                out.append(" ")
                continue
            }
            // **クラスタ丸ごと不可視なら落とす**(単独で立つ書式/制御文字)。
            // 可視の文字と同じクラスタに居る制御文字はここを通らないので残る。
            // 空白(White_Space)は上で扱い済み・寄せない modes では**残す**(見た目に効くため)
            if cluster.unicodeScalars.allSatisfy({
                let category = $0.properties.generalCategory
                return (category == .format || category == .control)
                    && !$0.properties.isWhitespace
            }) {
                continue
            }
            // 末尾に余った結合子だけを落とす(上のコメントの理由)
            var scalars = Array(cluster.unicodeScalars)
            while let last = scalars.last, Self.danglingJoiners.contains(last) {
                scalars.removeLast()
            }
            out.unicodeScalars.append(contentsOf: scalars)
        }
        guard self == .selector else { return out }
        // 連続空白は1つに畳み、両端はトリムする(セレクタだけ)
        return out.split(separator: " ", omittingEmptySubsequences: true)
            .joined(separator: " ")
    }
}
