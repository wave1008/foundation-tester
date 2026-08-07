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
            parts.append("\"\(truncate(label, labelDisplayLimit))\"")
        }
        if let id = e.identifier, !id.isEmpty {
            let suffix = idCount.map { " ×\($0)" } ?? ""
            parts.append("id=\(id)\(suffix)")
        }
        let value = e.value.map(FlowMatchMode.stripZeroWidthCharacters)
        if let value, !value.isEmpty {
            parts.append("value=\"\(truncate(value, valueDisplayLimit))\"")
        }
        let placeholder = e.placeholder.map(FlowMatchMode.stripZeroWidthCharacters)
        if let placeholder, !placeholder.isEmpty, placeholder != label {
            parts.append("ph=\"\(truncate(placeholder, valueDisplayLimit))\"")
        }
        // 取り得る範囲(スライダー・プログレス)。**値だけでは意味が決まらない** ——
        // `value="3"` が 0..10 の3なのか 0..100 の3なのかで読み方が変わる
        if let range = e.range, !range.isEmpty {
            parts.append("range=\(range)")
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

    public static func truncate(_ s: String, _ max: Int) -> String {
        s.count <= max ? s : String(s.prefix(max)) + "…"
    }

    /// 描画で切り詰める上限。**セレクタに使えるかを決める値**なので注記側と共有する
    /// (片方だけ変えると「切り詰めた」と言いながら実は完全な文字列、が起きる)
    public static let labelDisplayLimit = 40
    public static let valueDisplayLimit = 30

    /// 切り詰めたラベルがあるときだけ出す注記。**印字された文字列は完全一致では当たらない** ——
    /// 読み手は木に出ている文字列をそのままセレクタへ写すので、これが無いと
    /// 「木に居るのに waitFor が当たらない」= 照合のバグに見える(2026-08-07 に実アプリで実測。
    /// Google マップの1画面に40字超が3件あり、そのまま渡した waitFor が外れた)。
    /// 例に出す前方一致は**実際に当たる形**を組む(切り詰めた文字列の `…` を落とすだけでは
    /// 末尾が語の途中で切れていても当たるので、そのまま `*…*` で包める)
    public static func truncatedLabelNote(_ snapshot: SnapshotResponse) -> String? {
        let longest = snapshot.elements
            .compactMap { $0.label.map(FlowMatchMode.stripZeroWidthCharacters) }
            .filter { $0.count > labelDisplayLimit }
            .max(by: { $0.count < $1.count })
        guard let longest else { return nil }
        let example = String(longest.prefix(min(12, labelDisplayLimit)))
        return "note: labels longer than \(labelDisplayLimit) characters are shown cut off with"
            + " \"…\" — that \"…\" is display only, so copying the printed text into a selector"
            + " will never match. Use a prefix partial match instead (e.g. *\(example)*).\n"
    }

    /// 渡されたセレクタが**この画面のどれかのラベルの切り詰め表示**そのものか。
    /// `waitFor`/`scrollTo` が外れた理由がこれなら、綴りでも待ち時間でもないと名指しできる
    public static func truncatedSelectorHint(_ selectorText: String,
                                             in snapshot: SnapshotResponse) -> String? {
        let bare = selectorText.trimmingCharacters(in: CharacterSet(charactersIn: "*"))
        guard bare.hasSuffix("…") else { return nil }
        let prefix = String(bare.dropLast())
        guard !prefix.isEmpty else { return nil }
        let full = snapshot.elements
            .compactMap { $0.label.map(FlowMatchMode.stripZeroWidthCharacters) }
            .first { $0.hasPrefix(prefix) && $0.count > prefix.count }
        guard full != nil else { return nil }
        let example = String(prefix.prefix(min(12, prefix.count)))
        return " The text you passed ends with \"…\", which is how a label longer than"
            + " \(labelDisplayLimit) characters is *displayed* — it is not part of the label,"
            + " so an exact match cannot succeed. Use a prefix instead (e.g. *\(example)*)."
    }

    public static let textInputTypes: Set<String> = [
        "textField", "secureTextField", "textView", "searchField",
    ]
}
