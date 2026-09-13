// 空打ち(スクロール探索の終端で容器の1タッチを肩代わりする横抜けドラッグ)を撃つかの**第3段**。
// 1段目 = パッケージ(.app / .ipa)/ 2段目 = 台帳(AppFrameworkLedger)で UI フレームワークが判れば
// それに従う(StepExecutor.shouldEmptyDrag)。どちらも無い(材料の無い物理端末・他人のアプリ)ときだけ、
// **掴んだ要素のクラス名**(ElementInfo.axClass = XCTest の非公開属性 5004)で決める。
//
// 根拠(2026-09-12 実測・予備シミュレータ・XCUITest): Compose / Flutter の要素は `UIAccessibilityElement`
// (自前描画の上に置く a11y 要素 = ビューを持たず、タッチはホストのビューが自前で処理する = 次の1タッチを
// 吸う側)。React Native は `UIView`、SwiftUI は `NSObject`、UIKit は実クラス名で、どれも空打ちが要らない
// (RN は空打ちで行が押される側)。UIKit の実アプリにも `UIAccessibilityElement` は少数出る(地図 6/111・
// メッセージ 2/60)ので、判定はアプリ全体ではなく**掴んだ要素**で行う。
// **取れなければ不明 = 撃たない**(旧ランナー・in-app・Android・Xcode の版で属性が変わった場合)

import Foundation

public enum AccessibilityClassHint {
    /// Compose / Flutter が a11y 要素に使うクラス(ビューを持たない要素)
    public static let hostedElementClass = "UIAccessibilityElement"

    /// true = 自前描画のホストが触るべき要素(空打ちを撃つ)/ false = ビューを持つ要素(撃たない)/
    /// nil = クラス名が無い(不明。呼び手は撃たない側へ倒す)
    public static func hostsOwnTouches(_ element: ElementInfo) -> Bool? {
        guard let axClass = element.axClass, !axClass.isEmpty else { return nil }
        return axClass == hostedElementClass
    }
}
