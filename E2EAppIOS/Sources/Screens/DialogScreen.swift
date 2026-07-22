import SwiftUI

struct DialogScreen: View {
    @State private var result = "none"
    @State private var dialogOpen = false
    @State private var maybeCount = 0
    @State private var auto = Prefs.getBool("auto_dialog", false)

    var body: some View {
        ScreenColumn {
            TaggedText(tag: Tags.txtDialogResult, text: "dialog=\(result)")
            TaggedButton(tag: Tags.btnShowDialog, label: "ダイアログを開く") { dialogOpen = true }
            TaggedButton(tag: Tags.btnMaybeDialog, label: "交互にダイアログ") {
                maybeCount += 1
                // 乱数不使用: 奇数回目だけ開く決定的な交互動作が検証要件。
                if maybeCount % 2 == 1 { dialogOpen = true }
            }
            HStack {
                Text("起動時ダイアログ")
                Toggle("", isOn: $auto)
                    .labelsHidden()
                    .accessibilityIdentifier(Tags.swAutoDialog)
                    .onChange(of: auto) { newValue in Prefs.setBool("auto_dialog", newValue) }
            }
            TaggedText(tag: Tags.txtAutoDialog, text: "auto=\(auto ? "on" : "off")")
        }
        // auto=on のとき、この画面に入るたびダイアログを自動で開く。
        .onAppear { if auto { dialogOpen = true } }
        // UIAlertController は別ウィンドウに描画されるが、**ボタンには** accessibilityIdentifier が
        // そのまま届く(Android の testTagsAsResourceId のような再適用は不要)。
        // ただし title/message は UIAlertController が自前で描く StaticText で、
        // .accessibilityIdentifier を付けても捨てられる(実測。message 側に付けても同じ)。
        // → 見出しの検証はラベル「確認」で行う契約にする(#txt_dialog_title は iOS ネイティブには無い)。
        .alert("確認", isPresented: $dialogOpen) {
            Button("OK") {
                result = "ok"
            }
            .accessibilityIdentifier(Tags.btnDialogOK)
            Button("キャンセル", role: .cancel) {
                result = "cancel"
            }
            .accessibilityIdentifier(Tags.btnDialogCancel)
        }
    }
}

struct HealScreen: View {
    @State private var schemaV1 = Prefs.getBool("heal_schema_v1", true)
    @State private var tapped = "-"

    var body: some View {
        ScreenColumn {
            HStack {
                Text("旧ID(v1)を使う")
                Toggle("", isOn: $schemaV1)
                    .labelsHidden()
                    .accessibilityIdentifier(Tags.swHealSchema)
                    .onChange(of: schemaV1) { newValue in Prefs.setBool("heal_schema_v1", newValue) }
            }
            TaggedText(tag: Tags.txtHealSchema, text: "schema=\(schemaV1 ? "v1" : "v2")")

            // ラベル固定・id のみ切替がヒール検証の核: schema=v2 で id が解決不能でも、
            // ラベル「修復対象」から FM が着地できるかを見る。
            TaggedButton(tag: schemaV1 ? Tags.btnHealV1 : Tags.btnHealV2, label: "修復対象") {
                tapped = schemaV1 ? "v1" : "v2"
            }
            TaggedText(tag: Tags.txtHealResult, text: "tapped=\(tapped)")
            TaggedButton(tag: Tags.btnHealReset, label: "修復結果クリア") { tapped = "-" }
        }
    }
}
