import SwiftUI

/// plain スタイルの List は Section の見出しが上端に貼り付く(iOS 標準の慣用)。
struct StickyScreen: View {
    @State private var result = "sticky=none"
    private let letters = ["A", "B", "C", "D", "E", "F", "G", "H"]

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            TaggedText(tag: Tags.txtStickyResult, text: result)
                .padding([.horizontal, .top], 16)
            List {
                ForEach(letters, id: \.self) { letter in
                    Section {
                        ForEach(0..<10, id: \.self) { n in
                            Button("行 \(letter)\(n)") {
                                result = "sticky=" + Tags.rowSticky(letter, n)
                            }
                            .accessibilityIdentifier(Tags.rowSticky(letter, n))
                        }
                    } header: {
                        Text("セクション \(letter)")
                            .accessibilityIdentifier(Tags.hdr(letter))
                    }
                }
            }
            .listStyle(.plain)
        }
        .screenTitleTag("貼り付く見出し")
    }
}
