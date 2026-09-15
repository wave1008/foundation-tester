// ロケータの指紋による決定的なドリフト解決。
//
// **効くのはプライマリ・フォールバック・ヒールキャッシュのいずれも解決できなかった失敗経路だけ**
// (StepExecutor+Actions.swift の解決分岐で FM ヒールより前・matchCached より後ろに置く)。
// 成功経路の解決順(プライマリ → フォールバック → キャッシュ)には一切触れないので、
// このリスクは構造的にこの1箇所に閉じる。今緑のステップの挙動は変わらない。
//
// 控える属性は type + label(+ 非nilのときだけ placeholder)。**id は控えない** —— ドリフトで
// 変わるのがまさに id なので照合の材料にならない。**value も控えない** —— 入力値は実行ごとに変わる。
//
// 一致件数が**ちょうど1件のときだけ**採用する。スコア・編集距離・重み付けは作らない
// (「根拠のない定数を置かない」方針)。0件・複数件一致は不採用のまま従来の経路(FM ヒール)へ委ねる
// —— 複数件を「もっとも近い」で選ぶと別要素へ静かに解決し、後段の検証が別要素を見て
// 誤った緑・誤った赤を作る。
public struct LocatorFingerprint: Codable, Equatable, Sendable {
    public let type: String
    public let label: String?
    public let placeholder: String?

    public init(type: String, label: String?, placeholder: String?) {
        self.type = type
        self.label = label
        self.placeholder = placeholder
    }

    /// 解決に成功した要素から指紋を採る。**呼び出し側はプライマリ/フォールバックで
    /// 素直に解決できた回だけ呼ぶこと** —— 指紋やヒールで解決した要素から採ると、
    /// 誤った解決が指紋として固定化され、以後ずっと同じ誤りを再生産する
    public init(of element: ElementInfo) {
        self.init(type: element.type, label: element.label, placeholder: element.placeholder)
    }

    /// label か placeholder の少なくとも片方が空白以外の文字を持つ。**型だけの指紋は要素を名指し
    /// していない** —— `nil == nil` で一致するので、ラベル無しのアイコンボタンが消える回帰でも、
    /// 画面に残った別のラベル無しボタンが「ちょうど1件」になれば叩いて緑にしてしまう。記録も照合もしない
    public var isIdentifying: Bool {
        func hasText(_ s: String?) -> Bool {
            !(s ?? "").trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        }
        return hasText(label) || hasText(placeholder)
    }

    /// 現在の木から、控えた全属性に一致する要素を探す。**ちょうど1件のときだけ**返す
    /// (0件・複数件は nil = 不採用。`isIdentifying` でない指紋も nil —— 古い版が書いた控えを含む)
    public func resolve(in elements: [ElementInfo]) -> ElementInfo? {
        guard isIdentifying else { return nil }
        let matches = elements.filter {
            $0.type == type && $0.label == label
                && (placeholder == nil || $0.placeholder == placeholder)
        }
        return matches.count == 1 ? matches[0] : nil
    }
}
