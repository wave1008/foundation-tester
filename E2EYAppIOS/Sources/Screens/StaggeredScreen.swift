import SwiftUI

/// A12: 列ごとの LazyVStack を 2 本並べ、短い方の列へ詰める(tie は左)。木の順は列ごと(左列 → 右列)。
struct StaggeredScreen: View {
    @State private var result = "stag=none"

    private static func height(_ i: Int) -> CGFloat { CGFloat(80 + ((i * 37) % 5) * 30) }

    private static let columns: [[Int]] = {
        var cols: [[Int]] = [[], []]
        var sums: [CGFloat] = [0, 0]
        for i in 0..<60 {
            let c = sums[1] < sums[0] ? 1 : 0
            cols[c].append(i)
            sums[c] += height(i)
        }
        return cols
    }()

    var body: some View {
        VStack(spacing: 0) {
            EchoArea { TaggedText(tag: "txt_staggered_result", text: result) }
            ScrollView {
                HStack(alignment: .top, spacing: 8) {
                    ForEach(0..<2, id: \.self) { c in
                        LazyVStack(spacing: 8) {
                            ForEach(Self.columns[c], id: \.self) { i in
                                let name = "stag_\(Tags.two(i))"
                                Button { result = "stag=\(name)" } label: {
                                    Text("タイル \(Tags.two(i))")
                                        .frame(maxWidth: .infinity)
                                        .frame(height: Self.height(i))
                                        .background(Color.green.opacity(0.2))
                                }
                                .buttonStyle(.plain)
                                .accessibilityIdentifier(name)
                            }
                        }
                    }
                }
                .padding(8)
            }
            .accessibilityIdentifier("grid_staggered")
        }
        .screenTitleTag("高さの揃わないグリッド")
    }
}
