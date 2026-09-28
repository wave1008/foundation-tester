import SwiftUI

struct ChipsScreen: View {
    @State private var wifiOn = false
    @State private var assistResult = "assist=none"
    @State private var seg = "day"

    var body: some View {
        ScreenColumn {
            Toggle("Wi-Fi", isOn: $wifiOn)
                .toggleStyle(.button)
                .accessibilityIdentifier(Tags.chipWifi)
            TaggedText(tag: Tags.txtChipResult, text: "wifi=\(wifiOn)")

            Button("ヘルプ") { assistResult = "assist=tapped" }
                .buttonStyle(.bordered)
                .accessibilityIdentifier(Tags.chipAssist)
            TaggedText(tag: Tags.txtAssistResult, text: assistResult)

            Picker("", selection: $seg) {
                Text("日").tag("day").accessibilityIdentifier(Tags.segDay)
                Text("週").tag("week").accessibilityIdentifier(Tags.segWeek)
                Text("月").tag("month").accessibilityIdentifier(Tags.segMonth)
            }
            .pickerStyle(.segmented)
            TaggedText(tag: Tags.txtSegResult, text: "seg=\(seg)")

            // SwiftUI に範囲スライダーの標準部品が無いため操作自体は省き、
            // echo だけ固定値で置く(docs/ui-contract.md §省いた部品)。
            TaggedText(tag: Tags.txtRangeResult, text: "range=20-80")
        }
        .screenTitleTag("チップと分割ボタン")
    }
}
