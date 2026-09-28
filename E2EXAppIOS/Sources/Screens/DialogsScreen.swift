import SwiftUI

/// トースト(`#btn_toast`)は iOS に OS 標準の実装が無いため省く(docs/ui-contract.md 参照。
/// スナックバー画面のカスタム toast とは別物 = ここでは自前実装も足さない)。
struct DialogsScreen: View {
    @State private var result = "dialogs=none"
    @State private var showAlert = false
    @State private var showPrompt = false
    @State private var promptText = ""
    @State private var showActionSheet = false
    @State private var showFullscreen = false

    var body: some View {
        ScreenColumn {
            TaggedText(tag: Tags.txtDialogsResult, text: result)
            TaggedButton(tag: Tags.btnAlert, label: "アラート") { showAlert = true }
            TaggedButton(tag: Tags.btnPrompt, label: "入力つき") {
                promptText = ""
                showPrompt = true
            }
            TaggedButton(tag: Tags.btnActionSheet, label: "アクションシート") { showActionSheet = true }
            TaggedButton(tag: Tags.btnFullscreen, label: "全画面") { showFullscreen = true }
        }
        .screenTitleTag("ダイアログ")
        .alert("確認", isPresented: $showAlert) {
            Button("OK") { result = "alert=ok" }
            Button("キャンセル", role: .cancel) { result = "alert=cancel" }
        }
        // alert 内の TextField は UIAlertController が描く。id が AX ツリーへ届くかは
        // Menu 項目(docs/ui-contract.md)と同じ理由で未検証。
        .alert("入力してください", isPresented: $showPrompt) {
            TextField("入力", text: $promptText)
                .accessibilityIdentifier(Tags.fieldPrompt)
            Button("保存") { result = "prompt=\(promptText)" }
            Button("キャンセル", role: .cancel) { result = "prompt=cancel" }
        }
        .confirmationDialog("アクションシート", isPresented: $showActionSheet) {
            Button("写真を撮る") { result = "sheet=camera" }
            Button("ライブラリから選ぶ") { result = "sheet=library" }
            Button("キャンセル", role: .cancel) { result = "sheet=cancel" }
        }
        .fullScreenCover(isPresented: $showFullscreen) {
            ScreenColumn {
                TaggedText(tag: Tags.txtFullscreenTitle, text: "全画面ダイアログ")
                TaggedButton(tag: Tags.btnFullscreenSave, label: "保存") {
                    result = "fullscreen=saved"
                    showFullscreen = false
                }
                TaggedButton(tag: Tags.btnFullscreenClose, label: "閉じる") {
                    result = "fullscreen=closed"
                    showFullscreen = false
                }
            }
        }
    }
}
