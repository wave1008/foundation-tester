import SwiftUI

struct GridScreen: View {
    @State private var result = "grid=none"
    private let columns = Array(repeating: GridItem(.flexible()), count: 3)

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            TaggedText(tag: Tags.txtGridResult, text: result)
                .padding([.horizontal, .top], 16)
            ScrollView {
                LazyVGrid(columns: columns, spacing: 4) {
                    ForEach(0..<90, id: \.self) { n in
                        Button {
                            result = String(format: "grid=%02d", n)
                        } label: {
                            Text("セル \(String(format: "%02d", n))")
                                .frame(maxWidth: .infinity, minHeight: 96)
                        }
                        .accessibilityIdentifier(Tags.cell(n))
                    }
                }
                .padding(.horizontal, 16)
            }
            .accessibilityIdentifier(Tags.gridMain)
        }
        .screenTitleTag("グリッド")
    }
}
