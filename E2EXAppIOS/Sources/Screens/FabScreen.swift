import SwiftUI

/// iOS に FAB の定番は無いため overlay の Button で自作する(契約どおり。docs/ui-contract.md 参照)。
/// 行ラベル(行 F00 等)は契約が明記しないため他画面の命名(行 <suffix>)に揃えて補完。
struct FabScreen: View {
    @State private var result = "fab=none"

    var body: some View {
        ZStack(alignment: .bottomTrailing) {
            List {
                ForEach(0..<30, id: \.self) { n in
                    Text("行 F" + String(format: "%02d", n))
                        .accessibilityIdentifier(Tags.rowF(n))
                }
            }
            VStack(alignment: .trailing, spacing: 12) {
                Button {
                    result = "fab=extended"
                } label: {
                    Label("新規作成", systemImage: "plus")
                        .padding()
                        .background(Color.accentColor)
                        .foregroundColor(.white)
                        .clipShape(Capsule())
                }
                .accessibilityIdentifier(Tags.fabExtended)

                Button {
                    result = "fab=add"
                } label: {
                    Image(systemName: "plus")
                        .padding()
                        .background(Color.accentColor)
                        .foregroundColor(.white)
                        .clipShape(Circle())
                }
                .accessibilityLabel("追加")
                .accessibilityIdentifier(Tags.fabAdd)
            }
            .padding(20)

            VStack {
                TaggedText(tag: Tags.txtFabResult, text: result)
                    .padding(6)
                    .background(.thinMaterial)
                Spacer()
            }
        }
        .screenTitleTag("FAB")
        .toolbar {
            ToolbarItemGroup(placement: .bottomBar) {
                Button("検索") { result = "fab=search" }
                    .accessibilityIdentifier(Tags.barActionSearch)
                Spacer()
                Button("共有") { result = "fab=share" }
                    .accessibilityIdentifier(Tags.barActionShare)
            }
        }
    }
}
