// ScrollActionAvailability.swift
// scrollToEdge が「もう動かせない」と分かっている向きへ、確かめのためだけに1本送るのを避けるための
// 純粋判定。Android は ElementInfo.scrollActions(AX の action 一覧)で申告するが、iOS の2ブリッジは
// 申告しない(nil)ので、その回は今までどおり実際に撃って確かめる(見逃しはあっても誤検知は作らない側)。

import Foundation

public enum ScrollActionAvailability {

    /// `finger`(指の動き。`step.direction` と同じ語彙)へこれから送ろうとしている swipe が、
    /// 容器の申告からして**既に効果が無い**と分かっているか。
    /// **scrollActions が nil なら常に false**(未申告 = 分からない。実際に撃って確かめる)。
    public static func atEdge(scrollActions: [String]?, forSwipe finger: FTSwipeDirection) -> Bool {
        guard let scrollActions else { return false }
        let needed = requiredActionNames(forSwipe: finger)
        return !needed.contains { scrollActions.contains($0) }
    }

    /// finger 方向へ中身を動かすために容器が持っていてほしいアクション名。
    /// **finger は指の動きで、中身はその逆へ動く**(`FTScrollDirection.swipe` の逆写像を
    /// ここへ書き足さない —— 指を下へ払う(finger=.down)と中身は先頭側(backward/up)へ寄る)
    private static func requiredActionNames(forSwipe finger: FTSwipeDirection) -> Set<String> {
        switch finger {
        case .down: return ["backward", "up"]
        case .up: return ["forward", "down"]
        case .right: return ["backward", "left"]
        case .left: return ["forward", "right"]
        }
    }
}
