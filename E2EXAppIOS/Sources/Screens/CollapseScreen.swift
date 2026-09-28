import SwiftUI

/// iOS の UINavigationBar 大見出しは `#btn_back` と同じ理由(公開 API 無し)で
/// accessibilityIdentifier を持てない。契約の `#txt_collapse_header` はその代替として
/// リスト先頭に置く別要素("大きな見出し"という固定文言)で、こちらはスクロールで流れる
/// (実際に伸縮するのはシステムの大見出しの方)。docs/ui-contract.md に差分を記載。
struct CollapseScreen: View {
    @State private var result = "collapse=none"

    var body: some View {
        List {
            TaggedText(tag: Tags.txtCollapseHeader, text: "大きな見出し")
            ForEach(0..<50, id: \.self) { n in
                Button("行 C" + String(format: "%02d", n)) {
                    result = "collapse=" + Tags.rowC(n)
                }
                .accessibilityIdentifier(Tags.rowC(n))
            }
        }
        .navigationTitle("伸縮するヘッダ")
        .navigationBarTitleDisplayMode(.large)
        // 大見出しが縮んで消えても txt_collapse_result は木に残す(safeAreaInset は List の外側扱い)。
        .safeAreaInset(edge: .top) {
            TaggedText(tag: Tags.txtCollapseResult, text: result)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(8)
                .background(.thinMaterial)
        }
    }
}
