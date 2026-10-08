import SwiftUI

/// 全開の高さ。`.large` だと上部の固定領域(echo)をシートが覆うので、その分を残す。
private struct ExpandedDetent: CustomPresentationDetent {
    static func height(in context: Context) -> CGFloat? { context.maxDetentValue - 150 }
}

private extension PresentationDetent {
    static let collapsed = PresentationDetent.height(64)
    static let half = PresentationDetent.medium
    static let expanded = PresentationDetent.custom(ExpandedDetent.self)
}

/// A9: 閉じられない常駐シート(`.sheet` + detents + `presentationBackgroundInteraction(.enabled)` + `interactiveDismissDisabled`)。
struct PlayerScreen: View {
    @State private var showSheet = false
    @State private var detent = PresentationDetent.collapsed
    @State private var result = "player=none"
    @State private var playing = false

    private var stateText: String {
        detent == .collapsed ? "collapsed" : (detent == .half ? "half" : "expanded")
    }

    var body: some View {
        VStack(spacing: 0) {
            EchoArea {
                TaggedText(tag: "txt_sheet_state", text: "sheet=\(stateText)")
                TaggedText(tag: "txt_player_result", text: result)
            }
            List {
                ForEach(0..<40, id: \.self) { i in
                    let name = "row_main_\(Tags.two(i))"
                    Button { result = "player=main:\(name)" } label: {
                        Text("本文 \(Tags.two(i))").frame(maxWidth: .infinity, minHeight: 44, alignment: .leading)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .accessibilityIdentifier(name)
                }
            }
            .listStyle(.plain)
            .safeAreaInset(edge: .bottom) { Color.clear.frame(height: 64) }
        }
        .screenTitleTag("引き伸ばせるシート")
        .onAppear { DispatchQueue.main.async { showSheet = true } }
        .onDisappear { showSheet = false }
        .sheet(isPresented: $showSheet) {
            sheetContent
                .presentationDetents([.collapsed, .half, .expanded], selection: $detent)
                .presentationBackgroundInteraction(.enabled)
                .presentationContentInteraction(.resizes)
                .presentationDragIndicator(.visible)
                .interactiveDismissDisabled()
        }
    }

    @ViewBuilder
    private var sheetContent: some View {
        if detent == .collapsed {
            HStack {
                Button { detent = .half } label: {
                    HStack {
                        Text("再生中: トラック 1")
                        Spacer()
                    }
                    .frame(maxHeight: .infinity)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityIdentifier("txt_mini_title")
                Button(playing ? "一時停止" : "再生") {
                    playing.toggle()
                    result = playing ? "player=play" : "player=pause"
                }
                .accessibilityIdentifier("btn_mini_play")
            }
            .padding(.horizontal, 16)
            .frame(maxHeight: .infinity)
            .accessibilityElement(children: .contain)
            .accessibilityIdentifier("mini_player")
        } else {
            VStack(spacing: 0) {
                HStack {
                    Text("トラック 1").font(.headline).accessibilityIdentifier("txt_player_title")
                    Spacer()
                    Button { detent = .collapsed } label: { Image(systemName: "chevron.down") }
                        .accessibilityLabel("畳む")
                        .accessibilityIdentifier("btn_player_collapse")
                }
                .padding(16)
                List {
                    ForEach(0..<30, id: \.self) { i in
                        let name = "queue_row_\(Tags.two(i))"
                        Button { result = "player=queue:\(name)" } label: {
                            Text("キュー \(Tags.two(i))").frame(maxWidth: .infinity, minHeight: 44, alignment: .leading)
                                .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .accessibilityIdentifier(name)
                    }
                }
                .listStyle(.plain)
                .accessibilityIdentifier("list_queue")
            }
        }
    }
}
