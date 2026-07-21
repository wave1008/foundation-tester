// [PoC occlusion-guard] FM 視覚照合に回してよい要素かの足切り(ツリーのみ・安価)。
// 実機計測(2026-07-21 sut-ec-mobile)で、a11y label が実描画と一致しない要素
// (アイコン/画像=label は説明文、絵文字単体、結合セマンティクス=label に `, ` 区切り)に
// FM を当てると約50%が誤反転すると判明。これらを FM 前に除外し、
// 「label が verbatim にテキスト描画される要素」だけを対象にする。省略(…)は verifier 側で許容する。

import Foundation

public enum OcclusionEligibility {
    public struct Verdict { public let ok: Bool; public let reason: String }

    /// FM occlusion 照合の対象にしてよいか。ok=false の要素はガードを素通り(従来どおり pass)。
    /// isUserText: label が textEquals/valueEquals の**ユーザー期待値**(リテラル)か。true のときは
    /// 結合セマンティクスの `, ` 規則を当てない(ユーザーが句読点入りテキストを意図的に検証し得るため。
    /// この規則は exist の実 a11y label=結合コンテナ検出のためのもの)。
    public static func eligible(type: String, label: String, isUserText: Bool = false) -> Verdict {
        // テキスト系の型のみ(Compose iOS/XCUITest とも本文テキストは "StaticText")。
        // Image/Button/Cell/Other 等はアイコン・画像でラベルが説明文になりがち。
        let textTypes = ["StaticText", "Text", "TextView", "Label", "SearchField", "TextField"]
        guard textTypes.contains(where: { type == $0 || type.hasSuffix($0) }) else {
            return Verdict(ok: false, reason: "非テキスト型:\(type)")
        }
        // 結合セマンティクス(コンテナが子を連結した label)。`, ` 区切りは複数要素の合成。
        // ユーザー期待値(textEquals)には当てない(正当な句読点を誤除外するため)。
        if !isUserText, label.contains(", ") {
            return Verdict(ok: false, reason: "結合label")
        }
        // 記号/絵文字のみ(判読すべき「文字」が無い)。文字=Unicode の letter か number を1つ以上要求。
        let hasWordChar = label.unicodeScalars.contains {
            CharacterSet.letters.contains($0) || CharacterSet.decimalDigits.contains($0)
        }
        if !hasWordChar {
            return Verdict(ok: false, reason: "文字なし(絵文字/記号)")
        }
        return Verdict(ok: true, reason: "")
    }
}
