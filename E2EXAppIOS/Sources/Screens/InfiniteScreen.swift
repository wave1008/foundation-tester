import SwiftUI

struct InfiniteScreen: View {
    @State private var loadedCount = 20
    @State private var isLoading = false
    @State private var result = "infinite=none"

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            TaggedText(tag: Tags.txtInfiniteCount, text: "loaded=\(loadedCount)")
                .padding([.horizontal, .top], 16)
            List {
                ForEach(0..<loadedCount, id: \.self) { n in
                    Button {
                        result = "infinite=" + Tags.rowI(n)
                    } label: {
                        Text("項目 " + String(format: "%02d", n))
                    }
                    .accessibilityIdentifier(Tags.rowI(n))
                    // 末尾行が現れたら 0.8 秒後に次の 20 行を足す(最大 100。契約どおり)。
                    .onAppear {
                        if n == loadedCount - 1 { loadMore() }
                    }
                }
                if isLoading {
                    TaggedText(tag: Tags.txtLoading, text: "読み込み中")
                }
            }
            .accessibilityIdentifier(Tags.listInfinite)
            TaggedText(tag: Tags.txtInfiniteResult, text: result)
                .padding(.horizontal, 16)
        }
        .screenTitleTag("無限スクロール")
    }

    private func loadMore() {
        guard !isLoading, loadedCount < 100 else { return }
        isLoading = true
        Task {
            try? await Task.sleep(nanoseconds: 800_000_000)
            loadedCount = min(loadedCount + 20, 100)
            isLoading = false
        }
    }
}
