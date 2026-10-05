import SwiftUI

/// A1: 縦の List の各行に横の ScrollView + LazyHStack(IceCubes・firefox-ios のホームと同じ入れ子)。
struct NestedScreen: View {
    @State private var result = "nested=none"

    var body: some View {
        VStack(spacing: 0) {
            EchoArea { TaggedText(tag: "txt_nested_result", text: result) }
            List {
                ForEach(0..<10, id: \.self) { i in
                    VStack(alignment: .leading, spacing: 4) {
                        Text("棚 \(i)").font(.headline).accessibilityIdentifier("txt_shelf_\(i)")
                        ScrollView(.horizontal, showsIndicators: false) {
                            LazyHStack(spacing: 8) {
                                ForEach(0..<15, id: \.self) { j in
                                    let name = "card_\(i)_\(Tags.two(j))"
                                    Button { result = "nested=\(name)" } label: {
                                        Text("カード \(i)-\(Tags.two(j))")
                                            .frame(width: 140, height: 120)
                                            .background(Color.blue.opacity(0.15))
                                    }
                                    .buttonStyle(.plain)
                                    .accessibilityIdentifier(name)
                                }
                            }
                        }
                        .accessibilityIdentifier("shelf_\(i)")
                    }
                    .listRowSeparator(.hidden)
                }
            }
            .listStyle(.plain)
            .accessibilityIdentifier("list_nested")
        }
        .screenTitleTag("入れ子スクロール")
    }
}
