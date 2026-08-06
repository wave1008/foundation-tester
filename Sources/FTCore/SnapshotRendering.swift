// SnapshotRendering.swift
// スナップショットを FM 向けの set-of-mark 圧縮テキストに描画する。
// 目標: 一般的な画面で 300〜800 トークンに収める(1要素1行)。

import Foundation

public enum SnapshotRenderer {

    /// `[3] Button "ログイン" id=login_btn (120,610 180x44)` 形式の1行を要素ごとに出力する。
    ///
    /// `flagging` に入れた ref の行末には印を付ける(既定は空 = 従来どおり)。MCP が
    /// スクロール残像を名指しするのに使う —— **先頭の注記だけでは足りない**という
    /// 外部フィードバック(2026-08-06)への対応で、ref をコピーする行そのものに出す。
    public static func render(_ snapshot: SnapshotResponse,
                              flagging: [Int: String] = [:]) -> String {
        var lines: [String] = []
        let s = snapshot.screen
        lines.append("screen: \(Int(s.width))x\(Int(s.height))")
        // 同じ id が2つ以上ある要素は、生成側へ「単独では曖昧」と伝えるため件数を付す
        var idCounts: [String: Int] = [:]
        for e in snapshot.elements {
            if let id = e.identifier, !id.isEmpty {
                idCounts[id, default: 0] += 1
            }
        }
        for e in snapshot.elements {
            let flag = flagging[e.ref].map { " \($0)" } ?? ""
            let idCount = e.identifier.flatMap { idCounts[$0] }.flatMap { $0 >= 2 ? $0 : nil }
            lines.append(renderElement(e, idCount: idCount) + flag)
        }
        if snapshot.truncatedCount > 0 {
            lines.append("(+\(snapshot.truncatedCount) elements truncated)")
        }
        return lines.joined(separator: "\n")
    }

    static func renderElement(_ e: ElementInfo, idCount: Int? = nil) -> String {
        var parts: [String] = ["[\(e.ref)]", e.type]
        // ゼロ幅文字は画面にもスナップショットにも見えないので truncate の前に除去する
        // (除去してからコピーした文字列は FlowMatchMode.matches の正規化と必ず一致する)
        let label = e.label.map(FlowMatchMode.stripZeroWidthCharacters)
        if let label, !label.isEmpty {
            parts.append("\"\(truncate(label, 40))\"")
        }
        if let id = e.identifier, !id.isEmpty {
            let suffix = idCount.map { " ×\($0)" } ?? ""
            parts.append("id=\(id)\(suffix)")
        }
        let value = e.value.map(FlowMatchMode.stripZeroWidthCharacters)
        if let value, !value.isEmpty {
            parts.append("value=\"\(truncate(value, 30))\"")
        }
        let placeholder = e.placeholder.map(FlowMatchMode.stripZeroWidthCharacters)
        if let placeholder, !placeholder.isEmpty, placeholder != label {
            parts.append("ph=\"\(truncate(placeholder, 30))\"")
        }
        // 空の入力欄はモデルに明示する(「入力済みと思い込んで送信」対策)。
        // label があるのに empty と出す自己矛盾を避けるため、label も無いときだけ出す
        if Self.textInputTypes.contains(e.type), e.value == nil, label == nil || label!.isEmpty {
            parts.append("empty")
        }
        if !e.enabled {
            parts.append("disabled")
        }
        // 選択・チェック状態(iOS の isSelected / Android の isChecked||isSelected)。
        // **true のときだけ**出す = 「印が無い」は「オフ」と「状態を持たない」の両方を含む
        // (checkIsOFF が状態を持たない要素でも通る既定と同じ意味論。StepExecutor+Assert 参照)。
        // これが無いと、タブの選択状態は checkIsON では表明できるのに ft_snapshot からは見えない
        if e.checked == true {
            parts.append("checked")
        }
        // `scrollFrame:` に指定できる容器の印。**true のときだけ**出す(申告できないエンジンが
        // あるので「印が無い = スクロールしない」ではない。ElementInfo.scrollable 参照)
        if e.scrollable == true {
            parts.append("scroll")
        }
        let f = e.frame
        parts.append("(\(Int(f.x)),\(Int(f.y)) \(Int(f.width))x\(Int(f.height)))")
        return parts.joined(separator: " ")
    }

    static func truncate(_ s: String, _ max: Int) -> String {
        s.count <= max ? s : String(s.prefix(max)) + "…"
    }

    public static let textInputTypes: Set<String> = [
        "textField", "secureTextField", "textView", "searchField",
    ]
}
