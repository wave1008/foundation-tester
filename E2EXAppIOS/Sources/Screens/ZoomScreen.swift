import SwiftUI

/// MagnifyGesture は iOS 17+ 限定のため、deployment target iOS 16.0 に合わせて
/// 旧 API の MagnificationGesture を使う(挙動は同一。docs/ui-contract.md 参照)。
struct ZoomScreen: View {
    @State private var scale: CGFloat = 1.0
    @State private var lastScale: CGFloat = 1.0
    @State private var offset: CGSize = .zero
    @State private var lastOffset: CGSize = .zero

    var body: some View {
        ScreenColumn {
            TaggedText(tag: Tags.txtZoomScale, text: "scale=" + ZoomScreen.formatted(scale))
            TaggedButton(tag: Tags.btnZoomReset, label: "元に戻す") { reset() }
            RoundedRectangle(cornerRadius: 12)
                .fill(Color.blue.opacity(0.4))
                .frame(width: 200, height: 200)
                .scaleEffect(scale)
                .offset(offset)
                .accessibilityIdentifier(Tags.zoomTarget)
                .gesture(
                    MagnificationGesture()
                        .onChanged { value in
                            scale = min(4.0, max(1.0, lastScale * value))
                        }
                        .onEnded { _ in lastScale = scale }
                )
                .simultaneousGesture(
                    DragGesture()
                        .onChanged { value in
                            offset = CGSize(
                                width: lastOffset.width + value.translation.width,
                                height: lastOffset.height + value.translation.height)
                        }
                        .onEnded { _ in lastOffset = offset }
                )
        }
        .screenTitleTag("ピンチで拡大")
    }

    private func reset() {
        scale = 1.0
        lastScale = 1.0
        offset = .zero
        lastOffset = .zero
    }

    private static func formatted(_ v: CGFloat) -> String {
        String(format: "%.1f", v)
    }
}
