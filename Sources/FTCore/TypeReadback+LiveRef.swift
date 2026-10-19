// TypeReadback.value(of:in:) が読む要素そのもの(ホスト側だけで使う)。**TypeReadback.swift はブリッジの入力**
// (BridgeSourceSet・ランナーと in-app が共有)なので、ホストだけの関数はこのファイルに置く(触ると版上げが要る)。
// 突き合わせの規則は value(of:in:) と同じでなければならない(TypeReadbackLiveRefTests が等価を固定する)

import Foundation

extension TypeReadback {
    /// 撮り直した木の中の同じ欄(identifier が空でなければ identifier、無ければ frame で1つに決まるときだけ)。
    /// **撮り直した後に撃つ ref はこれの ref**(ブリッジは撮るたびに ref の表を作り直す)
    public static func match(of target: ElementInfo, in elements: [ElementInfo]) -> ElementInfo? {
        let matches = elements.filter { element in
            if let identifier = target.identifier, !identifier.isEmpty {
                return element.identifier == identifier
            }
            return element.frame == target.frame
        }
        return matches.count == 1 ? matches.first : nil
    }
}
