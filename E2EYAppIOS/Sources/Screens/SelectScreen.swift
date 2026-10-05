import SwiftUI

/// A5: `List(selection:)` + EditMode。`#btn_edit` は自前の Button で editMode を切り替える。
/// 通常モードの「開く」と長押しは editMode が非活性の枝だけに付ける(活性の枝に付けると List の選択タップと競合する)。
/// 長押しは Button に onLongPressGesture を付けても Button の押下に負けるので simultaneousGesture。
struct SelectScreen: View {
    @State private var rows = Array(1...20)
    @State private var selection = Set<Int>()
    @State private var editMode = EditMode.inactive
    @State private var result = "select=none"
    /// 長押しで選択モードへ入った指の離しが Button の押下として届くので、その1回の「開く」を捨てる。leave() でも解く(離しが届かない場合)。
    @State private var longPressed = false

    private var selecting: Bool { editMode == .active }

    var body: some View {
        VStack(spacing: 0) {
            EchoArea {
                TaggedText(tag: "txt_select_mode", text: "mode=\(selecting ? "select" : "normal")")
                TaggedText(tag: "txt_select_count", text: "selected=\(selection.count)")
                TaggedText(tag: "txt_select_result", text: result)
            }
            bar
            List(selection: $selection) {
                ForEach(rows, id: \.self) { n in
                    row(n)
                }
            }
            .listStyle(.plain)
            .environment(\.editMode, $editMode)
        }
        .screenTitleTag("選択モード")
    }

    @ViewBuilder
    private func row(_ n: Int) -> some View {
        let name = "sel_row_\(Tags.two(n))"
        if selecting {
            Text("項目 \(Tags.two(n))")
                .frame(maxWidth: .infinity, minHeight: 44, alignment: .leading)
                .accessibilityIdentifier(name)
        } else {
            Button {
                if longPressed { longPressed = false; return }
                result = "select=open:\(name)"
            } label: {
                Text("項目 \(Tags.two(n))")
                    .frame(maxWidth: .infinity, minHeight: 44, alignment: .leading)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .simultaneousGesture(
                LongPressGesture().onEnded { _ in
                    longPressed = true
                    selection = [n]
                    editMode = .active
                }
            )
            .accessibilityIdentifier(name)
        }
    }

    private var bar: some View {
        HStack {
            if selecting {
                Button { leave() } label: { Image(systemName: "xmark") }
                    .accessibilityLabel("キャンセル")
                    .accessibilityIdentifier("btn_sel_cancel")
                Button("すべて選択") { selection = Set(rows) }.accessibilityIdentifier("btn_sel_all")
                Button("削除") { deleteSelected() }.accessibilityIdentifier("btn_sel_delete")
            } else {
                Text("項目")
            }
            Spacer()
            Button(selecting ? "完了" : "編集") {
                if selecting { leave() } else { editMode = .active }
            }
            .accessibilityIdentifier("btn_edit")
        }
        .padding(.horizontal, 16)
        .frame(height: 44)
        .background(Color(.secondarySystemBackground))
    }

    private func leave() {
        longPressed = false
        selection = []
        editMode = .inactive
    }

    private func deleteSelected() {
        let ids = selection.sorted().map(Tags.two).joined(separator: ",")
        rows.removeAll { selection.contains($0) }
        result = "select=deleted:\(ids)"
        leave()
    }
}
