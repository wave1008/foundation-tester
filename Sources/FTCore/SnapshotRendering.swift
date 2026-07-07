// SnapshotRendering.swift
// スナップショットを FM 向けの set-of-mark 圧縮テキストに描画する。
// 目標: 一般的な画面で 300〜800 トークンに収める(1要素1行)。

import Foundation

public enum SnapshotRenderer {

    /// `[3] Button "ログイン" id=login_btn (120,610 180x44)` 形式の1行を要素ごとに出力する。
    public static func render(_ snapshot: SnapshotResponse) -> String {
        var lines: [String] = []
        let s = snapshot.screen
        lines.append("screen: \(Int(s.width))x\(Int(s.height))")
        for e in snapshot.elements {
            lines.append(renderElement(e))
        }
        if snapshot.truncatedCount > 0 {
            lines.append("(+\(snapshot.truncatedCount) elements truncated)")
        }
        return lines.joined(separator: "\n")
    }

    static func renderElement(_ e: ElementInfo) -> String {
        var parts: [String] = ["[\(e.ref)]", e.type]
        if let label = e.label, !label.isEmpty {
            parts.append("\"\(truncate(label, 40))\"")
        }
        if let id = e.identifier, !id.isEmpty {
            parts.append("id=\(id)")
        }
        if let value = e.value, !value.isEmpty {
            parts.append("value=\"\(truncate(value, 30))\"")
        }
        if let ph = e.placeholder, !ph.isEmpty, ph != e.label {
            parts.append("ph=\"\(truncate(ph, 30))\"")
        }
        // 空の入力欄はモデルに明示する(「入力済みと思い込んで送信」対策)
        if Self.textInputTypes.contains(e.type), e.value == nil {
            parts.append("未入力")
        }
        if !e.enabled {
            parts.append("disabled")
        }
        let f = e.frame
        parts.append("(\(Int(f.x)),\(Int(f.y)) \(Int(f.width))x\(Int(f.height)))")
        return parts.joined(separator: " ")
    }

    static func truncate(_ s: String, _ max: Int) -> String {
        s.count <= max ? s : String(s.prefix(max)) + "…"
    }

    public static let textInputTypes: Set<String> = [
        "TextField", "SecureTextField", "TextView", "SearchField",
    ]
}
