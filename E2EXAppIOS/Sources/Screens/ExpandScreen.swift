import SwiftUI

struct ExpandScreen: View {
    private struct Group {
        let tag: String
        let title: String
        let items: [(tag: String, label: String)]
    }

    @State private var result = "expand=none"

    private let groups: [Group] = [
        Group(tag: Tags.groupFruit, title: "果物", items: [
            (Tags.item("fruit", 1), "りんご"), (Tags.item("fruit", 2), "みかん"), (Tags.item("fruit", 3), "ぶどう"),
        ]),
        Group(tag: Tags.groupVeg, title: "野菜", items: [
            (Tags.item("veg", 1), "にんじん"), (Tags.item("veg", 2), "たまねぎ"), (Tags.item("veg", 3), "キャベツ"),
        ]),
        Group(tag: Tags.groupDrink, title: "飲み物", items: [
            (Tags.item("drink", 1), "水"), (Tags.item("drink", 2), "お茶"), (Tags.item("drink", 3), "コーヒー"),
        ]),
    ]

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            TaggedText(tag: Tags.txtExpandResult, text: result)
                .padding([.horizontal, .top], 16)
            List {
                // DisclosureGroup は isExpanded を束縛しない限り既定で閉じた状態(契約どおり)。
                ForEach(groups, id: \.tag) { group in
                    DisclosureGroup {
                        ForEach(group.items, id: \.tag) { item in
                            Button(item.label) { result = "expand=\(item.tag)" }
                                .accessibilityIdentifier(item.tag)
                        }
                    } label: {
                        Text(group.title).accessibilityIdentifier(group.tag)
                    }
                }
            }
        }
        .screenTitleTag("展開するリスト")
    }
}
