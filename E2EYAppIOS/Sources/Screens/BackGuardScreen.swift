import SwiftUI

@MainActor
final class BackGuardModel: ObservableObject {
    @Published var result = "back=none"
    @Published var title = ""
    @Published var panelOpen = false
    @Published var showDiscard = false

    /// 戻る操作の判定。true = 画面を戻してよい(このとき結果も確定する)。#btn_back とエッジスワイプが同じ判定を通る。
    func requestBack() -> Bool {
        if panelOpen { panelOpen = false; return false }
        if title.isEmpty { result = "back=clean"; return true }
        showDiscard = true
        return false
    }
}

/// A8: 独自の戻るボタン(`#btn_back`)。システムの戻るを隠すと UIKit はエッジスワイプも無効にするので、
/// 横取りの判定をエッジスワイプにも通す(EdgeSwipeGuard)。
struct BackGuardScreen: View {
    @StateObject private var model = BackGuardModel()
    @State private var showEditor = false

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            EchoArea { TaggedText(tag: "txt_back_result", text: model.result) }
            TaggedButton(tag: "btn_open_editor", label: "編集画面を開く") {
                model.panelOpen = false
                model.showDiscard = false
                showEditor = true
            }
            .padding(.horizontal, 16)
            Spacer()
        }
        .screenTitleTag("戻るの横取り")
        .navigationDestination(isPresented: $showEditor) {
            BackEditorScreen(model: model)
        }
    }
}

private struct BackEditorScreen: View {
    @ObservedObject var model: BackGuardModel
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        ZStack {
            VStack(alignment: .leading, spacing: 12) {
                EchoArea { TaggedText(tag: "txt_editor_state", text: "panel=\(model.panelOpen ? "open" : "closed")") }
                TextField("タイトル", text: $model.title)
                    .textFieldStyle(.roundedBorder)
                    .padding(.horizontal, 16)
                    .accessibilityIdentifier("field_title")
                TaggedButton(tag: "btn_open_panel", label: "パネルを開く") { model.panelOpen = true }
                    .padding(.horizontal, 16)
                if model.panelOpen {
                    VStack {
                        Text("パネル").accessibilityIdentifier("txt_panel")
                    }
                    .frame(maxWidth: .infinity, minHeight: 80)
                    .background(Color.yellow.opacity(0.25))
                    .padding(.horizontal, 16)
                    .accessibilityIdentifier("panel_inline")
                }
                Spacer()
            }
            if model.showDiscard { discardDialog }
        }
        .screenTitleTag("編集")
        .navigationBarBackButtonHidden(true)
        .toolbar {
            ToolbarItem(placement: .topBarLeading) {
                Button {
                    if model.requestBack() { dismiss() }
                } label: { Image(systemName: "chevron.backward") }
                    .accessibilityLabel("戻る")
                    .accessibilityIdentifier(Tags.btnBack)
            }
        }
        .background(EdgeSwipeGuard { model.requestBack() })
    }

    private var discardDialog: some View {
        ZStack {
            Color.black.opacity(0.4).ignoresSafeArea()
            VStack(spacing: 16) {
                Text("変更を破棄しますか?").font(.headline).accessibilityIdentifier("txt_discard_title")
                HStack(spacing: 12) {
                    Button("破棄", role: .destructive) {
                        model.showDiscard = false
                        model.result = "back=discarded"
                        model.title = ""
                        dismiss()
                    }
                    .accessibilityIdentifier("btn_discard")
                    Button("編集を続ける") { model.showDiscard = false }
                        .accessibilityIdentifier("btn_keep")
                }
                .buttonStyle(.bordered)
            }
            .padding(24)
            .background(Color(.systemBackground), in: RoundedRectangle(cornerRadius: 14))
            .padding(32)
        }
    }
}

/// interactivePopGestureRecognizer の delegate を差し替え、開始時に判定を呼ぶ。
/// `shouldPop` が false を返したらエッジスワイプは戻らない(判定側がパネルを閉じる・ダイアログを出す)。
/// delegate はナビゲーションコントローラが画面を跨いで共有するので、離れるときに元へ戻す。
private struct EdgeSwipeGuard: UIViewControllerRepresentable {
    let shouldPop: @MainActor () -> Bool

    func makeUIViewController(context: Context) -> Controller { Controller() }
    func updateUIViewController(_ controller: Controller, context: Context) { controller.shouldPop = shouldPop }

    final class Controller: UIViewController, UIGestureRecognizerDelegate {
        var shouldPop: @MainActor () -> Bool = { true }
        private weak var savedDelegate: UIGestureRecognizerDelegate?

        override func viewDidAppear(_ animated: Bool) {
            super.viewDidAppear(animated)
            guard let g = navigationController?.interactivePopGestureRecognizer else { return }
            if g.delegate !== self { savedDelegate = g.delegate }
            g.delegate = self
            g.isEnabled = true
            if #available(iOS 26.0, *) {
                navigationController?.interactiveContentPopGestureRecognizer?.isEnabled = false
            }
        }

        override func viewWillDisappear(_ animated: Bool) {
            super.viewWillDisappear(animated)
            navigationController?.interactivePopGestureRecognizer?.delegate = savedDelegate
            if #available(iOS 26.0, *) {
                navigationController?.interactiveContentPopGestureRecognizer?.isEnabled = true
            }
        }

        func gestureRecognizerShouldBegin(_ gestureRecognizer: UIGestureRecognizer) -> Bool {
            MainActor.assumeIsolated { shouldPop() }
        }
    }
}
