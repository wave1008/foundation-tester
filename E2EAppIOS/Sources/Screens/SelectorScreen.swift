import SwiftUI

struct SelectorScreen: View {
    @State private var result = "-"

    var body: some View {
        ScreenColumn {
            TaggedText(tag: Tags.selectorResult, text: "result=\(result)")

            // 「許可」⊂「通知を許可」の部分一致衝突は契約で意図的に作られた検証材料。
            TaggedButton(tag: Tags.btnAllow, label: "許可") { result = "allow" }
            TaggedButton(tag: Tags.btnAllowNotification, label: "通知を許可") { result = "allow_notification" }

            // 同一ラベル「項目」の3連。ラベル指定では曖昧・#id か .Type[n] でのみ引ける。
            TaggedButton(tag: Tags.btnItem1, label: "項目") { result = "item1" }
            TaggedButton(tag: Tags.btnItem2, label: "項目") { result = "item2" }
            TaggedButton(tag: Tags.btnItem3, label: "項目") { result = "item3" }

            TaggedText(tag: Tags.txtSharedLabel, text: "共通ラベル")
            TaggedButton(tag: Tags.btnSharedLabel, label: "共通ラベル") { result = "shared" }

            TaggedButton(tag: Tags.btnAliasNew, label: "別名ボタン") { result = "alias" }

            TaggedButton(tag: Tags.btnSelectorReset, label: "結果クリア") { result = "-" }

            // 700pt: 初期表示では絶対に画面内に入らない高さ(scrollTo / requireVisible の検証材料)。
            Spacer().frame(height: 700)
            TaggedText(tag: Tags.txtOffscreen, text: "画面外テキスト")
        }
    }
}
