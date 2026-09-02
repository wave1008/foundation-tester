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
    /// value/placeholder: 同じ要素の入力値/プレースホルダ文字列(ElementInfo からそのまま)。
    /// **placeholder は値が入ると描画されなくなる** —— 期待文字列が placeholder と一致し、
    /// かつ非空の value がそれと異なる(=値で置き換わって隠れている)ときは対象外にする。
    /// value が空(placeholder が現に描画されている)のときはこの規則を当てない。
    /// web: ElementInfo.web(DOM から読んだ Web コンテンツか)。**DOM 経路の入力欄
    /// (textField/secureTextField/textView)は label を常に aria-label にする**
    /// (WebViewDOMSnapshot.swift の JS)。aria-label は画面には一切描画されない
    /// 支援技術専用の属性なので対象外にする。
    /// **ただし期待文字列(この関数の `label` 引数)が非空の value に含まれているときは除外しない**
    /// —— その形は呼び出し元(StepExecutor+Assert.swift の valueIs/valueContains 経路)が
    /// `element.value` 由来の期待文字列を渡しており、aria-label ではなく**現に画面へ描画されている
    /// 値そのもの**を検証している。ここまで除外すると「入力した値が実際に見えているか」の
    /// 正当な検証がガードごと消える。
    /// **Web の staticText 等はここで捕まえない** —— それらの label は実際に描画された本文
    /// (labelOf の textContent フォールバック)で、placeholder 規則とは別の経路を守っている。
    public static func eligible(type: String, label: String, isUserText: Bool = false,
                                 value: String?, placeholder: String?, web: Bool?) -> Verdict {
        // テキスト系の型のみ(Compose iOS/XCUITest とも本文テキストは "staticText")。
        // 型はホスト側で先頭小文字に正規化済み(ElementInfo.normalizedType)
        // image/button/cell/other 等はアイコン・画像でラベルが説明文になりがち。
        let textTypes = ["staticText", "text", "textView", "label", "searchField", "textField"]
        // 接尾辞照合は大小無視(`secureTextField` が `textField` を、ベンダ接頭辞付きの型が素の型を含む)
        let lowered = type.lowercased()
        guard textTypes.contains(where: { lowered == $0.lowercased() || lowered.hasSuffix($0.lowercased()) }) else {
            return Verdict(ok: false, reason: "non-text type: \(type)")
        }
        // Web(DOM)経路の入力欄は label が常に aria-label(WebViewDOMSnapshot.swift の
        // `role === "textField" || "secureTextField" || "textView"` 分岐)で、aria-label は
        // 画面に描画されない。**ただし期待文字列が非空の value に含まれているなら別**
        // (valueIs/valueContains 経路は element.value 由来の期待文字列を渡してくる = 現に
        // 描画されている値そのものを見ている。等号ではなく包含: valueContains は部分一致)。
        let webInputTypes: Set<String> = ["textfield", "securetextfield", "textview"]
        if web == true, webInputTypes.contains(lowered) {
            let renderedAsValue = value.map { !$0.isEmpty && $0.contains(label) } ?? false
            if !renderedAsValue {
                return Verdict(ok: false, reason: "web input label is aria-label (never rendered)")
            }
        }
        // 結合セマンティクス(コンテナが子を連結した label)。`, ` 区切りは複数要素の合成。
        // ユーザー期待値(textEquals)には当てない(正当な句読点を誤除外するため)。
        if !isUserText, label.contains(", ") {
            return Verdict(ok: false, reason: "merged label")
        }
        // 記号/絵文字のみ(判読すべき「文字」が無い)。文字=Unicode の letter か number を1つ以上要求。
        let hasWordChar = label.unicodeScalars.contains {
            CharacterSet.letters.contains($0) || CharacterSet.decimalDigits.contains($0)
        }
        if !hasWordChar {
            return Verdict(ok: false, reason: "no text (emoji/symbols)")
        }
        // 期待文字列が placeholder 由来で、値が入って隠れている(=画面には描画されていない)。
        // 値が空なら placeholder は現に描画されているのでこの規則は当てない。
        if let placeholder, placeholder == label, let value, !value.isEmpty, value != label {
            return Verdict(ok: false, reason: "placeholder hidden by value")
        }
        return Verdict(ok: true, reason: "")
    }
}
