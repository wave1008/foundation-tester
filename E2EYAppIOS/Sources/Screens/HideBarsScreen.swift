import SwiftUI

/// A10: 下へ送ると上部バー・FAB・下部バーが隠れ、少しでも戻すと現れる。
/// UIKit の `hidesBarsOnSwipe` は使わない(隠れるのが UINavigationBar になり、契約の `#bar_top_hiding` 等の id を付けられず、
/// `#txt_screen_title` / 戻るも一緒に消える)。SwiftUI の定番どおり、スクロール量を読んで自前のバーを平行移動する。
struct HideBarsScreen: View {
    @State private var result = "hide=none"
    @State private var hidden = false
    @State private var lastOffset: CGFloat = 0

    private let barHeight: CGFloat = 52

    var body: some View {
        VStack(spacing: 0) {
            EchoArea {
                TaggedText(tag: "txt_hide_result", text: result)
                TaggedText(tag: "txt_bars_state", text: "bars=\(hidden ? "hidden" : "shown")")
            }
            ZStack {
                ScrollView {
                    LazyVStack(spacing: 0) {
                        Color.clear.frame(height: barHeight)
                        ForEach(0..<60, id: \.self) { i in
                            let name = "row_h_\(Tags.two(i))"
                            Button { result = "hide=\(name)" } label: {
                                Text("行 H\(Tags.two(i))").frame(maxWidth: .infinity, minHeight: 48, alignment: .leading)
                                    .padding(.horizontal, 16)
                                    .contentShape(Rectangle())
                            }
                            .buttonStyle(.plain)
                            .accessibilityIdentifier(name)
                        }
                        Color.clear.frame(height: barHeight)
                    }
                }
                .onScrollGeometryChange(for: CGFloat.self) { $0.contentOffset.y + $0.contentInsets.top } action: { _, y in track(y) }

                VStack(spacing: 0) {
                    HStack {
                        Text("受信トレイ").font(.headline)
                        Spacer()
                        Button("並べ替え") { result = "hide=top_action" }.accessibilityIdentifier("btn_top_action")
                    }
                    .padding(.horizontal, 16)
                    .frame(height: barHeight)
                    .background(Color(.secondarySystemBackground))
                    .accessibilityElement(children: .contain)
                    .accessibilityIdentifier("bar_top_hiding")
                    .offset(y: hidden ? -barHeight : 0)
                    .opacity(hidden ? 0 : 1)
                    Spacer()
                    HStack {
                        Spacer()
                        Button { result = "hide=fab" } label: {
                            Image(systemName: "plus").frame(width: 56, height: 56)
                                .background(Circle().fill(Color.accentColor)).foregroundStyle(.white)
                        }
                        .accessibilityLabel("作成")
                        .accessibilityIdentifier("fab_hiding")
                        .padding(16)
                    }
                    .offset(y: hidden ? barHeight + 90 : 0)
                    .opacity(hidden ? 0 : 1)
                    HStack {
                        Button("受信") { result = "hide=bottom_a" }.accessibilityIdentifier("btn_bottom_a")
                            .frame(maxWidth: .infinity)
                        Button("フォルダ") { result = "hide=bottom_b" }.accessibilityIdentifier("btn_bottom_b")
                            .frame(maxWidth: .infinity)
                    }
                    .frame(height: barHeight)
                    .background(Color(.secondarySystemBackground))
                    .accessibilityElement(children: .contain)
                    .accessibilityIdentifier("bar_bottom_hiding")
                    .offset(y: hidden ? barHeight : 0)
                    .opacity(hidden ? 0 : 1)
                }
                .animation(.easeInOut(duration: 0.25), value: hidden)
            }
            .clipped()
        }
        .screenTitleTag("スクロールで隠れるバー")
    }

    /// 内容が上へ動く(offset 増)= 隠す・戻す(offset 減)= 出す。端のバウンスで誤反転しないよう先頭付近は常に出す。
    private func track(_ y: CGFloat) {
        let delta = y - lastOffset
        lastOffset = y
        if y <= 4 { hidden = false }
        else if delta > 6 { hidden = true }
        else if delta < -2 { hidden = false }
    }
}
