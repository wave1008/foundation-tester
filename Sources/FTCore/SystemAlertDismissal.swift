// iOS のシステム許可アラート(位置情報・通知など)を自動で押すときの「どれを押すか」。
//
// **ツールは推測しない**(2026-08-19)。位置情報の許可は「1回だけ許可 / Appの使用中は許可 /
// 許可しない」のように**どれが是認かが文脈で変わる**うえ、並び順もラベルもロケールと OS 版で
// 変わる。既定ボタンを当てにいくと、取り違えたときの症状が「テストが意図しない権限状態で
// 走り続ける」= 沈黙になる。だから押してよいラベルは**実行プロファイルに書かれた分だけ**
// とし、書かれていなければ何もしない(従来どおりシナリオが自分で閉じる)。
//
// 「自動許可」も「自動拒否」もこの1つの仕組みで書ける ——
// 並べるラベルを是認側にするか拒否側にするかの違いしかない。

import Foundation

public enum SystemAlertDismissal {
    /// fallback(SpringBoard 参照セッション)の木から押すべきボタンを1つ選ぶ。
    /// labels は実行プロファイルに書かれた順で、**先に見つかったものを採る**
    /// (「Appの使用中は許可」を「許可」より前に置けば、両方あるときは前者が選ばれる)。
    ///
    /// **完全一致だけ**。部分一致にすると `"許可"` の指定が **"許可しない" を押す** ——
    /// 自動化が正反対の権限を与える形の事故になり、しかも run は緑のまま進む。
    ///
    /// 型は `button` に限る。別の型で出るアラートでは**発火しない**が、
    /// 縮退の向きはそれでよい(押さなければ従来どおりシナリオが失敗して気付ける。
    /// 押し間違えると気付けない)。
    public static func buttonToTap(in elements: [ElementInfo], labels: [String]) -> ElementInfo? {
        guard !labels.isEmpty else { return nil }
        let candidates = elements.filter { $0.enabled && $0.type == "button" }
        for label in labels {
            let wanted = label.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !wanted.isEmpty else { continue }
            if let hit = candidates.first(where: { $0.label == wanted }) { return hit }
        }
        return nil
    }
}
