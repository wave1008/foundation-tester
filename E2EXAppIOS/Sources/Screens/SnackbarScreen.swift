import SwiftUI

/// iOS に定番のスナックバーは無いため、共通のカスタム toast オーバーレイで代替する
/// (docs/ui-contract.md §スナックバー)。内部の「元に戻す」ボタンは契約どおり id を付けない。
struct SnackbarScreen: View {
    private enum Kind { case long, short }

    @State private var result = "snackbar=none"
    @State private var visible: Kind?
    @State private var dismissTask: Task<Void, Never>?

    var body: some View {
        ZStack(alignment: .bottom) {
            ScreenColumn {
                TaggedText(tag: Tags.txtSnackbarResult, text: result)
                TaggedButton(tag: Tags.btnShowSnackbar, label: "スナックバーを出す") { show(.long) }
                TaggedButton(tag: Tags.btnShowSnackbarShort, label: "短いスナックバー") { show(.short) }
            }
            if let visible {
                toast(visible).transition(.move(edge: .bottom).combined(with: .opacity))
            }
        }
        .screenTitleTag("スナックバー")
    }

    private func toast(_ kind: Kind) -> some View {
        HStack {
            Text(kind == .long ? "削除しました" : "保存しました")
                .foregroundColor(.white)
            Spacer()
            if kind == .long {
                Button("元に戻す") {
                    dismissTask?.cancel()
                    withAnimation {
                        result = "snackbar=undo"
                        visible = nil
                    }
                }
                .foregroundColor(.yellow)
            }
        }
        .padding()
        .background(Color.black.opacity(0.85))
        .cornerRadius(8)
        .padding(.horizontal, 16)
        .padding(.bottom, 24)
    }

    private func show(_ kind: Kind) {
        dismissTask?.cancel()
        withAnimation { visible = kind }
        let seconds: UInt64 = kind == .long ? 10 : 4
        dismissTask = Task {
            try? await Task.sleep(nanoseconds: seconds * 1_000_000_000)
            guard !Task.isCancelled else { return }
            withAnimation {
                visible = nil
                result = kind == .long ? "snackbar=dismissed" : "snackbar=short-dismissed"
            }
        }
    }
}
