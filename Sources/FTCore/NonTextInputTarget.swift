// type/clearInput の XCUITest への撃ち直しを止める門。**TypeReadback.swift はブリッジのソース集合に入るので、
// ホストでしか使わないこの判定はそちらに置かない**(置くとブリッジの指紋が変わり版上げを強いる)

extension TypeReadback {
    /// **型名だけで「入力欄では絶対にない」と言える型の集合**(ネイティブウィジェット由来でしか
    /// 出ない型だけを入れる)。`cell` / `clickable` / `other` / `staticText` は含めない ——
    /// これらは「役割が確定しない」受け皿(Android の `SnapshotBuilder.mappedType` が
    /// clickable 容器・className 不明のノードに割り当てる/XCUITest の `.cell` も同じ語彙 "Clickable" に
    /// 畳む)で、**自前描画(Compose/Flutter)の本物の入力欄がここへ誤って落ちる実測がある**
    /// (`TapTargetGeometry.nonInputTypeTargetNote` の doc)。
    public static let positivelyNonTextInputTypes: Set<String> = [
        "button", "switch", "toggle", "link", "slider", "stepper", "segmentedControl",
        "checkBox", "menuItem",
    ]

    /// 対象へ「打ち直し」(type/clearInput の XCUITest フォールバック)を撃ってよいか判断する前段の
    /// 門。**in-app が撃った合成タップの後に XCUITest がもう一度タップすると、対象がボタン等なら
    /// 2 回押す**(送信・購入の二重実行になりうる)。撃ち直さなくても入力欄でない対象への
    /// type/clearInput はどちらのエンジンでも成功しようがないので、回さなくても失うものが無い。
    ///
    /// **selfRendered が false と確定しているときだけ**型名を信じる(nil = 不明も含めて false 以外は
    /// 常に false を返す = 撃ち直しを許す側に倒す)。自前描画(Compose/Flutter)では上の集合の型名が
    /// 誤って本物の入力欄に付くことがあるため、型名だけでは判定できない
    public static func isPositivelyNonTextInput(_ element: ElementInfo, selfRendered: Bool?) -> Bool {
        guard selfRendered == false else { return false }
        return positivelyNonTextInputTypes.contains(element.type)
    }
}
