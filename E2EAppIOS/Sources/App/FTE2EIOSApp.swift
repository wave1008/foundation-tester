import SwiftUI

enum Screen {
    case selector, input, gesture, scroll, async, dialog, lifecycle, heal, diagnostics
}

private enum Tab { case home, controls, about }

@main
struct FTE2EIOSApp: App {
    init() {
        LaunchCounter.shared.ensureCounted()
    }

    var body: some Scene {
        WindowGroup { AppShell() }
    }
}

// プロセス起動ごとに @State が初期値へ戻る = 「起動時は必ずホームタブのルート」契約が自然に成立する
// (launchApp はアプリのデータを消さないため、ナビ状態のリセットはアプリ側の責務)。
struct AppShell: View {
    @State private var tab: Tab = .home
    @State private var homeChild: Screen? = nil

    private var title: String {
        switch tab {
        case .controls: return "コントロール"
        case .about: return "情報"
        case .home:
            switch homeChild {
            case nil: return "ホーム"
            case .selector: return "セレクタ"
            case .input: return "テキスト入力"
            case .gesture: return "ジェスチャ"
            case .scroll: return "スクロール"
            case .async: return "非同期表示"
            case .dialog: return "ダイアログ"
            case .lifecycle: return "ライフサイクル"
            case .heal: return "自己修復"
            case .diagnostics: return "診断"
            }
        }
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                if homeChild != nil {
                    TaggedButton(tag: Tags.back, label: "戻る") { homeChild = nil }
                }
                TaggedText(tag: Tags.screenTitle, text: title)
                    .font(.headline)
                Spacer()
            }
            .padding(16)

            content
                .frame(maxWidth: .infinity, maxHeight: .infinity)

            HStack(spacing: 0) {
                TaggedButton(tag: Tags.tabHome, label: "ホーム", fillWidth: true) { switchTab(.home) }
                TaggedButton(tag: Tags.tabControls, label: "コントロール", fillWidth: true) { switchTab(.controls) }
                TaggedButton(tag: Tags.tabAbout, label: "情報", fillWidth: true) { switchTab(.about) }
            }
        }
    }

    @ViewBuilder private var content: some View {
        switch tab {
        case .controls: ControlsScreen()
        case .about: AboutScreen()
        case .home:
            switch homeChild {
            case nil: HomeScreen { homeChild = $0 }
            case .selector: SelectorScreen()
            case .input: InputScreen()
            case .gesture: GestureScreen()
            case .scroll: ScrollScreen()
            case .async: AsyncScreen()
            case .dialog: DialogScreen()
            case .lifecycle: LifecycleScreen()
            case .heal: HealScreen()
            case .diagnostics: DiagnosticsScreen()
            }
        }
    }

    /// タブ切替は下位画面スタックを捨てて各タブのルートへ着地する(契約 §シェル)。
    private func switchTab(_ next: Tab) {
        tab = next
        homeChild = nil
    }
}
