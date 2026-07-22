import SwiftUI

// レイアウトはソフトキーボードに支配される(Compose 版と同じ制約。実測は E2EApp/docs/ui-contract.md)。
//   1. スクロールさせない。スクロール可だとフォーカス時に列が動き、次の入力欄がキーボード下へ回り込む。
//   2. シナリオが触る要素(echo・送信/クリア・単一行/パスワード欄)をタイトル下 384pt に収める。
//      複数行欄とその echo だけは折り返しの下でよい(シナリオが触らない)。
// 送信/クリアを HStack に並べているのはこの高さ予算を作るため。
struct InputScreen: View {
    @State private var single = ""
    @State private var password = ""
    @State private var multiline = ""
    @State private var submitted = "-"

    var body: some View {
        ScreenColumn(scrollable: false) {
            TaggedText(tag: Tags.echoSingle, text: "single=\(single)")
            TaggedText(tag: Tags.echoPassword, text: "password=\(password)")
            TaggedText(tag: Tags.echoLength, text: "len=\(single.count)")
            TaggedText(tag: Tags.txtInputSubmitted, text: "submitted=\(submitted)")

            UIKitTextField(tag: Tags.fieldSingle, placeholder: "単一行", text: $single)
                .frame(height: 44)
            UIKitTextField(tag: Tags.fieldPassword, placeholder: "パスワード", isSecure: true, text: $password)
                .frame(height: 44)

            HStack(spacing: 8) {
                TaggedButton(tag: Tags.btnInputSubmit, label: "送信", fillWidth: true) { submitted = single }
                TaggedButton(tag: Tags.btnInputClear, label: "入力クリア", fillWidth: true) {
                    single = ""
                    password = ""
                    multiline = ""
                    submitted = "-"
                }
            }

            TaggedText(tag: Tags.echoMultiline, text: "multiline=\(multiline.replacingOccurrences(of: "\n", with: " "))")
            UIKitTextView(tag: Tags.fieldMultiline, text: $multiline)
                .frame(height: 80)
        }
    }
}
