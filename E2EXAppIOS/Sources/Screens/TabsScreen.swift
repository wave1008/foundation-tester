import SwiftUI

struct TabsScreen: View {
    @State private var fixedTab = "A"
    @State private var scrollTab = "01"
    @State private var navbarTab = "home"

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            VStack(alignment: .leading, spacing: 8) {
                Picker("", selection: $fixedTab) {
                    Text("タブA").tag("A").accessibilityIdentifier(Tags.tabA)
                    Text("タブB").tag("B").accessibilityIdentifier(Tags.tabB)
                    Text("タブC").tag("C").accessibilityIdentifier(Tags.tabC)
                }
                .pickerStyle(.segmented)
                TaggedText(tag: Tags.txtTabContent, text: "content=\(fixedTab)")
            }

            VStack(alignment: .leading, spacing: 8) {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 8) {
                        ForEach(1...12, id: \.self) { n in
                            let code = String(format: "%02d", n)
                            Button("項目タブ\(code)") { scrollTab = code }
                                .accessibilityIdentifier(Tags.stab(n))
                        }
                    }
                }
                .accessibilityIdentifier(Tags.stabRow)
                TaggedText(tag: Tags.txtStabContent, text: "scroll-tab=\(scrollTab)")
            }

            TaggedText(tag: Tags.txtNavbarResult, text: "navbar=\(navbarTab)")

            // 画面下端のボトムナビゲーションは、この画面に埋め込んだ TabView(タブバー)で代替する。
            // tabItem の identifier が AX ツリーへ届くかは docs/ui-contract.md で未検証と明記している。
            TabView(selection: $navbarTab) {
                Color.clear
                    .tabItem { Label("ホーム", systemImage: "house") }
                    .accessibilityIdentifier(Tags.navbarHome)
                    .tag("home")
                Color.clear
                    .tabItem { Label("探す", systemImage: "magnifyingglass") }
                    .accessibilityIdentifier(Tags.navbarSearch)
                    .tag("search")
                Color.clear
                    .tabItem { Label("設定", systemImage: "gearshape") }
                    .accessibilityIdentifier(Tags.navbarSettings)
                    .tag("settings")
            }
        }
        .padding(.top, 16)
        .screenTitleTag("タブ")
    }
}
