import SwiftUI

struct ContextScreen: View {
    @State private var result = "context=none"

    var body: some View {
        ScreenColumn {
            TaggedText(tag: Tags.txtContextResult, text: result)
            ForEach(1...3, id: \.self) { n in
                Text("長押し行 \(n)")
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(12)
                    .background(Color(.secondarySystemBackground))
                    .accessibilityIdentifier(Tags.ctxRow(n))
                    .contextMenu {
                        Button("編集") { result = "context=row\(n):edit" }
                        Button("複製") { result = "context=row\(n):copy" }
                        Button("削除", role: .destructive) { result = "context=row\(n):delete" }
                    }
            }
        }
        .screenTitleTag("長押しメニュー")
    }
}
