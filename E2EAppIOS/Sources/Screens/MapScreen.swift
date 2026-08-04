import SwiftUI

/// 軸ごとの向き。8pt 未満は none(手ぶれを斜めと誤判定しないため。契約は E2EAppCMP/docs/ui-contract.md)
private let panThreshold: CGFloat = 8
/// 倍率の不感帯。ピンチ以外の操作で拾う微小な zoom を in/out と読まないため
private let zoomDeadZone: CGFloat = 0.05

// マップ系アプリの検証材料。**ジェスチャ画面とは別画面**にしてある: あちらの #pad_swipe は
// DragGesture を取って方向を決める作りで、同じ領域に拡大ジェスチャを重ねるとどちらかが空振りする。
// 値は全て累積(#btn_map_reset でだけ戻る)。1操作ごとに戻すと、ジェスチャ直後の snapshot が
// 間に合わなかったときに検証が落ちる。
struct MapScreen: View {
    @State private var zoom: CGFloat = 1
    @State private var panX: CGFloat = 0
    @State private var panY: CGFloat = 0
    @State private var doubleCount = 0

    var body: some View {
        GeometryReader { geo in
            ZStack {
                Rectangle()
                    .fill(Color(.secondarySystemBackground))
                    .accessibilityElement()
                    .accessibilityIdentifier(Tags.padMap)
                    .accessibilityLabel("マップ領域")
                    // **simultaneousGesture で重ねる**: .gesture を2回書くと後勝ちで片方が死ぬ。
                    // ダブルタップは最初に置く(単タップ判定に化ける前に拾わせる)
                    .simultaneousGesture(
                        TapGesture(count: 2).onEnded { doubleCount += 1 }
                    )
                    .simultaneousGesture(
                        MagnificationGesture().onEnded { value in zoom *= value }
                    )
                    .simultaneousGesture(
                        DragGesture(minimumDistance: 10).onEnded { value in
                            panX += value.translation.width
                            panY += value.translation.height
                        }
                    )

                // ラベルは #pad_map 側に持たせてある。ここで見せる文字は a11y から隠す
                // (隠さないと「マップ領域」が2要素になりラベルセレクタが曖昧になる)。
                Text("マップ領域").accessibilityHidden(true)

                VStack(alignment: .trailing, spacing: 4) {
                    TaggedText(tag: Tags.txtZoomDir, text: "zoom=\(zoomDirection)")
                    TaggedText(tag: Tags.txtZoom, text: "zoom=\(formattedZoom)")
                    TaggedText(tag: Tags.txtPan, text: "pan=\(panLabel)")
                    TaggedText(tag: Tags.txtDoubleCount, text: "double=\(doubleCount)")
                }
                .padding(12)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topTrailing)

                TaggedButton(tag: Tags.btnMapReset, label: "マップクリア", fillWidth: true) {
                    zoom = 1
                    panX = 0
                    panY = 0
                    doubleCount = 0
                }
                .frame(width: geo.size.width * 0.45)
                .padding(12)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottomLeading)
            }
        }
    }

    private var zoomDirection: String {
        if zoom > 1 + zoomDeadZone { return "in" }
        if zoom < 1 - zoomDeadZone { return "out" }
        return "-"
    }

    private var formattedZoom: String { String(format: "%.1f", zoom) }

    /// 指の移動方向。両軸とも非 none なら斜め(ftester の swipeBy の検証材料)
    private var panLabel: String {
        if abs(panX) < panThreshold && abs(panY) < panThreshold { return "-" }
        let horizontal = abs(panX) < panThreshold ? "none" : (panX < 0 ? "left" : "right")
        let vertical = abs(panY) < panThreshold ? "none" : (panY < 0 ? "up" : "down")
        return "\(horizontal)-\(vertical)"
    }
}
