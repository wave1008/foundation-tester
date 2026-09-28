import SwiftUI

struct MenuScreen: View {
    /// SwiftUI `Menu` / `Picker(.menu)` は UIMenu 経由でポップアップを描くため、
    /// 中身の identifier が AX ツリーへ届くかは docs/ui-contract.md で未検証と明記している。
    private enum Fruit: String, CaseIterable {
        case apple = "りんご", banana = "バナナ", cherry = "さくらんぼ"

        var code: String {
            switch self {
            case .apple: return "apple"
            case .banana: return "banana"
            case .cherry: return "cherry"
            }
        }
    }

    @State private var menuResult = "menu=none"
    @State private var fruit: Fruit?
    @State private var fruitResult = "fruit=none"

    var body: some View {
        ScreenColumn {
            Menu {
                Button("コピー") { menuResult = "menu=copy" }
                    .accessibilityIdentifier(Tags.menuItemCopy)
                Button("共有") { menuResult = "menu=share" }
                    .accessibilityIdentifier(Tags.menuItemShare)
                Button("削除", role: .destructive) { menuResult = "menu=delete" }
                    .accessibilityIdentifier(Tags.menuItemDelete)
            } label: {
                Text("メニューを開く")
            }
            .accessibilityIdentifier(Tags.btnOpenMenu)
            TaggedText(tag: Tags.txtMenuResult, text: menuResult)

            Picker("果物", selection: $fruit) {
                Text("").tag(Fruit?.none)
                ForEach(Fruit.allCases, id: \.self) { f in
                    Text(f.rawValue).tag(Optional(f))
                }
            }
            .pickerStyle(.menu)
            .accessibilityIdentifier(Tags.fieldFruit)
            .onChange(of: fruit) { newValue in
                if let newValue { fruitResult = "fruit=\(newValue.code)" }
            }
            TaggedText(tag: Tags.txtFruitResult, text: fruitResult)
        }
        .screenTitleTag("メニュー")
    }
}
