import SwiftUI

/// A4: `.swipeActions`(trailing は full swipe が先頭のボタン = 削除に当たる順)+ leading のピン留め。
/// 返信行は DragGesture の自前実装(行は元の位置へ戻る)。
struct SwipeActionsScreen: View {
    @State private var rows = Array(1...6)
    @State private var result = "action=none"
    @State private var reply = "reply=none"

    var body: some View {
        VStack(spacing: 0) {
            EchoArea {
                TaggedText(tag: "txt_swipe_actions_result", text: result)
                TaggedText(tag: "txt_swipe_actions_count", text: "rows=\(rows.count)")
                TaggedText(tag: "txt_reply_target", text: reply)
            }
            List {
                Section {
                    ForEach(rows, id: \.self) { n in
                        Button { result = "action=row\(n):open" } label: {
                            Text("スワイプ行 \(n)").frame(maxWidth: .infinity, minHeight: 44, alignment: .leading)
                                .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .accessibilityIdentifier("sw_row_\(n)")
                        .swipeActions(edge: .trailing, allowsFullSwipe: true) {
                            Button("削除", role: .destructive) {
                                rows.removeAll { $0 == n }
                                result = "action=row\(n):delete"
                            }
                            .accessibilityIdentifier("btn_sw_delete_\(n)")
                            Button("アーカイブ") { result = "action=row\(n):archive" }
                                .tint(.orange)
                                .accessibilityIdentifier("btn_sw_archive_\(n)")
                        }
                        .swipeActions(edge: .leading, allowsFullSwipe: false) {
                            Button("ピン留め") { result = "action=row\(n):pin" }
                                .tint(.blue)
                                .accessibilityIdentifier("btn_sw_pin_\(n)")
                        }
                    }
                }
                Section {
                    ForEach(1...3, id: \.self) { n in
                        ReplyRow(n: n) { reply = "reply=reply_row_\($0)" }
                    }
                }
            }
        }
        .screenTitleTag("スワイプの操作")
        .background(ContentPopGestureDisabler())
    }
}

private struct ReplyRow: View {
    let n: Int
    let onReply: (Int) -> Void
    @State private var dx: CGFloat = 0

    var body: some View {
        GeometryReader { geo in
            Text("返信行 \(n)")
                .frame(maxWidth: .infinity, minHeight: 44, alignment: .leading)
                .offset(x: dx)
                .contentShape(Rectangle())
                .simultaneousGesture(
                    DragGesture(minimumDistance: 12)
                        .onChanged { v in
                            guard abs(v.translation.width) > abs(v.translation.height) else { return }
                            dx = min(max(0, v.translation.width), 80)
                        }
                        .onEnded { v in
                            if v.translation.width > geo.size.width * 0.25 { onReply(n) }
                            withAnimation { dx = 0 }
                        }
                )
        }
        .frame(height: 44)
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier("reply_row_\(n)")
    }
}
