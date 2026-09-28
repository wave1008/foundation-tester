import SwiftUI

struct SwipeScreen: View {
    @State private var rows = Array(1...5)
    @State private var lastRemoved = "removed=none"

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            TaggedText(tag: Tags.txtSwipeResult, text: lastRemoved)
                .padding([.horizontal, .top], 16)
            TaggedText(tag: Tags.txtSwipeCount, text: "rows=\(rows.count)")
                .padding(.horizontal, 16)
            List {
                ForEach(rows, id: \.self) { n in
                    Text("スワイプ行 \(n)")
                        .accessibilityIdentifier(Tags.swipeRow(n))
                        // leading 側は何も登録しない = 左から右のスワイプは無効(契約どおり)
                        .swipeActions(edge: .trailing, allowsFullSwipe: true) {
                            Button("削除", role: .destructive) { remove(n) }
                        }
                }
            }
        }
        .screenTitleTag("スワイプで削除")
        .background(ContentPopGestureDisabler())
    }

    private func remove(_ n: Int) {
        rows.removeAll { $0 == n }
        lastRemoved = "removed=\(n)"
    }
}

/// iOS 26 以降の「コンテンツの上の右払いで戻る」をこの画面でだけ切る。
/// leading 側に何も登録していない行の右払いは、行ではなくこのジェスチャに渡って画面が戻ることがある
/// (M1Ultra で 12 回に 1 回)。契約は「左から右は無効」なので、戻る経路は画面の左端と戻るボタンだけにする。
private struct ContentPopGestureDisabler: UIViewControllerRepresentable {
    func makeUIViewController(context: Context) -> Controller { Controller() }
    func updateUIViewController(_ controller: Controller, context: Context) {}

    final class Controller: UIViewController {
        override func viewDidAppear(_ animated: Bool) {
            super.viewDidAppear(animated)
            setContentPop(enabled: false)
        }

        // ナビゲーションコントローラは画面を跨いで共有なので、離れるときに戻す
        override func viewWillDisappear(_ animated: Bool) {
            super.viewWillDisappear(animated)
            setContentPop(enabled: true)
        }

        private func setContentPop(enabled: Bool) {
            if #available(iOS 26.0, *) {
                navigationController?.interactiveContentPopGestureRecognizer?.isEnabled = enabled
            }
        }
    }
}
