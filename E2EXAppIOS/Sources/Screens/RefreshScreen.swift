import SwiftUI

struct RefreshScreen: View {
    @State private var count = 0

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            TaggedText(tag: Tags.txtRefreshCount, text: "refresh=\(count)")
                .padding([.horizontal, .top], 16)
            List {
                ForEach(0..<20, id: \.self) { n in
                    Text("更新行 \(String(format: "%02d", n))")
                        .accessibilityIdentifier(Tags.rowRefresh(n))
                }
            }
            .refreshable {
                try? await Task.sleep(nanoseconds: 1_000_000_000)
                count += 1
            }
        }
        .screenTitleTag("引っ張って更新")
    }
}
