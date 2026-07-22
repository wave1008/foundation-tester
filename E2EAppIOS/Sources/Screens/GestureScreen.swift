import SwiftUI

// ブリッジの swipe は要素を狙わず画面を払う: iOS は XCUITest の XCUIApplication.swipeUp() 等で
// アプリ frame 全体を払う(in-app エンジンは座標スワイプを持たず、動かせるスクロールビューが
// 無ければ 501 を返して XCUITest へ回る)。
// よって #pad_swipe は**コンテンツ領域いっぱい**に敷き、その上に操作要素を重ねる構成にする。
// 重ねてよいのは Text(ポインタを消費しない)だけ。ボタン類は始点を塞がないよう
// 「幅 45% 以内(中央列 x=0.5w を空ける)」かつ「上下の端(中央行 y=0.5h を空ける)」に置く。
struct GestureScreen: View {
    @State private var tapCount = 0
    @State private var pressCount = 0
    @State private var swipeDir = "-"
    @State private var last = "-"

    var body: some View {
        GeometryReader { geo in
            ZStack {
                Rectangle()
                    .fill(Color(.secondarySystemBackground))
                    .accessibilityElement()
                    .accessibilityIdentifier(Tags.padSwipe)
                    .accessibilityLabel("スワイプ領域")
                    .gesture(
                        // minimumDistance 10: タップ(移動 0)をドラッグと誤認しないための下限。
                        DragGesture(minimumDistance: 10)
                            .onEnded { value in
                                let dx = value.translation.width
                                let dy = value.translation.height
                                // 判定は指の移動方向(上へ払う = up)。ブリッジの direction 定義と一致させる契約。
                                swipeDir = abs(dx) > abs(dy)
                                    ? (dx < 0 ? "left" : "right")
                                    : (dy < 0 ? "up" : "down")
                                last = "swipe"
                            }
                    )

                // ラベルは #pad_swipe 側に持たせてある。ここで見せる文字は a11y から隠す
                // (隠さないと「スワイプ領域」が2要素になりラベルセレクタが曖昧になる)。
                Text("スワイプ領域").accessibilityHidden(true)

                // 上部左: タップ系。幅 45% で中央列を空ける。
                VStack(spacing: 8) {
                    TaggedButton(tag: Tags.btnTapCounter, label: "タップ", fillWidth: true) {
                        tapCount += 1
                        last = "tap"
                    }
                    longPressBox
                }
                .frame(width: geo.size.width * 0.45)
                .padding(12)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)

                // 右上: 読み取り専用の表示。Text はポインタを消費しないのでパッドの上に重ねてよい。
                VStack(alignment: .trailing, spacing: 4) {
                    TaggedText(tag: Tags.txtTapCount, text: "tap=\(tapCount)")
                    TaggedText(tag: Tags.txtPressCount, text: "press=\(pressCount)")
                    TaggedText(tag: Tags.txtSwipeDir, text: "swipe=\(swipeDir)")
                    TaggedText(tag: Tags.txtLastGesture, text: "last=\(last)")
                }
                .padding(12)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topTrailing)

                TaggedButton(tag: Tags.btnGestureReset, label: "ジェスチャクリア", fillWidth: true) {
                    tapCount = 0
                    pressCount = 0
                    swipeDir = "-"
                    last = "-"
                }
                .frame(width: geo.size.width * 0.45)
                .padding(12)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottomLeading)
            }
        }
    }

    // 通常タップでは増えず長押しでのみ増える要素。SwiftUI Button は長押しを区別できないため
    // 自前の Box + onLongPressGesture で作る(トレイトだけ Button に見せてツリー上の型を揃える)。
    private var longPressBox: some View {
        Text("長押し")
            .foregroundColor(.white)
            .frame(maxWidth: .infinity, minHeight: 56)
            .background(Color.accentColor)
            .cornerRadius(8)
            .onLongPressGesture(minimumDuration: 0.5) {
                pressCount += 1
                last = "longpress"
            }
            .accessibilityElement(children: .combine)
            .accessibilityAddTraits(.isButton)
            .accessibilityIdentifier(Tags.btnLongPress)
    }
}
