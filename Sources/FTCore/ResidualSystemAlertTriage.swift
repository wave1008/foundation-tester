// run 開始時点で**既に画面に居るアラート**の検知(純粋ロジックだけ)。
//
// なぜ要るか(2026-08-19 の受け手報告): iOS の許可アラートは SpringBoard が別プロセスで描くので、
// **対象アプリを terminate しても、アンインストールしても画面に残る**。残ったまま次の run が
// 始まると全ステップが空振りし、症状は「アプリが壊れている」ようにしか見えない
// (アプリの a11y ツリーには他プロセスの window が出ないので、要素一覧でも気付けない)。
//
// **警告だけ。自動では閉じない**(新しい検知は警告から始める)。閉じたいなら実行プロファイルの
// `iosAlertHandler` を登録する —— そちらは「押してよいボタン」を利用者が明示する仕組み。

import Foundation

public enum ResidualSystemAlertTriage {
    /// アラートが居れば、人が読んで次の手を決められる説明を返す(nil = 居ない)。
    /// 判定は `type == "alert"` の1点だけ(同定条件は OpenURLConsent と同じ出典)。
    /// ボタンはアラートの子孫(depth がアラートより深い連続範囲)から拾う —— どれを押せば
    /// よいかは人が決めるので、**候補を全部見せる**
    public static func describe(elements: [ElementInfo]) -> String? {
        for (index, element) in elements.enumerated() where element.type == "alert" {
            var buttons: [String] = []
            for candidate in elements[(index + 1)...] {
                guard candidate.depth > element.depth else { break }
                if candidate.type == "button", let label = candidate.label, !label.isEmpty {
                    buttons.append(label)
                }
            }
            let title = element.label.map { $0.isEmpty ? "(no title)" : $0 } ?? "(no title)"
            let choices = buttons.isEmpty ? "" : " [buttons: \(buttons.joined(separator: " / "))]"
            return "\(title)\(choices)"
        }
        return nil
    }
}
