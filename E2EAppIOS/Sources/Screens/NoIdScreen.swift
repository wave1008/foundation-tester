import SwiftUI

// 契約: E2EAppCMP/docs/ui-contract.md「ID なし画面」。
// **この画面のビューに accessibilityIdentifier を付けてはいけない**
// (方向セレクタだけで操作・検証できることを保証するための画面)。
// 行の最小高 48 と行間は帯判定(:right が隣の行のスイッチを拾わない)の余裕。
struct NoIdScreen: View {
    @State private var notify = false
    @State private var location = false
    @State private var qty = 0

    var body: some View {
        ScreenColumn(scrollable: false) {
            Text("設定").font(.headline)

            toggleRow(label: "通知", isOn: $notify)
            Text("notify=\(notify ? "on" : "off")")

            toggleRow(label: "位置情報", isOn: $location)
            Text("location=\(location ? "on" : "off")")

            HStack(spacing: 16) {
                Button("変更") { if qty > 0 { qty -= 1 } }
                    .buttonStyle(.borderedProminent)
                    .frame(minHeight: 48)
                Text("数量")
                Button("変更") { qty += 1 }
                    .buttonStyle(.borderedProminent)
                    .frame(minHeight: 48)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            Text("qty=\(qty)")
        }
    }

    private func toggleRow(label: String, isOn: Binding<Bool>) -> some View {
        HStack {
            Text(label)
            Spacer()
            Toggle("", isOn: isOn).labelsHidden()
        }
        .frame(minHeight: 48)
    }
}
