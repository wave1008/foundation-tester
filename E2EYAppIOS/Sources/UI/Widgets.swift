import SwiftUI

struct TaggedButton: View {
    let tag: String
    let label: String
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Text(label).frame(minHeight: 44)
        }
        .buttonStyle(.borderedProminent)
        .accessibilityIdentifier(tag)
    }
}

struct TaggedText: View {
    let tag: String
    let text: String

    var body: some View {
        Text(text).accessibilityIdentifier(tag)
    }
}

/// 画面上部の固定領域(スクロールしない)。echo はここへまとめる。
struct EchoArea<Content: View>: View {
    @ViewBuilder let content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 4) { content }
            .font(.footnote)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 16)
            .padding(.vertical, 6)
    }
}

extension View {
    /// `#txt_screen_title` は画面見出し。システムの戻るボタンは前画面の navigationTitle をラベルに使うので両方をここで揃える。
    /// システムの戻るは UINavigationBar が内部で描くため `#btn_back` を付けられない(A8 だけ自前の戻るに替える)。
    func screenTitleTag(_ title: String) -> some View {
        self
            .navigationTitle(title)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .principal) {
                    Text(title).accessibilityIdentifier(Tags.screenTitle)
                }
            }
    }
}

/// iOS 26 以降の「コンテンツの上の右払いで戻る」をこの画面でだけ切る。
/// 左から右の横払い(A4 のピン留め・返信)がこのジェスチャに奪われて画面が戻ることがある。
struct ContentPopGestureDisabler: UIViewControllerRepresentable {
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
