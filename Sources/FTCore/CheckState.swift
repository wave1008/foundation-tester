// チェック状態(checkIsON / checkIsOFF / セレクタの `checked=`)の唯一の判定元。
// ワイヤの `checked` は true のときだけ送られる(省略 = オフ / 状態を持たない要素の区別が無い)ので、
// value に載っている状態を読んで「オフ」を確定させる。規則と実測(iOS 27・両エンジン同値):
//   - Flutter の Checkbox/Switch・SwiftUI Toggle・RN の role=switch・WebKit の checkbox: 型 switch + value "1"/"0"
//     (WebKit の mixed は "2")。Flutter の mixed は engine が "0" を返す = オフと区別できない
//   - RN の role=checkbox/radio: value "checkbox, checked" 等(OSS の RN は翻訳表が空 = 英語固定)
//   - Compose iOS: On のときだけ selected trait。Off/Indeterminate は何も出さない。Switch は型 switch で value 無し
//   - Android: checkable なノードにブリッジが value "1"/"0" を載せる(型は CheckBox/Switch/StaticText/Button …)
//   - DOM 経路(WebView): checkBox/switch の役割に value "1"/"0"/"2" を載せる(WebViewDOMSnapshot)

public enum CheckState: String, Sendable, Equatable {
    case on, off, mixed
    /// 状態を報告していない(状態を持たない要素か、状態を a11y に出さない実装)
    case unknown
}

public enum CheckStateReading {
    /// value "1"/"0"/"2" を状態として読む型(iOS)。**型で絞る** —— button のバッジ数 "1" 等を読まないため
    static let numericStateTypes: Set<String> = ["switch", "toggle", "checkBox", "radioButton"]
    /// 入力欄の value は利用者が打った文字列(Android の EditText も "1" になりうる)
    static let textEntryTypes: Set<String> = ["textField", "secureTextField", "textView", "searchField", "staticText"]

    public static func state(of element: ElementInfo, isAndroid: Bool) -> CheckState {
        state(checked: element.checked, type: element.type, value: element.value, isAndroid: isAndroid)
    }

    /// セレクタの `checked=` 用(プラットフォームを知らない経路)。オンの判定は OS に依らない ——
    /// Android の value "1" は isChecked 由来で、同じノードは必ず `checked == true` も持つ
    public static func onOrMixed(_ element: ElementInfo) -> CheckState? {
        switch state(of: element, isAndroid: false) {
        case .on: return .on
        case .mixed: return .mixed
        case .off, .unknown: return element.checked == true ? .on : nil
        }
    }

    public static func state(checked: Bool?, type: String, value: String?, isAndroid: Bool) -> CheckState {
        if let fromValue = numericState(type: type, value: value, isAndroid: isAndroid) {
            return fromValue
        }
        if checked == true { return .on }
        if checked == false { return .off }
        if let fromTokens = tokenState(type: type, value: value) { return fromTokens }
        // Compose iOS の Switch は value を出さず、On のときだけ selected。スイッチは必ず状態を持つので
        // 「型 switch・value 無し・selected 無し」はオフと読める(他の実装のスイッチは必ず value を出す)
        if !isAndroid, type == "switch", value == nil { return .off }
        return .unknown
    }

    private static func numericState(type: String, value: String?, isAndroid: Bool) -> CheckState? {
        guard let value else { return nil }
        // Android の value "1"/"0" はブリッジが checkable のノードにだけ載せる。StaticText
        // (CheckedTextView)にも載るが、入力欄の value は打った文字列なので除く
        let eligible = isAndroid
            ? !["textField", "secureTextField", "textView", "searchField"].contains(type)
            : numericStateTypes.contains(type)
        guard eligible else { return nil }
        switch value {
        case "1": return .on
        case "0": return .off
        case "2": return isAndroid ? nil : .mixed
        default: return nil
        }
    }

    /// RN の accessibilityValue はカンマ区切りの語の並び(役割・状態・busy・アプリの value)
    private static func tokenState(type: String, value: String?) -> CheckState? {
        guard let value, !textEntryTypes.contains(type) else { return nil }
        let tokens = Set(value.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) })
        if tokens.contains("mixed") { return .mixed }
        if tokens.contains("unchecked") { return .off }
        if tokens.contains("checked") { return .on }
        return nil
    }
}
