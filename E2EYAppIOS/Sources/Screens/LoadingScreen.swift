import SwiftUI

@MainActor
final class LoadingModel: ObservableObject {
    enum Phase { case initial, idle, footerLoading, error, end }

    @Published var phase = Phase.initial
    @Published var loaded = 0
    @Published var result = "loading=none"
    private var failedOnce = false
    private var generation = 0

    var stateText: String {
        switch phase {
        case .initial, .footerLoading: return "loading"
        case .idle: return "loaded"
        case .error: return "error"
        case .end: return "end"
        }
    }

    func start() {
        generation += 1
        let gen = generation
        phase = .initial
        loaded = 0
        failedOnce = false
        result = "loading=none"
        Task {
            try? await Task.sleep(nanoseconds: 2_000_000_000)
            guard gen == generation else { return }
            loaded = 30
            phase = .idle
        }
    }

    /// 末尾の番兵が見えたとき。1回目の追加読み込みは必ず失敗し、再試行で 20 行足す。50 行まで読んだら終わり。
    func reachedEnd() {
        guard phase == .idle else { return }
        if loaded >= 50 { phase = .end; return }
        loadMore()
    }

    func retry() { guard phase == .error else { return }; loadMore() }

    private func loadMore() {
        generation += 1
        let gen = generation
        phase = .footerLoading
        Task {
            try? await Task.sleep(nanoseconds: 1_000_000_000)
            guard gen == generation else { return }
            if !failedOnce {
                failedOnce = true
                phase = .error
            } else {
                loaded = 50
                phase = .idle
            }
        }
    }
}

/// A3: 骨組みの行は本物と同じ #id・ラベルで押せない(disabled)。読み込み中も木に居る。
struct LoadingScreen: View {
    @StateObject private var model = LoadingModel()

    var body: some View {
        VStack(spacing: 0) {
            EchoArea {
                TaggedText(tag: "txt_loading_state", text: "state=\(model.stateText)")
                TaggedText(tag: "txt_loading_count", text: "loaded=\(model.loaded)")
                TaggedText(tag: "txt_loading_result", text: model.result)
                Button("読み込み直す") { model.start() }.accessibilityIdentifier("btn_reload")
            }
            List {
                if model.phase == .initial {
                    ForEach(0..<8, id: \.self) { i in
                        let name = "row_l_\(Tags.two(i))"
                        Button { } label: { Text("記事 \(Tags.two(i))").frame(maxWidth: .infinity, minHeight: 44, alignment: .leading).contentShape(Rectangle()) }
                            .buttonStyle(.plain)
                            .disabled(true)
                            .opacity(0.4)
                            .accessibilityLabel("記事 \(Tags.two(i))")
                            .accessibilityIdentifier(name)
                    }
                } else {
                    ForEach(0..<model.loaded, id: \.self) { i in
                        let name = "row_l_\(Tags.two(i))"
                        Button { model.result = "loading=\(name)" } label: {
                            Text("記事 \(Tags.two(i))").frame(maxWidth: .infinity, minHeight: 44, alignment: .leading)
                                .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .accessibilityIdentifier(name)
                    }
                    footer.id(model.phase)
                }
            }
            .listStyle(.plain)
        }
        .screenTitleTag("読み込みの状態")
        .onAppear { model.start() }
    }

    @ViewBuilder
    private var footer: some View {
        switch model.phase {
        case .footerLoading:
            Text("読み込み中").accessibilityIdentifier("txt_footer_loading")
        case .error:
            VStack(alignment: .leading) {
                Text("読み込みに失敗しました").accessibilityIdentifier("txt_footer_error")
                Button("再試行") { model.retry() }.accessibilityIdentifier("btn_retry")
            }
        case .end:
            Text("これ以上ありません").accessibilityIdentifier("txt_footer_end")
        default:
            Color.clear.frame(height: 1).onAppear { model.reachedEnd() }
        }
    }
}
