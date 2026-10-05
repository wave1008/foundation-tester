import SwiftUI

/// A11: SwiftUI には NestedScrollView 相当が無いので、縦 ScrollView 1つ + `LazyVStack(pinnedViews:)` でヘッダが先に縮み、
/// タブ列は貼り付く。ページは横の paging ScrollView(`scrollPosition(id:)` でタブと同期)。
/// 縦の位置はタブ間で共有(タブごとの一覧位置は持てない。docs/ui-contract.md の逸脱)。
struct TabHeaderScreen: View {
    private struct Tab { let key: String; let label: String; let prefix: String; let rowLabel: String }
    private static let tabs = [
        Tab(key: "posts", label: "投稿", prefix: "post", rowLabel: "投稿"),
        Tab(key: "media", label: "メディア", prefix: "media", rowLabel: "メディア"),
        Tab(key: "likes", label: "いいね", prefix: "like", rowLabel: "いいね"),
    ]
    private let headerHeight: CGFloat = 200
    private let tabBarHeight: CGFloat = 44

    @State private var result = "tabhdr=none"
    @State private var tab: String? = "posts"
    @State private var expanded = true

    var body: some View {
        VStack(spacing: 0) {
            EchoArea {
                TaggedText(tag: "txt_tabhdr_result", text: result)
                TaggedText(tag: "txt_tabhdr_tab", text: "tab=\(tab ?? "posts")")
                TaggedText(tag: "txt_tabhdr_header", text: "header=\(expanded ? "expanded" : "collapsed")")
            }
            ScrollView {
                LazyVStack(spacing: 0, pinnedViews: [.sectionHeaders]) {
                    VStack(spacing: 12) {
                        Text("プロフィール見出し").font(.title3).accessibilityIdentifier("txt_profile_header")
                        Button("フォロー") { result = "tabhdr=follow" }
                            .buttonStyle(.borderedProminent)
                            .accessibilityIdentifier("btn_follow")
                    }
                    .frame(maxWidth: .infinity)
                    .frame(height: headerHeight)
                    .background(Color.purple.opacity(0.12))
                    .background(GeometryReader { geo in
                        Color.clear.preference(key: HeaderBottomKey.self, value: geo.frame(in: .named("tab_scroll")).maxY)
                    })
                    Section {
                        pages
                    } header: {
                        tabBar
                    }
                }
            }
            .coordinateSpace(name: "tab_scroll")
            .onPreferenceChange(HeaderBottomKey.self) { bottom in expanded = bottom > tabBarHeight }
        }
        .screenTitleTag("折りたたみヘッダとタブ")
    }

    private var tabBar: some View {
        HStack(spacing: 0) {
            ForEach(Self.tabs, id: \.key) { t in
                Button(t.label) { withAnimation { tab = t.key } }
                    .frame(maxWidth: .infinity, minHeight: tabBarHeight)
                    .fontWeight(tab == t.key ? .bold : .regular)
                    .accessibilityIdentifier("tab_\(t.key)")
            }
        }
        .background(Color(.systemBackground))
    }

    private var pages: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(alignment: .top, spacing: 0) {
                ForEach(Self.tabs, id: \.key) { t in
                    VStack(spacing: 0) {
                        ForEach(0..<40, id: \.self) { i in
                            let name = "\(t.prefix)_\(Tags.two(i))"
                            Button { result = "tabhdr=\(name)" } label: {
                                Text("\(t.rowLabel) \(Tags.two(i))")
                                    .frame(maxWidth: .infinity, minHeight: 56, alignment: .leading)
                                    .padding(.horizontal, 16)
                            }
                            .buttonStyle(.plain)
                            .accessibilityIdentifier(name)
                        }
                    }
                    .containerRelativeFrame(.horizontal)
                    .id(t.key)
                }
            }
            .scrollTargetLayout()
        }
        .scrollTargetBehavior(.paging)
        .scrollPosition(id: $tab)
    }
}

private struct HeaderBottomKey: PreferenceKey {
    static let defaultValue: CGFloat = 0
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) { value = nextValue() }
}
