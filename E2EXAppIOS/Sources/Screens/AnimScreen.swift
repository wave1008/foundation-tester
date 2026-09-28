import SwiftUI

struct AnimScreen: View {
    @State private var visible = false
    @State private var count = 0

    var body: some View {
        ScreenColumn {
            TaggedButton(tag: Tags.btnToggleAnim, label: "表示を切り替える") {
                // visible の値自体はボタン押下時点で切り替える。1.5 秒かけて動くのは
                // withAnimation に包まれた transition(.opacity) の見た目だけ(契約どおり)。
                withAnimation(.easeInOut(duration: 1.5)) { visible.toggle() }
            }
            TaggedText(tag: Tags.txtAnimVisible, text: "visible=\(visible)")
            if visible {
                TaggedText(tag: Tags.txtAnimTarget, text: "アニメ完了")
                    .transition(.opacity)
            }

            TaggedButton(tag: Tags.btnAnimInc, label: "増やす") {
                withAnimation(.easeInOut(duration: 0.8)) { count += 1 }
            }
            Text("count=\(count)")
                .contentTransition(.numericText())
                .accessibilityIdentifier(Tags.txtAnimCount)
        }
        .screenTitleTag("アニメーション")
    }
}
