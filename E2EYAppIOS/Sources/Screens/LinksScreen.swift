import SwiftUI

/// A6: `Text(AttributedString)` の `.link` + openURL ハンドラ。リンクは子ノードとして木に出ない(ローター扱い)。
struct LinksScreen: View {
    @State private var result = "link=none"

    private static func linked(_ parts: [(String, String?)]) -> AttributedString {
        var out = AttributedString()
        for (text, link) in parts {
            var s = AttributedString(text)
            if let link { s.link = URL(string: "e2ey://\(link)") }
            out += s
        }
        return out
    }

    private let terms = linked([
        ("続行すると", nil), ("利用規約", "terms"), ("と", nil), ("プライバシーポリシー", "privacy"),
        ("に同意したものとみなされます。", nil),
    ])
    private let post = linked([
        ("", nil), ("@alice", "mention/alice"), (" さんが ", nil), ("https://example.com/a", "url"), (" を共有しました", nil),
    ])
    private let inner = linked([("お知らせ: 詳細は", nil), ("こちら", "inner")])

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            EchoArea { TaggedText(tag: "txt_links_result", text: result) }
            VStack(alignment: .leading, spacing: 24) {
                Text(terms).font(.footnote).accessibilityIdentifier("txt_terms")
                Text(post).font(.footnote).accessibilityIdentifier("txt_post")
                Button { result = "link=row" } label: {
                    Text(inner)
                        .frame(maxWidth: .infinity, minHeight: 44, alignment: .leading)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityIdentifier("row_with_link")
            }
            .padding(16)
            Spacer()
        }
        .environment(\.openURL, OpenURLAction { url in
            let path = (url.host ?? "") + url.path
            switch path {
            case "terms": result = "link=terms"
            case "privacy": result = "link=privacy"
            case "mention/alice": result = "link=mention:alice"
            case "url": result = "link=url"
            case "inner": result = "link=inner"
            default: break
            }
            return .handled
        })
        .screenTitleTag("文中リンク")
    }
}
