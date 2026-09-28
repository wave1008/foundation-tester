import SwiftUI

struct SheetScreen: View {
    @State private var showSheet = false
    @State private var result = "sheet=none"
    // onDismiss はスクリム/下スワイプ/戻るのどれでも呼ばれる。選択操作による dismiss と
    // 区別するため、選択済みかを this-presentation 単位で覚えておく。
    @State private var selectedThisPresentation = false

    var body: some View {
        ScreenColumn {
            TaggedText(tag: Tags.txtSheetResult, text: result)
            TaggedButton(tag: Tags.btnOpenSheet, label: "シートを開く") {
                selectedThisPresentation = false
                showSheet = true
            }
        }
        .screenTitleTag("ボトムシート")
        .sheet(isPresented: $showSheet, onDismiss: {
            if !selectedThisPresentation { result = "sheet=dismissed" }
        }) {
            sheetContent
                .presentationDetents([.medium, .large])
        }
    }

    private func choose(_ value: String) {
        selectedThisPresentation = true
        result = value
        showSheet = false
    }

    private var sheetContent: some View {
        VStack(spacing: 12) {
            TaggedText(tag: Tags.txtSheetTitle, text: "シートの見出し")
                .font(.headline)
                .padding(.top, 16)
            HStack {
                ForEach(1...3, id: \.self) { n in
                    Button("選択肢 \(n)") { choose("sheet=opt\(n)") }
                        .accessibilityIdentifier(Tags.btnSheetOpt(n))
                }
            }
            List {
                ForEach(0..<30, id: \.self) { n in
                    Button("シート行 \(String(format: "%02d", n))") { choose(String(format: "sheet=row%02d", n)) }
                        .accessibilityIdentifier(Tags.rowSheet(n))
                }
            }
            // 半分開きのシートでは画面中央がシートの縁に当たるので、探索は scrollFrame でこの一覧を指す
            .accessibilityIdentifier("list_sheet")
        }
    }
}
