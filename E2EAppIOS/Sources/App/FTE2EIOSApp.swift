import SwiftUI

enum Screen {
    case selector, input, gesture, map, scroll, async, dialog, lifecycle, heal, diagnostics, noid, webview, cover, keyboardCover
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
            case .map: return "マップ"
            case .scroll: return "スクロール"
            case .async: return "非同期表示"
            case .dialog: return "ダイアログ"
            case .lifecycle: return "ライフサイクル"
            case .heal: return "自己修復"
            case .diagnostics: return "診断"
            case .noid: return "ID なし"
            case .webview: return "WebView"
            case .cover: return "覆い"
            case .keyboardCover: return "キーボードの覆い"
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
        .onOpenURL { handleDeepLink($0) }
    }

    // launchApp(url:) の再起動直後・実行中の openURL のどちらも SwiftUI がここへ集約して配送する。
    // 起動時リセット(@State の初期値 = ホームのルート)の後に適用される順序になる(契約 §ディープリンク)。
    // 未知の URL は #txt_last_deeplink の記録だけ行い、ナビは変えない(既存のタブ/画面状態を壊さない)。
    private func handleDeepLink(_ url: URL) {
        DeepLinkState.shared.lastURL = url.absoluteString
        guard url.scheme == "fte2eios", url.host == "screen" else { return }
        switch url.path {
        case "/selector":
            tab = .home
            homeChild = .selector
        case "/lifecycle":
            tab = .home
            homeChild = .lifecycle
        default:
            break
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
            case .gesture: GestureScreen(onOpenMap: { homeChild = .map })
            case .map: MapScreen()
            case .scroll: ScrollScreen()
            case .async: AsyncScreen()
            case .dialog: DialogScreen()
            case .lifecycle: LifecycleScreen()
            case .heal: HealScreen()
            case .diagnostics: DiagnosticsScreen()
            case .noid: NoIdScreen()
            case .webview: WebViewScreen()
            case .cover: CoverScreen()
            case .keyboardCover: KeyboardCoverScreen()
            }
        }
    }

    /// タブ切替は下位画面スタックを捨てて各タブのルートへ着地する(契約 §シェル)。
    private func switchTab(_ next: Tab) {
        tab = next
        homeChild = nil
    }
}
