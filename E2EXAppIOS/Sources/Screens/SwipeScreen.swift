import SwiftUI

struct SwipeScreen: View {
    @State private var rows = Array(1...5)
    @State private var lastRemoved = "removed=none"

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            TaggedText(tag: Tags.txtSwipeResult, text: lastRemoved)
                .padding([.horizontal, .top], 16)
            TaggedText(tag: Tags.txtSwipeCount, text: "rows=\(rows.count)")
                .padding(.horizontal, 16)
            List {
                ForEach(rows, id: \.self) { n in
                    Text("スワイプ行 \(n)")
                        .accessibilityIdentifier(Tags.swipeRow(n))
                        // leading 側は何も登録しない = 左から右のスワイプは無効(契約どおり)
                        .swipeActions(edge: .trailing, allowsFullSwipe: true) {
                            Button("削除", role: .destructive) { remove(n) }
                        }
                }
            }
        }
        .screenTitleTag("スワイプで削除")
    }

    private func remove(_ n: Int) {
        rows.removeAll { $0 == n }
        lastRemoved = "removed=\(n)"
    }
}
