import SwiftUI

struct SearchScreen: View {
    @State private var query = ""
    @State private var result = "search=none"

    private let allSuggestions = ["apple", "apricot", "banana"]

    private var filtered: [String] {
        guard !query.isEmpty else { return allSuggestions }
        return allSuggestions.filter { $0.hasPrefix(query) }
    }

    var body: some View {
        ScreenColumn {
            TaggedText(tag: Tags.txtSearchResult, text: result)
        }
        .screenTitleTag("検索バー")
        // 検索欄自体は system 提供(UISearchBar 相当)で `.accessibilityIdentifier` を渡す
        // public API が無い。docs/ui-contract.md に不在の旨を明記している。
        .searchable(text: $query, placement: .navigationBarDrawer(displayMode: .always), prompt: "検索")
        .searchSuggestions {
            ForEach(filtered, id: \.self) { s in
                Button {
                    query = s
                    result = "search=\(s)"
                } label: {
                    Text(s)
                }
                .accessibilityIdentifier(Tags.suggestion(s))
            }
        }
        .onSubmit(of: .search) {
            result = "search=\(query)"
        }
    }
}
