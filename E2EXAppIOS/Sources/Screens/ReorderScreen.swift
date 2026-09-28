import SwiftUI

/// 常時編集モード(`.environment(\.editMode, .constant(.active))`)でハンドルを常に出す
/// (iOS の定番: 右端のハンドルを掴んでドラッグする形。EditButton による切替は使わない)。
struct ReorderScreen: View {
    @State private var order = Array(1...5)

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            TaggedText(tag: Tags.txtReorderResult, text: "order=" + order.map(String.init).joined(separator: ","))
                .padding([.horizontal, .top], 16)
            List {
                ForEach(order, id: \.self) { n in
                    Text("並べ替え \(n)")
                        .accessibilityIdentifier(Tags.reorderRow(n))
                }
                .onMove { indices, newOffset in
                    order.move(fromOffsets: indices, toOffset: newOffset)
                }
            }
            .environment(\.editMode, .constant(.active))
        }
        .screenTitleTag("並べ替え")
    }
}
