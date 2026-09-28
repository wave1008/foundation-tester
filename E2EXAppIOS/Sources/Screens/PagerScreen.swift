import SwiftUI

struct PagerScreen: View {
    @State private var page = 0
    @State private var result = "pager=none"

    var body: some View {
        ScreenColumn {
            TabView(selection: $page) {
                ForEach(0..<5, id: \.self) { n in
                    VStack(spacing: 12) {
                        TaggedText(tag: Tags.txtPage(n), text: "ページ \(n)")
                        TaggedButton(tag: Tags.btnPage(n), label: "ページ \(n) のボタン") {
                            result = "pager=tapped \(n)"
                        }
                    }
                    .tag(n)
                }
            }
            .tabViewStyle(.page)
            .frame(height: 240)
            .accessibilityIdentifier(Tags.pagerMain)

            TaggedText(tag: Tags.txtPagerState, text: "page=\(page)")
            TaggedText(tag: Tags.txtPagerResult, text: result)
            TaggedButton(tag: Tags.btnPagerNext, label: "次のページ") {
                guard page < 4 else { return }
                withAnimation { page += 1 }
            }
        }
        .screenTitleTag("ページャ")
    }
}
